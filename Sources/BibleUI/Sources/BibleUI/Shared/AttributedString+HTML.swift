// AttributedString+HTML.swift — Render Android HTML without Foundation's reentrant HTML importer

import SwiftUI
import SwordKit

extension AttributedString {
    /**
     Creates native attributed text from Android's pinned TagSoup `Html.fromHtml` projection.

     Parsing is pure and deterministic. It never enters WebKit or Foundation's HTML importer, whose
     synchronous run-loop work can reenter SwiftUI while a view body is updating. The shared
     SwordKit projection retains Android entity decoding, malformed-markup repair, legacy block
     breaks, UTF-16 span boundaries, and active links for every BibleUI HTML consumer.

     - Parameters:
       - htmlBody: Android-style HTML fragment.
       - baseFont: SwiftUI font applied before semantic inline spans.
       - basePointSize: Numeric size used to compose Android relative-size spans.
     - Side effects: Loads pinned TagSoup resources on first use.
     - Failure modes: Invalid or empty span boundaries are ignored while projected text is retained.
     */
    init(
        htmlBody: String,
        baseFont: Font = .body,
        basePointSize: CGFloat = 16
    ) {
        self.init(
            androidHTMLProjection: SwordHTMLVisibleTextProjection.projectFormatted(htmlBody),
            baseFont: baseFont,
            basePointSize: basePointSize,
            baseForegroundColor: nil
        )
    }

    /** Translates one already-parsed Android projection without reparsing its source HTML. */
    fileprivate init(
        androidHTMLProjection projection: SwordHTMLFormattedTextProjection,
        baseFont: Font,
        basePointSize: CGFloat,
        baseForegroundColor: Color?
    ) {
        self.init(projection.text)
        self.font = baseFont
        if let baseForegroundColor { self.foregroundColor = baseForegroundColor }
        let boundaries = attributedIndices(
            atUTF16Offsets: Set(projection.spans.flatMap { [$0.startUTF16, $0.endUTF16] })
        )

        let colorSpans = projection.spans.enumerated()
            .filter { _, span in
                switch span.style {
                case .foregroundARGB, .backgroundARGB: true
                default: false
                }
            }
            .sorted { lhs, rhs in
                let lhsLength = lhs.element.endUTF16 - lhs.element.startUTF16
                let rhsLength = rhs.element.endUTF16 - rhs.element.startUTF16
                if lhsLength != rhsLength { return lhsLength > rhsLength }
                if lhs.element.startUTF16 != rhs.element.startUTF16 {
                    return lhs.element.startUTF16 < rhs.element.startUTF16
                }
                return lhs.offset > rhs.offset
            }

        for span in projection.spans where !span.style.isFontOrColorStyle {
            guard let lower = boundaries[span.startUTF16],
                  let upper = boundaries[span.endUTF16],
                  lower < upper else {
                continue
            }
            let range = lower..<upper
            switch span.style {
            case .bold:
                addInlineIntent(.stronglyEmphasized, in: range)
            case .italic:
                addInlineIntent(.emphasized, in: range)
            case .underline:
                self[range].underlineStyle = .single
            case .strikethrough:
                self[range].strikethroughStyle = .single
            case .monospace:
                addInlineIntent(.code, in: range)
            case .superscript:
                self[range].baselineOffset = 5
            case .subscriptStyle:
                self[range].baselineOffset = -3
            case .link(let destination):
                self[range].link = URL(string: destination)
            case .textAlignment:
                // SwiftUI's attributed-text scope has no paragraph-alignment attribute. The pure
                // projection retains it for renderers that own paragraph layout.
                break
            case .bullet:
                let list = PresentationIntent(.unorderedList, identity: span.startUTF16)
                self[range].presentationIntent = PresentationIntent(
                    .listItem(ordinal: 1),
                    identity: span.startUTF16 &+ 1,
                    parent: list
                )
            case .quote:
                self[range].presentationIntent = PresentationIntent(
                    .blockQuote,
                    identity: span.startUTF16
                )
            case .relativeSize, .fontFamily, .foregroundARGB, .backgroundARGB:
                break
            }
        }

        applyFontSpans(
            projection.spans.filter(\.style.isFontStyle),
            boundaries: boundaries,
            basePointSize: basePointSize
        )
        for (_, span) in colorSpans {
            guard let lower = boundaries[span.startUTF16],
                  let upper = boundaries[span.endUTF16],
                  lower < upper else {
                continue
            }
            switch span.style {
            case .foregroundARGB(let argb):
                self[lower..<upper].foregroundColor = color(fromARGB: argb)
            case .backgroundARGB(let argb):
                self[lower..<upper].backgroundColor = color(fromARGB: argb)
            default:
                break
            }
        }
    }

    /** Applies nested Android face and relative-size spans as one linear boundary sweep. */
    private mutating func applyFontSpans(
        _ spans: [SwordHTMLFormattedTextProjection.Span],
        boundaries: [Int: AttributedString.Index],
        basePointSize: CGFloat
    ) {
        guard !spans.isEmpty else { return }
        struct Event {
            let spanIndex: Int
            let starts: Bool
        }
        var events: [Int: [Event]] = [:]
        for (index, span) in spans.enumerated() {
            events[span.startUTF16, default: []].append(Event(spanIndex: index, starts: true))
            events[span.endUTF16, default: []].append(Event(spanIndex: index, starts: false))
        }
        let offsets = events.keys.sorted()
        var active: Set<Int> = []

        for (offsetIndex, offset) in offsets.enumerated() {
            for event in events[offset, default: []] where !event.starts {
                active.remove(event.spanIndex)
            }
            let starts = events[offset, default: []]
                .filter(\.starts)
                .sorted {
                    let lhs = spans[$0.spanIndex]
                    let rhs = spans[$1.spanIndex]
                    return lhs.endUTF16 > rhs.endUTF16
                }
            for event in starts { active.insert(event.spanIndex) }

            guard offsetIndex + 1 < offsets.count,
                  let lower = boundaries[offset],
                  let upper = boundaries[offsets[offsetIndex + 1]],
                  lower < upper,
                  !active.isEmpty else {
                continue
            }

            var sizeFactor = 1.0
            var family: (start: Int, length: Int, index: Int, value: String)?
            for spanIndex in active {
                let span = spans[spanIndex]
                switch span.style {
                case .relativeSize(let factor):
                    sizeFactor *= factor
                case .fontFamily(let value):
                    let length = span.endUTF16 - span.startUTF16
                    if family == nil
                        || span.startUTF16 > family!.start
                        || (span.startUTF16 == family!.start && length < family!.length)
                        || (span.startUTF16 == family!.start
                            && length == family!.length
                            && spanIndex < family!.index) {
                        family = (span.startUTF16, length, spanIndex, value)
                    }
                default:
                    break
                }
            }
            let pointSize = basePointSize * sizeFactor
            self[lower..<upper].font = family.map { androidHTMLFont($0.value, size: pointSize) }
                ?? .system(size: pointSize)
        }
    }

    /** Maps Android/CSS generic family names to real native font designs before named fallback. */
    private func androidHTMLFont(_ source: String, size: CGFloat) -> Font {
        let family = source.split(separator: ",", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased() ?? ""
        switch family {
        case "serif":
            return .system(size: size, design: .serif)
        case "sans", "sans-serif":
            return .system(size: size, design: .default)
        case "monospace":
            return .system(size: size, design: .monospaced)
        case "cursive":
            return .system(size: size, design: .rounded)
        default:
            return .custom(source, size: size)
        }
    }

    /**
     Resolves all requested UTF-16 boundaries in one forward pass over Unicode scalars.

     Scalar traversal retains valid Android boundaries inside a Swift grapheme cluster. A malformed
     range that bisects a UTF-16 surrogate pair is omitted while later valid ranges keep resolving.
     */
    fileprivate func attributedIndices(
        atUTF16Offsets requestedOffsets: Set<Int>
    ) -> [Int: AttributedString.Index] {
        let orderedOffsets = requestedOffsets.filter { $0 >= 0 }.sorted()
        guard !orderedOffsets.isEmpty else { return [:] }
        var result: [Int: AttributedString.Index] = [:]
        var requestedIndex = 0
        var utf16Offset = 0
        var cursor = unicodeScalars.startIndex

        while requestedIndex < orderedOffsets.count {
            let requested = orderedOffsets[requestedIndex]
            if requested == utf16Offset {
                result[requested] = cursor
                requestedIndex += 1
                continue
            }
            guard requested > utf16Offset, cursor < unicodeScalars.endIndex else { break }

            let scalar = unicodeScalars[cursor]
            let nextOffset = utf16Offset + (scalar.value > 0xFFFF ? 2 : 1)
            let nextCursor = unicodeScalars.index(after: cursor)
            while requestedIndex < orderedOffsets.count,
                  orderedOffsets[requestedIndex] > utf16Offset,
                  orderedOffsets[requestedIndex] < nextOffset {
                // No AttributedString scalar boundary exists inside one surrogate pair.
                requestedIndex += 1
            }
            utf16Offset = nextOffset
            cursor = nextCursor
        }
        return result
    }

    /** Adds one composable semantic inline style without replacing an existing nested style. */
    private mutating func addInlineIntent(
        _ intent: InlinePresentationIntent,
        in range: Range<AttributedString.Index>
    ) {
        let segments = self[range].runs.map { run in
            (range: run.range, intents: run.inlinePresentationIntent ?? [])
        }
        for segment in segments {
            var intents = segment.intents
            intents.insert(intent)
            self[segment.range].inlinePresentationIntent = intents
        }
    }

    /// Converts one Android ARGB scalar into SwiftUI's stable sRGB color space.
    private func color(fromARGB argb: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255
        )
    }
}

private extension SwordHTMLFormattedTextProjection.Style {
    /// Styles whose final SwiftUI font must be composed from every active nested span.
    var isFontStyle: Bool {
        switch self {
        case .relativeSize, .fontFamily: true
        default: false
        }
    }

    /// Styles applied after semantic spans so nested colors retain inner-source precedence.
    var isFontOrColorStyle: Bool {
        switch self {
        case .relativeSize, .fontFamily, .foregroundARGB, .backgroundARGB: true
        default: false
        }
    }
}

/** Renders Android block, list, quote, alignment, and inline HTML without a reentrant importer. */
struct AndroidHTMLText: View {
    /// Native paragraph projection captured once for this view value.
    private let paragraphs: [AndroidHTMLParagraph]
    /// Font policy selected by the owning native surface.
    private let baseFont: Font
    /// Vertical separation matching Android legacy block margins.
    private let paragraphSpacing: CGFloat
    /**
     Creates one native rich-text view from Android's pinned TagSoup projection.

     - Parameters:
       - htmlBody: Android-style HTML fragment.
       - baseFont: Font selected by the owning native surface.
       - basePointSize: Numeric size used for Android relative-size and block-margin projection.
       - foregroundColor: Owning surface default applied before explicit source color spans.
     - Side effects: Loads pinned TagSoup resources on first use.
     - Failure modes: Malformed markup is repaired by the pinned parser; invalid spans are ignored.
     */
    init(
        htmlBody: String,
        baseFont: Font = .body,
        basePointSize: CGFloat = 16,
        foregroundColor: Color? = nil
    ) {
        let projection = SwordHTMLVisibleTextProjection.projectFormatted(htmlBody)
        let attributed = AttributedString(
            androidHTMLProjection: projection,
            baseFont: baseFont,
            basePointSize: basePointSize,
            baseForegroundColor: foregroundColor
        )
        self.paragraphs = AndroidHTMLParagraph.project(
            projection: projection,
            attributed: attributed
        )
        self.baseFont = baseFont
        self.paragraphSpacing = basePointSize
    }

    var body: some View {
        VStack(alignment: .leading, spacing: paragraphSpacing) {
            ForEach(paragraphs) { paragraph in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(0..<paragraph.bulletDepth, id: \.self) { depth in
                        if paragraph.bulletGlyphDepths.contains(depth) {
                            // AOSP BulletSpan defaults: radius 4 px and trailing gap 2 px.
                            Circle()
                                .frame(width: 8, height: 8)
                                .padding(.trailing, 2)
                                .accessibilityHidden(true)
                        } else {
                            // An outer BulletSpan contributes its margin to nested paragraphs, but
                            // Android draws its glyph only at that span's own first paragraph.
                            Color.clear
                                .frame(width: 10, height: 8)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(paragraph.text)
                        .font(baseFont)
                        .multilineTextAlignment(paragraph.multilineTextAlignment)
                        .frame(maxWidth: .infinity, alignment: paragraph.frameAlignment)
                }
                .padding(.leading, CGFloat(paragraph.quoteDepth) * 4)
                .overlay(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(0..<paragraph.quoteDepth, id: \.self) { _ in
                            // AOSP QuoteSpan defaults: blue, 2 px stripe, and 2 px trailing gap.
                            Rectangle()
                                .fill(Color(
                                    .sRGB,
                                    red: 0,
                                    green: 0,
                                    blue: 1,
                                    opacity: 1
                                ))
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }
}

/** One visual paragraph derived from Android's legacy two-newline block boundary. */
private struct AndroidHTMLParagraph: Identifiable {
    let id: Int
    let text: AttributedString
    let bulletDepth: Int
    let bulletGlyphDepths: [Int]
    let quoteDepth: Int
    let alignment: SwordHTMLFormattedTextProjection.TextAlignment?

    var frameAlignment: Alignment {
        switch alignment {
        case .center: .center
        case .end: .trailing
        case .start, nil: .leading
        }
    }

    /// SwiftUI line alignment corresponding to Android's start/center/end paragraph span.
    var multilineTextAlignment: TextAlignment {
        switch alignment {
        case .center: .center
        case .end: .trailing
        case .start, nil: .leading
        }
    }

    /** Splits native rendering at Android legacy block margins without reparsing or copying HTML. */
    static func project(
        projection: SwordHTMLFormattedTextProjection,
        attributed: AttributedString
    ) -> [Self] {
        let ranges = paragraphUTF16Ranges(in: projection.text)
        let boundaries = attributed.attributedIndices(
            atUTF16Offsets: Set(ranges.flatMap { [$0.lowerBound, $0.upperBound] })
        )
        let semanticSpans = projection.spans.enumerated().compactMap { index, span in
            switch span.style {
            case .bullet, .quote, .textAlignment:
                return (index, span)
            default:
                return nil
            }
        }.sorted {
            if $0.1.startUTF16 != $1.1.startUTF16 {
                return $0.1.startUTF16 < $1.1.startUTF16
            }
            return $0.1.endUTF16 > $1.1.endUTF16
        }
        var nextSpan = 0
        var active: [Int: SwordHTMLFormattedTextProjection.Span] = [:]
        return ranges.enumerated().compactMap { index, range in
            guard let lower = boundaries[range.lowerBound],
                  let upper = boundaries[range.upperBound],
                  lower < upper else {
                return nil
            }
            active = active.filter { $0.value.endUTF16 > range.lowerBound }
            while nextSpan < semanticSpans.count,
                  semanticSpans[nextSpan].1.startUTF16 < range.upperBound {
                let candidate = semanticSpans[nextSpan]
                if candidate.1.endUTF16 > range.lowerBound {
                    active[candidate.0] = candidate.1
                }
                nextSpan += 1
            }
            let overlappingSpans = active.sorted { $0.key < $1.key }.map(\.value)
            let overlappingStyles = overlappingSpans.map(\.style)
            let bulletSpans = overlappingSpans.filter { $0.style == .bullet }.sorted {
                if $0.startUTF16 != $1.startUTF16 { return $0.startUTF16 < $1.startUTF16 }
                return $0.endUTF16 > $1.endUTF16
            }
            return Self(
                id: index,
                text: AttributedString(attributed[lower..<upper]),
                bulletDepth: bulletSpans.count,
                bulletGlyphDepths: bulletSpans.enumerated().compactMap { depth, span in
                    span.startUTF16 == range.lowerBound ? depth : nil
                },
                quoteDepth: overlappingStyles.filter { $0 == .quote }.count,
                alignment: overlappingStyles.compactMap { style in
                    guard case .textAlignment(let value) = style else { return nil }
                    return value
                }.last
            )
        }
    }

    /** Finds nonempty paragraph ranges in one scalar pass while retaining single `br` newlines. */
    private static func paragraphUTF16Ranges(in text: String) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var paragraphStart = 0
        var utf16Offset = 0
        var newlineStart: Int?
        var newlineCount = 0

        for scalar in text.unicodeScalars {
            if scalar.value == 0x0A {
                if newlineStart == nil { newlineStart = utf16Offset }
                newlineCount += 1
            } else if newlineCount >= 2, let separatorStart = newlineStart {
                if paragraphStart < separatorStart { ranges.append(paragraphStart..<separatorStart) }
                paragraphStart = utf16Offset
                newlineStart = nil
                newlineCount = 0
            } else {
                newlineStart = nil
                newlineCount = 0
            }
            utf16Offset += scalar.value > 0xFFFF ? 2 : 1
        }
        if newlineCount >= 2, let separatorStart = newlineStart {
            if paragraphStart < separatorStart { ranges.append(paragraphStart..<separatorStart) }
        } else if paragraphStart < utf16Offset {
            ranges.append(paragraphStart..<utf16Offset)
        }
        return ranges
    }
}
