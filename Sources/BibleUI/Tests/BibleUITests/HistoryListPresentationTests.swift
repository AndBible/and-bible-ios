import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 App-host-free coverage for the History screen list contracts.

 These tests replace expensive XCUITest reopen checks by asserting the package-level rules that
 drive the visible History list: active-window filtering, Android reference formatting, stable
 automation identifiers, and bounded accessibility exports.
 */
final class HistoryListPresentationTests: XCTestCase {
    /**
     Verifies History rows are scoped to the active reader window when one is known.

     Setup:
     - three persisted rows: one in the active window, one in another window, and one unscoped

     Expected result:
     - an active window shows only rows owned by that window
     - a nil active window falls back to every loaded row, matching the existing reader behavior

     Failure meaning:
     - History could delete, export, or render rows from the wrong reader pane.
     */
    func testVisibleItemsFollowActiveWindowScope() {
        let activeWindow = Window(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)
        let otherWindow = Window(id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!)
        let activeRow = makeHistoryItem(idSuffix: 1, key: "Exod.2.1", window: activeWindow)
        let otherRow = makeHistoryItem(idSuffix: 2, key: "Matt.3.1", window: otherWindow)
        let unscopedRow = makeHistoryItem(idSuffix: 3, key: "Mark.4.1", window: nil)

        XCTAssertEqual(
            HistoryListPresentation.visibleItems(
                [activeRow, otherRow, unscopedRow],
                activeWindowID: activeWindow.id
            ).map(\.key),
            ["Exod.2.1"]
        )
        XCTAssertEqual(
            HistoryListPresentation.visibleItems(
                [activeRow, otherRow, unscopedRow],
                activeWindowID: nil
            ).map(\.key),
            ["Exod.2.1", "Matt.3.1", "Mark.4.1"]
        )
    }

    /**
     Verifies row identifiers keep the same deterministic key contract used by XCUITest helpers.

     Expected result:
     - punctuation in OSIS keys becomes underscores
     - row identifiers reuse the sanitized suffix

     Failure meaning:
     - retained UI smoke tests could lose their stable selectors or match rows ambiguously.
     */
    func testHistoryIdentifiersUseStableSanitizedKeys() {
        let item = makeHistoryItem(idSuffix: 4, key: "Exod.2.1", window: nil)

        XCTAssertEqual(HistoryListPresentation.sanitizedKey("Matt.3.1"), "Matt_3_1")
        XCTAssertEqual(HistoryListPresentation.rowStateToken(for: item), "|Exod_2_1|")
        XCTAssertEqual(HistoryListPresentation.rowIdentifier(for: item), "historyRow::Exod_2_1")
    }

    /**
     Verifies detailed History accessibility exports are count-based and bounded.

     Setup:
     - three visible rows with a row-token export limit of two

     Expected result:
     - normal exports include only the count
     - detailed exports append only the first two delimited row tokens

     Failure meaning:
     - UI tests could become brittle from unbounded state dumps or lose the row evidence needed to
       replace full reopen flows.
     */
    func testAccessibilityValueExportsCountAndBoundedRowTokens() {
        let rows = [
            makeHistoryItem(idSuffix: 5, key: "Exod.2.1", window: nil),
            makeHistoryItem(idSuffix: 6, key: "Matt.3.1", window: nil),
            makeHistoryItem(idSuffix: 7, key: "Mark.4.1", window: nil),
        ]

        XCTAssertEqual(
            HistoryListPresentation.accessibilityValue(for: rows, includeRowTokens: false, rowTokenLimit: 2),
            "count=3"
        )
        XCTAssertEqual(
            HistoryListPresentation.accessibilityValue(for: rows, includeRowTokens: true, rowTokenLimit: 2),
            "count=3;rows=|Exod_2_1|,|Matt_3_1|"
        )
    }

    /**
     Verifies History row titles match Android's chapter-and-verse key description.

     Expected result:
     - module-aware resolvers win when supplied and verse numbers remain visible
     - verse zero is omitted like Android's `CommonUtils.getKeyDescription`
     - module-prefixed keys retain the underlying reference
     - malformed keys are returned unchanged

     Failure meaning:
     - extracting presentation logic changed visible History row titles.
     */
    func testFormattedKeyUsesResolverAndKeepsMalformedKeys() {
        XCTAssertEqual(
            HistoryListPresentation.formattedKey("Exod.2.1", bookNameResolver: { osisID in
                osisID == "Exod" ? "Exodus" : nil
            }),
            "Exodus 2:1"
        )
        XCTAssertEqual(
            HistoryListPresentation.formattedKey("Exod.2.0", bookNameResolver: { _ in "Exodus" }),
            "Exodus 2"
        )
        XCTAssertEqual(
            HistoryListPresentation.formattedKey("KJV:Exod.2.3", bookNameResolver: { _ in "Exodus" }),
            "Exodus 2:3"
        )
        XCTAssertEqual(
            HistoryListPresentation.formattedKey("not-a-reference", bookNameResolver: nil),
            "not-a-reference"
        )
    }

    /**
     Verifies History row titles retain Android's module abbreviation after the reference.

     Expected result:
     - nonempty module initials are appended after the localized reference
     - blank legacy module values do not introduce stray whitespace

     Failure meaning:
     - dialog rows would omit information rendered by Android's `KeyHistoryItem.description`.
     */
    func testFormattedDescriptionIncludesAndroidDocumentAbbreviation() {
        XCTAssertEqual(
            HistoryListPresentation.formattedDescription(
                key: "Exod.2.1",
                document: "KJV",
                bookNameResolver: { $0 == "Exod" ? "Exodus" : nil }
            ),
            "Exodus 2:1 KJV"
        )
        XCTAssertEqual(
            HistoryListPresentation.formattedDescription(
                key: "not-a-reference",
                document: " ",
                bookNameResolver: nil
            ),
            "not-a-reference"
        )
    }

    /**
     Builds a History row with deterministic ID and timestamp for package-level tests.

     - Parameters:
       - idSuffix: Final UUID digit used to keep fixtures distinct.
       - key: Persisted OSIS-style history key.
       - window: Optional owning reader window.
     - Returns: An unsaved `HistoryItem` configured with the supplied key and owner.
     - Side effects: assigns the item's `window` relationship.
     - Failure modes: This helper cannot fail for suffixes used by the tests.
     */
    private func makeHistoryItem(idSuffix: Int, key: String, window: Window?) -> HistoryItem {
        let item = HistoryItem(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!,
            createdAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
            document: "KJV",
            key: key
        )
        item.window = window
        return item
    }
}
