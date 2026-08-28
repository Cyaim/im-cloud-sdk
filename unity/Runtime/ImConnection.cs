using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im.Json;
using Cyaim.Im.Threading;
using Cyaim.Im.Transport;

namespace Cyaim.Im
{
    /// <summary>
    /// Lifecycle of the connection as a whole — not of one socket. A connection lives across as
    /// many sockets as it takes.
    /// </summary>
    public enum ImConnectionState
    {
        /// <summary>Constructed, never connected.</summary>
        Idle = 0,

        /// <summary>First socket in flight.</summary>
        Connecting = 1,

        /// <summary>Open and usable.</summary>
        Open = 2,

        /// <summary>The socket dropped and a replacement is being opened, after a jittered delay.</summary>
        Reconnecting = 3,

        /// <summary>Stopped for good: the app closed it, or the server kicked us terminally.</summary>
        Closed = 4,
    }

    /// <summary>
    /// One multiplexed WebSocket to the gateway, with the reconnect behaviour a shipped game
    /// actually needs.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Requests and responses are correlated by <c>id</c>, so any number of calls can be in flight
    /// on the single socket and each one gets its own reply and its own deadline. Server-initiated
    /// pushes arrive in the same envelope and are routed to <see cref="On"/> subscribers.
    /// </para>
    /// <para>
    /// Reconnecting is not an optional extra. A gateway holds sockets and therefore deploys rarely,
    /// but when it does deploy — or when a node fails, or a phone leaves wifi — every client on that
    /// node reconnects at once. Without full jitter those clients arrive as a synchronised
    /// thundering herd against the very service that just came back up. See
    /// <see cref="FullJitterBackoff"/>, which is the default and is the part of this class most
    /// worth reading before changing.
    /// </para>
    /// <para>
    /// <b>Threading.</b> Every field below is touched on the dispatcher thread and nowhere else. The
    /// public methods are callable from any thread: each one posts its work to the dispatcher rather
    /// than taking a lock, so there is a single serialised timeline of state changes, and every
    /// callback the SDK raises lands on the Unity main thread. Socket I/O is the only thing that
    /// happens off it. A <see cref="Task"/> returned from here completes on the dispatcher thread
    /// too, which is why <c>await</c>ing one inside the SDK resumes somewhere safe to touch state —
    /// and why blocking on one with <c>.Result</c> from the main thread deadlocks the pump that
    /// would have completed it.
    /// </para>
    /// <para>
    /// 重连不是可选项：网关一次滚动更新会让该节点上所有客户端同时重连。没有全抖动退避，
    /// 这些客户端会变成打向刚恢复的服务的同步洪峰。
    /// </para>
    /// </remarks>
    public sealed class ImConnection : IDisposable
    {
        /// <summary>
        /// Heartbeat cadence used until the server reports its own (SPEC-02 §2.1: 30 s, with the
        /// gateway declaring a session offline after 90 s of silence).
        /// </summary>
        public const int DefaultHeartbeatSeconds = 30;

        /// <summary>Conversations asked for per <c>conn.sync</c> page.</summary>
        internal const int ResumePageSize = 200;

        private const int NormalCloseCode = 1000;

        /// <summary>Transport status the gateway sends when no endpoint matched the target.</summary>
        private const int UnknownTargetStatus = 2;

        private readonly ImConnectionOptions _options;
        private readonly IImDispatcher _dispatcher;
        private readonly IReconnectBackoff _backoff;
        private readonly Func<IImTransport> _transportFactory;
        private readonly ImPlatform _platform;

        private readonly object _listenerGate = new object();

        // Case-insensitive because SPEC-02 §2 matches endpoint names case-insensitively, and a
        // gateway that starts echoing "Evt.Message" must not silently unsubscribe every client.
        private readonly Dictionary<string, List<Action<ImFrame>>> _listeners =
            new Dictionary<string, List<Action<ImFrame>>>(StringComparer.OrdinalIgnoreCase);

        private readonly Dictionary<string, PendingRequest> _pending =
            new Dictionary<string, PendingRequest>(StringComparer.Ordinal);

        private readonly List<TaskCompletionSource<bool>> _connectWaiters =
            new List<TaskCompletionSource<bool>>();

        /// <summary>
        /// Callers parked on an in-flight token renewal, so a burst of 1101s produces one
        /// <c>conn.reauth</c> and not ten.
        /// </summary>
        /// <remarks>
        /// A list of completion sources rather than one shared <see cref="Task"/> that everyone
        /// awaits, and the difference is not stylistic. When several <c>await</c>s attach to one
        /// task, the TPL inlines at most one of their continuations and schedules the rest onto the
        /// thread pool — so every caller after the first would resume off the dispatcher thread,
        /// which is the one thing this class exists to prevent. Completing a source per waiter, on
        /// the dispatcher, keeps all of them on the single serialised timeline. It is the same
        /// pattern <see cref="_connectWaiters"/> uses, for the same reason.
        /// </remarks>
        private readonly List<TaskCompletionSource<bool>> _renewWaiters =
            new List<TaskCompletionSource<bool>>();

        private bool _renewing;

        private IImTransport _transport;
        private CancellationTokenSource _lifetime;
        private IDisposable _reconnectTimer;
        private IDisposable _heartbeatTimer;
        private IDisposable _connectDeadline;

        private int _stateCode;
        private int _session;
        private bool _sessionEnded = true;
        private bool _stopped = true;
        private bool _disposed;
        private bool _kickReported;
        private int _attempt;
        private int _heartbeatSeconds = DefaultHeartbeatSeconds;
        private long _requestCounter;
        private string _token;

        /// <summary>Creates a connection. Nothing happens until <see cref="ConnectAsync"/>.</summary>
        /// <param name="options">Endpoint, credentials and policies. Validated here, not later.</param>
        public ImConnection(ImConnectionOptions options)
        {
            if (options == null)
            {
                throw new ArgumentNullException("options");
            }

            options.Validate();

            _options = options;
            _token = options.Token;
            _dispatcher = options.Dispatcher != null ? options.Dispatcher : ImMainThreadDispatcher.Instance;
            _backoff = options.Backoff != null ? options.Backoff : new FullJitterBackoff();
            _transportFactory = options.TransportFactory != null
                ? options.TransportFactory
                : new Func<IImTransport>(ImTransports.CreateDefault);
            _platform = options.Platform != ImPlatform.Unknown ? options.Platform : ImDevice.DetectPlatform();
        }

        /// <summary>
        /// Where this connection runs its callbacks. Post to it yourself if you need to hop onto the
        /// same serialised timeline the SDK uses.
        /// </summary>
        public IImDispatcher Dispatcher
        {
            get { return _dispatcher; }
        }

        /// <summary>Current state. Readable from any thread.</summary>
        public ImConnectionState State
        {
            get { return (ImConnectionState)Volatile.Read(ref _stateCode); }
        }

        /// <summary>
        /// Requests sent and still waiting for a reply. A gauge, and the one place a leak in the
        /// correlation map would show: a cancelled or timed-out call that left its entry behind
        /// grows this for the life of the connection.
        /// </summary>
        /// <remarks>Read on the dispatcher thread; from anywhere else it is a snapshot at best.</remarks>
        public int PendingRequests
        {
            get { return _pending.Count; }
        }

        /// <summary>Raised on the dispatcher thread whenever <see cref="State"/> changes.</summary>
        public event Action<ImConnectionState> StateChanged;

        /// <summary>
        /// Raised on the dispatcher thread when the server closed this session deliberately, whether
        /// it announced it with a <c>conn.kick</c> push or only in the close reason.
        /// </summary>
        /// <remarks>
        /// Raised at most once per session, so the usual "push, then close with the same reason"
        /// sequence does not tell the player twice. When <see cref="ImKick.IsTerminal"/> is set the
        /// SDK has stopped for good: show something, because nothing else is coming.
        /// </remarks>
        public event Action<ImKick> Kicked;

        /// <summary>
        /// Subscribes to a server push target (see <see cref="ImPushTarget"/>). Dispose the result
        /// to unsubscribe. Handlers run on the dispatcher thread.
        /// </summary>
        public IDisposable On(string target, Action<ImFrame> handler)
        {
            if (string.IsNullOrEmpty(target))
            {
                throw new ArgumentException("target is required", "target");
            }

            if (handler == null)
            {
                throw new ArgumentNullException("handler");
            }

            lock (_listenerGate)
            {
                List<Action<ImFrame>> handlers;
                if (!_listeners.TryGetValue(target, out handlers))
                {
                    handlers = new List<Action<ImFrame>>(2);
                    _listeners[target] = handlers;
                }

                handlers.Add(handler);
            }

            return new Subscription(this, target, handler);
        }

        /// <summary>
        /// Opens the socket and completes when it is usable.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Attempts inside <see cref="ImConnectionOptions.ConnectTimeout"/> are retried with the
        /// normal jittered backoff, so a gateway that is mid-restart is waited out rather than
        /// reported as a failure. When the timeout does expire the returned task fails <i>and the
        /// connection stops</i>: a background reconnect loop the caller believes has already failed
        /// is worse than a clean error they can act on. Call this again to try afresh.
        /// </para>
        /// <para>
        /// A terminal kick during the attempt also fails the task — a banned account will not
        /// become un-banned by waiting.
        /// </para>
        /// </remarks>
        public Task ConnectAsync(CancellationToken cancellationToken = default(CancellationToken))
        {
            var completion = new TaskCompletionSource<bool>();
            _dispatcher.Post(delegate { BeginConnect(completion, cancellationToken); });
            return completion.Task;
        }

        /// <summary>
        /// Retries now instead of waiting out the current backoff delay.
        /// </summary>
        /// <remarks>
        /// Call it when the platform tells you something the SDK cannot see: the app returned to the
        /// foreground, or connectivity came back. The pending delay exists to spread a fleet out
        /// after a shared failure; a per-device signal that the network just changed is better
        /// information than that delay. It does not reset the attempt counter, so a device stuck in
        /// a captive portal that calls this in a loop still backs off. Does nothing once the
        /// connection has been closed or terminally kicked.
        /// </remarks>
        public void ReconnectNow()
        {
            _dispatcher.Post(delegate
            {
                if (_disposed || _stopped || State == ImConnectionState.Open)
                {
                    return;
                }

                if (_reconnectTimer == null)
                {
                    return;
                }

                _reconnectTimer.Dispose();
                _reconnectTimer = null;
                StartOpen();
            });
        }

        /// <summary>
        /// Replaces the token used for the next handshake. The current socket keeps the credential
        /// it connected with — the gateway authenticates at upgrade time and there is no way to
        /// re-authenticate an open socket.
        /// </summary>
        /// <remarks>
        /// Use it after your own login refreshes, or before calling <see cref="ConnectAsync"/> again
        /// following a terminal kick. Routine expiry does not need this: the SDK asks
        /// <see cref="ImConnectionOptions.TokenProvider"/> on its own.
        /// </remarks>
        public void SetToken(string token)
        {
            if (string.IsNullOrEmpty(token))
            {
                throw new ArgumentException("token is required", "token");
            }

            _dispatcher.Post(delegate { _token = token; });
        }

        /// <summary>
        /// Closes the socket and stops reconnecting. In-flight requests fail immediately rather than
        /// hanging until their deadlines.
        /// </summary>
        public void Close()
        {
            _dispatcher.Post(delegate { CloseInternal(); });
        }

        /// <inheritdoc/>
        public void Dispose()
        {
            _dispatcher.Post(delegate
            {
                if (_disposed)
                {
                    return;
                }

                _disposed = true;
                CloseInternal();

                lock (_listenerGate)
                {
                    _listeners.Clear();
                }

                StateChanged = null;
                Kicked = null;
            });
        }

        /// <summary>
        /// Sends a request and completes with its <c>data</c> payload.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Fails with <see cref="ImException"/> for any non-zero business code, so a caller can
        /// <c>try</c>/<c>catch</c> once instead of inspecting every result, and the exception
        /// carries the <c>traceId</c> that makes a support ticket answerable.
        /// </para>
        /// <para>
        /// A request issued while the socket is down fails immediately with
        /// <see cref="ImErrorCode.ServiceUnavailable"/> instead of queueing. A chat client that
        /// silently buffers sends produces messages that arrive minutes late with no explanation,
        /// and a game that shows its own retry UI can decide better than the SDK can.
        /// </para>
        /// </remarks>
        /// <param name="target">Endpoint name, e.g. <c>msg.send</c> (SPEC-02 §2).</param>
        /// <param name="body">Request payload. Null sends an empty object.</param>
        /// <param name="cancellationToken">Abandons the request; the server is not told.</param>
        public Task<JsonValue> RequestAsync(
            string target,
            JsonValue body = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            if (string.IsNullOrEmpty(target))
            {
                throw new ArgumentException("target is required", "target");
            }

            return SendWithReauthAsync(target, body, cancellationToken);
        }

        /// <summary>
        /// Renews the credential on the socket that is already open, without dropping it.
        /// </summary>
        /// <remarks>
        /// The gateway authenticates at upgrade time, so before <c>conn.reauth</c> existed a token
        /// expiring mid-session cost a full reconnect — on the flaky network where tokens tend to
        /// expire, which is exactly the reconnect anyone was trying to avoid. The new token must
        /// belong to the same user; one for anyone else is refused rather than quietly changing who
        /// this socket is. The token used for the <i>next</i> handshake is updated too, so a later
        /// reconnect does not fall back to the expired one.
        /// </remarks>
        public async Task ReauthAsync(
            string token,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            if (string.IsNullOrEmpty(token))
            {
                throw new ArgumentException("token is required", "token");
            }

            await SendOnceAsync("conn.reauth", JsonValue.NewObject().Set("token", token), cancellationToken)
                .ConfigureAwait(false);

            _dispatcher.Post(delegate { _token = token; });
        }

        /// <summary>
        /// Sends a request and, on <see cref="ImErrorCode.TokenExpired"/>, renews the token in place
        /// and tries once more.
        /// </summary>
        /// <remarks>
        /// <para>
        /// This is the one place the SDK retries a business call, and it is not a retry policy: a
        /// 1101 means the credential aged out between the call being written and being read, and the
        /// same call with a fresh token is a different call. Everything else — including
        /// <see cref="ImErrorCode.RateLimited"/> — surfaces with
        /// <see cref="ImException.IsRetryable"/> set and is the application's decision, because an
        /// SDK that silently re-sends hides rate limiting from the UI that has to explain it.
        /// </para>
        /// <para>
        /// Retrying a send is safe for the usual reason: <c>clientMsgId</c> is generated before the
        /// first attempt, so the server returns the original result rather than posting twice.
        /// </para>
        /// </remarks>
        private async Task<JsonValue> SendWithReauthAsync(
            string target,
            JsonValue body,
            CancellationToken cancellationToken)
        {
            try
            {
                return await SendOnceAsync(target, body, cancellationToken).ConfigureAwait(false);
            }
            catch (ImException failure)
            {
                var renewable = failure.Code == ImErrorCode.TokenExpired &&
                                _options.TokenProvider != null &&
                                !string.Equals(target, "conn.reauth", StringComparison.OrdinalIgnoreCase);

                if (!renewable)
                {
                    throw;
                }

                if (!await RenewTokenAsync().ConfigureAwait(false))
                {
                    throw;
                }

                return await SendOnceAsync(target, body, cancellationToken).ConfigureAwait(false);
            }
        }

        private Task<bool> RenewTokenAsync()
        {
            var completion = new TaskCompletionSource<bool>();
            _dispatcher.Post(delegate { BeginRenewToken(completion); });
            return completion.Task;
        }

        private void BeginRenewToken(TaskCompletionSource<bool> completion)
        {
            if (_disposed || _stopped)
            {
                completion.TrySetResult(false);
                return;
            }

            _renewWaiters.Add(completion);

            if (_renewing)
            {
                // Someone else is already asking. Every caller that piles up behind it gets the one
                // answer, which is the point: ten requests failing 1101 in the same frame is the
                // normal shape of a token expiring, not an unusual one.
                return;
            }

            _renewing = true;
            var ignored = RunRenewTokenAsync();
        }

        private async Task RunRenewTokenAsync()
        {
            var renewed = false;

            try
            {
                var provider = _options.TokenProvider;
                if (provider != null)
                {
                    var fresh = await provider(CancellationToken.None).ConfigureAwait(false);

                    // Returning null is the documented way for an app to say "this user is logged
                    // out now". Honour it here as well as on the reconnect path.
                    if (!string.IsNullOrEmpty(fresh))
                    {
                        await ReauthAsync(fresh).ConfigureAwait(false);
                        ImLog.Info("renewed the token in place; the socket was not dropped");
                        renewed = true;
                    }
                }
            }
            catch (Exception error)
            {
                ImLog.Warn("conn.reauth failed; the session will drop when the server closes it", error);
            }

            var outcome = renewed;
            _dispatcher.Post(delegate { FinishRenewToken(outcome); });
        }

        private void FinishRenewToken(bool renewed)
        {
            _renewing = false;
            ReleaseRenewWaiters(renewed);
        }

        private void ReleaseRenewWaiters(bool renewed)
        {
            if (_renewWaiters.Count == 0)
            {
                return;
            }

            var waiters = _renewWaiters.ToArray();
            _renewWaiters.Clear();
            for (int i = 0; i < waiters.Length; i++)
            {
                waiters[i].TrySetResult(renewed);
            }
        }

        private Task<JsonValue> SendOnceAsync(string target, JsonValue body, CancellationToken cancellationToken)
        {
            var completion = new TaskCompletionSource<JsonValue>();
            _dispatcher.Post(delegate { BeginRequest(target, body, completion, cancellationToken); });
            return completion.Task;
        }

        /// <summary>
        /// Sends a request whose payload is not interesting, for endpoints that only succeed or
        /// fail.
        /// </summary>
        public async Task ExecuteAsync(
            string target,
            JsonValue body = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            await RequestAsync(target, body, cancellationToken).ConfigureAwait(false);
        }

        // ------------------------------------------------------------------ connect

        private void BeginConnect(TaskCompletionSource<bool> completion, CancellationToken cancellationToken)
        {
            if (_disposed)
            {
                completion.TrySetException(new ObjectDisposedException("ImConnection"));
                return;
            }

            if (State == ImConnectionState.Open)
            {
                completion.TrySetResult(true);
                return;
            }

            if (cancellationToken.IsCancellationRequested)
            {
                completion.TrySetCanceled();
                return;
            }

            _connectWaiters.Add(completion);

            if (cancellationToken.CanBeCanceled)
            {
                cancellationToken.Register(delegate
                {
                    _dispatcher.Post(delegate
                    {
                        _connectWaiters.Remove(completion);
                        completion.TrySetCanceled();
                    });
                });
            }

            // Armed for every caller, including one that arrives mid-reconnect: a task that never
            // completes is worse than one that fails, and an app calling this from a "retry" button
            // needs an answer either way.
            ArmConnectDeadline();

            if (!_stopped)
            {
                // Already connecting or reconnecting: this caller just joins the wait.
                return;
            }

            _stopped = false;
            _attempt = 0;
            EnsureLifetime();
            StartOpen();
        }

        private void ArmConnectDeadline()
        {
            if (_connectDeadline != null || _options.ConnectTimeout <= TimeSpan.Zero)
            {
                return;
            }

            var budget = _options.ConnectTimeout;
            _connectDeadline = _dispatcher.Schedule(budget, delegate
            {
                _connectDeadline = null;
                if (State == ImConnectionState.Open || _stopped)
                {
                    return;
                }

                var failure = new ImException(
                    ImErrorCode.Timeout,
                    "could not reach the gateway within " +
                    budget.TotalSeconds.ToString("0.#", CultureInfo.InvariantCulture) + "s");

                // Take the waiters before closing: CloseInternal fails whatever is still waiting
                // with a generic "closed", and the caller deserves the reason it actually failed.
                var waiters = _connectWaiters.ToArray();
                _connectWaiters.Clear();

                CloseInternal();

                for (int i = 0; i < waiters.Length; i++)
                {
                    waiters[i].TrySetException(failure);
                }
            });
        }

        private void SignalConnected()
        {
            if (_connectDeadline != null)
            {
                _connectDeadline.Dispose();
                _connectDeadline = null;
            }

            if (_connectWaiters.Count == 0)
            {
                return;
            }

            var waiters = _connectWaiters.ToArray();
            _connectWaiters.Clear();
            for (int i = 0; i < waiters.Length; i++)
            {
                waiters[i].TrySetResult(true);
            }
        }

        private void FailConnectWaiters(Exception error)
        {
            if (_connectWaiters.Count == 0)
            {
                return;
            }

            var waiters = _connectWaiters.ToArray();
            _connectWaiters.Clear();
            for (int i = 0; i < waiters.Length; i++)
            {
                waiters[i].TrySetException(error);
            }
        }

        // ------------------------------------------------------------------- socket

        private void StartOpen()
        {
            if (_disposed || _stopped)
            {
                return;
            }

            EnsureLifetime();
            _session++;
            _sessionEnded = false;
            _kickReported = false;
            var session = _session;

            SetState(_attempt == 0 ? ImConnectionState.Connecting : ImConnectionState.Reconnecting);

            IImTransport transport;
            try
            {
                transport = _transportFactory();
            }
            catch (Exception error)
            {
                ImLog.Error("could not create a transport", error);
                EndSession(session, new ImTransportClose(1006, string.Empty, error));
                return;
            }

            _transport = transport;

            // Both of these can arrive on a socket thread. Everything they touch lives on the
            // dispatcher, so nothing is decided here beyond "which session was this".
            transport.TextReceived = delegate(string text)
            {
                _dispatcher.Post(delegate { HandleText(session, text); });
            };

            transport.Closed = delegate(ImTransportClose close)
            {
                _dispatcher.Post(delegate { EndSession(session, close); });
            };

            Uri url;
            try
            {
                url = BuildUrl();
            }
            catch (Exception error)
            {
                ImLog.Error("endpoint is not a usable URL", error);
                EndSession(session, new ImTransportClose(1006, string.Empty, error));
                return;
            }

            // Host and path only. The query string carries the user token, and a token in a log
            // file — or in a bug report screenshot of the Unity console — is a live credential.
            ImLog.Info("connecting to " + url.Scheme + "://" + url.Host + url.AbsolutePath +
                       " (attempt " + _attempt.ToString(CultureInfo.InvariantCulture) + ")");

            Task handshake;
            try
            {
                handshake = transport.ConnectAsync(url, _lifetime.Token);
            }
            catch (Exception error)
            {
                EndSession(session, new ImTransportClose(1006, string.Empty, error));
                return;
            }

            handshake.ContinueWith(
                delegate(Task completed)
                {
                    _dispatcher.Post(delegate
                    {
                        if (completed.IsFaulted || completed.IsCanceled)
                        {
                            // The transport also reports this through Closed; EndSession is
                            // idempotent per session, so whichever arrives first wins and the
                            // other is ignored.
                            var error = completed.Exception != null
                                ? (Exception)completed.Exception.GetBaseException()
                                : new ImException(ImErrorCode.ServiceUnavailable, "handshake cancelled");
                            EndSession(session, new ImTransportClose(1006, string.Empty, error));
                            return;
                        }

                        HandleOpened(session);
                    });
                },
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }

        private void HandleOpened(int session)
        {
            if (session != _session || _sessionEnded)
            {
                return;
            }

            if (_stopped)
            {
                // Closed while the handshake was in flight.
                CloseInternal();
                return;
            }

            // Reset only once a socket actually opened. Resetting on the attempt itself would turn
            // a gateway that accepts and immediately drops connections into a tight retry loop.
            //
            // The heartbeat interval is deliberately *not* reset: the cadence a previous socket
            // learned is a better guess than the default, and if the server had asked for something
            // faster than 30 s, going back to the default could get this session dropped before its
            // first beat. The first reply corrects it either way.
            _attempt = 0;

            SetState(ImConnectionState.Open);
            ImLog.Info("connected");

            ScheduleHeartbeat();
            SignalConnected();
        }

        private void EndSession(int session, ImTransportClose close)
        {
            if (session != _session || _sessionEnded)
            {
                return;
            }

            _sessionEnded = true;
            StopHeartbeat();

            var transport = _transport;
            _transport = null;
            if (transport != null)
            {
                // Dispose aborts, which raises Closed again — harmless, because this session is
                // already marked ended and the callback is dropped above.
                transport.TextReceived = null;
                transport.Closed = null;
                transport.Dispose();
            }

            // 1004 Timeout rather than 1005 ServiceUnavailable, and the difference is not cosmetic:
            // 1005 claims the call was never delivered, and this code does not know that. The
            // request may well have executed on the server before the socket went. 1004 is the
            // honest answer, and it is the one that makes a caller reach for clientMsgId
            // idempotency instead of blindly resending.
            FailAllPending(new ImException(ImErrorCode.Timeout, "the connection was lost before a reply arrived"));

            if (_stopped || _disposed)
            {
                SetState(ImConnectionState.Closed);
                return;
            }

            ImKick kick;
            if (ImKicks.TryParse(close.Reason, out kick))
            {
                if (kick.IsTerminal)
                {
                    // Coming back would fail identically, forever.
                    ImLog.Info("kicked: " + kick.RawReason + " (terminal, not reconnecting)");
                    StopRetrying();
                    ReportKick(kick);
                    SetState(ImConnectionState.Closed);
                    FailConnectWaiters(new ImException(
                        kick.Reason == ImKickReason.UserBanned ? ImErrorCode.UserBanned : ImErrorCode.Unauthorized,
                        "kicked by the server: " + kick.RawReason));
                    return;
                }

                if (kick.Reason == ImKickReason.TokenExpired)
                {
                    RefreshTokenAndReconnect(kick);
                    return;
                }

                ImLog.Info("kicked: " + kick.RawReason + " (recoverable, reconnecting)");
                ReportKick(kick);
            }
            else if (close.Error != null)
            {
                ImLog.Info("socket failed: " + close.Error.Message);
            }
            else
            {
                ImLog.Info("socket closed: " + close);
            }

            ScheduleReconnect();
        }

        private void ScheduleReconnect()
        {
            if (_stopped || _disposed)
            {
                return;
            }

            SetState(ImConnectionState.Reconnecting);
            _attempt++;

            var delay = _backoff.NextDelay(_attempt);
            ImLog.Info("reconnecting in " + delay.TotalMilliseconds.ToString("0", CultureInfo.InvariantCulture) +
                       " ms (attempt " + _attempt.ToString(CultureInfo.InvariantCulture) + ")");

            if (_reconnectTimer != null)
            {
                _reconnectTimer.Dispose();
            }

            _reconnectTimer = _dispatcher.Schedule(delay, delegate
            {
                _reconnectTimer = null;
                StartOpen();
            });
        }

        private void RefreshTokenAndReconnect(ImKick kick)
        {
            var provider = _options.TokenProvider;
            if (provider == null)
            {
                // Nobody to ask. This is a configuration mistake worth being loud about: the token
                // will expire on every long-lived session, and without a provider every one of them
                // ends here.
                ImLog.Warn("the token expired and no ImConnectionOptions.TokenProvider was set");
                StopRetrying();
                ReportKick(kick);
                SetState(ImConnectionState.Closed);
                FailConnectWaiters(new ImException(ImErrorCode.TokenExpired, "the user token expired"));
                return;
            }

            SetState(ImConnectionState.Reconnecting);
            ImLog.Info("token expired, asking the host app for a fresh one");

            Task<string> request;
            try
            {
                request = provider(_lifetime.Token);
            }
            catch (Exception error)
            {
                ImLog.Error("the token provider threw", error);
                request = null;
            }

            if (request == null)
            {
                StopForRefusedToken(kick);
                return;
            }

            request.ContinueWith(
                delegate(Task<string> completed)
                {
                    _dispatcher.Post(delegate
                    {
                        if (_stopped || _disposed)
                        {
                            return;
                        }

                        string fresh = null;
                        if (completed.Status == TaskStatus.RanToCompletion)
                        {
                            fresh = completed.Result;
                        }
                        else if (completed.Exception != null)
                        {
                            // The host app's token endpoint is down. Treat it as a refusal rather
                            // than looping on a token we already know the server rejects.
                            ImLog.Error("the token provider failed", completed.Exception.GetBaseException());
                        }

                        if (string.IsNullOrEmpty(fresh))
                        {
                            StopForRefusedToken(kick);
                            return;
                        }

                        _token = fresh;
                        ScheduleReconnect();
                    });
                },
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }

        private void StopForRefusedToken(ImKick kick)
        {
            // Returning null from the provider is the documented way for an app to say "this user
            // is logged out now" — it must stop the reconnect loop, not restart it.
            StopRetrying();
            ReportKick(kick);
            SetState(ImConnectionState.Closed);
            FailConnectWaiters(new ImException(ImErrorCode.TokenExpired, "no replacement token was supplied"));
        }

        /// <summary>
        /// Stops the reconnect machinery without touching the socket, for the paths where the socket
        /// is already gone and only the timers are still alive.
        /// </summary>
        private void StopRetrying()
        {
            _stopped = true;

            if (_reconnectTimer != null)
            {
                _reconnectTimer.Dispose();
                _reconnectTimer = null;
            }

            if (_connectDeadline != null)
            {
                _connectDeadline.Dispose();
                _connectDeadline = null;
            }
        }

        private void CloseInternal()
        {
            _stopped = true;
            _sessionEnded = true;
            _session++;

            StopHeartbeat();

            if (_reconnectTimer != null)
            {
                _reconnectTimer.Dispose();
                _reconnectTimer = null;
            }

            if (_connectDeadline != null)
            {
                _connectDeadline.Dispose();
                _connectDeadline = null;
            }

            if (_lifetime != null)
            {
                try
                {
                    _lifetime.Cancel();
                }
                catch (ObjectDisposedException)
                {
                }
            }

            var transport = _transport;
            _transport = null;
            if (transport != null)
            {
                transport.TextReceived = null;
                transport.Closed = null;
                transport.Close(NormalCloseCode, "client-close");

                // Give the close handshake a moment before releasing the socket. Disposing straight
                // away aborts it, and a server that never sees a close frame keeps the session
                // registered until its own timeout — which under a single-device policy is how a
                // player gets told they are already logged in elsewhere.
                _dispatcher.Schedule(TimeSpan.FromSeconds(3), transport.Dispose);
            }

            // Same reasoning as EndSession: an in-flight request whose socket is taken away may
            // already have run, so it fails 1004 and not 1005. A caller that never got a reply is
            // told exactly that, rather than being told something that might not be true.
            FailAllPending(new ImException(ImErrorCode.Timeout, "the connection was closed before a reply arrived"));

            // A renewal nobody will finish would leave its waiters awaiting forever, and each of
            // those is a caller that already has an answer coming — the failure of the call it was
            // retrying.
            ReleaseRenewWaiters(false);

            SetState(ImConnectionState.Closed);
            FailConnectWaiters(new ImException(ImErrorCode.ServiceUnavailable, "connection closed"));
        }

        private void EnsureLifetime()
        {
            if (_lifetime != null && !_lifetime.IsCancellationRequested)
            {
                return;
            }

            if (_lifetime != null)
            {
                _lifetime.Dispose();
            }

            _lifetime = new CancellationTokenSource();
        }

        // ---------------------------------------------------------------- requests

        private void BeginRequest(
            string target,
            JsonValue body,
            TaskCompletionSource<JsonValue> completion,
            CancellationToken cancellationToken)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                completion.TrySetCanceled();
                return;
            }

            var transport = _transport;
            if (transport == null || State != ImConnectionState.Open)
            {
                completion.TrySetException(new ImException(
                    ImErrorCode.ServiceUnavailable,
                    "not connected, so " + target + " was not sent",
                    null,
                    target));
                return;
            }

            var id = NextRequestId();
            var pending = new PendingRequest(completion, target);
            _pending[id] = pending;

            pending.Timer = _dispatcher.Schedule(_options.RequestTimeout, delegate
            {
                if (!_pending.Remove(id))
                {
                    return;
                }

                pending.Release();
                completion.TrySetException(new ImException(
                    ImErrorCode.Timeout,
                    "request timed out: " + target,
                    null,
                    target));
            });

            if (cancellationToken.CanBeCanceled)
            {
                pending.Cancellation = cancellationToken.Register(delegate
                {
                    _dispatcher.Post(delegate
                    {
                        if (!_pending.Remove(id))
                        {
                            return;
                        }

                        pending.Release();
                        completion.TrySetCanceled();
                    });
                });
            }

            var payload = JsonValue.NewObject()
                .Set("id", id)
                .Set("target", target)
                .Set("body", body != null ? body : JsonValue.NewObject());

            var text = payload.ToJson();
            ImLog.Verbose("→ " + text);
            transport.Send(text);
        }

        private string NextRequestId()
        {
            _requestCounter++;

            // Unique per connection and per instant, and short enough not to bloat every frame.
            return "c" + _requestCounter.ToString("x", CultureInfo.InvariantCulture) + "-" +
                   DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString("x", CultureInfo.InvariantCulture);
        }

        private void FailAllPending(Exception error)
        {
            if (_pending.Count == 0)
            {
                return;
            }

            var entries = new List<PendingRequest>(_pending.Values);
            _pending.Clear();

            for (int i = 0; i < entries.Count; i++)
            {
                entries[i].Release();
                entries[i].Completion.TrySetException(error);
            }
        }

        // ------------------------------------------------------------------ receive

        private void HandleText(int session, string text)
        {
            if (session != _session || _sessionEnded)
            {
                return;
            }

            ImLog.Verbose("← " + text);

            JsonValue root;
            if (!ImJson.TryParse(text, out root))
            {
                // A frame we cannot read is a frame we must drop rather than half-interpret.
                ImLog.Warn("dropped an unparseable frame of " +
                           text.Length.ToString(CultureInfo.InvariantCulture) + " characters");
                return;
            }

            var frame = ImFrame.FromJson(root);

            PendingRequest waiting = null;
            if (!string.IsNullOrEmpty(frame.Id) && _pending.TryGetValue(frame.Id, out waiting))
            {
                _pending.Remove(frame.Id);
                waiting.Release();
                CompleteRequest(waiting, frame);
                return;
            }

            DispatchPush(frame);
        }

        private static void CompleteRequest(PendingRequest pending, ImFrame frame)
        {
            if (frame.Status == UnknownTargetStatus)
            {
                // 1008 UnsupportedOperation, and deliberately not 1002 NotFound. 1002 means "your
                // group does not exist"; 1008 means "this deployment does not have this endpoint" —
                // which is what an SDK newer than a private-deployment server produces, and is the
                // one thing the integrator staring at it needs to be told verbatim.
                pending.Completion.TrySetException(new ImException(
                    ImErrorCode.UnsupportedOperation,
                    "this deployment has no endpoint named " + pending.Target,
                    frame.TraceId,
                    pending.Target));
                return;
            }

            if (frame.Status != 0)
            {
                // The endpoint itself threw. Status and code are different layers on purpose —
                // SPEC-02 §1.2 — and a server that filled in a business code alongside the
                // transport failure knows more about it than we do.
                var code = frame.Code != 0 ? frame.Code : ImErrorCode.InternalError;
                var message = !string.IsNullOrEmpty(frame.Msg) ? frame.Msg : "transport error on " + pending.Target;
                pending.Completion.TrySetException(new ImException(code, message, frame.TraceId, pending.Target));
                return;
            }

            if (!frame.Body.IsObject)
            {
                pending.Completion.TrySetException(new ImException(
                    ImErrorCode.InternalError,
                    "the reply to " + pending.Target + " carried no result body",
                    null,
                    pending.Target));
                return;
            }

            if (frame.Code != ImErrorCode.Ok)
            {
                var message = !string.IsNullOrEmpty(frame.Message) ? frame.Message : pending.Target + " failed";
                pending.Completion.TrySetException(
                    new ImException(frame.Code, message, frame.TraceId, pending.Target));
                return;
            }

            pending.Completion.TrySetResult(frame.Data);
        }

        private void DispatchPush(ImFrame frame)
        {
            if (string.Equals(frame.Target, ImPushTarget.Kick, StringComparison.OrdinalIgnoreCase))
            {
                // The server announces a kick before closing. Reporting it here means the app knows
                // why even in the window before the socket actually goes away.
                ReportKick(ImKicks.FromPayload(frame.Data));
            }

            Action<ImFrame>[] handlers = null;
            lock (_listenerGate)
            {
                List<Action<ImFrame>> registered;
                if (_listeners.TryGetValue(frame.Target, out registered) && registered.Count > 0)
                {
                    handlers = registered.ToArray();
                }
            }

            if (handlers == null)
            {
                return;
            }

            for (int i = 0; i < handlers.Length; i++)
            {
                ImSafeEvent.Invoke(handlers[i], frame);
            }
        }

        private void ReportKick(ImKick kick)
        {
            if (_kickReported)
            {
                return;
            }

            _kickReported = true;
            ImSafeEvent.Raise(Kicked, kick);
        }

        // ---------------------------------------------------------------- heartbeat

        /// <summary>
        /// Beats on the server's cadence and forces the socket down when a beat fails.
        /// </summary>
        /// <remarks>
        /// The failed beat is the point. A phone that changed network, or a middlebox that dropped
        /// the flow, leaves a socket the OS still reports as perfectly healthy because nothing was
        /// ever sent to prove otherwise — the half-open case. Nothing else notices: reads block
        /// forever and writes succeed into a void. A beat that does not come back is the proof, and
        /// aborting rather than closing politely is deliberate, because a polite close on a dead
        /// socket waits for a reply that is never coming.
        /// </remarks>
        private void ScheduleHeartbeat()
        {
            StopHeartbeat();

            var session = _session;
            _heartbeatTimer = _dispatcher.Schedule(TimeSpan.FromSeconds(_heartbeatSeconds), delegate
            {
                _heartbeatTimer = null;
                Beat(session);
            });
        }

        private void Beat(int session)
        {
            if (session != _session || _sessionEnded || State != ImConnectionState.Open)
            {
                return;
            }

            var transport = _transport;

            RequestAsync("conn.heartbeat").ContinueWith(
                delegate(Task<JsonValue> completed)
                {
                    _dispatcher.Post(delegate
                    {
                        if (session != _session || _sessionEnded)
                        {
                            return;
                        }

                        if (completed.Status != TaskStatus.RanToCompletion)
                        {
                            ImLog.Warn("heartbeat failed; treating the socket as half-open and forcing it down");
                            if (transport != null)
                            {
                                transport.Abort();
                            }

                            return;
                        }

                        // The server owns the cadence; adopt whatever it reports. A gateway under
                        // load can widen it, and a client that keeps its own interval would be
                        // dropped for being too slow or waste battery being too fast.
                        var reported = completed.Result["intervalSeconds"].AsInt();
                        if (reported > 0 && reported != _heartbeatSeconds)
                        {
                            ImLog.Info("heartbeat interval is now " +
                                       reported.ToString(CultureInfo.InvariantCulture) + "s");
                            _heartbeatSeconds = reported;
                        }

                        ScheduleHeartbeat();
                    });
                },
                CancellationToken.None,
                TaskContinuationOptions.ExecuteSynchronously,
                TaskScheduler.Default);
        }

        private void StopHeartbeat()
        {
            if (_heartbeatTimer != null)
            {
                _heartbeatTimer.Dispose();
                _heartbeatTimer = null;
            }
        }

        // ------------------------------------------------------------------ plumbing

        private Uri BuildUrl()
        {
            var endpoint = _options.Endpoint.TrimEnd('/');
            var channel = string.IsNullOrEmpty(_options.Channel) ? "/im" : _options.Channel;
            if (channel[0] != '/')
            {
                channel = "/" + channel;
            }

            var url = new StringBuilder(160);
            url.Append(endpoint).Append(channel);

            // Credentials travel in the query string because a browser WebSocket handshake cannot
            // carry custom headers, and the WebGL build has to speak the same protocol as every
            // other platform. The gateway authenticates during the upgrade and rejects a bad token
            // with a 401 before a connection is ever allocated.
            url.Append("?appId=").Append(Uri.EscapeDataString(_options.AppId));
            url.Append("&token=").Append(Uri.EscapeDataString(_token));
            url.Append("&deviceId=").Append(Uri.EscapeDataString(_options.DeviceId));
            url.Append("&platform=").Append(((int)_platform).ToString(CultureInfo.InvariantCulture));
            url.Append("&v=1");

            if (!string.IsNullOrEmpty(_options.ClientVersion))
            {
                url.Append("&cv=").Append(Uri.EscapeDataString(_options.ClientVersion));
            }

            if (!string.IsNullOrEmpty(_options.Language))
            {
                url.Append("&lang=").Append(Uri.EscapeDataString(_options.Language));
            }

            return new Uri(url.ToString());
        }

        private void SetState(ImConnectionState state)
        {
            if (State == state)
            {
                return;
            }

            Volatile.Write(ref _stateCode, (int)state);
            ImSafeEvent.Raise(StateChanged, state);
        }

        private void Unsubscribe(string target, Action<ImFrame> handler)
        {
            lock (_listenerGate)
            {
                List<Action<ImFrame>> handlers;
                if (!_listeners.TryGetValue(target, out handlers))
                {
                    return;
                }

                handlers.Remove(handler);
                if (handlers.Count == 0)
                {
                    _listeners.Remove(target);
                }
            }
        }

        private sealed class PendingRequest
        {
            internal readonly TaskCompletionSource<JsonValue> Completion;
            internal readonly string Target;
            internal IDisposable Timer;
            internal CancellationTokenRegistration Cancellation;

            internal PendingRequest(TaskCompletionSource<JsonValue> completion, string target)
            {
                Completion = completion;
                Target = target;
            }

            internal void Release()
            {
                if (Timer != null)
                {
                    Timer.Dispose();
                    Timer = null;
                }

                Cancellation.Dispose();
            }
        }

        private sealed class Subscription : IDisposable
        {
            private ImConnection _owner;
            private readonly string _target;
            private readonly Action<ImFrame> _handler;

            internal Subscription(ImConnection owner, string target, Action<ImFrame> handler)
            {
                _owner = owner;
                _target = target;
                _handler = handler;
            }

            public void Dispose()
            {
                var owner = _owner;
                if (owner == null)
                {
                    return;
                }

                _owner = null;
                owner.Unsubscribe(_target, _handler);
            }
        }
    }
}
