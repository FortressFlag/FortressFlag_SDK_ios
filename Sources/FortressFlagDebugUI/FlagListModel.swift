import Foundation
import FortressFlag
import Observation

/// The state behind `FlagListView`, separated from it so the logic — sorting, change
/// subscription, outcome description — is unit-testable without rendering SwiftUI.
///
/// `@MainActor` because it exists to drive UI, and because the SDK deliberately calls `onChange`
/// handlers off the main actor (making every notification pay for a main-thread hop whether the
/// caller needs one or not would be wrong for a library; a view model is exactly the caller that
/// does need one). The hop happens here, once, where the UI requirement lives.
@MainActor
@Observable
public final class FlagListModel {
    /// One flag as the list renders it.
    public struct Row: Identifiable, Equatable, Sendable {
        /// The flag key, as the server sends it.
        public let key: String
        /// The effective value — the contract-v2 union — resolved through the same cascade as
        /// `FortressFlag.isEnabled` and its siblings.
        public let value: FlagValue
        /// Where the value came from — `.fresh` or `.cached`, never a default; see
        /// `FortressFlag.allFlags()`.
        public let source: ValueSource

        public var id: String { key }

        /// Boolean flags only; a string/number flag reads false here and shows its scalar in
        /// `displayText`.
        public var isEnabled: Bool { value.boolValue ?? false }

        /// The value in words: On/Off for booleans, the scalar itself for the rest.
        public var displayText: String {
            switch value {
            case let .bool(bool): return bool ? "On" : "Off"
            case let .string(string): return string
            case let .number(number): return String(number)
            }
        }
    }

    /// Every flag this device knows about, sorted by key so the list is stable across refreshes.
    public private(set) var rows: [Row] = []

    /// What the SDK is doing right now. Re-read on every reload — see `refreshDiagnostics()`.
    public private(set) var diagnostics: Diagnostics

    /// The outcome of the most recent manual refresh, `nil` until one has run.
    public private(set) var lastRefreshOutcome: RefreshOutcome?

    /// Whether a manual refresh is in flight.
    public private(set) var isRefreshing = false

    /// Reads and actions, injectable so tests can drive the model without the process-global SDK.
    struct DataSource: Sendable {
        var allFlags: @Sendable () -> [String: Resolution]
        var diagnostics: @Sendable () -> Diagnostics
        var refresh: @Sendable () async -> RefreshOutcome
        var observeChanges: @Sendable (@escaping @Sendable (Set<String>) -> Void) -> ObserverToken

        static let live = DataSource(
            allFlags: { FortressFlag.allFlags() },
            diagnostics: { FortressFlag.diagnostics },
            refresh: { await FortressFlag.refresh() },
            observeChanges: { FortressFlag.onChange($0) }
        )
    }

    private let dataSource: DataSource
    private var changeToken: ObserverToken?

    /// A model reading the live SDK.
    public convenience init() {
        self.init(dataSource: .live)
    }

    init(dataSource: DataSource) {
        self.dataSource = dataSource
        self.diagnostics = dataSource.diagnostics()
        reload()

        // The token unregisters on deinit, so a discarded model leaks neither the handler nor
        // itself — hence `weak self` in a handler the SDK retains until then.
        changeToken = dataSource.observeChanges { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
    }

    /// Re-reads flags and diagnostics from the SDK. Called on appear, on every change
    /// notification, after a manual refresh, and on the view's slow tick; safe to call as often
    /// as the UI likes — two dictionary reads under a lock and a sort of a handful of keys.
    ///
    /// The tick matters more than it looks: `onChange` fires only when an *effective* value
    /// moves, so a poll can change what this screen shows without firing it — a brand-new flag
    /// arrives as `false` (no effective change, but a new row), and `lastSuccessfulFetch`
    /// advances on every successful poll. Waiting for notifications alone would leave both
    /// stale, and a debug screen that lies about what the device holds is worse than no screen.
    public func reload() {
        rows = dataSource.allFlags()
            .map { Row(key: $0.key, value: $0.value.value, source: $0.value.source) }
            .sorted { $0.key < $1.key }
        diagnostics = dataSource.diagnostics()
    }

    /// Asks the SDK to fetch now, records the outcome, and reloads. Concurrent calls coalesce in
    /// the SDK; here they just both report the shared outcome.
    public func refresh() async {
        isRefreshing = true
        let outcome = await dataSource.refresh()
        lastRefreshOutcome = outcome
        isRefreshing = false
        reload()
    }
}

extension FlagListModel {
    /// A one-line human description of a refresh outcome, for the status footer.
    ///
    /// Lives on the model rather than on `RefreshOutcome` itself: how a debug screen words an
    /// outcome is presentation, not SDK contract, and English prose on a public SDK enum would be
    /// a string customers start matching on.
    public static func describe(_ outcome: RefreshOutcome) -> String {
        switch outcome {
        case let .updated(changedKeys):
            return "Updated — \(changedKeys.count) flag(s) changed"
        case .unchanged:
            return "Up to date — no values changed"
        case .notStarted:
            return "Not started — call FortressFlag.start first"
        case let .failed(failure):
            return "Failed — \(describe(failure))"
        }
    }

    static func describe(_ failure: RefreshFailure) -> String {
        switch failure {
        case .network:
            return "network unreachable; serving last known values"
        case .unauthorized:
            return "SDK key rejected; serving last known values"
        case .rateLimited:
            return "rate limited; will retry with backoff"
        case .server:
            return "server error; serving last known values"
        case .rejectedPayload:
            return "payload failed verification; serving last known values"
        case .noDeviceIdentity:
            return "no device identity (keychain unavailable)"
        }
    }
}
