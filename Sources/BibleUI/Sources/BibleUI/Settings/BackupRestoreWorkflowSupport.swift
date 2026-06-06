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
     - Side effects: Reads from the temporary file for file-backed payloads; SwiftUI performs the
       actual destination write.
     - Failure modes: Rethrows file-wrapper creation failures for missing or unreadable temporary
       files.
     */
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        switch content {
        case .data(let data):
            return FileWrapper(regularFileWithContents: data)
        case .file(let fileURL):
            return try FileWrapper(url: fileURL, options: .immediate)
        }
    }
}

/**
 Android-style radio row used by the Backup & Restore workflow.

 The row is implemented as a button so the whole line toggles the selection, matching Android's
 wide radio-row affordance while staying native SwiftUI.
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

    /// Accessibility identifier assigned to the row button.
    let accessibilityIdentifier: String

    /**
     Builds one radio row.

     - Side effects: Mutates the bound selection when the row is tapped.
     - Failure modes: This view does not throw; accessibility state follows the bound selection.
     */
    var body: some View {
        Button {
            selection = value
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selection == value ? "largecircle.fill.circle" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
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
