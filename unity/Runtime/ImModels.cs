using System;
using System.Collections.Generic;
using System.Globalization;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    /// <summary>
    /// A message as the server stored it.
    /// </summary>
    /// <remarks>
    /// Order a conversation by <see cref="Seq"/> and nothing else. <see cref="SendTime"/> is a
    /// client clock and is wrong on some fraction of every real player base; arrival order is wrong
    /// whenever a socket reconnects. <see cref="Seq"/> is gap-free per conversation and is the only
    /// field that defines order.
    /// </remarks>
    public sealed class ImMessage : IImJsonPayload
    {
        /// <summary>Tenant id.</summary>
        public string AppId { get; private set; }

        /// <summary>Conversation this message belongs to.</summary>
        public string ConversationId { get; private set; }

        /// <summary>Single chat, group, room, and so on.</summary>
        public ImConversationType ConversationType { get; private set; }

        /// <summary>
        /// Gap-free position inside the conversation, starting at 1. Ordering and gap repair both
        /// key off this. A <c>seq</c> of 0 means the message was never persisted (typing and other
        /// online-only signals) and must not move any cursor.
        /// </summary>
        public long Seq { get; private set; }

        /// <summary>Globally unique sortable id (snowflake).</summary>
        public long MessageId { get; private set; }

        /// <summary>The sender idempotency key. Equal ids mean the same logical send.</summary>
        public string ClientMsgId { get; private set; }

        /// <summary>User id of the sender.</summary>
        public string SenderId { get; private set; }

        /// <summary>Platform the sender was on.</summary>
        public ImPlatform SenderPlatform { get; private set; }

        /// <summary>Payload kind; determines the shape of <see cref="Content"/>.</summary>
        public ImMessageContentType ContentType { get; private set; }

        /// <summary>
        /// Structured payload. Left as JSON because its shape is defined by
        /// <see cref="ContentType"/> and by whatever custom types the game invents — a fixed C#
        /// class here would make <see cref="ImMessageContentType.Custom"/> unusable.
        /// </summary>
        public JsonValue Content { get; private set; }

        /// <summary>True when the message mentions everyone.</summary>
        public bool MentionAll { get; private set; }

        /// <summary>Explicitly mentioned users. Never null.</summary>
        public List<string> MentionedUserIds { get; private set; }

        /// <summary>The message this one quotes, or 0.</summary>
        public long QuoteMessageId { get; private set; }

        /// <summary>emoji to the users who reacted with it. Null when there are none.</summary>
        public Dictionary<string, List<string>> Reactions { get; private set; }

        /// <summary>Set when the message has been recalled.</summary>
        public ImRecallInfo Recalled { get; private set; }

        /// <summary>Set when the message has been edited.</summary>
        public ImEditInfo Edited { get; private set; }

        /// <summary>Sender clock in unix ms. Display only — never sort by it.</summary>
        public long SendTime { get; private set; }

        /// <summary>Authoritative server clock in unix ms.</summary>
        public long CreateTime { get; private set; }

        /// <summary>Tenant-defined extras. Never null.</summary>
        public JsonValue Extensions { get; private set; }

        /// <summary>Convenience for the common case: the text of a
        /// <see cref="ImMessageContentType.Text"/> message, or null.</summary>
        public string Text
        {
            get { return Content["text"].AsString(); }
        }

        /// <summary>Server-side delivery state.</summary>
        public ImMessageStatus Status { get; private set; }

        /// <summary>Root of the thread this message replies into, or 0.</summary>
        public long ThreadRootId { get; private set; }

        /// <summary>Unix ms after which the server drops the message, or null.</summary>
        public long? ExpireAt { get; private set; }

        /// <summary>Maps a message out of a payload.</summary>
        public static ImMessage FromJson(JsonValue json)
        {
            return ImPayload.Read<ImMessage>(json);
        }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            if (json == null)
            {
                json = JsonValue.Null;
            }

            AppId = json["appId"].AsString(string.Empty);
            ConversationId = json["conversationId"].AsString(string.Empty);
            ConversationType = (ImConversationType)json["conversationType"].AsInt();
            Seq = json["seq"].AsLong();
            MessageId = json["messageId"].AsLong();
            ClientMsgId = json["clientMsgId"].AsString(string.Empty);
            SenderId = json["senderId"].AsString(string.Empty);
            SenderPlatform = (ImPlatform)json["senderPlatform"].AsInt();
            ContentType = (ImMessageContentType)json["contentType"].AsInt();
            Content = json["content"];
            MentionAll = json["mentionAll"].AsBool();
            MentionedUserIds = json["mentionedUserIds"].AsStringList();
            QuoteMessageId = json["quoteMessageId"].AsLong();
            ThreadRootId = json["threadRootId"].AsLong();
            Status = (ImMessageStatus)json["status"].AsInt();
            SendTime = json["sendTime"].AsLong();
            CreateTime = json["createTime"].AsLong();
            ExpireAt = ImPayload.OptionalLong(json, "expireAt");
            Extensions = json["extensions"];

            var reactions = json["reactions"];
            if (reactions.IsObject && reactions.Count > 0)
            {
                Reactions = new Dictionary<string, List<string>>(reactions.Count);
                foreach (var member in reactions.Members)
                {
                    Reactions[member.Key] = member.Value.AsStringList();
                }
            }

            var recalled = json["recalled"];
            if (recalled.IsObject)
            {
                Recalled = new ImRecallInfo
                {
                    OperatorId = recalled["operatorId"].AsString(string.Empty),
                    RecallTime = recalled["recallTime"].AsLong(),
                    ByAdmin = recalled["byAdmin"].AsBool(),
                    Reason = recalled["reason"].AsString(),
                };
            }

            var edited = json["edited"];
            if (edited.IsObject)
            {
                Edited = new ImEditInfo
                {
                    OperatorId = edited["operatorId"].AsString(string.Empty),
                    EditTime = edited["editTime"].AsLong(),
                    Version = edited["version"].AsInt(),
                };
            }
        }
    }

    /// <summary>Recall metadata attached to a message that was taken back.</summary>
    public sealed class ImRecallInfo
    {
        /// <summary>Who recalled it.</summary>
        public string OperatorId { get; internal set; }

        /// <summary>When, in unix ms.</summary>
        public long RecallTime { get; internal set; }

        /// <summary>True when a moderator or admin did it rather than the sender.</summary>
        public bool ByAdmin { get; internal set; }

        /// <summary>Optional reason shown to the user.</summary>
        public string Reason { get; internal set; }
    }

    /// <summary>Edit metadata attached to a message that was changed after sending.</summary>
    public sealed class ImEditInfo
    {
        /// <summary>Who edited it.</summary>
        public string OperatorId { get; internal set; }

        /// <summary>When, in unix ms.</summary>
        public long EditTime { get; internal set; }

        /// <summary>Monotonic edit version, so a late frame cannot overwrite a newer body.</summary>
        public int Version { get; internal set; }
    }

    /// <summary>What the server returns for an accepted send.</summary>
    public sealed class ImSendResult : IImJsonPayload
    {
        /// <summary>Global message id.</summary>
        public long MessageId { get; private set; }

        /// <summary>Position in the conversation. Holding this means the message is persisted.</summary>
        public long Seq { get; private set; }

        /// <summary>Conversation the message landed in — resolved server-side for a receiver-id send.</summary>
        public string ConversationId { get; private set; }

        /// <summary>The idempotency key that was used.</summary>
        public string ClientMsgId { get; private set; }

        /// <summary>Server clock in unix ms.</summary>
        public long CreateTime { get; private set; }

        /// <summary>
        /// True when the server matched an earlier send with the same <see cref="ClientMsgId"/> and
        /// returned the original result. A retry after a timeout lands here, which is the whole
        /// point of generating the id up front.
        /// </summary>
        public bool Deduplicated { get; private set; }

        /// <summary>True when moderation altered the payload before storing it.</summary>
        public bool ContentModified { get; private set; }

        /// <summary>Maps a send result out of a payload.</summary>
        public static ImSendResult FromJson(JsonValue json)
        {
            return ImPayload.Read<ImSendResult>(json);
        }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            if (json == null)
            {
                json = JsonValue.Null;
            }

            MessageId = json["messageId"].AsLong();
            Seq = json["seq"].AsLong();
            ConversationId = json["conversationId"].AsString(string.Empty);
            ClientMsgId = json["clientMsgId"].AsString(string.Empty);
            CreateTime = json["createTime"].AsLong();
            Deduplicated = json["deduplicated"].AsBool();
            ContentModified = json["contentModified"].AsBool();
        }
    }

    /// <summary>One row of the conversation list.</summary>
    public sealed class ImConversationView : IImJsonPayload
    {
        /// <summary>Conversation id.</summary>
        public string ConversationId { get; private set; }

        /// <summary>Single, group, room, and so on.</summary>
        public ImConversationType Type { get; private set; }

        /// <summary>Highest seq the server holds for this conversation.</summary>
        public long MaxSeq { get; private set; }

        /// <summary>Seq this user has read up to.</summary>
        public long ReadSeq { get; private set; }

        /// <summary>
        /// Unread count, derived server-side from <see cref="MaxSeq"/> minus <see cref="ReadSeq"/>
        /// rather than kept as a counter — which is why every device agrees on the badge.
        /// </summary>
        public long UnreadCount { get; private set; }

        /// <summary>Pinned to the top of the list.</summary>
        public bool Pinned { get; private set; }

        /// <summary>Do-not-disturb level.</summary>
        public ImMuteMode Muted { get; private set; }

        /// <summary>Unsent draft, synced across devices.</summary>
        public string Draft { get; private set; }

        /// <summary>Tenant-defined tags. Never null.</summary>
        public List<string> Tags { get; private set; }

        /// <summary>
        /// The user marked this unread by hand, so the badge must stay lit even though
        /// <see cref="ReadSeq"/> says otherwise.
        /// </summary>
        public bool ManuallyUnread { get; private set; }

        /// <summary>Last change to this conversation, in unix ms. Feed the newest one back as
        /// <c>updatedAfter</c> to fetch only what moved.</summary>
        public long UpdatedAt { get; private set; }

        /// <summary>Digest of the newest message, for rendering the list without loading history.</summary>
        public ImConversationPreview LastMessage { get; private set; }

        /// <summary>
        /// The other participant, on a single chat, when the server chose to inline it. Null
        /// otherwise — resolve the peer with <c>user.batchProfile</c> rather than assuming this.
        /// </summary>
        public ImUserProfile Peer { get; private set; }

        /// <summary>The group, on a group conversation, when the server chose to inline it.</summary>
        public ImGroup Group { get; private set; }

        /// <summary>Tenant-defined extras. Never null.</summary>
        public JsonValue Extensions { get; private set; }

        /// <summary>Maps a conversation view out of a payload.</summary>
        public static ImConversationView FromJson(JsonValue json)
        {
            return ImPayload.Read<ImConversationView>(json);
        }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            if (json == null)
            {
                json = JsonValue.Null;
            }

            ConversationId = json["conversationId"].AsString(string.Empty);
            Type = (ImConversationType)json["type"].AsInt();
            MaxSeq = json["maxSeq"].AsLong();
            ReadSeq = json["readSeq"].AsLong();
            UnreadCount = json["unreadCount"].AsLong();
            Pinned = json["pinned"].AsBool();
            Muted = (ImMuteMode)json["muted"].AsInt();
            Draft = json["draft"].AsString();
            Tags = json["tags"].AsStringList();
            ManuallyUnread = json["manuallyUnread"].AsBool();
            UpdatedAt = json["updatedAt"].AsLong();
            Extensions = json["extensions"];

            LastMessage = ImConversationPreview.Read(json["lastMessage"]);

            var peer = json["peer"];
            if (peer.IsObject)
            {
                Peer = ImUserProfile.FromJson(peer);
            }

            var group = json["group"];
            if (group.IsObject)
            {
                Group = ImGroup.FromJson(group);
            }
        }
    }

    /// <summary>
    /// The one-line summary of a message: a conversation's <c>lastMessage</c>, and a pin's
    /// <see cref="ImPinnedMessage.Brief"/>. The server calls this shape <c>MessageBrief</c>.
    /// </summary>
    public sealed class ImConversationPreview
    {
        /// <summary>Id of the previewed message.</summary>
        public long MessageId { get; internal set; }

        /// <summary>Seq of the previewed message.</summary>
        public long Seq { get; internal set; }

        /// <summary>Who sent it.</summary>
        public string SenderId { get; internal set; }

        /// <summary>Its content type.</summary>
        public ImMessageContentType ContentType { get; internal set; }

        /// <summary>Server-rendered short text, already safe to display.</summary>
        public string Digest { get; internal set; }

        /// <summary>Server clock in unix ms.</summary>
        public long CreateTime { get; internal set; }

        /// <summary>True when the previewed message was recalled.</summary>
        public bool Recalled { get; internal set; }

        /// <summary>Maps a brief out of a payload, or returns null when the member is absent or not an object.</summary>
        internal static ImConversationPreview Read(JsonValue json)
        {
            if (json == null || !json.IsObject)
            {
                return null;
            }

            return new ImConversationPreview
            {
                MessageId = json["messageId"].AsLong(),
                Seq = json["seq"].AsLong(),
                SenderId = json["senderId"].AsString(string.Empty),
                ContentType = (ImMessageContentType)json["contentType"].AsInt(),
                Digest = json["digest"].AsString(string.Empty),
                CreateTime = json["createTime"].AsLong(),
                Recalled = json["recalled"].AsBool(),
            };
        }
    }

    /// <summary>One page of a cursor-paginated list. Every list endpoint returns this shape.</summary>
    /// <remarks>
    /// The page is handed back whole rather than flattened to a bare list, because
    /// <see cref="NextCursor"/> is the only correct way to page and an SDK that hid it would force
    /// every caller into the wrong loop. In particular: <b>never stop because
    /// <see cref="Items"/> is shorter than the limit you asked for.</b> The server computes the
    /// cursor on the raw page, before rows this user may not see are filtered out, so a short page
    /// with <see cref="HasMore"/> set is ordinary rather than exceptional.
    /// </remarks>
    /// <typeparam name="T">Row type.</typeparam>
    public sealed class ImPage<T>
    {
        /// <summary>Rows in this page. Never null.</summary>
        public List<T> Items { get; internal set; }

        /// <summary>Opaque cursor to pass back for the next page; null when exhausted.</summary>
        public string NextCursor { get; internal set; }

        /// <summary>True when another page exists. This, and only this, ends a paging loop.</summary>
        public bool HasMore { get; internal set; }

        /// <summary>
        /// Total rows behind the cursor, when the store can answer that cheaply; null when it
        /// cannot. Null is not zero, and rendering it as one is a visible bug.
        /// </summary>
        public long? Total { get; internal set; }

        internal ImPage()
        {
            Items = new List<T>();
        }

        /// <summary>Maps a page out of a payload, given a mapper for one row.</summary>
        public static ImPage<T> FromJson(JsonValue data, Func<JsonValue, T> map)
        {
            if (data == null)
            {
                data = JsonValue.Null;
            }

            var page = new ImPage<T>
            {
                NextCursor = data["nextCursor"].AsString(),
                HasMore = data["hasMore"].AsBool(),
                Total = ImPayload.OptionalLong(data, "total"),
            };

            foreach (var item in data["items"].Items)
            {
                page.Items.Add(map(item));
            }

            return page;
        }
    }

    /// <summary>
    /// Where a message is going. One of three addressing modes, made explicit so a call site cannot
    /// silently pass a user id where a conversation id belongs.
    /// </summary>
    public readonly struct ImRecipient
    {
        private readonly int _mode;
        private readonly string _id;

        private ImRecipient(int mode, string id)
        {
            _mode = mode;
            _id = id;
        }

        /// <summary>Addresses the single chat with this user, creating it on first send.</summary>
        public static ImRecipient User(string userId)
        {
            return new ImRecipient(1, userId);
        }

        /// <summary>Addresses a group by its id.</summary>
        public static ImRecipient Group(string groupId)
        {
            return new ImRecipient(2, groupId);
        }

        /// <summary>Addresses an existing conversation directly.</summary>
        public static ImRecipient Conversation(string conversationId)
        {
            return new ImRecipient(3, conversationId);
        }

        /// <summary>True when this recipient was never assigned a target.</summary>
        public bool IsEmpty
        {
            get { return _mode == 0 || string.IsNullOrEmpty(_id); }
        }

        internal void ApplyTo(JsonValue body)
        {
            switch (_mode)
            {
                case 1:
                    body.Set("receiverId", _id);
                    break;
                case 2:
                    body.Set("groupId", _id);
                    break;
                case 3:
                    body.Set("conversationId", _id);
                    break;
            }
        }

        /// <inheritdoc/>
        public override string ToString()
        {
            switch (_mode)
            {
                case 1:
                    return "user:" + _id;
                case 2:
                    return "group:" + _id;
                case 3:
                    return "conversation:" + _id;
                default:
                    return "(empty)";
            }
        }
    }

    /// <summary>
    /// A message to send. Only <see cref="Content"/> and a target are required; everything else has
    /// a sane default, and <see cref="ClientMsgId"/> is generated when left null.
    /// </summary>
    public sealed class ImSendRequest
    {
        /// <summary>Where it goes.</summary>
        public ImRecipient Recipient { get; set; }

        /// <summary>Payload kind. Defaults to <see cref="ImMessageContentType.Text"/>.</summary>
        public ImMessageContentType ContentType { get; set; }

        /// <summary>Structured payload. Build it with <see cref="JsonValue.NewObject"/>.</summary>
        public JsonValue Content { get; set; }

        /// <summary>
        /// Idempotency key. Leave it null and the SDK generates one, which is what makes a retry
        /// after a timeout safe. Set it yourself only when your own domain already has a natural
        /// key for this send — an order id, a quest completion — so a retry across a process
        /// restart still deduplicates.
        /// </summary>
        public string ClientMsgId { get; set; }

        /// <summary>Users to mention.</summary>
        public IEnumerable<string> MentionedUserIds { get; set; }

        /// <summary>Mention everyone in the group.</summary>
        public bool MentionAll { get; set; }

        /// <summary>Message being quoted, if any — an <see cref="ImMessage.MessageId"/> as it is.</summary>
        /// <remarks>
        /// A <c>long</c> here so it takes a message id unconverted, and written to the body as the
        /// decimal string of that id: the server's member is a <c>string?</c>, and the gateway's socket
        /// binder refuses a JSON number for a string member, so a numeric one made every quoting send
        /// come back <c>1000 InternalError</c>.
        /// 这里是 long，线路上写成十进制字符串：服务端字段是 string?，数字会被套接字绑定器以 1000 拒绝。
        /// </remarks>
        public long? QuoteMessageId { get; set; }

        /// <summary>
        /// Root of the thread this message replies into, if any — the root's
        /// <see cref="ImMessage.MessageId"/> as it is, the same value <see cref="ImMessage.ThreadRootId"/>
        /// reads back on every reply.
        /// </summary>
        /// <remarks>
        /// Written to the body as the decimal string of that id, like <see cref="QuoteMessageId"/>: the
        /// server's member is a <c>string?</c>, and the socket binder refuses a JSON number there with
        /// <c>1000</c>. Left null, the message is not a thread reply and the key is not sent.
        /// 线程回复的根消息 id；与 QuoteMessageId 一样按十进制字符串发送。不设置则不是线程回复。
        /// </remarks>
        public long? ThreadRootId { get; set; }

        /// <summary>
        /// The kind of conversation the <see cref="Recipient"/> addresses, declared by the caller. Optional.
        /// </summary>
        /// <remarks>
        /// An assertion, not addressing: the recipient alone decides where the message goes. When set,
        /// the server refuses the send if the address names another kind — <c>Single</c> for
        /// <see cref="ImRecipient.User"/>, <c>Group</c> for <see cref="ImRecipient.Group"/>, and for
        /// <see cref="ImRecipient.Conversation"/> the kind its id's prefix names (<c>s_</c>, <c>g_</c>,
        /// <c>r_</c>, <c>sys_</c>). Sent as its integer; left null, the key is not sent.
        /// 调用方声明的会话类型，只做断言：与收件地址所指的会话类型不符时服务端拒绝发送。
        /// </remarks>
        public ImConversationType? ConversationType { get; set; }

        /// <summary>Per-message delivery switches: offline push, unread counting, persistence.</summary>
        public JsonValue Options { get; set; }

        /// <summary>Tenant-defined extras stored with the message.</summary>
        public JsonValue Extensions { get; set; }

        /// <inheritdoc cref="ImSendRequest"/>
        public ImSendRequest()
        {
            ContentType = ImMessageContentType.Text;
        }

        internal JsonValue ToJson(string clientMsgId, long sendTime)
        {
            var body = JsonValue.NewObject();
            Recipient.ApplyTo(body);

            body.Set("contentType", (long)ContentType);
            body.Set("content", Content ?? JsonValue.NewObject());
            body.Set("clientMsgId", clientMsgId);
            body.Set("sendTime", sendTime);

            if (MentionAll)
            {
                body.Set("mentionAll", true);
            }

            if (MentionedUserIds != null)
            {
                body.Set("mentionedUserIds", JsonValue.ArrayOf(MentionedUserIds));
            }

            if (QuoteMessageId.HasValue)
            {
                body.Set("quoteMessageId", QuoteMessageId.Value.ToString(CultureInfo.InvariantCulture));
            }

            if (ThreadRootId.HasValue)
            {
                body.Set("threadRootId", ThreadRootId.Value.ToString(CultureInfo.InvariantCulture));
            }

            if (ConversationType.HasValue)
            {
                body.Set("conversationType", (long)ConversationType.Value);
            }

            if (Options != null)
            {
                body.Set("options", Options);
            }

            if (Extensions != null)
            {
                body.Set("extensions", Extensions);
            }

            return body;
        }
    }

    /// <summary>Details of a server-initiated disconnect.</summary>
    public readonly struct ImKick
    {
        /// <summary>Parsed reason.</summary>
        public ImKickReason Reason { get; }

        /// <summary>The raw text after <c>im-kick:</c>, for logs and for reasons this build predates.</summary>
        public string RawReason { get; }

        /// <summary>
        /// True when reconnecting would fail identically forever, so the SDK has stopped. Show the
        /// player a real message: they are not coming back without an app-level action.
        /// </summary>
        public bool IsTerminal { get; }

        /// <inheritdoc cref="ImKick"/>
        public ImKick(ImKickReason reason, string rawReason, bool isTerminal)
        {
            Reason = reason;
            RawReason = rawReason;
            IsTerminal = isTerminal;
        }

        /// <inheritdoc/>
        public override string ToString()
        {
            return "ImKick(" + RawReason + (IsTerminal ? ", terminal)" : ")");
        }
    }
}
