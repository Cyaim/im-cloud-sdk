using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>user.*</c> — profiles and presence.
    /// </summary>
    public sealed class ImUserApi : ImApiNamespace
    {
        internal ImUserApi(ImClient client)
            : base(client)
        {
        }

        /// <summary>The signed-in user's own profile.</summary>
        public Task<ImUserProfile> MeAsync(CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestAsync<ImUserProfile>("user.me", null, cancellationToken);
        }

        /// <summary>One other user's profile.</summary>
        public Task<ImUserProfile> ProfileAsync(
            ImUserIdRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.UserId, "userId");
            return RequestAsync<ImUserProfile>("user.profile", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="ProfileAsync(ImUserIdRequest,CancellationToken)"/>.</summary>
        public Task<ImUserProfile> ProfileAsync(
            string userId,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return ProfileAsync(new ImUserIdRequest(userId), cancellationToken);
        }

        /// <summary>
        /// Many profiles in one call. This is what stops a fifty-row conversation list issuing fifty
        /// profile requests, which is how a chat list takes two seconds to paint.
        /// </summary>
        /// <remarks>At most 200 ids; the server refuses more rather than truncating.</remarks>
        public Task<List<ImUserProfile>> BatchProfileAsync(
            ImUserIdsRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            return RequestListAsync<ImUserProfile>("user.batchProfile", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="BatchProfileAsync(ImUserIdsRequest,CancellationToken)"/>.</summary>
        public Task<List<ImUserProfile>> BatchProfileAsync(
            IEnumerable<string> userIds,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return BatchProfileAsync(new ImUserIdsRequest(userIds), cancellationToken);
        }

        /// <summary>
        /// Patches the signed-in user's own profile. A client may only edit itself, and the platform
        /// strips the fields it owns whatever the patch says.
        /// </summary>
        public Task UpdateProfileAsync(
            ImUpdateProfileRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            return ExecuteAsync("user.updateProfile", request, cancellationToken);
        }

        /// <summary>
        /// Whether these users are online right now, and from which platforms.
        /// </summary>
        /// <remarks>
        /// Fails with <see cref="ImErrorCode.FeatureNotEnabled"/> when the tenant has presence off.
        /// Report it and keep calling — a tenant can flip the flag at runtime, and a client that
        /// remembers "presence is off" stays wrong until the app restarts.
        /// </remarks>
        public Task<List<ImPresenceState>> PresenceAsync(
            ImUserIdsRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            return RequestListAsync<ImPresenceState>("user.presence", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="PresenceAsync(ImUserIdsRequest,CancellationToken)"/>.</summary>
        public Task<List<ImPresenceState>> PresenceAsync(
            IEnumerable<string> userIds,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return PresenceAsync(new ImUserIdsRequest(userIds), cancellationToken);
        }

        /// <summary>
        /// Watches users for online/offline transitions, which then arrive on
        /// <see cref="ImPushTarget.Presence"/>.
        /// </summary>
        /// <remarks>
        /// The subscription carries a TTL rather than living until an explicit unsubscribe, because
        /// a client that crashes never sends one. Renew it while the roster is on screen.
        /// One asymmetry worth knowing: this call does <i>not</i> check the tenant's presence flag,
        /// so it succeeds against a presence-disabled app and then never fires. Do not infer the
        /// flag from a successful subscribe — only
        /// <see cref="PresenceAsync(ImUserIdsRequest,CancellationToken)"/> reports it.
        /// </remarks>
        public Task SubscribePresenceAsync(
            ImSubscribePresenceRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            return ExecuteAsync("user.subscribePresence", request, cancellationToken);
        }

        /// <summary>Stops watching these users.</summary>
        public Task UnsubscribePresenceAsync(
            ImUserIdsRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            return ExecuteAsync("user.unsubscribePresence", request, cancellationToken);
        }

        /// <summary>
        /// Sets the signed-in user's free-text status — "in a raid", "back at 9" — or clears it.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Called with no request, or with a null or blank <see cref="ImSetStatusRequest.Status"/>,
        /// it clears the status. Longer than 64 characters after trimming is refused with
        /// <see cref="ImErrorCode.InvalidArgument"/>. Fails with
        /// <see cref="ImErrorCode.ServiceUnavailable"/> when the presence store is down.
        /// </para>
        /// <para>
        /// <b>It expires.</b> The server keeps a status for seven days and then drops it silently,
        /// so set it again at login if it is meant to persist. Subscribers see it as
        /// <see cref="ImPresenceState.CustomStatus"/> on <see cref="ImPushTarget.Presence"/>. Like
        /// <see cref="SubscribePresenceAsync(ImSubscribePresenceRequest,CancellationToken)"/>, this
        /// call does not check the tenant's presence switch — but reading the status back through
        /// <see cref="PresenceAsync(ImUserIdsRequest,CancellationToken)"/> does.
        /// </para>
        /// </remarks>
        public Task SetStatusAsync(
            ImSetStatusRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return ExecuteAsync(
                "user.setStatus",
                request != null ? request : new ImSetStatusRequest(),
                cancellationToken);
        }
    }
}
