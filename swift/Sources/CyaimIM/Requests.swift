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

/// `push.clicked` — the tap on a notification.
///
/// Both fields are optional and neither carries identity: the delivery row is located from the
/// socket. A `pushId` is believed only when it names a row belonging to this user on this device,
/// and with neither field the server takes this device's newest delivery — which is the only thing
/// a tap that opened the app without naming a message can mean. So a client cannot mark somebody
/// else's notification clicked, nor probe which `pushId` values exist.
public struct PushClickedRequest: Encodable, Sendable, Hashable {
    /// The delivery's `pu_…` id, when the notification payload carried one.
    public var pushId: String?

    /// The payload's `msgId`, when the tap gave you one.
    ///
    /// A string, because that is how the id arrives in the payload and how every message id travels
    /// on this wire. Do not parse it into an integer to hand it back — the round trip is what loses
    /// digits on a snowflake.
    public var messageId: String?

    public init(pushId: String? = nil, messageId: String? = nil) {
        self.pushId = pushId
        self.messageId = messageId
    }
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

// MARK: - moderation

/// `moderation.report` — one end user reporting another.
///
/// **There is no reporter field and there must not be.** The reporter is the socket: one would let
/// an account file in another's name, which is both a way to get somebody banned and a way to
/// poison the count a moderator decides on. `ModerationController` reads the reporter off the
/// connection, which is the one surface where the identity is a fact rather than a parameter.
///
/// 举报人就是这条连接，没有 reporterId 字段：有了它，一个账号就能以别人的名义举报——
/// 既是把人举报到封禁的路子，也会污染审核员据以决策的那个计数。
public struct SubmitReportRequest: Encodable, Sendable, Hashable {
    /// Who is being reported. Reporting yourself is `1001`.
    public var targetUserId: String

    /// Where it happened, when the report comes from inside a conversation.
    public var conversationId: String?

    /// The message being reported. `0` — the default — reports the account rather than one message.
    ///
    /// A report about a message that has already been deleted is accepted on purpose: nothing here
    /// about the message itself is validated, because that is the report a moderator most wants, and
    /// refusing it would turn the platform's own retention into a way to escape moderation.
    public var messageId: Int64

    /// One of ``ImReportCategory``. `nil` files it under `other`; a value the server does not know
    /// is **rejected** with `1001` rather than quietly filed under `other`.
    public var category: String?

    /// What the reporter typed. Usually the most useful field on the row a moderator opens.
    public var note: String?

    public init(
        targetUserId: String,
        conversationId: String? = nil,
        messageId: Int64 = 0,
        category: String? = nil,
        note: String? = nil
    ) {
        self.targetUserId = targetUserId
        self.conversationId = conversationId
        self.messageId = messageId
        self.category = category
        self.note = note
    }

    enum CodingKeys: String, CodingKey {
        case targetUserId, conversationId, messageId, category, note
    }

    /// Written by hand for one field: `messageId` leaves as a **quoted** string.
    ///
    /// The property stays `Int64` because that is what a message id is on this platform and what
    /// ``RecallMessageRequest`` and ``ReactRequest`` already take; what has to be a string is the
    /// JSON. Message ids are snowflakes past 2^53 by a factor of 38, `SubmitReportRequest.MessageId`
    /// carries `WriteAsString | AllowReadingFromString` on the server for exactly that reason, and a
    /// quoted id is therefore the shape both ends already agree on.
    ///
    /// The `msg.*` requests in this file still write theirs as JSON numbers, which is a defect and
    /// not a convention worth copying: the server's own DTOs for `msg.recall`, `msg.edit`,
    /// `msg.delete`, `msg.forward`, `msg.react` and `msg.receipt` take `string` now, and a JSON
    /// number cannot be read into one at all. Repairing those changes their public field types and
    /// belongs to one pass across all five SDKs — it is not a reason to write a new endpoint the
    /// broken way.
    ///
    /// The optionals keep `encodeIfPresent`, which is what the synthesised encoder would have done
    /// and what the gateway's "nulls are omitted when writing" policy expects.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetUserId, forKey: .targetUserId)
        try container.encodeIfPresent(conversationId, forKey: .conversationId)
        try container.encode(String(messageId), forKey: .messageId)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(note, forKey: .note)
    }
}

/// The categories a report can be filed under.
///
/// Plain strings rather than an enum, for the same reason as ``ImPushProvider``: the server owns
/// the list and rejects anything not on it, so the authoritative check is server-side and a closed
/// client-side enum would only stop an integrator from using a category added after their SDK
/// build. Show these six in the picker; send exactly what the user chose.
public enum ImReportCategory {
    public static let spam = "spam"
    public static let harassment = "harassment"
    public static let fraud = "fraud"
    public static let pornography = "pornography"
    public static let violence = "violence"
    public static let other = "other"
}

/// Reply to `moderation.report`. Deliberately two fields.
///
/// A receipt, not the row: the reporter has no business reading back the moderation state of their
/// own report, and the row carries `handledBy` and `resolution`, which are the tenant's internals.
/// So there is nothing here to poll — show the user that it was filed and stop.
public struct ReportReceipt: Decodable, Sendable, Hashable, Identifiable {
    /// `rp_…`. Worth putting in a support ticket: it is what finds the row.
    public let reportId: String

    /// Server clock, unix ms.
    public let createdAt: Int64

    public var id: String { reportId }

    enum CodingKeys: String, CodingKey {
        case reportId, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reportId = c.imString(.reportId) ?? ""
        createdAt = c.imInt64(.createdAt) ?? 0
    }
}
