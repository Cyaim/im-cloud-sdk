import Foundation
import Testing

@testable import CyaimIM

/// A request the SDK put on the wire, decoded.
///
/// Tests assert against this rather than against a string, because "did it ask for exactly the
/// missing range" is a question about `fromSeq` and `toSeq`, not about JSON formatting.
struct SentRequest: Sendable {
    let id: String
    let target: String
    let body: JSONValue

    init?(json text: String) {
        struct Raw: Decodable {
            let id: String
            let target: String
            let body: JSONValue?
        }

        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(text.utf8)) else { return nil }
        self.id = raw.id
        self.target = raw.target
        self.body = raw.body ?? .object([:])
    }

    subscript(key: String) -> JSONValue? { body[key] }
}

/// One scripted socket.
///
/// Everything the SDK's hard parts do — multiplex a reply, notice a gap, tell a kick from a dead
/// network — happens at this boundary, so this is where they can be tested without a gateway, a
/// network, or a clock that CI is allowed to disagree with.
final class MockChannel: ImWebSocketChannel, @unchecked Sendable {
    typealias Responder = @Sendable (SentRequest, MockChannel) -> Void

    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiter: CheckedContinuation<String, any Error>?
    private var closure: ImWebSocketClose?
    private var recorded: [SentRequest] = []
    private var wire: [String] = []
    private let responder: Responder

    init(responder: @escaping Responder) {
        self.responder = responder
    }

    // MARK: ImWebSocketChannel

    func send(_ text: String) async throws {
        // Every lock/unlock pair lives in a synchronous helper: `NSLock` is `noasync` on the
        // corelibs platforms, so a critical section may not straddle an `await` even accidentally.
        if let closed = currentClosure() { throw closed }

        guard let request = SentRequest(json: text) else { return }

        record(request)
        responder(request, self)
    }

    private func currentClosure() -> ImWebSocketClose? {
        lock.lock()
        defer { lock.unlock() }
        return closure
    }

    private func record(_ request: SentRequest) {
        lock.lock()
        recorded.append(request)
        wire.append("send:\(request.target)")
        lock.unlock()
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()

            if let closure {
                lock.unlock()
                continuation.resume(throwing: closure)
                return
            }

            if !inbox.isEmpty {
                let next = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
                return
            }

            waiter = continuation
            lock.unlock()
        }
    }

    func close(code: Int, reason: String) {
        finish(code: code, reason: reason)
    }

    // MARK: Server side

    /// Closes from the server's end. `reason` is where `im-kick:{Reason}` lives.
    func serverClose(code: Int, reason: String?) {
        finish(code: code, reason: reason)
    }

    /// Delivers a frame to the client.
    func push(_ frame: ImFrame) {
        guard let data = try? JSONEncoder().encode(frame) else {
            Issue.record("could not encode a frame for \(frame.target)")
            return
        }
        deliver(String(decoding: data, as: UTF8.self))
    }

    /// Replies to a request with a successful body.
    func reply(to request: SentRequest, data: JSONValue) {
        push(ImFrame(
            id: request.id,
            target: request.target,
            status: 0,
            body: ImBody(code: .ok, serverTime: ImClock.nowMilliseconds(), data: data)
        ))
    }

    /// Replies with a business failure — a non-zero `code` inside a transport-level success.
    func reply(to request: SentRequest, code: ImErrorCode, message: String, traceId: String? = nil) {
        push(ImFrame(
            id: request.id,
            target: request.target,
            status: 0,
            body: ImBody(
                code: code,
                message: message,
                traceId: traceId,
                serverTime: ImClock.nowMilliseconds(),
                data: nil
            )
        ))
    }

    /// Replies the way the gateway answers a target it has never heard of: transport `status: 2`,
    /// no business envelope at all.
    func replyUnroutable(to request: SentRequest) {
        push(ImFrame(
            id: request.id,
            target: request.target,
            status: 2,
            msg: "endpoint not found: \(request.target)"
        ))
    }

    /// Replies the way the gateway answers an endpoint that threw: transport `status: 1`.
    func replyEndpointThrew(to request: SentRequest, message: String = "unhandled exception") {
        push(ImFrame(id: request.id, target: request.target, status: 1, msg: message))
    }

    /// Pushes a server-initiated event.
    func event(_ target: PushTarget, data: JSONValue) {
        push(ImFrame(
            id: "srv-\(UUID().uuidString.prefix(8))",
            target: target.rawValue,
            status: 0,
            body: ImBody(code: .ok, serverTime: ImClock.nowMilliseconds(), data: data)
        ))
    }

    // MARK: Inspection

    var requests: [SentRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func requests(for target: String) -> [SentRequest] {
        requests.filter { $0.target == target }
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closure != nil
    }

    /// Sends and the close, in the order they happened.
    ///
    /// `requests` alone cannot answer "did the unregister go out *before* the socket closed", and
    /// that ordering is the entire content of the push-on-logout rule.
    var wireLog: [String] {
        lock.lock()
        defer { lock.unlock() }
        return wire
    }

    var closeCode: Int? {
        lock.lock()
        defer { lock.unlock() }
        return closure?.code
    }

    // MARK: Internals

    private func deliver(_ text: String) {
        lock.lock()

        if let waiting = waiter {
            waiter = nil
            lock.unlock()
            waiting.resume(returning: text)
            return
        }

        inbox.append(text)
        lock.unlock()
    }

    private func finish(code: Int, reason: String?) {
        lock.lock()
        if closure == nil {
            closure = ImWebSocketClose(code: code, reason: reason)
            wire.append("close:\(code)")
        }
        let error = closure!
        let waiting = waiter
        waiter = nil
        lock.unlock()

        waiting?.resume(throwing: error)
    }
}

/// Stands in for the gateway: counts handshakes, hands out ``MockChannel``s, and can refuse the
/// upgrade the way a real gateway refuses a stale token.
final class MockGateway: ImWebSocketConnector, @unchecked Sendable {
    enum Handshake: Sendable {
        case accept
        case refuse(status: Int)
    }

    private let lock = NSLock()
    private var urls: [URL] = []
    private var channels: [MockChannel] = []

    private let handshake: @Sendable (Int) -> Handshake
    private let onOpen: @Sendable (Int, MockChannel) -> Void
    private let responder: MockChannel.Responder

    /// - Parameters:
    ///   - handshake: decides, per attempt (1-based), whether the upgrade succeeds.
    ///   - onOpen: runs the moment a socket exists. Kick from here to reproduce an eviction that
    ///     lands before the client has said anything.
    ///   - responder: answers requests. The default answers the two endpoints the SDK calls on its
    ///     own — a heartbeat and the post-connect resume — so a test only has to script what it is
    ///     actually about.
    init(
        handshake: @escaping @Sendable (Int) -> Handshake = { _ in .accept },
        onOpen: @escaping @Sendable (Int, MockChannel) -> Void = { _, _ in },
        responder: @escaping MockChannel.Responder = MockGateway.defaultResponder
    ) {
        self.handshake = handshake
        self.onOpen = onOpen
        self.responder = responder
    }

    static let defaultResponder: MockChannel.Responder = { request, channel in
        _ = MockGateway.answerHousekeeping(request, channel)
    }

    /// One `conn.sync` page, as the wire shapes it.
    static func resumePage(
        conversations: [JSONValue] = [],
        gapsFrom: [String: Int64] = [:],
        nextCursor: String? = nil,
        hasMore: Bool = false
    ) -> JSONValue {
        var page: [String: JSONValue] = [
            "conversations": .array(conversations),
            "gapsFrom": .object(gapsFrom.mapValues { JSONValue.int($0) }),
            "hasMore": .bool(hasMore),
            "serverTime": .int(ImClock.nowMilliseconds()),
        ]

        if let nextCursor { page["nextCursor"] = .string(nextCursor) }
        return .object(page)
    }

    /// Answers the three calls every connect makes: `conn.heartbeat`, `conn.sync` and
    /// `diag.logRequests`. Returns true when it handled the request, so a test's own responder can
    /// delegate the boring half.
    ///
    /// **`diag.logRequests` belongs here, and leaving it out cost a red CI run.** It is issued on
    /// every connect exactly as the other two are, so a mock that does not answer it leaves a
    /// request pending in every test — which shows up as a leaked pending entry in one suite and as
    /// delivery ordering going wrong in another, neither of which names the cause. A mock gateway
    /// that answers only some of what the client always sends is not a smaller mock, it is a wrong
    /// one.
    /// diag.logRequests 属于这里：它与另外两条一样，每次连接都会发。
    /// 不答复它，每个用例里都会留下一条挂起的请求——表现为一个套件里「挂起项泄漏」、
    /// 另一个套件里「投递顺序不对」，而两者都不说出原因。
    @discardableResult
    static func answerHousekeeping(_ request: SentRequest, _ channel: MockChannel) -> Bool {
        switch request.target {
        case "diag.logRequests":
            // An empty list: nobody has asked this device for a log. That is the answer in every
            // test here, because a test that wanted otherwise would say so itself.
            // 空列表：没人要这台设备的日志——想要别的答案的用例会自己说。
            channel.reply(to: request, data: .array([]))
            return true

        case "conn.heartbeat":
            channel.reply(to: request, data: .object([
                "serverTime": .int(ImClock.nowMilliseconds()),
                "intervalSeconds": .int(30),
                "healed": .bool(false),
                "connectionId": .string("conn-test"),
                "nodeId": .string("node-test"),
            ]))
            return true

        case "conn.sync":
            channel.reply(to: request, data: .object([
                "conversations": .array([]),
                "gapsFrom": .object([:]),
                "hasMore": .bool(false),
                "serverTime": .int(ImClock.nowMilliseconds()),
            ]))
            return true

        default:
            return false
        }
    }

    func connect(to url: URL) async throws -> any ImWebSocketChannel {
        let attempt = recordAttempt(url)

        switch handshake(attempt) {
        case .refuse(let status):
            throw ImWebSocketHandshakeError(statusCode: status, underlying: nil)
        case .accept:
            break
        }

        let channel = MockChannel(responder: responder)
        recordChannel(channel)

        onOpen(attempt, channel)
        return channel
    }

    private func recordAttempt(_ url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        urls.append(url)
        return urls.count
    }

    private func recordChannel(_ channel: MockChannel) {
        lock.lock()
        channels.append(channel)
        lock.unlock()
    }

    /// How many times the SDK has tried to open a socket. The number the kick tests are about.
    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return urls.count
    }

    var handshakeURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    var openedChannels: [MockChannel] {
        lock.lock()
        defer { lock.unlock() }
        return channels
    }

    var lastChannel: MockChannel? {
        openedChannels.last
    }

    func queryValue(_ name: String, ofAttempt attempt: Int) -> String? {
        let urls = handshakeURLs
        guard urls.indices.contains(attempt - 1) else { return nil }
        return URLComponents(url: urls[attempt - 1], resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}
