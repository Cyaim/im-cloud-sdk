using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im.Json;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>msg.*</c> — sending, backfilling and operating on messages.
    /// </summary>
    public sealed class ImMsgApi : ImApiNamespace
    {
        internal ImMsgApi(ImClient client)
            : base(client)
        {
        }

        /// <summary>
        /// Sends a message and returns the server's authoritative result: its <c>seq</c>, its
        /// <c>messageId</c>, and whether the server recognised it as a duplicate of an earlier
        /// attempt.
        /// </summary>
        /// <remarks>
        /// Holding a <c>seq</c> means the message is persisted. A retry of a send that timed out is
        /// safe: <see cref="ImSendRequest.ClientMsgId"/> is filled in here when the caller leaves it
        /// null, and the server returns the first result with
        /// <see cref="ImSendResult.Deduplicated"/> set rather than posting twice.
        /// </remarks>
        public Task<ImSendResult> SendAsync(
            ImSendRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return Client.SendMessageAsync(request, cancellationToken);
        }

        /// <summary>
        /// Reads a contiguous <c>seq</c> window. The gap-repair primitive, and a public method
        /// because a tenant with its own message store syncs through it directly.
        /// </summary>
        /// <remarks>
        /// <para>
        /// <b>This call moves no cursor and delivers nothing through
        /// <see cref="ImClient.MessageReceived"/>.</b> The SDK's own repair loop is what feeds the
        /// delivery path; this returns the raw window to the caller.
        /// </para>
        /// <para>
        /// It is also not one-shot. The server clamps <see cref="ImSyncMessagesRequest.Limit"/> to
        /// 500 and reports <see cref="ImSyncResult.HasMore"/>; a 900-seq range asked for in one call
        /// silently returns 500. Worse, <c>hasMore</c> is computed on the raw window <i>before</i>
        /// messages hidden from this user are filtered out, so
        /// <see cref="ImSyncResult.Messages"/> can be shorter than the limit — even empty — while
        /// there is more to come. Loop on <c>hasMore</c>, never on the message count.
        /// </para>
        /// </remarks>
        public Task<ImSyncResult> SyncAsync(
            ImSyncMessagesRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return RequestAsync<ImSyncResult>("msg.sync", request, cancellationToken);
        }

        /// <summary>Pages backwards through history from a <c>seq</c> cursor.</summary>
        public Task<ImPage<ImMessage>> HistoryAsync(
            ImHistoryRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return RequestPageAsync<ImMessage>("msg.history", request, cancellationToken);
        }

        /// <summary>
        /// Withdraws a message for everyone. The server decides whether the sender still may — the
        /// window is per tenant, and outside it this fails rather than silently doing nothing.
        /// </summary>
        public Task RecallAsync(
            ImRecallMessageRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return ExecuteAsync("msg.recall", request, cancellationToken);
        }

        /// <summary>
        /// Deletes messages. Delete-for-me by default; distinct from
        /// <see cref="RecallAsync(ImRecallMessageRequest,CancellationToken)"/>, which withdraws them
        /// for everyone.
        /// </summary>
        public Task DeleteAsync(
            ImDeleteMessagesRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return ExecuteAsync("msg.delete", request, cancellationToken);
        }

        /// <summary>
        /// Reports that this user is typing. Never stored, never counted, never pushed, and dropped
        /// first when a connection is behind — so it carries no <c>seq</c> and costs a conversation
        /// nothing.
        /// </summary>
        /// <remarks>
        /// Fails with <see cref="ImErrorCode.FeatureNotEnabled"/> when the tenant has typing
        /// indicators off. Do not remember that: a tenant can flip the flag at runtime, and a client
        /// that latches it stays broken until the app restarts.
        /// </remarks>
        public Task TypingAsync(
            ImTypingRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return ExecuteAsync("msg.typing", request, cancellationToken);
        }

        /// <summary>Replaces the content of a message that has already been sent.</summary>
        public Task EditAsync(
            ImEditMessageRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return ExecuteAsync("msg.edit", request, cancellationToken);
        }

        /// <summary>
        /// Forwards messages into other conversations, one send per target, or bundled into a single
        /// merged message when <see cref="ImForwardMessagesRequest.Merge"/> is set.
        /// </summary>
        /// <remarks>
        /// The result list is one <see cref="ImSendResult"/> per target, in request order.
        /// <see cref="ImForwardMessagesRequest.ClientMsgId"/> is generated here when the caller
        /// leaves it null, for the same reason a send's is.
        /// </remarks>
        public async Task<List<ImSendResult>> ForwardAsync(
            ImForwardMessagesRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.SourceConversationId, "sourceConversationId");

            if (string.IsNullOrEmpty(request.ClientMsgId))
            {
                request.ClientMsgId = Client.NewClientMsgId();
            }

            var data = await RequestAsync("msg.forward", request, cancellationToken).ConfigureAwait(false);

            var results = new List<ImSendResult>(data.Count);
            foreach (var item in data.Items)
            {
                results.Add(ImSendResult.FromJson(item));
            }

            return results;
        }

        /// <summary>Adds or removes an emoji reaction.</summary>
        public Task ReactAsync(
            ImReactRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            Require(request.Emoji, "emoji");
            return ExecuteAsync("msg.react", request, cancellationToken);
        }

        /// <summary>
        /// Acknowledges specific messages as read. Distinct from
        /// <see cref="ImConvApi.ReadAsync(ImReadRequest,CancellationToken)"/>, which moves the
        /// conversation-level cursor the unread badge is derived from.
        /// </summary>
        public Task ReceiptAsync(
            ImReceiptRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return ExecuteAsync("msg.receipt", request, cancellationToken);
        }

        // ------------------------------------------------------------------------- T3
        //
        // Every message id below leaves as a string, and for these endpoints that is the server's
        // requirement rather than this SDK's caution: the request DTOs declare messageId as a C#
        // string, and the gateway's socket binder turns a JSON number for one into 1000
        // InternalError. See ImConversationMessageRequest.
        // 下面每个消息 id 都以字符串出线：服务端 DTO 就是 string，给数字会被绑定器拒成 1000。

        /// <summary>
        /// Pins a message to the conversation's board, which every participant sees.
        /// </summary>
        /// <remarks>
        /// <para>
        /// In a single chat either side may pin. In a group only the owner or an admin may while the
        /// deployment keeps <c>IM:Extras:GroupPinRequiresAdmin</c> on (the default), and anyone else
        /// gets <see cref="ImErrorCode.NoGroupPermission"/>. Chat rooms refuse with
        /// <see cref="ImErrorCode.UnsupportedOperation"/>.
        /// </para>
        /// <para>
        /// Refusals: <see cref="ImErrorCode.MessageNotFound"/> for a missing or recalled message;
        /// <see cref="ImErrorCode.UnsupportedOperation"/> for an ephemeral one (sent with
        /// <c>options.expireIn</c>); <see cref="ImErrorCode.Conflict"/> when the board already holds
        /// its cap (<c>IM:Extras:MaxPinsPerConversation</c>, 20 by default) — unpin one first.
        /// Pinning something already pinned succeeds and announces nothing.
        /// </para>
        /// <para>
        /// On success the server posts a notification message (content type 9, code <c>1514</c>) that
        /// neither counts as unread nor pushes. Its <c>content.messageId</c> is a bare JSON number,
        /// unlike every other message id on the wire, and loses digits on any route through a
        /// double — re-read <see cref="PinsAsync(ImConversationIdRequest,CancellationToken)"/>
        /// rather than trusting it.
        /// </para>
        /// </remarks>
        public Task PinAsync(
            ImConversationMessageRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            RequireMessageId(request.MessageId, "messageId");
            return ExecuteAsync("msg.pin", request, cancellationToken);
        }

        /// <summary>Takes a message off the conversation's board. Same permissions as pinning.</summary>
        /// <remarks>
        /// A message that is not pinned succeeds silently — which is why an id the server could not
        /// read is refused here instead of being sent. The <c>1514</c> notification with
        /// <c>pinned: false</c> is posted only when a pin was actually removed.
        /// </remarks>
        public Task UnpinAsync(
            ImConversationMessageRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            RequireMessageId(request.MessageId, "messageId");
            return ExecuteAsync("msg.unpin", request, cancellationToken);
        }

        /// <summary>
        /// The conversation's pin board, newest pin first. A plain list, not a page: the board is
        /// capped (20 by default), so there is nothing to page through.
        /// </summary>
        /// <remarks>
        /// Any participant may read it; a group non-member gets
        /// <see cref="ImErrorCode.NotGroupMember"/>. Pins whose message has since vanished are
        /// dropped from the answer and cleaned up. An empty board is an empty list, not an error.
        /// </remarks>
        public Task<List<ImPinnedMessage>> PinsAsync(
            ImConversationIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            return RequestListAsync<ImPinnedMessage>("msg.pins", request, cancellationToken);
        }

        /// <summary>Bookmarks a message for this user only. Private and silent.</summary>
        /// <remarks>
        /// Refusals: <see cref="ImErrorCode.MessageNotFound"/>;
        /// <see cref="ImErrorCode.UnsupportedOperation"/> for an ephemeral message;
        /// <see cref="ImErrorCode.Conflict"/> once the user holds
        /// <c>IM:Extras:MaxFavouritesPerUser</c> (5000 by default) — counted before the write, so
        /// re-favouriting at the cap fails too. A recalled message is <i>not</i> refused. Repeating
        /// the call is safe but moves the favourite back to the top.
        /// </remarks>
        public Task FavouriteAsync(
            ImConversationMessageRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            RequireMessageId(request.MessageId, "messageId");
            return ExecuteAsync("msg.favourite", request, cancellationToken);
        }

        /// <summary>Removes a bookmark. Always succeeds, repeats safely, and works after leaving the conversation.</summary>
        public Task UnfavouriteAsync(
            ImConversationMessageRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            RequireMessageId(request.MessageId, "messageId");
            return ExecuteAsync("msg.unfavourite", request, cancellationToken);
        }

        /// <summary>This user's bookmarked messages, newest favourite first, as whole messages.</summary>
        /// <remarks>
        /// <para>
        /// Page until <see cref="ImPage{T}.NextCursor"/> is null: a page can come back short — even
        /// empty — while the cursor is still set, because favourites in conversations the user can
        /// no longer read are hidden (kept, not deleted) after the page is cut. Favourites whose
        /// message is gone, or that the user deleted for themselves, are removed for good.
        /// </para>
        /// <para>
        /// Recalled messages are listed, with <see cref="ImMessage.Recalled"/> set. The rows carry
        /// no favourite timestamp, and <see cref="ImPage{T}.Total"/> is always null.
        /// </para>
        /// </remarks>
        public Task<ImPage<ImMessage>> FavouritesAsync(
            ImPageRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestPageAsync<ImMessage>(
                "msg.favourites",
                request != null ? request : new ImPageRequest(),
                cancellationToken);
        }

        /// <summary>
        /// Starts the burn-after-reading clock on an ephemeral message, for every participant.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Only for messages sent with <c>options.expireIn</c> above 0; anything else is refused with
        /// <see cref="ImErrorCode.UnsupportedOperation"/>. Called by the sender on their own message
        /// it succeeds and starts nothing, so it is safe to call for every ephemeral message this
        /// client renders.
        /// </para>
        /// <para>
        /// The first read by anyone other than the sender moves <c>expireAt</c> from
        /// <c>createTime + expireIn</c> to <c>now + expireIn</c>, conversation-wide — in a group the
        /// first reader starts everyone's clock. Later calls succeed silently. The change is pushed
        /// to participants as <c>evt.messageUpdate</c> with <c>kind: "burn"</c> and the absolute
        /// <c>expireAt</c>. A message nobody reads still expires at <c>createTime + expireIn</c>.
        /// </para>
        /// <para>
        /// This is a courtesy between cooperating clients, not a guarantee: a recipient that already
        /// holds the bytes can keep them.
        /// </para>
        /// </remarks>
        public Task BurnAsync(
            ImConversationMessageRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            RequireMessageId(request.MessageId, "messageId");
            return ExecuteAsync("msg.burn", request, cancellationToken);
        }

        /// <summary>Full-text search over messages this user can read, newest first.</summary>
        /// <remarks>
        /// <para>
        /// <b>Off unless the tenant turned it on.</b> The server checks, in this order: a per-user
        /// rate limit (<see cref="ImErrorCode.RateLimited"/>, 30 a minute by default, a 60-second
        /// sliding window with no retry hint); the tenant's search switch
        /// (<see cref="ImErrorCode.FeatureNotEnabled"/> — off by default, and forced off for
        /// end-to-end-encrypted apps); the search add-on in the plan
        /// (<see cref="ImErrorCode.PlanExpired"/>). The limiter runs <i>first</i>, so calls against a
        /// tenant with search off still spend the budget: debounce search-as-you-type. Do not
        /// remember a <see cref="ImErrorCode.FeatureNotEnabled"/> — the tenant can flip the switch at
        /// runtime.
        /// </para>
        /// <para>
        /// Recalled messages and messages this user deleted for themselves are excluded. The filters
        /// on <see cref="ImSearchMessagesRequest"/> apply after the index page is cut, so short and
        /// empty pages with <see cref="ImPage{T}.HasMore"/> set are normal; <see cref="ImPage{T}.Total"/>
        /// may be null. An index that takes more than five seconds comes back as
        /// <see cref="ImErrorCode.InternalError"/> rather than a timeout — treat it as retryable.
        /// </para>
        /// </remarks>
        public Task<ImPage<ImMessage>> SearchAsync(
            ImSearchMessagesRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);

            // Blank, not only empty: the server refuses a whitespace keyword with 1001 too, but only
            // after its rate limiter has charged the call to the user's per-minute budget.
            // 空白关键字服务端也会拒，但那是在限流器已经扣掉一次额度之后。
            if (string.IsNullOrWhiteSpace(request.Keyword))
            {
                throw new ArgumentException("keyword is required and must not be blank", "keyword");
            }

            return RequestPageAsync<ImMessage>("msg.search", request, cancellationToken);
        }

        /// <summary>Who has read one message — the detail behind a receipt tick.</summary>
        /// <remarks>
        /// <para>
        /// Refused with <see cref="ImErrorCode.MessageNotFound"/> when the message does not exist and
        /// <see cref="ImErrorCode.ReceiptDisabled"/> when it was not sent with
        /// <c>options.needReceipt</c>; the usual access errors apply. A message nobody has read yet
        /// returns an empty receipt rather than an error.
        /// </para>
        /// <para>
        /// <see cref="ImMessageReceipt.TotalCount"/> includes the sender and
        /// <see cref="ImMessageReceipt.ReadUserIds"/> never does, so "read by everyone" is
        /// <c>ReadCount == TotalCount - 1</c>. This read itself is not capped or truncated. The
        /// group-size cap is on writing: <see cref="ReceiptAsync(ImReceiptRequest,CancellationToken)"/>
        /// is refused in groups larger than the tenant's receipt limit (100 by default), so in such a
        /// group this returns an empty — or frozen — receipt.
        /// </para>
        /// </remarks>
        public Task<ImMessageReceipt> ReceiptDetailAsync(
            ImReceiptDetailRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ConversationId, "conversationId");
            RequireMessageId(request.MessageId, "messageId");
            return RequestAsync<ImMessageReceipt>("msg.receiptDetail", request, cancellationToken);
        }

        // There is deliberately no SendTextAsync here.
        //
        // `msg.sendText` is not an endpoint — it is not in sdk/endpoint-inventory.json and never
        // was. CONTRACT §4.2 says the namespaced surface is the endpoint list transliterated and
        // nothing else, precisely so that a reader who knows an endpoint name knows the call and a
        // support engineer can grep a bug report for it. A convenience with no endpoint behind it
        // breaks both, and this one broke them twice over: the deprecation messages on the flat
        // aliases pointed *at* it, so the SDK was teaching the invented shape as the correct one.
        //
        // The flat `im.SendTextAsync(...)` alias stays — it is one of the nine frozen legacy
        // methods §4.2 permits, it is in every published sample, and the other four SDKs keep the
        // same alias in the same place. Its replacement is `im.Msg.SendAsync(new ImSendRequest…)`.
        //
        // 这里刻意没有 SendTextAsync：msg.sendText 根本不是一个端点。契约 §4.2 规定命名空间层
        // 就是端点表的转写，凭空多出来的方法会让"知道端点名就知道方法名"这条保证失效。
    }
}
