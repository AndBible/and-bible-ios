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
     Fail-safe budget for semaphore-backed concurrency checkpoints on loaded CI runners.

     These tests synchronize on explicit production events rather than elapsed time. The deadline
     only prevents a genuine deadlock from hanging the suite and allows simulator task scheduling to
     exceed the former two-second bound without changing the event ordering under test.
     */
    private static let synchronizationTimeout: DispatchTimeInterval = .seconds(20)

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
     Verifies an active mutation gates only its Java-exact module owner.

     - Setup: Builds indexes whose initials are canonically equivalent in Swift but contain distinct
       Java UTF-16 sequences, then pauses a rebuild of only the composed owner inside its transaction.
     - Expected result: The composed owner reports unavailable while the decomposed sibling remains
       ready and searchable; releasing the writer publishes the replacement without touching the sibling.
     - Failure meaning: Search mutation state is keyed by Swift `String`, so Android-distinct books
       block or clear one another while either index is scheduled/creating.
     - Side effects: Coordinates one generated-index writer with semaphores and removes its isolated
       SQLite database. The `defer` release prevents a failed assertion from stranding the writer.
     */
    func testCanonicallyEquivalentModuleMutationsRemainIsolated() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-java-exact-mutation-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let composedName = "SEARCH\u{00C9}"
        let decomposedName = "SEARCHE\u{0301}"
        XCTAssertEqual(composedName, decomposedName, "The fixture must collide under Swift String")
        XCTAssertFalse(SwordJavaStringIdentity.equals(composedName, decomposedName))

        let reachedWriterPause = DispatchSemaphore(value: 0)
        let releaseWriterPause = DispatchSemaphore(value: 0)
        defer { releaseWriterPause.signal() }
        let service = SearchIndexService(databasePath: databaseURL.path)
        let composedOriginal = FixtureBibleSearchSource(
            name: composedName,
            description: "Composed exact owner",
            entries: [fixtureEntry(text: "composedold witness", verse: 1)]
        )
        let decomposedOriginal = FixtureBibleSearchSource(
            name: decomposedName,
            description: "Decomposed exact owner",
            entries: [fixtureEntry(text: "decomposedstable witness", verse: 2)]
        )
        let composedReplacement = FixtureBibleSearchSource(
            name: composedName,
            description: "Composed exact owner",
            entries: [fixtureEntry(text: "composednew witness", verse: 3)],
            pauseAfterEntry: 0,
            reachedPause: reachedWriterPause,
            releasePause: releaseWriterPause
        )
        try await service.createIndex(source: composedOriginal)
        try await service.createIndex(source: decomposedOriginal)
        let composedIdentity = composedOriginal.searchIndexSourceIdentity
        let decomposedIdentity = decomposedOriginal.searchIndexSourceIdentity

        let rebuild = Task {
            try await service.createIndex(source: composedReplacement)
        }
        XCTAssertEqual(
            reachedWriterPause.wait(timeout: .now() + Self.synchronizationTimeout),
            .success
        )

        XCTAssertFalse(service.hasIndex(for: composedIdentity))
        XCTAssertTrue(service.hasIndex(for: decomposedIdentity))
        XCTAssertEqual(
            service.modulesNeedingIndex(from: [composedIdentity, decomposedIdentity]),
            [composedIdentity]
        )
        XCTAssertEqual(
            try service.search(
                query: "decomposedstable",
                sourceIdentity: decomposedIdentity,
                wordMode: .allWords
            ).hits.count,
            1
        )

        releaseWriterPause.signal()
        try await rebuild.value
        XCTAssertTrue(service.hasIndex(for: composedReplacement.searchIndexSourceIdentity))
        XCTAssertTrue(service.hasIndex(for: decomposedIdentity))
    }

    /**
     Verifies source-capture tokens and readiness reject a canonically equivalent different owner.

     - Setup: Wraps composed/decomposed sources with the same version and fingerprint so only their
       exact module initials distinguish them, captures a token for the composed source, and attempts
       single, batch, and token-reuse authorization with the decomposed source.
     - Expected result: Both identities coexist in `Set`, every cross-spelling authorization fails,
       and a legitimately built decomposed index is not ready under the composed identity.
     - Failure meaning: Synthesized Swift hashing or direct `String ==` can bless a different JSword
       book whose initials normalize to the same Unicode spelling.
     - Side effects: Builds one isolated generated index and removes its SQLite database afterward.
     */
    func testIndexAuthorizationRejectsCanonicallyEquivalentDifferentOwner() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-java-exact-authorization-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let composedName = "TOKEN\u{00C9}"
        let decomposedName = "TOKENE\u{0301}"
        let sharedFingerprint = String(repeating: "a", count: 64)
        let composed = ExactIdentityBibleSearchSource(
            base: FixtureBibleSearchSource(
                name: composedName,
                description: "Composed token owner",
                entries: [fixtureEntry(text: "composedtoken witness", verse: 1)]
            ),
            sourceIdentity: SearchIndexSourceIdentity(
                moduleName: composedName,
                version: "",
                fingerprint: sharedFingerprint
            )
        )
        let decomposed = ExactIdentityBibleSearchSource(
            base: FixtureBibleSearchSource(
                name: decomposedName,
                description: "Decomposed token owner",
                entries: [fixtureEntry(text: "decomposedtoken witness", verse: 2)]
            ),
            sourceIdentity: SearchIndexSourceIdentity(
                moduleName: decomposedName,
                version: "",
                fingerprint: sharedFingerprint
            )
        )
        let service = SearchIndexService(databasePath: databaseURL.path)

        XCTAssertNotEqual(composed.searchIndexSourceIdentity, decomposed.searchIndexSourceIdentity)
        XCTAssertEqual(
            Set([composed.searchIndexSourceIdentity, decomposed.searchIndexSourceIdentity]).count,
            2
        )
        let composedCapture = try XCTUnwrap(
            service.captureIndexCreationSource(named: composedName) { composed }
        )

        do {
            try await service.createIndex(
                source: decomposed,
                authorization: composedCapture.authorization
            )
            XCTFail("Expected the composed authorization to reject the decomposed owner")
        } catch {
            XCTAssertEqual(
                error as? SearchIndexError,
                .indexUnavailable(moduleName: decomposedName)
            )
        }
        XCTAssertThrowsError(
            try service.captureIndexCreationSource(named: composedName) { decomposed }
        ) { error in
            XCTAssertEqual(
                error as? SearchIndexError,
                .indexVerificationFailed(moduleName: composedName)
            )
        }
        XCTAssertThrowsError(
            try service.captureIndexCreationSources(named: [composedName]) {
                [(name: decomposedName, source: decomposed as any BibleSearchIndexSource)]
            }
        ) { error in
            XCTAssertEqual(
                error as? SearchIndexError,
                .indexVerificationFailed(moduleName: composedName)
            )
        }

        try await service.createIndex(source: decomposed)
        XCTAssertTrue(service.hasIndex(for: decomposed.searchIndexSourceIdentity))
        XCTAssertFalse(service.hasIndex(for: composed.searchIndexSourceIdentity))
        XCTAssertThrowsError(
            try service.search(
                query: "decomposedtoken",
                sourceIdentity: composed.searchIndexSourceIdentity,
                wordMode: .allWords
            )
        ) { error in
            XCTAssertEqual(
                error as? SearchIndexError,
                .indexUnavailable(moduleName: composedName)
            )
        }
    }

    /**
     Verifies multi-module readiness, queries, grouping, and row diffing retain both exact owners.

     - Setup: Builds canonically equivalent composed/decomposed modules with the same version and
       fingerprint, one shared text hit, and one shared Strong's hit at the same canonical verse.
     - Expected result: Both module-name and source-identity overloads return two counts/matches,
       readiness reports neither missing, and hit/failure SwiftUI identifiers remain distinct.
     - Failure meaning: A `Set<String>`, `[String: …]`, synthesized identity hash, or `String` row ID
       has merged Android-distinct module owners at any point in the Search result pipeline.
     - Side effects: Builds and queries two indexes in one isolated SQLite database, then removes it.
     */
    func testMultiModuleSearchRetainsCanonicallyEquivalentExactOwners() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-java-exact-grouping-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let composedName = "GROUP\u{00C9}"
        let decomposedName = "GROUPE\u{0301}"
        let sharedFingerprint = String(repeating: "b", count: 64)
        let composed = ExactIdentityBibleSearchSource(
            base: FixtureBibleSearchSource(
                name: composedName,
                description: "Composed grouped owner",
                entries: [fixtureEntry(text: "exactgroup witness", verse: 1, strongToken: "H0430")]
            ),
            sourceIdentity: SearchIndexSourceIdentity(
                moduleName: composedName,
                version: "",
                fingerprint: sharedFingerprint
            )
        )
        let decomposed = ExactIdentityBibleSearchSource(
            base: FixtureBibleSearchSource(
                name: decomposedName,
                description: "Decomposed grouped owner",
                entries: [fixtureEntry(text: "exactgroup witness", verse: 1, strongToken: "H0430")]
            ),
            sourceIdentity: SearchIndexSourceIdentity(
                moduleName: decomposedName,
                version: "",
                fingerprint: sharedFingerprint
            )
        )
        let identities = [composed.searchIndexSourceIdentity, decomposed.searchIndexSourceIdentity]
        let names = [composedName, decomposedName]
        let service = SearchIndexService(databasePath: databaseURL.path)
        try await service.createIndex(source: composed)
        try await service.createIndex(source: decomposed)

        XCTAssertTrue(service.modulesNeedingIndex(from: identities).isEmpty)
        let textByIdentity = try service.searchMultiple(
            query: "exactgroup",
            sourceIdentities: identities,
            wordMode: .allWords
        )
        let textByName = try service.searchMultiple(
            query: "exactgroup",
            moduleNames: names,
            wordMode: .allWords
        )
        let strongsByIdentity = try service.searchStrongsMultiple(
            canonicalTokens: ["H0430"],
            sourceIdentities: identities
        )
        let strongsByName = try service.searchStrongsMultiple(
            canonicalTokens: ["H0430"],
            moduleNames: names
        )

        for grouped in [textByIdentity, textByName, strongsByIdentity, strongsByName] {
            XCTAssertEqual(grouped.totalHitCount, 2)
            XCTAssertEqual(grouped.moduleCounts.count, 2)
            XCTAssertEqual(
                Set(grouped.moduleCounts.map { SwordJavaExactStringIdentity($0.moduleName) }).count,
                2
            )
            let matches = try XCTUnwrap(grouped.groups.first).matches
            XCTAssertEqual(matches.count, 2)
            XCTAssertEqual(Set(matches.map(\.id)).count, 2)
        }
        let failureIDs = [
            SearchModuleFailure(moduleName: composedName, message: "first").id,
            SearchModuleFailure(moduleName: decomposedName, message: "second").id,
        ]
        XCTAssertEqual(Set(failureIDs).count, 2)
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
     Verifies Android's per-book CREATING gate and committed Search snapshot under a failed rebuild.

     - Setup: Commits a two-row text/Strong index plus an unrelated module, then pauses two already
       authorized reads after metadata establishes their snapshots. A same-module replacement pauses
       after its first staged text/Strong row and then throws deterministically.
     - Expected result: The admitted reads finish on the complete old generation; newly admitted reads
       for the rebuilding module fail as unavailable; the unrelated module remains searchable; after
       rollback, old text/Strong rows remain and staged rows are absent.
     - Failure meaning: iOS can expose a writer transaction through its read path, diverge from Android
       `IndexStatus.CREATING`, block unrelated books globally, or leak rolled-back generated content.
     - Side effects: Coordinates operation-owned SQLite readers and the serial writer with semaphores,
       then removes one isolated generated-index database. No timing sleeps are used.
     */
    func testConcurrentFailedRebuildKeepsCommittedSnapshotsAndGatesOnlyAffectedModule() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-concurrent-snapshot-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let readBarrier = SearchReadAuthorizationBarrier(
            moduleName: "REPLACE",
            expectedReaders: 2
        )
        let reachedWriterPause = DispatchSemaphore(value: 0)
        let releaseWriterPause = DispatchSemaphore(value: 0)
        defer {
            readBarrier.releaseReaders()
            DispatchQueue.global(qos: .userInitiated).async {
                releaseWriterPause.signal()
            }
        }
        let service = SearchIndexService(
            databasePath: databaseURL.path,
            readAuthorizationCheckpoint: { moduleName in
                readBarrier.checkpoint(moduleName: moduleName)
            }
        )
        let original = FixtureBibleSearchSource(
            name: "REPLACE",
            description: "Replacement fixture",
            entries: [
                fixtureEntry(text: "durableold witness one", verse: 1, strongToken: "H0430"),
                fixtureEntry(text: "durableold witness two", verse: 2, strongToken: "H0430"),
            ]
        )
        let unrelated = FixtureBibleSearchSource(
            name: "OTHER",
            description: "Unrelated fixture",
            entries: [
                fixtureEntry(text: "unrelatedstable witness", verse: 1, strongToken: "H0002"),
            ]
        )
        let failingReplacement = FixtureBibleSearchSource(
            name: "REPLACE",
            description: "Replacement fixture",
            entries: [
                fixtureEntry(text: "partialnew staged witness", verse: 3, strongToken: "H0001"),
                fixtureEntry(text: "completenew staged witness", verse: 4, strongToken: "H0001"),
            ],
            failureAfterEntry: 0,
            pauseAfterEntry: 0,
            reachedPause: reachedWriterPause,
            releasePause: releaseWriterPause
        )
        try await service.createIndex(source: original)
        try await service.createIndex(source: unrelated)
        let originalIdentity = original.searchIndexSourceIdentity

        let admittedTextRead = Task.detached {
            try service.search(
                query: "durableold",
                sourceIdentity: originalIdentity,
                wordMode: .allWords
            )
        }
        let admittedStrongsRead = Task.detached {
            try service.searchStrongs(
                canonicalTokens: ["H0430"],
                sourceIdentity: originalIdentity
            )
        }
        XCTAssertTrue(
            readBarrier.waitForReaders(timeout: .now() + Self.synchronizationTimeout)
        )

        let rebuild = Task {
            try await service.createIndex(source: failingReplacement)
        }
        XCTAssertEqual(
            reachedWriterPause.wait(timeout: .now() + Self.synchronizationTimeout),
            .success
        )

        XCTAssertFalse(service.hasIndex(for: originalIdentity))
        XCTAssertThrowsError(
            try service.search(
                query: "partialnew",
                sourceIdentity: originalIdentity,
                wordMode: .allWords
            )
        ) { error in
            XCTAssertEqual(error as? SearchIndexError, .indexUnavailable(moduleName: "REPLACE"))
        }
        XCTAssertThrowsError(
            try service.searchStrongs(
                canonicalTokens: ["H0001"],
                sourceIdentity: originalIdentity
            )
        ) { error in
            XCTAssertEqual(error as? SearchIndexError, .indexUnavailable(moduleName: "REPLACE"))
        }
        XCTAssertEqual(
            try service.search(
                query: "unrelatedstable",
                sourceIdentity: unrelated.searchIndexSourceIdentity,
                wordMode: .allWords
            ).hits.count,
            1
        )
        XCTAssertEqual(
            try service.searchStrongs(
                canonicalTokens: ["H0002"],
                sourceIdentity: unrelated.searchIndexSourceIdentity
            ).hits.count,
            1
        )

        readBarrier.releaseReaders()
        let admittedTextResults = try await admittedTextRead.value
        let admittedStrongsResults = try await admittedStrongsRead.value
        XCTAssertEqual(admittedTextResults.hits.count, 2)
        XCTAssertEqual(admittedStrongsResults.hits.count, 2)

        DispatchQueue.global(qos: .userInitiated).async {
            releaseWriterPause.signal()
        }
        do {
            try await rebuild.value
            XCTFail("Expected the staged replacement failure to escape index creation")
        } catch FixtureSearchSourceError.requestedFailure {
            // Expected explicit rollback path.
        }

        XCTAssertTrue(service.hasIndex(for: originalIdentity))
        XCTAssertEqual(
            try service.search(
                query: "durableold",
                sourceIdentity: originalIdentity,
                wordMode: .allWords
            ).hits.count,
            2
        )
        XCTAssertEqual(
            try service.searchStrongs(
                canonicalTokens: ["H0430"],
                sourceIdentity: originalIdentity
            ).hits.count,
            2
        )
        XCTAssertTrue(
            try service.search(
                query: "partialnew",
                sourceIdentity: originalIdentity,
                wordMode: .allWords
            ).hits.isEmpty
        )
        XCTAssertTrue(
            try service.searchStrongs(
                canonicalTokens: ["H0001"],
                sourceIdentity: originalIdentity
            ).hits.isEmpty
        )
    }

    /**
     Verifies a completed store invalidation rejects logical reads pinned to its previous WAL snapshot.

     - Setup: Pauses text and Strong's reads after old metadata establishes their snapshots, posts the
       synchronous installed-module mutation notification, then releases both readers after the durable
       generation update has completed and its transient blocked bit has cleared.
     - Expected result: Both reads throw `indexUnavailable` because their captured in-memory epoch is
       stale, and subsequent readiness checks reject the invalidated metadata.
     - Failure meaning: Comparing only SQLite generations inside one old snapshot can authorize content
       from a replaced or uninstalled module after notification processing has already completed.
     - Side effects: Advances one isolated Search database's store generation and removes the database.
     */
    func testModuleStoreInvalidationEpochRejectsPinnedTextAndStrongsSnapshots() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-invalidation-epoch-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let notificationCenter = NotificationCenter()
        let readBarrier = SearchReadAuthorizationBarrier(
            moduleName: "INVALIDATE",
            expectedReaders: 2
        )
        defer { readBarrier.releaseReaders() }
        let service = SearchIndexService(
            databasePath: databaseURL.path,
            notificationCenter: notificationCenter,
            readAuthorizationCheckpoint: { moduleName in
                readBarrier.checkpoint(moduleName: moduleName)
            }
        )
        let source = FixtureBibleSearchSource(
            name: "INVALIDATE",
            description: "Invalidation epoch fixture",
            entries: [
                fixtureEntry(text: "invalidatedold witness one", verse: 1, strongToken: "H0430"),
                fixtureEntry(text: "invalidatedold witness two", verse: 2, strongToken: "H0430"),
            ]
        )
        try await service.createIndex(source: source)
        let sourceIdentity = source.searchIndexSourceIdentity

        let pinnedTextRead = Task.detached {
            try service.search(
                query: "invalidatedold",
                sourceIdentity: sourceIdentity,
                wordMode: .allWords
            )
        }
        let pinnedStrongsRead = Task.detached {
            try service.searchStrongs(
                canonicalTokens: ["H0430"],
                sourceIdentity: sourceIdentity
            )
        }
        XCTAssertTrue(
            readBarrier.waitForReaders(timeout: .now() + Self.synchronizationTimeout)
        )

        SwordModuleStore.notifyModulesDidChange(center: notificationCenter)
        readBarrier.releaseReaders()

        do {
            _ = try await pinnedTextRead.value
            XCTFail("Expected the invalidation epoch to reject the pinned text snapshot")
        } catch {
            XCTAssertEqual(
                error as? SearchIndexError,
                .indexUnavailable(moduleName: "INVALIDATE")
            )
        }
        do {
            _ = try await pinnedStrongsRead.value
            XCTFail("Expected the invalidation epoch to reject the pinned Strong's snapshot")
        } catch {
            XCTAssertEqual(
                error as? SearchIndexError,
                .indexUnavailable(moduleName: "INVALIDATE")
            )
        }
        XCTAssertFalse(service.hasIndex(for: sourceIdentity))
        XCTAssertFalse(service.hasStrongsIndex(for: sourceIdentity))
    }

    /**
     Verifies a source retained behind an earlier build cannot adopt a later store generation.

     - Setup: Captures authorizations for modules A and B before pausing A inside its transaction,
       mirroring Search's serial multi-module queue. After A completes, a module-store replacement is
       published; the queued old B object and a freshly resolved B object intentionally have identical
       metadata fingerprints but different text and Strong's rows.
     - Expected result: Old B's pre-replacement authorization throws `indexUnavailable` without
       publishing rows. A newly captured authorization lets fresh B build, with only its replacement
       text and Strong's token searchable.
     - Failure meaning: A retained source can be blessed with the replacement's durable generation,
       defeating global invalidation and diverging from Android's current-book index admission.
     - Side effects: Coordinates one writer pause without sleeps, advances one isolated store
       generation, and removes the generated Search database afterward.
     */
    func testQueuedSourceAuthorizationRejectsSameIdentitySourceAfterStoreReplacement() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-queued-source-authorization-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let notificationCenter = NotificationCenter()
        let reachedFirstBuildPause = DispatchSemaphore(value: 0)
        let releaseFirstBuildPause = DispatchSemaphore(value: 0)
        defer {
            DispatchQueue.global(qos: .userInitiated).async {
                releaseFirstBuildPause.signal()
            }
        }
        let service = SearchIndexService(
            databasePath: databaseURL.path,
            notificationCenter: notificationCenter
        )
        let firstSource = FixtureBibleSearchSource(
            name: "QUEUEA",
            description: "First queued fixture",
            entries: [fixtureEntry(text: "firstqueue witness", verse: 1)],
            pauseAfterEntry: 0,
            reachedPause: reachedFirstBuildPause,
            releasePause: releaseFirstBuildPause
        )
        let staleQueuedSource = FixtureBibleSearchSource(
            name: "QUEUEB",
            description: "Second queued fixture",
            entries: [
                fixtureEntry(text: "stalequeued witness", verse: 1, strongToken: "H0001"),
            ]
        )
        let freshReplacementSource = FixtureBibleSearchSource(
            name: "QUEUEB",
            description: "Second queued fixture",
            entries: [
                fixtureEntry(text: "freshreplacement witness", verse: 2, strongToken: "H0002"),
            ]
        )
        XCTAssertEqual(
            staleQueuedSource.searchIndexSourceIdentity,
            freshReplacementSource.searchIndexSourceIdentity,
            "The regression must not rely on source metadata changing across replacement"
        )

        let queuedCaptures = try XCTUnwrap(
            service.captureIndexCreationSources(named: ["QUEUEA", "QUEUEB"]) {
                [
                    ("QUEUEA", firstSource),
                    ("QUEUEB", staleQueuedSource),
                ]
            }
        )
        XCTAssertEqual(queuedCaptures.map(\.name), ["QUEUEA", "QUEUEB"])
        let firstCapture = queuedCaptures[0]
        let staleQueuedCapture = queuedCaptures[1]
        let firstBuild = Task {
            try await service.createIndex(
                source: firstCapture.source,
                authorization: firstCapture.authorization
            )
        }
        XCTAssertEqual(
            reachedFirstBuildPause.wait(timeout: .now() + Self.synchronizationTimeout),
            .success
        )
        DispatchQueue.global(qos: .userInitiated).async {
            releaseFirstBuildPause.signal()
        }
        try await firstBuild.value

        SwordModuleStore.notifyModulesDidChange(center: notificationCenter)
        do {
            try await service.createIndex(
                source: staleQueuedCapture.source,
                authorization: staleQueuedCapture.authorization
            )
            XCTFail("Expected the pre-replacement queued source authorization to be rejected")
        } catch {
            XCTAssertEqual(error as? SearchIndexError, .indexUnavailable(moduleName: "QUEUEB"))
        }
        XCTAssertFalse(service.hasIndex(for: staleQueuedSource.searchIndexSourceIdentity))
        XCTAssertEqual(try indexedRowCount(at: databaseURL, moduleName: "QUEUEB"), 0)

        let freshCapture = try XCTUnwrap(
            service.captureIndexCreationSource(named: "QUEUEB") {
                freshReplacementSource
            }
        )
        try await service.createIndex(
            source: freshCapture.source,
            authorization: freshCapture.authorization
        )
        XCTAssertEqual(
            try service.search(
                query: "freshreplacement",
                sourceIdentity: freshReplacementSource.searchIndexSourceIdentity,
                wordMode: .allWords
            ).hits.count,
            1
        )
        XCTAssertTrue(
            try service.search(
                query: "stalequeued",
                sourceIdentity: freshReplacementSource.searchIndexSourceIdentity,
                wordMode: .allWords
            ).hits.isEmpty
        )
        XCTAssertEqual(
            try service.searchStrongs(
                canonicalTokens: ["H0002"],
                sourceIdentity: freshReplacementSource.searchIndexSourceIdentity
            ).hits.count,
            1
        )
        XCTAssertTrue(
            try service.searchStrongs(
                canonicalTokens: ["H0001"],
                sourceIdentity: freshReplacementSource.searchIndexSourceIdentity
            ).hits.isEmpty
        )
    }

    /**
     Verifies source discovery and authorization cannot straddle an installed-module replacement.

     - Setup: The service captures its pre-resolution epoch, the resolver returns an old native-style
       object, and the resolver synchronously publishes a same-identity replacement before returning.
       A fresh resolver then returns replacement content with identical metadata fingerprint.
     - Expected result: The old object never receives an authorization and publishes no rows; a fresh
       resolution/authorization handshake builds only replacement text and Strong's content.
     - Failure meaning: A same-version SWORD reinstall can complete between Search resolution and token
       capture, allowing the stale native handle to be blessed by the new durable generation.
     - Side effects: Advances one isolated store generation and removes the generated database.
     */
    func testSourceResolutionAuthorizationRejectsReplacementBeforeTokenCapture() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-source-resolution-authorization-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let notificationCenter = NotificationCenter()
        let service = SearchIndexService(
            databasePath: databaseURL.path,
            notificationCenter: notificationCenter
        )
        let staleResolvedSource = FixtureBibleSearchSource(
            name: "RESOLVE",
            description: "Resolution authorization fixture",
            entries: [
                fixtureEntry(text: "resolvedstale witness", verse: 1, strongToken: "H0001"),
            ]
        )
        let freshResolvedSource = FixtureBibleSearchSource(
            name: "RESOLVE",
            description: "Resolution authorization fixture",
            entries: [
                fixtureEntry(text: "resolvedfresh witness", verse: 2, strongToken: "H0002"),
            ]
        )
        XCTAssertEqual(
            staleResolvedSource.searchIndexSourceIdentity,
            freshResolvedSource.searchIndexSourceIdentity
        )

        do {
            _ = try service.captureIndexCreationSource(named: "RESOLVE") {
                let resolvedBeforeReplacement = staleResolvedSource
                SwordModuleStore.notifyModulesDidChange(center: notificationCenter)
                return resolvedBeforeReplacement
            }
            XCTFail("Expected replacement during source resolution to reject authorization")
        } catch {
            XCTAssertEqual(error as? SearchIndexError, .indexUnavailable(moduleName: "RESOLVE"))
        }
        XCTAssertEqual(try indexedRowCount(at: databaseURL, moduleName: "RESOLVE"), 0)

        let freshCapture = try XCTUnwrap(
            service.captureIndexCreationSource(named: "RESOLVE") {
                freshResolvedSource
            }
        )
        try await service.createIndex(
            source: freshCapture.source,
            authorization: freshCapture.authorization
        )
        XCTAssertEqual(
            try service.search(
                query: "resolvedfresh",
                sourceIdentity: freshResolvedSource.searchIndexSourceIdentity,
                wordMode: .allWords
            ).hits.count,
            1
        )
        XCTAssertTrue(
            try service.search(
                query: "resolvedstale",
                sourceIdentity: freshResolvedSource.searchIndexSourceIdentity,
                wordMode: .allWords
            ).hits.isEmpty
        )
        XCTAssertEqual(
            try service.searchStrongs(
                canonicalTokens: ["H0002"],
                sourceIdentity: freshResolvedSource.searchIndexSourceIdentity
            ).hits.count,
            1
        )
        XCTAssertTrue(
            try service.searchStrongs(
                canonicalTokens: ["H0001"],
                sourceIdentity: freshResolvedSource.searchIndexSourceIdentity
            ).hits.isEmpty
        )
    }

    /**
     Verifies multi-module readiness cannot combine results from two store generations.

     - Setup: Builds ready modules A and B, then pauses the aggregate immediately after A is observed
       ready. A synchronous module-store notification advances the generation before B is evaluated.
     - Expected result: The aggregate returns both identities as needing index, including A even though
       its individual old-generation check had already succeeded.
     - Failure meaning: Search can omit newly stale A, rebuild only B, declare the selection ready, and
       expose A as a partial-module failure instead of preserving Android's all-selected-books gate.
     - Side effects: Uses semaphores rather than sleeps, advances one isolated store generation, and
       removes the generated database after the detached readiness task completes.
     */
    func testAggregateReadinessFailsClosedWhenStoreGenerationChangesBetweenModules() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-aggregate-readiness-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let notificationCenter = NotificationCenter()
        let reachedFirstCandidate = DispatchSemaphore(value: 0)
        let releaseAggregate = DispatchSemaphore(value: 0)
        defer {
            DispatchQueue.global(qos: .userInitiated).async {
                releaseAggregate.signal()
            }
        }
        let service = SearchIndexService(
            databasePath: databaseURL.path,
            notificationCenter: notificationCenter,
            aggregateReadinessCheckpoint: { moduleName in
                guard moduleName == "AGGREGATEA" else { return }
                reachedFirstCandidate.signal()
                releaseAggregate.wait()
            }
        )
        let firstSource = FixtureBibleSearchSource(
            name: "AGGREGATEA",
            description: "First aggregate fixture",
            entries: [fixtureEntry(text: "aggregatefirst witness", verse: 1)]
        )
        let secondSource = FixtureBibleSearchSource(
            name: "AGGREGATEB",
            description: "Second aggregate fixture",
            entries: [fixtureEntry(text: "aggregatesecond witness", verse: 1)]
        )
        try await service.createIndex(source: firstSource)
        try await service.createIndex(source: secondSource)
        let identities = [
            firstSource.searchIndexSourceIdentity,
            secondSource.searchIndexSourceIdentity,
        ]

        let aggregate = Task.detached {
            service.modulesNeedingIndex(from: identities)
        }
        XCTAssertEqual(
            reachedFirstCandidate.wait(timeout: .now() + Self.synchronizationTimeout),
            .success
        )
        SwordModuleStore.notifyModulesDidChange(center: notificationCenter)
        DispatchQueue.global(qos: .userInitiated).async {
            releaseAggregate.signal()
        }

        let missingAfterMutation = await aggregate.value
        XCTAssertEqual(missingAfterMutation, identities)
    }

    /**
     Verifies text and Strong's multi-module aggregates discard old buckets after store mutation.

     - Setup: Builds matching A/B indexes and pauses each aggregate after A's successful committed
       snapshot. A synchronous module-store notification completes before B runs; indexes are rebuilt
       between the text and Strong's rounds so both query paths exercise the same deterministic seam.
     - Expected result: Each aggregate throws `indexUnavailable` for the complete selection rather
       than returning old A as partial success with B as a failure.
     - Failure meaning: Search can publish content from a replaced or uninstalled A after the module
       mutation has completed, despite each individual query having a valid local snapshot.
     - Side effects: Advances two isolated store generations, coordinates both rounds with reusable
       semaphores and no sleeps, and removes the generated database afterward.
     */
    func testMultiModuleTextAndStrongsDiscardResultsWhenStoreChangesBetweenModules() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-aggregate-query-epoch-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let notificationCenter = NotificationCenter()
        let reachedFirstModule = DispatchSemaphore(value: 0)
        let releaseAggregate = DispatchSemaphore(value: 0)
        defer {
            DispatchQueue.global(qos: .userInitiated).async {
                releaseAggregate.signal()
                releaseAggregate.signal()
            }
        }
        let service = SearchIndexService(
            databasePath: databaseURL.path,
            notificationCenter: notificationCenter,
            aggregateSearchCheckpoint: { moduleName in
                guard moduleName == "MULTIA" else { return }
                reachedFirstModule.signal()
                releaseAggregate.wait()
            }
        )
        let firstSource = FixtureBibleSearchSource(
            name: "MULTIA",
            description: "First aggregate query fixture",
            entries: [
                fixtureEntry(text: "aggregatequery witness", verse: 1, strongToken: "H0430"),
            ]
        )
        let secondSource = FixtureBibleSearchSource(
            name: "MULTIB",
            description: "Second aggregate query fixture",
            entries: [
                fixtureEntry(text: "aggregatequery witness", verse: 1, strongToken: "H0430"),
            ]
        )
        let identities = [
            firstSource.searchIndexSourceIdentity,
            secondSource.searchIndexSourceIdentity,
        ]
        try await service.createIndex(source: firstSource)
        try await service.createIndex(source: secondSource)

        let textAggregate = Task.detached {
            try service.searchMultiple(
                query: "aggregatequery",
                sourceIdentities: identities,
                wordMode: .allWords
            )
        }
        XCTAssertEqual(
            reachedFirstModule.wait(timeout: .now() + Self.synchronizationTimeout),
            .success
        )
        SwordModuleStore.notifyModulesDidChange(center: notificationCenter)
        DispatchQueue.global(qos: .userInitiated).async {
            releaseAggregate.signal()
        }
        do {
            _ = try await textAggregate.value
            XCTFail("Expected the text aggregate to discard its old-generation module")
        } catch {
            XCTAssertEqual(error as? SearchIndexError, .indexUnavailable(moduleName: "MULTIA"))
        }

        try await service.createIndex(source: firstSource)
        try await service.createIndex(source: secondSource)
        let strongsAggregate = Task.detached {
            try service.searchStrongsMultiple(
                canonicalTokens: ["H0430"],
                sourceIdentities: identities
            )
        }
        XCTAssertEqual(
            reachedFirstModule.wait(timeout: .now() + Self.synchronizationTimeout),
            .success
        )
        SwordModuleStore.notifyModulesDidChange(center: notificationCenter)
        DispatchQueue.global(qos: .userInitiated).async {
            releaseAggregate.signal()
        }
        do {
            _ = try await strongsAggregate.value
            XCTFail("Expected the Strong's aggregate to discard its old-generation module")
        } catch {
            XCTAssertEqual(error as? SearchIndexError, .indexUnavailable(moduleName: "MULTIA"))
        }
    }

    /**
     Verifies failed build verification rolls back before corrupt rows can become published state.

     - Setup: Commits an original text/Strong index, then installs one trigger that removes a staged FTS
       row after replacement metadata is inserted and a second trigger that would abort legacy cleanup.
     - Expected result: Verification fails inside the build transaction, so rollback restores the entire
       original generation without invoking fallible post-commit cleanup.
     - Failure meaning: A corrupt replacement can commit, its cleanup can fail, and readiness metadata
       can authorize incomplete staged text or Strong's rows instead of the prior durable generation.
     - Side effects: Adds test-only triggers/state to one isolated generated-index database, then removes it.
     */
    func testVerificationFailureRollsBackBeforePublicationWhenCleanupWouldFail() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-precommit-verification-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let service = SearchIndexService(databasePath: databaseURL.path)
        let original = FixtureBibleSearchSource(
            name: "VERIFYFAIL",
            description: "Verification fixture",
            entries: [
                fixtureEntry(text: "verifiedold witness one", verse: 1, strongToken: "H0430"),
                fixtureEntry(text: "verifiedold witness two", verse: 2, strongToken: "H0430"),
            ]
        )
        let corruptReplacement = FixtureBibleSearchSource(
            name: "VERIFYFAIL",
            description: "Verification fixture",
            entries: [
                fixtureEntry(text: "corruptnew witness one", verse: 3, strongToken: "H0001"),
                fixtureEntry(text: "corruptnew witness two", verse: 4, strongToken: "H0001"),
            ]
        )
        try await service.createIndex(source: original)
        let originalIdentity = original.searchIndexSourceIdentity
        try await service.performIndexMutationForTesting { db in
            guard sqlite3_exec(
                db,
                """
                CREATE TABLE forced_cleanup_failure_state (armed INTEGER NOT NULL);
                INSERT INTO forced_cleanup_failure_state VALUES (0);
                CREATE TRIGGER force_index_verification_failure
                AFTER INSERT ON indexed_modules
                WHEN NEW.module_name = 'VERIFYFAIL'
                BEGIN
                    DELETE FROM verse_fts
                    WHERE rowid = (
                        SELECT rowid FROM verse_fts
                        WHERE module_name = NEW.module_name
                        ORDER BY rowid
                        LIMIT 1
                    );
                    UPDATE forced_cleanup_failure_state SET armed = 1;
                END;
                CREATE TRIGGER fail_legacy_verification_cleanup
                BEFORE DELETE ON indexed_modules
                WHEN OLD.module_name = 'VERIFYFAIL'
                     AND (SELECT armed FROM forced_cleanup_failure_state LIMIT 1) = 1
                BEGIN
                    SELECT RAISE(ABORT, 'forced post-commit cleanup failure');
                END;
                """,
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw SQLiteBibleSearchFixtureError.writeFailed
            }
        }

        do {
            try await service.createIndex(source: corruptReplacement)
            XCTFail("Expected pre-commit row-count verification to reject the replacement")
        } catch {
            XCTAssertEqual(
                error as? SearchIndexError,
                .indexVerificationFailed(moduleName: "VERIFYFAIL")
            )
        }

        XCTAssertTrue(service.hasIndex(for: originalIdentity))
        XCTAssertTrue(service.hasStrongsIndex(for: originalIdentity))
        XCTAssertEqual(
            try service.search(
                query: "verifiedold",
                sourceIdentity: originalIdentity,
                wordMode: .allWords
            ).hits.count,
            2
        )
        XCTAssertEqual(
            try service.searchStrongs(
                canonicalTokens: ["H0430"],
                sourceIdentity: originalIdentity
            ).hits.count,
            2
        )
        XCTAssertTrue(
            try service.search(
                query: "corruptnew",
                sourceIdentity: originalIdentity,
                wordMode: .allWords
            ).hits.isEmpty
        )
        XCTAssertTrue(
            try service.searchStrongs(
                canonicalTokens: ["H0001"],
                sourceIdentity: originalIdentity
            ).hits.isEmpty
        )
    }

    /**
     Verifies a failed standalone deletion restores text, Strong's, and readiness metadata together.

     - Setup: Commits one text/Strong index, then installs a deterministic SQLite trigger that aborts
       the final metadata delete after the earlier generated-facet statements have executed.
     - Expected result: The delete transaction rolls back, both searches and readiness remain complete,
       and a later deletion succeeds after removing the trigger.
     - Failure meaning: An I/O/schema failure can publish metadata for an index whose text or lexical
       rows were already removed, causing false readiness and silent empty Search results.
     - Side effects: Mutates and removes one isolated generated-index database and temporary trigger.
     */
    func testDeleteFailureRollsBackTextStrongsAndMetadataAtomically() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-atomic-delete-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let service = SearchIndexService(databasePath: databaseURL.path)
        let source = FixtureBibleSearchSource(
            name: "DELETEFAIL",
            description: "Atomic deletion fixture",
            entries: [
                fixtureEntry(text: "durabledelete witness", verse: 1, strongToken: "H0430"),
            ]
        )
        try await service.createIndex(source: source)
        let sourceIdentity = source.searchIndexSourceIdentity
        try await service.performIndexMutationForTesting { db in
            guard sqlite3_exec(
                db,
                """
                CREATE TRIGGER fail_delete_metadata
                BEFORE DELETE ON indexed_modules
                WHEN OLD.module_name = 'DELETEFAIL'
                BEGIN
                    SELECT RAISE(ABORT, 'forced metadata delete failure');
                END;
                """,
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw SQLiteBibleSearchFixtureError.writeFailed
            }
        }

        await service.deleteIndex(for: "DELETEFAIL")

        XCTAssertTrue(service.hasIndex(for: sourceIdentity))
        XCTAssertTrue(service.hasStrongsIndex(for: sourceIdentity))
        XCTAssertEqual(
            try service.search(
                query: "durabledelete",
                sourceIdentity: sourceIdentity,
                wordMode: .allWords
            ).hits.count,
            1
        )
        XCTAssertEqual(
            try service.searchStrongs(
                canonicalTokens: ["H0430"],
                sourceIdentity: sourceIdentity
            ).hits.count,
            1
        )

        try await service.performIndexMutationForTesting { db in
            guard sqlite3_exec(
                db,
                "DROP TRIGGER fail_delete_metadata",
                nil,
                nil,
                nil
            ) == SQLITE_OK else {
                throw SQLiteBibleSearchFixtureError.writeFailed
            }
        }
        await service.deleteIndex(for: "DELETEFAIL")
        XCTAssertFalse(service.hasIndex(for: sourceIdentity))
        XCTAssertFalse(service.hasStrongsIndex(for: sourceIdentity))
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
        XCTAssertEqual(
            reachedPause.wait(timeout: .now() + Self.synchronizationTimeout),
            .success
        )

        task.cancel()
        DispatchQueue.global(qos: .userInitiated).async {
            releasePause.signal()
        }
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

    /**
     Returns one deterministic canonical Search entry for transaction-control sources.

     - Parameters:
       - text: Canonical analyzer and visible preview text.
       - verse: Positive Genesis verse number used for identity and stable ordering.
       - strongToken: Optional canonical lemma embedded in both lexical markup projections.
     - Returns: One immutable backend-neutral row with optional Strong's markup.
     - Side effects: None.
     - Failure modes: None; test callers provide valid verse/token values.
     */
    private func fixtureEntry(
        text: String,
        verse: Int,
        strongToken: String? = nil
    ) -> BibleSearchIndexEntry {
        let markup = strongToken.map { "<w lemma=\"strong:\($0)\">\(text)</w>" } ?? text
        return BibleSearchIndexEntry(
            displayKey: "Genesis 1:\(verse)",
            indexText: text,
            previewText: text,
            sourceMarkup: markup,
            taggedText: markup,
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

/**
 Deterministically pauses a bounded number of Search reads after metadata establishes their snapshot.

 The helper models reads admitted while Android still reports `IndexStatus.DONE`. Semaphores expose an
 exact writer-start boundary without sleeps, while a lock ensures concurrent text/Strong checkpoints
 consume distinct slots and later verification reads pass through normally.
 */
private final class SearchReadAuthorizationBarrier: @unchecked Sendable {
    /// Exact module whose first bounded readers participate in the concurrency barrier.
    private let moduleName: String

    /// Number of readers the test must pause before starting its writer.
    private let expectedReaders: Int

    /// Protects remaining-reader and one-shot-release state across detached Search tasks.
    private let lock = NSLock()

    /// Signals once for every reader whose committed snapshot has been established.
    private let reachedCheckpoint = DispatchSemaphore(value: 0)

    /// Releases each paused reader after the writer reaches its deterministic partial state.
    private let continueReading = DispatchSemaphore(value: 0)

    /// Slots still eligible to pause; later reads must not inherit the test barrier.
    private var remainingReaders: Int

    /// Prevents cleanup and the normal test path from double-signaling release tokens.
    private var readersReleased = false

    /**
     Creates one module-scoped, bounded authorization barrier.

     - Parameters:
       - moduleName: Exact Search index owner to pause.
       - expectedReaders: Positive number of initial logical reads coordinated by the test.
     - Side effects: Allocates in-process synchronization primitives only.
     - Failure modes: A non-positive count pauses no readers; production tests pass a positive value.
     */
    init(moduleName: String, expectedReaders: Int) {
        self.moduleName = moduleName
        self.expectedReaders = max(expectedReaders, 0)
        remainingReaders = max(expectedReaders, 0)
    }

    /**
     Pauses one eligible target-module read after signaling that its snapshot is established.

     - Parameter moduleName: Module authorized by the production read path.
     - Side effects: Atomically consumes one slot, signals the test thread, then waits for release.
     - Failure modes: Non-target and excess calls return immediately; the owning test always releases
       paused readers through normal flow or `defer` cleanup.
     - Important: The callback runs on independent Search tasks and never holds `lock` while waiting.
     */
    func checkpoint(moduleName: String) {
        guard moduleName == self.moduleName else { return }
        lock.lock()
        let shouldPause = remainingReaders > 0
        if shouldPause { remainingReaders -= 1 }
        lock.unlock()
        guard shouldPause else { return }
        reachedCheckpoint.signal()
        continueReading.wait()
    }

    /**
     Waits until every expected reader has reached the established-snapshot checkpoint.

     - Parameter timeout: Shared absolute deadline for deterministic test failure.
     - Returns: `true` only when all expected readers arrive before the deadline.
     - Side effects: Consumes one checkpoint signal per expected reader.
     - Failure modes: Returns false on the first timeout; it never sleeps or retries beyond the bound.
     */
    func waitForReaders(timeout: DispatchTime) -> Bool {
        for _ in 0..<expectedReaders {
            guard reachedCheckpoint.wait(timeout: timeout) == .success else { return false }
        }
        return true
    }

    /**
     Releases every bounded reader exactly once on either normal flow or test cleanup.

     - Side effects: Signals one continuation token per expected reader.
     - Failure modes: None; repeated calls are idempotent under `lock`.
     */
    func releaseReaders() {
        lock.lock()
        guard !readersReleased else {
            lock.unlock()
            return
        }
        readersReleased = true
        lock.unlock()
        for _ in 0..<expectedReaders {
            continueReading.signal()
        }
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

/**
 Delegates fixture streaming while exposing a caller-supplied installed source identity.

 Exact-identity tests use the wrapper to hold version/fingerprint constant across Java-distinct
 module initials, ensuring authorization and grouping assertions exercise module-name semantics
 rather than passing because the production metadata hash also changed.
 */
private final class ExactIdentityBibleSearchSource: BibleSearchIndexSource {
    /// Underlying deterministic source that owns metadata, progress, and row streaming.
    private let base: any BibleSearchIndexSource

    /// Caller-supplied identity whose module initials must match `base` exactly in valid fixtures.
    let searchIndexSourceIdentity: SearchIndexSourceIdentity

    /// Installed metadata delegated without normalization.
    var searchIndexModuleInfo: ModuleInfo { base.searchIndexModuleInfo }

    /// Backend revision delegated for protocol completeness; the explicit identity remains authoritative.
    var searchIndexStorageRevision: String { base.searchIndexStorageRevision }

    /// Progress denominator delegated to the bounded base source.
    var searchIndexProgressTotal: Int { base.searchIndexProgressTotal }

    /// Empty-text indexing contract delegated to the base source.
    var searchIndexIncludesEmptyIndexText: Bool { base.searchIndexIncludesEmptyIndexText }

    /**
     Creates a streaming wrapper with an explicit readiness identity.

     - Parameters:
       - base: Deterministic source providing module metadata and streamed rows.
       - sourceIdentity: Exact generation returned to authorization/readiness code.
     - Side effects: Retains `base`; performs no I/O and does not read source rows.
     - Failure modes: Mismatched identity/module values are intentionally retained so negative
       authorization tests can prove production code rejects them.
     */
    init(
        base: any BibleSearchIndexSource,
        sourceIdentity: SearchIndexSourceIdentity
    ) {
        self.base = base
        self.searchIndexSourceIdentity = sourceIdentity
    }

    /**
     Streams the base fixture unchanged through the production source contract.

     - Parameter consume: Synchronous generated-row consumer supplied by `SearchIndexService`.
     - Side effects: Delegates all base-source reads, pauses, and failure injection.
     - Throws: Re-throws base-source and consumer errors without translation.
     */
    func forEachSearchIndexEntry(
        _ consume: (BibleSearchIndexEntry) throws -> Bool
    ) throws {
        try base.forEachSearchIndexEntry(consume)
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

    /// A deterministic generated-index mutation or failure-injection statement failed.
    case writeFailed

    /// The checked-in KJV fixture could not be located from the test source path.
    case repositoryFixtureMissing
}
