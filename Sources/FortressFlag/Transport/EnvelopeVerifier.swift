import CryptoKit
import Foundation

/// Why an envelope was not accepted.
///
/// A rejection is never fatal: it means "serve the last value this device saw" (Founding §8.4).
/// Enumerated in this much detail because "flags stopped updating" is otherwise one of the
/// hardest things to debug in a customer's app, and the answer should be one log line.
enum EnvelopeRejection: Error, Sendable, Equatable {
    case malformedEnvelope
    case missingSignature
    case malformedSignature
    case unsupportedSignatureAlgorithm(String)
    case unknownKeyID(String)
    case badSignature
    case malformedPayload
    case unsupportedContractVersion(Int)
    case environmentMismatch(expected: String, received: String)
    case deviceMismatch
    case expired(at: Date)
    case issuedInTheFuture(at: Date)
}

/// An envelope that passed every check, kept alongside the exact bytes it arrived as.
///
/// `raw` is retained so the cache can store what was signed rather than a re-serialisation of what
/// we parsed. Re-serialising would silently strip any field a future server adds and break the
/// signature on reload.
struct VerifiedEnvelope: Sendable {
    let raw: Data
    let payload: FlagPayload
}

enum EnvelopeVerifier {
    /// What the payload must claim to be, for it to be about us.
    struct Expectations: Sendable {
        let environment: Environment

        /// The device the payload must be addressed to, or `nil` to skip that check.
        ///
        /// `nil` happens in one situation: loading the cache when the keychain is unavailable, so
        /// the SDK does not yet know its own identity. Skipping the check there is deliberate —
        /// the alternative is discarding the last recorded value and dropping every flag to
        /// `false` (Founding §8.4) because of a *transient* keychain failure. What is given up is
        /// small: the file being read is inside the app's own sandbox, and its signature is still
        /// verified, so planting another device's envelope requires filesystem access to the
        /// device, at which point the attacker has already won by easier routes.
        let deviceID: String?

        let now: Date

        /// Tolerance for a wrong device clock. End users set their clocks; a device an hour fast
        /// should not lose flag updates.
        var clockSkew: TimeInterval = 300

        /// Whether `expiresAt` is enforced.
        ///
        /// **True for a live response, false when loading the cache** — and that asymmetry is the
        /// single most important line in this file.
        ///
        /// On a live response, expiry is the replay window: without it, anyone who captured a
        /// valid response could serve it back forever, pinning a device to old flag values.
        ///
        /// On a cache load it must *not* apply. Founding §8.4 says the last recorded value is the
        /// primary fallback, and a device that has been offline for a month still has to serve
        /// what it last saw. Expiring the cache would silently revert every flag on that device to
        /// `false` — turning an outage into a feature regression, which is precisely the failure
        /// mode the cascade exists to prevent. Expiry governs *freshness*, not *validity*.
        var enforceExpiry: Bool = true
    }

    static func verify(
        raw: Data,
        policy: SignaturePolicy,
        expectations: Expectations
    ) -> Result<VerifiedEnvelope, EnvelopeRejection> {
        guard let envelope = try? JSONDecoder().decode(SignedEnvelope.self, from: raw),
              let payloadBytes = Base64URL.decode(envelope.payload)
        else {
            return .failure(.malformedEnvelope)
        }

        if case let .required(trustedKeys) = policy {
            if let failure = checkSignature(envelope.sig, over: payloadBytes, trustedKeys: trustedKeys) {
                return .failure(failure)
            }
        }

        guard let payload = try? JSONDecoder().decode(FlagPayload.self, from: payloadBytes) else {
            return .failure(.malformedPayload)
        }

        if let failure = checkBinding(payload, expectations) {
            return .failure(failure)
        }

        return .success(VerifiedEnvelope(raw: raw, payload: payload))
    }

    // MARK: - Signature

    private static func checkSignature(
        _ sig: String?,
        over payloadBytes: Data,
        trustedKeys: TrustedKeys
    ) -> EnvelopeRejection? {
        guard let sig else { return .missingSignature }

        // `algorithm:keyID:signature`, split at the first two colons: the SIGNATURE part may
        // carry extra colons, the key ID never can (contract-v1 §Signing keys, `[a-z0-9-]+`).
        let parts = sig.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return .malformedSignature }

        let algorithm = String(parts[0])
        let keyID = String(parts[1])
        guard algorithm == "ed25519" else { return .unsupportedSignatureAlgorithm(algorithm) }

        guard let signature = Base64URL.decode(String(parts[2])) else { return .malformedSignature }
        guard let keyBytes = trustedKeys.keysByID[keyID] else { return .unknownKeyID(keyID) }
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes) else {
            // A malformed key in our own trust store. Treated as "cannot verify with this key"
            // rather than a hard failure, so one bad entry does not disable a rotation set.
            return .unknownKeyID(keyID)
        }

        guard publicKey.isValidSignature(signature, for: payloadBytes) else { return .badSignature }
        return nil
    }

    // MARK: - Binding

    /// Confirms the payload is about *this* device, *this* environment, and *now*.
    ///
    /// A signature alone proves only that FortressFlag produced the bytes at some point. Without
    /// these checks a valid production payload could be replayed at a development build, another
    /// device's payload could be served to this one, and yesterday's values could be pinned in
    /// place indefinitely. The signature covers all of these fields, so an attacker cannot edit
    /// them — but the SDK still has to *look*.
    private static func checkBinding(
        _ payload: FlagPayload,
        _ expectations: Expectations
    ) -> EnvelopeRejection? {
        // The RANGE, not merely the newest: the durable cache may hold a v1 envelope across an
        // SDK upgrade, and rejecting it would drop every flag to `false` for a session — see
        // `supportedContractVersions`.
        guard supportedContractVersions.contains(payload.version) else {
            return .unsupportedContractVersion(payload.version)
        }
        guard payload.environment == expectations.environment.rawValue else {
            return .environmentMismatch(
                expected: expectations.environment.rawValue,
                received: payload.environment
            )
        }
        if let expectedDevice = expectations.deviceID, payload.device != expectedDevice {
            return .deviceMismatch
        }
        if payload.issuedAt.timeIntervalSince(expectations.now) > expectations.clockSkew {
            return .issuedInTheFuture(at: payload.issuedAt)
        }
        if expectations.enforceExpiry,
           expectations.now.timeIntervalSince(payload.expiresAt) > expectations.clockSkew {
            return .expired(at: payload.expiresAt)
        }
        return nil
    }
}
