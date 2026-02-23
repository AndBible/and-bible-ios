// DictionaryBrowserView.swift — Searchable key browser for dictionary/lexicon modules

import SwiftUI
import SwordKit

/// Searchable dictionary key browser, matching Android's ChooseDictionaryWord.
/// Loads all keys from the module and filters them in real-time as the user types.
struct DictionaryBrowserView: View {
    let module: SwordModule
    let onSelectKey: (String) -> Void

    @State private var searchText = ""
    @State private var allKeys: [String] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    private var filteredKeys: [String] {
        if searchText.isEmpty { return allKeys }
        return allKeys.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(String(localized: "dictionary_loading_keys"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredKeys.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(filteredKeys, id: \.self) { key in
                        Button(key) {
                            onSelectKey(key)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: $searchText, prompt: String(localized: "dictionary_search_keys"))
            .navigationTitle(module.info.description)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .task {
                let keys = await Task.detached { [module] in
                    module.allKeys()
                }.value
                allKeys = keys
                isLoading = false
            }
        }
    }
}
