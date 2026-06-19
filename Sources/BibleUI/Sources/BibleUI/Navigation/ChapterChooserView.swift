// ChapterChooserView.swift — Chapter selection grid

import SwiftUI

/**
 Grid-based chooser for selecting a chapter within a book.

 The chapter count is supplied by the parent chooser from the active module's versification data,
 so chapter availability matches the selected module rather than a static canon table.
 */
public struct ChapterChooserView: View {
    /// User-visible book name shown in the navigation title.
    let bookName: String

    /// Number of chapters available for this book in the active module; zero renders no choices.
    let chapterCount: Int

    /// Callback invoked with the chosen one-based chapter number.
    let onSelect: (Int) -> Void

    /**
     Creates a chapter chooser for one book.

     - Parameters:
       - bookName: Book name displayed in the navigation title.
       - chapterCount: Number of chapters available in the active module.
       - onSelect: Callback receiving the selected one-based chapter number.
     */
    public init(bookName: String, chapterCount: Int, onSelect: @escaping (Int) -> Void) {
        self.bookName = bookName
        self.chapterCount = chapterCount
        self.onSelect = onSelect
    }

    /// Builds the adaptive chapter grid.
    public var body: some View {
        ScrollView {
            let columns = [GridItem(.adaptive(minimum: 50), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                if chapterCount > 0 {
                    ForEach(1...chapterCount, id: \.self) { chapter in
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
            }
            .padding()
        }
        .navigationTitle(bookName)
    }
}
