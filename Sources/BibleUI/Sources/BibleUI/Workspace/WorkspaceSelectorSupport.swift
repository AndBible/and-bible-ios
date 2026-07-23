// WorkspaceSelectorSupport.swift -- Value-state and drag contracts for workspace management

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import BibleCore

/**
 One staged row in the app-owned workspace selector activity.

 Android keeps workspace edits in the activity's mutable data set until Save, while newly copied
 workspaces retain their source identity until the activity commits them. This value prevents
 SwiftData's live models from making Rename, Remove, Settings, and reorder actions irreversible
 before the user accepts the activity commit bar.

 Inputs: persisted workspace snapshots or a source draft selected for Copy as new
 Output: deterministic, equatable state suitable for filtering, reordering, and dirty detection
 Side effects: none
 Failure modes: none; missing optional settings preserve Android inheritance semantics
 */
struct WorkspaceSelectorDraft: Identifiable, Equatable {
    /** Durable source used when applying one staged row. */
    enum Origin: Equatable {
        /// Existing persisted workspace updated in place at commit time.
        case persisted(UUID)

        /// Existing persisted workspace deep-cloned at commit time.
        case clone(sourceID: UUID)
    }

    /// Stable selector identity; clones use a temporary identity until commit.
    let id: UUID

    /// Persistence operation used when applying the draft.
    let origin: Origin

    /// User-visible workspace name.
    var name: String

    /// Android workspace-list summary.
    var contentsText: String?

    /// Workspace-scoped text-display overrides staged by Settings and copy actions.
    var textDisplaySettings: TextDisplaySettings?

    /// Workspace toolbar/control color staged with text-display settings.
    var workspaceColor: Int?

    /** Creates a side-effect-free draft from one persisted workspace. */
    init(workspace: Workspace) {
        id = workspace.id
        origin = .persisted(workspace.id)
        name = workspace.name
        contentsText = workspace.contentsText
        textDisplaySettings = workspace.textDisplaySettings
        workspaceColor = workspace.workspaceColor
    }

    /** Creates a staged deep-copy row without writing a SwiftData graph. */
    init(cloning source: WorkspaceSelectorDraft, name: String) {
        id = UUID()
        switch source.origin {
        case .persisted(let sourceID), .clone(let sourceID):
            origin = .clone(sourceID: sourceID)
        }
        self.name = name
        contentsText = source.contentsText
        textDisplaySettings = source.textDisplaySettings
        workspaceColor = source.workspaceColor
    }

    /// Persisted identity for existing rows; clones intentionally return nil until commit.
    var persistedID: UUID? {
        guard case .persisted(let id) = origin else { return nil }
        return id
    }
}

/** App-owned child activity displayed from the workspace selector. */
enum WorkspaceSelectorSettingsDestination: Equatable {
    /// Workspace-scoped Text Options for the specified draft.
    case workspace(UUID)

    /// Global Text Options, returning to the specified workspace route on Back.
    case global(returningTo: UUID)
}

/** Android's two-stage selective workspace-settings copy workflow. */
enum WorkspaceSelectorCopyStage: Equatable {
    /// Choose fields before choosing target workspaces.
    case fieldsToWorkspaces(sourceID: UUID)

    /// Choose target workspaces for the previously selected fields.
    case targetWorkspaces(sourceID: UUID)

    /// Choose fields to copy directly to global defaults.
    case fieldsToGlobal(sourceID: UUID)
}

/** Pending workspace activation after Android's Apply changes confirmation. */
enum WorkspaceSelectorPendingActivation: Equatable {
    /// Select one row already represented by a selector draft.
    case draft(UUID)

    /// Create and select a new workspace after accepting or discarding other staged edits.
    case newWorkspace(name: String)
}

/**
 Reorders workspace drafts from Android's row drag handle.

 The selector disables this delegate while search filtering is active, matching Android's
 `RecyclerViewSearchHelper` behavior. The delegate mutates only staged value state and never writes
 SwiftData; Save remains the single persistence boundary.
 */
struct WorkspaceSelectorDropDelegate: DropDelegate {
    /// Row currently receiving the dragged item.
    let targetID: UUID

    /// Complete unfiltered staged order.
    @Binding var drafts: [WorkspaceSelectorDraft]

    /// Identity captured by the drag handle at drag start.
    @Binding var draggedID: UUID?

    /// Whether reordering is allowed for the current search state.
    let isEnabled: Bool

    /** Moves the source beside the entered target without persisting the result. */
    func dropEntered(info: DropInfo) {
        guard isEnabled,
              let draggedID,
              draggedID != targetID,
              let sourceIndex = drafts.firstIndex(where: { $0.id == draggedID }),
              let targetIndex = drafts.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        withAnimation(.easeInOut(duration: 0.12)) {
            drafts.move(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
            )
        }
    }

    /** Accepts plain-text drag providers emitted by workspace drag handles. */
    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && info.hasItemsConforming(to: [UTType.text])
    }

    /** Ends the staged drag operation without any persistence side effect. */
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        draggedID = nil
        return true
    }

    /** Advertises Android's reorder operation instead of a copy operation. */
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
