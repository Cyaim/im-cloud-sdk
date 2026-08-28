package com.cyaim.im.client

/**
 * `group.*` — the ten calls a group chat needs.
 *
 * Administration (transfer, roles, mutes, announcements, join applications) is tier T3 and is not
 * typed yet; reach it through [ImClient.invoke] until it is.
 */
public class GroupApi internal constructor(private val connection: ImConnection) {

    /**
     * Creates a group. The caller is always a member and always the owner, whatever
     * [CreateGroupRequest.memberIds] says.
     */
    public suspend fun create(request: CreateGroupRequest): Group =
        connection.request("group.create", request.asBody())

    public suspend fun info(request: GroupIdRequest): Group = connection.request("group.info", request.asBody())

    /** [info] for the one-field case. */
    public suspend fun info(groupId: String): Group = info(GroupIdRequest(groupId))

    /** Name, avatar, introduction, join and invite modes. Null fields are left alone. */
    public suspend fun update(request: UpdateGroupCommand) {
        connection.execute("group.update", request.asBody())
    }

    /** Owner only. Irreversible: the conversation stays, marked dismissed, and nobody can post. */
    public suspend fun dismiss(request: GroupIdRequest) {
        connection.execute("group.dismiss", request.asBody())
    }

    /** [dismiss] for the one-field case. */
    public suspend fun dismiss(groupId: String): Unit = dismiss(GroupIdRequest(groupId))

    /**
     * Pages the member list. Always paged, never "give me everyone": a super group holds a hundred
     * thousand members and materialising that into one frame is a self-inflicted outage.
     */
    public suspend fun memberList(request: GroupCursorRequest): Page<GroupMember> =
        connection.request("group.memberList", request.asBody())

    /** The groups the caller is in. */
    public suspend fun joined(request: CursorRequest = CursorRequest()): Page<Group> =
        connection.request("group.joined", request.asBody())

    public suspend fun invite(request: GroupMembersRequest) {
        connection.execute("group.invite", request.asBody())
    }

    public suspend fun kick(request: GroupMembersRequest) {
        connection.execute("group.kick", request.asBody())
    }

    /** Leaves the group. The owner must transfer ownership or dismiss it instead. */
    public suspend fun quit(request: GroupIdRequest) {
        connection.execute("group.quit", request.asBody())
    }

    /** [quit] for the one-field case. */
    public suspend fun quit(groupId: String): Unit = quit(GroupIdRequest(groupId))

    /**
     * Joins a group.
     *
     * Not joining is a normal outcome: a group whose `joinMode` is `NeedApproval` answers
     * `1508 JoinNeedsApproval`, which means the application is on file and an admin has to handle
     * it. Treat that code as "pending", not as a failure to retry.
     */
    public suspend fun join(request: JoinGroupRequest) {
        connection.execute("group.join", request.asBody())
    }
}
