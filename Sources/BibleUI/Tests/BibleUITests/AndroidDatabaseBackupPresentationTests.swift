import XCTest
import UniformTypeIdentifiers
@testable import BibleCore
@testable import BibleUI

/**
 Package-level presentation tests for Android database backup UI copy.

 The database backup service and archive semantics belong in `BibleCoreTests`; this suite protects
 the BibleUI-only localized strings that the Backup & Restore screen presents around those services.
 */
final class AndroidDatabaseBackupPresentationTests: XCTestCase {
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
}
