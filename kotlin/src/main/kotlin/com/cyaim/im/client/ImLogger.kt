package com.cyaim.im.client

/**
 * Where the SDK's own diagnostics go.
 *
 * There are only a handful of them and every one exists because the alternative was a silent
 * failure that is indistinguishable from a broken server: a cursor store that could not be
 * written, a push token held but never registered, a listener that threw. None of those can be
 * returned to a caller — they happen on the SDK's own coroutines, with nobody waiting — so they
 * have to go somewhere the integrator can see.
 *
 * A one-method interface rather than SLF4J: this artifact is a plain JVM library with three
 * dependencies, and adding a logging facade to emit five lines a session would be the fourth. Wire
 * it to whatever the host app already uses.
 *
 * SDK 自己的诊断信息只有寥寥几条，但每一条都对应一种"静默失败"——游标写不进去、
 * 持有推送 token 却从未注册、监听器抛异常。它们发生在 SDK 自己的协程上，没有调用方在等，
 * 只能有个地方让接入方看到。
 *
 * ```kotlin
 * ImOptions(
 *     …,
 *     logger = { level, message, cause -> Log.println(level.androidPriority, "IM", message) },
 * )
 * ```
 */
public fun interface ImLogger {
    public fun log(level: ImLogLevel, message: String, cause: Throwable?)

    public companion object {
        /**
         * The default. Warnings and errors to `System.err`, everything else dropped.
         *
         * `System.err` rather than `java.util.logging`, because on Android the former reaches
         * Logcat with no configuration and the latter needs a handler nobody installs. It is a
         * deliberately poor logger — the point is that the messages are visible by default, not
         * that this is where they belong.
         */
        public fun stderr(): ImLogger = ImLogger { level, message, cause ->
            if (level >= ImLogLevel.Warn) {
                System.err.println("[im-client/${level.name.lowercase()}] $message")
                cause?.printStackTrace()
            }
        }

        /** Silence. Only appropriate when you have wired the events you care about yourself. */
        public fun none(): ImLogger = ImLogger { _, _, _ -> }
    }
}

public enum class ImLogLevel {
    Debug,
    Info,
    Warn,
    Error,
}

internal fun ImLogger.debug(message: String) {
    log(ImLogLevel.Debug, message, null)
}

internal fun ImLogger.info(message: String) {
    log(ImLogLevel.Info, message, null)
}

internal fun ImLogger.warn(message: String, cause: Throwable? = null) {
    log(ImLogLevel.Warn, message, cause)
}

internal fun ImLogger.error(message: String, cause: Throwable? = null) {
    log(ImLogLevel.Error, message, cause)
}
