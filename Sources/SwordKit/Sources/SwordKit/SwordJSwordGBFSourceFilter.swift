// SwordJSwordGBFSourceFilter.swift -- Pinned JSword GBF source projection

import Foundation

/**
 Ports pinned JSword `GBFFilter`, `GBFTagBuilders`, and `GBFTags` into SwordKit.

 GBF is a tolerant tag grammar rather than XML. Android Java-trims the complete record, recognizes
 only tags whose first Java `char` is uppercase, ignores unknown GBF commands, maintains a nested
 OSIS stack, and attaches Strong/morph metadata to the preceding text or element. Keeping that
 grammar separate from ThML/OSIS prevents libsword `GBFOSIS` behavior from drifting across reader,
 Search, speech, AI, and dictionary paths.
 */
enum SwordJSwordGBFSourceFilter {
    /// Java regular expression that identifies versification-boundary `W` tags Android ignores.
    private static let alternateVersificationTag = try? NSRegularExpression(
        pattern: #"^WT?[GH] ?[0-9]+[-:][0-9abc-]+$"#
    )

    /// GBF punctuation run that Android separates only when it begins one text token.
    private static let separatorUnits = Set(" ,:;.?!".utf16)

    /** One tokenizer output consumed in exact source order. */
    private enum Token {
        /// Source text, including malformed angle-bracket sequences treated as visible text.
        case text(String)
        /// Uppercase-led candidate GBF command without surrounding angle brackets.
        case tag(String)
    }

    /**
     Converts one decoded GBF record into JSword-compatible structural OSIS.

     - Parameters:
       - source: Exact backend-extracted source after native encoding conversion only.
       - resolveReference: Passage-key resolver matching Android `book.getKey` acceptance.
     - Returns: Deterministically serialized OSIS children in source order.
     - Side effects: Allocates and mutates a bounded in-memory XML stack and invokes the supplied
       resolver for `RX` commands; no module cursor or persisted state is changed.
     - Failure modes: Unknown/malformed commands are ignored or retained as text according to the
       pinned tokenizer. Unresolvable references remain structural `reference` elements without an
       invented `osisRef`. Android runtime-failure cases return empty output without throwing.
     */
    static func convert(
        _ source: String,
        resolveReference: (String) -> String
    ) -> String {
        let root = SwordXMLNode.element(name: "div", attributes: [:])
        var stack = [root]
        guard let tokens = tokenize(SwordJavaStringIdentity.trim(source)) else { return "" }
        var conversionFailed = false
        for token in tokens {
            switch token {
            case .text(let value):
                appendText(value, stack: &stack, root: root)
            case .tag(let name):
                if !applyTag(
                    name,
                    stack: &stack,
                    root: root,
                    resolveReference: resolveReference
                ) {
                    conversionFailed = true
                }
            }
            if conversionFailed { return "" }
        }
        guard !stack.isEmpty else { return "" }
        return root.children.map { $0.serializedXML() }.joined()
    }

    /**
     Tokenizes one Java-trimmed GBF string with pinned UTF-16 index and uppercase semantics.

     - Parameter source: Java-trimmed decoded GBF record.
     - Returns: Ordered text and uppercase-led tag candidates; unknown candidates remain tags so
       the handler can omit them like Android. Returns nil for Android's terminal-opening-bracket
       runtime failure so the public nonthrowing conversion boundary fails closed.
     - Side effects: Allocates bounded UTF-16 slices only.
     - Failure modes: Unmatched angle brackets remain visible text except a terminal opening
       bracket, which reproduces Android's observable failed conversion as nil.
     */
    private static func tokenize(_ source: String) -> [Token]? {
        var remains = Array(source.utf16)
        var tokens: [Token] = []

        while true {
            let left = remains.firstIndex(of: 0x003C)
            let rightSearchStart = max((left ?? -1) + 1, 0)
            let right = rightSearchStart < remains.count
                ? remains[rightSearchStart...].firstIndex(of: 0x003E)
                : nil

            guard let left, let right else {
                if let left, left + 1 == remains.count, right == nil {
                    return nil
                }
                let position = max(left ?? -1, right ?? -1) + 1
                if position == 0 || position == remains.count {
                    tokens.append(.text(string(remains[remains.startIndex..<remains.endIndex])))
                    break
                }
                tokens.append(.text(string(remains[remains.startIndex..<position])))
                remains.removeFirst(position)
                continue
            }

            let firstTagUnit = left + 1
            guard firstTagUnit < remains.count,
                  SwordJavaTextCompatibility.isUpperCase(remains[firstTagUnit]) else {
                tokens.append(.text(string(remains[remains.startIndex...right])))
                remains.removeFirst(right + 1)
                continue
            }

            if left > 0 {
                appendLeadingTextTokens(
                    remains[remains.startIndex..<left],
                    to: &tokens
                )
            }
            if right > firstTagUnit {
                tokens.append(.tag(string(remains[firstTagUnit..<right])))
            }
            remains.removeFirst(right + 1)
        }
        return tokens
    }

    /**
     Applies JSword's punctuation-prefix split to source text immediately before a GBF command.

     - Parameters:
       - units: Nonempty or empty UTF-16 text before the command.
       - tokens: Token list receiving at most one leading-separator token and one remainder token.
     - Side effects: Appends text tokens in source order.
     - Failure modes: None; empty input appends nothing.
     */
    private static func appendLeadingTextTokens(
        _ units: ArraySlice<UInt16>,
        to tokens: inout [Token]
    ) {
        guard let first = units.first else { return }
        var split = units.startIndex
        if separatorUnits.contains(first) {
            split = units.index(after: split)
            while split < units.endIndex, separatorUnits.contains(units[split]) {
                split = units.index(after: split)
            }
            if split > units.startIndex {
                tokens.append(.text(string(units[units.startIndex..<split])))
            }
        }
        if split < units.endIndex {
            tokens.append(.text(string(units[split..<units.endIndex])))
        }
    }

    /**
     Applies one recognized GBF command to the mutable JSword-equivalent OSIS stack.

     - Parameters:
       - name: Command body without angle brackets.
       - stack: Root-first open-node stack; the last node receives new content.
       - root: Stable wrapping `div` whose children become the returned fragment.
       - resolveReference: Passage resolver used only by `RX`.
     - Side effects: Mutates newly allocated nodes and the open stack; may call the resolver.
     - Returns: True when Android completes the tag handler; false when its stack access would fail.
     - Failure modes: Unknown commands and Android-policed unmatched closing tags are ignored.
       Stack-underflow runtime failures return false so the public conversion boundary fails closed.
     */
    private static func applyTag(
        _ name: String,
        stack: inout [SwordXMLNode],
        root: SwordXMLNode,
        resolveReference: (String) -> String
    ) -> Bool {
        if isAlternateVersificationTag(name) { return true }
        let units = Array(name.utf16)
        guard units.count >= 2 else { return true }
        let prefix = string(units[0..<2])

        switch prefix {
        case "FB": return push(node("hi", ["type": "bold"]), onto: &stack)
        case "FI": return push(node("hi", ["type": "italic"]), onto: &stack)
        case "FR": return push(node("q", ["who": "Jesus"]), onto: &stack)
        case "FU": return push(node("hi", ["type": "underline"]), onto: &stack)
        case "RX":
            let request = string(units.dropFirst(2))
            let resolved = resolveReference(request)
            return push(
                node("reference", resolved.isEmpty ? [:] : ["osisRef": resolved]),
                onto: &stack
            )
        case "Fb", "Fi", "Fr", "Fu", "Rx", "Ts", "Tb", "Th", "Tt", "Fo", "Pp":
            if !stack.isEmpty { stack.removeLast() }
        case "CL": appendEmptyElement("lb", to: &stack)
        case "CM": appendEmptyElement(stack.isEmpty ? "lb" : "p", to: &stack)
        case "RF": return push(node("note", ["type": "x-StudyNote"]), onto: &stack)
        case "Rf": return closeFootnote(stack: &stack)
        case "RB": return push(node("note", ["type": "x-StudyNote"]), onto: &stack)
        case "TS", "TH": return push(node("title"), onto: &stack)
        case "TB":
            return push(node("title", [
                "canonical": "true",
                "subType": "x-preverse",
                "type": "psalm",
            ]), onto: &stack)
        case "TT": return push(node("title", ["type": "main"]), onto: &stack)
        case "BA", "BC", "BI", "BN", "BO", "BP", "JC", "JL": break
        case "JR": return push(node("seg", ["type": "text-align: right;"]), onto: &stack)
        case "FO": return push(node("q"), onto: &stack)
        case "PP": return push(node("lg"), onto: &stack)
        case "WH", "WG": return applyStrongWord(name, stack: &stack)
        case "WT": return applyStrongMorph(name, stack: &stack)
        case "CG": appendText("&gt;", stack: &stack, root: root)
        case "CT": appendText("&lt;", stack: &stack, root: root)
        default: break
        }
        return true
    }

    /**
     Appends one GBF text token after JSword's explicit `XMLUtil.escape` pass.

     - Parameters:
       - value: Exact source token or synthetic escape-tag entity text.
       - stack: Mutable open-node stack.
       - root: Stable wrapping container used when a `w` node is current.
     - Side effects: Appends one text node to the current element, root, or detached malformed stack.
     - Failure modes: None; an empty stack retains detached text but cannot alter returned content.
     */
    private static func appendText(
        _ value: String,
        stack: inout [SwordXMLNode],
        root: SwordXMLNode
    ) {
        let text = SwordXMLNode.text(javaXMLEscape(value))
        guard let current = stack.last else {
            stack.append(text)
            return
        }
        if current.isElement(exactlyNamed: "w") {
            root.children.append(text)
        } else if current.isElement {
            current.children.append(text)
        }
    }

    /**
     Attaches a Strong lemma to the preceding current-container child like `StrongsWordTag`.

     - Parameters:
       - name: Java-trimmed `WH`/`WG` command body.
       - stack: Current open-element stack; its final root element receives an empty Strong word
         when no predecessor exists.
     - Returns: True when Android can access its current stack entry; false on stack underflow.
     - Side effects: Wraps a preceding text node or mutates/appends one `w` element.
     - Failure modes: Empty stacks return false to reproduce Android's failed stack access.
     */
    private static func applyStrongWord(
        _ name: String,
        stack: inout [SwordXMLNode]
    ) -> Bool {
        guard let current = stack.last else { return false }
        let trimmed = SwordJavaStringIdentity.trim(name)
        var word = precedingWord(in: current)
        if word == nil {
            word = node("w")
            if let root = stack.first, root.isElement {
                root.children.append(word!)
            }
        }
        let lemma = "strong:" + string(Array(trimmed.utf16).dropFirst())
        let combined = [word?.attribute(named: "lemma"), lemma]
            .compactMap { $0 }
            .joined(separator: " ")
        word?.setAttribute(named: "lemma", value: combined)
        return true
    }

    /**
     Attaches a Strong morphology value to the preceding current-container child.

     - Parameters:
       - name: Java-trimmed `WT` command body.
       - stack: Current open-element stack.
     - Side effects: Wraps a preceding text node in `w` or mutates a preceding element's `morph`.
     - Returns: True when Android can access its current stack entry; false on stack underflow.
     - Failure modes: Missing preceding content is ignored like Android data policing; an empty
       stack returns false to reproduce Android's failed stack access.
     */
    private static func applyStrongMorph(
        _ name: String,
        stack: inout [SwordXMLNode]
    ) -> Bool {
        guard let current = stack.last else { return false }
        let trimmed = SwordJavaStringIdentity.trim(name)
        guard let word = precedingWord(in: current) else { return true }
        let morph = "x-StrongsMorph:T" + string(Array(trimmed.utf16).dropFirst(2))
        let combined = [word.attribute(named: "morph"), morph]
            .compactMap { $0 }
            .joined(separator: "|")
        word.setAttribute(named: "morph", value: combined)
        return true
    }

    /**
     Returns or creates the element receiving a Strong/morph attribute.

     - Parameter parent: Current open element whose last child is inspected.
     - Returns: Last child when it is an element, or a new `w` replacing a final text child; nil for
       absent/non-element parents or empty content.
     - Side effects: May replace the parent's last text child with a `w` wrapper.
     - Failure modes: None.
     */
    private static func precedingWord(in parent: SwordXMLNode?) -> SwordXMLNode? {
        guard let parent, parent.isElement, let last = parent.children.last else { return nil }
        if last.isElement { return last }
        guard last.isTextLike else { return nil }
        let word = node("w")
        word.children = [last]
        parent.children[parent.children.count - 1] = word
        return word
    }

    /**
     Closes the current GBF footnote and removes it when it has no content.

     - Parameter stack: Root-first open-node stack.
     - Side effects: Pops one node and may remove that exact node from its new parent.
     - Returns: True when Android completes or data-polices the close; false when removing an empty
       note leaves no parent and Android's next stack access would fail.
     - Failure modes: Empty stacks and non-element popped nodes are ignored; parent underflow after
       an empty note returns false.
     */
    private static func closeFootnote(stack: inout [SwordXMLNode]) -> Bool {
        guard !stack.isEmpty else { return true }
        let popped = stack.removeLast()
        guard popped.isElement else { return true }
        guard popped.children.isEmpty else { return true }
        guard let parent = stack.last else { return false }
        parent.children.removeAll { $0 === popped }
        return true
    }

    /**
     Adds and opens one element beneath the current stack element.

     - Parameters:
       - element: Newly allocated GBF projection node.
       - stack: Root-first open-node stack.
     - Side effects: Appends the element to its parent and pushes it when the parent is an element.
     - Returns: True when Android can access the current stack entry; false on stack underflow.
     - Failure modes: Empty stacks return false; text-topped stacks ignore the element.
     */
    private static func push(_ element: SwordXMLNode, onto stack: inout [SwordXMLNode]) -> Bool {
        guard let parent = stack.last else { return false }
        guard parent.isElement else { return true }
        parent.children.append(element)
        stack.append(element)
        return true
    }

    /**
     Appends one non-opening structural element to the current stack element.

     - Parameters:
       - name: Exact OSIS local name.
       - stack: Mutable root-first stack.
     - Side effects: Appends one empty element or retains it as detached malformed-stack state.
     - Failure modes: None.
     */
    private static func appendEmptyElement(
        _ name: String,
        to stack: inout [SwordXMLNode]
    ) {
        let element = node(name)
        guard let parent = stack.last else {
            stack.append(element)
            return
        }
        if parent.isElement { parent.children.append(element) }
    }

    /**
     Returns whether Android ignores this `W` command as an alternate-versification boundary.

     - Parameter name: Full GBF command body.
     - Returns: True only for the pinned whole-string regular-expression match.
     - Side effects: Runs one bounded in-memory regular expression.
     - Failure modes: A missing compiled expression fails closed as a normal GBF command.
     */
    private static func isAlternateVersificationTag(_ name: String) -> Bool {
        guard let alternateVersificationTag else { return false }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return alternateVersificationTag.firstMatch(in: name, range: range) != nil
    }

    /**
     Applies pinned JSword `XMLUtil.escape` before content enters JDOM-equivalent text storage.

     - Parameter value: Raw GBF text token.
     - Returns: String with `<`, `>`, `&`, and quote replaced by their XML entity spellings.
     - Side effects: None.
     - Failure modes: None; all other Unicode content remains exact.
     */
    private static func javaXMLEscape(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.utf8.count)
        for character in value {
            switch character {
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "&": output += "&amp;"
            case "\"": output += "&quot;"
            default: output.append(character)
            }
        }
        return output
    }

    /** Creates one empty OSIS element with deterministic attributes. */
    private static func node(
        _ name: String,
        _ attributes: [String: String] = [:]
    ) -> SwordXMLNode {
        .element(name: name, attributes: attributes)
    }

    /** Decodes one exact UTF-16 slice with Java-string-compatible replacement behavior. */
    private static func string<C: Collection>(_ units: C) -> String where C.Element == UInt16 {
        String(decoding: units, as: UTF16.self)
    }
}
