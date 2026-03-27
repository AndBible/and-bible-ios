// SearchIndexService.swift — FTS5-based full-text search index
//
// Builds and queries SQLite FTS5 indexes for SWORD modules.
// This replaces direct SWORD brute-force search with pre-built indexes
// for fast full-text search, matching Android's Lucene indexing behavior.

import Foundation
import SQLite3
import SwordKit
import Observation

/**
 Manages FTS5 search indexes for SWORD modules.

 Before a module can be searched, it must be indexed. The service extracts
 all verse/entry text from the SWORD module and inserts it into an FTS5
 virtual table. Subsequent searches query this table for near-instant results.

 Threading model:
 - the SQLite handle is opened with `SQLITE_OPEN_FULLMUTEX`
 - long-running indexing work happens on a background queue
 - observable UI state is pushed back to the main queue
 */
@Observable
public final class SearchIndexService: @unchecked Sendable {
    private var db: OpaquePointer?
    @ObservationIgnored
    private let dbPath: String

    /// Whether an index is currently being built.
    public var isIndexing = false

    /// Progress of current indexing operation (0.0 to 1.0).
    public var indexProgress: Double = 0

    /// Human-readable description of the module being indexed.
    public var indexingModule: String = ""

    /// Current key being processed during indexing (e.g. "Genesis 12:4").
    public var indexingKey: String = ""

    /**
     Creates the shared FTS5 index database if needed.

     The initializer opens `search_indexes.sqlite`, enables WAL mode, creates the
     required tables, and invalidates metadata for indexes built against older schemas.
     The database is stored in the app's Documents directory.
     */
    public init() {
        dbPath = Self.defaultDatabasePath()
        openDatabase()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func openDatabase() {
        guard sqlite3_open_v2(
            dbPath, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else { return }

        guard let db else { return }

        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)

        sqlite3_exec(db, """
            CREATE VIRTUAL TABLE IF NOT EXISTS verse_fts USING fts5(
                verse_key,
                plain_text,
                module_name UNINDEXED,
                tokenize='unicode61'
            )
        """, nil, nil, nil)

        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS indexed_modules (
                module_name TEXT PRIMARY KEY,
                verse_count INTEGER DEFAULT 0,
                indexed_at TEXT,
                schema_version INTEGER DEFAULT 1
            )
        """, nil, nil, nil)

        // Invalidate indexes built with an older schema version
        // (e.g., before Strong's stripping was added)
        sqlite3_exec(db, """
            DELETE FROM indexed_modules WHERE schema_version < \(Self.schemaVersion)
                OR schema_version IS NULL
        """, nil, nil, nil)
    }

    /**
     Resolves the SQLite database path for the current runtime environment.

     - Returns: Documents-backed index path for application launches.
     - Side effects:
       - creates the parent directory for the selected database path when needed
     - Failure modes:
       - silently ignores directory-creation failures and lets SQLite surface any later open error
     */
    private static func defaultDatabasePath() -> String {
        let fileManager = FileManager.default
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let databaseURL = docs.appendingPathComponent("search_indexes.sqlite")

        try? fileManager.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return databaseURL.path
    }

    // MARK: - Index Management

    /// Check whether a module has a search index.
    public func hasIndex(for moduleName: String) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT verse_count FROM indexed_modules WHERE module_name = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, moduleName, -1, sqliteTransient)
        return sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0
    }

    /// Return module names from the given list that don't have an index yet.
    public func modulesNeedingIndex(from moduleNames: [String]) -> [String] {
        moduleNames.filter { !hasIndex(for: $0) }
    }

    /**
     Build an FTS5 search index for a SWORD module.

     Iterates all entries in the module and inserts their text into the FTS5 table.
     Updates `isIndexing`, `indexProgress`, `indexingModule`, and `indexingKey`
     on the main thread for progress UI.
     */
    public func createIndex(module: SwordModule) async {
        let moduleName = module.info.name
        let moduleDesc = module.info.description

        await MainActor.run {
            isIndexing = true
            indexProgress = 0
            indexingModule = moduleDesc.isEmpty ? moduleName : moduleDesc
            indexingKey = ""
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self, let db = self.db else {
                    DispatchQueue.main.async {
                        self?.isIndexing = false
                        continuation.resume()
                    }
                    return
                }

                // Clear any existing data for this module
                self.deleteIndexData(db: db, moduleName: moduleName)

                // Begin bulk insert transaction
                sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)

                let insertSql = "INSERT INTO verse_fts (verse_key, plain_text, module_name) VALUES (?, ?, ?)"
                var insertStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK else {
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                    DispatchQueue.main.async {
                        self.isIndexing = false
                        continuation.resume()
                    }
                    return
                }

                var totalCount = 0
                let estimatedTotal = 31102.0 // standard Bible verse count

                module.iterateAllEntries { key, text, index in
                    // Skip empty entries
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return true }

                    // Strip Strong's numbers and other inline markup
                    let cleaned = Self.cleanText(trimmed)
                    guard !cleaned.isEmpty else { return true }

                    sqlite3_reset(insertStmt)
                    sqlite3_bind_text(insertStmt, 1, key, -1, self.sqliteTransient)
                    sqlite3_bind_text(insertStmt, 2, cleaned, -1, self.sqliteTransient)
                    sqlite3_bind_text(insertStmt, 3, moduleName, -1, self.sqliteTransient)
                    sqlite3_step(insertStmt)

                    totalCount = index + 1

                    // Update progress every 200 entries
                    if index % 200 == 0 {
                        let progress = min(Double(index) / estimatedTotal, 0.99)
                        DispatchQueue.main.async {
                            self.indexProgress = progress
                            self.indexingKey = key
                        }
                    }

                    return true
                }

                sqlite3_finalize(insertStmt)
                sqlite3_exec(db, "COMMIT", nil, nil, nil)

                // Record completion
                var recordStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, """
                    INSERT OR REPLACE INTO indexed_modules (module_name, verse_count, indexed_at, schema_version)
                    VALUES (?, ?, datetime('now'), ?)
                """, -1, &recordStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(recordStmt, 1, moduleName, -1, self.sqliteTransient)
                    sqlite3_bind_int(recordStmt, 2, Int32(totalCount))
                    sqlite3_bind_int(recordStmt, 3, Int32(Self.schemaVersion))
                    sqlite3_step(recordStmt)
                }
                sqlite3_finalize(recordStmt)

                DispatchQueue.main.async {
                    self.indexProgress = 1.0
                    self.isIndexing = false
                    continuation.resume()
                }
            }
        }
    }

    /// Delete the search index for a module.
    public func deleteIndex(for moduleName: String) {
        guard let db else { return }
        deleteIndexData(db: db, moduleName: moduleName)
    }

    private func deleteIndexData(db: OpaquePointer, moduleName: String) {
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, "DELETE FROM verse_fts WHERE module_name = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, moduleName, -1, sqliteTransient)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        stmt = nil

        if sqlite3_prepare_v2(db, "DELETE FROM indexed_modules WHERE module_name = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, moduleName, -1, sqliteTransient)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Search

    /// A single search result from the FTS5 index.
    public struct IndexSearchResult: Sendable {
        public let key: String
        public let snippet: String
        public let moduleName: String
    }

    /// Search the FTS5 index for a single module.
    public func search(
        query: String,
        moduleName: String,
        wordMode: SearchWordMode,
        scopeBookName: String? = nil,
        scopeTestament: String? = nil
    ) -> [IndexSearchResult] {
        guard let db, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let ftsQuery = buildFTSQuery(query: query, wordMode: wordMode)
        guard !ftsQuery.isEmpty else { return [] }

        let sql = """
            SELECT verse_key, snippet(verse_fts, 1, '', '', '...', 64), module_name
            FROM verse_fts
            WHERE verse_fts MATCH ? AND module_name = ?
            ORDER BY rank
            LIMIT 5000
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, ftsQuery, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, moduleName, -1, sqliteTransient)

        var results: [IndexSearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyPtr = sqlite3_column_text(stmt, 0),
                  let snippetPtr = sqlite3_column_text(stmt, 1),
                  let modPtr = sqlite3_column_text(stmt, 2) else { continue }

            let key = String(cString: keyPtr)
            let snippet = String(cString: snippetPtr)
            let modName = String(cString: modPtr)

            // Apply scope filter
            if let bookName = scopeBookName, !key.hasPrefix(bookName + " ") { continue }
            if let testament = scopeTestament {
                if testament == "OT" && Self.isNewTestament(key) { continue }
                if testament == "NT" && !Self.isNewTestament(key) { continue }
            }

            results.append(IndexSearchResult(key: key, snippet: snippet, moduleName: modName))
        }

        return results
    }

    /// Search across multiple modules and return results grouped by module.
    public func searchMultiple(
        query: String,
        moduleNames: [String],
        wordMode: SearchWordMode,
        scopeBookName: String? = nil,
        scopeTestament: String? = nil
    ) -> [String: [IndexSearchResult]] {
        var results: [String: [IndexSearchResult]] = [:]
        for name in moduleNames.sorted() {
            results[name] = search(
                query: query, moduleName: name, wordMode: wordMode,
                scopeBookName: scopeBookName, scopeTestament: scopeTestament
            )
        }
        return results
    }

    // MARK: - FTS Query Building

    private func buildFTSQuery(query: String, wordMode: SearchWordMode) -> String {
        let terms = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "" }

        // Escape FTS5 special characters in each term
        let escaped = terms.map { term -> String in
            // Double-quote terms that contain special chars
            let special: Set<Character> = ["*", "\"", "(", ")", ":", "^", "{", "}"]
            if term.contains(where: { special.contains($0) }) {
                return "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return term
        }

        switch wordMode {
        case .allWords:
            return escaped.joined(separator: " ")
        case .anyWord:
            return escaped.joined(separator: " OR ")
        case .phrase:
            return "\"" + terms.joined(separator: " ") + "\""
        }
    }

    // MARK: - Scope Filtering

    private static let ntBookPrefixes: [String] = [
        "Matthew", "Mark", "Luke", "John", "Acts", "Romans",
        "1 Corinthians", "2 Corinthians", "Galatians", "Ephesians",
        "Philippians", "Colossians", "1 Thessalonians", "2 Thessalonians",
        "1 Timothy", "2 Timothy", "Titus", "Philemon", "Hebrews",
        "James", "1 Peter", "2 Peter", "1 John", "2 John", "3 John",
        "Jude", "Revelation of John", "Revelation",
        "I Corinthians", "II Corinthians", "I Thessalonians", "II Thessalonians",
        "I Timothy", "II Timothy", "I Peter", "II Peter",
        "I John", "II John", "III John"
    ]

    private static func isNewTestament(_ key: String) -> Bool {
        for prefix in ntBookPrefixes {
            if key.hasPrefix(prefix + " ") { return true }
        }
        return false
    }

    // MARK: - Text Cleaning

    /**
     Strip Strong's number tags like `<H01732>`, `<G2424>` and other inline
     markup from SWORD strip text. Some modules (e.g., KJV with Strongs)
     embed these in the text data and `stripText()` doesn't remove them.
     */
    public static func cleanText(_ text: String) -> String {
        // Remove <Hxxxxx>, <Gxxxxx>, <hxxxxx>, <gxxxxx> patterns (Strong's Hebrew/Greek)
        // Also remove <Wxxxxx> (morphology) patterns
        guard text.contains("<") else { return text }
        var result = text
        // Strong's numbers: <H01234>, <G5678>, <h01234>, <g5678>
        if let regex = try? NSRegularExpression(pattern: "<[HGhgW]\\d+>", options: []) {
            result = regex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: ""
            )
        }
        // Collapse multiple spaces left behind
        if let spaceRegex = try? NSRegularExpression(pattern: "  +", options: []) {
            result = spaceRegex.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " "
            )
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - SQLite Helpers

    /// Current schema version. Increment to force re-indexing when text processing changes.
    private static let schemaVersion = 2

    /// SQLITE_TRANSIENT equivalent — tells SQLite to make a copy of the bound string.
    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }
}
