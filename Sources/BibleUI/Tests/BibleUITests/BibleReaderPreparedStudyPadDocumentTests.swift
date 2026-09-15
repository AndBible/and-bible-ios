// BibleReaderPreparedStudyPadDocumentTests.swift -- StudyPad immutable preparation contracts

import Foundation
import XCTest
@testable import BibleUI
@testable import BibleView

final class BibleReaderPreparedStudyPadDocumentTests: XCTestCase {
    /** The worker encoder preserves the existing journal payload and excludes separate events. */
    func testEncodedDocumentPreservesStudyPadCollections() throws {
        let labelID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let label = makeLabel(id: labelID, color: 23)
        let entry = makeEntry(labelID: labelID, text: "First line", orderNumber: 4)
        let relation = BookmarkToLabelData(
            bookmarkId: "bookmark",
            labelId: labelID.uuidString,
            orderNumber: 3,
            indentLevel: 1,
            expandContent: false,
            type: "BibleBookmarkToLabel"
        )
        let prepared = BibleReaderPreparedStudyPadDocument(
            labelID: labelID,
            displayName: "Study",
            jumpToID: "o-42",
            sourceDependencies: [.independent],
            label: label,
            bookmarkInputs: [],
            bookmarks: [],
            genericBookmarkInputs: [],
            genericBookmarks: [],
            bookmarkToLabels: [relation],
            genericBookmarkToLabels: [],
            journalTextEntries: [entry],
            labels: [label]
        )

        let json = try XCTUnwrap(prepared.encodedJSON())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let encodedEntry = try XCTUnwrap(
            (object["journalTextEntries"] as? [[String: Any]])?.first
        )
        let encodedRelation = try XCTUnwrap(
            (object["bookmarkToLabels"] as? [[String: Any]])?.first
        )

        XCTAssertEqual(object["id"] as? String, "journal_\(labelID.uuidString)")
        XCTAssertEqual(object["type"] as? String, "journal")
        XCTAssertEqual((object["label"] as? [String: Any])?["name"] as? String, "Study")
        XCTAssertEqual(encodedEntry["text"] as? String, "First line")
        XCTAssertEqual(encodedEntry["orderNumber"] as? Int, 4)
        XCTAssertEqual(encodedRelation["indentLevel"] as? Int, 1)
        XCTAssertNil(object["labels"])
        XCTAssertNil(object["jumpToId"])
    }

    /** Direct entry, style, and setup mutations each invalidate a prepared StudyPad result. */
    func testOwnerIdentityRejectsStaleRowsLabelsAndSetup() throws {
        let labelID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let label = makeLabel(id: labelID, color: 23)
        let baseline = makePrepared(
            labelID: labelID,
            label: label,
            entry: makeEntry(labelID: labelID, text: "Before", orderNumber: 1),
            labels: [label],
            jumpToID: "o-1"
        )
        let changedEntry = makePrepared(
            labelID: labelID,
            label: label,
            entry: makeEntry(labelID: labelID, text: "After", orderNumber: 1),
            labels: [label],
            jumpToID: "o-1"
        )
        let changedLabel = makePrepared(
            labelID: labelID,
            label: label,
            entry: makeEntry(labelID: labelID, text: "Before", orderNumber: 1),
            labels: [makeLabel(id: labelID, color: 29)],
            jumpToID: "o-1"
        )
        let changedSetup = makePrepared(
            labelID: labelID,
            label: label,
            entry: makeEntry(labelID: labelID, text: "Before", orderNumber: 1),
            labels: [label],
            jumpToID: "o-2"
        )

        XCTAssertNotEqual(baseline.ownerIdentity, changedEntry.ownerIdentity)
        XCTAssertNotEqual(baseline.ownerIdentity, changedLabel.ownerIdentity)
        XCTAssertNotEqual(baseline.ownerIdentity, changedSetup.ownerIdentity)
    }

    /** Canonically equivalent entry and label text retain exact Android UTF-16 identity. */
    func testOwnerIdentityPreservesExactUTF16EntryAndLabelValues() throws {
        let labelID = try XCTUnwrap(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "The fixture must exercise Swift's canonical equality.")
        let composedLabel = makeLabel(id: labelID, color: 23, name: composed)
        let decomposedLabel = makeLabel(id: labelID, color: 23, name: decomposed)

        let baseline = makePrepared(
            labelID: labelID,
            label: composedLabel,
            entry: makeEntry(labelID: labelID, text: composed, orderNumber: 1),
            labels: [composedLabel],
            jumpToID: "o-1"
        )
        let changedEntry = makePrepared(
            labelID: labelID,
            label: composedLabel,
            entry: makeEntry(labelID: labelID, text: decomposed, orderNumber: 1),
            labels: [composedLabel],
            jumpToID: "o-1"
        )
        let changedLabel = makePrepared(
            labelID: labelID,
            label: decomposedLabel,
            entry: makeEntry(labelID: labelID, text: composed, orderNumber: 1),
            labels: [decomposedLabel],
            jumpToID: "o-1"
        )

        XCTAssertNotEqual(baseline.ownerIdentity, changedEntry.ownerIdentity)
        XCTAssertNotEqual(baseline.ownerIdentity, changedLabel.ownerIdentity)
    }

    /** Builds a minimal immutable StudyPad request for exact-identity comparisons. */
    private func makePrepared(
        labelID: UUID,
        label: LabelData,
        entry: StudyPadTextItemData,
        labels: [LabelData],
        jumpToID: String?
    ) -> BibleReaderPreparedStudyPadDocument {
        BibleReaderPreparedStudyPadDocument(
            labelID: labelID,
            displayName: "Study",
            jumpToID: jumpToID,
            sourceDependencies: [.independent],
            label: label,
            bookmarkInputs: [],
            bookmarks: [],
            genericBookmarkInputs: [],
            genericBookmarks: [],
            bookmarkToLabels: [],
            genericBookmarkToLabels: [],
            journalTextEntries: [entry],
            labels: labels
        )
    }

    /** Creates one label payload with an explicit persisted identity and style. */
    private func makeLabel(id: UUID, color: Int, name: String = "Study") -> LabelData {
        LabelData(
            id: id.uuidString,
            name: name,
            style: BookmarkStyleData(color: color),
            isRealLabel: true
        )
    }

    /** Creates one typed text row whose body and order are independently mutable test inputs. */
    private func makeEntry(
        labelID: UUID,
        text: String,
        orderNumber: Int
    ) -> StudyPadTextItemData {
        StudyPadTextItemData(
            id: "entry",
            type: "journal",
            hashCode: 7,
            labelId: labelID.uuidString,
            text: text,
            contentType: "MARKDOWN",
            orderNumber: orderNumber,
            indentLevel: 0
        )
    }
}
