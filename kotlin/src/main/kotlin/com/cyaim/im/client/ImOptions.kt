package com.cyaim.im.client

import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * Everything the SDK needs to reach the gateway and behave itself once it is there.
 *
 * One options type serves both [ImConnection] and [ImClient]: Kotlin data classes cannot be
 * extended, and splitting this in two only to model an inheritance the caller never sees would
 * cost every caller a nested constructor call.
 */
public data class ImOptions(
    /** Base URL of the gateway, e.g. `wss://im.example.com`. [channel] is appended to it. */
    public val endpoint: String,
    public val appId: String,
    /**
     * A short-lived **user** token minted by your backend. Never an `AppSecret` — that key signs
     * tokens and can impersonate any user in the tenant, and anything shipped in an APK is
     * public. See docs/GETTING-STARTED.md §0.
     */
    public val token: String,
    /**
     * Stable per installation. The multi-device policy uses it to tell a reconnect apart from a
     * second device, so a value regenerated on every launch makes users kick themselves offline.
     * Persist a UUID in DataStore/SharedPreferences on first run and reuse it forever.
     */
    public val deviceId: String,
    /**
     * Who the [token] was minted for. **Required.**
     *
     * Not sent to the gateway — the server reads the identity out of the token — but it is the
     * third component of the cursor store's scope key, `(endpoint host, appId, userId)`, and it is
     * the one that stops account switching on a shared handset from handing one user another's
     * cursors: the SDK stamps the scope into every snapshot it writes and refuses one that belongs
     * to somebody else.
     *
     * It used to be nullable with a null default, which meant every account on a device scoped to
     * the same `host|appId|*` and the guarantee quietly did not apply to anyone who had not set it.
     * A required argument is the only version of that guarantee that cannot be forgotten. Your
     * backend already knows the value: it is the user it just minted a token for.
     *
     * 必填：游标作用域是 (host, appId, userId)，缺了 userId，同设备的两个账号会落在同一个作用域，
     * 那条保证就等于没有。
     */
    public val userId: String,
    public val platform: Platform = Platform.Android,
    /** The MVC channel path on the gateway. */
    public val channel: String = "/im",
    /**
     * Your own application's version, sent as the `cv` handshake parameter.
     *
     * Leave it null and the SDK sends its own ([ImSdk.packageVersion]) instead, so a support ticket
     * always carries something. Setting it replaces that, which is usually the better trade: the
     * SDK version is also derivable from the contract version in the ticket.
     */
    public val clientVersion: String? = null,
    /** BCP-47 tag; the server uses it for localised system messages and push text. */
    public val language: String? = null,
    /** How long an unanswered request waits before it fails with [ImErrorCode.Timeout]. */
    public val requestTimeout: Duration = 15.seconds,
    /**
     * Opening heartbeat cadence. The server reports its own interval in the first heartbeat reply
     * and that value wins from then on — the server is the side that decides when a connection is
     * considered dead (90 s without a beat, per SPEC-02 §2.1).
     */
    public val heartbeatInterval: Duration = 30.seconds,
    /**
     * Largest gap the client repairs message by message. Beyond this the conversation is reported
     * on [ImClient.conversationNeedsReload] and both its cursors jump to the top of the gap:
     * replaying fifty thousand messages into a UI helps nobody, and the app can reload that one
     * conversation from `msg.history` instead.
     *
     * Raising it past 500 does not buy a bigger single call — `msg.sync` is clamped to 500
     * server-side — it buys more iterations of the repair loop. That is fine and intended.
     */
    public val maxAutoRepairSeq: Long = 500,
    /**
     * How long an ordinary [ImClient.commit] may sit unwritten before the cursor store is asked to
     * save. Zero writes through on every commit.
     *
     * Coalescing is safe here and nowhere else: **a lost debounced commit costs one duplicate
     * delivery; a lost cursor entry costs silent permanent data loss.** So this window applies to
     * ordinary commits only. An adoption — the SDK taking the server's position for a conversation
     * it has never seen — is flushed synchronously whatever this says, and the store is also
     * flushed before every `conn.sync` and on [ImClient.close].
     *
     * 只有普通提交可以合并写；丢一次合并写最多多投一条重复消息，丢一条"采纳"记录则是永久静默丢数据。
     */
    public val cursorFlushInterval: Duration = 1.seconds,
    /**
     * Whether the SDK re-registers the held push token on every successful connect.
     *
     * On by default because that is the only way the server learns about a token the vendor
     * replaced while the process was frozen. Turn it off only if you are driving `push.register`
     * yourself; the SDK will then warn once per connect that it is holding a token it has never
     * registered, because a silently unregistered device looks exactly like a broken push provider.
     */
    public val autoRegisterPushToken: Boolean = true,
    /**
     * Where the SDK's own diagnostics go. Defaults to `System.err` for warnings and errors.
     *
     * Every message it emits exists because the alternative was a silent failure: a cursor store
     * that could not be written, a push token held but never registered, a listener that threw.
     */
    public val logger: ImLogger = ImLogger.stderr(),
    /**
     * Where the SDK's own runtime log lives between runs. **Optional, and the default is honest.**
     *
     * Supplying one is what makes "pull a log from that handset" answer questions about anything
     * before the current process — a crash, a night the app was closed, the reconnect storm at 3am.
     * Supplying none keeps a bounded ring in memory, which answers "what is happening now"
     * completely and "what happened when it crashed" not at all; the console shows which of the two
     * a support engineer is looking at, because a three-minute log and a seven-day log are
     * otherwise identical.
     *
     * The SDK does not pick a location for you — see `ADR-003`, and [ImCursorStore] for the same
     * rule applied to cursors. On Android that would be app-private storage whose backup behaviour
     * you configure, and "do chat logs end up in Google's backup" is a question you answer to a
     * regulator. [ImLogStore.file] is provided for when you have made that decision.
     *
     * SDK 不替你选写入位置：不提供也是一个完整的选择——内存环形缓冲只覆盖本次进程，
     * 而控制台会把这个区别显示出来。
     */
    public val logStore: ImLogStore = ImLogStore.inMemory(),
    /**
     * Called when the server closes with `im-kick:TokenExpired`, and when a business call comes
     * back `1101 TokenExpired`. Return a fresh token, or null to stop and go
     * [ConnectionState.Closed].
     *
     * In the second case the SDK renews the token on the **existing** socket with `conn.reauth`
     * and retries the failed call once, so an expiry mid-session costs a round trip rather than a
     * reconnect — which matters most on exactly the flaky networks where a reconnect is the thing
     * you were trying to avoid.
     *
     * It is a suspending function because getting a token means calling your backend, and this is
     * the one moment where blocking the reconnect loop is exactly right: there is nothing useful
     * to do with a connection until the token is valid again.
     */
    public val onTokenExpired: (suspend () -> String?)? = null,
) {
    init {
        require(endpoint.isNotBlank()) { "endpoint is required, e.g. wss://im.example.com" }
        require(endpoint.startsWith("ws://") || endpoint.startsWith("wss://")) {
            "endpoint must be a WebSocket URL (ws:// or wss://), got: $endpoint"
        }
        require(appId.isNotBlank()) { "appId is required" }
        require(token.isNotBlank()) { "token is required" }
        require(deviceId.isNotBlank()) {
            "deviceId is required and must be stable for this installation"
        }
        require(userId.isNotBlank()) {
            "userId is required: it is the third component of the cursor store's scope key and " +
                "the only thing that stops account switching on a shared device from handing one " +
                "user another's cursors (CONTRACT.md §5.3)"
        }
        require(requestTimeout.isPositive()) { "requestTimeout must be positive" }
        require(heartbeatInterval.isPositive()) { "heartbeatInterval must be positive" }
        require(maxAutoRepairSeq > 0) { "maxAutoRepairSeq must be positive" }
        require(!cursorFlushInterval.isNegative()) { "cursorFlushInterval must not be negative" }
    }

    /**
     * The cursor store's scope: `(endpoint host, appId, userId)`.
     *
     * Not the device id — the store is already local to the device. The user id is the part that
     * matters, and it is why [userId] has no default.
     */
    public fun cursorScope(): ImCursorScope =
        ImCursorScope.of(endpoint = endpoint, appId = appId, userId = userId)

    /** Never log the token; `toString()` on a data class would otherwise leak it into Logcat. */
    override fun toString(): String =
        "ImOptions(endpoint=$endpoint, appId=$appId, deviceId=$deviceId, userId=$userId, " +
            "platform=$platform, token=<redacted>)"
}
