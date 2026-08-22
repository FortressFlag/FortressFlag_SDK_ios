import Foundation
import Testing
@testable import FortressFlag
import FortressFlagTestKit

@Suite("Client orchestration")
struct FlagClientTests {
    let identity = EnvelopeFixture.SigningIdentity()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var trustedKeys: TrustedKeys { TrustedKeys([identity.keyID: identity.publicKeyBytes]) }

    func envelope(
        flags: [String: FlagValue],
        environment: String = "dev",
        device: String = TestSupport.deviceID,
        expired: Bool = false
    ) -> Data {
        EnvelopeFixture(
            environment: environment,
            device: device,
            issuedAt: expired ? now.addingTimeInterval(-7200) : now,
            expiresAt: expired ? now.addingTimeInterval(-3600) : now.addingTimeInterval(1800),
            flags: flags
        ).signed(with: identity)
    }

    func makeClient(
        api: any ClientAPI,
        cache: any EnvelopeCache = InMemoryEnvelopeCache(),
        deviceIdentity: any DeviceIdentityProviding = StubIdentity(TestSupport.deviceID),
        onChange: @escaping @Sendable (Set<String>) -> Void = { _ in }
    ) -> (FlagClient, SnapshotStore) {
        let store = SnapshotStore()
        let client = FlagClient(
            configuration: TestSupport.configuration(trustedKeys: trustedKeys),
            identityProvider: deviceIdentity,
            api: api,
            cache: cache,
            store: store,
            log: .silent,
            now: TestSupport.fixedClock(now),
            random: TestSupport.noJitter,
            notify: onChange
        )
        return (client, store)
    }

    // MARK: - Accepting values

    @Test("an accepted payload reaches the snapshot and the cache")
    func acceptedPayloadIsPublishedAndCached() async {
        let cache = InMemoryEnvelopeCache()
        let raw = envelope(flags: ["alpha": true])
        let (client, store) = makeClient(
            api: StubClientAPI(always: .success(raw: raw, etag: "\"v1\"")), cache: cache
        )

        let outcome = await client.refresh()

        #expect(outcome == .updated(changedKeys: ["alpha"]))
        #expect(store.current.fresh == ["alpha": true])
        #expect(cache.contents == raw)
    }

    @Test("a rejected payload leaves the cache untouched")
    func rejectedPayloadDoesNotDisturbTheCache() async {
        // The property that matters when someone can serve us responses: they can fail to change
        // what the device knows, but they cannot erase it.
        let good = envelope(flags: ["alpha": true])
        let cache = InMemoryEnvelopeCache(seeded: good)
        let attacker = EnvelopeFixture.SigningIdentity(keyID: identity.keyID)
        let forged = EnvelopeFixture(
            environment: "dev", device: TestSupport.deviceID, issuedAt: now,
            expiresAt: now.addingTimeInterval(1800), flags: ["alpha": false]
        ).signed(with: attacker)

        let (client, _) = makeClient(
            api: StubClientAPI(always: .success(raw: forged, etag: nil)), cache: cache
        )

        let outcome = await client.refresh()

        #expect(outcome == .failed(.rejectedPayload))
        #expect(cache.contents == good)
    }

    @Test("a payload for a different environment is refused")
    func wrongEnvironmentRefused() async {
        let (client, store) = makeClient(
            api: StubClientAPI(always: .success(
                raw: envelope(flags: ["alpha": true], environment: "prod"), etag: nil))
        )

        #expect(await client.refresh() == .failed(.rejectedPayload))
        #expect(store.current.fresh == nil)
    }

    // MARK: - Cache restore

    @Test("cached values are published before any network call")
    func cacheRestoredSynchronously() {
        let cache = InMemoryEnvelopeCache(seeded: envelope(flags: ["alpha": true]), etag: "\"v1\"")
        let api = StubClientAPI(always: .failure(.offline))
        let (client, store) = makeClient(api: api, cache: cache)

        let etag = client.loadCacheIntoStore()

        #expect(etag == "\"v1\"")
        #expect(store.current.cached == ["alpha": true])
        #expect(api.requestCount == 0)
    }

    @Test("a long-expired cache entry still serves")
    func expiredCacheStillServes() {
        // A device offline for months keeps the last values it saw. Expiring the cache would turn
        // an outage into every flag reverting to false (Founding §8.4).
        let cache = InMemoryEnvelopeCache(seeded: envelope(flags: ["alpha": true], expired: true))
        let (client, store) = makeClient(api: StubClientAPI(always: .failure(.offline)), cache: cache)

        _ = client.loadCacheIntoStore()

        #expect(store.current.cached == ["alpha": true])
    }

    @Test("an unverifiable cache is discarded rather than re-read forever")
    func poisonedCacheDiscarded() {
        let cache = InMemoryEnvelopeCache(seeded: Data("not an envelope".utf8))
        let (client, store) = makeClient(api: StubClientAPI(always: .failure(.offline)), cache: cache)

        _ = client.loadCacheIntoStore()

        #expect(store.current.cached == nil)
        #expect(cache.clearCount == 1)
    }

    @Test("another device's cached envelope is rejected once we know our identity")
    func foreignCacheRejected() {
        let cache = InMemoryEnvelopeCache(
            seeded: envelope(flags: ["alpha": true], device: "dev_BBBBBBBBBBBBBBBBBBBBBB")
        )
        let (client, store) = makeClient(api: StubClientAPI(always: .failure(.offline)), cache: cache)

        _ = client.loadCacheIntoStore()

        #expect(store.current.cached == nil)
    }

    // MARK: - Failure handling

    @Test("a transport failure leaves previously fetched values in place")
    func failureKeepsValues() async {
        let api = StubClientAPI([
            .success(raw: envelope(flags: ["alpha": true]), etag: nil),
            .failure(.offline),
        ])
        let (client, store) = makeClient(api: api)

        _ = await client.refresh()
        let second = await client.refresh()

        #expect(second == .failed(.network))
        #expect(store.current.fresh == ["alpha": true])
    }

    @Test(
        "every transport failure maps to a stable public reason",
        arguments: [
            (TransportFailure.offline, RefreshFailure.network),
            (.timedOut, .network),
            (.cancelled, .network),
            (.badRequestURL, .network),
            (.unauthorized, .unauthorized),
            (.rateLimited(retryAfter: 30), .rateLimited),
            (.serverError(status: 503), .server),
            (.unexpectedStatus(418), .server),
            (.responseTooLarge, .server),
        ]
    )
    func failureMapping(transport: TransportFailure, expected: RefreshFailure) async {
        let (client, _) = makeClient(api: StubClientAPI(always: .failure(transport)))
        #expect(await client.refresh() == .failed(expected))
    }

    @Test("no device identity means no request is attempted")
    func noIdentityNoRequest() async {
        // Minting an ephemeral identity here would be worse than failing: it would put junk in the
        // billing path, and device counts are revenue-critical (Founding §6.1).
        let api = StubClientAPI(always: .success(raw: envelope(flags: ["alpha": true]), etag: nil))
        let (client, _) = makeClient(
            api: api, deviceIdentity: StubIdentity(failing: .keychainUnavailable(-34018))
        )

        #expect(await client.refresh() == .failed(.noDeviceIdentity))
        #expect(api.requestCount == 0)
    }

    // MARK: - Conditional requests

    @Test("304 is treated as success and keeps the cached values")
    func notModified() async {
        let cache = InMemoryEnvelopeCache(seeded: envelope(flags: ["alpha": true]), etag: "\"v1\"")
        let api = StubClientAPI(always: .notModified)
        let (client, store) = makeClient(api: api, cache: cache)

        let restored = client.loadCacheIntoStore()
        await client.start(restoredETag: restored)
        await client.stop()

        #expect(store.current.cached == ["alpha": true])
    }

    @Test("the stored ETag is sent on the next request")
    func etagIsSent() async {
        let api = StubClientAPI([
            .success(raw: envelope(flags: ["alpha": true]), etag: "\"v7\""),
            .notModified,
        ])
        let (client, _) = makeClient(api: api)

        _ = await client.refresh()
        _ = await client.refresh()

        #expect(api.requests.last?.etag == "\"v7\"")
    }

    // MARK: - Change notification

    @Test("only effective changes are broadcast")
    func changeNotification() async {
        let received = Locked<[Set<String>]>([])
        let api = StubClientAPI([
            .success(raw: envelope(flags: ["alpha": true, "beta": false]), etag: nil),
            .success(raw: envelope(flags: ["alpha": true, "beta": true]), etag: nil),
        ])
        let (client, _) = makeClient(api: api, onChange: { changed in
            received.mutate { $0.append(changed) }
        })

        _ = await client.refresh()
        _ = await client.refresh()

        // The first payload reports only "alpha". "beta" arrived as false, and false is already
        // what the cascade resolves for a flag nobody has heard of — so its effective value did
        // not move and broadcasting it would wake UI for nothing.
        #expect(received.value == [["alpha"], ["beta"]])
    }

    @Test("an identical payload reports unchanged and notifies nobody")
    func identicalPayloadIsQuiet() async {
        let raw = envelope(flags: ["alpha": true])
        let received = Locked<Int>(0)
        let (client, _) = makeClient(
            api: StubClientAPI([.success(raw: raw, etag: nil), .success(raw: raw, etag: nil)]),
            onChange: { _ in received.mutate { $0 += 1 } }
        )

        _ = await client.refresh()
        #expect(await client.refresh() == .unchanged)
        #expect(received.value == 1)
    }

    // MARK: - Coalescing

    @Test("concurrent refreshes share a single request")
    func refreshesCoalesce() async {
        // Without this, an app calling refresh() from several screens on foreground makes the SDK
        // the reason the customer hits their own rate limit.
        let api = SlowStubClientAPI(outcome: .success(raw: envelope(flags: ["alpha": true]), etag: nil))
        let (client, _) = makeClient(api: api)

        async let first = client.refresh()
        async let second = client.refresh()
        async let third = client.refresh()
        _ = await (first, second, third)

        #expect(api.requestCount == 1)
    }

    // MARK: - Identity reset

    @Test("resetting identity clears values and the cache")
    func resetIdentity() async {
        let cache = InMemoryEnvelopeCache()
        let (client, store) = makeClient(
            api: StubClientAPI(always: .success(raw: envelope(flags: ["alpha": true]), etag: nil)),
            cache: cache
        )

        _ = await client.refresh()
        await client.resetIdentity()

        #expect(store.current.fresh == nil)
        #expect(store.current.cached == nil)
        #expect(cache.contents == nil)
    }
}

/// A transport that yields before answering, so concurrent callers genuinely overlap.
final class SlowStubClientAPI: ClientAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let outcome: FetchOutcome

    init(outcome: FetchOutcome) { self.outcome = outcome }

    func fetch(deviceID: String, etag: String?, tags: String?) async -> FetchOutcome {
        lock.withLock { count += 1 }
        try? await Task.sleep(for: .milliseconds(50))
        return outcome
    }

    var requestCount: Int {
        lock.withLock { count }
    }
}

/// Minimal lock-protected box for collecting callback output in tests.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.withLock { storage }
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.withLock { body(&storage) }
    }
}
