import Foundation

// `room.*` — chat rooms (T4): their requests, what they answer, and the `room.*` events that arrive
// inside `evt.system`. ``ImRoomNamespace`` is the surface that sends them.
//
// In a file of its own, as the desk is, because the family is typed whole or not at all
// (CONTRACT.md §3), and a reader looking for "what does a room send and get back" should find one
// place. The namespace itself lives in Namespaces.swift with the others, where
// `NamespacedSurfaceTests` reads it.
//
// **A room message is best effort and has no seq.** It arrives on `evt.message` as an ordinary
// ``ImMessage`` whose `seq` is **0** and whose `conversationId` is `r_<roomId>`. Nothing is stored
// per user, nothing is pushed offline, and there is no range to repair: ``ImClient`` hands it straight
// to ``ImClient/messages()`` — ahead of the serial repair lane, so it never waits behind another
// conversation's repair — and never lets it near a cursor. Do not commit it; ``ImClient/commit(_:seq:)``
// ignores a seq of 0 for that reason.
//
// 聊天室消息尽力而为、没有 seq：它是 evt.message 上一条 seq 为 0、conversationId 为 r_<roomId> 的普通消息。
// 不按人存储、不发离线推送、没有可补的区间——ImClient 在补洞队列之前就把它交给 messages()，
// 绝不让它碰游标，也不让它排在别的会话的补洞后面。不要 commit 它。

// MARK: - Requests

/// `room.join`, `room.quit` and `room.onlineCount`: the room, and nothing else.
///
/// **Membership belongs to this connection, not to the user.** After a reconnect the server no longer
/// counts this device as present and nothing is delivered until `room.join` is sent again. The SDK
/// does not rejoin for you — which rooms are still on screen is the application's knowledge.
///
/// 成员身份属于这条连接而不是这个用户：重连之后要重新 room.join，SDK 不替你重进。
public struct RoomIdRequest: Encodable, Sendable, Hashable {
    public var roomId: String

    public init(roomId: String) {
        self.roomId = roomId
    }

    public init(_ roomId: String) {
        self.roomId = roomId
    }
}

/// `room.memberList`. **A sample of who is present, not the full list** — the server never
/// enumerates a large room exactly. Page on ``Page/hasMore`` / ``Page/nextCursor`` like every other
/// list.
public struct RoomCursorRequest: Encodable, Sendable, Hashable {
    public var roomId: String

    /// Opaque; pass back ``Page/nextCursor`` verbatim. `nil` for the first page.
    public var cursor: String?

    /// The server clamps it: 1–100 is honoured, anything else becomes 50.
    public var limit: Int

    public init(roomId: String, cursor: String? = nil, limit: Int = 50) {
        self.roomId = roomId
        self.cursor = cursor
        self.limit = limit
    }
}

/// The message half of a `room.send` — the members of the server's `SendMessageRequest` that a room
/// reads, and no others.
///
/// Not ``SendMessageRequest``: a room message has no receiver, no group, no conversation to name (the
/// room is ``RoomSendRequest/roomId``) and nothing to quote or thread under, and a field the server
/// ignores is a field someone will set and wonder about. The names are the server's and are matched
/// **case-sensitively** inside `message`, so they are not something to rename.
///
/// ``clientMsgId`` is required by the server (`1001` without it). It is minted when the message is
/// built, as ``SendMessageRequest`` mints its own, so retrying the same request reuses it; a blank one
/// is filled in by ``ImRoomNamespace/send(_:)``, and a ``sendTime`` of 0 or below is stamped there.
///
/// 只含聊天室真正读取的字段。message 里的键按大小写精确匹配，名字不能改；clientMsgId 构造时生成，留空由 SDK 补上。
public struct RoomMessage: Encodable, Sendable, Hashable {
    /// Shaped by ``contentType``; for a text message, `["text": …]` — see ``text(_:)``.
    public var content: [String: JSONValue]

    /// An integer on the wire.
    public var contentType: MessageContentType

    /// The idempotency key. A blank one is filled in by ``ImRoomNamespace/send(_:)``.
    public var clientMsgId: String

    public var mentionAll: Bool

    public var mentionedUserIds: [String]

    /// Only ``MessageOptions/priority`` is read on this path: the room sheds `.low` first when it is
    /// over its rate. A room message is never stored or pushed offline whatever else is set here.
    public var options: MessageOptions?

    /// Client clock, unix ms. 0 or below is stamped by ``ImRoomNamespace/send(_:)``; the server keeps
    /// its own `createTime`.
    public var sendTime: Int64

    public var extensions: [String: JSONValue]?

    public init(
        content: [String: JSONValue],
        contentType: MessageContentType = .text,
        clientMsgId: String = ClientMessageId.generate(),
        mentionAll: Bool = false,
        mentionedUserIds: [String] = [],
        options: MessageOptions? = nil,
        sendTime: Int64 = ImClock.nowMilliseconds(),
        extensions: [String: JSONValue]? = nil
    ) {
        self.content = content
        self.contentType = contentType
        self.clientMsgId = clientMsgId
        self.mentionAll = mentionAll
        self.mentionedUserIds = mentionedUserIds
        self.options = options
        self.sendTime = sendTime
        self.extensions = extensions
    }

    /// A text message, the common case.
    public static func text(_ text: String) -> RoomMessage {
        RoomMessage(content: ["text": .string(text)])
    }
}

/// `room.send`. The caller must have joined the room on this connection (`1602 NotInRoom` otherwise).
public struct RoomSendRequest: Encodable, Sendable, Hashable {
    public var roomId: String
    public var message: RoomMessage

    public init(roomId: String, message: RoomMessage) {
        self.roomId = roomId
        self.message = message
    }
}

/// `room.mute`. Room owner or room admins only (`1103` otherwise), and never the owner (`1511`).
///
/// **Both optional members mean something when absent, and the absence is the dangerous half**, so
/// neither has a default in the initialiser: write `nil` on purpose.
///
/// - ``userId`` `nil` mutes **the whole room** (the owner and admins can still speak); a user id
///   mutes that member alone.
/// - ``untilMs`` `nil`, or a time already past, **lifts** the mute. A mute is always "until when".
///
/// `nil` leaves the key out of the body; it is never sent as JSON `null`.
///
/// 两个可选成员缺省时都有含义，而且缺省那一半是危险的，所以初始化器不给默认值：userId 为 nil 是全员禁言；
/// untilMs 为 nil 或已过去的时刻是解除禁言。nil 不写进请求体，也从不写成 null。
public struct RoomMuteRequest: Encodable, Sendable, Hashable {
    public var roomId: String

    /// `nil` is the whole room.
    public var userId: String?

    /// Unix ms the mute ends. `nil`, or a past time, lifts it.
    public var untilMs: Int64?

    public init(roomId: String, userId: String?, untilMs: Int64?) {
        self.roomId = roomId
        self.userId = userId
        self.untilMs = untilMs
    }
}

/// `room.kick`. Room owner or room admins only (`1103` otherwise), and never the owner (`1511`). The
/// member's sends answer `1602 NotInRoom` afterwards; the member and the room hear `room.kicked`.
public struct RoomKickRequest: Encodable, Sendable, Hashable {
    public var roomId: String
    public var userId: String

    public init(roomId: String, userId: String) {
        self.roomId = roomId
        self.userId = userId
    }
}

// MARK: - Payloads

/// A chat room as the tenant's backend created it (`POST /v1/rooms` — there is no socket call that
/// creates one). Read-only from a device: neither the name nor the admins change over the socket.
public struct ChatRoom: Decodable, Sendable, Hashable, Identifiable {
    public let appId: String
    public let roomId: String
    public let name: String
    public let avatar: String?

    /// Can mute and kick, and can never be muted or kicked.
    public let ownerId: String

    /// Can mute and kick, as the owner can.
    public let admins: [String]

    /// Connections allowed at once; 0 means unlimited. A full room answers `room.join` with `1601`.
    public let maxOnline: Int64

    /// How many recent messages a joiner receives in ``RoomJoinResult/recent``; 0 disables it.
    public let historyBufferSize: Int

    /// Messages per second the room accepts as a whole before shedding low-priority ones (`1003`).
    public let rateLimitPerSecond: Int

    /// A room-wide mute is in force: only the owner and admins can send (`1603` for everyone else).
    public let muteAll: Bool

    public let destroyed: Bool

    /// Unix ms.
    public let createdAt: Int64

    public let extensions: [String: JSONValue]?

    public var id: String { roomId }

    enum CodingKeys: String, CodingKey {
        case appId, roomId, name, avatar, ownerId, admins, maxOnline, historyBufferSize
        case rateLimitPerSecond, muteAll, destroyed, createdAt, extensions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = c.imString(.appId) ?? ""
        roomId = c.imString(.roomId) ?? ""
        name = c.imString(.name) ?? ""
        avatar = c.imString(.avatar)
        ownerId = c.imString(.ownerId) ?? ""
        admins = c.imStrings(.admins) ?? []
        maxOnline = c.imInt64(.maxOnline) ?? 0
        historyBufferSize = c.imInt(.historyBufferSize) ?? 0
        rateLimitPerSecond = c.imInt(.rateLimitPerSecond) ?? 0
        muteAll = c.imBool(.muteAll) ?? false
        destroyed = c.imBool(.destroyed) ?? false
        createdAt = c.imInt64(.createdAt) ?? 0
        extensions = c.imJSONMap(.extensions)
    }
}

/// What `room.join` answers.
public struct RoomJoinResult: Decodable, Sendable, Hashable {
    /// Required, as it is on the server: a reply without it does not decode.
    public let room: ChatRoom

    /// Connections present right after this one joined, cluster-wide.
    public let onlineCount: Int64

    /// The room's last few messages, oldest first, so a newcomer does not stare at an empty screen.
    /// Each has `seq` 0. **Returned here only**: they are not replayed on ``ImClient/messages()`` and
    /// touch no cursor — render them, and do not commit them.
    ///
    /// 只在这里返回：不会在 messages() 上重放，也不碰游标。
    public let recent: [ImMessage]

    enum CodingKeys: String, CodingKey {
        case room, onlineCount, recent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        room = try c.decode(ChatRoom.self, forKey: .room)
        onlineCount = c.imInt64(.onlineCount) ?? 0
        recent = c.imList(ImMessage.self, .recent) ?? []
    }
}

// MARK: - room.* events

/// One `room.*` event, as ``ImClient/roomEvents()`` delivers it.
///
/// The server sends these inside `evt.system` as `{"event": "room.muted", "body": {…}}`, beside events
/// that have nothing to do with rooms (the device-log request among them); only the `room.*` ones come
/// out here. A `room.*` name this build does not know is still delivered, with whatever ``roomId`` and
/// ``operatorId`` it carried and the whole ``body`` — a newer server must not be able to hide a room
/// event from an older app. Read by hand and never throws: a frame of another shape belongs to another
/// reader of `evt.system`.
///
/// - ``muted`` — ``userId`` `nil` is the whole room; ``untilMs`` `nil` or already past means the mute
///   was **lifted**, not set.
/// - ``kicked`` — ``userId`` is who was removed, and the removed member hears it too. If it is you,
///   stop sending: the server answers `1602` from now on.
/// - ``destroyed`` — the tenant's backend deleted the room. Every call about it answers `1600` now.
///
/// evt.system 里同时走着与聊天室无关的事件（设备日志请求就是其一），这里只交出 room.* 的；
/// 不认识的 room.* 名字照样交出，带上原始 body——新服务端不能把聊天室事件藏起来不让旧应用看到。
public struct RoomEvent: Sendable, Hashable {
    /// ``event`` of a mute set or lifted.
    public static let muted = "room.muted"
    /// ``event`` of a member removed.
    public static let kicked = "room.kicked"
    /// ``event`` of a room deleted by the tenant's backend.
    public static let destroyed = "room.destroyed"

    /// The prefix that makes an `evt.system` event a room's.
    static let namePrefix = "room."

    /// ``muted``, ``kicked``, ``destroyed``, or a `room.*` name a newer server added.
    public let event: String

    public let roomId: String

    /// Who did it: the owner, an admin, or the tenant backend's operator id.
    public let operatorId: String

    /// ``muted``: the member muted, `nil` for the whole room. ``kicked``: the member removed.
    public let userId: String?

    /// ``muted``: unix ms the mute ends; `nil`, or a past time, means it was lifted.
    public let untilMs: Int64?

    /// The event's whole `body`, for a field this build does not name.
    public let body: [String: JSONValue]

    public init(
        event: String,
        roomId: String,
        operatorId: String,
        userId: String? = nil,
        untilMs: Int64? = nil,
        body: [String: JSONValue] = [:]
    ) {
        self.event = event
        self.roomId = roomId
        self.operatorId = operatorId
        self.userId = userId
        self.untilMs = untilMs
        self.body = body
    }

    /// The `data` of an `evt.system` frame, as a room event — or `nil` when it is not one.
    ///
    /// `untilMs` is read under the string rule (CONTRACT.md §2): a 64-bit value may arrive quoted.
    static func fromSystemData(_ data: JSONValue?) -> RoomEvent? {
        guard case let .object(frame)? = data,
              case let .string(event)? = frame["event"],
              event.hasPrefix(RoomEvent.namePrefix)
        else {
            return nil
        }

        var members: [String: JSONValue] = [:]
        if case let .object(body)? = frame["body"] {
            members = body
        }

        return RoomEvent(
            event: event,
            roomId: members["roomId"]?.stringValue ?? "",
            operatorId: members["operatorId"]?.stringValue ?? "",
            userId: members["userId"]?.stringValue,
            untilMs: members["untilMs"]?.asInt64,
            body: members
        )
    }
}
