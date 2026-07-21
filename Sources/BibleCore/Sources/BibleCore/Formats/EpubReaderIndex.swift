// EpubReaderIndex.swift -- SQLite schema and EPUB index construction

import Foundation
import SQLite3

extension EpubReader {
    // MARK: - Index construction

    /**
     Builds a complete SQLite index for one extracted package.

     Every valid spine item must be transformed and inserted before the transaction commits. This
     prevents the issue-354 class of partial success from recurring in EPUB form.
     */
    static func buildIndex(
        packageRootURL: URL,
        indexURL: URL,
        resourceIdentity: EpubResourceIdentity,
        sourceFileName: String?
    ) throws {
        let package = try EpubPackageDocumentParser.parse(packageRootURL: packageRootURL)
        let database = try createIndexDatabase(at: indexURL)
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw EpubError.indexingFailed(Self.sqliteMessage(database))
        }

        do {
            try insertMetadata(
                package: package,
                resourceIdentity: resourceIdentity,
                sourceFileName: sourceFileName,
                database: database
            )

            var insertedContentCount = 0
            var nextFragmentID = 1
            for (spineOrdinal, spineItem) in package.spine.enumerated() {
                guard let item = package.manifestByID[spineItem.idref] else {
                    throw EpubError.invalidEpub("Spine references missing item \(spineItem.idref)")
                }
                guard item.mediaType == "application/xhtml+xml" || item.mediaType == "text/html" else {
                    if spineItem.isLinear {
                        throw EpubError.invalidEpub("Unsupported linear spine media type \(item.mediaType)")
                    }
                    continue
                }
                let transformed = try EpubContentTransformer.transform(
                    item: item,
                    package: package,
                    packageRootURL: packageRootURL,
                    resourceIdentity: resourceIdentity
                )
                let pageTitle = package.navigation.first(where: { $0.key == item.id })?.title
                    ?? URL(fileURLWithPath: item.path).deletingPathExtension().lastPathComponent
                for (fragmentOrdinal, fragment) in transformed.fragments.enumerated() {
                    try insertContent(
                        fragment,
                        id: nextFragmentID,
                        originalKey: transformed.originalKey,
                        href: transformed.href,
                        styleSheetPaths: transformed.styleSheetPaths,
                        title: pageTitle.isEmpty ? item.id : pageTitle,
                        spineOrdinal: spineOrdinal,
                        fragmentOrdinal: fragmentOrdinal,
                        database: database
                    )
                    if fragmentOrdinal == 0 {
                        try insertAnchorMapping(
                            originalKey: transformed.originalKey,
                            htmlID: "",
                            fragmentID: nextFragmentID,
                            database: database
                        )
                    }
                    for htmlID in fragment.htmlIDs {
                        try insertAnchorMapping(
                            originalKey: transformed.originalKey,
                            htmlID: htmlID,
                            fragmentID: nextFragmentID,
                            database: database
                        )
                    }
                    nextFragmentID += 1
                    insertedContentCount += 1
                }
            }
            guard insertedContentCount > 0 else {
                throw EpubError.invalidEpub("Package has no renderable spine content")
            }
            for (ordinal, point) in package.navigation.enumerated() {
                try insertNavigation(point, ordinal: ordinal, database: database)
            }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw EpubError.indexingFailed(Self.sqliteMessage(database))
            }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /**
     Creates an empty current-version EPUB index for a staged immutable generation.

     Raw archive imports and Android optimized-tree imports share this exact schema so every
     `EpubReader` API can open either source shape without runtime format branches.

     - Parameter indexURL: Staging destination for the new SQLite database.
     - Returns: Open read/write SQLite connection that the caller owns and must close.
     - Side effects: Removes any prior file at `indexURL`, creates a database, and installs the
       complete EPUB schema outside a transaction.
     - Throws: File-system or `EpubError.indexingFailed` errors when SQLite cannot create the schema.
     - Important: The returned connection contains no metadata or content and no open transaction.
     */
    static func createIndexDatabase(at indexURL: URL) throws -> OpaquePointer {
        try? FileManager.default.removeItem(at: indexURL)
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            indexURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw EpubError.indexingFailed("Unable to create SQLite index")
        }

        let schema = """
            PRAGMA journal_mode=DELETE;
            PRAGMA foreign_keys=ON;
            CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE toc (
                ordinal INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                key TEXT NOT NULL,
                href TEXT NOT NULL,
                fragment TEXT,
                depth INTEGER NOT NULL
            );
            CREATE TABLE content (
                id INTEGER PRIMARY KEY,
                original_key TEXT NOT NULL,
                href TEXT NOT NULL,
                title TEXT NOT NULL,
                content TEXT NOT NULL,
                plain_text TEXT NOT NULL,
                ordinal_start INTEGER NOT NULL,
                ordinal_end INTEGER NOT NULL,
                spine_ordinal INTEGER NOT NULL,
                fragment_ordinal INTEGER NOT NULL,
                UNIQUE (spine_ordinal, fragment_ordinal)
            );
            CREATE TABLE anchor_map (
                original_key TEXT NOT NULL,
                html_id TEXT NOT NULL,
                fragment_id INTEGER NOT NULL REFERENCES content(id) ON DELETE CASCADE,
                PRIMARY KEY (original_key, html_id)
            );
            CREATE TABLE styles (
                original_key TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                path TEXT NOT NULL,
                PRIMARY KEY (original_key, ordinal)
            );
            CREATE VIRTUAL TABLE content_fts USING fts5(
                contentText,
                key UNINDEXED,
                href UNINDEXED,
                title UNINDEXED,
                ordinal UNINDEXED,
                tokenize='unicode61'
            );
            """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            let message = sqliteMessage(database)
            sqlite3_close(database)
            try? FileManager.default.removeItem(at: indexURL)
            throw EpubError.indexingFailed(message)
        }
        return database
    }

    /**
     Inserts package, Android identity, source filename, and index-version metadata.

     - Parameters:
       - package: Parsed package whose descriptive metadata and OPF path are persisted.
       - resourceIdentity: Stable Android initials and immutable generation identifier.
       - sourceFileName: Exact import display name, or `nil` for legacy callers.
       - database: Open writable native EPUB index with an active caller-owned transaction.
     - Side effects: Inserts the complete metadata key set into `database`.
     - Throws: `EpubError.indexingFailed` when any SQLite statement cannot be completed.
     - Important: This method neither starts nor commits a transaction.
     */
    static func insertMetadata(
        package: EpubPackageDocument,
        resourceIdentity: EpubResourceIdentity,
        sourceFileName: String?,
        database: OpaquePointer?
    ) throws {
        let values: [(String, String)] = [
            ("index_version", indexVersion),
            ("initials", resourceIdentity.bookInitials),
            ("generation", resourceIdentity.generationIdentifier),
            ("source_file_name", sourceFileName ?? ""),
            ("title", package.title),
            ("author", package.author),
            ("language", package.language),
            ("identifier", package.packageIdentifier ?? ""),
            ("opf_path", package.opfPath)
        ]
        for (key, value) in values {
            try execute(
                "INSERT INTO metadata (key, value) VALUES (?, ?)",
                texts: [key, value],
                integers: [],
                database: database
            )
        }
    }

    /**
     Inserts one flattened navigation point when its exact content target was indexed.

     - Parameters:
       - point: Parsed navigation entry carrying the manifest key, href, fragment, and depth.
       - ordinal: Stable zero-based order in the flattened table of contents.
       - database: Open writable native EPUB index with an active caller-owned transaction.
     - Side effects: Reads `anchor_map` and may insert one `toc` row into `database`.
     - Throws: `EpubError.indexingFailed` when SQLite lookup or insertion fails.
     - Note: An unmapped target is omitted instead of being redirected to another fragment.
     */
    static func insertNavigation(
        _ point: EpubNavigationPoint,
        ordinal: Int,
        database: OpaquePointer?
    ) throws {
        guard let fragmentID = try mappedFragmentID(
            originalKey: point.key,
            htmlID: point.fragment,
            database: database
        ) else { return }
        try execute(
            "INSERT INTO toc (ordinal, title, key, href, fragment, depth) VALUES (?, ?, ?, ?, ?, ?)",
            texts: [point.title, String(fragmentID), point.href, point.fragment],
            integers: [Int64(ordinal), Int64(point.depth)],
            database: database,
            bindingOrder: [.integer(0), .text(0), .text(1), .text(2), .text(3), .integer(1)]
        )
    }

    /**
     Inserts one transformed fragment and its associated native lookup/search rows.

     - Parameters:
       - content: Sanitized fragment HTML, plain text, ordinal range, and BVA anchors.
       - id: Exact positive persisted fragment key.
       - originalKey: Owning OPF manifest identifier.
       - href: Canonical package path of the original spine document.
       - styleSheetPaths: Canonical linked stylesheets, stored once on the first fragment.
       - title: Reader-visible page title.
       - spineOrdinal: Position of the source document in OPF reading order.
       - fragmentOrdinal: Position of this fragment within the source document.
       - database: Open writable native EPUB index with an active caller-owned transaction.
     - Side effects: Inserts `content`, optional `styles`, and one FTS row per BVA anchor.
     - Throws: `EpubError.indexingFailed` when any SQLite insertion fails.
     - Important: The caller must insert anchor mappings separately after all content rows exist.
     */
    static func insertContent(
        _ content: EpubTransformedFragment,
        id: Int,
        originalKey: String,
        href: String,
        styleSheetPaths: [String],
        title: String,
        spineOrdinal: Int,
        fragmentOrdinal: Int,
        database: OpaquePointer?
    ) throws {
        try execute(
            """
            INSERT INTO content
                (id, original_key, href, title, content, plain_text, ordinal_start, ordinal_end,
                 spine_ordinal, fragment_ordinal)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            texts: [originalKey, href, title, content.html, content.plainText],
            integers: [
                Int64(id),
                Int64(content.ordinalRange.lowerBound),
                Int64(content.ordinalRange.upperBound),
                Int64(spineOrdinal),
                Int64(fragmentOrdinal)
            ],
            database: database,
            bindingOrder: [
                .integer(0), .text(0), .text(1), .text(2), .text(3), .text(4),
                .integer(1), .integer(2), .integer(3), .integer(4)
            ]
        )
        if fragmentOrdinal == 0 {
            for (ordinal, path) in styleSheetPaths.enumerated() {
                try execute(
                    "INSERT INTO styles (original_key, ordinal, path) VALUES (?, ?, ?)",
                    texts: [originalKey, path],
                    integers: [Int64(ordinal)],
                    database: database,
                    bindingOrder: [.text(0), .integer(0), .text(1)]
                )
            }
        }
        for anchor in content.anchors {
            try execute(
                """
                INSERT INTO content_fts
                    (contentText, key, href, title, ordinal)
                VALUES (?, ?, ?, ?, ?)
                """,
                texts: [
                    anchor.text,
                    String(id),
                    href,
                    title
                ],
                integers: [Int64(anchor.ordinal)],
                database: database,
                bindingOrder: [
                    .text(0), .text(1), .text(2), .text(3), .integer(0)
                ]
            )
        }
    }

    /**
     Inserts one exact OPF/XHTML target-to-fragment mapping.

     - Parameters:
       - originalKey: Owning OPF manifest identifier.
       - htmlID: Exact XHTML identifier, or an empty string for the document base.
       - fragmentID: Persisted numeric content key that owns the target.
       - database: Open writable native EPUB index with an active caller-owned transaction.
     - Side effects: Inserts or replaces one `anchor_map` row in `database`.
     - Throws: `EpubError.indexingFailed` when SQLite rejects the mapping.
     - Note: Replacement mirrors Android Room's primary-key conflict behavior for cloned IDs.
     */
    static func insertAnchorMapping(
        originalKey: String,
        htmlID: String,
        fragmentID: Int,
        database: OpaquePointer?
    ) throws {
        try execute(
            "INSERT OR REPLACE INTO anchor_map (original_key, html_id, fragment_id) VALUES (?, ?, ?)",
            texts: [originalKey, htmlID],
            integers: [Int64(fragmentID)],
            database: database,
            bindingOrder: [.text(0), .text(1), .integer(0)]
        )
    }

    /// Reads one source-target mapping while constructing navigation rows.
    private static func mappedFragmentID(
        originalKey: String,
        htmlID: String?,
        database: OpaquePointer?
    ) throws -> Int? {
        let sql = """
            SELECT fragment_id FROM anchor_map
            WHERE original_key = ? AND html_id = ?
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw EpubError.indexingFailed(sqliteMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        bindText(originalKey, to: statement, index: 1)
        bindText(htmlID ?? "", to: statement, index: 2)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Binding kinds used by the compact SQLite insert helper.
    private enum SQLBinding {
        /// String/optional-string index in the supplied text array.
        case text(Int)

        /// Integer index in the supplied integer array.
        case integer(Int)
    }

    /// Executes one prepared SQLite mutation and throws its diagnostic on failure.
    private static func execute(
        _ sql: String,
        texts: [String?],
        integers: [Int64],
        database: OpaquePointer?,
        bindingOrder: [SQLBinding]? = nil
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw EpubError.indexingFailed(sqliteMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        let order = bindingOrder ?? texts.indices.map(SQLBinding.text)
        for (position, binding) in order.enumerated() {
            switch binding {
            case .text(let index):
                if let value = texts[index] {
                    bindText(value, to: statement, index: Int32(position + 1))
                } else {
                    sqlite3_bind_null(statement, Int32(position + 1))
                }
            case .integer(let index):
                sqlite3_bind_int64(statement, Int32(position + 1), integers[index])
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw EpubError.indexingFailed(sqliteMessage(database))
        }
    }

    /// Reports whether a companion index uses the current schema/transform version.
    static func indexIsCurrent(indexURL: URL) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(indexURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return false
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM metadata WHERE key = 'index_version'",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return columnText(statement, index: 0) == indexVersion
    }

    /// Reads one metadata value from an older index before rebuilding it in place.
    static func metadataValue(at indexURL: URL, key: String) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(indexURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT value FROM metadata WHERE key = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(key, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, index: 0)
    }


    /// Binds one Swift string to a prepared SQLite statement.
    static func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, epubSQLiteTransient)
    }

    /// Reads an optional UTF-8 SQLite column.
    static func columnText(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    /**
     Reads the current SQLite connection diagnostic for EPUB index and query operations.

     - Parameter database: Open SQLite connection, or `nil` after an open failure.
     - Returns: SQLite's current diagnostic or a stable unavailable-connection message.
     - Side effects: Reads SQLite connection state without mutating it.
     - Failure modes: None; a missing connection returns a deterministic fallback string.
     */
    static func sqliteMessage(_ database: OpaquePointer?) -> String {
        guard let database else { return "SQLite connection unavailable" }
        return String(cString: sqlite3_errmsg(database))
    }
}
