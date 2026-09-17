import Foundation

/// Why a fetch did not produce an envelope.
enum TransportFailure: Error, Sendable, Equatable {
    case offline
    case timedOut
    /// The SDK key was rejected or revoked. Not fatal — the cache keeps answering.
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case unexpectedStatus(Int)
    case responseTooLarge
    case cancelled
    case insecureTransportRefused
    case badRequestURL
    case other(String)
}

/// The result of one attempt to fetch this device's flag values.
enum FetchOutcome: Sendable {
    /// The exact response bytes, unparsed. Verification happens above this layer so that the
    /// transport never has an opinion about whether a payload is trustworthy.
    case success(raw: Data, etag: String?)
    /// The server confirmed our cached copy is current. The cheapest possible answer, and the one
    /// most requests should get (Founding §6).
    case notModified
    case failure(TransportFailure)
}

/// The client data-plane contract, as the SDK consumes it.
///
/// A protocol so that the same SDK code path runs against the control plane today, the CDN edge
/// tomorrow, and a fake in tests — and so that swapping any of those is not a change to the
/// evaluation logic.
protocol ClientAPI: Sendable {
    /// `tags` is the pre-encoded `X-FF-Tags` header value, or nil to send none. Encoded above
    /// this layer (see `Tags.encode`) so the transport stays a dumb pipe and tests can assert
    /// the exact bytes a fetch carried.
    func fetch(deviceID: String, etag: String?, tags: String?) async -> FetchOutcome
}

/// Identifies this SDK build to the server. Sent so that a server-side bug affecting one SDK
/// version can be found without asking customers what they shipped.
enum SDKInfo {
    static let version = "1.0.0"
    static let platform = "ios"
    static var userAgent: String { "\(platform)/\(version)" }
}
