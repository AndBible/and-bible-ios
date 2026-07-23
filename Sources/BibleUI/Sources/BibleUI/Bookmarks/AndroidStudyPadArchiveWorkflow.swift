// AndroidStudyPadArchiveWorkflow.swift -- Shared Manage Labels archive coordination

import BibleCore
import Foundation
import SwiftData
import SwiftUI

/** User-visible result emitted by the shared Study Pad archive workflow. */
struct AndroidStudyPadArchiveFeedback: Equatable {
    let title: String
    let message: String
}

/**
 Coordinates Android Study Pad export/import for every app-owned Manage Labels mode.

 Android exposes the same overflow commands from Study Pads, Workspace label management, and
 Assignment. This observable owner centralizes selection, background archive construction,
 security-scoped file staging, validation, confirmation, cleanup, and feedback so feature screens
 compose one behavior instead of copying orchestration around the canonical BibleCore service.

 Inputs: visible export labels, a model container/context, and optional import-applied callback

 Outputs: bindings consumed by the shared export/import dialogs and platform file handoff

 Side effects: creates/cleans temporary archives, reads a user-selected provider URL, applies one
 validated import through `AndroidStudyPadArchiveService`, and updates observable presentation state

 Failure modes: service/filesystem/provider failures become `feedback`; in-progress operations
 reject cancel/re-entry and retain their owning confirmation surface until cleanup finishes
 */
@MainActor
@Observable
final class AndroidStudyPadArchiveWorkflow {
    /// Export-label selection dialog state.
    var showsExportSelection = false
    var exportLabelIDs: Set<UUID> = []
    private(set) var isExporting = false

    /// Platform export destination state.
    private var preparedExport: AndroidStudyPadArchiveExport?
    var exportDocument = BackupExportDocument()
    var exportFileName = AndroidStudyPadArchiveService.multipleStudyPadsFileName
    var showsFileExporter = false

    /// Platform import source and app-owned confirmation state.
    var showsFileImporter = false
    private(set) var importInspection: AndroidStudyPadArchiveInspection?
    private(set) var isImporting = false

    /// Latest archive success/failure feedback.
    var feedback: AndroidStudyPadArchiveFeedback?

    /** Opens a fresh Android export multiselect. */
    func beginExport() {
        guard !isExporting, !isImporting else { return }
        exportLabelIDs = []
        showsExportSelection = true
    }

    /** Opens the platform source picker used by Android's import intent equivalent. */
    func beginImport() {
        guard !isExporting, !isImporting else { return }
        showsFileImporter = true
    }

    /**
     Builds the specialized Android archive for the current export selection.

     - Parameters:
       - labels: Canonically ordered export choices shown by the owner route.
       - modelContainer: Shared container used to create a background read context.
     - Side effects: Creates a temporary archive and opens the platform destination picker.
     - Failure modes: Empty/re-entrant requests are ignored; service errors become feedback.
     */
    func exportSelectedStudyPads(labels: [BibleCore.Label], modelContainer: ModelContainer) {
        guard !exportLabelIDs.isEmpty, !isExporting else { return }
        let selectedIDs = labels.map(\.id).filter(exportLabelIDs.contains)
        prepareExport(
            labelIDs: selectedIDs,
            modelContainer: modelContainer,
            closesSelection: true
        )
    }

    /**
     Builds Android's specialized archive for one exact Study Pad window.

     - Parameters:
       - labelID: Active Study Pad label captured by the window popup.
       - modelContainer: Shared persistence container used for background export.
     - Side effects: Creates a temporary archive and opens the same system destination handoff as
       Manage Labels export.
     - Failure modes: Re-entrant requests are ignored; archive failures become shared feedback.
     */
    func exportStudyPad(labelID: UUID, modelContainer: ModelContainer) {
        prepareExport(
            labelIDs: [labelID],
            modelContainer: modelContainer,
            closesSelection: false
        )
    }

    /** Shared archive preparation used by multiselect and exact-window export entry points. */
    private func prepareExport(
        labelIDs: [UUID],
        modelContainer: ModelContainer,
        closesSelection: Bool
    ) {
        guard !labelIDs.isEmpty, !isExporting, !isImporting else { return }
        isExporting = true

        Task { @MainActor in
            defer { isExporting = false }
            do {
                let export = try await Task.detached(priority: .userInitiated) {
                    try AndroidStudyPadArchiveService().exportArchiveFile(
                        labelIDs: labelIDs,
                        modelContext: ModelContext(modelContainer)
                    )
                }.value
                preparedExport = export
                exportDocument = BackupExportDocument(fileURL: export.fileURL)
                exportFileName = export.fileName
                if closesSelection {
                    showsExportSelection = false
                }
                showsFileExporter = true
            } catch {
                feedback = AndroidStudyPadArchiveFeedback(
                    title: String(localized: "error_occurred", defaultValue: "An error has occurred"),
                    message: error.localizedDescription
                )
            }
        }
    }

    /** Cancels export selection only while no archive write is active. */
    func dismissExportSelection() {
        guard !isExporting else { return }
        showsExportSelection = false
        exportLabelIDs = []
    }

    /** Cleans the temporary archive after the platform destination handoff completes. */
    func handleFileExportCompletion(_ result: Result<URL, Error>) {
        if let preparedExport {
            AndroidStudyPadArchiveService().cleanup(preparedExport)
            self.preparedExport = nil
        }
        exportDocument = BackupExportDocument()
        switch result {
        case .success:
            break
        case .failure(let error):
            feedback = AndroidStudyPadArchiveFeedback(
                title: String(localized: "error_occurred", defaultValue: "An error has occurred"),
                message: error.localizedDescription
            )
        }
    }

    /**
     Copies, validates, and stages one provider-selected Android archive.

     - Parameter result: Platform file-import selection result.
     - Side effects: Temporarily accesses/copies the provider URL and publishes an inspection.
     - Failure modes: Provider, staging, ZIP, and manifest errors become feedback.
     */
    func handleFileImportSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let selectedURL = urls.first else {
            if case .failure(let error) = result {
                feedback = AndroidStudyPadArchiveFeedback(
                    title: String(localized: "error_occurred", defaultValue: "An error has occurred"),
                    message: error.localizedDescription
                )
            }
            return
        }
        let scoped = selectedURL.startAccessingSecurityScopedResource()
        let stagedURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "study-pad-import-\(UUID().uuidString).abdb.zip"
        )

        Task { @MainActor in
            defer {
                if scoped { selectedURL.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: stagedURL)
            }
            do {
                importInspection = try await Task.detached(priority: .userInitiated) {
                    try AndroidModuleBackupArchiveFileStager.copy(from: selectedURL, to: stagedURL)
                    return try AndroidStudyPadArchiveService().inspectImport(at: stagedURL)
                }.value
            } catch {
                feedback = AndroidStudyPadArchiveFeedback(
                    title: String(localized: "error_occurred", defaultValue: "An error has occurred"),
                    message: error.localizedDescription
                )
            }
        }
    }

    /**
     Applies the staged specialized archive through the canonical merge service.

     - Parameters:
       - modelContext: Live context receiving the validated import.
       - onApplied: Owner callback used to refresh search/list projections after success.
     - Side effects: Applies bookmark/label/Study Pad data, cleans staging, and emits feedback.
     - Failure modes: Re-entry/no-inspection are ignored; merge failures become feedback.
     */
    func applyImport(modelContext: ModelContext, onApplied: @escaping () -> Void = {}) {
        guard let importInspection, !isImporting else { return }
        isImporting = true
        Task { @MainActor in
            let service = AndroidStudyPadArchiveService()
            defer {
                service.cleanup(importInspection)
                isImporting = false
                self.importInspection = nil
            }
            do {
                _ = try service.applyImport(importInspection, modelContext: modelContext)
                onApplied()
                feedback = AndroidStudyPadArchiveFeedback(
                    title: String(localized: "studypads", defaultValue: "Study Pads"),
                    message: String(
                        localized: "install_zip_successfull",
                        defaultValue: "Module was installed successfully"
                    )
                )
            } catch {
                feedback = AndroidStudyPadArchiveFeedback(
                    title: String(localized: "error_occurred", defaultValue: "An error has occurred"),
                    message: error.localizedDescription
                )
            }
        }
    }

    /** Cancels import confirmation and removes the staged archive. */
    func dismissImportInspection() {
        guard let importInspection, !isImporting else { return }
        AndroidStudyPadArchiveService().cleanup(importInspection)
        self.importInspection = nil
    }
}
