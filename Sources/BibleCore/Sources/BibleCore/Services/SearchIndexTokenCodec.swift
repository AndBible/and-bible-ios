// SearchIndexTokenCodec.swift - lossless analyzer-token storage for SQLite FTS5

import Foundation

/**
 Encodes complete Lucene analyzer tokens into one FTS5-safe ASCII token each.

 SQLite's built-in tokenizers must still parse the `search_text` column and `MATCH` operands. Raw
 analyzer output cannot be passed through that boundary because punctuation can be split and Unicode
 can be folded a second time. Prefixing lowercase UTF-8 hex with `x` makes every encoded value one
 ASCII token, remains reversible, and preserves byte prefixes for Lucene suffix-wildcard queries.

 The codec is deterministic and stateless. It performs no filesystem or database I/O. Invalid encoded
 values fail closed during decoding; production search only emits values through `encode(_:)`.
 */
enum SearchIndexTokenCodec {
    /// Durable representation identifier recorded through the generated Search schema version.
    static let identifier = "utf8-hex-v1"

    /**
     Encodes one complete analyzer token without changing its bytes or token boundary.

     - Parameter token: Non-empty Lucene analyzer token or lowercased prefix operand.
     - Returns: One lowercase ASCII-alphanumeric token beginning with `x`.
     - Side effects: None.
     - Failure modes: Empty input produces `x`; callers reject empty analyzer operands earlier.
     - Complexity: O(n) in the token's UTF-8 byte count.
     */
    static func encode(_ token: String) -> String {
        var encoded = "x"
        encoded.reserveCapacity(1 + token.utf8.count * 2)
        for byte in token.utf8 {
            encoded.append(hexDigits[Int(byte >> 4)])
            encoded.append(hexDigits[Int(byte & 0x0F)])
        }
        return encoded
    }

    /**
     Serializes ordered analyzer tokens for the FTS5 `search_text` column.

     - Parameter tokens: Complete ordered token stream produced by the selected Lucene analyzer.
     - Returns: Space-delimited opaque tokens; FTS5 sees exactly one token per input element.
     - Side effects: None.
     - Failure modes: An empty stream returns an empty string for existing empty-verse handling.
     - Complexity: O(n) in the total UTF-8 byte count.
     */
    static func encodedText(_ tokens: [String]) -> String {
        tokens.map(encode).joined(separator: " ")
    }

    /**
     Reverses one encoded token for contract tests and diagnostics.

     - Parameter encoded: Value previously returned by `encode(_:)`.
     - Returns: Original token, or `nil` for a missing marker, odd hex length, invalid digit, or invalid
       UTF-8 sequence.
     - Side effects: None.
     - Failure modes: Malformed external values return `nil` and are never partially decoded.
     - Complexity: O(n) in the encoded byte count.
     */
    static func decode(_ encoded: String) -> String? {
        guard encoded.first == "x" else { return nil }
        let digits = encoded.dropFirst()
        guard digits.count.isMultiple(of: 2) else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(after: index)
            let end = digits.index(after: next)
            guard let high = hexValue(digits[index]),
                  let low = hexValue(digits[next]) else {
                return nil
            }
            bytes.append((high << 4) | low)
            index = end
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Lowercase alphabet keeps SQLite's ASCII case folding idempotent.
    private static let hexDigits = Array("0123456789abcdef")

    /** Converts one lowercase or uppercase ASCII hexadecimal digit into its nibble value. */
    private static func hexValue(_ character: Character) -> UInt8? {
        switch character {
        case "0"..."9": return UInt8(character.asciiValue! - Character("0").asciiValue!)
        case "a"..."f": return UInt8(character.asciiValue! - Character("a").asciiValue! + 10)
        case "A"..."F": return UInt8(character.asciiValue! - Character("A").asciiValue! + 10)
        default: return nil
        }
    }
}
