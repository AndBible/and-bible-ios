// EpubContentTransformer.swift -- EPUB XHTML rendering and resource bridge semantics

import Foundation

/**
 One Android-compatible render fragment derived from a spine document.
 */
struct EpubTransformedFragment: Sendable {
    /// Render-ready native HTML with canonical resource and EPUB-link targets.
    let html: String

    /// Plain text used for fallback display and diagnostics.
    let plainText: String

    /// Inclusive BVA ordinal range within the original spine document.
    let ordinalRange: ClosedRange<Int>

    /// Individual BVA sentence values used by the EPUB FTS index.
    let anchors: [(ordinal: Int, text: String)]

    /// XHTML ids owned by this fragment for TOC and internal-link mapping.
    let htmlIDs: [String]
}

/**
 Converts one spine XHTML document into Android-compatible native HTML.

 The transformer parses XHTML structurally, assigns BVA sentence ordinals, rewrites internal links
 to `(manifest key, HTML id)`, rewrites package media to the iOS resource scheme, strips executable
 content, and records stylesheet dependencies. It never uses regular expressions to discover or
 mutate XML elements.
 */
enum EpubContentTransformer {
    /// Elements omitted from native HTML because imported scripts/frames must not execute.
    private static let blockedElements: Set<String> = ["script", "iframe", "object", "embed"]

    /// Text containers excluded from BVA sentence wrapping.
    private static let nonOrdinalElements: Set<String> = ["style", "script", "note"]

    /**
     Transforms one manifest spine item.

     - Parameters:
       - item: XHTML manifest item to process.
       - package: Parsed package used for link-to-manifest resolution.
       - packageRootURL: Extracted package root.
       - resourceIdentity: Android initials and immutable generation for contained resource URLs.
     - Returns: Android-sized fragments, anchor ordinals, searchable text, and stylesheets.
     - Side effects: Reads the XHTML file from disk and mutates only an import-local XML tree.
     - Throws: XML, file-system, or `EpubError.invalidEpub` failures. A malformed spine document
       fails installation instead of publishing a partially indexed book.
     */
    static func transform(
        item: EpubManifestItem,
        package: EpubPackageDocument,
        packageRootURL: URL,
        resourceIdentity: EpubResourceIdentity
    ) throws -> EpubTransformedDocument {
        let resolver = EpubPackagePathResolver(packageRootURL: packageRootURL)
        let sourceURL = try resolver.fileURL(for: item.path)
        let root = try EpubXMLTreeParser.parse(Data(contentsOf: sourceURL))
        guard let body = root.descendants(includeSelf: true).first(where: { $0.localName == "body" }) else {
            throw EpubError.invalidEpub("Spine document has no XHTML body: \(item.path)")
        }

        let styleSheetPaths = try linkedStyleSheets(
            in: root,
            sourcePath: item.path,
            resolver: resolver
        )
        sanitizeAttributes(of: body)
        rewriteResourceAttributes(
            of: body,
            sourcePath: item.path,
            resolver: resolver,
            resourceIdentity: resourceIdentity
        )
        var ordinal = 0
        var anchors: [(ordinal: Int, text: String)] = []
        transformChildren(
            of: body,
            currentKey: item.id,
            sourcePath: item.path,
            package: package,
            resolver: resolver,
            resourceIdentity: resourceIdentity,
            ordinal: &ordinal,
            anchors: &anchors,
            wrapsText: true
        )

        body.name = "div"
        let classKey = body.attributes.keys.first { key in
            (key.split(separator: ":").last.map(String.init) ?? key).lowercased() == "class"
        }
        let existingClasses = classKey.flatMap { body.attributes.removeValue(forKey: $0) } ?? ""
        body.attributes["class"] = [existingClasses, "epub-native-document"]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        let wrapper = body
        var fragments: [EpubTransformedFragment] = []
        for fragmentRoot in splitIntoFragments(wrapper, anchorCount: ordinal) {
            let fragmentAnchors = anchorsIn(fragmentRoot, sourceAnchors: anchors)
            guard !fragmentAnchors.isEmpty else { continue }
            fragments.append(EpubTransformedFragment(
                html: fragmentRoot.serializedXML(),
                plainText: fragmentAnchors.map(\.text).joined(separator: " "),
                ordinalRange: fragmentAnchors[0].ordinal...fragmentAnchors[fragmentAnchors.count - 1].ordinal,
                anchors: fragmentAnchors,
                htmlIDs: htmlIDs(in: fragmentRoot)
            ))
        }
        let finalFragments = fragments.isEmpty ? [EpubTransformedFragment(
            html: wrapper.serializedXML(),
            plainText: "",
            ordinalRange: 0...0,
            anchors: [],
            htmlIDs: htmlIDs(in: wrapper)
        )] : fragments
        return EpubTransformedDocument(
            originalKey: item.id,
            href: item.path,
            styleSheetPaths: styleSheetPaths,
            fragments: finalFragments
        )
    }

    /**
     Splits transformed XHTML with Android's `ORDINALS_PER_FRAGMENT` boundary contract.

     Android derives page keys from database fragment ids and cuts only at paragraph-like element
     boundaries. A failed boundary lookup keeps the document whole, preserving link and ordinal
     stability for markup whose anchors do not sit inside splittable structures.
     */
    private static func splitIntoFragments(
        _ document: EpubXMLElement,
        anchorCount: Int
    ) -> [EpubXMLElement] {
        let fragmentCount = anchorCount / 500
        guard fragmentCount > 0 else { return [document] }
        let pieceLength = anchorCount / fragmentCount
        guard pieceLength > 0,
              let first = extractBetween(document, lowerOrdinal: nil, upperOrdinal: pieceLength) else {
            return [document]
        }

        var result = [first]
        var lower = pieceLength
        var upper = pieceLength * 2
        while upper < anchorCount {
            if let fragment = extractBetween(document, lowerOrdinal: lower, upperOrdinal: upper) {
                lower = upper
                result.append(fragment)
            }
            upper += pieceLength
        }
        if lower < anchorCount,
           let fragment = extractBetween(document, lowerOrdinal: lower, upperOrdinal: nil) {
            result.append(fragment)
        }
        return result
    }

    /// Clones and trims one document between two Android-compatible split elements.
    private static func extractBetween(
        _ original: EpubXMLElement,
        lowerOrdinal: Int?,
        upperOrdinal: Int?
    ) -> EpubXMLElement? {
        let document = original.deepCopy()
        let lowerElement = lowerOrdinal.flatMap { splitElement(in: document, ordinal: $0) }
        let upperElement = upperOrdinal.flatMap { splitElement(in: document, ordinal: $0) }
        if lowerElement === upperElement { return nil }

        if let lowerElement {
            trimSiblingsBefore(lowerElement, root: document)
            var ancestor = parent(of: lowerElement, in: document)
            while let current = ancestor {
                trimSiblingsBefore(current, root: document)
                ancestor = parent(of: current, in: document)
            }
        }
        if let upperElement {
            var ancestor = parent(of: upperElement, in: document)
            while let current = ancestor, parent(of: current, in: document) != nil {
                trimSiblingsAfter(current, root: document)
                ancestor = parent(of: current, in: document)
            }
            trimSiblingsAfter(upperElement, root: document)
            detach(upperElement, root: document)
        }
        return document
    }

    /// Finds the first element matching Android's paragraph-aware split-point XPath.
    private static func splitElement(in root: EpubXMLElement, ordinal: Int) -> EpubXMLElement? {
        for element in root.descendants(includeSelf: true) {
            let containsOrdinal = element.descendants(includeSelf: true).contains { candidate in
                candidate.localName.lowercased() == "bva"
                    && candidate.attribute(localName: "ordinal") == String(ordinal)
            }
            guard containsOrdinal else { continue }
            if element.localName.lowercased() == "p" { return element }
            guard let parent = parent(of: element, in: root),
                  let index = parent.children.firstIndex(where: { node in
                      guard case .element(let candidate) = node else { return false }
                      return candidate === element
                  }) else { continue }
            let siblingIsParagraph = parent.children.enumerated().contains { siblingIndex, node in
                guard siblingIndex != index, case .element(let sibling) = node else { return false }
                return sibling.localName.lowercased() == "p"
            }
            if siblingIsParagraph { return element }
        }
        return nil
    }

    /// Returns the direct parent of an element by identity.
    private static func parent(of target: EpubXMLElement, in root: EpubXMLElement) -> EpubXMLElement? {
        for child in root.children {
            guard case .element(let element) = child else { continue }
            if element === target { return root }
            if let match = parent(of: target, in: element) { return match }
        }
        return nil
    }

    /// Removes content before one element in its direct parent.
    private static func trimSiblingsBefore(_ target: EpubXMLElement, root: EpubXMLElement) {
        guard let parent = parent(of: target, in: root),
              let index = parent.children.firstIndex(where: { node in
                  guard case .element(let element) = node else { return false }
                  return element === target
              }) else { return }
        parent.children.removeFirst(index)
    }

    /// Removes content after one element in its direct parent.
    private static func trimSiblingsAfter(_ target: EpubXMLElement, root: EpubXMLElement) {
        guard let parent = parent(of: target, in: root),
              let index = parent.children.firstIndex(where: { node in
                  guard case .element(let element) = node else { return false }
                  return element === target
              }), index + 1 < parent.children.count else { return }
        parent.children.removeSubrange((index + 1)..<parent.children.count)
    }

    /// Detaches one element from its direct parent.
    private static func detach(_ target: EpubXMLElement, root: EpubXMLElement) {
        guard let parent = parent(of: target, in: root) else { return }
        parent.children.removeAll { node in
            guard case .element(let element) = node else { return false }
            return element === target
        }
    }

    /// Projects indexed anchor text to the BVA elements retained in one fragment.
    private static func anchorsIn(
        _ root: EpubXMLElement,
        sourceAnchors: [(ordinal: Int, text: String)]
    ) -> [(ordinal: Int, text: String)] {
        let retained = Set(root.descendants(includeSelf: true).compactMap { element -> Int? in
            guard element.localName.lowercased() == "bva",
                  let raw = element.attribute(localName: "ordinal") else { return nil }
            return Int(raw)
        })
        return sourceAnchors.filter { retained.contains($0.ordinal) }
    }

    /// Collects unique HTML ids retained by one fragment in document order.
    private static func htmlIDs(in root: EpubXMLElement) -> [String] {
        var seen = Set<String>()
        return root.descendants(includeSelf: true).compactMap { element in
            guard let id = element.attribute(localName: "id"), !id.isEmpty,
                  seen.insert(id).inserted else { return nil }
            return id
        }
    }

    /// Collects canonical stylesheet resources linked from an XHTML document head.
    private static func linkedStyleSheets(
        in root: EpubXMLElement,
        sourcePath: String,
        resolver: EpubPackagePathResolver
    ) throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for link in root.descendants(includeSelf: true) where link.localName == "link" {
            let relTokens = Set(
                (link.attribute(localName: "rel") ?? "")
                    .lowercased()
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
            )
            guard relTokens.contains("stylesheet"),
                  let href = link.attribute(localName: "href"),
                  let resolved = try resolver.resolve(href, relativeTo: sourcePath),
                  seen.insert(resolved.path).inserted else {
                continue
            }
            result.append(resolved.path)
        }
        return result
    }

    /// Recursively rewrites elements and replaces eligible text nodes with BVA anchors.
    private static func transformChildren(
        of element: EpubXMLElement,
        currentKey: String,
        sourcePath: String,
        package: EpubPackageDocument,
        resolver: EpubPackagePathResolver,
        resourceIdentity: EpubResourceIdentity,
        ordinal: inout Int,
        anchors: inout [(ordinal: Int, text: String)],
        wrapsText: Bool
    ) {
        var transformed: [EpubXMLNode] = []
        for child in element.children {
            switch child {
            case .text(let text):
                guard wrapsText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    transformed.append(.text(text))
                    continue
                }
                for sentence in EpubSentenceSplitter.split(text) {
                    let linkedChildren = ScriptureReferenceLinker.segments(
                        in: sentence,
                        documentLanguage: package.language
                    ).map { segment -> EpubXMLNode in
                        guard let osisRef = segment.osisRef else { return .text(segment.text) }
                        return .element(EpubXMLElement(
                            name: "reference",
                            attributes: ["osisRef": osisRef],
                            children: [.text(segment.text)]
                        ))
                    }
                    let anchor = EpubXMLElement(
                        name: "BVA",
                        attributes: ["ordinal": String(ordinal)],
                        children: linkedChildren
                    )
                    anchors.append((ordinal: ordinal, text: sentence))
                    ordinal += 1
                    transformed.append(.element(anchor))
                }
            case .element(let childElement):
                let localName = childElement.localName.lowercased()
                guard !blockedElements.contains(localName) else { continue }
                sanitizeAttributes(of: childElement)
                rewriteResourceAttributes(
                    of: childElement,
                    sourcePath: sourcePath,
                    resolver: resolver,
                    resourceIdentity: resourceIdentity
                )
                if localName == "style" {
                    childElement.children = childElement.children.map { node in
                        guard case .text(let css) = node else { return node }
                        return .text(EpubCSSProcessor.process(
                            css,
                            styleSheetPath: sourcePath,
                            packageRootURL: resolver.packageRootURL,
                            resourceIdentity: resourceIdentity
                        ))
                    }
                }
                if localName == "a" {
                    rewriteAnchor(
                        childElement,
                        currentKey: currentKey,
                        sourcePath: sourcePath,
                        package: package,
                        resolver: resolver,
                        resourceIdentity: resourceIdentity
                    )
                }
                transformChildren(
                    of: childElement,
                    currentKey: currentKey,
                    sourcePath: sourcePath,
                    package: package,
                    resolver: resolver,
                    resourceIdentity: resourceIdentity,
                    ordinal: &ordinal,
                    anchors: &anchors,
                    wrapsText: wrapsText && !nonOrdinalElements.contains(localName)
                )
                transformed.append(.element(childElement))
            }
        }
        element.children = transformed
    }

    /// Removes executable event-handler attributes from imported markup.
    private static func sanitizeAttributes(of element: EpubXMLElement) {
        element.attributes = element.attributes.filter { key, value in
            let localName = key.split(separator: ":").last.map(String.init)?.lowercased() ?? key.lowercased()
            if localName.hasPrefix("on") { return false }
            if ["href", "src", "data", "poster"].contains(localName),
               value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("javascript:") {
                return false
            }
            return true
        }
    }

    /// Rewrites media-bearing attributes to the contained custom EPUB resource scheme.
    private static func rewriteResourceAttributes(
        of element: EpubXMLElement,
        sourcePath: String,
        resolver: EpubPackagePathResolver,
        resourceIdentity: EpubResourceIdentity
    ) {
        let elementName = element.localName.lowercased()
        let resourceAttributes: Set<String> = elementName == "a"
            ? ["src", "poster", "data"]
            : ["src", "poster", "data", "href"]
        for key in Array(element.attributes.keys) {
            let localName = key.split(separator: ":").last.map(String.init)?.lowercased() ?? key.lowercased()
            if localName == "style", let value = element.attributes[key] {
                let sanitized = EpubCSSProcessor.processInlineDeclarations(
                    value,
                    sourcePath: sourcePath,
                    packageRootURL: resolver.packageRootURL,
                    resourceIdentity: resourceIdentity
                )
                if sanitized.isEmpty {
                    element.attributes.removeValue(forKey: key)
                } else {
                    element.attributes[key] = sanitized
                }
                continue
            }
            if localName == "srcset", let value = element.attributes[key] {
                let rewritten = rewriteSourceSet(
                    value,
                    sourcePath: sourcePath,
                    resolver: resolver,
                    resourceIdentity: resourceIdentity
                )
                if rewritten.isEmpty {
                    element.attributes.removeValue(forKey: key)
                } else {
                    element.attributes[key] = rewritten
                }
                continue
            }
            guard resourceAttributes.contains(localName), let value = element.attributes[key] else { continue }
            guard let resolved = try? resolver.resolve(value, relativeTo: sourcePath) else {
                if !isEmbeddedDataResource(value) {
                    element.attributes.removeValue(forKey: key)
                }
                continue
            }
            element.attributes[key] = EpubResourceLocator.resourceURLString(
                identity: resourceIdentity,
                canonicalPath: resolved.path,
                fragment: resolved.fragment
            )
        }
    }

    /// Rewrites each local URL in an XHTML `srcset` while preserving density/width descriptors.
    private static func rewriteSourceSet(
        _ value: String,
        sourcePath: String,
        resolver: EpubPackagePathResolver,
        resourceIdentity: EpubResourceIdentity
    ) -> String {
        var result: [String] = []
        var cursor = value.startIndex
        while cursor < value.endIndex {
            while cursor < value.endIndex, value[cursor].isWhitespace || value[cursor] == "," {
                cursor = value.index(after: cursor)
            }
            guard cursor < value.endIndex else { break }

            let urlStart = cursor
            while cursor < value.endIndex, !value[cursor].isWhitespace {
                cursor = value.index(after: cursor)
            }
            var rawURL = String(value[urlStart..<cursor])
            var endedAtComma = false
            while rawURL.last == "," {
                rawURL.removeLast()
                endedAtComma = true
            }
            guard !rawURL.isEmpty else { continue }

            while cursor < value.endIndex, value[cursor].isWhitespace {
                cursor = value.index(after: cursor)
            }
            let descriptorStart = cursor
            var parenthesisDepth = 0
            if !endedAtComma {
                while cursor < value.endIndex {
                    let character = value[cursor]
                    if character == "(" { parenthesisDepth += 1 }
                    if character == ")" { parenthesisDepth = max(0, parenthesisDepth - 1) }
                    if character == ",", parenthesisDepth == 0 { break }
                    cursor = value.index(after: cursor)
                }
            }
            let descriptor = endedAtComma
                ? ""
                : String(value[descriptorStart..<cursor]).trimmingCharacters(in: .whitespacesAndNewlines)
            if cursor < value.endIndex, value[cursor] == "," {
                cursor = value.index(after: cursor)
            }

            let rewrittenURL: String
            if let resolved = try? resolver.resolve(rawURL, relativeTo: sourcePath) {
                rewrittenURL = EpubResourceLocator.resourceURLString(
                    identity: resourceIdentity,
                    canonicalPath: resolved.path,
                    fragment: resolved.fragment
                )
            } else if isEmbeddedDataResource(rawURL) {
                rewrittenURL = rawURL
            } else {
                continue
            }
            result.append(descriptor.isEmpty ? rewrittenURL : "\(rewrittenURL) \(descriptor)")
        }
        return result.joined(separator: ", ")
    }

    /// Returns whether one unresolved media reference is a self-contained data URL.
    private static func isEmbeddedDataResource(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("data:")
    }

    /**
     Rewrites an XHTML anchor into a contained `epubRef` or the renderer's external `epubA`.

     Valid external schemes retain their original URL. Malformed or escaping local references are
     rendered as inert spans so URI-validation failures cannot be laundered through the native
     external-link bridge.

     - Parameters:
       - anchor: Import-local anchor element to rewrite in place.
       - currentKey: Manifest key for same-document fragment links.
       - sourcePath: Canonical XHTML path used for relative URI resolution.
       - package: Parsed manifest used to map contained paths back to general-book keys.
       - resolver: Package-root resolver enforcing URI containment.
       - resourceIdentity: Android initials and immutable generation for contained resources.
     - Side effects: Mutates `anchor`; performs no file or network I/O.
     - Failure modes: Invalid local references become inert content instead of aborting import or
       reaching the external-link bridge.
     */
    private static func rewriteAnchor(
        _ anchor: EpubXMLElement,
        currentKey: String,
        sourcePath: String,
        package: EpubPackageDocument,
        resolver: EpubPackagePathResolver,
        resourceIdentity: EpubResourceIdentity
    ) {
        guard let hrefKey = anchor.attributes.keys.first(where: {
            ($0.split(separator: ":").last.map(String.init) ?? $0).lowercased() == "href"
        }), let href = anchor.attributes[hrefKey] else {
            return
        }
        anchor.attributes.removeValue(forKey: hrefKey)

        let resolved: EpubResolvedHref?
        do {
            resolved = try resolver.resolve(href, relativeTo: sourcePath)
        } catch {
            anchor.name = "span"
            return
        }

        guard let resolved else {
            anchor.name = "epubA"
            anchor.attributes["href"] = href
            return
        }

        if let targetKey = package.manifestIDByPath[resolved.path] {
            anchor.name = "epubRef"
            anchor.attributes["to-key"] = targetKey
            anchor.attributes["to-id"] = resolved.fragment ?? ""
            return
        }

        if resolved.path == sourcePath {
            anchor.name = "epubRef"
            anchor.attributes["to-key"] = currentKey
            anchor.attributes["to-id"] = resolved.fragment ?? ""
            return
        }

        anchor.name = "epubA"
        anchor.attributes["href"] = EpubResourceLocator.resourceURLString(
            identity: resourceIdentity,
            canonicalPath: resolved.path,
            fragment: resolved.fragment
        )
    }
}


/**
 Ports Android's stable non-Bible sentence splitting contract for BVA ordinal assignment.

 Ordinals back generic bookmark offsets, so punctuation and long-text splitting must be
 deterministic. The splitter favors the same punctuation/dash boundaries as Android and bisects
 very long pieces near whitespace to keep selectable anchor spans manageable.
 */
private enum EpubSentenceSplitter {
    /// Android's target maximum BVA text length.
    private static let targetMaximumLength = 150

    /// ICU expression equivalent to Android `SwordContentFacade.splitMatch`.
    private static let boundaryExpression = try? NSRegularExpression(
        pattern: #"((\d{2,}|\D)(([.,;:!?。，；][\"'\p{Pf}]?\p{Z}+)|(\p{Z}*\p{Pd}\p{Z}*)))([\"'¡¿\p{Pi}]?\p{L})"#
    )

    /**
     Splits one decoded XHTML text node without dropping whitespace or punctuation.

     - Parameter text: Decoded source text.
     - Returns: Ordered non-empty pieces whose concatenation equals `text`.
     - Side effects: None.
     */
    static func split(_ text: String) -> [String] {
        guard let expression = boundaryExpression else { return [text] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = expression.matches(in: text, range: fullRange)
        var pieces: [String] = []
        var current = ""
        var lastStart = 0

        for match in matches where match.numberOfRanges > 6 {
            let prefixLength = match.range.location - lastStart
            if prefixLength > 0 {
                current += nsText.substring(with: NSRange(location: lastStart, length: prefixLength))
            }
            current += nsText.substring(with: match.range(at: 1))
            appendLengthBoundPieces(current, to: &pieces)
            current = nsText.substring(with: match.range(at: 6))
            lastStart = NSMaxRange(match.range)
        }
        if lastStart < nsText.length {
            current += nsText.substring(from: lastStart)
        }
        if !current.isEmpty {
            appendLengthBoundPieces(current, to: &pieces)
        }
        return pieces.isEmpty ? [text] : pieces
    }

    /// Recursively divides a long sentence near its midpoint whitespace.
    private static func appendLengthBoundPieces(_ value: String, to pieces: inout [String]) {
        guard value.count > targetMaximumLength else {
            pieces.append(value)
            return
        }
        let midpoint = value.index(value.startIndex, offsetBy: value.count / 2)
        let suffix = value[midpoint...]
        let splitIndex = suffix.firstIndex(where: { $0.isWhitespace })
            ?? value[..<midpoint].lastIndex(where: { $0.isWhitespace })
        guard let splitIndex else {
            pieces.append(value)
            return
        }
        let rightStart = value.index(after: splitIndex)
        let left = String(value[..<rightStart])
        let right = String(value[rightStart...])
        guard !left.isEmpty, !right.isEmpty else {
            pieces.append(value)
            return
        }
        appendLengthBoundPieces(left, to: &pieces)
        appendLengthBoundPieces(right, to: &pieces)
    }
}
