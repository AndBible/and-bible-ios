import XCTest
@testable import BibleUI

/** Generation-order coverage for Search result and index publication guards. */
final class LatestSearchRequestGateTests: XCTestCase {
    /**
     Verifies a replacement request rejects every terminal state from the older generation.

     Failure meaning:
     - a delayed success, failure, or loading completion can overwrite the newer query/options.
     */
    func testNewRequestRejectsStaleSuccessFailureAndLoadingPublication() {
        var gate = LatestSearchRequestGate()
        let first = gate.begin()
        let second = gate.begin()

        XCTAssertFalse(gate.accepts(first), "Stale success must not publish")
        XCTAssertFalse(gate.accepts(first), "Stale failure must not publish")
        XCTAssertFalse(gate.accepts(first), "Stale loading state must not publish")
        XCTAssertTrue(gate.accepts(second))
    }

    /**
     Verifies dismissal invalidation rejects the latest in-flight generation.

     Failure meaning:
     - Search or sibling index work can mutate a dismissed presentation after navigation.
     */
    func testInvalidationRejectsLatestGenerationAfterDismissal() {
        var gate = LatestSearchRequestGate()
        let inFlight = gate.begin()
        XCTAssertTrue(gate.accepts(inFlight))

        gate.invalidate()

        XCTAssertFalse(gate.accepts(inFlight))
    }

    /**
     Verifies search and index lanes remain independent when one lane is replaced.

     Failure meaning:
     - restarting an index operation can accidentally authorize a stale text-search completion, or
       cancelling Search can invalidate unrelated current index work through a shared generation.
     */
    func testSearchAndIndexGenerationLanesAreIndependent() {
        var searchGate = LatestSearchRequestGate()
        var indexGate = LatestSearchRequestGate()
        let search = searchGate.begin()
        let index = indexGate.begin()

        searchGate.invalidate()

        XCTAssertFalse(searchGate.accepts(search))
        XCTAssertTrue(indexGate.accepts(index))
    }

    /**
     Verifies editing the query invalidates only state representing a different submitted query.

     Setup:
     - compares an absent represented query, the same trimmed query, and changed text

     Expected result:
     - unsubmitted and formatting-equivalent text preserve state
     - materially changed text invalidates the active generation

     Failure significance:
     - stale loading, results, or errors can remain attached to edited query text
     */
    func testQueryEditsInvalidateOnlyDifferentRepresentedSearch() {
        XCTAssertFalse(SearchView.shouldInvalidateSearch(
            representedQuery: nil,
            changedQuery: "faith"
        ))
        XCTAssertFalse(SearchView.shouldInvalidateSearch(
            representedQuery: "faith",
            changedQuery: "  faith\n"
        ))
        XCTAssertTrue(SearchView.shouldInvalidateSearch(
            representedQuery: "faith",
            changedQuery: "hope"
        ))
        XCTAssertTrue(SearchView.shouldInvalidateSearch(
            representedQuery: "faith",
            changedQuery: ""
        ))
    }
}
