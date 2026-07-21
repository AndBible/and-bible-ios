// DictionaryBrowserView.swift — Searchable key browser for dictionary/lexicon modules

import SwiftUI
import SwordKit

/**
 Searchable key browser for dictionary and lexicon modules.

 The view loads every key from one captured SWORD or SQLite source, keeps them in memory, and filters
 the list locally as the user types. This mirrors Android's `ChooseDictionaryWord` flow.

 Data dependencies:
 - `source` is the selected dictionary snapshot whose exact keys should be listed
 - `onSelectKey` notifies the parent when the user chooses a key to open

 Side effects:
 - loads the module key list asynchronously when the view appears
 - presents a retry action when the selected backend cannot enumerate keys
 - dismisses the sheet when the user taps the toolbar Done action

 Failure modes:
 - a successful empty list renders the ordinary empty/search state
 - a backend failure remains visible with its diagnostic message and Retry action
 - cancellation discards the superseded task result without changing current browser state
 */
struct DictionaryBrowserView: View {
    /// Immutable backend snapshot whose keys and row presentations are being browsed.
    let source: DictionaryBrowserSource

    /// Callback invoked when the user chooses a dictionary key.
    let onSelectKey: (String) -> Void

    /// Live search text used to filter the loaded key list.
    @State private var searchText = ""

    /// Complete list of keys loaded from the module.
    @State private var allKeys: [String] = []

    /// Browser-session cache for lazily projected orthography/snippet rows.
    @State private var displayCache: DictionaryEntryDisplayCache

    /// Whether the module key list is still loading.
    @State private var isLoading = true

    /// Actionable backend error kept distinct from a successfully empty dictionary.
    @State private var loadErrorMessage: String?

    /// Monotonic retry token used to restart the structured key-loading task.
    @State private var loadAttempt = 0

    /// Dismiss action for closing the browser.
    @Environment(\.dismiss) private var dismiss

    /**
     Creates a dictionary chooser with a browser-scoped display-row cache.

     - Parameters:
       - module: Dictionary module whose exact global keys are shown.
       - onSelectKey: Callback for an exact selected key.
     - Side effects: Allocates an empty bounded row cache.
     - Failure modes: None.
     */
    init(
        module: SwordModule,
        onSelectKey: @escaping (String) -> Void
    ) {
        self.init(source: DictionaryBrowserSource(swordModule: module), onSelectKey: onSelectKey)
    }

    /**
     Creates a dictionary chooser over one immutable backend-independent source.

     - Parameters:
       - source: Captured SWORD or SQLite dictionary operations and title.
       - onSelectKey: Callback for an exact selected key.
     - Side effects: Allocates an empty bounded row cache.
     - Failure modes: None; source failures are handled by the structured loading task.
     */
    init(
        source: DictionaryBrowserSource,
        onSelectKey: @escaping (String) -> Void
    ) {
        self.source = source
        self.onSelectKey = onSelectKey
        _displayCache = State(initialValue: source.displayCache())
    }

    /// Keys matching the current search text.
    private var filteredKeys: [String] {
        DictionaryKeyFilter.filteredKeys(allKeys, searchText: searchText)
    }

    /**
     Builds the loading, searchable list, successful-empty, and retryable-failure states.

     - Returns: A navigation stack bound to the selected module and current search text.
     - Side effects: Starts one cancellation-propagating backend enumeration per `loadAttempt` and
       updates main-actor view state only if the enclosing structured task is still active.
     - Failure modes: Enumeration errors render a diagnostic Retry action; cancellation stops the
       backend read and discards its result, and successful empty content remains distinct from
       either case.
     - Important: The source captures one immutable backend snapshot, so a concurrent module switch
       cannot mix keys and definitions even if a cancelled detached read finishes later.
     */
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(String(localized: "dictionary_loading_keys"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadErrorMessage {
                    ContentUnavailableView {
                        Label(
                            String(localized: "error_occurred"),
                            systemImage: "exclamationmark.triangle"
                        )
                    } description: {
                        Text(loadErrorMessage)
                    } actions: {
                        Button(String(localized: "retry")) {
                            retryLoadingKeys()
                        }
                    }
                } else if filteredKeys.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(Array(filteredKeys.enumerated()), id: \.offset) { row in
                        let key = row.element
                        Button {
                            onSelectKey(key)
                        } label: {
                            DictionaryEntryDisplayRow(
                                key: key,
                                cache: displayCache
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $searchText, prompt: String(localized: "dictionary_search_keys"))
            .navigationTitle(source.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .task(id: loadAttempt) {
                let result: Result<[String], Error>
                do {
                    let keys = try await source.loadKeys()
                    result = .success(keys)
                } catch {
                    result = .failure(error)
                }
                guard !Task.isCancelled else { return }

                switch GenericSwordChooserResolver.resolve(result: result) {
                case .present(let validKeys):
                    allKeys = validKeys
                case .dismissWithoutSelection:
                    // Android leaves an empty dictionary chooser open; only ChooseKeyBase-backed
                    // general-book/map choosers auto-finish with a null selection.
                    allKeys = []
                case .failed(let message):
                    allKeys = []
                    loadErrorMessage = message
                }
                isLoading = false
            }
        }
    }

    /**
     Restarts key enumeration after a visible backend failure.

     - Side effects: Clears the current error, restores loading UI, and increments the task identity.
     - Failure modes: A repeated backend failure returns to the same actionable error state.
     */
    private func retryLoadingKeys() {
        loadErrorMessage = nil
        isLoading = true
        loadAttempt += 1
    }
}

/**
 One lazily loaded dictionary chooser row.

 The key is visible immediately for accessibility and interaction; Android-derived orthography or
 snippet text replaces it after the browser cache resolves the exact entry.
 */
private struct DictionaryEntryDisplayRow: View {
    /// Exact module key.
    let key: String
    /// Browser-session row cache.
    let cache: DictionaryEntryDisplayCache
    /// Current visible row text.
    @State private var displayText: String

    /**
     Creates a key-first row while its snippet is unresolved.

     - Parameters identify the exact key and its module-bound cache.
     - Side effects: Initializes visible text to the key.
     - Failure modes: None.
     */
    init(key: String, cache: DictionaryEntryDisplayCache) {
        self.key = key
        self.cache = cache
        _displayText = State(initialValue: key)
    }

    /** Builds the stable row label and starts one cache-backed exact-entry lookup. */
    var body: some View {
        Text(displayText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .task(id: key) {
                displayText = await cache.presentation(for: key).displayText
            }
    }
}
