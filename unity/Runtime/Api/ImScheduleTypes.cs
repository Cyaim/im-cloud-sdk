using System.Collections.Generic;
using System.Globalization;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    // ---------------------------------------------------------------------- the rule
    //
    // msg.schedule / msg.scheduled / msg.cancelScheduled (T4) queue a message for later. Until it fires a
    // schedule is not a message: no seq, no history, invisible to the recipient, and nothing about it is
    // pushed — there is no evt.* for creating, cancelling or firing one, so another device of the sender
    // learns of it only by listing again. When it fires, the server sends it through the ordinary send
    // path and every receiver (the sender's other devices too) gets an ordinary evt.message with an
    // ordinary seq. That message reaches MessageReceived, the cursors and the gap repair like any other;
    // scheduling one moves no cursor here.
    //
    // 定时消息在发出之前不是消息：没有 seq、不进历史、对方看不到，创建 / 取消 / 发出都没有任何 evt.* 推送，
    // 发送者的其他设备只能重新列一遍。发出时走普通发送路径，接收方（含发送者其他设备）收到一条普通的 evt.message、
    // 普通的 seq，照常经 MessageReceived、游标与补洞。定时这一步不动任何游标。

    // ---------------------------------------------------------------------- requests

    /// <summary>
    /// <c>msg.schedule</c>: a message to send at <see cref="SendAt"/>. The server binds it <b>flat</b> — the
    /// members of <c>msg.send</c> beside <c>sendAt</c>, with no <c>options</c> and no <c>sendTime</c>.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A narrower type than <see cref="ImSendRequest"/> on purpose: the server's <c>ScheduleRequest</c> has
    /// no options (a scheduled send refuses online-only and unstored messages, and the rest would be a
    /// nested object it never reads) and no client clock. A member this type does not have is one the
    /// server would have dropped without a word.
    /// </para>
    /// <para>
    /// Rules, from the server: <see cref="SendAt"/> must be at least 10 seconds ahead and at most 90 days
    /// (<c>1001</c> otherwise); <see cref="Content"/> must be a non-empty object (<c>1001</c>);
    /// <see cref="Recipient"/> is required (<c>1001</c>), and the same access rules as <c>msg.send</c>
    /// apply (not a member, blocked…). At most 100 pending schedules per user (<c>1006</c>) and 120 created
    /// per user per hour (<c>1003</c>). No app setting or add-on gates it.
    /// </para>
    /// <para>
    /// <b>Not idempotent.</b> Retrying a <c>msg.schedule</c> whose reply was lost creates a second schedule;
    /// <see cref="ClientMsgId"/> only deduplicates the eventual send. List with
    /// <see cref="ImMsgApi.ScheduledAsync"/> before retrying.
    /// </para>
    /// <para>
    /// 服务端按「平铺」绑定：msg.send 的字段加 sendAt，没有 options、没有 sendTime——所以这是比 ImSendRequest 更窄的类型。
    /// sendAt 至少提前 10 秒、至多 90 天；content 必须是非空对象；收件地址必填；每人至多 100 条待发（1006）、每小时至多建
    /// 120 条（1003）。msg.schedule 本身不幂等：丢了回复再重试会建出第二条，ClientMsgId 只对最终那次发送去重。
    /// </para>
    /// </remarks>
    public sealed class ImScheduleRequest : IImRequest
    {
        /// <summary>Where it goes, as on <see cref="ImSendRequest"/>: exactly one address is sent. Required.</summary>
        public ImRecipient Recipient { get; set; }

        /// <summary>When to send, unix ms. At least 10 s ahead, at most 90 days. Required.</summary>
        public long SendAt { get; set; }

        /// <summary>
        /// The kind of conversation <see cref="Recipient"/> addresses, declared by the caller. Optional; sent
        /// as its integer. The recipient alone decides where the message goes.
        /// </summary>
        public ImConversationType? ConversationType { get; set; }

        /// <summary>
        /// Idempotency key of the eventual send. Optional here, unlike <c>msg.send</c>: left null it is not
        /// sent and the server uses <c>sch-&lt;scheduleId&gt;</c>, which is what collapses a re-dispatch after
        /// a crash into the message already stored. It does not make <c>msg.schedule</c> itself idempotent.
        /// </summary>
        public string ClientMsgId { get; set; }

        /// <summary>Payload kind, sent as its integer. Defaults to <see cref="ImMessageContentType.Text"/>.</summary>
        public ImMessageContentType ContentType { get; set; }

        /// <summary>Structured payload, shaped by <see cref="ContentType"/>. A non-empty object; required.</summary>
        public JsonValue Content { get; set; }

        /// <summary>Mention everyone in the group. Sent only when true.</summary>
        public bool MentionAll { get; set; }

        /// <summary>Users to mention.</summary>
        public IEnumerable<string> MentionedUserIds { get; set; }

        /// <summary>
        /// Message being quoted — an <see cref="ImMessage.MessageId"/> as it is. Written as its decimal
        /// string: the server's member is a <c>string?</c>, and the socket binder answers <c>1000</c> for a
        /// JSON number there.
        /// </summary>
        public long? QuoteMessageId { get; set; }

        /// <summary>Root of the thread this message replies into, written as a decimal string like <see cref="QuoteMessageId"/>.</summary>
        public long? ThreadRootId { get; set; }

        /// <summary>Tenant-defined extras stored with the message. An object.</summary>
        public JsonValue Extensions { get; set; }

        /// <inheritdoc cref="ImScheduleRequest"/>
        public ImScheduleRequest()
        {
            ContentType = ImMessageContentType.Text;
        }

        /// <inheritdoc cref="ImScheduleRequest"/>
        public ImScheduleRequest(ImRecipient recipient, long sendAt, JsonValue content)
            : this()
        {
            Recipient = recipient;
            SendAt = sendAt;
            Content = content;
        }

        /// <summary>A plain text message, sent at <paramref name="sendAt"/> (unix ms).</summary>
        public static ImScheduleRequest Text(ImRecipient recipient, long sendAt, string text)
        {
            return new ImScheduleRequest(recipient, sendAt, JsonValue.NewObject().Set("text", text));
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject().Set("sendAt", SendAt);
            Recipient.ApplyTo(body);

            if (ConversationType.HasValue)
            {
                body.Set("conversationType", (long)ConversationType.Value);
            }

            body.Set("clientMsgId", string.IsNullOrEmpty(ClientMsgId) ? null : ClientMsgId);
            body.Set("contentType", (long)ContentType);
            body.Set("content", Content ?? JsonValue.NewObject());

            if (MentionAll)
            {
                body.Set("mentionAll", true);
            }

            if (MentionedUserIds != null)
            {
                body.Set("mentionedUserIds", ImJsonArrays.OfStrings(MentionedUserIds));
            }

            if (QuoteMessageId.HasValue)
            {
                body.Set("quoteMessageId", QuoteMessageId.Value.ToString(CultureInfo.InvariantCulture));
            }

            if (ThreadRootId.HasValue)
            {
                body.Set("threadRootId", ThreadRootId.Value.ToString(CultureInfo.InvariantCulture));
            }

            if (Extensions != null)
            {
                body.Set("extensions", Extensions);
            }

            return body;
        }
    }

    /// <summary>Body of <c>msg.cancelScheduled</c>: which schedule.</summary>
    /// <remarks>
    /// Refusals: <c>1002</c> for an unknown schedule or someone else's; <c>1006</c> when nothing is left
    /// to cancel — it is being sent, was already cancelled, or was already sent or failed (only the
    /// server's message tells which; see <see cref="ImMsgApi.CancelScheduledAsync(ImScheduleIdRequest, System.Threading.CancellationToken)"/>).
    /// A cancelled schedule is not removed: it stays in <c>msg.scheduled</c> for about 48 hours with
    /// <see cref="ImScheduledMessage.Error"/> set to <see cref="ImScheduledMessage.CancelledBySender"/>.
    /// 1002：不存在或不是你的；1006：已无可取消——正在发送、已取消、或已发出 / 已失败。取消后不会从列表消失，约 48 小时内带着 "cancelled by sender" 列出。
    /// </remarks>
    public sealed class ImScheduleIdRequest : IImRequest
    {
        /// <summary><see cref="ImScheduledMessage.ScheduleId"/>. Required.</summary>
        public string ScheduleId { get; set; }

        /// <inheritdoc cref="ImScheduleIdRequest"/>
        public ImScheduleIdRequest()
        {
        }

        /// <inheritdoc cref="ImScheduleIdRequest"/>
        public ImScheduleIdRequest(string scheduleId)
        {
            ScheduleId = scheduleId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("scheduleId", ScheduleId);
        }
    }

    // ---------------------------------------------------------------------- reply

    /// <summary>
    /// One queued message, as <c>msg.schedule</c> answers it and <c>msg.scheduled</c> lists it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>There is no state field.</b> The server's contract carries none, so the state is read off two
    /// members:
    /// </para>
    /// <list type="bullet">
    /// <item><b>waiting</b> (or being sent right now) — no <see cref="MessageId"/>, no <see cref="Error"/>;</item>
    /// <item><b>sent</b> — <see cref="MessageId"/> set: the message it became, to match against
    /// <see cref="ImMessage.MessageId"/>;</item>
    /// <item><b>cancelled</b> — <see cref="Error"/> is <see cref="CancelledBySender"/>;</item>
    /// <item><b>failed</b> — any other <see cref="Error"/> ("send failed", or the send path's reason).</item>
    /// </list>
    /// <para>
    /// <c>msg.scheduled</c> lists pending ones <i>and</i> those settled in about the last 48 hours, so a
    /// cancelled or sent entry stays visible for a while. <see cref="IsPending"/>, <see cref="IsSent"/>,
    /// <see cref="IsCancelled"/> and <see cref="IsFailed"/> spell the four out.
    /// </para>
    /// <para>
    /// 没有状态字段：无 MessageId 且无 Error 是等待（或正在发送）；有 MessageId 是已发出；Error 为 "cancelled by sender"
    /// 是已取消；其余 Error 是失败。列表里包括待发的和约 48 小时内已了结的。
    /// </para>
    /// </remarks>
    public sealed class ImScheduledMessage : IImJsonPayload
    {
        /// <summary>The server's <see cref="Error"/> text for a schedule its sender cancelled.</summary>
        public const string CancelledBySender = "cancelled by sender";

        /// <summary>Names it in <c>msg.cancelScheduled</c>.</summary>
        public string ScheduleId { get; private set; }

        /// <summary>Tenant id.</summary>
        public string AppId { get; private set; }

        /// <summary>Who scheduled it — always the caller.</summary>
        public string SenderId { get; private set; }

        /// <summary>The conversation it will be sent into, resolved from the address at scheduling time.</summary>
        public string ConversationId { get; private set; }

        /// <summary>When it is due, unix ms. It fires on the first dispatcher pass after this — every 15 s by default.</summary>
        public long SendAt { get; private set; }

        /// <summary>When it was scheduled, unix ms.</summary>
        public long CreatedAt { get; private set; }

        /// <summary>
        /// The message it became, once sent; null before. A string on the wire (it passes 2^53), read here
        /// without a double; a bare number is read too.
        /// </summary>
        public long? MessageId { get; private set; }

        /// <summary>
        /// Null while waiting and once sent; <see cref="CancelledBySender"/> when cancelled; otherwise why the
        /// send failed for good.
        /// </summary>
        public string Error { get; private set; }

        /// <summary>Waiting for its time, or being sent right now: neither a message id nor an error.</summary>
        public bool IsPending
        {
            get { return !MessageId.HasValue && Error == null; }
        }

        /// <summary>Sent: <see cref="MessageId"/> is the message it became.</summary>
        public bool IsSent
        {
            get { return MessageId.HasValue; }
        }

        /// <summary>Cancelled by its sender.</summary>
        public bool IsCancelled
        {
            get { return !MessageId.HasValue && Error == CancelledBySender; }
        }

        /// <summary>Refused by the send path for a reason that will not change on a retry; see <see cref="Error"/>.</summary>
        public bool IsFailed
        {
            get { return !MessageId.HasValue && Error != null && Error != CancelledBySender; }
        }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            ScheduleId = json["scheduleId"].AsString(string.Empty);
            AppId = json["appId"].AsString(string.Empty);
            SenderId = json["senderId"].AsString(string.Empty);
            ConversationId = json["conversationId"].AsString(string.Empty);
            SendAt = json["sendAt"].AsLong();
            CreatedAt = json["createdAt"].AsLong();
            MessageId = ImPayload.OptionalLong(json, "messageId");
            Error = json["error"].AsString();
        }
    }
}
