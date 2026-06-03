import XCTest
import AVFoundation
@testable import BibleCore
import CLibSword
@testable import SwordKit
import SwiftData
import SQLite3
@testable import BibleUI
@testable import BibleView
import struct SwiftUI.Binding
import enum SwiftUI.ColorScheme
import struct SwiftUI.EdgeInsets
import struct SwiftUI.EmptyView
#if os(iOS)
import UIKit
import WebKit
import struct SwiftUI.Color
#endif

extension AndBibleTests {
    /**
     Verifies that bookmark-label serialization falls back to the synthetic unlabeled payload when
     a relationship still points at a deleted in-memory label object.
     *
     * Data dependencies:
     * - creates an in-memory bookmark schema with one Bible bookmark, one label, and one junction
     *   row
     *
     * Side effects:
     * - inserts and saves live bookmark data
     * - deletes the label in the same `ModelContext` without first detaching the junction row so
     *   the helper sees the stale relationship shape that previously crashed the reader
     *
     * Failure modes:
     * - throws if the in-memory SwiftData container cannot be created or saved
     * - fails if serialization no longer produces an unlabeled fallback for the deleted relation
     */
    func testBookmarkLabelSerializationSkipsDeletedBibleLabels() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)

        let label = Label(name: "Temp")
        let bookmark = BibleBookmark(
            kjvOrdinalStart: 1,
            kjvOrdinalEnd: 1,
            ordinalStart: 1,
            ordinalEnd: 1,
            v11n: "KJVA"
        )
        bookmark.primaryLabelId = label.id

        let link = BibleBookmarkToLabel(orderNumber: 3, indentLevel: 1, expandContent: true)
        link.bookmark = bookmark
        link.label = label
        bookmark.bookmarkToLabels = [link]

        modelContext.insert(label)
        modelContext.insert(bookmark)
        modelContext.insert(link)
        try modelContext.save()

        modelContext.delete(label)

        let payload = BookmarkLabelSerializationSupport.biblePayload(
            bookmarkID: bookmark.id,
            links: bookmark.bookmarkToLabels,
            unlabeledLabelID: "UNLABELED"
        )

        XCTAssertEqual(payload.labelIDs, ["UNLABELED"])
        XCTAssertEqual(payload.relationItems.count, 1)
        XCTAssertEqual(payload.relationItems.first?.labelId, "UNLABELED")
        XCTAssertEqual(payload.relationItems.first?.type, "BibleBookmarkToLabel")
        XCTAssertEqual(
            BookmarkLabelSerializationSupport.primaryLabelID(
                primaryLabelID: bookmark.primaryLabelId,
                validLabelIDs: payload.labelIDs
            ),
            nil
        )
    }

    #if os(iOS)
    @MainActor
    func testReaderBookmarkBridgeUpdateEmitsTypedPayloadShape() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        let controller = BibleReaderController(bridge: bridge)
        controller.bookmarkService = bookmarkService

        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            wholeVerse: true
        )
        bookmark.book = "Genesis"
        bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "Quoted \"note\"\nsecond line")

        controller.refreshBookmarkInVueJS(bookmarkId: bookmark.id)

        let payloadJSON = try bridgeEmissionPayloadJSON(
            from: recordedScripts(),
            event: "add_or_update_bookmarks"
        )
        assertBridgeJSONIntegerField("createdAt", in: payloadJSON)
        assertBridgeJSONIntegerField("lastUpdatedOn", in: payloadJSON)

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_or_update_bookmarks") as? [[String: Any]]
        )
        let bookmarkObject = try XCTUnwrap(payload.first)
        XCTAssertEqual(bookmarkObject["type"] as? String, "bookmark")
        XCTAssertEqual(bookmarkObject["notes"] as? String, "Quoted \"note\"\nsecond line")
        XCTAssertEqual(bookmarkObject["hasNote"] as? Bool, true)
        XCTAssertTrue(bookmarkObject["offsetRange"] is NSNull)
        XCTAssertTrue(bookmarkObject["primaryLabelId"] is NSNull)
        XCTAssertTrue(bookmarkObject["customIcon"] is NSNull)
        XCTAssertTrue(bookmarkObject["osisFragment"] is NSNull)
        XCTAssertEqual(bookmarkObject["labels"] as? [String], [Label.unlabeledId.uuidString])

        let editAction = try XCTUnwrap(bookmarkObject["editAction"] as? [String: Any])
        XCTAssertTrue(editAction["mode"] is NSNull)
        XCTAssertTrue(editAction["content"] is NSNull)

        let relations = try XCTUnwrap(bookmarkObject["bookmarkToLabels"] as? [[String: Any]])
        let relation = try XCTUnwrap(relations.first)
        XCTAssertEqual(relation["type"] as? String, "BibleBookmarkToLabel")
        XCTAssertEqual(relation["bookmarkId"] as? String, bookmark.id.uuidString)
        XCTAssertEqual(relation["labelId"] as? String, Label.unlabeledId.uuidString)
    }

    @MainActor
    func testReaderStudyPadDocumentBridgeEmissionUsesTypedNestedPayloads() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        let controller = BibleReaderController(bridge: bridge)
        controller.bookmarkService = bookmarkService

        let label = bookmarkService.createLabel(name: "Study \"Notes\"", color: Label.defaultColor)
        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            wholeVerse: true
        )
        bookmark.book = "Genesis"
        _ = bookmarkService.toggleLabel(bookmarkId: bookmark.id, labelId: label.id)
        let genericBookmark = bookmarkService.addGenericBookmark(
            bookInitials: "DICT",
            key: "entry-key",
            startOrdinal: 2,
            endOrdinal: 2
        )
        _ = bookmarkService.toggleLabel(bookmarkId: genericBookmark.id, labelId: label.id)
        bookmarkService.saveBibleBookmarkNote(bookmarkId: genericBookmark.id, note: "Generic \"note\"")
        let createdEntry = try XCTUnwrap(
            bookmarkService.createStudyPadEntry(labelId: label.id, afterOrderNumber: -1)
        ).0
        bookmarkService.updateStudyPadTextEntryText(id: createdEntry.id, text: "Entry with \"quotes\"\nand newline")

        controller.bridgeDidSetClientReady(bridge)
        let scriptCount = recordedScripts().count
        controller.loadStudyPadDocument(labelId: label.id, bookmarkId: bookmark.id)
        let studyPadScripts = Array(recordedScripts().dropFirst(scriptCount))

        let payloadJSON = try bridgeEmissionPayloadJSON(
            from: studyPadScripts,
            event: "add_documents"
        )
        assertBridgeJSONIntegerField("createdAt", in: payloadJSON)
        assertBridgeJSONIntegerField("lastUpdatedOn", in: payloadJSON)

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(
                from: studyPadScripts,
                event: "add_documents"
            ) as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "journal")

        let labelObject = try XCTUnwrap(payload["label"] as? [String: Any])
        XCTAssertEqual(labelObject["name"] as? String, "Study \"Notes\"")
        let labelStyle = try XCTUnwrap(labelObject["style"] as? [String: Any])
        XCTAssertTrue(labelStyle["customIcon"] is NSNull)

        let bookmarks = try XCTUnwrap(payload["bookmarks"] as? [[String: Any]])
        let bookmarkObject = try XCTUnwrap(bookmarks.first)
        XCTAssertEqual(bookmarkObject["id"] as? String, bookmark.id.uuidString)
        XCTAssertTrue(bookmarkObject["primaryLabelId"] is NSNull)

        let genericBookmarks = try XCTUnwrap(payload["genericBookmarks"] as? [[String: Any]])
        let genericBookmarkObject = try XCTUnwrap(genericBookmarks.first)
        XCTAssertEqual(genericBookmarkObject["id"] as? String, genericBookmark.id.uuidString)
        XCTAssertEqual(genericBookmarkObject["type"] as? String, "generic-bookmark")
        XCTAssertEqual(genericBookmarkObject["notes"] as? String, "Generic \"note\"")
        XCTAssertTrue(genericBookmarkObject["primaryLabelId"] is NSNull)

        let relationships = try XCTUnwrap(payload["bookmarkToLabels"] as? [[String: Any]])
        let relationship = try XCTUnwrap(relationships.first)
        XCTAssertEqual(relationship["type"] as? String, "BibleBookmarkToLabel")
        XCTAssertEqual(relationship["labelId"] as? String, label.id.uuidString)

        let entries = try XCTUnwrap(payload["journalTextEntries"] as? [[String: Any]])
        let entryObject = try XCTUnwrap(entries.first)
        XCTAssertEqual(entryObject["id"] as? String, createdEntry.id.uuidString)
        XCTAssertEqual(entryObject["text"] as? String, "Entry with \"quotes\"\nand newline")
    }
    #endif

    /**
     Verifies that deleting a label clears bookmark junction rows and primary-label references
     before the label itself is removed.
     *
     * Data dependencies:
     * - creates an in-memory bookmark schema with one shared label attached to one Bible bookmark
     *   and one generic bookmark
     *
     * Side effects:
     * - persists the shared label, both bookmarks, and both bookmark-to-label junction rows
     * - deletes the label through `BookmarkService`, which should detach every affected bookmark
     *   relationship before saving
     *
     * Failure modes:
     * - throws if the in-memory SwiftData container cannot be created or saved
     * - fails if any relationship row or primary-label reference survives the label deletion
     */
    func testBookmarkServiceDeleteLabelDetachesBookmarkRelationships() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)

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

        bookmarkService.deleteLabel(id: label.id)

        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<Label>()).isEmpty)

        let reloadedBibleBookmark = try XCTUnwrap(
            try modelContext.fetch(FetchDescriptor<BibleBookmark>()).first
        )
        XCTAssertNil(reloadedBibleBookmark.primaryLabelId)
        XCTAssertTrue(reloadedBibleBookmark.bookmarkToLabels?.isEmpty ?? true)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<BibleBookmarkToLabel>()).isEmpty)

        let reloadedGenericBookmark = try XCTUnwrap(
            try modelContext.fetch(FetchDescriptor<GenericBookmark>()).first
        )
        XCTAssertNil(reloadedGenericBookmark.primaryLabelId)
        XCTAssertTrue(reloadedGenericBookmark.bookmarkToLabels?.isEmpty ?? true)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<GenericBookmarkToLabel>()).isEmpty)
    }

    /**
     Verifies that paragraph-break Bible bookmarks are persisted with the reserved system label.
     *
     * Data dependencies:
     * - creates an in-memory bookmark schema without pre-existing system labels
     *
     * Side effects:
     * - creates system labels and one Bible bookmark through `BookmarkService`
     *
     * Failure modes:
     * - throws if the in-memory SwiftData container cannot be created or queried
     * - fails if the bookmark is not linked to the paragraph-break label as its primary style label
     */
    func testBookmarkServiceCreatesParagraphBreakBibleBookmark() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)

        let bookmark = bookmarkService.addParagraphBreakBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            book: "Genesis"
        )

        let paragraphLabel = try XCTUnwrap(bookmarkService.label(id: Label.paragraphBreakLabelId))
        let reloadedBookmark = try XCTUnwrap(bookmarkService.bibleBookmark(id: bookmark.id))
        let link = try XCTUnwrap(
            bookmarkService.bibleBookmarkToLabel(
                bookmarkId: bookmark.id,
                labelId: Label.paragraphBreakLabelId
            )
        )

        XCTAssertEqual(paragraphLabel.name, Label.paragraphBreakLabelName)
        XCTAssertEqual(reloadedBookmark.book, "Genesis")
        XCTAssertFalse(reloadedBookmark.wholeVerse)
        XCTAssertEqual(reloadedBookmark.primaryLabelId, Label.paragraphBreakLabelId)
        XCTAssertEqual(link.bookmark?.id, bookmark.id)
        XCTAssertEqual(link.label?.id, Label.paragraphBreakLabelId)
        XCTAssertEqual(reloadedBookmark.bookmarkToLabels?.count, 1)
        XCTAssertEqual(reloadedBookmark.bookmarkToLabels?.first?.label?.id, Label.paragraphBreakLabelId)
    }

    /**
     Verifies that paragraph-break generic bookmarks use the same reserved label contract.
     *
     * Data dependencies:
     * - creates an in-memory bookmark schema without pre-existing system labels
     *
     * Side effects:
     * - creates system labels and one generic bookmark through `BookmarkService`
     *
     * Failure modes:
     * - throws if the in-memory SwiftData container cannot be created or queried
     * - fails if the generic bookmark does not carry the paragraph-break label relationship
     */
    func testBookmarkServiceCreatesParagraphBreakGenericBookmark() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)

        let bookmark = bookmarkService.addParagraphBreakGenericBookmark(
            bookInitials: "DICT",
            key: "entry-key",
            startOrdinal: 7,
            endOrdinal: 9
        )

        let reloadedBookmark = try XCTUnwrap(bookmarkService.genericBookmark(id: bookmark.id))
        let link = try XCTUnwrap(
            bookmarkService.genericBookmarkToLabel(
                bookmarkId: bookmark.id,
                labelId: Label.paragraphBreakLabelId
            )
        )

        XCTAssertEqual(reloadedBookmark.bookInitials, "DICT")
        XCTAssertEqual(reloadedBookmark.key, "entry-key")
        XCTAssertEqual(reloadedBookmark.ordinalStart, 7)
        XCTAssertEqual(reloadedBookmark.ordinalEnd, 9)
        XCTAssertFalse(reloadedBookmark.wholeVerse)
        XCTAssertEqual(reloadedBookmark.primaryLabelId, Label.paragraphBreakLabelId)
        XCTAssertEqual(link.bookmark?.id, bookmark.id)
        XCTAssertEqual(link.label?.id, Label.paragraphBreakLabelId)
        XCTAssertEqual(reloadedBookmark.bookmarkToLabels?.count, 1)
        XCTAssertEqual(reloadedBookmark.bookmarkToLabels?.first?.label?.id, Label.paragraphBreakLabelId)
    }

    /**
     Verifies that clearing a Bible bookmark note removes the persisted note row as well as the
     in-memory relationship.
     *
     * Data dependencies:
     * - creates an in-memory bookmark schema with one Bible bookmark and no pre-existing note row
     *
     * Side effects:
     * - writes one note through `BookmarkService`
     * - clears that note through `BookmarkService`, which should now save the context and delete
     *   the detached `BibleBookmarkNotes` row
     *
     * Failure modes:
     * - throws if the in-memory SwiftData container cannot be created or queried
     * - fails if the bookmark still resolves a note relationship or if orphaned note rows remain
     */
    func testBookmarkServiceClearingBibleBookmarkNoteDeletesPersistedNoteRow() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)

        let bookmark = BibleBookmark(
            kjvOrdinalStart: 1,
            kjvOrdinalEnd: 1,
            ordinalStart: 1,
            ordinalEnd: 1,
            v11n: "KJVA"
        )
        modelContext.insert(bookmark)
        try modelContext.save()

        bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "Seeded note")

        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<BibleBookmarkNotes>()).count, 1)

        let freshDeleteService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        freshDeleteService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: nil)

        let reloadedBookmark = try XCTUnwrap(
            try modelContext.fetch(FetchDescriptor<BibleBookmark>()).first
        )
        XCTAssertNil(reloadedBookmark.notes)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<BibleBookmarkNotes>()).isEmpty)
    }

    /**
     Verifies that saving a second Bible bookmark note replaces the persisted note text instead of
     creating a duplicate detached note row.
     *
     * Data dependencies:
     * - creates one in-memory Bible bookmark and no pre-existing note row
     *
     * Side effects:
     * - writes an initial note through `BookmarkService`
     * - writes a replacement note through a fresh `BookmarkService` instance bound to the same
     *   SwiftData context
     *
     * Failure modes:
     * - throws if the in-memory SwiftData container cannot be created or queried
     * - fails if the reloaded note text is not updated or if multiple detached note rows exist
     */
    func testBookmarkServiceUpdatingBibleBookmarkNoteReusesPersistedNoteRow() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)

        let bookmark = BibleBookmark(
            kjvOrdinalStart: 1,
            kjvOrdinalEnd: 1,
            ordinalStart: 1,
            ordinalEnd: 1,
            v11n: "KJVA"
        )
        modelContext.insert(bookmark)
        try modelContext.save()

        bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "Seeded note")
        let replacementService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        replacementService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "Updated note")

        let reloadedBookmark = try XCTUnwrap(
            try modelContext.fetch(FetchDescriptor<BibleBookmark>()).first
        )
        XCTAssertEqual(reloadedBookmark.notes?.notes, "Updated note")
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<BibleBookmarkNotes>()).count, 1)
    }

    /**
     Verifies that the My Notes rebuild query stops returning a bookmark after its note is deleted
     in the same live SwiftData context.
     *
     * Data dependencies:
     * - creates one in-memory `Genesis 1:1` Bible bookmark with a persisted note
     *
     * Side effects:
     * - loads the note-bearing bookmark through the same `bookmarks(for:endOrdinal:book:)` query
     *   that `BibleReaderController.loadMyNotesDocument()` uses
     * - clears the note through `BookmarkService`
     * - rebuilds the same bookmark query in the same context after deletion
     *
     * Failure modes:
     * - throws if the in-memory SwiftData container cannot be created or queried
     * - fails if the rebuild query still returns a note-bearing bookmark after deletion
     */
    func testBookmarkServiceClearingBibleBookmarkNoteRemovesBookmarkFromMyNotesQuery() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)

        let bookmark = BibleBookmark(
            kjvOrdinalStart: 1,
            kjvOrdinalEnd: 1,
            ordinalStart: 1,
            ordinalEnd: 1,
            v11n: "KJVA"
        )
        bookmark.book = "Genesis"
        modelContext.insert(bookmark)
        try modelContext.save()

        bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "Seeded note")

        let initialMyNotesBookmarks = bookmarkService
            .bookmarks(for: 1, endOrdinal: 40, book: "Genesis")
            .filter { $0.notes != nil && !($0.notes?.notes.isEmpty ?? true) }
        XCTAssertEqual(initialMyNotesBookmarks.map(\.id), [bookmark.id])

        bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: nil)

        let rebuiltMyNotesBookmarks = bookmarkService
            .bookmarks(for: 1, endOrdinal: 40, book: "Genesis")
            .filter { $0.notes != nil && !($0.notes?.notes.isEmpty ?? true) }
        XCTAssertTrue(rebuiltMyNotesBookmarks.isEmpty)
    }

    func testMyNotesAccessibilityStateCapsDetailedRowAndNoteTokens() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        let controller = BibleReaderController(bridge: BibleBridge())
        controller.bookmarkService = bookmarkService
        controller.navigateTo(book: "Psalms", chapter: 119, verse: 1)

        for verse in 1...60 {
            let ordinal = (119 - 1) * 40 + verse
            let bookmark = BibleBookmark(
                kjvOrdinalStart: ordinal,
                kjvOrdinalEnd: ordinal,
                ordinalStart: ordinal,
                ordinalEnd: ordinal,
                v11n: "KJVA"
            )
            bookmark.book = "Psalms"
            modelContext.insert(bookmark)
            try modelContext.save()
            bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "Note \(verse)")
        }

        let snapshot = controller.myNotesAccessibilitySnapshot

        XCTAssertEqual(snapshot.totalCount, 60)
        XCTAssertEqual(snapshot.rowReferenceTokens.count, UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
        XCTAssertEqual(snapshot.noteTokens.count, UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
        XCTAssertEqual(controller.myNotesAccessibilityState, snapshot.encodedValue)
    }

    /**
     Verifies that creating and editing one StudyPad entry persists its text payload in the backing
     SwiftData rows.
     *
     * Data dependencies:
     * - creates an in-memory bookmark schema with one real user label and no pre-existing StudyPad
     *   entries
     *
     * Side effects:
     * - creates one StudyPad entry after order `-1`
     * - updates the detached StudyPad text payload through a fresh `BookmarkService`
     *
     * Failure modes:
     * - throws if the in-memory SwiftData container cannot be created or queried
     * - fails if the created entry is missing, if its order number is wrong, or if the persisted
     *   text row does not contain the updated payload
     */
    func testBookmarkServiceCreateAndUpdateStudyPadEntryPersistsText() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)

        let label = bookmarkService.createLabel(name: "UI Test Seed", color: Label.defaultColor)
        let creation = try XCTUnwrap(
            bookmarkService.createStudyPadEntry(labelId: label.id, afterOrderNumber: -1)
        )
        XCTAssertEqual(creation.0.orderNumber, 0)

        let updateService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        updateService.updateStudyPadTextEntryText(id: creation.0.id, text: "Updated StudyPad note")
        try modelContext.save()

        let entries = try modelContext.fetch(FetchDescriptor<StudyPadTextEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.label?.id, label.id)

        let texts = try modelContext.fetch(FetchDescriptor<StudyPadTextEntryText>())
        XCTAssertEqual(texts.count, 1)
        XCTAssertEqual(texts.first?.text, "Updated StudyPad note")
    }

}
