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
