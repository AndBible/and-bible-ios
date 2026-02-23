// EpubReader.swift — EPUB file reader with ZIP extraction, XML parsing, and FTS5 indexing

import Foundation
import SQLite3
import CLibSword

/// SQLITE_TRANSIENT tells SQLite to make its own copy of bound text/blob data.
/// Required because Swift's auto-bridged C string buffers are temporary and may
/// be deallocated before sqlite3_step executes.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Metadata for an installed EPUB.
public struct EpubInfo: Sendable {
    public let identifier: String  // Sanitized directory name
    public let title: String
    public let author: String
    public let language: String
}

/// Reads EPUB files for Bible study content.
/// Uses a SQLite index for efficient content access.
public final class EpubReader: @unchecked Sendable {
    private let epubDir: String
    private var indexDb: OpaquePointer?

    /// EPUB metadata.
    public private(set) var title: String = ""
    public private(set) var author: String = ""
    public private(set) var language: String = "en"
    public let identifier: String

    /// Table of contents entries.
    public struct TOCEntry: Sendable {
        public let title: String
        public let href: String
        public let ordinal: Int
    }

    // MARK: - Static Install/Manage API

    /// Base directory for all installed EPUBs.
    private static var epubBaseDir: String {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
        return (docs as NSString).appendingPathComponent("epub")
    }

    /// Install an EPUB file. Returns the identifier on success.
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

    /// List all installed EPUBs.
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

    /// Delete an installed EPUB and its index.
    public static func delete(identifier: String) {
        let fm = FileManager.default
        let dir = (epubBaseDir as NSString).appendingPathComponent(identifier)
        let indexPath = dir + ".index.sqlite3"
        try? fm.removeItem(atPath: dir)
        try? fm.removeItem(atPath: indexPath)
    }

    // MARK: - Instance API

    /// Open an installed EPUB by identifier.
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

    /// The filesystem path to the extracted EPUB directory.
    public var extractedPath: String { epubDir }

    /// Get the table of contents.
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

    /// Get HTML content for a section by href.
    public func getContent(href: String) -> String? {
        // Try exact match first
        if let content = queryContent(href: href) { return content }
        // Try without fragment
        let base = href.components(separatedBy: "#").first ?? href
        if base != href, let content = queryContent(href: base) { return content }
        return nil
    }

    /// Get the title for a section by href.
    /// Checks the content table first (exact match), then the TOC table (base href match).
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

    /// Search the EPUB content.
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

    private func loadMetadata() {
        if let t = getMetaValue("title") { title = t }
        if let a = getMetaValue("author") { author = a }
        if let l = getMetaValue("language") { language = l }
    }

    private func getMetaValue(_ key: String) -> String? {
        Self.getMetaValueStatic(db: indexDb, key: key)
    }

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
            let rewrittenHTML = rewriteContent(bodyHTML, imageBase: imageBase, spineHrefs: Set(opf.spine.compactMap { opf.manifest[$0]?.href }))

            // Strip HTML tags for plain text (FTS indexing)
            let plainText = stripHTMLTags(rewrittenHTML)

            // Find title from TOC or use filename
            let entryTitle = tocEntries.first(where: { tocHrefMatches($0.href, href) })?.title ?? (href as NSString).deletingPathExtension

            insertContent(db: db, href: href, title: entryTitle, content: rewrittenHTML, plainText: plainText)
        }

        return true
    }

    // MARK: - XML Parsing

    /// Parse META-INF/container.xml → rootfile path
    private static func parseContainerXML(_ data: Data) -> String? {
        let parser = ContainerXMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.rootfilePath
    }

    /// Parse content.opf → metadata + manifest + spine
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

    /// Parse NCX file → flat list of TOC entries
    private static func parseNCX(_ data: Data) -> [(title: String, href: String)] {
        let parser = NCXXMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.parse()
        return parser.entries
    }

    // MARK: - Content Processing

    /// Extract the inner content of <body> from XHTML.
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

    /// Rewrite internal links to <epubRef> and images to file:// URLs.
    private static func rewriteContent(_ html: String, imageBase: String, spineHrefs: Set<String>) -> String {
        var result = html

        // Rewrite <img src="..."> to absolute file:// paths
        result = rewriteImageSources(result, imageBase: imageBase)

        // Rewrite <a href="..."> to <epubRef> or <epubA>
        result = rewriteLinks(result, spineHrefs: spineHrefs)

        return result
    }

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

    private static func rewriteLinks(_ html: String, spineHrefs: Set<String>) -> String {
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

    /// Strip HTML tags to get plain text for FTS indexing.
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

    /// Check if a TOC href matches a content href (may differ by fragment).
    private static func tocHrefMatches(_ tocHref: String, _ contentHref: String) -> Bool {
        let tocBase = tocHref.components(separatedBy: "#").first ?? tocHref
        return tocBase == contentHref
    }

    // MARK: - SQLite Helpers

    private static func insertMeta(db: OpaquePointer?, key: String, value: String) {
        let sql = "INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

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

    private struct ZipEntry {
        let name: String
        let data: Data
    }

    /// Parse ZIP file data and extract all entries.
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

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        return data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        return data.withUnsafeBytes { ptr in
            ptr.load(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    /// Inflate deflated data using the C adapter's inflate_raw_data().
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

    private static func sanitizeIdentifier(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("_") })
    }
}

// MARK: - Errors

public enum EpubError: LocalizedError {
    case invalidEpub(String)
    case decompressionFailed
    case indexingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidEpub(let msg): return "Invalid EPUB: \(msg)"
        case .decompressionFailed: return "Failed to decompress EPUB data"
        case .indexingFailed: return "Failed to build EPUB index"
        }
    }
}

// MARK: - OPF Data Structures

private struct ManifestItem {
    let href: String
    let mediaType: String
}

private struct OPFResult {
    let title: String
    let author: String
    let language: String
    let manifest: [String: ManifestItem]  // id → ManifestItem
    let spine: [String]  // ordered list of manifest IDs
}

// MARK: - XML Parser Delegates

/// Parses META-INF/container.xml to find the rootfile path.
private class ContainerXMLParser: NSObject, XMLParserDelegate {
    var rootfilePath: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        if elementName == "rootfile" || elementName.hasSuffix(":rootfile") {
            rootfilePath = attributeDict["full-path"]
        }
    }
}

/// Parses content.opf to extract metadata, manifest, and spine.
private class OPFXMLParser: NSObject, XMLParserDelegate {
    var title = ""
    var author = ""
    var language = ""
    var manifest: [String: ManifestItem] = [:]
    var spine: [String] = []

    private var currentElement = ""
    private var currentText = ""
    private var inMetadata = false

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

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inMetadata { currentText += string }
    }

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

/// Parses NCX (Navigation Control for XML) to extract table of contents.
private class NCXXMLParser: NSObject, XMLParserDelegate {
    var entries: [(title: String, href: String)] = []

    private var inNavPoint = false
    private var inNavLabel = false
    private var inText = false
    private var currentTitle = ""
    private var currentHref = ""
    private var currentText = ""
    private var depth = 0

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

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { currentText += string }
    }

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
