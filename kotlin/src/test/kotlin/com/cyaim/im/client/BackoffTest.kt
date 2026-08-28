package com.cyaim.im.client

import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The reconnect delay is the difference between a rolling gateway update that nobody notices and
 * one that takes the node down a second time, so the distribution itself is under test — not just
 * "does it wait".
 */
class BackoffTest {

    @Test
    fun `the ceiling doubles from 500ms and stops at 30s`() {
        assertEquals(500, Backoff.ceilingMillis(0))
        assertEquals(1_000, Backoff.ceilingMillis(1))
        assertEquals(2_000, Backoff.ceilingMillis(2))
        assertEquals(4_000, Backoff.ceilingMillis(3))
        assertEquals(8_000, Backoff.ceilingMillis(4))
        assertEquals(16_000, Backoff.ceilingMillis(5))

        // 500 << 6 is 32s, clamped. Everything past this point is the same 30s window: a client
        // that has been failing for an hour must still come back within half a minute of the
        // service returning.
        assertEquals(30_000, Backoff.ceilingMillis(6))
        assertEquals(30_000, Backoff.ceilingMillis(7))
        assertEquals(30_000, Backoff.ceilingMillis(50))
    }

    @Test
    fun `every draw stays inside its own window`() {
        val random = Random(20_260_819)
        for (attempt in 0..10) {
            val ceiling = Backoff.ceilingMillis(attempt)
            repeat(500) {
                val delay = Backoff.nextDelay(attempt, random).inWholeMilliseconds
                assertTrue(delay in 0 until ceiling, "attempt $attempt produced ${delay}ms, window is 0..<$ceiling")
            }
        }
    }

    /**
     * The test that stops full jitter from quietly regressing into something cheaper.
     *
     * Twenty thousand draws are bucketed into ten equal slices of the window. Full jitter fills
     * every slice roughly equally. A fixed backoff puts every draw in the last slice; `delay ± 10%`
     * puts every draw in the last two. Both would leave eight buckets empty and fail here — which
     * is exactly the point, because both would also reconnect an entire gateway node's worth of
     * clients inside the same second.
     */
    @Test
    fun `full jitter spreads draws across the entire window`() {
        val random = Random(4)
        val attempt = 6
        val ceiling = Backoff.ceilingMillis(attempt)
        val samples = 20_000
        val buckets = IntArray(10)

        repeat(samples) {
            val delay = Backoff.nextDelay(attempt, random).inWholeMilliseconds
            buckets[(delay * buckets.size / ceiling).toInt()]++
        }

        val expected = samples / buckets.size
        buckets.forEachIndexed { index, count ->
            assertTrue(
                count > expected * 0.8 && count < expected * 1.2,
                "bucket $index held $count draws, expected about $expected — " +
                    "the distribution is not uniform across 0..$ceiling",
            )
        }
    }

    @Test
    fun `two clients dropped together do not come back together`() {
        // A thousand clients disconnected by the same rolling update, each drawing independently.
        val random = Random(99)
        val arrivals = List(1_000) { Backoff.nextDelay(6, random).inWholeMilliseconds }

        // No single second may hold more than a small share of the fleet. With a fixed backoff
        // this number is 1000.
        val busiestSecond = arrivals.groupingBy { it / 1_000 }.eachCount().values.max()
        assertTrue(busiestSecond < 60, "$busiestSecond of 1000 clients reconnected in the same second")
    }
}
