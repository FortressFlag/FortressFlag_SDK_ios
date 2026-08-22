import Foundation

/// The real client transport.
///
/// Everything here is defensive against a server we do not control — which, on the data plane,
/// includes a CDN edge and whatever a hostile network puts in front of it.
final class HTTPClientAPI: ClientAPI, @unchecked Sendable {
    /// `@unchecked Sendable` covers the stored `URLSession`, which is safe to use concurrently
    /// but not universally annotated as such across the SDKs we build against. Every other stored
    /// property is a `let` of a `Sendable` type.

    private let configuration: Configuration
    private let session: URLSession
    private let log: Log

    /// Hard ceiling on a response body. A payload is kilobytes; anything approaching this is a
    /// server that is broken or hostile, and buffering it would be our memory problem inside
    /// someone else's app.
    static let maximumResponseBytes = FileEnvelopeCache.maximumEnvelopeBytes

    /// - Parameter protocolClasses: injected `URLProtocol` subclasses. Tests use this to drive the
    ///   *real* transport deterministically — status codes, oversized bodies, malformed headers —
    ///   rather than substituting a fake that would only test our idea of what URLSession does.
    ///   Always nil in production.
    init(configuration: Configuration, log: Log, protocolClasses: [AnyClass]? = nil) {
        self.configuration = configuration
        self.log = log

        // Ephemeral, and ours alone. The SDK must never touch the host app's cookie jar,
        // credential store or URL cache: reading them would be a privacy problem and writing them
        // would be an availability one.
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        // We keep our own durable cache and re-verify its signature; a second, unverified copy in
        // URLCache would be a store of flag state nobody checks.
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Fail fast rather than holding a request open waiting for a network. The cascade already
        // has an answer; a pending request is worth less than a prompt failure.
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout.seconds
        sessionConfiguration.timeoutIntervalForResource = configuration.requestTimeout.seconds * 2
        // Founding §7.4: TLS 1.2 or better, including edge to SDK. Stated explicitly rather than
        // inherited from whatever the platform default becomes.
        sessionConfiguration.tlsMinimumSupportedProtocolVersion = .TLSv12

        if let protocolClasses {
            sessionConfiguration.protocolClasses = protocolClasses
        }

        self.session = URLSession(configuration: sessionConfiguration)
    }

    func fetch(deviceID: String, etag: String?, tags: String?) async -> FetchOutcome {
        let request: URLRequest
        switch makeRequest(deviceID: deviceID, etag: etag, tags: tags) {
        case let .success(built): request = built
        case let .failure(failure): return .failure(failure)
        }

        do {
            let (stream, response) = try await session.bytes(for: request)

            guard let http = response as? HTTPURLResponse else {
                return .failure(.other("non-HTTP response"))
            }

            // A non-nil answer means the status alone decided the outcome and the body is
            // irrelevant. Extracted so that `fetch` reads as "decide on the status, then read the
            // body", which is what it does.
            if let decided = statusOutcome(http) {
                return decided
            }

            // Declared length is checked before a byte is read, so an obviously oversized response
            // costs nothing. The streaming cap below is what actually enforces the limit, because
            // Content-Length is a claim, not a promise.
            if http.expectedContentLength > Int64(Self.maximumResponseBytes) {
                return .failure(.responseTooLarge)
            }

            var raw = Data()
            raw.reserveCapacity(8 * 1024)
            for try await byte in stream {
                raw.append(byte)
                if raw.count > Self.maximumResponseBytes {
                    // Abandoning the loop cancels the underlying task, so a server streaming
                    // forever stops costing us bandwidth as well as memory.
                    return .failure(.responseTooLarge)
                }
            }

            let responseETag = http.value(forHTTPHeaderField: "ETag")
            return .success(raw: raw, etag: responseETag)
        } catch {
            return .failure(Self.classify(error))
        }
    }

    /// Maps a response status to an outcome, or nil when the body still has to be read.
    private func statusOutcome(_ http: HTTPURLResponse) -> FetchOutcome? {
        switch http.statusCode {
        case 200:
            return nil
        case 304:
            return .notModified
        case 401, 403:
            log.error(
                """
                The client API rejected this SDK key (HTTP \(http.statusCode)). Flags will \
                continue to resolve from the last cached values. Check that the key is for \
                the '\(configuration.environment.rawValue)' environment and has not been revoked.
                """
            )
            return .failure(.unauthorized)
        case 429:
            return .failure(.rateLimited(retryAfter: Self.retryAfterSeconds(http)))
        case 500...599:
            return .failure(.serverError(status: http.statusCode))
        default:
            return .failure(.unexpectedStatus(http.statusCode))
        }
    }

    // MARK: - Request

    func makeRequest(deviceID: String, etag: String?, tags: String?) -> Result<URLRequest, TransportFailure> {
        guard var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent("/v1/client/flags"),
            resolvingAgainstBaseURL: false
        ) else {
            return .failure(.badRequestURL)
        }
        components.queryItems = [
            URLQueryItem(name: "environment", value: configuration.environment.rawValue),
            // The contract this build asks for (v2: the value union). A server too old to know
            // it answers 400, the fetch fails, and the cascade serves the cache — never a guess.
            URLQueryItem(name: "v", value: String(supportedContractVersion)),
        ]

        guard let url = components.url else { return .failure(.badRequestURL) }

        // Belt and braces over `Configuration.validate()`. That runs at start-up and only logs;
        // this is the check that actually stops a plaintext request leaving the device, because a
        // caller who ignored the warning must still not be able to put an SDK key on the wire in
        // the clear.
        guard isTransportAcceptable(url) else {
            log.error("refusing to send an SDK key over plaintext HTTP to \(url.host ?? "an unknown host")")
            return .failure(.insecureTransportRefused)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.sdkKey)", forHTTPHeaderField: "Authorization")
        request.setValue(deviceID, forHTTPHeaderField: "X-FF-Device")
        request.setValue(SDKInfo.userAgent, forHTTPHeaderField: "X-FF-SDK")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let tags {
            // Already validated, merged and base64url-encoded (Tags.encode); header-safe by
            // construction.
            request.setValue(tags, forHTTPHeaderField: Tags.headerName)
        }
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return .success(request)
    }

    private func isTransportAcceptable(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        guard configuration.allowsInsecureLocalTransport, url.scheme?.lowercased() == "http" else {
            return false
        }
        guard Configuration.loopbackHosts.contains(url.host ?? "") else { return false }
        log.warning("sending a plaintext request to \(url.host ?? "localhost") — development only")
        return true
    }

    // MARK: - Response helpers

    /// `Retry-After` as seconds. Only the delta-seconds form is honoured; the HTTP-date form is
    /// ignored rather than parsed against a device clock we already know may be wrong.
    static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds > 0
        else {
            return nil
        }
        return seconds
    }

    private static func classify(_ error: any Error) -> TransportFailure {
        if error is CancellationError { return .cancelled }

        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .other(nsError.localizedDescription) }

        switch nsError.code {
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorCancelled:
            return .cancelled
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDataNotAllowed,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorInternationalRoamingOff:
            return .offline
        default:
            return .other("URLError \(nsError.code)")
        }
    }
}
