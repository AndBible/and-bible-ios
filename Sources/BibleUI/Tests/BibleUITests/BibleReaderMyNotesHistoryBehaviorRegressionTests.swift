import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

final class BibleReaderMyNotesHistoryBehaviorRegressionTests: BibleUISwordFixtureTestCase {
    private struct Fixture {
        let container: ModelContainer
        let store: WorkspaceStore
        let window: Window
        let manager: WindowManager
        let bridge: BibleBridge
        let scripts: () -> [String]
        let controller: BibleReaderController
        let module: SwordModule
    }

    /** A visible row refreshes the accepted anchor used by the next settings/content reload. */
    @MainActor
    func testVisibleSourceSpanRowOwnsReloadJump() async throws {
        let f = try await fixture("My Notes anchor reload")
        f.controller.switchModule(to: "VulgTest")
        XCTAssertTrue(f.controller.navigateTo(book: "Psalms", chapter: 10, verse: 1))
        let boundary = f.scripts().count
        f.controller.loadMyNotesDocument()
        _ = try await awaitBridgeEmission(
            from: f.scripts,
            event: "add_documents",
            after: boundary
        )
        let kjvaPsalmElevenTwo = try kjva("Ps", 11, 2)
        f.controller.bridge(
            f.bridge,
            didScrollToOrdinal: kjvaPsalmElevenTwo,
            key: "Ps.11.2",
            atChapterTop: false
        )
        let reloadBoundary = f.scripts().count
        f.controller.loadCurrentContent()
        let emitted = try await awaitBridgeEmission(
            from: f.scripts,
            event: "setup_content",
            after: reloadBoundary
        )
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emitted, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(setup["jumpToOrdinal"] as? Int, 14_571)
        XCTAssertEqual(f.controller.currentChapter, 10)
        XCTAssertEqual(f.controller.currentVerse, 3)
        XCTAssertEqual(f.window.pageManager?.bibleVerseNo, 3)
        withExtendedLifetime(f.container) {}
    }

    /** Same- and different-document Bible restores each record the exact page left once. */
    @MainActor
    func testBibleHistoryRestoreRecordsPriorPositionExactlyOnce() async throws {
        let f = try await fixture("Bible history restore")
        XCTAssertTrue(f.controller.navigateTo(book: "Matthew", chapter: 2, verse: 3))
        XCTAssertTrue(
            f.controller.navigateToHistoryTarget(
                document: "KJV",
                key: "Mark.1.1",
                anchorOrdinal: nil
            )
        )
        XCTAssertEqual(
            f.store.history(windowId: f.window.id).filter { $0.key == "Matt.2.3" }.count,
            1
        )
        XCTAssertTrue(
            f.controller.navigateToHistoryTarget(
                document: "VulgTest",
                key: "Ps.10.1",
                anchorOrdinal: nil
            )
        )
        let history = f.store.history(windowId: f.window.id)
        XCTAssertEqual(
            history.filter { $0.document == "KJV" && $0.key == "Mark.1.1" }.count,
            1
        )
        XCTAssertEqual(f.controller.currentBook, "Psalms")
        XCTAssertEqual(f.controller.currentChapter, 10)
        withExtendedLifetime(f.container) {}
    }

    /** Bible history exits My Notes, while a MyNote row restores notes with its exact anchor. */
    @MainActor
    func testHistoryExitsAndRestoresMyNotesWithValidAnchor() async throws {
        let f = try await fixture("My Notes history restore")
        let matthewFive = try kjva("Matt", 1, 5)
        try await open(f, matthewFive)
        XCTAssertTrue(
            f.controller.navigateToHistoryTarget(
                document: "KJV",
                key: "Gen.2.1",
                anchorOrdinal: nil
            )
        )
        XCTAssertFalse(f.controller.showingMyNotes)
        XCTAssertEqual(
            f.store.history(windowId: f.window.id).filter {
                $0.document == "MyNote" && $0.key == "Matt.1.5"
            }.count,
            1
        )
        let boundary = f.scripts().count
        XCTAssertTrue(
            f.controller.navigateToHistoryTarget(
                document: "MyNote",
                key: "Matt.1.5",
                anchorOrdinal: matthewFive
            )
        )
        let emitted = try await awaitBridgeEmission(
            from: f.scripts,
            event: "setup_content",
            after: boundary
        )
        let setup = try XCTUnwrap(
            bridgeEmissionPayload(from: emitted, event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(setup["jumpToOrdinal"] as? Int, matthewFive)
        XCTAssertTrue(f.controller.showingMyNotes)
        XCTAssertEqual(f.controller.currentVerse, 5)
        withExtendedLifetime(f.container) {}
    }

    /** A reader without a configured persistence store retains standalone in-memory navigation. */
    @MainActor
    func testStandaloneNavigationDoesNotRequireWorkspaceHistoryAdmission() async throws {
        let f = try await fixture("Standalone navigation")
        f.controller.workspaceStore = nil

        XCTAssertTrue(f.controller.navigateTo(book: "Matthew", chapter: 2, verse: 3))
        XCTAssertEqual(f.controller.currentBook, "Matthew")
        XCTAssertEqual(f.controller.currentChapter, 2)
        XCTAssertEqual(f.controller.currentVerse, 3)
        withExtendedLifetime(f.container) {}
    }

    /** Workspace-backed direct navigation rejects a store that does not own the managed window. */
    @MainActor
    func testDirectNavigationRejectsForeignPersistenceOwnerBeforeMutation() async throws {
        let f = try await fixture("Foreign direct-history owner")
        let foreignContainer = try makeWorkspaceModelContainer()
        let foreignStore = WorkspaceStore(modelContext: foreignContainer.mainContext)
        f.controller.workspaceStore = foreignStore
        let pageManager = try XCTUnwrap(f.window.pageManager)
        let previousDocument = pageManager.bibleDocument
        let previousBook = pageManager.bibleBibleBook
        let previousChapter = pageManager.bibleChapterNo
        let previousVerse = pageManager.bibleVerseNo
        let scriptBoundary = f.scripts().count

        XCTAssertFalse(f.controller.navigateTo(book: "Matthew", chapter: 2, verse: 3))
        XCTAssertEqual(f.controller.currentBook, "Genesis")
        XCTAssertEqual(f.controller.currentChapter, 1)
        XCTAssertEqual(f.controller.currentVerse, 1)
        XCTAssertEqual(pageManager.bibleDocument, previousDocument)
        XCTAssertEqual(pageManager.bibleBibleBook, previousBook)
        XCTAssertEqual(pageManager.bibleChapterNo, previousChapter)
        XCTAssertEqual(pageManager.bibleVerseNo, previousVerse)
        XCTAssertEqual(f.scripts().count, scriptBoundary)
        XCTAssertTrue(f.store.history(windowId: f.window.id).isEmpty)
        XCTAssertTrue(foreignStore.history(windowId: f.window.id).isEmpty)
        withExtendedLifetime((f.container, foreignContainer)) {}
    }

    /** A rejected history owner cannot half-switch the active document before returning false. */
    @MainActor
    func testHistoryRestoreRejectsForeignPersistenceOwnerBeforeDocumentSwitch() async throws {
        let f = try await fixture("Foreign restore-history owner")
        let foreignContainer = try makeWorkspaceModelContainer()
        let foreignStore = WorkspaceStore(modelContext: foreignContainer.mainContext)
        f.controller.workspaceStore = foreignStore
        let pageManager = try XCTUnwrap(f.window.pageManager)
        let previousDocument = pageManager.bibleDocument
        let previousBook = pageManager.bibleBibleBook
        let previousChapter = pageManager.bibleChapterNo
        let previousVerse = pageManager.bibleVerseNo
        let scriptBoundary = f.scripts().count

        XCTAssertFalse(
            f.controller.navigateToHistoryTarget(
                document: "VulgTest",
                key: "Ps.10.1",
                anchorOrdinal: nil
            )
        )
        XCTAssertEqual(f.controller.activeModuleName, "KJV")
        XCTAssertEqual(f.controller.currentBook, "Genesis")
        XCTAssertEqual(f.controller.currentChapter, 1)
        XCTAssertEqual(f.controller.currentVerse, 1)
        XCTAssertEqual(pageManager.bibleDocument, previousDocument)
        XCTAssertEqual(pageManager.bibleBibleBook, previousBook)
        XCTAssertEqual(pageManager.bibleChapterNo, previousChapter)
        XCTAssertEqual(pageManager.bibleVerseNo, previousVerse)
        XCTAssertEqual(f.scripts().count, scriptBoundary)
        XCTAssertTrue(f.store.history(windowId: f.window.id).isEmpty)
        XCTAssertTrue(foreignStore.history(windowId: f.window.id).isEmpty)
        withExtendedLifetime((f.container, foreignContainer)) {}
    }

    /**
     Creates an exact managed reader fixture with KJV and sparse Vulgate Psalm content.

     - Parameter name: Workspace name used to isolate the test's durable graph.
     - Returns: Registered controller, bridge recorder, modules, and persistence owners.
     - Side effects: Creates temporary SWORD and SwiftData stores and emits the initial Bible page.
     - Failure modes: Propagates fixture creation, SWORD discovery, registration, and bridge errors.
     */
    @MainActor
    private func fixture(_ name: String) async throws -> Fixture {
        let modulePath = try makeTemporarySwordFixturePath()
        try seedSyntheticRawTextBibleModule(
            named: "VulgTest",
            description: "Vulgate My Notes history fixture",
            versification: "Vulg",
            entries: [
                ("Ps", 1, 1, #"<verse osisID="Ps.1.1">Psalm admission.</verse>"#),
                ("Ps", 10, 1, #"<verse osisID="Ps.10.1">Psalm ten one.</verse>"#),
                ("Ps", 10, 2, #"<verse osisID="Ps.10.2">Psalm ten two.</verse>"#),
                ("Ps", 10, 3, #"<verse osisID="Ps.10.3">Psalm ten three.</verse>"#),
            ],
            in: modulePath
        )
        let sword = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let module = try XCTUnwrap(sword.module(named: "KJV"))
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: container.mainContext)
        let workspace = store.createWorkspace(name: name)
        let window = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let manager = WindowManager(workspaceStore: store)
        manager.setActiveWorkspace(workspace)
        manager.activeWindow = window
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: sword)
        controller.activeWindow = window
        controller.windowManagerRef = manager
        controller.workspaceStore = store
        XCTAssertTrue(manager.registerController(controller, for: window))
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)
        return Fixture(
            container: container,
            store: store,
            window: window,
            manager: manager,
            bridge: bridge,
            scripts: scripts,
            controller: controller,
            module: module
        )
    }

    /** Opens one selected KJVA My Notes row and waits for its real bridge replacement. */
    @MainActor
    private func open(_ fixture: Fixture, _ ordinal: Int) async throws {
        let boundary = fixture.scripts().count
        fixture.controller.loadMyNotesDocument(
            v11nName: JSwordKJVAVersification.name,
            sourceOrdinal: ordinal
        )
        _ = try await awaitBridgeEmission(
            from: fixture.scripts,
            event: "add_documents",
            after: boundary
        )
    }

    /** Resolves one exact KJVA row ordinal used by My Notes bridge payloads. */
    private func kjva(_ osis: String, _ chapter: Int, _ verse: Int) throws -> Int {
        try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(
                osisId: osis,
                chapter: chapter,
                verse: verse
            )
        )
    }
}
