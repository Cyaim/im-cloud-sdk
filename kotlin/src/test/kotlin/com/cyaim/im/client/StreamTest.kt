@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `msg.streamBegin` / `streamAppend` / `streamComplete` / `streamAbort`, the `evt.stream` push, and
 * the rule streaming imposes on the rest of the client: **the pieces are not messages** — no seq, no
 * cursor, no repair — **and the finished stream is one**, delivered and repaired like any other.
 *
 * Every call is asserted on the whole frame it puts on the wire, by JSON kind, and on what it makes of
 * a reply with every field set. Each `evt.stream` phase is decoded as the server writes it, and the
 * assembly is driven through every order the server can produce: in order, shed pieces, a duplicate,
 * a mid-stream join, a straggler after the end, and the terminal frame before and after the stored
 * message.
 *
 * 每个调用断言发出的整帧与对满字段答复的解码；evt.stream 的每一相按服务端的写法解码；拼装覆盖服务端能产生的
 * 每一种顺序：按序、丢片、重复、中途加入、收尾后迟到的帧，以及终止帧在存储消息之前与之后。
 */
class StreamTest {

    /** Past 2^53 and odd, so a trip through a double would change its last digit. */
    private val bigId = 360_381_357_961_969_667L

    private fun handle(): JsonObject = buildJsonObject {
        // Every member of the server's StreamHandle, each with a value no default reads as.
        put("streamId", "st_9f2c")
        put("conversationId", "s_alice_bob")
        put("startedAt", 1_755_000_000_000L)
        put("idleTimeoutSeconds", 30)
    }

    private fun sendResult(seq: Long = 5): JsonObject = buildJsonObject {
        put("messageId", bigId.toString())
        put("seq", seq)
        put("conversationId", "s_alice_bob")
        put("clientMsgId", "cid-stream")
        put("createTime", 1_755_000_009_000L)
        put("deduplicated", true)
        put("contentModified", true)
    }

    private fun gateway(): FakeGateway = FakeGateway().apply {
        onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "msg.streamBegin" -> replyTo(request, handle())
                "msg.streamComplete" -> replyTo(request, sendResult())
                "msg.streamAppend", "msg.streamAbort" -> replyTo(request, JsonNull)
                else -> null
            }
        }
    }

    private suspend fun <T> TestScope.settle(block: suspend () -> T): T {
        val call = backgroundScope.async { block() }
        runCurrent()
        return call.await()
    }

    // ---- evt.stream frames, exactly as the server writes them (camelCase, nulls left out) ----

    private fun beginFrame(streamId: String = "st_9f2c", placeholder: JsonObject? = null) = buildJsonObject {
        put("streamId", streamId)
        put("conversationId", "s_alice_bob")
        put("senderId", "alice")
        put("index", 0)
        put("done", false)
        if (placeholder != null) put("placeholder", placeholder)
    }

    private fun deltaFrame(index: Int, delta: String, streamId: String = "st_9f2c") = buildJsonObject {
        put("streamId", streamId)
        put("conversationId", "s_alice_bob")
        put("senderId", "alice")
        put("index", index)
        put("delta", delta)
        put("done", false)
    }

    private fun completedFrame(index: Int, seq: Long = 5, streamId: String = "st_9f2c") = buildJsonObject {
        put("streamId", streamId)
        put("conversationId", "s_alice_bob")
        put("senderId", "alice")
        put("index", index)
        put("done", true)
        put("messageId", bigId.toString())
        put("seq", seq)
    }

    private fun abortedFrame(index: Int, reason: String, streamId: String = "st_9f2c") = buildJsonObject {
        put("streamId", streamId)
        put("conversationId", "s_alice_bob")
        put("senderId", "alice")
        put("index", index)
        put("done", true)
        put("abortReason", reason)
    }

    /** The stored message a completed stream becomes: an ordinary evt.message with a real seq. */
    private fun storedMessage(seq: Long, text: String) = buildJsonObject {
        put("conversationId", "s_alice_bob")
        put("conversationType", 1)
        put("seq", seq)
        put("messageId", bigId.toString())
        put("clientMsgId", "cid-stream")
        put("senderId", "alice")
        put("senderPlatform", 2)
        put("contentType", 1)
        putJsonObject("content") { put("text", text) }
        put("sendTime", 1_755_000_000_000L)
        put("createTime", 1_755_000_009_000L)
    }

    private fun event(frame: JsonObject): StreamEvent = assertNotNull(StreamEvent.fromData(frame), "undecodable: $frame")

    // ------------------------------------------------------------------------------- the calls

    @Test
    fun `streamBegin fills the key, sends the content type as an integer, and decodes the handle`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val opened = settle { client.msg.streamBegin(BeginStreamRequest(receiverId = "bob")) }

        val body = gateway.latest.requestsTo("msg.streamBegin").single().body
        assertEquals(setOf("receiverId", "clientMsgId", "contentType"), body.keys, "nulls stay off the frame: $body")
        assertEquals("bob", body.jsonString("receiverId"))
        assertTrue(body.jsonString("clientMsgId").isNotBlank(), "the server makes none up and answers 1001 without one")
        assertEquals(MessageContentType.Text.code.toLong(), body.jsonInteger("contentType"))

        assertEquals("st_9f2c", opened.streamId)
        assertEquals("s_alice_bob", opened.conversationId)
        assertEquals(1_755_000_000_000L, opened.startedAt)
        assertEquals(30, opened.idleTimeoutSeconds)
    }

    @Test
    fun `streamBegin writes every member, options nested in exact camelCase`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.msg.streamBegin(
                BeginStreamRequest(
                    conversationId = "g_team",
                    receiverId = "bob",
                    groupId = "team",
                    clientMsgId = "cid-stream",
                    contentType = MessageContentType.Custom,
                    placeholder = buildJsonObject { put("name", "Assistant"); put("avatar", "bots/a.png") },
                    options = MessageOptions(
                        persistent = false, updateConversation = false, countUnread = false, offlinePush = false,
                        pushConfig = PushConfig(sound = "ding", payload = mapOf("k" to "v"), badgeCount = false, channelId = "ai"),
                        needReceipt = true, priority = MessagePriority.High, onlineOnly = true, noSelfSync = true,
                        expireIn = 60_000L, moderationBypass = true,
                    ),
                    extensions = buildJsonObject { put("model", "m-1") },
                ),
            )
        }

        val body = gateway.latest.requestsTo("msg.streamBegin").single().body
        assertEquals(members("BeginStreamRequest"), body.keys)
        assertEquals("g_team", body.jsonString("conversationId"))
        assertEquals("bob", body.jsonString("receiverId"))
        assertEquals("team", body.jsonString("groupId"))
        assertEquals("cid-stream", body.jsonString("clientMsgId"), "a given key is kept")
        assertEquals(100L, body.jsonInteger("contentType"))
        val placeholder = body.getValue("placeholder").jsonObject
        assertEquals("Assistant", placeholder.jsonString("name"))
        assertEquals("bots/a.png", placeholder.jsonString("avatar"))
        assertEquals("m-1", body.getValue("extensions").jsonObject.jsonString("model"))

        // Nested and matched case-sensitively by the socket: a miscased key would be dropped silently.
        val options = body.getValue("options").jsonObject
        assertEquals(members("MessageOptions"), options.keys)
        assertFalse(options.jsonBoolean("persistent"))
        assertFalse(options.jsonBoolean("updateConversation"))
        assertFalse(options.jsonBoolean("countUnread"))
        assertFalse(options.jsonBoolean("offlinePush"))
        assertTrue(options.jsonBoolean("needReceipt"))
        assertEquals(MessagePriority.High.code.toLong(), options.jsonInteger("priority"))
        assertTrue(options.jsonBoolean("onlineOnly"))
        assertTrue(options.jsonBoolean("noSelfSync"))
        assertEquals(60_000L, options.jsonInteger("expireIn"))
        assertTrue(options.jsonBoolean("moderationBypass"))
        val push = options.getValue("pushConfig").jsonObject
        // title and body are absent because a client may not send them (1103), not because they cannot be.
        assertEquals(setOf("sound", "payload", "badgeCount", "channelId"), push.keys)
        assertEquals("ding", push.jsonString("sound"))
        assertEquals("v", push.getValue("payload").jsonObject.jsonString("k"))
        assertFalse(push.jsonBoolean("badgeCount"))
        assertEquals("ai", push.jsonString("channelId"))
    }

    @Test
    fun `streamAppend and streamAbort send the stream id and their one field, as strings`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.msg.streamAppend(StreamAppendRequest("st_9f2c", "Hel"))
            client.msg.streamAbort(StreamAbortRequest("st_9f2c", reason = "the model failed"))
            client.msg.streamAbort(StreamAbortRequest("st_9f2d"))
        }

        val append = gateway.latest.requestsTo("msg.streamAppend").single().body
        assertEquals(setOf("streamId", "delta"), append.keys)
        assertEquals("st_9f2c", append.jsonString("streamId"))
        assertEquals("Hel", append.jsonString("delta"))

        val (reasoned, bare) = gateway.latest.requestsTo("msg.streamAbort").map { it.body }
        assertEquals(setOf("streamId", "reason"), reasoned.keys)
        assertEquals("the model failed", reasoned.jsonString("reason"))
        assertEquals(setOf("streamId"), bare.keys, "no reason is left off, never written as null: $bare")
        assertEquals("st_9f2d", bare.jsonString("streamId"))
    }

    @Test
    fun `streamComplete sends only what is given and decodes the stored message's identity`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val result = settle { client.msg.streamComplete(CompleteStreamRequest("st_9f2c")) }
        settle {
            client.msg.streamComplete(
                CompleteStreamRequest(
                    "st_9f2c",
                    content = textContent("Hello, cleaned up."),
                    extensions = buildJsonObject { put("tokens", 42) },
                ),
            )
        }

        val (plain, full) = gateway.latest.requestsTo("msg.streamComplete").map { it.body }
        assertEquals(setOf("streamId"), plain.keys, "no content: the server joins the pieces itself: $plain")
        assertEquals("st_9f2c", plain.jsonString("streamId"))
        assertEquals(setOf("streamId", "content", "extensions"), full.keys)
        assertEquals("Hello, cleaned up.", full.getValue("content").jsonObject.jsonString("text"))
        assertEquals(42L, full.getValue("extensions").jsonObject.jsonInteger("tokens"))

        assertEquals(bigId, result.messageId, "a string id, every digit kept")
        assertEquals(5L, result.seq)
        assertEquals("s_alice_bob", result.conversationId)
        assertEquals("cid-stream", result.clientMsgId)
        assertEquals(1_755_000_009_000L, result.createTime)
        assertTrue(result.deduplicated)
        assertTrue(result.contentModified)
    }

    @Test
    fun `a refused stream call throws with the server code and the target`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "msg.streamAppend" -> replyTo(request, JsonNull, code = ImErrorCode.NotFound)
                "msg.streamComplete" -> replyTo(request, JsonNull, code = ImErrorCode.ModerationRejected)
                "msg.streamBegin" -> replyTo(request, JsonNull, code = ImErrorCode.UnsupportedOperation)
                else -> null
            }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        val failures = settle {
            listOf(
                runCatching { client.msg.streamBegin(BeginStreamRequest(conversationId = "r_lobby")) },
                runCatching { client.msg.streamAppend(StreamAppendRequest("st_gone", "x")) },
                runCatching { client.msg.streamComplete(CompleteStreamRequest("st_9f2c")) },
            ).map { assertNotNull(it.exceptionOrNull() as? ImException) }
        }

        assertEquals(
            listOf(
                ImErrorCode.UnsupportedOperation to "msg.streamBegin",
                ImErrorCode.NotFound to "msg.streamAppend",
                ImErrorCode.ModerationRejected to "msg.streamComplete",
            ),
            failures.map { it.code to it.target },
        )
    }

    @Test
    fun `a StreamWriter opens with a key it keeps and sends every later call for its own stream`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val (writer, result) = settle {
            val writer = StreamWriter.begin(client.msg, BeginStreamRequest(receiverId = "bob"))
            writer.append("Hel")
            writer.append("lo")
            writer to writer.complete()
        }
        settle { writer.abort("too late") }

        val sent = gateway.latest
        val key = sent.requestsTo("msg.streamBegin").single().body.jsonString("clientMsgId")
        assertTrue(key.isNotBlank())
        assertEquals(key, writer.clientMsgId, "the writer knows the key the message will be stored under")
        assertEquals("st_9f2c", writer.streamId)
        assertEquals(30, writer.handle.idleTimeoutSeconds)
        assertEquals(listOf("Hel", "lo"), sent.requestsTo("msg.streamAppend").map { it.body.jsonString("delta") })
        assertTrue(sent.requestsTo("msg.streamAppend").all { it.body.jsonString("streamId") == "st_9f2c" })
        assertEquals(setOf("streamId"), sent.requestsTo("msg.streamComplete").single().body.keys)
        assertEquals("too late", sent.requestsTo("msg.streamAbort").single().body.jsonString("reason"))
        assertEquals(bigId, result.messageId)

        val given = settle { StreamWriter.begin(client.msg, BeginStreamRequest(groupId = "team", clientMsgId = "mine")) }
        assertEquals("mine", given.clientMsgId)
    }

    // --------------------------------------------------------------------------------- evt.stream

    @Test
    fun `each evt stream phase decodes as the server writes it`() {
        val begin = event(beginFrame(placeholder = buildJsonObject { put("name", "Assistant") }))
        assertEquals(StreamPhase.Begin, begin.phase)
        assertEquals("st_9f2c", begin.streamId)
        assertEquals("s_alice_bob", begin.conversationId)
        assertEquals("alice", begin.senderId)
        assertEquals(0, begin.index)
        assertNull(begin.delta, "the opening carries no delta")
        assertFalse(begin.done)
        assertEquals("Assistant", begin.placeholder?.jsonString("name"))
        assertNull(event(beginFrame()).placeholder, "a stream opened without one")

        val delta = event(deltaFrame(3, "lo, "))
        assertEquals(StreamPhase.Delta, delta.phase)
        assertEquals(3, delta.index)
        assertEquals("lo, ", delta.delta)
        assertNull(delta.messageId)
        assertNull(delta.placeholder)

        val completed = event(completedFrame(4, seq = 5_000_000_000L))
        assertEquals(StreamPhase.Completed, completed.phase)
        assertTrue(completed.done)
        assertEquals(4, completed.index)
        assertEquals(bigId, completed.messageId, "written as a string: every digit kept")
        assertEquals(5_000_000_000L, completed.seq)
        assertNull(completed.abortReason)

        // The same id as a bare number, as an older server wrote it.
        val numeric = event(
            buildJsonObject {
                put("streamId", "st_9f2c"); put("conversationId", "s_alice_bob"); put("senderId", "alice")
                put("index", 2); put("done", true); put("messageId", 77); put("seq", 6)
            },
        )
        assertEquals(StreamPhase.Completed, numeric.phase)
        assertEquals(77L, numeric.messageId)

        val aborted = event(abortedFrame(4, "the producer stopped sending for 30s"))
        assertEquals(StreamPhase.Aborted, aborted.phase)
        assertTrue(aborted.done)
        assertNull(aborted.messageId, "no message id is what makes it an abort")
        assertNull(aborted.seq)
        assertEquals("the producer stopped sending for 30s", aborted.abortReason)

        assertNull(StreamEvent.fromData(JsonPrimitive("not an object")))
        assertNull(StreamEvent.fromData(buildJsonObject { put("index", 1); put("delta", "x") }), "no stream id")
        assertNull(StreamEvent.fromData(null))
    }

    @Test
    fun `evt stream frames come out of streamEvents and never reach messages or a cursor`() = runTest {
        val gateway = gateway()
        val store = RecordingCursorStore()
        val client = newClient(gateway, store = store)
        val received = collectMessages(client)
        val events = mutableListOf<StreamEvent>()
        backgroundScope.launch { client.streamEvents.collect { events += it } }
        openClient(client, gateway)
        val socket = gateway.latest

        socket.push(PushTarget.Message, messageJson("s_alice_bob", 1))
        runCurrent()
        socket.push(PushTarget.Stream, beginFrame())
        socket.push(PushTarget.Stream, deltaFrame(1, "Hel"))
        socket.push(PushTarget.Stream, deltaFrame(3, "lo"))
        socket.push(PushTarget.Stream, JsonPrimitive("not an object"))
        socket.push(PushTarget.Stream, abortedFrame(4, "aborted by the producer"))
        runCurrent()

        assertEquals(listOf(0, 1, 3, 4), events.map { it.index }, "the unreadable frame is dropped, the rest delivered")
        assertEquals(listOf(StreamPhase.Begin, StreamPhase.Delta, StreamPhase.Delta, StreamPhase.Aborted), events.map { it.phase })
        assertEquals(listOf(1L), received.map { it.seq }, "a piece is not a message")
        assertTrue(socket.requestsTo("msg.sync").isEmpty(), "a hole between pieces is not a range to repair")

        // The conversation's cursor did not move for the stream: its next message is contiguous.
        socket.push(PushTarget.Message, messageJson("s_alice_bob", 2))
        runCurrent()
        assertEquals(listOf(1L, 2L), received.map { it.seq })
        assertTrue(socket.requestsTo("msg.sync").isEmpty())
        client.flushCursors()
        assertTrue(store.saves.none { it.convSeqs.keys.any { key -> key.startsWith("st_") } })
    }

    // ------------------------------------------------------------------------------- assembling

    @Test
    fun `pieces in order assemble into the text, and the completed stream names its message`() {
        val assembler = StreamAssembler()

        val opened = assertNotNull(assembler.accept(event(beginFrame(placeholder = buildJsonObject { put("name", "Assistant") }))))
        assertEquals(StreamStatus.Streaming, opened.status)
        assertEquals("", opened.text)
        assertTrue(opened.intact)
        assertEquals("Assistant", opened.placeholder?.jsonString("name"))

        assembler.accept(event(deltaFrame(1, "Hel")))
        assembler.accept(event(deltaFrame(2, "lo, ")))
        val third = assertNotNull(assembler.accept(event(deltaFrame(3, "world"))))
        assertEquals("Hello, world", third.text)
        assertTrue(third.intact)
        assertEquals("Hello, world", assembler["st_9f2c"]?.text)
        assertEquals(listOf("st_9f2c"), assembler.active.map { it.streamId })

        val done = assertNotNull(assembler.accept(event(completedFrame(4))))
        assertEquals(StreamStatus.Completed, done.status)
        assertEquals("Hello, world", done.text)
        assertTrue(done.intact)
        assertEquals(bigId, done.messageId)
        assertEquals(5L, done.seq)
        assertNull(done.abortReason)
        assertEquals("alice", done.senderId)
        assertEquals("s_alice_bob", done.conversationId)
        assertEquals("Assistant", done.placeholder?.jsonString("name"), "the placeholder outlives the opening frame")
        assertTrue(assembler.active.isEmpty(), "a finished stream is no longer running")
        assertNull(assembler["st_9f2c"])
    }

    @Test
    fun `an aborted stream ends with its reason and no message`() {
        val assembler = StreamAssembler()
        assembler.accept(event(beginFrame()))
        assembler.accept(event(deltaFrame(1, "Hel")))

        val aborted = assertNotNull(assembler.accept(event(abortedFrame(2, "the producer stopped sending for 30s"))))

        assertEquals(StreamStatus.Aborted, aborted.status)
        assertEquals("the producer stopped sending for 30s", aborted.abortReason)
        assertNull(aborted.messageId, "nothing was stored and nothing will arrive")
        assertNull(aborted.seq)
        assertEquals("Hel", aborted.text)
        assertTrue(aborted.intact)
        assertTrue(assembler.active.isEmpty())
    }

    @Test
    fun `a stream completed with no pieces is intact`() {
        val assembler = StreamAssembler()
        assembler.accept(event(beginFrame()))

        val done = assertNotNull(assembler.accept(event(completedFrame(1))))

        assertEquals(StreamStatus.Completed, done.status)
        assertEquals("", done.text)
        assertTrue(done.intact)
    }

    @Test
    fun `a duplicate piece and a duplicate opening change nothing`() {
        val assembler = StreamAssembler()
        assembler.accept(event(beginFrame()))
        assembler.accept(event(deltaFrame(1, "Hel")))

        assertNull(assembler.accept(event(deltaFrame(1, "Hel"))))
        assertNull(assembler.accept(event(beginFrame())))
        assertEquals("Hel", assembler["st_9f2c"]?.text)

        assembler.accept(event(deltaFrame(2, "lo")))
        assertNull(assembler.accept(event(deltaFrame(1, "Hel"))), "already joined into the text")
        assertEquals("Hello", assembler["st_9f2c"]?.text)
    }

    @Test
    fun `a piece ahead of a missing one waits, and joins when the missing one arrives`() {
        val assembler = StreamAssembler()
        assembler.accept(event(beginFrame()))
        assembler.accept(event(deltaFrame(1, "a")))

        val ahead = assertNotNull(assembler.accept(event(deltaFrame(3, "c"))))
        assertEquals("a", ahead.text, "the text stops at the hole rather than running past it")
        assertFalse(ahead.intact)
        assertNull(assembler.accept(event(deltaFrame(3, "c"))), "a held piece is not taken twice")

        val filled = assertNotNull(assembler.accept(event(deltaFrame(2, "b"))))
        assertEquals("abc", filled.text)
        assertTrue(filled.intact)
    }

    @Test
    fun `a shed piece leaves the stream not intact through to its end, and nothing is repaired`() {
        val assembler = StreamAssembler()
        assembler.accept(event(beginFrame()))
        assembler.accept(event(deltaFrame(1, "a")))
        assembler.accept(event(deltaFrame(3, "c")))

        val done = assertNotNull(assembler.accept(event(completedFrame(4))))

        assertEquals(StreamStatus.Completed, done.status)
        assertEquals("a", done.text)
        assertFalse(done.intact, "the stored message, not this text, is the reply")
        assertEquals(bigId, done.messageId)
    }

    @Test
    fun `a terminal frame past the last piece seen says pieces were lost`() {
        // Piece 2 was shed and nothing after it was ever sent: only the terminal index shows the loss.
        val assembler = StreamAssembler()
        assembler.accept(event(beginFrame()))
        assembler.accept(event(deltaFrame(1, "a")))

        val done = assertNotNull(assembler.accept(event(abortedFrame(3, "aborted by the producer"))))

        assertEquals(StreamStatus.Aborted, done.status)
        assertFalse(done.intact)
    }

    @Test
    fun `a mid-stream join is accepted and marked not intact`() {
        val assembler = StreamAssembler()

        val joined = assertNotNull(assembler.accept(event(deltaFrame(4, "late"))))

        assertEquals(StreamStatus.Streaming, joined.status)
        assertEquals("", joined.text, "pieces 1 to 3 never reached this device")
        assertFalse(joined.intact)
        assertNull(joined.placeholder)
        assertEquals("alice", joined.senderId)
        assertEquals("s_alice_bob", joined.conversationId)

        val done = assertNotNull(assembler.accept(event(completedFrame(5))))
        assertFalse(done.intact)
        assertEquals(bigId, done.messageId, "the message id is still there to swap in the stored message")
    }

    @Test
    fun `nothing reopens a finished stream`() {
        val assembler = StreamAssembler()
        assembler.accept(event(beginFrame()))
        assembler.accept(event(deltaFrame(1, "a")))
        assembler.accept(event(completedFrame(3)))

        assertNull(assembler.accept(event(deltaFrame(2, "b"))), "a straggler after the end")
        assertNull(assembler.accept(event(completedFrame(3))), "a second terminal frame")
        assertNull(assembler.accept(event(abortedFrame(3, "x"))))
        assertTrue(assembler.active.isEmpty())
    }

    @Test
    fun `streams are kept apart, and clear drops the running ones`() {
        val assembler = StreamAssembler()
        assembler.accept(event(beginFrame("st_a")))
        assembler.accept(event(beginFrame("st_b")))
        assembler.accept(event(deltaFrame(1, "A", streamId = "st_a")))
        assembler.accept(event(deltaFrame(1, "B", streamId = "st_b")))

        assertEquals("A", assembler["st_a"]?.text)
        assertEquals("B", assembler["st_b"]?.text)

        assembler.remove("st_a")
        assertEquals(listOf("st_b"), assembler.active.map { it.streamId })
        assembler.clear()
        assertTrue(assembler.active.isEmpty())
    }

    // ----------------------------------------------------- the finished stream is a message

    @Test
    fun `the stored message arrives through the ordinary path whether it lands before or after the terminal frame`() = runTest {
        for (messageFirst in listOf(false, true)) {
            val gateway = gateway()
            val client = newClient(gateway)
            val received = collectMessages(client)
            val streams = mutableListOf<AssembledStream>()
            backgroundScope.launch { client.streamEvents.assemble().collect { streams += it } }
            openClient(client, gateway)
            val socket = gateway.latest

            socket.push(PushTarget.Message, messageJson("s_alice_bob", 4))
            runCurrent()
            socket.push(PushTarget.Stream, beginFrame())
            socket.push(PushTarget.Stream, deltaFrame(1, "Hel"))
            socket.push(PushTarget.Stream, deltaFrame(2, "lo"))
            runCurrent()
            if (messageFirst) socket.push(PushTarget.Message, storedMessage(5, "Hello"))
            socket.push(PushTarget.Stream, completedFrame(3, seq = 5))
            if (!messageFirst) socket.push(PushTarget.Message, storedMessage(5, "Hello"))
            runCurrent()

            val final = streams.last()
            assertEquals(StreamStatus.Completed, final.status, "messageFirst=$messageFirst")
            assertEquals("Hello", final.text)
            val stored = received.single { it.seq == 5L }
            assertEquals(final.messageId, stored.messageId, "matched by message id (messageFirst=$messageFirst)")
            assertEquals("Hello", stored.text)
            assertEquals("cid-stream", stored.clientMsgId)
            assertEquals(listOf(4L, 5L), received.map { it.seq }, "contiguous, so nothing to repair")
            assertTrue(socket.requestsTo("msg.sync").isEmpty())
            client.close()
        }
    }

    @Test
    fun `streamComplete moves no cursor, so the producer's own copy is still delivered`() = runTest {
        val gateway = gateway()
        val store = RecordingCursorStore()
        val client = newClient(gateway, store = store)
        val received = collectMessages(client)
        openClient(client, gateway)
        val socket = gateway.latest

        socket.push(PushTarget.Message, messageJson("s_alice_bob", 4))
        runCurrent()
        val result = settle { client.msg.streamComplete(CompleteStreamRequest("st_9f2c")) }
        assertEquals(5L, result.seq)
        socket.push(PushTarget.Message, storedMessage(5, "Hello"))
        runCurrent()

        assertEquals(listOf(4L, 5L), received.map { it.seq }, "msg.send's cursor hook would have dropped seq 5 as a duplicate")
        assertTrue(socket.requestsTo("msg.sync").isEmpty())
    }

    @Test
    fun `a stored message that skips a seq is still repaired like any other`() = runTest {
        // The completed stream is an ordinary message: if the one before it was lost, the hole is
        // repaired before it is delivered.
        val gateway = gateway()
        val client = newClient(gateway)
        val received = collectMessages(client)
        openClient(client, gateway)
        val socket = gateway.latest

        socket.push(PushTarget.Message, messageJson("s_alice_bob", 3))
        runCurrent()
        socket.push(PushTarget.Message, storedMessage(5, "Hello"))
        runCurrent()

        val sync = socket.requestsTo("msg.sync").single()
        assertEquals("s_alice_bob", sync.bodyString("conversationId"))
        assertEquals(4L, sync.bodyLong("fromSeq"))
        assertEquals(4L, sync.bodyLong("toSeq"))
        assertEquals(listOf(3L), received.map { it.seq }, "held behind the repair")
    }

    // ------------------------------------------------------------------- held to the inventory

    /**
     * The decoding tests above are only as wide as their fixtures, and a request test only as wide as
     * the instance it builds. So the full fixtures carry every member the server declares, and the
     * requests send every member, held here to `endpoint-inventory.json`'s `payloadTypes`.
     */
    @Test
    fun `the full fixtures and requests carry every member the server declares`() {
        assertEquals(members("StreamHandle"), handle().keys)
        assertEquals(members("SendMessageResult"), sendResult().keys)

        val options = MessageOptions(pushConfig = PushConfig(title = "t", body = "b", sound = "s", payload = mapOf("k" to "v"), channelId = "c"), expireIn = 1L)
        val begin = BeginStreamRequest(
            conversationId = "c", receiverId = "r", groupId = "g", clientMsgId = "k",
            placeholder = buildJsonObject { put("name", "n") }, options = options, extensions = buildJsonObject { put("k", "v") },
        ).asBody().jsonObject
        assertEquals(members("BeginStreamRequest"), begin.keys)
        assertEquals(members("MessageOptions"), begin.getValue("options").jsonObject.keys)
        assertEquals(members("PushConfig"), begin.getValue("options").jsonObject.getValue("pushConfig").jsonObject.keys)
        assertEquals(members("StreamAppendRequest"), StreamAppendRequest("st_1", "d").asBody().jsonObject.keys)
        assertEquals(
            members("CompleteStreamRequest"),
            CompleteStreamRequest("st_1", textContent("t"), buildJsonObject { put("k", "v") }).asBody().jsonObject.keys,
        )
        assertEquals(members("StreamAbortRequest"), StreamAbortRequest("st_1", "r").asBody().jsonObject.keys)
    }

    /**
     * `evt.stream`'s data is the server's `StreamDelta` (and, for the opening, `StreamBeginFrame`:
     * the same shape plus `placeholder`). Neither is a request or a reply, so neither is in the
     * inventory's `payloadTypes`; the members are pinned here from `IStreamingMessageService.cs` and
     * `StreamingMessageService.cs`, and every one of them is read by [StreamEvent.fromData] — a
     * fixture key this SDK did not read would decode to null and an assertion above would fail.
     *
     * evt.stream 的 data 是服务端的 StreamDelta（开流帧是 StreamBeginFrame，多一个 placeholder）。两者都不在清单的
     * payloadTypes 里，所以成员在这里照 C# 钉住。
     */
    @Test
    fun `the evt stream fixtures carry every member of StreamDelta and StreamBeginFrame`() {
        val streamDelta = setOf("streamId", "conversationId", "senderId", "index", "delta", "done", "messageId", "seq", "abortReason")
        val streamBeginFrame = setOf("streamId", "conversationId", "senderId", "index", "done", "placeholder")

        assertEquals(streamBeginFrame, beginFrame(placeholder = buildJsonObject { put("name", "n") }).keys)
        assertEquals(
            streamDelta,
            deltaFrame(1, "d").keys + completedFrame(2).keys + abortedFrame(2, "r").keys,
            "between them the three later phases carry every member",
        )
        // The server leaves nulls out, so each phase carries only its own optional members.
        assertEquals(setOf("streamId", "conversationId", "senderId", "index", "delta", "done"), deltaFrame(1, "d").keys)
        assertEquals(setOf("streamId", "conversationId", "senderId", "index", "done", "messageId", "seq"), completedFrame(2).keys)
        assertEquals(setOf("streamId", "conversationId", "senderId", "index", "done", "abortReason"), abortedFrame(2, "r").keys)
    }

    private fun members(type: String): Set<String> {
        val inventory = ImJson.parseToJsonElement(inventoryFile().readText()).jsonObject
        return inventory.getValue("payloadTypes").jsonObject.getValue(type).jsonObject.getValue("properties").jsonArray
            .map { it.jsonObject.getValue("name").jsonPrimitive.content }
            .toSet()
    }

    private fun inventoryFile(): File {
        var directory: File? = File(".").absoluteFile
        repeat(8) {
            val candidate = directory ?: return@repeat
            val inventory = File(candidate, "endpoint-inventory.json")
            if (inventory.isFile) return inventory
            directory = candidate.parentFile
        }
        error("could not locate SDK/endpoint-inventory.json from ${File(".").absolutePath}")
    }
}
