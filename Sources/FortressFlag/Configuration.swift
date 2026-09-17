import Foundation

/// Which of the customer's environments this app build reads flags from.
///
/// A validated value type, not a free string — and no longer a closed enum. Since the backend's
/// custom-environments milestone (migration 0007) the set of environments is the customer's own
/// data: a tenant can create `qa` or `eu-live` in the dashboard, and this SDK must be able to
/// read it. What survives from the enum days is the misuse-resistance: "which environment am I?"
/// must never be arbitrary text, because on a product whose entire job is answering "is this on
/// in production?", a typo that silently reads the wrong environment is the worst failure mode
/// available. So construction is gated — the three seeded defaults are compile-time presets, and
/// anything else goes through `init?(key:)`, which enforces the same key format the server's
/// `environments_key_format` CHECK does (2–32 characters, lowercase letters, digits and hyphens,
/// starting and ending with a letter or digit) and returns `nil` rather than carrying rubbish.
///
/// The wire contract is unchanged: `environment` was always a string on the wire, and the
/// `rawValue` here is exactly what the enum's used to be for the three presets.
public struct Environment: RawRepresentable, Sendable, Hashable {
    /// The environment's key, exactly as it appears in the dashboard, the SDK key's prefix and
    /// the client API's `?environment=` parameter.
    public let rawValue: String

    /// The seeded default every tenant starts with, key `dev`.
    public static let development = Environment(unchecked: "dev")
    /// The seeded default with key `staging`.
    public static let staging = Environment(unchecked: "staging")
    /// The seeded default with key `prod`. Note that since custom environments, whether an
    /// environment is treated as production by the control plane is a property of the tenant's
    /// row (`is_production`), not of this name — the SDK does not care either way; it reads
    /// whatever environment its key is scoped to.
    public static let production = Environment(unchecked: "prod")

    /// Creates an environment from a key the customer defined in the dashboard, or `nil` when
    /// the string is not shaped like an environment key. `nil` rather than acceptance: a
    /// malformed key could never name an environment on any tenant, and carrying it forward
    /// would turn a compile-adjacent mistake into a runtime "flags silently never load".
    public init?(key: String) {
        guard Environment.isValidKey(key) else { return nil }
        self.rawValue = key
    }

    /// `RawRepresentable`, with the same validation as `init?(key:)`.
    public init?(rawValue: String) {
        self.init(key: rawValue)
    }

    /// For the compile-time presets above, whose keys are valid by inspection. Not public — the
    /// unvalidated path must not exist outside this file.
    private init(unchecked key: String) {
        self.rawValue = key
    }

    /// The server's `environments_key_format` shape, checked without a regex engine: this file
    /// must contain no crash primitives, and a hand-rolled scan over ASCII is easier to prove
    /// total than a pattern (Founding §8.1).
    private static func isValidKey(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard scalars.count >= 2, scalars.count <= 32 else { return false }

        func isLowerAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        guard let first = scalars.first, let last = scalars.last,
            isLowerAlphanumeric(first), isLowerAlphanumeric(last)
        else { return false }

        return scalars.allSatisfy { isLowerAlphanumeric($0) || $0 == "-" }
    }
}

/// How the SDK treats the signature on a flag payload.
///
/// The default is `required`. Rejecting an unverifiable payload is safe here in a way it is not
/// in most systems: rejection means "serve the last value this device saw", not "break the app"
/// (Founding §8.4). So there is no availability argument for verifying loosely.
public enum SignaturePolicy: Sendable {
    /// Reject any payload not signed by one of `trustedKeys`.
    case required(trustedKeys: TrustedKeys)

    /// Accept unsigned payloads. Intended for local development against a backend started
    /// without signing keys (`FF_SIGNING_*` unset), which serves envelopes with no `sig`. It is a
    /// named, greppable choice rather than a silent fallback so that "why is this not verifying?"
    /// always has an answer in the customer's own source.
    case disabled
}

/// Ed25519 public keys the SDK will accept payload signatures from, keyed by the key ID that
/// appears in the `sig` field of an envelope.
///
/// Keyed rather than a bare list so that rotation is a publish, not an app release: the backend
/// starts signing with `keyId` N+1 while SDKs in the wild already trust it.
public struct TrustedKeys: Sendable, Equatable {
    /// Raw 32-byte Ed25519 public keys by key ID.
    public let keysByID: [String: Data]

    public init(_ keysByID: [String: Data]) {
        self.keysByID = keysByID
    }

    /// The keys FortressFlag signs production payloads with (backend ADR-0025).
    ///
    /// Raw 32-byte Ed25519 public keys; the same values are published in the customer docs
    /// (`concepts/payload-signing`) and ADR-0025. Rotation adds key N+1 here one release before
    /// the backend switches to it (contract-v1 §Key rotation). Staging signs with a different key
    /// — a build that targets staging passes it explicitly. Never make this empty: `.required`
    /// with no keys rejects every payload.
    public static let fortressFlagProduction = TrustedKeys([
        // prod-2026-09-k1 (ADR-0025, minted 2026-09-16)
        // base64url EaEF8MHNu3onHxemTg3-OcrKrq7ODsZIVEp-IVV2ojg
        "prod-2026-09-k1": Data(
            // A PUBLIC key; the scanner's generic rule matches any 64-hex literal near "key".
            hexKey: "11a105f0c1cdbb7a271f17a64e0dfe39cacaaeaece0ec648544a7e215576a238"), // gitleaks:allow
    ])

    public var isEmpty: Bool { keysByID.isEmpty }
}

/// How much the SDK writes to the unified log.
public enum LogPolicy: Sendable {
    /// Errors and one-time configuration warnings only. The default.
    case standard
    /// Adds refresh lifecycle and resolution sources. Never enable in a shipping build: it names
    /// the customer's flag keys in the device log.
    case verbose
    /// Nothing at all.
    case silent
}

/// Everything the SDK needs to run.
///
/// Value type and `Sendable` so it can be handed across isolation boundaries without a copy the
/// caller can mutate underneath us.
public struct Configuration: Sendable {
    /// The client SDK key, of the form `ffc_<env>_<random>`.
    ///
    /// **This is not a secret.** It ships in every copy of the app and `strings` recovers it. It
    /// is read-only, scoped to one tenant and one environment, and revocable without an app
    /// release. Never put a management token here — the client API will not accept one.
    ///
    /// **It is rate-limited server-side on two dimensions**, so a customer reading this can
    /// predict the behaviour rather than discover it. The control plane counts requests **per
    /// device** — sized with headroom over ``minimumRefreshInterval``, so a client polling as
    /// fast as this SDK allows is never limited — and **per key**, as a much larger ceiling on
    /// the whole integration. The device dimension is what a misconfigured build trips; the key
    /// dimension is an abuse ceiling, and reaching it means something other than normal polling
    /// is happening.
    ///
    /// Either one answers **HTTP 429**, which this SDK treats as a transient failure: the fetch
    /// fails, ``FlagValue`` resolution continues from the durable cache (Founding §8.4), and the
    /// server's `Retry-After` feeds the backoff. Nothing is thrown to your app.
    public var sdkKey: String

    /// Which environment's values to read.
    public var environment: Environment

    /// The client API base URL. Defaults to FortressFlag's edge.
    public var baseURL: URL

    /// The shared keychain access group the device identity lives in, *without* the team prefix
    /// (the SDK resolves that at runtime). Pass the same value in every one of your apps.
    ///
    /// Leaving this `nil` works, but stores the identity per app — so one physical device with
    /// three of your apps counts as three billable devices instead of one. See the README.
    public var keychainAccessGroup: String?

    /// Custom tags to send with every flag fetch, fixed at start. The server evaluates targeting
    /// rules against them; change them at runtime with `FortressFlag.setTags(_:)`.
    ///
    /// Keys are 1–64 characters of `A–Z a–z 0–9 . _ -`; values at most 256 bytes; at most 32
    /// tags including the built-ins the SDK adds automatically (`appVersion`, `appBuild`,
    /// `osVersion`, `platform`, `sdkVersion` — those names are reserved). Entries outside the
    /// limits are dropped with a logged warning, never an error (Founding §8.1).
    ///
    /// **Tags transit on every request but are never stored by FortressFlag** — the server
    /// evaluates them statelessly and discards them. They still leave the device, so do not put
    /// anything in a tag you would not put in a request header: prefer stable, non-identifying
    /// values ("cohort": "beta"), and hash anything user-derived before it becomes a tag.
    public var tags: [String: String]

    /// How the SDK treats payload signatures. Defaults to `.required`.
    public var signaturePolicy: SignaturePolicy

    /// How often to poll for new values. Jitter of ±20% is applied so a fleet of devices does not
    /// synchronise into a thundering herd against a recovering backend.
    public var refreshInterval: Duration

    /// Per-request timeout. Short on purpose: a slow flag fetch must never become the app's
    /// problem, and a timeout costs nothing because the cache answers immediately.
    public var requestTimeout: Duration

    /// Permits a plaintext `http://` base URL for `localhost`/`127.0.0.1` only.
    ///
    /// Exists so the SDK can be developed against a local backend without teaching anyone to add
    /// an App Transport Security exception. Every request made under it logs a warning, and it
    /// still refuses any non-loopback host.
    public var allowsInsecureLocalTransport: Bool

    /// How much to log.
    public var logging: LogPolicy

    public init(
        sdkKey: String,
        environment: Environment,
        baseURL: URL = Configuration.defaultBaseURL,
        keychainAccessGroup: String? = nil,
        tags: [String: String] = [:],
        signaturePolicy: SignaturePolicy = .required(trustedKeys: .fortressFlagProduction),
        refreshInterval: Duration = .seconds(300),
        requestTimeout: Duration = .seconds(10),
        allowsInsecureLocalTransport: Bool = false,
        logging: LogPolicy = .standard
    ) {
        self.sdkKey = sdkKey
        self.environment = environment
        self.baseURL = baseURL
        self.keychainAccessGroup = keychainAccessGroup
        self.tags = tags
        self.signaturePolicy = signaturePolicy
        self.refreshInterval = refreshInterval
        self.requestTimeout = requestTimeout
        self.allowsInsecureLocalTransport = allowsInsecureLocalTransport
        self.logging = logging
    }

    /// FortressFlag's client API edge.
    public static let defaultBaseURL: URL = {
        // Built from components rather than a force-unwrapped string literal: this file must
        // contain no crash primitives, including ones a reviewer would wave through as obviously
        // safe (Founding §8.1).
        var components = URLComponents()
        components.scheme = "https"
        components.host = "edge.fortressflag.com"
        return components.url ?? URL(fileURLWithPath: "/")
    }()
}

// MARK: - Validation

/// A problem with a `Configuration`, reported rather than thrown.
public enum ConfigurationProblem: Sendable, Equatable, CustomStringConvertible {
    case emptySDKKey
    case sdkKeyWrongFormat
    case sdkKeyEnvironmentMismatch(keyEnvironment: String, configured: String)
    case insecureBaseURL
    case insecureTransportOnNonLoopbackHost(host: String)
    case signatureRequiredButNoTrustedKeys
    case refreshIntervalTooShort(minimum: Duration)

    public var description: String {
        switch self {
        case .emptySDKKey:
            return "sdkKey is empty."
        case .sdkKeyWrongFormat:
            return "sdkKey is not of the form ffc_<env>_<random>."
        case let .sdkKeyEnvironmentMismatch(keyEnvironment, configured):
            return """
                sdkKey is scoped to environment '\(keyEnvironment)' but the configuration asks for \
                '\(configured)'. The server will reject this; fix the key or the environment.
                """
        case .insecureBaseURL:
            return "baseURL must use https (or set allowsInsecureLocalTransport for localhost)."
        case let .insecureTransportOnNonLoopbackHost(host):
            return "allowsInsecureLocalTransport applies to loopback only, not '\(host)'."
        case .signatureRequiredButNoTrustedKeys:
            return """
                signaturePolicy is .required but no trusted keys were supplied, so every payload \
                will be rejected. Supply keys, or choose .disabled explicitly for local development.
                """
        case let .refreshIntervalTooShort(minimum):
            // A statement of fact, not a warning about a hypothetical: the control plane counts
            // per device and answers 429. Naming the status is what lets someone reading a log
            // line connect it to this message.
            return """
                refreshInterval is below the \(minimum) minimum. The control plane rate-limits \
                per device and will answer HTTP 429; the SDK keeps serving cached values, so the \
                effect is stale flags rather than an error.
                """
        }
    }
}

extension Configuration {
    /// The shortest polling interval the SDK will honour. Anything faster is the caller
    /// volunteering to be rate-limited, and costs the customer money for values that did not
    /// change (Founding §6).
    ///
    /// The server's per-device limit is sized with headroom over this number, so honouring it is
    /// sufficient — a client polling at exactly this interval is never limited.
    public static let minimumRefreshInterval: Duration = .seconds(30)

    /// Everything wrong with this configuration.
    ///
    /// Returned rather than thrown, and public, so that a customer can assert on it in their own
    /// test suite and find a mistake at build time instead of discovering at runtime that flags
    /// silently never load. `FortressFlag.start` calls this and logs, but never fails the app.
    public func validate() -> [ConfigurationProblem] {
        var problems: [ConfigurationProblem] = []

        if sdkKey.isEmpty {
            problems.append(.emptySDKKey)
        } else {
            let parts = sdkKey.split(separator: "_", omittingEmptySubsequences: false)
            if parts.count != 3 || parts[0] != "ffc" || parts[1].isEmpty || parts[2].isEmpty {
                problems.append(.sdkKeyWrongFormat)
            } else if parts[1] != environment.rawValue {
                problems.append(
                    .sdkKeyEnvironmentMismatch(
                        keyEnvironment: String(parts[1]),
                        configured: environment.rawValue
                    )
                )
            }
        }

        let scheme = baseURL.scheme?.lowercased()
        if scheme != "https" {
            if allowsInsecureLocalTransport, scheme == "http" {
                let host = baseURL.host ?? ""
                if !Configuration.loopbackHosts.contains(host) {
                    problems.append(.insecureTransportOnNonLoopbackHost(host: host))
                }
            } else {
                problems.append(.insecureBaseURL)
            }
        }

        if case let .required(keys) = signaturePolicy, keys.isEmpty {
            problems.append(.signatureRequiredButNoTrustedKeys)
        }

        if refreshInterval < Configuration.minimumRefreshInterval {
            problems.append(.refreshIntervalTooShort(minimum: Configuration.minimumRefreshInterval))
        }

        return problems
    }

    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
}
