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
        let sql = """
        INSERT INTO verse_fts (verse_key, plain_text, module_name, entry_order)
        VALUES ('Genesis 1:1', 'created', '\(escapedModuleName)', 0);
        INSERT INTO indexed_modules (module_name, verse_count, indexed_at, schema_version)
        VALUES ('\(escapedModuleName)', 1, datetime('now'), \(SearchIndexService.currentSchemaVersion));
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
