import Foundation
import Testing

@testable import CyaimIM

/// The reconnect delay is the difference between a rolling gateway update that nobody notices and
/// one that takes the fleet down twice. These tests assert the *distribution*, not just that some
/// delay comes out, because a fixed backoff and a full-jitter backoff are indistinguishable from a
/// single sample.
@Suite("Reconnect backoff")
struct BackoffTests {

    @Test("the ceiling doubles per attempt and stops at 30 seconds")
    func ceilingLadder() {
        let backoff = FullJitterBackoff.default

        #expect(isClose(backoff.ceiling(forAttempt: 1).seconds, 1))
        #expect(isClose(backoff.ceiling(forAttempt: 2).seconds, 2))
        #expect(isClose(backoff.ceiling(forAttempt: 3).seconds, 4))
        #expect(isClose(backoff.ceiling(forAttempt: 4).seconds, 8))
        #expect(isClose(backoff.ceiling(forAttempt: 5).seconds, 16))

        // 0.5s × 2⁶ is 32s, clamped to the 30s maximum, and it stays there however long the
        // network stays down.
        #expect(isClose(backoff.ceiling(forAttempt: 6).seconds, 30))
        #expect(isClose(backoff.ceiling(forAttempt: 40).seconds, 30))

        // Attempt numbers below 1 are treated as the first attempt rather than collapsing to zero.
        #expect(isClose(backoff.ceiling(forAttempt: 0).seconds, 1))
    }

    @Test("every delay lands inside 0 ..< ceiling")
    func delaysStayInsideTheWindow() {
        var generator = SeededGenerator(seed: 0xC0FF_EE00_1234)
        let backoff = FullJitterBackoff.default

        for attempt in 1 ... 8 {
            let ceiling = backoff.ceiling(forAttempt: attempt).seconds

            for _ in 0 ..< 500 {
                let delay = backoff.delay(forAttempt: attempt, using: &generator).seconds
                #expect(delay >= 0)
                #expect(delay < ceiling)
            }
        }
    }

    /// This is the test that a fixed backoff, or a `delay ± 10%` backoff, fails: both would leave
    /// nine of these ten buckets empty and one holding everything, which is precisely the
    /// synchronised wave the jitter exists to prevent.
    @Test("delays spread across the whole window rather than clustering")
    func fullJitterCoversTheWholeWindow() {
        var generator = SeededGenerator(seed: 20_260_819)
        let backoff = FullJitterBackoff.default
        let ceiling = backoff.ceiling(forAttempt: 6).seconds

        let samples = 4_000
        var buckets = [Int](repeating: 0, count: 10)

        for _ in 0 ..< samples {
            let delay = backoff.delay(forAttempt: 6, using: &generator).seconds
            let bucket = min(9, Int(delay / ceiling * 10))
            buckets[bucket] += 1
        }

        for (index, count) in buckets.enumerated() {
            #expect(count > samples / 20, "tenth #\(index) of the window held only \(count) of \(samples) draws")
        }

        #expect(buckets.max() ?? 0 < samples / 5, "one tenth of the window took more than a fifth of the draws")
    }

    @Test("the mean delay is about half the ceiling")
    func meanIsHalfTheCeiling() {
        var generator = SeededGenerator(seed: 99)
        let backoff = FullJitterBackoff.default
        let ceiling = backoff.ceiling(forAttempt: 4).seconds

        var total = 0.0
        let samples = 3_000
        for _ in 0 ..< samples {
            total += backoff.delay(forAttempt: 4, using: &generator).seconds
        }

        let mean = total / Double(samples)
        #expect(abs(mean - ceiling / 2) < ceiling * 0.05, "mean was \(mean), expected about \(ceiling / 2)")
    }

    @Test("a custom ladder is honoured")
    func customLadder() {
        let backoff = FullJitterBackoff(
            initialDelay: .milliseconds(100),
            maximumDelay: .seconds(2),
            doublingLimit: 3
        )

        #expect(isClose(backoff.ceiling(forAttempt: 1).seconds, 0.2))
        #expect(isClose(backoff.ceiling(forAttempt: 2).seconds, 0.4))
        #expect(isClose(backoff.ceiling(forAttempt: 3).seconds, 0.8))
        #expect(isClose(backoff.ceiling(forAttempt: 9).seconds, 0.8))
    }
}
