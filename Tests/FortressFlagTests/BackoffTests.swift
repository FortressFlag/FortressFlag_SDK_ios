import Foundation
import Testing
@testable import FortressFlag

@Suite("Backoff and jitter")
struct BackoffTests {
    let backoff = Backoff()

    /// Randomness that always returns the top of the range, so "±20%" becomes a checkable number.
    let maxJitter: (ClosedRange<Double>) -> Double = { $0.upperBound }
    let minJitter: (ClosedRange<Double>) -> Double = { $0.lowerBound }
    let noJitter: (ClosedRange<Double>) -> Double = { _ in 0 }

    @Test("no failures means no delay")
    func zeroFailures() {
        #expect(backoff.retryDelay(consecutiveFailures: 0, random: noJitter) == .zero)
    }

    @Test(
        "delay doubles with each consecutive failure",
        arguments: [(1, 2.0), (2, 4.0), (3, 8.0), (4, 16.0), (10, 1024.0)]
    )
    func exponential(failures: Int, expectedSeconds: Double) {
        let delay = backoff.retryDelay(consecutiveFailures: failures, random: noJitter)
        #expect(abs(delay.seconds - expectedSeconds) < 0.001)
    }

    @Test("the delay is capped")
    func capped() {
        let delay = backoff.retryDelay(consecutiveFailures: 50, random: noJitter)
        #expect(abs(delay.seconds - backoff.cap.seconds) < 0.001)
    }

    @Test("a device that has been offline for a very long time does not overflow into an instant retry")
    func noOverflow() {
        // The exponent is clamped before `pow`, so failure number 10,000 is still capped rather
        // than becoming infinity, NaN, or — worst case — zero.
        let delay = backoff.retryDelay(consecutiveFailures: 10_000, random: noJitter)
        #expect(delay.seconds > 0)
        #expect(delay.seconds <= backoff.cap.seconds)
    }

    @Test("jitter stays within ±20%")
    func jitterBounds() {
        let base = backoff.retryDelay(consecutiveFailures: 3, random: noJitter).seconds
        let high = backoff.retryDelay(consecutiveFailures: 3, random: maxJitter).seconds
        let low = backoff.retryDelay(consecutiveFailures: 3, random: minJitter).seconds

        #expect(abs(high - base * 1.2) < 0.001)
        #expect(abs(low - base * 0.8) < 0.001)
    }

    @Test("routine polling is jittered too")
    func pollJitter() {
        // Jitter on the success path is what stops a fleet that came back online together from
        // re-synchronising into a stampede against a backend that just recovered.
        let interval = Duration.seconds(300)
        let high = backoff.pollDelay(interval: interval, random: maxJitter).seconds
        let low = backoff.pollDelay(interval: interval, random: minJitter).seconds

        #expect(abs(high - 360) < 0.001)
        #expect(abs(low - 240) < 0.001)
        #expect(high != low)
    }

    @Test("Retry-After is honoured")
    func retryAfterHonoured() {
        let delay = backoff.retryDelay(honouring: 45, consecutiveFailures: 1, random: noJitter)
        #expect(abs(delay.seconds - 45) < 0.001)
    }

    @Test("an absurd Retry-After is clamped to the cap")
    func retryAfterClamped() {
        // A hostile or misconfigured header of a year must not silently disable flag updates on a
        // device until the app is force-quit.
        let delay = backoff.retryDelay(honouring: 31_536_000, consecutiveFailures: 1, random: noJitter)
        #expect(abs(delay.seconds - backoff.cap.seconds) < 0.001)
    }

    @Test("a nonsensical Retry-After falls back to exponential backoff")
    func retryAfterIgnoredWhenInvalid() {
        let delay = backoff.retryDelay(honouring: -5, consecutiveFailures: 2, random: noJitter)
        #expect(abs(delay.seconds - 4) < 0.001)
    }

    @Test("a negative computed delay can never become a busy loop")
    func neverNegative() {
        var wild = Backoff()
        wild.jitterFraction = 5
        let delay = wild.retryDelay(consecutiveFailures: 1, random: minJitter)
        #expect(delay.seconds >= 0)
    }
}
