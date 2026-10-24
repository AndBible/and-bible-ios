import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
import SwordKit

/** Android bookmark creation preserves exact source identity even without an exact KJVA mapping. */
@MainActor
final class BibleReaderUnmappedBookmarkTests: BibleUISwordFixtureTestCase {
    /**
     Reproduces #441 through the public bridge action using a real Calvin RawText module.
     Android stores Revelation 12:18 in its source canon plus a separate lookup projection.
     Expected behavior is a stored Bible bookmark and its source reference in the reader payload;
     rejecting the selection or relabeling it as Revelation 13 means parity is still broken.
     Temporary module and in-memory database writes are owned by this test.
     */
    func testExtraCalvinVerseCreatesSourcePreservingBibleBookmark() async throws {
        try await assertBookmark(v11n: "Calvin", book: "Rev", chapter: 12, verse: 18)
    }

    /** An absent target book has a zero lookup index but retains its source bookmark identity. */
    func testLXXBookAbsentFromKJVACanBeBookmarkedAndReopened() async throws {
        try await assertBookmark(v11n: "LXX", book: "3Macc", chapter: 1, verse: 29)
    }

    /** An extra source chapter survives saving and reopening without a target-canon equivalent. */
    func testVulgateExtraEstherChapterCanBeBookmarkedAndReopened() async throws {
        try await assertBookmark(v11n: "Vulg", book: "Esth", chapter: 11, verse: 12)
    }

    /** Exercises native source selection, note/label persistence, navigation, and chapter replay. */
    private func assertBookmark(v11n: String, book: String, chapter: Int, verse: Int) async throws {
        let path = try makeTemporarySwordFixturePath()
        try seedSyntheticRawTextBibleModule(
            named: "Calvin441", description: "Extra-verse bookmark regression",
            versification: v11n,
            entries: [(book, 1, 1, "Book probe"), (book, chapter, verse, "EXTRA_VERSE_441"), (book, chapter + 1, 1, "Away chapter")],
            in: path
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: path))
        let module = try XCTUnwrap(manager.module(named: "Calvin441"))
        let ordinal = try XCTUnwrap(module.verseOrdinal(osisBookId: book, chapter: chapter, verse: verse))
        XCTAssertEqual(module.verseReference(ordinal: ordinal)?.verse, verse)
        let container = try makeBookmarkListModelContainer()
        let context = ModelContext(container)
        let store = BookmarkStore(modelContext: context)
        let service = BookmarkService(store: store)
        let (bridge, scripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge, bookmarkService: service,
                                              swordManagerOverride: manager)
        let window = Window(isSynchronized: false)
        let page = PageManager(id: window.id)
        page.bibleDocument = "Calvin441"
        page.bibleBibleBook = try XCTUnwrap(JSwordBibleBook.ordinal(forOSIS: book))
        page.bibleBookEncoding = PageManager.jswordBibleBookEncoding
        page.bibleVersification = v11n
        page.bibleChapterNo = chapter
        page.bibleVerseNo = verse
        retainReaderWindowGraph(window, attaching: page)
        controller.activeWindow = window
        controller.restoreSavedPosition()
        controller.bridgeDidSetClientReady(bridge)
        _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)
        controller.bridge(bridge, addBookmark: "Calvin441", startOrdinal: ordinal,
                          endOrdinal: ordinal, addNote: true)
        let bookmarks = try context.fetch(FetchDescriptor<BibleBookmark>())
        XCTAssertEqual(bookmarks.count, 1, "Android accepts this valid source verse")
        guard let bookmark = bookmarks.first else { return }
        XCTAssertEqual(bookmark.ordinalStart, ordinal)
        XCTAssertEqual(bookmark.ordinalEnd, ordinal)
        XCTAssertEqual(bookmark.v11n, v11n)
        XCTAssertEqual(store.bibleBookmarks().map(\.id), [bookmark.id])
        let rows = try XCTUnwrap(bridgeEmissionPayload(from: scripts(), event: "add_or_update_bookmarks") as? [[String: Any]])
        XCTAssertEqual(rows.first?["osisRef"] as? String, "\(book).\(chapter).\(verse)")
        service.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "Preserved extra-verse note")
        let label = Label(name: "Extra verse study")
        context.insert(label)
        try context.save()
        _ = service.assignLabel(bookmarkId: bookmark.id, labelId: label.id)
        let target = try BookmarkNavigationTargetResolver.resolve(bookmark)
        let away = scripts().count
        XCTAssertTrue(controller.navigateToRef("\(book).\(chapter + 1).1"))
        _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: away)
        let boundary = scripts().count
        try controller.navigate(toBookmarkTarget: target)
        let emitted = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: boundary)
        let document = try XCTUnwrap(bridgeEmissionPayload(from: emitted, event: "add_documents") as? [String: Any])
        XCTAssertEqual(controller.currentChapter, chapter)
        XCTAssertEqual(controller.currentVerse, verse)
        let restored = try XCTUnwrap((document["bookmarks"] as? [[String: Any]])?.first)
        XCTAssertEqual(restored["osisRef"] as? String, "\(book).\(chapter).\(verse)")
        XCTAssertEqual(restored["fullText"] as? String, "EXTRA_VERSE_441")
        XCTAssertEqual(restored["notes"] as? String, "Preserved extra-verse note")
        XCTAssertTrue((restored["labels"] as? [String])?.contains(label.id.uuidString) == true)
    }
}
