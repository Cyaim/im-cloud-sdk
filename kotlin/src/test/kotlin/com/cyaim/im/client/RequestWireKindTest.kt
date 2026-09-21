@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Every request field leaves as the JSON kind of the server property it binds to.
 *
 * The socket binds a request body field by field with each property's C# type and none of the
 * serializer's number handling, so the *kind* is the whole contract: a C# `string` refuses a JSON
 * number, a `long` refuses a quoted one, an enum refuses its name, a `bool` refuses `"true"` — and
 * each refusal is the whole call answering `1000` before the endpoint runs. The value can be right
 * and the call still dead.
 *
 * That is how `msg.recall`, `msg.edit`, `msg.delete`, `msg.react`, `msg.forward`, `msg.receipt` and
 * `msg.send`'s quote/thread ids stayed broken in this SDK after the server moved them to strings:
 * nothing asserted their frames at all, and the shared accessors the other tests used read `7` and
 * `"7"` as the same thing.
 *
 * socket 按 C# 类型逐字段绑定：string 拒收数字、long 拒收带引号的数字、枚举拒收名字，
 * 拒收就是整次调用 1000。所以这里断言的是 JSON 类型，而不只是值。
 */
class RequestWireKindTest {

    /** Past 2^53 and odd, so a trip through a double would change its last digit. */
    private val bigId = 360_381_357_961_969_667L

    private val ext = buildJsonObject { put("k", "v") }

    // ------------------------------------------------------------- the fixed fields, on the frame

    private fun gateway(): FakeGateway = FakeGateway().apply {
        onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "msg.send" -> replyTo(
                    request,
                    buildJsonObject {
                        put("messageId", (bigId + 10).toString())
                        put("seq", 1)
                        put("conversationId", "s_alice_bob")
                        put("clientMsgId", request.body.getValue("clientMsgId").jsonPrimitive.content)
                    },
                )
                "msg.forward" -> replyTo(request, JsonArray(emptyList()))
                "msg.recall", "msg.edit", "msg.delete", "msg.react", "msg.receipt" -> replyTo(request, JsonNull)
                else -> null
            }
        }
    }

    private suspend fun <T> TestScope.settle(block: suspend () -> T): T {
        val call = backgroundScope.async { block() }
        runCurrent()
        return call.await()
    }

    @Test
    fun `every message id a msg request names leaves as a JSON string, exactly`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.msg.recall(RecallMessageRequest("s_alice_bob", bigId, reason = "typo"))
            client.msg.edit(EditMessageRequest("s_alice_bob", bigId, textContent("fixed")))
            client.msg.delete(DeleteMessagesRequest("s_alice_bob", listOf(bigId, 7L), forEveryone = true))
            client.msg.forward(ForwardMessagesRequest("s_alice_bob", listOf(bigId, 7L), listOf("g_team")))
            client.msg.react(ReactRequest("s_alice_bob", bigId, "+1", add = false))
            client.msg.receipt(ReceiptRequest("s_alice_bob", listOf(bigId, 7L)))
        }
        val sent = gateway.latest
        val big = bigId.toString()

        val recall = sent.requestsTo("msg.recall").single().body
        assertEquals(big, recall.jsonString("messageId"))
        assertEquals("typo", recall.jsonString("reason"))

        val edit = sent.requestsTo("msg.edit").single().body
        assertEquals(big, edit.jsonString("messageId"))

        val delete = sent.requestsTo("msg.delete").single().body
        assertEquals(listOf(big, "7"), delete.jsonStrings("messageIds"))
        assertTrue(delete.jsonBoolean("forEveryone"))

        val forward = sent.requestsTo("msg.forward").single().body
        assertEquals(listOf(big, "7"), forward.jsonStrings("messageIds"))
        assertEquals(listOf("g_team"), forward.jsonStrings("targetConversationIds"))
        assertFalse(forward.jsonBoolean("merge"))

        val react = sent.requestsTo("msg.react").single().body
        assertEquals(big, react.jsonString("messageId"))
        assertFalse(react.jsonBoolean("add"))

        val receipt = sent.requestsTo("msg.receipt").single().body
        assertEquals(listOf(big, "7"), receipt.jsonStrings("messageIds"))
    }

    @Test
    fun `msg send quotes its quote and thread ids on both overloads, and leaves absent ones off`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.msg.send(
                SendMessageRequest(
                    clientMsgId = "cid-wire",
                    contentType = MessageContentType.Text,
                    content = textContent("re"),
                    conversationId = "s_alice_bob",
                    quoteMessageId = bigId,
                    threadRootId = bigId - 2,
                    sendTime = 1_700_000_000_000L,
                ),
            )
            client.msg.send(SendRequest(SendTarget.User("bob"), textContent("re"), quoteMessageId = bigId))
            client.msg.send(SendRequest(SendTarget.User("bob"), textContent("plain")))
        }

        val (wire, ergonomic, plain) = gateway.latest.requestsTo("msg.send").map { it.body }

        assertEquals(bigId.toString(), wire.jsonString("quoteMessageId"))
        assertEquals((bigId - 2).toString(), wire.jsonString("threadRootId"))
        // The neighbours keep their own kinds: an enum is its integer, a clock is a number.
        assertEquals(1L, wire.jsonInteger("contentType"))
        assertEquals(1_700_000_000_000L, wire.jsonInteger("sendTime"))

        assertEquals(bigId.toString(), ergonomic.jsonString("quoteMessageId"))
        assertEquals("bob", ergonomic.jsonString("receiverId"))

        // Null is omitted, not written as null or as "0": the server reads an absent id as "none".
        assertFalse("quoteMessageId" in plain, "an absent quote id must stay off the frame: $plain")
        assertFalse("threadRootId" in plain, "an absent thread id must stay off the frame: $plain")
    }

    // ----------------------------------------------- every field of every typed request, vs the server

    /**
     * Server fields this SDK never sends, each with its reason. Anything else missing from a sample
     * is a failure, so a field the server adds cannot go unexamined.
     */
    private val omitted = mapOf(
        "RecallMessageRequest.asAdmin" to "forced false for client calls; admin recall is a server-API capability",
    )

    /** Every request object, fully populated, keyed by its class name — which is the server DTO's. */
    private fun samples(): Map<String, JsonObject> {
        val options = MessageOptions(
            persistent = false, updateConversation = false, countUnread = false, offlinePush = false,
            pushConfig = PushConfig(
                title = "t", body = "b", sound = "s", payload = mapOf("k" to "v"), badgeCount = false, channelId = "ch",
            ),
            needReceipt = true, priority = MessagePriority.High, onlineOnly = true, noSelfSync = true,
            expireIn = 5_000L, moderationBypass = true,
        )
        return listOf(
            sample(ResumeRequest(mapOf("s_alice_bob" to 42L), conversationCursor = 1_700_000_000_000L, cursor = "c", limit = 100)),
            sample(ReauthRequest("token-2")),
            sample(
                SendMessageRequest(
                    clientMsgId = "cid", contentType = MessageContentType.Image, content = textContent("hi"),
                    conversationId = "s_alice_bob", receiverId = "bob", groupId = "team",
                    conversationType = ConversationType.Group, mentionAll = true, mentionedUserIds = listOf("bob"),
                    quoteMessageId = bigId, threadRootId = bigId - 2, options = options,
                    sendTime = 1_700_000_000_000L, extensions = ext,
                ),
            ),
            sample(SyncMessagesRequest("s_alice_bob", fromSeq = 2, toSeq = 9, limit = 100, ascending = false)),
            sample(HistoryRequest("s_alice_bob", beforeSeq = 9, limit = 30)),
            sample(RecallMessageRequest("s_alice_bob", bigId, reason = "typo")),
            sample(EditMessageRequest("s_alice_bob", bigId, textContent("fixed"))),
            sample(DeleteMessagesRequest("s_alice_bob", listOf(bigId, 7L), forEveryone = true)),
            sample(ForwardMessagesRequest("s_alice_bob", listOf(bigId, 7L), listOf("g_team"), true, "t", "cid")),
            sample(ReactRequest("s_alice_bob", bigId, "+1", add = false)),
            sample(ReceiptRequest("s_alice_bob", listOf(bigId, 7L))),
            sample(TypingRequest("s_alice_bob", typing = false)),
            sample(ConversationMessageRequest("s_alice_bob", bigId)),
            sample(ReceiptDetailRequest("s_alice_bob", bigId)),
            sample(PageRequest(cursor = "p", limit = 30)),
            sample(
                SearchMessagesRequest(
                    keyword = "invoice", conversationId = "g_team", contentTypes = listOf(MessageContentType.File),
                    senderId = "bob", startTime = 1L, endTime = 2L, cursor = "s", limit = 30,
                ),
            ),
            sample(ListConversationsRequest(updatedAfter = 42, cursor = "c", limit = 30)),
            sample(ConversationIdRequest("s_alice_bob")),
            sample(ReadRequest("s_alice_bob", readSeq = 9)),
            sample(
                UpdateConversationSettingRequest(
                    "s_alice_bob",
                    ConversationSetting(pinned = true, muted = MuteMode.Silent, draft = "d", tags = listOf("work"), extensions = ext),
                ),
            ),
            sample(MarkUnreadRequest("s_alice_bob", unread = false)),
            sample(UserIdRequest("bob")),
            sample(UserIdsRequest(listOf("bob"))),
            sample(UpdateProfileRequest(buildJsonObject { put("nickname", "Al") })),
            sample(SubscribePresenceRequest(listOf("bob"), ttlSeconds = 300)),
            sample(SetStatusRequest("away")),
            sample(CursorRequest(cursor = "c", limit = 30)),
            sample(AddFriendRequest("bob", greeting = "hi", source = "search")),
            sample(HandleFriendRequest("bob", accept = true, reason = "ok")),
            sample(FriendRequestListRequest(incoming = false, cursor = "c", limit = 30)),
            sample(BlockRequest("bob", reason = "spam")),
            sample(SetRemarkRequest("bob", remark = "Bob", tags = listOf("work"))),
            sample(
                CreateGroupRequest(
                    name = "Team", memberIds = listOf("bob"), groupId = "team", avatar = "a", introduction = "i",
                    type = GroupType.Super, joinMode = GroupJoinMode.NeedApproval,
                    inviteMode = GroupInviteMode.AdminsOnly, maxMemberCount = 500, extensions = ext,
                ),
            ),
            sample(GroupIdRequest("team")),
            sample(
                UpdateGroupCommand(
                    "team",
                    UpdateGroupRequest(
                        name = "n", avatar = "a", introduction = "i", joinMode = GroupJoinMode.Forbidden,
                        inviteMode = GroupInviteMode.Forbidden, maxMemberCount = 200, extensions = ext,
                    ),
                ),
            ),
            sample(GroupCursorRequest("team", cursor = "c", limit = 30)),
            sample(GroupMembersRequest("team", listOf("bob"), reason = "r")),
            sample(JoinGroupRequest("team", reason = "r")),
            sample(TransferOwnerRequest("team", "bob")),
            sample(HandleApplicationRequest("team", "dave", accept = true, reason = "r")),
            sample(SetRoleRequest("team", "bob", GroupRole.Admin)),
            sample(MuteGroupRequest("team", mute = false, untilMs = 1_758_499_200_000L)),
            sample(MuteMemberRequest("team", "bob", untilMs = 1_758_499_200_000L)),
            sample(SetGroupNicknameRequest("team", userId = "bob", nickname = "Cap")),
            sample(AnnouncementRequest("team", "hello")),
            sample(UploadTicketRequest("a.png", "image/png", size = 1_024)),
            sample(DownloadUrlRequest("k/a.png", lifetimeSeconds = 60)),
            sample(RegisterPushTokenRequest(PushProvider.Fcm, "tok", language = "zh-CN")),
            sample(PushClickedRequest(pushId = "pu_1", messageId = bigId.toString())),
            sample(SubmitReportRequest("mallory", "s_alice_bob", bigId, ReportCategory.Spam, "n")),
            sample(DeviceLogAnswer("lr_1", uploaded = true, sizeBytes = 2_048, coveredFromMs = 1L, volatile = true, detail = "d")),
        ).toMap()
    }

    /** Encoded by `asBody()`, the one encoder every typed method hands its request to. */
    private inline fun <reified T> sample(request: T): Pair<String, JsonObject> =
        T::class.simpleName!! to request.asBody().jsonObject

    @Test
    fun `every field of every typed request leaves as the kind the server binds`() {
        val inventory = ImJson.parseToJsonElement(inventoryFile().readText()).jsonObject
        val types = inventory.getValue("payloadTypes").jsonObject
        val enums = inventory.getValue("payloadEnums").jsonObject.keys
        val samples = samples()
        val sweep = Sweep(types, enums, omitted.keys)

        val requestTypes = inventory.getValue("endpoints").jsonArray.map { it.jsonObject }
            .filter { it.getValue("implementedIn").jsonObject.getValue("kotlin").jsonPrimitive.booleanOrNull == true }
            .mapNotNull { (it["requestType"] as? JsonPrimitive)?.takeIf { type -> type.isString }?.content }
            .toSortedSet()

        for (type in requestTypes) {
            val body = samples[type]
            if (body == null) {
                sweep.problems += "$type: the inventory says Kotlin sends it and there is no sample here — add one"
                continue
            }
            sweep.checkObject(type, body, type)
        }
        for ((key, reason) in omitted) {
            val (type, field) = key.split('.', limit = 2)
            if (samples[type]?.containsKey(field) == true) sweep.problems += "$key is declared omitted ($reason) but is sent"
        }

        println("RequestWireKindTest: ${requestTypes.size} request types, ${sweep.checked} fields checked, ${omitted.size} declared omitted")
        assertTrue(
            sweep.problems.isEmpty(),
            "${sweep.problems.size} request field(s) do not leave as the kind the server binds " +
                "(each such call is refused with 1000 before the endpoint runs):\n  " +
                sweep.problems.joinToString("\n  ") +
                "\nSend the server's kind: a JSON string for a C# string, a bare integer for long/int/enum, " +
                "true/false for bool. If the server's type is what is wrong, change the DTO and regenerate the inventory.",
        )
    }

    // ------------------------------------------------ the recording, for the server's binder to judge

    /**
     * The sweep above judges against `endpoint-inventory.json`, which records the server's C# type
     * names but not its binder's rules — it could not see, for one, that a nested object is matched
     * case-sensitively. So the same samples are written to `SDK/wire-samples/kotlin.json`, and the
     * platform repository binds each of them with the server's real socket binder
     * (`SdkWireSampleBindingTests`). This test keeps that file honest: it fails when what this SDK
     * encodes drifts from what is committed. Set `IM_RECORD_WIRE_SAMPLES=1` to rewrite it.
     *
     * 上面的扫描对照的是清单（只记类型名，不记绑定器规则）。同一批样本落盘到 wire-samples/kotlin.json，
     * 由平台仓用服务端真实的绑定器逐个绑定；本测试在 SDK 的实际编码与已提交的文件不一致时失败。
     */
    @Test
    fun `the recorded wire samples are exactly what this SDK encodes`() {
        val file = wireSampleFile()
        val text = recordingText()

        if (System.getenv("IM_RECORD_WIRE_SAMPLES") == "1") {
            file.parentFile.mkdirs()
            file.writeText(text, Charsets.UTF_8)
            return
        }

        assertTrue(file.isFile, "${file.path} is missing; record it with $RECORD_COMMAND and commit it")
        val committed = file.readText(Charsets.UTF_8).replace("\r\n", "\n").split('\n')
        val live = text.split('\n')
        val changed = (0 until maxOf(committed.size, live.size))
            .filter { committed.getOrNull(it) != live.getOrNull(it) }
            .take(12)
            .map { "  line ${it + 1}\n    committed: ${committed.getOrNull(it) ?: "(none)"}\n    encoded now: ${live.getOrNull(it) ?: "(none)"}" }
        assertTrue(
            changed.isEmpty(),
            "what this SDK encodes no longer matches SDK/wire-samples/kotlin.json:\n${changed.joinToString("\n")}\n" +
                "If the change is intended, re-record with $RECORD_COMMAND and commit the file; the platform " +
                "repository's SdkWireSampleBindingTests will judge it against the server's real binder.",
        )
    }

    /** One sample per line, in declaration order, so a re-recording diffs line by line. */
    private fun recordingText(): String {
        fun quote(text: String): String = JsonPrimitive(text).toString()
        val comment = "RECORDED by SDK/kotlin/src/test/kotlin/com/cyaim/im/client/RequestWireKindTest.kt from asBody(), " +
            "the encoder every typed method hands its request to. Do not edit by hand; re-record with $RECORD_COMMAND. " +
            "Judged against the server's real socket binder by IM.Server/tests/IM.Tests.Unit/SdkWireSampleBindingTests.cs " +
            "in the platform repository."
        val lines = mutableListOf("{", "  \"\$comment\": ${quote(comment)},", "  \"sdk\": \"kotlin\",", "  \"omitted\": {")
        lines += omitted.entries.joinToString(",\n") { (key, reason) -> "    ${quote(key)}: ${quote(reason)}" }
        lines += "  },"
        lines += "  \"samples\": ["
        lines += samples().entries.joinToString(",\n") { (type, body) ->
            "    {\"type\":${quote(type)},\"via\":${quote("asBody($type)")},\"body\":$body}"
        }
        lines += "  ]"
        lines += "}"
        lines += ""
        return lines.joinToString("\n")
    }

    /** `SDK/wire-samples/kotlin.json`: beside the inventory, found by walking up (never the override). */
    private fun wireSampleFile(): File {
        var directory: File? = File(".").absoluteFile
        repeat(8) {
            val candidate = directory ?: return@repeat
            if (File(candidate, "endpoint-inventory.json").isFile) return File(File(candidate, "wire-samples"), "kotlin.json")
            directory = candidate.parentFile
        }
        error("could not locate SDK/endpoint-inventory.json from ${File(".").absolutePath}")
    }

    private companion object {
        const val RECORD_COMMAND = "IM_RECORD_WIRE_SAMPLES=1 ./gradlew test --tests \"*RequestWireKindTest*\" (in SDK/kotlin)"
    }

    /**
     * Walks a sample against the inventory's C# types. Only kinds, never values: a value that is
     * wrong but of the right kind is the endpoint's business, and a wrong kind never reaches it.
     */
    private class Sweep(
        private val types: JsonObject,
        private val enums: Set<String>,
        private val omitted: Set<String>,
    ) {
        val problems = mutableListOf<String>()
        var checked = 0

        private val collection = Regex("""^(?:List|IList|IReadOnlyList|IEnumerable|ICollection|IReadOnlyCollection|HashSet|ISet|IReadOnlySet)<(.+)>$""")
        private val dictionary = Regex("""^(?:Dictionary|IDictionary|IReadOnlyDictionary)<\s*string\s*,\s*(.+)>$""")
        private val integers = setOf("long", "int", "short", "byte", "ulong", "uint", "ushort", "sbyte")
        private val fractions = setOf("double", "float", "decimal")

        fun checkObject(type: String, value: JsonObject, path: String) {
            val properties = (types[type] as? JsonObject)?.get("properties")?.jsonArray?.map { it.jsonObject }
            if (properties == null) {
                problems += "$path: the inventory has no payload type $type"
                return
            }
            val names = properties.map { it.getValue("name").jsonPrimitive.content }.toSet()
            for (key in value.keys - names) problems += "$path.$key: sent, but the server's $type has no such field"
            for (property in properties) {
                val name = property.getValue("name").jsonPrimitive.content
                val csType = property.getValue("type").jsonPrimitive.content
                val element = value[name]
                if (element == null || element is JsonNull) {
                    if ("$type.$name" !in omitted) {
                        problems += "$path.$name ($csType): not in the sample — populate it, or declare it omitted with a reason"
                    }
                    continue
                }
                checked += 1
                checkValue(csType, element, "$path.$name")
            }
        }

        private fun checkValue(csType: String, element: JsonElement, path: String) {
            val type = csType.trim().removeSuffix("?").trim()
            collection.matchEntire(type)?.let { match ->
                val array = element as? JsonArray ?: return fail(path, csType, "a JSON array", element)
                if (array.isEmpty()) problems += "$path ($csType): sampled as [] — that proves nothing about the elements"
                array.forEachIndexed { i, item -> checkValue(match.groupValues[1], item, "$path[$i]") }
                return
            }
            dictionary.matchEntire(type)?.let { match ->
                val map = element as? JsonObject ?: return fail(path, csType, "a JSON object", element)
                val valueType = match.groupValues[1].trim().removeSuffix("?")
                if (valueType == "object") return
                if (map.isEmpty()) problems += "$path ($csType): sampled as {} — that proves nothing about the values"
                map.forEach { (key, item) -> checkValue(valueType, item, "$path.$key") }
                return
            }
            val primitive = element as? JsonPrimitive
            when {
                type == "object" -> Unit
                type == "string" ->
                    if (primitive == null || !primitive.isString) fail(path, csType, "a JSON string", element)
                type == "bool" ->
                    if (primitive == null || primitive.isString || primitive.booleanOrNull == null) {
                        fail(path, csType, "true or false", element)
                    }
                type in integers || type in enums ->
                    if (primitive == null || primitive.isString || primitive.content.toLongOrNull() == null) {
                        fail(path, csType, if (type in enums) "the enum's integer" else "a bare JSON integer", element)
                    }
                type in fractions ->
                    if (primitive == null || primitive.isString || primitive.content.toDoubleOrNull() == null) {
                        fail(path, csType, "a bare JSON number", element)
                    }
                types[type] is JsonObject ->
                    (element as? JsonObject)?.let { checkObject(type, it, path) } ?: fail(path, csType, "a JSON object", element)
                else -> problems += "$path: the server type $csType is not one this sweep knows — teach it"
            }
        }

        private fun fail(path: String, csType: String, expected: String, element: JsonElement) {
            problems += "$path: the server's field is $csType, which binds from $expected; sent $element"
        }
    }

    /**
     * `SDK/endpoint-inventory.json`, found by walking up. `IM_ENDPOINT_INVENTORY` points at another
     * copy, so a freshly generated inventory can judge this SDK before it is committed.
     */
    private fun inventoryFile(): File {
        System.getenv("IM_ENDPOINT_INVENTORY")?.takeIf { it.isNotBlank() }?.let { return File(it) }
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
