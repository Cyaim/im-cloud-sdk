@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * CONTRACT.md §7.6: for a given conversation, messages reach the application in `seq` order and
 * never concurrently with each other. Everything else in that section serves this one rule.
 */
class DeliveryOrderTest {

    private fun gateway(): FakeGateway = FakeGateway().apply {
        onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "msg.sync" -> {
                    val from = request.bodyLong("fromSeq")
                    val to = request.bodyLong("toSeq")
                    // Deliberately out of order on the wire: the SDK is the thing that sorts.
                    syncPage(request, request.bodyString("conversationId"), (from..to).toList().reversed())
                }
                "msg.typing" -> replyTo(request, JsonNull)
                else -> null
            }
        }
    }

    /** `messagesArriveInSeqOrder` — including across a gap repair. */
    @Test
    fun `messages arrive in seq order, including the ones a repair pulled back`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway, store = RecordingCursorStore(ImCursorSnapshot(mapOf("c1" to 1L))))
        val received = collectMessages(client)
        openClient(client, gateway)

        gateway.latest.push(PushTarget.Message, messageJson("c1", 7))
        runCurrent()
        gateway.latest.push(PushTarget.Message, messageJson("c1", 8))
        runCurrent()

        assertEquals((2L..8L).toList(), received.map { it.seq })
    }

    /**
     * A live message that arrives while a repair for the same conversation is still in flight has
     * to wait behind it, or the application sees the conversation jump forward and then fill in
     * behind — the exact shape this SDK exists to prevent.
     */
    @Test
    fun `a live message that lands mid-repair is held until the repair finishes`() = runTest {
        val gateway = FakeGateway()
        var syncRequest: JsonObject? = null
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                // Hold the repair open: no reply until the test says so.
                "msg.sync" -> { syncRequest = request; null }
                else -> null
            }
        }

        val client = newClient(gateway, store = RecordingCursorStore(ImCursorSnapshot(mapOf("c1" to 1L))))
        val received = collectMessages(client)
        openClient(client, gateway)

        gateway.latest.push(PushTarget.Message, messageJson("c1", 5))
        runCurrent()
        assertTrue(received.isEmpty(), "seq 5 waits behind the repair of 2..4")

        // Seq 6 arrives while the repair is still open. It must not overtake anything.
        gateway.latest.push(PushTarget.Message, messageJson("c1", 6))
        runCurrent()
        assertTrue(received.isEmpty())

        gateway.latest.deliver(syncPage(checkNotNull(syncRequest), "c1", listOf(2L, 3L, 4L)))
        runCurrent()

        assertEquals(listOf(2L, 3L, 4L, 5L, 6L), received.map { it.seq })
    }

    /**
     * `throwingListenerDoesNotStopDelivery`.
     *
     * One application bug in one handler must not stop delivery for every conversation, and must
     * never lose a cursor.
     */
    @Test
    fun `a collector that throws does not stop the pump`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        val survivor = mutableListOf<Long>()
        var thrownAt: Long? = null

        // Flow semantics differ from a callback SDK here, and the difference is worth being
        // explicit about: a collector that throws ends *its own* collection, because that is what
        // `collect` means in Kotlin. What must not happen is the SDK's pump stopping with it — the
        // other collectors keep receiving, and the cursor keeps moving, which is what the second
        // half of this test checks.
        backgroundScope.launch {
            try {
                client.messages.collect { message ->
                    if (message.seq == 2L) {
                        thrownAt = message.seq
                        throw IllegalStateException("the application has a bug")
                    }
                }
            } catch (contained: IllegalStateException) {
                // The application's bug, contained to the application's coroutine.
            }
        }
        backgroundScope.launch { client.messages.collect { survivor += it.seq } }
        runCurrent()
        openClient(client, gateway)

        for (seq in 1L..4L) {
            gateway.latest.push(PushTarget.Message, messageJson("c1", seq))
            runCurrent()
        }

        assertEquals(2L, thrownAt)
        assertEquals(listOf(1L, 2L, 3L, 4L), survivor, "the other collector saw everything")
        assertTrue(
            gateway.latest.requestsTo("msg.sync").isEmpty(),
            "the cursor advanced past the message that blew up, so seq 3 was not a false gap",
        )
    }

    /**
     * `reentrantCallFromListenerDoesNotDeadlock`.
     *
     * Calling back into the SDK from inside a collector is the single most natural thing an
     * application does — mark read on receipt, commit on receipt — and an SDK that deadlocks on it
     * is unusable.
     */
    @Test
    fun `calling back into the SDK from a collector does not deadlock`() = runTest {
        val gateway = gateway()
        val store = RecordingCursorStore()
        val client = newClient(gateway, store = store)
        val committed = mutableListOf<Long>()

        backgroundScope.launch {
            client.messages.collect { message ->
                // Two reentrant calls: one that writes state, one that goes to the wire.
                client.commit(message.conversationId, message.seq)
                client.msg.typing(message.conversationId, typing = false)
                committed += message.seq
            }
        }
        runCurrent()
        openClient(client, gateway)

        gateway.latest.push(PushTarget.Message, messageJson("c1", 1))
        runCurrent()
        gateway.latest.push(PushTarget.Message, messageJson("c1", 2))
        runCurrent()

        assertEquals(listOf(1L, 2L), committed)
        assertEquals(2L, store.held.convSeqs["c1"])
        assertEquals(2, gateway.latest.requestsTo("msg.typing").size)
    }

    @Test
    fun `two conversations are delivered independently and neither blocks the other`() = runTest {
        val gateway = FakeGateway()
        var held: JsonObject? = null
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "msg.sync" -> if (request.bodyString("conversationId") == "c1") {
                    held = request
                    null
                } else {
                    syncPage(request, "c2", listOf(2L))
                }
                else -> null
            }
        }

        val client = newClient(
            gateway,
            store = RecordingCursorStore(ImCursorSnapshot(mapOf("c1" to 1L, "c2" to 1L))),
        )
        val received = collectMessages(client)
        openClient(client, gateway)

        gateway.latest.push(PushTarget.Message, messageJson("c1", 3))
        gateway.latest.push(PushTarget.Message, messageJson("c2", 3))
        runCurrent()

        // c1 is stuck waiting for its repair; c2 finished anyway.
        assertEquals(listOf(2L, 3L), received.filter { it.conversationId == "c2" }.map { it.seq })
        assertTrue(received.none { it.conversationId == "c1" })

        gateway.latest.deliver(syncPage(checkNotNull(held), "c1", listOf(2L)))
        runCurrent()
        assertEquals(listOf(2L, 3L), received.filter { it.conversationId == "c1" }.map { it.seq })
    }
}
