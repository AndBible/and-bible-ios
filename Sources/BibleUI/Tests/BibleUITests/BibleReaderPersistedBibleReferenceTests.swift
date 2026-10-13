import XCTest
import BibleView
import BibleCore
@testable import BibleUI

/** Verifies detached reader labels never reinterpret an unmarked persisted book integer. */
final class BibleReaderPersistedBibleReferenceTests: XCTestCase {
    /** Canonical JSword identity supplies consistent agent, tab, and pane-menu labels. */
    @MainActor
    func testCanonicalDetachedReferenceProjectsBookChapterAndVerseLabels() throws {
        let pageManager = PageManager()
        pageManager.currentCategoryName = DocumentCategory.bible.pageManagerKey
        pageManager.bibleBibleBook = try XCTUnwrap(JSwordBibleBook.ordinal(forOSIS: "Gen"))
        pageManager.bibleBookEncoding = PageManager.jswordBibleBookEncoding
        pageManager.bibleVersification = JSwordKJVAVersification.name
        pageManager.bibleChapterNo = 3
        pageManager.bibleVerseNo = 1
        let window = BibleCore.Window()
        window.pageManager = pageManager

        let reference = try XCTUnwrap(
            BibleReaderPersistedBibleReference(pageManager: pageManager)
        )
        XCTAssertEqual(reference.compactChapterName, "Gen 3")
        XCTAssertEqual(reference.localizedChapterName, "Genesis 3")
        XCTAssertEqual(reference.osisVerseReference, "Gen.3.1")
        XCTAssertEqual(reference.localizedVerseName, "Genesis 3:1")
        XCTAssertEqual(WindowTabBar.detachedShortReference(for: window), "Gen 3")
        XCTAssertEqual(
            BibleWindowPaneMenuSnapshotFactory.referenceName(for: window, controller: nil),
            "Genesis 3"
        )
    }

    /** The persisted source canon owns addressability, including an explicitly stored introduction. */
    func testCanonicalDetachedReferenceUsesStoredVersificationWithoutKJVAMapping() throws {
        let pageManager = PageManager()
        pageManager.bibleBibleBook = try XCTUnwrap(JSwordBibleBook.ordinal(forOSIS: "Esth"))
        pageManager.bibleBookEncoding = PageManager.jswordBibleBookEncoding
        pageManager.bibleVersification = "Vulg"
        pageManager.bibleChapterNo = 16
        pageManager.bibleVerseNo = 24

        let vulgateReference = try XCTUnwrap(
            BibleReaderPersistedBibleReference(pageManager: pageManager)
        )
        XCTAssertEqual(vulgateReference.osisVerseReference, "Esth.16.24")

        pageManager.bibleVersification = JSwordKJVAVersification.name
        XCTAssertNil(BibleReaderPersistedBibleReference(pageManager: pageManager))

        pageManager.bibleBibleBook = try XCTUnwrap(JSwordBibleBook.ordinal(forOSIS: "Gen"))
        pageManager.bibleChapterNo = 3
        pageManager.bibleVerseNo = 0
        let introductionReference = try XCTUnwrap(
            BibleReaderPersistedBibleReference(pageManager: pageManager)
        )
        XCTAssertEqual(introductionReference.osisVerseReference, "Gen.3.0")

        pageManager.bibleBibleBook = try XCTUnwrap(JSwordBibleBook.ordinal(forOSIS: "1En"))
        pageManager.bibleVersification = "LXX"
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 9
        let lxxReference = try XCTUnwrap(
            BibleReaderPersistedBibleReference(pageManager: pageManager)
        )
        XCTAssertEqual(lxxReference.osisVerseReference, "1En.1.9")
    }

    /** A detached auxiliary tab projects its active key, never its retained hidden Bible tuple. */
    @MainActor
    func testDetachedGeneralBookReferenceDoesNotLeakHiddenBibleLocation() throws {
        let pageManager = PageManager()
        pageManager.currentCategoryName = DocumentCategory.generalBook.pageManagerKey
        pageManager.generalBookDocument = "Westminster21"
        pageManager.generalBookKey = "/Westminster21/Westminster21/WCF/Ch 6"
        pageManager.bibleBibleBook = try XCTUnwrap(JSwordBibleBook.ordinal(forOSIS: "Gen"))
        pageManager.bibleBookEncoding = PageManager.jswordBibleBookEncoding
        pageManager.bibleVersification = JSwordKJVAVersification.name
        pageManager.bibleChapterNo = 3
        pageManager.bibleVerseNo = 1
        let window = BibleCore.Window()
        window.pageManager = pageManager

        XCTAssertEqual(
            WindowTabBar.detachedShortReference(for: window),
            "/Westminster21/Westminster21/WCF/Ch 6"
        )
        XCTAssertEqual(
            BibleWindowPaneMenuSnapshotFactory.documentAbbreviation(
                for: window,
                controller: nil
            ),
            "Westminster21"
        )
        XCTAssertEqual(
            BibleWindowPaneMenuSnapshotFactory.referenceName(for: window, controller: nil),
            "/Westminster21/Westminster21/WCF/Ch 6"
        )
    }

    /** A registered pre-render general-book controller still labels the pending WCF key. */
    @MainActor
    func testPendingGeneralBookTabDoesNotLeakHiddenBibleLocation() throws {
        let pageManager = PageManager(
            currentCategoryName: DocumentCategory.generalBook.pageManagerKey
        )
        pageManager.generalBookDocument = "Westminster21"
        pageManager.generalBookKey = "/Westminster21/Westminster21/WCF/Ch 6"
        pageManager.bibleBibleBook = try XCTUnwrap(JSwordBibleBook.ordinal(forOSIS: "Gen"))
        pageManager.bibleBookEncoding = PageManager.jswordBibleBookEncoding
        pageManager.bibleVersification = JSwordKJVAVersification.name
        pageManager.bibleChapterNo = 3
        pageManager.bibleVerseNo = 1
        let window = BibleCore.Window()
        window.pageManager = pageManager
        let controller = BibleReaderController(bridge: BibleBridge(), initializesSword: false)
        controller.activeWindow = window
        controller.restoreSavedPosition()

        XCTAssertEqual(controller.currentCategory, .generalBook)
        XCTAssertEqual(
            WindowTabBar.shortReference(for: window, controller: controller),
            "/Westminster21/Westminster21/WCF/Ch 6"
        )
    }

    /** Legacy, unknown, and invalid identity domains stay unlabeled without a live source owner. */
    @MainActor
    func testDetachedReferencesFailClosedWithoutCanonicalBookEncoding() throws {
        let pageManager = PageManager()
        pageManager.currentCategoryName = DocumentCategory.bible.pageManagerKey
        pageManager.bibleBibleBook = try XCTUnwrap(JSwordBibleBook.ordinal(forOSIS: "Gen"))
        pageManager.bibleBookEncoding = nil
        pageManager.bibleVersification = JSwordKJVAVersification.name
        pageManager.bibleChapterNo = 3
        pageManager.bibleVerseNo = 1
        let window = BibleCore.Window()
        window.pageManager = pageManager

        XCTAssertNil(BibleReaderPersistedBibleReference(pageManager: pageManager))
        XCTAssertEqual(WindowTabBar.detachedShortReference(for: window), "")
        XCTAssertNil(
            BibleWindowPaneMenuSnapshotFactory.referenceName(for: window, controller: nil)
        )

        pageManager.bibleBookEncoding = PageManager.jswordBibleBookEncoding
        XCTAssertEqual(
            BibleReaderPersistedBibleReference(pageManager: pageManager)?.localizedVerseName,
            "Genesis 3:1"
        )
        XCTAssertEqual(WindowTabBar.detachedShortReference(for: window), "Gen 3")

        pageManager.bibleBookEncoding = "futureEncoding"
        XCTAssertNil(BibleReaderPersistedBibleReference(pageManager: pageManager))

        pageManager.bibleBookEncoding = PageManager.jswordBibleBookEncoding
        pageManager.bibleBibleBook = 127
        XCTAssertNil(BibleReaderPersistedBibleReference(pageManager: pageManager))
    }

    /** Canonical book identity still fails closed when its persisted location is incomplete or impossible. */
    func testCanonicalDetachedReferenceRejectsInvalidChapterVerseAndMissingVersification() throws {
        let pageManager = PageManager()
        pageManager.bibleBibleBook = try XCTUnwrap(JSwordBibleBook.ordinal(forOSIS: "Esth"))
        pageManager.bibleBookEncoding = PageManager.jswordBibleBookEncoding
        pageManager.bibleVersification = JSwordKJVAVersification.name
        pageManager.bibleChapterNo = 119
        pageManager.bibleVerseNo = 1

        XCTAssertNil(BibleReaderPersistedBibleReference(pageManager: pageManager))

        pageManager.bibleBibleBook = try XCTUnwrap(JSwordBibleBook.ordinal(forOSIS: "Gen"))
        pageManager.bibleChapterNo = 3
        pageManager.bibleVerseNo = 999
        XCTAssertNil(BibleReaderPersistedBibleReference(pageManager: pageManager))

        pageManager.bibleVerseNo = 1
        pageManager.bibleVersification = nil
        XCTAssertNil(BibleReaderPersistedBibleReference(pageManager: pageManager))

        pageManager.bibleVersification = " \n\t"
        XCTAssertNil(BibleReaderPersistedBibleReference(pageManager: pageManager))

        pageManager.bibleVersification = "Unknown"
        XCTAssertNil(BibleReaderPersistedBibleReference(pageManager: pageManager))

        pageManager.bibleVersification = JSwordKJVAVersification.name
        pageManager.bibleVerseNo = nil
        XCTAssertNil(BibleReaderPersistedBibleReference(pageManager: pageManager))

        pageManager.bibleVerseNo = 1
        pageManager.bibleChapterNo = Int(Int32.max) + 1
        XCTAssertNil(BibleReaderPersistedBibleReference(pageManager: pageManager))

        pageManager.bibleChapterNo = 3
        pageManager.bibleVerseNo = Int(Int32.max) + 1
        XCTAssertNil(BibleReaderPersistedBibleReference(pageManager: pageManager))
    }
}
