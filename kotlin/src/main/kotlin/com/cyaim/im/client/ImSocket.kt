package com.cyaim.im.client

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.concurrent.TimeUnit

/**
 * The transport seam.
 *
 * [ImConnection] talks to this rather than to OkHttp directly for two reasons: the reconnect,
 * kick and heartbeat rules are the valuable part of this SDK and they must be testable in virtual
 * time without a server; and a host app that already owns a tuned `OkHttpClient` (its own
 * interceptors, proxy, certificate pins, connection pool) should be able to hand it over instead
 * of paying for a second one.
 */
public interface ImSocket {
    /** Returns false when the frame could not be enqueued — a dead or saturated socket. */
    public fun send(text: String): Boolean

    /** Graceful close: sends a close frame and waits for the peer's. */
    public fun close(code: Int, reason: String?)

    /**
     * Hard close. Releases the socket without waiting for the peer to answer, which is the only
     * thing that works when the peer is no longer there — see the heartbeat path in [ImConnection].
     */
    public fun cancel()
}

/** Callbacks from the transport. All of them may arrive on any thread. */
public interface ImSocketListener {
    public fun onOpen()
    public fun onText(text: String)

    /** [reason] carries the `im-kick:{Reason}` marker when the server is kicking us off. */
    public fun onClosed(code: Int, reason: String?)
    public fun onFailure(cause: Throwable)
}

/** Opens sockets. Swap it in tests, or wrap it to add logging. */
public fun interface ImSocketFactory {
    public fun open(url: String, listener: ImSocketListener): ImSocket
}

/** The production transport: one OkHttp WebSocket per connection attempt. */
public class OkHttpSocketFactory(
    private val client: OkHttpClient = defaultClient(),
) : ImSocketFactory {

    override fun open(url: String, listener: ImSocketListener): ImSocket {
        val request = Request.Builder().url(toHttpScheme(url)).build()
        val socket = client.newWebSocket(
            request,
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) {
                    listener.onOpen()
                }

                override fun onMessage(webSocket: WebSocket, text: String) {
                    listener.onText(text)
                }

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    // We never negotiate `proto=msgpack`, so a binary frame is a text frame that
                    // took the wrong path through some proxy. Decoding it costs nothing and saves
                    // an unexplainable "messages stop arriving behind this one corporate gateway".
                    listener.onText(bytes.utf8())
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    // The kick reason arrives HERE, not in onClosed. OkHttp reports the peer's
                    // close frame in onClosing and expects us to answer before it will call
                    // onClosed; a listener that only implements onClosed can sit half-closed
                    // until OkHttp's own timeout fires, by which point the reason is a minute
                    // stale and we have already tried to reconnect a banned user.
                    webSocket.close(NORMAL_CLOSURE, null)
                    listener.onClosed(code, reason)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                    listener.onClosed(code, reason)
                }

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                    listener.onFailure(t)
                }
            },
        )
        return OkHttpImSocket(socket)
    }

    private class OkHttpImSocket(private val socket: WebSocket) : ImSocket {
        override fun send(text: String): Boolean = socket.send(text)

        override fun close(code: Int, reason: String?) {
            socket.close(code, reason)
        }

        override fun cancel() {
            socket.cancel()
        }
    }

    public companion object {
        /** RFC 6455 normal closure. */
        public const val NORMAL_CLOSURE: Int = 1000

        /**
         * Application close code used when we abandon a socket the OS still believes is alive.
         * 4000–4999 is the range reserved for applications.
         */
        public const val HEARTBEAT_FAILED_CLOSURE: Int = 4000

        /**
         * A client tuned for one long-lived socket, not for request/response traffic.
         *
         * `pingInterval` is deliberately left at zero. Liveness here is the application-level
         * `conn.heartbeat`, which is what keeps the server's routing entry alive: the entry carries
         * a TTL of three heartbeat intervals, so a client that stops sending them is routed away
         * from even though its socket may still be open.
         *
         * This comment used to say the server "drops a connection after 90 s without one". It never
         * did — `IdleTimeoutSeconds` sizes that Redis TTL and closes nothing. Since 2026-08-22 the
         * transport-level answer is the server's own `KeepAliveTimeoutSeconds` (a real Ping/Pong),
         * not anything this client does. The reasoning for leaving `pingInterval` at zero survives
         * the correction and is the actual point: a transport ping from here would keep the TCP
         * connection looking healthy while the server had already written the session off — the
         * worst of both worlds, a socket that is up and a user who is offline.
         */
        public fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .pingInterval(0, TimeUnit.MILLISECONDS)
            .retryOnConnectionFailure(true)
            .build()

        /**
         * OkHttp's URL parser only speaks http/https. Every OkHttp release so far has rewritten
         * `ws:`/`wss:` for us, but doing it here means a build against a version that stopped
         * fails at code review instead of at a customer's first connection.
         */
        internal fun toHttpScheme(url: String): String = when {
            url.startsWith("wss://", ignoreCase = true) -> "https://" + url.substring(6)
            url.startsWith("ws://", ignoreCase = true) -> "http://" + url.substring(5)
            else -> url
        }
    }
}
