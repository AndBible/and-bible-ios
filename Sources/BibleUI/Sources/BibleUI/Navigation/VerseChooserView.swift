// VerseChooserView.swift — Verse selection grid

import SwiftUI

/**
 Grid-based chooser for selecting a specific verse after book and chapter selection.

 The verse count is supplied by the parent chooser and reflects the currently selected book and
 chapter in the active module. The grid layout, row-order preference, progress overlays, and
 current-verse highlight mirror Android `GridChoosePassageVerse`.
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

    /// Android row-order option shared with the book chooser menu.
    let rowOrder: Bool

    /// Provides Android KJVA progress for a one-based verse.
    let progressProvider: (Int) -> PassageGridProgress

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
       - rowOrder: Android row-order option shared with book chooser settings.
       - progressProvider: Optional Android KJVA progress provider for verse cells.
       - onSelect: Callback receiving the selected one-based verse number.
     */
    public init(
        bookName: String,
        osisBookId: String? = nil,
        chapter: Int,
        verseCount: Int,
        currentVerse: Int? = nil,
        rowOrder: Bool = false,
        progressProvider: ((Int) -> PassageGridProgress)? = nil,
        onSelect: @escaping (Int) -> Void
    ) {
        self.bookName = bookName
        self.osisBookId = osisBookId
        self.chapter = chapter
        self.verseCount = verseCount
        self.currentVerse = currentVerse
        self.rowOrder = rowOrder
        self.progressProvider = progressProvider ?? { _ in .none }
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
                orientation: orientation,
                rowOrder: rowOrder
            )
            let slots = layout.displaySlots(for: verses)
            let columnCount = max(layout.columns, 1)
            let metrics = PassageGridMetrics.squareCells(
                availableWidth: proxy.size.width,
                columns: columnCount
            )
            let columns = Array(
                repeating: GridItem(.fixed(metrics.cellSide), spacing: PassageGridMetrics.spacing),
                count: columnCount
            )
            let categoryColor = PassageBookCategory.category(forOsisId: resolvedOsisBookId).color

            ScrollView {
                LazyVGrid(columns: columns, spacing: PassageGridMetrics.spacing) {
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
                                progress: progressProvider(verse),
                                cellSide: metrics.cellSide
                            ) {
                                onSelect(verse)
                            }
                        } else {
                            Color.clear
                                .frame(width: metrics.cellSide, height: metrics.cellSide)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(width: metrics.gridWidth)
                .padding(.horizontal, PassageGridMetrics.horizontalPadding)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("\(bookName) \(chapter)")
        .background(PassageChooserSurfacePalette.background.swiftUIColor.ignoresSafeArea())
    }

    /// OSIS id used for Android category color resolution.
    private var resolvedOsisBookId: String {
        osisBookId ?? BibleReaderController.osisBookId(for: bookName)
    }
}
