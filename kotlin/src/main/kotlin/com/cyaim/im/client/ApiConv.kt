package com.cyaim.im.client

/** `conv.*` — the list a user opens the app to, and the per-user state attached to it. */
public class ConvApi internal constructor(private val connection: ImConnection) {

    /**
     * The conversation list, incrementally.
     *
     * Pass the largest `updatedAt` you already hold as [ListConversationsRequest.updatedAfter] and
     * you download only what moved. **Page on `hasMore`/`nextCursor`, not on `items.size`** — the
     * server computes its cursor before filtering deleted conversations out, so a page shorter
     * than the limit with `hasMore = true` is ordinary.
     */
    public suspend fun list(request: ListConversationsRequest = ListConversationsRequest()): Page<ConversationView> =
        connection.request("conv.list", request.asBody())

    public suspend fun get(request: ConversationIdRequest): ConversationView =
        connection.request("conv.get", request.asBody())

    /** [get] for the one-field case. */
    public suspend fun get(conversationId: String): ConversationView = get(ConversationIdRequest(conversationId))

    /**
     * Moves the read cursor. Unread everywhere is derived from it, so this one write also clears
     * the badge on every other device of the same user.
     */
    public suspend fun read(request: ReadRequest) {
        connection.execute("conv.read", request.asBody())
    }

    /** [read] for the two-field case. */
    public suspend fun read(conversationId: String, readSeq: Long): Unit = read(ReadRequest(conversationId, readSeq))

    /** Pin, mute, draft and tags. Null fields of the setting are left alone. */
    public suspend fun setting(request: UpdateConversationSettingRequest) {
        connection.execute("conv.setting", request.asBody())
    }

    /**
     * Removes the conversation from **your** list. Other members keep theirs, and a new message
     * brings it back.
     */
    public suspend fun delete(request: ConversationIdRequest) {
        connection.execute("conv.delete", request.asBody())
    }

    /** [delete] for the one-field case. */
    public suspend fun delete(conversationId: String): Unit = delete(ConversationIdRequest(conversationId))

    /**
     * Clears **your** copy of the history. Clearing for everyone destroys other people's data and
     * is a server-API operation, not something a client may ask for.
     *
     * The server raises the reader's floor rather than deleting rows, so a later `msg.sync` for a
     * cleared range comes back empty with a higher `minSeq` — which is how the SDK's repair loop
     * knows to stop asking rather than retrying forever.
     */
    public suspend fun clear(request: ConversationIdRequest) {
        connection.execute("conv.clear", request.asBody())
    }

    /** [clear] for the one-field case. */
    public suspend fun clear(conversationId: String): Unit = clear(ConversationIdRequest(conversationId))

    /** Badge count across every conversation. `Long`, because the server returns one. */
    public suspend fun unreadTotal(): Long = connection.request("conv.unreadTotal")

    /**
     * Marks a conversation unread by hand — or, with `unread = false`, clears that mark.
     *
     * It does **not** move the read cursor, so the other side's receipts are untouched. It shows up
     * as [ConversationView.manuallyUnread], and the server reports `unreadCount` as 1 where it would
     * otherwise be 0. [read], [delete] and [clear] all clear it. Setting the value it already has
     * succeeds and sends nothing; a change reaches the caller's own devices as
     * `evt.conversationUpdate` with kind `"unread"`. Access errors are `1001`, `1103` and `1503`.
     *
     * 只是一个标记，不动 readSeq，对方的已读回执不受影响；conv.read / delete / clear 都会清掉它。
     */
    public suspend fun markUnread(request: MarkUnreadRequest) {
        connection.execute("conv.markUnread", request.asBody())
    }

    /** [markUnread] for the two-field case. */
    public suspend fun markUnread(conversationId: String, unread: Boolean = true): Unit =
        markUnread(MarkUnreadRequest(conversationId, unread))
}
