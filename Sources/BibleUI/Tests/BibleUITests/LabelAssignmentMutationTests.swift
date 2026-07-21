import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 App-host-free coverage for bookmark label-assignment persistence.

 These tests replace heavyweight XCUITest workflows that opened Label Assignment through the full
 reader shell to validate relationship mutations. The visible route still has a smoke test, while
 this package suite owns the Android `ManageLabels.Mode.ASSIGN` data contract for Bible and generic
 bookmarks.
 */
final class LabelAssignmentMutationTests: XCTestCase {
    /**
     Verifies Bible bookmark assignment and favourite toggles persist through SwiftData.

     Setup:
     - creates one Bible bookmark and one user label in an in-memory package test container
     - applies the same mutation helper used by `LabelAssignmentView`

     Expected result:
     - toggling favourite flips and saves `Label.favourite`
     - toggling assignment inserts exactly one `BibleBookmarkToLabel`
     - toggling assignment again removes the relationship row and refreshes assignment state

     Failure meaning:
     - the native label-assignment screen can pass route-level UI smoke tests while failing to
       mutate Android-compatible bookmark-label persistence.
     */
    func testLabelAssignmentMutationTogglesBibleAssignmentAndFavourite() throws {
        let modelContext = try makeBookmarkMutationContext()
        let bookmark = bibleBookmark(id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!)
        let label = Label(name: "UI Test Seed")
        modelContext.insert(bookmark)
        modelContext.insert(label)
        try modelContext.save()

        XCTAssertEqual(
            try LabelAssignmentMutation.state(for: bookmark.id, in: modelContext),
            .init(kind: .bible, assignedLabelIds: [])
        )

        XCTAssertTrue(try LabelAssignmentMutation.toggleFavourite(label, in: modelContext))
        XCTAssertTrue(label.favourite)

        let assignedState = try LabelAssignmentMutation.toggleLabel(
            label,
            bookmarkId: bookmark.id,
            kind: .bible,
            in: modelContext
        )
        XCTAssertEqual(assignedState, .init(kind: .bible, assignedLabelIds: [label.id]))
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<BibleBookmarkToLabel>()).count, 1)
        XCTAssertEqual(bookmark.primaryLabelId, label.id)

        let removedState = try LabelAssignmentMutation.toggleLabel(
            label,
            bookmarkId: bookmark.id,
            kind: .bible,
            in: modelContext
        )
        XCTAssertEqual(removedState, .init(kind: .bible, assignedLabelIds: []))
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<BibleBookmarkToLabel>()).isEmpty)
        XCTAssertNil(bookmark.primaryLabelId)
        XCTAssertTrue(label.favourite)
    }

    /**
     Verifies inline label creation assigns the new label without duplicating repeat submissions.

     Setup:
     - creates one Bible bookmark with no labels
     - calls the create-and-assign path twice with the same label name

     Expected result:
     - one real user label exists
     - one bookmark-to-label row exists
     - the refreshed state remains assigned after the repeat submission

     Failure meaning:
     - the alert-backed create-label affordance can create duplicate labels or duplicate
       relationships even though a visible row eventually appears.
     */
    func testLabelAssignmentMutationCreatesAndReusesBibleLabelAssignment() throws {
        let modelContext = try makeBookmarkMutationContext()
        let bookmark = bibleBookmark(id: UUID(uuidString: "30000000-0000-0000-0000-000000000002")!)
        modelContext.insert(bookmark)
        try modelContext.save()

        let firstState = try LabelAssignmentMutation.createAndAssignLabel(
            named: "UI Test Fresh",
            bookmarkId: bookmark.id,
            kind: .bible,
            in: modelContext
        )
        let secondState = try LabelAssignmentMutation.createAndAssignLabel(
            named: "UI Test Fresh",
            bookmarkId: bookmark.id,
            kind: .bible,
            in: modelContext
        )

        let labels = try modelContext.fetch(FetchDescriptor<Label>())
        let links = try modelContext.fetch(FetchDescriptor<BibleBookmarkToLabel>())
        XCTAssertEqual(labels.map(\.name), ["UI Test Fresh"])
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(firstState.kind, .bible)
        XCTAssertEqual(secondState.kind, .bible)
        XCTAssertEqual(firstState.assignedLabelIds, Set(labels.map(\.id)))
        XCTAssertEqual(secondState.assignedLabelIds, Set(labels.map(\.id)))
        XCTAssertEqual(bookmark.primaryLabelId, labels.first?.id)
    }

    /**
     Verifies generic bookmarks use the generic junction table for label assignment.

     Setup:
     - creates one generic bookmark and one user label
     - toggles assignment on and off through `LabelAssignmentMutation`

     Expected result:
     - the state reports `.generic`
     - assignment inserts exactly one `GenericBookmarkToLabel`
     - removal clears the generic relationship without creating Bible bookmark links

     Failure meaning:
     - dictionary/MyDocument bookmarks can disappear from Android-compatible filtered lists or
       mutate the wrong relationship table.
     */
    func testLabelAssignmentMutationTogglesGenericBookmarkAssignment() throws {
        let modelContext = try makeBookmarkMutationContext()
        let bookmark = GenericBookmark(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            key: "Entry 1",
            bookInitials: "UITESTDICT",
            createdAt: Date(timeIntervalSince1970: 1),
            ordinalStart: 1,
            ordinalEnd: 1,
            lastUpdatedOn: Date(timeIntervalSince1970: 1)
        )
        let label = Label(name: "UI Test Seed")
        modelContext.insert(bookmark)
        modelContext.insert(label)
        try modelContext.save()

        let assignedState = try LabelAssignmentMutation.toggleLabel(
            label,
            bookmarkId: bookmark.id,
            kind: .generic,
            in: modelContext
        )
        XCTAssertEqual(assignedState, .init(kind: .generic, assignedLabelIds: [label.id]))
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<GenericBookmarkToLabel>()).count, 1)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<BibleBookmarkToLabel>()).isEmpty)
        XCTAssertEqual(bookmark.primaryLabelId, label.id)

        let removedState = try LabelAssignmentMutation.toggleLabel(
            label,
            bookmarkId: bookmark.id,
            kind: .generic,
            in: modelContext
        )
        XCTAssertEqual(removedState, .init(kind: .generic, assignedLabelIds: []))
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<GenericBookmarkToLabel>()).isEmpty)
        XCTAssertNil(bookmark.primaryLabelId)
    }

    /**
     Verifies removing a primary assignment promotes the remaining label for both bookmark tables.

     Setup:
     - creates Bible and generic bookmarks with the same two labels
     - assigns the first label, then the second, and removes the first through the production helper

     Expected result:
     - the first assignment becomes primary
     - adding a second assignment retains the valid primary
     - removing the primary promotes the sole remaining label on both bookmarks

     Failure meaning:
     - Label Assignment bypassed the shared Android primary-label repair contract, leaving a stale
       scalar identifier after its relationship row was removed.
     */
    func testRemovingPrimaryAssignmentPromotesRemainingLabelForBibleAndGenericBookmarks() throws {
        let modelContext = try makeBookmarkMutationContext()
        let bible = bibleBookmark(id: UUID(uuidString: "30000000-0000-0000-0000-000000000004")!)
        let generic = GenericBookmark(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000005")!,
            key: "Entry 2",
            bookInitials: "UITESTDICT",
            createdAt: Date(timeIntervalSince1970: 1),
            ordinalStart: 2,
            ordinalEnd: 2,
            lastUpdatedOn: Date(timeIntervalSince1970: 1)
        )
        let first = Label(name: "First")
        let second = Label(name: "Second")
        modelContext.insert(bible)
        modelContext.insert(generic)
        modelContext.insert(first)
        modelContext.insert(second)
        try modelContext.save()

        for (bookmarkId, kind) in [
            (bible.id, LabelAssignmentMutation.BookmarkKind.bible),
            (generic.id, LabelAssignmentMutation.BookmarkKind.generic),
        ] {
            _ = try LabelAssignmentMutation.toggleLabel(
                first,
                bookmarkId: bookmarkId,
                kind: kind,
                in: modelContext
            )
            _ = try LabelAssignmentMutation.toggleLabel(
                second,
                bookmarkId: bookmarkId,
                kind: kind,
                in: modelContext
            )
            _ = try LabelAssignmentMutation.toggleLabel(
                first,
                bookmarkId: bookmarkId,
                kind: kind,
                in: modelContext
            )
        }

        XCTAssertEqual(bible.primaryLabelId, second.id)
        XCTAssertEqual(generic.primaryLabelId, second.id)
        XCTAssertEqual(
            try LabelAssignmentMutation.state(for: bible.id, in: modelContext).assignedLabelIds,
            [second.id]
        )
        XCTAssertEqual(
            try LabelAssignmentMutation.state(for: generic.id, in: modelContext).assignedLabelIds,
            [second.id]
        )
    }

    /**
     Creates a SwiftData context containing the bookmark models used by Label Assignment.

     - Returns: Fresh in-memory context for one test.
     - Side effects: Allocates an in-process SwiftData store.
     - Throws: SwiftData model-container construction errors.
     */
    private func makeBookmarkMutationContext() throws -> ModelContext {
        ModelContext(try makeBookmarkListModelContainer())
    }

    /**
     Builds a persisted Bible bookmark fixture for label-assignment mutation tests.

     - Parameter id: Stable bookmark identifier used by mutation calls.
     - Returns: Unsaved bookmark with Android/KJVA ordinal metadata.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func bibleBookmark(id: UUID) -> BibleBookmark {
        let bookmark = BibleBookmark(
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
        bookmark.book = "Genesis"
        return bookmark
    }
}
