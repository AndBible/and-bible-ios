// WorkspaceSelectorView.swift — Workspace selection and management

import SwiftUI
import SwiftData
import BibleCore

/**
 Lets the user switch workspaces and manage workspace lifecycle actions from one list.

 The view shows all persisted workspaces in display order, supports switching the active workspace,
 and exposes create, rename, clone, delete, and reorder actions.

 Data dependencies:
 - `windowManager` provides the active workspace and performs active-workspace switching
 - `modelContext` is used by `WorkspaceStore` for create/update/delete/reorder operations
 - `workspaces` is a live SwiftData query ordered by persisted workspace order

 Side effects:
 - selecting a row switches the active workspace and dismisses the sheet
 - alerts create, rename, or clone workspaces through `WorkspaceStore`
 - swipe deletion, context-menu deletion, and move actions mutate persisted workspace state
 */
public struct WorkspaceSelectorView: View {
    /// Shared window manager used to switch the active workspace.
    @Environment(WindowManager.self) private var windowManager

    /// SwiftData context used by `WorkspaceStore` mutations.
    @Environment(\.modelContext) private var modelContext

    /// Controls presentation of the create-workspace alert.
    @State private var showNewWorkspace = false

    /// Draft name for the create-workspace alert.
    @State private var newWorkspaceName = ""

    /// Controls presentation of the rename-workspace alert.
    @State private var showRenameWorkspace = false

    /// Draft name for the rename-workspace alert.
    @State private var renameWorkspaceName = ""

    /// Workspace currently targeted by the rename flow.
    @State private var workspaceToRename: Workspace?

    /// Controls presentation of the clone-workspace alert.
    @State private var showCloneWorkspace = false

    /// Draft name for the clone-workspace alert.
    @State private var cloneWorkspaceName = ""

    /// Workspace currently targeted by the clone flow.
    @State private var workspaceToClone: Workspace?

    /// Dismiss action for closing the selector screen.
    @Environment(\.dismiss) private var dismiss

    /// Persisted workspaces ordered by `orderNumber`.
    @Query(sort: \Workspace.orderNumber) private var workspaces: [Workspace]

    /**
     Creates the workspace selector screen.

     - Note: This initializer has no inputs and performs no side effects.
     */
    public init() {}

    /**
     Builds the workspace list, management alerts, and toolbar actions.
     */
    public var body: some View {
        List {
            if workspaces.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Text(String(localized: "workspace_no_workspaces"))
                            .foregroundStyle(.secondary)
                        Text(String(localized: "workspace_create_first"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                }
            } else {
                Section(String(localized: "workspaces")) {
                    ForEach(workspaces) { workspace in
                        workspaceSelectionButton(workspace)
                    }
                    .onDelete(perform: deleteWorkspaces)
                    .onMove(perform: moveWorkspaces)
                }
            }
        }
        .accessibilityIdentifier("workspaceSelectorScreen")
        .navigationTitle(String(localized: "workspaces"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "done")) { dismiss() }
                    .accessibilityIdentifier("workspaceSelectorDoneButton")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                EditButton()
                Button(String(localized: "add"), systemImage: "plus") {
                    showNewWorkspace = true
                }
                .accessibilityIdentifier("workspaceSelectorAddButton")
            }
        }
        .alert(String(localized: "workspace_new"), isPresented: $showNewWorkspace) {
            TextField(String(localized: "name"), text: $newWorkspaceName)
            Button(String(localized: "create")) {
                createWorkspace(named: newWorkspaceName)
                newWorkspaceName = ""
            }
            Button(String(localized: "cancel"), role: .cancel) { newWorkspaceName = "" }
        }
        .alert(String(localized: "rename"), isPresented: $showRenameWorkspace) {
            TextField(String(localized: "name"), text: $renameWorkspaceName)
            Button(String(localized: "save")) {
                guard let workspace = workspaceToRename else { return }
                renameWorkspace(workspace, to: renameWorkspaceName)
                workspaceToRename = nil
                renameWorkspaceName = ""
            }
            Button(String(localized: "cancel"), role: .cancel) {
                workspaceToRename = nil
                renameWorkspaceName = ""
            }
        }
        .alert(String(localized: "clone"), isPresented: $showCloneWorkspace) {
            TextField(String(localized: "name"), text: $cloneWorkspaceName)
            Button(String(localized: "create")) {
                guard let workspace = workspaceToClone else { return }
                cloneWorkspace(workspace, as: cloneWorkspaceName)
                workspaceToClone = nil
                cloneWorkspaceName = ""
            }
            Button(String(localized: "cancel"), role: .cancel) {
                workspaceToClone = nil
                cloneWorkspaceName = ""
            }
        }
    }

    /**
     Builds one workspace row with color indicator, summary text, and active-workspace marker.
     */
    private func workspaceRow(_ workspace: Workspace) -> some View {
        HStack {
            if let color = workspace.workspaceColor {
                Circle()
                    .fill(Color(argbInt: color))
                    .frame(width: 12, height: 12)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name.isEmpty ? String(localized: "untitled") : workspace.name)
                    .font(.body)
                if let contents = workspace.contentsText, !contents.isEmpty {
                    Text(contents)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let windowCount = workspace.windows?.count ?? 0
                    Text("\(windowCount) window\(windowCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if workspace.id == windowManager.activeWorkspace?.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
            }
        }
    }

    /**
     Builds the main workspace-selection button for one row.
     *
     * - Parameter workspace: Workspace represented by the selectable row body.
     * - Returns: A button that switches the active workspace and dismisses the selector.
     * - Side effects:
     *   - switches the active workspace through `WindowManager`
     *   - dismisses the selector sheet after the switch
     * - Failure modes: This helper cannot fail.
     */
    private func workspaceSelectionButton(_ workspace: Workspace) -> some View {
        Button {
            windowManager.setActiveWorkspace(workspace)
            dismiss()
        } label: {
            workspaceRow(workspace)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspaceSelectorRowButton")
        .accessibilityLabel(workspaceDisplayName(workspace))
        .accessibilityValue(
            workspace.id == windowManager.activeWorkspace?.id
                ? "activeWorkspace"
                : "inactiveWorkspace"
        )
        .contextMenu {
            Button(String(localized: "rename"), systemImage: "pencil") {
                prepareRename(for: workspace)
            }
            .accessibilityIdentifier("workspaceSelectorRenameAction")

            Button(String(localized: "clone"), systemImage: "doc.on.doc") {
                prepareClone(for: workspace)
            }
            .accessibilityIdentifier("workspaceSelectorCloneAction")

            Divider()

            Button(String(localized: "delete"), systemImage: "trash", role: .destructive) {
                deleteWorkspace(workspace)
            }
            .accessibilityIdentifier("workspaceSelectorDeleteAction")
            .disabled(workspace.id == windowManager.activeWorkspace?.id)
        }
    }

    /**
     Resolves the user-visible workspace name used by the row and UI tests.
     *
     * - Parameter workspace: Workspace whose display name should be derived.
     * - Returns: The persisted workspace name, or the localized untitled fallback when blank.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func workspaceDisplayName(_ workspace: Workspace) -> String {
        workspace.name.isEmpty ? String(localized: "untitled") : workspace.name
    }

    /**
     Prepares the rename alert for the selected workspace.
     *
     * - Parameter workspace: Workspace that should be renamed.
     * - Side effects:
     *   - in normal mode, stores the selected workspace in local alert state, pre-fills the
     *     rename field, and presents the rename alert
     *   - in XCUITest inline-action mode, renames the workspace immediately when a deterministic
     *     override name is configured
     * - Failure modes: This helper cannot fail.
     */
    private func prepareRename(for workspace: Workspace) {
        workspaceToRename = workspace
        renameWorkspaceName = workspace.name
        showRenameWorkspace = true
    }

    /**
     Prepares the clone alert for the selected workspace.
     *
     * - Parameter workspace: Workspace that should be deep-cloned.
     * - Side effects:
     *   - in normal mode, stores the selected workspace in local alert state, pre-fills the clone
     *     field, and presents the clone alert
     *   - in XCUITest inline-action mode, clones the workspace immediately when a deterministic
     *     override name is configured
     * - Failure modes: This helper cannot fail.
     */
    private func prepareClone(for workspace: Workspace) {
        workspaceToClone = workspace
        cloneWorkspaceName = String(format: String(localized: "copy_of %@"), workspace.name)
        showCloneWorkspace = true
    }

    /**
     Creates one workspace and applies the normal post-create selection behavior when appropriate.
     *
     * - Parameter name: User-visible name to assign to the new workspace.
     * - Side effects:
     *   - persists one new workspace through `WorkspaceStore`
     *   - in normal mode, switches the active workspace and dismisses the selector
     * - Failure modes:
     *   - returns without mutation when `name` is empty
     */
    private func createWorkspace(named name: String) {
        guard !name.isEmpty else { return }
        let store = WorkspaceStore(modelContext: modelContext)
        let workspace = store.createWorkspace(name: name)
        windowManager.setActiveWorkspace(workspace)
        dismiss()
    }

    /**
     Renames one workspace through `WorkspaceStore`.
     *
     * - Parameters:
     *   - workspace: Workspace to rename.
     *   - name: Replacement user-visible name.
     * - Side effects:
     *   - persists the renamed workspace through `WorkspaceStore`
     * - Failure modes:
     *   - returns without mutation when `name` is empty
     */
    private func renameWorkspace(_ workspace: Workspace, to name: String) {
        guard !name.isEmpty else { return }
        let store = WorkspaceStore(modelContext: modelContext)
        store.renameWorkspace(workspace, to: name)
    }

    /**
     Clones one workspace through `WorkspaceStore`.
     *
     * - Parameters:
     *   - workspace: Workspace to deep-clone.
     *   - name: User-visible name to assign to the cloned workspace.
     * - Side effects:
     *   - persists one deep-cloned workspace graph through `WorkspaceStore`
     * - Failure modes:
     *   - returns without mutation when `name` is empty
     */
    private func cloneWorkspace(_ workspace: Workspace, as name: String) {
        guard !name.isEmpty else { return }
        let store = WorkspaceStore(modelContext: modelContext)
        store.cloneWorkspace(workspace, newName: name)
    }

    /**
     Deletes a non-active workspace from the selector.
     *
     * - Parameter workspace: Workspace that should be removed.
     * - Side effects:
     *   - deletes the workspace through `WorkspaceStore` when it is not active
     * - Failure modes:
     *   - returns without mutation when the requested workspace is the active workspace
     */
    private func deleteWorkspace(_ workspace: Workspace) {
        guard workspace.id != windowManager.activeWorkspace?.id else { return }
        let store = WorkspaceStore(modelContext: modelContext)
        store.delete(workspace)
    }

    /**
     Deletes the selected workspaces, skipping the currently active workspace.
     */
    private func deleteWorkspaces(at offsets: IndexSet) {
        let store = WorkspaceStore(modelContext: modelContext)
        for index in offsets {
            let workspace = workspaces[index]
            if workspace.id == windowManager.activeWorkspace?.id {
                continue
            }
            store.delete(workspace)
        }
    }

    /**
     Persists a reordered workspace list after drag-and-drop movement.
     */
    private func moveWorkspaces(from source: IndexSet, to destination: Int) {
        var reordered = Array(workspaces)
        reordered.move(fromOffsets: source, toOffset: destination)
        let store = WorkspaceStore(modelContext: modelContext)
        store.reorderWorkspaces(reordered)
    }
}
