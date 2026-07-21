import SwiftData
import SwordKit
import XCTest
@testable import BibleCore

/**
 Package-lane coverage for bookmark persistence contracts owned by BibleCore.

 These tests were migrated out of the app-host bundle so BookmarkService data-safety behavior
 runs without building or installing the application. They intentionally keep the Android
 bookmark database and StudyPad persistence contracts from the original app-host tests. Mutation
 tests use autosave-disabled, file-backed stores and fresh containers so only an explicit
 synchronous save can satisfy their assertions.
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
            ordinalRange: try verifiedRange(
                bookInitials: "KJV",
                sourceVersification: "KJV",
                sourceOrdinalStart: 4,
                sourceOrdinalEnd: 4
            ),
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

        let sourceStart = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Matt", chapter: 1, verse: 1),
                versification: "KJV"
            )
        )
        let sourceEnd = try XCTUnwrap(
            JSwordCanon.referenceIndex(
                for: .init(osisBookId: "Matt", chapter: 1, verse: 3),
                versification: "KJV"
            )
        )
        let ordinalRange = try verifiedRange(
            bookInitials: "KJV",
            sourceVersification: "KJV",
            sourceOrdinalStart: sourceStart,
            sourceOrdinalEnd: sourceEnd
        )
        let bookmark = bookmarkService.addBibleBookmark(
            ordinalRange: ordinalRange,
            wholeVerse: true
        )

        XCTAssertEqual(bookmark.ordinalStart, sourceStart)
        XCTAssertEqual(bookmark.ordinalEnd, sourceEnd)
        XCTAssertEqual(bookmark.kjvOrdinalStart, ordinalRange.kjvaOrdinalStart)
        XCTAssertEqual(bookmark.kjvOrdinalEnd, ordinalRange.kjvaOrdinalEnd)
        XCTAssertNotEqual(bookmark.ordinalStart, bookmark.kjvOrdinalStart)
        XCTAssertEqual(bookmark.v11n, "KJV")
        XCTAssertEqual(bookmark.bookInitials, "KJV")
        XCTAssertTrue(bookmark.hasTrustedPersistedOrdinals)
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
            v11n: "KJVA",
            bookInitials: "KJVA",
            ordinalTrustMetadata: trustedAndroidMetadata(sourceOrdinal: 1_000, kjvaOrdinal: 100)
        )
        nilBookBookmark.book = nil
        let initialsBookmark = BibleBookmark(
            kjvOrdinalStart: 110,
            kjvOrdinalEnd: 110,
            ordinalStart: 1_010,
            ordinalEnd: 1_010,
            v11n: "KJVA",
            bookInitials: "KJVA",
            ordinalTrustMetadata: trustedAndroidMetadata(sourceOrdinal: 1_010, kjvaOrdinal: 110)
        )
        initialsBookmark.book = "KJV"
        let outsideBookmark = BibleBookmark(
            kjvOrdinalStart: 200,
            kjvOrdinalEnd: 200,
            ordinalStart: 2_000,
            ordinalEnd: 2_000,
            v11n: "KJVA",
            bookInitials: "KJVA",
            ordinalTrustMetadata: trustedAndroidMetadata(sourceOrdinal: 2_000, kjvaOrdinal: 200)
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
            v11n: "KJVA",
            bookInitials: "KJVA",
            ordinalTrustMetadata: trustedAndroidMetadata(
                sourceOrdinal: psalm51Intro,
                kjvaOrdinal: psalm51Intro
            )
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
            v11n: "KJVA",
            bookInitials: "KJVA",
            ordinalTrustMetadata: trustedAndroidMetadata(sourceOrdinal: 1, kjvaOrdinal: 1)
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
            ordinalRange: try verifiedRange(
                bookInitials: "KJV",
                sourceVersification: "KJV",
                sourceOrdinalStart: 4,
                sourceOrdinalEnd: 4
            ),
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
     Resolves a deterministic source range through the production typed mapping boundary.

     - Parameters:
       - bookInitials: Exact source module initials retained by the fixture row.
       - sourceVersification: Supported JSword versification that owns the source ordinals.
       - sourceOrdinalStart: Inclusive source start ordinal.
       - sourceOrdinalEnd: Inclusive source end ordinal.
     - Returns: Verified source-to-KJVA contract used by native service writes.
     - Side effects: Reads bundled canon and mapping fixtures only.
     - Failure modes: Throws an XCTest unwrap failure when fixture coordinates are invalid.
     */
    private func verifiedRange(
        bookInitials: String,
        sourceVersification: String,
        sourceOrdinalStart: Int,
        sourceOrdinalEnd: Int
    ) throws -> VerifiedKJVAOrdinalRange {
        try XCTUnwrap(
            VerifiedKJVAOrdinalRange(
                resolvingSourceBookInitials: bookInitials,
                sourceVersification: sourceVersification,
                sourceOrdinalStart: sourceOrdinalStart,
                sourceOrdinalEnd: sourceOrdinalEnd
            )
        )
    }

    /**
     Creates explicit trust for a single-verse fixture that represents validated Android input.

     - Parameters:
       - sourceOrdinal: Preserved source-domain ordinal from the Android row.
       - kjvaOrdinal: Bounds-validated KJVA ordinal supplied by Android.
     - Returns: Android-import trust metadata for the fixture row.
     - Side effects: Reads bundled canon bounds only.
     - Failure modes: Invalid ordinals produce unresolved metadata and cause the consuming test to
       fail closed.
     */
    private func trustedAndroidMetadata(
        sourceOrdinal: Int,
        kjvaOrdinal: Int
    ) -> PersistedOrdinalTrustMetadata {
        PersistedOrdinalTrustPolicy.androidImportMetadata(
            sourceVersification: "KJVA",
            sourceOrdinalStart: sourceOrdinal,
            sourceOrdinalEnd: sourceOrdinal,
            kjvaOrdinalStart: kjvaOrdinal,
            kjvaOrdinalEnd: kjvaOrdinal
        )
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
            v11n: "KJVA",
            bookInitials: "KJVA",
            ordinalTrustMetadata: trustedAndroidMetadata(sourceOrdinal: 1, kjvaOrdinal: 1)
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
            v11n: "KJVA",
            bookInitials: "KJVA",
            ordinalTrustMetadata: trustedAndroidMetadata(sourceOrdinal: 1, kjvaOrdinal: 1)
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
            v11n: "KJVA",
            bookInitials: "KJVA",
            ordinalTrustMetadata: trustedAndroidMetadata(sourceOrdinal: 1, kjvaOrdinal: 1)
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

    /**
     Verifies whole-range, custom-icon, and edit-action mutations are durable for both bookmark
     tables, matching Android's synchronous DAO updates.

     Each of the six mutation paths receives its own file-backed store. The mutation context has
     autosave disabled and is released before a fresh container reads the result, preventing a
     later mutation or implicit autosave from masking a missing store save. A failure means reader
     events can advertise bookmark state that is lost when the process exits.
     */
    func testBookmarkScalarMutationsPersistBeforeReturningWithAutosaveDisabled() throws {
        let directory = try makeTemporaryBookmarkStoreDirectory(prefix: "BookmarkScalarMutations")
        defer { try? FileManager.default.removeItem(at: directory) }
        let action = EditAction(mode: .append, content: "Persisted action")

        let bibleWholeVerseURL = directory.appendingPathComponent("BibleWholeVerse.store")
        let bibleWholeVerseID = try seedBibleBookmark(at: bibleWholeVerseURL)
        try withPersistentBookmarkContext(at: bibleWholeVerseURL) { _, service in
            service.setWholeVerse(bookmarkId: bibleWholeVerseID, value: false)
        }
        try withPersistentBookmarkContext(at: bibleWholeVerseURL) { _, service in
            let bookmark = try XCTUnwrap(service.bibleBookmark(id: bibleWholeVerseID))
            XCTAssertFalse(bookmark.wholeVerse)
            XCTAssertGreaterThan(bookmark.lastUpdatedOn, Self.persistenceBaselineDate)
        }

        let bibleIconURL = directory.appendingPathComponent("BibleCustomIcon.store")
        let bibleIconID = try seedBibleBookmark(at: bibleIconURL)
        try withPersistentBookmarkContext(at: bibleIconURL) { _, service in
            service.setCustomIcon(bookmarkId: bibleIconID, value: "bookmark")
        }
        try withPersistentBookmarkContext(at: bibleIconURL) { _, service in
            let bookmark = try XCTUnwrap(service.bibleBookmark(id: bibleIconID))
            XCTAssertEqual(bookmark.customIcon, "bookmark")
            XCTAssertGreaterThan(bookmark.lastUpdatedOn, Self.persistenceBaselineDate)
        }

        let bibleEditActionURL = directory.appendingPathComponent("BibleEditAction.store")
        let bibleEditActionID = try seedBibleBookmark(at: bibleEditActionURL)
        try withPersistentBookmarkContext(at: bibleEditActionURL) { _, service in
            service.setBookmarkEditAction(bookmarkId: bibleEditActionID, editAction: action)
        }
        try withPersistentBookmarkContext(at: bibleEditActionURL) { _, service in
            let bookmark = try XCTUnwrap(service.bibleBookmark(id: bibleEditActionID))
            XCTAssertEqual(bookmark.editAction, action)
            XCTAssertGreaterThan(bookmark.lastUpdatedOn, Self.persistenceBaselineDate)
        }

        let genericWholeVerseURL = directory.appendingPathComponent("GenericWholeVerse.store")
        let genericWholeVerseID = try seedGenericBookmark(at: genericWholeVerseURL)
        try withPersistentBookmarkContext(at: genericWholeVerseURL) { _, service in
            service.setWholeVerse(bookmarkId: genericWholeVerseID, value: false)
        }
        try withPersistentBookmarkContext(at: genericWholeVerseURL) { _, service in
            let bookmark = try XCTUnwrap(service.genericBookmark(id: genericWholeVerseID))
            XCTAssertFalse(bookmark.wholeVerse)
            XCTAssertGreaterThan(bookmark.lastUpdatedOn, Self.persistenceBaselineDate)
        }

        let genericIconURL = directory.appendingPathComponent("GenericCustomIcon.store")
        let genericIconID = try seedGenericBookmark(at: genericIconURL)
        try withPersistentBookmarkContext(at: genericIconURL) { _, service in
            service.setCustomIcon(bookmarkId: genericIconID, value: "journal")
        }
        try withPersistentBookmarkContext(at: genericIconURL) { _, service in
            let bookmark = try XCTUnwrap(service.genericBookmark(id: genericIconID))
            XCTAssertEqual(bookmark.customIcon, "journal")
            XCTAssertGreaterThan(bookmark.lastUpdatedOn, Self.persistenceBaselineDate)
        }

        let genericEditActionURL = directory.appendingPathComponent("GenericEditAction.store")
        let genericEditActionID = try seedGenericBookmark(at: genericEditActionURL)
        try withPersistentBookmarkContext(at: genericEditActionURL) { _, service in
            service.setBookmarkEditAction(bookmarkId: genericEditActionID, editAction: action)
        }
        try withPersistentBookmarkContext(at: genericEditActionURL) { _, service in
            let bookmark = try XCTUnwrap(service.genericBookmark(id: genericEditActionID))
            XCTAssertEqual(bookmark.editAction, action)
            XCTAssertGreaterThan(bookmark.lastUpdatedOn, Self.persistenceBaselineDate)
        }
    }

    /**
     Verifies StudyPad entry metadata and both relationship variants are synchronously durable.

     The test reopens the file-backed store after each individual service call before proceeding to
     the next path. This isolates Android's `updateStudyPadTextEntry` and `updateBookmarkToLabel`
     contracts and also pins timestamp persistence for bookmark relationship edits. A failure means
     the live StudyPad can render metadata that a newly opened context cannot recover.
     */
    func testStudyPadMetadataAndRelationshipMutationsPersistWithAutosaveDisabled() throws {
        let directory = try makeTemporaryBookmarkStoreDirectory(prefix: "StudyPadMetadataMutations")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Bookmarks.store")
        let fixture = try seedStudyPadFixture(at: storeURL)

        try withPersistentBookmarkContext(at: storeURL) { _, service in
            service.updateStudyPadTextEntry(
                id: fixture.survivingEntryID,
                orderNumber: 17,
                indentLevel: 3
            )
        }
        try withPersistentBookmarkContext(at: storeURL) { _, service in
            let entry = try XCTUnwrap(service.studyPadEntry(id: fixture.survivingEntryID))
            XCTAssertEqual(entry.orderNumber, 17)
            XCTAssertEqual(entry.indentLevel, 3)
        }

        try withPersistentBookmarkContext(at: storeURL) { _, service in
            service.updateBibleBookmarkToLabel(
                bookmarkId: fixture.bibleBookmarkID,
                labelId: fixture.labelID,
                orderNumber: 18,
                indentLevel: 4,
                expandContent: false
            )
        }
        try withPersistentBookmarkContext(at: storeURL) { _, service in
            let link = try XCTUnwrap(service.bibleBookmarkToLabel(
                bookmarkId: fixture.bibleBookmarkID,
                labelId: fixture.labelID
            ))
            XCTAssertEqual(link.orderNumber, 18)
            XCTAssertEqual(link.indentLevel, 4)
            XCTAssertFalse(link.expandContent)
            XCTAssertGreaterThan(
                try XCTUnwrap(service.bibleBookmark(id: fixture.bibleBookmarkID)).lastUpdatedOn,
                Self.persistenceBaselineDate
            )
        }

        try withPersistentBookmarkContext(at: storeURL) { _, service in
            service.updateGenericBookmarkToLabel(
                bookmarkId: fixture.genericBookmarkID,
                labelId: fixture.labelID,
                orderNumber: 19,
                indentLevel: 5,
                expandContent: true
            )
        }
        try withPersistentBookmarkContext(at: storeURL) { _, service in
            let link = try XCTUnwrap(service.genericBookmarkToLabel(
                bookmarkId: fixture.genericBookmarkID,
                labelId: fixture.labelID
            ))
            XCTAssertEqual(link.orderNumber, 19)
            XCTAssertEqual(link.indentLevel, 5)
            XCTAssertTrue(link.expandContent)
            XCTAssertGreaterThan(
                try XCTUnwrap(service.genericBookmark(id: fixture.genericBookmarkID)).lastUpdatedOn,
                Self.persistenceBaselineDate
            )
        }
    }

    /**
     Verifies one mixed StudyPad drag-and-drop payload persists every row before returning.

     The file-backed context disables autosave, updates Bible, generic, and text-entry order through
     one service call, then is discarded. A fresh container must observe all four order numbers.
     Failure indicates the iOS bridge can acknowledge Android's reorder payload while leaving the
     database in its previous order.
     */
    func testStudyPadMixedReorderPersistsAsOneExplicitBatch() throws {
        let directory = try makeTemporaryBookmarkStoreDirectory(prefix: "StudyPadMixedReorder")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Bookmarks.store")
        let fixture = try seedStudyPadFixture(at: storeURL)

        try withPersistentBookmarkContext(at: storeURL) { _, service in
            service.updateOrderNumbers(
                labelId: fixture.labelID,
                bibleBookmarkOrders: [(fixture.bibleBookmarkID, 30)],
                genericBookmarkOrders: [(fixture.genericBookmarkID, 20)],
                studyPadEntryOrders: [
                    (fixture.deletedEntryID, 10),
                    (fixture.survivingEntryID, 40),
                ]
            )
        }

        try withPersistentBookmarkContext(at: storeURL) { _, service in
            XCTAssertEqual(
                service.bibleBookmarkToLabel(
                    bookmarkId: fixture.bibleBookmarkID,
                    labelId: fixture.labelID
                )?.orderNumber,
                30
            )
            XCTAssertEqual(
                service.genericBookmarkToLabel(
                    bookmarkId: fixture.genericBookmarkID,
                    labelId: fixture.labelID
                )?.orderNumber,
                20
            )
            XCTAssertEqual(service.studyPadEntry(id: fixture.deletedEntryID)?.orderNumber, 10)
            XCTAssertEqual(service.studyPadEntry(id: fixture.survivingEntryID)?.orderNumber, 40)
        }
    }

    /**
     Verifies deleting a StudyPad text row and normalizing the remaining mixed order is one durable
     store operation.

     The fixture deliberately contains sparse order numbers and a detached text payload. After an
     autosave-disabled delete call, a fresh container must see the target and payload removed and
     the Bible, generic, and surviving text rows renumbered to `0...2`. Failure means a process exit
     can persist Android's delete while losing the required contiguous-order repair.
     */
    func testStudyPadDeleteAndOrderNormalizationPersistTogether() throws {
        let directory = try makeTemporaryBookmarkStoreDirectory(prefix: "StudyPadDeleteNormalization")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Bookmarks.store")
        let fixture = try seedStudyPadFixture(at: storeURL)

        try withPersistentBookmarkContext(at: storeURL) { context, service in
            let saveExpectation = expectation(
                description: "StudyPad deletion and normalization share one save"
            )
            saveExpectation.expectedFulfillmentCount = 1
            saveExpectation.assertForOverFulfill = true
            let saveObserver = NotificationCenter.default.addObserver(
                forName: ModelContext.willSave,
                object: context,
                queue: nil
            ) { _ in
                saveExpectation.fulfill()
            }
            defer { NotificationCenter.default.removeObserver(saveObserver) }

            let result = try XCTUnwrap(service.deleteStudyPadEntry(id: fixture.deletedEntryID))
            XCTAssertEqual(result.0, fixture.deletedEntryID)
            XCTAssertEqual(result.1, fixture.labelID)
            XCTAssertEqual(result.2.map(\.orderNumber), [0])
            XCTAssertEqual(result.3.map(\.orderNumber), [1])
            XCTAssertEqual(result.4.map(\.orderNumber), [2])
            wait(for: [saveExpectation], timeout: 1)
        }

        try withPersistentBookmarkContext(at: storeURL) { context, service in
            XCTAssertNil(service.studyPadEntry(id: fixture.deletedEntryID))
            let deletedEntryID = fixture.deletedEntryID
            let deletedTextDescriptor = FetchDescriptor<StudyPadTextEntryText>(
                predicate: #Predicate { $0.studyPadTextEntryId == deletedEntryID }
            )
            XCTAssertTrue(try context.fetch(deletedTextDescriptor).isEmpty)
            XCTAssertEqual(
                service.bibleBookmarkToLabel(
                    bookmarkId: fixture.bibleBookmarkID,
                    labelId: fixture.labelID
                )?.orderNumber,
                0
            )
            XCTAssertEqual(
                service.genericBookmarkToLabel(
                    bookmarkId: fixture.genericBookmarkID,
                    labelId: fixture.labelID
                )?.orderNumber,
                1
            )
            XCTAssertEqual(service.studyPadEntry(id: fixture.survivingEntryID)?.orderNumber, 2)
        }
    }

    /// Old timestamp used to prove mutation methods persist their `lastUpdatedOn` changes.
    private static let persistenceBaselineDate = Date(timeIntervalSince1970: 1)

    /**
     Creates a temporary directory owned by one persistence test.

     - Parameter prefix: Human-readable test purpose included in the directory name.
     - Returns: Newly created unique directory beneath the process temporary directory.
     - Side effects: Creates one directory; the calling test removes it with `defer`.
     - Failure modes: Rethrows filesystem directory-creation errors.
     */
    private func makeTemporaryBookmarkStoreDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /**
     Opens one production-shaped bookmark store with autosave disabled for an isolated operation.

     - Parameters:
       - storeURL: Stable SQLite URL reused across seed, mutation, and assertion phases.
       - body: Non-escaping operation that may read or mutate through the context and service.
     - Side effects: Opens the file-backed store and invokes `body`; only explicit store or context
       saves persist because autosave is disabled.
     - Failure modes: Rethrows container creation and closure errors.
     - Important: Callers must not retain SwiftData models beyond `body`; returning releases the
       container so the next invocation is a genuine reopen.
     */
    private func withPersistentBookmarkContext(
        at storeURL: URL,
        _ body: (ModelContext, BookmarkService) throws -> Void
    ) throws {
        let container = try makePersistentBookmarkModelContainer(at: storeURL)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        try body(context, BookmarkService(store: BookmarkStore(modelContext: context)))
    }

    /**
     Opens the complete bookmark schema at a caller-owned persistent-store URL.

     - Parameter storeURL: SQLite store URL inside a temporary test directory.
     - Returns: Local-only SwiftData container containing bookmark, StudyPad, and journal settings
       entities.
     - Side effects: Creates or opens the file-backed SQLite store and its sidecar files.
     - Failure modes: Rethrows schema or persistent-store initialization errors.
     */
    private func makePersistentBookmarkModelContainer(at storeURL: URL) throws -> ModelContainer {
        let schema = Schema([
            BibleBookmark.self,
            BibleBookmarkNotes.self,
            BibleBookmarkToLabel.self,
            GenericBookmark.self,
            GenericBookmarkNotes.self,
            GenericBookmarkToLabel.self,
            Label.self,
            StudyPadTextEntry.self,
            StudyPadTextEntryText.self,
            Setting.self,
        ])
        let configuration = ModelConfiguration(
            "BookmarkMutationPersistence",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /**
     Seeds one trusted Bible bookmark with intentionally old mutation metadata.

     - Parameter storeURL: Empty persistent store to seed.
     - Returns: Stable bookmark identifier used by a later isolated mutation.
     - Side effects: Inserts and explicitly saves one `Genesis 1:1` bookmark.
     - Failure modes: Rethrows container, versification, and SwiftData save errors.
     */
    private func seedBibleBookmark(at storeURL: URL) throws -> UUID {
        var bookmarkID: UUID?
        try withPersistentBookmarkContext(at: storeURL) { context, service in
            let bookmark = service.addBibleBookmark(
                ordinalRange: try verifiedRange(
                    bookInitials: "KJV",
                    sourceVersification: "KJV",
                    sourceOrdinalStart: 4,
                    sourceOrdinalEnd: 4
                ),
                wholeVerse: true
            )
            bookmark.lastUpdatedOn = Self.persistenceBaselineDate
            try context.save()
            bookmarkID = bookmark.id
        }
        return try XCTUnwrap(bookmarkID)
    }

    /**
     Seeds one generic bookmark with intentionally old mutation metadata.

     - Parameter storeURL: Empty persistent store to seed.
     - Returns: Stable bookmark identifier used by a later isolated mutation.
     - Side effects: Inserts and explicitly saves one dictionary-entry bookmark.
     - Failure modes: Rethrows container and SwiftData save errors.
     */
    private func seedGenericBookmark(at storeURL: URL) throws -> UUID {
        var bookmarkID: UUID?
        try withPersistentBookmarkContext(at: storeURL) { context, service in
            let bookmark = service.addGenericBookmark(
                bookInitials: "DICT",
                key: "durable-entry",
                startOrdinal: 2,
                endOrdinal: 2,
                wholeVerse: true
            )
            bookmark.lastUpdatedOn = Self.persistenceBaselineDate
            try context.save()
            bookmarkID = bookmark.id
        }
        return try XCTUnwrap(bookmarkID)
    }

    /**
     Seeds sparse mixed StudyPad rows for metadata, reorder, and delete-normalization assertions.

     - Parameter storeURL: Empty persistent store to seed.
     - Returns: Stable identifiers for the label, bookmarks, and text entries.
     - Side effects: Inserts one label, two bookmarks and links, two StudyPad entries and payloads,
       then explicitly saves them.
     - Failure modes: Rethrows container and SwiftData save errors.
     */
    private func seedStudyPadFixture(at storeURL: URL) throws -> PersistentStudyPadFixtureIDs {
        var fixture: PersistentStudyPadFixtureIDs?
        try withPersistentBookmarkContext(at: storeURL) { context, _ in
            let label = Label(name: "Durable StudyPad")
            let bibleBookmark = BibleBookmark(
                kjvOrdinalStart: 4,
                kjvOrdinalEnd: 4,
                ordinalStart: 4,
                ordinalEnd: 4,
                v11n: "KJVA",
                bookInitials: "KJV",
                ordinalTrustMetadata: trustedAndroidMetadata(sourceOrdinal: 4, kjvaOrdinal: 4)
            )
            bibleBookmark.lastUpdatedOn = Self.persistenceBaselineDate
            let bibleLink = BibleBookmarkToLabel(
                orderNumber: 4,
                indentLevel: 0,
                expandContent: true
            )
            bibleLink.bookmark = bibleBookmark
            bibleLink.label = label
            bibleBookmark.bookmarkToLabels = [bibleLink]

            let genericBookmark = GenericBookmark(key: "durable-entry", bookInitials: "DICT")
            genericBookmark.lastUpdatedOn = Self.persistenceBaselineDate
            let genericLink = GenericBookmarkToLabel(
                orderNumber: 8,
                indentLevel: 0,
                expandContent: false
            )
            genericLink.bookmark = genericBookmark
            genericLink.label = label
            genericBookmark.bookmarkToLabels = [genericLink]

            let deletedEntry = StudyPadTextEntry(orderNumber: 2, indentLevel: 0, contentType: "HTML")
            deletedEntry.label = label
            let deletedText = StudyPadTextEntryText(
                studyPadTextEntryId: deletedEntry.id,
                text: "Delete me"
            )
            deletedEntry.textEntry = deletedText
            deletedText.entry = deletedEntry

            let survivingEntry = StudyPadTextEntry(orderNumber: 12, indentLevel: 1, contentType: "HTML")
            survivingEntry.label = label
            let survivingText = StudyPadTextEntryText(
                studyPadTextEntryId: survivingEntry.id,
                text: "Keep me"
            )
            survivingEntry.textEntry = survivingText
            survivingText.entry = survivingEntry

            label.bibleBookmarkToLabels = [bibleLink]
            label.genericBookmarkToLabels = [genericLink]
            label.studyPadEntries = [deletedEntry, survivingEntry]
            context.insert(label)
            context.insert(bibleBookmark)
            context.insert(bibleLink)
            context.insert(genericBookmark)
            context.insert(genericLink)
            context.insert(deletedEntry)
            context.insert(deletedText)
            context.insert(survivingEntry)
            context.insert(survivingText)
            try context.save()

            fixture = PersistentStudyPadFixtureIDs(
                labelID: label.id,
                bibleBookmarkID: bibleBookmark.id,
                genericBookmarkID: genericBookmark.id,
                deletedEntryID: deletedEntry.id,
                survivingEntryID: survivingEntry.id
            )
        }
        return try XCTUnwrap(fixture)
    }
}

/** Stable identities returned by the file-backed mixed StudyPad fixture. */
private struct PersistentStudyPadFixtureIDs {
    /// Label owning every mixed StudyPad row in the fixture.
    let labelID: UUID

    /// Trusted Bible bookmark attached to `labelID`.
    let bibleBookmarkID: UUID

    /// Generic bookmark attached to `labelID`.
    let genericBookmarkID: UUID

    /// StudyPad text entry removed by the delete-normalization test.
    let deletedEntryID: UUID

    /// StudyPad text entry retained after normalization.
    let survivingEntryID: UUID
}
