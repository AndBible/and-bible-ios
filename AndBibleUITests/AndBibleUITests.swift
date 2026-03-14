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
     Verifies that settings can be opened from the reader shell.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled for test determinism
     *   - opens the reader overflow menu and pushes the settings screen
     * - Failure modes:
     *   - fails if settings cannot be reached from the reader shell
     *   - fails if the settings form or critical navigation rows are absent after navigation completes
     */
    func testSettingsScreenShowsPrimaryNavigationRows() {
        let app = makeApp()
        app.launch()

        let moreMenuButton = requireElement("readerMoreMenuButton", in: app)
        moreMenuButton.tap()
        requireElement("readerOpenSettingsAction", in: app, timeout: 5).tap()

        XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)
    }

    /**
     Verifies that reading plans can be opened from the reader shell.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled for test determinism
     *   - opens the reader overflow menu and pushes the reading-plan screen
     * - Failure modes:
     *   - fails if the reading-plans action is missing from the reader menu
     *   - fails if the reading-plan list screen does not render after navigation completes
     */
    func testReadingPlansScreenOpensFromReaderMenu() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openReadingPlans(in: app).exists)
    }

    /**
     Verifies that an active reading plan can advance from day one to day two.
     *
     * - Side effects:
     *   - launches the app directly into one seeded daily-reading view with existing plans reset
     *     for determinism
     *   - marks day one complete and waits for the daily-reading state to advance to day two
     * - Failure modes:
     *   - fails if the direct-launch daily-reading route never appears
     *   - fails if the day label or mark-as-read control is missing
     *   - fails if marking day one complete does not advance the daily-reading state to day two
     */
    func testReadingPlansStartPlanAndAdvanceDay() {
        let app = makeApp(openDailyReadingOnLaunch: true)
        app.launch()

        XCTAssertTrue(requireElement("dailyReadingScreen", in: app, timeout: 10).exists)
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
     *   - launches the app with the calculator gate disabled for test determinism
     *   - opens the reader overflow menu and pushes the downloads browser
     * - Failure modes:
     *   - fails if the downloads action is missing from the reader menu
     *   - fails if the downloads browser screen does not render after navigation completes
     */
    func testDownloadsScreenOpensFromReaderMenu() {
        let app = makeApp()
        app.launch()

        let moreMenuButton = requireElement("readerMoreMenuButton", in: app)
        moreMenuButton.tap()
        requireElement("readerOpenDownloadsAction", in: app, timeout: 5).tap()

        XCTAssertTrue(requireElement("moduleBrowserScreen", in: app, timeout: 10).exists)
    }

    /**
     Verifies that the workspace selector can be opened from the reader shell.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled for test determinism
     *   - opens the reader overflow menu and pushes the workspace selector
     * - Failure modes:
     *   - fails if the workspaces action is missing from the reader menu
     *   - fails if the workspace selector screen does not render after navigation completes
     */
    func testWorkspacesScreenOpensFromReaderMenu() {
        let app = makeApp()
        app.launch()

        let moreMenuButton = requireElement("readerMoreMenuButton", in: app)
        moreMenuButton.tap()
        requireElement("readerOpenWorkspacesAction", in: app, timeout: 5).tap()

        XCTAssertTrue(requireElement("workspaceSelectorScreen", in: app, timeout: 10).exists)
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
     *   - launches the app with the calculator gate disabled for test determinism
     *   - opens the reader overflow menu and pushes the bookmark list
     * - Failure modes:
     *   - fails if the bookmarks action is missing from the reader menu
     *   - fails if the bookmark list screen does not render after navigation completes
     */
    func testBookmarksScreenOpensFromReaderMenu() {
        let app = makeApp()
        app.launch()

        let moreMenuButton = requireElement("readerMoreMenuButton", in: app)
        moreMenuButton.tap()
        requireElement("readerOpenBookmarksAction", in: app, timeout: 5).tap()

        XCTAssertTrue(requireElement("bookmarkListScreen", in: app, timeout: 10).exists)
    }

    /**
     Verifies that the about screen can be opened from the reader shell.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled for test determinism
     *   - opens the reader overflow menu and pushes the about screen
     * - Failure modes:
     *   - fails if the about action is missing from the reader menu
     *   - fails if the about screen does not render after navigation completes
     */
    func testAboutScreenOpensFromReaderMenu() {
        let app = makeApp()
        app.launch()

        let moreMenuButton = requireElement("readerMoreMenuButton", in: app)
        moreMenuButton.tap()
        requireElement("readerOpenAboutAction", in: app, timeout: 5).tap()

        XCTAssertTrue(requireElement("aboutScreen", in: app, timeout: 10).exists)
    }

    /**
     Verifies that the downloads browser can be opened from Settings.
     *
     * - Side effects:
     *   - launches the app directly into Settings with the downloads row pre-scrolled into view
     *   - opens the downloads browser from the settings screen
     * - Failure modes:
     *   - fails if the Settings downloads link is missing or never becomes hittable
     *   - fails if the downloads browser screen does not render after navigation completes
     */
    func testSettingsDownloadsLinkOpensDownloadsBrowser() {
        let app = makeApp(settingsTarget: "settingsDownloadsLink")
        app.launch()

        openSettings(in: app, launchedDirectly: true)
        tapSettingsElement("settingsDownloadsLink", in: app)

        XCTAssertTrue(requireElement("moduleBrowserScreen", in: app, timeout: 10).exists)
    }

    /**
     Verifies that the import/export screen can be opened from Settings.
     *
     * - Side effects:
     *   - launches the app directly into Settings with the import/export row pre-scrolled into view
     *   - opens the import/export screen from Settings
     * - Failure modes:
     *   - fails if the Settings import/export link is missing or never becomes hittable
     *   - fails if the import/export screen does not render after navigation completes
     */
    func testSettingsImportExportLinkOpensImportExportScreen() {
        let app = makeApp(settingsTarget: "settingsImportExportLink")
        app.launch()

        openSettings(in: app, launchedDirectly: true)
        tapSettingsElement("settingsImportExportLink", in: app)

        XCTAssertTrue(requireElement("importExportScreen", in: app, timeout: 10).exists)
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
     Verifies that the label manager can be opened from Settings.
     *
     * - Side effects:
     *   - launches the app directly into Settings with the labels row pre-scrolled into view
     *   - opens the label manager from Settings
     * - Failure modes:
     *   - fails if the Settings labels link is missing or never becomes hittable
     *   - fails if the label manager screen does not render after navigation completes
     */
    func testSettingsLabelsLinkOpensLabelManager() {
        let app = makeApp(settingsTarget: "settingsLabelsLink")
        app.launch()

        XCTAssertTrue(openLabelManager(in: app).exists)
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
     Verifies that the text-display editor can be opened from Settings.
     *
     * - Side effects:
     *   - launches the app directly into Settings with the text-display row pre-scrolled into view
     *   - opens text-display settings from the settings screen
     * - Failure modes:
     *   - fails if the Settings text-display link is missing or never becomes hittable
     *   - fails if the text-display settings screen does not render after navigation completes
     */
    func testSettingsTextDisplayLinkOpensTextDisplayEditor() {
        let app = makeApp(settingsTarget: "settingsTextDisplayLink")
        app.launch()

        openSettings(in: app, launchedDirectly: true)
        tapSettingsElement("settingsTextDisplayLink", in: app)

        XCTAssertTrue(requireElement("textDisplaySettingsScreen", in: app, timeout: 10).exists)
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

        app.terminate()
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
     Builds the configured XCUIApplication instance used by each smoke test.
     *
     * - Parameters:
     *   - settingsTarget: Optional settings-row identifier that the app should open and pre-scroll
     *     into view on launch.
     *   - openTextDisplayOnLaunch: Whether the app should present Text Display immediately on
     *     launch.
     *   - openImportExportOnLaunch: Whether the app should present Import and Export immediately on
     *     launch.
     *   - openLabelManagerOnLaunch: Whether the app should present Label Manager immediately on
     *     launch.
     *   - openReadingPlansOnLaunch: Whether the app should present Reading Plans immediately on
     *     launch.
     *   - openDailyReadingOnLaunch: Whether the app should present one seeded daily-reading view
     *     immediately on launch.
     *   - openWorkspacesOnLaunch: Whether the app should present Workspaces immediately on launch.
     * - Returns: App handle configured with deterministic launch arguments for the smoke suite.
     * - Side effects:
     *   - appends a launch argument that disables the discrete-mode calculator gate during UI tests
     *   - when `settingsTarget` is supplied, configures the app to present Settings immediately and
     *     scroll the requested row into view
     *   - when `openTextDisplayOnLaunch` is `true`, configures the app to present Text Display
     *     immediately after the reader hydrates
     *   - when `openImportExportOnLaunch` is `true`, configures the app to present Import and
     *     Export immediately after the reader hydrates
     *   - when `openLabelManagerOnLaunch` is `true`, configures the app to present Label Manager
     *     immediately after the reader hydrates
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
        openTextDisplayOnLaunch: Bool = false,
        openImportExportOnLaunch: Bool = false,
        openLabelManagerOnLaunch: Bool = false,
        openReadingPlansOnLaunch: Bool = false,
        openDailyReadingOnLaunch: Bool = false,
        openWorkspacesOnLaunch: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_DISABLE_CALCULATOR_GATE"]
        if let settingsTarget {
            app.launchArguments += ["UITEST_OPEN_SETTINGS"]
            app.launchEnvironment["UITEST_SETTINGS_SCROLL_TARGET"] = settingsTarget
        }
        if openTextDisplayOnLaunch {
            app.launchArguments += ["UITEST_OPEN_TEXT_DISPLAY"]
        }
        if openImportExportOnLaunch {
            app.launchArguments += ["UITEST_OPEN_IMPORT_EXPORT"]
        }
        if openLabelManagerOnLaunch {
            app.launchArguments += ["UITEST_OPEN_LABEL_MANAGER"]
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
     Opens Reading Plans either from the reader overflow menu or from a direct test-only launch
     path.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - launchedDirectly: Whether the app was launched straight into the Reading Plans sheet.
     * - Returns: The root accessibility-identified Reading Plans screen element.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, opens the reader overflow menu and pushes Reading
     *     Plans
     *   - when `launchedDirectly` is `true`, waits for the direct-launch Reading Plans sheet to
     *     render
     * - Failure modes:
     *   - fails when the Reading Plans screen never appears
     */
    private func openReadingPlans(
        in app: XCUIApplication,
        launchedDirectly: Bool = false
    ) -> XCUIElement {
        if !launchedDirectly {
            let moreMenuButton = requireElement("readerMoreMenuButton", in: app)
            moreMenuButton.tap()
            requireElement("readerOpenReadingPlansAction", in: app, timeout: 5).tap()
        }
        return requireElement("readingPlanListScreen", in: app, timeout: 10)
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
            let moreMenuButton = requireElement("readerMoreMenuButton", in: app)
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
            let moreMenuButton = requireElement("readerMoreMenuButton", in: app)
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
