// AttributedString+HTML.swift — Convert HTML to AttributedString for SwiftUI Text

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension AttributedString {
    /// Create an AttributedString from an HTML body fragment.
    /// Wraps the content in a basic HTML document with the specified base font.
    /// Uses the system label color so text is visible in both light and dark modes.
    init(htmlBody: String, baseFont: Font = .body) throws {
        // Determine text color from current trait collection
        #if os(iOS)
        let labelColor = UIColor.label
        #elseif os(macOS)
        let labelColor = NSColor.labelColor
        #endif
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(iOS)
        labelColor.resolvedColor(with: UITraitCollection.current).getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif os(macOS)
        (labelColor.usingColorSpace(.sRGB) ?? labelColor).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        let colorCSS = "rgb(\(Int(r * 255)), \(Int(g * 255)), \(Int(b * 255)))"

        // Wrap in HTML with a base font size and dynamic text color
        let html = """
        <html><head><style>
        body { font-family: -apple-system, system-ui; font-size: 16px; color: \(colorCSS); }
        a { color: \(colorCSS); }
        </style></head><body>\(htmlBody)</body></html>
        """
        guard let data = html.data(using: .utf8) else {
            self.init(htmlBody)
            return
        }
        #if os(iOS)
        let nsAttr = try NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
        #elseif os(macOS)
        let nsAttr = try NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        )
        #endif
        self.init(nsAttr)
    }
}
