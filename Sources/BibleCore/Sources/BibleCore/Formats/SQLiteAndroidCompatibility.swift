// SQLiteAndroidCompatibility.swift -- Shared Android SQLite identity and XML contracts

import Foundation
import SwordKit

/**
 Hashable installed-module identity using Java's UTF-16 `String.equalsIgnoreCase` contract.

 Android requires equal UTF-16 lengths and compares each Java `char` without canonical
 normalization, multi-character expansion, or surrogate-pair case mapping. This public wrapper
 preserves BibleCore's installed-module API while delegating the actual identity to SwordKit's one
 Android 37 ICU-backed contract shared with native SWORD and TagSoup.
 */
public struct SQLiteDocumentIdentity: Hashable, Sendable {
    /// Shared Android 37 per-`char` identity used by native and SQLite registries.
    private let androidIdentity: SwordJavaStringIdentity

    /**
     Creates Android's case-insensitive identity for one exact initials string.

     - Parameter initials: Exact installed-module initials.
     - Side effects: None.
     - Failure modes: A missing bundled Android ICU oracle is a package-integrity failure and traps
       instead of silently changing module identity.
     */
    public init(_ initials: String) {
        androidIdentity = SwordJavaStringIdentity(initials)
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
