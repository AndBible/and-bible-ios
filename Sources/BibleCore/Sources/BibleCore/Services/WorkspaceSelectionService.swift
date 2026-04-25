// WorkspaceSelectionService.swift -- active workspace selection and deletion repair

import Foundation

/**
 Coordinates active workspace selection between the visible window manager and persisted settings.

 Android keeps the current workspace change explicit in the activity layer: selecting a workspace
 loads the workspace and writes the current workspace preference, and deleting the current workspace
 repairs selection to a surviving workspace. This service provides the same contract for iOS so
 workspace UI callers do not have to remember separate in-memory and persisted updates.
 */
public final class WorkspaceSelectionService {
    private let workspaceStore: WorkspaceStore
    private let settingsStore: SettingsStore
    private let windowManager: WindowManager

    /**
     Creates an active-workspace selection coordinator.

     - Parameters:
       - workspaceStore: Store used to fetch, delete, and repair workspace rows.
       - settingsStore: Store used to persist the active workspace identifier.
       - windowManager: Live manager whose visible workspace should follow persisted selection.
     */
    public init(
        workspaceStore: WorkspaceStore,
        settingsStore: SettingsStore,
        windowManager: WindowManager
    ) {
        self.workspaceStore = workspaceStore
        self.settingsStore = settingsStore
        self.windowManager = windowManager
    }

    /**
     Activates one workspace and persists that selection for launch restore.

     - Parameter workspace: Workspace to show immediately and restore on next launch.
     - Side effects:
       - updates `WindowManager.activeWorkspace`
       - writes `SettingsStore.activeWorkspaceId`
     */
    public func activate(_ workspace: Workspace) {
        windowManager.setActiveWorkspace(workspace)
        settingsStore.activeWorkspaceId = workspace.id
    }

    /**
     Deletes one workspace, repairing active selection first when needed.

     - Parameter workspace: Workspace requested for deletion.
     - Returns: `true` when a workspace was deleted, otherwise `false`.
     - Side effects:
       - refuses to delete the final workspace
       - switches to a surviving workspace before deleting the active one
       - repairs persisted active selection after deletion
     */
    @discardableResult
    public func deleteWorkspace(_ workspace: Workspace) -> Bool {
        deleteWorkspaces([workspace])
    }

    /**
     Deletes a batch of workspaces, preserving at least one valid active workspace.

     - Parameter workspaces: Workspaces requested for deletion.
     - Returns: `true` when at least one workspace was deleted, otherwise `false`.
     - Side effects:
       - refuses to delete all persisted workspaces
       - switches active selection to the first surviving workspace before deleting the active one
       - updates `SettingsStore.activeWorkspaceId` to match the live active workspace
     */
    @discardableResult
    public func deleteWorkspaces(_ workspaces: [Workspace]) -> Bool {
        let requestedIDs = Set(workspaces.map(\.id))
        guard !requestedIDs.isEmpty else {
            return false
        }

        let persistedWorkspaces = workspaceStore.workspaces()
        let persistedIDs = Set(persistedWorkspaces.map(\.id))
        let deletableIDs = requestedIDs.intersection(persistedIDs)
        guard !deletableIDs.isEmpty else {
            return false
        }

        let survivingWorkspaces = persistedWorkspaces.filter { !deletableIDs.contains($0.id) }
        guard !survivingWorkspaces.isEmpty else {
            _ = repairActiveWorkspace()
            return false
        }

        let activeWorkspaceID = windowManager.activeWorkspace?.id ?? settingsStore.activeWorkspaceId
        if let activeWorkspaceID, deletableIDs.contains(activeWorkspaceID) {
            activate(survivingWorkspaces[0])
        }

        workspaceStore.deleteWorkspaces(persistedWorkspaces.filter { deletableIDs.contains($0.id) })

        _ = repairActiveWorkspace(preferredFallback: survivingWorkspaces[0])
        return true
    }

    /**
     Repairs live and persisted active selection after workspace graph changes.

     - Parameter preferredFallback: Preferred surviving workspace when the current active selection
       is missing.
     - Returns: The valid active workspace after repair, or `nil` when no workspace exists.
     */
    @discardableResult
    public func repairActiveWorkspace(preferredFallback: Workspace? = nil) -> Workspace? {
        if let activeWorkspace = windowManager.activeWorkspace,
           workspaceStore.workspace(id: activeWorkspace.id) != nil {
            settingsStore.activeWorkspaceId = activeWorkspace.id
            return activeWorkspace
        }

        if let persistedID = settingsStore.activeWorkspaceId,
           let persistedWorkspace = workspaceStore.workspace(id: persistedID) {
            activate(persistedWorkspace)
            return persistedWorkspace
        }

        if let preferredFallback,
           workspaceStore.workspace(id: preferredFallback.id) != nil {
            activate(preferredFallback)
            return preferredFallback
        }

        if let firstWorkspace = workspaceStore.workspaces().first {
            activate(firstWorkspace)
            return firstWorkspace
        }

        settingsStore.activeWorkspaceId = nil
        return nil
    }
}
