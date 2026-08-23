import SQLite3
import XCTest
@testable import BibleCore

/// SQLite destructor marker used by temporary search-index fixtures in this file.
private let searchIndexFixtureSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 App-host-free package coverage for `SearchIndexService` mutation ordering.

 The service is owned by BibleCore and coordinates SQLite index mutations outside of the app host.
 This suite keeps queued deletion behavior in the package lane so concurrency regressions are caught
 without simulator app launch overhead.
 */
final class SearchIndexServiceMutationTests: XCTestCase {
    /**
     Verifies database-open failures remain observable and queries fail explicitly.

     A path below a missing parent directory makes SQLite fail deterministically. Search must retain
     that initialization failure for the retry UI and throw instead of presenting an empty result.
     */
    func testDatabaseOpenFailureIsRetainedAndSearchThrows() throws {
        let missingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-search-parent-\(UUID().uuidString)", isDirectory: true)
        let service = SearchIndexService(
            databasePath: missingParent.appendingPathComponent("search.sqlite").path
        )

        XCTAssertNotNil(service.lastFailureDescription)
        XCTAssertThrowsError(
            try service.search(query: "faith", moduleName: "KJV", wordMode: .allWords)
        ) { error in
            XCTAssertEqual(
                error as? SearchIndexError,
                .databaseUnavailable(operation: "checking KJV index")
            )
        }
    }

    /**
     Verifies Strong's readiness records completed scans rather than requiring at least one token.

     A text-only partial fixture must request rebuilding for a Strong's query. Once the same
     transactional metadata marks the Strong's scan complete, a module with zero lexical tokens is
     ready and must not enter an endless rebuild loop.
     */
    func testStrongsRequirementDistinguishesPartialFromCompletedEmptyFacet() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-empty-strongs-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = SearchIndexService(databasePath: databaseURL.path)
        try await service.performIndexMutationForTesting { db in
            try self.seedSearchIndexFixture(moduleName: "PLAIN", db: db)
        }

        XCTAssertEqual(
            service.modulesNeedingIndex(from: ["PLAIN"], requirement: .text),
            []
        )
        XCTAssertEqual(
            service.modulesNeedingIndex(from: ["PLAIN"], requirement: .strongs),
            ["PLAIN"]
        )

        try await service.performIndexMutationForTesting { db in
            guard sqlite3_exec(
                db,
                "UPDATE indexed_modules SET strongs_complete = 1 WHERE module_name = 'PLAIN'",
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw SearchIndexFixtureError.writeFailed
            }
        }

        XCTAssertTrue(service.hasStrongsIndex(for: "PLAIN"))
        XCTAssertEqual(
            service.modulesNeedingIndex(from: ["PLAIN"], requirement: .strongs),
            []
        )
    }

    /**
     Verifies search-index deletion waits for any queued SQLite mutation to finish.

     `SearchIndexService` serializes index writes through its mutation queue. Deleting an index while
     a fixture write is paused must run after the write releases, otherwise stale rows can survive and
     Search will treat a deleted module as still indexed.
     */
    func testSearchIndexDeleteIndexAwaitsQueuedMutation() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = SearchIndexService(databasePath: databaseURL.path)
        let queuedMutationStarted = expectation(description: "queued fixture mutation started")
        let releaseQueuedMutation = DispatchSemaphore(value: 0)

        let fixtureTask = Task {
            try await service.performIndexMutationForTesting { db in
                queuedMutationStarted.fulfill()
                releaseQueuedMutation.wait()
                try self.seedSearchIndexFixture(moduleName: "KJV", db: db)
            }
        }

        await fulfillment(of: [queuedMutationStarted], timeout: 1.0)
        let deleteTask = Task {
            await service.deleteIndex(for: "KJV")
        }

        DispatchQueue.global(qos: .userInitiated).async {
            releaseQueuedMutation.signal()
        }
        try await fixtureTask.value
        await deleteTask.value

        let deletedCounts = try searchIndexFixtureCounts(moduleName: "KJV", databaseURL: databaseURL)
        XCTAssertEqual(deletedCounts.rows, 0)
        XCTAssertEqual(deletedCounts.metadata, 0)
    }

    /**
     Verifies the token-boundary and source-generation schema replaces legacy generated indexes.

     - Setup: Writes a version-seven-style FTS/metadata pair without opaque-token, display-mode, or
       durable source-generation columns, then opens the database through production initialization.
     - Expected result: Version nine tables contain every required column and legacy readiness is gone.
     - Failure meaning: An upgraded app can continue advertising an incompatible generated index.
     - Side effects: Creates and removes one isolated SQLite database.
     */
    func testLegacyGeneratedSchemaRebuildsForOpaqueTokensAndSourceIdentity() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-schema-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        var legacyDatabase: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &legacyDatabase), SQLITE_OK)
        guard let legacyDatabase else { throw SearchIndexFixtureError.openFailed }
        let legacySQL = """
            CREATE VIRTUAL TABLE verse_fts USING fts5(
                search_text, verse_key UNINDEXED, plain_text UNINDEXED, module_name UNINDEXED,
                entry_order UNINDEXED, osis_book UNINDEXED, display_book UNINDEXED,
                chapter UNINDEXED, verse UNINDEXED, book_order UNINDEXED, canon_scope UNINDEXED,
                tokenize='unicode61'
            );
            CREATE TABLE indexed_modules (
                module_name TEXT PRIMARY KEY, verse_count INTEGER NOT NULL, indexed_at TEXT NOT NULL,
                schema_version INTEGER NOT NULL, language_code TEXT NOT NULL,
                analyzer_id TEXT NOT NULL, strongs_complete INTEGER NOT NULL DEFAULT 0
            );
            INSERT INTO indexed_modules VALUES (
                'KJV', 1, datetime('now'), 7, 'en', 'legacy-analyzer', 1
            );
        """
        guard sqlite3_exec(legacyDatabase, legacySQL, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(legacyDatabase)
            throw SearchIndexFixtureError.writeFailed
        }
        sqlite3_close(legacyDatabase)

        let service = SearchIndexService(databasePath: databaseURL.path)
        XCTAssertEqual(SearchIndexService.currentSchemaVersion, 9)
        XCTAssertFalse(service.hasIndex(for: "KJV"))

        let ftsColumns = try tableColumns(named: "verse_fts", databaseURL: databaseURL)
        XCTAssertTrue(ftsColumns.contains("display_book_mode"))
        let metadataColumns = try tableColumns(named: "indexed_modules", databaseURL: databaseURL)
        XCTAssertTrue(metadataColumns.isSuperset(of: [
            "source_version", "source_fingerprint", "store_generation",
        ]))
        XCTAssertEqual(
            try tableColumns(named: "search_index_state", databaseURL: databaseURL),
            Set(["id", "store_generation"])
        )
    }

    /**
     Verifies version-eight rows are invalidated when structured Search text projection changes.

     - Setup: Creates the current generated schema, seeds one ready module, then marks only its
       metadata as version eight to model an index built from SWORD stripped/rendered text.
     - Expected result: Reopening production initialization removes stale readiness while leaving the
       generated row inaccessible until normal transactional replacement rebuilds the module.
     - Failure meaning: Upgraded installations can keep returning annotation-bearing Search rows.
     - Side effects: Creates, mutates, and removes one isolated SQLite index database.
     */
    func testVersionEightTextProjectionMetadataRequiresReindex() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-v8-projection-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let currentService = SearchIndexService(databasePath: databaseURL.path)
        try seedSearchIndexFixture(moduleName: "FINRK", databaseURL: databaseURL)
        XCTAssertTrue(currentService.hasIndex(for: "FINRK"))

        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else {
            throw SearchIndexFixtureError.openFailed
        }
        guard sqlite3_exec(
            db,
            "UPDATE indexed_modules SET schema_version = 8 WHERE module_name = 'FINRK'",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            sqlite3_close(db)
            throw SearchIndexFixtureError.writeFailed
        }
        sqlite3_close(db)

        let reopenedService = SearchIndexService(databasePath: databaseURL.path)
        XCTAssertFalse(reopenedService.hasIndex(for: "FINRK"))
        let counts = try searchIndexFixtureCounts(moduleName: "FINRK", databaseURL: databaseURL)
        XCTAssertEqual(counts.rows, 1)
        XCTAssertEqual(counts.metadata, 0)
    }

    /**
     Reads one generated table's column names without mutating the database.

     - Parameters:
       - tableName: SQLite table whose `PRAGMA table_info` rows should be inspected.
       - databaseURL: Isolated generated-index database URL.
     - Returns: Exact persisted column-name set.
     - Side effects: Opens and closes one read-only SQLite connection.
     - Failure modes: Throws fixture open/read errors when SQLite cannot inspect the table.
     */
    private func tableColumns(named tableName: String, databaseURL: URL) throws -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            throw SearchIndexFixtureError.openFailed
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(tableName))", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SearchIndexFixtureError.readFailed
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 1) else {
                throw SearchIndexFixtureError.readFailed
            }
            columns.insert(String(cString: value))
        }
        return columns
    }

    private func seedSearchIndexFixture(moduleName: String, databaseURL: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw SearchIndexFixtureError.openFailed
        }
        defer { sqlite3_close(db) }

        try seedSearchIndexFixture(moduleName: moduleName, db: db)
    }

    private func seedSearchIndexFixture(moduleName: String, db: OpaquePointer?) throws {
        let escapedModuleName = moduleName.replacingOccurrences(of: "'", with: "''")
        let escapedAnalyzerID = SearchTextAnalyzer.profile(for: "en").identifier
            .replacingOccurrences(of: "'", with: "''")
        let encodedCreated = SearchIndexTokenCodec.encode("created")
        let sql = """
        INSERT INTO verse_fts (
            search_text, verse_key, plain_text, module_name, entry_order, osis_book,
            display_book, display_book_mode, chapter, verse, book_order, canon_scope
        ) VALUES (
            '\(encodedCreated)', 'Genesis 1:1', 'created', '\(escapedModuleName)', 0, 'Gen',
            'Genesis', 'source', 1, 1, 2, 'ot'
        );
        INSERT INTO indexed_modules (
            module_name, verse_count, indexed_at, schema_version, language_code, analyzer_id,
            strongs_complete, source_version, source_fingerprint, store_generation
        ) VALUES (
            '\(escapedModuleName)', 1, datetime('now'), \(SearchIndexService.currentSchemaVersion),
            'en', '\(escapedAnalyzerID)', 0, '',
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            (SELECT store_generation FROM search_index_state WHERE id = 1)
        );
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SearchIndexFixtureError.writeFailed
        }
    }

    private func searchIndexFixtureCounts(moduleName: String, databaseURL: URL) throws -> (rows: Int, metadata: Int) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw SearchIndexFixtureError.openFailed
        }
        defer { sqlite3_close(db) }

        return (
            rows: try searchIndexFixtureCount(
                db: db,
                sql: "SELECT COUNT(*) FROM verse_fts WHERE module_name = ?",
                moduleName: moduleName
            ),
            metadata: try searchIndexFixtureCount(
                db: db,
                sql: "SELECT COUNT(*) FROM indexed_modules WHERE module_name = ?",
                moduleName: moduleName
            )
        )
    }

    private func searchIndexFixtureCount(db: OpaquePointer?, sql: String, moduleName: String) throws -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SearchIndexFixtureError.readFailed
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, moduleName, -1, searchIndexFixtureSQLiteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw SearchIndexFixtureError.readFailed
        }
        return Int(sqlite3_column_int(stmt, 0))
    }

}

private enum SearchIndexFixtureError: Error {
    case openFailed
    case readFailed
    case writeFailed
}
