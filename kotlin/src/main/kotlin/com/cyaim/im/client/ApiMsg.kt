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
}
