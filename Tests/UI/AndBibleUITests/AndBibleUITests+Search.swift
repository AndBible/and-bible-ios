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
     * route contract: AI Settings remains reachable from the Android reader drawer and reproduces
     * Android's setup-to-connection hierarchy and explicit disclaimer gate;
     * Application Preferences opens the same AI screen; and Global text options opens root-scoped
     * Text Display settings.
     *
     * - Side effects:
     *   - launches the app with deterministic in-memory persistence
     *   - opens AI Settings directly from the reader drawer and pushes Connection settings
     *   - verifies Android's zero-provider row visibility and cancels both protected entry points
     *   - explicitly accepts once, then verifies Quick Setup resumes at provider selection
     *   - verifies persisted acceptance bypasses the gate for Quick Setup and Add Provider
     *   - pushes Settings from the reader action surface
     *   - opens the shared AI Settings destination from Application Preferences
     *   - activates the production Global text options row
     * - Failure modes:
     *   - fails if AI Settings skips Android's centered setup or separate Connection settings screen
     *   - fails if zero-provider Connection settings exposes configured-only rows
     *   - fails if cancellation counts as disclaimer acceptance
     *   - fails if explicit acceptance does not resume and persist for the protected action
     *   - fails if disclaimer copy renders localization identifiers instead of Android's text
     *   - fails if Settings still presents as a sheet instead of a reader destination
     *   - fails if the Android shortcut rows disappear from the Settings state
     *   - fails if Global text options opens any scope other than `global`
     */
    func testSettingsApplicationShortcutsOpenGlobalTextOptions() {
        let app = makeApp()
        app.launch()

        tapReaderAction("readerOpenAISettingsAction", in: app, timeout: 20)
        XCTAssertTrue(requireElement("aiSettingsTopAppBarBackButton", in: app, timeout: 20).exists)
        waitForReaderRenderedContentState(containing: "readerDestination=aiSettings", in: app, timeout: 10)
        XCTAssertTrue(
            app.staticTexts["Configure AI"].waitForExistence(timeout: 10),
            "Expected Android's centered Configure AI state before any provider exists."
        )
        XCTAssertTrue(requireElement("aiConfigureConnectionButton", in: app, timeout: 10).exists)
        XCTAssertFalse(unresolvedElement("aiQuickSetupButton", in: app).exists)
        XCTAssertFalse(unresolvedElement("aiAddProviderLink", in: app).exists)

        tapElementReliably(requireElement("aiConfigureConnectionButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("aiQuickSetupButton", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("aiProvidersLink", in: app, timeout: 10).exists)
        XCTAssertFalse(
            unresolvedElement("aiModelsLink", in: app).exists,
            "Android hides Models, Behavior, Advanced, and Usage until a provider exists."
        )

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
        XCTAssertFalse(
            unresolvedElement("aiQuickSetupButton", in: app).isHittable,
            "Android's modal disclaimer must block the underlying Quick Setup row."
        )
        XCTAssertFalse(
            requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).isHittable,
            "Android's modal disclaimer must block the underlying app-owned action bar."
        )
        tapElementReliably(requireElement("aiDisclaimerCancelButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("aiProvidersLink", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiProvidersTopAppBarBackButton", in: app, timeout: 10).exists)
        tapElementReliably(requireElement("aiAddProviderLink", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(
            requireElement("aiDisclaimerScreen", in: app, timeout: 10).exists,
            "Add Provider must use Android's same explicit disclaimer gate."
        )
        tapElementReliably(requireElement("aiDisclaimerCancelButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiProvidersTopAppBarBackButton", in: app, timeout: 10).exists)
        tapElementReliably(
            requireElement("aiProvidersTopAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("aiQuickSetupButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(
            requireElement("aiDisclaimerScreen", in: app, timeout: 10).exists,
            "Cancelling the disclaimer must not count as acceptance."
        )
        let disclaimerScrollView = app.scrollViews["aiDisclaimerScrollView"].firstMatch
        XCTAssertTrue(
            disclaimerScrollView.waitForExistence(timeout: 10),
            "Expected the app-owned disclaimer's visible scroll container."
        )
        let disclaimerAcceptButton = requireElement("aiDisclaimerAcceptButton", in: app, timeout: 10)
        for _ in 0..<8 where !disclaimerAcceptButton.isHittable {
            disclaimerScrollView.swipeUp()
        }
        XCTAssertTrue(
            disclaimerAcceptButton.isHittable,
            "Expected the full Android disclaimer to scroll to its explicit acceptance action."
        )
        tapElementReliably(disclaimerAcceptButton, timeout: 10)
        XCTAssertTrue(
            requireElement("aiQuickSetupProvider_GEMINI", in: app, timeout: 10).exists,
            "Explicit acceptance must resume Android's Quick Setup provider chooser."
        )
        tapElementReliably(requireElement("aiQuickSetupProvider_GEMINI", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiQuickSetupCredentialScreen", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("aiQuickSetupSaveButton", in: app, timeout: 10).exists)
        tapElementReliably(requireElement("aiQuickSetupCancelButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("aiQuickSetupButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(
            requireElement("aiQuickSetupProvider_GEMINI", in: app, timeout: 10).exists,
            "Persisted acceptance must bypass the disclaimer on later protected actions."
        )
        XCTAssertFalse(unresolvedElement("aiDisclaimerScreen", in: app).exists)
        tapElementReliably(requireElement("aiQuickSetupCancelButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("aiProvidersLink", in: app, timeout: 10), timeout: 10)
        tapElementReliably(requireElement("aiAddProviderLink", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiProviderTypeSelectionScreen", in: app, timeout: 10).exists)
        XCTAssertFalse(unresolvedElement("aiDisclaimerScreen", in: app).exists)
        tapElementReliably(requireElement("aiProviderType_GEMINI", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(
            requireElement("aiProviderSaveButton", in: app, timeout: 10).exists,
            "Persisted acceptance must resume Add Provider without another disclaimer."
        )
        tapElementReliably(requireElement("aiProviderCancelButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("aiProvidersTopAppBarBackButton", in: app, timeout: 10).exists)
        tapElementReliably(
            requireElement("aiProvidersTopAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10).exists)
        tapElementReliably(
            requireElement("aiConnectionSettingsTopAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        let aiSettingsBackButton = requireElement("aiSettingsTopAppBarBackButton", in: app, timeout: 10)
        tapElementReliably(aiSettingsBackButton, timeout: 10)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected AI Settings back navigation to return to the reader shell."
        )

        openSettings(in: app)
        XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)
        waitForReaderRenderedContentState(containing: "readerModal=none", in: app, timeout: 10)
        waitForReaderRenderedContentState(containing: "readerDestination=settings", in: app, timeout: 10)
        waitForSettingsState(containing: "settingsGlobalTextOptionsLink", in: app, timeout: 10)
        waitForSettingsState(containing: "settingsSyncLink", in: app, timeout: 10)
        waitForSettingsState(containing: "settingsAISettingsLink", in: app, timeout: 10)
        waitForSettingsState(containing: "settingsReadingProgressLink", in: app, timeout: 10)
        waitForSettingsState(containing: "adminFlows=readerActions", in: app, timeout: 10)

        tapSettingsElement("settingsAISettingsLink", in: app, timeout: 20)
        let nestedAISettingsBackButton = requireElement(
            "aiSettingsTopAppBarBackButton",
            in: app,
            timeout: 20
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
        waitForReaderRenderedContentState(containing: "readerModal=none", in: app, timeout: 10)
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
        tapAppOwnedDialogAction(
            "colorSettingsResetDialogAction::yes",
            dialogIdentifier: "colorSettingsResetDialog",
            expectedTitle: "Yes",
            in: app,
            timeout: 10
        )
        waitForElementValue("colorSettingsScreen", toEqual: "colorDefaults", in: app, timeout: 10)

        let colorSettingsBackButton = requireElement(
            "colorSettingsTopAppBarBackButton",
            in: app,
            timeout: 10
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
    Verifies Android's per-window Text Options route, parent-link back stack, and pane Close action.

    Android's pane/window menu owns both per-window Text Options and Close. These are distinct
    commands, but both require the same setup: create a second reader pane, open that pane's
    hamburger menu, and exercise a pane-scoped command. Android's single-top
    `TextDisplaySettingsActivity` pushes each parent scope onto its internal bundle stack, so Back
    from workspace scope must first restore window scope before a second Back returns to the reader.
    Keeping both commands in one workflow removes a duplicate cold launch while preserving that
    visible scope ladder and the pane-delete transaction.
     *
     * - Side effects:
     *   - launches the app, creates a second reader window through the tab bar, and opens the
     *     active pane hamburger menu
     *   - activates the pane-level All text options command
     *   - taps the workspace parent link from the window-scoped Text Display screen
     *   - navigates Back through window scope to the reader, reopens the same pane menu, and
     *     activates Close
     * - Failure modes:
     *   - fails if pane All text options routes to workspace/global scope
     *   - fails if window scope lacks either Android parent link
     *   - fails if the workspace parent link does not navigate to `scope=workspace`
     *   - fails if Back skips or cannot restore the preceding `scope=window` activity
     *   - fails if pane-menu Close terminates the app, leaves the deleted tab visible, or removes
     *     the remaining pane menu/add-window affordances
     */
    func testPaneAllTextOptionsOpensWindowScopeAndWorkspaceParentLink() {
        let app = makeApp()
        app.launch()

        addWindowTab(expectingOrder: 1, in: app, timeout: 15)
        let paneMenu = requireElement("windowPaneMenuButton::1", in: app, timeout: 10)
        openPaneMenu(paneMenu, in: app, timeout: 10)
        let allTextOptionsAction = requirePaneMenuItem("windowPaneMenuItem::allTextOptions", in: app, timeout: 10)
        tapElementReliably(allTextOptionsAction, timeout: 10)

        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=window", in: app, timeout: 10)
        let workspaceLink = requireElement("textDisplayOpenWorkspaceSettingsButton", in: app, timeout: 10)
        XCTAssertTrue(requireElement("textDisplayOpenGlobalSettingsButton", in: app, timeout: 10).exists)

        tapElementReliably(workspaceLink, timeout: 10)
        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=workspace", in: app, timeout: 10)
        XCTAssertFalse(unresolvedElement("textDisplayOpenWorkspaceSettingsButton", in: app).exists)
        XCTAssertTrue(requireElement("textDisplayOpenGlobalSettingsButton", in: app, timeout: 10).exists)

        tapElementReliably(
            requireElement("textDisplaySettingsTopAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        waitForElementValue("textDisplaySettingsScreen", toContain: "scope=window", in: app, timeout: 10)
        XCTAssertTrue(requireElement("textDisplayOpenWorkspaceSettingsButton", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("textDisplayOpenGlobalSettingsButton", in: app, timeout: 10).exists)

        tapElementReliably(
            requireElement("textDisplaySettingsTopAppBarBackButton", in: app, timeout: 10),
            timeout: 10
        )
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected app-owned Text Options back navigation to return to the reader shell before closing the pane."
        )
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
     Verifies Search and SearchResults remain distinct app-owned activities and navigate to reader.
     *
     * Exact Android search semantics for scope filters and word modes are covered in
     * `SearchIndexServiceQueryTests`. This UI smoke stays focused on the live Search surface:
     * Search must open as an Android-style reader destination rather than an iOS sheet, preserve
     * the launch-seeded query, expose tappable scope and word-mode rows, retain criteria while
     * SearchResults is open, and execute changes only through Android's explicit Search command.
     * The same live Search route then
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
     *   - returns from SearchResults before each scope/word-mode change and explicitly resubmits
     *   - enters a deterministic fixture query, exercises negative Search translation-picker
     *     dialog paths, commits the seeded two-module translation selection from Search Results,
     *     verifies Android's immediate result refresh, and taps its visible AATESTWEB result row
     * - Failure modes:
     *   - fails if Search regresses to sheet/modal presentation or drops the launch-seeded query
     *   - fails if visible Search option controls are not accessible
     *   - fails if scope or word-mode changes do not remain in criteria until explicit submission
     *   - fails if each submission does not open the separate SearchResults activity
     *   - fails if live translation-picker Cancel, outside-dismiss, or empty OK commits draft
     *     changes instead of preserving the previous selection
     *   - fails if the translation picker cannot commit a second module with KJV first or refresh
     *     Search Results in place as Android does
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

        returnToSearchCriteria(in: app)
        tapSearchScope(.newTestament, in: app)
        waitForSearchState(containing: "scope=newTestament", in: app, timeout: 20)
        waitForSearchState(containing: "stage=criteria", in: app, timeout: 20)
        submitSearchCriteria(in: app)
        waitForSearchResultRow(
            "searchResultRow::Genesis_1_2",
            in: app,
            shouldExist: false,
            timeout: 20
        )

        returnToSearchCriteria(in: app)
        tapSearchScope(.oldTestament, in: app)
        waitForSearchState(containing: "scope=oldTestament", in: app, timeout: 20)
        waitForSearchState(containing: "stage=criteria", in: app, timeout: 20)
        submitSearchCriteria(in: app)
        waitForSearchResultRow("searchResultRow::Genesis_1_2", in: app, shouldExist: true, timeout: 20)

        returnToSearchCriteria(in: app)
        tapSearchWordMode("Phrase", in: app, timeout: 10)
        waitForSearchState(containing: "wordMode=phrase", in: app, timeout: 20)
        waitForSearchState(containing: "stage=criteria", in: app, timeout: 20)
        submitSearchCriteria(in: app)
        waitForSearchResultRow(
            "searchResultRow::Genesis_1_2",
            in: app,
            shouldExist: false,
            timeout: 20
        )

        returnToSearchCriteria(in: app)
        tapSearchWordMode("Any Word", in: app, timeout: 10)
        waitForSearchState(containing: "wordMode=anyWord", in: app, timeout: 20)
        waitForSearchState(containing: "stage=criteria", in: app, timeout: 20)
        submitSearchCriteria(in: app)
        waitForSearchResultRow("searchResultRow::Genesis_1_2", in: app, shouldExist: true, timeout: 20)

        returnToSearchCriteria(in: app)
        let searchField = requireSearchInput(in: app, timeout: 10)
        replaceText(in: searchField, with: "earth", placeholderHints: ["Search Bible text", "Search Bible", "Search"])
        waitForSearchQuery("earth", in: app, timeout: 20)
        submitSearchCriteria(in: app)
        waitForSearchState(containing: "stage=results", in: app, timeout: 20)

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
        waitForSearchState(containing: "stage=results", in: app, timeout: 20)
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
     Reproduces a two-document scripture switch directly from Android's reader toolbar shortcut.

     The custom-theme fixture installs KJV and AATESTWEB, which makes the toolbar's two-document
     action switch immediately instead of opening a picker. Its distinct global, workspace, and
     window palettes expose an inheritance fallback that default day colors would conceal. Keeping
     this path separate from Search and Choose Document isolates reader content/theme reloading from
     destination-pop animations.

     - Side effects:
       - launches the deterministic two-Bible fixture with scoped custom colors in day mode
       - taps the production Bible toolbar action once
       - waits for the alternate Bible to become the rendered pane document
     - Failure modes:
       - fails if the fixture does not start on KJV
       - fails if the toolbar shortcut cannot switch to AATESTWEB
       - fails if either side of the switch loses the window-scoped day background
       - the app-host bridge contract separately rejects any paint boundary between clear and config
     */
    func testReaderQuickScriptureSwitchPreservesDayTheme() {
        let app = makeApp()
        app.launch()
        let expectedBackground = Int(Int32(bitPattern: 0xFFDDE7FA))

        waitForReaderRenderedContentState(containing: "category=bible;module=KJV", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "nightMode=false", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )

        tapElementReliably(
            requireElement("readerBibleToolbarButton", in: app, timeout: 20),
            timeout: 20
        )

        waitForReaderRenderedContentState(
            containing: "category=bible;module=AATESTWEB",
            in: app,
            timeout: 20
        )
        waitForReaderRenderedContentState(containing: "nightMode=false", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )
    }

    /**
     Verifies Android's fixed-dark passage chooser cannot mutate a System/day reader into night mode.

     The fixture explicitly selects System night mode, seeds visibly different day/night window
     colors, and launches the simulator in light appearance. Android presents its chooser in a
     separately themed activity with theme changes disabled; the iOS chooser must likewise scope
     dark styling to its own subtree instead of emitting a window-wide preferred color scheme.

     - Side effects:
       - launches the custom-theme fixture in explicit System/day mode
       - opens the production passage chooser and observes reader state while it remains presented
       - selects Genesis 2 and waits for the destination pop to finish
     - Failure modes:
       - fails if opening the chooser changes `nightMode` to true or selects the night background
       - fails if choosing Genesis 2 does not return to the same day-themed reader
       - fails if the reader state export becomes unavailable while the chooser is presented
     - Note: The negative observation spans the stable open chooser, where the former feedback loop
       held night mode true; it does not depend on sampling a single animation frame.
     */
    func testPassageChooserPreservesSystemDayTheme() {
        let app = makeApp()
        app.launch()
        let expectedBackground = Int(Int32(bitPattern: 0xFFDDE7FA))
        let unexpectedNightBackground = Int(Int32(bitPattern: 0xFF2B183C))

        waitForReaderRenderedContentState(containing: "nightMode=false", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )

        tapElementReliably(
            requireElement("bookChooserButton", in: app, timeout: 20),
            timeout: 20
        )
        XCTAssertTrue(requireElement("passageChooserScreen", in: app, timeout: 20).exists)
        let chooserReaderState = app.staticTexts["readerRenderedContentState"].firstMatch
        XCTAssertTrue(
            chooserReaderState.waitForExistence(timeout: 5),
            "Expected the chooser destination's reader-state export to remain available."
        )
        let expectedDayState = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value CONTAINS %@ AND value CONTAINS %@ AND value CONTAINS %@",
                "readerDestination=passageChooser",
                "nightMode=false",
                "readerBackground=\(expectedBackground)"
            ),
            object: chooserReaderState
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectedDayState], timeout: 5),
            .completed,
            "Expected the open chooser to retain the System/day reader state."
        )
        let unexpectedNightState = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value CONTAINS %@ OR value CONTAINS %@",
                "nightMode=true",
                "readerBackground=\(unexpectedNightBackground)"
            ),
            object: chooserReaderState
        )
        unexpectedNightState.isInverted = true
        XCTAssertEqual(
            XCTWaiter.wait(for: [unexpectedNightState], timeout: 1.5),
            .completed,
            "The fixed-dark chooser must not be interpreted as a dark system appearance."
        )

        tapElementReliably(
            app.buttons["passageBookCell.Gen"].firstMatch,
            timeout: 20
        )
        tapElementReliably(
            app.buttons["passageChapterCell.2"].firstMatch,
            timeout: 20
        )

        waitForReaderRenderedContentState(
            containing: "readerDestination=none",
            in: app,
            timeout: 20
        )
        waitForReaderRenderedContentState(containing: "nightMode=false", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )
        XCTAssertTrue(
            requireReaderReferenceValue(in: app, timeout: 20)
                .localizedCaseInsensitiveContains("Genesis 2"),
            "Expected passage selection to return to Genesis 2 in the original reader."
        )
    }

    /**
     Reproduces scripture replacement through Android's full Choose Document activity.

     This is the reported regression path: the current custom day-themed reader opens the app-owned
     document chooser, activates another installed Bible, and returns through the same reader stack.
     Global, workspace, and window fixtures use different colors, so recordings distinguish a lost
     window override from a mode change or application-default fallback. It complements the toolbar
     test so a failure can be attributed to destination dismissal or to the shared controller reload.

     - Side effects:
       - launches KJV/AATESTWEB with distinct global/workspace/window palettes in day mode
       - opens Choose Document through the production reader action
       - filters and selects AATESTWEB, then waits for the reader destination to close
     - Failure modes:
       - fails if Choose Document cannot open or expose the seeded module
       - fails if selection does not render AATESTWEB in the original pane
       - fails if the night policy or resolved window-scoped day background changes
     */
    func testDocumentChooserScriptureSwitchPreservesDayTheme() {
        let app = makeApp()
        app.launch()
        let expectedBackground = Int(Int32(bitPattern: 0xFFDDE7FA))

        waitForReaderRenderedContentState(containing: "category=bible;module=KJV", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "nightMode=false", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )

        tapReaderAction("readerChooseDocumentAction", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerDestination=chooseDocument",
            in: app,
            timeout: 20
        )
        let searchField = requireElement("modulePickerSearchField", in: app, timeout: 20)
        replaceText(in: searchField, with: "AATESTWEB", placeholderHints: ["Search"])
        tapElementReliably(
            requireElement("modulePickerRow::AATESTWEB", in: app, timeout: 20),
            timeout: 20
        )

        waitForReaderRenderedContentState(
            containing: "category=bible;module=AATESTWEB",
            in: app,
            timeout: 20
        )
        waitForReaderRenderedContentState(containing: "readerDestination=none", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "nightMode=false", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )
    }

    /**
     Reproduces scripture replacement while a non-default night palette is active.

     The fixture's window-scoped purple night background differs from its workspace blue, global
     blue-black, and Vue default black. That distinction catches a transient inheritance fallback
     even when the Boolean night-mode policy itself remains unchanged.

     - Side effects:
       - launches the deterministic KJV/AATESTWEB fixture in manual night mode
       - opens Choose Document, filters to AATESTWEB, and activates that Bible
       - returns to the reader with the configured night policy still active
     - Failure modes:
       - fails if the custom-night fixture does not start on KJV in night mode
       - fails if selection does not render AATESTWEB in the original pane
       - fails if either side of the switch loses the window-scoped night background
       - the app-host bridge contract separately rejects any paint boundary between clear and config
     */
    func testDocumentChooserScriptureSwitchPreservesCustomNightTheme() {
        let app = makeApp()
        app.launch()
        let expectedBackground = Int(Int32(bitPattern: 0xFF2B183C))

        waitForReaderRenderedContentState(containing: "category=bible;module=KJV", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "nightMode=true", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
        )

        tapReaderAction("readerChooseDocumentAction", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerDestination=chooseDocument",
            in: app,
            timeout: 20
        )
        let searchField = requireElement("modulePickerSearchField", in: app, timeout: 20)
        replaceText(in: searchField, with: "AATESTWEB", placeholderHints: ["Search"])
        tapElementReliably(
            requireElement("modulePickerRow::AATESTWEB", in: app, timeout: 20),
            timeout: 20
        )

        waitForReaderRenderedContentState(
            containing: "category=bible;module=AATESTWEB",
            in: app,
            timeout: 20
        )
        waitForReaderRenderedContentState(containing: "readerDestination=none", in: app, timeout: 20)
        waitForReaderRenderedContentState(containing: "nightMode=true", in: app, timeout: 20)
        waitForReaderRenderedContentState(
            containing: "readerBackground=\(expectedBackground)",
            in: app,
            timeout: 20
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
