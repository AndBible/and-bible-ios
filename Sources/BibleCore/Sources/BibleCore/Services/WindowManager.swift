// WindowManager.swift — Window lifecycle and layout management

import Foundation
import Observation

/// Manages window lifecycle, layout, and synchronization within workspaces.
@Observable
public final class WindowManager {
    private let workspaceStore: WorkspaceStore

    /// The currently active workspace.
    public private(set) var activeWorkspace: Workspace?

    /// Ordered list of visible windows in the active workspace.
    public private(set) var visibleWindows: [Window] = []

    /// All windows in the workspace (including minimized), for tab bar display.
    public private(set) var allWindows: [Window] = []

    /// The currently focused (active) window.
    public var activeWindow: Window?

    /**
     Controller registry — maps window IDs to their BibleReaderController instances.
     Uses AnyObject to avoid circular dependency (BibleCore can't import BibleUI).
     BibleReaderView casts to BibleReaderController.
     */
    public var controllers: [UUID: AnyObject] = [:]

    /**
     Incremented on every controller register/unregister to guarantee SwiftUI
     re-evaluates views that depend on the controller registry. Dictionary
     subscript mutations may not always trigger @Observable notifications.
     */
    public private(set) var controllerVersion: Int = 0

    /**
     Visible windows whose pane controller has not registered yet.

     This state models the gap between creating a persisted `Window` and SwiftUI instantiating the
     corresponding pane controller. UI that needs pane-scoped services should treat entries here as
     "opening" rather than as empty module or document state.
     */
    public private(set) var controllerPendingWindowIds: Set<UUID> = []

    /**
     Whether any visible pane is waiting for controller registration.

     - Returns: `true` while at least one visible window has no registered controller.
     - Side Effects: None.
     - Failure Modes: None.
     */
    public var hasPendingVisibleControllerRegistration: Bool {
        !controllerPendingWindowIds.isEmpty
    }

    /**
     Active workspace windows in persisted `orderNumber` order.

     Android's move-window menu uses `windowRepository.windowList`, not the visible/display-grouped
     ordering. Exposing this read-only list lets UI code build Android-parity move targets while
     keeping mutation centralized in `WindowManager`.
     */
    public var windowsInPersistedOrder: [Window] {
        guard let workspace = activeWorkspace else { return [] }
        return workspaceStore.windows(workspaceId: workspace.id)
    }

    /**
     Resolves Android's effective pin state for a window.

     - Parameter window: Window whose raw pin state should be combined with workspace auto-pin.
     - Returns: Effective pin mode used by visibility, ordering, and layout-weight behavior.
     - Side Effects: None.
     - Failure Modes: Detached windows fall back to their own workspace relationship and then to
       Android's enabled auto-pin default.
     */
    public func isEffectivelyPinned(_ window: Window) -> Bool {
        let autoPin = window.workspace?.workspaceSettings?.autoPin
            ?? activeWorkspace?.workspaceSettings?.autoPin
            ?? WorkspaceSettings.defaultAutoPin
        return window.effectivePinMode(autoPin: autoPin)
    }

    /**
     Returns the weight Android uses to render a window.

     - Parameter window: Window whose effective split weight is needed.
     - Returns: The raw window weight for effectively pinned windows, or the workspace's shared
       unpinned weight for effectively unpinned windows. Invalid values are clamped to `0.1`.
     - Side Effects: None.
     - Failure Modes: A missing shared unpinned weight falls back to the window's raw weight.
     */
    public func effectiveLayoutWeight(for window: Window) -> Float {
        let rawWeight = sanitizedLayoutWeight(window.layoutWeight)
        guard !isEffectivelyPinned(window) else { return rawWeight }
        let workspace = window.workspace ?? activeWorkspace
        return sanitizedLayoutWeight(workspace?.unPinnedWeight ?? rawWeight)
    }

    /// ID of the currently maximized window, if any.
    public var maximizedWindowId: UUID? {
        get { activeWorkspace?.maximizedWindowId }
        set { activeWorkspace?.maximizedWindowId = newValue }
    }

    // MARK: - Synchronized Scrolling

    /// Debounce work item for scroll sync (200ms matching Android WindowSync.kt:71).
    private var syncWorkItem: DispatchWorkItem?

    /**
     Callback to perform sync — set by the coordinator (BibleReaderView).
     Parameters: (sourceWindow, ordinal, key)
     */
    public var onSyncVerseChanged: ((Window, Int, String) -> Void)?

    /**
     Creates a window manager for a workspace-backed window set.
     - Parameter workspaceStore: Store used to load, mutate, and persist workspace windows.
     */
    public init(workspaceStore: WorkspaceStore) {
        self.workspaceStore = workspaceStore
    }

    // MARK: - Controller Registry

    /**
     Registers a pane controller and marks its window ready for pane-scoped actions.

     - Parameters:
       - controller: Controller created by the visible pane.
       - windowId: Identifier of the window now backed by `controller`.
     - Side Effects: Mutates the controller registry, clears pending readiness for `windowId`, and
       increments `controllerVersion` so SwiftUI consumers re-read registry-backed state.
     - Failure Modes: None; repeated registration for the same window replaces the stored
       controller.
     - Note: This is the normal transition from pending to ready.
     */
    public func registerController(_ controller: AnyObject, for windowId: UUID) {
        controllers[windowId] = controller
        controllerPendingWindowIds.remove(windowId)
        controllerVersion += 1
    }

    /**
     Unregisters a pane controller for a window that is leaving the workspace.

     - Parameter windowId: Identifier whose controller should be dropped.
     - Side Effects: Mutates controller and readiness registries, then increments
       `controllerVersion`.
     - Failure Modes: Missing controller entries are ignored.
     */
    public func unregisterController(for windowId: UUID) {
        controllers.removeValue(forKey: windowId)
        controllerPendingWindowIds.remove(windowId)
        controllerVersion += 1
    }

    /**
     Reports whether a specific visible window is waiting for controller registration.

     - Parameter windowId: Window identifier to inspect.
     - Returns: `true` when the window is visible but no controller has registered for it yet.
     - Side Effects: None.
     - Failure Modes: Unknown or hidden windows return `false`.
     */
    public func isControllerRegistrationPending(for windowId: UUID) -> Bool {
        controllerPendingWindowIds.contains(windowId)
    }

    // MARK: - Workspace Management

    /**
     Sets the active workspace and loads its windows through this manager's store context.

     - Parameter workspace: Workspace selected by the app, possibly resolved through another
       `ModelContext`.
     - Side Effects: Clears registered pane controllers, rebinds the workspace by ID into the
       manager-owned store when possible, refreshes visible/all window lists, and updates active
       window fallback.
     - Failure Modes: If the workspace cannot be resolved through the manager store, the supplied
       instance is retained and refresh may expose no windows until the store can fetch it.
     */
    public func setActiveWorkspace(_ workspace: Workspace) {
        // Clear controllers from the previous workspace to prevent stale entries
        controllers.removeAll()
        controllerPendingWindowIds.removeAll()
        activeWorkspace = workspaceStore.workspace(id: workspace.id) ?? workspace
        refreshWindows()
    }

    /**
     Refresh the visible windows list from the active workspace.
     Respects maximized state, filters minimized windows, and applies Android's display grouping
     so links windows render after normal content panes without mutating persisted order numbers.
     */
    public func refreshWindows() {
        guard let workspace = activeWorkspace else {
            visibleWindows = []
            allWindows = []
            controllerPendingWindowIds = []
            return
        }
        let persistedWindows = workspaceStore.windows(workspaceId: workspace.id)
        if normalizeWindowVisibility(persistedWindows) {
            workspaceStore.persistChanges()
        }
        allWindows = displayOrderedWindows(persistedWindows)

        // If a window is maximized, only show that one
        if let maxId = workspace.maximizedWindowId,
           let maxWindow = allWindows.first(where: { $0.id == maxId }) {
            visibleWindows = [maxWindow]
        } else {
            visibleWindows = allWindows.filter { $0.layoutState != "minimized" }
        }

        if activeWindow == nil || !visibleWindows.contains(where: { $0.id == activeWindow?.id }) {
            activeWindow = visibleWindows.first
        }
        reconcileControllerReadiness()
    }

    /**
     Focuses a window through the manager-owned lifecycle path.

     - Parameter window: Workspace window that should receive focus.
     - Side Effects: Restores a minimized target through `restoreWindow`; otherwise updates
       `activeWindow` when the target belongs to the active workspace.
     - Failure Modes: Windows outside the active workspace are ignored.
     */
    public func activateWindow(_ window: Window) {
        guard allWindows.contains(where: { $0.id == window.id }) else { return }
        if window.layoutState == "minimized" {
            restoreWindow(window)
        } else {
            activeWindow = window
        }
    }

    /**
     Applies Android's restore-strip tap behavior to one managed window.

     Android routes both visible and hidden restore buttons through `WindowControl.restoreWindow`.
     A window Android considers hidden is restored and focused; a visible window is minimized unless
     it is a terminal non-primary links window, which Android closes instead. Visibility includes
     Android's maximized-window rule rather than assuming every non-minimized window is on screen.
     The terminal check resolves the target identifier against current manager state so stale target
     metadata behaves like Android's nullable `ownTargetLinksWindow`.

     - Parameter window: Active-workspace window represented by the tapped restore-strip button.
     - Side Effects: Delegates to `restoreWindow`, `minimizeWindow`, or `removeWindow`, including
       their persistence, focus repair, controller cleanup, and published-window refresh behavior.
     - Failure Modes: Foreign windows are ignored. Existing lifecycle guards keep the final visible
       pane from being minimized and the final workspace window from being removed.
     - Note: Visibility is read at execution time rather than accepted from SwiftUI so a stale render
       snapshot cannot invert the requested transition.
     */
    public func toggleWindowVisibility(_ window: Window) {
        guard allWindows.contains(where: { $0.id == window.id }) else { return }

        if !isVisibleForAndroidRestoreAction(window) {
            restoreWindow(window)
            return
        }

        let isPrimaryLinksWindow = activeWorkspace?.primaryTargetLinksWindowId == window.id
        let isTerminalLinksWindow = window.isLinksWindow
            && explicitLinksWindowTarget(for: window) == nil
        if isTerminalLinksWindow && !isPrimaryLinksWindow {
            removeWindow(window)
        } else {
            minimizeWindow(window)
        }
    }

    /**
     Resolves Android's `Window.isVisible` branch for restore-strip actions.

     When a workspace is maximized, Android treats only the maximized pane as visible except for
     that pane's explicit chained links target. Outside that special case, any pane that is neither
     minimized nor closed is visible. Keeping this projection separate from `visibleWindows`
     preserves the chained-links exception and prevents a split-but-hidden peer from being
     misclassified as visible.

     - Parameter window: Managed window whose restore-strip action is being classified.
     - Returns: `true` when Android would take the visible minimize/close branch.
     - Side Effects: None.
     - Failure Modes: A stale maximized identifier falls back to ordinary layout-state visibility,
       matching `refreshWindows` repairing an unresolved maximized pane.
     */
    private func isVisibleForAndroidRestoreAction(_ window: Window) -> Bool {
        if let maximizedWindowId = activeWorkspace?.maximizedWindowId,
           let maximizedWindow = allWindows.first(where: { $0.id == maximizedWindowId }),
           maximizedWindow.targetLinksWindowId != window.id {
            return maximizedWindowId == window.id
        }
        return window.layoutState != "minimized" && window.layoutState != "closed"
    }

    // MARK: - Window Lifecycle

    /**
     Resolves the Android-style links target window for a source window.

     Every window first honors its own persisted `targetLinksWindowId`, matching Android's
     `Window.targetLinksWindow` lookup order. Without one, normal content windows route link
     results into the workspace primary links window, reusing an existing links window before
     creating a new one, while links windows chain a new target of their own — Android's
     recursive links-window behavior.

     - Parameter sourceWindow: Window that initiated the link navigation.
     - Returns: Existing or newly created links window, or `nil` when no workspace is active or
       creation fails.
     - Side Effects: May create a window, mark it as a links target, update
       `primaryTargetLinksWindowId` or `targetLinksWindowId`, unminimize an existing target, adjust
       active-window focus when restoring a hidden target, and refresh the visible window lists.
     - Failure Modes: Returns `nil` if there is no active workspace or `addWindow` cannot create a
       target window.
     - Note: Newly created visible links windows do not steal focus from the source window; Android
       only switches focus when an existing hidden links window is restored.
     */
    @discardableResult
    public func linksWindow(for sourceWindow: Window) -> Window? {
        guard activeWorkspace != nil else { return nil }

        let previousActiveWindow = activeWindow
        var createdLinksWindow = false
        let linksWindow: Window

        if let existing = explicitLinksWindowTarget(for: sourceWindow) {
            // Android's `Window.targetLinksWindow` consults the window's own persisted target
            // before any kind-specific fallback, so Android-synced workspaces whose normal
            // windows carry `targetLinksWindowId` route to that exact window instead of the
            // workspace primary.
            linksWindow = existing
        } else if sourceWindow.isLinksWindow {
            if let newWindow = createLinksWindow(from: sourceWindow) {
                sourceWindow.targetLinksWindowId = newWindow.id
                linksWindow = newWindow
                createdLinksWindow = true
            } else {
                return nil
            }
        } else if let existing = primaryLinksWindow() {
            linksWindow = existing
        } else if let newWindow = createLinksWindow(from: sourceWindow) {
            activeWorkspace?.primaryTargetLinksWindowId = newWindow.id
            linksWindow = newWindow
            createdLinksWindow = true
        } else {
            return nil
        }

        // Android treats both CLOSED and MINIMISED targets as non-visible and reveals the
        // selected links window, so a persisted explicit target in either hidden state is
        // restored before receiving the link result.
        if linksWindow.layoutState == "minimized" || linksWindow.layoutState == "closed" {
            restoreWindow(linksWindow)
        } else if createdLinksWindow, let previousActiveWindow {
            activeWindow = previousActiveWindow
        }

        workspaceStore.persistChanges()
        refreshWindows()
        return linksWindow
    }

    /**
     Minimizes one visible window without allowing the workspace to become empty.

     - Parameter window: Visible active-workspace window to hide.
     - Side Effects: Persists the minimized layout state, repairs focus when needed, and refreshes
       observable window lists.
     - Failure Modes: Hidden windows, foreign windows, and the final visible window are ignored.
     */
    public func minimizeWindow(_ window: Window) {
        guard visibleWindows.contains(where: { $0.id == window.id }), visibleWindows.count > 1 else {
            return
        }
        window.layoutState = "minimized"
        if activeWindow?.id == window.id {
            activeWindow = visibleWindows.first(where: { $0.id != window.id })
        }
        workspaceStore.persistChanges()
        refreshWindows()
    }

    /**
     Restores and focuses a minimized window while enforcing Android's unpinned-pane invariant.

     - Parameter window: Active-workspace window to reveal.
     - Side Effects: If the target is an effectively unpinned normal window, minimizes every peer
       in that category; then persists the target as visible, refreshes lists, and focuses it.
     - Failure Modes: Windows outside the active workspace are ignored.
     */
    public func restoreWindow(_ window: Window) {
        guard windowsInPersistedOrder.contains(where: { $0.id == window.id }) else { return }
        if !isEffectivelyPinned(window), !window.isLinksWindow {
            minimizeUnpinnedNormalPeers(except: window)
        }
        window.layoutState = "split"
        activeWindow = window
        workspaceStore.persistChanges()
        refreshWindows()
    }

    /**
     Adds a new window to the active workspace, optionally copying state from an existing window.
     - Parameters:
       - document: Optional Bible-module override. A clone otherwise preserves the source's Bible
         slot together with every other category slot.
       - category: Initial category for a fresh window. Clones preserve the source category exactly.
       - sourceWindow: Existing window whose raw pin state, sync state, links role, layout weight,
         and complete reader state should be cloned.
     - Returns: The newly created window, or `nil` when no workspace is active.
     - Side Effects: Inserts a window, exits maximized layout so the new active pane can render,
       refreshes display ordering, focuses the new window, and marks visible windows without
       registered controllers as pending.
     - Note: A source without a page manager fails instead of creating a misleading Bible clone.
     */
    @discardableResult
    public func addWindow(document: String? = nil, category: String = "bible", from sourceWindow: Window? = nil) -> Window? {
        createManagedWindow(
            document: document,
            category: category,
            from: sourceWindow,
            asLinksWindow: sourceWindow?.isLinksWindow ?? false,
            focusesNewWindow: true
        )
    }

    /**
     Creates and publishes one manager-owned window with its final window kind known up front.

     - Parameters:
       - document: Explicit Bible-slot override, or `nil` to inherit the source Bible document.
       - category: Initial category used only when creating a fresh window without a source.
       - sourceWindow: Optional window whose persisted reader and raw pane state should be cloned.
       - asLinksWindow: Whether the new window is an auxiliary links target.
       - focusesNewWindow: Whether this user-facing creation should focus the result. Internal links
         targets leave this false so link routing does not steal focus from the source pane.
     - Returns: The inserted window, or `nil` when there is no active workspace.
     - Side Effects: Inserts and persists the window graph, exits maximized layout, normalizes
       effectively unpinned normal panes, refreshes manager collections, and focuses ordinary
       windows. Links windows preserve the current focus.
     - Failure Modes: Missing active workspace or a source page manager returns `nil` without
       inserting a fallback pane.
     */
    private func createManagedWindow(
        document: String?,
        category: String,
        from sourceWindow: Window?,
        asLinksWindow: Bool,
        focusesNewWindow: Bool = false
    ) -> Window? {
        guard let workspace = activeWorkspace else { return nil }
        let window: Window
        if let source = sourceWindow {
            guard let clonedWindow = workspaceStore.addWindow(
                to: workspace,
                cloning: source,
                asLinksWindow: asLinksWindow
            ) else {
                return nil
            }
            window = clonedWindow
            if let document {
                window.pageManager?.bibleDocument = document
            }

            // Android appends clones of links panes; ordinary clones are inserted after the source.
            if !source.isLinksWindow {
                window.orderNumber = source.orderNumber + 1
                for w in allWindows where w.orderNumber >= window.orderNumber && w.id != window.id {
                    w.orderNumber += 1
                }
            }
        } else {
            window = workspaceStore.addWindow(to: workspace, document: document, category: category)
            window.isLinksWindow = asLinksWindow
        }

        // Intentional divergence from Android: Android's window creation never touches
        // `maximizedWindowId`, leaving a new window active but hidden behind the maximized pane.
        // iOS exits maximize so the created window is immediately visible. Link results never
        // reach this path while maximized because the pane-level links gate opens them in the
        // current window, matching Android's `checkIfOpenLinksInDedicatedWindow`.
        if workspace.maximizedWindowId != nil {
            workspace.maximizedWindowId = nil
        }

        if !isEffectivelyPinned(window) {
            initializeUnpinnedWeightIfNeeded(from: window)
            if !window.isLinksWindow {
                minimizeUnpinnedNormalPeers(except: window)
            }
        }
        window.layoutState = "split"
        if focusesNewWindow {
            activeWindow = window
        }
        workspaceStore.persistChanges()
        refreshWindows()
        return window
    }

    /**
     Recomputes controller readiness from the current visible window set.

     - Side Effects: Replaces `controllerPendingWindowIds` with visible windows lacking registered
       controllers.
     - Failure Modes: None.
     - Important: The pending set intentionally excludes minimized or otherwise hidden windows,
       because SwiftUI is not expected to instantiate panes for those windows until they become
       visible again.
     */
    private func reconcileControllerReadiness() {
        let nextPendingWindowIds = Set(visibleWindows.compactMap { window in
            controllers[window.id] == nil ? window.id : nil
        })
        if controllerPendingWindowIds != nextPendingWindowIds {
            controllerPendingWindowIds = nextPendingWindowIds
        }
    }

    /**
     Removes a window from the active workspace.

     The window is detached from published reader state before its SwiftData graph is deleted. That
     ordering prevents SwiftUI from re-evaluating a pane with a deleted `Window` or cascaded
     `PageManager` during the close transaction.
     */
    public func removeWindow(_ window: Window) {
        let persistedWindows = windowsInPersistedOrder
        guard persistedWindows.count > 1,
              let removedIndex = persistedWindows.firstIndex(where: { $0.id == window.id }) else {
            return
        }

        let removedWindowId = window.id
        let remainingWindows = persistedWindows.filter { $0.id != removedWindowId }
        let nearestWindow = remainingWindows[min(removedIndex, remainingWindows.count - 1)]
        let remainingVisibleWindows = visibleWindows.filter { $0.id != removedWindowId }
        let nextActiveWindow: Window
        if remainingVisibleWindows.isEmpty {
            nearestWindow.layoutState = "split"
            if !isEffectivelyPinned(nearestWindow), !nearestWindow.isLinksWindow {
                minimizeUnpinnedNormalPeers(except: nearestWindow, in: remainingWindows)
            }
            nextActiveWindow = nearestWindow
        } else {
            nextActiveWindow = remainingVisibleWindows.first ?? nearestWindow
        }

        unregisterController(for: removedWindowId)
        if activeWorkspace?.maximizedWindowId == removedWindowId {
            activeWorkspace?.maximizedWindowId = nil
        }
        visibleWindows.removeAll { $0.id == removedWindowId }
        allWindows.removeAll { $0.id == removedWindowId }
        if activeWindow?.id == removedWindowId {
            activeWindow = nextActiveWindow
        }
        workspaceStore.delete(window)
        refreshWindows()

        if visibleWindows.count == 1, let onlyWindow = visibleWindows.first {
            setLayoutWeight(1.0, for: onlyWindow)
            workspaceStore.persistChanges()
        }
    }

    /**
     Maximizes one active-workspace window and persists the workspace layout selection.

     - Parameter window: Window to display as the sole maximized pane.
     - Side Effects: Stores the maximized identifier, focuses the target, saves, and refreshes.
     - Failure Modes: Foreign windows are ignored.
     */
    public func maximizeWindow(_ window: Window) {
        guard allWindows.contains(where: { $0.id == window.id }) else { return }
        activeWorkspace?.maximizedWindowId = window.id
        activeWindow = window
        workspaceStore.persistChanges()
        refreshWindows()
    }

    /// Swap the order of two windows (move up/down).
    public func swapWindowOrder(_ window1: Window, _ window2: Window) {
        workspaceStore.swapWindowOrder(window1, window2)
        refreshWindows()
    }

    /**
     Moves a window to Android's absolute position inside its current pin-mode bucket.

     Android's pane menu builds `Move to...` rows from `windowList.filter { isPinMode matches }`
     and passes the target row's zero-based order into `moveWindowToPosition`. This method mirrors
     that behavior: pinned and unpinned buckets are reordered independently, then persisted as one
     workspace order while display grouping still keeps links windows at the end.

     - Parameters:
       - window: Window to reposition.
       - position: Zero-based target position inside the window's current pin-mode bucket.
     - Side Effects: Rewrites persisted window order numbers through `WorkspaceStore` and refreshes
       visible/all window lists.
     - Failure Modes: Missing active workspace, missing source window, or out-of-range positions
       are ignored.
     */
    public func moveWindow(_ window: Window, toPosition position: Int) {
        guard let workspace = activeWorkspace else { return }
        let workspaceWindows = workspaceStore.windows(workspaceId: workspace.id)
        var pinnedWindows = workspaceWindows.filter(isEffectivelyPinned)
        var unpinnedWindows = workspaceWindows.filter { !isEffectivelyPinned($0) }
        let targetIsPinned = isEffectivelyPinned(window)
        var targetBucket = targetIsPinned ? pinnedWindows : unpinnedWindows

        guard let originalIndex = targetBucket.firstIndex(where: { $0.id == window.id }),
              position >= 0,
              position < targetBucket.count else {
            return
        }

        let movedWindow = targetBucket.remove(at: originalIndex)
        targetBucket.insert(movedWindow, at: position)

        if targetIsPinned {
            pinnedWindows = targetBucket
        } else {
            unpinnedWindows = targetBucket
        }

        workspaceStore.reorderWindows(pinnedWindows + unpinnedWindows)
        refreshWindows()
    }

    /**
     Converts a links window into a normal window using Android's clone-and-close behavior.

     Android handles `Change to normal window` by adding a new window from the links source,
     clearing `isLinksWindow`, and then closing the original links window. The source pin state is
     intentionally preserved because Android does not clear it during conversion.

     - Parameter window: Links window to convert.
     - Returns: Newly created normal window, or `nil` when the source is not a links window or
       window creation fails.
     - Side Effects: Adds a cloned window, clears its links flag, removes the source links window,
       focuses the new window, and refreshes visible/all window lists.
     - Failure Modes: Returns `nil` without mutation for non-links windows or inactive workspaces.
     */
    @discardableResult
    public func changeLinksWindowToNormal(_ window: Window) -> Window? {
        guard window.isLinksWindow,
              let newWindow = createManagedWindow(
                  document: nil,
                  category: "bible",
                  from: window,
                  asLinksWindow: false,
                  focusesNewWindow: true
              ) else {
            return nil
        }

        removeWindow(window)
        activeWindow = newWindow
        refreshWindows()
        return newWindow
    }

    /**
     Mirrors Android's `WindowControl.setPinMode` behavior for pane-menu pin changes.

     Pinning a hidden window restores it. Unpinning a visible normal window minimizes it when
     another unpinned normal window is already visible, matching Android's one-active-unpinned-pane
     rule. Links windows should not call this method because their menu row is hidden.

     - Parameters:
       - window: Window whose pin state should change.
       - value: New pin-mode value.
     - Side Effects: Persists raw pin/layout state and refreshes observable window lists.
     - Failure Modes: Links windows and foreign windows are ignored.
     */
    public func setPinMode(_ window: Window, value: Bool) {
        guard !window.isLinksWindow,
              windowsInPersistedOrder.contains(where: { $0.id == window.id }) else {
            return
        }
        guard window.isPinMode != value else { return }
        window.isPinMode = value

        if isEffectivelyPinned(window), window.layoutState == "minimized" {
            restoreWindow(window)
            return
        }

        if !isEffectivelyPinned(window),
           window.layoutState != "minimized",
           visibleWindows.filter({ !isEffectivelyPinned($0) && !$0.isLinksWindow }).count > 1 {
            initializeUnpinnedWeightIfNeeded(from: window)
            window.layoutState = "minimized"
            if activeWindow?.id == window.id {
                activeWindow = visibleWindows.first(where: { $0.id != window.id })
            }
            workspaceStore.persistChanges()
            refreshWindows()
            return
        }

        if !isEffectivelyPinned(window) {
            initializeUnpinnedWeightIfNeeded(from: window)
        }
        workspaceStore.persistChanges()
        refreshWindows()
    }

    /**
     Applies the workspace auto-pin setting through Android's normalization path.

     - Parameter value: New workspace auto-pin value.
     - Side Effects: Persists workspace settings and, when auto-pin is disabled, minimizes every
       effectively unpinned normal window after the first persisted one.
     - Failure Modes: No active workspace is a no-op.
     - Note: Raw per-window pin values are preserved so they become effective again when auto-pin is
       later disabled.
     */
    public func setAutoPinEnabled(_ value: Bool) {
        guard let workspace = activeWorkspace else { return }
        var settings = workspace.workspaceSettings ?? WorkspaceSettings()
        settings.autoPin = value
        settings.normalizeAutoAssignPrimaryLabel()
        workspace.workspaceSettings = settings

        let windows = workspaceStore.windows(workspaceId: workspace.id)
        if !value {
            let unpinnedNormalWindows = windows.filter {
                !$0.isLinksWindow && !isEffectivelyPinned($0)
            }
            if let first = unpinnedNormalWindows.first {
                initializeUnpinnedWeightIfNeeded(from: first)
                for window in unpinnedNormalWindows.dropFirst() {
                    window.layoutState = "minimized"
                }
            }
        }

        workspaceStore.persistChanges()
        refreshWindows()
    }

    /**
     Updates adjacent pane weights and optionally commits the drag result.

     - Parameters:
       - firstWindow: Leading or upper pane.
       - firstWeight: New effective weight for `firstWindow`.
       - secondWindow: Trailing or lower pane.
       - secondWeight: New effective weight for `secondWindow`.
       - persist: Whether this update completes the gesture and should be saved.
     - Side Effects: Updates raw pinned weights or the workspace's shared unpinned weight. Saves only
       when `persist` is `true`.
     - Failure Modes: Foreign windows are ignored; non-finite or undersized weights clamp to `0.1`.
     */
    public func resizeWindows(
        _ firstWindow: Window,
        firstWeight: Float,
        _ secondWindow: Window,
        secondWeight: Float,
        persist: Bool
    ) {
        let activeWindowIds = Set(windowsInPersistedOrder.map(\.id))
        guard activeWindowIds.contains(firstWindow.id), activeWindowIds.contains(secondWindow.id) else {
            return
        }
        setLayoutWeight(firstWeight, for: firstWindow)
        setLayoutWeight(secondWeight, for: secondWindow)
        if persist {
            workspaceStore.persistChanges()
        }
    }

    /**
     Restores the active workspace from maximized layout.

     - Side Effects: Clears the maximized identifier, normalizes visible unpinned panes, persists,
       and refreshes observable window lists.
     - Failure Modes: No active workspace is a no-op.
     */
    public func unmaximize() {
        guard activeWorkspace != nil else { return }
        activeWorkspace?.maximizedWindowId = nil
        workspaceStore.persistChanges()
        refreshWindows()
    }

    /// Check if a window is maximized.
    public var isMaximized: Bool {
        activeWorkspace?.maximizedWindowId != nil
    }

    // MARK: - Synchronization

    /**
     Mirrors Android's `WindowControl.setSynchronised` for pane-menu disable behavior.

     - Parameters:
       - window: Window whose synchronization flag should change.
       - value: New synchronization state.
     - Side Effects: Mutates the window, refreshes observable window lists, and leaves sync-group
       membership unchanged.
     - Failure Modes: None.
     */
    public func setSynchronized(_ window: Window, value: Bool) {
        guard window.isSynchronized != value else { return }
        window.isSynchronized = value
        workspaceStore.persistChanges()
        refreshWindows()
    }

    /**
     Mirrors Android's `WindowControl.changeSyncGroup` selection and realignment behavior.

     Selecting a sync group enables synchronization, chooses Android's first visible synchronized
     verse-key peer in that group, and synchronously forwards the peer's source-local position through
     the existing reader callback. The callback resolves a stable source reference before each target
     converts it into its own ordinal space, preserving feedback suppression and versification safety.

     - Parameters:
       - window: Window whose synchronization group should be selected.
       - groupNumber: Zero-based group identifier matching Android's internal storage.
     - Side Effects: Enables synchronization, updates `syncGroup`, may synchronously realign grouped
       panes through `onSyncVerseChanged`, persists the workspace, and refreshes observable state.
     - Failure Modes: Out-of-range groups are ignored. Missing controllers, non-verse peers, and
       unresolved source positions preserve the group change without issuing a sync callback.
     - Note: The callback runs after the new group flags are set and before persistence/refresh,
       matching Android's synchronize-before-`WindowChangedEvent` ordering.
     */
    public func changeSyncGroup(_ window: Window, groupNumber: Int) {
        guard (0..<6).contains(groupNumber) else { return }
        window.isSynchronized = true
        window.syncGroup = groupNumber
        synchronizeImmediatelyFromPeer(joining: window)
        workspaceStore.persistChanges()
        refreshWindows()
    }

    /**
     Emits the first eligible peer's current position through the established synchronization path.

     - Parameter window: Newly synchronized window joining its selected stored group.
     - Side Effects: Calls `onSyncVerseChanged` synchronously when a visible registered peer can
       provide a valid source-local position. The callback may update other grouped panes.
     - Failure Modes: Returns without callback when no matching peer/controller/position exists.
     - Note: Peer ordering follows `visibleWindows`, matching Android's `firstOrNull` selection.
     */
    private func synchronizeImmediatelyFromPeer(joining window: Window) {
        guard let peer = visibleWindows.first(where: { candidate in
            guard candidate.id != window.id,
                  candidate.isSynchronized,
                  candidate.syncGroup == window.syncGroup,
                  let source = controllers[candidate.id] as? any WindowSynchronizationSource else {
                return false
            }
            return source.canProvideWindowSynchronizationPosition
        }),
        let source = controllers[peer.id] as? any WindowSynchronizationSource,
        let position = source.currentWindowSynchronizationPosition() else {
            return
        }

        onSyncVerseChanged?(peer, position.ordinal, position.key)
    }

    /// Get windows in the same sync group as the given window.
    public func syncedWindows(for window: Window) -> [Window] {
        visibleWindows.filter { $0.syncGroup == window.syncGroup && $0.isSynchronized }
    }

    /**
     Returns synchronized peer windows that still need a visible-verse update from the source.

     Android's `WindowSync` updates an inactive window's Bible key, then compares the old key before
     posting a secondary scroll. This mirrors that contract at the persisted window-state level: a
     target whose concrete Bible book/chapter/verse already equals the source is not asked to scroll
     again, while incomplete state is treated as stale so the existing sync path can repair it.

     - Parameter sourceWindow: Window that reported the latest visible verse.
     - Returns: Visible synchronized peer windows in the same sync group that differ from the source
       Bible position or lack a complete comparable position.
     - Side Effects: None.
     - Failure Modes: Returns an empty list when the source itself is not synchronized.
     */
    public func synchronizedVerseUpdateTargets(for sourceWindow: Window) -> [Window] {
        guard sourceWindow.isSynchronized else { return [] }
        return syncedWindows(for: sourceWindow).filter { target in
            guard target.id != sourceWindow.id else { return false }
            guard let sourcePM = sourceWindow.pageManager,
                  let targetPM = target.pageManager,
                  let sourceBook = sourcePM.bibleBibleBook,
                  let sourceChapter = sourcePM.bibleChapterNo,
                  let sourceVerse = sourcePM.bibleVerseNo,
                  let targetBook = targetPM.bibleBibleBook,
                  let targetChapter = targetPM.bibleChapterNo,
                  let targetVerse = targetPM.bibleVerseNo else {
                return true
            }
            return sourceBook != targetBook
                || sourceChapter != targetChapter
                || sourceVerse != targetVerse
        }
    }

    /// Notify that a verse changed in a window — triggers debounced sync to other windows.
    public func notifyVerseChanged(sourceWindow: Window, ordinal: Int, key: String) {
        guard sourceWindow.isSynchronized else { return }
        syncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onSyncVerseChanged?(sourceWindow, ordinal, key)
        }
        syncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /**
     Orders windows using Android's visible/tab grouping without mutating persisted order numbers.

     Android sorts normal pinned panes first, normal unpinned panes second, and links windows last.
     The stored `orderNumber` remains the within-group tiebreaker so user-managed ordering and
     remote-sync payloads keep their persisted meaning.

     - Parameter windows: Workspace windows in any persisted order.
     - Returns: Windows ordered for display and tab iteration.
     - Side Effects: None.
     - Failure Modes: None.
     */
    private func displayOrderedWindows(_ windows: [Window]) -> [Window] {
        windows.sorted { lhs, rhs in
            let lhsGroup = displayOrderGroup(for: lhs)
            let rhsGroup = displayOrderGroup(for: rhs)
            if lhsGroup != rhsGroup {
                return lhsGroup < rhsGroup
            }
            if lhs.orderNumber != rhs.orderNumber {
                return lhs.orderNumber < rhs.orderNumber
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /**
     Computes the Android display group for one window.

     - Parameter window: Window whose display bucket should be calculated.
     - Returns: `0` for normal pinned windows, `1` for normal unpinned windows, and `2` for links
       windows.
     - Side Effects: None.
     - Failure Modes: None.
     */
    private func displayOrderGroup(for window: Window) -> Int {
        if window.isLinksWindow { return 2 }
        return isEffectivelyPinned(window) ? 0 : 1
    }

    /**
     Repairs impossible visible-window state before publishing manager collections.

     - Parameters:
       - windows: Active workspace windows in persisted order.
       - preferredWindow: Optional unpinned normal window that should remain visible.
     - Returns: `true` when persisted layout or maximized metadata changed.
     - Side Effects: Clears stale maximized identifiers, restores an empty workspace to one visible
       window, and minimizes surplus visible effectively unpinned normal windows.
     - Failure Modes: An empty workspace remains empty.
     */
    private func normalizeWindowVisibility(
        _ windows: [Window],
        preferredWindow: Window? = nil
    ) -> Bool {
        guard !windows.isEmpty else { return false }
        var changed = false

        if let maximizedWindowId = activeWorkspace?.maximizedWindowId {
            if windows.contains(where: { $0.id == maximizedWindowId }) {
                return false
            }
            activeWorkspace?.maximizedWindowId = nil
            changed = true
        }

        var visible = windows.filter { $0.layoutState != "minimized" }
        if visible.isEmpty {
            let fallback = preferredWindow.flatMap { preferred in
                windows.first(where: { $0.id == preferred.id })
            } ?? windows[0]
            fallback.layoutState = "split"
            visible = [fallback]
            changed = true
        }

        let visibleUnpinnedNormalWindows = visible.filter {
            !$0.isLinksWindow && !isEffectivelyPinned($0)
        }
        guard visibleUnpinnedNormalWindows.count > 1 else { return changed }

        let retainedWindow = preferredWindow.flatMap { preferred in
            visibleUnpinnedNormalWindows.first(where: { $0.id == preferred.id })
        } ?? visibleUnpinnedNormalWindows[0]
        initializeUnpinnedWeightIfNeeded(from: retainedWindow)
        for window in visibleUnpinnedNormalWindows where window.id != retainedWindow.id {
            window.layoutState = "minimized"
            changed = true
        }
        return changed
    }

    /**
     Minimizes all effectively unpinned normal peers of a target window.

     - Parameters:
       - retainedWindow: Window that should remain available.
       - windows: Candidate workspace windows, defaulting to current persisted order.
     - Side Effects: Mutates peer layout states to `minimized`.
     - Failure Modes: Pinned and links windows are never changed.
     */
    private func minimizeUnpinnedNormalPeers(
        except retainedWindow: Window,
        in windows: [Window]? = nil
    ) {
        for window in windows ?? windowsInPersistedOrder
        where window.id != retainedWindow.id
            && !window.isLinksWindow
            && !isEffectivelyPinned(window) {
            window.layoutState = "minimized"
        }
    }

    /**
     Initializes Android's shared unpinned weight when a workspace first exposes an unpinned pane.

     - Parameter window: Window whose raw layout weight seeds the workspace value.
     - Side Effects: Writes `Workspace.unPinnedWeight` only when it is currently absent.
     - Failure Modes: Detached windows use the active workspace when available; otherwise no change.
     */
    private func initializeUnpinnedWeightIfNeeded(from window: Window) {
        guard let workspace = window.workspace ?? activeWorkspace,
              workspace.unPinnedWeight == nil else {
            return
        }
        workspace.unPinnedWeight = sanitizedLayoutWeight(window.layoutWeight)
    }

    /**
     Stores one effective pane weight using Android's pinned/shared-unpinned rule.

     - Parameters:
       - value: Requested effective weight.
       - window: Window receiving the weight.
     - Side Effects: Mutates either `Window.layoutWeight` or `Workspace.unPinnedWeight`.
     - Failure Modes: Detached unpinned windows without an active workspace are ignored.
     */
    private func setLayoutWeight(_ value: Float, for window: Window) {
        let sanitizedValue = sanitizedLayoutWeight(value)
        if isEffectivelyPinned(window) {
            window.layoutWeight = sanitizedValue
        } else {
            (window.workspace ?? activeWorkspace)?.unPinnedWeight = sanitizedValue
        }
    }

    /**
     Clamps a persisted pane weight to a finite positive layout value.

     - Parameter value: Raw weight loaded from persistence or a drag gesture.
     - Returns: `value` clamped to at least `0.1`, or `0.1` when non-finite.
     - Side Effects: None.
     - Failure Modes: None.
     */
    private func sanitizedLayoutWeight(_ value: Float) -> Float {
        guard value.isFinite else { return 0.1 }
        return max(0.1, value)
    }

    /**
     Finds the primary links window recorded on the active workspace.

     - Returns: Existing primary links window, or the first available links window if the stored
       identifier is missing or stale.
     - Side Effects: Repairs `primaryTargetLinksWindowId` when an existing links window is reused.
     - Failure Modes: Returns `nil` when no links window exists.
     */
    private func primaryLinksWindow() -> Window? {
        if let existingId = activeWorkspace?.primaryTargetLinksWindowId,
           let existing = allWindows.first(where: { $0.id == existingId }) {
            return existing
        }

        guard let existing = allWindows.first(where: { $0.isLinksWindow }) else {
            return nil
        }
        activeWorkspace?.primaryTargetLinksWindowId = existing.id
        return existing
    }

    /**
     Finds a links window chained from another links window.

     - Parameter sourceWindow: Links window that initiated a nested link result.
     - Returns: Explicit target window if its stored identifier still exists.
     - Side Effects: None.
     - Failure Modes: Returns `nil` for missing or stale target identifiers.
     */
    private func explicitLinksWindowTarget(for sourceWindow: Window) -> Window? {
        guard let existingId = sourceWindow.targetLinksWindowId else { return nil }
        return allWindows.first(where: { $0.id == existingId })
    }

    /**
     Creates a window configured as an Android links target.

     - Parameter sourceWindow: Window whose reading position and layout weight seed the new target.
     - Returns: Newly created links window, or `nil` when `addWindow` fails.
     - Side Effects: Inserts a window through `WorkspaceStore`, copies the source position and raw
       pin state via `addWindow`, then marks the result as a non-synchronized links window.
     - Failure Modes: Returns `nil` if there is no active workspace.
     */
    private func createLinksWindow(from sourceWindow: Window) -> Window? {
        guard let newWindow = createManagedWindow(
            document: nil,
            category: "bible",
            from: sourceWindow,
            asLinksWindow: true
        ) else {
            return nil
        }
        newWindow.isSynchronized = false
        return newWindow
    }
}
