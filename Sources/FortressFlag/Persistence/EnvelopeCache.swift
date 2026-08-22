import CryptoKit
import Foundation

/// What the cache holds: the bytes that were signed, plus the ETag they arrived with.
struct CachedEnvelope: Sendable {
    let raw: Data
    let etag: String?
}

/// Durable storage for the last envelope this device received.
///
/// The cache is a **correctness feature, not an optimisation** (Founding §8.4). It is what makes
/// "offline" and "our backend is down" indistinguishable from normal operation for the end user,
/// so it must survive app restarts, and every failure to read it must degrade rather than throw.
protocol EnvelopeCache: Sendable {
    func load() -> CachedEnvelope?
    func store(_ raw: Data, etag: String?)
    func clear()
}

/// File-backed cache under Application Support.
///
/// It stores **the signed envelope verbatim**, never the parsed values, and the caller re-verifies
/// the signature on load. That single decision is what makes the cache safe: poisoning it requires
/// forging an Ed25519 signature rather than editing a JSON file on a jailbroken device or in an
/// unencrypted backup. It also means the cache inherits every guarantee the transport has, for
/// free, and cannot drift from it.
struct FileEnvelopeCache: EnvelopeCache {
    private let directory: URL?
    private let log: Log

    private static let envelopeFile = "envelope.json"
    private static let etagFile = "etag.txt"

    /// A hostile or broken server must not be able to fill the user's disk. Real payloads are a
    /// few kilobytes; this is orders of magnitude of headroom and still bounded.
    static let maximumEnvelopeBytes = 1 << 20

    init(sdkKey: String, environment: Environment, log: Log) {
        self.log = log
        self.directory = Self.makeDirectory(sdkKey: sdkKey, environment: environment, log: log)
    }

    func load() -> CachedEnvelope? {
        guard let directory else { return nil }
        let envelopeURL = directory.appendingPathComponent(Self.envelopeFile)

        guard let raw = try? Data(contentsOf: envelopeURL) else { return nil }
        guard raw.count <= Self.maximumEnvelopeBytes else {
            // Something wrote a file we would never have written. Treat it as absent and remove
            // it: a truncated read would fail signature verification anyway, and leaving it in
            // place would mean retrying a doomed read on every launch.
            log.warning("cached envelope is implausibly large; discarding it")
            clear()
            return nil
        }

        let etag = try? String(contentsOf: directory.appendingPathComponent(Self.etagFile), encoding: .utf8)
        return CachedEnvelope(raw: raw, etag: etag)
    }

    func store(_ raw: Data, etag: String?) {
        guard let directory else { return }
        guard raw.count <= Self.maximumEnvelopeBytes else { return }

        do {
            let envelopeURL = directory.appendingPathComponent(Self.envelopeFile)
            try raw.write(to: envelopeURL, options: Self.writingOptions)
            let etagURL = directory.appendingPathComponent(Self.etagFile)
            if let etag, let data = etag.data(using: .utf8) {
                try data.write(to: etagURL, options: Self.writingOptions)
            } else {
                try? FileManager.default.removeItem(at: etagURL)
            }
        } catch {
            // A cache write failing is survivable — the in-memory values still serve this launch,
            // and the next launch falls back one further down the cascade. It is never a reason to
            // disturb the host app.
            log.error("could not write the flag cache: \(error.localizedDescription)")
        }
    }

    func clear() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.envelopeFile))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Self.etagFile))
    }

    // MARK: - Location

    /// `Application Support/com.fortressflag/<scope>/`.
    ///
    /// Scoped by a hash of the SDK key and environment so that two configurations in one app — a
    /// staging build and a production build sharing a container, or an app that reconfigures at
    /// runtime — cannot serve each other's values. The key is hashed rather than used directly so
    /// it never appears in a file path that ends up in a screenshot or a crash report.
    private static func makeDirectory(sdkKey: String, environment: Environment, log: Log) -> URL? {
        let manager = FileManager.default
        guard let base = try? manager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else {
            log.error("no Application Support directory; flag values will not survive a restart")
            return nil
        }

        var root = base.appendingPathComponent("com.fortressflag", isDirectory: true)
        let scope = scopeIdentifier(sdkKey: sdkKey, environment: environment)
        let directory = root.appendingPathComponent(scope, isDirectory: true)

        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log.error("could not create the flag cache directory: \(error.localizedDescription)")
            return nil
        }

        // Keep flag state out of the user's iCloud and iTunes backups. Two reasons, and the second
        // is the important one: it is data minimisation (Founding §7.3), and a backup restored onto
        // a *different* device would carry flag values that were evaluated for the old device.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)

        return directory
    }

    private static func scopeIdentifier(sdkKey: String, environment: Environment) -> String {
        let material = Data("\(sdkKey)|\(environment.rawValue)".utf8)
        let digest = SHA256.hash(data: material)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Atomic, and readable during a background launch but not while the device is locked
    /// pre-first-unlock.
    ///
    /// `completeUntilFirstUserAuthentication` rather than `complete`: the SDK has to resolve flags
    /// when the app is woken in the background, which can happen before the user has unlocked. A
    /// stricter class would make the cache unreadable exactly when the cascade is most needed and
    /// silently drop the device to `false`.
    private static var writingOptions: Data.WritingOptions {
        #if os(iOS) || os(visionOS) || os(tvOS) || os(watchOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        return [.atomic]
        #endif
    }
}
