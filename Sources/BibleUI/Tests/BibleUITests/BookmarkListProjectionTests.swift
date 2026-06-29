import XCTest
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
            ordinal: 81,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let matthew = bibleItem(
            reference: "Matthew 3:1",
            ordinal: 1_000,
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
        let exodus = bibleItem(reference: "Exodus 2:1", ordinal: 81)
        let matthew = bibleItem(reference: "Matthew 3:1", ordinal: 1_000)

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
            ordinal: 1,
            labels: [seedLabel]
        )
        let exodus = bibleItem(reference: "Exodus 2:1", ordinal: 81)

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

    private func bibleItem(
        reference: String,
        ordinal: Int,
        createdAt: Date = Date(timeIntervalSince1970: 100),
        labels: [Label] = []
    ) -> BookmarkListItem {
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
}
