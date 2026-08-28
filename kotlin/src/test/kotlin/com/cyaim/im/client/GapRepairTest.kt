@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * The correctness property this SDK exists for: the application never sees a conversation jump
 * forward and then fill in behind it.
 *
 * The cold-start half of the same story — what happens across a *process* restart rather than a
 * socket one — lives in [CursorTest], because it is a different failure with a different fix.
 */
class GapRepairTest {

    @Test
    fun `a gap is repaired before the message that revealed it is delivered`() = runTest {
        val gateway = gatewayWith(
            syncReply = { request -> syncPage(request, "c1", listOf(2L, 3L, 4L)) },
        )
        val client = newClient(gateway)
        val received = collectMessages(client)
        openClient(client, gateway)

        gateway.latest.push(PushTarget.Message, messageJson("c1", 1))
        runCurrent()

        // seq 5 with a local cursor of 1: 2, 3 and 4 were never delivered.
        gateway.latest.push(PushTarget.Message, messageJson("c1", 5))
        runCurrent()

        assertEquals(listOf(1L, 2L, 3L, 4L, 5L), received.map { it.seq })

        val sync = assertNotNull(gateway.latest.requestsTo("msg.sync").singleOrNull())
        assertEquals(2L, sync.bodyLong("fromSeq"))
        assertEquals(4L, sync.bodyLong("toSeq"))
        assertEquals(3L, sync.bodyLong("limit"))
    }

    @Test
    fun `a contiguous stream never calls msg dot sync`() = runTest {
        val gateway = gatewayWith()
        val client = newClient(gateway)
        val received = collectMessages(client)
        openClient(client, gateway)

        for (seq in 1L..5L) {
            gateway.latest.push(PushTarget.Message, messageJson("c1", seq))
            runCurrent()
        }

        assertEquals(listOf(1L, 2L, 3L, 4L, 5L), received.map { it.seq })
        assertTrue(gateway.latest.requestsTo("msg.sync").isEmpty())
    }

    @Test
    fun `a replayed message after a reconnect is dropped silently`() = runTest {
        val gateway = gatewayWith()
        val client = newClient(gateway)
        val received = collectMessages(client)
        openClient(client, gateway)

        gateway.latest.push(PushTarget.Message, messageJson("c1", 1))
        runCurrent()
        gateway.latest.push(PushTarget.Message, messageJson("c1", 2))
        runCurrent()
        gateway.latest.push(PushTarget.Message, messageJson("c1", 2))
        runCurrent()

        assertEquals(listOf(1L, 2L), received.map { it.seq })
    }

    @Test
    fun `an online-only message never moves the cursor`() = runTest {
        val gateway = gatewayWith(syncReply = { request -> syncPage(request, "c1", listOf(2L)) })
        val client = newClient(gateway)
        val received = collectMessages(client)
        openClient(client, gateway)

        gateway.latest.push(PushTarget.Message, messageJson("c1", 1))
        runCurrent()

        // seq 0: a chatroom or online-only message that was never persisted. It is delivered, but
        // it must not be mistaken for progress — otherwise the next real message looks contiguous.
        gateway.latest.push(PushTarget.Message, messageJson("c1", 0))
        runCurrent()
        gateway.latest.push(PushTarget.Message, messageJson("c1", 3))
        runCurrent()

        assertEquals(listOf(1L, 0L, 2L, 3L), received.map { it.seq })
    }

    @Test
    fun `gaps in different conversations do not block each other`() = runTest {
        val gateway = gatewayWith(
            syncReply = { request ->
                syncPage(request, request.bodyString("conversationId"), listOf(2L))
            },
        )
        val client = newClient(gateway)
        val received = collectMessages(client)
        openClient(client, gateway)

        gateway.latest.push(PushTarget.Message, messageJson("c1", 1))
        gateway.latest.push(PushTarget.Message, messageJson("c2", 1))
        runCurrent()

        gateway.latest.push(PushTarget.Message, messageJson("c1", 3))
        gateway.latest.push(PushTarget.Message, messageJson("c2", 3))
        runCurrent()

        assertEquals(2, gateway.latest.requestsTo("msg.sync").size)
        assertEquals(listOf(1L, 2L, 3L), received.filter { it.conversationId == "c1" }.map { it.seq })
        assertEquals(listOf(1L, 2L, 3L), received.filter { it.conversationId == "c2" }.map { it.seq })
    }

    /**
     * A device that has been offline for a week is behind by more messages than it can usefully
     * receive at once. The cursor still has to end up correct, and the app has to be told which
     * conversation to reload.
     */
    @Test
    fun `a gap wider than maxAutoRepairSeq is reported instead of backfilled`() = runTest {
        val gateway = gatewayWith()
        val client = newClient(gateway, maxAutoRepairSeq = 3)
        val received = collectMessages(client)
        val reload = collectReloads(client)
        openClient(client, gateway)

        gateway.latest.push(PushTarget.Message, messageJson("c1", 1))
        runCurrent()
        gateway.latest.push(PushTarget.Message, messageJson("c1", 5_000))
        runCurrent()

        assertTrue(gateway.latest.requestsTo("msg.sync").isEmpty(), "4998 messages is not a backfill")
        assertEquals(listOf("c1"), reload)
        assertEquals(listOf(1L, 5_000L), received.map { it.seq })

        // The cursor kept up, so the next message is contiguous rather than another false gap.
        gateway.latest.push(PushTarget.Message, messageJson("c1", 5_001))
        runCurrent()
        assertEquals(listOf(1L, 5_000L, 5_001L), received.map { it.seq })
    }

    // ----------------------------------------------------------------------- resume

    @Test
    fun `reconnecting repairs what conn dot sync reports as gapsFrom`() = runTest {
        val gateway = gatewayWith(
            resumeReply = { request ->
                resumePage(
                    request,
                    conversations = listOf(conversationJson("c1", maxSeq = 8)),
                    gaps = mapOf("c1" to 6L),
                )
            },
            syncReply = { request -> syncPage(request, "c1", listOf(6L, 7L, 8L)) },
        )
        val client = newClient(gateway, store = RecordingCursorStore(ImCursorSnapshot(mapOf("c1" to 5L))))
        val received = collectMessages(client)
        openClient(client, gateway)

        val sync = assertNotNull(gateway.latest.requestsTo("msg.sync").singleOrNull())
        assertEquals(6L, sync.bodyLong("fromSeq"))
        assertEquals(8L, sync.bodyLong("toSeq"))
        assertEquals(listOf(6L, 7L, 8L), received.map { it.seq })
    }

    @Test
    fun `a conversation seen for the first time adopts its position instead of replaying it`() = runTest {
        val gateway = gatewayWith(
            resumeReply = { request ->
                resumePage(request, conversations = listOf(conversationJson("c1", maxSeq = 4_000)))
            },
        )
        val client = newClient(gateway)
        val received = collectMessages(client)
        openClient(client, gateway)

        assertTrue(gateway.latest.requestsTo("msg.sync").isEmpty(), "a cold start is not a gap")
        assertTrue(received.isEmpty())

        // And the adopted cursor is real: the next message is contiguous with it.
        gateway.latest.push(PushTarget.Message, messageJson("c1", 4_001))
        runCurrent()
        assertEquals(listOf(4_001L), received.map { it.seq })
    }

    // --------------------------------------------------------------------- sending

    @Test
    fun `a send without a clientMsgId still gets one`() = runTest {
        val gateway = gatewayWith(
            sendReply = { request ->
                replyTo(
                    request,
                    buildJsonObject {
                        put("messageId", 1)
                        put("seq", 1)
                        put("conversationId", "c1")
                        put("clientMsgId", "echoed")
                        put("createTime", 1)
                    },
                )
            },
        )
        val client = newClient(gateway)
        openClient(client, gateway)

        client.msg.send(SendRequest(target = SendTarget.User("bob"), content = textContent("hello")))
        runCurrent()

        val send = assertNotNull(gateway.latest.requestsTo("msg.send").singleOrNull())
        assertEquals("bob", send.bodyString("receiverId"))
        assertTrue(send.bodyString("clientMsgId").isNotEmpty())
        assertEquals(MessageContentType.Text.code.toLong(), send.bodyLong("contentType"))
    }

    // --------------------------------------------------------------------- helpers

    private fun gatewayWith(
        resumeReply: (JsonObject) -> JsonObject? = { request -> resumePage(request) },
        syncReply: (JsonObject) -> JsonObject? = { null },
        sendReply: (JsonObject) -> JsonObject? = { null },
    ): FakeGateway = FakeGateway().apply {
        onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumeReply(request)
                "msg.sync" -> syncReply(request)
                "msg.send" -> sendReply(request)
                else -> null
            }
        }
    }
}

// ---- shared harness, used by every ImClient test in this package ----

internal fun TestScope.newClient(
    gateway: FakeGateway,
    maxAutoRepairSeq: Long = 500,
    store: ImCursorStore = RecordingCursorStore(),
    options: ImOptions = testOptions(maxAutoRepairSeq = maxAutoRepairSeq),
): ImClient = ImClient(
    options = options,
    cursorStore = store,
    socketFactory = gateway,
    parentContext = backgroundScope.coroutineContext,
    // Empty rather than Dispatchers.IO: a real dispatcher would escape the test scheduler's
    // virtual time, and every assertion here is about *when* the store was written.
    cursorStoreContext = EmptyCoroutineContext,
)

internal fun TestScope.collectMessages(client: ImClient): List<ImMessage> {
    val received = mutableListOf<ImMessage>()
    backgroundScope.launch { client.messages.collect { received += it } }
    runCurrent()
    return received
}

internal fun TestScope.collectReloads(client: ImClient): List<String> {
    val reloads = mutableListOf<String>()
    backgroundScope.launch { client.conversationNeedsReload.collect { reloads += it } }
    runCurrent()
    return reloads
}

internal fun TestScope.openClient(client: ImClient, gateway: FakeGateway) {
    backgroundScope.launch { client.connect() }
    runCurrent()
    gateway.latest.opened()
    runCurrent()
    kotlin.test.assertEquals(ConnectionState.Open, client.state.value)
}
