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

        controller.switchBibleDocument(to: "UITestComm")

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
