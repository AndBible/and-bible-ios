import SwiftData
import XCTest
@testable import BibleCore

/** Verifies registry membership and retirement are one coherent WindowManager ownership contract. */
final class WindowManagerControllerRetirementTests: XCTestCase {
    /** Re-registering the identical owner preserves the ready slot without retiring it. */
    func testSameControllerReregistrationKeepsReadyOwnership() throws {
        let fixture = try makeManager(name: "same")
        let controller = RetirementSpy()
        XCTAssertTrue(fixture.manager.registerController(controller, for: fixture.window))
        XCTAssertFalse(fixture.manager.isControllerRegistrationPending(for: fixture.window.id))

        XCTAssertTrue(fixture.manager.registerController(controller, for: fixture.window))

        XCTAssertTrue(fixture.manager.registeredController(for: fixture.window) === controller)
        XCTAssertFalse(fixture.manager.isControllerRegistrationPending(for: fixture.window.id))
        XCTAssertEqual(controller.retirementCount, 0)
    }

    /** Replacement and final unregister notify each displaced owner once after removal. */
    func testReplacementAndUnregisterRetireEachOwnerOnce() throws {
        let fixture = try makeManager(name: "replace")
        let first = RetirementSpy()
        let second = RetirementSpy()
        XCTAssertTrue(fixture.manager.registerController(first, for: fixture.window))

        XCTAssertTrue(fixture.manager.registerController(second, for: fixture.window))
        XCTAssertNil(fixture.manager.controllers.values.first(where: { $0 === first }))
        fixture.manager.unregisterController(for: fixture.window.id)

        XCTAssertEqual(first.retirementCount, 1)
        XCTAssertEqual(second.retirementCount, 1)
    }

    /** A stale pane from the prior workspace cannot replace or retire a live owner. */
    func testOldWorkspaceRegistrationIsRejectedBeforeMutation() throws {
        let fixture = try makeManager(name: "stale")
        let oldWindow = fixture.window
        let replacement = fixture.store.createWorkspace(name: "replacement")
        fixture.manager.setActiveWorkspace(replacement)
        let replacementWindow = try XCTUnwrap(fixture.manager.allWindows.first)
        let live = RetirementSpy()
        let stale = RetirementSpy()
        XCTAssertTrue(fixture.manager.registerController(live, for: replacementWindow))

        XCTAssertFalse(fixture.manager.registerController(stale, for: oldWindow))

        XCTAssertEqual(live.retirementCount, 0)
        XCTAssertEqual(stale.retirementCount, 0)
        XCTAssertTrue(fixture.manager.controllers[replacementWindow.id] === live)
    }

    /** A same-ID `Window` object outside the managed graph cannot claim the current slot. */
    func testSameIDForeignWindowObjectIsRejectedBeforeMutation() throws {
        let fixture = try makeManager(name: "same id foreign graph")
        let live = RetirementSpy()
        let stale = RetirementSpy()
        let foreignWindow = Window(id: fixture.window.id)
        XCTAssertTrue(fixture.manager.registerController(live, for: fixture.window))

        XCTAssertNil(fixture.manager.registeredController(for: foreignWindow))
        XCTAssertTrue(fixture.manager.registeredController(for: fixture.window) === live)
        XCTAssertFalse(fixture.manager.registerController(stale, for: foreignWindow))

        XCTAssertTrue(fixture.manager.controllers[fixture.window.id] === live)
        XCTAssertEqual(live.retirementCount, 0)
        XCTAssertEqual(stale.retirementCount, 0)
    }

    /** A replacement callback cannot reclaim or unregister the slot that now belongs to B. */
    func testReplacementRetirementCannotReenterAndUndoNewOwner() throws {
        let fixture = try makeManager(name: "reentrant replacement")
        let first = RetirementSpy()
        let second = RetirementSpy()
        var observedReplacement = false
        var reentrantRegistrationAccepted = true
        first.onRetire = {
            observedReplacement = fixture.manager.controllers[fixture.window.id] === second
            reentrantRegistrationAccepted = fixture.manager.registerController(
                first,
                for: fixture.window
            )
            fixture.manager.unregisterController(for: fixture.window.id)
        }
        XCTAssertTrue(fixture.manager.registerController(first, for: fixture.window))

        XCTAssertTrue(fixture.manager.registerController(second, for: fixture.window))

        XCTAssertTrue(observedReplacement)
        XCTAssertFalse(reentrantRegistrationAccepted)
        XCTAssertTrue(fixture.manager.controllers[fixture.window.id] === second)
        XCTAssertFalse(fixture.manager.isControllerRegistrationPending(for: fixture.window.id))
        XCTAssertEqual(first.retirementCount, 1)
        XCTAssertEqual(second.retirementCount, 0)
    }

    /** Window removal blocks its retirement callback from repopulating the deleted slot. */
    func testWindowRemovalRetirementCannotReenterDeletedSlot() throws {
        let fixture = try makeManager(name: "reentrant removal")
        _ = try XCTUnwrap(fixture.manager.addWindow(from: fixture.window))
        let removedWindowID = fixture.window.id
        let controller = RetirementSpy()
        var reentrantRegistrationAccepted = true
        controller.onRetire = {
            reentrantRegistrationAccepted = fixture.manager.registerController(
                controller,
                for: fixture.window
            )
        }
        XCTAssertTrue(fixture.manager.registerController(controller, for: fixture.window))

        fixture.manager.removeWindow(fixture.window)

        XCTAssertFalse(reentrantRegistrationAccepted)
        XCTAssertEqual(controller.retirementCount, 1)
        XCTAssertNil(fixture.manager.controllers[removedWindowID])
        XCTAssertFalse(fixture.manager.allWindows.contains { $0.id == removedWindowID })
    }

    /** A replacement callback that removes the window cannot strand B in the deleted slot. */
    func testReplacementRetirementGraphMutationRetiresUnmanagedReplacement() throws {
        let fixture = try makeManager(name: "reentrant replacement removal")
        _ = try XCTUnwrap(fixture.manager.addWindow(from: fixture.window))
        let removedWindowID = fixture.window.id
        let first = RetirementSpy()
        let second = RetirementSpy()
        first.onRetire = {
            fixture.manager.removeWindow(fixture.window)
        }
        XCTAssertTrue(fixture.manager.registerController(first, for: fixture.window))

        let accepted = fixture.manager.registerController(second, for: fixture.window)

        XCTAssertFalse(accepted)
        XCTAssertEqual(first.retirementCount, 1)
        XCTAssertEqual(second.retirementCount, 1)
        XCTAssertNil(fixture.manager.controllers[removedWindowID])
        XCTAssertFalse(fixture.manager.allWindows.contains { $0.id == removedWindowID })
    }

    /** Workspace switch deduplicates a controller temporarily registered in multiple slots. */
    func testWorkspaceSwitchRetiresSharedControllerOnlyOnce() throws {
        let fixture = try makeManager(name: "switch")
        let secondWindow = try XCTUnwrap(fixture.manager.addWindow(from: fixture.window))
        let controller = RetirementSpy()
        XCTAssertTrue(fixture.manager.registerController(controller, for: fixture.window))
        XCTAssertTrue(fixture.manager.registerController(controller, for: secondWindow))

        fixture.manager.setActiveWorkspace(fixture.store.createWorkspace(name: "replacement"))

        XCTAssertEqual(controller.retirementCount, 1)
        XCTAssertTrue(fixture.manager.controllers.isEmpty)
    }

    /** Workspace retirement exposes the new graph and cannot re-register against old membership. */
    func testWorkspaceRetirementCannotReenterOldRegistry() throws {
        let fixture = try makeManager(name: "reentrant workspace")
        let oldWindow = fixture.window
        let replacement = fixture.store.createWorkspace(name: "replacement")
        let replacementID = replacement.id
        let controller = RetirementSpy()
        var observedWorkspaceID: UUID?
        var reentrantRegistrationAccepted = true
        controller.onRetire = {
            observedWorkspaceID = fixture.manager.activeWorkspace?.id
            reentrantRegistrationAccepted = fixture.manager.registerController(
                controller,
                for: oldWindow
            )
        }
        XCTAssertTrue(fixture.manager.registerController(controller, for: fixture.window))

        fixture.manager.setActiveWorkspace(replacement)

        XCTAssertEqual(observedWorkspaceID, replacementID)
        XCTAssertFalse(reentrantRegistrationAccepted)
        XCTAssertEqual(controller.retirementCount, 1)
        XCTAssertTrue(fixture.manager.controllers.isEmpty)
    }

    /** Refresh retires the old same-ID graph owner and rebinds focus to the replacement object. */
    func testSameIDManagedGraphReplacementRetiresControllerAndRebindsFocus() throws {
        let fixture = try makeManager(name: "same id managed replacement")
        let oldWindow = fixture.window
        let controller = RetirementSpy()
        XCTAssertTrue(fixture.manager.registerController(controller, for: oldWindow))
        XCTAssertTrue(fixture.manager.activeWindow === oldWindow)

        let replacement = Window(id: oldWindow.id)
        let replacementPageManager = PageManager(id: replacement.id)
        fixture.context.insert(replacement)
        fixture.context.insert(replacementPageManager)
        replacement.pageManager = replacementPageManager
        replacement.workspace = fixture.manager.activeWorkspace
        oldWindow.workspace = nil
        fixture.manager.activeWorkspace?.windows = [replacement]
        try fixture.context.save()

        fixture.manager.refreshWindows()

        XCTAssertTrue(fixture.manager.allWindows.first === replacement)
        XCTAssertTrue(fixture.manager.activeWindow === replacement)
        XCTAssertNil(fixture.manager.controllers[replacement.id])
        XCTAssertEqual(controller.retirementCount, 1)
        XCTAssertTrue(fixture.manager.isControllerRegistrationPending(for: replacement.id))
        XCTAssertFalse(fixture.manager.registerController(controller, for: oldWindow))
    }

    /** Minimized windows remain registry members and may reuse their retained controller. */
    func testMinimizedWindowRemainsEligibleForControllerRegistration() throws {
        let fixture = try makeManager(name: "minimized")
        _ = try XCTUnwrap(fixture.manager.addWindow(from: fixture.window))
        let controller = RetirementSpy()
        XCTAssertTrue(fixture.manager.registerController(controller, for: fixture.window))

        fixture.manager.minimizeWindow(fixture.window)

        XCTAssertEqual(fixture.window.layoutState, "minimized")
        XCTAssertFalse(fixture.manager.visibleWindows.contains { $0.id == fixture.window.id })
        XCTAssertTrue(fixture.manager.controllers[fixture.window.id] === controller)

        fixture.manager.restoreWindow(fixture.window)
        XCTAssertTrue(fixture.manager.registerController(controller, for: fixture.window))
        XCTAssertFalse(fixture.manager.isControllerRegistrationPending(for: fixture.window.id))
        XCTAssertTrue(fixture.manager.controllers[fixture.window.id] === controller)
        XCTAssertEqual(controller.retirementCount, 0)
    }

    /** Builds one in-memory workspace graph without file or network side effects. */
    private func makeManager(name: String) throws -> (
        manager: WindowManager, store: WorkspaceStore, window: Window, context: ModelContext
    ) {
        let schema = Schema([
            Setting.self, Workspace.self, Window.self, PageManager.self, HistoryItem.self,
            BibleBookmark.self, BibleBookmarkNotes.self, BibleBookmarkToLabel.self,
            GenericBookmark.self, GenericBookmarkNotes.self, GenericBookmarkToLabel.self,
            Label.self, StudyPadTextEntry.self, StudyPadTextEntryText.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let context = ModelContext(container)
        let store = WorkspaceStore(modelContext: context)
        let workspace = store.createWorkspace(name: name)
        let window = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let manager = WindowManager(workspaceStore: store)
        manager.setActiveWorkspace(workspace)
        return (manager, store, window, context)
    }
}

/** Counts final registry retirement callbacks without retaining external resources. */
private final class RetirementSpy: WindowControllerRegistrationLifecycle {
    /// Number of synchronous final-ownership notifications observed by the test.
    private(set) var retirementCount = 0

    /// Optional reentrant action used to inspect and challenge registry callback ordering.
    var onRetire: (() -> Void)?

    /** Records one callback; tests own serialization and invoke no concurrent mutation. */
    func windowControllerWillUnregister() {
        retirementCount += 1
        onRetire?()
    }
}
