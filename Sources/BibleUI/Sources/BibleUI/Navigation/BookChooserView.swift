// BookChooserView.swift — Book selection grid

import SwiftUI
import SwordKit

/**
 Grid-based chooser for selecting a book and then drilling down to chapter or verse.

 The chooser uses the active module's `BookInfo` list instead of a static canon, so modules with
 expanded canons surface their additional books automatically. Depending on `navigateToVerse`, the
 flow ends after chapter selection or adds a verse-selection step.

 The grid layout and colors mirror Android's `GridChoosePassageBook` and `ButtonGrid` defaults:
 standard 66-book canons render in a dense column-major portrait matrix, expanded canons use
 Android's dynamic matrix, and the current passage is highlighted with its book category color.

 Data dependencies:
 - `books` is the module-specific canon and chapter metadata provided by the caller
 - `currentBook`, `currentChapter`, and `currentVerse` are the reader's active location used only
   for Android-compatible highlighting
 - `workspaceName` is shown on the first chooser step to mirror Android's activity title context
 - `verseCountProvider` supplies module-specific `Versification.getLastVerse` equivalents when
   the chooser drills into verse selection; `nil` means the active module could not resolve the
   selected chapter and no synthetic verse list should be shown
 - `onCancel` lets custom drawer presenters close their own presentation state; without it the view
   falls back to SwiftUI's environment dismiss action for sheet/navigation-stack hosts

 Side effects:
 - tapping a book mutates local selection state to advance to the chapter step
 - tapping a chapter may either complete the flow or advance to the verse step
 - tapping toolbar back actions resets the local step state without dismissing the chooser
 */
public struct BookChooserView: View {
    /// Dynamic book list derived from the active module's versification.
    let books: [BookInfo]

    /// Whether the flow should include a verse chooser after chapter selection.
    let navigateToVerse: Bool

    /// Current reader book name, used to highlight the active book.
    let currentBook: String?

    /// Current reader chapter, used to highlight the active chapter in the active book.
    let currentChapter: Int?

    /// Current reader verse, used to highlight the active verse in the active chapter.
    let currentVerse: Int?

    /// Active workspace name appended to the first-step title for Android parity.
    let workspaceName: String?

    /// Provides the last verse number for a selected book/chapter.
    let verseCountProvider: (BookInfo, Int) -> Int?

    /// Optional explicit cancellation callback for non-sheet presentations.
    let onCancel: (() -> Void)?

    /// Callback invoked when the user has completed the selection flow.
    let onSelect: (String, Int, Int?) -> Void

    /// Currently selected book, or `nil` while the grid step is visible.
    @State private var selectedBook: BookInfo?

    /// Currently selected chapter when the verse step is active.
    @State private var selectedChapter: Int?

    /// Dismiss action for canceling the chooser flow.
    @Environment(\.dismiss) private var dismiss

    /**
     Creates a book chooser for a specific module canon.

     - Parameters:
       - books: Book list from the active module's versification.
       - navigateToVerse: Whether the flow should include verse selection.
       - currentBook: Current reader book name, used only for selector highlighting.
       - currentChapter: Current reader chapter, used only for selector highlighting.
       - currentVerse: Current reader verse, used only for selector highlighting.
       - workspaceName: Active workspace name appended to the first-step chooser title.
       - verseCountProvider: Optional provider for module-specific chapter verse counts. A missing
         provider keeps existing no-module callers functional by falling back to the static
         compatibility table.
       - onCancel: Optional callback used by custom drawer hosts to close their presentation state.
       - onSelect: Callback receiving `(bookName, chapter, verse?)` when selection completes.
     */
    public init(
        books: [BookInfo],
        navigateToVerse: Bool = false,
        currentBook: String? = nil,
        currentChapter: Int? = nil,
        currentVerse: Int? = nil,
        workspaceName: String? = nil,
        verseCountProvider: ((BookInfo, Int) -> Int?)? = nil,
        onCancel: (() -> Void)? = nil,
        onSelect: @escaping (String, Int, Int?) -> Void
    ) {
        self.books = books
        self.navigateToVerse = navigateToVerse
        self.currentBook = currentBook
        self.currentChapter = currentChapter
        self.currentVerse = currentVerse
        self.workspaceName = workspaceName
        self.verseCountProvider = verseCountProvider ?? { book, chapter in
            BibleReaderController.verseCount(for: book.name, chapter: chapter)
        }
        self.onCancel = onCancel
        self.onSelect = onSelect
    }

    /**
     Builds the current chooser step: book grid, chapter grid, or verse grid.
     */
    public var body: some View {
        Group {
            if let book = selectedBook {
                if navigateToVerse, let chapter = selectedChapter {
                    VerseChooserView(
                        bookName: book.name,
                        osisBookId: book.osisId,
                        chapter: chapter,
                        verseCount: verseCountProvider(book, chapter) ?? 0,
                        currentVerse: currentVerseForSelectedContext(book: book, chapter: chapter)
                    ) { verse in
                        onSelect(book.name, chapter, verse)
                    }
                } else {
                    ChapterChooserView(
                        bookName: book.name,
                        osisBookId: book.osisId,
                        chapterCount: book.chapterCount,
                        currentChapter: currentChapterForSelectedBook(book)
                    ) { chapter in
                        if navigateToVerse {
                            selectedChapter = chapter
                        } else {
                            onSelect(book.name, chapter, nil)
                        }
                    }
                }
            } else {
                bookGrid
            }
        }
        .navigationTitle(navigationTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) { cancelChooser() }
            }
            if selectedChapter != nil {
                ToolbarItem(placement: .navigation) {
                    Button(String(localized: "choose_chapter", defaultValue: "Choose Chapter")) {
                        selectedChapter = nil
                    }
                }
            } else if selectedBook != nil {
                ToolbarItem(placement: .navigation) {
                    Button(String(localized: "books")) {
                        selectedBook = nil
                        selectedChapter = nil
                    }
                }
            }
        }
    }

    /**
     Cancels the chooser through the host-provided callback when present.

     Custom drawer presentation is owned by `BibleReaderView`, so SwiftUI's environment dismiss
     action is not sufficient there. Sheet-based callers keep the legacy path by omitting
     `onCancel`, which delegates to the environment dismiss action.
     */
    private func cancelChooser() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    /// Navigation title reflecting the current chooser step.
    private var navigationTitle: String {
        if let book = selectedBook, let chapter = selectedChapter {
            return "\(book.name) \(chapter)"
        }
        if let selectedBook {
            return selectedBook.name
        }

        return PassageChooserTitle.bookSelectionTitle(
            baseTitle: String(localized: "choose_book"),
            workspaceName: workspaceName
        )
    }

    /// Scrollable container for the Android-aligned book grid.
    private var bookGrid: some View {
        GeometryReader { proxy in
            let orientation = PassageGridOrientation(size: proxy.size)
            let layout = PassageGridLayout.androidDefault(
                itemCount: books.count,
                kind: .book,
                orientation: orientation
            )
            let slots = layout.displaySlots(for: books)
            let columnCount = max(layout.columns, 1)
            let metrics = PassageGridMetrics.squareCells(
                availableWidth: proxy.size.width,
                columns: columnCount
            )
            let columns = Array(
                repeating: GridItem(.fixed(metrics.cellSide), spacing: PassageGridMetrics.spacing),
                count: columnCount
            )

            ScrollView {
                LazyVGrid(columns: columns, spacing: PassageGridMetrics.spacing) {
                    ForEach(Array(slots.enumerated()), id: \.offset) { _, book in
                        if let book {
                            PassageGridButton(
                                title: book.abbreviation,
                                accessibilityLabel: book.name,
                                accessibilityIdentifier: "passageBookCell.\(book.osisId)",
                                palette: PassageGridCellPalette.bookPalette(
                                    for: book,
                                    currentOsisId: currentOsisBookId
                                ),
                                font: .subheadline.weight(.semibold),
                                cellSide: metrics.cellSide
                            ) {
                                selectedBook = book
                                selectedChapter = nil
                            }
                        } else {
                            Color.clear
                                .frame(width: metrics.cellSide, height: metrics.cellSide)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(width: metrics.gridWidth)
                .padding(PassageGridMetrics.horizontalPadding)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /**
     Resolves the current reader OSIS id against the active module's book list.

     - Returns: Current book OSIS id if it exists in the active module or static fallback table.
     */
    private var currentOsisBookId: String? {
        guard let currentBook else {
            return nil
        }
        if let book = books.first(where: { $0.name == currentBook || $0.osisId == currentBook }) {
            return book.osisId
        }
        return BibleReaderController.osisBookId(for: currentBook)
    }

    /**
     Returns the current chapter when the selected book matches the active reader book.

     - Parameter book: Book currently selected in the chooser flow.
     - Returns: Current chapter for matching books; otherwise `nil`.
     */
    private func currentChapterForSelectedBook(_ book: BookInfo) -> Int? {
        guard book.osisId == currentOsisBookId else {
            return nil
        }
        return currentChapter
    }

    /**
     Returns the current verse when the selected book and chapter match the active reader context.

     - Parameters:
       - book: Book currently selected in the chooser flow.
       - chapter: Chapter currently selected in the chooser flow.
     - Returns: Current verse for matching book/chapter contexts; otherwise `nil`.
     */
    private func currentVerseForSelectedContext(book: BookInfo, chapter: Int) -> Int? {
        guard book.osisId == currentOsisBookId, chapter == currentChapter else {
            return nil
        }
        return currentVerse
    }
}
