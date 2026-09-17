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
 * actions such as workspace cloning, reordering, and window creation. The explicitly named
 * `stageHistoryItem` is the sole staging API; reader navigation pairs it with its PageManager write
 * before one caller-owned journaled save.
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
     * - Parameters:
     *   - name: User-visible workspace name.
     *   - inheritingDefaultsFrom: Optional workspace whose workspace-scoped non-theme defaults
     *     and workspace accent color should seed the new workspace.
     * - Returns: The newly created workspace.
     * - Side Effects: Inserts a `Workspace`, a child `Window`, a matching `PageManager`, and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     * - Note: The initial `PageManager.id` is set to the new window ID so the one-to-one relationship stays aligned.
     *   When no source workspace supplies a color, the workspace uses Android's default `#ff444444`.
     */
    @discardableResult
    public func createWorkspace(name: String, inheritingDefaultsFrom source: Workspace? = nil) -> Workspace {
        let maxOrder = workspaces().map(\.orderNumber).max() ?? -1
        let workspace = Workspace(name: name, orderNumber: maxOrder + 1)
        workspace.textDisplaySettings = source?.textDisplaySettings?.clearingThemeColors()
        var workspaceSettings = source?.workspaceSettings ?? WorkspaceSettings()
        workspaceSettings.normalizeAutoAssignPrimaryLabel()
        workspace.workspaceSettings = workspaceSettings
        workspace.workspaceColor = source?.workspaceColor ?? Workspace.defaultWorkspaceColor
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
     Clones a workspace together with its window graph and current page state.

     Android copies each `Window` and `PageManager` into the new workspace but does not copy the
     source windows' History rows. Each cloned window therefore starts with an empty navigation
     history while retaining the source pane's current document and position.

     - Parameters:
       - source: Workspace to clone.
       - newName: User-visible name for the cloned workspace.
     - Returns: The cloned workspace.
     - Side Effects: Inserts a new workspace graph, shifts later workspace order numbers, deep-copies
       windows, page managers, and Android-only page fidelity, remaps links-window references,
       assigns Android's default workspace color when the source has no stored color, and saves
       `modelContext`.
     - Failure Modes: Save errors are swallowed under the store's existing eager-save contract.
     - Note: Window IDs are remapped so links-window references, maximized-window references, and
       page-manager ownership remain internally consistent. History remains owned by the source
       window identities.
     - Complexity: Roughly linear in the number of windows and page-manager fidelity rows attached
       to the source workspace.
     */
    @discardableResult
    public func cloneWorkspace(_ source: Workspace, newName: String) -> Workspace {
        let cloned = Workspace(name: newName, orderNumber: source.orderNumber + 1)
        cloned.contentsText = source.contentsText
        cloned.textDisplaySettings = source.textDisplaySettings
        if var workspaceSettings = source.workspaceSettings {
            workspaceSettings.normalizeAutoAssignPrimaryLabel()
            cloned.workspaceSettings = workspaceSettings
        }
        cloned.workspaceColor = source.workspaceColor ?? Workspace.defaultWorkspaceColor
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
        var clonedPageManagerWindowIDs: [(source: UUID, clone: UUID)] = []

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
                newPM.copyPersistedReaderState(from: srcPM)
                modelContext.insert(newPM)
                clonedPageManagerWindowIDs.append((source: srcWindow.id, clone: newWindow.id))
            }

            // Android workspace clones start each new window with an empty history stack.
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
        for windowIDs in clonedPageManagerWindowIDs {
            copyPageManagerFidelity(from: windowIDs.source, to: windowIDs.clone)
        }
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
     * Deletes multiple workspaces and saves once after all rows are marked for deletion.
     * - Parameter workspaces: Workspaces to delete.
     * - Side Effects: Deletes each workspace graph and saves `modelContext` once.
     * - Failure: Save errors are swallowed.
     */
    public func deleteWorkspaces(_ workspaces: [Workspace]) {
        for workspace in workspaces {
            modelContext.delete(workspace)
        }
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
     Adds an independently persisted pane by cloning an existing window and its complete reader state.

     Android's `WindowRepository.createNewWindow` copies the source window entity, clears its links
     target, restores the complete `CurrentPageManager.entity`, and gives the clone fresh identities.
     The clone intentionally starts visible and has no navigation history, matching that behavior.

     - Parameters:
       - workspace: Parent workspace that will own the cloned window.
       - source: Window whose pane and page-manager state should be copied.
       - asLinksWindow: Final links-window role for the clone. This is explicit because Android's
         change-to-normal action clones a links pane and then clears that role.
     - Returns: A separately owned window and page manager, or `nil` when the source has no page
       manager to clone.
     - Side Effects: Inserts and saves a new window/page-manager graph, then copies any preserved
       Android-only page-manager fidelity under the new window identifier.
     - Failure Modes: A missing source page manager returns `nil` without inserting a fallback Bible
       pane. Persistence failures retain the store's existing best-effort save behavior.
     - Important: The source's `targetLinksWindowId` and history are deliberately not copied.
     */
    @discardableResult
    func addWindow(
        to workspace: Workspace,
        cloning source: Window,
        asLinksWindow: Bool
    ) -> Window? {
        guard let sourcePageManager = source.pageManager else { return nil }

        let maxOrder = (workspace.windows ?? []).map(\.orderNumber).max() ?? -1
        let window = Window(
            isSynchronized: source.isSynchronized,
            isPinMode: source.isPinMode,
            isLinksWindow: asLinksWindow,
            orderNumber: maxOrder + 1,
            syncGroup: source.syncGroup,
            layoutWeight: source.layoutWeight,
            layoutState: "split"
        )
        window.workspace = workspace

        let pageManager = PageManager(
            id: window.id,
            currentCategoryName: sourcePageManager.currentCategoryName
        )
        pageManager.window = window
        pageManager.copyPersistedReaderState(from: sourcePageManager)

        modelContext.insert(window)
        modelContext.insert(pageManager)
        save()
        copyPageManagerFidelity(from: source.id, to: window.id)

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
     * Rewrites window `orderNumber` fields to match the supplied ordering.
     * - Parameter windows: Windows in their new desired persisted order.
     * - Side Effects: Mutates each window's `orderNumber` and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     * - Precondition: The array must already represent the complete ordering for the affected
     *   workspace.
     */
    public func reorderWindows(_ windows: [Window]) {
        for (index, window) in windows.enumerated() {
            window.orderNumber = index
        }
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
     Stages one reader history checkpoint in this store's model context.

     The exact `Window` must belong to this store's context and still resolve as its current row;
     foreign, deleted, and same-ID replacement objects are rejected before graph mutation.

     - Parameters:
       - window: Current store-owned window whose location is being left.
       - document: Document initials at that location.
       - key: Durable document key at that location.
       - anchorOrdinal: Optional scroll anchor for restoring the location.
     - Returns: `true` when a new row was staged, or `false` when the owner is invalid.
     - Side Effects: Inserts one new `HistoryItem` row; does not save.
     - Failure Modes: Owner validation failure leaves the graph unchanged and returns `false`.
     */
    @discardableResult
    public func stageHistoryItem(
        to window: Window,
        document: String,
        key: String,
        anchorOrdinal: Int? = nil
    ) -> Bool {
        guard ownsHistoryWindow(window) else { return false }
        let item = HistoryItem(document: document, key: key)
        item.anchorOrdinal = anchorOrdinal
        modelContext.insert(item)
        item.window = window
        return true
    }

    /**
     Appends and eagerly persists one reader history checkpoint.

     - Parameters:
       - window: Current store-owned window whose location is being left.
       - document: Document initials at that location.
       - key: Durable document key at that location.
       - anchorOrdinal: Optional scroll anchor for restoring the location.
     - Side Effects: For a valid owner, stages a history row and saves pending workspace changes.
     - Failure Modes: Foreign, deleted, or replaced owners are ignored. Journal and save failures
       are swallowed under the store's existing eager-save contract.
     */
    public func addHistoryItem(
        to window: Window,
        document: String,
        key: String,
        anchorOrdinal: Int? = nil
    ) {
        guard stageHistoryItem(
            to: window,
            document: document,
            key: key,
            anchorOrdinal: anchorOrdinal
        ) else { return }
        save()
    }

    /**
     Determines whether a window can own a history row in this store.

     - Parameter window: Exact window object proposed as the history owner.
     - Returns: `true` only when the object is live, belongs to this store's model context, and is
       the current registered model instance for its durable identifier.
     - Side Effects: Performs a bounded identity fetch; does not mutate or save the model graph.
     - Failure Modes: Deleted, foreign-context, detached, and same-ID replacement objects return
       `false`; fetch errors also fail closed.
     - Concurrency: Inherits the confinement of this store's `ModelContext`.
     */
    public func ownsHistoryWindow(_ window: Window) -> Bool {
        guard !window.isDeleted, window.modelContext === modelContext else { return false }
        let windowID = window.id
        var descriptor = FetchDescriptor<Window>(predicate: #Predicate { $0.id == windowID })
        descriptor.fetchLimit = 1
        guard let current = try? modelContext.fetch(descriptor).first else { return false }
        return current === window
    }

    /**
     * Fetches history for a window ordered by most recent first.
     * - Parameter windowId: Window UUID.
     * - Returns: History items belonging to the window.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     * - Note: Window membership and newest-first ordering are both applied by SwiftData.
     */
    public func history(windowId: UUID) -> [HistoryItem] {
        let descriptor = FetchDescriptor<HistoryItem>(
            predicate: #Predicate { $0.window?.id == windowId },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // MARK: - Persistence

    /**
     Copies Android-only page-manager fields stored outside the SwiftData window graph.

     - Parameters:
       - sourceWindowID: Existing window whose raw category, commentary source, and generic-page
         anchors should be read.
       - clonedWindowID: Fresh window identifier that should own an independent fidelity row.
     - Side Effects: Reads and, when source fidelity exists, writes one local `Setting` row after
       the cloned graph has already been persisted.
     - Failure Modes: Missing or malformed source fidelity produces no target row. Encoding and
       settings persistence failures follow `RemoteSyncWorkspaceFidelityStore`'s best-effort
       contract.
     */
    private func copyPageManagerFidelity(from sourceWindowID: UUID, to clonedWindowID: UUID) {
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(
            settingsStore: SettingsStore(modelContext: modelContext)
        )
        guard let source = fidelityStore.pageManagerEntry(for: sourceWindowID) else { return }

        fidelityStore.setPageManagerEntry(.init(
            windowID: clonedWindowID,
            rawCurrentCategoryName: source.rawCurrentCategoryName,
            commentarySourceBookAndKey: source.commentarySourceBookAndKey,
            dictionaryAnchorOrdinal: source.dictionaryAnchorOrdinal,
            generalBookAnchorOrdinal: source.generalBookAnchorOrdinal,
            mapAnchorOrdinal: source.mapAnchorOrdinal
        ))
    }

    /**
     * Saves window or workspace mutations performed by a coordinating service.
     * - Returns: `true` when the journaled save completed, otherwise `false`.
     * - Side Effects: Attempts to flush pending `modelContext` changes and the workspace journal.
     * - Failure: Journal and save errors are reported as `false` without escaping.
     * - Note: Entity creation, deletion, and ordering methods already save internally; this method
     *   covers grouped property mutations that must be committed as one manager-routed action.
     */
    @discardableResult
    public func persistChanges() -> Bool {
        save()
    }

    /**
     Saves pending workspace-related mutations.

     - Returns: `true` when the journaled save completed, otherwise `false`.
     - Side Effects: Attempts one isolated workspace graph and remote-sync journal save.
     - Failure Modes: Journal or SwiftData errors are converted to `false`; pending caller state is
       left in the context under the journal service's existing failure contract.
     */
    @discardableResult
    private func save() -> Bool {
        do {
            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .workspaces,
                modelContext: modelContext
            )
            return true
        } catch {
            return false
        }
    }
}
