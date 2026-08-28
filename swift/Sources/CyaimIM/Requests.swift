import Foundation

// One request object per endpoint, named for the server DTO it serialises to. See
// sdk/CONTRACT.md §4.3.
//
// Not a style preference. With positional parameters, the server adding one optional field is a
// source-breaking change in five languages at once; with a request object it is additive
// everywhere. Convenience overloads exist only where a request has at most two required scalars and
// nothing optional — `im.conv.read("c1", readSeq: 40)` is fine, a nine-argument `send` is not.
//
// 每个端点一个请求对象：服务端新增一个可选字段，用位置参数就是五种语言同时源码不兼容，
// 用请求对象则处处只是新增。
//
// These are `Encodable` by synthesis on purpose: Swift's synthesised encoder uses `encodeIfPresent`
// for optionals, which is exactly the gateway's "nulls are omitted when writing" policy (§2).

// MARK: - conn

/// `conn.reauth` — swap in a fresh token without dropping the socket.
public struct ReauthRequest: Encodable, Sendable, Hashable {
    public var token: String

    public init(token: String) {
        self.token = token
    }
}

/// `conn.sync` — what changed while we were away.
public struct ResumeRequest: Encodable, Sendable, Hashable {
    /// Highest **committed** seq per conversation. Never the delivered seq: see §5.2, and the
    /// one-line rule in `docs/SPEC-02-protocol.md` §3.3 that four SDKs got backwards.
    public var convSeqs: [String: Int64]

    /// Largest `ConversationView.updatedAt` from a completed run.
    public var conversationCursor: Int64

    /// Paging cursor. `nil` for the first page, then `ResumeResult.nextCursor`.
    public var cursor: String?

    /// Server clamps to 1…500; anything outside becomes 200.
    public var limit: Int

    public init(
        convSeqs: [String: Int64] = [:],
        conversationCursor: Int64 = 0,
        cursor: String? = nil,
        limit: Int = 200
    ) {
        self.convSeqs = convSeqs
        self.conversationCursor = conversationCursor
        self.cursor = cursor
        self.limit = limit
    }
}

/// Reply to `conn.sync`.
public struct ResumeResult: Decodable, Sendable, Hashable {
    public let conversations: [ConversationView]

    /// Pass back as ``ResumeRequest/cursor``. The list is sorted by `updatedAt` **descending**, so
    /// page 1 holds the newest timestamp and a client that stops there has skipped pages 2…N
    /// permanently.
    public let nextCursor: String?

    public let hasMore: Bool

    /// conversationId -> first seq this client is missing, as the *server* computed it.
    ///
    /// Trust it, but do not depend on it: `ConnController.Sync` only emits an entry when the client
    /// reported a non-zero seq for that conversation, so a conversation reported as `0` produces no
    /// entry at all. The SDK therefore derives its own range from the committed cursor and takes
    /// whichever of the two is later.
    public let gapsFrom: [String: Int64]

    public let serverTime: Int64

    enum CodingKeys: String, CodingKey {
        case conversations, nextCursor, hasMore, gapsFrom, serverTime
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = c.imList(ConversationView.self, .conversations) ?? []
        nextCursor = c.imString(.nextCursor)
        hasMore = c.imBool(.hasMore) ?? false
        gapsFrom = c.imInt64Map(.gapsFrom) ?? [:]
        serverTime = c.imInt64(.serverTime) ?? 0
    }
}

// MARK: - msg

/// `msg.send`.
///
/// Provide exactly one of `conversationId`, `receiverId` or `groupId`; the server resolves the last
/// two into a conversation id, which is what lets an app send the first message of a conversation
/// that does not exist yet.
public struct SendMessageRequest: Encodable, Sendable, Hashable {
    public var conversationId: String?

    /// Shorthand for a single chat with this user.
    public var receiverId: String?

    /// Shorthand for a group conversation.
    public var groupId: String?

    public var conversationType: ConversationType?

    /// Idempotency key. Mint it when you build the request, not when you send it: retry the *same*
    /// request as often as you like and the server returns the original result with
    /// ``SendMessageResult/deduplicated`` set rather than sending twice.
    public var clientMsgId: String

    public var contentType: MessageContentType

    /// Open payload — `["text": "hi"]`, `["objectKey": …, "width": …]`, or whatever your tenant
    /// invents for `contentType: 100`.
    public var content: [String: JSONValue]

    public var mentionAll: Bool
    public var mentionedUserIds: [String]?
    public var quoteMessageId: Int64?
    public var threadRootId: Int64?
    public var options: MessageOptions?

    /// The device clock, echoed back for display. The server never orders by it.
    public var sendTime: Int64

    public var extensions: [String: JSONValue]?

    public init(
        conversationId: String? = nil,
        receiverId: String? = nil,
        groupId: String? = nil,
        conversationType: ConversationType? = nil,
        clientMsgId: String = ClientMessageId.generate(),
        contentType: MessageContentType = .text,
        content: [String: JSONValue] = [:],
        mentionAll: Bool = false,
        mentionedUserIds: [String]? = nil,
        quoteMessageId: Int64? = nil,
        threadRootId: Int64? = nil,
        options: MessageOptions? = nil,
        sendTime: Int64 = ImClock.nowMilliseconds(),
        extensions: [String: JSONValue]? = nil
    ) {
        self.conversationId = conversationId
        self.receiverId = receiverId
        self.groupId = groupId
        self.conversationType = conversationType
        self.clientMsgId = clientMsgId
        self.contentType = contentType
        self.content = content
        self.mentionAll = mentionAll
        self.mentionedUserIds = mentionedUserIds
        self.quoteMessageId = quoteMessageId
        self.threadRootId = threadRootId
        self.options = options
        self.sendTime = sendTime
        self.extensions = extensions
    }

    /// The overwhelmingly common case.
    public static func text(_ text: String, to target: MessageTarget) -> SendMessageRequest {
        MessageDraft.text(text, to: target).request
    }
}

/// `msg.sync` — an explicit seq window.
///
/// The gap-repair loop's primitive, and a public method: a tenant with its own message store calls
/// it directly. `MessageService.SyncAsync` clamps `limit` to **500** and returns `hasMore`, so a
/// 900-seq range in one call silently returns 500 — page on ``SyncMessagesResult/hasMore``.
public struct SyncMessagesRequest: Encodable, Sendable, Hashable {
    public var conversationId: String

    /// Inclusive lower bound.
    public var fromSeq: Int64

    /// Inclusive upper bound; `0` means "up to the newest".
    public var toSeq: Int64

    public var limit: Int

    /// `false` walks backwards from `toSeq`.
    public var ascending: Bool

    public init(
        conversationId: String,
        fromSeq: Int64,
        toSeq: Int64 = 0,
        limit: Int = 100,
        ascending: Bool = true
    ) {
        self.conversationId = conversationId
        self.fromSeq = fromSeq
        self.toSeq = toSeq
        self.limit = limit
        self.ascending = ascending
    }
}

/// Reply to `msg.sync`.
public struct SyncMessagesResult: Decodable, Sendable, Hashable {
    public let conversationId: String
    public let messages: [ImMessage]
    public let maxSeq: Int64
    public let minSeq: Int64

    /// Computed on the **raw** window, before per-user hidden messages are filtered out. So
    /// `messages` can be shorter than `limit` — even empty — while this is `true`. Loop on this,
    /// never on `messages.count`.
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case conversationId, messages, maxSeq, minSeq, hasMore
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationId = c.imString(.conversationId) ?? ""
        messages = c.imList(ImMessage.self, .messages) ?? []
        maxSeq = c.imInt64(.maxSeq) ?? 0
        minSeq = c.imInt64(.minSeq) ?? 0
        hasMore = c.imBool(.hasMore) ?? false
    }
}

/// `msg.history` — backwards from a seq cursor.
public struct HistoryRequest: Encodable, Sendable, Hashable {
    public var conversationId: String

    /// Exclusive upper bound; `nil` starts at the newest message.
    public var beforeSeq: Int64?

    public var limit: Int

    public init(conversationId: String, beforeSeq: Int64? = nil, limit: Int = 20) {
        self.conversationId = conversationId
        self.beforeSeq = beforeSeq
        self.limit = limit
    }
}

/// `msg.recall` — withdraw for everyone.
///
/// There is deliberately no `asAdmin`: `MsgController.Recall` forces it to `false` whatever the
/// client claims, so a field for it would only mislead. Admin recall is a server-API capability.
public struct RecallMessageRequest: Encodable, Sendable, Hashable {
    public var conversationId: String
    public var messageId: Int64
    public var reason: String?

    public init(conversationId: String, messageId: Int64, reason: String? = nil) {
        self.conversationId = conversationId
        self.messageId = messageId
        self.reason = reason
    }
}

/// `msg.delete` — delete-for-me by default, distinct from ``RecallMessageRequest``.
public struct DeleteMessagesRequest: Encodable, Sendable, Hashable {
    public var conversationId: String
    public var messageIds: [Int64]

    /// `true` removes it for every participant. Server-side policy decides whether you may.
    public var forEveryone: Bool

    public init(conversationId: String, messageIds: [Int64], forEveryone: Bool = false) {
        self.conversationId = conversationId
        self.messageIds = messageIds
        self.forEveryone = forEveryone
    }
}

/// `msg.edit`.
public struct EditMessageRequest: Encodable, Sendable, Hashable {
    public var conversationId: String
    public var messageId: Int64
    public var content: [String: JSONValue]

    public init(conversationId: String, messageId: Int64, content: [String: JSONValue]) {
        self.conversationId = conversationId
        self.messageId = messageId
        self.content = content
    }
}

/// `msg.forward`.
public struct ForwardMessagesRequest: Encodable, Sendable, Hashable {
    public var sourceConversationId: String
    public var messageIds: [Int64]
    public var targetConversationIds: [String]

    /// Bundle them into one `Merged` message instead of forwarding one by one.
    public var merge: Bool
    public var mergeTitle: String?

    /// Idempotency key for the whole forward, not per target.
    public var clientMsgId: String

    public init(
        sourceConversationId: String,
        messageIds: [Int64],
        targetConversationIds: [String],
        merge: Bool = false,
        mergeTitle: String? = nil,
        clientMsgId: String = ClientMessageId.generate()
    ) {
        self.sourceConversationId = sourceConversationId
        self.messageIds = messageIds
        self.targetConversationIds = targetConversationIds
        self.merge = merge
        self.mergeTitle = mergeTitle
        self.clientMsgId = clientMsgId
    }
}

/// `msg.react`.
public struct ReactRequest: Encodable, Sendable, Hashable {
    public var conversationId: String
    public var messageId: Int64
    public var emoji: String

    /// `false` removes the caller's reaction.
    public var add: Bool

    public init(conversationId: String, messageId: Int64, emoji: String, add: Bool = true) {
        self.conversationId = conversationId
        self.messageId = messageId
        self.emoji = emoji
        self.add = add
    }
}

/// `msg.receipt` — per-message read marks, distinct from the conversation pointer in `conv.read`.
public struct ReceiptRequest: Encodable, Sendable, Hashable {
    public var conversationId: String
    public var messageIds: [Int64]

    public init(conversationId: String, messageIds: [Int64]) {
        self.conversationId = conversationId
        self.messageIds = messageIds
    }
}

/// `msg.typing`. Gated by the tenant's `EnableTypingIndicator`; expect `1203` when it is off, and
/// keep calling — the flag can be turned back on at runtime and a client that latched it stays
/// broken until the app restarts.
public struct TypingRequest: Encodable, Sendable, Hashable {
    public var conversationId: String
    public var typing: Bool

    public init(conversationId: String, typing: Bool = true) {
        self.conversationId = conversationId
        self.typing = typing
    }
}

// MARK: - conv

/// `conv.list`.
public struct ListConversationsRequest: Encodable, Sendable, Hashable {
    /// Only conversations changed after this unix-ms timestamp. `0` means all.
    public var updatedAfter: Int64
    public var cursor: String?
    public var limit: Int

    public init(updatedAfter: Int64 = 0, cursor: String? = nil, limit: Int = 50) {
        self.updatedAfter = updatedAfter
        self.cursor = cursor
        self.limit = limit
    }
}

/// `conv.get`, `conv.delete`, `conv.clear`.
public struct ConversationIdRequest: Encodable, Sendable, Hashable {
    public var conversationId: String

    public init(conversationId: String) {
        self.conversationId = conversationId
    }

    public init(_ conversationId: String) {
        self.conversationId = conversationId
    }
}

/// `conv.read`.
public struct ReadRequest: Encodable, Sendable, Hashable {
    public var conversationId: String
    public var readSeq: Int64

    public init(conversationId: String, readSeq: Int64) {
        self.conversationId = conversationId
        self.readSeq = readSeq
    }
}

/// `conv.setting` — pin, mute, draft and tags in one call.
public struct UpdateConversationSettingRequest: Encodable, Sendable, Hashable {
    public var conversationId: String
    public var setting: ConversationSetting?

    public init(conversationId: String, setting: ConversationSetting?) {
        self.conversationId = conversationId
        self.setting = setting
    }
}

// MARK: - user

/// `user.profile`, `friend.delete`, `friend.unblock`.
public struct UserIdRequest: Encodable, Sendable, Hashable {
    public var userId: String

    public init(userId: String) {
        self.userId = userId
    }

    public init(_ userId: String) {
        self.userId = userId
    }
}

/// `user.batchProfile`, `user.presence`, `user.unsubscribePresence`.
///
/// `user.batchProfile` refuses more than 200 ids with `1001`; page it yourself above that.
public struct UserIdsRequest: Encodable, Sendable, Hashable {
    public var userIds: [String]

    public init(userIds: [String]) {
        self.userIds = userIds
    }

    public init(_ userIds: [String]) {
        self.userIds = userIds
    }
}

/// `user.updateProfile` — a patch, not a replacement.
///
/// `appId`, `userId`, `banned`, `silencedUntil`, `createdAt` and `multiLoginOverride` are stripped
/// server-side whatever you put in them: a client must never be able to unban itself.
public struct UpdateProfileRequest: Encodable, Sendable, Hashable {
    public var patch: [String: JSONValue]

    public init(patch: [String: JSONValue]) {
        self.patch = patch
    }
}

/// `user.subscribePresence`.
///
/// Subscriptions carry a TTL rather than living until an explicit unsubscribe, because a client
/// that crashes never sends one. Re-subscribe before `ttlSeconds` elapses. Server clamps to
/// 1…3600, defaulting to 600.
///
/// This call is **not** gated by the tenant's `EnablePresence`, unlike `user.presence`: a subscribe
/// against a presence-disabled app succeeds and then never fires. Do not infer the flag from it.
public struct SubscribePresenceRequest: Encodable, Sendable, Hashable {
    public var userIds: [String]
    public var ttlSeconds: Int

    public init(userIds: [String], ttlSeconds: Int = 600) {
        self.userIds = userIds
        self.ttlSeconds = ttlSeconds
    }
}

// MARK: - media

/// `media.uploadTicket`.
public struct UploadTicketRequest: Encodable, Sendable, Hashable {
    public var fileName: String

    /// MIME type. Required — the tenant's allow-list is checked against it, and `1701` comes back
    /// when it is not allowed.
    public var contentType: String

    public var size: Int64

    public init(fileName: String, contentType: String, size: Int64) {
        self.fileName = fileName
        self.contentType = contentType
        self.size = size
    }
}

/// `media.downloadUrl`.
public struct DownloadUrlRequest: Encodable, Sendable, Hashable {
    /// The key stored in the message, not a URL.
    public var objectKey: String

    /// Server clamps to 1…86400, defaulting to 3600.
    public var lifetimeSeconds: Int

    public init(objectKey: String, lifetimeSeconds: Int = 3600) {
        self.objectKey = objectKey
        self.lifetimeSeconds = lifetimeSeconds
    }
}

// MARK: - push

/// `push.register`.
///
/// Identity comes from the socket. There is deliberately no `userId` or `deviceId` field — the
/// server would ignore them, and a field for something that cannot be said is a field that
/// misleads.
public struct RegisterPushTokenRequest: Encodable, Sendable, Hashable {
    /// One of `apns` `fcm` `huawei` `xiaomi` `oppo` `vivo` `honor`. Common aliases (`ios`,
    /// `firebase`, `hms`, …) are folded server-side; an unknown value is **rejected** with the
    /// legal list rather than stored as a token nothing can route.
    public var provider: String

    /// The vendor's device token, opaque to the platform. On iOS this is the hex encoding of the
    /// `Data` handed to `didRegisterForRemoteNotificationsWithDeviceToken`.
    public var token: String

    /// BCP-47. Defaults to the socket's `lang`.
    public var language: String?

    public init(provider: String = ImPushProvider.apns, token: String, language: String? = nil) {
        self.provider = provider
        self.token = token
        self.language = language
    }
}

/// The vendor channels the server routes to.
///
/// Plain strings rather than an enum: the server folds aliases and rejects unknown values with the
/// legal list, so the authoritative check is server-side and a closed client-side enum would only
/// stop an integrator from using a channel added after their SDK build.
public enum ImPushProvider {
    public static let apns = "apns"
    public static let fcm = "fcm"
    public static let huawei = "huawei"
    public static let xiaomi = "xiaomi"
    public static let oppo = "oppo"
    public static let vivo = "vivo"
    public static let honor = "honor"
}

// MARK: - friend

/// `friend.list`, `friend.blockList`, `group.joined`.
public struct CursorRequest: Encodable, Sendable, Hashable {
    public var cursor: String?
    public var limit: Int

    public init(cursor: String? = nil, limit: Int = 50) {
        self.cursor = cursor
        self.limit = limit
    }
}

/// `friend.add`.
public struct AddFriendRequest: Encodable, Sendable, Hashable {
    public var userId: String
    public var greeting: String?
    public var source: String?

    public init(userId: String, greeting: String? = nil, source: String? = nil) {
        self.userId = userId
        self.greeting = greeting
        self.source = source
    }
}

/// `friend.handleRequest`.
public struct HandleFriendRequest: Encodable, Sendable, Hashable {
    public var fromUserId: String
    public var accept: Bool
    public var reason: String?

    public init(fromUserId: String, accept: Bool, reason: String? = nil) {
        self.fromUserId = fromUserId
        self.accept = accept
        self.reason = reason
    }
}

/// `friend.requestList`.
public struct FriendRequestListRequest: Encodable, Sendable, Hashable {
    /// `true` lists requests sent to me; `false` lists requests I sent.
    public var incoming: Bool
    public var cursor: String?
    public var limit: Int

    public init(incoming: Bool = true, cursor: String? = nil, limit: Int = 50) {
        self.incoming = incoming
        self.cursor = cursor
        self.limit = limit
    }
}

/// `friend.block`.
///
/// Not optional in a shipping app: App Store review treats user blocking as mandatory for anything
/// carrying user-generated content.
public struct BlockRequest: Encodable, Sendable, Hashable {
    public var userId: String
    public var reason: String?

    public init(userId: String, reason: String? = nil) {
        self.userId = userId
        self.reason = reason
    }
}

// MARK: - group

/// `group.info`, `group.dismiss`, `group.quit`.
public struct GroupIdRequest: Encodable, Sendable, Hashable {
    public var groupId: String

    public init(groupId: String) {
        self.groupId = groupId
    }

    public init(_ groupId: String) {
        self.groupId = groupId
    }
}

/// `group.memberList`.
public struct GroupCursorRequest: Encodable, Sendable, Hashable {
    public var groupId: String
    public var cursor: String?
    public var limit: Int

    public init(groupId: String, cursor: String? = nil, limit: Int = 50) {
        self.groupId = groupId
        self.cursor = cursor
        self.limit = limit
    }
}

/// `group.invite`, `group.kick`.
public struct GroupMembersRequest: Encodable, Sendable, Hashable {
    public var groupId: String
    public var userIds: [String]
    public var reason: String?

    public init(groupId: String, userIds: [String], reason: String? = nil) {
        self.groupId = groupId
        self.userIds = userIds
        self.reason = reason
    }
}

/// `group.create`.
public struct CreateGroupRequest: Encodable, Sendable, Hashable {
    /// Supply your own id to make creation idempotent; leave `nil` and the server allocates one.
    public var groupId: String?

    public var name: String
    public var avatar: String?
    public var introduction: String?
    public var type: GroupType
    public var memberIds: [String]
    public var joinMode: GroupJoinMode
    public var inviteMode: GroupInviteMode
    public var maxMemberCount: Int?
    public var extensions: [String: JSONValue]?

    public init(
        name: String,
        memberIds: [String] = [],
        groupId: String? = nil,
        avatar: String? = nil,
        introduction: String? = nil,
        type: GroupType = .normal,
        joinMode: GroupJoinMode = .freeAccess,
        inviteMode: GroupInviteMode = .allMembers,
        maxMemberCount: Int? = nil,
        extensions: [String: JSONValue]? = nil
    ) {
        self.name = name
        self.memberIds = memberIds
        self.groupId = groupId
        self.avatar = avatar
        self.introduction = introduction
        self.type = type
        self.joinMode = joinMode
        self.inviteMode = inviteMode
        self.maxMemberCount = maxMemberCount
        self.extensions = extensions
    }
}

/// The patch half of `group.update`. Every field is optional: `nil` leaves it alone.
public struct UpdateGroupRequest: Encodable, Sendable, Hashable {
    public var name: String?
    public var avatar: String?
    public var introduction: String?
    public var joinMode: GroupJoinMode?
    public var inviteMode: GroupInviteMode?
    public var maxMemberCount: Int?
    public var extensions: [String: JSONValue]?

    public init(
        name: String? = nil,
        avatar: String? = nil,
        introduction: String? = nil,
        joinMode: GroupJoinMode? = nil,
        inviteMode: GroupInviteMode? = nil,
        maxMemberCount: Int? = nil,
        extensions: [String: JSONValue]? = nil
    ) {
        self.name = name
        self.avatar = avatar
        self.introduction = introduction
        self.joinMode = joinMode
        self.inviteMode = inviteMode
        self.maxMemberCount = maxMemberCount
        self.extensions = extensions
    }
}

/// `group.update`.
public struct UpdateGroupCommand: Encodable, Sendable, Hashable {
    public var groupId: String
    public var update: UpdateGroupRequest?

    public init(groupId: String, update: UpdateGroupRequest?) {
        self.groupId = groupId
        self.update = update
    }
}

/// `group.join`.
///
/// Succeeds outright when the group's `joinMode` is `.freeAccess`; with `.needApproval` it lodges
/// an application and comes back `1508`, which is not a failure to show as one.
public struct JoinGroupRequest: Encodable, Sendable, Hashable {
    public var groupId: String
    public var reason: String?

    public init(groupId: String, reason: String? = nil) {
        self.groupId = groupId
        self.reason = reason
    }
}
