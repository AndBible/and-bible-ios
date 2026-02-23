// BookChooserView.swift — Book selection grid

import SwiftUI

/// Grid-based book chooser for navigating to a Bible book.
public struct BookChooserView: View {
    let onSelect: (String, Int) -> Void
    @State private var selectedBook: String?
    @Environment(\.dismiss) private var dismiss

    public init(onSelect: @escaping (String, Int) -> Void) {
        self.onSelect = onSelect
    }

    private let oldTestamentBooks = [
        "Genesis", "Exodus", "Leviticus", "Numbers", "Deuteronomy",
        "Joshua", "Judges", "Ruth", "1 Samuel", "2 Samuel",
        "1 Kings", "2 Kings", "1 Chronicles", "2 Chronicles",
        "Ezra", "Nehemiah", "Esther", "Job", "Psalms",
        "Proverbs", "Ecclesiastes", "Song of Solomon", "Isaiah", "Jeremiah",
        "Lamentations", "Ezekiel", "Daniel", "Hosea", "Joel",
        "Amos", "Obadiah", "Jonah", "Micah", "Nahum",
        "Habakkuk", "Zephaniah", "Haggai", "Zechariah", "Malachi"
    ]

    private let newTestamentBooks = [
        "Matthew", "Mark", "Luke", "John", "Acts",
        "Romans", "1 Corinthians", "2 Corinthians", "Galatians", "Ephesians",
        "Philippians", "Colossians", "1 Thessalonians", "2 Thessalonians",
        "1 Timothy", "2 Timothy", "Titus", "Philemon", "Hebrews",
        "James", "1 Peter", "2 Peter", "1 John", "2 John",
        "3 John", "Jude", "Revelation"
    ]

    public var body: some View {
        Group {
            if let book = selectedBook {
                ChapterChooserView(bookName: book) { chapter in
                    onSelect(book, chapter)
                }
            } else {
                bookGrid
            }
        }
        .navigationTitle(selectedBook == nil ? String(localized: "choose_book") : selectedBook!)
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
                Section(String(localized: "old_testament")) {
                    bookGridSection(books: oldTestamentBooks)
                }
                Section(String(localized: "new_testament")) {
                    bookGridSection(books: newTestamentBooks)
                }
            }
            .padding()
        }
    }

    private func bookGridSection(books: [String]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(books, id: \.self) { book in
                Button(action: { selectedBook = book }) {
                    Text(abbreviation(for: book))
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

    private static let abbreviations: [String: String] = [
        "Genesis": "Gen", "Exodus": "Exod", "Leviticus": "Lev", "Numbers": "Num",
        "Deuteronomy": "Deut", "Joshua": "Josh", "Judges": "Judg", "Ruth": "Ruth",
        "1 Samuel": "1 Sam", "2 Samuel": "2 Sam", "1 Kings": "1 Kgs", "2 Kings": "2 Kgs",
        "1 Chronicles": "1 Chr", "2 Chronicles": "2 Chr", "Ezra": "Ezra", "Nehemiah": "Neh",
        "Esther": "Esth", "Job": "Job", "Psalms": "Psa", "Proverbs": "Prov",
        "Ecclesiastes": "Eccl", "Song of Solomon": "Song", "Isaiah": "Isa", "Jeremiah": "Jer",
        "Lamentations": "Lam", "Ezekiel": "Ezek", "Daniel": "Dan", "Hosea": "Hos",
        "Joel": "Joel", "Amos": "Amos", "Obadiah": "Obad", "Jonah": "Jonah",
        "Micah": "Mic", "Nahum": "Nah", "Habakkuk": "Hab", "Zephaniah": "Zeph",
        "Haggai": "Hag", "Zechariah": "Zech", "Malachi": "Mal",
        "Matthew": "Matt", "Mark": "Mark", "Luke": "Luke", "John": "John", "Acts": "Acts",
        "Romans": "Rom", "1 Corinthians": "1 Cor", "2 Corinthians": "2 Cor",
        "Galatians": "Gal", "Ephesians": "Eph", "Philippians": "Phil", "Colossians": "Col",
        "1 Thessalonians": "1 Thess", "2 Thessalonians": "2 Thess",
        "1 Timothy": "1 Tim", "2 Timothy": "2 Tim", "Titus": "Titus", "Philemon": "Phlm",
        "Hebrews": "Heb", "James": "Jas", "1 Peter": "1 Pet", "2 Peter": "2 Pet",
        "1 John": "1 John", "2 John": "2 John", "3 John": "3 John",
        "Jude": "Jude", "Revelation": "Rev",
    ]

    private func abbreviation(for book: String) -> String {
        Self.abbreviations[book] ?? book
    }
}
