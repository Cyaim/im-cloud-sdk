using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>friend.*</c> — the contact list, friend requests, and the blocklist.
    /// </summary>
    /// <remarks>
    /// Blocking is not an optional row on a feature matrix: app-store review treats it as mandatory
    /// for any app carrying user-generated content, which every chat is.
    /// </remarks>
    public sealed class ImFriendApi : ImApiNamespace
    {
        internal ImFriendApi(ImClient client)
            : base(client)
        {
        }

        /// <summary>The caller's friends, paged.</summary>
        public Task<ImPage<ImFriend>> ListAsync(
            ImCursorRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestPageAsync<ImFriend>(
                "friend.list",
                request != null ? request : new ImCursorRequest(),
                cancellationToken);
        }

        /// <summary>
        /// Sends a friend request. Whether the other side has to accept it is a tenant setting; a
        /// request to yourself is refused.
        /// </summary>
        public Task AddAsync(
            ImAddFriendRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.UserId, "userId");
            return ExecuteAsync("friend.add", request, cancellationToken);
        }

        /// <summary>Accepts or refuses a request someone sent to the caller.</summary>
        public Task HandleRequestAsync(
            ImHandleFriendRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.FromUserId, "fromUserId");
            return ExecuteAsync("friend.handleRequest", request, cancellationToken);
        }

        /// <summary>Pending friend requests, incoming by default.</summary>
        public Task<ImPage<ImFriendRequest>> RequestListAsync(
            ImFriendRequestListRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestPageAsync<ImFriendRequest>(
                "friend.requestList",
                request != null ? request : new ImFriendRequestListRequest(),
                cancellationToken);
        }

        /// <summary>Removes a friend. Symmetric: both sides lose the relationship.</summary>
        public Task DeleteAsync(
            ImUserIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.UserId, "userId");
            return ExecuteAsync("friend.delete", request, cancellationToken);
        }

        /// <summary>The caller's blocklist, paged.</summary>
        public Task<ImPage<ImBlockEntry>> BlockListAsync(
            ImCursorRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestPageAsync<ImBlockEntry>(
                "friend.blockList",
                request != null ? request : new ImCursorRequest(),
                cancellationToken);
        }

        /// <summary>
        /// Blocks a user. Their sends to the caller then fail with
        /// <see cref="ImErrorCode.BlockedByPeer"/> at the server, so nothing reaches this client to
        /// be filtered.
        /// </summary>
        public Task BlockAsync(
            ImBlockRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.UserId, "userId");
            return ExecuteAsync("friend.block", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="BlockAsync(ImBlockRequest,CancellationToken)"/>.</summary>
        public Task BlockAsync(
            string userId,
            string reason = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return BlockAsync(new ImBlockRequest(userId, reason), cancellationToken);
        }

        /// <summary>Lifts a block.</summary>
        public Task UnblockAsync(
            ImUserIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.UserId, "userId");
            return ExecuteAsync("friend.unblock", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="UnblockAsync(ImUserIdRequest,CancellationToken)"/>.</summary>
        public Task UnblockAsync(
            string userId,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return UnblockAsync(new ImUserIdRequest(userId), cancellationToken);
        }

        /// <summary>Sets the caller's private remark and tags for one contact.</summary>
        /// <remarks>
        /// <para>
        /// <b>Leaving <see cref="ImSetRemarkRequest.Remark"/> null clears the remark</b>, while
        /// leaving <see cref="ImSetRemarkRequest.Tags"/> null keeps the tags — so to change only the
        /// tags, send the current remark back with them. An empty tag list clears the tags.
        /// </para>
        /// <para>
        /// Refused with <see cref="ImErrorCode.InvalidArgument"/> for a remark over 64 characters
        /// (refused, not truncated), more than 20 tags, or a tag that is blank or over 32
        /// characters; with <see cref="ImErrorCode.NotFriend"/> when the user is not a contact. The
        /// change reaches only the caller's own devices, as <see cref="ImPushTarget.Friend"/> with
        /// action <c>"updated"</c>.
        /// </para>
        /// </remarks>
        public Task SetRemarkAsync(
            ImSetRemarkRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.UserId, "userId");
            return ExecuteAsync("friend.setRemark", request, cancellationToken);
        }
    }
}
