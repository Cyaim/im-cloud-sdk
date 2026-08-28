import Foundation

// The SDK's own runtime log, and where it lives between launches. See `ADR-003`.
//
// The decision this file implements: **the store belongs to the integrating application**, exactly
// as `ImCursorStore` does. The SDK does not pick a write location, because on iOS that is
// `Documents` or `Library/Caches` — whose backup behaviour differs, and "do chat logs reach iCloud"
// is a question an integrator answers to a regulator rather than one an SDK author should answer
// for them.
//
// 依据 ADR-003：存储属于接入方，与游标存储同理。SDK 不替你选写入位置——
// Documents 与 Library/Caches 的备份行为不同，而「聊天日志会不会进 iCloud」是你要向监管解释的问题。

// MARK: - Line

/// One line of the SDK's own runtime log. `t` is Unix ms.
///
/// Spelled the same way in all five SDKs, so a bundle written by one is legible to whoever opens
/// it, whatever produced it.
public struct ImLogLine: Codable, Sendable, Hashable {
    public var t: Int64
    public var level: String
    public var msg: String

    public init(t: Int64, level: String, msg: String) {
        self.t = t
        self.level = level
        self.msg = msg
    }
}

// MARK: - Store

/// Where the SDK's runtime log lives between launches.
///
/// **Optional, and the default is honest** — unlike ``ImCursorStore``, which has no default. The
/// asymmetry is deliberate: losing cursors loses a user's messages, while losing logs loses a
/// diagnostic. Requiring a store here would make every integration answer a question about a
/// feature most of them will never use.
///
/// Supplying one is what makes "pull a log from that handset" answer questions about anything
/// before the current launch — a crash, a night the app was closed, the reconnect storm at 3am.
/// Supplying none keeps a bounded ring in memory, which answers "what is happening now" completely
/// and "what happened when it crashed" not at all; the console shows which of the two a support
/// engineer is looking at, because a three-minute log and a seven-day log are otherwise identical.
///
/// 不提供也是一个完整的选择：内存环形缓冲只覆盖本次启动——
/// 它完整地回答「现在正在发生什么」，而对「崩的时候发生了什么」一个字也答不出。
///
/// A value type holding three closures rather than a protocol, for the same Swift reason
/// ``ImCursorStore`` is: the contract spells the factory `ImLogStore.inMemory()`, and a protocol's
/// own name cannot carry static members.
public struct ImLogStore: Sendable {
    /// True only for the store ``inMemory()`` builds.
    ///
    /// Internal on purpose, and the reason is the same one that made ``ImCursorStore/isVolatile``
    /// internal: a public flag would let *any* store — including one written over Core Data —
    /// announce itself persistent, and the only thing that answer drives is whether a support
    /// engineer is told the log they are reading covers three minutes or three weeks. A store that
    /// can lie about that is a store that can make somebody conclude nothing went wrong.
    /// 由 SDK 按身份判断而不是由存储自称：能自称持久的存储，也能让人得出「什么都没发生」的结论。
    let isVolatile: Bool

    private let _append: @Sendable ([ImLogLine]) async throws -> Void
    private let _read: @Sendable () async throws -> [ImLogLine]
    private let _clear: @Sendable () async throws -> Void

    public init(
        append: @escaping @Sendable ([ImLogLine]) async throws -> Void,
        read: @escaping @Sendable () async throws -> [ImLogLine],
        clear: @escaping @Sendable () async throws -> Void
    ) {
        self.isVolatile = false
        self._append = append
        self._read = read
        self._clear = clear
    }

    init(
        volatileAppend: @escaping @Sendable ([ImLogLine]) async throws -> Void,
        volatileRead: @escaping @Sendable () async throws -> [ImLogLine],
        volatileClear: @escaping @Sendable () async throws -> Void
    ) {
        self.isVolatile = true
        self._append = volatileAppend
        self._read = volatileRead
        self._clear = volatileClear
    }

    /// Appends lines. May coalesce, and may drop the oldest to stay within its own bound.
    ///
    /// **Throwing is handled, never fatal.** A broken store must not take down a client that is
    /// otherwise chatting happily: logging is a diagnostic feature, so its failure has to cost less
    /// than the thing it serves.
    public func append(_ lines: [ImLogLine]) async throws {
        try await _append(lines)
    }

    /// Everything currently held, oldest first.
    public func read() async throws -> [ImLogLine] {
        try await _read()
    }

    /// Called after a successful upload. A store that ignores this is allowed but will grow.
    public func clear() async throws {
        try await _clear()
    }

    // MARK: Provided implementations

    /// Loses everything on relaunch. The default, and an honest one.
    ///
    /// - Parameter capacity: lines kept before the oldest are dropped. Bounded on lines rather than
    ///   bytes because a line is what a reader counts, and a byte cap truncates the middle of the
    ///   sentence somebody is trying to read.
    public static func inMemory(capacity: Int = 2000) -> ImLogStore {
        let box = LineBox(capacity: capacity)

        return ImLogStore(
            volatileAppend: { await box.append($0) },
            volatileRead: { await box.read() },
            volatileClear: { await box.clear() }
        )
    }

    /// A single file, rotated once at `maxBytes`.
    ///
    /// **Provided but not the default**, and the difference matters: choosing this is you saying
    /// where your users' runtime detail may be written, and deciding separately whether that
    /// directory is backed up. `Library/Caches` is the usual answer for a log — the system may
    /// reclaim it, which for a diagnostic is acceptable and for a cursor would not be.
    /// 提供但不是默认：选它，是你在说「我的用户的运行细节可以写在这里」。
    ///
    /// Two files rather than one, because a single file truncated at the limit loses the tail —
    /// and the tail is the failure being investigated.
    /// 两个文件而不是一个：单文件到限就截断会丢掉尾巴，而尾巴正是故障本身。
    public static func file(at url: URL, maxBytes: Int = 2 * 1024 * 1024) -> ImLogStore {
        let box = FileBox(url: url, maxBytes: maxBytes)

        return ImLogStore(
            append: { try await box.append($0) },
            read: { try await box.read() },
            clear: { try await box.clear() }
        )
    }
}

private actor LineBox {
    private let capacity: Int
    private var lines: [ImLogLine] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func append(_ incoming: [ImLogLine]) {
        lines.append(contentsOf: incoming)
        // The newest are what a support engineer needs: the failure is at the end of the log.
        // 保留最新的：故障在日志末尾。
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }

    func read() -> [ImLogLine] { lines }

    func clear() { lines.removeAll() }
}

private actor FileBox {
    private let url: URL
    private let previous: URL
    private let maxBytes: Int

    init(url: URL, maxBytes: Int) {
        self.url = url
        self.previous = url.appendingPathExtension("1")
        self.maxBytes = maxBytes
    }

    func append(_ lines: [ImLogLine]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if let size = try? manager.attributesOfItem(atPath: url.path)[.size] as? Int, size >= maxBytes {
            try? manager.removeItem(at: previous)
            try? manager.moveItem(at: url, to: previous)
        }

        let text = lines.map { "\($0.t)\t\($0.level)\t\(Self.escape($0.msg))\n" }.joined()
        guard let data = text.data(using: .utf8) else { return }

        if manager.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    func read() throws -> [ImLogLine] {
        try Self.readOne(previous) + Self.readOne(url)
    }

    func clear() throws {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: previous)
    }

    private static func readOne(_ url: URL) throws -> [ImLogLine] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        return text.split(separator: "\n").compactMap { row in
            let parts = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let at = Int64(parts[0]) else { return nil }
            return ImLogLine(t: at, level: String(parts[1]), msg: unescape(String(parts[2])))
        }
    }

    // Newlines and tabs are escaped rather than forbidden: a log line very often carries a stack
    // trace, and a format that silently split one across records would make traces unreadable
    // exactly when they matter.
    // 转义而不是禁止：日志行里常常是一段堆栈，而会把它拆开的格式，恰在最要紧时让堆栈读不懂。
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

// MARK: - Sink

/// Buffers the SDK's own lines and hands them to the store.
///
/// **Buffered rather than written through**, because the events worth logging arrive in bursts — a
/// reconnect storm writes a dozen lines in as many milliseconds — and a file-backed store would be
/// asked for a dozen round trips to record one incident.
/// 带缓冲而不是直写：值得记的事件是成串来的，而落在文件上的存储会为一次事故被要求往返十几次。
/// Named `ImLogRecorder` rather than `ImLog`, which is already the SDK's one-line warning helper
/// in `ImSdk.swift`. The two are different things and both are worth having: that one shouts at a
/// developer now, this one records for a support engineer later.
/// 与 ImSdk.swift 里那个一行式告警助手区分开：那个是现在冲开发者喊，这个是留给之后的支持工程师读。
public actor ImLogRecorder {
    private let store: ImLogStore
    private let warn: (@Sendable (String) -> Void)?
    private var pending: [ImLogLine] = []
    private var storeFailed = false
    private var warned = false

    init(store: ImLogStore, warningHandler: (@Sendable (String) -> Void)? = nil) {
        self.store = store
        self.warn = warningHandler
    }

    /// True when the store is the in-memory one, so the log covers this launch only.
    public nonisolated var isVolatile: Bool { store.isVolatile }

    /// True once an append or a read has thrown. Surfaced so a misconfigured store is findable.
    public var failedToWrite: Bool { storeFailed }

    /// Adds a line. Applications may call this: the SDK cannot see what the *user* was doing when
    /// something went wrong, and that is usually the half that makes a log worth reading.
    /// 应用可以调用它：SDK 看不见用户当时在做什么，而那往往是让日志值得读的那一半。
    public func write(_ level: String, _ message: String) async {
        pending.append(ImLogLine(t: Int64(Date().timeIntervalSince1970 * 1000), level: level, msg: message))

        if pending.count >= 32 {
            await flush()
        }
    }

    public func flush() async {
        guard !pending.isEmpty else { return }

        let batch = pending
        pending = []

        do {
            try await store.append(batch)
        } catch {
            // Deliberately swallowed. A store that cannot be written to is a diagnostic problem,
            // and raising it here would put a logging failure in the path of whatever was being
            // logged — very often an error the application actually needs to see.
            // 刻意吞掉：在这里抛出，会把一次日志失败插进正在被记录的那件事的路径上。
            noteFailure(error)
        }
    }

    /// Everything the store holds, oldest first. Flushes first so the tail is not missing.
    public func read() async -> [ImLogLine] {
        await flush()

        do {
            return try await store.read()
        } catch {
            noteFailure(error)
            return []
        }
    }

    public func clear() async {
        pending = []
        do {
            try await store.clear()
        } catch {
            noteFailure(error)
        }
    }

    /// Says it once, out loud, the first time the store refuses.
    ///
    /// Once because a store that fails once fails every time, and a warning per line would bury the
    /// application's own output. Out loud at all because the alternative is an integrator finding
    /// out when a support engineer asks for a log and gets an empty one — which reads as "nothing
    /// happened on that device" rather than as "the store was never writable".
    /// 只说一次：会失败的存储每次都失败，逐行告警会淹掉应用自己的输出。
    /// 而完全不说的代价是：接入方要等到有人来要日志、拿到一份空的，才知道存储从来就写不进去。
    private func noteFailure(_ error: Error) {
        storeFailed = true

        guard !warned else { return }
        warned = true

        ImLog.warn(
            "the log store refused a write (\(error)). Device-log requests from the console will "
                + "come back empty, which reads as 'nothing happened on that device'. See ADR-003.",
            using: warn
        )
    }
}

/// Renders lines as the text file a support engineer opens.
///
/// Plain text, one line each, ISO timestamps — not JSON. Whoever reads this is reading it in a
/// viewer, often on a phone, and the first thing they do is search it for a word.
/// 纯文本而不是 JSON：读它的人在查看器里读、常常在手机上，而他做的第一件事是搜一个词。
func renderLogBundle(_ lines: [ImLogLine]) -> String {
    let formatter = ISO8601DateFormatter()

    return lines
        .map { line in
            let stamp = formatter.string(from: Date(timeIntervalSince1970: Double(line.t) / 1000))
            let level = line.level.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)
            return "\(stamp) \(level) \(line.msg)"
        }
        .joined(separator: "\n")
}
