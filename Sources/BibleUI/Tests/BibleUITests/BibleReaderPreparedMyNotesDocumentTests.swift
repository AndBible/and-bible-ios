// BibleReaderPreparedMyNotesDocumentTests.swift -- My Notes immutable preparation contracts

import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView

@MainActor
final class BibleReaderPreparedMyNotesDocumentTests: XCTestCase {
    /**
     A prepared source chapter emits its complete mapped KJVA span and heading.

     This serialization fixture represents a retained-source pseudo-document or synchronized target request.
     Explicit links map their selected verse before chapter expansion and need separate routing
     coverage; this test does not establish which ingress supplied the prepared reference.
     */
    func testEncodedDocumentUsesMappedCrossChapterReference() throws {
        let reference = try XCTUnwrap(
            MyNotesChapterReference(
                sourceVersification: "Vulg",
                sourceOSISBookId: "Ps",
                sourceChapter: 9,
                locale: Locale(identifier: "en")
            )
        )
        let bookmarkFixture = try makePersistedBookmark(note: "Mapped note")
        defer { withExtendedLifetime(bookmarkFixture) {} }
        let bookmark = bookmarkFixture.bookmark
        let input = BibleReaderPreparedBibleBookmarkInput(
            bookmark,
            unlabeledLabelID: "unlabelled"
        )
        let payload = makeBibleBookmarkPayload(
            id: bookmark.id.uuidString,
            note: "Mapped note",
            start: reference.kjvaOrdinalStart,
            end: reference.kjvaOrdinalEnd
        )
        let prepared = BibleReaderPreparedMyNotesDocument(
            reference: reference,
            sourceDependencies: [.independent],
            bookmarkInputs: [input],
            bookmarks: [payload],
            labels: [makeLabel(color: 17)],
            jumpToOrdinal: reference.kjvaOrdinalStart
        )

        let json = try XCTUnwrap(prepared.encodedJSON())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        XCTAssertEqual(object["id"] as? String, prepared.documentID)
        XCTAssertEqual(object["type"] as? String, "notes")
        XCTAssertEqual(object["verseRange"] as? String, "Psalms 9-10")
        XCTAssertEqual(object["ordinalRange"] as? [Int], [
            reference.kjvaOrdinalStart,
            reference.kjvaOrdinalEnd,
        ])
        XCTAssertEqual((object["bookmarks"] as? [[String: Any]])?.first?["notes"] as? String, "Mapped note")
        XCTAssertNil(object["labels"])
        XCTAssertNil(object["jumpToOrdinal"])
    }

    /** Direct note and offset mutations invalidate an in-flight snapshot without timestamp help. */
    func testOwnerIdentityRejectsDirectAnnotationMutationWithUnchangedTimestamp() throws {
        let reference = try XCTUnwrap(
            MyNotesChapterReference(
                sourceVersification: "KJV",
                sourceOSISBookId: "Gen",
                sourceChapter: 1,
                locale: Locale(identifier: "en")
            )
        )
        let bookmarkFixture = try makePersistedBookmark(note: "Before")
        defer { withExtendedLifetime(bookmarkFixture) {} }
        let bookmark = bookmarkFixture.bookmark
        bookmark.wholeVerse = false
        bookmark.startOffset = 1
        bookmark.endOffset = 4
        let timestamp = bookmark.lastUpdatedOn
        let captured = BibleReaderPreparedBibleBookmarkInput(
            bookmark,
            unlabeledLabelID: "unlabelled"
        )
        let first = BibleReaderPreparedMyNotesDocument(
            reference: reference,
            sourceDependencies: [.independent],
            bookmarkInputs: [captured],
            bookmarks: [makeBibleBookmarkPayload(id: bookmark.id.uuidString, note: "Before")],
            labels: [makeLabel(color: 17)],
            jumpToOrdinal: nil
        )

        bookmark.notes?.notes = "After"
        bookmark.startOffset = 2
        XCTAssertEqual(bookmark.lastUpdatedOn, timestamp)
        let recaptured = BibleReaderPreparedBibleBookmarkInput(
            bookmark,
            unlabeledLabelID: "unlabelled"
        )
        let second = BibleReaderPreparedMyNotesDocument(
            reference: reference,
            sourceDependencies: [.independent],
            bookmarkInputs: [recaptured],
            bookmarks: [makeBibleBookmarkPayload(id: bookmark.id.uuidString, note: "After")],
            labels: [makeLabel(color: 17)],
            jumpToOrdinal: nil
        )

        XCTAssertNotEqual(captured, recaptured)
        XCTAssertNotEqual(first.ownerIdentity, second.ownerIdentity)
    }

    /** Label styling participates in stale-result validation despite living outside document JSON. */
    func testOwnerIdentityIncludesSeparateLabelEventValues() throws {
        let reference = try XCTUnwrap(
            MyNotesChapterReference(
                sourceVersification: "KJV",
                sourceOSISBookId: "Gen",
                sourceChapter: 1
            )
        )
        let bookmarkFixture = try makePersistedBookmark(note: nil)
        defer { withExtendedLifetime(bookmarkFixture) {} }
        let bookmark = bookmarkFixture.bookmark
        let input = BibleReaderPreparedBibleBookmarkInput(bookmark, unlabeledLabelID: "unlabelled")
        let payload = makeBibleBookmarkPayload(id: bookmark.id.uuidString, note: nil)
        let first = BibleReaderPreparedMyNotesDocument(
            reference: reference,
            sourceDependencies: [.independent],
            bookmarkInputs: [input],
            bookmarks: [payload],
            labels: [makeLabel(color: 17)],
            jumpToOrdinal: nil
        )
        let second = BibleReaderPreparedMyNotesDocument(
            reference: reference,
            sourceDependencies: [.independent],
            bookmarkInputs: [input],
            bookmarks: [payload],
            labels: [makeLabel(color: 19)],
            jumpToOrdinal: nil
        )

        XCTAssertNotEqual(first.ownerIdentity, second.ownerIdentity)
    }

    /** Canonically equivalent source and note spellings remain distinct publication identities. */
    func testOwnerIdentityPreservesExactUTF16SourceAndNoteValues() throws {
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "The fixture must exercise Swift's canonical equality.")
        let reference = try XCTUnwrap(
            MyNotesChapterReference(
                sourceVersification: "KJV",
                sourceOSISBookId: "Gen",
                sourceChapter: 1
            )
        )
        let fixture = try makePersistedBookmark(note: composed)
        defer { withExtendedLifetime(fixture) {} }
        fixture.bookmark.v11n = "KJV"
        let baseline = BibleReaderPreparedMyNotesOwnerIdentity(
            reference: reference,
            bookmarks: [
                BibleReaderPreparedBibleBookmarkInput(
                    fixture.bookmark,
                    unlabeledLabelID: "unlabelled"
                ),
            ],
            labels: [],
            jumpToOrdinal: nil
        )

        fixture.bookmark.notes?.notes = decomposed
        let changedNote = BibleReaderPreparedMyNotesOwnerIdentity(
            reference: reference,
            bookmarks: [
                BibleReaderPreparedBibleBookmarkInput(
                    fixture.bookmark,
                    unlabeledLabelID: "unlabelled"
                ),
            ],
            labels: [],
            jumpToOrdinal: nil
        )

        fixture.bookmark.v11n = composed
        fixture.bookmark.notes?.notes = "note"
        let composedSource = BibleReaderPreparedMyNotesOwnerIdentity(
            reference: reference,
            bookmarks: [
                BibleReaderPreparedBibleBookmarkInput(
                    fixture.bookmark,
                    unlabeledLabelID: "unlabelled"
                ),
            ],
            labels: [],
            jumpToOrdinal: nil
        )
        fixture.bookmark.v11n = decomposed
        fixture.bookmark.notes?.notes = "note"
        let decomposedSource = BibleReaderPreparedMyNotesOwnerIdentity(
            reference: reference,
            bookmarks: [
                BibleReaderPreparedBibleBookmarkInput(
                    fixture.bookmark,
                    unlabeledLabelID: "unlabelled"
                ),
            ],
            labels: [],
            jumpToOrdinal: nil
        )

        XCTAssertNotEqual(baseline, changedNote)
        XCTAssertNotEqual(composedSource, decomposedSource)
    }

    /** An enriched row from another owner cannot be paired with the captured persistence input. */
    func testEncodedDocumentRejectsMismatchedEnrichedBookmarkIdentity() throws {
        let reference = try XCTUnwrap(
            MyNotesChapterReference(
                sourceVersification: "KJV",
                sourceOSISBookId: "Gen",
                sourceChapter: 1
            )
        )
        let bookmarkFixture = try makePersistedBookmark(note: nil)
        defer { withExtendedLifetime(bookmarkFixture) {} }
        let bookmark = bookmarkFixture.bookmark
        let prepared = BibleReaderPreparedMyNotesDocument(
            reference: reference,
            sourceDependencies: [.independent],
            bookmarkInputs: [
                BibleReaderPreparedBibleBookmarkInput(
                    bookmark,
                    unlabeledLabelID: "unlabelled"
                ),
            ],
            bookmarks: [makeBibleBookmarkPayload(id: UUID().uuidString, note: nil)],
            labels: [],
            jumpToOrdinal: nil
        )

        XCTAssertNil(prepared.encodedJSON())
    }

    /** Retains the in-memory owner for every model accessed by one test bookmark. */
    private struct PersistedBookmarkFixture {
        let container: ModelContainer
        let context: ModelContext
        let bookmark: BibleBookmark
    }

    /** Creates one attached bookmark graph using one authoritative relationship direction. */
    private func makePersistedBookmark(note: String?) throws -> PersistedBookmarkFixture {
        let container = try makeBookmarkListModelContainer()
        let context = ModelContext(container)
        let bookmark = BibleBookmark(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            kjvOrdinalStart: 4,
            kjvOrdinalEnd: 4,
            ordinalStart: 4,
            ordinalEnd: 4,
            v11n: "KJV",
            bookInitials: "KJV",
            createdAt: Date(timeIntervalSince1970: 10),
            lastUpdatedOn: Date(timeIntervalSince1970: 20),
            wholeVerse: true
        )
        bookmark.book = "Genesis"
        context.insert(bookmark)
        if let note {
            let notes = BibleBookmarkNotes(
                bookmarkId: bookmark.id,
                notes: note,
                contentType: "MARKDOWN"
            )
            context.insert(notes)
            notes.bookmark = bookmark
        }
        return PersistedBookmarkFixture(
            container: container,
            context: context,
            bookmark: bookmark
        )
    }

    /** Creates one fully shaped bookmark DTO after source enrichment. */
    private func makeBibleBookmarkPayload(
        id: String,
        note: String?,
        start: Int = 4,
        end: Int = 4
    ) -> BibleBookmarkData {
        BibleBookmarkData(
            id: id,
            type: "bookmark",
            hashCode: 1,
            ordinalRange: [start, end],
            offsetRange: nil,
            labels: ["unlabelled"],
            bookInitials: "KJV",
            bookName: "King James Version",
            bookAbbreviation: "KJV",
            createdAt: 10_000,
            text: "In the beginning",
            fullText: "In the beginning",
            bookmarkToLabels: [],
            primaryLabelId: nil,
            lastUpdatedOn: 20_000,
            notes: note,
            notesContentType: "MARKDOWN",
            hasNote: note != nil,
            wholeVerse: true,
            customIcon: nil,
            editAction: EditActionData(),
            osisRef: "Gen.1.1",
            originalOrdinalRange: [4, 4],
            verseRange: "Genesis 1:1",
            verseRangeOnlyNumber: "1:1",
            verseRangeAbbreviated: "Gen 1:1",
            v11n: "KJV",
            osisFragment: nil
        )
    }

    /** Creates a label DTO whose color is the only varying bridge-visible value. */
    private func makeLabel(color: Int) -> LabelData {
        LabelData(
            id: "label",
            name: "Notes",
            style: BookmarkStyleData(color: color),
            isRealLabel: true
        )
    }
}
