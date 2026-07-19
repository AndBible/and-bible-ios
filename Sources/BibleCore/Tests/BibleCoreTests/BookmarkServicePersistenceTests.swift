import SwiftData
import XCTest
@testable import BibleCore

/**
 Package-lane coverage for bookmark persistence contracts owned by BibleCore.

 These tests were migrated out of the app-host bundle so BookmarkService data-safety behavior
 runs without building or installing the application. They intentionally keep the Android
 bookmark database and StudyPad persistence contracts from the original app-host tests.
 */
final class BookmarkServicePersistenceTests: XCTestCase {

    /**
     Verifies the Android note-content default for bookmark notes saved below the bridge layer.
     Android persists `HTML` when no explicit note content type exists, so iOS service saves must
     produce an explicit `contentType` row instead of leaving notes format implicit forever.
     *
     * Data dependencies:
     * - creates one Bible bookmark and one generic bookmark in an in-memory bookmark schema
     *
     * Side effects:
     * - persists notes through `BookmarkService`
     *
     * Failure modes:
     * - fails if either note row omits `contentType` or stores a non-Android value
     */
    func testBookmarkServicePersistsDefaultHTMLContentTypeForNewBookmarkNotes() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))

        let bibleBookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            wholeVerse: true
        )
        let genericBookmark = bookmarkService.addGenericBookmark(
            bookInitials: "DICT",
            key: "entry-key",
            startOrdinal: 2,
            endOrdinal: 2
        )

        bookmarkService.saveBibleBookmarkNote(bookmarkId: bibleBookmark.id, note: "Bible note")
        bookmarkService.saveBibleBookmarkNote(bookmarkId: genericBookmark.id, note: "Generic note")

        let bibleNote = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<BibleBookmarkNotes>()).first)
        let genericNote = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<GenericBookmarkNotes>()).first)
        XCTAssertEqual(bibleNote.contentType, "HTML")
        XCTAssertEqual(genericNote.contentType, "HTML")
    }

    /**
     Verifies bookmark creation can persist Android-compatible KJVA ordinals separately from source
     module ordinals.
     *
     * Data dependencies:
     * - creates one in-memory Bible bookmark through `BookmarkService`
     *
     * Side effects:
     * - inserts and saves a `BibleBookmark`
     *
     * Failure modes:
     * - fails if the service collapses KJVA storage back to source ordinals, which would make
     *   restored and newly-created non-KJVA bookmarks drift from Android backup semantics.
     * - fails if source module initials are dropped into display-only fields.
     */
    func testBookmarkServicePersistsKJVAOrdinalsSeparatelyFromSourceOrdinals() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))

        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 10,
            endOrdinal: 12,
            kjvOrdinalStart: 20,
            kjvOrdinalEnd: 22,
            v11n: "KJV",
            wholeVerse: true
        )

        XCTAssertEqual(bookmark.ordinalStart, 10)
        XCTAssertEqual(bookmark.ordinalEnd, 12)
        XCTAssertEqual(bookmark.kjvOrdinalStart, 20)
        XCTAssertEqual(bookmark.kjvOrdinalEnd, 22)
        XCTAssertEqual(bookmark.v11n, "KJV")
        XCTAssertEqual(bookmark.bookInitials, "KJV")
    }

    /**
     Verifies restored Android bookmarks are found by KJVA overlap even when their `book` column is
     NULL or module initials.
     *
     * Data dependencies:
     * - inserts one restored-style bookmark with `book == nil`
     * - inserts one restored-style bookmark whose `book` value is Android module initials
     * - inserts one outside the queried KJVA chapter range
     *
     * Side effects:
     * - writes test bookmarks into an in-memory SwiftData context
     *
     * Failure modes:
     * - fails if the persistence query uses `BibleBookmark.book` for membership, reproducing issue
     *   #356 by hiding restored bookmarks from reader highlights and My Notes.
     */
    func testBookmarkServiceKJVAPassageQueryIgnoresRestoredAndroidBookColumn() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))

        let nilBookBookmark = BibleBookmark(
            kjvOrdinalStart: 100,
            kjvOrdinalEnd: 100,
            ordinalStart: 1_000,
            ordinalEnd: 1_000,
            v11n: "KJVA"
        )
        nilBookBookmark.book = nil
        let initialsBookmark = BibleBookmark(
            kjvOrdinalStart: 110,
            kjvOrdinalEnd: 110,
            ordinalStart: 1_010,
            ordinalEnd: 1_010,
            v11n: "KJVA"
        )
        initialsBookmark.book = "KJV"
        let outsideBookmark = BibleBookmark(
            kjvOrdinalStart: 200,
            kjvOrdinalEnd: 200,
            ordinalStart: 2_000,
            ordinalEnd: 2_000,
            v11n: "KJVA"
        )
        outsideBookmark.book = "Genesis"
        modelContext.insert(nilBookBookmark)
        modelContext.insert(initialsBookmark)
        modelContext.insert(outsideBookmark)
        try modelContext.save()

        let bookmarks = bookmarkService.bookmarks(for: 95, endOrdinal: 115, book: "Genesis")

        XCTAssertEqual(Set(bookmarks.map(\.id)), Set([nilBookBookmark.id, initialsBookmark.id]))
    }

    /**
     Verifies a Psalm-superscription bookmark is covered by its chapter's KJVA introduction range.

     Android's whole-chapter bookmark query starts at the chapter introduction (`Verse(v11n, book,
     chapter, 0)`), so a bookmark stored on a Psalm title (KJVA verse 0, ordinal `chapterStart - 1`)
     is included when that Psalm is read in any versification. This pins the ordinal contract the
     reader's `bookmarkQueryOrdinalRange` now relies on: the superscription bookmark is returned by a
     range whose lower bound is the chapter introduction, is missed by a range starting at verse 1
     (the pre-fix lower bound that excluded superscriptions in KJV-family modules), and never leaks
     into the previous chapter's range.
     */
    func testSuperscriptionBookmarkIsCoveredByChapterIntroductionQueryRange() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))

        let psalm51Intro = try XCTUnwrap(JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Ps", chapter: 51))
        let psalm51 = try XCTUnwrap(JSwordKJVAVersification.verseOrdinalRange(osisId: "Ps", chapter: 51))
        let psalm50Intro = try XCTUnwrap(JSwordKJVAVersification.chapterIntroOrdinal(osisId: "Ps", chapter: 50))
        let psalm50 = try XCTUnwrap(JSwordKJVAVersification.verseOrdinalRange(osisId: "Ps", chapter: 50))
        XCTAssertEqual(psalm51Intro, psalm51.lowerBound - 1, "The introduction ordinal sits immediately before verse 1.")

        let superscription = BibleBookmark(
            kjvOrdinalStart: psalm51Intro,
            kjvOrdinalEnd: psalm51Intro,
            ordinalStart: psalm51Intro,
            ordinalEnd: psalm51Intro,
            v11n: "KJVA"
        )
        modelContext.insert(superscription)
        try modelContext.save()

        // New lower bound (chapter introduction) covers the superscription bookmark.
        XCTAssertTrue(
            bookmarkService.bookmarks(for: psalm51Intro, endOrdinal: psalm51.upperBound)
                .contains { $0.id == superscription.id },
            "Chapter-introduction lower bound must cover a Psalm-title bookmark, matching Android."
        )
        // Pre-fix lower bound (verse 1) missed it — the gap this fix closes.
        XCTAssertFalse(
            bookmarkService.bookmarks(for: psalm51.lowerBound, endOrdinal: psalm51.upperBound)
                .contains { $0.id == superscription.id },
            "A verse-1 lower bound excludes the superscription ordinal, showing why the fix is needed."
        )
        // The introduction slot never leaks into the previous chapter's range.
        XCTAssertFalse(
            bookmarkService.bookmarks(for: psalm50Intro, endOrdinal: psalm50.upperBound)
                .contains { $0.id == superscription.id },
            "The Psalm 51 introduction ordinal must not fall inside Psalm 50's range."
        )
    }

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
     * - fails if the source module initials are not stored with the Bible bookmark.
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
        XCTAssertEqual(reloadedBookmark.bookInitials, "KJV")
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
        XCTAssertEqual(creation.0.contentType, "HTML")

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
