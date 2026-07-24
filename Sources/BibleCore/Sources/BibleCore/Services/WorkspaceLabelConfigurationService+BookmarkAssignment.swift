// WorkspaceLabelConfigurationService+BookmarkAssignment.swift -- Atomic Android label assignment

import Foundation
import SwiftData

/**
 Complete persisted state loaded when Android `ManageLabels.Mode.ASSIGN` opens.

 Android initializes a multi-bookmark assignment from the union of every bookmark's labels and
 carries workspace auto-assignment state through the same activity. Keeping those values in one
 domain snapshot prevents the SwiftUI route from assembling a partial, UI-owned persistence model.
 */
public struct BookmarkLabelAssignmentSnapshot: Sendable, Equatable {
    /// Number of Bible and generic bookmarks resolved by the assignment route.
    public let bookmarkCount: Int

    /// Union of label identities attached to every selected bookmark.
    public let selectedLabelIDs: Set<UUID>

    /// Primary label for a single bookmark, or nil for Android's multi-bookmark route.
    public let primaryLabelID: UUID?

    /// Workspace labels automatically attached to newly created bookmarks.
    public let autoAssignLabelIDs: Set<UUID>

    /// Workspace primary auto-assignment, normalized into `autoAssignLabelIDs`.
    public let autoAssignPrimaryLabelID: UUID?

    /// Workspace recent-label order used by Android's Active/Recent/Other grouping.
    public let recentLabelIDs: [UUID]
}

/** Errors that prevent an Android label-assignment generation from loading or committing. */
public enum BookmarkLabelAssignmentError: Error, LocalizedError, Equatable {
    /// One or more route identities disappeared before the operation ran.
    case missingBookmarks([UUID])

    /// One or more selected or workspace label identities disappeared before commit.
    case missingLabels([UUID])

    /// The workspace route no longer resolves in the isolated transaction context.
    case workspaceNotFound(UUID)

    /// A workspace mutation cannot be journaled because the production settings schema is absent.
    case settingsStorageUnavailable

    public var errorDescription: String? {
        switch self {
        case .missingBookmarks(let ids):
            return "Bookmark not found: \(Self.identifierList(ids))."
        case .missingLabels(let ids):
            return "Label not found: \(Self.identifierList(ids))."
        case .workspaceNotFound(let id):
            return "Workspace not found: \(id.uuidString)."
        case .settingsStorageUnavailable:
            return "Workspace label settings storage is unavailable."
        }
    }

    /// Stable identifier rendering used by diagnostics and tests.
    private static func identifierList(_ ids: [UUID]) -> String {
        ids.map(\.uuidString).sorted().joined(separator: ", ")
    }
}

public extension WorkspaceLabelConfigurationService {
    /**
     Loads Android's complete ASSIGN-mode state for Bible and generic bookmarks.

     - Parameters:
       - bookmarkIDs: Selected bookmark identities. Duplicate identities are collapsed.
       - workspaceID: Active workspace identity, or nil outside a reader workspace.
     - Returns: Union selection, single-bookmark primary, and workspace label configuration.
     - Side effects: Creates an isolated read context and fetches bookmark/workspace graphs.
     - Throws: `BookmarkLabelAssignmentError` for stale bookmark/workspace routes, or SwiftData
       fetch failures.
     */
    func bookmarkLabelAssignmentSnapshot(
        bookmarkIDs: [UUID],
        workspaceID: UUID?
    ) throws -> BookmarkLabelAssignmentSnapshot {
        let context = ModelContext(modelContainer)
        let requestedIDs = Set(bookmarkIDs)
        let bibleBookmarks = try context.fetch(FetchDescriptor<BibleBookmark>())
            .filter { requestedIDs.contains($0.id) }
        let genericBookmarks = try context.fetch(FetchDescriptor<GenericBookmark>())
            .filter { requestedIDs.contains($0.id) }
        let resolvedIDs = Set(bibleBookmarks.map(\.id) + genericBookmarks.map(\.id))
        let missingIDs = requestedIDs.subtracting(resolvedIDs)
        guard missingIDs.isEmpty else {
            throw BookmarkLabelAssignmentError.missingBookmarks(Array(missingIDs))
        }

        let selectedLabelIDs = Set(
            bibleBookmarks.flatMap { $0.bookmarkToLabels?.compactMap { $0.label?.id } ?? [] }
                + genericBookmarks.flatMap { $0.bookmarkToLabels?.compactMap { $0.label?.id } ?? [] }
        )
        let primaryLabelID: UUID?
        if requestedIDs.count == 1 {
            primaryLabelID = bibleBookmarks.first?.primaryLabelId
                ?? genericBookmarks.first?.primaryLabelId
        } else {
            primaryLabelID = nil
        }

        let workspace = try assignmentWorkspace(id: workspaceID, in: context)
        var workspaceSettings = workspace?.workspaceSettings ?? WorkspaceSettings()
        workspaceSettings.normalizeAutoAssignPrimaryLabel()
        return BookmarkLabelAssignmentSnapshot(
            bookmarkCount: resolvedIDs.count,
            selectedLabelIDs: selectedLabelIDs,
            primaryLabelID: primaryLabelID,
            autoAssignLabelIDs: workspaceSettings.autoAssignLabels,
            autoAssignPrimaryLabelID: workspaceSettings.autoAssignPrimaryLabel,
            recentLabelIDs: workspaceSettings.recentLabels.map(\.labelId)
        )
    }

    /**
     Commits one complete Android ASSIGN-mode generation atomically.

     Every selected bookmark receives the exact same requested label set, matching Android's
     multi-bookmark `changeLabelsForBookmark` contract. Existing junction metadata is retained for
     labels that stay assigned; newly attached labels use Android's default `orderNumber == -1`.
     Primary labels are preserved when still valid, otherwise repaired to the explicit primary or
     first requested label. Favourite and workspace auto-assignment edits share the same journaled
     transaction, so a failure cannot publish only part of the visible screen state.

     - Parameters:
       - bookmarkIDs: Bible and generic bookmark identities receiving the exact label set.
       - orderedSelectedLabelIDs: Selected labels in deterministic visible order.
       - primaryLabelID: Explicit primary selection, or nil to preserve/repair each bookmark.
       - favouriteValues: Changed favourite flags keyed by label identity.
       - autoAssignLabelIDs: Exact workspace auto-assignment set.
       - autoAssignPrimaryLabelID: Workspace primary auto-assignment, if any.
       - workspaceID: Active workspace identity, or nil outside workspace-aware presentation.
     - Side effects: Mutates bookmark junctions, bookmark timestamps/primary labels, label
       favourites, workspace settings, remote-sync journals, and commits one isolated context.
     - Throws: Stale identities, invalid workspace state, strict journal failures, cancellation,
       or SwiftData transaction failures. No live UI model is mutated on failure.
     */
    func commitBookmarkLabelAssignment(
        bookmarkIDs: [UUID],
        orderedSelectedLabelIDs: [UUID],
        primaryLabelID: UUID?,
        favouriteValues: [UUID: Bool],
        autoAssignLabelIDs: Set<UUID>,
        autoAssignPrimaryLabelID: UUID?,
        workspaceID: UUID?
    ) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let requestedBookmarkIDs = Set(bookmarkIDs)
        let selectedLabelIDs = Self.uniqueOrderedIDs(orderedSelectedLabelIDs)
            .filter { $0 != Label.unlabeledId }
        let requiredLabelIDs = Set(selectedLabelIDs)
            .union(favouriteValues.keys)
            .union(autoAssignLabelIDs)
            .union(primaryLabelID.map { [$0] } ?? [])
            .union(autoAssignPrimaryLabelID.map { [$0] } ?? [])
        let allLabels = try context.fetch(FetchDescriptor<Label>())
        let labelsByID = Dictionary(uniqueKeysWithValues: allLabels.map { ($0.id, $0) })
        let missingLabelIDs = requiredLabelIDs.subtracting(labelsByID.keys)
        guard missingLabelIDs.isEmpty else {
            throw BookmarkLabelAssignmentError.missingLabels(Array(missingLabelIDs))
        }

        let bibleBookmarks = try context.fetch(FetchDescriptor<BibleBookmark>())
            .filter { requestedBookmarkIDs.contains($0.id) }
        let genericBookmarks = try context.fetch(FetchDescriptor<GenericBookmark>())
            .filter { requestedBookmarkIDs.contains($0.id) }
        let resolvedBookmarkIDs = Set(bibleBookmarks.map(\.id) + genericBookmarks.map(\.id))
        let missingBookmarkIDs = requestedBookmarkIDs.subtracting(resolvedBookmarkIDs)
        guard missingBookmarkIDs.isEmpty else {
            throw BookmarkLabelAssignmentError.missingBookmarks(Array(missingBookmarkIDs))
        }

        let workspace = try assignmentWorkspace(id: workspaceID, in: context)
        let applyMutation = {
            let timestamp = Date()
            for bookmark in bibleBookmarks {
                Self.replaceLabels(
                    on: bookmark,
                    with: selectedLabelIDs,
                    labelsByID: labelsByID,
                    explicitPrimaryLabelID: primaryLabelID,
                    timestamp: timestamp,
                    context: context
                )
            }
            for bookmark in genericBookmarks {
                Self.replaceLabels(
                    on: bookmark,
                    with: selectedLabelIDs,
                    labelsByID: labelsByID,
                    explicitPrimaryLabelID: primaryLabelID,
                    timestamp: timestamp,
                    context: context
                )
            }
            for (labelID, value) in favouriteValues {
                labelsByID[labelID]?.favourite = value
            }
            if let workspace {
                var settings = workspace.workspaceSettings ?? WorkspaceSettings()
                settings.autoAssignLabels = autoAssignLabelIDs
                    .filter { $0 != Label.unlabeledId && labelsByID[$0] != nil }
                    .reduce(into: Set<UUID>()) { $0.insert($1) }
                settings.autoAssignPrimaryLabel = autoAssignPrimaryLabelID
                settings.normalizeAutoAssignPrimaryLabel()
                workspace.workspaceSettings = settings
            }
            context.processPendingChanges()
        }

        guard context.container.schema.entitiesByName["Setting"] != nil else {
            guard workspace == nil else {
                throw BookmarkLabelAssignmentError.settingsStorageUnavailable
            }
            applyMutation()
            try RemoteSyncMutationJournalService.savePendingGraphChanges(
                for: .bookmarks,
                modelContext: context
            )
            return
        }

        let settingsStore = SettingsStore(modelContext: context)
        let journal = RemoteSyncMutationJournalService()
        try settingsStore.performJournaledSave(in: context) {
            applyMutation()
            try journal.recordLocalChanges(
                for: .bookmarks,
                modelContext: context,
                settingsStore: settingsStore
            )
            if workspace != nil {
                try journal.recordLocalChanges(
                    for: .workspaces,
                    modelContext: context,
                    settingsStore: settingsStore
                )
            }
        }
    }

    /** Resolves one optional workspace in the assignment transaction context. */
    private func assignmentWorkspace(id: UUID?, in context: ModelContext) throws -> Workspace? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Workspace>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let workspace = try context.fetch(descriptor).first else {
            throw BookmarkLabelAssignmentError.workspaceNotFound(id)
        }
        return workspace
    }

    /** Removes duplicate identifiers without losing the caller's Android-visible order. */
    private static func uniqueOrderedIDs(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    /** Applies the exact label set to one Bible bookmark without saving mid-generation. */
    private static func replaceLabels(
        on bookmark: BibleBookmark,
        with selectedLabelIDs: [UUID],
        labelsByID: [UUID: Label],
        explicitPrimaryLabelID: UUID?,
        timestamp: Date,
        context: ModelContext
    ) {
        let existingLinks = bookmark.bookmarkToLabels ?? []
        let existingByLabelID = Dictionary(
            existingLinks.compactMap { link in link.label.map { ($0.id, link) } },
            uniquingKeysWith: { first, _ in first }
        )
        let selectedSet = Set(selectedLabelIDs)
        for link in existingLinks where link.label.map({ !selectedSet.contains($0.id) }) ?? true {
            bookmark.bookmarkToLabels?.removeAll { $0 === link }
            context.delete(link)
        }
        for labelID in selectedLabelIDs where existingByLabelID[labelID] == nil {
            guard let label = labelsByID[labelID] else { continue }
            let link = BibleBookmarkToLabel()
            link.bookmark = bookmark
            link.label = label
            context.insert(link)
        }
        bookmark.primaryLabelId = repairedPrimaryLabelID(
            current: bookmark.primaryLabelId,
            explicit: explicitPrimaryLabelID,
            selectedLabelIDs: selectedLabelIDs
        )
        bookmark.lastUpdatedOn = timestamp
    }

    /** Applies the exact label set to one generic bookmark without saving mid-generation. */
    private static func replaceLabels(
        on bookmark: GenericBookmark,
        with selectedLabelIDs: [UUID],
        labelsByID: [UUID: Label],
        explicitPrimaryLabelID: UUID?,
        timestamp: Date,
        context: ModelContext
    ) {
        let existingLinks = bookmark.bookmarkToLabels ?? []
        let existingByLabelID = Dictionary(
            existingLinks.compactMap { link in link.label.map { ($0.id, link) } },
            uniquingKeysWith: { first, _ in first }
        )
        let selectedSet = Set(selectedLabelIDs)
        for link in existingLinks where link.label.map({ !selectedSet.contains($0.id) }) ?? true {
            bookmark.bookmarkToLabels?.removeAll { $0 === link }
            context.delete(link)
        }
        for labelID in selectedLabelIDs where existingByLabelID[labelID] == nil {
            guard let label = labelsByID[labelID] else { continue }
            let link = GenericBookmarkToLabel()
            link.bookmark = bookmark
            link.label = label
            context.insert(link)
        }
        bookmark.primaryLabelId = repairedPrimaryLabelID(
            current: bookmark.primaryLabelId,
            explicit: explicitPrimaryLabelID,
            selectedLabelIDs: selectedLabelIDs
        )
        bookmark.lastUpdatedOn = timestamp
    }

    /** Preserves a live primary, otherwise chooses the explicit or first visible assignment. */
    private static func repairedPrimaryLabelID(
        current: UUID?,
        explicit: UUID?,
        selectedLabelIDs: [UUID]
    ) -> UUID? {
        if let explicit, selectedLabelIDs.contains(explicit) { return explicit }
        if let current, selectedLabelIDs.contains(current) { return current }
        return selectedLabelIDs.first
    }
}
