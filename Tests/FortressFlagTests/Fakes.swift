import Foundation
@testable import FortressFlag

/// A transport that replays a scripted sequence of outcomes.
///
/// Scripted rather than "returns X" so a test can express a *sequence* — fail, fail, succeed —
/// which is where the interesting behaviour (backoff, cache retention, recovery) lives.
final class StubClientAPI: ClientAPI, @unchecked Sendable {
    /// One fetch as the transport saw it.
    struct RecordedRequest: Sendable {
        let deviceID: String
        let etag: String?
        let tags: String?
    }

    private let lock = NSLock()
    private var scripted: [FetchOutcome]
    private var fallback: FetchOutcome
    private(set) var requests: [RecordedRequest] = []

    init(_ scripted: [FetchOutcome], fallback: FetchOutcome = .failure(.offline)) {
        self.scripted = scripted
        self.fallback = fallback
    }

    convenience init(always outcome: FetchOutcome) {
        self.init([], fallback: outcome)
    }

    func fetch(deviceID: String, etag: String?, tags: String?) async -> FetchOutcome {
        // Scoped locking, not lock()/unlock(): the latter is unavailable in an async context
        // because a suspension while holding the lock could resume on a different thread.
        lock.withLock {
            requests.append(RecordedRequest(deviceID: deviceID, etag: etag, tags: tags))
            return scripted.isEmpty ? fallback : scripted.removeFirst()
        }
    }

    var requestCount: Int {
        lock.withLock { requests.count }
    }

    var lastETag: String?? {
        lock.withLock { requests.last?.etag }
    }

    var lastTags: String?? {
        lock.withLock { requests.last?.tags }
    }
}

final class InMemoryEnvelopeCache: EnvelopeCache, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CachedEnvelope?
    private(set) var clearCount = 0

    init(seeded: Data? = nil, etag: String? = nil) {
        if let seeded { stored = CachedEnvelope(raw: seeded, etag: etag) }
    }

    func load() -> CachedEnvelope? {
        lock.withLock { stored }
    }

    func store(_ raw: Data, etag: String?) {
        lock.withLock { stored = CachedEnvelope(raw: raw, etag: etag) }
    }

    func clear() {
        lock.withLock {
            stored = nil
            clearCount += 1
        }
    }

    var contents: Data? {
        lock.withLock { stored?.raw }
    }
}

struct StubIdentity: DeviceIdentityProviding {
    let result: Result<String, IdentityFailure>

    init(_ deviceID: String) { result = .success(deviceID) }
    init(failing failure: IdentityFailure) { result = .failure(failure) }

    func identity() -> Result<String, IdentityFailure> { result }
    func reset() {}
}

extension Log {
    /// Tests should not write to the unified log.
    static var silent: Log { Log(policy: .silent, category: "test") }
}

enum TestSupport {
    static let deviceID = "dev_AAAAAAAAAAAAAAAAAAAAAA"

    static func configuration(
        environment: Environment = .development,
        trustedKeys: TrustedKeys,
        refreshInterval: Duration = .seconds(300)
    ) -> Configuration {
        Configuration(
            sdkKey: "ffc_\(environment.rawValue)_testtesttesttesttest",
            environment: environment,
            signaturePolicy: .required(trustedKeys: trustedKeys),
            refreshInterval: refreshInterval,
            logging: .silent
        )
    }

    /// Deterministic "randomness": always the midpoint, i.e. no jitter. Tests that care about
    /// jitter bounds supply their own.
    static let noJitter: @Sendable (ClosedRange<Double>) -> Double = { _ in 0 }

    static func fixedClock(_ date: Date) -> @Sendable () -> Date { { date } }
}
