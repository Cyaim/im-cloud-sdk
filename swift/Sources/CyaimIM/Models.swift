import Foundation

// Domain models. Field names match the wire exactly — the gateway serialises camelCase, so no key
// strategy is configured anywhere and what you read here is what goes over the socket.

// MARK: - Enumerated wire values

/// Device class, sent at handshake and echoed on every message.
public struct Platform: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }
    public init(_ rawValue: Int) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let unknown = Platform(0)
    public static let iOS = Platform(1)
    public static let android = Platform(2)
    public static let windows = Platform(3)
    public static let macOS = Platform(4)
    public static let web = Platform(5)
    public static let miniProgram = Platform(6)
    public static let linux = Platform(7)

    /// What this build is running on, so callers do not have to `#if os(...)` themselves.
    ///
    /// visionOS and tvOS report as iOS deliberately: the multi-login policy buckets devices by
    /// platform family, and an app shipped for all of them should not have its iPhone session
    /// evicted by its Vision Pro session under `OnePerPlatform`.
    public static var current: Platform {
        #if os(macOS)
        return .macOS
        #elseif os(iOS) || os(tvOS) || os(visionOS)
        return .iOS
        #elseif os(Windows)
        return .windows
        #elseif os(Linux)
        return .linux
        #else
        return .unknown
        #endif
    }

    public var description: String {
        switch self {
        case .unknown: return "Unknown"
        case .iOS: return "iOS"
        case .android: return "Android"
        case .windows: return "Windows"
        case .macOS: return "macOS"
        case .web: return "Web"
        case .miniProgram: return "MiniProgram"
        case .linux: return "Linux"
        default: return "Platform(\(rawValue))"
        }
    }
}

public struct ConversationType: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }
    public init(_ rawValue: Int) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let single = ConversationType(1)
    public static let group = ConversationType(2)
    public static let chatRoom = ConversationType(3)
    public static let system = ConversationType(4)
    public static let assistant = ConversationType(5)
}

public struct MessageContentType: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }
    public init(_ rawValue: Int) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let text = MessageContentType(1)
    public static let image = MessageContentType(2)
    public static let voice = MessageContentType(3)
    public static let video = MessageContentType(4)
    public static let file = MessageContentType(5)
    public static let location = MessageContentType(6)
    public static let card = MessageContentType(7)
    public static let merged = MessageContentType(8)
    public static let notification = MessageContentType(9)
    public static let tip = MessageContentType(10)
    public static let recall = MessageContentType(11)
    public static let stream = MessageContentType(12)

    /// 100 and above is tenant-defined. Anything the SDK does not recognise still round-trips.
    public static let custom = MessageContentType(100)
}

// MARK: - Messages

/// Set when a message has been recalled. The message stays in the stream so the UI can replace it
/// in place rather than making a hole in the list.
public struct RecallInfo: Codable, Sendable, Hashable {
    public let operatorId: String
    public let recallTime: Int64
    public let byAdmin: Bool
    public let reason: String?
}

/// Set when a message has been edited. `version` increments, so a late-arriving older edit can be
/// discarded instead of overwriting a newer one.
public struct EditInfo: Codable, Sendable, Hashable {
    public let operatorId: String
    public let editTime: Int64
    public let version: Int
}

/// One message in a conversation.
public struct ImMessage: Codable, Sendable, Hashable, Identifiable {
    public let appId: String
    public let conversationId: String
    public let conversationType: ConversationType

    /// Gap-free position inside the conversation. Ordering and gap repair both key off this.
    ///
    /// Order your UI by `seq`, never by a timestamp: client clocks are wrong, arrival order is not
    /// send order, and `seq` is the only value the server guarantees to be strictly contiguous.
    public let seq: Int64

    /// Globally unique message id (snowflake). `Identifiable` uses it.
    public let messageId: Int64

    /// The sender's idempotency key. Echoed back so an optimistic local row can be reconciled with
    /// the delivered message instead of being duplicated.
    public let clientMsgId: String

    public let senderId: String
    public let senderPlatform: Platform
    public let contentType: MessageContentType

    /// Open payload. `["text": ...]` for text, `["url": ..., "width": ...]` for media, anything
    /// the tenant likes for custom types.
    public let content: [String: JSONValue]

    public let mentionAll: Bool
    public let mentionedUserIds: [String]
    public let quoteMessageId: Int64?

    /// The message this one replies within, for threaded conversations.
    public let threadRootId: Int64?

    /// The switches the sender set. Notably `persistent` and `onlineOnly`, which are what produce
    /// a `seq` of 0 - see ``ImClient/messages()``.
    public let options: MessageOptions

    /// Delivery state as the server last knew it.
    public let status: MessageStatus

    /// emoji -> user ids who reacted with it.
    public let reactions: [String: [String]]

    public let recalled: RecallInfo?
    public let edited: EditInfo?

    /// The sender's clock, for display only.
    public let sendTime: Int64

    /// Authoritative server clock, unix ms.
    public let createTime: Int64

    /// Unix ms at which the server deletes this message. `nil` means never.
    public let expireAt: Int64?

    public let extensions: [String: JSONValue]

    public var id: Int64 { messageId }

    /// Convenience for the overwhelmingly common case.
    public var text: String? { content["text"]?.stringValue }

    public var isRecalled: Bool { recalled != nil }

    enum CodingKeys: String, CodingKey {
        case appId, conversationId, conversationType, seq, messageId, clientMsgId, senderId
        case senderPlatform, contentType, content, mentionAll, mentionedUserIds, quoteMessageId
        case threadRootId, options, status, reactions, recalled, edited, sendTime, createTime
        case expireAt, extensions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // Only the identity and ordering fields are required. Everything else defaults, because a
        // message that fails to decode is a message the user never sees, and the server is allowed
        // to add fields between app releases.
        conversationId = try c.decode(String.self, forKey: .conversationId)

        // `seq` is required, but its wire *type* is not fixed: the gateway is configured with
        // `AllowReadingFromString`, so a 64-bit value may arrive as `"1234"` - and a decoder that
        // throws on that drops the message rather than one field of it.
        guard let decodedSeq = c.imInt64(.seq) else {
            throw DecodingError.keyNotFound(CodingKeys.seq, .init(
                codingPath: c.codingPath,
                debugDescription: "seq is required and must be an integer"
            ))
        }
        seq = decodedSeq

        messageId = c.imInt64(.messageId) ?? 0
        senderId = c.imString(.senderId) ?? ""

        appId = c.imString(.appId) ?? ""
        conversationType = c.imValue(ConversationType.self, .conversationType) ?? .single
        clientMsgId = c.imString(.clientMsgId) ?? ""
        senderPlatform = c.imValue(Platform.self, .senderPlatform) ?? .unknown
        contentType = c.imValue(MessageContentType.self, .contentType) ?? .text
        content = c.imJSONMap(.content) ?? [:]
        mentionAll = c.imBool(.mentionAll) ?? false
        mentionedUserIds = c.imStrings(.mentionedUserIds) ?? []
        quoteMessageId = c.imInt64(.quoteMessageId)
        threadRootId = c.imInt64(.threadRootId)
        options = c.imValue(MessageOptions.self, .options) ?? MessageOptions()
        status = c.imValue(MessageStatus.self, .status) ?? .sent
        reactions = c.imStringListMap(.reactions) ?? [:]
        recalled = c.imValue(RecallInfo.self, .recalled)
        edited = c.imValue(EditInfo.self, .edited)
        sendTime = c.imInt64(.sendTime) ?? 0
        createTime = c.imInt64(.createTime) ?? 0
        expireAt = c.imInt64(.expireAt)
        extensions = c.imJSONMap(.extensions) ?? [:]
    }
}

/// What the server returns for an accepted send.
public struct SendMessageResult: Codable, Sendable, Hashable {
    public let messageId: Int64

    /// The message's position in the conversation. Holding this means the message is persisted.
    public let seq: Int64

    public let conversationId: String
    public let clientMsgId: String
    public let createTime: Int64

    /// True when the server matched an earlier send on `clientMsgId` and returned that result
    /// rather than sending again.
    public let deduplicated: Bool

    /// True when moderation rewrote the payload before storing it.
    public let contentModified: Bool

    enum CodingKeys: String, CodingKey {
        case messageId, seq, conversationId, clientMsgId, createTime, deduplicated, contentModified
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        messageId = c.imInt64(.messageId) ?? 0
        seq = c.imInt64(.seq) ?? 0
        clientMsgId = c.imString(.clientMsgId) ?? ""
        createTime = c.imInt64(.createTime) ?? 0
        deduplicated = c.imBool(.deduplicated) ?? false
        contentModified = c.imBool(.contentModified) ?? false
    }
}

// MARK: - Conversations

/// Enough of the last message to render a conversation row without loading the message itself.
public struct MessageBrief: Codable, Sendable, Hashable {
    public let messageId: Int64
    public let seq: Int64
    public let senderId: String
    public let contentType: MessageContentType

    /// Server-rendered one-line summary, already localised and already redacted for muted types.
    public let digest: String

    public let createTime: Int64
    public let recalled: Bool

    enum CodingKeys: String, CodingKey {
        case messageId, seq, senderId, contentType, digest, createTime, recalled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = c.imInt64(.messageId) ?? 0
        seq = c.imInt64(.seq) ?? 0
        senderId = c.imString(.senderId) ?? ""
        contentType = c.imValue(MessageContentType.self, .contentType) ?? .text
        digest = c.imString(.digest) ?? ""
        createTime = c.imInt64(.createTime) ?? 0
        recalled = c.imBool(.recalled) ?? false
    }
}

/// A row in the conversation list.
public struct ConversationView: Codable, Sendable, Hashable, Identifiable {
    public let conversationId: String
    public let type: ConversationType
    public let lastMessage: MessageBrief?

    /// Newest seq in the conversation. `maxSeq - readSeq` is the unread count, which is why the
    /// badge never drifts and why marking read on one device clears it on all of them.
    public let maxSeq: Int64

    public let readSeq: Int64
    public let unreadCount: Int64
    public let pinned: Bool

    public let muted: MuteMode

    public let draft: String?
    public let tags: [String]
    public let manuallyUnread: Bool

    /// Unix ms of the last change to this conversation. Feed the largest value you have seen back
    /// as `updatedAfter` to page incrementally.
    public let updatedAt: Int64

    /// The other party, for a single chat. Present only when the server was asked to hydrate it,
    /// which is why the SDK never assumes it and `user.batchProfile` exists.
    public let peer: UserProfile?

    /// The group, for a group conversation. Same caveat as ``peer``.
    public let group: Group?

    public let extensions: [String: JSONValue]

    public var id: String { conversationId }

    enum CodingKeys: String, CodingKey {
        case conversationId, type, lastMessage, maxSeq, readSeq, unreadCount, pinned, muted
        case draft, tags, manuallyUnread, updatedAt, peer, group, extensions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = try c.decode(String.self, forKey: .conversationId)
        type = c.imValue(ConversationType.self, .type) ?? .single
        lastMessage = c.imValue(MessageBrief.self, .lastMessage)
        maxSeq = c.imInt64(.maxSeq) ?? 0
        readSeq = c.imInt64(.readSeq) ?? 0
        unreadCount = c.imInt64(.unreadCount) ?? 0
        pinned = c.imBool(.pinned) ?? false
        muted = c.imValue(MuteMode.self, .muted) ?? .normal
        draft = c.imString(.draft)
        tags = c.imStrings(.tags) ?? []
        manuallyUnread = c.imBool(.manuallyUnread) ?? false
        updatedAt = c.imInt64(.updatedAt) ?? 0
        peer = c.imValue(UserProfile.self, .peer)
        group = c.imValue(Group.self, .group)
        extensions = c.imJSONMap(.extensions) ?? [:]
    }
}

/// Every list endpoint pages the same way: an opaque cursor plus a flag.
public struct Page<Item: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public let items: [Item]

    /// Pass back as `cursor` to get the next page. `nil` when there is nothing after this one.
    ///
    /// The only correct way to page. `ConversationService.ListAsync` computes this cursor from the
    /// raw page *before* deleted rows are filtered out, so a page can return fewer `items` than
    /// `limit` while ``hasMore`` is still true: stopping on a short page skips everything after it.
    public let nextCursor: String?

    public let hasMore: Bool

    /// Total matching rows, where the endpoint counts them. Frequently absent; never page on it.
    public let total: Int64?

    enum CodingKeys: String, CodingKey {
        case items, nextCursor, hasMore, total
    }

    public init(items: [Item], nextCursor: String? = nil, hasMore: Bool = false, total: Int64? = nil) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.total = total
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.imList(Item.self, .items) ?? []
        nextCursor = c.imString(.nextCursor)
        hasMore = c.imBool(.hasMore) ?? false
        total = c.imInt64(.total)
    }
}

// MARK: - Sending

/// Where a message is going.
///
/// Three shorthands for one field on the wire: the server resolves a user or a group id into a
/// conversation id for you, so the app does not have to know the conversation id before the first
/// message exists.
public enum MessageTarget: Sendable, Hashable {
    case user(String)
    case group(String)
    case conversation(String)
}

/// A message about to be sent.
///
/// `clientMsgId` is generated when the draft is created, not when it is sent. That is the whole
/// idempotency story in one line: hold on to the draft, retry it as many times as you like, and the
/// server returns the original result with `deduplicated == true` instead of sending twice. Build a
/// fresh draft only when you mean a genuinely new message.
public struct MessageDraft: Encodable, Sendable, Hashable {
    public var target: MessageTarget
    public var contentType: MessageContentType
    public var content: [String: JSONValue]

    /// Idempotency key. Derive it from your own domain (an order id, a form submission id) when
    /// you have something stable; otherwise the generated value is already stable per draft.
    public var clientMsgId: String

    public var mentionAll: Bool
    public var mentionedUserIds: [String]?
    public var quoteMessageId: Int64?

    /// Per-message switches the server understands, e.g. `["offlinePush": false]`.
    ///
    /// Two paths read this differently. `invoke("msg.send", body: draft)` writes the dictionary as
    /// given. `send(_:)` goes through ``request``, which reads it with ``MessageOptions``' decoder:
    /// only the switches ``MessageOptions`` models survive, and a value of the wrong JSON kind makes
    /// the whole dictionary fall back to the server's defaults. ``MessageOptions`` models every option
    /// the server reads today, and the server drops an unknown nested key anyway, so nothing it would
    /// act on is lost — until the server adds an option this SDK version does not know.
    /// `invoke` 原样写出；`send(_:)` 只保留 MessageOptions 建模的开关，类型不对时整组回落到默认值。

    /// The device clock, echoed back for display. The server never orders by it.
    public var sendTime: Int64

    public var extensions: [String: JSONValue]?

    public init(
        to target: MessageTarget,
        contentType: MessageContentType = .text,
        content: [String: JSONValue] = [:],
        clientMsgId: String = ClientMessageId.generate(),
        mentionAll: Bool = false,
        mentionedUserIds: [String]? = nil,
        quoteMessageId: Int64? = nil,
        options: [String: JSONValue]? = nil,
        sendTime: Int64 = ImClock.nowMilliseconds(),
        extensions: [String: JSONValue]? = nil
    ) {
        self.target = target
        self.contentType = contentType
        self.content = content
        self.clientMsgId = clientMsgId
        self.mentionAll = mentionAll
        self.mentionedUserIds = mentionedUserIds
        self.quoteMessageId = quoteMessageId
        self.options = options
        self.sendTime = sendTime
        self.extensions = extensions
    }

    /// Text shorthand.
    public static func text(_ text: String, to target: MessageTarget) -> MessageDraft {
        MessageDraft(to: target, contentType: .text, content: ["text": .string(text)])
    }

    /// The same message as the endpoint's own request type.
    ///
    /// ``MessageDraft`` predates the namespaced surface and keeps its ``MessageTarget`` enum, which
    /// is a genuinely better way to say "to this user" than three mutually exclusive optionals.
    /// This is the bridge: `im.msg.send(_:)` takes ``SendMessageRequest`` because §4.3 names the
    /// request object after the server DTO, and the draft converts into one.
    ///
    /// `options` crosses as well, read through ``MessageOptions``' own decoder: a switch the draft
    /// leaves out takes the default the server would have applied anyway. It used to be left behind
    /// here, so `send(_:)` quietly sent every draft with the defaults whatever it asked for.
    public var request: SendMessageRequest {
        var built = SendMessageRequest(
            clientMsgId: clientMsgId,
            contentType: contentType,
            content: content,
            mentionAll: mentionAll,
            mentionedUserIds: mentionedUserIds,
            quoteMessageId: quoteMessageId,
            options: options.flatMap { try? JSONValue.object($0).decoded(as: MessageOptions.self) },
            sendTime: sendTime,
            extensions: extensions
        )

        switch target {
        case .user(let userId): built.receiverId = userId
        case .group(let groupId): built.groupId = groupId
        case .conversation(let conversationId): built.conversationId = conversationId
        }

        return built
    }

    enum CodingKeys: String, CodingKey {
        case conversationId, receiverId, groupId, contentType, content, clientMsgId
        case mentionAll, mentionedUserIds, quoteMessageId, options, sendTime, extensions
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch target {
        case .user(let userId): try container.encode(userId, forKey: .receiverId)
        case .group(let groupId): try container.encode(groupId, forKey: .groupId)
        case .conversation(let conversationId): try container.encode(conversationId, forKey: .conversationId)
        }

        try container.encode(contentType, forKey: .contentType)
        try container.encode(content, forKey: .content)
        try container.encode(clientMsgId, forKey: .clientMsgId)
        try container.encode(sendTime, forKey: .sendTime)

        if mentionAll { try container.encode(true, forKey: .mentionAll) }
        try container.encodeIfPresent(mentionedUserIds, forKey: .mentionedUserIds)
        // Quoted: the server's field is `string?`. See ``RecallMessageRequest``.
        try container.encodeIfPresent(quoteMessageId.map { String($0) }, forKey: .quoteMessageId)
        try container.encodeIfPresent(options, forKey: .options)
        try container.encodeIfPresent(extensions, forKey: .extensions)
    }
}

/// Generates `clientMsgId` values: base-36 milliseconds plus randomness, matching the other SDKs.
public enum ClientMessageId {
    public static func generate() -> String {
        let stamp = String(ImClock.nowMilliseconds(), radix: 36)
        let random = UUID().uuidString.prefix(8).lowercased()
        return "\(stamp)-\(random)"
    }
}

/// Unix-millisecond clock, in one place so the SDK never mixes units.
public enum ImClock {
    public static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - Endpoint payloads

/// Reply to `conn.heartbeat`.
public struct HeartbeatResult: Decodable, Sendable, Hashable {
    public let serverTime: Int64

    /// How often to beat, in seconds. The server owns this cadence; the SDK adopts whatever it
    /// reports rather than hard-coding one.
    public let intervalSeconds: Int

    /// True when this beat rebuilt a cluster routing entry that had gone missing.
    public let healed: Bool

    /// This socket's cluster-unique id — worth logging, because a support ticket carrying it can be
    /// traced to an exact node and an exact connection.
    public let connectionId: String

    public let nodeId: String

    enum CodingKeys: String, CodingKey {
        case serverTime, intervalSeconds, healed, connectionId, nodeId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverTime = c.imInt64(.serverTime) ?? 0
        intervalSeconds = c.imInt(.intervalSeconds) ?? 0
        healed = c.imBool(.healed) ?? false
        connectionId = c.imString(.connectionId) ?? ""
        nodeId = c.imString(.nodeId) ?? ""
    }
}

/// Payload of a `conn.kick` push.
public struct KickEvent: Decodable, Sendable, Hashable {
    public let reason: KickReason
    public let operatorId: String?
    public let serverTime: Int64

    enum CodingKeys: String, CodingKey {
        case reason, operatorId, serverTime
    }

    public init(reason: KickReason, operatorId: String? = nil, serverTime: Int64 = 0) {
        self.reason = reason
        self.operatorId = operatorId
        self.serverTime = serverTime
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = c.imValue(KickReason.self, .reason) ?? KickReason("")
        operatorId = c.imString(.operatorId)
        serverTime = c.imInt64(.serverTime) ?? 0
    }
}
