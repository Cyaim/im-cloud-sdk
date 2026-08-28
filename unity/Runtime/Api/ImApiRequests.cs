using System.Collections.Generic;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    /// <summary>
    /// A request body the SDK can serialise. Every typed method takes exactly one of these.
    /// </summary>
    /// <remarks>
    /// One object per endpoint rather than positional parameters, and that is not a style
    /// preference: with positional parameters the server adding one optional field is a
    /// source-breaking change in five languages at once, while with a request object it is additive
    /// everywhere. Convenience overloads exist only where a request has at most two required scalar
    /// fields and nothing optional.
    /// </remarks>
    public interface IImRequest
    {
        /// <summary>Builds the wire body. Null members are omitted, per the gateway's JSON policy.</summary>
        JsonValue ToJson();
    }

    /// <summary>
    /// The vendor channels <c>push.register</c> accepts.
    /// </summary>
    /// <remarks>
    /// Send one explicitly. An empty provider falls back to the platform default, which is only
    /// reliable on iOS — Android fragments across five OEM channels and the server cannot guess
    /// which one a token came from. An unrecognised value is rejected with the legal list rather
    /// than stored as a token nothing can route.
    /// </remarks>
    public static class ImPushProvider
    {
        /// <summary>Apple Push Notification service.</summary>
        public const string Apns = "apns";

        /// <summary>Firebase Cloud Messaging.</summary>
        public const string Fcm = "fcm";

        /// <summary>Huawei Mobile Services push.</summary>
        public const string Huawei = "huawei";

        /// <summary>Xiaomi push.</summary>
        public const string Xiaomi = "xiaomi";

        /// <summary>OPPO push.</summary>
        public const string Oppo = "oppo";

        /// <summary>vivo push.</summary>
        public const string Vivo = "vivo";

        /// <summary>Honor push.</summary>
        public const string Honor = "honor";
    }

    // ------------------------------------------------------------------------ conn

    /// <summary>Body of <c>conn.reauth</c>.</summary>
    public sealed class ImReauthRequest : IImRequest
    {
        /// <summary>A fresh user token for the same user. A token for anyone else is refused.</summary>
        public string Token { get; set; }

        /// <inheritdoc cref="ImReauthRequest"/>
        public ImReauthRequest()
        {
        }

        /// <inheritdoc cref="ImReauthRequest"/>
        public ImReauthRequest(string token)
        {
            Token = token;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("token", Token);
        }
    }

    /// <summary>Body of <c>conn.sync</c>.</summary>
    /// <remarks>
    /// <see cref="ConvSeqs"/> must carry <c>committedSeq</c> — what the application has durably
    /// stored — never the highest seq the SDK has delivered. Reporting the delivered one is the
    /// data-loss bug in <c>sdk/CONTRACT.md</c> §5.1. <see cref="ImClient"/> builds this itself; the
    /// type is public because a tenant with its own store may drive the call directly.
    /// </remarks>
    public sealed class ImResumeRequest : IImRequest
    {
        /// <summary>conversationId to committedSeq. Entries at 0 are the same as absent.</summary>
        public Dictionary<string, long> ConvSeqs { get; set; }

        /// <summary>Newest <c>updatedAt</c> from a completed run. 0 asks for everything.</summary>
        public long ConversationCursor { get; set; }

        /// <summary>Paging cursor from the previous page's <c>nextCursor</c>.</summary>
        public string Cursor { get; set; }

        /// <summary>Conversations per page. The server clamps to 1…500; anything else becomes 200.</summary>
        public int Limit { get; set; }

        /// <inheritdoc cref="ImResumeRequest"/>
        public ImResumeRequest()
        {
            Limit = 200;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject();

            var seqs = JsonValue.NewObject();
            if (ConvSeqs != null)
            {
                foreach (var entry in ConvSeqs)
                {
                    if (entry.Value > 0)
                    {
                        seqs.Set(entry.Key, entry.Value);
                    }
                }
            }

            return body
                .Set("convSeqs", seqs)
                .Set("conversationCursor", ConversationCursor)
                .Set("cursor", Cursor)
                .Set("limit", (long)Limit);
        }
    }

    // ------------------------------------------------------------------------- msg

    /// <summary>Body of <c>msg.sync</c>.</summary>
    public sealed class ImSyncMessagesRequest : IImRequest
    {
        /// <summary>Conversation to read.</summary>
        public string ConversationId { get; set; }

        /// <summary>Inclusive lower bound.</summary>
        public long FromSeq { get; set; }

        /// <summary>Inclusive upper bound; 0 means "up to the newest".</summary>
        public long ToSeq { get; set; }

        /// <summary>Messages per call. The server clamps this to 500 whatever you ask for.</summary>
        public int Limit { get; set; }

        /// <summary>False walks backwards from <see cref="ToSeq"/>.</summary>
        public bool Ascending { get; set; }

        /// <inheritdoc cref="ImSyncMessagesRequest"/>
        public ImSyncMessagesRequest()
        {
            Limit = 100;
            Ascending = true;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("conversationId", ConversationId)
                .Set("fromSeq", FromSeq)
                .Set("toSeq", ToSeq)
                .Set("limit", (long)Limit)
                .Set("ascending", Ascending);
        }
    }

    /// <summary>Body of <c>msg.history</c>.</summary>
    public sealed class ImHistoryRequest : IImRequest
    {
        /// <summary>Conversation to read.</summary>
        public string ConversationId { get; set; }

        /// <summary>Seq of the oldest message you hold; null starts at the newest.</summary>
        public long? BeforeSeq { get; set; }

        /// <summary>Rows per page. The server clamps to 200.</summary>
        public int Limit { get; set; }

        /// <inheritdoc cref="ImHistoryRequest"/>
        public ImHistoryRequest()
        {
            Limit = 20;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("conversationId", ConversationId)
                .Set("beforeSeq", BeforeSeq)
                .Set("limit", (long)Limit);
        }
    }

    /// <summary>Body of <c>msg.recall</c>.</summary>
    /// <remarks>
    /// There is no admin flag here on purpose: the server forces one off for any client call, so a
    /// field for it would be a lie about what this request can do. Admin recall is a tenant-backend
    /// operation.
    /// </remarks>
    public sealed class ImRecallMessageRequest : IImRequest
    {
        /// <summary>Conversation the message is in.</summary>
        public string ConversationId { get; set; }

        /// <summary>Which message.</summary>
        public string MessageId { get; set; }

        /// <summary>Optional reason shown to other participants.</summary>
        public string Reason { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("conversationId", ConversationId)
                .Set("messageId", MessageId)
                .Set("reason", Reason);
        }
    }

    /// <summary>Body of <c>msg.delete</c>. Delete-for-me; distinct from recall.</summary>
    public sealed class ImDeleteMessagesRequest : IImRequest
    {
        /// <summary>Conversation the messages are in.</summary>
        public string ConversationId { get; set; }

        /// <summary>Which messages. Never empty.</summary>
        public List<string> MessageIds { get; set; }

        /// <summary>True removes it for every participant; false hides it only for you.</summary>
        public bool ForEveryone { get; set; }

        /// <inheritdoc cref="ImDeleteMessagesRequest"/>
        public ImDeleteMessagesRequest()
        {
            MessageIds = new List<string>();
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("conversationId", ConversationId)
                .Set("messageIds", ImJsonArrays.OfStrings(MessageIds))
                .Set("forEveryone", ForEveryone);
        }
    }

    /// <summary>Body of <c>msg.typing</c>.</summary>
    public sealed class ImTypingRequest : IImRequest
    {
        /// <summary>Conversation being typed into.</summary>
        public string ConversationId { get; set; }

        /// <summary>False reports that typing stopped.</summary>
        public bool Typing { get; set; }

        /// <inheritdoc cref="ImTypingRequest"/>
        public ImTypingRequest()
        {
            Typing = true;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("conversationId", ConversationId)
                .Set("typing", Typing);
        }
    }

    /// <summary>Body of <c>msg.edit</c>.</summary>
    public sealed class ImEditMessageRequest : IImRequest
    {
        /// <summary>Conversation the message is in.</summary>
        public string ConversationId { get; set; }

        /// <summary>Which message.</summary>
        public string MessageId { get; set; }

        /// <summary>The replacement payload, shaped by the message's content type.</summary>
        public JsonValue Content { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("conversationId", ConversationId)
                .Set("messageId", MessageId)
                .Set("content", Content != null ? Content : JsonValue.NewObject());
        }
    }

    /// <summary>Body of <c>msg.forward</c>.</summary>
    public sealed class ImForwardMessagesRequest : IImRequest
    {
        /// <summary>Where the messages are being taken from.</summary>
        public string SourceConversationId { get; set; }

        /// <summary>Which messages.</summary>
        public List<string> MessageIds { get; set; }

        /// <summary>Where they are going. One send per target.</summary>
        public List<string> TargetConversationIds { get; set; }

        /// <summary>True bundles them into one merged message instead of forwarding one by one.</summary>
        public bool Merge { get; set; }

        /// <summary>Title of the merged bundle, when <see cref="Merge"/> is set.</summary>
        public string MergeTitle { get; set; }

        /// <summary>
        /// Idempotency key. Left null the SDK generates one — which is what makes a retry after a
        /// timeout safe, exactly as it is for a send.
        /// </summary>
        public string ClientMsgId { get; set; }

        /// <inheritdoc cref="ImForwardMessagesRequest"/>
        public ImForwardMessagesRequest()
        {
            MessageIds = new List<string>();
            TargetConversationIds = new List<string>();
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("sourceConversationId", SourceConversationId)
                .Set("messageIds", ImJsonArrays.OfStrings(MessageIds))
                .Set("targetConversationIds", JsonValue.ArrayOf(TargetConversationIds))
                .Set("merge", Merge)
                .Set("mergeTitle", MergeTitle)
                .Set("clientMsgId", ClientMsgId);
        }
    }

    /// <summary>Body of <c>msg.react</c>.</summary>
    public sealed class ImReactRequest : IImRequest
    {
        /// <summary>Conversation the message is in.</summary>
        public string ConversationId { get; set; }

        /// <summary>Which message.</summary>
        public string MessageId { get; set; }

        /// <summary>The emoji, as the tenant spells it.</summary>
        public string Emoji { get; set; }

        /// <summary>False removes this user's reaction.</summary>
        public bool Add { get; set; }

        /// <inheritdoc cref="ImReactRequest"/>
        public ImReactRequest()
        {
            Add = true;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("conversationId", ConversationId)
                .Set("messageId", MessageId)
                .Set("emoji", Emoji)
                .Set("add", Add);
        }
    }

    /// <summary>Body of <c>msg.receipt</c>. Per-message read acks, distinct from the conversation cursor.</summary>
    public sealed class ImReceiptRequest : IImRequest
    {
        /// <summary>Conversation the messages are in.</summary>
        public string ConversationId { get; set; }

        /// <summary>Which messages were read.</summary>
        public List<string> MessageIds { get; set; }

        /// <inheritdoc cref="ImReceiptRequest"/>
        public ImReceiptRequest()
        {
            MessageIds = new List<string>();
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("conversationId", ConversationId)
                .Set("messageIds", ImJsonArrays.OfStrings(MessageIds));
        }
    }

    // ------------------------------------------------------------------------ conv

    /// <summary>Body of <c>conv.list</c>.</summary>
    public sealed class ImListConversationsRequest : IImRequest
    {
        /// <summary>Only rows changed after this unix-ms timestamp. 0 returns all of them.</summary>
        public long UpdatedAfter { get; set; }

        /// <summary>Paging cursor from the previous page.</summary>
        public string Cursor { get; set; }

        /// <summary>Rows per page. The server clamps to 200.</summary>
        public int Limit { get; set; }

        /// <inheritdoc cref="ImListConversationsRequest"/>
        public ImListConversationsRequest()
        {
            Limit = 50;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("updatedAfter", UpdatedAfter)
                .Set("cursor", Cursor)
                .Set("limit", (long)Limit);
        }
    }

    /// <summary>Body of <c>conv.get</c>, <c>conv.delete</c> and <c>conv.clear</c>.</summary>
    public sealed class ImConversationIdRequest : IImRequest
    {
        /// <summary>Which conversation.</summary>
        public string ConversationId { get; set; }

        /// <inheritdoc cref="ImConversationIdRequest"/>
        public ImConversationIdRequest()
        {
        }

        /// <inheritdoc cref="ImConversationIdRequest"/>
        public ImConversationIdRequest(string conversationId)
        {
            ConversationId = conversationId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("conversationId", ConversationId);
        }
    }

    /// <summary>Body of <c>conv.read</c>.</summary>
    public sealed class ImReadRequest : IImRequest
    {
        /// <summary>Which conversation.</summary>
        public string ConversationId { get; set; }

        /// <summary>Seq the user has read up to. Unread everywhere is derived from this.</summary>
        public long ReadSeq { get; set; }

        /// <inheritdoc cref="ImReadRequest"/>
        public ImReadRequest()
        {
        }

        /// <inheritdoc cref="ImReadRequest"/>
        public ImReadRequest(string conversationId, long readSeq)
        {
            ConversationId = conversationId;
            ReadSeq = readSeq;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("conversationId", ConversationId)
                .Set("readSeq", ReadSeq);
        }
    }

    /// <summary>Per-user state on one conversation. Every member is optional; null leaves it alone.</summary>
    public sealed class ImConversationSetting : IImRequest
    {
        /// <summary>Pin to the top of the list.</summary>
        public bool? Pinned { get; set; }

        /// <summary>Do-not-disturb level.</summary>
        public ImMuteMode? Muted { get; set; }

        /// <summary>Unsent draft, synced across this user's devices.</summary>
        public string Draft { get; set; }

        /// <summary>Tenant-defined tags. Folders are views over these.</summary>
        public List<string> Tags { get; set; }

        /// <summary>Tenant-defined extras.</summary>
        public JsonValue Extensions { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject();

            if (Pinned.HasValue)
            {
                body.Set("pinned", Pinned.Value);
            }

            if (Muted.HasValue)
            {
                body.Set("muted", (long)Muted.Value);
            }

            body.Set("draft", Draft);

            if (Tags != null)
            {
                body.Set("tags", JsonValue.ArrayOf(Tags));
            }

            if (Extensions != null)
            {
                body.Set("extensions", Extensions);
            }

            return body;
        }
    }

    /// <summary>Body of <c>conv.setting</c>.</summary>
    public sealed class ImUpdateConversationSettingRequest : IImRequest
    {
        /// <summary>Which conversation.</summary>
        public string ConversationId { get; set; }

        /// <summary>What to change. Members left null are not touched.</summary>
        public ImConversationSetting Setting { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("conversationId", ConversationId)
                .Set("setting", Setting != null ? Setting.ToJson() : JsonValue.NewObject());
        }
    }

    // ------------------------------------------------------------------------ user

    /// <summary>Body of <c>user.profile</c>, <c>friend.delete</c> and <c>friend.unblock</c>.</summary>
    public sealed class ImUserIdRequest : IImRequest
    {
        /// <summary>Which user.</summary>
        public string UserId { get; set; }

        /// <inheritdoc cref="ImUserIdRequest"/>
        public ImUserIdRequest()
        {
        }

        /// <inheritdoc cref="ImUserIdRequest"/>
        public ImUserIdRequest(string userId)
        {
            UserId = userId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("userId", UserId);
        }
    }

    /// <summary>Body of <c>user.batchProfile</c>, <c>user.presence</c> and <c>user.unsubscribePresence</c>.</summary>
    /// <remarks>
    /// The batch endpoint takes at most 200 ids per call and refuses more, which is a limit worth
    /// knowing before a conversation list with three hundred participants hits it.
    /// </remarks>
    public sealed class ImUserIdsRequest : IImRequest
    {
        /// <summary>Which users. At most 200 for <c>user.batchProfile</c>.</summary>
        public List<string> UserIds { get; set; }

        /// <inheritdoc cref="ImUserIdsRequest"/>
        public ImUserIdsRequest()
        {
            UserIds = new List<string>();
        }

        /// <inheritdoc cref="ImUserIdsRequest"/>
        public ImUserIdsRequest(IEnumerable<string> userIds)
        {
            UserIds = new List<string>();
            if (userIds != null)
            {
                UserIds.AddRange(userIds);
            }
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("userIds", JsonValue.ArrayOf(UserIds));
        }
    }

    /// <summary>Body of <c>user.updateProfile</c>. A patch, not a whole profile.</summary>
    /// <remarks>
    /// A client may only patch itself, and the platform strips the fields it owns —
    /// <c>appId</c>, <c>userId</c>, <c>banned</c>, <c>silencedUntil</c>, <c>createdAt</c>,
    /// <c>multiLoginOverride</c> — whatever the body says. Sending them is not an error; they are
    /// simply dropped.
    /// </remarks>
    public sealed class ImUpdateProfileRequest : IImRequest
    {
        /// <summary>Fields to change. Never empty, or the server refuses the call.</summary>
        public JsonValue Patch { get; set; }

        /// <inheritdoc cref="ImUpdateProfileRequest"/>
        public ImUpdateProfileRequest()
        {
            Patch = JsonValue.NewObject();
        }

        /// <inheritdoc cref="ImUpdateProfileRequest"/>
        public ImUpdateProfileRequest(JsonValue patch)
        {
            Patch = patch != null ? patch : JsonValue.NewObject();
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("patch", Patch != null ? Patch : JsonValue.NewObject());
        }
    }

    /// <summary>Body of <c>user.subscribePresence</c>.</summary>
    /// <remarks>
    /// Subscriptions carry a TTL rather than living until an explicit unsubscribe, because a client
    /// that crashes never sends one. Re-subscribe while the user is watching a roster.
    /// A subscribe against a presence-disabled app <i>succeeds</i> and then never fires — do not
    /// infer the feature flag from it; only <c>user.presence</c> reports 1203.
    /// </remarks>
    public sealed class ImSubscribePresenceRequest : IImRequest
    {
        /// <summary>Who to watch.</summary>
        public List<string> UserIds { get; set; }

        /// <summary>Seconds the subscription lives. Clamped to 1…3600; anything else becomes 600.</summary>
        public int TtlSeconds { get; set; }

        /// <inheritdoc cref="ImSubscribePresenceRequest"/>
        public ImSubscribePresenceRequest()
        {
            UserIds = new List<string>();
            TtlSeconds = 600;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("userIds", JsonValue.ArrayOf(UserIds))
                .Set("ttlSeconds", (long)TtlSeconds);
        }
    }

    // ----------------------------------------------------------------------- media

    /// <summary>Body of <c>media.uploadTicket</c>.</summary>
    public sealed class ImUploadTicketRequest : IImRequest
    {
        /// <summary>Original file name. The server derives the extension and the object key from it.</summary>
        public string FileName { get; set; }

        /// <summary>MIME type. The tenant's allow-list is checked against this.</summary>
        public string ContentType { get; set; }

        /// <summary>Size in bytes, checked against the tenant's ceiling before a ticket is issued.</summary>
        public long Size { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("fileName", FileName)
                .Set("contentType", ContentType)
                .Set("size", Size);
        }
    }

    /// <summary>Body of <c>media.downloadUrl</c>.</summary>
    public sealed class ImDownloadUrlRequest : IImRequest
    {
        /// <summary>The stored object key, as it appears in the message content.</summary>
        public string ObjectKey { get; set; }

        /// <summary>How long the signed URL lives. Clamped to 1…86400; anything else becomes 3600.</summary>
        public int LifetimeSeconds { get; set; }

        /// <inheritdoc cref="ImDownloadUrlRequest"/>
        public ImDownloadUrlRequest()
        {
            LifetimeSeconds = 3600;
        }

        /// <inheritdoc cref="ImDownloadUrlRequest"/>
        public ImDownloadUrlRequest(string objectKey)
            : this()
        {
            ObjectKey = objectKey;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("objectKey", ObjectKey)
                .Set("lifetimeSeconds", (long)LifetimeSeconds);
        }
    }

    // ------------------------------------------------------------------------ push

    /// <summary>Body of <c>push.register</c>.</summary>
    /// <remarks>
    /// Identity comes from the socket. There is deliberately no <c>userId</c> or <c>deviceId</c>
    /// here — the server ignores both, and "register a token against someone else's device" is not
    /// merely forbidden, there is no field in which to say it.
    /// </remarks>
    public sealed class ImRegisterPushTokenRequest : IImRequest
    {
        /// <summary>Vendor channel. See <see cref="ImPushProvider"/>; always send one.</summary>
        public string Provider { get; set; }

        /// <summary>The vendor's device token, opaque to the platform.</summary>
        public string Token { get; set; }

        /// <summary>BCP-47 tag for notification text. Null falls back to the socket's language.</summary>
        public string Language { get; set; }

        /// <inheritdoc cref="ImRegisterPushTokenRequest"/>
        public ImRegisterPushTokenRequest()
        {
        }

        /// <inheritdoc cref="ImRegisterPushTokenRequest"/>
        public ImRegisterPushTokenRequest(string provider, string token, string language = null)
        {
            Provider = provider;
            Token = token;
            Language = language;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("provider", Provider)
                .Set("token", Token)
                .Set("language", Language);
        }
    }

    /// <summary>Body of <c>push.clicked</c>. Both members optional; identity comes from the socket.</summary>
    /// <remarks>
    /// <para>
    /// Send whatever the notification payload handed you and nothing more. The server finds the
    /// delivery row from this connection: a <see cref="PushId"/> is believed only when the row it
    /// names belongs to this user on this device, and with neither member the newest delivery to
    /// this device is the one a tap can only have meant. That is what stops a client marking
    /// somebody else's notification clicked, or probing which <c>pu_…</c> ids exist.
    /// </para>
    /// <para>
    /// <see cref="MessageId"/> is a string for the reason every message id in this SDK is one: the
    /// ids are snowflakes far past 2^53, and a number loses its low digits somewhere along a route
    /// that includes browsers.
    /// messageId 是字符串：雪花 id 早已越过 2^53，走数字会在半路丢掉低位。
    /// </para>
    /// </remarks>
    public sealed class ImPushClickedRequest : IImRequest
    {
        /// <summary>The delivery's <c>pu_…</c> id, when the payload carried one.</summary>
        public string PushId { get; set; }

        /// <summary>The payload's <c>msgId</c>, when the tap gave you one.</summary>
        public string MessageId { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("pushId", PushId)
                .Set("messageId", MessageId);
        }
    }

    // ---------------------------------------------------------------------- friend

    /// <summary>Body of <c>friend.list</c>, <c>friend.blockList</c> and <c>group.joined</c>.</summary>
    public sealed class ImCursorRequest : IImRequest
    {
        /// <summary>Paging cursor from the previous page.</summary>
        public string Cursor { get; set; }

        /// <summary>Rows per page. Clamped to 1…200; anything else becomes 50.</summary>
        public int Limit { get; set; }

        /// <inheritdoc cref="ImCursorRequest"/>
        public ImCursorRequest()
        {
            Limit = 50;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("cursor", Cursor)
                .Set("limit", (long)Limit);
        }
    }

    /// <summary>Body of <c>friend.add</c>.</summary>
    public sealed class ImAddFriendRequest : IImRequest
    {
        /// <summary>
        /// Who to ask. Asking yourself is refused with
        /// <see cref="ImErrorCode.CannotAddSelf"/>.
        /// </summary>
        public string UserId { get; set; }

        /// <summary>Message shown with the request.</summary>
        public string Greeting { get; set; }

        /// <summary>Where the request came from — search, card, QR — for the tenant's own analytics.</summary>
        public string Source { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("userId", UserId)
                .Set("greeting", Greeting)
                .Set("source", Source);
        }
    }

    /// <summary>Body of <c>friend.handleRequest</c>.</summary>
    public sealed class ImHandleFriendRequest : IImRequest
    {
        /// <summary>Who asked.</summary>
        public string FromUserId { get; set; }

        /// <summary>True accepts, false refuses.</summary>
        public bool Accept { get; set; }

        /// <summary>Reason shown to the asker.</summary>
        public string Reason { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("fromUserId", FromUserId)
                .Set("accept", Accept)
                .Set("reason", Reason);
        }
    }

    /// <summary>Body of <c>friend.requestList</c>.</summary>
    public sealed class ImFriendRequestListRequest : IImRequest
    {
        /// <summary>True lists requests sent to this user; false lists the ones they sent.</summary>
        public bool Incoming { get; set; }

        /// <summary>Paging cursor from the previous page.</summary>
        public string Cursor { get; set; }

        /// <summary>Rows per page. Clamped to 1…200; anything else becomes 50.</summary>
        public int Limit { get; set; }

        /// <inheritdoc cref="ImFriendRequestListRequest"/>
        public ImFriendRequestListRequest()
        {
            Incoming = true;
            Limit = 50;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("incoming", Incoming)
                .Set("cursor", Cursor)
                .Set("limit", (long)Limit);
        }
    }

    /// <summary>Body of <c>friend.block</c>.</summary>
    /// <remarks>
    /// Not optional surface: app-store review treats user blocking as mandatory for any app
    /// carrying user-generated content.
    /// </remarks>
    public sealed class ImBlockRequest : IImRequest
    {
        /// <summary>Who to block.</summary>
        public string UserId { get; set; }

        /// <summary>Reason recorded with the block, for the tenant's own moderation trail.</summary>
        public string Reason { get; set; }

        /// <inheritdoc cref="ImBlockRequest"/>
        public ImBlockRequest()
        {
        }

        /// <inheritdoc cref="ImBlockRequest"/>
        public ImBlockRequest(string userId, string reason = null)
        {
            UserId = userId;
            Reason = reason;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("userId", UserId)
                .Set("reason", Reason);
        }
    }

    // ----------------------------------------------------------------------- group

    /// <summary>Body of <c>group.create</c>.</summary>
    /// <remarks>
    /// The caller is always added as a member and is always the owner, whatever
    /// <see cref="MemberIds"/> says.
    /// </remarks>
    public sealed class ImCreateGroupRequest : IImRequest
    {
        /// <summary>Choose the id yourself, or leave it null and the server allocates one.</summary>
        public string GroupId { get; set; }

        /// <summary>Display name. Required.</summary>
        public string Name { get; set; }

        /// <summary>Avatar object key or URL.</summary>
        public string Avatar { get; set; }

        /// <summary>Description shown before joining.</summary>
        public string Introduction { get; set; }

        /// <summary>Normal, super, or chat room.</summary>
        public ImGroupType Type { get; set; }

        /// <summary>Founding members besides the caller.</summary>
        public List<string> MemberIds { get; set; }

        /// <summary>How a stranger gets in.</summary>
        public ImGroupJoinMode JoinMode { get; set; }

        /// <summary>Who may invite.</summary>
        public ImGroupInviteMode InviteMode { get; set; }

        /// <summary>Ceiling for this group; null takes the tenant's default.</summary>
        public int? MaxMemberCount { get; set; }

        /// <summary>Tenant-defined extras.</summary>
        public JsonValue Extensions { get; set; }

        /// <inheritdoc cref="ImCreateGroupRequest"/>
        public ImCreateGroupRequest()
        {
            Type = ImGroupType.Normal;
            MemberIds = new List<string>();
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject()
                .Set("groupId", GroupId)
                .Set("name", Name)
                .Set("avatar", Avatar)
                .Set("introduction", Introduction)
                .Set("type", (long)Type)
                .Set("memberIds", JsonValue.ArrayOf(MemberIds))
                .Set("joinMode", (long)JoinMode)
                .Set("inviteMode", (long)InviteMode);

            if (MaxMemberCount.HasValue)
            {
                body.Set("maxMemberCount", (long)MaxMemberCount.Value);
            }

            if (Extensions != null)
            {
                body.Set("extensions", Extensions);
            }

            return body;
        }
    }

    /// <summary>Body of <c>group.info</c>, <c>group.dismiss</c> and <c>group.quit</c>.</summary>
    public sealed class ImGroupIdRequest : IImRequest
    {
        /// <summary>Which group.</summary>
        public string GroupId { get; set; }

        /// <inheritdoc cref="ImGroupIdRequest"/>
        public ImGroupIdRequest()
        {
        }

        /// <inheritdoc cref="ImGroupIdRequest"/>
        public ImGroupIdRequest(string groupId)
        {
            GroupId = groupId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("groupId", GroupId);
        }
    }

    /// <summary>The mutable half of a group. Every member is optional; null leaves it alone.</summary>
    public sealed class ImUpdateGroupRequest : IImRequest
    {
        /// <summary>New display name.</summary>
        public string Name { get; set; }

        /// <summary>New avatar object key or URL.</summary>
        public string Avatar { get; set; }

        /// <summary>New description.</summary>
        public string Introduction { get; set; }

        /// <summary>New join policy.</summary>
        public ImGroupJoinMode? JoinMode { get; set; }

        /// <summary>New invite policy.</summary>
        public ImGroupInviteMode? InviteMode { get; set; }

        /// <summary>New member ceiling.</summary>
        public int? MaxMemberCount { get; set; }

        /// <summary>Tenant-defined extras.</summary>
        public JsonValue Extensions { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            var body = JsonValue.NewObject()
                .Set("name", Name)
                .Set("avatar", Avatar)
                .Set("introduction", Introduction);

            if (JoinMode.HasValue)
            {
                body.Set("joinMode", (long)JoinMode.Value);
            }

            if (InviteMode.HasValue)
            {
                body.Set("inviteMode", (long)InviteMode.Value);
            }

            if (MaxMemberCount.HasValue)
            {
                body.Set("maxMemberCount", (long)MaxMemberCount.Value);
            }

            if (Extensions != null)
            {
                body.Set("extensions", Extensions);
            }

            return body;
        }
    }

    /// <summary>Body of <c>group.update</c>: which group, and what to change about it.</summary>
    public sealed class ImUpdateGroupCommand : IImRequest
    {
        /// <summary>Which group.</summary>
        public string GroupId { get; set; }

        /// <summary>What to change. Members left null are not touched.</summary>
        public ImUpdateGroupRequest Update { get; set; }

        /// <inheritdoc cref="ImUpdateGroupCommand"/>
        public ImUpdateGroupCommand()
        {
        }

        /// <inheritdoc cref="ImUpdateGroupCommand"/>
        public ImUpdateGroupCommand(string groupId, ImUpdateGroupRequest update)
        {
            GroupId = groupId;
            Update = update;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("groupId", GroupId)
                .Set("update", Update != null ? Update.ToJson() : JsonValue.NewObject());
        }
    }

    /// <summary>Body of <c>group.invite</c> and <c>group.kick</c>.</summary>
    public sealed class ImGroupMembersRequest : IImRequest
    {
        /// <summary>Which group.</summary>
        public string GroupId { get; set; }

        /// <summary>Which users. Never empty.</summary>
        public List<string> UserIds { get; set; }

        /// <summary>Reason recorded with the operation and shown in the system tip.</summary>
        public string Reason { get; set; }

        /// <inheritdoc cref="ImGroupMembersRequest"/>
        public ImGroupMembersRequest()
        {
            UserIds = new List<string>();
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("groupId", GroupId)
                .Set("userIds", JsonValue.ArrayOf(UserIds))
                .Set("reason", Reason);
        }
    }

    /// <summary>Body of <c>group.memberList</c>.</summary>
    /// <remarks>
    /// Always paged, never "give me everyone": a super group holds a hundred thousand members and
    /// materialising that into one frame is a self-inflicted outage.
    /// </remarks>
    public sealed class ImGroupCursorRequest : IImRequest
    {
        /// <summary>Which group.</summary>
        public string GroupId { get; set; }

        /// <summary>Paging cursor from the previous page.</summary>
        public string Cursor { get; set; }

        /// <summary>Rows per page. Clamped to 1…200; anything else becomes 50.</summary>
        public int Limit { get; set; }

        /// <inheritdoc cref="ImGroupCursorRequest"/>
        public ImGroupCursorRequest()
        {
            Limit = 50;
        }

        /// <inheritdoc cref="ImGroupCursorRequest"/>
        public ImGroupCursorRequest(string groupId)
            : this()
        {
            GroupId = groupId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("groupId", GroupId)
                .Set("cursor", Cursor)
                .Set("limit", (long)Limit);
        }
    }

    /// <summary>Body of <c>group.join</c>.</summary>
    public sealed class ImJoinGroupRequest : IImRequest
    {
        /// <summary>Which group.</summary>
        public string GroupId { get; set; }

        /// <summary>Message shown to the admin when the group needs approval.</summary>
        public string Reason { get; set; }

        /// <inheritdoc cref="ImJoinGroupRequest"/>
        public ImJoinGroupRequest()
        {
        }

        /// <inheritdoc cref="ImJoinGroupRequest"/>
        public ImJoinGroupRequest(string groupId, string reason = null)
        {
            GroupId = groupId;
            Reason = reason;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("groupId", GroupId)
                .Set("reason", Reason);
        }
    }

    // ------------------------------------------------------------------ moderation

    /// <summary>
    /// The categories <c>moderation.report</c> accepts.
    /// </summary>
    /// <remarks>
    /// An unrecognised value is refused rather than quietly filed under <see cref="Other"/>: a
    /// category the moderation queue cannot group by is a report nobody reads. Leaving the member
    /// null is the way to say "I do not know" — the server files that as <see cref="Other"/>
    /// itself.
    /// </remarks>
    public static class ImReportCategory
    {
        /// <summary>Unsolicited advertising, bulk sends, link spam.</summary>
        public const string Spam = "spam";

        /// <summary>Targeted abuse of a person.</summary>
        public const string Harassment = "harassment";

        /// <summary>Scams, impersonation, phishing.</summary>
        public const string Fraud = "fraud";

        /// <summary>Sexual content.</summary>
        public const string Pornography = "pornography";

        /// <summary>Violence, gore, threats of harm.</summary>
        public const string Violence = "violence";

        /// <summary>Everything else, and the default when none is named.</summary>
        public const string Other = "other";
    }

    /// <summary>Body of <c>moderation.report</c>.</summary>
    /// <remarks>
    /// <para>
    /// <b>There is no reporter member and there must not be.</b> The reporter is the connection —
    /// the socket is the only surface on which the user id is a fact rather than a parameter. A
    /// member for it would let one account file in another's name, which is both a way to get a
    /// stranger banned and a way to poison the count a moderator decides on.
    /// 举报人来自连接，请求体里没有这个字段：有了它，一个账号就能以别人的名义举报，
    /// 既能让陌生人被封，也能污染审核员据以决定的那个计数。
    /// </para>
    /// <para>
    /// <see cref="MessageId"/> is optional, and naming none reports the account rather than one
    /// message. The message itself is not checked — a report about one that has
    /// already been deleted is exactly the report a moderator most wants, so do not withhold one
    /// because the message is gone from the local store.
    /// </para>
    /// </remarks>
    public sealed class ImSubmitReportRequest : IImRequest
    {
        /// <summary>Who is being reported. Required, and reporting yourself is refused.</summary>
        public string TargetUserId { get; set; }

        /// <summary>Where it happened, when the report came from a conversation.</summary>
        public string ConversationId { get; set; }

        /// <summary>Which message, or null to report the account rather than one message.</summary>
        public string MessageId { get; set; }

        /// <summary>One of <see cref="ImReportCategory"/>. Null files it as <c>other</c>.</summary>
        public string Category { get; set; }

        /// <summary>What the player typed. Usually the most useful thing in the row.</summary>
        public string Note { get; set; }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("targetUserId", TargetUserId)
                .Set("conversationId", ConversationId)

                // Blank means absent, not "". The server reads this member as a number written as a
                // string, so an empty one fails to parse there and answers 1000 InternalError on a
                // field nobody filled in — and an empty box is how a report screen spells "no
                // particular message".
                // 空串按缺省处理：服务端把它当「写成字符串的数字」解析，"" 在那边解析失败，
                // 会让一个本就没填的可选字段回一个 1000。
                .Set("messageId", string.IsNullOrEmpty(MessageId) ? null : MessageId)
                .Set("category", Category)
                .Set("note", Note);
        }
    }

    /// <summary>Array builders the request bodies share.</summary>
    internal static class ImJsonArrays
    {
        /// <summary>
        /// Builds a JSON array of 64-bit integers. Written out rather than routed through a double,
        /// because a snowflake <c>messageId</c> past 2^53 does not survive the round trip.
        /// </summary>
        /// <summary>
        /// Builds a JSON array of message ids, which travel as strings.
        /// </summary>
        /// <remarks>
        /// The sibling <see cref="OfLongs"/> exists for numeric arrays and its comment explains why
        /// a snowflake cannot ride through a double. Ids now avoid that question entirely by never
        /// being numbers on the wire: the server quotes them, and so does this client.
        /// 消息 id 在线路上是字符串，因此彻底绕开了「雪花能不能塞进 double」这个问题。
        /// </remarks>
        internal static JsonValue OfStrings(IEnumerable<string> values)
        {
            var array = JsonValue.NewArray();
            if (values != null)
            {
                foreach (var value in values)
                {
                    array.Add(JsonValue.Of(value));
                }
            }

            return array;
        }

        internal static JsonValue OfLongs(IEnumerable<long> values)
        {
            var array = JsonValue.NewArray();
            if (values != null)
            {
                foreach (var value in values)
                {
                    array.Add(JsonValue.Of(value));
                }
            }

            return array;
        }
    }
}
