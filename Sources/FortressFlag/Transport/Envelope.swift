import Foundation
import os

/// The contract version this SDK build ASKS FOR (`?v=2` on every fetch).
///
/// Checked, not assumed. An SDK that meets a `v` it does not know must fall back to the cache
/// rather than guess at a payload whose meaning has changed — Founding §5 forbids breaking a
/// shipped SDK, and the flip side of that promise is that the SDK has to notice when the server
/// speaks a dialect it was not built for.
let supportedContractVersion = 2

/// Every version this build can DECODE. v1 stays accepted for one load-bearing reason: the
/// durable cache holds whatever envelope the device last accepted, and the first launch after
/// an SDK upgrade reads a v1 file. Rejecting it would boot every updating customer's app into
/// the `false` fallback for a session — the exact flicker the cache exists to prevent
/// (Founding §8.4). A v1 payload's `[String: Bool]` decodes into `.bool` values naturally.
let supportedContractVersions = 1...supportedContractVersion

/// The outer envelope: an opaque payload and a detached signature over its exact bytes.
///
/// **Nothing lives outside the signature.** That is the whole design. An inline JSON object with
/// a `sig` field alongside the data would require the server and every SDK to agree, byte for
/// byte, on a canonical serialisation — key ordering, number formatting, unicode escaping — and
/// any divergence between Go and Swift shows up as a signature that fails in production on some
/// payloads and not others. Signing the literal bytes we transmit removes that entire class of
/// bug, and it means no field can be trusted before the signature has been checked, because there
/// is no field to read.
///
/// The cost is that a response is not human-readable in a terminal. `docs/contract-v1.md` carries
/// a one-line command to decode one.
struct SignedEnvelope: Decodable, Sendable {
    /// Unpadded base64url of the payload JSON.
    let payload: String

    /// `ed25519:<keyID>:<unpadded base64url signature>`. Absent only when the server is not
    /// signing, which `SignaturePolicy.required` rejects.
    let sig: String?
}

/// The signed payload: this device's flag values for one environment at one moment.
///
/// Note what is *not* here. No flag names, no descriptions, no `updatedAt` — the management API
/// carries those for the dashboard, and they are internal roadmap prose that must never reach an
/// end-user's device (Founding §2.1). The device gets keys and scalar values; since contract v2
/// the values are the `FlagValue` union, and a v1 payload's booleans decode into it unchanged.
struct FlagPayload: Sendable, Equatable {
    let version: Int
    let tenant: String
    let environment: String
    let device: String
    let issuedAt: Date
    let expiresAt: Date
    let flags: [String: FlagValue]
}

extension FlagPayload: Decodable {
    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case tenant, environment, device, issuedAt, expiresAt, flags
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        tenant = try container.decode(String.self, forKey: .tenant)
        environment = try container.decode(String.self, forKey: .environment)
        device = try container.decode(String.self, forKey: .device)
        flags = try container.decode([String: FlagValue].self, forKey: .flags)

        issuedAt = try FlagPayload.decodeTimestamp(container, .issuedAt)
        expiresAt = try FlagPayload.decodeTimestamp(container, .expiresAt)
    }

    /// RFC 3339, accepted with or without fractional seconds.
    ///
    /// The backend emits `time.RFC3339` (no fraction) today. Accepting both is not laxity: a
    /// server-side change from `RFC3339` to `RFC3339Nano` is invisible in a Go code review and
    /// would otherwise brick every shipped SDK, which is exactly the failure Founding §5 exists
    /// to prevent.
    private static func decodeTimestamp(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> Date {
        let raw = try container.decode(String.self, forKey: key)
        guard let date = ISO8601.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "not an RFC 3339 timestamp"
            )
        }
        return date
    }
}

/// RFC 3339 parsing, tolerant of fractional seconds.
///
/// The formatters are held behind a lock rather than as bare `static let`s. `ISO8601DateFormatter`
/// is not `Sendable`, and its thread-safety is folklore rather than documented API — cheap to
/// serialise (this runs twice per refresh) and not worth a data race in a library that runs inside
/// someone else's app.
enum ISO8601 {
    private struct Formatters {
        let withFraction: ISO8601DateFormatter
        let withoutFraction: ISO8601DateFormatter

        init() {
            withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            withoutFraction = ISO8601DateFormatter()
            withoutFraction.formatOptions = [.withInternetDateTime]
        }
    }

    // `uncheckedState` because `ISO8601DateFormatter` is not `Sendable`. Serialising every access
    // behind this lock is exactly what makes that safe.
    private static let formatters = OSAllocatedUnfairLock(uncheckedState: Formatters())

    static func parse(_ string: String) -> Date? {
        formatters.withLockUnchecked {
            $0.withoutFraction.date(from: string) ?? $0.withFraction.date(from: string)
        }
    }

    static func string(from date: Date) -> String {
        formatters.withLockUnchecked { $0.withoutFraction.string(from: date) }
    }
}
