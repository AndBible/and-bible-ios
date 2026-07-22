// MyBibleReader.swift -- Shared SQLite document contracts and Android-compatible MyBible reader

import Foundation
import SQLite3

/// SQLite destructor marker that copies Swift string buffers before a prepared statement reads them.
private let sqliteDocumentReaderTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/** Identifies the Android-compatible SQLite module family that produced catalog metadata. */
public enum SQLiteDocumentFormat: String, Equatable, Sendable {
    /// MyBible `.SQLite3` module.
    case myBible

    /// MySword `.*.mybible` module.
    case mySword

    /// e-Sword `.bblx` or `.bbli` module.
    case eSword
}

/**
 Stable metadata projected by every Android-compatible SQLite document reader.

 The fields intentionally avoid reader-specific database details so a later backend catalog can
 enumerate MyBible, MySword, and e-Sword modules through one value type without reopening files.
 The value has no side effects and is deterministic for a given file path and database contents.
 */
public struct SQLiteDocumentMetadata: Equatable, Sendable {
    /// Exact source database URL opened by the reader.
    public let sourceURL: URL

    /// SQLite module family used to interpret the source schema.
    public let format: SQLiteDocumentFormat

    /// Android-compatible synthetic module initials.
    public let initials: String

    /// Short module label, including Android's filename-derived fallback.
    public let abbreviation: String

    /// Human-readable title supplied by the module or derived from its description.
    public let title: String

    /// Module description used by Android's generated SWORD configuration.
    public let description: String

    /// Module language code, preserving the source format's default when metadata is absent.
    public let language: String

    /// Source module version, or Android's format-specific fallback.
    public let version: String

    /// Reader category selected from the source schema or filename.
    public let category: DocumentCategory

    /// Reading direction advertised by the source metadata.
    public let direction: TextDirection

    /// Whether Bible content advertises Strong's annotations.
    public let hasStrongs: Bool

    /// Whether a dictionary is marked as a Strong's definition module.
    public let isStrongsDictionary: Bool

    /// Whether Bible content advertises or contains MyBible `<J>` words-of-Christ markup.
    public let hasWordsOfChrist: Bool

    /**
     Creates immutable catalog metadata for one validated SQLite module.

     - Parameters:
       - sourceURL: Exact source database URL.
       - format: SQLite module family.
       - initials: Android-compatible synthetic initials.
       - abbreviation: Short module label.
       - title: Human-readable title.
       - description: Human-readable description.
       - language: Source language code.
       - version: Source version string.
       - category: Document category selected by the reader.
       - direction: Source reading direction.
       - hasStrongs: Whether Bible content advertises Strong's annotations.
       - isStrongsDictionary: Whether dictionary content supplies Strong's definitions.
       - hasWordsOfChrist: Whether MyBible words-of-Christ markup is available.
     - Side effects: None.
     - Failure modes: None; readers validate values before construction.
     */
    public init(
        sourceURL: URL,
        format: SQLiteDocumentFormat,
        initials: String,
        abbreviation: String,
        title: String,
        description: String,
        language: String,
        version: String,
        category: DocumentCategory,
        direction: TextDirection,
        hasStrongs: Bool,
        isStrongsDictionary: Bool,
        hasWordsOfChrist: Bool
    ) {
        self.sourceURL = sourceURL
        self.format = format
        self.initials = initials
        self.abbreviation = abbreviation
        self.title = title
        self.description = description
        self.language = language
        self.version = version
        self.category = category
        self.direction = direction
        self.hasStrongs = hasStrongs
        self.isStrongsDictionary = isStrongsDictionary
        self.hasWordsOfChrist = hasWordsOfChrist
    }
}

/** A typed lookup key shared by Bible, commentary, and dictionary SQLite readers. */
public enum SQLiteDocumentKey: Hashable, Sendable {
    /// Numeric book/chapter/verse coordinate in the source format's Android book-number map.
    case verse(book: Int, chapter: Int, verse: Int)

    /// Exact dictionary topic or word key; lookup remains case-sensitive like Android SQLite.
    case dictionary(String)
}

/** One resolved SQLite document entry paired with the exact key used to request it. */
public struct SQLiteDocumentContent: Equatable, Sendable {
    /// Exact typed key resolved by the reader.
    public let key: SQLiteDocumentKey

    /// Android-compatible raw text or transformed OSIS fragment returned for the key.
    public let text: String

    /**
     Creates a resolved content value.

     - Parameters:
       - key: Exact key used for lookup.
       - text: Raw or Android-transformed module content.
     - Side effects: None.
     - Failure modes: None.
     */
    public init(key: SQLiteDocumentKey, text: String) {
        self.key = key
        self.text = text
    }
}

/**
 Describes filename, schema, metadata-cardinality, and SQLite failures surfaced by format readers.

 Readers distinguish unsupported filenames and malformed schemas from absent content so import and
 catalog code can reject a bad module once instead of silently treating every lookup as missing.
 */
public enum SQLiteDocumentReaderError: Error, Equatable, LocalizedError, Sendable {
    /// The path is missing, not a regular file, or is not readable.
    case unreadableFile(String)

    /// The filename does not match the selected format's Android discovery suffix.
    case unsupportedFileName(format: SQLiteDocumentFormat, fileName: String)

    /// SQLite could not open the source database in read-only mode.
    case cannotOpen(fileName: String, message: String)

    /// A table required by the selected category is absent.
    case missingTable(format: SQLiteDocumentFormat, table: String)

    /// A required table is present but lacks one or more Android content columns.
    case missingColumns(format: SQLiteDocumentFormat, table: String, columns: [String])

    /// No supported category table exists in a schema-discovered format such as MyBible.
    case unsupportedSchema(format: SQLiteDocumentFormat, tables: [String])

    /// MySword or e-Sword `Details` does not contain a readable first metadata row.
    case invalidMetadataRowCount(format: SQLiteDocumentFormat, actual: Int)

    /// One result row cannot fit inside Android's empty Requery CursorWindow.
    case cursorWindowRowTooLarge(fileName: String, windowSize: Int)

    /// Android would reject the SQLite storage class for the requested typed projection.
    case unsupportedStorageClass(
        fileName: String,
        column: String,
        expected: String,
        actual: String
    )

    /// The current Swift task was cancelled while SQLite was preparing or stepping a query.
    case cancelled(fileName: String)

    /// SQLite rejected a validated reader query or returned a step error.
    case queryFailed(fileName: String, message: String)

    /// User-facing diagnostic suitable for import and catalog error presentation.
    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let fileName):
            return "SQLite document is not a readable file: \(fileName)"
        case .unsupportedFileName(let format, let fileName):
            return "\(fileName) is not a supported \(format.rawValue) filename"
        case .cannotOpen(let fileName, let message):
            return "Could not open \(fileName): \(message)"
        case .missingTable(let format, let table):
            return "\(format.rawValue) database is missing table \(table)"
        case .missingColumns(let format, let table, let columns):
            return "\(format.rawValue) table \(table) is missing columns: \(columns.joined(separator: ", "))"
        case .unsupportedSchema(let format, let tables):
            return "\(format.rawValue) database has no supported content table among: \(tables.joined(separator: ", "))"
        case .invalidMetadataRowCount(let format, let actual):
            return "\(format.rawValue) Details table must contain a metadata row; found \(actual)"
        case .cursorWindowRowTooLarge(let fileName, let windowSize):
            return "SQLite row for \(fileName) cannot fit in Android's \(windowSize)-byte CursorWindow"
        case .unsupportedStorageClass(let fileName, let column, let expected, let actual):
            return "SQLite column \(column) in \(fileName) is \(actual), expected \(expected)"
        case .cancelled(let fileName):
            return "SQLite query was cancelled for \(fileName)"
        case .queryFailed(let fileName, let message):
            return "SQLite query failed for \(fileName): \(message)"
        }
    }
}

/**
 Common read-only contract for Android-compatible SQLite document sources.

 Implementations eagerly read identifying metadata but defer content-schema failures until the
 affected operation, matching Android's lazy SQLite backends. Built-in readers open an independent
 read-only connection for each operation so concurrent callers do not queue behind a shared handle.
 */
public protocol SQLiteDocumentReading: AnyObject {
    /// Validated immutable metadata for catalog projection.
    var metadata: SQLiteDocumentMetadata { get }

    /// High-level content category selected for this database.
    var category: DocumentCategory { get }

    /**
     Returns deterministic source keys suitable for indexing and catalog inspection.

     - Returns: Bible rows, commentary start coordinates, or dictionary keys in source order.
     - Side effects: Reads the open SQLite database.
     - Throws: `SQLiteDocumentReaderError.queryFailed` if SQLite cannot execute the query, or
       `.cursorWindowRowTooLarge` when Android could not expose one result row.
     */
    func keys() throws -> [SQLiteDocumentKey]

    /**
     Resolves one typed key without changing reader state.

     - Parameter key: Verse or dictionary key compatible with the reader's category.
     - Returns: Content for an existing key, or `nil` for a missing or category-incompatible key.
     - Side effects: Reads the open SQLite database.
     - Throws: `SQLiteDocumentReaderError.queryFailed` if SQLite cannot execute the query.
     */
    func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent?

    /**
     Reads one Bible chapter through the most efficient operation the reader provides.

     - Parameters:
       - book: Source-format book number.
       - chapter: One-based chapter number.
     - Returns: One first-row result per distinct verse coordinate, ordered by verse.
     - Side effects: Reads the open SQLite database.
     - Throws: Reader query, cancellation, storage-class, or CursorWindow failures.
     */
    func chapterContent(book: Int, chapter: Int) throws -> [(verse: Int, text: String)]

    /**
     Streams every distinct Bible chapter represented by real source rows.

     - Parameter body: Synchronous consumer receiving source-format book and one-based chapter
       coordinates in database order.
     - Side effects: Reads the source database on an operation-owned connection.
     - Throws: Reader query, cancellation, storage-class, CursorWindow, or consumer failures.
     - Important: Built-in readers use a constant-memory query so whole-Bible consumers such as
       Search do not need to materialize the complete verse-key set.
     */
    func forEachBibleChapter(_ body: (Int, Int) throws -> Bool) throws

    /**
     Emits source book numbers whose Android backend contains chapter 1 verse 1 or verse 2.

     - Parameter body: Synchronous consumer called for each matching source book number. Duplicate
       numbers are permitted because the library projects them into a canon-sized set.
     - Side effects: Reads the source database without retaining every matching row.
     - Throws: Reader query, cancellation, storage-class, CursorWindow, or consumer failures.
     */
    func forEachNavigationBookNumber(_ body: (Int) throws -> Void) throws
}

/** Supplies a compatibility chapter projection for test doubles and third-party reader adapters. */
public extension SQLiteDocumentReading {
    /**
     Derives distinct Bible chapters from the compatibility key API for external adapters.

     Built-in readers override this fallback with streaming SQL. The fallback keeps third-party test
     doubles source-compatible but may retain their key array, so production whole-Bible operations
     should use one of the built-in readers.

     - Parameter body: Consumer invoked once per distinct source chapter in key order.
     - Side effects: Calls `keys()` once.
     - Throws: Re-throws key enumeration and consumer failures.
     */
    func forEachBibleChapter(_ body: (Int, Int) throws -> Bool) throws {
        var seen = Set<SQLiteDocumentChapterCoordinate>()
        for key in try keys() {
            guard case .verse(let book, let chapter, _) = key else { continue }
            let coordinate = SQLiteDocumentChapterCoordinate(book: book, chapter: chapter)
            guard seen.insert(coordinate).inserted else { continue }
            guard try body(book, chapter) else { break }
        }
    }

    /**
     Derives a chapter from key and content operations when a reader has no batch implementation.

     Concrete SQLite readers override this method with fixed-query-count implementations. The
     fallback de-duplicates coordinates before lookup so malformed duplicate rows cannot amplify
     repeated content scans.

     - Parameters:
       - book: Source-format book number.
       - chapter: One-based chapter number.
     - Returns: Present verse rows ordered by verse number.
     - Side effects: Enumerates keys once and performs at most one content read per distinct verse.
     - Throws: Re-throws key enumeration or content lookup errors.
     */
    func chapterContent(book: Int, chapter: Int) throws -> [(verse: Int, text: String)] {
        var seen = Set<Int>()
        let verses = try keys().compactMap { key -> Int? in
            guard case .verse(let candidateBook, let candidateChapter, let verse) = key,
                  candidateBook == book,
                  candidateChapter == chapter,
                  seen.insert(verse).inserted else { return nil }
            return verse
        }.sorted()
        return try verses.compactMap { verse in
            let key = SQLiteDocumentKey.verse(book: book, chapter: chapter, verse: verse)
            return try content(for: key).map { (verse, $0.text) }
        }
    }

    /**
     Supplies exact-coordinate navigation discovery for test doubles and third-party adapters.

     Built-in SQLite readers override this fallback with Android `indexOf`-equivalent queries that
     also account for commentary ranges and consume rows incrementally.

     - Parameter body: Consumer called once for each source book represented by a 1:1 or 1:2 key.
     - Side effects: Enumerates the adapter's complete key result once.
     - Throws: Re-throws key enumeration or consumer failures.
     */
    func forEachNavigationBookNumber(_ body: (Int) throws -> Void) throws {
        var emitted = Set<Int>()
        for key in try keys() {
            guard case .verse(let book, let chapter, let verse) = key,
                  chapter == 1,
                  (verse == 1 || verse == 2),
                  emitted.insert(book).inserted else { continue }
            try body(book)
        }
    }
}

/** Hashable chapter identity used only by the protocol's compatibility fallback. */
private struct SQLiteDocumentChapterCoordinate: Hashable {
    /// Source-format book number.
    let book: Int

    /// One-based chapter number.
    let chapter: Int
}

/** Internal control-flow error used to stop a streaming SQLite chapter cursor without failure. */
enum SQLiteDocumentChapterIterationStop: Error {
    /// The synchronous consumer requested that no additional chapter rows be read.
    case requested
}

/** Parameter value bound to a shared SQLite reader statement. */
enum SQLiteDocumentBinding {
    /// Signed integer value bound with `sqlite3_bind_int64`.
    case integer(Int)

    /// UTF-8 text value copied into SQLite-owned statement storage.
    case text(String)

    /// Numeric coordinate bound as Android's typeless `rawQuery` string selection argument.
    case coordinate(Int)
}

/**
 Preserves the difference between an absent SQLite result row and a present row containing `NULL`.

 The wrapper lets Android-compatible readers coalesce a present nullable text value to an empty
 string without incorrectly treating that row as missing. It is deterministic and has no side
 effects.
 */
struct SQLiteDocumentTextRow {
    /// First-column text for the present row, preserving SQL `NULL` as `nil`.
    let value: String?
}

/** Bridges Swift task cancellation into SQLite's synchronous virtual-machine progress callback. */
private final class SQLiteDocumentCancellationProbe {
    /** Returns whether the task currently executing the SQLite virtual machine was cancelled. */
    func isCancelled() -> Bool {
        withUnsafeCurrentTask { task in
            task?.isCancelled ?? false
        }
    }
}

/** Returns nonzero to interrupt SQLite when the query's owning Swift task has been cancelled. */
private func sqliteDocumentReaderProgressHandler(
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context else { return 0 }
    let probe = Unmanaged<SQLiteDocumentCancellationProbe>
        .fromOpaque(context)
        .takeUnretainedValue()
    return probe.isCancelled() ? 1 : 0
}

/**
 Opens independent read-only SQLite handles and maps low-level failures to reader-specific errors.

 Each operation owns its prepare/bind/step/finalize lifecycle and progress handler. This mirrors
 Android's connection-backed cursor isolation without making cancelled callers wait behind another
 query or sharing mutable statement state across Swift tasks.
 */
final class SQLiteDocumentDatabase {
    /// Requery 3.49.0's fixed Android CursorWindow capacity.
    static let androidCursorWindowByteCount = 2 * 1_024 * 1_024

    /// SQLite virtual-machine instructions between responsive task-cancellation checks.
    private static let cancellationProgressInstructionCount: Int32 = 1_000

    /** Byte-exact allocator state for Requery 3.49.0's native 2 MiB CursorWindow. */
    private struct AndroidCursorWindowModel {
        /// Requery's 16-byte header plus its first 404-byte row-slot chunk.
        private(set) var freeOffset = 420

        /// Successfully allocated rows in the current refill window.
        private(set) var rowCount = 0

        /**
         Attempts to append the statement's current row without mutating state on failure.

         - Parameter statement: SQLite statement positioned on `SQLITE_ROW`.
         - Returns: `true` when the complete row fits this window.
         - Side effects: Advances allocator state only after every field fits.
         - Failure modes: Returns `false` when Requery's native allocator would report full.
         */
        mutating func appendRow(from statement: OpaquePointer) -> Bool {
            var candidate = self
            if candidate.rowCount > 0, candidate.rowCount.isMultiple(of: 100),
               !candidate.allocate(404, aligned: true) {
                return false
            }

            let fieldDirectoryBytes = Int(sqlite3_column_count(statement)) * 12
            guard candidate.allocate(fieldDirectoryBytes, aligned: true) else { return false }
            for column in 0..<sqlite3_column_count(statement) {
                let payloadBytes: Int
                switch sqlite3_column_type(statement, column) {
                case SQLITE_TEXT:
                    payloadBytes = Int(sqlite3_column_bytes(statement, column)) + 1
                case SQLITE_BLOB:
                    payloadBytes = Int(sqlite3_column_bytes(statement, column))
                default:
                    payloadBytes = 0
                }
                guard candidate.allocate(payloadBytes, aligned: false) else { return false }
            }
            candidate.rowCount += 1
            self = candidate
            return true
        }

        /** Reserves bytes using CursorWindow's optional four-byte alignment. */
        private mutating func allocate(_ byteCount: Int, aligned: Bool) -> Bool {
            let padding = aligned ? ((~freeOffset + 1) & 3) : 0
            guard byteCount >= 0,
                  freeOffset <= SQLiteDocumentDatabase.androidCursorWindowByteCount - padding,
                  byteCount <= SQLiteDocumentDatabase.androidCursorWindowByteCount
                    - freeOffset - padding else {
                return false
            }
            freeOffset += padding + byteCount
            return true
        }
    }

    /// Canonicalized source URL used in diagnostics and metadata.
    let url: URL

    /**
     Opens a regular readable file as SQLite in read-only mode.

     - Parameter url: Candidate database URL.
     - Side effects: Opens and closes one read-only SQLite handle to validate the source.
     - Throws: `SQLiteDocumentReaderError.unreadableFile` or `.cannotOpen` when validation fails.
     */
    init(url: URL) throws {
        let normalizedURL = url.standardizedFileURL
        let values = try? normalizedURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: normalizedURL.path) else {
            throw SQLiteDocumentReaderError.unreadableFile(normalizedURL.lastPathComponent)
        }

        var openedHandle: OpaquePointer?
        let result = sqlite3_open_v2(normalizedURL.path, &openedHandle, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let openedHandle else {
            let message = openedHandle
                .flatMap(sqlite3_errmsg)
                .map(String.init(cString:)) ?? "SQLite open failed with code \(result)"
            if let openedHandle {
                sqlite3_close(openedHandle)
            }
            throw SQLiteDocumentReaderError.cannotOpen(
                fileName: normalizedURL.lastPathComponent,
                message: message
            )
        }

        sqlite3_close(openedHandle)
        self.url = normalizedURL
    }

    /**
     Returns exact user-table names from SQLite's schema catalog.

     - Returns: Table names excluding SQLite's internal tables.
     - Side effects: Prepares, steps, and finalizes a read-only statement.
     - Throws: `SQLiteDocumentReaderError.queryFailed` on SQLite failure.
     */
    func tableNames() throws -> [String] {
        try rows(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
        ) { statement in
            try self.text(statement, column: 0)
        }
    }

    /**
     Reads Android's first row from a `Details` table or view.

     Only columns touched by the matching Android backend are projected. Integer-backed booleans
     use Requery `Cursor.getInt`, including base-zero text parsing and signed 32-bit truncation.
     Additional columns and rows are deliberately ignored.

     - Parameter format: Format used in row-cardinality errors.
     - Returns: Non-null values keyed by lowercased column name.
     - Side effects: Reads the `Details` table.
     - Throws: `.invalidMetadataRowCount` when no row exists, or a shared query/coercion error.
     */
    func firstDetailsRow(format: SQLiteDocumentFormat) throws -> [String: String] {
        guard let result = try firstRow("SELECT * FROM Details", transform: { statement in
            let names = (0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_name(statement, index)
                    .map(String.init(cString:))?
                    .lowercased() ?? ""
            }

            func index(of candidates: [String]) -> Int32? {
                candidates.compactMap { candidate in
                    names.firstIndex(of: candidate).map(Int32.init)
                }.first
            }

            var values: [String: String] = [:]
            func projectText(_ key: String, candidates: [String]) throws {
                guard let column = index(of: candidates),
                      let value = try self.optionalText(statement, column: column) else { return }
                values[key] = value
            }
            func projectInteger(_ key: String, candidates: [String]) throws {
                guard let column = index(of: candidates) else { return }
                values[key] = String(try self.integer(statement, column: column))
            }

            switch format {
            case .mySword:
                try projectText("title", candidates: ["title"])
                try projectText("description", candidates: ["description"])
                try projectText("abbreviation", candidates: ["abbreviation"])
                try projectText("version", candidates: ["version"])
                // Android lowercases names, then searches for mixed-case `rightToLeft`; it misses.
                try projectInteger("strong", candidates: ["strong"])
                try projectText("language", candidates: ["language"])
            case .eSword:
                try projectText("description", candidates: ["description", "title"])
                try projectText("abbreviation", candidates: ["abbreviation"])
                try projectInteger("righttoleft", candidates: ["righttoleft"])
                try projectInteger("strong", candidates: ["strong", "strongs"])
            case .myBible:
                break
            }
            return values
        }) else {
            throw SQLiteDocumentReaderError.invalidMetadataRowCount(format: format, actual: 0)
        }
        return result
    }

    /**
     Executes a query and materializes every transformed row before finalizing the statement.

     - Parameters:
       - sql: Static SQL statement text.
       - bindings: Positional values bound in array order.
       - transform: Synchronous row projection that must not retain the statement pointer.
     - Returns: Projected rows in SQLite result order.
     - Side effects: Prepares, binds, steps, and finalizes a read-only statement.
     - Throws: Shared prepare, bind, step, cancellation, CursorWindow, coercion, or transform errors.
     - Complexity: Uses Android's refillable window model, then retains result-proportional memory.
       Reducers that do not return every row must use `consumeRows` instead.
     */
    func rows<T>(
        _ sql: String,
        bindings: [SQLiteDocumentBinding] = [],
        transform: (OpaquePointer) throws -> T
    ) throws -> [T] {
        var values: [T] = []
        try consumeRows(sql, bindings: bindings, transform: transform) {
            values.append($0)
        }
        return values
    }

    /**
     Transforms and consumes each query row before stepping to the next row.

     The consumer must not retain the SQLite statement, but it may retain data that is part of its
     final result. No array of transformed rows is created, so transient row lifetime is constant.

     - Parameters:
       - sql: Static SQL statement text.
       - bindings: Positional values bound in array order.
       - transform: Synchronous row projection that must not retain the statement pointer.
       - consume: Synchronous consumer invoked before SQLite advances to the next row.
     - Side effects: Opens an operation-owned connection, then prepares, binds, steps, and finalizes
       one read-only statement.
     - Throws: Shared prepare, bind, step, cancellation, CursorWindow, coercion, transform, or
       consumer errors.
     - Complexity: Uses constant transient row memory in addition to state retained by `consume`.
     */
    func consumeRows<T>(
        _ sql: String,
        bindings: [SQLiteDocumentBinding] = [],
        transform: (OpaquePointer) throws -> T,
        consume: (T) throws -> Void
    ) throws {
        try withQueryConnection { handle, probe in
            let statement = try prepareStatement(handle: handle, sql, bindings: bindings)
            defer { sqlite3_finalize(statement) }

            var window = AndroidCursorWindowModel()
            while true {
                if probe.isCancelled() {
                    throw SQLiteDocumentReaderError.cancelled(fileName: url.lastPathComponent)
                }
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    try consumeCursorWindowRow(from: statement, window: &window)
                    try consume(try transform(statement))
                case SQLITE_DONE:
                    return
                default:
                    throw queryError(handle: handle)
                }
            }
        }
    }

    /**
     Returns the first transformed row without scanning or materializing later duplicate rows.

     - Parameters:
       - sql: Static SQL statement text.
       - bindings: Positional values bound in array order.
       - transform: Synchronous projection that must not retain the statement.
     - Returns: The transformed first row, or `nil` when the query has no rows.
     - Side effects: Opens an operation-owned connection, prepares, binds, steps once, and finalizes
       one statement.
     - Throws: Shared query, cancellation, CursorWindow, coercion, or transform errors.
     */
    func firstRow<T>(
        _ sql: String,
        bindings: [SQLiteDocumentBinding] = [],
        transform: (OpaquePointer) throws -> T
    ) throws -> T? {
        try withQueryConnection { handle, probe in
            let statement = try prepareStatement(handle: handle, sql, bindings: bindings)
            defer { sqlite3_finalize(statement) }

            if probe.isCancelled() {
                throw SQLiteDocumentReaderError.cancelled(fileName: url.lastPathComponent)
            }
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                var window = AndroidCursorWindowModel()
                try consumeCursorWindowRow(from: statement, window: &window)
                return try transform(statement)
            case SQLITE_DONE:
                return nil
            default:
                throw queryError(handle: handle)
            }
        }
    }

    /**
     Returns the first text column from the first result row without materializing later rows.

     The method preserves its scalar-text contract by returning `nil` for either no row or a SQL
     `NULL`. Callers that need to distinguish those states use `firstTextRow` directly.

     - Parameters:
       - sql: Static SQL statement text.
       - bindings: Positional query values.
     - Returns: First-column text, or `nil` for no row or a present SQL `NULL`.
     - Side effects: Prepares, binds, steps once, and finalizes a read-only statement.
     - Throws: `SQLiteDocumentReaderError.queryFailed` on SQLite failure.
     - Complexity: Uses constant result memory regardless of duplicate row count.
     */
    func firstText(
        _ sql: String,
        bindings: [SQLiteDocumentBinding] = []
    ) throws -> String? {
        guard let row = try firstTextRow(sql, bindings: bindings) else { return nil }
        return row.value
    }

    /**
     Reads at most one row while preserving its nullable first-column text.

     - Parameters:
       - sql: Static SQL statement text.
       - bindings: Positional query values.
     - Returns: A wrapper for the first row, or `nil` when the query returned no row.
     - Side effects: Prepares, binds, steps once, and finalizes a read-only statement.
     - Throws: `SQLiteDocumentReaderError.queryFailed` for prepare, bind, or step failure.
     - Complexity: Uses constant result memory.
     */
    func firstTextRow(
        _ sql: String,
        bindings: [SQLiteDocumentBinding] = []
    ) throws -> SQLiteDocumentTextRow? {
        try firstRow(sql, bindings: bindings) { statement in
            SQLiteDocumentTextRow(value: try self.optionalText(statement, column: 0))
        }
    }

    /**
     Returns one required integer scalar.

     - Parameter sql: Scalar query expected to return one row.
     - Returns: First-column integer value, or zero if the query unexpectedly returns no rows.
     - Side effects: Reads the open database.
     - Throws: `SQLiteDocumentReaderError.queryFailed` on SQLite failure.
     */
    func scalarInteger(_ sql: String) throws -> Int {
        try firstRow(sql) { statement in
            try self.integer(statement, column: 0)
        } ?? 0
    }

    /**
     Returns non-null Android-style text from a result column, using an empty string for SQL `NULL`.

     - Throws: `.unsupportedStorageClass` when the source is a BLOB.
     */
    func text(_ statement: OpaquePointer, column: Int32) throws -> String {
        try optionalText(statement, column: column) ?? ""
    }

    /**
     Projects SQLite storage through Android Cursor text coercion without truncating embedded NUL.

     INTEGER values become decimal strings and REAL values use Android/SQLite `%g` formatting.
     TEXT is decoded from SQLite's explicit byte count, while BLOB is rejected instead of silently
     coercing bytes to UTF-8.

     - Returns: Coerced text, or `nil` for SQL `NULL`.
     - Throws: `.unsupportedStorageClass` for BLOB values.
     */
    func optionalText(_ statement: OpaquePointer, column: Int32) throws -> String? {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL:
            return nil
        case SQLITE_INTEGER:
            return String(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return String(
                format: "%g",
                locale: Locale(identifier: "en_US_POSIX"),
                sqlite3_column_double(statement, column)
            ).replacingOccurrences(of: "E", with: "e")
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, column) else { return "" }
            let byteCount = Int(sqlite3_column_bytes(statement, column))
            return String(decoding: UnsafeBufferPointer(start: pointer, count: byteCount), as: UTF8.self)
        case SQLITE_BLOB:
            throw unsupportedStorageClass(
                statement: statement,
                column: column,
                expected: "text",
                actual: "BLOB"
            )
        default:
            throw unsupportedStorageClass(
                statement: statement,
                column: column,
                expected: "text",
                actual: "unknown"
            )
        }
    }

    /**
     Returns one Requery `Cursor.getInt`-compatible signed integer from a result column.

     TEXT uses C `strtoll(..., base: 0)`, INTEGER truncates to signed 32 bits, REAL first truncates
     toward zero as a Java long, and SQL `NULL` becomes zero. BLOB remains a typed failure.

     - Throws: `.unsupportedStorageClass` for BLOB values.
     */
    func integer(_ statement: OpaquePointer, column: Int32) throws -> Int {
        let longValue: Int64
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL:
            longValue = 0
        case SQLITE_INTEGER:
            longValue = sqlite3_column_int64(statement, column)
        case SQLITE_FLOAT:
            let value = sqlite3_column_double(statement, column)
            if value.isFinite,
               value >= Double(Int64.min),
               value < Double(Int64.max) {
                longValue = Int64(value.rounded(.towardZero))
            } else {
                longValue = Int64.min
            }
        case SQLITE_TEXT:
            let value = try optionalText(statement, column: column) ?? ""
            longValue = value.withCString { pointer in
                strtoll(pointer, nil, 0)
            }
        case SQLITE_BLOB:
            throw unsupportedStorageClass(
                statement: statement,
                column: column,
                expected: "integer",
                actual: "BLOB"
            )
        default:
            throw unsupportedStorageClass(
                statement: statement,
                column: column,
                expected: "integer",
                actual: "unknown"
            )
        }
        return Int(Int32(truncatingIfNeeded: longValue))
    }

    /**
     Prepares and binds one read-only SQLite statement for a stepping helper.

     - Parameters:
       - sql: Static SQL statement text.
       - bindings: Positional integer, UTF-8 text, or Android string-coordinate values.
     - Returns: A bound statement that the caller must finalize.
     - Side effects: Allocates SQLite statement state and copies bound text into SQLite storage.
     - Throws: `SQLiteDocumentReaderError.queryFailed`; failed statements are finalized here.
     */
    private func prepareStatement(
        handle: OpaquePointer,
        _ sql: String,
        bindings: [SQLiteDocumentBinding]
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            let error = queryError(handle: handle)
            if let statement {
                sqlite3_finalize(statement)
            }
            throw error
        }

        do {
            for (offset, binding) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch binding {
                case .integer(let value):
                    result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
                case .text(let value):
                    result = try bindText(value, to: statement, index: index)
                case .coordinate(let value):
                    result = try bindText(String(value), to: statement, index: index)
                }
                guard result == SQLITE_OK else { throw queryError(handle: handle) }
            }
            return statement
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
    }

    /**
     Binds a Swift string with its explicit UTF-8 length so embedded NUL bytes remain significant.

     - Parameters:
       - value: Exact text selection argument.
       - statement: Prepared statement receiving the copied value.
       - index: One-based SQLite parameter index.
     - Returns: SQLite's bind result code.
     - Side effects: Copies the complete UTF-8 buffer into SQLite-owned storage.
     - Throws: `.queryFailed` when the UTF-8 payload cannot fit SQLite's 32-bit length API.
     */
    private func bindText(
        _ value: String,
        to statement: OpaquePointer,
        index: Int32
    ) throws -> Int32 {
        let bytes = value.utf8CString
        let byteCount = bytes.count - 1
        guard byteCount <= Int(Int32.max) else {
            throw SQLiteDocumentReaderError.queryFailed(
                fileName: url.lastPathComponent,
                message: "SQLite text binding exceeds the supported UTF-8 length"
            )
        }
        return bytes.withUnsafeBufferPointer { buffer in
            sqlite3_bind_text(
                statement,
                index,
                buffer.baseAddress,
                Int32(byteCount),
                sqliteDocumentReaderTransient
            )
        }
    }

    /**
     Executes one statement lifecycle on an independent handle with cancellation polling.

     - Parameter operation: Query work that prepares and finalizes every statement it creates.
     - Returns: The operation's value.
     - Side effects: Opens and closes one read-only handle and installs its progress callback.
     - Throws: `.cancelled` before work starts or any error produced by the operation.
     */
    private func withQueryConnection<Value>(
        _ operation: (OpaquePointer, SQLiteDocumentCancellationProbe) throws -> Value
    ) throws -> Value {
        let probe = SQLiteDocumentCancellationProbe()
        guard !probe.isCancelled() else {
            throw SQLiteDocumentReaderError.cancelled(fileName: url.lastPathComponent)
        }

        var handle: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let handle else {
            let message = handle
                .flatMap(sqlite3_errmsg)
                .map(String.init(cString:)) ?? "SQLite open failed with code \(openResult)"
            if let handle { sqlite3_close(handle) }
            throw SQLiteDocumentReaderError.cannotOpen(
                fileName: url.lastPathComponent,
                message: message
            )
        }
        defer { sqlite3_close(handle) }
        sqlite3_progress_handler(
            handle,
            Self.cancellationProgressInstructionCount,
            sqliteDocumentReaderProgressHandler,
            Unmanaged.passUnretained(probe).toOpaque()
        )
        defer { sqlite3_progress_handler(handle, 0, nil, nil) }
        return try operation(handle, probe)
    }

    /**
     Streams one result row through Requery's refillable native CursorWindow allocator model.

     The model includes its 420-byte initial header/chunk, 12-byte field slots, four-byte aligned
     directories and later row-slot chunks, exact BLOB bytes, and TEXT NUL terminators. A row that
     does not fit after earlier rows starts a fresh window; only failure in an empty window throws.

     - Parameters:
       - statement: Statement currently positioned on a row.
       - window: Current refill-window allocator state, reset when necessary.
     - Side effects: Reads storage classes and exact byte lengths without coercing values.
     - Throws: `.cursorWindowRowTooLarge` when the row cannot fit an empty Android window.
     */
    private func consumeCursorWindowRow(
        from statement: OpaquePointer,
        window: inout AndroidCursorWindowModel
    ) throws {
        if window.appendRow(from: statement) { return }
        window = AndroidCursorWindowModel()
        guard window.appendRow(from: statement) else {
            throw SQLiteDocumentReaderError.cursorWindowRowTooLarge(
                fileName: url.lastPathComponent,
                windowSize: Self.androidCursorWindowByteCount
            )
        }
    }

    /** Creates a typed storage-class error using SQLite's source column label when available. */
    private func unsupportedStorageClass(
        statement: OpaquePointer,
        column: Int32,
        expected: String,
        actual: String
    ) -> SQLiteDocumentReaderError {
        let name = sqlite3_column_name(statement, column)
            .map(String.init(cString:)) ?? "#\(column)"
        return .unsupportedStorageClass(
            fileName: url.lastPathComponent,
            column: name,
            expected: expected,
            actual: actual
        )
    }

    /** Maps the current SQLite handle diagnostic to a stable reader error. */
    private func queryError(handle: OpaquePointer) -> SQLiteDocumentReaderError {
        if sqlite3_errcode(handle) == SQLITE_INTERRUPT {
            return .cancelled(fileName: url.lastPathComponent)
        }
        return SQLiteDocumentReaderError.queryFailed(
            fileName: url.lastPathComponent,
            message: String(cString: sqlite3_errmsg(handle))
        )
    }
}

/** Filesystem traversal helpers that preserve Android's per-format native directory order. */
enum SQLiteDocumentDiscovery {
    /**
     Recursively finds readable regular files accepted by a format suffix predicate.

     - Parameters:
       - directoryURL: Root directory equivalent to Android's format-specific module directory.
       - accepts: Filename predicate, normally a case-insensitive suffix check.
     - Returns: Matching descendants in filesystem-native depth-first discovery order.
     - Side effects: Traverses the filesystem without opening database contents.
     - Failure modes: Missing/unreadable roots return an empty result. Symlink targets outside the
       root and repeated directory targets are skipped; no Android-visible depth/count ceiling is
       imposed.
     */
    static func recursiveFiles(
        in directoryURL: URL,
        accepts: (String) -> Bool
    ) -> [URL] {
        let root = directoryURL.standardizedFileURL
        guard isReadableDirectory(root) else { return [] }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var visitedDirectories: Set<String> = [resolvedRoot.path]
        var pending = Array(children(of: resolvedRoot).reversed())
        var matches: [URL] = []

        while let entry = pending.popLast() {
            guard contains(entry, beneath: resolvedRoot) else { continue }

            if isReadableDirectory(entry) {
                let resolvedDirectory = entry.resolvingSymlinksInPath().standardizedFileURL
                guard visitedDirectories.insert(resolvedDirectory.path).inserted else { continue }
                pending.append(contentsOf: children(of: resolvedDirectory).reversed())
            } else if isReadableRegularFile(entry), accepts(entry.lastPathComponent) {
                matches.append(entry.standardizedFileURL)
            }
        }
        return matches
    }

    /**
     Finds matching readable files directly inside one directory without descending.

     - Parameters:
       - directoryURL: Root directory equivalent to Android's e-Sword module directory.
       - accepts: Filename predicate.
     - Returns: Matching immediate children in filesystem-native order.
     - Side effects: Lists one directory without opening database contents.
     - Failure modes: Missing or unreadable roots produce an empty result.
     */
    static func directFiles(
        in directoryURL: URL,
        accepts: (String) -> Bool
    ) -> [URL] {
        let root = directoryURL.standardizedFileURL
        guard isReadableDirectory(root) else { return [] }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        return children(of: root)
            .filter {
                contains($0, beneath: resolvedRoot)
                    && isReadableRegularFile($0)
                    && accepts($0.lastPathComponent)
            }
            .map(\.standardizedFileURL)
    }

    /**
     Lists direct readable child directories whose resolved targets remain under the requested root.

     - Parameter directoryURL: Package-discovery root.
     - Returns: Native-order child directory URLs with cycles and external links omitted.
     - Side effects: Reads one directory and resolves candidate symlinks.
     - Failure modes: Missing or unreadable roots return an empty result.
     */
    static func directDirectories(in directoryURL: URL) -> [URL] {
        let root = directoryURL.standardizedFileURL
        guard isReadableDirectory(root) else { return [] }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var seen = Set<String>()
        return children(of: root).filter { candidate in
            guard contains(candidate, beneath: resolvedRoot), isReadableDirectory(candidate) else {
                return false
            }
            return seen.insert(
                candidate.resolvingSymlinksInPath().standardizedFileURL.path
            ).inserted
        }
    }

    /**
     Reports whether a readable regular file resolves beneath a trusted discovery root.

     - Parameters:
       - url: Candidate file or symlink.
       - root: Trusted package or family root.
     - Returns: `true` only for readable regular targets contained by the resolved root.
     - Side effects: Resolves symlinks and reads file metadata.
     - Failure modes: Metadata errors return `false`.
     */
    static func isContainedReadableRegularFile(_ url: URL, beneath root: URL) -> Bool {
        contains(url, beneath: root.resolvingSymlinksInPath().standardizedFileURL)
            && isReadableRegularFile(url)
    }

    /** Returns direct children in the same native order used by Android `File.listFiles()`. */
    private static func children(of directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: []
        )) ?? [])
    }

    /** Returns whether a candidate's resolved target is the root or one of its descendants. */
    private static func contains(_ candidate: URL, beneath resolvedRoot: URL) -> Bool {
        let rootPath = resolvedRoot.standardizedFileURL.path
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/")
    }

    /** Reports whether a URL is a readable directory suitable for Android-style discovery. */
    private static func isReadableDirectory(_ url: URL) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
            && FileManager.default.isReadableFile(atPath: resolvedURL.path)
    }

    /** Reports whether a URL is a readable regular file suitable for Android-style discovery. */
    private static func isReadableRegularFile(_ url: URL) -> Bool {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
            && FileManager.default.isReadableFile(atPath: resolvedURL.path)
    }
}

/**
 Reads MyBible Bible, commentary, and dictionary SQLite schemas used by Android.

 MyBible discovery recursively accepts readable `.sqlite3` files. Initialization reads identifying
 metadata but leaves optional stories and category-specific content validation to the first access,
 matching Android's lazy backend. Each operation owns an independent read-only connection.
 */
public final class MyBibleReader: SQLiteDocumentReading {
    /// Open validated MyBible database.
    private let database: SQLiteDocumentDatabase

    /// Whether the optional Android `stories` title table is available.
    private let hasStories: Bool

    /// Validated immutable metadata suitable for later backend catalog integration.
    public let metadata: SQLiteDocumentMetadata

    /// Schema-selected MyBible content category.
    public var category: DocumentCategory { metadata.category }

    /// User-visible module description retained for existing callers.
    public var moduleDescription: String { metadata.description }

    /// Module language retained for existing callers.
    public var language: String { metadata.language }

    /// Whether this database exposes the MyBible `verses` schema.
    public var isBible: Bool { category == .bible }

    /// Whether this database exposes the MyBible `commentaries` schema.
    public var isCommentary: Bool { category == .commentary }

    /// Whether this database exposes the MyBible `dictionary` schema.
    public var isDictionary: Bool { category == .dictionary }

    /// Whether dictionary metadata marks this module as a Strong's definition source.
    public var hasStrongsDefinitions: Bool { metadata.isStrongsDictionary }

    /// Whether Bible metadata advertises Strong's-number annotations.
    public var hasStrongs: Bool { metadata.hasStrongs }

    /// Whether Android would advertise the WordsOfChrist feature for this Bible.
    public var hasWordsOfChrist: Bool { metadata.hasWordsOfChrist }

    /**
     Opens one Android MyBible database and reads the metadata needed for catalog identity.

     - Parameter fileURL: Readable `.SQLite3` file URL.
     - Side effects: Opens and closes one read-only SQLite handle to validate the source.
     - Throws: `SQLiteDocumentReaderError` for unsupported filenames, invalid SQLite, missing
       identifying metadata, or a schema with no supported category table. Content-column and
       optional-story failures remain lazy until their operation is accessed.
     */
    public convenience init(fileURL: URL) throws {
        guard fileURL.lastPathComponent.lowercased().hasSuffix(".sqlite3") else {
            throw SQLiteDocumentReaderError.unsupportedFileName(
                format: .myBible,
                fileName: fileURL.lastPathComponent
            )
        }

        try self.init(validatedFileURL: fileURL)
    }

    /**
     Opens the exact payload selected by a trusted package sidecar, regardless of legacy suffix.

     The installer admits extension-bearing `.SQLite3`/`.mybible` payloads and an exact historical
     extensionless payload derived from the package filename. Manual discovery remains restricted to
     `.sqlite3`, while this boundary lets the package retain its repository identity.

     - Parameter packagePayloadURL: Contained readable payload already selected by package discovery.
     - Side effects: Opens and closes one read-only SQLite handle to validate the source.
     - Throws: `SQLiteDocumentReaderError` for unreadable SQLite, metadata, or schema failures.
     */
    convenience init(packagePayloadURL: URL) throws {
        try self.init(validatedFileURL: packagePayloadURL)
    }

    /** Performs suffix-independent schema and metadata validation for an admitted payload. */
    private init(validatedFileURL fileURL: URL) throws {
        let database = try SQLiteDocumentDatabase(url: fileURL)
        let tables = try database.tableNames()
        let category: DocumentCategory
        if tables.contains("verses") {
            category = .bible
        } else if tables.contains("commentaries") {
            category = .commentary
        } else if tables.contains("dictionary") {
            category = .dictionary
        } else {
            throw SQLiteDocumentReaderError.unsupportedSchema(
                format: .myBible,
                tables: tables.sorted()
            )
        }

        let hasStories = tables.contains("stories")
        self.database = database
        self.hasStories = hasStories
        self.metadata = try Self.loadMetadata(
            database: database,
            category: category,
            sourceURL: fileURL.standardizedFileURL
        )
    }

    /**
     Preserves the original failable path initializer for current reader and test callers.

     - Parameter filePath: Filesystem path to a `.SQLite3` file.
     - Side effects: Opens and closes one read-only SQLite handle on success.
     - Failure modes: Returns `nil` for every structured initialization error; new catalog code
       should use `init(fileURL:)` when diagnostics are needed.
     */
    public convenience init?(filePath: String) {
        try? self.init(fileURL: URL(fileURLWithPath: filePath))
    }

    /**
     Recursively discovers MyBible files exactly where Android's `walkTopDown` scan would look.

     - Parameter directoryURL: MyBible module directory.
     - Returns: Readable regular descendants whose path ends in `.sqlite3`, case-insensitively.
     - Side effects: Traverses the filesystem but does not open candidate databases.
     - Failure modes: Missing or unreadable directories return an empty array.
     */
    public static func discover(in directoryURL: URL) -> [URL] {
        SQLiteDocumentDiscovery.recursiveFiles(in: directoryURL) {
            $0.lowercased().hasSuffix(".sqlite3")
        }
    }

    /**
     Returns deterministic keys from the selected MyBible content table.

     Commentary rows expose their starting coordinate because Android resolves range coverage at
     lookup time; dictionary topics retain exact source casing.

     - Returns: Typed keys ordered by coordinate or topic.
     - Side effects: Reads the open SQLite database.
     - Throws: `SQLiteDocumentReaderError.queryFailed` on SQLite failure, or
       `.cursorWindowRowTooLarge` if Android cannot expose one source row.
     */
    public func keys() throws -> [SQLiteDocumentKey] {
        switch category {
        case .bible:
            return try database.rows(
                "SELECT book_number, chapter, verse FROM verses ORDER BY book_number, chapter, verse"
            ) { statement in
                .verse(
                    book: try database.integer(statement, column: 0),
                    chapter: try database.integer(statement, column: 1),
                    verse: try database.integer(statement, column: 2)
                )
            }
        case .commentary:
            return try database.rows(
                """
                SELECT DISTINCT book_number, chapter_number_from, verse_number_from
                FROM commentaries
                ORDER BY book_number, chapter_number_from, verse_number_from
                """
            ) { statement in
                .verse(
                    book: try database.integer(statement, column: 0),
                    chapter: try database.integer(statement, column: 1),
                    verse: try database.integer(statement, column: 2)
                )
            }
        case .dictionary:
            return try database.rows("SELECT topic FROM dictionary") { statement in
                .dictionary(try database.text(statement, column: 0))
            }
        default:
            return []
        }
    }

    /**
     Streams distinct MyBible chapter coordinates without retaining the whole verse-key result.

     - Parameter body: Consumer receiving source book and chapter values in numeric order.
     - Side effects: Executes one read-only `verses` query on an operation-owned connection.
     - Throws: Shared query, cancellation, coercion, CursorWindow, or consumer failures.
     */
    public func forEachBibleChapter(_ body: (Int, Int) throws -> Bool) throws {
        guard category == .bible else { return }
        do {
            try database.consumeRows(
                """
                SELECT DISTINCT book_number, chapter
                FROM verses
                ORDER BY book_number, chapter
                """,
                transform: { statement in
                    (
                        try database.integer(statement, column: 0),
                        try database.integer(statement, column: 1)
                    )
                },
                consume: {
                    guard try body($0.0, $0.1) else {
                        throw SQLiteDocumentChapterIterationStop.requested
                    }
                }
            )
        } catch SQLiteDocumentChapterIterationStop.requested {
            return
        }
    }

    /**
     Streams books satisfying Android's `DocumentBibleBooks` 1:1-or-1:2 containment probe.

     Bible rows use exact coordinates. Commentary rows mirror `MyBibleBook.indexOfCommentary`, whose
     chapter and verse comparisons are intentionally independent and differ from content rendering's
     special 1:1 lower bound.

     - Parameter body: Consumer receiving each matching MyBible source book number.
     - Side effects: Executes at most one read-only query and may emit duplicate book numbers.
     - Throws: Shared query, cancellation, coercion, CursorWindow, or consumer failures.
     */
    public func forEachNavigationBookNumber(_ body: (Int) throws -> Void) throws {
        switch category {
        case .bible:
            try database.consumeRows(
                "SELECT book_number FROM verses WHERE chapter = 1 AND (verse = 1 OR verse = 2)",
                transform: { try database.integer($0, column: 0) },
                consume: body
            )
        case .commentary:
            try database.consumeRows(
                """
                SELECT book_number FROM commentaries WHERE
                    (chapter_number_from <= 1 AND verse_number_from <= 1 AND
                     chapter_number_to >= 1 AND verse_number_to >= 1) OR
                    (chapter_number_from = 1 AND verse_number_from = 1 AND
                     (chapter_number_to IS NULL OR chapter_number_to = 0) AND
                     (verse_number_to IS NULL OR verse_number_to = 0)) OR
                    (chapter_number_from <= 1 AND verse_number_from <= 2 AND
                     chapter_number_to >= 1 AND verse_number_to >= 2) OR
                    (chapter_number_from = 1 AND verse_number_from = 2 AND
                     (chapter_number_to IS NULL OR chapter_number_to = 0) AND
                     (verse_number_to IS NULL OR verse_number_to = 0))
                """,
                transform: { try database.integer($0, column: 0) },
                consume: body
            )
        default:
            return
        }
    }

    /**
     Resolves Bible, commentary-range, or dictionary content using Android's MyBible SQL contract.

     Bible results include optional `stories` titles. Commentary results join every covering row in
     Android order with the Kotlin `joinToString` default separator `, `.

     - Parameter key: Typed verse or dictionary key.
     - Returns: Resolved content, or `nil` when the key/category pair has no matching row.
     - Side effects: Reads the open SQLite database.
     - Throws: `SQLiteDocumentReaderError.queryFailed` on SQLite failure.
     */
    public func content(for key: SQLiteDocumentKey) throws -> SQLiteDocumentContent? {
        let text: String?
        switch (category, key) {
        case (.bible, .verse(let book, let chapter, let verse)):
            text = try bibleText(book: book, chapter: chapter, verse: verse)
        case (.commentary, .verse(let book, let chapter, let verse)):
            text = try commentaryText(book: book, chapter: chapter, verse: verse)
        case (.dictionary, .dictionary(let topic)):
            text = try database.firstText(
                "SELECT definition FROM dictionary WHERE topic = ?",
                bindings: [.text(topic)]
            )
        default:
            text = nil
        }
        return text.map { SQLiteDocumentContent(key: key, text: $0) }
    }

    /**
     Returns one Bible verse through the original nonthrowing API.

     - Parameters:
       - book: MyBible `book_number` value.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: Android-compatible verse text, including story titles, or `nil` when absent/error.
     - Side effects: Reads the open SQLite database.
     - Failure modes: SQLite errors are collapsed to `nil` for legacy caller compatibility.
     */
    public func getVerse(book: Int, chapter: Int, verse: Int) -> String? {
        (try? content(for: .verse(book: book, chapter: chapter, verse: verse)))?.text
    }

    /**
     Returns commentary covering one verse through a convenience API.

     - Parameters:
       - book: MyBible `book_number` value.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: Android-joined commentary fragments, or `nil` when absent/error.
     - Side effects: Reads the open SQLite database.
     - Failure modes: SQLite errors are collapsed to `nil`.
     */
    public func getCommentary(book: Int, chapter: Int, verse: Int) -> String? {
        guard isCommentary else { return nil }
        return (try? content(for: .verse(book: book, chapter: chapter, verse: verse)))?.text
    }

    /**
     Returns a dictionary entry by its exact MyBible topic key.

     - Parameter key: Topic such as `00430`, `H0430`, or `H430`.
     - Returns: Raw definition text, or `nil` when absent/error or not a dictionary.
     - Side effects: Reads the open SQLite database.
     - Failure modes: SQLite errors are collapsed to `nil` for Strong's builder compatibility.
     */
    public func getDictionaryEntry(key: String) -> String? {
        guard isDictionary else { return nil }
        return (try? content(for: .dictionary(key)))?.text
    }

    /**
     Returns all exact MyBible dictionary topics in deterministic order.

     - Returns: Topic strings, or an empty array for other categories/SQLite failure.
     - Side effects: Reads the open SQLite database.
     - Failure modes: SQLite errors are collapsed to an empty array.
     */
    public func dictionaryKeys() -> [String] {
        guard isDictionary, let keys = try? keys() else { return [] }
        return keys.compactMap { key in
            guard case .dictionary(let topic) = key else { return nil }
            return topic
        }
    }

    /**
     Returns a full Bible chapter through the original tuple API.

     - Parameters:
       - book: MyBible `book_number` value.
       - chapter: One-based chapter number.
     - Returns: Verse/text tuples ordered by verse, including optional story-title projection.
     - Side effects: Reads the open SQLite database.
     - Failure modes: SQLite failures return an empty array.
     */
    public func getChapter(book: Int, chapter: Int) -> [(verse: Int, text: String)] {
        (try? chapterContent(book: book, chapter: chapter)) ?? []
    }

    /**
     Reads a MyBible chapter with one verse query and at most one optional stories query.

     Duplicate coordinates preserve Android point-lookup semantics by retaining the first row in
     database scan order. Story rows are fetched once for the chapter and then projected in their
     database order, eliminating per-verse query amplification.

     - Parameters:
       - book: MyBible `book_number` value bound as Android text.
       - chapter: One-based chapter number bound as Android text.
     - Returns: One row per distinct present verse, ordered numerically.
     - Side effects: Executes one or two read-only queries on operation-owned connections.
     - Throws: Shared query, cancellation, coercion, or CursorWindow errors.
     */
    public func chapterContent(book: Int, chapter: Int) throws -> [(verse: Int, text: String)] {
        guard isBible else { return [] }
        var firstTextByVerse: [Int: SQLiteDocumentTextRow] = [:]
        try database.consumeRows(
            "SELECT verse, text FROM verses WHERE book_number = ? AND chapter = ?",
            bindings: [.coordinate(book), .coordinate(chapter)],
            transform: { statement in
                (
                    verse: try database.integer(statement, column: 0),
                    text: try database.optionalText(statement, column: 1)
                )
            },
            consume: { row in
                guard firstTextByVerse[row.verse] == nil else { return }
                firstTextByVerse[row.verse] = SQLiteDocumentTextRow(value: row.text)
            }
        )

        var textByVerse = firstTextByVerse.mapValues { $0.value ?? "" }
        if hasStories {
            var versesWithStories = Set<Int>()
            try database.consumeRows(
                "SELECT verse, title FROM stories WHERE book_number = ? AND chapter = ?",
                bindings: [.coordinate(book), .coordinate(chapter)],
                transform: { statement in
                    (
                        verse: try database.integer(statement, column: 0),
                        title: try database.text(statement, column: 1)
                    )
                },
                consume: { row in
                    guard let sourceText = firstTextByVerse[row.verse] else { return }
                    let isFirstStory = versesWithStories.insert(row.verse).inserted
                    let currentText = isFirstStory ? sourceText.value : textByVerse[row.verse]
                    textByVerse[row.verse] = Self.applyingStories(
                        row.title,
                        to: currentText,
                        isFirstStory: isFirstStory
                    )
                }
            )
        }

        return textByVerse.keys.sorted().map { verse in
            (
                verse,
                textByVerse[verse] ?? ""
            )
        }
    }

    /**
     Returns optional MyBible book-name metadata through the original tuple API.

     - Returns: Book number, long name, and short name ordered by `book_number`; modules without a
       `books` table return an empty array because Android content lookup does not require it.
     - Side effects: Reads the open SQLite database.
     - Failure modes: Missing optional tables or SQLite errors return an empty array.
     */
    public func books() -> [(number: Int, name: String, shortName: String)] {
        guard let tables = try? database.tableNames(), tables.contains("books"),
              let rows = try? database.rows(
                "SELECT book_number, long_name, short_name FROM books ORDER BY book_number",
                transform: { statement in
                    (
                        try database.integer(statement, column: 0),
                        try database.text(statement, column: 1),
                        try database.text(statement, column: 2)
                    )
                }
              ) else { return [] }
        return rows
    }

    /** Loads Android-derived metadata after schema validation. */
    private static func loadMetadata(
        database: SQLiteDocumentDatabase,
        category: DocumentCategory,
        sourceURL: URL
    ) throws -> SQLiteDocumentMetadata {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let initials = "MyBible-" + SQLiteDocumentIdentity.sanitizedModuleName(baseName)
        let abbreviation = String(baseName.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first ?? Substring(baseName))
        let description = try infoValue(
            database: database,
            name: "description",
            defaultValue: ""
        )
        let language = try infoValue(database: database, name: "language", defaultValue: "en")
        let hasStrongsDictionary = try infoValue(
            database: database,
            name: "is_strong",
            defaultValue: ""
        ) == "true"
        let hasStrongs = try infoValue(
            database: database,
            name: "strong_numbers",
            defaultValue: ""
        ) == "true"
        let hasWordsOfChrist = try wordsOfChristAvailable(
            database: database,
            category: category
        )

        return SQLiteDocumentMetadata(
            sourceURL: database.url,
            format: .myBible,
            initials: initials,
            abbreviation: abbreviation,
            title: description.isEmpty ? abbreviation : description,
            description: description,
            language: language,
            version: "0.0",
            category: category,
            direction: .ltr,
            hasStrongs: hasStrongs,
            isStrongsDictionary: hasStrongsDictionary,
            hasWordsOfChrist: hasWordsOfChrist
        )
    }

    /** Reads the first exact-name MyBible metadata value with Android's missing-row fallback. */
    private static func infoValue(
        database: SQLiteDocumentDatabase,
        name: String,
        defaultValue: String
    ) throws -> String {
        guard let row = try database.firstTextRow(
            "SELECT value FROM info WHERE name = ?",
            bindings: [.text(name)]
        ) else { return defaultValue }
        return row.value ?? defaultValue
    }

    /** Detects Android's exact-name metadata flags and `<J>` content fallback. */
    private static func wordsOfChristAvailable(
        database: SQLiteDocumentDatabase,
        category: DocumentCategory
    ) throws -> Bool {
        guard category == .bible else { return false }
        let flags = try database.rows(
            """
            SELECT value FROM info
            WHERE name IN ('is_words_of_christ', 'words_of_christ', 'is_red_letter', 'red_letter')
            """
        ) { try database.optionalText($0, column: 0) }
        if flags.contains(where: parseMyBibleBoolean) {
            return true
        }
        do {
            return try database.firstText(
                "SELECT '1' FROM verses WHERE instr(lower(text), '<j>') > 0 LIMIT 1"
            ) != nil
        } catch let error as SQLiteDocumentReaderError {
            guard case .queryFailed = error else { throw error }
            return false
        }
    }

    /** Parses the MyBible boolean forms Android accepts for WordsOfChrist metadata flags. */
    private static func parseMyBibleBoolean(_ value: String?) -> Bool {
        value?.caseInsensitiveCompare("true") == .orderedSame || value == "1"
    }

    /**
     Reads one MyBible verse and applies Android's nullable-text and optional-story behavior.

     - Parameters:
       - book: MyBible book number.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: Projected verse text, an empty string for a present SQL `NULL`, or `nil` when the
       coordinate has no row.
     - Side effects: Reads `verses` and, when available, `stories` from the open database.
     - Throws: `SQLiteDocumentReaderError` for query or row-materialization failures.
     */
    private func bibleText(book: Int, chapter: Int, verse: Int) throws -> String? {
        guard let row = try database.firstTextRow(
            "SELECT text FROM verses WHERE book_number = ? AND chapter = ? AND verse = ?",
            bindings: [.coordinate(book), .coordinate(chapter), .coordinate(verse)]
        ) else { return nil }
        var text = row.value ?? ""

        if hasStories {
            var hasAppliedStory = false
            try database.consumeRows(
                """
                SELECT title FROM stories
                WHERE book_number = ? AND chapter = ? AND verse = ?
                """,
                bindings: [.coordinate(book), .coordinate(chapter), .coordinate(verse)],
                transform: { try database.text($0, column: 0) },
                consume: { story in
                    text = Self.applyingStories(
                        story,
                        to: hasAppliedStory ? text : row.value,
                        isFirstStory: !hasAppliedStory
                    )
                    hasAppliedStory = true
                }
            )
        }
        return text
    }

    /**
     Reads every MyBible commentary row selected by Android's observable independent comparisons.

     Android compares chapter and verse columns independently rather than as lexicographic
     coordinates. This intentionally reproduces that result, including its surprising behavior for
     cross-chapter ranges, because changing it would alter installed commentary output rather than
     prevent corruption. A no-match query returns Android's empty `joinToString` result.

     - Parameters:
       - book: MyBible book number bound as text.
       - chapter: One-based target chapter bound as text.
       - verse: One-based target verse bound as text.
     - Returns: Joined `<div>` fragments, or an empty string when no rows match.
     - Side effects: Executes one read-only query on an operation-owned connection.
     - Throws: Shared query, cancellation, coercion, or CursorWindow errors.
     */
    private func commentaryText(book: Int, chapter: Int, verse: Int) throws -> String? {
        let fromChapter = chapter == 1 && verse == 1 ? 0 : chapter
        let fromVerse = chapter == 1 && verse == 1 ? 0 : verse
        var result = ""
        var hasRow = false
        try database.consumeRows(
            """
            SELECT text FROM commentaries
            WHERE book_number = ? AND (
                (
                    chapter_number_from <= ? AND verse_number_from <= ? AND
                    chapter_number_to >= ? AND verse_number_to >= ?
                ) OR (
                    chapter_number_from = ? AND verse_number_from = ? AND
                    (chapter_number_to IS NULL OR chapter_number_to = 0) AND
                    (verse_number_to IS NULL OR verse_number_to = 0)
                )
            )
            ORDER BY chapter_number_from, verse_number_from
            """,
            bindings: [
                .coordinate(book),
                .coordinate(chapter),
                .coordinate(verse),
                .coordinate(fromChapter),
                .coordinate(fromVerse),
                .coordinate(chapter),
                .coordinate(verse),
            ],
            transform: { try database.text($0, column: 0) },
            consume: { text in
                if hasRow { result += ", " }
                result += "<div>\(text)</div>"
                hasRow = true
            }
        )
        return result
    }

    /**
     Applies one optional MyBible story title in source database order.

     Android interpolates nullable verse text as literal `null` once any story exists, appends titles
     beginning with `<`, and prepends every other title. The ordering and null marker are exact. To
     keep the observable result structurally usable as OSIS, valid source fragments are retained,
     malformed fragments become escaped visible text, and plain title text is XML-escaped.

     - Parameters:
       - story: Current story title value.
       - text: Nullable source text for the first story or prior projected text thereafter.
       - isFirstStory: Whether Android's nullable interpolation must be applied to the source text.
     - Returns: Verse text with this story projection applied.
     - Side effects: None.
     - Failure modes: None; every Swift string has a deterministic XML-text projection.
     */
    private static func applyingStories(
        _ story: String,
        to text: String?,
        isFirstStory: Bool
    ) -> String {
        let result: String
        if isFirstStory {
            result = text.map(SQLiteDocumentXMLCompatibility.validatedFragmentOrEscapedText) ?? "null"
        } else {
            result = text ?? ""
        }
        if story.hasPrefix("<") {
            return result + SQLiteDocumentXMLCompatibility.validatedFragmentOrEscapedText(story)
        }
        return "<title canonical=\"false\">\(SQLiteDocumentXMLCompatibility.escapedText(story))</title>\(result)"
    }
}
