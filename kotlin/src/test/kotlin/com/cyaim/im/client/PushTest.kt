@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonNull
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/**
 * CONTRACT.md §6.
 *
 * The server side of offline push shipped and **no SDK called it**, so offline notifications — the
 * feature every mobile deal turns on — were unreachable from any official client. These are the
 * three rules that make it work rather than nearly work.
 */
class PushTest {

    private fun gateway(): FakeGateway = FakeGateway().apply {
        onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "push.register", "push.unregister", "push.clicked" -> replyTo(request, JsonNull)
                else -> null
            }
        }
    }

    /**
     * `registersOnEveryConnect`.
     *
     * Not once at install. The vendor may replace a token while the process is frozen and the
     * server has no other way to learn it; re-registering an unchanged one costs no write, because
     * the server debounces it.
     */
    @Test
    fun `three connects produce three push registrations`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        client.push.setToken(PushProvider.Fcm, "token-abc")
        openClient(client, gateway)

        repeat(2) {
            gateway.latest.networkFailure()
            runCurrent()
            advanceTimeBy(2.seconds)
            runCurrent()
            gateway.latest.opened()
            runCurrent()
        }

        val registrations = gateway.allSent.filter { it.target == "push.register" }
        assertEquals(3, registrations.size, "one per successful connect")
        assertTrue(registrations.all { it.bodyString("token") == "token-abc" })
        assertTrue(registrations.all { it.bodyString("provider") == "fcm" })
        assertTrue(client.push.isRegistered)
    }

    /**
     * The Android rule: the provider always travels explicitly. The server's empty-provider
     * fallback is only reliable on iOS, and Android fragments across five OEM channels it cannot
     * guess between.
     */
    @Test
    fun `an OEM channel is sent as the channel it is`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        client.push.setToken(PushProvider.Huawei, "hms-token", language = "zh-CN")
        openClient(client, gateway)

        val registration = gateway.latest.requestsTo("push.register").single()
        assertEquals("huawei", registration.bodyString("provider"))
        assertEquals("zh-CN", registration.bodyString("language"))
        // Identity comes from the socket. There is no field here in which to claim someone else's.
        assertEquals(null, registration.bodyStringOrNull("userId"))
        assertEquals(null, registration.bodyStringOrNull("deviceId"))
    }

    /**
     * `unregisterPrecedesDisconnect`.
     *
     * After the socket closes there is no authenticated channel and the token cannot be removed at
     * all — only the tenant backend can then clean it up. So the order is not a nicety.
     */
    @Test
    fun `logout unregisters before it closes the socket`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        client.push.setToken(PushProvider.Fcm, "token-abc")
        openClient(client, gateway)

        val socket = gateway.latest
        assertEquals(null, socket.closedWith)

        client.logout()
        runCurrent()

        assertEquals(
            "push.unregister",
            socket.sent.last().target,
            "the last frame on the wire must be the unregister, not whatever preceded the close",
        )
        assertEquals(OkHttpSocketFactory.NORMAL_CLOSURE, socket.closedWith?.first)
        assertEquals(null, client.push.token, "the device has said it no longer wants push")
    }

    @Test
    fun `disconnecting on its own never unregisters`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        client.push.setToken(PushProvider.Fcm, "token-abc")
        openClient(client, gateway)

        val socket = gateway.latest
        client.close()
        runCurrent()

        assertTrue(
            socket.requestsTo("push.unregister").isEmpty(),
            "a dead socket is precisely the state offline push exists to serve",
        )
    }

    /** `tokenRefreshWhileOfflineRegistersOnNextConnect`. */
    @Test
    fun `a token handed over while offline is registered on the next connect`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        assertTrue(gateway.latest.requestsTo("push.register").isEmpty(), "there was no token to send")

        gateway.latest.networkFailure()
        runCurrent()

        // FirebaseMessagingService.onNewToken, while the socket is down.
        client.push.setToken(PushProvider.Fcm, "refreshed")
        assertTrue(!client.push.isRegistered)

        advanceTimeBy(2.seconds)
        runCurrent()
        gateway.latest.opened()
        runCurrent()

        assertEquals("refreshed", gateway.latest.requestsTo("push.register").single().bodyString("token"))
        assertTrue(client.push.isRegistered)
    }

    /**
     * A silently unregistered device is indistinguishable from a broken push provider, and that
     * misdiagnosis costs a support cycle every time.
     */
    @Test
    fun `holding a token without registering it is said out loud`() = runTest {
        val gateway = gateway()
        val logger = RecordingLogger()
        val client = newClient(
            gateway,
            options = testOptions(logger = logger, autoRegisterPushToken = false),
        )
        client.push.setToken(PushProvider.Fcm, "token-abc")
        openClient(client, gateway)

        assertTrue(gateway.latest.requestsTo("push.register").isEmpty())
        assertTrue(
            logger.atLeast(ImLogLevel.Warn).any { it.contains("§6.2") },
            "the warning has to name the rule: ${logger.lines}",
        )
    }

    @Test
    fun `a failed registration is logged and does not take the session down`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "push.register" -> replyTo(request, JsonNull, code = ImErrorCode.FeatureNotEnabled)
                else -> null
            }
        }
        val logger = RecordingLogger()
        val client = newClient(gateway, options = testOptions(logger = logger))
        client.push.setToken(PushProvider.Fcm, "token-abc")
        openClient(client, gateway)

        assertEquals(ConnectionState.Open, client.state.value)
        assertTrue(!client.push.isRegistered)
        assertTrue(logger.atLeast(ImLogLevel.Warn).any { it.contains("push.register failed") })
    }

    /**
     * The tap report carries what the payload gave it and nothing else — the identity is the
     * socket's, so there is no field here to claim another user's notification with.
     */
    @Test
    fun `a notification tap reports the message id the payload carried`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val call = backgroundScope.async {
            client.push.clicked(PushClickedRequest(messageId = "350598345233801216"))
        }
        runCurrent()
        call.await()

        val clicked = gateway.latest.requestsTo("push.clicked").single()
        assertEquals("350598345233801216", clicked.bodyString("messageId"))
        assertEquals(null, clicked.bodyStringOrNull("userId"))
        assertEquals(null, clicked.bodyStringOrNull("deviceId"))
    }

    /**
     * Best-effort statistics. `2401 PushDeliveryNotFound` is what a tap on a notification older
     * than the seven-day retention answers — nobody's fault, and no application should have to
     * write a `catch` for a click count that is one short. It is also not retried: a second frame
     * would cost the socket a round trip the user is waiting behind, to fix a number.
     */
    @Test
    fun `a click the server cannot match is not raised to the application`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "push.clicked" -> replyTo(request, JsonNull, code = ImErrorCode.PushDeliveryNotFound)
                else -> null
            }
        }
        val logger = RecordingLogger()
        val client = newClient(gateway, options = testOptions(logger = logger))
        openClient(client, gateway)

        val call = backgroundScope.async { runCatching { client.push.clicked() } }
        runCurrent()

        assertEquals(null, call.await().exceptionOrNull(), "an expired delivery row is not the caller's problem")
        assertEquals(1, gateway.latest.requestsTo("push.clicked").size, "never retried")
        assertTrue(
            logger.lines.any { it.first == ImLogLevel.Debug && it.second.contains("push.clicked") },
            "invisible by default, but there for whoever is looking at a funnel: ${logger.lines}",
        )
    }
}
