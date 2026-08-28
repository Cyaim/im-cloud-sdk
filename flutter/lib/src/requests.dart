/// One request object per endpoint, named for the server DTO in `sdk/endpoint-inventory.json`.
///
/// **Why an object and not positional parameters.** With positional parameters the server adding
/// one optional field is a source-breaking change in five languages at once; with a request object
/// it is additive everywhere. The rule (`sdk/CONTRACT.md` §4.3) is that every typed method takes
/// exactly one of these, and convenience overloads exist only where the request has at most two
/// required scalar fields and nothing optional — `im.conv.read(conversationId, readSeq)` qualifies,
/// a nine-argument `msg.send` does not.
///
/// 每个端点一个请求对象：服务端新增一个可选字段时，五种语言都是"加一个可选参数"而不是破坏性变更。
library;

import 'dart:math';

import 'json.dart';
import 'models.dart';
import 'protocol.dart';

/// Anything the typed surface sends as a request body.
abstract interface class ImRequestBody {
  /// Nulls are dropped — see [imBody]. The server omits nulls when writing and treats a missing
  /// field as default, so the two are equivalent, but only omitting keeps a frame small on a
  /// mobile radio.
  Map<String, Object?> toJson();
}

// ---------------------------------------------------------------------------- conn (T0)

/// `conn.reauth`. Exchanges a fresh token on the socket that is already open.
///
/// This is the endpoint that makes a mid-session token expiry cost one frame instead of a full
/// reconnect — and on the flaky network where tokens tend to expire, a reconnect is exactly what
/// you were trying to avoid. The renewed token must belong to the identity already on the socket;
/// the server refuses a token for another user with [ImErrorCode.forbidden] rather than quietly
/// changing who you are.
class ImReauthRequest implements ImRequestBody {
  const ImReauthRequest({required this.token});

  /// A freshly minted user token from the tenant's own backend. Never an app secret.
  final String token;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'token': token};
}

/// `conn.sync`. Ask what changed while we were away.
///
/// The SDK issues this itself on every connect and reconnect; an application normally never
/// constructs one. It is typed and public because the escape hatch and the diagnostics screen both
/// need it, and because a tenant with its own resume strategy should not have to hand-roll the
/// body.
class ImResumeRequest implements ImRequestBody {
  const ImResumeRequest({
    this.convSeqs = const <String, int>{},
    this.conversationCursor = 0,
    this.cursor,
    this.limit = 200,
  });

  /// **`committedSeq` per conversation, never `deliveredSeq`.** `docs/SPEC-02-protocol.md` §3.3:
  /// 报的是已落库的 seq，不是收到过的 seq. A conversation missing from this map, or reported as
  /// `0`, produces no gap entry in the reply — see [ImResumeResult.gapsFrom].
  final Map<String, int> convSeqs;

  /// Newest `ConversationView.updatedAt` from a run that completed. See `sdk/CONTRACT.md` §5.6
  /// step 8 for why "from a run that completed" is load-bearing.
  final int conversationCursor;

  /// Page cursor, from the previous page's [ImResumeResult.nextCursor].
  final String? cursor;

  /// Server clamps to 1…500; anything outside becomes 200.
  final int limit;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'convSeqs': convSeqs,
        'conversationCursor': conversationCursor,
        'cursor': cursor,
        'limit': limit,
      });
}

// ---------------------------------------------------------------------------- msg (T1)

/// `msg.send`.
///
/// Address it exactly one way: [conversationId] for a conversation you already have,
/// [receiverId] for a 1:1 by user id, or [groupId]. The server resolves or creates the
/// conversation from whichever you supplied.
class ImSendMessageRequest implements ImRequestBody {
  ImSendMessageRequest({
    this.conversationId,
    this.receiverId,
    this.groupId,
    this.conversationType,
    this.contentType = ImMessageContentType.text,
    required this.content,
    String? clientMsgId,
    this.mentionAll = false,
    this.mentionedUserIds,
    this.quoteMessageId,
    this.threadRootId,
    this.options,
    int? sendTime,
    this.extensions,
  })  : clientMsgId = clientMsgId ?? imNewClientMsgId(),
        sendTime = sendTime ?? DateTime.now().millisecondsSinceEpoch;

  /// Plain text, the case that is 90% of traffic.
  factory ImSendMessageRequest.text(
    String text, {
    String? conversationId,
    String? receiverId,
    String? groupId,
    String? clientMsgId,
    List<String>? mentionedUserIds,
    bool mentionAll = false,
    String? quoteMessageId,
    ImMessageOptions? options,
  }) =>
      ImSendMessageRequest(
        conversationId: conversationId,
        receiverId: receiverId,
        groupId: groupId,
        content: <String, dynamic>{'text': text},
        clientMsgId: clientMsgId,
        mentionedUserIds: mentionedUserIds,
        mentionAll: mentionAll,
        quoteMessageId: quoteMessageId,
        options: options,
      );

  final String? conversationId;
  final String? receiverId;
  final String? groupId;
  final ImConversationType? conversationType;
  final ImMessageContentType contentType;

  /// Shaped by [contentType], and free-form for a custom type. For media this holds the
  /// [ImMediaUploadTicket.objectKey], not a URL.
  final Map<String, dynamic> content;

  /// Idempotency key, generated when you do not supply one.
  ///
  /// `(appId, conversationId, senderId, clientMsgId)` is unique server-side, so reissuing a send
  /// that timed out returns the original result rather than posting a second message. This is also
  /// what makes cancellation safe: a cancelled `msg.send` may well have sent, and the same
  /// [clientMsgId] is how you find out without duplicating.
  final String clientMsgId;

  final bool mentionAll;
  final List<String>? mentionedUserIds;
  final String? quoteMessageId;
  final String? threadRootId;
  final ImMessageOptions? options;

  /// Sender's own clock, unix ms. Display only — the server stamps `createTime` itself, because
  /// client clocks are wrong.
  final int sendTime;

  final Map<String, dynamic>? extensions;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'conversationId': conversationId,
        'receiverId': receiverId,
        'groupId': groupId,
        'conversationType': conversationType?.wireValue,
        'clientMsgId': clientMsgId,
        'contentType': contentType.wireValue,
        'content': content,
        'mentionAll': mentionAll,
        'mentionedUserIds': mentionedUserIds,
        'quoteMessageId': quoteMessageId,
        'threadRootId': threadRootId,
        'options': options?.toJson(),
        'sendTime': sendTime,
        'extensions': extensions,
      });
}

/// `msg.sync`. A contiguous seq window, used to repair a gap.
///
/// [limit] is clamped to 500 server-side. A window wider than that comes back truncated with
/// [ImSyncMessagesResult.hasMore] set — loop, do not assume one call covers the range.
class ImSyncMessagesRequest implements ImRequestBody {
  const ImSyncMessagesRequest({
    required this.conversationId,
    required this.fromSeq,
    required this.toSeq,
    this.limit = 500,
    this.ascending = true,
  });

  final String conversationId;
  final int fromSeq;

  /// `0` means "up to the conversation's current maxSeq".
  final int toSeq;

  final int limit;

  /// Gap repair always wants ascending: the application must see a conversation fill in forwards.
  final bool ascending;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'conversationId': conversationId,
        'fromSeq': fromSeq,
        'toSeq': toSeq,
        'limit': limit,
        'ascending': ascending,
      };
}

/// `msg.history`. Pages backwards from a seq cursor. Server clamps [limit] to 200.
class ImHistoryRequest implements ImRequestBody {
  const ImHistoryRequest({
    required this.conversationId,
    this.beforeSeq,
    this.limit = 20,
  });

  final String conversationId;

  /// Null starts at the newest message.
  final int? beforeSeq;

  final int limit;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'conversationId': conversationId,
        'beforeSeq': beforeSeq,
        'limit': limit,
      });
}

/// `msg.recall`. Withdraws a message for everyone.
///
/// There is no `asAdmin` here on purpose: the server forces it to false for any client call,
/// whatever the body says, because admin recall is a server-API capability.
class ImRecallMessageRequest implements ImRequestBody {
  const ImRecallMessageRequest({
    required this.conversationId,
    required this.messageId,
    this.reason,
  });

  final String conversationId;
  final String messageId;
  final String? reason;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'conversationId': conversationId,
        'messageId': messageId,
        'reason': reason,
      });
}

/// `msg.delete`. Removes messages from the caller's own view, or from everyone's.
class ImDeleteMessagesRequest implements ImRequestBody {
  const ImDeleteMessagesRequest({
    required this.conversationId,
    required this.messageIds,
    this.forEveryone = false,
  });

  final String conversationId;
  final List<String> messageIds;

  /// True destroys other people's copies and is refused unless the caller may. False is the
  /// ordinary case and hides the message for the caller only.
  final bool forEveryone;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'conversationId': conversationId,
        'messageIds': messageIds,
        'forEveryone': forEveryone,
      };
}

/// `msg.typing`. Never stored, never counted, dropped first when a connection is behind.
///
/// Tenant-gated: an app with `EnableTypingIndicator` off answers [ImErrorCode.featureNotEnabled].
/// Do not latch that locally — the tenant can turn it on while your app is running.
class ImTypingRequest implements ImRequestBody {
  const ImTypingRequest({required this.conversationId, this.typing = true});

  final String conversationId;
  final bool typing;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'conversationId': conversationId,
        'typing': typing,
      };
}

/// `msg.edit`.
class ImEditMessageRequest implements ImRequestBody {
  const ImEditMessageRequest({
    required this.conversationId,
    required this.messageId,
    required this.content,
  });

  final String conversationId;
  final String messageId;

  /// Replaces the content wholesale; it is not a patch.
  final Map<String, dynamic> content;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'conversationId': conversationId,
        'messageId': messageId,
        'content': content,
      };
}

/// `msg.forward`. One call, many targets.
class ImForwardMessagesRequest implements ImRequestBody {
  ImForwardMessagesRequest({
    required this.sourceConversationId,
    required this.messageIds,
    required this.targetConversationIds,
    this.merge = false,
    this.mergeTitle,
    String? clientMsgId,
  }) : clientMsgId = clientMsgId ?? imNewClientMsgId();

  final String sourceConversationId;
  final List<String> messageIds;
  final List<String> targetConversationIds;

  /// True posts one `merged` message containing them all; false posts each separately.
  final bool merge;

  final String? mergeTitle;

  /// Idempotency key for the whole forward, generated when not supplied.
  final String clientMsgId;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'sourceConversationId': sourceConversationId,
        'messageIds': messageIds,
        'targetConversationIds': targetConversationIds,
        'merge': merge,
        'mergeTitle': mergeTitle,
        'clientMsgId': clientMsgId,
      });
}

/// `msg.react`. [add] false removes the caller's reaction.
class ImReactRequest implements ImRequestBody {
  const ImReactRequest({
    required this.conversationId,
    required this.messageId,
    required this.emoji,
    this.add = true,
  });

  final String conversationId;
  final String messageId;
  final String emoji;
  final bool add;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'conversationId': conversationId,
        'messageId': messageId,
        'emoji': emoji,
        'add': add,
      };
}

/// `msg.receipt`. Per-message read acknowledgement, distinct from the conversation-level read
/// cursor that `conv.read` moves.
class ImReceiptRequest implements ImRequestBody {
  const ImReceiptRequest({required this.conversationId, required this.messageIds});

  final String conversationId;
  final List<String> messageIds;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'conversationId': conversationId,
        'messageIds': messageIds,
      };
}

// ---------------------------------------------------------------------------- conv (T1/T2)

/// `conv.list`. Incremental by design: pass the largest `updatedAt` you already hold.
///
/// Getting this wrong is the difference between a one-second cold start and a thirty-second one
/// for a heavy user. Server clamps [limit] to 200.
class ImListConversationsRequest implements ImRequestBody {
  const ImListConversationsRequest({
    this.updatedAfter = 0,
    this.cursor,
    this.limit = 50,
  });

  final int updatedAfter;
  final String? cursor;
  final int limit;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'updatedAfter': updatedAfter,
        'cursor': cursor,
        'limit': limit,
      });
}

/// `conv.get`, `conv.delete`, `conv.clear`. The server's `ConversationIdRequest`.
class ImConversationIdRequest implements ImRequestBody {
  const ImConversationIdRequest({required this.conversationId});

  final String conversationId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'conversationId': conversationId};
}

/// `conv.read`. Moves the read cursor, which clears the badge on every device of this user because
/// unread is derived from it rather than counted per device.
class ImReadRequest implements ImRequestBody {
  const ImReadRequest({required this.conversationId, required this.readSeq});

  final String conversationId;
  final int readSeq;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'conversationId': conversationId,
        'readSeq': readSeq,
      };
}

/// `conv.setting`. A patch: only the fields you set on [setting] change.
class ImUpdateConversationSettingRequest implements ImRequestBody {
  const ImUpdateConversationSettingRequest({
    required this.conversationId,
    required this.setting,
  });

  final String conversationId;
  final ImConversationSetting setting;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'conversationId': conversationId,
        'setting': setting.toJson(),
      };
}

// ---------------------------------------------------------------------------- user (T1/T2)

/// `user.profile`, `friend.delete`, `friend.unblock`. The server's `UserIdRequest`.
class ImUserIdRequest implements ImRequestBody {
  const ImUserIdRequest({required this.userId});

  final String userId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'userId': userId};
}

/// `user.batchProfile`, `user.presence`, `user.unsubscribePresence`. The server's `UserIdsRequest`.
///
/// Batch is not an optimisation here, it is the difference between a conversation list that paints
/// and one that does not: 50 rows resolved one call each is 50 round trips on a mobile radio. The
/// server refuses more than 200 ids per request.
class ImUserIdsRequest implements ImRequestBody {
  const ImUserIdsRequest({required this.userIds});

  final List<String> userIds;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'userIds': userIds};
}

/// `user.updateProfile`. Patches the caller's own profile, by key.
///
/// A client may only patch itself, whatever the body says. The server also strips the fields the
/// platform owns — `appId`, `userId`, `banned`, `silencedUntil`, `createdAt`,
/// `multiLoginOverride` — so a client cannot unban or unsilence itself.
class ImUpdateProfileRequest implements ImRequestBody {
  const ImUpdateProfileRequest({required this.patch});

  final Map<String, dynamic> patch;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'patch': patch};
}

/// `user.subscribePresence`.
///
/// Subscriptions carry a TTL rather than living until an explicit unsubscribe, because a client
/// that crashes never sends one and an unbounded subscriber set is a leak that only shows up as
/// presence fan-out cost months later. Server clamps [ttlSeconds] to 1…3600, defaulting to 600.
///
/// One asymmetry worth knowing: this endpoint does **not** check the tenant's `EnablePresence`
/// flag, while `user.presence` does. A subscribe against a presence-disabled app succeeds and then
/// never fires, so do not infer the flag from a successful subscribe.
class ImSubscribePresenceRequest implements ImRequestBody {
  const ImSubscribePresenceRequest({required this.userIds, this.ttlSeconds = 600});

  final List<String> userIds;
  final int ttlSeconds;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'userIds': userIds,
        'ttlSeconds': ttlSeconds,
      };
}

// ---------------------------------------------------------------------------- friend (T2)

/// `friend.list`, `friend.blockList`, `group.joined`. The server's `CursorRequest`.
class ImCursorRequest implements ImRequestBody {
  const ImCursorRequest({this.cursor, this.limit = 50});

  final String? cursor;

  /// Server clamps to 1…200.
  final int limit;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'cursor': cursor,
        'limit': limit,
      });
}

/// `friend.add`. Sends an application; it is not an immediate friendship.
class ImAddFriendRequest implements ImRequestBody {
  const ImAddFriendRequest({required this.userId, this.greeting, this.source});

  final String userId;
  final String? greeting;

  /// Where the request came from: `search`, `qrcode`, `group`, anything the tenant defines.
  final String? source;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'userId': userId,
        'greeting': greeting,
        'source': source,
      });
}

/// `friend.handleRequest`. Accept or refuse an incoming application.
class ImHandleFriendRequest implements ImRequestBody {
  const ImHandleFriendRequest({
    required this.fromUserId,
    required this.accept,
    this.reason,
  });

  final String fromUserId;
  final bool accept;
  final String? reason;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'fromUserId': fromUserId,
        'accept': accept,
        'reason': reason,
      });
}

/// `friend.requestList`.
class ImFriendRequestListRequest implements ImRequestBody {
  const ImFriendRequestListRequest({
    this.incoming = true,
    this.cursor,
    this.limit = 50,
  });

  /// True lists applications sent *to* the caller; false lists the ones they sent.
  final bool incoming;

  final String? cursor;
  final int limit;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'incoming': incoming,
        'cursor': cursor,
        'limit': limit,
      });
}

/// `friend.block`.
class ImBlockRequest implements ImRequestBody {
  const ImBlockRequest({required this.userId, this.reason});

  final String userId;
  final String? reason;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'userId': userId,
        'reason': reason,
      });
}

// ---------------------------------------------------------------------------- group (T2)

/// `group.create`. The creator is always a member and always the owner, whatever [memberIds] says.
class ImCreateGroupRequest implements ImRequestBody {
  const ImCreateGroupRequest({
    required this.name,
    this.groupId,
    this.avatar,
    this.introduction,
    this.type = ImGroupType.normal,
    this.memberIds = const <String>[],
    this.joinMode = ImGroupJoinMode.freeAccess,
    this.inviteMode = ImGroupInviteMode.allMembers,
    this.maxMemberCount,
    this.extensions,
  });

  final String name;

  /// Supply your own id to make creation idempotent against a retry; leave null to have the server
  /// allocate one.
  final String? groupId;

  final String? avatar;
  final String? introduction;
  final ImGroupType type;
  final List<String> memberIds;
  final ImGroupJoinMode joinMode;
  final ImGroupInviteMode inviteMode;

  /// Null takes the tenant's configured ceiling.
  final int? maxMemberCount;

  final Map<String, dynamic>? extensions;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'groupId': groupId,
        'name': name,
        'avatar': avatar,
        'introduction': introduction,
        'type': type.wireValue,
        'memberIds': memberIds,
        'joinMode': joinMode.wireValue,
        'inviteMode': inviteMode.wireValue,
        'maxMemberCount': maxMemberCount,
        'extensions': extensions,
      });
}

/// `group.info`, `group.dismiss`, `group.quit`. The server's `GroupIdRequest`.
class ImGroupIdRequest implements ImRequestBody {
  const ImGroupIdRequest({required this.groupId});

  final String groupId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'groupId': groupId};
}

/// The mutable half of a group, for `group.update`. Only the fields you set change.
class ImUpdateGroupRequest implements ImRequestBody {
  const ImUpdateGroupRequest({
    this.name,
    this.avatar,
    this.introduction,
    this.joinMode,
    this.inviteMode,
    this.maxMemberCount,
    this.extensions,
  });

  final String? name;
  final String? avatar;
  final String? introduction;
  final ImGroupJoinMode? joinMode;
  final ImGroupInviteMode? inviteMode;
  final int? maxMemberCount;
  final Map<String, dynamic>? extensions;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'name': name,
        'avatar': avatar,
        'introduction': introduction,
        'joinMode': joinMode?.wireValue,
        'inviteMode': inviteMode?.wireValue,
        'maxMemberCount': maxMemberCount,
        'extensions': extensions,
      });
}

/// `group.update`. The server wraps [update] in a command carrying the id, and this mirrors it
/// exactly rather than flattening — flattening would make `name` mean two things at two levels.
class ImUpdateGroupCommand implements ImRequestBody {
  const ImUpdateGroupCommand({required this.groupId, required this.update});

  final String groupId;
  final ImUpdateGroupRequest update;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'groupId': groupId,
        'update': update.toJson(),
      };
}

/// `group.invite`, `group.kick`.
class ImGroupMembersRequest implements ImRequestBody {
  const ImGroupMembersRequest({
    required this.groupId,
    required this.userIds,
    this.reason,
  });

  final String groupId;
  final List<String> userIds;
  final String? reason;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'groupId': groupId,
        'userIds': userIds,
        'reason': reason,
      });
}

/// `group.join`. A group with `needApproval` answers [ImErrorCode.joinNeedsApproval]; that is the
/// application being filed, not a failure.
class ImJoinGroupRequest implements ImRequestBody {
  const ImJoinGroupRequest({required this.groupId, this.reason});

  final String groupId;
  final String? reason;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'groupId': groupId,
        'reason': reason,
      });
}

/// `group.memberList`. Always paged, never "give me everyone": a super group holds a hundred
/// thousand members and materialising that into one frame is a self-inflicted outage.
class ImGroupCursorRequest implements ImRequestBody {
  const ImGroupCursorRequest({
    required this.groupId,
    this.cursor,
    this.limit = 50,
  });

  final String groupId;
  final String? cursor;

  /// Server clamps to 1…200.
  final int limit;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'groupId': groupId,
        'cursor': cursor,
        'limit': limit,
      });
}

// ---------------------------------------------------------------------------- media (T1)

/// `media.uploadTicket`.
class ImUploadTicketRequest implements ImRequestBody {
  const ImUploadTicketRequest({
    required this.fileName,
    required this.contentType,
    required this.size,
  });

  /// Used for the extension and for the stored name. The server chooses the object key itself.
  final String fileName;

  /// MIME type. The tenant's allow-list is checked against it — a refusal is
  /// [ImErrorCode.fileTypeNotAllowed].
  final String contentType;

  /// Bytes. Checked against the tenant's ceiling before a URL is signed, so an oversized file
  /// fails here rather than after the upload.
  final int size;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'fileName': fileName,
        'contentType': contentType,
        'size': size,
      };
}

/// `media.downloadUrl`. Exchanges a stored object key for a short-lived link.
class ImDownloadUrlRequest implements ImRequestBody {
  const ImDownloadUrlRequest({required this.objectKey, this.lifetimeSeconds = 3600});

  /// From [ImMediaUploadTicket.objectKey], or out of a message's `content`.
  final String objectKey;

  /// Server clamps to 1…86400, defaulting to 3600. Sign a short one and re-sign on demand: a long
  /// link is a long window for a leak.
  final int lifetimeSeconds;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'objectKey': objectKey,
        'lifetimeSeconds': lifetimeSeconds,
      };
}

// ---------------------------------------------------------------------------- push (T1)

/// `push.register`.
///
/// **Identity comes from the socket.** There is no `userId` or `deviceId` field here, and that is
/// deliberate on the server's side too: the connection is the one place where app id, user id and
/// device id are all already authenticated together, so "register a token against someone else's
/// device" is not merely forbidden — there is no field in which to say it.
class ImRegisterPushTokenRequest implements ImRequestBody {
  const ImRegisterPushTokenRequest({
    required this.provider,
    required this.token,
    this.language,
  });

  /// One of [ImPushProvider]. Common aliases (`ios`, `firebase`, `hms`, …) are folded server-side;
  /// an unknown value is **rejected** with the legal list rather than stored as a token nothing can
  /// route.
  ///
  /// Empty falls back to the platform default, which is only reliable on iOS. **On Android always
  /// send this explicitly** — Android fragments across five OEM channels and the server cannot
  /// guess which one a token came from.
  /// Android 必须显式指定厂商通道：服务端无法从 token 反推它来自哪家。
  final String provider;

  /// The vendor's device token, opaque to the platform.
  final String token;

  /// BCP-47. Defaults to the socket's `lang`.
  final String? language;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'provider': provider,
        'token': token,
        'language': language,
      });
}

/// The vendor channels `push.register` accepts.
///
/// Strings, not an enum, for the same reason [ImErrorCode] is: the server owns the list and folds
/// aliases, and a new OEM channel must not require an SDK release.
abstract final class ImPushProvider {
  static const String apns = 'apns';
  static const String fcm = 'fcm';
  static const String huawei = 'huawei';
  static const String xiaomi = 'xiaomi';
  static const String oppo = 'oppo';
  static const String vivo = 'vivo';
  static const String honor = 'honor';

  /// Every channel the server routes, for a settings screen that has to offer a choice.
  static const List<String> values = <String>[apns, fcm, huawei, xiaomi, oppo, vivo, honor];
}

// ---------------------------------------------------------------------------- helpers

final Random _random = Random();

/// A client-side idempotency key: millisecond stamp plus randomness, base36.
///
/// Generating one here rather than asking callers for it means a naive caller still gets
/// exactly-once semantics on a retry. It does not need to be a UUID — it is scoped to
/// `(appId, conversationId, senderId)` server-side, so collision only matters within one sender's
/// own traffic in the same millisecond.
String imNewClientMsgId() {
  final String stamp = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final String suffix = _random.nextInt(0x7fffffff).toRadixString(36);
  return '$stamp-$suffix';
}
