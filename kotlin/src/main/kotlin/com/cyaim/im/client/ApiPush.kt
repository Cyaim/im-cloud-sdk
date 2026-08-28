package com.cyaim.im.client

import kotlinx.coroutines.CancellationException
import java.util.concurrent.atomic.AtomicReference

/** A vendor device token as this SDK holds it. [provider] is one of [PushProvider]'s values. */
public data class ImPushToken(
    public val provider: String,
    public val token: String,
    /** BCP-47. Null lets the server fall back to the socket's `lang`. */
    public val language: String? = null,
)

/**
 * `push.*` — offline notifications.
 *
 * ### The Android question
 *
 * This artifact is a plain JVM library with zero Android dependencies: `java-library`, JVM 11, not
 * one `android.*` import. That is the right call — the same jar serves an Android app, a desktop
 * client and a JVM service — but Firebase hands the FCM token to the **host app**, through
 * `FirebaseMessagingService.onNewToken`, not to a library. The SDK cannot ask for it.
 *
 * So it does not:
 *
 * > **The host app owns token acquisition. The SDK owns token delivery.**
 *
 * You call [setToken] from your own `onNewToken` and once at startup; the SDK caches it and
 * registers it on every connect. Four lines of glue, in the host app, where the Firebase
 * dependency already is.
 *
 * ```kotlin
 * class ImMessagingService : FirebaseMessagingService() {
 *     override fun onNewToken(token: String) {
 *         Im.client?.push?.setToken(PushProvider.Fcm, token)
 *     }
 * }
 *
 * // and once at startup, because onNewToken only fires when the token *changes*:
 * im.push.setToken(PushProvider.Fcm, FirebaseMessaging.getInstance().token.await())
 * ```
 *
 * On a Chinese OEM handset substitute that vendor's SDK and its [PushProvider] constant. **Always
 * pass the provider explicitly on Android**: the server's empty-provider fallback is only reliable
 * on iOS, and Android fragments across five OEM channels the server cannot guess between.
 *
 * ### When registration happens
 *
 * 1. **On every successful connect**, if a token is known. Not once at install — the vendor may
 *    replace a token while the process is frozen and the server has no other way to learn it.
 *    Re-registering an unchanged token costs no write; the server debounces it.
 * 2. **On every token refresh**: immediately if connected, otherwise cached and sent by rule 1 on
 *    the next connect.
 * 3. **On logout, [unregister] before closing the socket.** After the socket is gone there is no
 *    authenticated channel and the token cannot be removed at all. [ImClient.logout] does this in
 *    the right order. Disconnecting never unregisters — a dead socket is precisely the state
 *    offline push exists to serve.
 *
 * If a client dies without unregistering — force quit, crash, uninstall — only the tenant backend
 * can clean up: `DELETE /v1/users/{userId}/push-tokens/{deviceId}`.
 *
 * 宿主 App 负责取 token，SDK 负责送 token：Firebase 只把 token 交给 App，库拿不到它，
 * 所以这里不引入任何 Android 依赖，只提供 setToken。退出登录必须先 unregister 再断开——
 * socket 断了就再也没有可鉴权的通道去删这个 token。
 */
public class PushApi internal constructor(
    private val connection: ImConnection,
    private val logger: ImLogger,
) {

    private val cached = AtomicReference<ImPushToken?>(null)

    @Volatile
    private var registered: ImPushToken? = null

    /** The token the SDK is holding, or null if the host app has never supplied one. */
    public val token: ImPushToken? get() = cached.get()

    /** Whether the held token has been accepted by the server on this connection. */
    public val isRegistered: Boolean get() = registered != null && registered == cached.get()

    /**
     * Hands the SDK a vendor token. Non-suspending, so it is safe to call from
     * `FirebaseMessagingService.onNewToken` and from a cold-start callback alike.
     *
     * The registration itself happens on the next connect. If you are already connected, call
     * [register] (or simply let the next reconnect carry it — a token change while connected is
     * rare and one reconnect's delay is not worth blocking a lifecycle callback for).
     */
    public fun setToken(provider: String, token: String, language: String? = null) {
        require(token.isNotBlank()) { "push token must not be blank" }
        cached.set(ImPushToken(provider, token, language))
    }

    /** Forgets the held token without telling the server. [unregister] is what you usually want. */
    public fun clearToken() {
        cached.set(null)
        registered = null
    }

    /**
     * Registers a token now. Idempotent; the server debounces an unchanged one.
     *
     * The token is also cached, so every later connect re-registers it by itself.
     */
    public suspend fun register(request: RegisterPushTokenRequest) {
        require(request.token.isNotBlank()) { "push token must not be blank" }
        val held = ImPushToken(request.provider, request.token, request.language)
        cached.set(held)
        connection.execute("push.register", request.asBody())
        registered = held
    }

    /** [register] for a token the SDK already holds, or one you pass here. */
    public suspend fun register(provider: String, token: String, language: String? = null): Unit =
        register(RegisterPushTokenRequest(provider, token, language))

    /**
     * Drops this device's registration. Other devices of the same user are untouched.
     *
     * Also forgets the held token: this is a statement that the device no longer wants push, and
     * silently re-registering it on the next connect would contradict that. Call [setToken] again
     * to opt back in.
     */
    public suspend fun unregister() {
        connection.execute("push.unregister", null)
        clearToken()
    }

    /**
     * Reports that the user tapped one of this device's notifications. Call it from the tap
     * handler, not from wherever the message is rendered.
     *
     * What it feeds is the delivery funnel on the tenant's push screen: sent → delivered → clicked.
     * APNs and FCM do not report delivery at all, so on most deployments a tap is the only evidence
     * that a notification ever arrived, and the server credits delivery from it.
     *
     * Pass what the payload gave you — `messageId` from the notification's `msgId` is the usual
     * one. With nothing at all the server attributes this device's newest delivery, which is the
     * right answer for a tap that opened the app without naming a message.
     *
     * **It never throws and it is never retried.** These are best-effort statistics: the common
     * failure is `2401 PushDeliveryNotFound` for a row that has aged out after seven days, which is
     * nobody's fault, and there is no version of "the click count is one short" worth making an
     * application handle — or worth a second frame on a socket the user is waiting on. The failure
     * goes to [ImLogger] at debug, so it is off by default and there to be turned on when a funnel
     * looks wrong.
     *
     * 尽力而为的统计：不抛异常、不重试。最常见的失败是七天后行已过期（2401），
     * 那不是任何人的错，也没有哪个应用需要为「点击数少了一次」写一段处理逻辑。
     */
    public suspend fun clicked(request: PushClickedRequest = PushClickedRequest()) {
        try {
            connection.execute("push.clicked", request.asBody())
        } catch (cancellation: CancellationException) {
            // The caller's scope went away, which is a decision rather than a failure. Swallowing
            // it here would break structured concurrency on the coroutine that is being cancelled.
            throw cancellation
        } catch (failure: Throwable) {
            logger.log(
                ImLogLevel.Debug,
                "push.clicked was not recorded; the delivery funnel will be one tap short",
                failure,
            )
        }
    }

    /**
     * Rule 1: called by [ImClient] after every successful connect.
     *
     * Failures are logged rather than thrown — nobody is waiting on this call, and a push
     * registration that failed must not take the session down with it. But it is logged loudly,
     * because a silently unregistered device is indistinguishable from a broken push provider and
     * that misdiagnosis costs a support cycle every time.
     */
    internal suspend fun registerOnConnect(autoRegister: Boolean) {
        val held = cached.get() ?: return

        if (!autoRegister) {
            if (registered == null) {
                logger.warn(
                    "a push token is held but automatic registration is off and push.register has " +
                        "never succeeded; offline notifications will not arrive (CONTRACT.md §6.2)",
                )
            }
            return
        }

        try {
            connection.execute(
                "push.register",
                RegisterPushTokenRequest(held.provider, held.token, held.language).asBody(),
            )
            registered = held
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (failure: Throwable) {
            registered = null
            logger.warn(
                "push.register failed; this device will not receive offline notifications " +
                    "until the next successful connect (CONTRACT.md §6.2)",
                failure,
            )
        }
    }

    /** True when [ImClient.logout] should spend a round trip unregistering before closing. */
    internal fun hasToken(): Boolean = cached.get() != null
}
