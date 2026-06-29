import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 App-host-free coverage for Label Manager persistence mutations.

 These tests replace the heavyweight XCUITest create/rename/delete journey with direct SwiftData
 assertions against the same mutation helpers used by `LabelManagerView` and `LabelEditView`. The
 visible app UI keeps a route smoke, while this package suite owns the durable Android
 `ManageLabels` data contract beneath that route.
 */
final class LabelManagerMutationTests: XCTestCase {
    /**
     Verifies Label Manager creates only non-empty user labels and persists edit-screen saves.

     Setup:
     - creates an in-memory bookmark/label schema
     - invokes the same create helper used by `LabelManagerView`
     - mutates the label name as `LabelEditView` does through its bound model, then saves through
       the same edit persistence helper

     Expected result:
     - empty create submissions leave the label table untouched
     - a non-empty label is inserted once
     - the edited name is saved and refetchable by identifier

     Failure meaning:
     - the visible Label Manager route can open while silently failing to create labels or persist
       edits in the package-owned data model.
     */
    func testLabelManagerMutationCreatesAndPersistsEditedLabel() throws {
        let container = try makeBookmarkListModelContainer()
        let modelContext = ModelContext(container)

        XCTAssertNil(try LabelManagerMutation.createLabel(named: "", in: modelContext))
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<Label>()).isEmpty)

        let label = try XCTUnwrap(
            try LabelManagerMutation.createLabel(named: "L1", in: modelContext)
        )
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<Label>()).map(\.name), ["L1"])

        label.name = "L2"
        try LabelManagerMutation.persistLabelEdits(in: modelContext)

        let verifierContext = ModelContext(container)
        let targetId = label.id
        var descriptor = FetchDescriptor<Label>(
            predicate: #Predicate { $0.id == targetId }
        )
        descriptor.fetchLimit = 1
        let reloadedLabel = try XCTUnwrap(try verifierContext.fetch(descriptor).first)
        XCTAssertEqual(reloadedLabel.name, "L2")
    }

    /**
     Verifies Label Manager deletion uses the bookmark-safe relationship cleanup path.

     Setup:
     - creates one label assigned to both a Bible bookmark and a generic bookmark
     - marks the label as each bookmark's primary label
     - deletes the label through `LabelManagerMutation`, the same path used by the SwiftUI row
       swipe and context-menu delete actions

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

        LabelManagerMutation.deleteLabel(label, in: modelContext)

        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<Label>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<BibleBookmarkToLabel>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<GenericBookmarkToLabel>()).isEmpty)

        let reloadedBibleBookmark = try XCTUnwrap(
            try modelContext.fetch(FetchDescriptor<BibleBookmark>()).first
        )
        XCTAssertNil(reloadedBibleBookmark.primaryLabelId)
        XCTAssertTrue(reloadedBibleBookmark.bookmarkToLabels?.isEmpty ?? true)

        let reloadedGenericBookmark = try XCTUnwrap(
            try modelContext.fetch(FetchDescriptor<GenericBookmark>()).first
        )
        XCTAssertNil(reloadedGenericBookmark.primaryLabelId)
        XCTAssertTrue(reloadedGenericBookmark.bookmarkToLabels?.isEmpty ?? true)
    }
}
