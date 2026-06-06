// ImportExportView.swift -- Android-aligned Backup & Restore settings screen

import SwiftUI
import SwiftData
import BibleCore
import SwordKit
import UniformTypeIdentifiers

/**
 Android-aligned Backup & Restore settings screen.

 The user-facing workflow follows Android's `BackupActivity`: users first choose Database,
 Documents, or Application for backup, choose Database or Documents for Restore or Import, and use
 the reset controls from the same screen. iOS keeps platform-specific plumbing behind those choices:
 Files export and share sheets replace Android intents, SwiftData restore engines replace raw
 Android database-file swaps, and document/module importers replace Android's `InstallZip` activity.

 Legacy JSON/CSV utilities are intentionally demoted out of the primary backup path because they do
 not represent Android backup semantics.

 Data dependencies:
 - `modelContext` is passed into `BackupService` for backup import/export operations

 Side effects:
 - backup actions generate Android-compatible archives and then present Files export or share UI
 - restore/import actions read user-selected files through `fileImporter` and mutate app data
   through backup/import/install services
 - reset actions mutate category data through `AndroidBackupResetService`
 - status text reflects the latest success or failure message across all operations
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

    /// Controls presentation of the Android database restore/import picker.
    @State private var showDatabaseRestorePicker = false

    /// Controls presentation of the Android documents restore/import picker.
    @State private var showDocumentsRestorePicker = false

    /// Controls presentation of the legacy JSON/CSV import picker.
    @State private var showLegacyImportPicker = false

    /// URL of the most recently exported file shared through the share sheet.
    @State private var exportedFileURL: URL?

    /// Latest user-visible success or error message across import/export actions.
    @State private var statusMessage: String?

    /// Whether a backup export is currently in progress.
    @State private var isExporting = false

    /// Whether a backup import is currently in progress.
    @State private var isImporting = false

    /// Whether a SWORD module installation is currently in progress.
    @State private var isInstallingModule = false

    /// Whether an Android module backup restore is currently in progress.
    @State private var isRestoringAndroidModuleBackup = false

    /// Whether an Android module backup export is currently in progress.
    @State private var isExportingAndroidModuleBackup = false

    /// Controls presentation of Android module backup export module selection.
    @State private var showAndroidModuleBackupExportSheet = false

    /// Installed SWORD modules shown in the Android module backup export selection sheet.
    @State private var androidModuleBackupExportModules: [ModuleInfo] = []

    /// Selected Android module backup bytes retained while the overwrite confirmation is visible.
    @State private var pendingAndroidModuleBackupData: Data?

    /// Existing module file paths reported for the pending Android module backup confirmation.
    @State private var pendingAndroidModuleBackupExistingFiles: [String] = []

    /// Controls the Android module backup overwrite confirmation prompt.
    @State private var showAndroidModuleBackupOverwriteAlert = false

    /// Whether an EPUB installation is currently in progress.
    @State private var isInstallingEpub = false

    /// Android database backup archive currently staged for category selection.
    @State private var androidBackupArchive: AndroidDatabaseBackupArchive?

    /// Last archive presented by the sheet, retained until dismissal cleanup runs.
    @State private var androidBackupArchivePendingCleanup: AndroidDatabaseBackupArchive?

    /// Whether selected Android backup sections are currently being applied.
    @State private var isApplyingAndroidBackup = false

    /// Reset category waiting for Android-style destructive confirmation.
    @State private var pendingResetCategory: AndroidBackupResetCategory?

    /// Service used to export, load, apply, and clean up Android `.abdb.zip` database backups.
    private let androidBackupService = AndroidDatabaseBackupService()

    /// Service used to inspect, restore, and export Android `.abmd.zip` module backups.
    private let androidModuleBackupService = AndroidModuleBackupService()

    /// Service used to reset Android BackupActivity categories through iOS storage engines.
    private let androidResetService = AndroidBackupResetService()

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
        if showDatabaseRestorePicker {
            return "databaseRestorePickerPresented"
        }
        if showDocumentsRestorePicker {
            return "documentsRestorePickerPresented"
        }
        if showLegacyImportPicker {
            return "legacyImportPickerPresented"
        }
        if showAndroidModuleBackupExportSheet {
            return "androidModuleBackupExportPresented"
        }
        if androidBackupArchive != nil {
            return "androidBackupImportPresented"
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
        isImporting || isRestoringAndroidModuleBackup || isInstallingModule || isInstallingEpub
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
                .disabled(isBackingUp)
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
                .disabled(isRestoringOrImporting)
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
                }
            } header: {
                Text(String(localized: "reset_databases_title", defaultValue: "Reset Databases"))
            }

            Section {
                Button {
                    exportLegacyFullBackup()
                } label: {
                    SwiftUI.Label(
                        String(localized: "legacy_full_backup_json", defaultValue: "Legacy Backup (JSON)"),
                        systemImage: "arrow.up.doc"
                    )
                }
                .accessibilityIdentifier("importExportLegacyFullBackupButton")
                .disabled(isExporting)

                Button {
                    exportBookmarksCSV()
                } label: {
                    SwiftUI.Label(String(localized: "bookmarks_csv"), systemImage: "tablecells")
                }
                .disabled(isExporting)

                Button {
                    showLegacyImportPicker = true
                } label: {
                    SwiftUI.Label(
                        String(localized: "legacy_import_json_csv", defaultValue: "Import Legacy JSON/CSV"),
                        systemImage: "arrow.down.doc"
                    )
                }
                .accessibilityIdentifier("backupWorkflowLegacyImportButton")
                .disabled(isImporting)
            } header: {
                Text(String(localized: "legacy_import_export_tools", defaultValue: "Legacy Import/Export Tools"))
            } footer: {
                Text(String(
                    localized: "legacy_import_export_tools_footer",
                    defaultValue: "These tools are retained for old iOS JSON/CSV files. Android-compatible backup and restore uses the Database and Documents choices above."
                ))
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.callout)
                        .foregroundStyle(statusMessage.contains("Error") ? .red : .green)
                }
            }
        }
        .accessibilityIdentifier("importExportScreen")
        .accessibilityValue(accessibilityState)
        .navigationTitle(String(localized: "backup_and_restore", defaultValue: "Backup & Restore"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            String(localized: "backup_backup_title", defaultValue: "Backup to where?"),
            isPresented: $showBackupDestinationDialog,
            titleVisibility: .visible
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
                defaultValue: "Backup to phone or elsewhere via Share function (email, Google Drive etc.)?"
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
        .sheet(isPresented: $showExportSheet, onDismiss: { pendingBackupExport = nil }) {
            if let url = exportedFileURL {
                ShareSheet(items: [url])
            }
        }
        .fileImporter(
            isPresented: $showDatabaseRestorePicker,
            allowedContentTypes: [.zip, .data],
            allowsMultipleSelection: false
        ) { result in
            handleDatabaseRestoreImport(result)
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
            isPresented: $showDocumentsRestorePicker,
            allowedContentTypes: [.zip, .epub, .data],
            allowsMultipleSelection: false
        ) { result in
            handleDocumentsRestoreImport(result)
        }
        .sheet(isPresented: $showAndroidModuleBackupExportSheet) {
            AndroidModuleBackupExportSheet(
                modules: androidModuleBackupExportModules,
                isExporting: isExportingAndroidModuleBackup,
                onCancel: dismissAndroidModuleBackupExportSelection,
                onExport: exportAndroidModuleBackup(moduleNames:)
            )
        }
        .fileImporter(
            isPresented: $showLegacyImportPicker,
            allowedContentTypes: [.json, .commaSeparatedText, .data],
            allowsMultipleSelection: false
        ) { result in
            handleLegacyImport(result)
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
    }

    /**
     Starts the selected Android BackupActivity backup flow.

     Database and Documents prepare Android-compatible archives before presenting Android's
     destination choice. Application backup is unavailable on iOS because apps cannot export their
     installed bundle as an IPA/APK equivalent at runtime.

     - Side effects: Mutates export/progress/status state and may present backup destination or
       module-selection UI.
     - Failure modes: Category-specific export failures are surfaced through `statusMessage`.
     */
    private func beginBackup() {
        switch backupTarget.wrappedValue {
        case .database:
            exportAndroidDatabaseBackup()
        case .documents:
            presentAndroidModuleBackupExportSelection()
        case .application:
            statusMessage = String(
                localized: "ios_application_backup_unavailable",
                defaultValue: "Application backup is not available on iOS because installed app bundles cannot be exported from within the app."
            )
        }
    }

    /**
     Starts the selected Android BackupActivity Restore or Import flow.

     - Side effects: Presents either the database backup picker or the document/module picker.
     - Failure modes: Picker failures are handled by the selected result handler.
     */
    private func beginRestoreOrImport() {
        switch restoreTarget.wrappedValue {
        case .database:
            showDatabaseRestorePicker = true
        case .documents:
            showDocumentsRestorePicker = true
        }
    }

    /**
     Exports an Android-compatible database backup and presents Android's destination choice.

     This is the parity backup path: Android expects `AndBibleDatabaseBackup.abdb.zip` containing
     `AndBibleBackupManifest.json` and supported category SQLite databases under `db/`.

     - Side effects:
       - toggles export state and clears prior status messages
       - reads SwiftData through `AndroidDatabaseBackupService`
       - stores the generated archive until the user chooses Phone storage or Share
     - Failure modes: Catches backup export and file-write failures and surfaces them as status text.
     */
    private func exportAndroidDatabaseBackup() {
        isExporting = true
        statusMessage = nil

        do {
            let export = try androidBackupService.exportArchive(
                modelContext: modelContext,
                settingsStore: SettingsStore(modelContext: modelContext)
            )
            let categorySummary = export.categories
                .map(\.localizedBackupSectionName)
                .joined(separator: ", ")
            presentBackupDestination(
                BackupExportPayload(
                    data: export.data,
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

        isExporting = false
    }

    /**
     Stores a generated backup payload and presents Android's Backup to where? choice.

     - Parameter payload: Valid archive bytes plus default file name and completion status.
     - Side effects: Mutates pending export state and presents the confirmation dialog.
     - Failure modes: none; backup generation has already succeeded before this method is called.
     */
    private func presentBackupDestination(_ payload: BackupExportPayload) {
        pendingBackupExport = payload
        showBackupDestinationDialog = true
    }

    /**
     Completes the pending backup using the selected Android destination.

     - Parameter destination: Phone storage uses Files export; Share writes a temporary file and
       opens the share sheet.
     - Side effects:
       - mutates exporter or share-sheet presentation state
       - writes a temporary file for Share
       - updates status text after the selected destination accepts the payload
     - Failure modes: Missing pending payload is ignored; file-write failures set `statusMessage`.
     */
    private func finishPendingBackupExport(to destination: BackupExportDestination) {
        guard let payload = pendingBackupExport else {
            return
        }

        switch destination {
        case .phoneStorage:
            backupExportDocument = BackupExportDocument(data: payload.data)
            backupExportFileName = payload.fileName
            showBackupFileExporter = true
        case .share:
            if let url = saveToTempFile(data: payload.data, fileName: payload.fileName) {
                exportedFileURL = url
                showExportSheet = true
                statusMessage = payload.statusMessage
            }
        }
    }

    /**
     Handles completion of SwiftUI's Files exporter.

     - Parameter result: Export result emitted by the system document picker.
     - Side effects:
       - clears the pending export once the exporter finishes
       - publishes the prepared completion message only after successful export
       - updates visible error state on failure
     - Failure modes: Export errors are formatted with the shared import/export error prefix.
     */
    private func handleBackupFileExport(_ result: Result<URL, Error>) {
        let completionMessage = pendingBackupExport?.statusMessage
        pendingBackupExport = nil

        switch result {
        case .success:
            statusMessage = completionMessage
        case .failure(let error):
            statusMessage = localizedErrorMessage(error)
        }
    }

    /**
     Cancels a prepared backup destination choice without writing or sharing the archive.
     *
     - Side effects: Releases the generated archive bytes and dismisses any pending status from
       the abandoned export.
     - Failure modes: none.
     */
    private func cancelPendingBackupExport() {
        pendingBackupExport = nil
    }

    /**
     Exports the legacy iOS JSON backup, writes it to a temporary file, and presents the share sheet.

     The JSON payload is retained for local/developer compatibility, but it is not Android's
     manual backup format and should not be treated as the parity backup path.

     - Side effects:
       - toggles export state and clears prior status messages
       - queries `BackupService` for a full JSON backup payload
       - writes the payload to a temporary file and presents the share sheet on success
     - Failure modes: Surfaces missing backup data through status text.
     */
    private func exportLegacyFullBackup() {
        isExporting = true
        statusMessage = nil

        let service = BackupService(modelContext: modelContext)
        guard let data = service.exportFullBackup() else {
            statusMessage = String(localized: "error_create_backup")
            isExporting = false
            return
        }

        let fileName = "andbible-backup-\(dateString()).json"
        if let url = saveToTempFile(data: data, fileName: fileName) {
            exportedFileURL = url
            showExportSheet = true
        }

        isExporting = false
    }

    /**
     Exports bookmarks as CSV, writes the file to a temporary location, and presents the share sheet.
     */
    private func exportBookmarksCSV() {
        isExporting = true
        statusMessage = nil

        let service = BackupService(modelContext: modelContext)
        guard let data = service.exportBookmarksCSV() else {
            statusMessage = String(localized: "error_export_bookmarks")
            isExporting = false
            return
        }

        let fileName = "andbible-bookmarks-\(dateString()).csv"
        if let url = saveToTempFile(data: data, fileName: fileName) {
            exportedFileURL = url
            showExportSheet = true
        }

        isExporting = false
    }

    /**
     Handles Android database backup restore/import file selection.

     Android's Database restore path accepts `.abdb.zip` manual backup archives and then asks the
     user which sections to Restore or Import. iOS mirrors that contract by rejecting document,
     module, and legacy files from this target instead of routing every format through one generic
     importer.

     - Parameter result: File picker result for the Database Restore or Import target.
     - Side effects:
       - reads the selected file through security-scoped access
       - stages a validated Android database backup archive for section selection
       - updates status text on invalid selection or read failure
     - Failure modes: Picker, read, and archive validation failures are surfaced through
       `statusMessage`.
     */
    private func handleDatabaseRestoreImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            statusMessage = nil

            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            guard isAndroidDatabaseBackupFile(url) else {
                statusMessage = String(
                    localized: "android_database_backup_required",
                    defaultValue: "Select an Android database backup file (.abdb.zip)."
                )
                isImporting = false
                return
            }

            guard let data = try? Data(contentsOf: url) else {
                statusMessage = String(localized: "error_read_file")
                isImporting = false
                return
            }

            loadAndroidBackupArchive(from: data)
            isImporting = false

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
       - updates status text with success or failure messages
     - Failure modes: Unsupported document formats and importer errors are surfaced through
       `statusMessage`.
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
            if AndroidModuleBackupService.isAndroidModuleBackupFileName(url.lastPathComponent) {
                isRestoringAndroidModuleBackup = true
                guard let data = try? Data(contentsOf: url) else {
                    statusMessage = String(localized: "error_read_file")
                    isRestoringAndroidModuleBackup = false
                    return
                }
                prepareAndroidModuleBackupRestore(from: data)
                if !showAndroidModuleBackupOverwriteAlert {
                    isRestoringAndroidModuleBackup = false
                }
                return
            }

            switch ext {
            case "zip":
                installModule(from: url)
            case "epub":
                installEpub(from: url)
            case "bbl", "cmt", "dct", "mybible", "sqlite3", "bbli", "bblx":
                statusMessage = String(localized: "mysword_file_hint")
            default:
                statusMessage = String(localized: "error_unsupported_format_\(ext)")
            }

        case .failure(let error):
            statusMessage = localizedErrorMessage(error)
        }
    }

    /**
     Handles legacy iOS JSON/CSV file selection.

     This path is deliberately separate from Android Backup & Restore semantics. It exists only for
     existing iOS JSON backups and bookmark CSV files and does not accept Android archive formats.

     - Parameter result: File picker result from the Legacy Import/Export section.
     - Side effects: Imports JSON or CSV data through `BackupService` and updates `statusMessage`.
     - Failure modes: Picker, read, parse, and unsupported-format failures are surfaced through
       status text.
     */
    private func handleLegacyImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            statusMessage = nil

            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            guard let data = try? Data(contentsOf: url) else {
                statusMessage = String(localized: "error_read_file")
                isImporting = false
                return
            }

            let service = BackupService(modelContext: modelContext)
            switch url.pathExtension.lowercased() {
            case "json":
                let count = service.importFullBackup(data)
                statusMessage = count > 0
                    ? String(localized: "imported_items_\(count)")
                    : String(localized: "error_parse_backup")
            case "csv":
                let count = service.importBookmarksCSV(data)
                statusMessage = count > 0
                    ? String(localized: "imported_bookmarks_\(count)")
                    : String(localized: "error_parse_csv")
            default:
                statusMessage = String(
                    localized: "legacy_import_format_required",
                    defaultValue: "Select a legacy JSON backup or bookmark CSV file."
                )
            }

            isImporting = false

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
     Loads a raw Android database backup archive and presents the section-selection sheet.

     - Parameter data: Raw file bytes read from the user-selected backup.
     - Side effects:
       - clears any previously staged Android backup archive
       - writes validated Android SQLite files into a temporary staging directory
       - updates `androidBackupArchive` so SwiftUI presents the selection sheet
       - updates `statusMessage` when validation fails
     - Failure modes: Surfaces `AndroidDatabaseBackupError` and ZIP/file-system errors as status text.
     */
    private func loadAndroidBackupArchive(from data: Data) {
        cleanupLoadedAndroidBackupArchive()
        do {
            let archive = try androidBackupService.loadArchive(from: data)
            androidBackupArchive = archive
            androidBackupArchivePendingCleanup = archive
        } catch {
            statusMessage = localizedErrorMessage(error)
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
       - updates `statusMessage` with the apply result or error
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
            do {
                let report = try androidBackupService.apply(
                    archive: archive,
                    selections: selections,
                    modelContext: modelContext,
                    settingsStore: SettingsStore(modelContext: modelContext)
                )
                statusMessage = androidBackupStatusMessage(for: report)
            } catch {
                statusMessage = localizedErrorMessage(error)
            }
            isApplyingAndroidBackup = false
            dismissAndroidBackupArchive()
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
     - Returns: Localized status text containing the shared error prefix and error message.
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
     Installs one SWORD ZIP through the shared module repository.

     - Parameter url: Security-scoped URL for a user-selected ZIP file.
     - Side effects: Imports module files into local SWORD storage and updates `statusMessage`.
     - Failure modes: `ModuleRepository.installFromZip(at:)` errors are surfaced as status text.
     */
    private func installModule(from url: URL) {
        isInstallingModule = true
        statusMessage = nil
        do {
            let repo = ModuleRepository()
            let moduleName = try repo.installFromZip(at: url)
            statusMessage = String(localized: "installed_module_\(moduleName)")
        } catch {
            statusMessage = localizedErrorMessage(error)
        }
        isInstallingModule = false
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
       - reads local SWORD module config and data files
       - dismisses the selection sheet and schedules Android's backup destination choice after
         SwiftUI processes dismissal, avoiding two active sheet presentations at once
       - updates status text with export success or failure details
     */
    private func exportAndroidModuleBackup(moduleNames: [String]) {
        guard !moduleNames.isEmpty else {
            statusMessage = localizedErrorMessage(AndroidModuleBackupError.noExportableModules)
            return
        }
        isExportingAndroidModuleBackup = true
        statusMessage = nil
        do {
            let export = try androidModuleBackupService.exportArchive(moduleNames: Set(moduleNames))
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
            Task { @MainActor in
                await Task.yield()
                presentBackupDestination(payload)
            }
        } catch {
            statusMessage = localizedErrorMessage(error)
        }
        isExportingAndroidModuleBackup = false
    }

    /**
     Inspects an Android module backup and either restores it or queues overwrite confirmation.

     - Parameter data: Raw `.abmd.zip` archive bytes selected by the user.
     - Side effects:
     - may write supported module files when no overwrite confirmation is required
     - may retain `data` and existing paths in state for a later confirmation action
     - updates status text with restore success or failure details
     - Failure modes: Catches service errors and surfaces them to the settings screen.
     */
    private func prepareAndroidModuleBackupRestore(from data: Data) {
        do {
            let inspection = try androidModuleBackupService.inspectArchive(from: data)
            guard inspection.existingEntryPaths.isEmpty else {
                pendingAndroidModuleBackupData = data
                pendingAndroidModuleBackupExistingFiles = inspection.existingEntryPaths
                showAndroidModuleBackupOverwriteAlert = true
                return
            }
            let report = try androidModuleBackupService.restoreArchive(
                from: data,
                allowOverwritingExistingFiles: true
            )
            statusMessage = androidModuleBackupRestoreStatusMessage(for: report)
        } catch {
            statusMessage = localizedErrorMessage(error)
        }
    }

    /**
     Restores the pending Android module backup after the user confirms overwriting files.

     Side effects:
     - writes supported SWORD module files into the local module directory
     - clears pending confirmation state
     - updates status text with success or failure details
     */
    private func restorePendingAndroidModuleBackup() {
        guard let data = pendingAndroidModuleBackupData else {
            clearPendingAndroidModuleBackup()
            return
        }
        do {
            let report = try androidModuleBackupService.restoreArchive(
                from: data,
                allowOverwritingExistingFiles: true
            )
            statusMessage = androidModuleBackupRestoreStatusMessage(for: report)
        } catch {
            statusMessage = localizedErrorMessage(error)
        }
        clearPendingAndroidModuleBackup()
        isRestoringAndroidModuleBackup = false
    }

    /**
     Clears retained Android module backup confirmation state without mutating user files.
     */
    private func clearPendingAndroidModuleBackup() {
        pendingAndroidModuleBackupData = nil
        pendingAndroidModuleBackupExistingFiles = []
        showAndroidModuleBackupOverwriteAlert = false
        isRestoringAndroidModuleBackup = false
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
     Installs one EPUB document through the local EPUB reader store.

     - Parameter url: Security-scoped URL for a user-selected EPUB file.
     - Side effects: Copies/processes EPUB content into app storage and updates `statusMessage`.
     - Failure modes: `EpubReader.install(epubURL:)` errors are surfaced as status text.
     */
    private func installEpub(from url: URL) {
        isInstallingEpub = true
        statusMessage = nil

        do {
            let identifier = try EpubReader.install(epubURL: url)
            if let reader = EpubReader(identifier: identifier) {
                statusMessage = String(localized: "installed_epub_\(reader.title)")
            } else {
                statusMessage = String(localized: "installed_epub_\(identifier)")
            }
        } catch {
            statusMessage = localizedErrorMessage(error)
        }

        isInstallingEpub = false
    }

    /**
     Applies one confirmed Android BackupActivity reset category.

     - Parameter category: Reset category selected from the Reset Databases section.
     - Side effects:
       - mutates SwiftData/settings/file-backed repository state through `AndroidBackupResetService`
       - clears category-scoped remote-sync bookkeeping for sync-backed categories
       - updates `statusMessage` with success or failure text
     - Failure modes: Reset service errors are caught and surfaced with the shared error prefix.
     */
    private func resetDatabase(_ category: AndroidBackupResetCategory) {
        statusMessage = nil
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

    /**
     Returns the current date formatted for exported backup file names.
     */
    private func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /**
     Writes export data to a temporary file and returns its URL for sharing.

     - Parameters:
       - data: File contents to write.
       - fileName: Target filename appended within the temporary directory.
     - Returns: Temporary file URL on success, or `nil` after updating `statusMessage` on failure.
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
