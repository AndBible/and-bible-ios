// SwordVerseOSISProjection.swift -- JSword SwordBook verse-entry projection

import Foundation

/**
 Reconstructs pinned JSword's chapter/pre-verse boundary for one SWORD verse entry.

 `SwordBook.addOSIS` leaves already-wrapped verse content intact. Otherwise it finds the last direct
 `div`/`title` with `subType="x-preverse"` (including repaired Psalm titles), keeps everything
 through that node at chapter level, and wraps the complete suffix as the verse body.
 */
public struct SwordVerseOSISProjection: Equatable, Sendable {
    /// Full lossless source after JSword's Psalm-title attribute repair.
    public let sourceXML: String
    /// Content retained at chapter level before a synthetic verse.
    public let preVerseXML: String
    /// Complete suffix to wrap, or all source content when a direct verse already exists.
    public let verseBodyXML: String
    /// Whether JSword found a direct top-level verse and therefore skips synthetic wrapping.
    public let isAlreadyWrapped: Bool

    /**
     Parses and partitions one raw SWORD verse-entry fragment using pinned `SwordBook.addOSIS`.

     - Parameters:
       - fragmentXML: Raw source fragment; outer spaces/tabs remain content.
       - verseOrdinal: Optional source ordinal applied to direct existing verse elements, matching
         JSword's reader assembly. Search projection omits it because it does not affect text.
     - Returns: Full repaired source plus exact pre-verse/body ownership and wrapper state.
     - Side effects: Parses and mutates a bounded in-memory XML tree only.
     - Failure modes: Malformed XML remains wholly in `sourceXML`/`verseBodyXML`, with no invented
       preamble and `isAlreadyWrapped == false`.
     */
    public static func project(
        _ fragmentXML: String,
        verseOrdinal: Int? = nil
    ) -> SwordVerseOSISProjection {
        guard let root = try? SwordXMLTreeParser.parse(
            xml: "<osis-fragment>\(fragmentXML)</osis-fragment>"
        ) else {
            return SwordVerseOSISProjection(
                sourceXML: fragmentXML,
                preVerseXML: "",
                verseBodyXML: fragmentXML,
                isAlreadyWrapped: false
            )
        }

        var lastPreVerseIndex: Int?
        var alreadyWrapped = false
        for (index, node) in root.children.enumerated() where node.isElement {
            if node.localName == "verse" {
                alreadyWrapped = true
                if let verseOrdinal {
                    node.setAttribute(named: "verseOrdinal", value: String(verseOrdinal))
                }
                continue
            }

            let subtype = node.attribute(named: "subType")
            if subtype == "x-preverse", node.localName == "div" || node.localName == "title" {
                lastPreVerseIndex = index
            } else if node.localName == "title", node.attribute(named: "type") == "psalm" {
                if node.attribute(named: "canonical") == nil {
                    node.setAttribute(named: "canonical", value: "true")
                }
                if subtype == nil {
                    node.setAttribute(named: "subType", value: "x-preverse")
                    lastPreVerseIndex = index
                }
            }
        }

        let serialized = root.children.map { $0.serializedXML() }
        let fullSource = serialized.joined()
        if alreadyWrapped {
            return SwordVerseOSISProjection(
                sourceXML: fullSource,
                preVerseXML: "",
                verseBodyXML: fullSource,
                isAlreadyWrapped: true
            )
        }

        guard let lastPreVerseIndex else {
            return SwordVerseOSISProjection(
                sourceXML: fullSource,
                preVerseXML: "",
                verseBodyXML: fullSource,
                isAlreadyWrapped: false
            )
        }
        return SwordVerseOSISProjection(
            sourceXML: fullSource,
            preVerseXML: serialized[...lastPreVerseIndex].joined(),
            verseBodyXML: serialized[(lastPreVerseIndex + 1)...].joined(),
            isAlreadyWrapped: false
        )
    }
}
