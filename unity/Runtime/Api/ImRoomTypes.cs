using System;
using System.Collections.Generic;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    // ---------------------------------------------------------------------- the rule
    //
    // A room message is best effort and has no seq. It arrives on evt.message as an ordinary
    // ImMessage whose Seq is 0 and whose ConversationId is "r_<roomId>": nothing is stored per user,
    // nothing is pushed offline, and there is no range to repair. ImClient hands it straight to
    // MessageReceived and never lets it near a cursor or the gap-repair path — do not Commit it.
    // 聊天室消息尽力而为、没有 seq：evt.message 上一条 Seq 为 0、ConversationId 为 r_<roomId> 的普通消息。
    // 不按人存储、不发离线推送、没有可补的区间；ImClient 直接交给 MessageReceived，绝不让它碰游标或补洞。不要 Commit 它。

    // ---------------------------------------------------------------------- requests

    /// <summary>
    /// <c>room.join</c>, <c>room.quit</c> and <c>room.onlineCount</c>: the room, and nothing else.
    /// </summary>
    /// <remarks>
    /// <b>Membership belongs to this connection, not to the player.</b> After a reconnect the server
    /// no longer counts this device as present, and nothing is delivered until <c>room.join</c> is
    /// sent again. The SDK does not rejoin for you — which rooms are still on screen is the game's
    /// knowledge, not the socket's.
    /// 成员身份属于这条连接而不是这个玩家：重连之后要重新 room.join，SDK 不替你重进。
    /// </remarks>
    public sealed class ImRoomIdRequest : IImRequest
    {
        /// <summary>Which room. Required.</summary>
        public string RoomId { get; set; }

        /// <inheritdoc cref="ImRoomIdRequest"/>
        public ImRoomIdRequest()
        {
        }

        /// <inheritdoc cref="ImRoomIdRequest"/>
        public ImRoomIdRequest(string roomId)
        {
            RoomId = roomId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject().Set("roomId", RoomId);
        }
    }

    /// <summary>
    /// <c>room.memberList</c>. <b>A sample of who is present, not the full list</b> — the server never
    /// enumerates a large room exactly. Page on <see cref="ImPage{T}.HasMore"/> and
    /// <see cref="ImPage{T}.NextCursor"/> like every other list.
    /// </summary>
    public sealed class ImRoomCursorRequest : IImRequest
    {
        /// <summary>Which room. Required.</summary>
        public string RoomId { get; set; }

        /// <summary>Opaque; pass back <see cref="ImPage{T}.NextCursor"/> verbatim. Null for the first page.</summary>
        public string Cursor { get; set; }

        /// <summary>Rows per page. The server honours 1–100; anything else becomes 50.</summary>
        public int Limit { get; set; }

        /// <inheritdoc cref="ImRoomCursorRequest"/>
        public ImRoomCursorRequest()
        {
            Limit = 50;
        }

        /// <inheritdoc cref="ImRoomCursorRequest"/>
        public ImRoomCursorRequest(string roomId)
            : this()
        {
            RoomId = roomId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("roomId", RoomId)
                .Set("cursor", Cursor)
                .Set("limit", (long)Limit);
        }
    }

    /// <summary>
    /// The message half of a <c>room.send</c> — the members of the server's <c>SendMessageRequest</c>
    /// a room reads, and no others.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Not <see cref="ImSendRequest"/>: a room message has no recipient (the room is
    /// <see cref="ImRoomSendRequest.RoomId"/>) and nothing to quote or thread under, and a member the
    /// server ignores is a member someone will set and then wonder about.
    /// </para>
    /// <para>
    /// <b>The keys inside <c>message</c> are matched case-sensitively</b> by the socket binder, and a
    /// miscased one is dropped without an error — so this type writes them, and they are not something
    /// to hand-roll through <c>InvokeAsync</c>. <see cref="ClientMsgId"/> is required by the server
    /// (<c>1001</c> without it); leave it null and <see cref="ImRoomApi.SendAsync"/> generates one, as
    /// <c>msg.send</c> does.
    /// 只含聊天室真正读取的字段。message 里的键按大小写精确匹配、写错的会被静默丢掉；ClientMsgId 留空由 SDK 生成。
    /// </para>
    /// </remarks>
    public sealed class ImRoomMessage
    {
        /// <summary>Payload kind, sent as its integer. Defaults to <see cref="ImMessageContentType.Text"/>.</summary>
        public ImMessageContentType ContentType { get; set; }

        /// <summary>Structured payload, shaped by <see cref="ContentType"/>. Null sends an empty object.</summary>
        public JsonValue Content { get; set; }

        /// <summary>The idempotency key. Null is filled in by <see cref="ImRoomApi.SendAsync"/>.</summary>
        public string ClientMsgId { get; set; }

        /// <summary>Mention everyone in the room. Sent only when true.</summary>
        public bool MentionAll { get; set; }

        /// <summary>Users to mention.</summary>
        public IEnumerable<string> MentionedUserIds { get; set; }

        /// <summary>
        /// The server's <c>MessageOptions</c>, passed through verbatim. On this path only
        /// <c>priority</c> is read: a room over its rate sheds <c>Low</c> first. A room message is never
        /// stored or pushed offline, whatever else is set here.
        /// </summary>
        public JsonValue Options { get; set; }

        /// <summary>Client clock, unix ms. Null is stamped by <see cref="ImRoomApi.SendAsync"/>; the server keeps its own <c>createTime</c>.</summary>
        public long? SendTime { get; set; }

        /// <summary>Tenant-defined extras carried with the message.</summary>
        public JsonValue Extensions { get; set; }

        /// <inheritdoc cref="ImRoomMessage"/>
        public ImRoomMessage()
        {
            ContentType = ImMessageContentType.Text;
        }

        /// <summary>A plain text message.</summary>
        public static ImRoomMessage Text(string text)
        {
            return new ImRoomMessage { Content = JsonValue.NewObject().Set("text", text) };
        }

        internal JsonValue ToJson(string clientMsgId, long? sendTime)
        {
            var body = JsonValue.NewObject()
                .Set("contentType", (long)ContentType)
                .Set("content", Content ?? JsonValue.NewObject())
                .Set("clientMsgId", clientMsgId)
                .Set("sendTime", sendTime);

            if (MentionAll)
            {
                body.Set("mentionAll", true);
            }

            if (MentionedUserIds != null)
            {
                body.Set("mentionedUserIds", ImJsonArrays.OfStrings(MentionedUserIds));
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

    /// <summary>
    /// <c>room.send</c>. The caller must have joined the room on this connection
    /// (<c>1602 NotInRoom</c> otherwise, and after a kick).
    /// </summary>
    /// <remarks>
    /// <see cref="ToJson"/> writes what is set; <see cref="ImRoomApi.SendAsync"/> fills in a missing
    /// <see cref="ImRoomMessage.ClientMsgId"/> and <see cref="ImRoomMessage.SendTime"/> first.
    /// </remarks>
    public sealed class ImRoomSendRequest : IImRequest
    {
        /// <summary>Which room. Required.</summary>
        public string RoomId { get; set; }

        /// <summary>What to say. Required.</summary>
        public ImRoomMessage Message { get; set; }

        /// <inheritdoc cref="ImRoomSendRequest"/>
        public ImRoomSendRequest()
        {
        }

        /// <inheritdoc cref="ImRoomSendRequest"/>
        public ImRoomSendRequest(string roomId, ImRoomMessage message)
        {
            RoomId = roomId;
            Message = message;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return ToJson(
                Message != null ? Message.ClientMsgId : null,
                Message != null ? Message.SendTime : null);
        }

        internal JsonValue ToJson(string clientMsgId, long? sendTime)
        {
            var body = JsonValue.NewObject().Set("roomId", RoomId);
            if (Message != null)
            {
                body.Set("message", Message.ToJson(clientMsgId, sendTime));
            }

            return body;
        }
    }

    /// <summary>
    /// <c>room.mute</c>. Room owner or room admins only (<c>1103</c> otherwise), and never the owner
    /// (<c>1511</c>).
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Both optional members mean something when absent, and the absence is the dangerous half</b>,
    /// so all three are constructor arguments and there is no parameterless form:
    /// </para>
    /// <list type="bullet">
    /// <item><see cref="UserId"/> null mutes <b>the whole room</b> (the owner and admins can still
    /// speak); a user id mutes that member alone.</item>
    /// <item><see cref="UntilMs"/> null, or a time already past, <b>lifts</b> the mute. A mute is always
    /// "until when".</item>
    /// </list>
    /// <para>
    /// Written as <c>new ImRoomMuteRequest { RoomId = "lobby", UserId = "bob" }</c>, a "mute Bob" would
    /// unmute him, with no error anywhere. <see cref="Unmute"/> says the other half out loud.
    /// 两个可选成员缺省时都有含义，而且缺省那一半是危险的，所以三个都是构造参数、没有无参构造：
    /// UserId 为 null 是全员禁言；UntilMs 为 null 或已过去是解除禁言。
    /// </para>
    /// </remarks>
    public sealed class ImRoomMuteRequest : IImRequest
    {
        /// <inheritdoc cref="ImRoomMuteRequest"/>
        /// <param name="roomId">Which room.</param>
        /// <param name="userId">The member to mute, or null for the whole room.</param>
        /// <param name="untilMs">Unix ms the mute ends. Null, or a past time, lifts it.</param>
        public ImRoomMuteRequest(string roomId, string userId, long? untilMs)
        {
            RoomId = roomId;
            UserId = userId;
            UntilMs = untilMs;
        }

        /// <summary>Which room. Required.</summary>
        public string RoomId { get; set; }

        /// <summary>The member to mute, or null for the whole room.</summary>
        public string UserId { get; set; }

        /// <summary>Unix ms the mute ends. Null, or a past time, lifts it.</summary>
        public long? UntilMs { get; set; }

        /// <summary>Lifts a mute: one member's, or with <paramref name="userId"/> null, the whole room's.</summary>
        public static ImRoomMuteRequest Unmute(string roomId, string userId = null)
        {
            return new ImRoomMuteRequest(roomId, userId, null);
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("roomId", RoomId)
                .Set("userId", UserId)
                .Set("untilMs", UntilMs);
        }
    }

    /// <summary>
    /// <c>room.kick</c>. Room owner or room admins only (<c>1103</c> otherwise), and never the owner
    /// (<c>1511</c>). The member's sends answer <c>1602 NotInRoom</c> afterwards; the room hears
    /// <c>room.kicked</c>.
    /// </summary>
    public sealed class ImRoomKickRequest : IImRequest
    {
        /// <summary>Which room. Required.</summary>
        public string RoomId { get; set; }

        /// <summary>The member to remove. Required.</summary>
        public string UserId { get; set; }

        /// <inheritdoc cref="ImRoomKickRequest"/>
        public ImRoomKickRequest()
        {
        }

        /// <inheritdoc cref="ImRoomKickRequest"/>
        public ImRoomKickRequest(string roomId, string userId)
        {
            RoomId = roomId;
            UserId = userId;
        }

        /// <inheritdoc/>
        public JsonValue ToJson()
        {
            return JsonValue.NewObject()
                .Set("roomId", RoomId)
                .Set("userId", UserId);
        }
    }

    // ---------------------------------------------------------------------- payloads

    /// <summary>
    /// A chat room as the tenant's backend created it (<c>POST /v1/rooms</c> — there is no socket call
    /// that creates one). Read-only from a device: neither the name nor the admins change over the socket.
    /// </summary>
    public sealed class ImChatRoom : IImJsonPayload
    {
        /// <summary>The tenant.</summary>
        public string AppId { get; internal set; }

        /// <summary>The room id.</summary>
        public string RoomId { get; internal set; }

        /// <summary>Display name.</summary>
        public string Name { get; internal set; }

        /// <summary>Avatar object key or URL, or null.</summary>
        public string Avatar { get; internal set; }

        /// <summary>Can mute and kick, and can never be muted or kicked.</summary>
        public string OwnerId { get; internal set; }

        /// <summary>Can mute and kick, as the owner can. Never null.</summary>
        public List<string> Admins { get; internal set; }

        /// <summary>Connections allowed at once; 0 means unlimited. A full room answers <c>room.join</c> with <c>1601</c>.</summary>
        public long MaxOnline { get; internal set; }

        /// <summary>How many recent messages a joiner receives in <see cref="ImRoomJoinResult.Recent"/>; 0 disables it.</summary>
        public int HistoryBufferSize { get; internal set; }

        /// <summary>Messages per second the room accepts as a whole before shedding low-priority ones (<c>1003</c>).</summary>
        public int RateLimitPerSecond { get; internal set; }

        /// <summary>A room-wide mute is in force: only the owner and admins can send (<c>1603</c> for everyone else).</summary>
        public bool MuteAll { get; internal set; }

        /// <summary>
        /// The tenant's backend destroyed it. Only <c>room.join</c>, <c>room.send</c>, <c>room.mute</c>
        /// and <c>room.kick</c> answer <c>1600</c> for it: <c>room.onlineCount</c> answers 0,
        /// <c>room.memberList</c> an empty sample and <c>room.quit</c> succeeds, so polling the count
        /// never notices — watch <see cref="ImRoomEvent.Destroyed"/> instead.
        /// </summary>
        public bool Destroyed { get; internal set; }

        /// <summary>Unix ms.</summary>
        public long CreatedAt { get; internal set; }

        /// <summary>Tenant-defined extras, or null when there are none.</summary>
        public JsonValue Extensions { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            AppId = json["appId"].AsString(string.Empty);
            RoomId = json["roomId"].AsString(string.Empty);
            Name = json["name"].AsString(string.Empty);
            Avatar = json["avatar"].AsString();
            OwnerId = json["ownerId"].AsString(string.Empty);
            Admins = json["admins"].AsStringList();
            MaxOnline = json["maxOnline"].AsLong();
            HistoryBufferSize = json["historyBufferSize"].AsInt();
            RateLimitPerSecond = json["rateLimitPerSecond"].AsInt();
            MuteAll = json["muteAll"].AsBool();
            Destroyed = json["destroyed"].AsBool();
            CreatedAt = json["createdAt"].AsLong();
            Extensions = json["extensions"].IsObject ? json["extensions"] : null;
        }
    }

    /// <summary>What <c>room.join</c> answers.</summary>
    public sealed class ImRoomJoinResult : IImJsonPayload
    {
        /// <summary>The room joined.</summary>
        public ImChatRoom Room { get; internal set; }

        /// <summary>Connections present right after this one joined, cluster-wide.</summary>
        public long OnlineCount { get; internal set; }

        /// <summary>
        /// The room's last few messages, oldest first, so a newcomer does not stare at an empty screen.
        /// Each has <c>Seq</c> 0. Never null.
        /// </summary>
        /// <remarks>
        /// <b>Returned here only</b>: they are not replayed on <see cref="ImClient.MessageReceived"/> and
        /// touch no cursor — render them, and do not commit them.
        /// 只在这里返回：不会在 MessageReceived 上重放，也不碰游标。
        /// </remarks>
        public List<ImMessage> Recent { get; internal set; }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            Room = ImPayload.Read<ImChatRoom>(json["room"]);
            OnlineCount = json["onlineCount"].AsLong();
            Recent = ImPayload.ReadList<ImMessage>(json["recent"]);
        }
    }

    /// <summary>One <c>room.*</c> event, as <see cref="ImClient.OnRoomEvent"/> delivers it.</summary>
    /// <remarks>
    /// <para>
    /// The server sends these inside <c>evt.system</c> as <c>{"event": "room.muted", "body": {…}}</c>,
    /// beside events that have nothing to do with rooms — the device-log request among them, which
    /// keeps its own handler. Only the <c>room.*</c> ones come out here. A <c>room.*</c> name this
    /// build does not know is still delivered, with whatever <see cref="RoomId"/> and
    /// <see cref="OperatorId"/> it carried and the whole <see cref="Body"/>: a newer server must not
    /// be able to hide a room event from an older game.
    /// </para>
    /// <list type="bullet">
    /// <item><see cref="Muted"/> — <see cref="UserId"/> null is the whole room; <see cref="UntilMs"/>
    /// null or already past means the mute was <b>lifted</b>, not set (<see cref="IsMuteInForceAt"/>).</item>
    /// <item><see cref="Kicked"/> — <see cref="UserId"/> is who was removed. If it is you, stop sending:
    /// the server answers <c>1602</c>.</item>
    /// <item><see cref="Destroyed"/> — the tenant's backend deleted the room. Join, send, mute and kick
    /// answer <c>1600</c> from now on.</item>
    /// </list>
    /// <para>
    /// evt.system 里同时走着与聊天室无关的事件（设备日志请求就是其一，它有自己的处理器），这里只交出 room.* 的；
    /// 不认识的 room.* 名字照样交出、带上原始 Body——新服务端不能把聊天室事件藏起来不让旧游戏看到。
    /// </para>
    /// </remarks>
    public sealed class ImRoomEvent : IImJsonPayload
    {
        /// <summary>A mute was set or lifted.</summary>
        public const string Muted = "room.muted";

        /// <summary>A member was removed.</summary>
        public const string Kicked = "room.kicked";

        /// <summary>The room is gone.</summary>
        public const string Destroyed = "room.destroyed";

        /// <summary>The prefix that makes an <c>evt.system</c> event a room's.</summary>
        public const string Prefix = "room.";

        /// <summary><see cref="Muted"/>, <see cref="Kicked"/>, <see cref="Destroyed"/>, or a <c>room.*</c> name a newer server added.</summary>
        public string Event { get; internal set; }

        /// <summary>The room it happened in.</summary>
        public string RoomId { get; internal set; }

        /// <summary>Who did it: the owner, an admin, or the tenant backend's operator id.</summary>
        public string OperatorId { get; internal set; }

        /// <summary><see cref="Muted"/>: the member muted, null for the whole room. <see cref="Kicked"/>: the member removed.</summary>
        public string UserId { get; internal set; }

        /// <summary><see cref="Muted"/>: unix ms the mute ends; null, or a past time, means it was lifted.</summary>
        public long? UntilMs { get; internal set; }

        /// <summary>The event's whole <c>body</c>, for a field this build does not name. Never null.</summary>
        public JsonValue Body { get; internal set; }

        /// <summary>True on a <see cref="Muted"/> that names no member: the whole room.</summary>
        public bool IsWholeRoom
        {
            get { return Event == Muted && string.IsNullOrEmpty(UserId); }
        }

        /// <summary>
        /// True when this is a <see cref="Muted"/> whose mute is still in force at
        /// <paramref name="unixMs"/>. False for a lift — an absent or past <see cref="UntilMs"/> — and
        /// for every other event.
        /// </summary>
        public bool IsMuteInForceAt(long unixMs)
        {
            return Event == Muted && UntilMs.HasValue && UntilMs.Value > unixMs;
        }

        /// <summary>
        /// The <c>data</c> of an <c>evt.system</c> frame as a room event, or null when it is not one.
        /// Never throws: a frame of another shape belongs to another reader of <c>evt.system</c>.
        /// </summary>
        internal static ImRoomEvent FromSystemData(JsonValue data)
        {
            if (data == null || !data.IsObject)
            {
                return null;
            }

            var name = data["event"].AsString(string.Empty);
            if (!name.StartsWith(Prefix, StringComparison.Ordinal))
            {
                return null;
            }

            return ImPayload.Read<ImRoomEvent>(data);
        }

        /// <inheritdoc/>
        public void ReadFrom(JsonValue json)
        {
            Event = json["event"].AsString(string.Empty);

            var body = json["body"];
            Body = body.IsObject ? body : JsonValue.NewObject();
            RoomId = Body["roomId"].AsString(string.Empty);
            OperatorId = Body["operatorId"].AsString(string.Empty);
            UserId = Body["userId"].AsString();
            UntilMs = ImPayload.OptionalLong(Body, "untilMs");
        }
    }
}
