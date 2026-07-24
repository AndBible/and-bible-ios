// ImportExportView.swift -- Android-aligned Backup & Restore settings screen

import SwiftUI
import SwiftData
import BibleCore
import SwordKit
import UniformTypeIdentifiers

/**
 Streams a provider-owned Android module backup into an app-owned staging file.

 The copier keeps memory bounded, checks cooperative cancellation before every read and write, and
 removes partial output before returning an error. Callers remain responsible for security-scoped
 access and for choosing a unique destination.
 */
enum AndroidModuleBackupArchiveFileStager {
    /**
     Copies one archive without loading it into memory.

     - Parameters:
       - sourceURL: Readable provider or local archive URL.
       - destinationURL: Unique app-owned staging destination.
       - didWriteChunk: Optional synchronous observer invoked after each completed chunk write.
     - Side effects: Creates or replaces `destinationURL`, writes the source bytes to it, and invokes
       `didWriteChunk` on the copy task when supplied.
     - Failure modes: Rethrows cancellation and file-system failures after removing partial output.
     */
    static func copy(
        from sourceURL: URL,
        to destinationURL: URL,
        didWriteChunk: (@Sendable (_ byteCount: Int) -> Void)? = nil
    ) throws {
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        do {
            try Data().write(to: destinationURL, options: .atomic)
            let output = try FileHandle(forWritingTo: destinationURL)
            defer { try? output.close() }
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: 64 * 1_024) ?? Data()
                if chunk.isEmpty { break }
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
                didWriteChunk?(chunk.count)
            }
            try Task.checkCancellation()
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }
}

/**
 Local SWORD document waiting for explicit overwrite consent in Backup & Restore.

 The selected request and read-only inspection are retained only for alert presentation. The
 repository repeats conflict and layout validation before publishing any files.
 */
private struct ImportExportLocalModuleOverwriteConfirmation: Identifiable {
    /// Selected file and provider metadata.
    let request: ExternalDocumentImportRequest

    /// Validated archive summary with exact existing destinations.
    let inspection: LocalSwordZipInspection

    /// Stable identity for SwiftUI alert presentation.
    var id: String { request.url.standardizedFileURL.path }
}

/**
 Android-aligned Backup & Restore settings screen.

 The user-facing workflow follows Android's `BackupActivity` where the capability is implementable
 on iOS: users first choose Database or Documents for backup, choose Database or Documents for
 Restore or Import, and use the reset controls from the same screen. Android's Application/APK row
 is omitted because iOS apps cannot export their installed bundle as an APK/IPA equivalent at
 runtime. iOS keeps platform-specific plumbing behind those choices: Files export and share sheets
 replace Android intents, SwiftData restore engines replace raw Android database-file swaps, and
 document/module importers replace Android's `InstallZip` activity.

 Data dependencies:
- `modelContext` provides the SwiftData container used by Android-compatible database backup
  import/export operations

 Side effects:
 - backup actions generate Android-compatible archives and then present Files export or share UI
 - restore/import actions read user-selected files through `fileImporter` and mutate app data
   through backup/import/install services
 - reset actions mutate category data through `AndroidBackupResetService`
 - feedback alerts report success, failure, and guidance after operations complete
 */
public struct ImportExportView: View {
    /// SwiftData context used by backup import/export services.
    @Environment(\.modelContext) private var modelContext

    /// Fallback navigation dismissal for standalone callers outside the reader destination owner.
    @Environment(\.dismiss) private var dismiss

    /// Reader/workspace palette shared with other app-owned Android activity surfaces.
    private let surfacePalette: ReaderThemeSurfacePalette

    /// Optional reader-owned destination dismissal that avoids relying on native navigation chrome.
    private let onDismiss: (() -> Void)?

    /// Controls presentation of the share sheet after a successful export.
    @State private var showExportSheet = false

    /// Persisted Android-style backup radio selection.
    @AppStorage("backup_workflow_backup_target") private var backupTargetRawValue = BackupWorkflowTarget.database.rawValue

    /// Persisted Android-style restore/import radio selection.
    @AppStorage("backup_workflow_restore_target") private var restoreTargetRawValue = RestoreWorkflowTarget.database.rawValue

    /// Controls Android's backup destination choice dialog.
    @State private var showBackupDestinationDialog = false

    /// Prepared archive waiting for the user's Files/Share destination choice.
    @State private var pendingBackupExport: BackupExportPayload?

    /// File document used by SwiftUI's Files exporter.
    @State private var backupExportDocument = BackupExportDocument()

    /// Default file name used by SwiftUI's Files exporter.
    @State private var backupExportFileName = AndroidDatabaseBackupService.databaseBackupFileName

    /// Controls presentation of the Files exporter for "Phone storage".
    @State private var showBackupFileExporter = false

    /// Controls presentation of the shared restore/import file picker.
    @State private var showRestoreImportPicker = false

    /// Startup setup target that should open its picker as soon as this route appears.
    private let startupRestoreImportTarget: RestoreWorkflowTarget?

    /// Reader-owned runtime that must observe restored Android speech preferences immediately.
    private let speakService: SpeakService?

    /// Prevents a startup-triggered restore/import picker from reopening after dismissal.
    @State private var didPresentStartupRestoreImportPicker = false

    /// Restore/import target whose content types and result handler are active for the file picker.
    @State private var restoreImportPickerTarget: RestoreWorkflowTarget?

    /// URL of the most recently exported file shared through the share sheet.
    @State private var exportedFileURL: URL?

    /// Pending user-visible success, failure, or guidance message for the feedback alert.
    @State private var statusMessage: String?

    /// Pending Android-style transient install-success toast for document/module restores.
    @State private var transientStatusMessage: String?

    /// Scheduled dismissal for the current Android-style transient status toast.
    @State private var transientStatusWorkItem: DispatchWorkItem?

    /// Controls presentation of the Android-style operation feedback alert.
    @State private var showStatusAlert = false

    /// Completion message to show only after the iOS share sheet reports a completed destination.
    @State private var pendingShareCompletionMessage: String?

    /// Whether Android-compatible database backup export is currently preparing an archive.
    @State private var isExportingAndroidDatabaseBackup = false

    /// Whether any export action is currently in progress.
    private var isExporting: Bool {
        isExportingAndroidDatabaseBackup
    }

    /// Whether a backup import is currently in progress.
    @State private var isImporting = false

    /// Whether a ZIP, EPUB, or TTF document installation is currently in progress.
    @State private var isInstallingDocument = false

    /// Durable local SWORD install phase shown while document installation is active.
    @State private var documentInstallProgress: ModuleInstallProgress?

    /// Ordinary SWORD ZIP waiting for explicit replacement consent.
    @State private var pendingLocalModuleOverwrite: ImportExportLocalModuleOverwriteConfirmation?

    /// Whether an Android module backup restore is currently in progress.
    @State private var isRestoringAndroidModuleBackup = false

    /// Whether an Android module backup export is currently in progress.
    @State private var isExportingAndroidModuleBackup = false

    /// Controls presentation of Android module backup export module selection.
    @State private var showAndroidModuleBackupExportSheet = false

    /// Canonical all-family rows shown in the Android module backup export selection sheet.
    @State private var androidModuleBackupExportModules: [AndroidModuleBackupInstalledContent] = []

    /// Retained discovery/export task so cancel and view teardown stop archive work cooperatively.
    @State private var androidModuleBackupExportTask: Task<Void, Never>?

    /// Identity of the export task currently permitted to finish the shared UI operation state.
    @State private var androidModuleBackupExportOperationID: UUID?

    /// Retained inspection/restore task so view teardown stops pre-commit archive work.
    @State private var androidModuleBackupRestoreTask: Task<Void, Never>?

    /// Identity of the restore task currently permitted to finish the shared UI operation state.
    @State private var androidModuleBackupRestoreOperationID: UUID?

    /// Temporary Android module backup archive retained while overwrite confirmation is visible.
    @State private var pendingAndroidModuleBackupURL: URL?

    /// Archive-bound consent waiting for the Android module backup confirmation action.
    @State private var pendingAndroidModuleBackupAuthorization: LocalSwordZipOverwriteAuthorization?

    /// Controls the Android module backup overwrite confirmation prompt.
    @State private var showAndroidModuleBackupOverwriteAlert = false

    /// Android database backup archive currently staged for category selection.
    @State private var androidBackupArchive: AndroidDatabaseBackupArchive?

    /// Last archive presented by the sheet, retained until dismissal cleanup runs.
    @State private var androidBackupArchivePendingCleanup: AndroidDatabaseBackupArchive?

    /// Whether selected Android backup sections are currently being applied.
    @State private var isApplyingAndroidBackup = false

    /// Reset category waiting for Android-style destructive confirmation.
    @State private var pendingResetCategory: AndroidBackupResetCategory?

    /// Whether an Android BackupActivity reset category is currently mutating local stores.
    @State private var isResettingBackupCategory = false

    /// Service used to export, load, apply, and clean up Android `.abdb.zip` database backups.
    private let androidBackupService = AndroidDatabaseBackupService()

    /// Service used to reset Android BackupActivity categories through iOS storage engines.
    private let androidResetService = AndroidBackupResetService()

    /**
     Lightweight sentinel for file read failures that should preserve the existing generic copy.

     The background database-backup loader uses this instead of passing through Foundation's
     low-level file errors so the user still sees the established `error_read_file` message for
     unreadable picker selections.
     */
    private enum ImportExportFileReadError: Error {
        /// Selected file bytes could not be loaded from disk.
        case unreadable
    }

    /**
     Creates the import/export screen.

     - Parameter speakService: Optional live speech runtime to refresh after settings restore.
     - Side effects: none; the service is used only after a successful restore selection.
     - Failure modes: Omitting the service preserves standalone settings previews and tests.
     */
    public init(speakService: SpeakService? = nil) {
        self.startupRestoreImportTarget = nil
        self.speakService = speakService
        self.surfacePalette = .standard
        self.onDismiss = nil
    }

    /**
     Creates the import/export screen for a startup setup action.

     Android's startup Restore Database and Load Documents From Files buttons open their target
     pickers directly instead of first showing BackupActivity's generic landing screen. This
     initializer preserves that entry-point intent while reusing the same picker handlers as the
     normal Backup & Restore screen.

     - Parameters:
       - startupRestoreImportTarget: Optional restore/import target to present once after the route
         appears.
       - speakService: Optional live speech runtime to refresh after settings restore.
     - Side effects: none; restore behavior starts only after user selection.
     - Failure modes: Omitting the service preserves startup routing without live speech state.
     */
    init(
        startupRestoreImportTarget: RestoreWorkflowTarget?,
        speakService: SpeakService? = nil,
        surfacePalette: ReaderThemeSurfacePalette = .standard,
        onDismiss: (() -> Void)? = nil
    ) {
        self.startupRestoreImportTarget = startupRestoreImportTarget
        self.speakService = speakService
        self.surfacePalette = surfacePalette
        self.onDismiss = onDismiss
    }

    /**
     Current presentation snapshot for UI automation and picker routing.

     The value encodes which modal surface the screen is actively driving and which restore/import
     target owns the shared file picker. It has no side effects; SwiftUI state mutation remains in
     the view event handlers.
     */
    private var presentationState: ImportExportPresentationState {
        ImportExportPresentationState(
            backupDestinationPresented: showBackupDestinationDialog,
            backupFileExporterPresented: showBackupFileExporter,
            shareSheetPresented: showExportSheet,
            restoreImportPickerPresented: showRestoreImportPicker,
            restoreImportPickerTarget: restoreImportPickerTarget,
            restoreTarget: restoreTarget.wrappedValue,
            androidModuleBackupExportPresented: showAndroidModuleBackupExportSheet,
            androidBackupImportPresented: androidBackupArchive != nil,
            resetInProgress: isResettingBackupCategory,
            backupPayloadPending: pendingBackupExport != nil
        )
    }

    /**
     Current accessibility-visible presentation state for UI automation.

     - Returns: A stable sentinel for the foremost Backup & Restore presentation surface.
     - Side effects: none.
     - Failure modes: none; inactive state returns `idle`.
     */
    private var accessibilityState: String {
        presentationState.accessibilityValue
    }

    /**
     Type-safe binding around the persisted backup target raw value.

     - Side effects: writes `UserDefaults` through `@AppStorage` when the user changes the radio row.
     - Failure modes: Unknown persisted values fall back to Android's Database default.
     */
    private var backupTarget: Binding<BackupWorkflowTarget> {
        Binding(
            get: { BackupWorkflowTarget(rawValue: backupTargetRawValue) ?? .database },
            set: { backupTargetRawValue = $0.rawValue }
        )
    }

    /**
     Type-safe binding around the persisted restore/import target raw value.

     - Side effects: writes `UserDefaults` through `@AppStorage` when the user changes the radio row.
     - Failure modes: Unknown persisted values fall back to Android's Database default.
     */
    private var restoreTarget: Binding<RestoreWorkflowTarget> {
        Binding(
            get: { RestoreWorkflowTarget(rawValue: restoreTargetRawValue) ?? .database },
            set: { restoreTargetRawValue = $0.rawValue }
        )
    }

    /**
     Android reset categories with safe iOS storage equivalents or preserved Android-owned state.

     - Returns: Reset buttons in Android's BackupActivity order.
     - Side effects: none.
     - Failure modes: none.
     */
    private var resetCategories: [AndroidBackupResetCategory] {
        [
            .bookmarks,
            .workspaces,
            .readingPlans,
            .repositories,
            .applicationPreferences,
            .myDocuments,
            .aiSettings,
            .progress,
        ]
    }

    /**
     Whether any backup/archive export operation is active.
     */
    private var isBackingUp: Bool {
        isExporting || isExportingAndroidModuleBackup
    }

    /**
     Whether any restore/import/install operation is active.
     */
    private var isRestoringOrImporting: Bool {
        isImporting || isRestoringAndroidModuleBackup || isInstallingDocument
    }

    /**
     Whether any Backup & Restore operation is reading or mutating shared app storage.

     - Returns: `true` during backup/export, restore/import/install, or reset work.
     - Side effects: none.
     - Failure modes: none.
     */
    private var isBackupWorkflowBusy: Bool {
        isBackingUp || isRestoringOrImporting || isResettingBackupCategory
    }

    /**
     Allowed content types for the currently active restore/import picker.

     Android keeps Database backup archives and Documents/module imports as distinct visible
     restore targets. iOS uses one SwiftUI file importer for reliability, then selects the allowed
     UTTypes from the active target so the platform picker still opens the correct category.

     - Returns: Database archive types for Database, or module/document types for Documents.
     - Side effects: none.
     - Failure modes: Falls back to the persisted restore target if the picker target was cleared by
       the platform before the result callback arrives.
     */
    private var restoreImportPickerContentTypes: [UTType] {
        presentationState.restoreImportPickerContentTypes
    }

    /**
     Builds Android's app-owned BackupActivity and attaches only legitimate external file/share
     handoffs plus app-owned dialogs.

     Side effects: Activity commands mutate parent workflow state; platform presenters activate only
     after explicit Files/share actions.

     Failure modes: Operation failures are retained in `statusMessage` and presented by the shared
     Android decision dialog layer.
     */
    public var body: some View {
        AndroidBackupRestoreActivityView(
            surfacePalette: surfacePalette,
            backupTarget: backupTarget,
            restoreTarget: restoreTarget,
            resetCategories: resetCategories,
            isBackingUp: isBackingUp,
            isRestoringOrImporting: isRestoringOrImporting,
            isWorkflowBusy: isBackupWorkflowBusy,
            documentInstallProgress: isInstallingDocument
                ? documentInstallProgress ?? ModuleInstallProgress(phase: .queued)
                : nil,
            accessibilityValue: accessibilityState,
            onBack: dismissActivity,
            onBackup: beginBackup,
            onRestoreOrImport: beginRestoreOrImport,
            onReset: { pendingResetCategory = $0 }
        )
        .onAppear {
            presentStartupRestoreImportPickerIfNeeded()
        }
        .overlay {
            if showBackupDestinationDialog {
                AndroidDecisionDialog(title: String(localized: "backup_backup_title", defaultValue: "Backup to where?"), message: String(localized: "backup_backup_message_ios", defaultValue: "Backup to phone or elsewhere via Share function (email, iCloud Drive etc.)?"), actions: [
                    .init(id: "phone", title: String(localized: "backup_phone_storage", defaultValue: "Phone storage"), style: .normal) { chooseBackupDestination(.phoneStorage) },
                    .init(id: "share", title: String(localized: "share", defaultValue: "Share"), style: .normal) { chooseBackupDestination(.share) },
                    .init(id: "cancel", title: String(localized: "cancel"), style: .normal, perform: cancelBackupDestinationChoice)
                ], accessibilityIdentifier: "backupDestinationDialog")
            }
        }
        .fileExporter(
            isPresented: $showBackupFileExporter,
            document: backupExportDocument,
            contentType: .zip,
            defaultFilename: backupExportFileName
        ) { result in
            handleBackupFileExport(result)
        }
        .sheet(isPresented: $showExportSheet, onDismiss: handleShareSheetDismiss) {
            if let url = exportedFileURL {
                ShareSheet(items: [url], onCompletion: handleBackupShareCompletion)
            }
        }
        .overlay {
            if let archive = androidBackupArchive {
                AndroidDatabaseBackupImportDialog(
                    archive: archive,
                    isApplying: isApplyingAndroidBackup,
                    onDismiss: dismissAndroidBackupArchive,
                    onApply: applyAndroidBackupSelections
                )
                .onAppear {
                    androidBackupArchivePendingCleanup = archive
                }
            }
        }
        .fileImporter(
            isPresented: $showRestoreImportPicker,
            allowedContentTypes: restoreImportPickerContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleRestoreImportPickerResult(result)
        }
        .overlay {
            if showAndroidModuleBackupExportSheet {
                AndroidModuleBackupExportDialog(
                    isExporting: isExportingAndroidModuleBackup,
                    onCancel: dismissAndroidModuleBackupExportSelection
                ) {
                    AndroidModuleBackupExportSheet(
                        modules: androidModuleBackupExportModules,
                        isExporting: isExportingAndroidModuleBackup,
                        onCancel: dismissAndroidModuleBackupExportSelection,
                        onExport: exportAndroidModuleBackup(moduleNames:)
                    )
                }
            }
        }
        .overlay {
            if let category = pendingResetCategory {
                AndroidDecisionDialog(title: category.localizedBackupResetButtonTitle, message: String(format: String(localized: "reset_database_confirm", defaultValue: "This will permanently delete all data in \"%@\" and reset it to the initial state. This cannot be undone.\n\nAre you sure?"), category.localizedBackupResetTitle), actions: [
                    .init(id: "reset", title: String(localized: "reset", defaultValue: "Reset"), style: .destructive) { pendingResetCategory = nil; resetDatabase(category) },
                    .init(id: "cancel", title: String(localized: "cancel"), style: .normal) { pendingResetCategory = nil }
                ])
            }
        }
        .overlay {
            if let confirmation = pendingLocalModuleOverwrite {
                AndroidDecisionDialog(title: String(localized: "android_module_backup_overwrite_title", defaultValue: "Overwrite existing module files?"), message: ModuleBrowserView.localModuleOverwriteMessage(confirmation.inspection), actions: [
                    .init(id: "cancel", title: String(localized: "cancel"), style: .normal) { pendingLocalModuleOverwrite = nil },
                    .init(id: "overwrite", title: String(localized: "overwrite", defaultValue: "Overwrite"), style: .destructive) { pendingLocalModuleOverwrite = nil; performSupportedDocumentInstall(confirmation.request, overwritePolicy: .replaceExisting(confirmation.inspection.overwriteAuthorization)) }
                ])
            }
        }
        .overlay {
            if showAndroidModuleBackupOverwriteAlert {
                AndroidDecisionDialog(title: String(localized: "android_module_backup_overwrite_title", defaultValue: "Overwrite existing module files?"), message: androidModuleBackupOverwriteMessage(), actions: [
                    .init(id: "cancel", title: String(localized: "cancel"), style: .normal) { clearPendingAndroidModuleBackup() },
                    .init(id: "overwrite", title: String(localized: "overwrite", defaultValue: "Overwrite"), style: .destructive) { restorePendingAndroidModuleBackup() }
                ])
            }
        }
        .androidToastFeedback(transientStatusMessage, bottomPadding: 48)
        .onChange(of: statusMessage) { _, newValue in
            showStatusAlert = newValue != nil
        }
        .overlay {
            if showStatusAlert {
                AndroidDecisionDialog(title: String(localized: "backup_and_restore", defaultValue: "Backup & Restore"), message: statusMessage ?? "", actions: [
                    .init(id: "okay", title: String(localized: "ok"), style: .normal) { statusMessage = nil; showStatusAlert = false }
                ])
            }
        }
        .onDisappear {
            androidModuleBackupExportOperationID = nil
            androidModuleBackupExportTask?.cancel()
            androidModuleBackupExportTask = nil
            isExportingAndroidModuleBackup = false
            androidModuleBackupRestoreOperationID = nil
            androidModuleBackupRestoreTask?.cancel()
            androidModuleBackupRestoreTask = nil
            isRestoringAndroidModuleBackup = false
        }
    }

    /**
     Closes the app-owned BackupActivity through its reader owner or navigation fallback.

     Side effects: Clears the reader destination when supplied; otherwise invokes SwiftUI's route
     dismissal environment.

     Failure modes: none; one and only one dismissal path is invoked.
     */
    private func dismissActivity() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    /**
     Commits one Android backup-destination choice after dismissing the app-owned dialog.

     - Parameter destination: Phone-storage or share handoff selected by the user.
     - Side effects: Clears dialog state and advances the pending archive to its platform boundary.
     - Failure modes: Missing pending payload is handled by `finishPendingBackupExport`.
     */
    private func chooseBackupDestination(_ destination: BackupExportDestination) {
        showBackupDestinationDialog = false
        finishPendingBackupExport(to: destination)
    }

    /** Dismisses Android's destination dialog and removes its pending temporary archive. */
    private func cancelBackupDestinationChoice() {
        showBackupDestinationDialog = false
        cancelPendingBackupExport()
    }

    /**
     Starts the selected Android BackupActivity backup flow.

     Database and Documents prepare Android-compatible archives before presenting Android's
     destination choice. Android's Application/APK target is omitted from iOS because apps cannot
     export their installed bundle as an IPA/APK equivalent at runtime.

     - Side effects: Mutates export/progress/feedback state and may present backup destination or
       module-selection UI.
     - Failure modes: Category-specific export failures are surfaced through the feedback alert.
     */
    private func beginBackup() {
        switch backupTarget.wrappedValue {
        case .database:
            exportAndroidDatabaseBackup()
        case .documents:
            presentAndroidModuleBackupExportSelection()
        }
    }

    /**
     Starts the selected Android BackupActivity Restore or Import flow.

     - Side effects: Presents either the database backup picker or the document/module picker.
     - Failure modes: Picker failures are handled by the selected result handler.
     */
    private func beginRestoreOrImport() {
        restoreImportPickerTarget = restoreTarget.wrappedValue
        showRestoreImportPicker = true
    }

    /**
     Opens the startup-requested restore/import picker once.

     Android startup setup has direct buttons for Database restore and Documents loading. iOS still
     needs this route in the navigation stack to own SwiftUI's file importer, so this method applies
     the startup target and presents the existing shared picker exactly once.

     - Side effects: Updates the persisted restore/import radio target, captures the picker target,
       and presents the file picker.
     - Failure modes: If another backup workflow is already busy, the startup picker is not opened.
     */
    private func presentStartupRestoreImportPickerIfNeeded() {
        guard !didPresentStartupRestoreImportPicker,
              let startupRestoreImportTarget,
              !isBackupWorkflowBusy else {
            return
        }
        didPresentStartupRestoreImportPicker = true
        restoreTargetRawValue = startupRestoreImportTarget.rawValue
        restoreImportPickerTarget = startupRestoreImportTarget
        showRestoreImportPicker = true
    }

    /**
     Routes the shared restore/import picker result to the target-specific workflow.

     SwiftUI presentation modifiers are more reliable when one file importer owns the picker
     lifecycle. This method preserves Android's Database/Documents split by dispatching the selected
     file to the result handler captured when the user tapped Restore or Import.

     - Parameter result: File picker result returned by SwiftUI.
     - Side effects: Clears the transient picker target, then may mutate restore/import state
       through the target-specific handler.
     - Failure modes: Picker and importer failures are forwarded to the selected target handler.
     */
    private func handleRestoreImportPickerResult(_ result: Result<[URL], Error>) {
        let target = restoreImportPickerTarget ?? restoreTarget.wrappedValue
        restoreImportPickerTarget = nil

        switch target {
        case .database:
            handleDatabaseRestoreImport(result)
        case .documents:
            handleDocumentsRestoreImport(result)
        }
    }

    /**
     Exports an Android-compatible database backup and presents Android's destination choice.

     This is the parity backup path: Android expects `AndBibleDatabaseBackup.abdb.zip` containing
     `AndBibleBackupManifest.json` and supported category SQLite databases under `db/`.

     - Side effects:
       - marks the Android database export row as active and clears prior feedback messages
       - schedules archive generation after one main-actor yield so SwiftUI can render the busy
         state before the expensive SQLite/ZIP work starts
       - exports from a background SwiftData context so SQLite and ZIP work do not block the UI actor
       - stores the generated archive file until the user chooses Phone storage or Share
     - Failure modes: Catches backup export and file-write failures and surfaces them as feedback.
     */
    private func exportAndroidDatabaseBackup() {
        isExportingAndroidDatabaseBackup = true
        statusMessage = nil
        let modelContainer = modelContext.container

        Task { @MainActor in
            await Task.yield()
            defer { isExportingAndroidDatabaseBackup = false }

            do {
                let export = try await Task.detached(priority: .userInitiated) {
                    let exportContext = ModelContext(modelContainer)
                    return try AndroidDatabaseBackupService().exportArchiveFile(
                        modelContext: exportContext,
                        settingsStore: SettingsStore(modelContext: exportContext)
                    )
                }.value
                let exportURL = try moveExportFileToShareDirectory(export)
                let categorySummary = export.categories
                    .map(\.localizedBackupSectionName)
                    .joined(separator: ", ")
                presentBackupDestination(
                    BackupExportPayload(
                        temporaryFileURL: exportURL,
                        fileName: export.fileName,
                        statusMessage: String(
                            localized: "android_database_backup_exported_summary",
                            defaultValue: "Exported Android database backup: \(categorySummary)"
                        )
                    )
                )
            } catch {
                statusMessage = localizedErrorMessage(error)
            }
        }
    }

    /**
     Stores a generated backup payload and presents Android's Backup to where? alert choice.

     - Parameter payload: Valid archive content plus default file name and completion status.
     - Side effects: Replaces any previous pending payload, mutates pending export state, and
       presents the destination alert.
     - Failure modes: none; backup generation has already succeeded before this method is called.
     */
    private func presentBackupDestination(_ payload: BackupExportPayload) {
        clearPendingBackupExport()
        pendingBackupExport = payload
        showBackupDestinationDialog = true
    }

    /**
     Completes the pending backup using the selected Android destination.

     - Parameter destination: Phone storage uses Files export; Share opens the share sheet with an
       existing file-backed archive or writes data-backed payloads to a temporary file first.
     - Side effects:
       - mutates exporter or share-sheet presentation state
       - may write a temporary file for data-backed Share payloads
       - queues feedback after the selected destination accepts the payload
     - Failure modes: Missing pending payload is ignored; file-read/write failures are surfaced
       through the feedback alert.
     */
    private func finishPendingBackupExport(to destination: BackupExportDestination) {
        guard let payload = pendingBackupExport else {
            return
        }

        switch destination {
        case .phoneStorage:
            backupExportDocument = payload.fileDocument()
            backupExportFileName = payload.fileName
            showBackupFileExporter = true
        case .share:
            if let url = payload.temporaryFileURL {
                exportedFileURL = url
                showExportSheet = true
                pendingShareCompletionMessage = payload.statusMessage
                return
            }

            do {
                if let url = saveToTempFile(data: try payload.loadData(), fileName: payload.fileName) {
                    exportedFileURL = url
                    pendingShareCompletionMessage = payload.statusMessage
                    clearPendingBackupExport()
                    showExportSheet = true
                }
            } catch {
                clearPendingBackupExport()
                statusMessage = localizedErrorMessage(error)
            }
        }
    }

    /**
     Handles completion of SwiftUI's Files exporter.

     - Parameter result: Export result emitted by the system document picker.
     - Side effects:
       - clears the pending export once the exporter finishes
       - publishes the prepared feedback message only after successful export
       - updates visible feedback state on failure
     - Failure modes: Export errors are formatted with the shared import/export error prefix.
     */
    private func handleBackupFileExport(_ result: Result<URL, Error>) {
        let completionMessage = pendingBackupExport?.statusMessage
        clearPendingBackupExport()

        switch result {
        case .success:
            statusMessage = completionMessage
        case .failure(let error):
            statusMessage = localizedErrorMessage(error)
        }
    }

    /**
     Handles return from the iOS share sheet.

     UIKit reports whether the user completed a share destination, cancelled, or hit an activity
     error. Backup & Restore uses that stronger platform result to preserve Android's visible
     destination workflow without treating a cancelled iOS share sheet as a successful backup.

     - Parameter completion: Platform-neutral result emitted by `ShareSheet`.
     - Side effects:
       - releases the pending temporary export payload after the share controller finishes
       - clears the queued share completion message
       - presents success feedback only when `completion.completed` is true
       - presents error feedback when the platform reports an activity error
     - Failure modes: Share activity errors are surfaced through the shared import/export error
       formatter.
     */
    private func handleBackupShareCompletion(_ completion: ShareSheetCompletion) {
        let completionMessage = pendingShareCompletionMessage
        pendingShareCompletionMessage = nil
        clearPendingBackupExport()

        if let error = completion.error {
            statusMessage = localizedErrorMessage(error)
            return
        }

        if completion.completed, let completionMessage {
            statusMessage = completionMessage
        }
    }

    /**
     Cleans up any share export state left after the share sheet leaves the screen.

     UIKit normally calls `completionWithItemsHandler` for both completion and cancellation. The
     dismissal hook remains a defensive cleanup boundary for platform dismissals that do not provide a
     completion callback, but it intentionally does not publish success feedback because dismissal is
     not proof that a backup destination accepted the archive.

     - Side effects: Clears queued share feedback and releases any still-pending temporary export file.
     - Failure modes: Temporary-file cleanup failures are intentionally ignored by
       `BackupExportPayload`.
     */
    private func handleShareSheetDismiss() {
        pendingShareCompletionMessage = nil
        clearPendingBackupExport()
        exportedFileURL = nil
    }

    /**
     Cancels a prepared backup destination choice without writing or sharing the archive.
     *
     - Side effects: Releases generated archive bytes or temporary files and dismisses any pending
       feedback from the abandoned export.
     - Failure modes: none.
     */
    private func cancelPendingBackupExport() {
        pendingShareCompletionMessage = nil
        clearPendingBackupExport()
    }

    /**
     Releases the prepared backup payload and removes any temporary archive it owns.

     - Side effects: Deletes file-backed temporary exports and clears pending export state.
     - Failure modes: Temporary-file cleanup failures are intentionally ignored by
       `BackupExportPayload`.
     */
    private func clearPendingBackupExport() {
        pendingBackupExport?.cleanupTemporaryFile()
        pendingBackupExport = nil
    }

    /**
     Handles Android database backup restore/import file selection.

     Android's Database restore path accepts `.abdb.zip` manual backup archives and then asks the
     user which sections to Restore or Import. iOS mirrors that contract by rejecting document,
     module, and legacy files from this target instead of routing every format through one generic
     importer.

     - Parameter result: File picker result for the Database Restore or Import target.
     - Side effects:
       - validates the selected filename before scheduling background file read and archive staging
       - keeps import controls disabled until background validation and staging finish
       - presents feedback on invalid selection or read failure
     - Failure modes: Picker, read, and archive validation failures are surfaced through
       the feedback alert.
     */
    private func handleDatabaseRestoreImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            statusMessage = nil

            guard isAndroidDatabaseBackupFile(url) else {
                statusMessage = String(
                    localized: "android_database_backup_required",
                    defaultValue: "Select an Android database backup file (.abdb.zip)."
                )
                isImporting = false
                return
            }

            loadAndroidBackupArchive(from: url)

        case .failure(let error):
            statusMessage = localizedErrorMessage(error)
        }
    }

    /**
     Handles Android Documents restore/import file selection.

     Android routes document restore/import through its document loader. iOS maps that visible target
     to the existing native importers for Android module backups, SWORD module ZIPs, and EPUB
     documents while keeping those formats out of the top-level backup UI.

     - Parameter result: File picker result for the Documents Restore or Import target.
     - Side effects:
       - reads Android module backup archives when selected
       - installs SWORD ZIP modules or EPUB files through their existing native services
       - presents feedback with success, failure, or guidance messages
     - Failure modes: Unsupported document formats and importer errors are surfaced through
       the feedback alert.
     */
    private func handleDocumentsRestoreImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            statusMessage = nil

            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            let ext = url.pathExtension.lowercased()
            if isAndroidDatabaseBackupFile(url) {
                statusMessage = String(
                    localized: "android_database_backup_wrong_restore_target",
                    defaultValue: "Android database backups must be restored or imported from the Database target."
                )
                return
            }
            if AndroidModuleBackupService.isAndroidModuleBackupFileName(url.lastPathComponent) {
                isRestoringAndroidModuleBackup = true
                prepareAndroidModuleBackupRestore(from: url)
                return
            }

            switch ext {
            case "zip", "epub", "ttf":
                installSupportedDocument(from: url)
            case "bbl", "cmt", "dct", "mybible", "sqlite3", "bbli", "bblx":
                statusMessage = String(localized: "mysword_file_hint")
            default:
                statusMessage = unsupportedFormatMessage(forExtension: ext)
            }

        case .failure(let error):
            statusMessage = localizedErrorMessage(error)
        }
    }

    /**
     Determines whether a selected import file should be handled as an Android database backup.

     Android names manual database backups with the compound `.abdb.zip` suffix. The generic
     import picker no longer treats arbitrary ZIP files as database backups because Android module
     backups use the sibling `.abmd.zip` suffix and ordinary SWORD ZIP packages are handled by the
     module installer.

     - Parameter url: User-selected file URL.
     - Returns: `true` when the filename has Android's database-backup suffix.
     - Side effects: none.
     - Failure modes: Invalid ZIP contents are rejected later by the backup service.
     */
    private func isAndroidDatabaseBackupFile(_ url: URL) -> Bool {
        let fileName = url.lastPathComponent.lowercased()
        return fileName.hasSuffix(AndroidDatabaseBackupService.databaseBackupSuffix)
    }

    /**
     Formats the existing localized unsupported-format message.

     - Parameter fileExtension: Extension from the selected file URL.
     - Returns: Localized unsupported-format message with the extension interpolated.
     - Side effects: none.
     - Failure modes: Empty extensions are reported with an empty format placeholder, matching the
       existing generic unsupported-file contract.
     */
    private func unsupportedFormatMessage(forExtension fileExtension: String) -> String {
        String(
            format: String(
                localized: "error_unsupported_format_%@",
                defaultValue: "Error: Unsupported file format (%@)"
            ),
            fileExtension
        )
    }

    /**
     Loads a raw Android database backup archive and presents the section-selection sheet.

     The picker handler validates the Android backup filename and sets `isImporting` before calling
     this method. This method then owns the rest of the lifecycle: it yields once so SwiftUI can
     render disabled controls, reads and validates the archive off the main actor, and clears
     `isImporting` only after success or failure is published.

     - Parameter url: Security-scoped URL selected from the Android Database restore/import picker.
     - Side effects:
       - clears any previously staged Android backup archive
       - reads the selected file through security-scoped access in a detached task
       - writes validated Android SQLite files into a temporary staging directory off the main actor
       - updates `androidBackupArchive` so SwiftUI presents the selection sheet
       - clears `isImporting` after background work finishes
       - presents feedback when validation fails
     - Failure modes: Surfaces unreadable files with the existing generic read error, and surfaces
       `AndroidDatabaseBackupError` plus ZIP/file-system errors as feedback.
     */
    private func loadAndroidBackupArchive(from url: URL) {
        cleanupLoadedAndroidBackupArchive()

        Task { @MainActor in
            await Task.yield()
            defer {
                isImporting = false
            }

            do {
                let archive = try await Task.detached(priority: .userInitiated) {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    return try AndroidDatabaseBackupService().loadArchive(fromArchiveAt: url)
                }.value
                androidBackupArchive = archive
                androidBackupArchivePendingCleanup = archive
            } catch ImportExportFileReadError.unreadable {
                statusMessage = String(localized: "error_read_file")
            } catch {
                statusMessage = localizedErrorMessage(error)
            }
        }
    }

    /**
     Applies selected Android backup sections and reports the completed category summaries.

     This method flips the applying state synchronously, then schedules the restore/import work on
     the main actor after one yield so SwiftUI can render the disabled controls and progress state
     before the potentially expensive SwiftData rewrite starts.

     - Parameter selections: Supported category/mode pairs emitted by the selection sheet.
     - Side effects:
       - mutates `isApplyingAndroidBackup` immediately so the sheet disables controls and
         interactive dismissal
       - mutates selected local SwiftData categories through `AndroidDatabaseBackupService`
       - disables and clears remote-sync state for every applied Android-backed category
       - removes the staged archive directory after success or failure
       - presents feedback with the apply result or error after the sheet dismisses
     - Failure modes: Catches service errors and surfaces them to the settings screen.
     */
    private func applyAndroidBackupSelections(_ selections: [AndroidDatabaseBackupSelection]) {
        guard let archive = androidBackupArchive else {
            return
        }

        isApplyingAndroidBackup = true
        statusMessage = nil
        Task { @MainActor in
            await Task.yield()
            let feedbackMessage: String
            do {
                let settingsStore = SettingsStore(modelContext: modelContext)
                let report = try androidBackupService.apply(
                    archive: archive,
                    selections: selections,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
                reloadSpeechRuntimeAfterBackupIfNeeded(
                    selections: selections,
                    settingsStore: settingsStore
                )
                feedbackMessage = androidBackupStatusMessage(for: report)
            } catch {
                feedbackMessage = localizedErrorMessage(error)
            }
            isApplyingAndroidBackup = false
            dismissAndroidBackupArchive()
            await Task.yield()
            statusMessage = feedbackMessage
        }
    }

    /**
     Applies restored Android settings to the live speech runtime before reporting success.

     - Parameters:
       - selections: Successfully applied backup sections.
       - settingsStore: Store containing the restored Android preference values.
     - Side effects: Rebinds and reloads `SpeakService` when settings or workspaces were restored.
     - Failure modes: Missing services, active workspace identifiers, or workspace rows fall back to
       global restored settings without failing the completed backup operation.
     */
    private func reloadSpeechRuntimeAfterBackupIfNeeded(
        selections: [AndroidDatabaseBackupSelection],
        settingsStore: SettingsStore
    ) {
        AndroidBackupSpeechRuntimeReloader.reloadIfNeeded(
            selections: selections,
            settingsStore: settingsStore,
            activeWorkspaceSettings: settingsStore.activeWorkspaceId.flatMap {
                WorkspaceStore(modelContext: modelContext)
                    .workspace(id: $0)?
                    .workspaceSettings?
                    .speakSettings
            },
            speakService: speakService
        )
    }

    /**
     Builds the user-visible completion summary for an Android backup apply report.

     - Parameter report: Service report containing one row per applied section.
     - Returns: Concise status message listing category, mode, and row summary.
     - Side effects: none.
     - Failure modes: Empty reports return a generic success message, though the sheet normally
       prevents empty selections.
     */
    private func androidBackupStatusMessage(for report: AndroidDatabaseBackupApplyReport) -> String {
        guard !report.sections.isEmpty else {
            return String(localized: "android_backup_applied", defaultValue: "Android backup applied.")
        }
        let summaries = report.sections.map { section in
            "\(section.mode.localizedBackupModeName) \(section.category.localizedBackupSectionName): \(section.summary)"
        }
        return String(
            localized: "android_backup_applied_summary",
            defaultValue: "Android backup applied: \(summaries.joined(separator: "; "))"
        )
    }

    /**
     Formats an import/export error with the localized shared error prefix.

     `String(localized:)` interpolation is easy to misuse for this shared `%@` key. This helper
     resolves the stable `error_prefix_%@` format first, then applies the concrete error message as
     an argument so every import/export error path uses the same localized surface.

     - Parameter error: Error whose localized description should be shown to the user.
     - Returns: Localized feedback text containing the shared error prefix and error message.
     - Side effects: none.
     - Failure modes: Falls back to the key's untranslated format if the app bundle lacks a
       localization entry.
     */
    private func localizedErrorMessage(_ error: Error) -> String {
        String(
            format: NSLocalizedString("error_prefix_%@", comment: "Import/export error prefix"),
            error.localizedDescription
        )
    }

    /**
     Dismisses the Android backup sheet and removes its temporary extracted files.

     Side effects:
     - deletes the staged archive directory on a best-effort basis
     - clears `androidBackupArchive`
     - clears the dismissal cleanup fallback once the archive has been removed
     - Failure modes: Cleanup errors are swallowed by the service because the files are temporary.
     */
    private func dismissAndroidBackupArchive() {
        guard let archive = androidBackupArchive else {
            androidBackupArchivePendingCleanup = nil
            return
        }
        cleanupAndroidBackupArchive(archive)
        androidBackupArchive = nil
        androidBackupArchivePendingCleanup = nil
    }

    /**
     Removes the currently staged Android backup archive without changing user data.

     Side effects:
     - deletes the temporary extracted database directory, if present
     - clears `androidBackupArchive`
     - clears the dismissal cleanup fallback
     - Failure modes: Cleanup errors are swallowed by the service because the files are temporary.
     */
    private func cleanupLoadedAndroidBackupArchive() {
        guard let archive = androidBackupArchive else {
            androidBackupArchivePendingCleanup = nil
            return
        }
        cleanupAndroidBackupArchive(archive)
        androidBackupArchive = nil
        androidBackupArchivePendingCleanup = nil
    }

    /**
     Cleans up the presented Android backup after SwiftUI dismisses the sheet.

     SwiftUI may clear an item-backed sheet binding before `onDismiss` runs. The pending-cleanup
     copy preserves the staging directory owner until this dismissal callback removes it.

     Side effects:
     - deletes the temporary extracted database directory, if present
     - clears the active archive binding and fallback cleanup copy
     - Failure modes: Cleanup errors are swallowed by the service because the files are temporary.
     */
    private func cleanupDismissedAndroidBackupArchive() {
        let archive = androidBackupArchive ?? androidBackupArchivePendingCleanup
        if let archive {
            cleanupAndroidBackupArchive(archive)
        }
        androidBackupArchive = nil
        androidBackupArchivePendingCleanup = nil
    }

    /**
     Removes one staged Android backup archive without mutating presentation state.

     - Parameter archive: Loaded archive whose temporary directory should be deleted.
     - Side effects: Deletes the archive staging directory on a best-effort basis.
     - Failure modes: Cleanup errors are swallowed by the service because the files are temporary.
     */
    private func cleanupAndroidBackupArchive(_ archive: AndroidDatabaseBackupArchive) {
        androidBackupService.cleanup(archive)
    }

    /**
     Installs one externally supplied document through the shared document import service without
     blocking the Settings UI.

     Settings and app-scene document opens both call `ExternalDocumentImportService` so Android's
     ZIP/EPUB/TTF document-install contract stays centralized instead of drifting between entry
     points. The file I/O and archive work run off the main actor so the install progress state can
     render before import work starts.

     - Parameter url: Security-scoped URL for a user-selected ZIP, EPUB, or TTF file.
     - Side effects: Mutates install progress state on the main actor, imports module, EPUB, or TTF
       files into local app storage from a detached task, presents Android install successes as
       transient toast feedback, and presents unsupported/error feedback as an alert.
     - Failure modes: Unsupported formats and installer errors are surfaced as feedback.
     */
    private func installSupportedDocument(from url: URL) {
        isInstallingDocument = true
        documentInstallProgress = ModuleInstallProgress(phase: .queued)
        statusMessage = nil
        let request = ExternalDocumentImportRequest(
            url: url,
            contentTypeIdentifier: try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier,
            suggestedFileName: url.lastPathComponent
        )
        let service = ExternalDocumentImportService()
        Task { @MainActor in
            let preflight = await Task.detached(priority: .userInitiated) {
                service.preflightDocument(request)
            }.value
            switch preflight {
            case .ready:
                performSupportedDocumentInstall(request, overwritePolicy: .reject)
            case .moduleOverwriteRequired(let inspection):
                isInstallingDocument = false
                documentInstallProgress = nil
                pendingLocalModuleOverwrite = ImportExportLocalModuleOverwriteConfirmation(
                    request: request,
                    inspection: inspection
                )
            case .failed(let message):
                isInstallingDocument = false
                documentInstallProgress = nil
                statusMessage = ExternalDocumentImportResult.failed(message: message).feedbackMessage
            }
        }
    }

    /**
     Installs one preflighted external document without blocking the Settings UI.

     - Parameters:
       - request: Selected ZIP, EPUB, or TTF request.
       - overwritePolicy: Explicit SWORD conflict policy; replacement is used only after consent.
     - Side effects: Runs installer I/O off the main actor, publishes durable SWORD phases, then
       presents Android toast or error feedback.
     - Failure modes: Installer failures are returned as structured feedback and leave the view
       available for retry.
     */
    private func performSupportedDocumentInstall(
        _ request: ExternalDocumentImportRequest,
        overwritePolicy: LocalSwordZipOverwritePolicy
    ) {
        isInstallingDocument = true
        documentInstallProgress = ModuleInstallProgress(phase: .queued)
        statusMessage = nil
        let service = ExternalDocumentImportService()
        Task { @MainActor in
            await Task.yield()
            let result = await Task.detached(priority: .userInitiated) {
                service.importDocument(
                    request,
                    moduleOverwritePolicy: overwritePolicy,
                    progressState: { progress in
                        Task { @MainActor in
                            documentInstallProgress = progress
                        }
                    }
                )
            }.value
            isInstallingDocument = false
            documentInstallProgress = nil
            if result.usesAndroidInstallToastFeedback {
                showTransientStatusMessage(result.feedbackMessage)
            } else {
                statusMessage = result.feedbackMessage
            }
        }
    }

    /**
     Presents every installed family accepted by Android-compatible backup export.

     Android asks the user which installed documents/modules to include before writing
     `AndBibleModulesBackup.abmd.zip`. iOS reads the exporter's canonical installed-content catalog,
     then applies Android's stable language ordering before presenting the multiselect sheet.

     Side effects:
     - discovers and validates all exportable families off the main actor
     - updates `androidModuleBackupExportModules`
     - presents the export selection sheet or surfaces a no-modules error
     */
    private func presentAndroidModuleBackupExportSelection() {
        statusMessage = nil
        androidModuleBackupExportTask?.cancel()
        let operationID = UUID()
        androidModuleBackupExportOperationID = operationID
        isExportingAndroidModuleBackup = true
        androidModuleBackupExportTask = Task { @MainActor in
            defer {
                if androidModuleBackupExportOperationID == operationID {
                    isExportingAndroidModuleBackup = false
                    androidModuleBackupExportTask = nil
                    androidModuleBackupExportOperationID = nil
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try AndroidModuleBackupService().installedContentCatalog()
                }
                let discovered = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                guard androidModuleBackupExportOperationID == operationID else { return }
                let modules = discovered.enumerated().sorted { lhs, rhs in
                    let order = lhs.element.language.localizedCaseInsensitiveCompare(
                        rhs.element.language
                    )
                    return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
                }.map(\.element)
                guard !modules.isEmpty else {
                    throw AndroidModuleBackupError.noExportableModules
                }
                androidModuleBackupExportModules = modules
                showAndroidModuleBackupExportSheet = true
            } catch is CancellationError {
                return
            } catch {
                if androidModuleBackupExportOperationID == operationID {
                    statusMessage = localizedErrorMessage(error)
                }
            }
        }
    }

    /**
     Dismisses Android module backup export selection without writing files.

     Side effects:
     - clears export selection state
     - dismisses the export selection sheet
     */
    private func dismissAndroidModuleBackupExportSelection() {
        androidModuleBackupExportOperationID = nil
        androidModuleBackupExportTask?.cancel()
        androidModuleBackupExportTask = nil
        showAndroidModuleBackupExportSheet = false
        androidModuleBackupExportModules = []
        isExportingAndroidModuleBackup = false
    }

    /**
     Exports selected installed content as Android's `.abmd.zip` module backup archive.

     - Parameter moduleNames: Selected module initials emitted by the export selection sheet.
     - Side effects:
       - marks the module export as active before scheduling work so SwiftUI can disable the sheet
       - discovers, pins, compresses, and verifies selected family files off the main actor
       - dismisses the selection sheet and schedules Android's backup destination choice after
         SwiftUI processes dismissal, avoiding two active sheet presentations at once
       - presents feedback with export failure details after dismissing the selection sheet
     */
    private func exportAndroidModuleBackup(moduleNames: [String]) {
        guard !moduleNames.isEmpty else {
            statusMessage = localizedErrorMessage(AndroidModuleBackupError.noExportableModules)
            return
        }
        isExportingAndroidModuleBackup = true
        statusMessage = nil

        androidModuleBackupExportTask?.cancel()
        let operationID = UUID()
        androidModuleBackupExportOperationID = operationID
        androidModuleBackupExportTask = Task { @MainActor in
            await Task.yield()
            var generatedArchiveURL: URL?
            defer {
                if let generatedArchiveURL {
                    try? FileManager.default.removeItem(at: generatedArchiveURL)
                }
                if androidModuleBackupExportOperationID == operationID {
                    isExportingAndroidModuleBackup = false
                    androidModuleBackupExportTask = nil
                    androidModuleBackupExportOperationID = nil
                }
            }

            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try AndroidModuleBackupService().exportArchiveFile(
                        orderedModuleNames: moduleNames
                    )
                }
                let export = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                generatedArchiveURL = export.fileURL
                try Task.checkCancellation()
                guard androidModuleBackupExportOperationID == operationID else { return }
                showAndroidModuleBackupExportSheet = false
                androidModuleBackupExportModules = []
                await Task.yield()
                try Task.checkCancellation()
                guard androidModuleBackupExportOperationID == operationID else { return }
                let exportURL = try moveExportFileToShareDirectory(
                    fileURL: export.fileURL,
                    fileName: export.fileName
                )
                generatedArchiveURL = nil
                let payload = BackupExportPayload(
                    temporaryFileURL: exportURL,
                    fileName: export.fileName,
                    statusMessage: String(
                        localized: "android_module_backup_exported_summary",
                        defaultValue: "Exported Android module backup: \(export.moduleNames.joined(separator: ", "))"
                    )
                )
                presentBackupDestination(payload)
            } catch is CancellationError {
                return
            } catch {
                if androidModuleBackupExportOperationID == operationID {
                    showAndroidModuleBackupExportSheet = false
                    androidModuleBackupExportModules = []
                    await Task.yield()
                    statusMessage = localizedErrorMessage(error)
                }
            }
        }
    }

    /**
     Inspects an Android module backup and either restores it or queues overwrite confirmation.

     - Parameter url: User-selected `.abmd.zip` archive URL.
     - Side effects:
     - copies the selected security-scoped file to a temporary archive
     - may write supported module files when no overwrite confirmation is required
     - may retain the temporary archive URL and existing paths for a later confirmation action
     - presents Android install success through a transient toast
     - Failure modes: Catches service errors and surfaces them to the settings screen.
     */
    private func prepareAndroidModuleBackupRestore(from url: URL) {
        androidModuleBackupRestoreTask?.cancel()
        let operationID = UUID()
        androidModuleBackupRestoreOperationID = operationID
        androidModuleBackupRestoreTask = Task { @MainActor in
            await Task.yield()
            var temporaryArchiveURL: URL?
            defer {
                if androidModuleBackupRestoreOperationID == operationID {
                    androidModuleBackupRestoreTask = nil
                    androidModuleBackupRestoreOperationID = nil
                }
            }
            do {
                let inspectionWorker = Task.detached(priority: .userInitiated) {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    let archiveURL = try Self.copyAndroidModuleBackupArchiveToTemporaryFile(from: url)
                    do {
                        let inspection = try AndroidModuleBackupService().inspectArchive(fromArchiveAt: archiveURL)
                        return (archiveURL, inspection)
                    } catch {
                        try? FileManager.default.removeItem(at: archiveURL)
                        throw error
                    }
                }
                let prepared = try await withTaskCancellationHandler {
                    try await inspectionWorker.value
                } onCancel: {
                    inspectionWorker.cancel()
                }
                temporaryArchiveURL = prepared.0
                try Task.checkCancellation()
                guard androidModuleBackupRestoreOperationID == operationID else {
                    throw CancellationError()
                }

                guard prepared.1.existingEntryPaths.isEmpty else {
                    pendingAndroidModuleBackupURL = prepared.0
                    pendingAndroidModuleBackupAuthorization = prepared.1.overwriteAuthorization
                    showAndroidModuleBackupOverwriteAlert = true
                    isRestoringAndroidModuleBackup = false
                    temporaryArchiveURL = nil
                    return
                }

                let restoreWorker = Task.detached(priority: .userInitiated) {
                    try AndroidModuleBackupService().restoreArchive(
                        fromArchiveAt: prepared.0,
                        overwritePolicy: .reject
                    )
                }
                let report = try await withTaskCancellationHandler {
                    try await restoreWorker.value
                } onCancel: {
                    restoreWorker.cancel()
                }
                try Task.checkCancellation()
                guard androidModuleBackupRestoreOperationID == operationID else {
                    throw CancellationError()
                }
                showTransientStatusMessage(androidModuleBackupRestoreStatusMessage(for: report))
                isRestoringAndroidModuleBackup = false
                try? FileManager.default.removeItem(at: prepared.0)
                temporaryArchiveURL = nil
            } catch is CancellationError {
                if let temporaryArchiveURL {
                    try? FileManager.default.removeItem(at: temporaryArchiveURL)
                }
                if androidModuleBackupRestoreOperationID == operationID {
                    isRestoringAndroidModuleBackup = false
                }
            } catch {
                if let temporaryArchiveURL {
                    try? FileManager.default.removeItem(at: temporaryArchiveURL)
                }
                if androidModuleBackupRestoreOperationID == operationID {
                    statusMessage = localizedErrorMessage(error)
                    isRestoringAndroidModuleBackup = false
                }
            }
        }
    }

    /**
     Restores the pending Android module backup after the user confirms overwriting files.

     Side effects:
     - writes supported SWORD module files into the local module directory
     - clears pending confirmation state
     - presents Android install success through a transient toast after the overwrite alert closes
     - surfaces service errors through the feedback alert
     */
    private func restorePendingAndroidModuleBackup() {
        guard let archiveURL = pendingAndroidModuleBackupURL,
              let authorization = pendingAndroidModuleBackupAuthorization else {
            clearPendingAndroidModuleBackup()
            return
        }
        pendingAndroidModuleBackupURL = nil
        pendingAndroidModuleBackupAuthorization = nil
        showAndroidModuleBackupOverwriteAlert = false
        isRestoringAndroidModuleBackup = true

        androidModuleBackupRestoreTask?.cancel()
        let operationID = UUID()
        androidModuleBackupRestoreOperationID = operationID
        androidModuleBackupRestoreTask = Task { @MainActor in
            await Task.yield()
            defer {
                try? FileManager.default.removeItem(at: archiveURL)
                if androidModuleBackupRestoreOperationID == operationID {
                    isRestoringAndroidModuleBackup = false
                    androidModuleBackupRestoreTask = nil
                    androidModuleBackupRestoreOperationID = nil
                }
            }
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try AndroidModuleBackupService().restoreArchive(
                        fromArchiveAt: archiveURL,
                        overwritePolicy: .replaceExisting(authorization)
                    )
                }
                let report = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                try Task.checkCancellation()
                if androidModuleBackupRestoreOperationID == operationID {
                    showTransientStatusMessage(androidModuleBackupRestoreStatusMessage(for: report))
                }
            } catch is CancellationError {
                // View teardown and replacement stop only pre-commit work; the service owns commit.
            } catch {
                if androidModuleBackupRestoreOperationID == operationID {
                    statusMessage = localizedErrorMessage(error)
                }
            }
        }
    }

    /**
     Shows Android-style transient success feedback on the Backup & Restore screen.

     Android document/module installs report successful completion with a short toast. Settings
     retains alerts for failures and destructive confirmations, but success copy should not block
     the screen or require an OK tap.

     - Parameter message: Localized toast text to display.
     - Side effects:
       - cancels any pending toast dismissal
       - mutates transient feedback state
       - schedules automatic toast dismissal
     - Failure modes: none; newer messages replace earlier transient feedback.
     */
    private func showTransientStatusMessage(_ message: String) {
        transientStatusWorkItem?.cancel()
        withAnimation { transientStatusMessage = message }
        let work = DispatchWorkItem {
            withAnimation { transientStatusMessage = nil }
            transientStatusWorkItem = nil
        }
        transientStatusWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AndroidToastFeedback.shortDuration,
            execute: work
        )
    }

    /**
     Clears retained Android module backup confirmation state without mutating user files.
     */
    private func clearPendingAndroidModuleBackup() {
        androidModuleBackupRestoreOperationID = nil
        androidModuleBackupRestoreTask?.cancel()
        androidModuleBackupRestoreTask = nil
        if let pendingAndroidModuleBackupURL {
            try? FileManager.default.removeItem(at: pendingAndroidModuleBackupURL)
        }
        pendingAndroidModuleBackupURL = nil
        pendingAndroidModuleBackupAuthorization = nil
        showAndroidModuleBackupOverwriteAlert = false
        isRestoringAndroidModuleBackup = false
    }

    /**
     Copies a selected Android module backup archive into app-owned temporary storage.

     - Parameter url: Security-scoped document URL selected by the user.
     - Returns: Temporary `.abmd.zip` archive URL owned by this app.
     - Side effects: Creates one temporary file and streams the selected archive into it.
     - Failure modes: Rethrows cancellation and file-system read/write failures; partial output is
       removed before an error escapes.
     */
    nonisolated private static func copyAndroidModuleBackupArchiveToTemporaryFile(from url: URL) throws -> URL {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-module-backup-\(UUID().uuidString).abmd.zip")
        try AndroidModuleBackupArchiveFileStager.copy(from: url, to: destinationURL)
        return destinationURL
    }

    /**
     Builds the overwrite-confirmation message for Android module backup restore.

     - Returns: User-visible explanation listing the first few paths that would be overwritten.
     - Side effects: none.
     - Failure modes: Empty pending state returns a generic overwrite warning.
     */
    private func androidModuleBackupOverwriteMessage() -> String {
        guard let authorization = pendingAndroidModuleBackupAuthorization,
              !authorization.conflictingPaths.isEmpty else {
            return String(
                localized: "android_module_backup_overwrite_generic",
                defaultValue: "This backup will replace existing module files."
            )
        }
        let preview = authorization.conflictingPaths.prefix(5).joined(separator: "\n")
        return String(
            localized: "android_module_backup_overwrite_message",
            defaultValue: "This backup will replace existing module files:\n\(preview)"
        )
    }

    /**
     Builds the user-visible completion summary for Android module backup restore.

     - Parameter report: Restore report from `AndroidModuleBackupService`.
     - Returns: Android's generic module-install success message. The report remains an input so the
       restore caller keeps the service contract explicit even though Android does not enumerate
       restored module names in the success surface.
     - Side effects: none.
     - Failure modes: Missing localization falls back to Android's English success string.
     */
    private func androidModuleBackupRestoreStatusMessage(for report: AndroidModuleBackupRestoreReport) -> String {
        AndroidModuleBackupPresentation.localizedRestoreSuccessMessage(for: report)
    }

    /**
     Applies one confirmed Android BackupActivity reset category.

     - Parameter category: Reset category selected from the Reset Databases section.
     - Side effects:
       - marks the reset category row as active before scheduling work so SwiftUI can render the
         destructive-alert dismissal and disabled controls before the reset starts
       - mutates SwiftData/settings/file-backed repository state through `AndroidBackupResetService`
       - clears category-scoped remote-sync bookkeeping for sync-backed categories
       - presents feedback with success or failure text after the reset confirmation closes
     - Failure modes: Reset service errors are caught and surfaced with the shared error prefix.
     */
    private func resetDatabase(_ category: AndroidBackupResetCategory) {
        guard !isBackupWorkflowBusy else {
            return
        }
        isResettingBackupCategory = true
        statusMessage = nil

        Task { @MainActor in
            await Task.yield()
            defer {
                isResettingBackupCategory = false
            }

            do {
                _ = try androidResetService.reset(
                    category,
                    modelContext: modelContext,
                    settingsStore: SettingsStore(modelContext: modelContext)
                )
                statusMessage = category.localizedBackupResetSuccessMessage
            } catch {
                statusMessage = localizedErrorMessage(error)
            }
        }
    }

    /**
     Moves a file-backed Android database backup export to the canonical share-sheet filename.

     Android parity depends on presenting `AndBibleDatabaseBackup.abdb.zip`, while the background
     export service creates a unique temporary filename to avoid collisions during archive generation.

     - Parameter export: Completed file-backed database backup export.
     - Returns: Temporary file URL with Android's canonical backup filename.
     - Side effects:
       - deletes any previous temporary export with the same canonical filename
       - moves the generated archive into the share-sheet location
       - removes the generated archive if the canonical move fails
     - Failure modes: Rethrows file-system errors when the previous export cannot be removed or the
       generated archive cannot be moved after attempting to clean up the source archive.
     */
    private func moveExportFileToShareDirectory(_ export: AndroidDatabaseBackupFileExport) throws -> URL {
        try moveExportFileToShareDirectory(fileURL: export.fileURL, fileName: export.fileName)
    }

    /**
     Moves one file-backed backup export to its canonical Android destination filename.

     - Parameters:
       - fileURL: Unique generated archive owned by the export workflow.
       - fileName: Canonical Android backup filename presented to Files and Share.
     - Returns: Temporary canonical URL retained until destination completion.
     - Side effects: Replaces an older temporary export and moves the generated archive.
     - Throws: Filesystem failures after attempting to remove the generated source on error.
     */
    private func moveExportFileToShareDirectory(fileURL sourceURL: URL, fileName: String) throws -> URL {
        let fileManager = FileManager.default
        let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(fileName)
        if destinationURL == sourceURL {
            return destinationURL
        }
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return destinationURL
        } catch {
            try? fileManager.removeItem(at: sourceURL)
            throw error
        }
    }

    /**
     Writes export data to a temporary file and returns its URL for sharing.

     - Parameters:
       - data: File contents to write.
       - fileName: Target filename appended within the temporary directory.
     - Returns: Temporary file URL on success, or `nil` after queuing failure feedback.
     */
    private func saveToTempFile(data: Data, fileName: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            statusMessage = String(localized: "error_save_file")
            return nil
        }
    }
}

// Uses ShareSheet from Shared/ShareSheet.swift
