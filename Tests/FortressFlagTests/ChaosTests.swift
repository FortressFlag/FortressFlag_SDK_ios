import Foundation
import Testing
@testable import FortressFlag
import FortressFlagTestKit

/// The suite that proves the one thing the SDK actually promises: **flagging can fail in any way
/// at all, and the host app neither crashes nor sees an error.**
///
/// Every other test checks that a specific thing works. These check that nothing breaks when
/// everything is wrong at once — which is the state a real device is in during an outage, on a
/// hotel Wi-Fi captive portal, or in the hands of someone actively attacking us.
@Suite("Chaos — nothing takes the host app down")
struct ChaosTests {
    let identity = EnvelopeFixture.SigningIdentity()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var trustedKeys: TrustedKeys { TrustedKeys([identity.keyID: identity.publicKeyBytes]) }

    /// Every way a response can be wrong, in one list.
    func hostileResponses() -> [FetchOutcome] {
        let attacker = EnvelopeFixture.SigningIdentity(keyID: identity.keyID)

        func fixture(_ mutate: (inout EnvelopeFixture) -> Void = { _ in }) -> EnvelopeFixture {
            var base = EnvelopeFixture(
                environment: "dev",
                device: TestSupport.deviceID,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(1800),
                flags: ["alpha": true]
            )
            mutate(&base)
            return base
        }

        return [
            // Transport-level failures
            .failure(.offline),
            .failure(.timedOut),
            .failure(.cancelled),
            .failure(.unauthorized),
            .failure(.rateLimited(retryAfter: nil)),
            .failure(.rateLimited(retryAfter: 31_536_000)),
            .failure(.serverError(status: 500)),
            .failure(.serverError(status: 503)),
            .failure(.unexpectedStatus(418)),
            .failure(.responseTooLarge),
            .failure(.other("something nobody anticipated")),

            // Bodies that are not envelopes at all
            .success(raw: Data(), etag: nil),
            .success(raw: Data("<html>captive portal</html>".utf8), etag: nil),
            .success(raw: Data("{".utf8), etag: nil),
            .success(raw: Data("null".utf8), etag: nil),
            .success(raw: Data(repeating: 0, count: 4096), etag: nil),

            // Envelopes that are structurally valid but must not be trusted
            .success(raw: fixture().unsigned(), etag: nil),
            .success(raw: fixture().tampered(with: identity, flippingFlag: "alpha"), etag: nil),
            .success(raw: fixture().signed(with: attacker), etag: nil),
            .success(raw: fixture { $0.environment = "prod" }.signed(with: identity), etag: nil),
            .success(
                raw: fixture { $0.device = "dev_BBBBBBBBBBBBBBBBBBBBBB" }.signed(with: identity),
                etag: nil),
            .success(raw: fixture { $0.version = 99 }.signed(with: identity), etag: nil),
            .success(
                raw: fixture {
                    $0.issuedAt = now.addingTimeInterval(-7200)
                    $0.expiresAt = now.addingTimeInterval(-3600)
                }.signed(with: identity),
                etag: nil
            ),
            .success(
                raw: fixture { $0.issuedAt = now.addingTimeInterval(86400) }.signed(with: identity),
                etag: nil),

            // Truncation, the classic mid-flight failure
            .success(raw: fixture().signed(with: identity).prefix(20), etag: nil),

            // A 304 with nothing cached behind it
            .notModified,
        ]
    }

    @Test("a device holding a good value never loses it, whatever the server does")
    func cachedValueSurvivesEverything() async {
        let good = EnvelopeFixture(
            environment: "dev", device: TestSupport.deviceID, issuedAt: now,
            expiresAt: now.addingTimeInterval(1800), flags: ["alpha": true, "beta": false]
        ).signed(with: identity)

        let cache = InMemoryEnvelopeCache(seeded: good)
        let store = SnapshotStore()
        let client = FlagClient(
            configuration: TestSupport.configuration(trustedKeys: trustedKeys),
            identityProvider: StubIdentity(TestSupport.deviceID),
            api: StubClientAPI(hostileResponses(), fallback: .failure(.offline)),
            cache: cache,
            store: store,
            log: .silent,
            now: TestSupport.fixedClock(now),
            random: TestSupport.noJitter,
            notify: { _ in }
        )

        _ = client.loadCacheIntoStore()

        for _ in 0..<hostileResponses().count {
            let outcome = await client.refresh()
            // Whatever happened, it was reported as an outcome and not raised.
            #expect(outcome != .notStarted)

            // And the device still answers correctly, from the value it recorded.
            let alpha = Resolver.resolve(
                key: "alpha", fresh: store.current.fresh, cached: store.current.cached,
                developerDefault: nil
            )
            #expect(alpha == Resolution(value: true, source: .cached))
        }

        // The cache is exactly what it was. Nothing hostile rewrote it.
        #expect(cache.contents == good)
    }

    @Test("a device with nothing cached answers false, never a crash")
    func coldDeviceAnswersFalse() async {
        let store = SnapshotStore()
        let client = FlagClient(
            configuration: TestSupport.configuration(trustedKeys: trustedKeys),
            identityProvider: StubIdentity(TestSupport.deviceID),
            api: StubClientAPI(hostileResponses(), fallback: .failure(.offline)),
            cache: InMemoryEnvelopeCache(),
            store: store,
            log: .silent,
            now: TestSupport.fixedClock(now),
            random: TestSupport.noJitter,
            notify: { _ in }
        )

        for _ in 0..<hostileResponses().count {
            _ = await client.refresh()
            let result = Resolver.resolve(
                key: "anything", fresh: store.current.fresh, cached: store.current.cached,
                developerDefault: nil
            )
            #expect(result == Resolution(value: false, source: .safeDefault))
        }
    }

    @Test("the keychain being unavailable degrades, it does not fail")
    func noKeychainStillResolves() async {
        let store = SnapshotStore()
        let client = FlagClient(
            configuration: TestSupport.configuration(trustedKeys: trustedKeys),
            identityProvider: StubIdentity(failing: .keychainUnavailable(-34018)),
            api: StubClientAPI(always: .failure(.offline)),
            cache: InMemoryEnvelopeCache(
                seeded: EnvelopeFixture(
                    environment: "dev", device: TestSupport.deviceID, issuedAt: now,
                    expiresAt: now.addingTimeInterval(1800), flags: ["alpha": true]
                ).signed(with: identity)
            ),
            store: store,
            log: .silent,
            now: TestSupport.fixedClock(now),
            random: TestSupport.noJitter,
            notify: { _ in }
        )

        // No identity, so the device check is skipped and the cache still serves — the whole point
        // of making the check optional.
        _ = client.loadCacheIntoStore()
        #expect(store.current.cached == ["alpha": true])
        #expect(await client.refresh() == .failed(.noDeviceIdentity))
        #expect(store.current.cached == ["alpha": true])
    }

    @Test("a change handler that throws a fit does not take the SDK with it")
    func hostileChangeHandler() async {
        // Customers write these handlers. One that recurses into the SDK, or blocks, must not
        // deadlock the app — the broadcast copies handlers out from under its lock before calling.
        let good = EnvelopeFixture(
            environment: "dev", device: TestSupport.deviceID, issuedAt: now,
            expiresAt: now.addingTimeInterval(1800), flags: ["alpha": true]
        ).signed(with: identity)

        let calls = Locked<Int>(0)
        let store = SnapshotStore()
        let client = FlagClient(
            configuration: TestSupport.configuration(trustedKeys: trustedKeys),
            identityProvider: StubIdentity(TestSupport.deviceID),
            api: StubClientAPI(always: .success(raw: good, etag: nil)),
            cache: InMemoryEnvelopeCache(),
            store: store,
            log: .silent,
            now: TestSupport.fixedClock(now),
            random: TestSupport.noJitter,
            notify: { _ in
                calls.mutate { $0 += 1 }
                // Re-entrant read from inside the handler.
                _ = store.current
            }
        )

        _ = await client.refresh()
        #expect(calls.value == 1)
    }
}
