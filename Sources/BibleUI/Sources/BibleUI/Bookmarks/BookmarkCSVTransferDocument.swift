// BookmarkCSVTransferDocument.swift -- SwiftUI file transfer surfaces for bookmark CSV

import BibleCore
import SwiftUI
import UniformTypeIdentifiers

/** File document passed to SwiftUI's export picker for Android bookmark CSV bytes. */
struct BookmarkCSVTransferDocument: FileDocument {
    /// CSV and plain-text types accepted by Android's importer.
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .plainText]

    /// Immutable UTF-8 CSV payload.
    let data: Data

    /** Creates an export document from already-encoded CSV bytes. */
    init(data: Data) {
        self.data = data
    }

    /**
     Reads bytes supplied by SwiftUI's document infrastructure.

     - Parameter configuration: File wrapper selected by the user.
     - Side effects: Reads the regular-file payload into memory.
     - Throws: Cocoa file errors when the selected wrapper has no regular-file contents.
     */
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    /**
     Supplies the immutable CSV bytes to the destination selected by the user.

     - Parameter configuration: Export request from SwiftUI.
     - Returns: Regular-file wrapper containing the CSV payload.
     - Side effects: None; SwiftUI performs the actual destination write.
     - Failure modes: This in-memory wrapper construction cannot fail.
     */
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/** Android `Dialogs.multiselect`-equivalent column selector shown before the system export handoff. */
struct BookmarkCSVColumnSelectionView: View {
    /// Current appearance used by the shared Android dialog window.
    @Environment(\.colorScheme) private var colorScheme

    /// Draft selection that commits only when Android's positive action is chosen.
    @State private var selectedColumns: Set<AndroidBookmarkCSVColumn>

    /// Called after the user confirms at least one selected column.
    let onExport: (Set<AndroidBookmarkCSVColumn>) -> Void

    /// Called when the user dismisses without exporting.
    let onCancel: () -> Void

    /** Creates a dialog draft from the presenting list's persisted selection. */
    init(
        selectedColumns: Set<AndroidBookmarkCSVColumn>,
        onExport: @escaping (Set<AndroidBookmarkCSVColumn>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _selectedColumns = State(initialValue: selectedColumns)
        self.onExport = onExport
        self.onCancel = onCancel
    }

    /** Builds Android's app-owned multi-select dialog without a generic SwiftUI sheet. */
    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "androidBookmarkCSVColumnDialog",
            onOutsideTap: onCancel
        ) {
            AndroidMultiselectDialogContent(
                title: String(
                    localized: "csv_column_selection_title",
                    defaultValue: "Select CSV Columns"
                ),
                rows: AndroidBookmarkCSVColumn.allCases.map { column in
                    AndroidMultiselectDialogRow(
                        id: column,
                        title: column.displayName,
                        accessibilityIdentifier: "bookmarkCSVColumnToggle::\(column.rawValue)"
                    )
                },
                selectedIDs: $selectedColumns,
                isBusy: false,
                accessibilityIdentifier: "androidBookmarkCSVColumnDialogContent",
                accessibilityPrefix: "bookmarkCSVColumn",
                onCancel: onCancel,
                onConfirm: { onExport(Set($0)) }
            )
        }
    }
}

/** User-visible localized names for Android bookmark CSV columns. */
private extension AndroidBookmarkCSVColumn {
    /// Localized column label shown in the export selector.
    var displayName: String {
        switch self {
        case .osisReference: return String(localized: "osis_reference", defaultValue: "OSIS reference")
        case .bibleReference: return String(localized: "bible_reference", defaultValue: "Bible reference")
        case .document: return String(localized: "document", defaultValue: "Document")
        case .book: return String(localized: "book", defaultValue: "Book")
        case .chapterStart: return String(localized: "chapter_start", defaultValue: "Start chapter")
        case .verseStart: return String(localized: "verse_start", defaultValue: "Start verse")
        case .chapterEnd: return String(localized: "chapter_end", defaultValue: "End chapter")
        case .verseEnd: return String(localized: "verse_end", defaultValue: "End verse")
        case .id: return String(localized: "id", defaultValue: "ID")
        case .ordinalStart: return String(localized: "ordinal_start", defaultValue: "Start ordinal")
        case .ordinalEnd: return String(localized: "ordinal_end", defaultValue: "End ordinal")
        case .createdAt: return String(localized: "created_at", defaultValue: "Created at")
        case .lastUpdatedOn: return String(localized: "last_updated_at", defaultValue: "Last updated")
        case .startOffset: return String(localized: "start_offset", defaultValue: "Start offset")
        case .endOffset: return String(localized: "end_offset", defaultValue: "End offset")
        case .labels: return String(localized: "labels", defaultValue: "Labels")
        case .notes: return String(localized: "bookmark_notes", defaultValue: "Notes")
        case .customIcon: return String(localized: "custom_icon", defaultValue: "Custom icon")
        }
    }
}
