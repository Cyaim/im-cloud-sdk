import Foundation

/// Everything the client needs to open a connection and keep it open.
public struct ImClientOptions: Sendable {
    /// Gateway base URL, e.g. `wss://im.example.com`. `https`/`http` are rewritten to `wss`/`ws`,
    /// because the two get mixed up constantly and the failure is a silent one.
    public var endpoint: URL

    /// Channel path appended to `endpoint`. Only change this if the tenant's gateway is mounted
    /// somewhere other than `/im`.
    public var channelPath: String

    /// Tenant identifier. Safe to ship in the app; the `AppSecret` never is.
    public var appId: String

    /// Short-lived user token minted by the tenant's backend. Never an app secret.
    public var token: String

    /// Stable per-installation identifier.
    ///
    /// The multi-device policy uses this to tell a reconnect apart from a second device. A value
    /// regenerated per launch makes users kick themselves offline, so persist it in the keychain
    /// (not `UserDefaults`, which is wiped by a reinstall while the keychain is not).
    public var deviceId: String

    /// The signed-in user. **Required.**
    ///
    /// Not sent in the handshake — the gateway reads the identity out of the token — but the third
    /// component of the cursor store's scope, `(endpoint host, appId, userId)`, and the one that
    /// stops account switching on a shared device from handing one user another's cursors
    /// (§5.3). Your backend already knows the value: it is the user it just minted a token for.
    public var userId: String

    public var platform: Platform

    /// Your app's version, surfaced in the console's session list. Worth setting: it is how you
    /// find out that a bug only happens on a build you shipped three releases ago.
    public var clientVersion: String?

    /// BCP-47 language tag. The server localises system messages and push copy with it.
    public var language: String?

    /// How long an unanswered request waits before it throws `ImError(code: .timeout)`.
    public var requestTimeout: Duration

    /// Starting heartbeat cadence, used only until the server states its own in the first reply.
    public var heartbeatInterval: Duration

    /// Reconnect delay policy. Full jitter; see `FullJitterBackoff`.
    public var backoff: FullJitterBackoff

    /// Largest gap the client repairs message by message.
    ///
    /// Past this, the conversation is too far behind to backfill: both cursors jump to the newest
    /// seq, the SDK raises ``ImSessionEvent/conversationNeedsReload(conversationId:fromSeq:toSeq:)``,
    /// and the app re-opens the conversation from history instead. Replaying fifty thousand
    /// messages into a UI helps nobody, and doing it on a phone on cellular helps less.
    ///
    /// Raising this above 500 does not buy a bigger single `msg.sync` — the server clamps that to
    /// 500 — it buys more iterations of the repair loop, which is fine and intended.
    public var maxAutoRepairSeq: Int64

    /// Where cursors live between launches. **Required, with no default.**
    ///
    /// There is no implicit default because defaulting to no persistence is exactly what produced
    /// the cold-start data-loss bug in four of the five SDKs, and defaulting to *some* persistence
    /// would mean the SDK guessing where your app is allowed to write. A compile error is the
    /// cheapest possible place to have this conversation. Pass ``ImCursorStore/inMemory()`` if you
    /// really do not want persistence; you get one warning and nothing else.
    ///
    /// 没有默认值：默认不持久化正是那个静默丢消息的 bug，而默认某种持久化等于替应用猜它能往哪写。
    public var cursorStore: ImCursorStore

    /// How long an ordinary commit may sit before the store is asked to save. Floor 0, no ceiling.
    ///
    /// A flush always happens before `conn.sync` regardless, and an *adoption* write is never
    /// debounced at all. The asymmetry is the point: a lost debounced commit costs one duplicate
    /// delivery, while a lost adoption write costs silent permanent data loss.
    public var cursorFlushInterval: Duration

    /// How many `msg.sync` pages one repair may take before it gives up and declares the gap
    /// oversized instead. Guards against a server that always reports `hasMore`.
    public var maxRepairPages: Int

    /// How many `conn.sync` pages one resume may take. At the default page size of 200 this is
    /// 20,000 conversations, which is well past any real account and still bounded.
    public var maxResumePages: Int

    /// Where the SDK's handful of warnings go. `nil` writes them to standard error.
    ///
    /// There are only a few, they are all one-per-session, and every one names the section of the
    /// contract behind it — because each warns about something that is otherwise completely silent.
    public var warningHandler: (@Sendable (String) -> Void)?

    /// Called when the server reports the token has expired, and when the gateway refuses the
    /// upgrade with 401.
    ///
    /// Return a fresh token from your backend to reconnect, or `nil` to stop trying — `nil` is the
    /// right answer when the user has been signed out of your app entirely.
    public var tokenProvider: (@Sendable () async -> String?)?

    /// Where the SDK's own runtime log lives between launches. **Optional, and the default is honest.**
    ///
    /// Unlike ``cursorStore`` this has a default, and the asymmetry is deliberate: losing cursors
    /// loses a user's messages, while losing logs loses a diagnostic. Supplying one is what makes
    /// "pull a log from that handset" answer questions about anything before the current launch — a
    /// crash, a night the app was closed, the reconnect storm at 3am. Supplying none keeps a bounded
    /// ring in memory, and the console shows a support engineer which of the two they are reading.
    ///
    /// The SDK does not pick a location for you — see `ADR-003`. On iOS that would be `Documents`
    /// or `Library/Caches`, whose backup behaviour differs, and "do chat logs reach iCloud" is a
    /// question you answer to a regulator. ``ImLogStore/file(at:maxBytes:)`` is there for when you
    /// have made that decision.
    ///
    /// SDK 不替你选写入位置：不提供也是一个完整的选择，而控制台会把这个区别显示出来。
    public var logStore: ImLogStore

    /// Transport factory. The default opens a `URLSessionWebSocketTask`; tests substitute their own.
    public var connector: any ImWebSocketConnector

    public init(
        endpoint: URL,
        appId: String,
        token: String,
        deviceId: String,
        userId: String,
        cursorStore: ImCursorStore,
        platform: Platform = .current,
        channelPath: String = "/im",
        clientVersion: String? = nil,
        language: String? = nil,
        requestTimeout: Duration = .seconds(15),
        heartbeatInterval: Duration = .seconds(30),
        backoff: FullJitterBackoff = .default,
        maxAutoRepairSeq: Int64 = 500,
        cursorFlushInterval: Duration = .milliseconds(1000),
        maxRepairPages: Int = 16,
        maxResumePages: Int = 100,
        warningHandler: (@Sendable (String) -> Void)? = nil,
        tokenProvider: (@Sendable () async -> String?)? = nil,
        logStore: ImLogStore = .inMemory(),
        connector: any ImWebSocketConnector = URLSessionWebSocketConnector()
    ) {
        self.endpoint = endpoint
        self.appId = appId
        self.token = token
        self.deviceId = deviceId
        self.userId = userId
        self.cursorStore = cursorStore
        self.logStore = logStore
        self.platform = platform
        self.channelPath = channelPath
        self.clientVersion = clientVersion
        self.language = language
        self.requestTimeout = requestTimeout
        self.heartbeatInterval = heartbeatInterval
        self.backoff = backoff
        self.maxAutoRepairSeq = maxAutoRepairSeq
        self.cursorFlushInterval = cursorFlushInterval
        self.maxRepairPages = maxRepairPages
        self.maxResumePages = maxResumePages
        self.warningHandler = warningHandler
        self.tokenProvider = tokenProvider
        self.connector = connector
    }

    /// What goes in the `cv` handshake parameter.
    ///
    /// Always carries this package's version, and the host app's too when it set one. The gateway
    /// stores it verbatim on the session, so a support ticket arrives with both halves of "which
    /// build is this" without anyone having to ask for either.
    /// Who this session's cursors belong to.
    var cursorScope: ImCursorScope {
        ImCursorScope(endpoint: endpoint, appId: appId, userId: userId)
    }

    var handshakeClientVersion: String {
        guard let clientVersion, !clientVersion.isEmpty else { return ImSdk.userAgent }
        return "\(clientVersion) \(ImSdk.userAgent)"
    }
}

/// Where the socket is in its lifecycle.
///
/// `reconnecting` is deliberately distinct from `connecting`: an app should show a banner for one
/// and a spinner for the other, and telling them apart after the fact is impossible.
public enum ConnectionState: String, Sendable, Hashable, CustomStringConvertible {
    /// Never connected, or explicitly disconnected and awaiting a foreground.
    case idle

    /// First connection attempt in flight.
    case connecting

    /// Socket is up and requests will be answered.
    case open

    /// Dropped; a jittered retry is scheduled.
    case reconnecting

    /// Closed for good — either the app asked, or the server said do not come back.
    case closed

    public var description: String { rawValue }

    /// True when a request issued right now would fail immediately.
    public var isUsable: Bool { self == .open }
}
