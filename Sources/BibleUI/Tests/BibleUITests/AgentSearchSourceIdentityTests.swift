import SQLite3
import SwiftData
import XCTest

@testable import BibleCore
@testable import BibleUI
@testable import SwordKit

/// SQLite copy marker used by the deterministic generated-index fixtures in this file.
private let agentSearchFixtureSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/** Verifies AI Search tools authorize the exact readable source generation they query. */
final class AgentSearchSourceIdentityTests: BibleUISwordFixtureTestCase {
    /**
     Keeps readable native content from bypassing the generated Search index contract.

     - Setup: Opens the real KJV module and an empty temporary Search database, without running
       index generation. The independently chosen text and lexical queries have native matches.
     - Expected result: Explicit and automatic text/Strong's tools report their public not-indexed
       errors, and installed-document metadata stays unindexed.
     - Failure meaning: A missing index silently falls back to a native preview path, with different
       annotation, truncation or source-identity semantics.
     - Side effects: Creates transient stores and one temporary Search database; fixture teardown
       and deferred cleanup remove them. No full-Bible indexing is needed for this failure path.
     */
    @MainActor
    func testReadableNativeSourceCannotBypassMissingSearchIndex() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        XCTAssertTrue(module.info.features.contains(.strongsNumbers))
        let source = try module.inspectVerseKeyOSISSourceRestoringPrevious("Gen.1.1")
        XCTAssertTrue(source.osisFragment.contains("beginning"))

        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-search-no-index-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let searchIndexService = SearchIndexService(databasePath: databaseURL.path)
        let adapter = try makeAdapter(
            swordManager: manager,
            searchIndexService: searchIndexService
        )

        for books in [["KJV"], []] {
            XCTAssertThrowsError(try adapter.searchBible(
                query: "beginning",
                books: books,
                maximum: 20,
                offset: 0
            )) { error in
                XCTAssertEqual(
                    (error as? BibleUIAgentDomainError)?.code,
                    books.isEmpty ? "NO_INDEX" : "NOT_INDEXED"
                )
            }
        }
        for book: String? in ["KJV", nil] {
            XCTAssertThrowsError(try adapter.searchByStrongs(
                reportedNumber: "H0430",
                canonicalToken: "H0430",
                book: book,
                maximum: 20,
                offset: 0
            )) { error in
                XCTAssertEqual((error as? BibleUIAgentDomainError)?.code, "NOT_INDEXED")
            }
        }
        XCTAssertEqual(
            try installedIndexFlag(from: adapter.getInstalledDocuments(category: .bible), named: "KJV"),
            .bool(false)
        )
    }

    /**
     Rejects stale same-initials rows across text, Strong's, and installed-document readiness.

     - Setup: Seeds text and Strong's rows for the readable KJV fixture's exact source identity,
       proves all three Agent projections are ready, then changes only durable source-fingerprint
       metadata. Name-only compatibility readiness remains true while the current installed source
       identity no longer matches.
     - Expected result: Explicit and automatic selection fail with their stable not-indexed errors,
       and installed metadata reports `isIndexed=false`; before corruption every route succeeds and
       metadata reports true.
     - Failure meaning: AI can query or advertise rows produced by a replaced same-initials backend.
     - Side effects: Copies one temporary SWORD fixture, creates transient SwiftData containers and
       one deterministic Search database, then removes filesystem fixtures during teardown/defer cleanup.
     */
    @MainActor
    func testAgentSearchRequiresCurrentInstalledSourceIdentity() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        XCTAssertTrue(module.info.features.contains(.strongsNumbers))
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-search-identity-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let searchIndexService = SearchIndexService(databasePath: databaseURL.path)
        try await seedAgentSearchIndex(module: module, service: searchIndexService)
        let adapter = try makeAdapter(
            swordManager: manager,
            searchIndexService: searchIndexService
        )

        let explicitTextSearch = try adapter.searchBible(
            query: "beginning",
            books: ["KJV"],
            maximum: 20,
            offset: 0
        )
        let automaticTextSearch = try adapter.searchBible(
            query: "beginning",
            books: [],
            maximum: 20,
            offset: 0
        )
        for result in [explicitTextSearch, automaticTextSearch] {
            XCTAssertEqual(
                result.data?.objectValue?["results"]?.arrayValue?.compactMap {
                    $0.objectValue?["book"]?.stringValue
                },
                ["KJV"]
            )
        }
        let explicitStrongsSearch = try adapter.searchByStrongs(
            reportedNumber: "H0430",
            canonicalToken: "H0430",
            book: "KJV",
            maximum: 20,
            offset: 0
        )
        let automaticStrongsSearch = try adapter.searchByStrongs(
            reportedNumber: "H0430",
            canonicalToken: "H0430",
            book: nil,
            maximum: 20,
            offset: 0
        )
        for result in [explicitStrongsSearch, automaticStrongsSearch] {
            XCTAssertEqual(result.data?.objectValue?["searchedBook"]?.stringValue, "KJV")
            XCTAssertEqual(result.data?.objectValue?["results"]?.arrayValue?.count, 1)
        }
        XCTAssertEqual(
            try installedIndexFlag(from: adapter.getInstalledDocuments(category: .bible), named: "KJV"),
            .bool(true)
        )

        try await searchIndexService.performIndexMutationForTesting { database in
            let sql = """
                UPDATE indexed_modules
                SET source_fingerprint =
                    'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
                WHERE module_name = 'KJV'
                """
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                let message = sqlite3_errmsg(database).map(String.init(cString:))
                    ?? "SQLite update failed"
                throw NSError(
                    domain: "AgentSearchSourceIdentityFixture",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
        }

        XCTAssertTrue(searchIndexService.hasIndex(for: "KJV"))
        XCTAssertTrue(searchIndexService.hasStrongsIndex(for: "KJV"))
        XCTAssertFalse(searchIndexService.hasIndex(for: module.searchIndexSourceIdentity))
        XCTAssertFalse(searchIndexService.hasStrongsIndex(for: module.searchIndexSourceIdentity))
        XCTAssertThrowsError(try adapter.searchBible(
            query: "beginning",
            books: ["KJV"],
            maximum: 20,
            offset: 0
        )) { error in
            XCTAssertEqual((error as? BibleUIAgentDomainError)?.code, "NOT_INDEXED")
        }
        XCTAssertThrowsError(try adapter.searchBible(
            query: "beginning",
            books: [],
            maximum: 20,
            offset: 0
        )) { error in
            XCTAssertEqual((error as? BibleUIAgentDomainError)?.code, "NO_INDEX")
        }
        XCTAssertThrowsError(try adapter.searchByStrongs(
            reportedNumber: "H0430",
            canonicalToken: "H0430",
            book: "KJV",
            maximum: 20,
            offset: 0
        )) { error in
            XCTAssertEqual((error as? BibleUIAgentDomainError)?.code, "NOT_INDEXED")
        }
        XCTAssertThrowsError(try adapter.searchByStrongs(
            reportedNumber: "H0430",
            canonicalToken: "H0430",
            book: nil,
            maximum: 20,
            offset: 0
        )) { error in
            XCTAssertEqual((error as? BibleUIAgentDomainError)?.code, "NOT_INDEXED")
        }
        XCTAssertEqual(
            try installedIndexFlag(from: adapter.getInstalledDocuments(category: .bible), named: "KJV"),
            .bool(false)
        )
    }

    /**
     Keeps implicit Search/Strong's tools aligned with prompt BookSet order.

     - Setup: Registers an initials-first native Bible with abbreviation `Zulu` and an initials-last
       Bible with abbreviation `Alpha`, seeds query rows for both exact source generations, and
       leaves KJV unindexed.
     - Expected result: Android's installed BookSet reverses initials order through its abbreviation
       tier, while the prompt default, empty-book Search, and nil-book Strong's tool all select the
       Alpha-abbreviation Bible.
     - Failure meaning: Agent tools can silently query a different Bible than the system prompt
       advertises when automatic routes consume a non-BookSet inventory.
     - Side effects: Writes two inherited fixture descriptors and a temporary generated-index
       database removed by teardown.
     */
    @MainActor
    func testAutomaticAgentSearchAndPromptUseInstalledBookSetOrder() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let initialsFirst = "AAAInitialsFirst"
        let bookSetFirst = "ZZZBookSetFirst"
        try seedBibleAliasModule(
            named: initialsFirst,
            description: "Initials-first Bible",
            in: modulePath
        )
        try seedBibleAliasModule(
            named: bookSetFirst,
            description: "BookSet-first Bible",
            in: modulePath
        )
        try appendConfigLine(
            "Abbreviation=Zulu",
            moduleName: initialsFirst,
            modulePath: modulePath
        )
        try appendConfigLine(
            "Abbreviation=Alpha",
            moduleName: bookSetFirst,
            modulePath: modulePath
        )

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let initialsFirstModule = try XCTUnwrap(manager.module(named: initialsFirst))
        let bookSetModule = try XCTUnwrap(manager.module(named: bookSetFirst))
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-search-bookset-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let searchIndexService = SearchIndexService(databasePath: databaseURL.path)
        try await seedAgentSearchIndex(module: initialsFirstModule, service: searchIndexService)
        try await seedAgentSearchIndex(module: bookSetModule, service: searchIndexService)

        let resolver = BibleReaderInstalledModuleResolver(
            swordManager: manager,
            sqliteModules: []
        )
        XCTAssertLessThan(initialsFirst, bookSetFirst)
        XCTAssertEqual(
            resolver.readableModulesInBookSetOrder(categories: [.bible])
                .map(\.info.name)
                .filter { $0 == initialsFirst || $0 == bookSetFirst },
            [bookSetFirst, initialsFirst]
        )

        let adapter = try makeAdapter(
            swordManager: manager,
            searchIndexService: searchIndexService
        )
        let bibleSearch = try adapter.searchBible(
            query: "beginning",
            books: [],
            maximum: 20,
            offset: 0
        )
        let searchedBooks = try XCTUnwrap(
            bibleSearch.data?.objectValue?["results"]?.arrayValue
        ).compactMap { $0.objectValue?["book"]?.stringValue }
        XCTAssertFalse(searchedBooks.isEmpty)
        XCTAssertTrue(searchedBooks.allSatisfy { $0 == bookSetFirst })
        let strongsSearch = try adapter.searchByStrongs(
            reportedNumber: "H0430",
            canonicalToken: "H0430",
            book: nil,
            maximum: 20,
            offset: 0
        )
        XCTAssertEqual(
            strongsSearch.data?.objectValue?["searchedBook"]?.stringValue,
            bookSetFirst
        )

        let promptEnvironment = AIReaderReferenceEnvironmentResolver.resolve(
            installedModules: resolver.registeredBookMetadata(),
            excludedInitials: [],
            indexedModule: { name in
                guard let source = resolver.searchIndexSource(named: name) else { return false }
                return searchIndexService.hasIndex(for: source.searchIndexSourceIdentity)
            },
            selectedStrongsHebrew: [],
            selectedStrongsGreek: [],
            selectedGreekMorphology: []
        )
        XCTAssertEqual(promptEnvironment.defaultSearchBible?.initials, bookSetFirst)
    }

    /**
     Seeds the smallest complete generated index that exercises Agent source authorization.

     The adapter tests in this class own installed-source selection and identity validation. Full
     canonical streaming, transaction publication, and generated-index replacement are covered by
     BibleCore. Binding the real module identity here keeps those contracts separate while retaining
     production text analysis, FTS querying, Strong's querying, and readiness checks.

     - Parameters:
       - module: Real installed SWORD module whose exact source generation owns the fixture rows.
       - service: Isolated production Search service initialized with the current schema.
     - Side effects: Inserts one text row, one Strong's row, and matching completion metadata on the
       service's serialized test mutation queue.
     - Throws: Text analysis or SQLite preparation, binding, and execution failures.
     */
    private func seedAgentSearchIndex(
        module: SwordModule,
        service: SearchIndexService
    ) async throws {
        let identity = module.searchIndexSourceIdentity
        let analyzer = SearchTextAnalyzer.profile(for: module.info.language)
        let analyzedText = try SearchTextAnalyzer.analyzedText(
            "In the beginning God created the heaven and the earth.",
            profile: analyzer
        )
        try await service.performIndexMutationForTesting { database in
            try self.executeAgentSearchFixtureStatement(
                database: database,
                sql: """
                INSERT INTO verse_fts (
                    search_text, verse_key, plain_text, module_name, entry_order, osis_book,
                    display_book, display_book_mode, chapter, verse, book_order, canon_scope
                ) VALUES (?, 'Genesis 1:1', 'In the beginning God created the heaven and the earth.',
                          ?, 0, 'Gen', 'Genesis', 'source', 1, 1, 2, 'ot')
                """,
                values: [analyzedText, identity.moduleName]
            )
            try self.executeAgentSearchFixtureStatement(
                database: database,
                sql: """
                INSERT INTO verse_strongs (
                    module_name, token, verse_key, entry_order, highlight_ranges
                ) VALUES (?, 'H0430', 'Genesis 1:1', 0, '')
                """,
                values: [identity.moduleName]
            )
            try self.executeAgentSearchFixtureStatement(
                database: database,
                sql: """
                INSERT INTO indexed_modules (
                    module_name, verse_count, indexed_at, schema_version, language_code, analyzer_id,
                    strongs_complete, source_version, source_fingerprint, store_generation
                ) VALUES (?, 1, datetime('now'), ?, ?, ?, 1, ?, ?,
                          (SELECT store_generation FROM search_index_state WHERE id = 1))
                """,
                values: [
                    identity.moduleName,
                    SearchIndexService.currentSchemaVersion,
                    module.info.language,
                    analyzer.identifier,
                    identity.version,
                    identity.fingerprint,
                ]
            )
        }
    }

    /** Executes one bound fixture statement without interpreting module metadata as SQL. */
    private func executeAgentSearchFixtureStatement(
        database: OpaquePointer,
        sql: String,
        values: [Any]
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw agentSearchFixtureError(database: database, operation: "prepare")
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let string as String:
                result = sqlite3_bind_text(
                    statement,
                    index,
                    string,
                    -1,
                    agentSearchFixtureSQLiteTransient
                )
            case let integer as Int:
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(integer))
            default:
                throw NSError(
                    domain: "AgentSearchSourceIdentityFixture",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported SQLite fixture value"]
                )
            }
            guard result == SQLITE_OK else {
                throw agentSearchFixtureError(database: database, operation: "bind")
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw agentSearchFixtureError(database: database, operation: "execute")
        }
    }

    /** Returns the current SQLite failure without hiding the fixture operation that failed. */
    private func agentSearchFixtureError(database: OpaquePointer, operation: String) -> NSError {
        let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? "SQLite failure"
        return NSError(
            domain: "AgentSearchSourceIdentityFixture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "SQLite \(operation) failed: \(message)"]
        )
    }

    /**
     Builds the production Agent adapter with operation-unused stores backed by transient models.

     - Parameters:
       - swordManager: Readable installed source registry under test.
       - searchIndexService: Generated-index service whose identity metadata is mutated by the test.
     - Returns: A complete production adapter suitable for direct Search tool calls.
     - Side effects: Allocates three in-memory SwiftData containers.
     - Throws: SwiftData container construction failures.
     */
    @MainActor
    private func makeAdapter(
        swordManager: SwordManager,
        searchIndexService: SearchIndexService
    ) throws -> BibleUIAgentDomainAdapter {
        let bookmarkContext = ModelContext(try makeBookmarkListModelContainer())
        let myDocumentContext = ModelContext(try makeMyDocumentModelContainer())
        let workspaceContext = ModelContext(try makeWorkspaceModelContainer())
        return BibleUIAgentDomainAdapter(
            swordManager: swordManager,
            sqliteLibrary: SQLiteDocumentModuleLibrary(discoveredModules: []),
            searchIndexService: searchIndexService,
            bookmarkService: BookmarkService(store: BookmarkStore(modelContext: bookmarkContext)),
            labelConfigurationService: WorkspaceLabelConfigurationService(
                modelContext: bookmarkContext
            ),
            myDocumentLibraryStore: MyDocumentLibraryStore(modelContext: myDocumentContext),
            myDocumentStore: MyDocumentStore(modelContext: myDocumentContext),
            windowManager: WindowManager(
                workspaceStore: WorkspaceStore(modelContext: workspaceContext)
            ),
            documentAccessPolicy: AllowEveryAgentDocumentPolicy(),
            windowDocumentRouter: UnusedAgentWindowDocumentRouter(),
            strictMyDocumentInitialsUnavailable: { _ in false }
        )
    }

    /**
     Reads one named document's exact JSON `isIndexed` value.

     - Parameters:
       - result: Successful `getInstalledDocuments` result.
       - initials: Canonical installed initials to locate.
     - Returns: Stored Boolean JSON value.
     - Side effects: Records an XCTest failure when the expected response shape is absent.
     - Throws: `XCTUnwrap` failures for malformed or missing metadata.
     */
    private func installedIndexFlag(
        from result: AgentToolResult,
        named initials: String
    ) throws -> JSONValue {
        let documents = try XCTUnwrap(result.data?.objectValue?["documents"]?.arrayValue)
        let document = try XCTUnwrap(documents.first {
            $0.objectValue?["initials"]?.stringValue == initials
        })
        return try XCTUnwrap(document.objectValue?["isIndexed"])
    }

    /** Appends one test-only SWORD descriptor field without changing inherited fixture payloads. */
    private func appendConfigLine(
        _ line: String,
        moduleName: String,
        modulePath: String
    ) throws {
        let url = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/\(moduleName.lowercased()).conf")
        var config = try String(contentsOf: url, encoding: .utf8)
        config.append("\n\(line)\n")
        try config.write(to: url, atomically: true, encoding: .utf8)
    }
}

/** Deterministic Agent policy allowing every installed source in this focused identity test. */
@MainActor
private struct AllowEveryAgentDocumentPolicy: BibleUIAgentDocumentAccessPolicy {
    /** Allows the supplied initials without persistence reads. */
    func allows(documentInitials: String) -> Bool { true }
}

/** Window router sentinel; Search tool tests must never attempt a pane mutation. */
private struct UnusedAgentWindowDocumentRouter: BibleUIAgentWindowDocumentRouting {
    /** Fails if an unrelated document-navigation side effect reaches this focused fixture. */
    @MainActor
    func setDocument(
        windowID: UUID,
        documentInitials: String,
        key: String?
    ) async throws -> BibleUIAgentWindowDocumentState {
        throw UnusedAgentWindowDocumentRouterError.unexpectedInvocation
    }
}

/** Unexpected side effect emitted by the Search-only Agent fixture. */
private enum UnusedAgentWindowDocumentRouterError: Error {
    /// The Search operation attempted an out-of-scope live window mutation.
    case unexpectedInvocation
}
