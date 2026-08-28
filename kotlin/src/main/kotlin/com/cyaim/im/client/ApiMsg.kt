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
}
