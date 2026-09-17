import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/** End-to-end final-disposition contracts exposed by prepared reader selection routes. */
@MainActor
final class BibleReaderSelectionSettlementIntegrationTests: BibleUISwordFixtureTestCase {
    private var retainedPaneOwners: [(WindowManager, ModelContainer?)] = []
    /** An invalid request terminates once without changing the selected document. */
    func testMyDocumentMissingRequestReturnsFailureWithoutSelection() async throws {
        let container = try makeMyDocumentModelContainer()
        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        controller.myDocumentStore = MyDocumentStore(modelContext: container.mainContext)
        try attachWindow(to: controller)

        let disposition = await controller.loadMyDocumentPageAwaitingSelection(
            bookInitials: "missing",
            pageKey: "missing"
        )

        XCTAssertEqual(disposition, .failed(.settle))
        XCTAssertNil(controller.activeGeneralBookModuleName)
        XCTAssertNil(controller.currentGeneralBookKey)
        withExtendedLifetime(container) {}
    }

    /** A prepared page reports bridge rejection after selected intent commits but no bridge accepts. */
    func testMyDocumentBridgeRejectionIsReturnedAfterSelectionCommit() async throws {
        let fixture = try makeMyDocumentFixture(title: "Rejected", pageKey: "rejected")
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        controller.myDocumentStore = MyDocumentStore(modelContext: fixture.context)
        try attachWindow(to: controller)
        controller.bridgeDidSetClientReady(bridge)

        let disposition = await controller.loadMyDocumentPageAwaitingSelection(
            bookInitials: fixture.document.initials,
            pageKey: fixture.page.pageKey
        )

        XCTAssertEqual(disposition, .bridgeRejected)
        XCTAssertEqual(controller.activeGeneralBookModuleName, fixture.document.initials)
        XCTAssertEqual(controller.currentGeneralBookKey, fixture.page.pageKey)
        XCTAssertNil(controller.committedRenderState.identity)
        withExtendedLifetime(fixture.container) {}
    }

    /** One stale owner retries once and exposes only the final accepted publication. */
    func testMyDocumentStaleOwnerReturnsFinalRetryAcceptance() async throws {
        let fixture = try makeMyDocumentFixture(title: "Before", pageKey: "retry")
        let action = SelectionSettlementBoundaryAction()
        let coordinator = BibleReaderDocumentPreparationCoordinator(
            workerQueue: DispatchQueue(label: "org.andbible.tests.selection-settlement"),
            phaseObserver: { phase, _, key in
                guard phase == .publication, key.family.rawValue == "my-document" else { return }
                action.runOnce()
            }
        )
        let (bridge, scripts) = makeRecordingBridge()
        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: coordinator
        )
        controller.myDocumentStore = MyDocumentStore(modelContext: fixture.context)
        try attachWindow(to: controller)
        controller.bridgeDidSetClientReady(bridge)
        action.install {
            fixture.page.title = "After"
            try? fixture.context.save()
        }
        let boundary = scripts().count

        let disposition = await controller.loadMyDocumentPageAwaitingSelection(
            bookInitials: fixture.document.initials,
            pageKey: fixture.page.pageKey
        )

        XCTAssertEqual(disposition, .accepted)
        XCTAssertTrue(action.didRun)
        let emitted = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        let replacements = emitted.filter { $0.contains("emit('add_documents'") }
        XCTAssertEqual(replacements.count, 1)
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: replacements, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["key"] as? String, fixture.page.pageKey)
        XCTAssertEqual(controller.committedRenderState.identity?.key, fixture.page.pageKey)
        withExtendedLifetime(fixture.container) {}
    }

    /** Page-less My Documents reports the actual accepted no-content publication. */
    func testPageLessMyDocumentGeneralBookRouteReturnsAccepted() async throws {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let document = MyDocument(name: "Empty", initials: "EMPTY")
        context.insert(document)
        try context.save()
        let (bridge, _) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        controller.myDocumentStore = MyDocumentStore(modelContext: context)
        try attachWindow(to: controller)
        XCTAssertTrue(controller.switchMyDocumentToolbarDocument(
            expectedID: document.id,
            initials: document.initials
        ))

        let disposition = await controller.loadGeneralBookEntryAwaitingSelection(key: nil)

        XCTAssertEqual(disposition, .accepted)
        XCTAssertEqual(controller.activeGeneralBookModuleName, document.initials)
        XCTAssertNil(controller.currentGeneralBookKey)
        XCTAssertEqual(controller.committedRenderState.identity?.moduleName, document.initials)
        withExtendedLifetime(container) {}
    }

    /** AI routing reports a committed selected page even when its bridge is not ready. */
    func testAIRouterReturnsBridgeRejectedMyDocumentSelection() async throws {
        let myDocumentContainer = try makeMyDocumentModelContainer()
        let context = myDocumentContainer.mainContext
        let document = MyDocument(name: "Rejected", initials: "REJECTED")
        let page = MyDocumentPage(title: "Page", pageKey: "page")
        let content = MyDocumentPageContent(pageId: page.id, content: "Body")
        context.insert(document)
        context.insert(page)
        context.insert(content)
        page.document = document
        page.pageContent = content
        document.pages = [page]
        try context.save()
        let workspaceContainer = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: workspaceContainer.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "Rejected bridge")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)
        let store = MyDocumentStore(modelContext: context)
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        controller.myDocumentStore = store
        retainReaderWindowGraph(window)
        controller.activeWindow = window
        windowManager.registerController(controller, for: window)
        controller.bridgeDidSetClientReady(bridge)
        let router = AIReaderWindowDocumentRouter(
            windowManager: windowManager,
            myDocumentStore: store
        )

        let observed = try await router.setDocument(
            windowID: window.id,
            documentInitials: document.initials,
            key: page.pageKey
        )

        XCTAssertEqual(observed.documentInitials, document.initials)
        XCTAssertEqual(observed.currentKey, page.pageKey)
        XCTAssertEqual(controller.activeGeneralBookModuleName, document.initials)
        XCTAssertEqual(controller.currentGeneralBookKey, page.pageKey)
        XCTAssertNil(controller.committedRenderState.identity)
        withExtendedLifetime((myDocumentContainer, workspaceContainer)) {}
    }

    /** A pre-ready My Notes selection settles only after its retained request is accepted. */
    func testMyNotesPreReadyAwaitSettlesAfterClientReadyReplay() async throws {
        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let ordinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Matt", chapter: 1, verse: 1)
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        try attachWindow(to: controller)
        let boundary = scripts().count

        let pending = Task { @MainActor in
            await controller.loadMyNotesDocumentAwaitingSelection(jumpToOrdinal: ordinal)
        }
        try await awaitReaderCondition("pre-ready My Notes target retained") {
            controller.showingMyNotes
        }
        controller.bridgeDidSetClientReady(bridge)

        let disposition = await pending.value
        XCTAssertEqual(disposition, .accepted)
        let emitted = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: emitted, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "notes")
        XCTAssertTrue(controller.showingMyNotes)
    }

    /** Superseding a retained My Notes request cancels it once and accepts only the replacement. */
    func testMyNotesPreReadySupersessionCancelsOldWaiterAndAcceptsReplacement() async throws {
        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let firstOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        let secondOrdinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Matt", chapter: 1, verse: 1)
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        try attachWindow(to: controller)
        let boundary = scripts().count

        let first = Task { @MainActor in
            await controller.loadMyNotesDocumentAwaitingSelection(jumpToOrdinal: firstOrdinal)
        }
        try await awaitReaderCondition("first pre-ready My Notes target retained") {
            controller.showingMyNotes
        }
        let second = Task { @MainActor in
            await controller.loadMyNotesDocumentAwaitingSelection(jumpToOrdinal: secondOrdinal)
        }
        let firstDisposition = await first.value
        controller.bridgeDidSetClientReady(bridge)

        let secondDisposition = await second.value
        XCTAssertEqual(firstDisposition, .cancelled)
        XCTAssertEqual(secondDisposition, .accepted)
        let emitted = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: boundary
        )
        XCTAssertEqual(emitted.filter { $0.contains("emit('add_documents'") }.count, 1)
    }

    /** StudyPad retention is pane-local and settles when its own bridge accepts replay. */
    func testStudyPadPreReadySettlementBelongsToOriginalPane() async throws {
        let container = try makeBookmarkListModelContainer()
        let service = BookmarkService(store: BookmarkStore(modelContext: ModelContext(container)))
        let label = service.createLabel(name: "Retained", color: Label.defaultColor)
        let (firstBridge, firstScripts) = makeRecordingBridge()
        let first = BibleReaderController(
            bridge: firstBridge,
            bookmarkService: service,
            initializesSword: false
        )
        try attachWindow(to: first)
        let pending = Task { @MainActor in
            await first.loadStudyPadDocumentAwaitingSelection(labelId: label.id)
        }
        try await awaitReaderCondition("pre-ready StudyPad target retained") {
            first.showingStudyPad
        }

        let (otherBridge, _) = makeRecordingBridge()
        let other = BibleReaderController(bridge: otherBridge, initializesSword: false)
        try attachWindow(to: other)
        other.bridgeDidSetClientReady(otherBridge)
        XCTAssertTrue(firstScripts().isEmpty)

        first.bridgeDidSetClientReady(firstBridge)
        let disposition = await pending.value
        XCTAssertEqual(disposition, .accepted)
        let emitted = try await awaitBridgeEmission(
            from: firstScripts,
            event: "add_documents",
            after: 0
        )
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: emitted, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "journal")
        withExtendedLifetime(container) {}
    }

    /** An already-cancelled task cannot supersede state or admit a new StudyPad selection. */
    func testAlreadyCancelledAwaitDoesNotStartSelection() async throws {
        let container = try makeBookmarkListModelContainer()
        let service = BookmarkService(store: BookmarkStore(modelContext: ModelContext(container)))
        let label = service.createLabel(name: "Never selected", color: Label.defaultColor)
        let controller = BibleReaderController(
            bridge: BibleBridge(),
            bookmarkService: service,
            initializesSword: false
        )
        try attachWindow(to: controller)

        let disposition = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await controller.loadStudyPadDocumentAwaitingSelection(labelId: label.id)
        }.value

        XCTAssertEqual(disposition, .cancelled)
        XCTAssertFalse(controller.showingStudyPad)
        XCTAssertNil(controller.activeStudyPadLabelId)
        withExtendedLifetime(container) {}
    }

    /** Restored Multi retains its final settlement until the bridge accepts replay. */
    func testRestoredMultiPreReadyReturnsReplayAcceptance() async throws {
        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        try attachWindow(to: controller)
        let pending = Task { @MainActor in
            await controller.loadRestoredAndroidMultiDocumentAwaitingSelection(
                pageKey: "KJV:Gen.1.1"
            )
        }
        try await awaitReaderCondition("Multi selected before client readiness") {
            controller.currentGeneralBookKey == "KJV:Gen.1.1"
        }

        XCTAssertFalse(scripts().contains { $0.contains("emit('add_documents'") })
        controller.bridgeDidSetClientReady(bridge)
        let disposition = await pending.value
        XCTAssertEqual(disposition, .accepted)
        let emitted = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: 0
        )
        XCTAssertEqual(emitted.filter { $0.contains("emit('add_documents'") }.count, 1)
        XCTAssertEqual(controller.committedRenderState.identity?.moduleName, "Multi")
    }

    /** Compare uses the shared retained transient slot and exposes replay acceptance. */
    func testComparePreReadyReturnsReplayAcceptance() async throws {
        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let ordinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        let captureGate = SelectionPreparationGate()
        defer { captureGate.release() }
        let preparation = BibleReaderDocumentPreparationCoordinator(
            workerQueue: DispatchQueue(label: "org.andbible.tests.compare-pre-ready-owner"),
            phaseObserver: { phase, _, key in
                guard phase == .sourceCapture, key.family.rawValue == "composite" else { return }
                captureGate.blockUntilReleased()
            }
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(
            bridge: bridge,
            swordManagerOverride: manager,
            documentPreparationCoordinator: preparation
        )
        try attachWindow(to: controller)
        let pending = Task { @MainActor in
            await controller.loadCompareDocumentAwaitingSelection(.ordinals(
                bookInitials: "KJV",
                startOrdinal: ordinal,
                endOrdinal: ordinal
            ))
        }
        try await awaitReaderCondition("Compare source capture is blocked") {
            captureGate.didStart
        }
        XCTAssertTrue(scripts().isEmpty)

        controller.bridgeDidSetClientReady(bridge)
        XCTAssertFalse(scripts().contains { $0.contains("emit('add_documents'") })
        captureGate.release()
        let disposition = await pending.value
        XCTAssertEqual(disposition, .accepted)
        let emitted = try await awaitBridgeEmission(
            from: scripts,
            event: "add_documents",
            after: 0
        )
        XCTAssertEqual(emitted.filter { $0.contains("emit('add_documents'") }.count, 1)
        XCTAssertEqual(controller.committedRenderState.identity?.book, "Compare")
    }

    /** Cancelling pre-ready My Notes drops request bytes but keeps its selected target rebuildable. */
    func testCancelledPreReadyMyNotesRebuildsFreshOnClientReady() async throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let ordinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Matt", chapter: 1, verse: 1)
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        try attachWindow(to: controller)
        let pending = Task { @MainActor in
            await controller.loadMyNotesDocumentAwaitingSelection(jumpToOrdinal: ordinal)
        }
        try await awaitReaderCondition("My Notes selected before readiness") {
            controller.showingMyNotes
        }

        pending.cancel()
        let disposition = await pending.value
        XCTAssertEqual(disposition, .cancelled)
        XCTAssertTrue(controller.showingMyNotes)
        XCTAssertFalse(scripts().contains { $0.contains("emit('add_documents'") })

        controller.bridgeDidSetClientReady(bridge)
        let emitted = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)
        XCTAssertEqual(emitted.filter { $0.contains("emit('add_documents'") }.count, 1)
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: emitted, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "notes")
    }

    /** A failed StudyPad replacement leaves the accepted My Notes selection available to replay. */
    func testFailedStudyPadReplacementPreservesPriorMyNotesSelection() async throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let ordinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1)
        )
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        try attachWindow(to: controller)
        let accepted = Task { @MainActor in
            await controller.loadMyNotesDocumentAwaitingSelection(jumpToOrdinal: ordinal)
        }
        try await awaitReaderCondition("prior My Notes selection retained") {
            controller.showingMyNotes
        }

        let replacement = await controller.loadStudyPadDocumentAwaitingSelection(labelId: UUID())

        let acceptedDisposition = await accepted.value
        XCTAssertEqual(acceptedDisposition, .cancelled)
        XCTAssertEqual(replacement, .failed(.settle))
        XCTAssertTrue(controller.showingMyNotes)
        XCTAssertFalse(controller.showingStudyPad)
        controller.bridgeDidSetClientReady(bridge)
        let emitted = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)
        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: emitted, event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "notes")
    }

    /** Cancelling pre-ready Multi evicts its serialized payload and rebuilds once from PageManager. */
    func testCancelledPreReadyMultiRebuildsOnceFromSelectedIdentity() async throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        try attachWindow(to: controller)
        let pending = Task { @MainActor in
            await controller.loadRestoredAndroidMultiDocumentAwaitingSelection(
                pageKey: "KJV:Gen.1.1"
            )
        }
        try await awaitReaderCondition("Multi selected before cancellation") {
            controller.currentGeneralBookKey == "KJV:Gen.1.1"
        }

        pending.cancel()
        let disposition = await pending.value
        XCTAssertEqual(disposition, .cancelled)
        XCTAssertEqual(controller.currentGeneralBookKey, "KJV:Gen.1.1")
        controller.bridgeDidSetClientReady(bridge)

        let emitted = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)
        XCTAssertEqual(emitted.filter { $0.contains("emit('add_documents'") }.count, 1)
        XCTAssertEqual(controller.committedRenderState.identity?.moduleName, "Multi")
    }

    private func makeMyDocumentFixture(
        title: String,
        pageKey: String
    ) throws -> (
        container: ModelContainer,
        context: ModelContext,
        document: MyDocument,
        page: MyDocumentPage
    ) {
        let container = try makeMyDocumentModelContainer()
        let context = ModelContext(container)
        let document = MyDocument(name: "Local", initials: "LOCAL")
        let page = MyDocumentPage(title: title, pageKey: pageKey)
        let content = MyDocumentPageContent(pageId: page.id, content: "Body")
        context.insert(document)
        context.insert(page)
        context.insert(content)
        page.document = document
        page.pageContent = content
        document.pages = [page]
        try context.save()
        return (container, context, document, page)
    }

    /** Final registry retirement detaches real bridge delivery before a late client-ready message. */
    func testRegistryRetirementDetachesBridgeBeforeLateClientReadyReplay() async throws {
        let manager = try XCTUnwrap(SwordManager(modulePath: makeTemporarySwordFixturePath()))
        let module = try XCTUnwrap(manager.module(named: "KJV"))
        let ordinal = try XCTUnwrap(
            module.verseOrdinal(osisBookId: "Matt", chapter: 1, verse: 1)
        )
        let container = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: container.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "Retirement")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.activeWindow = window
        controller.windowManagerRef = windowManager
        controller.workspaceStore = workspaceStore
        XCTAssertTrue(windowManager.registerController(controller, for: window))

        let pending = Task { @MainActor in
            await controller.loadMyNotesDocumentAwaitingSelection(jumpToOrdinal: ordinal)
        }
        try await awaitReaderCondition("retired My Notes request retained") {
            controller.showingMyNotes
        }
        let boundary = scripts().count
        windowManager.unregisterController(for: window.id)

        let disposition = await pending.value
        XCTAssertEqual(disposition, .cancelled)
        XCTAssertNil(controller.activeWindow)
        XCTAssertNil(bridge.delegate)
        XCTAssertEqual(bridge.dispatchMessage(method: "setClientReady", args: []), .handled)
        XCTAssertEqual(scripts().count, boundary)
        withExtendedLifetime(container) {}
    }

    /** Retiring an old controller cannot detach a shared bridge already adopted by its replacement. */
    func testRegistryReplacementPreservesNewBridgeOwner() throws {
        let container = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: container.mainContext)
        let workspace = workspaceStore.createWorkspace(name: "Replacement")
        let window = try XCTUnwrap(workspaceStore.windows(workspaceId: workspace.id).first)
        let windowManager = WindowManager(workspaceStore: workspaceStore)
        windowManager.setActiveWorkspace(workspace)
        let bridge = BibleBridge()
        let oldController = BibleReaderController(bridge: bridge, initializesSword: false)
        oldController.activeWindow = window
        XCTAssertTrue(windowManager.registerController(oldController, for: window))

        let newController = BibleReaderController(bridge: bridge, initializesSword: false)
        newController.activeWindow = window
        var interactions = 0
        bridge.onAnyMessage = { interactions += 1 }
        XCTAssertTrue(windowManager.registerController(newController, for: window))

        XCTAssertTrue(bridge.delegate === newController)
        XCTAssertEqual(bridge.dispatchMessage(method: "setClientReady", args: []), .handled)
        XCTAssertEqual(interactions, 0)
        XCTAssertEqual(bridge.dispatchMessage(method: "toast", args: ["Owned"]), .handled)
        XCTAssertEqual(interactions, 1)
        withExtendedLifetime(container) {}
    }

    private func attachWindow(to controller: BibleReaderController) throws {
        let owner = try registerMyNotesPaneOwner(controller)
        retainedPaneOwners.append((owner.manager, owner.container))
    }
}

/** Deterministically blocks a real preparation worker until the test releases source capture. */
private final class SelectionPreparationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    /// Whether the worker reached the gated source-capture boundary.
    var didStart: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started
    }

    /** Marks the gate started and blocks the worker until ``release()`` is called. */
    func blockUntilReleased() {
        condition.lock()
        started = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    /** Releases all waiting workers; repeated cleanup calls are harmless. */
    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/** Runs one deterministic source mutation at the first matching publication boundary. */
private final class SelectionSettlementBoundaryAction: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?
    private var hasRun = false

    var didRun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasRun
    }

    func install(_ action: @escaping () -> Void) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func runOnce() {
        lock.lock()
        guard !hasRun, let action else {
            lock.unlock()
            return
        }
        hasRun = true
        self.action = nil
        lock.unlock()
        action()
    }
}
