import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Verifies Search resolves and navigates Android-compatible SQLite Bibles through reader runtime state.

 These tests use real SWORD and MyBible fixtures so collision precedence and result navigation pass
 through the same controller registry and module-switch coordinators used by the Search destination.
 */
final class SearchSQLiteRuntimeIntegrationTests: BibleUISwordFixtureTestCase {
    /**
     Verifies the current-source batch resolver rejects a canonically equivalent wrong owner.

     - Setup: Installs a MyBible source whose initials use composed `É`, then deliberately returns
       that source for a decomposed request that Swift considers equal but Java does not.
     - Expected result: Current Search creation resolution fails closed instead of authorizing the
       composed source for the Java-distinct requested initials.
     - Failure meaning: SearchView can undo the service authorization boundary by canonically
       matching a registry source before an index-creation token is captured.
     - Side effects: Creates one isolated package fixture and opens one fresh native inventory.
     */
    @MainActor
    func testCurrentIndexBatchRejectsCanonicallyEquivalentRegistryOwner() throws {
        let composedName = "CAF\u{00C9}"
        let decomposedName = "CAFE\u{0301}"
        XCTAssertEqual(composedName, decomposedName)
        XCTAssertFalse(SwordJavaStringIdentity.equals(composedName, decomposedName))

        let modulePath = try makeTemporarySwordFixturePath()
        try installMyBiblePackage(
            initials: composedName,
            directoryName: "canonical-owner-source",
            in: modulePath
        )
        let presentationManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: presentationManager
        )
        let registry = try XCTUnwrap(controller.makeSearchIndexSourceRegistry())
        let composedSource = try XCTUnwrap(registry.source(named: composedName))

        let resolved = SearchView.resolveCurrentSearchIndexSourcesForCreation(
            named: [decomposedName],
            modulePath: modulePath,
            registrySource: { _ in composedSource },
            managerFactory: { SwordManager(modulePath: $0) }
        )

        XCTAssertNil(resolved)
    }

    /**
     Verifies current native ownership failure cannot fall through to an immutable SQLite source.

     - Setup: Installs one readable MyBible source and captures it in Search's presentation registry,
       then injects a current-manager factory that deterministically fails.
     - Expected result: Batch creation resolution returns nil after exactly one factory invocation;
       the old SQLite registry source is not authorized when native ownership cannot be checked.
     - Failure meaning: A transient SWORD-manager failure can bless a stale or newly shadowed SQLite
       source, contradicting Search's fail-closed current-store authorization contract.
     - Side effects: Creates one isolated package fixture and reads its immutable registry metadata.
     */
    @MainActor
    func testCurrentIndexBatchFailsClosedWhenFreshManagerCannotOpen() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installMyBiblePackage(
            initials: "SQLFAILCLOSED",
            directoryName: "manager-failure-source",
            in: modulePath
        )
        let presentationManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: presentationManager
        )
        let registry = try XCTUnwrap(controller.makeSearchIndexSourceRegistry())
        XCTAssertTrue(registry.source(named: "SQLFAILCLOSED") is SQLiteDocumentModule)
        var managerFactoryInvocationCount = 0

        let resolved = SearchView.resolveCurrentSearchIndexSourcesForCreation(
            named: ["SQLFAILCLOSED"],
            modulePath: modulePath,
            registrySource: { registry.source(named: $0) },
            managerFactory: { _ in
                managerFactoryInvocationCount += 1
                return nil
            }
        )

        XCTAssertNil(resolved)
        XCTAssertEqual(managerFactoryInvocationCount, 1)
    }

    /**
     Verifies mixed multi-select creation shares one authoritative native inventory.

     - Setup: Uses fixture KJV plus two native-absent MyBible sources, captures the presentation
       registry, and injects a counting factory that opens a real fresh manager.
     - Expected result: Fresh native KJV and both exact SQLite fallbacks resolve in requested order
       while the manager factory runs once for the complete batch.
     - Failure meaning: Search either rejects valid Android SQLite books or regresses to one full
       native inventory/manager lifetime per selected translation on the UI path.
     - Side effects: Creates two isolated package fixtures and one operation-owned SWORD manager.
    */
    @MainActor
    func testCurrentIndexBatchUsesOneManagerForMixedNativeAndSQLiteSources() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installMyBiblePackage(
            initials: "SQLBATCHA",
            directoryName: "batch-source-a",
            in: modulePath
        )
        try installMyBiblePackage(
            initials: "SQLBATCHB",
            directoryName: "batch-source-b",
            in: modulePath
        )
        let presentationManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: presentationManager
        )
        let registry = try XCTUnwrap(controller.makeSearchIndexSourceRegistry())
        var managerFactoryInvocationCount = 0

        let resolved = try XCTUnwrap(
            SearchView.resolveCurrentSearchIndexSourcesForCreation(
                named: ["KJV", "SQLBATCHA", "SQLBATCHB"],
                modulePath: modulePath,
                registrySource: { registry.source(named: $0) },
                managerFactory: { path in
                    managerFactoryInvocationCount += 1
                    return SwordManager(modulePath: path)
                }
            )
        )

        XCTAssertEqual(managerFactoryInvocationCount, 1)
        XCTAssertEqual(resolved.map(\.name), ["KJV", "SQLBATCHA", "SQLBATCHB"])
        XCTAssertEqual(
            resolved.map { $0.source.searchIndexModuleInfo.name },
            ["KJV", "SQLBATCHA", "SQLBATCHB"]
        )
        XCTAssertFalse(resolved[0].source is SwordModule)
        XCTAssertFalse(resolved[0].source is SQLiteDocumentModule)
        XCTAssertTrue(resolved.dropFirst().allSatisfy {
            $0.source is SQLiteDocumentModule
        })
    }

    /**
     Pins Search source resolution to JSword lookup precedence rather than the initials-only UI catalog.

     - Setup: Installs one uniquely named MyBible package and one lowercase KJV collision beside the
       genuine SWORD KJV fixture.
     - Expected result: Exact initials and full-name variants resolve the unique SQLite source, while
       every Java-equal KJV request resolves the genuine SWORD module.
     - Failure meaning: Search uses the narrower reader catalog or allows SQLite to shadow SWORD.
     - Side effects: Copies isolated SWORD/MyBible fixtures and validates their metadata read-only.
     */
    @MainActor
    func testSearchRegistryPreservesFullNameLookupAndSwordCollisionPrecedence() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installMyBiblePackage(
            initials: "SQLSEARCH",
            directoryName: "search-source",
            in: modulePath
        )
        try installMyBiblePackage(
            initials: "kjv",
            directoryName: "sword-collision",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: manager
        )
        let registry = try XCTUnwrap(controller.makeSearchIndexSourceRegistry())

        let exactSQLite = try XCTUnwrap(registry.source(named: "SQLSEARCH"))
        XCTAssertTrue(exactSQLite is SQLiteDocumentModule)
        XCTAssertEqual(exactSQLite.searchIndexModuleInfo.name, "SQLSEARCH")
        XCTAssertEqual(
            registry.source(named: "MyBible Bible Fixture")?.searchIndexModuleInfo.name,
            "SQLSEARCH"
        )
        XCTAssertEqual(
            registry.source(named: "mybible bible fixture")?.searchIndexModuleInfo.name,
            "SQLSEARCH"
        )

        let collisionOwner = try XCTUnwrap(registry.source(named: "kjv"))
        XCTAssertTrue(collisionOwner is SwordModule)
        XCTAssertEqual(collisionOwner.searchIndexModuleInfo.name, "KJV")
    }

    /**
     Verifies locked native ownership cannot be bypassed through a colliding SQLite Search source.

     - Setup: Adds a locked native Bible whose full description equals one MyBible initials token,
       plus an unrelated readable MyBible source, beside the normal readable KJV fixture.
     - Expected result: The locked native stays in inclusive reader inventory, both it and its
       shadowed SQLite collision are absent from Search, and the unrelated SQLite source remains.
     - Failure meaning: Search can index/navigate a backend identity that the global registry routes
       to an unlock-required native owner, or can hide unrelated readable SQLite content.
     - Side effects: Writes isolated SWORD/MyBible fixtures and reads their metadata through a fresh
       manager/controller snapshot; it does not attempt an unlock.
     */
    @MainActor
    func testLockedNativeOwnerShadowsSQLiteCollisionWithoutHidingUnrelatedSearchSource() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "LOCKEDSEARCH",
            description: "SQLLOCKED",
            in: modulePath
        )
        let lockedConfigURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/lockedsearch.conf")
        var lockedConfig = try String(contentsOf: lockedConfigURL, encoding: .utf8)
        lockedConfig += "\nCipherKey=\n"
        try lockedConfig.write(to: lockedConfigURL, atomically: true, encoding: .utf8)
        try installMyBiblePackage(
            initials: "SQLLOCKED",
            directoryName: "locked-full-name-collision",
            in: modulePath
        )
        try installMyBiblePackage(
            initials: "SQLUNRELATED",
            directoryName: "unrelated-readable-source",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertEqual(manager.moduleAccessState(named: "LOCKEDSEARCH"), .locked)
        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: manager
        )
        let registry = try XCTUnwrap(controller.makeSearchIndexSourceRegistry())

        XCTAssertTrue(controller.installedBibleModules.contains { $0.name == "LOCKEDSEARCH" })
        XCTAssertFalse(controller.installedBibleModules.contains { $0.name == "SQLLOCKED" })
        XCTAssertNil(registry.source(named: "LOCKEDSEARCH"))
        XCTAssertNil(registry.source(named: "SQLLOCKED"))
        XCTAssertTrue(registry.source(named: "SQLUNRELATED") is SQLiteDocumentModule)
        XCTAssertTrue(registry.source(named: "KJV") is SwordModule)
    }

    /**
     Navigates a non-active SQLite Search result without falling through to the current SWORD Bible.

     - Setup: Starts on fixture KJV and installs a package-owned MyBible source with Genesis 1:2.
     - Expected result: The selected SQLite identity becomes active before navigation; a subsequent
       missing-module or malformed canonical target returns false and leaves the SQLite location
       unchanged.
     - Failure meaning: Search result module identity is discarded or navigation uses active fallback.
     - Side effects: Switches and updates one isolated reader controller's Bible location.
     */
    @MainActor
    func testSearchResultNavigatesNonActiveSQLiteModuleWithoutActiveFallback() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installMyBiblePackage(
            initials: "SQLSEARCH",
            directoryName: "navigation-source",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: manager
        )
        XCTAssertEqual(controller.activeModuleName, "KJV")

        XCTAssertTrue(controller.navigateToSearchResult(SearchNavigationTarget(
            moduleName: "SQLSEARCH",
            osisBookId: "Gen",
            displayBook: "Genesis",
            chapter: 1,
            verse: 2
        )))
        XCTAssertEqual(controller.activeModuleName, "SQLSEARCH")
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 2)

        XCTAssertFalse(controller.navigateToSearchResult(SearchNavigationTarget(
            moduleName: "MISSING",
            osisBookId: "Matt",
            displayBook: "Matthew",
            chapter: 1,
            verse: 1
        )))
        XCTAssertEqual(controller.activeModuleName, "SQLSEARCH")
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 2)

        XCTAssertFalse(controller.navigateToSearchResult(SearchNavigationTarget(
            moduleName: "SQLSEARCH",
            osisBookId: "",
            displayBook: "Matthew",
            chapter: 1,
            verse: 1
        )))
        XCTAssertEqual(controller.activeModuleName, "SQLSEARCH")
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 2)
    }

    /**
     Opens SearchResults' complete mixed-backend match set through the shared links-window route.

     - Setup: Installs the real SWORD KJV fixture beside a package-owned MyBible source, then builds
       grouped Search hits for one exact verse from each module.
     - Expected result: The controller emits one Vue Multi document whose fragments preserve group
       order, exact module initials, and exact OSIS identities. An empty result fails closed without
       invoking the window callback.
     - Failure meaning: SearchResults' Android "Open in window" action drops translations, substitutes
       the active Bible, reorders hits, or dismisses Search after an unroutable request.
     - Side effects: Reads two isolated fixture verses and captures one in-memory window payload.
     */
    @MainActor
    func testOpenSearchResultsInWindowPreservesEveryExactModuleMatch() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try installMyBiblePackage(
            initials: "SQLSEARCH",
            directoryName: "window-source",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: manager
        )
        let genesisOrder = SearchCanonicalBookCatalog.order(of: "Gen")
        let kjvIdentity = SearchVerseIdentity(
            osisBookId: "Gen",
            canonicalBookOrder: genesisOrder,
            chapter: 1,
            verse: 1
        )
        let sqliteIdentity = SearchVerseIdentity(
            osisBookId: "Gen",
            canonicalBookOrder: genesisOrder,
            chapter: 1,
            verse: 2
        )
        let grouped = SearchGroupedResults(
            moduleResults: [
                SearchModuleResults(moduleName: "KJV", hits: [
                    SearchModuleHit(
                        moduleName: "KJV",
                        key: "Genesis 1:1",
                        displayBook: "Genesis",
                        snippet: "In the beginning",
                        identity: kjvIdentity
                    ),
                ]),
                SearchModuleResults(moduleName: "SQLSEARCH", hits: [
                    SearchModuleHit(
                        moduleName: "SQLSEARCH",
                        key: "Genesis 1:2",
                        displayBook: "Genesis",
                        snippet: "The earth was formless",
                        identity: sqliteIdentity,
                        bookNamePresentation: .localizedCanonical
                    ),
                ]),
            ],
            moduleOrder: ["KJV", "SQLSEARCH"]
        )
        var routedJSON: String?
        controller.onOpenMultiReferenceDocumentInLinksWindow = { routedJSON = $0 }

        XCTAssertTrue(controller.openSearchResultsInLinksWindow(grouped))
        let data = try XCTUnwrap(routedJSON?.data(using: .utf8))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let fragments = try XCTUnwrap(payload["osisFragments"] as? [[String: Any]])
        XCTAssertEqual(payload["type"] as? String, "multi")
        XCTAssertEqual(payload["compare"] as? Bool, false)
        XCTAssertEqual(fragments.map { $0["bookInitials"] as? String }, ["KJV", "SQLSEARCH"])
        XCTAssertEqual(fragments.map { $0["osisRef"] as? String }, ["Gen.1.1", "Gen.1.2"])
        XCTAssertTrue((fragments[0]["xml"] as? String)?.contains("osisID=\"Gen.1.1\"") == true)
        XCTAssertTrue((fragments[1]["xml"] as? String)?.contains("osisID=\"Gen.1.2\"") == true)

        routedJSON = nil
        let empty = SearchGroupedResults(moduleResults: [], moduleOrder: [])
        XCTAssertFalse(controller.openSearchResultsInLinksWindow(empty))
        XCTAssertNil(routedJSON)
    }

    /** Installs one package-owned MyBible fixture with caller-controlled Search initials. */
    private func installMyBiblePackage(
        initials: String,
        directoryName: String,
        in modulePath: String
    ) throws {
        let repositoryRoot = try BibleUITestSourceLocator.repositoryRoot(
            containing: "Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders/mybible-bible.SQLite3"
        )
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/BibleCore/Tests/Fixtures/SQLiteDocumentReaders/mybible-bible.SQLite3"
        )
        let packageRoot = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mybible/\(directoryName)", isDirectory: true)
        let payloadName = "\(directoryName).SQLite3"
        try FileManager.default.createDirectory(
            at: packageRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: sourceURL,
            to: packageRoot.appendingPathComponent(payloadName)
        )
        let packageFileName = "\(payloadName).zip"
        let sidecar = try JSONSerialization.data(withJSONObject: [
            "name": initials,
            "description": "Search SQLite fixture",
            "category": "Biblical Texts",
            "language": "en",
            "version": "1",
            "sourceName": "Fixture",
            "packageFileName": packageFileName,
            "downloadURL": "https://example.invalid/\(packageFileName)",
            "installedAt": 0,
        ], options: [.sortedKeys])
        try sidecar.write(to: packageRoot.appendingPathComponent("module.json"))
    }
}
