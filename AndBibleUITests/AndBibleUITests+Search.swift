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
     Verifies Android `ListPreference` parity rows stay compact on the Settings root surface.
     *
     * The regression this guards against is SwiftUI's inline `Picker` presentation, which rendered
     * selected values such as `Chapter` and `System` as oversized blue rows in the Settings list.
     *
     * - Side effects:
     *   - launches the app and opens Application Preferences from the reader action surface
     *   - types row titles into the production Settings search field to reveal each preference row
     * - Failure modes:
     *   - fails if the menu-backed row identifier is missing
     *   - fails if a selected `ListPreference` value is visible as standalone root-row text
     */
    func testApplicationPreferencesRenderAndroidListPreferenceRowsWithoutInlineValues() {
        let app = makeApp()
        app.launch()

        openSettings(in: app)

        assertSettingsListPreferenceMenuRow(
            identifier: "settingsListPreferenceMenu::toolbar_button_actions",
            searchTitle: "Action for toolbar button press",
            inlineSelectedValue: "Press to open menu, long press for documents screen (default)",
            in: app
        )
        assertSettingsListPreferenceMenuRow(
            identifier: "settingsListPreferenceMenu::bible_view_swipe_mode",
            searchTitle: "Action for swipe left / right gesture",
            inlineSelectedValue: "Chapter",
            in: app
        )
        assertSettingsListPreferenceMenuRow(
            identifier: "settingsListPreferenceMenu::night_mode_pref3",
            searchTitle: "Night mode switching",
            inlineSelectedValue: "System",
            in: app
        )
        assertSettingsListPreferenceMenuRow(
            identifier: "settingsListPreferenceMenu::locale_pref",
            searchTitle: "Application language",
            inlineSelectedValue: "English",
            in: app
        )
        assertSettingsListPreferenceMenuRow(
            identifier: "settingsListPreferenceMenu::notes_content_type",
            searchTitle: "Format for new bookmark notes",
            inlineSelectedValue: "Rich text (HTML)",
            in: app
        )
    }

    /**
     Verifies that Android's main reader All Text Options action opens workspace text-display
     settings instead of the left-drawer Application Preferences destination.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic in-memory data
     *   - opens the real overflow menu action identified by Android's All Text Options row
     *   - pushes the native workspace-scoped Text Display settings destination
     * - Failure modes:
     *   - fails if the overflow action is routed to global Application Preferences
     *   - fails if the overflow action is routed to window-scoped Text Display settings
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
        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=workspace", in: app, timeout: 10)
        XCTAssertFalse(
            unresolvedElement("settingsForm", in: app).exists,
            "Expected All Text Options to open the Text Display destination, not Application Preferences."
        )
    }

    /**
     Verifies Android's workspace parent-link behavior from the reader All Text Options route.

     Android shows only the global parent link from workspace-scoped text-display settings. Tapping
     that link opens global text options, where the parent-link category is hidden because global is
     the root scope.
     *
     * - Side effects:
     *   - launches the app and opens the production reader All Text Options route
     *   - taps the Global text options parent link inside Text Display settings
     * - Failure modes:
     *   - fails if workspace scope exposes the window-only workspace parent link
     *   - fails if the global parent link is missing or does not open `scope=global`
     *   - fails if global scope still exposes parent links
     */
    func testWorkspaceTextOptionsParentLinkOpensGlobalScope() {
        let app = makeApp()
        app.launch()

        _ = openAllTextOptions(in: app)
        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=workspace", in: app, timeout: 10)
        XCTAssertFalse(
            unresolvedElement("textDisplayOpenWorkspaceSettingsButton", in: app).exists,
            "Workspace text options must not show Android's window-only workspace parent link."
        )

        let globalLink = requireElement("textDisplayOpenGlobalSettingsButton", in: app, timeout: 10)
        tapElementReliably(globalLink, timeout: 10)
        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=global", in: app, timeout: 10)
        XCTAssertFalse(unresolvedElement("textDisplayOpenWorkspaceSettingsButton", in: app).exists)
        XCTAssertFalse(unresolvedElement("textDisplayOpenGlobalSettingsButton", in: app).exists)
    }

    /**
     Verifies Android's per-window Text Options route and parent-link ladder.

     Android's pane/window menu opens window-scoped text options. That screen shows both parent
     links; the workspace link then opens workspace-scoped settings with only the global parent
     link visible.
     *
     * - Side effects:
     *   - launches the app, creates a second reader window through the tab bar, and opens the
     *     active pane hamburger menu
     *   - activates the pane-level All text options command
     *   - taps the workspace parent link from the window-scoped Text Display screen
     * - Failure modes:
     *   - fails if pane All text options routes to workspace/global scope
     *   - fails if window scope lacks either Android parent link
     *   - fails if the workspace parent link does not navigate to `scope=workspace`
     */
    func testPaneAllTextOptionsOpensWindowScopeAndWorkspaceParentLink() {
        let app = makeApp()
        app.launch()

        addWindowTab(expectingOrder: 1, in: app, timeout: 15)
        let paneMenu = requireElement("windowPaneMenuButton::1", in: app, timeout: 10)
        tapElementReliably(paneMenu, timeout: 10)
        let textOptionsAction = requireElement("windowPaneTextOptionsButton", in: app, timeout: 10)
        tapElementReliably(textOptionsAction, timeout: 10)

        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=window", in: app, timeout: 10)
        let workspaceLink = requireElement("textDisplayOpenWorkspaceSettingsButton", in: app, timeout: 10)
        XCTAssertTrue(requireElement("textDisplayOpenGlobalSettingsButton", in: app, timeout: 10).exists)

        tapElementReliably(workspaceLink, timeout: 10)
        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=workspace", in: app, timeout: 10)
        XCTAssertFalse(unresolvedElement("textDisplayOpenWorkspaceSettingsButton", in: app).exists)
        XCTAssertTrue(requireElement("textDisplayOpenGlobalSettingsButton", in: app, timeout: 10).exists)
    }

    /**
     Verifies Android's Application Preferences Global text options route.

     The Android root Settings screen exposes `global_text_display_settings` under Look & feel.
     iOS mirrors that shortcut, and opening it must show global scope with no parent links.
     *
     * - Side effects:
     *   - launches the app and opens Application Preferences from reader actions
     *   - activates the Global text options row
     * - Failure modes:
     *   - fails if the global settings shortcut is metadata-only and not user-navigable
     *   - fails if Application Preferences opens workspace/window text options instead of global
     *   - fails if global scope exposes parent links
     */
    func testApplicationPreferencesGlobalTextOptionsOpenGlobalScope() {
        let app = makeApp()
        app.launch()

        _ = openSettingsDestination(
            linkIdentifier: "settingsGlobalTextOptionsLink",
            destinationIdentifier: "textDisplaySettingsScreen",
            readinessIdentifiers: ["textDisplayFontFamilyButton"],
            in: app,
            destinationTimeout: 20
        )

        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=global", in: app, timeout: 10)
        XCTAssertFalse(unresolvedElement("textDisplayOpenWorkspaceSettingsButton", in: app).exists)
        XCTAssertFalse(unresolvedElement("textDisplayOpenGlobalSettingsButton", in: app).exists)
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
     Reveals and validates one Settings `ListPreference` row after the Android-style conversion.
     *
     * - Parameters:
     *   - identifier: Stable menu-row accessibility identifier exposed by production Settings.
     *   - searchTitle: English row title used to narrow Settings search in UI tests.
     *   - inlineSelectedValue: Value that must not be visible as standalone root-list text.
     *   - app: Running application under test.
     * - Side effects: rewrites the Settings search query.
     * - Failure modes: records XCTest failures for missing rows or visible inline selected values.
     */
    private func assertSettingsListPreferenceMenuRow(
        identifier: String,
        searchTitle: String,
        inlineSelectedValue: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let settingsForm = requireElement("settingsForm", in: app, timeout: 10, file: file, line: line)
        let searchField = requireSettingsSearchField(in: app, settingsForm: settingsForm, file: file, line: line)
        replaceText(in: searchField, with: searchTitle, placeholderHints: ["Search"])

        let row = requireElement(identifier, in: app, timeout: 10, file: file, line: line)
        XCTAssertTrue(row.exists, "Expected compact menu row \(identifier) to exist.", file: file, line: line)
        XCTAssertFalse(
            isVisibleSettingsText(inlineSelectedValue, in: app, settingsForm: settingsForm),
            "Expected '\(inlineSelectedValue)' to be hidden until the menu opens, not rendered inline in Settings.",
            file: file,
            line: line
        )
    }

    /**
     Resolves the Settings search field used to reveal offscreen Android-parity rows.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - settingsForm: Visible Settings root surface.
     * - Returns: The search field exposed by SwiftUI's `searchable` modifier.
     * - Side effects: scrolls upward when the search field is not initially in the hierarchy.
     * - Failure modes: records an XCTest failure when search cannot be reached.
     */
    private func requireSettingsSearchField(
        in app: XCUIApplication,
        settingsForm: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if let field = firstExistingElement(
                settingsSearchFieldCandidates(in: app, settingsForm: settingsForm),
                timeout: 0.2
            ) {
                return field
            }
            settingsForm.swipeDown()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail("Expected Settings search field to exist.", file: file, line: line)
        return app.searchFields["Search"].firstMatch
    }

    /**
     Reports whether one visible Settings text/control still exposes stale inline picker content.
     *
     * - Parameters:
     *   - text: Exact selected value that should only appear after opening a chooser menu.
     *   - app: Running application under test.
     *   - settingsForm: Settings root surface used as the visibility container.
     * - Returns: `true` when the stale value is visible in the root Settings surface.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail directly.
     */
    private func isVisibleSettingsText(
        _ text: String,
        in app: XCUIApplication,
        settingsForm: XCUIElement
    ) -> Bool {
        [
            settingsForm.staticTexts[text].firstMatch,
            settingsForm.buttons[text].firstMatch,
            settingsForm.otherElements[text].firstMatch,
            app.staticTexts[text].firstMatch,
            app.buttons[text].firstMatch,
            app.otherElements[text].firstMatch,
        ].contains { $0.exists && isElementVisible($0, within: settingsForm) }
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
     *   - launches the standard reader shell without a launch-seeded Search presentation
     *   - opens Search from the real reader toolbar, enters a deterministic bundled query, waits
     *     for the bundled index/search pass, and taps the first returned result row
     *   - dismisses Search through the normal result-selection flow and navigates the reader to
     *     the selected passage
     * - Failure modes:
     *   - fails if Search cannot be opened from the reader toolbar
     *   - fails if the Search field cannot receive and submit the deterministic query
     *   - fails if bundled search results do not produce at least one tappable result row
     *   - fails if selecting the result does not move the reader away from `Genesis 1`
     */
    func testSearchResultSelectionNavigatesReaderToBundledReference() {
        let app = makeApp()
        app.launch()

        let initialReference = requireReaderReferenceValue(in: app, timeout: 15)

        _ = openSearch(in: app)
        let searchField = requireSearchInput(in: app, timeout: 10)
        replaceText(in: searchField, with: "noah", placeholderHints: ["Search Bible text", "Search Bible", "Search"])
        dismissKeyboardAfterFocusedTextEntry(searchField, in: app)
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
     Verifies that a bundled Strong's query reaches the indexed lexical-token path and returns hits.
     *
     * - Side effects:
     *   - launches the app directly into Search with one deterministic Strong's query
     *   - lets Search create the bundled KJV index when missing, then waits for non-zero results
     * - Failure modes:
     *   - fails if Search never reaches the ready state for the Strong's query after index setup
     *   - fails if the bundled Strong's-capable Bible still reports zero indexed lexical matches
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
