// SwordVerseOSISProjection.swift -- Chapter-level projection for verse-entry OSIS

import Foundation

/**
 Separates chapter-level pre-verse structure from one SWORD verse entry.

 Android asks JSword for a chapter-range OSIS fragment, where section titles and paragraph
 milestones are siblings of the following `<verse>`. The iOS SWORD bridge reads one entry at a
 time, and those leading nodes arrive in the same entry as the verse text. This projection restores
 the chapter-level structure before `BibleChapterDocumentBuilder` adds its synthetic verse wrapper.
 */
public struct SwordVerseOSISProjection: Equatable, Sendable {
    /// Leading title, chapter, and milestone XML that belongs before the synthetic verse.
    public let preVerseXML: String
    /// Remaining inline and textual XML that belongs inside the synthetic verse.
    public let verseBodyXML: String

    /**
     Parses and partitions one raw SWORD verse-entry fragment.

     - Parameter fragmentXML: Raw OSIS content for one exact verse key.
     - Returns: A projection whose concatenated fields preserve the source node order.
     - Side effects: Parses an in-memory XML document without resolving external entities.
     - Failure modes: Malformed XML is retained entirely as `verseBodyXML`; no source content is
       discarded and `preVerseXML` is empty.
     */
    public static func project(_ fragmentXML: String) -> SwordVerseOSISProjection {
        let trimmed = fragmentXML.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let root = try? SwordXMLTreeParser.parse(xml: "<osis-fragment>\(trimmed)</osis-fragment>") else {
            return SwordVerseOSISProjection(preVerseXML: "", verseBodyXML: trimmed)
        }

        var preVerseNodes: [SwordXMLNode] = []
        var pendingWhitespace: [SwordXMLNode] = []
        var bodyNodes: [SwordXMLNode] = []
        var reachedVerseBody = false

        for node in root.children {
            if reachedVerseBody {
                bodyNodes.append(node)
            } else if node.isWhitespaceOnlyText {
                pendingWhitespace.append(node)
            } else if node.isChapterLevelVersePreamble {
                preVerseNodes.append(contentsOf: pendingWhitespace)
                pendingWhitespace.removeAll(keepingCapacity: true)
                preVerseNodes.append(node)
            } else {
                bodyNodes.append(contentsOf: pendingWhitespace)
                pendingWhitespace.removeAll(keepingCapacity: true)
                bodyNodes.append(node)
                reachedVerseBody = true
            }
        }

        if reachedVerseBody {
            bodyNodes.append(contentsOf: pendingWhitespace)
        } else {
            preVerseNodes.append(contentsOf: pendingWhitespace)
        }

        return SwordVerseOSISProjection(
            preVerseXML: preVerseNodes.map { $0.serializedXML() }.joined(),
            verseBodyXML: bodyNodes.map { $0.serializedXML() }.joined()
        )
    }
}

private extension SwordXMLNode {
    /// Whether this node is formatting-only whitespace between top-level fragment nodes.
    var isWhitespaceOnlyText: Bool {
        isTextLike && stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /**
     Whether this leading node occupies JSword's chapter level rather than the verse body.

     Titles and chapter markers are always pre-verse structure. SWORD represents paired section,
     paragraph, poetic line-group, and pre-verse boundaries as empty milestone elements carrying
     `sID` or `eID`. Comments and processing instructions are non-rendering metadata and can remain
     with the adjacent preamble without changing visible content.
     */
    var isChapterLevelVersePreamble: Bool {
        guard isElement else {
            return !isTextLike
        }
        if localName == "title" || localName == "chapter" {
            return true
        }
        if attribute(named: "subType")?.lowercased() == "x-preverse" {
            return true
        }
        return (localName == "div" || localName == "lg" || localName == "milestone")
            && (attribute(named: "sID") != nil || attribute(named: "eID") != nil)
    }
}
