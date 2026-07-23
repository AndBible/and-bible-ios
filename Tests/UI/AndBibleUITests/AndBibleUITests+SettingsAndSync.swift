import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    /**
     Verifies the single installed AndBible app can present and leave its calculator launch gate.
     *
     * The workflow writes a custom PIN and enables the gate through production Settings without
     * replacing the active Settings screen. Resume and relaunch must present the gate; seven wrong
     * attempts must not authorize; and every resume after a valid unlock must re-arm the gate.
     *
     * - Side effects:
     *   - resets and seeds the installed AndBible app container with the baseline fixture
     *   - writes a custom PIN and enables `show_calculator` through the visible Settings controls
     *   - backgrounds, terminates, relaunches, unlocks, and verifies post-unlock re-locking
     *   - opens Settings after authorization
     * - Failure modes:
     *   - fails when AndBible is not installed on the test simulator
     *   - fails when incorrect attempts or lifecycle transitions bypass exact PIN authorization
     *   - fails when runtime security controls or truthful platform help disappear
     */
    func testSingleAppCalculatorGateAndSecuritySettings() {
        let customPIN = "08642"
        let app = makeApp()
        app.launch()
        XCTAssertTrue(waitForReaderShellReady(in: app, timeout: 30))

        openSettings(in: app)
        let initialPinRow = requireSettingsNavigationControl("calculatorPinRow", in: app, timeout: 20)
        let pinField = initialPinRow.elementType == .textField
            ? initialPinRow
            : initialPinRow.textFields.firstMatch
        XCTAssertTrue(pinField.waitForExistence(timeout: 10), "Calculator PIN row must contain an editable field.")
        replaceText(in: pinField, with: customPIN, placeholderHints: ["PIN"])
        XCTAssertEqual(pinField.value as? String, customPIN)

        let initialShowCalculatorToggle = requireSettingsNavigationControl(
            "showCalculatorToggle",
            in: app,
            timeout: 20
        )
        if initialShowCalculatorToggle.value as? String != "1" {
            toggleSwitchReliably(
                initialShowCalculatorToggle,
                expectedValue: "1",
                timeout: 10
            )
        }
        XCTAssertEqual(
            requireSettingsNavigationControl("showCalculatorToggle", in: app, timeout: 10).value as? String,
            "1",
            "Android keeps Settings visible after enabling the gate and persists it for the next resume."
        )
        XCTAssertFalse(app.otherElements["calculatorGateRoot"].exists)

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(
            app.otherElements["calculatorGateRoot"].waitForExistence(timeout: 10),
            "The first resume after enabling show_calculator must present the calculator gate."
        )

        let equalsButton = app.buttons["="].firstMatch
        XCTAssertTrue(equalsButton.waitForExistence(timeout: 10), "The calculator gate must expose its equals key.")
        for _ in 0..<7 {
            tapElementReliably(equalsButton, timeout: 10)
        }
        XCTAssertTrue(
            app.otherElements["calculatorGateRoot"].exists,
            "Repeated incorrect equals taps must not unlock AndBible."
        )

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(
            app.otherElements["calculatorGateRoot"].waitForExistence(timeout: 10),
            "Backgrounding and activation must retain the calculator gate."
        )

        app.terminate()
        app.launch()
        XCTAssertTrue(
            app.otherElements["calculatorGateRoot"].waitForExistence(timeout: 20),
            "Relaunch must discard calculator input without weakening PIN authorization."
        )
        for key in customPIN.map(String.init) + ["="] {
            let keyButton = app.buttons[key].firstMatch
            XCTAssertTrue(keyButton.waitForExistence(timeout: 10), "The calculator gate must expose its \(key) key.")
            tapElementReliably(keyButton, timeout: 10)
        }
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 30),
            "Only the exact persisted custom PIN should unlock AndBible."
        )

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(
            app.otherElements["calculatorGateRoot"].waitForExistence(timeout: 10),
            "Android re-arms the enabled calculator gate whenever an unlocked app resumes."
        )
        for key in customPIN.map(String.init) + ["="] {
            let keyButton = app.buttons[key].firstMatch
            XCTAssertTrue(keyButton.waitForExistence(timeout: 10), "The re-armed gate must expose its \(key) key.")
            tapElementReliably(keyButton, timeout: 10)
        }
        XCTAssertTrue(
            waitForReaderShellReady(in: app, timeout: 30),
            "The persisted custom PIN must unlock the re-armed gate."
        )

        openSettings(in: app)
        let helpButton = requireSettingsNavigationControl("discreteHelpButton", in: app, timeout: 20)
        tapElementReliably(helpButton, timeout: 10)
        XCTAssertTrue(
            requireElement("androidMyDocumentDecisionDialog", in: app, timeout: 10).exists
        )
        let platformHelpText = "On iOS, the app icon changes to a calculator when 'Hide religious symbols' is enabled, but the app display name cannot be changed at runtime due to platform limitations."
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", platformHelpText)
            ).firstMatch.waitForExistence(timeout: 10)
        )
        tapAlertButton("OK", in: app, timeout: 10)

        XCTAssertTrue(requireSettingsNavigationControl("calculatorPinRow", in: app, timeout: 20).exists)
        XCTAssertTrue(requireSettingsNavigationControl("discreteModeToggle", in: app, timeout: 20).exists)
        XCTAssertTrue(requireSettingsNavigationControl("showCalculatorToggle", in: app, timeout: 20).exists)
    }

    /**
     Verifies Android BackupActivity workflow rows plus iOS database-backup destination handling.
     *
     * Package tests own the backup archive, reset, and restore persistence contracts. This UI smoke
     * keeps the user-visible workflow live: Backup & Restore exposes Android's Database/Documents
     * targets, hides unsupported Application/APK and legacy JSON/CSV paths, asks for the Android
     * "Backup to where?" decision before export, clears that pending destination on Cancel, and does
     * not report success when the iOS share sheet is closed without selecting a destination.
     *
     * - Side effects:
     *   - launches the app and opens the reader administration Backup & Restore route
     *   - triggers Android-compatible `.abdb.zip` database backup generation twice in one route
     *   - cancels the app-owned destination dialog once and the system share sheet once
     * - Failure modes:
     *   - fails if Android-compatible workflow rows disappear or unsupported legacy rows return
     *   - fails if iOS bypasses Android's destination choice and jumps directly to the share sheet
     *   - fails if destination Cancel leaves a stale generated archive pending
     *   - fails if dismissing the share sheet reports a completed backup
     */
    func testSettingsBackupRestoreDatabaseWorkflowDestinationAndShareCancel() {
        let app = makeApp()
        app.launch()

        let importExportScreen = openImportExport(in: app)
        XCTAssertTrue(importExportScreen.exists)

        XCTAssertTrue(requireElement("backupWorkflowTarget.databaseButton", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("backupWorkflowTarget.documentsButton", in: app, timeout: 10).exists)
        XCTAssertFalse(app.buttons["backupWorkflowTarget.applicationButton"].exists)
        XCTAssertTrue(requireElement("restoreWorkflowTarget.databaseButton", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("restoreWorkflowTarget.documentsButton", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("backupWorkflowBackupButton", in: app, timeout: 10).exists)
        XCTAssertTrue(requireElement("backupWorkflowRestoreButton", in: app, timeout: 10).exists)
        XCTAssertTrue(requireReachableBackupRestoreButton("backupWorkflowReset.bookmarksButton", in: app, timeout: 10).exists)
        XCTAssertFalse(app.buttons["importExportLegacyFullBackupButton"].exists)
        XCTAssertFalse(app.buttons["backupWorkflowLegacyImportButton"].exists)

        let databaseTarget = requireElement("backupWorkflowTarget.databaseButton", in: app, timeout: 10)
        tapElementReliably(databaseTarget, timeout: 10)

        let databaseBackupButton = requireElement("backupWorkflowBackupButton", in: app, timeout: 10)
        tapElementReliably(databaseBackupButton, timeout: 10)
        waitForElementValue("importExportScreen", toEqual: "backupDestinationPresented", in: app, timeout: 20)
        XCTAssertTrue(
            app.staticTexts["Backup to phone or elsewhere via Share function (email, iCloud Drive etc.)?"].waitForExistence(timeout: 10),
            "Backup destination copy should describe iCloud Drive, not Android's Google Drive wording."
        )
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Google Drive")).firstMatch.exists,
            "iOS backup destination copy must not advertise Google Drive as the native backup target."
        )

        tapAlertButton("Cancel", in: app, timeout: 10)
        waitForElementValue("importExportScreen", toEqual: "idle", in: app, timeout: 10)

        tapElementReliably(databaseBackupButton, timeout: 10)
        waitForElementValue("importExportScreen", toEqual: "backupDestinationPresented", in: app, timeout: 20)

        tapAlertButton("Share", in: app, timeout: 10)
        waitForElementValue("importExportScreen", toEqual: "shareSheetPresented", in: app, timeout: 20)

        let closeButton = firstExistingElement(
            [
                app.buttons["Close"].firstMatch,
                app.navigationBars.buttons["Close"].firstMatch,
                app.buttons["Cancel"].firstMatch,
                app.navigationBars.buttons["Cancel"].firstMatch,
            ],
            timeout: 10
        )
        XCTAssertNotNil(closeButton, "Expected the system share sheet to expose a Close or Cancel control.")
        guard let closeButton else {
            return
        }

        tapElementReliably(closeButton, timeout: 10)
        waitForElementValue("importExportScreen", toEqual: "idle", in: app, timeout: 10)
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Exported Android database backup")).firstMatch
                .waitForExistence(timeout: 3),
            "Closing the Share destination must not report that the backup was saved."
        )
    }

    /**
     Verifies that the visible My Documents adopt-versus-create confirmation can drive the
     create-new branch.
     *
     * - Side effects:
     *   - resets and seeds the installed AndBible app container with the baseline fixture
     *   - launches Sync Settings with deterministic NextCloud settings and a UI-test remote
     *     backend that reports one existing same-named My Documents sync folder
     *   - scrolls to and enables My Documents sync through the production category row
     *   - chooses "Copy from this device to Cloud" in the adopt-versus-create prompt and confirms
     *     the destructive reset-cloud branch
     * - Failure modes:
     *   - fails if the first adopt/create prompt never appears
     *   - fails if the create-new choice does not surface the reset-cloud confirmation
     *   - fails if confirming the reset-cloud branch does not complete synchronization with the
     *     My Documents category enabled
     */
    func testSyncSettingsMyDocumentsAdoptCreateChoiceSynchronizesFromVisibleWorkflow() {
        let app = makeApp(remoteSyncBootstrapScenario: "adopt-existing")
        app.launch()

        _ = openSyncSettingsFromReaderAction(in: app)
        waitForSyncState(["backend": "NEXT_CLOUD", "enabled": "none"], in: app, timeout: 10)

        toggleSyncCategory(
            "syncCategoryToggle::mydocuments",
            in: app,
            expectedTokens: [
                "backend": "NEXT_CLOUD",
                "enabled": "mydocuments",
                "bootstrapPrompt": "adoptOrCreate:mydocuments",
            ],
            timeout: 15
        )

        chooseSyncBootstrapPromptOption(
            "Copy from this device to Cloud",
            expecting: ["pendingConfirmation": "resetCloud:mydocuments"],
            in: app,
            timeout: 10
        )
        tapAlertButton("OK", in: app, timeout: 10)

        waitForSyncState(
            [
                "backend": "NEXT_CLOUD",
                "enabled": "mydocuments",
                "bootstrapPrompt": "none",
                "pendingConfirmation": "none",
                "lastConfirmation": "resetCloud:mydocuments",
            ],
            in: app,
            timeout: 20
        )
    }

    /**
     Verifies NextCloud invalid URL validation, category disabling, and backend switching.
     *
     * - Side effects:
     *   - launches the app on the reader shell with persisted NextCloud settings and bookmarks
     *     already enabled through host-side fixture seeding
     *   - enters one invalid server URL and commits the inline credential edit through the
     *     Android-equivalent keyboard commit action
     *   - disables the bookmarks category through the production toggle and observes the immediate
     *     exported `enabled=none` state
     *   - dismisses the Sync screen, reopens it from the reader action, and rehydrates from
     *     persisted settings state
     *   - switches from NextCloud to iCloud through the production backend picker, dismisses, and
     *     reopens again so the iCloud section is rehydrated from persisted settings
     * - Failure modes:
     *   - fails if the seeded Sync screen does not start with `backend=NEXT_CLOUD;enabled=bookmarks`
     *   - fails if the NextCloud server field is missing or if the exported connection-test state
     *     never reaches `failureInvalidURL`
     *   - fails if disabling the category does not update the exported Sync screen state to
     *     `backend=NEXT_CLOUD;enabled=none`
     *   - fails if the direct dismiss or reopen controls never appear
     *   - fails if reopening the sheet does not preserve the exported `enabled=none` state token
     *   - fails if switching backend does not expose the iCloud section immediately and after
     *     direct reopen
     */
    func testSyncSettingsCategoryDisableAndBackendSwitchPersistAcrossDirectReopen() {
        let app = makeApp()
        app.launch()

        _ = openSyncSettingsFromReaderAction(in: app)
        let syncState = requireElement("syncSettingsState", in: app, timeout: 10)
        assertSyncState(
            syncState.value as? String,
            backend: "NEXT_CLOUD",
            enabled: "bookmarks"
        )

        let serverField = requireElement("syncNextCloudServerURLField", in: app, timeout: 10)
        replaceText(in: serverField, with: "not-a-url")
        let commitButton = requireElement("syncNextCloudServerURLCommitButton", in: app, timeout: 5)
        tapElementReliably(commitButton, timeout: 2)
        waitForElementValue("syncSettingsState", toContain: "remoteStatus=failureInvalidURL", in: app, timeout: 10)
        tapAlertButton("OK", in: app, timeout: 10)

        toggleSyncCategory(
            "syncCategoryToggle::bookmarks",
            in: app,
            expectedTokens: ["backend": "NEXT_CLOUD", "enabled": "none"]
        )

        dismissSyncSettings(in: app)
        _ = openSyncSettingsFromReaderAction(in: app)

        let reopenedSyncState = requireElement("syncSettingsState", in: app, timeout: 10)
        assertSyncState(
            reopenedSyncState.value as? String,
            backend: "NEXT_CLOUD",
            enabled: "none"
        )

        tapSyncBackend("ICLOUD", in: app)
        waitForSyncState(
            ["backend": "ICLOUD", "enabled": "none"],
            in: app,
            timeout: 10
        )
        XCTAssertTrue(requireElement("syncICloudEnabledToggle", in: app, timeout: 10).exists)

        dismissSyncSettings(in: app)
        _ = openSyncSettingsFromReaderAction(in: app)

        waitForSyncState(
            ["backend": "ICLOUD", "enabled": "none"],
            in: app,
            timeout: 10
        )
        XCTAssertTrue(requireElement("syncICloudEnabledToggle", in: app, timeout: 10).exists)
    }

    /**
     Verifies the production Sync Settings iCloud toggle uses the live runtime applier instead of
     the legacy restart-required fallback.
     *
     Issue #322 moved iCloud mode changes from "save preference and restart" to "rebuild the app
     data stack now." The old path is easy to regress because it is still preserved for previews
     and non-app hosts that do not install a runtime mode-change handler. This smoke test opens the
     real Sync Settings route, taps the iCloud toggle, and asserts the exported state never becomes
     `restartRequired=true` / `.pendingRestart`. The live runtime rebuild must keep the settings
     route open while refreshing data-bound reader panes underneath it. It intentionally does not
     require a signed-in iCloud account or successful CloudKit adoption; those outcomes are separate
     service contracts, while this test protects the production wiring to the live applier.
     */
    func testSyncSettingsICloudToggleDoesNotRequireRestart() {
        let app = makeApp()
        app.launch()

        _ = openSyncSettingsFromReaderAction(in: app)
        XCTAssertTrue(
            app.otherElements["appOwnedSyncSettingsRoute"].waitForExistence(timeout: 2),
            "The production reader Sync Settings action must use the app-owned route so live runtime rebuilds cannot tear down reader-owned modal state."
        )
        tapSyncBackend("ICLOUD", in: app)
        waitForSyncState(
            ["backend": "ICLOUD", "restartRequired": "false"],
            in: app,
            timeout: 10
        )

        let toggle = requireElement("syncICloudEnabledToggle", in: app, timeout: 10)
        let initialState = resolvedElementSemanticText("syncSettingsState", in: app) ?? ""
        if syncStateToken(named: "icloudEnabled", in: initialState) != "true" {
            tapElementReliably(toggle, timeout: 10)
        }

        waitForICloudSyncRuntimeApplyToSettle(in: app, timeout: 30)
    }

    /**
     Resolves a Backup & Restore action that may live below the first visible viewport.
     *
     * - Parameters:
     *   - identifier: Accessibility identifier of the production Backup & Restore button.
     *   - app: Running application under test.
     *   - timeout: Maximum time to keep resolving and revealing the screen.
     *   - file: Source file used for XCTest failure attribution.
     *   - line: Source line used for XCTest failure attribution.
     * - Returns: The resolved button once it is exposed in the Backup & Restore scroll surface.
     * - Side effects:
     *   - scrolls the Backup & Restore screen downward until the requested control is visible
     * - Failure modes:
     *   - records an XCTest failure if the control never appears or remains outside the screen viewport
     */
    func requireReachableBackupRestoreButton(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let screen = requireElement("importExportScreen", in: app, timeout: timeout, file: file, line: line)
        let deadline = Date().addingTimeInterval(timeout)
        var lastCandidate = unresolvedElement(identifier, in: app)

        repeat {
            if let button = resolvedElement(identifier, in: app) {
                lastCandidate = button
                if waitForElementToBecomeHittable(button, timeout: 0.5) ||
                    isElementVisible(button, within: screen)
                {
                    return button
                }
            }

            if screen.exists, !screen.frame.isEmpty {
                screen.swipeUp()
            } else {
                app.swipeUp()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTAssertTrue(
            lastCandidate.exists,
            "Expected Backup & Restore button '\(identifier)' to exist within \(timeout) seconds.",
            file: file,
            line: line
        )
        XCTAssertTrue(
            isElementVisible(lastCandidate, within: screen),
            "Expected Backup & Restore button '\(identifier)' to become visible within \(timeout) seconds.",
            file: file,
            line: line
        )
        return lastCandidate
    }
}
