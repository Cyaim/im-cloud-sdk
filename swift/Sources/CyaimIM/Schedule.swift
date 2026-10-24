import Foundation

// `msg.schedule` / `msg.scheduled` / `msg.cancelScheduled` — a message written now and sent later
// (T4). The three calls live on ``ImMsgNamespace``, because their prefix is `msg` (CONTRACT.md §4.1);
// what they send and get back is here.
//
// **A scheduled message, once it fires, is an ordinary message.** The server sends it through the
// normal `msg.send` path: the receiver gets a plain `evt.message` with a real seq, and the sender's
// other devices get the usual self-sync. Nothing about it needs decoding of its own, and it reaches
// ``ImClient/messages()``, cursors and gap repair like any other message. **Nothing is pushed when a
// schedule is created, cancelled or fires** — another device of the sender's learns about the outbox
// only by calling `msg.scheduled` again.
//
// **It fires on the server's sweep, not to the millisecond.** The dispatcher runs every 15 seconds by
// default (`IM:Extras:DispatchIntervalSeconds`), so a message goes out on the first sweep after
// ``ScheduleRequest/sendAt`` — up to one interval late, never early.
//
// 定时消息发出之后就是一条普通消息：服务端走普通发送路径，接收方收到带真 seq 的 evt.message，经 messages()、游标与补洞，
// 与任何消息一样。创建、取消、发出都不推送任何事件——发送者的其他设备只能重新调用 msg.scheduled 才知道。
// 发送粒度是服务端的扫描周期（默认 15 秒）：在 sendAt 之后的第一次扫描发出，最多晚一个周期，绝不提前。

// MARK: - Requests

/// `msg.schedule`: the message to send later, and when.
///
/// **Flat, not a nested message.** The server binds these members at the top level and has no
/// `options` and no `sendTime` on this path, deliberately: the scheduler refuses online-only and
/// unstored sends outright, and the clock that matters is ``sendAt``. So this is not
/// ``SendMessageRequest`` with a time added — it is the members of it the scheduler reads.
///
/// **Name the conversation one of three ways** — ``conversationId``, else ``groupId``, else
/// ``receiverId``, in that order of precedence (not the order `msg.streamBegin` uses); none of them is
/// `1001`. The sender must be allowed to write there exactly as `msg.send` requires — a group
/// non-member, a block, a ban are refused here, at scheduling, with the same codes.
///
/// **Refusals:** `1001` for empty ``content``, no address, a ``sendAt`` less than 10 seconds ahead
/// (`IM:Extras:MinScheduleLeadSeconds`) or more than 90 days ahead (`ScheduleHorizonDays`); `1003`
/// for more than 120 schedules created by one user in an hour; `1006` once the user holds 100 still
/// pending (`MaxPendingSchedulesPerUser`) — cancel one first.
///
/// **Not idempotent.** Retrying a `msg.schedule` whose reply was lost creates a second schedule;
/// ``clientMsgId`` only deduplicates the eventual send, and is therefore **not** minted here. After a
/// timeout, list with ``ImMsgNamespace/scheduled(_:)`` before trying again.
///
/// 扁平结构，不是嵌套的消息：服务端在顶层绑定这些成员，这条路径刻意没有 options 和 sendTime。
/// 会话三选一：conversationId 优先，其次 groupId，再次 receiverId。sendAt 至少提前 10 秒、至多 90 天；
/// 每人每小时最多建 120 条（1003），同时待发最多 100 条（1006）。msg.schedule 本身不幂等：
/// 丢了答复就重试会建出第二条，超时之后先 msg.scheduled 列一遍再决定。clientMsgId 留空，不在这里生成。
public struct ScheduleRequest: Encodable, Sendable, Hashable {
    /// When to send, unix ms. At least 10 seconds and at most 90 days ahead of the server's clock.
    public var sendAt: Int64

    /// The content, shaped by ``contentType``; for a text message, `["text": …]`. Empty is `1001`.
    public var content: [String: JSONValue]

    /// An integer on the wire.
    public var contentType: MessageContentType

    public var conversationId: String?
    public var receiverId: String?
    public var groupId: String?

    /// Bound by the server but not used to address the message; the three ids above do that.
    public var conversationType: ConversationType?

    /// The idempotency key of the **eventual send**. Optional here, unlike `msg.send`: left `nil`, the
    /// server uses `sch-<scheduleId>`, which is what makes a re-dispatch after a crash collapse into
    /// the message already stored. It does not make `msg.schedule` itself idempotent, so it is never
    /// filled in for you.
    public var clientMsgId: String?

    public var mentionAll: Bool
    public var mentionedUserIds: [String]

    /// Leaves as a quoted string: the server's field is a `string`. See ``encode(to:)``.
    public var quoteMessageId: Int64?

    /// Leaves as a quoted string: the server's field is a `string`. See ``encode(to:)``.
    public var threadRootId: Int64?

    public var extensions: [String: JSONValue]?

    public init(
        sendAt: Int64,
        content: [String: JSONValue],
        contentType: MessageContentType = .text,
        conversationId: String? = nil,
        receiverId: String? = nil,
        groupId: String? = nil,
        conversationType: ConversationType? = nil,
        clientMsgId: String? = nil,
        mentionAll: Bool = false,
        mentionedUserIds: [String] = [],
        quoteMessageId: Int64? = nil,
        threadRootId: Int64? = nil,
        extensions: [String: JSONValue]? = nil
    ) {
        self.sendAt = sendAt
        self.content = content
        self.contentType = contentType
        self.conversationId = conversationId
        self.receiverId = receiverId
        self.groupId = groupId
        self.conversationType = conversationType
        self.clientMsgId = clientMsgId
        self.mentionAll = mentionAll
        self.mentionedUserIds = mentionedUserIds
        self.quoteMessageId = quoteMessageId
        self.threadRootId = threadRootId
        self.extensions = extensions
    }

    enum CodingKeys: String, CodingKey {
        case sendAt, content, contentType, conversationId, receiverId, groupId, conversationType
        case clientMsgId, mentionAll, mentionedUserIds, quoteMessageId, threadRootId, extensions
    }

    /// Written by hand for two fields: `quoteMessageId` and `threadRootId` leave as **quoted**
    /// strings, as ``SendMessageRequest`` writes them — the server declares both `string?`, and a JSON
    /// number there fails the whole call with `1000` before the endpoint runs.
    ///
    /// Everything else is what the synthesised encoder would write: `encode` for the non-optionals,
    /// `encodeIfPresent` for the optionals, so a `nil` is absent rather than `null`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sendAt, forKey: .sendAt)
        try container.encode(content, forKey: .content)
        try container.encode(contentType, forKey: .contentType)
        try container.encodeIfPresent(conversationId, forKey: .conversationId)
        try container.encodeIfPresent(receiverId, forKey: .receiverId)
        try container.encodeIfPresent(groupId, forKey: .groupId)
        try container.encodeIfPresent(conversationType, forKey: .conversationType)
        try container.encodeIfPresent(clientMsgId, forKey: .clientMsgId)
        try container.encode(mentionAll, forKey: .mentionAll)
        try container.encode(mentionedUserIds, forKey: .mentionedUserIds)
        try container.encodeIfPresent(quoteMessageId.map { String($0) }, forKey: .quoteMessageId)
        try container.encodeIfPresent(threadRootId.map { String($0) }, forKey: .threadRootId)
        try container.encodeIfPresent(extensions, forKey: .extensions)
    }
}

/// `msg.cancelScheduled`: one of the caller's schedules, by ``ScheduledMessage/scheduleId``.
///
/// `1001` for an empty id; `1002` for one that does not exist **or is someone else's**. `1006` when
/// there is nothing left to cancel, and the code is the same for three cases told apart only by the
/// server's message: the dispatcher has started sending it ("already being sent and can no longer be
/// cancelled"), it was cancelled already, or it has already been sent or has failed — a sent one is
/// taken back with `msg.recall`, not here. A cancelled schedule stays in `msg.scheduled` for about 48
/// hours, with ``ScheduledMessage/error`` "cancelled by sender".
///
/// 不存在或不是自己的都回 1002；没有可取消的了回 1006——正在发送、已经取消过、已经发出或失败，三种同码，只有服务端的话不同
/// （已发出的要用 msg.recall 撤回）。取消之后它仍在 msg.scheduled 里留约 48 小时，error 为 "cancelled by sender"。
public struct ScheduleIdRequest: Encodable, Sendable, Hashable {
    public var scheduleId: String

    public init(scheduleId: String) {
        self.scheduleId = scheduleId
    }

    public init(_ scheduleId: String) {
        self.scheduleId = scheduleId
    }
}

// MARK: - Responses

/// One entry of the caller's outbox, as `msg.schedule` answers it and `msg.scheduled` lists it.
///
/// **There is no state field**; the state is read off two members:
///
/// - **pending** — ``messageId`` `nil` and ``error`` `nil`;
/// - **sent** — ``messageId`` set: the stored message's id, which arrived as an ordinary `evt.message`;
/// - **cancelled or failed** — ``error`` set: exactly `"cancelled by sender"` after
///   `msg.cancelScheduled`, otherwise the reason the send failed (`"send failed"` when the server has
///   none better).
///
/// Settled entries — sent, cancelled, failed — stay listed for about 48 hours
/// (`IM:Extras:SettledScheduleRetentionHours`), then disappear.
///
/// 没有状态字段：messageId 与 error 都为空是待发；messageId 有值是已发出；error 有值是已取消（恰为 "cancelled by sender"）
/// 或发送失败（原因，缺省 "send failed"）。已了结的条目约保留 48 小时。
public struct ScheduledMessage: Codable, Sendable, Hashable, Identifiable {
    /// The id to cancel it by. `Identifiable` uses it.
    public let scheduleId: String

    public let appId: String
    public let senderId: String

    /// The conversation the address resolved to at scheduling time.
    public let conversationId: String

    /// Unix ms, as scheduled.
    public let sendAt: Int64

    /// Unix ms, server clock.
    public let createdAt: Int64

    /// The stored message's id, once sent. Arrives as a JSON string and decodes with every digit.
    public let messageId: Int64?

    /// Set when the schedule was cancelled (`"cancelled by sender"`) or failed for good.
    public let error: String?

    public var id: String { scheduleId }

    enum CodingKeys: String, CodingKey {
        case scheduleId, appId, senderId, conversationId, sendAt, createdAt, messageId, error
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scheduleId = c.imString(.scheduleId) ?? ""
        appId = c.imString(.appId) ?? ""
        senderId = c.imString(.senderId) ?? ""
        conversationId = c.imString(.conversationId) ?? ""
        sendAt = c.imInt64(.sendAt) ?? 0
        createdAt = c.imInt64(.createdAt) ?? 0
        messageId = c.imInt64(.messageId)
        error = c.imString(.error)
    }
}
