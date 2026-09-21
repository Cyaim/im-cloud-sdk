using System;
using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>group.*</c> — creating groups, their rosters, getting in and out of them, and running them:
    /// ownership, roles, mutes, nicknames, announcements and join applications.
    /// </summary>
    /// <remarks>
    /// The administrative calls announce what they changed by posting a notification message
    /// (content type 9) into the group conversation, so the other members' clients learn of it
    /// through the ordinary message stream rather than a side channel; each method says which code
    /// it posts, and when it posts nothing. Refusals common to all of them:
    /// <see cref="ImErrorCode.GroupNotFound"/>, <see cref="ImErrorCode.GroupDismissed"/>,
    /// <see cref="ImErrorCode.NotGroupMember"/> and <see cref="ImErrorCode.NoGroupPermission"/>.
    /// </remarks>
    public sealed class ImGroupApi : ImApiNamespace
    {
        internal ImGroupApi(ImClient client)
            : base(client)
        {
        }

        /// <summary>
        /// Creates a group. The caller is always a member and always the owner, whatever
        /// <see cref="ImCreateGroupRequest.MemberIds"/> says.
        /// </summary>
        public Task<ImGroup> CreateAsync(
            ImCreateGroupRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.Name, "name");
            return RequestAsync<ImGroup>("group.create", request, cancellationToken);
        }

        /// <summary>One group's profile.</summary>
        public Task<ImGroup> InfoAsync(
            ImGroupIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            return RequestAsync<ImGroup>("group.info", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="InfoAsync(ImGroupIdRequest,CancellationToken)"/>.</summary>
        public Task<ImGroup> InfoAsync(
            string groupId,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return InfoAsync(new ImGroupIdRequest(groupId), cancellationToken);
        }

        /// <summary>Changes a group's name, avatar, policies or ceiling. Members left null are untouched.</summary>
        public Task UpdateAsync(
            ImUpdateGroupCommand request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            return ExecuteAsync("group.update", request, cancellationToken);
        }

        /// <summary>Dismisses a group. Owner only, and it does not come back.</summary>
        public Task DismissAsync(
            ImGroupIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            return ExecuteAsync("group.dismiss", request, cancellationToken);
        }

        /// <summary>
        /// The member roster, paged. Always paged and never "give me everyone": a super group holds
        /// a hundred thousand members and materialising that into one frame is a self-inflicted
        /// outage.
        /// </summary>
        public Task<ImPage<ImGroupMember>> MemberListAsync(
            ImGroupCursorRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            return RequestPageAsync<ImGroupMember>("group.memberList", request, cancellationToken);
        }

        /// <summary>Groups the caller is in, paged.</summary>
        public Task<ImPage<ImGroup>> JoinedAsync(
            ImCursorRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestPageAsync<ImGroup>(
                "group.joined",
                request != null ? request : new ImCursorRequest(),
                cancellationToken);
        }

        /// <summary>Brings users into a group. Whether the caller may is the group's invite policy.</summary>
        public Task InviteAsync(
            ImGroupMembersRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            return ExecuteAsync("group.invite", request, cancellationToken);
        }

        /// <summary>Removes members. Admin or owner only.</summary>
        public Task KickAsync(
            ImGroupMembersRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            return ExecuteAsync("group.kick", request, cancellationToken);
        }

        /// <summary>Leaves a group. An owner must transfer ownership or dismiss it instead.</summary>
        public Task QuitAsync(
            ImGroupIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            return ExecuteAsync("group.quit", request, cancellationToken);
        }

        /// <summary>
        /// Joins a group. Under <see cref="ImGroupJoinMode.NeedApproval"/> this raises an
        /// application rather than joining, and succeeds either way — watch
        /// <see cref="ImPushTarget.Group"/> for the outcome.
        /// </summary>
        public Task JoinAsync(
            ImJoinGroupRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            return ExecuteAsync("group.join", request, cancellationToken);
        }

        // ------------------------------------------------------------------------- T3

        /// <summary>Hands the group to another member. Owner only, and not repeatable.</summary>
        /// <remarks>
        /// The new owner must already be a member (<see cref="ImErrorCode.NotGroupMember"/>
        /// otherwise), and transferring to yourself is refused with
        /// <see cref="ImErrorCode.InvalidArgument"/>. <b>The outgoing owner becomes a plain member,
        /// not an admin</b> — promote them afterwards with
        /// <see cref="SetRoleAsync(ImSetRoleRequest,CancellationToken)"/>, from the new owner's
        /// session, if that is what the game wants. A retry after success fails with
        /// <see cref="ImErrorCode.NoGroupPermission"/>, because the caller is no longer the owner.
        /// Posts notification <c>1511</c>.
        /// </remarks>
        public Task TransferAsync(
            ImTransferOwnerRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            Require(request.NewOwnerId, "newOwnerId");
            return ExecuteAsync("group.transfer", request, cancellationToken);
        }

        /// <summary>Join applications to groups the caller manages, newest first, paged.</summary>
        /// <remarks>
        /// <para>
        /// With a <see cref="ImGroupCursorRequest.GroupId"/> the caller must be owner or admin of
        /// that group. With none — called with no request at all, or a null group id — it lists
        /// across every group the caller manages, looking only at the first 200 groups they belong
        /// to.
        /// </para>
        /// <para>
        /// <b>Every status comes back</b>, handled applications included; filter on
        /// <see cref="ImGroupApplication.Status"/> for an inbox of
        /// <see cref="ImApplicationStatus.Pending"/> ones. A limit of 1–200 is kept; anything else
        /// becomes 50.
        /// </para>
        /// </remarks>
        public Task<ImPage<ImGroupApplication>> ApplicationListAsync(
            ImGroupCursorRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestPageAsync<ImGroupApplication>(
                "group.applicationList",
                request != null ? request : new ImGroupCursorRequest(),
                cancellationToken);
        }

        /// <summary>Accepts or rejects a join application. Owner or admin only.</summary>
        /// <remarks>
        /// <see cref="ImHandleApplicationRequest.Accept"/> must be set — the server reads its absence
        /// as a rejection — and leaving it null throws here. Refused with
        /// <see cref="ImErrorCode.ApplicationNotFound"/> for an unknown application and
        /// <see cref="ImErrorCode.Conflict"/> for one already handled. A rejection is recorded with
        /// its reason and notifies nobody. An acceptance adds the member and posts notification
        /// <c>1513</c>; if the group is full (<see cref="ImErrorCode.GroupFull"/>) the application
        /// stays pending.
        /// </remarks>
        public Task HandleApplicationAsync(
            ImHandleApplicationRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            Require(request.ApplicantId, "applicantId");
            if (!request.Accept.HasValue)
            {
                throw new ArgumentException(
                    "accept is required: the server reads a missing accept as a rejection, and a handled application cannot be handled again",
                    "accept");
            }

            return ExecuteAsync("group.handleApplication", request, cancellationToken);
        }

        /// <summary>Makes a member an admin, or an admin a member. Owner only.</summary>
        /// <remarks>
        /// Only <see cref="ImGroupRole.Member"/> and <see cref="ImGroupRole.Admin"/> are sent; any
        /// other value throws here (see <see cref="ImSetRoleRequest"/> for why). Ownership moves with
        /// <see cref="TransferAsync(ImTransferOwnerRequest,CancellationToken)"/>. Refused with
        /// <see cref="ImErrorCode.NotGroupMember"/> when the target is not in the group and
        /// <see cref="ImErrorCode.CannotOperateOwner"/> when the target is the owner — the caller
        /// included. Setting the role a member already has succeeds and posts nothing; otherwise
        /// notification <c>1507</c> (made admin) or <c>1508</c> (made member) is posted.
        /// </remarks>
        public Task SetRoleAsync(
            ImSetRoleRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            Require(request.UserId, "userId");
            if (request.Role != ImGroupRole.Member && request.Role != ImGroupRole.Admin)
            {
                throw new ArgumentOutOfRangeException(
                    "role",
                    (int)request.Role,
                    "role must be Member or Admin; ownership moves with group.transfer");
            }

            return ExecuteAsync("group.setRole", request, cancellationToken);
        }

        /// <summary>Mutes or unmutes the whole group. Owner or admin only.</summary>
        /// <remarks>
        /// <para>
        /// The owner and admins can still send; everyone else is refused with
        /// <see cref="ImErrorCode.GroupMuted"/> until it lifts.
        /// <see cref="ImMuteGroupRequest.Mute"/> defaults to true, and <c>Mute = false</c> unmutes
        /// whatever <see cref="ImMuteGroupRequest.UntilMs"/> says.
        /// </para>
        /// <para>
        /// <b>An <see cref="ImMuteGroupRequest.UntilMs"/> in the past mutes indefinitely</b>, not
        /// briefly — compute deadlines from the server's clock. Every call posts notification
        /// <c>1509</c>, even when nothing changed.
        /// </para>
        /// </remarks>
        public Task MuteAsync(
            ImMuteGroupRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            return ExecuteAsync("group.mute", request, cancellationToken);
        }

        /// <summary>Mutes one member until a time, or lifts their mute. Owner or admin only.</summary>
        /// <remarks>
        /// A future <see cref="ImMuteMemberRequest.UntilMs"/> mutes until then; <b>null or a past
        /// time unmutes</b>. There is no indefinite member mute — use a far-future time. The muted
        /// member's sends fail with <see cref="ImErrorCode.MemberMuted"/>. Refused with
        /// <see cref="ImErrorCode.CannotOperateOwner"/> for the owner,
        /// <see cref="ImErrorCode.UnsupportedOperation"/> for yourself, and
        /// <see cref="ImErrorCode.NoGroupPermission"/> for an admin muting another admin. Posts
        /// notification <c>1510</c>.
        /// </remarks>
        public Task MuteMemberAsync(
            ImMuteMemberRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            Require(request.UserId, "userId");
            return ExecuteAsync("group.muteMember", request, cancellationToken);
        }

        /// <summary>Sets a per-group display name — the caller's own, or, with rank, someone else's.</summary>
        /// <remarks>
        /// Any member may set their own (leave <see cref="ImSetGroupNicknameRequest.UserId"/> null).
        /// Setting another member's needs owner or admin and a higher rank than theirs
        /// (<see cref="ImErrorCode.NoGroupPermission"/> or
        /// <see cref="ImErrorCode.CannotOperateOwner"/>). A blank nickname clears it; one over 64
        /// characters is <b>silently truncated</b>. Posts notification <c>1506</c> whose
        /// <c>fields</c> list spells the member <c>"Nickname"</c>, capitalised.
        /// </remarks>
        public Task SetNicknameAsync(
            ImSetGroupNicknameRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            return ExecuteAsync("group.setNickname", request, cancellationToken);
        }

        /// <summary>Replaces the group's announcement, or clears it. Owner or admin only.</summary>
        /// <remarks>
        /// A null or blank announcement clears it; beyond 4096 characters it is <b>silently
        /// truncated</b>. Sets <see cref="ImGroup.AnnouncementUpdatedAt"/>. Every call posts
        /// notification <c>1512</c>, even when the text did not change — so do not call it on every
        /// settings-screen save.
        /// </remarks>
        public Task AnnouncementAsync(
            ImAnnouncementRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.GroupId, "groupId");
            return ExecuteAsync("group.announcement", request, cancellationToken);
        }
    }
}
