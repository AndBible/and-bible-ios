import XCTest
import SwiftData
import UniformTypeIdentifiers
@testable import BibleCore
@testable import BibleUI

/**
 Package-level presentation tests for Android database backup UI copy.

 The database backup service and archive semantics belong in `BibleCoreTests`; this suite protects
 the BibleUI-only localized strings that the Backup & Restore screen presents around those services.
 */
final class AndroidDatabaseBackupPresentationTests: XCTestCase {
    /** Verifies restored settings/workspaces immediately rebind and reload the live speech service. */
    func testAndroidBackupRestoreReloadsLiveSpeechRuntimeOnlyForRelevantSections() throws {
        let container = try makeWorkspaceModelContainer()
        let settingsStore = SettingsStore(modelContext: ModelContext(container))
        var globalSettings = SpeakSettings()
        globalSettings.playbackSettings.speed = 173
        settingsStore.setString("SpeakSettings", value: try globalSettings.androidJSON())
        let speakService = SpeakService()

        XCTAssertFalse(
            AndroidBackupSpeechRuntimeReloader.reloadIfNeeded(
                selections: [.init(category: .bookmarks, mode: .restore)],
                settingsStore: settingsStore,
                activeWorkspaceSettings: nil,
                speakService: speakService
            )
        )
        XCTAssertEqual(speakService.settings.playbackSettings.speed, 100)

        XCTAssertTrue(
            AndroidBackupSpeechRuntimeReloader.reloadIfNeeded(
                selections: [.init(category: .settings, mode: .restore)],
                settingsStore: settingsStore,
                activeWorkspaceSettings: nil,
                speakService: speakService
            )
        )
        XCTAssertEqual(speakService.settings, globalSettings)

        var workspaceSettings = SpeakSettings()
        workspaceSettings.playbackSettings.speed = 189
        workspaceSettings.sleepTimer = 12
        XCTAssertTrue(
            AndroidBackupSpeechRuntimeReloader.reloadIfNeeded(
                selections: [.init(category: .workspaces, mode: .import)],
                settingsStore: settingsStore,
                activeWorkspaceSettings: workspaceSettings,
                speakService: speakService
            )
        )
        XCTAssertEqual(speakService.settings, workspaceSettings)
    }

    /**
     Verifies Backup & Restore reset success copy names the category that was reset.

     Setup:
     - reads the BibleUI presentation labels for Android reset categories

     Expected result:
     - repository reset feedback includes repository wording
     - repository reset feedback does not claim that only "Database" was reset

     Failure meaning:
     - the user-visible reset result would be misleading for non-database categories such as
       Repositories, Application Preferences, My Documents, or Progress.
     */
    func testAndroidBackupResetSuccessMessageNamesSelectedCategory() {
        let message = AndroidBackupResetCategory.repositories.localizedBackupResetSuccessMessage

        XCTAssertTrue(message.localizedCaseInsensitiveContains("repositories"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("database has been reset"))
    }

    /**
     Verifies Android's Database and Documents restore/import targets keep distinct picker payloads.

     Setup:
     - builds package-level presentation snapshots that mirror tapping Restore or Import with each
       Android-visible target selected

     Expected result:
     - Database reports the database restore picker sentinel and accepts Android database archive
       UTTypes only
     - Documents reports the documents picker sentinel and accepts the shared document/module import
       UTTypes

     Failure meaning:
     - the iOS Backup & Restore screen could collapse Android's distinct Database/Documents restore
       paths into one generic picker, hiding database archive errors or routing module imports to the
       wrong importer.
     */
    func testRestoreImportPickerPresentationSeparatesDatabaseAndDocumentsTargets() {
        let databaseState = ImportExportPresentationState(
            restoreImportPickerPresented: true,
            restoreImportPickerTarget: .database,
            restoreTarget: .documents
        )
        let documentsState = ImportExportPresentationState(
            restoreImportPickerPresented: true,
            restoreImportPickerTarget: .documents,
            restoreTarget: .database
        )

        XCTAssertEqual(databaseState.accessibilityValue, "databaseRestorePickerPresented")
        XCTAssertEqual(databaseState.restoreImportPickerContentTypes, [.zip, .data])
        XCTAssertEqual(documentsState.accessibilityValue, "documentsRestorePickerPresented")
        XCTAssertEqual(
            documentsState.restoreImportPickerContentTypes,
            ExternalDocumentImportService.supportedContentTypes
        )
        XCTAssertNotEqual(
            documentsState.restoreImportPickerContentTypes,
            databaseState.restoreImportPickerContentTypes
        )
    }

    /**
     Verifies the restore/import picker falls back to the persisted target if SwiftUI clears the
     transient picker target before result handling.

     Setup:
     - constructs active picker snapshots without a transient target, matching a defensive lifecycle
       boundary in SwiftUI file importer presentation

     Expected result:
     - persisted Database still reports database picker state and database archive UTTypes
     - persisted Documents still reports documents picker state and document/module UTTypes

     Failure meaning:
     - a platform cleanup race could silently reroute Documents imports into the Database backup path
       or database restores into the Documents importer.
     */
    func testRestoreImportPickerPresentationFallsBackToPersistedTarget() {
        let databaseFallbackState = ImportExportPresentationState(
            restoreImportPickerPresented: true,
            restoreTarget: .database
        )
        let documentsFallbackState = ImportExportPresentationState(
            restoreImportPickerPresented: true,
            restoreTarget: .documents
        )

        XCTAssertEqual(databaseFallbackState.effectiveRestoreImportTarget, .database)
        XCTAssertEqual(databaseFallbackState.accessibilityValue, "databaseRestorePickerPresented")
        XCTAssertEqual(databaseFallbackState.restoreImportPickerContentTypes, [.zip, .data])
        XCTAssertEqual(documentsFallbackState.effectiveRestoreImportTarget, .documents)
        XCTAssertEqual(documentsFallbackState.accessibilityValue, "documentsRestorePickerPresented")
        XCTAssertEqual(
            documentsFallbackState.restoreImportPickerContentTypes,
            ExternalDocumentImportService.supportedContentTypes
        )
    }

    /**
     Verifies Backup & Restore reports the foremost active presentation surface.

     Setup:
     - builds synthetic state with multiple booleans active to model SwiftUI's transitional frames
       while a modal is being replaced

     Expected result:
     - Android's backup destination dialog remains the foremost sentinel
     - lower-priority progress and payload states do not mask visible modal ownership

     Failure meaning:
     - UI automation could observe a stale or lower-priority state, making tests brittle and hiding
       regressions in the visible Android-aligned workflow.
     */
    func testBackupRestorePresentationStatePrioritizesVisibleModalSurfaces() {
        let state = ImportExportPresentationState(
            backupDestinationPresented: true,
            shareSheetPresented: true,
            restoreImportPickerPresented: true,
            restoreImportPickerTarget: .documents,
            restoreTarget: .database,
            androidBackupImportPresented: true,
            resetInProgress: true,
            backupPayloadPending: true
        )

        XCTAssertEqual(state.accessibilityValue, "backupDestinationPresented")
    }

    /**
     Verifies Android shows a checked-by-default section dialog only for multiple safe databases.

     Failure meaning: unsupported databases could become actionable, archive order could drift, or
     the iOS flow could invent a section picker for Android's single-database fast path.
     */
    func testDatabaseDialogStateSelectsEverySupportedSectionInArchiveOrder() {
        let sections = [
            databaseSection(.bookmarks),
            databaseSection(.settings),
            databaseSection(
                .repositories,
                support: .unsupportedVersion(version: 2, supported: 1)
            ),
        ]

        let state = AndroidDatabaseBackupDialogState(sections: sections)

        XCTAssertEqual(state.phase, .sectionSelection)
        XCTAssertEqual(state.orderedSupportedCategories, [.bookmarks, .settings])
        XCTAssertEqual(state.selectedCategories, Set([.bookmarks, .settings]))
        XCTAssertTrue(state.selections.isEmpty)
    }

    /**
     Verifies OK with no checked sections follows Android's empty-result dismissal path.

     Failure meaning: the app could apply an empty batch, leave a blank modal visible, or treat the
     neutral Select-none action as a destructive command.
     */
    func testDatabaseDialogStateDismissesAnEmptySectionSelection() {
        var state = AndroidDatabaseBackupDialogState(
            sections: [databaseSection(.bookmarks), databaseSection(.workspaces)]
        )
        state.selectedCategories = []

        XCTAssertEqual(state.confirmSectionSelection(), .dismiss)
        XCTAssertEqual(state.phase, .finished)
        XCTAssertTrue(state.selections.isEmpty)
    }

    /**
     Verifies Android's per-category Import then Restore/overwrite sequence and ordered batch.

     Failure meaning: iOS could collapse mode choices into one global picker, omit destructive
     confirmation, or reorder archive sections before the service applies them.
     */
    func testDatabaseDialogStateCollectsSequentialImportAndConfirmedRestore() {
        var state = AndroidDatabaseBackupDialogState(
            sections: [databaseSection(.bookmarks), databaseSection(.workspaces)]
        )

        XCTAssertEqual(state.confirmSectionSelection(), .awaitingInput)
        XCTAssertEqual(state.phase, .modeChoice(.bookmarks))
        XCTAssertEqual(state.chooseMode(.import), .awaitingInput)
        XCTAssertEqual(state.phase, .modeChoice(.workspaces))
        XCTAssertEqual(state.chooseMode(.restore), .awaitingInput)
        XCTAssertEqual(state.phase, .overwriteConfirmation(.workspaces))
        XCTAssertEqual(state.confirmOverwrite(), .awaitingInput)
        XCTAssertEqual(state.phase, .readyToApply)
        XCTAssertEqual(
            state.takeReadyOutcome(),
            .apply([
                .init(category: .bookmarks, mode: .import),
                .init(category: .workspaces, mode: .restore),
            ])
        )
        XCTAssertEqual(state.phase, .finished)
        XCTAssertEqual(state.takeReadyOutcome(), .awaitingInput)
    }

    /**
     Verifies Android's neutral Cancel skips one database instead of abandoning later selections.

     Failure meaning: canceling one mode question could wrongly dismiss the whole archive or apply
     a category for which the user never chose a mode.
     */
    func testDatabaseDialogStateCancelSkipsOnlyTheCurrentCategory() {
        var state = AndroidDatabaseBackupDialogState(
            sections: [databaseSection(.bookmarks), databaseSection(.workspaces)]
        )

        XCTAssertEqual(state.confirmSectionSelection(), .awaitingInput)
        XCTAssertEqual(state.skipCurrentCategory(), .awaitingInput)
        XCTAssertEqual(state.phase, .modeChoice(.workspaces))
        XCTAssertEqual(state.skipCurrentCategory(), .dismiss)
        XCTAssertEqual(state.phase, .finished)
        XCTAssertTrue(state.selections.isEmpty)
    }

    /**
     Verifies Android skips the section selector for one database and retains category-specific
     restore behavior when iOS supports fewer modes than Android.

     Failure meaning: single sync archives could require an invented extra dialog, or restore-only
     sync/non-sync categories could receive the wrong overwrite treatment.
     */
    func testDatabaseDialogStateUsesAndroidSingleSectionAndRestoreOnlyPaths() {
        let syncState = AndroidDatabaseBackupDialogState(
            sections: [databaseSection(.bookmarks)]
        )
        XCTAssertEqual(syncState.phase, .modeChoice(.bookmarks))

        let restoreOnlySyncState = AndroidDatabaseBackupDialogState(
            sections: [databaseSection(.aiSettings)]
        )
        XCTAssertEqual(restoreOnlySyncState.phase, .overwriteConfirmation(.aiSettings))

        var nonSyncState = AndroidDatabaseBackupDialogState(
            sections: [databaseSection(.settings)]
        )
        XCTAssertEqual(nonSyncState.phase, .readyToApply)
        XCTAssertEqual(
            nonSyncState.takeReadyOutcome(),
            .apply([.init(category: .settings, mode: .restore)])
        )
    }

    /**
     Creates one presentation-only validated section for pure dialog-state tests.

     - Parameters:
       - category: Android database identity under test.
       - support: Validation result presented to the state machine.
     - Returns: Immutable section metadata; its temporary URL is never opened.
     - Side effects: none.
     - Failure modes: none.
     */
    private func databaseSection(
        _ category: AndroidDatabaseBackupCategory,
        support: AndroidDatabaseBackupSectionSupport = .supported
    ) -> AndroidDatabaseBackupSection {
        AndroidDatabaseBackupSection(
            category: category,
            fileName: category.databaseFileName ?? "",
            databaseFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(category.rawValue).sqlite3"),
            databaseVersion: 1,
            declaredInManifest: true,
            support: support
        )
    }
}
