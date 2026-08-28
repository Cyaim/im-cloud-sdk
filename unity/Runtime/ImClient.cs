using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Cyaim.Im.Json;
using Cyaim.Im.Threading;

namespace Cyaim.Im
{
    /// <summary>
    /// The client a game actually uses: connect, send, and receive messages that are in order and
    /// have no holes in them.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Beyond wrapping endpoints, this owns the one thing every correct IM client must do and most
    /// hand-rolled ones do not: it tracks where each conversation stands, notices when an arriving
    /// message skips a number, and pulls the missing range before delivering. WebSocket delivery is
    /// at-most-once and unordered across a reconnect; contiguous <c>seq</c> plus this repair loop is
    /// what turns that into a correct, ordered conversation.
    /// </para>
    /// <para>
    /// <b>Two cursors, not one.</b> <c>deliveredSeq</c> is the highest seq handed to the game in
    /// this process; it lives in memory and drives gap detection and duplicate suppression.
    /// <c>committedSeq</c> is the highest seq the game has told the SDK it has <i>durably stored</i>
    /// through <see cref="Commit"/>; it is written to <see cref="ImClientOptions.CursorStore"/> and
    /// it — never the delivered one — is what gets reported to the server on resume. The SDK will
    /// not advance <c>committedSeq</c> from the mere fact that a handler returned: a callback
    /// returning means the message reached memory, which is exactly the state a crash loses, and
    /// inferring durability from it is how you get a cursor that is confidently wrong.
    /// </para>
    /// <para>
    /// Delivery is therefore <b>at-least-once</b>. Be idempotent on
    /// <see cref="ImMessage.MessageId"/>. See <c>sdk/CONTRACT.md</c> §5 for the whole model,
    /// including the silent data-loss bug this design exists to close.
    /// </para>
    /// <para>
    /// Each conversation has its own command queue. That is not decoration: a repair is a network
    /// round trip, and letting the next arriving message overtake an in-flight repair would deliver
    /// the very out-of-order jump the repair exists to prevent, while running repairs inline across
    /// conversations would stall every other chat behind one slow <c>msg.sync</c>. Per-conversation
    /// serialisation is exactly the granularity the <c>seq</c> invariant is defined at.
    /// </para>
    /// <para>
    /// <b>Threading.</b> Every event here is raised on the dispatcher thread — the Unity main
    /// thread — so a handler may touch <c>GameObject</c>s freely. That is the whole reason the
    /// dispatcher exists: the first thing anyone writes in a message handler is
    /// <c>Instantiate(chatBubble)</c>, and doing that from a socket thread crashes the player.
    /// Internally the same guarantee comes for free, because a <see cref="Task"/> from
    /// <see cref="ImConnection"/> is completed on the dispatcher thread, so every <c>await</c> below
    /// resumes there and the cursors need no locking.
    /// </para>
    /// <para>
    /// 客户端必须做、而多数自研客户端没做的事：按会话记录游标，发现跳号就先补拉再投递。
    /// 两个游标缺一不可：内存里的 deliveredSeq 用来查漏和去重，落盘的 committedSeq 才是上报给
    /// 服务端的位置。把 deliveredSeq 当成落盘位置上报，正是冷启动静默丢消息的根因。
    /// </para>
    /// </remarks>
    /// <example>
    /// <code>
    /// var im = new ImClient(new ImClientOptions
    /// {
    ///     Endpoint = "wss://im.example.com",
    ///     AppId = "your-app-id",
    ///     UserId = "alice",
    ///     Token = tokenFromYourBackend,
    ///     DeviceId = ImDevice.GetOrCreateDeviceId(),
    ///     TokenProvider = ct => FetchTokenFromYourBackend(ct),
    ///     CursorStore = ImCursorStore.PersistentDataPath(),
    /// });
    ///
    /// im.MessageReceived += m =&gt;
    /// {
    ///     ChatDatabase.Insert(m);                 // durable first
    ///     im.Commit(m.ConversationId, m.Seq);     // then, and only then, commit
    ///     ChatView.Append(m);
    /// };
    ///
    /// await im.ConnectAsync();
    /// await im.Msg.SendAsync(new ImSendRequest { Recipient = ImRecipient.User("bob"), Content = … });
    /// </code>
    /// </example>
    public sealed class ImClient : IDisposable
    {
        /// <summary>
        /// Messages per <c>msg.sync</c> call during a repair. The server clamps to this whatever the
        /// client asks for, so asking for more only produces a silently short page.
        /// </summary>
        internal const int ServerSyncPageLimit = 500;

        private readonly ImConnection _connection;
        private readonly IImDispatcher _dispatcher;
        private readonly IDisposable _messageSubscription;
        private readonly IDisposable _systemSubscription;
        private readonly ImDeviceLogs _deviceLogs;
        private readonly Dictionary<string, Inbox> _inboxes = new Dictionary<string, Inbox>(StringComparer.Ordinal);
        private readonly long _maxAutoRepair;
        private readonly int _maxRepairPages;
        private readonly Random _random = new Random(Environment.TickCount ^ Guid.NewGuid().GetHashCode());

        private readonly IImCursorStore _store;
        private readonly ImCursorScope _scope;
        private readonly TimeSpan _flushInterval;

        /// <summary>Committed cursors, mirrored to the store. Touched on the dispatcher thread only.</summary>
        private readonly ImCursorSnapshot _snapshot;

        /// <summary>What the store handed back at construction, kept frozen for diagnostics.</summary>
        private readonly ImCursorSnapshot _restored;

        /// <summary>False after a failed load: adopt nothing, persist nothing. See §5.8.</summary>
        private bool _cursorsUsable = true;

        private ImCursorStoreException _loadFailure;

        /// <summary>Set when the store handed back another account's cursors. See §5.3.</summary>
        private bool _cursorScopeRejected;

        private bool _loadFailureReported;
        private bool _snapshotDirty;
        private IDisposable _flushTimer;

        /// <summary>
        /// Bumped by every resume run, so a run left over from a socket that has since died cannot
        /// advance a cursor on behalf of the socket that replaced it.
        /// </summary>
        private int _resumeGeneration;

        private bool _disposed;

        /// <summary>Creates a client. Nothing connects until <see cref="ConnectAsync"/>.</summary>
        /// <param name="options">
        /// Endpoint, credentials and policies. <see cref="ImClientOptions.CursorStore"/> is
        /// required; see its documentation for why it has no default.
        /// </param>
        public ImClient(ImClientOptions options)
        {
            if (options == null)
            {
                throw new ArgumentNullException("options");
            }

            _maxAutoRepair = options.MaxAutoRepairSeq > 0
                ? options.MaxAutoRepairSeq
                : ImClientOptions.DefaultMaxAutoRepairSeq;
            _maxRepairPages = options.MaxRepairPages > 0 ? options.MaxRepairPages : 64;
            _flushInterval = options.CursorFlushInterval >= TimeSpan.Zero
                ? options.CursorFlushInterval
                : ImClientOptions.DefaultCursorFlushInterval;

            _store = options.CursorStore;
            _scope = ImCursorScope.Of(options.Endpoint, options.AppId, options.UserId);

            // Not asked of the store: the SDK recognises its own in-memory store by type, so a
            // store a game wrote cannot announce itself volatile and switch this warning off. The
            // warning is the only thing standing between a misconfigured build and a support ticket
            // about missing history.
            if (_store is ImMemoryCursorStore)
            {
                ImLog.Warn(
                    "cursors are not being persisted (ImCursorStore.InMemory). Every cold start will " +
                    "adopt the server's position, so messages that arrive while this app is closed " +
                    "are never delivered. See sdk/CONTRACT.md §5.3.");
            }

            _snapshot = LoadSnapshot();
            _restored = _snapshot.Clone();
            SeedInboxes(_snapshot);

            _connection = new ImConnection(options);
            _dispatcher = _connection.Dispatcher;

            Conn = new ImConnApi(this);
            Msg = new ImMsgApi(this);
            Conv = new ImConvApi(this);
            User = new ImUserApi(this);
            Friend = new ImFriendApi(this);
            Group = new ImGroupApi(this);
            Media = new ImMediaApi(this);
            Push = new ImPushApi(this);
            Moderation = new ImModerationApi(this);
            Diag = new ImDiagApi(this);

            // Defaulted rather than required, unlike the cursor store: losing cursors loses a
            // player's messages, while losing logs loses a diagnostic (ADR-003).
            // 与游标存储不同这里有默认值：丢游标丢的是玩家的消息，丢日志丢的是一次排障。
            Log = new ImLogRecorder(
                options.LogStore ?? ImLogStore.InMemory(),
                message => ImLog.Info(message));

            _deviceLogs = new ImDeviceLogs(Diag, Log, options.DeviceId);

            _messageSubscription = _connection.On(ImPushTarget.Message, HandleMessageFrame);

            // A log request arrives inside evt.system rather than on a target of its own, so a
            // client built before this feature existed receives an action it does not recognise and
            // ignores it. A new target would instead be silently dropped by every existing build,
            // and there would be no way to tell that apart from a device that was offline (ADR-003).
            // 走 evt.system 里的一个 action 而不是新事件名：旧版本收到不认识的 action 会忽略它。
            _systemSubscription = _connection.On(ImPushTarget.System, HandleSystemFrame);
            _connection.StateChanged += HandleStateChanged;
            _connection.Kicked += HandleKicked;

            // A game killed in the background loses whatever the debounce was still holding, and on
            // mobile that is the common case rather than the rare one.
            ImMainThreadDispatcher.ApplicationSuspending += HandleApplicationSuspending;
        }

        // ------------------------------------------------------------------ namespaces

        /// <summary><c>conn.*</c> — heartbeat, reauth, resume.</summary>
        public ImConnApi Conn { get; private set; }

        /// <summary><c>msg.*</c> — send, sync, history, recall, edit, forward, react, receipts.</summary>
        public ImMsgApi Msg { get; private set; }

        /// <summary><c>conv.*</c> — the conversation list and the per-user state on it.</summary>
        public ImConvApi Conv { get; private set; }

        /// <summary><c>user.*</c> — profiles and presence.</summary>
        public ImUserApi User { get; private set; }

        /// <summary><c>friend.*</c> — contacts, requests, blocking.</summary>
        public ImFriendApi Friend { get; private set; }

        /// <summary><c>group.*</c> — groups and their rosters.</summary>
        public ImGroupApi Group { get; private set; }

        /// <summary><c>media.*</c> — upload tickets and signed download URLs.</summary>
        public ImMediaApi Media { get; private set; }

        /// <summary><c>push.*</c> — offline notification registration and the tap that follows.</summary>
        public ImPushApi Push { get; private set; }

        /// <summary><c>moderation.*</c> — reporting a user or one of their messages.</summary>
        public ImModerationApi Moderation { get; private set; }

        /// <summary><c>diag.*</c> — this device's half of troubleshooting. Driven by the client.</summary>
        public ImDiagApi Diag { get; private set; }

        /// <summary>
        /// The SDK's own runtime log: written here, read when the server asks this device for it.
        /// </summary>
        /// <remarks>
        /// Exposed so a game can add its own lines — the ones that explain what the <i>player</i> was
        /// doing when it went wrong, which the SDK cannot see and which are usually the half that
        /// makes a log worth reading.
        /// 公开出来是为了让游戏写自己的行：SDK 看不见玩家当时在做什么，而那往往是让日志值得读的那一半。
        /// </remarks>
        public ImLogRecorder Log { get; private set; }

        // ------------------------------------------------------------------ properties

        /// <summary>
        /// The socket underneath. Use it for the things this class does not wrap: another push
        /// target, a raw frame, a fresh token after a kick.
        /// </summary>
        public ImConnection Connection
        {
            get { return _connection; }
        }

        /// <summary>Current connection state. Readable from any thread.</summary>
        public ImConnectionState State
        {
            get { return _connection.State; }
        }

        /// <summary>
        /// The loop every callback here runs on. Post to it to move your own work onto the same
        /// serialised timeline — useful in a headless build driving a <c>ManualDispatcher</c>.
        /// </summary>
        public IImDispatcher Dispatcher
        {
            get { return _dispatcher; }
        }

        /// <summary>
        /// False when the cursor store could not be read, or when it does not persist at all. While
        /// this is false the SDK adopts nothing and writes nothing.
        /// </summary>
        /// <remarks>
        /// Worth surfacing somewhere a tester can see. A build whose cursors are not persisting
        /// behaves perfectly until the app is closed, and then loses every message that arrived
        /// while it was — which is not a bug anyone finds by using the app for five minutes.
        /// </remarks>
        public bool CursorsPersisted
        {
            get { return _cursorsUsable && !(_store is ImMemoryCursorStore); }
        }

        /// <summary>
        /// What <see cref="ImClientOptions.CursorStore"/> returned at construction, frozen.
        /// </summary>
        /// <remarks>
        /// Empty after a failed load, and empty on a genuinely fresh install — the two are told
        /// apart by <see cref="CursorStoreFailed"/>, never by this being empty. Useful on a test
        /// build to answer "did this launch actually restore anything", which is otherwise
        /// invisible until the day it matters.
        /// </remarks>
        public ImCursorSnapshot RestoredCursors
        {
            get { return _restored.Clone(); }
        }

        /// <summary>The committed cursors as they stand now, as an independent copy.</summary>
        public ImCursorSnapshot CurrentCursors
        {
            get { return _snapshot.Clone(); }
        }

        /// <summary>
        /// True when the store held cursors for a different <c>(host, appId, userId)</c> and the SDK
        /// discarded them rather than replaying another account's position into this one
        /// (<c>sdk/CONTRACT.md</c> §5.3).
        /// </summary>
        /// <remarks>
        /// Worth surfacing on a diagnostics screen: it means this account re-downloads, and it means
        /// the store is shared across logins where it should be keyed per account with
        /// <see cref="ImCursorScope.StorageKey"/>.
        /// </remarks>
        public bool CursorScopeRejected
        {
            get { return _cursorScopeRejected; }
        }

        // ------------------------------------------------------------------ events

        /// <summary>Connection lifecycle, on the main thread. Drive your "connecting…" banner from it.</summary>
        public event Action<ImConnectionState> StateChanged;

        /// <summary>
        /// Every message, in <c>seq</c> order per conversation, with gaps already repaired.
        /// </summary>
        /// <remarks>
        /// Includes messages this device sent, once the server has assigned them a seq, so a single
        /// render path handles both. Subscribe before <see cref="ConnectAsync"/>. Store the message
        /// durably and then call <see cref="Commit"/>: delivery is at-least-once, so be idempotent
        /// on <see cref="ImMessage.MessageId"/>, and a message that is never committed is delivered
        /// again after the next reconnect.
        /// </remarks>
        public event Action<ImMessage> MessageReceived;

        /// <summary>
        /// The server closed this session deliberately. When <see cref="ImKick.IsTerminal"/> is set,
        /// the SDK has stopped and the player needs to be told — send them back to your login
        /// screen rather than leaving a spinner up forever.
        /// </summary>
        public event Action<ImKick> Kicked;

        /// <summary>
        /// A conversation fell further behind than <see cref="ImClientOptions.MaxAutoRepairSeq"/>
        /// and was skipped forward instead of backfilled.
        /// </summary>
        /// <remarks>
        /// The cursor is correct and new messages keep arriving normally, but the ones in between
        /// were never delivered. Reload the conversation from
        /// <see cref="ImMsgApi.HistoryAsync"/> — when the player opens it is soon enough. Raised on
        /// both paths that can skip a range: the resume run and a live message that jumped.
        /// </remarks>
        public event Action<string> ConversationNeedsReload;

        /// <summary>Former name of <see cref="ConversationNeedsReload"/>.</summary>
        [Obsolete("Renamed to ConversationNeedsReload to match sdk/CONTRACT.md §5.6. Removed in 2.0.")]
        public event Action<string> ConversationStale;

        /// <summary>
        /// The cursor store could not be read, so the SDK is running without one.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Raised once, on the first connect. This is deliberately not a silent log line: a failed
        /// load and a fresh install are indistinguishable to the adoption branch, and adopting on a
        /// failed load destroys history that is sitting intact in your own database. So the SDK
        /// adopts nothing and persists nothing for the rest of the session.
        /// </para>
        /// <para>
        /// The correct response is to re-derive cursors from your own store and hand them back with
        /// <see cref="Commit"/> — which is monotonic precisely so that this works. The alternative
        /// is to accept a re-download.
        /// </para>
        /// </remarks>
        public event Action<ImCursorStoreException> CursorStoreFailed;

        // ------------------------------------------------------------------ lifecycle

        /// <summary>
        /// Subscribes to a server push, decoded to its payload
        /// (<c>evt.typing</c>, <c>evt.read</c>, <c>evt.group</c>, …). Dispose to unsubscribe.
        /// </summary>
        /// <remarks>
        /// Do not subscribe to <see cref="ImPushTarget.Message"/> here: those frames arrive before
        /// gap repair, so a handler on them sees exactly the out-of-order jumps this SDK exists to
        /// hide. Use <see cref="MessageReceived"/>.
        /// </remarks>
        public IDisposable On(string target, Action<JsonValue> handler)
        {
            if (handler == null)
            {
                throw new ArgumentNullException("handler");
            }

            return _connection.On(target, delegate(ImFrame frame) { handler(frame.Data); });
        }

        /// <summary>Subscribes to a server push as a whole frame, for the id, status and traceId.</summary>
        public IDisposable OnFrame(string target, Action<ImFrame> handler)
        {
            return _connection.On(target, handler);
        }

        /// <summary>Opens the connection and completes once it is usable.</summary>
        public Task ConnectAsync(CancellationToken cancellationToken = default(CancellationToken))
        {
            return _connection.ConnectAsync(cancellationToken);
        }

        /// <summary>
        /// Closes the connection and stops reconnecting. Committed cursors are flushed first and
        /// kept, so connecting again resumes from where this device left off.
        /// </summary>
        /// <remarks>
        /// This deliberately does <b>not</b> unregister for offline push — a dead socket is exactly
        /// the state push exists to serve. Signing a user out is
        /// <see cref="LogoutAsync"/>.
        /// </remarks>
        public void Disconnect()
        {
            _dispatcher.Post(delegate { FlushCursorsNow(); });
            _connection.Close();
        }

        /// <summary>
        /// Signs the user out: unregisters this device for offline push, then closes the socket.
        /// </summary>
        /// <remarks>
        /// <para>
        /// The order is the whole point. After the socket closes there is no authenticated channel
        /// and the token cannot be removed at all, so a logout that disconnects first leaves the
        /// handset receiving the next user's notifications until the tenant backend cleans it up
        /// with <c>DELETE /v1/users/{userId}/push-tokens/{deviceId}</c>.
        /// </para>
        /// <para>
        /// A failed unregister does not stop the disconnect: a logout a network error can refuse is
        /// worse than a stale token. This does not clear the cursor store — cursors and your local
        /// messages share one lifetime, so clear both together or neither.
        /// </para>
        /// </remarks>
        public async Task LogoutAsync(CancellationToken cancellationToken = default(CancellationToken))
        {
            await Push.UnregisterQuietlyAsync(cancellationToken).ConfigureAwait(false);
            Disconnect();
        }

        /// <summary>Closes everything and releases the connection. Not reusable.</summary>
        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;

            ImMainThreadDispatcher.ApplicationSuspending -= HandleApplicationSuspending;

            // Before the connection goes: Close() posts through the dispatcher, and a flush queued
            // behind it would run against a client nobody is holding any more.
            FlushCursorsNow();

            _connection.StateChanged -= HandleStateChanged;
            _connection.Kicked -= HandleKicked;
            _messageSubscription.Dispose();
            _systemSubscription.Dispose();
            _connection.Dispose();

            MessageReceived = null;
            StateChanged = null;
            Kicked = null;
            ConversationNeedsReload = null;
#pragma warning disable 618
            ConversationStale = null;
#pragma warning restore 618
            CursorStoreFailed = null;
        }

        // ------------------------------------------------------------------ cursors

        /// <summary>
        /// Tells the SDK that everything up to <paramref name="seq"/> in this conversation is
        /// durably stored on this device.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Call it <i>after</i> the write to your own store has returned, not when the handler was
        /// entered. This is the number reported to the server on the next resume, and it is what
        /// decides whether a message that arrives while the app is closed is ever delivered.
        /// </para>
        /// <para>
        /// Monotonic: a lower seq is ignored rather than treated as an error, so re-deriving cursors
        /// from your own store on startup — the recovery path after
        /// <see cref="CursorStoreFailed"/> — is safe to do in any order.
        /// </para>
        /// <para>
        /// A game with no store of its own can call this straight from the message handler. That is
        /// honest — "durable" then means "as durable as this game gets" — and it still beats the SDK
        /// inferring it, because the choice is visible in your code rather than hidden in ours.
        /// </para>
        /// </remarks>
        public void Commit(string conversationId, long seq)
        {
            if (string.IsNullOrEmpty(conversationId) || seq <= 0)
            {
                return;
            }

            _dispatcher.Post(delegate { CommitInternal(conversationId, seq); });
        }

        /// <summary>
        /// Writes any pending commits through to the store now.
        /// </summary>
        /// <remarks>
        /// The SDK flushes before every resume, when Unity reports the app is being suspended, and
        /// on <see cref="Disconnect"/> and <see cref="Dispose"/>. Call it yourself from a save point
        /// of your own if you have one; it is cheap and does nothing when nothing has changed.
        /// </remarks>
        public void FlushCursors()
        {
            _dispatcher.Post(delegate { FlushCursorsNow(); });
        }

        /// <summary>
        /// Highest <c>seq</c> delivered to this process for a conversation, or 0. This is the value
        /// to pass to <see cref="ImConvApi.ReadAsync(string,long,CancellationToken)"/> when the
        /// player has read to the bottom.
        /// </summary>
        /// <remarks>
        /// Not the same as <see cref="CommittedSeqOf"/>, and not what gets reported to the server.
        /// After a reconnect this is reset back to the committed value, so anything delivered but
        /// never committed is delivered again.
        /// </remarks>
        public long DeliveredSeqOf(string conversationId)
        {
            if (string.IsNullOrEmpty(conversationId))
            {
                return 0;
            }

            lock (_inboxes)
            {
                Inbox inbox;
                return _inboxes.TryGetValue(conversationId, out inbox) ? Interlocked.Read(ref inbox.Delivered) : 0;
            }
        }

        /// <summary>Highest <c>seq</c> this conversation has been <see cref="Commit"/>ted to, or 0.</summary>
        public long CommittedSeqOf(string conversationId)
        {
            if (string.IsNullOrEmpty(conversationId))
            {
                return 0;
            }

            lock (_inboxes)
            {
                Inbox inbox;
                return _inboxes.TryGetValue(conversationId, out inbox) ? Interlocked.Read(ref inbox.Committed) : 0;
            }
        }

        /// <summary>Former name of <see cref="DeliveredSeqOf"/>.</summary>
        [Obsolete("Renamed to DeliveredSeqOf; the SDK now tracks a committed cursor as well. Removed in 2.0.")]
        public long CursorOf(string conversationId)
        {
            return DeliveredSeqOf(conversationId);
        }

        // ------------------------------------------------------- frozen legacy surface

        /// <summary>Sends a message. Prefer <see cref="ImMsgApi.SendAsync"/>.</summary>
        [Obsolete("Use im.Msg.SendAsync. Kept because it appears in every published sample; removed in 2.0.")]
        public Task<ImSendResult> SendAsync(
            ImSendRequest request,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return SendMessageAsync(request, cancellationToken);
        }

        /// <summary>
        /// Shorthand for a plain text message. Prefer
        /// <see cref="ImMsgApi.SendAsync(ImSendRequest,CancellationToken)"/>.
        /// </summary>
        /// <remarks>
        /// The replacement is <c>Msg.SendAsync</c> and not a namespaced <c>SendTextAsync</c>:
        /// <c>msg.sendText</c> is not an endpoint, so no such method exists on the typed surface in
        /// any of the five SDKs. This deprecation message used to name one, which taught the wrong
        /// shape every time somebody followed it.
        /// </remarks>
        [Obsolete("Use im.Msg.SendAsync(new ImSendRequest { … }). Kept because it appears in every published sample; removed in 2.0.")]
        public Task<ImSendResult> SendTextAsync(
            ImRecipient recipient,
            string text,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            if (text == null)
            {
                throw new ArgumentNullException("text");
            }

            return Msg.SendAsync(
                new ImSendRequest
                {
                    Recipient = recipient,
                    ContentType = ImMessageContentType.Text,
                    Content = Json.JsonValue.NewObject().Set("text", text),
                },
                cancellationToken);
        }

        /// <summary>Pages backwards through history. Prefer <see cref="ImMsgApi.HistoryAsync"/>.</summary>
        [Obsolete("Use im.Msg.HistoryAsync. Kept because it appears in every published sample; removed in 2.0.")]
        public Task<ImPage<ImMessage>> HistoryAsync(
            string conversationId,
            long beforeSeq = 0,
            int limit = 20,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return Msg.HistoryAsync(
                new ImHistoryRequest
                {
                    ConversationId = conversationId,
                    BeforeSeq = beforeSeq > 0 ? beforeSeq : (long?)null,
                    Limit = limit,
                },
                cancellationToken);
        }

        /// <summary>Recalls a message. Prefer <see cref="ImMsgApi.RecallAsync"/>.</summary>
        [Obsolete("Use im.Msg.RecallAsync. Kept because it appears in every published sample; removed in 2.0.")]
        public Task RecallAsync(
            string conversationId,
            long messageId,
            string reason = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return Msg.RecallAsync(
                new ImRecallMessageRequest
                {
                    ConversationId = conversationId,

                    // The request carries the id as a string, because the gateway reads it as a
                    // number written as one. This overload takes a long, so the conversion happens
                    // here — and it did not, which is why this assembly did not compile at all.
                    // 请求体里是字符串（网关按「写成字符串的数字」来读），而这个重载收的是 long：
                    // 换算要在这里做——它原本没有做，这也正是整个程序集根本编译不过的原因。
                    MessageId = messageId.ToString(CultureInfo.InvariantCulture),
                    Reason = reason,
                },
                cancellationToken);
        }

        /// <summary>Adds or removes a reaction. Prefer <see cref="ImMsgApi.ReactAsync"/>.</summary>
        [Obsolete("Use im.Msg.ReactAsync. Kept because it appears in every published sample; removed in 2.0.")]
        public Task ReactAsync(
            string conversationId,
            long messageId,
            string emoji,
            bool add = true,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return Msg.ReactAsync(
                new ImReactRequest
                {
                    ConversationId = conversationId,
                    MessageId = messageId.ToString(CultureInfo.InvariantCulture),
                    Emoji = emoji,
                    Add = add,
                },
                cancellationToken);
        }

        /// <summary>Reports typing. Prefer <see cref="ImMsgApi.TypingAsync"/>.</summary>
        [Obsolete("Use im.Msg.TypingAsync — the endpoint is msg.typing. Removed in 2.0.")]
        public Task SetTypingAsync(
            string conversationId,
            bool typing = true,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return Msg.TypingAsync(
                new ImTypingRequest { ConversationId = conversationId, Typing = typing },
                cancellationToken);
        }

        /// <summary>The conversation list. Prefer <see cref="ImConvApi.ListAsync"/>.</summary>
        [Obsolete("Use im.Conv.ListAsync — the endpoint is conv.list. Removed in 2.0.")]
        public Task<ImPage<ImConversationView>> ConversationsAsync(
            long updatedAfter = 0,
            string cursor = null,
            int limit = 50,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return Conv.ListAsync(
                new ImListConversationsRequest { UpdatedAfter = updatedAfter, Cursor = cursor, Limit = limit },
                cancellationToken);
        }

        /// <summary>Moves the read cursor. Prefer <see cref="ImConvApi.ReadAsync(string,long,CancellationToken)"/>.</summary>
        [Obsolete("Use im.Conv.ReadAsync — the endpoint is conv.read. Removed in 2.0.")]
        public Task MarkReadAsync(
            string conversationId,
            long readSeq,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return Conv.ReadAsync(conversationId, readSeq, cancellationToken);
        }

        /// <summary>Badge count. Prefer <see cref="ImConvApi.UnreadTotalAsync"/>, which returns a long.</summary>
        [Obsolete("Use im.Conv.UnreadTotalAsync — the endpoint is conv.unreadTotal. Removed in 2.0.")]
        public async Task<int> TotalUnreadAsync(CancellationToken cancellationToken = default(CancellationToken))
        {
            return (int)await Conv.UnreadTotalAsync(cancellationToken).ConfigureAwait(false);
        }

        // ------------------------------------------------------------------- invoke

        /// <summary>
        /// Escape hatch for any endpoint the typed surface does not cover yet.
        /// </summary>
        /// <remarks>
        /// It shares one code path with every typed method, so timeouts, cancellation and error
        /// mapping behave identically. It never touches a cursor: <c>InvokeAsync("msg.sync", …)</c>
        /// returns messages and moves nothing, because an escape hatch that quietly mutated sequence
        /// state would be unpredictable in exactly the situations it gets used in.
        /// </remarks>
        /// <example>
        /// <code>
        /// // group.transfer is tier 3 and not typed yet
        /// await im.InvokeAsync("group.transfer", JsonValue.NewObject()
        ///     .Set("groupId", groupId)
        ///     .Set("newOwnerId", userId));
        /// </code>
        /// </example>
        public Task<JsonValue> InvokeAsync(
            string target,
            JsonValue body = null,
            CancellationToken cancellationToken = default(CancellationToken))
        {
            return _connection.RequestAsync(target, body, cancellationToken);
        }

        /// <summary>Same, decoded to one of the SDK's payload types.</summary>
        /// <example>
        /// <code>
        /// var group = await im.InvokeAsync&lt;ImGroup&gt;("group.info",
        ///     JsonValue.NewObject().Set("groupId", groupId));
        /// </code>
        /// </example>
        public async Task<T> InvokeAsync<T>(
            string target,
            JsonValue body = null,
            CancellationToken cancellationToken = default(CancellationToken))
            where T : IImJsonPayload, new()
        {
            var data = await _connection.RequestAsync(target, body, cancellationToken).ConfigureAwait(false);
            return ImPayload.Read<T>(data);
        }

        /// <summary>Same, decoded to a list.</summary>
        public async Task<List<T>> InvokeListAsync<T>(
            string target,
            JsonValue body = null,
            CancellationToken cancellationToken = default(CancellationToken))
            where T : IImJsonPayload, new()
        {
            var data = await _connection.RequestAsync(target, body, cancellationToken).ConfigureAwait(false);
            return ImPayload.ReadList<T>(data);
        }

        /// <summary>Same, decoded to one page of a cursor-paginated list.</summary>
        public async Task<ImPage<T>> InvokePageAsync<T>(
            string target,
            JsonValue body = null,
            CancellationToken cancellationToken = default(CancellationToken))
            where T : IImJsonPayload, new()
        {
            var data = await _connection.RequestAsync(target, body, cancellationToken).ConfigureAwait(false);
            return ImPage<T>.FromJson(data, ImPayload.Read<T>);
        }

        // -------------------------------------------------------- internals: requests

        /// <summary>The one request path every typed method and <c>InvokeAsync</c> shares.</summary>
        internal Task<JsonValue> SendRequestAsync(
            string target,
            JsonValue body,
            CancellationToken cancellationToken)
        {
            return _connection.RequestAsync(target, body, cancellationToken);
        }

        /// <summary>Backs <see cref="ImMsgApi.SendAsync"/>, including the cursor bookkeeping.</summary>
        internal async Task<ImSendResult> SendMessageAsync(
            ImSendRequest request,
            CancellationToken cancellationToken)
        {
            if (request == null)
            {
                throw new ArgumentNullException("request");
            }

            if (request.Recipient.IsEmpty)
            {
                throw new ArgumentException(
                    "ImSendRequest.Recipient is required; build one with ImRecipient.User/Group/Conversation.",
                    "request");
            }

            var clientMsgId = !string.IsNullOrEmpty(request.ClientMsgId)
                ? request.ClientMsgId
                : NewClientMsgId();

            var body = request.ToJson(clientMsgId, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            var data = await _connection.RequestAsync("msg.send", body, cancellationToken).ConfigureAwait(false);
            var result = ImSendResult.FromJson(data);

            // Our own message advances the delivered cursor, through the inbox rather than by
            // writing it here: if the server placed our send beyond the seq we had, something
            // arrived while we were sending and that hole is real. Adopting the number quietly
            // would hide it until the next reconnect. It does not advance the committed cursor —
            // the game has not stored the message yet, and this is not the place to guess.
            if (!string.IsNullOrEmpty(result.ConversationId) && result.Seq > 0)
            {
                Enqueue(result.ConversationId, InboxCommand.Reconcile(result.Seq));
            }

            return result;
        }

        /// <summary>
        /// Time prefix plus randomness: sortable in a log, and unique enough that two devices of the
        /// same user sending in the same millisecond cannot collide on the idempotency key.
        /// </summary>
        internal string NewClientMsgId()
        {
            var stamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString("x", CultureInfo.InvariantCulture);

            byte[] noise = new byte[6];
            lock (_random)
            {
                _random.NextBytes(noise);
            }

            var text = new StringBuilder(stamp.Length + 13);
            text.Append(stamp).Append('-');
            for (int i = 0; i < noise.Length; i++)
            {
                text.Append(noise[i].ToString("x2", CultureInfo.InvariantCulture));
            }

            return text.ToString();
        }

        // --------------------------------------------------------- internals: cursors

        private ImCursorSnapshot LoadSnapshot()
        {
            try
            {
                var loaded = _store.Load();
                if (loaded == null)
                {
                    return new ImCursorSnapshot();
                }

                // The account-switch guarantee, sdk/CONTRACT.md §5.3. The snapshot carries the
                // identity the SDK stamped on it, so a store that does nothing to keep two accounts
                // apart still cannot hand one player the other's position. The worst a shared store
                // can do is cost the earlier account a re-download — loud, logged and recoverable;
                // inherited cursors are silent, permanent, and look exactly like a working client.
                // 快照自带身份：即使存储没有按账号隔离，也不会把上一个账号的游标交给下一个账号。
                if (!string.IsNullOrEmpty(loaded.Scope) &&
                    !string.Equals(loaded.Scope, _scope.Key, StringComparison.Ordinal))
                {
                    _cursorScopeRejected = true;
                    ImLog.Warn(
                        "the cursor store holds cursors for '" + loaded.Scope + "' but this session " +
                        "is '" + _scope.Key + "'; starting clean rather than replaying another " +
                        "account's position. Key the store per account with " +
                        "ImCursorScope.StorageKey. See sdk/CONTRACT.md §5.3.");
                    return new ImCursorSnapshot();
                }

                return loaded;
            }
            catch (Exception error)
            {
                // Not a fresh install. A fresh install has nothing stored; this has something the
                // store could not read, and treating the two the same is how adoption destroys
                // history that is sitting intact in the game's own database.
                _cursorsUsable = false;
                _loadFailure = new ImCursorStoreException(_scope, error);
                ImLog.Error(_loadFailure.Message, error);
                return new ImCursorSnapshot();
            }
        }

        private void SeedInboxes(ImCursorSnapshot snapshot)
        {
            foreach (var entry in snapshot.ConvSeqs)
            {
                var inbox = InboxFor(entry.Key);
                inbox.Delivered = entry.Value;
                inbox.Committed = entry.Value;
                inbox.HighWater = entry.Value;
            }
        }

        private void CommitInternal(string conversationId, long seq)
        {
            var inbox = InboxFor(conversationId);

            if (seq <= Interlocked.Read(ref inbox.Committed))
            {
                // Monotonic: a lower seq is ignored rather than an error, so an app re-deriving
                // cursors from its own store can call this in any order.
                return;
            }

            Interlocked.Exchange(ref inbox.Committed, seq);

            // Invariant 1 from §5.2: committed never exceeds delivered. An app re-deriving cursors
            // legitimately runs ahead of what this process has delivered, and pulling delivered up
            // to match is what stops the next live message looking like a gap back to zero.
            if (seq > Interlocked.Read(ref inbox.Delivered))
            {
                Interlocked.Exchange(ref inbox.Delivered, seq);
            }

            if (seq > inbox.HighWater)
            {
                inbox.HighWater = seq;
            }

            _snapshot.ConvSeqs[conversationId] = seq;
            MarkCursorsDirty();
        }

        /// <summary>
        /// Records an adoption and writes it through immediately.
        /// </summary>
        /// <remarks>
        /// The synchronous write is not an optimisation choice, it is the correctness one. If an
        /// adoption write is lost, the next cold start sees no entry for the conversation, adopts a
        /// <i>newer</i> <c>maxSeq</c>, and silently drops everything in between — the original bug,
        /// re-created by the debounce that was meant to be harmless. Ordinary commits may be
        /// coalesced because losing one costs a duplicate delivery; losing this one costs data.
        /// </remarks>
        private void AdoptFirstSight(string conversationId, long maxSeq)
        {
            if (!_cursorsUsable)
            {
                return;
            }

            var inbox = InboxFor(conversationId);
            Interlocked.Exchange(ref inbox.Delivered, maxSeq);
            Interlocked.Exchange(ref inbox.Committed, maxSeq);
            if (maxSeq > inbox.HighWater)
            {
                inbox.HighWater = maxSeq;
            }

            _snapshot.ConvSeqs[conversationId] = maxSeq;
            _snapshotDirty = true;
            FlushCursorsNow();
        }

        private void MarkCursorsDirty()
        {
            if (!_cursorsUsable)
            {
                return;
            }

            _snapshotDirty = true;

            if (_flushInterval <= TimeSpan.Zero)
            {
                FlushCursorsNow();
                return;
            }

            if (_flushTimer != null)
            {
                return;
            }

            _flushTimer = _dispatcher.Schedule(_flushInterval, delegate
            {
                _flushTimer = null;
                FlushCursorsNow();
            });
        }

        private void FlushCursorsNow()
        {
            if (_flushTimer != null)
            {
                _flushTimer.Dispose();
                _flushTimer = null;
            }

            if (!_snapshotDirty || !_cursorsUsable)
            {
                return;
            }

            _snapshotDirty = false;

            try
            {
                // Stamped on every write. This is what the next launch — or the next account on
                // this device — reads to decide whether these cursors are theirs.
                _snapshot.Scope = _scope.Key;
                _store.Save(_snapshot);
            }
            catch (Exception error)
            {
                // Losing a write costs duplicate delivery on the next start, which is recoverable;
                // the session keeps running. Turning it off would not be, so this does not clear
                // _cursorsUsable — the next flush may well succeed.
                _snapshotDirty = true;
                ImLog.Warn("could not persist cursors for " + _scope, error);
            }
        }

        private Dictionary<string, long> CommittedMap()
        {
            var map = new Dictionary<string, long>(_snapshot.ConvSeqs.Count, StringComparer.Ordinal);
            foreach (var entry in _snapshot.ConvSeqs)
            {
                if (entry.Value > 0)
                {
                    map[entry.Key] = entry.Value;
                }
            }

            return map;
        }

        private void HandleApplicationSuspending()
        {
            // Straight through rather than posted: Unity is about to stop calling Update, so a
            // dispatcher post here may never run. Everything this touches is main-thread state and
            // OnApplicationPause is a main-thread callback.
            FlushCursorsNow();
        }

        // -------------------------------------------------------- internals: delivery

        private void HandleStateChanged(ImConnectionState state)
        {
            ImSafeEvent.Raise(StateChanged, state);

            if (!_loadFailureReported && _loadFailure != null)
            {
                // Surfaced here rather than from the constructor, where nobody has subscribed yet.
                // A connection-state moment is also the honest place for it: this is a session-wide
                // degradation, not a one-call failure.
                _loadFailureReported = true;
                ImSafeEvent.Raise(CursorStoreFailed, _loadFailure);
            }

            if (state == ImConnectionState.Open)
            {
                // Fire and forget: resume is best-effort by design, and every failure inside it is
                // handled there. Blocking the state callback on a network round trip would stall
                // the frame this runs on.
                var ignored = ResumeAsync();

                // §6.2 rule 1: re-register the push token on every connect, because the vendor may
                // have replaced it while the process was frozen and the server has no other way to
                // find out. An unchanged token costs no write; the server debounces it.
                Push.RegisterOnConnect();

                // Least urgent of the post-connect work: a device that cannot answer a log request
                // is still a device that can chat, and nothing here may delay gap repair.
                // 连接后最不紧急的一件：答不出日志请求的设备仍然是能聊天的设备。
                var alsoIgnored = _deviceLogs.CheckAsync();
            }
        }

        private void HandleKicked(ImKick kick)
        {
            ImSafeEvent.Raise(Kicked, kick);
        }

        /// <summary>
        /// Routes an <c>evt.system</c> frame to the device-log runner, and ignores everything else.
        /// </summary>
        /// <remarks>
        /// Fire and forget for the same reason the resume is: this runs on the frame the socket
        /// delivered on, and blocking it on an upload would stall the game.
        /// 与 resume 同理不等待：它跑在 socket 投递的那一帧上，卡在上传上会拖住游戏。
        /// </remarks>
        private void HandleSystemFrame(ImFrame frame)
        {
            var ignored = _deviceLogs.OnSystemEventAsync(frame.Data);
        }

        private void HandleMessageFrame(ImFrame frame)
        {
            var data = frame.Data;
            if (!data.IsObject)
            {
                return;
            }

            var message = ImMessage.FromJson(data);
            if (string.IsNullOrEmpty(message.ConversationId))
            {
                ImLog.Warn("dropped a message with no conversationId");
                return;
            }

            Enqueue(message.ConversationId, InboxCommand.Arrived(message));
        }

        private void Enqueue(string conversationId, InboxCommand command)
        {
            var inbox = InboxFor(conversationId);

            inbox.Commands.Enqueue(command);
            if (inbox.Draining)
            {
                // A repair is in flight for this conversation. Whatever just arrived waits behind
                // it, which is the whole point: delivering it now is the out-of-order jump.
                return;
            }

            var ignored = DrainAsync(conversationId, inbox);
        }

        private Inbox InboxFor(string conversationId)
        {
            lock (_inboxes)
            {
                Inbox inbox;
                if (!_inboxes.TryGetValue(conversationId, out inbox))
                {
                    inbox = new Inbox();
                    _inboxes[conversationId] = inbox;
                }

                return inbox;
            }
        }

        private async Task DrainAsync(string conversationId, Inbox inbox)
        {
            inbox.Draining = true;
            try
            {
                while (inbox.Commands.Count > 0)
                {
                    var command = inbox.Commands.Dequeue();
                    try
                    {
                        await ApplyAsync(conversationId, inbox, command).ConfigureAwait(false);
                    }
                    catch (Exception error)
                    {
                        // One malformed message must not take this conversation's queue down with
                        // it; the next arrival re-detects any gap it left behind.
                        ImLog.Warn("inbox command failed for " + conversationId, error);
                    }
                }
            }
            finally
            {
                inbox.Draining = false;
            }
        }

        private Task ApplyAsync(string conversationId, Inbox inbox, InboxCommand command)
        {
            switch (command.Kind)
            {
                case InboxCommandKind.Arrived:
                    return DeliverAsync(conversationId, inbox, command.Message);
                case InboxCommandKind.Repair:
                    return RepairAsync(conversationId, inbox, command.FromSeq, command.ToSeq);
                default:
                    return ReconcileAsync(conversationId, inbox, command.FromSeq);
            }
        }

        private async Task DeliverAsync(string conversationId, Inbox inbox, ImMessage message)
        {
            var known = Interlocked.Read(ref inbox.Delivered);

            // seq 0 means the message was never persisted (typing, presence, best-effort chat room
            // traffic): deliver it straight through and never let it move a cursor.
            if (message.Seq == 0)
            {
                Emit(message);
                return;
            }

            // Already seen. Duplicates are routine after a reconnect replay and must be silent.
            if (message.Seq <= known)
            {
                return;
            }

            if (known > 0 && message.Seq > known + 1)
            {
                // A gap. Repair it before delivering this message, so the game never sees a
                // conversation jump forward and then fill in behind it.
                await RepairAsync(conversationId, inbox, known + 1, message.Seq - 1).ConfigureAwait(false);
            }

            if (message.Seq > Interlocked.Read(ref inbox.Delivered))
            {
                Deliver(inbox, message);
            }
        }

        /// <summary>
        /// Fetches the inclusive range <c>[fromSeq, toSeq]</c> and delivers it in order, paging for
        /// as long as the server says there is more.
        /// </summary>
        /// <remarks>
        /// <para>
        /// Paging is mandatory, not an optimisation. The server clamps <c>msg.sync</c> to 500
        /// messages, so a 900-seq range asked for in one call silently returns 500 and a client that
        /// ignores <c>hasMore</c> leaves the other 400 as a permanent hole — the exact failure the
        /// repair was for.
        /// </para>
        /// <para>
        /// The loop ends on <c>hasMore</c> and never on the message count.
        /// <c>hasMore</c> is computed on the raw window before messages hidden from this user are
        /// filtered out, so a page can come back short — even empty — with more still to come.
        /// </para>
        /// <para>
        /// Both entry points share this: a gap noticed on a live message and a gap the server
        /// reported on resume behave identically, including raising
        /// <see cref="ConversationNeedsReload"/> when the span is too large. A hole nobody is told
        /// about is the same defect as a hole nobody repairs.
        /// </para>
        /// </remarks>
        private async Task RepairAsync(string conversationId, Inbox inbox, long fromSeq, long toSeq)
        {
            var span = toSeq - fromSeq + 1;
            if (span <= 0)
            {
                return;
            }

            if (span > _maxAutoRepair)
            {
                // Too far behind to backfill message by message. Accept the jump, keep the cursor
                // honest, and tell the game which conversation to reload from history.
                SkipForward(
                    conversationId,
                    inbox,
                    toSeq,
                    span.ToString(CultureInfo.InvariantCulture) + " messages behind");
                return;
            }

            var cursor = fromSeq;

            for (int page = 0; page < _maxRepairPages; page++)
            {
                if (cursor > toSeq)
                {
                    return;
                }

                var limit = (int)Math.Min(toSeq - cursor + 1, ServerSyncPageLimit);
                var request = new ImSyncMessagesRequest
                {
                    ConversationId = conversationId,
                    FromSeq = cursor,
                    ToSeq = toSeq,
                    Limit = limit,
                    Ascending = true,
                };

                JsonValue data;
                try
                {
                    data = await _connection.RequestAsync("msg.sync", request.ToJson()).ConfigureAwait(false);
                }
                catch (Exception error)
                {
                    // The repair failed — the socket died mid-sync, or the server refused. Return
                    // without moving the cursor: the caller then delivers what arrived, because a
                    // chat that stops updating while one msg.sync keeps failing is worse than a
                    // chat with a hole in it. That hole is real and stays until the app reloads the
                    // conversation from history, which is why this is the one path here that logs.
                    ImLog.Warn("gap repair failed for " + conversationId + " [" +
                               cursor.ToString(CultureInfo.InvariantCulture) + ".." +
                               toSeq.ToString(CultureInfo.InvariantCulture) + "]", error);
                    return;
                }

                var result = ImSyncResult.FromJson(data);
                var messages = result.Messages;

                // Ascending was requested, but the ordering guarantee that matters is the one
                // enforced here: delivering a backfill out of order would recreate the very jump
                // the repair was for.
                messages.Sort(CompareBySeq);

                long highest = 0;
                for (int i = 0; i < messages.Count; i++)
                {
                    var message = messages[i];
                    if (message.Seq > highest)
                    {
                        highest = message.Seq;
                    }

                    if (message.Seq > Interlocked.Read(ref inbox.Delivered))
                    {
                        Deliver(inbox, message);
                    }
                }

                if (!result.HasMore)
                {
                    return;
                }

                // Advance past what came back. When the page was empty — every row in the window
                // hidden from this user — there is no highest seq to go from, and the contract's
                // "or r.maxSeq" would jump to the end of the conversation and abandon the rest of
                // the range. seq is gap-free, so the window covered `limit` seqs from `cursor`, and
                // stepping by the limit is both safe and guaranteed to make progress.
                var next = highest > 0 ? highest + 1 : cursor + limit;
                cursor = next > cursor ? next : cursor + 1;
            }

            // The loop cap is a guard against a server that reports hasMore forever; hitting it is
            // a real hole, so it gets the same treatment an oversized gap does rather than being
            // swallowed.
            SkipForward(
                conversationId,
                inbox,
                toSeq,
                "repair did not finish within " + _maxRepairPages.ToString(CultureInfo.InvariantCulture) + " pages");
        }

        /// <summary>
        /// Moves both cursors to <paramref name="toSeq"/> and tells the game the range in between
        /// was skipped.
        /// </summary>
        /// <remarks>
        /// Both halves are mandatory. Skipping the cursor advance makes every later message look
        /// like a gap and re-request a range that has already been declined; skipping the event
        /// leaves a hole in the UI that nothing will ever mention.
        /// </remarks>
        private void SkipForward(string conversationId, Inbox inbox, long toSeq, string reason)
        {
            ImLog.Info("skipping " + conversationId + " forward to seq " +
                       toSeq.ToString(CultureInfo.InvariantCulture) + " (" + reason + ")");

            if (toSeq > Interlocked.Read(ref inbox.Delivered))
            {
                Interlocked.Exchange(ref inbox.Delivered, toSeq);
            }

            if (toSeq > inbox.HighWater)
            {
                inbox.HighWater = toSeq;
            }

            // The SDK commits here itself, which it otherwise never does, because there is nothing
            // for the game to store: these messages were never delivered and never will be.
            CommitInternal(conversationId, toSeq);

            RaiseNeedsReload(conversationId);
        }

        /// <summary>
        /// Moves the delivered cursor to a seq learned from something other than a delivered message
        /// — this device's own send — repairing anything skipped on the way.
        /// </summary>
        private async Task ReconcileAsync(string conversationId, Inbox inbox, long seq)
        {
            var known = Interlocked.Read(ref inbox.Delivered);
            if (seq <= known)
            {
                return;
            }

            if (known > 0 && seq > known + 1)
            {
                await RepairAsync(conversationId, inbox, known + 1, seq - 1).ConfigureAwait(false);
            }

            if (seq > Interlocked.Read(ref inbox.Delivered))
            {
                Interlocked.Exchange(ref inbox.Delivered, seq);
            }

            if (seq > inbox.HighWater)
            {
                inbox.HighWater = seq;
            }
        }

        // ---------------------------------------------------------- internals: resume

        /// <summary>
        /// Runs after every (re)connect: asks the server what changed while we were away, adopts
        /// conversations this device has never seen, and repairs the rest.
        /// </summary>
        /// <remarks>
        /// <para>
        /// The server does the diffing. A device that has been offline for a week cannot usefully
        /// work out what it missed by pulling the whole conversation list and comparing, and a
        /// client that replays everything on every reconnect is a client that costs its tenant money
        /// every time a train goes through a tunnel.
        /// </para>
        /// <para>
        /// Two things here are easy to get wrong and are both silent when you do. <b>The run pages.</b>
        /// <c>conn.sync</c> returns at most 200 conversations at a time, and a user with more than
        /// that gets gaps reported only for the first page unless the client keeps asking.
        /// <b>The conversation cursor moves only when the run finishes.</b> The list is sorted by
        /// <c>updatedAt</c> descending, so page one holds the newest timestamp; a client that takes
        /// the maximum from page one and stops has pushed its cursor past every conversation on
        /// pages two onward, and the server filters on <c>updatedAt &gt; cursor</c> and will never
        /// return them again. Re-reading a page is free. Skipping one is permanent.
        /// </para>
        /// </remarks>
        private async Task ResumeAsync()
        {
            var generation = Interlocked.Increment(ref _resumeGeneration);

            try
            {
                // Everything committed since the last flush has to be on the wire in convSeqs, and
                // in the store, before the server is asked what we are missing.
                FlushCursorsNow();

                // §5.2 invariant 2. Without this the redelivered messages are dropped as duplicates
                // by the very cursor that was too far ahead, and the repair achieves nothing.
                ResetDeliveredToCommitted();

                string cursor = null;
                var runMaxUpdatedAt = _snapshot.ConversationCursor;
                var completed = false;

                for (int page = 0; page < MaxResumePages; page++)
                {
                    var request = new ImResumeRequest
                    {
                        ConvSeqs = CommittedMap(),
                        ConversationCursor = _snapshot.ConversationCursor,
                        Cursor = cursor,
                        Limit = ImConnection.ResumePageSize,
                    };

                    var data = await _connection.RequestAsync("conn.sync", request.ToJson()).ConfigureAwait(false);

                    if (generation != Volatile.Read(ref _resumeGeneration))
                    {
                        // A newer connect superseded this run. Its cursor is the one that counts,
                        // and finishing this one would advance the conversation cursor on behalf of
                        // pages a dead socket read.
                        return;
                    }

                    var result = ImResumeResult.FromJson(data);
                    ApplyResumePage(result, ref runMaxUpdatedAt);

                    if (!result.HasMore)
                    {
                        completed = true;
                        break;
                    }

                    if (string.IsNullOrEmpty(result.NextCursor))
                    {
                        // hasMore with no cursor is a server bug; stopping here without advancing
                        // the conversation cursor costs a re-read next time, which is the cheap
                        // half of the two ways to be wrong.
                        ImLog.Warn("conn.sync reported hasMore with no nextCursor; stopping the resume run");
                        break;
                    }

                    cursor = result.NextCursor;
                }

                if (completed && runMaxUpdatedAt > _snapshot.ConversationCursor)
                {
                    _snapshot.ConversationCursor = runMaxUpdatedAt;
                    MarkCursorsDirty();
                }
            }
            catch (Exception error)
            {
                // Resume is best-effort. A failure here leaves every cursor untouched — including
                // the conversation cursor, which must not move for an interrupted run — so the next
                // arriving message detects its gap and repairs it the normal way.
                ImLog.Warn("resume after reconnect failed", error);
            }
        }

        /// <summary>Conversations pages one resume run may read before giving up.</summary>
        private const int MaxResumePages = 200;

        private void ApplyResumePage(ImResumeResult result, ref long runMaxUpdatedAt)
        {
            var maxSeqById = new Dictionary<string, long>(StringComparer.Ordinal);
            var planned = new Dictionary<string, long>(StringComparer.Ordinal);

            for (int i = 0; i < result.Conversations.Count; i++)
            {
                var view = result.Conversations[i];
                if (string.IsNullOrEmpty(view.ConversationId))
                {
                    continue;
                }

                maxSeqById[view.ConversationId] = view.MaxSeq;

                if (view.UpdatedAt > runMaxUpdatedAt)
                {
                    runMaxUpdatedAt = view.UpdatedAt;
                }

                if (IsFirstSight(view.ConversationId))
                {
                    // Never seen here, so there is no history to replay into a UI that has never
                    // shown it. Adopt the server's position — and write it through synchronously,
                    // before the next page is asked for.
                    AdoptFirstSight(view.ConversationId, view.MaxSeq);
                    continue;
                }

                // Known to us. The server only reports a gap when it was told a non-zero position,
                // so a conversation we have delivered but never committed produces no gapsFrom
                // entry at all — computing the range from our own committed cursor covers that case
                // as well as the one the server does report, and the two agree everywhere they
                // overlap.
                var from = CommittedSeqOf(view.ConversationId) + 1;
                if (view.MaxSeq >= from)
                {
                    planned[view.ConversationId] = from;
                }
            }

            foreach (var gap in result.GapsFrom)
            {
                if (!planned.ContainsKey(gap.Key) && maxSeqById.ContainsKey(gap.Key))
                {
                    planned[gap.Key] = gap.Value;
                }
            }

            foreach (var repair in planned)
            {
                long toSeq;
                if (!maxSeqById.TryGetValue(repair.Key, out toSeq))
                {
                    continue;
                }

                if (toSeq - repair.Value + 1 <= 0)
                {
                    continue;
                }

                Enqueue(repair.Key, InboxCommand.Repair(repair.Value, toSeq));
            }
        }

        /// <summary>
        /// True when neither the restored snapshot nor this process has ever held a position for
        /// this conversation.
        /// </summary>
        /// <remarks>
        /// The in-process half matters: a conversation delivered live on this socket but never
        /// committed has no snapshot entry, and treating it as first sight on the next reconnect
        /// would adopt the server's newest seq and drop everything the game had not stored yet.
        /// </remarks>
        private bool IsFirstSight(string conversationId)
        {
            if (_snapshot.ConvSeqs.ContainsKey(conversationId))
            {
                return false;
            }

            lock (_inboxes)
            {
                Inbox inbox;
                return !_inboxes.TryGetValue(conversationId, out inbox) || inbox.HighWater <= 0;
            }
        }

        private void ResetDeliveredToCommitted()
        {
            lock (_inboxes)
            {
                foreach (var entry in _inboxes)
                {
                    var inbox = entry.Value;
                    Interlocked.Exchange(ref inbox.Delivered, Interlocked.Read(ref inbox.Committed));
                }
            }
        }

        // ----------------------------------------------------------- internals: plumbing

        private static int CompareBySeq(ImMessage left, ImMessage right)
        {
            return left.Seq.CompareTo(right.Seq);
        }

        private void Deliver(Inbox inbox, ImMessage message)
        {
            Interlocked.Exchange(ref inbox.Delivered, message.Seq);
            if (message.Seq > inbox.HighWater)
            {
                inbox.HighWater = message.Seq;
            }

            Emit(message);
        }

        private void Emit(ImMessage message)
        {
            ImSafeEvent.Raise(MessageReceived, message);
        }

        private void RaiseNeedsReload(string conversationId)
        {
            ImSafeEvent.Raise(ConversationNeedsReload, conversationId);
#pragma warning disable 618
            ImSafeEvent.Raise(ConversationStale, conversationId);
#pragma warning restore 618
        }

        private enum InboxCommandKind
        {
            Arrived = 0,
            Repair = 1,
            Reconcile = 2,
        }

        private sealed class InboxCommand
        {
            internal InboxCommandKind Kind;
            internal ImMessage Message;
            internal long FromSeq;
            internal long ToSeq;

            internal static InboxCommand Arrived(ImMessage message)
            {
                return new InboxCommand { Kind = InboxCommandKind.Arrived, Message = message };
            }

            internal static InboxCommand Repair(long fromSeq, long toSeq)
            {
                return new InboxCommand { Kind = InboxCommandKind.Repair, FromSeq = fromSeq, ToSeq = toSeq };
            }

            internal static InboxCommand Reconcile(long seq)
            {
                return new InboxCommand { Kind = InboxCommandKind.Reconcile, FromSeq = seq };
            }
        }

        /// <summary>
        /// One conversation's delivery state: how far it has been delivered, how far it has been
        /// committed, and what is waiting.
        /// </summary>
        private sealed class Inbox
        {
            /// <summary>
            /// Highest seq handed to the game in this process. Fields rather than properties
            /// because <c>Interlocked.Read</c> needs one — a 64-bit read is not atomic on a 32-bit
            /// player, and the accessors are callable from any thread.
            /// </summary>
            internal long Delivered;

            /// <summary>Highest seq the game has said it stored. Mirrored into the cursor store.</summary>
            internal long Committed;

            /// <summary>
            /// Highest seq ever seen for this conversation in this process, and never reset by the
            /// delivered-to-committed rewind. It is what tells "we have never heard of this
            /// conversation" — where adoption is correct — apart from "we have heard of it and have
            /// not stored it yet", where adoption would be data loss.
            /// </summary>
            internal long HighWater;

            internal readonly Queue<InboxCommand> Commands = new Queue<InboxCommand>();

            /// <summary>True while a command for this conversation is awaiting the network.</summary>
            internal bool Draining;
        }
    }
}
