@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

class ImConnectionTest {

    // ------------------------------------------------------------- kick vs. network

    /**
     * Why a kick and a dead network need opposite responses: reconnecting after
     * `MultiLoginPolicy` means fighting the user's other device for the session, forever.
     */
    @Test
    fun `a terminal kick closes for good and never reconnects`() = runTest {
        val gateway = FakeGateway()
        val connection = newConnection(gateway)
        val pushes = mutableListOf<ImFrame>()
        backgroundScope.launch { connection.frames.collect { pushes += it } }
        runCurrent()
        openConnection(connection, gateway)

        gateway.latest.serverClosed(4001, "${KickReason.ClosePrefix}MultiLoginPolicy")
        runCurrent()

        assertEquals(ConnectionState.Closed, connection.state.value)

        advanceTimeBy(5.minutes)
        runCurrent()
        assertEquals(1, gateway.sockets.size, "a terminal kick must not open a second socket")

        val kick = assertNotNull(pushes.singleOrNull())
        assertEquals(PushTarget.Kick, kick.target)
        assertEquals(
            "MultiLoginPolicy",
            kick.body?.data?.jsonObject?.get("reason")?.jsonPrimitive?.content,
        )
    }

    @Test
    fun `every terminal reason is terminal`() = runTest {
        val terminal = listOf("MultiLoginPolicy", "TokenRevoked", "UserBanned", "AppDisabled", "AdminKick")
        for (reason in terminal) {
            val gateway = FakeGateway()
            val connection = newConnection(gateway)
            openConnection(connection, gateway)

            gateway.latest.serverClosed(4001, "${KickReason.ClosePrefix}$reason")
            runCurrent()
            advanceTimeBy(1.minutes)
            runCurrent()

            assertEquals(ConnectionState.Closed, connection.state.value, "$reason should be terminal")
            assertEquals(1, gateway.sockets.size, "$reason must not reconnect")
            connection.close()
        }
    }

    @Test
    fun `a dropped network reconnects after a jittered wait`() = runTest {
        val gateway = FakeGateway()
        val connection = newConnection(gateway)
        openConnection(connection, gateway)

        gateway.latest.networkFailure()
        runCurrent()

        assertEquals(ConnectionState.Reconnecting, connection.state.value)
        assertEquals(1, gateway.sockets.size, "the retry has to wait, not fire immediately")

        // CeilingRandom draws the top of the first window: 999 ms of the 1 s ceiling.
        advanceTimeBy(900.milliseconds)
        runCurrent()
        assertEquals(1, gateway.sockets.size, "still inside the backoff window")

        advanceTimeBy(200.milliseconds)
        runCurrent()
        assertEquals(2, gateway.sockets.size)
    }

    @Test
    fun `an unrecognised kick reason is treated as recoverable`() = runTest {
        val gateway = FakeGateway()
        val connection = newConnection(gateway)
        openConnection(connection, gateway)

        // A reason invented by a server newer than this SDK.
        gateway.latest.serverClosed(4009, "${KickReason.ClosePrefix}RegionMigrated")
        runCurrent()
        advanceTimeBy(2.seconds)
        runCurrent()

        assertEquals(2, gateway.sockets.size, "an unknown reason must not strand the client offline")
    }

    // ---------------------------------------------------------------- token expiry

    @Test
    fun `an expired token is refreshed before reconnecting`() = runTest {
        val gateway = FakeGateway()
        var asked = 0
        val connection = newConnection(gateway, onTokenExpired = { asked++; "token-2" })
        openConnection(connection, gateway)

        gateway.latest.serverClosed(4002, "${KickReason.ClosePrefix}TokenExpired")
        runCurrent()
        advanceTimeBy(2.seconds)
        runCurrent()

        assertEquals(1, asked, "the host app must be asked exactly once")
        assertEquals(2, gateway.sockets.size)
        assertTrue(gateway.urls[0].contains("token=token-1"))
        assertTrue(gateway.urls[1].contains("token=token-2"), "the retry must carry the new token")
    }

    @Test
    fun `a host app that declines to refresh stops the client`() = runTest {
        val gateway = FakeGateway()
        val connection = newConnection(gateway, onTokenExpired = { null })
        openConnection(connection, gateway)

        gateway.latest.serverClosed(4002, "${KickReason.ClosePrefix}TokenExpired")
        runCurrent()
        advanceTimeBy(1.minutes)
        runCurrent()

        assertEquals(ConnectionState.Closed, connection.state.value)
        assertEquals(1, gateway.sockets.size)
    }

    // ------------------------------------------------------------------ foreground

    @Test
    fun `resumeNow skips the remaining backoff`() = runTest {
        val gateway = FakeGateway()
        val connection = newConnection(gateway)
        openConnection(connection, gateway)

        gateway.latest.networkFailure()
        runCurrent()
        advanceTimeBy(100.milliseconds)
        runCurrent()
        assertEquals(1, gateway.sockets.size)

        // The user came back to the app; the other 899 ms of the window are dead time.
        connection.resumeNow()
        runCurrent()
        assertEquals(2, gateway.sockets.size)
    }

    // ---------------------------------------------------------------- multiplexing

    @Test
    fun `replies are matched by id, not by arrival order`() = runTest {
        val gateway = FakeGateway()
        val connection = newConnection(gateway)
        openConnection(connection, gateway)

        val profile = backgroundScope.async {
            connection.request<JsonElement>("user.profile", buildJsonObject { put("userId", "alice") })
        }
        val unread = backgroundScope.async { connection.request<JsonElement>("conv.unreadTotal") }
        runCurrent()

        val requests = gateway.latest.sent
        assertEquals(2, requests.size)

        // Answered in the opposite order, which is normal when two endpoints cost different amounts.
        gateway.latest.deliver(replyTo(requests[1], JsonPrimitive(7)))
        gateway.latest.deliver(replyTo(requests[0], JsonPrimitive("alice")))
        runCurrent()

        assertEquals("alice", profile.await().jsonPrimitive.content)
        assertEquals("7", unread.await().jsonPrimitive.content)
    }

    @Test
    fun `an unanswered request times out and names its target`() = runTest {
        val gateway = FakeGateway()
        val connection = newConnection(gateway)
        openConnection(connection, gateway)

        val call = backgroundScope.async { runCatching { connection.request<JsonElement>("msg.send") } }
        runCurrent()
        advanceTimeBy(16.seconds)
        runCurrent()

        val failure = assertNotNull(call.await().exceptionOrNull() as? ImException)
        assertEquals(ImErrorCode.Timeout, failure.code)
        assertEquals("msg.send", failure.target)
    }

    @Test
    fun `a business error carries its code and traceId`() = runTest {
        val gateway = FakeGateway()
        val connection = newConnection(gateway)
        openConnection(connection, gateway)

        val call = backgroundScope.async { runCatching { connection.request<JsonElement>("msg.send") } }
        runCurrent()

        val request = gateway.latest.sent.single()
        gateway.latest.deliver(
            replyTo(request, JsonPrimitive("rejected"), code = ImErrorCode.ModerationRejected),
        )
        runCurrent()

        val failure = assertNotNull(call.await().exceptionOrNull() as? ImException)
        assertEquals(ImErrorCode.ModerationRejected, failure.code)
        // Both of these are what turns a bug report into a one-query investigation.
        assertEquals("trace-${request.id}", failure.traceId)
        assertEquals("msg.send", failure.target)
        assertFalse(failure.isRetryable, "moderation says no every time")
    }

    @Test
    fun `a request made while the socket is down fails instead of queueing`() = runTest {
        val gateway = FakeGateway()
        val connection = newConnection(gateway)
        openConnection(connection, gateway)

        gateway.latest.networkFailure()
        runCurrent()

        val failure = assertNotNull(
            runCatching { connection.request<JsonElement>("msg.send") }.exceptionOrNull() as? ImException,
        )
        // 1005 ServiceUnavailable, and it never reached the wire.
        assertEquals(ImErrorCode.ServiceUnavailable, failure.code)
        assertTrue(failure.isRetryable)
        assertTrue(gateway.allSent.isEmpty(), "an offline request must not be queued for later")
    }

    @Test
    fun `losing the socket fails every in-flight request`() = runTest {
        val gateway = FakeGateway()
        val connection = newConnection(gateway)
        openConnection(connection, gateway)

        val call = backgroundScope.async { runCatching { connection.request<JsonElement>("msg.history") } }
        runCurrent()

        gateway.latest.networkFailure()
        runCurrent()

        // 1004 Timeout, not 1005 ServiceUnavailable: 1005 would claim the call never reached the
        // server, and we do not know that — the request may well have executed. 1004 is the honest
        // answer and the one that makes a caller reach for clientMsgId idempotency.
        val failure = assertNotNull(call.await().exceptionOrNull() as? ImException)
        assertEquals(ImErrorCode.Timeout, failure.code)
    }

    // ------------------------------------------------------------------- heartbeat

    @Test
    fun `a failed heartbeat forces the half-open socket down and reconnects`() = runTest {
        val gateway = FakeGateway()
        val connection = newConnection(gateway)
        openConnection(connection, gateway)
        val dead = gateway.latest

        // 30 s: the first beat goes out. The socket is half-open, so nothing answers.
        advanceTimeBy(30.seconds + 1.milliseconds)
        runCurrent()
        assertEquals("conn.heartbeat", dead.sent.last().target)
        assertFalse(dead.cancelled)

        // 15 s later the request gives up, and takes the socket with it.
        advanceTimeBy(16.seconds)
        runCurrent()
        assertTrue(dead.cancelled, "a missed beat must abandon the socket, not wait for a close frame")

        advanceTimeBy(1.seconds)
        runCurrent()
        assertEquals(2, gateway.sockets.size)
    }

    @Test
    fun `the server owns the heartbeat cadence`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            if (request.target == "conn.heartbeat") {
                replyTo(request, buildJsonObject { put("serverTime", 1L); put("intervalSeconds", 5) })
            } else {
                null
            }
        }
        val connection = newConnection(gateway)
        openConnection(connection, gateway)

        advanceTimeBy(30.seconds + 1.milliseconds)
        runCurrent()
        assertEquals(1, gateway.latest.requestsTo("conn.heartbeat").size)

        // The server said 5 s, so the next beat is 5 s away — not 30.
        advanceTimeBy(5.seconds + 1.milliseconds)
        runCurrent()
        assertEquals(2, gateway.latest.requestsTo("conn.heartbeat").size)
    }

    // ------------------------------------------------------------------- lifecycle

    @Test
    fun `the handshake carries everything the gateway authenticates on`() = runTest {
        val gateway = FakeGateway()
        val connection = newConnection(gateway)
        openConnection(connection, gateway)

        val url = gateway.urls.single()
        assertTrue(url.startsWith("wss://im.example.com/im?"), url)
        assertTrue(url.contains("appId=app-1"), url)
        assertTrue(url.contains("token=token-1"), url)
        assertTrue(url.contains("deviceId=device-1"), url)
        assertTrue(url.contains("platform=${Platform.Android.code}"), url)
        assertTrue(url.contains("v=1"), url)
    }

    @Test
    fun `close is terminal and fails what was in flight`() = runTest {
        val gateway = FakeGateway()
        val connection = newConnection(gateway)
        openConnection(connection, gateway)

        val call = backgroundScope.async { runCatching { connection.request<JsonElement>("msg.history") } }
        runCurrent()

        connection.close()
        runCurrent()

        assertEquals(ConnectionState.Closed, connection.state.value)
        val failure = assertNotNull(call.await().exceptionOrNull() as? ImException)
        assertEquals(ImErrorCode.Timeout, failure.code)
        assertEquals(OkHttpSocketFactory.NORMAL_CLOSURE, gateway.sockets.single().closedWith?.first)

        advanceTimeBy(1.minutes)
        runCurrent()
        assertEquals(1, gateway.sockets.size)
    }

    // --------------------------------------------------------------------- helpers

    private fun TestScope.newConnection(
        gateway: FakeGateway,
        onTokenExpired: (suspend () -> String?)? = null,
        random: Random = CeilingRandom(),
    ): ImConnection = ImConnection(
        options = testOptions(onTokenExpired = onTokenExpired),
        socketFactory = gateway,
        parentContext = backgroundScope.coroutineContext,
        random = random,
        clock = { 1_700_000_000_000L },
    )

    private fun TestScope.openConnection(connection: ImConnection, gateway: FakeGateway) {
        backgroundScope.launch { connection.connect() }
        runCurrent()
        gateway.latest.opened()
        runCurrent()
        assertEquals(ConnectionState.Open, connection.state.value)
    }
}
