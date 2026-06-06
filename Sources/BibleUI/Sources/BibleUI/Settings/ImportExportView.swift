// ImportExportView.swift — Import/Export settings screen

import SwiftUI
import SwiftData
import BibleCore
import SwordKit
import UniformTypeIdentifiers

/**
 Settings screen for exporting backups, importing backups, installing SWORD modules, and importing EPUB books.

 The view coordinates file export to temporary files, file-importer presentation, security-scoped
 resource access, and dispatch to the relevant backup or installer service.

 Data dependencies:
 - `modelContext` is passed into `BackupService` for backup import/export operations

 Side effects:
 - export actions write temporary files and present a share sheet
 - import actions read user-selected files through `fileImporter` and mutate app data through
   backup/import services
 - module and EPUB install actions import external content into the app's storage locations
 - status text reflects the latest success or failure message across all operations
 */
public struct ImportExportView: View {
    /// SwiftData context used by backup import/export services.
    @Environment(\.modelContext) private var modelContext

    /// Controls presentation of the share sheet after a successful export.
    @State private var showExportSheet = false

    /// Controls presentation of the backup import file picker.
    @State private var showImportPicker = false

    /// URL of the most recently exported file shared through the share sheet.
    @State private var exportedFileURL: URL?

    /// Latest user-visible success or error message across import/export actions.
    @State private var statusMessage: String?

    /// Whether a backup export is currently in progress.
    @State private var isExporting = false

    /// Whether a backup import is currently in progress.
    @State private var isImporting = false

    /// Controls presentation of the SWORD module ZIP picker.
    @State private var showModuleZipPicker = false

    /// Whether a SWORD module installation is currently in progress.
    @State private var isInstallingModule = false

    /// Controls presentation of the Android module backup picker.
    @State private var showAndroidModuleBackupPicker = false

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

    /// Controls presentation of the EPUB picker.
    @State private var showEpubPicker = false

    /// Whether an EPUB installation is currently in progress.
    @State private var isInstallingEpub = false

    /// Android database backup archive currently staged for category selection.
    @State private var androidBackupArchive: AndroidDatabaseBackupArchive?

    /// Last archive presented by the sheet, retained until dismissal cleanup runs.
    @State private var androidBackupArchivePendingCleanup: AndroidDatabaseBackupArchive?

    /// Whether selected Android backup sections are currently being applied.
    @State private var isApplyingAndroidBackup = false

    /// Service used to export, load, apply, and clean up Android `.abdb.zip` database backups.
    private let androidBackupService = AndroidDatabaseBackupService()

    /// Service used to inspect, restore, and export Android `.abmd.zip` module backups.
    private let androidModuleBackupService = AndroidModuleBackupService()

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
        if showExportSheet {
            return "shareSheetPresented"
        }
        if showImportPicker {
            return "importPickerPresented"
        }
        if showModuleZipPicker {
            return "moduleZipPickerPresented"
        }
        if showAndroidModuleBackupPicker {
            return "androidModuleBackupPickerPresented"
        }
        if showAndroidModuleBackupExportSheet {
            return "androidModuleBackupExportPresented"
        }
        if showEpubPicker {
            return "epubPickerPresented"
        }
        if androidBackupArchive != nil {
            return "androidBackupImportPresented"
        }
        return "idle"
    }

    /**
     Builds the export, import, module-install, EPUB-install, and status sections.
     */
    public var body: some View {
        List {
            Section {
                Button {
                    exportAndroidDatabaseBackup()
                } label: {
                    HStack {
                        SwiftUI.Label(
                            String(localized: "android_database_backup", defaultValue: "Android Database Backup"),
                            systemImage: "archivebox.fill"
                        )
                        Spacer()
                        if isExporting {
                            ProgressView()
                        }
                    }
                }
                .accessibilityIdentifier("importExportAndroidDatabaseBackupButton")
                .disabled(isExporting)

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
            } header: {
                Text(String(localized: "export"))
            } footer: {
                Text(String(localized: "export_footer"))
            }

            // Import section
            Section {
                Button {
                    showImportPicker = true
                } label: {
                    HStack {
                        SwiftUI.Label(String(localized: "import_from_file"), systemImage: "arrow.down.doc")
                        Spacer()
                        if isImporting {
                            ProgressView()
                        }
                    }
                }
                .accessibilityIdentifier("importExportImportButton")
                .disabled(isImporting)
            } header: {
                Text(String(localized: "import"))
            } footer: {
                Text(String(localized: "import_footer"))
            }

            // SWORD module install section
            Section {
                Button {
                    showModuleZipPicker = true
                } label: {
                    HStack {
                        SwiftUI.Label(String(localized: "install_sword_module"), systemImage: "shippingbox")
                        Spacer()
                        if isInstallingModule {
                            ProgressView()
                        }
                    }
                }
                .disabled(isInstallingModule)

                Button {
                    showAndroidModuleBackupPicker = true
                } label: {
                    HStack {
                        SwiftUI.Label(
                            String(localized: "restore_android_module_backup", defaultValue: "Restore Android Module Backup"),
                            systemImage: "archivebox"
                        )
                        Spacer()
                        if isRestoringAndroidModuleBackup {
                            ProgressView()
                        }
                    }
                }
                .disabled(isRestoringAndroidModuleBackup)

                Button {
                    presentAndroidModuleBackupExportSelection()
                } label: {
                    HStack {
                        SwiftUI.Label(
                            String(localized: "export_android_module_backup", defaultValue: "Export Android Module Backup"),
                            systemImage: "archivebox.fill"
                        )
                        Spacer()
                        if isExportingAndroidModuleBackup {
                            ProgressView()
                        }
                    }
                }
                .disabled(isExportingAndroidModuleBackup)
            } header: {
                Text(String(localized: "modules"))
            } footer: {
                Text(String(localized: "modules_footer"))
            }

            // EPUB import section
            Section {
                Button {
                    showEpubPicker = true
                } label: {
                    HStack {
                        SwiftUI.Label(String(localized: "install_epub_book"), systemImage: "book")
                        Spacer()
                        if isInstallingEpub {
                            ProgressView()
                        }
                    }
                }
                .disabled(isInstallingEpub)
            } header: {
                Text(String(localized: "epub"))
            } footer: {
                Text(String(localized: "epub_footer"))
            }

            // Status
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
        .navigationTitle(String(localized: "import_export"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showExportSheet) {
            if let url = exportedFileURL {
                ShareSheet(items: [url])
            }
        }
        .fileImporter(
            isPresented: $showImportPicker,
            allowedContentTypes: [.json, .commaSeparatedText, .zip, .data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
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
            isPresented: $showModuleZipPicker,
            allowedContentTypes: [.zip, .data],
            allowsMultipleSelection: false
        ) { result in
            handleModuleZipImport(result)
        }
        .fileImporter(
            isPresented: $showAndroidModuleBackupPicker,
            allowedContentTypes: [.zip, .data],
            allowsMultipleSelection: false
        ) { result in
            handleAndroidModuleBackupImport(result)
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
            isPresented: $showEpubPicker,
            allowedContentTypes: [.epub, .data],
            allowsMultipleSelection: false
        ) { result in
            handleEpubImport(result)
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
     Exports an Android-compatible database backup and presents the share sheet.

     This is the parity backup path: Android expects `AndBibleDatabaseBackup.abdb.zip` containing
     `AndBibleBackupManifest.json` and supported category SQLite databases under `db/`.

     - Side effects:
       - toggles export state and clears prior status messages
       - reads SwiftData through `AndroidDatabaseBackupService`
       - writes the generated archive to a temporary file and presents the share sheet on success
       - updates status text with the categories included in the backup
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
            if let url = saveToTempFile(data: export.data, fileName: export.fileName) {
                exportedFileURL = url
                showExportSheet = true
                let categorySummary = export.categories
                    .map(\.localizedBackupSectionName)
                    .joined(separator: ", ")
                statusMessage = String(
                    localized: "android_database_backup_exported_summary",
                    defaultValue: "Exported Android database backup: \(categorySummary)"
                )
            }
        } catch {
            statusMessage = localizedErrorMessage(error)
        }

        isExporting = false
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
     Handles backup/bookmark import results from the generic file importer.

     Supported formats:
     - `.json`: full backup import via `BackupService.importFullBackup`
     - `.csv`: bookmark import via `BackupService.importBookmarksCSV`
     - `.abdb.zip`: Android database backup staging via `AndroidDatabaseBackupService`
     - `.abmd.zip`: Android module backup restore via `AndroidModuleBackupService`
     - `.bbl`, `.cmt`, `.dct`: MySword/MyBible hint only; no import is performed

     Side effects:
     - starts and stops security-scoped resource access for the chosen file
     - reads the imported file data and updates status text with success or error details
     - mutates persisted app data through `BackupService` for supported formats
     - stages Android backup SQLite files in a temporary directory before presenting section choice
     */
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            statusMessage = nil

            // Start accessing security-scoped resource
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            guard let data = try? Data(contentsOf: url) else {
                statusMessage = String(localized: "error_read_file")
                isImporting = false
                return
            }

            let ext = url.pathExtension.lowercased()
            if isAndroidDatabaseBackupFile(url) {
                loadAndroidBackupArchive(from: data)
                isImporting = false
                return
            }
            if AndroidModuleBackupService.isAndroidModuleBackupFileName(url.lastPathComponent) {
                prepareAndroidModuleBackupRestore(from: data)
                isImporting = false
                return
            }

            let service = BackupService(modelContext: modelContext)

            switch ext {
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

            case "bbl", "cmt", "dct":
                statusMessage = String(localized: "mysword_file_hint")

            default:
                statusMessage = String(localized: "error_unsupported_format_\(ext)")
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
     Handles SWORD module ZIP import results from the file importer.

     Side effects:
     - starts and stops security-scoped resource access for the chosen ZIP file
     - installs the module through `ModuleRepository`
     - updates status text with the installed module name or any failure message
     */
    private func handleModuleZipImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isInstallingModule = true
            statusMessage = nil

            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let repo = ModuleRepository()
                let moduleName = try repo.installFromZip(at: url)
                statusMessage = String(localized: "installed_module_\(moduleName)")
            } catch {
                statusMessage = localizedErrorMessage(error)
            }

            isInstallingModule = false

        case .failure(let error):
            statusMessage = localizedErrorMessage(error)
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
       - reads local SWORD module config and data files
       - writes the generated backup to a temporary file
       - dismisses the selection sheet and schedules the share sheet after SwiftUI processes
         dismissal, avoiding two active sheet presentations at once
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
            if let url = saveToTempFile(data: export.data, fileName: export.fileName) {
                exportedFileURL = url
                showAndroidModuleBackupExportSheet = false
                androidModuleBackupExportModules = []
                Task { @MainActor in
                    await Task.yield()
                    showExportSheet = true
                }
                statusMessage = String(
                    localized: "android_module_backup_exported_summary",
                    defaultValue: "Exported Android module backup: \(export.moduleNames.joined(separator: ", "))"
                )
            }
        } catch {
            statusMessage = localizedErrorMessage(error)
        }
        isExportingAndroidModuleBackup = false
    }

    /**
     Handles Android module backup import results from the module-backup file picker.

     Side effects:
     - starts and stops security-scoped resource access for the chosen archive
     - inspects the archive before writing files
     - either restores immediately or shows an overwrite confirmation for existing module files
     - updates status text with success or failure details
     */
    private func handleAndroidModuleBackupImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isRestoringAndroidModuleBackup = true
            statusMessage = nil

            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let data = try Data(contentsOf: url)
                prepareAndroidModuleBackupRestore(from: data)
            } catch {
                statusMessage = localizedErrorMessage(error)
            }
            if !showAndroidModuleBackupOverwriteAlert {
                isRestoringAndroidModuleBackup = false
            }

        case .failure(let error):
            statusMessage = localizedErrorMessage(error)
        }
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
     Handles EPUB import results from the file importer.

     Side effects:
     - installs the selected EPUB through `EpubReader.install`
     - resolves the installed reader title when possible for a friendlier success message
     - updates status text with the final success or failure message
     */
    private func handleEpubImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
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

        case .failure(let error):
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
