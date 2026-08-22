import Foundation
import Testing
@testable import FortressFlag
import FortressFlagTestKit

@Suite("Device identity format")
struct DeviceIdentityFormatTests {
    @Test(
        "a well-formed identity is 128 bits of base64url behind a dev_ or sim_ prefix",
        arguments: [
            "dev_AAAAAAAAAAAAAAAAAAAAAA",
            // Simulator builds mint sim_ (device metering, M5): served flags normally, never
            // billed. BOTH prefixes are asserted unconditionally — a device that stored a dev_
            // id and then runs in a simulator must keep it, so acceptance cannot depend on
            // which prefix this build mints.
            "sim_AAAAAAAAAAAAAAAAAAAAAA",
        ]
    )
    func wellFormed(value: String) {
        // This format is a cross-platform contract, not an implementation detail: Android has to
        // mint the same shape so that "one device" means the same thing on both platforms
        // (Founding §6.1, and the open question in §12).
        #expect(KeychainDeviceIdentity.isWellFormed(value))
    }

    @Test(
        "anything else is treated as absent rather than trusted",
        arguments: [
            "",
            "AAAAAAAAAAAAAAAAAAAAAA",              // no prefix
            "dev_",                                 // no body
            "dev_short",                            // too few bytes
            "dev_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",   // too many bytes
            "dev_!!!!!!!!!!!!!!!!!!!!!!",           // not base64url
            "device_AAAAAAAAAAAAAAAAAAAAAA",        // wrong prefix
            "sim_",                                 // sim_ enforces the same body shape
            "sim_short",                            // too few bytes
            "xxx_AAAAAAAAAAAAAAAAAAAAAA",           // an unknown prefix is not an identity
        ]
    )
    func rejected(value: String) {
        // A corrupt or foreign value must not be adopted: sending a malformed identifier upstream
        // fails every request, and adopting one puts junk in the billing path.
        #expect(!KeychainDeviceIdentity.isWellFormed(value))
    }
}

/// Whether this test host can actually reach the data-protection keychain.
///
/// A bare `swift test` process has no application identifier, so `SecItemAdd` returns
/// `errSecMissingEntitlement` (-34018) on macOS. These tests are gated on the real capability
/// rather than faked with a stub: a keychain stub would test our idea of the keychain, and the
/// behaviour that matters here — duplicate handling, accessibility classes, access groups — is
/// exactly the part a stub would get to define for itself.
func dataProtectionKeychainIsAvailable() -> Bool {
    let probe = KeychainStore.add(Data("probe".utf8), account: "availability-probe", accessGroup: nil)
    defer { KeychainStore.delete(account: "availability-probe", accessGroup: nil) }
    switch probe {
    case .added, .duplicate: return true
    case .failed: return false
    }
}

/// Keychain-backed identity. Skipped where the keychain is unavailable; CI runs the same suite in
/// a simulator host, where it is.
@Suite(
    "Device identity, keychain-backed",
    .serialized,
    .enabled(if: dataProtectionKeychainIsAvailable(), "data-protection keychain unavailable in this host")
)
struct KeychainDeviceIdentityTests {
    @Test("an identity is minted once and then stable across instances")
    func stableAcrossInstances() throws {
        defer { KeychainDeviceIdentity(configuredAccessGroup: nil, log: .silent).reset() }

        let first = KeychainDeviceIdentity(configuredAccessGroup: nil, log: .silent)
        let second = KeychainDeviceIdentity(configuredAccessGroup: nil, log: .silent)

        let a = try first.identity().get()
        let b = try second.identity().get()

        #expect(a == b)
        #expect(KeychainDeviceIdentity.isWellFormed(a))
    }

    @Test("this build mints the prefix its target environment dictates")
    func mintedPrefixMatchesBuild() throws {
        defer { KeychainDeviceIdentity(configuredAccessGroup: nil, log: .silent).reset() }

        // CONDITIONAL ON PURPOSE (device metering, M5): CI's device-tests job runs this suite in
        // a simulator, where the build mints sim_; `swift test` on a Mac host would mint dev_.
        // An unconditional assertion on a minted value passes in one environment and fails in
        // the other — the format suite above owns the unconditional claims.
        #if targetEnvironment(simulator)
        let expected = "sim_"
        #else
        let expected = "dev_"
        #endif

        let identity = KeychainDeviceIdentity(configuredAccessGroup: nil, log: .silent)
        identity.reset() // a fresh mint, not whatever an earlier test left stored
        #expect(try identity.identity().get().hasPrefix(expected))
    }

    @Test("losing the mint race adopts the winner's value instead of overwriting it")
    func duplicateAdoptsExisting() throws {
        defer { KeychainDeviceIdentity(configuredAccessGroup: nil, log: .silent).reset() }

        // Simulates another of the customer's apps having written first. Overwriting here would
        // leave two apps on different identities and bill one device as two, permanently.
        let winner = "dev_ZZZZZZZZZZZZZZZZZZZZZZ"
        _ = KeychainStore.add(Data(winner.utf8), account: "v1", accessGroup: nil)

        let identity = KeychainDeviceIdentity(configuredAccessGroup: nil, log: .silent)
        #expect(try identity.identity().get() == winner)
    }

    @Test("reset produces a genuinely different identity")
    func resetMintsAnew() throws {

        let identity = KeychainDeviceIdentity(configuredAccessGroup: nil, log: .silent)
        let before = try identity.identity().get()
        identity.reset()
        let after = try identity.identity().get()
        defer { identity.reset() }

        #expect(before != after)
    }

    @Test("a corrupt stored value is replaced rather than sent upstream")
    func corruptValueReplaced() throws {
        KeychainStore.delete(account: "v1", accessGroup: nil)
        _ = KeychainStore.add(Data("not a device id".utf8), account: "v1", accessGroup: nil)

        let identity = KeychainDeviceIdentity(configuredAccessGroup: nil, log: .silent)
        defer { identity.reset() }

        // The corrupt row is still there, so the add loses the race, re-reads, and finds the same
        // rubbish. The identity provider must report failure rather than adopt it.
        let result = identity.identity()
        if case let .success(value) = result {
            #expect(KeychainDeviceIdentity.isWellFormed(value))
        }
    }
}

@Suite("Durable cache", .serialized)
struct FileEnvelopeCacheTests {
    let signing = EnvelopeFixture.SigningIdentity()

    func makeCache(key: String = "ffc_dev_cachetest") -> FileEnvelopeCache {
        FileEnvelopeCache(sdkKey: key, environment: .development, log: .silent)
    }

    @Test("stored bytes come back byte-identical")
    func roundTrip() {
        // Byte-identical matters more than it looks: the cache holds what was *signed*, so a
        // re-serialisation would strip any field a future server adds and break the signature on
        // reload.
        let cache = makeCache()
        defer { cache.clear() }

        let raw = EnvelopeFixture(device: TestSupport.deviceID, flags: ["alpha": true])
            .signed(with: signing)
        cache.store(raw, etag: "\"v3\"")

        let loaded = cache.load()
        #expect(loaded?.raw == raw)
        #expect(loaded?.etag == "\"v3\"")
    }

    @Test("an empty cache loads as nil, not as an error")
    func emptyCache() {
        let cache = makeCache(key: "ffc_dev_neverwritten")
        cache.clear()
        #expect(cache.load() == nil)
    }

    @Test("clearing removes both the envelope and the ETag")
    func clearing() {
        let cache = makeCache()
        cache.store(Data("{}".utf8), etag: "\"v1\"")
        cache.clear()
        #expect(cache.load() == nil)
    }

    @Test("two environments never see each other's values")
    func scopedByEnvironment() {
        // A staging build and a production build sharing a container must not serve each other's
        // flags — on this product that is the difference between a feature being on for staff and
        // on for everyone.
        let dev = FileEnvelopeCache(sdkKey: "ffc_dev_same", environment: .development, log: .silent)
        let prod = FileEnvelopeCache(sdkKey: "ffc_dev_same", environment: .production, log: .silent)
        defer { dev.clear(); prod.clear() }

        dev.store(Data("dev-bytes".utf8), etag: nil)
        prod.store(Data("prod-bytes".utf8), etag: nil)

        #expect(dev.load()?.raw == Data("dev-bytes".utf8))
        #expect(prod.load()?.raw == Data("prod-bytes".utf8))
    }

    @Test("two SDK keys never see each other's values")
    func scopedByKey() {
        let a = FileEnvelopeCache(sdkKey: "ffc_dev_aaa", environment: .development, log: .silent)
        let b = FileEnvelopeCache(sdkKey: "ffc_dev_bbb", environment: .development, log: .silent)
        defer { a.clear(); b.clear() }

        a.store(Data("a-bytes".utf8), etag: nil)
        b.store(Data("b-bytes".utf8), etag: nil)

        #expect(a.load()?.raw == Data("a-bytes".utf8))
        #expect(b.load()?.raw == Data("b-bytes".utf8))
    }

    @Test("an oversized payload is refused rather than written to the user's disk")
    func oversizedRefused() {
        let cache = makeCache(key: "ffc_dev_oversize")
        defer { cache.clear() }

        cache.store(Data(repeating: 0x41, count: FileEnvelopeCache.maximumEnvelopeBytes + 1), etag: nil)
        #expect(cache.load() == nil)
    }

    @Test("corrupt cached bytes are survivable")
    func corruptBytes() {
        let cache = makeCache(key: "ffc_dev_corrupt")
        defer { cache.clear() }

        cache.store(Data("this is not an envelope".utf8), etag: nil)

        // The cache layer returns whatever it holds; rejecting it is the verifier's job, and it does
        // so without throwing. This asserts the read path does not fail on unexpected content.
        #expect(cache.load()?.raw == Data("this is not an envelope".utf8))
    }

    @Test("writing without an ETag removes a stale one")
    func etagCleared() {
        let cache = makeCache(key: "ffc_dev_etag")
        defer { cache.clear() }

        cache.store(Data("{}".utf8), etag: "\"old\"")
        cache.store(Data("{}".utf8), etag: nil)

        // A stale ETag would make the server answer 304 for a payload we no longer hold.
        #expect(cache.load()?.etag == nil)
    }
}
