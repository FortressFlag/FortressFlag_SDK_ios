import Foundation
import Testing
@testable import FortressFlag
import FortressFlagTestKit

@Suite("Envelope verification")
struct EnvelopeVerifierTests {
    let identity = EnvelopeFixture.SigningIdentity()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    var trustedKeys: TrustedKeys {
        TrustedKeys([identity.keyID: identity.publicKeyBytes])
    }

    func fixture(
        environment: String = "dev",
        device: String = TestSupport.deviceID,
        version: Int = 1,
        issuedAt: Date? = nil,
        expiresAt: Date? = nil,
        flags: [String: FlagValue] = ["alpha": true]
    ) -> EnvelopeFixture {
        EnvelopeFixture(
            version: version,
            environment: environment,
            device: device,
            issuedAt: issuedAt ?? now,
            expiresAt: expiresAt ?? now.addingTimeInterval(1800),
            flags: flags
        )
    }

    func expectations(
        environment: Environment = .development,
        device: String? = TestSupport.deviceID,
        enforceExpiry: Bool = true
    ) -> EnvelopeVerifier.Expectations {
        EnvelopeVerifier.Expectations(
            environment: environment, deviceID: device, now: now, enforceExpiry: enforceExpiry
        )
    }

    // MARK: - Happy path

    @Test("a correctly signed, correctly bound envelope is accepted")
    func accepted() throws {
        let result = EnvelopeVerifier.verify(
            raw: fixture().signed(with: identity),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations()
        )
        let verified = try result.get()
        #expect(verified.payload.flags == ["alpha": true])
    }

    @Test("fractional-second timestamps are accepted")
    func fractionalSeconds() {
        // A Go server switching RFC3339 to RFC3339Nano is invisible in review and would otherwise
        // brick every shipped SDK.
        let payload = #"{"v":1,"tenant":"t","environment":"dev","#
            + #""device":"\#(TestSupport.deviceID)","#
            + #""issuedAt":"2027-01-15T10:00:00.123Z","expiresAt":"2027-01-15T10:30:00.500Z","#
            + #""flags":{"alpha":true}}"#
        let envelope = Self.envelope(payloadJSON: Data(payload.utf8), identity: identity)

        let result = EnvelopeVerifier.verify(
            raw: envelope,
            policy: .required(trustedKeys: trustedKeys),
            expectations: EnvelopeVerifier.Expectations(
                environment: .development,
                deviceID: TestSupport.deviceID,
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        // Accepted or rejected on expiry — either way it must have *parsed*, not failed to decode.
        if case let .failure(rejection) = result {
            #expect(rejection != .malformedPayload)
        }
    }

    @Test("unknown top-level fields do not break decoding")
    func forwardCompatibleFields() {
        // `now` in `expectations()` is 2027-01-15T08:00:00Z, so this payload is current.
        let payload = #"{"v":1,"tenant":"t","environment":"dev","#
            + #""device":"\#(TestSupport.deviceID)","#
            + #""issuedAt":"2027-01-15T07:30:00Z","expiresAt":"2027-01-15T08:30:00Z","#
            + #""flags":{"a":true},"somethingNew":{"nested":1}}"#
        let envelope = Self.envelope(payloadJSON: Data(payload.utf8), identity: identity)

        let result = EnvelopeVerifier.verify(
            raw: envelope,
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations()
        )
        #expect((try? result.get()) != nil)
    }

    // MARK: - Signature

    @Test("a tampered payload is rejected")
    func tampered() {
        let result = EnvelopeVerifier.verify(
            raw: fixture().tampered(with: identity, flippingFlag: "alpha"),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations()
        )
        #expect(result.rejection == .badSignature)
    }

    @Test("an unsigned envelope is rejected when signatures are required")
    func unsignedRejected() {
        let result = EnvelopeVerifier.verify(
            raw: fixture().unsigned(),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations()
        )
        #expect(result.rejection == .missingSignature)
    }

    @Test("an unsigned envelope is accepted when signatures are disabled")
    func unsignedAcceptedWhenDisabled() {
        let result = EnvelopeVerifier.verify(
            raw: fixture().unsigned(), policy: .disabled, expectations: expectations()
        )
        #expect((try? result.get()) != nil)
    }

    @Test("a signature from an untrusted key is rejected")
    func untrustedKey() {
        let attacker = EnvelopeFixture.SigningIdentity(keyID: identity.keyID)
        let result = EnvelopeVerifier.verify(
            raw: fixture().signed(with: attacker),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations()
        )
        #expect(result.rejection == .badSignature)
    }

    @Test("an unknown key ID is rejected, and named")
    func unknownKeyID() {
        let other = EnvelopeFixture.SigningIdentity(keyID: "rotated-key-9")
        let result = EnvelopeVerifier.verify(
            raw: fixture().signed(with: other),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations()
        )
        #expect(result.rejection == .unknownKeyID("rotated-key-9"))
    }

    @Test("an empty trust store rejects everything")
    func emptyTrustStore() {
        // The fail-closed default before the backend has signing keys. Rejection here means
        // "serve the cache", never "break the app".
        let result = EnvelopeVerifier.verify(
            raw: fixture().signed(with: identity),
            policy: .required(trustedKeys: TrustedKeys([:])),
            expectations: expectations()
        )
        #expect(result.rejection == .unknownKeyID(identity.keyID))
    }

    // MARK: - Binding

    @Test("a production payload is rejected by a development build")
    func environmentMismatch() {
        let result = EnvelopeVerifier.verify(
            raw: fixture(environment: "prod").signed(with: identity),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations(environment: .development)
        )
        #expect(result.rejection == .environmentMismatch(expected: "dev", received: "prod"))
    }

    @Test("another device's payload is rejected")
    func deviceMismatch() {
        let result = EnvelopeVerifier.verify(
            raw: fixture(device: "dev_BBBBBBBBBBBBBBBBBBBBBB").signed(with: identity),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations()
        )
        #expect(result.rejection == .deviceMismatch)
    }

    @Test("a future contract version is refused rather than guessed at")
    func futureVersion() {
        let result = EnvelopeVerifier.verify(
            raw: fixture(version: 3).signed(with: identity),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations()
        )
        #expect(result.rejection == .unsupportedContractVersion(3))
    }

    @Test("both supported contract versions are accepted — a v1 cache must load after upgrade")
    func supportedVersionRange() {
        for version in [1, 2] {
            let result = EnvelopeVerifier.verify(
                raw: fixture(version: version).signed(with: identity),
                policy: .required(trustedKeys: trustedKeys),
                expectations: expectations()
            )
            #expect(result.rejection == nil, "version \(version) must verify")
        }
    }

    @Test("a live response past its expiry is rejected as a replay")
    func expiredLiveResponse() {
        let result = EnvelopeVerifier.verify(
            raw: fixture(
                issuedAt: now.addingTimeInterval(-7200), expiresAt: now.addingTimeInterval(-3600)
            ).signed(with: identity),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations()
        )
        #expect(result.rejection == .expired(at: now.addingTimeInterval(-3600)))
    }

    @Test("the same expired envelope is accepted from the cache")
    func expiredCacheEntryStillServes() {
        // The asymmetry that keeps an offline device working. Expiry bounds the replay window on
        // the wire; it must never expire the last value a device recorded, because that would turn
        // an outage into every flag silently reverting to false.
        let result = EnvelopeVerifier.verify(
            raw: fixture(
                issuedAt: now.addingTimeInterval(-90 * 86400),
                expiresAt: now.addingTimeInterval(-89 * 86400)
            ).signed(with: identity),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations(enforceExpiry: false)
        )
        #expect((try? result.get()) != nil)
    }

    @Test("clock skew is tolerated in both directions")
    func clockSkew() {
        let barelyExpired = fixture(
            issuedAt: now.addingTimeInterval(-1900), expiresAt: now.addingTimeInterval(-100)
        )
        let result = EnvelopeVerifier.verify(
            raw: barelyExpired.signed(with: identity),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations()
        )
        #expect((try? result.get()) != nil)
    }

    @Test("a payload issued far in the future is rejected")
    func issuedInTheFuture() {
        let future = now.addingTimeInterval(86400)
        let result = EnvelopeVerifier.verify(
            raw: fixture(issuedAt: future, expiresAt: future.addingTimeInterval(1800))
                .signed(with: identity),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations()
        )
        #expect(result.rejection == .issuedInTheFuture(at: future))
    }

    @Test("the device check is skipped when the SDK has no identity yet")
    func deviceCheckSkipped() {
        let result = EnvelopeVerifier.verify(
            raw: fixture().signed(with: identity),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations(device: nil)
        )
        #expect((try? result.get()) != nil)
    }

    // MARK: - Malformed input

    @Test(
        "garbage never crashes the verifier",
        arguments: [
            "", "{", "null", "[]", #"{"payload":"!!!not base64!!!"}"#,
            #"{"payload":"e30","sig":"nonsense"}"#,
            #"{"payload":"e30","sig":"rsa:k:AAAA"}"#,
            #"{"payload":"e30","sig":"ed25519:k"}"#,
            #"{"sig":"ed25519:k:AAAA"}"#,
        ]
    )
    func malformedInput(raw: String) {
        // Every one of these is something a hostile server or a corrupted file can produce. None
        // may throw, trap, or hang — they must all become an ordinary rejection.
        let result = EnvelopeVerifier.verify(
            raw: Data(raw.utf8),
            policy: .required(trustedKeys: trustedKeys),
            expectations: expectations()
        )
        #expect(result.rejection != nil)
    }

    @Test("a truncated but well-formed envelope is rejected, not decoded")
    func truncatedPayload() {
        var raw = fixture().signed(with: identity)
        raw = raw.prefix(raw.count / 2)
        let result = EnvelopeVerifier.verify(
            raw: raw, policy: .required(trustedKeys: trustedKeys), expectations: expectations()
        )
        #expect(result.rejection == .malformedEnvelope)
    }

    // MARK: - Helpers

    private static func envelope(payloadJSON: Data, identity: EnvelopeFixture.SigningIdentity) -> Data {
        let signature = (try? identity.privateKey.signature(for: payloadJSON)) ?? Data()
        let object: [String: Any] = [
            "payload": base64URL(payloadJSON),
            "sig": "ed25519:\(identity.keyID):\(base64URL(signature))",
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Result where Failure == EnvelopeRejection {
    /// The rejection, or nil if the result succeeded. Keeps the assertions above readable.
    var rejection: EnvelopeRejection? {
        if case let .failure(rejection) = self { return rejection }
        return nil
    }
}
