import Foundation
import SQLite3
import XCTest
@testable import BibleCore
import SwordKit

/** Exercises analyzer storage and multi-source failure behavior through the production index service. */
final class SearchIndexEndToEndParityTests: XCTestCase {
    /**
     Retains a lexical-only JSword document whose analyzed body is empty.

     - Setup: Builds one default-policy source with empty index/preview text and a Strong's lemma in
       source markup.
     - Expected result: Exact Strong's search returns the verse with an empty complete preview.
     - Failure meaning: iOS discarded the row before independently extracting JSword's lexical field.
     - Side effects: Creates and removes one isolated generated-index database.
     */
    func testStrongsOnlyEntrySurvivesEmptyBodyIndexPolicy() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-strongs-only-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let service = SearchIndexService(databasePath: databaseURL.path)
        let source = InMemorySearchIndexSource(
            moduleName: "LEXICALONLY",
            language: "en",
            storageRevision: "lexical-only",
            visibleText: "",
            strongToken: "H0430"
        )

        try await service.createIndex(source: source)

        XCTAssertTrue(service.hasIndex(for: source.searchIndexSourceIdentity))
        XCTAssertTrue(service.hasStrongsIndex(for: source.searchIndexSourceIdentity))
        let hits = try service.searchStrongs(
            canonicalTokens: ["H0430"],
            sourceIdentity: source.searchIndexSourceIdentity
        ).hits
        XCTAssertEqual(hits.map(\.key), ["Genesis 1:1"])
        XCTAssertEqual(hits.map(\.snippet), [""])
    }

    /**
     Preserves the complete projection stored for Search result presentation.

     - Setup: Indexes one preview longer than the former 240-character service truncation boundary.
     - Expected result: An exact-generation text query returns every persisted character unchanged
       and marks only the analyzer-matched query token for emphasis.
     - Failure meaning: Search storage/query code is truncating Android-visible content or losing
       the analyzer-owned presentation range used by result rows.
     - Side effects: Creates and removes one isolated generated-index database.
     */
    func testSearchHitReturnsCompletePreviewBeyondFormerCharacterLimit() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-full-preview-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let service = SearchIndexService(databasePath: databaseURL.path)
        let fullPreview = "searchneedle " + String(repeating: "complete preview segment ", count: 20)
        let source = InMemorySearchIndexSource(
            moduleName: "FULLPREVIEW",
            language: "en",
            storageRevision: "full-preview",
            visibleText: fullPreview
        )

        XCTAssertGreaterThan(fullPreview.count, 240)
        try await service.createIndex(source: source)

        let hit = try XCTUnwrap(service.search(
            query: "searchneedle",
            sourceIdentity: source.searchIndexSourceIdentity,
            wordMode: .anyWord
        ).hits.first)
        XCTAssertEqual(hit.snippet, fullPreview)
        XCTAssertEqual(
            hit.snippetSegments.filter(\.isEmphasized).map(\.text),
            ["searchneedle"]
        )
    }

    /**
     Verifies structured Strong's ranges survive the complete index publication and query path.

     - Setup: Builds one real generated index row whose H0430 lemma owns only `God` in a longer
       annotation-free preview.
     - Expected result: The Strong query returns the full preview and emphasizes exactly `God`.
     - Failure meaning: Source-backed lexical ranges were lost during normalization, SQLite
       publication, grouped query decoding, or final hit segmentation.
     - Side effects: Creates and removes one isolated generated-index database.
     */
    func testStrongsHighlightRangeSurvivesIndexPublication() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-strong-highlight-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let service = SearchIndexService(databasePath: databaseURL.path)
        let preview = "In the beginning God created"
        let source = InMemorySearchIndexSource(
            moduleName: "LEXICALRANGE",
            language: "en",
            storageRevision: "lexical-range",
            visibleText: preview,
            strongToken: "H0430",
            strongHighlightText: "God"
        )

        try await service.createIndex(source: source)

        let hit = try XCTUnwrap(service.searchStrongs(
            canonicalTokens: ["H0430"],
            sourceIdentity: source.searchIndexSourceIdentity
        ).hits.first)
        XCTAssertEqual(hit.snippet, preview)
        XCTAssertEqual(
            hit.snippetSegments.filter(\.isEmphasized).map(\.text),
            ["God"]
        )
    }

    /**
     Verifies the production default identity changes for version and backend storage generations.

     - Setup: Creates same-initials in-memory sources that differ only by version or storage revision.
     - Expected result: Every generation has a distinct 64-digit SHA-256 fingerprint while preserving
       its exact declared version.
     - Failure meaning: Same-initials replacement metadata can authorize rows from an older source.
     - Side effects: None; the sources do not open external storage.
     */
    func testDefaultSourceIdentityChangesWithVersionAndStorageRevision() {
        let original = InMemorySearchIndexSource(
            moduleName: "IDENTITY",
            language: "en",
            version: "1.0",
            storageRevision: "storage-a",
            visibleText: "original"
        )
        let upgraded = InMemorySearchIndexSource(
            moduleName: "IDENTITY",
            language: "en",
            version: "2.0",
            storageRevision: "storage-a",
            visibleText: "upgraded"
        )
        let replaced = InMemorySearchIndexSource(
            moduleName: "IDENTITY",
            language: "en",
            version: "1.0",
            storageRevision: "storage-b",
            visibleText: "replaced"
        )

        XCTAssertEqual(original.searchIndexSourceIdentity.version, "1.0")
        XCTAssertEqual(original.searchIndexSourceIdentity.fingerprint.count, 64)
        XCTAssertNotEqual(
            original.searchIndexSourceIdentity.fingerprint,
            upgraded.searchIndexSourceIdentity.fingerprint
        )
        XCTAssertNotEqual(
            original.searchIndexSourceIdentity.fingerprint,
            replaced.searchIndexSourceIdentity.fingerprint
        )
    }

    /**
     Proves FTS receives opaque complete analyzer tokens without changing Search semantics.

     - Setup: Builds real generated indexes for Czech and Greek oracle text through `createIndex`.
     - Expected result: Czech diacritics remain significant; phrase, Boolean, and prefix queries still
       match; each punctuation-bearing Classic token matches intact while split punctuation does not.
     - Failure meaning: SQLite has re-tokenized analyzer output or query lowering no longer mirrors the
       indexed representation.
     - Side effects: Creates and removes one isolated generated-index database.
     */
    func testOpaqueFTSRepresentationPreservesCzechAndClassicPunctuationSemantics() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-token-boundaries-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let service = SearchIndexService(databasePath: databaseURL.path)
        let czech = InMemorySearchIndexSource(
            moduleName: "CZECH",
            language: "cs",
            storageRevision: "czech-oracle",
            visibleText: "PŘÍLIŠ žluťoučký kůň"
        )
        let greek = InMemorySearchIndexSource(
            moduleName: "GREEK",
            language: "el",
            storageRevision: "greek-classic-oracle",
            visibleText: "ΘΕΟΣ U.S.A. O'Reilly test@example.com 3.14 中文"
        )
        let czechToken = "příliš"
        XCTAssertEqual(SearchIndexTokenCodec.decode(SearchIndexTokenCodec.encode(czechToken)), czechToken)
        XCTAssertTrue(
            SearchIndexTokenCodec.encode(czechToken)
                .hasPrefix(SearchIndexTokenCodec.encode("příl"))
        )

        try await service.createIndex(source: czech)
        try await service.createIndex(source: greek)

        XCTAssertEqual(try hitCount("příliš", in: czech, using: service), 1)
        XCTAssertEqual(try hitCount("prilis", in: czech, using: service), 0)
        XCTAssertEqual(
            try hitCount("příliš žluťoučký", in: czech, wordMode: .phrase, using: service),
            1
        )
        XCTAssertEqual(try hitCount("příliš AND kůň", in: czech, using: service), 1)
        XCTAssertEqual(try hitCount("příliš NOT kůň", in: czech, using: service), 0)
        XCTAssertEqual(try hitCount("příl*", in: czech, using: service), 1)

        for token in ["U.S.A.", "O'Reilly", "test@example.com", "3.14"] {
            XCTAssertEqual(
                try hitCount(token, in: greek, using: service),
                1,
                "Expected the complete Classic analyzer token '\(token)' to survive FTS storage."
            )
        }
        XCTAssertEqual(
            try hitCount("U S A", in: greek, wordMode: .allWords, using: service),
            0,
            "Split punctuation must not alias the single U.S.A. analyzer token."
        )
    }

    /**
     Verifies text and Strong's grouped searches retain good modules and report bad ones explicitly.

     - Setup: Builds two real module indexes, then corrupts only one module's durable source identity.
     - Expected result: Both grouped query paths return the healthy hit plus an ordered failure for the
       stale module; selecting only the stale module preserves the existing throwing contract.
     - Failure meaning: One module failure can erase successful translations or disappear from the
       grouped result contract.
     - Side effects: Creates, mutates, and removes one isolated generated-index database.
     */
    func testGroupedSearchRetainsSuccessfulModulesAndReportsPerModuleFailures() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-partial-failure-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let service = SearchIndexService(databasePath: databaseURL.path)
        let healthy = InMemorySearchIndexSource(
            moduleName: "HEALTHY",
            language: "en",
            storageRevision: "healthy",
            visibleText: "shared searchable text",
            strongToken: "H0430"
        )
        let stale = InMemorySearchIndexSource(
            moduleName: "STALE",
            language: "en",
            storageRevision: "stale",
            visibleText: "shared searchable text",
            strongToken: "H0430"
        )
        try await service.createIndex(source: healthy)
        try await service.createIndex(source: stale)

        try await service.performIndexMutationForTesting { db in
            let sql = """
                UPDATE indexed_modules
                SET source_fingerprint = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
                WHERE module_name = 'STALE'
            """
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "SQLite update failed"
                throw NSError(
                    domain: "SearchIndexPartialFailureFixture",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
        }

        let identities = [healthy.searchIndexSourceIdentity, stale.searchIndexSourceIdentity]
        let textResults = try service.searchMultiple(
            query: "shared",
            sourceIdentities: identities,
            wordMode: .allWords
        )
        XCTAssertEqual(textResults.moduleCounts, [SearchModuleCount(moduleName: "HEALTHY", count: 1)])
        XCTAssertEqual(textResults.groups.flatMap(\.matches).map(\.moduleName), ["HEALTHY"])
        XCTAssertEqual(textResults.moduleFailures.map(\.moduleName), ["STALE"])
        XCTAssertFalse(try XCTUnwrap(textResults.moduleFailures.first).message.isEmpty)

        let strongsResults = try service.searchStrongsMultiple(
            canonicalTokens: ["H0430"],
            sourceIdentities: identities
        )
        XCTAssertEqual(strongsResults.moduleCounts, [SearchModuleCount(moduleName: "HEALTHY", count: 1)])
        XCTAssertEqual(strongsResults.groups.flatMap(\.matches).map(\.moduleName), ["HEALTHY"])
        XCTAssertEqual(strongsResults.moduleFailures.map(\.moduleName), ["STALE"])

        XCTAssertThrowsError(
            try service.searchMultiple(
                query: "shared",
                sourceIdentities: [stale.searchIndexSourceIdentity],
                wordMode: .allWords
            )
        )
        XCTAssertThrowsError(
            try service.searchStrongsMultiple(
                canonicalTokens: ["H0430"],
                sourceIdentities: [stale.searchIndexSourceIdentity]
            )
        )
    }

    /**
     Runs one exact-generation text query through the production service.

     - Parameters:
       - query: Raw Lucene-compatible query text.
       - source: In-memory source whose exact identity authorizes the generated rows.
       - wordMode: Android query decoration mode, defaulting to any-word.
       - service: Isolated production index service.
     - Returns: Bounded module hit count.
     - Side effects: Performs read-only metadata and FTS queries.
     - Failure modes: Propagates readiness, analyzer, syntax, and SQLite errors.
     */
    private func hitCount(
        _ query: String,
        in source: InMemorySearchIndexSource,
        wordMode: SearchWordMode = .anyWord,
        using service: SearchIndexService
    ) throws -> Int {
        try service.search(
            query: query,
            sourceIdentity: source.searchIndexSourceIdentity,
            wordMode: wordMode
        ).hits.count
    }
}

/**
 Deterministic one-verse source used to exercise production analyzer/index/query boundaries.

 The fixture simulates exact metadata, a backend storage revision, canonical coordinates, visible text,
 and optional Strong's markup. It intentionally omits external storage and mutable cursor behavior;
 production service transactionality and query execution remain unmocked.
 */
private final class InMemorySearchIndexSource: BibleSearchIndexSource {
    /// Exact module metadata selecting the requested production analyzer.
    let searchIndexModuleInfo: ModuleInfo

    /// Generation-specific source revision included in the default SHA-256 identity.
    let searchIndexStorageRevision: String

    /// One emitted verse is the complete progress domain.
    let searchIndexProgressTotal = 1

    /// Visible text analyzed and indexed for the source's only verse.
    private let visibleText: String

    /// Optional lexical token embedded in source markup for Strong's search.
    private let strongToken: String?

    /// Optional visible substring owned by the lexical token for attributed-result coverage.
    private let strongHighlightText: String?

    /**
     Creates one immutable source generation without opening external storage.

     - Parameters:
       - moduleName: Exact same-initials identity used by generated rows.
       - language: Module language selecting the production analyzer.
       - version: Declared generation version included in the default fingerprint.
       - storageRevision: Backend generation component included in the default fingerprint.
       - visibleText: Complete visible text for the only verse.
       - strongToken: Optional canonical Strong's token embedded in lexical markup.
       - strongHighlightText: Optional first visible substring owned by `strongToken`.
     - Side effects: None.
     - Failure modes: None; the production index service validates the resulting identity and content.
     */
    init(
        moduleName: String,
        language: String,
        version: String = "1.0",
        storageRevision: String,
        visibleText: String,
        strongToken: String? = nil,
        strongHighlightText: String? = nil
    ) {
        searchIndexModuleInfo = ModuleInfo(
            name: moduleName,
            description: moduleName,
            category: .bible,
            language: language,
            moduleDriver: "RawText",
            version: version
        )
        searchIndexStorageRevision = storageRevision
        self.visibleText = visibleText
        self.strongToken = strongToken
        self.strongHighlightText = strongHighlightText
    }

    /**
     Emits the only canonical verse to the production indexing consumer.

     - Parameter consume: Synchronous service consumer; its Boolean result is accepted after one row.
     - Side effects: Invokes the consumer exactly once and allocates bounded one-verse markup.
     - Throws: Propagates the consumer's cancellation, analyzer, or SQLite failure.
     - Note: No second row exists, so a `false` result requires no additional cursor work.
     */
    func forEachSearchIndexEntry(
        _ consume: (BibleSearchIndexEntry) throws -> Bool
    ) throws {
        let highlightRange = strongHighlightText.map { (visibleText as NSString).range(of: $0) }
        let lemmaSpans: [SwordBibleSearchLemmaSpan]
        if let strongToken,
           let highlightRange,
           highlightRange.location != NSNotFound,
           highlightRange.length > 0 {
            lemmaSpans = [SwordBibleSearchLemmaSpan(
                lemma: "strong:\(strongToken)",
                location: highlightRange.location,
                length: highlightRange.length
            )]
        } else {
            lemmaSpans = []
        }
        let markup = strongToken.map { "<w lemma=\"strong:\($0)\">\(visibleText)</w>" }
            ?? visibleText
        _ = try consume(BibleSearchIndexEntry(
            displayKey: "Genesis 1:1",
            indexText: visibleText,
            previewText: visibleText,
            sourceMarkup: markup,
            taggedText: markup,
            lemmaSpans: lemmaSpans,
            entryOrder: 0,
            sourcePosition: 1,
            osisBookId: "Gen",
            displayBook: "Genesis",
            chapter: 1,
            verse: 1
        ))
    }
}
