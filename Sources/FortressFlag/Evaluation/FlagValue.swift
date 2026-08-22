import Foundation

/// A flag's value: the contract-v2 union (ADR-0008 in the backend repo).
///
/// A flag has an immutable KIND — boolean, string or number — and every value it ever serves is
/// a bare scalar of that kind. There are deliberately no objects or arrays: evaluated payloads
/// are readable by anyone holding the customer's binary, and structured payloads would force a
/// schema conversation between app versions that a flag should never require.
///
/// Under contract v1 every value was a boolean; a v1 payload decodes into `.bool` cases, which
/// is what lets a pre-v2 cache file load unchanged after an SDK upgrade.
public enum FlagValue: Sendable, Equatable {
    case bool(Bool)
    case string(String)
    case number(Double)

    /// The boolean, or nil when this value is not a boolean. `isEnabled` uses this to keep its
    /// exact pre-v2 behaviour: a non-boolean value resolves to the caller's default, never a
    /// coercion and never an error (Founding §8.1).
    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    /// Numbers are float64 on the wire, exactly as the server serves them.
    public var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }
}

extension FlagValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Order matters only for clarity — the three JSON scalar shapes are disjoint. Anything
        // else (null, object, array) is a decode failure, which the verifier reports as a
        // malformed payload: fail closed to the cache, never guess at a shape (Founding §8.3).
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "flag values are JSON booleans, strings or numbers"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .bool(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        }
    }
}

/// Literal conformances, so a boolean-only call site reads exactly as it did before the union
/// existed — `["dark-mode": true]` — and fixtures can write values as plain literals.
extension FlagValue: ExpressibleByBooleanLiteral, ExpressibleByStringLiteral,
    ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}
