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

        // ------------------------------------------------------------------------- T4: streaming
        //
        // A reply produced a piece at a time (an AI assistant typing it out). The pieces travel as
        // evt.stream frames, which are not messages: no seq, online only, never stored, never repaired
        // (ImClient.OnStreamEvent, ImStreamAssembler). The completed stream is one ordinary message on
        // evt.message, through the cursors and gap repair like any other. See ImStreamTypes.cs.
        // 分片经 evt.stream 推送，不是消息：没有 seq、只投在线、不落库、不补洞。收尾后的那条才是普通消息，照常走游标与补洞。

        /// <summary>
        /// Opens a stream and tells every online member of the conversation to draw a placeholder.
        /// Returns the handle every later call names.
        /// </summary>
        /// <remarks>
        /// <para>
        /// A null <see cref="ImBeginStreamRequest.ClientMsgId"/> is generated and written back <b>onto the
        /// request object</b>, as <see cref="ForwardAsync"/> does, so the caller can read the key of the
        /// message this stream becomes; the server makes none up.
        /// </para>
        /// <para>
        /// Every refusal <c>msg.send</c> could give for the address and the sender is given here, at the
        /// opening: <c>1104</c> / <c>1408</c> / <c>1303</c> / <c>1302</c>, <c>1500</c> / <c>1501</c> /
        /// <c>1503</c> / <c>1506</c> / <c>1505</c>; <c>1008</c> for anything but a single chat or a group of
        /// at most 200; <c>1103</c> for refused options; <c>1003</c> past 60 openings a minute.
        /// </para>
        /// <para>
        /// 开流时就按 msg.send 的规则检查全部权限。ClientMsgId 留空则生成并写回请求对象，调用方可以读回。
        /// </para>
        /// </remarks>
        public Task<ImStreamHandle> StreamBeginAsync(
            ImBeginStreamRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            if (request.Recipient.IsEmpty)
            {
                throw new ArgumentException(
                    "ImBeginStreamRequest.Recipient is required; build one with ImRecipient.User/Group/Conversation.",
                    "request");
            }

            if (string.IsNullOrEmpty(request.ClientMsgId))
            {
                request.ClientMsgId = Client.NewClientMsgId();
            }

            return RequestAsync<ImStreamHandle>("msg.streamBegin", request, cancellationToken);
        }

        /// <summary>Sends the next piece of an open stream.</summary>
        /// <remarks>
        /// An empty delta is accepted by the server and does nothing. Refusals: <c>1002</c> finished or
        /// expired, <c>1103</c> someone else's stream, <c>1401</c> a piece over 4096 characters or a text
        /// past the cap (the stream stays open), <c>1003</c> more than 100 pieces a second.
        /// 空 delta 服务端接受且什么都不做；1401 之后流仍然开着。
        /// </remarks>
        public Task StreamAppendAsync(
            ImStreamAppendRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.StreamId, "streamId");
            return ExecuteAsync("msg.streamAppend", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="StreamAppendAsync(ImStreamAppendRequest, CancellationToken)"/>.</summary>
        public Task StreamAppendAsync(
            string streamId,
            string delta,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return StreamAppendAsync(new ImStreamAppendRequest(streamId, delta), cancellationToken);
        }

        /// <summary>
        /// Finishes a stream into one ordinary message and returns its <see cref="ImSendResult"/> — a real
        /// <c>Seq</c>, the <c>ClientMsgId</c> the stream was opened with.
        /// </summary>
        /// <remarks>
        /// <para>
        /// <b>Unlike <see cref="SendAsync"/>, this moves no cursor.</b> The stored message is delivered on
        /// <c>evt.message</c> to the producer's own connection too, and it must arrive on
        /// <see cref="ImClient.MessageReceived"/> like anyone else's; a delivered cursor already moved to
        /// its seq would drop it there as a duplicate.
        /// </para>
        /// <para>
        /// It can be refused the ways <c>msg.send</c> can (moderation, a webhook, the store), and the stream
        /// is consumed either way: receivers get a terminal frame with an <c>abortReason</c>, and a second
        /// complete or abort answers <c>1002</c>.
        /// </para>
        /// <para>
        /// 与 SendAsync 不同，这里不动游标：存下来的消息也会推给生产者自己的连接，必须照常从 MessageReceived 出来；
        /// 先把游标挪到它的 seq，它就会被当成重复丢掉。被拒时流同样被消费掉。
        /// </para>
        /// </remarks>
        public Task<ImSendResult> StreamCompleteAsync(
            ImCompleteStreamRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.StreamId, "streamId");
            return RequestAsync<ImSendResult>("msg.streamComplete", request, cancellationToken);
        }

        /// <summary>
        /// Ends a stream without a message. Receivers get a terminal frame with the reason, so no
        /// placeholder hangs for the idle window.
        /// </summary>
        public Task StreamAbortAsync(
            ImStreamAbortRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.StreamId, "streamId");
            return ExecuteAsync("msg.streamAbort", request, cancellationToken);
        }

        // ------------------------------------------------------------------------- T4: scheduled messages
        //
        // A schedule is not a message until it fires: no seq, no history, nothing pushed when it is created
        // or cancelled. When it fires, receivers get an ordinary evt.message with an ordinary seq, which
        // goes through MessageReceived, the cursors and gap repair like any other. See ImScheduleTypes.cs.
        // 发出之前它不是消息，创建与取消都没有推送；发出时接收方收到普通的 evt.message，照常走游标与补洞。

        /// <summary>
        /// Queues a message to be sent at <see cref="ImScheduleRequest.SendAt"/> and returns the schedule —
        /// a schedule id, not a message id.
        /// </summary>
        /// <remarks>
        /// <para>
        /// The body is the server's flat <c>ScheduleRequest</c>: the members of <c>msg.send</c> beside
        /// <c>sendAt</c>, no <c>options</c>, no <c>sendTime</c>. A null <see cref="ImScheduleRequest.ClientMsgId"/>
        /// is <i>not</i> generated here: the server uses <c>sch-&lt;scheduleId&gt;</c>.
        /// </para>
        /// <para>
        /// It fires on the first dispatcher pass at or after <c>sendAt</c> — every 15 seconds by default — so
        /// expect it up to about 15 s late. Refusals: <c>1001</c> (no content, no address, <c>sendAt</c> less
        /// than 10 s ahead or more than 90 days), the access errors of <c>msg.send</c>, <c>1006</c> at 100
        /// pending, <c>1003</c> past 120 an hour. <b>Not idempotent</b>: a retry makes a second schedule.
        /// Nothing here moves a cursor.
        /// </para>
        /// <para>
        /// 服务端每 15 秒（默认）扫一次，到点后的第一次扫描发出，可能晚到约 15 秒。ClientMsgId 留空不在这里生成，服务端用
        /// sch-&lt;scheduleId&gt;。本调用不幂等，也不动任何游标。
        /// </para>
        /// </remarks>
        public Task<ImScheduledMessage> ScheduleAsync(
            ImScheduleRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            if (request.Recipient.IsEmpty)
            {
                throw new ArgumentException(
                    "ImScheduleRequest.Recipient is required; build one with ImRecipient.User/Group/Conversation.",
                    "request");
            }

            if (request.Content == null || !request.Content.IsObject || request.Content.Count == 0)
            {
                throw new ArgumentException("ImScheduleRequest.Content must be a non-empty object", "request");
            }

            return RequestAsync<ImScheduledMessage>("msg.schedule", request, cancellationToken);
        }

        /// <summary>
        /// This user's schedules, a page at a time: the pending ones <b>and</b> those settled in about the
        /// last 48 hours — sent, cancelled or failed. <see cref="ImScheduledMessage"/> says how to tell them
        /// apart.
        /// </summary>
        /// <remarks>
        /// A cancelled schedule stays listed, with <see cref="ImScheduledMessage.IsCancelled"/>. Page on
        /// <see cref="ImPage{T}.NextCursor"/>; <see cref="ImPage{T}.Total"/> is always null. Default page 20,
        /// at most 100. Another device learns of a schedule only through this call.
        /// 已取消的仍在列表里（IsCancelled）。其他设备只能靠这个调用得知定时消息的变化。
        /// </remarks>
        public Task<ImPage<ImScheduledMessage>> ScheduledAsync(
            ImPageRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestPageAsync<ImScheduledMessage>(
                "msg.scheduled",
                request != null ? request : new ImPageRequest(),
                cancellationToken);
        }

        /// <summary>Cancels a schedule that has not been sent yet.</summary>
        /// <remarks>
        /// <para>
        /// <c>1002</c> for an unknown schedule or someone else's. <c>1006</c> means <b>nothing is left to
        /// cancel</b>, in one of three states that differ only in the server's message:
        /// </para>
        /// <list type="bullet">
        /// <item>in flight — "this message is already being sent and can no longer be cancelled";</item>
        /// <item>already cancelled — "this scheduled message has already been cancelled";</item>
        /// <item>already sent or failed — "this scheduled message has already been sent or has failed, and
        /// can no longer be cancelled".</item>
        /// </list>
        /// <para>
        /// Branch on the code, not the text. For one that was sent, the remedy is <c>msg.recall</c> on the
        /// message it became (its <see cref="ImScheduledMessage.MessageId"/>).
        /// The entry is not removed: <c>msg.scheduled</c> keeps it for about 48 hours with
        /// <see cref="ImScheduledMessage.Error"/> = <see cref="ImScheduledMessage.CancelledBySender"/>.
        /// 未知或别人的是 1002。1006 表示已无可取消：正在发送、已取消、已发出或已失败三种情况，只有消息文本不同；
        /// 按码分支，不要按文本。已发出的那种，补救办法是对它变成的那条消息 msg.recall。
        /// </para>
        /// </remarks>
        public Task CancelScheduledAsync(
            ImScheduleIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.ScheduleId, "scheduleId");
            return ExecuteAsync("msg.cancelScheduled", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="CancelScheduledAsync(ImScheduleIdRequest, CancellationToken)"/>.</summary>
        public Task CancelScheduledAsync(
            string scheduleId,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return CancelScheduledAsync(new ImScheduleIdRequest(scheduleId), cancellationToken);
        }

        // ------------------------------------------------------------------------- T4: translation

        /// <summary>
        /// Translates messages this user can already read into <see cref="ImTranslateRequest.TargetLanguage"/>.
        /// </summary>
        /// <remarks>
        /// <para>
        /// <b>Expect a refusal on most deployments</b>: <see cref="ImErrorCode.PlanExpired"/> (<c>1204</c>)
        /// when the plan lacks the translation add-on, <see cref="ImErrorCode.FeatureNotEnabled"/>
        /// (<c>1203</c>) when no provider is configured. Both arrive as an ordinary <see cref="ImException"/>
        /// carrying the code and the server's message — show a "translation unavailable" state, and do not
        /// cache it. A message that alone could not be translated has
        /// <see cref="ImTranslatedMessage.Error"/> set; the others still carry their text.
        /// </para>
        /// <para>
        /// 大多数部署会拒绝：缺翻译增值项回 1204，没配翻译服务回 1203，都以普通 ImException（码 + 服务端原文）抛出，别缓存。
        /// 单条翻译失败只体现在那一条的 Error 上。
        /// </para>
        /// </remarks>
        public Task<ImTranslationResult> TranslateAsync(
            ImTranslateRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);

            // Both are required members of the server's type: a body without one fails to bind and comes
            // back 1000, not a 1001 naming the field.
            // 两者在服务端类型上都是 required：缺了会在绑定阶段失败、回 1000，而不是点名字段的 1001。
            Require(request.ConversationId, "conversationId");
            Require(request.TargetLanguage, "targetLanguage");
            return RequestAsync<ImTranslationResult>("msg.translate", request, cancellationToken);
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
