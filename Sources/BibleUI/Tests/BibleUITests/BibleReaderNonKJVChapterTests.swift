import Foundation
import XCTest
import SwiftData
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
import SwordKit

/** Source-canon chapter rendering must survive absent or partial KJVA annotation mappings. */
@MainActor
final class BibleReaderNonKJVChapterTests: BibleUISwordFixtureTestCase {
    /** Calvin Psalm titles add a ninth verse; direct loading and adjacent loading retain it. */
    func testCalvinPsalmDirectAndAdjacentLoadingPreservesLastVerse() async throws {
        try await assertChapter(versification: "Calvin", book: "Ps", chapter: 3, lastVerse: 9, adjacent: true)
    }

    /** Calvin Revelation 12 has eighteen verses, independent of KJVA's seventeen. */
    func testCalvinRevelationPreservesEighteenthVerse() async throws {
        try await assertChapter(versification: "Calvin", book: "Rev", chapter: 12, lastVerse: 18, adjacent: true)
    }

    /** LXX 3 Maccabees has no KJVA book; absence of annotations must not suppress its text. */
    func testLXXBookAbsentFromKJVARenders() async throws {
        try await assertChapter(versification: "LXX", book: "3Macc", chapter: 1, lastVerse: 29)
    }

    /** Vulgate Esther's additional chapters remain in their source canon. */
    func testVulgateAdditionalEstherChapterRenders() async throws {
        try await assertChapter(versification: "Vulg", book: "Esth", chapter: 11, lastVerse: 12)
    }

    /**
     Builds sparse real RawText source records and observes the controller's accepted bridge output.
     Both introduction settings are exercised. Optional scrolling starts from the preceding chapter.
     Failures distinguish lost source content from fabricated target-domain coordinates; files and
     controller state are test-owned, and no persisted bookmark mutation is attempted.
     */
    private func assertChapter(
        versification: String,
        book: String,
        chapter: Int,
        lastVerse: Int,
        adjacent: Bool = false
    ) async throws {
        let path = try makeTemporarySwordFixturePath()
        let name = "Chapter441"
        var entries = [(book, chapter, 1, "FIRST_441"), (book, chapter, lastVerse, "LAST_441")]
        if chapter > 1 { entries.append((book, 1, 1, "BOOK_PROBE_441")) }
        if adjacent { entries.append((book, chapter - 1, 1, "PREVIOUS_441")) }
        try seedSyntheticRawTextBibleModule(
            named: name, description: "Non-KJV chapter regression", versification: versification,
            entries: entries, in: path
        )
        let manager = try XCTUnwrap(SwordManager(modulePath: path))
        let module = try XCTUnwrap(manager.module(named: name))
        XCTAssertTrue(module.inspectVerseKeyAndRawEntryRestoringPrevious("\(book).\(chapter).\(lastVerse)").rawEntry.contains("LAST_441"))
        let container = try makeBookmarkListModelContainer()
        let context = ModelContext(container)
        let service = BookmarkService(store: BookmarkStore(modelContext: context))
        let annotationBook = versification == "Calvin" ? book : "Gen"
        let annotationChapter = versification == "Calvin" ? chapter : 1
        let ordinal = try XCTUnwrap(JSwordKJVAVersification.verseOrdinal(
            osisId: annotationBook, chapter: annotationChapter, verse: 1
        ))
        // A stored KJVA annotation must survive partial mapping, and must not leak into an
        // unrelated source-only book. This fixture represents an existing database row.
        let reference = VerseKeyReference(osisBookId: annotationBook, chapter: annotationChapter,
                                          verse: 1, ordinal: ordinal)
        let verified = try XCTUnwrap(VerifiedKJVAOrdinalRange(
            sourceBookInitials: "KJV", sourceVersification: "KJVA",
            sourceOrdinalStart: ordinal, sourceOrdinalEnd: ordinal,
            sourceReferenceStart: reference, sourceReferenceEnd: reference
        ))
        service.addBibleBookmark(ordinalRange: verified)
        try context.save()
        for introductions in [false, true] {
            let (bridge, scripts) = makeRecordingBridge()
            let controller = BibleReaderController(bridge: bridge, bookmarkService: service, swordManagerOverride: manager)
            let window = Window(isSynchronized: false)
            let page = PageManager(id: window.id)
            page.bibleDocument = name
            page.bibleBibleBook = try XCTUnwrap(JSwordBibleBook.ordinal(forOSIS: book))
            page.bibleBookEncoding = PageManager.jswordBibleBookEncoding
            page.bibleVersification = versification
            page.bibleChapterNo = chapter
            page.bibleVerseNo = 1
            retainReaderWindowGraph(window, attaching: page)
            controller.activeWindow = window
            var settings = TextDisplaySettings.appDefaults
            settings.showSectionTitles = introductions
            controller.displaySettings = settings
            controller.restoreSavedPosition()
            controller.bridgeDidSetClientReady(bridge)
            let emitted = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: 0)
            let document = try XCTUnwrap(bridgeEmissionPayload(from: emitted, event: "add_documents") as? [String: Any])
            let fragment = try XCTUnwrap(document["osisFragment"] as? [String: Any])
            let xml = try XCTUnwrap(fragment["xml"] as? String)
            XCTAssertTrue(xml.contains("LAST_441"), xml)
            XCTAssertEqual((document["bookmarks"] as? [[String: Any]])?.count,
                           versification == "Calvin" ? 1 : 0)
            XCTAssertEqual(fragment["v11n"] as? String, versification)
            XCTAssertEqual((document["ordinalRange"] as? [Int])?.last,
                           module.verseOrdinal(osisBookId: book, chapter: chapter, verse: lastVerse))
            if adjacent {
                let boundary = scripts().count
                XCTAssertTrue(controller.navigateToRef("\(book).\(chapter - 1).1"))
                _ = try await awaitBridgeEmission(from: scripts, event: "add_documents", after: boundary)
                let responseBoundary = scripts().count
                controller.bridge(bridge, requestMoreToEnd: 9441)
                let response = try await awaitBridgeScript(from: scripts, after: responseBoundary,
                    description: "source chapter appended") { $0.hasPrefix("bibleView.response(9441,") }
                XCTAssertTrue(try XCTUnwrap(response).contains("LAST_441"))
            }
        }
    }
}
