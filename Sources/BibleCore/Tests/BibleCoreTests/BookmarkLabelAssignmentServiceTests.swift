import SwiftData
import XCTest
@testable import BibleCore

/**
 Adversarial coverage for Android `ManageLabels.Mode.ASSIGN` at its canonical service boundary.

 These tests deliberately mix Bible and generic bookmarks, retain Study Pad junction metadata,
 exercise a workspace transaction, and inject stale route identities. A presentation smoke test
 cannot substitute for these contracts because the visible checkboxes may look correct while only
 one bookmark table, one persistence category, or part of the requested generation was saved.
 */
final class BookmarkLabelAssignmentServiceTests: XCTestCase {
    /**
     Verifies Android's multi-bookmark route starts from the union of both bookmark tables.

     Setup: one Bible bookmark carries First and one generic bookmark carries Second.

     Expected result: the mixed snapshot resolves two bookmarks and returns both label identities;
     a single-bookmark snapshot also returns its persisted primary label.

     Failure meaning: multi-select Assignment can erase labels that were present only on another
     selected row or can lose the reader's primary-label selection.
     */
    func testSnapshotUnionsBibleAndGenericAssignmentsAndRetainsSinglePrimary() throws {
        let fixture = try makeFixture(includesWorkspace: false)
        let first = Label(name: "First")
        let second = Label(name: "Second")
        let bible = trustedBibleBookmark(id: UUID())
        let generic = GenericBookmark(id: UUID(), key: "Entry", bookInitials: "DICT")
        fixture.context.insert(first)
        fixture.context.insert(second)
        fixture.context.insert(bible)
        fixture.context.insert(generic)
        attach(first, to: bible, order: 4, context: fixture.context)
        attach(second, to: generic, order: 8, context: fixture.context)
        bible.primaryLabelId = first.id
        generic.primaryLabelId = second.id
        try fixture.context.save()

        let service = WorkspaceLabelConfigurationService(modelContext: fixture.context)
        let mixed = try service.bookmarkLabelAssignmentSnapshot(
            bookmarkIDs: [bible.id, generic.id],
            workspaceID: nil
        )
        XCTAssertEqual(mixed.bookmarkCount, 2)
        XCTAssertEqual(mixed.selectedLabelIDs, [first.id, second.id])
        XCTAssertNil(mixed.primaryLabelID)

        let single = try service.bookmarkLabelAssignmentSnapshot(
            bookmarkIDs: [bible.id],
            workspaceID: nil
        )
        XCTAssertEqual(single.selectedLabelIDs, [first.id])
        XCTAssertEqual(single.primaryLabelID, first.id)
    }

    /**
     Verifies exact-set replacement covers both tables without destroying retained junction state.

     Setup: Bible retains First with non-default Study Pad metadata; generic starts with Second.
     Assignment selects First and Third for both and explicitly makes Third primary.

     Expected result: both bookmarks have exactly First/Third, Third is primary, the retained Bible
     link keeps its order/indent/expansion values, new links use Android's `-1` order, and the
     favourite edit commits with the same generation.

     Failure meaning: Assignment is a UI loop over eager saves, resets Study Pad layout, updates only
     one bookmark table, or publishes only part of the visible draft.
     */
    func testCommitReplacesMixedBookmarkLabelsExactlyAndPreservesRetainedMetadata() throws {
        let fixture = try makeFixture(includesWorkspace: false)
        let first = Label(name: "First")
        let second = Label(name: "Second")
        let third = Label(name: "Third")
        let bible = trustedBibleBookmark(id: UUID())
        let generic = GenericBookmark(id: UUID(), key: "Entry", bookInitials: "DICT")
        [first, second, third].forEach(fixture.context.insert)
        fixture.context.insert(bible)
        fixture.context.insert(generic)
        attach(first, to: bible, order: 7, indent: 3, expanded: false, context: fixture.context)
        attach(second, to: generic, order: 9, context: fixture.context)
        bible.primaryLabelId = first.id
        generic.primaryLabelId = second.id
        try fixture.context.save()

        try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .commitBookmarkLabelAssignment(
                bookmarkIDs: [bible.id, generic.id],
                orderedSelectedLabelIDs: [first.id, third.id],
                primaryLabelID: third.id,
                favouriteValues: [third.id: true],
                autoAssignLabelIDs: [],
                autoAssignPrimaryLabelID: nil,
                workspaceID: nil
            )

        let verification = ModelContext(fixture.context.container)
        let savedBible = try XCTUnwrap(try fetchBible(bible.id, in: verification))
        let savedGeneric = try XCTUnwrap(try fetchGeneric(generic.id, in: verification))
        XCTAssertEqual(Set(savedBible.bookmarkToLabels?.compactMap(\.label?.id) ?? []), [first.id, third.id])
        XCTAssertEqual(Set(savedGeneric.bookmarkToLabels?.compactMap(\.label?.id) ?? []), [first.id, third.id])
        XCTAssertEqual(savedBible.primaryLabelId, third.id)
        XCTAssertEqual(savedGeneric.primaryLabelId, third.id)

        let retained = try XCTUnwrap(savedBible.bookmarkToLabels?.first { $0.label?.id == first.id })
        XCTAssertEqual(retained.orderNumber, 7)
        XCTAssertEqual(retained.indentLevel, 3)
        XCTAssertFalse(retained.expandContent)
        XCTAssertEqual(savedBible.bookmarkToLabels?.first { $0.label?.id == third.id }?.orderNumber, -1)
        XCTAssertEqual(savedGeneric.bookmarkToLabels?.first { $0.label?.id == third.id }?.orderNumber, -1)
        XCTAssertTrue(try XCTUnwrap(try fetchLabel(third.id, in: verification)).favourite)
    }

    /**
     Verifies stale route validation happens before any assignment mutation is staged.

     Setup: one valid Bible bookmark has First; the request also contains a missing bookmark and
     asks to replace First with Second while favouriting Second.

     Expected result: the typed missing-bookmark error is thrown and a new verification context
     still sees First, the original primary, and an unchanged favourite value.

     Failure meaning: a partially saved generation can escape when one selected row is deleted by
     sync or another window while Assignment is open.
     */
    func testCommitWithMissingBookmarkRollsBackBeforeAnyVisibleDraftChange() throws {
        let fixture = try makeFixture(includesWorkspace: false)
        let first = Label(name: "First")
        let second = Label(name: "Second")
        let bible = trustedBibleBookmark(id: UUID())
        fixture.context.insert(first)
        fixture.context.insert(second)
        fixture.context.insert(bible)
        attach(first, to: bible, order: 2, context: fixture.context)
        bible.primaryLabelId = first.id
        try fixture.context.save()
        let missingID = UUID()

        XCTAssertThrowsError(
            try WorkspaceLabelConfigurationService(modelContext: fixture.context)
                .commitBookmarkLabelAssignment(
                    bookmarkIDs: [bible.id, missingID],
                    orderedSelectedLabelIDs: [second.id],
                    primaryLabelID: second.id,
                    favouriteValues: [second.id: true],
                    autoAssignLabelIDs: [],
                    autoAssignPrimaryLabelID: nil,
                    workspaceID: nil
                )
        ) { error in
            XCTAssertEqual(error as? BookmarkLabelAssignmentError, .missingBookmarks([missingID]))
        }

        let verification = ModelContext(fixture.context.container)
        let saved = try XCTUnwrap(try fetchBible(bible.id, in: verification))
        XCTAssertEqual(saved.bookmarkToLabels?.compactMap(\.label?.id), [first.id])
        XCTAssertEqual(saved.primaryLabelId, first.id)
        XCTAssertFalse(try XCTUnwrap(try fetchLabel(second.id, in: verification)).favourite)
    }

    /**
     Verifies bookmark, favourite, workspace auto-assignment, and both journals commit together.

     Setup: a production-shaped container has one workspace, Bible bookmark, and two labels.

     Expected result: the exact relationship and favourite change are persisted, workspace
     auto-assignment/primary are normalized to Second, recent ordering loads in the snapshot, and
     both bookmark/workspace remote-sync journals contain mutations.

     Failure meaning: the app can show Android parity while workspace behavior or remote sync still
     observes an older generation.
     */
    func testWorkspaceCommitPublishesOneCrossCategoryGenerationAndBothJournals() throws {
        let fixture = try makeFixture(includesWorkspace: true)
        let workspace = try XCTUnwrap(fixture.workspace)
        let first = Label(name: "First")
        let second = Label(name: "Second")
        let bible = trustedBibleBookmark(id: UUID())
        fixture.context.insert(first)
        fixture.context.insert(second)
        fixture.context.insert(bible)
        attach(first, to: bible, order: 0, context: fixture.context)
        bible.primaryLabelId = first.id
        workspace.workspaceSettings = WorkspaceSettings(
            recentLabels: [RecentLabel(labelId: second.id)],
            autoAssignLabels: [first.id],
            autoAssignPrimaryLabel: first.id
        )
        try fixture.context.save()

        let service = WorkspaceLabelConfigurationService(modelContext: fixture.context)
        let before = try service.bookmarkLabelAssignmentSnapshot(
            bookmarkIDs: [bible.id],
            workspaceID: workspace.id
        )
        XCTAssertEqual(before.recentLabelIDs, [second.id])
        XCTAssertEqual(before.autoAssignLabelIDs, [first.id])

        try service.commitBookmarkLabelAssignment(
            bookmarkIDs: [bible.id],
            orderedSelectedLabelIDs: [second.id],
            primaryLabelID: second.id,
            favouriteValues: [second.id: true],
            autoAssignLabelIDs: [second.id],
            autoAssignPrimaryLabelID: second.id,
            workspaceID: workspace.id
        )

        let verification = ModelContext(fixture.context.container)
        let savedBookmark = try XCTUnwrap(try fetchBible(bible.id, in: verification))
        let savedWorkspace = try XCTUnwrap(try verification.fetch(FetchDescriptor<Workspace>())
            .first { $0.id == workspace.id })
        XCTAssertEqual(savedBookmark.bookmarkToLabels?.compactMap(\.label?.id), [second.id])
        XCTAssertEqual(savedBookmark.primaryLabelId, second.id)
        XCTAssertTrue(try XCTUnwrap(try fetchLabel(second.id, in: verification)).favourite)
        XCTAssertEqual(savedWorkspace.workspaceSettings?.autoAssignLabels, [second.id])
        XCTAssertEqual(savedWorkspace.workspaceSettings?.autoAssignPrimaryLabel, second.id)

        let settingsStore = SettingsStore(modelContext: verification)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertFalse(try journal.pendingMutations(for: .bookmarks, settingsStore: settingsStore).isEmpty)
        XCTAssertFalse(try journal.pendingMutations(for: .workspaces, settingsStore: settingsStore).isEmpty)
    }

    /**
     Verifies WORKSPACE mode can commit without inventing a bookmark assignment.

     Setup: one workspace auto-assigns First and both labels are favourites.

     Expected result: an empty-bookmark generation clears auto-assignment, primary, and both
     favourite values while publishing bookmark/workspace journals.

     Failure meaning: the app-owned Workspace Manage Labels route either needs a fake bookmark,
     silently skips reset, or commits only one persistence category.
     */
    func testWorkspaceOnlyCommitSupportsResetWithoutSyntheticBookmark() throws {
        let fixture = try makeFixture(includesWorkspace: true)
        let workspace = try XCTUnwrap(fixture.workspace)
        let first = Label(name: "First", favourite: true)
        let second = Label(name: "Second", favourite: true)
        fixture.context.insert(first)
        fixture.context.insert(second)
        workspace.workspaceSettings = WorkspaceSettings(
            autoAssignLabels: [first.id],
            autoAssignPrimaryLabel: first.id
        )
        try fixture.context.save()

        try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .commitBookmarkLabelAssignment(
                bookmarkIDs: [],
                orderedSelectedLabelIDs: [],
                primaryLabelID: nil,
                favouriteValues: [first.id: false, second.id: false],
                autoAssignLabelIDs: [],
                autoAssignPrimaryLabelID: nil,
                workspaceID: workspace.id
            )

        let verification = ModelContext(fixture.context.container)
        let savedWorkspace = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<Workspace>()).first { $0.id == workspace.id }
        )
        XCTAssertEqual(savedWorkspace.workspaceSettings?.autoAssignLabels, [])
        XCTAssertNil(savedWorkspace.workspaceSettings?.autoAssignPrimaryLabel)
        XCTAssertFalse(try XCTUnwrap(try fetchLabel(first.id, in: verification)).favourite)
        XCTAssertFalse(try XCTUnwrap(try fetchLabel(second.id, in: verification)).favourite)

        let settingsStore = SettingsStore(modelContext: verification)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertFalse(try journal.pendingMutations(for: .bookmarks, settingsStore: settingsStore).isEmpty)
        XCTAssertFalse(try journal.pendingMutations(for: .workspaces, settingsStore: settingsStore).isEmpty)
    }

    /// In-memory schema and optional workspace used by one test.
    private struct Fixture {
        let context: ModelContext
        let workspace: Workspace?
    }

    /** Creates either the minimal bookmark graph or the production-shaped workspace graph. */
    private func makeFixture(includesWorkspace: Bool) throws -> Fixture {
        var models: [any PersistentModel.Type] = [
            BibleBookmark.self,
            BibleBookmarkNotes.self,
            BibleBookmarkToLabel.self,
            GenericBookmark.self,
            GenericBookmarkNotes.self,
            GenericBookmarkToLabel.self,
            Label.self,
            StudyPadTextEntry.self,
            StudyPadTextEntryText.self,
        ]
        if includesWorkspace {
            models += [
                Workspace.self,
                Window.self,
                PageManager.self,
                HistoryItem.self,
                Setting.self,
            ]
        }
        let schema = Schema(models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
        let workspace = includesWorkspace ? Workspace(name: "Workspace") : nil
        if let workspace {
            workspace.workspaceSettings = WorkspaceSettings()
            context.insert(workspace)
        }
        try context.save()
        return Fixture(context: context, workspace: workspace)
    }

    /** Creates a Bible bookmark whose KJVA provenance passes production trust filtering. */
    private func trustedBibleBookmark(id: UUID) -> BibleBookmark {
        BibleBookmark(
            id: id,
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            ordinalStart: 4,
            ordinalEnd: 4,
            v11n: "KJV",
            createdAt: Date(timeIntervalSince1970: 1),
            lastUpdatedOn: Date(timeIntervalSince1970: 1),
            ordinalTrustMetadata: PersistedOrdinalTrustPolicy.androidImportMetadata(
                sourceVersification: "KJV",
                sourceOrdinalStart: 4,
                sourceOrdinalEnd: 4,
                kjvaOrdinalStart: 4,
                kjvaOrdinalEnd: 4
            )
        )
    }

    /** Inserts one Bible junction with explicit Study Pad metadata. */
    private func attach(
        _ label: Label,
        to bookmark: BibleBookmark,
        order: Int,
        indent: Int = 0,
        expanded: Bool = true,
        context: ModelContext
    ) {
        let link = BibleBookmarkToLabel(
            orderNumber: order,
            indentLevel: indent,
            expandContent: expanded
        )
        link.bookmark = bookmark
        link.label = label
        context.insert(link)
    }

    /** Inserts one generic-bookmark junction with explicit Study Pad metadata. */
    private func attach(
        _ label: Label,
        to bookmark: GenericBookmark,
        order: Int,
        indent: Int = 0,
        expanded: Bool = true,
        context: ModelContext
    ) {
        let link = GenericBookmarkToLabel(
            orderNumber: order,
            indentLevel: indent,
            expandContent: expanded
        )
        link.bookmark = bookmark
        link.label = label
        context.insert(link)
    }

    /** Fetches one Bible bookmark from a fresh verification context. */
    private func fetchBible(_ id: UUID, in context: ModelContext) throws -> BibleBookmark? {
        try context.fetch(FetchDescriptor<BibleBookmark>()).first { $0.id == id }
    }

    /** Fetches one generic bookmark from a fresh verification context. */
    private func fetchGeneric(_ id: UUID, in context: ModelContext) throws -> GenericBookmark? {
        try context.fetch(FetchDescriptor<GenericBookmark>()).first { $0.id == id }
    }

    /** Fetches one label from a fresh verification context. */
    private func fetchLabel(_ id: UUID, in context: ModelContext) throws -> Label? {
        try context.fetch(FetchDescriptor<Label>()).first { $0.id == id }
    }
}
