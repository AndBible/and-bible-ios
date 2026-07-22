// GenericBookmarkSourceTextProjection.swift -- visible text projection for generic annotations

import Foundation
import Markdown

/**
 Projects stored My Documents and XHTML content into the visible text domain used by Android
 generic-bookmark offsets.

 Android records `startOffset` and `endOffset` against rendered text, not source markup. This
 boundary uses the same structured parsers already present in BibleCore so bookmark payloads never
 derive selection text with regular-expression tag stripping.
 */
public enum GenericBookmarkSourceTextProjection {
    /**
     Returns the visible text for one My Documents body.

     - Parameters:
       - content: Stored page body.
       - contentType: Android-compatible page content type.
     - Returns: Text corresponding to the reader-visible character stream.
     - Side effects: none.
     - Failure modes: Malformed OSIS falls back to the stored source text; HTML intentionally
       remains literal because Android's My Documents HTML mode renders escaped source markup.
     */
    public static func myDocumentText(
        _ content: String,
        contentType: MyDocumentContentType
    ) -> String {
        switch contentType {
        case .markdown:
            var extractor = MarkdownVisibleTextExtractor()
            extractor.visit(Document(parsing: content, options: [.disableSmartOpts]))
            return extractor.result
        case .html:
            return content
        case .osis:
            return xmlText(content) ?? content
        }
    }

    /**
     Returns the visible text represented by one EPUB XHTML fragment.

     - Parameter xhtml: Structured XHTML emitted by the EPUB content transformer.
     - Returns: Decoded descendant text, or the original input when parsing fails.
     - Side effects: none.
     - Failure modes: Malformed XHTML returns the source rather than inventing an empty payload.
     */
    public static func xhtmlText(_ xhtml: String) -> String {
        xmlText(xhtml) ?? xhtml
    }

    /** Parses XML with external entities disabled and returns descendant text. */
    private static func xmlText(_ source: String) -> String? {
        guard let data = source.data(using: .utf8),
              let root = try? EpubXMLTreeParser.parse(data) else {
            return nil
        }
        return root.textContent()
    }
}

/// Collects rendered Markdown text while preserving explicit line breaks.
private struct MarkdownVisibleTextExtractor: MarkupWalker {
    /// Accumulated visible text in document order.
    private(set) var result = ""

    /// Appends one decoded Markdown text node.
    mutating func visitText(_ text: Text) {
        result += text.string
    }

    /// Appends inline-code content without Markdown delimiters.
    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += inlineCode.code
    }

    /// Preserves a soft line break as one newline character.
    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }

    /// Preserves an explicit Markdown line break as one newline character.
    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "\n"
    }
}
