// BibleReaderPreparedCompositeDocumentTests.swift -- Immutable Multi preparation contracts

import Foundation
import XCTest
@testable import BibleUI
import BibleView

final class BibleReaderPreparedCompositeDocumentTests: XCTestCase {
    /** Java-distinct source strings never coalesce through Swift canonical equality or delimiters. */
    func testCompositeRequestIdentityPreservesExactStructuredSourceText() {
        let composed = BibleReaderMultiReferencePreparationRequest(
            references: [
                OsisRef(
                    book: "Caf\u{00E9}|Book",
                    chapter: 1,
                    verse: 1,
                    osisId: "Gen",
                    sourceVersification: "KJV|A",
                    targetBookInitials: "Target|One"
                ),
            ],
            activeModuleName: "Fallback"
        )
        let decomposed = BibleReaderMultiReferencePreparationRequest(
            references: [
                OsisRef(
                    book: "Cafe\u{0301}|Book",
                    chapter: 1,
                    verse: 1,
                    osisId: "Gen",
                    sourceVersification: "KJV|A",
                    targetBookInitials: "Target|One"
                ),
            ],
            activeModuleName: "Fallback"
        )
        let repartitioned = BibleReaderMultiReferencePreparationRequest(
            references: [
                OsisRef(
                    book: "Caf\u{00E9}",
                    chapter: 1,
                    verse: 1,
                    osisId: "Gen",
                    sourceVersification: "KJV",
                    targetBookInitials: "A|Target|One"
                ),
            ],
            activeModuleName: "Fallback"
        )

        XCTAssertNotEqual(composed.identity, decomposed.identity)
        XCTAssertNotEqual(composed.identity, repartitioned.identity)
        XCTAssertEqual(composed.identity, composed.identity)
    }

    /** Pure encoding retains copied fragments and Android's restorable Multi page key. */
    func testCopiedFragmentEncodingProducesRestorableMultiDocument() throws {
        let capture = BibleReaderCompositeSourceCapture(
            fragments: [
                OsisFragment(
                    xml: "<div><verse osisID=\"Gen.1.1\">Created</verse></div>",
                    key: "Gen.1.1",
                    keyName: "Genesis 1:1",
                    v11n: "KJVA",
                    bookCategory: "BIBLE",
                    bookInitials: "KJV",
                    bookAbbreviation: "KJV",
                    osisRef: "Gen.1.1",
                    isNewTestament: false,
                    features: OsisFeatures(),
                    hasStrongs: false,
                    ordinalRange: [4, 4],
                    language: "en",
                    direction: "ltr"
                ),
            ],
            renderedKey: "multi",
            pageKey: nil,
            contentType: nil,
            compare: false,
            sourceDependencies: [.independent],
            sourceProvenance: .swordModules(["KJV"])
        )

        let prepared = try XCTUnwrap(BibleReaderPreparedCompositeDocument.encode(capture))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(prepared.documentJSON.utf8))
                as? [String: Any]
        )
        let fragments = try XCTUnwrap(object["osisFragments"] as? [[String: Any]])

        XCTAssertEqual(object["type"] as? String, "multi")
        XCTAssertEqual(object["compare"] as? Bool, false)
        XCTAssertEqual(fragments.first?["xml"] as? String, capture.fragments[0].xml)
        XCTAssertEqual(prepared.pageKey, "KJV:Gen.1.1")
        XCTAssertEqual(prepared.sourceDependencies, [.independent])
        XCTAssertEqual(prepared.sourceProvenance, .swordModules(["KJV"]))
    }
}
