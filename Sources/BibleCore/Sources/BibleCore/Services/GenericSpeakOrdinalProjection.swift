// GenericSpeakOrdinalProjection.swift -- Exact Android generic speech ordinal text

import Foundation

/**
 Projects Android BVA-marked generic content into exact local speech ordinals.

 EPUB content is transformed into one `<bva ordinal="...">` element per sentence. Android's
 `GeneralSpeakTextProvider` advances that ordinal independently from the document key, so callers
 must not flatten an entire page into one speech unit. This projection uses the shared structured
 XML parser and fails closed if the declared page range and markup disagree.
 */
public enum GenericSpeakOrdinalProjection {
    /**
     Extracts one visible text value for every ordinal in an EPUB page.

     - Parameters:
       - xhtml: Transformed EPUB XHTML containing BVA elements.
       - expectedRange: Inclusive ordinal range recorded with the page.
     - Returns: Exact ordinal-to-text values when every expected ordinal occurs once, otherwise
       `nil`.
     - Side effects: Parses the supplied XHTML in memory with external entities disabled.
     - Failure modes: Malformed XML, duplicate ordinals, missing ordinals, out-of-range anchors, or
       empty anchor text fail closed instead of speaking a flattened page under the wrong cursor.
     */
    public static func epubOrdinalTexts(
        xhtml: String,
        expectedRange: ClosedRange<Int>
    ) -> [Int: String]? {
        guard let data = xhtml.data(using: .utf8),
              let root = try? EpubXMLTreeParser.parse(data) else {
            return nil
        }

        var result: [Int: String] = [:]
        for element in root.descendants(includeSelf: true)
            where element.localName.caseInsensitiveCompare("bva") == .orderedSame {
            guard let rawOrdinal = element.attribute(localName: "ordinal"),
                  let ordinal = Int(rawOrdinal),
                  expectedRange.contains(ordinal),
                  result[ordinal] == nil else {
                return nil
            }
            let text = normalizedText(element.textContent())
            guard !text.isEmpty else { return nil }
            result[ordinal] = text
        }

        guard result.count == expectedRange.count,
              expectedRange.allSatisfy({ result[$0] != nil }) else {
            return nil
        }
        return result
    }

    /** Normalizes the newline and whitespace behavior used by Android generic speech commands. */
    private static func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
