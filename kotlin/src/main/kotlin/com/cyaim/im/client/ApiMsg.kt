package com.cyaim.im.client

/**
 * `msg.*` — everything that happens to a message.
 *
 * [send] is the only method here that touches the SDK's cursors, and only through the same
 * delivery path a pushed message takes. [sync] in particular moves nothing: it is the raw endpoint,
 * useful for a bespoke backfill, and the automatic gap repair is a separate caller of it.
 */
public class MsgApi internal constructor(
    private val connection: ImConnection,
    private val newClientMsgId: () -> String,
    private val onSent: suspend (SendMessageResult) -> Unit,
) {

    /**
     * Sends a message and returns the server's authoritative result: its `seq`, its `messageId`,
     * and whether the server recognised it as a duplicate of an earlier attempt.
     *
     * A blank [SendMessageRequest.clientMsgId] is filled in here rather than rejected, so a caller
     * who never thinks about idempotency gets it anyway: `(appId, conversationId, senderId,
     * clientMsgId)` is unique server-side, and a resend after a timeout returns the first result
     * with `deduplicated = true` instead of posting the message twice.
     */
    public suspend fun send(request: SendMessageRequest): SendMessageResult {
        val payload = when {
            request.clientMsgId.isNotBlank() -> request
            else -> request.copy(clientMsgId = newClientMsgId())
        }
        val stamped = if (payload.sendTime > 0) payload else payload.copy(sendTime = System.currentTimeMillis())
        val result = connection.request<SendMessageResult>("msg.send", stamped.asBody())
        onSent(result)
        return result
    }

    /** [send] with the target as a sealed type, so "exactly one of three" is a compile error. */
    public suspend fun send(request: SendRequest): SendMessageResult =
        send(request.toWire(request.clientMsgId ?: newClientMsgId(), System.currentTimeMillis()))

    /**
     * Fetches an exact seq window. Gap repair, not paging: the server honours the range to the
     * number rather than returning a "close enough" page.
     *
     * The raw endpoint. It does not deliver anything through [ImClient.messages] and it does not
     * move a cursor — [ImClient] repairs gaps by calling this and then feeding the result through
     * the normal delivery path, which is what makes dedupe, ordering and commit behave identically
     * for a repaired message and a live one.
     *
     * **Loop on [SyncMessagesResult.hasMore], never on `messages.size`.** `hasMore` is computed on
     * the raw window before messages hidden from this reader are filtered out, so a short — even
     * empty — page with `hasMore = true` is normal, and stopping on a short page leaves the hole
     * the repair was for.
     */
    public suspend fun sync(request: SyncMessagesRequest): SyncMessagesResult =
        connection.request("msg.sync", request.asBody())

    /** Pages backwards from a seq cursor. `beforeSeq` is exclusive. */
    public suspend fun history(request: HistoryRequest): Page<ImMessage> =
        connection.request("msg.history", request.asBody())

    public suspend fun recall(request: RecallMessageRequest) {
        connection.execute("msg.recall", request.asBody())
    }

    /** Replaces the content of a message you sent, inside the tenant's edit window. */
    public suspend fun edit(request: EditMessageRequest) {
        connection.execute("msg.edit", request.asBody())
    }

    /**
     * Deletes messages. `forEveryone = false` (the default) hides them from you alone; true
     * destroys other people's copy and the server checks whether you may.
     */
    public suspend fun delete(request: DeleteMessagesRequest) {
        connection.execute("msg.delete", request.asBody())
    }

    /** Forwards to one or more conversations; one result per target. */
    public suspend fun forward(request: ForwardMessagesRequest): List<SendMessageResult> {
        val payload = if (request.clientMsgId.isNotBlank()) request else request.copy(clientMsgId = newClientMsgId())
        return connection.request("msg.forward", payload.asBody())
    }

    public suspend fun react(request: ReactRequest) {
        connection.execute("msg.react", request.asBody())
    }

    /** Per-message read acknowledgement. Distinct from `conv.read`, which is the whole cursor. */
    public suspend fun receipt(request: ReceiptRequest) {
        connection.execute("msg.receipt", request.asBody())
    }

    /**
     * Typing indicator. Never stored, never counted, never given a seq.
     *
     * Answers `1203 FeatureNotEnabled` when the tenant has the indicator switched off. **Do not
     * latch that locally** — the tenant can turn it back on at runtime, and a client that
     * remembers "typing is off" stays broken until the app restarts. Report it and keep calling.
     */
    public suspend fun typing(request: TypingRequest) {
        connection.execute("msg.typing", request.asBody())
    }

    /** [typing] for the two-field case. */
    public suspend fun typing(conversationId: String, typing: Boolean = true): Unit =
        typing(TypingRequest(conversationId, typing))

    // ---------------------------------------------------------------- T3: competitive parity
    //
    // Every message id below leaves the device quoted — see ConversationMessageRequest. For these
    // endpoints that is the server's requirement: their DTOs declare the id a string, and a JSON
    // number in its place is refused with 1000 before the endpoint runs.
    // 下面每个消息 id 都以字符串出线：服务端 DTO 就是 string，给数字会被绑定器拒成 1000。

    /**
     * Pins a message to the conversation's shared board — something everyone in the conversation
     * sees, as opposed to [favourite], which only the caller does.
     *
     * **Who may:** either side of a single chat. In a group, only the owner or an admin while the
     * deployment's `IM:Extras:GroupPinRequiresAdmin` is on, which is the default (`1504`
     * otherwise). Chat rooms are `1008`; a system or assistant conversation is `1103` unless the
     * caller has received something there.
     *
     * **Refusals:** `1400` for a message that is not there — including a `messageId` the server
     * cannot parse — and for a recalled one; `1008` for an ephemeral message (sent with
     * `options.expireIn`); `1006` once the board holds `IM:Extras:MaxPinsPerConversation` pins
     * (20 by default) — unpin one first. Pinning what is already pinned succeeds and announces
     * nothing.
     *
     * On success every participant gets a notification message (`contentType` 9, `content.code`
     * 1514, `pinned: true`), which does not count as unread and sends no push. **Do not take the
     * message id from that notification:** its `content.messageId` is a bare JSON number, which a
     * JavaScript or Dart-on-web peer has already rounded. Re-read [pins] instead.
     *
     * 置顶成功会发一条 1514 通知，但它的 content.messageId 是裸数字，在 JS 一侧已经丢了精度——请重新读 pins。
     */
    public suspend fun pin(request: ConversationMessageRequest) {
        connection.execute("msg.pin", request.asBody())
    }

    /** [pin] for the two-field case. */
    public suspend fun pin(conversationId: String, messageId: Long): Unit =
        pin(ConversationMessageRequest(conversationId, messageId))

    /**
     * Takes a message off the board. Same permission rules as [pin].
     *
     * **Succeeds silently when nothing was pinned** — including for a `messageId` the server cannot
     * parse — so it is safe to retry, and a success is no proof the id was right. The 1514
     * notification (`pinned: false`) goes out only when a pin was actually removed and the message
     * still exists.
     */
    public suspend fun unpin(request: ConversationMessageRequest) {
        connection.execute("msg.unpin", request.asBody())
    }

    /** [unpin] for the two-field case. */
    public suspend fun unpin(conversationId: String, messageId: Long): Unit =
        unpin(ConversationMessageRequest(conversationId, messageId))

    /**
     * The conversation's pinned board, newest pin first.
     *
     * **A plain list, not a [Page]:** the board is capped (20 by default), so there is nothing to
     * page through, and an empty list means nothing is pinned. Any participant may read it; a
     * group non-member is `1503`. Pins whose message has since vanished are dropped from the answer
     * and cleaned up server-side.
     */
    public suspend fun pins(request: ConversationIdRequest): List<PinnedMessage> =
        connection.request("msg.pins", request.asBody())

    /** [pins] for the one-field case. */
    public suspend fun pins(conversationId: String): List<PinnedMessage> = pins(ConversationIdRequest(conversationId))

    /**
     * Bookmarks a message for the caller alone. Private and silent: nobody else is told.
     *
     * **Refusals:** `1400` for a message that is not there (including an unparseable id); `1008`
     * for an ephemeral message; `1006` once the caller holds `IM:Extras:MaxFavouritesPerUser`
     * (5000 by default). The count is taken **before** the write, so re-favouriting something at the
     * cap fails too. A recalled message is **not** refused. Repeating it is safe, but it resets the
     * timestamp and moves the favourite back to the top of [favourites].
     */
    public suspend fun favourite(request: ConversationMessageRequest) {
        connection.execute("msg.favourite", request.asBody())
    }

    /** [favourite] for the two-field case. */
    public suspend fun favourite(conversationId: String, messageId: Long): Unit =
        favourite(ConversationMessageRequest(conversationId, messageId))

    /**
     * Removes a bookmark. **Always succeeds** — nothing to remove, an unparseable id, a
     * conversation the caller has since left: all `0`. Safe to repeat, and a success proves nothing
     * about the id.
     */
    public suspend fun unfavourite(request: ConversationMessageRequest) {
        connection.execute("msg.unfavourite", request.asBody())
    }

    /** [unfavourite] for the two-field case. */
    public suspend fun unfavourite(conversationId: String, messageId: Long): Unit =
        unfavourite(ConversationMessageRequest(conversationId, messageId))

    /**
     * The caller's bookmarks across every conversation, newest favourite first, as whole messages.
     * There is no favourite id or favourite timestamp in the answer — the message is the entry.
     *
     * **Page on [Page.nextCursor], never on `items.size`.** Favourites in chats the caller can no
     * longer read are hidden (and kept), so a page can come back short — even empty — with more to
     * come. Favourites whose message is gone, or that the caller deleted for themselves, are
     * removed. Recalled messages **are** listed, with `recalled` set. [Page.total] is never present.
     */
    public suspend fun favourites(request: PageRequest = PageRequest()): Page<ImMessage> =
        connection.request("msg.favourites", request.asBody())

    /**
     * Burn-after-reading: starts the countdown on an ephemeral message the caller has opened.
     *
     * Only for a message sent with `options.expireIn > 0`; anything else is `1008`. A missing or
     * unparseable id is `1001` — the one T3 target that validates it — and a message that is not
     * there is `1400`.
     *
     * The **first** read by anyone other than the sender moves `expireAt` from
     * `createTime + expireIn` to `now + expireIn`, and that is conversation-wide: in a group the
     * first reader starts everyone's clock. Later calls, and the sender's own call on their own
     * message, succeed and change nothing, so it is safe to call for every ephemeral message you
     * render. Participants learn the new deadline from an `evt.messageUpdate` push with
     * `kind: "burn"` and an absolute `expireAt`. A message nobody opens still expires at
     * `createTime + expireIn`.
     *
     * This is a courtesy between cooperating clients, not a guarantee: a recipient who already has
     * the bytes can keep them.
     *
     * 阅后即焚只在 expireIn > 0 的消息上生效；第一个非发送者读者启动的是整个会话的倒计时。
     * 它是守约客户端之间的约定，不是保证。
     */
    public suspend fun burn(request: ConversationMessageRequest) {
        connection.execute("msg.burn", request.asBody())
    }

    /** [burn] for the two-field case. */
    public suspend fun burn(conversationId: String, messageId: Long): Unit =
        burn(ConversationMessageRequest(conversationId, messageId))

    /**
     * Full-text search over the caller's messages, newest first.
     *
     * **Off by default.** The tenant's `EnableSearch` is false unless someone turned it on, and it
     * is forced off for an end-to-end-encrypted app: that answers `1203 FeatureNotEnabled`. Do not
     * latch it — the flag is a runtime setting. A plan without the search add-on answers
     * `1204 PlanExpired`.
     *
     * **Rate limited on its own, and before either of those checks.** Each user gets
     * `MaxSearchPerMinutePerUser` calls in a sliding 60-second window (30 by default) and then
     * `1003 RateLimited` with no retry hint — and calls against a disabled search still spend the
     * budget. Debounce a search-as-you-type box.
     *
     * Recalled messages and messages the caller deleted for themselves are excluded. Short, even
     * empty, pages with `hasMore = true` are normal — see [SearchMessagesRequest] — so page on
     * [Page.hasMore]. [Page.total] may be absent. An index slower than five seconds comes back as
     * `1000 InternalError` rather than `1004`; treat it as retryable.
     *
     * 默认关闭（1203，不要记住它）；自带每人每分钟 30 次的限流（1003），而且在开关检查之前计数——输入联想要防抖。
     */
    public suspend fun search(request: SearchMessagesRequest): Page<ImMessage> =
        connection.request("msg.search", request.asBody())

    /**
     * Who has read one message.
     *
     * Answers from the stored receipt when there is one. Otherwise `1400` for a message that is not
     * there (including an unparseable id), `1410` for one not sent with `options.needReceipt`, and
     * for the rest an empty receipt: no readers, `readCount` 0, the current `totalCount`, and
     * `updatedAt` equal to the message's `createTime`. Access errors are `1001`, `1103` and `1503`.
     *
     * **Nothing caps or truncates this read.** The member limit lives on the write side:
     * `msg.receipt` answers `1410` in a group larger than the tenant's `ReceiptGroupMemberLimit`
     * (100 by default), so nobody's read is recorded there and this returns an empty — or, if the
     * group grew past the limit, frozen — receipt. See [MessageReceipt] for why "read by everyone"
     * is `totalCount - 1`.
     *
     * 读取这一侧不设上限也不截断；人数上限作用在 msg.receipt 写入那一侧——超限的群根本记不下已读。
     */
    public suspend fun receiptDetail(request: ReceiptDetailRequest): MessageReceipt =
        connection.request("msg.receiptDetail", request.asBody())

    /** [receiptDetail] for the two-field case. */
    public suspend fun receiptDetail(conversationId: String, messageId: Long): MessageReceipt =
        receiptDetail(ReceiptDetailRequest(conversationId, messageId))

    // ------------------------------------------------------------------- streaming (T4)

    /**
     * Opens a stream — a reply that arrives a piece at a time — and pushes its opening `evt.stream`
     * frame to every online member of the conversation, the producer's own connection included.
     *
     * A blank [BeginStreamRequest.clientMsgId] is filled in, as [send] fills one: the server makes
     * none up, and it is the key the finished message is stored under. Every permission `msg.send`
     * checks is checked here, at the opening (see [BeginStreamRequest] for the codes); `1003` is more
     * than 60 openings a minute. Then [streamAppend] the pieces and [streamComplete] or [streamAbort]
     * within [StreamHandle.idleTimeoutSeconds] of the last call, or the server reaps the stream.
     *
     * 开流。clientMsgId 留空由这里补上（服务端不生成，最终消息以它为幂等键）。msg.send 的全部权限检查都在开流时做。
     */
    public suspend fun streamBegin(request: BeginStreamRequest): StreamHandle =
        connection.request("msg.streamBegin", keyed(request).asBody())

    /**
     * Sends the next piece; the server numbers it and pushes it as an `evt.stream` frame. See
     * [StreamAppendRequest] for the refusals — `1401` leaves the stream open.
     */
    public suspend fun streamAppend(request: StreamAppendRequest) {
        connection.execute("msg.streamAppend", request.asBody())
    }

    /**
     * Finishes the stream: the server stores it as one ordinary message, delivers that on
     * `evt.message`, pushes the terminal `evt.stream` frame, and answers the message's identity.
     *
     * **Unlike [send], this does not move the delivered cursor.** The stored message is pushed to the
     * producer's own connection too, and arrives on [ImClient.messages] through the ordinary path —
     * cursors, ordering and gap repair included. Moving the cursor here would make that delivery look
     * like a duplicate and drop it.
     *
     * Can be refused as `msg.send` can (moderation, a webhook, the store), and the stream is consumed
     * either way; a second complete answers `1002`.
     *
     * 与 send 不同，这里不推进 delivered 游标：存下来的消息也会推给生产者自己的连接，经普通路径进 messages；
     * 在这里推进游标会让那次投递被当成重复而丢掉。
     */
    public suspend fun streamComplete(request: CompleteStreamRequest): SendMessageResult =
        connection.request("msg.streamComplete", request.asBody())

    /**
     * Ends the stream without a message. Receivers get a terminal frame carrying the reason; nothing
     * is stored. A second abort, or one after [streamComplete], answers `1002`.
     */
    public suspend fun streamAbort(request: StreamAbortRequest) {
        connection.execute("msg.streamAbort", request.asBody())
    }

    // ------------------------------------------------------------------- scheduling (T4)

    /**
     * Schedules a message for [ScheduleRequest.sendAt] and answers the outbox entry — `scheduleId` to
     * cancel it by, no `messageId` yet.
     *
     * **Moves no cursor and delivers nothing.** When it fires, the message reaches the receiver as an
     * ordinary `evt.message` with a real seq (and the sender's devices through the usual self-sync), on the
     * first server sweep after `sendAt` (every 15 seconds by default). No event announces the schedule
     * itself. **Not idempotent**: a retry after a lost reply schedules twice. See [ScheduleRequest] for
     * the refusals and limits.
     *
     * 不动游标、不投递任何东西：到点发出时，接收方经普通 evt.message 收到它（发送者的设备经通常的自同步），粒度是服务端扫描周期（默认 15 秒）。
     * 不幂等：丢了答复就重试会建两条。
     */
    public suspend fun schedule(request: ScheduleRequest): ScheduledMessage =
        connection.request("msg.schedule", request.asBody())

    /**
     * The caller's outbox in `sendAt` order, earliest first: pending schedules **and** the ones settled
     * in about the last 48 hours — sent, cancelled (`error` "cancelled by sender") or failed. See
     * [ScheduledMessage] for telling them apart. The server's page is 20 by default and 100 at most.
     * Page on [Page.nextCursor]; [Page.total] is never present.
     *
     * 按 sendAt 从早到晚列出待发的，以及约 48 小时内已了结的（已发、已取消、失败）。
     */
    public suspend fun scheduled(request: PageRequest = PageRequest()): Page<ScheduledMessage> =
        connection.request("msg.scheduled", request.asBody())

    /**
     * Cancels one of the caller's pending schedules. `1002` for an unknown id or someone else's,
     * `1006` once it is being sent. The entry stays listed, marked cancelled, for about 48 hours.
     */
    public suspend fun cancelScheduled(request: ScheduleIdRequest) {
        connection.execute("msg.cancelScheduled", request.asBody())
    }

    /** [cancelScheduled] for the one-field case. */
    public suspend fun cancelScheduled(scheduleId: String): Unit = cancelScheduled(ScheduleIdRequest(scheduleId))

    // ------------------------------------------------------------------ translation (T4)

    /**
     * Translates up to 50 messages of one conversation. Per-message failures come back inside the
     * result ([TranslatedMessage.error]); the call itself fails only as a whole.
     *
     * **A deployment without translation refuses it as an ordinary [ImException]**: `1204
     * PlanExpired` when the plan lacks the translation add-on, `1203 FeatureNotEnabled` when the plan
     * has it but no provider is configured — both checked before the request itself, both carrying
     * the server's message. Neither is retryable; do not latch either for longer than a session.
     *
     * 没有翻译能力的部署以普通 ImException 拒绝：套餐不含翻译回 1204，含翻译但没配服务商回 1203，都带服务端的原话，都不可重试。
     */
    public suspend fun translate(request: TranslateRequest): TranslationResult =
        connection.request("msg.translate", request.asBody())

    /** [request] with a client message id, filled in when blank. Shared by [StreamWriter]. */
    internal fun keyed(request: BeginStreamRequest): BeginStreamRequest =
        if (request.clientMsgId.isNotBlank()) request else request.copy(clientMsgId = newClientMsgId())
}
