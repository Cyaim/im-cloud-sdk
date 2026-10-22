using System;
using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>room.*</c> — chat rooms: the live-stream comment wall, the broadcast lobby, the world
    /// channel (T4).
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>A room trades every delivery guarantee for scale, and the game has to know it.</b> Its
    /// messages are not stored per player, not pushed offline, and carry <c>Seq</c> <b>0</b>: they
    /// arrive on <see cref="ImClient.MessageReceived"/> as ordinary <see cref="ImMessage"/>s whose
    /// <c>ConversationId</c> is <c>r_&lt;roomId&gt;</c>, and <see cref="ImClient"/> keeps them out of
    /// the cursors and the gap repair entirely — a dropped frame is gone, and there is no range to
    /// ask for. Do not <see cref="ImClient.Commit"/> them; it ignores a seq of 0 for that reason.
    /// </para>
    /// <para>
    /// <b>Rooms are created by the tenant's backend</b> (<c>POST /v1/rooms</c>), never from a device.
    /// <b>Joining belongs to the connection</b>: after a reconnect, call <see cref="JoinAsync(ImRoomIdRequest, CancellationToken)"/>
    /// again for every room still on screen — the SDK does not do it for you. Mutes, kicks and the
    /// room's destruction arrive on <see cref="ImClient.OnRoomEvent"/>.
    /// </para>
    /// <para>
    /// A deployment older than this build answers <c>1008 UnsupportedOperation</c>; neither retrying
    /// nor re-authenticating changes it.
    /// 聊天室用全部投递保证换规模：消息不按人存储、不发离线推送、Seq 为 0，ImClient 让它们完全绕开游标与补洞。
    /// 聊天室由租户后端创建；入房属于连接，重连后要重新 Join，SDK 不代劳。
    /// </para>
    /// </remarks>
    public sealed class ImRoomApi : ImApiNamespace
    {
        internal ImRoomApi(ImClient client)
            : base(client)
        {
        }

        /// <summary>
        /// Enters a room on this connection and returns it, the head count, and its last few messages.
        /// </summary>
        /// <remarks>
        /// <c>1600 RoomNotFound</c> for a room that does not exist or was destroyed;
        /// <c>1601 RoomFull</c> when <see cref="ImChatRoom.MaxOnline"/> connections are already in.
        /// The messages in <see cref="ImRoomJoinResult.Recent"/> are returned here only.
        /// </remarks>
        public Task<ImRoomJoinResult> JoinAsync(
            ImRoomIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.RoomId, "roomId");
            return RequestAsync<ImRoomJoinResult>("room.join", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="JoinAsync(ImRoomIdRequest, CancellationToken)"/>.</summary>
        public Task<ImRoomJoinResult> JoinAsync(
            string roomId,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return JoinAsync(new ImRoomIdRequest(roomId), cancellationToken);
        }

        /// <summary>Leaves a room on this connection. Leaving one you are not in succeeds.</summary>
        public Task QuitAsync(
            ImRoomIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.RoomId, "roomId");
            return ExecuteAsync("room.quit", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="QuitAsync(ImRoomIdRequest, CancellationToken)"/>.</summary>
        public Task QuitAsync(
            string roomId,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return QuitAsync(new ImRoomIdRequest(roomId), cancellationToken);
        }

        /// <summary>
        /// Says something to the room. The result's <c>Seq</c> is <b>always 0</b> and its
        /// <c>ConversationId</c> is <c>r_&lt;roomId&gt;</c>.
        /// </summary>
        /// <remarks>
        /// <para>
        /// It moves no cursor, which is why this does not go through <c>msg.send</c>: the send there
        /// reconciles the conversation's cursor with the seq it gets back, and a room has none.
        /// A null <see cref="ImRoomMessage.ClientMsgId"/> is generated and a null
        /// <see cref="ImRoomMessage.SendTime"/> stamped, as <c>msg.send</c> does — the caller's
        /// request object is not modified.
        /// </para>
        /// <para>
        /// Refusals: <c>1602 NotInRoom</c> (not joined on this connection, or kicked),
        /// <c>1603 RoomMuted</c> (the whole room is muted and you are neither owner nor admin),
        /// <c>1506 MemberMuted</c>, <c>1401 MessageTooLong</c>, <c>1402 ModerationRejected</c>,
        /// <c>1003 RateLimited</c> (the room is over its rate), <c>1600 RoomNotFound</c>.
        /// 结果的 Seq 恒为 0，不动游标，所以不走 msg.send。
        /// </para>
        /// </remarks>
        public async Task<ImSendResult> SendAsync(
            ImRoomSendRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.RoomId, "roomId");
            if (request.Message == null)
            {
                throw new ArgumentException("message is required", "request");
            }

            var message = request.Message;
            var clientMsgId = !string.IsNullOrEmpty(message.ClientMsgId)
                ? message.ClientMsgId
                : Client.NewClientMsgId();
            var sendTime = message.SendTime.HasValue
                ? message.SendTime.Value
                : DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

            var data = await Client
                .SendRequestAsync("room.send", request.ToJson(clientMsgId, sendTime), cancellationToken)
                .ConfigureAwait(false);
            return ImSendResult.FromJson(data);
        }

        /// <summary>Connections in the room right now, cluster-wide. A bare number.</summary>
        /// <remarks>
        /// <b>An unknown or destroyed room answers 0</b>, not <c>1600</c>: this is polled for a viewer
        /// counter and the server skips the existence check.
        /// 不存在或已销毁的房间回 0，不回 1600。
        /// </remarks>
        public async Task<long> OnlineCountAsync(
            ImRoomIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.RoomId, "roomId");
            var data = await RequestAsync("room.onlineCount", request, cancellationToken).ConfigureAwait(false);
            return data.AsLong();
        }

        /// <summary>Shorthand for <see cref="OnlineCountAsync(ImRoomIdRequest, CancellationToken)"/>.</summary>
        public Task<long> OnlineCountAsync(
            string roomId,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return OnlineCountAsync(new ImRoomIdRequest(roomId), cancellationToken);
        }

        /// <summary>
        /// <b>A sample</b> of the user ids present, not the full list: the server never enumerates a
        /// large room exactly.
        /// </summary>
        /// <remarks>
        /// Page on <see cref="ImPage{T}.HasMore"/> and <see cref="ImPage{T}.NextCursor"/>; a page can be
        /// short, or empty, with more to come. An unknown or destroyed room is an empty sample, not
        /// <c>1600</c>.
        /// 返回的是抽样，不是全量名单；只按 HasMore / NextCursor 翻页。不存在的房间回空抽样，不回 1600。
        /// </remarks>
        public async Task<ImPage<string>> MemberListAsync(
            ImRoomCursorRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.RoomId, "roomId");
            var data = await RequestAsync("room.memberList", request, cancellationToken).ConfigureAwait(false);
            return ImPage<string>.FromJson(data, item => item.AsString(string.Empty));
        }

        /// <summary>
        /// Mutes the room or one member until a time — or, with <see cref="ImRoomMuteRequest.UntilMs"/>
        /// null or past, lifts the mute. Owner or admins only (<c>1103</c>); never the owner (<c>1511</c>).
        /// </summary>
        public Task MuteAsync(
            ImRoomMuteRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.RoomId, "roomId");
            return ExecuteAsync("room.mute", request, cancellationToken);
        }

        /// <summary>
        /// Removes a member from the room. Owner or admins only (<c>1103</c>); never the owner
        /// (<c>1511</c>).
        /// </summary>
        public Task KickAsync(
            ImRoomKickRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.RoomId, "roomId");
            Require(request.UserId, "userId");
            return ExecuteAsync("room.kick", request, cancellationToken);
        }
    }
}
