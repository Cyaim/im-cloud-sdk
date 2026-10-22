package com.cyaim.im.client

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.longOrNull

/*
 * `room.*` — chat rooms (T4): their requests, what they answer, and the `room.*` events that arrive
 * inside `evt.system`. [RoomApi] is the surface that sends them.
 *
 * In a file of its own, as the desk is, because the family is typed whole or not at all
 * (CONTRACT.md §3) and a reader looking for "what does a room send and get back" should find one
 * place.
 *
 * **A room message is best effort and has no seq.** It arrives on `evt.message` as an ordinary
 * [ImMessage] whose `seq` is **0** and whose `conversationId` is `r_<roomId>`. Nothing is stored per
 * user, nothing is pushed offline, and there is no range to repair: [ImClient] hands it straight to
 * [ImClient.messages] and never lets it near a cursor or the gap-repair path. Do not commit it.
 *
 * 聊天室消息尽力而为、没有 seq：它是 evt.message 上一条 seq 为 0、conversationId 为 r_<roomId> 的普通消息。
 * 不按人存储、不发离线推送、没有可补的区间——ImClient 直接交给 messages，绝不让它碰游标或补洞管线。不要 commit 它。
 */

// ---------------------------------------------------------------------------------- requests

/**
 * `room.join`, `room.quit` and `room.onlineCount`: the room, and nothing else.
 *
 * **Membership belongs to this connection, not to the user.** After a reconnect the server no longer
 * counts this device as present and nothing is delivered until `room.join` is sent again. The SDK
 * does not rejoin for you — which rooms are still on screen is the application's knowledge.
 *
 * 成员身份属于这条连接而不是这个用户：重连之后要重新 room.join，SDK 不替你重进。
 */
@Serializable
public data class RoomIdRequest(
    public val roomId: String,
)

/**
 * `room.memberList`. **A sample of who is present, not the full list** — the server never enumerates
 * a large room exactly. Page on [Page.hasMore] / [Page.nextCursor] like every other list.
 */
@Serializable
public data class RoomCursorRequest(
    public val roomId: String,
    /** Opaque; pass back [Page.nextCursor] verbatim. Null for the first page. */
    public val cursor: String? = null,
    /** The server clamps it: 1–100 is honoured, anything else becomes 50. */
    public val limit: Int = 50,
)

/**
 * The message half of a `room.send` — the members of the server's `SendMessageRequest` that a room
 * reads, and no others.
 *
 * Not [SendMessageRequest]: a room message has no receiver, no group, no conversation to name (the
 * room is [RoomSendRequest.roomId]) and nothing to quote or thread under, and a field the server
 * ignores is a field someone will set and wonder about. The names are the server's and are matched
 * **case-sensitively** inside `message`, so they are not something to rename.
 *
 * [clientMsgId] is required by the server (`1001` without it); leave it blank and [RoomApi.send]
 * fills one in, as `msg.send` does.
 *
 * 只含聊天室真正读取的字段。message 里的键按大小写精确匹配，名字不能改；clientMsgId 留空由 SDK 补上。
 */
@Serializable
public data class RoomMessage(
    /** Shaped by [contentType]; for a text message, [textContent]. */
    public val content: JsonObject,
    /** An integer on the wire. */
    public val contentType: MessageContentType = MessageContentType.Text,
    /** The idempotency key. Blank is filled in by [RoomApi.send]. */
    public val clientMsgId: String = "",
    public val mentionAll: Boolean = false,
    public val mentionedUserIds: List<String> = emptyList(),
    /**
     * Only [MessageOptions.priority] is read on this path: the room sheds `Low` first when it is over
     * its rate. A room message is never stored or pushed offline whatever else is set here.
     */
    public val options: MessageOptions? = null,
    /** Client clock, unix ms. Zero is stamped by [RoomApi.send]; the server keeps its own `createTime`. */
    public val sendTime: Long = 0,
    public val extensions: JsonObject? = null,
)

/** `room.send`. The caller must have joined the room on this connection (`1602 NotInRoom` otherwise). */
@Serializable
public data class RoomSendRequest(
    public val roomId: String,
    public val message: RoomMessage,
)

/**
 * `room.mute`. Room owner or room admins only (`1103` otherwise), and never the owner (`1511`).
 *
 * **Both optional members mean something when absent, and the absence is the dangerous half**, so
 * neither has a default: write `null` on purpose.
 *
 * - [userId] null mutes **the whole room** (the owner and admins can still speak); a user id mutes
 *   that member alone.
 * - [untilMs] null, or a time already past, **lifts** the mute. A mute is always "until when".
 *
 * 两个可选成员缺省时都有含义，而且缺省那一半是危险的，所以都不给默认值：userId 为 null 是全员禁言；
 * untilMs 为 null 或已过去的时刻是解除禁言。
 */
@Serializable
public data class RoomMuteRequest(
    public val roomId: String,
    /** Null is the whole room. */
    public val userId: String?,
    /** Unix ms the mute ends. Null, or a past time, lifts it. */
    public val untilMs: Long?,
)

/**
 * `room.kick`. Room owner or room admins only (`1103` otherwise), and never the owner (`1511`). The
 * member's sends answer `1602 NotInRoom` afterwards; the room hears `room.kicked`.
 */
@Serializable
public data class RoomKickRequest(
    public val roomId: String,
    public val userId: String,
)

// --------------------------------------------------------------------------------- responses

/**
 * A chat room as the tenant's backend created it (`POST /v1/rooms` — there is no socket call that
 * creates one). Read-only from a device: neither the name nor the admins change over the socket.
 */
@Serializable
public data class ChatRoom(
    public val appId: String = "",
    public val roomId: String = "",
    public val name: String = "",
    public val avatar: String? = null,
    /** Can mute and kick, and can never be muted or kicked. */
    public val ownerId: String = "",
    /** Can mute and kick, as the owner can. */
    public val admins: List<String> = emptyList(),
    /** Connections allowed at once; 0 means unlimited. A full room answers `room.join` with `1601`. */
    public val maxOnline: Long = 0,
    /** How many recent messages a joiner receives in [RoomJoinResult.recent]; 0 disables it. */
    public val historyBufferSize: Int = 0,
    /** Messages per second the room accepts as a whole before shedding low-priority ones (`1003`). */
    public val rateLimitPerSecond: Int = 0,
    /** A room-wide mute is in force: only the owner and admins can send (`1603` for everyone else). */
    public val muteAll: Boolean = false,
    public val destroyed: Boolean = false,
    /** Unix ms. */
    public val createdAt: Long = 0,
    public val extensions: JsonObject? = null,
)

/** What `room.join` answers. */
@Serializable
public data class RoomJoinResult(
    public val room: ChatRoom,
    /** Connections present right after this one joined, cluster-wide. */
    public val onlineCount: Long = 0,
    /**
     * The room's last few messages, oldest first, so a newcomer does not stare at an empty screen.
     * Each has `seq` 0. **Returned here only**: they are not replayed on [ImClient.messages] and touch
     * no cursor — render them, and do not commit them.
     *
     * 只在这里返回：不会在 messages 上重放，也不碰游标。
     */
    public val recent: List<ImMessage> = emptyList(),
)

// --------------------------------------------------------------------------- room.* events

/**
 * One `room.*` event, as [ImClient.roomEvents] delivers it.
 *
 * The server sends these inside `evt.system` as `{"event": "room.muted", "body": {…}}`, beside
 * events that have nothing to do with rooms (the device-log request among them); only the `room.*`
 * ones come out here. A `room.*` name this build does not know is still delivered, with whatever
 * [roomId] and [operatorId] it carried and the whole [body] — a newer server must not be able to
 * hide a room event from an older app.
 *
 * - [MUTED] — [userId] null is the whole room; [untilMs] null or already past means the mute was
 *   **lifted**, not set.
 * - [KICKED] — [userId] is who was removed. If it is you, stop sending: the server answers `1602`.
 * - [DESTROYED] — the tenant's backend deleted the room. Every call about it answers `1600` now.
 *
 * evt.system 里同时走着与聊天室无关的事件（设备日志请求就是其一），这里只交出 room.* 的；
 * 不认识的 room.* 名字照样交出，带上原始 body——新服务端不能把聊天室事件藏起来不让旧应用看到。
 */
public data class RoomEvent(
    /** [MUTED], [KICKED], [DESTROYED], or a `room.*` name a newer server added. */
    public val event: String,
    public val roomId: String,
    /** Who did it: the owner, an admin, or the tenant backend's operator id. */
    public val operatorId: String,
    /** [MUTED]: the member muted, null for the whole room. [KICKED]: the member removed. */
    public val userId: String?,
    /** [MUTED]: unix ms the mute ends; null, or a past time, means it was lifted. */
    public val untilMs: Long?,
    /** The event's whole `body`, for a field this build does not name. */
    public val body: JsonObject,
) {
    public companion object {
        public const val MUTED: String = "room.muted"
        public const val KICKED: String = "room.kicked"
        public const val DESTROYED: String = "room.destroyed"

        /** The prefix that makes an `evt.system` event a room's. */
        internal const val PREFIX: String = "room."

        /**
         * The `data` of an `evt.system` frame, as a room event — or null when it is not one. Never
         * throws: a frame of another shape belongs to another reader of `evt.system`.
         */
        internal fun fromSystemData(data: JsonElement?): RoomEvent? {
            val frame = data as? JsonObject ?: return null
            val event = frame.string("event") ?: return null
            if (!event.startsWith(PREFIX)) return null
            val body = frame["body"] as? JsonObject ?: JsonObject(emptyMap())
            return RoomEvent(
                event = event,
                roomId = body.string("roomId").orEmpty(),
                operatorId = body.string("operatorId").orEmpty(),
                userId = body.string("userId"),
                untilMs = (body["untilMs"] as? JsonPrimitive)?.longOrNull,
                body = body,
            )
        }

        private fun JsonObject.string(key: String): String? =
            (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
    }
}
