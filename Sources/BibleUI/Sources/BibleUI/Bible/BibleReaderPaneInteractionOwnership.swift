// BibleReaderPaneInteractionOwnership.swift — exact pane ownership for native interaction

import Foundation
import BibleCore

/**
 Routes native reader interaction through the exact live pane object.

 Persisted window UUIDs identify durable rows, but a workspace refresh can replace a `Window`
 object with another instance carrying the same UUID. Native gesture closures belong to one pane
 instance, so they must use object identity before focusing or forwarding scroll state.
 */
@MainActor
enum BibleReaderPaneInteractionOwnership {
    /**
     Focuses the pane only while its controller and bridge still own the exact managed window.

     - Parameters:
       - controller: Controller captured by the pane interaction closure.
       - paneWindow: Exact window object that created the pane.
       - paneWindowID: Stable ID captured once while binding that pane.
       - windowManager: Current workspace lifecycle owner.
       - didActivate: Callback that publishes the changed active state to reader clients.
     - Returns: `true` when the exact pane is active after the attempt.
     - Side effects: May activate a current inactive pane and invoke `didActivate` once.
     - Failure modes: Returns `false` for retired controllers, replaced bridge owners, unmanaged
       same-UUID windows, or an activation that does not select the exact object.
     */
    @discardableResult
    static func focus(
        controller: BibleReaderController,
        paneWindow: Window,
        paneWindowID: UUID,
        windowManager: WindowManager,
        didActivate: () -> Void
    ) -> Bool {
        guard controller.activeWindow === paneWindow,
              controller.bridge.delegate === controller,
              windowManager.controllers[paneWindowID] === controller else {
            return false
        }
        if windowManager.activeWindow === paneWindow {
            return true
        }
        guard windowManager.managesWindow(paneWindow) else { return false }

        windowManager.activateWindow(paneWindow)
        guard windowManager.activeWindow === paneWindow else { return false }
        didActivate()
        return controller.activeWindow === paneWindow
            && controller.bridge.delegate === controller
            && windowManager.controllers[paneWindowID] === controller
            && windowManager.activeWindow === paneWindow
    }

    /**
     Forwards one user-origin native scroll delta after exact ownership and sync checks.

     - Parameters:
       - deltaY: Signed WebView scroll delta.
       - controller: Controller captured by the pane's native scroll closure.
       - paneWindow: Exact window object that created the pane.
       - paneWindowID: Stable ID captured once while binding that pane.
       - windowManager: Current workspace lifecycle owner.
       - forward: Parent-reader callback for fullscreen accumulation.
     - Side effects: A valid inactive pane may focus through `controller.handleUserInteraction()`;
       the delta is then forwarded exactly once.
     - Failure modes: Suppressed synchronized motion, retired/replaced ownership, failed focus, and
       stale same-UUID panes are ignored without forwarding.
     */
    static func forwardNativeScrollDelta(
        _ deltaY: Double,
        controller: BibleReaderController,
        paneWindow: Window,
        paneWindowID: UUID,
        windowManager: WindowManager,
        forward: (Double) -> Void
    ) {
        guard controller.activeWindow === paneWindow,
              controller.bridge.delegate === controller,
              windowManager.controllers[paneWindowID] === controller,
              controller.shouldTreatNativeScrollDeltaAsUserInteraction() else {
            return
        }

        if windowManager.activeWindow !== paneWindow {
            controller.handleUserInteraction()
        }

        guard controller.activeWindow === paneWindow,
              controller.bridge.delegate === controller,
              windowManager.controllers[paneWindowID] === controller,
              windowManager.activeWindow === paneWindow else {
            return
        }
        forward(deltaY)
    }
}
