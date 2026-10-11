import Foundation
import SwiftData
import XCTest
@testable import BibleCore

/** Verifies the one-way PageManager transition to Android's JSword Bible position identity. */
@MainActor
final class PageManagerBibleBookEncodingMigrationTests: XCTestCase {
    func testNewPageManagerStartsAtCompleteAndroidDefault() {
        let pageManager = PageManager()

        XCTAssertEqual(pageManager.bibleBookEncoding, PageManager.jswordBibleBookEncoding)
        XCTAssertEqual(pageManager.biblePositionForAndroid, .androidDefault)
        XCTAssertEqual(pageManager.bibleVersification, "KJV")
        XCTAssertEqual(pageManager.bibleBibleBook, 2)
        XCTAssertEqual(pageManager.bibleChapterNo, 1)
        XCTAssertEqual(pageManager.bibleVerseNo, 1)
    }

    func testNormalizationResetsAmbiguousTupleAndPreservesDocumentAndAuxiliaryState() {
        let pageManager = PageManager(currentCategoryName: "general_book")
        pageManager.bibleDocument = "ESV"
        pageManager.bibleVersification = "Vulg"
        pageManager.bibleBibleBook = 17
        pageManager.bibleChapterNo = 5
        pageManager.bibleVerseNo = 9
        pageManager.bibleBookEncoding = "futureEncoding"
        pageManager.commentaryDocument = "MHC"
        pageManager.dictionaryKey = "grace"
        pageManager.generalBookDocument = "Westminster21"
        pageManager.generalBookKey = "/Westminster21/WCF/Ch 6"
        pageManager.mapKey = "Jerusalem"
        pageManager.epubHref = "chapter-7.xhtml"
        pageManager.jsState = #"{"scrollY":640}"#

        XCTAssertTrue(pageManager.normalizeBibleBookEncodingToJSwordOrdinal())
        XCTAssertEqual(pageManager.biblePositionForAndroid, .androidDefault)
        XCTAssertEqual(pageManager.bibleDocument, "ESV")
        XCTAssertEqual(pageManager.commentaryDocument, "MHC")
        XCTAssertEqual(pageManager.dictionaryKey, "grace")
        XCTAssertEqual(pageManager.generalBookDocument, "Westminster21")
        XCTAssertEqual(pageManager.generalBookKey, "/Westminster21/WCF/Ch 6")
        XCTAssertEqual(pageManager.mapKey, "Jerusalem")
        XCTAssertEqual(pageManager.epubHref, "chapter-7.xhtml")
        XCTAssertEqual(pageManager.currentCategoryName, "general_book")
        XCTAssertEqual(pageManager.jsState, #"{"scrollY":640}"#)
        XCTAssertFalse(pageManager.normalizeBibleBookEncodingToJSwordOrdinal())
    }

    func testNormalizationResetsIncompleteCanonicalTupleButPreservesCompleteUnknownVersification() {
        let incomplete = PageManager()
        incomplete.bibleBookEncoding = PageManager.jswordBibleBookEncoding
        incomplete.bibleVersification = nil
        incomplete.bibleBibleBook = 20
        incomplete.bibleChapterNo = 119
        incomplete.bibleVerseNo = 1

        XCTAssertTrue(incomplete.normalizeBibleBookEncodingToJSwordOrdinal())
        XCTAssertEqual(incomplete.biblePositionForAndroid, .androidDefault)

        let unknownVersification = PageManager()
        unknownVersification.bibleBookEncoding = PageManager.jswordBibleBookEncoding
        unknownVersification.bibleVersification = "FutureV11N"
        unknownVersification.bibleBibleBook = 126
        unknownVersification.bibleChapterNo = 16
        unknownVersification.bibleVerseNo = 24

        XCTAssertFalse(unknownVersification.normalizeBibleBookEncodingToJSwordOrdinal())
        XCTAssertEqual(
            unknownVersification.biblePositionForAndroid,
            PageManagerBiblePosition(
                versification: "FutureV11N",
                bookOrdinal: 126,
                chapter: 16,
                verse: 24
            )
        )
    }

    func testCloneAndAndroidRestoreProjectionCannotCopyLegacyInteger() {
        let source = PageManager(currentCategoryName: "map")
        source.bibleDocument = "ESV"
        source.bibleVersification = "Vulg"
        source.bibleBibleBook = 17
        source.bibleChapterNo = 5
        source.bibleVerseNo = 9
        source.bibleBookEncoding = nil
        source.mapDocument = "BibleAtlas"
        source.mapKey = "Jerusalem"

        let clone = PageManager()
        clone.copyPersistedReaderState(from: source)

        XCTAssertEqual(clone.biblePositionForAndroid, .androidDefault)
        XCTAssertEqual(clone.bibleDocument, "ESV")
        XCTAssertEqual(clone.currentCategoryName, "map")
        XCTAssertEqual(clone.mapDocument, "BibleAtlas")
        XCTAssertEqual(clone.mapKey, "Jerusalem")

        let stagedRestore = RemoteSyncAndroidWorkspacePageManager(
            windowID: UUID(),
            bibleDocument: "ESV",
            bibleVersification: "Vulg",
            bibleBook: 17,
            bibleBookEncoding: nil,
            bibleChapterNo: 5,
            bibleVerseNo: 9,
            commentaryDocument: nil,
            commentaryAnchorOrdinal: nil,
            commentarySourceBookAndKey: nil,
            dictionaryDocument: nil,
            dictionaryKey: nil,
            dictionaryAnchorOrdinal: nil,
            generalBookDocument: "Westminster21",
            generalBookKey: "/Westminster21/WCF/Ch 6",
            generalBookAnchorOrdinal: nil,
            mapDocument: nil,
            mapKey: nil,
            mapAnchorOrdinal: nil,
            currentCategoryName: "GENERAL_BOOK",
            textDisplaySettings: nil,
            jsState: nil
        )

        XCTAssertEqual(stagedRestore.biblePositionForAndroid, .androidDefault)
        XCTAssertEqual(stagedRestore.bibleDocument, "ESV")
        XCTAssertEqual(stagedRestore.generalBookDocument, "Westminster21")
        XCTAssertEqual(stagedRestore.generalBookKey, "/Westminster21/WCF/Ch 6")
    }

    func testMigrationNormalizesEveryAmbiguousRowOnceWithoutChangingWorkspaceGraph() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let workspace = Workspace(name: "Study", orderNumber: 0)
        let legacyWindow = Window(orderNumber: 0)
        let unknownWindow = Window(orderNumber: 1)
        let canonicalWindow = Window(orderNumber: 2)
        legacyWindow.workspace = workspace
        unknownWindow.workspace = workspace
        canonicalWindow.workspace = workspace

        let legacy = PageManager(id: legacyWindow.id, currentCategoryName: "dictionary")
        legacy.window = legacyWindow
        legacy.bibleDocument = "KJV"
        legacy.bibleVersification = "KJVA"
        legacy.bibleBibleBook = 17
        legacy.bibleChapterNo = 23
        legacy.bibleVerseNo = 1
        legacy.bibleBookEncoding = nil
        legacy.dictionaryDocument = "StrongsGreek"
        legacy.dictionaryKey = "G5485"

        let unknown = PageManager(id: unknownWindow.id, currentCategoryName: "general_book")
        unknown.window = unknownWindow
        unknown.bibleDocument = "Vulgate"
        unknown.bibleVersification = "Vulg"
        unknown.bibleBibleBook = 18
        unknown.bibleChapterNo = 5
        unknown.bibleVerseNo = 1
        unknown.bibleBookEncoding = "newerEncoding"
        unknown.generalBookDocument = "Westminster21"
        unknown.generalBookKey = "/Westminster21/WCF/Ch 6"

        let canonical = PageManager(id: canonicalWindow.id, currentCategoryName: "bible")
        canonical.window = canonicalWindow
        canonical.bibleDocument = "ExtendedCanon"
        canonical.bibleVersification = "FutureV11N"
        canonical.bibleBibleBook = 126
        canonical.bibleChapterNo = 16
        canonical.bibleVerseNo = 24

        context.insert(workspace)
        context.insert(legacyWindow)
        context.insert(unknownWindow)
        context.insert(canonicalWindow)
        context.insert(legacy)
        context.insert(unknown)
        context.insert(canonical)
        try context.save()

        let saveExpectation = expectation(description: "Normalization persists one batch")
        saveExpectation.expectedFulfillmentCount = 1
        saveExpectation.assertForOverFulfill = true
        let observer = NotificationCenter.default.addObserver(
            forName: ModelContext.willSave,
            object: context,
            queue: nil
        ) { _ in saveExpectation.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        let service = PageManagerBibleBookEncodingMigrationService(modelContext: context)
        XCTAssertEqual(
            try service.migrate(),
            PageManagerBibleBookEncodingMigrationReport(normalizedPageManagerCount: 2)
        )
        wait(for: [saveExpectation], timeout: 1)
        XCTAssertEqual(legacy.biblePositionForAndroid, .androidDefault)
        XCTAssertEqual(unknown.biblePositionForAndroid, .androidDefault)
        XCTAssertEqual(legacy.bibleDocument, "KJV")
        XCTAssertEqual(legacy.dictionaryDocument, "StrongsGreek")
        XCTAssertEqual(legacy.dictionaryKey, "G5485")
        XCTAssertEqual(unknown.bibleDocument, "Vulgate")
        XCTAssertEqual(unknown.generalBookDocument, "Westminster21")
        XCTAssertEqual(unknown.generalBookKey, "/Westminster21/WCF/Ch 6")
        XCTAssertEqual(
            canonical.biblePositionForAndroid,
            PageManagerBiblePosition(
                versification: "FutureV11N",
                bookOrdinal: 126,
                chapter: 16,
                verse: 24
            )
        )
        XCTAssertEqual(workspace.windows?.count, 3)

        XCTAssertEqual(
            try service.migrate(),
            PageManagerBibleBookEncodingMigrationReport(normalizedPageManagerCount: 0)
        )
        XCTAssertFalse(context.hasChanges)
    }

    func testOutboundSnapshotProjectsLegacyTupleAsWholeAndroidDefault() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let workspace = Workspace(name: "Export", orderNumber: 0)
        let window = Window(orderNumber: 0)
        window.workspace = workspace
        let pageManager = PageManager(id: window.id, currentCategoryName: "general_book")
        pageManager.window = window
        pageManager.bibleDocument = "ESV"
        pageManager.bibleVersification = "Vulg"
        pageManager.bibleBibleBook = 17
        pageManager.bibleChapterNo = 5
        pageManager.bibleVerseNo = 9
        pageManager.bibleBookEncoding = nil
        pageManager.generalBookDocument = "Westminster21"
        pageManager.generalBookKey = "/Westminster21/WCF/Ch 6"
        context.insert(workspace)
        context.insert(window)
        context.insert(pageManager)
        try context.save()

        let snapshot = RemoteSyncWorkspaceSnapshotService().snapshotCurrentState(
            modelContext: context,
            settingsStore: SettingsStore(modelContext: context)
        )
        let row = try XCTUnwrap(snapshot.pageManagerRowsByKey.values.first)

        XCTAssertEqual(row.bibleDocument, "ESV")
        XCTAssertEqual(row.bibleVersification, "KJV")
        XCTAssertEqual(row.bibleBook, 2)
        XCTAssertEqual(row.bibleChapterNo, 1)
        XCTAssertEqual(row.bibleVerseNo, 1)
        XCTAssertEqual(row.generalBookDocument, "Westminster21")
        XCTAssertEqual(row.generalBookKey, "/Westminster21/WCF/Ch 6")
        XCTAssertEqual(pageManager.bibleBibleBook, 17, "Pure export projection must not mutate storage")
        XCTAssertNil(pageManager.bibleBookEncoding)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Setting.self,
            Workspace.self,
            Window.self,
            PageManager.self,
            HistoryItem.self,
            BibleBookmark.self,
            BibleBookmarkNotes.self,
            BibleBookmarkToLabel.self,
            GenericBookmark.self,
            GenericBookmarkNotes.self,
            GenericBookmarkToLabel.self,
            Label.self,
            StudyPadTextEntry.self,
            StudyPadTextEntryText.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
