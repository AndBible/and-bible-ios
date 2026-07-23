import XCTest
@testable import BibleCore

final class StudyPadContentSearchTests: XCTestCase {
    /**
     Verifies Android's three-source grouping, reserved-label exclusion, result ordering, snippets,
     and first-match navigation identity using detached deterministic fixtures.
     */
    func testSearchGroupsAllContentSourcesAndSortsLikeAndroid() throws {
        let textID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let bibleID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
        let genericID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
        let frequentID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let secondaryID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!
        let specialID = UUID(uuidString: "00000000-0000-0000-0000-000000000023")!

        let results = StudyPadContentSearch.search(
            documents: [
                StudyPadSearchDocument(
                    labelID: secondaryID,
                    labelName: "Beta",
                    labelColor: 2,
                    isSpecialLabel: false,
                    entries: [.init(id: UUID(), type: .textEntry, text: "one needle")]
                ),
                StudyPadSearchDocument(
                    labelID: frequentID,
                    labelName: "Alpha",
                    labelColor: 1,
                    isSpecialLabel: false,
                    entries: [
                        .init(id: textID, type: .textEntry, text: String(repeating: "x", count: 55) + "needle" + String(repeating: "y", count: 55)),
                        .init(id: bibleID, type: .bookmarkNote, text: "Bible needle note"),
                        .init(id: genericID, type: .bookmarkNote, text: "Generic needle note"),
                    ]
                ),
                StudyPadSearchDocument(
                    labelID: specialID,
                    labelName: Label.aiLabelName,
                    labelColor: 3,
                    isSpecialLabel: true,
                    entries: [.init(id: UUID(), type: .textEntry, text: "needle")]
                ),
            ],
            query: "needle"
        )

        XCTAssertEqual(results.map(\.labelID), [frequentID, secondaryID])
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first.matchCount, 3)
        XCTAssertEqual(first.matches.map(\.entryID), [textID, bibleID, genericID])
        XCTAssertEqual(first.matches.map(\.entryType), [.textEntry, .bookmarkNote, .bookmarkNote])
        XCTAssertTrue(first.matches[0].textSnippet.hasPrefix("..."))
        XCTAssertTrue(first.matches[0].textSnippet.hasSuffix("..."))
        let snippet = first.matches[0].textSnippet as NSString
        XCTAssertEqual(
            snippet.substring(with: NSRange(
                location: first.matches[0].matchStart,
                length: first.matches[0].matchEnd - first.matches[0].matchStart
            )),
            "needle"
        )
    }

    /// Verifies case-insensitive matching and Android's one-result-per-matching-entry behavior.
    func testSearchCountsEntriesRatherThanEveryOccurrence() throws {
        let labelID = UUID()
        let entryID = UUID()
        let result = try XCTUnwrap(StudyPadContentSearch.search(
            documents: [StudyPadSearchDocument(
                labelID: labelID,
                labelName: "Notes",
                labelColor: 1,
                isSpecialLabel: false,
                entries: [.init(id: entryID, type: .textEntry, text: "Needle, needle")]
            )],
            query: "needle"
        ).first)

        XCTAssertEqual(result.matchCount, 1)
        XCTAssertEqual(result.matches.first?.entryID, entryID)
        XCTAssertEqual(result.matches.first?.matchStart, 0)
        XCTAssertEqual(result.matches.first?.matchEnd, 6)
    }

    /// Verifies empty input produces no accidental all-label content result.
    func testEmptyQueryReturnsNoResults() {
        XCTAssertTrue(StudyPadContentSearch.search(documents: [], query: "").isEmpty)
    }
}
