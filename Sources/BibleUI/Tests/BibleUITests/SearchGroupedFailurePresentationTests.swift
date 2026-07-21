import XCTest
@testable import BibleCore
@testable import BibleUI

/**
 Pins the Search screen's presentation contract for successful and failed selected modules.

 The suite uses immutable Core result values and calls the production SearchView state serializer. It
 does not mount SwiftUI or mutate app state; visible row construction consumes the same retained
 `moduleFailures` array directly.
 */
final class SearchGroupedFailurePresentationTests: XCTestCase {
    /**
     Verifies the production Search state export retains both a healthy count and failed module name.

     - Setup: Creates the same mixed-success `SearchGroupedResults` value returned by the index service.
     - Expected result: Search's UI automation value reports the successful translation separately from
       the failed translation, matching the visible result pill and failure row.
     - Failure meaning: SearchView can receive partial results while hiding their module failure state.
     - Side effects: None.
     */
    func testSearchAccessibilityStateExposesPartialModuleFailure() {
        let identity = SearchVerseIdentity(
            osisBookId: "Gen",
            canonicalBookOrder: SearchCanonicalBookCatalog.order(of: "Gen"),
            chapter: 1,
            verse: 1
        )
        let hit = SearchModuleHit(
            moduleName: "HEALTHY",
            key: "Genesis 1:1",
            displayBook: "Genesis",
            snippet: "shared text",
            identity: identity
        )
        let grouped = SearchGroupedResults(
            moduleResults: [SearchModuleResults(moduleName: "HEALTHY", hits: [hit])],
            moduleOrder: ["HEALTHY", "STALE"],
            moduleFailures: [SearchModuleFailure(moduleName: "STALE", message: "Index unavailable")]
        )

        XCTAssertEqual(
            SearchView.searchAccessibilityGroupToken(for: grouped),
            "groupedTotal=1;groupedHitTotal=1;groupedCounts=HEALTHY:1;groupedFailures=STALE"
        )
        XCTAssertEqual(grouped.moduleFailures.first?.message, "Index unavailable")
    }
}
