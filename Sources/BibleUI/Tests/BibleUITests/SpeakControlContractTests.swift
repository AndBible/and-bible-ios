import BibleCore
import XCTest
@testable import BibleUI

/** Contract tests for Android timer and two-stage repeated-passage control state. */
final class SpeakControlContractTests: XCTestCase {
    /** Verifies restored timer defaults are constrained to Android's 1-through-120 picker. */
    func testTimerSelectionUsesCompleteAndroidMinuteDomain() {
        XCTAssertEqual(SpeakTimerSelection.validMinutes, 1...120)
        XCTAssertEqual(SpeakTimerSelection.normalized(-1), 1)
        XCTAssertEqual(SpeakTimerSelection.normalized(1), 1)
        XCTAssertEqual(SpeakTimerSelection.normalized(37), 37)
        XCTAssertEqual(SpeakTimerSelection.normalized(121), 120)
    }

    /** Verifies passage selection requires a beginning followed by one strictly later ending. */
    func testVerseRangeDraftUsesTwoStrictExactPositionStages() {
        let positions = (1...3).map(makePosition)
        var draft = SpeakVerseRangeDraft(positions: positions)

        XCTAssertEqual(draft.availablePositions, Array(positions.dropLast()))
        XCTAssertEqual(draft.select(positions[1]), .awaitingEnd)
        XCTAssertEqual(draft.start, positions[1])
        XCTAssertEqual(draft.availablePositions, [positions[2]])
        XCTAssertEqual(draft.select(positions[1]), .invalid)
        XCTAssertEqual(
            draft.select(positions[2]),
            .completed(start: positions[1], end: positions[2])
        )
    }

    /**
     Verifies semantic passage-list capability hides the contiguous range editor.

     Android legacy key lists can be discontiguous or duplicated, so position count alone must not
     expose a control that could widen persisted repeat state across passage boundaries.
     */
    func testVerseRangeEditorHidesWhenProviderRejectsRangeEditing() {
        XCTAssertFalse(
            SpeakVerseRangeControlAvailability.isVisible(
                supportsEditing: false,
                positionCount: 4
            )
        )
        XCTAssertTrue(
            SpeakVerseRangeControlAvailability.isVisible(
                supportsEditing: true,
                positionCount: 4
            )
        )
    }

    /** Verifies the shared passage chooser receives the provider's complete ordered Bible canon. */
    func testPassageChooserCatalogDerivesBooksAndChapterBoundsFromExactPositions() {
        let positions = [
            makeCatalogPosition(osisId: "Gen", chapter: 1, verse: 1),
            makeCatalogPosition(osisId: "Gen", chapter: 2, verse: 3),
            makeCatalogPosition(osisId: "Matt", chapter: 1, verse: 2),
        ]

        let books = SpeakPassageChooserCatalog.books(from: positions)

        XCTAssertEqual(books.map(\.osisId), ["Gen", "Matt"])
        XCTAssertEqual(books.map(\.chapterCount), [2, 1])
        XCTAssertEqual(books.map(\.testament), [1, 2])
        XCTAssertEqual(
            SpeakPassageChooserCatalog.verseCount(
                for: books[0],
                chapter: 2,
                positions: positions
            ),
            3
        )
    }

    /** Verifies grid results resolve to exact provider positions without display-name guessing. */
    func testPassageChooserCatalogResolvesExactOSISPosition() throws {
        let positions = [
            makeCatalogPosition(osisId: "Gen", chapter: 1, verse: 1),
            makeCatalogPosition(osisId: "Gen", chapter: 1, verse: 2),
        ]
        let book = try XCTUnwrap(SpeakPassageChooserCatalog.books(from: positions).first)

        XCTAssertEqual(
            SpeakPassageChooserCatalog.position(
                book: book,
                chapter: 1,
                verse: 2,
                positions: positions
            ),
            positions[1]
        )
        XCTAssertNil(
            SpeakPassageChooserCatalog.position(
                book: book,
                chapter: 1,
                verse: 3,
                positions: positions
            )
        )
    }

    /** Creates one catalog position with independent book/chapter/verse identity. */
    private func makeCatalogPosition(
        osisId: String,
        chapter: Int,
        verse: Int
    ) -> SpeakStreamPosition {
        SpeakStreamPosition(
            id: "KJV:\(osisId).\(chapter).\(verse)",
            category: .bible,
            bookInitials: "KJV",
            key: "\(osisId).\(chapter).\(verse)",
            osisRef: "\(osisId).\(chapter).\(verse)",
            keyName: "\(osisId) \(chapter):\(verse)",
            bookName: "KJV",
            ordinalStart: verse,
            ordinalEnd: verse,
            chapter: chapter,
            verse: verse,
            groupIdentifier: "\(osisId).\(chapter)",
            language: "en",
            versification: "KJV"
        )
    }

    /** Creates one exact Bible position for range-selection state tests. */
    private func makePosition(_ verse: Int) -> SpeakStreamPosition {
        SpeakStreamPosition(
            id: "KJV:Gen.1.\(verse)",
            category: .bible,
            bookInitials: "KJV",
            key: "Gen.1.\(verse)",
            osisRef: "Gen.1.\(verse)",
            keyName: "Genesis 1:\(verse)",
            bookName: "Genesis",
            ordinalStart: verse,
            ordinalEnd: verse,
            chapter: 1,
            verse: verse,
            groupIdentifier: "Gen.1",
            language: "en",
            versification: "KJV"
        )
    }
}
