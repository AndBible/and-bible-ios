// WorkspaceLabelConfigurationService.swift -- Android workspace-scoped label configuration

import Foundation
import SwiftData

/**
 Workspace-owned label behavior edited by Android `LabelEditActivity`.

 The value combines fields stored natively in `WorkspaceSettings` with Android's
 `WorkspaceLabelOverride` row. Keeping this as one domain value prevents the UI from creating a
 parallel settings store or partially saving auto-assignment and display override state.
 */
public struct WorkspaceLabelConfiguration: Sendable, Equatable {
    /// Whether new bookmarks in the workspace automatically receive the label.
    public var isAutoAssigned: Bool

    /// Whether this label is the workspace's primary automatically assigned label.
    public var isPrimaryAutoAssigned: Bool

    /// Android display override: highlight, underline, marker, hidden, or nil for no override.
    public var overrideMode: Int?

    /** Creates one complete workspace-label configuration value. */
    public init(
        isAutoAssigned: Bool = false,
        isPrimaryAutoAssigned: Bool = false,
        overrideMode: Int? = nil
    ) {
        self.isAutoAssigned = isAutoAssigned
        self.isPrimaryAutoAssigned = isPrimaryAutoAssigned
        self.overrideMode = overrideMode
    }
}

/**
 Complete Android-editable value state for one bookmark label.

 This is the persistence-layer counterpart of `LabelEditActivity.LabelData`. It deliberately omits
 relationships and workspace behavior: bookmark/StudyPad ownership stays on `Label`, while
 auto-assignment and display override stay in `WorkspaceLabelConfiguration`. Sharing this value
 prevents each UI route from rebuilding a different subset of editable fields.
 */
public struct LabelEditValues: Sendable, Equatable {
    public var name: String
    public var color: Int
    public var markerStyle: Bool
    public var markerStyleWholeVerse: Bool
    public var underlineStyle: Bool
    public var underlineStyleWholeVerse: Bool
    public var hideStyle: Bool
    public var hideStyleWholeVerse: Bool
    public var favourite: Bool
    public var type: String?
    public var customIcon: String?

    /** Creates explicit values for a new label or a test fixture. */
    public init(
        name: String,
        color: Int = Label.defaultColor,
        markerStyle: Bool = false,
        markerStyleWholeVerse: Bool = false,
        underlineStyle: Bool = false,
        underlineStyleWholeVerse: Bool = true,
        hideStyle: Bool = false,
        hideStyleWholeVerse: Bool = false,
        favourite: Bool = false,
        type: String? = nil,
        customIcon: String? = nil
    ) {
        self.name = name
        self.color = color
        self.markerStyle = markerStyle
        self.markerStyleWholeVerse = markerStyleWholeVerse
        self.underlineStyle = underlineStyle
        self.underlineStyleWholeVerse = underlineStyleWholeVerse
        self.hideStyle = hideStyle
        self.hideStyleWholeVerse = hideStyleWholeVerse
        self.favourite = favourite
        self.type = type
        self.customIcon = customIcon
    }

    /** Creates a complete editable snapshot from one persisted label. */
    public init(label: Label) {
        self.init(
            name: label.name,
            color: label.color,
            markerStyle: label.markerStyle,
            markerStyleWholeVerse: label.markerStyleWholeVerse,
            underlineStyle: label.underlineStyle,
            underlineStyleWholeVerse: label.underlineStyleWholeVerse,
            hideStyle: label.hideStyle,
            hideStyleWholeVerse: label.hideStyleWholeVerse,
            favourite: label.favourite,
            type: label.type,
            customIcon: label.customIcon
        )
    }

    /**
     Applies every Android-editable value without saving or changing relationship ownership.

     - Parameters:
       - label: Persisted label owned by the caller's isolated write context.
       - preservesSystemName: Whether an existing reserved label keeps its canonical name.
     - Side effects: Mutates scalar label fields in memory.
     - Failure modes: none; validation and persistence belong to the service transaction.
     */
    func apply(to label: Label, preservesSystemName: Bool) {
        if !preservesSystemName || !label.isSystemLabel {
            label.name = name
        }
        label.color = color
        label.markerStyle = markerStyle
        label.markerStyleWholeVerse = markerStyleWholeVerse
        label.underlineStyle = underlineStyle
        label.underlineStyleWholeVerse = underlineStyleWholeVerse
        label.hideStyle = hideStyle
        label.hideStyleWholeVerse = hideStyleWholeVerse
        label.favourite = favourite
        label.type = type
        label.customIcon = customIcon
    }
}

/** Errors raised before a workspace-label mutation can be committed. */
public enum WorkspaceLabelConfigurationError: Error, LocalizedError, Equatable {
    /// Android only defines override modes 0 through 3.
    case invalidOverrideMode(Int)

    /// A workspace override requires the production settings entity.
    case settingsStorageUnavailable

    /// The requested label disappeared before the isolated commit began.
    case labelNotFound(UUID)

    /// The requested workspace disappeared before the isolated commit began.
    case workspaceNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidOverrideMode(let mode):
            return "Invalid Android workspace label override mode: \(mode)."
        case .settingsStorageUnavailable:
            return "Workspace label settings storage is unavailable."
        case .labelNotFound(let id):
            return "Label not found: \(id.uuidString)."
        case .workspaceNotFound(let id):
            return "Workspace not found: \(id.uuidString)."
        }
    }
}

/**
 Coordinates Android label mutations that span bookmark and workspace persistence categories.

 Labels belong to the bookmark database contract, while auto-assignment and display overrides
 belong to the active workspace contract. This service commits both projections in one SwiftData
 transaction and records both remote-sync categories, so callers never need to bypass existing
 persistence owners or duplicate Android's primary-label invariant.
 */
public final class WorkspaceLabelConfigurationService {
    /// Caller context used only for read-only configuration projection.
    private let readContext: ModelContext

    /// Shared container used by this service's isolated transaction extensions.
    let modelContainer: ModelContainer

    /** Creates a configuration service bound to one model context. */
    public init(modelContext: ModelContext) {
        readContext = modelContext
        modelContainer = modelContext.container
    }

    /**
     Reads the complete configuration for one label in an optional workspace.

     - Parameters:
       - labelID: Persisted label identity.
       - workspace: Active workspace, or nil for routes without workspace context.
     - Returns: Stored auto-assignment, primary, and display-override values; a nil workspace returns
       an empty configuration.
     - Side effects: none.
     - Failure modes: Missing or malformed fidelity rows are treated as no override, matching the
       fidelity store's fail-closed read contract.
     */
    public func configuration(
        for labelID: UUID,
        in workspace: Workspace?
    ) -> WorkspaceLabelConfiguration {
        guard let workspace else { return WorkspaceLabelConfiguration() }
        let settings = workspace.workspaceSettings ?? WorkspaceSettings()
        let override = RemoteSyncWorkspaceFidelityStore(
            settingsStore: SettingsStore(modelContext: readContext)
        ).labelOverride(workspaceID: workspace.id, labelID: labelID)
        return WorkspaceLabelConfiguration(
            isAutoAssigned: settings.autoAssignLabels.contains(labelID),
            isPrimaryAutoAssigned: settings.autoAssignPrimaryLabel == labelID,
            overrideMode: override?.overrideMode
        )
    }

    /**
     Updates one existing label and its optional workspace configuration in an isolated transaction.

     - Parameters:
       - labelID: Stable identity of the existing label.
       - values: Complete replacement Android-editable scalar state.
       - workspaceID: Active workspace identity, or nil outside a workspace-aware route.
       - configuration: Complete replacement workspace behavior for the label.
     - Side effects: Mutates the isolated label graph, workspace settings, override fidelity, and
       bookmark/workspace remote-sync journals, then commits one transaction.
     - Throws: Missing identities, invalid override values, strict snapshot failures, cancellation,
       or SwiftData transaction failures. The caller's live context is never mutated on failure.
     */
    public func updateLabel(
        id labelID: UUID,
        values: LabelEditValues,
        workspaceID: UUID?,
        configuration: WorkspaceLabelConfiguration
    ) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let label = try fetchLabel(id: labelID, in: context) else {
            throw WorkspaceLabelConfigurationError.labelNotFound(labelID)
        }
        let workspace = try fetchWorkspace(id: workspaceID, in: context)
        try persistLabelMutation(
            labelID: labelID,
            workspace: workspace,
            configuration: configuration,
            modelContext: context
        ) {
            values.apply(to: label, preservesSystemName: true)
        }
    }

    /**
     Creates and commits one complete Android label and optional workspace configuration.

     - Parameters:
       - id: Stable identity allocated before the transaction so workspace settings can reference it.
       - values: Complete persisted label scalar state.
       - workspaceID: Active workspace identity, or nil outside a workspace-aware route.
       - configuration: Complete workspace behavior for the new label.
     - Returns: Stable identity of the committed label.
     - Side effects: Inserts the label and commits bookmark/workspace journals in an isolated context.
     - Throws: Validation, missing-workspace, strict journal, cancellation, or SwiftData failures.
     */
    @discardableResult
    public func createLabel(
        id: UUID = UUID(),
        values: LabelEditValues,
        workspaceID: UUID?,
        configuration: WorkspaceLabelConfiguration
    ) throws -> UUID {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let workspace = try fetchWorkspace(id: workspaceID, in: context)
        return try persistLabelMutation(
            labelID: id,
            workspace: workspace,
            configuration: configuration,
            modelContext: context
        ) {
            let label = Label(id: id)
            values.apply(to: label, preservesSystemName: false)
            context.insert(label)
            return id
        }
    }

    /**
     Deletes one label through the complete Android bookmark/workspace ownership boundary.

     - Parameters:
       - labelID: Stable identity of the non-system label being deleted.
       - deleteOrphanedBookmarks: Whether bookmarks with no other live label are also deleted.
     - Returns: The exact bookmark deletion preview applied by the transaction.
     - Side effects: Deletes the label and selected orphan bookmark graphs, removes the label from
       every workspace's auto-assignment, primary, recent-label, and Study Pad cursor state, removes
       every workspace display override for the label, records bookmark and workspace journals,
       and commits the generation atomically.
     - Throws: Missing labels, strict snapshot failures, cancellation, or SwiftData transaction
       failures. The caller's live context is never mutated on failure.
     */
    @discardableResult
    public func deleteLabel(
        id labelID: UUID,
        deleteOrphanedBookmarks: Bool
    ) throws -> BookmarkLabelDeletionImpact {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let store = BookmarkStore(modelContext: context)
        let bookmarkService = BookmarkService(store: store)
        guard let label = store.label(id: labelID),
              let impact = bookmarkService.labelDeletionImpact(id: labelID) else {
            throw WorkspaceLabelConfigurationError.labelNotFound(labelID)
        }

        let stageDeletion = {
            store.stageDelete(
                label,
                deletingBibleBookmarkIDs: deleteOrphanedBookmarks ? Set(impact.bibleBookmarkIDs) : [],
                deletingGenericBookmarkIDs: deleteOrphanedBookmarks ? Set(impact.genericBookmarkIDs) : []
            )
            try self.removeWorkspaceReferences(to: labelID, in: context)
        }

        guard context.container.schema.entitiesByName["Setting"] != nil else {
            try stageDeletion()
            try context.save()
            return impact
        }

        let settingsStore = SettingsStore(modelContext: context)
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        let journal = RemoteSyncMutationJournalService()
        return try settingsStore.performJournaledSave(in: context) {
            try stageDeletion()
            fidelityStore.removeLabelOverrides(forLabelID: labelID)
            context.processPendingChanges()
            try journal.recordLocalChanges(
                for: .bookmarks,
                modelContext: context,
                settingsStore: settingsStore
            )
            if context.container.schema.entitiesByName["Workspace"] != nil {
                try journal.recordLocalChanges(
                    for: .workspaces,
                    modelContext: context,
                    settingsStore: settingsStore
                )
            }
            return impact
        }
    }

    /**
     Commits a staged label mutation and its optional workspace configuration atomically.

     The caller supplies an isolated context so a failed transaction cannot leave the UI's live
     SwiftData objects carrying values that were rolled back on disk.
     */
    @discardableResult
    private func persistLabelMutation<Result>(
        labelID: UUID,
        workspace: Workspace?,
        configuration: WorkspaceLabelConfiguration,
        modelContext: ModelContext,
        mutation: () throws -> Result
    ) throws -> Result {
        if let mode = configuration.overrideMode, !(0...3).contains(mode) {
            throw WorkspaceLabelConfigurationError.invalidOverrideMode(mode)
        }

        guard modelContext.container.schema.entitiesByName["Setting"] != nil else {
            guard workspace == nil else {
                throw WorkspaceLabelConfigurationError.settingsStorageUnavailable
            }
            let result = try mutation()
            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .bookmarks,
                modelContext: modelContext
            )
            return result
        }

        let settingsStore = SettingsStore(modelContext: modelContext)
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        let journal = RemoteSyncMutationJournalService()

        return try settingsStore.performJournaledSave(in: modelContext) {
            let result = try mutation()
            if let workspace {
                try apply(
                    configuration,
                    for: labelID,
                    in: workspace,
                    fidelityStore: fidelityStore
                )
            }
            modelContext.processPendingChanges()
            try journal.recordLocalChanges(
                for: .bookmarks,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            if workspace != nil {
                try journal.recordLocalChanges(
                    for: .workspaces,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            }
            return result
        }
    }

    /** Fetches one label by stable identity inside the isolated write context. */
    private func fetchLabel(id: UUID, in context: ModelContext) throws -> Label? {
        var descriptor = FetchDescriptor<Label>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /** Resolves an optional workspace identity inside the isolated write context. */
    private func fetchWorkspace(id: UUID?, in context: ModelContext) throws -> Workspace? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let workspace = try context.fetch(descriptor).first else {
            throw WorkspaceLabelConfigurationError.workspaceNotFound(id)
        }
        return workspace
    }

    /** Removes every workspace-owned reference to one globally deleted label. */
    private func removeWorkspaceReferences(
        to labelID: UUID,
        in context: ModelContext
    ) throws {
        guard context.container.schema.entitiesByName["Workspace"] != nil else { return }
        for workspace in try context.fetch(FetchDescriptor<Workspace>()) {
            guard var settings = workspace.workspaceSettings else { continue }
            let removedAutoAssignment = settings.autoAssignLabels.remove(labelID) != nil
            let removedPrimary = settings.autoAssignPrimaryLabel == labelID
            let originalRecentCount = settings.recentLabels.count
            settings.recentLabels.removeAll { $0.labelId == labelID }
            let removedCursor = settings.studyPadCursors.removeValue(forKey: labelID) != nil
            guard removedAutoAssignment
                    || removedPrimary
                    || settings.recentLabels.count != originalRecentCount
                    || removedCursor else {
                continue
            }
            if removedPrimary {
                settings.autoAssignPrimaryLabel = nil
            }
            settings.normalizeAutoAssignPrimaryLabel()
            workspace.workspaceSettings = settings
        }
    }

    /** Applies one validated configuration without committing outside the caller's transaction. */
    private func apply(
        _ configuration: WorkspaceLabelConfiguration,
        for labelID: UUID,
        in workspace: Workspace,
        fidelityStore: RemoteSyncWorkspaceFidelityStore
    ) throws {
        var settings = workspace.workspaceSettings ?? WorkspaceSettings()
        if configuration.isAutoAssigned || configuration.isPrimaryAutoAssigned {
            settings.autoAssignLabels.insert(labelID)
        } else {
            settings.autoAssignLabels.remove(labelID)
        }
        if configuration.isPrimaryAutoAssigned {
            settings.autoAssignPrimaryLabel = labelID
        } else if settings.autoAssignPrimaryLabel == labelID {
            settings.autoAssignPrimaryLabel = nil
        }
        settings.normalizeAutoAssignPrimaryLabel()
        workspace.workspaceSettings = settings

        if let overrideMode = configuration.overrideMode {
            try fidelityStore.setLabelOverride(RemoteSyncCurrentWorkspaceLabelOverrideRow(
                workspaceID: workspace.id,
                labelID: labelID,
                overrideMode: overrideMode
            ))
        } else {
            fidelityStore.removeLabelOverride(workspaceID: workspace.id, labelID: labelID)
        }
    }
}
