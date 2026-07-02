import SQLite3
import XCTest
@testable import BibleCore
@testable import SwordKit

/// SQLite destructor marker used by temporary search-index query fixtures in this file.
private let searchIndexQueryFixtureSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 App-host-free package coverage for indexed Search query behavior.

 The removed UI tests previously launched the full app to validate Search mode and scope changes
 against seeded indexes. These tests keep those Android-parity data contracts in the BibleCore
 package lane by exercising `SearchIndexService` directly against deterministic FTS fixtures.
 */
final class SearchIndexServiceQueryTests: XCTestCase {
    /**
     Verifies indexed Search word modes match Android-visible search semantics.

     The UI-level regression switched `earth void` from all-words to phrase and any-word. That
     behavior is owned by the FTS query builder, so this package test proves:
     all-words requires both terms, phrase requires adjacency, and any-word restores rows that
     contain either term.
     */
    func testIndexedSearchWordModesMatchAndroidSearchContracts() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-query-modes-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = SearchIndexService(databasePath: databaseURL.path)
        try await seedSearchIndex(service: service, rows: [
            SearchIndexFixtureRow(key: "Genesis 1:1", text: "earth alone", moduleName: "KJV", order: 0),
            SearchIndexFixtureRow(
                key: "Genesis 1:2",
                text: "earth was without form and void",
                moduleName: "KJV",
                order: 1
            ),
            SearchIndexFixtureRow(key: "Genesis 1:3", text: "void alone", moduleName: "KJV", order: 2),
        ])

        XCTAssertEqual(
            service.search(query: "earth void", moduleName: "KJV", wordMode: .allWords).map(\.key),
            ["Genesis 1:2"]
        )
        XCTAssertEqual(
            service.search(query: "earth void", moduleName: "KJV", wordMode: .phrase).map(\.key),
            []
        )
        XCTAssertEqual(
            service.search(query: "earth void", moduleName: "KJV", wordMode: .anyWord).map(\.key),
            ["Genesis 1:1", "Genesis 1:2", "Genesis 1:3"]
        )
    }

    /**
     Verifies indexed Search scope filters preserve Android's OT/NT/current-book behavior.

     The previous UI regression proved Search reran after tapping the visible scope buttons. This
     package equivalent locks the actual scope filtering that determines the result set: OT excludes
     New Testament keys, NT includes only New Testament keys, and current-book scope matches the
     reader-provided book name prefix.
     */
    func testIndexedSearchScopeFiltersMatchAndroidSearchContracts() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-query-scopes-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = SearchIndexService(databasePath: databaseURL.path)
        try await seedSearchIndex(service: service, rows: [
            SearchIndexFixtureRow(key: "Genesis 1:3", text: "light", moduleName: "KJV", order: 0),
            SearchIndexFixtureRow(key: "Matthew 1:1", text: "light", moduleName: "KJV", order: 1),
            SearchIndexFixtureRow(key: "John 1:4", text: "light", moduleName: "KJV", order: 2),
            SearchIndexFixtureRow(key: "Revelation of John 22:5", text: "light", moduleName: "KJV", order: 3),
        ])

        XCTAssertEqual(
            service.search(query: "light", moduleName: "KJV", wordMode: .allWords).map(\.key),
            ["Genesis 1:3", "Matthew 1:1", "John 1:4", "Revelation of John 22:5"]
        )
        XCTAssertEqual(
            service.search(
                query: "light",
                moduleName: "KJV",
                wordMode: .allWords,
                scopeTestament: "OT"
            ).map(\.key),
            ["Genesis 1:3"]
        )
        XCTAssertEqual(
            service.search(
                query: "light",
                moduleName: "KJV",
                wordMode: .allWords,
                scopeTestament: "NT"
            ).map(\.key),
            ["Matthew 1:1", "John 1:4", "Revelation of John 22:5"]
        )
        XCTAssertEqual(
            service.search(
                query: "light",
                moduleName: "KJV",
                wordMode: .allWords,
                scopeBookName: "John"
            ).map(\.key),
            ["John 1:4"]
        )
    }

    /**
     Verifies multi-translation Search returns per-module buckets used for grouped totals.

     Android displays grouped totals after selecting additional translations. BibleUI package tests
     own picker ordering, commit, and visible summary formatting; this Core package test owns the
     indexed backing service buckets that the UI summarizes.
     */
    func testIndexedSearchMultipleReturnsPerModuleBucketsForGroupedTotals() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-query-multi-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = SearchIndexService(databasePath: databaseURL.path)
        try await seedSearchIndex(service: service, rows: [
            SearchIndexFixtureRow(key: "Genesis 1:2", text: "earth", moduleName: "KJV", order: 0),
            SearchIndexFixtureRow(key: "John 3:16", text: "earth", moduleName: "AATESTWEB", order: 1),
            SearchIndexFixtureRow(key: "Romans 8:1", text: "earth", moduleName: "AATESTWEB", order: 2),
        ])

        let grouped = service.searchMultiple(
            query: "earth",
            moduleNames: ["AATESTWEB", "KJV"],
            wordMode: .allWords
        )

        XCTAssertEqual(grouped["KJV"]?.map(\.key), ["Genesis 1:2"])
        XCTAssertEqual(grouped["AATESTWEB"]?.map(\.key), ["John 3:16", "Romans 8:1"])
        XCTAssertEqual(grouped.values.reduce(0) { $0 + $1.count }, 3)
    }

    /**
     Verifies indexed Strong's search reads canonical token rows in Android-style module order.

     Android's JSword search uses the Lucene `strong` field for "find all occurrences" instead of
     walking every verse at interaction time. This test keeps the iOS `verse_strongs` contract in the
     BibleCore package lane with a deterministic fixture, so package CI does not need to rebuild the
     full KJV fixture index to prove the same behavior.

     - Setup: Seeds cleaned verse-text rows plus explicit Strong's token rows for KJV.
     - Expected result: H0430 hits return only the tokenized verses, ordered by canonical entry order,
       with cleaned snippets and Strong's readiness set for the module.
     - Failure meaning: The indexed Strong's facet no longer behaves like Android's JSword field, or
       the fixture metadata no longer exercises the readiness gate Search uses before querying.
     - Side effects: Creates and removes one temporary SQLite database.
     */
    func testIndexedStrongsSearchFindsCanonicalTokensInModuleOrder() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-query-strongs-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = SearchIndexService(databasePath: databaseURL.path)
        try await seedSearchIndex(service: service, rows: [
            SearchIndexFixtureRow(
                key: "Genesis 1:1",
                text: "In the beginning God created the heaven and the earth.",
                moduleName: "KJV",
                order: 0,
                strongTokens: ["H0430"]
            ),
            SearchIndexFixtureRow(
                key: "Genesis 1:2",
                text: "And the Spirit of God moved upon the face of the waters.",
                moduleName: "KJV",
                order: 1,
                strongTokens: ["H0430"]
            ),
            SearchIndexFixtureRow(
                key: "John 1:1",
                text: "In the beginning was the Word.",
                moduleName: "KJV",
                order: 2,
                strongTokens: ["G3056"]
            ),
        ])

        XCTAssertTrue(service.hasIndex(for: "KJV"))
        XCTAssertTrue(service.hasStrongsIndex(for: "KJV"))

        let hits = service.searchStrongs(canonicalTokens: ["H0430"], moduleName: "KJV")

        XCTAssertEqual(hits.map(\.key), ["Genesis 1:1", "Genesis 1:2"])
        XCTAssertTrue(
            hits.allSatisfy { !$0.snippet.contains("<H") && !$0.snippet.contains("<G") },
            "Expected indexed Strong's previews to use cleaned verse text rather than raw Strong's tags"
        )
    }

    /**
     Verifies indexed text search emits hits in Android-style canonical verse order.

     Android groups Lucene hits by verse and sorts scripture results by book, chapter, and verse
     before rendering them. The iOS FTS index must therefore preserve module entry order instead of
     exposing SQLite rank ordering for broad queries such as `earth`, `jesus`, and `noah`.

     - Setup: Seeds deliberately mixed OT/NT fixture rows with canonical entry_order values.
     - Expected result: Broad searches return early canonical KJV hits before later-book relevance
       matches.
     - Failure meaning: Indexed search result ordering has drifted from Android's visible search
       result contract.
     - Side effects: Creates and removes one temporary SQLite database.
     */
    func testIndexedSearchReturnsTextHitsInCanonicalEntryOrder() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-query-order-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = SearchIndexService(databasePath: databaseURL.path)
        try await seedSearchIndex(service: service, rows: [
            SearchIndexFixtureRow(
                key: "Genesis 1:1",
                text: "In the beginning God created the heaven and the earth.",
                moduleName: "KJV",
                order: 0
            ),
            SearchIndexFixtureRow(
                key: "Genesis 1:2",
                text: "And the earth was without form, and void.",
                moduleName: "KJV",
                order: 1
            ),
            SearchIndexFixtureRow(
                key: "Genesis 6:8",
                text: "But Noah found grace in the eyes of the Lord.",
                moduleName: "KJV",
                order: 2
            ),
            SearchIndexFixtureRow(
                key: "Matthew 1:1",
                text: "The book of the generation of Jesus Christ.",
                moduleName: "KJV",
                order: 3
            ),
            SearchIndexFixtureRow(
                key: "Luke 3:23",
                text: "And Jesus himself began to be about thirty years of age.",
                moduleName: "KJV",
                order: 4
            ),
        ])

        let earthHits = service.search(query: "earth", moduleName: "KJV", wordMode: .allWords)
        let jesusHits = service.search(query: "jesus", moduleName: "KJV", wordMode: .allWords)
        let noahHits = service.search(query: "noah", moduleName: "KJV", wordMode: .allWords)

        XCTAssertEqual(
            Array(earthHits.prefix(2).map(\.key)),
            ["Genesis 1:1", "Genesis 1:2"],
            "Expected indexed search hits to follow canonical module order, not SQLite rank order"
        )
        XCTAssertEqual(
            jesusHits.first?.key,
            "Matthew 1:1",
            "Expected broad New Testament hits to start at the first canonical KJV match"
        )
        XCTAssertTrue(
            noahHits.prefix(5).map(\.key).contains("Genesis 6:8"),
            "Expected early canonical Noah hits to remain visible in the first rendered results"
        )
    }

    /**
     Seeds a deterministic FTS fixture through the production index mutation queue.

     - Parameters:
       - service: Search index service under test.
       - rows: FTS and optional Strong's-token rows to install before querying.
     - Side effects: Mutates the service's temporary SQLite database on its production mutation queue.
     - Failure modes: Throws when SQLite rejects the fixture writes.
     */
    private func seedSearchIndex(service: SearchIndexService, rows: [SearchIndexFixtureRow]) async throws {
        try await service.performIndexMutationForTesting { db in
            for row in rows {
                try self.insert(row, db: db)
                for strongToken in row.strongTokens {
                    try self.insertStrongToken(strongToken, row: row, db: db)
                }
            }
            for moduleName in Set(rows.map(\.moduleName)) {
                try self.markModuleIndexed(
                    moduleName: moduleName,
                    rowCount: rows.filter { $0.moduleName == moduleName }.count,
                    db: db
                )
            }
        }
    }

    /**
     Inserts one verse row into the temporary FTS table.

     - Parameters:
       - row: Fixture row containing the searchable text and canonical entry order.
       - db: SQLite handle supplied by `SearchIndexService` on its mutation queue.
     - Side effects: Writes one `verse_fts` row.
     - Failure modes: Throws when SQLite cannot prepare or execute the insert.
     */
    private func insert(_ row: SearchIndexFixtureRow, db: OpaquePointer?) throws {
        let sql = """
            INSERT INTO verse_fts (verse_key, plain_text, module_name, entry_order)
            VALUES (?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SearchIndexQueryFixtureError.writeFailed
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, row.key, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_text(stmt, 2, row.text, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_text(stmt, 3, row.moduleName, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_int(stmt, 4, Int32(row.order))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SearchIndexQueryFixtureError.writeFailed
        }
    }

    /**
     Inserts one canonical Strong's token row linked to an already seeded verse row.

     - Parameters:
       - strongToken: JSword-style canonical token such as `H0430`.
       - row: Fixture row whose verse key, module name, and entry order should own the token.
       - db: SQLite handle supplied by `SearchIndexService` on its mutation queue.
     - Side effects: Writes one `verse_strongs` row using the same schema as runtime indexing.
     - Failure modes: Throws when SQLite cannot prepare or execute the insert.
     */
    private func insertStrongToken(_ strongToken: String, row: SearchIndexFixtureRow, db: OpaquePointer?) throws {
        let sql = """
            INSERT INTO verse_strongs (module_name, token, verse_key, entry_order)
            VALUES (?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SearchIndexQueryFixtureError.writeFailed
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, row.moduleName, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_text(stmt, 2, strongToken, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_text(stmt, 3, row.key, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_int(stmt, 4, Int32(row.order))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SearchIndexQueryFixtureError.writeFailed
        }
    }

    /**
     Marks a fixture module as indexed so `SearchIndexService` mirrors runtime readiness.

     - Parameters:
       - moduleName: SWORD module abbreviation represented by the fixture rows.
       - rowCount: Number of searchable rows installed for the module.
       - db: SQLite handle supplied by `SearchIndexService` on its mutation queue.
     - Side effects: Upserts one `indexed_modules` metadata row.
     - Failure modes: Throws when SQLite cannot prepare or execute the metadata write.
     */
    private func markModuleIndexed(moduleName: String, rowCount: Int, db: OpaquePointer?) throws {
        let sql = """
            INSERT OR REPLACE INTO indexed_modules (module_name, verse_count, indexed_at, schema_version)
            VALUES (?, ?, datetime('now'), ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SearchIndexQueryFixtureError.writeFailed
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, moduleName, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_int(stmt, 2, Int32(rowCount))
        sqlite3_bind_int(stmt, 3, Int32(SearchIndexService.currentSchemaVersion))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SearchIndexQueryFixtureError.writeFailed
        }
    }
}

/**
 One deterministic indexed-search fixture row.

 The fixture mirrors `SearchIndexService.createIndex(module:)` output: `text` becomes a row in the
 FTS table, and each `strongTokens` value becomes a linked row in the Strong's-token table. Tests use
 this instead of rebuilding full SWORD module indexes when the behavior under test is query semantics.
 */
private struct SearchIndexFixtureRow {
    let key: String
    let text: String
    let moduleName: String
    let order: Int
    var strongTokens: [String] = []
}

private enum SearchIndexQueryFixtureError: Error {
    case writeFailed
}
