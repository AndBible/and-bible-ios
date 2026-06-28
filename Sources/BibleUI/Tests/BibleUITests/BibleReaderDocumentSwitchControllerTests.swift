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
        let modulePath = try makeTemporaryBundledSwordPath()
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
        let modulePath = try makeTemporaryBundledSwordPath()
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
        let modulePath = try makeTemporaryBundledSwordPath()
        try seedEmptyRawDictionaryModule(named: "UITestDict", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        let window = Window()
        let pageManager = PageManager(id: window.id)
        pageManager.dictionaryKey = "stale-key"
        window.pageManager = pageManager
        controller.activeWindow = window
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        controller.switchDictionaryDocument(to: "UITestDict")

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
        let modulePath = try makeTemporaryBundledSwordPath()
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

        controller.switchGeneralBookDocument(to: "UITestGB")

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
        let modulePath = try makeTemporaryBundledSwordPath()
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

        controller.switchMapDocument(to: "UITestMap")

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
        let modulePath = try makeTemporaryBundledSwordPath()
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
     Protects the controller-level Bible switch API from accepting non-Bible modules.

     The quick selector and module picker currently pass Bible-filtered rows, but
     `BibleReaderController.switchBibleDocument(to:)` is public controller API and mirrors Android's
     current-document transition only for Bible documents. A non-Bible SWORD module must therefore
     leave the active Bible, document category, PageManager state, and persistence callbacks
     unchanged. A failure means an accidental non-Bible caller can corrupt pane state by forcing the
     reader into Bible mode with a commentary/dictionary module name.
     */
    @MainActor
    func testBibleDocumentSwitchRejectsNonBibleModulesWithoutStateMutation() throws {
        let (bridge, _) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
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

        controller.switchBibleDocument(to: "UITestComm")

        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(controller.activeModuleName, baselineBibleModuleName)
        XCTAssertEqual(pageManager.bibleDocument, baselineBibleDocument)
        XCTAssertEqual(pageManager.currentCategoryName, baselineCategoryName)
        XCTAssertEqual(persistCount, 0)
    }
}
