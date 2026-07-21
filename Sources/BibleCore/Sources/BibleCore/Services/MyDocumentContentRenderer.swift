// MyDocumentContentRenderer.swift -- Android-parity My Documents XHTML rendering

import Foundation

/**
 Renders raw My Documents bodies into the native HTML/OSIS fragment consumed by BibleView.

 Android parses Markdown with a CommonMark parser plus GFM tables, emits XHTML-compatible HTML,
 wraps HTML as escaped text for Vue's native HTML component, and passes OSIS through. The Swift
 Markdown package is pinned in `Package.swift`; its parser is backed by cmark-gfm and its formatter
 supports tables, links, lists, task items, and self-closing void elements.
 */
public enum MyDocumentContentRenderer {
    /**
     Converts one raw page body to Android's wrapper contract.

     - Parameters:
       - content: Stored raw Markdown, HTML, or OSIS text.
       - contentType: Android-compatible storage type.
     - Returns: Renderable XHTML/OSIS fragment.
     - Side effects: None.
     - Failure modes: None; raw HTML is XML-escaped as text and OSIS remains caller-authored.
     */
    public static func render(_ content: String, contentType: MyDocumentContentType) -> String {
        switch contentType {
        case .markdown:
            return "<div class=\"mydoc-markdown\">\(MyDocumentXHTMLFormatter.format(content))</div>"
        case .html:
            return "<div class=\"mydoc-html\"><html>\(escapeXML11(content))</html></div>"
        case .osis:
            return content
        }
    }

    /**
     Escapes raw HTML using Apache Commons Text's XML 1.1 character rules used by Android.
     */
    public static func escapeXML11(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x26:
                result += "&amp;"
            case 0x3C:
                result += "&lt;"
            case 0x3E:
                result += "&gt;"
            case 0x22:
                result += "&quot;"
            case 0x27:
                result += "&apos;"
            case 0x00, 0xFFFE, 0xFFFF:
                continue
            case 0x01...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F...0x84, 0x86...0x9F:
                result += "&#\(scalar.value);"
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
