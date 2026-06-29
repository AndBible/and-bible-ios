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
        openPaneMenu(paneMenu, in: app, timeout: 10)
        let textOptionsSubmenu = requirePaneMenuItem("windowPaneMenuItem::textOptions", in: app, timeout: 10)
        tapElementReliably(textOptionsSubmenu, timeout: 10)
        let allTextOptionsAction = requirePaneMenuItem("windowPaneMenuItem::allTextOptions", in: app, timeout: 10)
        tapElementReliably(allTextOptionsAction, timeout: 10)

        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=window", in: app, timeout: 10)
        let workspaceLink = requireElement("textDisplayOpenWorkspaceSettingsButton", in: app, timeout: 10)
        XCTAssertTrue(requireElement("textDisplayOpenGlobalSettingsButton", in: app, timeout: 10).exists)

        tapElementReliably(workspaceLink, timeout: 10)
        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=workspace", in: app, timeout: 10)
        XCTAssertFalse(unresolvedElement("textDisplayOpenWorkspaceSettingsButton", in: app).exists)
        XCTAssertTrue(requireElement("textDisplayOpenGlobalSettingsButton", in: app, timeout: 10).exists)
    }

    /**
     Verifies that closing a pane from Android's pane hamburger menu leaves the reader alive.

     The close action removes the active SwiftData `Window` and its cascaded `PageManager`. The
     reader must detach that window from visible SwiftUI state before deleting it so the split view
     never re-renders a pane backed by invalidated model objects.
     *
     - Side effects:
     *   - launches the app, creates a second reader window through the tab bar, and opens the
     *     active pane hamburger menu
     *   - activates the pane-level Close command
     * - Failure modes:
     *   - fails if the pane menu close action terminates the app
     *   - fails if the closed window tab remains visible after the close transaction settles
     *   - fails if the remaining one-window pane loses Android's pane hamburger affordance
     *   - fails if the remaining one-window footer cannot create another window
     */
    func testPaneMenuCloseWindowKeepsReaderAlive() {
        let app = makeApp()
        app.launch()

        addWindowTab(expectingOrder: 1, in: app, timeout: 15)
        openPaneMenu(requireElement("windowPaneMenuButton::1", in: app, timeout: 10), in: app, timeout: 10)
        tapElementReliably(
            requirePaneMenuItem("windowPaneMenuItem::close", in: app, timeout: 12),
            timeout: 10
        )

        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected reader shell to remain alive after pane-menu Close."
        )
        waitForClosedWindowOrder(1, in: app, timeout: 15)
        let finalState = readerRenderedContentStateValue(in: app) ?? "nil"
        XCTAssertFalse(finalState.contains("windowOrder=none"), "Expected an active reader window after Close; state=\(finalState)")
        XCTAssertTrue(requireElement("windowPaneMenuButton::0", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("windowTabAddButton", in: app, timeout: 10).exists)
    }

    /**
     Waits until the reader's live footer model no longer contains a closed window order.

     The tab bar is backed by `WindowManager.allWindows`, which the compact reader state exposes as
     `windowTabOrders`. Watching that model keeps the assertion tied to the close transaction itself
     instead of a stale accessibility snapshot from the removed SwiftUI button.
     *
     * - Parameters:
     *   - order: Window order that should be removed from the footer model.
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for SwiftData deletion and SwiftUI reconciliation.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects: polls the compact reader state export.
     * - Failure modes: records an XCTest failure when the closed order remains present or the
     *   reader loses its active-window state.
     */
    private func waitForClosedWindowOrder(
        _ order: Int,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastState = readerRenderedContentStateValue(in: app) ?? "nil"
        var lastOrders = windowTabOrdersFromReaderState(in: app)
        repeat {
            lastState = readerRenderedContentStateValue(in: app) ?? "nil"
            lastOrders = windowTabOrdersFromReaderState(in: app)
            if let lastOrders,
               !lastOrders.contains(order),
               !lastState.contains("windowOrder=none") {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let failureMessage = """
            Expected window order \(order) to be removed within \(timeout) seconds; \
            orders=\(String(describing: lastOrders)), state=\(lastState)
            """
        XCTFail(
            failureMessage,
            file: file,
            line: line
        )
    }

    /**
     Opens the Android-style pane popup menu and waits until its custom SwiftUI surface is visible.

     CI can accept the tap on the small pane hamburger while SwiftUI still drops the presentation
     transaction under load. This helper keeps the test anchored on the real user affordance by
     retrying the pane-menu button only until the actual popup container appears.
     *
     * - Parameters:
     *   - paneMenu: The pane hamburger button already resolved by accessibility identifier.
     *   - app: Running application under test.
     *   - timeout: Maximum time to retry the button/popup handshake.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects: taps the pane hamburger button and polls the live accessibility hierarchy.
     * - Failure modes: records an XCTest failure when the popup surface never appears.
     */
    private func openPaneMenu(
        _ paneMenu: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if resolvedPaneMenuSurface(in: app) != nil {
                return
            }

            _ = tapElementIfPossible(paneMenu, timeout: 1)
            if waitForPaneMenuSurface(in: app, timeout: 0.8) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTAssertTrue(
            resolvedPaneMenuSurface(in: app) != nil,
            "Expected pane menu surface to appear within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Resolves one Android-style pane-menu row, scrolling the custom popup when the row is below the
     first visible viewport.

     - Parameters:
     *   - identifier: Accessibility identifier for the pane-menu row.
     *   - app: Running application under test.
     *   - timeout: Maximum time to search while scrolling.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first matching row that XCTest reports as hittable, or the unresolved query
     *   after failure.
     * - Side effects: swipes the `windowPaneMenu` popup surface upward while re-querying rows.
     * - Failure modes: records an XCTest failure when the row never becomes hittable.
     */
    private func requirePaneMenuItem(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let item = resolvedPaneMenuItem(identifier, in: app) {
                if waitForElementToBecomeHittable(item, timeout: 0.2) {
                    return item
                }
            }

            if let menuSurface = resolvedPaneMenuSurface(in: app) {
                menuSurface.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let item = app.buttons[identifier].firstMatch.exists
            ? app.buttons[identifier].firstMatch
            : unresolvedElement(identifier, in: app)
        XCTAssertTrue(
            item.exists && item.isHittable,
            "Expected pane menu item '\(identifier)' to become hittable within \(timeout) seconds.",
            file: file,
            line: line
        )
        return item
    }

    private func resolvedPaneMenuItem(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        let menuScrollView = app.scrollViews["windowPaneMenu"].firstMatch
        let candidates = [
            menuScrollView.buttons[identifier].firstMatch,
            app.buttons[identifier].firstMatch,
            menuScrollView.otherElements[identifier].firstMatch,
            app.otherElements[identifier].firstMatch,
        ]
        return candidates.first(where: { elementHasUsableFrame($0) })
    }

    /**
     Polls for the custom pane menu surface without recording an assertion failure.

     - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for any accessibility surface that represents the popup.
     * - Returns: `true` when a usable popup container appears before the timeout.
     * - Side effects: repeatedly queries the live accessibility hierarchy.
     * - Failure modes: This helper cannot fail directly.
     */
    private func waitForPaneMenuSurface(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if resolvedPaneMenuSurface(in: app) != nil {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return resolvedPaneMenuSurface(in: app) != nil
    }

    /**
     Resolves the SwiftUI accessibility surface for the Android-style pane popup menu.

     SwiftUI can expose the same custom menu as a scroll view, other element, or button depending
     on the OS/XCTest runtime. The helper accepts any candidate with a usable frame so tests can
     scroll or verify the real popup surface without depending on one platform-specific element
     type.
     *
     * - Parameter app: Running application under test.
     * - Returns: The first usable popup container, or `nil` when the menu is not visible.
     * - Side effects: queries the live accessibility hierarchy only.
     * - Failure modes: This helper cannot fail directly.
     */
    private func resolvedPaneMenuSurface(in app: XCUIApplication) -> XCUIElement? {
        let candidates = [
            app.scrollViews["windowPaneMenu"].firstMatch,
            app.otherElements["windowPaneMenu"].firstMatch,
            app.buttons["windowPaneMenu"].firstMatch,
        ]
        return candidates.first(where: { elementHasUsableFrame($0) })
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
     Search fixture contract for normal UI workflows.

     `scripts/ui_test_fixture_manifest.json` maps these Search tests to the `search-indexed` or
     `search-multi-translation` scenarios. Those scenarios seed `search_indexes.sqlite` before app
     launch, so the app should detect the selected modules as already indexed. Normal Search tests
     must not enter `state=needsIndex`; runtime index-creation coverage belongs in a separate test
     and fixture path so it cannot hide seeded-fixture regressions.
     */

    /**
     Verifies that Search preserves a seeded initial query typed through the real UI.
     *
     * - Side effects:
     *   - launches the app on the reader shell with the initial query `earth` queued for Search
     *   - opens Search from the toolbar and waits for the Search destination to settle
     * - Failure modes:
     *   - fails if the Search screen never appears
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
     Verifies Search opens as an integrated reader destination instead of an iOS sheet.
     *
     * Android Search is a full activity with toolbar navigation, not a bottom/large iOS sheet with a
     * `Done` affordance. This test protects that presentation contract separately from Search's
     * query behavior so future visual parity work does not accidentally reintroduce sheet chrome.
     *
     * - Setup: Launches the standard seeded Search fixture and opens Search through the reader entry.
     * - Expected result: The reader state reports `readerDestination=search`, and no navigation-bar
     *   `Done` button is exposed by the Search surface.
     * - Failure meaning: Search has drifted back to sheet/modal presentation instead of Android's
     *   destination-style surface.
     * - Side effects: Presents Search from the reader shell.
     */
    func testSearchPresentsAsReaderDestinationInsteadOfSheet() {
        let app = makeApp(searchQuery: "earth")
        app.launch()

        _ = openSearch(in: app)
        waitForReaderRenderedContentState(containing: "readerDestination=search", in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Search should not expose iOS sheet-style Done chrome when opened from the reader."
        )
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
     *   - uses the seeded startup reader reference `Genesis 1:1` as the before-navigation value
     *   - verifies picker Cancel ignores a draft UITESTWEB row selection
     *   - verifies outside dismissal ignores a draft UITESTWEB row selection
     *   - verifies Select all followed by Select none and OK preserves the prior selection
     *   - opens the real translation picker, selects UITESTWEB, and commits with OK
     *   - verifies the visible selected-translation summary matches Android's abbreviation list
     *   - waits for the active query to rerun and export grouped per-translation counts
     * - Failure modes:
     *   - fails if the translation picker is not reachable from Search options
     *   - fails if Cancel, outside dismissal, or empty OK mutates the committed module selection
     *   - fails if selecting a second translation does not rerun the active query with KJV first
     *   - fails if the selected-translation button collapses Android's abbreviation list into a
     *     generic iOS count label
     *   - fails if grouped totals collapse to single-translation results
     */
    func testSearchMultiTranslationSelectionUpdatesGroupedTotals() {
        let app = makeApp(searchQuery: "earth")
        app.launch()

        let initialReference = "Genesis 1:1"

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
        tapSearchTranslationRow(moduleName: "UITESTWEB", in: app, timeout: 45)
        tapSearchTranslationCancel(in: app, timeout: 10)
        waitForSearchSelectedModules(
            in: app,
            timeout: 10,
            description: "still exactly KJV after cancel"
        ) { modules in
            modules == Set(["KJV"])
        }

        tapSearchTranslationPicker(in: app, timeout: 10)
        tapSearchTranslationRow(moduleName: "UITESTWEB", in: app, timeout: 45)
        tapSearchTranslationOutsideDismiss(in: app, timeout: 10)
        waitForSearchSelectedModules(
            in: app,
            timeout: 10,
            description: "still exactly KJV after outside dismissal"
        ) { modules in
            modules == Set(["KJV"])
        }

        tapSearchTranslationPicker(in: app, timeout: 10)
        tapSearchTranslationSelectAll(in: app, timeout: 10)
        tapSearchTranslationSelectAll(in: app, timeout: 10)
        tapSearchTranslationOK(in: app, timeout: 10)
        waitForSearchSelectedModules(
            in: app,
            timeout: 10,
            description: "still exactly KJV after empty OK"
        ) { modules in
            modules == Set(["KJV"])
        }

        tapSearchTranslationPicker(in: app, timeout: 10)
        tapSearchTranslationRow(moduleName: "UITESTWEB", in: app, timeout: 45)
        tapSearchTranslationOK(in: app, timeout: 10)

        waitForSearchSelectedModules(
            in: app,
            timeout: 20,
            description: "more than one module including UITESTWEB"
        ) { modules in
            modules.count > 1 && modules.contains("UITESTWEB")
        }
        waitForSearchState(containing: "selectedModuleOrder=KJV,UITESTWEB", in: app, timeout: 20)
        XCTAssertTrue(
            app.staticTexts["KJV, UITESTWEB"].waitForExistence(timeout: 5),
            "Expected the Search translation button to show Android's selected abbreviation list."
        )
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
     *   - fails if selecting the result does not move the reader to the selected verse
     */
    func testSearchResultSelectionNavigatesReaderToBundledReference() {
        let app = makeApp()
        app.launch()

        let initialReference = requireReaderReferenceValue(in: app, timeout: 15)

        _ = openSearch(in: app)
        let searchField = requireSearchInput(in: app, timeout: 10)
        replaceText(in: searchField, with: "noah", placeholderHints: ["Search Bible text", "Search Bible", "Search"])
        dismissSearchFieldFocusIfNeeded(in: app)
        waitForSearchQuery("noah", in: app, timeout: 20)

        let noahResultIdentifier = "searchResultRow::Genesis_6_8"
        waitForSearchResultRow(noahResultIdentifier, in: app, shouldExist: true, timeout: 20)
        let updatedReference = tapSearchResultRowAndWaitForReaderReferenceChange(
            noahResultIdentifier,
            from: initialReference,
            in: app,
            timeout: 20
        )
        XCTAssertNotEqual(
            updatedReference,
            initialReference,
            "Expected selecting a Search result to move the reader away from '\(initialReference)'."
        )
        XCTAssertTrue(
            updatedReference.localizedCaseInsensitiveContains("Genesis 6:8"),
            "Expected selecting the Search result to navigate to Genesis 6:8, but saw '\(updatedReference)'."
        )
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
