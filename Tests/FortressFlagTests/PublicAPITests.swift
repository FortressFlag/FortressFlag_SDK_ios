import Foundation
import Testing
@testable import FortressFlag
import FortressFlagTestKit

/// The surface customers actually touch.
///
/// Serialized, because `FortressFlag` is deliberately process-global: an SDK that made every
/// caller thread a configuration object through their view hierarchy would not get adopted.
@Suite("Public API", .serialized)
struct PublicAPITests {
    let signing = EnvelopeFixture.SigningIdentity()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var trustedKeys: TrustedKeys { TrustedKeys([signing.keyID: signing.publicKeyBytes]) }

    func envelope(_ flags: [String: FlagValue]) -> Data {
        EnvelopeFixture(
            environment: "dev",
            device: TestSupport.deviceID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(1800),
            flags: flags
        ).signed(with: signing)
    }

    /// Starts the SDK against fakes. Mirrors the production `start` exactly, minus the network,
    /// the keychain and the filesystem.
    func startSDK(
        api: any ClientAPI = StubClientAPI(always: .failure(.offline)),
        cache: any EnvelopeCache = InMemoryEnvelopeCache(),
        identity: any DeviceIdentityProviding = StubIdentity(TestSupport.deviceID)
    ) {
        FortressFlag.start(
            configuration: TestSupport.configuration(trustedKeys: trustedKeys),
            identity: identity,
            api: api,
            cache: cache,
            log: .silent,
            now: TestSupport.fixedClock(now),
            random: TestSupport.noJitter
        )
    }

    // MARK: - Before start

    @Test("reading a flag before start is safe and returns the safe default")
    func beforeStart() {
        FortressFlag.stop()
        #expect(FortressFlag.isEnabled("anything") == false)
        #expect(FortressFlag.isEnabled("anything", default: true) == true)
        #expect(FortressFlag.resolve("anything").source == .safeDefault)
    }

    @Test("refreshing before start reports notStarted rather than failing")
    func refreshBeforeStart() async {
        FortressFlag.stop()
        #expect(await FortressFlag.refresh() == .notStarted)
    }

    // MARK: - Start

    @Test("cached values are readable on the line after start returns")
    func cacheIsHotImmediately() {
        // The whole reason `loadCacheIntoStore` is synchronous. If this were deferred to a Task,
        // every cold start would briefly answer false for every flag — a visible flicker of
        // un-launched features on the customer's launch screen.
        startSDK(cache: InMemoryEnvelopeCache(seeded: envelope(["alpha": true])))
        defer { FortressFlag.stop() }

        #expect(FortressFlag.isEnabled("alpha"))
        #expect(FortressFlag.resolve("alpha").source == .cached)
    }

    @Test("diagnostics report started as soon as start returns")
    func startedImmediately() {
        startSDK()
        defer { FortressFlag.stop() }
        #expect(FortressFlag.diagnostics.isStarted)
    }

    @Test("starting twice discards the previous configuration's values")
    func restartResetsState() {
        startSDK(cache: InMemoryEnvelopeCache(seeded: envelope(["alpha": true])))
        #expect(FortressFlag.isEnabled("alpha"))

        startSDK(cache: InMemoryEnvelopeCache())
        defer { FortressFlag.stop() }

        // Otherwise a customer who reconfigures at runtime — switching environments in a debug
        // build, say — would read the previous environment's values.
        #expect(FortressFlag.isEnabled("alpha") == false)
    }

    // MARK: - Reading

    @Test("a fetched value is readable and reports its source")
    func fetchedValue() async {
        startSDK(api: StubClientAPI(always: .success(raw: envelope(["alpha": true]), etag: nil)))
        defer { FortressFlag.stop() }

        _ = await FortressFlag.refresh()

        #expect(FortressFlag.isEnabled("alpha"))
        #expect(FortressFlag.resolve("alpha").source == .fresh)
    }

    @Test("a developer default never overrides a value this device recorded")
    func defaultDoesNotOverrideCache() {
        startSDK(cache: InMemoryEnvelopeCache(seeded: envelope(["alpha": false])))
        defer { FortressFlag.stop() }

        #expect(FortressFlag.isEnabled("alpha", default: true) == false)
    }

    @Test("reading is safe from many threads at once")
    func concurrentReads() async {
        // `isEnabled` is called from SwiftUI bodies, which means many threads, many times per
        // frame. This is the shape of the access pattern, not an artificial stress test.
        startSDK(cache: InMemoryEnvelopeCache(seeded: envelope(["alpha": true])))
        defer { FortressFlag.stop() }

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<200 {
                group.addTask { FortressFlag.isEnabled("alpha") }
            }
            for await value in group {
                #expect(value)
            }
        }
    }

    // MARK: - Enumeration

    @Test("allFlags with nothing fetched and nothing cached is empty")
    func allFlagsEmpty() {
        // Not asserted "before start": like isEnabled, allFlags keeps answering from the
        // snapshot after stop(), so mid-process the honest empty case is a fresh start with an
        // empty cache.
        startSDK()
        defer { FortressFlag.stop() }
        #expect(FortressFlag.allFlags().isEmpty)
    }

    @Test("allFlags reports every key with the same value and source as single reads")
    func allFlagsMatchesSingleReads() async {
        startSDK(
            api: StubClientAPI(always: .success(raw: envelope(["alpha": true, "beta": false]), etag: nil))
        )
        defer { FortressFlag.stop() }

        _ = await FortressFlag.refresh()
        let all = FortressFlag.allFlags()

        #expect(all.keys.sorted() == ["alpha", "beta"])
        for (key, resolution) in all {
            #expect(resolution.value == FlagValue.bool(FortressFlag.isEnabled(key)))
            #expect(resolution == FortressFlag.resolve(key))
        }
        #expect(all["alpha"]?.source == .fresh)
    }

    @Test("allFlags restored from cache reports cached provenance")
    func allFlagsFromCache() {
        startSDK(cache: InMemoryEnvelopeCache(seeded: envelope(["alpha": true])))
        defer { FortressFlag.stop() }

        let all = FortressFlag.allFlags()
        #expect(all["alpha"] == Resolution(value: true, source: .cached))
    }

    @Test("a key that leaves the payload leaves allFlags on the same refresh")
    func allFlagsDropsRemovedKeys() async {
        // Archiving a flag in the dashboard removes it from the payload, and the SDK's wholesale
        // cache overwrite means it stops being enumerable within one poll — ADR-0003's blast
        // radius, asserted here so the debug list is guaranteed to show it.
        startSDK(
            api: StubClientAPI([
                .success(raw: envelope(["alpha": true, "beta": true]), etag: nil),
                .success(raw: envelope(["beta": true]), etag: nil),
            ])
        )
        defer { FortressFlag.stop() }

        _ = await FortressFlag.refresh()
        #expect(FortressFlag.allFlags().keys.sorted() == ["alpha", "beta"])

        _ = await FortressFlag.refresh()
        #expect(FortressFlag.allFlags().keys.sorted() == ["beta"])
        #expect(FortressFlag.resolve("alpha").source == .safeDefault)
    }

    // MARK: - Change notification

    @Test("a change handler fires for effective changes")
    func changeHandler() async {
        let received = Locked<[Set<String>]>([])
        startSDK(api: StubClientAPI([.success(raw: envelope(["alpha": true]), etag: nil)]))
        let token = FortressFlag.onChange { keys in received.mutate { $0.append(keys) } }
        defer {
            token.invalidate()
            FortressFlag.stop()
        }

        _ = await FortressFlag.refresh()

        #expect(received.value == [["alpha"]])
    }

    @Test("an invalidated handler stops firing")
    func handlerInvalidation() async {
        let received = Locked<Int>(0)
        startSDK(api: StubClientAPI([.success(raw: envelope(["alpha": true]), etag: nil)]))
        defer { FortressFlag.stop() }

        let token = FortressFlag.onChange { _ in received.mutate { $0 += 1 } }
        token.invalidate()

        _ = await FortressFlag.refresh()
        #expect(received.value == 0)
    }

    // MARK: - Privacy

    @Test("resetIdentity clears values immediately")
    func resetIdentityClearsValues() {
        // A deletion right is not honoured "eventually". The in-memory values go on the calling
        // thread, before this returns; the keychain and cache follow on the actor.
        startSDK(cache: InMemoryEnvelopeCache(seeded: envelope(["alpha": true])))
        defer { FortressFlag.stop() }

        #expect(FortressFlag.isEnabled("alpha"))
        FortressFlag.resetIdentity()
        #expect(FortressFlag.isEnabled("alpha") == false)
    }

    @Test("diagnostics expose the device identity and nothing else identifying")
    func diagnostics() async {
        startSDK(api: StubClientAPI(always: .success(raw: envelope(["alpha": true]), etag: nil)))
        defer { FortressFlag.stop() }

        _ = await FortressFlag.refresh()
        let diagnostics = FortressFlag.diagnostics

        #expect(diagnostics.deviceIdentity == TestSupport.deviceID)
        #expect(diagnostics.freshFlagCount == 1)
        #expect(diagnostics.lastSuccessfulFetch == now)
    }

    // MARK: - Stop

    @Test("stop leaves reads working and reports not started")
    func stopKeepsReadsWorking() async {
        startSDK(cache: InMemoryEnvelopeCache(seeded: envelope(["alpha": true])))
        FortressFlag.stop()

        // Stopping the poll must not blind the app. Values already resolved keep resolving.
        #expect(FortressFlag.isEnabled("alpha"))
        #expect(FortressFlag.diagnostics.isStarted == false)
        #expect(await FortressFlag.refresh() == .notStarted)
    }
}

// MARK: - The value union (contract v2)

extension PublicAPITests {
    @Test("stringValue and numberValue serve the union; isEnabled keeps its exact behaviour")
    func valueUnion() async {
        startSDK(api: StubClientAPI(always: .success(
            raw: envelope(["dark-mode": true, "checkout-cta": "buy-now", "retry-limit": 3]),
            etag: nil
        )))
        defer { FortressFlag.stop() }
        _ = await FortressFlag.refresh()

        #expect(FortressFlag.stringValue("checkout-cta", default: "control") == "buy-now")
        #expect(FortressFlag.numberValue("retry-limit", default: 1) == 3)
        #expect(FortressFlag.isEnabled("dark-mode"))

        // The kind projections are fail-safe, never coercions (Founding §8.1): asking a string
        // flag the boolean question — or vice versa — answers the caller's own default, exactly
        // as if the flag were unknown.
        #expect(FortressFlag.isEnabled("checkout-cta") == false)
        #expect(FortressFlag.isEnabled("checkout-cta", default: true) == true)
        #expect(FortressFlag.stringValue("dark-mode", default: "fallback") == "fallback")
        #expect(FortressFlag.numberValue("checkout-cta", default: 7) == 7)

        // Unknown flags answer the default through the same cascade.
        #expect(FortressFlag.stringValue("never-heard-of-it", default: "control") == "control")
        #expect(FortressFlag.numberValue("never-heard-of-it", default: 2.5) == 2.5)
    }

    @Test("union values survive the durable cache")
    func unionValuesSurviveTheCache() {
        startSDK(cache: InMemoryEnvelopeCache(seeded: envelope(["checkout-cta": "buy-now"])))
        defer { FortressFlag.stop() }
        #expect(FortressFlag.stringValue("checkout-cta", default: "control") == "buy-now")
        #expect(FortressFlag.resolve("checkout-cta").source == .cached)
    }

    /// THE UPGRADE PIN (the plan's named trap): the durable cache holds a v1 envelope across an
    /// SDK upgrade, and it must still load — or every updating customer app boots into the
    /// `false` fallback for a session. The fixture is a LITERAL v1 payload: `v: 1` and a
    /// `[String: Bool]` flags object, byte-shaped exactly as a v1 server wrote it.
    @Test("a v1 cache file still loads after the upgrade to contract v2")
    func v1CacheLoadsAfterUpgrade() {
        let v1 = EnvelopeFixture(
            version: 1,
            environment: "dev",
            device: TestSupport.deviceID,
            issuedAt: now.addingTimeInterval(-86_400), // stale — freshness never gates the cache
            expiresAt: now.addingTimeInterval(-82_800),
            flags: ["dark-mode": true, "beta-banner": false]
        ).signed(with: signing)

        startSDK(cache: InMemoryEnvelopeCache(seeded: v1))
        defer { FortressFlag.stop() }

        #expect(FortressFlag.isEnabled("dark-mode"))
        #expect(FortressFlag.isEnabled("beta-banner") == false)
        #expect(FortressFlag.resolve("dark-mode").source == .cached)
    }
}
