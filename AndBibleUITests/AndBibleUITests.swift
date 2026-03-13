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

        let moreMenuButton = requireElement("readerMoreMenuButton", in: app)
        moreMenuButton.tap()
        requireElement("readerOpenReadingPlansAction", in: app, timeout: 5).tap()

        XCTAssertTrue(requireElement("readingPlanListScreen", in: app, timeout: 10).exists)
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

        openSettings(in: app, launchedDirectly: true)
        tapSettingsElement("settingsLabelsLink", in: app)

        XCTAssertTrue(requireElement("labelManagerScreen", in: app, timeout: 10).exists)
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
     *   - openImportExportOnLaunch: Whether the app should present Import and Export immediately on
     *     launch.
     * - Returns: App handle configured with deterministic launch arguments for the smoke suite.
     * - Side effects:
     *   - appends a launch argument that disables the discrete-mode calculator gate during UI tests
     *   - when `settingsTarget` is supplied, configures the app to present Settings immediately and
     *     scroll the requested row into view
     *   - when `openImportExportOnLaunch` is `true`, configures the app to present Import and
     *     Export immediately after the reader hydrates
     * - Failure modes: This helper cannot fail.
     */
    private func makeApp(
        settingsTarget: String? = nil,
        openImportExportOnLaunch: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_DISABLE_CALCULATOR_GATE"]
        if let settingsTarget {
            app.launchArguments += ["UITEST_OPEN_SETTINGS"]
            app.launchEnvironment["UITEST_SETTINGS_SCROLL_TARGET"] = settingsTarget
        }
        if openImportExportOnLaunch {
            app.launchArguments += ["UITEST_OPEN_IMPORT_EXPORT"]
        }
        return app
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
     Opens Settings from the reader overflow menu.
     *
     * - Parameters:
     *   - app: Running application under test.
     *   - launchedDirectly: Whether the app was launched straight into the settings sheet.
     * - Side effects:
     *   - when `launchedDirectly` is `false`, opens the reader overflow menu and pushes the
     *     Settings screen onto the navigation stack
     *   - dismisses the language restart alert when it appears over Settings
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
        if okButton.waitForExistence(timeout: 1) {
            okButton.tap()
        }
        XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)
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
}
