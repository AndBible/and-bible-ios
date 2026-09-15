import SwiftData
import XCTest
@testable import BibleCore

/**
 Adversarial coverage for Android `ManageLabels.Mode.ASSIGN` at its canonical service boundary.

 These tests deliberately distinguish reader differential placement from bookmark-list junction
 recreation, mix Bible and generic bookmarks, exercise a workspace transaction, and inject stale
 route identities. A presentation smoke test
 cannot substitute for these contracts because the visible checkboxes may look correct while only
 one bookmark table, one persistence category, or part of the requested generation was saved.
 */
@MainActor
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
            workspaceID: nil,
            intent: .bookmarkList
        )
        XCTAssertEqual(mixed.bookmarkCount, 2)
        XCTAssertEqual(mixed.selectedLabelIDs, [first.id, second.id])
        XCTAssertNil(mixed.primaryLabelID)

        let single = try service.bookmarkLabelAssignmentSnapshot(
            bookmarkIDs: [bible.id],
            workspaceID: nil,
            intent: .reader
        )
        XCTAssertEqual(single.selectedLabelIDs, [first.id])
        XCTAssertEqual(single.primaryLabelID, first.id)
    }

    /**
     Verifies bookmark-list replacement covers both tables with Android's recreated junction state.

     Setup: Bible retains First with non-default Study Pad metadata; generic starts with Second.
     Assignment selects First and Third for both while the caller carries an irrelevant primary.

     Expected result: both bookmarks have exactly First/Third, every junction has Android's default
     StudyPad metadata, each pre-existing primary remains untouched, and the favourite edit commits
     with the same generation.

     Failure meaning: Assignment is a UI loop over eager saves, fails to reproduce default StudyPad
     metadata, updates only one bookmark table, changes list-route primaries, or publishes only part
     of the visible draft.
     */
    func testBookmarkListCommitRecreatesMixedLinksWithDefaultsAndPreservesPrimaries() throws {
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
        let originalBibleTimestamp = bible.lastUpdatedOn
        let originalGenericTimestamp = generic.lastUpdatedOn
        try fixture.context.save()

        try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .commitBookmarkLabelAssignment(
                bookmarkIDs: [bible.id, generic.id],
                orderedSelectedLabelIDs: [first.id, third.id],
                primaryLabelID: third.id,
                favouriteValues: [third.id: true],
                autoAssignLabelIDs: [],
                autoAssignPrimaryLabelID: nil,
                workspaceID: nil,
                intent: .bookmarkList
            )

        let verification = ModelContext(fixture.context.container)
        let savedBible = try XCTUnwrap(try fetchBible(bible.id, in: verification))
        let savedGeneric = try XCTUnwrap(try fetchGeneric(generic.id, in: verification))
        XCTAssertEqual(Set(savedBible.bookmarkToLabels?.compactMap(\.label?.id) ?? []), [first.id, third.id])
        XCTAssertEqual(Set(savedGeneric.bookmarkToLabels?.compactMap(\.label?.id) ?? []), [first.id, third.id])
        XCTAssertEqual(savedBible.primaryLabelId, first.id)
        XCTAssertEqual(savedGeneric.primaryLabelId, second.id)
        XCTAssertEqual(savedBible.lastUpdatedOn, originalBibleTimestamp)
        XCTAssertEqual(savedGeneric.lastUpdatedOn, originalGenericTimestamp)

        for link in savedBible.bookmarkToLabels ?? [] {
            XCTAssertEqual(link.orderNumber, -1)
            XCTAssertEqual(link.indentLevel, 0)
            XCTAssertTrue(link.expandContent)
        }
        for link in savedGeneric.bookmarkToLabels ?? [] {
            XCTAssertEqual(link.orderNumber, -1)
            XCTAssertEqual(link.indentLevel, 0)
            XCTAssertTrue(link.expandContent)
        }
        XCTAssertTrue(try XCTUnwrap(try fetchLabel(third.id, in: verification)).favourite)
    }

    /**
     Verifies unchanged list membership still resets Android-visible StudyPad junction metadata.

     Setup: one list bookmark already has the submitted label but its junction is ordered, indented,
     and collapsed. Expected: Apply writes Android's recreated-link defaults, preserves primary and
     date, journals bookmarks, and leaves the workspace journal empty. A failure incorrectly treats
     membership equality as complete bookmark-list semantic equality.
     */
    func testBookmarkListUnchangedMembershipResetsStudyPadMetadataAndJournals() throws {
        let fixture = try makeFixture(includesWorkspace: true)
        let workspace = try XCTUnwrap(fixture.workspace)
        let label = Label(name: "StudyPad")
        let bookmark = trustedBibleBookmark(id: UUID())
        fixture.context.insert(label)
        fixture.context.insert(bookmark)
        attach(
            label,
            to: bookmark,
            order: 8,
            indent: 2,
            expanded: false,
            context: fixture.context
        )
        bookmark.primaryLabelId = label.id
        let originalTimestamp = bookmark.lastUpdatedOn
        try fixture.context.save()

        try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .commitBookmarkLabelAssignment(
                bookmarkIDs: [bookmark.id],
                orderedSelectedLabelIDs: [label.id],
                primaryLabelID: nil,
                favouriteValues: [:],
                autoAssignLabelIDs: [],
                autoAssignPrimaryLabelID: nil,
                workspaceID: workspace.id,
                intent: .bookmarkList
            )

        let verification = ModelContext(fixture.context.container)
        let saved = try XCTUnwrap(try fetchBible(bookmark.id, in: verification))
        let link = try XCTUnwrap(saved.bookmarkToLabels?.first)
        XCTAssertEqual(link.orderNumber, -1)
        XCTAssertEqual(link.indentLevel, 0)
        XCTAssertTrue(link.expandContent)
        XCTAssertEqual(saved.primaryLabelId, label.id)
        XCTAssertEqual(saved.lastUpdatedOn, originalTimestamp)
        let settingsStore = SettingsStore(modelContext: verification)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertFalse(try journal.pendingMutations(for: .bookmarks, settingsStore: settingsStore).isEmpty)
        XCTAssertTrue(try journal.pendingMutations(for: .workspaces, settingsStore: settingsStore).isEmpty)
    }

    /**
     Verifies a list route whose links already have recreated defaults is a true semantic no-op.

     Setup: one bookmark has the selected label with default junction metadata and a persisted
     primary. The list caller submits a missing primary value, which Android ignores. Expected: no
     stale-identity error and no graph, timestamp, or journal changes. A failure either gives list assignment reader-primary
     semantics or pays the complete bookmark journal cost for an identical visible end state.
     */
    func testBookmarkListDefaultJunctionAndPrimaryInputAreSemanticNoOp() throws {
        let fixture = try makeFixture(includesWorkspace: true)
        let workspace = try XCTUnwrap(fixture.workspace)
        let first = Label(name: "First")
        let missingPrimaryID = UUID()
        let bookmark = trustedBibleBookmark(id: UUID())
        fixture.context.insert(first)
        fixture.context.insert(bookmark)
        attach(first, to: bookmark, order: -1, context: fixture.context)
        bookmark.primaryLabelId = first.id
        let originalTimestamp = bookmark.lastUpdatedOn
        try fixture.context.save()

        try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .commitBookmarkLabelAssignment(
                bookmarkIDs: [bookmark.id],
                orderedSelectedLabelIDs: [first.id],
                primaryLabelID: missingPrimaryID,
                favouriteValues: [:],
                autoAssignLabelIDs: [],
                autoAssignPrimaryLabelID: nil,
                workspaceID: workspace.id,
                intent: .bookmarkList
            )

        let verification = ModelContext(fixture.context.container)
        let saved = try XCTUnwrap(try fetchBible(bookmark.id, in: verification))
        XCTAssertEqual(saved.primaryLabelId, first.id)
        XCTAssertEqual(saved.lastUpdatedOn, originalTimestamp)
        XCTAssertEqual(saved.bookmarkToLabels?.first?.orderNumber, -1)
        let settingsStore = SettingsStore(modelContext: verification)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertTrue(try journal.pendingMutations(for: .bookmarks, settingsStore: settingsStore).isEmpty)
        XCTAssertTrue(try journal.pendingMutations(for: .workspaces, settingsStore: settingsStore).isEmpty)
    }

    /**
     Verifies reader assignment retains existing links and uses Android's cursor/count placement.

     Setup: the reader bookmark retains a collapsed indented link, one added label has a StudyPad
     cursor amid trusted Bible/generic/text rows, another has no cursor, and quarantined Bible links
     exist for both labels. Expected: retained metadata is exact; cursor insertion shifts only trusted
     later rows and advances the cursor; count placement excludes the quarantined link; recent labels,
     explicit primary, and both category journals publish without touching the date.
     */
    func testReaderCommitPreservesRetainedMetadataAndUsesCursorOrItemCountForNewLinks() throws {
        let fixture = try makeFixture(includesWorkspace: true)
        let workspace = try XCTUnwrap(fixture.workspace)
        let retainedLabel = Label(name: "Retained")
        let cursorLabel = Label(name: "Cursor")
        let countLabel = Label(name: "Count")
        let target = trustedBibleBookmark(id: UUID())
        let existingBible = trustedBibleBookmark(id: UUID())
        let existingGeneric = GenericBookmark(id: UUID(), key: "Cursor entry", bookInitials: "DICT")
        let quarantinedBible = BibleBookmark(
            id: UUID(),
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            ordinalStart: 4,
            ordinalEnd: 4,
            v11n: "KJV"
        )
        [retainedLabel, cursorLabel, countLabel].forEach(fixture.context.insert)
        fixture.context.insert(target)
        fixture.context.insert(existingBible)
        fixture.context.insert(existingGeneric)
        fixture.context.insert(quarantinedBible)
        attach(
            retainedLabel,
            to: target,
            order: 7,
            indent: 3,
            expanded: false,
            context: fixture.context
        )
        attach(cursorLabel, to: existingBible, order: 1, context: fixture.context)
        attach(cursorLabel, to: existingGeneric, order: 3, context: fixture.context)
        attach(cursorLabel, to: quarantinedBible, order: 4, context: fixture.context)
        attach(countLabel, to: quarantinedBible, order: 5, context: fixture.context)
        XCTAssertFalse(quarantinedBible.hasTrustedPersistedOrdinals)
        let cursorText = StudyPadTextEntry(orderNumber: 2, indentLevel: 1)
        cursorText.label = cursorLabel
        fixture.context.insert(cursorText)
        let countText = StudyPadTextEntry(orderNumber: 0)
        countText.label = countLabel
        fixture.context.insert(countText)
        target.primaryLabelId = retainedLabel.id
        workspace.workspaceSettings = WorkspaceSettings(
            recentLabels: [RecentLabel(
                labelId: retainedLabel.id,
                lastAccess: Date(timeIntervalSince1970: 1)
            )],
            studyPadCursors: [cursorLabel.id: 2]
        )
        let originalTimestamp = target.lastUpdatedOn
        try fixture.context.save()

        try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .commitBookmarkLabelAssignment(
                bookmarkIDs: [target.id],
                orderedSelectedLabelIDs: [retainedLabel.id, cursorLabel.id, countLabel.id],
                primaryLabelID: countLabel.id,
                favouriteValues: [:],
                autoAssignLabelIDs: [],
                autoAssignPrimaryLabelID: nil,
                workspaceID: workspace.id,
                intent: .reader
            )

        let verification = ModelContext(fixture.context.container)
        let savedTarget = try XCTUnwrap(try fetchBible(target.id, in: verification))
        let retained = try XCTUnwrap(
            savedTarget.bookmarkToLabels?.first { $0.label?.id == retainedLabel.id }
        )
        XCTAssertEqual(retained.orderNumber, 7)
        XCTAssertEqual(retained.indentLevel, 3)
        XCTAssertFalse(retained.expandContent)
        XCTAssertEqual(
            savedTarget.bookmarkToLabels?.first { $0.label?.id == cursorLabel.id }?.orderNumber,
            2
        )
        XCTAssertEqual(
            savedTarget.bookmarkToLabels?.first { $0.label?.id == countLabel.id }?.orderNumber,
            1
        )
        XCTAssertEqual(savedTarget.primaryLabelId, countLabel.id)
        XCTAssertEqual(savedTarget.lastUpdatedOn, originalTimestamp)

        let savedBible = try XCTUnwrap(try fetchBible(existingBible.id, in: verification))
        let savedGeneric = try XCTUnwrap(try fetchGeneric(existingGeneric.id, in: verification))
        XCTAssertEqual(savedBible.bookmarkToLabels?.first?.orderNumber, 1)
        XCTAssertEqual(savedGeneric.bookmarkToLabels?.first?.orderNumber, 4)
        let savedQuarantined = try XCTUnwrap(try fetchBible(quarantinedBible.id, in: verification))
        XCTAssertEqual(
            savedQuarantined.bookmarkToLabels?.first { $0.label?.id == cursorLabel.id }?.orderNumber,
            4
        )
        XCTAssertEqual(
            savedQuarantined.bookmarkToLabels?.first { $0.label?.id == countLabel.id }?.orderNumber,
            5
        )
        let savedCursorText = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<StudyPadTextEntry>())
                .first { $0.id == cursorText.id }
        )
        XCTAssertEqual(savedCursorText.orderNumber, 3)
        let savedWorkspace = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<Workspace>()).first { $0.id == workspace.id }
        )
        XCTAssertEqual(savedWorkspace.workspaceSettings?.studyPadCursors[cursorLabel.id], 3)
        XCTAssertNil(savedWorkspace.workspaceSettings?.studyPadCursors[countLabel.id])
        XCTAssertEqual(
            Set(savedWorkspace.workspaceSettings?.recentLabels.map(\.labelId) ?? []),
            [retainedLabel.id, cursorLabel.id, countLabel.id]
        )
        let settingsStore = SettingsStore(modelContext: verification)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertFalse(try journal.pendingMutations(for: .bookmarks, settingsStore: settingsStore).isEmpty)
        XCTAssertFalse(try journal.pendingMutations(for: .workspaces, settingsStore: settingsStore).isEmpty)
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
                    workspaceID: nil,
                    intent: .bookmarkList
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
            workspaceID: workspace.id,
            intent: .reader
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
            workspaceID: workspace.id,
            intent: .reader
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
                workspaceID: workspace.id,
                intent: .workspace
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

    /**
     Verifies ASSIGN confirmation with an unchanged draft performs no semantic or journal write.

     Setup: one bookmark already has the submitted label/primary and its workspace already carries
     the submitted auto-assignment state. Expected: the timestamp and relationship stay exact and
     both category journals remain empty. A failure means closing an untouched foreground editor
     still enters the collection-wide bookmark snapshot path.
     */
    func testUnchangedAssignCommitPreservesTimestampAndSkipsBothJournals() throws {
        let fixture = try makeFixture(includesWorkspace: true)
        let workspace = try XCTUnwrap(fixture.workspace)
        let label = Label(name: "Stable")
        let bookmark = trustedBibleBookmark(id: UUID())
        fixture.context.insert(label)
        fixture.context.insert(bookmark)
        attach(label, to: bookmark, order: 4, context: fixture.context)
        bookmark.primaryLabelId = label.id
        workspace.workspaceSettings = WorkspaceSettings(
            autoAssignLabels: [label.id],
            autoAssignPrimaryLabel: label.id
        )
        let originalTimestamp = bookmark.lastUpdatedOn
        try fixture.context.save()

        try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .commitBookmarkLabelAssignment(
                bookmarkIDs: [bookmark.id],
                orderedSelectedLabelIDs: [label.id],
                primaryLabelID: label.id,
                favouriteValues: [label.id: false],
                autoAssignLabelIDs: [label.id],
                autoAssignPrimaryLabelID: label.id,
                workspaceID: workspace.id,
                intent: .reader
            )

        let verification = ModelContext(fixture.context.container)
        let saved = try XCTUnwrap(try fetchBible(bookmark.id, in: verification))
        XCTAssertEqual(saved.lastUpdatedOn, originalTimestamp)
        XCTAssertEqual(saved.bookmarkToLabels?.compactMap(\.label?.id), [label.id])
        XCTAssertEqual(saved.bookmarkToLabels?.first?.orderNumber, 4)
        let settingsStore = SettingsStore(modelContext: verification)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertTrue(try journal.pendingMutations(for: .bookmarks, settingsStore: settingsStore).isEmpty)
        XCTAssertTrue(try journal.pendingMutations(for: .workspaces, settingsStore: settingsStore).isEmpty)
    }

    /**
     Verifies cancellation remains observable when a valid generation needs no persistence work.

     Setup: the production-shaped fixture already contains the exact submitted assignment, then the
     service call starts in a cancelled task. Expected: the call throws `CancellationError`, retains
     the relationship and timestamp, and produces no category journal. A failure means the no-op
     fast path can dismiss a cancelled foreground operation as successful.
     */
    func testCancelledValidNoOpThrowsWithoutPersistingOrJournaling() async throws {
        let full = try makeFixture(includesWorkspace: true)
        let fullWorkspace = try XCTUnwrap(full.workspace)
        let fullLabel = Label(name: "Full stable")
        let fullBookmark = trustedBibleBookmark(id: UUID())
        full.context.insert(fullLabel)
        full.context.insert(fullBookmark)
        attach(fullLabel, to: fullBookmark, order: 3, context: full.context)
        fullBookmark.primaryLabelId = fullLabel.id
        fullWorkspace.workspaceSettings = WorkspaceSettings(
            autoAssignLabels: [fullLabel.id],
            autoAssignPrimaryLabel: fullLabel.id
        )
        let fullTimestamp = fullBookmark.lastUpdatedOn
        try full.context.save()

        let fullResult: Result<Void, Error> = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try WorkspaceLabelConfigurationService(modelContext: full.context)
                    .commitBookmarkLabelAssignment(
                        bookmarkIDs: [fullBookmark.id],
                        orderedSelectedLabelIDs: [fullLabel.id],
                        primaryLabelID: fullLabel.id,
                        favouriteValues: [:],
                        autoAssignLabelIDs: [fullLabel.id],
                        autoAssignPrimaryLabelID: fullLabel.id,
                        workspaceID: fullWorkspace.id,
                        intent: .reader
                    )
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch fullResult {
        case .success:
            XCTFail("Expected the cancelled no-op assignment to throw CancellationError")
        case .failure(let error):
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        let fullVerification = ModelContext(full.context.container)
        let savedFull = try XCTUnwrap(try fetchBible(fullBookmark.id, in: fullVerification))
        XCTAssertEqual(savedFull.lastUpdatedOn, fullTimestamp)
        XCTAssertEqual(savedFull.bookmarkToLabels?.compactMap(\.label?.id), [fullLabel.id])
        XCTAssertEqual(savedFull.bookmarkToLabels?.first?.orderNumber, 3)
        let fullSettings = SettingsStore(modelContext: fullVerification)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertTrue(try journal.pendingMutations(for: .bookmarks, settingsStore: fullSettings).isEmpty)
        XCTAssertTrue(try journal.pendingMutations(for: .workspaces, settingsStore: fullSettings).isEmpty)
    }

    /**
     Verifies this public service rejects a container that cannot persist its required journal.

     Setup: an explicitly unsupported graph-only schema contains a valid bookmark and two labels.
     Expected: a real assignment change throws `settingsStorageUnavailable` and leaves the original
     relationship, primary, and favourite state exact. A failure reintroduces silent graph-only
     persistence that no production caller supports.
     */
    func testCommitRejectsMissingJournalStorageWithoutPersistingGraphChanges() throws {
        let fixture = try makeUnsupportedFixtureWithoutSettings()
        let first = Label(name: "First")
        let second = Label(name: "Second")
        let bookmark = trustedBibleBookmark(id: UUID())
        fixture.context.insert(first)
        fixture.context.insert(second)
        fixture.context.insert(bookmark)
        attach(first, to: bookmark, order: 2, context: fixture.context)
        bookmark.primaryLabelId = first.id
        try fixture.context.save()

        XCTAssertThrowsError(
            try WorkspaceLabelConfigurationService(modelContext: fixture.context)
                .commitBookmarkLabelAssignment(
                    bookmarkIDs: [bookmark.id],
                    orderedSelectedLabelIDs: [second.id],
                    primaryLabelID: second.id,
                    favouriteValues: [second.id: true],
                    autoAssignLabelIDs: [],
                    autoAssignPrimaryLabelID: nil,
                    workspaceID: nil,
                    intent: .reader
                )
        ) { error in
            XCTAssertEqual(
                error as? BookmarkLabelAssignmentError,
                .settingsStorageUnavailable
            )
        }

        let verification = ModelContext(fixture.context.container)
        let saved = try XCTUnwrap(try fetchBible(bookmark.id, in: verification))
        XCTAssertEqual(saved.bookmarkToLabels?.compactMap(\.label?.id), [first.id])
        XCTAssertEqual(saved.primaryLabelId, first.id)
        XCTAssertFalse(try XCTUnwrap(try fetchLabel(second.id, in: verification)).favourite)
    }

    /**
     Verifies requested-ID predicates remain exact beyond SQLite's legacy 999-bind boundary.

     Setup: 1,001 selected bookmarks have no labels while unrelated rows carry one label and
     primary. Expected: snapshot and no-op commit resolve only the selected rows, and an unrelated
     row retains its graph. A failure exposes predicate translation, chunking, or overfetch on a
     supported iOS runtime through the production service rather than a test-only query.
     */
    func testLargeBookmarkSelectionPredicatesExcludeUnrelatedRowsBeyondLegacyBindLimit() throws {
        let fixture = try makeFixture(includesWorkspace: false)
        let unrelatedLabel = Label(name: "Unrelated")
        fixture.context.insert(unrelatedLabel)

        let selectedIDs = (0..<1_001).map { _ in UUID() }
        for id in selectedIDs {
            fixture.context.insert(trustedBibleBookmark(id: id))
        }

        let unrelatedIDs = (0..<23).map { _ in UUID() }
        for (index, id) in unrelatedIDs.enumerated() {
            let bookmark = trustedBibleBookmark(id: id)
            fixture.context.insert(bookmark)
            attach(unrelatedLabel, to: bookmark, order: index, context: fixture.context)
            bookmark.primaryLabelId = unrelatedLabel.id
        }
        try fixture.context.save()

        let service = WorkspaceLabelConfigurationService(modelContext: fixture.context)
        let snapshot = try service.bookmarkLabelAssignmentSnapshot(
            bookmarkIDs: selectedIDs,
            workspaceID: nil,
            intent: .bookmarkList
        )
        XCTAssertEqual(snapshot.bookmarkCount, selectedIDs.count)
        XCTAssertTrue(snapshot.selectedLabelIDs.isEmpty)
        XCTAssertNil(snapshot.primaryLabelID)

        try service.commitBookmarkLabelAssignment(
            bookmarkIDs: selectedIDs,
            orderedSelectedLabelIDs: [],
            primaryLabelID: nil,
            favouriteValues: [:],
            autoAssignLabelIDs: [],
            autoAssignPrimaryLabelID: nil,
            workspaceID: nil,
            intent: .bookmarkList
        )

        let verification = ModelContext(fixture.context.container)
        let firstSelected = try XCTUnwrap(try fetchBible(try XCTUnwrap(selectedIDs.first), in: verification))
        let lastSelected = try XCTUnwrap(try fetchBible(try XCTUnwrap(selectedIDs.last), in: verification))
        XCTAssertTrue(firstSelected.bookmarkToLabels?.isEmpty ?? true)
        XCTAssertTrue(lastSelected.bookmarkToLabels?.isEmpty ?? true)
        let unrelated = try XCTUnwrap(try fetchBible(try XCTUnwrap(unrelatedIDs.first), in: verification))
        XCTAssertEqual(unrelated.bookmarkToLabels?.compactMap(\.label?.id), [unrelatedLabel.id])
        XCTAssertEqual(unrelated.primaryLabelId, unrelatedLabel.id)
    }

    /**
     Verifies an unselected missing reader primary falls back without stale-identity failure.

     Android validates the selected labels, assigns the returned primary, then falls back to the
     first selected label when that primary is absent. Expected: the selected label persists as
     primary and the irrelevant missing UUID is never fetched or validated.
     */
    func testReaderIgnoresMissingUnselectedPrimaryAndFallsBackToFirstSelected() throws {
        let fixture = try makeFixture(includesWorkspace: false)
        let label = Label(name: "Selected")
        let bookmark = trustedBibleBookmark(id: UUID())
        fixture.context.insert(label)
        fixture.context.insert(bookmark)
        attach(label, to: bookmark, order: 5, context: fixture.context)
        bookmark.primaryLabelId = nil
        try fixture.context.save()

        try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .commitBookmarkLabelAssignment(
                bookmarkIDs: [bookmark.id],
                orderedSelectedLabelIDs: [label.id],
                primaryLabelID: UUID(),
                favouriteValues: [:],
                autoAssignLabelIDs: [],
                autoAssignPrimaryLabelID: nil,
                workspaceID: nil,
                intent: .reader
            )

        let verification = ModelContext(fixture.context.container)
        let saved = try XCTUnwrap(try fetchBible(bookmark.id, in: verification))
        XCTAssertEqual(saved.primaryLabelId, label.id)
        XCTAssertEqual(saved.bookmarkToLabels?.first?.orderNumber, 5)
    }

    /**
     Verifies WORKSPACE intent projects away bookmark, selected-label, and stale primary inputs.

     The workspace caller owns favourite/auto-assignment state only. Expected: missing irrelevant
     bookmark and selected-label IDs do not abort, and a missing auto-primary outside the submitted
     auto-assigned set normalizes to its real first label.
     */
    func testWorkspaceIntentIgnoresBookmarkSelectionAndMissingUnassignedPrimaries() throws {
        let fixture = try makeFixture(includesWorkspace: true)
        let workspace = try XCTUnwrap(fixture.workspace)
        let label = Label(name: "Workspace")
        fixture.context.insert(label)
        try fixture.context.save()

        try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .commitBookmarkLabelAssignment(
                bookmarkIDs: [UUID()],
                orderedSelectedLabelIDs: [UUID()],
                primaryLabelID: UUID(),
                favouriteValues: [:],
                autoAssignLabelIDs: [label.id],
                autoAssignPrimaryLabelID: UUID(),
                workspaceID: workspace.id,
                intent: .workspace
            )

        let verification = ModelContext(fixture.context.container)
        let savedWorkspace = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<Workspace>()).first { $0.id == workspace.id }
        )
        XCTAssertEqual(savedWorkspace.workspaceSettings?.autoAssignLabels, [label.id])
        XCTAssertEqual(savedWorkspace.workspaceSettings?.autoAssignPrimaryLabel, label.id)
        let settingsStore = SettingsStore(modelContext: verification)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertTrue(try journal.pendingMutations(for: .bookmarks, settingsStore: settingsStore).isEmpty)
        XCTAssertFalse(try journal.pendingMutations(for: .workspaces, settingsStore: settingsStore).isEmpty)
    }

    /**
     Verifies WORKSPACE-mode edits journal only the workspace category.

     Setup: Manage Labels has no bookmark route and adds one existing label to workspace automatic
     assignment. Expected: workspace settings persist, the workspace journal changes, and the
     bookmark journal stays empty. A failure means a workspace-only foreground action still
     materializes the complete bookmark snapshot.
     */
    func testWorkspaceOnlyAssignmentChangeSkipsBookmarkJournalProjection() throws {
        let fixture = try makeFixture(includesWorkspace: true)
        let workspace = try XCTUnwrap(fixture.workspace)
        let label = Label(name: "Workspace only")
        fixture.context.insert(label)
        try fixture.context.save()

        try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .commitBookmarkLabelAssignment(
                bookmarkIDs: [],
                orderedSelectedLabelIDs: [],
                primaryLabelID: nil,
                favouriteValues: [:],
                autoAssignLabelIDs: [label.id],
                autoAssignPrimaryLabelID: label.id,
                workspaceID: workspace.id,
                intent: .workspace
            )

        let verification = ModelContext(fixture.context.container)
        let savedWorkspace = try XCTUnwrap(
            try verification.fetch(FetchDescriptor<Workspace>()).first { $0.id == workspace.id }
        )
        XCTAssertEqual(savedWorkspace.workspaceSettings?.autoAssignLabels, [label.id])
        XCTAssertEqual(savedWorkspace.workspaceSettings?.autoAssignPrimaryLabel, label.id)
        let settingsStore = SettingsStore(modelContext: verification)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertTrue(try journal.pendingMutations(for: .bookmarks, settingsStore: settingsStore).isEmpty)
        XCTAssertFalse(try journal.pendingMutations(for: .workspaces, settingsStore: settingsStore).isEmpty)
    }

    /**
     Verifies bookmark-list label changes journal bookmarks without a workspace mutation.

     Setup: one list bookmark changes from First to Second while workspace fields remain empty and
     its existing primary already names Second. Expected: exact membership changes with the primary
     and timestamp stable, only the bookmark journal is populated, and the workspace journal stays
     empty. A failure drops a list assignment, changes Last Updated sorting, or invents reader-only
     recent-label effects.
     */
    func testBookmarkOnlyAssignmentChangeSkipsWorkspaceJournalProjection() throws {
        let fixture = try makeFixture(includesWorkspace: true)
        let workspace = try XCTUnwrap(fixture.workspace)
        let first = Label(name: "First")
        let second = Label(name: "Second")
        let bookmark = trustedBibleBookmark(id: UUID())
        let untouched = trustedBibleBookmark(id: UUID())
        untouched.lastUpdatedOn = Date(timeIntervalSince1970: 2)
        fixture.context.insert(first)
        fixture.context.insert(second)
        fixture.context.insert(bookmark)
        fixture.context.insert(untouched)
        attach(first, to: bookmark, order: 1, context: fixture.context)
        bookmark.primaryLabelId = second.id
        let originalTimestamp = bookmark.lastUpdatedOn
        try fixture.context.save()

        try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .commitBookmarkLabelAssignment(
                bookmarkIDs: [bookmark.id],
                orderedSelectedLabelIDs: [second.id],
                primaryLabelID: nil,
                favouriteValues: [:],
                autoAssignLabelIDs: [],
                autoAssignPrimaryLabelID: nil,
                workspaceID: workspace.id,
                intent: .bookmarkList
            )

        let verification = ModelContext(fixture.context.container)
        let saved = try XCTUnwrap(try fetchBible(bookmark.id, in: verification))
        XCTAssertEqual(saved.bookmarkToLabels?.compactMap(\.label?.id), [second.id])
        XCTAssertEqual(saved.primaryLabelId, second.id)
        XCTAssertEqual(saved.lastUpdatedOn, originalTimestamp)
        XCTAssertEqual(
            BookmarkStore(modelContext: verification).bibleBookmarks(sortOrder: .lastUpdated).map(\.id),
            [bookmark.id, untouched.id]
        )
        let settingsStore = SettingsStore(modelContext: verification)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertFalse(try journal.pendingMutations(for: .bookmarks, settingsStore: settingsStore).isEmpty)
        XCTAssertTrue(try journal.pendingMutations(for: .workspaces, settingsStore: settingsStore).isEmpty)
    }

    /**
     Verifies a real primary-label change is journaled without changing Android's bookmark date.

     Setup: one reader bookmark retains the same two labels but changes primary from First to
     Second. Expected: the primary persists and produces a bookmark mutation while `lastUpdatedOn`
     and the workspace journal remain unchanged. A failure either drops the primary-only graph
     change or incorrectly reorders Android's Last Updated bookmark view.
     */
    func testPrimaryOnlyAssignmentChangePreservesTimestampAndJournalsBookmark() throws {
        let fixture = try makeFixture(includesWorkspace: true)
        let workspace = try XCTUnwrap(fixture.workspace)
        let first = Label(name: "First")
        let second = Label(name: "Second")
        let bookmark = trustedBibleBookmark(id: UUID())
        fixture.context.insert(first)
        fixture.context.insert(second)
        fixture.context.insert(bookmark)
        attach(first, to: bookmark, order: 1, context: fixture.context)
        attach(second, to: bookmark, order: 2, context: fixture.context)
        bookmark.primaryLabelId = first.id
        let originalTimestamp = bookmark.lastUpdatedOn
        try fixture.context.save()

        try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .commitBookmarkLabelAssignment(
                bookmarkIDs: [bookmark.id],
                orderedSelectedLabelIDs: [first.id, second.id],
                primaryLabelID: second.id,
                favouriteValues: [:],
                autoAssignLabelIDs: [],
                autoAssignPrimaryLabelID: nil,
                workspaceID: workspace.id,
                intent: .reader
            )

        let verification = ModelContext(fixture.context.container)
        let saved = try XCTUnwrap(try fetchBible(bookmark.id, in: verification))
        XCTAssertEqual(saved.primaryLabelId, second.id)
        XCTAssertEqual(saved.lastUpdatedOn, originalTimestamp)
        let settingsStore = SettingsStore(modelContext: verification)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertFalse(try journal.pendingMutations(for: .bookmarks, settingsStore: settingsStore).isEmpty)
        XCTAssertTrue(try journal.pendingMutations(for: .workspaces, settingsStore: settingsStore).isEmpty)
    }

    /**
     Verifies a favourite-only label edit does not rewrite an unchanged bookmark assignment.

     Setup: ASSIGN mode submits the bookmark's existing label and primary while changing that
     label's favourite flag. Expected: the label and bookmark journal change, but the bookmark
     timestamp and relationship stay exact and the workspace journal remains empty. A failure
     means category-level change detection still turns a label-only edit into a bookmark rewrite.
     */
    func testFavouriteOnlyChangePreservesBookmarkTimestampAndSkipsWorkspaceJournal() throws {
        let fixture = try makeFixture(includesWorkspace: true)
        let workspace = try XCTUnwrap(fixture.workspace)
        let label = Label(name: "Favourite")
        let bookmark = trustedBibleBookmark(id: UUID())
        fixture.context.insert(label)
        fixture.context.insert(bookmark)
        attach(label, to: bookmark, order: 6, context: fixture.context)
        bookmark.primaryLabelId = label.id
        let originalTimestamp = bookmark.lastUpdatedOn
        try fixture.context.save()

        try WorkspaceLabelConfigurationService(modelContext: fixture.context)
            .commitBookmarkLabelAssignment(
                bookmarkIDs: [bookmark.id],
                orderedSelectedLabelIDs: [label.id],
                primaryLabelID: label.id,
                favouriteValues: [label.id: true],
                autoAssignLabelIDs: [],
                autoAssignPrimaryLabelID: nil,
                workspaceID: workspace.id,
                intent: .reader
            )

        let verification = ModelContext(fixture.context.container)
        let saved = try XCTUnwrap(try fetchBible(bookmark.id, in: verification))
        XCTAssertEqual(saved.lastUpdatedOn, originalTimestamp)
        XCTAssertEqual(saved.bookmarkToLabels?.compactMap(\.label?.id), [label.id])
        XCTAssertTrue(try XCTUnwrap(try fetchLabel(label.id, in: verification)).favourite)
        let settingsStore = SettingsStore(modelContext: verification)
        let journal = RemoteSyncMutationJournalService()
        XCTAssertFalse(try journal.pendingMutations(for: .bookmarks, settingsStore: settingsStore).isEmpty)
        XCTAssertTrue(try journal.pendingMutations(for: .workspaces, settingsStore: settingsStore).isEmpty)
    }

    /// Context and optional workspace owned by one test.
    private struct Fixture {
        let context: ModelContext
        let workspace: Workspace?
    }

    /** Creates the app's complete cloud/local model partitions in distinct persistent stores. */
    private func makeFixture(includesWorkspace: Bool) throws -> Fixture {
        let storeDirectory = try makeProcessLifetimePersistentStoreDirectory(
            label: "bookmark-label-assignment"
        )
        let cloudModels = BibleCoreBaseModelRegistration.cloudModels
            + AIModelRegistration.cloudSyncableModels
        let localModels = BibleCoreBaseModelRegistration.localModels
            + AIModelRegistration.localOnlyModels
        let schema = Schema(cloudModels + localModels)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    "BookmarkLabelAssignmentCloud",
                    schema: Schema(cloudModels),
                    url: storeDirectory.appendingPathComponent(
                        "BookmarkLabelAssignmentCloud.store"
                    ),
                    cloudKitDatabase: .none
                ),
                ModelConfiguration(
                    "BookmarkLabelAssignmentLocal",
                    schema: Schema(localModels),
                    url: storeDirectory.appendingPathComponent(
                        "BookmarkLabelAssignmentLocal.store"
                    ),
                    cloudKitDatabase: .none
                ),
            ]
        )
        let context = ModelContext(container)
        let workspace = includesWorkspace ? Workspace(name: "Workspace") : nil
        if let workspace {
            workspace.workspaceSettings = WorkspaceSettings()
            context.insert(workspace)
        }
        try context.save()
        return Fixture(context: context, workspace: workspace)
    }

    /** Creates the unsupported graph-only schema used solely to verify capability rejection. */
    private func makeUnsupportedFixtureWithoutSettings() throws -> Fixture {
        let models: [any PersistentModel.Type] = [
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
        let schema = Schema(models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
        try context.save()
        return Fixture(context: context, workspace: nil)
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
