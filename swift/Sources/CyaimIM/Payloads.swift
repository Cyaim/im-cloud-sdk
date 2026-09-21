import Foundation

// Payload types the typed surface returns. Field names match the wire exactly — the gateway
// serialises camelCase and no key strategy is configured anywhere, so what you read here is what
// goes over the socket.
//
// Every decoder is written by hand rather than synthesised, and every field except the ones the
// server marks required has a default. A payload that fails to decode is a screen the user never
// sees, and the server is allowed to add a field between two of your releases.

// MARK: - Enumerated wire values

/// How a conversation is muted for this user. `0` is not muted.
public struct MuteMode: ImOpenEnum {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let normal = MuteMode(0)
    /// Delivered in-app, but never as an offline push.
    public static let noPush = MuteMode(1)
    /// Delivered and not counted: no badge, no push, no unread.
    public static let silent = MuteMode(2)
}

/// Delivery state of a message, as the server last knew it.
public struct MessageStatus: ImOpenEnum {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let sending = MessageStatus(0)
    public static let sent = MessageStatus(1)
    public static let delivered = MessageStatus(2)
    public static let read = MessageStatus(3)
    public static let failed = MessageStatus(4)
}

/// Which traffic gets dropped first when a connection is behind.
public struct MessagePriority: ImOpenEnum {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let low = MessagePriority(0)
    public static let normal = MessagePriority(1)
    public static let high = MessagePriority(2)
}

/// How many devices of one user may hold a socket at once.
public struct MultiLoginPolicy: ImOpenEnum {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let allowAll = MultiLoginPolicy(0)
    public static let onePerPlatform = MultiLoginPolicy(1)
    public static let oneMobileOneDesktopOneWeb = MultiLoginPolicy(2)
    public static let singleDevice = MultiLoginPolicy(3)
}

public struct GroupType: ImOpenEnum {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let normal = GroupType(1)
    /// Large group: no member-list fan-out, no read receipts, different storage.
    public static let superGroup = GroupType(2)
    public static let chatRoom = GroupType(3)
}

public struct GroupRole: ImOpenEnum {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let member = GroupRole(1)
    public static let admin = GroupRole(2)
    public static let owner = GroupRole(3)
}

public struct GroupJoinMode: ImOpenEnum {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let freeAccess = GroupJoinMode(0)
    public static let needApproval = GroupJoinMode(1)
    public static let forbidden = GroupJoinMode(2)
}

public struct GroupInviteMode: ImOpenEnum {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let allMembers = GroupInviteMode(0)
    public static let adminsOnly = GroupInviteMode(1)
    public static let forbidden = GroupInviteMode(2)
}

/// Where a friend request or a group application has got to.
public struct ApplicationStatus: ImOpenEnum {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let pending = ApplicationStatus(0)
    public static let accepted = ApplicationStatus(1)
    public static let rejected = ApplicationStatus(2)
    public static let expired = ApplicationStatus(3)
}

// MARK: - Users

/// A hosted user profile.
///
/// Tenants may keep their own user store and mirror only the display fields here; hosting them is
/// what lets the service render a conversation list without a callback per row.
public struct UserProfile: Codable, Sendable, Hashable, Identifiable {
    public let appId: String
    public let userId: String
    public let nickname: String?
    public let avatar: String?
    public let gender: Int
    public let birthday: String?
    public let signature: String?

    /// Hashed, never the raw value. The platform never holds a phone number it could leak.
    public let phoneHash: String?
    public let emailHash: String?

    /// Unix ms until which this user may not send anywhere. `nil` means not silenced.
    public let silencedUntil: Int64?

    /// Hard ban: cannot connect at all.
    public let banned: Bool

    public let multiLoginOverride: MultiLoginPolicy?
    public let createdAt: Int64
    public let updatedAt: Int64

    /// Tenant data. Returned verbatim, and replaced wholesale by the tenant backend's
    /// `POST /v1/users` — so it is a place for your fields and never for a secret.
    public let extensions: [String: JSONValue]

    public var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case appId, userId, nickname, avatar, gender, birthday, signature, phoneHash, emailHash
        case silencedUntil, banned, multiLoginOverride, createdAt, updatedAt, extensions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        appId = c.imString(.appId) ?? ""
        nickname = c.imString(.nickname)
        avatar = c.imString(.avatar)
        gender = c.imInt(.gender) ?? 0
        birthday = c.imString(.birthday)
        signature = c.imString(.signature)
        phoneHash = c.imString(.phoneHash)
        emailHash = c.imString(.emailHash)
        silencedUntil = c.imInt64(.silencedUntil)
        banned = c.imBool(.banned) ?? false
        multiLoginOverride = c.imValue(MultiLoginPolicy.self, .multiLoginOverride)
        createdAt = c.imInt64(.createdAt) ?? 0
        updatedAt = c.imInt64(.updatedAt) ?? 0
        extensions = c.imJSONMap(.extensions) ?? [:]
    }
}

/// A user's online state, aggregated across their devices.
public struct PresenceState: Codable, Sendable, Hashable, Identifiable {
    public let userId: String
    public let online: Bool
    public let platforms: [Platform]

    /// Unix ms of last activity. Meaningful when offline.
    public let lastSeen: Int64

    /// Tenant-defined, e.g. `"busy"`, `"in-game"`.
    public let customStatus: String?

    public var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId, online, platforms, lastSeen, customStatus
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        online = c.imBool(.online) ?? false
        platforms = c.imList(Platform.self, .platforms) ?? []
        lastSeen = c.imInt64(.lastSeen) ?? 0
        customStatus = c.imString(.customStatus)
    }
}

// MARK: - Media

/// A short-lived presigned upload, plus the key to put in the message.
///
/// Messages carry `objectKey`, never `downloadUrl`: every reader signs their own link with
/// `media.downloadUrl`, which is what makes expiry and per-reader access control possible at all. A
/// URL baked into a message is public forever the moment the message leaks.
///
/// 消息里存 objectKey 而不是 URL：每个读者自己签发短期链接，撤销与鉴权才有可能。
public struct MediaUploadTicket: Codable, Sendable, Hashable {
    /// The key to store in the message's `content`.
    public let objectKey: String

    /// `PUT` the bytes here. The server chose the key, so a client cannot write outside its own
    /// tenant and user prefix.
    public let uploadUrl: String

    /// A signed link valid until `expiresAt`. Convenience for an immediate preview only — do not
    /// persist it and do not send it to anyone.
    public let downloadUrl: String

    /// Extra form fields for storage backends that want a POST policy rather than a PUT.
    public let formFields: [String: String]

    public let expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case objectKey, uploadUrl, downloadUrl, formFields, expiresAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        objectKey = c.imString(.objectKey) ?? ""
        uploadUrl = c.imString(.uploadUrl) ?? ""
        downloadUrl = c.imString(.downloadUrl) ?? ""
        formFields = c.imStringMap(.formFields) ?? [:]
        expiresAt = c.imInt64(.expiresAt) ?? 0
    }
}

// MARK: - Message options

/// Per-notification copy for one message.
public struct PushConfig: Codable, Sendable, Hashable {
    public var title: String?
    public var body: String?
    public var sound: String?
    public var payload: [String: String]?

    /// Whether this message increments the recipient's badge.
    public var badgeCount: Bool

    /// Android notification channel.
    public var channelId: String?

    public init(
        title: String? = nil,
        body: String? = nil,
        sound: String? = nil,
        payload: [String: String]? = nil,
        badgeCount: Bool = true,
        channelId: String? = nil
    ) {
        self.title = title
        self.body = body
        self.sound = sound
        self.payload = payload
        self.badgeCount = badgeCount
        self.channelId = channelId
    }

    enum CodingKeys: String, CodingKey {
        case title, body, sound, payload, badgeCount, channelId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.imString(.title)
        body = c.imString(.body)
        sound = c.imString(.sound)
        payload = c.imStringMap(.payload)
        badgeCount = c.imBool(.badgeCount) ?? true
        channelId = c.imString(.channelId)
    }
}

/// The switches a sender may set on one message.
///
/// `onlineOnly` plus `persistent == false` is how a message gets `seq == 0` and bypasses the cursor
/// machinery entirely — see ``ImClient/messages()``.
public struct MessageOptions: Codable, Sendable, Hashable {
    public var persistent: Bool
    public var updateConversation: Bool
    public var countUnread: Bool
    public var offlinePush: Bool
    public var pushConfig: PushConfig?
    public var needReceipt: Bool
    public var priority: MessagePriority
    public var onlineOnly: Bool

    /// Do not echo this message back to the sender's other devices.
    public var noSelfSync: Bool

    /// **Milliseconds** until the server deletes it, counted from when the server receives it.
    /// `nil` means never. The server adds this straight to its unix-ms clock (`expireAt = now +
    /// expireIn`), so a value meant as seconds expires a thousand times too soon.
    public var expireIn: Int64?

    /// Skip content moderation. Server-side policy decides whether a client may ask.
    public var moderationBypass: Bool

    public init(
        persistent: Bool = true,
        updateConversation: Bool = true,
        countUnread: Bool = true,
        offlinePush: Bool = true,
        pushConfig: PushConfig? = nil,
        needReceipt: Bool = false,
        priority: MessagePriority = .normal,
        onlineOnly: Bool = false,
        noSelfSync: Bool = false,
        expireIn: Int64? = nil,
        moderationBypass: Bool = false
    ) {
        self.persistent = persistent
        self.updateConversation = updateConversation
        self.countUnread = countUnread
        self.offlinePush = offlinePush
        self.pushConfig = pushConfig
        self.needReceipt = needReceipt
        self.priority = priority
        self.onlineOnly = onlineOnly
        self.noSelfSync = noSelfSync
        self.expireIn = expireIn
        self.moderationBypass = moderationBypass
    }

    enum CodingKeys: String, CodingKey {
        case persistent, updateConversation, countUnread, offlinePush, pushConfig, needReceipt
        case priority, onlineOnly, noSelfSync, expireIn, moderationBypass
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        persistent = c.imBool(.persistent) ?? true
        updateConversation = c.imBool(.updateConversation) ?? true
        countUnread = c.imBool(.countUnread) ?? true
        offlinePush = c.imBool(.offlinePush) ?? true
        pushConfig = c.imValue(PushConfig.self, .pushConfig)
        needReceipt = c.imBool(.needReceipt) ?? false
        priority = c.imValue(MessagePriority.self, .priority) ?? .normal
        onlineOnly = c.imBool(.onlineOnly) ?? false
        noSelfSync = c.imBool(.noSelfSync) ?? false
        expireIn = c.imInt64(.expireIn)
        moderationBypass = c.imBool(.moderationBypass) ?? false
    }
}

/// Per-user conversation settings. Every field is optional: `nil` means "leave as it is".
public struct ConversationSetting: Codable, Sendable, Hashable {
    public var pinned: Bool?
    public var muted: MuteMode?
    public var draft: String?
    public var tags: [String]?
    public var extensions: [String: JSONValue]?

    public init(
        pinned: Bool? = nil,
        muted: MuteMode? = nil,
        draft: String? = nil,
        tags: [String]? = nil,
        extensions: [String: JSONValue]? = nil
    ) {
        self.pinned = pinned
        self.muted = muted
        self.draft = draft
        self.tags = tags
        self.extensions = extensions
    }

    enum CodingKeys: String, CodingKey {
        case pinned, muted, draft, tags, extensions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinned = c.imBool(.pinned)
        muted = c.imValue(MuteMode.self, .muted)
        draft = c.imString(.draft)
        tags = c.imStrings(.tags)
        extensions = c.imJSONMap(.extensions)
    }
}

// MARK: - Groups

public struct Group: Codable, Sendable, Hashable, Identifiable {
    public let appId: String
    public let groupId: String
    public let type: GroupType
    public let name: String
    public let avatar: String?
    public let introduction: String?
    public let announcement: String?
    public let announcementUpdatedAt: Int64?
    public let ownerId: String
    public let memberCount: Int
    public let maxMemberCount: Int
    public let joinMode: GroupJoinMode
    public let inviteMode: GroupInviteMode

    /// Everyone but the owner and admins is muted.
    public let muteAll: Bool

    /// Unix ms at which `muteAll` lapses. `nil` means indefinitely.
    public let muteEndTime: Int64?

    /// A dismissed group still resolves, so an app can render "this group was dismissed" rather
    /// than a 404 where a conversation used to be.
    public let dismissed: Bool

    public let createdAt: Int64
    public let updatedAt: Int64
    public let extensions: [String: JSONValue]

    public var id: String { groupId }

    enum CodingKeys: String, CodingKey {
        case appId, groupId, type, name, avatar, introduction, announcement, announcementUpdatedAt
        case ownerId, memberCount, maxMemberCount, joinMode, inviteMode, muteAll, muteEndTime
        case dismissed, createdAt, updatedAt, extensions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groupId = try c.decode(String.self, forKey: .groupId)
        appId = c.imString(.appId) ?? ""
        type = c.imValue(GroupType.self, .type) ?? .normal
        name = c.imString(.name) ?? ""
        avatar = c.imString(.avatar)
        introduction = c.imString(.introduction)
        announcement = c.imString(.announcement)
        announcementUpdatedAt = c.imInt64(.announcementUpdatedAt)
        ownerId = c.imString(.ownerId) ?? ""
        memberCount = c.imInt(.memberCount) ?? 0
        maxMemberCount = c.imInt(.maxMemberCount) ?? 0
        joinMode = c.imValue(GroupJoinMode.self, .joinMode) ?? .freeAccess
        inviteMode = c.imValue(GroupInviteMode.self, .inviteMode) ?? .allMembers
        muteAll = c.imBool(.muteAll) ?? false
        muteEndTime = c.imInt64(.muteEndTime)
        dismissed = c.imBool(.dismissed) ?? false
        createdAt = c.imInt64(.createdAt) ?? 0
        updatedAt = c.imInt64(.updatedAt) ?? 0
        extensions = c.imJSONMap(.extensions) ?? [:]
    }
}

public struct GroupMember: Codable, Sendable, Hashable, Identifiable {
    public let appId: String
    public let groupId: String
    public let userId: String
    public let role: GroupRole

    /// In-group display name. Falls back to the profile nickname when `nil`.
    public let nickname: String?

    /// Unix ms at which this member's mute lapses. `nil` means not muted.
    public let muteEndTime: Int64?

    public let joinTime: Int64
    public let joinSource: String?
    public let extensions: [String: JSONValue]

    /// Unique within a group, which is the only scope this type is ever listed in.
    public var id: String { "\(groupId)/\(userId)" }

    enum CodingKeys: String, CodingKey {
        case appId, groupId, userId, role, nickname, muteEndTime, joinTime, joinSource, extensions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        appId = c.imString(.appId) ?? ""
        groupId = c.imString(.groupId) ?? ""
        role = c.imValue(GroupRole.self, .role) ?? .member
        nickname = c.imString(.nickname)
        muteEndTime = c.imInt64(.muteEndTime)
        joinTime = c.imInt64(.joinTime) ?? 0
        joinSource = c.imString(.joinSource)
        extensions = c.imJSONMap(.extensions) ?? [:]
    }
}

/// A request to join a group, as `group.applicationList` returns it.
///
/// **Every status comes back, not only pending ones** — the server does not filter. For a "waiting
/// for you" list, keep the rows whose ``status`` is ``ApplicationStatus/pending``. The server never
/// produces ``ApplicationStatus/expired`` today.
///
/// 服务端不按状态过滤，各种状态都会返回；「等你处理」要自己筛 pending。
public struct GroupApplication: Codable, Sendable, Hashable, Identifiable {
    public let appId: String
    public let groupId: String

    /// Who wants to join. Pass it back as ``HandleApplicationRequest/applicantId``.
    public let applicantId: String

    /// Set when an ordinary member invited ``applicantId`` into a group that needs approval.
    public let inviterId: String?

    public let reason: String?
    public let status: ApplicationStatus

    /// Who accepted or rejected it.
    public let handlerId: String?

    public let handleReason: String?

    /// Unix ms.
    public let createdAt: Int64

    /// Unix ms. `nil` while pending.
    public let handledAt: Int64?

    /// The server keeps one row per applicant per group, so the pair is unique.
    public var id: String { "\(groupId)/\(applicantId)" }

    enum CodingKeys: String, CodingKey {
        case appId, groupId, applicantId, inviterId, reason, status, handlerId, handleReason
        case createdAt, handledAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applicantId = try c.decode(String.self, forKey: .applicantId)
        appId = c.imString(.appId) ?? ""
        groupId = c.imString(.groupId) ?? ""
        inviterId = c.imString(.inviterId)
        reason = c.imString(.reason)
        status = c.imValue(ApplicationStatus.self, .status) ?? .pending
        handlerId = c.imString(.handlerId)
        handleReason = c.imString(.handleReason)
        createdAt = c.imInt64(.createdAt) ?? 0
        handledAt = c.imInt64(.handledAt)
    }
}

// MARK: - Message extras

/// One entry on a conversation's pinned board, as `msg.pins` returns it.
///
/// ``messageId`` arrives as a JSON string, like every message id the server writes, and decodes into
/// the `Int64` exactly.
public struct PinnedMessage: Codable, Sendable, Hashable, Identifiable {
    public let messageId: Int64
    public let seq: Int64

    /// Who pinned it.
    public let pinnedBy: String

    /// Unix ms, server clock.
    public let pinnedAt: Int64

    /// Built fresh when the board is read, so it reflects a recall that happened after the pin
    /// (`digest` `"[Recalled]"`, `recalled == true`). Tokens such as `"[Image]"` are fixed wire
    /// values for the client to localise. `msg.pins` always fills it; optional because the server's
    /// type allows it to be absent.
    public let brief: MessageBrief?

    public var id: Int64 { messageId }

    enum CodingKeys: String, CodingKey {
        case messageId, seq, pinnedBy, pinnedAt, brief
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = c.imInt64(.messageId) ?? 0
        seq = c.imInt64(.seq) ?? 0
        pinnedBy = c.imString(.pinnedBy) ?? ""
        pinnedAt = c.imInt64(.pinnedAt) ?? 0
        brief = c.imValue(MessageBrief.self, .brief)
    }
}

/// `msg.receiptDetail` — who has read one message.
///
/// **``totalCount`` includes the sender and ``readUserIds`` never does**, so "read by everyone" is
/// `readCount == totalCount - 1`, not `readCount == totalCount`. ``totalCount`` is a snapshot taken
/// at the last receipt, not a live member count.
///
/// 发送者计入 totalCount 却不会出现在 readUserIds 里，「全员已读」是 readCount == totalCount - 1。
public struct MessageReceipt: Codable, Sendable, Hashable, Identifiable {
    public let appId: String
    public let conversationId: String

    /// Arrives quoted, decodes exactly.
    public let messageId: Int64

    /// Never contains the sender. Not truncated: nothing caps this read.
    public let readUserIds: [String]

    public let readCount: Int

    /// Includes the sender: 2 in a single chat, the member count in a group.
    public let totalCount: Int

    /// Unix ms. Equal to the message's `createTime` when nobody has read it yet.
    public let updatedAt: Int64

    public var id: Int64 { messageId }

    enum CodingKeys: String, CodingKey {
        case appId, conversationId, messageId, readUserIds, readCount, totalCount, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = c.imString(.appId) ?? ""
        conversationId = c.imString(.conversationId) ?? ""
        messageId = c.imInt64(.messageId) ?? 0
        readUserIds = c.imStrings(.readUserIds) ?? []
        readCount = c.imInt(.readCount) ?? 0
        totalCount = c.imInt(.totalCount) ?? 0
        updatedAt = c.imInt64(.updatedAt) ?? 0
    }
}

// MARK: - Relationships

public struct Friend: Codable, Sendable, Hashable, Identifiable {
    public let appId: String

    /// The owner of this entry — the caller.
    public let userId: String

    /// The other person.
    public let friendUserId: String

    /// The caller's private name for them. Renders instead of the nickname.
    public let remark: String?

    public let tags: [String]
    public let source: String?
    public let addTime: Int64
    public let extensions: [String: JSONValue]

    public var id: String { friendUserId }

    enum CodingKeys: String, CodingKey {
        case appId, userId, friendUserId, remark, tags, source, addTime, extensions
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        friendUserId = try c.decode(String.self, forKey: .friendUserId)
        appId = c.imString(.appId) ?? ""
        userId = c.imString(.userId) ?? ""
        remark = c.imString(.remark)
        tags = c.imStrings(.tags) ?? []
        source = c.imString(.source)
        addTime = c.imInt64(.addTime) ?? 0
        extensions = c.imJSONMap(.extensions) ?? [:]
    }
}

/// A pending, accepted or rejected friend request.
public struct FriendRequest: Codable, Sendable, Hashable, Identifiable {
    public let appId: String
    public let fromUserId: String
    public let toUserId: String
    public let greeting: String?
    public let source: String?
    public let status: ApplicationStatus
    public let handleReason: String?
    public let createdAt: Int64
    public let handledAt: Int64?

    public var id: String { "\(fromUserId)->\(toUserId)" }

    enum CodingKeys: String, CodingKey {
        case appId, fromUserId, toUserId, greeting, source, status, handleReason, createdAt, handledAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fromUserId = try c.decode(String.self, forKey: .fromUserId)
        appId = c.imString(.appId) ?? ""
        toUserId = c.imString(.toUserId) ?? ""
        greeting = c.imString(.greeting)
        source = c.imString(.source)
        status = c.imValue(ApplicationStatus.self, .status) ?? .pending
        handleReason = c.imString(.handleReason)
        createdAt = c.imInt64(.createdAt) ?? 0
        handledAt = c.imInt64(.handledAt)
    }
}

/// One row of the caller's blocklist.
public struct BlockEntry: Codable, Sendable, Hashable, Identifiable {
    public let appId: String
    public let userId: String
    public let blockedUserId: String
    public let createdAt: Int64
    public let reason: String?

    public var id: String { blockedUserId }

    enum CodingKeys: String, CodingKey {
        case appId, userId, blockedUserId, createdAt, reason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blockedUserId = try c.decode(String.self, forKey: .blockedUserId)
        appId = c.imString(.appId) ?? ""
        userId = c.imString(.userId) ?? ""
        createdAt = c.imInt64(.createdAt) ?? 0
        reason = c.imString(.reason)
    }
}
