using System;
using System.Collections.Generic;
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

        /// <summary>
        /// Marks a conversation unread by hand, or clears that mark — the "mark as unread" swipe.
        /// </summary>
        /// <remarks>
        /// <para>
        /// It does not move the read cursor, so the other side's receipts are unaffected. It shows up
        /// as <see cref="ImConversationView.ManuallyUnread"/>, and the server reports an
        /// <see cref="ImConversationView.UnreadCount"/> of 1 where it would otherwise be 0.
        /// <see cref="ReadAsync(ImReadRequest,CancellationToken)"/>, <c>conv.delete</c> and
        /// <c>conv.clear</c> all clear the mark.
        /// </para>
        /// <para>
        /// Setting the value it already has succeeds and sends nothing; a change reaches this user's
        /// other devices as <c>evt.conversationUpdate</c> with kind <c>"unread"</c>. Access errors:
        /// <see cref="ImErrorCode.Forbidden"/>, and <see cref="ImErrorCode.NotGroupMember"/> in a
        /// group.
        /// </para>
        /// </remarks>
        public Task MarkUnreadAsync(
            ImMarkUnreadRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return ExecuteAsync("conv.markUnread", request, cancellationToken);
        }

        // ------------------------------------------------------------------------- T4: folders
        //
        // A folder holds tags, not conversations: filter conv.list with them. See ImFolderTypes.cs.
        // 文件夹装的是标签，不是会话：用它们过滤 conv.list。

        /// <summary>This user's folders — a plain list, not a page (at most 20).</summary>
        /// <remarks>
        /// Folder changes are not pushed, so this is how another device sees them. An empty list is no
        /// folders, not an error.
        /// 文件夹的变化没有推送，其他设备靠这个调用看到。
        /// </remarks>
        public Task<List<ImConversationFolder>> FoldersAsync(CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestListAsync<ImConversationFolder>("conv.folders", null, cancellationToken);
        }

        /// <summary>
        /// Creates a folder (no <see cref="ImUpsertFolderRequest.FolderId"/>) or replaces one, and returns it
        /// as saved.
        /// </summary>
        /// <remarks>
        /// A replace, not a patch: every member is written. Each tag must already be on one of this user's
        /// conversations (<see cref="SettingAsync"/> with <see cref="ImConversationSetting.Tags"/>), else
        /// <c>1001</c>; at most 16 tags, and 20 folders (<c>1006</c>). Creating without an id is not
        /// idempotent — choose the id to make a retry safe.
        /// 整份替换。每个标签都必须已在本人的某个会话上（先 SettingAsync 打标签），否则 1001。不带 id 新建不幂等。
        /// </remarks>
        public Task<ImConversationFolder> UpsertFolderAsync(
            ImUpsertFolderRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);

            // Blank, not only empty: the server refuses a whitespace name with 1001 as well.
            // 空白名字服务端同样回 1001。
            if (string.IsNullOrWhiteSpace(request.Name))
            {
                throw new ArgumentException("name is required and must not be blank", "name");
            }

            return RequestAsync<ImConversationFolder>("conv.upsertFolder", request, cancellationToken);
        }

        /// <summary>
        /// Deletes a folder and nothing else: the conversations keep their tags and stay in the list.
        /// <c>1002</c> for an unknown folder.
        /// </summary>
        public Task DeleteFolderAsync(
            ImFolderIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.FolderId, "folderId");
            return ExecuteAsync("conv.deleteFolder", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="DeleteFolderAsync(ImFolderIdRequest, CancellationToken)"/>.</summary>
        public Task DeleteFolderAsync(
            string folderId,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return DeleteFolderAsync(new ImFolderIdRequest(folderId), cancellationToken);
        }
    }
}
