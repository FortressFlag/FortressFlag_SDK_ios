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

extension Data {
    /// Decodes a hex literal into bytes, for the trusted-key constants. Malformed input yields
    /// empty `Data`, which the verifier treats as `unknownKeyID` — never a trap in shipped code.
    init(hexKey: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexKey.count / 2)
        var index = hexKey.startIndex
        while index < hexKey.endIndex {
            guard let next = hexKey.index(index, offsetBy: 2, limitedBy: hexKey.endIndex),
                  let byte = UInt8(hexKey[index..<next], radix: 16)
            else {
                self.init()
                return
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
