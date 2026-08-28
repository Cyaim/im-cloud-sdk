using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>conv.*</c> — the list a player opens the app to, and the per-user state on it.
    /// </summary>
    public sealed class ImConvApi : ImApiNamespace
    {
        internal ImConvApi(ImClient client)
            : base(client)
        {
        }

        /// <summary>
        /// The conversation list, incrementally.
        /// </summary>
        /// <remarks>
        /// Pass the largest <see cref="ImConversationView.UpdatedAt"/> you already hold as
        /// <see cref="ImListConversationsRequest.UpdatedAfter"/>: this list is designed to be synced,
        /// not re-fetched, and getting it wrong is the difference between a one-second cold start
        /// and a thirty-second one for a heavy user.
        /// </remarks>
        public Task<ImPage<ImConversationView>> ListAsync(
            ImListConversationsRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestPageAsync<ImConversationView>(
                "conv.list",
                request != null ? request : new ImListConversationsRequest(),
                cancellationToken);
        }

        /// <summary>One conversation's row, including this user's unread count and read cursor.</summary>
        public Task<ImConversationView> GetAsync(
            ImConversationIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return RequestAsync<ImConversationView>("conv.get", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="GetAsync(ImConversationIdRequest,CancellationToken)"/>.</summary>
        public Task<ImConversationView> GetAsync(
            string conversationId,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return GetAsync(new ImConversationIdRequest(conversationId), cancellationToken);
        }

        /// <summary>
        /// Moves the read cursor. Unread counts everywhere — this device, the player's phone, the
        /// app badge — are derived from it server-side, so there is no counter to drift.
        /// </summary>
        public Task ReadAsync(
            ImReadRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return ExecuteAsync("conv.read", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="ReadAsync(ImReadRequest,CancellationToken)"/>.</summary>
        public Task ReadAsync(
            string conversationId,
            long readSeq,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return ReadAsync(new ImReadRequest(conversationId, readSeq), cancellationToken);
        }

        /// <summary>Badge count across every conversation.</summary>
        public async Task<long> UnreadTotalAsync(CancellationToken cancellationToken = default(CancellationToken))
        {
            var data = await Client.SendRequestAsync("conv.unreadTotal", null, cancellationToken)
                .ConfigureAwait(false);

            // A bare number today; an object with a total in it would be a compatible way for the
            // server to add detail later, so read both rather than reporting a zero badge.
            return data.IsObject ? data["total"].AsLong() : data.AsLong();
        }

        /// <summary>Pins, mutes, drafts and tags — the per-user state on one conversation.</summary>
        public Task SettingAsync(
            ImUpdateConversationSettingRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return ExecuteAsync("conv.setting", request, cancellationToken);
        }

        /// <summary>
        /// Removes the conversation from this user's list. The messages themselves are untouched,
        /// and a new message brings the row back.
        /// </summary>
        public Task DeleteAsync(
            ImConversationIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return ExecuteAsync("conv.delete", request, cancellationToken);
        }

        /// <summary>
        /// Clears this user's view of the history. A client may only clear its own copy; clearing
        /// for everyone destroys other people's data and is a tenant-backend operation.
        /// </summary>
        /// <remarks>
        /// This does not move the SDK's cursors, and it should not: the conversation continues from
        /// where it was, and re-adopting its position here would silently skip anything that arrived
        /// between the clear and the next connect.
        /// </remarks>
        public Task ClearAsync(
            ImConversationIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return ExecuteAsync("conv.clear", request, cancellationToken);
        }
    }
}
