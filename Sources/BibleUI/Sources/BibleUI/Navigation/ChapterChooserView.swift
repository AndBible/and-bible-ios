// ChapterChooserView.swift — Chapter selection grid

import SwiftUI

/**
 Grid-based chooser for selecting a chapter within a book.

 The chapter count is supplied by the parent chooser from the active module's versification data,
 so chapter availability matches the selected module rather than a static canon table.
 The grid layout and current-chapter highlight mirror Android `GridChoosePassageChapter`.
 */
public struct ChapterChooserView: View {
    /// User-visible book name shown in the navigation title.
    let bookName: String

    /// OSIS id for the selected book, used to resolve Android category color.
    let osisBookId: String?

    /// Number of chapters available for this book in the active module; zero renders no choices.
    let chapterCount: Int

    /// Current reader chapter if this chooser is showing the active book.
    let currentChapter: Int?

    /// Callback invoked with the chosen one-based chapter number.
    let onSelect: (Int) -> Void

    /**
     Creates a chapter chooser for one book.

     - Parameters:
       - bookName: Book name displayed in the navigation title.
       - osisBookId: OSIS id for Android category color; falls back to static resolution by name.
       - chapterCount: Number of chapters available in the active module.
       - currentChapter: Current reader chapter to highlight when the active book is selected.
       - onSelect: Callback receiving the selected one-based chapter number.
     */
    public init(
        bookName: String,
        osisBookId: String? = nil,
        chapterCount: Int,
        currentChapter: Int? = nil,
        onSelect: @escaping (Int) -> Void
    ) {
        self.bookName = bookName
        self.osisBookId = osisBookId
        self.chapterCount = chapterCount
        self.currentChapter = currentChapter
        self.onSelect = onSelect
    }

    /// Builds the Android-aligned chapter grid.
    public var body: some View {
        GeometryReader { proxy in
            let chapters = chapterCount > 0 ? Array(1...chapterCount) : []
            let orientation = PassageGridOrientation(size: proxy.size)
            let layout = PassageGridLayout.androidDefault(
                itemCount: chapters.count,
                kind: .number,
                orientation: orientation
            )
            let slots = layout.displaySlots(for: chapters)
            let columns = Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: 4),
                count: max(layout.columns, 1)
            )
            let categoryColor = PassageBookCategory.category(forOsisId: resolvedOsisBookId).color

            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, chapter in
                        if let chapter {
                            PassageGridButton(
                                title: "\(chapter)",
                                accessibilityLabel: "\(bookName) \(chapter)",
                                accessibilityIdentifier: "passageChapterCell.\(chapter)",
                                palette: PassageGridCellPalette.numberPalette(
                                    number: chapter,
                                    currentNumber: currentChapter,
                                    categoryColor: categoryColor
                                ),
                                font: .body.monospacedDigit().weight(.semibold),
                                minHeight: 36
                            ) {
                                onSelect(chapter)
                            }
                        } else {
                            Color.clear
                                .frame(minHeight: 36)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .padding(12)
            }
        }
        .navigationTitle(bookName)
    }

    /// OSIS id used for Android category color resolution.
    private var resolvedOsisBookId: String {
        osisBookId ?? BibleReaderController.osisBookId(for: bookName)
    }
}
