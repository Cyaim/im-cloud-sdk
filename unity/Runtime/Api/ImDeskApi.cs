using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Cyaim.Im
{
    /// <summary>
    /// <c>desk.*</c> — the customer-service desk, from both sides of it (T4).
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Two audiences, one namespace, and which one you are is decided by the session rather than
    /// by the method you call.</b> <see cref="RequestAsync(ImDeskRequest, CancellationToken)"/> and <see cref="RateAsync"/> are the
    /// player's — an in-game "contact support" screen; <see cref="AcceptAsync"/>,
    /// <see cref="TransferAsync"/>, <see cref="StatusAsync"/>, <see cref="QueueAsync"/>,
    /// <see cref="CannedAsync"/> and <see cref="SuggestAsync"/> are an agent's;
    /// <see cref="CloseAsync"/> is either side's. The server checks the caller against the session's
    /// holder every time, so an agent-shaped call from a player is <c>1103</c>.
    /// </para>
    /// <para>
    /// <b>The conversation is not here.</b> Everything a player and an agent say to each other is an
    /// ordinary single chat with the desk account, sent with <c>msg.send</c> and read with
    /// <c>msg.history</c>. These nine verbs only move the <i>assignment</i> around it.
    /// </para>
    /// <para>
    /// A deployment older than this build answers <c>1008 UnsupportedOperation</c>; neither retrying
    /// nor re-authenticating changes it.
    /// 两种角色共用一个命名空间，「你是谁」由会话判定。聊天不在这里：这九个动词只负责「谁来接」。
    /// </para>
    /// </remarks>
    public sealed class ImDeskApi : ImApiNamespace
    {
        internal ImDeskApi(ImClient client)
            : base(client)
        {
        }

        /// <summary>
        /// Asks for a person, and returns the session — a new one, or the caller's own open one.
        /// Null asks with nothing filled in, which is the plain "talk to a human" button.
        /// </summary>
        /// <remarks>
        /// Idempotent server-side, so the button needs no guard. <see cref="ImDeskSession.State"/>
        /// says what happened: <see cref="ImDeskSessionState.Queued"/> means waiting,
        /// <see cref="ImDeskSessionState.Assigned"/> means an idle agent took it in the same call.
        /// </remarks>
        public Task<ImDeskSession> RequestAsync(
            ImDeskRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return base.RequestAsync<ImDeskSession>("desk.request", request ?? new ImDeskRequest(), cancellationToken);
        }

        /// <summary>Takes a session: the named one, or the next one waiting when no id is given.</summary>
        /// <remarks>
        /// An empty queue is <c>1002</c>, which a workbench polling for work should read as "nothing
        /// waiting"; being at capacity is <c>1205</c>, which is not retryable — finish a session first.
        /// 队列为空答 1002；已满答 1205，解法是先结掉一个，不是重试。
        /// </remarks>
        public Task<ImDeskSession> AcceptAsync(
            ImDeskAcceptRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return base.RequestAsync<ImDeskSession>("desk.accept", request ?? new ImDeskAcceptRequest(), cancellationToken);
        }

        /// <summary>
        /// Hands a session on — to a named agent, a skill queue, or back to its own queue. Build the
        /// request with <see cref="ImDeskTransferRequest.Agent"/>, <see cref="ImDeskTransferRequest.Skill"/>
        /// or <see cref="ImDeskTransferRequest.Queue"/>.
        /// </summary>
        public Task TransferAsync(
            ImDeskTransferRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.SessionId, "sessionId");
            return ExecuteAsync("desk.transfer", request, cancellationToken);
        }

        /// <summary>
        /// Ends a session; either side may. Closing an already-closed session succeeds, which is what
        /// makes a retry after a timeout safe. Leaving <see cref="ImDeskCloseRequest.InviteRating"/>
        /// null still invites.
        /// </summary>
        public Task CloseAsync(
            ImDeskCloseRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.SessionId, "sessionId");
            return ExecuteAsync("desk.close", request, cancellationToken);
        }

        /// <summary>
        /// Sets this agent's availability and renews their heartbeat. Call it on a timer, not only
        /// when the agent changes status: the roster drops an agent whose console stopped talking.
        /// </summary>
        public Task StatusAsync(
            ImDeskStatusRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            return ExecuteAsync("desk.status", request, cancellationToken);
        }

        /// <summary>
        /// The queue as a supervisor watches it. Takes no arguments — it is the whole desk.
        /// <see cref="ImDeskQueueView.AvgFirstResponseSeconds"/> is null when nothing is measurable.
        /// </summary>
        public Task<ImDeskQueueView> QueueAsync(CancellationToken cancellationToken = default(CancellationToken))
        {
            return base.RequestAsync<ImDeskQueueView>("desk.queue", null, cancellationToken);
        }

        /// <summary>
        /// The player rates a finished session, 1–5, in reply to the 1807 notice. Accepted once, only
        /// inside the rating window (<c>1006</c> otherwise); <c>1203</c> when ratings are switched off.
        /// </summary>
        public Task RateAsync(
            ImDeskRateRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.SessionId, "sessionId");
            return ExecuteAsync("desk.rate", request, cancellationToken);
        }

        /// <summary>The canned replies in this centre's phrasebook. Read-only here.</summary>
        /// <remarks>
        /// Pass your own member id as <see cref="ImDeskCannedRequest.OwnerMemberId"/> for "shared,
        /// plus mine": leaving it null lists every member's personal entries, because the server
        /// does not narrow by caller on this route.
        /// </remarks>
        public Task<List<ImDeskCannedReply>> CannedAsync(
            ImDeskCannedRequest request = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return RequestListAsync<ImDeskCannedReply>("desk.canned", request ?? new ImDeskCannedRequest(), cancellationToken);
        }

        /// <summary>
        /// Up to three model-written drafts for the session this agent holds. Nothing here reaches
        /// the player. <c>1203</c> when the tenant has configured no LLM; <c>1005</c> when the model
        /// did not answer.
        /// </summary>
        public async Task<List<string>> SuggestAsync(
            ImDeskSuggestRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            RequireRequest(request);
            Require(request.SessionId, "sessionId");
            var data = await base.RequestAsync("desk.suggest", request, cancellationToken).ConfigureAwait(false);
            return data.AsStringList();
        }
    }
}
