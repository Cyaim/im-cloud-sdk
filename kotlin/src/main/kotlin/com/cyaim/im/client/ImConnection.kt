package com.cyaim.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.yield
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put
import kotlinx.serialization.serializer
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.random.Random
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * One multiplexed WebSocket to the gateway, with the reconnect behaviour a production client
 * actually needs.
 *
 * Reconnecting is not an optional extra here. A gateway holds sockets and therefore deploys
 * rarely, but when it does deploy — or when a node fails, or a phone changes network, or Android
 * drops the process into Doze — every client on that node reconnects at once. Without jittered
 * backoff those clients arrive as a synchronised thundering herd against the very service that
 * just came back up. See [Backoff] for why the jitter is *full* jitter.
 *
 * Everything runs inside one supervised scope. Cancel the scope you passed in, or call [close],
 * and the socket, the reconnect loop, the heartbeat and every in-flight request go with it — no
 * daemon thread outlives the object that owns it.
 *
 * 重连不是可选项：网关一次滚动更新会让该节点上所有客户端同时重连。没有带抖动的退避，
 * 这些客户端会变成打向刚恢复的服务的同步洪峰。
 */
public class ImConnection(
    private val options: ImOptions,
    private val socketFactory: ImSocketFactory = OkHttpSocketFactory(),
    /**
     * Parent context for everything this connection runs. Pass a `lifecycleScope`'s context to tie
     * the socket to a screen, or leave it empty for a process-lifetime client.
     */
    parentContext: CoroutineContext = EmptyCoroutineContext,
    /** Injectable so the jitter distribution can be asserted rather than eyeballed. */
    private val random: Random = Random.Default,
    private val clock: () -> Long = System::currentTimeMillis,
) : AutoCloseable {

    private val supervisor = SupervisorJob(parentContext[Job])

    // parentContext after Dispatchers.Default: a caller-supplied dispatcher (a test dispatcher,
    // say) wins, and the supervisor replaces whatever Job came with it so cancelling us never
    // cancels the caller.
    private val scope = CoroutineScope(
        Dispatchers.Default + parentContext + supervisor + CoroutineName("im-connection"),
    )

    private val _state = MutableStateFlow(ConnectionState.Idle)

    /** Current socket lifecycle. Bind it straight to a "connecting…" banner. */
    public val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private val _frames = MutableSharedFlow<ImFrame>(
        replay = 0,
        extraBufferCapacity = 64,
        onBufferOverflow = BufferOverflow.SUSPEND,
    )

    /**
     * Every server-initiated frame: pushes, plus the synthetic `conn.kick` this class emits when a
     * close reason says we were kicked.
     *
     * Hot, with no replay. A frame that arrives while nobody is collecting is dropped — exactly
     * like a push with no registered listener in the other SDKs — so subscribe before [connect].
     */
    public val frames: SharedFlow<ImFrame> = _frames.asSharedFlow()

    /**
     * Hand-off between the socket's reader thread and the coroutine world. Unbounded on purpose:
     * the reader thread must never block on application code, because a socket that stops being
     * read is a socket whose TCP window closes and whose heartbeat replies stop arriving — the
     * client would then diagnose its own slow collector as a dead server.
     */
    private val inbound = Channel<ImFrame>(Channel.UNLIMITED)

    private val pending = ConcurrentHashMap<String, CompletableDeferred<ImFrame>>()
    private val requestCounter = AtomicLong()

    /**
     * How many replies are still outstanding.
     *
     * Exposed for the conformance test that asserts a cancelled call leaves nothing behind: a
     * cancellation path that forgets to remove its entry is a leak that grows for the life of the
     * connection, and it is invisible from outside without this.
     */
    internal val pendingRequestCount: Int get() = pending.size

    /** Serialises `conn.reauth` so a burst of 1101s asks the host app for one token, not twenty. */
    private val reauthLock = Mutex()

    @Volatile
    private var tokenGeneration: Long = 0

    /** Conflated: a burst of foreground events collapses into one skipped backoff. */
    private val wake = Channel<Unit>(Channel.CONFLATED)

    private val started = AtomicBoolean(false)

    @Volatile
    private var socket: ImSocket? = null

    @Volatile
    private var token: String = options.token

    @Volatile
    private var heartbeatInterval: Duration = options.heartbeatInterval

    @Volatile
    private var closedByClient: Boolean = false

    @Volatile
    private var lastKick: KickEvent? = null

    init {
        scope.launch {
            for (frame in inbound) {
                _frames.emit(frame)
            }
        }
    }

    /**
     * Opens the socket and suspends until it is [ConnectionState.Open].
     *
     * Suspending until the connection is usable, rather than returning the moment the socket
     * object exists, is what `suspend` means in Kotlin — and it makes the obvious sequence
     * (`connect()` then `send()`) correct instead of a race. While the network is down this keeps
     * waiting and the reconnect loop keeps trying; wrap it in `withTimeout` if your UI needs to
     * give up. It throws only when the connection reaches a state it cannot come back from: a
     * terminal kick, or an expired token the host app declined to replace.
     */
    public suspend fun connect() {
        check(!closedByClient) { "This ImConnection is closed. Build a new one." }

        if (started.compareAndSet(false, true)) {
            scope.launch { reconnectLoop() }
        }

        state.first { it == ConnectionState.Open || it == ConnectionState.Closed }

        if (_state.value == ConnectionState.Closed) {
            val kick = lastKick
            throw ImException(
                code = if (kick?.reason == KickReason.TokenExpired) {
                    ImErrorCode.TokenExpired
                } else {
                    ImErrorCode.Unauthorized
                },
                message = "connection closed before it opened" +
                    (kick?.let { ": ${KickReason.ClosePrefix}${it.raw}" } ?: ""),
            )
        }
    }

    /**
     * Skips whatever backoff is currently being waited out and retries immediately.
     *
     * Call it when the app comes back to the foreground or the OS reports a usable network. On
     * Android this matters more than it looks: after Doze the process wakes with a dead socket and
     * a timer that may still have twenty seconds to run, and those twenty seconds are the ones the
     * user spends staring at a chat that has not loaded. The wake also resets the attempt counter,
     * because "the user just came back" is new information, not another failed retry.
     */
    public fun resumeNow() {
        wake.trySend(Unit)
    }

    /**
     * Terminal. Cancels the reconnect loop, the heartbeat and every in-flight request, and
     * releases the socket. A closed connection is not reusable — build a new one, which is also
     * what you want after a logout, since the token is different anyway.
     */
    override fun close() {
        if (closedByClient) return
        closedByClient = true

        _state.value = ConnectionState.Closed
        socket?.close(OkHttpSocketFactory.NORMAL_CLOSURE, "client-close")
        socket = null

        failAllPending(ImException(ImErrorCode.Timeout, "connection closed"))
        inbound.close()
        scope.cancel()
    }

    // ------------------------------------------------------------------- requests

    /**
     * Sends a request, waits for the reply that carries the same id, and decodes its `data`.
     *
     * Throws [ImException] for a transport failure, for any non-zero business code, and for a
     * request that goes unanswered past [ImOptions.requestTimeout]. Requests issued while the
     * socket is down fail immediately rather than queueing: a chat client that silently buffers
     * sends produces messages that arrive minutes late with no explanation, and the caller is the
     * only party that knows whether this particular send is still worth making.
     *
     * The one thing it retries is an expired token, and only once: `1101 TokenExpired` asks
     * [ImOptions.onTokenExpired] for a fresh one, renews it on this same socket with `conn.reauth`
     * and reissues the call. Nothing else is ever retried — see [ImException.isRetryable] for why
     * that decision belongs to the caller.
     */
    public suspend fun <T> request(
        target: String,
        body: JsonElement?,
        deserializer: DeserializationStrategy<T>,
    ): T {
        val generation = tokenGeneration
        val data = try {
            exchangeAndUnwrap(target, body)
        } catch (failure: ImException) {
            if (failure.code != ImErrorCode.TokenExpired || target == ReauthTarget) throw failure
            if (!renewTokenInPlace(generation)) throw failure
            exchangeAndUnwrap(target, body)
        }

        return ImJson.decodeFromJsonElement(deserializer, data.orEmptyObject())
    }

    /**
     * One round trip, with both layers of the envelope mapped onto one exception (CONTRACT.md §7.2).
     *
     * Two of the mappings are choices rather than deductions and are worth naming here, because
     * both look wrong until you have debugged the case they are for:
     *
     * - `status == 2` becomes **1008 UnsupportedOperation, not 1002 NotFound**. 1002 means "your
     *   group does not exist"; 1008 means "this deployment does not have this endpoint" — which is
     *   exactly what an SDK newer than a private-deployment server produces, and exactly the
     *   sentence the integrator needs to read.
     * - `status == 1` becomes **1000 InternalError** with the transport's own `msg`, because the
     *   endpoint threw before it could produce an `ApiResult` and any code in the body is noise.
     */
    private suspend fun exchangeAndUnwrap(target: String, body: JsonElement?): JsonElement? {
        val frame = exchange(target, body)

        when (frame.status) {
            0 -> Unit

            1 -> throw ImException(
                code = ImErrorCode.InternalError,
                message = frame.msg ?: "the endpoint threw",
                traceId = frame.body?.traceId,
                target = target,
            )

            2 -> throw ImException(
                code = ImErrorCode.UnsupportedOperation,
                message = "this deployment has no endpoint '$target'",
                traceId = frame.body?.traceId,
                target = target,
            )

            else -> throw ImException(
                code = ImErrorCode.InternalError,
                message = frame.msg ?: "unknown transport status ${frame.status}",
                traceId = frame.body?.traceId,
                target = target,
            )
        }

        val result = frame.body
        if (result == null || result.code != ImErrorCode.Ok) {
            throw ImException(
                code = result?.code ?: ImErrorCode.InternalError,
                message = result?.message ?: "request failed",
                traceId = result?.traceId,
                target = target,
            )
        }

        return result.data
    }

    /**
     * Renews the token on the socket we already have.
     *
     * Behind a mutex and a generation counter because a token expiring on a busy client fails
     * several in-flight requests at once, and asking the host app's token endpoint once per
     * request is how a mid-session expiry turns into a small DDoS of your own backend. The losers
     * of the race see the generation has moved and simply retry with the token the winner fetched.
     *
     * 令牌过期时往往有多个请求同时失败；没有这道闸门，每个失败的请求都会去问一次宿主 App 的
     * 发令牌接口，把一次过期变成对自家后端的一次小型冲击。
     */
    private suspend fun renewTokenInPlace(seenGeneration: Long): Boolean {
        val refresh = options.onTokenExpired ?: return false

        reauthLock.withLock {
            if (tokenGeneration != seenGeneration) return true

            val fresh = try {
                refresh()
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (failure: Throwable) {
                null
            }
            if (fresh.isNullOrBlank()) return false

            return try {
                exchangeAndUnwrap(
                    ReauthTarget,
                    ImJson.encodeToJsonElement(ReauthRequest.serializer(), ReauthRequest(fresh)),
                )
                token = fresh
                tokenGeneration = seenGeneration + 1
                true
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (failure: Throwable) {
                // The fresh token was refused too. Let the original failure stand and let the
                // close path deal with the session; retrying here would loop.
                false
            }
        }
    }

    /** [request] with the result type inferred, e.g. `request<SendMessageResult>("msg.send", body)`. */
    public suspend inline fun <reified T> request(target: String, body: JsonElement? = null): T =
        request(target, body, serializer())

    /**
     * A call whose reply carries nothing worth decoding. It still throws on failure — it is the
     * error, not the payload, that these endpoints return.
     */
    public suspend fun execute(target: String, body: JsonElement? = null) {
        request(target, body, JsonElement.serializer())
    }

    private suspend fun exchange(target: String, body: JsonElement?): ImFrame {
        val active = socket
        if (active == null || _state.value != ConnectionState.Open) {
            throw ImException(ImErrorCode.ServiceUnavailable, "not connected", target = target)
        }

        // Unique per connection, which is all the reply router needs; the counter also makes the
        // id sortable in a packet capture.
        val id = "c${requestCounter.incrementAndGet()}-${clock().toString(36)}"
        val deferred = CompletableDeferred<ImFrame>()
        pending[id] = deferred

        try {
            val payload = ImRequest(id = id, target = target, body = body ?: JsonObject(emptyMap()))
            if (!active.send(ImJson.encodeToString(ImRequest.serializer(), payload))) {
                throw ImException(ImErrorCode.ServiceUnavailable, "socket refused the frame", target = target)
            }
            return withTimeout(options.requestTimeout) { deferred.await() }
        } catch (timeout: TimeoutCancellationException) {
            // Only withTimeout's own cancellation is caught here. A CancellationException from
            // the caller's scope must keep propagating, or `withTimeout` around a whole screen
            // would come back as a timed-out request instead of a cancelled one.
            throw ImException(
                code = ImErrorCode.Timeout,
                message = "request timed out after ${options.requestTimeout}: $target",
                target = target,
                cause = timeout,
            )
        } finally {
            pending.remove(id)
        }
    }

    // ------------------------------------------------------------- connection loop

    private enum class Disposition { Retry, RefreshToken, Terminal }

    private class SessionOutcome(
        val opened: Boolean,
        val disposition: Disposition,
        val kick: KickEvent?,
    )

    private suspend fun reconnectLoop() {
        var attempt = 0

        while (currentCoroutineContext().isActive && !closedByClient) {
            _state.value = if (attempt == 0) ConnectionState.Connecting else ConnectionState.Reconnecting

            val outcome = runSession()
            if (outcome.opened) attempt = 0

            when (outcome.disposition) {
                Disposition.Terminal -> {
                    // Coming back would fail identically, forever. Stop, and tell the app why.
                    outcome.kick?.let { emitKick(it) }
                    _state.value = ConnectionState.Closed
                    return
                }

                Disposition.RefreshToken -> {
                    val fresh = try {
                        options.onTokenExpired?.invoke()
                    } catch (cancellation: CancellationException) {
                        throw cancellation
                    } catch (failure: Throwable) {
                        // The host app's token endpoint is down. Treat it as a refusal rather
                        // than looping on a token we know is expired.
                        null
                    }

                    if (fresh.isNullOrBlank()) {
                        emitKick(outcome.kick ?: KickEvent(KickReason.TokenExpired, "TokenExpired"))
                        _state.value = ConnectionState.Closed
                        return
                    }

                    token = fresh
                    attempt += 1
                    if (waitBeforeRetry(attempt)) attempt = 0
                }

                Disposition.Retry -> {
                    attempt += 1
                    if (waitBeforeRetry(attempt)) attempt = 0
                }
            }
        }

        if (closedByClient) _state.value = ConnectionState.Closed
    }

    /** Returns true when a [resumeNow] cut the wait short. */
    private suspend fun waitBeforeRetry(attempt: Int): Boolean {
        _state.value = ConnectionState.Reconnecting

        // Drop wakes that arrived while we were connected; only a wake during the wait counts.
        while (wake.tryReceive().isSuccess) {
            // discard
        }

        val wait = Backoff.nextDelay(attempt, random)
        if (wait <= Duration.ZERO) {
            // A zero draw is legal full jitter — reconnect at once, but yield first so a gateway
            // that refuses instantly cannot spin this loop.
            yield()
            return false
        }

        return withTimeoutOrNull(wait) { wake.receive() } != null
    }

    /** Opens one socket and suspends until it dies. Returns what the loop should do about it. */
    private suspend fun runSession(): SessionOutcome {
        val opened = CompletableDeferred<Unit>()
        val finished = CompletableDeferred<CloseInfo>()
        var everOpened = false

        // Also kept outside the deferred so the cleanup path can quote it even when this coroutine
        // is being cancelled and never gets to read the awaited value.
        var closeInfo: CloseInfo? = null

        val listener = object : ImSocketListener {
            override fun onOpen() {
                opened.complete(Unit)
            }

            override fun onText(text: String) {
                dispatch(text)
            }

            override fun onClosed(code: Int, reason: String?) {
                val info = CloseInfo(code, reason, null)
                closeInfo = info
                finished.complete(info)
            }

            override fun onFailure(cause: Throwable) {
                val info = CloseInfo(code = 0, reason = null, cause = cause)
                closeInfo = info
                finished.complete(info)
            }
        }

        val active = try {
            socketFactory.open(buildUrl(), listener)
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (failure: Throwable) {
            // A malformed URL or an exhausted thread pool. Nothing was opened, so this is a
            // network-class failure: back off and try again.
            return SessionOutcome(opened = false, disposition = Disposition.Retry, kick = null)
        }
        socket = active

        // Whichever happens first: the handshake completes, or the socket dies trying. Doing this
        // with `select` rather than a watcher coroutine keeps every state transition on this one
        // coroutine — a watcher could publish `Open` a moment after the session had already ended
        // and leave the app showing a connection that is not there.
        select<Unit> {
            opened.onAwait { }
            finished.onAwait { }
        }

        var heartbeatJob: Job? = null
        if (opened.isCompleted && !finished.isCompleted) {
            everOpened = true
            _state.value = ConnectionState.Open
            heartbeatJob = scope.launch { heartbeat(active) }
        }

        val info = try {
            finished.await()
        } finally {
            heartbeatJob?.cancel()
            socket = null
            // Whatever ended the session, release the socket: OkHttp keeps a reader thread and a
            // connection alive until someone says otherwise.
            active.cancel()
            // 1004 Timeout, not 1005 ServiceUnavailable: 1005 would claim the call never reached
            // the server, and we do not know that — the request may well have executed and had its
            // reply eaten by the close. 1004 is the honest answer, and it is the one that makes a
            // caller reach for clientMsgId idempotency instead of blindly resending. CONTRACT.md §7.2.
            // Callers waiting on a reply also get told why, not merely that: "connection lost
            // (code=4001, reason=im-kick:UserBanned)" ends a support thread that "connection lost"
            // would have started.
            failAllPending(
                ImException(
                    code = ImErrorCode.Timeout,
                    message = "connection lost" + (closeInfo?.describe() ?: ""),
                    cause = closeInfo?.cause,
                ),
            )
        }

        if (closedByClient) {
            return SessionOutcome(everOpened, Disposition.Retry, null)
        }

        // The close reason is the only signal that separates "you were kicked" from "the network
        // died", and the two need opposite responses.
        val kick = parseKick(info.reason)
        val disposition = when {
            kick == null -> Disposition.Retry
            kick.reason == KickReason.TokenExpired -> Disposition.RefreshToken
            kick.reason.isTerminal -> Disposition.Terminal
            // A reason from a newer server than this SDK. Reconnecting is the safe guess: at
            // worst we are told again, at best we were kicked for something transient.
            else -> Disposition.Retry
        }

        return SessionOutcome(everOpened, disposition, kick)
    }

    /** What the transport reported when the session ended: a close frame, or a thrown failure. */
    private class CloseInfo(val code: Int, val reason: String?, val cause: Throwable?) {
        fun describe(): String = buildString {
            append(" (code=").append(code)
            reason?.takeIf { it.isNotBlank() }?.let { append(", reason=").append(it) }
            cause?.let { append(", cause=").append(it::class.simpleName).append(": ").append(it.message) }
            append(")")
        }
    }

    /**
     * Beats on the server's cadence and forces the socket down when a beat fails.
     *
     * This is the half-open socket case: the phone changed network, or a middlebox dropped the
     * flow, and the OS still reports a perfectly good connection because nothing was ever sent to
     * prove otherwise. The failed beat is that proof.
     */
    private suspend fun heartbeat(active: ImSocket) {
        while (currentCoroutineContext().isActive) {
            delay(heartbeatInterval)

            val beat = try {
                request("conn.heartbeat", null, HeartbeatResult.serializer())
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (failure: Throwable) {
                // cancel(), not close(): a graceful close waits for a close frame from a peer that
                // is not answering, so on the exact connection we are trying to abandon it hangs
                // until OkHttp's own timeout — a minute of a user seeing "connected" and nothing
                // arriving. Cancelling surfaces onFailure now and the loop reconnects.
                active.cancel()
                return
            }

            // The server owns the cadence; adopt whatever it reports.
            if (beat.intervalSeconds > 0) {
                heartbeatInterval = beat.intervalSeconds.seconds
            }
        }
    }

    // ------------------------------------------------------------------- plumbing

    /** Runs on the transport's reader thread. Nothing in here may suspend or block. */
    private fun dispatch(text: String) {
        val frame = try {
            ImJson.decodeFromString(ImFrame.serializer(), text)
        } catch (failure: Exception) {
            // Unparseable frame. Dropping it beats killing the reader.
            return
        }

        val waiting = if (frame.id.isNotEmpty()) pending.remove(frame.id) else null
        if (waiting != null) {
            waiting.complete(frame)
            return
        }

        inbound.trySend(frame)
    }

    private fun buildUrl(): String {
        val base = options.endpoint.trimEnd('/')
        val query = buildList {
            add("appId" to options.appId)
            add("token" to token)
            add("deviceId" to options.deviceId)
            add("platform" to options.platform.code.toString())
            add("v" to "1")
            // Always send something: a ticket that carries a client version is one question the
            // support engineer does not have to ask. The app's own version wins when it set one.
            add("cv" to (options.clientVersion ?: ImSdk.packageVersion))
            options.language?.let { add("lang" to it) }
        }.joinToString("&") { (key, value) -> "$key=${URLEncoder.encode(value, "UTF-8")}" }

        return "$base${options.channel}?$query"
    }

    private fun parseKick(reason: String?): KickEvent? {
        val raw = reason ?: return null
        if (!raw.startsWith(KickReason.ClosePrefix)) return null
        val name = raw.removePrefix(KickReason.ClosePrefix).trim()
        return KickEvent(KickReason.fromWire(name), name)
    }

    /**
     * Publishes a kick the app would otherwise never see. The server usually pushes `conn.kick`
     * before closing, but a gateway that dies mid-kick, or a proxy that eats the last frame,
     * leaves the close reason as the only evidence — and "you were signed out on another device"
     * is not a message the app can afford to lose.
     */
    private fun emitKick(kick: KickEvent) {
        lastKick = kick
        inbound.trySend(
            ImFrame(
                id = "",
                target = PushTarget.Kick,
                status = 0,
                body = ImBody(
                    code = ImErrorCode.Ok,
                    serverTime = clock(),
                    data = buildJsonObject { put("reason", kick.raw) },
                ),
            ),
        )
    }

    private fun failAllPending(error: ImException) {
        for (id in pending.keys.toList()) {
            pending.remove(id)?.completeExceptionally(error)
        }
    }

    private companion object {
        /** The one target [request] must never try to reauth around, or it would recurse. */
        const val ReauthTarget = "conn.reauth"
    }
}
