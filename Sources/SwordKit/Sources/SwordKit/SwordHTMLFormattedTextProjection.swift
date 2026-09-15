import Foundation

/**
 Immutable Android `Html.fromHtml` text and inline-span output.

 Offsets use Java UTF-16 units because Android `Spanned` ranges and the pinned TagSoup scanner use
 that coordinate space. The value contains no UIKit/AppKit objects, so parsing remains a pure,
 worker-safe operation and rendering frameworks only translate the finished projection.
 */
public struct SwordHTMLFormattedTextProjection: Equatable, Sendable {
    /// Paragraph alignment values accepted by Android's HTML CSS handler.
    public enum TextAlignment: Equatable, Sendable {
        case start
        case center
        case end
    }

    /// One Android character or paragraph span over a half-open UTF-16 range.
    public struct Span: Equatable, Sendable {
        /// Inclusive Java UTF-16 start offset.
        public let startUTF16: Int
        /// Exclusive Java UTF-16 end offset.
        public let endUTF16: Int
        /// Semantic style emitted by Android's HTML handler.
        public let style: Style

        public init(startUTF16: Int, endUTF16: Int, style: Style) {
            self.startUTF16 = startUTF16
            self.endUTF16 = endUTF16
            self.style = style
        }
    }

    /// Android HTML styles needed by native SwiftUI text consumers.
    public enum Style: Equatable, Sendable {
        case bold
        case italic
        case underline
        case strikethrough
        case monospace
        case relativeSize(Double)
        case superscript
        case subscriptStyle
        case link(String)
        case fontFamily(String)
        case foregroundARGB(UInt32)
        case backgroundARGB(UInt32)
        case textAlignment(TextAlignment)
        case bullet
        case quote
    }

    /// Visible text after pinned entities, TagSoup repair, and legacy block margins.
    public let text: String
    /// Spans in parser callback order.
    public let spans: [Span]

    public init(text: String, spans: [Span]) {
        self.text = text
        self.spans = spans
    }
}
