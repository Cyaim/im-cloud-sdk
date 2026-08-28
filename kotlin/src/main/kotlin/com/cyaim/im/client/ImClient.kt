package com.cyaim.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.random.Random

/**
 * The client applications actually use.
 *
 * Beyond wrapping the 51 typed endpoints of tiers T0–T2, this owns the one thing every correct IM
 * client must do and most hand-rolled ones do not: it keeps two cursors per conversation, notices
 * when an arriving message skips a number, and pulls the missing range before delivering.
 *
 * ### The two cursors, and why there are two
 *
 * - **`deliveredSeq`** — the highest seq handed to *you* in this process. Memory only.
 * - **`committedSeq`** — the highest seq you have told the SDK you have **durably stored**, via
 *   [commit]. Written through to the [ImCursorStore] and reported to `conn.sync`.
 *
 * One cursor is not enough, and the bug that proves it is a silent one. `conn.sync` only reports a
 * gap for a conversation the client mentioned in `convSeqs`; a conversation it did not mention
 * produces no gap entry at all, and the client then adopts the server's current `maxSeq`. Every
 * message that arrived while the app was closed is now behind the cursor, will never be requested
 * and will never arrive — no error, no log line, nothing later that corrects it. A client that
 * reports "the highest seq I received" has the same hole one restart wide, because a message that
 * reached a callback and not a database is exactly what a crash loses.
 *
 * So: you [commit] after your own write succeeds, the SDK reports committed seqs and nothing else,
 * and on every connect it resets delivered back down to committed so the redelivered messages
 * actually reach you instead of being dropped as duplicates by a cursor that was too far ahead.
 * **Delivery is at-least-once. Be idempotent on `messageId`.**
 *
 * 两个游标：delivered 是投递到应用的最高 seq（仅内存），committed 是应用声明已落库的最高 seq
 * （持久化，也是上报给 conn.sync 的那个）。只有一个游标必然出现静默丢消息：
 * conn.sync 只对客户端报告过的会话给出缺口，没报告的会话直接采纳服务端 maxSeq，中间全丢。
 *
 * ### Per-conversation serialisation
 *
 * Each conversation gets its own inbox coroutine. That is not decoration: a repair is a network
 * round trip, and running it inline would stall every other conversation behind one slow
 * `msg.sync`, while running it concurrently with the same conversation's next message would let
 * the two race to deliver. Per-conversation serialisation is exactly the granularity the `seq`
 * invariant is defined at, and it is also what holds later live messages behind an in-flight
 * repair.
 */
public class ImClient(
    private val options: ImOptions,
    /**
     * Where cold-start cursors live. **Required, with no default** — see [ImCursorStore] for the
     * data-loss bug that a default would reintroduce. `ImCursorStore.inMemory()` is the explicit
     * way to opt out.
     */
    private val cursorStore: ImCursorStore,
    socketFactory: ImSocketFactory = OkHttpSocketFactory(),
    /** Cancel this context (a `lifecycleScope`, a session scope) and the whole client stops. */
    parentContext: CoroutineContext = EmptyCoroutineContext,
    /**
     * Where [ImCursorStore.load] and [ImCursorStore.save] run. Blocking I/O is expected of a store,
     * and it must not happen on the coroutine that pumps messages.
     */
    private val cursorStoreContext: CoroutineContext = Dispatchers.IO,
) : AutoCloseable {

    /** The transport underneath. Public for endpoints the typed surface does not cover yet. */
    public val connection: ImConnection = ImConnection(options, socketFactory, parentContext)

    private val logger: ImLogger = options.logger

    /**
     * The SDK's own runtime log: written here, read when the server asks this device for it.
     *
     * Tees into both [ImOptions.logger] and [ImOptions.logStore] — they answer different questions.
     * The sink is for the developer watching Logcat right now; the store is for the support
     * engineer reading a bundle from a customer's handset a week later.
     * 两边都写：sink 给此刻盯着 Logcat 的开发者，store 给一周后读那份包的支持工程师。
     */
    private val log: ImLog = ImLog(options.logStore, options.logger)

    private val supervisor = SupervisorJob(parentContext[Job])
    private val scope = CoroutineScope(
        Dispatchers.Default + parentContext + supervisor + CoroutineName("im-client"),
    )

    private val cursors = CursorBook()
    private val inboxes = ConcurrentHashMap<String, Channel<InboxCommand>>()

    private val writer = CursorWriter(
        store = cursorStore,
        scope = scope,
        storeContext = cursorStoreContext,
        flushInterval = options.cursorFlushInterval,
        logger = logger,
        snapshot = { cursors.snapshot(options.cursorScope().key) },
    )

    private val loadLock = Mutex()

    @Volatile
    private var cursorsLoaded = false

    // ------------------------------------------------------------------ typed surface

    /** `conn.*` — heartbeat, reauth, resume. Mostly driven for you. */
    public val conn: ConnApi = ConnApi(connection)

    /** `msg.*` — send, sync, history, recall, edit, delete, forward, react, receipt, typing. */
    public val msg: MsgApi = MsgApi(
        connection = connection,
        newClientMsgId = ::newClientMsgId,
        onSent = { result ->
            // Our own message advances the *delivered* cursor and nothing else. Routing it through
            // the conversation's inbox rather than writing here keeps every mutation on one
            // coroutine, and lets the inbox notice if our send landed at a seq beyond what we have
            // seen — that hole is real, and silently adopting the higher number would hide it
            // until the next reconnect. It deliberately does not commit: the application has not
            // stored this message yet, and only the application knows when it has.
            if (result.conversationId.isNotEmpty() && result.seq > 0) {
                inboxFor(result.conversationId).send(InboxCommand.Sent(result.seq))
            }
        },
    )

    /** `conv.*` — the conversation list and the per-user state on it. */
    public val conv: ConvApi = ConvApi(connection)

    /** `user.*` — profiles and presence. */
    public val user: UserApi = UserApi(connection)

    /** `friend.*` — contacts, requests, blocklist. */
    public val friend: FriendApi = FriendApi(connection)

    /** `group.*` — the ten calls a group chat needs. */
    public val group: GroupApi = GroupApi(connection)

    /** `media.*` — upload tickets and signed download links. */
    public val media: MediaApi = MediaApi(connection)

    /** `push.*` — offline notifications. Read [PushApi] before you ship an Android build. */
    public val push: PushApi = PushApi(connection, logger)

    /** `moderation.*` — reporting a user or a message. The other half of `friend.block`. */
    public val moderation: ModerationApi = ModerationApi(connection)

    /** `diag.*` — this device's half of troubleshooting. Driven by the client; see [DiagApi]. */
    public val diag: DiagApi = DiagApi(connection)

    private val deviceLogs: ImDeviceLogs = ImDeviceLogs(diag, log, options.deviceId)

    // ------------------------------------------------------------------------- events

    private val _messages = MutableSharedFlow<ImMessage>(replay = 0, extraBufferCapacity = 64)

    /**
     * Every message, in `seq` order per conversation, gaps already repaired.
     *
     * Hot and without replay, so start collecting before [connect]: a message emitted while
     * nothing is subscribed is dropped from the flow — the same thing that happens to a push with
     * no registered listener in the other SDKs. Keep the collector cheap; it applies back-pressure
     * all the way to the socket's queue.
     *
     * Call [commit] once the message is in your own store. Until you do, the SDK assumes it is not
     * durable and will deliver it again after a reconnect.
     */
    public val messages: SharedFlow<ImMessage> = _messages.asSharedFlow()

    private val _conversationNeedsReload = MutableSharedFlow<String>(replay = 0, extraBufferCapacity = 16)

    /**
     * Conversations that fell further behind than [ImOptions.maxAutoRepairSeq] and were skipped
     * forward instead of backfilled. Reload these from `msg.history`.
     *
     * Both halves of that are load-bearing: the cursors *are* advanced past the hole, so later
     * messages are not mistaken for another gap and the same declined range is not re-requested
     * forever — and you *are* told, because a hole nobody is told about is the same defect as a
     * hole nobody repairs.
     */
    public val conversationNeedsReload: SharedFlow<String> = _conversationNeedsReload.asSharedFlow()

    /** The name this flow carried before it was aligned across the five SDKs. */
    @Deprecated(
        "Renamed to conversationNeedsReload to match the other SDKs",
        ReplaceWith("conversationNeedsReload"),
    )
    public val staleConversations: SharedFlow<String> get() = conversationNeedsReload

    private val _cursorStoreState = MutableStateFlow<ImCursorStoreState>(ImCursorStoreState.NotLoaded)

    /**
     * What happened when the cursor store was read, and therefore whether this session's cursors
     * can be trusted.
     *
     * Worth binding in a debug build at least. [ImCursorStoreState.Failed] means the SDK is
     * refusing to adopt or advance anything for the rest of the session, which is the safe
     * behaviour but not a state you want to ship in silently; and
     * `Loaded(conversations = 0, persistent = false)` is the in-memory store telling you every
     * cold start will drop whatever arrived while the process was down.
     */
    public val cursorStoreState: StateFlow<ImCursorStoreState> = _cursorStoreState.asStateFlow()

    /**
     * Kicks, from either the server's `conn.kick` push or the close reason the SDK decodes when
     * the push never arrived. A terminal kick is also the moment [state] goes
     * [ConnectionState.Closed] for good.
     */
    public val kicks: Flow<KickEvent> = connection.frames
        .filter { it.target == PushTarget.Kick }
        .map { frame ->
            val raw = runCatching {
                frame.body?.data?.jsonObject?.get("reason")?.jsonPrimitive?.content
            }.getOrNull().orEmpty()
            KickEvent(KickReason.fromWire(raw), raw)
        }

    /** Socket lifecycle. */
    public val state: StateFlow<ConnectionState> get() = connection.state

    private sealed interface InboxCommand {
        /** A message off the wire, to be gap-checked and delivered. */
        data class Arrived(val message: ImMessage) : InboxCommand

        /** Backfill an inclusive range, then deliver it in order. */
        data class Repair(val fromSeq: Long, val toSeq: Long) : InboxCommand

        /**
         * First sight of a conversation on `conn.sync`: take the server's position for both
         * cursors rather than replaying a history no UI has ever shown. [done] is completed once
         * the adoption is durable, because the run must not request another page before then.
         */
        data class Adopt(val seq: Long, val done: CompletableDeferred<Unit>) : InboxCommand

        /** Our own send landed at this seq. Moves `delivered` only — see [commit]. */
        data class Sent(val seq: Long) : InboxCommand
    }

    init {
        // UNDISPATCHED so the subscription to `frames` is registered inside this constructor. A
        // dispatched launch would subscribe a moment later, and a push that landed in that moment
        // would be dropped by the hot flow — an intermittent lost message is not a bug anyone
        // enjoys chasing.
        // A log request arrives inside evt.system rather than on a target of its own, so a client
        // built before this feature existed receives an action it does not recognise and ignores
        // it. A new target would instead be silently dropped by every existing build, and there
        // would be no way to tell that apart from a device that was offline (ADR-003).
        // 走 evt.system 里的一个 action 而不是新事件名：旧版本收到不认识的 action 会忽略它，那是对的。
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            connection.frames
                .filter { it.target == PushTarget.System }
                .collect { frame -> deviceLogs.onSystemEvent(frame.body?.data) }
        }

        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            connection.frames
                .filter { it.target == PushTarget.Message }
                .collect { frame ->
                    val message = decodeMessage(frame) ?: return@collect
                    inboxFor(message.conversationId).send(InboxCommand.Arrived(message))
                }
        }

        // collectLatest, so a reconnect that happens mid-resume cancels the stale resume instead
        // of racing a second one against it. A cancelled run leaves `conversationCursor` exactly
        // where it was, which is the whole point of §5.6 step 8.
        scope.launch(start = CoroutineStart.UNDISPATCHED) {
            connection.state.collectLatest { state ->
                if (state != ConnectionState.Open) return@collectLatest
                try {
                    coroutineScope {
                        // Push registration runs alongside the resume rather than in front of it:
                        // it is not allowed to delay gap repair by a request timeout, and gap
                        // repair is not allowed to delay it either.
                        launch { push.registerOnConnect(options.autoRegisterPushToken) }

                        // Least urgent of the three and last in the list: it must never delay gap
                        // repair, and its failure is logged rather than raised — a device that
                        // cannot answer a log request is still a device that can chat.
                        // 三件里最不紧急：绝不能拖慢补洞，失败只记录不抛出。
                        launch { deviceLogs.check() }
                        resume()
                    }
                } catch (cancellation: CancellationException) {
                    // A reconnect, or close(). Either way the next Open runs a fresh resume, and
                    // the cursors are exactly where the interrupted run left them.
                    throw cancellation
                } catch (failure: Throwable) {
                    // Nothing is waiting on this coroutine, so an escaped exception would reach
                    // the thread's default handler and kill nothing useful while looking alarming.
                    logger.warn("post-connect resume did not complete", failure)
                }
            }
        }
    }

    /** Opens the socket and suspends until it is usable. See [ImConnection.connect]. */
    public suspend fun connect() {
        connection.connect()
    }

    /**
     * Retries immediately instead of waiting out the current backoff. Call it from `ON_START` and
     * from your network callback; see [ImConnection.resumeNow].
     */
    public fun resumeNow() {
        connection.resumeNow()
    }

    /**
     * Unregisters the push token and then closes, in that order.
     *
     * The order is the entire point. After the socket is gone there is no authenticated channel
     * and the token cannot be removed at all, so the device keeps receiving notifications for an
     * account that has logged out — and only the tenant backend can then clean it up, with
     * `DELETE /v1/users/{userId}/push-tokens/{deviceId}`. Disconnecting never unregisters by
     * itself; a dead socket is precisely the state offline push exists to serve.
     *
     * Cursors are flushed but **not cleared**. Clear them yourself if and only if you also clear
     * the local messages — the two have one lifetime, and keeping one without the other is either
     * an empty conversation that never refills or a full re-download.
     *
     * 先注销推送再断开：socket 一断就再没有可鉴权的通道能删这个 token。
     */
    public suspend fun logout() {
        if (push.hasToken() && connection.state.value == ConnectionState.Open) {
            try {
                push.unregister()
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (failure: Throwable) {
                logger.warn(
                    "push.unregister failed on logout; this device may keep receiving " +
                        "notifications until the tenant backend removes the token",
                    failure,
                )
            }
        }
        close()
    }

    /** Terminal: flushes cursors, stops the socket, the reconnect loop and every inbox. Not reusable. */
    override fun close() {
        connection.close()
        // Blocking, on the caller's thread, and deliberately: the scope is about to be cancelled,
        // so there is nowhere to put an asynchronous write, and this is the one path where the
        // next thing that happens is a cold start.
        writer.flushBlocking()
        inboxes.values.forEach { it.close() }
        inboxes.clear()
        scope.cancel()
    }

    // ------------------------------------------------------------------------ cursors

    /**
     * Tells the SDK that everything up to [seq] in this conversation is **durably stored on this
     * device**. Call it after your own write returns, not when the message reaches your UI.
     *
     * Monotonic: a lower seq is ignored rather than an error, which is what lets you re-derive
     * cursors from your own database and replay them in any order — the correct recovery when
     * [cursorStoreState] reports a failed load.
     *
     * The SDK will never advance this on its own from the fact that a collector returned. A
     * callback returning means the message reached memory, which is exactly the state a crash
     * loses, and inferring durability from it is how you get a cursor that is confidently wrong.
     * (The one exception is adoption — a conversation seen for the first time, where there is
     * nothing for the application to have stored.)
     *
     * 在你自己的写入成功之后调用，而不是在 UI 收到消息时。回调返回只说明消息进了内存，
     * 而内存正是崩溃会丢掉的东西。
     */
    public suspend fun commit(conversationId: String, seq: Long) {
        ensureCursorsLoaded()
        if (cursors.commit(conversationId, seq)) writer.schedule()
    }

    /** The committed cursor for one conversation, or 0. */
    public suspend fun committedSeq(conversationId: String): Long {
        ensureCursorsLoaded()
        return cursors.committedOf(conversationId)
    }

    /**
     * Writes any debounced commits out now.
     *
     * Call it on the platform's background/suspend signal — `ON_STOP`, a service shutdown hook.
     * The SDK also flushes before every `conn.sync` and on [close], and never debounces an
     * adoption, so this is a safety net rather than a requirement.
     */
    public suspend fun flushCursors() {
        writer.flushNow()
    }

    // ---------------------------------------------------------------------- raw events

    /** Raw frames for one push target, for events with no typed wrapper here yet. */
    public fun frames(target: String): Flow<ImFrame> = connection.frames.filter { it.target == target }

    /**
     * Decoded payloads for one push target, e.g.
     * `events<TypingEvent>(PushTarget.Typing)`.
     */
    public inline fun <reified T> events(target: String): Flow<T> =
        connection.frames
            .filter { it.target == target }
            .map { frame -> ImJson.decodeFromJsonElement<T>(frame.body?.data ?: JsonObject(emptyMap())) }

    /**
     * Escape hatch for any endpoint the typed surface does not cover yet — tiers T3 and T4 today.
     *
     * It shares one code path with every typed method, so timeouts, cancellation, reauth and error
     * mapping behave identically. It deliberately does **not** participate in cursor logic:
     * `invoke("msg.sync", …)` returns messages and moves nothing.
     *
     * ```kotlin
     * // group.setRole is tier T3 and not typed yet:
     * im.invoke<Unit>("group.setRole", buildJsonObject {
     *     put("groupId", groupId); put("userId", userId); put("role", GroupRole.Admin.code)
     * })
     * ```
     */
    public suspend inline fun <reified T> invoke(target: String, body: JsonElement? = null): T =
        connection.request(target, body)

    // ---------------------------------------------------------------- frozen shorthands

    /**
     * Sends a message.
     *
     * @suppress kept because it appears in every README and sample; it delegates to [msg].
     */
    @Deprecated("Use im.msg.send(request)", ReplaceWith("msg.send(request)"), DeprecationLevel.WARNING)
    public suspend fun send(request: SendRequest): SendMessageResult = msg.send(request)

    /** Shorthand for a plain text message. */
    @Deprecated(
        "Use im.msg.send(SendRequest(target, textContent(text)))",
        ReplaceWith("msg.send(SendRequest(target = target, content = textContent(text)))"),
        DeprecationLevel.WARNING,
    )
    public suspend fun sendText(target: SendTarget, text: String): SendMessageResult =
        msg.send(SendRequest(target = target, content = textContent(text), contentType = MessageContentType.Text))

    /** Pages backwards through history. Omit [beforeSeq] to start at the newest message. */
    @Deprecated("Use im.msg.history(HistoryRequest(...))", ReplaceWith("msg.history(HistoryRequest(conversationId, beforeSeq, limit))"))
    public suspend fun history(conversationId: String, beforeSeq: Long? = null, limit: Int = 20): Page<ImMessage> =
        msg.history(HistoryRequest(conversationId, beforeSeq, limit))

    @Deprecated("Use im.msg.recall(RecallMessageRequest(...))", ReplaceWith("msg.recall(RecallMessageRequest(conversationId, messageId, reason))"))
    public suspend fun recall(conversationId: String, messageId: Long, reason: String? = null): Unit =
        msg.recall(RecallMessageRequest(conversationId, messageId, reason))

    @Deprecated("Use im.msg.react(ReactRequest(...))", ReplaceWith("msg.react(ReactRequest(conversationId, messageId, emoji, add))"))
    public suspend fun react(conversationId: String, messageId: Long, emoji: String, add: Boolean = true): Unit =
        msg.react(ReactRequest(conversationId, messageId, emoji, add))

    @Deprecated("Use im.msg.typing(conversationId, typing)", ReplaceWith("msg.typing(conversationId, typing)"))
    public suspend fun setTyping(conversationId: String, typing: Boolean = true): Unit =
        msg.typing(conversationId, typing)

    @Deprecated("Use im.conv.list(ListConversationsRequest(...))", ReplaceWith("conv.list(ListConversationsRequest(updatedAfter, cursor, limit))"))
    public suspend fun conversations(updatedAfter: Long = 0, cursor: String? = null, limit: Int = 50): Page<ConversationView> =
        conv.list(ListConversationsRequest(updatedAfter, cursor, limit))

    @Deprecated("Use im.conv.read(conversationId, readSeq)", ReplaceWith("conv.read(conversationId, readSeq)"))
    public suspend fun markRead(conversationId: String, readSeq: Long): Unit = conv.read(conversationId, readSeq)

    @Deprecated("Use im.conv.unreadTotal()", ReplaceWith("conv.unreadTotal()"))
    public suspend fun totalUnread(): Long = conv.unreadTotal()

    // ----------------------------------------------------------------------- internals

    private fun inboxFor(conversationId: String): SendChannel<InboxCommand> =
        inboxes.computeIfAbsent(conversationId) { id ->
            // Unbounded: the producer is the socket's dispatch coroutine, and dropping a command
            // here would mean dropping the very gap-repair this class exists to perform.
            val channel = Channel<InboxCommand>(Channel.UNLIMITED)
            scope.launch {
                for (command in channel) {
                    try {
                        handle(id, command)
                    } catch (cancellation: CancellationException) {
                        throw cancellation
                    } catch (failure: Throwable) {
                        // One malformed message must not take this conversation's pump down with
                        // it; the next arrival re-detects any gap it left behind.
                        logger.warn("inbox for conversation $id failed to handle a command", failure)
                    } finally {
                        if (command is InboxCommand.Adopt) command.done.complete(Unit)
                    }
                }
            }
            channel
        }

    private suspend fun handle(conversationId: String, command: InboxCommand) {
        when (command) {
            is InboxCommand.Arrived -> deliver(conversationId, command.message)
            is InboxCommand.Repair -> repair(conversationId, command.fromSeq, command.toSeq)
            is InboxCommand.Adopt -> adopt(conversationId, command.seq)
            is InboxCommand.Sent -> sent(conversationId, command.seq)
        }
    }

    /** CONTRACT.md §5.7, in order. */
    private suspend fun deliver(conversationId: String, message: ImMessage) {
        // seq 0 means the message was never persisted (typing, presence, chat-room traffic):
        // deliver it straight through and never let it touch a cursor.
        if (message.seq == 0L) {
            _messages.emit(message)
            return
        }

        val delivered = cursors.deliveredOf(conversationId)

        // Already seen. Duplicates are routine after a reconnect replay and must be silent.
        if (message.seq <= delivered) return

        if (delivered > 0L && message.seq > delivered + 1L) {
            // A gap. Repair it before delivering this message, so the application never sees a
            // conversation jump forward and then fill in behind it.
            repair(conversationId, delivered + 1L, message.seq - 1L)
        }

        if (message.seq > cursors.deliveredOf(conversationId)) {
            cursors.markDelivered(conversationId, message.seq)
            _messages.emit(message)
        }
    }

    /**
     * Fetches `[fromSeq, toSeq]` and delivers it in order. Only ever called from an inbox, which
     * is what stops two repairs for one conversation from running at once and holds later live
     * messages behind this one.
     *
     * The loop is not optional. `msg.sync` clamps its limit to 500 server-side and reports
     * `hasMore`, so a 900-seq range asked for in one call silently returns 500 and an SDK that
     * ignores `hasMore` leaves the other 400 as a permanent hole — the exact failure the repair
     * was for. And `hasMore` is computed on the raw window *before* messages hidden from this
     * reader are filtered out, so a page can be short, or empty, while more of the range remains:
     * loop on `hasMore`, never on `messages.size`.
     *
     * 补洞必须循环：服务端把 limit 夹到 500 并用 hasMore 告知还有剩余，
     * 而 hasMore 是在过滤本用户不可见消息之前算的，所以"这一页很短"不代表拉完了。
     */
    private suspend fun repair(conversationId: String, fromSeq: Long, toSeq: Long) {
        val span = toSeq - fromSeq + 1
        if (span <= 0) return

        if (span > options.maxAutoRepairSeq) {
            skipForward(conversationId, toSeq, span)
            return
        }

        // One iteration per full page, plus slack for pages the server shortened by hiding rows.
        val cap = ((span + MsgSyncMaxLimit - 1) / MsgSyncMaxLimit).toInt() + RepairIterationSlack
        var cursor = fromSeq
        var iterations = 0

        while (cursor <= toSeq) {
            if (++iterations > cap) {
                // A server that keeps saying hasMore without making progress must not spin a
                // client forever. Fall through to the oversized-gap behaviour: cursor forward,
                // and tell the application to reload.
                logger.warn("repair of $conversationId [$fromSeq..$toSeq] exceeded $cap pages; reloading instead")
                skipForward(conversationId, toSeq, span)
                return
            }

            val page = try {
                msg.sync(
                    SyncMessagesRequest(
                        conversationId = conversationId,
                        fromSeq = cursor,
                        toSeq = toSeq,
                        limit = minOf(toSeq - cursor + 1, MsgSyncMaxLimit).toInt(),
                        ascending = true,
                    ),
                )
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (failure: Throwable) {
                // The repair failed; the caller still delivers what arrived rather than stalling
                // the conversation. The next message detects the gap again and retries. Cursors
                // are untouched, so nothing is lost by giving up here.
                logger.warn("repair of $conversationId [$cursor..$toSeq] failed", failure)
                return
            }

            for (message in page.messages.sortedBy { it.seq }) {
                if (message.seq > cursors.deliveredOf(conversationId)) {
                    cursors.markDelivered(conversationId, message.seq)
                    _messages.emit(message)
                }
            }

            if (!page.hasMore) return

            val next = (page.messages.maxOfOrNull { it.seq } ?: page.maxSeq) + 1
            if (next <= cursor) {
                // hasMore with nothing above where we already are. Retrying the identical window
                // would loop; leave it for the next gap detection, which has fresh information.
                logger.warn("repair of $conversationId made no progress at seq $cursor; giving up for now")
                return
            }
            cursor = next
        }
    }

    /**
     * A gap too wide to backfill. CONTRACT.md §5.6 step 5, and **both halves are mandatory**:
     * skipping the cursor advance makes every later message look like a gap and re-request a range
     * we have already declined, and skipping the event leaves a hole in the UI that nothing will
     * ever mention.
     */
    private suspend fun skipForward(conversationId: String, toSeq: Long, span: Long) {
        cursors.markDelivered(conversationId, toSeq)
        if (cursors.commit(conversationId, toSeq)) writer.schedule()
        logger.info("$conversationId is $span messages behind; skipping to $toSeq and asking for a reload")
        _conversationNeedsReload.emit(conversationId)
    }

    /**
     * First sight of a conversation: take the server's position for both cursors rather than
     * replaying a history that no UI has ever shown.
     *
     * The `delivered > 0` guard is the case where this is not really first sight — a live message
     * arrived for this conversation before `conn.sync` returned — and there the honest answer is a
     * repair, not a skip.
     *
     * **The store write is not debounced.** If an adoption is lost, the next cold start sees no
     * entry, adopts a *newer* `maxSeq`, and silently drops everything in between: the original bug,
     * re-created by the optimisation.
     */
    private suspend fun adopt(conversationId: String, seq: Long) {
        val delivered = cursors.deliveredOf(conversationId)
        if (delivered > 0L && seq > delivered + 1L) {
            repair(conversationId, delivered + 1L, seq - 1L)
        }
        cursors.markDelivered(conversationId, seq)
        cursors.commit(conversationId, seq)
        writer.markDirty()
        writer.flushNow()
    }

    /** Our own send landed. Moves `delivered`; committing is the application's call. */
    private suspend fun sent(conversationId: String, seq: Long) {
        val delivered = cursors.deliveredOf(conversationId)
        if (delivered > 0L && seq > delivered + 1L) {
            repair(conversationId, delivered + 1L, seq - 1L)
        }
        cursors.markDelivered(conversationId, seq)
    }

    /**
     * Runs after every (re)connect: asks the server what changed while we were away and repairs
     * each conversation whose seq has moved past ours.
     *
     * The server does the diffing. A cold device that has been offline for a week cannot usefully
     * work out what it missed by pulling the whole conversation list and comparing.
     *
     * Two things here are easy to get wrong and are silent when you do:
     *
     * - **It pages.** `conn.sync` returns at most 200 conversations at a time. A user with more
     *   than that gets gaps reported only for the first page unless the client keeps asking.
     * - **`conversationCursor` moves only when the whole run finished.** The list is sorted by
     *   `updatedAt` descending, so page 1 holds the newest timestamp: a client that takes the
     *   maximum from page 1 and stops has pushed the cursor past every conversation on pages
     *   2…N, and the server filters on `updatedAt > conversationCursor` and will never return
     *   them again. Re-reading a page is free; skipping one is permanent.
     *
     * 分页与游标推进的时机都会静默出错：会话列表按 updatedAt 倒序，只取第 1 页的最大值就等于
     * 把游标推过了第 2…N 页的全部会话，服务端从此不会再返回它们。重读一页是免费的，跳过一页是永久的。
     */
    private suspend fun resume() {
        ensureCursorsLoaded()

        // §5.2 rule 2. Without this the repaired messages are dropped as duplicates by the very
        // cursor that was too far ahead, and the repair delivers nothing at all.
        cursors.resetDeliveredToCommitted()

        var cursor: String? = null
        var newestUpdatedAt = 0L
        var pages = 0
        var completed = false

        while (true) {
            // Everything committed so far — adoptions included — is on disk before we ask again.
            writer.flushNow()

            val page = try {
                conn.sync(
                    ResumeRequest(
                        convSeqs = cursors.committedSeqs(),
                        conversationCursor = cursors.conversationCursor,
                        cursor = cursor,
                        limit = ResumePageSize,
                    ),
                )
            } catch (cancellation: CancellationException) {
                // A reconnect cancelled us mid-run. Leave conversationCursor alone and start over.
                throw cancellation
            } catch (failure: Throwable) {
                logger.warn("conn.sync failed; leaving cursors untouched and waiting for the next connect", failure)
                return
            }

            val maxSeqByConversation = page.conversations.associate { it.conversationId to it.maxSeq }
            val adoptions = ArrayList<CompletableDeferred<Unit>>()

            // Repairs are queued before adoptions. Against the real server the two sets are
            // disjoint — a gap is only ever reported for a conversation we put in `convSeqs`, so
            // it is by definition not first sight — but if they ever overlap, an adoption that ran
            // first would set the cursor to `maxSeq` and the backfill behind it would deliver
            // nothing at all. The inbox is FIFO, so queue order is execution order.
            for ((conversationId, fromSeq) in page.gapsFrom) {
                val toSeq = maxSeqByConversation[conversationId] ?: continue
                if (toSeq - fromSeq + 1 <= 0) continue
                inboxFor(conversationId).send(InboxCommand.Repair(fromSeq, toSeq))
            }

            for (conversation in page.conversations) {
                newestUpdatedAt = maxOf(newestUpdatedAt, conversation.updatedAt)
                if (cursors.frozen || cursors.isKnown(conversation.conversationId)) continue
                val done = CompletableDeferred<Unit>()
                adoptions += done
                inboxFor(conversation.conversationId).send(InboxCommand.Adopt(conversation.maxSeq, done))
            }

            // Adoptions are durable before the next page is asked for; repairs are not waited on,
            // because they are the slow part and each conversation's inbox already serialises it.
            adoptions.forEach { it.await() }

            if (!page.hasMore) {
                completed = true
                break
            }

            val next = page.nextCursor
            if (next == null) {
                logger.warn("conn.sync reported hasMore with no nextCursor; stopping this run")
                break
            }
            cursor = next

            if (++pages >= MaxResumePages) {
                logger.warn("conn.sync exceeded $MaxResumePages pages; stopping this run")
                break
            }
        }

        writer.flushNow()

        // §5.6 step 8. Only a run that reached `hasMore == false` may move this.
        if (completed && cursors.advanceConversationCursor(newestUpdatedAt)) {
            writer.schedule()
        }
    }

    /**
     * Reads the cursor store, once, before the first `conn.sync`.
     *
     * A load that throws is **not** treated as a fresh install. The two are indistinguishable to
     * the adoption branch, and adopting on a failed load destroys history that is sitting intact
     * in the application's own database. So the failure is surfaced on [cursorStoreState], nothing
     * is adopted, and no cursor advances for the rest of the session — leaving the application to
     * decide between re-deriving its cursors through [commit] and accepting a re-download.
     */
    private suspend fun ensureCursorsLoaded() {
        if (cursorsLoaded) return
        loadLock.withLock {
            if (cursorsLoaded) return

            val scopeKey = options.cursorScope().key
            // Not declared by the store: the SDK recognises its own in-memory store by type, so a
            // custom store cannot announce itself volatile and switch this warning off.
            val persistent = cursorStore !is InMemoryCursorStore
            try {
                val snapshot = withContext(cursorStoreContext) { cursorStore.load() }

                if (snapshot.scope != null && snapshot.scope != scopeKey) {
                    // A different (host, appId, userId). Not corruption, and not this account's
                    // data: start clean rather than hand one user another's cursors.
                    logger.warn(
                        "cursor store holds cursors for '${snapshot.scope}' but this session is " +
                            "'$scopeKey'; starting clean. Use one store per account.",
                    )
                    cursors.restore(ImCursorSnapshot())
                    _cursorStoreState.value = ImCursorStoreState.Loaded(0, 0, persistent)
                } else {
                    cursors.restore(snapshot)
                    _cursorStoreState.value = ImCursorStoreState.Loaded(
                        conversations = snapshot.convSeqs.size,
                        conversationCursor = snapshot.conversationCursor,
                        persistent = persistent,
                    )
                }

                if (!persistent) {
                    logger.warn(
                        "ImCursorStore.inMemory(): cursors do not survive this process. Every cold " +
                            "start will adopt the server's position and silently drop whatever " +
                            "arrived while the app was closed (CONTRACT.md §5.3).",
                    )
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (failure: Throwable) {
                cursors.freeze()
                _cursorStoreState.value = ImCursorStoreState.Failed(failure)
                logger.error(
                    "cursor store load failed. Refusing to adopt any conversation or advance any " +
                        "cursor this session, because a failed load and a fresh install are " +
                        "indistinguishable and adopting would destroy history you still hold " +
                        "(CONTRACT.md §5.8). Re-derive cursors with commit(), or rebuild the " +
                        "client with a working store.",
                    failure,
                )
            }
            cursorsLoaded = true
        }
    }

    private fun decodeMessage(frame: ImFrame): ImMessage? = try {
        ImJson.decodeFromJsonElement(ImMessage.serializer(), frame.body?.data.orEmptyObject())
    } catch (failure: Exception) {
        logger.warn("dropped an undecodable evt.message frame", failure)
        null
    }

    /**
     * Time prefix plus randomness: sortable in a log, and unique enough that two devices of the
     * same user sending in the same millisecond cannot collide on the idempotency key.
     */
    private fun newClientMsgId(): String {
        val stamp = System.currentTimeMillis().toString(36)
        val noise = Random.nextLong(1L shl 48).toString(36)
        return "$stamp-$noise"
    }

    private companion object {
        /** Conversations per `conn.sync` page: the server's own default, and its clamp ceiling. */
        const val ResumePageSize = 200

        /** `MessageService.SyncAsync` clamps to this. Asking for more silently returns 500. */
        const val MsgSyncMaxLimit = 500L

        /** Extra `msg.sync` calls allowed beyond the arithmetic minimum, for hidden-row shortfalls. */
        const val RepairIterationSlack = 4

        /** 200 pages × 200 conversations. Past that, something is wrong with the server, not us. */
        const val MaxResumePages = 200
    }
}
