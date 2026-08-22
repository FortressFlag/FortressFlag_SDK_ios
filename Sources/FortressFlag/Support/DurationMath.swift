import Foundation

extension Duration {
    /// The duration as fractional seconds.
    ///
    /// `Duration`'s own arithmetic does not cover everything jitter and backoff need, and going
    /// through `Double` in one clearly-named place beats scattering `components.attoseconds`
    /// conversions through the scheduling code.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }

    /// Clamped to zero: a negative delay is a scheduling bug, and sleeping "negatively" would
    /// silently become a busy loop against the customer's battery.
    static func fromSeconds(_ value: Double) -> Duration {
        guard value.isFinite, value > 0 else { return .zero }
        return .seconds(value)
    }
}
