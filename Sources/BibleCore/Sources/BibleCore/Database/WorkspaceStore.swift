// WorkspaceStore.swift — Workspace persistence operations

import Foundation
import SwiftData

/**
 * Manages workspace, window, page-manager, and history persistence.
 *
 * This store owns the durable graph behind the reader layout:
 * - workspaces and their ordering
 * - child windows and matching `PageManager` rows
 * - per-window navigation history
 *
 * Mutations save eagerly so the visible window model and persisted state remain aligned after UI
 * actions such as workspace cloning, reordering, and window creation.
 *
 * - Important: This store inherits the thread/actor confinement of the supplied `ModelContext`.
 */
@Observable
public final class WorkspaceStore {
    /// SwiftData context used for all workspace, window, and history reads and writes.
    private let modelContext: ModelContext

    /**
     * Creates a workspace store bound to the caller's SwiftData context.
     * - Parameter modelContext: Context used for workspace, window, page-manager, and history persistence.
     * - Important: The caller owns context lifecycle and confinement.
     */
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Workspaces

    /**
     * Fetches all workspaces ordered by `orderNumber`.
     * - Returns: Persisted workspaces in display order.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     */
    public func workspaces() -> [Workspace] {
        let descriptor = FetchDescriptor<Workspace>(
            sortBy: [SortDescriptor(\.orderNumber)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /**
     * Fetches a workspace by primary key.
     * - Parameter id: Workspace UUID.
     * - Returns: The workspace when found, otherwise `nil`.
     * - Failure: Fetch errors are swallowed and reported as `nil`.
     */
    public func workspace(id: UUID) -> Workspace? {
        var descriptor = FetchDescriptor<Workspace>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /**
     * Creates a new workspace with the default single-Bible-window graph.
     * - Parameter name: User-visible workspace name.
     * - Returns: The newly created workspace.
     * - Side Effects: Inserts a `Workspace`, a child `Window`, a matching `PageManager`, and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     * - Note: The initial `PageManager.id` is set to the new window ID so the one-to-one relationship stays aligned.
     */
    @discardableResult
    public func createWorkspace(name: String) -> Workspace {
        let maxOrder = workspaces().map(\.orderNumber).max() ?? -1
        let workspace = Workspace(name: name, orderNumber: maxOrder + 1)
        modelContext.insert(workspace)

        // Create a default window with Bible page
        let window = Window(orderNumber: 0)
        window.workspace = workspace

        let pageManager = PageManager(id: window.id, currentCategoryName: "bible")
        pageManager.window = window

        modelContext.insert(window)
        modelContext.insert(pageManager)
        save()

        return workspace
    }

    /**
     * Renames an existing workspace and saves the change immediately.
     * - Parameters:
     *   - workspace: Workspace to rename.
     *   - newName: New user-visible name.
     * - Side Effects: Mutates the workspace row and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func renameWorkspace(_ workspace: Workspace, to newName: String) {
        workspace.name = newName
        save()
    }

    /**
     * Clones a workspace together with its window graph and navigation history.
     * - Parameters:
     *   - source: Workspace to clone.
     *   - newName: User-visible name for the cloned workspace.
     * - Returns: The cloned workspace.
     * - Side Effects: Inserts a new workspace graph, shifts later workspace order numbers, deep-copies windows,
     *   page managers, and history items, remaps links-window references, and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     * - Note: Window IDs are remapped so links-window references, maximized-window references, and page-manager
     *   ownership remain internally consistent.
     * - Complexity: Roughly linear in the number of windows plus history items attached to the source workspace.
     */
    @discardableResult
    public func cloneWorkspace(_ source: Workspace, newName: String) -> Workspace {
        let cloned = Workspace(name: newName, orderNumber: source.orderNumber + 1)
        cloned.contentsText = source.contentsText
        cloned.textDisplaySettings = source.textDisplaySettings
        cloned.workspaceSettings = source.workspaceSettings
        cloned.workspaceColor = source.workspaceColor
        cloned.unPinnedWeight = source.unPinnedWeight
        modelContext.insert(cloned)

        // Shift order of workspaces after the source
        let allWorkspaces = workspaces()
        for ws in allWorkspaces where ws.id != cloned.id && ws.orderNumber > source.orderNumber {
            ws.orderNumber += 1
        }

        // Deep-copy windows
        let sourceWindows = (source.windows ?? []).sorted { $0.orderNumber < $1.orderNumber }
        var windowIdMap: [UUID: UUID] = [:]  // old -> new, for links references

        for srcWindow in sourceWindows {
            let newWindow = Window(
                isSynchronized: srcWindow.isSynchronized,
                isPinMode: srcWindow.isPinMode,
                isLinksWindow: srcWindow.isLinksWindow,
                orderNumber: srcWindow.orderNumber,
                syncGroup: srcWindow.syncGroup,
                layoutWeight: srcWindow.layoutWeight,
                layoutState: srcWindow.layoutState
            )
            newWindow.workspace = cloned
            newWindow.targetLinksWindowId = srcWindow.targetLinksWindowId
            windowIdMap[srcWindow.id] = newWindow.id
            modelContext.insert(newWindow)

            // Deep-copy PageManager
            if let srcPM = srcWindow.pageManager {
                let newPM = PageManager(id: newWindow.id, currentCategoryName: srcPM.currentCategoryName)
                newPM.window = newWindow
                newPM.bibleDocument = srcPM.bibleDocument
                newPM.bibleVersification = srcPM.bibleVersification
                newPM.bibleBibleBook = srcPM.bibleBibleBook
                newPM.bibleChapterNo = srcPM.bibleChapterNo
                newPM.bibleVerseNo = srcPM.bibleVerseNo
                newPM.commentaryDocument = srcPM.commentaryDocument
                newPM.commentaryAnchorOrdinal = srcPM.commentaryAnchorOrdinal
                newPM.dictionaryDocument = srcPM.dictionaryDocument
                newPM.dictionaryKey = srcPM.dictionaryKey
                newPM.generalBookDocument = srcPM.generalBookDocument
                newPM.generalBookKey = srcPM.generalBookKey
                newPM.mapDocument = srcPM.mapDocument
                newPM.mapKey = srcPM.mapKey
                newPM.epubIdentifier = srcPM.epubIdentifier
                newPM.epubHref = srcPM.epubHref
                newPM.textDisplaySettings = srcPM.textDisplaySettings
                newPM.jsState = srcPM.jsState
                modelContext.insert(newPM)
            }

            // Deep-copy HistoryItems
            for item in srcWindow.historyItems ?? [] {
                let newItem = HistoryItem(document: item.document, key: item.key)
                newItem.anchorOrdinal = item.anchorOrdinal
                newItem.createdAt = item.createdAt
                newItem.window = newWindow
                modelContext.insert(newItem)
            }
        }

        // Remap links window references
        if let srcMaxId = source.maximizedWindowId, let newId = windowIdMap[srcMaxId] {
            cloned.maximizedWindowId = newId
        }
        if let srcLinksId = source.primaryTargetLinksWindowId, let newId = windowIdMap[srcLinksId] {
            cloned.primaryTargetLinksWindowId = newId
        }
        for window in cloned.windows ?? [] {
            if let targetId = window.targetLinksWindowId, let newId = windowIdMap[targetId] {
                window.targetLinksWindowId = newId
            }
        }

        save()
        return cloned
    }

    /**
     * Deletes a workspace and relies on cascade rules for its windows, page managers, and history.
     * - Parameter workspace: Workspace to delete.
     * - Side Effects: Deletes the workspace graph and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func delete(_ workspace: Workspace) {
        modelContext.delete(workspace)
        save()
    }

    /**
     * Rewrites workspace `orderNumber` fields to match the supplied ordering.
     * - Parameter workspaces: Workspaces in their new desired order.
     * - Side Effects: Mutates each workspace's `orderNumber` and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     * - Precondition: The array must already represent the desired display order.
     */
    public func reorderWorkspaces(_ workspaces: [Workspace]) {
        for (index, workspace) in workspaces.enumerated() {
            workspace.orderNumber = index
        }
        save()
    }

    // MARK: - Windows

    /**
     * Fetches windows for a workspace ordered by `orderNumber`.
     * - Parameter workspaceId: Workspace UUID.
     * - Returns: Windows in display order.
     * - Failure: Missing workspaces and fetch errors are reported as an empty array.
     * - Note: This method reads the workspace first and then sorts the loaded relationship in memory.
     */
    public func windows(workspaceId: UUID) -> [Window] {
        guard let workspace = workspace(id: workspaceId) else { return [] }
        return (workspace.windows ?? []).sorted { $0.orderNumber < $1.orderNumber }
    }

    /**
     * Adds a window to a workspace and creates a matching `PageManager`.
     * - Parameters:
     *   - workspace: Parent workspace.
     *   - document: Optional initial Bible document.
     *   - category: Initial document category.
     * - Returns: The newly created window.
     * - Side Effects: Inserts a window and one-to-one page-manager row, then saves `modelContext`.
     * - Failure: Save errors are swallowed.
     * - Note: New windows are appended after the current highest `orderNumber` in the workspace.
     */
    @discardableResult
    public func addWindow(to workspace: Workspace, document: String? = nil, category: String = "bible") -> Window {
        let maxOrder = (workspace.windows ?? []).map(\.orderNumber).max() ?? -1
        let window = Window(orderNumber: maxOrder + 1)
        window.workspace = workspace

        let pageManager = PageManager(id: window.id, currentCategoryName: category)
        pageManager.bibleDocument = document
        pageManager.window = window

        modelContext.insert(window)
        modelContext.insert(pageManager)
        save()

        return window
    }

    /**
     * Swaps the `orderNumber` values of two windows.
     * - Parameters:
     *   - window1: First window.
     *   - window2: Second window.
     * - Side Effects: Mutates both windows and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func swapWindowOrder(_ window1: Window, _ window2: Window) {
        let temp = window1.orderNumber
        window1.orderNumber = window2.orderNumber
        window2.orderNumber = temp
        save()
    }

    /**
     * Deletes a window and relies on cascade rules for its page manager and history.
     * - Parameter window: Window to delete.
     * - Side Effects: Deletes the window graph and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func delete(_ window: Window) {
        modelContext.delete(window)
        save()
    }

    // MARK: - History

    /**
     * Appends a history item to a window.
     * - Parameters:
     *   - window: Owning window.
     *   - document: Document initials at the time of navigation.
     *   - key: Durable document key for the history location.
     *   - anchorOrdinal: Optional scroll anchor for restoring position.
     * - Side Effects: Inserts a `HistoryItem` row linked to the window and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func addHistoryItem(to window: Window, document: String, key: String, anchorOrdinal: Int? = nil) {
        let item = HistoryItem(document: document, key: key)
        item.anchorOrdinal = anchorOrdinal
        item.window = window
        modelContext.insert(item)
        save()
    }

    /**
     * Fetches history for a window ordered by most recent first.
     * - Parameter windowId: Window UUID.
     * - Returns: History items belonging to the window.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     * - Complexity: `O(n)` over all history items because window filtering happens after fetch.
     */
    public func history(windowId: UUID) -> [HistoryItem] {
        let descriptor = FetchDescriptor<HistoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.window?.id == windowId }
    }

    // MARK: - Persistence

    /**
     * Saves pending workspace-related mutations.
     * - Side Effects: Flushes `modelContext` to disk.
     * - Failure: Save errors are swallowed.
     */
    private func save() {
        try? modelContext.save()
    }
}
