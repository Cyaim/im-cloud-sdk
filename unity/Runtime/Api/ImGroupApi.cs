using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>group.*</c> — creating groups, their rosters, and getting in and out of them.
    /// </summary>
    /// <remarks>
    /// Administration beyond this — transfer, roles, mutes, announcements, applications — is the
    /// next tier and is reachable today through
    /// <see cref="ImClient.InvokeAsync(string,Cyaim.Im.Json.JsonValue,CancellationToken)"/>.
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
    }
}
