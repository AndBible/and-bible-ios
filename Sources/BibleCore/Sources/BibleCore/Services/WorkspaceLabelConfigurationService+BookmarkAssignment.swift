// WorkspaceLabelConfigurationService+BookmarkAssignment.swift -- Android label assignment

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

    /// Reader primary for one bookmark; nil for bookmark-list and workspace routes.
    public let primaryLabelID: UUID?

    /// Workspace labels automatically attached to newly created bookmarks.
    public let autoAssignLabelIDs: Set<UUID>

    /// Workspace primary auto-assignment, normalized into `autoAssignLabelIDs`.
    public let autoAssignPrimaryLabelID: UUID?

    /// Workspace recent-label order used by Android's Active/Recent/Other grouping.
    public let recentLabelIDs: [UUID]
}

/** Identifies the Android caller whose distinct label-mutation contract must be reproduced. */
public enum BookmarkLabelAssignmentIntent: Sendable, Equatable {
    /// `BibleView.assignLabels`: differential links, explicit primary, and StudyPad placement.
    case reader

    /// `Bookmarks.assignLabels`: exact link recreation with default StudyPad metadata.
    case bookmarkList

    /// `ManageLabels.Mode.WORKSPACE`: favourite and workspace fields without bookmark rows.
    case workspace
}

/** Errors that prevent an Android label-assignment generation from loading or committing. */
public enum BookmarkLabelAssignmentError: Error, LocalizedError, Equatable {
    /// One or more route identities disappeared before the operation ran.
    case missingBookmarks([UUID])

    /// One or more selected or workspace label identities disappeared before commit.
    case missingLabels([UUID])

    /// The workspace route no longer resolves in the isolated transaction context.
    case workspaceNotFound(UUID)

    /// The assignment cannot be journaled because the production settings schema is absent.
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
       - bookmarkIDs: Selected reader/list identities. Duplicate identities are collapsed;
         workspace intent ignores this parameter.
       - workspaceID: Active workspace identity, or nil outside a reader workspace.
       - intent: Android caller contract that determines whether a single primary is exposed.
     - Returns: Union selection, single-bookmark primary, and workspace label configuration.
     - Side effects: Creates an isolated read context and fetches only the requested bookmark
       identities plus the optional workspace graph.
     - Throws: `BookmarkLabelAssignmentError` for stale bookmark/workspace routes, or SwiftData
       fetch failures.
     */
    func bookmarkLabelAssignmentSnapshot(
        bookmarkIDs: [UUID],
        workspaceID: UUID?,
        intent: BookmarkLabelAssignmentIntent
    ) throws -> BookmarkLabelAssignmentSnapshot {
        let context = ModelContext(modelContainer)
        let requestedIDs = intent == .workspace ? [] : Set(bookmarkIDs)
        let bibleBookmarks = try assignmentBibleBookmarks(ids: requestedIDs, in: context)
        let genericBookmarks = try assignmentGenericBookmarks(ids: requestedIDs, in: context)
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
        if intent == .reader, requestedIDs.count == 1 {
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
     Commits one complete Android ASSIGN-mode generation in one isolated journaled save.

     Reader assignment preserves retained junctions, places new links at Android's StudyPad cursor
     or item count, and applies the returned primary. Bookmark-list assignment recreates the exact
     link state with Android's default StudyPad metadata and leaves bookmark primaries untouched.
     Favourite and workspace edits use the same isolated journaled-save owner; its existing
     persistence and rollback limits remain unchanged.

     - Parameters:
       - bookmarkIDs: Bible and generic reader/list identities; ignored for workspace intent.
       - orderedSelectedLabelIDs: Reader/list labels in deterministic visible order; ignored for
         workspace intent.
       - primaryLabelID: Reader primary selection; ignored by bookmark-list and workspace routes.
       - favouriteValues: Changed favourite flags keyed by label identity.
       - autoAssignLabelIDs: Exact workspace auto-assignment set.
       - autoAssignPrimaryLabelID: Workspace primary auto-assignment, if any.
       - workspaceID: Active workspace identity, or nil outside workspace-aware presentation.
       - intent: Explicit Android reader, bookmark-list, or workspace caller contract.
     - Side effects: Applies the changed caller-specific junction/primary behavior, label favourites,
       or workspace settings; records only changed category journals and commits one isolated
       context. An unchanged generation performs no save or journal projection.
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
        workspaceID: UUID?,
        intent: BookmarkLabelAssignmentIntent
    ) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let requestedBookmarkIDs = intent == .workspace ? [] : Set(bookmarkIDs)
        let selectedLabelIDs = intent == .workspace
            ? []
            : Self.uniqueOrderedIDs(orderedSelectedLabelIDs)
                .filter { $0 != Label.unlabeledId }
        // Reader/list primary is valid only when selected; workspace primary is valid only when
        // auto-assigned. The selected sets already require those identities, while ignored stale
        // primary inputs must fall back instead of aborting the generation.
        let requiredLabelIDs = Set(selectedLabelIDs)
            .union(favouriteValues.keys)
            .union(autoAssignLabelIDs)
        let labelsByID = try assignmentLabels(ids: requiredLabelIDs, in: context)
        let missingLabelIDs = requiredLabelIDs.subtracting(labelsByID.keys)
        guard missingLabelIDs.isEmpty else {
            throw BookmarkLabelAssignmentError.missingLabels(Array(missingLabelIDs))
        }

        let bibleBookmarks = try assignmentBibleBookmarks(ids: requestedBookmarkIDs, in: context)
        let genericBookmarks = try assignmentGenericBookmarks(ids: requestedBookmarkIDs, in: context)
        let resolvedBookmarkIDs = Set(bibleBookmarks.map(\.id) + genericBookmarks.map(\.id))
        let missingBookmarkIDs = requestedBookmarkIDs.subtracting(resolvedBookmarkIDs)
        guard missingBookmarkIDs.isEmpty else {
            throw BookmarkLabelAssignmentError.missingBookmarks(Array(missingBookmarkIDs))
        }

        let workspace = try assignmentWorkspace(id: workspaceID, in: context)
        guard context.container.schema.entitiesByName["Setting"] != nil else {
            throw BookmarkLabelAssignmentError.settingsStorageUnavailable
        }

        let readerPlan = try Self.readerMutationPlan(
            bibleBookmarks: bibleBookmarks,
            genericBookmarks: genericBookmarks,
            selectedLabelIDs: selectedLabelIDs,
            workspaceSettings: workspace?.workspaceSettings,
            hasWorkspace: workspace != nil,
            intent: intent,
            context: context
        )
        let desiredWorkspaceSettings = workspace.map {
            Self.desiredWorkspaceSettings(
                current: readerPlan.workspaceSettings ?? $0.workspaceSettings,
                autoAssignLabelIDs: autoAssignLabelIDs,
                autoAssignPrimaryLabelID: autoAssignPrimaryLabelID,
                labelsByID: labelsByID
            )
        }
        let bookmarkChanges = Self.bookmarkCategoryChanges(
            bibleBookmarks: bibleBookmarks,
            genericBookmarks: genericBookmarks,
            selectedLabelIDs: selectedLabelIDs,
            primaryLabelID: primaryLabelID,
            favouriteValues: favouriteValues,
            labelsByID: labelsByID,
            intent: intent
        )
        let workspaceChanges: Bool
        if let workspace, let desiredWorkspaceSettings {
            workspaceChanges = !Self.workspaceAssignmentEquals(
                workspace.workspaceSettings,
                desiredWorkspaceSettings
            )
        } else {
            workspaceChanges = false
        }
        try Task.checkCancellation()
        guard bookmarkChanges || workspaceChanges else { return }

        let settingsStore = SettingsStore(modelContext: context)
        let journal = RemoteSyncMutationJournalService()
        try settingsStore.performJournaledSave(in: context) {
            if bookmarkChanges {
                try Self.applyBookmarkMutation(
                    bibleBookmarks: bibleBookmarks,
                    genericBookmarks: genericBookmarks,
                    selectedLabelIDs: selectedLabelIDs,
                    primaryLabelID: primaryLabelID,
                    favouriteValues: favouriteValues,
                    labelsByID: labelsByID,
                    intent: intent,
                    readerPlan: readerPlan,
                    context: context
                )
                try journal.recordLocalChanges(
                    for: .bookmarks,
                    modelContext: context,
                    settingsStore: settingsStore
                )
            }
            if workspaceChanges, let workspace, let desiredWorkspaceSettings {
                workspace.workspaceSettings = desiredWorkspaceSettings
                context.processPendingChanges()
                try journal.recordLocalChanges(
                    for: .workspaces,
                    modelContext: context,
                    settingsStore: settingsStore
                )
            }
        }
    }

    /** Fetches only requested Bible bookmark identities in one bounded-set query. */
    private func assignmentBibleBookmarks(
        ids: Set<UUID>,
        in context: ModelContext
    ) throws -> [BibleBookmark] {
        guard !ids.isEmpty else { return [] }
        let requestedIDs = Array(ids)
        return try context.fetch(FetchDescriptor<BibleBookmark>(
            predicate: #Predicate { requestedIDs.contains($0.id) }
        ))
    }

    /** Fetches only requested generic bookmark identities in one bounded-set query. */
    private func assignmentGenericBookmarks(
        ids: Set<UUID>,
        in context: ModelContext
    ) throws -> [GenericBookmark] {
        guard !ids.isEmpty else { return [] }
        let requestedIDs = Array(ids)
        return try context.fetch(FetchDescriptor<GenericBookmark>(
            predicate: #Predicate { requestedIDs.contains($0.id) }
        ))
    }

    /** Fetches only labels needed to validate and apply the generation in one bounded-set query. */
    private func assignmentLabels(ids: Set<UUID>, in context: ModelContext) throws -> [UUID: Label] {
        guard !ids.isEmpty else { return [:] }
        let requestedIDs = Array(ids)
        let labels = try context.fetch(FetchDescriptor<Label>(
            predicate: #Predicate { requestedIDs.contains($0.id) }
        ))
        // Retain the previous transaction's fail-fast behavior for a duplicated requested UUID.
        return Dictionary(uniqueKeysWithValues: labels.map { ($0.id, $0) })
    }

    /** One Android reader link insertion and whether a cursor requires shifting later items. */
    private struct ReaderInsertion {
        let orderNumber: Int
        let shiftsExistingRows: Bool
    }

    /** Prepared reader-only relationship and workspace effects for the journaled save. */
    private struct ReaderMutationPlan {
        var bibleInsertions: [ObjectIdentifier: [UUID: ReaderInsertion]] = [:]
        var genericInsertions: [ObjectIdentifier: [UUID: ReaderInsertion]] = [:]
        var workspaceSettings: WorkspaceSettings?
    }

    /**
     Prepares Android reader placement, cursor, and recent-label effects without mutating models.
     */
    private static func readerMutationPlan(
        bibleBookmarks: [BibleBookmark],
        genericBookmarks: [GenericBookmark],
        selectedLabelIDs: [UUID],
        workspaceSettings: WorkspaceSettings?,
        hasWorkspace: Bool,
        intent: BookmarkLabelAssignmentIntent,
        context: ModelContext
    ) throws -> ReaderMutationPlan {
        guard intent == .reader else { return ReaderMutationPlan() }
        var plan = ReaderMutationPlan(
            workspaceSettings: hasWorkspace ? workspaceSettings ?? WorkspaceSettings() : nil
        )
        var itemCounts: [UUID: Int] = [:]
        var changedLabelIDs: [UUID] = []

        func insertion(for labelID: UUID) throws -> ReaderInsertion {
            let itemCount: Int
            if let plannedCount = itemCounts[labelID] {
                itemCount = plannedCount
            } else {
                itemCount = try studyPadItemCount(labelID: labelID, in: context)
            }
            let cursor = plan.workspaceSettings?.studyPadCursors[labelID]
            let orderNumber = min(cursor ?? itemCount, itemCount)
            if cursor != nil {
                plan.workspaceSettings?.studyPadCursors[labelID] = orderNumber + 1
            }
            itemCounts[labelID] = itemCount + 1
            return ReaderInsertion(
                orderNumber: orderNumber,
                shiftsExistingRows: cursor != nil
            )
        }

        for bookmark in bibleBookmarks {
            let existing = Set(bookmark.bookmarkToLabels?.compactMap(\.label?.id) ?? [])
            let removed = existing.filter { !selectedLabelIDs.contains($0) }
            let added = selectedLabelIDs.filter { !existing.contains($0) }
            changedLabelIDs.append(contentsOf: added)
            changedLabelIDs.append(contentsOf: removed)
            let insertions = Dictionary(
                uniqueKeysWithValues: try added.map { ($0, try insertion(for: $0)) }
            )
            plan.bibleInsertions[ObjectIdentifier(bookmark)] = insertions
        }
        for bookmark in genericBookmarks {
            let existing = Set(bookmark.bookmarkToLabels?.compactMap(\.label?.id) ?? [])
            let removed = existing.filter { !selectedLabelIDs.contains($0) }
            let added = selectedLabelIDs.filter { !existing.contains($0) }
            changedLabelIDs.append(contentsOf: added)
            changedLabelIDs.append(contentsOf: removed)
            let insertions = Dictionary(
                uniqueKeysWithValues: try added.map { ($0, try insertion(for: $0)) }
            )
            plan.genericInsertions[ObjectIdentifier(bookmark)] = insertions
        }
        if plan.workspaceSettings != nil, !changedLabelIDs.isEmpty {
            updateRecentLabels(
                uniqueOrderedIDs(changedLabelIDs),
                in: &plan.workspaceSettings,
                at: Date()
            )
        }
        return plan
    }

    /** Counts one affected label while preserving iOS's quarantined-Bible trust gate. */
    private static func studyPadItemCount(
        labelID: UUID,
        in context: ModelContext
    ) throws -> Int {
        let bibleRows = try context.fetch(FetchDescriptor<BibleBookmarkToLabel>(
            predicate: #Predicate { $0.label?.id == labelID }
        ))
        let bibleCount = bibleRows.filter {
            $0.bookmark?.hasTrustedPersistedOrdinals == true
        }.count
        let genericCount = try context.fetchCount(FetchDescriptor<GenericBookmarkToLabel>(
            predicate: #Predicate { $0.label?.id == labelID }
        ))
        let textCount = try context.fetchCount(FetchDescriptor<StudyPadTextEntry>(
            predicate: #Predicate { $0.label?.id == labelID }
        ))
        return bibleCount + genericCount + textCount
    }

    /** Updates Android's at-most-15 recent-label list for reader membership changes. */
    private static func updateRecentLabels(
        _ labelIDs: [UUID],
        in workspaceSettings: inout WorkspaceSettings?,
        at timestamp: Date
    ) {
        guard var settings = workspaceSettings else { return }
        for labelID in labelIDs {
            if let index = settings.recentLabels.firstIndex(where: { $0.labelId == labelID }) {
                settings.recentLabels[index].lastAccess = timestamp
                settings.recentLabels.sort { $0.lastAccess < $1.lastAccess }
            } else {
                settings.recentLabels.append(RecentLabel(labelId: labelID, lastAccess: timestamp))
                while settings.recentLabels.count > 15 {
                    settings.recentLabels.removeFirst()
                }
            }
        }
        workspaceSettings = settings
    }

    /** Returns whether the submitted bookmark-category generation differs from persistence. */
    private static func bookmarkCategoryChanges(
        bibleBookmarks: [BibleBookmark],
        genericBookmarks: [GenericBookmark],
        selectedLabelIDs: [UUID],
        primaryLabelID: UUID?,
        favouriteValues: [UUID: Bool],
        labelsByID: [UUID: Label],
        intent: BookmarkLabelAssignmentIntent
    ) -> Bool {
        let selected = Set(selectedLabelIDs)
        let bibleChanged = bibleBookmarks.contains { bookmark in
            let links = bookmark.bookmarkToLabels ?? []
            switch intent {
            case .reader:
                return links.contains { $0.label == nil }
                    || Set(links.compactMap(\.label?.id)) != selected
                    || bookmark.primaryLabelId != readerPrimaryLabelID(
                        explicit: primaryLabelID,
                        selectedLabelIDs: selectedLabelIDs
                    )
            case .bookmarkList:
                return links.count != selected.count
                    || Set(links.compactMap(\.label?.id)) != selected
                    || links.contains {
                        $0.orderNumber != -1 || $0.indentLevel != 0 || !$0.expandContent
                    }
            case .workspace:
                return false
            }
        }
        let genericChanged = genericBookmarks.contains { bookmark in
            let links = bookmark.bookmarkToLabels ?? []
            switch intent {
            case .reader:
                return links.contains { $0.label == nil }
                    || Set(links.compactMap(\.label?.id)) != selected
                    || bookmark.primaryLabelId != readerPrimaryLabelID(
                        explicit: primaryLabelID,
                        selectedLabelIDs: selectedLabelIDs
                    )
            case .bookmarkList:
                return links.count != selected.count
                    || Set(links.compactMap(\.label?.id)) != selected
                    || links.contains {
                        $0.orderNumber != -1 || $0.indentLevel != 0 || !$0.expandContent
                    }
            case .workspace:
                return false
            }
        }
        return bibleChanged || genericChanged || favouriteValues.contains {
            labelsByID[$0.key]?.favourite != $0.value
        }
    }

    /** Applies only changed bookmark-category fields without changing Android's bookmark date. */
    private static func applyBookmarkMutation(
        bibleBookmarks: [BibleBookmark],
        genericBookmarks: [GenericBookmark],
        selectedLabelIDs: [UUID],
        primaryLabelID: UUID?,
        favouriteValues: [UUID: Bool],
        labelsByID: [UUID: Label],
        intent: BookmarkLabelAssignmentIntent,
        readerPlan: ReaderMutationPlan,
        context: ModelContext
    ) throws {
        switch intent {
        case .reader:
            for bookmark in bibleBookmarks {
                try replaceReaderLabels(
                    on: bookmark,
                    with: selectedLabelIDs,
                    labelsByID: labelsByID,
                    explicitPrimaryLabelID: primaryLabelID,
                    insertions: readerPlan.bibleInsertions[ObjectIdentifier(bookmark)] ?? [:],
                    context: context
                )
            }
            for bookmark in genericBookmarks {
                try replaceReaderLabels(
                    on: bookmark,
                    with: selectedLabelIDs,
                    labelsByID: labelsByID,
                    explicitPrimaryLabelID: primaryLabelID,
                    insertions: readerPlan.genericInsertions[ObjectIdentifier(bookmark)] ?? [:],
                    context: context
                )
            }
        case .bookmarkList:
            for bookmark in bibleBookmarks {
                replaceBookmarkListLabels(
                    on: bookmark,
                    with: selectedLabelIDs,
                    labelsByID: labelsByID,
                    context: context
                )
            }
            for bookmark in genericBookmarks {
                replaceBookmarkListLabels(
                    on: bookmark,
                    with: selectedLabelIDs,
                    labelsByID: labelsByID,
                    context: context
                )
            }
        case .workspace:
            break
        }
        for (labelID, value) in favouriteValues where labelsByID[labelID]?.favourite != value {
            labelsByID[labelID]?.favourite = value
        }
        context.processPendingChanges()
    }

    /** Produces the exact normalized workspace assignment fields written by this operation. */
    private static func desiredWorkspaceSettings(
        current: WorkspaceSettings?,
        autoAssignLabelIDs: Set<UUID>,
        autoAssignPrimaryLabelID: UUID?,
        labelsByID: [UUID: Label]
    ) -> WorkspaceSettings {
        var settings = current ?? WorkspaceSettings()
        settings.autoAssignLabels = autoAssignLabelIDs
            .filter { $0 != Label.unlabeledId && labelsByID[$0] != nil }
            .reduce(into: Set<UUID>()) { $0.insert($1) }
        settings.autoAssignPrimaryLabel = autoAssignPrimaryLabelID
        settings.normalizeAutoAssignPrimaryLabel()
        return settings
    }

    /** Compares submitted fields plus reader-owned cursor and recent-label effects. */
    private static func workspaceAssignmentEquals(
        _ current: WorkspaceSettings?,
        _ desired: WorkspaceSettings
    ) -> Bool {
        let current = current ?? WorkspaceSettings()
        return current.autoAssignLabels == desired.autoAssignLabels
            && current.autoAssignPrimaryLabel == desired.autoAssignPrimaryLabel
            && current.studyPadCursors == desired.studyPadCursors
            && recentLabelsEqual(current.recentLabels, desired.recentLabels)
    }

    /** Compares persisted recent-label identity, order, and access timestamps. */
    private static func recentLabelsEqual(_ lhs: [RecentLabel], _ rhs: [RecentLabel]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { pair in
            pair.0.labelId == pair.1.labelId && pair.0.lastAccess == pair.1.lastAccess
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

    /** Applies Android reader differential membership and explicit primary to a Bible bookmark. */
    private static func replaceReaderLabels(
        on bookmark: BibleBookmark,
        with selectedLabelIDs: [UUID],
        labelsByID: [UUID: Label],
        explicitPrimaryLabelID: UUID?,
        insertions: [UUID: ReaderInsertion],
        context: ModelContext
    ) throws {
        let existingLinks = bookmark.bookmarkToLabels ?? []
        let existingByLabelID = Dictionary(
            existingLinks.compactMap { link in link.label.map { ($0.id, link) } },
            uniquingKeysWith: { first, _ in first }
        )
        let selectedSet = Set(selectedLabelIDs)
        let desiredPrimary = readerPrimaryLabelID(
            explicit: explicitPrimaryLabelID,
            selectedLabelIDs: selectedLabelIDs
        )
        guard existingLinks.contains(where: { $0.label == nil })
            || Set(existingByLabelID.keys) != selectedSet
            || bookmark.primaryLabelId != desiredPrimary else { return }
        for link in existingLinks where link.label.map({ !selectedSet.contains($0.id) }) ?? true {
            bookmark.bookmarkToLabels?.removeAll { $0 === link }
            context.delete(link)
        }
        for labelID in selectedLabelIDs where existingByLabelID[labelID] == nil {
            guard let label = labelsByID[labelID], let insertion = insertions[labelID] else { continue }
            if insertion.shiftsExistingRows {
                try incrementStudyPadOrder(
                    for: label.id,
                    from: insertion.orderNumber,
                    in: context
                )
            }
            let link = BibleBookmarkToLabel(orderNumber: insertion.orderNumber)
            link.bookmark = bookmark
            link.label = label
            context.insert(link)
        }
        bookmark.primaryLabelId = desiredPrimary
    }

    /** Applies Android reader differential membership and explicit primary to a generic bookmark. */
    private static func replaceReaderLabels(
        on bookmark: GenericBookmark,
        with selectedLabelIDs: [UUID],
        labelsByID: [UUID: Label],
        explicitPrimaryLabelID: UUID?,
        insertions: [UUID: ReaderInsertion],
        context: ModelContext
    ) throws {
        let existingLinks = bookmark.bookmarkToLabels ?? []
        let existingByLabelID = Dictionary(
            existingLinks.compactMap { link in link.label.map { ($0.id, link) } },
            uniquingKeysWith: { first, _ in first }
        )
        let selectedSet = Set(selectedLabelIDs)
        let desiredPrimary = readerPrimaryLabelID(
            explicit: explicitPrimaryLabelID,
            selectedLabelIDs: selectedLabelIDs
        )
        guard existingLinks.contains(where: { $0.label == nil })
            || Set(existingByLabelID.keys) != selectedSet
            || bookmark.primaryLabelId != desiredPrimary else { return }
        for link in existingLinks where link.label.map({ !selectedSet.contains($0.id) }) ?? true {
            bookmark.bookmarkToLabels?.removeAll { $0 === link }
            context.delete(link)
        }
        for labelID in selectedLabelIDs where existingByLabelID[labelID] == nil {
            guard let label = labelsByID[labelID], let insertion = insertions[labelID] else { continue }
            if insertion.shiftsExistingRows {
                try incrementStudyPadOrder(
                    for: label.id,
                    from: insertion.orderNumber,
                    in: context
                )
            }
            let link = GenericBookmarkToLabel(orderNumber: insertion.orderNumber)
            link.bookmark = bookmark
            link.label = label
            context.insert(link)
        }
        bookmark.primaryLabelId = desiredPrimary
    }

    /** Applies bookmark-list clear/reinsert end state while leaving the Bible primary untouched. */
    private static func replaceBookmarkListLabels(
        on bookmark: BibleBookmark,
        with selectedLabelIDs: [UUID],
        labelsByID: [UUID: Label],
        context: ModelContext
    ) {
        let existingLinks = bookmark.bookmarkToLabels ?? []
        let selected = Set(selectedLabelIDs)
        guard existingLinks.count != selected.count
            || Set(existingLinks.compactMap(\.label?.id)) != selected
            || existingLinks.contains(where: {
                $0.orderNumber != -1 || $0.indentLevel != 0 || !$0.expandContent
            }) else { return }
        for link in existingLinks {
            bookmark.bookmarkToLabels?.removeAll { $0 === link }
            context.delete(link)
        }
        for labelID in selectedLabelIDs {
            guard let label = labelsByID[labelID] else { continue }
            let link = BibleBookmarkToLabel()
            link.bookmark = bookmark
            link.label = label
            context.insert(link)
        }
    }

    /** Applies bookmark-list clear/reinsert end state while leaving the generic primary untouched. */
    private static func replaceBookmarkListLabels(
        on bookmark: GenericBookmark,
        with selectedLabelIDs: [UUID],
        labelsByID: [UUID: Label],
        context: ModelContext
    ) {
        let existingLinks = bookmark.bookmarkToLabels ?? []
        let selected = Set(selectedLabelIDs)
        guard existingLinks.count != selected.count
            || Set(existingLinks.compactMap(\.label?.id)) != selected
            || existingLinks.contains(where: {
                $0.orderNumber != -1 || $0.indentLevel != 0 || !$0.expandContent
            }) else { return }
        for link in existingLinks {
            bookmark.bookmarkToLabels?.removeAll { $0 === link }
            context.delete(link)
        }
        for labelID in selectedLabelIDs {
            guard let label = labelsByID[labelID] else { continue }
            let link = GenericBookmarkToLabel()
            link.bookmark = bookmark
            link.label = label
            context.insert(link)
        }
    }

    /** Fetches one affected label's suffix and shifts only trusted Bible plus generic/text rows. */
    private static func incrementStudyPadOrder(
        for labelID: UUID,
        from orderNumber: Int,
        in context: ModelContext
    ) throws {
        let bibleRows = try context.fetch(FetchDescriptor<BibleBookmarkToLabel>(
            predicate: #Predicate {
                $0.label?.id == labelID && $0.orderNumber >= orderNumber
            }
        ))
        let genericRows = try context.fetch(FetchDescriptor<GenericBookmarkToLabel>(
            predicate: #Predicate {
                $0.label?.id == labelID && $0.orderNumber >= orderNumber
            }
        ))
        let textRows = try context.fetch(FetchDescriptor<StudyPadTextEntry>(
            predicate: #Predicate {
                $0.label?.id == labelID && $0.orderNumber >= orderNumber
            }
        ))
        bibleRows
            .filter { $0.bookmark?.hasTrustedPersistedOrdinals == true }
            .forEach { $0.orderNumber += 1 }
        genericRows.forEach { $0.orderNumber += 1 }
        textRows.forEach { $0.orderNumber += 1 }
    }

    /** Applies Android reader's explicit primary, falling back to the first selected label. */
    private static func readerPrimaryLabelID(
        explicit: UUID?,
        selectedLabelIDs: [UUID]
    ) -> UUID? {
        if let explicit, selectedLabelIDs.contains(explicit) { return explicit }
        return selectedLabelIDs.first
    }
}
