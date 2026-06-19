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
    /// Current search-index schema version. Increment to force re-indexing when text processing changes.
    public static let currentSchemaVersion = 4

    private var db: OpaquePointer?
    @ObservationIgnored
    private let dbPath: String
    /**
     Serial queue for SQLite mutations that rewrite module index contents.

     `SQLITE_OPEN_FULLMUTEX` protects individual SQLite calls, not logical create/delete
     operations. Keeping index creation and deletion on one queue prevents Delete Index from
     interleaving with a background build and leaving partial FTS rows with completed metadata.
     */
    @ObservationIgnored
    private let indexMutationQueue = DispatchQueue(
        label: "org.andbible.ios.search-index.mutations",
        qos: .userInitiated
    )
    /**
     Queue-specific marker used to detect re-entrant synchronous legacy delete calls.

     `DispatchQueue.sync` deadlocks when called from the same serial queue. The deprecated
     synchronous delete overload checks this marker so internal queued work can delete directly
     while outside callers still block until the serial mutation queue reaches their request.
     */
    @ObservationIgnored
    private let indexMutationQueueSpecificKey = DispatchSpecificKey<Bool>()

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
        configureIndexMutationQueue()
        openDatabase()
    }

    /**
     Creates the search index service against a caller-supplied SQLite path.

     Tests use this initializer to isolate index state from the app's shared Documents database.
     Runtime callers should use `init()` so the service resolves the standard app database path.

     - Parameter databasePath: Absolute path for the FTS5 SQLite database.
     - Side effects:
       - opens or creates the SQLite database at `databasePath`
       - creates required FTS and metadata tables when absent
     - Failure modes:
       - SQLite open or schema failures leave the service with no active database handle
     */
    init(databasePath: String) {
        dbPath = databasePath
        configureIndexMutationQueue()
        openDatabase()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /**
     Marks the serial index mutation queue so synchronous compatibility calls can detect re-entry.

     - Side effects: associates an instance-local marker with `indexMutationQueue`.
     - Failure modes: none; Dispatch queue-specific values are retained by the queue for the
       service lifetime.
     */
    private func configureIndexMutationQueue() {
        indexMutationQueue.setSpecific(key: indexMutationQueueSpecificKey, value: true)
    }

    private func openDatabase() {
        guard sqlite3_open_v2(
            dbPath, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else { return }

        guard let db else { return }

        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)

        if Self.searchSchemaNeedsRebuild(db: db) {
            sqlite3_exec(db, "DROP TABLE IF EXISTS verse_strongs", nil, nil, nil)
            sqlite3_exec(db, "DROP TABLE IF EXISTS verse_fts", nil, nil, nil)
            sqlite3_exec(db, "DROP TABLE IF EXISTS indexed_modules", nil, nil, nil)
        }

        sqlite3_exec(db, """
            CREATE VIRTUAL TABLE IF NOT EXISTS verse_fts USING fts5(
                verse_key,
                plain_text,
                module_name UNINDEXED,
                entry_order UNINDEXED,
                tokenize='unicode61'
            )
        """, nil, nil, nil)

        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS verse_strongs (
                module_name TEXT NOT NULL,
                token TEXT NOT NULL,
                verse_key TEXT NOT NULL,
                entry_order INTEGER NOT NULL,
                PRIMARY KEY (module_name, token, verse_key)
            )
        """, nil, nil, nil)

        sqlite3_exec(db, """
            CREATE INDEX IF NOT EXISTS idx_verse_strongs_module_token
            ON verse_strongs (module_name, token, entry_order)
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
     Detects whether the persisted FTS schema predates canonical entry ordering.

     The app stores search indexes in a durable SQLite database. `CREATE VIRTUAL TABLE IF NOT
     EXISTS` cannot add a new FTS5 column to an existing table, so schema upgrades that change FTS
     columns must drop the generated index tables and let callers rebuild modules on demand.
     Android displays scripture search hits in canonical verse order; retaining a rank-only legacy
     table would preserve the user-visible ordering bug after app upgrade.

     - Parameter db: Open SQLite handle for the search-index database.
     - Returns: `true` when `verse_fts` exists without the required `entry_order` column.
     - Side effects: Reads SQLite table metadata only.
     - Failure modes: Returns `false` when SQLite cannot prepare metadata, allowing the normal
       create path to handle a missing or corrupt table.
     */
    private static func searchSchemaNeedsRebuild(db: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, "PRAGMA table_info(verse_fts)", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }

        var sawColumn = false
        var hasEntryOrder = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            sawColumn = true
            guard let namePtr = sqlite3_column_text(stmt, 1) else { continue }
            if String(cString: namePtr) == "entry_order" {
                hasEntryOrder = true
            }
        }

        return sawColumn && !hasEntryOrder
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

    /**
     Checks whether a module has the lexical Strong's facet required for indexed Strong's search.

     Text FTS and Strong's lookup are separate Android/JSword index facets: a module can have
     `verse_fts` rows that satisfy ordinary text search while still lacking `verse_strongs` rows
     needed by "find all occurrences" for Strong's numbers. This method deliberately validates the
     real token table, not only `indexed_modules`, so stale or partial text-only indexes cannot be
     mistaken for Strong's-capable indexes.

     - Parameter moduleName: SWORD module initials to inspect.
     - Returns: `true` only when module metadata exists and at least one lexical Strong's token row
       is present for the module.
     - Side effects: Reads the SQLite search-index database.
     - Failure modes: Returns `false` when the database handle is unavailable, metadata is missing,
       the Strong's token table is absent/empty, or SQLite statement preparation fails.
     */
    public func hasStrongsIndex(for moduleName: String) -> Bool {
        guard hasIndex(for: moduleName), let db else { return false }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        let sql = "SELECT 1 FROM verse_strongs WHERE module_name = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        sqlite3_bind_text(stmt, 1, moduleName, -1, sqliteTransient)
        return sqlite3_step(stmt) == SQLITE_ROW
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
            indexMutationQueue.async { [weak self] in
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

                let insertSql = """
                    INSERT INTO verse_fts (verse_key, plain_text, module_name, entry_order)
                    VALUES (?, ?, ?, ?)
                """
                var insertStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, insertSql, -1, &insertStmt, nil) == SQLITE_OK else {
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                    DispatchQueue.main.async {
                        self.isIndexing = false
                        continuation.resume()
                    }
                    return
                }
                let insertStrongsSql = """
                    INSERT OR IGNORE INTO verse_strongs (module_name, token, verse_key, entry_order)
                    VALUES (?, ?, ?, ?)
                """
                var insertStrongsStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, insertStrongsSql, -1, &insertStrongsStmt, nil) == SQLITE_OK else {
                    sqlite3_finalize(insertStmt)
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                    DispatchQueue.main.async {
                        self.isIndexing = false
                        continuation.resume()
                    }
                    return
                }

                var totalCount = 0
                let estimatedTotal = 31102.0 // standard Bible verse count

                module.iterateAllEntriesWithRaw { key, text, rawEntry, index in
                    // Skip empty entries
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return true }

                    // Strip Strong's numbers and other inline markup
                    let cleaned = Self.cleanText(trimmed)
                    guard !cleaned.isEmpty else { return true }
                    let rawTokens = StrongsTokenNormalizer.canonicalTokens(
                        rawEntry: rawEntry,
                        renderedTextProvider: { "" },
                        isNewTestamentBook: false
                    )
                    let taggedTextTokens = StrongsTokenNormalizer.canonicalTokens(taggedText: trimmed)
                    let strongTokens = Self.orderedUnique(rawTokens + taggedTextTokens)

                    sqlite3_reset(insertStmt)
                    sqlite3_bind_text(insertStmt, 1, key, -1, self.sqliteTransient)
                    sqlite3_bind_text(insertStmt, 2, cleaned, -1, self.sqliteTransient)
                    sqlite3_bind_text(insertStmt, 3, moduleName, -1, self.sqliteTransient)
                    sqlite3_bind_int(insertStmt, 4, Int32(index))
                    sqlite3_step(insertStmt)

                    for token in strongTokens {
                        sqlite3_reset(insertStrongsStmt)
                        sqlite3_clear_bindings(insertStrongsStmt)
                        sqlite3_bind_text(insertStrongsStmt, 1, moduleName, -1, self.sqliteTransient)
                        sqlite3_bind_text(insertStrongsStmt, 2, token, -1, self.sqliteTransient)
                        sqlite3_bind_text(insertStrongsStmt, 3, key, -1, self.sqliteTransient)
                        sqlite3_bind_int(insertStrongsStmt, 4, Int32(index))
                        sqlite3_step(insertStrongsStmt)
                    }

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
                sqlite3_finalize(insertStrongsStmt)
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

    /**
     Deletes the search index for a module after any active index mutation completes.

     - Parameter moduleName: Module initials whose FTS rows and metadata should be removed.
     - Side effects:
       - mutates the FTS index database on the service's serial mutation queue
     - Failure modes:
       - missing indexes, closed database handles, and SQLite statement failures are treated as
         no-ops so callers can use this as Android-style best-effort cleanup
     */
    public func deleteIndex(for moduleName: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            indexMutationQueue.async { [weak self] in
                if let self, let db = self.db {
                    self.deleteIndexData(db: db, moduleName: moduleName)
                }
                continuation.resume()
            }
        }
    }

    /**
     Deletes the search index for a module for callers that still use the former synchronous API.

     This overload preserves source compatibility while callers migrate to the async deletion path.
     It blocks the calling thread until earlier queued index mutations finish, then removes the
     module's FTS rows and metadata on the same serial mutation queue used by async create/delete.

     - Parameter moduleName: Module initials whose FTS rows and metadata should be removed.
     - Side effects:
       - blocks the caller until the serial mutation queue reaches this deletion request
       - deletes directly when already executing on the serial mutation queue to avoid deadlock
       - mutates the FTS index database on the service's serial mutation queue
     - Failure modes:
       - missing indexes, closed database handles, and SQLite statement failures are treated as
         no-ops so legacy callers keep the same best-effort behavior as the async API
     - Important: New code should call `await deleteIndex(for:)` so UI tasks can suspend instead
       of blocking a thread while queued index mutations complete.
     */
    @available(*, deprecated, message: "Use await deleteIndex(for:) so deletion can suspend instead of blocking.")
    public func deleteIndex(for moduleName: String) {
        if DispatchQueue.getSpecific(key: indexMutationQueueSpecificKey) == true {
            guard let db else { return }
            deleteIndexData(db: db, moduleName: moduleName)
            return
        }

        indexMutationQueue.sync {
            guard let db else { return }
            deleteIndexData(db: db, moduleName: moduleName)
        }
    }

    #if DEBUG
    /**
     Runs a test-supplied SQLite mutation on the production index mutation queue.

     This hook lets regression tests install deterministic barriers and fixture writes without
     building a full SWORD module index. The closure receives the open SQLite handle and executes
     in the same serialized position as `createIndex(module:)` and `deleteIndex(for:)`.

     - Parameter mutation: Fixture operation to run against the open search-index database handle.
     - Side effects:
       - enqueues work on `indexMutationQueue`
       - may mutate the search-index SQLite database when the closure performs writes
     - Failure modes:
       - resumes without invoking `mutation` when the database handle is unavailable
       - propagates any error thrown by `mutation` to the awaiting test
     - Important: DEBUG-only test support. Runtime code should use the public index APIs instead.
     */
    func performIndexMutationForTesting(_ mutation: @escaping (OpaquePointer) throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            indexMutationQueue.async { [weak self] in
                guard let self, let db = self.db else {
                    continuation.resume()
                    return
                }

                do {
                    try mutation(db)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    #endif

    private func deleteIndexData(db: OpaquePointer, moduleName: String) {
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, "DELETE FROM verse_strongs WHERE module_name = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, moduleName, -1, sqliteTransient)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        stmt = nil

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
            ORDER BY CAST(entry_order AS INTEGER)
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

    /**
     Searches the Strong's-token index for verses containing all requested canonical tokens.

     Android stores Strong's numbers in JSword's Lucene `strong` field and queries that field for
     "find all occurrences". iOS mirrors that architecture by keeping lexical Strong's tokens in a
     separate SQLite table linked to the normal verse-text index. This keeps plain text search free
     of Strong's tags while avoiding per-search SWORD scans for common numbers.

     - Parameters:
       - canonicalTokens: JSword-style canonical tokens such as `H0430` or `G0123a`; every token
         must be present in a returned verse.
       - moduleName: SWORD module initials whose completed index should be searched.
       - scopeBookName: Optional human-readable book-name prefix for current-book searches.
       - scopeTestament: Optional `OT` or `NT` testament filter.
     - Returns: Matching verse keys with cleaned preview snippets in canonical module order.
     - Side effects: Reads the SQLite search-index database.
     - Failure modes:
       - returns an empty array when the database is unavailable, tokens are empty, or SQLite
         statement preparation fails
     */
    public func searchStrongs(
        canonicalTokens: [String],
        moduleName: String,
        scopeBookName: String? = nil,
        scopeTestament: String? = nil
    ) -> [IndexSearchResult] {
        guard let db else { return [] }
        let tokens = Self.orderedUnique(canonicalTokens).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: tokens.count).joined(separator: ",")
        let sql = """
            SELECT s.verse_key, f.plain_text, s.module_name, MIN(s.entry_order) AS sort_order
            FROM verse_strongs s
            JOIN verse_fts f
                ON f.verse_key = s.verse_key
                AND f.module_name = s.module_name
            WHERE s.module_name = ?
                AND s.token IN (\(placeholders))
            GROUP BY s.module_name, s.verse_key
            HAVING COUNT(DISTINCT s.token) = ?
            ORDER BY sort_order
            LIMIT 5000
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

        sqlite3_bind_text(stmt, 1, moduleName, -1, sqliteTransient)
        for (offset, token) in tokens.enumerated() {
            sqlite3_bind_text(stmt, Int32(offset + 2), token, -1, sqliteTransient)
        }
        sqlite3_bind_int(stmt, Int32(tokens.count + 2), Int32(tokens.count))

        var results: [IndexSearchResult] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let keyPtr = sqlite3_column_text(stmt, 0),
                  let snippetPtr = sqlite3_column_text(stmt, 1),
                  let modPtr = sqlite3_column_text(stmt, 2) else { continue }

            let key = String(cString: keyPtr)
            let snippet = String(cString: snippetPtr)
            let modName = String(cString: modPtr)

            if let bookName = scopeBookName, !key.hasPrefix(bookName + " ") { continue }
            if let testament = scopeTestament {
                if testament == "OT" && Self.isNewTestament(key) { continue }
                if testament == "NT" && !Self.isNewTestament(key) { continue }
            }

            results.append(IndexSearchResult(
                key: key,
                snippet: String(snippet.prefix(200)),
                moduleName: modName
            ))
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

    private static let schemaVersion = currentSchemaVersion

    /// SQLITE_TRANSIENT equivalent — tells SQLite to make a copy of the bound string.
    private var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
