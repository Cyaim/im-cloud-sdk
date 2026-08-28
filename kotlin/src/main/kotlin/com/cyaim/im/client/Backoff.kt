package com.cyaim.im.client

import kotlin.random.Random
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds

/**
 * Reconnect backoff: exponential ceiling, **full jitter**.
 *
 * A gateway holds sockets, so it deploys rarely — but when it does, every client on the node being
 * replaced is disconnected in the same instant, and every one of them wants back in. The delay a
 * client waits is the only thing standing between that and a synchronised stampede against the
 * service that has just finished starting.
 *
 * Full jitter means a uniform draw from `[0, ceiling)`, where the ceiling doubles from 500 ms up
 * to 30 s. Not a fixed backoff, and not `delay ± 10 %`: with either of those, N clients that were
 * dropped together arrive together, one ceiling later, and knock the node over again. Only drawing
 * across the *whole* window actually spreads them out — after the first round the arrivals are
 * uniform over 30 seconds instead of stacked in one.
 *
 * 满抖动（0..ceiling 均匀取值），不是固定退避、也不是 ±10%：网关滚动更新时同一节点上的连接
 * 会被同时断开，只有在整个窗口上均匀取值才能把它们真正打散。
 */
public object Backoff {
    /** First ceiling. Short enough that a one-off blip is invisible to the user. */
    public const val BASE_DELAY_MS: Long = 500

    /**
     * Hard ceiling. Also the reason a phone that comes back from Doze reconnects within half a
     * minute instead of an hour: the window never grows past this, however long we were away.
     */
    public const val MAX_DELAY_MS: Long = 30_000

    /** 500 ms shifted six times is 32 s, already past [MAX_DELAY_MS]; shifting further is noise. */
    public const val MAX_DOUBLINGS: Int = 6

    /** The upper bound of the window for [attempt] (1 = the first retry). */
    public fun ceilingMillis(attempt: Int): Long =
        minOf(MAX_DELAY_MS, BASE_DELAY_MS shl attempt.coerceIn(0, MAX_DOUBLINGS))

    /**
     * A delay drawn uniformly from `[0, ceilingMillis(attempt))`.
     *
     * [random] is a parameter so the distribution can be asserted in a test. A reconnect policy
     * that is only inspected by reading it is a reconnect policy that quietly regresses to a fixed
     * delay the first time someone "simplifies" it.
     */
    public fun nextDelay(attempt: Int, random: Random = Random.Default): Duration =
        random.nextLong(ceilingMillis(attempt)).milliseconds
}
