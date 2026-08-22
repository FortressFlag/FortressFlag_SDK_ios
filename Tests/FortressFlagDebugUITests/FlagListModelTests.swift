import Foundation
import Testing
@testable import FortressFlag
@testable import FortressFlagDebugUI

/// The view model behind the debug flag list. Driven entirely through the injectable data
/// source — no global SDK state, no rendering — so these run anywhere `swift test` does.
@MainActor
@Suite("FlagListModel")
struct FlagListModelTests {
    /// A scriptable stand-in for the SDK, with a captured change handler so tests can fire
    /// notifications the way the real SDK does: from off the main actor.
    final class StubSource: @unchecked Sendable {
        private let lock = NSLock()
        private var flags: [String: Resolution]
        private var diagnostics: Diagnostics
        private var outcome: RefreshOutcome
        private var handler: (@Sendable (Set<String>) -> Void)?

        init(
            flags: [String: Resolution] = [:],
            diagnostics: Diagnostics = StubSource.someDiagnostics(),
            outcome: RefreshOutcome = .unchanged
        ) {
            self.flags = flags
            self.diagnostics = diagnostics
            self.outcome = outcome
        }

        static func someDiagnostics(
            isStarted: Bool = true,
            fetch: Date? = nil,
            fresh: Int = 0,
            cached: Int = 0
        ) -> Diagnostics {
            Diagnostics(
                isStarted: isStarted,
                deviceIdentity: "dev_AAAAAAAAAAAAAAAAAAAAAA",
                lastSuccessfulFetch: fetch,
                freshFlagCount: fresh,
                cachedFlagCount: cached,
                sentTagKeys: ["appVersion", "platform", "sdkVersion"]
            )
        }

        func set(flags: [String: Resolution]) {
            lock.withLock { self.flags = flags }
        }

        func set(diagnostics: Diagnostics) {
            lock.withLock { self.diagnostics = diagnostics }
        }

        /// Fires the captured change handler off the main actor, as the SDK does.
        func notifyChange(_ keys: Set<String>) {
            let captured = lock.withLock { handler }
            captured?(keys)
        }

        var dataSource: FlagListModel.DataSource {
            FlagListModel.DataSource(
                allFlags: { [self] in lock.withLock { flags } },
                diagnostics: { [self] in lock.withLock { diagnostics } },
                refresh: { [self] in lock.withLock { outcome } },
                observeChanges: { [self] newHandler in
                    lock.withLock { handler = newHandler }
                    return ObserverToken(cancel: {})
                }
            )
        }
    }

    /// Polls until `condition` holds or a deadline passes — the change notification hops actors,
    /// so its effect is not observable synchronously.
    func eventually(
        _ condition: @MainActor () -> Bool,
        within timeout: Duration = .seconds(2)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("rows are sorted by key and carry value and provenance")
    func rowsSortedAndMapped() {
        let source = StubSource(flags: [
            "zulu": Resolution(value: true, source: .fresh),
            "alpha": Resolution(value: false, source: .cached),
        ])
        let model = FlagListModel(dataSource: source.dataSource)

        #expect(model.rows.map(\.key) == ["alpha", "zulu"])
        #expect(model.rows[0] == FlagListModel.Row(key: "alpha", value: .bool(false), source: .cached))
        #expect(model.rows[1] == FlagListModel.Row(key: "zulu", value: .bool(true), source: .fresh))
    }

    @Test("no flags is an empty row list, ready for the designed empty state")
    func emptyRows() {
        let model = FlagListModel(dataSource: StubSource().dataSource)
        #expect(model.rows.isEmpty)
        #expect(model.lastRefreshOutcome == nil)
    }

    @Test("a change notification from off the main actor reloads the rows")
    func changeNotificationReloads() async {
        let source = StubSource(flags: ["alpha": Resolution(value: false, source: .fresh)])
        let model = FlagListModel(dataSource: source.dataSource)
        #expect(model.rows.first?.isEnabled == false)

        source.set(flags: ["alpha": Resolution(value: true, source: .fresh)])
        await Task.detached { source.notifyChange(["alpha"]) }.value

        let reloaded = await eventually { model.rows.first?.isEnabled == true }
        #expect(reloaded, "the model should hop to the main actor and reload after a change")
    }

    @Test("refresh records the outcome and reloads")
    func refreshRecordsOutcome() async {
        let source = StubSource(outcome: .updated(changedKeys: ["alpha"]))
        let model = FlagListModel(dataSource: source.dataSource)

        source.set(flags: ["alpha": Resolution(value: true, source: .fresh)])
        await model.refresh()

        #expect(model.lastRefreshOutcome == .updated(changedKeys: ["alpha"]))
        #expect(model.rows.map(\.key) == ["alpha"])
        #expect(model.isRefreshing == false)
    }

    @Test("reload picks up a new flag that fired no change notification")
    func reloadSeesNewOffFlag() {
        // A freshly created flag arrives as Off: no effective value moves, so onChange never
        // fires — the view's slow tick calling reload() is the only way it appears. This test
        // pins that path so nobody "optimises" the tick back down to diagnostics-only.
        let source = StubSource(flags: ["alpha": Resolution(value: true, source: .fresh)])
        let model = FlagListModel(dataSource: source.dataSource)
        #expect(model.rows.map(\.key) == ["alpha"])

        let fetch = Date(timeIntervalSince1970: 1_800_000_000)
        source.set(flags: [
            "alpha": Resolution(value: true, source: .fresh),
            "brand-new": Resolution(value: false, source: .fresh),
        ])
        source.set(diagnostics: StubSource.someDiagnostics(fetch: fetch, fresh: 2))
        model.reload()

        #expect(model.rows.map(\.key) == ["alpha", "brand-new"])
        #expect(model.diagnostics.lastSuccessfulFetch == fetch)
        #expect(model.diagnostics.freshFlagCount == 2)
    }

    @Test("every refresh outcome has a human description")
    func outcomeDescriptions() {
        // The wording is presentation and may change; what must hold is that no outcome renders
        // as an empty string, and failures explain that cached values keep serving.
        let outcomes: [RefreshOutcome] = [
            .updated(changedKeys: ["a"]),
            .unchanged,
            .notStarted,
            .failed(.network),
            .failed(.unauthorized),
            .failed(.rateLimited),
            .failed(.server),
            .failed(.rejectedPayload),
            .failed(.noDeviceIdentity),
        ]
        for outcome in outcomes {
            #expect(!FlagListModel.describe(outcome).isEmpty)
        }
        #expect(FlagListModel.describe(.failed(.network)).contains("last known values"))
    }
}
