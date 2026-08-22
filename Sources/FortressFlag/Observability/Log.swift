import Foundation
import os

/// The SDK's window into the unified log.
///
/// Two rules, both from Founding §10 and §2.1:
///
/// 1. **Flag keys are `private` by default.** A customer's flag keys name their unreleased work
///    ("checkout-redesign-q3"). They are already in the app binary, but a device log is copied
///    into bug reports and shared far more casually than a binary is disassembled.
/// 2. **Nothing that could carry end-user data is ever logged**, at any policy. There is no code
///    path here that takes an evaluation context.
struct Log: Sendable {
    private let policy: LogPolicy
    private let logger: Logger

    init(policy: LogPolicy, category: String) {
        self.policy = policy
        self.logger = Logger(subsystem: "com.fortressflag.sdk", category: category)
    }

    /// Something went wrong that a developer integrating the SDK should know about. Always
    /// emitted unless logging is `.silent`, because a silent misconfiguration looks exactly like
    /// "all our flags are off".
    func error(_ message: String) {
        guard policy != .silent else { return }
        logger.error("\(message, privacy: .public)")
    }

    /// A one-time integration warning — a bad configuration, a missing entitlement.
    func warning(_ message: String) {
        guard policy != .silent else { return }
        logger.warning("\(message, privacy: .public)")
    }

    /// Lifecycle detail. Suppressed unless the caller opted into `.verbose`.
    func debug(_ message: String) {
        guard policy == .verbose else { return }
        logger.debug("\(message, privacy: .public)")
    }

    /// Lifecycle detail that names a flag key. Redacted in the log unless `.verbose`, and dropped
    /// entirely otherwise.
    func debug(_ message: String, flagKey: String) {
        guard policy == .verbose else { return }
        logger.debug("\(message, privacy: .public) key=\(flagKey, privacy: .private)")
    }
}

extension LogPolicy: Equatable {}
