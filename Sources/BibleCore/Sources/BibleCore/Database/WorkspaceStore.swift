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
