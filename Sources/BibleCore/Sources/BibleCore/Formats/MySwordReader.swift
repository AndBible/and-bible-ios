// MySwordReader.swift — MySword SQLite database reader

import Foundation
import SQLite3

/// Reads MySword format Bible databases (.bbl, .cmt, .dct files).
/// MySword files are SQLite databases with specific table structures.
public final class MySwordReader: @unchecked Sendable {
    private var db: OpaquePointer?
    private let filePath: String

    /// The type of MySword file.
    public enum FileType: String {
        case bible = "bbl"
        case commentary = "cmt"
        case dictionary = "dct"
    }

    /// Detected file type.
    public let fileType: FileType

    /// Module description from the database.
    public private(set) var moduleDescription: String = ""

    /// Module language.
    public private(set) var language: String = "en"

    /// Initialize with a MySword database file.
    /// - Parameter filePath: Path to the .bbl/.cmt/.dct file.
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

    /// Get verse text for a Bible file.
    /// - Parameters:
    ///   - book: Book number (1-based, Genesis=1).
    ///   - chapter: Chapter number (1-based).
    ///   - verse: Verse number (1-based).
    /// - Returns: The verse text as HTML/OSIS, or nil if not found.
    public func getVerse(book: Int, chapter: Int, verse: Int) -> String? {
        guard fileType == .bible else { return nil }

        let query = "SELECT Scripture FROM Bible WHERE Book = ? AND Chapter = ? AND Verse = ?"
        return executeTextQuery(query, params: [book, chapter, verse])
    }

    /// Get a full chapter of text.
    /// - Parameters:
    ///   - book: Book number (1-based).
    ///   - chapter: Chapter number (1-based).
    /// - Returns: Array of (verse number, text) tuples.
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

    /// Get commentary text.
    public func getCommentary(book: Int, chapter: Int, verse: Int) -> String? {
        guard fileType == .commentary else { return nil }
        let query = "SELECT Commentary FROM Commentary WHERE Book = ? AND Chapter = ? AND Verse = ?"
        return executeTextQuery(query, params: [book, chapter, verse])
    }

    /// Get dictionary entry by key.
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

    /// List all dictionary keys.
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

    private func loadMetadata() {
        if let desc = getDetailValue("Description") {
            moduleDescription = desc
        }
        if let lang = getDetailValue("Language") {
            language = lang
        }
    }

    private func getDetailValue(_ key: String) -> String? {
        let query = "SELECT Value FROM Details WHERE Name = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, key, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

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
