// GeneralBookBrowserView.swift — Flat key list browser for general books and maps

import SwiftUI
import SwordKit

/// Flat key list browser for general book and map modules.
/// Reused for both `.generalBook` and `.map` categories.
struct GeneralBookBrowserView: View {
    let module: SwordModule
    let title: String
    let onSelectKey: (String) -> Void

    @State private var allKeys: [String] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(String(localized: "genbook_loading_entries"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if allKeys.isEmpty {
                    ContentUnavailableView(
                        String(localized: "genbook_no_entries"),
                        systemImage: "book.closed",
                        description: Text(String(localized: "genbook_no_entries_description"))
                    )
                } else {
                    List(allKeys, id: \.self) { key in
                        Button(key) {
                            onSelectKey(key)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(title)
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
