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

// ---------------------------------------------------------------------------- msg (T3)

/// `msg.pin`, `msg.unpin`, `msg.favourite`, `msg.unfavourite`, `msg.burn`. The server's
/// `ConversationMessageRequest`: one message, named by its conversation and its id.
///
/// **[messageId] is a string, and on these endpoints the server insists on it.** The DTO declares
/// it as a C# `string`, and the gateway's socket binder does not go through the platform's JSON
/// options: a JSON number for a string property is not coerced, it throws, and the call comes back
/// `1000` with nothing to say which field was wrong. The package's own reason — a snowflake does
/// not survive a web `int` — points the same way.
///
/// 这里的 messageId 在服务端就是 string；套接字绑定器不做类型转换，发数字会被拒成一个说不出原因的 1000。
class ImConversationMessageRequest implements ImRequestBody {
  const ImConversationMessageRequest({required this.conversationId, required this.messageId});

  final String conversationId;

  /// The snowflake as decimal digits, exactly as [ImMessage.messageId] holds it.
  final String messageId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'conversationId': conversationId,
        'messageId': messageId,
      };
}

/// `msg.favourites`. The server's `PageRequest`: a cursor and a page size, nothing else.
class ImPageRequest implements ImRequestBody {
  const ImPageRequest({this.cursor, this.limit = 20});

  /// From the previous page's [ImPage.nextCursor]. A cursor the server cannot read restarts at page
  /// one rather than failing.
  final String? cursor;

  /// `0` or less becomes 20 server-side; anything above 100 becomes 100.
  final int limit;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'cursor': cursor,
        'limit': limit,
      });
}

/// `msg.search`. Full-text search over what the caller can see.
///
/// Only [keyword] is required. The other filters are applied **after** the index returns a page, so
/// a page can come back short — even empty — with [ImPage.hasMore] still true. Page on
/// [ImPage.nextCursor], never on `items.length`.
class ImSearchMessagesRequest implements ImRequestBody {
  const ImSearchMessagesRequest({
    required this.keyword,
    this.conversationId,
    this.contentTypes,
    this.senderId,
    this.startTime,
    this.endTime,
    this.cursor,
    this.limit = 20,
  });

  /// Blank is refused with [ImErrorCode.invalidArgument]. One made only of punctuation or emoji is
  /// not refused — it returns an empty page.
  final String keyword;

  /// One conversation. **Without it only the caller's 200 most recently updated conversations are
  /// searched** (`IM:Search:MaxConversationsPerQuery`), so an old chat is reachable only by naming
  /// it. A conversation the caller cannot see is [ImErrorCode.forbidden] — a group the caller is not
  /// in included, which is not [ImErrorCode.notGroupMember] here.
  final String? conversationId;

  /// Integers on the wire, like every enum in this package.
  final List<ImMessageContentType>? contentTypes;

  final String? senderId;

  /// Inclusive, against the server's `createTime`, unix ms.
  final int? startTime;

  /// Inclusive, against the server's `createTime`, unix ms.
  final int? endTime;

  final String? cursor;

  /// `0` or less becomes 20 server-side; anything above 100 becomes 100.
  final int limit;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'keyword': keyword,
        'conversationId': conversationId,
        'contentTypes': contentTypes == null
            ? null
            : <int>[for (final ImMessageContentType type in contentTypes!) type.wireValue],
        'senderId': senderId,
        'startTime': startTime,
        'endTime': endTime,
        'cursor': cursor,
        'limit': limit,
      });
}

/// `msg.receiptDetail`. Who has read one message.
///
/// [messageId] is a C# `string` on the server, for the reason [ImConversationMessageRequest] gives.
class ImReceiptDetailRequest implements ImRequestBody {
  const ImReceiptDetailRequest({required this.conversationId, required this.messageId});

  final String conversationId;
  final String messageId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'conversationId': conversationId,
        'messageId': messageId,
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

/// `conv.markUnread` (T3). The "remind me later" mark, set or cleared by hand.
class ImMarkUnreadRequest implements ImRequestBody {
  const ImMarkUnreadRequest({required this.conversationId, this.unread = true});

  final String conversationId;

  /// True sets the mark, false clears it. **Always sent**: the server reads an absent field as
  /// `true` — a property initialiser, not a nullable — so a request that left it out could only
  /// ever set the mark.
  /// 服务端把缺省读作 true，所以这个字段总是发出去：清除标记必须显式发 false。
  final bool unread;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'conversationId': conversationId,
        'unread': unread,
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

/// `user.setStatus` (T3). The caller's own free-text status line — "in a meeting", "on leave".
class ImSetStatusRequest implements ImRequestBody {
  const ImSetStatusRequest({this.status});

  /// Trimmed server-side; more than 64 characters is [ImErrorCode.invalidArgument]. **Null or blank
  /// clears it**, so `const ImSetStatusRequest()` is how a status is removed.
  final String? status;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{'status': status});
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

/// `friend.setRemark` (T3). What the caller calls a contact, and which of their folders the contact
/// is filed in. Never shown to the contact.
///
/// **The two optional fields are not symmetric, and the asymmetry is the server's.** A null
/// [remark] *clears* the remark; a null [tags] leaves the tags alone. So changing only the tags
/// means sending the current remark along with them, or the remark is lost in the same call.
///
/// 两个可选字段不对称：remark 为空是清空备注，tags 为空是不动标签。只改标签时要把现有备注一起带上。
class ImSetRemarkRequest implements ImRequestBody {
  const ImSetRemarkRequest({required this.userId, this.remark, this.tags});

  /// The contact. Not a contact is [ImErrorCode.notFriend].
  final String userId;

  /// At most 64 characters — longer is refused with [ImErrorCode.invalidArgument], not truncated.
  /// Null or blank clears it.
  final String? remark;

  /// Null leaves the tags as they are; an empty list clears them. At most 20, each non-blank and at
  /// most 32 characters, or the whole call is [ImErrorCode.invalidArgument].
  final List<String>? tags;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'userId': userId,
        'remark': remark,
        'tags': tags,
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

/// `group.memberList`, `group.applicationList`. Always paged, never "give me everyone": a super
/// group holds a hundred thousand members and materialising that into one frame is a
/// self-inflicted outage.
class ImGroupCursorRequest implements ImRequestBody {
  const ImGroupCursorRequest({
    required this.groupId,
    this.cursor,
    this.limit = 50,
  });

  /// For `group.applicationList` an empty string means "every group I manage" — see
  /// `ImGroupApi.applicationList`.
  final String groupId;

  final String? cursor;

  /// `group.memberList`: server clamps to 1…200. `group.applicationList`: 1…200 is kept and
  /// anything else — 0, negative, over 200 — becomes 50.
  final int limit;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'groupId': groupId,
        'cursor': cursor,
        'limit': limit,
      });
}

// ---------------------------------------------------------------------------- group (T3)

/// `group.transfer`. Hands the group to another member.
class ImTransferOwnerRequest implements ImRequestBody {
  const ImTransferOwnerRequest({required this.groupId, required this.newOwnerId});

  final String groupId;

  /// Must already be a member ([ImErrorCode.notGroupMember] otherwise) and must not be the caller
  /// ([ImErrorCode.invalidArgument]).
  final String newOwnerId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'groupId': groupId,
        'newOwnerId': newOwnerId,
      };
}

/// `group.handleApplication`. Accepts or rejects one join request.
class ImHandleApplicationRequest implements ImRequestBody {
  const ImHandleApplicationRequest({
    required this.groupId,
    required this.applicantId,
    required this.accept,
    this.reason,
  });

  final String groupId;
  final String applicantId;

  /// **Required here although the server does not require it: absent means reject.** The C#
  /// default is `false`, so a body that forgot the field would turn somebody away without anyone
  /// deciding to. The constructor makes the decision explicit instead.
  /// 服务端省略即拒绝，所以这里设成必填：忘了写的请求会在没人决定的情况下拒掉一个人。
  final bool accept;

  /// Stored as the application's `handleReason`.
  final String? reason;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'groupId': groupId,
        'applicantId': applicantId,
        'accept': accept,
        'reason': reason,
      });
}

/// `group.setRole`. Promotes a member to admin, or demotes an admin.
class ImSetRoleRequest implements ImRequestBody {
  /// [role] must be [ImGroupRole.member] or [ImGroupRole.admin]; anything else fails an assertion
  /// in a debug build, and is a compile-time error in a `const` one.
  const ImSetRoleRequest({required this.groupId, required this.userId, required this.role})
      : assert(
          role == ImGroupRole.member || role == ImGroupRole.admin,
          'group.setRole takes ImGroupRole.member or ImGroupRole.admin only. Ownership moves with '
          'group.transfer, and any other number is stored by the server as a privilege bug.',
        );

  final String groupId;
  final String userId;

  /// **[ImGroupRole.member] or [ImGroupRole.admin], and nothing else — checked here, because the
  /// server does not.** It refuses [ImGroupRole.owner] (`1008`, "use group.transfer") but stores any
  /// other integer it is given, and two of them are privilege bugs: `0` escapes a group-wide mute
  /// (only `Member` is muted) and `4` or above counts as a manager that outranks every admin. The
  /// field is required because the server reads an absent role as `Member` — a demotion should
  /// never be the result of leaving something out.
  ///
  /// The check is an `assert`, so it guards development and compiles away in release; the SDK does
  /// not refuse the call on the server's behalf.
  /// 只接受 member / admin：服务端拒 owner，却会原样存下其它任何整数——0 能躲过全员禁言，4 以上比管理员还大。
  final ImGroupRole role;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'groupId': groupId,
        'userId': userId,
        'role': role.wireValue,
      };
}

/// `group.mute`. The group-wide switch.
class ImMuteGroupRequest implements ImRequestBody {
  const ImMuteGroupRequest({required this.groupId, this.mute = true, this.untilMs});

  final String groupId;

  /// True mutes, false unmutes (and [untilMs] is then ignored). **Always sent**: the server reads an
  /// absent field as `true`.
  final bool mute;

  /// Unix ms the mute lasts until. Null with [mute] true is indefinite.
  ///
  /// **Never send a time that has already passed: the server reads it as *indefinite*, not as
  /// "unmute".** Its own comment says the opposite; its code sets the group muted and drops the
  /// deadline. A value computed as `now + duration` at the moment of the call is safe; one kept from
  /// an old form state is not. To unmute, send `mute: false`.
  /// 不要发已经过去的时间：服务端把它当成「无限期」，而不是「解除」。解除请发 mute: false。
  final int? untilMs;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'groupId': groupId,
        'mute': mute,
        'untilMs': untilMs,
      });
}

/// `group.muteMember`. One member.
class ImMuteMemberRequest implements ImRequestBody {
  const ImMuteMemberRequest({required this.groupId, required this.userId, this.untilMs});

  final String groupId;
  final String userId;

  /// Unix ms the member stays muted until. **Null, or a time in the past, unmutes**; there is no
  /// indefinite member mute — send a far-future time for one. Note the opposite reading from
  /// [ImMuteGroupRequest.untilMs], where a past time mutes indefinitely.
  /// 缺省或过去的时间即解除；没有「无限期禁言个人」，要就发一个很远的时间。与全员禁言的读法正好相反。
  final int? untilMs;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'groupId': groupId,
        'userId': userId,
        'untilMs': untilMs,
      });
}

/// `group.setNickname`. The name somebody goes by inside one group.
class ImSetGroupNicknameRequest implements ImRequestBody {
  const ImSetGroupNicknameRequest({required this.groupId, this.userId, this.nickname});

  final String groupId;

  /// Whose nickname. **Null, empty or the caller's own id means the caller**, which any member may
  /// set. Anybody else's needs owner or admin *and* outranking them
  /// ([ImErrorCode.noGroupPermission] / [ImErrorCode.cannotOperateOwner]).
  final String? userId;

  /// Trimmed; null or blank clears it. Longer than 64 characters is **silently truncated**, not
  /// refused.
  final String? nickname;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'groupId': groupId,
        'userId': userId,
        'nickname': nickname,
      });
}

/// `group.announcement`. Replaces the group's announcement.
class ImAnnouncementRequest implements ImRequestBody {
  const ImAnnouncementRequest({required this.groupId, this.announcement});

  final String groupId;

  /// Trimmed; null or blank clears it. Longer than 4096 characters is **silently truncated**, not
  /// refused.
  final String? announcement;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'groupId': groupId,
        'announcement': announcement,
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

// ---------------------------------------------------------------------------- push (T1/T2)

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

/// `push.clicked`. The tap on a notification, reported back for the delivery funnel.
///
/// **Both fields are optional and neither carries identity.** The row is located from the
/// connection: a [pushId] is believed only when it names a delivery to this user on this device,
/// and without one the server takes this device's newest delivery — narrowed to [messageId] when
/// you supply it. That is what stops a client marking somebody else's notification clicked, or
/// probing which `pu_…` ids exist.
///
/// Send whatever the notification payload gave you and nothing else. With neither field the server
/// still attributes the newest delivery to this device, which is the right answer for a tap that
/// opened the app without naming a message.
class ImPushClickedRequest implements ImRequestBody {
  const ImPushClickedRequest({this.pushId, this.messageId});

  /// The delivery's `pu_…` id, when the payload carried one.
  final String? pushId;

  /// The payload's `msgId`, when the tap gave you one. A string for the same reason every message
  /// id in this package is one: the ids are snowflakes, and on the web a Dart `int` is a JavaScript
  /// number that cannot hold one exactly.
  final String? messageId;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'pushId': pushId,
        'messageId': messageId,
      });
}

// ---------------------------------------------------------------------------- moderation (T2)

/// `moderation.report`. One end user reporting another, optionally naming a message.
///
/// **There is no field for the reporter and there must not be.** It comes from the socket, which is
/// the only surface on which the user id is a fact rather than a parameter. A field would let an
/// account file in somebody else's name — both a way to get a stranger banned and a way to poison
/// the count a moderator decides on.
/// 举报人来自连接而不是请求体：只有这一面上的 userId 是事实而不是参数。
class ImSubmitReportRequest implements ImRequestBody {
  const ImSubmitReportRequest({
    required this.targetUserId,
    this.conversationId,
    this.messageId,
    this.category = ImReportCategory.other,
    this.note,
  });

  /// The account being reported. Reporting yourself is refused with
  /// [ImErrorCode.invalidArgument].
  final String targetUserId;

  /// Where it happened, when the reporter was looking at a conversation.
  final String? conversationId;

  /// The message being reported. Null reports the account rather than one message.
  ///
  /// The server does **not** check that the message still exists, and that is deliberate: a report
  /// about a message that was already deleted is exactly the report a moderator most wants, and
  /// refusing it would turn the platform's own retention into a way to escape moderation. So do not
  /// withhold a report because the message went away under the reporter.
  /// 服务端刻意不校验消息是否还在——关于「已被删掉的消息」的举报恰恰是审核员最想要的那条。
  final String? messageId;

  /// One of [ImReportCategory]. An unknown value is refused with [ImErrorCode.invalidArgument]
  /// rather than filed under a name no moderation queue can group on.
  final String category;

  /// What the reporter typed. Usually the most useful field in the row, so give them somewhere to
  /// type it.
  final String? note;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'targetUserId': targetUserId,
        'conversationId': conversationId,
        // An empty id is omitted rather than sent. The server reads this field as a string: absent,
        // blank or "0" means "this is about the account, not one message", digits name that
        // message, and anything else is refused with 1001. Omitting is the one spelling every
        // server version has read as the account. A UI that reports from a screen with no message
        // selected produces exactly that empty string.
        // 空串按缺省处理：服务端这个字段是字符串，缺省、空白或 "0" 都表示举报账号；省略是各版本都认的写法。
        'messageId': messageId == '' ? null : messageId,
        'category': category,
        'note': note,
      });
}

/// The categories `moderation.report` accepts.
///
/// Strings, not an enum, for the same reason [ImPushProvider] is: the server owns the list. Unlike
/// the push channels an unknown value here is refused outright rather than folded, so offer
/// [values] in the picker and send back what the user chose.
abstract final class ImReportCategory {
  static const String spam = 'spam';
  static const String harassment = 'harassment';
  static const String fraud = 'fraud';
  static const String pornography = 'pornography';
  static const String violence = 'violence';

  /// The server's default: an empty [ImSubmitReportRequest.category] is filed as this.
  static const String other = 'other';

  /// Every category the server files, for the picker a report screen has to show.
  static const List<String> values = <String>[
    spam,
    harassment,
    fraud,
    pornography,
    violence,
    other,
  ];
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
