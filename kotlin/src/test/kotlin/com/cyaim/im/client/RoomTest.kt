@file:OptIn(ExperimentalCoroutinesApi::class)

package com.cyaim.im.client

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
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
 * `room.*` — the seven chat-room calls, the `room.*` events inside `evt.system`, and the one rule a
 * room imposes on the rest of the client: **its messages carry seq 0 and never enter cursors or gap
 * repair**.
 *
 * Every call is asserted on the frame it puts on the wire — target and the whole body, by JSON kind —
 * and on what it makes of a reply with every field set. The seq-0 tests are the reason this family
 * needed typing at all: a client that fed a room message into the repair path would ask `msg.sync`
 * for a range that does not exist on every message, or move a conversation's cursor with a number
 * that means nothing.
 *
 * 每个调用都断言发出的整帧与对满字段答复的解码；seq 0 那几条是这一族非类型化不可的原因：
 * 把聊天室消息喂进补洞的客户端会对每条消息去要一段不存在的区间，或者用一个毫无意义的数去动会话游标。
 */
class RoomTest {

    /** Past 2^53 and odd, so a trip through a double would change its last digit. */
    private val bigId = 360_381_357_961_969_667L

    private fun chatRoom(): JsonObject = buildJsonObject {
        // Every member of the server's ChatRoom, each with a value no default reads as — so a key
        // spelled wrong on this side decodes to a default and an assertion below fails.
        // `the full fixtures carry every member the server declares` holds the list to the inventory.
        put("appId", "demo")
        put("roomId", "lobby")
        put("name", "Launch stream")
        put("avatar", "rooms/lobby.png")
        put("ownerId", "alice")
        putJsonArray("admins") { add(JsonPrimitive("carol")) }
        put("maxOnline", 5_000_000_000L)
        put("historyBufferSize", 20)
        put("rateLimitPerSecond", 150)
        put("muteAll", true)
        put("destroyed", true)
        put("createdAt", 1_755_000_000_000L)
        putJsonObject("extensions") { put("topic", "launch") }
    }

    /** A room message as the server builds one: seq 0, `r_<roomId>`, type ChatRoom, online only. */
    private fun roomMessage(roomId: String, n: Int, sender: String = "bob"): JsonObject = buildJsonObject {
        put("appId", "demo")
        put("conversationId", "r_$roomId")
        put("conversationType", 3)
        put("seq", 0)
        put("messageId", (bigId + n).toString())
        put("clientMsgId", "room-$n")
        put("senderId", sender)
        put("senderPlatform", 2)
        put("contentType", 1)
        putJsonObject("content") { put("text", "wave $n") }
        putJsonObject("options") {
            put("persistent", false)
            put("updateConversation", false)
            put("countUnread", false)
            put("offlinePush", false)
            put("onlineOnly", true)
            put("priority", 1)
        }
        put("sendTime", 1_755_000_000_000L + n)
        put("createTime", 1_755_000_000_000L + n)
    }

    private fun joinResult(): JsonObject = buildJsonObject {
        put("room", chatRoom())
        put("onlineCount", 3_000_000_000L)
        put("recent", buildJsonArray { add(roomMessage("lobby", 1)); add(roomMessage("lobby", 2)) })
    }

    private fun sendResult(request: JsonObject): JsonObject = buildJsonObject {
        // The server's SendMessageResult for a room: seq is always 0, the id is a string.
        put("messageId", (bigId + 10).toString())
        put("seq", 0)
        put("conversationId", "r_" + request.bodyString("roomId"))
        put("clientMsgId", request.body.getValue("message").jsonObject.jsonString("clientMsgId"))
        put("createTime", 1_755_000_000_500L)
        put("deduplicated", true)
        put("contentModified", true)
    }

    private fun gateway(): FakeGateway = FakeGateway().apply {
        onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "room.join" -> replyTo(request, joinResult())
                "room.send" -> replyTo(request, sendResult(request))
                "room.onlineCount" -> replyTo(request, JsonPrimitive(3_000_000_000L))
                "room.memberList" -> replyTo(
                    request,
                    buildJsonObject {
                        putJsonArray("items") { add(JsonPrimitive("bob")); add(JsonPrimitive("carol")) }
                        put("nextCursor", "1")
                        put("hasMore", true)
                    },
                )
                "room.quit", "room.mute", "room.kick" -> replyTo(request, JsonNull)
                else -> null
            }
        }
    }

    private suspend fun <T> TestScope.settle(block: suspend () -> T): T {
        val call = backgroundScope.async { block() }
        runCurrent()
        return call.await()
    }

    // ------------------------------------------------------------------------------- the calls

    @Test
    fun `room join sends only the room and decodes the room, the head count and the recent messages`() = runTest {
        val gateway = gateway()
        val store = RecordingCursorStore()
        val client = newClient(gateway, store = store)
        val received = collectMessages(client)
        openClient(client, gateway)

        val joined = settle { client.room.join(RoomIdRequest("lobby")) }

        val body = gateway.latest.requestsTo("room.join").single().body
        assertEquals(setOf("roomId"), body.keys)
        assertEquals("lobby", body.jsonString("roomId"))

        val room = joined.room
        assertEquals("demo", room.appId)
        assertEquals("lobby", room.roomId)
        assertEquals("Launch stream", room.name)
        assertEquals("rooms/lobby.png", room.avatar)
        assertEquals("alice", room.ownerId)
        assertEquals(listOf("carol"), room.admins)
        assertEquals(5_000_000_000L, room.maxOnline, "maxOnline is a long")
        assertEquals(20, room.historyBufferSize)
        assertEquals(150, room.rateLimitPerSecond)
        assertTrue(room.muteAll)
        assertTrue(room.destroyed)
        assertEquals(1_755_000_000_000L, room.createdAt)
        assertEquals("launch", room.extensions?.jsonString("topic"))
        assertEquals(3_000_000_000L, joined.onlineCount, "onlineCount is a long")

        assertEquals(listOf(bigId + 1, bigId + 2), joined.recent.map { it.messageId }, "string ids, every digit kept")
        val first = joined.recent.first()
        assertEquals(0L, first.seq)
        assertEquals("r_lobby", first.conversationId)
        assertEquals(ConversationType.ChatRoom, first.conversationType)
        assertEquals("wave 1", first.text)
        assertEquals(false, first.options?.persistent)
        assertEquals(true, first.options?.onlineOnly)

        // The buffer is handed to the caller and nowhere else: not replayed as live traffic, and not
        // a reason to touch a cursor.
        runCurrent()
        assertTrue(received.isEmpty(), "join's recent messages are not replayed on messages: $received")
        assertEquals(0L, client.committedSeq("r_lobby"))
        assertTrue(store.saves.none { "r_lobby" in it.convSeqs }, "a room never reaches the cursor store")
        assertTrue(gateway.latest.requestsTo("msg.sync").isEmpty())
    }

    @Test
    fun `room quit and onlineCount send only the room, and onlineCount answers a bare long`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val count = settle { client.room.onlineCount(RoomIdRequest("lobby")) }
        settle { client.room.quit(RoomIdRequest("lobby")) }

        for (target in listOf("room.onlineCount", "room.quit")) {
            val body = gateway.latest.requestsTo(target).single().body
            assertEquals(setOf("roomId"), body.keys, "$target: $body")
            assertEquals("lobby", body.jsonString("roomId"))
        }
        assertEquals(3_000_000_000L, count)
    }

    @Test
    fun `room memberList sends the default limit, passes the cursor back, and decodes a sample page`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val page = settle { client.room.memberList(RoomCursorRequest("lobby")) }
        settle { client.room.memberList(RoomCursorRequest("lobby", cursor = page.nextCursor, limit = 100)) }

        val (first, next) = gateway.latest.requestsTo("room.memberList").map { it.body }
        assertEquals(setOf("roomId", "limit"), first.keys, "no cursor on the first page: $first")
        assertEquals("lobby", first.jsonString("roomId"))
        assertEquals(50L, first.jsonInteger("limit"))
        assertEquals(setOf("roomId", "cursor", "limit"), next.keys)
        assertEquals("1", next.jsonString("cursor"))
        assertEquals(100L, next.jsonInteger("limit"))

        assertEquals(listOf("bob", "carol"), page.items)
        assertEquals("1", page.nextCursor)
        assertTrue(page.hasMore)
        assertNull(page.total)
    }

    @Test
    fun `room mute writes each absence only when it is asked for`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle {
            client.room.mute(RoomMuteRequest("lobby", userId = "bob", untilMs = 1_755_000_060_000L))
            client.room.mute(RoomMuteRequest("lobby", userId = null, untilMs = 1_755_000_060_000L))
            client.room.mute(RoomMuteRequest("lobby", userId = null, untilMs = null))
        }

        val (member, room, lifted) = gateway.latest.requestsTo("room.mute").map { it.body }
        assertEquals(setOf("roomId", "userId", "untilMs"), member.keys)
        assertEquals("lobby", member.jsonString("roomId"))
        assertEquals("bob", member.jsonString("userId"))
        assertEquals(1_755_000_060_000L, member.jsonInteger("untilMs"))

        assertEquals(setOf("roomId", "untilMs"), room.keys, "no userId is the whole room: $room")
        assertEquals(setOf("roomId"), lifted.keys, "no untilMs lifts the mute — never written as null: $lifted")
    }

    @Test
    fun `room kick names the room and the member`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        settle { client.room.kick(RoomKickRequest("lobby", "bob")) }

        val body = gateway.latest.requestsTo("room.kick").single().body
        assertEquals(setOf("roomId", "userId"), body.keys)
        assertEquals("lobby", body.jsonString("roomId"))
        assertEquals("bob", body.jsonString("userId"))
    }

    @Test
    fun `room send fills the key and the clock and writes the message members the room reads`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        openClient(client, gateway)

        val result = settle { client.room.send(RoomSendRequest("lobby", RoomMessage(textContent("hi")))) }
        settle {
            client.room.send(
                RoomSendRequest(
                    "lobby",
                    RoomMessage(
                        content = buildJsonObject { put("url", "media/a.png") },
                        contentType = MessageContentType.Image,
                        clientMsgId = "cid-room",
                        mentionAll = true,
                        mentionedUserIds = listOf("carol"),
                        options = MessageOptions(priority = MessagePriority.Low),
                        sendTime = 1_755_000_000_100L,
                        extensions = buildJsonObject { put("k", "v") },
                    ),
                ),
            )
        }

        val (plain, full) = gateway.latest.requestsTo("room.send").map { it.body }
        assertEquals(setOf("roomId", "message"), plain.keys)
        assertEquals("lobby", plain.jsonString("roomId"))
        val message = plain.getValue("message").jsonObject
        // Exact camelCase, because the server matches keys inside `message` case-sensitively and
        // drops a miscased one without a word.
        assertEquals(
            setOf("content", "contentType", "clientMsgId", "mentionAll", "mentionedUserIds", "sendTime"),
            message.keys,
        )
        assertEquals("hi", message.getValue("content").jsonObject.jsonString("text"))
        assertEquals(MessageContentType.Text.code.toLong(), message.jsonInteger("contentType"))
        assertTrue(message.jsonString("clientMsgId").isNotBlank(), "the server answers 1001 without one")
        assertTrue(message.jsonInteger("sendTime") > 0, "a zero clock is stamped")
        assertFalse(message.jsonBoolean("mentionAll"))
        assertEquals(emptyList(), message.jsonStrings("mentionedUserIds"))

        val rich = full.getValue("message").jsonObject
        assertEquals(
            setOf("content", "contentType", "clientMsgId", "mentionAll", "mentionedUserIds", "options", "sendTime", "extensions"),
            rich.keys,
        )
        assertEquals("cid-room", rich.jsonString("clientMsgId"), "a given key is kept")
        assertEquals(1_755_000_000_100L, rich.jsonInteger("sendTime"), "a given clock is kept")
        assertEquals(MessageContentType.Image.code.toLong(), rich.jsonInteger("contentType"))
        assertTrue(rich.jsonBoolean("mentionAll"))
        assertEquals(listOf("carol"), rich.jsonStrings("mentionedUserIds"))
        assertEquals(MessagePriority.Low.code.toLong(), rich.getValue("options").jsonObject.jsonInteger("priority"))
        assertEquals("v", rich.getValue("extensions").jsonObject.jsonString("k"))

        assertEquals(bigId + 10, result.messageId)
        assertEquals(0L, result.seq)
        assertEquals("r_lobby", result.conversationId)
        assertEquals(message.jsonString("clientMsgId"), result.clientMsgId)
        assertEquals(1_755_000_000_500L, result.createTime)
        assertTrue(result.deduplicated)
        assertTrue(result.contentModified)

        assertTrue(gateway.latest.requestsTo("msg.send").isEmpty(), "a room send is not a msg.send")
    }

    @Test
    fun `a refused room send throws with the server code`() = runTest {
        val gateway = FakeGateway()
        gateway.onRequest = { request ->
            when (request.target) {
                "conn.sync" -> resumePage(request)
                "room.send" -> replyTo(request, JsonNull, code = ImErrorCode.NotInRoom)
                else -> null
            }
        }
        val client = newClient(gateway)
        openClient(client, gateway)

        val call = backgroundScope.async {
            runCatching { client.room.send(RoomSendRequest("lobby", RoomMessage(textContent("hi")))) }
        }
        runCurrent()

        val failure = assertNotNull(call.await().exceptionOrNull() as? ImException)
        assertEquals(ImErrorCode.NotInRoom, failure.code)
        assertEquals("room.send", failure.target)
    }

    // ------------------------------------------------------------------ seq 0 stays out of repair

    @Test
    fun `a seq-0 room message is delivered at once and never enters gap repair`() = runTest {
        val gateway = gateway()
        val store = RecordingCursorStore()
        val client = newClient(gateway, store = store)
        val received = collectMessages(client)
        openClient(client, gateway)
        val socket = gateway.latest

        socket.push(PushTarget.Message, messageJson("c1", 1))
        runCurrent()
        // Three room messages, all at seq 0: each is delivered — not taken for a duplicate of the
        // last — and none is taken for a gap in its own "conversation" or in c1's.
        for (n in 1..3) socket.push(PushTarget.Message, roomMessage("lobby", n))
        runCurrent()
        socket.push(PushTarget.Message, messageJson("c1", 2))
        runCurrent()

        assertEquals(
            listOf("c1" to 1L, "r_lobby" to 0L, "r_lobby" to 0L, "r_lobby" to 0L, "c1" to 2L),
            received.map { it.conversationId to it.seq },
        )
        assertEquals(listOf("wave 1", "wave 2", "wave 3"), received.filter { it.seq == 0L }.map { it.text })
        assertTrue(socket.requestsTo("msg.sync").isEmpty(), "a room message is never a range to repair")

        // c1's cursor did not move for the room traffic, so the next real message is contiguous.
        socket.push(PushTarget.Message, messageJson("c1", 3))
        runCurrent()
        assertEquals(listOf(1L, 2L, 3L), received.filter { it.conversationId == "c1" }.map { it.seq })
        assertTrue(socket.requestsTo("msg.sync").isEmpty())

        assertEquals(0L, client.committedSeq("r_lobby"))
        client.flushCursors()
        assertTrue(store.saves.none { "r_lobby" in it.convSeqs }, "a room never reaches the cursor store")
    }

    @Test
    fun `a room message is not held behind a repair in flight`() = runTest {
        // msg.sync is left unanswered: c1's repair is still in flight when the room message lands.
        val gateway = gateway()
        val client = newClient(gateway)
        val received = collectMessages(client)
        openClient(client, gateway)
        val socket = gateway.latest

        socket.push(PushTarget.Message, messageJson("c1", 1))
        runCurrent()
        socket.push(PushTarget.Message, messageJson("c1", 5))
        runCurrent()
        assertEquals(1, socket.requestsTo("msg.sync").size, "c1 is repairing 2..4")

        socket.push(PushTarget.Message, roomMessage("lobby", 1))
        runCurrent()

        assertEquals(listOf("c1" to 1L, "r_lobby" to 0L), received.map { it.conversationId to it.seq })
        assertEquals(1, socket.requestsTo("msg.sync").size, "and the room message asked for nothing")
    }

    @Test
    fun `committing a room message changes no cursor, and a real commit still does`() = runTest {
        val gateway = gateway()
        val store = RecordingCursorStore()
        val client = newClient(gateway, store = store)
        openClient(client, gateway)

        // The application that commits everything it stores, room messages included.
        client.commit("r_lobby", 0)
        client.commit("c1", 4)
        client.flushCursors()
        runCurrent()

        assertEquals(0L, client.committedSeq("r_lobby"))
        assertEquals(4L, client.committedSeq("c1"))
        assertEquals(mapOf("c1" to 4L), store.held.convSeqs, "only the real conversation is stored")
    }

    @Test
    fun `a room send result moves no cursor`() = runTest {
        val gateway = gateway()
        val store = RecordingCursorStore()
        val client = newClient(gateway, store = store)
        val received = collectMessages(client)
        openClient(client, gateway)

        settle { client.room.send(RoomSendRequest("lobby", RoomMessage(textContent("hi")))) }
        client.flushCursors()
        runCurrent()

        assertEquals(0L, client.committedSeq("r_lobby"))
        assertTrue(store.saves.none { "r_lobby" in it.convSeqs })
        assertTrue(received.isEmpty(), "the echo, if any, is the server's evt.message — not the reply")
        assertTrue(gateway.latest.requestsTo("msg.sync").isEmpty())
    }

    // ---------------------------------------------------------------------------- room.* events

    @Test
    fun `room events come out of evt system, and nothing else on it does`() = runTest {
        val gateway = gateway()
        val client = newClient(gateway)
        val events = mutableListOf<RoomEvent>()
        backgroundScope.launch { client.roomEvents.collect { events += it } }
        openClient(client, gateway)
        val socket = gateway.latest

        fun system(event: String, body: JsonObject?) = socket.push(
            PushTarget.System,
            buildJsonObject {
                put("event", event)
                if (body != null) put("body", body)
            },
        )

        system("room.muted", buildJsonObject { put("roomId", "lobby"); put("operatorId", "alice"); put("untilMs", 1_755_000_060_000L) })
        system("room.muted", buildJsonObject { put("roomId", "lobby"); put("operatorId", "carol"); put("userId", "bob") })
        system("room.kicked", buildJsonObject { put("roomId", "lobby"); put("operatorId", "alice"); put("userId", "bob") })
        system("room.destroyed", buildJsonObject { put("roomId", "lobby"); put("operatorId", "ops") })
        system("room.renamed", buildJsonObject { put("roomId", "lobby"); put("operatorId", "ops"); put("name", "After party") })
        // Not a room's: the device-log request shares the target, and so does whatever comes next.
        system("device.logRequest", buildJsonObject { put("requestId", "lr_1"); put("deviceId", "another-device") })
        system("roomish.event", buildJsonObject { put("roomId", "lobby") })
        socket.push(PushTarget.System, JsonPrimitive("not an object"))
        socket.push(PushTarget.Message, roomMessage("lobby", 1))
        runCurrent()

        assertEquals(
            listOf(RoomEvent.MUTED, RoomEvent.MUTED, RoomEvent.KICKED, RoomEvent.DESTROYED, "room.renamed"),
            events.map { it.event },
            "only room.* events, the unknown one included: $events",
        )
        val (wholeRoom, member, kicked) = events
        val (destroyed, renamed) = events.drop(3)

        assertEquals("lobby", wholeRoom.roomId)
        assertEquals("alice", wholeRoom.operatorId)
        assertNull(wholeRoom.userId, "no userId is the whole room")
        assertEquals(1_755_000_060_000L, wholeRoom.untilMs)

        assertEquals("bob", member.userId)
        assertEquals("carol", member.operatorId)
        assertNull(member.untilMs, "no untilMs: the mute was lifted")

        assertEquals("bob", kicked.userId)
        assertEquals("alice", kicked.operatorId)
        assertNull(kicked.untilMs)

        assertEquals("lobby", destroyed.roomId)
        assertEquals("ops", destroyed.operatorId)
        assertNull(destroyed.userId)

        assertEquals("lobby", renamed.roomId)
        assertEquals("After party", renamed.body.jsonString("name"), "an unknown event keeps its whole body")
    }

    // ------------------------------------------------------------------- held to the inventory

    /**
     * The decoding tests above are only as wide as their fixtures: a member a fixture leaves out
     * decodes to its default whatever key this SDK reads it from. So the full fixtures carry every
     * member the server's type declares, and the requests send every member, held here to
     * `endpoint-inventory.json`'s `payloadTypes`.
     */
    @Test
    fun `the full fixtures carry every member the server declares`() {
        assertEquals(members("ChatRoom"), chatRoom().keys)
        assertEquals(members("RoomJoinResult"), joinResult().keys)

        assertEquals(members("RoomIdRequest"), RoomIdRequest("lobby").asBody().jsonObject.keys)
        assertEquals(members("RoomCursorRequest"), RoomCursorRequest("lobby", cursor = "1", limit = 20).asBody().jsonObject.keys)
        assertEquals(members("RoomMuteRequest"), RoomMuteRequest("lobby", "bob", 1L).asBody().jsonObject.keys)
        assertEquals(members("RoomKickRequest"), RoomKickRequest("lobby", "bob").asBody().jsonObject.keys)
        assertEquals(members("RoomSendRequest"), RoomSendRequest("lobby", RoomMessage(textContent("hi"))).asBody().jsonObject.keys)
    }

    /**
     * `RoomMessage` is the server's `SendMessageRequest` minus what a room never reads. This pins
     * both halves: every member it sends is a member of the server type (so none is dropped as
     * unknown), and what it leaves out is exactly the addressing, quoting and threading a room has no
     * use for — a member the server adds shows up here instead of going unexamined.
     */
    @Test
    fun `a room message sends server members only, and leaves out exactly what a room ignores`() {
        val full = RoomMessage(
            content = textContent("hi"), contentType = MessageContentType.Text, clientMsgId = "c", mentionAll = true,
            mentionedUserIds = listOf("bob"), options = MessageOptions(), sendTime = 1L, extensions = buildJsonObject { put("k", "v") },
        ).asBody().jsonObject.keys
        val server = members("SendMessageRequest")

        assertEquals(emptySet(), full - server, "sent, but not a member of the server's SendMessageRequest")
        assertEquals(
            setOf("conversationId", "receiverId", "groupId", "conversationType", "quoteMessageId", "threadRootId"),
            server - full,
        )
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
