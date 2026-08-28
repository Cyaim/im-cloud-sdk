package com.cyaim.im.client

/*
 * Typed endpoint namespaces.
 *
 * One object per target prefix — `im.conn`, `im.msg`, `im.conv`, `im.user`, `im.friend`,
 * `im.group`, `im.media`, `im.push` — and inside it one method per endpoint, named for the
 * endpoint's method part and nothing else. `msg.cancelScheduled` is `im.msg.cancelScheduled`; it is
 * not `cancelScheduledMessage`, `unschedule` or `deleteScheduled`, however much better one of those
 * reads. A synonym costs every future reader a lookup and costs the support engineer the ability to
 * grep a bug report against the server's own logs.
 *
 * 命名空间与端点前缀一一对应，方法名就是端点名的后半段，不取同义词：改名字等于让每个读者
 * 多查一次表，也让支持工程师无法用工单里的端点名直接 grep 代码。
 *
 * Every one of them is a thin wrapper over the same `ImConnection.request(target, body)` that
 * `invoke()` uses, so timeouts, cancellation, error mapping and reauth cannot drift between the
 * typed surface and the escape hatch (CONTRACT.md §8 rule 1).
 */

/**
 * `conn.*` — the session floor.
 *
 * You will rarely call any of this: [ImClient] beats the heartbeat, runs [sync] on every connect
 * and renews the token itself. It is public because a private deployment sometimes needs to drive
 * one of them by hand, and because [reauth] is worth knowing about.
 */
public class ConnApi internal constructor(private val connection: ImConnection) {

    /**
     * Keeps the session alive, and heals it: a beat that finds no routing entry re-registers this
     * connection and republishes presence.
     *
     * [ImConnection] already runs this on the cadence the server reports, and a missed beat
     * abandons the socket. Calling it yourself is harmless but buys nothing.
     */
    public suspend fun heartbeat(): HeartbeatResult = connection.request("conn.heartbeat")

    /**
     * Exchanges a fresh token **on the existing socket**, so a token expiring mid-session costs a
     * round trip instead of a reconnect.
     *
     * That distinction matters exactly when it is hardest to test: on a flaky network, a reconnect
     * is the thing you were trying to avoid, and it is also the thing most likely to fail. The
     * token must belong to the identity already on this socket — a client cannot change who it is
     * without reconnecting, and the server refuses with `1103 Forbidden` if it tries.
     *
     * [ImClient] calls this for you when a business call comes back `1101 TokenExpired` and you
     * supplied [ImOptions.onTokenExpired]; the failed call is then retried once.
     */
    public suspend fun reauth(request: ReauthRequest) {
        connection.execute("conn.reauth", request.asBody())
    }

    /** [reauth] for the one-field case. */
    public suspend fun reauth(token: String): Unit = reauth(ReauthRequest(token))

    /**
     * Asks what changed while we were away.
     *
     * **[ImClient] issues this itself on every connect, with the durable cursors from its
     * [ImCursorStore], and repairs what comes back.** Calling it by hand is legitimate for a
     * diagnostic or a bespoke sync loop, but a hand-built [ResumeRequest] carrying in-memory seqs
     * is the data-loss bug CONTRACT.md §5.1 exists to describe: a conversation you do not report
     * produces no gap entry, and the messages you were missing are never mentioned again.
     */
    public suspend fun sync(request: ResumeRequest): ResumeResult =
        connection.request("conn.sync", request.asBody())
}
