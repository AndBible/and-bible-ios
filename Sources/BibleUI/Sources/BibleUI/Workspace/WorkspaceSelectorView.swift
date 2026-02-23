// WorkspaceSelectorView.swift — Workspace selection and management

import SwiftUI
import SwiftData
import BibleCore

/// Allows switching between workspaces and managing them.
public struct WorkspaceSelectorView: View {
    @Environment(WindowManager.self) private var windowManager
    @Environment(\.modelContext) private var modelContext
    @State private var showNewWorkspace = false
    @State private var newWorkspaceName = ""
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Workspace.orderNumber) private var workspaces: [Workspace]

    public init() {}

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
                        Button {
                            windowManager.setActiveWorkspace(workspace)
                            dismiss()
                        } label: {
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
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteWorkspaces)
                }
            }
        }
        .navigationTitle(String(localized: "workspaces"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "done")) { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "add"), systemImage: "plus") {
                    showNewWorkspace = true
                }
            }
        }
        .alert(String(localized: "workspace_new"), isPresented: $showNewWorkspace) {
            TextField(String(localized: "name"), text: $newWorkspaceName)
            Button(String(localized: "create")) {
                guard !newWorkspaceName.isEmpty else { return }
                let store = WorkspaceStore(modelContext: modelContext)
                let workspace = store.createWorkspace(name: newWorkspaceName)
                windowManager.setActiveWorkspace(workspace)
                newWorkspaceName = ""
                dismiss()
            }
            Button(String(localized: "cancel"), role: .cancel) { newWorkspaceName = "" }
        }
    }

    private func deleteWorkspaces(at offsets: IndexSet) {
        let store = WorkspaceStore(modelContext: modelContext)
        for index in offsets {
            let workspace = workspaces[index]
            // Don't delete the active workspace
            if workspace.id == windowManager.activeWorkspace?.id {
                continue
            }
            store.delete(workspace)
        }
    }
}
