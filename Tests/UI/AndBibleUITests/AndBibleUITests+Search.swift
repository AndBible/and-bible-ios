import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    /**
     Verifies reader administration actions and Settings route Android shortcut rows.
     *
     * Package tests own the full Application Preferences row catalog. This UI smoke keeps the live
     * route contract: About, Label Settings, and AI Settings remain reachable from the reader menu;
     * AI setup is blocked by Android's explicit disclaimer acceptance; Application Preferences
     * opens the same AI screen; and Global text options opens root-scoped Text Display settings.
     *
     * - Side effects:
     *   - launches the app with deterministic in-memory persistence
     *   - opens and dismisses About from the reader menu
     *   - opens and dismisses Label Manager from the reader menu's Label Settings action
     *   - opens AI Settings directly from the reader drawer and cancels both protected entry points
     *   - explicitly accepts once, then verifies Quick Setup resumes and both actions bypass the gate
     *   - pushes Settings from the reader action surface
     *   - opens the shared AI Settings destination from Application Preferences
     *   - activates the production Global text options row
     * - Failure modes:
     *   - fails if About no longer opens from the reader menu or cannot return to the reader shell
     *   - fails if Label Settings cannot reach `LabelManagerView` readiness exports
     *   - fails if AI Settings is absent from the drawer or cancellation counts as acceptance
     *   - fails if explicit acceptance does not resume and persist for the protected action
     *   - fails if disclaimer copy renders localization identifiers instead of Android's text
     *   - fails if Settings still presents as a sheet instead of a reader destination
     *   - fails if the Android shortcut rows disappear from the Settings state
     *   - fails if Global text options opens any scope other than `global`
     */
    func testSettingsApplicationShortcutsOpenGlobalTextOptions() {
        let app = makeApp()
        app.launch()

        openAboutFromReaderMenu(in: app)
        let aboutSheet = requireElement("aboutSheetScreen", in: app, timeout: 10)
        tapElementReliably(requireElement("aboutDoneButton", in: app, timeout: 10), timeout: 10)
        waitForElementToDisappear(aboutSheet, timeout: 10)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected About dismissal to return to the reader shell."
        )

        XCTAssertTrue(openLabelManager(in: app).exists)
        _ = requireElement("labelManagerAddButton", in: app, timeout: 10)
        _ = requireElement("labelManagerStateExport", in: app, timeout: 10)
        let labelManagerDoneButton = firstExistingElement(
            [
                app.navigationBars.buttons["Done"].firstMatch,
                app.buttons["Done"].firstMatch,
            ],
            timeout: 10
        )
        XCTAssertNotNil(labelManagerDoneButton, "Expected Label Manager to expose a Done action.")
        guard let labelManagerDoneButton else {
            return
        }
        tapElementReliably(labelManagerDoneButton, timeout: 10)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected Label Manager dismissal to return to the reader shell."
        )

        tapReaderAction("readerOpenAISettingsAction", in: app, timeout: 20)
        XCTAssertTrue(requireElement("aiSettingsScreen", in: app, timeout: 20).exists)
        waitForReaderRenderedContentState(containing: "readerDestination=aiSettings", in: app, timeout: 10)
        tapElementReliably(requireElement("aiQuickSetupButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiDisclaimerScreen", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("aiDisclaimerAcceptButton", in: app, timeout: 10).exists)
        let localizedDisclaimerPoint = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "AI can make mistakes")
        ).firstMatch
        XCTAssertTrue(
            localizedDisclaimerPoint.waitForExistence(timeout: 10),
            "Expected Android's localized disclaimer point instead of a raw resource key."
        )
        XCTAssertFalse(app.staticTexts["ai_disclaimer_point1"].exists)
        tapElementReliably(requireElement("aiDisclaimerCancelButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiSettingsScreen", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("aiAddProviderLink", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(
            requireElement("aiDisclaimerScreen", in: app, timeout: 10).exists,
            "Add Provider must use Android's same explicit disclaimer gate."
        )
        tapElementReliably(requireElement("aiDisclaimerCancelButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiSettingsScreen", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("aiQuickSetupButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(
            requireElement("aiDisclaimerScreen", in: app, timeout: 10).exists,
            "Cancelling the disclaimer must not count as acceptance."
        )
        let disclaimerScreen = requireElement("aiDisclaimerScreen", in: app, timeout: 10)
        let disclaimerAcceptButton = requireElement("aiDisclaimerAcceptButton", in: app, timeout: 10)
        for _ in 0..<8 where !disclaimerAcceptButton.isHittable {
            disclaimerScreen.swipeUp()
        }
        XCTAssertTrue(
            disclaimerAcceptButton.isHittable,
            "Expected the full Android disclaimer to scroll to its explicit acceptance action."
        )
        tapElementReliably(disclaimerAcceptButton, timeout: 10)
        XCTAssertTrue(
            requireElement("aiQuickSetupSaveButton", in: app, timeout: 10).exists,
            "Explicit acceptance must resume the exact Quick Setup action."
        )
        tapElementReliably(requireElement("aiQuickSetupCancelButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiSettingsScreen", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("aiQuickSetupButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(
            requireElement("aiQuickSetupSaveButton", in: app, timeout: 10).exists,
            "Persisted acceptance must bypass the disclaimer on later protected actions."
        )
        XCTAssertFalse(unresolvedElement("aiDisclaimerScreen", in: app).exists)
        tapElementReliably(requireElement("aiQuickSetupCancelButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiSettingsScreen", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("aiAddProviderLink", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(
            requireElement("aiProviderSaveButton", in: app, timeout: 10).exists,
            "Persisted acceptance must resume Add Provider without another disclaimer."
        )
        XCTAssertFalse(unresolvedElement("aiDisclaimerScreen", in: app).exists)
        tapElementReliably(requireElement("aiProviderCloseButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiSettingsScreen", in: app, timeout: 10).exists)

        let aiSettingsBackButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(
            aiSettingsBackButton.waitForExistence(timeout: 10),
            "Expected direct AI Settings to expose reader-stack back navigation."
        )
        tapElementReliably(aiSettingsBackButton, timeout: 10)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected AI Settings back navigation to return to the reader shell."
        )

        openSettings(in: app)
        XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)
        waitForReaderRenderedContentState(containing: "readerSheet=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=settings", in: app, timeout: 10)
        waitForSettingsState(containing: "settingsGlobalTextOptionsLink", in: app, timeout: 10)
        waitForSettingsState(containing: "settingsSyncLink", in: app, timeout: 10)
        waitForSettingsState(containing: "settingsAISettingsLink", in: app, timeout: 10)
        waitForSettingsState(containing: "settingsReadingProgressLink", in: app, timeout: 10)
        waitForSettingsState(containing: "adminFlows=readerActions", in: app, timeout: 10)

        tapSettingsElement("settingsAISettingsLink", in: app, timeout: 20)
        XCTAssertTrue(requireElement("aiSettingsScreen", in: app, timeout: 20).exists)
        let nestedAISettingsBackButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(
            nestedAISettingsBackButton.waitForExistence(timeout: 10),
            "Expected nested AI Settings to return to Application Preferences."
        )
        tapElementReliably(nestedAISettingsBackButton, timeout: 10)
        XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)

        tapSettingsElement("settingsGlobalTextOptionsLink", in: app, timeout: 20)
        XCTAssertTrue(requireElement("textDisplaySettingsScreen", in: app, timeout: 20).exists)
        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=global", in: app, timeout: 10)
        XCTAssertFalse(unresolvedElement("textDisplayOpenWorkspaceSettingsButton", in: app).exists)
        XCTAssertFalse(unresolvedElement("textDisplayOpenGlobalSettingsButton", in: app).exists)
    }

    /**
     Verifies Android's reader All Text Options route, color reset, workspace parent link, and
     font-family editor presentation.
     *
     Package tests own text-display row order, row visibility, editor state semantics, and Android
     value normalization. This UI smoke keeps the production route live: the reader action opens
     workspace-scoped Text Display settings, the workspace scope exposes only the global parent
     link, and the font-family editor is the in-place Android-style dialog rather than native iOS
     picker or sheet chrome.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic in-memory data
     *   - opens the real overflow menu action identified by Android's All Text Options row
     *   - opens Colors from that workspace-scoped route and resets seeded custom colors
     *   - taps the Global text options parent link inside Text Display settings
     *   - opens the font-family editor overlay
     * - Failure modes:
     *   - fails if the overflow action is routed to global Application Preferences
     *   - fails if the overflow action is routed to window-scoped Text Display settings
     *   - fails if the Colors route or reset action is missing from the visible Android path
     *   - fails if the workspace parent link is missing or if global scope still exposes parent
     *     links
     *   - fails if the editor route regresses to native iOS picker/sheet presentation
     */
    func testAllTextOptionsWorkspaceRouteAndFontEditor() {
        let app = makeApp()
        app.launch()

        let textDisplayScreen = openAllTextOptions(in: app)
        XCTAssertTrue(textDisplayScreen.exists)
        waitForReaderRenderedContentState(containing: "readerSheet=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=textOptions", in: app, timeout: 10)
        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=workspace", in: app, timeout: 10)
        XCTAssertFalse(
            unresolvedElement("settingsForm", in: app).exists,
            "Expected All Text Options to open the Text Display destination, not Application Preferences."
        )

        XCTAssertFalse(
            unresolvedElement("textDisplayOpenWorkspaceSettingsButton", in: app).exists,
            "Workspace text options must not show Android's window-only workspace parent link."
        )

        let colorsLink = requireReachableTextDisplayButton("textDisplayColorsLink", in: app, timeout: 10)
        tapElementReliably(colorsLink, timeout: 10)
        waitForElementValue("colorSettingsScreen", toEqual: "colorCustom", in: app, timeout: 10)
        XCTAssertEqual(resolvedElementSemanticText("colorSettingsScreen", in: app), "colorCustom")

        tapElementReliably(requireElement("colorSettingsResetButton", in: app, timeout: 10), timeout: 10)
        waitForElementValue("colorSettingsScreen", toEqual: "colorDefaults", in: app, timeout: 10)

        let colorSettingsBackButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(
            colorSettingsBackButton.waitForExistence(timeout: 10),
            "Expected Colors to expose NavigationStack back chrome to Text Options."
        )
        tapElementReliably(colorSettingsBackButton, timeout: 10)
        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=workspace", in: app, timeout: 10)

        let globalLink = requireReachableTextDisplayButton(
            "textDisplayOpenGlobalSettingsButton",
            in: app,
            revealDirection: .upper,
            timeout: 10
        )
        tapElementReliably(globalLink, timeout: 10)
        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=global", in: app, timeout: 10)
        XCTAssertFalse(unresolvedElement("textDisplayOpenWorkspaceSettingsButton", in: app).exists)
        XCTAssertFalse(unresolvedElement("textDisplayOpenGlobalSettingsButton", in: app).exists)

        let fontFamilyButton = requireReachableTextDisplayButton("textDisplayFontFamilyButton", in: app, timeout: 10)
        tapElementReliably(fontFamilyButton, timeout: 10)
        waitForElementValue("textDisplaySettingsScreen", toContain: "preferenceEditor=fontFamily", in: app, timeout: 10)
        XCTAssertTrue(
            app.otherElements["textDisplayPreferenceEditorOverlay"].waitForExistence(timeout: 10),
            "Expected the Android-style text display editor overlay to be visible."
        )
    }

    /**
     Verifies Android's per-window Text Options route, parent-link ladder, and pane Close action.

     Android's pane/window menu owns both per-window Text Options and Close. These are distinct
     commands, but both require the same setup: create a second reader pane, open that pane's
     hamburger menu, and exercise a pane-scoped command. Keeping them in one workflow removes a
     duplicate cold launch while preserving the visible window-scope route and delete transaction.
     *
     * - Side effects:
     *   - launches the app, creates a second reader window through the tab bar, and opens the
     *     active pane hamburger menu
     *   - activates the pane-level All text options command
     *   - taps the workspace parent link from the window-scoped Text Display screen
     *   - exits the Text Options route, reopens the same pane menu, and activates Close
     * - Failure modes:
     *   - fails if pane All text options routes to workspace/global scope
     *   - fails if window scope lacks either Android parent link
     *   - fails if the workspace parent link does not navigate to `scope=workspace`
     *   - fails if pane-menu Close terminates the app, leaves the deleted tab visible, or removes
     *     the remaining pane menu/add-window affordances
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

        let nestedTextOptionsBackButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(
            nestedTextOptionsBackButton.waitForExistence(timeout: 10),
            "Expected workspace Text Options to expose NavigationStack back chrome."
        )
        tapElementReliably(nestedTextOptionsBackButton, timeout: 10)
        if !waitForReaderShellReady(in: app, timeout: 5) {
            waitForElementValue("textDisplaySettingsScreen", toContain: "scope=window", in: app, timeout: 10)
            tapElementReliably(requireElement("readerDestinationBackButton", in: app, timeout: 10), timeout: 10)
            XCTAssertTrue(
                waitForReaderShellReady(in: app, timeout: 20),
                "Expected Text Options back navigation to return to the reader shell before closing the pane."
            )
        }
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
        var lastOrders = windowTabOrdersFromReaderState(in: app)
        waitForResolvedSemanticState(
            named: "readerClosedWindowOrder",
            timeout: timeout,
            valueProvider: { self.readerRenderedContentStateValue(in: app) ?? "nil" },
            success: { state in
                if let rawOrders = self.readerRenderedContentStateToken("windowTabOrders", in: state) {
                    lastOrders = rawOrders == "none"
                        ? []
                        : rawOrders
                            .split(separator: ",")
                            .compactMap { Int($0) }
                } else {
                    lastOrders = nil
                }
                guard let lastOrders else {
                    return false
                }
                return !lastOrders.contains(order) && !state.contains("windowOrder=none")
            },
            failureDescription: { state in
                """
                Expected window order \(order) to be removed within \(timeout) seconds; \
                orders=\(String(describing: lastOrders)), state=\(state)
                """
            },
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
            if waitForPaneMenuSurface(in: app, timeout: min(0.8, max(0, deadline.timeIntervalSinceNow))) {
                return
            }
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
     Waits for the custom pane menu surface without recording an assertion failure.

     - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for any accessibility surface that represents the popup.
     * - Returns: `true` when a usable popup container appears before the timeout.
     * - Side effects: waits on an XCTest predicate over the live accessibility hierarchy.
     * - Failure modes: This helper cannot fail directly.
     */
    private func waitForPaneMenuSurface(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(block: { _, _ in self.resolvedPaneMenuSurface(in: app) != nil })
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        expectation.expectationDescription = "Wait for pane menu surface"
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed || resolvedPaneMenuSurface(in: app) != nil
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
     Search fixture contract for normal UI workflows.

     `Tests/UI/Fixtures/ui_test_fixture_manifest.json` maps retained Search UI tests to the
     `search-multi-translation` scenario. That scenario seeds `search_indexes.sqlite` and the
     deterministic AATESTWEB module before app launch, so the app should detect selected modules as
     already indexed. Normal Search tests must not enter `state=needsIndex`; runtime index-creation
     coverage belongs in a separate test and fixture path so it cannot hide seeded-fixture
     regressions.
     */

    /**
     Verifies Search opens as an integrated reader destination, mutates active-query state, and
     returns to the reader from result selection.
     *
     * Exact Android search semantics for scope filters and word modes are covered in
     * `SearchIndexServiceQueryTests`. This UI smoke stays focused on the live Search surface:
     * Search must open as an Android-style reader destination rather than an iOS sheet, preserve
     * the launch-seeded query, expose tappable scope and word-mode rows, update exported state, and
     * rerender the seeded result list after each option change. The same live Search route then
     * enters a deterministic fixture query, verifies the live translation picker Cancel,
     * outside-dismiss, and empty-OK paths, commits a second translation through the live picker,
     * verifies grouped unique-verse and translation-hit totals plus both visible module rows, and
     * selects the secondary translation result so the
     * reader-navigation handoff remains covered
     * without a second cold app launch.
     *
     * - Side effects:
     *   - launches the app directly into Search with the initial query `earth void`
     *   - opens Search through the reader entry and verifies destination/no-sheet chrome
     *   - switches Search scope between NT and OT
     *   - switches Search word mode from all words to phrase and then to any word
     *   - enters a deterministic fixture query, exercises negative Search translation-picker
     *     dialog paths, commits the seeded two-module translation selection, and taps its visible
     *     AATESTWEB result row
     * - Failure modes:
     *   - fails if Search regresses to sheet/modal presentation or drops the launch-seeded query
     *   - fails if visible Search option controls are not accessible
     *   - fails if scope or word-mode changes do not update the Search state export
     *   - fails if the visible seeded result list does not rerender after option changes
     *   - fails if live translation-picker Cancel, outside-dismiss, or empty OK commits draft
     *     changes instead of preserving the previous selection
     *   - fails if the translation picker cannot commit a second module with KJV first
     *   - fails if matching translations are not grouped into one Android-compatible unique verse
     *     while retaining accessible result rows for both translation hits
     *   - fails if selecting the final result row does not navigate the reader to the selected
     *     passage
     */
    func testSearchOptionControlsMutateVisibleState() {
        let app = makeApp(searchQuery: "earth void")
        app.launch()

        let initialReference = "Genesis 1:1"
        _ = openSearch(in: app)
        waitForReaderRenderedContentState(containing: "readerDestination=search", in: app, timeout: 10)
        XCTAssertFalse(
            app.navigationBars.buttons["Done"].firstMatch.exists,
            "Search should not expose iOS sheet-style Done chrome when opened from the reader."
        )
        waitForSearchQuery("earth void", in: app, timeout: 20)
        waitForSearchResultRow("searchResultRow::Genesis_1_2", in: app, shouldExist: true, timeout: 20)

        tapSearchScope(.newTestament, in: app)
        waitForSearchState(containing: "scope=newTestament", in: app, timeout: 20)
        waitForSearchResultRow(
            "searchResultRow::Genesis_1_2",
            in: app,
            shouldExist: false,
            timeout: 20
        )

        tapSearchScope(.oldTestament, in: app)
        waitForSearchState(containing: "scope=oldTestament", in: app, timeout: 20)
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

        let searchField = requireSearchInput(in: app, timeout: 10)
        replaceText(in: searchField, with: "earth", placeholderHints: ["Search Bible text", "Search Bible", "Search"])
        dismissSearchFieldFocusIfNeeded(in: app)
        waitForSearchQuery("earth", in: app, timeout: 20)

        waitForSearchSelectedModules(
            in: app,
            timeout: 20,
            description: "exactly KJV before multi-translation commit"
        ) { modules in
            modules == Set(["KJV"])
        }

        tapSearchTranslationPicker(in: app, timeout: 10)
        tapSearchTranslationSelectAll(in: app, timeout: 10)
        tapSearchTranslationCancel(in: app, timeout: 10)
        waitForSearchSelectedModules(
            in: app,
            timeout: 20,
            description: "KJV after cancelling translation-picker draft"
        ) { modules in
            modules == Set(["KJV"])
        }

        tapSearchTranslationPicker(in: app, timeout: 10)
        tapSearchTranslationSelectAll(in: app, timeout: 10)
        tapSearchTranslationOutsideDismiss(in: app, timeout: 10)
        waitForSearchSelectedModules(
            in: app,
            timeout: 20,
            description: "KJV after outside-dismissing translation-picker draft"
        ) { modules in
            modules == Set(["KJV"])
        }

        tapSearchTranslationPicker(in: app, timeout: 10)
        tapSearchTranslationSelectAll(in: app, timeout: 10)
        tapSearchTranslationSelectAll(in: app, timeout: 10)
        tapSearchTranslationOK(in: app, timeout: 10)
        waitForSearchSelectedModules(
            in: app,
            timeout: 20,
            description: "KJV after empty translation-picker OK"
        ) { modules in
            modules == Set(["KJV"])
        }

        tapSearchTranslationPicker(in: app, timeout: 10)
        tapSearchTranslationRow(moduleName: "AATESTWEB", in: app, timeout: 20)
        tapSearchTranslationOK(in: app, timeout: 10)

        waitForSearchSelectedModules(
            in: app,
            timeout: 20,
            description: "more than one module including AATESTWEB"
        ) { modules in
            modules.count > 1 && modules.contains("AATESTWEB")
        }
        waitForSearchState(containing: "selectedModuleOrder=KJV,AATESTWEB", in: app, timeout: 20)
        XCTAssertTrue(
            app.staticTexts["KJV, AATESTWEB"].waitForExistence(timeout: 5),
            "Expected the Search translation button to show Android's selected abbreviation list."
        )
        waitForSearchState(containing: "groupedTotal=1", in: app, timeout: 20)
        waitForSearchState(containing: "groupedHitTotal=2", in: app, timeout: 20)
        waitForSearchState(containing: "KJV:1", in: app, timeout: 20)
        waitForSearchState(containing: "AATESTWEB:1", in: app, timeout: 20)
        waitForSearchResultCount(atLeast: 1, in: app, timeout: 20)

        let groupedResultIdentifier = "searchResultRow::Genesis_1_2"
        let secondaryModuleResultIdentifier = "searchResultModuleRow::Genesis_1_2::AATESTWEB"
        waitForSearchResultRow(groupedResultIdentifier, in: app, shouldExist: true, timeout: 20)
        waitForSearchResultRow(secondaryModuleResultIdentifier, in: app, shouldExist: true, timeout: 20)
        let updatedReference = tapSearchResultRowAndWaitForReaderReferenceChange(
            secondaryModuleResultIdentifier,
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
            updatedReference.localizedCaseInsensitiveContains("Genesis 1:2"),
            "Expected selecting the Search result to navigate to Genesis 1:2, but saw '\(updatedReference)'."
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
