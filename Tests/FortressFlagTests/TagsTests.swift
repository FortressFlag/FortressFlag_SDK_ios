import Foundation
import Testing
@testable import FortressFlag
import FortressFlagTestKit

/// Decodes an `X-FF-Tags` header value back into the tag object it carries.
private func decodeTags(_ header: String?) -> [String: String]? {
    guard let header, let data = Base64URL.decode(header) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
}

@Suite("Tag encoding")
struct TagsTests {
    @Test("keys follow the contract alphabet")
    func keyValidation() {
        for valid in ["appVersion", "a", "a.b-c_d", "COHORT", "k9", String(repeating: "k", count: 64)] {
            #expect(Tags.isValidKey(valid), "\(valid) should be valid")
        }
        let tooLong = String(repeating: "k", count: 65)
        for invalid in ["", " ", "app version", "app/version", "café", "a\n", tooLong] {
            #expect(!Tags.isValidKey(invalid), "\(invalid) should be invalid")
        }
    }

    @Test("sanitize drops what the contract cannot carry, and only that")
    func sanitizeDrops() {
        let kept = Tags.sanitize(
            [
                "cohort": "beta",
                "empty": "",
                "bad key": "x",
                "appVersion": "9.9",  // collides with a built-in: the device's truth wins
                "long": String(repeating: "v", count: 257),
                "atCap": String(repeating: "v", count: 256),
            ],
            reserved: BuiltinTags.reservedKeys,
            log: .silent
        )
        #expect(kept == [
            "cohort": "beta",
            "empty": "",
            "atCap": String(repeating: "v", count: 256),
        ])
    }

    @Test("encoding is deterministic regardless of construction order")
    func encodingIsDeterministic() {
        // Two dictionaries with the same contents built in different orders. Dictionary
        // iteration order is arbitrary, so equality of the ENCODED form is the property M3's
        // ETag needs and the one this test pins.
        var forward: [String: String] = [:]
        var backward: [String: String] = [:]
        let pairs = (0..<20).map { ("key\($0)", "value\($0)") }
        for (key, value) in pairs { forward[key] = value }
        for (key, value) in pairs.reversed() { backward[key] = value }

        let first = Tags.encode(builtin: ["platform": "ios"], custom: forward, log: .silent)
        let second = Tags.encode(builtin: ["platform": "ios"], custom: backward, log: .silent)
        #expect(first != nil)
        #expect(first == second)
    }

    @Test("built-ins ride along and nothing is empty-encoded")
    func encodingMergesBuiltins() {
        let header = Tags.encode(
            builtin: ["platform": "ios", "appVersion": "1.0"],
            custom: ["cohort": "beta"],
            log: .silent
        )
        #expect(decodeTags(header) == ["platform": "ios", "appVersion": "1.0", "cohort": "beta"])

        #expect(Tags.encode(builtin: [:], custom: [:], log: .silent) == nil)
    }

    @Test("over the count cap, custom tags shed and built-ins survive")
    func countCapShedsCustomTags() {
        var custom: [String: String] = [:]
        for index in 0..<40 {
            custom[String(format: "key%02d", index)] = "v"
        }
        let header = Tags.encode(builtin: ["platform": "ios"], custom: custom, log: .silent)
        let decoded = decodeTags(header)
        #expect(decoded?.count == Tags.Limits.maxCount)
        #expect(decoded?["platform"] == "ios")
        // Shedding is from the END of the sorted order, so the survivors are the first 31 keys.
        #expect(decoded?["key30"] == "v")
        #expect(decoded?["key31"] == nil)
    }

    @Test("over the document cap, custom tags shed until it fits")
    func documentCapShedsCustomTags() {
        var custom: [String: String] = [:]
        for index in 0..<30 {
            custom[String(format: "key%02d", index)] = String(repeating: "v", count: 250)
        }
        let header = Tags.encode(builtin: ["platform": "ios"], custom: custom, log: .silent)
        let decoded = decodeTags(header)
        #expect(decoded != nil)
        #expect(decoded?["platform"] == "ios")
        if let header {
            #expect(Base64URL.decode(header)?.count ?? .max <= Tags.Limits.maxDocumentBytes)
        }
        // Some custom tags survived — the cap trims, it does not clear.
        #expect((decoded?.count ?? 0) > 1)
    }

    @Test("built-in tags derive from the bundle and omit what is missing")
    func builtinDerivation() {
        let full = BuiltinTags.collect(
            bundleInfo: ["CFBundleShortVersionString": "2.1", "CFBundleVersion": "421"],
            osVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 1)
        )
        #expect(full["appVersion"] == "2.1")
        #expect(full["appBuild"] == "421")
        #expect(full["osVersion"] == "26.0.1")
        #expect(full["platform"] == "ios")
        #expect(full["sdkVersion"] == SDKInfo.version)

        // No Info.plist values: the version tags are OMITTED, never empty — an absent tag makes
        // rules on it skip, which is the contract's semantics for "unknown".
        let bare = BuiltinTags.collect(
            bundleInfo: nil,
            osVersion: OperatingSystemVersion(majorVersion: 18, minorVersion: 4, patchVersion: 0)
        )
        #expect(bare["appVersion"] == nil)
        #expect(bare["appBuild"] == nil)
        #expect(bare["osVersion"] == "18.4")
        #expect(Set(bare.keys).isSubset(of: BuiltinTags.reservedKeys))
    }
}

@Suite("Tag transport")
struct TagTransportTests {
    let identity = EnvelopeFixture.SigningIdentity()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var trustedKeys: TrustedKeys { TrustedKeys([identity.keyID: identity.publicKeyBytes]) }

    func envelope(flags: [String: FlagValue]) -> Data {
        EnvelopeFixture(
            environment: "dev",
            device: TestSupport.deviceID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(1800),
            flags: flags
        ).signed(with: identity)
    }

    func makeClient(
        api: any ClientAPI,
        configTags: [String: String] = [:],
        builtin: [String: String] = [:]
    ) -> (FlagClient, SnapshotStore) {
        var configuration = TestSupport.configuration(trustedKeys: trustedKeys)
        configuration.tags = configTags
        let store = SnapshotStore()
        let client = FlagClient(
            configuration: configuration,
            identityProvider: StubIdentity(TestSupport.deviceID),
            api: api,
            cache: InMemoryEnvelopeCache(),
            store: store,
            log: .silent,
            builtinTags: builtin,
            now: TestSupport.fixedClock(now),
            random: TestSupport.noJitter,
            notify: { _ in }
        )
        return (client, store)
    }

    @Test("every fetch carries the merged configuration and built-in tags")
    func fetchCarriesTags() async {
        let api = StubClientAPI(always: .failure(.offline))
        let (client, _) = makeClient(
            api: api,
            configTags: ["cohort": "beta"],
            builtin: ["platform": "ios", "appVersion": "1.0"]
        )

        _ = await client.refresh()

        #expect(decodeTags(api.requests.last?.tags) == [
            "cohort": "beta", "platform": "ios", "appVersion": "1.0",
        ])
    }

    @Test("no tags at all sends no header")
    func noTagsSendsNoHeader() async {
        let api = StubClientAPI(always: .failure(.offline))
        let (client, _) = makeClient(api: api)

        _ = await client.refresh()

        #expect(api.requests.last?.tags == String??.some(nil))
    }

    @Test("setTags replaces the custom set and the next fetch carries it")
    func setTagsReplacesAndSends() async {
        let api = StubClientAPI(always: .failure(.offline))
        let (client, store) = makeClient(
            api: api,
            configTags: ["cohort": "beta", "plan": "free"],
            builtin: ["platform": "ios"]
        )

        await client.setTags(["cohort": "internal"])
        _ = await client.refresh()

        // Whole-set replacement: "plan" is gone, not merged.
        #expect(decodeTags(api.requests.last?.tags) == [
            "cohort": "internal", "platform": "ios",
        ])
        #expect(store.current.sentTagKeys == ["cohort", "platform"])
    }

    @Test("a tag change invalidates the stored ETag")
    func tagChangeClearsETag() async {
        // The validator names a payload evaluated for the OLD tags; keeping it would let a
        // future 304 confirm values the new tags might not produce. The server sends no ETag
        // yet (M3) — this is the behaviour that must already be right when it does.
        let api = StubClientAPI(
            [.success(raw: envelope(flags: ["alpha": true]), etag: "\"v1\"")],
            fallback: .failure(.offline)
        )
        let (client, _) = makeClient(api: api, builtin: ["platform": "ios"])

        _ = await client.refresh()
        await client.setTags(["cohort": "beta"])
        _ = await client.refresh()

        #expect(api.requests.count == 2)
        #expect(api.requests.first?.etag == String??.some(nil))
        // Without the invalidation this would be "v1".
        #expect(api.requests.last?.etag == String??.some(nil))
    }

    @Test("setTags with an unchanged effective set keeps the ETag")
    func unchangedTagsKeepETag() async {
        let api = StubClientAPI(
            [.success(raw: envelope(flags: ["alpha": true]), etag: "\"v1\"")],
            fallback: .failure(.offline)
        )
        let (client, _) = makeClient(
            api: api, configTags: ["cohort": "beta"], builtin: ["platform": "ios"]
        )

        _ = await client.refresh()
        await client.setTags(["cohort": "beta"])
        _ = await client.refresh()

        #expect(api.requests.last?.etag == "\"v1\"")
    }

    @Test("the diagnostics keys are published from start")
    func tagKeysArePublishedOnStart() async {
        let api = StubClientAPI(always: .failure(.offline))
        let (client, store) = makeClient(
            api: api,
            configTags: ["cohort": "beta"],
            builtin: ["platform": "ios", "sdkVersion": "1.0.0"]
        )

        await client.start(restoredETag: nil)
        await client.stop()

        #expect(store.current.sentTagKeys == ["cohort", "platform", "sdkVersion"])
    }
}
