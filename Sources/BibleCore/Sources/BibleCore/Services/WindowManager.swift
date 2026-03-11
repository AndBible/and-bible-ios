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

    /// Controller registry — maps window IDs to their BibleReaderController instances.
    /// Uses AnyObject to avoid circular dependency (BibleCore can't import BibleUI).
    /// BibleReaderView casts to BibleReaderController.
    public var controllers: [UUID: AnyObject] = [:]

    /// Incremented on every controller register/unregister to guarantee SwiftUI
    /// re-evaluates views that depend on the controller registry. Dictionary
    /// subscript mutations may not always trigger @Observable notifications.
    public private(set) var controllerVersion: Int = 0

    /// ID of the currently maximized window, if any.
    public var maximizedWindowId: UUID? {
        get { activeWorkspace?.maximizedWindowId }
        set { activeWorkspace?.maximizedWindowId = newValue }
    }

    // MARK: - Synchronized Scrolling

    /// Debounce work item for scroll sync (200ms matching Android WindowSync.kt:71).
    private var syncWorkItem: DispatchWorkItem?

    /// Callback to perform sync — set by the coordinator (BibleReaderView).
    /// Parameters: (sourceWindow, ordinal, key)
    public var onSyncVerseChanged: ((Window, Int, String) -> Void)?

    /// Creates a window manager for a workspace-backed window set.
    /// - Parameter workspaceStore: Store used to load, mutate, and persist workspace windows.
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

    /// Refresh the visible windows list from the active workspace.
    /// Respects maximized state and filters minimized windows.
    public func refreshWindows() {
        guard let workspace = activeWorkspace else {
            visibleWindows = []
            allWindows = []
            return
        }
        allWindows = workspaceStore.windows(workspaceId: workspace.id)

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

    /// Adds a new window to the active workspace, optionally copying state from an existing window.
    /// - Parameters:
    ///   - document: Explicit document/module to open. When `nil`, the source window's Bible document is reused.
    ///   - category: Category to use when no eligible source category is inherited.
    ///   - sourceWindow: Existing window whose sync state, layout weight, and reading position should be cloned.
    /// - Returns: The newly created window, or `nil` when no workspace is active.
    /// - Note: Non-Bible categories such as dictionary or EPUB are intentionally not inherited; new windows fall back to Bible/commentary semantics.
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
}
