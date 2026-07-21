// EpubSearchTextProjection.swift -- trusted raw-FTS hit projection

import Foundation

/** One plain-text EPUB search snippet run with an explicit trust-derived emphasis state. */
public struct EpubSearchSnippetSegment: Sendable, Equatable {
    /// Original EPUB text for this run.
    public let text: String

    /// Whether SQLite FTS matched this source run.
    public let isEmphasized: Bool

    /** Creates one immutable snippet run. */
    public init(text: String, isEmphasized: Bool) {
        self.text = text
        self.isEmphasized = isEmphasized
    }
}

/**
 Converts trusted SQLite highlighting over Android's raw EPUB `contentText` into source runs.

 Android indexes original BVA text with SQLite FTS5 and does not run JSword analyzers for EPUBs.
 Per-request nonce markers supplied to SQLite are therefore the complete emphasis authority;
 authored markup and marker-like text remain ordinary source text.
 */
enum EpubSearchTextProjection {
    /**
     Converts nonce-marked raw FTS output into source-preserving presentation segments.

     - Parameters:
       - sourceText: Original untrusted EPUB sentence stored in FTS.
       - highlightedSourceText: SQLite `highlight` output over the raw source-text column.
       - openingMarker: Per-request marker supplied to SQLite as the highlight prefix.
       - closingMarker: Per-request marker supplied to SQLite as the highlight suffix.
     - Returns: Source-preserving plain and emphasized runs.
     - Side effects: None.
     - Failure modes: Unbalanced, nested, or source-changing marker output degrades to one unstyled
       source run instead of trusting malformed presentation data.
     */
    static func sourceSnippetSegments(
        sourceText: String,
        highlightedSourceText: String,
        openingMarker: String,
        closingMarker: String
    ) -> [EpubSearchSnippetSegment] {
        guard !openingMarker.isEmpty, !closingMarker.isEmpty else {
            return plainSegments(sourceText)
        }

        var cursor = highlightedSourceText.startIndex
        var insideHighlight = false
        var buffer = ""
        var reconstructed = ""
        var result: [EpubSearchSnippetSegment] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            reconstructed.append(buffer)
            if let last = result.last, last.isEmphasized == insideHighlight {
                result[result.count - 1] = EpubSearchSnippetSegment(
                    text: last.text + buffer,
                    isEmphasized: insideHighlight
                )
            } else {
                result.append(EpubSearchSnippetSegment(text: buffer, isEmphasized: insideHighlight))
            }
            buffer = ""
        }

        while cursor < highlightedSourceText.endIndex {
            if highlightedSourceText[cursor...].hasPrefix(openingMarker) {
                guard !insideHighlight else { return plainSegments(sourceText) }
                flush()
                insideHighlight = true
                cursor = highlightedSourceText.index(cursor, offsetBy: openingMarker.count)
                continue
            }
            if highlightedSourceText[cursor...].hasPrefix(closingMarker) {
                guard insideHighlight else { return plainSegments(sourceText) }
                flush()
                insideHighlight = false
                cursor = highlightedSourceText.index(cursor, offsetBy: closingMarker.count)
                continue
            }
            buffer.append(highlightedSourceText[cursor])
            cursor = highlightedSourceText.index(after: cursor)
        }
        guard !insideHighlight else { return plainSegments(sourceText) }
        flush()
        guard reconstructed == sourceText else { return plainSegments(sourceText) }
        return result
    }

    /** Returns one untrusted source string as an unstyled run. */
    private static func plainSegments(_ sourceText: String) -> [EpubSearchSnippetSegment] {
        sourceText.isEmpty ? [] : [EpubSearchSnippetSegment(text: sourceText, isEmphasized: false)]
    }
}
