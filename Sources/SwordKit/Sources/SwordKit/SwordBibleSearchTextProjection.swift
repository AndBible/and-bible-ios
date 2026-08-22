// SwordBibleSearchTextProjection.swift -- Android-parity Bible search text projection

import Foundation

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
     - Returns: Independently projected canonical index text and visible preview text.
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
        return Self(
            indexText: SwordJavaTextCompatibility.trim(canonicalWriter.output),
            previewText: preview
        )
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
