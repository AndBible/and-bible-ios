import Foundation

/**
 Minimal mutable XML node used by the iOS-compatible OSIS processor.

 Foundation's DOM (`XMLDocument`/`XMLElement`) is unavailable on iOS. This tree keeps element names,
 attributes, text, CDATA, comments, and processing instructions without crossing into rendered HTML.
 */
final class SwordXMLNode {
    /// XML node kind and payload.
    private enum Kind {
        case element(name: String, attributes: [String: String])
        case text(String)
        case cdata(String)
        case comment(String)
        case processingInstruction(target: String, data: String?)
    }

    /// Node payload.
    private var kind: Kind
    /// Ordered child nodes; only element nodes have children.
    var children: [SwordXMLNode] = []

    /// Whether this node is an XML element.
    var isElement: Bool {
        if case .element = kind { return true }
        return false
    }

    /// Whether this node contributes XPath text content.
    var isTextLike: Bool {
        switch kind {
        case .text, .cdata: return true
        default: return false
        }
    }

    /// Whether parser character chunks may be coalesced into this ordinary text node.
    var isOrdinaryText: Bool {
        if case .text = kind { return true }
        return false
    }

    /// Element local name without a namespace prefix.
    var localName: String {
        guard case .element(let name, _) = kind else { return "" }
        return name.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? name
    }

    /// Exact qualified element name retained from source XML.
    var qualifiedName: String {
        guard case .element(let name, _) = kind else { return "" }
        return name
    }

    /// Recursive text value matching JDOM's element value behavior.
    var stringValue: String {
        switch kind {
        case .text(let value), .cdata(let value):
            return value
        case .element:
            return children.map(\.stringValue).joined()
        case .comment, .processingInstruction:
            return ""
        }
    }

    /**
     Returns JDOM2's `Content.toString()` representation for non-Element/non-Text children.

     Android's Bible Search preview appends this diagnostic representation for comments and
     processing instructions before its one `Html.fromHtml` pass. Elements and text-like nodes
     return nil because their dedicated traversal branches own those values.
     */
    var jdomContentDescription: String? {
        switch kind {
        case .comment:
            return "[Comment: \(serializedXML())]"
        case .processingInstruction:
            return "[ProcessingInstruction: \(serializedXML())]"
        case .element, .text, .cdata:
            return nil
        }
    }

    /** Creates an element node with ordered children added later. */
    static func element(name: String, attributes: [String: String]) -> SwordXMLNode {
        SwordXMLNode(kind: .element(name: name, attributes: attributes))
    }

    /** Creates an ordinary text node. */
    static func text(_ value: String) -> SwordXMLNode {
        SwordXMLNode(kind: .text(value))
    }

    /** Creates a CDATA node. */
    static func cdata(_ value: String) -> SwordXMLNode {
        SwordXMLNode(kind: .cdata(value))
    }

    /** Creates a comment node. */
    static func comment(_ value: String) -> SwordXMLNode {
        SwordXMLNode(kind: .comment(value))
    }

    /** Creates a processing-instruction node. */
    static func processingInstruction(target: String, data: String?) -> SwordXMLNode {
        SwordXMLNode(kind: .processingInstruction(target: target, data: data))
    }

    /** Stores one node payload. */
    private init(kind: Kind) {
        self.kind = kind
    }

    /** Returns whether this node is an element with the requested local name. */
    func isElement(named name: String) -> Bool {
        isElement && localName == name
    }

    /** Returns whether this node is a no-namespace element with the exact requested name. */
    func isElement(exactlyNamed name: String) -> Bool {
        isElement && qualifiedName == name
    }

    /** Returns one exact no-namespace attribute value. */
    func attribute(named name: String) -> String? {
        guard case .element(_, let attributes) = kind else { return nil }
        return attributes[name]
    }

    /**
     Sets one no-namespace attribute on an element node.

     - Parameters:
       - name: Exact attribute name.
       - value: Replacement value serialized with normal XML escaping.
     - Side effects: Mutates the receiver when it is an element; other node kinds are unchanged.
     - Failure modes: None; assigning an existing name replaces its prior value.
     */
    func setAttribute(named name: String, value: String) {
        guard case .element(let elementName, var attributes) = kind else { return }
        attributes[name] = value
        kind = .element(name: elementName, attributes: attributes)
    }

    /** Produces an independent recursive copy. */
    func deepCopy() -> SwordXMLNode {
        let copy = SwordXMLNode(kind: kind)
        copy.children = children.map { $0.deepCopy() }
        return copy
    }

    /**
     Applies a transform to every ordinary XML text node in document order.

     - Parameter transform: Pure text projection applied to `Text` nodes, excluding CDATA,
       comments, and processing instructions.
     - Side effects: Mutates this node and all element descendants in place.
     - Failure modes: None; the transform is nonthrowing.
     */
    func transformOrdinaryText(_ transform: (String) -> String) {
        switch kind {
        case .text(let value):
            kind = .text(transform(value))
        case .element:
            children.forEach { $0.transformOrdinaryText(transform) }
        case .cdata, .comment, .processingInstruction:
            break
        }
    }

    /** Serializes the preserved XML tree deterministically without rendering it. */
    func serializedXML() -> String {
        switch kind {
        case .element(let name, let attributes):
            let serializedAttributes = attributes.keys.sorted().map { key in
                " \(key)=\"\(Self.escapeAttribute(attributes[key] ?? ""))\""
            }.joined()
            guard !children.isEmpty else { return "<\(name)\(serializedAttributes)/>" }
            return "<\(name)\(serializedAttributes)>\(children.map { $0.serializedXML() }.joined())</\(name)>"
        case .text(let value):
            return Self.escapeText(value)
        case .cdata(let value):
            return "<![CDATA[\(value)]]>"
        case .comment(let value):
            return "<!--\(value)-->"
        case .processingInstruction(let target, let data):
            return data.map { "<?\(target) \($0)?>" } ?? "<?\(target)?>"
        }
    }

    /** Escapes XML text while preserving Unicode scalars. */
    private static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /** Escapes XML attribute text while preserving Unicode scalars. */
    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value).replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/** Builds `SwordXMLNode` trees with Foundation's iOS-supported streaming parser. */
final class SwordXMLTreeParser: NSObject, XMLParserDelegate {
    /// Open element stack.
    private var stack: [SwordXMLNode] = []
    /// Parsed document root.
    private var root: SwordXMLNode?
    /// First parser error, retained for an actionable failure.
    private var failure: Error?

    /**
     Parses one complete XML document.

     - Parameter xml: UTF-8 XML with exactly one root element.
     - Returns: Parsed root node.
     - Side effects: Allocates an in-memory tree; external entities are never loaded.
     - Failure modes: Throws the parser error or a missing-root error.
     */
    static func parse(xml: String) throws -> SwordXMLNode {
        let delegate = SwordXMLTreeParser()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.failure == nil else {
            throw delegate.failure ?? parser.parserError ?? SwordOSISProcessorError.missingRoot
        }
        guard let root = delegate.root else {
            throw SwordOSISProcessorError.missingRoot
        }
        return root
    }

    /** Adds one parsed element and makes it the active parent. */
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = SwordXMLNode.element(name: qName ?? elementName, attributes: attributeDict)
        append(element)
        stack.append(element)
    }

    /** Closes the active parsed element. */
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }

    /** Appends parser text, coalescing chunks into the same logical XML text node. */
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !string.isEmpty else { return }
        if let last = stack.last?.children.last, last.isOrdinaryText {
            let combined = last.stringValue + string
            stack.last?.children.removeLast()
            stack.last?.children.append(.text(combined))
        } else {
            append(.text(string))
        }
    }

    /** Preserves one CDATA section as structural source XML. */
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        append(.cdata(String(decoding: CDATABlock, as: UTF8.self)))
    }

    /** Preserves one XML comment. */
    func parser(_ parser: XMLParser, foundComment comment: String) {
        append(.comment(comment))
    }

    /** Preserves one processing instruction. */
    func parser(
        _ parser: XMLParser,
        foundProcessingInstructionWithTarget target: String,
        data: String?
    ) {
        append(.processingInstruction(target: target, data: data))
    }

    /** Retains the first parser error. */
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil { failure = parseError }
    }

    /** Appends a node to the active element or records the document root. */
    private func append(_ node: SwordXMLNode) {
        if let parent = stack.last {
            parent.children.append(node)
        } else if root == nil {
            root = node
        }
    }
}

/** XML-shape failures not represented by Foundation's parser error. */
enum SwordOSISProcessorError: Error, LocalizedError {
    case missingRoot
    case invalidRootCount(Int)

    /// Human-readable malformed-fragment reason.
    var errorDescription: String? {
        switch self {
        case .missingRoot:
            return "The OSIS fragment has no XML root element."
        case .invalidRootCount(let count):
            return "The OSIS fragment must contain one root element; found \(count)."
        }
    }
}
