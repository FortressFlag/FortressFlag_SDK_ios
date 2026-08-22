import Foundation
import os

/// Everything `isEnabled` needs, in one immutable value.
///
/// It is a single struct behind a single lock rather than several independently-updated fields so
/// that a read can never observe a half-applied refresh — fresh values from one payload alongside
/// a device ID from another.
struct Snapshot: Sendable, Equatable {
    /// Values from the most recent accepted payload.
    var fresh: [String: FlagValue]?
    /// Values from the durable cache: the last payload this device ever accepted.
    var cached: [String: FlagValue]?
    var deviceID: String?
    var lastSuccessfulFetch: Date?
    var isStarted: Bool = false
    /// The KEYS of the tags a fetch will send — built-in and custom merged, sorted. Keys only:
    /// tag values never enter the snapshot, for the same reason they never enter a log line.
    var sentTagKeys: [String] = []
}

/// Holds the snapshot for the synchronous read path.
///
/// `isEnabled` is called from SwiftUI `body`, which means it may run dozens of times per frame on
/// the main thread. It therefore cannot be `async`, cannot hop to an actor, and cannot do I/O —
/// an unfair lock around an immutable struct is the whole mechanism. The actor above does all the
/// work and publishes the result here.
final class SnapshotStore: Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Snapshot())

    var current: Snapshot {
        lock.withLock { $0 }
    }

    func update(_ body: (inout Snapshot) -> Void) {
        // `withLockUnchecked` because `body` is not `@Sendable`. It never escapes — it runs
        // synchronously inside the critical section and is gone before the lock is released — so
        // requiring callers to prove sendability would only push `@Sendable` annotations through
        // call sites that cannot race by construction.
        lock.withLockUnchecked { body(&$0) }
    }

    func reset() {
        lock.withLock { $0 = Snapshot() }
    }
}

/// What happened on a refresh. Returned rather than thrown — no SDK call throws to the caller
/// (Founding §8.1).
public enum RefreshOutcome: Sendable, Equatable {
    /// New values arrived. `changedKeys` lists the flags whose *effective* value moved, which is
    /// not the same as the flags present in the payload.
    case updated(changedKeys: Set<String>)
    /// The server confirmed nothing changed, or the payload matched what we already had.
    case unchanged
    case failed(RefreshFailure)
    /// `start` has not been called.
    case notStarted
}

/// Why a refresh did not produce new values. Deliberately coarse and stable: this is a public
/// switchable type, so it names *classes* of failure a caller might act on, not every internal
/// rejection reason. The detail goes to the log.
public enum RefreshFailure: Sendable, Equatable {
    case network
    case unauthorized
    case rateLimited
    case server
    /// A payload arrived but failed verification — bad signature, wrong environment, wrong
    /// device, expired, or a contract version this SDK does not understand.
    case rejectedPayload
    /// No device identity, so no request could be made. The keychain is unavailable.
    case noDeviceIdentity
}

/// A read-only view of what the SDK is doing, for a customer's own diagnostics screen.
public struct Diagnostics: Sendable, Equatable {
    public let isStarted: Bool
    /// The pseudonymous device identifier, if one has been minted. Safe to display and to include
    /// in a support ticket — it is random and identifies nobody.
    public let deviceIdentity: String?
    public let lastSuccessfulFetch: Date?
    /// Number of flags in the most recent accepted payload.
    public let freshFlagCount: Int
    /// Number of flags in the durable cache.
    public let cachedFlagCount: Int
    /// The keys of the tags each fetch sends — the automatic built-ins plus whatever
    /// `Configuration.tags` / `setTags` supplied, sorted. Keys only, never values: the keys are
    /// the integrator's own configuration and safe on a debug screen; the values are not
    /// exposed anywhere.
    public let sentTagKeys: [String]
}
