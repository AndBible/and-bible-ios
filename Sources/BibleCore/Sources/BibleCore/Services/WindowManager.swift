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

    /// Register a controller for a window.
    public func registerController(_ controller: AnyObject, for windowId: UUID) {
        controllers[windowId] = controller
        controllerVersion += 1
    }

    /// Unregister a controller for a window.
    public func unregisterController(for windowId: UUID) {
        controllers.removeValue(forKey: windowId)
        controllerVersion += 1
    }

    // MARK: - Workspace Management

    /// Set the active workspace and load its windows.
    public func setActiveWorkspace(_ workspace: Workspace) {
        // Clear controllers from the previous workspace to prevent stale entries
        controllers.removeAll()
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

        refreshWindows()
        activeWindow = window
        return window
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

    /// Get windows in the same sync group as the given window.
    public func syncedWindows(for window: Window) -> [Window] {
        visibleWindows.filter { $0.syncGroup == window.syncGroup && $0.isSynchronized }
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
