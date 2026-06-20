// VerseChooserView.swift — Verse selection grid

import SwiftUI

/**
 Grid-based chooser for selecting a specific verse after book and chapter selection.

 The verse count is supplied by the parent chooser and reflects the currently selected book and
 chapter in the active module. The grid layout and current-verse highlight mirror Android
 `GridChoosePassageVerse`.
 */
public struct VerseChooserView: View {
    /// User-visible book name shown in the navigation title.
    let bookName: String

    /// OSIS id for the selected book, used to resolve Android category color.
    let osisBookId: String?

    /// One-based chapter number currently being selected within.
    let chapter: Int

    /// Number of verses available for this chapter in the active module; zero renders no choices.
    let verseCount: Int

    /// Current reader verse if this chooser is showing the active book and chapter.
    let currentVerse: Int?

    /// Callback invoked with the chosen one-based verse number.
    let onSelect: (Int) -> Void

    /**
     Creates a verse chooser for one book and chapter.

     - Parameters:
       - bookName: Book name displayed in the navigation title.
       - osisBookId: OSIS id for Android category color; falls back to static resolution by name.
       - chapter: One-based chapter number for the current selection flow.
       - verseCount: Number of verses available in this chapter.
       - currentVerse: Current reader verse to highlight when the active chapter is selected.
       - onSelect: Callback receiving the selected one-based verse number.
     */
    public init(
        bookName: String,
        osisBookId: String? = nil,
        chapter: Int,
        verseCount: Int,
        currentVerse: Int? = nil,
        onSelect: @escaping (Int) -> Void
    ) {
        self.bookName = bookName
        self.osisBookId = osisBookId
        self.chapter = chapter
        self.verseCount = verseCount
        self.currentVerse = currentVerse
        self.onSelect = onSelect
    }

    /// Builds the Android-aligned verse grid.
    public var body: some View {
        GeometryReader { proxy in
            let verses = verseCount > 0 ? Array(1...verseCount) : []
            let orientation = PassageGridOrientation(size: proxy.size)
            let layout = PassageGridLayout.androidDefault(
                itemCount: verses.count,
                kind: .number,
                orientation: orientation
            )
            let slots = layout.displaySlots(for: verses)
            let columns = Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: 4),
                count: max(layout.columns, 1)
            )
            let categoryColor = PassageBookCategory.category(forOsisId: resolvedOsisBookId).color

            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, verse in
                        if let verse {
                            PassageGridButton(
                                title: "\(verse)",
                                accessibilityLabel: "\(bookName) \(chapter):\(verse)",
                                accessibilityIdentifier: "passageVerseCell.\(verse)",
                                palette: PassageGridCellPalette.numberPalette(
                                    number: verse,
                                    currentNumber: currentVerse,
                                    categoryColor: categoryColor
                                ),
                                font: .callout.monospacedDigit().weight(.semibold),
                                minHeight: 34
                            ) {
                                onSelect(verse)
                            }
                        } else {
                            Color.clear
                                .frame(minHeight: 34)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .padding(12)
            }
        }
        .navigationTitle("\(bookName) \(chapter)")
    }

    /// OSIS id used for Android category color resolution.
    private var resolvedOsisBookId: String {
        osisBookId ?? BibleReaderController.osisBookId(for: bookName)
    }
}
