// EpubSearchView.swift — Full-text search within an EPUB

import SwiftUI
import BibleCore

/// Search within the active EPUB using FTS5.
struct EpubSearchView: View {
    let reader: EpubReader
    let onSelectHref: (String) -> Void

    @State private var searchText = ""
    @State private var results: [(href: String, title: String, snippet: String)] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if !hasSearched {
                    ContentUnavailableView(
                        String(localized: "search_epub"),
                        systemImage: "magnifyingglass",
                        description: Text("Enter a search term to find text within \"\(reader.title)\".")
                    )
                } else if isSearching {
                    ProgressView(String(localized: "searching"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(results.indices, id: \.self) { index in
                        let result = results[index]
                        Button {
                            onSelectHref(result.href)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                Text(stripHTMLFromSnippet(result.snippet))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $searchText, prompt: String(localized: "epub_search_prompt"))
            .onSubmit(of: .search) {
                performSearch()
            }
            .navigationTitle("Search: \(reader.title)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
        }
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isSearching = true
        hasSearched = true

        results = reader.search(query: query)
        isSearching = false
    }

    private func stripHTMLFromSnippet(_ snippet: String) -> String {
        snippet.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
