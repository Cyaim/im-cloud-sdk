import Foundation

// Cold-start cursors. See sdk/CONTRACT.md §5, which this file implements literally.
//
// The bug this exists to kill: a client that restarts, does not report what it already holds, and
// therefore adopts the server's newest seq. Every message that arrived while the app was closed is
// then behind the cursor — never requested, never delivered, no error, no log line, no later event
// that corrects it. Four of the five SDKs shipped that; this one did not, but only because an
// integrator who noticed `seed(_:)` wired it up by hand. Nothing forced them to. This file is what
// forces them to.
//
// 冷启动游标。四个 SDK 会在冷启动时把游标重置到服务端最新 seq，关闭期间到达的消息就此永久丢失，
// 且没有任何错误或日志。本文件把"持久化"变成构造时必须回答的问题，而不是一个可以忘掉的可选项。

// MARK: - Snapshot

/// Everything one launch needs to hand the next one.
///
/// `convSeqs` holds **committed** seqs — what the application has told the SDK it has durably
/// stored — never what merely reached its memory. That distinction is the whole of §5.2, and
/// reporting the wrong one is what four SDKs did.
public struct ImCursorSnapshot: Codable, Sendable, Hashable {
    /// conversationId -> highest seq the application has durably stored.
    public var convSeqs: [String: Int64]

    /// Largest `ConversationView.updatedAt` from a **completed** `conn.sync` run.
    ///
    /// Only a completed run may advance it. The conversation list is sorted by `updatedAt`
    /// descending, so page 1 holds the newest timestamp: a client that takes the maximum from
    /// page 1 and stops has pushed this value past every conversation on pages 2…N, and the server
    /// will never return them again.
    public var conversationCursor: Int64

    /// Which ``ImCursorScope`` these cursors belong to, as ``ImCursorScope/key``. Stamped by the
    /// SDK on every write.
    ///
    /// **This field is the account-switch guarantee, and it lives in the payload rather than in the
    /// store's signature on purpose.** A store is a few lines an integrator writes; a store that
    /// keys itself per account is a few lines an integrator *remembers* to write. Carrying the
    /// identity here means the SDK can refuse cursors belonging to somebody else even when the
    /// store did nothing to keep two accounts apart — so an app that does nothing special cannot
    /// get it wrong.
    ///
    /// `nil` on a snapshot the SDK has never written. That is accepted, and the next save stamps it.
    public var scope: String?

    public init(convSeqs: [String: Int64] = [:], conversationCursor: Int64 = 0, scope: String? = nil) {
        self.convSeqs = convSeqs
        self.conversationCursor = conversationCursor
        self.scope = scope
    }

    public static let empty = ImCursorSnapshot()

    public var isEmpty: Bool { convSeqs.isEmpty && conversationCursor == 0 }

    enum CodingKeys: String, CodingKey {
        case convSeqs, conversationCursor, scope
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        convSeqs = (try? container.decodeIfPresent([String: Int64].self, forKey: .convSeqs)) ?? [:]
        conversationCursor = (try? container.decodeIfPresent(Int64.self, forKey: .conversationCursor)) ?? 0
        scope = try? container.decodeIfPresent(String.self, forKey: .scope)
    }
}

// MARK: - Scope

/// What a set of cursors belongs to: `(endpoint host, appId, userId)`.
///
/// Not the device id — the store is already local to the device. `userId` is in there because
/// without it, two accounts on one handset share one file, and signing in as the second user hands
/// it the first user's cursors: every conversation looks already-read up to somebody else's seq.
///
/// 作用域键里必须有 userId：同一台设备上换账号时，否则会把上一个账号的游标交给下一个账号。
public struct ImCursorScope: Sendable, Hashable {
    public var host: String
    public var appId: String
    public var userId: String

    public init(host: String, appId: String, userId: String) {
        self.host = host
        self.appId = appId
        self.userId = userId
    }

    /// The usual construction: the same endpoint URL the client connects to.
    public init(endpoint: URL, appId: String, userId: String) {
        self.init(host: endpoint.host ?? endpoint.absoluteString, appId: appId, userId: userId)
    }

    /// The identity stamped into ``ImCursorSnapshot/scope`` and compared on load:
    /// `host|appId|userId`. Spelled the same way in all five SDKs, so a snapshot written by one is
    /// legible to the others.
    public var key: String {
        "\(host)|\(appId)|\(userId.isEmpty ? "*" : userId)"
    }

    /// The same identity, safe as a file name on every platform.
    ///
    /// Every component is escaped rather than hashed: a support engineer looking at a device's
    /// container should be able to read which account a file belongs to without a lookup table.
    public var storageKey: String {
        "\(Self.escape(host))_\(Self.escape(appId))_\(Self.escape(userId))"
    }

    /// A filesystem-safe file name for this scope.
    public var fileName: String {
        "\(storageKey).cursors.json"
    }

    private static func escape(_ value: String) -> String {
        let safe = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "." ? Character(scalar) : "_"
        }
        return String(safe)
    }
}

// MARK: - Store

/// Where cursors live between launches.
///
/// **Required.** ``ImClientOptions`` takes one with no default, and an integrator who genuinely
/// does not want persistence passes ``inMemory()`` and gets one warning naming §5.3. Defaulting to
/// no persistence is what produced the data-loss bug; defaulting to *some* persistence would mean
/// guessing where an app is allowed to write, and a wrong guess about that is worse than a compile
/// error.
///
/// **Lifetime.** The cursor store and your own message store have exactly one lifetime. Whatever
/// destroys one destroys the other, and in that order — cursors first. Clearing messages while
/// keeping cursors shows an empty conversation that will never refill; keeping messages while
/// clearing cursors costs a full re-download and duplicate delivery.
///
/// **Exactly two members, `load()` and `save(_:)`, as §5.3 specifies** — the same pair the other
/// four SDKs expose. There is no `scope` parameter and no persistence flag: the account identity
/// travels inside ``ImCursorSnapshot/scope``, which the SDK stamps and checks, and whether a store
/// is volatile is the SDK's judgement rather than the store's claim (see ``inMemory()``).
///
/// A value type holding two closures rather than a protocol, for one reason, and it is a Swift
/// limitation rather than a design choice: the contract spells the factories
/// `ImCursorStore.inMemory()` and `ImCursorStore.applicationSupport(subdirectory:scope:)`, and a
/// Swift protocol's own name cannot carry static members — `ImCursorStore.inMemory()` would not
/// compile against `protocol ImCursorStore`. Renaming the protocol so an enum could hold the
/// factories would diverge from the other four in the name, which is the thing worth keeping.
/// Conforming stores are still easy: ``init(load:save:)`` takes any pair of closures, which is how
/// the test suite substitutes a store that throws.
public struct ImCursorStore: Sendable {
    /// True only for the store ``inMemory()`` builds.
    ///
    /// Internal on purpose. It used to be a public `isPersistent` on the initialiser, so *any*
    /// store — including one an integrator wrote over Core Data — could announce itself volatile;
    /// and the only thing that answer drives is the one warning standing between a misconfigured
    /// client and a support ticket about missing history. Three of the five SDKs had that hole.
    let isVolatile: Bool

    private let _load: @Sendable () async throws -> ImCursorSnapshot
    private let _save: @Sendable (ImCursorSnapshot) async throws -> Void

    public init(
        load: @escaping @Sendable () async throws -> ImCursorSnapshot,
        save: @escaping @Sendable (ImCursorSnapshot) async throws -> Void
    ) {
        self.isVolatile = false
        self._load = load
        self._save = save
    }

    /// The volatile variant, reachable only from ``inMemory()``.
    init(
        volatileLoad: @escaping @Sendable () async throws -> ImCursorSnapshot,
        volatileSave: @escaping @Sendable (ImCursorSnapshot) async throws -> Void
    ) {
        self.isVolatile = true
        self._load = volatileLoad
        self._save = volatileSave
    }

    /// Called once, before the first connect.
    ///
    /// Throwing is meaningful: the SDK treats a failed load as "unknown", not as "empty". It
    /// surfaces ``ImSessionEvent/cursorStoreUnavailable(_:)``, refuses to adopt, and refuses to
    /// advance any cursor for the session, because a failed load and a fresh install are
    /// indistinguishable to the adoption branch and adopting on a failed load destroys history that
    /// is sitting intact in the application's own database.
    public func load() async throws -> ImCursorSnapshot {
        try await _load()
    }

    /// Called by the SDK. May be coalesced — see ``ImClientOptions/cursorFlushInterval`` — except
    /// for an adoption write, which is flushed synchronously.
    public func save(_ snapshot: ImCursorSnapshot) async throws {
        try await _save(snapshot)
    }

    // MARK: Provided implementations

    /// Nothing survives the process. An explicit choice, never a default.
    ///
    /// The client logs one warning naming §5.3 and emits ``ImSessionEvent/cursorsNotPersisted`` on
    /// the first connect, so "we forgot to configure a store" is visible in a log rather than in a
    /// bug report about missing messages six weeks later.
    public static func inMemory() -> ImCursorStore {
        let box = SnapshotBox()

        return ImCursorStore(
            volatileLoad: { box.read() },
            volatileSave: { box.write($0) }
        )
    }

    /// A JSON file at an exact URL. Foundation only; the app picks the directory.
    ///
    /// Writes are atomic (`Data.WritingOptions.atomic`), so a process killed mid-save leaves the
    /// previous snapshot intact rather than a truncated one — and a truncated snapshot would decode
    /// as a load failure, which is the one outcome §5.8 has to work hard to survive.
    /// **Put the user id in the URL** if two accounts can sign in on one device. Point both at one
    /// file and the SDK notices — the snapshot carries its scope — and starts clean rather than
    /// handing the second user the first one's cursors; but the first account's cursors are gone
    /// once the second one writes, and it re-downloads on its next login.
    /// ``applicationSupport(subdirectory:scope:)`` does that naming for you.
    public static func file(at url: URL) -> ImCursorStore {
        let writer = FileWriter(url: url)

        return ImCursorStore(
            load: { try writer.read() },
            save: { try writer.write($0) }
        )
    }

    /// A JSON file under Application Support, named for the scope.
    ///
    /// `~/Library/Application Support/<subdirectory>/<host>_<appId>_<userId>.cursors.json`, which
    /// on iOS is inside the app container and is backed up with it — correct, because these
    /// cursors describe a message store that is backed up too. If your message store is *not*
    /// backed up, put both in Caches with ``file(at:)`` and keep the two lifetimes together.
    public static func applicationSupport(
        subdirectory: String = "CyaimIM",
        scope: ImCursorScope
    ) throws -> ImCursorStore {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        let directory = root.appendingPathComponent(subdirectory, isDirectory: true)
        let writer = FileWriter(url: directory.appendingPathComponent(scope.fileName, isDirectory: false))

        return ImCursorStore(
            load: { try writer.read() },
            save: { try writer.write($0) }
        )
    }

    // MARK: Internals

    /// The in-memory store's one slot. A lock-guarded class so the store stays a `Sendable` value.
    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot = ImCursorSnapshot.empty

        func read() -> ImCursorSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return snapshot
        }

        func write(_ value: ImCursorSnapshot) {
            lock.lock()
            snapshot = value
            lock.unlock()
        }
    }

    /// Serialises file access, so an adoption flush and a debounced save cannot interleave halfway
    /// through a write.
    private final class FileWriter: @unchecked Sendable {
        private let lock = NSLock()
        private let url: URL

        init(url: URL) {
            self.url = url
        }

        func read() throws -> ImCursorSnapshot {
            lock.lock()
            defer { lock.unlock() }

            // A file that is not there yet is a fresh install, which is the one case where an empty
            // snapshot is the honest answer. Anything else — unreadable, corrupt, wrong shape —
            // throws, and §5.8 takes over.
            guard FileManager.default.fileExists(atPath: url.path) else { return .empty }

            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ImCursorSnapshot.self, from: data)
        }

        func write(_ snapshot: ImCursorSnapshot) throws {
            lock.lock()
            defer { lock.unlock() }

            let directory = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        }
    }
}
