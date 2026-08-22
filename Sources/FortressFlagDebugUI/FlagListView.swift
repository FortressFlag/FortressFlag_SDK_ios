import FortressFlag
import SwiftUI

/// The development flag list: every flag key this device has received, its effective value, and
/// what the SDK is doing.
///
/// This is the screen a developer debugs an integration against, so it is built to answer "is it
/// even talking?" before it answers anything else: the diagnostics section is always present, the
/// values name their provenance (fresh vs cached), and a refresh reports its outcome in words.
///
/// It renders only what `FortressFlag.allFlags()` exposes — this device's own payload, whose keys
/// ship in the app binary anyway. There is deliberately no error UI for flag reads: the SDK never
/// throws, so there are only states to render, never failures to catch.
///
/// Host it wherever a debug surface fits; a `NavigationStack` gives it a title, and
/// pull-to-refresh works regardless:
///
/// ```swift
/// NavigationStack {
///     FlagListView()
/// }
/// ```
public struct FlagListView: View {
    @State private var model = FlagListModel()

    public init() {}

    public var body: some View {
        List {
            flagsSection
            diagnosticsSection
        }
        .navigationTitle("Feature flags")
        // Pull-to-refresh is the only manual-refresh affordance, deliberately — it is the
        // gesture every iOS developer already reaches for on a list, and a toolbar button was
        // chrome duplicating it. On macOS, where the pull gesture does not exist, the background
        // poll and the slow tick below keep the screen current on their own.
        .refreshable {
            await model.refresh()
        }
        .task {
            // A slow tick re-reads everything for as long as the screen is visible. Change
            // notifications alone are not enough: a poll can add a new flag (arriving Off — no
            // effective change, no notification) or advance lastSuccessfulFetch, and both must
            // show here. Reading a lock-guarded snapshot twice a second costs nothing; the loop
            // dies with the view via task cancellation. See FlagListModel.reload.
            model.reload()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                model.reload()
            }
        }
    }

    // MARK: - Flags

    @ViewBuilder
    private var flagsSection: some View {
        Section {
            if model.rows.isEmpty {
                emptyState
            } else {
                ForEach(model.rows) { row in
                    flagRow(row)
                }
            }
        } header: {
            Text("Flags")
        } footer: {
            if let outcome = model.lastRefreshOutcome {
                Text(FlagListModel.describe(outcome))
            }
        }
    }

    private func flagRow(_ row: FlagListModel.Row) -> some View {
        // State is carried in words as well as in colour and symbol shape — never colour alone.
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.key)
                    .font(.body.monospaced())
                Text(source(of: row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(
                row.displayText,
                systemImage: row.isEnabled ? "checkmark.circle.fill" : "circle"
            )
            .labelStyle(.titleAndIcon)
            .font(.callout.weight(.medium))
            .foregroundStyle(row.isEnabled ? Color.green : Color.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func source(of row: FlagListModel.Row) -> String {
        switch row.source {
        case .fresh:
            return "fresh from server"
        case .cached:
            return "from durable cache"
        case .developerDefault, .safeDefault:
            // Unreachable from allFlags() — enumeration only reports values the device has — but
            // rendered honestly rather than trapped on, should the enumeration contract ever grow.
            return "default"
        }
    }

    /// "No flags yet" is a designed state, not an accident: it is what a first launch looks like
    /// before the first poll answers, and what a misconfigured key looks like forever. Point at
    /// the diagnostics instead of leaving a blank screen.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No flags received yet", systemImage: "flag.slash")
        } description: {
            Text(
                """
                Nothing has been fetched and nothing is cached. If this persists, the \
                diagnostics below say whether the SDK is started and when it last reached \
                the server.
                """
            )
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            LabeledContent("Started", value: model.diagnostics.isStarted ? "Yes" : "No")
            LabeledContent("Device identity", value: deviceIdentity)
            LabeledContent("Last successful fetch", value: lastFetch)
            LabeledContent("Fresh flags", value: "\(model.diagnostics.freshFlagCount)")
            LabeledContent("Cached flags", value: "\(model.diagnostics.cachedFlagCount)")
            LabeledContent("Tags sent", value: tagsSent)
        }
        .font(.callout)
    }

    /// Keys only, which is all `Diagnostics` exposes: the keys are the integrator's own
    /// configuration plus the SDK's built-ins, fine on a debug screen; the values are not
    /// surfaced anywhere.
    private var tagsSent: String {
        let keys = model.diagnostics.sentTagKeys
        return keys.isEmpty ? "none" : keys.joined(separator: ", ")
    }

    /// Safe to display: the identity is a random pseudonym that identifies nobody (see
    /// `Diagnostics.deviceIdentity`).
    private var deviceIdentity: String {
        model.diagnostics.deviceIdentity ?? "not yet minted"
    }

    private var lastFetch: String {
        guard let date = model.diagnostics.lastSuccessfulFetch else { return "never" }
        return date.formatted(date: .omitted, time: .standard)
    }
}
