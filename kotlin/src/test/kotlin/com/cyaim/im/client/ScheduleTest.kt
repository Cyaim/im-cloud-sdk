@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonElement
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
 * `msg.schedule` / `msg.scheduled` / `msg.cancelScheduled`, `conv.folders` / `conv.upsertFolder` /
 * `conv.deleteFolder`, and `msg.translate` — the seven T4 calls typed together in round 77.
 *
 * Every call is asserted on the whole frame it puts on the wire, by JSON kind, and on what it makes
 * of a reply with every field set; the fixtures and requests are held to `endpoint-inventory.json`'s
 * `payloadTypes`. Two rules get tests of their own: a schedule moves no cursor and the message it
 * fires is an ordinary `evt.message`; and a deployment without translation (`1203` / `1204`) reaches
 * the caller as an ordinary, readable [ImException] — code, the server's message, the target.
 *
 * 每个调用断言发出的整帧与对满字段答复的解码，夹具与请求对着清单的 payloadTypes 钉住。另有两条规则单独测：
 * 定时不动游标、到点发出的是普通 evt.message；没有翻译能力的部署（1203 / 1204）以普通、可读的 ImException 交给调用方。
 */
class ScheduleTest {

    /** Past 2^53 and odd, so a trip through a double would change its last digit. */
    private val bigId = 360_381_357_961_969_667L

    // ------------------------------------------------------------------------------ fixtures

    private fun scheduled(
        scheduleId: String = "sch_7f3a",
        messageId: JsonElement? = null,
        error: String? = null,
    ): JsonObject = buildJsonObject {
        // Every member of the server's ScheduledMessage, each with a value no default reads as.
        put("scheduleId", scheduleId)
        put("appId", "demo")
        put("senderId", "alice")
        put("conversationId", "s_alice_bob")
        put("sendAt", 1_755_000_060_000L)
        put("createdAt", 1_755_000_000_000L)
        if (messageId != null) put("messageId", messageId)
        if (error != null) put("error", error)
    }

    private fun folder(folderId: String = "f_work", withTypes: Boolean = true): JsonObject = buildJsonObject {
        // Every member of the server's ConversationFolder.
        put("folderId", folderId)
        put("name", "Work")
        put("order", 3)
        putJsonArray("tags") { add(JsonPrimitive("work")); add(JsonPrimitive("clients")) }
        put("unreadOnly", true)
        if (withTypes) putJsonArray("types") { add(JsonPrimitive(1)); add(JsonPrimitive(2)) }
    }

    private fun translated(messageId: JsonElement, text: String?, cached: Boolean, error: String?): JsonObject =
        buildJsonObject {
            put("messageId", messageId)
            if (text != null) put("text", text)
            put("cached", cached)
            if (error != null) put("error", error)
        }

    private fun translation(): JsonObject = buildJsonObject {
        // Every member of TranslationResult; between them the items carry every member of TranslatedMessage.
        put("targetLanguage", "zh-CN")
        put(
            "items",
            buildJsonArray {
                add(translated(JsonPrimitive(bigId.toString()), "你好", cached = true, error = null))
                add(translated(JsonPrimitive("7"), null, cached = false, error = "message has no text"))
            },
        )
    }

    /** A refusal as the server writes one: status 0, a business code, its message, no data. */
    private fun refuse(request: JsonObject, code: Int, message: String): JsonObject = buildJsonObject {
        put("id", request.id)
        put("target", request.target)
        put("status", 0)
        putJsonObject("body") {
            put("code", code)
            put("message", message)
            put("traceId", "trace-refused")
            put("serverTime", 1_755_000_000_000L)
        }
    }

    private fun gateway(): FakeGateway = FakeGateway().apply {
        onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "msg.schedule" -> replyTo(request, scheduled())
                "msg.scheduled" -> replyTo(
                    request,
                    buildJsonObject {
                        put(
                            "items",
                            buildJsonArray {
                                add(scheduled("sch_pending"))
                                add(scheduled("sch_sent", messageId = JsonPrimitive(bigId.toString())))
                                add(scheduled("sch_cancelled", error = "cancelled by sender"))
                                add(scheduled("sch_failed", error = "send failed"))
                            },
                        )
                        put("nextCursor", "c2")
                        put("hasMore", true)
                    },
                )
                "conv.folders" -> replyTo(request, buildJsonArray { add(folder()); add(folder("f_all", withTypes = false)) })
                "conv.upsertFolder" -> replyTo(request, folder())
                "msg.translate" -> replyTo(request, translation())
                "msg.cancelScheduled", "conv.deleteFolder" -> replyTo(request, JsonNull)
                else -> null
            }
        }
    }

    private suspend fun <T> TestScope.settle(block: suspend () -> T): T {
        val call = backgroundScope.async { block() }
        runCurrent()
        return call.await()
    }

    private suspend fun TestScope.failure(block: suspend () -> Unit): ImException {
        val call = backgroundScope.async { runCatching { block() } }
        runCurrent()
        return assertNotNull(call.await().exceptionOrNull() as? ImException, "expected an ImException")
    }

    // ---------------------------------------------------------------------------- msg.schedule

    @Test
    fun `msg schedule sends the flat request with no options, no sendTime and no invented key`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val entry = settle { client.msg.schedule(ScheduleRequest(sendAt = 1_755_000_060_000L, content = textContent("later"), receiverId = "bob")) }

        val body = gateway.latest.requestsTo("msg.schedule").single().body
        assertEquals(setOf("sendAt", "content", "contentType", "receiverId", "mentionAll", "mentionedUserIds"), body.keys)
        assertEquals(1_755_000_060_000L, body.jsonInteger("sendAt"))
        assertEquals("later", body.getValue("content").jsonObject.jsonString("text"))
        assertEquals(MessageContentType.Text.code.toLong(), body.jsonInteger("contentType"))
        assertEquals("bob", body.jsonString("receiverId"))
        assertFalse(body.jsonBoolean("mentionAll"))
        assertEquals(emptyList(), body.jsonStrings("mentionedUserIds"))
        // The server derives sch-<scheduleId> for a missing key; the SDK must not make one up, and
        // there is no options or sendTime on this wire at all.
        assertFalse("clientMsgId" in body, "an absent key is left to the server: $body")
        assertFalse("options" in body)
        assertFalse("sendTime" in body)

        assertEquals("sch_7f3a", entry.scheduleId)
        assertEquals("demo", entry.appId)
        assertEquals("alice", entry.senderId)
        assertEquals("s_alice_bob", entry.conversationId)
        assertEquals(1_755_000_060_000L, entry.sendAt)
        assertEquals(1_755_000_000_000L, entry.createdAt)
        assertNull(entry.messageId, "pending: not sent yet")
        assertNull(entry.error, "pending: neither cancelled nor failed")
    }

    @Test
    fun `msg schedule writes every member in the kind the server binds`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.msg.schedule(
                ScheduleRequest(
                    sendAt = 1_755_000_060_000L,
                    content = buildJsonObject { put("url", "media/a.png") },
                    contentType = MessageContentType.Image,
                    conversationId = "g_team",
                    receiverId = "bob",
                    groupId = "team",
                    conversationType = ConversationType.Group,
                    clientMsgId = "cid-later",
                    mentionAll = true,
                    mentionedUserIds = listOf("bob", "carol"),
                    quoteMessageId = bigId,
                    threadRootId = bigId - 2,
                    extensions = buildJsonObject { put("k", "v") },
                ),
            )
        }

        val body = gateway.latest.requestsTo("msg.schedule").single().body
        assertEquals(members("ScheduleRequest"), body.keys)
        assertEquals(1_755_000_060_000L, body.jsonInteger("sendAt"))
        assertEquals("media/a.png", body.getValue("content").jsonObject.jsonString("url"))
        assertEquals(MessageContentType.Image.code.toLong(), body.jsonInteger("contentType"))
        assertEquals("g_team", body.jsonString("conversationId"))
        assertEquals("bob", body.jsonString("receiverId"))
        assertEquals("team", body.jsonString("groupId"))
        assertEquals(ConversationType.Group.code.toLong(), body.jsonInteger("conversationType"))
        assertEquals("cid-later", body.jsonString("clientMsgId"))
        assertTrue(body.jsonBoolean("mentionAll"))
        assertEquals(listOf("bob", "carol"), body.jsonStrings("mentionedUserIds"))
        assertEquals(bigId.toString(), body.jsonString("quoteMessageId"), "a string on the server, every digit kept")
        assertEquals((bigId - 2).toString(), body.jsonString("threadRootId"))
        assertEquals("v", body.getValue("extensions").jsonObject.jsonString("k"))
    }

    @Test
    fun `msg scheduled sends the page and tells pending, sent, cancelled and failed apart`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val page = settle { client.msg.scheduled() }
        settle { client.msg.scheduled(PageRequest(cursor = page.nextCursor, limit = 100)) }

        val (first, next) = gateway.latest.requestsTo("msg.scheduled").map { it.body }
        assertEquals(setOf("limit"), first.keys, "no cursor on the first page: $first")
        assertEquals(20L, first.jsonInteger("limit"))
        assertEquals(setOf("cursor", "limit"), next.keys)
        assertEquals("c2", next.jsonString("cursor"))
        assertEquals(100L, next.jsonInteger("limit"))

        assertEquals("c2", page.nextCursor)
        assertTrue(page.hasMore)
        assertNull(page.total)
        val (pending, sent, cancelled, failed) = page.items
        assertEquals("sch_pending", pending.scheduleId)
        assertNull(pending.messageId)
        assertNull(pending.error)
        assertEquals(bigId, sent.messageId, "a string id decodes with every digit")
        assertNull(sent.error)
        assertEquals("cancelled by sender", cancelled.error, "a cancelled entry stays listed, marked")
        assertNull(cancelled.messageId)
        assertEquals("send failed", failed.error)
        assertEquals(1_755_000_060_000L, failed.sendAt)
    }

    @Test
    fun `a scheduled message id written as a bare number decodes too`() {
        val entry = ImJson.decodeFromJsonElement(ScheduledMessage.serializer(), scheduled(messageId = JsonPrimitive(42L)))
        assertEquals(42L, entry.messageId)
    }

    @Test
    fun `msg cancelScheduled sends only the id on both overloads, and a refusal carries the server's words`() = runTest {
        var refusal: Pair<Int, String>? = null
        val gateway = gateway().apply {
            val ordinary = onRequest!!
            onRequest = { request ->
                val (code, message) = refusal ?: (0 to "")
                if (request.target == "msg.cancelScheduled" && code != 0) refuse(request, code, message) else ordinary(request)
            }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.msg.cancelScheduled(ScheduleIdRequest("sch_7f3a"))
            client.msg.cancelScheduled("sch_8b1c")
        }
        val bodies = gateway.latest.requestsTo("msg.cancelScheduled").map { it.body }
        assertEquals(listOf(setOf("scheduleId"), setOf("scheduleId")), bodies.map { it.keys })
        assertEquals(listOf("sch_7f3a", "sch_8b1c"), bodies.map { it.jsonString("scheduleId") })

        refusal = ImErrorCode.NotFound to "no such scheduled message"
        val unknown = failure { client.msg.cancelScheduled("sch_nope") }
        assertEquals(ImErrorCode.NotFound, unknown.code)
        assertEquals("no such scheduled message", unknown.message)
        assertEquals("msg.cancelScheduled", unknown.target)

        refusal = ImErrorCode.Conflict to "already being sent and can no longer be cancelled"
        val late = failure { client.msg.cancelScheduled("sch_7f3a") }
        assertEquals(ImErrorCode.Conflict, late.code)
        assertEquals("already being sent and can no longer be cancelled", late.message)
    }

    @Test
    fun `scheduling moves no cursor, and the message it fires is an ordinary evt message`() = runTest {
        val gateway = gateway()
        val store = RecordingCursorStore()
        val client = newClient(gateway, store = store)
        val received = collectMessages(client)
        openClient(client, gateway)

        settle { client.msg.schedule(ScheduleRequest(sendAt = 1_755_000_060_000L, content = textContent("later"), receiverId = "bob")) }
        client.flushCursors()
        runCurrent()
        assertTrue(received.isEmpty(), "a schedule delivers nothing: $received")
        assertEquals(0L, client.committedSeq("s_alice_bob"))
        assertTrue(store.saves.none { "s_alice_bob" in it.convSeqs })
        assertTrue(gateway.latest.requestsTo("msg.sync").isEmpty())

        // When it fires, the server sends it through the normal path: a plain evt.message with a real
        // seq and the derived key. No decoding of its own, no special case.
        gateway.latest.push(
            PushTarget.Message,
            buildJsonObject {
                put("conversationId", "s_alice_bob")
                put("conversationType", 1)
                put("seq", 1)
                put("messageId", bigId.toString())
                put("clientMsgId", "sch-sch_7f3a")
                put("senderId", "alice")
                put("contentType", 1)
                putJsonObject("content") { put("text", "later") }
                put("createTime", 1_755_000_061_000L)
            },
        )
        runCurrent()
        assertEquals(listOf(Triple("s_alice_bob", 1L, "later")), received.map { Triple(it.conversationId, it.seq, it.text) })
        assertEquals(bigId, received.single().messageId)
        assertEquals("sch-sch_7f3a", received.single().clientMsgId)
        assertTrue(gateway.latest.requestsTo("msg.sync").isEmpty(), "seq 1 is contiguous; nothing to repair")
    }

    // ------------------------------------------------------------------------------- folders

    @Test
    fun `conv folders sends an empty body and decodes the bare array`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val folders = settle { client.conv.folders() }

        assertEquals(JsonObject(emptyMap()), gateway.latest.requestsTo("conv.folders").single().body)
        assertEquals(listOf("f_work", "f_all"), folders.map { it.folderId })
        val work = folders.first()
        assertEquals("Work", work.name)
        assertEquals(3, work.order)
        assertEquals(listOf("work", "clients"), work.tags)
        assertTrue(work.unreadOnly)
        assertEquals(listOf(ConversationType.Single, ConversationType.Group), work.types, "integers on the wire")
        assertNull(folders.last().types, "absent types means every type")
    }

    @Test
    fun `conv upsertFolder creates without an id and replaces with one, every member in its kind`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val saved = settle { client.conv.upsertFolder(UpsertFolderRequest("Work")) }
        settle {
            client.conv.upsertFolder(
                UpsertFolderRequest(
                    name = "Work",
                    folderId = "f_work",
                    order = 3,
                    tags = listOf("work", "clients"),
                    unreadOnly = true,
                    types = listOf(ConversationType.Single, ConversationType.Group),
                ),
            )
        }

        val (create, replace) = gateway.latest.requestsTo("conv.upsertFolder").map { it.body }
        assertEquals(setOf("name", "order", "tags", "unreadOnly"), create.keys, "no folderId creates; no types is all: $create")
        assertEquals("Work", create.jsonString("name"))
        assertEquals(0L, create.jsonInteger("order"))
        assertEquals(emptyList(), create.jsonStrings("tags"))
        assertFalse(create.jsonBoolean("unreadOnly"))

        assertEquals(members("UpsertFolderRequest"), replace.keys)
        assertEquals("f_work", replace.jsonString("folderId"))
        assertEquals(3L, replace.jsonInteger("order"))
        assertEquals(listOf("work", "clients"), replace.jsonStrings("tags"))
        assertTrue(replace.jsonBoolean("unreadOnly"))
        assertEquals(listOf(1L, 2L), replace.getValue("types").jsonArray.mapIndexed { i, it -> jsonInteger(it, "types[$i]") })

        assertEquals("f_work", saved.folderId, "the saved folder, id included")
        assertEquals("Work", saved.name)
        assertEquals(3, saved.order)
        assertEquals(listOf("work", "clients"), saved.tags)
        assertTrue(saved.unreadOnly)
        assertEquals(listOf(ConversationType.Single, ConversationType.Group), saved.types)
    }

    @Test
    fun `conv deleteFolder sends only the id on both overloads, and an unknown one is 1002`() = runTest {
        val gateway = gateway().apply {
            val ordinary = onRequest!!
            onRequest = { request ->
                if (request.target == "conv.deleteFolder" && request.bodyString("folderId") == "f_gone") {
                    refuse(request, ImErrorCode.NotFound, "no such folder")
                } else {
                    ordinary(request)
                }
            }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.conv.deleteFolder(FolderIdRequest("f_work"))
            client.conv.deleteFolder("f_home")
        }
        val bodies = gateway.latest.requestsTo("conv.deleteFolder").map { it.body }
        assertEquals(listOf(setOf("folderId"), setOf("folderId")), bodies.map { it.keys })
        assertEquals(listOf("f_work", "f_home"), bodies.map { it.jsonString("folderId") })

        val gone = failure { client.conv.deleteFolder("f_gone") }
        assertEquals(ImErrorCode.NotFound, gone.code)
        assertEquals("no such folder", gone.message)
        assertEquals("conv.deleteFolder", gone.target)
    }

    // ----------------------------------------------------------------------------- translate

    @Test
    fun `msg translate quotes every id and decodes each item, a per-message failure included`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val result = settle { client.msg.translate(TranslateRequest("s_alice_bob", listOf(bigId, 7L), "zh-CN")) }
        settle { client.msg.translate(TranslateRequest("s_alice_bob", listOf(bigId), "zh-CN", sourceLanguage = "en")) }

        val (plain, hinted) = gateway.latest.requestsTo("msg.translate").map { it.body }
        assertEquals(setOf("conversationId", "messageIds", "targetLanguage"), plain.keys, "no source hint is left off: $plain")
        assertEquals("s_alice_bob", plain.jsonString("conversationId"))
        assertEquals(listOf(bigId.toString(), "7"), plain.jsonStrings("messageIds"), "strings on the server, every digit kept")
        assertEquals("zh-CN", plain.jsonString("targetLanguage"))
        assertEquals(members("TranslateRequest"), hinted.keys)
        assertEquals("en", hinted.jsonString("sourceLanguage"))

        assertEquals("zh-CN", result.targetLanguage)
        val (done, refused) = result.items
        assertEquals(bigId, done.messageId)
        assertEquals("你好", done.text)
        assertTrue(done.cached)
        assertNull(done.error)
        assertEquals(7L, refused.messageId)
        assertNull(refused.text)
        assertFalse(refused.cached)
        assertEquals("message has no text", refused.error, "one item failing does not fail the call")
    }

    /**
     * The point of typing this call at all on most deployments: no provider, or a plan without the
     * add-on. Both must arrive as the SDK's ordinary error — code, the server's sentence, the target —
     * and leave the connection usable, not as a crash or an undecodable reply.
     */
    @Test
    fun `a deployment without translation answers 1203 or 1204 as an ordinary readable ImException`() = runTest {
        var code = ImErrorCode.FeatureNotEnabled
        var message = "no translation provider is configured (IM:Translation:Provider)"
        val gateway = gateway().apply {
            val ordinary = onRequest!!
            onRequest = { request -> if (request.target == "msg.translate") refuse(request, code, message) else ordinary(request) }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        val noProvider = failure { client.msg.translate(TranslateRequest("s_alice_bob", listOf(bigId), "zh-CN")) }
        assertEquals(ImErrorCode.FeatureNotEnabled, noProvider.code)
        assertEquals("no translation provider is configured (IM:Translation:Provider)", noProvider.message)
        assertEquals("msg.translate", noProvider.target)
        assertEquals("trace-refused", noProvider.traceId)
        assertFalse(noProvider.isRetryable, "retrying cannot conjure a provider")
        assertFalse(noProvider.requiresReauth)

        code = ImErrorCode.PlanExpired
        message = "message translation is not included in this plan; start its trial or enable the add-on in the console"
        val notInPlan = failure { client.msg.translate(TranslateRequest("s_alice_bob", listOf(bigId), "zh-CN")) }
        assertEquals(ImErrorCode.PlanExpired, notInPlan.code)
        assertEquals(message, notInPlan.message)
        assertFalse(notInPlan.isRetryable)

        // The refusal is the call's, not the connection's.
        assertEquals(ConnectionState.Open, client.state.value)
        assertEquals(2, settle { client.conv.folders() }.size)
    }

    // ------------------------------------------------------------------- held to the inventory

    /**
     * The decoding tests above are only as wide as their fixtures: a member a fixture leaves out
     * decodes to its default whatever key this SDK reads it from. So the full fixtures carry every
     * member the server's type declares, and the requests send every member, held here to
     * `endpoint-inventory.json`'s `payloadTypes`.
     */
    @Test
    fun `the full fixtures and requests carry every member the server declares`() {
        assertEquals(members("ScheduledMessage"), scheduled(messageId = JsonPrimitive("1"), error = "e").keys)
        assertEquals(members("ConversationFolder"), folder().keys)
        assertEquals(members("TranslationResult"), translation().keys)
        assertEquals(
            members("TranslatedMessage"),
            translation().getValue("items").jsonArray.flatMap { it.jsonObject.keys }.toSet(),
            "between them the items carry every member",
        )

        assertEquals(
            members("ScheduleRequest"),
            ScheduleRequest(
                sendAt = 1L, content = textContent("t"), conversationId = "c", receiverId = "r", groupId = "g",
                conversationType = ConversationType.Single, clientMsgId = "k", mentionedUserIds = listOf("u"),
                quoteMessageId = 1L, threadRootId = 2L, extensions = buildJsonObject { put("k", "v") },
            ).asBody().jsonObject.keys,
        )
        assertEquals(members("ScheduleIdRequest"), ScheduleIdRequest("s").asBody().jsonObject.keys)
        assertEquals(members("PageRequest"), PageRequest(cursor = "c").asBody().jsonObject.keys)
        assertEquals(
            members("UpsertFolderRequest"),
            UpsertFolderRequest("n", folderId = "f", types = listOf(ConversationType.Single)).asBody().jsonObject.keys,
        )
        assertEquals(members("FolderIdRequest"), FolderIdRequest("f").asBody().jsonObject.keys)
        assertEquals(members("TranslateRequest"), TranslateRequest("c", listOf(1L), "en", "zh").asBody().jsonObject.keys)
    }

    /**
     * `ScheduleRequest` is the members of the server's `SendMessageRequest` the scheduler reads, plus
     * `sendAt`. This pins both halves: what it adds is exactly `sendAt`, and what it leaves out is
     * exactly `options` and `sendTime`, which the server deliberately does not bind on this path — a
     * member either type gains shows up here instead of going unexamined.
     */
    @Test
    fun `a schedule request is the send request minus options and sendTime, plus sendAt`() {
        val schedule = members("ScheduleRequest")
        val send = members("SendMessageRequest")
        assertEquals(setOf("sendAt"), schedule - send)
        assertEquals(setOf("options", "sendTime"), send - schedule)
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
