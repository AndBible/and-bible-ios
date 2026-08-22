// AIReaderWindowDocumentRouterTests.swift -- Fail-closed AI reader document routing

import Foundation
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import SwordKit

/** Protects live-pane AI routing from bypassing reader module activation preflights. */
@MainActor
final class AIReaderWindowDocumentRouterTests: BibleUISwordFixtureTestCase {
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
}
