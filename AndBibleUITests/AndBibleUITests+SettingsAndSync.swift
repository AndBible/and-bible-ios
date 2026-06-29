import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
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

        let destinationCancelButton = firstExistingElement(
            [
                app.buttons["backupDestinationCancelButton"].firstMatch,
                app.sheets.buttons["Cancel"].firstMatch,
                app.alerts.buttons["Cancel"].firstMatch,
                app.buttons["Cancel"].firstMatch,
            ],
            timeout: 10
        )
        XCTAssertNotNil(destinationCancelButton, "Expected Backup destination dialog to expose a cancel action.")
        guard let destinationCancelButton else {
            return
        }
        tapElementReliably(destinationCancelButton, timeout: 10)
        waitForElementValue("importExportScreen", toEqual: "idle", in: app, timeout: 10)

        tapElementReliably(databaseBackupButton, timeout: 10)
        waitForElementValue("importExportScreen", toEqual: "backupDestinationPresented", in: app, timeout: 20)

        let shareButton = requireElement("backupDestinationShareButton", in: app, timeout: 10)
        tapElementReliably(shareButton, timeout: 10)
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
     Verifies that Android Restore or Import keeps Database and Documents as distinct targets.
     *
     * - Side effects:
     *   - launches the app and opens Backup & Restore
     *   - triggers the default Database Restore/Import picker
     *   - relaunches a fresh app instance, selects Documents, and triggers the document/module picker
     * - Failure modes:
     *   - fails if the default Database target no longer opens the `.abdb.zip` restore/import path
     *   - fails if Documents restore/import is collapsed into the database picker or legacy iOS
     *     JSON/CSV importer
     */
    func testSettingsBackupRestoreRestoreImportPresentsTargetSpecificPickers() {
        let databaseApp = makeApp()
        databaseApp.launch()

        let databaseScreen = openImportExport(in: databaseApp)
        XCTAssertTrue(databaseScreen.exists)

        let databaseTarget = requireElement("restoreWorkflowTarget.databaseButton", in: databaseApp, timeout: 10)
        tapElementReliably(databaseTarget, timeout: 10)

        let databaseRestoreButton = requireElement("backupWorkflowRestoreButton", in: databaseApp, timeout: 10)
        tapElementReliably(databaseRestoreButton, timeout: 10)
        waitForElementValue("importExportScreen", toEqual: "databaseRestorePickerPresented", in: databaseApp, timeout: 20)
        databaseApp.terminate()

        let documentsApp = makeApp()
        documentsApp.launch()

        let documentsScreen = openImportExport(in: documentsApp)
        XCTAssertTrue(documentsScreen.exists)

        let documentsTarget = requireElement("restoreWorkflowTarget.documentsButton", in: documentsApp, timeout: 10)
        tapElementReliably(documentsTarget, timeout: 10)

        let documentsRestoreButton = requireElement("backupWorkflowRestoreButton", in: documentsApp, timeout: 10)
        tapElementReliably(documentsRestoreButton, timeout: 10)
        waitForElementValue("importExportScreen", toEqual: "documentsRestorePickerPresented", in: documentsApp, timeout: 20)
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

        let searchField = requireBookmarkListSearchField(in: app, timeout: 10)

        selectBookmarkListFilterChip("UI_Test_Seed", in: app, timeout: 10)
        waitForBookmarkListState(containing: "count=1", in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Genesis_1_1"), in: app, timeout: 10)
        waitForBookmarkListState(notContaining: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)

        replaceText(in: searchField, with: "Exodus", placeholderHints: ["Search bookmarks"])
        waitForBookmarkListState(containing: "count=0", in: app, timeout: 10)
        waitForBookmarkListState(containing: "query=Exodus", in: app, timeout: 10)
        waitForBookmarkListState(notContaining: bookmarkListRowStateToken("Genesis_1_1"), in: app, timeout: 10)

        reopenBookmarkList(in: app)
        waitForBookmarkListState(containing: "selectedLabel=all", in: app, timeout: 10)
        waitForBookmarkListState(containing: "count=2", in: app, timeout: 10)
        waitForBookmarkListState(notContaining: "query=Exodus", in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Genesis_1_1"), in: app, timeout: 10)
        waitForBookmarkListState(containing: bookmarkListRowStateToken("Exodus_2_1"), in: app, timeout: 10)
    }

    /**
     Verifies that the Settings Label Manager route opens the native manager screen.
     *
     * Label creation, edit-save, and delete persistence now run in `LabelManagerMutationTests`
     * because they are package-owned SwiftData contracts. This UI smoke intentionally stays small
     * and protects only the live app route and readiness probes.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens the label manager through Settings
     * - Failure modes:
     *   - fails if the Settings route cannot reach `LabelManagerView` or if the screen loses its
     *     app-visible readiness/export identifiers
     */
    func testLabelManagerScreenOpensFromSettings() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openLabelManager(in: app).exists)
        _ = requireElement("labelManagerAddButton", in: app, timeout: 10)
        _ = requireElement("labelManagerStateExport", in: app, timeout: 10)
    }

    /**
     Verifies that invalid NextCloud server input surfaces the expected validation status.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens Sync Settings from the reader action
     *   - enters one invalid server URL and commits the inline credential edit through the
     *     Android-equivalent keyboard commit action
     * - Failure modes:
     *   - fails if the Sync Settings sheet never appears
     *   - fails if the NextCloud server field is missing
     *   - fails if the exported connection-test state never reaches `failureInvalidURL`
     */
    func testSyncSettingsNextCloudInvalidURLShowsValidationStatus() {
        let app = makeApp()
        app.launch()

        _ = openSyncSettingsFromReaderAction(in: app)
        let serverField = requireElement("syncNextCloudServerURLField", in: app, timeout: 10)

        replaceText(in: serverField, with: "not-a-url")
        let commitButton = requireElement("syncNextCloudServerURLCommitButton", in: app, timeout: 5)
        tapElementReliably(commitButton, timeout: 2)
        waitForElementValue("syncSettingsState", toContain: "remoteStatus=failureInvalidURL", in: app, timeout: 10)
    }

    /**
     Verifies that the visible My Documents adopt-versus-create confirmation can drive the
     create-new branch.
     *
     * - Side effects:
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

        let createFromDeviceButton = app.alerts.firstMatch.buttons["Copy from this device to Cloud"].firstMatch
        XCTAssertTrue(
            createFromDeviceButton.waitForExistence(timeout: 10),
            "Expected the adopt-versus-create alert to expose the create-new choice."
        )
        tapElementReliably(createFromDeviceButton, timeout: 10)

        waitForSyncState(["pendingConfirmation": "resetCloud:mydocuments"], in: app, timeout: 10)
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
     Verifies category disabling and backend switching mutate state and persist across reopen.
     *
     * - Side effects:
     *   - launches the app on the reader shell with persisted NextCloud settings and bookmarks
     *     already enabled through host-side fixture seeding
     *   - disables the bookmarks category through the production toggle and observes the immediate
     *     exported `enabled=none` state
     *   - dismisses the Sync screen, reopens it from the reader action, and rehydrates from
     *     persisted settings state
     *   - switches from NextCloud to iCloud through the production backend picker, dismisses, and
     *     reopens again so the iCloud section is rehydrated from persisted settings
     * - Failure modes:
     *   - fails if the seeded Sync screen does not start with `backend=NEXT_CLOUD;enabled=bookmarks`
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

        _ = openColorSettings(in: app)
        waitForElementValue("colorSettingsScreen", toEqual: "colorCustom", in: app, timeout: 10)
        XCTAssertEqual(resolvedElementSemanticText("colorSettingsScreen", in: app), "colorCustom")

        tapElementReliably(requireElement("colorSettingsResetButton", in: app, timeout: 10), timeout: 10)
        waitForElementValue("colorSettingsScreen", toEqual: "colorDefaults", in: app, timeout: 10)
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
