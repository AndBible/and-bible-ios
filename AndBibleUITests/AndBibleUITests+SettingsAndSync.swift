import Foundation
import Darwin
import XCTest
#if canImport(UIKit)
import UIKit
#endif

extension AndBibleUITests {
    func testAboutScreenOpensFromReaderMenu() {
        let app = makeApp()
        app.launch()

        openAboutFromReaderMenu(in: app)
    }

    /**
     Verifies that Backup & Restore exposes Android BackupActivity's primary workflow choices.
     *
     * - Side effects:
     *   - launches the app and opens the reader administration Backup & Restore route
     *   - reads Android-derived radio rows and reset actions through accessibility identifiers
     * - Failure modes:
     *   - fails if iOS exposes platform-specific JSON/CSV import/export semantics
     *   - fails if actionable Database/Documents backup, Restore/Import, or reset sections
     *     disappear from the user-visible workflow
     *   - fails if iOS exposes Android's Application/APK backup row even though that target cannot
     *     be implemented on iOS
     */
    func testSettingsBackupRestoreShowsAndroidBackupActivityWorkflow() {
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
    }

    /**
     Verifies that Android Database backup presents the backup destination choice before export.
     *
     * - Side effects:
     *   - launches the app and opens Backup & Restore
     *   - triggers Android-compatible `.abdb.zip` database backup generation
     *   - presents the Android-derived "Backup to where?" decision instead of jumping directly to
     *     the iOS share sheet
     *   - cancels the destination choice and verifies the prepared payload is released
     * - Failure modes:
     *   - fails if the Database backup target is missing
     *   - fails if iOS bypasses Android's destination choice and restores the old share-first flow
     *   - fails if cancel leaves a stale generated archive pending in the screen state
     */
    func testSettingsBackupRestoreDatabaseBackupPresentsDestinationChoice() {
        let app = makeApp()
        app.launch()

        let importExportScreen = openImportExport(in: app)
        XCTAssertTrue(importExportScreen.exists)

        let databaseTarget = requireElement("backupWorkflowTarget.databaseButton", in: app, timeout: 10)
        tapElementReliably(databaseTarget, timeout: 10)

        let databaseBackupButton = requireElement("backupWorkflowBackupButton", in: app, timeout: 10)
        tapElementReliably(databaseBackupButton, timeout: 10)
        waitForElementValue("importExportScreen", toEqual: "backupDestinationPresented", in: app, timeout: 20)

        let cancelButton = requireElement("backupDestinationCancelButton", in: app, timeout: 10)
        tapElementReliably(cancelButton, timeout: 10)
        waitForElementValue("importExportScreen", toEqual: "idle", in: app, timeout: 10)
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

        _ = requireElement("labelAssignmentRow::\(newLabelSegment)", in: app, timeout: 20)
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
        waitForLabelManagerState(containing: "showNewLabel=true", in: app, timeout: 10)
        let newLabelNameField = requireLabelManagerNewLabelField(in: app, timeout: 10)
        guard typePromptText(
            originalName,
            into: newLabelNameField,
            in: app,
            timeout: 15,
            accessibilityIdentifier: "labelManagerNewLabelNameField"
        ) else {
            return
        }
        tapLabelCreationPromptCreateButton(in: app, timeout: 10)
        waitForLabelManagerState(containing: labelManagerRowStateToken(originalName), in: app, timeout: 10)

        let createdRow = requireLabelRow(named: originalName, in: app, timeout: 10)
        tapElementReliably(createdRow, timeout: 10)
        _ = requireElement("labelEditScreen", in: app, timeout: 10)
        replaceKnownText(
            in: requireElement("labelEditNameField", in: app, timeout: 10),
            existingCharacterCount: originalName.count,
            with: renamedName,
            app: app
        )
        tapElementReliably(requireElement("labelEditDoneButton", in: app, timeout: 10), timeout: 10)

        waitForLabelManagerState(notContaining: labelManagerRowStateToken(originalName), in: app, timeout: 10)
        waitForLabelManagerState(containing: labelManagerRowStateToken(renamedName), in: app, timeout: 10)
        let renamedRowToDelete = requireLabelRow(named: renamedName, in: app, timeout: 10)
        renamedRowToDelete.swipeLeft()
        tapElementReliably(requireElement("labelManagerDeleteAction", in: app, timeout: 10), timeout: 10)
        waitForLabelManagerState(notContaining: labelManagerRowStateToken(renamedName), in: app, timeout: 10)
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
     Verifies that Reading Progress settings are exposed from the Android-parity Settings features section.

     - Side effects:
     *   - launches the app on the reader shell and opens Settings
     *   - opens Reading Progress Settings from the settings screen
     - Failure modes:
     *   - fails if the Settings reading-progress shortcut is missing or never becomes hittable
     *   - fails if the Reading Progress settings screen does not render after navigation completes
     */
    func testSettingsReadingProgressLinkOpensReadingProgressSettings() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(
            openSettingsDestination(
                linkIdentifier: "settingsReadingProgressLink",
                destinationIdentifier: "readingProgressSettingsScreen",
                in: app,
                destinationTimeout: 20
            ).exists
        )
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
        dismissKeyboardAfterFocusedTextEntry(serverField, in: app)
        triggerSyncConnectionTest(in: app, timeout: 15)
        waitForElementValue("syncSettingsState", toContain: "remoteStatus=failureInvalidURL", in: app, timeout: 10)
    }

    /**
     Verifies that the visible adopt-versus-create confirmation can drive the create-new branch.
     *
     * - Side effects:
     *   - launches Sync Settings with deterministic NextCloud settings and a UI-test remote
     *     backend that reports one existing same-named bookmark sync folder
     *   - enables bookmark sync through the production category row
     *   - chooses "Copy from this device to Cloud" in the adopt-versus-create prompt and confirms
     *     the destructive reset-cloud branch
     * - Failure modes:
     *   - fails if the first adopt/create prompt never appears
     *   - fails if the create-new choice does not surface the reset-cloud confirmation
     *   - fails if confirming the reset-cloud branch does not complete synchronization with the
     *     bookmarks category enabled
     */
    func testSyncSettingsAdoptCreateConfirmationCreateChoiceSynchronizesFromVisibleWorkflow() {
        let app = makeApp(remoteSyncBootstrapScenario: "adopt-existing")
        app.launch()

        _ = openSyncSettingsFromReaderAction(in: app)
        waitForSyncState(["backend": "NEXT_CLOUD", "enabled": "none"], in: app, timeout: 10)

        toggleSyncCategory(
            "syncCategoryToggle::bookmarks",
            in: app,
            expectedTokens: [
                "backend": "NEXT_CLOUD",
                "enabled": "bookmarks",
                "bootstrapPrompt": "adoptOrCreate:bookmarks",
            ],
            timeout: 15
        )

        let createFromDeviceButton = app.alerts.firstMatch.buttons["Copy from this device to Cloud"].firstMatch
        XCTAssertTrue(
            createFromDeviceButton.waitForExistence(timeout: 10),
            "Expected the adopt-versus-create alert to expose the create-new choice."
        )
        tapElementReliably(createFromDeviceButton, timeout: 10)

        waitForSyncState(["pendingConfirmation": "resetCloud:bookmarks"], in: app, timeout: 10)
        tapAlertButton("OK", in: app, timeout: 10)

        waitForSyncState(
            [
                "backend": "NEXT_CLOUD",
                "enabled": "bookmarks",
                "bootstrapPrompt": "none",
                "pendingConfirmation": "none",
                "lastConfirmation": "resetCloud:bookmarks",
            ],
            in: app,
            timeout: 20
        )
    }

    /**
     Verifies that the My Documents category row is exposed and starts the same manual
     synchronization path as existing supported categories.
     *
     * - Side effects:
     *   - launches Sync Settings with deterministic NextCloud settings and a UI-test remote
     *     backend that reports one existing same-named My Documents sync folder
     *   - scrolls to and enables the production My Documents category row
     *   - leaves synchronization at the visible adopt-versus-create prompt, proving the category
     *     entered the manual remote-sync branch without requiring live credentials
     * - Failure modes:
     *   - fails if the My Documents category row is missing from Sync Settings
     *   - fails if enabling the row does not persist `enabled=mydocuments`
     *   - fails if enabling the row does not surface the My Documents adopt/create prompt
     */
    func testSyncSettingsMyDocumentsCategoryToggleStartsManualSyncPath() {
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
    }

    /**
     Verifies that the Sync category section exports Android's runtime-visible row set.
     *
     * Android declares Reading Plans in XML but hides it at runtime, while AI Settings and Reading
     * Progress remain visible. iOS mirrors that by exporting active rows for implemented
     * categories and deferred rows for the unimplemented AI/progress engines.
     *
     * - Side effects:
     *   - launches Sync Settings with deterministic NextCloud settings
     *   - reads the production Sync Settings accessibility state probe
     * - Failure modes:
     *   - fails if Reading Plans is reintroduced to the visible row set
     *   - fails if AI Settings or Reading Progress stop being disclosed as deferred rows
     */
    func testSyncSettingsCategoryRowsMatchAndroidRuntimeVisibility() {
        let app = makeApp()
        app.launch()

        _ = openSyncSettingsFromReaderAction(in: app)
        waitForSyncState(
            [
                "backend": "NEXT_CLOUD",
                "visible": "bookmarks,workspaces,mydocuments,ai_settings,progress",
                "deferred": "ai_settings,progress",
            ],
            in: app,
            timeout: 10
        )
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
    }

    /**
     Verifies that switching the active sync backend swaps the visible Sync section and exported
     backend state.
     *
     * - Side effects:
     *   - launches the app on the reader shell with persisted NextCloud settings from host-side
     *     fixture seeding
     *   - opens Sync Settings from the reader action and switches the production picker from
     *     NextCloud to iCloud
     * - Failure modes:
     *   - fails if the seeded NextCloud field or the iCloud enable toggle never appears
     *   - fails if the exported Sync screen state does not move from `backend=NEXT_CLOUD;enabled=none`
     *     to `backend=ICLOUD;enabled=none`
     */
    func testSyncSettingsBackendSwitchMutatesVisibleSection() {
        let app = makeApp()
        app.launch()

        _ = openSyncSettingsFromReaderAction(in: app)
        let syncState = requireElement("syncSettingsState", in: app, timeout: 10)
        assertSyncState(
            syncState.value as? String,
            backend: "NEXT_CLOUD",
            enabled: "none"
        )
        XCTAssertTrue(requireElement("syncNextCloudServerURLField", in: app, timeout: 10).exists)

        tapSyncBackend("ICLOUD", in: app)
        waitForSyncState(
            ["backend": "ICLOUD", "enabled": "none"],
            in: app,
            timeout: 10
        )
        XCTAssertTrue(requireElement("syncICloudEnabledToggle", in: app, timeout: 10).exists)
    }

    /**
     Verifies that switching the active sync backend persists across a direct dismiss and reopen of
     Sync Settings.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens Sync Settings with its persisted backend
     *   - switches the backend from NextCloud to iCloud through the production picker
     *   - dismisses and reopens Sync Settings from the reader action so the sheet rehydrates from
     *     persisted settings state
     * - Failure modes:
     *   - fails if the seeded Sync screen does not start in the NextCloud branch
     *   - fails if the dismiss or reopen controls never appear
     *   - fails if reopening the sheet does not preserve the exported `backend=ICLOUD;enabled=none`
     *     state token or the iCloud section
     */
    func testSyncSettingsBackendSwitchPersistsAcrossDirectReopen() {
        let app = makeApp()
        app.launch()

        _ = openSyncSettingsFromReaderAction(in: app)
        let syncState = requireElement("syncSettingsState", in: app, timeout: 10)
        assertSyncState(
            syncState.value as? String,
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

        let textDisplayScreen = openAllTextOptions(in: app)
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

        let textDisplayScreen = openAllTextOptions(in: app)
        XCTAssertTrue(textDisplayScreen.exists)
        let fontFamilyButton = requireReachableTextDisplayButton("textDisplayFontFamilyButton", in: app, timeout: 10)
        tapElementReliably(fontFamilyButton, timeout: 10)
        waitForElementValue("textDisplaySettingsScreen", toContain: "fontPickerPresented", in: app, timeout: 10)
    }

    /**
     Verifies that the color editor can be opened from All Text Options.
     *
     * - Side effects:
     *   - launches the app on the reader shell and opens All Text Options
     *   - opens Colors from the text-display settings screen
     * - Failure modes:
     *   - fails if the Text Options colors link is missing or never becomes hittable
     *   - fails if the color settings screen does not render after navigation completes
     */
    func testSettingsColorsLinkOpensColorEditor() {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(openColorSettings(in: app).exists)
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
