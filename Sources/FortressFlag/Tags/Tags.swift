import Foundation

/// Device tags (contract v1, `X-FF-Tags`; backend ADR-0004): the values this device reports with
/// every fetch, which the server evaluates targeting rules against. Tags are **request-scoped on
/// the server by decision** — evaluated and forgotten, never persisted, never logged — but they
/// still transit, so the same rule applies here as everywhere else in this SDK: a tag VALUE may
/// carry anything the customer put in it and never appears in a log line. A tag KEY is the
/// customer's own configuration, loggable when it is well-formed.
enum Tags {
    /// The request header the merged tag set travels in.
    static let headerName = "X-FF-Tags"

    /// The caps, shared verbatim with the server (contract v1). The server answers 400 to a
    /// violation because the SDK enforces the same caps here first — a request over the caps
    /// means a broken client, so this file is what keeps that statement true.
    enum Limits {
        static let maxCount = 32
        static let maxKeyLength = 64
        static let maxValueLength = 256
        static let maxDocumentBytes = 4096
    }

    /// Whether `key` is within the contract's alphabet: 1–64 characters of
    /// `A–Z a–z 0–9 . _ -`. A byte scan rather than a regex — it is called per tag per change,
    /// and there is nothing a regex would make clearer.
    static func isValidKey(_ key: String) -> Bool {
        let bytes = Array(key.utf8)
        guard !bytes.isEmpty, bytes.count <= Limits.maxKeyLength else { return false }
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                continue
            default:
                return false
            }
        }
        return true
    }

    /// Validates customer-supplied tags, dropping what the contract cannot carry.
    ///
    /// Dropping, not throwing and not truncating: no SDK call throws (Founding §8.1), and a
    /// truncated value would silently match different rules than the one the customer set. Each
    /// drop logs a warning naming the KEY only — a key that itself failed the charset check is
    /// arbitrary text and is logged as a placeholder instead, exactly as the server does.
    ///
    /// `reserved` is the built-in tag names. A customer key colliding with one is dropped: the
    /// built-ins are mechanically derived truths about the device, and letting configuration
    /// overwrite "what version is this app?" would make every version rule lie.
    static func sanitize(
        _ custom: [String: String],
        reserved: Set<String>,
        log: Log
    ) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(custom.count)
        for (key, value) in custom {
            guard isValidKey(key) else {
                log.warning("dropping tag with a malformed key (1-64 chars of A-Za-z0-9._- required)")
                continue
            }
            guard !reserved.contains(key) else {
                log.warning("dropping tag '\(key)': it collides with a built-in tag the SDK sends itself")
                continue
            }
            guard value.utf8.count <= Limits.maxValueLength else {
                log.warning("dropping tag '\(key)': its value exceeds \(Limits.maxValueLength) bytes")
                continue
            }
            out[key] = value
        }
        return out
    }

    /// Merges built-ins over custom tags and encodes the result as the header value: unpadded
    /// base64url of a JSON object, **keys sorted**. Returns nil when there is nothing to send.
    ///
    /// Deterministic on purpose, and the reason is M3, not tidiness: the ETag design will make a
    /// byte-identical request cheap, and a map serialised in iteration order would produce a
    /// different header — and a different cache identity — on every launch for the same tags.
    ///
    /// When the merged set exceeds the count or document caps, CUSTOM tags are dropped from the
    /// end of the sorted order until it fits, each drop logged by key. Built-ins always survive:
    /// they are small, bounded, and the ones rules most depend on.
    static func encode(
        builtin: [String: String],
        custom: [String: String],
        log: Log
    ) -> String? {
        var kept = custom

        let overCount = builtin.count + kept.count - Limits.maxCount
        if overCount > 0 {
            for key in kept.keys.sorted().suffix(overCount) {
                log.warning("dropping tag '\(key)': more than \(Limits.maxCount) tags")
                kept.removeValue(forKey: key)
            }
        }

        while true {
            let merged = kept.merging(builtin) { _, builtinValue in builtinValue }
            guard !merged.isEmpty else { return nil }
            guard let document = serialize(merged) else {
                // JSON encoding of a [String: String] cannot realistically fail; if it somehow
                // does, sending no tags — and therefore serving defaults — is the safe answer.
                log.warning("could not encode tags; sending none")
                return nil
            }
            if document.count <= Limits.maxDocumentBytes {
                return Base64URL.encode(document)
            }
            // Over the document cap: shed the last custom tag (in sorted-key order) and try
            // again. Only custom tags are sheddable; built-ins plus the rest still evaluate.
            guard let last = kept.keys.max() else {
                log.warning("built-in tags alone exceed the document cap; sending none")
                return nil
            }
            log.warning(
                "dropping tag '\(last)': the encoded tag document exceeds \(Limits.maxDocumentBytes) bytes"
            )
            kept.removeValue(forKey: last)
        }
    }

    /// JSON with sorted keys. `JSONEncoder` guarantees the escaping; `.sortedKeys` guarantees the
    /// determinism the doc comment above promises.
    private static func serialize(_ tags: [String: String]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(tags)
    }
}

/// The tags the SDK sends automatically: mechanically derived facts about this installation,
/// none of them user-identifying, none read through required-reason APIs (the bundle's info
/// dictionary and `ProcessInfo.operatingSystemVersion` are both unrestricted, so
/// `PrivacyInfo.xcprivacy` is unchanged by this feature).
enum BuiltinTags {
    /// The reserved names. A customer tag with one of these keys is dropped — see
    /// `Tags.sanitize`.
    static let reservedKeys: Set<String> = [
        "appVersion", "appBuild", "osVersion", "platform", "sdkVersion",
    ]

    /// The live set, from the main bundle. A missing Info.plist value simply omits its tag; a
    /// rule on the absent key then never matches, which is the contract's absent-tag semantics
    /// doing exactly its job.
    static func current() -> [String: String] {
        collect(
            bundleInfo: Bundle.main.infoDictionary,
            osVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    /// The derivation, separated from its inputs so tests can drive it without a host app.
    static func collect(
        bundleInfo: [String: Any]?,
        osVersion: OperatingSystemVersion
    ) -> [String: String] {
        var tags: [String: String] = [
            "platform": SDKInfo.platform,
            "sdkVersion": SDKInfo.version,
            "osVersion": describe(osVersion),
        ]
        if let version = bundleInfo?["CFBundleShortVersionString"] as? String, !version.isEmpty {
            tags["appVersion"] = version
        }
        if let build = bundleInfo?["CFBundleVersion"] as? String, !build.isEmpty {
            tags["appBuild"] = build
        }
        return tags
    }

    /// "26.0.1", with a trailing ".0" patch omitted the way Apple's own version strings omit it.
    /// The server's semver comparison reads missing components as 0, so "26.0" == "26.0.0" and
    /// the shortening changes nothing about how rules match.
    private static func describe(_ version: OperatingSystemVersion) -> String {
        if version.patchVersion == 0 {
            return "\(version.majorVersion).\(version.minorVersion)"
        }
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
