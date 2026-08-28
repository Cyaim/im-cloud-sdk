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
