package com.cyaim.im.client

import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.LongAsStringSerializer
import kotlinx.serialization.json.JsonObject

/*
 * `msg.schedule` / `msg.scheduled` / `msg.cancelScheduled` — a message written now and sent later
 * (T4). The three calls live on [MsgApi], because their prefix is `msg` (CONTRACT.md §4.1); what they
 * send and get back is here.
 *
 * **A scheduled message, once it fires, is an ordinary message.** The server sends it through the
 * normal `msg.send` path: the receiver gets a plain `evt.message` with a real seq, and the sender's
 * other devices get the usual self-sync. Nothing about it needs decoding of its own, and it reaches
 * [ImClient.messages], cursors and gap repair like any other message. **Nothing is pushed when a
 * schedule is created, cancelled or fires** — another device of the sender's learns about the outbox
 * only by calling `msg.scheduled` again.
 *
 * **It fires on the server's sweep, not to the millisecond.** The dispatcher runs every 15 seconds by
 * default (`IM:Extras:DispatchIntervalSeconds`), so a message goes out on the first sweep after
 * [ScheduleRequest.sendAt] — up to one interval late, never early.
 *
 * 定时消息发出之后就是一条普通消息：服务端走普通发送路径，接收方收到带真 seq 的 evt.message，经 messages、游标与补洞，
 * 与任何消息一样。创建、取消、发出都不推送任何事件——发送者的其他设备只能重新调用 msg.scheduled 才知道。
 * 发送粒度是服务端的扫描周期（默认 15 秒）：在 sendAt 之后的第一次扫描发出，最多晚一个周期，绝不提前。
 */

// ---------------------------------------------------------------------------------- requests

/**
 * `msg.schedule`: the message to send later, and when.
 *
 * **Flat, not a nested message.** The server binds these members at the top level and has no
 * `options` and no `sendTime` on this path, deliberately: the scheduler refuses online-only and
 * unstored sends outright, and the clock that matters is [sendAt]. So this is not
 * [SendMessageRequest] with a time added — it is the members of it the scheduler reads.
 *
 * **Name the conversation one of three ways** — [conversationId], else [groupId], else
 * [receiverId], in that order of precedence; none of them is `1001`. The sender must be allowed to
 * write there exactly as `msg.send` requires (a group non-member, a block, a ban are refused here,
 * at scheduling, with the same codes).
 *
 * **Refusals:** `1001` for empty [content], no address, a [sendAt] less than 10 seconds ahead
 * (`IM:Extras:MinScheduleLeadSeconds`) or more than 90 days ahead (`ScheduleHorizonDays`); `1003`
 * for more than 120 schedules created by one user in an hour; `1006` once the user holds 100 still
 * pending (`MaxPendingSchedulesPerUser`) — cancel one first.
 *
 * **Not idempotent.** Retrying a `msg.schedule` whose reply was lost creates a second schedule;
 * [clientMsgId] only deduplicates the eventual send. After a timeout, list with `msg.scheduled`
 * before trying again.
 *
 * 扁平结构，不是嵌套的消息：服务端在顶层绑定这些成员，这条路径刻意没有 options 和 sendTime。
 * 会话三选一：conversationId 优先，其次 groupId，再次 receiverId。sendAt 至少提前 10 秒、至多 90 天；
 * 每人每小时最多建 120 条（1003），同时待发最多 100 条（1006）。msg.schedule 本身不幂等：
 * 丢了答复就重试会建出第二条，超时之后先 msg.scheduled 列一遍再决定。
 */
@Serializable
public data class ScheduleRequest(
    /** When to send, unix ms. At least 10 seconds and at most 90 days ahead of the server's clock. */
    public val sendAt: Long,
    /** The content, shaped by [contentType]; for a text message, [textContent]. Empty is `1001`. */
    public val content: JsonObject,
    /** An integer on the wire. */
    public val contentType: MessageContentType = MessageContentType.Text,
    public val conversationId: String? = null,
    public val receiverId: String? = null,
    public val groupId: String? = null,
    /** Bound by the server but not used to address the message; the three ids above do that. */
    public val conversationType: ConversationType? = null,
    /**
     * The idempotency key of the **eventual send**. Optional here, unlike `msg.send`: left null, the
     * server uses `sch-<scheduleId>`, which is what makes a re-dispatch after a crash collapse into
     * the message already stored. It does not make `msg.schedule` itself idempotent.
     */
    public val clientMsgId: String? = null,
    public val mentionAll: Boolean = false,
    public val mentionedUserIds: List<String> = emptyList(),
    /** Quoted on the wire: the server's field is a `string`. */
    @Serializable(with = LongAsStringSerializer::class)
    public val quoteMessageId: Long? = null,
    /** Quoted on the wire: the server's field is a `string`. */
    @Serializable(with = LongAsStringSerializer::class)
    public val threadRootId: Long? = null,
    public val extensions: JsonObject? = null,
)

/**
 * `msg.cancelScheduled`: one of the caller's schedules, by [ScheduledMessage.scheduleId].
 *
 * `1001` for an empty id; `1002` for one that does not exist **or is someone else's**. `1006` means
 * **nothing is left to cancel**, three ways, told apart only by the server's message:
 *
 * - in flight — "this message is already being sent and can no longer be cancelled";
 * - already cancelled — "this scheduled message has already been cancelled";
 * - already sent or failed — "this scheduled message has already been sent or has failed, and can
 *   no longer be cancelled". For one that was sent, the remedy is `msg.recall`.
 *
 * A cancelled schedule stays in `msg.scheduled` for about 48 hours, with
 * [ScheduledMessage.error] "cancelled by sender".
 *
 * 不存在或不是自己的都回 1002。1006 表示已经没有可取消的了：正在发送、已经取消过、或已经发出 / 失败，三者只有消息文字不同；
 * 已经发出的要撤回请用 msg.recall。取消之后它仍在 msg.scheduled 里留约 48 小时，error 为 "cancelled by sender"。
 */
@Serializable
public data class ScheduleIdRequest(
    public val scheduleId: String,
)

// --------------------------------------------------------------------------------- responses

/**
 * One entry of the caller's outbox, as `msg.schedule` answers it and `msg.scheduled` lists it.
 *
 * **There is no state field**; the state is read off two members:
 *
 * - **pending** — [messageId] null and [error] null;
 * - **sent** — [messageId] set: the stored message's id, which arrived as an ordinary `evt.message`;
 * - **cancelled or failed** — [error] set: exactly `"cancelled by sender"` after `msg.cancelScheduled`,
 *   otherwise the reason the send failed (`"send failed"` when the server has none better).
 *
 * Settled entries — sent, cancelled, failed — stay listed for about 48 hours
 * (`IM:Extras:SettledScheduleRetentionHours`), then disappear.
 *
 * 没有状态字段：messageId 与 error 都为空是待发；messageId 有值是已发出；error 有值是已取消（恰为 "cancelled by sender"）
 * 或发送失败（原因，缺省 "send failed"）。已了结的条目约保留 48 小时。
 */
@Serializable
public data class ScheduledMessage(
    public val scheduleId: String = "",
    public val appId: String = "",
    public val senderId: String = "",
    /** The conversation the address resolved to at scheduling time. */
    public val conversationId: String = "",
    /** Unix ms, as scheduled. */
    public val sendAt: Long = 0,
    /** Unix ms, server clock. */
    public val createdAt: Long = 0,
    /** The stored message's id, once sent. Arrives as a JSON string and decodes with every digit. */
    public val messageId: Long? = null,
    /** Set when the schedule was cancelled (`"cancelled by sender"`) or failed for good. */
    public val error: String? = null,
)
