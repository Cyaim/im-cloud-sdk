package com.cyaim.im.client

/**
 * `group.*` — the ten calls a group chat needs, and the eight that administer one (transfer, roles,
 * mutes, nicknames, the announcement and join applications).
 *
 * Most administrative calls announce themselves in the group as a notification message
 * (`contentType` 9), so the other members' clients learn of them through the ordinary message
 * stream rather than a separate event. Where a method below says "notification N", N is that
 * message's `content.code`. **Those codes share their numbers with unrelated error codes** — 1511 is
 * `OwnerTransferred` in a notification and `CannotOperateOwner` in an error, 1512 is
 * `AnnouncementChanged` and `ApplicationNotFound` — so never read one where you expect the other.
 *
 * 通知消息的 content.code 与错误码数值重叠（1511、1512 在两边含义不同），不要混读。
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

    // ---------------------------------------------------------------- T3: administration

    /**
     * Hands the group to another member. **Owner only** (`1504`).
     *
     * Not repeatable: a retry after it succeeded is `1504`, because the caller is no longer the
     * owner. The outgoing owner becomes a plain member, **not** an admin — follow with [setRole]
     * from the new owner's side if that is what you want. Transferring to yourself is `1001`; to a
     * non-member, `1503`. Announced with notification 1511 (`OwnerTransferred`).
     */
    public suspend fun transfer(request: TransferOwnerRequest) {
        connection.execute("group.transfer", request.asBody())
    }

    /** [transfer] for the two-field case. */
    public suspend fun transfer(groupId: String, newOwnerId: String): Unit =
        transfer(TransferOwnerRequest(groupId, newOwnerId))

    /**
     * Join requests, newest first.
     *
     * With no group — the default, an empty [GroupCursorRequest.groupId] — it lists across every
     * group the caller manages, looking only at the first 200 groups they have joined. With a
     * group, the caller must be its owner or an admin (`1504`).
     *
     * **It returns every status, not only pending**: filter on [GroupApplication.status] for a
     * "waiting for you" list.
     *
     * 返回所有状态而不只是待处理的；「等你处理」要自己筛 Pending。
     */
    public suspend fun applicationList(
        request: GroupCursorRequest = GroupCursorRequest(groupId = ""),
    ): Page<GroupApplication> = connection.request("group.applicationList", request.asBody())

    /**
     * Accepts or rejects one join request. Owner or admin (`1504`).
     *
     * `1512` when there is no such request, `1006` when it was already handled. A rejection is
     * stored with its reason and **tells nobody**. An acceptance adds the member and announces
     * notification 1513 (`ApplicationAccepted`) — unless the group is full (`1502`), in which case
     * the request stays pending.
     */
    public suspend fun handleApplication(request: HandleApplicationRequest) {
        connection.execute("group.handleApplication", request.asBody())
    }

    /**
     * Promotes a member to admin or demotes an admin to member. **Owner only** (`1504`).
     *
     * Only [GroupRole.Member] and [GroupRole.Admin] are sent; anything else throws
     * [IllegalArgumentException] here, before a frame is written — see [SetRoleRequest] for why
     * the server cannot be trusted to refuse them itself. Ownership moves with [transfer].
     *
     * A non-member target is `1503`; the owner as target — including the owner calling on
     * themselves — is `1511`. Setting the role a member already has succeeds and announces nothing;
     * otherwise notification 1507 (`AdminSet`) or 1508 (`AdminRevoked`) goes out.
     */
    public suspend fun setRole(request: SetRoleRequest) {
        require(request.role == GroupRole.Member || request.role == GroupRole.Admin) {
            if (request.role == GroupRole.Owner) {
                "group.setRole cannot make an owner; ownership moves with group.transfer"
            } else {
                "group.setRole takes GroupRole.Member or GroupRole.Admin, not ${request.role}"
            }
        }
        connection.execute("group.setRole", request.asBody())
    }

    /**
     * Mutes or unmutes the whole group. Owner or admin (`1504`); the owner and admins can still send
     * while it is on, and everyone else gets `1505`.
     *
     * **Read [MuteGroupRequest] first:** `mute` defaults to true, and **a past `untilMs` mutes
     * indefinitely**, not "until a moment already gone". Every call writes and announces
     * notification 1509 (`MuteAllChanged`), even when nothing changed.
     *
     * 过去的 untilMs 是「无限期」而不是「解除」；每次调用都会写入并发 1509 通知，哪怕没有变化。
     */
    public suspend fun mute(request: MuteGroupRequest) {
        connection.execute("group.mute", request.asBody())
    }

    /**
     * Mutes one member until a time, or unmutes them. Owner or admin (`1504`).
     *
     * **A null or past `untilMs` unmutes** — the opposite reading from [mute], and there is no
     * indefinite member mute. A non-member target is `1503`, the owner `1511`, yourself `1008`, and
     * an admin muting another admin `1504`. The muted member's sends then fail with `1506`.
     * Announced with notification 1510 (`MemberMuteChanged`).
     */
    public suspend fun muteMember(request: MuteMemberRequest) {
        connection.execute("group.muteMember", request.asBody())
    }

    /**
     * Sets a member's in-group nickname — your own with no `userId`, which any member may do.
     * Someone else's needs owner or admin **and** outranking them (`1504` / `1511`); a non-member
     * target is `1503`. Past 64 characters it is silently truncated. Announced with notification
     * 1506 (`InfoChanged`), whose `fields` spells the field `"Nickname"`, capitalised.
     */
    public suspend fun setNickname(request: SetGroupNicknameRequest) {
        connection.execute("group.setNickname", request.asBody())
    }

    /**
     * Replaces the group announcement; null or blank clears it. Owner or admin (`1504`).
     *
     * Past 4096 characters it is silently truncated. Sets [Group.announcementUpdatedAt], and every
     * call announces notification 1512 (`AnnouncementChanged`) — even when the text did not change.
     */
    public suspend fun announcement(request: AnnouncementRequest) {
        connection.execute("group.announcement", request.asBody())
    }
}
