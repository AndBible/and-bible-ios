// EpubPackageDocument.swift -- EPUB container, OPF, navigation, and XHTML semantics

import Foundation

/**
 Canonical path and fragment resolved inside an extracted EPUB package.

 `path` is always relative to the package root, uses forward slashes, and has already passed the
 package-containment check. `fragment` is decoded for HTML-id navigation.
 */
struct EpubResolvedHref: Equatable, Sendable {
    /// Canonical package-relative resource path.
    let path: String

    /// Optional decoded fragment identifier.
    let fragment: String?
}

/**
 Resolves EPUB URI references against package files without permitting root escape.

 EPUB OPF, navigation, XHTML, CSS, and media references all use URI-relative semantics. This
 resolver centralizes percent decoding and containment so every importer and resource-serving path
 applies the same contract.
 */
struct EpubPackagePathResolver: Sendable {
    /// Standardized extracted-package root URL.
    let packageRootURL: URL

    /**
     Creates a resolver rooted at one extracted EPUB directory.

     - Parameter packageRootURL: Directory containing `META-INF` and package resources.
     - Side effects: None.
     - Failure modes: Resolution methods fail when the supplied URL is not a local package path.
     */
    init(packageRootURL: URL) {
        self.packageRootURL = packageRootURL.standardizedFileURL
    }

    /**
     Resolves a local EPUB href relative to a package file.

     - Parameters:
       - rawHref: URI reference from container, OPF, navigation, XHTML, or CSS.
       - sourcePath: Canonical package-relative path of the referring file. An empty value resolves
         from the package root.
     - Returns: Canonical path and optional fragment, or `nil` for an external/non-file URI.
     - Side effects: None.
     - Throws: `EpubError.invalidEpub` when a local URI is malformed or escapes the package root.
     */
    func resolve(_ rawHref: String, relativeTo sourcePath: String) throws -> EpubResolvedHref? {
        let trimmed = rawHref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return sourcePath.isEmpty ? nil : EpubResolvedHref(path: sourcePath, fragment: nil)
        }

        let escapedSpaces = trimmed.replacingOccurrences(of: " ", with: "%20")
        guard let relativeURL = URL(string: escapedSpaces) else {
            throw EpubError.invalidEpub("Malformed package href: \(rawHref)")
        }
        if let scheme = relativeURL.scheme, !scheme.isEmpty {
            return nil
        }
        let percentEncodedPath = URLComponents(url: relativeURL, resolvingAgainstBaseURL: false)?
            .percentEncodedPath.lowercased() ?? ""
        guard !percentEncodedPath.contains("%2f"),
              !percentEncodedPath.contains("%5c"),
              !percentEncodedPath.contains("%00"),
              !relativeURL.path.contains("\\"),
              !relativeURL.path.contains("\0") else {
            throw EpubError.invalidEpub("Package href contains an encoded path separator: \(rawHref)")
        }

        let sourceURL = sourcePath.isEmpty
            ? packageRootURL.appendingPathComponent("package-root")
            : packageRootURL.appendingPathComponent(sourcePath)
        guard let resolvedURL = URL(string: escapedSpaces, relativeTo: sourceURL)?.absoluteURL,
              resolvedURL.isFileURL else {
            throw EpubError.invalidEpub("Malformed package href: \(rawHref)")
        }

        let standardized = resolvedURL.standardizedFileURL
        let rootPath = packageRootURL.path.hasSuffix("/")
            ? packageRootURL.path
            : packageRootURL.path + "/"
        guard standardized.path.hasPrefix(rootPath), standardized.path.count > rootPath.count else {
            throw EpubError.invalidEpub("Package href escapes the EPUB root: \(rawHref)")
        }

        let path = String(standardized.path.dropFirst(rootPath.count))
        guard !path.isEmpty, !path.split(separator: "/").contains("..") else {
            throw EpubError.invalidEpub("Invalid package path: \(rawHref)")
        }
        let fragment = relativeURL.fragment?.removingPercentEncoding ?? relativeURL.fragment
        return EpubResolvedHref(path: path, fragment: fragment?.isEmpty == true ? nil : fragment)
    }

    /**
     Returns a contained file URL for a previously canonical package path.

     - Parameter canonicalPath: Path produced by `resolve(_:relativeTo:)`.
     - Returns: Standardized file URL inside the package root.
     - Side effects: None.
     - Throws: `EpubError.invalidEpub` if a caller supplies a non-canonical or escaping path.
     */
    func fileURL(for canonicalPath: String) throws -> URL {
        guard !canonicalPath.isEmpty,
              !canonicalPath.hasPrefix("/"),
              !canonicalPath.hasPrefix("~"),
              !canonicalPath.contains("\\"),
              !canonicalPath.contains("\0") else {
            throw EpubError.invalidEpub("Invalid package resource path: \(canonicalPath)")
        }
        let pathComponents = canonicalPath.split(separator: "/", omittingEmptySubsequences: false)
        guard !pathComponents.isEmpty,
              pathComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw EpubError.invalidEpub("Invalid package resource path: \(canonicalPath)")
        }
        let fileURL = packageRootURL.appendingPathComponent(canonicalPath).standardizedFileURL
        let rootPath = packageRootURL.path.hasSuffix("/")
            ? packageRootURL.path
            : packageRootURL.path + "/"
        guard fileURL.path.hasPrefix(rootPath), fileURL.path.count > rootPath.count else {
            throw EpubError.invalidEpub("Package resource escapes the EPUB root: \(canonicalPath)")
        }
        return fileURL
    }
}

/**
 One OPF manifest resource with its canonical package location.
 */
struct EpubManifestItem: Equatable, Sendable {
    /// OPF manifest identifier used by EPUB links and the general-book adapter.
    let id: String

    /// Canonical package-relative resource path.
    let path: String

    /// Declared media type.
    let mediaType: String

    /// Whitespace-separated EPUB 3 manifest properties.
    let properties: Set<String>
}

/**
 One ordered OPF spine reference.
 */
struct EpubSpineItem: Equatable, Sendable {
    /// Referenced manifest identifier.
    let idref: String

    /// Whether the OPF marks this item as part of the linear reading order.
    let isLinear: Bool
}

/**
 One normalized EPUB navigation target.
 */
struct EpubNavigationPoint: Equatable, Sendable {
    /// User-visible TOC label.
    let title: String

    /// Target manifest identifier.
    let key: String

    /// Canonical target resource path.
    let href: String

    /// Optional target HTML identifier.
    let fragment: String?

    /// Zero-based nesting depth in the NCX or EPUB 3 navigation hierarchy.
    let depth: Int
}

/**
 Parsed EPUB package metadata and reading order.

 The model is produced only after container, OPF, manifest, and spine validation succeeds. All
 paths are canonical and package-contained, making it safe for indexing and later resource lookup.
 */
struct EpubPackageDocument: Sendable {
    /// Package title from Dublin Core metadata, or `nil` for Android's filename fallback.
    let title: String?

    /// Package description from Dublin Core metadata, or `nil` for Android's filename fallback.
    let description: String?

    /// Creator/author metadata.
    let author: String

    /// BCP-47-ish package language, defaulting to `en` when absent.
    let language: String

    /// Stable package identifier metadata when present.
    let packageIdentifier: String?

    /// Canonical OPF package document path.
    let opfPath: String

    /// Manifest resources keyed by OPF identifier.
    let manifestByID: [String: EpubManifestItem]

    /// Reverse manifest lookup keyed by canonical package path.
    let manifestIDByPath: [String: String]

    /// Spine items in package reading order.
    let spine: [EpubSpineItem]

    /// Flattened NCX or EPUB 3 TOC entries in document order.
    let navigation: [EpubNavigationPoint]
}

/**
 Parses EPUB container, OPF, NCX, and EPUB 3 navigation documents with structured XML traversal.

 The parser intentionally does not use regular expressions for XML. Namespace prefixes are treated
 as aliases and semantic matching uses local names, matching the prefix-independent EPUB contract.
 */
enum EpubPackageDocumentParser {
    /**
     Loads and validates an extracted EPUB package.

     - Parameter packageRootURL: Extracted package directory containing `META-INF/container.xml`.
     - Returns: Canonical package metadata, manifest, spine, and navigation.
     - Side effects: Reads container, OPF, and optional navigation files from disk.
     - Throws: `EpubError.invalidEpub`, XML parse errors, or file-system errors for missing and
       malformed required package resources.
     */
    static func parse(packageRootURL: URL) throws -> EpubPackageDocument {
        let resolver = EpubPackagePathResolver(packageRootURL: packageRootURL)
        let containerURL = packageRootURL
            .appendingPathComponent("META-INF", isDirectory: true)
            .appendingPathComponent("container.xml")
        let containerRoot = try EpubXMLTreeParser.parse(Data(contentsOf: containerURL))
        guard let rootfile = containerRoot.descendants(includeSelf: true)
            .first(where: { $0.localName == "rootfile" }),
              let rootfileHref = rootfile.attribute(localName: "full-path"),
              let resolvedOPF = try resolver.resolve(rootfileHref, relativeTo: "") else {
            throw EpubError.invalidEpub("META-INF/container.xml has no package rootfile")
        }

        let opfURL = try resolver.fileURL(for: resolvedOPF.path)
        let opfRoot = try EpubXMLTreeParser.parse(Data(contentsOf: opfURL))
        let allOPFElements = opfRoot.descendants(includeSelf: true)
        guard allOPFElements.contains(where: { $0.localName == "metadata" }),
              let manifest = allOPFElements.first(where: { $0.localName == "manifest" }),
              let spineElement = allOPFElements.first(where: { $0.localName == "spine" }) else {
            throw EpubError.invalidEpub("Package document is missing metadata, manifest, or spine")
        }

        let title = firstMetadataText(named: "title", in: opfRoot)
        let description = firstMetadataText(named: "description", in: opfRoot)
        let author = firstMetadataText(named: "creator", in: opfRoot) ?? ""
        let language = firstMetadataText(named: "language", in: opfRoot) ?? "en"
        let packageIdentifier = firstMetadataText(named: "identifier", in: opfRoot)

        var manifestByID: [String: EpubManifestItem] = [:]
        var manifestIDByPath: [String: String] = [:]
        for itemElement in directChildElements(of: manifest).filter({ $0.localName == "item" }) {
            guard let id = itemElement.attribute(localName: "id"), !id.isEmpty,
                  let href = itemElement.attribute(localName: "href"),
                  let mediaType = itemElement.attribute(localName: "media-type"),
                  let resolved = try resolver.resolve(href, relativeTo: resolvedOPF.path) else {
                throw EpubError.invalidEpub("Manifest contains an invalid local item")
            }
            guard manifestByID[id] == nil, manifestIDByPath[resolved.path] == nil else {
                throw EpubError.invalidEpub("Manifest contains duplicate ids or resource paths")
            }
            let properties = Set(
                (itemElement.attribute(localName: "properties") ?? "")
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
            )
            let item = EpubManifestItem(
                id: id,
                path: resolved.path,
                mediaType: mediaType.lowercased(),
                properties: properties
            )
            manifestByID[id] = item
            manifestIDByPath[resolved.path] = id
        }
        guard !manifestByID.isEmpty else {
            throw EpubError.invalidEpub("Package manifest is empty")
        }

        let itemReferences = directChildElements(of: spineElement).filter { $0.localName == "itemref" }
        var spine: [EpubSpineItem] = []
        for itemref in itemReferences {
            guard let idref = itemref.attribute(localName: "idref"), !idref.isEmpty,
                  manifestByID[idref] != nil else {
                throw EpubError.invalidEpub("Spine contains a missing manifest reference")
            }
            spine.append(EpubSpineItem(
                idref: idref,
                isLinear: itemref.attribute(localName: "linear")?.lowercased() != "no"
            ))
        }
        guard !spine.isEmpty else {
            throw EpubError.invalidEpub("Package spine has no valid manifest references")
        }

        let navigation = try parseNavigation(
            packageRootURL: packageRootURL,
            resolver: resolver,
            opfPath: resolvedOPF.path,
            manifestByID: manifestByID,
            manifestIDByPath: manifestIDByPath,
            spineElement: spineElement,
            spine: spine
        )

        return EpubPackageDocument(
            title: title,
            description: description,
            author: author,
            language: language,
            packageIdentifier: packageIdentifier,
            opfPath: resolvedOPF.path,
            manifestByID: manifestByID,
            manifestIDByPath: manifestIDByPath,
            spine: spine,
            navigation: navigation
        )
    }

    /// Returns direct element children without flattening nested structures.
    private static func directChildElements(of element: EpubXMLElement) -> [EpubXMLElement] {
        element.children.compactMap { child in
            guard case .element(let childElement) = child else { return nil }
            return childElement
        }
    }

    /**
     Reads the first non-empty metadata value whose resolved namespace is Dublin Core.

     Namespace declarations may live on the OPF package element rather than the metadata element,
     so traversal starts at the package root and carries inherited prefix bindings into descendants.
     Matching a local name alone is insufficient because EPUB metadata may legally contain extension
     elements such as `<vendor:title>` beside the canonical `<dc:title>`.

     - Parameters:
       - name: Dublin Core local name to resolve, such as `title` or `language`.
       - packageRoot: Parsed OPF root whose namespace scope owns the metadata descendants.
     - Returns: The normalized first non-empty Dublin Core value, or `nil` when none exists.
     - Side effects: none.
     - Failure modes: none; malformed XML is rejected before this parsed tree is supplied.
     */
    private static func firstMetadataText(
        named name: String,
        in packageRoot: EpubXMLElement
    ) -> String? {
        let dublinCoreNamespace = "http://purl.org/dc/elements/1.1/"

        func firstMatch(
            in element: EpubXMLElement,
            inheritedNamespaces: [String: String]
        ) -> String? {
            var namespaces = inheritedNamespaces
            for (qualifiedName, value) in element.attributes {
                if qualifiedName == "xmlns" {
                    namespaces[""] = value
                } else if qualifiedName.hasPrefix("xmlns:") {
                    namespaces[String(qualifiedName.dropFirst("xmlns:".count))] = value
                }
            }

            let qualifiedComponents = element.name
                .split(separator: ":", maxSplits: 1)
                .map(String.init)
            let prefix = qualifiedComponents.count == 2 ? qualifiedComponents[0] : ""
            if element.localName == name, namespaces[prefix] == dublinCoreNamespace {
                let value = element.textContent()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }

            for child in element.children {
                guard case .element(let childElement) = child,
                      let value = firstMatch(
                          in: childElement,
                          inheritedNamespaces: namespaces
                      ) else {
                    continue
                }
                return value
            }
            return nil
        }

        return firstMatch(in: packageRoot, inheritedNamespaces: [:])
    }

    /**
     Selects EPUB 3 nav, EPUB 2 NCX, or spine fallback navigation in that order.

     EPUB 3 nav is preferred when declared because it is the package's modern navigation contract.
     NCX remains supported for EPUB 2 and compatibility packages. A package without either gets a
     deterministic spine-derived chooser rather than an empty reader route.
     */
    private static func parseNavigation(
        packageRootURL: URL,
        resolver: EpubPackagePathResolver,
        opfPath: String,
        manifestByID: [String: EpubManifestItem],
        manifestIDByPath: [String: String],
        spineElement: EpubXMLElement,
        spine: [EpubSpineItem]
    ) throws -> [EpubNavigationPoint] {
        if let navItem = manifestByID.values.first(where: { $0.properties.contains("nav") }) {
            let points = try parseEPUB3Navigation(
                item: navItem,
                packageRootURL: packageRootURL,
                resolver: resolver,
                manifestIDByPath: manifestIDByPath
            )
            if !points.isEmpty {
                return points
            }
        }

        let ncxID = spineElement.attribute(localName: "toc")
            ?? manifestByID.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" })?.id
        if let ncxID, let ncxItem = manifestByID[ncxID] {
            let points = try parseNCXNavigation(
                item: ncxItem,
                packageRootURL: packageRootURL,
                resolver: resolver,
                manifestIDByPath: manifestIDByPath
            )
            if !points.isEmpty {
                return points
            }
        }

        return spine.enumerated().compactMap { index, spineItem in
            guard let item = manifestByID[spineItem.idref] else { return nil }
            let fallbackTitle = URL(fileURLWithPath: item.path)
                .deletingPathExtension()
                .lastPathComponent
            return EpubNavigationPoint(
                title: fallbackTitle.isEmpty ? "Section \(index + 1)" : fallbackTitle,
                key: item.id,
                href: item.path,
                fragment: nil,
                depth: 0
            )
        }
    }

    /// Parses nested EPUB 3 `<nav epub:type="toc">` lists into document-order targets.
    private static func parseEPUB3Navigation(
        item: EpubManifestItem,
        packageRootURL: URL,
        resolver: EpubPackagePathResolver,
        manifestIDByPath: [String: String]
    ) throws -> [EpubNavigationPoint] {
        let root = try EpubXMLTreeParser.parse(Data(contentsOf: resolver.fileURL(for: item.path)))
        guard let nav = root.descendants(includeSelf: true).first(where: { element in
            guard element.localName == "nav" else { return false }
            let typeValue = element.attribute(localName: "type") ?? ""
            return typeValue.split(whereSeparator: \.isWhitespace).contains("toc")
        }) else {
            return []
        }

        var result: [EpubNavigationPoint] = []
        for child in directChildElements(of: nav) where child.localName == "ol" {
            try appendNavigationList(
                child,
                depth: 0,
                sourcePath: item.path,
                resolver: resolver,
                manifestIDByPath: manifestIDByPath,
                result: &result
            )
        }
        return result
    }

    /// Recursively flattens one EPUB 3 ordered-list level while preserving depth.
    private static func appendNavigationList(
        _ list: EpubXMLElement,
        depth: Int,
        sourcePath: String,
        resolver: EpubPackagePathResolver,
        manifestIDByPath: [String: String],
        result: inout [EpubNavigationPoint]
    ) throws {
        for listItem in directChildElements(of: list) where listItem.localName == "li" {
            if let anchor = directChildElements(of: listItem).first(where: { $0.localName == "a" }),
               let rawHref = anchor.attribute(localName: "href"),
               let resolved = try resolver.resolve(rawHref, relativeTo: sourcePath),
               let key = manifestIDByPath[resolved.path] {
                let title = anchor.textContent().trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(EpubNavigationPoint(
                    title: title.isEmpty ? key : title,
                    key: key,
                    href: resolved.path,
                    fragment: resolved.fragment,
                    depth: depth
                ))
            }
            for childList in directChildElements(of: listItem) where childList.localName == "ol" {
                try appendNavigationList(
                    childList,
                    depth: depth + 1,
                    sourcePath: sourcePath,
                    resolver: resolver,
                    manifestIDByPath: manifestIDByPath,
                    result: &result
                )
            }
        }
    }

    /// Parses nested EPUB 2 NCX `navPoint` elements into document-order targets.
    private static func parseNCXNavigation(
        item: EpubManifestItem,
        packageRootURL: URL,
        resolver: EpubPackagePathResolver,
        manifestIDByPath: [String: String]
    ) throws -> [EpubNavigationPoint] {
        let root = try EpubXMLTreeParser.parse(Data(contentsOf: resolver.fileURL(for: item.path)))
        guard let navMap = root.descendants(includeSelf: true).first(where: { $0.localName == "navMap" }) else {
            return []
        }
        var result: [EpubNavigationPoint] = []
        try appendNCXPoints(
            directChildElements(of: navMap).filter { $0.localName == "navPoint" },
            depth: 0,
            sourcePath: item.path,
            resolver: resolver,
            manifestIDByPath: manifestIDByPath,
            result: &result
        )
        return result
    }

    /// Recursively flattens NCX points while keeping each point's own label and href isolated.
    private static func appendNCXPoints(
        _ points: [EpubXMLElement],
        depth: Int,
        sourcePath: String,
        resolver: EpubPackagePathResolver,
        manifestIDByPath: [String: String],
        result: inout [EpubNavigationPoint]
    ) throws {
        for point in points {
            let direct = directChildElements(of: point)
            let label = direct.first(where: { $0.localName == "navLabel" })?
                .textContent().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawHref = direct.first(where: { $0.localName == "content" })?
                .attribute(localName: "src")
            if let rawHref,
               let resolved = try resolver.resolve(rawHref, relativeTo: sourcePath),
               let key = manifestIDByPath[resolved.path] {
                result.append(EpubNavigationPoint(
                    title: label.isEmpty ? key : label,
                    key: key,
                    href: resolved.path,
                    fragment: resolved.fragment,
                    depth: depth
                ))
            }
            try appendNCXPoints(
                direct.filter { $0.localName == "navPoint" },
                depth: depth + 1,
                sourcePath: sourcePath,
                resolver: resolver,
                manifestIDByPath: manifestIDByPath,
                result: &result
            )
        }
    }
}

/**
 One transformed EPUB spine document ready for native-HTML rendering and search indexing.
 */
struct EpubTransformedDocument: Sendable {
    /// Original OPF manifest identifier used by EPUB link and TOC targets.
    let originalKey: String

    /// Canonical package-relative XHTML path.
    let href: String

    /// Canonical linked stylesheet paths declared by the XHTML head.
    let styleSheetPaths: [String]

    /// Android-shaped fragments in source reading order.
    let fragments: [EpubTransformedFragment]
}
