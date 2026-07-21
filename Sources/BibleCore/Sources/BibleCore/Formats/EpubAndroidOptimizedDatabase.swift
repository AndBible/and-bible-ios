// EpubAndroidOptimizedDatabase.swift -- Android SQLite validation and native publication

import Foundation
import SQLite3

/**
 Completes Android optimized-index import after Room fragment and mapping validation.

 Optional Android search state is checked against the imported fragment set, while native metadata,
 content, navigation, styles, anchors, and FTS rows are published through the shared index schema.
 */
extension EpubAndroidOptimizedIndexImporter {
    /**
     Validates an optional Android FTS database without trusting it as the native search index.

     Native FTS rows are deterministically rebuilt from BVA text so absent Android search state is
     still searchable. When Android did include `SearchIndex`, every row must reference an imported
     fragment and an ordinal inside that fragment, preventing stale cross-generation search data.

     - Parameters:
       - searchDatabaseURL: Exact identity-bound Android search database path.
       - fragments: Imported fragment records.
     - Side effects: Opens and reads the optional SQLite database.
     - Throws: `EpubError.invalidEpub` for corruption, schema mismatch, or invalid result targets.
     */
    static func validateSearchDatabase(
        at searchDatabaseURL: URL,
        fragments: [FragmentRecord]
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            searchDatabaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw EpubError.invalidEpub("Android EPUB search database is not readable SQLite")
        }
        defer { sqlite3_close(database) }
        try validateSQLiteIntegrity(database, description: "Android EPUB search database")

        let columns = try tableColumns("SearchIndex", database: database)
        guard !columns.isEmpty else { return }
        guard Set(["contentText", "frag_id", "ordinal"]).isSubset(of: columns) else {
            throw EpubError.invalidEpub("Android EPUB search database has an unsupported schema")
        }
        let fragmentByID = Dictionary(uniqueKeysWithValues: fragments.map { ($0.id, $0) })
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT contentText, frag_id, ordinal FROM SearchIndex",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw sqliteInvalid(database, operation: "reading Android EPUB search rows")
        }
        defer { sqlite3_finalize(statement) }
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard EpubReader.columnText(statement, index: 0) != nil,
                  let fragmentID = exactInteger(statement, index: 1),
                  let fragment = fragmentByID[fragmentID],
                  let ordinal = exactInteger(statement, index: 2),
                  fragment.ordinalRange.contains(ordinal) else {
                throw EpubError.invalidEpub("Android EPUB search row targets another fragment set")
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw sqliteInvalid(database, operation: "reading Android EPUB search rows")
        }
    }

    /**
     Writes validated Android rows into the ordinary current-version native index schema.

     - Parameters:
       - indexURL: Staging destination for the native SQLite database.
       - package: Parsed OPF/navigation model.
       - fragments: Android fragments in numeric ID order.
       - mappings: Exact base/XHTML-id mappings.
       - styles: Canonical stylesheet rows in Android order.
       - resourceIdentity: Initials and generation metadata.
       - sourceFileName: Exact Android display-name directory component.
     - Side effects: Creates and transactionally fills `indexURL`, including native FTS rows.
     - Throws: `EpubError.indexingFailed` or an insertion error; failed transactions are rolled back.
     */
    static func writeNativeIndex(
        at indexURL: URL,
        package: EpubPackageDocument,
        fragments: [FragmentRecord],
        mappings: [AnchorMapping],
        styles: [StyleRecord],
        resourceIdentity: EpubResourceIdentity,
        sourceFileName: String
    ) throws {
        let database = try EpubReader.createIndexDatabase(at: indexURL)
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw EpubError.indexingFailed(EpubReader.sqliteMessage(database))
        }
        do {
            try EpubReader.insertMetadata(
                package: package,
                resourceIdentity: resourceIdentity,
                sourceFileName: sourceFileName,
                database: database
            )
            let spineOrdinalByID = Dictionary(uniqueKeysWithValues: try renderableSpineItems(
                package: package
            ).map { ($0.item.id, $0.ordinal) })
            let stylePathsByID = Dictionary(grouping: styles, by: \.originalID)
                .mapValues { $0.map(\.path) }
            var nextFragmentOrdinalByID: [String: Int] = [:]
            for record in fragments {
                guard let item = package.manifestByID[record.originalID],
                      let spineOrdinal = spineOrdinalByID[record.originalID] else {
                    throw EpubError.invalidEpub("Android EPUB fragment lost its OPF spine identity")
                }
                let fragmentOrdinal = nextFragmentOrdinalByID[record.originalID, default: 0]
                let pageTitle = package.navigation.first(where: { $0.key == item.id })?.title
                    ?? URL(fileURLWithPath: item.path).deletingPathExtension().lastPathComponent
                try EpubReader.insertContent(
                    record.transformed.fragment,
                    id: record.id,
                    originalKey: record.originalID,
                    href: item.path,
                    styleSheetPaths: stylePathsByID[record.originalID] ?? [],
                    title: pageTitle.isEmpty ? item.id : pageTitle,
                    spineOrdinal: spineOrdinal,
                    fragmentOrdinal: fragmentOrdinal,
                    database: database
                )
                nextFragmentOrdinalByID[record.originalID] = fragmentOrdinal + 1
            }
            for mapping in mappings {
                try EpubReader.insertAnchorMapping(
                    originalKey: mapping.originalID,
                    htmlID: mapping.htmlID,
                    fragmentID: mapping.fragmentID,
                    database: database
                )
            }
            for (ordinal, point) in package.navigation.enumerated() {
                try EpubReader.insertNavigation(point, ordinal: ordinal, database: database)
            }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw EpubError.indexingFailed(EpubReader.sqliteMessage(database))
            }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /**
     Runs SQLite's full integrity check and requires one exact `ok` result.

     - Parameters:
       - database: Open read-only SQLite connection.
       - description: Diagnostic prefix naming the Android artifact.
     - Side effects: Reads every database page as directed by SQLite.
     - Throws: `EpubError.invalidEpub` for prepare, step, or integrity failures.
     */
    static func validateSQLiteIntegrity(
        _ database: OpaquePointer,
        description: String
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else {
            throw sqliteInvalid(database, operation: "checking \(description)")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              EpubReader.columnText(statement, index: 0) == "ok",
              sqlite3_step(statement) == SQLITE_DONE else {
            throw EpubError.invalidEpub("\(description) failed SQLite integrity validation")
        }
    }

    /**
     Reads one integer-valued SQLite pragma.

     - Parameters:
       - name: Compile-time pragma name supplied by this importer.
       - database: Open SQLite connection.
     - Returns: Exact platform `Int` value.
     - Side effects: Executes one read-only pragma.
     - Throws: `EpubError.invalidEpub` if SQLite cannot return exactly one integer row.
     */
    static func integerPragma(_ name: String, database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA \(name)", -1, &statement, nil) == SQLITE_OK else {
            throw sqliteInvalid(database, operation: "reading Android EPUB database version")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = exactInteger(statement, index: 0),
              sqlite3_step(statement) == SQLITE_DONE else {
            throw EpubError.invalidEpub("Android EPUB database pragma is invalid")
        }
        return value
    }

    /**
     Requires a known subset of columns in one Android Room table.

     - Parameters:
       - required: Column names used by this importer.
       - table: Compile-time Room table name.
       - database: Open Android SQLite connection.
     - Side effects: Reads SQLite schema metadata.
     - Throws: `EpubError.invalidEpub` when the table is missing or its schema is incompatible.
     */
    static func requireColumns(
        _ required: Set<String>,
        table: String,
        database: OpaquePointer
    ) throws {
        let columns = try tableColumns(table, database: database)
        guard required.isSubset(of: columns) else {
            throw EpubError.invalidEpub("Android EPUB database table \(table) has an unsupported schema")
        }
    }

    /**
     Reads the exact column-name set for one compile-time SQLite table.

     - Parameters:
       - table: Trusted table name owned by this importer.
       - database: Open SQLite connection.
     - Returns: Column names from `PRAGMA table_info` or an empty set when the table is absent.
     - Side effects: Reads SQLite schema metadata.
     - Throws: `EpubError.invalidEpub` when the pragma cannot be prepared or stepped completely.
     */
    static func tableColumns(
        _ table: String,
        database: OpaquePointer
    ) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA table_info(\"\(table)\")",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw sqliteInvalid(database, operation: "reading Android EPUB schema")
        }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let name = EpubReader.columnText(statement, index: 1) else {
                throw EpubError.invalidEpub("Android EPUB database schema row is incomplete")
            }
            columns.insert(name)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw sqliteInvalid(database, operation: "reading Android EPUB schema")
        }
        return columns
    }

    /**
     Converts one SQLite integer column to `Int` without truncation or coercing NULL.

     - Parameters:
       - statement: Stepped SQLite statement positioned on a row.
       - index: Zero-based column index.
     - Returns: Exact `Int`, or `nil` for NULL/non-integer/out-of-range values.
     - Side effects: Reads the current statement row only.
     - Failure modes: Returns `nil` instead of throwing so row validators can emit contract errors.
     */
    static func exactInteger(_ statement: OpaquePointer?, index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else { return nil }
        return Int(exactly: sqlite3_column_int64(statement, index))
    }

    /**
     Builds a stable invalid-EPUB error from SQLite's current diagnostic.

     - Parameters:
       - database: Open Android SQLite connection.
       - operation: Human-readable read operation that failed.
     - Returns: `EpubError.invalidEpub` retaining SQLite's diagnostic without exposing SQL data.
     - Side effects: Reads connection error state only.
     - Failure modes: None.
     */
    static func sqliteInvalid(
        _ database: OpaquePointer?,
        operation: String
    ) -> EpubError {
        .invalidEpub("\(operation) failed: \(EpubReader.sqliteMessage(database))")
    }
}
