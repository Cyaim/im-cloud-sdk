import Foundation
import Testing

@testable import CyaimIM

/// A deterministic `RandomNumberGenerator` (SplitMix64).
///
/// The reconnect tests assert the *shape of a distribution*, which is only a fact — rather than a
/// coin flip that fails one CI run in fifty — if the draws are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64 = 0x2545_F491_4F6C_DD1D) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Collects everything an `AsyncStream` produces so a test can assert on it after the fact.
///
/// A lock-guarded class rather than an actor, so an assertion reads `collector.items` instead of
/// `await collector.items` — and, more usefully, so the consuming loop runs outside any actor.
final class Collector<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    private var pump: Task<Void, Never>?

    /// Starts consuming immediately, which matters: pushes with no subscriber are dropped by
    /// design, so a collector attached after `connect()` would be testing the wrong thing.
    init(_ stream: AsyncStream<Element>) {
        pump = Task { [weak self] in
            for await element in stream {
                self?.append(element)
            }
        }
    }

    var items: [Element] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int { items.count }

    func stop() {
        pump?.cancel()
        pump = nil
    }

    private func append(_ element: Element) {
        lock.lock()
        storage.append(element)
        lock.unlock()
    }
}

/// Float comparison with a tolerance. `Duration` round-trips through fractional seconds, so an
/// exact `==` here would be asserting on the last bit of a Double rather than on behaviour.
func isClose(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-9) -> Bool {
    abs(lhs - rhs) <= tolerance
}

/// A lock-guarded slot, for a responder that has to remember one thing between requests.
final class Holder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func take() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        let taken = value
        value = nil
        return taken
    }
}

/// Polls `condition` until it holds or the deadline passes.
///
/// Everything under test is event-driven, so a test that asserts immediately after an action is
/// asserting on a race. Polling a condition is slower to write than a `sleep` and does not go flaky
/// on a loaded CI box.
@discardableResult
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(3),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)

    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }

    Issue.record("timed out after \(timeout) waiting for: \(description)")
    return false
}

/// Gives the event loop a few turns so "nothing further happened" can be asserted honestly.
func settle(_ turns: Int = 40) async {
    for _ in 0 ..< turns {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// Options wired to a mock transport, with the timings a test can afford to wait for.
///
/// The backoff is deliberately tiny rather than disabled: reconnect behaviour is exactly what these
/// tests are about, and a zero delay would hide an ordering bug that a real millisecond exposes.
func makeOptions(
    connector: any ImWebSocketConnector,
    token: String = "token-1",
    requestTimeout: Duration = .milliseconds(500),
    heartbeatInterval: Duration = .seconds(30),
    backoff: FullJitterBackoff = FullJitterBackoff(
        initialDelay: .milliseconds(2),
        maximumDelay: .milliseconds(10),
        doublingLimit: 2
    ),
    maxAutoRepairSeq: Int64 = 500,
    userId: String = "alice",
    cursorStore: ImCursorStore = .inMemory(),
    cursorFlushInterval: Duration = .zero,
    maxRepairPages: Int = 16,
    maxResumePages: Int = 100,
    warningHandler: (@Sendable (String) -> Void)? = { _ in },
    tokenProvider: (@Sendable () async -> String?)? = nil
) -> ImClientOptions {
    ImClientOptions(
        endpoint: URL(string: "https://im.test")!,
        appId: "app-test",
        token: token,
        deviceId: "device-test",
        userId: userId,
        cursorStore: cursorStore,
        platform: .iOS,
        channelPath: "/im",
        clientVersion: "1.0.0-test",
        language: "en-US",
        requestTimeout: requestTimeout,
        heartbeatInterval: heartbeatInterval,
        backoff: backoff,
        maxAutoRepairSeq: maxAutoRepairSeq,
        cursorFlushInterval: cursorFlushInterval,
        maxRepairPages: maxRepairPages,
        maxResumePages: maxResumePages,
        warningHandler: warningHandler,
        tokenProvider: tokenProvider,
        connector: connector
    )
}

/// A cursor store a test can watch: it records every snapshot the SDK asked it to write, and can be
/// made to fail on load.
///
/// The recording matters as much as the storage. "The adoption write reached the store *before* the
/// next `conn.sync` page went out" is an ordering claim, and only a store that timestamps its
/// writes against the wire can settle it.
final class RecordingCursorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: ImCursorSnapshot
    private var writes: [ImCursorSnapshot] = []
    private var loadFailure: (any Error)?
    private var loadCount = 0

    init(_ initial: ImCursorSnapshot = .empty, loadFailure: (any Error)? = nil) {
        self.snapshot = initial
        self.loadFailure = loadFailure
    }

    convenience init(convSeqs: [String: Int64], conversationCursor: Int64 = 0, scope: String? = nil) {
        self.init(ImCursorSnapshot(
            convSeqs: convSeqs,
            conversationCursor: conversationCursor,
            scope: scope
        ))
    }

    var store: ImCursorStore {
        ImCursorStore(
            load: { [self] in try read() },
            save: { [self] in write($0) }
        )
    }

    /// Every snapshot the SDK asked to save, in order.
    var savedSnapshots: [ImCursorSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    var current: ImCursorSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    var loads: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadCount
    }

    private func read() throws -> ImCursorSnapshot {
        lock.lock()
        let failure = loadFailure
        loadCount += 1
        let value = snapshot
        lock.unlock()

        if let failure { throw failure }
        return value
    }

    private func write(_ value: ImCursorSnapshot) {
        lock.lock()
        snapshot = value
        writes.append(value)
        lock.unlock()
    }
}

/// A store whose `load()` throws. §5.8's whole point is that this is not the same as an empty one.
struct CursorStoreFailure: Error, Sendable {
    let reason: String
}

/// A wire-shaped `evt.message` payload.
func messagePayload(
    conversationId: String,
    seq: Int64,
    text: String? = nil,
    senderId: String = "alice"
) -> JSONValue {
    let now = ImClock.nowMilliseconds()

    return .object([
        "appId": .string("app-test"),
        "conversationId": .string(conversationId),
        "conversationType": .int(1),
        "seq": .int(seq),
        "messageId": .int(9_000_000_000_000_000 + seq),
        "clientMsgId": .string("cm-\(seq)"),
        "senderId": .string(senderId),
        "senderPlatform": .int(1),
        "contentType": .int(1),
        "content": .object(["text": .string(text ?? "message \(seq)")]),
        "sendTime": .int(now),
        "createTime": .int(now),
    ])
}

/// A wire-shaped conversation row.
func conversationPayload(
    _ conversationId: String,
    maxSeq: Int64,
    readSeq: Int64 = 0,
    updatedAt: Int64? = nil
) -> JSONValue {
    .object([
        "conversationId": .string(conversationId),
        "type": .int(1),
        "maxSeq": .int(maxSeq),
        "readSeq": .int(readSeq),
        "unreadCount": .int(max(maxSeq - readSeq, 0)),
        "pinned": .bool(false),
        "muted": .int(0),
        "updatedAt": .int(updatedAt ?? ImClock.nowMilliseconds()),
    ])
}

/// A wire-shaped `msg.sync` reply covering `range`.
func syncPayload(conversationId: String, range: ClosedRange<Int64>) -> JSONValue {
    .object([
        "conversationId": .string(conversationId),
        "messages": .array(range.map { messagePayload(conversationId: conversationId, seq: $0) }),
        "maxSeq": .int(range.upperBound),
        "minSeq": .int(1),
        "hasMore": .bool(false),
    ])
}

/// Collects the SDK's warnings so a test can assert that the one warning it is supposed to say was
/// said. There are only a handful of them and each one is the only evidence of an otherwise silent
/// failure, so "it warned" is a real assertion rather than a log check.
final class WarningLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var handler: @Sendable (String) -> Void {
        { [self] line in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func contains(_ fragment: String) -> Bool {
        messages.contains { $0.contains(fragment) }
    }
}

/// One scripted reply, so a test can say "this page fails" as easily as "this page has three rows".
enum ScriptedReply: Sendable {
    case data(JSONValue)
    case failure(ImErrorCode, String)
    /// No reply at all — the request times out.
    case silence
}

/// Serves a list of replies to one target, in order, one per request.
///
/// `beforeReply` runs the instant the request arrives and before anything is sent back, which is how
/// an ordering claim like "the adoption write reached the store before the next page was asked for"
/// gets settled rather than asserted after the fact.
final class ScriptedResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let replies: [ScriptedReply]
    private let fallback: ScriptedReply
    private let beforeReply: @Sendable (Int, SentRequest) -> Void

    init(
        _ replies: [ScriptedReply],
        fallback: ScriptedReply = .data(.object([:])),
        beforeReply: @escaping @Sendable (Int, SentRequest) -> Void = { _, _ in }
    ) {
        self.replies = replies
        self.fallback = fallback
        self.beforeReply = beforeReply
    }

    func answer(_ request: SentRequest, _ channel: MockChannel) {
        lock.lock()
        let position = index
        let reply = index < replies.count ? replies[index] : fallback
        index += 1
        lock.unlock()

        beforeReply(position, request)

        switch reply {
        case .data(let payload):
            channel.reply(to: request, data: payload)
        case .failure(let code, let message):
            channel.reply(to: request, code: code, message: message, traceId: "trace-scripted")
        case .silence:
            break
        }
    }

    var served: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }
}
