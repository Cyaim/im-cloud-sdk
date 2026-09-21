package com.cyaim.im.client

import kotlinx.serialization.json.JsonObject

/** `user.*` — profiles and presence. */
public class UserApi internal constructor(private val connection: ImConnection) {

    /** The caller's own profile. */
    public suspend fun me(): UserProfile = connection.request("user.me")

    public suspend fun profile(request: UserIdRequest): UserProfile =
        connection.request("user.profile", request.asBody())

    /** [profile] for the one-field case. */
    public suspend fun profile(userId: String): UserProfile = profile(UserIdRequest(userId))

    /**
     * Resolves up to 200 profiles in one call.
     *
     * This is what stops a fifty-row conversation list from issuing fifty profile requests, which
     * is the difference between a list that paints immediately and one that paints over two
     * seconds. Batch first, then cache.
     */
    public suspend fun batchProfile(request: UserIdsRequest): List<UserProfile> =
        connection.request("user.batchProfile", request.asBody())

    /** [batchProfile] for the common call shape. */
    public suspend fun batchProfile(userIds: List<String>): List<UserProfile> =
        batchProfile(UserIdsRequest(userIds))

    /**
     * Patches the caller's **own** profile. A client can never edit another user, whatever it puts
     * in the patch, and the server strips the fields the platform owns (`banned`, `silencedUntil`,
     * `multiLoginOverride`, …) before applying it.
     */
    public suspend fun updateProfile(request: UpdateProfileRequest) {
        connection.execute("user.updateProfile", request.asBody())
    }

    /** [updateProfile] for a raw JSON patch. */
    public suspend fun updateProfile(patch: JsonObject): Unit = updateProfile(UpdateProfileRequest(patch))

    /**
     * Current presence for a set of users.
     *
     * Answers `1203 FeatureNotEnabled` when the tenant has presence switched off. Do not remember
     * that: the flag is a runtime setting and a client that latches it stays dark after the tenant
     * turns presence back on.
     */
    public suspend fun presence(request: UserIdsRequest): List<PresenceState> =
        connection.request("user.presence", request.asBody())

    /** [presence] for the common call shape. */
    public suspend fun presence(userIds: List<String>): List<PresenceState> = presence(UserIdsRequest(userIds))

    /**
     * Watches a set of users for online/offline transitions, delivered on `evt.presence`.
     *
     * The subscription has a TTL and expires; re-subscribe while the screen that needs it is open.
     * Unlike [presence] this call does **not** check the tenant's presence flag, so it succeeds on
     * a presence-disabled app and then never fires. Do not infer the flag from it succeeding.
     */
    public suspend fun subscribePresence(request: SubscribePresenceRequest) {
        connection.execute("user.subscribePresence", request.asBody())
    }

    public suspend fun unsubscribePresence(request: UserIdsRequest) {
        connection.execute("user.unsubscribePresence", request.asBody())
    }

    /** [unsubscribePresence] for the common call shape. */
    public suspend fun unsubscribePresence(userIds: List<String>): Unit =
        unsubscribePresence(UserIdsRequest(userIds))

    /**
     * Sets the caller's custom status line; `SetStatusRequest()` clears it.
     *
     * **It expires.** The server keeps it for seven days and then drops it without telling anyone,
     * so set it again on login if it should persist. Subscribers see it as
     * [PresenceState.customStatus] on `evt.presence`. `1005` when the presence store is down.
     *
     * One asymmetry, the same shape as [subscribePresence]'s: this call does **not** check the
     * tenant's presence flag, while reading the status back through [presence] does. A status set
     * on a presence-disabled app succeeds and is then unreadable.
     *
     * 七天后自动消失（不通知），要常驻就在每次登录时重设。写入不检查 EnablePresence，读取检查。
     */
    public suspend fun setStatus(request: SetStatusRequest) {
        connection.execute("user.setStatus", request.asBody())
    }
}

/**
 * `friend.*` — the contact list, its pending requests, and the blocklist.
 *
 * [block] is not a nice-to-have. App-store review treats user blocking as mandatory for any app
 * carrying user-generated content, and an SDK that omits it turns a review rejection into a
 * release cycle.
 */
public class FriendApi internal constructor(private val connection: ImConnection) {

    public suspend fun list(request: CursorRequest = CursorRequest()): Page<Friend> =
        connection.request("friend.list", request.asBody())

    /**
     * Sends a friend request. Not a friendship: it is one until the other side handles it, and the
     * tenant may have configured auto-accept, in which case it is one immediately.
     */
    public suspend fun add(request: AddFriendRequest) {
        connection.execute("friend.add", request.asBody())
    }

    /** Accepts or rejects an incoming request. */
    public suspend fun handleRequest(request: HandleFriendRequest) {
        connection.execute("friend.handleRequest", request.asBody())
    }

    /** Incoming (default) or outgoing pending requests. */
    public suspend fun requestList(request: FriendRequestListRequest = FriendRequestListRequest()): Page<FriendRequest> =
        connection.request("friend.requestList", request.asBody())

    public suspend fun delete(request: UserIdRequest) {
        connection.execute("friend.delete", request.asBody())
    }

    /** [delete] for the one-field case. */
    public suspend fun delete(userId: String): Unit = delete(UserIdRequest(userId))

    /**
     * Blocks a user: their messages stop arriving and yours stop reaching them (`1303`/`1304`).
     * Blocking is not deleting — the friendship, if any, survives it.
     */
    public suspend fun block(request: BlockRequest) {
        connection.execute("friend.block", request.asBody())
    }

    /** [block] for the one-field case. */
    public suspend fun block(userId: String): Unit = block(BlockRequest(userId))

    public suspend fun unblock(request: UserIdRequest) {
        connection.execute("friend.unblock", request.asBody())
    }

    /** [unblock] for the one-field case. */
    public suspend fun unblock(userId: String): Unit = unblock(UserIdRequest(userId))

    public suspend fun blockList(request: CursorRequest = CursorRequest()): Page<BlockEntry> =
        connection.request("friend.blockList", request.asBody())

    /**
     * Sets the remark (the caller's private name for a contact) and optionally the tags.
     *
     * Read [SetRemarkRequest] before calling: **a null remark clears the remark**, while null tags
     * leave the tags alone. `1001` for a missing `userId` or a value past its limit; `1302` when the
     * user is not a contact. The change reaches the caller's own devices as `evt.friend` with
     * action `"updated"`; the contact is not told.
     */
    public suspend fun setRemark(request: SetRemarkRequest) {
        connection.execute("friend.setRemark", request.asBody())
    }
}
