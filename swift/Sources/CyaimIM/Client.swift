import Foundation

/// The client applications actually use.
///
/// Beyond wrapping commands, this owns the two things every correct IM client must do and most
/// hand-rolled ones do not:
///
/// - **Ordering and gap repair.** It tracks the highest `seq` handed to the application per
///   conversation, notices when an arriving message skips a number, and pulls the missing range
///   with `msg.sync` *before* delivering. WebSocket delivery is at-most-once and unordered across a
///   reconnect; contiguous `seq` plus this repair loop is what turns that into a correct, ordered
///   conversation.
/// - **Cold start.** It keeps a second, durable cursor — what *you* have told it you stored — and
///   reports that one to the server, so a relaunch asks for what it missed instead of adopting the
///   server's newest `seq` and losing everything that arrived while the app was closed. See
///   ``commit(_:seq:)`` and ``ImCursorStore``; the rules are `sdk/CONTRACT.md` §5.
///
/// Everything the app observes comes out of an `AsyncStream`, and everything it calls is
/// `async`/`await`. There are no callbacks and no delegate to retain, so there is no thread to be
/// careful about and nothing to weakly capture:
///
/// ```swift
/// let im = ImClient(options: .init(
///     endpoint: URL(string: "wss://im.example.com")!,
///     appId: "your-app-id",
///     token: await backend.imToken(),
///     deviceId: KeychainDeviceId.current,
///     userId: me.id,
///     cursorStore: try .applicationSupport(scope: .init(
///         endpoint: URL(string: "wss://im.example.com")!, appId: "your-app-id", userId: me.id
///     )),
///     tokenProvider: { await backend.imToken() }
/// ))
///
/// Task {
///     for await message in im.messages() {
///         try await store.append(message)          // durable
///         await im.commit(message.conversationId, seq: message.seq)
///     }
/// }
/// Task { for await state in im.states() { await banner.show(state) } }
///
/// try await im.connect()
/// _ = try await im.sendText("hello", to: .user("bob"))
/// ```
///
/// Delivery is **at-least-once**: a message you were handed but never committed comes back after a
/// reconnect. Be idempotent on `messageId`.
///
/// 客户端必须做、而多数自研客户端没做的两件事：按会话记录已见的最大 seq 以补洞，
/// 以及单独维护一份"应用已落库"的持久游标——冷启动上报的是后者，否则关闭期间的消息会被静默跳过。
public actor ImClient {

    /// The transport underneath. Public because an endpoint the typed surface has not caught up
    /// with is a normal situation, not a defect — see ``invoke(_:body:as:)``.
    public nonisolated let connection: ImConnection

    private let options: ImClientOptions

    /// The SDK's own runtime log: written here, read when the server asks this device for it.
    ///
    /// Exposed so an application can add its own lines — the ones that explain what the *user* was
    /// doing when it went wrong, which the SDK cannot see and which are usually the half that makes
    /// a log worth reading.
    /// 公开出来是为了让应用写自己的行：SDK 看不见用户当时在做什么，而那往往是让日志值得读的那一半。
    public let log: ImLogRecorder

    private let deviceLogs: ImDeviceLogs

    /// The application's warning sink, for the namespaces that need to report a swallowed failure.
    ///
    /// `options` is private and stays private — it carries credentials. This exposes the one member
    /// a namespace has any business reaching, so `im.push.clicked` can tell the app that a tap went
    /// uncounted through the same channel as every other warning instead of writing to stderr,
    /// which on iOS is a place nobody reads.
    /// options 保持私有（里面有凭据），这里只放开命名空间真正需要的那一个成员：
    /// 让「有一次点击没记上」经由与其余告警相同的通道抵达应用，而不是写进 iOS 上没人看的 stderr。
    /// `nonisolated` because it reads an immutable `let` on a `Sendable` type: there is no actor
    /// state to protect, and hopping onto the actor to fetch a closure would make a namespace await
    /// the client's mailbox just to file a warning — behind whatever send or sync is queued ahead of
    /// it. 读的是 Sendable 类型上的不可变 let，没有需要保护的 actor 状态；
    /// 为了取一个闭包而跳上 actor，等于让命名空间排在队列里那些发送/同步后面，只为记一条告警。
    nonisolated var warningSink: (@Sendable (String) -> Void)? { options.warningHandler }

    // MARK: Cursors

    /// Highest `seq` handed to the application in **this process**, per conversation.
    ///
    /// In memory only. Used for gap detection and duplicate suppression, and reset to
    /// ``committed`` on every connect so that redelivery actually reaches the application instead
    /// of being dropped as duplicate by the very cursor that was too far ahead.
    private var delivered: [String: Int64] = [:]

    /// Highest `seq` the application has told us it has **durably stored**, per conversation.
    ///
    /// Written through to ``ImCursorStore``. This is the value reported in `convSeqs`, and the
    /// distinction from ``delivered`` is the whole of §5.2 — a callback returning means the message
    /// reached the app's memory, which is exactly the state a crash loses.
    private var committed: [String: Int64] = [:]

    /// Largest `ConversationView.updatedAt` from a completed `conn.sync` run.
    private var conversationCursor: Int64 = 0

    private var cursorsLoaded = false

    /// Set when the store handed back another account's cursors and they were discarded (§5.3).
    private var foreignScopeRejected = false

    /// False after ``ImCursorStore/load()`` threw. No adoption, no cursor advance, for the whole
    /// session — see §5.8 and ``ImSessionEvent/cursorStoreUnavailable(_:)``.
    private var cursorsUsable = true

    private var saveIsPending = false
    private var flushTask: Task<Void, Never>?
    private var warnedAboutVolatileStore = false

    // MARK: Push

    private var pushToken: CachedPushToken?
    private var pushEverRegistered = false
    private var warnedAboutUnregisteredPush = false

    /// The (socket, token) pair the last successful `push.register` covered.
    ///
    /// Registration is required on every connect and on every token change — and on exactly those.
    /// Without this pair the two triggers race after a connect: the state pump is a step behind the
    /// `connect()` that woke the caller, so an app that sets its token immediately afterwards
    /// registers once itself and once more when the pump catches up.
    private var pushRegisteredFor: PushRegistrationMark?

    private struct PushRegistrationMark: Sendable, Hashable {
        var session: UInt64
        var token: String
    }

    private struct CachedPushToken: Sendable, Hashable {
        var provider: String
        var token: String
        var language: String?
    }

    // MARK: Plumbing

    private nonisolated let messageHub = Broadcaster<ImMessage>()
    private nonisolated let sessionHub = Broadcaster<ImSessionEvent>()

    /// One serial lane for everything that touches a cursor.
    ///
    /// Pushes arrive on one task and reconnects trigger a resume on another, and both repair gaps.
    /// Being an actor keeps that memory-safe but not *correct*: two repairs interleaving at their
    /// `await` points can deliver seq 8 before seq 7. Funnelling both through one queue with one
    /// consumer means the ordering guarantee this class exists for holds by construction rather
    /// than by review — and it is also what satisfies §5.10's "do not run two repairs for one
    /// conversation concurrently", without a per-conversation lock.
    private nonisolated let work: AsyncStream<Work>
    private nonisolated let workContinuation: AsyncStream<Work>.Continuation

    private var pumps: [Task<Void, Never>] = []
    private var isStarted = false

    private enum Work: Sendable {
        case incoming(ImMessage)
        case resume
        case sent(conversationId: String, seq: Int64)
    }

    // MARK: - Init

    public init(options: ImClientOptions) {
        self.connection = ImConnection(options: options)
        self.options = options

        let lane = ImClient.makeWorkLane()
        self.work = lane.stream
        self.workContinuation = lane.continuation

        let recorder = ImLogRecorder(store: options.logStore, warningHandler: options.warningHandler)
        self.log = recorder
        self.deviceLogs = ImDeviceLogs(connection: connection, log: recorder, deviceId: options.deviceId)
    }

    /// Builds a client around an already-configured connection. Useful in tests and in apps that
    /// want to hold the transport themselves. The cursor store and the repair limits come from the
    /// options the connection was built with.
    public init(connection: ImConnection) {
        self.connection = connection
        self.options = connection.options

        let lane = ImClient.makeWorkLane()
        self.work = lane.stream
        self.workContinuation = lane.continuation

        let recorder = ImLogRecorder(store: connection.options.logStore, warningHandler: connection.options.warningHandler)
        self.log = recorder
        self.deviceLogs = ImDeviceLogs(connection: connection, log: recorder, deviceId: connection.options.deviceId)
    }

    /// The stream is unbounded because dropping work is never the right answer here: a discarded
    /// `.incoming` is a message the user never sees, and a discarded `.resume` is a conversation
    /// that stays behind until the next reconnect.
    private static func makeWorkLane() -> (stream: AsyncStream<Work>, continuation: AsyncStream<Work>.Continuation) {
        var continuation: AsyncStream<Work>.Continuation? = nil
        let stream = AsyncStream<Work>(bufferingPolicy: .unbounded) { continuation = $0 }

        // The build closure above runs synchronously, so this is never nil.
        return (stream, continuation!)
    }

    // MARK: - Namespaces

    /// `conn.*` — session lifecycle.
    public nonisolated var conn: ImConnNamespace { ImConnNamespace(connection: connection) }

    /// `msg.*` — send, sync, history, recall, reactions.
    public nonisolated var msg: ImMsgNamespace { ImMsgNamespace(connection: connection, client: self) }

    /// `conv.*` — the conversation list and its per-user state.
    public nonisolated var conv: ImConvNamespace { ImConvNamespace(connection: connection) }

    /// `user.*` — profiles and presence.
    public nonisolated var user: ImUserNamespace { ImUserNamespace(connection: connection) }

    /// `media.*` — upload tickets and signed download links.
    public nonisolated var media: ImMediaNamespace { ImMediaNamespace(connection: connection) }

    /// `push.*` — offline push registration. See ``ImPushNamespace/setToken(provider:token:language:)``.
    public nonisolated var push: ImPushNamespace { ImPushNamespace(connection: connection, client: self) }

    /// `friend.*` — contacts, requests and the blocklist.
    public nonisolated var friend: ImFriendNamespace { ImFriendNamespace(connection: connection) }

    /// `group.*` — group lifecycle and membership.
    public nonisolated var group: ImGroupNamespace { ImGroupNamespace(connection: connection) }

    /// `moderation.*` — reporting a user or a message. The other half of ``friend``'s blocklist.
    public nonisolated var moderation: ImModerationNamespace { ImModerationNamespace(connection: connection) }

    /// `diag.*` — this device's half of troubleshooting.
    ///
    /// **Ordinary applications never call these.** The client drives both: it asks once after every
    /// connect and answers whatever is waiting. They are typed because this SDK's rule is that every
    /// endpoint has a typed method — a capability reachable only through ``invoke(_:body:as:)`` is
    /// one a support engineer cannot find. See `ADR-003` for why the log store belongs to you.
    /// 一般应用不会调用它们：客户端自己驱动。类型化是因为「每个端点都有类型化方法」是本 SDK 的规矩。
    public nonisolated var diag: ImDiagNamespace { ImDiagNamespace(connection: connection) }

    // MARK: - Streams

    /// Every message, in `seq` order per conversation, gaps already repaired.
    ///
    /// Each call returns an independent stream, so a conversation view and a badge counter can each
    /// have one. The buffer is unbounded because dropping is not an option: the entire point of the
    /// repair loop is that the application sees every `seq`.
    ///
    /// Call ``commit(_:seq:)`` once the message is durably in your own store. Until you do, the
    /// message is delivered again after a reconnect — which is the correct trade, and why you must
    /// be idempotent on `messageId`.
    public nonisolated func messages() -> AsyncStream<ImMessage> {
        messageHub.subscribe()
    }

    /// Everything the SDK needs to tell you that is neither a message nor a connection state:
    /// a conversation it declined to backfill, a cursor store it could not read, a push token it is
    /// holding but has never registered.
    ///
    /// Consume this. Every case in ``ImSessionEvent`` exists because the alternative is a hole
    /// nobody is told about.
    public nonisolated func sessionEvents() -> AsyncStream<ImSessionEvent> {
        sessionHub.subscribe()
    }

    /// Connection lifecycle, starting with the current value.
    public nonisolated func states() -> AsyncStream<ConnectionState> {
        connection.states()
    }

    /// Kicks — including the one the SDK synthesises from a close reason when the gateway dies
    /// before its `conn.kick` push lands.
    ///
    /// Consume this. "Signed in on another device" is a sentence only the app can say, and this is
    /// the only place it is said.
    public nonisolated func kicks() -> AsyncStream<KickEvent> {
        events(.kick, as: KickEvent.self)
    }

    /// Any other server event, decoded.
    ///
    /// ```swift
    /// for await typing in im.events(.typing, as: TypingEvent.self) { … }
    /// ```
    ///
    /// A payload that does not decode is skipped rather than ending the stream: a gateway that adds
    /// a field must not be able to stop an app that has not been rebuilt for it.
    public nonisolated func events<Payload: Decodable & Sendable>(
        _ target: PushTarget,
        as type: Payload.Type
    ) -> AsyncStream<Payload> {
        let frames = connection.events(for: target)

        return AsyncStream(Payload.self, bufferingPolicy: .unbounded) { continuation in
            let pump = Task {
                for await frame in frames {
                    if let payload: Payload = frame.decodedData() {
                        continuation.yield(payload)
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    /// Raw frames for a target, for payloads the SDK does not model.
    public nonisolated func frames(for target: PushTarget) -> AsyncStream<ImFrame> {
        connection.events(for: target)
    }

    // MARK: - Lifecycle

    /// Connects, and returns once the socket is usable.
    ///
    /// Cursors are loaded from ``ImClientOptions/cursorStore`` before the socket opens, and
    /// subscriptions are wired up before it too, so neither the first `conn.sync` nor the gateway's
    /// post-connect burst can land before the client knows what this device already holds.
    public func connect() async throws {
        await loadCursorsIfNeeded()
        start()
        try await connection.connect()
    }

    /// Closes for good. Ends every stream, fails every in-flight request, stops reconnecting.
    ///
    /// **This does not unregister for push, and must not** — a dead socket is precisely the state
    /// offline push exists to serve. Logging out is ``logout()``, which unregisters first.
    ///
    /// Not optional: a live client's pump tasks hold it, so a client that is dropped without this
    /// call keeps reconnecting for the lifetime of the process. On iOS you do **not** need it when
    /// the app goes to the background — see ``enterForeground()`` and ``enterBackground()``.
    public func disconnect() async {
        for pump in pumps { pump.cancel() }
        pumps.removeAll()
        isStarted = false

        flushTask?.cancel()
        flushTask = nil
        await flushCursors()

        workContinuation.finish()
        await connection.close()
        messageHub.finish()
        sessionHub.finish()
    }

    /// Signs this device out: `push.unregister` **first**, then ``disconnect()``.
    ///
    /// The order is the whole point. After the socket closes the SDK has no authenticated channel
    /// and cannot remove the token at all, and a token left registered means the user keeps getting
    /// notifications for an account they signed out of. If the client dies without getting here —
    /// force-quit, crash, uninstall — only the tenant backend can clean up, with
    /// `DELETE /v1/users/{userId}/push-tokens/{deviceId}`.
    ///
    /// Best effort by design: an unregister that fails must not stop a logout.
    ///
    /// 顺序即全部意义：socket 一关就再也没有可鉴权的通道去摘掉 token。
    public func logout() async {
        try? await connection.execute("push.unregister")
        pushToken = nil
        pushEverRegistered = false
        pushRegisteredFor = nil
        await disconnect()
    }

    /// The one call to make when the app returns to the foreground.
    ///
    /// iOS suspends the process, and a suspended process has no socket: the OS tears it down within
    /// seconds or minutes, keeps delivering pushes on your behalf, and hands the app back a
    /// connection object that may look fine and carry nothing. This skips whatever backoff is being
    /// waited out, and probes a nominally-open socket immediately instead of waiting up to a
    /// heartbeat interval to find out it is dead. Everything the client missed is then repaired by
    /// the resume that follows the reconnect.
    ///
    /// ```swift
    /// .onChange(of: scenePhase) { _, phase in
    ///     switch phase {
    ///     case .active: Task { await im.enterForeground() }
    ///     case .background: Task { await im.enterBackground() }
    ///     default: break
    ///     }
    /// }
    /// ```
    public nonisolated func enterForeground() async {
        await connection.enterForeground()
    }

    /// ``enterForeground()`` for a synchronous context, such as
    /// `applicationWillEnterForeground(_:)`. Fire and forget.
    public nonisolated func enterForegroundNow() {
        Task { await self.enterForeground() }
    }

    /// Flushes pending cursor commits. Call it on the platform's suspend signal.
    ///
    /// The socket does not need closing when you background — doing that only makes the next
    /// foreground slower — but a debounced commit that has not reached the store yet does need
    /// writing, because the process may not be resumed.
    public func enterBackground() async {
        await flushCursors()
    }

    // MARK: - Cursors

    /// Tells the SDK that everything up to `seq` in this conversation is **durably stored** by the
    /// application.
    ///
    /// This is the value reported to the server on the next connect, so calling it is what makes a
    /// cold start ask for the right range. Monotonic: a lower `seq` is ignored, not an error, which
    /// is what lets an application re-derive cursors from its own database and hand them back in
    /// any order after a store failure.
    ///
    /// Call it **after** your write commits, never from inside the delivery callback before the
    /// write. A callback returning means the message reached memory; inferring durability from that
    /// is how you get a cursor that is confidently wrong.
    ///
    /// 落库之后再调用。回调返回只代表消息进了内存，而进程崩溃丢的正是这部分。
    public func commit(_ conversationId: String, seq: Int64) {
        guard seq > (committed[conversationId] ?? 0) else { return }

        committed[conversationId] = seq

        // The invariant is committed <= delivered. An application re-deriving cursors from its own
        // store may legitimately commit past what this process has delivered.
        if seq > (delivered[conversationId] ?? 0) {
            delivered[conversationId] = seq
        }

        scheduleSave()
    }

    /// Commits several conversations at once, for an application that batches its writes.
    public func commit(_ cursors: [String: Int64]) {
        for (conversationId, seq) in cursors {
            commit(conversationId, seq: seq)
        }
    }

    /// Highest `seq` handed to the application for a conversation in this process, or 0.
    public func highestSeq(in conversationId: String) -> Int64 {
        delivered[conversationId] ?? 0
    }

    /// Highest `seq` the application has committed for a conversation, or 0. This is what
    /// `conn.sync` reports.
    public func committedSeq(in conversationId: String) -> Int64 {
        committed[conversationId] ?? 0
    }

    /// The snapshot as it stands right now — what would be written if the store were flushed,
    /// stamped with whose cursors these are.
    public func cursorSnapshot() -> ImCursorSnapshot {
        ImCursorSnapshot(
            convSeqs: committed,
            conversationCursor: conversationCursor,
            scope: options.cursorScope.key
        )
    }

    /// True when the store held cursors for a different `(host, appId, userId)` and the SDK
    /// discarded them rather than replaying another account's position into this one (§5.3).
    ///
    /// Worth surfacing: it means this account re-downloads, and it means the store is shared across
    /// logins where it should be keyed per account with ``ImCursorScope/storageKey``.
    public var didRejectForeignCursors: Bool { foreignScopeRejected }

    /// True when the SDK is refusing to move cursors because ``ImCursorStore/load()`` failed.
    ///
    /// While this is false the SDK adopts nothing, advances nothing on its own, and writes nothing
    /// back to the store — it will not overwrite a file that may still be recoverable. Your own
    /// ``commit(_:seq:)`` still works and still drives `convSeqs`, which is the intended recovery:
    /// re-derive the cursors from your message store, commit them, then call ``resync()``.
    public var isCursorStoreUsable: Bool { cursorsUsable }

    /// Runs a `conn.sync` pass again, right now.
    ///
    /// Queued behind whatever is already on the delivery lane, so it cannot reorder messages. The
    /// case it exists for is recovery after ``ImSessionEvent/cursorStoreUnavailable(_:)``: the
    /// application re-derives its cursors, commits them, and asks for the repair that the failed
    /// load made impossible the first time.
    public func resync() {
        workContinuation.yield(.resume)
    }

    /// Seeds cursors held somewhere other than the ``ImCursorStore``.
    ///
    /// Predates ``ImCursorStore`` and stays for apps that keep cursors in their own database — it
    /// is the same thing ``commit(_:)`` does, plus the conversation cursor. Both values are
    /// merged with whatever the store loaded, taking the larger, so calling it before or after
    /// ``connect()`` gives the same answer.
    ///
    /// > Deprecated for 2.0. Prefer an ``ImCursorStore`` and ``commit(_:seq:)``: a store is loaded
    /// > by the SDK at the right moment, whereas a `seed` that the integrator forgets to call is
    /// > indistinguishable from a fresh install, which is the failure mode this whole area exists
    /// > to prevent.
    public func seed(_ cursors: [String: Int64], conversationCursor: Int64 = 0) {
        for (conversationId, seq) in cursors {
            if seq > (committed[conversationId] ?? 0) { committed[conversationId] = seq }
            if seq > (delivered[conversationId] ?? 0) { delivered[conversationId] = seq }
        }

        self.conversationCursor = max(self.conversationCursor, conversationCursor)
    }

    private func loadCursorsIfNeeded() async {
        guard !cursorsLoaded else { return }
        cursorsLoaded = true

        // Not asked of the store: only the SDK's own in-memory store is volatile, because a store
        // that could declare itself volatile could also switch this warning off.
        if options.cursorStore.isVolatile, !warnedAboutVolatileStore {
            warnedAboutVolatileStore = true
            ImLog.warn(
                "cursors are not being persisted (ImCursorStore.inMemory()). Every message that "
                    + "arrives while this process is not running will be skipped on the next launch. "
                    + "See sdk/CONTRACT.md §5.3.",
                using: options.warningHandler
            )
            sessionHub.yield(.cursorsNotPersisted)
        }

        do {
            let snapshot = try await options.cursorStore.load()

            // The account-switch guarantee, §5.3. The snapshot carries the identity the SDK
            // stamped on it, so a store that does nothing to keep two accounts apart still cannot
            // hand one user the other's position. The worst a shared store can do is cost the
            // earlier account a re-download — loud, logged and recoverable; inherited cursors are
            // silent, permanent, and look exactly like a working client.
            // 快照自带身份：即使存储没有按账号隔离，也不会把上一个账号的游标交给下一个账号。
            let mine = options.cursorScope.key
            if let stamped = snapshot.scope, stamped != mine {
                foreignScopeRejected = true
                ImLog.warn(
                    "the cursor store holds cursors for '\(stamped)' but this session is "
                        + "'\(mine)'; starting clean rather than replaying another account's "
                        + "position. Key the store per account with ImCursorScope.storageKey. "
                        + "See sdk/CONTRACT.md §5.3.",
                    using: options.warningHandler
                )
                return
            }

            // Merged rather than assigned, so an app that also calls `seed(_:)` — or that commits
            // before the first connect — cannot have its value silently replaced by an older one.
            //
            // An entry of 0 is merged too, and that is not a formality: "this conversation is known
            // and we hold nothing of it" is a different statement from "we have never heard of this
            // conversation", and only the second one may adopt.
            for (conversationId, seq) in snapshot.convSeqs {
                guard let existing = committed[conversationId] else {
                    committed[conversationId] = seq
                    continue
                }
                if seq > existing { committed[conversationId] = seq }
            }
            for (conversationId, seq) in committed where seq > (delivered[conversationId] ?? 0) {
                delivered[conversationId] = seq
            }
            conversationCursor = max(conversationCursor, snapshot.conversationCursor)
        } catch {
            // A failed load and a fresh install look identical to the adoption branch, and adopting
            // on a failed load destroys history sitting intact in the application's own database.
            // So: surface it, adopt nothing, advance nothing, for the rest of the session.
            cursorsUsable = false

            let failure = (error as? ImError) ?? ImError(
                code: .internalError,
                message: "cursor store load failed: \(error)"
            )

            ImLog.warn(
                "could not load cursors (\(failure.message)). No cursor will be adopted or advanced "
                    + "this session; re-derive them from your own store with commit(_:seq:). "
                    + "See sdk/CONTRACT.md §5.8.",
                using: options.warningHandler
            )
            sessionHub.yield(.cursorStoreUnavailable(failure))
        }
    }

    /// Coalesces ordinary commits. Adoption never comes through here — see ``flushCursors()``.
    ///
    /// The asymmetry is deliberate: **a lost debounced commit costs one duplicate delivery; a lost
    /// adoption write costs silent permanent data loss.** That is why one is allowed to be lossy
    /// and the other is not.
    private func scheduleSave() {
        saveIsPending = true
        guard flushTask == nil else { return }

        let interval = options.cursorFlushInterval

        flushTask = Task { [weak self] in
            if interval > .zero {
                do { try await Task.sleep(for: interval) } catch { return }
            }
            await self?.flushIfPending()
        }
    }

    private func flushIfPending() async {
        flushTask = nil
        guard saveIsPending else { return }
        await flushCursors()
    }

    /// Writes the snapshot now. Called before every `conn.sync`, after every adoption, on
    /// ``enterBackground()`` and on ``disconnect()``.
    private func flushCursors() async {
        guard cursorsUsable, saveIsPending else { return }
        saveIsPending = false

        do {
            try await options.cursorStore.save(cursorSnapshot())
        } catch {
            // Worth one line and nothing more: a save that failed costs redelivery of whatever was
            // in it, which the application is already required to tolerate.
            ImLog.warn("could not save cursors: \(error)", using: options.warningHandler)
        }
    }

    // MARK: - Push registration

    /// Hands the SDK this device's push token, and registers it.
    ///
    /// Call it from `didRegisterForRemoteNotificationsWithDeviceToken` and again whenever the
    /// vendor replaces the token. The SDK re-sends it on **every** connect after that, because a
    /// vendor may replace a token while the process is frozen and the server has no other way to
    /// learn it; re-registering an unchanged token costs no write server-side.
    ///
    /// ```swift
    /// func application(_ app: UIApplication,
    ///                  didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    ///     Task { await im.push.setToken(deviceToken: token) }
    /// }
    /// ```
    @available(*, deprecated, message: "Use im.push.setToken(deviceToken:) — the token-cache pair is setToken/clearToken on the push namespace in all five SDKs. Removed in 2.0.")
    public func setPushToken(deviceToken: Data, provider: String = ImPushProvider.apns, language: String? = nil) async {
        await setPushTokenInternal(
            provider: provider,
            token: deviceToken.map { String(format: "%02x", $0) }.joined(),
            language: language
        )
    }

    /// ``setPushToken(deviceToken:provider:language:)`` for a token you already have as a string —
    /// an FCM token on a Catalyst build, say.
    @available(*, deprecated, message: "Use im.push.setToken(provider:token:language:). Removed in 2.0.")
    public func setPushToken(provider: String = ImPushProvider.apns, token: String, language: String? = nil) async {
        await setPushTokenInternal(provider: provider, token: token, language: language)
    }

    /// What ``ImPushNamespace/setToken(provider:token:language:)`` and the deprecated aliases both
    /// run. Kept off the public surface so there is one spelling of this in the SDK's API.
    func setPushTokenInternal(provider: String, token: String, language: String?) async {
        let replacement = CachedPushToken(provider: provider, token: token, language: language)
        guard replacement != pushToken else { return }

        pushToken = replacement
        pushEverRegistered = false

        // Immediately if connected; otherwise the cache is enough — the next connect sends it.
        // Never queued: registration is a normal request and obeys the not-connected rule.
        if await connection.currentState == .open {
            await registerPushIfNeeded()
        }
    }

    /// Forgets the cached token without unregistering it. For an app that is turning notifications
    /// off locally; ``logout()`` is what removes the registration server-side.
    @available(*, deprecated, message: "Use im.push.clearToken(). Removed in 2.0.")
    public func clearPushToken() {
        clearPushTokenInternal()
    }

    /// What ``ImPushNamespace/clearToken()`` and the deprecated alias both run.
    func clearPushTokenInternal() {
        pushToken = nil
        pushEverRegistered = false
        pushRegisteredFor = nil
    }

    /// True once a `push.register` has succeeded on this client.
    public var isPushRegistered: Bool { pushEverRegistered }

    private func registerPushIfNeeded() async {
        guard let cached = pushToken else { return }
        guard await connection.currentState == .open else { return }

        let mark = PushRegistrationMark(session: await connection.sessionGeneration, token: cached.token)
        guard mark != pushRegisteredFor else { return }

        // Claimed before the round trip, not after: the two triggers can both be in flight, and a
        // check that only records success lets both of them through.
        pushRegisteredFor = mark

        do {
            try await connection.execute("push.register", body: RegisterPushTokenRequest(
                provider: cached.provider,
                token: cached.token,
                language: cached.language ?? options.language
            ))

            pushEverRegistered = true
        } catch {
            // The claim is released so the next connect tries again rather than assuming this
            // device is registered when it is not.
            pushRegisteredFor = nil

            let failure = error as? ImError

            // One warning, once. A device holding a token it never registered is indistinguishable
            // from a broken push provider, and that misdiagnosis costs a support cycle every time.
            if !warnedAboutUnregisteredPush {
                warnedAboutUnregisteredPush = true
                ImLog.warn(
                    "push.register failed (\(failure?.description ?? "\(error)")). This device holds "
                        + "a \(cached.provider) token that is not registered, so it will receive no "
                        + "offline notifications. See sdk/CONTRACT.md §6.",
                    using: options.warningHandler
                )
            }

            sessionHub.yield(.pushTokenNotRegistered(provider: cached.provider, lastError: failure))
        }
    }

    // MARK: - Messaging

    /// Sends a message and returns the server's receipt.
    ///
    /// Holding the returned ``SendMessageResult`` means the message is persisted: `seq` is only
    /// issued after the write. If this throws ``ImError`` with ``ImError/isRetryable``, send the
    /// *same* ``MessageDraft`` again — its `clientMsgId` is what makes the retry idempotent, and a
    /// duplicate comes back as the original result with `deduplicated == true` rather than as a
    /// second message.
    ///
    /// > Deprecated for 2.0. Prefer `im.msg.send(_:)`.
    @discardableResult
    public func send(_ draft: MessageDraft) async throws -> SendMessageResult {
        try await msg.send(draft.request)
    }

    /// Text shorthand for the overwhelmingly common case.
    ///
    /// > Deprecated for 2.0. Prefer `im.msg.send(.text(_:to:))`.
    @discardableResult
    public func sendText(_ text: String, to target: MessageTarget) async throws -> SendMessageResult {
        try await send(.text(text, to: target))
    }

    /// Pages backwards through history.
    ///
    /// - Parameter beforeSeq: exclusive upper bound; `nil` starts at the newest message.
    ///
    /// > Deprecated for 2.0. Prefer `im.msg.history(_:)`.
    public func history(
        of conversationId: String,
        before beforeSeq: Int64? = nil,
        limit: Int = 20
    ) async throws -> Page<ImMessage> {
        try await msg.history(HistoryRequest(conversationId: conversationId, beforeSeq: beforeSeq, limit: limit))
    }

    /// Pulls an explicit range. Moves no cursor — this is the raw endpoint, and the gap-repair loop
    /// has its own path through it.
    ///
    /// > Deprecated for 2.0. Prefer `im.msg.sync(_:)`, which also reports `hasMore`.
    public func sync(
        _ conversationId: String,
        from fromSeq: Int64,
        to toSeq: Int64,
        ascending: Bool = true
    ) async throws -> [ImMessage] {
        let span = max(toSeq - fromSeq + 1, 1)

        return try await msg.sync(SyncMessagesRequest(
            conversationId: conversationId,
            fromSeq: fromSeq,
            toSeq: toSeq,
            limit: Int(min(span, 500)),
            ascending: ascending
        )).messages
    }

    /// Recalls a message. The recall is itself an event: peers get `evt.messageUpdate`, not a
    /// deletion, so a UI can replace the bubble in place instead of leaving a hole in the list.
    ///
    /// > Deprecated for 2.0. Prefer `im.msg.recall(_:)`.
    public func recall(_ messageId: Int64, in conversationId: String, reason: String? = nil) async throws {
        try await msg.recall(RecallMessageRequest(
            conversationId: conversationId,
            messageId: messageId,
            reason: reason
        ))
    }

    /// Adds or removes an emoji reaction.
    ///
    /// > Deprecated for 2.0. Prefer `im.msg.react(_:)`.
    public func react(
        _ emoji: String,
        to messageId: Int64,
        in conversationId: String,
        add: Bool = true
    ) async throws {
        try await msg.react(ReactRequest(
            conversationId: conversationId,
            messageId: messageId,
            emoji: emoji,
            add: add
        ))
    }

    /// Reports typing state. Online-only and never persisted, so a failure here is not worth
    /// showing anyone — but it still throws, because swallowing it would hide a dead socket.
    ///
    /// > Deprecated for 2.0. Prefer `im.msg.typing(_:)`, whose name matches the endpoint.
    public func setTyping(_ typing: Bool = true, in conversationId: String) async throws {
        try await msg.typing(TypingRequest(conversationId: conversationId, typing: typing))
    }

    // MARK: - Conversations

    /// The conversation list, incrementally.
    ///
    /// - Parameter updatedAfter: the largest `updatedAt` you have already seen. Pass `0` for the
    ///   first page and the remembered value afterwards; the server then sends only what moved,
    ///   which on a cold launch is the difference between one round trip and forty.
    ///
    /// > Deprecated for 2.0. Prefer `im.conv.list(_:)`.
    public func conversations(
        updatedAfter: Int64 = 0,
        cursor: String? = nil,
        limit: Int = 50
    ) async throws -> Page<ConversationView> {
        try await conv.list(ListConversationsRequest(updatedAfter: updatedAfter, cursor: cursor, limit: limit))
    }

    /// Moves the read cursor.
    ///
    /// Unread counts are derived server-side from `maxSeq - readSeq`, so this is not a counter that
    /// can drift: read on one device and every other device's badge clears too. Unrelated to
    /// ``commit(_:seq:)``, which is about durability rather than about what the user has read.
    ///
    /// > Deprecated for 2.0. Prefer `im.conv.read(_:readSeq:)`.
    public func markRead(_ conversationId: String, upTo readSeq: Int64) async throws {
        try await conv.read(conversationId, readSeq: readSeq)
    }

    /// The badge number.
    ///
    /// > Deprecated for 2.0. Prefer `im.conv.unreadTotal()`, which returns the wire's `Int64`.
    public func totalUnread() async throws -> Int {
        Int(try await conv.unreadTotal())
    }

    // MARK: - Escape hatch

    /// Calls any endpoint in the catalogue, typed by the caller.
    ///
    /// The catalogue is larger than the typed surface above and grows faster than SDK releases do,
    /// so this is a supported route rather than a workaround — it is how you ship on Friday against
    /// an endpoint the next SDK release will type:
    ///
    /// ```swift
    /// // msg.cancelScheduled is tier 4 and not yet typed here.
    /// try await im.invoke("msg.cancelScheduled", body: [
    ///     "scheduleId": .string(scheduleId),
    /// ] as [String: JSONValue], as: EmptyBody.self)
    /// ```
    ///
    /// `EmptyBody` is the answer type for an endpoint that acknowledges without a payload, which is
    /// most write endpoints. Give each body field the JSON type the server's request DTO declares —
    /// the gateway binds field by field without converting, so a mismatch is refused with `1000`.
    /// The `msg.*` endpoints declare message ids as `string`: `.string(String(messageId))`.
    ///
    /// It shares one code path with every typed method, so timeouts, cancellation and error mapping
    /// behave identically. It never participates in cursor logic: `invoke("msg.sync", …)` returns
    /// messages and moves nothing.
    public func invoke<Response: Decodable & Sendable>(
        _ target: String,
        body: some Encodable & Sendable,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await connection.request(target, body: body, as: type)
    }

    /// ``invoke(_:body:as:)`` for an endpoint that takes no arguments.
    public func invoke<Response: Decodable & Sendable>(
        _ target: String,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await connection.request(target, as: type)
    }

    // MARK: - Pumps

    private func start() {
        guard !isStarted else { return }
        isStarted = true

        // Subscriptions are taken here, before the socket opens, because an unsubscribed push is
        // dropped rather than buffered.
        let incoming = connection.events(for: .message)
        let states = connection.states()

        // A log request arrives inside evt.system rather than on a target of its own, so a client
        // built before this feature existed receives an action it does not recognise and ignores
        // it. A new target would instead be silently dropped by every existing build, and there
        // would be no way to tell that apart from a device that was offline (ADR-003).
        // 走 evt.system 里的一个 action 而不是新事件名：旧版本收到不认识的 action 会忽略它，那是对的。
        let system = connection.events(for: .system)

        pumps.append(Task { [deviceLogs] in
            for await frame in system {
                await deviceLogs.onSystemEvent(frame.body?.data)
            }
        })

        pumps.append(Task { [workContinuation] in
            await ImClient.pumpMessages(incoming, into: workContinuation)
        })

        pumps.append(Task { [workContinuation] in
            await ImClient.pumpStates(states, into: workContinuation, notifying: self)
        })

        pumps.append(Task { [work] in
            await ImClient.pumpWork(work, into: self)
        })
    }

    /// The serial lane's only consumer.
    ///
    /// It holds the client for as long as it runs, which is why ``disconnect()`` is not optional:
    /// the task and the actor keep each other alive exactly like a strong delegate cycle, and
    /// nothing else will break it.
    private static func pumpWork(_ work: AsyncStream<Work>, into client: ImClient) async {
        for await item in work {
            switch item {
            case .incoming(let message):
                await client.deliver(message)
            case .resume:
                await client.resume()
            case .sent(let conversationId, let seq):
                await client.recordSent(conversationId, seq: seq)
            }
        }
    }

    /// Decodes pushes and queues them. `static`, so the loop runs on the cooperative pool instead
    /// of occupying the actor for every frame — and so a slow repair cannot block decoding.
    private static func pumpMessages(
        _ frames: AsyncStream<ImFrame>,
        into work: AsyncStream<Work>.Continuation
    ) async {
        for await frame in frames {
            guard let message: ImMessage = frame.decodedData() else { continue }
            work.yield(.incoming(message))
        }
    }

    /// Every transition into `open` — the first connect and every reconnect after it — schedules a
    /// resume behind whatever messages are already queued, and re-registers the push token.
    ///
    /// Push registration deliberately does *not* go on the work lane: it touches no cursor, and
    /// putting a round trip in front of the resume would delay every missed message by it.
    private static func pumpStates(
        _ states: AsyncStream<ConnectionState>,
        into work: AsyncStream<Work>.Continuation,
        notifying client: ImClient
    ) async {
        for await state in states where state == .open {
            work.yield(.resume)
            await client.socketDidOpen()
        }
    }

    private func socketDidOpen() {
        // Least urgent of the post-connect work and deliberately unconditional: unlike push
        // registration there is no token to guard on, and a device with nothing waiting gets one
        // cheap round trip that returns an empty list.
        // 连接后最不紧急的一件，且无条件执行：没有 token 之类的前提，
        // 没有待办的设备只是多一次返回空列表的往返。
        Task { [deviceLogs] in
            await deviceLogs.check()
        }

        guard pushToken != nil else { return }

        Task { [weak self] in
            await self?.registerPushIfNeeded()
        }
    }

    // MARK: - Ordering and gap repair

    /// Decides what to do with one arriving message. Runs on the serial work lane, so the `await`
    /// inside a repair cannot let a later message overtake an earlier one.
    private func deliver(_ message: ImMessage) async {
        // seq 0 means the message was never persisted — a chat-room broadcast, an online-only tip.
        // Deliver it straight through and never let it move a cursor.
        if message.seq == 0 {
            emit(message)
            return
        }

        let known = delivered[message.conversationId] ?? 0

        // Already seen. Duplicates are routine after a reconnect replay and must be silent.
        if message.seq <= known {
            return
        }

        if known > 0, message.seq > known + 1 {
            // A gap. Repair it *before* delivering this message, so the application never sees a
            // conversation jump forward and then fill in behind it.
            await repair(message.conversationId, from: known + 1, to: message.seq - 1)
        } else if known == 0, cursorsUsable, committed[message.conversationId] == nil {
            // First sight of a conversation on the live path.
            //
            // Adopt at `seq - 1`: we take responsibility for everything before this message —
            // there is no UI showing it, and replaying a stranger's whole history into a
            // conversation the user has never opened helps nobody — but *not* for the message
            // itself, which the application still has to commit.
            //
            // Recording an entry at all is the point. Without one, the next cold start sees no
            // entry for this conversation, adopts whatever `maxSeq` has become by then, and
            // silently drops everything in between. That is the original bug, arriving by a
            // different door.
            let floor = max(message.seq - 1, 0)
            committed[message.conversationId] = floor
            delivered[message.conversationId] = floor
            saveIsPending = true
            await flushCursors()
        }

        delivered[message.conversationId] = max(delivered[message.conversationId] ?? 0, message.seq)
        emit(message)
    }

    /// Records a seq this device produced, so the server's echo is not mistaken for a gap.
    ///
    /// Goes through the work lane rather than being written inline by ``send(_:)``, so it cannot
    /// interleave with a repair at an `await` point and make the repaired messages look like
    /// duplicates.
    private func recordSent(_ conversationId: String, seq: Int64) async {
        guard seq > 0 else { return }

        if cursorsUsable, committed[conversationId] == nil {
            // Same reasoning as first sight on the live path: an entry has to exist, and this
            // message is not committed until the application says so.
            committed[conversationId] = max(seq - 1, 0)
            saveIsPending = true
            await flushCursors()
        }

        if seq > (delivered[conversationId] ?? 0) {
            delivered[conversationId] = seq
        }
    }

    /// Pulls `[fromSeq, toSeq]` and delivers it in order, paging until the server says it is done.
    ///
    /// Both the live-gap path and the resume path come through here, which is what makes them
    /// behave identically — including declining an oversized span and telling the application about
    /// it. `MessageService.SyncAsync` clamps `limit` to 500 and computes `hasMore` on the raw window
    /// *before* per-user hidden messages are filtered out, so `messages` can be shorter than
    /// `limit` — even empty — while `hasMore` is true. Loop on `hasMore`, never on `messages.count`.
    private func repair(_ conversationId: String, from fromSeq: Int64, to toSeq: Int64) async {
        guard toSeq - fromSeq + 1 > 0 else { return }

        guard toSeq - fromSeq + 1 <= options.maxAutoRepairSeq else {
            // Too far behind to backfill message by message. Replaying fifty thousand messages into
            // a UI helps nobody, and doing it on a phone on cellular helps less.
            await decline(conversationId, from: fromSeq, to: toSeq)
            return
        }

        var cursor = fromSeq
        var pages = 0

        while cursor <= toSeq {
            pages += 1

            guard pages <= options.maxRepairPages else {
                // A server that always reports `hasMore` must not be able to spin a client forever.
                // Falling through to the oversized behaviour keeps the cursor honest and tells the
                // application that this stretch needs a reload.
                await decline(conversationId, from: cursor, to: toSeq)
                return
            }

            let result: SyncMessagesResult
            do {
                result = try await connection.request("msg.sync", body: SyncMessagesRequest(
                    conversationId: conversationId,
                    fromSeq: cursor,
                    toSeq: toSeq,
                    limit: Int(min(toSeq - cursor + 1, 500)),
                    ascending: true
                ))
            } catch {
                // The repair failed — the socket died mid-fetch, or the range has aged out of
                // storage. The caller still delivers the message that exposed the gap, because a
                // conversation frozen at yesterday's message is a worse failure than one missing a
                // few in the middle, and the cursor stays where it was so the next connect retries.
                return
            }

            for message in result.messages.sorted(by: { $0.seq < $1.seq })
            where message.seq >= cursor && message.seq <= toSeq {
                guard message.seq > (delivered[conversationId] ?? 0) else { continue }
                delivered[conversationId] = message.seq
                emit(message)
            }

            guard result.hasMore else { break }

            let next = (result.messages.map(\.seq).max() ?? result.maxSeq) + 1
            guard next > cursor else { break }
            cursor = next
        }
    }

    /// Gives up on a span, and says so.
    ///
    /// Both halves are mandatory. Skipping the cursor advance makes every later message look like a
    /// gap and re-request a range we have already declined; skipping the event leaves a hole in the
    /// UI that nothing will ever mention. A hole nobody is told about is the same defect as a hole
    /// nobody repairs.
    ///
    /// 两半都不能省：不推进游标，之后每条消息都会被当成缺口而反复重拉已经拒绝过的区间；
    /// 不发事件，界面上就留下一段永远没人提起的空白。
    private func decline(_ conversationId: String, from fromSeq: Int64, to toSeq: Int64) async {
        if toSeq > (delivered[conversationId] ?? 0) {
            delivered[conversationId] = toSeq
        }

        if cursorsUsable, toSeq > (committed[conversationId] ?? 0) {
            committed[conversationId] = toSeq
            saveIsPending = true
            await flushCursors()
        }

        sessionHub.yield(.conversationNeedsReload(
            conversationId: conversationId,
            fromSeq: fromSeq,
            toSeq: toSeq
        ))
    }

    /// Runs after every connect and every reconnect: asks the server what changed while we were
    /// away, and repairs each conversation whose `seq` has moved past ours.
    ///
    /// It deliberately does not replay everything. A client that has been offline for a week is
    /// behind by more messages than it can usefully receive at once, and the server knows better
    /// than the client which conversations actually moved.
    ///
    /// The paging is not optional. `conn.sync` returns at most 200 conversations per page and the
    /// list is sorted by `updatedAt` **descending**, so a client that reads page 1, takes the
    /// newest timestamp from it and stops has pushed `conversationCursor` past every conversation
    /// on pages 2…N — and `ListUserConversationsAsync` filters on `UpdatedAt > updatedAfter`, so the
    /// server will never return them again. Re-reading a page is free; skipping one is permanent.
    private func resume() async {
        // §5.2(2), and the reason redelivery reaches the application at all: without this reset,
        // repaired messages are dropped as duplicates by the very cursor that was too far ahead.
        resetDeliveredToCommitted()

        // Whatever a commit left pending goes out before we report `convSeqs`.
        await flushCursors()

        var cursor: String? = nil
        var newestUpdatedAt = conversationCursor
        var completedRun = false
        var page = 0

        while page < options.maxResumePages {
            page += 1

            let result: ResumeResult
            do {
                result = try await connection.request("conn.sync", body: ResumeRequest(
                    convSeqs: committed,
                    conversationCursor: conversationCursor,
                    cursor: cursor,
                    limit: 200
                ))
            } catch {
                // Interrupted. `conversationCursor` must not move at all: a partial run that
                // advanced it would hide every conversation it never reached.
                return
            }

            var adoptedSomething = false
            var maxSeqOnPage: [String: Int64] = [:]

            for view in result.conversations {
                newestUpdatedAt = max(newestUpdatedAt, view.updatedAt)
                maxSeqOnPage[view.conversationId] = view.maxSeq

                // First sight of a conversation: adopt its cursor rather than replaying its whole
                // history into a UI that has never shown it. Never while the store is unreadable —
                // a failed load and a fresh install are indistinguishable here, and that is exactly
                // the confusion adoption must not resolve by guessing.
                if cursorsUsable, committed[view.conversationId] == nil {
                    committed[view.conversationId] = view.maxSeq
                    delivered[view.conversationId] = view.maxSeq
                    saveIsPending = true
                    adoptedSomething = true
                }
            }

            // Adoption is a commit, and unlike an ordinary one its write is flushed *here* — before
            // the next page is requested. If an adoption write is lost, the next cold start sees no
            // entry, adopts a newer `maxSeq`, and silently drops everything in between: the
            // original bug, re-created by the optimisation.
            if adoptedSomething {
                await flushCursors()
            }

            // Sorted only so the order is reproducible: a dictionary's iteration order is not, and
            // a test that asserts what was requested should not have to sort the evidence.
            for (conversationId, toSeq) in maxSeqOnPage.sorted(by: { $0.key < $1.key }) {
                // With the store unreadable the client has no trustworthy floor for a conversation
                // it holds no entry for, and inventing one would either replay a whole history or
                // skip part of it. Leave it alone until the application commits a real cursor and
                // calls ``resync()``.
                guard cursorsUsable || committed[conversationId] != nil else { continue }

                // The server's own gap list is authoritative when it has an entry — but it only
                // emits one when the client reported a non-zero seq (`ConnController.Sync` guards
                // on `known > 0`), so a conversation we hold at 0 produces no entry at all. Taking
                // the later of the two means a client is never at the mercy of that guard.
                let fromSeq = max((committed[conversationId] ?? 0) + 1, result.gapsFrom[conversationId] ?? 0)
                guard toSeq >= fromSeq else { continue }

                await repair(conversationId, from: fromSeq, to: toSeq)
            }

            if !result.hasMore {
                completedRun = true
                break
            }

            guard let next = result.nextCursor, !next.isEmpty else {
                // `hasMore` with nothing to page on. Nothing useful left to do, and emphatically
                // not a completed run.
                break
            }

            cursor = next
        }

        // Only a run that reached `hasMore == false` may move the conversation cursor.
        guard cursorsUsable, completedRun, newestUpdatedAt > conversationCursor else { return }

        conversationCursor = newestUpdatedAt
        saveIsPending = true
        await flushCursors()
    }

    private func resetDeliveredToCommitted() {
        delivered = committed
    }

    private func emit(_ message: ImMessage) {
        messageHub.yield(message)
    }

    // MARK: - Internal hooks

    /// Called by ``ImMsgNamespace`` after a successful send. Our own message occupies a seq like
    /// any other, and recording it keeps the echo the server pushes back from looking like a gap.
    nonisolated func noteSent(_ result: SendMessageResult) {
        workContinuation.yield(.sent(conversationId: result.conversationId, seq: result.seq))
    }

    /// Called by ``ImPushNamespace`` so a direct `im.push.register(_:)` still teaches the client
    /// what to re-send on the next connect.
    func notePushRegistered(_ request: RegisterPushTokenRequest) async {
        pushToken = CachedPushToken(
            provider: request.provider,
            token: request.token,
            language: request.language
        )
        pushEverRegistered = true
        pushRegisteredFor = PushRegistrationMark(
            session: await connection.sessionGeneration,
            token: request.token
        )
    }

    func notePushUnregistered() {
        pushToken = nil
        pushEverRegistered = false
        pushRegisteredFor = nil
    }
}
