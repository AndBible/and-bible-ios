import Foundation
import SQLite3
import XCTest
@testable import BibleCore
@testable import SwordKit

/// SQLite destructor marker used by Search fixture verification queries.
private let sqliteBibleSearchTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Verifies Android-compatible SQLite Bibles participate in the production Search index contract.

 The suite exercises real MyBible readers, the SWORD adapter, mixed grouping, JSword source lookup,
 transactional replacement, cancellation, visible-text projection, and Strong's extraction without
 retaining a writable or shared source connection.
 */
final class SQLiteBibleSearchIndexTests: XCTestCase {
    /**
     Indexes sparse MyBible rows with canonical metadata, visible text, scopes, and Strong's tokens.

     - Setup: Creates a real MyBible database containing sparse OT rows, one empty real row, and an
       NT row. Source text includes an OSIS Strong's lemma.
     - Expected result: All four real rows are committed, text/Strong's searches find canonical
       coordinates, SQLite display names resolve from OSIS for each requested locale, tags stay out
       of snippets, and OT/NT scope filters use OSIS metadata.
     - Failure meaning: SQLite indexing is partial, markup-blind, non-canonical, or SWORD-only.
     - Side effects: Creates and removes isolated source and generated-index databases.
     */
    func testSQLiteBibleIndexIncludesSparseCanonicalRowsVisibleTextAndStrongs() async throws {
        let fixture = try makeSQLiteBibleFixture(
            fileName: "search-source.SQLite3",
            description: "SQLite Search Source",
            verses: [
                (10, 1, 1, "In the <w lemma=\"strong:H0430\">beginning</w> God created"),
                (10, 1, 3, "Sparse light appears"),
                (10, 1, 4, ""),
                (470, 1, 1, "Jesus begins the new testament"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let indexURL = fixture.root.appendingPathComponent("search.sqlite")
        let service = SearchIndexService(databasePath: indexURL.path)

        try await service.createIndex(source: fixture.module)

        let moduleName = fixture.module.info.name
        XCTAssertTrue(service.hasIndex(for: moduleName))
        XCTAssertTrue(service.hasStrongsIndex(for: moduleName))
        XCTAssertEqual(try indexedRowCount(at: indexURL, moduleName: moduleName), 4)
        XCTAssertEqual(service.indexProgress, 1)

        let textHit = try XCTUnwrap(
            service.search(
                query: "sparse light",
                moduleName: moduleName,
                wordMode: .allWords
            ).hits.first
        )
        XCTAssertEqual(textHit.identity.osisBookId, "Gen")
        XCTAssertEqual(textHit.identity.chapter, 1)
        XCTAssertEqual(textHit.identity.verse, 3)
        XCTAssertEqual(textHit.bookNamePresentation, .localizedCanonical)
        XCTAssertEqual(textHit.displayBook(locale: Locale(identifier: "fr")), "Genèse")
        XCTAssertEqual(textHit.displayBook(locale: Locale(identifier: "en")), "Genesis")
        XCTAssertFalse(textHit.snippet.contains("<w"))

        let strongsHit = try XCTUnwrap(
            service.searchStrongs(canonicalTokens: ["H0430"], moduleName: moduleName).hits.first
        )
        XCTAssertEqual(
            strongsHit.identity,
            SearchVerseIdentity(
                osisBookId: "Gen",
                canonicalBookOrder: SearchCanonicalBookCatalog.order(of: "Gen"),
                chapter: 1,
                verse: 1
            )
        )
        XCTAssertFalse(strongsHit.snippet.contains("lemma"))

        XCTAssertEqual(
            try service.search(
                query: "testament",
                moduleName: moduleName,
                wordMode: .allWords,
                scope: .newTestament
            ).hits.map(\.identity.osisBookId),
            ["Matt"]
        )
        XCTAssertTrue(
            try service.search(
                query: "testament",
                moduleName: moduleName,
                wordMode: .allWords,
                scope: .oldTestament
            ).hits.isEmpty
        )
    }

    /**
     Reproduces FinRK-shaped annotations through the SQLite Bible adapter and generated index.

     - Setup: Builds real MyBible verses containing a Strong's word/cross-reference and a second
       source with leading NBSP plus an encoded literal `<H123>` canonical token.
     - Expected result: Text and Strong's hits return annotation-free previews, the reference target
       is absent, and generated-index ingestion preserves both Java-trim NBSP and the literal H123
       analyzer token instead of applying the legacy regex/Foundation cleanup a second time.
     - Failure meaning: A backend adapter has reused commentary/render text for Search or the service
       has recombined canonical analyzer text with visible preview text.
     - Side effects: Creates and removes isolated source and generated-index SQLite databases.
     */
    func testStructuredSQLiteSearchExcludesCrossReferenceNotesFromCorpusAndPreview() async throws {
        let fixture = try makeSQLiteBibleFixture(
            fileName: "search-annotations.SQLite3",
            description: "Search Annotation Fixture",
            verses: [
                (
                    10,
                    1,
                    1,
                    "Visible kointähti <w lemma=\"strong:H0430\">word</w> <note type=\"crossReference\"><reference osisRef=\"Ps.119.105\">xrefonly</reference></note>"
                ),
                (10, 1, 2, "&nbsp;&lt;H123&gt;word"),
            ]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = SearchIndexService(
            databasePath: fixture.root.appendingPathComponent("search.sqlite").path
        )
        let moduleName = fixture.module.info.name

        try await service.createIndex(source: fixture.module)

        let textHit = try XCTUnwrap(
            service.search(
                query: "kointähti",
                moduleName: moduleName,
                wordMode: .allWords
            ).hits.first
        )
        XCTAssertEqual(textHit.snippet, "Visible kointähti word ")
        XCTAssertTrue(
            try service.search(
                query: "xrefonly",
                moduleName: moduleName,
                wordMode: .allWords
            ).hits.isEmpty
        )

        let strongsHit = try XCTUnwrap(
            service.searchStrongs(canonicalTokens: ["H0430"], moduleName: moduleName).hits.first
        )
        XCTAssertEqual(strongsHit.snippet, "Visible kointähti word ")

        let encodedLiteralHit = try XCTUnwrap(
            service.search(
                query: "H123",
                moduleName: moduleName,
                wordMode: .allWords
            ).hits.first
        )
        XCTAssertEqual(encodedLiteralHit.identity.verse, 2)
        XCTAssertEqual(encodedLiteralHit.snippet, "\u{00A0}word")
    }

    /**
     Verifies valid e-Sword `.bbli` OSIS is structural despite its raw-byte reader contract.

     - Setup: Creates a real `.bbli` Bible whose verse contains visible prose and a valid OSIS
       cross-reference note, then builds the production generated Search index.
     - Expected result: Visible prose is searchable/presented, while the note-only token is absent.
     - Failure meaning: `.bbli` has been blanket-treated as literal text instead of Android's OSIS
       backend contract, or annotations have re-entered one of the two Search text domains.
     - Side effects: Creates and removes isolated source and generated-index SQLite databases.
     */
    func testESwordBBLISearchProjectsValidOSISStructure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbli-structured-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("structured.bbli")
        try SQLiteDocumentTestDatabase.create(
            at: sourceURL,
            statements: [
                "CREATE TABLE Details (Title TEXT, Abbreviation TEXT, RightToLeft INTEGER, Strongs INTEGER)",
                "INSERT INTO Details VALUES ('Structured e-Sword Fixture', 'ESOSIS', 0, 0)",
                "CREATE TABLE Bible (Book INTEGER, Chapter INTEGER, Verse INTEGER, Scripture TEXT)",
                "INSERT INTO Bible VALUES (1, 1, 1, 'Visible bbliword <note type=\"crossReference\"><reference osisRef=\"Ps.119.105\">xrefonly</reference></note>')",
            ]
        )
        let module = SQLiteDocumentModule(
            reader: try ESwordReader(fileURL: sourceURL),
            origin: .manual
        )
        let service = SearchIndexService(
            databasePath: root.appendingPathComponent("search.sqlite").path
        )

        try await service.createIndex(source: module)

        let hit = try XCTUnwrap(
            service.search(
                query: "bbliword",
                moduleName: module.info.name,
                wordMode: .allWords
            ).hits.first
        )
        XCTAssertEqual(hit.snippet, "Visible bbliword ")
        XCTAssertTrue(
            try service.search(
                query: "xrefonly",
                moduleName: module.info.name,
                wordMode: .allWords
            ).hits.isEmpty
        )
    }

    /**
     Protects repairable e-Sword `.bbli` text through pinned JSword structural compatibility.

     - Setup: Indexes the checked-in `.bbli` fixture containing an unclosed `<text>` element and bare
       ampersand through the production SQLite module adapter.
     - Expected result: Entity cleanup and tag reclosure retain the verse as structured OSIS; Search
       omits the tag itself and Android's post-concatenation HTML pass collapses adjacent spaces.
     - Failure meaning: SQLite Search has diverged from pinned `OSISFilter` repair/`htmlToSpan` or
       selected an escaped/rendered fallback.
     - Side effects: Reads one checked-in database and creates/removes an isolated generated index.
     */
    func testESwordBBLISearchRepairsMalformedOSISStructurally() async throws {
        let reader = try ESwordReader(fileURL: sqliteDocumentFixtureURL("sample.bbli"))
        let module = SQLiteDocumentModule(reader: reader, origin: .manual)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbli-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SearchIndexService(
            databasePath: root.appendingPathComponent("search.sqlite").path
        )

        try await service.createIndex(source: module)

        let hit = try XCTUnwrap(
            service.search(
                query: "unchanged",
                moduleName: module.info.name,
                wordMode: .allWords
            ).hits.first
        )
        XCTAssertEqual(hit.snippet, "Plain stays unchanged & readable")
    }

    /**
     Builds real SWORD and SQLite indexes and groups equivalent verses across both backends.

     - Setup: Opens the checked-in KJV SWORD fixture and a one-verse MyBible source sharing the word
       `beginning` at Genesis 1:1.
     - Expected result: Both indexes are ready, mixed search returns both modules in the same
       canonical verse group, and per-module counts retain the selected identities.
     - Failure meaning: The backend-neutral contract or mixed Search aggregation drops one backend.
     - Side effects: Reads the checked-in SWORD fixture and creates temporary SQLite databases.
     */
    func testMixedSwordAndSQLiteIndexesGroupCanonicalResultsAndCounts() async throws {
        let fixture = try makeSQLiteBibleFixture(
            fileName: "mixed-source.SQLite3",
            description: "Mixed SQLite Source",
            verses: [(10, 1, 1, "In the beginning mixed sqlite witness")]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = try XCTUnwrap(SwordManager(modulePath: try repositorySwordFixturePath()))
        let swordModule = try XCTUnwrap(manager.module(named: "KJV"))
        let service = SearchIndexService(
            databasePath: fixture.root.appendingPathComponent("mixed-search.sqlite").path
        )

        try await service.createIndex(source: swordModule)
        try await service.createIndex(source: fixture.module)

        let sqliteName = fixture.module.info.name
        let grouped = try service.searchMultiple(
            query: "beginning",
            moduleNames: [sqliteName, "KJV"],
            wordMode: .allWords,
            scope: .currentBook(osisBookId: "Gen")
        )
        let genesisOneOne = try XCTUnwrap(grouped.groups.first {
            $0.identity == SearchVerseIdentity(
                osisBookId: "Gen",
                canonicalBookOrder: SearchCanonicalBookCatalog.order(of: "Gen"),
                chapter: 1,
                verse: 1
            )
        })

        XCTAssertEqual(
            Set(genesisOneOne.matches.map { $0.moduleName }),
            Set([sqliteName, "KJV"])
        )
        XCTAssertEqual(grouped.moduleCounts.map(\.moduleName), [sqliteName, "KJV"])
        XCTAssertEqual(grouped.moduleCounts.first?.count, 1)
        XCTAssertGreaterThanOrEqual(grouped.moduleCounts.last?.count ?? 0, 1)
    }

    /**
     Pins the combined source registry to Android `Books.getBook` precedence.

     - Setup: Registers primary and additional sources with initials/full-name collisions and
       canonically distinct UTF-16 spellings.
     - Expected result: Primary initials win Java-equal collisions, exact initials beat full names,
       exact full-name lookup uses the last owner, and folded lookup uses insertion order.
     - Failure meaning: Search can index a different module than the picker identity selected.
     - Side effects: None.
     */
    func testSearchSourceRegistryUsesJSwordIdentityPrecedence() throws {
        let swordKJV = FixtureBibleSearchSource(name: "KJV", description: "King James Version")
        let exactInitials = FixtureBibleSearchSource(name: "MATCH", description: "Initial owner")
        let firstFullName = FixtureBibleSearchSource(name: "FIRST", description: "Shared Name")
        let sqliteCollision = FixtureBibleSearchSource(name: "kjv", description: "SQLite KJV")
        let fullNameCollision = FixtureBibleSearchSource(name: "SECOND", description: "Shared Name")
        let folded = FixtureBibleSearchSource(name: "SQLiteOnly", description: "SQLite Full Name")
        let fullNameNamedLikeInitials = FixtureBibleSearchSource(
            name: "OTHER",
            description: "MATCH"
        )
        let registry = BibleSearchIndexSourceRegistry(
            primarySources: [swordKJV, exactInitials, firstFullName],
            additionalSources: [
                sqliteCollision,
                fullNameCollision,
                folded,
                fullNameNamedLikeInitials,
            ]
        )

        XCTAssertTrue(registry.source(named: "kjv") === swordKJV)
        XCTAssertTrue(registry.source(named: "MATCH") === exactInitials)
        XCTAssertTrue(registry.source(named: "Shared Name") === fullNameCollision)
        XCTAssertTrue(registry.source(named: "sqlite full name") === folded)
        XCTAssertNil(registry.source(named: "SQLite KJV"))
    }

    /**
     Verifies a source failure rolls back staged replacement rows and preserves the prior ready index.

     - Setup: Commits one complete source, then replaces the same identity with a source that throws
       after its first generated row.
     - Expected result: The error remains explicit, old rows and readiness survive, and the staged
       replacement token is absent.
     - Failure meaning: A backend read failure can publish or advertise a partial replacement index.
     - Side effects: Creates and removes one generated Search database.
     */
    func testSourceFailureRollsBackPartialReplacementAndPreservesReadyIndex() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-source-failure-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let service = SearchIndexService(databasePath: databaseURL.path)
        let oldSource = FixtureBibleSearchSource(
            name: "REPLACE",
            description: "Replacement fixture",
            entries: [fixtureEntry(text: "durable old token", verse: 1)]
        )
        let failingSource = FixtureBibleSearchSource(
            name: "REPLACE",
            description: "Replacement fixture",
            entries: [fixtureEntry(text: "partial new token", verse: 2)],
            failureAfterEntry: 0
        )
        try await service.createIndex(source: oldSource)

        do {
            try await service.createIndex(source: failingSource)
            XCTFail("Expected the staged source failure to escape index creation")
        } catch FixtureSearchSourceError.requestedFailure {
            // Expected explicit source failure.
        }

        XCTAssertTrue(service.hasIndex(for: "REPLACE"))
        XCTAssertEqual(
            try service.search(query: "durable", moduleName: "REPLACE", wordMode: .allWords).hits.count,
            1
        )
        XCTAssertEqual(
            try service.search(query: "partial", moduleName: "REPLACE", wordMode: .allWords).hits.count,
            0
        )
        XCTAssertNotNil(service.lastFailureDescription)
    }

    /**
     Verifies cancellation interrupts queued source iteration and rolls back generated rows.

     - Setup: Pauses a deterministic source after one row has entered the transaction, cancels the
       owning task, then releases iteration.
     - Expected result: Creation throws cancellation, no completion metadata or row survives, and
       progress returns to a non-ready state.
     - Failure meaning: Search cancellation can leave a partial index marked ready or continue work.
     - Side effects: Coordinates one serial index mutation through test-owned semaphores.
     */
    func testCancellationRollsBackPartialSourceWithoutPublishingReadiness() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-source-cancel-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let service = SearchIndexService(databasePath: databaseURL.path)
        let reachedPause = DispatchSemaphore(value: 0)
        let releasePause = DispatchSemaphore(value: 0)
        let source = FixtureBibleSearchSource(
            name: "CANCELLED",
            description: "Cancellation fixture",
            entries: [
                fixtureEntry(text: "first staged token", verse: 1),
                fixtureEntry(text: "second staged token", verse: 2),
            ],
            pauseAfterEntry: 0,
            reachedPause: reachedPause,
            releasePause: releasePause
        )
        let task = Task {
            try await service.createIndex(source: source)
        }
        XCTAssertEqual(reachedPause.wait(timeout: .now() + 2), .success)

        task.cancel()
        releasePause.signal()
        do {
            try await task.value
            XCTFail("Expected cancellation to escape index creation")
        } catch is CancellationError {
            // Expected cancellation contract.
        }

        XCTAssertFalse(service.hasIndex(for: "CANCELLED"))
        XCTAssertEqual(try indexedRowCount(at: databaseURL, moduleName: "CANCELLED"), 0)
        XCTAssertFalse(service.isIndexing)
        XCTAssertEqual(service.indexProgress, 0)
    }

    /** Creates one real MyBible fixture and its immutable SQLite module facade. */
    private func makeSQLiteBibleFixture(
        fileName: String,
        description: String,
        verses: [(book: Int, chapter: Int, verse: Int, text: String)]
    ) throws -> (root: URL, module: SQLiteDocumentModule) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-bible-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sourceURL = root.appendingPathComponent(fileName)
        var statements = [
            "CREATE TABLE info (name TEXT, value TEXT)",
            "INSERT INTO info VALUES ('description', '\(sqlEscaped(description))')",
            "INSERT INTO info VALUES ('language', 'en')",
            "INSERT INTO info VALUES ('strong_numbers', 'true')",
            "CREATE TABLE verses (book_number INTEGER, chapter INTEGER, verse INTEGER, text TEXT)",
        ]
        statements.append(contentsOf: verses.map {
            "INSERT INTO verses VALUES (\($0.book), \($0.chapter), \($0.verse), '\(sqlEscaped($0.text))')"
        })
        try SQLiteDocumentTestDatabase.create(at: sourceURL, statements: statements)
        let reader = try MyBibleReader(fileURL: sourceURL)
        return (root, SQLiteDocumentModule(reader: reader, origin: .manual))
    }

    /** Returns one deterministic canonical Search entry for transaction-control sources. */
    private func fixtureEntry(text: String, verse: Int) -> BibleSearchIndexEntry {
        BibleSearchIndexEntry(
            displayKey: "Genesis 1:\(verse)",
            indexText: text,
            previewText: text,
            sourceMarkup: text,
            taggedText: text,
            entryOrder: verse + 3,
            sourcePosition: verse + 3,
            osisBookId: "Gen",
            displayBook: "Genesis",
            chapter: 1,
            verse: verse
        )
    }

    /** Reads one module's generated FTS row count from a completed or rolled-back fixture database. */
    private func indexedRowCount(at databaseURL: URL, moduleName: String) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else {
            throw SQLiteBibleSearchFixtureError.openFailed
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT COUNT(*) FROM verse_fts WHERE module_name = ?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            throw SQLiteBibleSearchFixtureError.readFailed
        }
        sqlite3_bind_text(statement, 1, moduleName, -1, sqliteBibleSearchTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteBibleSearchFixtureError.readFailed
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /** Escapes a deterministic test value for a single-quoted SQLite fixture literal. */
    private func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    /** Locates the checked-in KJV fixture without relying on the process working directory. */
    private func repositorySwordFixturePath() throws -> String {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("Package.swift").path
            ) {
                return candidate
                    .appendingPathComponent(
                        "Sources/BibleUI/Tests/BibleUITests/Fixtures/sword",
                        isDirectory: true
                    )
                    .path
            }
            candidate.deleteLastPathComponent()
        }
        throw SQLiteBibleSearchFixtureError.repositoryFixtureMissing
    }

    /** Returns one checked-in SQLite reader fixture without copying or mutating it. */
    private func sqliteDocumentFixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SQLiteDocumentReaders/\(name)")
    }
}

/** Deterministic backend-neutral source used to drive transaction and registry tests. */
private final class FixtureBibleSearchSource: BibleSearchIndexSource {
    /// Installed metadata exposed to the production indexer.
    let searchIndexModuleInfo: ModuleInfo

    /// Progress denominator derived from the fixture's bounded row count.
    var searchIndexProgressTotal: Int { max(entries.count, 1) }

    /// Canonical rows emitted in caller-provided order.
    private let entries: [BibleSearchIndexEntry]

    /// Optional zero-based row after which iteration throws explicitly.
    private let failureAfterEntry: Int?

    /// Optional zero-based row after which iteration blocks for cancellation coordination.
    private let pauseAfterEntry: Int?

    /// Signals that the blocking row has already entered the service transaction.
    private let reachedPause: DispatchSemaphore?

    /// Releases blocked fixture iteration after the owning task is cancelled.
    private let releasePause: DispatchSemaphore?

    /** Creates one immutable source with optional deterministic failure/cancellation control. */
    init(
        name: String,
        description: String,
        entries: [BibleSearchIndexEntry] = [],
        failureAfterEntry: Int? = nil,
        pauseAfterEntry: Int? = nil,
        reachedPause: DispatchSemaphore? = nil,
        releasePause: DispatchSemaphore? = nil
    ) {
        searchIndexModuleInfo = ModuleInfo(
            name: name,
            description: description,
            category: .bible,
            language: "en",
            moduleDriver: "RawText",
            aboutMetadata: ModuleAboutMetadata(versification: "KJV")
        )
        self.entries = entries
        self.failureAfterEntry = failureAfterEntry
        self.pauseAfterEntry = pauseAfterEntry
        self.reachedPause = reachedPause
        self.releasePause = releasePause
    }

    /** Emits bounded fixture rows and applies caller-selected failure or pause points. */
    func forEachSearchIndexEntry(
        _ consume: (BibleSearchIndexEntry) throws -> Bool
    ) throws {
        for (index, entry) in entries.enumerated() {
            guard try consume(entry) else { return }
            if pauseAfterEntry == index {
                reachedPause?.signal()
                releasePause?.wait()
            }
            if failureAfterEntry == index {
                throw FixtureSearchSourceError.requestedFailure
            }
        }
    }
}

/** Explicit fixture source failure used to verify transaction rollback. */
private enum FixtureSearchSourceError: Error {
    /// Caller-selected failure after a generated row entered the transaction.
    case requestedFailure
}

/** Deterministic filesystem/database failures from Search test support. */
private enum SQLiteBibleSearchFixtureError: Error {
    /// The generated Search database could not be opened read-only.
    case openFailed

    /// A generated-index verification query failed.
    case readFailed

    /// The checked-in KJV fixture could not be located from the test source path.
    case repositoryFixtureMissing
}
