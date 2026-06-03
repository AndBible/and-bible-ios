import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    /**
     Verifies that Settings opens as a reader navigation destination and exposes Android-parity
     application-preference shortcuts.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled, in-memory persistence, and one
     *     deterministic seeded bookmark-label pair for stable reader-shell startup
     *   - pushes Settings from the reader action surface and samples the exported reader/settings
     *     accessibility state
     * - Failure modes:
     *   - fails if settings cannot be reached from the reader shell
     *   - fails if Settings is still presented as a reader sheet rather than a navigation
     *     destination
     *   - fails if the feature shortcuts or reader-admin-flow contract are absent
     */
    func testSettingsScreenShowsApplicationPreferenceShortcuts() {
        let app = makeApp()
        app.launch()

        openSettings(in: app)
        XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)
        waitForReaderRenderedContentState(containing: "readerSheet=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=settings", in: app, timeout: 10)
        waitForSettingsState(containing: "settingsSyncLink", in: app, timeout: 10)
        waitForSettingsState(containing: "settingsReadingProgressLink", in: app, timeout: 10)
        waitForSettingsState(containing: "adminFlows=readerActions", in: app, timeout: 10)
    }

    /**
     Verifies that the reader overflow All Text Options action opens window text-display settings
     instead of the left-drawer Application Preferences destination.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic in-memory data
     *   - opens the real overflow menu action identified by Android's All Text Options row
     *   - pushes the native Text Display settings destination
     * - Failure modes:
     *   - fails if the overflow action is routed to global Application Preferences
     *   - fails if the Text Display settings screen never becomes ready
     */
    func testAllTextOptionsOpensReaderTextDisplaySurface() {
        let app = makeApp()
        app.launch()

        openReaderActionDestination(
            actionIdentifier: "readerOpenTextOptionsAction",
            destinationIdentifier: "textDisplaySettingsScreen",
            readinessIdentifiers: [
                "textDisplayFontFamilyButton",
                "textDisplayJustifyTextToggleButton",
            ],
            in: app,
            timeout: 20
        )

        XCTAssertTrue(requireElement("textDisplaySettingsScreen", in: app, timeout: 10).exists)
        waitForReaderRenderedContentState(containing: "readerSheet=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=textOptions", in: app, timeout: 10)
        XCTAssertFalse(
            unresolvedElement("settingsForm", in: app).exists,
            "Expected All Text Options to open the Text Display destination, not Application Preferences."
        )
    }

    /**
     Verifies that Search preserves a seeded initial query typed through the real UI.
     *
     * - Side effects:
     *   - launches the app on the reader shell with the initial query `earth` queued for Search
     *   - opens Search from the toolbar and waits for the search sheet to settle
     * - Failure modes:
     *   - fails if the Search sheet never appears
     *   - fails if the seeded query is dropped before the Search screen reaches its settled state
     */
    func testSearchDirectLaunchRetainsSeededQuery() {
        let app = makeApp(searchQuery: "earth")
        app.launch()

        _ = openSearch(in: app)
        waitForSearchQuery("earth", in: app, timeout: 20)
        waitForSearchResultRow("searchResultRow::Genesis_1_2", in: app, shouldExist: true, timeout: 20)
    }

    /**
     Verifies that Search can query the seeded bundled index and return bundled results.
     *
     * - Side effects:
     *   - launches the app on the reader shell with the initial query `earth` queued for Search
     *   - opens Search from the toolbar and waits for the seeded bundled index to become ready
     * - Failure modes:
     *   - fails if the Search screen never reaches the ready state
     *   - fails if the seeded bundled result set still returns zero hits
     */
    func testSearchDirectLaunchUsesSeededIndexAndReturnsBundledResults() {
        let app = makeApp(searchQuery: "earth")
        app.launch()

        _ = openSearch(in: app)
        waitForSearchState(containing: "query=earth", in: app, timeout: 20)
        waitForSearchResultRow("searchResultRow::Genesis_1_2", in: app, shouldExist: true, timeout: 20)
    }

    /**
     Verifies that selecting a second Search translation reruns the query and reports grouped totals.
     *
     * - Side effects:
     *   - launches Search with deterministic KJV and UITESTWEB index rows for `earth`
     *   - opens the real translation picker and selects UITESTWEB
     *   - waits for the active query to rerun and export grouped per-translation counts
     * - Failure modes:
     *   - fails if the translation picker is not reachable from Search options
     *   - fails if selecting a second translation does not rerun the active query
     *   - fails if grouped totals collapse to single-translation results
     */
    func testSearchMultiTranslationSelectionUpdatesGroupedTotals() {
        let app = makeApp(searchQuery: "earth")
        app.launch()

        let initialReference = requireReaderReferenceValue(in: app, timeout: 15)

        _ = openSearch(in: app)
        waitForSearchState(containing: "query=earth", in: app, timeout: 20)
        waitForSearchSelectedModules(
            in: app,
            timeout: 20,
            description: "exactly KJV"
        ) { modules in
            modules == Set(["KJV"])
        }
        waitForSearchResultRow("searchResultRow::Genesis_1_2", in: app, shouldExist: true, timeout: 20)

        tapSearchTranslationPicker(in: app, timeout: 10)
        tapSearchTranslationRow(moduleName: "UITESTWEB", in: app, timeout: 10)
        tapSearchTranslationDone(in: app, timeout: 10)

        waitForSearchSelectedModules(
            in: app,
            timeout: 20,
            description: "more than one module including UITESTWEB"
        ) { modules in
            modules.count > 1 && modules.contains("UITESTWEB")
        }
        waitForSearchState(containing: "groupedTotal=3", in: app, timeout: 20)
        waitForSearchState(containing: "KJV:1", in: app, timeout: 20)
        waitForSearchState(containing: "UITESTWEB:2", in: app, timeout: 20)
        waitForSearchResultCount(atLeast: 3, in: app, timeout: 20)

        let groupedResult = requireElement("searchResultRow::John_3_16", in: app, timeout: 20)
        tapElementReliably(groupedResult, timeout: 10)

        let updatedReference = waitForReaderReferenceValueToChange(
            from: initialReference,
            in: app,
            timeout: 20
        )
        XCTAssertNotEqual(
            updatedReference,
            initialReference,
            "Expected selecting a grouped Search result to move the reader away from '\(initialReference)'."
        )
    }

    /**
     Verifies that changing Search scope reruns the current query and updates the result set.
     *
     * - Side effects:
     *   - launches the app directly into Search with the initial query `jesus`
     *   - switches Search scope from whole Bible to the Old Testament and then to the New
     *     Testament
     *   - waits for Search to rerun after each scope change and inspects the exported Search
     *     state
     * - Failure modes:
     *   - fails if the visible `OT` or `NT` Search scope buttons are not accessible
     *   - fails if the Old Testament scope does not reduce the `jesus` query to zero hits
     *   - fails if the New Testament scope does not restore non-zero bundled hits
     */
    func testSearchScopeChangeRerunsQueryAndUpdatesResults() {
        let app = makeApp(searchQuery: "jesus")
        app.launch()

        _ = openSearch(in: app)
        waitForSearchResultRow("searchResultRow::Matthew_1_1", in: app, shouldExist: true, timeout: 20)

        tapSearchScope(.oldTestament, in: app)
        waitForSearchState(containing: "scope=oldTestament", in: app, timeout: 20)
        waitForSearchResultRow(
            "searchResultRow::Matthew_1_1",
            in: app,
            shouldExist: false,
            timeout: 20
        )

        tapSearchScope(.newTestament, in: app)
        waitForSearchState(containing: "scope=newTestament", in: app, timeout: 20)
        waitForSearchResultRow("searchResultRow::Matthew_1_1", in: app, shouldExist: true, timeout: 20)
    }

    /**
     Verifies that changing Search word mode reruns the current query and updates the result set.
     *
     * - Side effects:
     *   - launches the app directly into Search with the initial query `earth void`
     *   - switches Search word mode from all words to phrase and then to any word
     *   - waits for Search to rerun after each mode change and inspects the exported Search state
     * - Failure modes:
     *   - fails if the visible `Phrase` or `Any Word` Search mode buttons are not accessible
     *   - fails if phrase mode does not reduce the `earth void` query to zero hits
     *   - fails if any-word mode does not restore non-zero bundled hits
     */
    func testSearchWordModeChangeRerunsQueryAndUpdatesResults() {
        let app = makeApp(searchQuery: "earth void")
        app.launch()

        _ = openSearch(in: app)
        waitForSearchResultRow("searchResultRow::Genesis_1_2", in: app, shouldExist: true, timeout: 20)

        tapSearchWordMode("Phrase", in: app, timeout: 10)
        waitForSearchState(containing: "wordMode=phrase", in: app, timeout: 20)
        waitForSearchResultRow(
            "searchResultRow::Genesis_1_2",
            in: app,
            shouldExist: false,
            timeout: 20
        )

        tapSearchWordMode("Any Word", in: app, timeout: 10)
        waitForSearchState(containing: "wordMode=anyWord", in: app, timeout: 20)
        waitForSearchResultRow("searchResultRow::Genesis_1_2", in: app, shouldExist: true, timeout: 20)
    }

    /**
     Verifies that the real reader Search workflow can navigate to a bundled search hit.
     *
     * - Side effects:
     *   - launches the standard reader shell with one deterministic seeded query for the Search UI
     *   - opens Search from the real reader toolbar, waits for the bundled index/search pass, and
     *     taps the first returned result row
     *   - dismisses Search through the normal result-selection flow and navigates the reader to
     *     the selected passage
     * - Failure modes:
     *   - fails if Search cannot be opened from the reader toolbar
     *   - fails if bundled search results do not produce at least one tappable result row
     *   - fails if selecting the result does not move the reader away from `Genesis 1`
     */
    func testSearchResultSelectionNavigatesReaderToBundledReference() {
        let app = makeApp(searchQuery: "noah")
        app.launch()

        let initialReference = requireReaderReferenceValue(in: app, timeout: 15)

        _ = openSearch(in: app)
        waitForSearchQuery("noah", in: app, timeout: 20)

        let noahResultIdentifier = "searchResultRow::Genesis_6_8"
        waitForSearchResultRow(noahResultIdentifier, in: app, shouldExist: true, timeout: 20)
        let noahResult = requireElement(noahResultIdentifier, in: app, timeout: 20)
        tapElementReliably(noahResult, timeout: 10)

        let updatedReference = waitForReaderReferenceValueToChange(
            from: initialReference,
            in: app,
            timeout: 20
        )
        XCTAssertNotEqual(
            updatedReference,
            initialReference,
            "Expected selecting a Search result to move the reader away from '\(initialReference)'."
        )
    }

    /**
     Verifies that a bundled Strong's query reaches the direct lemma-search path and returns hits.
     *
     * - Side effects:
     *   - launches the app directly into Search with one deterministic Strong's query
     *   - waits for Search to bypass any FTS index prompt and settle with non-zero results
     * - Failure modes:
     *   - fails if Search never reaches the ready state for the Strong's query
     *   - fails if the bundled Strong's-capable Bible still reports zero matches
     */
    func testSearchDirectLaunchStrongsQueryReturnsBundledResults() {
        let app = makeApp(searchQuery: "H00430")
        app.launch()

        _ = openSearch(in: app)
        waitForSearchState(containing: "query=H00430", in: app, timeout: 20)
        waitForSearchResultCount(atLeast: 1, in: app, timeout: 20)
    }

    /**
     Guards the shared text-entry placeholder normalization against SwiftUI prompt fields whose
     placeholder values surface through XCUI as `Optional(...)`.
     *
     * - Side effects: none.
     * - Failure modes:
     *   - fails if Optional-wrapped placeholder text no longer normalizes to the placeholder value
     */
    func testTextEntrySemanticValueCandidatesUnwrapOptionalPlaceholderForms() {
        let plainOptionalCandidates = textEntrySemanticValueCandidates(from: "Optional(Label name)")
        XCTAssertTrue(
            plainOptionalCandidates.contains("label name"),
            "Expected Optional(Label name) to normalize to the placeholder text."
        )

        let quotedOptionalCandidates = textEntrySemanticValueCandidates(from: "Optional(\"Name\")")
        XCTAssertTrue(
            quotedOptionalCandidates.contains("name"),
            "Expected Optional(\"Name\") to normalize to the placeholder text."
        )
    }

}
