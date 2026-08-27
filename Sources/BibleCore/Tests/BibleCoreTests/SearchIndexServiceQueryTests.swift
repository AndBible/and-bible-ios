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
     behavior is owned by the FTS query builder, so this package test proves all-words requires both
     terms, phrase requires adjacency, and any-word restores rows that contain either term. It also
     proves all/any results publish exactly the analyzer-owned visible ranges for every matched term.
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

        let allWordHits = try service.search(
            query: "earth void",
            moduleName: "KJV",
            wordMode: .allWords
        ).hits
        XCTAssertEqual(allWordHits.map(\.key), ["Genesis 1:2"])
        XCTAssertEqual(
            allWordHits.flatMap(\.snippetSegments).filter(\.isEmphasized).map(\.text),
            ["earth", "void"]
        )
        XCTAssertEqual(
            try service.search(query: "earth void", moduleName: "KJV", wordMode: .phrase).hits.map(\.key),
            []
        )
        let anyWordHits = try service.search(
            query: "earth void",
            moduleName: "KJV",
            wordMode: .anyWord
        ).hits
        XCTAssertEqual(anyWordHits.map(\.key), ["Genesis 1:1", "Genesis 1:2", "Genesis 1:3"])
        XCTAssertEqual(
            anyWordHits.map { $0.snippetSegments.filter(\.isEmphasized).map(\.text) },
            [["earth"], ["earth", "void"], ["void"]]
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
            SearchIndexFixtureRow(
                key: "創世記 1:3", text: "light", moduleName: "KJV", order: 0,
                displayBook: "創世記", osisBookId: "Gen", chapter: 1, verse: 3
            ),
            SearchIndexFixtureRow(
                key: "馬太福音 1:1", text: "light", moduleName: "KJV", order: 1,
                displayBook: "馬太福音", osisBookId: "Matt", chapter: 1, verse: 1
            ),
            SearchIndexFixtureRow(
                key: "ヨハネ 1:4", text: "light", moduleName: "KJV", order: 2,
                displayBook: "ヨハネ", osisBookId: "John", chapter: 1, verse: 4
            ),
            SearchIndexFixtureRow(
                key: "默示録 22:5", text: "light", moduleName: "KJV", order: 3,
                displayBook: "默示録", osisBookId: "Rev", chapter: 22, verse: 5
            ),
            SearchIndexFixtureRow(
                key: "Tobie 1:1", text: "light", moduleName: "KJV", order: 4,
                displayBook: "Tobie", osisBookId: "Tob", chapter: 1, verse: 1
            ),
        ])

        XCTAssertEqual(
            try service.search(query: "light", moduleName: "KJV", wordMode: .allWords).hits.map(\.key),
            ["創世記 1:3", "馬太福音 1:1", "ヨハネ 1:4", "默示録 22:5", "Tobie 1:1"]
        )
        XCTAssertEqual(
            try service.search(
                query: "light",
                moduleName: "KJV",
                wordMode: .allWords,
                scope: .oldTestament
            ).hits.map(\.key),
            ["創世記 1:3"]
        )
        XCTAssertEqual(
            try service.search(
                query: "light",
                moduleName: "KJV",
                wordMode: .allWords,
                scope: .newTestament
            ).hits.map(\.key),
            ["馬太福音 1:1", "ヨハネ 1:4", "默示録 22:5"]
        )
        XCTAssertEqual(
            try service.search(
                query: "light",
                moduleName: "KJV",
                wordMode: .allWords,
                scope: .currentBook(osisBookId: "John")
            ).hits.map(\.key),
            ["ヨハネ 1:4"]
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
            SearchIndexFixtureRow(
                key: "Genèse 1:2", text: "earth", moduleName: "AATESTWEB", order: 0,
                displayBook: "Genèse", osisBookId: "Gen", chapter: 1, verse: 2
            ),
            SearchIndexFixtureRow(key: "Romans 8:1", text: "earth", moduleName: "AATESTWEB", order: 1),
        ])

        let grouped = try service.searchMultiple(
            query: "earth",
            moduleNames: ["AATESTWEB", "KJV"],
            wordMode: .allWords
        )

        XCTAssertEqual(grouped.groups.count, 2)
        XCTAssertEqual(grouped.groups.first?.identity.osisBookId, "Gen")
        XCTAssertEqual(grouped.groups.first?.matches.map(\.moduleName), ["AATESTWEB", "KJV"])
        XCTAssertEqual(grouped.moduleCounts.map(\.moduleName), ["AATESTWEB", "KJV"])
        XCTAssertEqual(grouped.moduleCounts.map(\.count), [2, 1])
        XCTAssertEqual(grouped.totalHitCount, 3)

        let secondTranslationHit = try XCTUnwrap(
            grouped.groups.first?.matches.first(where: { $0.moduleName == "AATESTWEB" })
        )
        XCTAssertEqual(
            SearchNavigationTarget(hit: secondTranslationHit),
            SearchNavigationTarget(
                moduleName: "AATESTWEB",
                osisBookId: "Gen",
                displayBook: "Genèse",
                chapter: 1,
                verse: 2
            )
        )
    }

    /**
     Verifies indexed Strong's search reads canonical token rows in Android-style module order.

     Android's JSword search uses the Lucene `strong` field for "find all occurrences" instead of
     walking every verse at interaction time. This test keeps the iOS `verse_strongs` contract in the
     BibleCore package lane with a deterministic fixture, so package CI does not need to rebuild the
     full KJV fixture index to prove the same behavior.

     - Setup: Seeds cleaned verse-text rows plus explicit Strong's token rows for KJV.
     - Expected result: H0430 hits return only the tokenized verses, ordered by canonical entry order,
       with cleaned snippets and Strong's readiness set for the module; analyzer-empty input returns
       an authorized zero-hit single-module and grouped result rather than an error.
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
                strongTokens: ["H0430"],
                strongHighlightRanges: [
                    "H0430": [SearchTextHighlightRange(location: 17, length: 3)],
                ]
            ),
            SearchIndexFixtureRow(
                key: "Genesis 1:2",
                text: "And the Spirit of God moved upon the face of the waters.",
                moduleName: "KJV",
                order: 1,
                strongTokens: ["H0430"],
                strongHighlightRanges: [
                    "H0430": [SearchTextHighlightRange(location: 18, length: 3)],
                ]
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

        let hits = try service.searchStrongs(canonicalTokens: ["H0430"], moduleName: "KJV").hits

        XCTAssertEqual(hits.map(\.key), ["Genesis 1:1", "Genesis 1:2"])
        XCTAssertTrue(
            hits.allSatisfy { !$0.snippet.contains("<H") && !$0.snippet.contains("<G") },
            "Expected indexed Strong's previews to use cleaned verse text rather than raw Strong's tags"
        )
        XCTAssertEqual(
            hits.map { $0.snippetSegments.filter(\.isEmphasized).map(\.text) },
            [["God"], ["God"]]
        )

        let analyzerEmpty = try service.searchStrongs(
            canonicalTokens: [],
            moduleName: "KJV"
        )
        XCTAssertEqual(analyzerEmpty.moduleName, "KJV")
        XCTAssertTrue(analyzerEmpty.hits.isEmpty)

        let groupedAnalyzerEmpty = try service.searchStrongsMultiple(
            canonicalTokens: [],
            sourceIdentities: [
                SearchIndexSourceIdentity(
                    moduleName: "KJV",
                    version: "",
                    fingerprint: String(repeating: "a", count: 64)
                ),
            ]
        )
        XCTAssertEqual(groupedAnalyzerEmpty.moduleCounts, [
            SearchModuleCount(moduleName: "KJV", count: 0),
        ])
        XCTAssertTrue(groupedAnalyzerEmpty.groups.isEmpty)
        XCTAssertEqual(groupedAnalyzerEmpty.totalHitCount, 0)
    }

    /**
     Verifies Strong's queries retain every selected module and group equivalent verses.

     The selected list repeats both successful modules to model duplicated restored/picker input.
     Android's append-based aggregation does not terminate on duplicate selection tokens, while the
     iOS query boundary intentionally keeps the first exact module occurrence so one translation
     cannot create duplicate result rows.

     - Setup: Seeds two Strong's-capable modules plus one zero-hit module and queries a repeated
       selected-module list.
     - Expected result: Both name- and source-identity production overloads return one canonical
       verse group retaining LSG then KJV, and each exact module has one count bucket in
       first-selected order.
     - Failure meaning: Find All can either drop a selected translation, duplicate its visible row,
       or reach the latent grouped-result duplicate-key boundary found while investigating #416.
     - Side effects: Creates and removes one temporary SQLite database.
     */
    func testIndexedStrongsSearchGroupsAcrossAllSelectedTranslations() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-query-strongs-multi-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let service = SearchIndexService(databasePath: databaseURL.path)
        try await seedSearchIndex(service: service, rows: [
            SearchIndexFixtureRow(
                key: "Genesis 1:1", text: "God created", moduleName: "KJV", order: 0,
                strongTokens: ["H0430"]
            ),
            SearchIndexFixtureRow(
                key: "Genèse 1:1", text: "Dieu créa", moduleName: "LSG", order: 0,
                strongTokens: ["H0430"], displayBook: "Genèse", osisBookId: "Gen",
                chapter: 1, verse: 1
            ),
            SearchIndexFixtureRow(
                key: "Genesis 1:1", text: "God created", moduleName: "PLAIN", order: 0
            ),
        ])

        let grouped = try service.searchStrongsMultiple(
            canonicalTokens: ["H0430"],
            moduleNames: ["LSG", "LSG", "PLAIN", "KJV", "KJV"]
        )
        let sourceFingerprint = String(repeating: "a", count: 64)
        let groupedBySourceIdentity = try service.searchStrongsMultiple(
            canonicalTokens: ["H0430"],
            sourceIdentities: ["LSG", "LSG", "PLAIN", "KJV", "KJV"].map {
                SearchIndexSourceIdentity(
                    moduleName: $0,
                    version: "",
                    fingerprint: sourceFingerprint
                )
            }
        )

        XCTAssertEqual(grouped.groups.count, 1)
        XCTAssertEqual(grouped.groups[0].matches.map(\.moduleName), ["LSG", "KJV"])
        XCTAssertEqual(grouped.moduleCounts.map(\.moduleName), ["LSG", "PLAIN", "KJV"])
        XCTAssertEqual(grouped.moduleCounts.map(\.count), [1, 0, 1])
        XCTAssertEqual(grouped.totalHitCount, 2)
        XCTAssertEqual(groupedBySourceIdentity, grouped)
    }

    /**
     Verifies grouped Search remains total when a caller supplies duplicate exact module buckets.

     Production text and Strong's services de-duplicate selected initials before querying, but the
     public result contract previously rebuilt both success and failure maps with
     `Dictionary(uniqueKeysWithValues:)`. Any restored, test, or future caller that repeated a
     module therefore terminated the process instead of degrading like Android's append-based
     aggregation.

     - Setup: Supplies two KJV success buckets, two BAD failure buckets, a contradictory KJV failure,
       and duplicate module-order entries. The ignored duplicate KJV result is marked truncated so
       retained-first semantics are observable.
     - Expected result: The first KJV bucket wins, WEB remains the second match, only the first BAD
       failure remains, the KJV failure is suppressed by success, and truncation stays false.
     - Failure meaning: Multi-translation Search can still trap, expose duplicate SwiftUI identities,
       or publish contradictory success/failure state for one exact installed module.
     - Side effects: None.
     */
    func testGroupedResultsCoalescesDuplicateExactModuleBucketsWithoutTrap() {
        let verse = SearchVerseIdentity(
            osisBookId: "Gen",
            canonicalBookOrder: 0,
            chapter: 1,
            verse: 1
        )
        let firstKJVHit = SearchModuleHit(
            moduleName: "KJV",
            key: "Genesis 1:1",
            displayBook: "Genesis",
            snippet: "God created",
            identity: verse
        )
        let duplicateKJVHit = SearchModuleHit(
            moduleName: "KJV",
            key: "Genesis 1:2",
            displayBook: "Genesis",
            snippet: "duplicate must not publish",
            identity: SearchVerseIdentity(
                osisBookId: "Gen",
                canonicalBookOrder: 0,
                chapter: 1,
                verse: 2
            )
        )
        let webHit = SearchModuleHit(
            moduleName: "WEB",
            key: "Genesis 1:1",
            displayBook: "Genesis",
            snippet: "God created",
            identity: verse
        )

        let grouped = SearchGroupedResults(
            moduleResults: [
                SearchModuleResults(moduleName: "KJV", hits: [firstKJVHit]),
                SearchModuleResults(
                    moduleName: "KJV",
                    hits: [duplicateKJVHit],
                    isTruncated: true
                ),
                SearchModuleResults(moduleName: "WEB", hits: [webHit]),
            ],
            moduleOrder: ["KJV", "KJV", "WEB"],
            moduleFailures: [
                SearchModuleFailure(moduleName: "BAD", message: "first failure"),
                SearchModuleFailure(moduleName: "BAD", message: "duplicate failure"),
                SearchModuleFailure(moduleName: "KJV", message: "contradictory failure"),
            ]
        )

        XCTAssertEqual(grouped.groups.count, 1)
        XCTAssertEqual(grouped.groups[0].matches.map(\.moduleName), ["KJV", "WEB"])
        XCTAssertEqual(grouped.moduleCounts.map(\.moduleName), ["KJV", "WEB"])
        XCTAssertEqual(grouped.moduleCounts.map(\.count), [1, 1])
        XCTAssertEqual(grouped.moduleFailures, [
            SearchModuleFailure(moduleName: "BAD", message: "first failure"),
        ])
        XCTAssertEqual(grouped.totalHitCount, 2)
        XCTAssertFalse(grouped.isTruncated)
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

        let earthHits = try service.search(query: "earth", moduleName: "KJV", wordMode: .allWords).hits
        let jesusHits = try service.search(query: "jesus", moduleName: "KJV", wordMode: .allWords).hits
        let noahHits = try service.search(query: "noah", moduleName: "KJV", wordMode: .allWords).hits

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
            INSERT INTO verse_fts (
                search_text, verse_key, plain_text, module_name, entry_order, osis_book,
                display_book, display_book_mode, chapter, verse, book_order, canon_scope
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SearchIndexQueryFixtureError.writeFailed
        }
        defer { sqlite3_finalize(stmt) }

        let analyzedText = try SearchTextAnalyzer.analyzedText(
            row.text,
            profile: SearchTextAnalyzer.profile(for: "en")
        )
        sqlite3_bind_text(stmt, 1, analyzedText, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_text(stmt, 2, row.key, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_text(stmt, 3, row.text, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_text(stmt, 4, row.moduleName, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_int(stmt, 5, Int32(row.order))
        sqlite3_bind_text(stmt, 6, row.osisBookId, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_text(stmt, 7, row.displayBook, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_text(
            stmt,
            8,
            SearchBookNamePresentation.source.rawValue,
            -1,
            searchIndexQueryFixtureSQLiteTransient
        )
        sqlite3_bind_int(stmt, 9, Int32(row.chapter))
        sqlite3_bind_int(stmt, 10, Int32(row.verse))
        sqlite3_bind_int(stmt, 11, Int32(SearchCanonicalBookCatalog.order(of: row.osisBookId)))
        sqlite3_bind_text(
            stmt,
            12,
            SearchCanonicalBookCatalog.section(of: row.osisBookId).rawValue,
            -1,
            searchIndexQueryFixtureSQLiteTransient
        )
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
            INSERT INTO verse_strongs (
                module_name, token, verse_key, entry_order, highlight_ranges
            ) VALUES (?, ?, ?, ?, ?)
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
        let encodedRanges = row.strongHighlightRanges[strongToken, default: []]
            .map { "\($0.location):\($0.length)" }
            .joined(separator: ",")
        sqlite3_bind_text(stmt, 5, encodedRanges, -1, searchIndexQueryFixtureSQLiteTransient)
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
            INSERT OR REPLACE INTO indexed_modules (
                module_name, verse_count, indexed_at, schema_version, language_code, analyzer_id,
                strongs_complete, source_version, source_fingerprint, store_generation
            ) VALUES (
                ?, ?, datetime('now'), ?, 'en', ?, 1, '', ?,
                (SELECT store_generation FROM search_index_state WHERE id = 1)
            )
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SearchIndexQueryFixtureError.writeFailed
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, moduleName, -1, searchIndexQueryFixtureSQLiteTransient)
        sqlite3_bind_int(stmt, 2, Int32(rowCount))
        sqlite3_bind_int(stmt, 3, Int32(SearchIndexService.currentSchemaVersion))
        sqlite3_bind_text(
            stmt,
            4,
            SearchTextAnalyzer.profile(for: "en").identifier,
            -1,
            searchIndexQueryFixtureSQLiteTransient
        )
        sqlite3_bind_text(
            stmt,
            5,
            String(repeating: "a", count: 64),
            -1,
            searchIndexQueryFixtureSQLiteTransient
        )
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
    let strongTokens: [String]
    let strongHighlightRanges: [String: [SearchTextHighlightRange]]
    let displayBook: String
    let osisBookId: String
    let chapter: Int
    let verse: Int

    init(
        key: String,
        text: String,
        moduleName: String,
        order: Int,
        strongTokens: [String] = [],
        strongHighlightRanges: [String: [SearchTextHighlightRange]] = [:],
        displayBook explicitDisplayBook: String? = nil,
        osisBookId explicitOsisBookId: String? = nil,
        chapter explicitChapter: Int? = nil,
        verse explicitVerse: Int? = nil
    ) {
        let components = key.split(separator: " ")
        let chapterVerse = components.last?.split(separator: ":") ?? []
        let parsedDisplayBook = components.dropLast().joined(separator: " ")
        self.key = key
        self.text = text
        self.moduleName = moduleName
        self.order = order
        self.strongTokens = strongTokens
        self.strongHighlightRanges = strongHighlightRanges
        self.displayBook = explicitDisplayBook ?? parsedDisplayBook
        self.osisBookId = explicitOsisBookId ?? [
            "Genesis": "Gen",
            "Matthew": "Matt",
            "John": "John",
            "Luke": "Luke",
            "Romans": "Rom",
            "Revelation of John": "Rev",
        ][parsedDisplayBook] ?? parsedDisplayBook
        self.chapter = explicitChapter ?? chapterVerse.first.flatMap { Int($0) } ?? 0
        self.verse = explicitVerse ?? chapterVerse.dropFirst().first.flatMap { Int($0) } ?? 0
    }
}

private enum SearchIndexQueryFixtureError: Error {
    case writeFailed
}
