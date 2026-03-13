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
     *   - launches the app with the calculator gate disabled for test determinism
     *   - navigates from the reader shell into Settings and then into the downloads browser
     * - Failure modes:
     *   - fails if the Settings downloads link is missing or cannot be reached by scrolling
     *   - fails if the downloads browser screen does not render after navigation completes
     */
    func testSettingsDownloadsLinkOpensDownloadsBrowser() {
        let app = makeApp()
        app.launch()

        openSettings(in: app)
        tapScrollableElement("settingsDownloadsLink", fallbackLabel: "Downloads", in: app)

        XCTAssertTrue(requireElement("moduleBrowserScreen", in: app, timeout: 10).exists)
    }

    /**
     Verifies that the import/export screen can be opened from Settings.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled for test determinism
     *   - navigates from the reader shell into Settings and then into the import/export screen
     * - Failure modes:
     *   - fails if the Settings import/export link is missing or cannot be reached by scrolling
     *   - fails if the import/export screen does not render after navigation completes
     */
    func testSettingsImportExportLinkOpensImportExportScreen() {
        let app = makeApp()
        app.launch()

        openSettings(in: app)
        tapScrollableElement("settingsImportExportLink", fallbackLabel: "Import & Export", in: app)

        XCTAssertTrue(requireElement("importExportScreen", in: app, timeout: 10).exists)
    }

    /**
     Verifies that the full-backup export action drives Import and Export into share-sheet presentation.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled for test determinism
     *   - navigates through Settings into Import and Export
     *   - triggers a full-backup export, which writes a temporary file and requests share-sheet
     *     presentation
     * - Failure modes:
     *   - fails if the Import and Export link cannot be reached from Settings
     *   - fails if the full-backup action is missing from the Import and Export screen
     *   - fails if the Import and Export screen never reports the share-sheet-presented state after
     *     export completes
     */
    func testSettingsImportExportFullBackupPresentsShareSheet() {
        let app = makeApp()
        app.launch()

        openSettings(in: app)
        tapScrollableElement("settingsImportExportLink", fallbackLabel: "Import & Export", in: app)

        let importExportScreen = requireElement("importExportScreen", in: app, timeout: 10)
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
     *   - launches the app with the calculator gate disabled for test determinism
     *   - navigates through Settings into Import and Export
     *   - triggers the backup import action, which requests document-picker presentation
     * - Failure modes:
     *   - fails if the Import and Export link cannot be reached from Settings
     *   - fails if the import action is missing from the Import and Export screen
     *   - fails if the Import and Export screen never reports the import-picker-presented state
     */
    func testSettingsImportExportImportPresentsFilePickerState() {
        let app = makeApp()
        app.launch()

        openSettings(in: app)
        tapScrollableElement("settingsImportExportLink", fallbackLabel: "Import & Export", in: app)

        let importExportScreen = requireElement("importExportScreen", in: app, timeout: 10)
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
     *   - launches the app with the calculator gate disabled for test determinism
     *   - navigates from the reader shell into Settings and then into the label manager
     * - Failure modes:
     *   - fails if the Settings labels link is missing or cannot be reached by scrolling
     *   - fails if the label manager screen does not render after navigation completes
     */
    func testSettingsLabelsLinkOpensLabelManager() {
        let app = makeApp()
        app.launch()

        openSettings(in: app)
        tapScrollableElement("settingsLabelsLink", fallbackLabel: "Labels", in: app)

        XCTAssertTrue(requireElement("labelManagerScreen", in: app, timeout: 10).exists)
    }

    /**
     Verifies that the sync settings screen can be opened from Settings.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled for test determinism
     *   - navigates from the reader shell into Settings and then into sync settings
     * - Failure modes:
     *   - fails if the Settings sync link is missing or cannot be reached by scrolling
     *   - fails if the sync settings screen does not render after navigation completes
     */
    func testSettingsSyncLinkOpensSyncSettings() {
        let app = makeApp()
        app.launch()

        openSettings(in: app)
        tapScrollableElement("settingsSyncLink", fallbackLabel: "iCloud Sync", in: app)

        XCTAssertTrue(requireElement("syncSettingsScreen", in: app, timeout: 10).exists)
    }

    /**
     Verifies that the text-display editor can be opened from Settings.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled for test determinism
     *   - navigates from the reader shell into Settings and then into text-display settings
     * - Failure modes:
     *   - fails if the Settings text-display link is missing or cannot be reached by scrolling
     *   - fails if the text-display settings screen does not render after navigation completes
     */
    func testSettingsTextDisplayLinkOpensTextDisplayEditor() {
        let app = makeApp()
        app.launch()

        openSettings(in: app)
        tapScrollableElement("settingsTextDisplayLink", fallbackLabel: "Text Display", in: app)

        XCTAssertTrue(requireElement("textDisplaySettingsScreen", in: app, timeout: 10).exists)
    }

    /**
     Verifies that the color editor can be opened from Settings.
     *
     * - Side effects:
     *   - launches the app with the calculator gate disabled for test determinism
     *   - navigates from the reader shell into Settings and then into color settings
     * - Failure modes:
     *   - fails if the Settings colors link is missing or cannot be reached by scrolling
     *   - fails if the color settings screen does not render after navigation completes
     */
    func testSettingsColorsLinkOpensColorEditor() {
        let app = makeApp()
        app.launch()

        openSettings(in: app)
        tapScrollableElement("settingsColorsLink", fallbackLabel: "Colors", in: app)

        XCTAssertTrue(requireElement("colorSettingsScreen", in: app, timeout: 10).exists)
    }

    /**
     Builds the configured XCUIApplication instance used by each smoke test.
     *
     * - Returns: App handle configured with deterministic launch arguments for the smoke suite.
     * - Side effects:
     *   - appends a launch argument that disables the discrete-mode calculator gate during UI tests
     * - Failure modes: This helper cannot fail.
     */
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["UITEST_DISABLE_CALCULATOR_GATE"]
        return app
    }

    /**
     Opens Settings from the reader overflow menu.
     *
     * - Parameter app: Running application under test.
     * - Side effects:
     *   - opens the reader overflow menu
     *   - pushes the Settings screen onto the navigation stack
     * - Failure modes:
     *   - fails when the reader overflow menu or Settings action cannot be found
     */
    private func openSettings(in app: XCUIApplication) {
        let moreMenuButton = requireElement("readerMoreMenuButton", in: app)
        moreMenuButton.tap()
        requireElement("readerOpenSettingsAction", in: app, timeout: 5).tap()
        XCTAssertTrue(requireElement("settingsForm", in: app, timeout: 10).exists)
        let okButton = app.buttons["OK"]
        if okButton.waitForExistence(timeout: 1) {
            okButton.tap()
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
     Scrolls the Settings form until an identified row becomes tappable, then taps it.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the target settings row.
     *   - fallbackLabel: Visible row label used when SwiftUI does not surface the identifier directly.
     *   - app: Running application under test.
     *   - maxSwipes: Maximum number of upward swipes to perform before failing.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Side effects:
     *   - scrolls the settings form upward until the target row becomes hittable
     *   - falls back to a visible label query when SwiftUI cell wrappers hide custom identifiers
     *   - taps the target row once it becomes hittable
     * - Failure modes:
     *   - records an XCTest failure if the row never appears or never becomes hittable
     */
    private func tapScrollableElement(
        _ identifier: String,
        fallbackLabel: String,
        in app: XCUIApplication,
        maxSwipes: Int = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let settingsForm = requireElement("settingsForm", in: app, timeout: 10, file: file, line: line)
        let identifierElement = app.descendants(matching: .any)[identifier].firstMatch
        let buttonElement = app.buttons[fallbackLabel].firstMatch
        let textElement = app.staticTexts[fallbackLabel].firstMatch
        let cellElement = app.collectionViews.cells.containing(.staticText, identifier: fallbackLabel).firstMatch

        func currentElement() -> XCUIElement {
            if identifierElement.exists {
                return identifierElement
            }
            if cellElement.exists {
                return cellElement
            }
            if buttonElement.exists {
                return buttonElement
            }
            return textElement
        }

        for _ in 0..<maxSwipes {
            let element = currentElement()
            if element.exists && element.isHittable {
                element.tap()
                return
            }
            settingsForm.swipeUp()
        }

        let element = currentElement()
        XCTAssertTrue(
            element.waitForExistence(timeout: 2),
            "Expected element '\(identifier)' or label '\(fallbackLabel)' to exist after scrolling.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            element.isHittable,
            "Expected element '\(identifier)' or label '\(fallbackLabel)' to become hittable after scrolling.",
            file: file,
            line: line
        )
        element.tap()
    }
}
