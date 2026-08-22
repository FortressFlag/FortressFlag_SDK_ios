import Foundation

/// Where a resolved value came from. Reported so a developer can tell "on because the server said
/// so" from "on because that is what this device last heard" — a distinction that matters a great
/// deal when debugging a rollout.
public enum ValueSource: Sendable, Equatable {
    /// From the most recent successful fetch.
    case fresh
    /// From the durable cache: the last value this device actually saw.
    case cached
    /// The `default:` the caller passed.
    case developerDefault
    /// `false`. Nothing has ever been recorded for this flag on this device.
    case safeDefault
}

/// A resolved flag value and its provenance.
///
/// `value` carries the contract-v2 union: `.bool` for boolean flags (every flag, before
/// multivariate kinds existed), `.string`/`.number` for the rest. `isEnabled`, `stringValue`
/// and `numberValue` each project their own kind out of it, fail-safe.
public struct Resolution: Sendable, Equatable {
    public let value: FlagValue
    public let source: ValueSource
}

/// The fallback cascade (Founding CLAUDE.md §8.4).
///
/// Deliberately pure — no I/O, no clock, no state. This is the most consequential logic in the
/// SDK and it is the piece most likely to be got subtly wrong, so it is written to be exhaustively
/// table-testable in isolation.
///
/// The order that is easy to get wrong: **a developer-supplied default substitutes for `false`
/// only.** A value this device actually received always beats a compiled-in guess, even if that
/// value is weeks old and the device has been offline since. The founding document is explicit
/// about this and the reason is that the server is the authority on a flag's state; the default
/// only answers "what if this device has never heard anything at all?".
///
/// Note also that, *within this function*, a present fresh payload with the key absent falls
/// through to the cache tier. Do not design against that as a grace period: in the shipped SDK it
/// never happens across polls, because `FlagClient` mirrors every accepted payload into both
/// tiers, so a key that leaves the payload leaves the cache on the same poll and resolves to the
/// developer default, else `false`. That is deliberate — it is what makes archiving a flag turn
/// the feature off on every device within one poll (ADR-0003 in `FortressFlag_Backend/docs/adr/`
/// examined and kept it). The fall-through matters only inside a single resolution, where the two
/// tiers may briefly differ during `changedKeys`' before/after comparison.
enum Resolver {
    static func resolve(
        key: String,
        fresh: [String: FlagValue]?,
        cached: [String: FlagValue]?,
        developerDefault: FlagValue?
    ) -> Resolution {
        if let value = fresh?[key] {
            return Resolution(value: value, source: .fresh)
        }
        if let value = cached?[key] {
            return Resolution(value: value, source: .cached)
        }
        if let developerDefault {
            return Resolution(value: developerDefault, source: .developerDefault)
        }
        return Resolution(value: .bool(false), source: .safeDefault)
    }

    /// Effective values for every key this device knows about — the union of the fresh and cached
    /// key sets, each resolved through `resolve` so enumeration cannot drift from single-key
    /// reads. No developer default participates: enumeration reports what the device *has*, and a
    /// compiled-in default is not something the device has.
    static func resolveAll(
        fresh: [String: FlagValue]?,
        cached: [String: FlagValue]?
    ) -> [String: Resolution] {
        var keys = Set(fresh?.keys ?? [:].keys)
        keys.formUnion(cached?.keys ?? [:].keys)

        var resolutions = [String: Resolution](minimumCapacity: keys.count)
        for key in keys {
            resolutions[key] = resolve(key: key, fresh: fresh, cached: cached, developerDefault: nil)
        }
        return resolutions
    }

    /// Keys whose effective value differs between two payload states, for change notification.
    ///
    /// Computed over the union of both key sets so that a flag *disappearing* from a payload is
    /// evaluated too: it falls back down the cascade, which may well change its effective value.
    static func changedKeys(
        from oldFresh: [String: FlagValue]?,
        to newFresh: [String: FlagValue]?,
        cached: [String: FlagValue]?
    ) -> Set<String> {
        var keys = Set(oldFresh?.keys ?? [:].keys)
        keys.formUnion(newFresh?.keys ?? [:].keys)

        return keys.filter { key in
            let before = resolve(key: key, fresh: oldFresh, cached: cached, developerDefault: nil)
            let after = resolve(key: key, fresh: newFresh, cached: cached, developerDefault: nil)
            return before.value != after.value
        }
    }
}
