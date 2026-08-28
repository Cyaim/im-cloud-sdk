@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * CONTRACT.md §7: two layers of envelope collapsed onto one exception, and the handful of
 * classification rules all five SDKs have to agree on.
 */
class ErrorsTest {

    /**
     * The row of §7.2 that is a choice rather than a deduction, and the one that costs a support
     * cycle when it is wrong: an SDK newer than a private-deployment server must be able to say
     * "this deployment does not have that endpoint", not "not found".
     */
    @Test
    fun `an unroutable target maps to UnsupportedOperation, not NotFound`() = runTest {
        val gateway = FakeGateway()
        val connection = testConnection(gateway)
        openConnection(connection, gateway)

        val call = backgroundScope.async { runCatching { connection.request<JsonElement>("group.setRole") } }
        runCurrent()

        val request = gateway.latest.sent.single()
        gateway.latest.deliver(
            buildJsonObject {
                put("id", request.id)
                put("target", request.target)
                put("status", 2)
                put("msg", "endpoint not found")
            },
        )
        runCurrent()

        val failure = assertNotNull(call.await().exceptionOrNull() as? ImException)
        assertEquals(ImErrorCode.UnsupportedOperation, failure.code)
        assertEquals("group.setRole", failure.target)
        assertTrue(
            failure.message.orEmpty().contains("group.setRole"),
            "the message has to name the target: ${failure.message}",
        )
    }

    @Test
    fun `an endpoint that threw maps to InternalError and quotes the transport message`() = runTest {
        val gateway = FakeGateway()
        val connection = testConnection(gateway)
        openConnection(connection, gateway)

        val call = backgroundScope.async { runCatching { connection.request<JsonElement>("msg.send") } }
        runCurrent()

        val request = gateway.latest.sent.single()
        gateway.latest.deliver(
            buildJsonObject {
                put("id", request.id)
                put("target", request.target)
                put("status", 1)
                put("msg", "NullReferenceException in MessageService")
            },
        )
        runCurrent()

        val failure = assertNotNull(call.await().exceptionOrNull() as? ImException)
        assertEquals(ImErrorCode.InternalError, failure.code)
        assertEquals("NullReferenceException in MessageService", failure.message)
        assertTrue(failure.isRetryable)
    }

    /**
     * Both flags are computed from the code alone, so this is the table itself and not a
     * behavioural test. It exists because five SDKs disagreeing about whether `1003` is retryable
     * is the kind of drift nobody notices until a customer compares two platforms.
     */
    @Test
    fun `retry classification matches the contract table`() {
        val retryable = listOf(
            ImErrorCode.InternalError,
            ImErrorCode.RateLimited,
            ImErrorCode.Timeout,
            ImErrorCode.ServiceUnavailable,
        )
        for (code in retryable) {
            assertTrue(ImErrorCode.isRetryable(code), "$code should be retryable")
        }

        val terminal = listOf(
            ImErrorCode.InvalidArgument, ImErrorCode.NotFound, ImErrorCode.Conflict,
            ImErrorCode.PayloadTooLarge, ImErrorCode.UnsupportedOperation,
            ImErrorCode.Unauthorized, ImErrorCode.TokenExpired, ImErrorCode.TokenInvalid,
            ImErrorCode.Forbidden, ImErrorCode.UserBanned, ImErrorCode.KickedByOtherDevice,
            ImErrorCode.QuotaExceeded, ImErrorCode.FeatureNotEnabled, ImErrorCode.PlanExpired,
            ImErrorCode.ModerationRejected, ImErrorCode.NotGroupMember, ImErrorCode.MemberMuted,
        )
        for (code in terminal) {
            assertFalse(ImErrorCode.isRetryable(code), "$code must not be retryable")
        }

        for (code in listOf(ImErrorCode.Unauthorized, ImErrorCode.TokenExpired, ImErrorCode.TokenInvalid)) {
            assertTrue(ImErrorCode.requiresReauth(code), "$code needs a fresh token")
        }

        // Also in the 1100 band, and a fresh token fixes neither.
        for (code in listOf(ImErrorCode.Forbidden, ImErrorCode.UserBanned, ImErrorCode.KickedByOtherDevice)) {
            assertFalse(ImErrorCode.requiresReauth(code), "$code is not a token problem")
        }
    }

    /**
     * A cancellation path that leaves its entry in the pending map is a leak that grows for the
     * life of the connection — invisible until a long-lived client runs out of memory.
     */
    @Test
    fun `cancelling a call removes its pending entry and raises CancellationException`() = runTest {
        val gateway = FakeGateway()
        val connection = testConnection(gateway)
        openConnection(connection, gateway)

        var thrown: Throwable? = null
        val call = backgroundScope.launch {
            try {
                connection.request<JsonElement>("msg.history")
            } catch (failure: Throwable) {
                thrown = failure
            }
        }
        runCurrent()
        assertEquals(1, connection.pendingRequestCount)

        call.cancel()
        runCurrent()

        assertEquals(0, connection.pendingRequestCount, "the pending entry must not outlive the call")
        assertTrue(
            thrown is CancellationException,
            "cancellation is not a server outcome and must not become an ImException: $thrown",
        )
    }

    /**
     * `1203 FeatureNotEnabled` is a runtime tenant switch, not a property of the deployment. A
     * client that remembers "typing is off" stays broken until the app restarts — including after
     * the tenant turns it back on.
     */
    @Test
    fun `feature-not-enabled is reported every time and never latched`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "msg.typing" -> replyTo(request, JsonNull, code = ImErrorCode.FeatureNotEnabled)
                else -> null
            }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        repeat(2) {
            val failure = runCatching { client.msg.typing("c1", true) }.exceptionOrNull() as? ImException
            assertEquals(ImErrorCode.FeatureNotEnabled, assertNotNull(failure).code)
            runCurrent()
        }

        assertEquals(
            2,
            gateway.latest.requestsTo("msg.typing").size,
            "the second call must still reach the wire; the tenant can flip the flag at runtime",
        )
    }

    /**
     * §7.4: an expired token is renewed on the socket we already have, and the failed call is
     * retried once. A reconnect is exactly what you were trying to avoid on the flaky network
     * where this happens.
     */
    @Test
    fun `an expired token is renewed in place and the call is retried once`() = runTest {
        val gateway = FakeGateway()
        var asked = 0
        var sends = 0
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "conn.reauth" -> replyTo(request, JsonNull)
                "msg.send" -> {
                    sends += 1
                    if (sends == 1) {
                        replyTo(request, JsonNull, code = ImErrorCode.TokenExpired)
                    } else {
                        replyTo(
                            request,
                            buildJsonObject {
                                put("messageId", 7)
                                put("seq", 7)
                                put("conversationId", "c1")
                            },
                        )
                    }
                }
                else -> null
            }
        }

        val connection = testConnection(
            gateway,
            options = testOptions(onTokenExpired = { asked += 1; "token-2" }),
        )
        openConnection(connection, gateway)

        val result = backgroundScope.async {
            connection.request<SendMessageResult>("msg.send", buildJsonObject { put("clientMsgId", "x") })
        }
        runCurrent()

        assertEquals(7L, result.await().seq)
        assertEquals(1, asked, "the host app is asked exactly once")
        assertEquals(1, gateway.latest.requestsTo("conn.reauth").size)
        assertEquals("token-2", gateway.latest.requestsTo("conn.reauth").single().bodyString("token"))
        assertEquals(2, gateway.latest.requestsTo("msg.send").size, "retried once, not twice")
        assertEquals(1, gateway.sockets.size, "renewing a token must not cost a reconnect")
    }

    @Test
    fun `a refused renewal surfaces the original failure`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "conn.reauth" -> replyTo(request, JsonNull, code = ImErrorCode.TokenInvalid)
                else -> replyTo(request, JsonNull, code = ImErrorCode.TokenExpired)
            }
        }
        val connection = testConnection(gateway, options = testOptions(onTokenExpired = { "token-2" }))
        openConnection(connection, gateway)

        val call = backgroundScope.async { runCatching { connection.request<JsonElement>("user.me") } }
        runCurrent()

        val failure = assertNotNull(call.await().exceptionOrNull() as? ImException)
        assertEquals(ImErrorCode.TokenExpired, failure.code)
        assertTrue(failure.requiresReauth)
    }

    @Test
    fun `numbers that arrive as JSON strings still decode`() {
        // NumberHandling.AllowReadingFromString is set server-side, so a 64-bit seq can and does
        // arrive quoted. A decoder that throws here takes the whole conversation down.
        val message = ImJson.decodeFromString(
            ImMessage.serializer(),
            """{"conversationId":"c1","seq":"9007199254740993","messageId":"42","contentType":"1"}""",
        )
        assertEquals(9_007_199_254_740_993L, message.seq)
        assertEquals(42L, message.messageId)
        assertEquals(MessageContentType.Text, message.contentType)
    }

    @Test
    fun `an unknown enum member keeps its raw value instead of collapsing to Unknown`() {
        val message = ImJson.decodeFromString(
            ImMessage.serializer(),
            """{"conversationId":"c1","contentType":777}""",
        )
        // Not MessageContentType.Unknown: 777 is what the support ticket needs, and it is also
        // what has to go back on the wire unchanged if this message is ever re-encoded.
        assertEquals(777, message.contentType.code)
        assertEquals("MessageContentType(777)", message.contentType.toString())
        assertTrue(ImJson.encodeToString(ImMessage.serializer(), message).contains("\"contentType\":777"))
    }

    @Test
    fun `a field the server stopped sending does not break decoding`() {
        val view = ImJson.decodeFromString(ConversationView.serializer(), """{"conversationId":"c1"}""")
        assertEquals("c1", view.conversationId)
        assertEquals(MuteMode.Normal, view.muted)
        assertEquals(0L, view.unreadCount)
        assertEquals(null, view.lastMessage)
    }

    @Test
    fun `an unrecognised field does not break decoding`() {
        val view = ImJson.decodeFromString(
            ConversationView.serializer(),
            """{"conversationId":"c1","somethingTheGatewayAddedLastTuesday":{"a":1}}""",
        )
        assertEquals("c1", view.conversationId)
    }

    @Test
    fun `a page shorter than its limit is still a page with more`() {
        // The shape that makes `items.size < limit` a wrong stop condition.
        val page = ImJson.decodeFromString(
            Page.serializer(ConversationView.serializer()),
            """{"items":[{"conversationId":"c1"}],"hasMore":true,"nextCursor":"c2","total":"41"}""",
        )
        assertEquals(1, page.items.size)
        assertTrue(page.hasMore)
        assertEquals("c2", page.nextCursor)
        assertEquals(41L, page.total)
    }

    @Test
    fun `the error carries everything a support ticket needs`() {
        val failure = ImException(
            code = ImErrorCode.RateLimited,
            message = "too many",
            traceId = "trace-1",
            target = "msg.search",
        )
        assertTrue(failure.isRetryable)
        assertFalse(failure.requiresReauth)
        assertTrue(failure.toString().contains("trace-1"))
        assertTrue(failure.toString().contains("msg.search"))
    }
}
