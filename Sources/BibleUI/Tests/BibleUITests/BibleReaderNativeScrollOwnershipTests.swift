import BibleCore
@testable import BibleView
import SwiftData
import XCTest
@testable import BibleUI

/** Verifies native reader scrolling remains bound to the exact live pane object. */
@MainActor
final class BibleReaderNativeScrollOwnershipTests: XCTestCase {
    /** An inactive-pane drag focuses once while subsequent deltas stay on the exact active fast path. */
    func testInactiveManagedPaneDragActivatesBeforeForwardingDelta() throws {
        let fixture = try makeTwoWindowFixture(name: "inactive pane drag")
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        controller.activeWindow = fixture.target
        XCTAssertTrue(fixture.manager.registerController(controller, for: fixture.target))
        fixture.manager.activeWindow = fixture.source

        var activeStatePublications = 0
        let target = fixture.target
        let targetID = target.id
        let manager = fixture.manager
        controller.onInteraction = { [weak controller, weak target, weak manager] in
            guard let controller, let target, let manager else { return }
            BibleReaderPaneInteractionOwnership.focus(
                controller: controller,
                paneWindow: target,
                paneWindowID: targetID,
                windowManager: manager
            ) {
                activeStatePublications += 1
            }
        }
        var forwardedDeltas: [Double] = []

        BibleReaderPaneInteractionOwnership.forwardNativeScrollDelta(
            18,
            controller: controller,
            paneWindow: target,
            paneWindowID: targetID,
            windowManager: manager,
            forward: { forwardedDeltas.append($0) }
        )
        BibleReaderPaneInteractionOwnership.forwardNativeScrollDelta(
            22,
            controller: controller,
            paneWindow: target,
            paneWindowID: targetID,
            windowManager: manager,
            forward: { forwardedDeltas.append($0) }
        )

        XCTAssertTrue(manager.activeWindow === target)
        XCTAssertEqual(activeStatePublications, 1)
        XCTAssertEqual(forwardedDeltas, [18, 22])
        controller.onInteraction = nil
        withExtendedLifetime(fixture.container) {}
    }

    /** Sync-origin motion stays passive until explicit interaction releases the controller guard. */
    func testSynchronizedDeltaIsSuppressedUntilExplicitInteraction() throws {
        let fixture = try makeTwoWindowFixture(name: "synchronized drag")
        let bridge = BibleBridge()
        bridge.javaScriptEvaluationObserver = { _ in }
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let target = fixture.target
        let targetID = target.id
        let manager = fixture.manager
        controller.activeWindow = target
        XCTAssertTrue(manager.registerController(controller, for: target))
        manager.activeWindow = fixture.source
        var activeStatePublications = 0
        controller.onInteraction = { [weak controller, weak target, weak manager] in
            guard let controller, let target, let manager else { return }
            BibleReaderPaneInteractionOwnership.focus(
                controller: controller,
                paneWindow: target,
                paneWindowID: targetID,
                windowManager: manager
            ) {
                activeStatePublications += 1
            }
        }
        var forwardedDeltas: [Double] = []

        controller.bridgeDidSetClientReady(bridge)
        controller.scrollToOrdinal(17)
        BibleReaderPaneInteractionOwnership.forwardNativeScrollDelta(
            18,
            controller: controller,
            paneWindow: target,
            paneWindowID: targetID,
            windowManager: manager,
            forward: { forwardedDeltas.append($0) }
        )

        XCTAssertTrue(manager.activeWindow === fixture.source)
        XCTAssertEqual(activeStatePublications, 0)
        XCTAssertTrue(forwardedDeltas.isEmpty)

        controller.handleUserInteraction()
        BibleReaderPaneInteractionOwnership.forwardNativeScrollDelta(
            18,
            controller: controller,
            paneWindow: target,
            paneWindowID: targetID,
            windowManager: manager,
            forward: { forwardedDeltas.append($0) }
        )

        XCTAssertTrue(manager.activeWindow === target)
        XCTAssertEqual(activeStatePublications, 1)
        XCTAssertEqual(forwardedDeltas, [18])
        controller.onInteraction = nil
        withExtendedLifetime(fixture.container) {}
    }

    /** Retirement during focus publication prevents the triggering delta from escaping. */
    func testActivationCallbackRetirementPreventsDeltaForwarding() throws {
        let fixture = try makeTwoWindowFixture(name: "activation retirement")
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        let target = fixture.target
        let targetID = target.id
        let manager = fixture.manager
        controller.activeWindow = target
        XCTAssertTrue(manager.registerController(controller, for: target))
        manager.activeWindow = fixture.source
        var focusResult: Bool?
        controller.onInteraction = { [weak controller, weak target, weak manager] in
            guard let controller, let target, let manager else { return }
            focusResult = BibleReaderPaneInteractionOwnership.focus(
                controller: controller,
                paneWindow: target,
                paneWindowID: targetID,
                windowManager: manager
            ) {
                manager.unregisterController(for: target.id)
            }
        }
        var forwardedDeltas: [Double] = []

        BibleReaderPaneInteractionOwnership.forwardNativeScrollDelta(
            30,
            controller: controller,
            paneWindow: target,
            paneWindowID: targetID,
            windowManager: manager,
            forward: { forwardedDeltas.append($0) }
        )

        XCTAssertNil(controller.activeWindow)
        XCTAssertNil(bridge.delegate)
        XCTAssertEqual(focusResult, false)
        XCTAssertTrue(forwardedDeltas.isEmpty)
        controller.onInteraction = nil
        withExtendedLifetime(fixture.container) {}
    }

    /** A controller retained by another slot cannot act through a pane slot now owned by its replacement. */
    func testMultiSlotControllerCannotForwardFromReplacedPaneSlot() throws {
        let fixture = try makeTwoWindowFixture(name: "multi-slot replacement")
        let manager = fixture.manager
        let target = fixture.target
        let targetID = target.id
        let priorBridge = BibleBridge()
        let priorController = BibleReaderController(bridge: priorBridge, initializesSword: false)
        priorController.activeWindow = target
        XCTAssertTrue(manager.registerController(priorController, for: fixture.source))
        XCTAssertTrue(manager.registerController(priorController, for: target))

        let replacementBridge = BibleBridge()
        let replacementController = BibleReaderController(
            bridge: replacementBridge,
            initializesSword: false
        )
        replacementController.activeWindow = target
        XCTAssertTrue(manager.registerController(replacementController, for: target))
        manager.activeWindow = target

        XCTAssertTrue(manager.controllers[fixture.source.id] === priorController)
        XCTAssertTrue(manager.controllers[targetID] === replacementController)
        XCTAssertTrue(priorController.activeWindow === target)
        XCTAssertTrue(priorBridge.delegate === priorController)
        XCTAssertFalse(
            BibleReaderPaneInteractionOwnership.focus(
                controller: priorController,
                paneWindow: target,
                paneWindowID: targetID,
                windowManager: manager,
                didActivate: { XCTFail("replaced pane slot must not publish focus") }
            )
        )
        var priorDeltas: [Double] = []
        BibleReaderPaneInteractionOwnership.forwardNativeScrollDelta(
            25,
            controller: priorController,
            paneWindow: target,
            paneWindowID: targetID,
            windowManager: manager,
            forward: { priorDeltas.append($0) }
        )
        var replacementDeltas: [Double] = []
        BibleReaderPaneInteractionOwnership.forwardNativeScrollDelta(
            25,
            controller: replacementController,
            paneWindow: target,
            paneWindowID: targetID,
            windowManager: manager,
            forward: { replacementDeltas.append($0) }
        )

        XCTAssertTrue(priorDeltas.isEmpty)
        XCTAssertEqual(replacementDeltas, [25])
        withExtendedLifetime(fixture.container) {}
    }

    /** A retired same-UUID pane cannot reclaim focus or affect fullscreen after graph replacement. */
    func testRetiredSameIDPaneCannotActivateOrForwardNativeScroll() throws {
        let container = try makeWorkspaceModelContainer()
        let context = ModelContext(container)
        let store = WorkspaceStore(modelContext: context)
        let workspace = store.createWorkspace(name: "retired pane")
        let original = try XCTUnwrap(store.windows(workspaceId: workspace.id).first)
        let originalID = original.id
        let manager = WindowManager(workspaceStore: store)
        manager.setActiveWorkspace(workspace)
        let bridge = BibleBridge()
        let controller = BibleReaderController(bridge: bridge, initializesSword: false)
        controller.activeWindow = original
        XCTAssertTrue(manager.registerController(controller, for: original))
        controller.onInteraction = { [weak controller, weak original, weak manager] in
            guard let controller, let original, let manager else { return }
            BibleReaderPaneInteractionOwnership.focus(
                controller: controller,
                paneWindow: original,
                paneWindowID: originalID,
                windowManager: manager,
                didActivate: {}
            )
        }

        let replacement = Window(id: original.id)
        let replacementPageManager = PageManager(id: replacement.id)
        context.insert(replacement)
        context.insert(replacementPageManager)
        replacement.pageManager = replacementPageManager
        replacement.workspace = workspace
        original.workspace = nil
        workspace.windows = [replacement]
        try context.save()
        manager.refreshWindows()

        XCTAssertTrue(manager.activeWindow === replacement)
        XCTAssertNil(controller.activeWindow)
        XCTAssertNil(bridge.delegate)

        controller.handleUserInteraction()
        var forwardedDeltas: [Double] = []
        BibleReaderPaneInteractionOwnership.forwardNativeScrollDelta(
            80,
            controller: controller,
            paneWindow: original,
            paneWindowID: originalID,
            windowManager: manager,
            forward: { forwardedDeltas.append($0) }
        )

        XCTAssertTrue(manager.activeWindow === replacement)
        XCTAssertTrue(forwardedDeltas.isEmpty)
        controller.onInteraction = nil
        withExtendedLifetime(container) {}
    }

    /** Creates two exact managed panes with the source initially active. */
    private func makeTwoWindowFixture(name: String) throws -> (
        container: ModelContainer,
        manager: WindowManager,
        source: Window,
        target: Window
    ) {
        let container = try makeWorkspaceModelContainer()
        let store = WorkspaceStore(modelContext: container.mainContext)
        let workspace = store.createWorkspace(name: name)
        let manager = WindowManager(workspaceStore: store)
        manager.setActiveWorkspace(workspace)
        let source = try XCTUnwrap(manager.activeWindow)
        let target = try XCTUnwrap(manager.addWindow(from: source))
        manager.activeWindow = source
        return (container, manager, source, target)
    }
}
