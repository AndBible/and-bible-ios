// AIReaderWindowDocumentRouterTests.swift -- Fail-closed AI reader document routing

import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/** Protects live-pane AI routing from bypassing reader module activation preflights. */
@MainActor
final class AIReaderWindowDocumentRouterTests: BibleUISwordFixtureTestCase {
    /**
     Routes a local full-name/case alias through the canonical combined-registry owner.

     - Setup: Registers one My Documents page and a live empty pane, then calls the production
       router directly with a case-varied display name rather than initials.
     - Expected: The exact page renders and observed/persisted state reports canonical initials.
     - Failure meaning: The Agent preflight and live router use different JSword lookup tiers, or
       the router reuses the alias for exact local storage reads.
     - Side effects: Writes in-memory workspace/My Documents graphs and emits one reader document.
     */
    func testMyDocumentFullNameAliasRoutesWithCanonicalInitials() async throws {
        let myDocumentContainer = try makeMyDocumentModelContainer()
        let myDocumentContext = myDocumentContainer.mainContext
        let document = MyDocument(name: "Router Local Full Name", initials: "RouterLocal")
        let page = MyDocumentPage(title: "Entry", pageKey: "entry", contentType: .markdown)
        let content = MyDocumentPageContent(pageId: page.id, content: "Canonical route")
        page.pageContent = content
        page.document = document
        document.pages = [page]
        myDocumentContext.insert(document)
        myDocumentContext.insert(page)
        myDocumentContext.insert(content)
        try myDocumentContext.save()

        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "AI local alias route")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)
        let store = MyDocumentStore(modelContext: myDocumentContext)
        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        controller.myDocumentStore = store
        controller.activeWindow = window
        windowManager.registerController(controller, for: window.id)
        let router = AIReaderWindowDocumentRouter(
            windowManager: windowManager,
            myDocumentStore: store
        )

        let observed = try await router.setDocument(
            windowID: window.id,
            documentInitials: "router local full name",
            key: "entry"
        )

        XCTAssertEqual(observed.documentInitials, "RouterLocal")
        XCTAssertEqual(observed.currentKey, "entry")
        XCTAssertEqual(window.pageManager?.generalBookDocument, "RouterLocal")
        XCTAssertEqual(window.pageManager?.generalBookKey, "entry")
    }

    /**
     Verifies a locked Bible plus reference cannot navigate the currently active readable Bible.

     - Setup: Registers a ready KJV pane beside an installed encrypted Bible, then asks the
       production AI router to open the locked module at John 3:16.
     - Expected result: Routing throws the stable credential-free `NAVIGATION_FAILED` error before
       changing location, module, category, pane persistence, callbacks, or bridge emissions.
     - Failure meaning: An AI document request can ignore `.requiresUnlock` and apply its key to the
       previously active Bible, creating a partial cross-document navigation.
     - Side effects: Creates isolated in-memory workspace/My Documents stores and a temporary SWORD
       fixture removed by the inherited cleanup contract.
     */
    func testLockedBibleWithKeyFailsBeforeNavigationOrPaneMutation() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedBibleAliasModule(
            named: "LOCKED",
            description: "Locked AI router Bible",
            in: modulePath
        )
        let configURL = URL(fileURLWithPath: modulePath)
            .appendingPathComponent("mods.d/locked.conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "AI router lock preflight")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)

        let (bridge, recordedScripts) = makeRecordingBridge()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.activeWindow = window
        window.pageManager?.bibleDocument = "KJV"
        window.pageManager?.currentCategoryName = DocumentCategory.bible.pageManagerKey
        windowManager.registerController(controller, for: window.id)
        controller.bridgeDidSetClientReady(bridge)
        XCTAssertEqual(manager.moduleAccessState(named: "LOCKED"), .locked)

        let myDocumentContainer = try makeMyDocumentModelContainer()
        let router = AIReaderWindowDocumentRouter(
            windowManager: windowManager,
            myDocumentStore: MyDocumentStore(modelContext: myDocumentContainer.mainContext)
        )
        let baselineModule = controller.activeModuleName
        let baselineCategory = controller.currentCategory
        let baselineBook = controller.currentBook
        let baselineChapter = controller.currentChapter
        let baselineVerse = controller.currentVerse
        let baselineBibleDocument = window.pageManager?.bibleDocument
        let baselineCategoryName = window.pageManager?.currentCategoryName
        let baselineScriptCount = recordedScripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        do {
            _ = try await router.setDocument(
                windowID: window.id,
                documentInitials: "LOCKED",
                key: "John.3.16"
            )
            XCTFail("Expected locked Bible routing to fail before key navigation.")
        } catch let error as BibleUIAgentDomainError {
            XCTAssertEqual(error.code, "NAVIGATION_FAILED")
            XCTAssertEqual(error.message, "The requested document could not be opened.")
        }

        XCTAssertEqual(controller.activeModuleName, baselineModule)
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(controller.currentBook, baselineBook)
        XCTAssertEqual(controller.currentChapter, baselineChapter)
        XCTAssertEqual(controller.currentVerse, baselineVerse)
        XCTAssertEqual(window.pageManager?.bibleDocument, baselineBibleDocument)
        XCTAssertEqual(window.pageManager?.currentCategoryName, baselineCategoryName)
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(recordedScripts().count, baselineScriptCount)
    }

    /**
     Verifies locked commentary authorization runs before the AI route applies its requested key.

     - Setup: Registers a ready KJV pane beside an installed plaintext-backed but locked commentary,
       then asks the production AI router to open that commentary at John 3:16.
     - Expected result: Routing throws `NAVIGATION_FAILED` before changing the readable Bible's
       location, active commentary/category, `PageManager`, persistence count, or bridge emissions.
     - Failure meaning: Commentary routing can navigate the previously active source first and only
       discover afterward that the requested document was not authorized.
     - Side effects: Creates isolated in-memory workspace/My Documents stores and one temporary
       SWORD fixture removed by inherited teardown.
     - Failure modes: Fixture, SwiftData, or manager setup failures throw through XCTest.
     */
    func testLockedCommentaryWithKeyFailsBeforeNavigationOrPaneMutation() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawCommentaryModule(named: "LockedComm", in: modulePath)
        let configURL = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mods.d/lockedcomm.conf")
        var configuration = try String(contentsOf: configURL, encoding: .utf8)
        configuration.append("\nCipherKey=\n")
        try configuration.write(to: configURL, atomically: true, encoding: .utf8)

        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "AI commentary lock preflight")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)

        let (bridge, recordedScripts) = makeRecordingBridge()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.activeWindow = window
        window.pageManager?.bibleDocument = "KJV"
        window.pageManager?.currentCategoryName = DocumentCategory.bible.pageManagerKey
        windowManager.registerController(controller, for: window.id)
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)
        XCTAssertEqual(manager.moduleAccessState(named: "LockedComm"), .locked)

        let myDocumentContainer = try makeMyDocumentModelContainer()
        let router = AIReaderWindowDocumentRouter(
            windowManager: windowManager,
            myDocumentStore: MyDocumentStore(modelContext: myDocumentContainer.mainContext)
        )
        let baselineModule = controller.activeModuleName
        let baselineCommentary = controller.activeCommentaryModuleName
        let baselineCategory = controller.currentCategory
        let baselineBook = controller.currentBook
        let baselineChapter = controller.currentChapter
        let baselineVerse = controller.currentVerse
        let baselineBibleDocument = window.pageManager?.bibleDocument
        let baselineCommentaryDocument = window.pageManager?.commentaryDocument
        let baselineCategoryName = window.pageManager?.currentCategoryName
        let baselineScriptCount = recordedScripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }

        do {
            _ = try await router.setDocument(
                windowID: window.id,
                documentInitials: "LockedComm",
                key: "John.3.16"
            )
            XCTFail("Expected locked commentary routing to fail before key navigation.")
        } catch let error as BibleUIAgentDomainError {
            XCTAssertEqual(error.code, "NAVIGATION_FAILED")
            XCTAssertEqual(error.message, "The requested document could not be opened.")
        }

        XCTAssertEqual(controller.activeModuleName, baselineModule)
        XCTAssertEqual(controller.activeCommentaryModuleName, baselineCommentary)
        XCTAssertEqual(controller.currentCategory, baselineCategory)
        XCTAssertEqual(controller.currentBook, baselineBook)
        XCTAssertEqual(controller.currentChapter, baselineChapter)
        XCTAssertEqual(controller.currentVerse, baselineVerse)
        XCTAssertEqual(window.pageManager?.bibleDocument, baselineBibleDocument)
        XCTAssertEqual(window.pageManager?.commentaryDocument, baselineCommentaryDocument)
        XCTAssertEqual(window.pageManager?.currentCategoryName, baselineCategoryName)
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(recordedScripts().count, baselineScriptCount)
    }

    /**
     Preflights invalid optional keys for every Android-routable installed document category.

     - Setup: Registers readable Bible, commentary, dictionary, general-book, and map fixtures in one
       live KJV pane, then requests an invalid reference/key for each through the production router.
     - Expected: Every request reports `KEY_NOT_FOUND` before changing any category-owned handle,
       key/reference, PageManager field, persistence count, or Vue emission.
     - Failure meaning: `setDocument` switches or persists a requested source before proving its
       optional key, leaving a partially changed window when the second navigation step fails.
     - Side effects: Writes inherited temporary SWORD fixtures plus isolated in-memory workspace and
       My Documents graphs.
     */
    func testInvalidInstalledKeysFailAcrossAndroidCategoryMatrixBeforeAnyPaneMutation() async throws {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedEmptyRawCommentaryModule(named: "RouterCommentary", in: modulePath)
        try seedEmptyRawDictionaryModule(named: "RouterDictionary", in: modulePath)
        try seedEmptyRawGeneralBookModule(named: "RouterGeneralBook", in: modulePath)
        try seedEmptyRawMapModule(named: "RouterMap", in: modulePath)
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))

        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "AI key preflight matrix")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.activeWindow = window
        window.pageManager?.bibleDocument = "KJV"
        window.pageManager?.currentCategoryName = DocumentCategory.bible.pageManagerKey
        windowManager.registerController(controller, for: window.id)
        controller.navigateTo(book: "Genesis", chapter: 1, verse: 1)
        controller.bridgeDidSetClientReady(bridge)

        let myDocumentContainer = try makeMyDocumentModelContainer()
        let router = AIReaderWindowDocumentRouter(
            windowManager: windowManager,
            myDocumentStore: MyDocumentStore(modelContext: myDocumentContainer.mainContext)
        )
        let baselineModule = controller.activeModuleName
        let baselineCommentary = controller.activeCommentaryModuleName
        let baselineDictionary = controller.activeDictionaryModuleName
        let baselineGeneralBook = controller.activeGeneralBookModuleName
        let baselineMap = controller.activeMapModuleName
        let baselineDictionaryKey = controller.currentDictionaryKey
        let baselineGeneralBookKey = controller.currentGeneralBookKey
        let baselineMapKey = controller.currentMapKey
        let baselineCategory = controller.currentCategory
        let baselineBook = controller.currentBook
        let baselineChapter = controller.currentChapter
        let baselineVerse = controller.currentVerse
        let pageManager = try XCTUnwrap(window.pageManager)
        let baselinePageCategory = pageManager.currentCategoryName
        let baselinePageBible = pageManager.bibleDocument
        let baselinePageCommentary = pageManager.commentaryDocument
        let baselinePageDictionary = pageManager.dictionaryDocument
        let baselinePageDictionaryKey = pageManager.dictionaryKey
        let baselinePageGeneralBook = pageManager.generalBookDocument
        let baselinePageGeneralBookKey = pageManager.generalBookKey
        let baselinePageMap = pageManager.mapDocument
        let baselinePageMapKey = pageManager.mapKey
        let baselineScripts = recordedScripts().count
        var persistCount = 0
        controller.onPersistState = { persistCount += 1 }
        let requests = [
            ("KJV", "Gen.999.1"),
            ("RouterCommentary", "Gen.999.1"),
            ("RouterDictionary", "missing-dictionary-key"),
            ("RouterGeneralBook", "missing-general-book-key"),
            ("RouterMap", "missing-map-key"),
        ]

        for (initials, key) in requests {
            do {
                _ = try await router.setDocument(
                    windowID: window.id,
                    documentInitials: initials,
                    key: key
                )
                XCTFail("Expected optional key preflight to reject \(initials).")
            } catch let error as BibleUIAgentDomainError {
                XCTAssertEqual(error.code, "KEY_NOT_FOUND", initials)
            }

            XCTAssertEqual(controller.activeModuleName, baselineModule, initials)
            XCTAssertEqual(controller.activeCommentaryModuleName, baselineCommentary, initials)
            XCTAssertEqual(controller.activeDictionaryModuleName, baselineDictionary, initials)
            XCTAssertEqual(controller.activeGeneralBookModuleName, baselineGeneralBook, initials)
            XCTAssertEqual(controller.activeMapModuleName, baselineMap, initials)
            XCTAssertEqual(controller.currentDictionaryKey, baselineDictionaryKey, initials)
            XCTAssertEqual(controller.currentGeneralBookKey, baselineGeneralBookKey, initials)
            XCTAssertEqual(controller.currentMapKey, baselineMapKey, initials)
            XCTAssertEqual(controller.currentCategory, baselineCategory, initials)
            XCTAssertEqual(controller.currentBook, baselineBook, initials)
            XCTAssertEqual(controller.currentChapter, baselineChapter, initials)
            XCTAssertEqual(controller.currentVerse, baselineVerse, initials)
            XCTAssertEqual(pageManager.currentCategoryName, baselinePageCategory, initials)
            XCTAssertEqual(pageManager.bibleDocument, baselinePageBible, initials)
            XCTAssertEqual(pageManager.commentaryDocument, baselinePageCommentary, initials)
            XCTAssertEqual(pageManager.dictionaryDocument, baselinePageDictionary, initials)
            XCTAssertEqual(pageManager.dictionaryKey, baselinePageDictionaryKey, initials)
            XCTAssertEqual(pageManager.generalBookDocument, baselinePageGeneralBook, initials)
            XCTAssertEqual(pageManager.generalBookKey, baselinePageGeneralBookKey, initials)
            XCTAssertEqual(pageManager.mapDocument, baselinePageMap, initials)
            XCTAssertEqual(pageManager.mapKey, baselinePageMapKey, initials)
            XCTAssertEqual(persistCount, 0, initials)
            XCTAssertEqual(recordedScripts().count, baselineScripts, initials)
        }
    }
}
