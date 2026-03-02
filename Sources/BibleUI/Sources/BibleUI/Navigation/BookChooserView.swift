// BookChooserView.swift — Book selection grid

import SwiftUI
import SwordKit

/// Grid-based book chooser for navigating to a Bible book.
///
/// Displays books from the active module's versification, grouped by testament.
/// Modules with apocrypha/deuterocanonical books will show additional sections.
public struct BookChooserView: View {
    let books: [BookInfo]
    let onSelect: (String, Int) -> Void
    @State private var selectedBook: BookInfo?
    @Environment(\.dismiss) private var dismiss

    /// Create a book chooser with a specific book list.
    /// - Parameters:
    ///   - books: The book list from the active module's versification.
    ///   - onSelect: Callback with (bookName, chapter) when a chapter is selected.
    public init(books: [BookInfo], onSelect: @escaping (String, Int) -> Void) {
        self.books = books
        self.onSelect = onSelect
    }

    /// Old Testament books from the provided list.
    private var oldTestamentBooks: [BookInfo] {
        books.filter { $0.testament == 1 }
    }

    /// New Testament books from the provided list.
    private var newTestamentBooks: [BookInfo] {
        books.filter { $0.testament == 2 }
    }

    public var body: some View {
        Group {
            if let book = selectedBook {
                ChapterChooserView(bookName: book.name, chapterCount: book.chapterCount) { chapter in
                    onSelect(book.name, chapter)
                }
            } else {
                bookGrid
            }
        }
        .navigationTitle(selectedBook?.name ?? String(localized: "choose_book"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "cancel")) { dismiss() }
            }
            if selectedBook != nil {
                ToolbarItem(placement: .navigation) {
                    Button(String(localized: "books")) { selectedBook = nil }
                }
            }
        }
    }

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

    private func bookGridSection(books: [BookInfo]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(books) { book in
                Button(action: { selectedBook = book }) {
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
