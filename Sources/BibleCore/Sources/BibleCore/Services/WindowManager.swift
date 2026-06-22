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

    /// Set the active workspace and load its windows.
    public func setActiveWorkspace(_ workspace: Workspace) {
        // Clear controllers from the previous workspace to prevent stale entries
        controllers.removeAll()
        controllerPendingWindowIds.removeAll()
        activeWorkspace = workspace
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
        allWindows = displayOrderedWindows(workspaceStore.windows(workspaceId: workspace.id))

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

    // MARK: - Window Lifecycle

    /**
     Resolves the Android-style links target window for a source window.

     Normal content windows route link results into the workspace primary links window, reusing an
     existing links window before creating a new one. Links windows keep their own chained target
     through `targetLinksWindowId`, matching Android's recursive links-window behavior.

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

        if sourceWindow.isLinksWindow {
            if let existing = explicitLinksWindowTarget(for: sourceWindow) {
                linksWindow = existing
            } else if let newWindow = createLinksWindow(from: sourceWindow) {
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

        if linksWindow.layoutState == "minimized" {
            linksWindow.layoutState = "split"
            activeWindow = linksWindow
        } else if createdLinksWindow, let previousActiveWindow {
            activeWindow = previousActiveWindow
        }

        refreshWindows()
        return linksWindow
    }

    /// Minimize a window (hides it from the visible list).
    public func minimizeWindow(_ window: Window) {
        window.layoutState = "minimized"
        if activeWindow?.id == window.id {
            activeWindow = visibleWindows.first(where: { $0.id != window.id })
        }
        refreshWindows()
    }

    /// Restore a minimized window — adds it back to the split view alongside existing windows.
    public func restoreWindow(_ window: Window) {
        window.layoutState = "split"
        refreshWindows()
        activeWindow = window
    }

    /**
     Adds a new window to the active workspace, optionally copying state from an existing window.
     - Parameters:
       - document: Explicit document/module to open. When `nil`, the source window's Bible document is reused.
       - category: Category to use when no eligible source category is inherited.
       - sourceWindow: Existing window whose sync state, layout weight, and reading position should be cloned.
     - Returns: The newly created window, or `nil` when no workspace is active.
     - Side Effects: Inserts a window, exits maximized layout so the new active pane can render,
       refreshes display ordering, focuses the new window, and marks visible windows without
       registered controllers as pending.
     - Note: Non-Bible categories such as dictionary or EPUB are intentionally not inherited; new windows fall back to Bible/commentary semantics.
     */
    @discardableResult
    public func addWindow(document: String? = nil, category: String = "bible", from sourceWindow: Window? = nil) -> Window? {
        guard let workspace = activeWorkspace else { return nil }
        let doc = document ?? sourceWindow?.pageManager?.bibleDocument
        // Don't inherit non-Bible categories (epub, dictionary, etc.) — new windows start as Bible
        let sourceCat = sourceWindow?.pageManager?.currentCategoryName
        let cat = (sourceCat == "bible" || sourceCat == "commentary") ? (sourceCat ?? category) : category
        let window = workspaceStore.addWindow(to: workspace, document: doc, category: cat)

        // Copy properties from source window
        if let source = sourceWindow {
            window.isSynchronized = source.isSynchronized
            window.syncGroup = source.syncGroup
            window.layoutWeight = source.layoutWeight

            // Copy position
            if let pm = window.pageManager, let spm = source.pageManager {
                pm.bibleBibleBook = spm.bibleBibleBook
                pm.bibleChapterNo = spm.bibleChapterNo
                pm.bibleVerseNo = spm.bibleVerseNo
                pm.commentaryDocument = spm.commentaryDocument
            }

            // Insert after source in order
            window.orderNumber = source.orderNumber + 1
            // Shift subsequent windows
            for w in allWindows where w.orderNumber >= window.orderNumber && w.id != window.id {
                w.orderNumber += 1
            }
        }

        if workspace.maximizedWindowId != nil {
            workspace.maximizedWindowId = nil
        }

        refreshWindows()
        activeWindow = window
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

    /// Remove a window from the workspace.
    public func removeWindow(_ window: Window) {
        unregisterController(for: window.id)
        workspaceStore.delete(window)
        refreshWindows()
    }

    /// Maximize a window (hide others).
    public func maximizeWindow(_ window: Window) {
        activeWorkspace?.maximizedWindowId = window.id
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
        var pinnedWindows = workspaceWindows.filter(\.isPinMode)
        var unpinnedWindows = workspaceWindows.filter { !$0.isPinMode }
        var targetBucket = window.isPinMode ? pinnedWindows : unpinnedWindows

        guard let originalIndex = targetBucket.firstIndex(where: { $0.id == window.id }),
              position >= 0,
              position < targetBucket.count else {
            return
        }

        let movedWindow = targetBucket.remove(at: originalIndex)
        targetBucket.insert(movedWindow, at: position)

        if window.isPinMode {
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
              let newWindow = addWindow(from: window) else {
            return nil
        }

        newWindow.isLinksWindow = false
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
     - Side Effects: Mutates pin/layout state and refreshes observable window lists.
     - Failure Modes: None.
     */
    public func setPinMode(_ window: Window, value: Bool) {
        guard window.isPinMode != value else { return }
        window.isPinMode = value

        if value && window.layoutState == "minimized" {
            restoreWindow(window)
            return
        }

        if !value,
           window.layoutState != "minimized",
           visibleWindows.filter({ !$0.isPinMode && !$0.isLinksWindow }).count > 1 {
            minimizeWindow(window)
            return
        }

        refreshWindows()
    }

    /// Restore all windows from maximized state.
    public func unmaximize() {
        activeWorkspace?.maximizedWindowId = nil
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
        refreshWindows()
    }

    /**
     Mirrors Android's `WindowControl.changeSyncGroup` selection behavior.

     Selecting a sync group also enables synchronization for the window. Actual verse realignment is
     handled by existing scroll/navigation sync paths after state changes propagate.

     - Parameters:
       - window: Window whose synchronization group should be selected.
       - groupNumber: Zero-based group identifier matching Android's internal storage.
     - Side Effects: Enables synchronization, updates `syncGroup`, and refreshes observable window
       state.
     - Failure Modes: Out-of-range groups are ignored.
     */
    public func changeSyncGroup(_ window: Window, groupNumber: Int) {
        guard (0..<6).contains(groupNumber) else { return }
        window.isSynchronized = true
        window.syncGroup = groupNumber
        refreshWindows()
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
        return window.isPinMode ? 0 : 1
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
     - Side Effects: Inserts a window through `WorkspaceStore`, copies the source position via
       `addWindow`, then marks the result as a non-synchronized pinned links window.
     - Failure Modes: Returns `nil` if there is no active workspace.
     */
    private func createLinksWindow(from sourceWindow: Window) -> Window? {
        guard let newWindow = addWindow(from: sourceWindow) else { return nil }
        newWindow.isLinksWindow = true
        newWindow.isPinMode = true
        newWindow.isSynchronized = false
        return newWindow
    }
}
