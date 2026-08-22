import Testing
@testable import FortressFlag

/// The cascade is the most consequential logic in the SDK, so it is tested as a truth table over
/// every combination of the four inputs rather than with a handful of illustrative cases.
@Suite("Fallback cascade (Founding §8.4)")
struct ResolverTests {
    @Test("fresh wins over everything")
    func freshWins() {
        let result = Resolver.resolve(
            key: "a", fresh: ["a": true], cached: ["a": false], developerDefault: false
        )
        #expect(result == Resolution(value: true, source: .fresh))
    }

    @Test("a cached value beats a developer default, however old it is")
    func cacheBeatsDefault() {
        // The rule most likely to be "simplified" by a future contributor into something that
        // looks more intuitive. It is not a preference: the server is the authority on a flag's
        // state, and the default only answers "what if this device has never heard anything?".
        let result = Resolver.resolve(
            key: "a", fresh: nil, cached: ["a": false], developerDefault: true
        )
        #expect(result == Resolution(value: false, source: .cached))
    }

    @Test("the developer default answers only when nothing was ever recorded")
    func developerDefault() {
        let result = Resolver.resolve(key: "a", fresh: nil, cached: nil, developerDefault: true)
        #expect(result == Resolution(value: true, source: .developerDefault))
    }

    @Test("an unknown flag with no default is off")
    func safeDefault() {
        let result = Resolver.resolve(key: "a", fresh: nil, cached: nil, developerDefault: nil)
        #expect(result == Resolution(value: false, source: .safeDefault))
    }

    // MARK: - resolveAll

    @Test("resolveAll enumerates the union of fresh and cached keys")
    func resolveAllUnion() {
        let all = Resolver.resolveAll(
            fresh: ["a": true, "b": false],
            cached: ["b": true, "c": true]
        )
        #expect(all.keys.sorted() == ["a", "b", "c"])
    }

    @Test("resolveAll agrees with resolve for every key it returns")
    func resolveAllAgreesWithResolve() {
        let fresh: [String: FlagValue]? = ["a": true, "b": false]
        let cached: [String: FlagValue]? = ["b": true, "c": true]

        let all = Resolver.resolveAll(fresh: fresh, cached: cached)

        for (key, resolution) in all {
            let single = Resolver.resolve(
                key: key, fresh: fresh, cached: cached, developerDefault: nil
            )
            #expect(resolution == single, "enumeration drifted from single-key reads for '\(key)'")
        }
        #expect(all["a"] == Resolution(value: true, source: .fresh))
        #expect(all["b"] == Resolution(value: false, source: .fresh))
        #expect(all["c"] == Resolution(value: true, source: .cached))
    }

    @Test("resolveAll with nothing recorded is empty, not a dictionary of defaults")
    func resolveAllEmpty() {
        #expect(Resolver.resolveAll(fresh: nil, cached: nil).isEmpty)
        #expect(Resolver.resolveAll(fresh: [:], cached: [:]).isEmpty)
    }

    @Test("a key absent from a present payload falls through to the cache, not to false")
    func absentKeyFallsThrough() {
        // A flag missing from a payload means the server did not mention it. The server says "off"
        // by sending false — treating silence as off would flip every flag the moment a payload
        // was trimmed.
        let result = Resolver.resolve(
            key: "a", fresh: ["b": true], cached: ["a": true], developerDefault: nil
        )
        #expect(result == Resolution(value: true, source: .cached))
    }

    @Test("empty payloads are not the same as missing payloads")
    func emptyPayload() {
        let result = Resolver.resolve(key: "a", fresh: [:], cached: [:], developerDefault: nil)
        #expect(result == Resolution(value: false, source: .safeDefault))
    }

    /// Exhaustive truth table. Each input is either absent, present-true or present-false.
    @Test(
        "every combination of the four inputs resolves as specified",
        arguments: [
            // fresh, cached, default, expected value, expected source
            (nil as Bool?, nil as Bool?, nil as Bool?, false, ValueSource.safeDefault),
            (nil, nil, true, true, .developerDefault),
            (nil, nil, false, false, .developerDefault),
            (nil, true, nil, true, .cached),
            (nil, true, false, true, .cached),
            (nil, false, true, false, .cached),
            (true, nil, nil, true, .fresh),
            (true, false, false, true, .fresh),
            (false, true, true, false, .fresh),
        ]
    )
    func truthTable(
        fresh: Bool?, cached: Bool?, developerDefault: Bool?, expected: Bool, source: ValueSource
    ) {
        let result = Resolver.resolve(
            key: "k",
            fresh: fresh.map { ["k": .bool($0)] },
            cached: cached.map { ["k": .bool($0)] },
            developerDefault: developerDefault.map(FlagValue.bool)
        )
        #expect(result.value == FlagValue.bool(expected))
        #expect(result.source == source)
    }

    @Test("changed keys are computed on effective value, not payload membership")
    func changedKeys() {
        // "b" leaves the payload but the cache still says true, so its effective value is
        // unchanged and it must not be reported as a change.
        let changed = Resolver.changedKeys(
            from: ["a": false, "b": true],
            to: ["a": true],
            cached: ["b": true]
        )
        #expect(changed == ["a"])
    }

    @Test("no changes reported when nothing moved")
    func noChanges() {
        let changed = Resolver.changedKeys(from: ["a": true], to: ["a": true], cached: nil)
        #expect(changed.isEmpty)
    }

    @Test("a key dropping out with no cache behind it is a change")
    func droppedKeyIsAChange() {
        let changed = Resolver.changedKeys(from: ["a": true], to: [:], cached: nil)
        #expect(changed == ["a"])
    }
}
