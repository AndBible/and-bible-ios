// BackupRestoreWorkflowSupport.swift -- Android BackupActivity presentation helpers

import BibleCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/**
 Backup targets shown by Android's BackupActivity.

 The cases intentionally mirror Android's radio group order: Database, Documents, Application.
 iOS can only implement application backup as a documented platform deviation because installed
 iOS app bundles cannot be exported by the app at runtime the way Android exports an APK.
 */
enum BackupWorkflowTarget: String, CaseIterable, Identifiable {
    /// Bookmarks, labels, notes, StudyPads, reading plans, workspaces, and related databases.
    case database

    /// Installed Bible/commentary/dictionary/map modules and EPUB-like document content.
    case documents

    /// Android APK backup target; unavailable as a real iOS export target.
    case application

    /// Stable SwiftUI identifier.
    var id: String { rawValue }

    /// Title shown beside the radio control.
    var localizedTitle: String {
        switch self {
        case .database:
            return String(localized: "backup_database", defaultValue: "Database")
        case .documents:
            return String(localized: "backup_documents", defaultValue: "Documents")
        case .application:
            return String(localized: "backup_application", defaultValue: "Application")
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
        case .application:
            return String(localized: "backup_application_info", defaultValue: "Application file (.APK)")
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
    /// Raw backup archive bytes.
    let data: Data

    /// Android-compatible default file name.
    let fileName: String

    /// Completion message to show after a destination is selected.
    let statusMessage: String
}

/**
 Minimal `FileDocument` wrapper for exporting Android-compatible backup archives.

 The document is write-only for this workflow. A permissive read initializer is still supplied
 because SwiftUI's `FileDocument` protocol requires it, but the import path never constructs this
 type from user-selected files.
 */
struct BackupExportDocument: FileDocument {
    /// The exporter writes ZIP archives, including Android's compound `.abdb.zip` and `.abmd.zip` names.
    static var readableContentTypes: [UTType] { [.zip, .data] }

    /// Raw file bytes written by `fileWrapper(configuration:)`.
    var data: Data

    /**
     Creates a document from generated backup bytes.

     - Parameter data: Archive bytes to write.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    init(data: Data = Data()) {
        self.data = data
    }

    /**
     Creates a document from a file-import configuration to satisfy `FileDocument`.

     - Parameter configuration: SwiftUI read configuration.
     - Side effects: Reads in-memory file wrapper contents when SwiftUI invokes this path.
     - Failure modes: Missing regular-file contents produce an empty document because this app does
       not use `BackupExportDocument` for importing.
     */
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    /**
     Produces the file wrapper written by SwiftUI's exporter.

     - Parameter configuration: SwiftUI write configuration.
     - Returns: A regular file wrapper containing `data`.
     - Side effects: none; SwiftUI performs the actual file-system write.
     - Failure modes: This implementation does not throw.
     */
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
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
