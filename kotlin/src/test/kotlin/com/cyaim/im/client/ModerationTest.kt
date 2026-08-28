@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * `moderation.report` — the half of app-store review that `friend.block` does not cover.
 *
 * Two of these are about what is *not* on the wire. The reporter is the connection, and a message
 * id leaves quoted; both are properties a reader cannot check by looking at the call site, which is
 * exactly why they are asserted on the frame.
 */
class ModerationTest {

    /** An id past 2^53, with zero sequence bits — the shape the server measured in production. */
    private val bigId = 350_598_345_233_801_216L

    private fun gateway(): FakeGateway = FakeGateway().apply {
        onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "moderation.report" -> replyTo(
                    request,
                    buildJsonObject {
                        put("reportId", "rp_7f3c")
                        put("createdAt", 1_700_000_000_000L)
                    },
                )
                else -> null
            }
        }
    }

    @Test
    fun `a report carries no reporter and quotes the message id`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val call = backgroundScope.async {
            client.moderation.report(
                SubmitReportRequest(
                    targetUserId = "mallory",
                    conversationId = "s_alice_mallory",
                    messageId = bigId,
                    category = ReportCategory.Harassment,
                    note = "kept messaging after being asked to stop",
                ),
            )
        }
        runCurrent()

        val sent = gateway.latest.requestsTo("moderation.report").single()
        assertEquals("mallory", sent.bodyString("targetUserId"))
        assertEquals("harassment", sent.bodyString("category"))

        // The reporter comes from the socket. A field for it would let an account file in another's
        // name, which is both a way to get somebody banned and a way to poison a moderator's count.
        assertEquals(null, sent.bodyStringOrNull("reporterId"))
        assertEquals(null, sent.bodyStringOrNull("userId"))

        val messageId = sent.body.getValue("messageId").jsonPrimitive
        assertTrue(
            messageId.isString,
            "the id has to leave quoted: as a JSON number this one is 38 times past what a " +
                "JavaScript client can hold, and the platform writes every message id as a string",
        )
        assertEquals(bigId.toString(), messageId.content)

        val receipt = call.await()
        assertEquals("rp_7f3c", receipt.reportId)
        assertEquals(1_700_000_000_000L, receipt.createdAt)
    }

    /**
     * Reporting the account rather than one message is the default, and it is the case a "report
     * this user" button in a profile screen sends.
     */
    @Test
    fun `a report about nothing in particular still names the account`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val call = backgroundScope.async {
            client.moderation.report(SubmitReportRequest(targetUserId = "mallory"))
        }
        runCurrent()

        val sent = gateway.latest.requestsTo("moderation.report").single()
        assertEquals("0", sent.body.getValue("messageId").jsonPrimitive.content)
        assertEquals("other", sent.bodyString("category"), "the server's own default, said out loud")
        assertEquals("rp_7f3c", call.await().reportId)
    }

    /**
     * Reporting yourself is refused, and it reaches the caller as an exception like any other
     * business code — this endpoint has no "partly succeeded" answer to swallow.
     */
    @Test
    fun `a refused report throws rather than returning an empty receipt`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "moderation.report" -> replyTo(request, JsonNull, code = ImErrorCode.InvalidArgument)
                else -> null
            }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        val call = backgroundScope.async {
            runCatching { client.moderation.report(SubmitReportRequest(targetUserId = "alice")) }
        }
        runCurrent()

        val failure = assertNotNull(call.await().exceptionOrNull() as? ImException)
        assertEquals(ImErrorCode.InvalidArgument, failure.code)
        assertEquals("moderation.report", failure.target)
    }
}
