import Foundation
import Darwin
import XCTest

/**
 UI smoke tests for the core iPhone navigation shell.

 Data dependencies:
 - launches the production AndBible app target under XCUITest
 - relies on stable accessibility identifiers exposed by the reader overflow menu and settings form

 Side effects:
 - boots the app in a simulator-hosted UI automation session
 - opens the reader overflow menu and drives settings navigation

 Failure modes:
 - fails when the app no longer reaches the reader shell on launch
 - fails when the documented accessibility identifiers drift without coordinated test updates

 Concurrency:
 - runs on XCTest's serialized UI automation thread
 */
final class AndBibleUITests: XCTestCase {
    /// Tracks the currently launched app so each test can end with a deterministic teardown.
    private var trackedApp: XCUIApplication?

    /**
     Configures each UI test for fail-fast execution.
     *
     * - Side effects:
     *   - disables XCTest's continue-after-failure behavior for the current test method
     * - Failure modes: This override cannot fail.
     */
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /**
     Tears down the currently running UI-test app process after each test method.
     *
     * - Side effects:
     *   - terminates the tracked app when it is still running so the next test gets a clean launch
     *   - clears the stored app handle for the completed test method
     * - Failure modes:
     *   - silently ignores already-stopped app processes because termination is only cleanup
     */
    override func tearDownWithError() throws {
        if let trackedApp, trackedApp.state != .notRunning {
            _ = terminateAppReliably(trackedApp)
        }
        trackedApp = nil
    }

    /**
     Verifies that the reader overflow menu exposes its primary actions and that Settings can be
     opened from the reader shell.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled, in-memory persistence, and one
     *     deterministic seeded bookmark-label pair for stable reader-shell startup
     *   - opens the reader overflow menu, validates the primary overflow rows, dismisses the menu,
     *     and pushes the settings screen
     * - Failure modes:
     *   - fails if any primary overflow-menu action is absent
     *   - fails if settings cannot be reached from the reader shell
     *   - fails if the settings form does not render after navigation completes
     */
    func testSettingsScreenShowsPrimaryNavigationRows() {
        let app = makeApp()
        app.launch()

        tapReaderMoreMenuButton(in: app)
        XCTAssertTrue(requireElement("readerOverflowSectionTitlesToggle", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("readerOverflowStrongsModeAction", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("readerOverflowVerseNumbersToggle", in: app, timeout: 10).exists)
        dismissReaderOverflowMenu(in: app, timeout: 15)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected overflow dismissal to restore the reader shell before opening Settings."
        )

        openSettings(in: app)
        XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)
        waitForSettingsState(containing: "settingsImportExportLink", in: app, timeout: 10)
        waitForSettingsState(containing: "settingsSyncLink", in: app, timeout: 10)
        waitForSettingsState(containing: "settingsLabelsLink", in: app, timeout: 10)
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

        let noahResult = requireElement("searchResultRow::Genesis_6_8", in: app, timeout: 20)
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
        XCTAssertTrue(requireElement("searchQueryField", in: app, timeout: 5).exists)
        waitForSearchState(containing: "query=H00430", in: app, timeout: 20)
        waitForSearchResultCount(atLeast: 1, in: app, timeout: 20)
    }

    /**
     Verifies that an active reading plan can advance from day one to day two.
     *
     * - Side effects:
     *   - launches the app with one seeded active plan and existing plans reset for determinism
     *   - opens that seeded plan through the dedicated UI-test daily-reading route
     *   - marks day one complete and waits for the daily-reading state to advance to day two
     * - Failure modes:
     *   - fails if the seeded daily-reading screen never appears
     *   - fails if the day label or mark-as-read control is missing
     *   - fails if marking day one complete does not advance the daily-reading state to day two
     */
    func testReadingPlansStartPlanAndAdvanceDay() {
        let app = makeApp()
        app.launch()

        tapReaderAction("readerOpenReadingPlansAction", in: app)
        XCTAssertTrue(requireElement("readingPlanListScreen", in: app, timeout: 15).exists)
        tapElementReliably(requireElement("readingPlanStartButton", in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireElement("availablePlansScreen", in: app, timeout: 10).exists)
        tapElementReliably(requireElement("readingPlanTemplateButton", in: app, timeout: 15), timeout: 10)
        XCTAssertTrue(requireElement("readingPlanListScreen", in: app, timeout: 15).exists)
        tapElementReliably(requireElement("readingPlanActivePlanLink", in: app, timeout: 15), timeout: 10)
        let currentDay = requireElement("dailyReadingCurrentDayLabel", in: app, timeout: 15)
        XCTAssertEqual(currentDay.value as? String, "1")

        tapElementReliably(
            requireElement("dailyReadingMarkAsReadButton", in: app, timeout: 10),
            timeout: 10
        )

        let advancedDayPredicate = NSPredicate(format: "value == %@", "2")
        expectation(for: advancedDayPredicate, evaluatedWith: currentDay)
        waitForExpectations(timeout: 20)
    }

    /**
     Verifies that the downloads browser can be opened from the reader shell.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled, in-memory persistence, and one
     *     deterministic seeded bookmark-label pair for stable reader-shell startup
     *   - opens the reader overflow menu and pushes the downloads browser
     * - Failure modes:
     *   - fails if the downloads action is missing from the reader menu
     *   - fails if the downloads browser screen does not render after navigation completes
     */
    func testDownloadsScreenOpensFromReaderMenu() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openDownloads(in: app).exists)
    }

    /**
     Verifies that the downloads browser can open the repository manager and dismiss the add-source
     sheet back to the repository list.
     *
     * - Side effects:
     *   - launches directly into Downloads
     *   - opens the repository manager from the real downloads toolbar button
     *   - opens the add-source sheet and cancels it
     * - Failure modes:
     *   - fails if the downloads browser or repository manager never appears
     *   - fails if the add-source sheet cannot be presented from the repository manager
     *   - fails if cancelling the add-source sheet does not return to the repository manager
     */
    func testDownloadsRepositoryManagerAddSourceCancelFlow() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openDownloads(in: app).exists)
        tapElementReliably(
            requireElement("moduleBrowserRepositoriesButton", in: app, timeout: 10),
            timeout: 15
        )

        XCTAssertTrue(requireElement("repositoryManagerScreen", in: app, timeout: 20).exists)
        tapElementReliably(
            requireElement("repositoryManagerAddButton", in: app, timeout: 10),
            timeout: 10
        )

        XCTAssertTrue(requireElement("repositoryManagerAddSourceScreen", in: app, timeout: 20).exists)
        tapElementReliably(
            requireElement("repositoryManagerAddSourceCancelButton", in: app, timeout: 10),
            timeout: 10
        )

        XCTAssertTrue(requireElement("repositoryManagerScreen", in: app, timeout: 20).exists)
    }

    /**
     Verifies that the workspace selector can create a workspace, make it active, and switch back.
     *
     * Rename, clone, and delete semantics are covered by `WorkspaceStore` unit tests because the
     * production UI exposes those actions through long-press context menus that are pathologically
     * slow under hosted XCTest.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens the workspace selector from the reader
     *     menu
     *   - creates one workspace, verifies it becomes active, then switches back to the original
     *     active workspace
     * - Failure modes:
     *   - fails if the workspace selector never appears
     *   - fails if the create alert, workspace rows, or active-workspace state do not update as
     *     expected
     */
    func testWorkspaceSelectorCreateAndSwitchFlow() {
        let app = makeApp()
        let createdName = "W1"
        app.launch()

        XCTAssertTrue(openWorkspaceSelector(in: app).exists)
        let originalActiveWorkspaceName = requireActiveWorkspaceRow(in: app, timeout: 10).label

        tapElementReliably(requireElement("workspaceSelectorAddButton", in: app, timeout: 10), timeout: 10)
        replaceText(in: requireAlertTextField(in: app, timeout: 10), with: createdName)
        tapAlertButton("Create", in: app, timeout: 10)

        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected creating a workspace to return to the reader shell."
        )

        _ = openWorkspaceSelector(in: app)
        _ = requireWorkspaceRow(named: createdName, in: app, timeout: 15)
        XCTAssertEqual(
            requireActiveWorkspaceRow(in: app, timeout: 10).label,
            createdName,
            "Expected the new workspace to become active after creation."
        )

        tapElementReliably(
            requireWorkspaceRow(named: originalActiveWorkspaceName, in: app, timeout: 10),
            timeout: 10
        )
        dismissAlertIfPresent(in: app, timeout: 5)
        dismissWorkspaceSelectorIfStillPresented(in: app, timeout: 20)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected switching workspaces to return to the reader shell."
        )
    }

    /**
     Verifies that the bookmark list can be opened from the reader shell.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled, in-memory persistence, and one
     *     deterministic seeded bookmark-label pair for stable reader-shell startup
     *   - opens the reader overflow menu and pushes the bookmark list
     * - Failure modes:
     *   - fails if the bookmarks action is missing from the reader menu
     *   - fails if the bookmark list screen does not render after navigation completes
     */
    func testBookmarksScreenOpensFromReaderMenu() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openBookmarkList(in: app).exists)
    }

    /**
     Verifies that selecting a seeded bookmark row dismisses the list and navigates the reader to
     that bookmark's chapter.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic `Exodus 2:1` bookmark while the reader
     *     itself stays on `Genesis 1`
     *   - opens the bookmark list from the actual reader overflow menu
     *   - taps the seeded bookmark row and waits for the visible reader reference to reach
     *     `Exodus 2`
     * - Failure modes:
     *   - fails if the bookmark list or seeded bookmark row never appears
     *   - fails if tapping the seeded bookmark row does not drive the reader to `Exodus 2`
     */
    func testBookmarkSelectionNavigatesReaderToSeededReference() {
        let app = makeApp()
        app.launch()

        let initialReference = requireReaderReferenceValue(in: app, timeout: 20)
        XCTAssertTrue(
            initialReference.localizedCaseInsensitiveContains("Genesis 1"),
            "Expected the seeded bookmark-navigation scenario to start on Genesis 1, but saw '\(initialReference)'."
        )

        _ = openBookmarkList(in: app)
        let bookmarkRow = requireBookmarkRow("Exodus_2_1", in: app, timeout: 10)
        tapElementReliably(bookmarkRow, timeout: 10)
        let updatedReference = waitForReaderReferenceValueToChange(
            from: initialReference,
            in: app,
            timeout: 20
        )
        XCTAssertTrue(
            updatedReference.localizedCaseInsensitiveContains("Exodus 2"),
            "Expected selecting the seeded bookmark to navigate to Exodus 2, but saw '\(updatedReference)'."
        )
    }

    /**
     Verifies that bookmark navigation from a third window updates only that pane's rendered content.
     *
     * - Side effects:
     *   - launches the seeded bookmark-navigation fixture on the reader shell
     *   - creates two additional windows, activates the third one, opens the bookmark list from
     *     that pane, and selects the seeded `Exodus 2:1` row
     *   - switches back to the first window to confirm its rendered content stayed on `Genesis 1`
     * - Failure modes:
     *   - fails if the extra windows cannot be created or activated
     *   - fails if the third window does not render `Exodus 2`
     *   - fails if the first window's rendered content also changes away from `Genesis 1`
     */
    func testThirdWindowBookmarkNavigationUpdatesOnlyTargetPaneContent() {
        let app = makeApp()
        app.launch()

        waitForReaderRenderedContentState(
            containing: "windowOrder=0;category=bible;module=KJV;book=Genesis;chapter=1",
            in: app,
            timeout: 20
        )

        tapElementReliably(requireElement("windowTabAddButton", in: app, timeout: 10), timeout: 10)
        _ = requireElement("windowTabButton::1", in: app, timeout: 10)
        tapElementReliably(requireElement("windowTabAddButton", in: app, timeout: 10), timeout: 10)
        _ = requireElement("windowTabButton::2", in: app, timeout: 10)

        tapWindowTab(2, in: app, timeout: 10)
        waitForReaderRenderedContentState(
            containing: "windowOrder=2;category=bible;module=KJV;book=Genesis;chapter=1",
            in: app,
            timeout: 20
        )

        _ = openBookmarkList(in: app)
        tapElementReliably(requireBookmarkRow("Exodus_2_1", in: app, timeout: 10), timeout: 10)
        waitForReaderRenderedContentState(
            containing: "windowOrder=2;category=bible;module=KJV;book=Exodus;chapter=2",
            in: app,
            timeout: 20
        )

        tapWindowTab(0, in: app, timeout: 10)
        waitForReaderRenderedContentState(
            containing: "windowOrder=0;category=bible;module=KJV;book=Genesis;chapter=1",
            in: app,
            timeout: 20
        )
    }

    /**
     Verifies that a third-window document-type switch updates that pane's content instead of only
     mutating tab chrome.
     *
     * - Side effects:
     *   - launches the baseline reader shell, creates two additional windows, and activates the
     *     third one
     *   - switches that third pane into commentary and then back into Bible using the real toolbar
     *     document controls and, when needed, the real module picker
     *   - switches back to the first tab to confirm its rendered content never left `Genesis 1`
     * - Failure modes:
     *   - fails if the third window cannot be activated
     *   - fails if the third pane never reports `category=commentary` and then `category=bible`
     *   - fails if the first pane's rendered content drifts while the third pane is changing modes
     */
    func testThirdWindowDocumentSwitchUpdatesOnlyTargetPaneContent() {
        let app = makeApp()
        app.launch()

        waitForReaderRenderedContentState(
            containing: "windowOrder=0;category=bible;module=KJV;book=Genesis;chapter=1",
            in: app,
            timeout: 20
        )

        tapElementReliably(requireElement("windowTabAddButton", in: app, timeout: 10), timeout: 10)
        _ = requireElement("windowTabButton::1", in: app, timeout: 10)
        tapElementReliably(requireElement("windowTabAddButton", in: app, timeout: 10), timeout: 10)
        _ = requireElement("windowTabButton::2", in: app, timeout: 10)

        tapWindowTab(2, in: app, timeout: 10)
        waitForReaderRenderedContentState(
            containing: "windowOrder=2;category=bible",
            in: app,
            timeout: 20
        )

        tapElementReliably(requireElement("readerCommentaryToolbarButton", in: app, timeout: 10), timeout: 10)
        if waitForAnyElement(["modulePickerScreen"], in: app, timeout: 3) != nil {
            tapFirstModulePickerRow(in: app, timeout: 10)
        }
        waitForReaderRenderedContentState(
            containing: "windowOrder=2;category=commentary",
            in: app,
            timeout: 20
        )

        tapElementReliably(requireElement("readerBibleToolbarButton", in: app, timeout: 10), timeout: 10)
        if waitForAnyElement(["modulePickerScreen"], in: app, timeout: 3) != nil {
            if let kjvRow = resolvedElement("modulePickerRow::KJV", in: app) {
                tapElementReliably(kjvRow, timeout: 10)
            } else {
                tapFirstModulePickerRow(in: app, timeout: 10)
            }
        }
        waitForReaderRenderedContentState(
            containing: "windowOrder=2;category=bible",
            in: app,
            timeout: 20
        )

        tapWindowTab(0, in: app, timeout: 10)
        waitForReaderRenderedContentState(
            containing: "windowOrder=0;category=bible;module=KJV;book=Genesis;chapter=1",
            in: app,
            timeout: 20
        )
    }

    /**
     Verifies that deleting one bookmark row from the real bookmark list leaves other bookmarks
     intact across reopen.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic `Exodus 2:1` and `Matthew 3:1` bookmarks
     *   - opens the real bookmark list from the reader overflow menu
     *   - deletes only the Exodus row through the row-level swipe action, dismisses the screen,
     *     and reopens the list to confirm the Matthew row persists
     * - Failure modes:
     *   - fails if the bookmark list or either seeded bookmark row never appears
     *   - fails if the row-level delete action is missing for the Exodus bookmark
     *   - fails if deleting the Exodus row also removes the Matthew row or if the Exodus row
     *     returns after reopening the bookmark list
     */
    func testBookmarkRowDeletePreservesOtherRowsAcrossReopen() {
        let app = makeApp()
        app.launch()

        _ = openBookmarkList(in: app)
        let exodusRow = requireBookmarkRow("Exodus_2_1", in: app, timeout: 10)
        _ = requireBookmarkRow("Matthew_3_1", in: app, timeout: 10)

        exodusRow.swipeLeft()
        requireElement("bookmarkListDeleteButton::Exodus_2_1", in: app, timeout: 10).tap()

        waitForBookmarkListState(containing: "count=1", in: app, timeout: 10)
        waitForBookmarkListState(notContaining: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Matthew_3_1"), in: app, timeout: 10)

        reopenBookmarkList(in: app)
        waitForBookmarkListState(containing: "count=1", in: app, timeout: 10)
        waitForBookmarkListState(notContaining: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Matthew_3_1"), in: app, timeout: 10)
    }

    /**
     Verifies that changing the bookmark-list sort menu reorders the visible rows.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic `Exodus 2:1` and `Matthew 3:1` bookmarks
     *   - opens the real bookmark list from the reader overflow menu
     *   - verifies the default `Date created` ordering, opens the real sort menu, selects `Bible
     *     order`, and waits for the visible row order to update
     * - Failure modes:
     *   - fails if the bookmark list, sort menu, or `Bible order` option never appears
     *   - fails if the default row order does not match the seeded creation order
     *   - fails if selecting `Bible order` does not move the Exodus row above the Matthew row
     */
    func testBookmarkListSortMenuReordersRows() {
        let app = makeApp()
        app.launch()

        _ = openBookmarkList(in: app)
        waitForElement(
            "bookmarkListRowButton::Matthew_3_1",
            toAppearAbove: "bookmarkListRowButton::Exodus_2_1",
            in: app
        )

        sortBookmarkListByBibleOrder(in: app)

        waitForElement(
            "bookmarkListRowButton::Exodus_2_1",
            toAppearAbove: "bookmarkListRowButton::Matthew_3_1",
            in: app
        )
    }

    /**
     Verifies that bookmark-list text search narrows the visible rows and that clearing the query
     restores the full row set.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic `Exodus 2:1` and `Matthew 3:1` bookmarks
     *   - opens the real bookmark list from the reader overflow menu
     *   - types `Matthew` into the real bookmark search field, verifies the list narrows to the
     *     matching row, then clears the query and verifies both rows return
     * - Failure modes:
     *   - fails if the bookmark list, search field, or either seeded bookmark row never appears
     *   - fails if the search query does not hide the non-matching bookmark row
     *   - fails if clearing the search query does not restore the full bookmark row set
     */
    func testBookmarkListSearchNarrowsAndClearsVisibleRows() {
        let app = makeApp()
        app.launch()

        _ = openBookmarkList(in: app)
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Expected bookmark search field to exist.")

        let matthewRow = app.descendants(matching: .any)["bookmarkListRowButton::Matthew_3_1"]

        replaceText(in: searchField, with: "Matthew")
        searchField.typeText("\n")
        waitForBookmarkListState(containing: "count=1", in: app, timeout: 10)
        waitForBookmarkListState(containing: "query=Matthew", in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Matthew_3_1"), in: app, timeout: 10)
        waitForBookmarkListState(notContaining: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)

        XCTAssertTrue(
            matthewRow.waitForExistence(timeout: 10),
            "Expected Matthew bookmark row to appear after filtering."
        )
        XCTAssertTrue(matthewRow.exists, "Expected Matthew bookmark row to remain visible after filtering.")

        replaceText(in: searchField, with: "")
        waitForBookmarkListState(containing: "count=2", in: app, timeout: 10)
        waitForBookmarkListState(notContaining: "query=Matthew", in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Matthew_3_1"), in: app, timeout: 10)
        XCTAssertTrue(
            requireBookmarkRow("Exodus_2_1", in: app, timeout: 10).exists,
            "Expected Exodus bookmark row to reappear after clearing search."
        )
        XCTAssertTrue(matthewRow.waitForExistence(timeout: 10), "Expected Matthew bookmark row to remain visible after clearing search.")
    }

    /**
     Verifies that bookmark-list label chips narrow the visible rows and that clearing the filter
     restores the full row set.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic `Genesis 1:1` and `Exodus 2:1` bookmarks,
     *     each assigned to a different user label
     *   - opens the real bookmark list from the reader overflow menu
     *   - selects the seeded `UI Test Seed` label chip, verifies the list narrows to the matching
     *     bookmark row, then clears the filter through the real `All` chip
     * - Failure modes:
     *   - fails if the bookmark list, seeded filter chip, or either seeded bookmark row never
     *     appears
     *   - fails if the label filter does not hide the non-matching bookmark row
     *   - fails if clearing the filter does not restore the full bookmark row set
     */
    func testBookmarkListLabelFilterNarrowsAndClearsVisibleRows() {
        let app = makeApp()
        app.launch()

        _ = openBookmarkList(in: app)
        selectBookmarkListFilterChip("UI_Test_Seed", in: app, timeout: 10)
        waitForBookmarkListState(containing: "count=1", in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Genesis_1_1"), in: app, timeout: 10)
        waitForBookmarkListState(notContaining: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)

        let genesisRow = requireBookmarkRow("Genesis_1_1", in: app, timeout: 10)
        XCTAssertTrue(genesisRow.exists, "Expected Genesis bookmark row to remain visible for the selected label.")
        XCTAssertTrue(
            requireElement("bookmarkListOpenStudyPadButton::UI_Test_Seed", in: app, timeout: 10).exists,
            "Expected the seeded label StudyPad handoff to appear while the filter is active."
        )

        selectBookmarkListFilterChip("all", in: app, timeout: 10)
        waitForBookmarkListState(containing: "count=2", in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Genesis_1_1"), in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)
        XCTAssertTrue(genesisRow.waitForExistence(timeout: 10), "Expected Genesis bookmark row to remain visible after clearing the filter.")
        XCTAssertTrue(
            requireBookmarkRow("Exodus_2_1", in: app, timeout: 10).exists,
            "Expected Exodus bookmark row to return after clearing the filter."
        )
        XCTAssertFalse(
            app.buttons["bookmarkListOpenStudyPadButton::UI_Test_Seed"].firstMatch.exists,
            "Expected the StudyPad handoff to disappear once the label filter is cleared."
        )
    }

    /**
     Verifies that selecting a seeded bookmark label filter exposes the StudyPad handoff and opens
     the matching StudyPad document in the reader shell.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic `Genesis 1:1` bookmark assigned to the
     *     seeded `UI Test Seed` label
     *   - opens the bookmark list from the actual reader overflow menu
     *   - selects the seeded label chip and triggers the real `Open StudyPad` action
     * - Failure modes:
     *   - fails if the seeded label filter or StudyPad action never appears
     *   - fails if the reader never enters StudyPad mode for `UI Test Seed`
     */
    func testBookmarkListOpensStudyPadForSelectedLabel() {
        let app = makeApp()
        app.launch()

        _ = openBookmarkList(in: app)
        openSeedStudyPadFromBookmarkList(in: app)
        waitForStudyPadPresentation(in: app, timeout: 20)
        let studyPadTitle = requireElement("readerStudyPadTitle", in: app, timeout: 10)
        XCTAssertEqual(studyPadTitle.label, "UI Test Seed")
    }

    /**
     Verifies that selecting a seeded history row jumps the active reader to that prior location.
     *
     * - Side effects:
     *   - launches the app with one deterministic persisted history row while staying on the real
     *     reader shell
     *   - opens History from the reader menu
     *   - selects the seeded history row and waits for the visible reader reference to change
     *     from `Genesis 1` to `Exodus 2`
     * - Failure modes:
     *   - fails if the reader shell or seeded history row never appears
     *   - fails if selecting the history row does not update the reader reference to `Exodus 2`
     */
    func testHistorySelectionNavigatesReaderToSeededReference() {
        let app = makeApp()
        app.launch()

        let initialReference = requireReaderReferenceValue(in: app, timeout: 20)
        XCTAssertTrue(
            initialReference.localizedCaseInsensitiveContains("Genesis 1"),
            "Expected the seeded history scenario to start on Genesis 1, but saw '\(initialReference)'."
        )

        XCTAssertTrue(openHistory(in: app).exists)
        tapElementReliably(requireHistoryRow(containing: "Exodus 2", in: app, timeout: 10), timeout: 10)
        let updatedReference = waitForReaderReferenceValueToChange(
            from: initialReference,
            in: app,
            timeout: 20
        )
        XCTAssertTrue(
            updatedReference.localizedCaseInsensitiveContains("Exodus 2"),
            "Expected selecting the seeded history row to navigate to Exodus 2, but saw '\(updatedReference)'."
        )
    }

    /**
     Verifies that clearing history removes the seeded row and keeps History empty after reopen.
     *
     * - Side effects:
     *   - launches the app with deterministic persisted history rows while staying on the real
     *     reader shell
     *   - opens History from the reader menu, clears the visible history, dismisses the screen,
     *     then reopens History to verify the cleared seeded rows remain deleted
     * - Failure modes:
     *   - fails if the History screen or clear control never appears
     *   - fails if reopening History still shows the seeded rows that Clear should delete
     */
    func testHistoryClearRemovesSeededRowAcrossReopen() {
        let app = makeApp()
        app.launch()

        _ = openHistory(in: app)
        XCTAssertTrue(requireHistoryRow(containing: "Exodus 2", in: app, timeout: 10).exists)

        tapElementReliably(requireElement("historyClearButton", in: app, timeout: 10), timeout: 10)
        waitForElementExistence(
            "historyRow::Exod_2_1",
            in: app,
            shouldExist: false,
            timeout: 10
        )
        waitForElementExistence(
            "historyRow::Matt_3_1",
            in: app,
            shouldExist: false,
            timeout: 10
        )
        waitForElementValue("historyScreen", toContain: "count=0", in: app, timeout: 10)
        waitForElementExistence("historyClearButton", in: app, shouldExist: false, timeout: 10)
        tapElementReliably(requireElement("historyDoneButton", in: app, timeout: 10), timeout: 10)
        _ = openHistory(in: app)
        waitForHistoryState(containing: "count=0", in: app, timeout: 10)
        waitForHistoryState(notContaining: historyRowStateToken("Exod_2_1"), in: app, timeout: 10)
        waitForHistoryState(notContaining: historyRowStateToken("Matt_3_1"), in: app, timeout: 10)
    }

    /**
     Verifies that deleting one history row leaves other history rows intact across reopen.
     *
     * - Side effects:
     *   - launches the app with two deterministic persisted history rows while staying on the real
     *     reader shell
     *   - opens History from the reader menu, deletes only the Exodus row, dismisses the screen,
     *     and reopens History to confirm the Matthew row persists
     * - Failure modes:
     *   - fails if the History screen or delete control never appears
     *   - fails if deleting Exodus also removes Matthew or if Exodus returns after reopening
     */
    func testHistoryRowDeletePreservesOtherRowsAcrossReopen() {
        let app = makeApp()
        app.launch()

        _ = openHistory(in: app)
        let exodusRow = requireHistoryRow(containing: "Exodus 2", in: app, timeout: 10)
        _ = requireHistoryRow(containing: "Matthew 3", in: app, timeout: 10)
        exodusRow.swipeLeft()
        tapElementReliably(requireElement("historyDeleteButton::Exod_2_1", in: app, timeout: 10), timeout: 10)
        waitForHistoryState(containing: "count=1", in: app, timeout: 10)
        waitForHistoryState(notContaining: historyRowStateToken("Exod_2_1"), in: app, timeout: 10)
        waitForHistoryState(containing: historyRowStateToken("Matt_3_1"), in: app, timeout: 10)

        tapElementReliably(requireElement("historyDoneButton", in: app, timeout: 10), timeout: 10)
        _ = openHistory(in: app)
        waitForHistoryState(containing: "count=1", in: app, timeout: 10)
        waitForHistoryState(notContaining: historyRowStateToken("Exod_2_1"), in: app, timeout: 10)
        waitForHistoryState(containing: historyRowStateToken("Matt_3_1"), in: app, timeout: 10)
    }

    /**
     Verifies that label assignment can be reached from the real bookmark-list path and still
     toggle the seeded label state.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic bookmark and seed label preloaded
     *   - opens the bookmark list from the reader overflow menu
     *   - opens label assignment from the seeded bookmark row and toggles favourite plus assignment
     * - Failure modes:
     *   - fails if the bookmark list cannot be reached from the reader menu
     *   - fails if the seeded bookmark row or inline edit-labels action is missing
     *   - fails if the label-assignment screen never appears or the seeded row state does not
     *     update after the toggles
     */
    func testBookmarkListOpensLabelAssignmentForSeededBookmark() {
        let app = makeApp()
        app.launch()

        let labelAssignmentScreen = openLabelAssignmentFromBookmarkList(in: app)
        XCTAssertTrue(labelAssignmentScreen.exists)

        assertSeedLabelAssignmentCanToggle(in: app)
    }

    /**
     Verifies that the about screen can be opened from the reader shell.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled, in-memory persistence, and one
     *     deterministic seeded bookmark-label pair for stable reader-shell startup
     *   - opens the reader overflow menu and pushes the about screen
     * - Failure modes:
     *   - fails if the about action is missing from the reader menu
     *   - fails if the about screen does not render after navigation completes
     */
    func testAboutScreenOpensFromReaderMenu() {
        let app = makeApp()
        app.launch()

        openAboutFromReaderMenu(in: app)
    }

    /**
     Verifies that the full-backup export action drives Import and Export into share-sheet presentation.
     *
     * - Side effects:
     *   - launches the app directly into Import and Export
     *   - triggers a full-backup export, which writes a temporary file and requests share-sheet
     *     presentation
     * - Failure modes:
     *   - fails if the full-backup action is missing from the Import and Export screen
     *   - fails if the Import and Export screen never reports the share-sheet-presented state after
     *     export completes
     */
    func testSettingsImportExportFullBackupPresentsShareSheet() {
        let app = makeApp()
        app.launch()

        let importExportScreen = openImportExport(in: app)
        XCTAssertTrue(importExportScreen.exists)

        let fullBackupButton = requireElement("importExportFullBackupButton", in: app, timeout: 10)
        tapElementReliably(fullBackupButton, timeout: 10)
        waitForElementValue("importExportScreen", toEqual: "shareSheetPresented", in: app, timeout: 20)
    }

    /**
     Verifies that the import action drives Import and Export into file-picker presentation.
     *
     * - Side effects:
     *   - launches the app directly into Import and Export
     *   - triggers the backup import action, which requests document-picker presentation
     * - Failure modes:
     *   - fails if the import action is missing from the Import and Export screen
     *   - fails if the Import and Export screen never reports the import-picker-presented state
     */
    func testSettingsImportExportImportPresentsFilePickerState() {
        let app = makeApp()
        app.launch()

        let importExportScreen = openImportExport(in: app)
        XCTAssertTrue(importExportScreen.exists)

        let importButton = requireElement("importExportImportButton", in: app, timeout: 10)
        tapElementReliably(importButton, timeout: 10)
        waitForElementValue("importExportScreen", toEqual: "importPickerPresented", in: app, timeout: 20)
    }

    /**
     Verifies that label assignment can toggle both favourite and assignment state for a seeded
     label.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens the seeded label-assignment sheet
     *   - toggles the seed label's favourite state and assignment checkbox
     * - Failure modes:
     *   - fails if the label-assignment route never appears
     *   - fails if the seed label row or either inline control is missing
     *   - fails if the row accessibility state never updates to the combined assigned/favourite
     *     value after the toggles
     */
    func testLabelAssignmentTogglesFavouriteAndAssignment() {
        let app = makeApp()
        app.launch()

        let labelAssignmentScreen = openLabelAssignment(in: app)
        XCTAssertTrue(labelAssignmentScreen.exists)

        assertSeedLabelAssignmentCanToggle(in: app)
    }

    /**
     Verifies that label assignment can create a new label from the real bookmark-list path and
     reflect that assignment back on the bookmark list after dismissal.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic bookmark plus the seeded label-assignment
     *     workflow data
     *   - opens label assignment from the actual bookmark-list row affordance
     *   - creates one new label inline through the alert flow and dismisses back to the bookmark
     *     list
     * - Failure modes:
     *   - fails if the bookmark list, label-assignment screen, or create-label affordance never
     *     appears
     *   - fails if the alert text field or confirm action cannot be reached
     *   - fails if the new label row never reaches the assigned state or if the bookmark list does
     *     not expose the new filter chip after dismissal
     */
    func testBookmarkListLabelAssignmentCreatesAndAssignsNewLabel() {
        let app = makeApp()
        let newLabelSegment = "UI_Test_Fresh"
        app.launch()

        _ = openLabelAssignmentFromBookmarkList(in: app)
        createFreshLabelFromAssignment(in: app)

        _ = requireElement("labelAssignmentRow::\(newLabelSegment)", in: app, timeout: 10)
        waitForElementValue(
            "labelAssignmentRow::\(newLabelSegment)",
            toEqual: "assigned,notFavourite",
            in: app,
            timeout: 10
        )

        dismissLabelAssignmentToBookmarkList(in: app)
        XCTAssertTrue(
            requireElement("bookmarkListFilterChip::\(newLabelSegment)", in: app, timeout: 10).exists,
            "Expected the new label to appear as a bookmark-list filter chip after dismissal."
        )
    }

    /**
     Verifies that removing a bookmark's assigned label through the real label-assignment sheet
     prevents that bookmark from appearing under the same label filter on return to the bookmark
     list.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic bookmark already assigned to the seeded
     *     `UI Test Seed` label
     *   - opens label assignment from the actual bookmark-list row affordance
     *   - removes the seeded label assignment, dismisses back to the bookmark list, and applies
     *     the real label filter chip
     * - Failure modes:
     *   - fails if the bookmark list, label-assignment screen, or seeded label row never appears
     *   - fails if the seeded row never reaches the unassigned state after toggling
     *   - fails if filtering by the removed label still shows the bookmark row
     */
    func testBookmarkListLabelAssignmentRemovalHidesBookmarkUnderFilter() {
        let app = makeApp()
        app.launch()

        _ = openLabelAssignmentFromBookmarkList(in: app)

        let seedRow = requireElement("labelAssignmentRow::UI_Test_Seed", in: app, timeout: 10)
        XCTAssertEqual(seedRow.value as? String, "assigned,notFavourite")
        requireElement("labelAssignmentToggleButton::UI_Test_Seed", in: app, timeout: 10).tap()

        waitForElementValue(
            "labelAssignmentRow::UI_Test_Seed",
            toEqual: "unassigned,notFavourite",
            in: app,
            timeout: 10
        )

        dismissLabelAssignmentToBookmarkList(in: app)

        selectBookmarkListFilterChip("UI_Test_Seed", in: app, timeout: 10)
        waitForBookmarkListState(containing: "count=0", in: app, timeout: 10)
        waitForBookmarkListState(notContaining: bookmarkListRowStateToken("Genesis_1_1"), in: app, timeout: 10)
    }

    /**
     Verifies that bookmark-list filter and search state reset after dismissing and reopening the
     real bookmark sheet.
     *
     * - Side effects:
     *   - launches the reader shell with deterministic `Genesis 1:1` and `Exodus 2:1` bookmarks
     *     assigned to different labels
     *   - opens the real bookmark list, applies the seeded label filter, then adds a conflicting
     *     search query so the filtered list becomes empty
     *   - dismisses and reopens the bookmark list from the reader menu
     * - Failure modes:
     *   - fails if the bookmark list, seeded label chip, or search field never appears
     *   - fails if the conflicting search query does not hide the remaining filtered bookmark
     *   - fails if reopening the bookmark list does not restore both seeded rows
     */
    func testBookmarkListFilterAndSearchResetAcrossReopen() {
        let app = makeApp()
        app.launch()

        _ = openBookmarkList(in: app)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Expected bookmark search field to exist.")

        selectBookmarkListFilterChip("UI_Test_Seed", in: app, timeout: 10)
        waitForBookmarkListState(containing: "count=1", in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Genesis_1_1"), in: app, timeout: 10)
        waitForBookmarkListState(notContaining: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)
        let genesisRow = requireBookmarkRow("Genesis_1_1", in: app, timeout: 10)
        XCTAssertTrue(genesisRow.waitForExistence(timeout: 10), "Expected Genesis bookmark row to remain visible after filtering.")

        replaceText(in: searchField, with: "Exodus")
        searchField.typeText("\n")
        waitForBookmarkListState(containing: "count=0", in: app, timeout: 10)
        waitForBookmarkListState(containing: "query=Exodus", in: app, timeout: 10)
        waitForBookmarkListState(notContaining: bookmarkListRowStateToken("Genesis_1_1"), in: app, timeout: 10)

        reopenBookmarkList(in: app)
        waitForBookmarkListState(containing: "selectedLabel=all", in: app, timeout: 10)
        waitForBookmarkListState(containing: "count=2", in: app, timeout: 10)
        waitForBookmarkListState(notContaining: "query=Exodus", in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Genesis_1_1"), in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)
        XCTAssertTrue(genesisRow.waitForExistence(timeout: 10), "Expected Genesis bookmark row to reappear after reopening the bookmark list.")
        XCTAssertTrue(
            requireBookmarkRow("Exodus_2_1", in: app, timeout: 10).exists,
            "Expected Exodus bookmark row to reappear after reopening the bookmark list."
        )
    }

    /**
     Verifies that labels can be created, renamed, and deleted from the label manager.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens the label manager through Settings
     *   - creates one new label, renames it through the edit sheet, and deletes it via swipe
     *     actions
     * - Failure modes:
     *   - fails if the create alert, edit sheet, or delete swipe action cannot be reached through
     *     the label manager UI
     *   - fails if the created or renamed label row never appears, or if the deleted row remains
     *     visible after deletion
     */
    func testLabelManagerCreateRenameDeleteFlow() {
        let app = makeApp()
        let originalName = "L1"
        let renamedName = "L2"
        app.launch()

        XCTAssertTrue(openLabelManager(in: app).exists)

        tapElementReliably(requireElement("labelManagerAddButton", in: app, timeout: 10), timeout: 10)
        replaceText(in: requireLabelManagerNewLabelField(in: app, timeout: 10), with: originalName)
        tapElementReliably(requireLabelManagerCreateButton(in: app, timeout: 10), timeout: 10)
        XCTAssertTrue(requireLabelRow(named: originalName, in: app, timeout: 10).exists)

        let createdRow = requireLabelRow(named: originalName, in: app, timeout: 10)
        tapElementReliably(createdRow, timeout: 10)
        _ = requireElement("labelEditScreen", in: app, timeout: 10)
        replaceText(in: requireElement("labelEditNameField", in: app, timeout: 10), with: renamedName)
        tapElementReliably(requireElement("labelEditDoneButton", in: app, timeout: 10), timeout: 10)

        XCTAssertTrue(requireLabelRow(named: renamedName, in: app, timeout: 10).exists)
        let renamedRowToDelete = requireLabelRow(named: renamedName, in: app, timeout: 10)
        renamedRowToDelete.swipeLeft()
        tapElementReliably(requireElement("labelManagerDeleteAction", in: app, timeout: 10), timeout: 10)
        waitForElementExistence("labelManagerRowButton-\(renamedName)", in: app, shouldExist: false, timeout: 10)
    }

    /**
     Verifies that the sync settings screen can be opened from Settings.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens Settings
     *   - opens Sync Settings from the settings screen
     * - Failure modes:
     *   - fails if the Settings sync link is missing or never becomes hittable
     *   - fails if the sync settings screen does not render after navigation completes
     */
    func testSettingsSyncLinkOpensSyncSettings() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openSyncSettings(in: app).exists)
    }

    /**
     Verifies that invalid NextCloud server input surfaces the expected validation status.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens Sync Settings from the reader action
     *   - enters one invalid server URL and triggers the manual connection test
     * - Failure modes:
     *   - fails if the Sync Settings sheet never appears
     *   - fails if the NextCloud server field or test-connection control is missing
     *   - fails if the exported connection-test state never reaches `failureInvalidURL`
     */
    func testSyncSettingsNextCloudInvalidURLShowsValidationStatus() {
        let app = makeApp()
        app.launch()

        _ = openSyncSettingsFromReaderAction(in: app)
        let serverField = requireElement("syncNextCloudServerURLField", in: app, timeout: 10)

        replaceText(in: serverField, with: "not-a-url")
        dismissKeyboardIfPresent(in: app)
        triggerSyncConnectionTest(in: app, timeout: 15)
        waitForElementValue("syncRemoteStatus", toEqual: "failureInvalidURL", in: app, timeout: 10)
    }

    /**
     Verifies that disabling one seeded NextCloud sync category updates the exported Sync screen
     state.
     *
     * - Side effects:
     *   - launches the app on the reader shell with persisted NextCloud settings and bookmarks
     *     already enabled through host-side fixture seeding
     *   - opens Sync Settings from the reader action and toggles the production bookmarks switch
     *     off
     * - Failure modes:
     *   - fails if the production bookmarks toggle never appears for the seeded category state
     *   - fails if the Sync screen state does not start with `backend=NEXT_CLOUD;enabled=bookmarks`
     *   - fails if disabling the category does not update the exported Sync screen state to
     *     `backend=NEXT_CLOUD;enabled=none`
     */
    func testSyncSettingsCategoryToggleMutatesExportedState() {
        let app = makeApp()
        app.launch()

        _ = openSyncSettingsFromReaderAction(in: app)
        let syncState = requireElement("syncSettingsState", in: app, timeout: 10)
        XCTAssertEqual(
            syncState.value as? String,
            "backend=NEXT_CLOUD;enabled=bookmarks"
        )

        toggleSyncCategory(
            "syncCategoryToggle::bookmarks",
            in: app,
            expectedScreenValue: "backend=NEXT_CLOUD;enabled=none"
        )
    }

    /**
     Verifies that disabling a seeded NextCloud sync category persists across a direct dismiss and
     reopen of Sync Settings.
     *
     * - Side effects:
     *   - launches the app on the reader shell with persisted NextCloud settings and bookmarks
     *     already enabled through host-side fixture seeding
     *   - disables the bookmarks category through the production toggle
     *   - dismisses the Sync screen, reopens it from the reader action, and rehydrates from
     *     persisted settings state
     * - Failure modes:
     *   - fails if the seeded Sync screen does not start with `backend=NEXT_CLOUD;enabled=bookmarks`
     *   - fails if the direct dismiss or reopen controls never appear
     *   - fails if reopening the sheet does not preserve the exported `enabled=none` state token
     */
    func testSyncSettingsCategoryDisablePersistsAcrossDirectReopen() {
        let app = makeApp()
        app.launch()

        _ = openSyncSettingsFromReaderAction(in: app)
        let syncState = requireElement("syncSettingsState", in: app, timeout: 10)
        XCTAssertEqual(
            syncState.value as? String,
            "backend=NEXT_CLOUD;enabled=bookmarks"
        )

        toggleSyncCategory(
            "syncCategoryToggle::bookmarks",
            in: app,
            expectedScreenValue: "backend=NEXT_CLOUD;enabled=none"
        )

        dismissSyncSettings(in: app)
        _ = openSyncSettingsFromReaderAction(in: app)

        let reopenedSyncState = requireElement("syncSettingsState", in: app, timeout: 10)
        XCTAssertEqual(
            reopenedSyncState.value as? String,
            "backend=NEXT_CLOUD;enabled=none"
        )
    }

    /**
     Verifies that switching the active sync backend swaps the visible Sync section and exported
     backend state.
     *
     * - Side effects:
     *   - launches the app on the reader shell with persisted NextCloud settings from host-side
     *     fixture seeding
     *   - opens Sync Settings from the reader action and switches the production picker from
     *     NextCloud to Google Drive
     * - Failure modes:
     *   - fails if the seeded NextCloud field or the Google Drive sign-in control never appears
     *   - fails if the exported Sync screen state does not move from `backend=NEXT_CLOUD;enabled=none`
     *     to `backend=GOOGLE_DRIVE;enabled=none`
     */
    func testSyncSettingsBackendSwitchMutatesVisibleSection() {
        let app = makeApp()
        app.launch()

        _ = openSyncSettingsFromReaderAction(in: app)
        let syncState = requireElement("syncSettingsState", in: app, timeout: 10)
        XCTAssertEqual(
            syncState.value as? String,
            "backend=NEXT_CLOUD;enabled=none"
        )
        XCTAssertTrue(requireElement("syncNextCloudServerURLField", in: app, timeout: 10).exists)

        tapSyncBackend("GOOGLE_DRIVE", in: app)
        waitForElementValue(
            "syncSettingsState",
            toEqual: "backend=GOOGLE_DRIVE;enabled=none",
            in: app,
            timeout: 10
        )
        XCTAssertTrue(requireElement("syncGoogleDriveSignInButton", in: app, timeout: 10).exists)
    }

    /**
     Verifies that switching the active sync backend persists across a direct dismiss and reopen of
     Sync Settings.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens Sync Settings with its persisted backend
     *   - switches the backend from NextCloud to Google Drive through the production picker
     *   - dismisses and reopens Sync Settings from the reader action so the sheet rehydrates from
     *     persisted settings state
     * - Failure modes:
     *   - fails if the seeded Sync screen does not start in the NextCloud branch
     *   - fails if the dismiss or reopen controls never appear
     *   - fails if reopening the sheet does not preserve the exported `backend=GOOGLE_DRIVE;enabled=none`
     *     state token or the Google Drive section
     */
    func testSyncSettingsBackendSwitchPersistsAcrossDirectReopen() {
        let app = makeApp()
        app.launch()

        _ = openSyncSettingsFromReaderAction(in: app)
        let syncState = requireElement("syncSettingsState", in: app, timeout: 10)
        XCTAssertEqual(
            syncState.value as? String,
            "backend=NEXT_CLOUD;enabled=none"
        )

        tapSyncBackend("GOOGLE_DRIVE", in: app)
        waitForElementValue(
            "syncSettingsState",
            toEqual: "backend=GOOGLE_DRIVE;enabled=none",
            in: app,
            timeout: 10
        )
        XCTAssertTrue(requireElement("syncGoogleDriveSignInButton", in: app, timeout: 10).exists)

        dismissSyncSettings(in: app)
        _ = openSyncSettingsFromReaderAction(in: app)

        waitForElementValue(
            "syncSettingsState",
            toEqual: "backend=GOOGLE_DRIVE;enabled=none",
            in: app,
            timeout: 10
        )
        XCTAssertTrue(requireElement("syncGoogleDriveSignInButton", in: app, timeout: 10).exists)
    }

    /**
     Verifies that toggling justify text mutates the exported control state.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens the text-display editor
     *   - toggles the justify-text control and waits for its accessibility value to change
     * - Failure modes:
     *   - fails if the text-display editor never appears
     *   - fails if the justify-text toggle is missing or if its exported state never changes after
     *     the toggle
     */
    func testTextDisplayJustifyToggleMutatesControlState() {
        let app = makeApp()
        app.launch()

        let textDisplayScreen = openTextDisplaySettings(in: app)
        XCTAssertTrue(textDisplayScreen.exists)

        let justifyToggleButton = app.buttons["textDisplayJustifyTextToggleButton"].firstMatch
        XCTAssertTrue(justifyToggleButton.waitForExistence(timeout: 10), "Expected justify-text control to exist.")
        let initialScreenValue = (textDisplayScreen.value as? String) ?? ""
        let expectedScreenToken = initialScreenValue.contains("justifyTextOn") ? "justifyTextOff" : "justifyTextOn"
        toggleTextDisplayJustifySwitch(
            on: textDisplayScreen,
            in: app,
            expectedScreenToken: expectedScreenToken,
            timeout: 10
        )
        waitForElementValue(
            "textDisplaySettingsScreen",
            toContain: expectedScreenToken,
            in: app,
            timeout: 10
        )
    }

    /**
     Verifies that the font-family control presents the native font picker from Text Display.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens the text-display editor
     *   - taps the font-family control, which presents the iOS font picker sheet
     * - Failure modes:
     *   - fails if the text-display editor never appears
     *   - fails if the font-family control is missing or if the screen never reports
     *     `fontPickerPresented` after the tap
     */
    func testTextDisplayFontFamilyButtonPresentsFontPicker() {
        let app = makeApp()
        app.launch()

        let textDisplayScreen = openTextDisplaySettings(in: app)
        XCTAssertTrue(textDisplayScreen.exists)
        let fontFamilyButton = requireElement("textDisplayFontFamilyButton", in: app, timeout: 10)
        tapElementReliably(fontFamilyButton, timeout: 10)

        let valuePredicate = NSPredicate(format: "value CONTAINS %@", "fontPickerPresented")
        expectation(for: valuePredicate, evaluatedWith: textDisplayScreen)
        waitForExpectations(timeout: 10)
    }

    /**
     Verifies that the color editor can be opened from Settings.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens Settings
     *   - opens Colors from the settings screen
     * - Failure modes:
     *   - fails if the Settings colors link is missing or never becomes hittable
     *   - fails if the color settings screen does not render after navigation completes
     */
    func testSettingsColorsLinkOpensColorEditor() {
        let app = makeApp()
        app.launch()

        openSettings(in: app)
        tapSettingsElement("settingsColorsLink", in: app)

        XCTAssertTrue(requireElement("colorSettingsScreen", in: app, timeout: 10).exists)
    }

    /**
     Verifies that the Colors reset action restores the seeded theme tuple to defaults.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens the Colors editor with a seeded
     *     non-default theme tuple
     *   - triggers the reset-to-defaults action and waits for the exported color state to return
     *     to the default marker
     * - Failure modes:
     *   - fails if the Colors editor never appears
     *   - fails if the reset action is missing or if the exported color state never changes back
     *     to `colorDefaults`
     */
    func testColorSettingsResetRestoresDefaultThemeColors() {
        let app = makeApp()
        app.launch()

        let colorScreen = openColorSettings(in: app)
        XCTAssertEqual(colorScreen.value as? String, "colorCustom")

        tapElementReliably(requireElement("colorSettingsResetButton", in: app, timeout: 10), timeout: 10)
        waitForElementValue("colorSettingsScreen", toEqual: "colorDefaults", in: app, timeout: 10)
    }

    /**
     Builds the XCUIApplication instance used by each UI test.
     *
     * - Parameter searchQuery: Optional search query to type into Search after the sheet opens.
     * - Returns: App handle configured with deterministic per-test metadata.
     * - Side effects:
     *   - terminates any previously tracked app process so each test starts from a clean launch
     *   - assigns a unique session identifier used by the host-side fixture tooling
     *   - stores one optional Search query for later use by `openSearch(in:)`
     * - Failure modes: This helper cannot fail.
     */
    private func makeApp(searchQuery: String? = nil) -> XCUIApplication {
        if let trackedApp, trackedApp.state != .notRunning {
            _ = terminateAppReliably(trackedApp)
        }
        let app = XCUIApplication()
        trackedApp = app
        app.launchEnvironment["UITEST_SESSION_ID"] = UUID().uuidString
        app.launchEnvironment["UITEST_ENABLE_DETAILED_ACCESSIBILITY_EXPORTS"] = "1"
        app.launchArguments += ["-UITEST_ENABLE_DETAILED_ACCESSIBILITY_EXPORTS"]
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let searchQuery {
            app.launchEnvironment["UITEST_SEARCH_QUERY"] = searchQuery
            app.launchArguments += ["-UITEST_SEARCH_QUERY", searchQuery]
        }
        prepareFixtureIfRequested(for: app)
        return app
    }

    /**
     Applies one host-side fixture scenario to the simulator app container before launching the app.
     *
     * - Side effects:
     *   - resolves the app data container from the current simulator UDID
     *   - runs `UITestFixtureTool reset` and `seed` against that installed app container
     * - Failure modes:
     *   - records an XCTest failure when the fixture tool path, simulator UDID, or data container
     *     cannot be resolved from the current test-host environment
     *   - records an XCTest failure when the fixture reset or seed subprocess exits non-zero
     */
    private func prepareFixtureIfRequested(
        for app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let environment = ProcessInfo.processInfo.environment
        guard let scenario = resolveFixtureScenario(
            environment: environment,
            file: file,
            line: line
        ) else {
            return
        }
        guard let fixtureToolPath = resolveFixtureToolPath(
            environment: environment,
            file: file,
            line: line
        ) else {
            return
        }
        let bundleID = environment["UITEST_BUNDLE_ID"] ?? "org.andbible.ios"
        guard let dataContainerPath = ensureInstalledAppDataContainer(
            for: app,
            bundleIdentifier: bundleID,
            file: file,
            line: line
        ) else {
            return
        }

        print(
            "Preparing fixture scenario '\(scenario)' with container '\(dataContainerPath)'."
        )

        let resetResult = runHostProcess(
            executablePath: fixtureToolPath,
            arguments: [
                "reset",
                "--data-container",
                dataContainerPath,
                "--bundle-id",
                bundleID,
            ],
            timeout: 30
        )
        XCTAssertEqual(
            resetResult.status,
            0,
            "Fixture reset failed for scenario '\(scenario)':\nstdout:\n\(resetResult.stdout)\nstderr:\n\(resetResult.stderr)",
            file: file,
            line: line
        )

        let seedResult = runHostProcess(
            executablePath: fixtureToolPath,
            arguments: [
                "seed",
                "--data-container",
                dataContainerPath,
                "--scenario",
                scenario,
                "--bundle-id",
                bundleID,
            ],
            timeout: 30
        )
        XCTAssertEqual(
            seedResult.status,
            0,
            "Fixture seed failed for scenario '\(scenario)':\nstdout:\n\(seedResult.stdout)\nstderr:\n\(seedResult.stderr)",
            file: file,
            line: line
        )
    }

    /**
     Ensures the app under test has a real simulator data container before fixture seeding runs.
     *
     * - Parameters:
     *   - app: Application under test that will later be launched for the real test body.
     *   - bundleIdentifier: Bundle identifier of the app under test.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Absolute simulator data-container path for the installed app.
     * - Side effects:
     *   - performs one bootstrap launch/terminate cycle when the simulator has not yet created the
     *     app data container
     * - Failure modes:
     *   - records an XCTest failure when the bootstrap launch cannot materialize the data
     *     container before fixture seeding needs it
     */
    private func ensureInstalledAppDataContainer(
        for app: XCUIApplication,
        bundleIdentifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let simulatorID = environment["UITEST_SIMULATOR_ID"] ?? environment["SIMULATOR_UDID"]
        let forceXCTestBootstrap = environment["UITEST_FORCE_XCTEST_BOOTSTRAP"] == "1"

        if let existingPath = waitForInstalledAppDataContainer(
            simulatorID: simulatorID,
            bundleIdentifier: bundleIdentifier,
            timeout: 5
        ) {
            return existingPath
        }

        print("Bootstrapping app container for bundle '\(bundleIdentifier)' before fixture seeding.")
        var usedXCTestBootstrap = simulatorID == nil || forceXCTestBootstrap
        if forceXCTestBootstrap {
            print("Forcing XCTest bootstrap launch for bundle '\(bundleIdentifier)'.")
        } else if let simulatorID {
            let launchResult = runHostProcess(
                executablePath: "/usr/bin/xcrun",
                arguments: ["simctl", "launch", simulatorID, bundleIdentifier],
                timeout: 20
            )
            if launchResult.status == 0 {
                if let bootstrappedPath = waitForInstalledAppDataContainer(
                    simulatorID: simulatorID,
                    bundleIdentifier: bundleIdentifier,
                    timeout: 30
                ) {
                    _ = runHostProcess(
                        executablePath: "/usr/bin/xcrun",
                        arguments: ["simctl", "terminate", simulatorID, bundleIdentifier],
                        timeout: 10
                    )
                    return bootstrappedPath
                }
                _ = runHostProcess(
                    executablePath: "/usr/bin/xcrun",
                    arguments: ["simctl", "terminate", simulatorID, bundleIdentifier],
                    timeout: 10
                )
            } else {
                print(
                    """
                    simctl bootstrap launch failed for '\(bundleIdentifier)'; falling back to XCTest launch.
                    stdout:
                    \(launchResult.stdout)
                    stderr:
                    \(launchResult.stderr)
                    """
                )
                usedXCTestBootstrap = true
            }
        }

        if usedXCTestBootstrap {
            app.launchEnvironment["UITEST_EXIT_AFTER_BOOTSTRAP_LAUNCH"] = "1"
            app.launch()
            if let bootstrappedPath = waitForInstalledAppDataContainer(
                simulatorID: simulatorID,
                bundleIdentifier: bundleIdentifier,
                timeout: 45
            ) {
                XCTAssertTrue(
                    waitForAppToStop(app, timeout: 30) || terminateAppReliably(
                        app,
                        bundleIdentifier: bundleIdentifier,
                        simulatorID: simulatorID
                    ),
                    "Expected bootstrap app '\(bundleIdentifier)' to stop before fixture seeding.",
                    file: file,
                    line: line
                )
                app.launchEnvironment.removeValue(forKey: "UITEST_EXIT_AFTER_BOOTSTRAP_LAUNCH")
                return bootstrappedPath
            }
            XCTAssertTrue(
                waitForAppToStop(app, timeout: 30) || terminateAppReliably(
                    app,
                    bundleIdentifier: bundleIdentifier,
                    simulatorID: simulatorID
                ),
                "Expected bootstrap app '\(bundleIdentifier)' to stop before fixture seeding.",
                file: file,
                line: line
            )
            app.launchEnvironment.removeValue(forKey: "UITEST_EXIT_AFTER_BOOTSTRAP_LAUNCH")
        }

        if let bootstrappedPath = waitForInstalledAppDataContainer(
            simulatorID: simulatorID,
            bundleIdentifier: bundleIdentifier,
            timeout: 45
        ) {
            return bootstrappedPath
        }

        if let simulatorID {
            _ = resolveInstalledAppDataContainer(
                simulatorID: simulatorID,
                bundleIdentifier: bundleIdentifier,
                timeout: 5,
                recordFailure: true,
                file: file,
                line: line
            )
            return nil
        }

        XCTFail(
            "Unable to resolve simulator data container for '\(bundleIdentifier)' after bootstrap launch.",
            file: file,
            line: line
        )
        return nil
    }

    /**
     Terminates the app under test through CoreSimulator instead of XCTest's direct terminate path.
     *
     * XCTest's `terminate()` is not reliable for apps launched solely to materialize the simulator
     * data container during fixture seeding. When that bootstrap launch cannot be terminated cleanly,
     * the actual problem is not the test flow but the process-lifecycle helper. Host-side
     * `simctl terminate` is a better source of truth because the fixture tool also runs against the
     * simulator host, not the XCUIApplication bridge.
     *
     * - Parameters:
     *   - app: Running app handle to stop.
     *   - bundleIdentifier: Bundle identifier of the app under test.
     *   - simulatorID: Current simulator UDID when already known.
     * - Returns: `true` when the app is already stopped or a host-side terminate succeeds.
     * - Side effects:
     *   - resolves the simulator UDID from the current test environment when needed
     *   - retries `xcrun simctl terminate` a small number of times before giving up
     * - Failure modes: This helper does not record XCTest failures directly.
     */
    private func terminateAppReliably(
        _ app: XCUIApplication,
        bundleIdentifier: String? = nil,
        simulatorID: String? = nil
    ) -> Bool {
        if app.state == .notRunning {
            return true
        }

        let resolvedBundleIdentifier = bundleIdentifier ?? currentUITestBundleIdentifier()
        let resolvedSimulatorID = simulatorID ?? resolveCurrentSimulatorID()

        guard let resolvedSimulatorID else {
            return false
        }

        for _ in 0..<3 {
            let terminateResult = runHostProcess(
                executablePath: "/usr/bin/xcrun",
                arguments: ["simctl", "terminate", resolvedSimulatorID, resolvedBundleIdentifier],
                timeout: 15
            )
            if terminateResult.status == 0 {
                return true
            }
            if app.state == .notRunning {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }

        return app.state == .notRunning
    }

    /**
     Waits for one XCUIApplication handle to report a stopped state.
     *
     * - Parameters:
     *   - app: Application handle that should eventually stop.
     *   - timeout: Maximum time to wait for `.notRunning`.
     * - Returns: `true` when the app stops within the timeout, otherwise `false`.
     * - Side effects: Pumps the current run loop while waiting for state propagation.
     * - Failure modes: This helper does not record XCTest failures directly.
     */
    private func waitForAppToStop(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.state == .notRunning {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline

        return app.state == .notRunning
    }

    /**
     Resolves the bundle identifier of the app under test for host-side simulator commands.
     *
     * - Returns: Explicit UI-test bundle identifier override, or the production app default.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func currentUITestBundleIdentifier() -> String {
        ProcessInfo.processInfo.environment["UITEST_BUNDLE_ID"] ?? "org.andbible.ios"
    }

    /**
     Resolves the current simulator UDID for host-side `simctl` commands.
     *
     * Resolution order:
     * - explicit UI-test host overrides
     * - the simulator runtime environment
     * - the `Devices/<UDID>/...` segment in the current bundle path
     *
     * - Returns: Current simulator UDID when it can be derived, otherwise `nil`.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func resolveCurrentSimulatorID() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let simulatorID = environment["UITEST_SIMULATOR_ID"], !simulatorID.isEmpty {
            return simulatorID
        }
        if let simulatorID = environment["SIMULATOR_UDID"], !simulatorID.isEmpty {
            return simulatorID
        }

        let pathComponents = Bundle.main.bundleURL.pathComponents
        guard let devicesIndex = pathComponents.firstIndex(of: "Devices"),
              pathComponents.indices.contains(devicesIndex + 1) else {
            return nil
        }
        return pathComponents[devicesIndex + 1]
    }

    /**
     Waits for the installed app data container to become visible through either `simctl` or the
     simulator filesystem scan.
     *
     * - Parameters:
     *   - simulatorID: Optional simulator UDID used for `simctl get_app_container`.
     *   - bundleIdentifier: Bundle identifier of the app under test.
     *   - timeout: Maximum time to keep polling both host-side resolution strategies.
     * - Returns: Absolute simulator data-container path once available, otherwise `nil`.
     * - Side effects:
     *   - repeatedly queries `simctl get_app_container` when a simulator UDID is known
     *   - scans the simulator filesystem for container metadata while installation settles
     * - Failure modes: This helper does not fail directly.
     */
    private func waitForInstalledAppDataContainer(
        simulatorID: String?,
        bundleIdentifier: String,
        timeout: TimeInterval
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let simulatorID,
               let path = resolveInstalledAppDataContainer(
                   simulatorID: simulatorID,
                   bundleIdentifier: bundleIdentifier,
                   timeout: 2,
                   recordFailure: false
               ) {
                return path
            }
            if let path = findInstalledAppDataContainerFromFilesystem(
                bundleIdentifier: bundleIdentifier
            ) {
                return path
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline

        return nil
    }

    /**
     Resolves the installed simulator data container by scanning mobile-container metadata on disk.
     *
     * - Parameters:
     *   - bundleIdentifier: Bundle identifier of the app under test.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Absolute simulator data-container path for the installed app.
     * - Side effects:
     *   - scans the current simulator's `Containers/Data/Application` directories
     * - Failure modes:
     *   - records an XCTest failure when the simulator data root or matching container metadata
     *     cannot be resolved from the installed app bundle path
     */
    private func findInstalledAppDataContainerFromFilesystem(
        bundleIdentifier: String
    ) -> String? {
        let installedAppBundleURL = Bundle.main.bundleURL
        let simulatorDataRootURL = installedAppBundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dataApplicationsURL = simulatorDataRootURL
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Application", isDirectory: true)

        guard FileManager.default.fileExists(atPath: dataApplicationsURL.path) else {
            return nil
        }

        let candidateURLs = (try? FileManager.default.contentsOfDirectory(
            at: dataApplicationsURL,
            includingPropertiesForKeys: nil
        )) ?? []

        for candidateURL in candidateURLs {
            let metadataURL = candidateURL.appendingPathComponent(
                ".com.apple.mobile_container_manager.metadata.plist",
                isDirectory: false
            )
            guard let metadata = NSDictionary(contentsOf: metadataURL) as? [String: Any],
                  let identifier = metadata["MCMMetadataIdentifier"] as? String,
                  identifier == bundleIdentifier else {
                continue
            }
            return candidateURL.path
        }

        return nil
    }

    /**
     Resolves the fixture scenario for the current UI test.
     *
     * Resolution order:
     * - explicit `UITEST_FIXTURE_SCENARIO` host environment override
     * - checked-in `scripts/ui_test_fixture_manifest.json` entry for the current test method
     *
     * - Parameters:
     *   - environment: Current XCTest host environment.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Fixture scenario name, or `nil` only when the current test is intentionally
     *   absent from the manifest.
     * - Side effects:
     *   - reads the checked-in fixture manifest from the repository root when no explicit override
     *     is present
     * - Failure modes:
     *   - records an XCTest failure when the manifest cannot be read or the current test name
     *     cannot be normalized into a manifest key
     */
    private func resolveFixtureScenario(
        environment: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        if let scenario = environment["UITEST_FIXTURE_SCENARIO"], !scenario.isEmpty {
            return scenario
        }

        guard let testIdentifier = currentFixtureManifestTestIdentifier(file: file, line: line),
              let manifestURL = resolveRepositoryRootURL(file: file, line: line)?
                .appendingPathComponent("scripts", isDirectory: true)
                .appendingPathComponent("ui_test_fixture_manifest.json", isDirectory: false) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode([String: String].self, from: data)
            if let scenario = manifest[testIdentifier] {
                return scenario
            }
            XCTFail(
                "Fixture manifest is missing an entry for '\(testIdentifier)'.",
                file: file,
                line: line
            )
            return nil
        } catch {
            XCTFail(
                "Unable to load fixture manifest at '\(manifestURL.path)': \(error)",
                file: file,
                line: line
            )
            return nil
        }
    }

    /**
     Resolves the built host-side fixture tool path.
     *
     * Resolution order:
     * - explicit `UITEST_FIXTURE_TOOL_PATH` host environment override
     * - `.build/debug/UITestFixtureTool`
     * - architecture-specific `.build/<triple>/debug/UITestFixtureTool`
     *
     * - Parameters:
     *   - environment: Current XCTest host environment.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Absolute executable path for the fixture tool.
     * - Side effects:
     *   - probes the repository-local SwiftPM build outputs for the fixture tool binary
     * - Failure modes:
     *   - records an XCTest failure when the fixture tool cannot be resolved
     */
    private func resolveFixtureToolPath(
        environment: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        if let fixtureToolPath = environment["UITEST_FIXTURE_TOOL_PATH"], !fixtureToolPath.isEmpty {
            return fixtureToolPath
        }

        guard let repoRootURL = resolveRepositoryRootURL(file: file, line: line) else {
            return nil
        }

        let candidateURLs = [
            repoRootURL.appendingPathComponent(".build/debug/UITestFixtureTool", isDirectory: false),
            repoRootURL.appendingPathComponent(".build/arm64-apple-macosx/debug/UITestFixtureTool", isDirectory: false),
            repoRootURL.appendingPathComponent(".build/x86_64-apple-macosx/debug/UITestFixtureTool", isDirectory: false),
        ]

        if let candidate = candidateURLs.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return candidate.path
        }

        XCTFail(
            "Unable to resolve UITestFixtureTool in \(candidateURLs.map(\.path).joined(separator: ", ")).",
            file: file,
            line: line
        )
        return nil
    }

    /**
     Resolves the canonical fixture-manifest key for the current XCTest method.
     *
     * - Parameters:
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Manifest key shaped like `AndBibleUITests/AndBibleUITests/testExample`.
     * - Side effects: none.
     * - Failure modes:
     *   - records an XCTest failure when the XCTest name cannot be normalized
     */
    private func currentFixtureManifestTestIdentifier(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        let rawName = name
        guard let methodName = rawName.split(separator: " ").last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "]")),
              methodName.hasPrefix("test") else {
            XCTFail(
                "Unable to derive fixture manifest identifier from XCTest name '\(rawName)'.",
                file: file,
                line: line
            )
            return nil
        }
        return "AndBibleUITests/AndBibleUITests/\(methodName)"
    }

    /**
     Resolves the repository root from the checked-in UI-test source file path.
     *
     * - Parameters:
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Absolute repository root URL.
     * - Side effects: none.
     * - Failure modes:
     *   - records an XCTest failure when the source path cannot be normalized
     */
    private func resolveRepositoryRootURL(
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> URL? {
        let fileURL = URL(fileURLWithPath: String(describing: file), isDirectory: false)
        let repoRootURL = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = repoRootURL
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("ui_test_fixture_manifest.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            XCTFail(
                "Unable to resolve repository root from '\(fileURL.path)'; missing '\(manifestURL.path)'.",
                file: file,
                line: line
            )
            return nil
        }
        return repoRootURL
    }

    /**
     Resolves the installed simulator app data container for the current test run.
     *
     * - Parameters:
     *   - simulatorID: Target simulator UDID.
     *   - bundleIdentifier: Bundle identifier of the app under test.
     *   - timeout: Maximum time to keep retrying `simctl get_app_container`.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Absolute data-container path, or `nil` after recording a failure.
     * - Side effects:
     *   - polls the simulator host for the installed app container while xcodebuild finishes
     *     test-run installation
     * - Failure modes:
     *   - records an XCTest failure when no installed app container can be resolved before timeout
     */
    private func resolveInstalledAppDataContainer(
        simulatorID: String,
        bundleIdentifier: String,
        timeout: TimeInterval,
        recordFailure: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError = ""

        repeat {
            let result = runHostProcess(
                executablePath: "/usr/bin/xcrun",
                arguments: ["simctl", "get_app_container", simulatorID, bundleIdentifier, "data"],
                timeout: 10
            )
            let trimmedPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.status == 0, !trimmedPath.isEmpty {
                return trimmedPath
            }
            if let fallbackPath = resolveInstalledAppDataContainerFromListApps(
                simulatorID: simulatorID,
                bundleIdentifier: bundleIdentifier
            ) {
                return fallbackPath
            }
            lastError = result.stderr.isEmpty ? result.stdout : result.stderr
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline

        if recordFailure {
            XCTFail(
                "Unable to resolve app data container for '\(bundleIdentifier)' on simulator '\(simulatorID)' within \(timeout) seconds.\nLast host output:\n\(lastError)",
                file: file,
                line: line
            )
        }
        return nil
    }

    /**
     Falls back to `simctl listapps` when `get_app_container` is temporarily stale.
     *
     * CoreSimulator can already know the installed app metadata, including `DataContainer`, even
     * while `get_app_container ... data` is still returning an empty result during early
     * installation windows.
     *
     * - Parameters:
     *   - simulatorID: Target simulator UDID.
     *   - bundleIdentifier: Bundle identifier of the app under test.
     * - Returns: Absolute data-container path when `listapps` reports one, otherwise `nil`.
     * - Side effects:
     *   - runs `xcrun simctl listapps` on the host and parses the OpenStep property-list output
     * - Failure modes: This helper does not fail directly.
     */
    private func resolveInstalledAppDataContainerFromListApps(
        simulatorID: String,
        bundleIdentifier: String
    ) -> String? {
        let result = runHostProcess(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "listapps", simulatorID, bundleIdentifier],
            timeout: 10
        )
        guard result.status == 0 else {
            return nil
        }
        let escapedIdentifier = NSRegularExpression.escapedPattern(for: bundleIdentifier)
        let pattern = #"(?s)""# + escapedIdentifier + #""\s*=\s*\{.*?DataContainer\s*=\s*"([^"]+)";"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: result.stdout,
                  range: NSRange(result.stdout.startIndex..., in: result.stdout)
              ),
              let containerRange = Range(match.range(at: 1), in: result.stdout),
              let url = URL(string: String(result.stdout[containerRange])) else {
            return nil
        }

        return url.path
    }

    /**
     Runs one host-side subprocess from the macOS XCTest runner and captures its output.
     *
     * - Parameters:
     *   - executablePath: Absolute executable path to run.
     *   - arguments: CLI arguments excluding the executable itself.
     *   - timeout: Maximum time to wait before terminating the subprocess.
     * - Returns: Exit status plus captured stdout/stderr text.
     * - Side effects:
     *   - spawns one host-side child process from the XCTest runner
     *   - terminates the child process when it exceeds the timeout budget
     * - Failure modes:
     *   - returns `-1` when the subprocess cannot be launched
     *   - returns `-2` when the subprocess is terminated after exceeding the timeout budget
     */
    private func runHostProcess(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> (status: Int32, stdout: String, stderr: String) {
        var stdoutPipe: [Int32] = [0, 0]
        var stderrPipe: [Int32] = [0, 0]
        guard pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            return (-1, "", "Failed to create host-process pipes.")
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&fileActions, stderrPipe[0])

        let command = [executablePath] + arguments
        let cArguments = command.map { strdup($0) }
        defer { cArguments.forEach { free($0) } }
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: cArguments.count + 1)
        defer { argv.deallocate() }
        for (index, pointer) in cArguments.enumerated() {
            argv[index] = pointer
        }
        argv[cArguments.count] = nil

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executablePath, &fileActions, nil, argv, nil)
        close(stdoutPipe[1])
        close(stderrPipe[1])
        if spawnStatus != 0 {
            let stderr = String(cString: strerror(spawnStatus))
            close(stdoutPipe[0])
            close(stderrPipe[0])
            return (-1, "", "Failed to launch \(executablePath): \(stderr)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        var waitStatus: Int32 = 0
        var timedOut = false
        while true {
            let waitResult = waitpid(pid, &waitStatus, WNOHANG)
            if waitResult == pid {
                break
            }
            if Date() >= deadline {
                timedOut = true
                kill(pid, SIGKILL)
                _ = waitpid(pid, &waitStatus, 0)
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        let stdout = readAll(from: stdoutPipe[0])
        let stderr = readAll(from: stderrPipe[0])
        close(stdoutPipe[0])
        close(stderrPipe[0])

        if timedOut {
            return (-2, stdout, stderr)
        }
        let terminatingSignal = waitStatus & 0x7f
        if terminatingSignal == 0 {
            return ((waitStatus >> 8) & 0xff, stdout, stderr)
        }
        if terminatingSignal != 0 {
            return (-3, stdout, stderr.isEmpty ? "Process terminated by signal \(terminatingSignal)." : stderr)
        }
        return (-4, stdout, stderr)
    }

    /**
     Reads all currently available UTF-8 text from one file descriptor.
     *
     * - Parameter fileDescriptor: Open descriptor positioned at the start of the captured stream.
     * - Returns: Best-effort UTF-8 decoded contents.
     * - Side effects:
     *   - drains the descriptor until EOF
     * - Failure modes:
     *   - returns an empty string when the descriptor cannot be read or the bytes are not valid
     *     UTF-8
     */
    private func readAll(from fileDescriptor: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead <= 0 {
                break
            }
            data.append(buffer, count: bytesRead)
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    /**
     Opens Search from the real reader toolbar.
     *
     * - Parameters:
     *   - app: Running application under test.
     * - Returns: The visible Search screen root element.
     * - Side effects:
     *   - opens Search through the stable reader action surface
     *   - when `makeApp(searchQuery:)` supplied one query, types it into the live Search field
     * - Failure modes:
     *   - fails when the Search screen never appears
     */
    private func openSearch(in app: XCUIApplication) -> XCUIElement {
        if app.launchArguments.contains("-UITEST_SEARCH_QUERY"),
           let prePresentedSearch = waitForSearchScreenIfAlreadySeeded(in: app, timeout: 10) {
            waitForSearchInteractionReady(on: prePresentedSearch, in: app, timeout: 120)
            return prePresentedSearch
        }

        tapReaderSearchEntry(in: app, timeout: 15)
        let searchScreen = requireSearchScreen(in: app, timeout: 20)
        waitForSearchInteractionReady(on: searchScreen, in: app, timeout: 120)
        return searchScreen
    }

    /// Reuses a Search sheet that the app auto-presented from a launch-seeded UI-test query.
    private func waitForSearchScreenIfAlreadySeeded(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let searchState = resolvedSearchStateElement(in: app) {
                return searchState
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return nil
    }

    /**
     Opens Search from the most stable production reader affordance available on the current shell.
     *
     * Search can appear both as a direct toolbar button and as a drawer action. The UI harness
     * should prefer the direct toolbar button when it is already visible instead of forcing the
     * drawer path and paying the extra surface-recovery cost.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - taps the direct toolbar Search action when it is already visible on the reader shell
     *   - otherwise falls back to the shared reader-action routing helper
     * - Failure modes:
     *   - records an XCTest failure if neither the direct button nor the routed action can be
     *     opened within the allotted timeout
     */
    private func tapReaderSearchEntry(
        in app: XCUIApplication,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if waitForReaderShellReady(in: app, timeout: min(10, timeout)),
           resolvedElement("readerNavigationDrawer", in: app) == nil,
           resolvedElement("readerOverflowMenu", in: app) == nil
        {
            let directCandidates = [
                app.buttons["readerOpenSearchAction"].firstMatch,
                app.buttons["Search"].firstMatch,
            ]

            if let directButton = directCandidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
                tapElementReliably(directButton, timeout: timeout, file: file, line: line)
                return
            }
        }

        tapReaderAction("readerOpenSearchAction", in: app, timeout: timeout, file: file, line: line)
    }

    /**
     Resolves the root Search screen element without forcing XCTest through incorrect typed queries.
     *
     * SwiftUI can expose this surface as different automation classes across runtimes, so Search
     * must not go through the generic identifier resolver that still reasons in terms of buttons,
     * links, or scroll views. This helper only asks XCTest for any element carrying the stable
     * `searchScreen` identifier and returns the first live match.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first live Search root node exporting the `searchScreen` identifier.
     * - Side effects:
     *   - polls the live accessibility hierarchy until Search is presented
     * - Failure modes:
     *   - records an XCTest failure if Search never presents a root node within the timeout
     */
    private func requireSearchScreen(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let stateElement = resolvedSearchStateElement(in: app) {
                return stateElement
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let screen = unresolvedElement("searchStateExport", in: app)
        XCTAssertTrue(
            screen.exists,
            "Expected Search to present the exported Search state element within \(timeout) seconds.",
            file: file,
            line: line
        )
        return screen
    }

    /**
     Waits for the Search screen to report that its current query is no longer in flight.
     *
     * - Parameters:
     *   - searchScreen: Search root element exporting deterministic state in its accessibility
     *     value.
     *   - timeout: Maximum time to wait for the `state=ready;searching=false` state.
     * - Side effects:
     *   - blocks the current XCTest method until the search state reports ready completion or
     *     times out
     * - Failure modes:
     *   - fails the test if the Search screen never reports `state=ready;searching=false`
     *     before the timeout
     */
    private func waitForSearchToFinish(in app: XCUIApplication, timeout: TimeInterval) {
        waitForSearchState(containing: "", in: app, timeout: timeout)
    }

    /**
     Waits for Search to become interactive and triggers index creation when the screen reports
     that the active module needs one.
     *
     * - Parameters:
     *   - searchScreen: Search root element exporting deterministic state in its accessibility
     *     value.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the Search accessibility value until it reports `state=ready`
     *   - taps the visible `Create` button when Search reports `state=needsIndex`
     * - Failure modes:
     *   - records an XCTest failure if Search never becomes interactive within the timeout window
     */
    private func waitForSearchInteractionReady(
        on searchScreen: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let state = resolvedSearchStateValue(in: app) ?? (searchScreen.value as? String ?? "")
            if state.contains("state=ready") {
                return
            }
            let createButton = resolveSearchCreateIndexButton(in: app)
            if state.contains("state=needsIndex")
                || createButton.exists
                || createButton.waitForExistence(timeout: 0.2)
            {
                tapElementReliably(createButton, timeout: 10, file: file, line: line)
                continue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        XCTFail(
            "Expected Search to become interactive within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Waits for the Search screen to report a settled state containing one expected semantic token.
     *
     * - Parameters:
     *   - token: State fragment expected once the current search rerun has completed.
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for `state=ready;searching=false` with the requested token.
     * - Side effects:
     *   - re-resolves the live `searchScreen` element until its accessibility value reports the
     *     requested settled state or the timeout expires
     * - Failure modes:
     *   - fails the test if the Search screen never reaches the requested settled state
     */
    private func waitForSearchState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = resolvedSearchStateValue(in: app),
               value.contains("state=ready"),
               value.contains("searching=false"),
               value.contains(token) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        let lastValue = resolvedSearchStateValue(in: app) ?? "nil"
        XCTFail(
            "Expected Search state to contain '\(token)' within \(timeout) seconds; last value was '\(lastValue)'."
        )
    }

    /**
     Waits for Search to report at least one settled result row count.
     *
     * - Parameters:
     *   - minimumCount: Inclusive lower bound for the exported `results=` count.
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait before failing.
     * - Side effects:
     *   - polls the Search accessibility export until it reports `state=ready;searching=false`
     *     with a parsed result count at or above `minimumCount`
     * - Failure modes:
     *   - fails the test if Search never publishes a large-enough settled count
     */
    private func waitForSearchResultCount(
        atLeast minimumCount: Int,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = resolvedSearchStateValue(in: app),
               value.contains("state=ready"),
               value.contains("searching=false"),
               let count = searchResultCount(from: value),
               count >= minimumCount {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline

        let lastValue = resolvedSearchStateValue(in: app) ?? "nil"
        XCTFail(
            "Expected Search to report at least \(minimumCount) results within \(timeout) seconds; last value was '\(lastValue)'."
        )
    }

    /// Parses the deterministic `results=` token from Search accessibility state.
    private func searchResultCount(from state: String) -> Int? {
        guard let range = state.range(of: "results=") else { return nil }
        let suffix = state[range.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// Taps the first visible module row inside the real module picker sheet.
    private func tapFirstModulePickerRow(
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let screen = requireElement("modulePickerScreen", in: app, timeout: timeout, file: file, line: line)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let button = screen.buttons.element(boundBy: 0)
            if button.exists {
                tapElementReliably(button, timeout: timeout, file: file, line: line)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail(
            "Expected module picker to expose at least one selectable module row within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Taps one visible button by its accessibility label and waits for it to become hittable.
     *
     * - Parameters:
     *   - label: Visible accessibility label expected on the target button.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the button to exist and become
     *     hittable.
     * - Side effects:
     *   - resolves the requested button from the visible button hierarchy and taps its center
     *     point directly
     * - Failure modes:
     *   - fails if the button never appears or never becomes hittable within the timeout
     */
    private func tapButtonLabeled(
        _ label: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(
            button.waitForExistence(timeout: timeout),
            "Expected visible button '\(label)' to exist within \(timeout) seconds."
        )
        tapElementReliably(button, timeout: timeout)
    }

    /**
     Taps one Search scope button through its stable accessibility identifier.
     *
     * - Parameters:
     *   - scopeToken: Stable Search scope token exported by `SearchView`.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the scope button to exist and become
     *     hittable.
     * - Side effects:
     *   - resolves the requested Search scope button from the accessibility hierarchy and taps
     *     its center point directly
     * - Failure modes:
     *   - fails if the requested scope button never appears or never becomes hittable within the
     *     allotted timeout
     */
    private func tapSearchScope(
        _ scopeToken: SearchScopeToken,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        let identifier = "searchScopeButton::\(scopeToken.rawValue)"

        while Date() < deadline {
            dismissSearchFieldFocusIfNeeded(in: app)
            revealSearchControls(in: app)

            let searchScreen = unresolvedElement("searchScreen", in: app)
            let scopeStrip = resolvedElement("searchScopeStrip", in: app)
                ?? searchScreen.scrollViews["searchScopeStrip"].firstMatch
            let candidates = [
                scopeStrip.buttons[identifier].firstMatch,
                scopeStrip.otherElements[identifier].firstMatch,
                searchScreen.buttons[identifier].firstMatch,
                searchScreen.otherElements[identifier].firstMatch,
            ]

            if let identifierElement = candidates.first(where: {
                ($0.exists || $0.waitForExistence(timeout: 0.2))
                    && waitForElementToBecomeHittable($0, timeout: 0.5)
            }) {
                identifierElement.tap()
                return
            }

            if scopeStrip.exists, !scopeStrip.frame.isEmpty {
                if let candidate = candidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
                    if candidate.frame.minX < scopeStrip.frame.minX {
                        scopeStrip.swipeRight()
                    } else {
                        scopeStrip.swipeLeft()
                    }
                } else {
                    scopeStrip.swipeLeft()
                    scopeStrip.swipeRight()
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail("Expected Search scope button '\(scopeToken.fallbackLabel)' to exist within \(timeout) seconds.")
    }

    /**
     Taps one Search word-mode control while staying scoped to the live Search screen.
     *
     * - Parameters:
     *   - label: Visible segmented-control label, such as `Phrase` or `Any Word`.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     * - Side effects:
     *   - resolves the mode control from Search's visible hierarchy and taps it directly
     * - Failure modes:
     *   - fails if the requested mode control never appears on Search within the timeout
     */
    private func tapSearchWordMode(
        _ label: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            dismissSearchFieldFocusIfNeeded(in: app)
            revealSearchControls(in: app)
            let searchScreen = unresolvedElement("searchScreen", in: app)

            if let segmentIndex = searchWordModeSegmentIndex(forVisibleLabel: label),
               let picker = [
                   searchScreen.segmentedControls["searchWordModePicker"].firstMatch,
                   searchScreen.segmentedControls.firstMatch,
                   searchScreen.otherElements["searchWordModePicker"].firstMatch,
               ].first(where: { $0.exists || $0.waitForExistence(timeout: 0.2) })
            {
                tapSegmentedControlSegment(
                    picker,
                    index: segmentIndex,
                    segmentCount: SearchWordModeControl.segmentCount,
                    timeout: timeout
                )
                return
            }

            if let token = searchWordModeToken(forVisibleLabel: label) {
                let identifierCandidates = [
                    searchScreen.buttons["searchWordModeButton::\(token)"].firstMatch,
                    searchScreen.otherElements["searchWordModeButton::\(token)"].firstMatch,
                ]
                for candidate in identifierCandidates where candidate.exists || candidate.waitForExistence(timeout: 0.2) {
                    tapElementReliably(candidate, timeout: timeout)
                    return
                }
            }

            let fallbackCandidates = [
                searchScreen.segmentedControls.buttons[label].firstMatch,
                searchScreen.buttons[label].firstMatch,
            ]
            for candidate in fallbackCandidates where candidate.exists || candidate.waitForExistence(timeout: 0.2) {
                tapElementReliably(candidate, timeout: timeout)
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail("Expected Search mode button '\(label)' to exist within \(timeout) seconds.")
    }

    /**
     Maps one visible Search word-mode label to the stable accessibility token exported by Search.
     *
     * - Parameter label: Visible segmented-control label used by the UI test.
     * - Returns: Stable production token for the requested label, or `nil` when the label is
     *   unknown to the test harness.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func searchWordModeToken(forVisibleLabel label: String) -> String? {
        switch label {
        case "All Words":
            return "allWords"
        case "Any Word":
            return "anyWord"
        case "Phrase":
            return "phrase"
        default:
            return nil
        }
    }

    /**
     Maps one visible Search word-mode label to its deterministic segment index within the Search
     segmented control.
     *
     * - Parameter label: Visible segmented-control label used by the UI test.
     * - Returns: Zero-based segment index for the requested label, or `nil` when the label is
     *   unknown to the test harness.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func searchWordModeSegmentIndex(forVisibleLabel label: String) -> Int? {
        switch label {
        case "All Words":
            return 0
        case "Any Word":
            return 1
        case "Phrase":
            return 2
        default:
            return nil
        }
    }

    /**
     Reveals Search option controls that may be hidden behind the active search field or list
     scroll position.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - swipes the Search results container or another visible scrollable Search surface
     *     downward to bring scope controls back into view
     * - Failure modes:
     *   - falls back to a brief run-loop advance when no visible Search scroll surface exists
     */
    private func revealSearchControls(in app: XCUIApplication) {
        let searchScreen = unresolvedElement("searchScreen", in: app)
        let optionsPanel = searchScreen.otherElements["searchOptionsPanel"].firstMatch
        if optionsPanel.exists || optionsPanel.waitForExistence(timeout: 0.2) {
            return
        }

        let optionsToggle = app.buttons["searchOptionsToggleButton"].firstMatch
        if optionsToggle.exists || optionsToggle.waitForExistence(timeout: 0.2) {
            let toggleValue = String(describing: optionsToggle.value ?? "")
            if toggleValue.localizedCaseInsensitiveContains("hidden") {
                tapElementReliably(optionsToggle, timeout: 5)
                if optionsPanel.waitForExistence(timeout: 2) {
                    return
                }
            }
        }
        let scrollableCandidates: [XCUIElement] = [
            unresolvedElement("searchResultsList", in: app),
            searchScreen.collectionViews["searchResultsList"].firstMatch,
            searchScreen.collectionViews.firstMatch,
            searchScreen.tables.firstMatch,
            searchScreen.scrollViews.firstMatch,
        ]

        if let visibleScrollable = scrollableCandidates.first(where: {
            $0.exists && !$0.frame.isEmpty
        }) {
            for _ in 0..<2 {
                visibleScrollable.swipeDown()
                if optionsPanel.exists || optionsPanel.waitForExistence(timeout: 0.5) {
                    return
                }
            }
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    /**
     Moves focus away from the active Search field so the lower Search option rows can surface.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - uses one visible keyboard dismissal action when the software keyboard remains presented
     *     after query submission
     * - Failure modes:
     *   - silently leaves focus unchanged when no keyboard dismissal action is available
     */
    private func dismissSearchFieldFocusIfNeeded(in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists || keyboard.waitForExistence(timeout: 0.2) else {
            return
        }

        dismissKeyboardIfPresent(in: app)
        guard keyboard.exists else {
            return
        }
        let searchScreen = unresolvedElement("searchScreen", in: app)
        let dismissalCandidates = [
            searchScreen.buttons["searchWordModeButton::allWords"].firstMatch,
            searchScreen.otherElements["searchWordModeButton::allWords"].firstMatch,
            searchScreen.segmentedControls["searchWordModePicker"].buttons["All Words"].firstMatch,
            searchScreen.segmentedControls.buttons["All Words"].firstMatch,
            searchScreen.buttons["All Words"].firstMatch
        ]
        for candidate in dismissalCandidates where candidate.exists && !candidate.frame.isEmpty {
            tapElementReliably(candidate, timeout: 5)
            return
        }

        let pickerCandidates = [
            searchScreen.segmentedControls["searchWordModePicker"].firstMatch,
            searchScreen.segmentedControls.firstMatch,
            searchScreen.otherElements["searchWordModePicker"].firstMatch,
        ]
        if let picker = pickerCandidates.first(where: { $0.exists || $0.waitForExistence(timeout: 0.2) }) {
            tapSegmentedControlSegment(
                picker,
                index: 0,
                segmentCount: SearchWordModeControl.segmentCount,
                timeout: 5
            )
        }
    }

    /**
     Waits for the visible Search input control to retain one expected query string.
     *
     * - Parameters:
     *   - expectedQuery: Query string expected to remain in the Search field after opening Search.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the live Search field until its accessibility value contains `expectedQuery`
     * - Failure modes:
     *   - records an XCTest failure if the Search field never exposes the expected query before
     *     timeout
     */
    private func waitForSearchQuery(
        _ expectedQuery: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let searchScreen = requireSearchScreen(in: app, timeout: timeout, file: file, line: line)

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let currentValue = resolvedSearchInputValue(in: app)
            let currentState = searchScreen.value as? String ?? ""
            if currentValue.contains(expectedQuery)
                || currentState.contains("query=\(expectedQuery)")
            {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalValue = resolvedSearchInputValue(in: app)
        let finalState = searchScreen.value as? String ?? ""
        XCTAssertTrue(
            finalValue.contains(expectedQuery) || finalState.contains("query=\(expectedQuery)"),
            "Expected Search to contain query '\(expectedQuery)' within \(timeout) seconds. Field value: '\(finalValue)'. Screen state: '\(finalState)'.",
            file: file,
            line: line
        )
    }

    /**
     Waits for one deterministic Search result row to either appear or disappear.
     *
     * - Parameters:
     *   - identifier: Stable result-row accessibility identifier.
     *   - app: Running application under test.
     *   - shouldExist: Whether the result row is expected to exist by the timeout.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the live XCUI hierarchy until the requested row reaches the requested existence
     *     state
     * - Failure modes:
     *   - records an XCTest failure if the row never reaches the requested existence state
     */
    private func waitForSearchResultRow(
        _ identifier: String,
        in app: XCUIApplication,
        shouldExist: Bool,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        let rowToken = "|\(identifier)|"

        repeat {
            if let value = resolvedSearchStateValue(in: app),
               value.contains("state=ready"),
               value.contains("searching=false"),
               value.contains(rowToken) == shouldExist {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalValue = resolvedSearchStateValue(in: app) ?? ""
        XCTAssertEqual(
            finalValue.contains(rowToken),
            shouldExist,
            "Expected Search result '\(identifier)' existence to become \(shouldExist) within \(timeout) seconds. Final Search state: '\(finalValue)'.",
            file: file,
            line: line
        )
    }

    /**
     Extracts the exported numeric result count from the Search accessibility state token.
     *
     * - Parameter searchState: Semicolon-delimited Search screen state string.
     * - Returns: Parsed result count, or `-1` when the token is missing or malformed.
     * - Side effects: none.
     * - Failure modes:
       - returns `-1` when the Search screen accessibility export changes shape unexpectedly
     */
    private func searchResultsCount(from searchState: String) -> Int {
        guard let resultsToken = searchState
            .split(separator: ";")
            .first(where: { $0.hasPrefix("results=") }) else {
            return -1
        }
        return Int(resultsToken.dropFirst("results=".count)) ?? -1
    }

    /**
     Resolves the first tappable Search result row exported by the current Search screen.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the first result row to materialize.
     * - Returns: First matching Search result row element.
     * - Side effects:
     *   - queries the live accessibility hierarchy for any identifier prefixed with
     *     `searchResultRow::`
     * - Failure modes:
     *   - fails when the Search screen exports no tappable result rows before the timeout
     */
    private func requireFirstSearchResultRow(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement {
        let results = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "searchResultRow::")
        )
        let firstMatch = results.firstMatch
        XCTAssertTrue(
            firstMatch.waitForExistence(timeout: timeout),
            "Expected at least one search result row within \(timeout) seconds."
        )
        return firstMatch
    }


    /**
     Opens the workspace selector from the reader action surface.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified workspace selector screen element.
     * - Side effects:
     *   - resolves the production reader action surface and pushes the workspace selector
     * - Failure modes:
     *   - fails when the workspace selector screen never appears
     */
    private func openWorkspaceSelector(in app: XCUIApplication) -> XCUIElement {
        tapReaderAction("readerOpenWorkspacesAction", in: app)
        return requireElement("workspaceSelectorAddButton", in: app, timeout: 15)
    }

    /**
     Opens Label Manager through Settings navigation.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Label Manager screen element.
     * - Side effects:
     *   - opens Settings and pushes the Label Manager screen
     * - Failure modes:
     *   - fails when the Label Manager screen never appears
     */
    private func openLabelManager(in app: XCUIApplication) -> XCUIElement {
        openSettingsDestination(
            linkIdentifier: "settingsLabelsLink",
            destinationIdentifier: "labelManagerScreen",
            readinessIdentifiers: ["labelManagerAddButton"],
            in: app,
            destinationTimeout: 20
        )
    }

    /**
     Opens Label Assignment from the bookmark list.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Label Assignment screen element.
     * - Side effects:
     *   - opens the bookmark list and taps the seeded bookmark's edit-labels affordance
     * - Failure modes:
     *   - fails when the Label Assignment screen never appears
     */
    private func openLabelAssignment(in app: XCUIApplication) -> XCUIElement {
        return openLabelAssignmentFromBookmarkList(in: app)
    }

    /**
     Opens Label Assignment from the actual bookmark-list flow.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Label Assignment screen element.
     * - Side effects:
     *   - opens the reader overflow menu and pushes the bookmark list
     *   - taps the seeded bookmark row's real edit-label affordance
     * - Failure modes:
     *   - fails when the bookmark list or seeded bookmark edit-labels action never appears
     */
    private func openLabelAssignmentFromBookmarkList(in app: XCUIApplication) -> XCUIElement {
        _ = openBookmarkList(in: app)
        tapElementReliably(
            requireElement("bookmarkListEditLabelsButton::Genesis_1_1", in: app, timeout: 10),
            timeout: 10
        )
        return requireElement("labelAssignmentScreen", in: app, timeout: 10)
    }

    /**
     Opens the bookmark list from the reader shell.
     *
     * - Parameter app: Running application whose reader shell should present the bookmark list.
     * - Returns: The root accessibility-identified bookmark list element.
     * - Side effects:
     *   - opens the reader overflow menu and pushes the bookmark list
     * - Failure modes:
     *   - fails if the reader menu button, bookmark action, or bookmark list root never appears
     */
    @discardableResult
    private func openBookmarkList(
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> XCUIElement {
        openReaderActionDestination(
            actionIdentifier: "readerOpenBookmarksAction",
            destinationIdentifier: "bookmarkListScreen",
            readinessIdentifiers: ["bookmarkListDoneButton", "bookmarkListSortMenu"],
            in: app,
            timeout: timeout
        )
    }

    /**
     Dismisses the bookmark list and reopens it from the reader shell.
     *
     * - Parameter app: Running application whose bookmark sheet should be reopened.
     * - Side effects:
     *   - dismisses the bookmark sheet through the real Done button when available and falls back
     *     to a top-edge sheet drag gesture otherwise
     *   - opens the bookmark list again through the standard reader navigation path
     * - Failure modes:
     *   - fails when the bookmark list cannot be dismissed or reopened
     */
    private func reopenBookmarkList(in app: XCUIApplication) {
        let doneButton = app.buttons["bookmarkListDoneButton"].firstMatch
        if doneButton.exists || doneButton.waitForExistence(timeout: 2) {
            tapElementReliably(doneButton, timeout: 10)
        } else {
            dismissSheetByDraggingDown(requireElement("bookmarkListScreen", in: app, timeout: 10))
        }
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected bookmark list dismissal to return to the reader shell."
        )
        _ = openBookmarkList(in: app, timeout: 20)
    }

    /**
     Activates one bookmark-list filter chip and waits for the exported bookmark-list state to
     report the matching selected label.
     *
     * - Parameters:
     *   - labelToken: Sanitized label token exported in the chip identifier and screen state.
     *   - app: Running application whose bookmark list should change filters.
     *   - timeout: Maximum number of seconds to wait for the selected-label state update.
     * - Side effects:
     *   - taps the production filter chip and waits for the bookmark-list screen state to settle
     * - Failure modes:
     *   - fails if the chip is unavailable or the bookmark-list state never reflects the selection
     */
    private func selectBookmarkListFilterChip(
        _ labelToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        tapElementReliably(
            requireElement("bookmarkListFilterChip::\(labelToken)", in: app, timeout: timeout),
            timeout: timeout
        )
        waitForBookmarkListState(containing: "selectedLabel=\(labelToken)", in: app, timeout: timeout)
    }

    /**
     Waits for the bookmark-list screen accessibility state to contain one token.
     *
     * - Parameters:
     *   - token: State fragment expected from the exported bookmark-list accessibility value.
     *   - app: Running application whose bookmark list should reach the requested state.
     *   - timeout: Maximum number of seconds to wait before failing.
     * - Side effects:
     *   - polls the bookmark-list screen accessibility export until the requested token appears
     * - Failure modes:
     *   - records an XCTest failure if the bookmark-list state never contains the token
     */
    private func waitForBookmarkListState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        waitForElementValue("bookmarkListScreen", toContain: token, in: app, timeout: timeout)
    }

    /**
     Waits for the bookmark-list screen accessibility state to stop containing one token.
     *
     * - Parameters:
     *   - token: State fragment that should disappear from the exported bookmark-list value.
     *   - app: Running application whose bookmark list should drop the requested token.
     *   - timeout: Maximum number of seconds to wait before failing.
     * - Side effects:
     *   - polls the bookmark-list screen accessibility export until the requested token disappears
     * - Failure modes:
     *   - records an XCTest failure if the bookmark-list state keeps reporting the token
     */
    private func waitForBookmarkListState(
        notContaining token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        waitForElementValue("bookmarkListScreen", toNotContain: token, in: app, timeout: timeout)
    }

    /**
     Returns one bookmark-row token as serialized by the bookmark-list accessibility state.
     *
     * - Parameter referenceToken: Sanitized row reference token, such as `Genesis_1_1`.
     * - Returns: Bookmark-list row token wrapped in delimiters for exact containment checks.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func bookmarkListRowStateToken(_ referenceToken: String) -> String {
        "|\(referenceToken)|"
    }

    /**
     Returns one history-row token as serialized by the History screen accessibility state.
     *
     * - Parameter keyToken: Sanitized history key token, such as `Exod_2_1`.
     * - Returns: History row token wrapped in delimiters for exact containment checks.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func historyRowStateToken(_ keyToken: String) -> String {
        "|\(keyToken)|"
    }

    /**
     Waits for the History screen accessibility state to contain one token.
     *
     * - Parameters:
     *   - token: State fragment expected from the exported History accessibility value.
     *   - app: Running application whose History screen should reach the requested state.
     *   - timeout: Maximum number of seconds to wait before failing.
     * - Side effects:
     *   - polls the History screen accessibility export until the requested token appears
     * - Failure modes:
     *   - records an XCTest failure if the History state never contains the token
     */
    private func waitForHistoryState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        waitForElementValue("historyScreen", toContain: token, in: app, timeout: timeout)
    }

    /**
     Waits for the History screen accessibility state to stop containing one token.
     *
     * - Parameters:
     *   - token: State fragment that should disappear from the exported History value.
     *   - app: Running application whose History screen should drop the requested token.
     *   - timeout: Maximum number of seconds to wait before failing.
     * - Side effects:
     *   - polls the History screen accessibility export until the requested token disappears
     * - Failure modes:
     *   - records an XCTest failure if the History state keeps reporting the token
     */
    private func waitForHistoryState(
        notContaining token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        waitForElementValue("historyScreen", toNotContain: token, in: app, timeout: timeout)
    }

    /**
     Opens History from the reader shell.
     *
     * - Parameter app: Running application whose reader shell should present History.
     * - Returns: The root accessibility-identified History screen element.
     * - Side effects:
     *   - opens the reader overflow menu and pushes the History sheet
     * - Failure modes:
     *   - fails if the reader menu button, History action, or History screen root never appears
     */
    @discardableResult
    private func openHistory(in app: XCUIApplication) -> XCUIElement {
        openReaderActionDestination(
            actionIdentifier: "readerOpenHistoryAction",
            destinationIdentifier: "historyScreen",
            readinessIdentifiers: ["historyDoneButton", "historyClearButton", "historyEmptyState"],
            in: app
        )
    }

    /**
     Opens Downloads from the reader shell.
     *
     * - Parameter app: Running application whose reader shell should present Downloads.
     * - Returns: The root accessibility-identified downloads screen element.
     * - Side effects:
     *   - opens the reader overflow menu and pushes Downloads
     * - Failure modes:
     *   - fails if the reader menu button, downloads action, or downloads screen root never appears
     */
    private func openDownloads(in app: XCUIApplication) -> XCUIElement {
        openReaderActionDestination(
            actionIdentifier: "readerOpenDownloadsAction",
            destinationIdentifier: "moduleBrowserScreen",
            readinessIdentifiers: ["moduleBrowserRepositoriesButton"],
            in: app
        )
    }

    /**
     Opens Import and Export through Settings navigation.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Import and Export screen element.
     * - Side effects:
     *   - opens Settings and pushes the Import and Export screen
     * - Failure modes:
     *   - fails when the Import and Export screen never appears
     */
    private func openImportExport(in app: XCUIApplication) -> XCUIElement {
        openSettingsDestination(
            linkIdentifier: "settingsImportExportLink",
            destinationIdentifier: "importExportScreen",
            readinessIdentifiers: ["importExportImportButton", "importExportFullBackupButton"],
            in: app,
            destinationTimeout: 20
        )
    }

    /**
     Opens Sync Settings through Settings navigation.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Sync Settings screen element.
     * - Side effects:
     *   - opens Settings and pushes the Sync Settings screen
     * - Failure modes:
     *   - fails when the Sync Settings screen never appears
     */
    private func openSyncSettings(in app: XCUIApplication) -> XCUIElement {
        openSettingsDestination(
            linkIdentifier: "settingsSyncLink",
            destinationIdentifier: "syncSettingsScreen",
            readinessIdentifiers: ["syncBackendPicker", "syncRemoteStatus"],
            in: app,
            destinationTimeout: 20
        )
    }

    /**
     Opens one reader-overflow destination and waits for either its root or one of its stable
     ready controls.
     *
     * - Parameters:
     *   - actionIdentifier: Accessibility identifier of the reader action button.
     *   - destinationIdentifier: Accessibility identifier exported by the destination root.
     *   - readinessIdentifiers: Stable controls that prove the destination is usable even when the
     *     root view is materialized under a different XCUI type.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the destination to become usable.
     * - Returns: The resolved destination root when available, otherwise one ready control.
     * - Side effects:
     *   - opens the reader overflow menu and activates the requested production action
     * - Failure modes:
     *   - fails when neither the destination root nor any readiness control appears in time
     */
    @discardableResult
    private func openReaderActionDestination(
        actionIdentifier: String,
        destinationIdentifier: String,
        readinessIdentifiers: [String],
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) -> XCUIElement {
        let destination = unresolvedElement(destinationIdentifier, in: app)
        let readinessCandidates = [destinationIdentifier] + readinessIdentifiers

        for attempt in 1...2 {
            tapReaderAction(actionIdentifier, in: app, timeout: timeout)

            if waitForAnyElement(readinessCandidates, in: app, timeout: timeout) != nil {
                if let resolvedDestination = resolvedElement(destinationIdentifier, in: app) {
                    return resolvedDestination
                }
                if destination.exists || destination.waitForExistence(timeout: 1) {
                    return destination
                }
                if let readyElement = waitForAnyElement(readinessIdentifiers, in: app, timeout: 1) {
                    return readyElement
                }
            }

            if attempt == 1 {
                if readerActionUsesNavigationDrawer(actionIdentifier) {
                    if let dismissArea = resolvedElement("readerNavigationDrawerDismissArea", in: app) {
                        tapElementReliably(dismissArea, timeout: min(5, timeout))
                    }
                } else if resolvedElement("readerOverflowMenu", in: app) != nil {
                    dismissReaderOverflowMenu(
                        in: app,
                        timeout: min(8, timeout),
                        file: #filePath,
                        line: #line
                    )
                }
            }
        }

        XCTAssertTrue(
            destination.exists,
            "Expected destination '\(destinationIdentifier)' to appear after activating '\(actionIdentifier)'."
        )
        return destination
    }

    /**
     Opens Sync Settings directly from the reader action surface.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Sync Settings screen element.
     * - Side effects:
     *   - opens the reader overflow menu and presents Sync Settings directly from the reader shell
     * - Failure modes:
     *   - fails when the Sync Settings screen never appears
     */
    private func openSyncSettingsFromReaderAction(in app: XCUIApplication) -> XCUIElement {
        openReaderActionDestination(
            actionIdentifier: "readerOpenSyncSettingsAction",
            destinationIdentifier: "syncSettingsScreen",
            readinessIdentifiers: ["syncBackendPicker", "syncRemoteStatus"],
            in: app,
            timeout: 20
        )
    }

    /**
     Dismisses Sync Settings back to the reader shell.
     *
     * - Parameter app: Running application whose Sync sheet should be dismissed.
     * - Side effects:
     *   - taps the real Done button when the sheet exposes it
     *   - falls back to a top-edge drag gesture when the toolbar button is not present
     * - Failure modes:
     *   - fails when Sync Settings cannot be dismissed back to the reader shell
     */
    private func dismissSyncSettings(in app: XCUIApplication) {
        let syncScreen = requireElement("syncSettingsScreen", in: app, timeout: 10)
        let doneButton = app.buttons["syncSettingsDoneButton"].firstMatch
        if doneButton.exists || doneButton.waitForExistence(timeout: 2) {
            tapElementReliably(doneButton, timeout: 10)
        } else {
            dismissSheetByDraggingDown(syncScreen)
        }
        waitForElementToDisappear(syncScreen, timeout: 10)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected Sync Settings dismissal to return to the reader shell."
        )
    }

    /**
     Dismisses the Settings sheet back to the reader shell.
     *
     * - Parameter app: Running application whose Settings sheet should be dismissed.
     * - Side effects:
     *   - drags the production Settings form downward to close the sheet
     * - Failure modes:
     *   - fails when the Settings sheet cannot be dismissed back to the reader shell
     */
    private func dismissSettings(in app: XCUIApplication) {
        let settingsForm = requireElement("settingsForm", in: app, timeout: 10)
        dismissSheetByDraggingDown(settingsForm)
        waitForElementToDisappear(settingsForm, timeout: 10)
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 20),
            "Expected Settings dismissal to return to the reader shell."
        )
    }

    /**
     Switches Sync Settings to one backend through the production picker.
     *
     * - Parameters:
     *   - backendRawValue: Target backend raw value that should become active.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the switch control to resolve and become
     *     hittable.
     * - Side effects:
     *   - opens the backend picker and selects the requested production option
     * - Failure modes:
     *   - fails if no backend-switch control for the requested backend becomes available
     */
    private func tapSyncBackend(
        _ backendRawValue: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 15
    ) {
        let picker = requireElement("syncBackendPicker", in: app, timeout: timeout)
        tapElementReliably(picker, timeout: timeout)

        let optionIdentifier = "syncBackendOption::\(backendRawValue)"
        if let identifiedOption = resolvedElement(optionIdentifier, in: app),
           identifiedOption.exists
        {
            tapElementReliably(identifiedOption, timeout: timeout)
            return
        }

        let backendLabel: String = switch backendRawValue {
        case "GOOGLE_DRIVE":
            "Google Drive"
        case "NEXT_CLOUD":
            "NextCloud"
        default:
            backendRawValue
        }

        let option = resolveSyncBackendOption(named: backendLabel, in: app, timeout: timeout)
        XCTAssertTrue(
            option.waitForExistence(timeout: timeout),
            "Expected sync backend option '\(backendLabel)' to exist."
        )
        tapElementReliably(option, timeout: timeout)
    }

    /**
     Resolves the first live picker option for one Sync backend label across the system control
     presentations SwiftUI may choose on CI.
     *
     * - Parameters:
     *   - backendLabel: User-visible backend option label.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the first option candidate to appear.
     * - Returns: The first live picker-option candidate, preferring visible controls.
     * - Side effects:
     *   - probes multiple XCUI query families because SwiftUI `Picker` presentations may surface
     *     options as buttons, cells, static texts, or generic elements depending on platform state
     * - Failure modes:
     *   - returns an unresolved fallback query when no picker option becomes available before the
     *     timeout expires; the caller records the assertion failure
     */
    private func resolveSyncBackendOption(
        named backendLabel: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement {
        let candidates: [XCUIElement] = [
            app.sheets.buttons[backendLabel].firstMatch,
            app.sheets.staticTexts[backendLabel].firstMatch,
            app.alerts.buttons[backendLabel].firstMatch,
            app.alerts.staticTexts[backendLabel].firstMatch,
            app.collectionViews.buttons[backendLabel].firstMatch,
            app.collectionViews.staticTexts[backendLabel].firstMatch,
            app.tables.buttons[backendLabel].firstMatch,
            app.tables.staticTexts[backendLabel].firstMatch,
            app.buttons[backendLabel].firstMatch,
            app.cells[backendLabel].firstMatch,
            app.staticTexts[backendLabel].firstMatch,
            app.otherElements[backendLabel].firstMatch,
        ]

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let visible = candidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
                return visible
            }
            if let existing = candidates.first(where: { $0.exists }) {
                return existing
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return candidates[0]
    }

    /**
     Opens Colors through Settings navigation.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Colors screen element.
     * - Side effects:
     *   - opens Settings and pushes the Colors screen
     * - Failure modes:
     *   - fails when the Colors screen never appears
     */
    private func openColorSettings(in app: XCUIApplication) -> XCUIElement {
        openSettingsDestination(
            linkIdentifier: "settingsColorsLink",
            destinationIdentifier: "colorSettingsScreen",
            readinessIdentifiers: ["colorSettingsResetButton"],
            in: app,
            destinationTimeout: 20
        )
    }

    /**
     Opens Text Display through Settings navigation.
     *
     * - Parameter app: Running application under test.
     * - Returns: The root accessibility-identified Text Display screen element.
     * - Side effects:
     *   - opens Settings and pushes the Text Display screen
     * - Failure modes:
     *   - fails when the Text Display screen never appears
     */
    private func openTextDisplaySettings(in app: XCUIApplication) -> XCUIElement {
        openSettingsDestination(
            linkIdentifier: "settingsTextDisplayLink",
            destinationIdentifier: "textDisplaySettingsScreen",
            readinessIdentifiers: ["textDisplayFontFamilyButton"],
            in: app,
            destinationTimeout: 20
        )
    }

    /**
     Opens Settings from the reader shell action surface.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - resolves the stable reader action surface and pushes the Settings screen onto the
     *     navigation stack
     *   - dismisses the language restart alert only when it is already present after Settings loads
     * - Failure modes:
     *   - fails when the reader action surface or Settings action cannot be found
     *   - fails when the settings form never appears
     */
    private func openSettings(in app: XCUIApplication) {
        for attempt in 1...2 {
            if !waitForReaderShellReady(in: app, timeout: 20) {
                if attempt == 1 {
                    continue
                }
                break
            }

            tapReaderAction("readerOpenSettingsAction", in: app, timeout: 20)
            if waitForSettingsReady(in: app, timeout: 20) {
                return
            }
            if attempt == 1 {
                continue
            }
        }
        XCTFail("Expected the Settings screen to become ready after opening it from the reader menu.")
    }

    /**
     Resolves one settings navigation control from the production Settings form.
     *
     * - Parameters:
     *   - identifier: Production settings-row identifier requested by the test.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The production settings row element.
     * - Side effects:
     *   - scrolls the Settings form while re-querying the live XCUI hierarchy
     * - Failure modes:
     *   - records an XCTest failure if the production row never appears
     */
    private func requireSettingsNavigationControl(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let settingsForm = requireElement("settingsForm", in: app, timeout: timeout, file: file, line: line)
        let visibleTitle = settingsNavigationTitle(for: identifier)
        let deadline = Date().addingTimeInterval(timeout)
        func resolvedVisibleControl() -> XCUIElement? {
            var candidates = [
                settingsForm.links[identifier].firstMatch,
                settingsForm.buttons[identifier].firstMatch,
                settingsForm.cells[identifier].firstMatch,
                settingsForm.otherElements[identifier].firstMatch,
                app.links[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.cells[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]

            if let visibleTitle {
                candidates.insert(contentsOf: [
                    settingsForm.links[visibleTitle].firstMatch,
                    settingsForm.buttons[visibleTitle].firstMatch,
                    settingsForm.cells[visibleTitle].firstMatch,
                    settingsForm.otherElements[visibleTitle].firstMatch,
                    settingsForm.cells.containing(.staticText, identifier: visibleTitle).firstMatch,
                    settingsForm.otherElements.containing(.staticText, identifier: visibleTitle).firstMatch,
                    settingsForm.staticTexts[visibleTitle].firstMatch,
                    app.links[visibleTitle].firstMatch,
                    app.buttons[visibleTitle].firstMatch,
                    app.cells[visibleTitle].firstMatch,
                    app.otherElements[visibleTitle].firstMatch,
                    app.cells.containing(.staticText, identifier: visibleTitle).firstMatch,
                    app.staticTexts[visibleTitle].firstMatch,
                ], at: 0)
            }

            if let control = candidates.first(where: { $0.exists && waitForElementToBecomeHittable($0, timeout: 0.5) }) {
                return control
            }
            if let control = candidates.first(where: { $0.exists && isElementVisible($0, within: settingsForm) }) {
                return control
            }
            return nil
        }

        if visibleTitle != nil {
            for _ in 0..<3 {
                if let control = resolvedVisibleControl() {
                    return control
                }
                guard settingsForm.exists, !settingsForm.frame.isEmpty, Date() < deadline else {
                    break
                }
                settingsForm.swipeDown()
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            }
        }

        repeat {
            if let control = resolvedVisibleControl() {
                return control
            }
            guard settingsForm.exists, !settingsForm.frame.isEmpty else {
                break
            }

            settingsForm.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let control = unresolvedElement(identifier, in: app)
        if control.exists {
            return control
        }

        XCTAssertTrue(
            false,
            "Expected settings navigation control '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return control
    }

    /**
     Maps one production Settings row identifier to the English title rendered in UI tests.
     *
     * `makeApp()` forces `AppleLanguages=(en)` and `AppleLocale=en_US`, so these labels are stable
     * across local and CI runs even when SwiftUI does not surface the row identifiers through the
     * underlying `Form` hierarchy.
     *
     * - Parameter identifier: Stable production identifier used by the test helpers.
     * - Returns: The visible English title for the row, or `nil` when the identifier has no
     *   title-based fallback.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func settingsNavigationTitle(for identifier: String) -> String? {
        switch identifier {
        case "settingsDownloadsLink":
            "Downloads"
        case "settingsRepositoriesLink":
            "Repositories"
        case "settingsImportExportLink":
            "Import & Export"
        case "settingsSyncLink":
            "iCloud Sync"
        case "settingsLabelsLink":
            "Labels"
        case "settingsTextDisplayLink":
            "Text Display"
        case "settingsColorsLink":
            "Colors"
        default:
            nil
        }
    }

    /**
     Opens one Settings destination and retries the row tap once when hosted simulators leave the
     view on the Settings form after the first navigation attempt.
     *
     * - Parameters:
     *   - linkIdentifier: Accessibility identifier of the Settings row to activate.
     *   - destinationIdentifier: Accessibility identifier of the destination root screen.
     *   - app: Running application under test.
     *   - rowTimeout: Maximum number of seconds to wait for the Settings row to resolve.
     *   - destinationTimeout: Maximum number of seconds to wait for the destination screen.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved destination root element.
     * - Side effects:
     *   - opens Settings, taps the requested row, and retries the tap once when the first attempt
     *     leaves the UI on the Settings form
     * - Failure modes:
     *   - records an XCTest failure if the destination screen never appears after two attempts
     */
    private func openSettingsDestination(
        linkIdentifier: String,
        destinationIdentifier: String,
        readinessIdentifiers: [String] = [],
        in app: XCUIApplication,
        rowTimeout: TimeInterval = 20,
        destinationTimeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        openSettings(in: app)
        let destination = unresolvedElement(destinationIdentifier, in: app)
        let readinessCandidates = [destinationIdentifier] + readinessIdentifiers

        for attempt in 0..<2 {
            tapSettingsElement(linkIdentifier, in: app, timeout: rowTimeout, file: file, line: line)
            if waitForAnyElement(
                readinessCandidates,
                in: app,
                timeout: destinationTimeout,
                file: file,
                line: line
            ) != nil {
                if destination.exists || destination.waitForExistence(timeout: 1) {
                    return destination
                }
                if let readyElement = waitForAnyElement(
                    readinessIdentifiers,
                    in: app,
                    timeout: 1,
                    file: file,
                    line: line
                ) {
                    return readyElement
                }
            }

            if attempt == 0 {
                let settingsStillVisible =
                    waitForSettingsReady(in: app, timeout: 3) ||
                    unresolvedElement("settingsForm", in: app).exists
                if settingsStillVisible {
                    dismissSettings(in: app)
                    openSettings(in: app)
                    continue
                }
            }
        }

        XCTAssertTrue(
            destination.exists,
            "Expected Settings destination '\(destinationIdentifier)' to appear after activating '\(linkIdentifier)'.",
            file: file,
            line: line
        )
        return destination
    }

    /**
     Produces the minimal ordered set of XCUI queries for one accessibility identifier.
     *
     * This helper is intentionally explicit for recurring screen/container roots. The earlier
     * generic "try every XCUI type" approach was the main source of CI flakiness because it could
     * resolve the wrong class for a screen root and force XCTest into very expensive cross-type
     * snapshot evaluation.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier to resolve.
     *   - app: Running application under test.
     * - Returns: One narrow ordered set of queries for the requested identifier.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func elementCandidates(
        for identifier: String,
        in app: XCUIApplication
    ) -> [XCUIElement] {
        let anyIdentifierMatch = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch

        if identifier.hasPrefix("labelAssignmentRow::") {
            return [
                app.collectionViews.cells[identifier].firstMatch,
                app.cells[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
                anyIdentifierMatch,
            ]
        }

        if identifier.hasPrefix("labelAssignmentToggleButton::")
            || identifier.hasPrefix("labelAssignmentFavouriteButton::")
        {
            return [
                app.buttons[identifier].firstMatch,
                app.collectionViews.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
                anyIdentifierMatch,
            ]
        }

        if identifier.hasPrefix("bookmarkListFilterChip::") {
            return [
                app.buttons[identifier].firstMatch,
                app.scrollViews.buttons[identifier].firstMatch,
                app.collectionViews.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        if identifier.hasPrefix("bookmarkListOpenStudyPadButton::") {
            return [
                app.buttons[identifier].firstMatch,
                app.collectionViews.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        if identifier.hasPrefix("bookmarkListEditLabelsButton::")
            || identifier.hasPrefix("bookmarkListRowButton::")
        {
            return [
                app.buttons[identifier].firstMatch,
                app.collectionViews.buttons[identifier].firstMatch,
                app.cells.buttons[identifier].firstMatch,
                app.cells[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        if identifier.hasPrefix("windowTabButton::") || identifier.hasPrefix("modulePickerRow::") {
            return [
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        }

        switch identifier {
        case "readerNavigationDrawer":
            return [
                app.scrollViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "readerNavigationDrawerDismissArea":
            return [
                app.otherElements[identifier].firstMatch,
            ]
        case "readerNavigationDrawerButton":
            return [
                app.buttons[identifier].firstMatch,
            ]
        case "readerMoreMenuButton", "bookChooserButton":
            return [
                app.buttons[identifier].firstMatch,
            ]
        case "readerBibleToolbarButton", "readerCommentaryToolbarButton":
            return [
                app.otherElements[identifier].firstMatch,
                app.images[identifier].firstMatch,
                anyIdentifierMatch,
            ]
        case "windowTabAddButton":
            return [
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "readerStudyPadTitle", "readerMyNotesTitle":
            return [
                app.staticTexts[identifier].firstMatch,
                app.navigationBars.staticTexts[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "readerRenderedContentState":
            return [
                app.otherElements[identifier].firstMatch,
                app.staticTexts[identifier].firstMatch,
            ]
        case "readerOverflowMenu":
            return [
                app.otherElements[identifier].firstMatch,
                app.scrollViews[identifier].firstMatch,
            ]
        case "readerOverflowMenuDismissArea":
            return [
                app.otherElements[identifier].firstMatch,
            ]
        case "readerOverflowSectionTitlesToggle":
            return [
                app.buttons[identifier].firstMatch,
                app.buttons["Section Titles"].firstMatch,
                app.buttons["Section titles"].firstMatch,
                app.otherElements[identifier].firstMatch,
                anyIdentifierMatch,
            ]
        case "readerOverflowStrongsModeAction":
            return [
                app.buttons[identifier].firstMatch,
                app.buttons["Strong's Numbers…"].firstMatch,
                app.buttons["Strong's Numbers..."].firstMatch,
                app.buttons["Strong's numbers…"].firstMatch,
                app.buttons["Strong's numbers..."].firstMatch,
                app.otherElements[identifier].firstMatch,
                anyIdentifierMatch,
            ]
        case "readerOverflowVerseNumbersToggle":
            return [
                app.buttons[identifier].firstMatch,
                app.buttons["Chapter & Verse Numbers"].firstMatch,
                app.buttons["Chapter & verse numbers"].firstMatch,
                app.otherElements[identifier].firstMatch,
                anyIdentifierMatch,
            ]
        case "labelAssignmentCreateNewLabelButton":
            return [
                app.alerts.buttons[identifier].firstMatch,
                app.sheets.buttons[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.collectionViews.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "labelManagerNewLabelNameField":
            return [
                app.textFields[identifier].firstMatch,
                app.textFields["Label name"].firstMatch,
                app.alerts.textFields[identifier].firstMatch,
                app.alerts.textFields["Label name"].firstMatch,
                app.sheets.textFields[identifier].firstMatch,
                app.sheets.textFields["Label name"].firstMatch,
            ]
        case "labelEditNameField":
            return [
                app.textFields[identifier].firstMatch,
                app.textViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "labelManagerCreateButton":
            return [
                app.buttons[identifier].firstMatch,
                app.buttons["Create"].firstMatch,
                app.alerts.buttons[identifier].firstMatch,
                app.alerts.buttons["Create"].firstMatch,
                app.sheets.buttons[identifier].firstMatch,
                app.sheets.buttons["Create"].firstMatch,
            ]
        case "aboutAppTitle":
            return [
                app.staticTexts[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "aboutDoneButton", "labelAssignmentDoneButton", "bookmarkListDoneButton":
            return [
                app.buttons[identifier].firstMatch,
                app.navigationBars.buttons[identifier].firstMatch,
                app.toolbars.buttons[identifier].firstMatch,
                app.collectionViews.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "aboutScreen":
            return [
                app.scrollViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "aboutSheetScreen":
            return [
                app.navigationBars[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "searchScreen":
            return [
                app.otherElements[identifier].firstMatch,
                app.collectionViews[identifier].firstMatch,
                app.scrollViews[identifier].firstMatch,
            ]
        case "searchStateExport":
            return [
                app.staticTexts[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "searchResultsList":
            return [
                app.collectionViews[identifier].firstMatch,
                app.tables[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "searchScopeStrip":
            return [
                app.scrollViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "searchWordModePicker":
            return [
                app.segmentedControls[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "searchQueryField":
            return [
                app.textFields[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case
            "settingsDownloadsLink",
            "settingsRepositoriesLink",
            "settingsImportExportLink",
            "settingsSyncLink",
            "settingsLabelsLink",
            "settingsTextDisplayLink",
            "settingsColorsLink":
            return [
                app.links[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.cells[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "syncSettingsState":
            return [
                app.otherElements[identifier].firstMatch,
                app.staticTexts[identifier].firstMatch,
            ]
        case "textDisplayFontFamilyButton":
            return [
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case "textDisplayJustifyTextToggle":
            return [
                app.switches[identifier].firstMatch,
                app.buttons[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
            ]
        case
            "settingsForm",
            "bookmarkListScreen",
            "labelAssignmentScreen",
            "labelManagerScreen",
            "labelEditScreen",
            "syncSettingsScreen",
            "colorSettingsScreen",
            "textDisplaySettingsScreen",
            "importExportScreen",
            "historyScreen",
            "modulePickerScreen",
            "moduleBrowserScreen":
            return [
                app.collectionViews[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
                anyIdentifierMatch,
            ]
        case "workspaceSelectorScreen":
            return [
                app.collectionViews[identifier].firstMatch,
                app.tables[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
                anyIdentifierMatch,
            ]
        case "readingPlanTemplateButton":
            return [
                app.buttons[identifier].firstMatch,
                app.collectionViews.buttons[identifier].firstMatch,
                app.cells[identifier].firstMatch,
                app.otherElements[identifier].firstMatch,
                anyIdentifierMatch,
            ]
        default:
            return [anyIdentifierMatch]
        }
    }

    /**
     Resolves the first live typed XCUI element for one accessibility identifier.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier to resolve.
     *   - app: Running application under test.
     * - Returns: The first existing typed candidate in the explicit priority order.
     * - Side effects: none.
     * - Failure modes: returns `nil` when the identifier is not currently exposed.
     */
    private func resolvedElement(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        let candidates = elementCandidates(for: identifier, in: app)
        return candidates.first(where: { $0.exists })
    }

    /**
     Returns a stable fallback query for one accessibility identifier without forcing broad queries.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier to resolve.
     *   - app: Running application under test.
     * - Returns: The first typed candidate for the identifier.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func unresolvedElement(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        elementCandidates(for: identifier, in: app).first ?? app.otherElements[identifier].firstMatch
    }

    /**
     Waits for an accessibility-identified element and records a precise failure when it never appears.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier expected to appear in the UI hierarchy.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first matching UI element for the requested accessibility identifier.
     * - Side effects:
     *   - queries the live XCUI hierarchy repeatedly until the timeout expires
     *   - records an XCTest assertion failure when no matching element appears in time
     * - Failure modes:
     *   - returns the unresolved query result after recording a failure when the identifier never appears
     */
    private func requireElement(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = resolvedElement(identifier, in: app) {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let element = unresolvedElement(identifier, in: app)
        XCTAssertTrue(
            element.exists,
            "Expected element '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Waits for the first accessibility-identified element in a candidate set to appear.
     *
     * - Parameters:
     *   - identifiers: Ordered accessibility identifiers to probe.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to keep polling.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first matching visible element, or `nil` when none appear before timeout.
     * - Side effects:
     *   - repeatedly re-queries the live XCUI hierarchy across the provided identifiers
     * - Failure modes: This helper does not fail directly.
     */
    private func waitForAnyElement(
        _ identifiers: [String],
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for identifier in identifiers {
                if let candidate = resolvedElement(identifier, in: app) {
                    return candidate
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return nil
    }

    /**
     Waits for one bookmark-list row to appear and records a precise failure if it does not.
     *
     * - Parameters:
     *   - referenceSegment: Identifier-safe reference segment such as `Exodus_2_1`.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved bookmark-row element.
     * - Side effects:
     *   - queries the live accessibility hierarchy for the requested bookmark row identifier
     * - Failure modes:
     *   - records an XCTest failure if the bookmark row never appears within the timeout
     */
    private func requireBookmarkRow(
        _ referenceSegment: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        requireElement(
            "bookmarkListRowButton::\(referenceSegment)",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
    }

    /**
     Waits for one visible History row whose accessible label contains the requested reference text.
     *
     * - Parameters:
     *   - fragment: Case-insensitive substring expected inside the visible History row label.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved History row element.
     * - Side effects:
     *   - queries both button and generic accessibility elements for the visible History row label
     * - Failure modes:
     *   - records an XCTest failure if no matching History row appears within the timeout
     */
    private func requireHistoryRow(
        containing fragment: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", fragment)
        let button = app.buttons.matching(predicate).firstMatch
        if button.waitForExistence(timeout: timeout) {
            return button
        }

        let element = app.descendants(matching: .any).matching(predicate).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected a History row containing '\(fragment)' within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Resolves the first visible accessibility element whose label contains a reader reference token.
     *
     * - Parameters:
     *   - fragment: Case-insensitive substring expected inside the rendered reader reference.
     *   - app: Running application under test.
     * - Returns: Matching UI element query result.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func readerReferenceElement(
        containing fragment: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let referenceButton = app.buttons["bookChooserButton"].firstMatch
        if referenceButton.exists || referenceButton.waitForExistence(timeout: 0.5) {
            return referenceButton
        }
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", fragment)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    /**
     Waits for the visible reader chrome to expose a reference label containing the requested token.
     *
     * - Parameters:
     *   - fragment: Case-insensitive substring expected inside the rendered reader reference.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Matching UI element.
     * - Side effects:
     *   - queries the live XCUI hierarchy until a matching element appears
     * - Failure modes:
     *   - records an XCTest failure when no matching visible reference appears in time
     */
    private func requireReaderReferenceContaining(
        _ fragment: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let referenceButton = app.buttons["bookChooserButton"].firstMatch
        if referenceButton.exists || referenceButton.waitForExistence(timeout: min(timeout, 1)) {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if let value = referenceButton.value as? String,
                   value.localizedCaseInsensitiveContains(fragment)
                {
                    return referenceButton
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            } while Date() < deadline

            let finalValue = referenceButton.value as? String ?? ""
            XCTAssertTrue(
                finalValue.localizedCaseInsensitiveContains(fragment),
                "Expected the reader reference to contain '\(fragment)' within \(timeout) seconds, but saw '\(finalValue)'.",
                file: file,
                line: line
            )
            return referenceButton
        }

        let element = readerReferenceElement(containing: fragment, in: app)
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected a visible reader reference containing '\(fragment)' within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Waits for the visible reader chrome to stop exposing a stale reference label.
     *
     * - Parameters:
     *   - fragment: Case-insensitive substring expected to disappear after navigation.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the matching UI element until it no longer exists
     * - Failure modes:
     *   - records an XCTest failure when the stale reference remains visible after the timeout
     */
    private func waitForReaderReferenceToDisappear(
        _ fragment: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let referenceButton = app.buttons["bookChooserButton"].firstMatch
        if referenceButton.exists || referenceButton.waitForExistence(timeout: min(timeout, 1)) {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                let value = referenceButton.value as? String ?? ""
                if !value.localizedCaseInsensitiveContains(fragment) {
                    return
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            } while Date() < deadline

            let finalValue = referenceButton.value as? String ?? ""
            XCTAssertFalse(
                finalValue.localizedCaseInsensitiveContains(fragment),
                "Expected the reader reference to stop containing '\(fragment)' within \(timeout) seconds, but saw '\(finalValue)'.",
                file: file,
                line: line
            )
            return
        }

        let element = readerReferenceElement(containing: fragment, in: app)
        let predicate = NSPredicate(format: "exists == false")
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
        XCTAssertFalse(
            element.exists,
            "Expected reader reference containing '\(fragment)' to disappear within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Waits for the primary reader reference control to expose a non-empty value.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The current non-empty reader reference string from `bookChooserButton`.
     * - Side effects:
     *   - polls the live reader toolbar until the reference control exports one non-empty value
     * - Failure modes:
     *   - records an XCTest failure if the reader reference never becomes non-empty
     */
    private func requireReaderReferenceValue(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let referenceButton = requireButton(
            "bookChooserButton",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = referenceButton.value as? String, !value.isEmpty {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let fallbackValue = referenceButton.value as? String ?? ""
        XCTAssertFalse(
            fallbackValue.isEmpty,
            "Expected bookChooserButton to expose a non-empty reader reference within \(timeout) seconds.",
            file: file,
            line: line
        )
        return fallbackValue
    }

    /**
     Waits for the active reader pane's rendered-content export to contain one semantic token.
     */
    private func waitForReaderRenderedContentState(
        containing token: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let stateElement = resolvedElement("readerRenderedContentState", in: app),
               let value = stateElement.value as? String,
               value.contains(token) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let stateElement = requireElement("readerRenderedContentState", in: app, timeout: 1, file: file, line: line)
        let lastValue = stateElement.value.map { "\($0)" } ?? "nil"
        XCTFail(
            "Expected reader rendered-content state to contain '\(token)' within \(timeout) seconds; last value was '\(lastValue)'.",
            file: file,
            line: line
        )
    }

    /**
     Waits for the reader shell's stable navigation chrome to become interactive again.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before returning `false`.
     * - Returns: `true` when the stable reader toolbar is visible again and no drawer-only or
     *   overflow-only action remains exposed over the shell.
     * - Side effects:
     *   - polls the live toolbar hierarchy while modal surfaces dismiss back to the reader shell
     *   - avoids expensive cross-surface root queries by checking menu-only action affordances
     * - Failure modes:
     *   - returns `false` when the reader shell never restores its primary controls before timeout
     */
    private func waitForReaderShellReady(
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let drawerButton = resolvedElement("readerNavigationDrawerButton", in: app)
            let referenceButton = resolvedElement("bookChooserButton", in: app)
            let moreButton = resolvedElement("readerMoreMenuButton", in: app)
            let referenceValue = referenceButton?.value as? String ?? ""
            let drawerActionVisible = app.buttons["readerOpenBookmarksAction"].firstMatch.exists
            let overflowActionVisible = app.buttons["readerOpenWorkspacesAction"].firstMatch.exists

            if drawerButton != nil,
               referenceButton != nil,
               moreButton != nil,
               !referenceValue.isEmpty,
               !drawerActionVisible,
               !overflowActionVisible {
                return true
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return false
    }

    /**
     Waits for the primary reader reference control to change away from one previous value.
     *
     * - Parameters:
     *   - initialValue: Previously observed reader reference that should no longer be visible.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first non-empty reader reference value different from `initialValue`.
     * - Side effects:
     *   - polls the live reader toolbar until `bookChooserButton` exports a different value
     * - Failure modes:
     *   - records an XCTest failure if the reader reference never changes before the timeout
     */
    private func waitForReaderReferenceValueToChange(
        from initialValue: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let referenceButton = requireButton(
            "bookChooserButton",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = referenceButton.value as? String,
               !value.isEmpty,
               value != initialValue {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let fallbackValue = referenceButton.value as? String ?? ""
        XCTAssertNotEqual(
            fallbackValue,
            initialValue,
            "Expected bookChooserButton to change away from '\(initialValue)' within \(timeout) seconds.",
            file: file,
            line: line
        )
        return fallbackValue
    }

    /**
     Taps one bottom window-tab pill by order number and waits for its active state to surface.
     */
    private func tapWindowTab(
        _ order: Int,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let identifier = "windowTabButton::\(order)"
        let tabButton = requireElement(identifier, in: app, timeout: timeout, file: file, line: line)
        tapElementReliably(tabButton, timeout: timeout, file: file, line: line)

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let value = resolvedElement(identifier, in: app)?.value as? String,
               value.contains("state=active") {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let lastValue = resolvedElement(identifier, in: app)?.value.map { "\($0)" } ?? "nil"
        XCTFail(
            "Expected window tab \(order) to become active within \(timeout) seconds; last value was '\(lastValue)'.",
            file: file,
            line: line
        )
    }

    /**
     Waits for one accessibility-identified button element to exist.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier expected on a button element.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved button element.
     * - Side effects:
     *   - queries the live button hierarchy repeatedly until the identifier resolves or the
     *     timeout expires
     * - Failure modes:
     *   - records an XCTest failure if the requested button never appears within the allotted
     *     timeout
     */
    private func requireButton(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let button = app.buttons[identifier].firstMatch
        XCTAssertTrue(
            button.waitForExistence(timeout: timeout),
            "Expected button '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return button
    }

    /**
     Polls one accessibility-identified element until its value matches the expected semantic token.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier whose resolved element value should be sampled.
     *   - expectedValue: Semantic value expected before the timeout expires.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep polling before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly re-queries the live XCUI hierarchy for the requested identifier
     *   - records an XCTest failure when the value never reaches the expected state before timeout
     * - Failure modes:
     *   - fails when the element disappears or its accessibility value never reaches the requested
     *     token within the timeout window
     */
    private func waitForElementValue(
        _ identifier: String,
        toEqual expectedValue: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let currentElement = resolvedElement(identifier, in: app) {
                let currentValue = currentElement.value as? String
                if currentValue == expectedValue || currentElement.label == expectedValue {
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalElement = unresolvedElement(identifier, in: app)
        let finalValue = finalElement.value as? String
        XCTAssertEqual(
            finalValue ?? finalElement.label,
            expectedValue,
            "Expected element '\(identifier)' to reach value '\(expectedValue)' within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Waits for one accessibility-identified element value to contain a token.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier expected to appear in the UI hierarchy.
     *   - expectedToken: Token that should appear inside the element value or label.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep polling before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly re-queries the live XCUI hierarchy until the requested token appears in the
     *     element value or label
     * - Failure modes:
     *   - fails when the element disappears or never reports the requested token before timeout
     */
    private func waitForElementValue(
        _ identifier: String,
        toContain expectedToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let currentElement = resolvedElement(identifier, in: app) {
                let currentValue = currentElement.value as? String
                let currentLabel = currentElement.label
                if currentValue?.contains(expectedToken) == true || currentLabel.contains(expectedToken) {
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalElement = unresolvedElement(identifier, in: app)
        let finalValue = finalElement.value as? String
        XCTAssertTrue(
            (finalValue?.contains(expectedToken) == true || finalElement.label.contains(expectedToken)),
            "Expected element '\(identifier)' to contain token '\(expectedToken)' within \(timeout) seconds. Final value: '\(finalValue ?? finalElement.label)'.",
            file: file,
            line: line
        )
    }

    /**
     Waits for one accessibility-identified element value to stop containing a token.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier expected to appear in the UI hierarchy.
     *   - unexpectedToken: Token that should disappear from the element value or label.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep polling before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly re-queries the live XCUI hierarchy until the requested token disappears from
     *     the element value and label
     * - Failure modes:
     *   - fails when the element disappears or keeps reporting the token after the timeout
     */
    private func waitForElementValue(
        _ identifier: String,
        toNotContain unexpectedToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let currentElement = resolvedElement(identifier, in: app) {
                let currentValue = currentElement.value as? String
                let currentLabel = currentElement.label
                if currentValue?.contains(unexpectedToken) != true && !currentLabel.contains(unexpectedToken) {
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalElement = unresolvedElement(identifier, in: app)
        let finalValue = finalElement.value as? String ?? finalElement.label
        XCTAssertFalse(
            finalValue.contains(unexpectedToken),
            "Expected element '\(identifier)' to stop containing '\(unexpectedToken)' within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Waits for one accessibility-identified element to reach the requested existence state.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier to re-resolve while polling.
     *   - app: Running application under test.
     *   - shouldExist: Requested final existence state.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly samples the live XCUI hierarchy until the requested element exists or
     *     disappears
     * - Failure modes:
     *   - records an XCTest failure when the element never reaches the requested existence state
     */
    private func waitForElementExistence(
        _ identifier: String,
        in app: XCUIApplication,
        shouldExist: Bool,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let currentExists = resolvedElement(identifier, in: app) != nil
            if currentExists == shouldExist {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let currentExists = resolvedElement(identifier, in: app) != nil
        XCTAssertEqual(
            currentExists,
            shouldExist,
            "Expected element '\(identifier)' existence to become \(shouldExist) within \(timeout) seconds.",
            file: file,
            line: line
        )
    }


    /**
     Waits for the reader shell's overflow-menu button, allowing extra time for the first cold app
     launch in the UI bundle.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the reader shell to become interactive.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The reader overflow-menu button once the reader shell has rendered it.
     * - Side effects:
     *   - repeatedly queries the live XCUI hierarchy while the reader shell finishes bootstrapping
     * - Failure modes:
     *   - records an XCTest failure if the reader shell never reaches a state where the overflow
     *     menu button exists within the allotted timeout
     */
    private func requireReaderMoreMenuButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        requireButton(
            "readerMoreMenuButton",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
    }

    /**
     Taps the reader overflow-menu button after the reader shell becomes interactive.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the toolbar button to exist and become
     *     hittable.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - resolves the overflow-menu button from the live toolbar hierarchy
     *   - taps its center point directly through the shared reliable-tap helper
     * - Failure modes:
     *   - records an XCTest failure if the overflow-menu button never becomes usable within the
     *     allotted timeout
     */
    private func tapReaderMoreMenuButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if tryTapReaderMoreMenuButton(in: app, timeout: timeout, file: file, line: line) {
            return
        }

        XCTFail(
            "Expected the reader overflow menu to appear after tapping readerMoreMenuButton within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Attempts to open the reader overflow menu without recording an XCTest failure on timeout.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to spend trying to open the overflow menu.
     *   - file: Source file used for nested helper attribution.
     *   - line: Source line used for nested helper attribution.
     * - Returns: `true` when the production overflow menu becomes visible.
     * - Side effects:
     *   - taps the production more-menu button and waits for the menu surface to appear
     * - Failure modes:
     *   - returns `false` when the menu never appears before the local retry budget expires
     */
    private func tryTapReaderMoreMenuButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        _ = requireReaderReferenceValue(
            in: app,
            timeout: min(15, timeout),
            file: file,
            line: line
        )
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let button = requireReaderMoreMenuButton(
                in: app,
                timeout: min(2, max(0.5, deadline.timeIntervalSinceNow)),
                file: file,
                line: line
            )
            if waitForElementToBecomeHittable(button, timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))) {
                button.tap()
            } else if button.exists, !button.frame.isEmpty {
                button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            if waitForReaderOverflowMenu(in: app, timeout: min(5, max(1, deadline.timeIntervalSinceNow))) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return false
    }

    /**
     Dismisses the reader overflow menu and waits until the reader shell is visible again.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to spend dismissing the overflow menu.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - taps the explicit dismiss area when available and falls back to dragging the overflow
     *     panel down when the overlay ignores the first tap
     * - Failure modes:
     *   - records an XCTest failure when the overflow menu never disappears before timeout
     */
    private func dismissReaderOverflowMenu(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            guard let overflowMenu = resolvedElement("readerOverflowMenu", in: app),
                  !overflowMenu.frame.isEmpty else {
                if waitForReaderShellReady(in: app, timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))) {
                    return
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }

            let dismissArea = unresolvedElement("readerOverflowMenuDismissArea", in: app)
            if dismissArea.exists && !dismissArea.frame.isEmpty {
                let backdropTapPoint = dismissArea.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.2))
                backdropTapPoint.tap()
                if !waitForReaderOverflowMenu(in: app, timeout: 1) &&
                    waitForReaderShellReady(in: app, timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))) {
                    return
                }
            }

            let overflowButton = unresolvedElement("readerMoreMenuButton", in: app)
            if overflowButton.exists &&
                waitForElementToBecomeHittable(
                    overflowButton,
                    timeout: min(1, max(0.25, deadline.timeIntervalSinceNow))
                )
            {
                overflowButton.tap()
                if !waitForReaderOverflowMenu(in: app, timeout: 1) &&
                    waitForReaderShellReady(in: app, timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))) {
                    return
                }
            }

            dismissSheetByDraggingDown(overflowMenu, file: file, line: line)
            if !waitForReaderOverflowMenu(in: app, timeout: 1) &&
                waitForReaderShellReady(in: app, timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))) {
                return
            }
        } while Date() < deadline

        XCTAssertFalse(
            waitForReaderOverflowMenu(in: app, timeout: 1),
            "Expected the reader overflow menu to dismiss within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Waits for the custom reader overflow sheet to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the overflow sheet.
     * - Returns: `true` when the production `readerOverflowMenu` scroll view appears.
     * - Side effects:
     *   - polls the explicit overflow-sheet accessibility identifier instead of scanning the full
     *     app hierarchy for guessed menu containers.
     * - Failure modes:
     *   - returns `false` when the overflow sheet never appears before timeout.
     */
    private func waitForReaderOverflowMenu(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let menuCandidates = [
            app.otherElements["readerOverflowMenu"].firstMatch,
            app.scrollViews["readerOverflowMenu"].firstMatch,
        ]
        let actionCandidates = [
            app.buttons["readerOpenWorkspacesAction"].firstMatch,
            app.buttons["readerOverflowNightModeToggle"].firstMatch,
            app.buttons["readerOverflowSectionTitlesToggle"].firstMatch,
        ]
        repeat {
            if menuCandidates.contains(where: { $0.exists && !$0.frame.isEmpty }) ||
                actionCandidates.contains(where: { $0.exists && !$0.frame.isEmpty }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return menuCandidates.contains(where: { $0.exists }) ||
            actionCandidates.contains(where: { $0.exists })
    }

    /**
     Taps the Android-style reader navigation drawer button and waits for the drawer to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the drawer to appear.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - resolves the production `readerNavigationDrawerButton`
     *   - taps it directly and waits for the `readerNavigationDrawer` surface
     * - Failure modes:
     *   - records an XCTest failure if the drawer never appears in time
     */
    private func tapReaderNavigationDrawerButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if tryTapReaderNavigationDrawerButton(in: app, timeout: timeout, file: file, line: line) {
            return
        }

        XCTFail(
            "Expected the reader navigation drawer to appear after tapping readerNavigationDrawerButton within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Attempts to open the reader navigation drawer without recording an XCTest failure on timeout.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to spend trying to open the drawer.
     *   - file: Source file used for nested helper attribution.
     *   - line: Source line used for nested helper attribution.
     * - Returns: `true` when the production drawer becomes visible.
     * - Side effects:
     *   - taps the production navigation-drawer button and waits for drawer affordances to appear
     * - Failure modes:
     *   - returns `false` when the drawer never appears before the local retry budget expires
     */
    private func tryTapReaderNavigationDrawerButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        _ = requireReaderReferenceValue(
            in: app,
            timeout: min(15, timeout),
            file: file,
            line: line
        )
        _ = waitForReaderShellReady(in: app, timeout: min(10, timeout))
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let button = requireElement(
                "readerNavigationDrawerButton",
                in: app,
                timeout: min(2, max(0.5, deadline.timeIntervalSinceNow))
            )
            if !button.frame.isEmpty {
                tapElementReliably(
                    button,
                    timeout: min(2, max(0.5, deadline.timeIntervalSinceNow)),
                    file: file,
                    line: line
                )
                if waitForReaderNavigationDrawer(in: app, timeout: min(5, max(2, deadline.timeIntervalSinceNow))) {
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return false
    }

    /**
     Waits for the Android-style reader navigation drawer to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the drawer.
     * - Returns: `true` when the production `readerNavigationDrawer` surface appears.
     * - Side effects:
     *   - polls the explicit drawer accessibility identifier.
     * - Failure modes:
     *   - returns `false` when the drawer never appears before timeout.
     */
    private func waitForReaderNavigationDrawer(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let drawerCandidates = [
            app.scrollViews["readerNavigationDrawer"].firstMatch,
            app.otherElements["readerNavigationDrawer"].firstMatch,
        ]
        let actionCandidates = [
            app.buttons["readerOpenBookmarksAction"].firstMatch,
            app.buttons["readerOpenSettingsAction"].firstMatch,
            app.buttons["readerOpenSearchAction"].firstMatch,
        ]
        repeat {
            if drawerCandidates.contains(where: { $0.exists && !$0.frame.isEmpty }) ||
                actionCandidates.contains(where: { $0.exists && !$0.frame.isEmpty }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return drawerCandidates.contains(where: { $0.exists }) ||
            actionCandidates.contains(where: { $0.exists })
    }

    /**
     Taps one reader-shell action after the stable action surface has been resolved.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the reader action to invoke.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the action to appear and become hittable.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the requested reader action button to appear
     *   - taps the resolved button through the shared reliable-tap helper
     * - Failure modes:
     *   - records an XCTest failure if the requested reader action never appears or never becomes
     *     hittable within the allotted timeout
     */
    private func tapReaderAction(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            guard let button = tryResolveReaderActionControl(
                identifier,
                in: app,
                timeout: min(3, max(1, deadline.timeIntervalSinceNow))
            ) else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }
            if waitForElementToBecomeHittable(button, timeout: min(1.5, max(0.5, deadline.timeIntervalSinceNow))) {
                button.tap()
            } else if let overflowMenu = resolvedElement("readerOverflowMenu", in: app),
                      isElementVisible(button, within: overflowMenu)
            {
                button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                continue
            }

            let settleDeadline = Date().addingTimeInterval(min(2, max(0.5, deadline.timeIntervalSinceNow)))
            repeat {
                if resolvedElement("readerOverflowMenu", in: app) == nil {
                    return
                }
                if let refreshedButton = resolvedElement(identifier, in: app), !refreshedButton.exists {
                    return
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            } while Date() < settleDeadline
        } while Date() < deadline

        let button = requireReaderActionControl(
            identifier,
            in: app,
            timeout: min(5, timeout),
            file: file,
            line: line
        )
        if let actionSurface = ensureReaderActionSurface(
            for: identifier,
            in: app,
            timeout: min(5, timeout),
            file: file,
            line: line
        ) {
            XCTAssertTrue(
                button.isHittable || isElementVisible(button, within: actionSurface),
                "Expected element '\(identifier)' to become tappable within \(timeout) seconds.",
                file: file,
                line: line
            )
            return
        }

        XCTFail(
            "Expected the reader action surface to remain available while activating '\(identifier)' within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Opens About from the reader overflow menu with one bounded retry when the first tap does not
     transition away from the live menu.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to spend across menu discovery, action tapping, and
     *     destination confirmation.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - opens the reader overflow menu
     *   - taps the About action up to two times when the first tap leaves the menu open
     * - Failure modes:
     *   - records an XCTest failure if the About destination never appears within the allotted
     *     timeout
     */
    private func openAboutFromReaderMenu(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)

        for attempt in 1...2 {
            let remaining = max(1, deadline.timeIntervalSinceNow)
            tapReaderAction(
                "readerOpenAboutAction",
                in: app,
                timeout: min(10, remaining),
                file: file,
                line: line
            )
            if waitForAboutScreenVisible(in: app, timeout: min(8, max(1, deadline.timeIntervalSinceNow))) {
                return
            }

            if attempt == 1 {
                if resolvedElement("readerNavigationDrawer", in: app) != nil {
                    continue
                }
            }
        }

        XCTAssertTrue(
            waitForAboutScreenVisible(in: app, timeout: min(5, max(1, deadline.timeIntervalSinceNow))),
            "Expected the About destination to surface within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Confirms the About destination rendered after reader-menu navigation.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the About destination to surface.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls explicit About-only accessibility identifiers so the waiter does not rely on broad
     *     hierarchy scans or generic localized button titles during sheet transitions
     * - Failure modes:
     *   - records an XCTest failure if none of the About-specific surface identifiers appears
     *     within the allotted timeout
     */
    private func waitForAboutScreenVisible(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        waitForAnyElement(
            ["aboutDoneButton", "aboutAppTitle", "aboutScreen", "aboutSheetScreen"],
            in: app,
            timeout: timeout,
            file: file,
            line: line
        ) != nil
    }

    /**
     Maps one reader overflow action identifier to the visible English menu title exported by the
     production `Menu` rows.
     *
     * - Parameter identifier: Stable accessibility identifier attached in `BibleReaderView`.
     * - Returns: User-visible menu title that XCTest can use as a fallback query surface.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func readerActionTitle(for identifier: String) -> String {
        switch identifier {
        case "readerChooseDocumentAction":
            return "Choose Document"
        case "readerOpenSearchAction":
            return "Search"
        case "readerOpenSpeakAction":
            return "Speak"
        case "readerOpenBookmarksAction":
            return "Bookmarks"
        case "readerOpenStudyPadsAction":
            return "StudyPads"
        case "readerOpenMyNotesAction":
            return "My Notes"
        case "readerOpenHistoryAction":
            return "History"
        case "readerOpenReadingPlansAction":
            return "Reading Plans"
        case "readerOpenSettingsAction":
            return "Application preferences"
        case "readerOpenWorkspacesAction":
            return "Workspaces…"
        case "readerOpenDownloadsAction":
            return "Download Documents"
        case "readerOpenImportExportAction":
            return "Backup & Restore"
        case "readerOpenSyncSettingsAction":
            return "Device synchronization"
        case "readerOpenHelpAction":
            return "Help & Tips"
        case "readerSponsorDevelopmentAction":
            return "Buy development work"
        case "readerNeedHelpAction":
            return "Need Help"
        case "readerContributeAction":
            return "How to Contribute"
        case "readerOpenAboutAction":
            return "About"
        case "readerOpenAppLicenseAction":
            return "App Licence"
        case "readerTellFriendAction":
            return "Recommend to a friend"
        case "readerRateAppAction":
            return "Rate & Review"
        case "readerReportBugAction":
            return "Feedback / bug report"
        default:
            return identifier
        }
    }

    /**
     Declares which production reader action surface should host one action identifier.
     *
     * - Parameter identifier: Stable accessibility identifier attached in `BibleReaderView`.
     * - Returns: `true` when the action belongs to the left navigation drawer; otherwise `false`
     *   and the action belongs to the overflow/options menu.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func readerActionUsesNavigationDrawer(_ identifier: String) -> Bool {
        switch identifier {
        case "readerOpenBookmarksAction",
             "readerOpenHistoryAction",
             "readerOpenReadingPlansAction",
             "readerOpenDownloadsAction",
             "readerOpenSettingsAction",
             "readerOpenAboutAction",
             "readerChooseDocumentAction",
             "readerOpenSearchAction",
             "readerOpenSpeakAction",
             "readerOpenStudyPadsAction",
             "readerOpenMyNotesAction",
             "readerOpenImportExportAction",
             "readerOpenSyncSettingsAction",
             "readerOpenHelpAction",
             "readerNeedHelpAction",
             "readerContributeAction",
             "readerOpenAppLicenseAction",
             "readerTellFriendAction",
             "readerRateAppAction",
             "readerReportBugAction":
            return true
        default:
            return false
        }
    }

    /**
     Ensures the correct production reader action surface is open for one action identifier.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the requested reader action.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to spend dismissing conflicting surfaces and opening
     *     the required one.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The currently visible action surface, or `nil` when it never becomes available
     *   inside the local retry budget.
     * - Side effects:
     *   - dismisses the wrong menu surface when it is currently visible
     *   - opens either the left navigation drawer or the overflow/options sheet
     * - Failure modes:
     *   - returns `nil` when the required action surface never becomes available before timeout
     */
    private func ensureReaderActionSurface(
        for identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let prefersDrawer = readerActionUsesNavigationDrawer(identifier)

        repeat {
            if prefersDrawer {
                if let drawer = resolvedElement("readerNavigationDrawer", in: app),
                   !drawer.frame.isEmpty {
                    return drawer
                }
                if let overflowMenu = resolvedElement("readerOverflowMenu", in: app),
                   !overflowMenu.frame.isEmpty {
                    dismissReaderOverflowMenu(
                        in: app,
                        timeout: min(8, max(5, deadline.timeIntervalSinceNow)),
                        file: file,
                        line: line
                    )
                } else {
                    _ = tryTapReaderNavigationDrawerButton(
                        in: app,
                        timeout: min(12, max(5, deadline.timeIntervalSinceNow)),
                        file: file,
                        line: line
                    )
                }
            } else {
                if let overflowMenu = resolvedElement("readerOverflowMenu", in: app),
                   !overflowMenu.frame.isEmpty {
                    return overflowMenu
                }
                if let drawer = resolvedElement("readerNavigationDrawer", in: app),
                   drawer.exists {
                    let dismissArea = unresolvedElement("readerNavigationDrawerDismissArea", in: app)
                    if dismissArea.exists {
                        tapElementReliably(dismissArea, timeout: 5, file: file, line: line)
                    }
                } else {
                    _ = tryTapReaderMoreMenuButton(
                        in: app,
                        timeout: min(12, max(5, deadline.timeIntervalSinceNow)),
                        file: file,
                        line: line
                    )
                }
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        if prefersDrawer {
            let drawer = unresolvedElement("readerNavigationDrawer", in: app)
            return drawer.exists ? drawer : nil
        }

        let overflowMenu = unresolvedElement("readerOverflowMenu", in: app)
        return overflowMenu.exists ? overflowMenu : nil
    }

    /**
     Resolves one reader overflow action from either its stable accessibility identifier or its
     visible menu title.
     *
     * - Parameters:
     *   - identifier: Stable accessibility identifier attached in `BibleReaderView`.
     *   - app: Running application under test.
     * - Returns: Best-effort live XCUI element for the action.
     * - Side effects: none.
     * - Failure modes: returns a non-existing identifier-backed element when no live match exists.
     */
    private func resolveReaderActionElement(
        _ identifier: String,
        in app: XCUIApplication,
        actionSurface: XCUIElement
    ) -> XCUIElement {
        let title = readerActionTitle(for: identifier)
        let scopedCandidates = [
            actionSurface.buttons[identifier].firstMatch,
            actionSurface.buttons[title].firstMatch,
            actionSurface.otherElements[identifier].firstMatch,
        ]

        if let visibleCandidate = scopedCandidates.first(where: { $0.exists && $0.isHittable }) {
            return visibleCandidate
        }
        if let frameCandidate = scopedCandidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
            return frameCandidate
        }
        return scopedCandidates.first(where: { $0.exists }) ?? actionSurface.buttons[identifier].firstMatch
    }

    /**
     Resolves one reader-shell menu action, scrolling the live menu surface when the requested
     action starts below the fold.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the reader action to resolve.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to keep searching and scrolling.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved reader action button.
     * - Side effects:
     *   - re-queries the live accessibility hierarchy while swiping the visible menu container
     *     upward to reveal actions lower in the overflow menu
     * - Failure modes:
     *   - records an XCTest failure when the requested action never appears before the timeout
     */
    private func requireReaderActionControl(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        if let control = tryResolveReaderActionControl(identifier, in: app, timeout: timeout) {
            return control
        }

        let title = readerActionTitle(for: identifier)
        let prefersDrawer = readerActionUsesNavigationDrawer(identifier)
        let directActionCandidates = [
            app.buttons[identifier].firstMatch,
            app.buttons[title].firstMatch,
        ]

        if let finalSurface = prefersDrawer
            ? resolvedElement("readerNavigationDrawer", in: app)
            : resolvedElement("readerOverflowMenu", in: app)
        {
            let finalAction = resolveReaderActionElement(identifier, in: app, actionSurface: finalSurface)
            XCTAssertTrue(
                finalAction.exists,
                "Expected reader action '\(identifier)' to exist within \(timeout) seconds.",
                file: file,
                line: line
            )
            return finalAction
        }

        if let directAction = directActionCandidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
            return directAction
        }

        let actionSurface = unresolvedElement(
            prefersDrawer ? "readerNavigationDrawer" : "readerOverflowMenu",
            in: app
        )
        XCTAssertTrue(
            actionSurface.exists,
            "Expected the reader action surface to appear within \(timeout) seconds before resolving '\(identifier)'.",
            file: file,
            line: line
        )
        return resolveReaderActionElement(identifier, in: app, actionSurface: actionSurface)
    }

    /**
     Attempts to resolve one reader-shell action without recording an XCTest failure on transient
     drawer/overflow misses.
     */
    private func tryResolveReaderActionControl(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        let title = readerActionTitle(for: identifier)
        let prefersDrawer = readerActionUsesNavigationDrawer(identifier)
        let directActionCandidates = [
            app.buttons[identifier].firstMatch,
            app.buttons[title].firstMatch,
        ]
        repeat {
            if let actionSurface = ensureReaderActionSurface(
                for: identifier,
                in: app,
                timeout: min(10, max(3, deadline.timeIntervalSinceNow))
            ) {
                for _ in 0..<4 {
                    let action = resolveReaderActionElement(identifier, in: app, actionSurface: actionSurface)
                    if action.exists, waitForElementToBecomeHittable(action, timeout: 0.5) {
                        return action
                    }
                    if isElementVisible(action, within: actionSurface) {
                        return action
                    }
                    if actionSurface.exists, !actionSurface.frame.isEmpty {
                        actionSurface.swipeUp()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                    }
                }
            }

            if let directAction = directActionCandidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
                return directAction
            }
            if let directAction = directActionCandidates.first(where: { $0.exists }) {
                return directAction
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        if let finalSurface = prefersDrawer
            ? resolvedElement("readerNavigationDrawer", in: app)
            : resolvedElement("readerOverflowMenu", in: app)
        {
            let finalAction = resolveReaderActionElement(identifier, in: app, actionSurface: finalSurface)
            if finalAction.exists {
                return finalAction
            }
        }

        if let directAction = directActionCandidates.first(where: { $0.exists && !$0.frame.isEmpty }) {
            return directAction
        }
        if let directAction = directActionCandidates.first(where: { $0.exists }) {
            return directAction
        }
        return nil
    }

    /**
     Waits for one live XCUI element to become hittable.
     *
     * - Parameters:
     *   - element: Resolved XCUI element expected to expose a tappable accessibility surface.
     *   - timeout: Maximum number of seconds to poll.
     * - Returns: `true` when XCTest reports the element as hittable before the timeout.
     * - Side effects:
     *   - repeatedly samples the element while allowing pending UI transitions to settle
     * - Failure modes: This helper does not fail directly.
     */
    private func waitForElementToBecomeHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists && element.isHittable {
                return true
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0, !element.exists {
                _ = element.waitForExistence(timeout: min(0.2, remaining))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return element.exists && element.isHittable
    }

    /**
     Waits for one resolved element to become tappable, then uses XCTest's native tap path.
     *
     * - Parameters:
     *   - element: Resolved XCUI element that should be tapped.
     *   - timeout: Maximum number of seconds to wait for the element to become hittable.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the live element to appear and uses XCTest's native `tap()` path once the
     *     simulator reports the element as hittable
     * - Failure modes:
     *   - records an XCTest failure if the element never appears
     *   - records an XCTest failure if the element never becomes hittable
     */
    private func tapElementReliably(
        _ element: XCUIElement,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if waitForElementToBecomeHittable(element, timeout: timeout) {
            element.tap()
            return
        }

        let exists = element.exists || element.waitForExistence(timeout: min(timeout, 1))
        XCTAssertTrue(
            exists,
            "Expected element '\(element.identifier)' to exist before tapping within \(timeout) seconds.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            element.isHittable,
            "Expected element '\(element.identifier)' to become hittable before tapping within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Returns whether one resolved element exposes a visible leading-edge tap point within a
     container viewport.
     *
     * - Parameters:
     *   - element: Live XCUI element that may be partially clipped by the container.
     *   - container: Scrollable ancestor whose visible bounds should contain the tap point.
     * - Returns: `true` when the element exposes a stable tap point within the container viewport.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func isElementVisible(
        _ element: XCUIElement,
        within container: XCUIElement
    ) -> Bool {
        guard element.exists, !element.frame.isEmpty else {
            return false
        }
        guard container.exists, !container.frame.isEmpty else {
            return true
        }

        let visibleFrame = container.frame.insetBy(dx: 0, dy: 16)
        let intersection = visibleFrame.intersection(element.frame)
        guard !intersection.isNull else {
            return false
        }
        let minimumVisibleHeight = min(max(24, element.frame.height * 0.5), element.frame.height)
        let minimumVisibleWidth = min(max(40, element.frame.width * 0.3), element.frame.width)
        return intersection.height >= minimumVisibleHeight &&
            intersection.width >= minimumVisibleWidth
    }

    /**
     Taps one deterministic segment within a visible segmented control by geometry instead of child
     button queries, which SwiftUI does not expose consistently across XCTest runtimes.
     *
     * - Parameters:
     *   - control: Segmented control exporting the target segments.
     *   - index: Zero-based segment index to tap.
     *   - segmentCount: Total number of visible segments in the control.
     *   - timeout: Maximum number of seconds to wait for the control to expose a stable frame.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the segmented control to expose a non-empty frame, then taps the requested
     *     segment center directly
     * - Failure modes:
     *   - records an XCTest failure if the control never appears or the requested segment index is
     *     out of range
     */
    private func tapSegmentedControlSegment(
        _ control: XCUIElement,
        index: Int,
        segmentCount: Int,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            index >= 0 && index < segmentCount,
            "Expected segmented control segment index \(index) to be within 0..<\(segmentCount).",
            file: file,
            line: line
        )
        guard index >= 0 && index < segmentCount else {
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !control.frame.isEmpty {
                let dx = (CGFloat(index) + 0.5) / CGFloat(segmentCount)
                control.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: 0.5)).tap()
                return
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining > 0 {
                _ = control.waitForExistence(timeout: min(0.2, remaining))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTAssertTrue(
            !control.frame.isEmpty,
            "Expected segmented control '\(control.identifier)' to expose a non-empty frame before tapping segment \(index) within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /// Shared geometry constants for the Search word-mode segmented control.
    private enum SearchWordModeControl {
        static let segmentCount = 3
    }

    /**
     Dismisses the software keyboard through one visible return-style action when present.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - taps one visible keyboard action so lower controls are no longer obscured
     * - Failure modes:
     *   - silently leaves focus unchanged when no software keyboard or dismissal action exists
     */
    private func dismissKeyboardIfPresent(in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.exists || keyboard.waitForExistence(timeout: 0.2) else {
            return
        }

        for title in ["Done", "Return", "Go", "Search", "OK"] {
            let button = keyboard.buttons[title].firstMatch
            if button.exists || button.waitForExistence(timeout: 0.2) {
                if waitForElementToBecomeHittable(button, timeout: 0.5) {
                    button.tap()
                } else if !button.frame.isEmpty {
                    button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                }
                return
            }
        }
    }

    /**
     Waits for the currently presented alert text field to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first alert-owned text field.
     * - Side effects:
     *   - waits for a live alert, then resolves its native text field instead of the broader app
     *     hierarchy
     * - Failure modes:
     *   - records an XCTest failure if no alert text field appears within the timeout
     */
    private func requireAlertTextField(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: timeout),
            "Expected an alert with a text field within \(timeout) seconds.",
            file: file,
            line: line
        )
        let textField = alert.textFields.firstMatch
        XCTAssertTrue(
            textField.waitForExistence(timeout: timeout),
            "Expected the presented alert to expose a text field within \(timeout) seconds.",
            file: file,
            line: line
        )
        return textField
    }

    /**
     Taps one native alert button and waits for the alert to disappear before continuing.
     *
     * - Parameters:
     *   - title: Visible button title expected inside the currently presented alert.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the button and dismissal.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - resolves the live alert button, taps it, and blocks until the alert no longer exists
     * - Failure modes:
     *   - records an XCTest failure if the alert button never appears or the alert does not
     *     dismiss after the tap
     */
    private func tapAlertButton(
        _ title: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(
            alert.waitForExistence(timeout: timeout),
            "Expected an alert before tapping '\(title)'.",
            file: file,
            line: line
        )
        let button = alert.buttons[title].firstMatch
        XCTAssertTrue(
            button.waitForExistence(timeout: timeout),
            "Expected alert button '\(title)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        tapElementReliably(button, timeout: timeout, file: file, line: line)

        let dismissedPredicate = NSPredicate(format: "exists == false")
        expectation(for: dismissedPredicate, evaluatedWith: alert)
        waitForExpectations(timeout: timeout)
        XCTAssertFalse(
            alert.exists,
            "Expected the alert to dismiss after tapping '\(title)'.",
            file: file,
            line: line
        )
    }

    /**
     Performs a direct top-edge drag to dismiss a presented sheet.
     *
     * - Parameter element: Visible sheet-root element that should respond to the dismissal drag.
     * - Side effects:
     *   - drags from near the sheet's top edge toward the bottom of the screen, which dismisses
     *     the sheet instead of scrolling the sheet content
     * - Failure modes:
     *   - records an XCTest failure if the element never exposes a usable frame
     */
    private func dismissSheetByDraggingDown(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            element.frame.isEmpty,
            "Expected sheet element '\(element.identifier)' to expose a non-empty frame before dismissal.",
            file: file,
            line: line
        )
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03))
        let finish = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: finish)
    }

    /**
     Waits for one previously resolved element to disappear from the live hierarchy.
     *
     * - Parameters:
     *   - element: Previously visible element expected to disappear.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - blocks the current test until the element no longer exists
     * - Failure modes:
     *   - records an XCTest failure if the element remains visible after the timeout
     */
    private func waitForElementToDisappear(
        _ element: XCUIElement,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "exists == false")
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
        XCTAssertFalse(
            element.exists,
            "Expected element '\(element.identifier)' to disappear within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Dismisses one lingering alert through its cancel button when the alert is still present.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the alert/cancel button.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - taps the visible cancel button only when an alert is still present after a flow that
     *     should already have dismissed it
     * - Failure modes:
     *   - records an XCTest failure if a presented alert exposes no cancel button or refuses to
     *     dismiss after the cancel tap
     */
    private func dismissAlertIfPresent(
        in app: XCUIApplication,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let alert = app.alerts.firstMatch
        guard alert.exists || alert.waitForExistence(timeout: min(1, timeout)) else {
            return
        }

        let cancelButton = alert.buttons["Cancel"].firstMatch
        XCTAssertTrue(
            cancelButton.waitForExistence(timeout: timeout),
            "Expected lingering alert '\(alert.label)' to expose a Cancel button within \(timeout) seconds.",
            file: file,
            line: line
        )
        tapElementReliably(cancelButton, timeout: timeout, file: file, line: line)
        waitForElementToDisappear(alert, timeout: timeout, file: file, line: line)
    }

    /**
     Closes the workspace selector when switching rows did not dismiss it automatically.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the selector to dismiss on its own after a workspace switch
     *   - taps the real toolbar Done button when the selector remains visible
     * - Failure modes:
     *   - records an XCTest failure if the selector is still visible after the timeout expires
     */
    private func dismissWorkspaceSelectorIfStillPresented(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let selector = unresolvedElement("workspaceSelectorScreen", in: app)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if !selector.exists {
                return
            }

            let doneButton = app.buttons["workspaceSelectorDoneButton"].firstMatch
            if doneButton.exists || doneButton.waitForExistence(timeout: 0.5) {
                tapElementReliably(doneButton, timeout: 5, file: file, line: line)
                if selector.exists {
                    waitForElementToDisappear(selector, timeout: min(10, deadline.timeIntervalSinceNow), file: file, line: line)
                }
                return
            }

            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }

        XCTFail(
            "Expected the workspace selector to dismiss within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Resolves the visible text-entry control for Search across system search-field variants.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait while revealing and re-querying the search control.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first visible Search input control exposed as either a `SearchField` or
     *   generic `TextField`.
     * - Side effects:
     *   - re-queries the Search hierarchy across a few downward swipes to reveal system search UI
     *     variants that are not immediately visible in hosted simulators
     * - Failure modes:
     *   - records an XCTest failure if neither control type appears before the timeout expires
     */
    private func requireSearchInput(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let identifiedField = resolvedElement("searchQueryField", in: app),
               identifiedField.exists,
               (identifiedField.isHittable || !identifiedField.frame.isEmpty)
            {
                return identifiedField
            }
            let fieldCandidates = [
                app.textFields["searchQueryField"].firstMatch,
                app.otherElements["searchQueryField"].firstMatch,
                app.searchFields["searchQueryField"].firstMatch,
                app.navigationBars.searchFields.firstMatch,
                app.searchFields.firstMatch,
                app.navigationBars.textFields.firstMatch,
                app.textFields.firstMatch,
            ]

            if let field = fieldCandidates.first(where: {
                ($0.exists || $0.waitForExistence(timeout: 0.2)) && ($0.isHittable || !$0.frame.isEmpty)
            }) {
                return field
            }
            revealSearchControls(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        XCTFail(
            "Expected Search text field to exist.",
            file: file,
            line: line
        )
        return unresolvedElement("searchQueryField", in: app)
    }

    /**
     Reads the current Search input value from a freshly resolved live field.
     *
     * - Parameter app: Running application under test.
     * - Returns: The current Search field value, or an empty string when no live Search field is
     *   currently exposed.
     * - Side effects:
     *   - re-queries the live Search field hierarchy instead of relying on a previously resolved
     *     XCUI element handle
     * - Failure modes:
     *   - returns an empty string when the Search input is temporarily absent or its value is not a
     *     string
     */
    private func resolvedSearchInputValue(in app: XCUIApplication) -> String {
        let candidates = [
            app.searchFields.firstMatch,
            app.textFields.firstMatch,
        ]

        for candidate in candidates where candidate.exists && !candidate.frame.isEmpty {
            return candidate.value as? String ?? ""
        }

        return ""
    }

    /**
     Resolves the visible Create button from Search's index prompt while excluding the root Search
     screen element that XCTest may misclassify as a button on some simulator runtimes.
     *
     * - Parameter app: Running application under test.
     * - Returns: The first real Create button candidate, or an unresolved query when none exists.
     * - Side effects:
     *   - queries the live XCUI hierarchy for buttons labeled `Create`
     * - Failure modes:
     *   - returns an unresolved fallback element when the prompt button is unavailable
     */
    private func resolveSearchCreateIndexButton(in app: XCUIApplication) -> XCUIElement {
        let alertCreateButton = app.alerts.firstMatch.buttons["Create"].firstMatch
        if alertCreateButton.exists || alertCreateButton.waitForExistence(timeout: 0.5) {
            return alertCreateButton
        }

        let sheetCreateButton = app.sheets.firstMatch.buttons["Create"].firstMatch
        if sheetCreateButton.exists || sheetCreateButton.waitForExistence(timeout: 0.5) {
            return sheetCreateButton
        }

        let visibleCreateButton = app.buttons["Create"].firstMatch
        if visibleCreateButton.exists || visibleCreateButton.waitForExistence(timeout: 0.5) {
            return visibleCreateButton
        }

        return visibleCreateButton
    }

    /**
     Resolves the text field used by the Label Manager create-label alert.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The best available alert text field, preferring the explicit accessibility
     *   identifier when SwiftUI exposes it.
     * - Side effects:
     *   - waits for the alert to appear and then re-queries its text fields
     * - Failure modes:
     *   - records an XCTest failure if the create-label alert or its text field never appears
     */
    private func requireLabelManagerNewLabelField(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let field = resolveLabelCreationPromptTextField(in: app),
               field.exists,
               (field.isHittable || !field.frame.isEmpty) {
                return field
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let fallback = app.alerts.firstMatch.textFields["labelManagerNewLabelNameField"].firstMatch
        XCTAssertTrue(
            fallback.exists,
            "Expected the Label Manager create prompt text field to appear within \(timeout) seconds.",
            file: file,
            line: line
        )
        return fallback
    }

    /**
     Resolves the create action button shown by the Label Manager create-label alert.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The best available create button, preferring the explicit accessibility
     *   identifier when SwiftUI exposes it.
     * - Side effects:
     *   - waits for the alert to appear and then re-queries its action buttons
     * - Failure modes:
     *   - records an XCTest failure if the create button never appears
     */
    private func requireLabelManagerCreateButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let button = resolveLabelCreationPromptCreateButton(in: app),
               button.exists,
               (button.isHittable || !button.frame.isEmpty) {
                return button
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let fallback = app.alerts.firstMatch.buttons["labelManagerCreateButton"].firstMatch
        XCTAssertTrue(
            fallback.exists,
            "Expected the Label Manager create prompt button to appear within \(timeout) seconds.",
            file: file,
            line: line
        )
        return fallback
    }

    /**
     Waits for the Settings screen to expose at least one stable production control.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before giving up.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: `true` when Settings is ready for interaction, otherwise `false`.
     * - Side effects:
     *   - dismisses the language restart confirmation when it appears during navigation
     *   - polls the Settings screen for both the form root and stable row identifiers
     * - Failure modes: This helper does not fail directly.
     */
    private func waitForSettingsReady(
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let settingsForm = resolvedElement("settingsForm", in: app),
               settingsForm.exists,
               !settingsForm.frame.isEmpty
            {
                return true
            }

            if resolvedElement("settingsForm", in: app) != nil {
                return true
            }

            let alert = app.alerts.firstMatch
            let okButton = alert.buttons["OK"].firstMatch
            if alert.exists && okButton.exists && !okButton.frame.isEmpty {
                tapElementReliably(okButton, timeout: 2, file: file, line: line)
                continue
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return false
    }

    /**
     Waits for the exported Settings screen state to contain one deterministic token.
     *
     * - Parameters:
     *   - expectedToken: Token expected inside the semicolon-delimited Settings screen state.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to poll before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly reads the production `settingsForm` accessibility value
     * - Failure modes:
     *   - records an XCTest failure if the requested token never appears before timeout
     */
    private func waitForSettingsState(
        containing expectedToken: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let settingsForm = requireElement("settingsForm", in: app, timeout: timeout, file: file, line: line)
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let state = settingsForm.value as? String, state.contains(expectedToken) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalState = settingsForm.value as? String ?? ""
        XCTFail(
            "Expected Settings state to contain '\(expectedToken)' within \(timeout) seconds. Last state: '\(finalState)'.",
            file: file,
            line: line
        )
    }

    /**
     Waits for the My Notes screen title to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the My Notes title.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the My Notes title appears
     * - Failure modes:
     *   - records an XCTest failure if the native My Notes title never appears before timeout
     */
    private func waitForMyNotesPresentation(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            requireElement("readerMyNotesTitle", in: app, timeout: timeout, file: file, line: line).exists,
            file: file,
            line: line
        )
    }

    /**
     Waits for the StudyPad screen title to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the StudyPad title.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the StudyPad title appears
     * - Failure modes:
     *   - records an XCTest failure if the native StudyPad title never appears before timeout
     */
    private func waitForStudyPadPresentation(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            requireElement("readerStudyPadTitle", in: app, timeout: timeout, file: file, line: line).exists,
            file: file,
            line: line
        )
    }

    /**
     Waits for a pre-scrolled settings row to become hittable, then taps it.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the target settings row.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the row to become hittable.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the requested settings row to resolve and become hittable
     *   - taps the target row once it becomes hittable
     * - Failure modes:
     *   - records an XCTest failure if the row never appears or never becomes hittable within the
     *     allotted timeout
     */
    private func tapSettingsElement(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let element = requireSettingsNavigationControl(
            identifier,
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
        if waitForElementToBecomeHittable(element, timeout: min(2, timeout)) {
            element.tap()
            return
        }
        if let settingsForm = resolvedElement("settingsForm", in: app),
           isElementVisible(element, within: settingsForm)
        {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return
        }
        tapElementReliably(element, timeout: timeout, file: file, line: line)
    }

    /**
     Opens the seeded `UI Test Seed` StudyPad handoff through the production bookmark-list controls.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - selects the real `UI Test Seed` filter chip
     *   - taps the production StudyPad handoff button shown for the selected label
     * - Failure modes:
     *   - fails if the production label-filter or StudyPad handoff controls are unavailable
     */
    private func openSeedStudyPadFromBookmarkList(in app: XCUIApplication) {
        selectBookmarkListFilterChip("UI_Test_Seed", in: app, timeout: 10)
        tapElementReliably(requireElement("bookmarkListOpenStudyPadButton::UI_Test_Seed", in: app, timeout: 10), timeout: 10)
    }

    /**
     Stable Search scope tokens mirrored from `SearchView` accessibility exports.
     */
    private enum SearchScopeToken: String {
        case oldTestament
        case newTestament

        var fallbackLabel: String {
            switch self {
            case .oldTestament:
                "OT"
            case .newTestament:
                "NT"
            }
        }
    }

    /**
     Creates the deterministic `UI Test Fresh` label from the label-assignment sheet.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - opens the native create-label alert
     *   - fills the label name field and confirms creation
     * - Failure modes:
     *   - fails if the create-label alert cannot be presented or completed
     */
    private func createFreshLabelFromAssignment(in app: XCUIApplication) {
        presentLabelCreationPrompt(in: app, timeout: 10)
        let nameField = requireLabelManagerNewLabelField(in: app, timeout: 10)
        replaceText(in: nameField, with: "UI Test Fresh")
        tapElementReliably(requireLabelManagerCreateButton(in: app, timeout: 10), timeout: 10)
    }

    /**
     Dismisses Label Assignment back to the bookmark list and waits for the transition to settle.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to wait for the sheet dismissal to complete.
     * - Side effects:
     *   - taps the production done button on Label Assignment
     *   - polls the live hierarchy until the label-assignment surface disappears and the bookmark
     *     list becomes visible again
     * - Failure modes:
     *   - fails if the dismiss action cannot be tapped
     *   - fails if the sheet never dismisses fully back to the bookmark list within the timeout
     */
    private func dismissLabelAssignmentToBookmarkList(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tapElementReliably(
            requireElement("labelAssignmentDoneButton", in: app, timeout: timeout),
            timeout: timeout
        )

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let labelAssignmentVisible = resolvedElement("labelAssignmentScreen", in: app) != nil
            let bookmarkListVisible = resolvedElement("bookmarkListScreen", in: app) != nil
            if !labelAssignmentVisible && bookmarkListVisible {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline

        XCTAssertFalse(
            unresolvedElement("labelAssignmentScreen", in: app).exists,
            "Expected Label Assignment to dismiss within \(timeout) seconds.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            unresolvedElement("bookmarkListScreen", in: app).exists,
            "Expected the bookmark list to reappear within \(timeout) seconds after dismissing Label Assignment.",
            file: file,
            line: line
        )
    }

    /**
     Opens the create-label prompt from Label Assignment and waits for its field or action to
     surface before returning.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep retrying the production create-label control.
     * - Side effects:
     *   - taps the real create-label button and polls the live accessibility hierarchy for the
     *     prompt field/button until one appears
     * - Failure modes:
     *   - records an XCTest failure if the prompt never becomes reachable within the timeout
     */
    private func presentLabelCreationPrompt(
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        let trigger = requireElement("labelAssignmentCreateNewLabelButton", in: app, timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            tapElementReliably(trigger, timeout: 5)
            if resolvedLabelCreationPrompt(in: app) != nil
                || resolveLabelCreationPromptTextField(in: app) != nil
                || resolveLabelCreationPromptCreateButton(in: app) != nil
            {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTFail("Expected the Label Manager create prompt to appear within \(timeout) seconds.")
    }

    /// Resolves the compact exported Search state element when Search is presented.
    private func resolvedSearchStateElement(in app: XCUIApplication) -> XCUIElement? {
        resolvedElement("searchStateExport", in: app) ?? resolvedElement("searchScreen", in: app)
    }

    /// Reads the current exported Search state without forcing the whole Search container query.
    private func resolvedSearchStateValue(in app: XCUIApplication) -> String? {
        if let stateElement = resolvedSearchStateElement(in: app),
           let value = stateElement.value as? String {
            return value
        }
        return nil
    }

    /// Returns the visible prompt container used by the create-label flow.
    private func resolvedLabelCreationPrompt(in app: XCUIApplication) -> XCUIElement? {
        let alert = app.alerts.firstMatch
        if alert.exists || alert.waitForExistence(timeout: 0.2) {
            return alert
        }

        let sheet = app.sheets.firstMatch
        if sheet.exists || sheet.waitForExistence(timeout: 0.2) {
            return sheet
        }

        return nil
    }

    /// Resolves the create-label prompt text field by scoping queries to the live prompt first.
    private func resolveLabelCreationPromptTextField(in app: XCUIApplication) -> XCUIElement? {
        if let prompt = resolvedLabelCreationPrompt(in: app) {
            let promptCandidates = [
                prompt.textFields["labelManagerNewLabelNameField"].firstMatch,
                prompt.textFields["Label name"].firstMatch,
                prompt.textFields.firstMatch,
            ]
            if let field = promptCandidates.first(where: { $0.exists }) {
                return field
            }
        }

        let appCandidates = [
            app.textFields["labelManagerNewLabelNameField"].firstMatch,
            app.textFields["Label name"].firstMatch,
        ]
        return appCandidates.first(where: { $0.exists })
    }

    /// Resolves the create-label prompt action button by scoping queries to the live prompt first.
    private func resolveLabelCreationPromptCreateButton(in app: XCUIApplication) -> XCUIElement? {
        if let prompt = resolvedLabelCreationPrompt(in: app) {
            let promptCandidates = [
                prompt.buttons["labelManagerCreateButton"].firstMatch,
                prompt.buttons["Create"].firstMatch,
            ]
            if let button = promptCandidates.first(where: { $0.exists }) {
                return button
            }
        }

        let appCandidates = [
            app.buttons["labelManagerCreateButton"].firstMatch,
            app.buttons["Create"].firstMatch,
        ]
        return appCandidates.first(where: { $0.exists })
    }

    /**
     Switches the bookmark list into Bible-order sorting through the production sort menu.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - opens the production sort menu and selects the Bible-order option
     * - Failure modes:
     *   - fails if the sort menu or Bible-order option is unavailable
     */
    private func sortBookmarkListByBibleOrder(in app: XCUIApplication) {
        requireElement("bookmarkListSortMenu", in: app, timeout: 10).tap()
        requireElement("bookmarkListSortOption::bibleOrder", in: app, timeout: 10).tap()
    }

    /**
     Toggles the seeded label row inside Label Assignment and verifies the combined state change.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - taps the seeded label's favourite and assignment controls
     *   - waits for the row accessibility value to update to the combined assigned/favourite state
     * - Failure modes:
     *   - fails if the seed row or either inline control is missing
     *   - fails if the row accessibility value never reaches `assigned,favourite`
     */
    private func assertSeedLabelAssignmentCanToggle(in app: XCUIApplication) {
        let seedRow = requireElement("labelAssignmentRow::UI_Test_Seed", in: app, timeout: 10)
        let initialState = seedRow.value as? String
        XCTAssertTrue(
            initialState == "assigned,notFavourite" || initialState == "unassigned,notFavourite",
            "Expected the seeded label row to start in a known non-favourite state, got '\(initialState ?? "nil")'."
        )

        let favouriteButton = requireElement(
            "labelAssignmentFavouriteButton::UI_Test_Seed",
            in: app,
            timeout: 10
        )
        let toggleButton = requireElement(
            "labelAssignmentToggleButton::UI_Test_Seed",
            in: app,
            timeout: 10
        )

        tapElementReliably(favouriteButton, timeout: 10)
        waitForElementValue("labelAssignmentRow::UI_Test_Seed", toEqual: "assigned,favourite", in: app, timeout: 10)

        if initialState == "assigned,notFavourite" {
            tapElementReliably(toggleButton, timeout: 10)
            waitForElementValue("labelAssignmentRow::UI_Test_Seed", toEqual: "unassigned,favourite", in: app, timeout: 10)
        }

        tapElementReliably(toggleButton, timeout: 10)
        waitForElementValue("labelAssignmentRow::UI_Test_Seed", toEqual: "assigned,favourite", in: app, timeout: 10)
    }

    /**
     Resolves one workspace row by its accessibility label.
     *
     * - Parameters:
     *   - name: User-visible workspace name expected on the row.
     *   - app: Running application under test.
     * - Returns: The first matching workspace-selector row button for the requested workspace.
     * - Side effects:
     *   - queries the live accessibility hierarchy for a workspace-selector row whose label matches
     *     `name`
     * - Failure modes:
     *   - returns an unresolved query when no matching row currently exists
     */
    private func workspaceRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        let predicate = NSPredicate(format: "label == %@", name)
        return app.buttons
            .matching(identifier: "workspaceSelectorRowButton")
            .matching(predicate)
            .firstMatch
    }

    /**
     Waits for a workspace row to appear and records a precise failure if it does not.
     *
     * - Parameters:
     *   - name: User-visible workspace name expected on the row.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved workspace-row UI element.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the requested row exists or the timeout
     *     expires
     * - Failure modes:
     *   - records an XCTest failure if the row never appears within the requested timeout
     */
    private func requireWorkspaceRow(
        named name: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = workspaceRow(named: name, in: app)
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected workspace row '\(name)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Waits for the active workspace row to appear.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The first workspace row whose accessibility value is `activeWorkspace`.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the active workspace row exists or the
     *     timeout expires
     * - Failure modes:
     *   - records an XCTest failure if no active workspace row becomes visible within the timeout
     */
    private func requireActiveWorkspaceRow(
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let predicate = NSPredicate(format: "value == %@", "activeWorkspace")
        let element = app.buttons
            .matching(identifier: "workspaceSelectorRowButton")
            .matching(predicate)
            .firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected an active workspace row within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Resolves one workspace inline action by button identifier and workspace label.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier exposed by the workspace selector inline action.
     *   - workspaceName: User-visible workspace name attached to the button's accessibility label.
     *   - app: Running application under test.
     * - Returns: The first matching inline action button.
     * - Side effects:
     *   - queries the live accessibility hierarchy for a button whose identifier and label match
     *     the requested workspace action
     * - Failure modes:
     *   - returns an unresolved query when no matching inline action button currently exists
     */
    private func workspaceInlineAction(
        identifier: String,
        workspaceName: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let labelPredicate = NSPredicate(format: "label == %@", workspaceName)
        return app.buttons
            .matching(identifier: identifier)
            .matching(labelPredicate)
            .firstMatch
    }

    /**
     Waits for a workspace inline action and records a precise failure if it does not appear.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier exposed by the workspace selector inline action.
     *   - workspaceName: User-visible workspace name attached to the button's accessibility label.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved inline workspace-action UI element.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the requested inline action becomes visible
     * - Failure modes:
     *   - records an XCTest failure if the action never appears within the requested timeout
     */
    private func requireWorkspaceInlineAction(
        identifier: String,
        workspaceName: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = workspaceInlineAction(
            identifier: identifier,
            workspaceName: workspaceName,
            in: app
        )
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected workspace action '\(identifier)' for '\(workspaceName)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Resolves one label row by its accessibility label.
     *
     * - Parameters:
     *   - name: User-visible label name expected on the row.
     *   - app: Running application under test.
     * - Returns: The first matching Label Manager row button for the requested label name.
     * - Side effects:
     *   - queries the live accessibility hierarchy for a label-manager row whose label matches
     *     `name`
     * - Failure modes:
     *   - returns an unresolved query when no matching row currently exists
     */
    private func labelRow(named name: String, in app: XCUIApplication) -> XCUIElement {
        let identifier = "labelManagerRowButton-\(name)"
        if let labelManagerScreen = resolvedElement("labelManagerScreen", in: app) {
            let scopedLink = labelManagerScreen.links[identifier].firstMatch
            if scopedLink.exists || scopedLink.waitForExistence(timeout: 0.5) {
                return scopedLink
            }
            let scopedButton = labelManagerScreen.buttons[identifier].firstMatch
            if scopedButton.exists || scopedButton.waitForExistence(timeout: 0.5) {
                return scopedButton
            }
        }
        let globalLink = app.links[identifier].firstMatch
        if globalLink.exists || globalLink.waitForExistence(timeout: 0.5) {
            return globalLink
        }
        return app.buttons[identifier].firstMatch
    }

    /**
     Waits for a label row to appear and records a precise failure if it does not.
     *
     * - Parameters:
     *   - name: User-visible label name expected on the row.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved label-row UI element.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the requested row exists or the timeout
     *     expires
     * - Failure modes:
     *   - records an XCTest failure if the row never appears within the requested timeout
     */
    private func requireLabelRow(
        named name: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = labelRow(named: name, in: app)
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected label row '\(name)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Resolves one label inline action by button identifier and label name.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier exposed by the label-manager inline action.
     *   - labelName: User-visible label name attached to the button's accessibility label.
     *   - app: Running application under test.
     * - Returns: The first matching inline action button.
     * - Side effects:
     *   - queries the live accessibility hierarchy for a button whose identifier and label match
     *     the requested label action
     * - Failure modes:
     *   - returns an unresolved query when no matching inline action button currently exists
     */
    private func labelInlineAction(
        identifier: String,
        labelName: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons["\(identifier)-\(labelName)"]
    }

    /**
     Waits for a label inline action and records a precise failure if it does not appear.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier exposed by the label-manager inline action.
     *   - labelName: User-visible label name attached to the button's accessibility label.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved inline label-action UI element.
     * - Side effects:
     *   - polls the live accessibility hierarchy until the requested inline action becomes visible
     * - Failure modes:
     *   - records an XCTest failure if the action never appears within the requested timeout
     */
    private func requireLabelInlineAction(
        identifier: String,
        labelName: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let element = labelInlineAction(identifier: identifier, labelName: labelName, in: app)
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected label action '\(identifier)' for '\(labelName)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
    }

    /**
     Replaces the entire contents of one text field with a new string.
     *
     * - Parameters:
     *   - element: Text field to overwrite.
     *   - text: Replacement text that should become the field's entire value.
     * - Side effects:
     *   - focuses the field, emits delete keystrokes for the current value, and types the
     *     replacement text through XCTest's software keyboard bridge
     * - Failure modes:
     *   - if the field reports a non-string value, the helper falls back to appending `text`
     *     instead of first deleting existing content
     */
    private func replaceText(in element: XCUIElement, with text: String) {
        let existingText = currentTextEntryValue(in: element)
        if existingText == text {
            return
        }

        let app = trackedApp ?? XCUIApplication()
        if !clearTextEntryElement(element, app: app) {
            XCTFail("Expected text input '\(element.identifier)' to clear before typing replacement text.")
            return
        }

        if !text.isEmpty {
            element.typeText(text)
        }
    }

    /**
     Resolves the current user-entered text for one text-entry control.
     *
     * - Parameter element: Focused text field or search field.
     * - Returns: The editable field contents, excluding placeholder/label text when the control
     *   is currently empty.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func currentTextEntryValue(in element: XCUIElement) -> String {
        guard let rawValue = element.value as? String else {
            return ""
        }

        let placeholderCandidates = Set(
            [element.label, element.identifier, element.placeholderValue ?? ""]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        let normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else {
            return ""
        }

        if placeholderCandidates.contains(normalizedValue) {
            return ""
        }

        return rawValue
    }

    /**
     Attempts to select the entire current field contents through the iOS edit menu.
     *
     * - Parameters:
     *   - element: Focused text-entry element whose contents should be selected.
     *   - app: Running application hosting the system edit menu.
     * - Returns: `true` when "Select All" became available and was tapped.
     * - Side effects:
     *   - double-taps the field and, when needed, long-presses it to surface edit actions
     * - Failure modes: This helper does not fail directly.
     */
    private func selectAllTextIfAvailable(
        in element: XCUIElement,
        app: XCUIApplication
    ) -> Bool {
        let selectAllMenuItem = app.menuItems["Select All"].firstMatch

        func tapSelectAllIfPresent(timeout: TimeInterval) -> Bool {
            if selectAllMenuItem.waitForExistence(timeout: timeout) {
                selectAllMenuItem.tap()
                return true
            }
            return false
        }

        element.press(forDuration: 1.0)
        if tapSelectAllIfPresent(timeout: 1) {
            return true
        }

        element.tap()
        return tapSelectAllIfPresent(timeout: 0.5)
    }

    /**
     Focuses one text-entry control through XCTest's native tap path without coordinate fallback.
     *
     * - Parameters:
     *   - element: Text field or search field that should receive keyboard focus.
     *   - timeout: Maximum number of seconds to wait for the control to expose a stable frame.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the text input to exist, then taps it directly so the software keyboard can
     *     attach without the slower coordinate-based path
     * - Failure modes:
     *   - records an XCTest failure if the text input never exists or never exposes a non-empty
     *     frame before timeout
     */
    private func focusTextEntryElement(
        _ element: XCUIElement,
        preferTrailingEdge: Bool = false,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected text input '\(element.identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists && waitForElementToBecomeHittable(element, timeout: 0.5) {
                if preferTrailingEdge, !element.frame.isEmpty {
                    element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
                } else {
                    element.tap()
                }
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTAssertTrue(
            waitForElementToBecomeHittable(element, timeout: 0),
            "Expected text input '\(element.identifier)' to become hittable within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Clears one text-entry control and verifies that the editable contents are empty afterward.
     *
     * - Parameters:
     *   - element: Text field or search field whose contents should be removed.
     *   - app: Running application hosting the keyboard/edit menu.
     * - Returns: `true` when the helper confirms the field is empty.
     * - Side effects:
     *   - focuses the field, taps the standard clear control when available, otherwise deletes the
     *     visible contents from the trailing edge and finally falls back to the edit menu
     * - Failure modes: This helper does not fail directly.
     */
    private func clearTextEntryElement(
        _ element: XCUIElement,
        app: XCUIApplication
    ) -> Bool {
        let existingText = currentTextEntryValue(in: element)
        if existingText.isEmpty {
            focusTextEntryElement(element, timeout: 10)
            return true
        }

        focusTextEntryElement(element, preferTrailingEdge: true, timeout: 10)

        let clearButton = element.buttons["Clear text"].firstMatch
        if waitForElementToBecomeHittable(clearButton, timeout: 0.5) {
            clearButton.tap()
            if currentTextEntryValue(in: element).isEmpty {
                return true
            }
        }

        var remainingText = currentTextEntryValue(in: element)
        for _ in 0..<2 where !remainingText.isEmpty {
            let deleteSequence = String(
                repeating: XCUIKeyboardKey.delete.rawValue,
                count: remainingText.count
            )
            element.typeText(deleteSequence)
            remainingText = currentTextEntryValue(in: element)
            if remainingText.isEmpty {
                return true
            }
        }

        if selectAllTextIfAvailable(in: element, app: app) {
            let selectionLength = max(currentTextEntryValue(in: element).count, 1)
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: selectionLength))
            if currentTextEntryValue(in: element).isEmpty {
                return true
            }
        }

        return currentTextEntryValue(in: element).isEmpty
    }

    /**
     Waits for one switch element to report the requested raw value.
     *
     * - Parameters:
     *   - element: Switch element whose accessibility value should be polled.
     *   - expectedValue: Raw switch value expected before the timeout expires.
     *   - timeout: Maximum time to keep polling before giving up.
     * - Returns: `true` when the switch reaches `expectedValue`, otherwise `false`.
     * - Side effects:
     *   - repeatedly samples the live XCUI switch value so delayed SwiftUI updates can settle
     * - Failure modes: This helper cannot fail.
     */
    private func waitForSwitchValue(
        _ element: XCUIElement,
        toEqual expectedValue: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (element.value as? String) == expectedValue {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        return (element.value as? String) == expectedValue
    }

    /**
     Toggles one switch element and retries with a second native tap when the first tap does not
     drive the underlying value change.
     *
     * - Parameters:
     *   - element: Switch element that should toggle.
     *   - expectedValue: Switch value expected after the toggle.
     *   - timeout: Maximum time to wait for the expected value before retrying/failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - performs one normal tap and, when needed, one more native tap on the same switch
     * - Failure modes:
     *   - records an XCTest failure when the switch never reaches `expectedValue`
     */
    private func toggleSwitchReliably(
        _ element: XCUIElement,
        expectedValue: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        tapElementReliably(element, timeout: timeout, file: file, line: line)
        if waitForSwitchValue(element, toEqual: expectedValue, timeout: min(timeout, 2)) {
            return
        }

        XCTAssertTrue(
            waitForElementToBecomeHittable(element, timeout: min(timeout, 2)),
            "Expected switch '\(element.identifier)' to become hittable before retrying the toggle.",
            file: file,
            line: line
        )
        element.tap()
        XCTAssertTrue(
            waitForSwitchValue(element, toEqual: expectedValue, timeout: min(timeout, 2)),
            "Expected switch '\(element.identifier)' to reach value '\(expectedValue)' within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

    /**
     Toggles one settings switch through the production switch control itself.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the production switch.
     *   - app: Running application under test.
     *   - expectedValue: Switch value expected after the toggle.
     *   - timeout: Maximum time to wait for the cell and switch to appear.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the real switch accessibility surface and toggles it through
     *     `toggleSwitchReliably`
     * - Failure modes:
     *   - records an XCTest failure when neither the row nor the switch can drive the expected
     *     value change
     */
    private func toggleSettingsSwitch(
        _ identifier: String,
        in app: XCUIApplication,
        expectedValue: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let toggle = app.switches[identifier].firstMatch
        XCTAssertTrue(
            toggle.waitForExistence(timeout: timeout),
            "Expected switch '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        toggleSwitchReliably(toggle, expectedValue: expectedValue, timeout: timeout, file: file, line: line)
    }

    /**
     Toggles one Sync category switch through the production switch control, then waits for the
     exported Sync screen state to confirm the mutation.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the production Sync category toggle.
     *   - app: Running application under test.
     *   - expectedScreenValue: Screen accessibility value expected after the toggle.
     *   - timeout: Maximum time to wait for the switch interaction and screen-state mutation.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly re-queries the exported Sync screen state and stops once the requested token
     *     appears
     *   - uses the real toggle control for each retry
     * - Failure modes:
     *   - records an XCTest failure if the switch never appears or if the Sync screen state does
     *     not reach the requested token after the interaction
     */
    private func toggleSyncCategory(
        _ identifier: String,
        in app: XCUIApplication,
        expectedScreenValue: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let toggle = app.buttons[identifier].firstMatch
        XCTAssertTrue(
            toggle.waitForExistence(timeout: timeout),
            "Expected sync category control '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        tapElementReliably(toggle, timeout: timeout, file: file, line: line)

        waitForElementValue(
            "syncSettingsState",
            toEqual: expectedScreenValue,
            in: app,
            timeout: timeout
        )
    }

    /**
     Toggles the real justify-text setting and treats the screen-level exported state as the
     authoritative mutation signal.
     *
     * - Parameters:
     *   - screen: Root Text Display screen element whose exported semantic state should change.
     *   - app: Running application under test.
     *   - expectedScreenToken: Screen accessibility token expected after the toggle.
     *   - timeout: Maximum time to keep retrying the real UI interaction.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly toggles the real justify-text switch and polls the exported screen state
     * - Failure modes:
     *   - records an XCTest failure if the switch never drives the screen state to the requested
     *     token within the timeout window
     */
    private func toggleTextDisplayJustifySwitch(
        on screen: XCUIElement,
        in app: XCUIApplication,
        expectedScreenToken: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let toggle = app.buttons["textDisplayJustifyTextToggleButton"].firstMatch
        XCTAssertTrue(
            toggle.waitForExistence(timeout: timeout),
            "Expected justify-text control to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        if (screen.value as? String)?.contains(expectedScreenToken) == true {
            return
        }
        tapElementReliably(toggle, timeout: timeout, file: file, line: line)

        waitForElementValue(
            "textDisplaySettingsScreen",
            toContain: expectedScreenToken,
            in: app,
            timeout: 1,
            file: file,
            line: line
        )
    }

    /**
     Returns the opposite serialized switch value for one live XCUI switch.
     *
     * - Parameter element: Live switch element whose current value should be inverted.
     * - Returns: The expected value string after one successful toggle.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func toggledSwitchValue(for element: XCUIElement) -> String {
        switch (element.value as? String)?.lowercased() {
        case "1", "true", "on":
            return "0"
        default:
            return "1"
        }
    }

    /**
     Polls one accessibility-identified element until its value or label contains a token.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier to re-resolve while polling.
     *   - token: Token expected to appear in the element value or label.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep polling before returning `false`.
     * - Returns: `true` when the element value or label contains `token`, otherwise `false`.
     * - Side effects:
     *   - repeatedly samples the live accessibility hierarchy while delayed SwiftUI updates settle
     * - Failure modes: This helper cannot fail.
     */
    private func waitForElementValueToContain(
        _ identifier: String,
        token: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = resolvedElement(identifier, in: app) {
                let value = element.value as? String
                if value?.contains(token) == true || element.label.contains(token) {
                    return true
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        if let element = resolvedElement(identifier, in: app) {
            let value = element.value as? String
            return value?.contains(token) == true || element.label.contains(token)
        }
        return false
    }

    /**
     Taps the NextCloud connection-test control until the exported status leaves the idle state.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep retrying the production button.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - dismisses the keyboard when needed, taps the real test-connection button, and polls the
     *     exported remote-status token until it changes
     * - Failure modes:
     *   - records an XCTest failure if the button never drives `syncRemoteStatus` away from `idle`
     */
    private func triggerSyncConnectionTest(
        in app: XCUIApplication,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = requireElement(
            "syncNextCloudTestConnectionButton",
            in: app,
            timeout: timeout,
            file: file,
            line: line
        )
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if let statusElement = resolvedElement("syncRemoteStatus", in: app),
               let statusValue = statusElement.value as? String,
               statusValue != "idle"
            {
                return
            }

            dismissKeyboardIfPresent(in: app)
            tapElementReliably(button, timeout: 5, file: file, line: line)

            let settleDeadline = Date().addingTimeInterval(2)
            repeat {
                if let statusElement = resolvedElement("syncRemoteStatus", in: app),
                   let statusValue = statusElement.value as? String,
                   statusValue != "idle"
                {
                    return
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            } while Date() < settleDeadline
        } while Date() < deadline

        let finalStatus = (resolvedElement("syncRemoteStatus", in: app)?.value as? String) ?? "nil"
        XCTAssertNotEqual(
            finalStatus,
            "idle",
            "Expected syncRemoteStatus to leave idle within \(timeout) seconds after triggering a connection test.",
            file: file,
            line: line
        )
    }

    /**
     Polls until one accessibility-identified element appears above another in the visible UI.
     *
     * - Parameters:
     *   - upperIdentifier: Accessibility identifier expected to resolve to the higher row.
     *   - lowerIdentifier: Accessibility identifier expected to resolve to the lower row.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep polling before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - repeatedly re-queries the live XCUI hierarchy for both identifiers until their visible
     *     frames settle into the requested vertical order
     *   - records an XCTest failure when the requested order never appears before timeout
     * - Failure modes:
     *   - fails when either element disappears or when the requested vertical ordering never
     *     materializes within the timeout window
     */
    private func waitForElement(
        _ upperIdentifier: String,
        toAppearAbove lowerIdentifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let upperElement = unresolvedElement(upperIdentifier, in: app)
            let lowerElement = unresolvedElement(lowerIdentifier, in: app)
            if upperElement.exists,
               lowerElement.exists,
               upperElement.frame.minY < lowerElement.frame.minY {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalUpperElement = unresolvedElement(upperIdentifier, in: app)
        let finalLowerElement = unresolvedElement(lowerIdentifier, in: app)
        XCTAssertTrue(
            finalUpperElement.exists && finalLowerElement.exists &&
                finalUpperElement.frame.minY < finalLowerElement.frame.minY,
            "Expected '\(upperIdentifier)' to appear above '\(lowerIdentifier)' within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

}
