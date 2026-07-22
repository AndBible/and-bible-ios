// EpubAndroidOptimizedContent.swift -- validated Android optimized XHTML conversion

import Foundation

/**
 One internal-link target retained from Android's optimized native XHTML.

 The optimized index importer verifies these targets against `EpubHtmlToFrag` after every fragment
 is parsed, preventing a link from silently resolving to another document or fallback fragment.
 */
struct EpubAndroidInternalLinkTarget: Equatable, Hashable, Sendable {
    /// OPF manifest identifier written by Android as `to-key`.
    let originalKey: String

    /// Exact XHTML identifier written by Android as `to-id`, or the empty base-page target.
    let htmlID: String
}

/**
 Native iOS fragment plus the optimized Android links that still require database validation.
 */
struct EpubAndroidOptimizedTransformedFragment: Sendable {
    /// Render-ready fragment carrying Android's original BVA ordinal range.
    let fragment: EpubTransformedFragment

    /// Internal targets encountered in document order.
    let internalLinkTargets: [EpubAndroidInternalLinkTarget]
}

/**
 Validates and rewrites one gzip-decoded XHTML fragment produced by Android's EPUB optimizer.

 Android has already replaced the original body with a `div`, assigned BVA ordinals, converted local
 links to `epubRef`, and rewritten media to `/epub/<OPF-relative path>`. This transformer deliberately
 does not sentence-split again. It strips executable content, validates preserved ordinals, rewrites
 resources to an immutable iOS generation, and records links for exact Room-map verification.
 */
enum EpubAndroidOptimizedContentTransformer {
    /// Executable or nested-document elements omitted from imported native HTML.
    private static let blockedElements: Set<String> = ["script", "iframe", "object", "embed"]

    /**
     Converts one Android optimizer fragment to the native `EpubReader` content contract.

     - Parameters:
       - data: Gzip-decoded XML bytes from `optimized/<fragment id>.xhtml.gz`.
       - item: OPF spine item owned by the corresponding Room fragment row.
       - package: Parsed package used to validate `epubRef` manifest identities.
       - packageRootURL: Copied immutable package staging root.
       - resourceIdentity: Android initials and new immutable generation token.
       - expectedOrdinalRange: Inclusive `ordinalStart...ordinalEnd` from `EpubFragment`.
     - Returns: Sanitized native HTML, search anchors, IDs, and unresolved internal-link targets.
     - Side effects: Parses and mutates only an import-local XML tree; performs no writes or network
       access.
     - Throws: XML or `EpubError.invalidEpub` failures for malformed roots, ordinals, resources, or
       link identities. No partially transformed fragment is returned.
     */
    static func transform(
        data: Data,
        item: EpubManifestItem,
        package: EpubPackageDocument,
        packageRootURL: URL,
        resourceIdentity: EpubResourceIdentity,
        expectedOrdinalRange: ClosedRange<Int>
    ) throws -> EpubAndroidOptimizedTransformedFragment {
        let root = try EpubXMLTreeParser.parse(data)
        guard root.localName.lowercased() == "div" else {
            throw EpubError.invalidEpub(
                "Android optimized fragment for \(item.id) does not have a div root"
            )
        }
        let resolver = EpubPackagePathResolver(packageRootURL: packageRootURL)
        var linkTargets: [EpubAndroidInternalLinkTarget] = []
        try sanitizeAndRewrite(
            root,
            item: item,
            package: package,
            resolver: resolver,
            resourceIdentity: resourceIdentity,
            linkTargets: &linkTargets
        )
        addNativeDocumentClass(to: root)

        var anchors: [(ordinal: Int, text: String)] = []
        var priorOrdinal: Int?
        for element in root.descendants(includeSelf: true)
            where element.localName.lowercased() == "bva" {
            guard let rawOrdinal = element.attribute(localName: "ordinal"),
                  let ordinal = Int(rawOrdinal),
                  ordinal >= 0,
                  String(ordinal) == rawOrdinal,
                  priorOrdinal.map({ ordinal > $0 }) ?? true else {
                throw EpubError.invalidEpub(
                    "Android optimized fragment for \(item.id) has invalid BVA ordinals"
                )
            }
            priorOrdinal = ordinal
            anchors.append((ordinal: ordinal, text: element.textContent()))
        }
        if anchors.isEmpty {
            guard expectedOrdinalRange == 0...0 else {
                throw EpubError.invalidEpub(
                    "Android fragment ordinal range does not match its XHTML content"
                )
            }
        } else {
            guard anchors.first?.ordinal == expectedOrdinalRange.lowerBound,
                  anchors.last?.ordinal == expectedOrdinalRange.upperBound,
                  anchors.allSatisfy({ expectedOrdinalRange.contains($0.ordinal) }) else {
                throw EpubError.invalidEpub(
                    "Android fragment ordinal range does not match its XHTML content"
                )
            }
        }

        var seenHTMLIDs = Set<String>()
        var htmlIDs: [String] = []
        for element in root.descendants(includeSelf: true) {
            guard let htmlID = element.attribute(localName: "id"), !htmlID.isEmpty else { continue }
            guard seenHTMLIDs.insert(htmlID).inserted else {
                throw EpubError.invalidEpub(
                    "Android optimized fragment contains duplicate XHTML id \(htmlID)"
                )
            }
            htmlIDs.append(htmlID)
        }

        return EpubAndroidOptimizedTransformedFragment(
            fragment: EpubTransformedFragment(
                html: root.serializedXML(),
                plainText: anchors.map(\.text).joined(separator: " "),
                ordinalRange: expectedOrdinalRange,
                anchors: anchors,
                htmlIDs: htmlIDs
            ),
            internalLinkTargets: linkTargets
        )
    }

    /**
     Recursively strips blocked nodes and rewrites every retained element in place.

     - Parameters:
       - element: Current import-local XML element.
       - item: Owning OPF spine item for relative path resolution.
       - package: Parsed package used for internal-link validation.
       - resolver: Package-contained URI resolver.
       - resourceIdentity: Immutable route identity for media and CSS URLs.
       - linkTargets: Accumulator receiving validated `epubRef` targets.
     - Side effects: Mutates `element` and descendants and appends to `linkTargets`.
     - Throws: `EpubError.invalidEpub` for malformed links or unsafe local resource references.
     */
    private static func sanitizeAndRewrite(
        _ element: EpubXMLElement,
        item: EpubManifestItem,
        package: EpubPackageDocument,
        resolver: EpubPackagePathResolver,
        resourceIdentity: EpubResourceIdentity,
        linkTargets: inout [EpubAndroidInternalLinkTarget]
    ) throws {
        sanitizeAttributes(of: element)
        let localName = element.localName.lowercased()
        guard localName != "a" else {
            throw EpubError.invalidEpub("Android optimized fragment contains an unoptimized anchor")
        }
        try rewriteResourceAttributes(
            of: element,
            item: item,
            package: package,
            resolver: resolver,
            resourceIdentity: resourceIdentity
        )
        switch localName {
        case "epubref":
            let target = try validateInternalLink(element, package: package)
            linkTargets.append(target)
        case "epuba":
            try validateExternalLink(element)
        default:
            break
        }

        if localName == "style" {
            element.children = element.children.map { node in
                guard case .text(let css) = node else { return node }
                return .text(EpubCSSProcessor.process(
                    css,
                    styleSheetPath: item.path,
                    packageRootURL: resolver.packageRootURL,
                    resourceIdentity: resourceIdentity
                ))
            }
        }

        var retainedChildren: [EpubXMLNode] = []
        for child in element.children {
            guard case .element(let childElement) = child else {
                retainedChildren.append(child)
                continue
            }
            guard !blockedElements.contains(childElement.localName.lowercased()) else { continue }
            try sanitizeAndRewrite(
                childElement,
                item: item,
                package: package,
                resolver: resolver,
                resourceIdentity: resourceIdentity,
                linkTargets: &linkTargets
            )
            retainedChildren.append(.element(childElement))
        }
        element.children = retainedChildren
    }

    /**
     Removes event handlers and script URLs while preserving inert presentation attributes.

     - Parameter element: Import-local element whose attributes are filtered in place.
     - Side effects: Mutates `element.attributes` only.
     - Failure modes: None; dangerous attributes are removed rather than interpreted.
     */
    private static func sanitizeAttributes(of element: EpubXMLElement) {
        element.attributes = element.attributes.filter { key, value in
            let localName = attributeLocalName(key)
            if localName.hasPrefix("on") { return false }
            if ["href", "src", "data", "poster"].contains(localName),
               value.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("javascript:") {
                return false
            }
            return true
        }
    }

    /**
     Validates Android's already-converted internal link without permitting identity fallback.

     - Parameters:
       - element: `epubRef` element carrying `to-key` and optional `to-id`.
       - package: Parsed OPF manifest.
     - Returns: Exact target retained for later Room mapping verification.
     - Side effects: None.
     - Throws: `EpubError.invalidEpub` if `to-key` is absent or does not identify an XHTML/HTML
       manifest item, or if `to-id` contains a NUL scalar.
     */
    private static func validateInternalLink(
        _ element: EpubXMLElement,
        package: EpubPackageDocument
    ) throws -> EpubAndroidInternalLinkTarget {
        guard let originalKey = element.attribute(localName: "to-key"),
              !originalKey.isEmpty,
              let item = package.manifestByID[originalKey],
              item.mediaType == "application/xhtml+xml" || item.mediaType == "text/html" else {
            throw EpubError.invalidEpub("Android optimized fragment has an invalid epubRef target")
        }
        let htmlID = element.attribute(localName: "to-id") ?? ""
        guard !htmlID.contains("\0") else {
            throw EpubError.invalidEpub("Android optimized fragment has an invalid epubRef id")
        }
        return EpubAndroidInternalLinkTarget(originalKey: originalKey, htmlID: htmlID)
    }

    /**
     Restricts Android `epubA` elements to the HTTP(S) links its optimizer generates.

     - Parameter element: External-link element to validate.
     - Side effects: None.
     - Throws: `EpubError.invalidEpub` when the href is absent, malformed, or uses another scheme.
     */
    private static func validateExternalLink(_ element: EpubXMLElement) throws {
        guard let href = element.attribute(localName: "href"),
              let components = URLComponents(string: href),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw EpubError.invalidEpub("Android optimized fragment has an invalid epubA target")
        }
    }

    /**
     Rewrites local media, inline CSS, and source-set attributes to immutable resource URLs.

     - Parameters:
       - element: Retained native XHTML element.
       - item: Owning spine item for ordinary relative references.
       - package: Package model whose OPF path anchors Android `/epub/` references.
       - resolver: Containment-enforcing package resolver.
       - resourceIdentity: Generation-scoped custom route identity.
     - Side effects: Mutates resource-bearing attributes in `element`.
     - Throws: `EpubError.invalidEpub` for malformed, external, or escaping resource references.
     */
    private static func rewriteResourceAttributes(
        of element: EpubXMLElement,
        item: EpubManifestItem,
        package: EpubPackageDocument,
        resolver: EpubPackagePathResolver,
        resourceIdentity: EpubResourceIdentity
    ) throws {
        let elementName = element.localName.lowercased()
        let resourceAttributes: Set<String> = elementName == "epubref" || elementName == "epuba"
            ? ["src", "poster", "data"]
            : ["src", "poster", "data", "href"]
        for key in Array(element.attributes.keys) {
            let localName = attributeLocalName(key)
            guard let value = element.attributes[key] else { continue }
            if localName == "style" {
                let processed = EpubCSSProcessor.processInlineDeclarations(
                    value,
                    sourcePath: item.path,
                    packageRootURL: resolver.packageRootURL,
                    resourceIdentity: resourceIdentity
                )
                if processed.isEmpty {
                    element.attributes.removeValue(forKey: key)
                } else {
                    element.attributes[key] = processed
                }
                continue
            }
            if localName == "srcset" {
                element.attributes[key] = try rewriteSourceSet(
                    value,
                    item: item,
                    package: package,
                    resolver: resolver,
                    resourceIdentity: resourceIdentity
                )
                continue
            }
            guard resourceAttributes.contains(localName) else { continue }
            if isEmbeddedDataResource(value) {
                continue
            }
            let resolved = try resolveAndroidResource(
                value,
                item: item,
                package: package,
                resolver: resolver
            )
            element.attributes[key] = EpubResourceLocator.resourceURLString(
                identity: resourceIdentity,
                canonicalPath: resolved.path,
                fragment: resolved.fragment
            )
        }
    }

    /**
     Resolves Android's optimizer URL form or an untouched XHTML-relative resource reference.

     - Parameters:
       - rawValue: Attribute URL from optimized markup.
       - item: Owning spine item.
       - package: Parsed package whose OPF directory is Android's resource root.
       - resolver: Package-contained URI resolver.
     - Returns: Canonical package path and optional fragment.
     - Side effects: None.
     - Throws: `EpubError.invalidEpub` when the value is empty, external, malformed, or escaping.
     */
    private static func resolveAndroidResource(
        _ rawValue: String,
        item: EpubManifestItem,
        package: EpubPackageDocument,
        resolver: EpubPackagePathResolver
    ) throws -> EpubResolvedHref {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let androidPrefix = "/epub/"
        let href: String
        let sourcePath: String
        if trimmed.hasPrefix(androidPrefix) {
            href = String(trimmed.dropFirst(androidPrefix.count))
            sourcePath = package.opfPath
        } else {
            href = trimmed
            sourcePath = item.path
        }
        guard !href.isEmpty,
              let resolved = try resolver.resolve(href, relativeTo: sourcePath) else {
            throw EpubError.invalidEpub("Android optimized fragment has an unsafe resource path")
        }
        return resolved
    }

    /**
     Rewrites each local URL in a `srcset` while preserving width/density descriptors.

     - Parameters:
       - value: Raw `srcset` attribute.
       - item: Owning spine item.
       - package: Parsed package for Android root-relative paths.
       - resolver: Package-contained URI resolver.
       - resourceIdentity: Generation-scoped route identity.
     - Returns: Canonical comma-separated source set.
     - Side effects: None.
     - Throws: `EpubError.invalidEpub` when any candidate is malformed or escapes the package.
     */
    private static func rewriteSourceSet(
        _ value: String,
        item: EpubManifestItem,
        package: EpubPackageDocument,
        resolver: EpubPackagePathResolver,
        resourceIdentity: EpubResourceIdentity
    ) throws -> String {
        var result: [String] = []
        var cursor = value.startIndex
        while cursor < value.endIndex {
            while cursor < value.endIndex, value[cursor].isWhitespace || value[cursor] == "," {
                cursor = value.index(after: cursor)
            }
            guard cursor < value.endIndex else { break }
            let urlStart = cursor
            while cursor < value.endIndex, !value[cursor].isWhitespace, value[cursor] != "," {
                cursor = value.index(after: cursor)
            }
            let rawURL = String(value[urlStart..<cursor])
            while cursor < value.endIndex, value[cursor].isWhitespace {
                cursor = value.index(after: cursor)
            }
            let descriptorStart = cursor
            while cursor < value.endIndex, value[cursor] != "," {
                cursor = value.index(after: cursor)
            }
            let descriptor = String(value[descriptorStart..<cursor])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cursor < value.endIndex {
                cursor = value.index(after: cursor)
            }
            let rewritten: String
            if isEmbeddedDataResource(rawURL) {
                rewritten = rawURL
            } else {
                let resolved = try resolveAndroidResource(
                    rawURL,
                    item: item,
                    package: package,
                    resolver: resolver
                )
                rewritten = EpubResourceLocator.resourceURLString(
                    identity: resourceIdentity,
                    canonicalPath: resolved.path,
                    fragment: resolved.fragment
                )
            }
            result.append(descriptor.isEmpty ? rewritten : "\(rewritten) \(descriptor)")
        }
        guard !result.isEmpty else {
            throw EpubError.invalidEpub("Android optimized fragment has an empty srcset")
        }
        return result.joined(separator: ", ")
    }

    /**
     Reports whether one media URL is self-contained and requires no package lookup.

     - Parameter value: Raw resource or `srcset` candidate value.
     - Returns: `true` only when the trimmed value begins with the case-insensitive `data:` scheme.
     - Side effects: None.
     - Failure modes: None; malformed data URLs remain inert browser input and are not decoded here.
     */
    private static func isEmbeddedDataResource(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("data:")
    }

    /**
     Adds the same native wrapper class produced by ordinary raw-XHTML transformation.

     - Parameter root: Android fragment root to update.
     - Side effects: Rewrites the class attribute without duplicating `epub-native-document`.
     - Failure modes: None.
     */
    private static func addNativeDocumentClass(to root: EpubXMLElement) {
        let classKey = root.attributes.keys.first { attributeLocalName($0) == "class" }
        let existing = classKey.flatMap { root.attributes.removeValue(forKey: $0) } ?? ""
        var classes = existing.split(whereSeparator: \.isWhitespace).map(String.init)
        if !classes.contains("epub-native-document") {
            classes.append("epub-native-document")
        }
        root.attributes["class"] = classes.joined(separator: " ")
    }

    /**
     Returns a namespace-independent lowercase attribute name.

     - Parameter qualifiedName: Qualified XML attribute name.
     - Returns: Lowercase final component after an optional namespace prefix.
     - Side effects: None.
     - Failure modes: None.
     */
    private static func attributeLocalName(_ qualifiedName: String) -> String {
        (qualifiedName.split(separator: ":").last.map(String.init) ?? qualifiedName).lowercased()
    }
}
