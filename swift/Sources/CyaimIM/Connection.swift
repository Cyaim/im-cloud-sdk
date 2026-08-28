import Foundation

/// One multiplexed WebSocket to the gateway, with the reconnect behaviour a production client
/// actually needs.
///
/// Most apps want ``ImClient`` instead — it owns this object and adds the sequence tracking that
/// makes a conversation correct. Reach for `ImConnection` when you want the pipe and nothing else:
/// a bot, a diagnostic tool, a screen that only listens for `evt.presence`.
///
/// Reconnecting is not an optional extra here. A gateway holds sockets and therefore deploys
/// rarely, but when it does deploy — or when a node fails, or a phone hands off from Wi-Fi to
/// cellular, or iOS suspends the app for forty minutes — every client on that node reconnects at
/// once. Without jittered backoff those clients arrive as a synchronised thundering herd against
/// the very service that just came back up. See ``FullJitterBackoff`` for why the jitter is *full*
/// jitter and not a fixed delay with a wobble.
///
/// The object is an `actor`, so the receive loop, the heartbeat, the reconnect loop and the app's
/// own calls all mutate one piece of state — the pending-request table, the socket, the token —
/// without a lock and without the compiler having to take anyone's word for it.
///
/// 重连不是可选项：网关一次滚动更新会让该节点上所有客户端同时重连。没有带抖动的退避，
/// 这些客户端会变成打向刚恢复的服务的同步洪峰。
public actor ImConnection {

    // MARK: - Configuration

    /// Internal rather than private so ``ImClient`` can read the cursor store and the repair
    /// limits from the same options object the transport was built with.
    let options: ImClientOptions

    /// Replays the latest value, so a subscriber that arrives after the socket opened is still told
    /// that it is open instead of waiting for the next transition that may never come.
    private nonisolated let stateHub = Broadcaster<ConnectionState>(replaysLatest: true)

    private nonisolated let eventHubs = EventHubRegistry()

    // MARK: - Mutable state

    /// The token in use right now. Diverges from `options.token` the moment the host app supplies a
    /// replacement through ``ImClientOptions/tokenProvider``.
    private var token: String

    private var channel: (any ImWebSocketChannel)?
    private var state: ConnectionState = .idle

    private var pending: [String: PendingRequest] = [:]
    private var requestCounter: UInt64 = 0

    private var heartbeatInterval: Duration

    private var loopTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?

    /// Set by ``enterForeground()``. Read and cleared by the backoff wait, which treats "the user
    /// just came back" as new information rather than as another failed attempt.
    private var wakeRequested = false

    private var isClosedByClient = false

    /// Incremented every time a socket reaches ``ConnectionState/open``.
    ///
    /// Lets a caller say "once per socket" without having to observe the state stream itself, which
    /// is inherently a step behind: by the time a state pump sees `.open`, application code that was
    /// waiting on ``connect()`` has already run.
    private var openedSockets: UInt64 = 0

    /// The `conn.reauth` currently in flight, if any. See ``renewToken()``.
    private var renewal: Task<Bool, Never>?

    /// The last kick seen, so ``connect()`` can explain *why* it failed rather than reporting a
    /// generic "closed".
    private var lastKick: KickEvent?

    // MARK: - Init

    public init(options: ImClientOptions) {
        self.options = options
        self.token = options.token
        self.heartbeatInterval = options.heartbeatInterval
        stateHub.yield(.idle)
    }

    // MARK: - Observation

    /// Where the socket is right now. Cheap to read, and the value a `.task` modifier should render
    /// before the first element of ``states()`` arrives.
    public var currentState: ConnectionState { state }

    /// How many sockets this connection has opened. Identifies the current session.
    public var sessionGeneration: UInt64 { openedSockets }

    /// A stream of lifecycle changes, starting with the current value.
    ///
    /// Every call returns an independent stream, so a banner view and an analytics hook can each
    /// have one. The stream ends when ``close()`` is called; a terminal kick does *not* end it,
    /// because the app still needs to observe the `.closed` that follows.
    public nonisolated func states() -> AsyncStream<ConnectionState> {
        stateHub.subscribe()
    }

    /// Raw frames for one push target.
    ///
    /// Pushes that nobody is subscribed to are dropped rather than buffered, so subscribe before
    /// ``connect()``. That is not a performance nicety: an app that subscribes after connecting has
    /// a window in which the gateway's post-connect burst lands nowhere.
    public nonisolated func events(for target: PushTarget) -> AsyncStream<ImFrame> {
        events(for: target.rawValue)
    }

    /// Raw frames for a target the SDK does not name yet.
    public nonisolated func events(for target: String) -> AsyncStream<ImFrame> {
        eventHubs.hub(for: target).subscribe()
    }

    // MARK: - Lifecycle

    /// Opens the socket and returns once it is ``ConnectionState/open``.
    ///
    /// Returning when the connection is *usable*, rather than when the socket object exists, is
    /// what `async` should mean: the obvious sequence — `connect()` then `send()` — is then correct
    /// instead of a race. While the network is down this keeps waiting and the reconnect loop keeps
    /// trying, so wrap the call in a timeout if your UI needs to give up and show something.
    ///
    /// It throws only when the connection reaches a state it cannot come back from: a terminal
    /// kick, or an expired token the host app declined to replace.
    public func connect() async throws {
        guard !isClosedByClient else {
            throw ImError(code: .notConnected, message: "this connection is closed; build a new one")
        }

        if loopTask == nil {
            loopTask = Task { [weak self] in
                await self?.reconnectLoop()
            }
        }

        // Subscribed before awaiting, and the hub replays its latest value, so neither a transition
        // that happens in the next instant nor one that already happened can be missed.
        if await ImConnection.firstDecisiveState(in: stateHub.subscribe()) == .open {
            return
        }

        let kick = lastKick
        throw ImError(
            code: kick?.reason == .tokenExpired ? .tokenExpired : .unauthorized,
            message: "connection closed before it opened"
                + (kick.map { ": \(KickReason.closePrefix)\($0.reason.rawValue)" } ?? "")
        )
    }

    /// Consumes state changes until one of them settles the question `connect()` is asking.
    ///
    /// `static`, and therefore outside the actor, on purpose: iterating an `AsyncStream` from
    /// inside an actor would pin the iterator to the actor's executor for every element. Here the
    /// loop runs on the cooperative pool and the actor stays free to change the very state we are
    /// waiting for — which, if it did not, would be a deadlock rather than a slowdown.
    private static func firstDecisiveState(in states: AsyncStream<ConnectionState>) async -> ConnectionState {
        for await observed in states {
            if observed == .open || observed == .closed {
                return observed
            }
        }
        return .closed
    }

    /// Tell the connection the app is back in the foreground.
    ///
    /// Two different things need to happen and which one depends on where the connection is:
    ///
    /// - Waiting out a backoff: skip the rest of the wait. After a suspension the timer may still
    ///   have twenty seconds to run, and those are exactly the seconds the user spends looking at a
    ///   chat that has not loaded.
    /// - Nominally open: probe it. A socket that iOS froze for half an hour is frequently dead
    ///   without anything having said so, and the app is about to be judged on whether the first
    ///   message the user sends goes through. The probe is a heartbeat that forces the socket down
    ///   if it fails, which is far better than discovering the truth on the user's message.
    ///
    /// Returns immediately; the probe runs on its own.
    public func enterForeground() {
        guard !isClosedByClient else { return }

        wakeRequested = true
        retryTimer?.cancel()

        if state == .open {
            probeTask?.cancel()
            probeTask = Task { [weak self] in
                await self?.probe()
            }
        }
    }

    /// Terminal. Stops the reconnect loop and the heartbeat, fails every in-flight request, closes
    /// the socket and ends every stream this connection hands out.
    ///
    /// A closed connection is not reusable — build a new one, which is what you want after a logout
    /// anyway, since the token is different.
    public func close() {
        guard !isClosedByClient else { return }
        isClosedByClient = true

        loopTask?.cancel()
        loopTask = nil
        retryTimer?.cancel()
        retryTimer = nil
        probeTask?.cancel()
        probeTask = nil
        stopHeartbeat()

        channel?.close(code: 1000, reason: "client-close")
        channel = nil

        setState(.closed)

        // 1004 rather than 1005, for the same reason a dropped socket uses it: the SDK does not
        // know whether an in-flight request already executed, and claiming it was never delivered
        // is the answer that makes a caller resend something the server has already accepted.
        failAllPending(ImError(code: .timeout, message: "the connection was closed before the reply arrived"))

        eventHubs.finishAll()
        stateHub.finish()
    }

    // MARK: - Requests

    /// Sends a request, waits for the reply carrying the same id, and decodes its `data` as
    /// `Response`.
    ///
    /// Throws ``ImError`` for a transport failure, for any non-zero business code, and for a request
    /// that goes unanswered past ``ImClientOptions/requestTimeout``. Cancelling the calling task
    /// throws `CancellationError` and forgets the request.
    ///
    /// Requests issued while the socket is down fail immediately rather than queueing. A chat client
    /// that silently buffers sends produces messages that arrive minutes late with no explanation,
    /// and the caller is the only party that knows whether this particular send is still worth
    /// making.
    public func request<Response: Decodable & Sendable>(
        _ target: String,
        body: some Encodable & Sendable,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        let frame = try await exchangeRenewingToken(target: target, body: body)
        try frame.throwIfFailed(target: target)
        return try frame.requireData(as: Response.self)
    }

    /// ``request(_:body:as:)`` for an endpoint that takes no arguments.
    public func request<Response: Decodable & Sendable>(
        _ target: String,
        as type: Response.Type = Response.self
    ) async throws -> Response {
        try await request(target, body: EmptyBody(), as: type)
    }

    /// A call whose reply carries nothing worth decoding. It still throws on failure — it is the
    /// error, not the payload, that these endpoints return.
    public func execute(_ target: String, body: some Encodable & Sendable) async throws {
        let frame = try await exchangeRenewingToken(target: target, body: body)
        try frame.throwIfFailed(target: target)
    }

    /// ``execute(_:body:)`` for an endpoint that takes no arguments.
    public func execute(_ target: String) async throws {
        try await execute(target, body: EmptyBody())
    }

    /// One round trip, with a single `conn.reauth` retry when the token aged out mid-session.
    ///
    /// A token that expires while the socket is up used to cost a full reconnect — and on a flaky
    /// network a reconnect is exactly what the long-lived socket was avoiding. `conn.reauth` swaps
    /// the credential in place on the existing socket, so the cost is one extra round trip and the
    /// caller never sees the failure.
    ///
    /// The retry happens **once**, never on `conn.reauth` itself, and only when the host app
    /// supplied a ``ImClientOptions/tokenProvider``. If the renewal fails, the original `1101` is
    /// returned untouched and the caller sees the honest answer.
    ///
    /// 令牌在会话中过期本来要付一次完整重连的代价，而弱网下重连正是长连接想避免的。
    private func exchangeRenewingToken(
        target: String,
        body: some Encodable & Sendable
    ) async throws -> ImFrame {
        let frame = try await exchange(target: target, body: body)

        guard frame.status == 0,
              frame.body?.code == .tokenExpired,
              target != "conn.reauth",
              options.tokenProvider != nil
        else {
            return frame
        }

        guard await renewToken() else { return frame }

        return try await exchange(target: target, body: body)
    }

    /// Fetches a fresh token and swaps it in. Single-flight: a burst of requests that all hit
    /// `1101` at once produces one `conn.reauth`, not one each.
    private func renewToken() async -> Bool {
        if let inFlight = renewal {
            return await inFlight.value
        }

        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            return await self.performRenewal()
        }

        renewal = task
        let renewed = await task.value
        renewal = nil
        return renewed
    }

    private func performRenewal() async -> Bool {
        guard let provider = options.tokenProvider else { return false }
        guard let fresh = await provider(), !fresh.isEmpty else { return false }

        do {
            let frame = try await exchange(target: "conn.reauth", body: ReauthRequest(token: fresh))
            try frame.throwIfFailed(target: "conn.reauth")
        } catch {
            return false
        }

        // Kept for the next reconnect too, so a socket that drops right after a renewal comes back
        // with the token that works rather than the one that just expired.
        token = fresh
        return true
    }

    /// One request/response round trip, returning the raw frame.
    ///
    /// The ordering here is the whole multiplexing story: the pending entry is recorded *before*
    /// the frame is handed to the socket, so a reply can never arrive for a caller that has not
    /// been written down yet. The actor's serial execution is what makes that guarantee free.
    private func exchange(target: String, body: some Encodable & Sendable) async throws -> ImFrame {
        guard state == .open, channel != nil else {
            throw ImError(code: .notConnected, message: "not connected", target: target)
        }

        try Task.checkCancellation()

        requestCounter += 1
        // Unique per connection, which is all the reply router needs. The counter also makes the id
        // sortable in a packet capture, which is worth something at three in the morning.
        let id = "c\(requestCounter)-\(String(ImClock.nowMilliseconds(), radix: 36))"

        let text: String
        do {
            let data = try JSONValue.encoder.encode(ImRequestFrame(id: id, target: target, body: body))
            text = String(decoding: data, as: UTF8.self)
        } catch {
            throw ImError(
                code: .invalidArgument,
                message: "could not encode \(target): \(error)",
                target: target
            )
        }

        let timeout = options.requestTimeout

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ImFrame, any Error>) in
                // Strong `self` in all three tasks below, deliberately. Each one exists to resume
                // the continuation exactly once, and a connection released mid-request would
                // otherwise leave the caller suspended forever.
                let expiry = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return // cancelled because the reply arrived first
                    }
                    await self.expire(id: id)
                }

                pending[id] = PendingRequest(target: target, continuation: continuation, expiry: expiry)

                Task {
                    await self.transmit(text: text, id: id)
                }
            }
        } onCancel: {
            Task {
                await self.abort(id: id)
            }
        }
    }

    private func transmit(text: String, id: String) async {
        guard let channel else {
            fail(id: id, with: ImError(code: .notConnected, message: "not connected"))
            return
        }

        do {
            try await channel.send(text)
        } catch {
            fail(id: id, with: ImError(code: .notConnected, message: "socket refused the frame: \(error)"))
        }
    }

    private func expire(id: String) async {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.expiry.cancel()
        entry.continuation.resume(
            throwing: ImError(
                code: .timeout,
                message: "request timed out after \(options.requestTimeout): \(entry.target)",
                target: entry.target
            )
        )
    }

    private func abort(id: String) async {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.expiry.cancel()
        entry.continuation.resume(throwing: CancellationError())
    }

    private func fail(id: String, with error: ImError) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.expiry.cancel()
        entry.continuation.resume(throwing: ImError(
            code: error.code,
            message: error.message,
            traceId: error.traceId,
            target: entry.target
        ))
    }

    private func failAllPending(_ error: ImError) {
        let entries = pending
        pending.removeAll()

        for (_, entry) in entries {
            entry.expiry.cancel()
            entry.continuation.resume(throwing: ImError(
                code: error.code,
                message: error.message,
                traceId: error.traceId,
                target: entry.target
            ))
        }
    }

    private struct PendingRequest {
        let target: String
        let continuation: CheckedContinuation<ImFrame, any Error>
        let expiry: Task<Void, Never>
    }

    /// How many replies are outstanding. Internal, and read only by the test that proves a
    /// cancelled call removes its entry rather than leaking one for the life of the connection.
    var pendingRequestCount: Int { pending.count }

    // MARK: - Reconnect loop

    private enum Disposition {
        /// A network-class failure. Back off — with jitter — and come back.
        case retry
        /// The token is stale. Ask the host app for a new one, then come back.
        case refreshToken
        /// Do not come back. Reconnecting would fail identically, forever.
        case terminal
    }

    private struct SessionOutcome {
        let opened: Bool
        let disposition: Disposition
        let kick: KickEvent?
    }

    private func reconnectLoop() async {
        var attempt = 0

        while !isClosedByClient && !Task.isCancelled {
            setState(attempt == 0 ? .connecting : .reconnecting)

            let outcome = await runSession()

            // A session that actually opened resets the ladder. Otherwise a connection that
            // survives an hour and then drops would be treated as the tenth failure in a row and
            // wait thirty seconds for no reason.
            if outcome.opened { attempt = 0 }

            switch outcome.disposition {
            case .terminal:
                if let kick = outcome.kick { emitKick(kick) }
                setState(.closed)
                return

            case .refreshToken:
                let fresh = await refreshedToken()

                guard let fresh, !fresh.isEmpty else {
                    // No host app, or the host app said no. `nil` is the right answer when the user
                    // has been signed out entirely, and looping on a token we know is expired is
                    // load with no upside.
                    emitKick(outcome.kick ?? KickEvent(
                        reason: .tokenExpired,
                        serverTime: ImClock.nowMilliseconds()
                    ))
                    setState(.closed)
                    return
                }

                token = fresh
                attempt += 1
                if await waitBeforeRetry(attempt: attempt) { attempt = 0 }

            case .retry:
                attempt += 1
                if await waitBeforeRetry(attempt: attempt) { attempt = 0 }
            }
        }

        if isClosedByClient { setState(.closed) }
    }

    /// Asks the host app for a replacement token.
    ///
    /// The `await` releases the actor, so a token endpoint that takes four seconds stalls only the
    /// reconnect loop — the app's own calls into this object are still served meanwhile.
    private func refreshedToken() async -> String? {
        guard let provider = options.tokenProvider else { return nil }
        return await provider()
    }

    /// Waits out one backoff. Returns `true` when ``enterForeground()`` cut the wait short.
    private func waitBeforeRetry(attempt: Int) async -> Bool {
        setState(.reconnecting)

        // Only a wake that arrives *during* the wait counts; one left over from while we were
        // connected must not skip the very first backoff after a drop.
        wakeRequested = false

        let delay = options.backoff.delay(forAttempt: attempt)
        guard delay > .zero else {
            // A zero draw is legal full jitter — reconnect at once. Yield first so a gateway that
            // refuses instantly cannot spin this loop into a hot one.
            await Task.yield()
            return false
        }

        // `try? await …` would infer `Task<Void?, Never>`; the explicit catch keeps the type
        // `Task<Void, Never>` so the stored property does not have to widen.
        let timer = Task { do { try await Task.sleep(for: delay) } catch {} }
        retryTimer = timer
        await timer.value
        retryTimer = nil

        let woken = wakeRequested
        wakeRequested = false
        return woken
    }

    /// Opens one socket and returns when it dies, along with what the loop should do about it.
    private func runSession() async -> SessionOutcome {
        let url: URL
        do {
            url = try buildURL()
        } catch {
            // A malformed endpoint will not become well formed on the fourth attempt.
            return SessionOutcome(
                opened: false,
                disposition: .terminal,
                kick: KickEvent(reason: .handshakeRejected, serverTime: ImClock.nowMilliseconds())
            )
        }

        let socket: any ImWebSocketChannel
        do {
            socket = try await options.connector.connect(to: url)
        } catch let handshake as ImWebSocketHandshakeError {
            return outcome(forHandshakeStatus: handshake.statusCode)
        } catch let closed as ImWebSocketClose {
            // The gateway accepted the upgrade and then evicted us immediately, which is how a
            // multi-login kick presents itself when the other device wins the race.
            return outcome(forCloseReason: closed.reason, opened: false)
        } catch {
            return SessionOutcome(opened: false, disposition: .retry, kick: nil)
        }

        channel = socket
        openedSockets += 1
        setState(.open)
        startHeartbeat(on: socket)

        var closeReason: String?
        do {
            while true {
                let text = try await socket.receive()
                dispatch(text)
            }
        } catch let closed as ImWebSocketClose {
            closeReason = closed.reason
        } catch {
            // A transport error with no close frame: a dead radio, a middlebox, a TLS failure.
            closeReason = nil
        }

        stopHeartbeat()
        channel = nil
        socket.close(code: 1000, reason: "session-ended")

        // 1004 Timeout, deliberately, and not 1005: 1005 claims the call was never delivered and
        // the SDK does not know that. The request may well have executed. Timeout is the honest
        // answer, and it is the one that makes a caller reach for `clientMsgId` idempotency
        // instead of blindly resending.
        failAllPending(ImError(code: .timeout, message: "the socket closed before the reply arrived"))

        if isClosedByClient {
            return SessionOutcome(opened: true, disposition: .retry, kick: nil)
        }

        return outcome(forCloseReason: closeReason, opened: true)
    }

    /// The close reason is the only signal that separates "you were kicked" from "the network
    /// died", and the two need opposite responses.
    private func outcome(forCloseReason reason: String?, opened: Bool) -> SessionOutcome {
        guard let kicked = KickReason(closeReason: reason) else {
            return SessionOutcome(opened: opened, disposition: .retry, kick: nil)
        }

        let kick = KickEvent(reason: kicked, serverTime: ImClock.nowMilliseconds())

        if kicked == .tokenExpired {
            return SessionOutcome(opened: opened, disposition: .refreshToken, kick: kick)
        }

        if kicked.isTerminal {
            return SessionOutcome(opened: opened, disposition: .terminal, kick: kick)
        }

        // A reason from a server newer than this build — `ServerShutdown` among them. Reconnecting
        // is the safe guess: at worst we are told again, at best we were dropped for something
        // transient like a node going away for a deploy.
        return SessionOutcome(opened: opened, disposition: .retry, kick: kick)
    }

    private func outcome(forHandshakeStatus status: Int?) -> SessionOutcome {
        let now = ImClock.nowMilliseconds()

        switch status {
        case 401:
            // The gateway rejects a stale token in `BeforeConnectionEvent`, before a socket exists.
            // Recoverable, and the only party that can fix it is the host app.
            return SessionOutcome(
                opened: false,
                disposition: .refreshToken,
                kick: KickEvent(reason: .tokenExpired, serverTime: now)
            )
        case 403:
            // Authenticated and refused: banned user, disabled app, wrong tenant. Retrying is pure
            // load against a decision that will not change.
            return SessionOutcome(
                opened: false,
                disposition: .terminal,
                kick: KickEvent(reason: .handshakeRejected, serverTime: now)
            )
        default:
            // 5xx, 429, a proxy in the way, no response at all. All of these come back.
            return SessionOutcome(opened: false, disposition: .retry, kick: nil)
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat(on socket: any ImWebSocketChannel) {
        stopHeartbeat()
        heartbeatTask = Task { [weak self] in
            await self?.runHeartbeat(on: socket)
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// Beats on the server's cadence and forces the socket down when a beat fails.
    ///
    /// This is the half-open socket case, and on iOS it is not an edge case: the phone changed
    /// network, or a NAT dropped the flow while the app was suspended, and the OS still reports a
    /// perfectly good connection because nothing has been sent to prove otherwise. The failed beat
    /// is that proof. Without it the user sees a connected UI that silently delivers nothing.
    private func runHeartbeat(on socket: any ImWebSocketChannel) async {
        while !Task.isCancelled {
            let interval = heartbeatInterval
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }

            do {
                let beat: HeartbeatResult = try await request("conn.heartbeat")
                // The server owns the cadence; adopt whatever it reports rather than hard-coding
                // one that a future gateway config would silently disagree with.
                if beat.intervalSeconds > 0 {
                    heartbeatInterval = .seconds(beat.intervalSeconds)
                }
            } catch is CancellationError {
                return
            } catch {
                socket.close(code: 4000, reason: "heartbeat-failed")
                return
            }
        }
    }

    /// One immediate beat, used by ``enterForeground()``.
    private func probe() async {
        guard state == .open, let socket = channel else { return }

        do {
            let beat: HeartbeatResult = try await request("conn.heartbeat")
            if beat.intervalSeconds > 0 {
                heartbeatInterval = .seconds(beat.intervalSeconds)
            }
        } catch is CancellationError {
            return
        } catch {
            socket.close(code: 4001, reason: "foreground-probe-failed")
        }
    }

    // MARK: - Plumbing

    /// Routes one inbound text frame. Replies and pushes are structurally identical, so this is the
    /// only decode site: a reply finds its caller by id, and anything else is a push.
    private func dispatch(_ text: String) {
        let frame: ImFrame
        do {
            frame = try JSONValue.decoder.decode(ImFrame.self, from: Data(text.utf8))
        } catch {
            // An unparseable frame. Dropping it beats tearing down a working socket over one bad
            // payload — the next frame is probably fine.
            return
        }

        if !frame.id.isEmpty, let waiting = pending.removeValue(forKey: frame.id) {
            waiting.expiry.cancel()
            waiting.continuation.resume(returning: frame)
            return
        }

        if frame.target == PushTarget.kick.rawValue,
           let event: KickEvent = frame.decodedData() {
            // Remember the server's own version of the kick: it carries the operator id and the
            // authoritative time, which the close-reason fallback below cannot.
            lastKick = event
        }

        eventHubs.publish(frame)
    }

    /// Publishes a kick the app would otherwise never see.
    ///
    /// The gateway usually pushes `conn.kick` before closing, but a node that dies mid-kick, or a
    /// proxy that eats the last frame, leaves the close reason as the only evidence — and "you were
    /// signed out on another device" is not a message an app can afford to lose.
    private func emitKick(_ kick: KickEvent) {
        lastKick = kick

        eventHubs.publish(ImFrame(
            id: "",
            target: PushTarget.kick.rawValue,
            status: 0,
            body: ImBody(
                code: .ok,
                serverTime: kick.serverTime,
                data: .object([
                    "reason": .string(kick.reason.rawValue),
                    "serverTime": .int(kick.serverTime),
                ])
            )
        ))
    }

    private func setState(_ next: ConnectionState) {
        guard state != next else { return }
        state = next
        stateHub.yield(next)
    }

    /// Builds the handshake URL.
    ///
    /// `https`/`http` are rewritten to `wss`/`ws` because the two get mixed up constantly and the
    /// failure — `URLSessionWebSocketTask` never completing its upgrade — looks exactly like a dead
    /// network. Query items go through `URLComponents` so a token with URL-unsafe characters cannot
    /// silently truncate the query.
    private func buildURL() throws -> URL {
        guard var components = URLComponents(url: options.endpoint, resolvingAgainstBaseURL: false) else {
            throw ImError(code: .invalidArgument, message: "endpoint is not a URL: \(options.endpoint)")
        }

        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }

        let channelPath = options.channelPath.hasPrefix("/") ? options.channelPath : "/" + options.channelPath
        components.path = path + channelPath

        var items = [
            URLQueryItem(name: "appId", value: options.appId),
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "deviceId", value: options.deviceId),
            URLQueryItem(name: "platform", value: String(options.platform.rawValue)),
            URLQueryItem(name: "v", value: "1"),
        ]

        items.append(URLQueryItem(name: "cv", value: options.handshakeClientVersion))
        if let language = options.language {
            items.append(URLQueryItem(name: "lang", value: language))
        }

        components.queryItems = items

        guard let url = components.url else {
            throw ImError(code: .invalidArgument, message: "could not build a handshake URL")
        }

        return url
    }
}
