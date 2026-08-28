/// Payload types the typed surface returns and accepts, beyond the envelope in `protocol.dart`.
///
/// Every class here is named for the server DTO in `sdk/endpoint-inventory.json` with an `Im`
/// prefix, and every field for the JSON name in that inventory. The prefix is not decoration: Dart
/// has no namespaces, so a library's exports land directly in the importing file's scope, and a
/// package that exported bare `Group`, `Message`, `Friend` and `UserProfile` would collide with
/// almost every application that imported it. `ImPlatform` already exists for exactly this reason —
/// `dart:io` owns `Platform`.
///
/// Same rules as the envelope: hand-decoded, tolerant of missing fields, tolerant of numbers that
/// arrive as strings, and never throwing because the server grew a field.
///
/// 类名按 endpoint-inventory.json 的服务端 DTO 命名并加 Im 前缀：Dart 没有命名空间，
/// 导出裸 Group / Message / Friend 会和几乎所有应用冲突。
library;

import 'json.dart';
import 'protocol.dart';

// ---------------------------------------------------------------------------- conn (T0)

/// `conn.heartbeat`. The server owns the cadence, so [intervalSeconds] is adopted rather than
/// configured.
class ImHeartbeatResult {
  const ImHeartbeatResult({
    required this.serverTime,
    required this.intervalSeconds,
    required this.healed,
    required this.connectionId,
    required this.nodeId,
  });

  factory ImHeartbeatResult.fromJson(Map<String, dynamic> json) => ImHeartbeatResult(
        serverTime: imIntOr(json['serverTime']),
        intervalSeconds: imIntOr(json['intervalSeconds']),
        healed: imBool(json['healed']),
        connectionId: imStringOr(json['connectionId']),
        nodeId: imStringOr(json['nodeId']),
      );

  /// Authoritative clock, unix ms.
  final int serverTime;

  /// How often to beat. The gateway may change it at runtime; the SDK re-arms its timer when it
  /// does.
  final int intervalSeconds;

  /// True when this beat rebuilt a cluster routing entry that had gone missing — a Redis eviction,
  /// a failover to an empty replica. Worth surfacing in a diagnostics screen: a client that heals
  /// often is telling you something about the cluster.
  final bool healed;

  /// This socket's cluster-unique id. Quote it in a support ticket and the exact node and
  /// connection can be found without guessing.
  final String connectionId;

  /// The gateway node holding this socket.
  final String nodeId;
}

/// `conn.sync`. What changed while the client was away.
///
/// The server deliberately does not replay the missed messages: a client offline for a week may be
/// a hundred thousand messages behind across four hundred conversations, and pushing that at
/// reconnect is how a reconnect storm becomes an outage. It returns what *changed* and lets the
/// client decide what to fetch — and, crucially, when to stop.
class ImResumeResult {
  const ImResumeResult({
    required this.conversations,
    required this.gapsFrom,
    required this.hasMore,
    required this.serverTime,
    this.nextCursor,
  });

  factory ImResumeResult.fromJson(Map<String, dynamic> json) => ImResumeResult(
        conversations: imList<ImConversationView>(
          json['conversations'],
          ImConversationView.fromJson,
        ),
        nextCursor: imString(json['nextCursor']),
        hasMore: imBool(json['hasMore']),
        gapsFrom: imIntMap(json['gapsFrom']),
        serverTime: imIntOr(json['serverTime']),
      );

  /// One page of conversations whose state moved, newest [ImConversationView.updatedAt] first.
  final List<ImConversationView> conversations;

  /// Page cursor. Null when exhausted.
  final String? nextCursor;

  /// **Page on this, not on `conversations.length`.** A page can be short and still have more
  /// behind it.
  final bool hasMore;

  /// `conversationId` → first seq the client is missing. Feed each into `msg.sync`.
  ///
  /// A conversation the client did not report — or reported as `0` — produces **no entry here**.
  /// That is not the server being unhelpful, it is the server having nothing to compare against,
  /// and it is the reason the client must report `committedSeq` for every conversation it knows
  /// about. See `sdk/CONTRACT.md` §5.1.
  final Map<String, int> gapsFrom;

  final int serverTime;
}

// ---------------------------------------------------------------------------- msg (T1)

/// `msg.sync`. One page of a contiguous seq range.
class ImSyncMessagesResult {
  const ImSyncMessagesResult({
    required this.conversationId,
    required this.messages,
    required this.maxSeq,
    required this.minSeq,
    required this.hasMore,
  });

  factory ImSyncMessagesResult.fromJson(Map<String, dynamic> json) => ImSyncMessagesResult(
        conversationId: imStringOr(json['conversationId']),
        messages: imList<ImMessage>(json['messages'], ImMessage.fromJson),
        maxSeq: imIntOr(json['maxSeq']),
        minSeq: imIntOr(json['minSeq']),
        hasMore: imBool(json['hasMore']),
      );

  final String conversationId;

  /// The window, minus anything hidden for this user.
  final List<ImMessage> messages;

  /// Highest seq the conversation holds — not the highest in [messages].
  final int maxSeq;

  /// Lowest seq this user may see. A member who joined late, or whose history was cleared, has a
  /// floor above 1.
  final int minSeq;

  /// **Computed on the raw window, before per-user hidden messages are filtered out**
  /// (`MessageService.SyncAsync` says so in a comment). So [messages] can be shorter than the
  /// requested limit — even empty — while this is true. Loop on this, never on `messages.length`.
  /// hasMore 是按过滤前的原始窗口算的，messages 可能不满页甚至为空，但仍然还有。
  final bool hasMore;
}

/// Per-message switches the sender chose. Defaults match the server's own.
class ImMessageOptions {
  const ImMessageOptions({
    this.persistent = true,
    this.updateConversation = true,
    this.countUnread = true,
    this.offlinePush = true,
    this.pushConfig,
    this.needReceipt = false,
    this.priority = ImMessagePriority.normal,
    this.onlineOnly = false,
    this.noSelfSync = false,
    this.expireIn,
    this.moderationBypass = false,
  });

  factory ImMessageOptions.fromJson(Map<String, dynamic> json) {
    if (json.isEmpty) return const ImMessageOptions();
    final Object? push = json['pushConfig'];

    return ImMessageOptions(
      persistent: json.containsKey('persistent') ? imBool(json['persistent']) : true,
      updateConversation:
          json.containsKey('updateConversation') ? imBool(json['updateConversation']) : true,
      countUnread: json.containsKey('countUnread') ? imBool(json['countUnread']) : true,
      offlinePush: json.containsKey('offlinePush') ? imBool(json['offlinePush']) : true,
      pushConfig: push is Map<String, dynamic> ? ImPushConfig.fromJson(push) : null,
      needReceipt: imBool(json['needReceipt']),
      priority: ImMessagePriority.fromWire(json['priority']),
      onlineOnly: imBool(json['onlineOnly']),
      noSelfSync: imBool(json['noSelfSync']),
      expireIn: imInt(json['expireIn']),
      moderationBypass: imBool(json['moderationBypass']),
    );
  }

  /// False writes nothing to the store, which also means [ImMessage.seq] comes back `0` and the
  /// message never touches a cursor.
  final bool persistent;

  final bool updateConversation;
  final bool countUnread;

  /// False suppresses the offline push for this one message. It does not unregister anything.
  final bool offlinePush;

  final ImPushConfig? pushConfig;

  /// Ask recipients for a read receipt. Tenant-gated: a tenant with receipts off answers
  /// [ImErrorCode.receiptDisabled].
  final bool needReceipt;

  final ImMessagePriority priority;

  /// Deliver only to sockets that are open right now. Implies no offline push and, in practice,
  /// `seq == 0`.
  final bool onlineOnly;

  /// Do not echo this message to the sender's own other devices.
  final bool noSelfSync;

  /// Burn-after-reading lifetime in ms, from first read.
  final int? expireIn;

  /// Skip the moderation callback. Only a privileged tenant configuration honours it.
  final bool moderationBypass;

  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'persistent': persistent,
        'updateConversation': updateConversation,
        'countUnread': countUnread,
        'offlinePush': offlinePush,
        'pushConfig': pushConfig?.toJson(),
        'needReceipt': needReceipt,
        'priority': priority.wireValue,
        'onlineOnly': onlineOnly,
        'noSelfSync': noSelfSync,
        'expireIn': expireIn,
        'moderationBypass': moderationBypass,
      });
}

/// Overrides for the notification this message raises on a device that is offline.
class ImPushConfig {
  const ImPushConfig({
    this.title,
    this.body,
    this.sound,
    this.payload,
    this.badgeCount = true,
    this.channelId,
  });

  factory ImPushConfig.fromJson(Map<String, dynamic> json) => ImPushConfig(
        title: imString(json['title']),
        body: imString(json['body']),
        sound: imString(json['sound']),
        payload: imStringMap(json['payload']),
        badgeCount: json.containsKey('badgeCount') ? imBool(json['badgeCount']) : true,
        channelId: imString(json['channelId']),
      );

  final String? title;
  final String? body;
  final String? sound;

  /// Extra key/values delivered with the notification, for deep linking.
  final Map<String, String>? payload;

  /// Whether this message increments the app badge.
  final bool badgeCount;

  /// Android notification channel.
  final String? channelId;

  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'title': title,
        'body': body,
        'sound': sound,
        'payload': payload,
        'badgeCount': badgeCount,
        'channelId': channelId,
      });
}

// ---------------------------------------------------------------------------- user (T1)

/// Multi-device login policy, per user, overriding the app's default.
extension type const ImMultiLoginPolicy(int wireValue) {
  static const ImMultiLoginPolicy allowAll = ImMultiLoginPolicy(0);
  static const ImMultiLoginPolicy onePerPlatform = ImMultiLoginPolicy(1);
  static const ImMultiLoginPolicy oneMobileOneDesktopOneWeb = ImMultiLoginPolicy(2);
  static const ImMultiLoginPolicy singleDevice = ImMultiLoginPolicy(3);

  static const List<ImMultiLoginPolicy> values = <ImMultiLoginPolicy>[
    allowAll,
    onePerPlatform,
    oneMobileOneDesktopOneWeb,
    singleDevice
  ];

  static ImMultiLoginPolicy fromWire(Object? value) => ImMultiLoginPolicy(imIntOr(value));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        0 => 'allowAll',
        1 => 'onePerPlatform',
        2 => 'oneMobileOneDesktopOneWeb',
        3 => 'singleDevice',
        _ => 'multiLoginPolicy($wireValue)',
      };
}

/// A user, as any client may see them. The server's `UserProfile`.
///
/// Contact details are hashes, never the values: the platform stores `phoneHash` so a tenant can
/// implement "find by phone number" without the platform holding the number.
class ImUserProfile {
  const ImUserProfile({
    required this.appId,
    required this.userId,
    this.nickname,
    this.avatar,
    this.gender = 0,
    this.birthday,
    this.signature,
    this.phoneHash,
    this.emailHash,
    this.silencedUntil,
    this.banned = false,
    this.multiLoginOverride,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.extensions = const <String, dynamic>{},
  });

  factory ImUserProfile.fromJson(Map<String, dynamic> json) => ImUserProfile(
        appId: imStringOr(json['appId']),
        userId: imStringOr(json['userId']),
        nickname: imString(json['nickname']),
        avatar: imString(json['avatar']),
        gender: imIntOr(json['gender']),
        birthday: imString(json['birthday']),
        signature: imString(json['signature']),
        phoneHash: imString(json['phoneHash']),
        emailHash: imString(json['emailHash']),
        silencedUntil: imInt(json['silencedUntil']),
        banned: imBool(json['banned']),
        multiLoginOverride: json['multiLoginOverride'] == null
            ? null
            : ImMultiLoginPolicy.fromWire(json['multiLoginOverride']),
        createdAt: imIntOr(json['createdAt']),
        updatedAt: imIntOr(json['updatedAt']),
        extensions: imMap(json['extensions']),
      );

  final String appId;
  final String userId;
  final String? nickname;

  /// Object key or URL, as the tenant chose. The platform does not interpret it.
  final String? avatar;

  /// Tenant-defined. The platform stores the number and attaches no meaning to it.
  final int gender;

  final String? birthday;
  final String? signature;

  /// Hash, never the phone number itself.
  final String? phoneHash;

  /// Hash, never the address itself.
  final String? emailHash;

  /// Muted platform-wide until this unix-ms instant. Null when not silenced.
  final int? silencedUntil;

  final bool banned;

  /// Per-user override of the app's multi-device policy. Null means "use the app default".
  final ImMultiLoginPolicy? multiLoginOverride;

  final int createdAt;
  final int updatedAt;

  /// Tenant-defined fields. `user.updateProfile` patches these by key.
  final Map<String, dynamic> extensions;

  @override
  String toString() => 'ImUserProfile($userId${nickname == null ? '' : ', $nickname'})';
}

/// A user's live presence. The server's `PresenceState`.
class ImPresenceState {
  const ImPresenceState({
    required this.userId,
    required this.online,
    this.platforms = const <ImPlatform>[],
    this.lastSeen = 0,
    this.customStatus,
  });

  factory ImPresenceState.fromJson(Map<String, dynamic> json) {
    final Object? platforms = json['platforms'];
    return ImPresenceState(
      userId: imStringOr(json['userId']),
      online: imBool(json['online']),
      platforms: <ImPlatform>[
        if (platforms is List)
          for (final Object? element in platforms) ImPlatform.fromWire(element),
      ],
      lastSeen: imIntOr(json['lastSeen']),
      customStatus: imString(json['customStatus']),
    );
  }

  final String userId;
  final bool online;

  /// Every platform the user currently has a live socket on. Empty when offline.
  final List<ImPlatform> platforms;

  /// Unix ms of the last time they were seen. Meaningful when [online] is false.
  final int lastSeen;

  /// Free text the user set, e.g. "in a meeting".
  final String? customStatus;
}

// ---------------------------------------------------------------------------- media (T1)

/// A short-lived presigned upload. The server chooses [objectKey] so a client cannot write outside
/// its own tenant and user prefix.
///
/// The upload goes **straight to object storage**, never through the gateway. Put the bytes at
/// [uploadUrl] (including [formFields] where the backend is form-based), then send a message whose
/// `content` carries [objectKey] — never a URL. Messages hold keys so every reader signs their own
/// short-lived link, which is what makes expiry and revocation possible at all; a URL baked into a
/// message is public forever the moment it leaks.
///
/// 消息里存 object key 而不是 URL：每个读者单独签发短期链接，撤销与鉴权才有可能。
class ImMediaUploadTicket {
  const ImMediaUploadTicket({
    required this.objectKey,
    required this.uploadUrl,
    required this.downloadUrl,
    required this.expiresAt,
    this.formFields = const <String, String>{},
  });

  factory ImMediaUploadTicket.fromJson(Map<String, dynamic> json) => ImMediaUploadTicket(
        objectKey: imStringOr(json['objectKey']),
        uploadUrl: imStringOr(json['uploadUrl']),
        downloadUrl: imStringOr(json['downloadUrl']),
        formFields: imStringMap(json['formFields']),
        expiresAt: imIntOr(json['expiresAt']),
      );

  /// Put this in the message `content`. It is the durable identity of the object.
  final String objectKey;

  /// Presigned PUT (or POST) target. Expires — see [expiresAt].
  final String uploadUrl;

  /// A download link valid now. Do not store it: call `media.downloadUrl` when you need one.
  final String downloadUrl;

  /// Extra fields a form-based backend requires alongside the file part.
  final Map<String, String> formFields;

  /// Unix ms after which [uploadUrl] stops working.
  final int expiresAt;
}

// ---------------------------------------------------------------------------- conv (T2)

/// The per-user settings `conv.setting` writes. Every field is optional and only the ones you set
/// are changed — this is a patch, not a replacement.
class ImConversationSetting {
  const ImConversationSetting({
    this.pinned,
    this.muted,
    this.draft,
    this.tags,
    this.extensions,
  });

  factory ImConversationSetting.fromJson(Map<String, dynamic> json) => ImConversationSetting(
        pinned: json['pinned'] == null ? null : imBool(json['pinned']),
        muted: json['muted'] == null ? null : ImMuteMode.fromWire(json['muted']),
        draft: imString(json['draft']),
        tags: json['tags'] == null ? null : imStringList(json['tags']),
        extensions: imMapOrNull(json['extensions']),
      );

  final bool? pinned;
  final ImMuteMode? muted;

  /// Unsent text, synced across the user's devices.
  final String? draft;

  /// The tags conversation folders filter on.
  final List<String>? tags;

  final Map<String, dynamic>? extensions;

  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'pinned': pinned,
        'muted': muted?.wireValue,
        'draft': draft,
        'tags': tags,
        'extensions': extensions,
      });
}

// ---------------------------------------------------------------------------- friend (T2)

/// Outcome of a friend or group application.
extension type const ImApplicationStatus(int wireValue) {
  static const ImApplicationStatus pending = ImApplicationStatus(0);
  static const ImApplicationStatus accepted = ImApplicationStatus(1);
  static const ImApplicationStatus rejected = ImApplicationStatus(2);
  static const ImApplicationStatus expired = ImApplicationStatus(3);

  static const List<ImApplicationStatus> values = <ImApplicationStatus>[
    pending,
    accepted,
    rejected,
    expired
  ];

  static ImApplicationStatus fromWire(Object? value) => ImApplicationStatus(imIntOr(value));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        0 => 'pending',
        1 => 'accepted',
        2 => 'rejected',
        3 => 'expired',
        _ => 'applicationStatus($wireValue)',
      };
}

/// One row of the caller's contact list. The server's `Friend`.
class ImFriend {
  const ImFriend({
    required this.appId,
    required this.userId,
    required this.friendUserId,
    this.remark,
    this.tags = const <String>[],
    this.source,
    this.addTime = 0,
    this.extensions = const <String, dynamic>{},
  });

  factory ImFriend.fromJson(Map<String, dynamic> json) => ImFriend(
        appId: imStringOr(json['appId']),
        userId: imStringOr(json['userId']),
        friendUserId: imStringOr(json['friendUserId']),
        remark: imString(json['remark']),
        tags: imStringList(json['tags']),
        source: imString(json['source']),
        addTime: imIntOr(json['addTime']),
        extensions: imMap(json['extensions']),
      );

  final String appId;

  /// The owner of this contact row — the caller.
  final String userId;

  /// The contact. Resolve the profile with `user.batchProfile`, not one call per row.
  final String friendUserId;

  /// The name the caller gave them, which the UI shows in place of the nickname.
  final String? remark;

  final List<String> tags;

  /// Where the relationship came from: `search`, `qrcode`, `group`, anything the tenant chose.
  final String? source;

  final int addTime;
  final Map<String, dynamic> extensions;
}

/// A pending or settled friend application. The server's `FriendRequest`.
class ImFriendRequest {
  const ImFriendRequest({
    required this.appId,
    required this.fromUserId,
    required this.toUserId,
    required this.status,
    this.greeting,
    this.source,
    this.handleReason,
    this.createdAt = 0,
    this.handledAt,
  });

  factory ImFriendRequest.fromJson(Map<String, dynamic> json) => ImFriendRequest(
        appId: imStringOr(json['appId']),
        fromUserId: imStringOr(json['fromUserId']),
        toUserId: imStringOr(json['toUserId']),
        greeting: imString(json['greeting']),
        source: imString(json['source']),
        status: ImApplicationStatus.fromWire(json['status']),
        handleReason: imString(json['handleReason']),
        createdAt: imIntOr(json['createdAt']),
        handledAt: imInt(json['handledAt']),
      );

  final String appId;
  final String fromUserId;
  final String toUserId;
  final String? greeting;
  final String? source;
  final ImApplicationStatus status;
  final String? handleReason;
  final int createdAt;
  final int? handledAt;
}

/// One row of the caller's blocklist. The server's `BlockEntry`.
///
/// Blocking is not optional product surface: app-store review treats it as mandatory for any app
/// carrying user-generated content, which is why `friend.block` sits in the same tier as sending a
/// message at all.
class ImBlockEntry {
  const ImBlockEntry({
    required this.appId,
    required this.userId,
    required this.blockedUserId,
    this.createdAt = 0,
    this.reason,
  });

  factory ImBlockEntry.fromJson(Map<String, dynamic> json) => ImBlockEntry(
        appId: imStringOr(json['appId']),
        userId: imStringOr(json['userId']),
        blockedUserId: imStringOr(json['blockedUserId']),
        createdAt: imIntOr(json['createdAt']),
        reason: imString(json['reason']),
      );

  final String appId;
  final String userId;
  final String blockedUserId;
  final int createdAt;
  final String? reason;
}

// ---------------------------------------------------------------------------- group (T2)

/// What kind of group this is. [superGroup] is the server's `Super` — renamed only because `super`
/// is a Dart keyword.
extension type const ImGroupType(int wireValue) {
  static const ImGroupType normal = ImGroupType(1);

  /// `GroupType.Super`: tens of thousands of members, different fan-out strategy server-side.
  static const ImGroupType superGroup = ImGroupType(2);

  static const ImGroupType chatRoom = ImGroupType(3);

  static const List<ImGroupType> values = <ImGroupType>[normal, superGroup, chatRoom];

  static ImGroupType fromWire(Object? value) => ImGroupType(imIntOr(value, 1));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        1 => 'normal',
        2 => 'super',
        3 => 'chatRoom',
        _ => 'groupType($wireValue)',
      };
}

/// A member's authority in a group.
extension type const ImGroupRole(int wireValue) {
  static const ImGroupRole member = ImGroupRole(1);
  static const ImGroupRole admin = ImGroupRole(2);
  static const ImGroupRole owner = ImGroupRole(3);

  static const List<ImGroupRole> values = <ImGroupRole>[member, admin, owner];

  static ImGroupRole fromWire(Object? value) => ImGroupRole(imIntOr(value, 1));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        1 => 'member',
        2 => 'admin',
        3 => 'owner',
        _ => 'groupRole($wireValue)',
      };
}

/// How a stranger gets in.
extension type const ImGroupJoinMode(int wireValue) {
  static const ImGroupJoinMode freeAccess = ImGroupJoinMode(0);
  static const ImGroupJoinMode needApproval = ImGroupJoinMode(1);
  static const ImGroupJoinMode forbidden = ImGroupJoinMode(2);

  static const List<ImGroupJoinMode> values = <ImGroupJoinMode>[
    freeAccess,
    needApproval,
    forbidden
  ];

  static ImGroupJoinMode fromWire(Object? value) => ImGroupJoinMode(imIntOr(value));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        0 => 'freeAccess',
        1 => 'needApproval',
        2 => 'forbidden',
        _ => 'groupJoinMode($wireValue)',
      };
}

/// Who may add someone else.
extension type const ImGroupInviteMode(int wireValue) {
  static const ImGroupInviteMode allMembers = ImGroupInviteMode(0);
  static const ImGroupInviteMode adminsOnly = ImGroupInviteMode(1);
  static const ImGroupInviteMode forbidden = ImGroupInviteMode(2);

  static const List<ImGroupInviteMode> values = <ImGroupInviteMode>[
    allMembers,
    adminsOnly,
    forbidden
  ];

  static ImGroupInviteMode fromWire(Object? value) => ImGroupInviteMode(imIntOr(value));

  bool get isKnown => values.contains(this);

  String get name => switch (wireValue) {
        0 => 'allMembers',
        1 => 'adminsOnly',
        2 => 'forbidden',
        _ => 'groupInviteMode($wireValue)',
      };
}

/// A group. The server's `Group`.
class ImGroup {
  const ImGroup({
    required this.appId,
    required this.groupId,
    required this.name,
    required this.ownerId,
    this.type = ImGroupType.normal,
    this.avatar,
    this.introduction,
    this.announcement,
    this.announcementUpdatedAt,
    this.memberCount = 0,
    this.maxMemberCount = 0,
    this.joinMode = ImGroupJoinMode.freeAccess,
    this.inviteMode = ImGroupInviteMode.allMembers,
    this.muteAll = false,
    this.muteEndTime,
    this.dismissed = false,
    this.createdAt = 0,
    this.updatedAt = 0,
    this.extensions = const <String, dynamic>{},
  });

  factory ImGroup.fromJson(Map<String, dynamic> json) => ImGroup(
        appId: imStringOr(json['appId']),
        groupId: imStringOr(json['groupId']),
        type: ImGroupType.fromWire(json['type']),
        name: imStringOr(json['name']),
        avatar: imString(json['avatar']),
        introduction: imString(json['introduction']),
        announcement: imString(json['announcement']),
        announcementUpdatedAt: imInt(json['announcementUpdatedAt']),
        ownerId: imStringOr(json['ownerId']),
        memberCount: imIntOr(json['memberCount']),
        maxMemberCount: imIntOr(json['maxMemberCount']),
        joinMode: ImGroupJoinMode.fromWire(json['joinMode']),
        inviteMode: ImGroupInviteMode.fromWire(json['inviteMode']),
        muteAll: imBool(json['muteAll']),
        muteEndTime: imInt(json['muteEndTime']),
        dismissed: imBool(json['dismissed']),
        createdAt: imIntOr(json['createdAt']),
        updatedAt: imIntOr(json['updatedAt']),
        extensions: imMap(json['extensions']),
      );

  final String appId;
  final String groupId;
  final ImGroupType type;
  final String name;
  final String? avatar;
  final String? introduction;
  final String? announcement;
  final int? announcementUpdatedAt;
  final String ownerId;
  final int memberCount;
  final int maxMemberCount;
  final ImGroupJoinMode joinMode;
  final ImGroupInviteMode inviteMode;

  /// Everyone but owner and admins is muted.
  final bool muteAll;

  /// When [muteAll] lifts, unix ms. Null means indefinitely.
  final int? muteEndTime;

  /// The group was dismissed. It stays readable so a client can render the history it already has.
  final bool dismissed;

  final int createdAt;
  final int updatedAt;
  final Map<String, dynamic> extensions;

  @override
  String toString() => 'ImGroup($groupId, "$name", $memberCount members)';
}

/// One member of a group. The server's `GroupMember`.
class ImGroupMember {
  const ImGroupMember({
    required this.appId,
    required this.groupId,
    required this.userId,
    this.role = ImGroupRole.member,
    this.nickname,
    this.muteEndTime,
    this.joinTime = 0,
    this.joinSource,
    this.extensions = const <String, dynamic>{},
  });

  factory ImGroupMember.fromJson(Map<String, dynamic> json) => ImGroupMember(
        appId: imStringOr(json['appId']),
        groupId: imStringOr(json['groupId']),
        userId: imStringOr(json['userId']),
        role: ImGroupRole.fromWire(json['role']),
        nickname: imString(json['nickname']),
        muteEndTime: imInt(json['muteEndTime']),
        joinTime: imIntOr(json['joinTime']),
        joinSource: imString(json['joinSource']),
        extensions: imMap(json['extensions']),
      );

  final String appId;
  final String groupId;
  final String userId;
  final ImGroupRole role;

  /// The name this member uses in this group, which overrides their profile nickname here only.
  final String? nickname;

  /// Individually muted until this unix-ms instant. Null when not muted.
  final int? muteEndTime;

  final int joinTime;
  final String? joinSource;
  final Map<String, dynamic> extensions;
}

// ---------------------------------------------------------------------------- moderation (T2)

/// `moderation.report`. What the reporting client gets back — deliberately two fields.
///
/// Not the stored row: a reporter has no business reading back the moderation state of their own
/// report, and the row carries fields (`handledBy`, `resolution`) that belong to the tenant's
/// moderators. Keep [reportId] anyway: it is the only handle either side has on this report
/// afterwards, and a user asking "what happened to my report" is asking about that string.
///
/// 回执而不是那一行：举报人没有理由读回自己举报的审核状态，而那一行上还带着内部字段。
class ImReportReceipt {
  const ImReportReceipt({required this.reportId, this.createdAt = 0});

  factory ImReportReceipt.fromJson(Map<String, dynamic> json) => ImReportReceipt(
        reportId: imStringOr(json['reportId']),
        createdAt: imIntOr(json['createdAt']),
      );

  /// The server's `rp_…` handle for this report.
  final String reportId;

  /// When the report was filed, unix ms on the server's clock.
  final int createdAt;
}
