import Foundation

/// How long to wait before the next poll.
///
/// Two jobs, and the second one is the one that matters at scale. The obvious job is to stop a
/// device hammering a failing backend. The less obvious job is **de-synchronisation**: without
/// jitter, every device that started polling at the same moment — which, after an outage, is all
/// of them — retries in lockstep, and the backend that just came back up is knocked over by its
/// own clients. Jitter on the success path matters as much as on the failure path.
///
/// Randomness is injected rather than called, so the bounds can be asserted in tests instead of
/// hoped for.
struct Backoff: Sendable, Equatable {
    /// Delay after the first failure. Doubles from here.
    var base: Duration = .seconds(2)

    /// Ceiling. Half an hour: a device that has been failing for hours is almost certainly
    /// offline, and there is nothing to gain from asking more often — the cache is already
    /// answering every call.
    var cap: Duration = .seconds(1800)

    /// Fraction of the computed delay to spread over, either side. 0.2 gives ±20%.
    var jitterFraction: Double = 0.2

    /// Delay before retrying after `consecutiveFailures` failures in a row.
    func retryDelay(consecutiveFailures: Int, random: (ClosedRange<Double>) -> Double) -> Duration {
        guard consecutiveFailures > 0 else { return .zero }

        // Exponent capped before `pow` so a long-lived offline device cannot overflow the
        // multiplier into infinity on its ten-thousandth failed attempt.
        let exponent = Double(min(consecutiveFailures - 1, 32))
        let raw = min(base.seconds * pow(2, exponent), cap.seconds)
        return .fromSeconds(jittered(raw, random: random))
    }

    /// Delay before the next routine poll.
    func pollDelay(interval: Duration, random: (ClosedRange<Double>) -> Double) -> Duration {
        .fromSeconds(jittered(interval.seconds, random: random))
    }

    /// A server that told us when to come back is obeyed, but never past the cap — a hostile or
    /// misconfigured `Retry-After` of a year must not silently disable flag updates for a device
    /// until the app is force-quit.
    func retryDelay(
        honouring retryAfter: TimeInterval?,
        consecutiveFailures: Int,
        random: (ClosedRange<Double>) -> Double
    ) -> Duration {
        guard let retryAfter, retryAfter > 0 else {
            return retryDelay(consecutiveFailures: consecutiveFailures, random: random)
        }
        return .fromSeconds(min(retryAfter, cap.seconds))
    }

    private func jittered(_ seconds: Double, random: (ClosedRange<Double>) -> Double) -> Double {
        let spread = seconds * jitterFraction
        return seconds + random(-spread...spread)
    }
}

extension Backoff {
    /// The production source of randomness.
    static func systemRandom(_ range: ClosedRange<Double>) -> Double {
        guard range.lowerBound < range.upperBound else { return range.lowerBound }
        return Double.random(in: range)
    }
}
