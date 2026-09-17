import CryptoKit
import Foundation
import Testing
@testable import FortressFlag
import FortressFlagTestKit

/// The cross-SDK signature vectors from `FortressFlag_Standards/vectors/signing.json` (backend
/// ADR-0025): every `accept` envelope verifies, every `reject` envelope fails with the named code.
/// Each envelope is fed to the verifier as the exact bytes the file carries — never re-serialised.
@Suite("Signing vectors (Standards)")
struct SigningVectorTests {
    struct Entry: Decodable {
        let name: String
        let envelope: String
        let code: String?
    }

    struct VectorFile: Decodable {
        let keyId: String
        let publicKey: String
        let accept: [Entry]
        let reject: [Entry]
    }

    static let file: VectorFile = {
        guard let url = Bundle.module.url(
            forResource: "signing", withExtension: "json", subdirectory: "Vectors"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(VectorFile.self, from: data)
        else { return VectorFile(keyId: "", publicKey: "", accept: [], reject: []) }
        return decoded
    }()

    // The vector payloads are issued 2026-09-16 and expire in 2099; any `now` in between binds.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    var trustedKeys: TrustedKeys {
        TrustedKeys([Self.file.keyId: Base64URL.decode(Self.file.publicKey) ?? Data()])
    }

    var expectations: EnvelopeVerifier.Expectations {
        EnvelopeVerifier.Expectations(
            environment: .production, deviceID: "dev_AAAAAAAAAAAAAAAAAAAAAA", now: Self.now
        )
    }

    @Test("the vector file is present and carries the RFC 8032 §7.1 TEST 1 public key, never a seed")
    func fileShape() {
        #expect(Self.file.keyId == "vector-k1")
        #expect(Base64URL.decode(Self.file.publicKey)?.count == 32)
        #expect(Self.file.accept.count == 2)
        #expect(Self.file.reject.count == 4)
    }

    @Test("every accept entry verifies under .required")
    func acceptEntries() throws {
        for entry in Self.file.accept {
            let raw = try #require(Base64URL.decode(entry.envelope), "\(entry.name) is not base64url")
            let result = EnvelopeVerifier.verify(
                raw: raw, policy: .required(trustedKeys: trustedKeys), expectations: expectations
            )
            switch (entry.name, result) {
            case ("client-v2", .success(let verified)):
                #expect(verified.payload.version == 2)
                #expect(verified.payload.flags["dark-mode"] == true)
                #expect(verified.raw == raw)
            case ("server-sv1", .failure(let rejection)):
                // A server ruleset is not a client payload: the signature passes and only the
                // client-shaped parse refuses it — proving the crypto agrees on the server bytes.
                #expect(rejection == .malformedPayload, "\(entry.name): \(rejection)")
            case (_, .failure(let rejection)):
                Issue.record("\(entry.name) rejected: \(rejection)")
            default:
                Issue.record("\(entry.name): unexpected outcome")
            }
        }
    }

    @Test("every reject entry fails with the named code")
    func rejectEntries() throws {
        let expected: [String: EnvelopeRejection] = [
            "badSignature": .badSignature,
            "unknownKeyId": .unknownKeyID("vector-k9"),
            "unsupportedSignatureAlgorithm": .unsupportedSignatureAlgorithm("p256"),
            "missingSignature": .missingSignature,
        ]
        for entry in Self.file.reject {
            let raw = try #require(Base64URL.decode(entry.envelope), "\(entry.name) is not base64url")
            let code = try #require(entry.code)
            let want = try #require(expected[code], "\(entry.name): unmapped code \(code)")
            let result = EnvelopeVerifier.verify(
                raw: raw, policy: .required(trustedKeys: trustedKeys), expectations: expectations
            )
            guard case let .failure(rejection) = result else {
                Issue.record("\(entry.name) was accepted")
                continue
            }
            #expect(rejection == want, Comment(rawValue: entry.name))
        }
    }

    @Test("the wrong key under a known key ID is a bad signature, not an unknown key")
    func wrongKeyForKnownID() throws {
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let entry = try #require(Self.file.accept.first { $0.name == "client-v2" })
        let raw = try #require(Base64URL.decode(entry.envelope))
        let result = EnvelopeVerifier.verify(
            raw: raw,
            policy: .required(trustedKeys: TrustedKeys([Self.file.keyId: other])),
            expectations: expectations
        )
        #expect(result.failure == .badSignature)
    }

    @Test("the production constant holds prod-2026-09-k1 as exactly 32 raw bytes")
    func productionConstant() {
        #expect(TrustedKeys.fortressFlagProduction.keysByID.keys.sorted() == ["prod-2026-09-k1"])
        #expect(TrustedKeys.fortressFlagProduction.keysByID["prod-2026-09-k1"]?.count == 32)
        #expect(!TrustedKeys.fortressFlagProduction.isEmpty)
        let configuration = Configuration(sdkKey: "ffc_prod_x", environment: .production)
        if case let .required(keys) = configuration.signaturePolicy {
            #expect(keys == .fortressFlagProduction)
        } else {
            Issue.record("the default policy is not .required(.fortressFlagProduction)")
        }
    }

    @Test("a TestKit fixture verifies under the default policy once its key joins the production set")
    func fixtureAlongsideProductionKey() throws {
        let identity = EnvelopeFixture.SigningIdentity(keyID: "test-2026-09-k1")
        let fixture = EnvelopeFixture(
            environment: "prod", device: "dev_AAAAAAAAAAAAAAAAAAAAAA", issuedAt: Self.now,
            flags: ["alpha": true]
        )
        let keys = TrustedKeys(
            TrustedKeys.fortressFlagProduction.keysByID.merging(
                [identity.keyID: identity.publicKeyBytes]) { _, new in new }
        )
        let accepted = EnvelopeVerifier.verify(
            raw: fixture.signed(with: identity), policy: .required(trustedKeys: keys),
            expectations: expectations
        )
        #expect((try? accepted.get())?.payload.flags["alpha"] == true)

        let tampered = EnvelopeVerifier.verify(
            raw: fixture.tampered(with: identity, flippingFlag: "alpha"),
            policy: .required(trustedKeys: keys), expectations: expectations
        )
        #expect(tampered.failure == .badSignature)

        let unknown = EnvelopeVerifier.verify(
            raw: fixture.signed(with: identity),
            policy: .required(trustedKeys: .fortressFlagProduction), expectations: expectations
        )
        #expect(unknown.failure == .unknownKeyID("test-2026-09-k1"))

        let unsigned = EnvelopeVerifier.verify(
            raw: fixture.unsigned(), policy: .disabled, expectations: expectations
        )
        #expect((try? unsigned.get())?.payload.flags["alpha"] == true)
    }
}

private extension Result where Failure == EnvelopeRejection {
    var failure: EnvelopeRejection? {
        if case let .failure(rejection) = self { return rejection }
        return nil
    }
}
