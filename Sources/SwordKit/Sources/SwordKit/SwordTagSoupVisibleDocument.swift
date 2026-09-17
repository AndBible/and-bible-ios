import Foundation

/**
 Replays TagSoup's schema-backed element repair into Android `HtmlToSpannedConverter` visible text.

 The scanner is intentionally separate: this state owns document-local bogons, parser
 rectification/restart stacks, synthetic start/end events, and the small subset of Android span
 callbacks that change the stored plain string.
 */
struct SwordTagSoupVisibleDocument {
    /// Whether this pass records formatting metadata in addition to visible text.
    private let collectFormatting: Bool
    /// Marker classes used by Android's `getLast`/`setSpanFromMark` handler contract.
    private enum SpanMarkerKind: Equatable {
        case bold
        case italic
        case big
        case small
        case monospace
        case underline
        case strikethrough
        case superscript
        case subscriptMark
        case link
        case fontFamily
        case foregroundColor
        case backgroundColor
        case alignment
        case bullet
        case quote
        case heading
    }

    /// One open Android formatting marker at a Java UTF-16 text offset.
    private struct SpanMarker {
        let kind: SpanMarkerKind
        let startUTF16: Int
        let style: SwordHTMLFormattedTextProjection.Style?
    }

    /**
     Stores one live TagSoup parser element and its deferred-close state.

     Instances mutate only inside the owning document stack, perform no I/O, and cannot fail;
     `isPreclosed` preserves `F_NOFORCE` close ordering until the blocking structure is removed.
     */
    private struct OpenElement {
        /// Pinned schema or document-local bogon declaration.
        let type: SwordTagSoupHTMLSchema.ElementType
        /// Scanner-decoded attributes retained when TagSoup restarts an inline element.
        let attributes: [String: String]
        /// Whether an enclosing `F_NOFORCE` close deferred this element.
        var isPreclosed = false
    }

    /// Parser stack from synthetic root through the current element.
    private var stack: [OpenElement]
    /// Restartable inline elements popped above repaired structure, newest last.
    private var saved: [OpenElement] = []
    /// Runtime bogon declarations retained by Android-lowercased QName within one document.
    private var bogons: [String: SwordTagSoupHTMLSchema.ElementType] = [:]
    /// Visible output produced by Android's HTML handler callbacks.
    private(set) var output = ""
    /// Incremental Java UTF-16 length of `output` used by span callbacks.
    private var outputUTF16Count = 0
    /// Android formatting spans completed by parser end callbacks.
    private(set) var spans: [SwordHTMLFormattedTextProjection.Span] = []
    /// Shared Android `Newline` markers opened by visible block handlers.
    private var visibleBlockMarkers: [String] = []
    /// Open formatting markers in Android insertion order.
    private var spanMarkers: [SpanMarker] = []

    /**
     Creates one parser document rooted at TagSoup's generated synthetic root.

     - Side effects: Loads the pinned schema on first use and initializes in-memory parser stacks.
     - Failure modes: Missing schema data falls back to an unrestricted synthetic root; resource
       integrity tests prevent that degraded state from shipping.
     */
    init(collectFormatting: Bool = false) {
        self.collectFormatting = collectFormatting
        let root = SwordTagSoupHTMLSchema.element(namedCanonicalName: "<root>")
            ?? SwordTagSoupHTMLSchema.bogon(named: "<root>")
        stack = [OpenElement(type: root, attributes: [:])]
    }

    /**
     Feeds one decoded PCDATA/CDATA event through parser rectification and Android spacing.

     - Parameter value: Scanner-normalized character data; entity interpretation is already done.
     - Side effects: May synthesize HTML/body elements, close incompatible structure, and append
       visible characters.
     - Failure modes: Whitespace-only data that the current schema context cannot contain is
       ignored, matching TagSoup with `ignorableWhitespace == false`.
     */
    mutating func appendCharacters(_ value: String) {
        guard !value.isEmpty,
              let pcdata = SwordTagSoupHTMLSchema.element(namedCanonicalName: "<pcdata>") else {
            return
        }
        let allJavaWhitespace = value.utf16.allSatisfy(SwordJavaTextCompatibility.isWhitespace)
        if allJavaWhitespace, stack.last?.type.canContain(pcdata) == false {
            return
        }
        guard rectify(pcdata, emitIncomingElement: false) else { return }
        appendVisibleCharacters(value)
    }

    /**
     Commits one repaired scanner start tag through TagSoup's schema parser.

     - Parameters:
       - repairedName: Exact `Parser.makeName` QName.
       - isSelfClosing: Whether scanner action `A_EMPTYTAG` committed the tag.
     - Returns: The canonical current QName when pushing the type requested scanner CDATA mode, or
       nil otherwise. A value remains for an empty `script`/`style`, matching transition ordering.
     - Side effects: Mutates parser stacks and emits balanced Android start/end callbacks.
     - Failure modes: A schema resource failure treats the tag as a runtime bogon.
     */
    mutating func startTag(
        repairedName: String,
        isSelfClosing: Bool,
        attributes: [String: String] = [:]
    ) -> String? {
        let type = elementType(for: repairedName)
        var enteredCDATA = false
        guard rectify(type, attributes: attributes, enteredCDATA: &enteredCDATA) else { return nil }
        if isSelfClosing || stack.last?.type.model == 0 {
            closeCurrentElement()
        }
        return enteredCDATA ? type.name : nil
    }

    /**
     Applies one repaired scanner end tag with TagSoup's unmatched/no-force semantics.

     - Parameter repairedName: Exact `Parser.makeName` output from the end-tag scanner buffer, or
       empty when TagSoup's zero-length ETAG closes the current eligible element.
     - Side effects: Pops matched structure, emits synthetic closes, and may restart inline tags.
     - Failure modes: Unknown or structurally unreachable end tags are ignored.
     */
    mutating func endTag(repairedName: String) {
        let type: SwordTagSoupHTMLSchema.ElementType?
        if repairedName.isEmpty {
            type = stack.last?.type
        } else {
            let lookupKey = SwordJavaTextCompatibility.lowercasedRoot(repairedName)
            type = SwordTagSoupHTMLSchema.knownElement(named: repairedName) ?? bogons[lookupKey]
        }
        guard let type,
              let matched = stack.lastIndex(where: { $0.type.name == type.name }),
              matched >= 2 else {
            return
        }

        let hasNoForceAbove = stack[(matched + 1)...].contains {
            $0.type.flags & SwordTagSoupHTMLSchema.noForceFlag != 0
        }
        if hasNoForceAbove {
            stack[matched].isPreclosed = true
        } else {
            while stack.count - 1 > matched {
                restartablyPop()
            }
            pop()
        }
        while stack.last?.isPreclosed == true {
            pop()
        }
        restart(nextElement: nil)
    }

    /**
     Synthesizes every parser end event still open when `HTMLScanner` reaches EOF.

     - Side effects: Drains the element stack and emits Android end-tag effects into `output`.
     - Failure modes: None; an already-finished document is unchanged.
     */
    mutating func finish() {
        while stack.count > 1 {
            pop()
        }
    }

    /**
     Resolves or creates one document-local TagSoup type for a repaired QName.

     - Parameter repairedName: Exact `Parser.makeName` result.
     - Returns: Pinned declaration or stable runtime bogon for this document.
     - Side effects: May insert one bogon keyed by Android root-lowercase identity.
     - Failure modes: Schema misses intentionally create unrestricted bogons.
     */
    private mutating func elementType(
        for repairedName: String
    ) -> SwordTagSoupHTMLSchema.ElementType {
        if let known = SwordTagSoupHTMLSchema.knownElement(named: repairedName) {
            return known
        }
        let key = SwordJavaTextCompatibility.lowercasedRoot(repairedName)
        if let existing = bogons[key] { return existing }
        let created = SwordTagSoupHTMLSchema.bogon(named: repairedName)
        bogons[key] = created
        return created
    }

    /**
     Rectifies one incoming type, emitting it and any natural parents in parser order.

     - Parameters:
       - incoming: Schema type requested by text or start-tag input.
       - emitIncomingElement: Whether the requested type itself receives a parser callback.
     - Returns: True when current/synthesized structure can contain the input.
     - Side effects: May pop/restart stack elements and emit balanced visible callbacks.
     - Failure modes: Returns false when no stack ancestor/natural-parent chain can contain input.
     */
    private mutating func rectify(
        _ incoming: SwordTagSoupHTMLSchema.ElementType,
        emitIncomingElement: Bool = true,
        attributes: [String: String] = [:]
    ) -> Bool {
        var ignored = false
        return rectify(
            incoming,
            emitIncomingElement: emitIncomingElement,
            attributes: attributes,
            enteredCDATA: &ignored
        )
    }

    /**
     Rectifies one type while reporting whether any emitted element enters scanner CDATA.

     - Parameters:
       - incoming: Schema type requested by text or start-tag input.
       - emitIncomingElement: Whether the requested type itself is pushed.
       - enteredCDATA: Set true if any emitted declaration carries TagSoup's CDATA flag.
     - Returns: True when the parser found or synthesized a valid containing chain.
     - Side effects: Mutates live/saved stacks and visible output in parser callback order.
     - Failure modes: Returns false without emitting when containment cannot be rectified.
     */
    private mutating func rectify(
        _ incoming: SwordTagSoupHTMLSchema.ElementType,
        emitIncomingElement: Bool = true,
        attributes: [String: String] = [:],
        enteredCDATA: inout Bool
    ) -> Bool {
        var chain = [incoming]
        var candidate = incoming
        var containingIndex = stack.lastIndex { $0.type.canContain(candidate) }
        while containingIndex == nil,
              let parentName = candidate.parentName,
              let parent = SwordTagSoupHTMLSchema.element(namedCanonicalName: parentName) {
            chain.insert(parent, at: 0)
            candidate = parent
            containingIndex = stack.lastIndex { $0.type.canContain(candidate) }
        }
        guard let containingIndex else { return false }

        while stack.count - 1 > containingIndex {
            restartablyPop()
        }
        for (index, type) in chain.enumerated() {
            if emitIncomingElement || index < chain.count - 1 {
                let emittedAttributes = index == chain.count - 1 ? attributes : [:]
                push(type, attributes: emittedAttributes)
                if type.flags & SwordTagSoupHTMLSchema.cdataFlag != 0 {
                    enteredCDATA = true
                }
            }
            let next = index + 1 < chain.count ? chain[index + 1] : nil
            restart(nextElement: next)
        }
        return true
    }

    /**
     Restarts saved inline elements while current and incoming containment both allow it.

     - Parameter nextElement: Optional next synthesized type that the restart candidate must contain.
     - Side effects: Moves eligible declarations from `saved` to the live stack and emits starts.
     - Failure modes: Stops deterministically at the first ineligible candidate.
     */
    private mutating func restart(nextElement: SwordTagSoupHTMLSchema.ElementType?) {
        while let candidate = saved.last,
              stack.last?.type.canContain(candidate.type) == true,
              nextElement == nil || candidate.type.canContain(nextElement!) {
            saved.removeLast()
            push(candidate.type, attributes: candidate.attributes)
        }
    }

    /**
     Pops one element and saves restartable inline structure for later rectification.

     - Side effects: Emits one end callback and may append its type to `saved`.
     - Failure modes: An empty stack is a no-op; the synthetic root is protected by `pop`.
     */
    private mutating func restartablyPop() {
        guard let popped = stack.last else { return }
        pop()
        if popped.type.flags & SwordTagSoupHTMLSchema.restartFlag != 0 {
            saved.append(popped)
        }
    }

    /**
     Pushes one parser element and emits its Android start callback.

     - Parameter type: Pinned schema or document-local bogon declaration.
     - Side effects: Extends `stack` and may append visible margins/object replacement text.
     - Failure modes: None.
     */
    private mutating func push(
        _ type: SwordTagSoupHTMLSchema.ElementType,
        attributes: [String: String] = [:]
    ) {
        stack.append(OpenElement(type: type, attributes: attributes))
        handleStartTag(type.localName, attributes: attributes)
    }

    /**
     Closes the current eligible parser element without restart bookkeeping.

     - Side effects: Pops and emits end callbacks, drains preclosed ancestors, then restarts eligible
       inline structure.
     - Failure modes: Direct children of the synthetic root are deliberately retained, matching
       TagSoup's `etag_basic` root guard.
     */
    private mutating func closeCurrentElement() {
        guard stack.count >= 3 else { return }
        pop()
        while stack.last?.isPreclosed == true { pop() }
        restart(nextElement: nil)
    }

    /**
     Pops one parser element and emits its Android end callback.

     - Side effects: Removes the live stack tail and may append visible block/br output.
     - Failure modes: The synthetic root is never removed; root-only input is a no-op.
     */
    private mutating func pop() {
        guard stack.count > 1 else { return }
        let popped = stack.removeLast()
        handleEndTag(popped.type.localName, attributes: popped.attributes)
    }

    /**
     Applies visible-string effects of Android's HTML start-tag handler.

     - Parameter localName: SAX local name after QName repair/schema lookup.
     - Side effects: Appends image replacement text or opens a legacy block-margin marker.
     - Failure modes: Unsupported tags have no visible effect.
     */
    private mutating func handleStartTag(
        _ localName: String,
        attributes: [String: String]
    ) {
        if javaTagEquals(localName, "img") {
            appendVisibleCharacters("\u{FFFC}")
            return
        }

        if visibleBlockName(for: localName) != nil {
            appendNewlines(minimum: 2)
            visibleBlockMarkers.append(localName)
        }

        guard collectFormatting else { return }

        if visibleBlockName(for: localName) != nil,
           let alignment = cssAlignment(attributes["style"]) {
            openSpan(.alignment, style: .textAlignment(alignment))
        }

        if javaTagEquals(localName, "strong") || javaTagEquals(localName, "b") {
            openSpan(.bold, style: .bold)
        } else if ["em", "cite", "dfn", "i"].contains(where: {
            javaTagEquals(localName, $0)
        }) {
            openSpan(.italic, style: .italic)
        } else if javaTagEquals(localName, "big") {
            openSpan(.big, style: .relativeSize(1.25))
        } else if javaTagEquals(localName, "small") {
            openSpan(.small, style: .relativeSize(0.8))
        } else if javaTagEquals(localName, "font") {
            if let color = androidHTMLColor(attributes["color"]) {
                openSpan(.foregroundColor, style: .foregroundARGB(color))
            }
            if let face = attributes["face"], !face.isEmpty {
                openSpan(.fontFamily, style: .fontFamily(face))
            }
        } else if javaTagEquals(localName, "blockquote") {
            openSpan(.quote, style: .quote)
        } else if javaTagEquals(localName, "tt") {
            openSpan(.monospace, style: .monospace)
        } else if javaTagEquals(localName, "a") {
            openSpan(.link, style: attributes["href"].map {
                SwordHTMLFormattedTextProjection.Style.link($0)
            })
        } else if javaTagEquals(localName, "u") {
            openSpan(.underline, style: .underline)
        } else if ["del", "s", "strike"].contains(where: {
            javaTagEquals(localName, $0)
        }) {
            openSpan(.strikethrough, style: .strikethrough)
        } else if javaTagEquals(localName, "sup") {
            openSpan(.superscript, style: .superscript)
        } else if javaTagEquals(localName, "sub") {
            openSpan(.subscriptMark, style: .subscriptStyle)
        } else if javaTagEquals(localName, "li") {
            openSpan(.bullet, style: .bullet)
        } else if let level = headingLevel(for: localName) {
            let sizes = [1.5, 1.4, 1.3, 1.2, 1.1, 1.0]
            openSpan(.heading, style: .relativeSize(sizes[level]))
            openSpan(.bold, style: .bold)
        }

        if ["p", "span", "li"].contains(where: { javaTagEquals(localName, $0) }) {
            if let foreground = cssColor(named: "color", in: attributes["style"]) {
                openSpan(.foregroundColor, style: .foregroundARGB(foreground))
            }
            if let background = cssBackgroundColor(in: attributes["style"]) {
                openSpan(.backgroundColor, style: .backgroundARGB(background))
            }
            if cssHasLineThrough(attributes["style"]) {
                openSpan(.strikethrough, style: .strikethrough)
            }
        }
    }

    /**
     Applies visible-string effects of Android's HTML end-tag handler.

     - Parameters:
       - localName: SAX local name of the parser-emitted close.
       - attributes: Exact attributes retained with the matching parser start event.
     - Side effects: Appends a br newline or closes the latest legacy block marker with margins.
     - Failure modes: Unsupported/unmatched visible handlers have no effect.
     */
    private mutating func handleEndTag(
        _ localName: String,
        attributes: [String: String]
    ) {
        if javaTagEquals(localName, "br") {
            output.append("\n")
            outputUTF16Count += 1
            return
        }

        guard collectFormatting else {
            if visibleBlockName(for: localName) != nil,
               !visibleBlockMarkers.isEmpty {
                appendNewlines(minimum: 2)
                visibleBlockMarkers.removeLast()
            }
            return
        }

        if ["p", "span", "li"].contains(where: { javaTagEquals(localName, $0) }) {
            if cssHasLineThrough(attributes["style"]) {
                closeSpan(.strikethrough)
            }
            if cssBackgroundColor(in: attributes["style"]) != nil {
                closeSpan(.backgroundColor)
            }
            if cssColor(named: "color", in: attributes["style"]) != nil {
                closeSpan(.foregroundColor)
            }
        }

        if javaTagEquals(localName, "strong") || javaTagEquals(localName, "b") {
            closeSpan(.bold)
        } else if ["em", "cite", "dfn", "i"].contains(where: {
            javaTagEquals(localName, $0)
        }) {
            closeSpan(.italic)
        } else if javaTagEquals(localName, "big") {
            closeSpan(.big)
        } else if javaTagEquals(localName, "small") {
            closeSpan(.small)
        } else if javaTagEquals(localName, "font") {
            if let face = attributes["face"], !face.isEmpty {
                closeSpan(.fontFamily)
            }
            if androidHTMLColor(attributes["color"]) != nil {
                closeSpan(.foregroundColor)
            }
        } else if javaTagEquals(localName, "blockquote") {
            // Android ends the block before converting the paragraph-style marker.
        } else if javaTagEquals(localName, "tt") {
            closeSpan(.monospace)
        } else if javaTagEquals(localName, "a") {
            closeSpan(.link)
        } else if javaTagEquals(localName, "u") {
            closeSpan(.underline)
        } else if ["del", "s", "strike"].contains(where: {
            javaTagEquals(localName, $0)
        }) {
            closeSpan(.strikethrough)
        } else if javaTagEquals(localName, "sup") {
            closeSpan(.superscript)
        } else if javaTagEquals(localName, "sub") {
            closeSpan(.subscriptMark)
        } else if headingLevel(for: localName) != nil {
            closeSpan(.bold)
            closeSpan(.heading)
        }

        if visibleBlockName(for: localName) != nil,
           !visibleBlockMarkers.isEmpty {
            appendNewlines(minimum: 2)
            visibleBlockMarkers.removeLast()
            if cssAlignment(attributes["style"]) != nil {
                closeSpan(.alignment, paragraphStyle: true)
            }
        }

        if javaTagEquals(localName, "li") {
            closeSpan(.bullet, paragraphStyle: true)
        } else if javaTagEquals(localName, "blockquote") {
            closeSpan(.quote, paragraphStyle: true)
        }
    }

    /// Opens one Android handler marker at the current Java UTF-16 output boundary.
    private mutating func openSpan(
        _ kind: SpanMarkerKind,
        style: SwordHTMLFormattedTextProjection.Style?
    ) {
        spanMarkers.append(SpanMarker(kind: kind, startUTF16: outputUTF16Count, style: style))
    }

    /** Converts Android's most recently opened marker of a class into a finished span. */
    private mutating func closeSpan(_ kind: SpanMarkerKind, paragraphStyle: Bool = false) {
        guard let index = spanMarkers.lastIndex(where: { $0.kind == kind }) else { return }
        let marker = spanMarkers.remove(at: index)
        guard let style = marker.style else { return }
        var end = outputUTF16Count
        if paragraphStyle, end >= 2, output.utf16.suffix(2).allSatisfy({ $0 == 0x0A }) {
            end -= 1
        }
        guard marker.startUTF16 < end else { return }
        spans.append(.init(startUTF16: marker.startUTF16, endUTF16: end, style: style))
    }

    /// Resolves Android's case-insensitive `h1`...`h6` branch to its zero-based level.
    private func headingLevel(for localName: String) -> Int? {
        (1...6).first { javaTagEquals(localName, "h\($0)") }.map { $0 - 1 }
    }

    /// Matches Android's CSS `text-decoration: line-through` declaration without regex parsing.
    private func cssHasLineThrough(_ style: String?) -> Bool {
        cssValue(named: "text-decoration", in: style)?
            .caseInsensitiveCompare("line-through") == .orderedSame
    }

    /// Resolves Android's block `text-align` values from one inline CSS declaration.
    private func cssAlignment(
        _ style: String?
    ) -> SwordHTMLFormattedTextProjection.TextAlignment? {
        guard let value = cssValue(named: "text-align", in: style) else { return nil }
        if value.caseInsensitiveCompare("start") == .orderedSame { return .start }
        if value.caseInsensitiveCompare("center") == .orderedSame { return .center }
        if value.caseInsensitiveCompare("end") == .orderedSame { return .end }
        return nil
    }

    /// Resolves one CSS color property through Android's legacy color parser.
    private func cssColor(named name: String, in style: String?) -> UInt32? {
        androidHTMLColor(cssValue(named: name, in: style))
    }

    /// Resolves Android's `background`/`background-color` CSS aliases in source order.
    private func cssBackgroundColor(in style: String?) -> UInt32? {
        guard let style else { return nil }
        for declaration in style.split(separator: ";") {
            let fields = declaration.split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let name = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.caseInsensitiveCompare("background") == .orderedSame
                    || name.caseInsensitiveCompare("background-color") == .orderedSame else {
                continue
            }
            let value = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            return androidHTMLColor(value)
        }
        return nil
    }

    /// Returns the first non-whitespace token for one case-insensitive CSS property.
    private func cssValue(named name: String, in style: String?) -> String? {
        guard let style else { return nil }
        for declaration in style.split(separator: ";") {
            let fields = declaration.split(separator: ":", maxSplits: 1)
            guard fields.count == 2,
                  fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(name) == .orderedSame else {
                continue
            }
            return fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        return nil
    }

    /**
     Parses Android legacy `Html` color names, hex strings, and `XmlUtils` numeric forms.

     The returned alpha is forced opaque exactly as `HtmlToSpannedConverter` does after parsing.
     */
    private func androidHTMLColor(_ source: String?) -> UInt32? {
        guard let source, !source.isEmpty else { return nil }
        let names: [String: UInt32] = [
            "black": 0xFF00_0000, "darkgray": 0xFF44_4444, "darkgrey": 0xFF44_4444,
            "gray": 0xFF88_8888, "grey": 0xFF88_8888,
            "lightgray": 0xFFCC_CCCC, "lightgrey": 0xFFCC_CCCC,
            "white": 0xFFFF_FFFF, "red": 0xFFFF_0000, "green": 0xFF00_FF00,
            "blue": 0xFF00_00FF, "yellow": 0xFFFF_FF00, "cyan": 0xFF00_FFFF,
            "aqua": 0xFF00_FFFF, "magenta": 0xFFFF_00FF, "fuchsia": 0xFFFF_00FF,
            "lime": 0xFF00_FF00, "maroon": 0xFF80_0000, "navy": 0xFF00_0080,
            "olive": 0xFF80_8000, "purple": 0xFF80_0080, "silver": 0xFFC0_C0C0,
            "teal": 0xFF00_8080,
        ]
        if source.first?.isLetter == true {
            return names[source.lowercased()]
        }
        if source.hasPrefix("#"), (source.count == 7 || source.count == 9),
           let value = UInt32(source.dropFirst(), radix: 16) {
            return value | 0xFF00_0000
        }

        var digits = source[...]
        var sign: Int64 = 1
        if digits.first == "-" {
            sign = -1
            digits = digits.dropFirst()
        }
        let radix: Int
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            radix = 16
            digits = digits.dropFirst(2)
        } else if digits.hasPrefix("#") {
            radix = 16
            digits = digits.dropFirst()
        } else if digits.count > 1, digits.first == "0" {
            radix = 8
            digits = digits.dropFirst()
        } else {
            radix = 10
        }
        guard let magnitude = Int64(digits, radix: radix),
              let signed = Int32(exactly: magnitude * sign) else { return nil }
        return UInt32(bitPattern: signed) | 0xFF00_0000
    }

    /**
     Resolves one local name against Android's legacy-margin block handler set.

     - Parameter localName: Repaired SAX local name.
     - Returns: Canonical ASCII handler name, or nil when the tag has no visible block callback.
     - Side effects: Loads pinned character mappings on first comparison.
     - Failure modes: Resource failure yields no Unicode case matches.
     */
    private func visibleBlockName(for localName: String) -> String? {
        ["p", "ul", "li", "div", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6"]
            .first { javaTagEquals(localName, $0) }
    }

    /**
     Compares one handler-local tag using Android `String.equalsIgnoreCase`.

     - Parameters:
       - lhs: Repaired source local name.
       - rhs: Canonical ASCII Android handler name.
     - Returns: Pinned non-expanding per-UTF16 comparison result.
     - Side effects: Loads compatibility mappings on first use.
     - Failure modes: None after resource validation.
     */
    private func javaTagEquals(_ lhs: String, _ rhs: String) -> Bool {
        SwordJavaTextCompatibility.equalsIgnoreCase(lhs, rhs)
    }

    /**
     Appends Android character callbacks with ASCII-space/newline collapse per scalar boundary.

     - Parameter value: One scanner callback after entity/control normalization.
     - Side effects: Extends `output`, suppressing leading/duplicate ASCII spaces and newlines while
       retaining tabs and non-ASCII whitespace.
     - Failure modes: Empty callbacks are a no-op.
     */
    private mutating func appendVisibleCharacters(_ value: String) {
        for scalar in value.unicodeScalars {
            if scalar.value == 0x20 || scalar.value == 0x0A {
                let predecessor = output.utf16.last ?? 0x0A
                guard predecessor != 0x20, predecessor != 0x0A else { continue }
                output.append(" ")
                outputUTF16Count += 1
            } else {
                output.unicodeScalars.append(scalar)
                outputUTF16Count += scalar.value > 0xFFFF ? 2 : 1
            }
        }
    }

    /**
     Ensures nonempty output ends with Android legacy mode's requested block margin.

     - Parameter minimum: Minimum trailing newline count requested by the handler.
     - Side effects: Appends only missing newline characters.
     - Failure modes: Empty output and already-satisfied margins are unchanged.
     */
    private mutating func appendNewlines(minimum: Int) {
        guard !output.isEmpty else { return }
        let existing = output.utf16.reversed().prefix { $0 == 0x0A }.count
        guard existing < minimum else { return }
        let added = minimum - existing
        output += String(repeating: "\n", count: added)
        outputUTF16Count += added
    }
}
