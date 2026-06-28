import XCTest
@testable import BibleUI

/**
 Package-lane coverage for settings-search matching owned by BibleUI.

 The matcher is pure presentation logic that decides which Android-parity settings rows are visible
 for a search query, so it belongs in the BibleUI package lane instead of the app-host bundle.
 */
final class SettingsSearchMatcherTests: XCTestCase {
    /**
     Verifies every normalized query term must match an entry's rendered searchable text.

     Failure means the settings search field may show rows that only partially match multi-word
     queries, or fail case-insensitive matching of Android-derived row metadata.
     */
    func testSettingsSearchMatcherRequiresAllNormalizedTermsAcrossEntryText() {
        let entry = AndBibleSettingsSearchEntry(
            identifier: "settingsReadingProgressLink",
            title: "Reading Progress Settings",
            summary: "Configure automatic reading tracking",
            detail: "Memorization",
            keywords: ["features", "progress"]
        )

        XCTAssertTrue(AndBibleSettingsSearchMatcher.matches(query: "", entry: entry))
        XCTAssertTrue(AndBibleSettingsSearchMatcher.matches(query: "reading tracking", entry: entry))
        XCTAssertTrue(AndBibleSettingsSearchMatcher.matches(query: "FEATURES progress", entry: entry))
        XCTAssertFalse(AndBibleSettingsSearchMatcher.matches(query: "sync tracking", entry: entry))
    }

    /**
     Verifies section-level search only exposes matching rows while empty search preserves routing.

     The settings UI may navigate to a specific row by identifier. A non-empty query must require
     that row to match exactly, while an empty query should not block existing row routing.
     */
    func testSettingsSearchMatcherFiltersExactRenderedRowsWithinMatchingSection() {
        let entries = [
            AndBibleSettingsSearchEntry(
                identifier: "monochrome_mode",
                title: "Black & white mode",
                summary: "Use application in monochrome mode"
            ),
            AndBibleSettingsSearchEntry(
                identifier: "disable_animations",
                title: "Disable animations",
                summary: "Disable smooth scrolling animations"
            ),
        ]

        XCTAssertTrue(entries.contains { AndBibleSettingsSearchMatcher.matches(query: "monochrome", entry: $0) })
        XCTAssertTrue(
            AndBibleSettingsSearchMatcher.matchesIdentifier(
                "monochrome_mode",
                query: "monochrome",
                entries: entries
            )
        )
        XCTAssertFalse(
            AndBibleSettingsSearchMatcher.matchesIdentifier(
                "disable_animations",
                query: "monochrome",
                entries: entries
            )
        )
        XCTAssertFalse(
            AndBibleSettingsSearchMatcher.matchesIdentifier(
                "missing_row",
                query: "monochrome",
                entries: entries
            )
        )
        XCTAssertTrue(
            AndBibleSettingsSearchMatcher.matchesIdentifier(
                "missing_row",
                query: "",
                entries: entries
            )
        )
    }
}
