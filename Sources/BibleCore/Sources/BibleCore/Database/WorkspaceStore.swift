// WorkspaceStore.swift — Workspace persistence operations

import Foundation
import SwiftData

/// Manages workspace, window, and page manager persistence.
@Observable
public final class WorkspaceStore {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Workspaces

    /// Fetch all workspaces ordered by orderNumber.
    public func workspaces() -> [Workspace] {
        let descriptor = FetchDescriptor<Workspace>(
            sortBy: [SortDescriptor(\.orderNumber)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Fetch a workspace by ID.
    public func workspace(id: UUID) -> Workspace? {
        var descriptor = FetchDescriptor<Workspace>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Create a new workspace with default settings.
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

    /// Rename a workspace.
    public func renameWorkspace(_ workspace: Workspace, to newName: String) {
        workspace.name = newName
        save()
    }

    /// Clone a workspace with all its windows, page managers, and history.
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

    /// Delete a workspace and all its windows.
    public func delete(_ workspace: Workspace) {
        modelContext.delete(workspace)
        save()
    }

    /// Update workspace order numbers after reordering.
    public func reorderWorkspaces(_ workspaces: [Workspace]) {
        for (index, workspace) in workspaces.enumerated() {
            workspace.orderNumber = index
        }
        save()
    }

    // MARK: - Windows

    /// Fetch windows for a workspace, ordered by orderNumber.
    public func windows(workspaceId: UUID) -> [Window] {
        guard let workspace = workspace(id: workspaceId) else { return [] }
        return (workspace.windows ?? []).sorted { $0.orderNumber < $1.orderNumber }
    }

    /// Add a window to a workspace.
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

    /// Swap the order of two windows.
    public func swapWindowOrder(_ window1: Window, _ window2: Window) {
        let temp = window1.orderNumber
        window1.orderNumber = window2.orderNumber
        window2.orderNumber = temp
        save()
    }

    /// Delete a window.
    public func delete(_ window: Window) {
        modelContext.delete(window)
        save()
    }

    // MARK: - History

    /// Add a history item to a window.
    public func addHistoryItem(to window: Window, document: String, key: String, anchorOrdinal: Int? = nil) {
        let item = HistoryItem(document: document, key: key)
        item.anchorOrdinal = anchorOrdinal
        item.window = window
        modelContext.insert(item)
        save()
    }

    /// Get history for a window, most recent first.
    public func history(windowId: UUID) -> [HistoryItem] {
        let descriptor = FetchDescriptor<HistoryItem>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.window?.id == windowId }
    }

    // MARK: - Persistence

    private func save() {
        try? modelContext.save()
    }
}
