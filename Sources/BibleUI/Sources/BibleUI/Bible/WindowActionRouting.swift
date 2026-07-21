// WindowActionRouting.swift -- Executable window-action seams used by reader controls

import CoreGraphics
import BibleCore

/**
 Receives state-changing commands emitted by a reader window tab.

 `WindowManager` is the production implementation. Keeping the protocol at the UI command boundary
 lets tests execute the same dispatcher used by SwiftUI without duplicating window lifecycle rules.
 */
protocol WindowTabActionTarget: AnyObject {
    /// Activates a visible window and applies the manager's focus normalization.
    func activateWindow(_ window: BibleCore.Window)

    /// Restores a minimized window through the manager lifecycle.
    func restoreWindow(_ window: BibleCore.Window)

    /// Moves a window to an Android-compatible position within its pin bucket.
    func moveWindow(_ window: BibleCore.Window, toPosition position: Int)

    /// Minimizes a window while preserving the manager's visible-window invariants.
    func minimizeWindow(_ window: BibleCore.Window)

    /// Maximizes a window through the manager's persisted layout path.
    func maximizeWindow(_ window: BibleCore.Window)

    /// Restores the workspace from maximized layout.
    func unmaximize()

    /// Changes synchronized-scrolling participation through the manager persistence path.
    func setSynchronized(_ window: BibleCore.Window, value: Bool)

    /// Changes effective pin behavior through the manager normalization path.
    func setPinMode(_ window: BibleCore.Window, value: Bool)

    /// Selects a synchronization group and applies the manager's immediate realignment behavior.
    func changeSyncGroup(_ window: BibleCore.Window, groupNumber: Int)

    /// Removes a window through the manager lifecycle and persistence path.
    func removeWindow(_ window: BibleCore.Window)
}

/**
 Describes one state-changing command emitted by an Android-style reader window tab.

 Associated values carry only user intent. `WindowTabActionDispatcher` delegates all lifecycle,
 validation, normalization, and persistence behavior to its `WindowTabActionTarget`.
 */
enum WindowTabAction: Equatable {
    /// Selects a tab, restoring it when it is currently minimized and activating it otherwise.
    case select(isMinimized: Bool)

    /// Activates the tab before a secondary action such as typed-reference navigation.
    case activate

    /// Restores a minimized tab from its context menu.
    case restore

    /// Moves the tab to a zero-based position in its effective pin bucket.
    case move(toPosition: Int)

    /// Minimizes the tab.
    case minimize

    /// Maximizes the tab.
    case maximize

    /// Leaves the workspace's maximized layout.
    case unmaximize

    /// Enables or disables synchronized scrolling.
    case setSynchronized(Bool)

    /// Enables or disables explicit pin mode.
    case setPinMode(Bool)

    /// Selects a zero-based synchronization group.
    case changeSyncGroup(Int)

    /// Closes the tab.
    case close
}

/**
 Routes typed window-tab commands into the production window lifecycle boundary.

 The dispatcher contains no window behavior of its own beyond choosing restore versus activate for
 tab selection. Every mutation is delegated to `WindowManager` in production, preserving its
 validation, normalization, synchronization, and persistence contracts.
 */
struct WindowTabActionDispatcher {
    /// Production manager or recording test target that receives routed commands.
    private let target: any WindowTabActionTarget

    /**
     Creates a dispatcher around the supplied lifecycle target.

     - Parameter target: Receiver responsible for all window mutations and persistence.
     - Side Effects: None until `perform(_:for:)` is called.
     - Failure Modes: None.
     */
    init(target: any WindowTabActionTarget) {
        self.target = target
    }

    /**
     Executes one tab command through the lifecycle target.

     - Parameters:
       - action: Typed user action emitted by the tab button or context menu.
       - window: Window represented by the tab.
     - Side Effects: Delegates exactly one state-changing operation to `target`.
     - Failure Modes: Validation failures are handled by the target as no-ops; the dispatcher does
       not mutate models directly or synthesize fallback behavior.
     */
    func perform(_ action: WindowTabAction, for window: BibleCore.Window) {
        switch action {
        case .select(let isMinimized):
            if isMinimized {
                target.restoreWindow(window)
            } else {
                target.activateWindow(window)
            }
        case .activate:
            target.activateWindow(window)
        case .restore:
            target.restoreWindow(window)
        case .move(let position):
            target.moveWindow(window, toPosition: position)
        case .minimize:
            target.minimizeWindow(window)
        case .maximize:
            target.maximizeWindow(window)
        case .unmaximize:
            target.unmaximize()
        case .setSynchronized(let value):
            target.setSynchronized(window, value: value)
        case .setPinMode(let value):
            target.setPinMode(window, value: value)
        case .changeSyncGroup(let group):
            target.changeSyncGroup(window, groupNumber: group)
        case .close:
            target.removeWindow(window)
        }
    }
}

/**
 Receives effective-weight reads and adjacent-pane resize writes from a separator drag session.

 `WindowManager` is the production implementation, so the session never writes raw model weights or
 duplicates effective pin/auto-pin behavior.
 */
protocol WindowSeparatorResizeTarget: AnyObject {
    /// Returns the effective layout weight used to render one pane.
    func effectiveLayoutWeight(for window: BibleCore.Window) -> Float

    /// Applies adjacent effective weights and optionally persists the completed gesture.
    func resizeWindows(
        _ firstWindow: BibleCore.Window,
        firstWeight: Float,
        _ secondWindow: BibleCore.Window,
        secondWeight: Float,
        persist: Bool
    )
}

/**
 Owns one separator gesture's effective-weight snapshot and persistence boundary.

 A gesture snapshots both effective weights once, derives every transient update from that stable
 baseline, and asks `WindowManager` to persist only the final pair. This mirrors Android's
 proportional separator behavior while keeping SwiftUI gesture closures free of mutable model logic.
 */
struct WindowSeparatorDragSession {
    /// Whether a drag has captured its starting effective weights and awaits completion.
    private(set) var isDragging = false

    /// Effective weight of the leading or upper pane at gesture start.
    private var startWeight1: Float = 1

    /// Effective weight of the trailing or lower pane at gesture start.
    private var startWeight2: Float = 1

    /// Most recent calculated effective weight for the leading or upper pane.
    private var currentWeight1: Float = 1

    /// Most recent calculated effective weight for the trailing or lower pane.
    private var currentWeight2: Float = 1

    /// Android-compatible minimum effective pane weight.
    private let minimumWeight: Float = 0.1

    /**
     Applies one drag translation as a transient adjacent-pane resize.

     - Parameters:
       - translation: Horizontal or vertical drag distance selected by the SwiftUI view.
       - parentSize: Available extent along the split axis.
       - totalPaneCount: Visible pane count used to derive Android's average pane extent.
       - firstWindow: Leading or upper pane, which grows for positive translation.
       - secondWindow: Trailing or lower pane, which shrinks for positive translation.
       - target: Effective-weight and resize boundary, implemented by `WindowManager` in production.
     - Side Effects: On the first update, reads both effective weights. Every valid update delegates
       one resize with `persist: false`.
     - Failure Modes: Non-positive average pane extent suppresses the transient resize after the
       gesture snapshot; completing that gesture still persists the unchanged effective pair.
     - Note: Every update is calculated from the first event's snapshot rather than compounding
       prior translations.
     */
    mutating func update(
        translation: CGFloat,
        parentSize: CGFloat,
        totalPaneCount: Int,
        firstWindow: BibleCore.Window,
        secondWindow: BibleCore.Window,
        target: any WindowSeparatorResizeTarget
    ) {
        if !isDragging {
            isDragging = true
            startWeight1 = target.effectiveLayoutWeight(for: firstWindow)
            startWeight2 = target.effectiveLayoutWeight(for: secondWindow)
            currentWeight1 = startWeight1
            currentWeight2 = startWeight2
        }

        let averagePaneSize = parentSize / CGFloat(totalPaneCount)
        guard averagePaneSize > 0 else { return }

        let variationPercent = Float(translation / averagePaneSize)
        currentWeight1 = max(minimumWeight, startWeight1 + variationPercent)
        currentWeight2 = max(minimumWeight, startWeight2 - variationPercent)
        target.resizeWindows(
            firstWindow,
            firstWeight: currentWeight1,
            secondWindow,
            secondWeight: currentWeight2,
            persist: false
        )
    }

    /**
     Completes the active gesture and persists its final effective weights once.

     - Parameters:
       - firstWindow: Leading or upper pane captured by the separator.
       - secondWindow: Trailing or lower pane captured by the separator.
       - target: Resize boundary, implemented by `WindowManager` in production.
     - Side Effects: Delegates one resize with `persist: true`, then clears active gesture state.
     - Failure Modes: Ending without a preceding update is a no-op.
     */
    mutating func finish(
        firstWindow: BibleCore.Window,
        secondWindow: BibleCore.Window,
        target: any WindowSeparatorResizeTarget
    ) {
        guard isDragging else { return }
        target.resizeWindows(
            firstWindow,
            firstWeight: currentWeight1,
            secondWindow,
            secondWeight: currentWeight2,
            persist: true
        )
        isDragging = false
    }
}

/// Connects the tab dispatcher to the app's sole window lifecycle implementation.
extension WindowManager: WindowTabActionTarget {}

/// Connects separator drag sessions to the manager's effective-weight persistence implementation.
extension WindowManager: WindowSeparatorResizeTarget {}
