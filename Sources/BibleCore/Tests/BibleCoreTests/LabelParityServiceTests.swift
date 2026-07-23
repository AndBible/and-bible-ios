import SwiftData
import XCTest
@testable import BibleCore

/**
 Exercises Android label deletion semantics at the canonical BibleCore service boundary.

 The tests intentionally mix Bible and generic bookmarks and include a multi-label bookmark. This
 prevents a UI-only implementation from claiming parity while deleting too much, retaining orphan
 rows, or calculating the confirmation count from only one bookmark table.
 */
final class BookmarkLabelDeletionParityTests: XCTestCase {
    /**
     Verifies the preview and destructive choice delete exactly the bookmarks Android calls orphaned.

     - Side effects: Creates labels, Bible/generic bookmarks, and junction rows in memory, then
       deletes the target label with orphan removal enabled.
     - Failure modes: Fails if the preview omits either bookmark category, if a shared bookmark is
       classified as orphaned, or if deletion retains orphan rows/deletes the shared row.
     */
    func testDeleteLabelWithOrphansRemovesOnlyBookmarksWithoutAnotherLiveLabel() throws {
        let fixture = try makeDeletionFixture()

        let impact = try XCTUnwrap(fixture.service.labelDeletionImpact(id: fixture.targetLabelID))
        XCTAssertEqual(impact.bibleBookmarkIDs, [fixture.orphanBibleID])
        XCTAssertEqual(impact.genericBookmarkIDs, [fixture.orphanGenericID])
        XCTAssertEqual(impact.orphanedBookmarkCount, 2)

        let appliedImpact = try XCTUnwrap(
            fixture.service.deleteLabel(
                id: fixture.targetLabelID,
                deleteOrphanedBookmarks: true
            )
        )
        XCTAssertEqual(appliedImpact, impact)
        XCTAssertNil(fixture.store.label(id: fixture.targetLabelID))
        XCTAssertNil(fixture.store.bibleBookmark(id: fixture.orphanBibleID))
        XCTAssertNil(fixture.store.genericBookmark(id: fixture.orphanGenericID))

        let shared = try XCTUnwrap(fixture.store.bibleBookmark(id: fixture.sharedBibleID))
        XCTAssertEqual(shared.bookmarkToLabels?.compactMap(\.label?.id), [fixture.retainedLabelID])
        XCTAssertEqual(shared.primaryLabelId, fixture.retainedLabelID)
    }

    /**
     Verifies Android's label-only choice detaches the target without deleting orphaned bookmarks.

     - Side effects: Creates a fresh mixed bookmark fixture and deletes only its target label.
     - Failure modes: Fails if either orphan bookmark is removed, if target junctions survive, or if
       the retained bookmark's other label/primary identity is damaged.
     */
    func testDeleteLabelOnlyRetainsBookmarksAndDetachesTargetRelationships() throws {
        let fixture = try makeDeletionFixture()

        _ = fixture.service.deleteLabel(
            id: fixture.targetLabelID,
            deleteOrphanedBookmarks: false
        )

        let bible = try XCTUnwrap(fixture.store.bibleBookmark(id: fixture.orphanBibleID))
        XCTAssertTrue(bible.bookmarkToLabels?.isEmpty ?? true)
        XCTAssertNil(bible.primaryLabelId)

        let generic = try XCTUnwrap(fixture.store.genericBookmark(id: fixture.orphanGenericID))
        XCTAssertTrue(generic.bookmarkToLabels?.isEmpty ?? true)
        XCTAssertNil(generic.primaryLabelId)

        let shared = try XCTUnwrap(fixture.store.bibleBookmark(id: fixture.sharedBibleID))
        XCTAssertEqual(shared.bookmarkToLabels?.compactMap(\.label?.id), [fixture.retainedLabelID])
        XCTAssertEqual(shared.primaryLabelId, fixture.retainedLabelID)
    }

    /// Complete test graph and service handles for one deletion scenario.
    private struct DeletionFixture {
        let store: BookmarkStore
        let service: BookmarkService
        let targetLabelID: UUID
        let retainedLabelID: UUID
        let orphanBibleID: UUID
        let orphanGenericID: UUID
        let sharedBibleID: UUID
    }

    /** Creates a persisted target label with Bible, generic, and shared bookmark relationships. */
    private func makeDeletionFixture() throws -> DeletionFixture {
        let container = try makeBookmarkRestoreModelContainer()
        let context = ModelContext(container)
        let store = BookmarkStore(modelContext: context)
        let service = BookmarkService(store: store)
        let target = Label(name: "Target")
        let retained = Label(name: "Retained")

        let orphanBible = BibleBookmark(
            kjvOrdinalStart: 1,
            kjvOrdinalEnd: 1,
            ordinalStart: 1,
            ordinalEnd: 1,
            v11n: "KJVA",
            bookInitials: "KJVA",
            ordinalTrustMetadata: trustedAndroidMetadata(sourceOrdinal: 1, kjvaOrdinal: 1)
        )
        orphanBible.primaryLabelId = target.id
        attach(target, to: orphanBible, order: 0, context: context)

        let orphanGeneric = GenericBookmark(key: "orphan", bookInitials: "DICT")
        orphanGeneric.primaryLabelId = target.id
        attach(target, to: orphanGeneric, order: 1, context: context)

        let sharedBible = BibleBookmark(
            kjvOrdinalStart: 2,
            kjvOrdinalEnd: 2,
            ordinalStart: 2,
            ordinalEnd: 2,
            v11n: "KJVA",
            bookInitials: "KJVA",
            ordinalTrustMetadata: trustedAndroidMetadata(sourceOrdinal: 2, kjvaOrdinal: 2)
        )
        sharedBible.primaryLabelId = retained.id
        attach(target, to: sharedBible, order: 2, context: context)
        attach(retained, to: sharedBible, order: 3, context: context)

        context.insert(target)
        context.insert(retained)
        context.insert(orphanBible)
        context.insert(orphanGeneric)
        context.insert(sharedBible)
        try context.save()

        return DeletionFixture(
            store: store,
            service: service,
            targetLabelID: target.id,
            retainedLabelID: retained.id,
            orphanBibleID: orphanBible.id,
            orphanGenericID: orphanGeneric.id,
            sharedBibleID: sharedBible.id
        )
    }

    /** Attaches one label to a Bible bookmark and stages the explicit junction row. */
    private func attach(
        _ label: Label,
        to bookmark: BibleBookmark,
        order: Int,
        context: ModelContext
    ) {
        let link = BibleBookmarkToLabel(orderNumber: order)
        link.bookmark = bookmark
        link.label = label
        bookmark.bookmarkToLabels = (bookmark.bookmarkToLabels ?? []) + [link]
        context.insert(link)
    }

    /** Attaches one label to a generic bookmark and stages the explicit junction row. */
    private func attach(
        _ label: Label,
        to bookmark: GenericBookmark,
        order: Int,
        context: ModelContext
    ) {
        let link = GenericBookmarkToLabel(orderNumber: order)
        link.bookmark = bookmark
        link.label = label
        bookmark.bookmarkToLabels = (bookmark.bookmarkToLabels ?? []) + [link]
        context.insert(link)
    }

    /** Creates explicit validated Android ordinal provenance for one Bible fixture row. */
    private func trustedAndroidMetadata(
        sourceOrdinal: Int,
        kjvaOrdinal: Int
    ) -> PersistedOrdinalTrustMetadata {
        PersistedOrdinalTrustPolicy.androidImportMetadata(
            sourceVersification: "KJVA",
            sourceOrdinalStart: sourceOrdinal,
            sourceOrdinalEnd: sourceOrdinal,
            kjvaOrdinalStart: kjvaOrdinal,
            kjvaOrdinalEnd: kjvaOrdinal
        )
    }
}

/**
 Verifies the cross-category transaction used by Android's workspace-aware label editor.

 These tests pin the primary-label invariant, workspace override fidelity, rollback behavior, and
 both remote-sync journals so UI routes cannot persist only the visible label fields.
 */
final class WorkspaceLabelConfigurationServiceTests: XCTestCase {
    /**
     Verifies one editor commit persists label fields, workspace fields, override, and both journals.

     - Side effects: Inserts one workspace/label, then performs one cross-category mutation.
     - Failure modes: Fails if primary auto-assignment is left outside the assigned set, override
       fidelity is missing, or either bookmarks/workspaces mutation journal remains empty.
     */
    func testPersistLabelMutationCommitsCompleteWorkspaceConfigurationAndBothJournals() throws {
        let fixture = try makeWorkspaceLabelFixture()
        let service = WorkspaceLabelConfigurationService(modelContext: fixture.context)
        var values = LabelEditValues(label: fixture.label)
        values.name = "Edited"

        try service.updateLabel(
            id: fixture.label.id,
            values: values,
            workspaceID: fixture.workspace.id,
            configuration: WorkspaceLabelConfiguration(
                isAutoAssigned: false,
                isPrimaryAutoAssigned: true,
                overrideMode: 2
            )
        )

        let verificationContext = ModelContext(fixture.context.container)
        let label = try XCTUnwrap(try verificationContext.fetch(FetchDescriptor<Label>()).first)
        let workspace = try XCTUnwrap(try verificationContext.fetch(FetchDescriptor<Workspace>()).first)
        let verificationService = WorkspaceLabelConfigurationService(modelContext: verificationContext)
        XCTAssertEqual(label.name, "Edited")
        XCTAssertTrue(workspace.workspaceSettings?.autoAssignLabels.contains(label.id) == true)
        XCTAssertEqual(workspace.workspaceSettings?.autoAssignPrimaryLabel, label.id)
        XCTAssertEqual(verificationService.configuration(for: label.id, in: workspace).overrideMode, 2)

        let settingsStore = SettingsStore(modelContext: verificationContext)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertFalse(try journal.pendingMutations(for: .bookmarks, settingsStore: settingsStore).isEmpty)
        XCTAssertFalse(try journal.pendingMutations(for: .workspaces, settingsStore: settingsStore).isEmpty)
    }

    /**
     Verifies an error after staging mutations rolls back the label and workspace as one generation.

     - Side effects: Attempts a mutation that changes the label and workspace before throwing.
     - Failure modes: Fails if either label text, auto-assignment, primary identity, or override row
       survives the rejected transaction.
     */
    func testPersistLabelMutationRollsBackLabelAndWorkspaceWhenMutationThrows() throws {
        let fixture = try makeWorkspaceLabelFixture()
        let service = WorkspaceLabelConfigurationService(modelContext: fixture.context)
        let originalName = fixture.label.name
        let malformedKey = "remote_sync.pending_mutations.bookmarks.corrupt"
        SettingsStore(modelContext: fixture.context).setString(malformedKey, value: "{")
        var values = LabelEditValues(label: fixture.label)
        values.name = "Must roll back"

        XCTAssertThrowsError(
            try service.updateLabel(
                id: fixture.label.id,
                values: values,
                workspaceID: fixture.workspace.id,
                configuration: WorkspaceLabelConfiguration(
                    isAutoAssigned: true,
                    isPrimaryAutoAssigned: true,
                    overrideMode: 3
                )
            )
        )

        XCTAssertEqual(fixture.label.name, originalName)
        let verificationContext = ModelContext(fixture.context.container)
        let label = try XCTUnwrap(try verificationContext.fetch(FetchDescriptor<Label>()).first)
        let workspace = try XCTUnwrap(try verificationContext.fetch(FetchDescriptor<Workspace>()).first)
        let verificationService = WorkspaceLabelConfigurationService(modelContext: verificationContext)
        XCTAssertEqual(label.name, originalName)
        XCTAssertFalse(workspace.workspaceSettings?.autoAssignLabels.contains(label.id) == true)
        XCTAssertNil(workspace.workspaceSettings?.autoAssignPrimaryLabel)
        XCTAssertNil(verificationService.configuration(for: label.id, in: workspace).overrideMode)
    }

    /**
     Verifies invalid Android override values fail before the caller's label mutation executes.

     - Side effects: Attempts one invalid editor commit.
     - Failure modes: Fails if the mutation closure runs or if the error is not the typed validation
       error used by UI and tests.
     */
    func testPersistLabelMutationRejectsInvalidOverrideBeforeMutatingLabel() throws {
        let fixture = try makeWorkspaceLabelFixture()
        let service = WorkspaceLabelConfigurationService(modelContext: fixture.context)
        var values = LabelEditValues(label: fixture.label)
        values.name = "Invalid"

        XCTAssertThrowsError(
            try service.updateLabel(
                id: fixture.label.id,
                values: values,
                workspaceID: fixture.workspace.id,
                configuration: WorkspaceLabelConfiguration(overrideMode: 4)
            )
        ) { error in
            XCTAssertEqual(error as? WorkspaceLabelConfigurationError, .invalidOverrideMode(4))
        }
        XCTAssertEqual(fixture.label.name, "Original")
    }

    /**
     Verifies canonical deletion removes every workspace-owned reference and no unrelated state.

     - Side effects: Adds a second workspace, a retained label, recent/cursor references, and three
       override rows before deleting the target label.
     - Failure modes: Fails if any target reference survives, if the retained override is removed,
       if primary auto-assignment is not repaired, or if either sync category is not journaled.
     */
    func testDeleteLabelCleansAllWorkspaceReferencesAndPreservesUnrelatedOverrides() throws {
        let fixture = try makeWorkspaceLabelFixture()
        let retainedLabel = Label(name: "Retained")
        let secondWorkspace = Workspace(name: "Second")
        fixture.workspace.workspaceSettings = WorkspaceSettings(
            recentLabels: [
                RecentLabel(labelId: fixture.label.id),
                RecentLabel(labelId: retainedLabel.id),
            ],
            autoAssignLabels: [fixture.label.id, retainedLabel.id],
            autoAssignPrimaryLabel: fixture.label.id,
            studyPadCursors: [fixture.label.id: 7, retainedLabel.id: 4]
        )
        secondWorkspace.workspaceSettings = WorkspaceSettings(
            recentLabels: [RecentLabel(labelId: fixture.label.id)],
            autoAssignLabels: [fixture.label.id],
            autoAssignPrimaryLabel: fixture.label.id,
            studyPadCursors: [fixture.label.id: 3]
        )
        fixture.context.insert(retainedLabel)
        fixture.context.insert(secondWorkspace)
        try fixture.context.save()

        let fidelityStore = RemoteSyncWorkspaceFidelityStore(
            settingsStore: SettingsStore(modelContext: fixture.context)
        )
        try fidelityStore.setLabelOverride(RemoteSyncCurrentWorkspaceLabelOverrideRow(
            workspaceID: fixture.workspace.id,
            labelID: fixture.label.id,
            overrideMode: 1
        ))
        try fidelityStore.setLabelOverride(RemoteSyncCurrentWorkspaceLabelOverrideRow(
            workspaceID: secondWorkspace.id,
            labelID: fixture.label.id,
            overrideMode: 2
        ))
        try fidelityStore.setLabelOverride(RemoteSyncCurrentWorkspaceLabelOverrideRow(
            workspaceID: fixture.workspace.id,
            labelID: retainedLabel.id,
            overrideMode: 3
        ))

        let impact = try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .deleteLabel(id: fixture.label.id, deleteOrphanedBookmarks: false)
        XCTAssertEqual(impact.orphanedBookmarkCount, 0)

        let verificationContext = ModelContext(fixture.context.container)
        let labels = try verificationContext.fetch(FetchDescriptor<Label>())
        XCTAssertNil(labels.first { $0.id == fixture.label.id })
        XCTAssertNotNil(labels.first { $0.id == retainedLabel.id })

        let workspaces = try verificationContext.fetch(FetchDescriptor<Workspace>())
        let first = try XCTUnwrap(workspaces.first { $0.id == fixture.workspace.id })
        let second = try XCTUnwrap(workspaces.first { $0.id == secondWorkspace.id })
        XCTAssertEqual(first.workspaceSettings?.autoAssignLabels, Set([retainedLabel.id]))
        XCTAssertEqual(first.workspaceSettings?.autoAssignPrimaryLabel, retainedLabel.id)
        XCTAssertEqual(first.workspaceSettings?.recentLabels.map(\.labelId), [retainedLabel.id])
        XCTAssertNil(first.workspaceSettings?.studyPadCursors[fixture.label.id])
        XCTAssertEqual(first.workspaceSettings?.studyPadCursors[retainedLabel.id], 4)
        XCTAssertTrue(second.workspaceSettings?.autoAssignLabels.isEmpty == true)
        XCTAssertNil(second.workspaceSettings?.autoAssignPrimaryLabel)
        XCTAssertTrue(second.workspaceSettings?.recentLabels.isEmpty == true)
        XCTAssertNil(second.workspaceSettings?.studyPadCursors[fixture.label.id])

        let verificationFidelity = RemoteSyncWorkspaceFidelityStore(
            settingsStore: SettingsStore(modelContext: verificationContext)
        )
        XCTAssertNil(verificationFidelity.labelOverride(
            workspaceID: fixture.workspace.id,
            labelID: fixture.label.id
        ))
        XCTAssertNil(verificationFidelity.labelOverride(
            workspaceID: secondWorkspace.id,
            labelID: fixture.label.id
        ))
        XCTAssertEqual(
            verificationFidelity.labelOverride(
                workspaceID: fixture.workspace.id,
                labelID: retainedLabel.id
            )?.overrideMode,
            3
        )

        let settingsStore = SettingsStore(modelContext: verificationContext)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertFalse(try journal.pendingMutations(for: .bookmarks, settingsStore: settingsStore).isEmpty)
        XCTAssertFalse(try journal.pendingMutations(for: .workspaces, settingsStore: settingsStore).isEmpty)
    }

    /**
     Verifies a late journal failure rolls back label, workspace, and override deletion together.

     - Side effects: Seeds workspace references and an override, injects malformed pending bookmark
       journal state, then attempts canonical label deletion.
     - Failure modes: Fails if any staged deletion escapes rollback or mutates the caller's live
       label object despite the rejected isolated transaction.
     */
    func testDeleteLabelRollsBackEveryOwnerWhenBookmarkJournalFails() throws {
        let fixture = try makeWorkspaceLabelFixture()
        fixture.workspace.workspaceSettings = WorkspaceSettings(
            recentLabels: [RecentLabel(labelId: fixture.label.id)],
            autoAssignLabels: [fixture.label.id],
            autoAssignPrimaryLabel: fixture.label.id,
            studyPadCursors: [fixture.label.id: 9]
        )
        try fixture.context.save()
        let settingsStore = SettingsStore(modelContext: fixture.context)
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        try fidelityStore.setLabelOverride(RemoteSyncCurrentWorkspaceLabelOverrideRow(
            workspaceID: fixture.workspace.id,
            labelID: fixture.label.id,
            overrideMode: 2
        ))
        settingsStore.setString("remote_sync.pending_mutations.bookmarks.corrupt", value: "{")

        XCTAssertThrowsError(
            try WorkspaceLabelConfigurationService(modelContext: fixture.context)
                .deleteLabel(id: fixture.label.id, deleteOrphanedBookmarks: false)
        )
        XCTAssertFalse(fixture.label.isDeleted)

        let verificationContext = ModelContext(fixture.context.container)
        XCTAssertNotNil(try verificationContext.fetch(FetchDescriptor<Label>())
            .first { $0.id == fixture.label.id })
        let workspace = try XCTUnwrap(try verificationContext.fetch(FetchDescriptor<Workspace>())
            .first { $0.id == fixture.workspace.id })
        XCTAssertEqual(workspace.workspaceSettings?.autoAssignLabels, Set([fixture.label.id]))
        XCTAssertEqual(workspace.workspaceSettings?.autoAssignPrimaryLabel, fixture.label.id)
        XCTAssertEqual(workspace.workspaceSettings?.recentLabels.map(\.labelId), [fixture.label.id])
        XCTAssertEqual(workspace.workspaceSettings?.studyPadCursors[fixture.label.id], 9)
        XCTAssertEqual(
            RemoteSyncWorkspaceFidelityStore(
                settingsStore: SettingsStore(modelContext: verificationContext)
            ).labelOverride(
                workspaceID: fixture.workspace.id,
                labelID: fixture.label.id
            )?.overrideMode,
            2
        )
    }

    /// Complete graph needed by both strict bookmark and workspace journal projectors.
    private struct WorkspaceLabelFixture {
        let context: ModelContext
        let workspace: Workspace
        let label: Label
    }

    /** Creates and saves one production-shaped workspace and label graph. */
    private func makeWorkspaceLabelFixture() throws -> WorkspaceLabelFixture {
        let schema = Schema([
            BibleBookmark.self,
            BibleBookmarkNotes.self,
            BibleBookmarkToLabel.self,
            GenericBookmark.self,
            GenericBookmarkNotes.self,
            GenericBookmarkToLabel.self,
            Label.self,
            StudyPadTextEntry.self,
            StudyPadTextEntryText.self,
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
        let workspace = Workspace(name: "Workspace")
        workspace.workspaceSettings = WorkspaceSettings()
        let label = Label(name: "Original")
        context.insert(workspace)
        context.insert(label)
        try context.save()
        return WorkspaceLabelFixture(context: context, workspace: workspace, label: label)
    }
}
