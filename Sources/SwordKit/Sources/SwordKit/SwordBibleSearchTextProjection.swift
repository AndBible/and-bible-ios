// SwordBibleSearchTextProjection.swift -- Android-parity Bible search text projection

import Foundation

/** One structured lemma attribute mapped to its visible Search preview UTF-16 range. */
public struct SwordBibleSearchLemmaSpan: Equatable, Sendable {
    /// Exact source lemma attribute, potentially containing multiple space-delimited values.
    public let lemma: String

    /// Zero-based UTF-16 offset in `SwordBibleSearchTextProjection.previewText`.
    public let location: Int

    /// Positive UTF-16 length of the visible source text owned by the lemma element.
    public let length: Int

    /**
     Creates one immutable structured lexical range.

     - Parameters:
       - lemma: Exact structured source attribute owned by the visible word.
       - location: Zero-based UTF-16 offset in the final preview.
       - length: Positive UTF-16 length of the owned visible source text.
     - Side effects: None.
     - Failure modes: Values are retained verbatim; the index boundary validates them against the
       final preview and omits malformed ranges.
     */
    public init(lemma: String, location: Int, length: Int) {
        self.lemma = lemma
        self.location = location
        self.length = length
    }
}

/**
 Separates one Bible verse's searchable canonical text from its user-visible Search preview.

 Android's JSword index analyzes canonical OSIS text, while `MultiSearchItemAdapter` re-reads the
 structured verse and omits annotation subtrees for presentation. Keeping both values in one
 immutable projection prevents rendered SWORD filters from becoming either indexed corpus or UI.
 */
public struct SwordBibleSearchTextProjection: Equatable, Sendable {
    /// JSword-compatible canonical body supplied to the module-language search analyzer.
    public let indexText: String

    /// Android MultiSearch-compatible verse text stored for result presentation.
    public let previewText: String

    /// Structured lemma attributes mapped to exact visible-preview ranges.
    public let lemmaSpans: [SwordBibleSearchLemmaSpan]

    /**
     Projects one source-neutral OSIS verse without passing it through an HTML render filter.

     JSword-recognized `x-preverse` structure and repaired Psalm titles are separated before a
     synthetic verse is traversed; ordinary titles and milestones remain in their source position.
     Canonical index text follows JSword's `OSISUtil.getCanonicalText`: `note`, `title`, and
     `reference` are excluded unless explicitly marked `canonical="true"`, and parsed JDOM-style
     text reaches the analyzer verbatim. Preview text follows Android `MultiSearchItemAdapter`:
     `note` and `reference` subtrees are excluded after that exact pre-verse boundary is separated,
     then one pinned AOSP TagSoup/`Html.fromHtml` pass produces visible presentation text. Malformed
     source follows JSword's structured entity-cleaning, tag-reclosure, and tag-cleaning ladder.

     - Parameters:
       - sourceXML: Source-neutral OSIS fragment for one exact positive verse.
       - moduleInitials: Exact installed initials controlling pinned module-specific source repair.
     - Returns: Independently projected canonical index text, visible preview text, and structured
       lemma ranges for Strong's result emphasis.
     - Side effects: Parses one bounded XML fragment in memory; external entities are disabled.
     - Failure modes: Irreparable source produces an empty projection, matching pinned JSword's
       empty-content fallback; no entry selects stripped or rendered text.
     - Note: There is intentionally no stripped/rendered-text fallback because those filters can
       synthesize HTML anchors from OSIS cross references, which is the issue this boundary prevents.
     */
    public static func project(
        sourceXML: String,
        moduleInitials: String? = nil
    ) -> Self {
        let repairedSourceRoot = SwordJSwordOSISFragmentParser.parse(
            sourceXML,
            moduleInitials: moduleInitials
        )
        let repairedSource = repairedSourceRoot.children.map { $0.serializedXML() }.joined()
        let verseProjection = SwordVerseOSISProjection.project(repairedSource)
        let canonicalRoot = SwordJSwordOSISFragmentParser.parse(verseProjection.sourceXML)
        var canonicalWriter = CanonicalWriter()
        appendCanonicalText(from: canonicalRoot, to: &canonicalWriter)

        var previewSource = ""
        let previewRoot = SwordJSwordOSISFragmentParser.parse(verseProjection.verseBodyXML)
        if verseProjection.isAlreadyWrapped {
            for verse in previewRoot.children where verse.isElement(named: "verse") {
                appendPreviewSourceText(from: verse, to: &previewSource)
            }
        } else {
            appendPreviewSourceText(from: previewRoot, to: &previewSource)
        }
        let preview = SwordHTMLVisibleTextProjection.project(previewSource)
        let lemmaSpans = projectedLemmaSpans(
            previewRoot: previewRoot,
            isAlreadyWrapped: verseProjection.isAlreadyWrapped,
            authoritativePreview: preview
        )
        return Self(
            indexText: SwordJavaTextCompatibility.trim(canonicalWriter.output),
            previewText: preview,
            lemmaSpans: lemmaSpans
        )
    }

    /** Marker grammar used only to carry structured lemma boundaries through Html.fromHtml parity. */
    private static let lemmaMarkerRegex = try? NSRegularExpression(
        pattern: "\u{E000}([se])([0-9]+)\u{E001}"
    )

    /**
     Projects structured lemma boundaries through the same tolerant HTML pass as visible text.

     - Parameters:
       - previewRoot: Repaired structured verse-body root used by ordinary preview traversal.
       - isAlreadyWrapped: Whether only direct `verse` children contribute to presentation.
       - authoritativePreview: Unmarked visible projection that must remain byte-for-byte unchanged.
     - Returns: Ordered lemma spans when nonce-like marker removal reconstructs the authoritative
       preview exactly; otherwise an empty fail-closed list.
     - Side effects: Performs one additional bounded in-memory visible projection.
     - Failure modes: Marker collision, malformed nesting, invalid indices, or any projection drift
       returns no spans rather than associating a Strong's token with the wrong visible word.
     */
    private static func projectedLemmaSpans(
        previewRoot: SwordXMLNode,
        isAlreadyWrapped: Bool,
        authoritativePreview: String
    ) -> [SwordBibleSearchLemmaSpan] {
        var markedSource = ""
        var lemmas: [String] = []
        if isAlreadyWrapped {
            for verse in previewRoot.children where verse.isElement(named: "verse") {
                appendMarkedPreviewSourceText(from: verse, to: &markedSource, lemmas: &lemmas)
            }
        } else {
            appendMarkedPreviewSourceText(from: previewRoot, to: &markedSource, lemmas: &lemmas)
        }
        guard !lemmas.isEmpty, let lemmaMarkerRegex else { return [] }

        let markedPreview = SwordHTMLVisibleTextProjection.project(markedSource)
        let markedUnits = Array(markedPreview.utf16)
        let fullRange = NSRange(location: 0, length: markedUnits.count)
        let matches = lemmaMarkerRegex.matches(in: markedPreview, range: fullRange)
        guard matches.count == lemmas.count * 2 else { return [] }

        var cleanUnits: [UInt16] = []
        cleanUnits.reserveCapacity(markedUnits.count)
        var sourceCursor = 0
        var starts: [Int: Int] = [:]
        var spans: [SwordBibleSearchLemmaSpan] = []
        for match in matches {
            guard match.range.location >= sourceCursor,
                  let kindRange = Range(match.range(at: 1), in: markedPreview),
                  let indexRange = Range(match.range(at: 2), in: markedPreview),
                  let index = Int(markedPreview[indexRange]),
                  lemmas.indices.contains(index) else { return [] }
            cleanUnits.append(contentsOf: markedUnits[sourceCursor..<match.range.location])
            let kind = markedPreview[kindRange]
            if kind == "s" {
                guard starts[index] == nil else { return [] }
                starts[index] = cleanUnits.count
            } else {
                guard let start = starts.removeValue(forKey: index), start <= cleanUnits.count else {
                    return []
                }
                let length = cleanUnits.count - start
                if length > 0 {
                    spans.append(SwordBibleSearchLemmaSpan(
                        lemma: lemmas[index],
                        location: start,
                        length: length
                    ))
                }
            }
            sourceCursor = match.range.location + match.range.length
        }
        cleanUnits.append(contentsOf: markedUnits[sourceCursor..<markedUnits.count])
        guard starts.isEmpty,
              String(decoding: cleanUnits, as: UTF16.self) == authoritativePreview else { return [] }
        return spans.sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }
    }

    /**
     Concatenates preview source while surrounding every structured lemma element with markers.

     - Parameters:
       - node: Current repaired OSIS node.
       - output: HTML-like source accumulated in Android presentation order.
       - lemmas: Exact lemma values whose marker indices are embedded into `output`.
     - Side effects: Appends marker/text content and lemma metadata in deterministic source order.
     - Failure modes: None; note/reference subtrees are excluded and malformed XML was repaired
       before traversal.
     */
    private static func appendMarkedPreviewSourceText(
        from node: SwordXMLNode,
        to output: inout String,
        lemmas: inout [String]
    ) {
        guard node.isElement else {
            if node.isTextLike {
                output += node.stringValue
            } else if let description = node.jdomContentDescription {
                output += description
            }
            return
        }
        guard !["note", "reference"].contains(node.localName) else { return }

        let markerIndex: Int?
        if let lemma = node.attribute(named: "lemma"), !lemma.isEmpty {
            markerIndex = lemmas.count
            lemmas.append(lemma)
            output += "\u{E000}s\(lemmas.count - 1)\u{E001}"
        } else {
            markerIndex = nil
        }

        for child in node.children {
            if child.isElement {
                guard !["note", "reference"].contains(child.localName) else { continue }
                if child.children.contains(where: \.isElement) {
                    appendMarkedPreviewSourceText(from: child, to: &output, lemmas: &lemmas)
                } else {
                    let childMarkerIndex: Int?
                    if let lemma = child.attribute(named: "lemma"), !lemma.isEmpty {
                        childMarkerIndex = lemmas.count
                        lemmas.append(lemma)
                        output += "\u{E000}s\(lemmas.count - 1)\u{E001}"
                    } else {
                        childMarkerIndex = nil
                    }
                    for leafContent in child.children where leafContent.isTextLike {
                        output += leafContent.stringValue
                    }
                    if let childMarkerIndex {
                        output += "\u{E000}e\(childMarkerIndex)\u{E001}"
                    }
                }
            } else {
                appendMarkedPreviewSourceText(from: child, to: &output, lemmas: &lemmas)
            }
        }
        if let markerIndex {
            output += "\u{E000}e\(markerIndex)\u{E001}"
        }
    }

    /**
     Maintains JSword-compatible text boundaries while canonical XML nodes are traversed.

     The value is local to one synchronous projection, mutates only its in-memory output, and cannot
     fail. UTF-16 boundary predicates deliberately prevent Swift grapheme/whitespace behavior from
     changing JSword's adjacent-node separator decisions.
     */
    private struct CanonicalWriter {
        /// Canonical text accumulated in source document order.
        var output = ""

        /**
         Appends one parsed JDOM-style text node with JSword's adjacent-node separator rule.

         - Parameters:
           - value: Exact text or CDATA node value emitted by the current canonical element.
           - parentName: Parent OSIS element; `seg` deliberately joins adjacent word fragments.
         - Side effects: Mutates `output` in document order.
         - Failure modes: Empty values are retained only through JSword's separator behavior.
        */
        mutating func write(_ value: String, parentName: String) {
            if let last = output.utf16.last,
               !SwordJavaTextCompatibility.isWhitespace(last),
               (value.isEmpty
                    || value.utf16.first.map(SwordJavaTextCompatibility.isWhitespace) == false),
               parentName != "seg" {
                output.append(" ")
            }
            output.append(value)
        }
    }

    /**
     Walks one node using pinned JSword `OSISUtil.getCanonicalText` inclusion and spacing rules.

     - Parameters:
       - node: Current structured OSIS node.
       - writer: Shared document-order canonical text writer.
     - Side effects: Appends included text and semantic whitespace to `writer`.
     - Failure modes: None; malformed XML has already passed the pinned repair boundary.
     */
    private static func appendCanonicalText(
        from node: SwordXMLNode,
        to writer: inout CanonicalWriter
    ) {
        guard node.isElement else { return }
        let canonical = node.attribute(named: "canonical")
        if ["note", "title", "reference"].contains(node.localName),
           canonical.map({ SwordJavaTextCompatibility.equalsIgnoreCase($0, "true") }) != true {
            return
        }

        for child in node.children {
            if child.isElement {
                appendCanonicalText(from: child, to: &writer)
            } else if child.isTextLike {
                writer.write(child.stringValue, parentName: node.localName)
            }
        }
    }

    /**
     Concatenates raw child text using Android MultiSearch presentation exclusions.

     - Parameters:
       - node: Current structured OSIS node.
       - output: HTML-like character data accumulated in source order before `htmlToSpan` parity.
     - Side effects: Appends parsed text verbatim to `output`; source nodes are never mutated.
     - Failure modes: None; malformed XML has already passed the pinned repair boundary.
     */
    private static func appendPreviewSourceText(from node: SwordXMLNode, to output: inout String) {
        guard node.isElement else {
            if node.isTextLike {
                output += node.stringValue
            } else if let description = node.jdomContentDescription {
                output += description
            }
            return
        }
        guard !["note", "reference"].contains(node.localName) else { return }
        for child in node.children {
            if child.isElement {
                guard !["note", "reference"].contains(child.localName) else { continue }
                if child.children.contains(where: \.isElement) {
                    appendPreviewSourceText(from: child, to: &output)
                } else {
                    for leafContent in child.children where leafContent.isTextLike {
                        output += leafContent.stringValue
                    }
                }
            } else {
                appendPreviewSourceText(from: child, to: &output)
            }
        }
    }

}
