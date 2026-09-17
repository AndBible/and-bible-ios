import XCTest
import SwordKit
@testable import BibleCore
@testable import BibleUI

/** Encoding, exact request identity, and native capture contracts for prepared Memorize documents. */
final class BibleReaderPreparedMemorizeDocumentTests: BibleUISwordFixtureTestCase {
    /** Encodes copied source/progress values without consulting persistence or native modules. */
    func testEncodeProjectsKJVAProgressAndPreservesVueState() throws {
        let capture = BibleReaderMemorizeSourceCapture(
            bookInitials: "KJV",
            startOrdinal: 4,
            endOrdinal: 5,
            title: "Genesis 1:1-2",
            osisReference: "Gen.1.1-Gen.1.2",
            sourceBookAndKeyJSON: #"{"document":"KJV","key":"Gen.1.1-Gen.1.2"}"#,
            sourceVersification: "KJV",
            references: [
                .init(osisBookId: "Gen", chapter: 1, verse: 1, ordinal: 4),
                .init(osisBookId: "Gen", chapter: 1, verse: 2, ordinal: 5),
            ],
            textItems: [
                .init(key: "Gen.1.1", text: "In the beginning"),
                .init(key: "Gen.1.2", text: "The earth was without form"),
            ],
            memorizationProjections: [
                .init(renderedOrdinal: 40, kjvaOrdinal: 4),
                .init(renderedOrdinal: 41, kjvaOrdinal: 5),
            ],
            kjvaOrdinalStart: 4,
            kjvaOrdinalEnd: 5,
            sourceDependencies: [.independent]
        )
        let owner = BibleReaderMemorizeOwnerSnapshot(
            memorizedKJVAOrdinals: [4],
            targetKJVAOrdinals: [5],
            settings: .init(payload: [
                "autoMarkMemorized": false,
                "memorizeWordVisibility": "hidden",
            ])
        )

        let emission = try XCTUnwrap(
            BibleReaderPreparedMemorizeDocument.encode(
                capture: capture,
                owner: owner,
                stateJSON: #"{"memorize":{"mode":"scramble"}}"#
            )
        )
        let data = try XCTUnwrap(emission.documentJSON.data(using: .utf8))
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(document["type"] as? String, "memorize")
        XCTAssertEqual(document["memorizedOrdinals"] as? [Int], [40])
        XCTAssertEqual(document["targetOrdinals"] as? [Int], [41])
        XCTAssertEqual(
            (document["state"] as? [String: Any])?["memorize"] as? [String: String],
            ["mode": "scramble"]
        )
        XCTAssertEqual(
            (document["readingProgressSettings"] as? [String: Any])?["autoMarkMemorized"]
                as? Bool,
            false
        )
        XCTAssertEqual(emission.source.references.map(\.ordinal), [4, 5])
    }

    /** Keeps delimiter-like fields structurally distinct under Java UTF-16 identity. */
    func testRequestIdentityDoesNotFlattenDelimiterLikeFields() {
        let first = BibleReaderMemorizePreparationRequest(
            bookInitials: "KJV",
            startOrdinal: 4,
            endOrdinal: 4,
            currentBook: "Genesis|7",
            currentChapter: 8,
            osisBookID: "Gen",
            stateJSON: "state",
            directKJVAReferences: nil
        )
        let second = BibleReaderMemorizePreparationRequest(
            bookInitials: "KJV",
            startOrdinal: 4,
            endOrdinal: 4,
            currentBook: "Genesis",
            currentChapter: 7,
            osisBookID: "8|Gen",
            stateJSON: "state",
            directKJVAReferences: nil
        )
        let firstFlattened = "KJV|4|4|Genesis|7|8|Gen|state|"
        let secondFlattened = "KJV|4|4|Genesis|7|8|Gen|state|"

        XCTAssertEqual(firstFlattened, secondFlattened)
        XCTAssertNotEqual(first.identity, second.identity)
    }

    /** Treats canonically equivalent but Java-distinct source initials as different requests. */
    func testRequestIdentityUsesExactUTF16SourceIdentity() {
        let composed = BibleReaderMemorizePreparationRequest(
            bookInitials: "Caf\u{00E9}",
            startOrdinal: 4,
            endOrdinal: 4,
            currentBook: "Genesis",
            currentChapter: 1,
            osisBookID: "Gen",
            stateJSON: nil,
            directKJVAReferences: nil
        )
        let decomposed = BibleReaderMemorizePreparationRequest(
            bookInitials: "Cafe\u{0301}",
            startOrdinal: 4,
            endOrdinal: 4,
            currentBook: "Genesis",
            currentChapter: 1,
            osisBookID: "Gen",
            stateJSON: nil,
            directKJVAReferences: nil
        )

        XCTAssertNotEqual(composed.identity, decomposed.identity)
    }

    /** Preserves chapter-introduction rows and rejects an ordinal with mismatched coordinates. */
    func testCapturePreservesExactIntroInclusiveKJVARange() throws {
        let manager = try XCTUnwrap(
            SwordManager(modulePath: makeTemporarySwordFixturePath())
        )
        let request = BibleReaderMemorizePreparationRequest(
            bookInitials: "KJV",
            startOrdinal: 1_609,
            endOrdinal: 1_611,
            currentBook: "Exodus",
            currentChapter: 1,
            osisBookID: "Exod",
            stateJSON: nil,
            directKJVAReferences: [
                .init(osisBookId: "Exod", chapter: 1, verse: 22, ordinal: 1_609),
                .init(osisBookId: "Exod", chapter: 2, verse: 0, ordinal: 1_610),
                .init(osisBookId: "Exod", chapter: 2, verse: 1, ordinal: 1_611),
            ]
        )

        let capture = try XCTUnwrap(
            BibleReaderPreparedMemorizeDocument.capture(
                request: request,
                manager: manager,
                managerGeneration: manager.contentAuthorizationGeneration,
                optionSettings: []
            )
        )
        XCTAssertEqual(
            capture.references.map(\.osisRef),
            ["Exod.1.22", "Exod.2.0", "Exod.2.1"]
        )
        XCTAssertEqual(
            capture.textItems.map(\.key.rawValue),
            ["Exod.1.22", "Exod.2.0", "Exod.2.1"]
        )
        let introduction = try XCTUnwrap(
            capture.textItems.first { $0.key == BibleReaderPreparationExactText("Exod.2.0") }
        )
        XCTAssertEqual(introduction.text.rawValue, "")

        let mismatched = BibleReaderMemorizePreparationRequest(
            bookInitials: request.bookInitials,
            startOrdinal: request.startOrdinal,
            endOrdinal: request.endOrdinal,
            currentBook: request.currentBook,
            currentChapter: request.currentChapter,
            osisBookID: request.osisBookID,
            stateJSON: request.stateJSON,
            directKJVAReferences: [
                .init(osisBookId: "Exod", chapter: 2, verse: 1, ordinal: 1_610),
            ]
        )
        XCTAssertNil(
            BibleReaderPreparedMemorizeDocument.capture(
                request: mismatched,
                manager: manager,
                managerGeneration: manager.contentAuthorizationGeneration,
                optionSettings: []
            )
        )
    }
}
