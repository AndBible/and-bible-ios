import XCTest
import SwiftData
@testable import BibleCore
@testable import BibleUI

/**
 App-host-free coverage for the History screen list contracts.

 These tests replace expensive XCUITest reopen checks by asserting the package-level rules that
 drive the visible History list: active-window filtering, stable automation identifiers, bounded
 accessibility exports, and SwiftData persistence after Clear or row-delete actions.
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
     - row and delete-button identifiers share the same sanitized suffix

     Failure meaning:
     - retained UI smoke tests could lose their stable selectors or match rows ambiguously.
     */
    func testHistoryIdentifiersUseStableSanitizedKeys() {
        let item = makeHistoryItem(idSuffix: 4, key: "Exod.2.1", window: nil)

        XCTAssertEqual(HistoryListPresentation.sanitizedKey("Matt.3.1"), "Matt_3_1")
        XCTAssertEqual(HistoryListPresentation.rowStateToken(for: item), "|Exod_2_1|")
        XCTAssertEqual(HistoryListPresentation.rowIdentifier(for: item), "historyRow::Exod_2_1")
        XCTAssertEqual(HistoryListPresentation.deleteButtonIdentifier(for: item), "historyDeleteButton::Exod_2_1")
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
     Verifies Clear deletes and saves only rows visible in the active History scope.

     Setup:
     - an in-memory SwiftData workspace with two active-window rows and two other-window rows

     Expected result:
     - Clear removes the two active-window rows and leaves both other-window rows persisted

     Failure meaning:
     - clearing History could erase another pane's navigation state, or the mutation could fail to
       persist after reopening the screen.
     */
    func testClearVisibleItemsPersistsOnlyActiveWindowRows() throws {
        let fixture = try makeSeededHistoryFixture()

        let deletedCount = try HistoryListPresentation.clearVisibleItems(
            from: fixture.rows,
            activeWindowID: fixture.activeWindow.id,
            in: fixture.modelContext
        )

        XCTAssertEqual(deletedCount, 2)
        XCTAssertEqual(try persistedHistoryKeys(in: fixture.modelContext), ["Exod.2.1", "Mark.4.1"])
    }

    /**
     Verifies row deletion removes matching keys only inside the active History scope.

     Setup:
     - duplicate `Exod.2.1` rows in separate reader windows plus a distinct active-window row

     Expected result:
     - deleting `Exod.2.1` from the active window removes one row and preserves the same key in the
       other window

     Failure meaning:
     - row deletion could collapse duplicate history keys across panes or fail to persist.
     */
    func testDeleteVisibleItemsMatchesKeyInsideActiveWindowOnly() throws {
        let fixture = try makeSeededHistoryFixture()

        let deletedCount = try HistoryListPresentation.deleteVisibleItems(
            matchingKey: "Exod.2.1",
            from: fixture.rows,
            activeWindowID: fixture.activeWindow.id,
            in: fixture.modelContext
        )

        XCTAssertEqual(deletedCount, 1)
        let remaining = try fixture.modelContext.fetch(FetchDescriptor<HistoryItem>())
        XCTAssertEqual(Set(remaining.map(\.key)), ["Exod.2.1", "Matt.3.1", "Mark.4.1"])
        XCTAssertEqual(remaining.filter { $0.key == "Exod.2.1" }.map { $0.window?.id }, [fixture.otherWindow.id])
    }

    /**
     Verifies History row titles keep the existing OSIS display fallback behavior.

     Expected result:
     - module-aware resolvers win when supplied
     - malformed keys are returned unchanged

     Failure meaning:
     - extracting presentation logic changed visible History row titles.
     */
    func testFormattedKeyUsesResolverAndKeepsMalformedKeys() {
        XCTAssertEqual(
            HistoryListPresentation.formattedKey("Exod.2.1", bookNameResolver: { osisID in
                osisID == "Exod" ? "Exodus" : nil
            }),
            "Exodus 2"
        )
        XCTAssertEqual(
            HistoryListPresentation.formattedKey("not-a-reference", bookNameResolver: nil),
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

    /**
     Creates an in-memory SwiftData history graph for destructive action tests.

     - Returns: A fixture containing the model context, two windows, and loaded history rows.
     - Side effects: Inserts windows and history rows into a transient SwiftData container.
     - Failure modes: Rethrows SwiftData container or save failures.
     */
    private func makeSeededHistoryFixture() throws -> HistoryFixture {
        let container = try makeWorkspaceModelContainer()
        let modelContext = ModelContext(container)
        let activeWindow = Window(id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!)
        let otherWindow = Window(id: UUID(uuidString: "00000000-0000-0000-0000-000000000222")!)
        let rows = [
            makeHistoryItem(idSuffix: 11, key: "Exod.2.1", window: activeWindow),
            makeHistoryItem(idSuffix: 12, key: "Matt.3.1", window: activeWindow),
            makeHistoryItem(idSuffix: 13, key: "Exod.2.1", window: otherWindow),
            makeHistoryItem(idSuffix: 14, key: "Mark.4.1", window: otherWindow),
        ]

        modelContext.insert(activeWindow)
        modelContext.insert(otherWindow)
        for row in rows {
            modelContext.insert(row)
        }
        try modelContext.save()

        return HistoryFixture(
            modelContext: modelContext,
            activeWindow: activeWindow,
            otherWindow: otherWindow,
            rows: rows
        )
    }

    /**
     Fetches persisted history keys in deterministic order.

     - Parameter modelContext: SwiftData context containing `HistoryItem` rows.
     - Returns: Sorted persisted keys.
     - Side effects: Reads the in-memory SwiftData context.
     - Failure modes: Rethrows SwiftData fetch failures.
     */
    private func persistedHistoryKeys(in modelContext: ModelContext) throws -> [String] {
        try modelContext.fetch(FetchDescriptor<HistoryItem>()).map(\.key).sorted()
    }

    /**
     Test-only container for a seeded History graph.

     The fixture records both windows so destructive tests can distinguish duplicate keys that
     belong to different reader panes.
     */
    private struct HistoryFixture {
        /// SwiftData context that owns every row in `rows`.
        let modelContext: ModelContext

        /// Window that should be treated as active by the tested helper.
        let activeWindow: Window

        /// Secondary window used to prove History mutations are pane-scoped.
        let otherWindow: Window

        /// Loaded history rows passed to `HistoryListPresentation`.
        let rows: [HistoryItem]
    }
}
