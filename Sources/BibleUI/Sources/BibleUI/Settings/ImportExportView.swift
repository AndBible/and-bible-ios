// ImportExportView.swift -- Android-aligned Backup & Restore settings screen

import SwiftUI
import SwiftData
import BibleCore
import SwordKit
import UniformTypeIdentifiers

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

    /// Restore/import target whose content types and result handler are active for the file picker.
    @State private var restoreImportPickerTarget: RestoreWorkflowTarget?

    /// URL of the most recently exported file shared through the share sheet.
    @State private var exportedFileURL: URL?

    /// Pending user-visible success, failure, or guidance message for the feedback alert.
    @State private var statusMessage: String?

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

    /// Whether an Android module backup restore is currently in progress.
    @State private var isRestoringAndroidModuleBackup = false

    /// Whether an Android module backup export is currently in progress.
    @State private var isExportingAndroidModuleBackup = false

    /// Controls presentation of Android module backup export module selection.
    @State private var showAndroidModuleBackupExportSheet = false

    /// Installed SWORD modules shown in the Android module backup export selection sheet.
    @State private var androidModuleBackupExportModules: [ModuleInfo] = []

    /// Temporary Android module backup archive retained while overwrite confirmation is visible.
    @State private var pendingAndroidModuleBackupURL: URL?

    /// Existing module file paths reported for the pending Android module backup confirmation.
    @State private var pendingAndroidModuleBackupExistingFiles: [String] = []

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

     - Note: This initializer has no inputs and performs no side effects.
     */
    public init() {}

    /**
     Current accessibility-visible presentation state for UI automation.

     The value encodes which modal surface the screen is actively driving so UI tests can assert
     workflow transitions without depending on private UIKit or SwiftUI picker hierarchy details.
     */
    private var accessibilityState: String {
        if showBackupDestinationDialog {
            return "backupDestinationPresented"
        }
        if showBackupFileExporter {
            return "fileExporterPresented"
        }
        if showExportSheet {
            return "shareSheetPresented"
        }
        if showRestoreImportPicker {
            switch restoreImportPickerTarget ?? restoreTarget.wrappedValue {
            case .database:
                return "databaseRestorePickerPresented"
            case .documents:
                return "documentsRestorePickerPresented"
            }
        }
        if showAndroidModuleBackupExportSheet {
            return "androidModuleBackupExportPresented"
        }
        if androidBackupArchive != nil {
            return "androidBackupImportPresented"
        }
        if isResettingBackupCategory {
            return "resetInProgress"
        }
        if pendingBackupExport != nil {
            return "backupPayloadPending"
        }
        return "idle"
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
     Android reset categories with safe iOS storage equivalents.

     - Returns: Reset buttons in Android's BackupActivity order, omitting AI Settings until iOS has
       a real durable AI settings store.
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
        switch restoreImportPickerTarget ?? restoreTarget.wrappedValue {
        case .database:
            return [.zip, .data]
        case .documents:
            return ExternalDocumentImportService.supportedContentTypes
        }
    }

    /**
     Builds Android's BackupActivity sections using native iOS file plumbing.
     */
    public var body: some View {
        List {
            Section {
                ForEach(BackupWorkflowTarget.allCases) { target in
                    BackupWorkflowOptionRow(
                        title: target.localizedTitle,
                        description: target.localizedDescription,
                        value: target,
                        selection: backupTarget,
                        accessibilityIdentifier: "backupWorkflowTarget.\(target.rawValue)Button"
                    )
                }

                Button {
                    beginBackup()
                } label: {
                    HStack {
                        Text(String(localized: "backup_to", defaultValue: "Backup to..."))
                        Spacer()
                        if isBackingUp {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("backupWorkflowBackupButton")
                .disabled(isBackupWorkflowBusy)
            } header: {
                Text(String(localized: "backup_and_restore", defaultValue: "Backup & Restore"))
            }

            Section {
                ForEach(RestoreWorkflowTarget.allCases) { target in
                    BackupWorkflowOptionRow(
                        title: target.localizedTitle,
                        description: target.localizedDescription,
                        value: target,
                        selection: restoreTarget,
                        accessibilityIdentifier: "restoreWorkflowTarget.\(target.rawValue)Button"
                    )
                }

                Button {
                    beginRestoreOrImport()
                } label: {
                    HStack {
                        Text(String(localized: "backup_restore_from2", defaultValue: "Restore or Import from..."))
                        Spacer()
                        if isRestoringOrImporting {
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("backupWorkflowRestoreButton")
                .disabled(isBackupWorkflowBusy)
            } header: {
                Text(String(localized: "backup_restore2", defaultValue: "Restore or Import"))
            }

            Section {
                Text(String(
                    localized: "reset_databases_description",
                    defaultValue: "Reset individual databases to their initial empty state. This cannot be undone."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)

                ForEach(resetCategories) { category in
                    Button(role: .destructive) {
                        pendingResetCategory = category
                    } label: {
                        Text(category.localizedBackupResetButtonTitle)
                    }
                    .accessibilityIdentifier(category.backupResetAccessibilityIdentifier)
                    .disabled(isBackupWorkflowBusy)
                }
            } header: {
                Text(String(localized: "reset_databases_title", defaultValue: "Reset Databases"))
            }

        }
        .accessibilityIdentifier("importExportScreen")
        .accessibilityValue(accessibilityState)
        .navigationTitle(String(localized: "backup_and_restore", defaultValue: "Backup & Restore"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert(
            String(localized: "backup_backup_title", defaultValue: "Backup to where?"),
            isPresented: $showBackupDestinationDialog,
        ) {
            Button(String(localized: "backup_phone_storage", defaultValue: "Phone storage")) {
                finishPendingBackupExport(to: .phoneStorage)
            }
            .accessibilityIdentifier("backupDestinationPhoneStorageButton")
            Button(String(localized: "share", defaultValue: "Share")) {
                finishPendingBackupExport(to: .share)
            }
            .accessibilityIdentifier("backupDestinationShareButton")
            Button(String(localized: "cancel"), role: .cancel) {
                cancelPendingBackupExport()
            }
            .accessibilityIdentifier("backupDestinationCancelButton")
        } message: {
            Text(String(
                localized: "backup_backup_message",
                defaultValue: "Backup to phone or elsewhere via Share function (email, iCloud Drive etc.)?"
            ))
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
        .sheet(item: $androidBackupArchive, onDismiss: cleanupDismissedAndroidBackupArchive) { archive in
            AndroidDatabaseBackupImportSheet(
                archive: archive,
                isApplying: isApplyingAndroidBackup,
                onCancel: dismissAndroidBackupArchive,
                onApply: applyAndroidBackupSelections
            )
            .onAppear {
                androidBackupArchivePendingCleanup = archive
            }
        }
        .fileImporter(
            isPresented: $showRestoreImportPicker,
            allowedContentTypes: restoreImportPickerContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleRestoreImportPickerResult(result)
        }
        .sheet(isPresented: $showAndroidModuleBackupExportSheet) {
            AndroidModuleBackupExportSheet(
                modules: androidModuleBackupExportModules,
                isExporting: isExportingAndroidModuleBackup,
                onCancel: dismissAndroidModuleBackupExportSelection,
                onExport: exportAndroidModuleBackup(moduleNames:)
            )
        }
        .alert(item: $pendingResetCategory) { category in
            Alert(
                title: Text(category.localizedBackupResetButtonTitle),
                message: Text(String(
                    format: String(
                        localized: "reset_database_confirm",
                        defaultValue: "This will permanently delete all data in \"%@\" and reset it to the initial state. This cannot be undone.\n\nAre you sure?"
                    ),
                    category.localizedBackupResetTitle
                )),
                primaryButton: .destructive(Text(String(localized: "reset", defaultValue: "Reset"))) {
                    resetDatabase(category)
                },
                secondaryButton: .cancel(Text(String(localized: "cancel")))
            )
        }
        .alert(
            String(localized: "android_module_backup_overwrite_title", defaultValue: "Overwrite existing module files?"),
            isPresented: $showAndroidModuleBackupOverwriteAlert
        ) {
            Button(String(localized: "cancel"), role: .cancel) {
                clearPendingAndroidModuleBackup()
            }
            Button(String(localized: "overwrite", defaultValue: "Overwrite"), role: .destructive) {
                restorePendingAndroidModuleBackup()
            }
        } message: {
            Text(androidModuleBackupOverwriteMessage())
        }
        .onChange(of: statusMessage) { _, newValue in
            showStatusAlert = newValue != nil
        }
        .alert(
            String(localized: "backup_and_restore", defaultValue: "Backup & Restore"),
            isPresented: $showStatusAlert
        ) {
            Button(String(localized: "ok"), role: .cancel) {
                statusMessage = nil
            }
        } message: {
            Text(statusMessage ?? "")
        }
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
                let report = try androidBackupService.apply(
                    archive: archive,
                    selections: selections,
                    modelContext: modelContext,
                    settingsStore: SettingsStore(modelContext: modelContext)
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
       files into local app storage from a detached task, and presents feedback.
     - Failure modes: Unsupported formats and installer errors are surfaced as feedback.
     */
    private func installSupportedDocument(from url: URL) {
        isInstallingDocument = true
        statusMessage = nil
        Task { @MainActor in
            defer {
                isInstallingDocument = false
            }
            await Task.yield()
            let result = await Task.detached(priority: .userInitiated) {
                ExternalDocumentImportService().importDocument(at: url)
            }.value
            statusMessage = result.feedbackMessage
        }
    }

    /**
     Presents installed SWORD modules for Android-compatible backup export selection.

     Android asks the user which installed documents/modules to include before writing
     `AndBibleModulesBackup.abmd.zip`. iOS mirrors that behavior for SWORD-backed modules by
     collecting the current installed-module list from `SwordManager`, sorting it in Android's
     language-first order, and presenting a multiselect sheet before export.

     Side effects:
     - reads installed modules through `SwordManager`
     - updates `androidModuleBackupExportModules`
     - presents the export selection sheet or surfaces a no-modules error
     */
    private func presentAndroidModuleBackupExportSelection() {
        statusMessage = nil
        guard let manager = SwordManager() else {
            statusMessage = localizedErrorMessage(AndroidModuleBackupError.noExportableModules)
            return
        }
        let modules = manager.installedModules().sorted { lhs, rhs in
            let languageOrder = lhs.language.localizedCaseInsensitiveCompare(rhs.language)
            if languageOrder != .orderedSame {
                return languageOrder == .orderedAscending
            }
            let descriptionOrder = lhs.description.localizedCaseInsensitiveCompare(rhs.description)
            if descriptionOrder != .orderedSame {
                return descriptionOrder == .orderedAscending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        guard !modules.isEmpty else {
            statusMessage = localizedErrorMessage(AndroidModuleBackupError.noExportableModules)
            return
        }
        androidModuleBackupExportModules = modules
        showAndroidModuleBackupExportSheet = true
    }

    /**
     Dismisses Android module backup export selection without writing files.

     Side effects:
     - clears export selection state
     - dismisses the export selection sheet
     */
    private func dismissAndroidModuleBackupExportSelection() {
        showAndroidModuleBackupExportSheet = false
        androidModuleBackupExportModules = []
        isExportingAndroidModuleBackup = false
    }

    /**
     Exports selected SWORD modules as Android's `.abmd.zip` module backup archive.

     - Parameter moduleNames: Selected module initials emitted by the export selection sheet.
     - Side effects:
       - marks the module export as active before scheduling work so SwiftUI can disable the sheet
       - reads local SWORD module config and data files off the main actor
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

        let selectedModuleNames = Set(moduleNames)
        Task { @MainActor in
            await Task.yield()
            defer {
                isExportingAndroidModuleBackup = false
            }

            do {
                let export = try await Task.detached(priority: .userInitiated) {
                    try AndroidModuleBackupService().exportArchive(moduleNames: selectedModuleNames)
                }.value
                showAndroidModuleBackupExportSheet = false
                androidModuleBackupExportModules = []
                let payload = BackupExportPayload(
                    data: export.data,
                    fileName: export.fileName,
                    statusMessage: String(
                        localized: "android_module_backup_exported_summary",
                        defaultValue: "Exported Android module backup: \(export.moduleNames.joined(separator: ", "))"
                    )
                )
                await Task.yield()
                presentBackupDestination(payload)
            } catch {
                showAndroidModuleBackupExportSheet = false
                androidModuleBackupExportModules = []
                await Task.yield()
                statusMessage = localizedErrorMessage(error)
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
     - presents feedback with restore success or failure details
     - Failure modes: Catches service errors and surfaces them to the settings screen.
     */
    private func prepareAndroidModuleBackupRestore(from url: URL) {
        Task { @MainActor in
            await Task.yield()
            var temporaryArchiveURL: URL?
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    let archiveURL = try Self.copyAndroidModuleBackupArchiveToTemporaryFile(from: url)
                    let inspection = try AndroidModuleBackupService().inspectArchive(fromArchiveAt: archiveURL)
                    return (archiveURL, inspection)
                }.value
                temporaryArchiveURL = prepared.0

                guard prepared.1.existingEntryPaths.isEmpty else {
                    pendingAndroidModuleBackupURL = prepared.0
                    pendingAndroidModuleBackupExistingFiles = prepared.1.existingEntryPaths
                    showAndroidModuleBackupOverwriteAlert = true
                    return
                }

                let report = try await Task.detached(priority: .userInitiated) {
                    try AndroidModuleBackupService().restoreArchive(
                        fromArchiveAt: prepared.0,
                        allowOverwritingExistingFiles: true
                    )
                }.value
                statusMessage = androidModuleBackupRestoreStatusMessage(for: report)
                isRestoringAndroidModuleBackup = false
                try? FileManager.default.removeItem(at: prepared.0)
                temporaryArchiveURL = nil
            } catch {
                if let temporaryArchiveURL {
                    try? FileManager.default.removeItem(at: temporaryArchiveURL)
                }
                statusMessage = localizedErrorMessage(error)
                isRestoringAndroidModuleBackup = false
            }
        }
    }

    /**
     Restores the pending Android module backup after the user confirms overwriting files.

     Side effects:
     - writes supported SWORD module files into the local module directory
     - clears pending confirmation state
     - presents feedback with success or failure details after the overwrite alert closes
     */
    private func restorePendingAndroidModuleBackup() {
        guard let archiveURL = pendingAndroidModuleBackupURL else {
            clearPendingAndroidModuleBackup()
            return
        }
        pendingAndroidModuleBackupURL = nil
        pendingAndroidModuleBackupExistingFiles = []
        showAndroidModuleBackupOverwriteAlert = false
        isRestoringAndroidModuleBackup = true

        Task { @MainActor in
            await Task.yield()
            let feedbackMessage: String
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try AndroidModuleBackupService().restoreArchive(
                        fromArchiveAt: archiveURL,
                        allowOverwritingExistingFiles: true
                    )
                }.value
                feedbackMessage = androidModuleBackupRestoreStatusMessage(for: report)
            } catch {
                feedbackMessage = localizedErrorMessage(error)
            }
            try? FileManager.default.removeItem(at: archiveURL)
            isRestoringAndroidModuleBackup = false
            statusMessage = feedbackMessage
        }
    }

    /**
     Clears retained Android module backup confirmation state without mutating user files.
     */
    private func clearPendingAndroidModuleBackup() {
        if let pendingAndroidModuleBackupURL {
            try? FileManager.default.removeItem(at: pendingAndroidModuleBackupURL)
        }
        pendingAndroidModuleBackupURL = nil
        pendingAndroidModuleBackupExistingFiles = []
        showAndroidModuleBackupOverwriteAlert = false
        isRestoringAndroidModuleBackup = false
    }

    /**
     Copies a selected Android module backup archive into app-owned temporary storage.

     - Parameter url: Security-scoped document URL selected by the user.
     - Returns: Temporary `.abmd.zip` archive URL owned by this app.
     - Side effects: Creates one temporary file by copying `url`.
     - Failure modes: Rethrows file-system copy failures.
     */
    private static func copyAndroidModuleBackupArchiveToTemporaryFile(from url: URL) throws -> URL {
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("android-module-backup-\(UUID().uuidString).abmd.zip")
        try FileManager.default.copyItem(at: url, to: destinationURL)
        return destinationURL
    }

    /**
     Builds the overwrite-confirmation message for Android module backup restore.

     - Returns: User-visible explanation listing the first few paths that would be overwritten.
     - Side effects: none.
     - Failure modes: Empty pending state returns a generic overwrite warning.
     */
    private func androidModuleBackupOverwriteMessage() -> String {
        guard !pendingAndroidModuleBackupExistingFiles.isEmpty else {
            return String(
                localized: "android_module_backup_overwrite_generic",
                defaultValue: "This backup will replace existing module files."
            )
        }
        let preview = pendingAndroidModuleBackupExistingFiles.prefix(5).joined(separator: "\n")
        return String(
            localized: "android_module_backup_overwrite_message",
            defaultValue: "This backup will replace existing module files:\n\(preview)"
        )
    }

    /**
     Builds the user-visible completion summary for Android module backup restore.

     - Parameter report: Restore report from `AndroidModuleBackupService`.
     - Returns: Concise status message listing installed modules and skipped unsupported content.
     - Side effects: none.
     - Failure modes: Empty module names produce a generic success message, though the service
       normally rejects archives without supported SWORD modules.
     */
    private func androidModuleBackupRestoreStatusMessage(for report: AndroidModuleBackupRestoreReport) -> String {
        let modules = report.installedModuleNames.isEmpty
            ? String(localized: "android_module_backup_modules_unknown", defaultValue: "modules")
            : report.installedModuleNames.joined(separator: ", ")
        if report.skippedUnsupportedEntryPaths.isEmpty {
            return String(
                localized: "android_module_backup_restored_summary",
                defaultValue: "Restored Android module backup: \(modules)"
            )
        }
        return String(
            localized: "android_module_backup_restored_with_skips_summary",
            defaultValue: "Restored Android module backup: \(modules). Skipped \(report.skippedUnsupportedEntryPaths.count) Android-only files."
        )
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
        let fileManager = FileManager.default
        let fileURL = fileManager.temporaryDirectory.appendingPathComponent(export.fileName)
        if fileURL == export.fileURL {
            return fileURL
        }
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            try fileManager.moveItem(at: export.fileURL, to: fileURL)
            return fileURL
        } catch {
            try? fileManager.removeItem(at: export.fileURL)
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
