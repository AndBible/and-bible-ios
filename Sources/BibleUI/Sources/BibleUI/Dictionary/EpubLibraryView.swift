// EpubLibraryView.swift — Lists all installed EPUB files

import SwiftUI
import BibleCore

/// Lists all installed EPUB files for selection.
struct EpubLibraryView: View {
    let onSelectEpub: (String) -> Void

    @State private var epubs: [EpubInfo] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(String(localized: "epub_loading_library"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if epubs.isEmpty {
                    ContentUnavailableView(
                        String(localized: "epub_no_epubs_installed"),
                        systemImage: "book",
                        description: Text(String(localized: "epub_no_epubs_installed_description"))
                    )
                } else {
                    List {
                        ForEach(epubs, id: \.identifier) { epub in
                            Button {
                                onSelectEpub(epub.identifier)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(epub.title)
                                        .font(.headline)
                                        .lineLimit(2)
                                    if !epub.author.isEmpty {
                                        Text(epub.author)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: deleteEpubs)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(String(localized: "epub_library"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .task {
                epubs = EpubReader.installedEpubs()
                isLoading = false
            }
        }
    }

    private func deleteEpubs(at offsets: IndexSet) {
        for index in offsets {
            let epub = epubs[index]
            EpubReader.delete(identifier: epub.identifier)
        }
        epubs.remove(atOffsets: offsets)
    }
}
