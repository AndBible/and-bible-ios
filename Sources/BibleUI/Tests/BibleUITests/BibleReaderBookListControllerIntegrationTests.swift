// BibleReaderBookListControllerIntegrationTests.swift -- Native registry ownership regressions

import Foundation
import SwordKit
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView

/** Exercises book-list ownership through real native managers and reader controller transactions. */
@MainActor
final class BibleReaderBookListControllerIntegrationTests: BibleUISwordFixtureTestCase {
    /**
     Exercises the real native document-switch coordinator with an inventory adopted at configure.

     - Side effects: Creates an isolated SWORD fixture and mutates one in-memory `PageManager`.
     - Failure meaning: Avoiding repeated enumeration can bypass the shared switch transaction or
       suppress its category, persistence, and ready-client reload effects.
     - Throws: Fixture creation or native module discovery errors.
     */
    func testNativeDocumentSwitchReusesConfiguredInventoryAndStillPersistsAndReloads() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "WEB",
            description: "World English Bible",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(manager.readableModule(named: "WEB"))
        let generation = manager.contentAuthorizationGeneration
        let registryWitness = BibleReaderBookListRegistryWitness(
            managerOwner: manager,
            managerGeneration: generation.managerGeneration,
            moduleStoreGeneration: generation.moduleStoreGeneration,
            installedSourceGeneration: 1
        )
        let source = try XCTUnwrap(registryWitness.sourceIdentityIfCurrent(
            managerOwner: manager,
            moduleOwner: module,
            backend: .sword,
            managerGeneration: generation.managerGeneration,
            moduleStoreGeneration: generation.moduleStoreGeneration,
            installedSourceGeneration: 1
        ))
        var owner = BibleReaderBookListOwner()
        owner.record([Self.genesis], for: source)

        let window = Window()
        let pageManager = PageManager(
            id: window.id,
            currentCategoryName: DocumentCategory.commentary.pageManagerKey
        )
        window.pageManager = pageManager
        retainReaderWindowGraph(window)
        var activeModule: SwordModule?
        var currentCategory = DocumentCategory.commentary
        var currentBooks: [BookInfo] = []
        var enumerationCount = 0
        var persistCount = 0
        var reloadCount = 0
        let context = BibleReaderModuleSwitchContext(
            swordManager: manager,
            activeWindow: window,
            clientReady: true,
            currentCategory: currentCategory,
            currentDictionaryKey: nil,
            currentGeneralBookKey: nil,
            currentMapKey: nil,
            containsExactGenericKey: { _, _ in false },
            loadGenericKeys: { _ in [] },
            setBibleModule: { selected, _ in activeModule = selected },
            setCommentaryModule: { _, _ in },
            setDictionaryModule: { _, _ in },
            setGeneralBookModule: { _, _ in },
            setMapModule: { _, _ in },
            setDictionaryKey: { _ in },
            setGeneralBookKey: { _ in },
            setMapKey: { _ in },
            setCurrentCategory: { currentCategory = $0 },
            refreshBookList: {
                guard let activeModule else {
                    XCTFail("Expected the switch to activate WEB before refreshing books.")
                    return
                }
                let currentGeneration = manager.contentAuthorizationGeneration
                guard let currentSource = registryWitness.sourceIdentityIfCurrent(
                    managerOwner: manager,
                    moduleOwner: activeModule,
                    backend: .sword,
                    managerGeneration: currentGeneration.managerGeneration,
                    moduleStoreGeneration: currentGeneration.moduleStoreGeneration,
                    installedSourceGeneration: 1
                ) else {
                    XCTFail("Expected the configured registry witness to remain current.")
                    return
                }
                currentBooks = owner.resolve(for: currentSource) {
                    enumerationCount += 1
                    return activeModule.getBookList()
                }
            },
            moduleBookListCount: { currentBooks.count },
            persistState: { persistCount += 1 },
            loadCurrentContent: { reloadCount += 1 }
        )
        let coordinator = BibleReaderModuleSwitchCoordinator()

        let first = coordinator.switchBibleDocument(to: "WEB", context: context)
        let second = coordinator.switchBibleDocument(to: "WEB", context: context)

        XCTAssertEqual(first, .switched)
        XCTAssertEqual(second, .switched)
        XCTAssertTrue(activeModule === module)
        XCTAssertEqual(currentCategory, .bible)
        XCTAssertEqual(currentBooks, [Self.genesis])
        XCTAssertEqual(enumerationCount, 0)
        XCTAssertEqual(pageManager.bibleDocument, "WEB")
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.bible.pageManagerKey)
        XCTAssertEqual(persistCount, 2)
        XCTAssertEqual(reloadCount, 2)
    }

    /**
     Proves controller configuration and pane copy replace a native manager created before a real
     module-store publication instead of stamping its cached registry with the newer generation.

     - Side effects: Creates two real Bible fixtures, publishes the second config/data pair under
       the production canonical transaction lease, and constructs isolated reader controllers.
     - Failure meaning: A late configure or pane copy can omit the newly published module while
       treating an old immutable `SWMgr` as current.
     - Throws: Fixture, transaction, native-manager, or controller setup failures.
     */
    func testConfigurationAndPaneCopyReplaceManagerCreatedBeforePublication() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        let configDirectory = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d", isDirectory: true)
        for configURL in try FileManager.default.contentsOfDirectory(
            at: configDirectory,
            includingPropertiesForKeys: nil
        ) {
            try FileManager.default.removeItem(at: configURL)
        }
        try seedSyntheticRawTextBibleModule(
            named: "CUSTOM",
            description: "Original custom Bible",
            versification: "KJV",
            entries: [("Gen", 1, 1, "<verse osisID=\"Gen.1.1\">ORIGINAL</verse>")],
            in: modulePath
        )
        let staleManager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertEqual(staleManager.installedModules().map(\.name), ["CUSTOM"])
        let sourceController = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: staleManager
        )
        XCTAssertEqual(sourceController.bookList.map(\.osisId), ["Gen"])
        XCTAssertEqual(
            sourceController.installedModules(for: .bible).first?.description,
            "Original custom Bible"
        )

        let coordinator = ModuleStoreMutationCoordinator.shared(
            forModuleRoot: URL(fileURLWithPath: modulePath)
        )
        try coordinator.withExclusiveTransaction(
            kind: .remoteSword,
            prepare: { () },
            commit: { _ in
                try self.seedSyntheticRawTextBibleModule(
                    named: "CUSTOMNEXT",
                    description: "Replacement custom Bible",
                    versification: "KJV",
                    entries: [("Exod", 1, 1, "<verse osisID=\"Exod.1.1\">REPLACEMENT</verse>")],
                    in: modulePath
                )
                let replacementConfigURL = configDirectory.appendingPathComponent(
                    "customnext.conf",
                    isDirectory: false
                )
                let installedConfigURL = configDirectory.appendingPathComponent(
                    "custom.conf",
                    isDirectory: false
                )
                let replacementConfig = try String(
                    contentsOf: replacementConfigURL,
                    encoding: .utf8
                )
                    .replacingOccurrences(of: "[CUSTOMNEXT]", with: "[CUSTOM]")
                    .replacingOccurrences(of: "Abbreviation=CUSTOMNEXT", with: "Abbreviation=CUSTOM")
                try replacementConfig.write(
                    to: installedConfigURL,
                    atomically: true,
                    encoding: .utf8
                )
                try FileManager.default.removeItem(at: replacementConfigURL)
                let swordCacheURL = configDirectory.appendingPathComponent(
                    "modules-conf.cache",
                    isDirectory: false
                )
                if FileManager.default.fileExists(atPath: swordCacheURL.path) {
                    try FileManager.default.removeItem(at: swordCacheURL)
                }
            }
        )
        XCTAssertEqual(
            staleManager.readableModule(named: "CUSTOM")?.getBookList().map(\.osisId),
            ["Gen"]
        )

        let configuredFromStale = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: staleManager
        )
        XCTAssertFalse(configuredFromStale.swordManager === staleManager)
        XCTAssertEqual(configuredFromStale.installedModules(for: .bible).map(\.name), ["CUSTOM"])
        XCTAssertEqual(
            configuredFromStale.installedModules(for: .bible).first?.description,
            "Replacement custom Bible"
        )
        XCTAssertEqual(configuredFromStale.bookList.map(\.osisId), ["Exod"])
        XCTAssertEqual(
            sourceController.installedModules(for: .bible).first?.description,
            "Original custom Bible"
        )

        let targetManager = try XCTUnwrap(
            SwordManager.currentRegistryManager(modulePath: modulePath)
        )
        let targetController = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: targetManager
        )
        XCTAssertTrue(targetController.copyModuleState(from: sourceController))
        XCTAssertFalse(targetController.swordManager === staleManager)
        XCTAssertEqual(targetController.installedModules(for: .bible).map(\.name), ["CUSTOM"])
        XCTAssertEqual(
            targetController.installedModules(for: .bible).first?.description,
            "Replacement custom Bible"
        )
        XCTAssertEqual(targetController.bookList.map(\.osisId), ["Exod"])
    }

    /// Stable configured inventory used to prove a repeated switch does not enumerate again.
    private static let genesis = BookInfo(
        name: "Genesis",
        osisId: "Gen",
        abbreviation: "Gen",
        chapterCount: 50,
        testament: 1
    )
}
