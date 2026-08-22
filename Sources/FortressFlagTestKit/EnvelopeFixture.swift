import CryptoKit
import Foundation
import FortressFlag

/// Builds contract-v1 envelopes for tests.
///
/// Shipped as a product rather than kept in the test target because two other groups need exactly
/// this: the backend team, to check their Go signer produces bytes this SDK's verifier accepts
/// before either side ships; and any future SDK (Android) that must agree on the same wire format.
/// A contract with one implementation is an assumption — Founding §5 calls the contract sacred,
/// and this is how it gets tested instead of asserted.
///
/// It deliberately mirrors what a *server* does, not what the SDK does, so a bug in the SDK's
/// decoder cannot hide behind a fixture that shares its code.
public struct EnvelopeFixture: Sendable {
    /// A signing key pair for tests. Generated per fixture — there are no checked-in private keys
    /// in this repository, and there never will be.
    public struct SigningIdentity: Sendable {
        public let keyID: String
        // The high-entropy string a secret scanner sees on the next line is CryptoKit's TYPE
        // NAME in a declaration, not a key. Annotated inline rather than allowlisted in a
        // .gitleaks.toml: a config allowlist is how a secret scanner quietly stops scanning, and
        // this way the exemption sits next to the thing it exempts where a reviewer will see it.
        public let privateKey: Curve25519.Signing.PrivateKey // gitleaks:allow

        /// The raw 32-byte public key, in the form `TrustedKeys` expects.
        public var publicKeyBytes: Data { privateKey.publicKey.rawRepresentation }

        public init(keyID: String = "test-key-1") {
            self.keyID = keyID
            self.privateKey = Curve25519.Signing.PrivateKey()
        }
    }

    public var version: Int
    public var tenant: String
    public var environment: String
    public var device: String
    public var issuedAt: Date
    public var expiresAt: Date
    /// The value union (contract v2). Boolean literals still read as they always did —
    /// `["dark-mode": true]` — and a `version: 1` fixture should carry only `.bool` values,
    /// exactly as a v1 server could only ever have sent.
    public var flags: [String: FlagValue]

    public init(
        // Contract v2, the newest dialect the SDK asks for. Pass 1 to model a pre-upgrade
        // server or cache file.
        version: Int = 2,
        tenant: String = "11111111-1111-1111-1111-111111111111",
        environment: String = "dev",
        device: String,
        issuedAt: Date = Date(),
        expiresAt: Date? = nil,
        flags: [String: FlagValue] = [:]
    ) {
        self.version = version
        self.tenant = tenant
        self.environment = environment
        self.device = device
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt ?? issuedAt.addingTimeInterval(1800)
        self.flags = flags
    }

    /// The inner payload JSON — the exact bytes that get signed.
    public func payloadJSON() -> Data {
        // Hand-assembled rather than `JSONEncoder`d so that a change to the SDK's own Codable
        // conformance cannot silently change what the fixture claims a server sends.
        let jsonFlags: [String: Any] = flags.mapValues { value in
            switch value {
            case let .bool(bool): return bool
            case let .string(string): return string
            case let .number(number): return number
            }
        }
        var object: [String: Any] = [
            "v": version,
            "tenant": tenant,
            "environment": environment,
            "device": device,
            "issuedAt": Self.rfc3339(issuedAt),
            "expiresAt": Self.rfc3339(expiresAt),
            "flags": jsonFlags,
        ]
        if flags.isEmpty {
            object["flags"] = [String: Bool]()
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// A complete signed envelope, as the client API would return it.
    public func signed(with identity: SigningIdentity) -> Data {
        let payload = payloadJSON()
        let signature = (try? identity.privateKey.signature(for: payload)) ?? Data()
        return Self.envelope(
            payload: payload,
            sig: "ed25519:\(identity.keyID):\(Self.base64URL(signature))"
        )
    }

    /// An envelope with no signature, for exercising `SignaturePolicy.disabled` and for asserting
    /// that `.required` rejects it.
    public func unsigned() -> Data {
        Self.envelope(payload: payloadJSON(), sig: nil)
    }

    /// A signed envelope whose payload has been altered after signing — the exact shape of a
    /// man-in-the-middle or a poisoned cache file.
    public func tampered(with identity: SigningIdentity, flippingFlag key: String) -> Data {
        let honest = payloadJSON()
        let signature = (try? identity.privateKey.signature(for: honest)) ?? Data()

        var forged = self
        forged.flags[key] = .bool(!(flags[key]?.boolValue ?? false))

        return Self.envelope(
            payload: forged.payloadJSON(),
            sig: "ed25519:\(identity.keyID):\(Self.base64URL(signature))"
        )
    }

    // MARK: - Helpers

    private static func envelope(payload: Data, sig: String?) -> Data {
        var object: [String: Any] = ["payload": base64URL(payload)]
        if let sig { object["sig"] = sig }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
