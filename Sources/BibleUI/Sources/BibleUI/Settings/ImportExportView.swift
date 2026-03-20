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

    /// Controls presentation of the EPUB picker.
    @State private var showEpubPicker = false

    /// Whether an EPUB installation is currently in progress.
    @State private var isInstallingEpub = false

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
        if showEpubPicker {
            return "epubPickerPresented"
        }
        return "idle"
    }

    /**
     Builds the export, import, module-install, EPUB-install, and status sections.
     */
    public var body: some View {
        List {
            // Export section
            Section {
                Button {
                    exportFullBackup()
                } label: {
                    HStack {
                        SwiftUI.Label(String(localized: "full_backup_json"), systemImage: "arrow.up.doc")
                        Spacer()
                        if isExporting {
                            ProgressView()
                        }
                    }
                }
                .accessibilityIdentifier("importExportFullBackupButton")
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
            allowedContentTypes: [.json, .commaSeparatedText, .data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .fileImporter(
            isPresented: $showModuleZipPicker,
            allowedContentTypes: [.zip, .data],
            allowsMultipleSelection: false
        ) { result in
            handleModuleZipImport(result)
        }
        .fileImporter(
            isPresented: $showEpubPicker,
            allowedContentTypes: [.epub, .data],
            allowsMultipleSelection: false
        ) { result in
            handleEpubImport(result)
        }
    }

    /**
     Exports a full JSON backup, writes it to a temporary file, and presents the share sheet.

     Side effects:
     - toggles export state and clears prior status messages
     - queries `BackupService` for a full backup payload
     - writes the payload to a temporary file and presents the share sheet on success
     */
    private func exportFullBackup() {
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
     - `.bbl`, `.cmt`, `.dct`: MySword/MyBible hint only; no import is performed

     Side effects:
     - starts and stops security-scoped resource access for the chosen file
     - reads the imported file data and updates status text with success or error details
     - mutates persisted app data through `BackupService` for supported formats
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
            statusMessage = String(localized: "error_prefix_\(error.localizedDescription)")
        }
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
                statusMessage = String(localized: "error_prefix_\(error.localizedDescription)")
            }

            isInstallingModule = false

        case .failure(let error):
            statusMessage = String(localized: "error_prefix_\(error.localizedDescription)")
        }
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
                statusMessage = String(localized: "error_prefix_\(error.localizedDescription)")
            }

            isInstallingEpub = false

        case .failure(let error):
            statusMessage = String(localized: "error_prefix_\(error.localizedDescription)")
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
