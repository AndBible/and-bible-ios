// MyBibleReader.swift -- MyBible SQLite database reader

import Foundation
import SQLite3

/**
 Reads MyBible SQLite modules used by the MyBible and related Android ecosystems.

 The reader expects the MyBible schema:
 - `verses(book_number, chapter, verse, text)` for Bible text
 - `books(book_number, long_name, short_name)` for book metadata
 - `info(name, value)` for module metadata

 Some MyBible packages may not be Bible texts. `detectType()` checks for the `verses` table so
 callers can gate Bible-specific features when the schema diverges.

 - Important: `MyBibleReader` is marked `@unchecked Sendable` so higher-level import and module
   management flows can store and pass reader instances across actor boundaries. The class does
   not synchronize access to the underlying SQLite handle, so callers must confine each
   instance's use to one actor, queue, or thread at a time and avoid overlapping method calls.
 */
public final class MyBibleReader: @unchecked Sendable {
    /// Open SQLite handle for the source MyBible database.
    private var db: OpaquePointer?

    /// Filesystem path to the opened MyBible database file.
    private let filePath: String

    /// User-visible module description loaded from the `info` table.
    public private(set) var moduleDescription: String = ""

    /// Module language code loaded from the `info` table.
    public private(set) var language: String = "en"

    /// Whether the opened database exposes a `verses` table and can be treated as a Bible.
    public private(set) var isBible: Bool = true

    /**
     Opens a MyBible SQLite database in read-only mode.

     - Parameter filePath: Filesystem path to the `.SQLite3` file.
     - Note: Initialization fails when SQLite cannot open the database read-only.
     */
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

    /**
     Returns one verse from a MyBible module.

     - Parameters:
       - book: MyBible `book_number` value.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: Verse text, or `nil` when no matching row exists.
     */
    public func getVerse(book: Int, chapter: Int, verse: Int) -> String? {
        let query = "SELECT text FROM verses WHERE book_number = ? AND chapter = ? AND verse = ?"
        return executeTextQuery(query, params: [book, chapter, verse])
    }

    /**
     Returns a full chapter from a MyBible module.

     - Parameters:
       - book: MyBible `book_number` value.
       - chapter: One-based chapter number.
     - Returns: Verse-number/text tuples ordered by verse.
     */
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

    /**
     Returns the book metadata table for the opened MyBible module.

     - Returns: Tuples of MyBible book number, long name, and short name ordered by book number.
     */
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

    /// Detects whether the opened MyBible database exposes the `verses` table.
    private func detectType() {
        // Check if the 'verses' table exists (Bible) vs. other tables
        let query = "SELECT name FROM sqlite_master WHERE type='table' AND name='verses'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        isBible = sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Loads common module metadata from the MyBible `info` table.
    private func loadMetadata() {
        if let desc = getInfoValue("description") {
            moduleDescription = desc
        }
        if let lang = getInfoValue("language") {
            language = lang
        }
    }

    /// Reads one key from the MyBible `info` table.
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

    /// Executes a positional text query against the open MyBible database.
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
