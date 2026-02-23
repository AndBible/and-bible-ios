// MyBibleReader.swift — MyBible SQLite database reader

import Foundation
import SQLite3

/// Reads MyBible format Bible databases (.SQLite3 files).
/// MyBible uses a different table structure than MySword.
public final class MyBibleReader: @unchecked Sendable {
    private var db: OpaquePointer?
    private let filePath: String

    /// Module description.
    public private(set) var moduleDescription: String = ""

    /// Module language.
    public private(set) var language: String = "en"

    /// Whether this is a Bible (vs. commentary/dictionary).
    public private(set) var isBible: Bool = true

    /// Initialize with a MyBible database file.
    /// - Parameter filePath: Path to the .SQLite3 file.
    public init?(filePath: String) {
        self.filePath = filePath

        guard sqlite3_open_v2(filePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }

        detectType()
        loadMetadata()
    }

    deinit {
        sqlite3_close(db)
    }

    /// Get verse text.
    /// - Parameters:
    ///   - book: Book number (MyBible uses its own numbering scheme).
    ///   - chapter: Chapter number (1-based).
    ///   - verse: Verse number (1-based).
    /// - Returns: Verse text or nil.
    public func getVerse(book: Int, chapter: Int, verse: Int) -> String? {
        let query = "SELECT text FROM verses WHERE book_number = ? AND chapter = ? AND verse = ?"
        return executeTextQuery(query, params: [book, chapter, verse])
    }

    /// Get a full chapter.
    public func getChapter(book: Int, chapter: Int) -> [(verse: Int, text: String)] {
        let query = "SELECT verse, text FROM verses WHERE book_number = ? AND chapter = ? ORDER BY verse"
        var results: [(Int, String)] = []

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(book))
        sqlite3_bind_int(stmt, 2, Int32(chapter))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let verseNum = Int(sqlite3_column_int(stmt, 0))
            if let textPtr = sqlite3_column_text(stmt, 1) {
                results.append((verseNum, String(cString: textPtr)))
            }
        }

        return results
    }

    /// Get list of books in this module.
    public func books() -> [(number: Int, name: String, shortName: String)] {
        let query = "SELECT book_number, long_name, short_name FROM books ORDER BY book_number"
        var results: [(Int, String, String)] = []

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let num = Int(sqlite3_column_int(stmt, 0))
            let longName = String(cString: sqlite3_column_text(stmt, 1))
            let shortName = String(cString: sqlite3_column_text(stmt, 2))
            results.append((num, longName, shortName))
        }

        return results
    }

    // MARK: - Private

    private func detectType() {
        // Check if the 'verses' table exists (Bible) vs. other tables
        let query = "SELECT name FROM sqlite_master WHERE type='table' AND name='verses'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        isBible = sqlite3_step(stmt) == SQLITE_ROW
    }

    private func loadMetadata() {
        if let desc = getInfoValue("description") {
            moduleDescription = desc
        }
        if let lang = getInfoValue("language") {
            language = lang
        }
    }

    private func getInfoValue(_ key: String) -> String? {
        let query = "SELECT value FROM info WHERE name = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let textPtr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: textPtr)
    }

    private func executeTextQuery(_ query: String, params: [Int]) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        for (index, param) in params.enumerated() {
            sqlite3_bind_int(stmt, Int32(index + 1), Int32(param))
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let textPtr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: textPtr)
    }
}
