// BackupRestoreWorkflowSupport.swift -- Android BackupActivity presentation helpers

import BibleCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/**
 Actionable backup targets shown in iOS's Android-aligned Backup & Restore workflow.

 Android's BackupActivity also offers Application/APK backup. iOS omits that row instead of
 showing an inert option because the platform cannot export an installed app bundle as an APK/IPA
 equivalent from inside the app.
 */
enum BackupWorkflowTarget: String, CaseIterable, Identifiable {
    /// Bookmarks, labels, notes, StudyPads, reading plans, workspaces, and related databases.
    case database

    /// Installed Bible/commentary/dictionary/map modules and EPUB-like document content.
    case documents

    /// Stable SwiftUI identifier.
    var id: String { rawValue }

    /// Title shown beside the radio control.
    var localizedTitle: String {
        switch self {
        case .database:
            return String(localized: "backup_database", defaultValue: "Database")
        case .documents:
            return String(localized: "backup_documents", defaultValue: "Documents")
        }
    }

    /// Android-derived explanatory text shown below the radio title.
    var localizedDescription: String {
        switch self {
        case .database:
            return String(
                localized: "backup_database_info",
                defaultValue: "Bookmarks, labels, notes, study pads, reading plans, workspaces etc."
            )
        case .documents:
            return String(
                localized: "backup_document_info",
                defaultValue: "Bibles, commentaries, dictionaries, maps etc."
            )
        }
    }
}

/**
 Restore/import targets shown by Android's BackupActivity.

 Android exposes Restore or Import for Database archives and a Documents loader for module/document
 files. Application restore is intentionally absent from Android's restore radio group and is not
 added on iOS.
 */
enum RestoreWorkflowTarget: String, CaseIterable, Identifiable {
    /// Android `.abdb.zip` database archive restore/import.
    case database

    /// Android document/module loader and `.abmd.zip` module backup restore/import.
    case documents

    /// Stable SwiftUI identifier.
    var id: String { rawValue }

    /// Title shown beside the radio control.
    var localizedTitle: String {
        switch self {
        case .database:
            return BackupWorkflowTarget.database.localizedTitle
        case .documents:
            return BackupWorkflowTarget.documents.localizedTitle
        }
    }

    /// Android-derived explanatory text shown below the radio title.
    var localizedDescription: String {
        switch self {
        case .database:
            return BackupWorkflowTarget.database.localizedDescription
        case .documents:
            return BackupWorkflowTarget.documents.localizedDescription
        }
    }
}

/**
 Presentation state exported by the Android-aligned Backup & Restore screen.

 The SwiftUI view owns the actual `@State` values and platform presenters. This value type keeps
 the derived accessibility sentinel and restore/import picker content-type contract testable without
 booting the app, while preserving Android's visible split between Database restore/import archives
 and Documents/module imports.

 - Parameters:
   - backupDestinationPresented: Whether Android's "Backup to where?" destination dialog is active.
   - backupFileExporterPresented: Whether the iOS Files exporter is active for Phone storage.
   - shareSheetPresented: Whether the iOS share controller is active for Share.
   - restoreImportPickerPresented: Whether the shared Restore or Import file picker is active.
   - restoreImportPickerTarget: Transient target captured when the user tapped Restore or Import.
   - restoreTarget: Persisted Android restore/import radio target.
   - androidModuleBackupExportPresented: Whether module-backup export selection is active.
   - androidBackupImportPresented: Whether Android database-backup section selection is active.
   - resetInProgress: Whether an Android BackupActivity reset category is mutating storage.
   - backupPayloadPending: Whether a generated backup archive is awaiting a destination.
 - Side effects: none; callers are responsible for presenting and mutating SwiftUI state.
 - Failure modes: If the transient restore/import picker target is absent, the persisted target is
   used so SwiftUI lifecycle cleanup cannot collapse Documents imports into Database restores.
 */
struct ImportExportPresentationState: Equatable {
    /// Whether Android's "Backup to where?" destination dialog is active.
    let backupDestinationPresented: Bool

    /// Whether the iOS Files exporter is active for Phone storage.
    let backupFileExporterPresented: Bool

    /// Whether the iOS share controller is active for Share.
    let shareSheetPresented: Bool

    /// Whether the shared Restore or Import file picker is active.
    let restoreImportPickerPresented: Bool

    /// Transient target captured when the user tapped Restore or Import.
    let restoreImportPickerTarget: RestoreWorkflowTarget?

    /// Persisted Android restore/import radio target.
    let restoreTarget: RestoreWorkflowTarget

    /// Whether module-backup export selection is active.
    let androidModuleBackupExportPresented: Bool

    /// Whether Android database-backup section selection is active.
    let androidBackupImportPresented: Bool

    /// Whether an Android BackupActivity reset category is mutating storage.
    let resetInProgress: Bool

    /// Whether a generated backup archive is awaiting a destination.
    let backupPayloadPending: Bool

    /**
     Creates a presentation snapshot for Backup & Restore derived state.

     - Parameters:
       - backupDestinationPresented: Whether Android's destination dialog is active.
       - backupFileExporterPresented: Whether the Files exporter is active.
       - shareSheetPresented: Whether the share sheet is active.
       - restoreImportPickerPresented: Whether the restore/import picker is active.
       - restoreImportPickerTarget: Optional target captured for the active picker.
       - restoreTarget: Persisted fallback target for restore/import.
       - androidModuleBackupExportPresented: Whether module backup export selection is active.
       - androidBackupImportPresented: Whether Android database backup selection is active.
       - resetInProgress: Whether a reset operation is active.
       - backupPayloadPending: Whether an export payload is pending.
     - Side effects: none.
     - Failure modes: none.
     */
    init(
        backupDestinationPresented: Bool = false,
        backupFileExporterPresented: Bool = false,
        shareSheetPresented: Bool = false,
        restoreImportPickerPresented: Bool = false,
        restoreImportPickerTarget: RestoreWorkflowTarget? = nil,
        restoreTarget: RestoreWorkflowTarget = .database,
        androidModuleBackupExportPresented: Bool = false,
        androidBackupImportPresented: Bool = false,
        resetInProgress: Bool = false,
        backupPayloadPending: Bool = false
    ) {
        self.backupDestinationPresented = backupDestinationPresented
        self.backupFileExporterPresented = backupFileExporterPresented
        self.shareSheetPresented = shareSheetPresented
        self.restoreImportPickerPresented = restoreImportPickerPresented
        self.restoreImportPickerTarget = restoreImportPickerTarget
        self.restoreTarget = restoreTarget
        self.androidModuleBackupExportPresented = androidModuleBackupExportPresented
        self.androidBackupImportPresented = androidBackupImportPresented
        self.resetInProgress = resetInProgress
        self.backupPayloadPending = backupPayloadPending
    }

    /**
     Target that should own the active restore/import picker.

     - Returns: The transient picker target when present, otherwise the persisted radio target.
     - Side effects: none.
     - Failure modes: none; fallback preserves a valid Android target.
     */
    var effectiveRestoreImportTarget: RestoreWorkflowTarget {
        restoreImportPickerTarget ?? restoreTarget
    }

    /**
     Accessibility sentinel exposed for UI tests on the Backup & Restore root.

     - Returns: A single stable token describing the foremost active presentation surface.
     - Side effects: none.
     - Failure modes: none; inactive state returns `idle`.
     */
    var accessibilityValue: String {
        if backupDestinationPresented {
            return "backupDestinationPresented"
        }
        if backupFileExporterPresented {
            return "fileExporterPresented"
        }
        if shareSheetPresented {
            return "shareSheetPresented"
        }
        if restoreImportPickerPresented {
            switch effectiveRestoreImportTarget {
            case .database:
                return "databaseRestorePickerPresented"
            case .documents:
                return "documentsRestorePickerPresented"
            }
        }
        if androidModuleBackupExportPresented {
            return "androidModuleBackupExportPresented"
        }
        if androidBackupImportPresented {
            return "androidBackupImportPresented"
        }
        if resetInProgress {
            return "resetInProgress"
        }
        if backupPayloadPending {
            return "backupPayloadPending"
        }
        return "idle"
    }

    /**
     Allowed content types for the currently active restore/import picker.

     Android keeps database backups and module/document imports as separate visible restore targets.
     iOS uses one SwiftUI importer and selects content types from this derived state so the platform
     picker still follows that Android contract.

     - Returns: Database archive types for Database, or module/document types for Documents.
     - Side effects: none.
     - Failure modes: Falls back to `restoreTarget` when no transient picker target is available.
     */
    var restoreImportPickerContentTypes: [UTType] {
        switch effectiveRestoreImportTarget {
        case .database:
            return [.zip, .data]
        case .documents:
            return ExternalDocumentImportService.supportedContentTypes
        }
    }
}

/**
 Android BackupActivity destination choices adapted to iOS file plumbing.

 Android labels the choices Phone storage and Share. iOS implements Phone storage through the
 native document exporter and Share through the existing share sheet, preserving the visible
 decision even though the platform plumbing differs.
 */
enum BackupExportDestination {
    /// Save through the Files document exporter.
    case phoneStorage

    /// Present the platform share sheet.
    case share
}

/**
 Prepared backup file waiting for the user's destination choice.

 - Note: Backup generation happens before the destination dialog so the dialog only appears when
   there is a valid archive to save or share.
 */
struct BackupExportPayload {
    /// Generated backup content, either in memory or already staged as a temporary file.
    enum Content {
        /// Raw backup archive bytes.
        case data(Data)

        /// Temporary archive file owned by this payload until the destination flow completes.
        case temporaryFile(URL)
    }

    /// Generated backup content prepared for Files export or Share.
    let content: Content

    /// Android-compatible default file name.
    let fileName: String

    /// Completion message to show after a destination is selected.
    let statusMessage: String

    /**
     Creates an in-memory payload for smaller backup archive producers.

     - Parameters:
       - data: Archive bytes to export.
       - fileName: Android-compatible default file name.
       - statusMessage: Completion message shown after the selected destination accepts the backup.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    init(data: Data, fileName: String, statusMessage: String) {
        self.content = .data(data)
        self.fileName = fileName
        self.statusMessage = statusMessage
    }

    /**
     Creates a temporary file-backed payload for large backup archive producers.

     - Parameters:
       - temporaryFileURL: Temporary archive file owned by the destination workflow.
       - fileName: Android-compatible default file name.
       - statusMessage: Completion message shown after the selected destination accepts the backup.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    init(temporaryFileURL: URL, fileName: String, statusMessage: String) {
        self.content = .temporaryFile(temporaryFileURL)
        self.fileName = fileName
        self.statusMessage = statusMessage
    }

    /**
     Builds the SwiftUI document used by Phone storage export.

     - Returns: A `BackupExportDocument` backed by the payload's existing storage.
     - Side effects: none.
     - Failure modes: File-backed documents may throw later if SwiftUI writes after the temporary file
       has been removed.
     */
    func fileDocument() -> BackupExportDocument {
        switch content {
        case .data(let data):
            return BackupExportDocument(data: data)
        case .temporaryFile(let fileURL):
            return BackupExportDocument(fileURL: fileURL)
        }
    }

    /**
     Returns a ready-to-share temporary file when the payload is already file-backed.

     - Returns: Temporary file URL for file-backed payloads, otherwise `nil`.
     - Side effects: none.
     - Failure modes: none.
     */
    var temporaryFileURL: URL? {
        if case .temporaryFile(let fileURL) = content {
            return fileURL
        }
        return nil
    }

    /**
     Reads the payload bytes for APIs that still require `Data`.

     - Returns: Archive bytes from memory or from the temporary file.
     - Side effects: Reads file-backed payload contents from disk.
     - Failure modes: Rethrows file read failures for temporary file-backed payloads.
     */
    func loadData() throws -> Data {
        switch content {
        case .data(let data):
            return data
        case .temporaryFile(let fileURL):
            return try Data(contentsOf: fileURL)
        }
    }

    /**
     Removes the temporary file owned by this payload.

     - Side effects: Deletes the file-backed archive if present.
     - Failure modes: Cleanup failures are intentionally ignored because the destination flow has
       already ended and the file lives in the temporary directory.
     */
    func cleanupTemporaryFile() {
        guard case .temporaryFile(let fileURL) = content else {
            return
        }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/**
 Minimal `FileDocument` wrapper for exporting Android-compatible backup archives.

 The document is write-only for this workflow. A permissive read initializer is still supplied
 because SwiftUI's `FileDocument` protocol requires it, but the import path never constructs this
 type from user-selected files.
 */
struct BackupExportDocument: FileDocument {
    /// Source used when SwiftUI writes the exported file.
    private enum Content {
        /// Raw bytes for smaller generated backups.
        case data(Data)

        /// Existing temporary archive file for larger generated backups.
        case file(URL)
    }

    /// The exporter writes ZIP archives, including Android's compound `.abdb.zip` and `.abmd.zip` names.
    static var readableContentTypes: [UTType] { [.zip, .data] }

    /// File contents written by `fileWrapper(configuration:)`.
    private var content: Content

    /**
     Creates a document from generated backup bytes.

     - Parameter data: Archive bytes to write.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    init(data: Data = Data()) {
        self.content = .data(data)
    }

    /**
     Creates a document from an existing temporary backup file.

     - Parameter fileURL: Archive file to stream through SwiftUI's document exporter.
     - Side effects: none.
     - Failure modes: This initializer cannot fail; `fileWrapper(configuration:)` reports missing
       or unreadable files when SwiftUI writes the document.
     */
    init(fileURL: URL) {
        self.content = .file(fileURL)
    }

    /**
     Creates a document from a file-import configuration to satisfy `FileDocument`.

     - Parameter configuration: SwiftUI read configuration.
     - Side effects: Reads in-memory file wrapper contents when SwiftUI invokes this path.
     - Failure modes: Missing regular-file contents produce an empty document because this app does
       not use `BackupExportDocument` for importing.
     */
    init(configuration: ReadConfiguration) throws {
        content = .data(configuration.file.regularFileContents ?? Data())
    }

    /**
     Produces the file wrapper written by SwiftUI's exporter.

     - Parameter configuration: SwiftUI write configuration.
     - Returns: A regular file wrapper containing the generated backup content.
     - Side effects: Creates a lazy file wrapper for file-backed payloads; SwiftUI performs the
       actual destination read and write.
     - Failure modes: Rethrows file-wrapper creation failures for missing or unreadable temporary
       files.
     */
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        switch content {
        case .data(let data):
            return FileWrapper(regularFileWithContents: data)
        case .file(let fileURL):
            return try FileWrapper(url: fileURL, options: [])
        }
    }
}

/**
 Android-style radio row used by the Backup & Restore workflow.

 This adapter supplies BackupActivity's generic value type and stable identifiers to the shared
 `AndroidRadioRow`; it does not reconstruct a feature-local radio indicator.
 */
struct BackupWorkflowOptionRow<Value: Equatable>: View {
    /// Title shown beside the radio indicator.
    let title: String

    /// Secondary explanation shown under the title.
    let description: String

    /// Value represented by this row.
    let value: Value

    /// Currently selected value for the surrounding radio group.
    @Binding var selection: Value

    /// Whether the row accepts input while the parent workflow is idle.
    let isEnabled: Bool

    /// Owner-resolved primary content color.
    let foregroundColor: Color

    /// Owner-resolved supporting-text and unchecked-indicator color.
    let secondaryColor: Color

    /// Global AppCompat accent used by the selected radio indicator.
    let accentColor: Color

    /// Accessibility identifier assigned to the row button.
    let accessibilityIdentifier: String

    /**
     Builds one radio row.

     - Side effects: Mutates the bound selection when the row is tapped.
     - Failure modes: This view does not throw; accessibility state follows the bound selection.
     */
    var body: some View {
        AndroidRadioRow(
            title: title,
            description: description,
            value: value,
            selection: $selection,
            isEnabled: isEnabled,
            foregroundColor: foregroundColor,
            secondaryColor: secondaryColor,
            accentColor: accentColor,
            accessibilityIdentifier: accessibilityIdentifier
        )
    }
}

/**
 Localizes Android BackupActivity reset category titles for the iOS settings screen.

 The extension stays in BibleUI because these labels are presentation copy. The reset behavior and
 category boundaries remain owned by `AndroidBackupResetService` in BibleCore.
 */
extension AndroidBackupResetCategory {
    /// Android-derived button target name without the "Reset:" prefix.
    var localizedBackupResetTitle: String {
        switch self {
        case .bookmarks:
            return String(
                localized: "db_bookmarks",
                defaultValue: "Bookmarks, My Notes, Labels and Study Pads"
            )
        case .workspaces:
            return String(localized: "help_workspaces_title", defaultValue: "Workspaces")
        case .readingPlans:
            return String(localized: "reading_plans_plural", defaultValue: "Reading Plans")
        case .repositories:
            return String(
                localized: "db_repositories",
                defaultValue: "Repositories and related settings"
            )
        case .applicationPreferences:
            return String(localized: "settings", defaultValue: "Application Preferences")
        case .myDocuments:
            return String(localized: "my_documents_title", defaultValue: "My Documents")
        case .aiSettings:
            return String(localized: "ai_settings_sync_title", defaultValue: "AI Settings")
        case .progress:
            return String(localized: "progress_sync_title", defaultValue: "Reading Progress")
        }
    }

    /// Full reset button title matching Android's `reset_something` pattern.
    var localizedBackupResetButtonTitle: String {
        String(
            format: String(localized: "reset_something", defaultValue: "Reset: %@"),
            localizedBackupResetTitle
        )
    }

    /**
     Category-aware success message for Android BackupActivity reset actions.
     *
     - Returns: User-visible confirmation that names the category just reset instead of always
       saying "Database".
     - Side effects: none.
     - Failure modes: none.
     */
    var localizedBackupResetSuccessMessage: String {
        String(
            format: String(
                localized: "reset_category_success",
                defaultValue: "%@ has been reset successfully"
            ),
            localizedBackupResetTitle
        )
    }

    /// Stable accessibility identifier for UI tests.
    var backupResetAccessibilityIdentifier: String {
        "backupWorkflowReset.\(rawValue)Button"
    }
}

/**
 Android module backup presentation strings shared by Settings and external file-open imports.

 Android restores `.abmd.zip` archives through `InstallZip`, which reports successful document
 installs with the generic `install_zip_successfull` toast instead of enumerating every module in
 the backup. iOS keeps restore reports for diagnostics and tests, but user-facing completion copy
 comes from this helper so both restore entry points stay aligned with Android.
 */
enum AndroidModuleBackupPresentation {
    /**
     Generic Android InstallZip success text for module backup restores.

     - Returns: Localized success message equivalent to Android's `install_zip_successfull`.
     - Side effects: Reads localization resources through Swift's localized string lookup.
     - Failure modes: Missing localization falls back to Android's English string.
     */
    static var localizedInstallSuccessMessage: String {
        String(
            localized: "install_zip_successfull",
            defaultValue: "Module was installed successfully"
        )
    }

    /**
     Converts a completed Android module-backup restore report into Android's success copy.

     - Parameter report: Restore report retained by callers for diagnostics and future telemetry.
     - Returns: Generic Android InstallZip success text, intentionally independent of module names,
       entry counts, and skipped Android-only payloads because Android's success toast does not
       expose those details.
     - Side effects: Reads localization resources through Swift's localized string lookup.
     - Failure modes: Missing localization falls back to Android's English string.
     */
    static func localizedRestoreSuccessMessage(for report: AndroidModuleBackupRestoreReport) -> String {
        _ = report
        return localizedInstallSuccessMessage
    }
}
