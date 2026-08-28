import 'dart:math';

/// Reconnect delay generator using **full jitter**.
///
/// The ceiling doubles per attempt up to [maxDelay]; the delay actually waited is a uniform random
/// draw from `0..ceiling`. Not the ceiling. Not the ceiling ±10%. The whole interval.
///
/// This matters more than it looks. A gateway holds sockets, so it is deployed rarely — but when
/// it is, a rolling update drops every socket on the node being replaced, at the same instant.
/// Those clients then all reconnect. With a fixed backoff they arrive together; with a
/// narrow-band jitter (`delay ± 10%`) they arrive together inside a slightly wider window, which
/// for a node holding tens of thousands of connections is the same outage. Full jitter spreads
/// them evenly across the whole ceiling, so the reconnect load looks like a ramp instead of a
/// spike — against the very service that has just come back up and has cold caches.
///
/// 全抖动（0..ceiling 均匀取样）而不是固定退避或 ±10%：网关滚动更新会让一个节点上的所有连接
/// 同时断开，只有把重连时间摊平到整个区间，恢复中的服务才不会被同步洪峰再打垮一次。
///
/// The generator is deliberately a separate, injectable object rather than three lines inside the
/// connection: it is the single piece of this SDK whose correctness is statistical, and it can
/// only be tested by drawing from it thousands of times.
class FullJitterBackoff {
  /// Creates a generator. The defaults match every other Cyaim IM client SDK — do not change them
  /// per-platform, or a fleet made of mixed clients de-synchronises unevenly.
  ///
  /// [random] is injectable so tests can be deterministic. Production uses a shared [Random];
  /// there is no security requirement here, only a spreading one.
  FullJitterBackoff({
    this.baseDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 30),
    this.doublingAttempts = 6,
    Random? random,
  })  : assert(baseDelay > Duration.zero, 'baseDelay must be positive'),
        assert(maxDelay >= baseDelay, 'maxDelay must be at least baseDelay'),
        assert(doublingAttempts >= 0, 'doublingAttempts must not be negative'),
        _random = random ?? Random();

  final Random _random;

  /// Ceiling for the first attempt is `baseDelay * 2`; it doubles from there.
  final Duration baseDelay;

  /// The ceiling never grows past this. Beyond half a minute a user has already decided the app
  /// is broken, so waiting longer buys the server nothing and costs the app everything.
  final Duration maxDelay;

  /// How many times the ceiling is allowed to double before it is pinned. With the defaults the
  /// ceiling reaches [maxDelay] at attempt 6 and stays there, so the exponent cannot overflow no
  /// matter how long a device stays offline.
  final int doublingAttempts;

  /// The upper bound of the random draw for [attempt] (1-based).
  ///
  /// Exposed because it is the honest way to describe the policy in a log line or a test: "the
  /// next attempt will fire somewhere in 0..8s" is meaningful, "the next attempt is in 3.2s" is
  /// only the outcome of one coin flip.
  Duration ceilingFor(int attempt) {
    final int clamped = attempt < 0 ? 0 : (attempt > doublingAttempts ? doublingAttempts : attempt);
    final int ceilingMicros = baseDelay.inMicroseconds * (1 << clamped);
    return ceilingMicros >= maxDelay.inMicroseconds
        ? maxDelay
        : Duration(microseconds: ceilingMicros);
  }

  /// A uniform draw from `0..ceilingFor(attempt)`.
  ///
  /// Attempt numbering is 1-based: the first reconnect after a drop is attempt 1. Returning a
  /// delay that can be very close to zero is intentional — some fraction of the fleet should come
  /// back immediately, and the rest should trail in behind them.
  Duration delayFor(int attempt) {
    final int ceilingMicros = ceilingFor(attempt).inMicroseconds;
    return Duration(microseconds: (_random.nextDouble() * ceilingMicros).floor());
  }
}
