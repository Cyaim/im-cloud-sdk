using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>conn.*</c> — the session floor. Transport lifecycle, not product features: a client
    /// missing one of these is broken rather than incomplete.
    /// </summary>
    /// <remarks>
    /// The SDK drives all three itself. They are public because a tenant with its own resume logic,
    /// its own token lifecycle, or a diagnostic screen needs to reach them, not because a normal
    /// integration has to call them.
    /// </remarks>
    public sealed class ImConnApi : ImApiNamespace
    {
        internal ImConnApi(ImClient client)
            : base(client)
        {
        }

        /// <summary>
        /// Sends one heartbeat and returns what the server says about this session.
        /// </summary>
        /// <remarks>
        /// <see cref="ImConnection"/> already beats on the cadence the reply reports, so calling
        /// this by hand is for diagnostics — <see cref="ImHeartbeatResult.ConnectionId"/> and
        /// <see cref="ImHeartbeatResult.NodeId"/> are what a support ticket should carry, and
        /// <see cref="ImHeartbeatResult.Healed"/> says this beat rebuilt a routing entry that had
        /// gone missing.
        /// </remarks>
        public Task<ImHeartbeatResult> HeartbeatAsync(CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestAsync<ImHeartbeatResult>("conn.heartbeat", null, cancellationToken);
        }

        /// <summary>
        /// Swaps in a fresh token on the socket that is already open.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Without this, a token expiring mid-session costs a full reconnect — and on the flaky
        /// network where tokens tend to expire, a reconnect is exactly what you were trying to
        /// avoid. The new token must belong to the same user; one for anyone else is refused with
        /// <see cref="ImErrorCode.Forbidden"/> rather than quietly changing who this socket is.
        /// </para>
        /// <para>
        /// The SDK calls this for you when a request comes back
        /// <see cref="ImErrorCode.TokenExpired"/> and an
        /// <see cref="ImConnectionOptions.TokenProvider"/> is set; see
        /// <see cref="ImConnection.ReauthAsync"/>, which also updates the token the next handshake
        /// will use.
        /// </para>
        /// </remarks>
        public Task ReauthAsync(
            ImReauthRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.Token, "token");
            return ExecuteAsync("conn.reauth", request, cancellationToken);
        }

        /// <summary>Shorthand for <see cref="ReauthAsync(ImReauthRequest,CancellationToken)"/>.</summary>
        public Task ReauthAsync(string token, CancellationToken cancellationToken = default(CancellationToken))
        {
            return ReauthAsync(new ImReauthRequest(token), cancellationToken);
        }

        /// <summary>
        /// Asks what changed while this device was away: which conversations moved, and where each
        /// gap starts.
        /// </summary>
        /// <remarks>
        /// <para>
        /// <b>This call moves no cursor.</b> <see cref="ImClient"/> runs its own paged resume on
        /// every connect — reporting <c>committedSeq</c>, adopting first sight, repairing gaps,
        /// advancing <c>conversationCursor</c> only when a run completes — and that is the path that
        /// owns the cursor state. Calling this yourself returns the raw page and changes nothing,
        /// which is what makes it safe to use from a diagnostic screen.
        /// </para>
        /// <para>
        /// If you do drive it yourself: page on <see cref="ImResumeResult.HasMore"/> and
        /// <see cref="ImResumeResult.NextCursor"/>, never on the item count, and do not advance your
        /// stored <c>conversationCursor</c> until a page comes back with <c>hasMore</c> false. The
        /// list is sorted by <c>updatedAt</c> descending, so taking the maximum from page one and
        /// stopping pushes the cursor past every conversation on the pages you never read, and the
        /// server will not return them again.
        /// </para>
        /// </remarks>
        public Task<ImResumeResult> SyncAsync(
            ImResumeRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestAsync<ImResumeResult>("conn.sync", request, cancellationToken);
        }
    }
}
