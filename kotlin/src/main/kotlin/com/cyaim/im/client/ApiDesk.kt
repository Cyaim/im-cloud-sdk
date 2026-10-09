package com.cyaim.im.client

/**
 * `desk.*` — the customer-service desk, from both sides of it (T4).
 *
 * **Two audiences, one namespace, and which one you are is decided by the session rather than by
 * the method you call.** [request] and [rate] are the customer's; [accept], [transfer], [status],
 * [queue], [canned] and [suggest] are an agent's; [close] is either side's. The server checks the
 * caller against the session's holder on every one of them, so an agent-shaped call from a customer
 * is `1103`, not a privilege escalation.
 *
 * **The conversation is not here.** Everything a customer and an agent say to each other is an
 * ordinary single chat between the customer and the desk account, sent with `msg.send` and read with
 * `msg.history`. These nine verbs only move the *assignment* around it — which is why an in-app
 * support screen is a chat screen plus [request] and [rate].
 *
 * **A deployment older than this build answers `1008 UnsupportedOperation`** rather than a
 * desk-specific code; neither retrying nor re-authenticating changes it.
 *
 * 两种角色共用一个命名空间，「你是谁」由会话判定。聊天不在这里：客户与坐席之间就是一条普通单聊，
 * 这九个动词只负责「谁来接」。
 */
public class DeskApi internal constructor(private val connection: ImConnection) {

    /**
     * Asks for a person, and returns the session — a new one, or the caller's own open one.
     *
     * Idempotent, so the button needs no guard. [DeskSession.state] says what happened:
     * [DeskSessionState.Queued] means waiting (the 1801 notice is already in the transcript),
     * [DeskSessionState.Assigned] means an idle agent took it in the same call.
     */
    public suspend fun request(request: DeskRequest = DeskRequest()): DeskSession =
        connection.request("desk.request", request.asBody())

    /**
     * Takes a session: the named one, or the next one waiting when [DeskAcceptRequest.sessionId] is
     * null. An empty queue is `1002`, which a workbench polling for work should read as "nothing
     * waiting"; being at capacity is `1205`, which is **not** retryable — finish a session first.
     *
     * 队列为空答 1002 而不是空成功；已满答 1205，解法是先结掉一个，不是重试。
     */
    public suspend fun accept(request: DeskAcceptRequest = DeskAcceptRequest()): DeskSession =
        connection.request("desk.accept", request.asBody())

    /**
     * Hands a session on — to a named agent, a skill queue, or back to its own queue. Build the
     * request with [DeskTransferRequest.agent], [DeskTransferRequest.skill] or
     * [DeskTransferRequest.queue]. Only an assigned session can be transferred (`1006` otherwise), and
     * only by its holder or a supervisor (`1103`).
     */
    public suspend fun transfer(request: DeskTransferRequest) {
        connection.execute("desk.transfer", request.asBody())
    }

    /**
     * Ends a session. Either side may. **Closing an already-closed session succeeds**, which is what
     * makes a retry after a timeout safe. Leaving [DeskCloseRequest.inviteRating] null still invites.
     */
    public suspend fun close(request: DeskCloseRequest) {
        connection.execute("desk.close", request.asBody())
    }

    /**
     * Sets this agent's availability and renews their heartbeat. **Call it on a timer**, not only when
     * the agent changes status: the roster drops an agent whose console has stopped saying anything.
     *
     * 要按心跳周期调用：名册会把不再说话的坐席回收并重排它的会话。
     */
    public suspend fun status(request: DeskStatusRequest) {
        connection.execute("desk.status", request.asBody())
    }

    /**
     * The queue as a supervisor watches it. Takes no arguments — it is the whole desk.
     * [DeskQueueView.avgFirstResponseSeconds] is null when nothing in the window is measurable.
     */
    public suspend fun queue(): DeskQueueView =
        connection.request("desk.queue", null)

    /**
     * The customer rates a finished session, 1–5, in reply to the 1807 notice. Accepted once, only
     * inside the rating window (`1006` otherwise); `1203` when ratings are switched off.
     */
    public suspend fun rate(request: DeskRateRequest) {
        connection.execute("desk.rate", request.asBody())
    }

    /**
     * The canned replies in this centre's phrasebook. Read-only here; editing is a console concern.
     *
     * **Pass your own member id as [DeskCannedRequest.ownerMemberId]** for "shared, plus mine":
     * leaving it null lists every member's personal entries, because the server does not narrow by
     * caller on this route.
     */
    public suspend fun canned(request: DeskCannedRequest = DeskCannedRequest()): List<DeskCannedReply> =
        connection.request("desk.canned", request.asBody())

    /**
     * Up to three model-written drafts for the session this agent holds. Nothing here reaches the
     * customer. `1203` when the tenant has configured no LLM; `1005` when the model did not answer.
     */
    public suspend fun suggest(request: DeskSuggestRequest): List<String> =
        connection.request("desk.suggest", request.asBody())
}
