// EpubReader.swift -- EPUB file reader with ZIP extraction, XML parsing, and FTS5 indexing

import Foundation
import SQLite3
import CLibSword

/**
 SQLite destructor marker that forces SQLite to copy bound strings and blobs.

 Swift's bridged UTF-8 buffers are temporary, so bindings used across `sqlite3_step` must
 request a SQLite-owned copy to avoid reading freed memory.
 */
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Describes one installed EPUB package discovered in the app's extracted-EPUB directory.

 The identifier is a sanitized directory name used for storage and reopening. The remaining
 fields are read from the EPUB's generated SQLite metadata table.
 */
public struct EpubInfo: Sendable {
    /// Sanitized directory name and stable lookup key for the installed EPUB.
    public let identifier: String

    /// User-visible title read from the generated SQLite metadata table.
    public let title: String

    /// User-visible author/creator value read from the EPUB metadata.
    public let author: String

    /// Language code stored in EPUB metadata, defaulting to `en` when absent.
    public let language: String
}

/**
 Reads EPUB content by extracting the package into app storage and indexing it into SQLite.

 The reader has two phases:
 1. installation: unzip into `Documents/epub/<identifier>` and build a companion
    `<identifier>.index.sqlite3` database
 2. runtime access: open the generated index, load metadata/TOC, and serve rewritten XHTML plus
    FTS5-backed search results

 The indexed `content` table stores rewritten HTML for rendering, while `content_fts` stores
 plain text for full-text search. The HTML rewrite stage converts EPUB-internal links into
 `<epubRef>` tags and image paths into `file://` URLs that WKWebView can load directly.

 - Important: `EpubReader` is marked `@unchecked Sendable` so higher-level import and reading
   flows can move reader instances across actor boundaries without copying extracted-package
   state. The class does not provide internal synchronization for `indexDb`, so callers must
   serialize access to a given instance and avoid overlapping SQLite operations from multiple
   tasks, threads, or actors.
 */
public final class EpubReader: @unchecked Sendable {
    /// Filesystem directory containing the extracted EPUB package contents.
    private let epubDir: String

    /// Read-only SQLite handle for the generated companion index database.
    private var indexDb: OpaquePointer?

    /// User-visible EPUB title loaded from the generated metadata table.
    public private(set) var title: String = ""

    /// User-visible EPUB author/creator loaded from the generated metadata table.
    public private(set) var author: String = ""

    /// EPUB language code loaded from the generated metadata table.
    public private(set) var language: String = "en"

    /// Stable identifier used for storage, reopening, and list presentation.
    public let identifier: String

    /**
     Represents one flattened table-of-contents row from the indexed EPUB navigation tree.

     The ordinal is the insertion order used for list presentation and for reconstructing the
     original reading sequence.
     */
    public struct TOCEntry: Sendable {
        /// User-visible title from the NCX or fallback spine-generated table of contents.
        public let title: String

        /// Relative EPUB href used to fetch the corresponding indexed content row.
        public let href: String

        /// Zero-based TOC ordering stored in the companion SQLite index.
        public let ordinal: Int
    }

    // MARK: - Static Install/Manage API

    /// Root directory containing all extracted EPUB packages managed by the app.
    private static var epubBaseDir: String {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        return (docs as NSString).appendingPathComponent("epub")
    }

    /**
     Installs an EPUB into the app-managed library and builds its companion search index.

     - Parameter epubURL: Security-scoped URL chosen by the user.
     - Returns: Sanitized identifier used as the extracted directory name and reopen key.
     - Throws: `EpubError.invalidEpub` when the archive cannot be parsed, `EpubError.indexingFailed`
       when the extracted package cannot be indexed, or any file-I/O errors thrown by
       `FileManager` and `Data`.
     - Important: This method mutates on-disk app storage by deleting any prior install for the
       same identifier, writing extracted package files, and creating a new SQLite index.
     */
    public static func install(epubURL: URL) throws -> String {
        let fm = FileManager.default
        let baseName = epubURL.deletingPathExtension().lastPathComponent
        let ident = sanitizeIdentifier(baseName)
        let destDir = (epubBaseDir as NSString).appendingPathComponent(ident)

        // Remove existing if re-installing
        if fm.fileExists(atPath: destDir) {
            try fm.removeItem(atPath: destDir)
        }
        let indexPath = destDir + ".index.sqlite3"
        if fm.fileExists(atPath: indexPath) {
            try fm.removeItem(atPath: indexPath)
        }

        // Create destination directory
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        // Read and extract ZIP
        let accessing = epubURL.startAccessingSecurityScopedResource()
        defer { if accessing { epubURL.stopAccessingSecurityScopedResource() } }

        let zipData = try Data(contentsOf: epubURL)
        let entries = try parseZip(zipData)
        guard !entries.isEmpty else {
            throw EpubError.invalidEpub("ZIP file is empty")
        }

        // Extract all files
        for entry in entries {
            let filePath = (destDir as NSString).appendingPathComponent(entry.name)
            let fileDir = (filePath as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: fileDir, withIntermediateDirectories: true)
            try entry.data.write(to: URL(fileURLWithPath: filePath))
        }

        // Build the index
        guard buildIndex(epubDir: destDir, indexPath: indexPath) else {
            // Clean up on failure
            try? fm.removeItem(atPath: destDir)
            try? fm.removeItem(atPath: indexPath)
            throw EpubError.indexingFailed
        }

        return ident
    }

    /**
     Lists all extracted EPUBs that have a valid companion SQLite index.

     - Returns: Installed EPUB metadata sorted by title using localized case-insensitive order.
     - Note: Directories without an `.index.sqlite3` file are ignored so partially extracted or
       damaged installs do not surface in the library UI.
     */
    public static func installedEpubs() -> [EpubInfo] {
        let fm = FileManager.default
        let base = epubBaseDir
        guard fm.fileExists(atPath: base) else { return [] }

        var results: [EpubInfo] = []
        guard let items = try? fm.contentsOfDirectory(atPath: base) else { return [] }

        for item in items {
            let itemPath = (base as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: itemPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let indexPath = itemPath + ".index.sqlite3"
            guard fm.fileExists(atPath: indexPath) else { continue }

            // Read metadata from index
            var db: OpaquePointer?
            guard sqlite3_open_v2(indexPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { continue }
            defer { sqlite3_close(db) }

            let title = getMetaValueStatic(db: db, key: "title") ?? item
            let author = getMetaValueStatic(db: db, key: "author") ?? ""
            let language = getMetaValueStatic(db: db, key: "language") ?? "en"

            results.append(EpubInfo(identifier: item, title: title, author: author, language: language))
        }

        return results.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /**
     Deletes an installed EPUB package directory and its companion SQLite index.

     - Parameter identifier: Sanitized EPUB identifier previously returned by `install(epubURL:)`.
     - Note: Missing files are ignored. The method has filesystem side effects but does not throw.
     */
    public static func delete(identifier: String) {
        let fm = FileManager.default
        let dir = (epubBaseDir as NSString).appendingPathComponent(identifier)
        let indexPath = dir + ".index.sqlite3"
        try? fm.removeItem(atPath: dir)
        try? fm.removeItem(atPath: indexPath)
    }

    // MARK: - Instance API

    /**
     Opens a previously installed EPUB by identifier.

     - Parameter identifier: Sanitized identifier returned by `install(epubURL:)`.
     - Note: Initialization fails when either the extracted directory or companion SQLite index
       is missing, or when the index cannot be opened read-only.
     */
    public init?(identifier: String) {
        self.identifier = identifier
        let dir = Self.epubBaseDir
        self.epubDir = (dir as NSString).appendingPathComponent(identifier)

        guard FileManager.default.fileExists(atPath: epubDir) else { return nil }

        let indexPath = epubDir + ".index.sqlite3"
        guard FileManager.default.fileExists(atPath: indexPath) else { return nil }

        guard sqlite3_open_v2(indexPath, &indexDb, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }

        loadMetadata()
    }

    deinit {
        sqlite3_close(indexDb)
    }

    /// Filesystem path to the extracted EPUB directory used for image loading and debugging.
    public var extractedPath: String { epubDir }

    /**
     Loads the flattened table of contents from the generated SQLite index.

     - Returns: TOC entries ordered by their stored ordinal.
     */
    public func tableOfContents() -> [TOCEntry] {
        let query = "SELECT title, href, ordinal FROM toc ORDER BY ordinal"
        var entries: [TOCEntry] = []

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(indexDb, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let title = String(cString: sqlite3_column_text(stmt, 0))
            let href = String(cString: sqlite3_column_text(stmt, 1))
            let ordinal = Int(sqlite3_column_int(stmt, 2))
            entries.append(TOCEntry(title: title, href: href, ordinal: ordinal))
        }

        return entries
    }

    /**
     Returns rewritten HTML for one EPUB content section.

     - Parameter href: Relative EPUB href, optionally including a fragment identifier.
     - Returns: Rewritten body HTML suitable for the web renderer, or `nil` when the section is
       not present in the generated index.
     */
    public func getContent(href: String) -> String? {
        // Try exact match first
        if let content = queryContent(href: href) { return content }
        // Try without fragment
        let base = href.components(separatedBy: "#").first ?? href
        if base != href, let content = queryContent(href: base) { return content }
        return nil
    }

    /**
     Resolves the best available display title for a content href.

     The lookup checks the indexed `content` row first and falls back to the TOC table because
     NCX hrefs may include fragments while the content table stores base hrefs.

     - Parameter href: Relative EPUB href, optionally including a fragment identifier.
     - Returns: The best available section title, or `nil` when neither indexed content nor the
       flattened TOC contains a matching href.
     */
    public func getTitle(href: String) -> String? {
        let base = href.components(separatedBy: "#").first ?? href

        // Try content table (exact match)
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(indexDb, "SELECT title FROM content WHERE href = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, base, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) == SQLITE_ROW, let textPtr = sqlite3_column_text(stmt, 0) {
                let title = String(cString: textPtr)
                sqlite3_finalize(stmt)
                if !title.isEmpty { return title }
            } else {
                sqlite3_finalize(stmt)
            }
        }

        // Try TOC table (base href match — TOC hrefs may have fragments)
        stmt = nil
        if sqlite3_prepare_v2(indexDb, "SELECT title, href FROM toc", -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let titlePtr = sqlite3_column_text(stmt, 0),
                      let hrefPtr = sqlite3_column_text(stmt, 1) else { continue }
                let tocHref = String(cString: hrefPtr)
                let tocBase = tocHref.components(separatedBy: "#").first ?? tocHref
                if tocBase == base {
                    return String(cString: titlePtr)
                }
            }
        }

        return nil
    }

    /**
     Executes an FTS5 phrase search across the indexed plain-text content.

     - Parameter query: User-entered search text. Double quotes are escaped before binding.
     - Returns: Matching href/title/snippet tuples ordered by SQLite's FTS5 default ranking.
     */
    public func search(query: String) -> [(href: String, title: String, snippet: String)] {
        // Sanitize query for FTS5
        let sanitized = query.replacingOccurrences(of: "\"", with: "\"\"")
        let ftsQuery = "\"\(sanitized)\""

        let sql = "SELECT href, title, snippet(content_fts, 2, '<b>', '</b>', '...', 32) FROM content_fts WHERE content_fts MATCH ?"
        var results: [(String, String, String)] = []

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(indexDb, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, ftsQuery, -1, SQLITE_TRANSIENT)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let href = String(cString: sqlite3_column_text(stmt, 0))
            let title = String(cString: sqlite3_column_text(stmt, 1))
            let snippet = String(cString: sqlite3_column_text(stmt, 2))
            results.append((href, title, snippet))
        }

        return results
    }

    // MARK: - Private Instance

    /// Loads the cached title, author, and language values from the generated metadata table.
    private func loadMetadata() {
        if let t = getMetaValue("title") { title = t }
        if let a = getMetaValue("author") { author = a }
        if let l = getMetaValue("language") { language = l }
    }

    /// Reads one metadata value from the open SQLite index for this EPUB instance.
    private func getMetaValue(_ key: String) -> String? {
        Self.getMetaValueStatic(db: indexDb, key: key)
    }

    /// Reads one metadata value from an arbitrary EPUB index database handle.
    private static func getMetaValueStatic(db: OpaquePointer?, key: String) -> String? {
        let query = "SELECT value FROM metadata WHERE key = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let textPtr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: textPtr)
    }

    /// Returns the stored rewritten HTML for one exact href from the `content` table.
    private func queryContent(href: String) -> String? {
        let query = "SELECT content FROM content WHERE href = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(indexDb, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, href, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let textPtr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: textPtr)
    }

    // MARK: - Index Building (Static)

    /**
     Builds the companion SQLite index for an extracted EPUB package.

     Pipeline:
     1. read `META-INF/container.xml` to locate `content.opf`
     2. parse the OPF metadata, manifest, and spine
     3. parse NCX navigation when present, otherwise synthesize a TOC from the spine
     4. create SQLite tables `metadata`, `toc`, `content`, and `content_fts`
     5. rewrite each spine XHTML body for WKWebView and index its plain text for FTS5

     - Parameters:
       - epubDir: Filesystem path to the extracted EPUB root directory.
       - indexPath: Filesystem path for the generated SQLite index.
     - Returns: `true` on success, otherwise `false`.
     - Important: This method performs file I/O, XML parsing, SQLite writes, and FTS5 indexing.
     */
    private static func buildIndex(epubDir: String, indexPath: String) -> Bool {
        // 1. Parse container.xml → find rootfile path
        let containerPath = (epubDir as NSString).appendingPathComponent("META-INF/container.xml")
        guard let containerData = FileManager.default.contents(atPath: containerPath),
              let rootfilePath = parseContainerXML(containerData) else {
            return false
        }

        // Determine content base directory (OPF location)
        let opfFullPath = (epubDir as NSString).appendingPathComponent(rootfilePath)
        let opfDir = (rootfilePath as NSString).deletingLastPathComponent

        // 2. Parse content.opf → metadata + manifest + spine
        guard let opfData = FileManager.default.contents(atPath: opfFullPath),
              let opf = parseOPF(opfData) else {
            return false
        }

        // 3. Parse TOC (NCX or nav.xhtml)
        var tocEntries: [(title: String, href: String)] = []
        if let ncxId = opf.manifest.first(where: { $0.value.mediaType == "application/x-dtbncx+xml" })?.key {
            let ncxHref = opf.manifest[ncxId]!.href
            let ncxPath = opfDir.isEmpty ? ncxHref : (opfDir as NSString).appendingPathComponent(ncxHref)
            let ncxFullPath = (epubDir as NSString).appendingPathComponent(ncxPath)
            if let ncxData = FileManager.default.contents(atPath: ncxFullPath) {
                tocEntries = parseNCX(ncxData)
            }
        }

        // Fallback: if no TOC, use spine items as TOC
        if tocEntries.isEmpty {
            for (idx, spineId) in opf.spine.enumerated() {
                if let item = opf.manifest[spineId] {
                    tocEntries.append((title: "Section \(idx + 1)", href: item.href))
                }
            }
        }

        // 4. Create SQLite index
        var db: OpaquePointer?
        guard sqlite3_open_v2(indexPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_close(db) }

        // Enable WAL mode
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)

        let schema = """
            CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS toc (ordinal INTEGER PRIMARY KEY, title TEXT, href TEXT);
            CREATE TABLE IF NOT EXISTS content (href TEXT PRIMARY KEY, title TEXT, content TEXT, plain_text TEXT);
            CREATE VIRTUAL TABLE IF NOT EXISTS content_fts USING fts5(href, title, plain_text, tokenize='unicode61');
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { return false }

        // 5. Insert metadata
        insertMeta(db: db, key: "title", value: opf.title)
        insertMeta(db: db, key: "author", value: opf.author)
        insertMeta(db: db, key: "language", value: opf.language)

        // 6. Insert TOC entries
        for (idx, entry) in tocEntries.enumerated() {
            insertTOC(db: db, ordinal: idx, title: entry.title, href: entry.href)
        }

        // 7. Extract and insert content for each spine item
        var processedHrefs = Set<String>()
        for spineId in opf.spine {
            guard let item = opf.manifest[spineId] else { continue }
            let href = item.href
            guard !processedHrefs.contains(href) else { continue }
            processedHrefs.insert(href)

            let contentPath = opfDir.isEmpty ? href : (opfDir as NSString).appendingPathComponent(href)
            let contentFullPath = (epubDir as NSString).appendingPathComponent(contentPath)

            guard let xhtmlData = FileManager.default.contents(atPath: contentFullPath),
                  let xhtmlString = String(data: xhtmlData, encoding: .utf8) else { continue }

            // Extract body content
            let bodyHTML = extractBody(xhtmlString)

            // Rewrite links and images
            let imageBase = "file://" + (contentFullPath as NSString).deletingLastPathComponent
            let rewrittenHTML = rewriteContent(bodyHTML, imageBase: imageBase)

            // Strip HTML tags for plain text (FTS indexing)
            let plainText = stripHTMLTags(rewrittenHTML)

            // Find title from TOC or use filename
            let entryTitle = tocEntries.first(where: { tocHrefMatches($0.href, href) })?.title ?? (href as NSString).deletingPathExtension

            insertContent(db: db, href: href, title: entryTitle, content: rewrittenHTML, plainText: plainText)
        }

        return true
    }

    // MARK: - XML Parsing

    /// Parses `META-INF/container.xml` and returns the relative path to the package OPF file.
    private static func parseContainerXML(_ data: Data) -> String? {
        let parser = ContainerXMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.rootfilePath
    }

    /// Parses `content.opf` into metadata, manifest, and spine structures used for indexing.
    private static func parseOPF(_ data: Data) -> OPFResult? {
        let parser = OPFXMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()

        guard !parser.spine.isEmpty else { return nil }
        return OPFResult(
            title: parser.title.isEmpty ? "Untitled" : parser.title,
            author: parser.author,
            language: parser.language.isEmpty ? "en" : parser.language,
            manifest: parser.manifest,
            spine: parser.spine
        )
    }

    /// Parses an NCX navigation document into a flat TOC sequence.
    private static func parseNCX(_ data: Data) -> [(title: String, href: String)] {
        let parser = NCXXMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.entries
    }

    // MARK: - Content Processing

    /// Extracts the inner `<body>` HTML from an XHTML document for storage and later rendering.
    private static func extractBody(_ xhtml: String) -> String {
        // Find <body...> opening tag
        guard let bodyStart = xhtml.range(of: "<body", options: .caseInsensitive) else {
            return xhtml
        }
        // Find the closing ">" of the body tag
        guard let bodyTagEnd = xhtml.range(of: ">", range: bodyStart.upperBound..<xhtml.endIndex) else {
            return xhtml
        }
        // Find </body>
        guard let bodyClose = xhtml.range(of: "</body>", options: .caseInsensitive) else {
            return String(xhtml[bodyTagEnd.upperBound...])
        }
        return String(xhtml[bodyTagEnd.upperBound..<bodyClose.lowerBound])
    }

    /**
     Rewrites raw EPUB body HTML into the renderer-specific form used by the app.

     Image sources are rewritten to absolute `file://` URLs, and links are rewritten into
     `<epubRef>` for internal navigation or `<epubA>` for external links.
     */
    private static func rewriteContent(_ html: String, imageBase: String) -> String {
        var result = html

        // Rewrite <img src="..."> to absolute file:// paths
        result = rewriteImageSources(result, imageBase: imageBase)

        // Rewrite <a href="..."> to <epubRef> or <epubA>
        result = rewriteLinks(result)

        return result
    }

    /// Rewrites relative `<img src>` paths into absolute `file://` URLs for WKWebView loading.
    private static func rewriteImageSources(_ html: String, imageBase: String) -> String {
        // Match <img ... src="..." ...> and rewrite src to absolute file:// URL
        var result = html
        let imgPattern = try! NSRegularExpression(pattern: #"(<img\b[^>]*?\bsrc\s*=\s*")([^"]+)(")"#, options: .caseInsensitive)
        let range = NSRange(result.startIndex..., in: result)
        let matches = imgPattern.matches(in: result, range: range).reversed()

        for match in matches {
            guard match.numberOfRanges >= 4,
                  let srcRange = Range(match.range(at: 2), in: result) else { continue }
            let src = String(result[srcRange])
            if !src.hasPrefix("http") && !src.hasPrefix("file://") && !src.hasPrefix("data:") {
                let absoluteSrc = imageBase + "/" + src
                result.replaceSubrange(srcRange, with: absoluteSrc)
            }
        }
        return result
    }

    /**
     Rewrites EPUB anchor tags into the app's internal navigation tags.

     Internal links become `<epubRef>` with split key/fragment attributes. External links remain
     clickable via `<epubA>`.
     */
    private static func rewriteLinks(_ html: String) -> String {
        var result = html
        // Match <a href="...">...</a> — rewrite to epubRef for internal, epubA for external
        let linkPattern = try! NSRegularExpression(
            pattern: #"<a\b([^>]*?\bhref\s*=\s*")([^"]+)("[^>]*)>(.*?)</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let range = NSRange(result.startIndex..., in: result)
        let matches = linkPattern.matches(in: result, range: range).reversed()

        for match in matches {
            guard match.numberOfRanges >= 5,
                  let fullRange = Range(match.range, in: result),
                  let hrefRange = Range(match.range(at: 2), in: result),
                  let contentRange = Range(match.range(at: 4), in: result) else { continue }

            let href = String(result[hrefRange])
            let content = String(result[contentRange])

            if href.hasPrefix("http://") || href.hasPrefix("https://") || href.hasPrefix("mailto:") {
                // External link → <epubA>
                let replacement = "<epubA href=\"\(href)\">\(content)</epubA>"
                result.replaceSubrange(fullRange, with: replacement)
            } else {
                // Internal link → <epubRef>
                let parts = href.components(separatedBy: "#")
                let toKey = parts[0]
                let toId = parts.count > 1 ? parts[1] : ""
                let replacement = "<epubRef to-key=\"\(toKey)\" to-id=\"\(toId)\">\(content)</epubRef>"
                result.replaceSubrange(fullRange, with: replacement)
            }
        }

        return result
    }

    /// Removes tags and decodes common entities to produce FTS5-searchable plain text.
    private static func stripHTMLTags(_ html: String) -> String {
        var text = html
        // Remove tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode common entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&apos;", with: "'")
        text = text.replacingOccurrences(of: "&#160;", with: " ")
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        // Collapse whitespace
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return text
    }

    /// Compares a TOC href and a content href while ignoring any fragment identifier.
    private static func tocHrefMatches(_ tocHref: String, _ contentHref: String) -> Bool {
        let tocBase = tocHref.components(separatedBy: "#").first ?? tocHref
        return tocBase == contentHref
    }

    // MARK: - SQLite Helpers

    /// Inserts or replaces one metadata row in the generated EPUB index.
    private static func insertMeta(db: OpaquePointer?, key: String, value: String) {
        let sql = "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// Inserts or replaces one table-of-contents row in the generated EPUB index.
    private static func insertTOC(db: OpaquePointer?, ordinal: Int, title: String, href: String) {
        let sql = "INSERT OR REPLACE INTO toc (ordinal, title, href) VALUES (?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(ordinal))
        sqlite3_bind_text(stmt, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, href, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /**
     Inserts one content row and its paired FTS5 row into the generated EPUB index.

     The `content` table stores rewritten HTML plus plain text, while `content_fts` stores the
     searchable projection used by FTS5.
     */
    private static func insertContent(db: OpaquePointer?, href: String, title: String, content: String, plainText: String) {
        // Insert into content table
        let sql1 = "INSERT OR REPLACE INTO content (href, title, content, plain_text) VALUES (?, ?, ?, ?)"
        var stmt1: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql1, -1, &stmt1, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt1) }
        sqlite3_bind_text(stmt1, 1, href, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt1, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt1, 3, content, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt1, 4, plainText, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt1)

        // Insert into FTS5 table
        let sql2 = "INSERT INTO content_fts (href, title, plain_text) VALUES (?, ?, ?)"
        var stmt2: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql2, -1, &stmt2, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt2) }
        sqlite3_bind_text(stmt2, 1, href, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt2, 2, title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt2, 3, plainText, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt2)
    }

    // MARK: - ZIP Parsing

    /// One local file entry extracted from the EPUB ZIP archive.
    private struct ZipEntry {
        let name: String
        let data: Data
    }

    /**
     Parses local-file ZIP entries from the EPUB archive and inflates supported payloads.

     - Parameter data: Raw EPUB archive bytes.
     - Returns: Extracted file entries excluding directory records.
     - Throws: `EpubError.decompressionFailed` when a deflated member cannot be inflated.
     - Note: Only stored (`0`) and deflated (`8`) compression methods are supported.
     */
    private static func parseZip(_ data: Data) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        var offset = 0

        while offset + 30 <= data.count {
            // Local file header signature: 0x04034b50
            let sig = data.subdata(in: offset..<offset+4)
            guard sig == Data([0x50, 0x4b, 0x03, 0x04]) else { break }

            let method = readUInt16(data, at: offset + 8)
            let compressedSize = Int(readUInt32(data, at: offset + 18))
            let uncompressedSize = Int(readUInt32(data, at: offset + 22))
            let nameLen = Int(readUInt16(data, at: offset + 26))
            let extraLen = Int(readUInt16(data, at: offset + 28))

            let nameStart = offset + 30
            guard nameStart + nameLen <= data.count else { break }
            let name = String(data: data[nameStart..<nameStart+nameLen], encoding: .utf8) ?? ""

            let dataStart = nameStart + nameLen + extraLen
            guard dataStart + compressedSize <= data.count else { break }
            let compressedData = data[dataStart..<dataStart+compressedSize]

            if !name.isEmpty && !name.hasSuffix("/") {
                let fileData: Data
                switch method {
                case 0: // Stored
                    fileData = Data(compressedData)
                case 8: // Deflated
                    fileData = try inflateData(Data(compressedData), uncompressedSize: uncompressedSize)
                default:
                    offset = dataStart + compressedSize
                    continue
                }
                entries.append(ZipEntry(name: name, data: fileData))
            }

            offset = dataStart + compressedSize
        }

        return entries
    }

    /// Reads a little-endian `UInt16` from the ZIP byte stream.
    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        return data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    /// Reads a little-endian `UInt32` from the ZIP byte stream.
    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        return data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    /**
     Inflates a deflated ZIP member using the C adapter provided by `CLibSword`.

     - Parameters:
       - compressed: Deflated payload bytes.
       - uncompressedSize: Expected uncompressed size from the ZIP header.
     - Throws: `EpubError.decompressionFailed` when the adapter cannot inflate the payload.
     */
    private static func inflateData(_ compressed: Data, uncompressedSize: Int) throws -> Data {
        return try compressed.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = ptr.baseAddress else {
                throw EpubError.decompressionFailed
            }

            var outputLen: UInt = 0
            guard let output = inflate_raw_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(compressed.count),
                UInt(uncompressedSize),
                &outputLen
            ) else {
                throw EpubError.decompressionFailed
            }

            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLen))
        }
    }

    // MARK: - Helpers

    /// Replaces unsupported filesystem characters so EPUB titles become stable directory names.
    private static func sanitizeIdentifier(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
    }
}

// MARK: - Errors

/**
 Enumerates install and indexing failures for EPUB ingestion.

 These errors are surfaced during user-driven import and describe invalid archives,
 decompression failures, and index-construction failures.
 */
public enum EpubError: LocalizedError {
    /// The archive structure or required EPUB metadata was invalid, with a reason string.
    case invalidEpub(String)
    case decompressionFailed
    case indexingFailed

    /// User-visible error description presented by import flows.
    public var errorDescription: String? {
        switch self {
        case .invalidEpub(let msg): return "Invalid EPUB: \(msg)"
        case .decompressionFailed: return "Failed to decompress EPUB data"
        case .indexingFailed: return "Failed to build EPUB index"
        }
    }
}

// MARK: - OPF Data Structures

/// One manifest item parsed from `content.opf`.
private struct ManifestItem {
    /// Relative resource href as declared in the OPF manifest.
    let href: String

    /// Declared MIME/media type for the resource.
    let mediaType: String
}

/// Aggregate result produced by OPF parsing before SQLite indexing begins.
private struct OPFResult {
    /// Resolved package title, defaulting to `Untitled` when absent.
    let title: String

    /// Resolved package author/creator string.
    let author: String

    /// Resolved package language code, defaulting to `en` when absent.
    let language: String

    /// Manifest items keyed by OPF manifest identifier.
    let manifest: [String: ManifestItem]  // id → ManifestItem

    /// Ordered list of manifest identifiers representing the reading spine.
    let spine: [String]  // ordered list of manifest IDs
}

// MARK: - XML Parser Delegates

/**
 XML parser delegate for `META-INF/container.xml`.

 The delegate extracts the `full-path` attribute from the first `rootfile` element so the
 indexer can locate `content.opf`.
 */
private class ContainerXMLParser: NSObject, XMLParserDelegate {
    /// Relative path to the package OPF file discovered in `container.xml`.
    var rootfilePath: String?

    /// Captures the `full-path` attribute from the `<rootfile>` element.
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "rootfile" || elementName.hasSuffix(":rootfile") {
            rootfilePath = attributeDict["full-path"]
        }
    }
}

/**
 XML parser delegate for `content.opf`.

 The delegate collects Dublin Core metadata plus the manifest and spine ordering needed to
 rewrite and index reading content.
 */
private class OPFXMLParser: NSObject, XMLParserDelegate {
    /// First non-empty title found in the OPF metadata section.
    var title = ""

    /// First non-empty creator value found in the OPF metadata section.
    var author = ""

    /// First non-empty language value found in the OPF metadata section.
    var language = ""

    /// Manifest items keyed by OPF manifest identifier.
    var manifest: [String: ManifestItem] = [:]

    /// Ordered spine manifest identifiers used to determine reading order.
    var spine: [String] = []

    /// Current local XML element name used while parsing metadata text.
    private var currentElement = ""

    /// Character buffer for the current metadata text node.
    private var currentText = ""

    /// Whether the parser is currently inside the OPF metadata block.
    private var inMetadata = false

    /// Collects manifest items, spine order, and metadata text as the OPF stream is parsed.
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        currentElement = localName
        currentText = ""

        switch localName {
        case "metadata":
            inMetadata = true
        case "item":
            if let id = attributeDict["id"],
               let href = attributeDict["href"],
               let mediaType = attributeDict["media-type"] {
                manifest[id] = ManifestItem(href: href, mediaType: mediaType)
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                spine.append(idref)
            }
        default:
            break
        }
    }

    /// Appends character data while the parser is inside the OPF metadata block.
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inMetadata { currentText += string }
    }

    /// Commits buffered metadata text when an OPF metadata element closes.
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        if localName == "metadata" {
            inMetadata = false
            return
        }

        guard inMetadata else { return }
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch localName {
        case "title":
            if title.isEmpty { title = trimmed }
        case "creator":
            if author.isEmpty { author = trimmed }
        case "language":
            if language.isEmpty { language = trimmed }
        default:
            break
        }
    }
}

/**
 XML parser delegate for NCX navigation documents.

 The parser flattens the NCX navigation hierarchy into a linear TOC sequence used by the app's
 library and reader navigation UI.
 */
private class NCXXMLParser: NSObject, XMLParserDelegate {
    /// Flattened NCX entries captured in parse order.
    var entries: [(title: String, href: String)] = []

    /// Whether the parser is currently inside a `navPoint`.
    private var inNavPoint = false

    /// Whether the parser is currently inside a `navLabel`.
    private var inNavLabel = false

    /// Whether the parser is currently buffering `<text>` node content.
    private var inText = false

    /// Title for the current top-level navigation point.
    private var currentTitle = ""

    /// Href for the current top-level navigation point.
    private var currentHref = ""

    /// Character buffer for the current NCX text node.
    private var currentText = ""

    /// Nested `navPoint` depth used to flatten the hierarchy safely.
    private var depth = 0

    /// Tracks NCX hierarchy and captures titles/hrefs for navigation points.
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        switch localName {
        case "navPoint":
            if depth == 0 {
                currentTitle = ""
                currentHref = ""
            }
            depth += 1
            inNavPoint = true
        case "navLabel":
            inNavLabel = true
        case "text":
            if inNavLabel {
                inText = true
                currentText = ""
            }
        case "content":
            if inNavPoint {
                currentHref = attributeDict["src"] ?? ""
            }
        default:
            break
        }
    }

    /// Buffers character data for the current NCX `<text>` node.
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { currentText += string }
    }

    /// Finalizes NCX titles and appends completed navigation entries.
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName

        switch localName {
        case "text":
            if inText {
                currentTitle = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                inText = false
            }
        case "navLabel":
            inNavLabel = false
        case "navPoint":
            depth -= 1
            if !currentTitle.isEmpty && !currentHref.isEmpty {
                entries.append((title: currentTitle, href: currentHref))
            }
            if depth == 0 {
                currentTitle = ""
                currentHref = ""
            }
        default:
            break
        }
    }
}
