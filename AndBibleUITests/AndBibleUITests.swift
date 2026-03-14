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
        let app = makeApp(seedBookmarkLabelWorkflowOnLaunch: true)
        app.launch()

        let moreMenuButton = requireReaderMoreMenuButton(in: app)
        moreMenuButton.tap()
        XCTAssertTrue(requireElement("readerOpenReadingPlansAction", in: app, timeout: 5).exists)
        XCTAssertTrue(requireElement("readerOpenDownloadsAction", in: app, timeout: 5).exists)
        XCTAssertTrue(requireElement("readerOpenWorkspacesAction", in: app, timeout: 5).exists)
        XCTAssertTrue(requireElement("readerOpenBookmarksAction", in: app, timeout: 5).exists)
        XCTAssertTrue(requireElement("readerOpenAboutAction", in: app, timeout: 5).exists)

        requireElement("readerOpenSettingsAction", in: app, timeout: 5).tap()

        XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)
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
        waitForSearchToFinish(on: searchScreen, timeout: 20)

        let searchState = searchScreen.value as? String ?? ""
        XCTAssertTrue(
            searchState.contains("query=earth"),
            "Expected search state to retain the seeded query, got '\(searchState)'."
        )
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
        let app = makeApp(seedBookmarkLabelWorkflowOnLaunch: true)
        app.launch()

        let moreMenuButton = requireReaderMoreMenuButton(in: app)
        moreMenuButton.tap()
        requireElement("readerOpenDownloadsAction", in: app, timeout: 5).tap()

        XCTAssertTrue(requireElement("moduleBrowserScreen", in: app, timeout: 10).exists)
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
        let app = makeApp(seedBookmarkLabelWorkflowOnLaunch: true)
        app.launch()

        let moreMenuButton = requireReaderMoreMenuButton(in: app)
        moreMenuButton.tap()
        requireElement("readerOpenBookmarksAction", in: app, timeout: 5).tap()

        XCTAssertTrue(requireElement("bookmarkListScreen", in: app, timeout: 10).exists)
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
        let app = makeApp(seedHistoryWorkflowOnLaunch: true)
        app.launch()

        let currentReferenceState = requireElement("readerCurrentReferenceState", in: app, timeout: 10)
        let historyNavigationState = requireElement("uiTestHistoryNavigationState", in: app, timeout: 10)
        XCTAssertEqual(currentReferenceState.label, "Genesis 1")
        XCTAssertEqual(historyNavigationState.label, "idle")

        let moreMenuButton = requireReaderMoreMenuButton(in: app)
        moreMenuButton.tap()
        requireElement("readerOpenHistoryAction", in: app, timeout: 5).tap()

        XCTAssertTrue(requireElement("historyScreen", in: app, timeout: 10).exists)
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
     *   - opens History from the actual reader overflow menu
     *   - clears the visible history, dismisses the screen, then reopens History to verify the
     *     persisted row remains deleted
     * - Failure modes:
     *   - fails if the reader shell, History action, clear button, or empty state never appears
     *   - fails if the seeded row still exists after clearing or if reopening History restores the
     *     deleted row
     */
    func testHistoryClearRemovesSeededRowAcrossReopen() {
        let app = makeApp(seedHistoryWorkflowOnLaunch: true)
        app.launch()

        openHistoryFromReaderMenu(in: app)
        let historyRow = app.buttons["historyRow::Exod_2_1"].firstMatch
        XCTAssertTrue(historyRow.waitForExistence(timeout: 10), "Expected seeded history row button to exist.")

        requireElement("historyClearButton", in: app, timeout: 10).tap()
        let deletedPredicate = NSPredicate(format: "exists == false")
        expectation(for: deletedPredicate, evaluatedWith: historyRow)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["historyClearButton"].firstMatch.exists)

        requireElement("historyDoneButton", in: app, timeout: 10).tap()
        openHistoryFromReaderMenu(in: app)

        XCTAssertFalse(app.buttons["historyRow::Exod_2_1"].firstMatch.exists)
        XCTAssertFalse(app.buttons["historyClearButton"].firstMatch.exists)
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
        let app = makeApp(seedBookmarkLabelWorkflowOnLaunch: true)
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
        let app = makeApp(seedBookmarkLabelWorkflowOnLaunch: true)
        app.launch()

        let moreMenuButton = requireReaderMoreMenuButton(in: app)
        moreMenuButton.tap()
        requireElement("readerOpenAboutAction", in: app, timeout: 5).tap()

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

        requireElement("syncBackendSelect::GOOGLE_DRIVE", in: app, timeout: 10).tap()
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

        requireElement("syncBackendSelect::GOOGLE_DRIVE", in: app, timeout: 10).tap()
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

        _ = openTextDisplaySettings(in: app, launchedDirectly: true)

        let justifyToggle = requireElement("textDisplayJustifyTextToggle", in: app, timeout: 10)
        let justifyState = app.staticTexts["textDisplayJustifyTextState"].firstMatch
        XCTAssertTrue(justifyState.waitForExistence(timeout: 10), "Expected justify text state label to exist.")
        let initialValue = justifyState.label
        let expectedValue = initialValue == "justifyTextOn" ? "justifyTextOff" : "justifyTextOn"
        justifyToggle.tap()

        let valuePredicate = NSPredicate(format: "label == %@", expectedValue)
        expectation(for: valuePredicate, evaluatedWith: justifyState)
        waitForExpectations(timeout: 10)
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
     *   - seedHistoryWorkflowOnLaunch: Whether the app should seed one deterministic history row
     *     while still landing on the reader shell.
     *   - openReadingPlansOnLaunch: Whether the app should present Reading Plans immediately on
     *     launch.
     *   - openDailyReadingOnLaunch: Whether the app should present one seeded daily-reading view
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
     *   - when `seedHistoryWorkflowOnLaunch` is `true`, configures the app to seed one persisted
     *     history row while leaving navigation at the reader shell
     *   - when `openReadingPlansOnLaunch` is `true`, configures the app to present Reading Plans
     *     immediately after the reader hydrates
     *   - when `openDailyReadingOnLaunch` is `true`, configures the app to seed one reading plan
     *     and present its daily-reading view immediately after the reader hydrates
     *   - when `openWorkspacesOnLaunch` is `true`, configures the app to present Workspaces
     *     immediately after the reader hydrates
     * - Failure modes: This helper cannot fail.
     */
    private func makeApp(
        settingsTarget: String? = nil,
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
        seedHistoryWorkflowOnLaunch: Bool = false,
        openReadingPlansOnLaunch: Bool = false,
        openDailyReadingOnLaunch: Bool = false,
        openWorkspacesOnLaunch: Bool = false
    ) -> XCUIApplication {
        if let trackedApp, trackedApp.state != .notRunning {
            trackedApp.terminate()
        }
        let app = XCUIApplication()
        trackedApp = app
        app.launchArguments += ["UITEST_DISABLE_CALCULATOR_GATE", "UITEST_USE_IN_MEMORY_STORES"]
        if let settingsTarget {
            app.launchArguments += ["UITEST_OPEN_SETTINGS"]
            app.launchEnvironment["UITEST_SETTINGS_SCROLL_TARGET"] = settingsTarget
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
        if seedHistoryWorkflowOnLaunch {
            app.launchArguments += ["UITEST_SEED_HISTORY_WORKFLOW"]
        }
        if openReadingPlansOnLaunch {
            app.launchArguments += ["UITEST_OPEN_READING_PLANS"]
        }
        if openDailyReadingOnLaunch {
            app.launchArguments += ["UITEST_OPEN_DAILY_READING"]
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
     *   - timeout: Maximum time to wait for the `searching=false` state token.
     * - Side effects:
     *   - blocks the current XCTest method until the search state reports completion or times out
     * - Failure modes:
     *   - fails the test if the Search screen never reports `searching=false` before the timeout
     */
    private func waitForSearchToFinish(on searchScreen: XCUIElement, timeout: TimeInterval) {
        let predicate = NSPredicate { evaluated, _ in
            guard let element = evaluated as? XCUIElement,
                  let value = element.value as? String else {
                return false
            }
            return value.contains("searching=false")
        }

        expectation(for: predicate, evaluatedWith: searchScreen)
        waitForExpectations(timeout: timeout)
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
            let moreMenuButton = requireReaderMoreMenuButton(in: app)
            moreMenuButton.tap()
            requireElement("readerOpenWorkspacesAction", in: app, timeout: 5).tap()
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
     *   - taps the seeded bookmark row's inline edit-labels action
     * - Failure modes:
     *   - fails when the bookmark list or seeded bookmark edit-labels action never appears
     */
    private func openLabelAssignmentFromBookmarkList(in app: XCUIApplication) -> XCUIElement {
        let moreMenuButton = requireReaderMoreMenuButton(in: app)
        moreMenuButton.tap()
        requireElement("readerOpenBookmarksAction", in: app, timeout: 5).tap()
        _ = requireElement("bookmarkListScreen", in: app, timeout: 10)
        requireElement("bookmarkListEditLabelsButton::Genesis_1_1", in: app, timeout: 10).tap()
        return requireElement("labelAssignmentScreen", in: app, timeout: 10)
    }

    /**
     Opens History from the real reader overflow menu and waits for the screen root to render.
     *
     * - Parameter app: Running application whose reader shell should present History.
     * - Returns: The root accessibility-identified History screen element.
     * - Side effects:
     *   - opens the reader overflow menu
     *   - presents the History sheet from the actual reader action surface
     * - Failure modes:
     *   - fails if the reader menu button, History action, or History screen root never appears
     */
    @discardableResult
    private func openHistoryFromReaderMenu(in app: XCUIApplication) -> XCUIElement {
        let moreMenuButton = requireReaderMoreMenuButton(in: app)
        moreMenuButton.tap()
        requireElement("readerOpenHistoryAction", in: app, timeout: 5).tap()
        return requireElement("historyScreen", in: app, timeout: 10)
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
     Opens Settings from the reader overflow menu.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - launchedDirectly: Whether the app was launched straight into the settings sheet.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, opens the reader overflow menu and pushes the
     *     Settings screen onto the navigation stack
     *   - dismisses the language restart alert only when it is already present after Settings loads
     * - Failure modes:
     *   - fails when the reader overflow menu or Settings action cannot be found for non-direct
     *     launches
     *   - fails when the settings form never appears
     */
    private func openSettings(in app: XCUIApplication, launchedDirectly: Bool = false) {
        if !launchedDirectly {
            let moreMenuButton = requireReaderMoreMenuButton(in: app)
            moreMenuButton.tap()
            requireElement("readerOpenSettingsAction", in: app, timeout: 5).tap()
        }
        XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)
        let okButton = app.buttons["OK"]
        if okButton.exists {
            okButton.tap()
            XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)
        }
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
            if currentElement.exists, currentElement.value as? String == expectedValue {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        let finalElement = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertEqual(
            finalElement.value as? String,
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
        requireElement(
            "readerMoreMenuButton",
            in: app,
            timeout: timeout,
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
        let element = requireElement(identifier, in: app, timeout: timeout, file: file, line: line)
        let hittablePredicate = NSPredicate(format: "hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: hittablePredicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "Expected element '\(identifier)' to become hittable within \(timeout) seconds.",
            file: file,
            line: line
        )
        element.tap()
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

}
