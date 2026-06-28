// BookmarkTests.swift — Tests for BibleCore bookmark models

import XCTest
@testable import BibleCore

final class BookmarkModelTests: XCTestCase {
    func testBibleBookmarkDefaults() {
        let bookmark = BibleBookmark()
        XCTAssertEqual(bookmark.v11n, "KJVA")
        XCTAssertTrue(bookmark.wholeVerse)
        XCTAssertNil(bookmark.startOffset)
        XCTAssertNil(bookmark.endOffset)
        XCTAssertNil(bookmark.primaryLabelId)
        XCTAssertNil(bookmark.customIcon)
    }

    func testLabelConstants() {
        XCTAssertEqual(Label.speakLabelName, "__SPEAK_LABEL__")
        XCTAssertEqual(Label.unlabeledName, "__UNLABELED__")
        XCTAssertEqual(Label.paragraphBreakLabelName, "__PARAGRAPH_BREAK_LABEL__")
    }

    func testLabelSystemDetection() {
        let userLabel = Label(name: "My Study")
        XCTAssertTrue(userLabel.isRealLabel)
        XCTAssertFalse(userLabel.isSystemLabel)

        let speakLabel = Label(name: Label.speakLabelName)
        XCTAssertFalse(speakLabel.isRealLabel)
        XCTAssertTrue(speakLabel.isSystemLabel)
    }

    func testEditAction() {
        var action = EditAction()
        XCTAssertNil(action.mode)
        XCTAssertNil(action.content)

        action = EditAction(mode: .append, content: "test")
        XCTAssertEqual(action.mode, .append)
        XCTAssertEqual(action.content, "test")
    }

    func testBookmarkStylePresetColors() {
        XCTAssertEqual(BookmarkStylePreset.blueHighlight.color, 0xFF91A7FF)
        XCTAssertEqual(BookmarkStylePreset.redHighlight.color, 0xFFFF9999)
        XCTAssertNotEqual(BookmarkStylePreset.yellowStar.color, BookmarkStylePreset.greenHighlight.color)
    }

}
