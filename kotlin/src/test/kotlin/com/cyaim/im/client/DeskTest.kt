@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `desk.*` — the nine customer-service verbs, and the `evt.desk` frame.
 *
 * Every verb is asserted on the frame it puts on the wire — target and the whole body, by JSON kind
 * — and on what it makes of a representative reply. Three properties carry the weight and none is
 * visible from a signature: a transfer names exactly one target, an absent optional member is not the
 * same as one set to a value (`inviteRating` omitted *invites*), and `endReason` is a string where
 * its neighbour `state` is an integer.
 *
 * 每个动词都断言它发出的整帧（target 与按 JSON 类型的请求体），以及它对一个代表性答复的解码。
 */
class DeskTest {

    private fun session(full: Boolean): JsonObject = buildJsonObject {
        put("sessionId", "ds_1")
        put("appId", "demo")
        put("customerId", "v_01hh")
        put("conversationId", "s_desk_v_01hh")
        put("state", if (full) 1 else 0)
        put("priority", if (full) 3 else 0)
        put("queuedAt", 1_755_000_000_000L)
        if (full) {
            // Every member of the server's DeskSession, each with a value no default reads as — so a
            // key spelled wrong on this side decodes to null or a default and an assertion below fails.
            // `the full fixtures carry every member the server declares` holds the list to the inventory.
            put("agentId", "a_7")
            put("skill", "billing")
            put("assignedAt", 1_755_000_060_000L)
            put("closedAt", 1_755_000_900_000L)
            put("resolution", "refunded")
            putJsonObject("context") { put("desk.channel", "app") }
            putJsonArray("history") { add(JsonPrimitive("a_3")) }
            put("firstAgentMessageAt", 1_755_000_070_000L)
            put("rating", 4)
            put("ratingInvitedAt", 1_755_000_910_000L)
            put("ratingComment", "quick")
            put("ratedAt", 1_755_000_920_000L)
            put("channel", "app")
            put("visitorId", "v_01hh")
            put("deskId", "dk_1")
            put("groupId", "g_billing")
            put("disposition", "resolved")
            put("ratingReason", "slow at first")
            putJsonArray("ratingTags") { add(JsonPrimitive("polite")) }
            put("snoozedUntil", 1_755_001_000_000L)
            putJsonObject("summary") {
                put("issue", "refund")
                put("state", "waiting on finance")
                put("nextStep", "check the order")
                put("generatedAt", 1_755_000_050_000L)
                put("model", "demo/model")
            }
            putJsonArray("tags") { add(JsonPrimitive("billing/refund")) }
            put("endReason", "bot-handoff")
            put("ratingResolved", false)
            put("star", true)
            putJsonArray("responseSamples") {
                add(buildJsonObject {
                    put("customerAt", 1L)
                    put("agentAt", 2L)
                    put("agentId", "a_7")
                })
            }
        }
    }

    private fun queueView(measured: Boolean): JsonObject = buildJsonObject {
        put("waiting", 3)
        put("assigned", 2)
        put("availableAgents", 1)
        put("headWaitSeconds", 95)
        if (measured) put("avgFirstResponseSeconds", 12.5)
        putJsonObject("waitingBySkill") { put("billing", 3) }
    }

    private fun cannedRow(): JsonObject = buildJsonObject {
        put("id", "cr_1")
        put("title", "Refunds")
        put("content", "Refunds take 3–5 days.")
        put("skill", "billing")
        put("scope", "personal")
        put("folder", "refunds")
        put("ownerMemberId", "m_1")
        put("updatedAt", 1_755_000_000_000L)
    }

    private fun gateway(): FakeGateway = FakeGateway().apply {
        onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "desk.request" -> replyTo(request, session(full = false))
                "desk.accept" -> replyTo(request, session(full = true))
                "desk.queue" -> replyTo(request, queueView(measured = false))
                "desk.canned" -> replyTo(
                    request,
                    buildJsonArray {
                        add(cannedRow())
                        add(buildJsonObject {
                            put("id", "cr_2")
                            put("title", "Hello")
                            put("content", "Hi!")
                            put("scope", "all")
                            put("updatedAt", 1L)
                        })
                    },
                )
                "desk.suggest" -> replyTo(request, buildJsonArray { add(JsonPrimitive("Sure — one moment.")) })
                "desk.transfer", "desk.close", "desk.status", "desk.rate" -> replyTo(request, JsonNull)
                else -> null
            }
        }
    }

    private suspend fun <T> kotlinx.coroutines.test.TestScope.settle(block: suspend () -> T): T {
        val call = backgroundScope.async { block() }
        runCurrent()
        return call.await()
    }

    @Test
    fun `desk request sends an empty body by default and decodes a queued session with its absences`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val queued = settle { client.desk.request() }
        val bare = gateway.latest.requestsTo("desk.request").single().body
        assertEquals(JsonObject(emptyMap()), bare, "the plain button sends nothing: $bare")

        assertEquals("ds_1", queued.sessionId)
        assertEquals(DeskSessionState.Queued, queued.state)
        assertNull(queued.agentId, "absent while queued")
        assertNull(queued.endReason)
        assertNull(queued.summary)
        assertEquals(emptyList(), queued.tags)
        assertFalse(queued.star)
        assertNull(queued.ratingResolved)

        settle {
            client.desk.request(
                DeskRequest(skill = "billing", priority = 2, context = buildJsonObject { put("desk.page", "/orders/9") }),
            )
        }
        val full = gateway.latest.requestsTo("desk.request").last().body
        assertEquals(setOf("skill", "priority", "context"), full.keys)
        assertEquals("billing", full.jsonString("skill"))
        assertEquals(2L, full.jsonInteger("priority"))
        assertEquals("/orders/9", full.getValue("context").jsonObject.jsonString("desk.page"))
    }

    @Test
    fun `desk accept names the session or nothing, and decodes every product field`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle { client.desk.accept() }
        val taken = settle { client.desk.accept(DeskAcceptRequest("ds_1")) }

        val (next, named) = gateway.latest.requestsTo("desk.accept").map { it.body }
        assertEquals(JsonObject(emptyMap()), next, "\"give me the next\" names no session")
        assertEquals(setOf("sessionId"), named.keys)
        assertEquals("ds_1", named.jsonString("sessionId"))

        assertEquals("ds_1", taken.sessionId)
        assertEquals("demo", taken.appId)
        assertEquals("v_01hh", taken.customerId)
        assertEquals("a_7", taken.agentId)
        assertEquals("s_desk_v_01hh", taken.conversationId)
        assertEquals(DeskSessionState.Assigned, taken.state)
        assertEquals("billing", taken.skill)
        assertEquals(3, taken.priority)
        assertEquals(1_755_000_000_000L, taken.queuedAt)
        assertEquals(1_755_000_060_000L, taken.assignedAt)
        assertEquals(1_755_000_900_000L, taken.closedAt)
        assertEquals("refunded", taken.resolution)
        assertEquals("app", taken.context?.getValue("desk.channel")?.jsonPrimitive?.content)
        assertEquals(listOf("a_3"), taken.history)
        assertEquals(1_755_000_070_000L, taken.firstAgentMessageAt)
        assertEquals(4, taken.rating)
        assertEquals(1_755_000_910_000L, taken.ratingInvitedAt)
        assertEquals("quick", taken.ratingComment)
        assertEquals(1_755_000_920_000L, taken.ratedAt)
        assertEquals(
            DeskSessionSummary("refund", "waiting on finance", "check the order", 1_755_000_050_000L, "demo/model"),
            taken.summary,
        )
        assertEquals(listOf("billing/refund"), taken.tags)
        assertEquals("app", taken.channel)
        assertEquals("v_01hh", taken.visitorId)
        assertEquals("dk_1", taken.deskId)
        assertEquals("g_billing", taken.groupId)
        assertEquals(DeskDisposition.Resolved, taken.disposition)
        // A string on the wire, unlike `state` beside it.
        assertEquals(DeskEndReason.BotHandoff, taken.endReason)
        assertEquals("slow at first", taken.ratingReason)
        assertEquals(false, taken.ratingResolved)
        assertEquals(listOf("polite"), taken.ratingTags)
        assertTrue(taken.star)
        assertEquals(1_755_001_000_000L, taken.snoozedUntil)
        assertEquals(DeskResponseSample(1L, 2L, "a_7"), taken.responseSamples.single())
    }

    @Test
    fun `desk transfer sends exactly the one target its factory names`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.desk.transfer(DeskTransferRequest.agent("ds_1", "a_9", note = "VIP, be gentle"))
            client.desk.transfer(DeskTransferRequest.skill("ds_1", "billing"))
            client.desk.transfer(DeskTransferRequest.queue("ds_1"))
        }

        val (agent, skill, queue) = gateway.latest.requestsTo("desk.transfer").map { it.body }
        assertEquals(setOf("sessionId", "toAgentId", "note"), agent.keys)
        assertEquals("a_9", agent.jsonString("toAgentId"))
        assertEquals("VIP, be gentle", agent.jsonString("note"))

        assertEquals(setOf("sessionId", "toSkill"), skill.keys)
        assertEquals("billing", skill.jsonString("toSkill"))

        // `toQueue` is a C# bool: it leaves as true/false, never "true" or 1, and only when it is the target.
        assertEquals(setOf("sessionId", "toQueue"), queue.keys)
        assertTrue(queue.jsonBoolean("toQueue"))
    }

    @Test
    fun `desk close sends only what the agent filled in, and inviteRating only when said out loud`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.desk.close(DeskCloseRequest("ds_1"))
            client.desk.close(
                DeskCloseRequest(
                    "ds_1",
                    resolution = "refunded",
                    tags = listOf("billing/refund"),
                    disposition = DeskDisposition.ToLead,
                    summary = "wants a refund, passed to sales",
                    inviteRating = false,
                ),
            )
        }

        val (bare, drawer) = gateway.latest.requestsTo("desk.close").map { it.body }
        // Omitting inviteRating invites; sending it as null or false would not be the same request.
        assertEquals(setOf("sessionId"), bare.keys)
        assertEquals(
            setOf("sessionId", "resolution", "tags", "disposition", "summary", "inviteRating"),
            drawer.keys,
        )
        assertEquals(listOf("billing/refund"), drawer.jsonStrings("tags"))
        assertEquals("to-lead", drawer.jsonString("disposition"))
        assertFalse(drawer.jsonBoolean("inviteRating"))
    }

    @Test
    fun `desk status sends the agent status as its integer`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.desk.status(DeskStatusRequest(AgentStatus.Available))
            client.desk.status(DeskStatusRequest(AgentStatus.Busy, maxConcurrent = 4))
        }

        val (heartbeat, busy) = gateway.latest.requestsTo("desk.status").map { it.body }
        // An enum by name is refused with 1000 before the endpoint runs.
        assertEquals(setOf("status"), heartbeat.keys)
        assertEquals(1L, heartbeat.jsonInteger("status"))
        assertEquals(2L, busy.jsonInteger("status"))
        assertEquals(4L, busy.jsonInteger("maxConcurrent"))
    }

    @Test
    fun `desk queue sends no body and keeps an unmeasured average null`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val view = settle { client.desk.queue() }

        assertEquals(JsonObject(emptyMap()), gateway.latest.requestsTo("desk.queue").single().body)
        assertEquals(3, view.waiting)
        assertEquals(1, view.availableAgents)
        assertEquals(95L, view.headWaitSeconds)
        assertEquals(2, view.assigned)
        assertNull(view.avgFirstResponseSeconds, "absent is \"not measured\", and must not read as 0")
        assertEquals(mapOf("billing" to 3), view.waitingBySkill)
    }

    @Test
    fun `desk queue decodes a measured average`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "desk.queue" -> replyTo(request, queueView(measured = true))
                else -> null
            }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        val view = settle { client.desk.queue() }

        assertEquals(12.5, view.avgFirstResponseSeconds)
    }

    @Test
    fun `desk rate omits what the survey did not ask`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.desk.rate(DeskRateRequest("ds_1", score = 5))
            client.desk.rate(
                DeskRateRequest("ds_1", score = 2, resolved = false, starTags = listOf("slow"), comment = "twenty minutes"),
            )
        }

        val (quiet, answered) = gateway.latest.requestsTo("desk.rate").map { it.body }
        // resolved absent = the survey never asked; resolved false = "no". Folding one into the other
        // turns silence into a complaint.
        assertEquals(setOf("sessionId", "score"), quiet.keys)
        assertEquals(5L, quiet.jsonInteger("score"))
        assertEquals(setOf("sessionId", "score", "resolved", "starTags", "comment"), answered.keys)
        assertFalse(answered.jsonBoolean("resolved"))
        assertEquals(listOf("slow"), answered.jsonStrings("starTags"))
    }

    @Test
    fun `desk canned filters by what it is given and decodes each tier`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle { client.desk.canned() }
        val replies = settle {
            client.desk.canned(DeskCannedRequest(skill = "billing", scope = DeskCannedReplyScope.Personal, ownerMemberId = "m_1"))
        }

        val (everything, mine) = gateway.latest.requestsTo("desk.canned").map { it.body }
        assertEquals(JsonObject(emptyMap()), everything)
        assertEquals(setOf("skill", "scope", "ownerMemberId"), mine.keys)
        assertEquals("personal", mine.jsonString("scope"))
        assertEquals("m_1", mine.jsonString("ownerMemberId"))

        assertEquals(listOf("cr_1", "cr_2"), replies.map { it.id })
        assertEquals("Refunds", replies[0].title)
        assertEquals("Refunds take 3–5 days.", replies[0].content)
        assertEquals("billing", replies[0].skill)
        assertEquals(DeskCannedReplyScope.Personal, replies[0].scope)
        assertEquals("refunds", replies[0].folder)
        assertEquals("m_1", replies[0].ownerMemberId)
        assertEquals(1_755_000_000_000L, replies[0].updatedAt)
        assertEquals(DeskCannedReplyScope.All, replies[1].scope)
        assertNull(replies[1].ownerMemberId)
        assertNull(replies[1].skill)
        assertNull(replies[1].folder)
    }

    @Test
    fun `desk suggest names the session and returns the drafts`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val drafts = settle { client.desk.suggest(DeskSuggestRequest("ds_1")) }

        val body = gateway.latest.requestsTo("desk.suggest").single().body
        assertEquals(setOf("sessionId"), body.keys)
        assertEquals("ds_1", body.jsonString("sessionId"))
        assertEquals(listOf("Sure — one moment."), drafts)
    }

    @Test
    fun `a refused transfer throws with the server code`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "desk.transfer" -> replyTo(request, JsonNull, code = ImErrorCode.InvalidArgument)
                else -> null
            }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        val call = backgroundScope.async { runCatching { client.desk.transfer(DeskTransferRequest.queue("ds_1")) } }
        runCurrent()

        val failure = assertNotNull(call.await().exceptionOrNull() as? ImException)
        assertEquals(ImErrorCode.InvalidArgument, failure.code)
        assertEquals("desk.transfer", failure.target)
    }

    @Test
    fun `evt desk frames decode, a forced release carries no session, and an unknown event is dropped`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        val received = mutableListOf<DeskEvent>()
        backgroundScope.launch { client.deskEvents.collect { received += it } }
        openClient(client, gateway)

        val socket = gateway.latest
        socket.push(
            PushTarget.Desk,
            buildJsonObject {
                put("event", "desk.session")
                put("change", "message")
                put("session", session(full = true))
                putJsonObject("message") { put("messageId", "360381357961969667") }
            },
        )
        socket.push(
            PushTarget.Desk,
            buildJsonObject {
                put("event", "desk.session")
                put("change", "released")
                put("reason", "supervisor")
                put("forced", true)
            },
        )
        socket.push(
            PushTarget.Desk,
            buildJsonObject {
                put("event", "desk.agent")
                put("change", "takeover")
                put("connectionId", "conn-2")
                put("memberId", "m_1")
            },
        )
        socket.push(
            PushTarget.Desk,
            buildJsonObject {
                put("event", "desk.session")
                put("change", "overdue")
                put("session", session(full = true))
                put("kind", "first-response")
                put("assignedAt", 1_755_000_060_000L)
                put("minutes", 5)
            },
        )
        socket.push(
            PushTarget.Desk,
            buildJsonObject {
                put("event", "desk.session")
                put("change", "inactive")
                put("session", session(full = true))
                put("minutes", 10)
                put("silentSince", 1_755_000_500_000L)
                put("star", true)
            },
        )
        socket.push(
            PushTarget.Desk,
            buildJsonObject {
                put("event", "desk.session")
                put("change", "note")
                put("session", session(full = true))
                putJsonObject("note") { put("text", "called back") }
                putJsonObject("author") { put("memberId", "m_2") }
            },
        )
        socket.push(PushTarget.Desk, buildJsonObject { put("event", "desk.somethingNew") })
        runCurrent()

        assertEquals(6, received.size, "the unknown event is dropped, not delivered half-built: $received")
        val (message, released, takeover) = received
        val (overdue, inactive, note) = received.drop(3)
        assertEquals(DeskSessionChange.Message, message.change)
        assertEquals("ds_1", message.session?.sessionId)
        assertEquals("360381357961969667", message.message?.jsonString("messageId"))

        assertEquals(DeskSessionChange.Released, released.change)
        assertNull(released.session, "a forced release carries no session")
        assertEquals(true, released.forced)
        assertEquals("supervisor", released.reason)

        assertEquals(DeskEvent.AGENT, takeover.event)
        assertEquals(DeskSessionChange.Takeover, takeover.change)
        assertEquals("conn-2", takeover.connectionId)
        assertEquals("m_1", takeover.memberId)
        assertNull(takeover.session)

        assertEquals(DeskSessionChange.Overdue, overdue.change)
        assertEquals("first-response", overdue.kind)
        assertEquals(1_755_000_060_000L, overdue.assignedAt)
        assertEquals(5, overdue.minutes)

        assertEquals(DeskSessionChange.Inactive, inactive.change)
        assertEquals(10, inactive.minutes)
        assertEquals(1_755_000_500_000L, inactive.silentSince)
        assertEquals(true, inactive.star)

        assertEquals(DeskSessionChange.Note, note.change)
        assertEquals("called back", note.note?.jsonString("text"))
        assertEquals("m_2", note.author?.jsonString("memberId"))
    }

    /**
     * The decoding tests above are only as wide as their fixtures: a member a fixture leaves out
     * decodes to its default whatever key this SDK reads it from. So the full fixtures carry every
     * member the server's type declares, held here to `endpoint-inventory.json`'s `payloadTypes`.
     */
    @Test
    fun `the full fixtures carry every member the server declares`() {
        val inventory = ImJson.parseToJsonElement(inventoryFile().readText()).jsonObject
        fun members(type: String): Set<String> =
            inventory.getValue("payloadTypes").jsonObject.getValue(type).jsonObject.getValue("properties").jsonArray
                .map { it.jsonObject.getValue("name").jsonPrimitive.content }
                .toSet()

        assertEquals(members("DeskSession"), session(full = true).keys)
        assertEquals(members("DeskQueueView"), queueView(measured = true).keys)
        assertEquals(members("DeskCannedReply"), cannedRow().keys)
    }

    /** CONTRACT.md §4.5: the change values are held to the server's list, order included. */
    @Test
    fun `the change values are the server's thirteen, in its order`() {
        val inventory = ImJson.parseToJsonElement(inventoryFile().readText()).jsonObject
        val server = inventory.getValue("deskChanges").jsonObject.values.map { it.jsonPrimitive.content }
        assertEquals(server, DeskSessionChange.All)
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
