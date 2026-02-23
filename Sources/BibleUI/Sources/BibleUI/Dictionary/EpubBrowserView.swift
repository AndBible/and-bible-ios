// EpubBrowserView.swift — Table of Contents browser for EPUB files

import SwiftUI
import BibleCore

/// Displays the table of contents for an EPUB file.
/// Tap an entry to navigate to that section.
struct EpubBrowserView: View {
    let reader: EpubReader
    let onSelectHref: (String) -> Void

    @State private var tocEntries: [EpubReader.TOCEntry] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

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
                            onSelectHref(entry.href)
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
