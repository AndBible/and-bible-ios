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
 - sheet-backed prompts create, rename, or clone workspaces through `WorkspaceStore`
 - swipe deletion, context-menu deletion, and move actions mutate persisted workspace state
 */
public struct WorkspaceSelectorView: View {
    /// Shared window manager used to switch the active workspace.
    @Environment(WindowManager.self) private var windowManager

    /// SwiftData context used by `WorkspaceStore` mutations.
    @Environment(\.modelContext) private var modelContext

    /// Current system color scheme used to resolve Android-parity surface colors.
    @Environment(\.colorScheme) private var colorScheme

    /// Currently presented workspace-name prompt, if any.
    @State private var workspacePrompt: WorkspaceNamePrompt?

    /// Draft name used by the active workspace prompt.
    @State private var workspacePromptName = ""

    /// Dismiss action for closing the selector screen.
    @Environment(\.dismiss) private var dismiss

    /// Persisted workspaces ordered by `orderNumber`.
    @Query(sort: \Workspace.orderNumber) private var workspaces: [Workspace]

    /**
     Creates the workspace selector screen.

     - Note: This initializer has no inputs and performs no side effects.
     */
    public init() {}

    private var dialogBackground: Color {
        AndroidDialogSurfacePalette.background(for: colorScheme)
    }

    private var dialogPrimaryText: Color {
        AndroidDialogSurfacePalette.primaryText(for: colorScheme)
    }

    private var dialogSecondaryText: Color {
        AndroidDialogSurfacePalette.secondaryText(for: colorScheme)
    }

    private var dialogAccent: Color {
        AndroidDialogSurfacePalette.accent(for: colorScheme)
    }

    /**
     Builds the workspace list, management alerts, and toolbar actions.
     */
    public var body: some View {
        List {
            if workspaces.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Text(String(localized: "workspace_no_workspaces"))
                            .foregroundStyle(dialogSecondaryText)
                        Text(String(localized: "workspace_create_first"))
                            .font(.caption)
                            .foregroundStyle(dialogSecondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                }
                .listRowBackground(dialogBackground)
            } else {
                Section {
                    ForEach(workspaces) { workspace in
                        workspaceSelectionButton(workspace)
                    }
                    .onDelete(perform: deleteWorkspaces)
                    .onMove(perform: moveWorkspaces)
                } header: {
                    Text(String(localized: "workspaces"))
                        .foregroundStyle(dialogSecondaryText)
                }
            }
        }
        .accessibilityIdentifier("workspaceSelectorScreen")
        .navigationTitle(String(localized: "workspaces"))
        .scrollContentBackground(.hidden)
        .background(dialogBackground.ignoresSafeArea())
        .tint(dialogAccent)
        #if os(iOS)
        .toolbarBackground(dialogBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "done")) { dismiss() }
                    .accessibilityIdentifier("workspaceSelectorDoneButton")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                EditButton()
                Button(String(localized: "add"), systemImage: "plus") {
                    prepareCreate()
                }
                .accessibilityIdentifier("workspaceSelectorAddButton")
            }
        }
        .sheet(item: $workspacePrompt, onDismiss: resetWorkspacePrompt) { prompt in
            NavigationStack {
                WorkspaceNamePromptView(
                    prompt: prompt,
                    name: $workspacePromptName,
                    onCancel: dismissWorkspacePrompt,
                    onConfirm: { submitWorkspacePrompt(prompt) }
                )
            }
            .tint(dialogAccent)
            #if os(iOS)
            .presentationDetents([.medium])
            #endif
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
                    .foregroundStyle(dialogPrimaryText)
                if let contents = workspace.contentsText, !contents.isEmpty {
                    Text(contents)
                        .font(.caption)
                        .foregroundStyle(dialogSecondaryText)
                } else {
                    let windowCount = workspace.windows?.count ?? 0
                    Text("\(windowCount) window\(windowCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(dialogSecondaryText)
                }
            }
            Spacer()
            if workspace.id == windowManager.activeWorkspace?.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(dialogAccent)
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
        .listRowBackground(dialogBackground)
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
     Prepares the create prompt with an empty workspace name draft.
     *
     * - Side effects:
     *   - resets the shared prompt draft
     *   - presents the create-workspace prompt sheet
     * - Failure modes: This helper cannot fail.
     */
    private func prepareCreate() {
        workspacePromptName = ""
        workspacePrompt = .create
    }

    /**
     Prepares the rename prompt for the selected workspace.
     *
     * - Parameter workspace: Workspace that should be renamed.
     * - Side effects:
     *   - stores the selected workspace in local prompt state
     *   - pre-fills the rename field and presents the rename prompt sheet
     * - Failure modes: This helper cannot fail.
     */
    private func prepareRename(for workspace: Workspace) {
        workspacePromptName = workspace.name
        workspacePrompt = .rename(workspace)
    }

    /**
     Prepares the clone prompt for the selected workspace.
     *
     * - Parameter workspace: Workspace that should be deep-cloned.
     * - Side effects:
     *   - stores the selected workspace in local prompt state
     *   - pre-fills the clone field and presents the clone prompt sheet
     * - Failure modes: This helper cannot fail.
     */
    private func prepareClone(for workspace: Workspace) {
        workspacePromptName = String(format: String(localized: "copy_of %@"), workspace.name)
        workspacePrompt = .clone(workspace)
    }

    /**
     Dismisses the active workspace prompt and clears its draft state.
     *
     * - Side effects:
     *   - closes the presented prompt sheet
     *   - resets the shared draft name
     * - Failure modes: This helper cannot fail.
     */
    private func dismissWorkspacePrompt() {
        workspacePrompt = nil
        workspacePromptName = ""
    }

    /**
     Clears the shared prompt draft after sheet dismissal.
     *
     * - Side effects:
     *   - resets the prompt draft text after interactive or programmatic dismissal
     * - Failure modes: This helper cannot fail.
     */
    private func resetWorkspacePrompt() {
        workspacePromptName = ""
    }

    /**
     Commits the active workspace prompt action using the current shared draft name.
     *
     * - Parameter prompt: Prompt action being confirmed.
     * - Side effects:
     *   - dismisses the prompt sheet before mutating workspace state
     *   - routes the current draft name into create, rename, or clone flows
     * - Failure modes:
     *   - returns without mutation when the current draft name is empty
     */
    private func submitWorkspacePrompt(_ prompt: WorkspaceNamePrompt) {
        let name = workspacePromptName
        guard !name.isEmpty else { return }

        workspacePrompt = nil

        switch prompt {
        case .create:
            createWorkspace(named: name)
        case .rename(let workspace):
            renameWorkspace(workspace, to: name)
        case .clone(let workspace):
            cloneWorkspace(workspace, as: name)
        }
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
        let workspace = store.createWorkspace(
            name: name,
            inheritingDefaultsFrom: windowManager.activeWorkspace
        )
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

/// Supported workspace-name prompt actions shown from the selector sheet.
private enum WorkspaceNamePrompt: Identifiable {
    case create
    case rename(Workspace)
    case clone(Workspace)

    var id: String {
        switch self {
        case .create:
            "create"
        case .rename(let workspace):
            "rename-\(workspace.id.uuidString)"
        case .clone(let workspace):
            "clone-\(workspace.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .create:
            String(localized: "workspace_new")
        case .rename:
            String(localized: "rename")
        case .clone:
            String(localized: "clone")
        }
    }

    var confirmTitle: String {
        switch self {
        case .rename:
            String(localized: "save")
        case .create, .clone:
            String(localized: "create")
        }
    }
}

/// Sheet-backed workspace prompt used for create, rename, and clone flows on iOS.
private struct WorkspaceNamePromptView: View {
    @Environment(\.colorScheme) private var colorScheme

    let prompt: WorkspaceNamePrompt
    @Binding var name: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @FocusState private var isNameFieldFocused: Bool

    private var canConfirm: Bool {
        !name.isEmpty
    }

    private var dialogBackground: Color {
        AndroidDialogSurfacePalette.background(for: colorScheme)
    }

    private var dialogPrimaryText: Color {
        AndroidDialogSurfacePalette.primaryText(for: colorScheme)
    }

    private var dialogSecondaryText: Color {
        AndroidDialogSurfacePalette.secondaryText(for: colorScheme)
    }

    private var dialogAccent: Color {
        AndroidDialogSurfacePalette.accent(for: colorScheme)
    }

    private var fieldBackground: Color {
        AndroidDialogSurfacePalette.fieldBackground(for: colorScheme)
    }

    private var fieldBorder: Color {
        AndroidDialogSurfacePalette.fieldBorder(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "name"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(dialogSecondaryText)

            TextField(String(localized: "name"), text: $name)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($isNameFieldFocused)
                .foregroundStyle(dialogPrimaryText)
                .tint(dialogAccent)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(fieldBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(fieldBorder, lineWidth: 1)
                )
                .accessibilityIdentifier("workspaceNamePromptTextField")
                .onSubmit {
                    guard canConfirm else { return }
                    onConfirm()
                }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dialogBackground.ignoresSafeArea())
        .accessibilityIdentifier("workspaceNamePromptScreen")
        .navigationTitle(prompt.title)
        .tint(dialogAccent)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(dialogBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel"), action: onCancel)
                    .accessibilityIdentifier("workspaceNamePromptCancelButton")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(prompt.confirmTitle, action: onConfirm)
                    .disabled(!canConfirm)
                    .accessibilityIdentifier("workspaceNamePromptConfirmButton")
            }
        }
        .task {
            await MainActor.run {
                isNameFieldFocused = true
            }
        }
    }
}
