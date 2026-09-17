import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/** Public-boundary regressions for My Notes render ownership and synchronized movement. */
final class BibleReaderMyNotesRenderOwnershipRegressionTests: BibleUISwordFixtureTestCase {
    private struct Fixture {
        let container: ModelContainer
        let store: WorkspaceStore
        let window: Window
        let windowManager: WindowManager
        let bridge: BibleBridge
        let scripts: () -> [String]
        let controller: BibleReaderController
        let worker: DispatchQueue
        let coordinator: BibleReaderDocumentPreparationCoordinator
        let module: SwordModule
    }

    /**
     A rejected same-span replacement must not authorize telemetry from the still-visible old DOM.

     The replacement is rejected at the real `BibleBridge.emit` boundary by temporarily removing
     both bridge destinations. The callback then reports another row from the old Matthew 1 DOM.
     That row must be consumed without changing the newly accepted native target or persisting it.
     */
    @MainActor
    func testRejectedSameSpanReplacementDoesNotAuthorizeOldDOMTelemetry() async throws {
        let fixture = try await makeFixture(name: "Rejected My Notes render")
        let matthewOneOne = try kjvaOrdinal("Matt", 1, 1)
        let matthewOneFive = try kjvaOrdinal("Matt", 1, 5)
        let matthewOneSeven = try kjvaOrdinal("Matt", 1, 7)
        try await openMyNotes(fixture, ordinal: matthewOneOne)

        var persistCount = 0
        fixture.controller.onPersistState = { persistCount += 1 }
        fixture.bridge.javaScriptEvaluationObserver = nil
        let disposition = await fixture.controller.loadMyNotesDocumentAwaitingSelection(
            jumpToOrdinal: matthewOneFive
        )
        XCTAssertEqual(disposition, .bridgeRejected)
        let persistenceAfterRejectedIntent = persistCount

        fixture.bridge.javaScriptEvaluationObserver = { _ in }
        fixture.controller.bridge(
            fixture.bridge,
            didScrollToOrdinal: matthewOneSeven,
            key: "Matt.1.7",
            atChapterTop: false
        )

        XCTAssertEqual(fixture.controller.currentBook, "Matthew")
        XCTAssertEqual(fixture.controller.currentChapter, 1)
        XCTAssertEqual(fixture.controller.currentVerse, 5)
        XCTAssertEqual(fixture.window.pageManager?.bibleVerseNo, 5)
        XCTAssertEqual(persistCount, persistenceAfterRejectedIntent)
        fixture.coordinator.cancelAll()
        withExtendedLifetime(fixture.container) {}
    }

    /**
     A same-span sync accepted while reload preparation is suspended supersedes that old reload.

     The sync must scroll exactly once and retain its verse after the worker resumes. The earlier
     reload must not subsequently replace the document or reset the accepted position.
     */
    @MainActor
    func testSameSpanSyncSupersedesSuspendedReload() async throws {
        let fixture = try await makeFixture(name: "Suspended My Notes reload")
        let matthewOneOne = try kjvaOrdinal("Matt", 1, 1)
        let matthewOneFive = try kjvaOrdinal("Matt", 1, 5)
        try await openMyNotes(fixture, ordinal: matthewOneOne)
        let boundary = fixture.scripts().count

        fixture.worker.suspend()
        fixture.controller.loadCurrentContent()
        fixture.controller.applyWindowSynchronizationPosition(
            WindowSynchronizationPosition(
                sourceVersification: JSwordKJVAVersification.name,
                osisBookId: "Matt",
                chapter: 1,
                verse: 5,
                sourceOrdinal: matthewOneFive,
                sourceKey: "Matt.1.5"
            )
        )
        fixture.worker.resume()
        try await drainPreparationPipeline(fixture.worker)

        let scripts = Array(fixture.scripts().dropFirst(boundary))
        XCTAssertEqual(scripts.filter { $0.contains("emit('scroll_to_verse'") }.count, 1)
        XCTAssertEqual(scripts.filter { $0.contains("emit('add_documents'") }.count, 0)
        XCTAssertEqual(fixture.controller.currentBook, "Matthew")
        XCTAssertEqual(fixture.controller.currentChapter, 1)
        XCTAssertEqual(fixture.controller.currentVerse, 5)
        XCTAssertEqual(fixture.window.pageManager?.bibleVerseNo, 5)
        fixture.coordinator.cancelAll()
        withExtendedLifetime(fixture.container) {}
    }

    /** An exact same-position typed sync is an observable no-op. */
    @MainActor
    func testExactSamePositionMyNotesSyncDoesNotBridgeOrPersist() async throws {
        let fixture = try await makeFixture(name: "No-op My Notes sync")
        let matthewOneFive = try kjvaOrdinal("Matt", 1, 5)
        try await openMyNotes(fixture, ordinal: matthewOneFive)
        var persistCount = 0
        fixture.controller.onPersistState = { persistCount += 1 }
        let boundary = fixture.scripts().count

        fixture.controller.applyWindowSynchronizationPosition(
            WindowSynchronizationPosition(
                sourceVersification: JSwordKJVAVersification.name,
                osisBookId: "Matt",
                chapter: 1,
                verse: 5,
                sourceOrdinal: matthewOneFive,
                sourceKey: "Matt.1.5"
            )
        )

        XCTAssertEqual(fixture.scripts().count, boundary)
        XCTAssertEqual(persistCount, 0)
        XCTAssertEqual(fixture.controller.currentVerse, 5)
        XCTAssertEqual(fixture.window.pageManager?.bibleVerseNo, 5)
        fixture.coordinator.cancelAll()
        withExtendedLifetime(fixture.container) {}
    }

    @MainActor
    private func makeFixture(name: String) async throws -> Fixture {
        let worker = DispatchQueue(label: "org.andbible.tests.mynotes-render-ownership")
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: container.mainContext)
        let workspace = store.createWorkspace(name: name)
        let window = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: store)
        windowManager.setActiveWorkspace(workspace)
        windowManager.activeWindow = window
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        controller.activeWindow = window
        controller.windowManagerRef = windowManager
        controller.workspaceStore = store
        XCTAssertTrue(windowManager.registerController(controller, for: window))
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)
        return Fixture(
            container: container,
            store: store,
            window: window,
            windowManager: windowManager,
            bridge: bridge,
            scripts: scripts,
            controller: controller,
            worker: worker,
            coordinator: coordinator,
            module: module
        )
    }

    @MainActor
    private func openMyNotes(_ fixture: Fixture, ordinal: Int) async throws {
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

    /** Resolves the exact ordinal domain consumed by My Notes bridge rows and typed sync. */
    private func kjvaOrdinal(_ osis: String, _ chapter: Int, _ verse: Int) throws -> Int {
        try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: osis, chapter: chapter, verse: verse)
        )
    }

    /**
     Gives every worker/main stage of an uncancelled capture, owner capture, enrichment, encoding,
     and publication pipeline a deterministic opportunity without issuing another reader action.
     */
    @MainActor
    private func drainPreparationPipeline(_ worker: DispatchQueue) async throws {
        for index in 0..<3 {
            let barrier = expectation(description: "preparation worker/main barrier \(index)")
            worker.async {
                DispatchQueue.main.async { barrier.fulfill() }
            }
            await fulfillment(of: [barrier], timeout: 3)
        }
    }
}
