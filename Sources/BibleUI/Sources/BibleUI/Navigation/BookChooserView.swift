// BookChooserView.swift — Book selection grid

import SwiftUI
import SwordKit

/**
 Grid-based chooser for selecting a book and then drilling down to chapter or verse.

 The chooser uses the active module's `BookInfo` list instead of a static canon, so modules with
 expanded canons surface their additional books automatically. Depending on `navigateToVerse`, the
 flow ends after chapter selection or adds a verse-selection step.

 Data dependencies:
 - `books` is the module-specific canon and chapter metadata provided by the caller
 - `verseCountProvider` supplies module-specific `Versification.getLastVerse` equivalents when
   the chooser drills into verse selection; `nil` means the active module could not resolve the
   selected chapter and no synthetic verse list should be shown
 - `dismiss` closes the chooser when the user cancels the flow

 Side effects:
 - tapping a book mutates local selection state to advance to the chapter step
 - tapping a chapter may either complete the flow or advance to the verse step
 - tapping toolbar back actions resets the local step state without dismissing the sheet
 */
public struct BookChooserView: View {
    /// Dynamic book list derived from the active module's versification.
    let books: [BookInfo]

    /// Whether the flow should include a verse chooser after chapter selection.
    let navigateToVerse: Bool

    /// Provides the last verse number for a selected book/chapter.
    let verseCountProvider: (BookInfo, Int) -> Int?

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
       - verseCountProvider: Optional provider for module-specific chapter verse counts. A missing
         provider keeps existing no-module callers functional by falling back to the static
         compatibility table.
       - onSelect: Callback receiving `(bookName, chapter, verse?)` when selection completes.
     */
    public init(
        books: [BookInfo],
        navigateToVerse: Bool = false,
        verseCountProvider: ((BookInfo, Int) -> Int?)? = nil,
        onSelect: @escaping (String, Int, Int?) -> Void
    ) {
        self.books = books
        self.navigateToVerse = navigateToVerse
        self.verseCountProvider = verseCountProvider ?? { book, chapter in
            BibleReaderController.verseCount(for: book.name, chapter: chapter)
        }
        self.onSelect = onSelect
    }

    /// Books tagged as Old Testament in the module-provided canon.
    private var oldTestamentBooks: [BookInfo] {
        books.filter { $0.testament == 1 }
    }

    /// Books tagged as New Testament in the module-provided canon.
    private var newTestamentBooks: [BookInfo] {
        books.filter { $0.testament == 2 }
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
                        chapter: chapter,
                        verseCount: verseCountProvider(book, chapter) ?? 0
                    ) { verse in
                        onSelect(book.name, chapter, verse)
                    }
                } else {
                    ChapterChooserView(bookName: book.name, chapterCount: book.chapterCount) { chapter in
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
                Button(String(localized: "cancel")) { dismiss() }
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

    /// Navigation title reflecting the current chooser step.
    private var navigationTitle: String {
        if let book = selectedBook, let chapter = selectedChapter {
            return "\(book.name) \(chapter)"
        }
        return selectedBook?.name ?? String(localized: "choose_book")
    }

    /// Scrollable container for the testament-grouped book grid.
    private var bookGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !oldTestamentBooks.isEmpty {
                    Section(String(localized: "old_testament")) {
                        bookGridSection(books: oldTestamentBooks)
                    }
                }
                if !newTestamentBooks.isEmpty {
                    Section(String(localized: "new_testament")) {
                        bookGridSection(books: newTestamentBooks)
                    }
                }
            }
            .padding()
        }
    }

    /**
     Builds one adaptive grid section for the provided books.

     - Parameter books: Books to render in this testament section.
     */
    private func bookGridSection(books: [BookInfo]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(books) { book in
                Button(action: {
                    selectedBook = book
                    selectedChapter = nil
                }) {
                    Text(book.abbreviation)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
