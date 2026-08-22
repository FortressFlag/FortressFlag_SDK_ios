import Foundation
import Testing
@testable import FortressFlag

@Suite("Configuration validation")
struct ConfigurationTests {
    let keys = TrustedKeys(["k": Data(repeating: 1, count: 32)])

    func configuration(
        sdkKey: String = "ffc_prod_abcdefghijklmnopqrstuv",
        environment: Environment = .production,
        baseURL: URL? = nil,
        allowsInsecureLocalTransport: Bool = false,
        refreshInterval: Duration = .seconds(300)
    ) -> Configuration {
        Configuration(
            sdkKey: sdkKey,
            environment: environment,
            baseURL: baseURL ?? Configuration.defaultBaseURL,
            signaturePolicy: .required(trustedKeys: keys),
            refreshInterval: refreshInterval,
            allowsInsecureLocalTransport: allowsInsecureLocalTransport,
            logging: .silent
        )
    }

    @Test("a sound configuration reports nothing")
    func valid() {
        #expect(configuration().validate().isEmpty)
    }

    @Test("an empty key is caught")
    func emptyKey() {
        #expect(configuration(sdkKey: "").validate() == [.emptySDKKey])
    }

    @Test(
        "a malformed key is caught",
        arguments: ["nope", "ffc_prod", "ffc_prod_", "sk_live_abcdef", "ffc__abc"]
    )
    func malformedKey(key: String) {
        #expect(configuration(sdkKey: key).validate().contains(.sdkKeyWrongFormat))
    }

    @Test("a key for the wrong environment is caught before the server rejects it")
    func environmentMismatch() {
        // Shipping a staging key in a production build is a mistake that otherwise surfaces as
        // "all our flags are off in production" — this turns it into a log line naming the problem.
        let problems = configuration(sdkKey: "ffc_dev_abcdefghij", environment: .production).validate()
        #expect(problems.contains(.sdkKeyEnvironmentMismatch(keyEnvironment: "dev", configured: "prod")))
    }

    @Test("plaintext HTTP is refused")
    func plaintextRefused() throws {
        let url = try #require(URL(string: "http://flags.example.com"))
        #expect(configuration(baseURL: url).validate().contains(.insecureBaseURL))
    }

    @Test("plaintext loopback is allowed only when explicitly opted into")
    func loopbackOptIn() throws {
        let url = try #require(URL(string: "http://localhost:8080"))
        #expect(configuration(baseURL: url).validate().contains(.insecureBaseURL))
        #expect(configuration(baseURL: url, allowsInsecureLocalTransport: true).validate().isEmpty)
    }

    @Test("the local-transport escape hatch does not extend to real hosts")
    func loopbackOnlyMeansLoopback() throws {
        // Otherwise "just for local dev" becomes a way to ship an SDK key over plaintext to
        // anywhere at all.
        let url = try #require(URL(string: "http://internal.corp.example.com"))
        let problems = configuration(baseURL: url, allowsInsecureLocalTransport: true).validate()
        #expect(problems.contains(.insecureTransportOnNonLoopbackHost(host: "internal.corp.example.com")))
    }

    @Test("requiring signatures with no keys is reported, not silently fatal")
    func emptyTrustStoreReported() {
        var config = configuration()
        config.signaturePolicy = .required(trustedKeys: TrustedKeys([:]))
        #expect(config.validate().contains(.signatureRequiredButNoTrustedKeys))
    }

    @Test("an aggressive poll interval is reported")
    func tooFrequent() {
        let problems = configuration(refreshInterval: .seconds(1)).validate()
        #expect(problems.contains(.refreshIntervalTooShort(minimum: Configuration.minimumRefreshInterval)))
    }

    @Test("the default base URL is https")
    func defaultIsHTTPS() {
        #expect(Configuration.defaultBaseURL.scheme == "https")
    }

    @Test("environment wire values match the backend's seeded defaults")
    func wireValues() {
        // These strings are the contract with the environments the backend seeds for every
        // tenant (db/seed/dev.sql; the closed `environments_key_supported` CHECK they once
        // matched was opened by migration 0007). Changing one silently reads the wrong
        // environment.
        #expect(Environment.development.rawValue == "dev")
        #expect(Environment.staging.rawValue == "staging")
        #expect(Environment.production.rawValue == "prod")
    }

    @Test("a customer-defined environment key constructs")
    func customEnvironmentKeys() throws {
        // Custom environments (backend 0007): the tenant creates `qa` in the dashboard and the
        // app build reading it names it by key.
        let qa = try #require(Environment(key: "qa"))
        #expect(qa.rawValue == "qa")
        #expect(Environment(key: "eu-prod-2")?.rawValue == "eu-prod-2")

        // And it composes with the key-mismatch validation like any preset.
        let mismatched = configuration(sdkKey: "ffc_dev_abcdefghij", environment: qa).validate()
        #expect(
            mismatched.contains(
                .sdkKeyEnvironmentMismatch(keyEnvironment: "dev", configured: "qa")))
        #expect(configuration(sdkKey: "ffc_qa_abcdefghij", environment: qa).validate().isEmpty)
    }

    @Test("a malformed environment key is nil, never carried")
    func malformedEnvironmentKeys() {
        // The same shape the server's `environments_key_format` CHECK enforces. A malformed key
        // could never name an environment on any tenant; carrying it would turn a typo into
        // "flags silently never load".
        for bad in [
            "", "a", "Prod", "with_underscore", "-leading", "trailing-", "spaced key",
            "a-key-well-beyond-the-thirty-two-character-bound", "émulateur",
        ] {
            #expect(Environment(key: bad) == nil, "accepted \(bad)")
        }
    }

    @Test("the presets and init?(key:) agree")
    func presetsRoundTrip() {
        for preset in [Environment.development, .staging, .production] {
            #expect(Environment(key: preset.rawValue) == preset)
            #expect(Environment(rawValue: preset.rawValue) == preset)
        }
    }
}

@Suite("Base64URL")
struct Base64URLTests {
    @Test("round-trips arbitrary bytes")
    func roundTrip() {
        for length in 0...64 {
            let data = Data((0..<length).map { UInt8($0 % 251) })
            let encoded = Base64URL.encode(data)
            #expect(!encoded.contains("="))
            #expect(!encoded.contains("+"))
            #expect(!encoded.contains("/"))
            #expect(Base64URL.decode(encoded) == data)
        }
    }

    @Test(
        "malformed input never traps",
        arguments: ["a", "!!!!", "abcde!", "====", "a=b=c", "\u{0}\u{1}"]
    )
    func malformed(input: String) {
        // The assertion is the absence of a crash: this decodes bytes that arrived from a party we
        // do not trust, and a trap here is a crash in the customer's app. Reaching the next line
        // is the pass condition.
        _ = Base64URL.decode(input)
    }

    @Test("a length that cannot be valid base64 is rejected")
    func impossibleLength() {
        #expect(Base64URL.decode("a") == nil)
    }
}
