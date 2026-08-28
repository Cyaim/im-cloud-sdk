import Foundation

/// Fan-out to any number of `AsyncStream` subscribers.
///
/// `AsyncStream` is single-consumer by design, but every one of these signals has more than one
/// natural consumer: a conversation view and a badge counter both want messages, a connection
/// banner and an analytics hook both want state. So each subscriber gets its own stream and this
/// object yields to all of them.
///
/// It is a lock-guarded class rather than actor state so that `subscribe()` needs no `await` — a
/// SwiftUI `.task { for await … }` should not have to hop an actor just to start listening — and so
/// that a stream's `onTermination` can unregister itself directly instead of scheduling a task that
/// may outlive the object.
final class Broadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private var latest: Element?
    private var isFinished = false
    private let replaysLatest: Bool

    /// - Parameter replaysLatest: deliver the most recent value to a new subscriber immediately.
    ///   Used for connection state, where a subscriber that joins after the socket opened still
    ///   needs to know that it is open.
    init(replaysLatest: Bool = false) {
        self.replaysLatest = replaysLatest
    }

    /// A new stream carrying every element yielded from now on.
    ///
    /// The default policy is unbounded because dropping is not an option for messages: the whole
    /// point of the gap-repair loop upstream is that the application sees every seq exactly once,
    /// and a buffer that quietly discards would undo it. Signals where only the newest value
    /// matters pass a bounded policy explicitly.
    func subscribe(
        bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded
    ) -> AsyncStream<Element> {
        AsyncStream(Element.self, bufferingPolicy: bufferingPolicy) { continuation in
            let id = UUID()

            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.finish()
                return
            }
            continuations[id] = continuation
            let replay = replaysLatest ? latest : nil
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }

            if let replay {
                continuation.yield(replay)
            }
        }
    }

    func yield(_ element: Element) {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        if replaysLatest {
            latest = element
        }
        let targets = Array(continuations.values)
        lock.unlock()

        // Yielding outside the lock: a consumer resumed by `yield` must never be able to re-enter
        // this object while it is held.
        for continuation in targets {
            continuation.yield(element)
        }
    }

    /// Ends every subscriber's stream. Terminal — later subscribers get an empty stream.
    func finish() {
        lock.lock()
        isFinished = true
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()

        for continuation in targets {
            continuation.finish()
        }
    }

    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}

/// The per-target registry of push subscribers.
///
/// Hubs are created on demand and kept: an app that subscribes to `evt.typing` once will subscribe
/// again after a view is recreated, and the number of distinct targets is small and bounded by the
/// protocol.
final class EventHubRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var hubs: [String: Broadcaster<ImFrame>] = [:]

    func hub(for target: String) -> Broadcaster<ImFrame> {
        lock.lock()
        defer { lock.unlock() }

        if let existing = hubs[target] {
            return existing
        }

        let created = Broadcaster<ImFrame>()
        hubs[target] = created
        return created
    }

    /// Delivers a frame to the subscribers of its target, if any. Unsubscribed pushes are dropped
    /// here rather than buffered forever.
    func publish(_ frame: ImFrame) {
        lock.lock()
        let hub = hubs[frame.target]
        lock.unlock()

        hub?.yield(frame)
    }

    func finishAll() {
        lock.lock()
        let all = Array(hubs.values)
        hubs.removeAll()
        lock.unlock()

        for hub in all {
            hub.finish()
        }
    }
}
