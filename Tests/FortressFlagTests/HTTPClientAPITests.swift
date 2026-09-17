import Foundation
import Testing
@testable import FortressFlag

/// Drives the **real** `HTTPClientAPI` through an injected `URLProtocol`.
///
/// Substituting a fake `ClientAPI` here would only test our idea of what URLSession does. The
/// behaviour that matters — status mapping, the response size cap, header shape, what happens to a
/// server that lies about `Content-Length` — lives in the interaction with URLSession itself, so
/// that is what gets exercised.
@Suite("HTTP transport", .serialized)
struct HTTPClientAPITests {
    func makeAPI(
        environment: Environment = .development,
        baseURL: String = "https://edge.example.com",
        allowsInsecureLocalTransport: Bool = false
    ) -> HTTPClientAPI {
        let url = URL(string: baseURL) ?? Configuration.defaultBaseURL
        let configuration = Configuration(
            sdkKey: "ffc_\(environment.rawValue)_testtesttesttest",
            environment: environment,
            baseURL: url,
            signaturePolicy: .disabled,
            requestTimeout: .seconds(5),
            allowsInsecureLocalTransport: allowsInsecureLocalTransport,
            logging: .silent
        )
        return HTTPClientAPI(
            configuration: configuration, log: .silent, protocolClasses: [StubURLProtocol.self])
    }

    // MARK: - Request shape

    @Test("the request carries the key, the device and the SDK version")
    func requestHeaders() throws {
        let request = try makeAPI()
            .makeRequest(deviceID: TestSupport.deviceID, etag: "\"v4\"", tags: nil).get()

        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ffc_dev_testtesttesttest")
        #expect(request.value(forHTTPHeaderField: "X-FF-Device") == TestSupport.deviceID)
        #expect(request.value(forHTTPHeaderField: "X-FF-SDK") == "ios/1.0.0")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == "\"v4\"")
        #expect(request.httpMethod == "GET")
    }

    @Test("the environment travels in the query, never as a default")
    func environmentInQuery() throws {
        let api = makeAPI(environment: .production)
        let request = try api.makeRequest(deviceID: TestSupport.deviceID, etag: nil, tags: nil).get()
        let url = try #require(request.url?.absoluteString)

        #expect(url.contains("/v1/client/flags"))
        #expect(url.contains("environment=prod"))
    }

    @Test("every fetch asks for contract v2")
    func contractVersionInQuery() throws {
        let request = try makeAPI().makeRequest(deviceID: TestSupport.deviceID, etag: nil, tags: nil).get()
        let url = try #require(request.url?.absoluteString)
        #expect(url.contains("v=2"))
    }

    @Test("no If-None-Match header when there is nothing cached")
    func noETagHeader() throws {
        let request = try makeAPI().makeRequest(deviceID: TestSupport.deviceID, etag: nil, tags: nil).get()
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("pre-encoded tags travel in X-FF-Tags, and their absence omits the header")
    func tagsHeader() throws {
        let encoded = "eyJhcHBWZXJzaW9uIjoiMi4xIn0"
        let with = try makeAPI().makeRequest(deviceID: TestSupport.deviceID, etag: nil, tags: encoded).get()
        #expect(with.value(forHTTPHeaderField: "X-FF-Tags") == encoded)

        let without = try makeAPI().makeRequest(deviceID: TestSupport.deviceID, etag: nil, tags: nil).get()
        #expect(without.value(forHTTPHeaderField: "X-FF-Tags") == nil)
    }

    @Test("a plaintext base URL never gets an SDK key on the wire")
    func plaintextRefused() {
        // `Configuration.validate()` warns about this at start-up but only logs. This is the check
        // that actually stops the request, for a caller who ignored the warning.
        let result = makeAPI(baseURL: "http://edge.example.com")
            .makeRequest(deviceID: TestSupport.deviceID, etag: nil, tags: nil)

        if case let .failure(failure) = result {
            #expect(failure == .insecureTransportRefused)
        } else {
            Issue.record("a plaintext request was built")
        }
    }

    @Test("the loopback escape hatch does not extend to real hosts")
    func loopbackOnly() {
        let allowed = makeAPI(baseURL: "http://localhost:8080", allowsInsecureLocalTransport: true)
            .makeRequest(deviceID: TestSupport.deviceID, etag: nil, tags: nil)
        #expect((try? allowed.get()) != nil)

        let refused = makeAPI(baseURL: "http://internal.corp.example.com", allowsInsecureLocalTransport: true)
            .makeRequest(deviceID: TestSupport.deviceID, etag: nil, tags: nil)
        if case let .failure(failure) = refused {
            #expect(failure == .insecureTransportRefused)
        } else {
            Issue.record("a plaintext request to a non-loopback host was built")
        }
    }

    // MARK: - Response handling

    @Test("a 200 returns the body and the ETag")
    func success() async {
        StubURLProtocol.respond(
            status: 200, body: Data("{\"payload\":\"e30\"}".utf8), headers: ["ETag": "\"v9\""])
        defer { StubURLProtocol.reset() }

        let outcome = await makeAPI().fetch(deviceID: TestSupport.deviceID, etag: nil, tags: nil)

        if case let .success(raw, etag) = outcome {
            #expect(raw == Data("{\"payload\":\"e30\"}".utf8))
            #expect(etag == "\"v9\"")
        } else {
            Issue.record("expected success, got \(outcome)")
        }
    }

    @Test(
        "every status maps to the right failure",
        arguments: [
            (304, nil as TransportFailure?),
            (401, TransportFailure.unauthorized),
            (403, .unauthorized),
            (429, .rateLimited(retryAfter: nil)),
            (500, .serverError(status: 500)),
            (503, .serverError(status: 503)),
            (418, .unexpectedStatus(418)),
            (302, .unexpectedStatus(302)),
        ]
    )
    func statusMapping(status: Int, expected: TransportFailure?) async {
        StubURLProtocol.respond(status: status, body: Data(), headers: [:])
        defer { StubURLProtocol.reset() }

        let outcome = await makeAPI().fetch(deviceID: TestSupport.deviceID, etag: nil, tags: nil)

        switch (outcome, expected) {
        case (.notModified, nil):
            break
        case let (.failure(actual), .some(want)):
            #expect(actual == want)
        default:
            Issue.record("status \(status) produced \(outcome)")
        }
    }

    @Test("Retry-After in delta-seconds is honoured")
    func retryAfterParsed() async {
        StubURLProtocol.respond(status: 429, body: Data(), headers: ["Retry-After": "45"])
        defer { StubURLProtocol.reset() }

        let outcome = await makeAPI().fetch(deviceID: TestSupport.deviceID, etag: nil, tags: nil)
        #expect(outcome.failure == .rateLimited(retryAfter: 45))
    }

    @Test(
        "an unparseable Retry-After is ignored rather than guessed at",
        arguments: ["Wed, 21 Oct 2026 07:28:00 GMT", "soon", "-1", "0", ""]
    )
    func retryAfterIgnored(header: String) async {
        // The HTTP-date form is deliberately not parsed: it would be evaluated against a device
        // clock we already know may be wrong, and backoff already has a sane answer.
        StubURLProtocol.respond(status: 429, body: Data(), headers: ["Retry-After": header])
        defer { StubURLProtocol.reset() }

        let outcome = await makeAPI().fetch(deviceID: TestSupport.deviceID, etag: nil, tags: nil)
        #expect(outcome.failure == .rateLimited(retryAfter: nil))
    }

    @Test("an oversized body is refused, not buffered")
    func oversizedBodyRefused() async {
        // A hostile or broken server must not be able to make its memory problem into the host
        // app's memory problem.
        let huge = Data(repeating: 0x41, count: HTTPClientAPI.maximumResponseBytes + 1024)
        StubURLProtocol.respond(status: 200, body: huge, headers: [:])
        defer { StubURLProtocol.reset() }

        let outcome = await makeAPI().fetch(deviceID: TestSupport.deviceID, etag: nil, tags: nil)
        #expect(outcome.failure == .responseTooLarge)
    }

    @Test("a body just under the cap is accepted")
    func atCapAccepted() async {
        let large = Data(repeating: 0x41, count: HTTPClientAPI.maximumResponseBytes - 1)
        StubURLProtocol.respond(status: 200, body: large, headers: [:])
        defer { StubURLProtocol.reset() }

        let outcome = await makeAPI().fetch(deviceID: TestSupport.deviceID, etag: nil, tags: nil)
        if case let .success(raw, _) = outcome {
            #expect(raw.count == large.count)
        } else {
            Issue.record("a body under the cap was refused: \(outcome)")
        }
    }

    @Test("a network error becomes a failure, never a throw")
    func networkErrorClassified() async {
        StubURLProtocol.fail(with: URLError(.notConnectedToInternet))
        defer { StubURLProtocol.reset() }

        let outcome = await makeAPI().fetch(deviceID: TestSupport.deviceID, etag: nil, tags: nil)
        #expect(outcome.failure == .offline)
    }

    @Test("a timeout is distinguishable from being offline")
    func timeoutClassified() async {
        StubURLProtocol.fail(with: URLError(.timedOut))
        defer { StubURLProtocol.reset() }

        let outcome = await makeAPI().fetch(deviceID: TestSupport.deviceID, etag: nil, tags: nil)
        #expect(outcome.failure == .timedOut)
    }

    @Test("an unrecognised URL error still lands as a failure")
    func unknownErrorClassified() async {
        StubURLProtocol.fail(with: URLError(.badServerResponse))
        defer { StubURLProtocol.reset() }

        let outcome = await makeAPI().fetch(deviceID: TestSupport.deviceID, etag: nil, tags: nil)
        #expect(outcome.failure != nil)
    }

    @Test("garbage in the body is still returned — judging it is the verifier's job")
    func garbageBodyPassedThrough() async {
        // The transport deliberately has no opinion on whether a payload is trustworthy. One layer
        // decides that, and it is the one holding the signing keys.
        StubURLProtocol.respond(status: 200, body: Data("<html>captive portal</html>".utf8), headers: [:])
        defer { StubURLProtocol.reset() }

        let outcome = await makeAPI().fetch(deviceID: TestSupport.deviceID, etag: nil, tags: nil)
        #expect(outcome.failure == nil)
    }
}

extension FetchOutcome {
    var failure: TransportFailure? {
        if case let .failure(failure) = self { return failure }
        return nil
    }
}

/// Serves a scripted response to whatever the session asks for.
final class StubURLProtocol: URLProtocol {
    private struct Script: @unchecked Sendable {
        var status: Int = 200
        var body: Data = Data()
        var headers: [String: String] = [:]
        var error: (any Error)?
    }

    private static let script = NSLock()
    nonisolated(unsafe) private static var current = Script()

    static func respond(status: Int, body: Data, headers: [String: String]) {
        script.withLock { current = Script(status: status, body: body, headers: headers, error: nil) }
    }

    static func fail(with error: any Error) {
        script.withLock { current = Script(error: error) }
    }

    static func reset() {
        script.withLock { current = Script() }
    }

    private static var snapshot: Script {
        script.withLock { current }
    }

    // swiftlint:disable static_over_final_class
    // These override `class func` declarations on URLProtocol. `static` is non-overridable, so it
    // is not an option here — the rule does not know the difference.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // swiftlint:enable static_over_final_class

    override func startLoading() {
        let script = Self.snapshot

        if let error = script.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: script.status, httpVersion: "HTTP/1.1", headerFields: script.headers
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !script.body.isEmpty {
            client?.urlProtocol(self, didLoad: script.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
