// AndroidDailyReadingPresentationTests.swift -- Daily Reading app-bar behavior contracts

import BibleCore
import XCTest
@testable import BibleUI

/** Focused tests for Android's Daily Reading action identity and app-bar visibility budget. */
final class AndroidDailyReadingPresentationTests: XCTestCase {
    /**
     Verifies Read, Speak, and Speak All operations cannot collide in progress presentation state.

     - Inputs: Read/Speak kinds with single and multiple reading-number selections.
     - Outputs: Exact stable action keys and uniqueness assertions.
     - Side effects: None.
     - Failure modes: Fails if independent commands can share a running-state identity.
     */
    func testActionKeysPreserveKindAndReadingNumbers() {
        let read = androidDailyReadingActionKey(kind: .read, readingNumbers: [1])
        let speak = androidDailyReadingActionKey(kind: .speak, readingNumbers: [1])
        let speakAll = androidDailyReadingActionKey(kind: .speak, readingNumbers: [1, 2, 3])

        XCTAssertEqual(read, "read::1")
        XCTAssertEqual(speak, "speak::1")
        XCTAssertEqual(speakAll, "speak::1-2-3")
        XCTAssertEqual(Set([read, speak, speakAll]).count, 3)
    }

    /**
     Verifies compact speech mode keeps only Android's speech controls and Bible shortcut.

     - Inputs: Compact width, active speech, and available commentary/dictionary documents.
     - Outputs: Visibility projection for speech, commentary, and dictionary controls.
     - Side effects: None.
     - Failure modes: Fails if compact speaking mode overflows with Android-hidden document actions.
     */
    func testCompactSpeechModeHidesCommentaryAndDictionary() {
        let projection = AndroidDailyReadingToolbarVisibility.resolve(
            isWide: false,
            isSpeaking: true,
            hasDictionary: true,
            hasCommentary: true
        )

        XCTAssertTrue(projection.showsSpeechControls)
        XCTAssertFalse(projection.showsDictionary)
        XCTAssertFalse(projection.showsCommentary)
    }

    /**
     Verifies expanded layouts retain every available document action while speech is active.

     - Inputs: Wide width, active speech, and available commentary/dictionary documents.
     - Outputs: Fully visible Android action projection.
     - Side effects: None.
     - Failure modes: Fails when iPad/landscape presentation incorrectly applies compact hiding.
     */
    func testWideSpeechModeKeepsDocumentActions() {
        let projection = AndroidDailyReadingToolbarVisibility.resolve(
            isWide: true,
            isSpeaking: true,
            hasDictionary: true,
            hasCommentary: true
        )

        XCTAssertTrue(projection.showsSpeechControls)
        XCTAssertTrue(projection.showsDictionary)
        XCTAssertTrue(projection.showsCommentary)
    }

    /**
     Verifies Android's resource-specific compact and expanded title budgets.

     - Inputs: One long module abbreviation at compact and expanded widths.
     - Outputs: Four- and seven-character visible labels.
     - Side effects: None.
     - Failure modes: Fails if quick-document labels can consume unbounded app-bar width.
     */
    func testDocumentTitlesUseAndroidCharacterBudgets() {
        XCTAssertEqual(
            androidDailyReadingToolbarDocumentTitle("ESV2011", isWide: false),
            "ESV2"
        )
        XCTAssertEqual(
            androidDailyReadingToolbarDocumentTitle("ESV2011-Extended", isWide: true),
            "ESV2011"
        )
    }
}
