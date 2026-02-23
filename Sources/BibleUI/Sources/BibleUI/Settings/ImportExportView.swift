// ImportExportView.swift — Import/Export settings screen

import SwiftUI
import SwiftData
import BibleCore
import SwordKit
import UniformTypeIdentifiers

/// Import and export app data (bookmarks, labels, reading plans, notes).
public struct ImportExportView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var showExportSheet = false
    @State private var showImportPicker = false
    @State private var exportedFileURL: URL?
    @State private var statusMessage: String?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var showModuleZipPicker = false
    @State private var isInstallingModule = false
    @State private var showEpubPicker = false
    @State private var isInstallingEpub = false

    public init() {}

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

    // MARK: - Export

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

    // MARK: - Import

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

    // MARK: - Module ZIP Import

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

    // MARK: - EPUB Import

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

    // MARK: - Helpers

    private func dateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

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
