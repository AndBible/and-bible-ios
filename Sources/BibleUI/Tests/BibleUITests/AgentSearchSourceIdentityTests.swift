import SQLite3
import SwiftData
import XCTest

@testable import BibleCore
@testable import BibleUI
@testable import SwordKit

/** Verifies AI Search tools authorize the exact readable source generation they query. */
final class AgentSearchSourceIdentityTests: BibleUISwordFixtureTestCase {
    /**
     Rejects stale same-initials rows across text, Strong's, and installed-document readiness.

     - Setup: Indexes the readable KJV fixture, proves all three Agent projections are ready, then
       changes only durable source-fingerprint metadata. Name-only compatibility readiness remains
       true while the current installed source identity no longer matches.
     - Expected result: Explicit and automatic selection fail with their stable not-indexed errors,
       and installed metadata reports `isIndexed=false`; before corruption every route succeeds and
       metadata reports true.
     - Failure meaning: AI can query or advertise rows produced by a replaced same-initials backend.
     - Side effects: Copies one temporary SWORD fixture, creates transient SwiftData containers and
       one generated Search database, then removes filesystem fixtures during teardown/defer cleanup.
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
        try await searchIndexService.createIndex(module: module)
        let adapter = try makeAdapter(
            swordManager: manager,
            searchIndexService: searchIndexService
        )

        XCTAssertNoThrow(try adapter.searchBible(
            query: "beginning",
            books: ["KJV"],
            maximum: 20,
            offset: 0
        ))
        XCTAssertNoThrow(try adapter.searchBible(
            query: "beginning",
            books: [],
            maximum: 20,
            offset: 0
        ))
        XCTAssertNoThrow(try adapter.searchByStrongs(
            reportedNumber: "H0430",
            canonicalToken: "H0430",
            book: "KJV",
            maximum: 20,
            offset: 0
        ))
        XCTAssertNoThrow(try adapter.searchByStrongs(
            reportedNumber: "H0430",
            canonicalToken: "H0430",
            book: nil,
            maximum: 20,
            offset: 0
        ))
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
       Bible with abbreviation `Alpha`, indexes both exact source generations, and leaves KJV
       unindexed.
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
        try await searchIndexService.createIndex(module: initialsFirstModule)
        try await searchIndexService.createIndex(module: bookSetModule)

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
            windowDocumentRouter: UnusedAgentWindowDocumentRouter()
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
