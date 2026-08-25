// SearchIndexSQLiteStoreBootstrap.swift — Connection creation and generated-schema ownership

import Foundation
import SQLite3

/**
 Opens and initializes the generated Search SQLite store as one schema contract.

 Generated Search rows are reproducible from installed sources, so incompatible partial schemas are
 dropped and rebuilt atomically during connection bootstrap. The returned handle uses full mutex and
 WAL exactly as the prior `SearchIndexService` implementation; the caller becomes its sole owner.

 - Side effects: Opens or creates the SQLite file, enables WAL, and creates/migrates generated tables.
 - Failure modes: Throws `SearchIndexError` for open or schema operations and closes every handle not
 returned successfully.
 */
enum SearchIndexSQLiteStoreBootstrap {
    /**
     Opens one writable generated-index connection and installs the current schema.

     - Parameter path: Absolute SQLite database path owned by one `SearchIndexService` instance.
     - Returns: Fully initialized SQLite handle whose lifetime transfers to the caller.
     - Side effects: May create the file, WAL sidecars, and generated schema tables.
     - Failure modes: Throws a typed SQLite error and closes any partially initialized handle.
     */
    static func open(path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let openCode = sqlite3_open_v2(
            path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openCode == SQLITE_OK, let handle else {
            let message = handle.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
                ?? "SQLite error \(openCode)"
            if let handle { sqlite3_close(handle) }
            throw SearchIndexError.sqlite(
                operation: "opening the database",
                code: openCode,
                message: message
            )
        }

        do {
            try execute(db: handle, sql: "PRAGMA journal_mode=WAL", operation: "enabling WAL")
            if schemaNeedsRebuild(db: handle) {
                try dropGeneratedSchema(db: handle)
            }
            try createSchema(db: handle)
            return handle
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    /**
     Detects any persisted schema that cannot represent current analyzer/source contracts.

     - Parameter db: Open writer connection during bootstrap.
     - Returns: `true` when any generated table exists but lacks a required column.
     - Side effects: Executes read-only `PRAGMA table_info` statements.
     - Failure modes: An unreadable table shape appears empty and is recreated by `createSchema`.
     */
    private static func schemaNeedsRebuild(db: OpaquePointer?) -> Bool {
        let ftsColumns = tableColumns(db: db, tableName: "verse_fts")
        let strongsColumns = tableColumns(db: db, tableName: "verse_strongs")
        let metadataColumns = tableColumns(db: db, tableName: "indexed_modules")
        let stateColumns = tableColumns(db: db, tableName: "search_index_state")
        guard !ftsColumns.isEmpty
                || !strongsColumns.isEmpty
                || !metadataColumns.isEmpty
                || !stateColumns.isEmpty else { return false }

        let requiredFTS: Set<String> = [
            "search_text", "verse_key", "plain_text", "module_name", "entry_order",
            "osis_book", "display_book", "display_book_mode", "chapter", "verse", "book_order",
            "canon_scope",
        ]
        let requiredMetadata: Set<String> = [
            "module_name", "verse_count", "indexed_at", "schema_version", "language_code",
            "analyzer_id", "strongs_complete", "source_version", "source_fingerprint",
            "store_generation",
        ]
        let requiredStrongs: Set<String> = [
            "module_name", "token", "verse_key", "entry_order", "highlight_ranges",
        ]
        let requiredState: Set<String> = ["id", "store_generation"]
        return !requiredFTS.isSubset(of: ftsColumns)
            || !requiredStrongs.isSubset(of: strongsColumns)
            || !requiredMetadata.isSubset(of: metadataColumns)
            || !requiredState.isSubset(of: stateColumns)
    }

    /**
     Returns exact SQLite column names for one generated table.

     - Parameters:
       - db: Open bootstrap writer connection.
       - tableName: Trusted generated table name used in `PRAGMA table_info`.
     - Returns: Exact column-name set, or an empty set when absent/unreadable.
     - Side effects: Executes one read-only schema statement.
     - Failure modes: Prepare/read failure returns an empty set so schema creation can repair it.
     */
    private static func tableColumns(db: OpaquePointer?, tableName: String) -> Set<String> {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db,
            "PRAGMA table_info(\(tableName))",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            return []
        }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW,
              let pointer = sqlite3_column_text(statement, 1) {
            columns.insert(String(cString: pointer))
        }
        return columns
    }

    /**
     Drops every reproducible generated table before an incompatible-schema rebuild.

     - Parameter db: Open bootstrap writer connection.
     - Side effects: Drops Strong's, text, metadata, and generation-state tables when present.
     - Throws: First typed SQLite failure; caller closes the incomplete bootstrap handle.
     */
    private static func dropGeneratedSchema(db: OpaquePointer?) throws {
        try execute(
            db: db,
            sql: "DROP TABLE IF EXISTS verse_strongs",
            operation: "dropping Strong's index"
        )
        try execute(
            db: db,
            sql: "DROP TABLE IF EXISTS verse_fts",
            operation: "dropping text index"
        )
        try execute(
            db: db,
            sql: "DROP TABLE IF EXISTS indexed_modules",
            operation: "dropping index metadata"
        )
        try execute(
            db: db,
            sql: "DROP TABLE IF EXISTS search_index_state",
            operation: "dropping index state"
        )
    }

    /**
     Creates every generated table/index and invalidates stale completion metadata.

     - Parameter db: Open bootstrap writer connection.
     - Side effects: Creates idempotent schema objects and deletes incompatible/incomplete metadata.
     - Throws: First typed SQLite schema or cleanup failure.
     */
    private static func createSchema(db: OpaquePointer?) throws {
        try execute(db: db, sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS verse_fts USING fts5(
                search_text,
                verse_key UNINDEXED,
                plain_text UNINDEXED,
                module_name UNINDEXED,
                entry_order UNINDEXED,
                osis_book UNINDEXED,
                display_book UNINDEXED,
                display_book_mode UNINDEXED,
                chapter UNINDEXED,
                verse UNINDEXED,
                book_order UNINDEXED,
                canon_scope UNINDEXED,
                tokenize='ascii'
            )
        """, operation: "creating the text index")
        try execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS verse_strongs (
                module_name TEXT NOT NULL,
                token TEXT NOT NULL,
                verse_key TEXT NOT NULL,
                entry_order INTEGER NOT NULL,
                highlight_ranges TEXT NOT NULL,
                PRIMARY KEY (module_name, token, verse_key)
            )
        """, operation: "creating the Strong's index")
        try execute(db: db, sql: """
            CREATE INDEX IF NOT EXISTS idx_verse_strongs_module_token
            ON verse_strongs (module_name, token, entry_order)
        """, operation: "creating the Strong's lookup")
        try execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS search_index_state (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                store_generation INTEGER NOT NULL
            )
        """, operation: "creating search index state")
        try execute(db: db, sql: """
            INSERT OR IGNORE INTO search_index_state (id, store_generation) VALUES (1, 0)
        """, operation: "initializing search index state")
        try execute(db: db, sql: """
            CREATE TABLE IF NOT EXISTS indexed_modules (
                module_name TEXT PRIMARY KEY,
                verse_count INTEGER NOT NULL,
                indexed_at TEXT NOT NULL,
                schema_version INTEGER NOT NULL,
                language_code TEXT NOT NULL,
                analyzer_id TEXT NOT NULL,
                strongs_complete INTEGER NOT NULL DEFAULT 0,
                source_version TEXT NOT NULL,
                source_fingerprint TEXT NOT NULL,
                store_generation INTEGER NOT NULL
            )
        """, operation: "creating index metadata")
        try execute(db: db, sql: """
            DELETE FROM indexed_modules
            WHERE schema_version != \(SearchIndexService.currentSchemaVersion)
               OR verse_count <= 0 OR analyzer_id = '' OR source_fingerprint = ''
        """, operation: "invalidating stale indexes")
    }

    /**
     Executes one schema statement and translates SQLite failures.

     - Parameters:
       - db: Open bootstrap writer connection.
       - sql: Complete trusted schema statement.
       - operation: Diagnostic operation attached to failures.
     - Side effects: Executes `sql` on `db`.
     - Throws: Typed `SearchIndexError.sqlite` when SQLite does not return `SQLITE_OK`.
     */
    private static func execute(
        db: OpaquePointer?,
        sql: String,
        operation: String
    ) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(db: db, operation: operation)
        }
    }

    /**
     Builds one typed SQLite diagnostic from the supplied bootstrap connection.

     - Parameters:
       - db: Connection supplying the current error code/message.
       - operation: Caller-facing failed operation.
     - Returns: Typed Search index SQLite error.
     - Side effects: Reads connection error state.
     - Failure modes: Missing native message uses a deterministic fallback string.
     */
    private static func sqliteError(
        db: OpaquePointer?,
        operation: String
    ) -> SearchIndexError {
        SearchIndexError.sqlite(
            operation: operation,
            code: sqlite3_errcode(db),
            message: sqlite3_errmsg(db).map(String.init(cString:)) ?? "Unknown SQLite error"
        )
    }
}
