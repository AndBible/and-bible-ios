// BridgeTypesTests.swift — Tests for bridge data types

import XCTest
@testable import BibleView

final class BridgeTypesTests: XCTestCase {
    /**
     Protects the default OSIS fragment bridge shape when no module features are available.

     The Swift initializer is commonly used without an explicit `features` argument for plain Bible
     fragments. A passing test proves those callers still emit the TypeScript-required `features`
     object as `{}` instead of omitting the key, which would break the shared client object contract.
     */
    func testOsisFragmentDefaultFeaturesEncodeAsEmptyObject() throws {
        let fragment = OsisFragment(
            xml: "<div>In the beginning...</div>",
            key: "Gen.1.1",
            keyName: "Genesis 1:1",
            bookInitials: "KJV"
        )

        let object = try bridgeJSONObject(fragment)

        let features = try XCTUnwrap(object["features"] as? [String: Any])
        XCTAssertTrue(features.isEmpty)
    }

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
            direction: "ltr",
            isNativeHtml: true
        )

        let data = try bridgeEncoder.encode(fragment)
        let decoded = try bridgeDecoder.decode(OsisFragment.self, from: data)

        XCTAssertEqual(decoded.key, "Gen.1.1")
        XCTAssertEqual(decoded.bookInitials, "KJV")
        XCTAssertEqual(decoded.direction, "ltr")
        XCTAssertEqual(decoded.ordinalRange, [0, 10])
        XCTAssertNil(decoded.features.type)
        XCTAssertNil(decoded.features.keyName)
        XCTAssertTrue(decoded.isNativeHtml)
    }

    /**
     Protects the package-level `OsisFragment` payload contract consumed by the Vue reader.

     The expected key set tracks `bibleview-js/src/types/client-objects.ts`; a failure means
     Swift bridge serialization drifted from the shared client object shape used by Android
     and iOS renderer code.
     */
    func testOsisFragmentPayloadKeysMatchClientObjectContract() throws {
        let fragment = OsisFragment(
            xml: "<div>In the beginning...</div>",
            key: "Gen.1",
            keyName: "Genesis 1",
            v11n: "KJVA",
            bookCategory: "BIBLE",
            bookInitials: "KJV",
            bookAbbreviation: "Gen",
            osisRef: "Gen.1",
            isNewTestament: false,
            features: OsisFeatures(type: "hebrew", keyName: "H00430"),
            hasStrongs: true,
            ordinalRange: [1, 31],
            language: "en",
            direction: "ltr"
        )

        let object = try bridgeJSONObject(fragment)

        XCTAssertJSONKeys(
            object,
            [
                "xml",
                "key",
                "keyName",
                "v11n",
                "bookCategory",
                "bookInitials",
                "bookAbbreviation",
                "osisRef",
                "isNewTestament",
                "features",
                "hasStrongs",
                "ordinalRange",
                "language",
                "direction",
                "isNativeHtml",
            ]
        )
        XCTAssertEqual(object["keyName"] as? String, "Genesis 1")
        XCTAssertEqual(object["bookInitials"] as? String, "KJV")
        XCTAssertEqual(object["bookAbbreviation"] as? String, "Gen")
        XCTAssertEqual(object["osisRef"] as? String, "Gen.1")
        XCTAssertEqual(object["direction"] as? String, "ltr")
        XCTAssertEqual(object["hasStrongs"] as? Bool, true)
        XCTAssertEqual(object["isNativeHtml"] as? Bool, false)

        let features = try XCTUnwrap(object["features"] as? [String: Any])
        XCTAssertJSONKeys(features, ["type", "keyName"])
        XCTAssertEqual(features["type"] as? String, "hebrew")
        XCTAssertEqual(features["keyName"] as? String, "H00430")
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

    func testLabelPayloadKeysMatchClientObjectContract() throws {
        let label = LabelData(
            id: "550e8400-e29b-41d4-a716-446655440000",
            name: "Important",
            style: BookmarkStyleData(
                color: 0xFFFF0000,
                isSpeak: true,
                isParagraphBreak: true,
                underline: true,
                underlineWholeVerse: true,
                markerStyle: true,
                markerStyleWholeVerse: true,
                hideStyle: true,
                hideStyleWholeVerse: true,
                customIcon: "star"
            ),
            isRealLabel: true
        )

        let object = try bridgeJSONObject(label)

        XCTAssertJSONKeys(object, ["id", "name", "style", "isRealLabel"])
        XCTAssertEqual(object["id"] as? String, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(object["name"] as? String, "Important")
        XCTAssertEqual(object["isRealLabel"] as? Bool, true)

        let style = try XCTUnwrap(object["style"] as? [String: Any])
        XCTAssertJSONKeys(
            style,
            [
                "color",
                "isSpeak",
                "isParagraphBreak",
                "underline",
                "underlineWholeVerse",
                "markerStyle",
                "markerStyleWholeVerse",
                "hideStyle",
                "hideStyleWholeVerse",
                "customIcon",
            ]
        )
        XCTAssertEqual(style["color"] as? Int, 0xFFFF0000)
        XCTAssertEqual(style["isSpeak"] as? Bool, true)
        XCTAssertEqual(style["isParagraphBreak"] as? Bool, true)
        XCTAssertEqual(style["underlineWholeVerse"] as? Bool, true)
        XCTAssertEqual(style["markerStyleWholeVerse"] as? Bool, true)
        XCTAssertEqual(style["hideStyleWholeVerse"] as? Bool, true)
        XCTAssertEqual(style["customIcon"] as? String, "star")
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

    func testSelectionQueryPayloadKeysMatchWebClientContract() throws {
        let query = SelectionQuery(
            bookInitials: "KJV",
            osisRef: "Gen.1.1-Gen.1.3",
            startOrdinal: 0,
            startOffset: 1,
            endOrdinal: 2,
            endOffset: 50,
            bookmarks: ["id1", "id2"],
            text: "In the beginning God created..."
        )

        let object = try bridgeJSONObject(query)

        XCTAssertJSONKeys(
            object,
            [
                "bookInitials",
                "osisRef",
                "startOrdinal",
                "startOffset",
                "endOrdinal",
                "endOffset",
                "bookmarks",
                "text",
            ]
        )
        XCTAssertEqual(object["bookInitials"] as? String, "KJV")
        XCTAssertEqual(object["osisRef"] as? String, "Gen.1.1-Gen.1.3")
        XCTAssertEqual(object["startOrdinal"] as? Int, 0)
        XCTAssertEqual(object["startOffset"] as? Int, 1)
        XCTAssertEqual(object["endOrdinal"] as? Int, 2)
        XCTAssertEqual(object["endOffset"] as? Int, 50)
        XCTAssertEqual(object["bookmarks"] as? [String], ["id1", "id2"])
        XCTAssertEqual(object["text"] as? String, "In the beginning God created...")
    }
}

private func bridgeJSONObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try bridgeEncoder.encode(value)
    let object = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(object as? [String: Any])
}

private func XCTAssertJSONKeys(
    _ object: [String: Any],
    _ expectedKeys: Set<String>,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(Set(object.keys), expectedKeys, file: file, line: line)
}
