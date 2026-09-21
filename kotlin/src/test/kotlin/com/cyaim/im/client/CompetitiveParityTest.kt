@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Tier T3 — CONTRACT.md §3's "competitive parity" row: group administration, pins, favourites,
 * search, burn-after-reading, the read-by detail, `conv.markUnread`, `user.setStatus` and
 * `friend.setRemark`.
 *
 * Every assertion here is on the frame, not on the method existing. The failure this tier is most
 * exposed to is invisible at the call site: a request field of the wrong JSON *type* is not coerced
 * by the gateway — it binds request bodies field by field, without the serializer's number
 * handling — so a message id sent as a number, or a role sent as a string, comes back
 * `1000 InternalError` before the endpoint runs. So each test says what type every field leaves
 * as, and the replies are built in the gateway's real envelope: an ack carries **no** `data` key at
 * all, and message ids arrive quoted.
 *
 * 每条断言都落在线路帧上：字段的 JSON 类型错了，网关不会替你转换，而是直接回 1000。
 */
class CompetitiveParityTest {

    /**
     * A message id past 2^53 with an odd low bit. No double can hold it, so a decoder that goes
     * through one — or an encoder that writes it as a number a JavaScript peer then rounds — cannot
     * land on these digits by accident.
     */
    private val bigId = 360_306_324_097_966_083L

    private val payloads: Map<String, JsonElement> = mapOf(
        "msg.pins" to buildJsonArray {
            add(
                buildJsonObject {
                    put("messageId", bigId.toString())
                    put("seq", 42)
                    put("pinnedBy", "alice")
                    put("pinnedAt", 1_758_412_790_000L)
                    put(
                        "brief",
                        buildJsonObject {
                            put("messageId", bigId.toString())
                            put("seq", 42)
                            put("senderId", "bob")
                            put("contentType", 2)
                            put("digest", "[Image]")
                            put("createTime", 1_758_412_700_000L)
                            put("recalled", false)
                        },
                    )
                },
            )
        },
        "msg.favourites" to messagePage(nextCursor = "f2"),
        "msg.search" to messagePage(nextCursor = "s2"),
        "msg.receiptDetail" to buildJsonObject {
            put("appId", "app-1")
            put("conversationId", "g_team")
            put("messageId", bigId.toString())
            put("readUserIds", buildJsonArray { add(JsonPrimitive("bob")); add(JsonPrimitive("carol")) })
            put("readCount", 2)
            put("totalCount", 8)
            put("updatedAt", 1_758_412_790_000L)
        },
        "group.applicationList" to buildJsonObject {
            put(
                "items",
                buildJsonArray {
                    add(
                        buildJsonObject {
                            put("appId", "app-1")
                            put("groupId", "team")
                            put("applicantId", "dave")
                            put("inviterId", "carol")
                            put("reason", "carol said to ask")
                            put("status", 0)
                            put("createdAt", 1_758_412_000_000L)
                        },
                    )
                    add(
                        buildJsonObject {
                            put("appId", "app-1")
                            put("groupId", "ops")
                            put("applicantId", "erin")
                            put("status", 2)
                            put("handlerId", "alice")
                            put("handleReason", "not this quarter")
                            put("createdAt", 1_758_411_000_000L)
                            put("handledAt", 1_758_411_500_000L)
                        },
                    )
                    add(
                        buildJsonObject {
                            put("groupId", "ops")
                            put("applicantId", "frank")
                            put("status", 7)
                        },
                    )
                },
            )
            put("hasMore", false)
        },
    )

    /** The fifteen T3 targets whose reply is a plain `ApiResult` with nothing to decode. */
    private val acks = setOf(
        "msg.pin", "msg.unpin", "msg.favourite", "msg.unfavourite", "msg.burn",
        "friend.setRemark", "user.setStatus", "conv.markUnread",
        "group.transfer", "group.handleApplication", "group.setRole", "group.mute", "group.muteMember",
        "group.setNickname", "group.announcement",
    )

    private fun gateway(): FakeGateway = FakeGateway().apply {
        onRequest = { request ->
            when (val target = request.target) {
                "conn.sync" -> resumePage(request)
                in payloads -> answer(request, payloads.getValue(target))
                in acks -> ack(request)
                else -> null
            }
        }
    }

    // ------------------------------------------------------------------------ coverage

    /**
     * The tier is read out of the inventory rather than listed here, so a target added to T3 on the
     * server shows up as a failure in this SDK instead of as a row nobody typed.
     */
    @Test
    fun `every T3 endpoint in the inventory has a typed method, and ImSdk says so`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)
        val before = gateway.latest.sent.size

        settle { driveEveryT3Method(client) }

        // Session traffic (a heartbeat, a push registration) is not what this counts.
        val sent = gateway.latest.sent.drop(before).map { it.target }
            .filterNot { it.startsWith("conn.") || it.startsWith("diag.") || it.startsWith("push.") }
            .toSet()
        assertEquals(inventoryTargets("T3"), sent)
        assertTrue("T3" in ImSdk.tiers, "ImSdk.tiers publishes the matrix; it has to say T3 is typed")
    }

    // ---------------------------------------------------------------------- message ids

    @Test
    fun `every T3 call that names a message sends its id quoted, every digit intact`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)
        val request = ConversationMessageRequest("g_team", bigId)

        settle {
            client.msg.pin(request)
            client.msg.unpin(request)
            client.msg.favourite(request)
            client.msg.unfavourite(request)
            client.msg.burn(request)
            client.msg.receiptDetail(ReceiptDetailRequest("g_team", bigId))
        }

        val targets = listOf(
            "msg.pin", "msg.unpin", "msg.favourite", "msg.unfavourite", "msg.burn", "msg.receiptDetail",
        )
        for (target in targets) {
            val body = gateway.latest.requestsTo(target).single().body
            assertEquals(setOf("conversationId", "messageId"), body.keys, target)
            assertEquals("g_team", body.string("conversationId"))
            // The server's field is a C# string. A JSON number here is not read as an id at all —
            // the socket binder refuses it and the call comes back 1000 before the endpoint runs.
            assertEquals("360306324097966083", body.string("messageId"), target)
        }
    }

    /**
     * The positional overloads are sugar, and sugar that put a different frame on the wire would be
     * a second code path wearing the first one's name.
     */
    @Test
    fun `the positional overloads put the request object's frame on the wire`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.msg.pin("g_team", bigId)
            client.msg.pin(ConversationMessageRequest("g_team", bigId))
            client.msg.unpin("g_team", bigId)
            client.msg.unpin(ConversationMessageRequest("g_team", bigId))
            client.msg.favourite("g_team", bigId)
            client.msg.favourite(ConversationMessageRequest("g_team", bigId))
            client.msg.unfavourite("g_team", bigId)
            client.msg.unfavourite(ConversationMessageRequest("g_team", bigId))
            client.msg.burn("g_team", bigId)
            client.msg.burn(ConversationMessageRequest("g_team", bigId))
            client.msg.receiptDetail("g_team", bigId)
            client.msg.receiptDetail(ReceiptDetailRequest("g_team", bigId))
            client.msg.pins("g_team")
            client.msg.pins(ConversationIdRequest("g_team"))
            client.conv.markUnread("g_team")
            client.conv.markUnread(MarkUnreadRequest("g_team"))
            client.group.transfer("team", "bob")
            client.group.transfer(TransferOwnerRequest("team", "bob"))
        }

        val targets = listOf(
            "msg.pin", "msg.unpin", "msg.favourite", "msg.unfavourite", "msg.burn", "msg.receiptDetail",
            "msg.pins", "conv.markUnread", "group.transfer",
        )
        for (target in targets) {
            val (overload, explicit) = gateway.latest.requestsTo(target).map { it.body }
            assertEquals(explicit, overload, target)
        }
    }

    // ---------------------------------------------------------------------------- msg.*

    @Test
    fun `pins is a plain list, and its ids decode to the exact digits`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val pins = settle { client.msg.pins(ConversationIdRequest("g_team")) }

        assertEquals(setOf("conversationId"), gateway.latest.requestsTo("msg.pins").single().body.keys)
        val pin = pins.single()
        assertEquals(bigId, pin.messageId, "a decoder that went through a double would be off in the last digits")
        assertEquals(42L, pin.seq)
        assertEquals("alice", pin.pinnedBy)
        assertEquals(1_758_412_790_000L, pin.pinnedAt)
        val brief = assertNotNull(pin.brief)
        assertEquals(bigId, brief.messageId)
        assertEquals(MessageContentType.Image, brief.contentType)
        assertEquals("[Image]", brief.digest)
        assertFalse(brief.recalled)
    }

    @Test
    fun `favourites pages whole messages and says the server's default limit out loud`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val page = settle { client.msg.favourites() }
        settle { client.msg.favourites(PageRequest(cursor = "f2", limit = 50)) }

        val (first, second) = gateway.latest.requestsTo("msg.favourites").map { it.body }
        // No cursor key at all on the first page: a null is omitted, not written as null.
        assertEquals(setOf("limit"), first.keys)
        assertEquals(20L, first.number("limit"))
        assertEquals("f2", second.string("cursor"))
        assertEquals(50L, second.number("limit"))

        val message = page.items.single()
        assertEquals(bigId, message.messageId)
        assertEquals(bigId - 2, message.quoteMessageId)
        assertEquals("g_team", message.conversationId)
        assertTrue(page.hasMore)
        assertEquals("f2", page.nextCursor)
        assertNull(page.total, "the server never counts favourites; absent is not zero")
    }

    @Test
    fun `search sends content types as integers and times as numbers, and omits what is unset`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val page = settle {
            client.msg.search(
                SearchMessagesRequest(
                    keyword = "invoice",
                    conversationId = "g_team",
                    contentTypes = listOf(MessageContentType.Text, MessageContentType.File, MessageContentType(777)),
                    startTime = 1_756_684_800_000L,
                ),
            )
        }

        val body = gateway.latest.requestsTo("msg.search").single().body
        assertEquals(setOf("keyword", "conversationId", "contentTypes", "startTime", "limit"), body.keys)
        assertEquals("invoice", body.string("keyword"))
        assertEquals("g_team", body.string("conversationId"))
        // The server's enum binds from an integer only: "Text" would be refused with 1000. An
        // unknown code goes out as it came in rather than being dropped.
        val types = body.getValue("contentTypes").jsonArray.map { it.jsonPrimitive }
        assertTrue(types.none { it.isString }, "content types must leave as integers: $types")
        assertEquals(listOf(1L, 5L, 777L), types.map { it.longOrNull })
        assertEquals(1_756_684_800_000L, body.number("startTime"))
        assertEquals(20L, body.number("limit"))

        assertEquals(bigId, page.items.single().messageId)
        assertEquals("s2", page.nextCursor)
        assertTrue(page.hasMore)
    }

    /**
     * Search is off by default and rate limited on its own, and neither answer is data: both reach
     * the caller as the exception, with the code to branch on and the target that produced it.
     */
    @Test
    fun `search refusals and a slow index reach the caller as ImException`() = runTest {
        var reply: (JsonObject) -> JsonObject = { request -> ack(request) }
        val gateway = FakeGateway().apply {
            onRequest = { request ->
                when (request.target) {
                    "conn.sync" -> resumePage(request)
                    "msg.search" -> reply(request)
                    else -> null
                }
            }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        suspend fun failure(): ImException = assertNotNull(
            settle { runCatching { client.msg.search(SearchMessagesRequest("invoice")) } }
                .exceptionOrNull() as? ImException,
        )

        reply = { request -> refuse(request, ImErrorCode.FeatureNotEnabled, "search is not enabled for this app") }
        val disabled = failure()
        assertEquals(ImErrorCode.FeatureNotEnabled, disabled.code)
        assertEquals("msg.search", disabled.target)

        reply = { request -> refuse(request, ImErrorCode.RateLimited, "search rate limit exceeded") }
        assertEquals(ImErrorCode.RateLimited, failure().code)

        // An index slower than five seconds is status 1 on the transport, not 1004.
        reply = { request -> threw(request) }
        val slow = failure()
        assertEquals(ImErrorCode.InternalError, slow.code)
        assertEquals("0HN7-trace", slow.traceId)
    }

    @Test
    fun `receiptDetail decodes the read-by list with its sender-inclusive total`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val receipt = settle { client.msg.receiptDetail(ReceiptDetailRequest("g_team", bigId)) }

        assertEquals(bigId, receipt.messageId)
        assertEquals("g_team", receipt.conversationId)
        assertEquals(listOf("bob", "carol"), receipt.readUserIds)
        assertEquals(2, receipt.readCount)
        assertEquals(8, receipt.totalCount)
        assertEquals(1_758_412_790_000L, receipt.updatedAt)
    }

    @Test
    fun `a business refusal on an ack endpoint throws instead of returning`() = runTest {
        val gateway = FakeGateway().apply {
            onRequest = { request ->
                when (request.target) {
                    "conn.sync" -> resumePage(request)
                    "msg.pin" -> refuse(
                        request,
                        ImErrorCode.Conflict,
                        "this conversation already has 20 pinned messages; unpin one first",
                    )
                    else -> null
                }
            }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        val failure = settle { runCatching { client.msg.pin("g_team", bigId) } }.exceptionOrNull()

        val error = assertIs<ImException>(failure)
        assertEquals(ImErrorCode.Conflict, error.code)
        assertEquals("msg.pin", error.target)
    }

    // ---------------------------------------------------------------- conv / user / friend

    @Test
    fun `markUnread writes the flag as a boolean, and a false is not dropped`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.conv.markUnread(MarkUnreadRequest("g_team"))
            client.conv.markUnread("g_team", unread = false)
        }

        val (marked, cleared) = gateway.latest.requestsTo("conv.markUnread").map { it.body }
        assertEquals(setOf("conversationId", "unread"), marked.keys)
        assertEquals(true, marked.flag("unread"))
        assertEquals(false, cleared.flag("unread"), "false is the only way to clear the mark; omitting it means true")
    }

    @Test
    fun `setStatus sends the text, and clearing it sends an empty body`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.user.setStatus(SetStatusRequest("in a meeting"))
            client.user.setStatus(SetStatusRequest())
        }

        val (set, cleared) = gateway.latest.requestsTo("user.setStatus").map { it.body }
        assertEquals("in a meeting", set.string("status"))
        assertEquals(JsonObject(emptyMap()), cleared)
    }

    @Test
    fun `setRemark sends tags as strings and leaves a null remark off the frame`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.friend.setRemark(SetRemarkRequest("bob", remark = "Bob (work)", tags = listOf("work", "vip")))
            client.friend.setRemark(SetRemarkRequest("bob", tags = emptyList()))
        }

        val (full, tagsOnly) = gateway.latest.requestsTo("friend.setRemark").map { it.body }
        assertEquals("bob", full.string("userId"))
        assertEquals("Bob (work)", full.string("remark"))
        assertEquals(listOf("work", "vip"), full.getValue("tags").jsonArray.map { it.jsonPrimitive.content })
        assertTrue(full.getValue("tags").jsonArray.all { it.jsonPrimitive.isString })
        // An empty list is a value — "clear the tags" — and has to survive encoding as one.
        assertEquals(setOf("userId", "tags"), tagsOnly.keys)
        assertEquals(JsonArray(emptyList()), tagsOnly.getValue("tags"))
    }

    // --------------------------------------------------------------------------- group.*

    @Test
    fun `transfer names the new owner and nothing else`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle { client.group.transfer(TransferOwnerRequest("team", "bob")) }

        val body = gateway.latest.requestsTo("group.transfer").single().body
        assertEquals(setOf("groupId", "newOwnerId"), body.keys)
        assertEquals("team", body.string("groupId"))
        assertEquals("bob", body.string("newOwnerId"))
    }

    @Test
    fun `applicationList defaults to every group I manage and keeps every status it is given`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val page = settle { client.group.applicationList() }

        val body = gateway.latest.requestsTo("group.applicationList").single().body
        assertEquals("", body.string("groupId"), "an empty group id is the server's 'every group I manage'")
        assertEquals(50L, body.number("limit"))

        val (pending, rejected, unknown) = page.items
        assertEquals(ApplicationStatus.Pending, pending.status)
        assertEquals("dave", pending.applicantId)
        assertEquals("carol", pending.inviterId)
        assertNull(pending.handledAt)
        assertEquals(ApplicationStatus.Rejected, rejected.status)
        assertEquals("alice", rejected.handlerId)
        assertEquals("not this quarter", rejected.handleReason)
        assertEquals(1_758_411_500_000L, rejected.handledAt)
        // An open enum: a status this build does not know keeps its number instead of collapsing.
        assertEquals(7, unknown.status.code)
        assertFalse(page.hasMore)
    }

    @Test
    fun `handleApplication writes a rejection out loud`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.group.handleApplication(HandleApplicationRequest("team", "dave", accept = false, reason = "full"))
            client.group.handleApplication(HandleApplicationRequest("team", "erin", accept = true))
        }

        val (rejected, accepted) = gateway.latest.requestsTo("group.handleApplication").map { it.body }
        assertEquals(setOf("groupId", "applicantId", "accept", "reason"), rejected.keys)
        assertEquals("dave", rejected.string("applicantId"))
        assertEquals(false, rejected.flag("accept"))
        assertEquals("full", rejected.string("reason"))
        assertEquals(setOf("groupId", "applicantId", "accept"), accepted.keys)
        assertEquals(true, accepted.flag("accept"))
    }

    /**
     * The server stores any integer it is given here: `0` escapes a group-wide mute, `4` outranks
     * the admins. So the method refuses them — and `Owner`, which the server refuses with a
     * pointer to `group.transfer` — before a frame is written.
     */
    @Test
    fun `setRole sends the role as an integer and refuses what the server would store wrongly`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.group.setRole(SetRoleRequest("team", "bob", GroupRole.Admin))
            client.group.setRole(SetRoleRequest("team", "bob", GroupRole.Member))
        }

        val (promoted, demoted) = gateway.latest.requestsTo("group.setRole").map { it.body }
        assertEquals(setOf("groupId", "userId", "role"), promoted.keys)
        assertEquals("bob", promoted.string("userId"))
        assertEquals(2L, promoted.number("role"))
        assertEquals(1L, demoted.number("role"))

        val owner = assertFailsWith<IllegalArgumentException> {
            client.group.setRole(SetRoleRequest("team", "bob", GroupRole.Owner))
        }
        assertTrue("group.transfer" in owner.message.orEmpty(), owner.message)
        for (role in listOf(GroupRole(0), GroupRole(4))) {
            assertFailsWith<IllegalArgumentException> { client.group.setRole(SetRoleRequest("team", "bob", role)) }
        }
        assertEquals(2, gateway.latest.requestsTo("group.setRole").size, "a refused role never reaches the socket")
    }

    @Test
    fun `mute and muteMember send untilMs as a number and leave it off when null`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.group.mute(MuteGroupRequest("team"))
            client.group.mute(MuteGroupRequest("team", untilMs = 1_758_499_200_000L))
            client.group.mute(MuteGroupRequest("team", mute = false))
            client.group.muteMember(MuteMemberRequest("team", "bob", untilMs = 1_758_499_200_000L))
            client.group.muteMember(MuteMemberRequest("team", "bob"))
        }

        val (indefinite, until, unmuted) = gateway.latest.requestsTo("group.mute").map { it.body }
        assertEquals(setOf("groupId", "mute"), indefinite.keys)
        assertEquals(true, indefinite.flag("mute"))
        assertEquals(1_758_499_200_000L, until.number("untilMs"))
        assertEquals(false, unmuted.flag("mute"))

        val (muted, released) = gateway.latest.requestsTo("group.muteMember").map { it.body }
        assertEquals("bob", muted.string("userId"))
        assertEquals(1_758_499_200_000L, muted.number("untilMs"))
        assertEquals(setOf("groupId", "userId"), released.keys, "no untilMs is how a member is unmuted")
    }

    @Test
    fun `setNickname and announcement leave null fields off the frame`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.group.setNickname(SetGroupNicknameRequest("team", nickname = "Captain"))
            client.group.setNickname(SetGroupNicknameRequest("team", userId = "bob", nickname = "Bobby"))
            client.group.announcement(AnnouncementRequest("team", "Standup moves to 10:00"))
            client.group.announcement(AnnouncementRequest("team"))
        }

        val (mine, theirs) = gateway.latest.requestsTo("group.setNickname").map { it.body }
        assertEquals(setOf("groupId", "nickname"), mine.keys, "no userId means the caller's own nickname")
        assertEquals("Captain", mine.string("nickname"))
        assertEquals("bob", theirs.string("userId"))

        val (posted, cleared) = gateway.latest.requestsTo("group.announcement").map { it.body }
        assertEquals("Standup moves to 10:00", posted.string("announcement"))
        assertEquals(setOf("groupId"), cleared.keys)
    }

    // ------------------------------------------------------------------------- harness

    /** One call to each of the twenty, through the request-object form. */
    private suspend fun driveEveryT3Method(client: ImClient) {
        val message = ConversationMessageRequest("g_team", bigId)
        client.msg.pin(message)
        client.msg.unpin(message)
        client.msg.pins(ConversationIdRequest("g_team"))
        client.msg.favourite(message)
        client.msg.unfavourite(message)
        client.msg.favourites(PageRequest())
        client.msg.burn(message)
        client.msg.search(SearchMessagesRequest("invoice"))
        client.msg.receiptDetail(ReceiptDetailRequest("g_team", bigId))
        client.conv.markUnread(MarkUnreadRequest("g_team"))
        client.user.setStatus(SetStatusRequest("in a meeting"))
        client.friend.setRemark(SetRemarkRequest("bob", "Bob"))
        client.group.transfer(TransferOwnerRequest("team", "bob"))
        client.group.applicationList(GroupCursorRequest("team"))
        client.group.handleApplication(HandleApplicationRequest("team", "dave", accept = true))
        client.group.setRole(SetRoleRequest("team", "bob", GroupRole.Admin))
        client.group.mute(MuteGroupRequest("team"))
        client.group.muteMember(MuteMemberRequest("team", "bob", 1_758_499_200_000L))
        client.group.setNickname(SetGroupNicknameRequest("team", nickname = "Captain"))
        client.group.announcement(AnnouncementRequest("team", "hello"))
    }

    /** Runs [block] against the scripted gateway and hands back what it returned. */
    private suspend fun <T> TestScope.settle(block: suspend () -> T): T {
        val call = backgroundScope.async { block() }
        runCurrent()
        return call.await()
    }

    private fun messagePage(nextCursor: String): JsonObject = buildJsonObject {
        put(
            "items",
            buildJsonArray {
                add(
                    buildJsonObject {
                        put("appId", "app-1")
                        put("conversationId", "g_team")
                        put("conversationType", 2)
                        put("seq", 42)
                        put("messageId", bigId.toString())
                        put("clientMsgId", "cid-42")
                        put("senderId", "bob")
                        put("senderPlatform", 2)
                        put("contentType", 1)
                        put("content", buildJsonObject { put("text", "the invoice is attached") })
                        put("quoteMessageId", (bigId - 2).toString())
                        put("sendTime", 1_758_412_700_000L)
                        put("createTime", 1_758_412_700_000L)
                    },
                )
            },
        )
        put("nextCursor", nextCursor)
        put("hasMore", true)
    }

    /** A plain ack exactly as the gateway writes it: no `data` key at all, rather than `data: null`. */
    private fun ack(request: JsonObject): JsonObject = envelope(request, status = 0) {
        put("code", ImErrorCode.Ok)
        put("serverTime", 1_758_412_800_000L)
        put("isSuccess", true)
    }

    private fun answer(request: JsonObject, data: JsonElement): JsonObject = envelope(request, status = 0) {
        put("code", ImErrorCode.Ok)
        put("serverTime", 1_758_412_800_000L)
        put("isSuccess", true)
        put("data", data)
    }

    private fun refuse(request: JsonObject, code: Int, message: String): JsonObject = envelope(request, status = 0) {
        put("code", code)
        put("message", message)
        put("serverTime", 1_758_412_800_000L)
        put("isSuccess", false)
    }

    /** The endpoint threw (or the socket could not bind the body): transport status 1. */
    private fun threw(request: JsonObject): JsonObject = envelope(request, status = 1) {
        put("code", ImErrorCode.InternalError)
        put("message", "internal error")
        put("traceId", "0HN7-trace")
        put("serverTime", 1_758_412_800_000L)
        put("isSuccess", false)
    }

    private fun envelope(
        request: JsonObject,
        status: Int,
        body: JsonObjectBuilder.() -> Unit,
    ): JsonObject = buildJsonObject {
        put("id", request.id)
        put("target", request.target)
        put("status", status)
        // .NET ticks, past 2^53. Diagnostic only, and they must not trip the decoder.
        put("requestTime", 639_254_400_000_000_000L)
        put("completeTime", 639_254_400_001_234_567L)
        put("body", buildJsonObject(body))
    }

    private fun JsonObject.string(key: String): String {
        val value = assertIs<JsonPrimitive>(getValue(key), key)
        assertTrue(value.isString, "$key has to leave as a JSON string, not $value")
        return value.content
    }

    private fun JsonObject.number(key: String): Long {
        val value = assertIs<JsonPrimitive>(getValue(key), key)
        assertFalse(value.isString, "$key has to leave as a JSON number, not the string $value")
        return assertNotNull(value.longOrNull, "$key is not an integer: $value")
    }

    private fun JsonObject.flag(key: String): Boolean {
        val value = assertIs<JsonPrimitive>(getValue(key), key)
        assertFalse(value.isString, "$key has to leave as a JSON boolean, not the string $value")
        return assertNotNull(value.booleanOrNull, "$key is not a boolean: $value")
    }

    /** The targets of one tier, out of `sdk/endpoint-inventory.json`. */
    private fun inventoryTargets(tier: String): Set<String> {
        var directory: File? = File(".").absoluteFile
        repeat(8) {
            val candidate = directory ?: return@repeat
            val inventory = File(candidate, "endpoint-inventory.json")
            if (inventory.isFile) {
                val targets = ImJson.parseToJsonElement(inventory.readText()).jsonObject
                    .getValue("tiers").jsonObject
                    .getValue(tier).jsonObject
                    .getValue("targets").jsonArray
                    .map { it.jsonPrimitive.content }
                    .toSet()
                assertTrue(targets.isNotEmpty(), "the inventory lists no $tier targets")
                return targets
            }
            directory = candidate.parentFile
        }
        error("could not locate sdk/endpoint-inventory.json from ${File(".").absolutePath}")
    }
}
