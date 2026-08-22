import Foundation

/**
 Replays TagSoup's schema-backed element repair into Android `HtmlToSpannedConverter` visible text.

 The scanner is intentionally separate: this state owns document-local bogons, parser
 rectification/restart stacks, synthetic start/end events, and the small subset of Android span
 callbacks that change the stored plain string.
 */
struct SwordTagSoupVisibleDocument {
    /**
     Stores one live TagSoup parser element and its deferred-close state.

     Instances mutate only inside the owning document stack, perform no I/O, and cannot fail;
     `isPreclosed` preserves `F_NOFORCE` close ordering until the blocking structure is removed.
     */
    private struct OpenElement {
        /// Pinned schema or document-local bogon declaration.
        let type: SwordTagSoupHTMLSchema.ElementType
        /// Whether an enclosing `F_NOFORCE` close deferred this element.
        var isPreclosed = false
    }

    /// Parser stack from synthetic root through the current element.
    private var stack: [OpenElement]
    /// Restartable inline elements popped above repaired structure, newest last.
    private var saved: [SwordTagSoupHTMLSchema.ElementType] = []
    /// Runtime bogon declarations retained by Android-lowercased QName within one document.
    private var bogons: [String: SwordTagSoupHTMLSchema.ElementType] = [:]
    /// Visible output produced by Android's HTML handler callbacks.
    private(set) var output = ""
    /// Shared Android `Newline` markers opened by visible block handlers.
    private var visibleBlockMarkers: [String] = []

    /**
     Creates one parser document rooted at TagSoup's generated synthetic root.

     - Side effects: Loads the pinned schema on first use and initializes in-memory parser stacks.
     - Failure modes: Missing schema data falls back to an unrestricted synthetic root; resource
       integrity tests prevent that degraded state from shipping.
     */
    init() {
        let root = SwordTagSoupHTMLSchema.element(namedCanonicalName: "<root>")
            ?? SwordTagSoupHTMLSchema.bogon(named: "<root>")
        stack = [OpenElement(type: root)]
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
    mutating func startTag(repairedName: String, isSelfClosing: Bool) -> String? {
        let type = elementType(for: repairedName)
        var enteredCDATA = false
        guard rectify(type, enteredCDATA: &enteredCDATA) else { return nil }
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
        emitIncomingElement: Bool = true
    ) -> Bool {
        var ignored = false
        return rectify(incoming, emitIncomingElement: emitIncomingElement, enteredCDATA: &ignored)
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
                push(type)
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
              stack.last?.type.canContain(candidate) == true,
              nextElement == nil || candidate.canContain(nextElement!) {
            saved.removeLast()
            push(candidate)
        }
    }

    /**
     Pops one element and saves restartable inline structure for later rectification.

     - Side effects: Emits one end callback and may append its type to `saved`.
     - Failure modes: An empty stack is a no-op; the synthetic root is protected by `pop`.
     */
    private mutating func restartablyPop() {
        guard let popped = stack.last?.type else { return }
        pop()
        if popped.flags & SwordTagSoupHTMLSchema.restartFlag != 0 {
            saved.append(popped)
        }
    }

    /**
     Pushes one parser element and emits its Android start callback.

     - Parameter type: Pinned schema or document-local bogon declaration.
     - Side effects: Extends `stack` and may append visible margins/object replacement text.
     - Failure modes: None.
     */
    private mutating func push(_ type: SwordTagSoupHTMLSchema.ElementType) {
        stack.append(OpenElement(type: type))
        handleStartTag(type.localName)
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
        handleEndTag(popped.type.localName)
    }

    /**
     Applies visible-string effects of Android's HTML start-tag handler.

     - Parameter localName: SAX local name after QName repair/schema lookup.
     - Side effects: Appends image replacement text or opens a legacy block-margin marker.
     - Failure modes: Unsupported tags have no visible effect.
     */
    private mutating func handleStartTag(_ localName: String) {
        if javaTagEquals(localName, "img") {
            appendVisibleCharacters("\u{FFFC}")
        } else if visibleBlockName(for: localName) != nil {
            appendNewlines(minimum: 2)
            visibleBlockMarkers.append(localName)
        }
    }

    /**
     Applies visible-string effects of Android's HTML end-tag handler.

     - Parameter localName: SAX local name of the parser-emitted close.
     - Side effects: Appends a br newline or closes the latest legacy block marker with margins.
     - Failure modes: Unsupported/unmatched visible handlers have no effect.
     */
    private mutating func handleEndTag(_ localName: String) {
        if javaTagEquals(localName, "br") {
            output.append("\n")
        } else if visibleBlockName(for: localName) != nil,
                  !visibleBlockMarkers.isEmpty {
            appendNewlines(minimum: 2)
            visibleBlockMarkers.removeLast()
        }
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
            } else {
                output.unicodeScalars.append(scalar)
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
        output += String(repeating: "\n", count: minimum - existing)
    }
}
