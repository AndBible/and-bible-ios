import BibleCore
import XCTest
@testable import BibleUI

final class BibleReaderPreparedDocumentPayloadTests: XCTestCase {
    /** The immutable worker encoder preserves the established Bible document schema byte-for-byte. */
    func testPreparedBiblePayloadMatchesOwnerBackedFactoryProjection() throws {
        let xml = #"<div><verse osisID="Gen.1.1">In the beginning</verse></div>"#
        let expected = try XCTUnwrap(
            BibleReaderDocumentPayloadFactory(
                activeModuleName: "KJV",
                hasStrongs: true,
                bookmarkPayload: { _ in
                    XCTFail("Fixture has no bookmarks")
                    fatalError("Unexpected bookmark projection")
                },
                chapterOrdinalRange: { _, _, _ in
                    (start: 4, end: 34, verseCount: 31)
                },
                kjvBookOrdinal: { _ in 1 },
                chapterReadCount: { _, _ in 2 },
                memorizedOrdinals: { _, _, _ in [4, 5] },
                targetOrdinals: { _, _, _ in [6] }
            ).documentJSON(
                BibleReaderDocumentPayloadRequest(
                    osisBookId: "Gen",
                    bookName: "Genesis",
                    chapter: 1,
                    verseCount: 31,
                    isNewTestament: false,
                    xml: xml,
                    moduleName: "King James Version",
                    moduleAbbreviation: "KJV",
                    versificationName: "KJV",
                    sourceHasStrongs: true
                )
            )
        )

        let actual = try XCTUnwrap(
            BibleReaderPreparedDocumentPayload(
                osisBookId: "Gen",
                bookName: "Genesis",
                chapter: 1,
                isNewTestament: false,
                xml: xml,
                bookCategory: DocumentCategory.bible.rawValue,
                bookInitials: "KJV",
                addChapter: true,
                originalOrdinalRange: nil,
                documentKey: "Gen.1",
                keyName: "Genesis 1",
                ordinalRange: [4, 34],
                fragmentOrdinalRange: [4, 34],
                fragmentKey: "KJV--Gen.1",
                fragmentOsisRef: "Gen.1",
                annotateRef: "Gen.1",
                fragmentFeatures: [:],
                commentaryRange: nil,
                moduleName: "King James Version",
                moduleAbbreviation: "KJV",
                versificationName: "KJV",
                language: "en",
                direction: "ltr",
                hasStrongs: true,
                bookmarks: [],
                genericBookmarks: [],
                aiDocMarkers: [],
                memorizedOrdinals: [4, 5],
                targetOrdinals: [6],
                chapterReadCount: 2,
                isNativeHTML: false
            ).encodedJSON()
        )

        XCTAssertEqual(actual, expected)
    }

    /** A Bible payload missing its source range is rejected before serialization. */
    func testPreparedBiblePayloadFailsClosedWithoutAuthorizedOrdinalRange() {
        let payload = BibleReaderPreparedDocumentPayload(
            osisBookId: "Gen",
            bookName: "Genesis",
            chapter: 1,
            isNewTestament: false,
            xml: "<div/>",
            bookCategory: DocumentCategory.bible.rawValue,
            bookInitials: "KJV",
            addChapter: true,
            originalOrdinalRange: nil,
            documentKey: "Gen.1",
            keyName: "Genesis 1",
            ordinalRange: nil,
            fragmentOrdinalRange: nil,
            fragmentKey: "KJV--Gen.1",
            fragmentOsisRef: "Gen.1",
            annotateRef: "Gen.1",
            fragmentFeatures: [:],
            commentaryRange: nil,
            moduleName: "King James Version",
            moduleAbbreviation: "KJV",
            versificationName: "KJV",
            language: "en",
            direction: "ltr",
            hasStrongs: true,
            bookmarks: [],
            genericBookmarks: [],
            aiDocMarkers: [],
            memorizedOrdinals: [],
            targetOrdinals: [],
            chapterReadCount: nil,
            isNativeHTML: false
        )

        XCTAssertNil(payload.encodedJSON())
    }
}
