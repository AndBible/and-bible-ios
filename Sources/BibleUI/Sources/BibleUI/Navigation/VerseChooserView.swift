// VerseChooserView.swift — Verse selection grid

import SwiftUI

/**
 Grid-based chooser for selecting a specific verse after book and chapter selection.

 The verse count is supplied by the parent chooser and reflects the currently selected book and
 chapter in the active module.
 */
public struct VerseChooserView: View {
    /// User-visible book name shown in the navigation title.
    let bookName: String

    /// One-based chapter number currently being selected within.
    let chapter: Int

    /// Number of verses available for this chapter in the active module; zero renders no choices.
    let verseCount: Int

    /// Callback invoked with the chosen one-based verse number.
    let onSelect: (Int) -> Void

    /**
     Creates a verse chooser for one book and chapter.

     - Parameters:
       - bookName: Book name displayed in the navigation title.
       - chapter: One-based chapter number for the current selection flow.
       - verseCount: Number of verses available in this chapter.
       - onSelect: Callback receiving the selected one-based verse number.
     */
    public init(bookName: String, chapter: Int, verseCount: Int, onSelect: @escaping (Int) -> Void) {
        self.bookName = bookName
        self.chapter = chapter
        self.verseCount = verseCount
        self.onSelect = onSelect
    }

    /// Builds the adaptive verse grid.
    public var body: some View {
        ScrollView {
            let columns = [GridItem(.adaptive(minimum: 44), spacing: 6)]
            LazyVGrid(columns: columns, spacing: 6) {
                if verseCount > 0 {
                    ForEach(1...verseCount, id: \.self) { verse in
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
            }
            .padding()
        }
        .navigationTitle("\(bookName) \(chapter)")
    }
}
