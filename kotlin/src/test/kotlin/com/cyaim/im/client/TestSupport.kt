@file:OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import java.io.IOException
import kotlin.random.Random

/**
 * A gateway that never touches a socket.
 *
 * The reconnect, kick, cursor and gap-repair rules are the whole point of this SDK, and all four
 * are timing-dependent. Driving them through a real server would make the tests slow, flaky and
 * unable to assert what happens after thirty seconds of backoff; driving them through this, on the
 * coroutines test scheduler, makes those assertions exact and instant.
 */
internal class FakeGateway : ImSocketFactory {
    val urls = mutableListOf<String>()
    val sockets = mutableListOf<FakeSocket>()

    /** Optional auto-responder: return a frame to reply with, or null to leave the request hanging. */
    var onRequest: ((JsonObject) -> JsonObject?)? = null

    val latest: FakeSocket get() = sockets.last()

    /** Every frame the client sent across every socket, in order. */
    val allSent: List<JsonObject> get() = sockets.flatMap { it.sent }

    override fun open(url: String, listener: ImSocketListener): ImSocket {
        urls += url
        return FakeSocket(listener, this).also { sockets += it }
    }
}

internal class FakeSocket(
    private val listener: ImSocketListener,
    private val gateway: FakeGateway,
) : ImSocket {

    val sent = mutableListOf<JsonObject>()

    var cancelled: Boolean = false
        private set

    var closedWith: Pair<Int, String?>? = null
        private set

    override fun send(text: String): Boolean {
        val request = ImJson.parseToJsonElement(text).jsonObject
        sent += request

        val scripted = gateway.onRequest?.invoke(request)

        when {
            scripted != null -> deliver(scripted)

            // Answered even when a test scripted nothing, because the client sends it on every
            // connect exactly as conn.sync and conn.heartbeat are sent. A fake that leaves it
            // hanging leaves one pending request in every test — invisible until something counts
            // them, and then it fails somewhere that does not name the cause. Swift's mock had this
            // hole and it cost a red CI run.
            // 即使用例没有脚本也要答：客户端每次连接都会发它，与 conn.sync 一样。
            // 不答就在每个用例里留下一条挂起的请求——它一直看不见，直到有东西去数它。
            request.target == "diag.logRequests" ->
                deliver(serverFrame(id = request.id, target = request.target, data = JsonArray(emptyList())))
        }

        return true
    }

    override fun close(code: Int, reason: String?) {
        closedWith = code to reason
    }

    override fun cancel() {
        if (cancelled) return
        cancelled = true
        listener.onFailure(IOException("socket cancelled"))
    }

    // ---- things a server does ----

    fun opened() {
        listener.onOpen()
    }

    /** A close carrying a reason, e.g. `im-kick:MultiLoginPolicy`. */
    fun serverClosed(code: Int, reason: String) {
        listener.onClosed(code, reason)
    }

    /** A socket that dies without a close frame: the network, not the server. */
    fun networkFailure() {
        listener.onFailure(IOException("connection reset by peer"))
    }

    fun deliver(frame: JsonObject) {
        listener.onText(frame.toString())
    }

    fun push(target: String, data: JsonElement) {
        deliver(serverFrame(id = "srv-${sent.size + 1}", target = target, data = data))
    }

    fun requestsTo(target: String): List<JsonObject> = sent.filter { it.target == target }
}

/**
 * A cursor store that remembers what it was asked to do.
 *
 * Everything §5 promises is invisible from outside the SDK — the whole mechanism is about what is
 * written and when — so the tests assert on this rather than on behaviour a user could see.
 */
internal class RecordingCursorStore(
    initial: ImCursorSnapshot = ImCursorSnapshot(),
    /** Set to make [load] throw, which must not be mistaken for a fresh install. */
    private val loadFailure: Throwable? = null,
) : ImCursorStore {

    val saves = mutableListOf<ImCursorSnapshot>()

    var loads: Int = 0
        private set

    @Volatile
    var held: ImCursorSnapshot = initial
        private set

    override fun load(): ImCursorSnapshot {
        loads += 1
        loadFailure?.let { throw it }
        return held
    }

    override fun save(snapshot: ImCursorSnapshot) {
        saves += snapshot
        held = snapshot
    }
}

/** Captures the SDK's own diagnostics so a test can assert one was emitted. */
internal class RecordingLogger : ImLogger {
    val lines = mutableListOf<Pair<ImLogLevel, String>>()

    override fun log(level: ImLogLevel, message: String, cause: Throwable?) {
        lines += level to message
    }

    fun atLeast(level: ImLogLevel): List<String> = lines.filter { it.first >= level }.map { it.second }
}

// ---- frame helpers ----

internal val JsonObject.target: String get() = getValue("target").jsonPrimitive.content
internal val JsonObject.id: String get() = getValue("id").jsonPrimitive.content
internal val JsonObject.body: JsonObject get() = getValue("body").jsonObject
internal fun JsonObject.bodyLong(key: String): Long = body.getValue(key).jsonPrimitive.long
internal fun JsonObject.bodyString(key: String): String = body.getValue(key).jsonPrimitive.content
internal fun JsonObject.bodyStringOrNull(key: String): String? = body[key]?.jsonPrimitive?.content

/** The `convSeqs` map out of a `conn.sync` request frame. */
internal fun JsonObject.bodySeqMap(key: String): Map<String, Long> =
    (body[key] as? JsonObject)?.mapValues { (_, value) -> value.jsonPrimitive.long } ?: emptyMap()

internal fun serverFrame(
    id: String,
    target: String,
    data: JsonElement,
    code: Int = ImErrorCode.Ok,
    status: Int = 0,
): JsonObject = buildJsonObject {
    put("id", id)
    put("target", target)
    put("status", status)
    put(
        "body",
        buildJsonObject {
            put("code", code)
            put("serverTime", 1_700_000_000_000L)
            put("traceId", "trace-$id")
            put("data", data)
        },
    )
}

internal fun replyTo(
    request: JsonObject,
    data: JsonElement,
    code: Int = ImErrorCode.Ok,
    status: Int = 0,
): JsonObject = serverFrame(id = request.id, target = request.target, data = data, code = code, status = status)

internal fun messageJson(conversationId: String, seq: Long, text: String = "m$seq"): JsonObject =
    buildJsonObject {
        put("conversationId", conversationId)
        put("conversationType", 1)
        put("seq", seq)
        put("messageId", 9_000_000 + seq)
        put("clientMsgId", "cid-$seq")
        put("senderId", "bob")
        put("senderPlatform", 2)
        put("contentType", 1)
        put("content", buildJsonObject { put("text", text) })
        put("sendTime", 1_700_000_000_000L + seq)
        put("createTime", 1_700_000_000_000L + seq)
    }

internal fun conversationJson(conversationId: String, maxSeq: Long, updatedAt: Long = 42): JsonObject =
    buildJsonObject {
        put("conversationId", conversationId)
        put("type", 1)
        put("maxSeq", maxSeq)
        put("readSeq", 0)
        put("unreadCount", 0)
        put("updatedAt", updatedAt)
    }

/** One page of a `conn.sync` reply. */
internal fun resumePage(
    request: JsonObject,
    conversations: List<JsonObject> = emptyList(),
    gaps: Map<String, Long> = emptyMap(),
    hasMore: Boolean = false,
    nextCursor: String? = null,
): JsonObject = replyTo(
    request,
    buildJsonObject {
        put("conversations", JsonArray(conversations))
        put(
            "gapsFrom",
            buildJsonObject { for ((conversationId, seq) in gaps) put(conversationId, seq) },
        )
        put("hasMore", hasMore)
        nextCursor?.let { put("nextCursor", it) }
    },
)

/** One page of a `msg.sync` reply. */
internal fun syncPage(
    request: JsonObject,
    conversationId: String,
    seqs: List<Long>,
    hasMore: Boolean = false,
    maxSeq: Long = seqs.maxOrNull() ?: 0,
): JsonObject = replyTo(
    request,
    buildJsonObject {
        put("conversationId", conversationId)
        put("messages", JsonArray(seqs.map { messageJson(conversationId, it) }))
        put("maxSeq", maxSeq)
        put("minSeq", 1)
        put("hasMore", hasMore)
    },
)

internal fun testOptions(
    maxAutoRepairSeq: Long = 500,
    onTokenExpired: (suspend () -> String?)? = null,
    userId: String = "alice",
    logger: ImLogger = ImLogger.none(),
    autoRegisterPushToken: Boolean = true,
): ImOptions = ImOptions(
    endpoint = "wss://im.example.com",
    appId = "app-1",
    token = "token-1",
    deviceId = "device-1",
    userId = userId,
    platform = Platform.Android,
    maxAutoRepairSeq = maxAutoRepairSeq,
    // Zero, so a test never has to advance virtual time to see a commit reach the store. The
    // debounce itself is asserted separately.
    cursorFlushInterval = kotlin.time.Duration.ZERO,
    autoRegisterPushToken = autoRegisterPushToken,
    logger = logger,
    onTokenExpired = onTokenExpired,
)

/**
 * Always draws the top of the window, so a test can assert "it waited" without depending on a
 * particular seed. [BackoffTest] is where the actual randomness is examined.
 */
internal class CeilingRandom : Random() {
    override fun nextBits(bitCount: Int): Int = 0
    override fun nextLong(until: Long): Long = (until - 1).coerceAtLeast(0)
}

// ---- shared connection harness ----

internal fun TestScope.testConnection(
    gateway: FakeGateway,
    options: ImOptions = testOptions(),
    random: Random = CeilingRandom(),
): ImConnection = ImConnection(
    options = options,
    socketFactory = gateway,
    parentContext = backgroundScope.coroutineContext,
    random = random,
    clock = { 1_700_000_000_000L },
)

internal fun TestScope.openConnection(connection: ImConnection, gateway: FakeGateway) {
    backgroundScope.launch { connection.connect() }
    runCurrent()
    gateway.latest.opened()
    runCurrent()
    kotlin.test.assertEquals(ConnectionState.Open, connection.state.value)
}
