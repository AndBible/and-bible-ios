// VerseChooserView.swift — Verse selection grid

import SwiftUI

/// Grid-based verse chooser for selecting a specific verse.
public struct VerseChooserView: View {
    let bookName: String
    let chapter: Int
    let verseCount: Int
    let onSelect: (Int) -> Void

    public init(bookName: String, chapter: Int, verseCount: Int, onSelect: @escaping (Int) -> Void) {
        self.bookName = bookName
        self.chapter = chapter
        self.verseCount = verseCount
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView {
            let columns = [GridItem(.adaptive(minimum: 44), spacing: 6)]
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(1...max(verseCount, 1), id: \.self) { verse in
                    Button(action: { onSelect(verse) }) {
                        Text("\(verse)")
                            .font(.callout.monospacedDigit())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle("\(bookName) \(chapter)")
    }
}
