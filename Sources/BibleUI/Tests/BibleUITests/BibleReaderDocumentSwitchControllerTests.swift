import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Package-level coverage for reader controller current-document switch side effects.

 Android quick selectors and full document chooser paths route selected documents through one
 current-document transition. These tests use temporary SWORD fixtures to keep that controller
 contract covered without the app host: selected modules, visible categories, stale auxiliary keys,
 bridge reloads, and persistence callbacks must remain atomic.
 */
final class BibleReaderDocumentSwitchControllerTests: BibleUISwordFixtureTestCase {
    /**
     Protects the quick selector's selected-row side effect contract.

     Android's popup selection calls the same current-document switch path used elsewhere in the
     reader. iOS should likewise route selected quick-menu modules through
     `BibleReaderController.switchBibleDocument(to:)` and persist the chosen Bible document plus
     Bible category on the pane's `PageManager`, rather than maintaining separate quick-selector
     state.
     */
    @MainActor
    func testBibleQuickModuleSelectorSelectionUsesControllerSwitchPathAndPersistsPaneDocument() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "WEB",
            description: "World English Bible",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window

        let action = BibleReaderQuickModuleSelectorPresentation.action(
            for: controller.installedBibleModules,
            activeModuleName: controller.activeModuleName
        )
        guard case .switchDirectly(let row) = action else {
            XCTFail("Expected Android's exactly-two-module shortcut to select the alternate Bible.")
            return
        }

        controller.switchBibleDocument(to: row.module.name)

        XCTAssertEqual(controller.activeModuleName, "WEB")
        XCTAssertEqual(pageManager.bibleDocument, "WEB")
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.bible.pageManagerKey)
    }

    /**
     Protects Android's atomic current-document switch behavior for commentary quick selections.

     Android `menuForDocs` delegates the selected commentary `Book` to `setCurrentDocument(book)`,
     which updates the active document and visible category together. iOS must provide the same
     controller-level contract for the quick selector instead of switching module and category in
     separate calls that can reload stale content or persist partial pane state.
     */
    @MainActor
    func testCommentaryDocumentSwitchPersistsModuleAndCategoryTogether() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawCommentaryModule(named: "UITestComm", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.switchCommentaryDocument(to: "UITestComm")

        XCTAssertEqual(controller.currentCategory, .commentary)
        XCTAssertEqual(controller.activeCommentaryModuleName, "UITestComm")
        XCTAssertEqual(pageManager.commentaryDocument, "UITestComm")
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.commentary.pageManagerKey)
        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects Android's atomic current-document switch behavior for dictionary quick selections.

     Android routes dictionaries from the commentary quick popup through `setCurrentDocument(book)`.
     iOS must therefore persist the selected dictionary, clear stale dictionary entry state, and
     switch the visible category in one controller call rather than splitting module and category
     updates across separate mutations.
     */
    @MainActor
    func testDictionaryDocumentSwitchPersistsModuleCategoryAndClearsKeyTogether() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedReadableRawDictionaryModule(
            named: "UITestDict",
            entryKey: "available-key",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.dictionaryKey = "stale-key"
        window.pageManager = pageManager
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        let outcome = controller.switchDictionaryDocument(to: "UITestDict")

        XCTAssertEqual(outcome, .switchedRequiringKeySelection)
        XCTAssertEqual(controller.currentCategory, .dictionary)
        XCTAssertEqual(controller.activeDictionaryModuleName, "UITestDict")
        XCTAssertNil(controller.currentDictionaryKey)
        XCTAssertEqual(pageManager.dictionaryDocument, "UITestDict")
        XCTAssertNil(pageManager.dictionaryKey)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.dictionary.pageManagerKey)
        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects Android's atomic current-document switch behavior for general-book quick selections.

     Android includes general books in the commentary quick popup and applies selections through the
     same current-document transition. The iOS controller must persist module/category and clear the
     stale general-book key together so quick selection cannot leave mixed pane state behind.
     */
    @MainActor
    func testGeneralBookDocumentSwitchPersistsModuleCategoryAndClearsKeyTogether() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawGeneralBookModule(named: "UITestGB", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.generalBookKey = "stale-key"
        window.pageManager = pageManager
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        let outcome = controller.switchGeneralBookDocument(to: "UITestGB")

        XCTAssertEqual(outcome, .switchedRequiringKeySelection)
        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(controller.activeGeneralBookModuleName, "UITestGB")
        XCTAssertNil(controller.currentGeneralBookKey)
        XCTAssertEqual(pageManager.generalBookDocument, "UITestGB")
        XCTAssertNil(pageManager.generalBookKey)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.generalBook.pageManagerKey)
        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects Android's atomic current-document switch behavior for map selections.

     Android routes maps through the same current-document transition as other chooser rows. The
     iOS controller must therefore persist the selected map/category and clear stale map keys
     together so map selection cannot leave mixed pane state behind.
     */
    @MainActor
    func testMapDocumentSwitchPersistsModuleCategoryAndClearsKeyTogether() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawMapModule(named: "UITestMap", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.mapKey = "stale-key"
        window.pageManager = pageManager
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        let outcome = controller.switchMapDocument(to: "UITestMap")

        XCTAssertEqual(outcome, .switchedRequiringKeySelection)
        XCTAssertEqual(controller.currentCategory, .map)
        XCTAssertEqual(controller.activeMapModuleName, "UITestMap")
        XCTAssertNil(controller.currentMapKey)
        XCTAssertEqual(pageManager.mapDocument, "UITestMap")
        XCTAssertNil(pageManager.mapKey)
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.map.pageManagerKey)
        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects Android's atomic current-document switch behavior for Bible quick selections.

     Android `MainBibleActivity.menuForDocs` delegates selected Bible rows to
     `CurrentPageManager.setCurrentDocument(book)`, which updates the active document and page
     category as one transition. iOS must not first reload the current non-Bible category and then
     reload the selected Bible, because that creates unnecessary WebView work and visible flicker.
     */
    @MainActor
    func testBibleDocumentSwitchFromCommentaryReloadsSelectedBibleOnce() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "WEB",
            description: "World English Bible",
            in: modulePath
        )
        try seedEmptyRawCommentaryModule(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.switchCategory(to: .commentary)
        controller.bridgeDidSetClientReady(bridge)
        let baselineScriptCount = recordedScripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.switchBibleDocument(to: "WEB")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let addDocumentScripts = recordedScripts()
            .dropFirst(baselineScriptCount)
            .filter { $0.contains("emit('add_documents'") }
        XCTAssertEqual(addDocumentScripts.count, 1)
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: Array(addDocumentScripts), event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["bookCategory"] as? String, "BIBLE")
        XCTAssertEqual(payload["bookInitials"] as? String, "WEB")
        XCTAssertEqual(controller.currentCategory, .bible)
        XCTAssertEqual(controller.activeModuleName, "WEB")
        XCTAssertEqual(pageManager.bibleDocument, "WEB")
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.bible.pageManagerKey)
        XCTAssertEqual(persistCount, 1)
    }

    /**
     Protects the shared activation boundary from selecting or rendering a locked Bible.

     - Setup: Marks a real temporary Bible alias encrypted with an empty `CipherKey`, attaches a
       ready reader pane whose current KJV is readable, and records persistence plus bridge scripts.
     - Expected result: Inclusive installed inventory retains the locked row, normal reader
       candidates exclude it, and both public switches leave active module, category, `PageManager`,
       persistence count, and rendered scripts byte-for-byte unchanged. The outcome-returning API
       classifies the target `.requiresUnlock`; its `@discardableResult` sibling remains source-safe.
     - Failure meaning: A non-picker caller can bypass the passphrase workflow and restore the empty
       locked-reader regression from issue #389.
     - Side effects: Writes only the inherited temporary SWORD fixture and removes it through the
       test-case cleanup contract; no shared app module store is touched.
     */
    @MainActor
    func testLockedBibleDocumentSwitchRequiresUnlockBeforeAnyStateMutation() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "LOCKED",
            description: "Locked test Bible",
            in: modulePath
        )
        let configURL = URL(fileURLWithPath: modulePath)
            .appendingPathComponent("mods.d/locked.conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        XCTAssertEqual(manager.moduleAccessState(named: "LOCKED"), .locked)
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "KJV"
        pageManager.currentCategoryName = DocumentCategory.bible.pageManagerKey
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)
        XCTAssertTrue(controller.installedBibleModules.contains { $0.name == "LOCKED" })
        XCTAssertFalse(controller.readableBibleModules.contains { $0.name == "LOCKED" })
        XCTAssertTrue(controller.readableBibleModules.contains { $0.name == "KJV" })

        let baselineModuleName = controller.activeModuleName
        let baselineCategory = controller.currentCategory
        let baselineBibleDocument = pageManager.bibleDocument
        let baselineCategoryName = pageManager.currentCategoryName
        let baselineScriptCount = recordedScripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        let outcome = controller.switchBibleDocument(to: "LOCKED")
        controller.switchModule(to: "LOCKED")

        XCTAssertEqual(outcome, .requiresUnlock(moduleName: "LOCKED"))
        XCTAssertEqual(controller.activeModuleName, baselineModuleName)
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(pageManager.bibleDocument, baselineBibleDocument)
        XCTAssertEqual(pageManager.currentCategoryName, baselineCategoryName)
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(recordedScripts().count, baselineScriptCount)
    }

    /**
     Protects public quick-selector and full-document routes from activating locked auxiliaries.

     - Setup: Installs locked commentary, dictionary, general-book, and map descriptors, attaches a
       ready KJV pane with non-default persisted auxiliary selections, and invokes each category's
       module-only quick switch plus full document switch.
     - Expected result: Both commentary calls and all six generic calls fail while active handles,
       category, `PageManager`, persistence count, and bridge script count remain unchanged.
     - Failure meaning: A controller wrapper can bypass the coordinator's fresh readable preflight
       or interpret a rejected quick selection as a completed document change.
     - Side effects: Writes only inherited temporary fixtures and records in-memory pane callbacks.
     - Failure modes: Fixture discovery and filesystem failures throw through XCTest.
     */
    @MainActor
    func testLockedAuxiliaryQuickAndDocumentSwitchesLeaveReadablePaneUntouched() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawCommentaryModule(named: "LockedComm", in: modulePath)
        try seedEmptyRawDictionaryModule(named: "LockedDict", in: modulePath)
        try seedEmptyRawGeneralBookModule(named: "LockedGB", in: modulePath)
        try seedEmptyRawMapModule(named: "LockedMap", in: modulePath)
        for moduleName in ["LockedComm", "LockedDict", "LockedGB", "LockedMap"] {
            let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
                .appendingPathComponent("mods.d/\(moduleName.lowercased()).conf")
            var configuration = try String(contentsOf: configURL, encoding: .utf8)
            configuration.append("\nCipherKey=\n")
            try configuration.write(to: configURL, atomically: true, encoding: .utf8)
        }

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(
            id: window.id,
            currentCategoryName: DocumentCategory.bible.pageManagerKey
        )
        pageManager.bibleDocument = "KJV"
        pageManager.commentaryDocument = "BaselineComm"
        pageManager.dictionaryDocument = "BaselineDict"
        pageManager.dictionaryKey = "baseline-dictionary-key"
        pageManager.generalBookDocument = "BaselineGB"
        pageManager.generalBookKey = "baseline-general-book-key"
        pageManager.mapDocument = "BaselineMap"
        pageManager.mapKey = "baseline-map-key"
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.bridgeDidSetClientReady(bridge)

        let baselineModuleName = controller.activeModuleName
        let baselineCommentaryName = controller.activeCommentaryModuleName
        let baselineDictionaryName = controller.activeDictionaryModuleName
        let baselineGeneralBookName = controller.activeGeneralBookModuleName
        let baselineMapName = controller.activeMapModuleName
        let baselineCategory = controller.currentCategory
        let baselineScriptCount = recordedScripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        XCTAssertEqual(controller.switchCommentaryModule(to: "LockedComm"), .failed)
        XCTAssertEqual(controller.switchCommentaryDocument(to: "LockedComm"), .failed)
        let genericOutcomes = [
            controller.switchDictionaryModule(to: "LockedDict"),
            controller.switchDictionaryDocument(to: "LockedDict"),
            controller.switchGeneralBookModule(to: "LockedGB"),
            controller.switchGeneralBookDocument(to: "LockedGB"),
            controller.switchMapModule(to: "LockedMap"),
            controller.switchMapDocument(to: "LockedMap"),
        ]
        for outcome in genericOutcomes {
            guard case .failed = outcome else {
                XCTFail("Expected locked auxiliary switch to fail, received \(outcome).")
                continue
            }
        }

        XCTAssertEqual(controller.activeModuleName, baselineModuleName)
        XCTAssertEqual(controller.activeCommentaryModuleName, baselineCommentaryName)
        XCTAssertEqual(controller.activeDictionaryModuleName, baselineDictionaryName)
        XCTAssertEqual(controller.activeGeneralBookModuleName, baselineGeneralBookName)
        XCTAssertEqual(controller.activeMapModuleName, baselineMapName)
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(pageManager.bibleDocument, "KJV")
        XCTAssertEqual(pageManager.commentaryDocument, "BaselineComm")
        XCTAssertEqual(pageManager.dictionaryDocument, "BaselineDict")
        XCTAssertEqual(pageManager.dictionaryKey, "baseline-dictionary-key")
        XCTAssertEqual(pageManager.generalBookDocument, "BaselineGB")
        XCTAssertEqual(pageManager.generalBookKey, "baseline-general-book-key")
        XCTAssertEqual(pageManager.mapDocument, "BaselineMap")
        XCTAssertEqual(pageManager.mapKey, "baseline-map-key")
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.bible.pageManagerKey)
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(recordedScripts().count, baselineScriptCount)
    }

    /**
     Protects My Notes from being dismissed by locked or unavailable Bible-link destinations.

     - Setup: Opens My Notes over readable KJV, retains one inclusive locked Bible row, and builds
       forced-module OSIS links for that locked row and a missing identity.
     - Expected result: Both navigations return false while My Notes visibility, active Bible,
       persisted page category, and persistence count remain unchanged.
     - Failure meaning: A caller-owned mode transition ran before the shared access/category
       preflight, so a rejected link can partially mutate the visible reader.
     - Side effects: Writes only the inherited temporary SWORD fixture and opens an in-memory pending
       My Notes document without a ready WebView client.
     */
    @MainActor
    func testLockedAndUnavailableBibleLinksPreserveMyNotesState() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "LOCKED",
            description: "Locked test Bible",
            in: modulePath
        )
        let configURL = URL(fileURLWithPath: modulePath)
            .appendingPathComponent("mods.d/locked.conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: manager
        )
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }
        controller.loadMyNotesDocument()
        XCTAssertTrue(controller.showingMyNotes)
        persistCount = 0

        let lockedLink = OsisRef(
            book: "Genesis",
            chapter: 1,
            verse: 1,
            osisId: "Gen",
            targetBookInitials: "LOCKED"
        )
        let unavailableLink = OsisRef(
            book: "Genesis",
            chapter: 1,
            verse: 1,
            osisId: "Gen",
            targetBookInitials: "MISSING"
        )
        let baselineCategoryName = pageManager.currentCategoryName

        XCTAssertFalse(controller.navigateToBibleLink(lockedLink))
        XCTAssertTrue(controller.showingMyNotes)
        XCTAssertEqual(controller.activeModuleName, "KJV")
        XCTAssertEqual(pageManager.currentCategoryName, baselineCategoryName)
        XCTAssertEqual(persistCount, 0)

        XCTAssertFalse(controller.navigateToBibleLink(unavailableLink))
        XCTAssertTrue(controller.showingMyNotes)
        XCTAssertEqual(controller.activeModuleName, "KJV")
        XCTAssertEqual(pageManager.currentCategoryName, baselineCategoryName)
        XCTAssertEqual(persistCount, 0)
    }

    /**
     Verifies a readable forced-module Bible link leaves My Notes at the coordinator commit edge.

     - Setup: Opens My Notes over KJV and targets a second readable real SWORD Bible alias.
     - Expected result: Link navigation succeeds, clears My Notes before persistence, activates and
       persists the target Bible/category, and leaves no partially prepared state.
     - Failure meaning: The post-preflight preparation callback was omitted, invoked too late, or
       invoked only for failure paths.
     - Side effects: Writes only the inherited temporary SWORD fixture and mutates an in-memory pane;
       the WebView client remains unready so no bridge rendering occurs.
     */
    @MainActor
    func testReadableBibleLinkClearsMyNotesBeforeSwitchPersistence() throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "WEB",
            description: "World English Bible",
            in: modulePath
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(
            bridge: BibleBridge(),
            swordManagerOverride: manager
        )
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.loadMyNotesDocument()
        XCTAssertTrue(controller.showingMyNotes)
        var myNotesStateAtPersistence: [Bool] = []
        controller.onPersistState = {
            myNotesStateAtPersistence.append(controller.showingMyNotes)
        }

        let readableLink = OsisRef(
            book: "Genesis",
            chapter: 1,
            verse: 1,
            osisId: "Gen",
            targetBookInitials: "WEB"
        )

        XCTAssertTrue(controller.navigateToBibleLink(readableLink))
        XCTAssertFalse(controller.showingMyNotes)
        XCTAssertEqual(controller.activeModuleName, "WEB")
        XCTAssertEqual(pageManager.bibleDocument, "WEB")
        XCTAssertEqual(pageManager.currentCategoryName, DocumentCategory.bible.pageManagerKey)
        XCTAssertFalse(myNotesStateAtPersistence.isEmpty)
        XCTAssertTrue(myNotesStateAtPersistence.allSatisfy { !$0 })
    }

    /**
     Protects the controller-level Bible switch API from accepting non-Bible modules.

     The quick selector and module picker currently pass Bible-filtered rows, but
     `BibleReaderController.switchBibleDocument(to:)` and `switchModule(to:)` are public controller
     APIs and mirror Android Bible transitions only for Bible documents. A non-Bible SWORD module
     must therefore return `.unavailable` and leave the active Bible, document category,
     `PageManager` state, persistence callbacks, and render state unchanged. A failure means an
     accidental non-Bible caller can corrupt pane state with a commentary/dictionary module name.
     */
    @MainActor
    func testBibleDocumentSwitchRejectsNonBibleModulesWithoutStateMutation() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawCommentaryModule(in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        controller.switchCategory(to: .commentary)
        let baselineCategory = controller.currentCategory
        let baselineBibleModuleName = controller.activeModuleName
        let baselineBibleDocument = pageManager.bibleDocument
        let baselineCategoryName = pageManager.currentCategoryName
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        let documentOutcome = controller.switchBibleDocument(to: "UITestComm")
        let moduleOutcome = controller.switchModule(to: "UITestComm")

        XCTAssertEqual(documentOutcome, .unavailable)
        XCTAssertEqual(moduleOutcome, .unavailable)
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(controller.activeModuleName, baselineBibleModuleName)
        XCTAssertEqual(pageManager.bibleDocument, baselineBibleDocument)
        XCTAssertEqual(pageManager.currentCategoryName, baselineCategoryName)
        XCTAssertEqual(persistCount, 0)
    }

    /**
     Protects the Bible switch API from activating a module with an unrecognized versification.

     `switchBibleDocument(to:)` is public controller API reachable beyond the versification-filtered
     picker (bridge, next/previous cycling, restore). A module whose versification SWORD cannot map
     must not become the active Bible — it would render mis-numbered under KJV — so the switch leaves
     the active Bible, category, PageManager state, and persistence untouched. See ADR-0010.
     */
    @MainActor
    func testBibleDocumentSwitchRejectsUnknownVersificationModuleWithoutStateMutation() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(named: "BOGUS", description: "Bogus Versification Bible", in: modulePath)
        let bogusConf = URL(fileURLWithPath: modulePath).appendingPathComponent("mods.d/bogus.conf")
        var conf = try String(contentsOf: bogusConf, encoding: .utf8)
        conf = conf.replacingOccurrences(of: "Versification=KJV", with: "Versification=BogusV11n")
        try conf.write(to: bogusConf, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        let baselineBibleModuleName = controller.activeModuleName
        let baselineBibleDocument = pageManager.bibleDocument
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.switchBibleDocument(to: "BOGUS")

        XCTAssertNotEqual(controller.activeModuleName, "BOGUS", "An unknown-versification module must not become the active Bible.")
        XCTAssertEqual(controller.activeModuleName, baselineBibleModuleName)
        XCTAssertEqual(pageManager.bibleDocument, baselineBibleDocument)
        XCTAssertEqual(persistCount, 0)
    }

    /**
     Protects the module-only Bible switch API from activating an unknown-versification module.

     `switchModule(to:)` changes the Bible without changing the visible category and, like
     `switchBibleDocument(to:)`, is public controller API reachable beyond the versification-filtered
     picker. A module whose versification SWORD cannot map must not become the active Bible. See
     ADR-0010.
     */
    @MainActor
    func testBibleModuleSwitchRejectsUnknownVersificationModuleWithoutStateMutation() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(named: "BOGUS", description: "Bogus Versification Bible", in: modulePath)
        let bogusConf = URL(fileURLWithPath: modulePath).appendingPathComponent("mods.d/bogus.conf")
        var conf = try String(contentsOf: bogusConf, encoding: .utf8)
        conf = conf.replacingOccurrences(of: "Versification=KJV", with: "Versification=BogusV11n")
        try conf.write(to: bogusConf, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        window.pageManager = pageManager
        controller.activeWindow = window
        let baselineBibleModuleName = controller.activeModuleName
        let baselineBibleDocument = pageManager.bibleDocument
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.switchModule(to: "BOGUS")

        XCTAssertNotEqual(controller.activeModuleName, "BOGUS", "An unknown-versification module must not become the active Bible.")
        XCTAssertEqual(controller.activeModuleName, baselineBibleModuleName)
        XCTAssertEqual(pageManager.bibleDocument, baselineBibleDocument)
        XCTAssertEqual(persistCount, 0)
    }

    /**
     Protects position restore from activating a persisted unknown-versification Bible.

     `restoreSavedPosition` reads `PageManager.bibleDocument`, which a pre-gate release or a synced
     workspace may set to an unknown-versification module. Restoring it would make it the active
     Bible (rendered mis-numbered under KJV); instead the gated active module chosen during SWORD
     configuration (here KJV) must remain. See ADR-0010.
     */
    @MainActor
    func testRestoreSavedPositionSkipsPersistedUnknownVersificationBible() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(named: "BOGUS", description: "Bogus Versification Bible", in: modulePath)
        let bogusConf = URL(fileURLWithPath: modulePath).appendingPathComponent("mods.d/bogus.conf")
        var conf = try String(contentsOf: bogusConf, encoding: .utf8)
        conf = conf.replacingOccurrences(of: "Versification=KJV", with: "Versification=BogusV11n")
        try conf.write(to: bogusConf, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        // The supported KJV is active after configuration.
        XCTAssertEqual(controller.activeModuleName, "KJV")

        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "BOGUS"
        window.pageManager = pageManager
        controller.activeWindow = window

        controller.restoreSavedPosition()

        XCTAssertEqual(controller.activeModuleName, "KJV", "A persisted unknown-versification Bible must not be restored as active.")
        XCTAssertEqual(controller.activeModule?.info.name, "KJV")
    }

    /**
     Protects pane restoration from replacing a readable fallback with a persisted locked Bible.

     - Setup: Configures the reader with plain KJV plus an encrypted empty-key Bible, then restores a
       `PageManager` whose saved Bible identity names the locked module.
     - Expected result: KJV remains active, the locked saved identity is preserved for a future
       app-owned unlock workflow, and restore performs no normalization persistence.
     - Failure meaning: Session restore can bypass the shared activation preflight or erase the user's
       locked selection before they have a chance to unlock it.
     - Side effects: Writes only the temporary SWORD fixture and records persistence callbacks.
     */
    @MainActor
    func testRestoreSavedPositionKeepsReadableFallbackForPersistedLockedBible() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "LOCKED",
            description: "Locked test Bible",
            in: modulePath
        )
        let configURL = URL(fileURLWithPath: modulePath)
            .appendingPathComponent("mods.d/locked.conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        XCTAssertEqual(controller.activeModuleName, "KJV")
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.bibleDocument = "LOCKED"
        window.pageManager = pageManager
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.restoreSavedPosition()

        XCTAssertEqual(controller.activeModuleName, "KJV")
        XCTAssertEqual(controller.activeModule?.info.name, "KJV")
        XCTAssertEqual(pageManager.bibleDocument, "LOCKED")
        XCTAssertEqual(persistCount, 0)
    }

    /**
     Prevents persisted auxiliary selections from reactivating relocked native content handles.

     - Setup: Installs locked commentary, dictionary, general-book, and map rows, attaches a page
       manager that persisted every row and its category-owned key, then restores the pane.
     - Expected result: Each requested identity remains available for a later unlock retry, but all
       four native content handles stay nil; only non-sensitive general-book/map keys remain staged.
     - Failure meaning: The post-configuration restore path has bypassed the shared readable-source
       resolver and reopened encrypted content after relaunch or pane reconstruction.
     - Side effects: Writes isolated SWORD fixture descriptors and records persistence callbacks;
       inherited teardown removes the temporary module root.
     */
    @MainActor
    func testRestoreSavedPositionPreservesLockedAuxiliarySelectionsWithoutActivatingHandles() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawCommentaryModule(named: "LockedComm", in: modulePath)
        try seedEmptyRawDictionaryModule(named: "LockedDict", in: modulePath)
        try seedEmptyRawGeneralBookModule(named: "LockedGB", in: modulePath)
        try seedEmptyRawMapModule(named: "LockedMap", in: modulePath)
        for moduleName in ["LockedComm", "LockedDict", "LockedGB", "LockedMap"] {
            let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
                .appendingPathComponent("mods.d/\(moduleName.lowercased()).conf")
            var configuration = try String(contentsOf: configURL, encoding: .utf8)
            configuration.append("\nCipherKey=\n")
            try configuration.write(to: configURL, atomically: true, encoding: .utf8)
        }

        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.commentaryDocument = "LockedComm"
        pageManager.dictionaryDocument = "LockedDict"
        pageManager.dictionaryKey = "locked-dictionary-key"
        pageManager.generalBookDocument = "LockedGB"
        pageManager.generalBookKey = "locked-general-book-key"
        pageManager.mapDocument = "LockedMap"
        pageManager.mapKey = "locked-map-key"
        window.pageManager = pageManager
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.restoreSavedPosition()

        XCTAssertNil(controller.activeCommentaryModule)
        XCTAssertEqual(controller.activeCommentaryModuleName, "LockedComm")
        XCTAssertNil(controller.activeDictionaryModule)
        XCTAssertEqual(controller.activeDictionaryModuleName, "LockedDict")
        XCTAssertNil(controller.currentDictionaryKey)
        XCTAssertNil(controller.activeGeneralBookModule)
        XCTAssertEqual(controller.activeGeneralBookModuleName, "LockedGB")
        XCTAssertEqual(controller.currentGeneralBookKey, "locked-general-book-key")
        XCTAssertNil(controller.activeMapModule)
        XCTAssertEqual(controller.activeMapModuleName, "LockedMap")
        XCTAssertEqual(controller.currentMapKey, "locked-map-key")
        XCTAssertEqual(pageManager.commentaryDocument, "LockedComm")
        XCTAssertEqual(pageManager.dictionaryDocument, "LockedDict")
        XCTAssertEqual(pageManager.dictionaryKey, "locked-dictionary-key")
        XCTAssertEqual(pageManager.generalBookDocument, "LockedGB")
        XCTAssertEqual(pageManager.mapDocument, "LockedMap")
        XCTAssertEqual(persistCount, 0)
    }

    /**
     Seeds one readable dictionary entry so a stale key is an ordinary exact-key miss.

     - Parameters:
       - moduleName: SWORD module initials to publish through the inherited fixture helper.
       - entryKey: Exact key written to the RawLD record.
       - modulePath: Temporary SWORD root that receives the module files.
     - Side effects: Creates a dictionary module and replaces its empty data/index files with one
       valid RawLD record.
     - Failure modes: Propagates fixture filesystem errors and fails when the record exceeds RawLD's
       two-byte length field.
     */
    private func seedReadableRawDictionaryModule(
        named moduleName: String,
        entryKey: String,
        in modulePath: String
    ) throws {
        try seedEmptyRawDictionaryModule(named: moduleName, in: modulePath)

        let moduleKey = moduleName.lowercased()
        let prefix = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("modules/lexdict/rawld/\(moduleKey)/\(moduleKey)")
        let record = Data("\(entryKey)\r\n<div type=\"entry\">Readable fixture</div>".utf8)
        var recordLength = try XCTUnwrap(UInt16(exactly: record.count)).littleEndian
        var index = Data([0, 0, 0, 0])
        withUnsafeBytes(of: &recordLength) { index.append(contentsOf: $0) }
        var data = record
        data.append(0x0A)

        try data.write(to: prefix.appendingPathExtension("dat"))
        try index.write(to: prefix.appendingPathExtension("idx"))
    }
}
