// BridgeTypesTests.swift — Tests for bridge data types

import XCTest
@testable import BibleView

final class BridgeTypesTests: XCTestCase {
    func testOsisFragmentCodable() throws {
        let fragment = OsisFragment(
            xml: "<div>In the beginning...</div>",
            key: "Gen.1.1",
            keyName: "Genesis 1:1",
            v11n: "KJVA",
            bookCategory: "BIBLE",
            bookInitials: "KJV",
            bookAbbreviation: "KJV",
            osisRef: "Gen.1.1",
            isNewTestament: false,
            ordinalRange: [0, 10],
            language: "en",
            direction: "ltr"
        )

        let data = try bridgeEncoder.encode(fragment)
        let decoded = try bridgeDecoder.decode(OsisFragment.self, from: data)

        XCTAssertEqual(decoded.key, "Gen.1.1")
        XCTAssertEqual(decoded.bookInitials, "KJV")
        XCTAssertEqual(decoded.direction, "ltr")
        XCTAssertEqual(decoded.ordinalRange, [0, 10])
    }

    func testBookmarkStyleDataDefaults() {
        let style = BookmarkStyleData()
        XCTAssertEqual(style.color, 0xFF91A7FF)
        XCTAssertFalse(style.isSpeak)
        XCTAssertFalse(style.isParagraphBreak)
        XCTAssertFalse(style.underline)
    }

    func testLabelDataCodable() throws {
        let label = LabelData(
            id: "550e8400-e29b-41d4-a716-446655440000",
            name: "Important",
            style: BookmarkStyleData(color: 0xFFFF0000, underline: true),
            isRealLabel: true
        )

        let data = try bridgeEncoder.encode(label)
        let decoded = try bridgeDecoder.decode(LabelData.self, from: data)

        XCTAssertEqual(decoded.name, "Important")
        XCTAssertEqual(decoded.style.color, 0xFFFF0000)
        XCTAssertTrue(decoded.style.underline)
    }

    func testSelectionQueryCodable() throws {
        let query = SelectionQuery(
            bookInitials: "KJV",
            osisRef: "Gen.1.1-Gen.1.3",
            startOrdinal: 0,
            startOffset: 0,
            endOrdinal: 2,
            endOffset: 50,
            bookmarks: ["id1", "id2"],
            text: "In the beginning God created..."
        )

        let data = try bridgeEncoder.encode(query)
        let decoded = try bridgeDecoder.decode(SelectionQuery.self, from: data)

        XCTAssertEqual(decoded.bookInitials, "KJV")
        XCTAssertEqual(decoded.bookmarks.count, 2)
        XCTAssertEqual(decoded.startOrdinal, 0)
        XCTAssertEqual(decoded.endOrdinal, 2)
    }
}
