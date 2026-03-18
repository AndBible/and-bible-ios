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
            trackedApp.terminate()
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
     *   - opens the reader overflow menu, validates the primary action rows, and pushes the
     *     settings screen
     * - Failure modes:
     *   - fails if any primary overflow-menu action is absent
     *   - fails if settings cannot be reached from the reader shell
     *   - fails if the settings form does not render after navigation completes
     */
    func testSettingsScreenShowsPrimaryNavigationRows() {
        let app = makeApp(openSettingsOnLaunch: true)
        app.launch()

        openSettings(in: app, launchedDirectly: true)
        XCTAssertTrue(requireSettingsNavigationControl("settingsDownloadsLink", in: app, timeout: 10).exists)
        XCTAssertTrue(requireSettingsNavigationControl("settingsSyncLink", in: app, timeout: 10).exists)
        XCTAssertTrue(requireSettingsNavigationControl("settingsTextDisplayLink", in: app, timeout: 10).exists)
        XCTAssertTrue(requireSettingsNavigationControl("settingsColorsLink", in: app, timeout: 10).exists)
    }

    /**
     Verifies that the direct-launch Search route preserves a seeded initial query.
     *
     * - Side effects:
     *   - launches the app directly into Search with the initial query `earth`
     *   - waits for the search sheet to hydrate and settle its exported state
     * - Failure modes:
     *   - fails if the direct-launch Search sheet never appears
     *   - fails if the seeded query is dropped before the Search screen reaches its settled state
     */
    func testSearchDirectLaunchRetainsSeededQuery() {
        let app = makeApp(openSearchOnLaunch: true, searchQuery: "earth")
        app.launch()

        let searchScreen = openSearch(in: app, launchedDirectly: true)
        waitForSearchToFinish(on: searchScreen, timeout: 120)

        let searchState = searchScreen.value as? String ?? ""
        XCTAssertTrue(
            searchState.contains("query=earth"),
            "Expected search state to retain the seeded query, got '\(searchState)'."
        )
    }

    /**
     Verifies that the direct-launch Search harness can build an index and return bundled results.
     *
     * - Side effects:
     *   - launches the app directly into Search with the initial query `earth`
     *   - waits for the disposable UI-test module set to be indexed and searched
     * - Failure modes:
     *   - fails if the Search screen never reaches the ready state after index creation
     *   - fails if the bundled module set is missing or the search still returns zero hits
     */
    func testSearchDirectLaunchBuildsIndexAndReturnsBundledResults() {
        let app = makeApp(openSearchOnLaunch: true, searchQuery: "earth")
        app.launch()

        let searchScreen = openSearch(in: app, launchedDirectly: true)
        waitForSearchToFinish(on: searchScreen, timeout: 120)

        let searchState = searchScreen.value as? String ?? ""
        let resultsCount = searchResultsCount(from: searchState)
        XCTAssertGreaterThan(
            resultsCount,
            0,
            "Expected bundled search results for 'earth', got '\(searchState)'."
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
        let app = makeApp(openSearchOnLaunch: true, searchQuery: "jesus")
        app.launch()

        let searchScreen = openSearch(in: app, launchedDirectly: true)
        waitForSearchToFinish(on: searchScreen, timeout: 120)

        let wholeBibleState = searchScreen.value as? String ?? ""
        XCTAssertTrue(
            wholeBibleState.contains("scope=wholeBible"),
            "Expected Search to start in whole-Bible scope, got '\(wholeBibleState)'."
        )
        XCTAssertGreaterThan(
            searchResultsCount(from: wholeBibleState),
            0,
            "Expected bundled whole-Bible hits for 'jesus', got '\(wholeBibleState)'."
        )

        tapButtonLabeled("OT", in: app)
        waitForSearchState(on: searchScreen, containing: "scope=oldTestament", timeout: 120)

        let oldTestamentState = searchScreen.value as? String ?? ""
        XCTAssertTrue(
            oldTestamentState.contains("scope=oldTestament"),
            "Expected Search to switch to Old Testament scope, got '\(oldTestamentState)'."
        )
        XCTAssertEqual(
            searchResultsCount(from: oldTestamentState),
            0,
            "Expected no Old Testament hits for 'jesus', got '\(oldTestamentState)'."
        )

        tapButtonLabeled("NT", in: app)
        waitForSearchState(on: searchScreen, containing: "scope=newTestament", timeout: 120)

        let newTestamentState = searchScreen.value as? String ?? ""
        XCTAssertTrue(
            newTestamentState.contains("scope=newTestament"),
            "Expected Search to switch to New Testament scope, got '\(newTestamentState)'."
        )
        XCTAssertGreaterThan(
            searchResultsCount(from: newTestamentState),
            0,
            "Expected bundled New Testament hits for 'jesus', got '\(newTestamentState)'."
        )
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
        let app = makeApp(openSearchOnLaunch: true, searchQuery: "earth void")
        app.launch()

        let searchScreen = openSearch(in: app, launchedDirectly: true)
        waitForSearchToFinish(on: searchScreen, timeout: 120)

        let allWordsState = searchScreen.value as? String ?? ""
        XCTAssertTrue(
            allWordsState.contains("wordMode=allWords"),
            "Expected Search to start in all-words mode, got '\(allWordsState)'."
        )
        XCTAssertGreaterThan(
            searchResultsCount(from: allWordsState),
            0,
            "Expected bundled all-words hits for 'earth void', got '\(allWordsState)'."
        )

        let phraseButton = app.buttons["Phrase"].firstMatch
        XCTAssertTrue(
            phraseButton.waitForExistence(timeout: 10),
            "Expected the visible Phrase Search mode button to exist."
        )
        phraseButton.tap()
        waitForSearchToFinish(on: searchScreen, timeout: 120)

        let phraseState = searchScreen.value as? String ?? ""
        XCTAssertTrue(
            phraseState.contains("wordMode=phrase"),
            "Expected Search to switch to phrase mode, got '\(phraseState)'."
        )
        XCTAssertEqual(
            searchResultsCount(from: phraseState),
            0,
            "Expected no phrase hits for 'earth void', got '\(phraseState)'."
        )

        let anyWordButton = app.buttons["Any Word"].firstMatch
        XCTAssertTrue(
            anyWordButton.waitForExistence(timeout: 10),
            "Expected the visible Any Word Search mode button to exist."
        )
        anyWordButton.tap()
        waitForSearchToFinish(on: searchScreen, timeout: 120)

        let anyWordState = searchScreen.value as? String ?? ""
        XCTAssertTrue(
            anyWordState.contains("wordMode=anyWord"),
            "Expected Search to switch to any-word mode, got '\(anyWordState)'."
        )
        XCTAssertGreaterThan(
            searchResultsCount(from: anyWordState),
            0,
            "Expected bundled any-word hits for 'earth void', got '\(anyWordState)'."
        )
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

        let currentReferenceState = requireElement("readerCurrentReferenceState", in: app, timeout: 10)
        XCTAssertEqual(currentReferenceState.label, "Genesis 1")

        let searchScreen = openSearch(in: app)
        waitForSearchToFinish(on: searchScreen, timeout: 120)

        let searchState = searchScreen.value as? String ?? ""
        XCTAssertTrue(
            searchState.contains("query=noah"),
            "Expected Search to run the seeded query, got '\(searchState)'."
        )
        XCTAssertGreaterThan(
            searchResultsCount(from: searchState),
            0,
            "Expected bundled search results for 'noah', got '\(searchState)'."
        )

        requireFirstSearchResultRow(in: app, timeout: 15).tap()

        let referencePredicate = NSPredicate(format: "label != %@", "Genesis 1")
        expectation(for: referencePredicate, evaluatedWith: currentReferenceState)
        waitForExpectations(timeout: 10)
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
        let app = makeApp(openDailyReadingOnLaunch: true)
        app.launch()

        XCTAssertTrue(requireElement("dailyReadingScreen", in: app, timeout: 15).exists)
        let currentDay = requireElement("dailyReadingCurrentDayLabel", in: app, timeout: 10)
        XCTAssertEqual(currentDay.value as? String, "1")

        requireElement("dailyReadingMarkAsReadButton", in: app, timeout: 10).tap()

        let advancedDayPredicate = NSPredicate(format: "value == %@", "2")
        expectation(for: advancedDayPredicate, evaluatedWith: currentDay)
        waitForExpectations(timeout: 10)
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
        let app = makeApp(openDownloadsOnLaunch: true)
        app.launch()

        XCTAssertTrue(openDownloads(in: app, launchedDirectly: true).exists)
    }

    /**
     Verifies that the downloads browser can open the repository manager and dismiss the add-source
     sheet back to the repository list.
     *
     * - Side effects:
     *   - launches the reader shell and opens Downloads from the real overflow menu
     *   - opens the repository manager from the real downloads toolbar button
     *   - opens the add-source sheet and cancels it
     * - Failure modes:
     *   - fails if the downloads browser or repository manager never appears
     *   - fails if the add-source sheet cannot be presented from the repository manager
     *   - fails if cancelling the add-source sheet does not return to the repository manager
     */
    func testDownloadsRepositoryManagerAddSourceCancelFlow() {
        let app = makeApp(openDownloadsOnLaunch: true)
        app.launch()

        XCTAssertTrue(openDownloads(in: app, launchedDirectly: true).exists)
        requireElement("moduleBrowserRepositoriesButton", in: app, timeout: 10).tap()

        XCTAssertTrue(requireElement("repositoryManagerScreen", in: app, timeout: 10).exists)
        requireElement("repositoryManagerAddButton", in: app, timeout: 10).tap()

        XCTAssertTrue(requireElement("repositoryManagerAddSourceScreen", in: app, timeout: 10).exists)
        requireElement("repositoryManagerAddSourceCancelButton", in: app, timeout: 10).tap()

        XCTAssertTrue(requireElement("repositoryManagerScreen", in: app, timeout: 10).exists)
    }

    /**
     Verifies that workspaces can be created, renamed, cloned, and deleted from the workspace
     selector.
     *
     * - Side effects:
     *   - launches the app directly into the workspace selector
     *   - creates one workspace, renames it through the test-only inline action surface, clones
     *     it, switches back to the original active workspace, and deletes the cloned and renamed
     *     workspaces
     * - Failure modes:
     *   - fails if the direct-launch workspace selector never appears
     *   - fails if any alert, inline workspace action, or workspace row required for the CRUD flow
     *     does not appear or does not update the selector state as expected
     */
    func testWorkspaceSelectorCreateRenameCloneDeleteFlow() {
        let app = makeApp(openWorkspacesOnLaunch: true)
        let createdName = "W1"
        let renamedName = "W2"
        let cloneName = "W3"
        app.launchEnvironment["UITEST_WORKSPACE_CREATE_NAME"] = createdName
        app.launchEnvironment["UITEST_WORKSPACE_RENAME_NAME"] = renamedName
        app.launchEnvironment["UITEST_WORKSPACE_CLONE_NAME"] = cloneName
        app.launch()

        XCTAssertTrue(openWorkspaceSelector(in: app, launchedDirectly: true).exists)
        let originalActiveWorkspaceName = requireActiveWorkspaceRow(in: app, timeout: 10).label

        requireElement("workspaceSelectorAddButton", in: app, timeout: 10).tap()

        _ = requireWorkspaceRow(named: createdName, in: app, timeout: 10)

        requireWorkspaceInlineAction(
            identifier: "workspaceSelectorInlineRenameButton",
            workspaceName: createdName,
            in: app,
            timeout: 10
        ).tap()

        _ = requireWorkspaceRow(named: renamedName, in: app, timeout: 10)

        requireWorkspaceInlineAction(
            identifier: "workspaceSelectorInlineCloneButton",
            workspaceName: renamedName,
            in: app,
            timeout: 10
        ).tap()

        _ = requireWorkspaceRow(named: cloneName, in: app, timeout: 10)

        requireWorkspaceInlineAction(
            identifier: "workspaceSelectorInlineDeleteButton",
            workspaceName: cloneName,
            in: app,
            timeout: 10
        ).tap()
        requireWorkspaceInlineAction(
            identifier: "workspaceSelectorInlineDeleteButton",
            workspaceName: renamedName,
            in: app,
            timeout: 10
        ).tap()

        let deletedPredicate = NSPredicate(format: "exists == false")
        expectation(for: deletedPredicate, evaluatedWith: workspaceRow(named: cloneName, in: app))
        expectation(for: deletedPredicate, evaluatedWith: workspaceRow(named: renamedName, in: app))
        waitForExpectations(timeout: 10)
        XCTAssertEqual(requireActiveWorkspaceRow(in: app, timeout: 10).label, originalActiveWorkspaceName)
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
        let app = makeApp(openBookmarksOnLaunch: true, seedBookmarkLabelWorkflowOnLaunch: true)
        app.launch()

        XCTAssertTrue(openBookmarkList(in: app, launchedDirectly: true).exists)
    }

    /**
     Verifies that the direct My Notes launch route shows the native notes header and can return
     to the Bible reader shell.
     *
     * - Side effects:
     *   - launches the app with one deterministic `Genesis 1:1` bookmark note seeded for the
     *     current chapter
     *   - opens My Notes directly through the reader-shell XCUITest harness
     *   - returns to the Bible header by tapping the native My Notes back button
     * - Failure modes:
     *   - fails if the direct My Notes route never presents its native header
     *   - fails if the seeded reader reference is not `Genesis 1`
     *   - fails if the direct My Notes route never reaches the harness-exported settled
     *     presentation state before the return action is attempted
     *   - fails if returning from My Notes does not restore the direct-launch reader-shell
     *     harness controls
     */
    func testMyNotesDirectLaunchShowsHeaderAndReturnsToBible() {
        let app = makeApp(openMyNotesOnLaunch: true)
        app.launch()

        let currentReferenceState = requireElement("readerCurrentReferenceState", in: app, timeout: 10)
        XCTAssertEqual(currentReferenceState.label, "Genesis 1")
        waitForMyNotesPresentation(in: app, timeout: 35)

        let backButton = requireElement("uiTestReturnFromMyNotesButton", in: app, timeout: 10)
        backButton.tap()

        let myNotesTitle = app.staticTexts["readerMyNotesTitle"]
        let dismissedPredicate = NSPredicate(format: "exists == false")
        expectation(for: dismissedPredicate, evaluatedWith: myNotesTitle)
        waitForExpectations(timeout: 10)

        XCTAssertEqual(currentReferenceState.label, "Genesis 1")
        XCTAssertTrue(requireElement("uiTestReopenMyNotesButton", in: app, timeout: 10).exists)
    }

    /**
     Verifies that the seeded My Notes bookmark note can be updated and that the updated note state
     persists after returning to the reader and reopening My Notes.
     *
     * - Side effects:
     *   - launches the app with one deterministic `Genesis 1:1` note-bearing bookmark and opens
     *     My Notes directly through the reader-shell harness
     *   - triggers the native XCUITest My Notes update action, which rewrites the seeded note to
     *     one deterministic replacement value and reloads the My Notes document
     *   - returns to the Bible reader shell and reopens My Notes through the native harness button
     * - Failure modes:
     *   - fails if the direct My Notes route never presents its native header
     *   - fails if the exported note state never reaches the seeded or updated tokens
     *   - fails if reopening My Notes does not preserve the updated note state
     */
    func testMyNotesSeededNoteUpdatePersistsAcrossReturnAndReopen() {
        let app = makeApp(openMyNotesOnLaunch: true)
        app.launch()

        waitForMyNotesPresentation(in: app, timeout: 35)
        waitForElementValue(
            "uiTestMyNotesNoteState",
            toEqual: "seeded:UI_Test_My_Notes_Note",
            in: app,
            timeout: 10
        )

        requireElement("uiTestUpdateMyNotesNoteButton", in: app, timeout: 10).tap()
        waitForElementValue(
            "uiTestMyNotesNoteState",
            toEqual: "updated:UI_Test_My_Notes_Updated_Note",
            in: app,
            timeout: 10
        )

        requireElement("uiTestReturnFromMyNotesButton", in: app, timeout: 10).tap()
        XCTAssertTrue(requireElement("uiTestReopenMyNotesButton", in: app, timeout: 10).exists)

        requireElement("uiTestReopenMyNotesButton", in: app, timeout: 10).tap()
        waitForMyNotesPresentation(in: app, timeout: 20)
        waitForElementValue(
            "uiTestMyNotesNoteState",
            toEqual: "updated:UI_Test_My_Notes_Updated_Note",
            in: app,
            timeout: 10
        )
    }

    /**
     Verifies that deleting the seeded My Notes note persists after returning to the reader and
     reopening My Notes.
     *
     * - Side effects:
     *   - launches the app with one deterministic `Genesis 1:1` note-bearing bookmark and opens
     *     My Notes directly through the reader-shell harness
     *   - triggers the native XCUITest My Notes delete action, which clears the seeded note and
     *     reloads the My Notes document
     *   - returns to the Bible reader shell and reopens My Notes through the native harness button
     * - Failure modes:
     *   - fails if the direct My Notes route never presents its native header
     *   - fails if the exported note state never reaches the seeded token before deletion
     *   - fails if reopening My Notes does not preserve the deleted note state
     */
    func testMyNotesSeededNoteDeletePersistsAcrossReturnAndReopen() {
        let app = makeApp(openMyNotesOnLaunch: true)
        app.launch()

        waitForMyNotesPresentation(in: app, timeout: 35)
        waitForElementValue(
            "uiTestMyNotesNoteState",
            toEqual: "seeded:UI_Test_My_Notes_Note",
            in: app,
            timeout: 10
        )

        requireElement("uiTestDeleteMyNotesNoteButton", in: app, timeout: 10).tap()
        waitForElementValue(
            "uiTestMyNotesNoteState",
            toEqual: "deleted",
            in: app,
            timeout: 10
        )

        requireElement("uiTestReturnFromMyNotesButton", in: app, timeout: 10).tap()
        XCTAssertTrue(requireElement("uiTestReopenMyNotesButton", in: app, timeout: 10).exists)

        requireElement("uiTestReopenMyNotesButton", in: app, timeout: 10).tap()
        waitForMyNotesPresentation(in: app, timeout: 20)
        waitForElementValue(
            "uiTestMyNotesNoteState",
            toEqual: "deleted",
            in: app,
            timeout: 10
        )
    }

    /**
     Verifies that selecting a seeded bookmark row dismisses the list and navigates the reader to
     that bookmark's chapter.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic `Exodus 2:1` bookmark while the reader
     *     itself stays on `Genesis 1`
     *   - opens the bookmark list from the actual reader overflow menu
     *   - taps the seeded bookmark row and waits for the exported bookmark-navigation state to
     *     confirm that the reader reached `Exodus 2`
     * - Failure modes:
     *   - fails if the bookmark list or seeded bookmark row never appears
     *   - fails if tapping the seeded bookmark row does not drive the reader to `Exodus 2`
     */
    func testBookmarkSelectionNavigatesReaderToSeededReference() {
        let app = makeApp(openBookmarksOnLaunch: true, seedBookmarkNavigationWorkflowOnLaunch: true)
        app.launch()

        let currentReferenceState = requireElement("readerCurrentReferenceState", in: app, timeout: 10)
        _ = requireElement("uiTestBookmarkNavigationState", in: app, timeout: 10)
        XCTAssertEqual(currentReferenceState.label, "Genesis 1")

        _ = openBookmarkList(in: app, launchedDirectly: true)
        let bookmarkRow = app.buttons["bookmarkListRowButton::Exodus_2_1"].firstMatch
        XCTAssertTrue(bookmarkRow.waitForExistence(timeout: 10), "Expected seeded bookmark row button to exist.")
        bookmarkRow.tap()

        waitForElementValue("uiTestBookmarkNavigationState", toEqual: "navigated:Exodus.2", in: app)
        XCTAssertEqual(currentReferenceState.label, "Exodus 2")
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
        let app = makeApp(openBookmarksOnLaunch: true, seedBookmarkMultiRowWorkflowOnLaunch: true)
        app.launch()

        openBookmarkList(in: app, launchedDirectly: true)
        let exodusRow = app.buttons["bookmarkListRowButton::Exodus_2_1"].firstMatch
        let matthewRow = app.buttons["bookmarkListRowButton::Matthew_3_1"].firstMatch
        XCTAssertTrue(exodusRow.waitForExistence(timeout: 10), "Expected Exodus bookmark row button to exist.")
        XCTAssertTrue(matthewRow.waitForExistence(timeout: 10), "Expected Matthew bookmark row button to exist.")

        exodusRow.swipeLeft()
        requireElement("bookmarkListDeleteButton::Exodus_2_1", in: app, timeout: 10).tap()

        let deletedPredicate = NSPredicate(format: "exists == false")
        expectation(for: deletedPredicate, evaluatedWith: exodusRow)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(matthewRow.exists, "Expected Matthew bookmark row to remain after deleting Exodus.")

        reopenBookmarkList(in: app, launchedDirectly: true)

        XCTAssertFalse(app.buttons["bookmarkListRowButton::Exodus_2_1"].firstMatch.exists)
        XCTAssertTrue(app.buttons["bookmarkListRowButton::Matthew_3_1"].firstMatch.exists)
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
        let app = makeApp(openBookmarksOnLaunch: true, seedBookmarkMultiRowWorkflowOnLaunch: true)
        app.launch()

        _ = openBookmarkList(in: app, launchedDirectly: true)
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
        let app = makeApp(openBookmarksOnLaunch: true, seedBookmarkMultiRowWorkflowOnLaunch: true)
        app.launch()

        _ = openBookmarkList(in: app, launchedDirectly: true)
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Expected bookmark search field to exist.")

        let exodusRow = app.buttons["bookmarkListRowButton::Exodus_2_1"].firstMatch
        let matthewRow = app.buttons["bookmarkListRowButton::Matthew_3_1"].firstMatch
        XCTAssertTrue(exodusRow.waitForExistence(timeout: 10), "Expected Exodus bookmark row button to exist.")
        XCTAssertTrue(matthewRow.waitForExistence(timeout: 10), "Expected Matthew bookmark row button to exist.")

        searchField.tap()
        searchField.typeText("Matthew")

        waitForElementValue(
            "bookmarkListHarnessState",
            toEqual: "bookmarkState=Matthew_3_1",
            in: app
        )

        replaceText(in: searchField, with: "")

        waitForElementValue(
            "bookmarkListHarnessState",
            toEqual: "bookmarkState=Exodus_2_1|Matthew_3_1",
            in: app
        )
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
        let app = makeApp(openBookmarksOnLaunch: true, seedBookmarkFilterWorkflowOnLaunch: true)
        app.launch()

        _ = openBookmarkList(in: app, launchedDirectly: true)
        let genesisRow = app.buttons["bookmarkListRowButton::Genesis_1_1"].firstMatch
        let exodusRow = app.buttons["bookmarkListRowButton::Exodus_2_1"].firstMatch
        XCTAssertTrue(genesisRow.waitForExistence(timeout: 10), "Expected Genesis bookmark row button to exist.")
        XCTAssertTrue(exodusRow.waitForExistence(timeout: 10), "Expected Exodus bookmark row button to exist.")

        requireElement("bookmarkListFilterChip::UI_Test_Seed", in: app, timeout: 10).tap()

        let hiddenPredicate = NSPredicate(format: "exists == false")
        expectation(for: hiddenPredicate, evaluatedWith: exodusRow)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(genesisRow.exists, "Expected Genesis bookmark row to remain visible for the selected label.")
        XCTAssertTrue(
            requireElement("bookmarkListOpenStudyPadButton::UI_Test_Seed", in: app, timeout: 10).exists,
            "Expected the seeded label StudyPad handoff to appear while the filter is active."
        )

        requireElement("bookmarkListFilterChip::all", in: app, timeout: 10).tap()

        XCTAssertTrue(genesisRow.waitForExistence(timeout: 10), "Expected Genesis bookmark row to remain visible after clearing the filter.")
        XCTAssertTrue(exodusRow.waitForExistence(timeout: 10), "Expected Exodus bookmark row to return after clearing the filter.")
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
        let app = makeApp(openBookmarksOnLaunch: true, seedBookmarkStudyPadWorkflowOnLaunch: true)
        app.launch()

        _ = openBookmarkList(in: app, launchedDirectly: true)
        openSeedStudyPadFromBookmarkList(in: app)

        let studyPadTitle = requireElement("readerStudyPadTitle", in: app, timeout: 10)
        XCTAssertEqual(studyPadTitle.label, "UI Test Seed")
    }

    /**
     Verifies that the seeded bookmark-label flow can open StudyPad and persist one deterministic
     note through the reader-shell StudyPad harness.
     *
     * - Side effects:
     *   - launches the reader shell with one deterministic `Genesis 1:1` bookmark assigned to the
     *     seeded `UI Test Seed` label
     *   - opens the bookmark list from the actual reader overflow menu, filters by the seeded
     *     label, and opens the real StudyPad handoff
     *   - triggers the reader-shell XCUITest StudyPad action, which persists one deterministic
     *     note and reloads the active StudyPad document
     * - Failure modes:
     *   - fails if the bookmark list, label filter, StudyPad handoff, or StudyPad shell action
     *     never appears
     *   - fails if the exported StudyPad note state never reaches the expected created token
     */
    func testBookmarkStudyPadCreateNoteFromLabelWorkflow() {
        let app = makeApp(openBookmarksOnLaunch: true, seedBookmarkStudyPadWorkflowOnLaunch: true)
        app.launch()

        _ = openBookmarkList(in: app, launchedDirectly: true)
        openSeedStudyPadFromBookmarkList(in: app)

        let studyPadTitle = requireElement("readerStudyPadTitle", in: app, timeout: 10)
        XCTAssertEqual(studyPadTitle.label, "UI Test Seed")

        requireElement("uiTestCreateStudyPadNoteButton", in: app, timeout: 10).tap()
        waitForElementValue(
            "uiTestStudyPadNoteState",
            toEqual: "created:UI_Test_StudyPad_Note",
            in: app
        )
    }

    /**
     Verifies that selecting a seeded history row jumps the active reader to that prior location.
     *
     * - Side effects:
     *   - launches the app with one deterministic persisted history row while staying on the real
     *     reader shell
     *   - opens History from the actual reader overflow menu
     *   - selects the seeded history row and waits for the reader's exported current-reference
     *     state to change from `Genesis 1` to `Exodus 2`
     * - Failure modes:
     *   - fails if the reader shell, History action, or seeded history row never appears
     *   - fails if selecting the history row does not update the reader's exported current
     *     reference state to `Exodus 2`
     */
    func testHistorySelectionNavigatesReaderToSeededReference() {
        let app = makeApp(openHistoryOnLaunch: true, seedHistoryWorkflowOnLaunch: true)
        app.launch()

        let currentReferenceState = requireElement("readerCurrentReferenceState", in: app, timeout: 10)
        let historyNavigationState = requireElement("uiTestHistoryNavigationState", in: app, timeout: 10)
        XCTAssertEqual(currentReferenceState.label, "Genesis 1")
        XCTAssertEqual(historyNavigationState.label, "idle")

        XCTAssertTrue(openHistory(in: app, launchedDirectly: true).exists)
        let historyRow = app.buttons["historyRow::Exod_2_1"].firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 10), "Expected seeded history row button to exist.")
        historyRow.tap()

        let navigationPredicate = NSPredicate(format: "label == %@", "navigated:Exod.2.1")
        expectation(for: navigationPredicate, evaluatedWith: historyNavigationState)

        let valuePredicate = NSPredicate(format: "label == %@", "Exodus 2")
        expectation(for: valuePredicate, evaluatedWith: currentReferenceState)
        waitForExpectations(timeout: 10)
    }

    /**
     Verifies that clearing history removes the seeded row and keeps History empty after reopen.
     *
     * - Side effects:
     *   - launches the app with one deterministic persisted history row while staying on the real
     *     reader shell
     *   - opens History through the direct-launch harness and verifies the seeded history state
     *   - clears the seeded history through the deterministic harness action, dismisses the screen,
     *     then reopens History to verify the persisted row remains deleted
     * - Failure modes:
     *   - fails if the direct-launch History screen or clear harness control never appears
     *   - fails if the exported history state never reaches `historyState=empty` after clearing or
     *     after reopening
     */
    func testHistoryClearRemovesSeededRowAcrossReopen() {
        let app = makeApp(openHistoryOnLaunch: true, seedHistoryWorkflowOnLaunch: true)
        app.launch()

        _ = openHistory(in: app, launchedDirectly: true)
        waitForElementValue("historyHarnessState", toEqual: "historyState=Exod_2_1", in: app)

        tapElementReliably(requireElement("historyHarnessClearButton", in: app, timeout: 10), timeout: 10)
        waitForElementValue("historyHarnessState", toEqual: "historyState=empty", in: app)

        tapElementReliably(requireElement("historyHarnessReopenButton", in: app, timeout: 10), timeout: 10)
        waitForElementValue("historyHarnessState", toEqual: "historyState=empty", in: app)
    }

    /**
     Verifies that deleting one history row leaves other history rows intact across reopen.
     *
     * - Side effects:
     *   - launches the app with two deterministic persisted history rows while staying on the real
     *     reader shell
     *   - opens History through the direct-launch harness and verifies the seeded multi-row state
     *   - deletes only the Exodus row through the deterministic harness action, dismisses the
     *     screen, and reopens History to confirm the Matthew row persists
     * - Failure modes:
     *   - fails if the direct-launch History screen or delete harness control never appears
     *   - fails if the exported history state does not collapse to `historyState=Matt_3_1` after
     *     deletion or after reopening
     */
    func testHistoryRowDeletePreservesOtherRowsAcrossReopen() {
        let app = makeApp(openHistoryOnLaunch: true, seedHistoryMultiRowWorkflowOnLaunch: true)
        app.launch()

        _ = openHistory(in: app, launchedDirectly: true)
        waitForElementValue(
            "historyHarnessState",
            toEqual: "historyState=Exod_2_1|Matt_3_1",
            in: app
        )

        tapElementReliably(requireElement("historyHarnessDeleteButton::Exod_2_1", in: app, timeout: 10), timeout: 10)
        waitForElementValue("historyHarnessState", toEqual: "historyState=Matt_3_1", in: app)

        tapElementReliably(requireElement("historyHarnessReopenButton", in: app, timeout: 10), timeout: 10)
        waitForElementValue("historyHarnessState", toEqual: "historyState=Matt_3_1", in: app)
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
        let app = makeApp(openBookmarksOnLaunch: true, seedBookmarkRowLabelWorkflowOnLaunch: true)
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
        let app = makeApp(openAboutOnLaunch: true)
        app.launch()

        XCTAssertTrue(requireElement("aboutScreen", in: app, timeout: 10).exists)
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
        let app = makeApp(openImportExportOnLaunch: true)
        app.launch()

        let importExportScreen = openImportExport(in: app, launchedDirectly: true)
        XCTAssertTrue(importExportScreen.exists)

        let fullBackupButton = requireElement("importExportFullBackupButton", in: app, timeout: 10)
        fullBackupButton.tap()

        let valuePredicate = NSPredicate(format: "value == %@", "shareSheetPresented")
        expectation(for: valuePredicate, evaluatedWith: importExportScreen)
        waitForExpectations(timeout: 15)
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
        let app = makeApp(openImportExportOnLaunch: true)
        app.launch()

        let importExportScreen = openImportExport(in: app, launchedDirectly: true)
        XCTAssertTrue(importExportScreen.exists)

        let importButton = requireElement("importExportImportButton", in: app, timeout: 10)
        importButton.tap()

        let valuePredicate = NSPredicate(format: "value == %@", "importPickerPresented")
        expectation(for: valuePredicate, evaluatedWith: importExportScreen)
        waitForExpectations(timeout: 15)
    }

    /**
     Verifies that label assignment can toggle both favourite and assignment state for a seeded
     label.
     *
     * - Side effects:
     *   - launches the app directly into one seeded label-assignment sheet
     *   - toggles the seed label's favourite state and assignment checkbox
     * - Failure modes:
     *   - fails if the direct-launch label-assignment route never appears
     *   - fails if the seed label row or either inline control is missing
     *   - fails if the row accessibility state never updates to the combined assigned/favourite
     *     value after the toggles
     */
    func testLabelAssignmentTogglesFavouriteAndAssignment() {
        let app = makeApp(openLabelAssignmentOnLaunch: true)
        app.launch()

        let labelAssignmentScreen = openLabelAssignment(in: app, launchedDirectly: true)
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
        let app = makeApp(openBookmarksOnLaunch: true, seedBookmarkRowLabelWorkflowOnLaunch: true)
        let newLabelName = "UI Test Fresh"
        let newLabelSegment = "UI_Test_Fresh"
        app.launch()

        _ = openLabelAssignmentFromBookmarkList(in: app)

        requireElement("labelAssignmentCreateNewLabelButton", in: app, timeout: 10).tap()
        let nameField = app.textFields["Label name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "Expected create-label text field to exist.")
        replaceText(in: nameField, with: newLabelName)
        app.buttons["Create"].firstMatch.tap()

        _ = requireElement("labelAssignmentRow::\(newLabelSegment)", in: app, timeout: 10)
        waitForElementValue(
            "labelAssignmentHarnessState",
            toEqual: "labelAssignmentState=\(newLabelSegment)",
            in: app
        )

        requireElement("labelAssignmentDoneButton", in: app, timeout: 10).tap()
        XCTAssertTrue(requireElement("bookmarkListScreen", in: app, timeout: 10).exists)
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
        let app = makeApp(openBookmarksOnLaunch: true, seedBookmarkStudyPadWorkflowOnLaunch: true)
        app.launch()

        _ = openLabelAssignmentFromBookmarkList(in: app)

        let seedRow = requireElement("labelAssignmentRow::UI_Test_Seed", in: app, timeout: 10)
        XCTAssertEqual(seedRow.value as? String, "assigned,notFavourite")
        requireElement("labelAssignmentToggleButton::UI_Test_Seed", in: app, timeout: 10).tap()

        let unassignedPredicate = NSPredicate(format: "value == %@", "unassigned,notFavourite")
        expectation(for: unassignedPredicate, evaluatedWith: seedRow)
        waitForExpectations(timeout: 10)

        requireElement("labelAssignmentDoneButton", in: app, timeout: 10).tap()
        _ = requireElement("bookmarkListScreen", in: app, timeout: 10)

        requireElement("bookmarkListFilterChip::UI_Test_Seed", in: app, timeout: 10).tap()

        let hiddenPredicate = NSPredicate(format: "exists == false")
        let bookmarkRow = app.buttons["bookmarkListRowButton::Genesis_1_1"].firstMatch
        expectation(for: hiddenPredicate, evaluatedWith: bookmarkRow)
        waitForExpectations(timeout: 10)
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
        let app = makeApp(openBookmarksOnLaunch: true, seedBookmarkFilterWorkflowOnLaunch: true)
        app.launch()

        _ = openBookmarkList(in: app, launchedDirectly: true)
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Expected bookmark search field to exist.")

        let genesisRow = app.buttons["bookmarkListRowButton::Genesis_1_1"].firstMatch
        let exodusRow = app.buttons["bookmarkListRowButton::Exodus_2_1"].firstMatch
        XCTAssertTrue(genesisRow.waitForExistence(timeout: 10), "Expected Genesis bookmark row button to exist.")
        XCTAssertTrue(exodusRow.waitForExistence(timeout: 10), "Expected Exodus bookmark row button to exist.")

        requireElement("bookmarkListFilterChip::UI_Test_Seed", in: app, timeout: 10).tap()

        let hiddenPredicate = NSPredicate(format: "exists == false")
        expectation(for: hiddenPredicate, evaluatedWith: exodusRow)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(genesisRow.exists, "Expected Genesis bookmark row to remain under the seeded label filter.")

        searchField.tap()
        searchField.typeText("Exodus")
        app.keyboards.buttons["Search"].firstMatch.tap()

        expectation(for: hiddenPredicate, evaluatedWith: genesisRow)
        waitForExpectations(timeout: 10)

        reopenBookmarkList(in: app, launchedDirectly: true)
        waitForElementValue(
            "bookmarkListHarnessState",
            toEqual: "bookmarkState=Exodus_2_1|Genesis_1_1",
            in: app
        )
    }

    /**
     Verifies that labels can be created, renamed, and deleted from the label manager.
     *
     * - Side effects:
     *   - launches the app directly into the label manager
     *   - creates one new label, renames it through the edit sheet, and deletes it via swipe
     *     actions
     * - Failure modes:
     *   - fails if the create alert, edit sheet, or delete swipe action cannot be reached through
     *     the label manager UI
     *   - fails if the created or renamed label row never appears, or if the deleted row remains
     *     visible after deletion
     */
    func testLabelManagerCreateRenameDeleteFlow() {
        let app = makeApp(openLabelManagerOnLaunch: true)
        let originalName = "L1"
        let renamedName = "L2"
        app.launchEnvironment["UITEST_LABEL_CREATE_NAME"] = originalName
        app.launchEnvironment["UITEST_LABEL_RENAME_NAME"] = renamedName
        app.launch()

        XCTAssertTrue(openLabelManager(in: app, launchedDirectly: true).exists)

        requireElement("labelManagerAddButton", in: app, timeout: 10).tap()
        XCTAssertTrue(requireLabelRow(named: originalName, in: app, timeout: 10).exists)

        requireLabelInlineAction(
            identifier: "labelManagerInlineEditButton",
            labelName: originalName,
            in: app,
            timeout: 10
        ).tap()

        let renamedRow = requireLabelRow(named: renamedName, in: app, timeout: 10)
        XCTAssertTrue(renamedRow.exists)
        XCTAssertFalse(labelRow(named: originalName, in: app).exists)

        requireLabelInlineAction(
            identifier: "labelManagerInlineDeleteButton",
            labelName: renamedName,
            in: app,
            timeout: 10
        ).tap()

        let deletedPredicate = NSPredicate(format: "exists == false")
        expectation(for: deletedPredicate, evaluatedWith: labelRow(named: renamedName, in: app))
        waitForExpectations(timeout: 10)
    }

    /**
     Verifies that the sync settings screen can be opened from Settings.
     *
     * - Side effects:
     *   - launches the app directly into Settings with the sync row pre-scrolled into view
     *   - opens sync settings from the settings screen
     * - Failure modes:
     *   - fails if the Settings sync link is missing or never becomes hittable
     *   - fails if the sync settings screen does not render after navigation completes
     */
    func testSettingsSyncLinkOpensSyncSettings() {
        let app = makeApp(settingsTarget: "settingsSyncLink")
        app.launch()

        openSettings(in: app, launchedDirectly: true)
        tapSettingsElement("settingsSyncLink", in: app)

        XCTAssertTrue(requireElement("syncSettingsScreen", in: app, timeout: 10).exists)
    }

    /**
     Verifies that invalid NextCloud server input surfaces the expected validation status.
     *
     * - Side effects:
     *   - launches the app directly into Sync Settings with the backend seeded to NextCloud
     *   - enters one invalid server URL plus a username and triggers the manual connection test
     * - Failure modes:
     *   - fails if the direct-launch Sync Settings sheet never appears
     *   - fails if the NextCloud fields or test-connection button are missing
     *   - fails if the exported connection-test state never reaches `failureInvalidURL`
     */
    func testSyncSettingsNextCloudInvalidURLShowsValidationStatus() {
        let app = makeApp(openSyncOnLaunch: true, syncBackend: "NEXT_CLOUD")
        app.launch()

        _ = openSyncSettings(in: app, launchedDirectly: true)
        let serverField = requireElement("syncNextCloudServerURLField", in: app, timeout: 10)
        let usernameField = requireElement("syncNextCloudUsernameField", in: app, timeout: 10)
        let statusRow = requireElement("syncRemoteStatus", in: app, timeout: 10)

        serverField.tap()
        serverField.typeText("not-a-url")
        usernameField.tap()
        usernameField.typeText("tester")

        requireElement("syncNextCloudTestConnectionButton", in: app, timeout: 10).tap()

        let valuePredicate = NSPredicate(format: "value == %@", "failureInvalidURL")
        expectation(for: valuePredicate, evaluatedWith: statusRow)
        waitForExpectations(timeout: 10)
    }

    /**
     Verifies that disabling one seeded NextCloud sync category updates the exported Sync screen
     state.
     *
     * - Side effects:
     *   - launches the app directly into Sync Settings with NextCloud selected and bookmarks
     *     pre-enabled in the in-memory settings store
     *   - invokes the XCUITest-only inline disable action, which calls the real category-disable
     *     persistence path
     * - Failure modes:
     *   - fails if the seeded disable action never appears for the bookmarks category
     *   - fails if the Sync screen state does not start with `backend=NEXT_CLOUD;enabled=bookmarks`
     *   - fails if disabling the category does not update the exported Sync screen state to
     *     `backend=NEXT_CLOUD;enabled=none`
     */
    func testSyncSettingsCategoryToggleMutatesExportedState() {
        let app = makeApp(
            openSyncOnLaunch: true,
            syncBackend: "NEXT_CLOUD",
            syncEnabledCategories: "bookmarks"
        )
        app.launch()

        let syncScreen = openSyncSettings(in: app, launchedDirectly: true)
        XCTAssertEqual(
            syncScreen.value as? String,
            "backend=NEXT_CLOUD;enabled=bookmarks"
        )

        requireElement("syncCategoryDisableButton::bookmarks", in: app, timeout: 10).tap()
        waitForElementValue(
            "syncSettingsScreen",
            toEqual: "backend=NEXT_CLOUD;enabled=none",
            in: app,
            timeout: 10
        )
    }

    /**
     Verifies that disabling a seeded NextCloud sync category persists across a direct dismiss and
     reopen of Sync Settings.
     *
     * - Side effects:
     *   - launches the app directly into Sync Settings with NextCloud selected and bookmarks
     *     pre-enabled in the in-memory settings store
     *   - disables the bookmarks category through the XCUITest-only inline action
     *   - dismisses the Sync sheet, reopens it through the test-only reader-shell control, and
     *     rehydrates the screen from persisted settings state
     * - Failure modes:
     *   - fails if the seeded Sync screen does not start with `backend=NEXT_CLOUD;enabled=bookmarks`
     *   - fails if the direct dismiss or reopen controls never appear
     *   - fails if reopening the sheet does not preserve the exported `enabled=none` state token
     */
    func testSyncSettingsCategoryDisablePersistsAcrossDirectReopen() {
        let app = makeApp(
            openSyncOnLaunch: true,
            syncBackend: "NEXT_CLOUD",
            syncEnabledCategories: "bookmarks"
        )
        app.launch()

        let syncScreen = openSyncSettings(in: app, launchedDirectly: true)
        XCTAssertEqual(
            syncScreen.value as? String,
            "backend=NEXT_CLOUD;enabled=bookmarks"
        )

        requireElement("syncCategoryDisableButton::bookmarks", in: app, timeout: 10).tap()
        waitForElementValue(
            "syncSettingsScreen",
            toEqual: "backend=NEXT_CLOUD;enabled=none",
            in: app,
            timeout: 10
        )

        requireElement("syncSettingsDoneButton", in: app, timeout: 10).tap()
        requireElement("uiTestReopenSyncSettingsButton", in: app, timeout: 10).tap()

        let reopenedSyncScreen = requireElement("syncSettingsScreen", in: app, timeout: 10)
        XCTAssertEqual(
            reopenedSyncScreen.value as? String,
            "backend=NEXT_CLOUD;enabled=none"
        )
    }

    /**
     Verifies that switching the active sync backend swaps the visible Sync section and exported
     backend state.
     *
     * - Side effects:
     *   - launches the app directly into Sync Settings with NextCloud selected in the in-memory
     *     settings store
     *   - invokes the XCUITest-only backend switch control to move from NextCloud to Google Drive
     * - Failure modes:
     *   - fails if the seeded NextCloud field or the Google Drive sign-in control never appears
     *   - fails if the exported Sync screen state does not move from `backend=NEXT_CLOUD;enabled=none`
     *     to `backend=GOOGLE_DRIVE;enabled=none`
     */
    func testSyncSettingsBackendSwitchMutatesVisibleSection() {
        let app = makeApp(openSyncOnLaunch: true, syncBackend: "NEXT_CLOUD")
        app.launch()

        let syncScreen = openSyncSettings(in: app, launchedDirectly: true)
        XCTAssertEqual(
            syncScreen.value as? String,
            "backend=NEXT_CLOUD;enabled=none"
        )
        XCTAssertTrue(requireElement("syncNextCloudServerURLField", in: app, timeout: 10).exists)

        tapSyncBackend("GOOGLE_DRIVE", in: app)
        waitForElementValue(
            "syncSettingsScreen",
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
     *   - launches the app directly into Sync Settings with NextCloud selected in the in-memory
     *     settings store
     *   - switches the backend from NextCloud to Google Drive through the XCUITest-only backend
     *     control
     *   - dismisses and reopens Sync Settings through the direct reader-shell harness so the sheet
     *     rehydrates from persisted settings state
     * - Failure modes:
     *   - fails if the seeded Sync screen does not start in the NextCloud branch
     *   - fails if the dismiss or reopen controls never appear
     *   - fails if reopening the sheet does not preserve the exported `backend=GOOGLE_DRIVE;enabled=none`
     *     state token or the Google Drive section
     */
    func testSyncSettingsBackendSwitchPersistsAcrossDirectReopen() {
        let app = makeApp(openSyncOnLaunch: true, syncBackend: "NEXT_CLOUD")
        app.launch()

        let syncScreen = openSyncSettings(in: app, launchedDirectly: true)
        XCTAssertEqual(
            syncScreen.value as? String,
            "backend=NEXT_CLOUD;enabled=none"
        )

        tapSyncBackend("GOOGLE_DRIVE", in: app)
        waitForElementValue(
            "syncSettingsScreen",
            toEqual: "backend=GOOGLE_DRIVE;enabled=none",
            in: app,
            timeout: 10
        )
        XCTAssertTrue(requireElement("syncGoogleDriveSignInButton", in: app, timeout: 10).exists)

        requireElement("syncSettingsDoneButton", in: app, timeout: 10).tap()
        requireElement("uiTestReopenSyncSettingsButton", in: app, timeout: 10).tap()

        let reopenedSyncScreen = requireElement("syncSettingsScreen", in: app, timeout: 10)
        XCTAssertEqual(
            reopenedSyncScreen.value as? String,
            "backend=GOOGLE_DRIVE;enabled=none"
        )
        XCTAssertTrue(requireElement("syncGoogleDriveSignInButton", in: app, timeout: 10).exists)
    }

    /**
    Verifies that toggling justify text mutates the exported control state.
     *
     * - Side effects:
     *   - launches the app directly into the text-display editor
     *   - toggles the justify-text control and waits for its accessibility value to change
     * - Failure modes:
     *   - fails if the direct-launch text-display editor never appears
     *   - fails if the justify-text toggle is missing or if its exported state never changes after
     *     the toggle
     */
    func testTextDisplayJustifyToggleMutatesControlState() {
        let app = makeApp(openTextDisplayOnLaunch: true)
        app.launch()

        let textDisplayScreen = openTextDisplaySettings(in: app, launchedDirectly: true)

        let justifyToggle = requireElement("textDisplayJustifyTextToggle", in: app, timeout: 10)
        let initialScreenState = textDisplayScreen.value as? String ?? ""
        let expectedJustifyState = initialScreenState.contains("justifyTextOn")
            ? "justifyTextOff|fontPickerHidden"
            : "justifyTextOn|fontPickerHidden"
        tapElementReliably(justifyToggle, timeout: 10)
        waitForElementValue(
            "textDisplaySettingsScreen",
            toEqual: expectedJustifyState,
            in: app,
            timeout: 10
        )
    }

    /**
     Verifies that the font-family control presents the native font picker from Text Display.
     *
     * - Side effects:
     *   - launches the app directly into the text-display editor
     *   - taps the font-family control, which presents the iOS font picker sheet
     * - Failure modes:
     *   - fails if the direct-launch text-display editor never appears
     *   - fails if the font-family control is missing or if the screen never reports
     *     `fontPickerPresented` after the tap
     */
    func testTextDisplayFontFamilyButtonPresentsFontPicker() {
        let app = makeApp(openTextDisplayOnLaunch: true)
        app.launch()

        let textDisplayScreen = openTextDisplaySettings(in: app, launchedDirectly: true)
        XCTAssertTrue(textDisplayScreen.exists)
        let fontFamilyButton = requireElement("textDisplayFontFamilyButton", in: app, timeout: 10)
        fontFamilyButton.tap()

        let valuePredicate = NSPredicate(format: "value CONTAINS %@", "fontPickerPresented")
        expectation(for: valuePredicate, evaluatedWith: textDisplayScreen)
        waitForExpectations(timeout: 10)
    }

    /**
     Verifies that the color editor can be opened from Settings.
     *
     * - Side effects:
     *   - launches the app directly into Settings with the colors row pre-scrolled into view
     *   - opens color settings from the settings screen
     * - Failure modes:
     *   - fails if the Settings colors link is missing or never becomes hittable
     *   - fails if the color settings screen does not render after navigation completes
     */
    func testSettingsColorsLinkOpensColorEditor() {
        let app = makeApp(settingsTarget: "settingsColorsLink")
        app.launch()

        openSettings(in: app, launchedDirectly: true)
        tapSettingsElement("settingsColorsLink", in: app)

        XCTAssertTrue(requireElement("colorSettingsScreen", in: app, timeout: 10).exists)
    }

    /**
     Verifies that the Colors reset action restores the seeded theme tuple to defaults.
     *
     * - Side effects:
     *   - launches the app directly into the Colors editor with a seeded non-default theme tuple
     *   - triggers the reset-to-defaults action and waits for the exported color state to return
     *     to the default marker
     * - Failure modes:
     *   - fails if the direct-launch Colors editor never appears
     *   - fails if the reset action is missing or if the exported color state never changes back
     *     to `colorDefaults`
     */
    func testColorSettingsResetRestoresDefaultThemeColors() {
        let app = makeApp(openColorsOnLaunch: true)
        app.launch()

        _ = openColorSettings(in: app, launchedDirectly: true)
        let colorState = app.staticTexts["colorSettingsState"].firstMatch
        XCTAssertTrue(colorState.waitForExistence(timeout: 10), "Expected color settings state label to exist.")
        XCTAssertEqual(colorState.label, "colorCustom")

        requireElement("colorSettingsResetButton", in: app, timeout: 10).tap()

        let valuePredicate = NSPredicate(format: "label == %@", "colorDefaults")
        expectation(for: valuePredicate, evaluatedWith: colorState)
        waitForExpectations(timeout: 10)
    }

    /**
     Builds the configured XCUIApplication instance used by each smoke test.
     *
     * - Parameters:
     *   - settingsTarget: Optional settings-row identifier that the app should open and pre-scroll
     *     into view on launch.
     *   - openSyncOnLaunch: Whether the app should present Sync Settings immediately on launch.
     *   - openSearchOnLaunch: Whether the app should present Search immediately on launch.
     *   - searchQuery: Optional search query to seed before a direct Search launch.
     *   - syncBackend: Optional remote backend raw value to seed before a direct Sync launch.
     *   - syncEnabledCategories: Optional comma-separated remote category raw values to seed as
     *     enabled before a direct Sync launch.
     *   - openTextDisplayOnLaunch: Whether the app should present Text Display immediately on
     *     launch.
     *   - openImportExportOnLaunch: Whether the app should present Import and Export immediately on
     *     launch.
     *   - openColorsOnLaunch: Whether the app should present Colors immediately on launch.
     *   - openLabelManagerOnLaunch: Whether the app should present Label Manager immediately on
     *     launch.
     *   - openLabelAssignmentOnLaunch: Whether the app should present one seeded label-assignment
     *     sheet immediately on launch.
     *   - seedBookmarkLabelWorkflowOnLaunch: Whether the app should seed one deterministic
     *     bookmark-plus-label workflow while still landing on the reader shell.
     *   - seedBookmarkRowLabelWorkflowOnLaunch: Whether the app should seed one deterministic
     *     bookmark-plus-label workflow while still landing on the reader shell and expose the real
     *     bookmark-row edit-label affordance.
     *   - seedBookmarkStudyPadWorkflowOnLaunch: Whether the app should seed one deterministic
     *     bookmark-plus-label workflow that can hand off into StudyPad from the real bookmark
     *     list.
     *   - seedBookmarkNavigationWorkflowOnLaunch: Whether the app should seed one deterministic
     *     bookmark-navigation target while still landing on the reader shell.
     *   - seedBookmarkMultiRowWorkflowOnLaunch: Whether the app should seed two deterministic
     *     bookmark rows while still landing on the reader shell.
     *   - seedBookmarkFilterWorkflowOnLaunch: Whether the app should seed two deterministic
     *     labeled bookmark rows while still landing on the reader shell.
     *   - seedHistoryWorkflowOnLaunch: Whether the app should seed one deterministic history row
     *     while still landing on the reader shell.
     *   - openReadingPlansOnLaunch: Whether the app should present Reading Plans immediately on
     *     launch.
     *   - openDailyReadingOnLaunch: Whether the app should present one seeded daily-reading view
     *     immediately on launch.
     *   - openMyNotesOnLaunch: Whether the app should seed one chapter note and present My Notes
     *     immediately on launch.
     *   - openWorkspacesOnLaunch: Whether the app should present Workspaces immediately on launch.
     * - Returns: App handle configured with deterministic launch arguments for the smoke suite.
     * - Side effects:
     *   - appends a launch argument that disables the discrete-mode calculator gate during UI tests
     *   - appends a launch argument that forces SwiftData-backed app state into an in-memory test
     *     container for deterministic launches
     *   - when `settingsTarget` is supplied, configures the app to present Settings immediately and
     *     scroll the requested row into view
     *   - when `openSearchOnLaunch` is `true`, configures the app to present Search immediately
     *     after the reader hydrates
     *   - when `searchQuery` is supplied, exports the requested initial query for the direct
     *     Search harness
     *   - when `openSyncOnLaunch` is `true`, configures the app to present Sync Settings
     *     immediately after the reader hydrates
     *   - when `syncBackend` is supplied, exports the requested backend raw value for the direct
     *     Sync Settings harness
     *   - when `syncEnabledCategories` is supplied, exports the requested enabled-category seed
     *     list for the direct Sync Settings harness
     *   - when `openTextDisplayOnLaunch` is `true`, configures the app to present Text Display
     *     immediately after the reader hydrates
     *   - when `openImportExportOnLaunch` is `true`, configures the app to present Import and
     *     Export immediately after the reader hydrates
     *   - when `openColorsOnLaunch` is `true`, configures the app to present Colors immediately
     *     after the reader hydrates with one seeded non-default color tuple
     *   - when `openLabelManagerOnLaunch` is `true`, configures the app to present Label Manager
     *     immediately after the reader hydrates
     *   - when `openLabelAssignmentOnLaunch` is `true`, configures the app to seed one bookmark
     *     plus labels and present Label Assignment immediately after the reader hydrates
     *   - when `seedBookmarkLabelWorkflowOnLaunch` is `true`, configures the app to seed one
     *     bookmark plus labels while leaving navigation at the reader shell
     *   - when `seedBookmarkRowLabelWorkflowOnLaunch` is `true`, configures the app to seed one
     *     bookmark plus labels while leaving navigation at the reader shell and keeps the
     *     production bookmark-row edit-label control active
     *   - when `seedBookmarkStudyPadWorkflowOnLaunch` is `true`, configures the app to seed one
     *     bookmark plus label pair that exposes the StudyPad handoff from the real bookmark list
     *   - when `seedBookmarkNavigationWorkflowOnLaunch` is `true`, configures the app to seed one
     *     bookmark-navigation target while leaving navigation at the reader shell
     *   - when `seedBookmarkMultiRowWorkflowOnLaunch` is `true`, configures the app to seed two
     *     bookmark rows while leaving navigation at the reader shell
     *   - when `seedBookmarkFilterWorkflowOnLaunch` is `true`, configures the app to seed two
     *     labeled bookmark rows while leaving navigation at the reader shell
     *   - when `seedHistoryWorkflowOnLaunch` is `true`, configures the app to seed one persisted
     *     history row while leaving navigation at the reader shell
     *   - when `seedHistoryMultiRowWorkflowOnLaunch` is `true`, configures the app to seed two
     *     persisted history rows while leaving navigation at the reader shell
     *   - when `openReadingPlansOnLaunch` is `true`, configures the app to present Reading Plans
     *     immediately after the reader hydrates
     *   - when `openDailyReadingOnLaunch` is `true`, configures the app to seed one reading plan
     *     and present its daily-reading view immediately after the reader hydrates
     *   - when `openMyNotesOnLaunch` is `true`, configures the app to seed one chapter note and
     *     present the native My Notes header immediately after the reader hydrates
     *   - when `openWorkspacesOnLaunch` is `true`, configures the app to present Workspaces
     *     immediately after the reader hydrates
     * - Failure modes: This helper cannot fail.
     */
    private func makeApp(
        settingsTarget: String? = nil,
        openSettingsOnLaunch: Bool = false,
        openBookmarksOnLaunch: Bool = false,
        openHistoryOnLaunch: Bool = false,
        openDownloadsOnLaunch: Bool = false,
        openAboutOnLaunch: Bool = false,
        openSearchOnLaunch: Bool = false,
        searchQuery: String? = nil,
        openSyncOnLaunch: Bool = false,
        syncBackend: String? = nil,
        syncEnabledCategories: String? = nil,
        openTextDisplayOnLaunch: Bool = false,
        openImportExportOnLaunch: Bool = false,
        openColorsOnLaunch: Bool = false,
        openLabelManagerOnLaunch: Bool = false,
        openLabelAssignmentOnLaunch: Bool = false,
        seedBookmarkLabelWorkflowOnLaunch: Bool = false,
        seedBookmarkRowLabelWorkflowOnLaunch: Bool = false,
        seedBookmarkStudyPadWorkflowOnLaunch: Bool = false,
        seedBookmarkNavigationWorkflowOnLaunch: Bool = false,
        seedBookmarkMultiRowWorkflowOnLaunch: Bool = false,
        seedBookmarkFilterWorkflowOnLaunch: Bool = false,
        seedHistoryWorkflowOnLaunch: Bool = false,
        seedHistoryMultiRowWorkflowOnLaunch: Bool = false,
        openReadingPlansOnLaunch: Bool = false,
        openDailyReadingOnLaunch: Bool = false,
        openMyNotesOnLaunch: Bool = false,
        openWorkspacesOnLaunch: Bool = false
    ) -> XCUIApplication {
        if let trackedApp, trackedApp.state != .notRunning {
            trackedApp.terminate()
        }
        let app = XCUIApplication()
        trackedApp = app
        app.launchArguments += ["UITEST_DISABLE_CALCULATOR_GATE", "UITEST_USE_IN_MEMORY_STORES"]
        app.launchEnvironment["UITEST_SESSION_ID"] = UUID().uuidString
        if openSettingsOnLaunch {
            app.launchArguments += ["UITEST_OPEN_SETTINGS"]
        }
        if let settingsTarget {
            app.launchArguments += ["UITEST_OPEN_SETTINGS"]
            app.launchEnvironment["UITEST_SETTINGS_SCROLL_TARGET"] = settingsTarget
        }
        if openBookmarksOnLaunch {
            app.launchArguments += ["UITEST_OPEN_BOOKMARKS"]
        }
        if openHistoryOnLaunch {
            app.launchArguments += ["UITEST_OPEN_HISTORY"]
        }
        if openDownloadsOnLaunch {
            app.launchArguments += ["UITEST_OPEN_DOWNLOADS"]
        }
        if openAboutOnLaunch {
            app.launchArguments += ["UITEST_OPEN_ABOUT"]
        }
        if openSearchOnLaunch {
            app.launchArguments += ["UITEST_OPEN_SEARCH"]
        }
        if let searchQuery {
            app.launchEnvironment["UITEST_SEARCH_QUERY"] = searchQuery
        }
        if openSyncOnLaunch {
            app.launchArguments += ["UITEST_OPEN_SYNC"]
        }
        if let syncBackend {
            app.launchEnvironment["UITEST_SYNC_BACKEND"] = syncBackend
        }
        if let syncEnabledCategories {
            app.launchEnvironment["UITEST_SYNC_ENABLED_CATEGORIES"] = syncEnabledCategories
        }
        if openTextDisplayOnLaunch {
            app.launchArguments += ["UITEST_OPEN_TEXT_DISPLAY"]
        }
        if openImportExportOnLaunch {
            app.launchArguments += ["UITEST_OPEN_IMPORT_EXPORT"]
        }
        if openColorsOnLaunch {
            app.launchArguments += ["UITEST_OPEN_COLORS"]
        }
        if openLabelManagerOnLaunch {
            app.launchArguments += ["UITEST_OPEN_LABEL_MANAGER"]
        }
        if openLabelAssignmentOnLaunch {
            app.launchArguments += ["UITEST_OPEN_LABEL_ASSIGNMENT"]
        }
        if seedBookmarkLabelWorkflowOnLaunch {
            app.launchArguments += ["UITEST_SEED_BOOKMARK_LABEL_WORKFLOW"]
        }
        if seedBookmarkRowLabelWorkflowOnLaunch {
            app.launchArguments += ["UITEST_SEED_BOOKMARK_ROW_LABEL_WORKFLOW"]
        }
        if seedBookmarkStudyPadWorkflowOnLaunch {
            app.launchArguments += ["UITEST_SEED_BOOKMARK_STUDYPAD_WORKFLOW"]
        }
        if seedBookmarkNavigationWorkflowOnLaunch {
            app.launchArguments += ["UITEST_SEED_BOOKMARK_NAVIGATION_WORKFLOW"]
        }
        if seedBookmarkMultiRowWorkflowOnLaunch {
            app.launchArguments += ["UITEST_SEED_BOOKMARK_MULTIROW_WORKFLOW"]
        }
        if seedBookmarkFilterWorkflowOnLaunch {
            app.launchArguments += ["UITEST_SEED_BOOKMARK_FILTER_WORKFLOW"]
        }
        if seedHistoryWorkflowOnLaunch {
            app.launchArguments += ["UITEST_SEED_HISTORY_WORKFLOW"]
        }
        if seedHistoryMultiRowWorkflowOnLaunch {
            app.launchArguments += ["UITEST_SEED_HISTORY_MULTIROW_WORKFLOW"]
        }
        if openReadingPlansOnLaunch {
            app.launchArguments += ["UITEST_OPEN_READING_PLANS"]
        }
        if openDailyReadingOnLaunch {
            app.launchArguments += ["UITEST_OPEN_DAILY_READING"]
        }
        if openMyNotesOnLaunch {
            app.launchArguments += ["UITEST_OPEN_MY_NOTES"]
        }
        if openWorkspacesOnLaunch {
            app.launchArguments += ["UITEST_OPEN_WORKSPACES"]
        }
        return app
    }

    /**
     Opens Search either from the reader toolbar or from a direct test-only launch path.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - launchedDirectly: Whether the app was launched straight into the Search sheet.
     * - Returns: The root accessibility-identified Search screen element.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, taps the reader toolbar search button
     *   - when `launchedDirectly` is `true`, waits for the direct-launch Search sheet to render
     * - Failure modes:
     *   - fails when the Search screen never appears
     */
    private func openSearch(
        in app: XCUIApplication,
        launchedDirectly: Bool = false
    ) -> XCUIElement {
        if !launchedDirectly {
            requireElement("readerSearchButton", in: app, timeout: 10).tap()
        }
        return requireElement("searchScreen", in: app, timeout: 10)
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
    private func waitForSearchToFinish(on searchScreen: XCUIElement, timeout: TimeInterval) {
        let predicate = NSPredicate { evaluated, _ in
            guard let element = evaluated as? XCUIElement,
                  let value = element.value as? String else {
                return false
            }
            return value.contains("state=ready") && value.contains("searching=false")
        }

        expectation(for: predicate, evaluatedWith: searchScreen)
        waitForExpectations(timeout: timeout)
    }

    /**
     Waits for the Search screen to report a settled state containing one expected semantic token.
     *
     * - Parameters:
     *   - searchScreen: Search root element exporting deterministic state in its accessibility
     *     value.
     *   - token: State fragment expected once the current search rerun has completed.
     *   - timeout: Maximum time to wait for `state=ready;searching=false` with the requested token.
     * - Side effects:
     *   - blocks the current XCTest method until the Search state export reports the requested
     *     token or the timeout expires
     * - Failure modes:
     *   - fails the test if the Search screen never reaches the requested settled state
     */
    private func waitForSearchState(
        on searchScreen: XCUIElement,
        containing token: String,
        timeout: TimeInterval
    ) {
        let predicate = NSPredicate { evaluated, _ in
            guard let element = evaluated as? XCUIElement,
                  let value = element.value as? String else {
                return false
            }
            return value.contains("state=ready")
                && value.contains("searching=false")
                && value.contains(token)
        }

        expectation(for: predicate, evaluatedWith: searchScreen)
        waitForExpectations(timeout: timeout)
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
     Opens the workspace selector either from the reader overflow menu or from a direct test-only
     launch path.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - launchedDirectly: Whether the app was launched straight into the workspace selector
     *     sheet.
     * - Returns: The root accessibility-identified workspace selector screen element.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, opens the reader overflow menu and pushes the
     *     workspace selector
     *   - when `launchedDirectly` is `true`, waits for the direct-launch workspace selector sheet
     *     to render
     * - Failure modes:
     *   - fails when the workspace selector screen never appears
     */
    private func openWorkspaceSelector(
        in app: XCUIApplication,
        launchedDirectly: Bool = false
    ) -> XCUIElement {
        if !launchedDirectly {
            tapReaderMoreMenuButton(in: app)
            tapReaderAction("readerOpenWorkspacesAction", in: app)
        }
        return requireElement("workspaceSelectorScreen", in: app, timeout: 10)
    }

    /**
     Opens Label Manager either from Settings navigation or from a direct test-only launch path.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - launchedDirectly: Whether the app was launched straight into the Label Manager sheet.
     * - Returns: The root accessibility-identified Label Manager screen element.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, opens Settings and pushes the Label Manager screen
     *   - when `launchedDirectly` is `true`, waits for the direct-launch Label Manager sheet to
     *     render
     * - Failure modes:
     *   - fails when the Label Manager screen never appears
     */
    private func openLabelManager(
        in app: XCUIApplication,
        launchedDirectly: Bool = false
    ) -> XCUIElement {
        if !launchedDirectly {
            openSettings(
                in: app,
                launchedDirectly: app.launchArguments.contains("UITEST_OPEN_SETTINGS")
            )
            tapSettingsElement("settingsLabelsLink", in: app)
        }
        return requireElement("labelManagerScreen", in: app, timeout: 10)
    }

    /**
     Opens Label Assignment either from a direct test-only launch path or from a future in-app
     path.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - launchedDirectly: Whether the app was launched straight into the label-assignment sheet.
     * - Returns: The root accessibility-identified Label Assignment screen element.
     * - Side effects:
     *   - when `launchedDirectly` is `true`, waits for the direct-launch Label Assignment sheet to
     *     render
     * - Failure modes:
     *   - fails when the Label Assignment screen never appears
     *   - triggers an XCTest failure if called without a supported non-direct launch path
     */
    private func openLabelAssignment(
        in app: XCUIApplication,
        launchedDirectly: Bool = false
    ) -> XCUIElement {
        if !launchedDirectly {
            XCTFail("Non-direct label-assignment launch is not implemented in this smoke suite")
        }
        return requireElement("labelAssignmentScreen", in: app, timeout: 10)
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
        _ = openBookmarkList(
            in: app,
            launchedDirectly: app.launchArguments.contains("UITEST_OPEN_BOOKMARKS")
        )
        requireElement("bookmarkListEditLabelsButton::Genesis_1_1", in: app, timeout: 10).tap()
        return requireElement("labelAssignmentScreen", in: app, timeout: 10)
    }

    /**
     Opens the bookmark list either from the reader shell or from a direct test-only launch path.
     *
     * - Parameters:
     *   - app: Running application whose reader shell should present the bookmark list.
     *   - launchedDirectly: Whether the app was launched straight into the bookmark list sheet.
     * - Returns: The root accessibility-identified bookmark list element.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, opens the reader overflow menu and pushes the
     *     bookmark list
     *   - when `launchedDirectly` is `true`, waits for the direct-launch bookmark list sheet to
     *     render
     * - Failure modes:
     *   - fails if the reader menu button, bookmark action, or bookmark list root never appears
     */
    @discardableResult
    private func openBookmarkList(
        in app: XCUIApplication,
        launchedDirectly: Bool = false
    ) -> XCUIElement {
        if !launchedDirectly {
            tapReaderMoreMenuButton(in: app)
            tapReaderAction("readerOpenBookmarksAction", in: app)
        }
        return requireElement("bookmarkListScreen", in: app, timeout: 10)
    }

    /**
     Reopens the direct-launch bookmark sheet through its deterministic XCUITest harness control.
     *
     * - Parameters:
     *   - app: Running application whose bookmark sheet should be reopened.
     *   - launchedDirectly: Whether the current workflow is using the direct-launch bookmark route.
     * - Side effects:
     *   - taps the bookmark-sheet reopen harness when `launchedDirectly` is `true`
     *   - falls back to opening the bookmark list through the standard helper for non-direct flows
     * - Failure modes:
     *   - fails when the reopen harness never appears for a direct-launch workflow
     */
    private func reopenBookmarkList(in app: XCUIApplication, launchedDirectly: Bool) {
        if launchedDirectly {
            tapElementReliably(
                requireElement("bookmarkListHarnessReopenButton", in: app, timeout: 10),
                timeout: 10
            )
            XCTAssertTrue(requireElement("bookmarkListScreen", in: app, timeout: 10).exists)
            return
        }
        _ = openBookmarkList(in: app)
    }

    /**
     Opens History either from the reader shell or from a direct test-only launch path.
     *
     * - Parameters:
     *   - app: Running application whose reader shell should present History.
     *   - launchedDirectly: Whether the app was launched straight into the History sheet.
     * - Returns: The root accessibility-identified History screen element.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, opens the reader overflow menu and pushes the
     *     History sheet
     *   - when `launchedDirectly` is `true`, waits for the direct-launch History sheet to render
     * - Failure modes:
     *   - fails if the reader menu button, History action, or History screen root never appears
     */
    @discardableResult
    private func openHistory(
        in app: XCUIApplication,
        launchedDirectly: Bool = false
    ) -> XCUIElement {
        if !launchedDirectly {
            tapReaderMoreMenuButton(in: app)
            tapReaderAction("readerOpenHistoryAction", in: app)
        }
        return requireElement("historyScreen", in: app, timeout: 10)
    }

    /**
     Opens Downloads either from the reader shell or from a direct test-only launch path.
     *
     * - Parameters:
     *   - app: Running application whose reader shell should present Downloads.
     *   - launchedDirectly: Whether the app was launched straight into the downloads sheet.
     * - Returns: The root accessibility-identified downloads screen element.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, opens the reader overflow menu and pushes Downloads
     *   - when `launchedDirectly` is `true`, waits for the direct-launch downloads sheet to render
     * - Failure modes:
     *   - fails if the reader menu button, downloads action, or downloads screen root never appears
     */
    private func openDownloads(
        in app: XCUIApplication,
        launchedDirectly: Bool = false
    ) -> XCUIElement {
        if !launchedDirectly {
            tapReaderMoreMenuButton(in: app)
            tapReaderAction("readerOpenDownloadsAction", in: app)
        }
        return requireElement("moduleBrowserScreen", in: app, timeout: 10)
    }

    /**
     Opens Import and Export either from Settings navigation or from a direct test-only launch path.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - launchedDirectly: Whether the app was launched straight into the Import and Export sheet.
     * - Returns: The root accessibility-identified Import and Export screen element.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, opens Settings and pushes the Import and Export screen
     *   - when `launchedDirectly` is `true`, waits for the direct-launch Import and Export sheet to
     *     render
     * - Failure modes:
     *   - fails when the Import and Export screen never appears
     */
    private func openImportExport(
        in app: XCUIApplication,
        launchedDirectly: Bool = false
    ) -> XCUIElement {
        if !launchedDirectly {
            openSettings(in: app)
            tapSettingsElement("settingsImportExportLink", in: app)
        }
        return requireElement("importExportScreen", in: app, timeout: 10)
    }

    /**
     Opens Sync Settings either from Settings navigation or from a direct test-only launch path.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - launchedDirectly: Whether the app was launched straight into the Sync Settings sheet.
     * - Returns: The root accessibility-identified Sync Settings screen element.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, opens Settings and pushes the Sync Settings screen
     *   - when `launchedDirectly` is `true`, waits for the direct-launch Sync Settings sheet to render
     * - Failure modes:
     *   - fails when the Sync Settings screen never appears
     */
    private func openSyncSettings(
        in app: XCUIApplication,
        launchedDirectly: Bool = false
    ) -> XCUIElement {
        if !launchedDirectly {
            openSettings(
                in: app,
                launchedDirectly: app.launchArguments.contains("UITEST_OPEN_SETTINGS")
            )
            tapSettingsElement("settingsSyncLink", in: app)
        }
        return requireElement("syncSettingsScreen", in: app, timeout: 10)
    }

    /**
     Switches Sync Settings to one backend using the deterministic harness control when available.
     *
     * - Parameters:
     *   - backendRawValue: Target backend raw value that should become active.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the switch control to resolve and become
     *     hittable.
     * - Side effects:
     *   - prefers the safe-area XCUITest harness backend control when present
     *   - otherwise falls back to the production backend switch control
     * - Failure modes:
     *   - fails if no backend-switch control for the requested backend becomes available
     */
    private func tapSyncBackend(
        _ backendRawValue: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10
    ) {
        let button = requireButton("syncBackendSelect::\(backendRawValue)", in: app, timeout: timeout)
        tapElementReliably(button, timeout: timeout)
    }

    /**
     Opens Colors either from Settings navigation or from a direct test-only launch path.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - launchedDirectly: Whether the app was launched straight into the Colors sheet.
     * - Returns: The root accessibility-identified Colors screen element.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, opens Settings and pushes the Colors screen
     *   - when `launchedDirectly` is `true`, waits for the direct-launch Colors sheet to render
     * - Failure modes:
     *   - fails when the Colors screen never appears
     */
    private func openColorSettings(
        in app: XCUIApplication,
        launchedDirectly: Bool = false
    ) -> XCUIElement {
        if !launchedDirectly {
            openSettings(
                in: app,
                launchedDirectly: app.launchArguments.contains("UITEST_OPEN_SETTINGS")
            )
            tapSettingsElement("settingsColorsLink", in: app)
        }
        return requireElement("colorSettingsScreen", in: app, timeout: 10)
    }

    /**
     Opens Text Display either from Settings navigation or from a direct test-only launch path.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - launchedDirectly: Whether the app was launched straight into the Text Display sheet.
     * - Returns: The root accessibility-identified Text Display screen element.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, opens Settings and pushes the Text Display screen
     *   - when `launchedDirectly` is `true`, waits for the direct-launch Text Display sheet to
     *     render
     * - Failure modes:
     *   - fails when the Text Display screen never appears
     */
    private func openTextDisplaySettings(
        in app: XCUIApplication,
        launchedDirectly: Bool = false
    ) -> XCUIElement {
        if !launchedDirectly {
            openSettings(
                in: app,
                launchedDirectly: app.launchArguments.contains("UITEST_OPEN_SETTINGS")
            )
            tapSettingsElement("settingsTextDisplayLink", in: app)
        }
        return requireElement("textDisplaySettingsScreen", in: app, timeout: 10)
    }

    /**
     Opens Settings from the reader shell action surface.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - launchedDirectly: Whether the app was launched straight into the settings sheet.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, resolves the stable reader action surface and pushes
     *     the Settings screen onto the navigation stack
     *   - dismisses the language restart alert only when it is already present after Settings loads
     * - Failure modes:
     *   - fails when the reader overflow menu or Settings action cannot be found for non-direct
     *     launches
     *   - fails when the settings form never appears
     */
    private func openSettings(in app: XCUIApplication, launchedDirectly: Bool = false) {
        if !launchedDirectly {
            tapReaderMoreMenuButton(in: app)
            tapReaderAction("readerOpenSettingsAction", in: app)
        }
        XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)
        let okButton = app.buttons["OK"]
        if okButton.exists {
            okButton.tap()
            XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)
        }
    }

    /**
     Resolves one settings navigation control, preferring the direct-launch XCUITest harness when available.
     *
     * - Parameters:
     *   - identifier: Production settings-row identifier requested by the test.
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: Direct harness button when present; otherwise the production settings row element.
     * - Side effects:
     *   - queries both the XCUITest harness and production settings hierarchy
     * - Failure modes:
     *   - records an XCTest failure if neither the harness control nor the production row appears
     */
    private func requireSettingsNavigationControl(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        if let harnessIdentifier = settingsHarnessIdentifier(for: identifier) {
            let harnessButton = app.buttons[harnessIdentifier].firstMatch
            if harnessButton.waitForExistence(timeout: 1) {
                return harnessButton
            }
        }
        return requireElement(identifier, in: app, timeout: timeout, file: file, line: line)
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
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "Expected element '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        return element
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
            let currentElement = app.descendants(matching: .any)[identifier].firstMatch
            let currentValue = currentElement.value as? String
            if currentElement.exists, currentValue == expectedValue || currentElement.label == expectedValue {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalElement = app.descendants(matching: .any)[identifier].firstMatch
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
     Resolves the reader action surface for one test step.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the toolbar button to exist and become
     *     hittable.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - prefers the XCUITest-only reader action harness when its direct action buttons are
     *     available on the reader shell
     *   - otherwise resolves the overflow-menu button from the toolbar hierarchy and taps its
     *     center point directly
     * - Failure modes:
     *   - records an XCTest failure if neither the harness nor the overflow-menu button becomes
     *     usable within the allotted timeout
     */
    private func tapReaderMoreMenuButton(
        in app: XCUIApplication,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = requireReaderMoreMenuButton(in: app, timeout: timeout, file: file, line: line)
        tapElementReliably(button, timeout: timeout, file: file, line: line)
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
        let button = requireButton(identifier, in: app, timeout: timeout, file: file, line: line)
        tapElementReliably(button, timeout: timeout, file: file, line: line)
    }

    /**
     Waits for one resolved element to become hittable, then taps its center point directly.
     *
     * - Parameters:
     *   - element: Resolved XCUI element that should be tapped.
     *   - timeout: Maximum number of seconds to wait for the element to become hittable.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - waits for the live element to report `hittable == true`
     *   - performs a coordinate-based center tap that bypasses XCUI's scroll-to-visible path
     * - Failure modes:
     *   - records an XCTest failure if the element never becomes hittable
     *   - records an XCTest failure if the element does not expose a non-empty frame for tapping
     */
    private func tapElementReliably(
        _ element: XCUIElement,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let hittablePredicate = NSPredicate(format: "hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: hittablePredicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "Expected element '\(element.identifier)' to become hittable within \(timeout) seconds.",
            file: file,
            line: line
        )
        XCTAssertFalse(
            element.frame.isEmpty,
            "Expected element '\(element.identifier)' to expose a non-empty frame before tapping.",
            file: file,
            line: line
        )
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /**
     Waits for the My Notes direct-launch harness to reach a settled presented state.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - timeout: Maximum number of seconds to wait for the harness to report presentation.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - polls the hidden My Notes harness state while the reader-shell direct-launch route
     *     finishes opening the chapter-level notes document
     *   - fails immediately if the harness reports one explicit `failed:` token
     *   - asserts that the native My Notes title exists once the harness reaches `presented`
     * - Failure modes:
     *   - records an XCTest failure if the harness reports a `failed:` token
     *   - records an XCTest failure if the harness never reaches `presented` before timeout
     *   - records an XCTest failure if the native My Notes title is still absent after
     *     presentation is reported
     */
    private func waitForMyNotesPresentation(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let stateElement = app.descendants(matching: .any)["uiTestMyNotesPresentationState"].firstMatch
            let state = (stateElement.value as? String) ?? stateElement.label
            if state == "presented" {
                XCTAssertTrue(
                    requireElement("readerMyNotesTitle", in: app, timeout: 10, file: file, line: line).exists,
                    file: file,
                    line: line
                )
                return
            }
            if state.hasPrefix("failed:") {
                XCTFail("Expected My Notes to present but harness reported '\(state)'.", file: file, line: line)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalStateElement = app.descendants(matching: .any)["uiTestMyNotesPresentationState"].firstMatch
        let finalState = (finalStateElement.value as? String) ?? finalStateElement.label
        XCTFail(
            "Expected My Notes to reach 'presented' within \(timeout) seconds, last state was '\(finalState)'.",
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
        tapElementReliably(element, timeout: timeout, file: file, line: line)
    }

    /**
     Maps one production settings-row identifier to its deterministic direct-launch harness control.
     *
     * - Parameter identifier: Production settings-row identifier requested by a test.
     * - Returns: Matching harness control identifier when the route has a stable direct-launch
     *   equivalent; otherwise `nil`.
     * - Side effects: none.
     * - Failure modes: This helper cannot fail.
     */
    private func settingsHarnessIdentifier(for identifier: String) -> String? {
        switch identifier {
        case "settingsDownloadsLink":
            "settingsHarnessDownloadsLink"
        case "settingsImportExportLink":
            "settingsHarnessImportExportLink"
        case "settingsSyncLink":
            "settingsHarnessSyncLink"
        case "settingsLabelsLink":
            "settingsHarnessLabelsLink"
        case "settingsTextDisplayLink":
            "settingsHarnessTextDisplayLink"
        case "settingsColorsLink":
            "settingsHarnessColorsLink"
        default:
            nil
        }
    }

    /**
     Opens the seeded `UI Test Seed` StudyPad handoff, preferring the direct-launch bookmark harness.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - uses the dedicated bookmark harness StudyPad button when present
     *   - otherwise selects the real `UI Test Seed` filter chip and taps the production StudyPad
     *     handoff button
     * - Failure modes:
     *   - fails if neither the harness button nor the production label-filter path is available
     */
    private func openSeedStudyPadFromBookmarkList(in app: XCUIApplication) {
        let harnessButton = app.buttons["bookmarkListHarnessOpenStudyPadButton::UI_Test_Seed"].firstMatch
        if harnessButton.waitForExistence(timeout: 1) {
            tapElementReliably(harnessButton, timeout: 10)
            return
        }

        requireElement("bookmarkListFilterChip::UI_Test_Seed", in: app, timeout: 10).tap()
        requireElement("bookmarkListOpenStudyPadButton::UI_Test_Seed", in: app, timeout: 10).tap()
    }

    /**
     Switches the bookmark list into Bible-order sorting, preferring the direct-launch harness control.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - uses the dedicated bookmark harness sort control when present
     *   - otherwise opens the production sort menu and selects the Bible-order option
     * - Failure modes:
     *   - fails if neither the harness control nor the production sort-menu path is available
     */
    private func sortBookmarkListByBibleOrder(in app: XCUIApplication) {
        let harnessButton = app.buttons["bookmarkListHarnessSortOption::bibleOrder"].firstMatch
        if harnessButton.waitForExistence(timeout: 1) {
            tapElementReliably(harnessButton, timeout: 10)
            return
        }

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
        XCTAssertEqual(seedRow.value as? String, "unassigned,notFavourite")

        requireElement(
            "labelAssignmentFavouriteButton::UI_Test_Seed",
            in: app,
            timeout: 10
        ).tap()
        requireElement(
            "labelAssignmentToggleButton::UI_Test_Seed",
            in: app,
            timeout: 10
        ).tap()

        let updatedPredicate = NSPredicate(format: "value == %@", "assigned,favourite")
        expectation(for: updatedPredicate, evaluatedWith: seedRow)
        waitForExpectations(timeout: 10)
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
        app.buttons["labelManagerRowButton-\(name)"]
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
        element.tap()
        if let existingText = element.value as? String {
            let deleteSequence = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingText.count)
            element.typeText(deleteSequence + text)
        } else {
            element.typeText(text)
        }
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
            let upperElement = app.descendants(matching: .any)[upperIdentifier].firstMatch
            let lowerElement = app.descendants(matching: .any)[lowerIdentifier].firstMatch
            if upperElement.exists,
               lowerElement.exists,
               upperElement.frame.minY < lowerElement.frame.minY {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalUpperElement = app.descendants(matching: .any)[upperIdentifier].firstMatch
        let finalLowerElement = app.descendants(matching: .any)[lowerIdentifier].firstMatch
        XCTAssertTrue(
            finalUpperElement.exists && finalLowerElement.exists &&
                finalUpperElement.frame.minY < finalLowerElement.frame.minY,
            "Expected '\(upperIdentifier)' to appear above '\(lowerIdentifier)' within \(timeout) seconds.",
            file: file,
            line: line
        )
    }

}
