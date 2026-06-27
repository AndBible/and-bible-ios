// MyBibleReader.swift -- MyBible SQLite database reader

import Foundation
import SQLite3

/// SQLite destructor marker that copies Swift string buffers before `sqlite3_step` reads them.
private let myBibleReaderSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Reads MyBible SQLite modules used by the MyBible and related Android ecosystems.

 The reader expects the MyBible schema:
 - `verses(book_number, chapter, verse, text)` for Bible text
 - `books(book_number, long_name, short_name)` for book metadata
 - `dictionary(topic, definition, ...)` for MyBible lexicon/dictionary modules
 - `info(name, value)` for module metadata

 Some MyBible packages may not be Bible texts. `detectType()` checks for Bible and dictionary
 tables so callers can gate schema-specific features when the module diverges from a Bible text.

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
    public private(set) var isBible: Bool = false

    /// Whether the opened database exposes a MyBible `dictionary` table.
    public private(set) var isDictionary: Bool = false

    /// Whether MyBible metadata marks the dictionary as a Strong's definition module.
    public private(set) var hasStrongsDefinitions: Bool = false

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
     Returns a dictionary entry by its MyBible topic key.

     Android's MyBible adapter reads Strong's dictionaries from `dictionary.topic` and tries both
     padded and category-prefixed keys such as `00430`, `H0430`, and `H430`. This method exposes
     the same exact-key lookup primitive to higher-level dictionary builders.

     - Parameter key: Dictionary topic key to resolve exactly.
     - Returns: Raw definition text for the topic, or `nil` when the module is not a dictionary or
       the key is absent.
     - Side effects: Reads the opened SQLite database.
     - Failure modes: SQLite prepare/step failures are treated as missing entries.
     */
    public func getDictionaryEntry(key: String) -> String? {
        guard isDictionary else { return nil }
        let query = "SELECT definition FROM dictionary WHERE topic = ?"
        return executeTextQuery(query, textParam: key)
    }

    /**
     Returns all dictionary topic keys exposed by the opened MyBible module.

     - Returns: Topic keys ordered by MyBible's topic column for deterministic callers.
     - Side effects: Reads the opened SQLite database.
     - Failure modes: Non-dictionary modules or SQLite failures return an empty list.
     */
    public func dictionaryKeys() -> [String] {
        guard isDictionary else { return [] }
        let query = "SELECT topic FROM dictionary ORDER BY topic"
        var results: [String] = []

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let textPtr = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: textPtr))
            }
        }

        return results
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

    /// Detects the high-level MyBible schema and Strong's metadata exposed by the database.
    private func detectType() {
        let tables = tableNames()
        isBible = tables.contains("verses")
        isDictionary = tables.contains("dictionary")
        hasStrongsDefinitions = isDictionary && Self.parseMyBibleBoolean(getInfoValue("is_strong"))
    }

    /// Returns all table names from SQLite's schema catalog.
    private func tableNames() -> Set<String> {
        let query = "SELECT name FROM sqlite_master WHERE type='table'"
        var names = Set<String>()

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return names }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let textPtr = sqlite3_column_text(stmt, 0) {
                names.insert(String(cString: textPtr))
            }
        }

        return names
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

        sqlite3_bind_text(stmt, 1, key, -1, myBibleReaderSQLiteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let textPtr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: textPtr)
    }

    /// Parses MyBible boolean metadata values such as `true`, `1`, and `yes`.
    private static func parseMyBibleBoolean(_ value: String?) -> Bool {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(normalized)
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

    /// Executes a single text-parameter query against the open MyBible database.
    private func executeTextQuery(_ query: String, textParam: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, textParam, -1, myBibleReaderSQLiteTransient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let textPtr = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: textPtr)
    }
}
