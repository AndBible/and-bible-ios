// MyDocumentXHTMLFormatter.swift -- Android-compatible, XML-safe Markdown rendering

import Foundation
import Markdown

/**
 Renders a `swift-markdown` syntax tree as the XHTML fragment expected by My Documents.

 Android uses commonmark-java with only the GFM tables extension. `swift-markdown` uses the same
 CommonMark family but its convenience `HTMLFormatter` emits unescaped text/attributes and enables
 task-list and strikethrough extensions. This formatter keeps the parser dependency while restoring
 Android's output contract: XML-sensitive text and attributes are escaped, void elements self-close,
 tables render structurally, task-list and strikethrough syntax remains literal, and named HTML
 entities are normalized to Unicode except for XML's five built-ins.

 Raw HTML nodes remain raw, matching Android's renderer. Callers that accept arbitrary external HTML
 should use the My Documents HTML content type, whose payload is XML-escaped separately.

 - Side effects: None.
 - Failure modes: None; unknown named entities are retained verbatim, matching Android's fallback.
 */
struct MyDocumentXHTMLFormatter: MarkupWalker {
    private(set) var result = ""
    private let sourceLines: [Substring]
    private var listTightnessStack: [Bool] = []
    private var tableColumnAlignments: [Table.ColumnAlignment?]?
    private var currentTableColumn = 0
    private var isInTableHead = false

    /**
     Retains source lines because `swift-markdown` 0.8 omits cmark's tight-list flag from its AST.

     - Parameter markdown: The exact Markdown source used to construct the visited syntax tree.
     - Side effects: None.
     - Failure modes: None.
     */
    private init(markdown: String) {
        sourceLines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /**
     Parses Markdown with smart punctuation disabled and returns an XHTML-compatible fragment.

     - Parameter markdown: Raw Markdown source.
     - Returns: XHTML fragment without the outer My Documents wrapper.
     - Side effects: None.
     - Failure modes: None; the CommonMark parser produces a document for every string.
     */
    static func format(_ markdown: String) -> String {
        let document = Document(parsing: markdown, options: [.disableSmartOpts])
        var formatter = Self(markdown: markdown)
        formatter.visit(document)
        return normalizeNamedEntities(in: formatter.result)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        result += "<blockquote>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let languageAttribute = codeBlock.language.map {
            " class=\"language-\(Self.escapeAttribute($0))\""
        } ?? ""
        result += "<pre><code\(languageAttribute)>\(Self.escapeText(codeBlock.code))</code></pre>\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        result += "<h\(heading.level)>"
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr />\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        result += html.rawHTML
    }

    mutating func visitListItem(_ listItem: ListItem) {
        let blocks = Array(listItem.children)
        let isTight = listTightnessStack.last == true
        result += "<li>"
        if !isTight || !(blocks.first is Paragraph) {
            result += "\n"
        }
        for (index, block) in blocks.enumerated() {
            visit(block)
            if isTight, block is Paragraph, index < blocks.count - 1 {
                result += "\n"
            }
        }
        result += "</li>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let startAttribute = orderedList.startIndex == 1 ? "" : " start=\"\(orderedList.startIndex)\""
        result += "<ol\(startAttribute)>\n"
        listTightnessStack.append(isTightList(orderedList))
        descendInto(orderedList)
        listTightnessStack.removeLast()
        result += "</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        result += "<ul>\n"
        listTightnessStack.append(isTightList(unorderedList))
        descendInto(unorderedList)
        listTightnessStack.removeLast()
        result += "</ul>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) {
        let isDirectListItemParagraph = paragraph.parent is ListItem
        let omitsParagraphElement = isDirectListItemParagraph && listTightnessStack.last == true
        if !omitsParagraphElement {
            result += "<p>"
        }
        if paragraph.indexInParent == 0,
           let listItem = paragraph.parent as? ListItem,
           let checkbox = listItem.checkbox {
            result += checkbox == .checked ? "[x] " : "[ ] "
        }
        descendInto(paragraph)
        if !omitsParagraphElement {
            result += "</p>\n"
        }
    }

    mutating func visitTable(_ table: Table) {
        result += "<table>\n"
        tableColumnAlignments = table.columnAlignments
        descendInto(table)
        tableColumnAlignments = nil
        result += "</table>\n"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        result += "<thead>\n<tr>\n"
        isInTableHead = true
        currentTableColumn = 0
        descendInto(tableHead)
        isInTableHead = false
        result += "</tr>\n</thead>\n"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        guard !tableBody.isEmpty else { return }
        result += "<tbody>\n"
        descendInto(tableBody)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        result += "<tr>\n"
        currentTableColumn = 0
        descendInto(tableRow)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        guard let alignments = tableColumnAlignments,
              currentTableColumn < alignments.count,
              tableCell.colspan > 0,
              tableCell.rowspan > 0 else {
            return
        }

        let element = isInTableHead ? "th" : "td"
        result += "<\(element)"
        if let alignment = alignments[currentTableColumn] {
            result += " align=\"\(alignment)\""
        }
        currentTableColumn += 1
        if tableCell.rowspan > 1 {
            result += " rowspan=\"\(tableCell.rowspan)\""
        }
        if tableCell.colspan > 1 {
            result += " colspan=\"\(tableCell.colspan)\""
        }
        result += ">"
        descendInto(tableCell)
        result += "</\(element)>\n"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(Self.escapeText(inlineCode.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        result += "<em>"
        descendInto(emphasis)
        result += "</em>"
    }

    mutating func visitStrong(_ strong: Strong) {
        result += "<strong>"
        descendInto(strong)
        result += "</strong>"
    }

    mutating func visitImage(_ image: Image) {
        result += "<img"
        if let source = image.source, !source.isEmpty {
            result += " src=\"\(Self.escapeAttribute(source))\""
        }
        result += " alt=\"\(Self.escapeAttribute(Self.plainText(in: image)))\""
        if let title = image.title, !title.isEmpty {
            result += " title=\"\(Self.escapeAttribute(title))\""
        }
        result += " />"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += inlineHTML.rawHTML
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br />\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }

    mutating func visitLink(_ link: Link) {
        result += "<a"
        if let destination = link.destination {
            result += " href=\"\(Self.escapeAttribute(destination))\""
        }
        if let title = link.title, !title.isEmpty {
            result += " title=\"\(Self.escapeAttribute(title))\""
        }
        result += ">"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitText(_ text: Text) {
        result += Self.escapeText(text.string)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        result += "~~"
        descendInto(strikethrough)
        result += "~~"
    }

    private static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value)
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /**
     Reconstructs CommonMark's list-tightness flag from source gaps discarded by the Swift AST.

     A list is loose when a blank source line separates direct blocks in an item or separates two
     items. Blank lines nested inside a child block do not loosen the containing list.

     - Parameter list: Parsed ordered or unordered list whose children retain source ranges.
     - Returns: `true` when direct list-item paragraphs must render without `<p>` wrappers.
     - Side effects: None.
     - Failure modes: Missing source ranges conservatively produce a loose list.
     */
    private func isTightList(_ list: Markup) -> Bool {
        let items = list.children.compactMap { $0 as? ListItem }
        guard items.count == list.childCount else {
            return false
        }
        let itemBlocks = items.map { Array($0.children) }

        for (item, blocks) in zip(items, itemBlocks) {
            guard let itemRange = item.range,
                  let firstBlockRange = blocks.first?.range else {
                return false
            }
            if containsBlankLine(
                after: itemRange.lowerBound,
                before: firstBlockRange.lowerBound
            ) {
                return false
            }

            for (leadingBlock, trailingBlock) in zip(blocks, blocks.dropFirst()) {
                guard let leadingRange = leadingBlock.range,
                      let trailingRange = trailingBlock.range else {
                    return false
                }
                if containsBlankLine(after: leadingRange.upperBound, before: trailingRange.lowerBound) {
                    return false
                }
            }
        }

        for (leadingBlocks, trailingBlocks) in zip(itemBlocks, itemBlocks.dropFirst()) {
            guard let leadingRange = leadingBlocks.last?.range,
                  let trailingRange = trailingBlocks.first?.range else {
                return false
            }
            if containsBlankLine(after: leadingRange.upperBound, before: trailingRange.lowerBound) {
                return false
            }
        }
        return true
    }

    /**
     Reports whether a complete blank source line lies strictly between two parsed locations.

     - Parameters:
       - start: Exclusive source location at the end of the leading block.
       - end: Exclusive source location at the start of the trailing block.
     - Returns: `true` when the intervening source contains a whitespace-only line.
     - Side effects: None.
     - Failure modes: Out-of-range parser locations are ignored and return `false`.
     */
    private func containsBlankLine(after start: SourceLocation, before end: SourceLocation) -> Bool {
        guard end.line - start.line > 1 else {
            return false
        }
        return ((start.line + 1)..<end.line).contains { lineNumber in
            let index = lineNumber - 1
            guard sourceLines.indices.contains(index) else {
                return false
            }
            return sourceLines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static let xmlEntityNames: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    /** Converts non-XML named HTML entities using the same parser's CommonMark entity table. */
    private static func normalizeNamedEntities(in html: String) -> String {
        var normalized = ""
        var index = html.startIndex

        while index < html.endIndex {
            guard html[index] == "&",
                  let semicolon = html[index...].firstIndex(of: ";") else {
                normalized.append(html[index])
                index = html.index(after: index)
                continue
            }

            let candidateRange = index...semicolon
            let candidate = String(html[candidateRange])
            let name = String(candidate.dropFirst().dropLast())
            let isNamedEntity = name.first?.isASCII == true
                && name.first?.isLetter == true
                && name.allSatisfy { $0.isASCII && $0.isLetter || $0.isNumber }
            guard isNamedEntity, !xmlEntityNames.contains(name) else {
                normalized += candidate
                index = html.index(after: semicolon)
                continue
            }

            let decoded = plainText(
                in: Document(parsing: candidate, options: [.disableSmartOpts])
            )
            normalized += decoded == candidate ? candidate : decoded
            index = html.index(after: semicolon)
        }
        return normalized
    }

    private static func plainText(in markup: Markup) -> String {
        var extractor = MyDocumentPlainTextExtractor()
        extractor.visit(markup)
        return extractor.result
    }
}

/// Extracts decoded text from parser nodes without re-rendering markup.
private struct MyDocumentPlainTextExtractor: MarkupWalker {
    private(set) var result = ""

    mutating func visitText(_ text: Text) {
        result += text.string
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += inlineCode.code
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "\n"
    }
}
