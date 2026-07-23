// AndroidBookmarkCSVExportWorkflow.swift -- Shared Android bookmark CSV export coordination

import BibleCore
import Foundation
import Observation
import SwiftData

/** User-visible terminal feedback from Android's bookmark CSV export flow. */
struct AndroidBookmarkCSVExportFeedback: Equatable {
    /// Localized decision-dialog title.
    let title: String

    /// Localized success or failure detail.
    let message: String
}

/**
 Owns Android's reusable bookmark CSV column-selection and file-destination workflow.

 Android routes both Bookmark list export and Study Pad window export through
 `BookmarkControl.exportBookmarksToCSV`: restore the persisted columns, show one app-owned column
 chooser, encode the exact caller-provided Bible bookmarks, then hand the immutable CSV to the
 platform document destination. Keeping that sequence here prevents reader-window export from
 recreating a second chooser, filename policy, or preference contract.

 Inputs: an exact ordered Bible-bookmark subset and the owning SwiftData context

 Outputs: observable app-owned chooser state, one immutable file document, and terminal feedback

 Side effects: reads/writes the unchecked-column preference and opens a system file destination
 through bindings owned by the composing view

 Failure modes: empty subsets and codec/file handoff failures become localized feedback; invalid
 persisted column names are ignored and no partial CSV is published
 */
@MainActor
@Observable
final class AndroidBookmarkCSVExportWorkflow {
    /// Columns currently selected in Android's app-owned multiselect dialog.
    var selectedColumns = Set(AndroidBookmarkCSVColumn.allCases)

    /// Whether the shared app-owned column selector is visible.
    var showsColumnSelector = false

    /// Whether the platform destination handoff is visible.
    var showsFileExporter = false

    /// Immutable encoded CSV handed to SwiftUI's file exporter.
    private(set) var exportDocument: BookmarkCSVTransferDocument?

    /// Latest success/failure/empty-selection outcome.
    var feedback: AndroidBookmarkCSVExportFeedback?

    /// Exact caller-owned bookmark subset retained only for the active export sequence.
    private var bookmarks: [BibleBookmark] = []

    /**
     Starts Android's shared column-selection sequence for one exact bookmark subset.

     - Parameters:
       - bookmarks: Ordered Bible bookmarks selected by the owning screen or Study Pad label.
       - modelContext: Context owning the durable unchecked-column preference.
     - Side effects: Restores column preferences and opens the app-owned selector.
     - Failure modes: Empty subsets publish Android's no-bookmarks feedback without opening UI.
     */
    func beginExport(bookmarks: [BibleBookmark], modelContext: ModelContext) {
        guard !showsColumnSelector, !showsFileExporter else { return }
        guard !bookmarks.isEmpty else {
            feedback = AndroidBookmarkCSVExportFeedback(
                title: String(localized: "bookmarks", defaultValue: "Bookmarks"),
                message: String(
                    localized: "no_bookmarks_to_export",
                    defaultValue: "No bookmarks to export"
                )
            )
            return
        }
        self.bookmarks = bookmarks
        let settings = SettingsStore(modelContext: modelContext)
        let unchecked = Set(settings.getStringSet(.bookmarkCSVUncheckedColumns))
        selectedColumns = Set(AndroidBookmarkCSVColumn.allCases.filter {
            !unchecked.contains($0.rawValue)
        })
        showsColumnSelector = true
    }

    /** Cancels the app-owned chooser and releases the pending source subset. */
    func cancelColumnSelection() {
        showsColumnSelector = false
        bookmarks = []
    }

    /**
     Encodes the pending subset after one explicit app-owned column choice.

     - Parameters:
       - columns: Exact columns selected by the user.
       - modelContext: Context receiving Android's unchecked-column preference.
     - Side effects: Persists preferences, creates an immutable CSV document, and opens the system
       destination handoff.
     - Failure modes: Empty/invalid columns or untrusted bookmark ordinals publish feedback and do
       not open the destination picker.
     */
    func prepareExport(
        columns: Set<AndroidBookmarkCSVColumn>,
        modelContext: ModelContext
    ) {
        selectedColumns = columns
        let unchecked = AndroidBookmarkCSVColumn.allCases
            .filter { !columns.contains($0) }
            .map(\.rawValue)
        SettingsStore(modelContext: modelContext).setStringSet(
            .bookmarkCSVUncheckedColumns,
            values: unchecked
        )

        do {
            exportDocument = BookmarkCSVTransferDocument(
                data: try AndroidBookmarkCSVCodec.encode(
                    bookmarks: bookmarks,
                    selectedColumns: columns
                )
            )
            showsColumnSelector = false
            showsFileExporter = true
        } catch {
            showsColumnSelector = false
            bookmarks = []
            feedback = AndroidBookmarkCSVExportFeedback(
                title: String(localized: "error_occurred", defaultValue: "Error"),
                message: error.localizedDescription
            )
        }
    }

    /**
     Resolves the platform destination handoff and releases immutable export state.

     - Parameter result: File-export completion from SwiftUI.
     - Side effects: Publishes localized feedback and clears pending bookmark/document state.
     - Failure modes: Provider errors remain visible; a successful handoff reports the exact count.
     */
    func handleFileExportCompletion(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            feedback = AndroidBookmarkCSVExportFeedback(
                title: String(localized: "success", defaultValue: "Success"),
                message: String.localizedStringWithFormat(
                    String(
                        localized: "csv_export_success",
                        defaultValue: "Exported %ld bookmarks to CSV"
                    ),
                    bookmarks.count
                )
            )
        case .failure(let error):
            feedback = AndroidBookmarkCSVExportFeedback(
                title: String(localized: "error_occurred", defaultValue: "Error"),
                message: error.localizedDescription
            )
        }
        exportDocument = nil
        bookmarks = []
    }

    /// Timestamped filename matching `BookmarkControl.exportBookmarksToCSV`.
    var exportFileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return "bible_bookmarks_\(formatter.string(from: Date())).csv"
    }
}
