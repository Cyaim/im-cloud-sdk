package com.cyaim.im.client

/**
 * `room.*` — chat rooms: the live-stream comment wall, the broadcast lobby (T4).
 *
 * **A room trades every delivery guarantee for scale, and the client has to know it.** Its messages
 * are not stored per user, not pushed offline and carry `seq` **0**: they arrive on
 * [ImClient.messages] as ordinary [ImMessage]s with `conversationId` `r_<roomId>`, and [ImClient]
 * keeps them out of cursors and gap repair entirely — a dropped frame is gone, and there is no range
 * to ask for. Do not commit them; [ImClient.commit] ignores a seq of 0 for that reason.
 *
 * **Rooms are created by the tenant's backend** (`POST /v1/rooms`), never from a device. **Joining
 * belongs to the connection**: after a reconnect, send [join] again for every room still on screen —
 * the SDK does not do it for you. Mutes, kicks and the room's destruction arrive on
 * [ImClient.roomEvents].
 *
 * **A deployment older than this build answers `1008 UnsupportedOperation`**; neither retrying nor
 * re-authenticating changes it.
 *
 * 聊天室用全部投递保证换规模：消息不按人存储、不发离线推送、seq 为 0，ImClient 让它们完全绕开游标与补洞。
 * 聊天室由租户后端创建；入房属于连接，重连后要重新 join，SDK 不代劳。
 */
public class RoomApi internal constructor(
    private val connection: ImConnection,
    private val newClientMsgId: () -> String,
) {

    /**
     * Enters a room on this connection and returns it, the head count, and its last few messages.
     *
     * `1600 RoomNotFound` for a room that does not exist or was destroyed; `1601 RoomFull` when
     * [ChatRoom.maxOnline] connections are already in.
     */
    public suspend fun join(request: RoomIdRequest): RoomJoinResult =
        connection.request("room.join", request.asBody())

    /** Leaves a room on this connection. Leaving one you are not in succeeds. */
    public suspend fun quit(request: RoomIdRequest) {
        connection.execute("room.quit", request.asBody())
    }

    /**
     * Says something to the room. The result's `seq` is **always 0** and its `conversationId` is
     * `r_<roomId>`; it moves no cursor, which is why this does not go through `msg.send`.
     *
     * A blank [RoomMessage.clientMsgId] is filled in and a zero [RoomMessage.sendTime] stamped, as
     * `msg.send` does. Refusals: `1602 NotInRoom` (not joined, or kicked), `1603 RoomMuted` (the whole
     * room is muted and you are neither owner nor admin), `1506 MemberMuted`, `1401 MessageTooLong`,
     * `1402 ModerationRejected`, `1003 RateLimited` (the room is over its rate).
     *
     * 结果的 seq 恒为 0，不动游标，所以不走 msg.send。
     */
    public suspend fun send(request: RoomSendRequest): SendMessageResult {
        val message = request.message
        val keyed = if (message.clientMsgId.isNotBlank()) message else message.copy(clientMsgId = newClientMsgId())
        val stamped = if (keyed.sendTime > 0) keyed else keyed.copy(sendTime = System.currentTimeMillis())
        return connection.request("room.send", request.copy(message = stamped).asBody())
    }

    /**
     * Connections in the room right now, cluster-wide. A bare number. **An unknown room answers 0**,
     * not `1600`: this is polled for a viewer counter and the server skips the existence check.
     */
    public suspend fun onlineCount(request: RoomIdRequest): Long =
        connection.request("room.onlineCount", request.asBody())

    /**
     * **A sample** of the user ids present, not the full list: the server never enumerates a large
     * room exactly. Page on [Page.hasMore] / [Page.nextCursor]; a page can be short, or empty, with
     * more to come. An unknown room is an empty sample, not `1600`.
     */
    public suspend fun memberList(request: RoomCursorRequest): Page<String> =
        connection.request("room.memberList", request.asBody())

    /**
     * Mutes the room or one member until a time — or, with [RoomMuteRequest.untilMs] null or past,
     * lifts the mute. Owner or admins only (`1103`); never the owner (`1511`).
     */
    public suspend fun mute(request: RoomMuteRequest) {
        connection.execute("room.mute", request.asBody())
    }

    /** Removes a member from the room. Owner or admins only (`1103`); never the owner (`1511`). */
    public suspend fun kick(request: RoomKickRequest) {
        connection.execute("room.kick", request.asBody())
    }
}
