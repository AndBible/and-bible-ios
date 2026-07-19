import XCTest
import SwiftData
@testable import BibleCore
@testable import BibleUI

/**
 Package-lane coverage for BookmarkList filtering, sorting, and state export.

 The visible BookmarkList UI still has E2E smoke coverage for drawer routing, row navigation, row
 deletion, StudyPad handoff, and label-assignment workflows. These tests protect the pure list
 projection that previously required full app launches: Android-compatible sort order, in-content
 search, label filtering, and compact state export.
 */
final class BookmarkListProjectionTests: XCTestCase {
    /**
     Verifies the default created-date order and Android Bible-order sort projection.

     Setup:
     - builds two Bible bookmark rows matching the UI fixture order: a newer Matthew row and an
       older Exodus row
     - runs the same pure projection used by `BookmarkListView`

     Expected result:
     - `createdAtDesc` keeps Matthew before Exodus
     - `bibleOrder` moves Exodus before Matthew by KJVA document order

     Failure meaning:
     - the native BookmarkList sort menu can drift from Android's bookmark ordering contract even
       though the app route still opens.
     */
    func testBookmarkListProjectionSortsCreatedDateAndBibleOrderLikeAndroid() {
        let exodus = bibleItem(
            reference: "Exodus 2:1",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let matthew = bibleItem(
            reference: "Matthew 3:1",
            createdAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(
            BookmarkListProjection.filteredItems(
                [exodus, matthew],
                selectedLabelId: nil,
                searchText: "",
                sortOrder: .createdAtDesc
            ).map(\.reference),
            ["Matthew 3:1", "Exodus 2:1"]
        )
        XCTAssertEqual(
            BookmarkListProjection.filteredItems(
                [exodus, matthew],
                selectedLabelId: nil,
                searchText: "",
                sortOrder: .bibleOrder
            ).map(\.reference),
            ["Exodus 2:1", "Matthew 3:1"]
        )
    }

    /**
     Verifies BookmarkList's Android-style in-content search narrows and clears rows.

     Setup:
     - builds one Exodus and one Matthew bookmark projection row
     - filters with a mixed-case query and then with an empty query

     Expected result:
     - matching is case-insensitive against the row's searchable text
     - clearing search restores all rows
     - detailed state export includes the same count/query/row-token contract the UI consumed

     Failure meaning:
     - the list may regress to platform search chrome or fail to restore rows when the visible query
       is cleared.
     */
    func testBookmarkListProjectionSearchNarrowsAndClearsRows() {
        let exodus = bibleItem(reference: "Exodus 2:1")
        let matthew = bibleItem(reference: "Matthew 3:1")

        let filtered = BookmarkListProjection.filteredItems(
            [exodus, matthew],
            selectedLabelId: nil,
            searchText: "matthew",
            sortOrder: .bibleOrder
        )
        XCTAssertEqual(filtered.map(\.reference), ["Matthew 3:1"])
        XCTAssertEqual(
            BookmarkListProjection.accessibilityValue(
                for: filtered,
                selectedLabelId: nil,
                labels: [],
                searchText: "Matthew",
                isAssigningLabels: false,
                includeRowTokens: true,
                rowTokenLimit: 10
            ),
            "count=1;selectedLabel=all;query=Matthew;labelAssignment=false;rows=|Matthew_3_1|"
        )

        let cleared = BookmarkListProjection.filteredItems(
            [exodus, matthew],
            selectedLabelId: nil,
            searchText: "",
            sortOrder: .bibleOrder
        )
        XCTAssertEqual(cleared.map(\.reference), ["Exodus 2:1", "Matthew 3:1"])
    }

    /**
     Verifies BookmarkList label chips narrow rows and expose selected-label state.

     Setup:
     - builds one Genesis bookmark assigned to the user label and one Exodus bookmark without it
     - filters through the same selected-label projection used by the SwiftUI chip

     Expected result:
     - only rows assigned to the selected label remain
     - `selectedLabel` is sanitized consistently with the visible chip identifiers
     - clearing the selected label restores both rows

     Failure meaning:
     - the BookmarkList could expose a StudyPad handoff or filtered row set for the wrong label.
     */
    func testBookmarkListProjectionLabelFilterNarrowsAndClearsRows() {
        let seedLabel = Label(name: "UI Test Seed")
        let genesis = bibleItem(
            reference: "Genesis 1:1",
            labels: [seedLabel]
        )
        let exodus = bibleItem(reference: "Exodus 2:1")

        let filtered = BookmarkListProjection.filteredItems(
            [genesis, exodus],
            selectedLabelId: seedLabel.id,
            searchText: "",
            sortOrder: .bibleOrder
        )
        XCTAssertEqual(filtered.map(\.reference), ["Genesis 1:1"])
        XCTAssertEqual(
            BookmarkListProjection.accessibilityValue(
                for: filtered,
                selectedLabelId: seedLabel.id,
                labels: [seedLabel],
                searchText: "",
                isAssigningLabels: false,
                includeRowTokens: true,
                rowTokenLimit: 10
            ),
            "count=1;selectedLabel=UI_Test_Seed;query=;labelAssignment=false;rows=|Genesis_1_1|"
        )

        let cleared = BookmarkListProjection.filteredItems(
            [genesis, exodus],
            selectedLabelId: nil,
            searchText: "",
            sortOrder: .bibleOrder
        )
        XCTAssertEqual(cleared.map(\.reference), ["Genesis 1:1", "Exodus 2:1"])
    }

    /**
     Verifies a selected label and in-content query compose without leaking stale state.

     Setup:
     - builds the same Genesis/Exodus label split used by the visible UI fixture
     - applies the seeded label filter, then a conflicting query, then clears both controls

     Expected result:
     - the selected label narrows the list to Genesis
     - the conflicting query hides Genesis without surfacing the unselected Exodus row
     - clearing label and query state restores both rows and exports the default `all` state

     Failure meaning:
     - BookmarkList reset behavior can regress while route-level UI smokes keep passing, or search
       can incorrectly bypass the selected-label filter.
     */
    func testBookmarkListProjectionComposesLabelFilterAndSearchThenResets() {
        let seedLabel = Label(name: "UI Test Seed")
        let genesis = bibleItem(
            reference: "Genesis 1:1",
            labels: [seedLabel]
        )
        let exodus = bibleItem(reference: "Exodus 2:1")
        let items = [genesis, exodus]

        let labelFiltered = BookmarkListProjection.filteredItems(
            items,
            selectedLabelId: seedLabel.id,
            searchText: "",
            sortOrder: .bibleOrder
        )
        XCTAssertEqual(labelFiltered.map(\.reference), ["Genesis 1:1"])

        let conflictingQuery = BookmarkListProjection.filteredItems(
            items,
            selectedLabelId: seedLabel.id,
            searchText: "Exodus",
            sortOrder: .bibleOrder
        )
        XCTAssertTrue(conflictingQuery.isEmpty)
        XCTAssertEqual(
            BookmarkListProjection.accessibilityValue(
                for: conflictingQuery,
                selectedLabelId: seedLabel.id,
                labels: [seedLabel],
                searchText: "Exodus",
                isAssigningLabels: false,
                includeRowTokens: true,
                rowTokenLimit: 10
            ),
            "count=0;selectedLabel=UI_Test_Seed;query=Exodus;labelAssignment=false;rows="
        )

        let reset = BookmarkListProjection.filteredItems(
            items,
            selectedLabelId: nil,
            searchText: "",
            sortOrder: .bibleOrder
        )
        XCTAssertEqual(reset.map(\.reference), ["Genesis 1:1", "Exodus 2:1"])
        XCTAssertEqual(
            BookmarkListProjection.accessibilityValue(
                for: reset,
                selectedLabelId: nil,
                labels: [seedLabel],
                searchText: "",
                isAssigningLabels: false,
                includeRowTokens: true,
                rowTokenLimit: 10
            ),
            "count=2;selectedLabel=all;query=;labelAssignment=false;rows=|Genesis_1_1|,|Exodus_2_1|"
        )
    }

    /**
     Verifies generic bookmark rows participate in the same label-filter projection as Bible rows.

     Setup:
     - builds one generic bookmark assigned to the selected label and one unassigned generic row

     Expected result:
     - the selected label exposes only the assigned generic row
     - detailed state export uses the generic module/key token consumed by UI smoke tests

     Failure meaning:
     - generic bookmarks can disappear from Android-compatible filtered bookmark lists, or the
       visible workflow can keep passing while package-level list projection has drifted.
     */
    func testBookmarkListProjectionFiltersGenericBookmarksByAssignedLabel() {
        let seedLabel = Label(name: "UI Test Seed")
        let assigned = genericItem(module: "UITESTDICT", key: "Entry 1", labels: [seedLabel])
        let unassigned = genericItem(module: "UITESTDICT", key: "Entry 2")

        let filtered = BookmarkListProjection.filteredItems(
            [assigned, unassigned],
            selectedLabelId: seedLabel.id,
            searchText: "",
            sortOrder: .bibleOrder
        )

        XCTAssertEqual(filtered.map(\.reference), ["UITESTDICT: Entry 1"])
        XCTAssertEqual(
            BookmarkListProjection.accessibilityValue(
                for: filtered,
                selectedLabelId: seedLabel.id,
                labels: [seedLabel],
                searchText: "",
                isAssigningLabels: false,
                includeRowTokens: true,
                rowTokenLimit: 10
            ),
            "count=1;selectedLabel=UI_Test_Seed;query=;labelAssignment=false;rows=|UITESTDICT_Entry_1|"
        )
    }

    /**
     Verifies deleting one projected Bible bookmark row persists without removing sibling rows.

     Setup:
     - persists two Bible bookmarks into an in-memory SwiftData context
     - deletes only the projected Exodus row through `BookmarkListMutation`

     Expected result:
     - one row is reported deleted
     - the Matthew row remains after fetching from SwiftData again

     Failure meaning:
     - BookmarkList row deletion can remove too much data or fail to survive reopening the list.
     */
    func testBookmarkListMutationDeletesOnlySelectedBibleBookmarkAndPersists() throws {
        let container = try makeBookmarkListModelContainer()
        let modelContext = ModelContext(container)
        let exodus = persistedBibleBookmark(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            book: "Exodus",
            ordinal: 81
        )
        let matthew = persistedBibleBookmark(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            book: "Matthew",
            ordinal: 1_000
        )
        modelContext.insert(exodus)
        modelContext.insert(matthew)
        try modelContext.save()

        let deletedCount = try BookmarkListMutation.deleteItems(
            [BookmarkListItem(bibleBookmark: exodus)],
            in: modelContext
        )

        XCTAssertEqual(deletedCount, 1)
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<BibleBookmark>()).compactMap(\.book).sorted(), ["Matthew"])
    }

    /**
     Verifies deleting a generic bookmark row persists without touching Bible bookmarks.

     Setup:
     - persists one Bible bookmark and one generic bookmark into the same context
     - deletes only the generic projection row

     Expected result:
     - the generic bookmark is gone after refetch
     - the Bible bookmark remains intact

     Failure meaning:
     - generic bookmark deletion can be coupled to Bible bookmark rows or fail to save.
     */
    func testBookmarkListMutationDeletesGenericBookmarkWithoutRemovingBibleRows() throws {
        let container = try makeBookmarkListModelContainer()
        let modelContext = ModelContext(container)
        let bibleBookmark = persistedBibleBookmark(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000011")!,
            book: "Genesis",
            ordinal: 1
        )
        let genericBookmark = GenericBookmark(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000012")!,
            key: "Entry 1",
            bookInitials: "UITESTDICT",
            createdAt: Date(timeIntervalSince1970: 2),
            ordinalStart: 2,
            ordinalEnd: 2,
            lastUpdatedOn: Date(timeIntervalSince1970: 2)
        )
        modelContext.insert(bibleBookmark)
        modelContext.insert(genericBookmark)
        try modelContext.save()

        let deletedCount = try BookmarkListMutation.deleteItems(
            [BookmarkListItem(genericBookmark: genericBookmark)],
            in: modelContext
        )

        XCTAssertEqual(deletedCount, 1)
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<BibleBookmark>()).compactMap(\.book), ["Genesis"])
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<GenericBookmark>()).isEmpty)
    }

    /**
     Builds a Bible bookmark projection row whose storage ordinals match its visible reference.

     Bookmark list rows now render, search, navigate, and sort from Android-compatible KJVA ordinals
     rather than the legacy display-name `book` field. Test fixtures therefore resolve the supplied
     reference through `JSwordKJVAVersification` so assertions exercise the same persisted contract as
     restored Android bookmarks.

     - Parameters:
       - reference: Human-readable `Book Chapter:Verse` reference covered by the KJVA table.
       - createdAt: Creation timestamp used by sort-order assertions.
       - labels: Labels that should appear assigned to the row.
     - Returns: A normalized Bible bookmark list item.
     - Side effects: assigns unsaved label relationship objects to the bookmark.
     - Failure modes: Records an XCTest failure and falls back to Genesis 1:1 when the reference
       cannot be parsed or resolved.
     */
    private func bibleItem(
        reference: String,
        createdAt: Date = Date(timeIntervalSince1970: 100),
        labels: [Label] = []
    ) -> BookmarkListItem {
        let ordinal = kjvaOrdinal(for: reference)
        let bookmark = BibleBookmark(
            kjvOrdinalStart: ordinal,
            kjvOrdinalEnd: ordinal,
            ordinalStart: ordinal,
            ordinalEnd: ordinal,
            createdAt: createdAt,
            lastUpdatedOn: createdAt
        )
        bookmark.book = reference
            .split(separator: " ")
            .dropLast()
            .joined(separator: " ")
        if !labels.isEmpty {
            bookmark.bookmarkToLabels = labels.map { label in
                let link = BibleBookmarkToLabel()
                link.bookmark = bookmark
                link.label = label
                return link
            }
        }

        return BookmarkListItem(bibleBookmark: bookmark) { _, _ in
            let chapterVerse = reference
                .split(separator: " ")
                .last?
                .split(separator: ":")
            guard let chapterText = chapterVerse?.first,
                  let verseText = chapterVerse?.last,
                  let chapter = Int(chapterText),
                  let verse = Int(verseText)
            else {
                return nil
            }
            return BookmarkListVerseReference(chapter: chapter, verse: verse)
        }
    }

    /**
     Resolves a compact display reference into the JSword KJVA ordinal expected by bookmark storage.

     - Parameter reference: Human-readable `Book Chapter:Verse` reference, using JSword long or short
       book names from the KJVA table.
     - Returns: The resolved KJVA verse ordinal, or Genesis 1:1 after recording a test failure.
     - Side effects: May record an XCTest failure when fixture text drifts from the KJVA contract.
     - Failure modes: Malformed references, unknown books, and out-of-range chapter/verse values fail
       the current test and use Genesis 1:1 so the suite can report the original assertion context.
     */
    private func kjvaOrdinal(for reference: String) -> Int {
        guard let separator = reference.lastIndex(of: " ") else {
            XCTFail("Malformed Bible reference fixture: \(reference)")
            return 4
        }
        let bookName = String(reference[..<separator])
        let chapterVerse = reference[reference.index(after: separator)...].split(separator: ":")
        guard chapterVerse.count == 2,
              let chapter = Int(chapterVerse[0]),
              let verse = Int(chapterVerse[1]) else {
            XCTFail("Malformed Bible reference fixture: \(reference)")
            return 4
        }
        guard let osisId = JSwordKJVAVersification.books.first(where: {
            $0.longName == bookName || $0.shortName == bookName || $0.osisId == bookName
        })?.osisId,
              let ordinal = JSwordKJVAVersification.verseOrdinal(
                osisId: osisId,
                chapter: chapter,
                verse: verse
              ) else {
            XCTFail("Unresolvable KJVA reference fixture: \(reference)")
            return 4
        }
        return ordinal
    }

    /**
     Builds a generic bookmark projection row with optional label assignments.

     - Parameters:
       - module: Generic document initials.
       - key: Generic document key.
       - labels: Labels that should appear assigned to the row.
     - Returns: A normalized generic bookmark list item.
     - Side effects: assigns unsaved label relationship objects to the bookmark.
     - Failure modes: This helper cannot fail.
     */
    private func genericItem(
        module: String,
        key: String,
        labels: [Label] = []
    ) -> BookmarkListItem {
        let bookmark = GenericBookmark(
            key: key,
            bookInitials: module,
            createdAt: Date(timeIntervalSince1970: 100),
            ordinalStart: 1,
            ordinalEnd: 1,
            lastUpdatedOn: Date(timeIntervalSince1970: 100)
        )
        if !labels.isEmpty {
            bookmark.bookmarkToLabels = labels.map { label in
                let link = GenericBookmarkToLabel()
                link.bookmark = bookmark
                link.label = label
                return link
            }
        }
        return BookmarkListItem(genericBookmark: bookmark)
    }

    /**
     Builds a persisted Bible bookmark fixture.

     - Parameters:
       - id: Stable identifier for assertions.
       - book: Display book name stored on the bookmark.
       - ordinal: Source and KJVA ordinal for the one-verse fixture.
     - Returns: A `BibleBookmark` ready for insertion into a test model context.
     - Side effects: assigns the bookmark book name.
     - Failure modes: This helper cannot fail.
     */
    private func persistedBibleBookmark(id: UUID, book: String, ordinal: Int) -> BibleBookmark {
        let bookmark = BibleBookmark(
            id: id,
            kjvOrdinalStart: ordinal,
            kjvOrdinalEnd: ordinal,
            ordinalStart: ordinal,
            ordinalEnd: ordinal,
            v11n: "KJVA",
            createdAt: Date(timeIntervalSince1970: TimeInterval(ordinal)),
            lastUpdatedOn: Date(timeIntervalSince1970: TimeInterval(ordinal))
        )
        bookmark.book = book
        return bookmark
    }
}
