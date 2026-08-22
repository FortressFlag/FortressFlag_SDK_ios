import Foundation

/// Unpadded base64url (RFC 4648 §5), the encoding used for device IDs and for every field of the
/// signed envelope.
///
/// Unpadded because these values appear in HTTP headers and URLs, where `=` needs escaping and
/// gets mangled by well-meaning intermediaries. Hand-rolled rather than pulled from a dependency:
/// it is fifteen lines and this package takes no dependencies (Founding §8.1).
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes, or returns nil. Never throws, never traps on malformed input — this parses bytes
    /// that arrived over a network from a party we do not trust yet.
    static func decode(_ string: String) -> Data? {
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Restore the padding base64EncodedString stripped. A length of 1 mod 4 is not a valid
        // base64 encoding of any byte string, so reject rather than pad it into something.
        switch standard.count % 4 {
        case 0: break
        case 2: standard += "=="
        case 3: standard += "="
        default: return nil
        }

        return Data(base64Encoded: standard)
    }
}
