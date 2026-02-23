// SearchResultsView.swift — Search results display

import SwiftUI
import SwordKit

/// Displays search results from a module search.
public struct SearchResultsView: View {
    let results: SearchResults

    public init(results: SearchResults) {
        self.results = results
    }

    public var body: some View {
        List {
            Section("\(results.count) results in \(results.moduleName)") {
                ForEach(results.results) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.key)
                            .font(.headline)
                        Text(result.previewText)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Results")
    }
}
