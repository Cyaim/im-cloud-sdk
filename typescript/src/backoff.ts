/**
 * Reconnect delay policy: **full jitter**.
 *
 * The ceiling doubles per attempt up to {@link MAX_DELAY_MS}; the delay actually waited is a
 * uniform random draw from `0..ceiling`. Not the ceiling. Not the ceiling ±10%. The whole interval.
 *
 * This matters more than it looks. A gateway holds sockets, so it deploys rarely — but when it
 * does, a rolling update drops every socket on the node being replaced, at the same instant, and
 * all of those clients reconnect. With a fixed backoff they arrive together; with a narrow-band
 * jitter (`delay ± 10%`) they arrive together inside a slightly wider window, which for a node
 * holding tens of thousands of connections is the same outage. Full jitter spreads them evenly
 * across the whole ceiling, so the reconnect load looks like a ramp instead of a spike — against
 * the very service that has just come back up with cold caches.
 *
 * 全抖动（0..ceiling 均匀取样）而不是固定退避或 ±10%：网关滚动更新会让一个节点上的所有连接
 * 同时断开，只有把重连时间摊平到整个区间，恢复中的服务才不会被同步洪峰再打垮一次。
 *
 * It lives in its own module, rather than as three characters inside the connection, because it is
 * the one piece of this SDK whose correctness is statistical: it can only be checked by drawing
 * from it thousands of times, which needs a seam. The Dart and Kotlin SDKs draw the same seam with
 * the same constants — do not change them per-platform, or a fleet of mixed clients
 * de-synchronises unevenly.
 */

/** Ceiling for the first attempt is `BASE_DELAY_MS * 2`; it doubles from there. */
export const BASE_DELAY_MS = 500;

/**
 * The ceiling never grows past this. Beyond half a minute a user has already decided the app is
 * broken, so waiting longer buys the server nothing and costs the app everything.
 */
export const MAX_DELAY_MS = 30_000;

/**
 * How many times the ceiling may double before it is pinned. With these constants it reaches
 * {@link MAX_DELAY_MS} at attempt 6 and stays there, so the exponent cannot run away no matter how
 * long a device stays offline.
 */
export const DOUBLING_ATTEMPTS = 6;

/**
 * Upper bound of the random draw for a 1-based `attempt`.
 *
 * Exported because it is the honest way to describe the policy in a log line or a test: "the next
 * attempt fires somewhere in 0..8s" is meaningful; "the next attempt is in 3.2s" is only the
 * outcome of one coin flip.
 */
export function fullJitterCeiling(attempt: number): number {
  const clamped = Math.min(Math.max(attempt, 0), DOUBLING_ATTEMPTS);
  return Math.min(MAX_DELAY_MS, BASE_DELAY_MS * 2 ** clamped);
}

/**
 * A uniform draw from `0..fullJitterCeiling(attempt)`.
 *
 * Attempt numbering is 1-based: the first reconnect after a drop is attempt 1. A delay very close
 * to zero is intentional — some fraction of the fleet should come back immediately and the rest
 * should trail in behind them.
 *
 * `random` is injectable so tests are deterministic. There is no security requirement here, only a
 * spreading one, so `Math.random` is the right default.
 */
export function fullJitterDelay(attempt: number, random: () => number = Math.random): number {
  return random() * fullJitterCeiling(attempt);
}
