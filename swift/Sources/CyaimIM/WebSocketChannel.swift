import Foundation

// `URLSession` and friends live in `FoundationNetworking` on the swift-corelibs platforms (Linux,
// Windows) and directly in `Foundation` on Apple's. The SDK targets Apple platforms, but the test
// suite has to run somewhere a Mac is not, and this is the whole cost of that.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Transport abstraction

/// One open WebSocket, reduced to the four things the connection layer needs.
///
/// The protocol exists so that reconnect behaviour, kick handling and gap repair can be tested
/// without a server: those are the parts that are hard to get right and impossible to verify
/// against a live gateway on CI. `URLSessionWebSocketChannel` is the only implementation that ships.
public protocol ImWebSocketChannel: Sendable {
    /// Sends one text frame.
    func send(_ text: String) async throws

    /// Waits for the next text frame.
    ///
    /// Throws `ImWebSocketClose` when the peer closed — carrying the close reason, which is the
    /// only way to tell a kick from a dead network — and any other error when the socket failed.
    func receive() async throws -> String

    /// Closes locally. `code` is a WebSocket close code; 4000-4999 are application-defined.
    func close(code: Int, reason: String)
}

/// Opens channels. Injected so tests can stand in for the network.
public protocol ImWebSocketConnector: Sendable {
    /// Performs the HTTP upgrade and returns once the socket is usable.
    func connect(to url: URL) async throws -> any ImWebSocketChannel
}

/// The peer closed the socket.
public struct ImWebSocketClose: Error, Sendable, Hashable {
    public let code: Int

    /// The close reason, verbatim. The gateway writes `im-kick:{Reason}` here when it is evicting
    /// this connection on purpose.
    public let reason: String?

    public init(code: Int, reason: String?) {
        self.code = code
        self.reason = reason
    }
}

/// The HTTP upgrade itself was refused, so there never was a socket.
///
/// Worth distinguishing from a dropped connection: 401 means the token is stale and the host app
/// can fix it, 403 means it never will be, and reconnecting on a loop in either case is just load
/// with no upside.
public struct ImWebSocketHandshakeError: Error, Sendable {
    public let statusCode: Int?
    public let underlying: (any Error)?

    public init(statusCode: Int?, underlying: (any Error)?) {
        self.statusCode = statusCode
        self.underlying = underlying
    }
}

// MARK: - URLSession implementation

/// Opens `URLSessionWebSocketTask` channels.
public struct URLSessionWebSocketConnector: ImWebSocketConnector {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration

    /// - Parameter configuration: called once per socket. It is a closure rather than a stored
    ///   configuration because `URLSessionConfiguration` is a mutable reference type and therefore
    ///   not `Sendable`; handing out a fresh one per connection also keeps a reconnect from
    ///   inheriting the previous socket's state.
    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { URLSessionWebSocketConnector.defaultConfiguration() }) {
        self.makeConfiguration = configuration
    }

    /// - `waitsForConnectivity` is off on purpose. Letting URLSession park the request until the
    ///   radio comes back would hide the failure from the SDK's own backoff, and then a fleet
    ///   coming back from an outage is scheduled by URLSession — which does not jitter — instead of
    ///   by us.
    /// - The request timeout is short because a gateway that has not completed a handshake in
    ///   fifteen seconds is not going to.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        #if canImport(Darwin)
        // Read-only on the corelibs platforms, where URLSession does not park requests for
        // connectivity in the first place — so there is nothing to switch off there.
        configuration.waitsForConnectivity = false
        #endif
        configuration.timeoutIntervalForRequest = 15
        configuration.httpShouldUsePipelining = false
        return configuration
    }

    public func connect(to url: URL) async throws -> any ImWebSocketChannel {
        let channel = URLSessionWebSocketChannel(url: url, configuration: makeConfiguration())
        try await channel.open()
        return channel
    }
}

/// A `URLSessionWebSocketTask` behind `ImWebSocketChannel`.
///
/// The delegate exists for one reason: `URLSessionWebSocketTask` reports the peer's close code and
/// reason to `didCloseWith`, and by the time `receive()` throws, that reason is the difference
/// between reconnecting and not. `receive()` alone gives an opaque `NSError`.
public final class URLSessionWebSocketChannel: NSObject, ImWebSocketChannel, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var openContinuation: CheckedContinuation<Void, any Error>?
    private var recordedClose: ImWebSocketClose?
    private var isOpen = false
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    init(url: URL, configuration: URLSessionConfiguration) {
        super.init()

        // A serial delegate queue: close and completion callbacks must not race each other, and
        // the continuation handshake below assumes they do not.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.cyaim.im.websocket"

        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        self.task = session.webSocketTask(with: url)
    }

    deinit {
        // URLSession holds its delegate — this object — until it is invalidated. Skipping this is
        // the classic way to leak one session per reconnect for the lifetime of the app.
        session?.invalidateAndCancel()
    }

    /// The live task, or the reason there is not one.
    ///
    /// Synchronous on purpose. `NSLock` is `noasync` on the corelibs platforms, so every lock/unlock
    /// pair has to sit inside a non-`async` function rather than straddling an `await` — which is
    /// the rule this code already followed by hand, now enforced by the compiler.
    private func liveTask() throws -> URLSessionWebSocketTask {
        lock.lock()
        let task = self.task
        let closed = recordedClose
        lock.unlock()

        if let closed { throw closed }
        guard let task else { throw ImWebSocketClose(code: 1006, reason: nil) }
        return task
    }

    /// Resumes the task and waits for the upgrade to complete or fail.
    ///
    /// Awaiting the handshake, rather than returning as soon as the task is resumed, is what lets
    /// `connect()` mean "connected" — including a 401 from the gateway's `BeforeConnectionEvent`,
    /// which is how a stale token presents itself.
    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()

            if let recordedClose {
                lock.unlock()
                continuation.resume(throwing: recordedClose)
                return
            }

            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }

            openContinuation = continuation
            let task = self.task
            lock.unlock()

            task?.resume()
        }
    }

    public func send(_ text: String) async throws {
        let task = try liveTask()
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        while true {
            let task = try liveTask()

            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                throw translate(error, task: task)
            }

            switch message {
            case .string(let text):
                return text
            case .data(let data):
                // The channel negotiates JSON, so a binary frame is either a proxy repacking text
                // or a protocol the app opted into elsewhere. Decode what can be decoded and skip
                // what cannot, rather than tearing down a working socket over one frame.
                if let text = String(data: data, encoding: .utf8) {
                    return text
                }
                continue
            @unknown default:
                continue
            }
        }
    }

    public func close(code: Int, reason: String) {
        lock.lock()
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        if recordedClose == nil {
            recordedClose = ImWebSocketClose(code: code, reason: reason)
        }
        lock.unlock()

        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task?.cancel(with: closeCode, reason: Data(reason.utf8))
        session?.finishTasksAndInvalidate()
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocolName: String?
    ) {
        lock.lock()
        isOpen = true
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()

        continuation?.resume()
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let close = ImWebSocketClose(
            code: closeCode.rawValue,
            reason: reason.flatMap { String(data: $0, encoding: .utf8) }
        )

        lock.lock()
        if recordedClose == nil { recordedClose = close }
        let continuation = openContinuation
        openContinuation = nil
        lock.unlock()

        continuation?.resume(throwing: close)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // Fires for every completion, including a clean close that `didCloseWith` already handled.
        // Only a handshake still waiting on `open()` cares.
        lock.lock()
        let continuation = openContinuation
        openContinuation = nil
        let alreadyOpen = isOpen
        lock.unlock()

        guard let continuation else { return }

        let status = (task.response as? HTTPURLResponse)?.statusCode
        if alreadyOpen, let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(throwing: ImWebSocketHandshakeError(statusCode: status, underlying: error))
        }
    }

    // MARK: Internals

    /// Turns whatever `receive()` threw into the most specific thing known about it.
    private func translate(_ error: any Error, task: URLSessionWebSocketTask) -> any Error {
        lock.lock()
        let recorded = recordedClose
        lock.unlock()

        if let recorded { return recorded }

        let closeCode = task.closeCode
        if closeCode != .invalid {
            return ImWebSocketClose(
                code: closeCode.rawValue,
                reason: task.closeReason.flatMap { String(data: $0, encoding: .utf8) }
            )
        }

        return error
    }
}
