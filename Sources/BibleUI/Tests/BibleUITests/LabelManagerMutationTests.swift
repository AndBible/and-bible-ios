import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 App-host-free coverage for the deletion boundary shared by Manage Labels and Label Edit.

 Creation, editing, favourites, and workspace configuration now use
 `WorkspaceLabelConfigurationService` directly and are covered in BibleCore. This suite retains the
 UI-module deletion bridge contract used to build Android's orphan confirmation and apply its choice.
 */
final class LabelManagerMutationTests: XCTestCase {
    /**
     Verifies Label Manager deletion uses the bookmark-safe relationship cleanup path.

     Setup:
     - creates one label assigned to both a Bible bookmark and a generic bookmark
     - marks the label as each bookmark's primary label
     - deletes the label through `LabelManagerMutation`, the same bridge used by the app-owned full
       editor after its explicit orphan confirmation

     Expected result:
     - the label row is removed
     - both bookmark-to-label junction tables are cleared
     - both bookmark primary-label references are nil

     Failure meaning:
     - removing a label from the visible Label Manager would leave Android-incompatible orphaned
       bookmark relationships even if the row disappears from the UI.
     */
    func testLabelManagerMutationDeletesLabelAndDetachesBookmarks() throws {
        let modelContext = ModelContext(try makeBookmarkListModelContainer())
        let label = Label(name: "Prayer")

        let bibleBookmark = BibleBookmark(
            kjvOrdinalStart: 1,
            kjvOrdinalEnd: 1,
            ordinalStart: 1,
            ordinalEnd: 1,
            v11n: "KJVA"
        )
        bibleBookmark.primaryLabelId = label.id
        let bibleLink = BibleBookmarkToLabel(orderNumber: 0, indentLevel: 0, expandContent: false)
        bibleLink.bookmark = bibleBookmark
        bibleLink.label = label
        bibleBookmark.bookmarkToLabels = [bibleLink]

        let genericBookmark = GenericBookmark(key: "entry", bookInitials: "DICT")
        genericBookmark.primaryLabelId = label.id
        let genericLink = GenericBookmarkToLabel(orderNumber: 1, indentLevel: 0, expandContent: true)
        genericLink.bookmark = genericBookmark
        genericLink.label = label
        genericBookmark.bookmarkToLabels = [genericLink]

        modelContext.insert(label)
        modelContext.insert(bibleBookmark)
        modelContext.insert(bibleLink)
        modelContext.insert(genericBookmark)
        modelContext.insert(genericLink)
        try modelContext.save()

        try LabelManagerMutation.deleteLabel(label, in: modelContext)

        let verificationContext = ModelContext(modelContext.container)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<Label>()).isEmpty)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<BibleBookmarkToLabel>()).isEmpty)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<GenericBookmarkToLabel>()).isEmpty)

        let reloadedBibleBookmark = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<BibleBookmark>()).first
        )
        XCTAssertNil(reloadedBibleBookmark.primaryLabelId)
        XCTAssertTrue(reloadedBibleBookmark.bookmarkToLabels?.isEmpty ?? true)

        let reloadedGenericBookmark = try XCTUnwrap(
            try verificationContext.fetch(FetchDescriptor<GenericBookmark>()).first
        )
        XCTAssertNil(reloadedGenericBookmark.primaryLabelId)
        XCTAssertTrue(reloadedGenericBookmark.bookmarkToLabels?.isEmpty ?? true)
    }
}
