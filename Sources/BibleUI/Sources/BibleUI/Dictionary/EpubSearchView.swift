// EpubSearchView.swift — Full-text search within an EPUB

import SwiftUI
import BibleCore

/**
 Full-text search screen for one EPUB book.

 The view delegates searches to `EpubReader` and presents typed BVA-anchor hits for in-book
 navigation.

 Data dependencies:
 - `reader` provides the book metadata and executes the EPUB search query
 - `modePreferences` restores and saves Android's exact EPUB search-mode preference
 - `onSelectResult` notifies the parent when the user chooses a matching key/ordinal

 Side effects:
 - submitting the search field mutates search state and runs an EPUB search
 - dismisses the search screen when the toolbar Done action is used
 */
struct EpubSearchView: View {
    /// Reader for the EPUB currently being searched.
    let reader: EpubReader

    /// Android-compatible persisted EPUB search-mode adapter.
    let modePreferences: SearchModePreferences

    /// Callback invoked when the user chooses a matching BVA anchor.
    let onSelectResult: (EpubReader.SearchResult) -> Void

    /// Current query text bound to the searchable field.
    @State private var searchText = ""

    /// Current anchor-level EPUB search results.
    @State private var results: [EpubReader.SearchResult] = []

    /// Android EPUB Search's phrase/all/any/raw-FTS selection.
    @State private var searchMode: EpubSearchMode

    /// Whether an EPUB search is currently in progress.
    @State private var isSearching = false

    /// Whether the user has executed at least one search in this session.
    @State private var hasSearched = false

    /// Explicit compiler/index failure, distinct from a valid zero-result search.
    @State private var searchFailureMessage: String?

    /// Dismiss action for closing the EPUB search screen.
    @Environment(\.dismiss) private var dismiss

    /**
     Creates one EPUB search screen with Android-compatible persisted mode state.

     - Parameters:
       - reader: Immutable EPUB generation to search.
       - modePreferences: Shared preference adapter for the exact Android search-mode contract.
       - onSelectResult: Navigation callback for a selected anchor hit.
     - Side effects: Reads the current search mode from app settings during view initialization.
     - Failure modes: Missing or unknown settings select Android's raw FTS mode.
     */
    init(
        reader: EpubReader,
        modePreferences: SearchModePreferences,
        onSelectResult: @escaping (EpubReader.SearchResult) -> Void
    ) {
        self.reader = reader
        self.modePreferences = modePreferences
        self.onSelectResult = onSelectResult
        _searchMode = State(initialValue: modePreferences.epubMode())
    }

    /**
     Builds the pre-search prompt, loading state, empty-result state, or result list.
     */
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchModePicker
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                Divider()

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
                    } else if let searchFailureMessage {
                        ContentUnavailableView(
                            String(localized: "error_executing_search", defaultValue: "Search failed"),
                            systemImage: "exclamationmark.magnifyingglass",
                            description: Text(searchFailureMessage)
                        )
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        List(results.indices, id: \.self) { index in
                            let result = results[index]
                            Button {
                                onSelectResult(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.title)
                                        .font(.headline)
                                        .lineLimit(1)
                                    highlightedSnippet(result.snippetSegments)
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
            }
            .searchable(text: $searchText, prompt: String(localized: "epub_search_prompt"))
            .onSubmit(of: .search) {
                performSearch()
            }
            .onChange(of: searchMode) { _, mode in
                modePreferences.saveEpubMode(mode)
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

    /** Android EPUB Search's four mutually exclusive word/query modes. */
    private var searchModePicker: some View {
        Picker(
            String(localized: "search_words_group_prompt", defaultValue: "Words"),
            selection: $searchMode
        ) {
            Text(String(localized: "search_all_words", defaultValue: "All"))
                .tag(EpubSearchMode.allWords)
            Text(String(localized: "search_any_word", defaultValue: "Any"))
                .tag(EpubSearchMode.anyWords)
            Text(String(localized: "search_phrase", defaultValue: "Phrase"))
                .tag(EpubSearchMode.phrase)
            Text(String(localized: "search_fts_query", defaultValue: "FTS"))
                .tag(EpubSearchMode.fullTextQuery)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("epubSearchModePicker")
    }

    /**
     Executes the trimmed EPUB query and updates view state with the resulting hits.

     Failure modes:
     - returns without searching when the trimmed query is empty
     - compiler, analyzer, and SQLite failures populate `searchFailureMessage`
     - zero-hit searches are a valid outcome and leave `results` empty
     */
    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isSearching = true
        hasSearched = true
        searchFailureMessage = nil
        do {
            results = try reader.searchResults(query: query, epubMode: searchMode)
        } catch {
            results = []
            searchFailureMessage = error.localizedDescription
        }
        isSearching = false
    }

    /**
     Builds a SwiftUI `Text` from source-preserving, trust-typed search segments.

     - Parameter segments: Plain source runs emitted by `EpubReader`, with emphasis derived only
       from per-request SQLite marker positions.
     - Returns: Original EPUB text with matched runs bolded.
     - Side effects: None.
     - Failure modes: Empty segments render empty text; authored markup remains literal text.
     */
    private func highlightedSnippet(_ segments: [EpubSearchSnippetSegment]) -> Text {
        segments.reduce(Text("")) { result, segment in
            result + Text(segment.text).fontWeight(segment.isEmphasized ? .bold : .regular)
        }
    }
}
