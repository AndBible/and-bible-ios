import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI

/** Protects the prior-location history contract shared by direct and adjacent reader navigation. */
@MainActor
final class BibleReaderChapterHistoryParityTests: XCTestCase {
    /** Escaping state captured by the navigation context. */
    private final class State {
        var position = BibleReaderNavigationPosition(book: "Genesis", chapter: 1, verse: 1)
        var history: [BibleReaderNavigationPosition] = []
        var positionObservedDuringHistory: [BibleReaderNavigationPosition] = []
        var persistCount = 0
        var loadCount = 0
    }

    /**
     Verifies direct selection and adjacent navigation both record the location being left.

     Android posts `AddHistoryItem` before `doSetKey`. This test invokes the coordinator entry point
     used by the chooser and then its next-chapter entry point used by horizontal swipe policy. Each
     history callback must receive and observe the prior location; both accepted transitions still
     persist once and request one content load.
     */
    func testDirectAndAdjacentChapterNavigationRecordPriorLocationBeforeMutation() throws {
        let coordinator = BibleReaderNavigationCoordinator()
        let state = State()
        let container = try makeWorkspaceModelContainer()
        let workspaceStore = WorkspaceStore(modelContext: ModelContext(container))
        let workspace = workspaceStore.createWorkspace(name: "Issue 421 navigation")
        let pageManager = try XCTUnwrap(workspace.windows?.first?.pageManager)
        pageManager.bibleDocument = "KJV"
        pageManager.bibleBibleBook = 0
        pageManager.bibleChapterNo = 1
        pageManager.bibleVerseNo = 1
        let books = [
            BibleReaderNavigationBook(name: "Genesis", osisId: "Gen", chapterCount: 50),
            BibleReaderNavigationBook(name: "Exodus", osisId: "Exod", chapterCount: 40),
        ]
        let context = BibleReaderNavigationContext(
            currentPosition: { state.position },
            setCurrentPosition: { state.position = $0 },
            pageManager: { pageManager },
            bookList: { books },
            isShowingAndroidMultiDocument: { false },
            clientReady: { true },
            chapterCount: { name in books.first { $0.name == name }?.chapterCount ?? 0 },
            nextBook: { name in
                guard let index = books.firstIndex(where: { $0.name == name }),
                      index + 1 < books.count else { return nil }
                return books[index + 1].name
            },
            previousBook: { name in
                guard let index = books.firstIndex(where: { $0.name == name }), index > 0 else {
                    return nil
                }
                return books[index - 1].name
            },
            bookNameForOsisId: { osisID in books.first { $0.osisId == osisID }?.name },
            ordinalForVerse: { _, chapter, verse in chapter * 100 + verse },
            verseReference: { _, ordinal in
                BibleReaderNavigationVerseReference(
                    chapter: ordinal / 100,
                    verse: ordinal % 100,
                    osisBookId: "Gen",
                    ordinal: ordinal
                )
            },
            recordHistory: { book, chapter, verse in
                state.positionObservedDuringHistory.append(state.position)
                state.history.append(
                    BibleReaderNavigationPosition(book: book, chapter: chapter, verse: verse)
                )
                return true
            },
            persistState: { state.persistCount += 1 },
            scrollToLoadedPosition: { _, _ in false },
            loadCurrentContent: { state.loadCount += 1 }
        )

        coordinator.navigateTo(book: "Genesis", chapter: 2, context: context)
        coordinator.navigateNext(context: context)

        XCTAssertEqual(
            state.history,
            [
                BibleReaderNavigationPosition(book: "Genesis", chapter: 1, verse: 1),
                BibleReaderNavigationPosition(book: "Genesis", chapter: 2, verse: 1),
            ]
        )
        XCTAssertEqual(state.positionObservedDuringHistory, state.history)
        XCTAssertEqual(
            state.position,
            BibleReaderNavigationPosition(book: "Genesis", chapter: 3, verse: 1)
        )
        XCTAssertEqual(pageManager.bibleChapterNo, 3)
        XCTAssertEqual(state.persistCount, 2)
        XCTAssertEqual(state.loadCount, 2)
        withExtendedLifetime(container) {}
    }
}
