// ChapterChooserView.swift — Chapter selection grid

import SwiftUI

/// Grid-based chapter chooser for selecting a chapter within a book.
///
/// The chapter count comes from the active module's versification data,
/// passed in by the parent BookChooserView.
public struct ChapterChooserView: View {
    let bookName: String
    let chapterCount: Int
    let onSelect: (Int) -> Void

    /// Create a chapter chooser.
    /// - Parameters:
    ///   - bookName: The book name (for the navigation title).
    ///   - chapterCount: Number of chapters in this book (from module versification).
    ///   - onSelect: Callback with the selected chapter number (1-based).
    public init(bookName: String, chapterCount: Int, onSelect: @escaping (Int) -> Void) {
        self.bookName = bookName
        self.chapterCount = chapterCount
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollView {
            let columns = [GridItem(.adaptive(minimum: 50), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(1...max(chapterCount, 1), id: \.self) { chapter in
                    Button(action: { onSelect(chapter) }) {
                        Text("\(chapter)")
                            .font(.body.monospacedDigit())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(bookName)
    }
}
