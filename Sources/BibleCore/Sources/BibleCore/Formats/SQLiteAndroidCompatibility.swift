// SQLiteAndroidCompatibility.swift -- Shared Android SQLite identity and XML contracts

import Foundation

/**
 Hashable installed-module identity using Java's UTF-16 `String.equalsIgnoreCase` contract.

 Android requires equal UTF-16 lengths, compares BMP characters without canonical normalization or
 multi-character expansion, and combines valid surrogate pairs before applying simple case mapping.
 The folded code points and original UTF-16 length therefore form one stable dictionary key while
 keeping canonically distinct spellings, such as composed and decomposed accents, separate.
 */
public struct SQLiteDocumentIdentity: Hashable, Sendable {
    /// Pinned Java-oracle lowercase table already shipped for Lucene-compatible analysis.
    private static let javaLowercaseTable: Lucene29CharacterTables = {
        do {
            return try Lucene29CharacterTables.loaded()
        } catch {
            preconditionFailure("Missing pinned OpenJDK character tables: \(error)")
        }
    }()

    /**
     Lowercase characters whose OpenJDK 17 uppercase form lowers to a different representative.

     This is the complete BMP delta between `Character.toLowerCase(char)` and Java's
     `Character.toLowerCase(Character.toUpperCase(char))`, generated from Eclipse Temurin 17.0.19.
     Keeping the aliases explicit prevents the host OS Unicode version from changing identity.
     */
    private static let javaUppercaseAliasFold: [UInt16: UInt16] = [
        0x00B5: 0x03BC,
        0x0131: 0x0069,
        0x017F: 0x0073,
        0x0345: 0x03B9,
        0x03C2: 0x03C3,
        0x03D0: 0x03B2,
        0x03D1: 0x03B8,
        0x03D5: 0x03C6,
        0x03D6: 0x03C0,
        0x03F0: 0x03BA,
        0x03F1: 0x03C1,
        0x03F5: 0x03B5,
        0x1C80: 0x0432,
        0x1C81: 0x0434,
        0x1C82: 0x043E,
        0x1C83: 0x0441,
        0x1C84: 0x0442,
        0x1C85: 0x0442,
        0x1C86: 0x044A,
        0x1C87: 0x0463,
        0x1C88: 0xA64B,
        0x1E9B: 0x1E61,
        0x1FBE: 0x03B9,
    ]

    /**
     OpenJDK 17 supplementary uppercase ranges and their lowercase deltas.

     The ranges come from the JDK 17 `UnicodeData.txt` oracle used to generate `CharacterData01`.
     They cover Deseret, Osage, Old Hungarian, Warang Citi, Medefaidrin, and Adlam. Lowercase code
     points already equal their lowercase-of-uppercase representative and need no table entry.
     */
    private static let supplementaryLowercaseRanges: [(ClosedRange<UInt32>, UInt32)] = [
        (0x10400...0x10427, 0x28),
        (0x104B0...0x104D3, 0x28),
        (0x10C80...0x10CB2, 0x40),
        (0x118A0...0x118BF, 0x20),
        (0x16E40...0x16E5F, 0x20),
        (0x1E900...0x1E921, 0x22),
    ]

    /// Original Java `String.length` retained because equalsIgnoreCase rejects unequal UTF-16 sizes.
    private let utf16Count: Int

    /// Non-expanding lowercase-of-uppercase representative for every source Unicode code point.
    private let foldedCodePoints: [UInt32]

    /**
     Creates Android's case-insensitive identity for one exact initials string.

     - Parameter initials: Exact installed-module initials.
     - Side effects: None.
     - Failure modes: A missing bundled OpenJDK oracle is a package-integrity failure and traps
       instead of silently changing module identity.
     */
    public init(_ initials: String) {
        utf16Count = initials.utf16.count
        foldedCodePoints = initials.unicodeScalars.map {
            Self.javaEqualsIgnoreCaseFold($0.value)
        }
    }

    /** Applies Android's historical MyBible/MySword `[^a-zA-z0-9]` replacement. */
    static func sanitizedModuleName(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            let code = scalar.value
            let accepted = (48...57).contains(code) || (65...122).contains(code)
            return accepted ? String(scalar) : "_"
        }.joined()
    }

    /** Applies e-Sword's exact Android `[^A-Za-z0-9]` replacement. */
    static func sanitizedESwordModuleName(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            let code = scalar.value
            let accepted = (48...57).contains(code)
                || (65...90).contains(code)
                || (97...122).contains(code)
            return accepted ? String(scalar) : "_"
        }.joined()
    }

    /** Returns OpenJDK 17's non-expanding lowercase-of-uppercase code-point representative. */
    private static func javaEqualsIgnoreCaseFold(_ codePoint: UInt32) -> UInt32 {
        if codePoint <= UInt32(UInt16.max) {
            let unit = UInt16(codePoint)
            return UInt32(javaUppercaseAliasFold[unit] ?? javaLowercaseTable.lowercase(unit))
        }
        for (range, delta) in supplementaryLowercaseRanges where range.contains(codePoint) {
            return codePoint + delta
        }
        return codePoint
    }
}

/** XML 1.0 text and fragment projection shared by every SQLite-backed reader. */
public enum SQLiteDocumentXMLCompatibility {
    /**
     Escapes one untrusted text value after replacing XML 1.0-forbidden scalars.

     - Parameter value: Plain source text that must not create markup.
     - Returns: XML-safe character data with five predefined entities escaped.
     - Side effects: None.
     - Failure modes: None; scalars outside XML 1.0's legal ranges become U+FFFD.
     */
    public static func escapedText(_ value: String) -> String {
        sanitizedXML10(value)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /**
     Retains a well-formed XML fragment or falls back to escaped visible source text.

     - Parameter value: Untrusted module-provided markup or plain text.
     - Returns: A sanitized well-formed fragment, or escaped text when parsing fails.
     - Side effects: Parses one in-memory wrapper document with external entities disabled.
     - Failure modes: Parser failures are contained by the escaped-text fallback.
     */
    public static func validatedFragmentOrEscapedText(_ value: String) -> String {
        let sanitized = sanitizedXML10(value)
        let parser = XMLParser(data: Data("<sqlite-fragment>\(sanitized)</sqlite-fragment>".utf8))
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? sanitized : escapedText(sanitized)
    }

    /**
     Derives Android's dictionary chooser snippet from one SQLite definition fragment.

     - Parameters:
       - fragment: Source dictionary markup returned by a validated SQLite reader.
       - key: Exact source key used by Android's prefix cleanup.
     - Returns: Orthography or bounded visible text, an empty string for no text, or nil when the
       fragment is not well-formed XML after XML 1.0 sanitization.
     - Side effects: Parses one in-memory wrapper with external entities disabled.
     - Failure modes: Malformed fragments return nil so callers can retain a key-only row.
     */
    public static func dictionarySnippet(fragment: String, key: String) -> String? {
        let sanitized = sanitizedXML10(fragment)
        let delegate = SQLiteDictionarySnippetParser()
        let parser = XMLParser(data: Data("<sqlite-dictionary>\(sanitized)</sqlite-dictionary>".utf8))
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        guard parser.parse() else { return nil }
        return delegate.snippet(key: key)
    }

    /** Replaces every scalar outside XML 1.0's legal character ranges with U+FFFD. */
    private static func sanitizedXML10(_ value: String) -> String {
        var sanitized = ""
        sanitized.reserveCapacity(value.utf8.count)

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D,
                 0x20...0xD7FF,
                 0xE000...0xFFFD,
                 0x10000...0x10FFFF:
                sanitized.unicodeScalars.append(scalar)
            default:
                sanitized.unicodeScalars.append("\u{FFFD}")
            }
        }

        return sanitized
    }
}

/** Collects the subset of OSIS text Android's dictionary chooser projects. */
private final class SQLiteDictionarySnippetParser: NSObject, XMLParserDelegate {
    /// Current wrapper-relative element depth.
    private var depth = 0

    /// Depth of Android's first direct title child currently excluded from fallback text.
    private var ignoredTitleDepth: Int?

    /// Whether Android's single direct-child `removeChild("title")` operation has been applied.
    private var removedDirectTitle = false

    /// Depth of the first entryFree element, when present.
    private var entryDepth: Int?

    /// Whether a complete entryFree element was observed.
    private var sawEntry = false

    /// Depth of a direct orth child currently being collected.
    private var orthDepth: Int?

    /// Visible source text outside excluded title elements.
    private var fallbackText = ""

    /// Visible text inside the first entryFree element.
    private var entryText = ""

    /// Current direct orth child text.
    private var currentOrthography = ""

    /// Nonempty orthography values in source order.
    private var orthographies: [String] = []

    /** Records relevant structural element boundaries. */
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        let hasNoNamespace = namespaceURI?.isEmpty ?? true
        if depth == 2,
           elementName == "title",
           hasNoNamespace,
           !removedDirectTitle {
            ignoredTitleDepth = depth
            removedDirectTitle = true
        }
        if depth == 2,
           elementName == "entryFree",
           hasNoNamespace,
           entryDepth == nil,
           !sawEntry {
            entryDepth = depth
        } else if elementName == "orth",
                  hasNoNamespace,
                  let entryDepth,
                  depth == entryDepth + 1 {
            orthDepth = depth
            currentOrthography = ""
        }
    }

    /** Appends semantic character data to the active Android projections. */
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if orthDepth != nil {
            currentOrthography += string
        }
        if entryDepth != nil {
            entryText += string
        }
        if ignoredTitleDepth == nil {
            fallbackText += string
        }
    }

    /** Closes title, orthography, and entryFree collection scopes. */
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if orthDepth == depth {
            if !currentOrthography.isEmpty {
                orthographies.append(currentOrthography)
            }
            orthDepth = nil
            currentOrthography = ""
        }
        if entryDepth == depth {
            entryDepth = nil
            sawEntry = true
        }
        if ignoredTitleDepth == depth {
            ignoredTitleDepth = nil
        }
        depth -= 1
    }

    /** Returns Android's orthography-first or cleaned bounded text snippet. */
    func snippet(key: String) -> String {
        if sawEntry, !orthographies.isEmpty {
            return orthographies.joined(separator: " - ")
        }
        return Self.cleanedSnippet(sawEntry ? entryText : fallbackText, key: key)
    }

    /** Mirrors `ChooseDictionaryWord.KeyInfo.cleanUpSnippet` including its trailing-space behavior. */
    private static func cleanedSnippet(_ source: String, key: String) -> String {
        var text = source.replacingOccurrences(of: "\n", with: " ")
        let textCodeUnits = Array(text.utf16)
        let keyCodeUnits = Array(key.utf16)
        if textCodeUnits.starts(with: keyCodeUnits) {
            text = String(decoding: textCodeUnits.dropFirst(keyCodeUnits.count), as: UTF16.self)
        }

        var words = text.components(separatedBy: " ")
        var result = ""
        while result.utf16.count < 50, !words.isEmpty {
            result += words.removeFirst() + " "
        }
        return result + (words.isEmpty ? "" : "...")
    }
}
