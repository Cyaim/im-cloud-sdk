import Foundation

/// Reconnect delays, drawn with **full jitter**.
///
/// The ceiling doubles per attempt up to 30 seconds, and the delay actually used is a uniform draw
/// from `0 ..< ceiling`. Not the ceiling itself, and not the ceiling ±10%.
///
/// This matters more than it looks. A gateway holds sockets, so a rolling update drops every socket
/// on the node being replaced at the same instant — tens of thousands of clients, all of which now
/// want to reconnect. With a fixed backoff they come back in the same second, at the service that
/// has only just finished starting, and knock it over again; the second wave is worse than the
/// first because it is now synchronised. Jittering by ±10% barely helps: the arrivals are still a
/// spike, just a slightly wider one. Drawing uniformly from the whole interval is what actually
/// spreads a node's worth of clients across it.
///
/// 满抖动而不是固定退避：网关滚动更新会让整节点客户端同时断线，固定退避（或 ±10% 抖动）
/// 会让它们在同一秒回来，把刚恢复的服务再打垮一次。
public struct FullJitterBackoff: Sendable, Hashable {
    /// Ceiling for the first attempt. Doubles from here.
    public var initialDelay: Duration

    /// The ceiling stops growing here. Beyond ~30s a user has given up on the app anyway, and the
    /// spread is already wide enough to de-synchronise a fleet.
    public var maximumDelay: Duration

    /// How many doublings before the ceiling is clamped. Six doublings of 500ms overshoots 30s,
    /// which is the intent: attempts 6 and beyond all draw from the full 0..30s window.
    public var doublingLimit: Int

    public init(
        initialDelay: Duration = .milliseconds(500),
        maximumDelay: Duration = .seconds(30),
        doublingLimit: Int = 6
    ) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.doublingLimit = doublingLimit
    }

    public static let `default` = FullJitterBackoff()

    /// The upper bound for `attempt`, where the first reconnect after a drop is attempt 1.
    public func ceiling(forAttempt attempt: Int) -> Duration {
        let exponent = min(max(attempt, 1), doublingLimit)
        let scaled = initialDelay.seconds * pow(2, Double(exponent))
        return .seconds(min(maximumDelay.seconds, scaled))
    }

    /// A delay for `attempt`, drawn uniformly from `0 ..< ceiling(forAttempt:)`.
    public func delay(forAttempt attempt: Int) -> Duration {
        var generator = SystemRandomNumberGenerator()
        return delay(forAttempt: attempt, using: &generator)
    }

    /// A delay for `attempt`, drawn from an explicit generator so the distribution is testable.
    public func delay<Generator: RandomNumberGenerator>(
        forAttempt attempt: Int,
        using generator: inout Generator
    ) -> Duration {
        let ceilingSeconds = ceiling(forAttempt: attempt).seconds
        guard ceilingSeconds > 0 else { return .zero }
        return .seconds(Double.random(in: 0 ..< ceilingSeconds, using: &generator))
    }
}

extension Duration {
    /// This duration in seconds. `Duration` stores attoseconds, and the arithmetic below is all in
    /// fractional seconds, so the conversion lives in one place.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
