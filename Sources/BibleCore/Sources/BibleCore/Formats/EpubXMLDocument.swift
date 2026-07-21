// EpubXMLDocument.swift -- Structured XML tree support for EPUB package documents

import Foundation

/**
 Errors produced while parsing XML resources from an EPUB package.

 The parser rejects malformed XML and documents without a single root element. External entity
 resolution is disabled so imported books cannot read local files or trigger network requests.
 */
enum EpubXMLDocumentError: LocalizedError {
    /// The XML parser rejected the document, with the parser's diagnostic when available.
    case malformed(String)

    /// The document did not contain exactly one root element.
    case missingRoot

    /// User-facing diagnostic used by the EPUB import error path.
    var errorDescription: String? {
        switch self {
        case .malformed(let message):
            return "Malformed EPUB XML: \(message)"
        case .missingRoot:
            return "Malformed EPUB XML: missing document root"
        }
    }
}

/**
 One mutable XML element in an EPUB package document.

 The tree intentionally preserves qualified element and attribute names. EPUB 2 and EPUB 3 files
 use different namespace prefixes in practice, while their semantic matching is based on local
 names. Callers therefore use `localName` and `attribute(localName:)` for matching but serialize the
 original qualified names back into renderer content.

 - Important: Instances are confined to one import operation and are not thread-safe.
 */
final class EpubXMLElement {
    /// Qualified element name as reported by `XMLParser`.
    var name: String

    /// Qualified attributes, including namespace declarations, preserved for serialization.
    var attributes: [String: String]

    /// Ordered child elements and text nodes.
    var children: [EpubXMLNode]

    /**
     Creates an XML element for the import-only tree.

     - Parameters:
       - name: Qualified element name.
       - attributes: Qualified attributes from the source document.
       - children: Ordered children, normally populated by `EpubXMLTreeParser`.
     - Side effects: None.
     - Failure modes: None; structural validation occurs while parsing.
     */
    init(name: String, attributes: [String: String], children: [EpubXMLNode] = []) {
        self.name = name
        self.attributes = attributes
        self.children = children
    }

    /// Namespace-independent local element name.
    var localName: String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    /**
     Returns the first attribute whose namespace-independent name matches `localName`.

     - Parameter localName: Attribute name without a namespace prefix.
     - Returns: Matching value, or `nil` when absent.
     - Side effects: None.
     */
    func attribute(localName: String) -> String? {
        attributes.first { key, _ in
            (key.split(separator: ":").last.map(String.init) ?? key) == localName
        }?.value
    }

    /**
     Returns all descendant elements, optionally including this element.

     - Parameter includeSelf: Whether the receiver should be the first result.
     - Returns: Elements in document order.
     - Side effects: None.
     - Complexity: O(n) in the represented subtree.
     */
    func descendants(includeSelf: Bool = false) -> [EpubXMLElement] {
        var result = includeSelf ? [self] : []
        for child in children {
            guard case .element(let element) = child else { continue }
            result.append(element)
            result.append(contentsOf: element.descendants())
        }
        return result
    }

    /**
     Flattens descendant text into the human-readable value used by metadata and TOC labels.

     - Returns: Concatenated text in document order without injecting synthetic separators.
     - Side effects: None.
     */
    func textContent() -> String {
        children.map { child in
            switch child {
            case .text(let text):
                return text
            case .element(let element):
                return element.textContent()
            }
        }.joined()
    }

    /**
     Creates an independent deep copy of this element tree.

     EPUB fragmentation trims different ranges from the same transformed XHTML document. Each
     fragment must therefore own its nodes so pruning one page cannot mutate another page.

     - Returns: A recursively copied element with copied attributes, text, and descendants.
     - Side effects: None.
     - Failure modes: None.
     */
    func deepCopy() -> EpubXMLElement {
        EpubXMLElement(
            name: name,
            attributes: attributes,
            children: children.map { node in
                switch node {
                case .element(let element):
                    return .element(element.deepCopy())
                case .text(let text):
                    return .text(text)
                }
            }
        )
    }

    /**
     Serializes this element and descendants as escaped XML/XHTML.

     - Returns: Deterministic markup with attributes sorted by qualified name.
     - Side effects: None.
     - Failure modes: None; the in-memory tree contains parsed names and escaped text is generated
       during serialization.
     */
    func serializedXML() -> String {
        let renderedAttributes = attributes.keys.sorted().map { key in
            " \(key)=\"\(Self.escapeAttribute(attributes[key] ?? ""))\""
        }.joined()
        let body = children.map(\.serializedXML).joined()
        return "<\(name)\(renderedAttributes)>\(body)</\(name)>"
    }

    /// Escapes XML text while preserving all Unicode scalar content.
    private static func escapeText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Escapes an XML attribute value for double-quoted serialization.
    private static func escapeAttribute(_ value: String) -> String {
        escapeText(value).replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/**
 Ordered node values stored under an `EpubXMLElement`.

 CDATA and ordinary character data intentionally share the text representation because the EPUB
 renderer consumes their decoded value and serialization re-escapes it safely.
 */
indirect enum EpubXMLNode {
    /// Nested element node.
    case element(EpubXMLElement)

    /// Decoded character or CDATA content.
    case text(String)

    /// Serializes one node for renderer output.
    var serializedXML: String {
        switch self {
        case .element(let element):
            return element.serializedXML()
        case .text(let text):
            return text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
    }
}

/**
 Builds a small mutable tree from standards-compliant EPUB XML/XHTML.

 The parser is shared by container, OPF, NCX, EPUB 3 navigation, and spine documents so none of
 those semantics depend on regular-expression extraction. It performs no file or network I/O.
 */
enum EpubXMLTreeParser {
    /**
     Parses one XML document into a qualified-name-preserving tree.

     - Parameter data: XML bytes from an extracted EPUB member.
     - Returns: The single root element.
     - Side effects: Allocates an in-memory tree; external entities are never resolved.
     - Throws: `EpubXMLDocumentError` for malformed XML or a missing root.
     */
    static func parse(_ data: Data) throws -> EpubXMLElement {
        let delegate = EpubXMLTreeParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        #if canImport(Darwin)
        parser.externalEntityResolvingPolicy = .never
        #endif

        guard parser.parse() else {
            let diagnostic = parser.parserError?.localizedDescription ?? "unknown parser error"
            throw EpubXMLDocumentError.malformed(diagnostic)
        }
        guard let root = delegate.root else {
            throw EpubXMLDocumentError.missingRoot
        }
        return root
    }
}

/**
 `XMLParserDelegate` implementation that constructs `EpubXMLElement` values in document order.

 The delegate is created per parse and has no shared state. Character callbacks are coalesced into
 adjacent text nodes to keep subsequent ordinal assignment deterministic across parser chunking.
 */
private final class EpubXMLTreeParserDelegate: NSObject, XMLParserDelegate {
    /// Completed root element after parsing.
    private(set) var root: EpubXMLElement?

    /// Open element stack used while consuming SAX callbacks.
    private var stack: [EpubXMLElement] = []

    /// Creates and attaches one element for a SAX start-element callback.
    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = EpubXMLElement(name: qName ?? elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(.element(element))
        } else if root == nil {
            root = element
        }
        stack.append(element)
    }

    /// Closes the current stack element after a SAX end-element callback.
    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if !stack.isEmpty {
            stack.removeLast()
        }
    }

    /// Appends decoded character data to the current element, coalescing adjacent chunks.
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
    }

    /// Appends decoded CDATA bytes to the current element.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let text = String(data: CDATABlock, encoding: .utf8) else { return }
        appendText(text)
    }

    /// Coalesces one parser-provided text chunk into the current element.
    private func appendText(_ text: String) {
        guard !text.isEmpty, let current = stack.last else { return }
        if case .text(let previous)? = current.children.last {
            current.children[current.children.count - 1] = .text(previous + text)
        } else {
            current.children.append(.text(text))
        }
    }
}
