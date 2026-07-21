// EpubBrowserView.swift — Table of Contents browser for EPUB files

import SwiftUI
import BibleCore

/**
 Table-of-contents browser for one installed EPUB.

 The view loads TOC entries from the selected `EpubReader` and lets the caller navigate with the
 numeric general-book key Android persists.

 Data dependencies:
 - `reader` provides EPUB metadata and TOC entries
 - `onSelectKey` notifies the parent when the user chooses one TOC target

 Side effects:
 - loads the TOC when the view appears
 - dismisses the browser when the toolbar Done action is used
 */
struct EpubBrowserView: View {
    /// Reader for the EPUB whose TOC is being browsed.
    let reader: EpubReader

    /// Callback invoked when the user chooses a numeric/composite general-book key.
    let onSelectKey: (String) -> Void

    /// Loaded table-of-contents entries for the EPUB.
    @State private var tocEntries: [EpubReader.TOCEntry] = []

    /// Whether the TOC is still loading.
    @State private var isLoading = true

    /// Dismiss action for closing the TOC browser.
    @Environment(\.dismiss) private var dismiss

    /**
     Builds the loading state, empty state, or TOC list for the EPUB.
     */
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(String(localized: "epub_loading_toc"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tocEntries.isEmpty {
                    ContentUnavailableView(
                        String(localized: "epub_no_toc"),
                        systemImage: "book.closed",
                        description: Text(String(localized: "epub_no_toc_description"))
                    )
                } else {
                    List(tocEntries, id: \.ordinal) { entry in
                        Button {
                            onSelectKey(entry.key)
                        } label: {
                            Text(entry.title)
                                .lineLimit(2)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(reader.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .task {
                let entries = reader.tableOfContents()
                tocEntries = entries
                isLoading = false
            }
        }
    }
}
