// CrossReferenceView.swift — Popup showing cross-reference verses with navigation

import SwiftUI

/// Displays a list of cross-reference verses with their text.
/// Tapping a reference navigates to that book/chapter.
struct CrossReferenceView: View {
    let references: [CrossReference]
    let onNavigate: (String, Int) -> Void

    var body: some View {
        NavigationStack {
            List(references) { ref in
                Button {
                    onNavigate(ref.book, ref.chapter)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ref.displayName)
                            .font(.headline)
                        if !ref.text.isEmpty {
                            Text(ref.text)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(String(localized: "cross_references"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }
}
