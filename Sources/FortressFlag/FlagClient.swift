import Foundation

/// Orchestrates identity, transport and cache, and publishes results into the `SnapshotStore`.
///
/// An actor because everything it owns is mutable state touched from a polling task, from
/// `refresh()` calls made by the host app, and from lifecycle events. The one thing it does *not*
/// own is the read path — see `SnapshotStore`.
actor FlagClient {
    private let configuration: Configuration
    private let identityProvider: any DeviceIdentityProviding
    private let api: any ClientAPI
    private let cache: any EnvelopeCache
    private let store: SnapshotStore
    private let log: Log
    private let backoff: Backoff
    private let now: @Sendable () -> Date
    private let random: @Sendable (ClosedRange<Double>) -> Double
    private let notify: @Sendable (Set<String>) -> Void

    private var etag: String?
    private var inFlight: Task<RefreshOutcome, Never>?
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var lastRetryAfter: TimeInterval?

    /// The tags every fetch carries. Built-ins are fixed for the process lifetime; the custom
    /// set starts from `Configuration.tags` and is replaced by `setTags`. `encodedTags` is the
    /// pre-computed header value — encoding is deterministic and the set changes rarely, so it
    /// is paid per change, not per poll.
    private let builtinTags: [String: String]
    private var customTags: [String: String]
    private var encodedTags: String?

    init(
        configuration: Configuration,
        identityProvider: any DeviceIdentityProviding,
        api: any ClientAPI,
        cache: any EnvelopeCache,
        store: SnapshotStore,
        log: Log,
        builtinTags: [String: String] = [:],
        backoff: Backoff = Backoff(),
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable (ClosedRange<Double>) -> Double = Backoff.systemRandom,
        notify: @escaping @Sendable (Set<String>) -> Void
    ) {
        self.configuration = configuration
        self.identityProvider = identityProvider
        self.api = api
        self.cache = cache
        self.store = store
        self.log = log
        self.builtinTags = builtinTags
        self.customTags = Tags.sanitize(
            configuration.tags, reserved: BuiltinTags.reservedKeys, log: log
        )
        self.encodedTags = Tags.encode(builtin: builtinTags, custom: customTags, log: log)
        self.backoff = backoff
        self.now = now
        self.random = random
        self.notify = notify
    }

    // MARK: - Lifecycle

    /// Begins polling. `restoredETag` comes from the synchronous cache load the facade already
    /// performed — see `loadCacheIntoStore`.
    func start(restoredETag: String?) {
        etag = restoredETag
        publishTagKeys()

        // The identity is resolved here rather than on the caller's thread: minting touches the
        // keychain, which can block, and app launch must not pay for it.
        if case let .success(deviceID) = identityProvider.identity() {
            store.update { $0.deviceID = deviceID }
        }

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        inFlight?.cancel()
        inFlight = nil
    }

    func resetIdentity() {
        identityProvider.reset()
        cache.clear()
        etag = nil
        consecutiveFailures = 0
        store.update {
            $0.fresh = nil
            $0.cached = nil
            $0.deviceID = nil
        }
        log.debug("identity and cached values cleared")
    }

    // MARK: - Tags

    /// Replaces the custom tag set. The caller (the facade) follows with one coalesced
    /// `refresh()`, so a login-driven tag takes effect within a request rather than a poll.
    func setTags(_ tags: [String: String]) {
        customTags = Tags.sanitize(tags, reserved: BuiltinTags.reservedKeys, log: log)
        let encoded = Tags.encode(builtin: builtinTags, custom: customTags, log: log)
        if encoded != encodedTags {
            // A different tag set can mean a different payload for this same device, so the
            // stored validator no longer names what the next response would be. The server sends
            // no ETag yet (M3); clearing now is what keeps this correct when it does.
            etag = nil
        }
        encodedTags = encoded
        publishTagKeys()
        log.debug("custom tags replaced (\(customTags.count) tag(s) kept)")
    }

    /// Publishes the KEYS of what a fetch will send, for the diagnostics screen. Keys only —
    /// values stay out of the snapshot for the same reason they stay out of logs.
    private func publishTagKeys() {
        let keys = Set(customTags.keys).union(builtinTags.keys).sorted()
        store.update { $0.sentTagKeys = keys }
    }

    // MARK: - Refresh

    /// Fetches new values, coalescing concurrent callers onto one request.
    ///
    /// Coalescing is not an optimisation here. Without it, an app that calls `refresh()` from
    /// several screens on foreground would issue several identical requests, and the SDK would be
    /// the reason the customer hit their own rate limit.
    func refresh() async -> RefreshOutcome {
        if let inFlight {
            return await inFlight.value
        }

        let task = Task { [weak self] () -> RefreshOutcome in
            guard let self else { return .notStarted }
            return await self.performRefresh()
        }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    private func performRefresh() async -> RefreshOutcome {
        let deviceID: String
        switch identityProvider.identity() {
        case let .success(value):
            deviceID = value
            store.update { $0.deviceID = value }
        case let .failure(failure):
            log.debug("no device identity available: \(failure)")
            recordFailure(retryAfter: nil)
            return .failed(.noDeviceIdentity)
        }

        let outcome = await api.fetch(deviceID: deviceID, etag: etag, tags: encodedTags)

        switch outcome {
        case .notModified:
            // A 304 is a successful conversation with the server, so it counts as a fetch. Leaving
            // `lastSuccessfulFetch` stale would make a perfectly healthy device — one whose flags
            // simply have not changed for a week — look, on a diagnostics screen, exactly like one
            // that has been failing for a week.
            recordSuccess()
            store.update { $0.lastSuccessfulFetch = self.now() }
            return .unchanged

        case let .failure(failure):
            log.debug("flag fetch failed: \(failure)")
            let retryAfter: TimeInterval?
            if case let .rateLimited(seconds) = failure { retryAfter = seconds } else { retryAfter = nil }
            recordFailure(retryAfter: retryAfter)
            return .failed(Self.classify(failure))

        case let .success(raw, responseETag):
            return accept(raw: raw, etag: responseETag, deviceID: deviceID)
        }
    }

    /// Verifies a freshly-fetched payload and, only if it passes, promotes it to both the live
    /// snapshot and the durable cache.
    ///
    /// A rejected payload leaves the cache untouched. That ordering is the point: an attacker who
    /// can serve responses cannot erase what the device already knows, they can only fail to
    /// change it.
    private func accept(raw: Data, etag responseETag: String?, deviceID: String) -> RefreshOutcome {
        let expectations = EnvelopeVerifier.Expectations(
            environment: configuration.environment,
            deviceID: deviceID,
            now: now()
        )

        let verification = EnvelopeVerifier.verify(
            raw: raw, policy: configuration.signaturePolicy, expectations: expectations
        )
        switch verification {
        case let .failure(rejection):
            log.error("rejected a flag payload: \(rejection). Serving the last known values.")
            recordFailure(retryAfter: nil)
            return .failed(.rejectedPayload)

        case let .success(verified):
            let previous = store.current
            let changed = Resolver.changedKeys(
                from: previous.fresh,
                to: verified.payload.flags,
                cached: previous.cached
            )

            cache.store(raw, etag: responseETag)
            etag = responseETag
            store.update {
                $0.fresh = verified.payload.flags
                // The cache mirrors the accepted payload so that the two never disagree within a
                // launch, and so a later rejection falls back to something we have verified.
                $0.cached = verified.payload.flags
                $0.lastSuccessfulFetch = self.now()
            }
            recordSuccess()

            if changed.isEmpty {
                return .unchanged
            }
            log.debug("flag values changed (\(changed.count) key(s))")
            notify(changed)
            return .updated(changedKeys: changed)
        }
    }

    // MARK: - Cache

    /// Reads the durable cache and publishes it, returning the stored ETag.
    ///
    /// `nonisolated` — and therefore synchronous — on purpose. It runs on the caller's thread
    /// during `FortressFlag.start`, before that call returns, so that an `isEnabled` on the very
    /// next line of the host app's launch already sees the last values this device had. Deferring
    /// it to a `Task` would mean every cold start briefly answers `false` for every flag, which is
    /// a visible flicker of un-launched features and precisely what the durable cache exists to
    /// prevent (Founding §8.4).
    ///
    /// It touches only immutable dependencies and the lock-protected `SnapshotStore`, which is
    /// what makes running it outside the actor safe.
    nonisolated func loadCacheIntoStore() -> String? {
        guard let cached = cache.load() else { return nil }

        // The identity may not be resolvable yet; the verifier skips the device check when it is
        // nil rather than discarding the fallback. See `Expectations.deviceID`.
        let knownDevice: String?
        if case let .success(value) = identityProvider.identity() {
            knownDevice = value
        } else {
            knownDevice = nil
        }

        let expectations = EnvelopeVerifier.Expectations(
            environment: configuration.environment,
            deviceID: knownDevice,
            now: now(),
            // Expiry is a freshness signal, not a validity one. An offline device must keep
            // serving what it last saw for as long as it stays offline (Founding §8.4).
            enforceExpiry: false
        )

        let verification = EnvelopeVerifier.verify(
            raw: cached.raw, policy: configuration.signaturePolicy, expectations: expectations
        )
        switch verification {
        case let .success(verified):
            store.update { $0.cached = verified.payload.flags }
            log.debug("restored \(verified.payload.flags.count) cached flag value(s)")
            return cached.etag

        case let .failure(rejection):
            // A cache we cannot verify is a cache we cannot use. Removing it stops us re-reading
            // and re-rejecting the same bytes on every launch, and an unverifiable file is exactly
            // what a poisoning attempt looks like.
            log.warning("discarding an unverifiable flag cache: \(rejection)")
            cache.clear()
            return nil
        }
    }

    // MARK: - Polling

    private func pollLoop() async {
        while !Task.isCancelled {
            _ = await refresh()

            let delay = consecutiveFailures > 0
                ? backoff.retryDelay(
                    honouring: lastRetryAfter,
                    consecutiveFailures: consecutiveFailures,
                    random: random)
                : backoff.pollDelay(interval: configuration.refreshInterval, random: random)

            do {
                try await Task.sleep(for: delay)
            } catch {
                // Cancellation. The only way out of the loop.
                return
            }
        }
    }

    private func recordSuccess() {
        consecutiveFailures = 0
        lastRetryAfter = nil
    }

    private func recordFailure(retryAfter: TimeInterval?) {
        // Saturating rather than wrapping: a device offline for a very long time keeps the cap,
        // it does not wrap around to retrying every two seconds.
        consecutiveFailures = min(consecutiveFailures + 1, Int.max - 1)
        lastRetryAfter = retryAfter
    }

    private static func classify(_ failure: TransportFailure) -> RefreshFailure {
        switch failure {
        case .offline, .timedOut, .cancelled, .other, .badRequestURL, .insecureTransportRefused:
            return .network
        case .unauthorized:
            return .unauthorized
        case .rateLimited:
            return .rateLimited
        case .serverError, .unexpectedStatus, .responseTooLarge:
            return .server
        }
    }
}
