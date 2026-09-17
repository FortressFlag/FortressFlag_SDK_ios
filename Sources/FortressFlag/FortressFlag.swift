import Foundation
import os

/// FortressFlag's iOS client SDK.
///
/// ## The promise
///
/// **No call in this API throws, blocks, or can crash your app.** A FortressFlag outage, a dead
/// network, a revoked key, a hostile Wi-Fi portal, a corrupt cache — all of them resolve to a flag
/// value and none of them reach your code as an error. That is the product: if flagging can take
/// an app down, it is worse than no flagging at all (Founding CLAUDE.md §8.1).
///
/// ## What this is not
///
/// **Flag values are not a security boundary.** They are evaluated on a device the end user
/// controls; anyone willing to patch your binary can turn any flag on. Use flags to decide what to
/// show, never to decide what someone is entitled to. Entitlement checks belong on your server.
///
/// ## Usage
///
/// ```swift
/// FortressFlag.start(
///     Configuration(
///         sdkKey: "ffc_prod_…",
///         environment: .production,
///         keychainAccessGroup: "com.acme.fortressflag"
///     )
/// )
///
/// if FortressFlag.isEnabled("new-checkout") {
///     // …
/// }
/// ```
public enum FortressFlag {
    private static let state = SharedState()

    // MARK: - Lifecycle

    /// Starts the SDK. Safe to call from `application(_:didFinishLaunchingWithOptions:)` or a
    /// SwiftUI `App.init`.
    ///
    /// Returns as soon as the durable cache has been read, so a flag read on the next line already
    /// sees the last values this device had. Everything else — identity, network, polling —
    /// happens in the background.
    ///
    /// Calling it a second time replaces the configuration and discards in-memory state. Invalid
    /// configuration is logged, never fatal: an app that ships with a typo'd key still launches,
    /// it just serves defaults.
    public static func start(_ configuration: Configuration) {
        let log = Log(policy: configuration.logging, category: "client")

        for problem in configuration.validate() {
            // An empty trust store under `.required` is a misconfiguration since the production
            // key shipped (ADR-0025): every payload is rejected, so it is an error, not a note.
            if problem == .signatureRequiredButNoTrustedKeys {
                log.error("configuration problem — \(problem)")
            } else {
                log.warning("configuration problem — \(problem)")
            }
        }

        let identity = KeychainDeviceIdentity(
            configuredAccessGroup: configuration.keychainAccessGroup,
            log: Log(policy: configuration.logging, category: "identity")
        )
        let api = HTTPClientAPI(
            configuration: configuration,
            log: Log(policy: configuration.logging, category: "transport")
        )
        let cache = FileEnvelopeCache(
            sdkKey: configuration.sdkKey,
            environment: configuration.environment,
            log: Log(policy: configuration.logging, category: "cache")
        )

        start(
            configuration: configuration,
            identity: identity,
            api: api,
            cache: cache,
            log: log,
            builtinTags: BuiltinTags.current()
        )
    }

    /// Dependency-injected start, used by the test suite and by `FortressFlagTestKit`.
    static func start(
        configuration: Configuration,
        identity: any DeviceIdentityProviding,
        api: any ClientAPI,
        cache: any EnvelopeCache,
        log: Log,
        builtinTags: [String: String] = [:],
        backoff: Backoff = Backoff(),
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable (ClosedRange<Double>) -> Double = Backoff.systemRandom
    ) {
        let previous = state.replaceClient(nil)
        if let previous {
            Task { await previous.stop() }
        }
        state.snapshots.reset()

        let client = FlagClient(
            configuration: configuration,
            identityProvider: identity,
            api: api,
            cache: cache,
            store: state.snapshots,
            log: log,
            builtinTags: builtinTags,
            backoff: backoff,
            now: now,
            random: random,
            notify: { changed in state.broadcast(changed) }
        )

        // Synchronous, before this function returns — see FlagClient.loadCacheIntoStore.
        let restoredETag = client.loadCacheIntoStore()

        // Marked started here rather than inside the actor, so that `diagnostics.isStarted` is
        // true the instant `start` returns. Setting it from the spawned task would leave a window
        // where the SDK is running but reports that it is not.
        state.snapshots.update { $0.isStarted = true }

        _ = state.replaceClient(client)
        Task { await client.start(restoredETag: restoredETag) }
    }

    /// Stops polling. Values already resolved keep resolving from memory and cache.
    public static func stop() {
        if let client = state.replaceClient(nil) {
            Task { await client.stop() }
        }
        state.snapshots.update { $0.isStarted = false }
    }

    // MARK: - Reading flags

    /// Whether `key` is on for this device.
    ///
    /// Synchronous and allocation-light: safe to call from a SwiftUI `body` that runs many times
    /// per frame. It reads an in-memory snapshot under an unfair lock — no I/O, no `await`, no
    /// main-thread work.
    ///
    /// The resolution order is fixed (Founding §8.4):
    /// 1. the most recent value fetched from FortressFlag
    /// 2. the last value this device recorded, from the durable cache
    /// 3. `default`, if you supplied one
    /// 4. `false`
    ///
    /// Note step 2 before step 3: a value this device actually received always beats a
    /// compiled-in default, however old it is. `default` answers "what if this device has never
    /// heard anything about this flag at all?" — not "what if we are offline?".
    public static func isEnabled(_ key: String, default defaultValue: Bool? = nil) -> Bool {
        // The kind projection (contract v2): a value that is not a boolean — a string or number
        // flag read through the boolean API — resolves to the caller's default, else `false`.
        // Fail-safe, never a coercion, never an error (Founding §8.1, §8.4): asking the wrong
        // question gets the same answer as never having heard of the flag.
        resolve(key, default: defaultValue).value.boolValue ?? defaultValue ?? false
    }

    /// The value of a STRING flag, or `default` when the flag is unknown, has no served value
    /// yet, or is not a string kind. Never throws (Founding §8.1); the cascade is `isEnabled`'s
    /// exactly — last received value, then cache, then your default.
    public static func stringValue(_ key: String, default defaultValue: String) -> String {
        let snapshot = state.snapshots.current
        let resolution = Resolver.resolve(
            key: key,
            fresh: snapshot.fresh,
            cached: snapshot.cached,
            developerDefault: .string(defaultValue)
        )
        return resolution.value.stringValue ?? defaultValue
    }

    /// The value of a NUMBER flag, or `default` under exactly `stringValue`'s rules. Numbers are
    /// float64 on the wire, as the server serves them.
    public static func numberValue(_ key: String, default defaultValue: Double) -> Double {
        let snapshot = state.snapshots.current
        let resolution = Resolver.resolve(
            key: key,
            fresh: snapshot.fresh,
            cached: snapshot.cached,
            developerDefault: .number(defaultValue)
        )
        return resolution.value.numberValue ?? defaultValue
    }

    /// As `isEnabled`, but reports the value union and where it came from. For diagnostics and
    /// for tests that want to assert on more than the projection.
    public static func resolve(_ key: String, default defaultValue: Bool? = nil) -> Resolution {
        let snapshot = state.snapshots.current
        return Resolver.resolve(
            key: key,
            fresh: snapshot.fresh,
            cached: snapshot.cached,
            developerDefault: defaultValue.map(FlagValue.bool)
        )
    }

    /// Every flag this device has received, with each key's effective value and where it came
    /// from.
    ///
    /// The keys are the union of the most recent payload and the durable cache — that is, every
    /// flag this device currently knows anything about. Values resolve through exactly the same
    /// cascade as `isEnabled`/`resolve`, so for any returned key,
    /// `allFlags()[key]?.value == isEnabled(key)`. Sources are therefore always `.fresh` or
    /// `.cached`: a key the device has never heard of is not in the dictionary at all, and there
    /// is no per-key developer default to report.
    ///
    /// Synchronous and allocation-proportional to the flag count: it reads the same lock-guarded
    /// in-memory snapshot as `isEnabled` — no I/O, no `await`. When the device holds nothing (a
    /// first launch before anything has been fetched or restored), it returns `[:]`; after
    /// `stop()` it keeps answering from the snapshot, exactly as `isEnabled` does.
    ///
    /// This enumerates only **this device's own payload** — the flag keys the server already sends
    /// this device, which ship in the app binary in any case (`docs/contract-v1.md` states and
    /// accepts this). It exposes no other device's data and nothing the management API holds
    /// (names, descriptions): the SDK never receives those.
    public static func allFlags() -> [String: Resolution] {
        let snapshot = state.snapshots.current
        return Resolver.resolveAll(fresh: snapshot.fresh, cached: snapshot.cached)
    }

    /// Fetches values now, in addition to the background poll. Never throws.
    ///
    /// Concurrent calls share one request. A good moment to call this is on foreground; a bad one
    /// is in a loop.
    @discardableResult
    public static func refresh() async -> RefreshOutcome {
        guard let client = state.client else { return .notStarted }
        return await client.refresh()
    }

    /// Replaces the custom tag set and fetches with it immediately. Never throws, never blocks.
    ///
    /// Call it when the facts a tag carries change — a login that moves the user into a cohort,
    /// a settings toggle. The replacement is whole-set: tags you omit stop being sent, and the
    /// built-in tags (`appVersion`, `appBuild`, `osVersion`, `platform`, `sdkVersion`) are
    /// always sent and cannot be overridden. Entries outside the documented limits are dropped
    /// with a logged warning naming the key (see `Configuration.tags`).
    ///
    /// The refresh it triggers coalesces with any already in flight, so calling this is never
    /// the reason you hit a rate limit. Until that refresh answers, flags keep resolving from
    /// the current values — a tag change is a reason to re-ask, not a reason to forget.
    public static func setTags(_ tags: [String: String]) {
        guard let client = state.client else { return }
        Task {
            await client.setTags(tags)
            _ = await client.refresh()
        }
    }

    // MARK: - Change notification

    /// Registers a handler for flag changes, returning a token that unregisters on deinit.
    ///
    /// The handler is called with the keys whose *effective* value changed — not everything in the
    /// payload — so it is safe to drive UI invalidation from it directly.
    ///
    /// It runs on a background context, not the main actor. Hop yourself if you touch UI; the SDK
    /// does not assume your handler is cheap, and dispatching to main on your behalf would make
    /// every notification a main-thread hop whether you needed one or not.
    public static func onChange(_ handler: @escaping @Sendable (Set<String>) -> Void) -> ObserverToken {
        let id = state.addListener(handler)
        return ObserverToken { state.removeListener(id) }
    }

    // MARK: - Privacy

    /// Deletes this device's identity and every cached value, then mints a fresh identity on next
    /// use.
    ///
    /// A real erasure path, not a flag (Founding §7.3). Call it when an end user exercises a
    /// deletion right, or when your app signs someone out of a shared device. The old identifier
    /// is unrecoverable afterwards — which is the point, and also means this device will be
    /// counted as a new one for billing.
    public static func resetIdentity() {
        state.snapshots.update {
            $0.fresh = nil
            $0.cached = nil
            $0.deviceID = nil
        }
        guard let client = state.client else { return }
        Task { await client.resetIdentity() }
    }

    /// A snapshot of what the SDK is doing. Cheap; safe to poll from a debug screen.
    public static var diagnostics: Diagnostics {
        let snapshot = state.snapshots.current
        return Diagnostics(
            isStarted: snapshot.isStarted,
            deviceIdentity: snapshot.deviceID,
            lastSuccessfulFetch: snapshot.lastSuccessfulFetch,
            freshFlagCount: snapshot.fresh?.count ?? 0,
            cachedFlagCount: snapshot.cached?.count ?? 0,
            sentTagKeys: snapshot.sentTagKeys
        )
    }
}

/// Keeps a change handler registered. Unregisters when it goes out of scope, so a forgotten token
/// leaks nothing and a retained view model does not have to remember to clean up.
public final class ObserverToken: Sendable {
    private let cancel: @Sendable () -> Void

    init(cancel: @escaping @Sendable () -> Void) {
        self.cancel = cancel
    }

    deinit { cancel() }

    /// Unregisters early.
    public func invalidate() { cancel() }
}

/// Process-wide SDK state.
///
/// A single lock guards the client reference and the listener table. The snapshot lives in its own
/// store with its own lock so that the hot read path never contends with lifecycle changes.
private final class SharedState: Sendable {
    let snapshots = SnapshotStore()

    private struct Inner {
        var client: FlagClient?
        var listeners: [UUID: @Sendable (Set<String>) -> Void] = [:]
    }

    private let inner = OSAllocatedUnfairLock(initialState: Inner())

    var client: FlagClient? {
        inner.withLock { $0.client }
    }

    /// Swaps the client and hands back the old one, so the caller can shut it down outside the
    /// lock — never call into an actor while holding one.
    func replaceClient(_ next: FlagClient?) -> FlagClient? {
        inner.withLock { state in
            let previous = state.client
            state.client = next
            return previous
        }
    }

    func addListener(_ handler: @escaping @Sendable (Set<String>) -> Void) -> UUID {
        let id = UUID()
        inner.withLock { $0.listeners[id] = handler }
        return id
    }

    func removeListener(_ id: UUID) {
        inner.withLock { _ = $0.listeners.removeValue(forKey: id) }
    }

    /// Copies the handlers out before calling any of them. A handler that registers or removes
    /// another handler would otherwise re-enter the lock and deadlock the app — in the SDK whose
    /// entire promise is that it cannot.
    func broadcast(_ changed: Set<String>) {
        let handlers = inner.withLock { Array($0.listeners.values) }
        for handler in handlers {
            handler(changed)
        }
    }
}
