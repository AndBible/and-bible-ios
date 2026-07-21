import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/**
 Android bookmark CSV interoperability coverage for structured encoding and atomic persistence.

 These tests use the same semicolon column contract as Android's `BookmarkCsvUtils` and real
 in-memory SwiftData relationships. They protect quoting, Unicode, label handling, UUID merge
 semantics, and fail-closed imports without relying on picker UI.
 */
final class AndroidBookmarkCSVTransferTests: XCTestCase {
    /**
     Verifies Android CSV survives a BOM plus Unicode, delimiters, quotes, and embedded newlines.

     Setup:
     - creates a verified John 3:16 bookmark with a Unicode label and multiline note
     - encodes through the production writer and imports a BOM-prefixed copy into a fresh store

     Expected result:
     - writer uses doubled quotes around the structured multiline field
     - imported ordinals, module initials, note text, and label name match exactly

     Failure meaning:
     - iOS exports cannot round-trip through Android-compatible CSV, or the parser splits quoted
       semicolons/newlines into malformed rows.
     */
    @MainActor
    func testCSVWriterAndImporterRoundTripBOMUnicodeQuotesAndNewlines() throws {
        let sourceContainer = try makeBookmarkRestoreModelContainer()
        let sourceContext = ModelContext(sourceContainer)
        let ordinal = try XCTUnwrap(
            JSwordKJVAVersification.verseOrdinal(osisId: "John", chapter: 3, verse: 16)
        )
        let noteText = "Café; \"quoted\"\nsecond line"
        let bookmark = verifiedBookmark(
            id: UUID(uuidString: "a1000000-0000-0000-0000-000000000001")!,
            ordinal: ordinal,
            moduleInitials: "KJV"
        )
        attachNote(noteText, to: bookmark, in: sourceContext)
        attachLabel(named: "Étude personnelle", to: bookmark, in: sourceContext)
        sourceContext.insert(bookmark)
        try sourceContext.save()

        let encoded = try AndroidBookmarkCSVCodec.encode(bookmarks: [bookmark])
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(encodedText.contains(#""Café; ""quoted"""#))
        XCTAssertTrue(encodedText.contains("\nsecond line\""))

        var prefixed = Data([0xEF, 0xBB, 0xBF])
        prefixed.append(encoded)
        let destinationContainer = try makeBookmarkRestoreModelContainer()
        let destinationContext = ModelContext(destinationContainer)
        let result = try AndroidBookmarkCSVTransferService(
            modelContext: destinationContext
        ).importCSV(prefixed)

        XCTAssertEqual(result, .init(created: 1, updated: 0))
        let imported = try XCTUnwrap(destinationContext.fetch(FetchDescriptor<BibleBookmark>()).first)
        XCTAssertEqual(imported.id, bookmark.id)
        XCTAssertEqual(imported.kjvOrdinalStart, ordinal)
        XCTAssertEqual(imported.bookInitials, "KJV")
        XCTAssertEqual(imported.notes?.notes, noteText)
        XCTAssertEqual(imported.bookmarkToLabels?.compactMap(\.label?.name), ["Étude personnelle"])
        XCTAssertTrue(imported.hasTrustedPersistedOrdinals)
    }

    /**
     Verifies UUID merge/create and exact-name label reuse occur in one successful import.

     Setup:
     - persists an existing bookmark and an existing `Shared` label
     - exports an update for that UUID plus a second new bookmark
     - assigns `Shared` and `Added` to the updated source row

     Expected result:
     - summary reports one update and one creation
     - the existing label is reused, the missing label is created once, and notes are replaced

     Failure meaning:
     - imports duplicate labels, append instead of replacing Android memberships, or create a
       duplicate bookmark instead of merging by UUID.
     */
    @MainActor
    func testCSVImportMergesUUIDCreatesMissingRowAndReconcilesLabels() throws {
        let destinationContainer = try makeBookmarkRestoreModelContainer()
        let destinationContext = ModelContext(destinationContainer)
        let existingID = UUID(uuidString: "a2000000-0000-0000-0000-000000000001")!
        let existing = verifiedBookmark(id: existingID, ordinal: 4, moduleInitials: "OLD")
        let shared = Label(name: " Shared ")
        destinationContext.insert(existing)
        destinationContext.insert(shared)
        try destinationContext.save()

        let sourceContainer = try makeBookmarkRestoreModelContainer()
        let sourceContext = ModelContext(sourceContainer)
        let updated = verifiedBookmark(id: existingID, ordinal: 5, moduleInitials: "KJV")
        let created = verifiedBookmark(
            id: UUID(uuidString: "a2000000-0000-0000-0000-000000000002")!,
            ordinal: 6,
            moduleInitials: "KJV"
        )
        attachNote("replacement", to: updated, in: sourceContext)
        attachLabel(named: "Shared", to: updated, in: sourceContext)
        attachLabel(named: "Added", to: updated, in: sourceContext)
        sourceContext.insert(updated)
        sourceContext.insert(created)
        try sourceContext.save()

        let data = try AndroidBookmarkCSVCodec.encode(bookmarks: [updated, created])
        let result = try AndroidBookmarkCSVTransferService(
            modelContext: destinationContext
        ).importCSV(data)

        XCTAssertEqual(result, .init(created: 1, updated: 1))
        let bookmarks = try destinationContext.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bookmarks.count, 2)
        let merged = try XCTUnwrap(bookmarks.first { $0.id == existingID })
        XCTAssertEqual(merged.kjvOrdinalStart, 5)
        XCTAssertEqual(merged.bookInitials, "KJV")
        XCTAssertEqual(merged.notes?.notes, "replacement")
        XCTAssertEqual(
            Set(merged.bookmarkToLabels?.compactMap(\.label?.name) ?? []),
            Set(["Added", " Shared "])
        )
        XCTAssertEqual(merged.bookmarkToLabels?.first { $0.label?.name == " Shared " }?.label?.id, shared.id)
        let labels = try destinationContext.fetch(FetchDescriptor<Label>())
        XCTAssertEqual(labels.filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == "Shared" }.count, 1)
        XCTAssertEqual(labels.filter { $0.name == "Added" }.count, 1)
    }

    /**
     Verifies Android's asymmetric omitted-column update behavior for notes and labels.

     Android always updates bookmark notes on a UUID merge, so an omitted notes column clears the
     old note. Label assignment only runs for a non-empty labels value, so an omitted or empty labels
     field preserves existing membership.

     Failure meaning:
     - importing an Android subset export can retain notes Android would clear or erase labels
       Android deliberately leaves attached.
     */
    @MainActor
    func testCSVUpdateWithoutNotesClearsNoteButEmptyLabelsPreserveMembership() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let context = ModelContext(container)
        let id = UUID(uuidString: "a2500000-0000-0000-0000-000000000001")!
        let existing = verifiedBookmark(id: id, ordinal: 4, moduleInitials: "KJV")
        context.insert(existing)
        attachNote("remove me", to: existing, in: context)
        attachLabel(named: "Keep", to: existing, in: context)
        try context.save()
        let csv = """
        ordinalStart;ordinalEnd;id;labels
        5;5;\(id.uuidString);
        """

        let result = try AndroidBookmarkCSVTransferService(
            modelContext: context
        ).importCSV(Data(csv.utf8))

        XCTAssertEqual(result, .init(created: 0, updated: 1))
        let updated = try XCTUnwrap(context.fetch(FetchDescriptor<BibleBookmark>()).first)
        XCTAssertNil(updated.notes)
        XCTAssertEqual(updated.bookmarkToLabels?.compactMap(\.label?.name), ["Keep"])
    }

    /**
     Verifies one malformed row rejects the complete document before the first valid row mutates.

     Failure meaning:
     - CSV import can leave a partially applied database when a later record has an invalid UUID.
     */
    @MainActor
    func testCSVImportRejectsMalformedLaterRowAtomically() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let context = ModelContext(container)
        let csv = """
        ordinalStart;ordinalEnd;id;notes
        4;4;a3000000-0000-0000-0000-000000000001;valid
        5;5;not-a-uuid;invalid
        """

        XCTAssertThrowsError(
            try AndroidBookmarkCSVTransferService(modelContext: context).importCSV(Data(csv.utf8))
        ) { error in
            guard case AndroidBookmarkCSVError.invalidIdentifier(record: 3, value: "not-a-uuid") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<BibleBookmark>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Label>()).isEmpty)
    }

    /**
     Verifies duplicate UUID rows are rejected before an existing bookmark can be overwritten.

     Failure meaning:
     - row order can silently decide which duplicate wins, violating deterministic atomic merge
       semantics and making malformed transfer files destructive.
     */
    @MainActor
    func testCSVImportRejectsDuplicateUUIDWithoutChangingExistingBookmark() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let context = ModelContext(container)
        let id = UUID(uuidString: "a4000000-0000-0000-0000-000000000001")!
        let existing = verifiedBookmark(id: id, ordinal: 4, moduleInitials: "ORIGINAL")
        context.insert(existing)
        try context.save()
        let csv = """
        ordinalStart;ordinalEnd;id;document
        5;5;\(id.uuidString);FIRST
        6;6;\(id.uuidString);SECOND
        """

        XCTAssertThrowsError(
            try AndroidBookmarkCSVTransferService(modelContext: context).importCSV(Data(csv.utf8))
        ) { error in
            XCTAssertEqual(error as? AndroidBookmarkCSVError, .duplicateBookmarkID(id))
        }
        let persisted = try XCTUnwrap(context.fetch(FetchDescriptor<BibleBookmark>()).first)
        XCTAssertEqual(persisted.kjvOrdinalStart, 4)
        XCTAssertEqual(persisted.bookInitials, "ORIGINAL")
    }

    /** Builds one verified KJVA bookmark suitable for navigation and CSV export fixtures. */
    private func verifiedBookmark(id: UUID, ordinal: Int, moduleInitials: String) -> BibleBookmark {
        BibleBookmark(
            id: id,
            kjvOrdinalStart: ordinal,
            kjvOrdinalEnd: ordinal,
            ordinalStart: ordinal,
            ordinalEnd: ordinal,
            v11n: JSwordKJVAVersification.name,
            bookInitials: moduleInitials,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUpdatedOn: Date(timeIntervalSince1970: 1_700_000_100),
            ordinalTrustMetadata: PersistedOrdinalTrustPolicy.androidImportMetadata(
                sourceVersification: JSwordKJVAVersification.name,
                sourceOrdinalStart: ordinal,
                sourceOrdinalEnd: ordinal,
                kjvaOrdinalStart: ordinal,
                kjvaOrdinalEnd: ordinal
            )
        )
    }

    /** Attaches one persisted note relationship to a bookmark fixture. */
    private func attachNote(_ text: String, to bookmark: BibleBookmark, in context: ModelContext) {
        let note = BibleBookmarkNotes(bookmarkId: bookmark.id, notes: text)
        note.bookmark = bookmark
        bookmark.notes = note
        context.insert(note)
    }

    /** Attaches one exact-name label relationship to a bookmark fixture. */
    private func attachLabel(
        named name: String,
        to bookmark: BibleBookmark,
        in context: ModelContext
    ) {
        let label = Label(name: name)
        let link = BibleBookmarkToLabel()
        link.bookmark = bookmark
        link.label = label
        bookmark.bookmarkToLabels = (bookmark.bookmarkToLabels ?? []) + [link]
        context.insert(label)
        context.insert(link)
    }
}
