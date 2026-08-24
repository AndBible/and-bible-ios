import Foundation

/**
 Canonical OSIS processing result shared by SWORD document readers.
 */
public struct SwordProcessedOSISFragment {
    /// OSIS after Android-compatible `BVA` insertion.
    public let xml: String
    /// OSIS before anchor insertion.
    public let originalXML: String
    /// Local generic-book bookmark anchor range.
    public let contentOrdinalRange: ClosedRange<Int>
    /// Source annotation target, when present.
    public let annotateRef: String?
    /// Text associated with each local anchor ordinal.
    public let anchorTexts: [Int: String]
    /// Android-compatible semantic plain text.
    public let comparablePlainText: String?
    /// Whether the source fragment contains non-whitespace content or structural elements.
    public let hasRenderableContent: Bool
}

/**
 Converts canonical SWORD source XML into the immutable fragment shape Android builds in
 `SwordContentFacade.readOsisFragment`.

 The processor operates on XML nodes rather than rendered text. It preserves source elements,
 attributes, links, and internal anchors, unwraps a commentary verse exactly as Android does, and
 ports Android's stable sentence splitting before assigning `BVA` ordinals.
 */
public enum SwordOSISFragmentProcessor {
    /// Android's immutable sentence target used for generic bookmark anchors.
    private static let targetMaximumLength = 150
    /// Namespace consumed by Vue's `BibleViewAnchor` component.
    private static let xhtmlNamespace = "http://www.w3.org/1999/xhtml"
    /// Parser-only element used to accept an XML fragment with multiple top-level nodes.
    private static let parserRootName = "andbible-fragment-root"

    /**
     Processes one source-format-converted OSIS entry.

     - Parameters:
       - sourceXML: Canonical source-family OSIS returned by the shared backend converter.
       - category: Module category controlling Android's commentary unwrapping rule.
       - moduleInitials: Exact module initials used by Android's source-specific structural repair.
     - Returns: Preserved source XML plus anchored XML and derived metadata.
     - Side effects: None outside temporary in-memory XML nodes.
     - Failure modes: Throws when the source entry is malformed XML.
     */
    public static func process(
        sourceXML: String,
        category: ModuleCategory,
        moduleInitials: String? = nil
    ) throws -> SwordProcessedOSISFragment {
        try process(
            sourceXML: sourceXML,
            category: category,
            moduleInitials: moduleInitials,
            addsAnchors: true,
            requiresDirectCommentaryVerse: false
        )
    }

    /**
     Processes one source fragment with explicit Android category-branch behavior.

     - Parameters:
       - sourceXML: Canonical source nodes before the outer `BookData` div.
       - category: Actual selected-book category controlling commentary unwrapping.
       - moduleInitials: Exact initials used by source-specific structural repair.
       - addsAnchors: Whether Android's category branch invokes `addAnchors`.
       - requiresDirectCommentaryVerse: Whether a commentary category without a direct `verse`
         must fail instead of preserving unrelated source nodes.
     - Returns: Immutable original and payload-ready XML plus derived bookmark metadata.
     - Side effects: None outside temporary in-memory XML nodes.
     - Failure modes: Throws for malformed XML or a required missing commentary verse.
     */
    private static func process(
        sourceXML: String,
        category: ModuleCategory,
        moduleInitials: String?,
        addsAnchors: Bool,
        requiresDirectCommentaryVerse: Bool
    ) throws -> SwordProcessedOSISFragment {
        let repairedSource = androidSourceRepair(sourceXML, moduleInitials: moduleInitials)
        let fragmentRoot = try androidFragmentRoot(
            sourceXML: repairedSource,
            category: category,
            requiresDirectCommentaryVerse: requiresDirectCommentaryVerse
        )
        let originalXML = fragmentRoot.serializedXML()
        let annotateRef = directAnnotateRef(in: fragmentRoot)
        let hasRenderableContent = containsRenderableSourceContent(fragmentRoot)

        var anchorTexts: [Int: String] = [:]
        if addsAnchors {
            addAnchors(to: fragmentRoot, anchorTexts: &anchorTexts)
        }
        let contentRange: ClosedRange<Int>
        if let minimum = anchorTexts.keys.min(), let maximum = anchorTexts.keys.max() {
            contentRange = minimum...maximum
        } else {
            contentRange = 0...0
        }
        let plainText = androidPlainText(from: fragmentRoot)
        fragmentRoot.transformOrdinaryText(SwordHTML4EntityDecoder.decode)
        anchorTexts = anchorTexts.mapValues(SwordHTML4EntityDecoder.decode)
        let xml = fragmentRoot.serializedXML()

        return SwordProcessedOSISFragment(
            xml: xml,
            originalXML: originalXML,
            contentOrdinalRange: contentRange,
            annotateRef: annotateRef,
            anchorTexts: anchorTexts,
            comparablePlainText: plainText.isEmpty ? nil : plainText,
            hasRenderableContent: hasRenderableContent
        )
    }

    /**
     Processes one backend-owned `SwordDictionary` entry with JSword's generated key title.

     `SwordDictionary.getOsisIterator` inserts a hidden `title[type=x-gen]` before every definition,
     including an exact empty body. Android then applies one `addAnchors` pass to that combined OSIS
     tree, so the generated title owns the first BVA ordinal and body ordinals continue after it.
     Keeping this boundary backend-neutral lets native RawLD and Android-compatible SQLite drivers
     share the same payload contract without routing structured source through rendered HTML.

     - Parameters:
       - sourceXML: Canonical source-filtered dictionary body, which may be empty.
       - keyName: Exact resolved `Key.name` inserted into JSword's generated title.
       - moduleInitials: Exact installed initials used by source-specific compatibility repair.
       - category: Actual selected-book category controlling Android's Bible/commentary branches.
     - Returns: Preserved title/body XML plus one Android-compatible anchored projection.
     - Side effects: None outside temporary in-memory XML nodes.
     - Failure modes: Throws when the source body is malformed XML; arbitrary key text is escaped by
       the XML tree serializer and cannot change the generated title structure.
     */
    public static func processDictionarySource(
        sourceXML: String,
        keyName: String,
        moduleInitials: String? = nil,
        category: ModuleCategory = .dictionary
    ) throws -> SwordProcessedOSISFragment {
        let repairedBody = SwordJSwordOSISSourceCompatibility.repairedSourceXML(
            sourceXML,
            moduleInitials: moduleInitials
        )
        let title = SwordXMLNode.element(
            name: "title",
            attributes: ["type": "x-gen"]
        )
        title.children = [.text(keyName)]
        return try process(
            sourceXML: title.serializedXML() + repairedBody,
            category: category,
            moduleInitials: moduleInitials,
            addsAnchors: category != .bible,
            requiresDirectCommentaryVerse: category == .commentary
        )
    }

    /**
     Processes one backend-owned `SwordGenBook` TreeKey through its actual configured category.

     JSword chooses `SwordGenBook` from the driver, independently from an explicit category. Key
     resolution therefore remains TreeKey-based even when metadata says Bible or Commentary;
     category affects only post-BookData projection. Bible skips anchors. Commentary requires and
     unwraps one direct verse only for a leaf TreeKey; parent TreeKeys retain their complete body.
     Every remaining non-Bible result receives the usual one BVA pass.

     - Parameters:
       - sourceXML: Canonical source-filtered TreeKey body, possibly containing multiple roots.
       - moduleInitials: Exact installed initials used by source-specific compatibility repair.
       - category: Actual selected-book category controlling Android's post-read branch.
       - treeKeyCardinality: Selected TreeKey plus descendants; Android's direct-verse rule applies
         only when this value is exactly one.
     - Returns: Canonical original and payload-ready XML under the actual category contract.
     - Side effects: None outside temporary in-memory XML nodes.
     - Failure modes: Throws for malformed XML or a Commentary leaf entry without a direct verse.
     */
    public static func processGenBookSource(
        sourceXML: String,
        moduleInitials: String? = nil,
        category: ModuleCategory,
        treeKeyCardinality: Int = 1
    ) throws -> SwordProcessedOSISFragment {
        try process(
            sourceXML: sourceXML,
            category: category,
            moduleInitials: moduleInitials,
            addsAnchors: category != .bible,
            requiresDirectCommentaryVerse: category == .commentary && treeKeyCardinality == 1
        )
    }

    /**
     Applies source-specific XML repair present in Android's pinned JSword `OSISFilter`.

     JSword repairs the historical `MapM` module when an entry starts inside a closing cell, row, or
     table. The exact check/order is retained here so map entries form the same semantic tree before
     anchoring instead of failing XML parsing on iOS.

     - Parameters:
       - sourceXML: Canonical source fragment before the outer BookData div is created.
       - moduleInitials: Exact installed module initials.
     - Returns: Original XML for ordinary modules, or the minimally reopened `MapM` structure.
     - Side effects: None.
     - Failure modes: None; malformed XML outside JSword's exact `MapM` workaround is left for the
       parser to reject explicitly.
     */
    static func androidSourceRepair(
        _ sourceXML: String,
        moduleInitials: String?
    ) -> String {
        guard moduleInitials == "MapM" else { return sourceXML }
        var repaired = sourceXML
        for tag in ["cell", "row", "table"] {
            let opening = repaired.range(of: "<\(tag)>")
            guard let closing = repaired.range(of: "</\(tag)>") else { continue }
            if opening == nil || opening!.lowerBound > closing.lowerBound {
                repaired = "<\(tag)>" + repaired
            }
        }
        return repaired
    }

    /**
     Derives Android's dictionary orthography/snippet for one preserved OSIS fragment.

     - Parameters:
       - xml: Root `<div>` before `BVA` insertion.
       - key: Exact dictionary key used for prefix cleanup.
     - Returns: Joined direct `orth` values when present; otherwise Android's cleaned, whole-word
       snippet capped around 50 UTF-16 code units.
     - Side effects: Parses and copies XML; the caller's fragment is immutable.
     - Failure modes: Throws if `xml` is malformed.
     */
    static func dictionarySnippet(xml: String, key: String) throws -> String {
        let workingRoot = try parseSingleRoot(xml).deepCopy()
        if let titleIndex = workingRoot.children.firstIndex(where: { child in
            child.isElement(exactlyNamed: "title")
        }) {
            workingRoot.children.remove(at: titleIndex)
        }

        guard let entry = directChildElements(named: "entryFree", in: workingRoot).first else {
            return cleanDictionarySnippet(workingRoot.stringValue, key: key)
        }
        let orthographies = directChildElements(named: "orth", in: entry)
            .map(\.stringValue)
            .filter { !$0.isEmpty }
        if !orthographies.isEmpty {
            return orthographies.joined(separator: " - ")
        }
        return cleanDictionarySnippet(entry.stringValue, key: key)
    }

    /**
     Builds Android's outer `BookData` div and commentary content shape.

     - Parameters:
       - sourceXML: Canonical source nodes, possibly empty or multi-root.
       - category: Module category.
       - requiresDirectCommentaryVerse: Whether a missing direct commentary `verse` must throw.
     - Returns: Mutable `<div>` containing source nodes, or the direct commentary verse children.
     - Side effects: None.
     - Failure modes: Throws when source XML cannot be parsed safely.
     */
    private static func androidFragmentRoot(
        sourceXML: String,
        category: ModuleCategory,
        requiresDirectCommentaryVerse: Bool
    ) throws -> SwordXMLNode {
        let wrapped = "<\(parserRootName)>\(withoutXMLDeclaration(sourceXML))</\(parserRootName)>"
        let parserRoot = try SwordXMLTreeParser.parse(xml: wrapped)
        let fragment = SwordXMLNode.element(name: "div", attributes: [:])
        fragment.children = parserRoot.children

        if category == .commentary {
            guard let verse = directChildElements(named: "verse", in: fragment).first else {
                if requiresDirectCommentaryVerse {
                    throw SwordOSISProcessorError.missingCommentaryVerse
                }
                return fragment
            }
            fragment.children = verse.children
        }
        return fragment
    }

    /**
     Parses XML that already has one root element.

     - Parameter xml: Complete XML element string.
     - Returns: Parsed root element.
     - Side effects: None.
     - Failure modes: Throws for malformed XML or a missing/multiple root element.
     */
    private static func parseSingleRoot(_ xml: String) throws -> SwordXMLNode {
        let wrapped = "<\(parserRootName)>\(withoutXMLDeclaration(xml))</\(parserRootName)>"
        let parserRoot = try SwordXMLTreeParser.parse(xml: wrapped)
        let elements = parserRoot.children.filter(\.isElement)
        let nonWhitespaceText = parserRoot.children.contains { child in
            child.isTextLike && !child.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        guard elements.count == 1, !nonWhitespaceText else {
            throw SwordOSISProcessorError.invalidRootCount(elements.count)
        }
        return elements[0]
    }

    /**
     Removes a leading XML declaration before embedding source nodes in the parser container.

     - Parameter xml: Source XML fragment.
     - Returns: XML without a leading declaration or byte-order mark.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func withoutXMLDeclaration(_ xml: String) -> String {
        let withoutBOM = xml.hasPrefix("\u{FEFF}") ? String(xml.dropFirst()) : xml
        guard let expression = try? NSRegularExpression(
            pattern: #"^\s*<\?xml[^?]*\?>"#,
            options: [.caseInsensitive]
        ) else {
            return withoutBOM
        }
        let range = NSRange(location: 0, length: (withoutBOM as NSString).length)
        return expression.stringByReplacingMatches(
            in: withoutBOM,
            range: range,
            withTemplate: ""
        )
    }

    /**
     Inserts stable `BVA` elements around every non-note, non-whitespace text node.

     - Parameters:
       - root: Mutable Android fragment root.
       - anchorTexts: Destination map populated with exact sentence text by ordinal.
     - Side effects: Replaces matching XML text nodes in `root`.
     - Failure modes: None; unsplittable long text remains one anchor.
     */
    private static func addAnchors(
        to root: SwordXMLNode,
        anchorTexts: inout [Int: String]
    ) {
        var ordinal = 0
        replaceAnchorableText(
            in: root,
            insideNote: false,
            ordinal: &ordinal,
            anchorTexts: &anchorTexts
        )
    }

    /**
     Recursively applies Android's `.//text()[not(ancestor::note)]` anchor rule.

     - Parameters:
       - node: Current mutable element.
       - insideNote: Whether an ancestor has local name `note`.
       - ordinal: Next local anchor ordinal.
       - anchorTexts: Destination text map.
     - Side effects: Replaces anchorable text children in document order.
     - Failure modes: None.
     */
    private static func replaceAnchorableText(
        in node: SwordXMLNode,
        insideNote: Bool,
        ordinal: inout Int,
        anchorTexts: inout [Int: String]
    ) {
        guard node.isElement else { return }
        let descendantsAreInsideNote = insideNote || node.isElement(exactlyNamed: "note")
        var replacement: [SwordXMLNode] = []

        for child in node.children {
            if child.isTextLike,
               !descendantsAreInsideNote,
               !child.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for piece in splitSentences(child.stringValue) {
                    let anchor = SwordXMLNode.element(
                        name: "BVA",
                        attributes: ["xmlns": xhtmlNamespace, "ordinal": String(ordinal)]
                    )
                    anchor.children = [.text(piece)]
                    replacement.append(anchor)
                    anchorTexts[ordinal] = piece
                    ordinal += 1
                }
            } else {
                replaceAnchorableText(
                    in: child,
                    insideNote: descendantsAreInsideNote,
                    ordinal: &ordinal,
                    anchorTexts: &anchorTexts
                )
                replacement.append(child)
            }
        }
        node.children = replacement
    }

    /**
     Ports Android's immutable sentence splitting used by generic bookmark ordinals.

     - Parameter text: One XML text-node value.
     - Returns: Sentence-sized pieces whose concatenation equals `text`.
     - Side effects: None.
     - Failure modes: If the regular expression cannot be compiled, returns the unsplit text.
     */
    static func splitSentences(_ text: String) -> [String] {
        let pattern = #"((\d{2,}|\D)(([.,;:!?。，；][\"'\p{Pf}]?\p{Z}+)|(\p{Z}*\p{Pd}\p{Z}*)))([\"'¡¿\p{Pi}]?\p{L})"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return text.isEmpty ? [] : [text]
        }

        let nsText = text as NSString
        let matches = expression.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        var pieces: [String] = []
        var lastStart = 0
        var current = ""

        for match in matches {
            guard match.numberOfRanges > 6,
                  match.range(at: 1).location != NSNotFound,
                  match.range(at: 6).location != NSNotFound else {
                continue
            }
            current += nsText.substring(with: NSRange(
                location: lastStart,
                length: match.range.location - lastStart
            ))
            current += nsText.substring(with: match.range(at: 1))
            pieces.append(contentsOf: cutLongSentences(current))
            current = nsText.substring(with: match.range(at: 6))
            lastStart = NSMaxRange(match.range)
        }

        if lastStart <= nsText.length {
            current += nsText.substring(from: lastStart)
        }
        if !current.isEmpty {
            pieces.append(contentsOf: cutLongSentences(current))
        }
        return pieces
    }

    /**
     Recursively bisects an overlong sentence near a Unicode word boundary, matching Android.

     - Parameter text: Sentence piece measured in UTF-16 code units.
     - Returns: One or more pieces; concatenation preserves the original text.
     - Side effects: None.
     - Failure modes: Text with no suitable boundary remains unsplit.
     */
    private static func cutLongSentences(_ text: String) -> [String] {
        let nsText = text as NSString
        guard nsText.length > targetMaximumLength else { return [text] }

        let targetLength = nsText.length / 2
        let pattern = "(.{\(targetLength)}\\p{Z}\\p{L}+\\p{Z}+)(\\p{L}+\\p{Z}.*)"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(location: 0, length: nsText.length)
              ),
              match.range(at: 1).location != NSNotFound,
              match.range(at: 2).location != NSNotFound else {
            return [text]
        }

        let first = nsText.substring(to: match.range.location) + nsText.substring(with: match.range(at: 1))
        let second = nsText.substring(with: match.range(at: 2))
        return [first, second].flatMap { piece in
            (piece as NSString).length > Int(Double(targetMaximumLength) * 1.1)
                ? cutLongSentences(piece)
                : [piece]
        }
    }

    /**
     Mirrors Android dictionary key-prefix cleanup and whole-word truncation.

     - Parameters:
       - snippet: Orthography-free entry text.
       - key: Exact dictionary key.
     - Returns: Cleaned snippet, including Android's intentional trailing space behavior.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func cleanDictionarySnippet(_ snippet: String, key: String) -> String {
        var cleaned = snippet.replacingOccurrences(of: "\n", with: " ")
        let snippetCodeUnits = Array(cleaned.utf16)
        let keyCodeUnits = Array(key.utf16)
        if snippetCodeUnits.starts(with: keyCodeUnits) {
            cleaned = (cleaned as NSString).substring(from: keyCodeUnits.count)
        }
        return maximumLettersWholeWords(cleaned)
    }

    /**
     Ports `ChooseDictionaryWord.maxLettersWholeWords`, including its unassigned `dropLast` call.

     - Parameter text: Dictionary entry text.
     - Returns: Whole words until the UTF-16 result reaches 50 characters, plus `...` if needed.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func maximumLettersWholeWords(_ text: String) -> String {
        var words = text.components(separatedBy: " ")
        var result = ""
        while (result as NSString).length < 50, !words.isEmpty {
            result += words.removeFirst() + " "
        }
        return result + (words.isEmpty ? "" : "...")
    }

    /**
     Reads Android's nested direct-child `<div annotateRef>` metadata.

     - Parameter root: Outer `BookData` fragment div.
     - Returns: Non-empty annotation reference, or `nil`.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func directAnnotateRef(in root: SwordXMLNode) -> String? {
        for div in directChildElements(named: "div", in: root) {
            let value = div.attribute(named: "annotateRef") ?? ""
            if !value.isEmpty { return value }
        }
        return nil
    }

    /**
     Determines whether the Android fragment is more than an empty `<div/>`.

     - Parameter root: Outer fragment div.
     - Returns: `true` for any child element or non-whitespace text node.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func containsRenderableSourceContent(_ root: SwordXMLNode) -> Bool {
        root.children.contains { node in
            node.isElement || (node.isTextLike && !node.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty)
        }
    }

    /**
     Returns direct no-namespace child elements by exact name.

     - Parameters:
       - name: Requested local name.
       - parent: Parent element.
     - Returns: Matching direct children in source order.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func directChildElements(
        named name: String,
        in parent: SwordXMLNode
    ) -> [SwordXMLNode] {
        parent.children.filter { $0.isElement(exactlyNamed: name) }
    }

    /**
     Converts OSIS to the plain-text representation Android compares for commentary blocks.

     - Parameter root: Anchored fragment root.
     - Returns: Trimmed semantic text with Android's whitespace normalization.
     - Side effects: None.
     - Failure modes: None; malformed source was rejected before this stage.
     */
    private static func androidPlainText(from root: SwordXMLNode) -> String {
        var output = ""
        appendAndroidPlainText(root, to: &output)
        output = output.replacingOccurrences(
            of: #" +\n"#,
            with: "\n",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /**
     Recursively ports Android `OsisToPlainText.walkElement` for block comparison.

     - Parameters:
       - element: Current OSIS element.
       - output: Destination text.
     - Side effects: Appends semantic text and lightweight markup to `output`.
     - Failure modes: None.
     */
    private static func appendAndroidPlainText(
        _ element: SwordXMLNode,
        to output: inout String
    ) {
        guard element.isElement else {
            output += element.stringValue
            return
        }
        let name = element.localName
        if name == "milestone" || name == "chapter" || name.hasPrefix("x-") { return }

        if name == "BVA" {
            appendPlainChildren(of: element, to: &output)
            return
        }
        if name == "reference", let osisRef = element.attribute(named: "osisRef") {
            var inner = ""
            appendPlainChildren(of: element, to: &inner)
            output += "[\(inner)](\(osisReferenceURL(osisRef)))"
            return
        }

        switch name {
        case "title": output += "\n## "
        case "note": output += " [Footnote: "
        case "transChange": output += "*"
        case "hi":
            output += element.attribute(named: "type") == "bold" ? "**" : "*"
        case "verse":
            if let id = element.attribute(named: "osisID"),
               let verseNumber = id.split(separator: ".").last {
                output += "\(verseNumber). "
            }
        case "q":
            output += element.attribute(named: "marker") ?? ""
        case "l", "lb": output += "\n"
        case "p", "div", "list", "lg", "row": output += "\n"
        case "item": output += "\n- "
        default: break
        }

        appendPlainChildren(of: element, to: &output)

        switch name {
        case "title": output += "\n"
        case "note": output += "]"
        case "transChange": output += "*"
        case "hi":
            output += element.attribute(named: "type") == "bold" ? "**" : "*"
        case "p", "div", "list", "lg", "row": output += "\n"
        case "cell": output += " "
        default: break
        }
    }

    /**
     Appends text and recursive element children in document order.

     - Parameters:
       - element: Parent element.
       - output: Destination text.
     - Side effects: Appends to `output`.
     - Failure modes: None.
     */
    private static func appendPlainChildren(
        of element: SwordXMLNode,
        to output: inout String
    ) {
        for child in element.children {
            if child.isTextLike {
                output += child.stringValue
            } else if child.isElement {
                appendAndroidPlainText(child, to: &output)
            }
        }
    }

    /**
     Converts an OSIS reference to Android's `sword://` plain-text link target.

     - Parameter reference: Module-qualified or unqualified OSIS reference.
     - Returns: Percent-encoded `sword://` URL.
     - Side effects: None.
     - Failure modes: None; every UTF-8 byte can be percent encoded.
     */
    private static func osisReferenceURL(_ reference: String) -> String {
        if let colon = reference.firstIndex(of: ":"), colon != reference.startIndex {
            let prefix = String(reference[..<colon])
            if prefix.first?.isUppercase == true {
                let key = String(reference[reference.index(after: colon)...])
                return "sword://\(encodeOSISReference(prefix))/\(encodeOSISReference(key))"
            }
        }
        return "sword:///\(encodeOSISReference(reference))"
    }

    /**
     Percent-encodes an OSIS reference with Android's RFC 3986 allowlist.

     - Parameter value: Reference component.
     - Returns: Encoded component preserving letters, digits, `-._~`.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func encodeOSISReference(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || "-._~".unicodeScalars.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    result += String(format: "%%%02X", byte)
                }
            }
        }
        return result
    }
}
