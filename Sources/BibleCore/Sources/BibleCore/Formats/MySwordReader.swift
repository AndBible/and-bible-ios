// MySwordReader.swift -- MySword SQLite database reader

import Foundation
import SQLite3

/**
 Reads MySword SQLite modules used by the Android ecosystem.

 The reader supports the three MySword file types:
 - `.bbl`: Bible text in a `Bible` table with `Scripture` rows keyed by book/chapter/verse
 - `.cmt`: commentary text in a `Commentary` table with the same positional keys
 - `.dct`: dictionary entries in a `Dictionary` table keyed by topic

 Shared module metadata is read from the `Details` table. The reader is intentionally
 read-only and does not mutate the source database.

 - Important: `MySwordReader` is marked `@unchecked Sendable` so higher-level import and module
   management flows can store and pass reader instances across actor boundaries. The class does
   not synchronize access to the underlying SQLite handle, so callers must confine each
   instance's use to one actor, queue, or thread at a time and avoid overlapping method calls.
 */
public final class MySwordReader: @unchecked Sendable {
    /// Open SQLite handle for the source MySword database.
    private var db: OpaquePointer?

    /// Filesystem path to the opened MySword database file.
    private let filePath: String

    /**
     Describes the supported MySword module families.

     The raw values mirror the expected filename extensions used to detect the backing schema.
     */
    public enum FileType: String {
        case bible = "bbl"
        case commentary = "cmt"
        case dictionary = "dct"
    }

    /// Detected module type derived from the MySword filename extension.
    public let fileType: FileType

    /// User-visible module description loaded from the `Details` table.
    public private(set) var moduleDescription: String = ""

    /// Module language code loaded from the `Details` table.
    public private(set) var language: String = "en"

    /**
     Opens a MySword module in read-only mode.

     - Parameter filePath: Filesystem path to a `.bbl`, `.cmt`, or `.dct` file.
     - Note: Initialization fails when the extension does not match a supported MySword type or
       when SQLite cannot open the database read-only.
     */
    public init?(filePath: String) {
        self.filePath = filePath

        // Detect file type from extension
        let ext = (filePath as NSString).pathExtension.lowercased()
        switch ext {
        case "bbl": self.fileType = .bible
        case "cmt": self.fileType = .commentary
        case "dct": self.fileType = .dictionary
        default: return nil
        }

        // Open database
        guard sqlite3_open_v2(filePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }

        loadMetadata()
    }

    deinit {
        sqlite3_close(db)
    }

    /**
     Returns one verse from a MySword Bible module.

     - Parameters:
       - book: One-based book number as stored by the MySword `Bible` table.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: Verse content as stored in the `Scripture` column, or `nil` when absent.
     */
    public func getVerse(book: Int, chapter: Int, verse: Int) -> String? {
        guard fileType == .bible else { return nil }

        let query = "SELECT Scripture FROM Bible WHERE Book = ? AND Chapter = ? AND Verse = ?"
        return executeTextQuery(query, params: [book, chapter, verse])
    }

    /**
     Returns a full chapter from a MySword Bible module.

     - Parameters:
       - book: One-based book number as stored by the MySword `Bible` table.
       - chapter: One-based chapter number.
     - Returns: Verse-number/text tuples ordered by verse.
     */
    public func getChapter(book: Int, chapter: Int) -> [(verse: Int, text: String)] {
        guard fileType == .bible else { return [] }

        let query = "SELECT Verse, Scripture FROM Bible WHERE Book = ? AND Chapter = ? ORDER BY Verse"
        var results: [(Int, String)] = []

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(book))
        sqlite3_bind_int(stmt, 2, Int32(chapter))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let verseNum = Int(sqlite3_column_int(stmt, 0))
            let text = String(cString: sqlite3_column_text(stmt, 1))
            results.append((verseNum, text))
        }

        return results
    }

    /**
     Returns commentary text for one verse-position key.

     - Parameters:
       - book: One-based book number as stored by the `Commentary` table.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: Commentary HTML/text, or `nil` when no row exists.
     */
    public func getCommentary(book: Int, chapter: Int, verse: Int) -> String? {
        guard fileType == .commentary else { return nil }
        let query = "SELECT Commentary FROM Commentary WHERE Book = ? AND Chapter = ? AND Verse = ?"
        return executeTextQuery(query, params: [book, chapter, verse])
    }

    /**
     Returns a dictionary entry by topic key from a MySword dictionary module.

     - Parameter key: Topic string stored in the `Dictionary.Topic` column.
     - Returns: Definition text, or `nil` when the topic is not present.
     */
    public func getDictionaryEntry(key: String) -> String? {
        guard fileType == .dictionary else { return nil }
        let query = "SELECT Definition FROM Dictionary WHERE Topic = ?"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    /**
     Lists all topic keys from a MySword dictionary module.

     - Returns: Topic strings ordered alphabetically by the SQLite query.
     */
    public func dictionaryKeys() -> [String] {
        guard fileType == .dictionary else { return [] }
        let query = "SELECT Topic FROM Dictionary ORDER BY Topic"
        var keys: [String] = []

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            keys.append(String(cString: sqlite3_column_text(stmt, 0)))
        }

        return keys
    }

    // MARK: - Private

    /// Loads common module metadata from the MySword `Details` table.
    private func loadMetadata() {
        if let desc = getDetailValue("Description") {
            moduleDescription = desc
        }
        if let lang = getDetailValue("Language") {
            language = lang
        }
    }

    /// Reads one key from the MySword `Details` table.
    private func getDetailValue(_ key: String) -> String? {
        let query = "SELECT Value FROM Details WHERE Name = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    /// Executes a positional text query against the open MySword database.
    private func executeTextQuery(_ query: String, params: [Int]) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        for (index, param) in params.enumerated() {
            sqlite3_bind_int(stmt, Int32(index + 1), Int32(param))
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }
}
