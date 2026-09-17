import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/** Behavioral coverage for target-local typed synchronization idempotence. */
final class BibleReaderTypedSyncIdempotenceTests: BibleUISwordFixtureTestCase {
    /** Repeated cross-versification deliveries mapped to the visible Bible verse do no work. */
    @MainActor
    func testRepeatedMappedSamePositionBibleSyncDoesNotBridgeOrPersist() async throws {
        let sword = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: container.mainContext)
        let workspace = store.createWorkspace(name: "Typed sync no-op")
        let window = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let manager = WindowManager(workspaceStore: store)
        manager.setActiveWorkspace(workspace)
        manager.activeWindow = window
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: sword)
        controller.activeWindow = window
        controller.workspaceStore = store
        controller.windowManagerRef = manager
        XCTAssertTrue(manager.registerController(controller, for: window))

        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)
        XCTAssertEqual(controller.committedRenderState.identity?.category, .bible)
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)
        XCTAssertEqual(controller.currentVerse, 1)

        let unexpectedPersistence = expectation(description: "same-position sync does not persist")
        unexpectedPersistence.isInverted = true
        controller.onPersistState = { unexpectedPersistence.fulfill() }
        let savedChapter = window.pageManager?.bibleChapterNo
        let savedVerse = window.pageManager?.bibleVerseNo
        let boundary = scripts().count
        let sameMappedPosition = WindowSynchronizationPosition(
            sourceVersification: "Vulg",
            osisBookId: "Gen",
            chapter: 1,
            verse: 1
        )

        controller.applyWindowSynchronizationPosition(sameMappedPosition)
        controller.applyWindowSynchronizationPosition(sameMappedPosition)

        XCTAssertEqual(scripts().count, boundary)
        await fulfillment(of: [unexpectedPersistence], timeout: 0.6)
        XCTAssertEqual(window.pageManager?.bibleChapterNo, savedChapter)
        XCTAssertEqual(window.pageManager?.bibleVerseNo, savedVerse)
        withExtendedLifetime(container) {}
    }

    /** Equal pre-ready state still admits the first rendered generation. */
    @MainActor
    func testPreReadyEqualCoordinateSyncStillPublishesInitialBible() async throws {
        let fixture = try await makeFixture(clientReady: false)
        fixture.controller.applyWindowSynchronizationPosition(genesisPosition(chapter: 1))
        XCTAssertTrue(fixture.scripts().isEmpty)

        fixture.controller.bridgeDidSetClientReady(fixture.bridge)
        _ = try await awaitBridgeEmission(
            from: fixture.scripts,
            event: "add_documents",
            after: 0
        )

        XCTAssertEqual(fixture.controller.committedRenderState.identity?.category, .bible)
        XCTAssertEqual(fixture.controller.currentChapter, 1)
        withExtendedLifetime(fixture.container) {}
    }

    /** Settled unloaded-chapter sync replaces passively without adding explicit navigation history. */
    @MainActor
    func testSettledCrossChapterBibleSyncReplacesWithoutHistoryOrOldDOMScroll() async throws {
        let fixture = try await makeFixture(clientReady: true)
        let boundary = fixture.scripts().count
        let historyCount = fixture.window.historyItems?.count ?? 0
        let persisted = expectation(description: "passive cross-chapter sync persists once")
        var persistCount = 0
        fixture.controller.onPersistState = {
            persistCount += 1
            if persistCount == 1 { persisted.fulfill() }
        }

        fixture.controller.applyWindowSynchronizationPosition(genesisPosition(chapter: 2))

        XCTAssertEqual(
            fixture.scripts().dropFirst(boundary)
                .filter { $0.contains("emit('scroll_to_verse'") }.count,
            0
        )
        _ = try await awaitBridgeEmission(
            from: fixture.scripts,
            event: "add_documents",
            after: boundary
        )
        XCTAssertEqual(
            fixture.scripts().dropFirst(boundary).filter { $0.contains("emit('add_documents'") }.count,
            1
        )
        XCTAssertEqual(fixture.controller.committedRenderState.identity?.chapter, 2)
        XCTAssertEqual(fixture.controller.currentChapter, 2)
        await fulfillment(of: [persisted], timeout: 1)
        XCTAssertEqual(persistCount, 1)
        XCTAssertEqual(fixture.window.historyItems?.count ?? 0, historyCount)
        fixture.coordinator.cancelAll()
        withExtendedLifetime(fixture.container) {}
    }

    /** Equal coordinates do not suppress a same-chapter replacement already in flight. */
    @MainActor
    func testPendingSameChapterRenderSurvivesEqualCoordinateSync() async throws {
        let fixture = try await makeFixture(clientReady: true)
        fixture.worker.suspend()
        let boundary = fixture.scripts().count
        let unexpectedPersistence = expectation(description: "equal pending sync does not persist")
        unexpectedPersistence.isInverted = true
        fixture.controller.onPersistState = { unexpectedPersistence.fulfill() }
        fixture.controller.loadCurrentContent()
        fixture.controller.applyWindowSynchronizationPosition(genesisPosition(chapter: 1))
        XCTAssertEqual(fixture.scripts().count, boundary)
        await fulfillment(of: [unexpectedPersistence], timeout: 0.6)
        fixture.worker.resume()

        _ = try await awaitBridgeEmission(
            from: fixture.scripts,
            event: "add_documents",
            after: boundary
        )
        XCTAssertEqual(
            fixture.scripts().dropFirst(boundary).filter { $0.contains("emit('add_documents'") }.count,
            1
        )
        XCTAssertEqual(fixture.controller.committedRenderState.identity?.chapter, 1)
        fixture.coordinator.cancelAll()
        withExtendedLifetime(fixture.container) {}
    }

    /** Equal coordinates do not suppress a cross-chapter replacement already in flight. */
    @MainActor
    func testPendingCrossChapterRenderSurvivesEqualCoordinateSync() async throws {
        let fixture = try await makeFixture(clientReady: true)
        fixture.worker.suspend()
        let boundary = fixture.scripts().count
        let explicitNavigationPersisted = expectation(
            description: "explicit pending navigation persistence settles"
        )
        fixture.controller.onPersistState = { explicitNavigationPersisted.fulfill() }
        XCTAssertTrue(fixture.controller.navigateTo(book: "Genesis", chapter: 2, verse: 1))
        await fulfillment(of: [explicitNavigationPersisted], timeout: 1)
        let unexpectedPersistence = expectation(description: "equal pending chapter does not persist")
        unexpectedPersistence.isInverted = true
        fixture.controller.onPersistState = { unexpectedPersistence.fulfill() }
        fixture.controller.applyWindowSynchronizationPosition(genesisPosition(chapter: 2))
        XCTAssertEqual(fixture.scripts().count, boundary)
        await fulfillment(of: [unexpectedPersistence], timeout: 0.6)
        fixture.worker.resume()

        _ = try await awaitBridgeEmission(
            from: fixture.scripts,
            event: "add_documents",
            after: boundary
        )
        XCTAssertEqual(
            fixture.scripts().dropFirst(boundary).filter { $0.contains("emit('add_documents'") }.count,
            1
        )
        XCTAssertEqual(fixture.controller.committedRenderState.identity?.chapter, 2)
        XCTAssertEqual(fixture.controller.currentChapter, 2)
        fixture.coordinator.cancelAll()
        withExtendedLifetime(fixture.container) {}
    }

    /** A changed sync supersedes an obsolete pending chapter without scrolling the old DOM. */
    @MainActor
    func testChangedSyncSupersedesPendingChapterWithOneReplacement() async throws {
        let fixture = try await makeFixture(clientReady: true)
        fixture.worker.suspend()
        let boundary = fixture.scripts().count
        let explicitNavigationPersisted = expectation(
            description: "explicit superseded navigation persistence settles"
        )
        fixture.controller.onPersistState = { explicitNavigationPersisted.fulfill() }
        XCTAssertTrue(fixture.controller.navigateTo(book: "Genesis", chapter: 2, verse: 1))
        await fulfillment(of: [explicitNavigationPersisted], timeout: 1)
        let historyCountAfterExplicitNavigation = fixture.window.historyItems?.count ?? 0
        let passiveSyncPersisted = expectation(description: "changed passive sync persists once")
        var passivePersistCount = 0
        fixture.controller.onPersistState = {
            passivePersistCount += 1
            if passivePersistCount == 1 { passiveSyncPersisted.fulfill() }
        }
        fixture.controller.applyWindowSynchronizationPosition(genesisPosition(chapter: 3))
        XCTAssertEqual(
            fixture.scripts().dropFirst(boundary).filter { $0.contains("emit('scroll_to_verse'") }.count,
            0
        )
        XCTAssertEqual(fixture.controller.currentChapter, 3)
        fixture.worker.resume()

        _ = try await awaitBridgeEmission(
            from: fixture.scripts,
            event: "add_documents",
            after: boundary
        )
        XCTAssertEqual(
            fixture.scripts().dropFirst(boundary).filter { $0.contains("emit('add_documents'") }.count,
            1
        )
        XCTAssertEqual(fixture.controller.committedRenderState.identity?.chapter, 3)
        await fulfillment(of: [passiveSyncPersisted], timeout: 1)
        XCTAssertEqual(passivePersistCount, 1)
        XCTAssertEqual(
            fixture.window.historyItems?.count ?? 0,
            historyCountAfterExplicitNavigation
        )
        fixture.coordinator.cancelAll()
        withExtendedLifetime(fixture.container) {}
    }

    /** StudyPad retains its visible journal while passive sync updates only the shared Bible key. */
    @MainActor
    func testStudyPadTypedSyncUpdatesSharedBiblePositionWithoutDOMMutation() async throws {
        let fixture = try await makeFixture(clientReady: true)
        let bookmarkContainer = try makeBookmarkListModelContainer()
        let bookmarkService = BookmarkService(
            store: BookmarkStore(modelContext: bookmarkContainer.mainContext)
        )
        fixture.controller.bookmarkService = bookmarkService
        let label = bookmarkService.createLabel(
            name: "Passive synchronization pad",
            color: Label.defaultColor
        )
        let studyPadBoundary = fixture.scripts().count
        fixture.controller.loadStudyPadDocument(labelId: label.id)
        _ = try await awaitBridgeEmission(
            from: fixture.scripts,
            event: "add_documents",
            after: studyPadBoundary
        )
        XCTAssertTrue(fixture.controller.showingStudyPad)
        let committedStudyPad = fixture.controller.committedRenderState
        let syncBoundary = fixture.scripts().count
        let persisted = expectation(description: "StudyPad shared Bible position persists once")
        var persistCount = 0
        fixture.controller.onPersistState = {
            persistCount += 1
            if persistCount == 1 { persisted.fulfill() }
        }

        fixture.controller.applyWindowSynchronizationPosition(genesisPosition(chapter: 1))
        fixture.controller.applyWindowSynchronizationPosition(genesisPosition(chapter: 2))

        XCTAssertEqual(fixture.scripts().count, syncBoundary)
        XCTAssertEqual(fixture.controller.committedRenderState, committedStudyPad)
        XCTAssertTrue(fixture.controller.showingStudyPad)
        XCTAssertEqual(fixture.controller.activeStudyPadLabelId, label.id)
        XCTAssertEqual(fixture.controller.currentBook, "Genesis")
        XCTAssertEqual(fixture.controller.currentChapter, 2)
        XCTAssertEqual(fixture.controller.currentVerse, 1)
        await fulfillment(of: [persisted], timeout: 1)
        XCTAssertEqual(persistCount, 1)
        fixture.coordinator.cancelAll()
        withExtendedLifetime((fixture.container, bookmarkContainer)) {}
    }

    /** A bridge-rejected target retries replacement and never scrolls its ordinal into the old DOM. */
    @MainActor
    func testRejectedReplacementRetriesEqualSyncWithoutScrollingCommittedOldDOM() async throws {
        let worker = DispatchQueue(label: "org.andbible.tests.typed-sync-rejected-retry")
        let rejectedPublication = expectation(description: "bridge-rejected replacement settles")
        let rejectionGate = TypedSyncPublicationGate()
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: worker,
            phaseObserver: { phase, _, key in
                guard phase == .publication,
                      key.family.rawValue == "bible",
                      rejectionGate.consumeIfOpen() else { return }
                rejectedPublication.fulfill()
            }
        )
        let sword = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: container.mainContext)
        let workspace = store.createWorkspace(name: "Typed sync rejected replacement")
        let window = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let manager = WindowManager(workspaceStore: store)
        manager.setActiveWorkspace(workspace)
        manager.activeWindow = window
        let bridge = BibleBridge()
        var scripts: [String] = []
        bridge.javaScriptEvaluationObserver = { scripts.append($0) }
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: sword,
            documentPreparationCoordinator: coordinator
        )
        controller.activeWindow = window
        controller.workspaceStore = store
        controller.windowManagerRef = manager
        XCTAssertTrue(manager.registerController(controller, for: window))
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(from: { scripts }, event: "add_documents", after: 0)
        XCTAssertEqual(controller.committedRenderState.identity?.chapter, 1)

        bridge.javaScriptEvaluationObserver = nil
        let rejectedNavigationPersisted = expectation(
            description: "rejected replacement native selection persists"
        )
        controller.onPersistState = { rejectedNavigationPersisted.fulfill() }
        rejectionGate.open()
        XCTAssertTrue(controller.navigateTo(book: "Genesis", chapter: 2, verse: 1))
        await fulfillment(of: [rejectedPublication, rejectedNavigationPersisted], timeout: 3)
        XCTAssertEqual(controller.currentChapter, 2)
        XCTAssertEqual(controller.committedRenderState.identity?.chapter, 1)

        bridge.javaScriptEvaluationObserver = { scripts.append($0) }
        let boundary = scripts.count
        let unexpectedPersistence = expectation(
            description: "rejected equal-target retry does not persist again"
        )
        unexpectedPersistence.isInverted = true
        controller.onPersistState = { unexpectedPersistence.fulfill() }
        controller.applyWindowSynchronizationPosition(genesisPosition(chapter: 2))
        XCTAssertEqual(
            scripts.dropFirst(boundary).filter { $0.contains("emit('scroll_to_verse'") }.count,
            0
        )
        await fulfillment(of: [unexpectedPersistence], timeout: 0.6)
        _ = try await awaitBridgeEmission(from: { scripts }, event: "add_documents", after: boundary)
        XCTAssertEqual(
            scripts.dropFirst(boundary).filter { $0.contains("emit('add_documents'") }.count,
            1
        )
        XCTAssertEqual(controller.committedRenderState.identity?.chapter, 2)
        coordinator.cancelAll()
        withExtendedLifetime((container, store, manager)) {}
    }

    private struct Fixture {
        let container: ModelContainer
        let store: WorkspaceStore
        let manager: WindowManager
        let window: Window
        let bridge: BibleBridge
        let scripts: () -> [String]
        let controller: BibleReaderController
        let worker: DispatchQueue
        let coordinator: BibleReaderDocumentPreparationCoordinator
    }

    /** Creates one exact registered Bible pane with a controllable preparation worker. */
    @MainActor
    private func makeFixture(clientReady: Bool) async throws -> Fixture {
        let worker = DispatchQueue(label: "org.andbible.tests.typed-sync-noop")
        let coordinator = BibleReaderDocumentPreparationCoordinator(workerQueue: worker)
        let sword = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: container.mainContext)
        let workspace = store.createWorkspace(name: "Typed sync pending render")
        let window = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let manager = WindowManager(workspaceStore: store)
        manager.setActiveWorkspace(workspace)
        manager.activeWindow = window
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: sword,
            documentPreparationCoordinator: coordinator
        )
        controller.activeWindow = window
        controller.workspaceStore = store
        controller.windowManagerRef = manager
        XCTAssertTrue(manager.registerController(controller, for: window))
        if clientReady {
            controller.bridgeDidSetClientReady(bridge)
            _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)
        }
        return Fixture(
            container: container,
            store: store,
            manager: manager,
            window: window,
            bridge: bridge,
            scripts: scripts,
            controller: controller,
            worker: worker,
            coordinator: coordinator
        )
    }

    /** Vulgate coordinates prove equality is evaluated after strict target mapping. */
    private func genesisPosition(chapter: Int) -> WindowSynchronizationPosition {
        WindowSynchronizationPosition(
            sourceVersification: "Vulg",
            osisBookId: "Gen",
            chapter: chapter,
            verse: 1
        )
    }

}

/** Lock-owned one-shot gate for the exact rejected replacement publication. */
private final class TypedSyncPublicationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var openState = false

    func open() {
        lock.lock()
        openState = true
        lock.unlock()
    }

    func consumeIfOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard openState else { return false }
        openState = false
        return true
    }
}
