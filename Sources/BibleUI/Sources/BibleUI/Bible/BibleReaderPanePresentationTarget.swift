// BibleReaderPanePresentationTarget.swift -- captured pane routing helpers

import Foundation
import BibleCore

/**
 Resolves the pane captured by Android-parity reader modal and destination flows.

 Reader menus can be opened from any visible pane. Android keeps subsequent actions scoped to that
 originating pane instead of drifting to whichever pane becomes active later. These helpers keep
 the SwiftUI shell's capture/fallback rules testable without constructing the full app host.
 */
struct BibleReaderPanePresentationTarget {
    /**
     Captures the window that should own a pane-scoped presentation.

     - Parameters:
       - windowId: Explicit originating pane identifier, when the menu action supplies one.
       - activeWindow: Current active window used as the fallback capture.
     - Returns: `windowId` when provided; otherwise the current active window identifier.
     - Side effects: None.
     - Failure modes: Returns `nil` when neither an explicit nor active window exists.
     */
    static func capturedWindowId(requested windowId: UUID?, activeWindow: Window?) -> UUID? {
        windowId ?? activeWindow?.id
    }

    /**
     Resolves the controller that owns a captured pane-scoped flow.

     - Parameters:
       - targetWindowId: Previously captured pane identifier.
       - controllers: Registered reader controllers keyed by window identifier.
       - activeWindow: Current active window used only when no target was captured.
       - type: Expected controller type.
     - Returns: The captured pane controller, or the active pane controller when no capture exists.
     - Side effects: None.
     - Failure modes: A missing captured controller returns `nil` instead of falling back to the
       active pane so actions cannot mutate the wrong window while registration is pending.
     */
    static func controller<Controller: AnyObject>(
        targetWindowId: UUID?,
        controllers: [UUID: AnyObject],
        activeWindow: Window?,
        as type: Controller.Type = Controller.self
    ) -> Controller? {
        if let targetWindowId {
            return controllers[targetWindowId] as? Controller
        }
        guard let activeId = activeWindow?.id else { return nil }
        return controllers[activeId] as? Controller
    }

    /**
     Resolves the window that owns the active pane-scoped presentation.

     - Parameters:
       - targetWindowId: Previously captured pane identifier.
       - allWindows: Currently loaded workspace windows.
       - activeWindow: Current active window used only when no target was captured.
     - Returns: The captured window, or the active window when no capture exists.
     - Side effects: None.
     - Failure modes: A missing captured window returns `nil` instead of falling back to a different
       pane.
     */
    static func window(
        targetWindowId: UUID?,
        allWindows: [Window],
        activeWindow: Window?
    ) -> Window? {
        guard let targetWindowId else {
            return activeWindow
        }
        return allWindows.first { $0.id == targetWindowId }
    }
}
