/// `room.*` — chat rooms (T4): their requests, what they answer, and the `room.*` events that
/// arrive inside `evt.system`. [ImRoomApi] is the surface that sends them.
///
/// In a file of its own because the family is typed whole or not at all (`sdk/CONTRACT.md` §3), and
/// a reader looking for "what does a room send and get back" should find one place.
///
/// **A room message is best-effort and carries `seq` 0.** It arrives on `ImClient.messages` as an
/// ordinary [ImMessage] whose [ImMessage.conversationId] is `r_<roomId>` and whose
/// [ImMessage.conversationType] is [ImConversationType.chatRoom], and it never enters gap repair or
/// moves a cursor: a room has no range anybody could ask for again, so a seq would be a promise
/// broken on every dropped frame. A dropped room frame is gone; [ImRoomJoinResult.recent] is a
/// ring buffer for newcomers, not a repair path.
///
/// **Membership belongs to the connection, not to the user.** After a reconnect the server no
/// longer counts this socket in the room; call `room.join` again. This package does not rejoin on
/// its own, because it cannot know which rooms the screen in front of the user still shows.
///
/// **Rooms are created by the tenant's backend** (`POST /v1/rooms`) and destroyed by it
/// (`DELETE /v1/rooms/{id}`); there is no socket call for either.
///
/// 聊天室消息尽力而为、seq 恒为 0：它照常出现在 messages 里（conversationId 为 `r_<roomId>`），
/// 但不进补洞、不动游标。成员身份属于连接：重连之后要重新 room.join，本包不替应用自动重进。
/// 房间只能由租户后端经 REST 创建与销毁。
library;

import 'api.dart' show ImRoomApi;
import 'json.dart';
import 'protocol.dart';
import 'requests.dart';

// ---------------------------------------------------------------------------- the room id

/// The one rule that joins a room id to the messages it carries.
abstract final class ImRoom {
  /// The prefix the server puts in front of a room id to make the conversation id of every
  /// message sent into it (`Conversation.RoomIdOf`).
  static const String conversationPrefix = 'r_';

  /// `r_<roomId>` — the [ImMessage.conversationId] of a message sent into [roomId].
  static String conversationIdOf(String roomId) => '$conversationPrefix$roomId';

  /// The room a message was sent into, or null when [conversationId] is not a room's.
  ///
  /// Use it to route [ImMessage]s off `ImClient.messages`: a room's traffic shares that stream with
  /// every conversation, and only this prefix (with [ImConversationType.chatRoom]) tells it apart.
  static String? roomIdOf(String conversationId) {
    if (!conversationId.startsWith(conversationPrefix)) return null;
    final String roomId = conversationId.substring(conversationPrefix.length);
    return roomId.isEmpty ? null : roomId;
  }
}

// ---------------------------------------------------------------------------- requests

/// `room.join`, `room.quit` and `room.onlineCount`. The server's `RoomIdRequest`.
class ImRoomIdRequest implements ImRequestBody {
  const ImRoomIdRequest({required this.roomId});

  /// The tenant-chosen id the room was created with. Empty is `1001`.
  final String roomId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'roomId': roomId};
}

/// `room.memberList`. The server's `RoomCursorRequest`.
///
/// **What comes back is a sample, not the roster.** The server walks its membership shards one page
/// at a time and never promises an exact or complete list of a room that may hold a million
/// viewers — render it as "who is here", never as "everyone who is here".
class ImRoomCursorRequest implements ImRequestBody {
  const ImRoomCursorRequest({required this.roomId, this.cursor, this.limit = 50});

  final String roomId;

  /// The previous page's [ImPage.nextCursor]; null for the first page.
  final String? cursor;

  /// The server clamps to 1…100; anything outside becomes 50.
  final int limit;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'roomId': roomId,
        'cursor': cursor,
        'limit': limit,
      });
}

/// The message half of a `room.send`: the members of the server's `SendMessageRequest` a room
/// actually reads.
///
/// **Narrower than [ImSendMessageRequest], on purpose** — as in the TypeScript and Kotlin SDKs. The
/// room is the address, so there is no `conversationId` / `receiverId` / `groupId` /
/// `conversationType`; a room message is never stored, so there is nothing to quote or thread
/// under; and of the options only the [priority] means anything. The server would bind the rest
/// and then ignore it, and a field that is accepted and ignored is a field somebody will rely on.
/// Whatever is sent, the server stamps the message with `conversationId` `r_<roomId>`,
/// `conversationType` 3, `seq` 0 and online-only options.
///
/// **These keys travel nested under `message`**, where the server's binder matches member names
/// case-sensitively and drops a miscased one without a word (a hand-written `ClientMsgId` is
/// dropped, and the send fails `1001` for a field that looks present) — which is why the body is
/// built here rather than from a map.
///
/// 只含聊天室真正读取的字段，与 TypeScript、Kotlin 一致：房间就是地址，消息不入库、无从引用，
/// options 里只有 priority 有意义。这些键嵌套在 message 里，服务端按大小写精确匹配，手写错了会被静默丢掉。
class ImRoomMessage {
  ImRoomMessage({
    required this.content,
    this.contentType = ImMessageContentType.text,
    String? clientMsgId,
    this.mentionAll = false,
    this.mentionedUserIds,
    this.priority,
    int? sendTime,
    this.extensions,
  })  : clientMsgId = clientMsgId ?? imNewClientMsgId(),
        sendTime = sendTime ?? DateTime.now().millisecondsSinceEpoch;

  /// Plain text.
  factory ImRoomMessage.text(
    String text, {
    String? clientMsgId,
    List<String>? mentionedUserIds,
    bool mentionAll = false,
    ImMessagePriority? priority,
  }) =>
      ImRoomMessage(
        content: <String, dynamic>{'text': text},
        clientMsgId: clientMsgId,
        mentionedUserIds: mentionedUserIds,
        mentionAll: mentionAll,
        priority: priority,
      );

  /// Shaped by [contentType], and free-form for a custom type (a gift, an emote).
  final Map<String, dynamic> content;

  final ImMessageContentType contentType;

  /// Idempotency key, **required by the server** (`1001` without one) and generated when you do not
  /// supply one.
  final String clientMsgId;

  final bool mentionAll;
  final List<String>? mentionedUserIds;

  /// The one option a room reads. **A room over its per-second budget sheds
  /// [ImMessagePriority.low] first**, while there is still headroom for everything above it, and
  /// answers `1003`: send emotes, gifts and reactions low so the host's words are not the ones
  /// dropped. Null leaves the server's default, normal. Goes out as `options.priority`.
  /// 房间超预算时先丢低优先级——表情、礼物请发 low。
  final ImMessagePriority? priority;

  /// Sender's own clock, unix ms. Display only; the server stamps `createTime` itself.
  final int sendTime;

  final Map<String, dynamic>? extensions;

  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'clientMsgId': clientMsgId,
        'contentType': contentType.wireValue,
        'content': content,
        'mentionAll': mentionAll,
        'mentionedUserIds': mentionedUserIds,
        'options': priority == null ? null : <String, Object?>{'priority': priority!.wireValue},
        'sendTime': sendTime,
        'extensions': extensions,
      });
}

/// `room.send`. The server's `RoomSendRequest`: a room id and an [ImRoomMessage].
///
/// The caller must have joined the room on this connection (`1602` otherwise, including after a
/// kick); a muted member is `1506`, anyone but the owner and admins during a room-wide mute `1603`.
class ImRoomSendRequest implements ImRequestBody {
  const ImRoomSendRequest({required this.roomId, required this.message});

  /// Plain text into [roomId], optionally at [priority].
  factory ImRoomSendRequest.text(
    String roomId,
    String text, {
    String? clientMsgId,
    List<String>? mentionedUserIds,
    bool mentionAll = false,
    ImMessagePriority? priority,
  }) =>
      ImRoomSendRequest(
        roomId: roomId,
        message: ImRoomMessage.text(
          text,
          clientMsgId: clientMsgId,
          mentionedUserIds: mentionedUserIds,
          mentionAll: mentionAll,
          priority: priority,
        ),
      );

  final String roomId;

  final ImRoomMessage message;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
        'roomId': roomId,
        'message': message.toJson(),
      };
}

/// `room.mute`. The server's `RoomMuteRequest`; only the room's owner or one of its
/// [ImChatRoom.admins] may send it (`1103` otherwise), and nobody can mute the owner (`1511`).
///
/// **One request both mutes and unmutes, and [untilMs] decides which**: a unix-ms deadline in the
/// future mutes until then; null, or a time already past, lifts the mute. That is why [untilMs] is
/// a required parameter even though it is nullable — `ImRoomMuteRequest(roomId: …)` reading as
/// "mute" while it unmutes is the mistake this signature refuses to let anyone make by omission.
/// [ImRoomMuteRequest.unmute] says the other half out loud.
///
/// **[userId] null means the whole room.** Owner and admins speak through a room-wide mute; a
/// muted member's send is `1506`, everybody else's during a room-wide mute is `1603`.
///
/// 一个请求既禁言也解禁，由 untilMs 决定：未来的时刻是禁言到那时，null 或已过去的时刻是解禁——
/// 所以 untilMs 虽可空却必须显式传。userId 为 null 表示全员。
class ImRoomMuteRequest implements ImRequestBody {
  const ImRoomMuteRequest({required this.roomId, this.userId, required this.untilMs});

  /// Lifts a mute: the room-wide one when [userId] is null, that member's otherwise.
  const ImRoomMuteRequest.unmute({required this.roomId, this.userId}) : untilMs = null;

  final String roomId;

  /// The member to mute; null for the whole room.
  final String? userId;

  /// Unix ms the mute runs until. Null (or a past time) unmutes.
  final int? untilMs;

  @override
  Map<String, Object?> toJson() => imBody(<String, Object?>{
        'roomId': roomId,
        'userId': userId,
        'untilMs': untilMs,
      });
}

/// `room.kick`. The server's `RoomKickRequest`; owner or admins only (`1103`), never the owner
/// (`1511`).
///
/// The kicked member's next send is `1602`. Their client hears `room.kicked` on
/// `ImClient.roomEvents` and should leave the screen: a kick drops the member's connections on the
/// node that handled it, and another node may keep delivering to them until they act on the event
/// or reconnect.
class ImRoomKickRequest implements ImRequestBody {
  const ImRoomKickRequest({required this.roomId, required this.userId});

  final String roomId;

  /// Required: empty is `1001`.
  final String userId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'roomId': roomId, 'userId': userId};
}

// ---------------------------------------------------------------------------- responses

/// A chat room as the tenant created it. The server's `ChatRoom`.
class ImChatRoom {
  const ImChatRoom({
    required this.roomId,
    this.appId = '',
    this.name = '',
    this.avatar,
    this.ownerId = '',
    this.admins = const <String>[],
    this.maxOnline = 0,
    this.historyBufferSize = 0,
    this.rateLimitPerSecond = 0,
    this.muteAll = false,
    this.destroyed = false,
    this.createdAt = 0,
    this.extensions = const <String, dynamic>{},
  });

  factory ImChatRoom.fromJson(Map<String, dynamic> json) => ImChatRoom(
        appId: imStringOr(json['appId']),
        roomId: imStringOr(json['roomId']),
        name: imStringOr(json['name']),
        avatar: imString(json['avatar']),
        ownerId: imStringOr(json['ownerId']),
        admins: imStringList(json['admins']),
        maxOnline: imIntOr(json['maxOnline']),
        historyBufferSize: imIntOr(json['historyBufferSize']),
        rateLimitPerSecond: imIntOr(json['rateLimitPerSecond']),
        muteAll: imBool(json['muteAll']),
        destroyed: imBool(json['destroyed']),
        createdAt: imIntOr(json['createdAt']),
        extensions: imMap(json['extensions']),
      );

  final String appId;
  final String roomId;
  final String name;
  final String? avatar;

  /// May mute and kick, and can be neither muted nor kicked.
  final String ownerId;

  /// May mute and kick. Set by the tenant's backend; the socket cannot change it.
  final List<String> admins;

  /// Online ceiling; `0` means unlimited. A join at the ceiling is `1601`.
  final int maxOnline;

  /// How many recent messages a joiner receives in [ImRoomJoinResult.recent]. `0` disables it.
  final int historyBufferSize;

  /// Messages per second the room as a whole accepts before shedding low priority.
  final int rateLimitPerSecond;

  /// True while a room-wide mute is in force — a projection of the stored deadline, read at the
  /// moment the server answered.
  final bool muteAll;

  final bool destroyed;

  /// Unix ms.
  final int createdAt;

  final Map<String, dynamic> extensions;
}

/// What `room.join` answers: the room, how many are in it, and what it said just before.
/// The server's `RoomJoinResult`.
class ImRoomJoinResult {
  const ImRoomJoinResult({
    required this.room,
    this.onlineCount = 0,
    this.recent = const <ImMessage>[],
  });

  factory ImRoomJoinResult.fromJson(Map<String, dynamic> json) => ImRoomJoinResult(
        room: ImChatRoom.fromJson(imMap(json['room'])),
        onlineCount: imIntOr(json['onlineCount']),
        recent: imList<ImMessage>(json['recent'], ImMessage.fromJson),
      );

  final ImChatRoom room;

  /// Online count including this connection, at the moment of joining.
  final int onlineCount;

  /// The room's ring buffer, **oldest first**, each with `seq` 0. Returned here and only here:
  /// this package does not replay it onto `ImClient.messages`, so render it before the live
  /// stream and deduplicate on [ImMessage.messageId] where the two overlap.
  final List<ImMessage> recent;
}

// ---------------------------------------------------------------------------- room.* events

/// One `room.*` event, as `ImClient.roomEvents` delivers it.
///
/// They arrive inside `evt.system` as `{"event": "room.…", "body": {…}}`, beside events that are
/// not about rooms at all (`device.logRequest`); only names starting with `room.` are decoded here,
/// and the others are left to whoever handles them. A `room.` name this build does not know is
/// still delivered, with its [body] intact, rather than dropped: a newer server announcing
/// something about a room the user is looking at is worth seeing.
///
/// 聊天室事件经 evt.system 到达，与 device.logRequest 等共用；这里只解码 `room.` 开头的事件名，
/// 不认识的 `room.*` 事件原样交出（body 完整）而不丢弃。
class ImRoomEvent {
  const ImRoomEvent({
    required this.event,
    required this.roomId,
    this.operatorId = '',
    this.userId,
    this.untilMs,
    this.body = const <String, dynamic>{},
  });

  /// A mute changed. [userId] null means the room-wide mute; [untilMs] null or past means it was
  /// lifted.
  static const String muted = 'room.muted';

  /// [userId] was removed from the room. When that is this user, leave the screen: the server
  /// has stopped accepting their sends (`1602`).
  static const String kicked = 'room.kicked';

  /// The tenant's backend destroyed the room. From now on `room.join`, `room.send`, `room.mute`
  /// and `room.kick` on it are `1600`; `room.onlineCount` answers 0, `room.memberList` an empty
  /// sample, and `room.quit` still succeeds — so this event, not a polled count, is how to notice.
  static const String destroyed = 'room.destroyed';

  /// The three names the server raises today.
  static const List<String> known = <String>[muted, kicked, destroyed];

  static const String _prefix = 'room.';

  /// Decodes an `evt.system` payload, or returns null for anything that is not a `room.*` event.
  static ImRoomEvent? tryParse(Object? data) {
    final Map<String, dynamic>? json = imMapOrNull(data);
    if (json == null) return null;

    final String? event = imString(json['event']);
    if (event == null || !event.startsWith(_prefix)) return null;

    final Map<String, dynamic> body = imMap(json['body']);
    return ImRoomEvent(
      event: event,
      roomId: imStringOr(body['roomId']),
      operatorId: imStringOr(body['operatorId']),
      userId: imString(body['userId']),
      untilMs: imInt(body['untilMs']),
      body: body,
    );
  }

  /// One of [known], or a `room.` name a newer server added.
  final String event;

  final String roomId;

  /// Who did it: the owner, an admin, or the tenant's backend.
  final String operatorId;

  /// `room.muted`: the member muted, null for the whole room. `room.kicked`: who was removed.
  final String? userId;

  /// `room.muted`: unix ms the mute runs until; null (or a past time) when it was lifted.
  final int? untilMs;

  /// The whole payload as the server sent it, for a field or an event this build does not type.
  final Map<String, dynamic> body;

  bool get isKnown => known.contains(event);
}
