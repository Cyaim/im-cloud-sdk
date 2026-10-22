using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    // ---------------------------------------------------------------------- the rule
    //
    // msg.streamBegin / streamAppend / streamComplete / streamAbort are a reply produced a piece at a
    // time — an AI assistant typing it out (T4) — and evt.stream carries the pieces to everyone in the
    // conversation who is online. The four calls are on ImMsgApi, because their prefix is msg
    // (CONTRACT §4.1); everything else about streaming is in this file.
    //
    // The pieces are not messages. An evt.stream frame has no seq, reaches online devices only and is
    // never stored, so nothing about it is ever repaired, synced or committed, and ImClient never lets
    // it near a cursor. What survives is the completed stream: the server stores it as one ordinary
    // message (a real seq, the clientMsgId the stream was opened with) and delivers it on evt.message
    // like any other, to the producer too. That message goes through MessageReceived, the cursors and
    // the gap repair exactly as every other message does, so a device that was offline for the whole
    // generation receives one finished message and not five hundred fragments.
    //
    // 分片不是消息：evt.stream 没有 seq，只投在线设备、从不落库，不补、不同步、不 Commit，ImClient 不让它碰游标。
    // 留下来的是收尾后的那条普通消息——真 seq、clientMsgId 是开流时那个——经 evt.message 投递（生产者自己也收到），
    // 走 MessageReceived、游标与补洞，与任何消息一样。整段生成期间离线的设备收到的是一条完成的消息，而不是几百个碎片。

    // ---------------------------------------------------------------------- options

    /// <summary>
    /// The server's <c>MessageOptions</c>: per-message delivery switches, written as the nested object
    /// the socket binder reads. Every member left null is not sent, and the server's default stands.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Nested keys are matched case-sensitively</b>, and a miscased one is dropped without an error —
    /// which is why this type writes them rather than a hand-built <see cref="JsonValue"/>. Its
    /// <see cref="ToJson"/> is also what to hand <see cref="ImSendRequest.Options"/>.
    /// </para>
    /// <para>
    /// 服务端的 MessageOptions。嵌套对象里的键按大小写精确匹配、写错的会被静默丢掉，所以由这个类型来写。
    /// 留空（null）的成员不发送，服务端默认值生效。
    /// </para>
    /// </remarks>
    public sealed class ImMessageOptions : IImRequest
    {
        /// <summary>Store the message. Server default true; false also means it carries no seq.</summary>
        public bool? Persistent { get; set; }

        /// <summary>Move the conversation's last message and order. Server default true.</summary>
        public bool? UpdateConversation { get; set; }

        /// <summary>Count it as unread. Server default true.</summary>
        public bool? CountUnread { get; set; }

        /// <summary>Send an offline push for it. Server default true.</summary>
        public bool? OfflinePush { get; set; }

        /// <summary>How the offline push looks. Null sends nothing.</summary>
        public ImPushConfig PushConfig { get; set; }

        /// <summary>Ask recipients for a read receipt. Server default false; tenant-gated.</summary>
        public bool? NeedReceipt { get; set; }

        /// <summary>Delivery priority, sent as its integer. Server default <see cref="ImMessagePriority.Normal"/>.</summary>
        public ImMessagePriority? Priority { get; set; }

        /// <summary>Deliver only to sockets open right now. Server default false.</summary>
        public bool? OnlineOnly { get; set; }

        /// <summary>Do not echo it to the sender's other devices. Server default false.</summary>
        public bool? NoSelfSync { get; set; }

        /// <summary>Burn-after-reading lifetime in ms. Null is not ephemeral.</summary>
        public long? ExpireIn { get; set; }

        /// <summary>Skip moderation. Server default false; honoured only where the server allows it.</summary>
        public bool? ModerationBypass { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject();
            SetFlag(body, "persistent", Persistent);
            SetFlag(body, "updateConversation", UpdateConversation);
            SetFlag(body, "countUnread", CountUnread);
            SetFlag(body, "offlinePush", OfflinePush);

            if (PushConfig != null)
            {
                body.Set("pushConfig", PushConfig.ToJson());
            }

            SetFlag(body, "needReceipt", NeedReceipt);
            if (Priority.HasValue)
            {
                body.Set("priority", (long)Priority.Value);
            }

            SetFlag(body, "onlineOnly", OnlineOnly);
            SetFlag(body, "noSelfSync", NoSelfSync);
            body.Set("expireIn", ExpireIn);
            SetFlag(body, "moderationBypass", ModerationBypass);
            return body;
        }

        internal static void SetFlag(JsonValue body, string name, bool? value)
        {
            if (value.HasValue)
            {
                body.Set(name, value.Value);
            }
        }
    }

    /// <summary>
    /// The server's <c>PushConfig</c>, nested inside <see cref="ImMessageOptions.PushConfig"/> — a second
    /// level of case-sensitive keys. Members left null are not sent.
    /// </summary>
    /// <remarks>
    /// A client may not set <see cref="Title"/> or <see cref="Body"/>: a non-empty one is refused with
    /// <c>1103</c>, because the override would drop the sender's name and moderation never reads it.
    /// They are here because the server's type has them and a server-side caller may.
    /// 客户端不能设置非空的 Title / Body（1103）；保留这两个成员只因为服务端类型有它们。
    /// </remarks>
    public sealed class ImPushConfig : IImRequest
    {
        /// <summary>Lock-screen title. Server calls only — a client gets <c>1103</c>.</summary>
        public string Title { get; set; }

        /// <summary>Lock-screen body. Server calls only — a client gets <c>1103</c>.</summary>
        public string Body { get; set; }

        /// <summary>Notification sound.</summary>
        public string Sound { get; set; }

        /// <summary>Handed back to the app when the notification is opened. String values only.</summary>
        public IDictionary<string, string> Payload { get; set; }

        /// <summary>Touch the app badge. Server default true.</summary>
        public bool? BadgeCount { get; set; }

        /// <summary>Vendor channel id (Android notification channel / FCM channel).</summary>
        public string ChannelId { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject()
                .Set("title", Title)
                .Set("body", Body)
                .Set("sound", Sound);

            if (Payload != null)
            {
                var payload = JsonValue.NewObject();
                foreach (var entry in Payload)
                {
                    payload.Set(entry.Key, JsonValue.Of(entry.Value));
                }

                body.Set("payload", payload);
            }

            ImMessageOptions.SetFlag(body, "badgeCount", BadgeCount);
            body.Set("channelId", ChannelId);
            return body;
        }
    }

    // ---------------------------------------------------------------------- requests

    /// <summary>
    /// <c>msg.streamBegin</c>: opens a stream in a single chat or a group and tells every online member
    /// that a reply is coming, so they can draw a placeholder before the first piece.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Only single chats (a chat with yourself included) and groups take a stream</b>: a chat room, a
    /// system or an assistant conversation answers <c>1008</c>, as does a group of more than 200.
    /// <see cref="Recipient"/> names it, as on <see cref="ImSendRequest"/>, so exactly one of
    /// <c>receiverId</c> / <c>groupId</c> / <c>conversationId</c> goes out.
    /// </para>
    /// <para>
    /// Anyone signed in may stream — a player, a bot, a desk agent — but <b>only as themselves</b>,
    /// under the rules of <c>msg.send</c>: <c>1104</c> banned, <c>1408</c> muted, <c>1303</c> blocked,
    /// <c>1302</c> not a friend where the app requires one, <c>1500</c> / <c>1501</c> / <c>1503</c> /
    /// <c>1506</c> / <c>1505</c> for the group. All of it is checked here, at the opening, not at the
    /// end. No app setting or add-on gates streaming. More than 60 openings a minute is <c>1003</c>.
    /// </para>
    /// <para>
    /// 只有单聊（含自己和自己）与不超过 200 人的群可以开流，其余 1008。任何登录用户都能开，但只能以自己的身份、
    /// 按 msg.send 的同一套规则，全在开流时检查；没有任何应用开关管它。
    /// </para>
    /// </remarks>
    public sealed class ImBeginStreamRequest : IImRequest
    {
        /// <summary>Where the stream — and the message it becomes — goes. Required.</summary>
        public ImRecipient Recipient { get; set; }

        /// <summary>
        /// The idempotency key of the message this stream becomes. The server does not make one up
        /// (<c>1001</c> without it): leave it null and <see cref="ImMsgApi.StreamBeginAsync"/> fills it
        /// in <b>on this object</b>, so it can be read back. The stored message carries it, and so does
        /// the <see cref="ImSendResult"/> of <c>msg.streamComplete</c>.
        /// </summary>
        public string ClientMsgId { get; set; }

        /// <summary>
        /// The finished message's content type, sent as its integer. Defaults to
        /// <see cref="ImMessageContentType.Text"/>. Whatever you open with is what the stored message
        /// carries; <see cref="ImMessageContentType.Stream"/> is not something to open with.
        /// </summary>
        public ImMessageContentType ContentType { get; set; }

        /// <summary>
        /// What receivers draw while the stream runs — an assistant's name, an avatar. An object. Echoed
        /// only in the opening <c>evt.stream</c> frame (<see cref="ImStreamEvent.Placeholder"/>); never stored.
        /// </summary>
        public JsonValue Placeholder { get; set; }

        /// <summary>
        /// The finished message's options. Two are refused here, at the opening, with <c>1103</c>: a
        /// non-empty <c>pushConfig.title</c> / <c>body</c>, and unstored media (<c>persistent</c> false
        /// or <c>onlineOnly</c> on an image, voice, video or file) while the app moderates.
        /// </summary>
        public ImMessageOptions Options { get; set; }

        /// <summary>Merged into the finished message; the keys given to <c>msg.streamComplete</c> win. An object.</summary>
        public JsonValue Extensions { get; set; }

        /// <inheritdoc cref="ImBeginStreamRequest"/>
        public ImBeginStreamRequest()
        {
            ContentType = ImMessageContentType.Text;
        }

        /// <inheritdoc cref="ImBeginStreamRequest"/>
        public ImBeginStreamRequest(ImRecipient recipient)
            : this()
        {
            Recipient = recipient;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject();
            Recipient.ApplyTo(body);
            body.Set("clientMsgId", ClientMsgId);
            body.Set("contentType", (long)ContentType);

            if (Placeholder != null)
            {
                body.Set("placeholder", Placeholder);
            }

            if (Options != null)
            {
                body.Set("options", Options.ToJson());
            }

            if (Extensions != null)
            {
                body.Set("extensions", Extensions);
            }

            return body;
        }
    }

    /// <summary>
    /// <c>msg.streamAppend</c>: the next piece. The server numbers the pieces 1, 2, 3… in the order it
    /// accepts them and pushes each as an <c>evt.stream</c> frame.
    /// </summary>
    /// <remarks>
    /// <para>
    /// An empty <see cref="Delta"/> is accepted and does nothing — no frame, no rate token. Refusals:
    /// <c>1002</c> the stream has finished or expired; <c>1103</c> it is someone else's; <c>1401</c> a
    /// piece over 4096 characters, or a stream whose text would pass the server's cap (16384) — <b>the
    /// stream stays open</b>, so send a shorter piece or complete it; <c>1003</c> more than 100 pieces a
    /// second. Each append also resets the idle clock (<see cref="ImStreamHandle.IdleTimeoutSeconds"/>).
    /// </para>
    /// <para>
    /// 空 delta 被接受且什么都不做。1401 之后流仍然开着。每次追加都重置空闲计时。
    /// </para>
    /// </remarks>
    public sealed class ImStreamAppendRequest : IImRequest
    {
        /// <summary><see cref="ImStreamHandle.StreamId"/>. Required.</summary>
        public string StreamId { get; set; }

        /// <summary>The piece. Null is sent as an empty string.</summary>
        public string Delta { get; set; }

        /// <inheritdoc cref="ImStreamAppendRequest"/>
        public ImStreamAppendRequest()
        {
        }

        /// <inheritdoc cref="ImStreamAppendRequest"/>
        public ImStreamAppendRequest(string streamId, string delta)
        {
            StreamId = streamId;
            Delta = delta;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("streamId", StreamId)
                .Set("delta", Delta ?? string.Empty);
        }
    }

    /// <summary>
    /// <c>msg.streamComplete</c>: finishes the stream, stores it as one ordinary message and delivers
    /// that message on <c>evt.message</c> — to the producer's own connection too.
    /// </summary>
    /// <remarks>
    /// <para>
    /// With <see cref="Content"/> null the message is <c>{"text": &lt;every piece, joined in order&gt;}</c>.
    /// A <see cref="Content"/> <b>replaces</b> the pieces rather than being added to them: a producer
    /// can store a cleaned-up version of what it streamed.
    /// </para>
    /// <para>
    /// The send runs through the same pipeline as <c>msg.send</c>, so it can be refused the same ways
    /// (moderation, a webhook, the store). <b>The stream is consumed either way</b>: a refused
    /// completion pushes a terminal frame with an <c>abortReason</c>, and a second complete or abort
    /// answers <c>1002</c>.
    /// </para>
    /// <para>
    /// Content 为空时消息是 {"text": 全部分片按序拼接}；给了 Content 就整个替换分片。收尾可以像 msg.send 一样被拒，
    /// 但无论成败流都被消费掉了：被拒时推一帧带 abortReason 的终止帧，第二次 complete / abort 回 1002。
    /// </para>
    /// </remarks>
    public sealed class ImCompleteStreamRequest : IImRequest
    {
        /// <summary><see cref="ImStreamHandle.StreamId"/>. Required.</summary>
        public string StreamId { get; set; }

        /// <summary>Null keeps the pieces as <c>{"text": …}</c>; an object replaces them.</summary>
        public JsonValue Content { get; set; }

        /// <summary>Merged over <see cref="ImBeginStreamRequest.Extensions"/>; these keys win.</summary>
        public JsonValue Extensions { get; set; }

        /// <inheritdoc cref="ImCompleteStreamRequest"/>
        public ImCompleteStreamRequest()
        {
        }

        /// <inheritdoc cref="ImCompleteStreamRequest"/>
        public ImCompleteStreamRequest(string streamId)
        {
            StreamId = streamId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject().Set("streamId", StreamId);
            if (Content != null)
            {
                body.Set("content", Content);
            }

            if (Extensions != null)
            {
                body.Set("extensions", Extensions);
            }

            return body;
        }
    }

    /// <summary>
    /// <c>msg.streamAbort</c>: ends the stream <b>without a message</b> — the model failed, the player
    /// pressed stop. Everyone watching receives a terminal frame carrying <see cref="Reason"/>, so no
    /// placeholder hangs.
    /// </summary>
    /// <remarks>
    /// Nothing is stored and nothing is delivered on <c>evt.message</c>. A second abort, or an abort after
    /// complete, answers <c>1002</c>.
    /// 不存任何东西，evt.message 上也不会有消息。第二次中止、或收尾之后再中止，回 1002。
    /// </remarks>
    public sealed class ImStreamAbortRequest : IImRequest
    {
        /// <summary><see cref="ImStreamHandle.StreamId"/>. Required.</summary>
        public string StreamId { get; set; }

        /// <summary>
        /// Shown to receivers as <see cref="ImStreamEvent.AbortReason"/>. Null or blank becomes
        /// "aborted by the producer"; cut to 256 characters.
        /// </summary>
        public string Reason { get; set; }

        /// <inheritdoc cref="ImStreamAbortRequest"/>
        public ImStreamAbortRequest()
        {
        }

        /// <inheritdoc cref="ImStreamAbortRequest"/>
        public ImStreamAbortRequest(string streamId, string reason = null)
        {
            StreamId = streamId;
            Reason = reason;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("streamId", StreamId)
                .Set("reason", Reason);
        }
    }

    // ---------------------------------------------------------------------- reply

    /// <summary>What <c>msg.streamBegin</c> answers: the stream to append to.</summary>
    public sealed class ImStreamHandle : IImJsonPayload
    {
        /// <summary><c>st_…</c>. Every other call about this stream names it.</summary>
        public string StreamId { get; private set; }

        /// <summary>The conversation the stream — and the message it becomes — belongs to.</summary>
        public string ConversationId { get; private set; }

        /// <summary>Unix ms. Also the finished message's <c>sendTime</c>.</summary>
        public long StartedAt { get; private set; }

        /// <summary>
        /// Seconds of silence after which the server gives up on the stream (30). There is no limit on
        /// how long a stream may run, only on how long it may go quiet: append or complete within it,
        /// or the stream is reaped — a terminal frame with an <c>abortReason</c>, and no message.
        /// 只限沉默、不限总时长：在这个秒数内追加或收尾，否则流被回收——推一帧带 abortReason 的终止帧，不产生消息。
        /// </summary>
        public int IdleTimeoutSeconds { get; private set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            StreamId = json["streamId"].AsString(string.Empty);
            ConversationId = json["conversationId"].AsString(string.Empty);
            StartedAt = json["startedAt"].AsLong();
            IdleTimeoutSeconds = json["idleTimeoutSeconds"].AsInt();
        }
    }

    // ---------------------------------------------------------------------- evt.stream

    /// <summary>Which of the four kinds of <c>evt.stream</c> frame an <see cref="ImStreamEvent"/> is.</summary>
    public enum ImStreamPhase
    {
        /// <summary>Index 0: a stream opened. No delta; maybe a <see cref="ImStreamEvent.Placeholder"/>.</summary>
        Begin = 0,

        /// <summary>Index 1 and up: one piece.</summary>
        Delta = 1,

        /// <summary>Terminal: the stream became the stored message <see cref="ImStreamEvent.MessageId"/>.</summary>
        Completed = 2,

        /// <summary>
        /// Terminal, no message: the producer aborted, went quiet past the idle timeout, or its completion
        /// was refused by the send pipeline. <see cref="ImStreamEvent.AbortReason"/> says which.
        /// </summary>
        Aborted = 3,
    }

    /// <summary>One <c>evt.stream</c> frame, as <see cref="ImClient.OnStreamEvent"/> delivers it.</summary>
    /// <remarks>
    /// <para>The four kinds share one shape, and <see cref="Phase"/> tells them apart:</para>
    /// <list type="bullet">
    /// <item><see cref="ImStreamPhase.Begin"/> — index 0, not done, <see cref="Placeholder"/> when the producer gave one.</item>
    /// <item><see cref="ImStreamPhase.Delta"/> — index 1, 2, 3…, not done, <see cref="Delta"/>.</item>
    /// <item><see cref="ImStreamPhase.Completed"/> — one past the last piece, done, <see cref="MessageId"/> and <see cref="Seq"/>.</item>
    /// <item><see cref="ImStreamPhase.Aborted"/> — one past the last piece, done, <see cref="AbortReason"/>.</item>
    /// </list>
    /// <para>
    /// <b>A missing index is a missing piece, and nothing will resend it.</b> Pieces are pushed at low
    /// priority and may be shed under load; there is no offset, no resend and no catch-up call. A device
    /// that notices a hole, joins mid-stream (its first frame has an index above 0) or was offline repairs
    /// nothing: it waits for the stored message, which arrives on <see cref="ImClient.MessageReceived"/>
    /// with the whole text. <see cref="ImStreamAssembler"/> does that bookkeeping.
    /// </para>
    /// <para>
    /// 缺一个 index 就是丢了一片，而且没有任何东西会重发：没有偏移、没有重发、没有追补。发现缺口、中途加入
    /// 或离线过的设备什么都不补，等那条存下来的消息——它带着全文从 MessageReceived 到来。
    /// </para>
    /// </remarks>
    public sealed class ImStreamEvent : IImJsonPayload
    {
        /// <summary><c>st_…</c>, the id the producer got from <c>msg.streamBegin</c>.</summary>
        public string StreamId { get; private set; }

        /// <summary>The conversation the stream belongs to.</summary>
        public string ConversationId { get; private set; }

        /// <summary>The producer. Every frame reaches the producer's own connection too.</summary>
        public string SenderId { get; private set; }

        /// <summary>0 for the opening frame, 1… for pieces, one past the last piece for the terminal frame.</summary>
        public int Index { get; private set; }

        /// <summary><see cref="ImStreamPhase.Delta"/> only: the piece's text. Null otherwise.</summary>
        public string Delta { get; private set; }

        /// <summary>True on the terminal frame, whichever way the stream ended.</summary>
        public bool Done { get; private set; }

        /// <summary>
        /// <see cref="ImStreamPhase.Completed"/> only: the stored message — match it against
        /// <see cref="ImMessage.MessageId"/>. A string on the wire (it passes 2^53); a bare number is read
        /// too. Null otherwise.
        /// </summary>
        public long? MessageId { get; private set; }

        /// <summary>
        /// <see cref="ImStreamPhase.Completed"/> only: the stored message's real seq. For matching only —
        /// the message itself moves the cursor when it arrives on <see cref="ImClient.MessageReceived"/>.
        /// </summary>
        public long? Seq { get; private set; }

        /// <summary>
        /// <see cref="ImStreamPhase.Aborted"/> only: the producer's reason, "the producer stopped sending
        /// for 30s", or the send pipeline's refusal.
        /// </summary>
        public string AbortReason { get; private set; }

        /// <summary><see cref="ImStreamPhase.Begin"/> only, when the producer gave one: what to draw meanwhile.</summary>
        public JsonValue Placeholder { get; private set; }

        /// <summary>The whole payload as the server sent it, for a field this build does not name. Never null.</summary>
        public JsonValue Data { get; private set; }

        /// <summary>Done with a message id is completed, done without one aborted; otherwise index 0 is the opening.</summary>
        public ImStreamPhase Phase
        {
            get
            {
                if (Done)
                {
                    return MessageId.HasValue ? ImStreamPhase.Completed : ImStreamPhase.Aborted;
                }

                return Index <= 0 ? ImStreamPhase.Begin : ImStreamPhase.Delta;
            }
        }

        /// <summary>
        /// The <c>data</c> of an <c>evt.stream</c> frame, or null when it is not one this build can read
        /// (not an object, or no stream id). Never throws: a frame of an unexpected shape must not stop
        /// the frames after it.
        /// </summary>
        internal static ImStreamEvent FromData(JsonValue data)
        {
            if (data == null || !data.IsObject || string.IsNullOrEmpty(data["streamId"].AsString()))
            {
                return null;
            }

            return ImPayload.Read<ImStreamEvent>(data);
        }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            Data = json != null && json.IsObject ? json : JsonValue.NewObject();
            StreamId = Data["streamId"].AsString(string.Empty);
            ConversationId = Data["conversationId"].AsString(string.Empty);
            SenderId = Data["senderId"].AsString(string.Empty);
            Index = Data["index"].AsInt();
            Delta = Data["delta"].AsString();
            Done = Data["done"].AsBool();

            // The server writes the id as a string (it passes 2^53); AsLong reads a bare number too.
            // 服务端把 id 写成字符串（它超过 2^53）；裸数字也照读。
            MessageId = ImPayload.OptionalLong(Data, "messageId");
            Seq = ImPayload.OptionalLong(Data, "seq");
            AbortReason = Data["abortReason"].AsString();
            Placeholder = Data["placeholder"].IsObject ? Data["placeholder"] : null;
        }
    }

    // ---------------------------------------------------------------------- assembling

    /// <summary>Where an <see cref="ImStreamState"/> stands.</summary>
    public enum ImStreamStatus
    {
        /// <summary>No terminal frame yet.</summary>
        Streaming = 0,

        /// <summary>The stream became the stored message <see cref="ImStreamState.MessageId"/>; swap the placeholder for it.</summary>
        Completed = 1,

        /// <summary>Ended without a message; <see cref="ImStreamState.AbortReason"/> says why. Nothing will arrive.</summary>
        Aborted = 2,
    }

    /// <summary>
    /// One stream as <see cref="ImStreamAssembler"/> has put it together so far. A snapshot: a later
    /// frame produces a new one.
    /// </summary>
    /// <remarks>
    /// <see cref="Text"/> is <b>for display while the stream runs</b>. The stored message is the truth:
    /// when it arrives on <see cref="ImClient.MessageReceived"/> — matched by <see cref="MessageId"/>
    /// once the terminal frame has named it, or by the <c>clientMsgId</c> the producer opened with —
    /// draw that instead. It can differ from <see cref="Text"/>: the producer may complete with content
    /// that replaces the pieces, and a piece that never reached this device is in the message and not
    /// in <see cref="Text"/>.
    /// Text 只用于流进行时的显示；存下来的那条消息才是准的。两者可能不同：收尾时可以给出替换分片的 content，
    /// 没到这台设备的分片在消息里而不在 Text 里。
    /// </remarks>
    public sealed class ImStreamState
    {
        /// <summary><c>st_…</c>.</summary>
        public string StreamId { get; internal set; }

        /// <summary>The conversation the stream belongs to.</summary>
        public string ConversationId { get; internal set; }

        /// <summary>The producer.</summary>
        public string SenderId { get; internal set; }

        /// <summary>
        /// Every piece received, joined in index order — a hole skipped, not waited on. With no hole and
        /// <see cref="ImStreamStatus.Completed"/> this is the text the server stored, unless the producer
        /// completed with explicit content.
        /// </summary>
        public string Text { get; internal set; }

        /// <summary>Streaming, completed or aborted.</summary>
        public ImStreamStatus Status { get; internal set; }

        /// <summary>Whether the opening frame arrived. False after joining mid-stream: no <see cref="Placeholder"/> to draw.</summary>
        public bool SawBegin { get; internal set; }

        /// <summary>From the opening frame; null when the producer gave none or this device missed it.</summary>
        public JsonValue Placeholder { get; internal set; }

        /// <summary>How many distinct pieces were received.</summary>
        public int Fragments { get; internal set; }

        /// <summary>
        /// Pieces known to be missing: below the highest index seen or, once finished, below the terminal
        /// frame's. Can fall back to 0 after the terminal frame, when a piece it overtook arrives late.
        /// </summary>
        public int MissingFragments { get; internal set; }

        /// <summary><see cref="ImStreamStatus.Completed"/> only: the stored message's id.</summary>
        public long? MessageId { get; internal set; }

        /// <summary><see cref="ImStreamStatus.Completed"/> only: the stored message's seq.</summary>
        public long? Seq { get; internal set; }

        /// <summary><see cref="ImStreamStatus.Aborted"/> only: why.</summary>
        public string AbortReason { get; internal set; }

        /// <summary>The terminal frame has arrived.</summary>
        public bool IsFinished
        {
            get { return Status != ImStreamStatus.Streaming; }
        }

        /// <summary>
        /// <see cref="Text"/> is short of what the producer sent. Do not repair it — nothing can resend a
        /// piece; wait for (or keep) the stored message, which carries the whole text.
        /// </summary>
        public bool HasGap
        {
            get { return MissingFragments > 0; }
        }
    }

    /// <summary>
    /// Puts <c>evt.stream</c> frames back together, one <see cref="ImStreamState"/> per stream, by the
    /// server's rules: pieces ordered by index, duplicates ignored, a hole counted rather than repaired,
    /// the terminal frame deciding completed or aborted.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>The frames do not always arrive in the order they were sent.</b> Pieces are pushed at low
    /// priority and the opening frame, the terminal frame and the finished message are not, and the
    /// server's per-connection queue sends normal frames ahead of queued low ones — so a queued piece can
    /// arrive after the terminal frame, and after the stored message itself. A finished stream is
    /// therefore remembered (the last <see cref="RememberFinished"/> of them) and a late piece updates
    /// it, where it would otherwise open a stream that never ends; a late opening or a second terminal
    /// frame is ignored. A frame for a stream this device never saw open is accepted as a mid-stream join
    /// (<see cref="ImStreamState.SawBegin"/> false).
    /// </para>
    /// <para>
    /// <b>A stream whose terminal frame never arrives</b> — the connection dropped while it ran — stays
    /// <see cref="ImStreamStatus.Streaming"/> here: the server replays no frame. If it was completed, its
    /// message still reaches <see cref="ImClient.MessageReceived"/> through the normal resume. Call
    /// <see cref="Forget"/> or <see cref="Clear"/> when you stop drawing it (on reconnect, say); frames
    /// for a forgotten stream are ignored from then on.
    /// </para>
    /// <para>
    /// Not thread-safe. Feed it from <see cref="ImClient.OnStreamEvent"/>, whose handlers run on the
    /// client's dispatcher — the main thread — one at a time.
    /// </para>
    /// <para>
    /// 分片是低优先级，开流帧、终帧和最终消息不是，所以排队中的分片可能晚于终帧乃至最终消息到达：已结束的流会被记住，
    /// 迟到的分片补进它，而不是新开一条永不结束的流。终帧没到（连接断了）的流在这里一直是 Streaming——服务端不重放；
    /// 不再画它时调用 Forget / Clear。非线程安全，从 OnStreamEvent（主线程）喂它即可。
    /// </para>
    /// </remarks>
    public sealed class ImStreamAssembler
    {
        private readonly Dictionary<string, Assembly> _active = new Dictionary<string, Assembly>(StringComparer.Ordinal);
        private readonly Dictionary<string, Assembly> _finished = new Dictionary<string, Assembly>(StringComparer.Ordinal);
        private readonly LinkedList<string> _finishedOrder = new LinkedList<string>();

        /// <summary>Remembers the last 256 finished streams for late pieces.</summary>
        public ImStreamAssembler()
            : this(256)
        {
        }

        /// <summary>Remembers the last <paramref name="rememberFinished"/> finished streams for late pieces.</summary>
        public ImStreamAssembler(int rememberFinished)
        {
            if (rememberFinished < 0)
            {
                throw new ArgumentOutOfRangeException("rememberFinished");
            }

            RememberFinished = rememberFinished;
        }

        /// <summary>How many finished (or forgotten) streams are kept, oldest evicted first.</summary>
        public int RememberFinished { get; private set; }

        /// <summary>The streams without a terminal frame yet, in no particular order.</summary>
        public List<ImStreamState> Active
        {
            get
            {
                var states = new List<ImStreamState>(_active.Count);
                foreach (var assembly in _active.Values)
                {
                    states.Add(assembly.Snapshot());
                }

                return states;
            }
        }

        /// <summary>The stream's current state, running or remembered; null when it is unknown.</summary>
        public ImStreamState StateOf(string streamId)
        {
            Assembly assembly;
            if (streamId != null && (_active.TryGetValue(streamId, out assembly) || _finished.TryGetValue(streamId, out assembly)))
            {
                return assembly.Snapshot();
            }

            return null;
        }

        /// <summary>
        /// Folds one frame in. Returns the stream's new state, or null when the frame changed nothing — a
        /// duplicate, a late opening or terminal frame, or a frame for a forgotten stream.
        /// </summary>
        public ImStreamState Accept(ImStreamEvent streamEvent)
        {
            if (streamEvent == null)
            {
                throw new ArgumentNullException("streamEvent");
            }

            Assembly finished;
            if (_finished.TryGetValue(streamEvent.StreamId, out finished))
            {
                if (streamEvent.Phase != ImStreamPhase.Delta || finished.Forgotten)
                {
                    return null;
                }

                return finished.AddPiece(streamEvent.Index, streamEvent.Delta) ? finished.Snapshot() : null;
            }

            Assembly assembly;
            if (!_active.TryGetValue(streamEvent.StreamId, out assembly))
            {
                assembly = new Assembly(streamEvent.StreamId, streamEvent.ConversationId, streamEvent.SenderId);
                _active[streamEvent.StreamId] = assembly;
            }

            switch (streamEvent.Phase)
            {
                case ImStreamPhase.Begin:
                    if (assembly.SawBegin)
                    {
                        return null;
                    }

                    assembly.SawBegin = true;
                    assembly.Placeholder = streamEvent.Placeholder;
                    break;

                case ImStreamPhase.Delta:
                    if (!assembly.AddPiece(streamEvent.Index, streamEvent.Delta))
                    {
                        return null;
                    }

                    break;

                default:
                    assembly.Status = streamEvent.Phase == ImStreamPhase.Completed
                        ? ImStreamStatus.Completed
                        : ImStreamStatus.Aborted;
                    assembly.MessageId = streamEvent.MessageId;
                    assembly.Seq = streamEvent.Seq;
                    assembly.AbortReason = streamEvent.AbortReason;

                    // The terminal index is one past the last piece, so it says how many there were.
                    // 终帧的 index 比最后一片大一，所以它说出了一共有几片。
                    assembly.PieceCount = streamEvent.Index > 0 ? streamEvent.Index - 1 : 0;
                    _active.Remove(streamEvent.StreamId);
                    Remember(assembly);
                    break;
            }

            return assembly.Snapshot();
        }

        /// <summary>Stops tracking a stream: returns its last state, and ignores its frames from now on.</summary>
        public ImStreamState Forget(string streamId)
        {
            if (streamId == null)
            {
                return null;
            }

            Assembly assembly;
            if (_active.TryGetValue(streamId, out assembly))
            {
                _active.Remove(streamId);
            }
            else if (!_finished.TryGetValue(streamId, out assembly))
            {
                return null;
            }

            assembly.Forgotten = true;
            Remember(assembly);
            return assembly.Snapshot();
        }

        /// <summary>
        /// Forgets every running stream and returns their last states — for a screen that is going away,
        /// or a connection that dropped while streams were open.
        /// </summary>
        public List<ImStreamState> Clear()
        {
            var ids = new List<string>(_active.Keys);
            var states = new List<ImStreamState>(ids.Count);
            foreach (var id in ids)
            {
                states.Add(Forget(id));
            }

            return states;
        }

        private void Remember(Assembly assembly)
        {
            if (_finished.ContainsKey(assembly.StreamId))
            {
                _finishedOrder.Remove(assembly.StreamId);
            }

            _finished[assembly.StreamId] = assembly;
            _finishedOrder.AddLast(assembly.StreamId);

            while (_finished.Count > RememberFinished)
            {
                var oldest = _finishedOrder.First.Value;
                _finishedOrder.RemoveFirst();
                _finished.Remove(oldest);
            }
        }

        /// <summary>
        /// The mutable half of one stream. Pieces that continue the text are appended to the text;
        /// ones that arrive past a hole wait in <c>_pending</c> until the hole fills (it may never).
        /// </summary>
        private sealed class Assembly
        {
            internal readonly string StreamId;
            internal readonly string ConversationId;
            internal readonly string SenderId;
            internal bool SawBegin;
            internal bool Forgotten;
            internal JsonValue Placeholder;
            internal ImStreamStatus Status;
            internal long? MessageId;
            internal long? Seq;
            internal string AbortReason;

            /// <summary>Known from the terminal frame: one less than its index.</summary>
            internal int? PieceCount;

            private readonly StringBuilder _text = new StringBuilder();
            private readonly SortedDictionary<int, string> _pending = new SortedDictionary<int, string>();

            /// <summary>Pieces 1 to this are all in <c>_text</c>.</summary>
            private int _contiguous;

            internal Assembly(string streamId, string conversationId, string senderId)
            {
                StreamId = streamId;
                ConversationId = conversationId;
                SenderId = senderId;
            }

            /// <summary>False for a duplicate, or an index below 1, which no piece has.</summary>
            internal bool AddPiece(int index, string delta)
            {
                if (index <= _contiguous || _pending.ContainsKey(index))
                {
                    return false;
                }

                delta = delta ?? string.Empty;
                if (index != _contiguous + 1)
                {
                    _pending[index] = delta;
                    return true;
                }

                _text.Append(delta);
                _contiguous = index;

                string next;
                while (_pending.TryGetValue(_contiguous + 1, out next))
                {
                    _pending.Remove(_contiguous + 1);
                    _text.Append(next);
                    _contiguous++;
                }

                return true;
            }

            internal ImStreamState Snapshot()
            {
                var received = _contiguous + _pending.Count;
                var highest = _contiguous;
                var text = new StringBuilder(_text.ToString());
                foreach (var entry in _pending)
                {
                    highest = entry.Key;
                    text.Append(entry.Value);
                }

                var expected = PieceCount.HasValue && PieceCount.Value > highest ? PieceCount.Value : highest;

                return new ImStreamState
                {
                    StreamId = StreamId,
                    ConversationId = ConversationId,
                    SenderId = SenderId,
                    Text = text.ToString(),
                    Status = Status,
                    SawBegin = SawBegin,
                    Placeholder = Placeholder,
                    Fragments = received,
                    MissingFragments = expected - received,
                    MessageId = MessageId,
                    Seq = Seq,
                    AbortReason = AbortReason,
                };
            }
        }
    }

    // ---------------------------------------------------------------------- producing

    /// <summary>
    /// One stream from the producer's side: <see cref="BeginAsync"/>, <see cref="AppendAsync"/> pieces,
    /// then <see cref="CompleteAsync"/> or <see cref="AbortAsync"/>.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A convenience over the four <see cref="ImMsgApi"/> calls, which remain the surface: it holds the
    /// <see cref="Handle"/> and the <see cref="ClientMsgId"/> the stream was opened with, so the caller
    /// does not have to. It is not on <c>im.Msg</c> because nothing there may be anything but an
    /// endpoint (CONTRACT §4.2).
    /// </para>
    /// <code>
    /// var reply = await ImStreamWriter.BeginAsync(im.Msg, new ImBeginStreamRequest(ImRecipient.User("bob")));
    /// try
    /// {
    ///     foreach (var token in tokens) await reply.AppendAsync(token);
    ///     await reply.CompleteAsync();        // stored as {"text": every piece, joined}
    /// }
    /// catch (Exception)
    /// {
    ///     await reply.AbortAsync("the model failed");
    ///     throw;
    /// }
    /// </code>
    /// <para>生产者一侧的便利封装：Begin → Append* → Complete | Abort。四个 im.Msg 调用才是正式的表面。</para>
    /// </remarks>
    public sealed class ImStreamWriter
    {
        private readonly ImMsgApi _msg;

        private ImStreamWriter(ImMsgApi msg, ImStreamHandle handle, string clientMsgId)
        {
            _msg = msg;
            Handle = handle;
            ClientMsgId = clientMsgId;
        }

        /// <summary>What <c>msg.streamBegin</c> answered.</summary>
        public ImStreamHandle Handle { get; private set; }

        /// <summary>The idempotency key of the message this stream becomes.</summary>
        public string ClientMsgId { get; private set; }

        /// <summary>Shorthand for <see cref="ImStreamHandle.StreamId"/>.</summary>
        public string StreamId
        {
            get { return Handle.StreamId; }
        }

        /// <summary>Sends <c>msg.streamBegin</c>, filling a null <see cref="ImBeginStreamRequest.ClientMsgId"/> first.</summary>
        /// <remarks>An invalid argument throws here, before anything is sent, as the call itself does.</remarks>
        public static Task<ImStreamWriter> BeginAsync(
            ImMsgApi msg,
            ImBeginStreamRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            if (msg == null)
            {
                throw new ArgumentNullException("msg");
            }

            return Opened(msg, msg.StreamBeginAsync(request, cancellationToken), request);
        }

        private static async Task<ImStreamWriter> Opened(ImMsgApi msg, Task<ImStreamHandle> beginning, ImBeginStreamRequest request)
        {
            var handle = await beginning.ConfigureAwait(false);
            return new ImStreamWriter(msg, handle, request.ClientMsgId);
        }

        /// <summary><c>msg.streamAppend</c> for this stream.</summary>
        public Task AppendAsync(string delta, CancellationToken cancellationToken = default(CancellationToken))
        {
            return _msg.StreamAppendAsync(new ImStreamAppendRequest(StreamId, delta), cancellationToken);
        }

        /// <summary><c>msg.streamComplete</c> for this stream. Null <paramref name="content"/> stores the pieces as <c>{"text": …}</c>.</summary>
        public Task<ImSendResult> CompleteAsync(
            JsonValue content = null,
            JsonValue extensions = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return _msg.StreamCompleteAsync(
                new ImCompleteStreamRequest(StreamId) { Content = content, Extensions = extensions },
                cancellationToken);
        }

        /// <summary><c>msg.streamAbort</c> for this stream.</summary>
        public Task AbortAsync(string reason = null, CancellationToken cancellationToken = default(CancellationToken))
        {
            return _msg.StreamAbortAsync(new ImStreamAbortRequest(StreamId, reason), cancellationToken);
        }
    }
}
