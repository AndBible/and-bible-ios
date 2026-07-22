import Foundation
import SQLite3

private let androidBookmarkContractSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct AndroidBookmarkSQLiteColumnContract: Equatable, Hashable {
    let objectName: String
    let ordinal: Int
    let name: String
    let type: String
    let notNull: Bool
    let defaultValue: String?
    let primaryKeyOrdinal: Int
}

struct AndroidBookmarkSQLiteForeignKeyContract: Equatable, Hashable {
    let tableName: String
    let identifier: Int
    let sequence: Int
    let referencedTable: String
    let sourceColumn: String
    let targetColumn: String
    let onUpdate: String
    let onDelete: String
    let match: String
}

struct AndroidBookmarkSQLiteIndexContract: Equatable, Hashable {
    let tableName: String
    let name: String
    let unique: Bool
    let origin: String
    let partial: Bool
    let columns: [String]
}

struct AndroidBookmarkSQLiteSchemaContract: Equatable {
    let userVersion: Int
    let roomIdentityHash: String?
    let tables: [String]
    let views: [String]
    let columns: [AndroidBookmarkSQLiteColumnContract]
    let foreignKeys: [AndroidBookmarkSQLiteForeignKeyContract]
    let indexes: [AndroidBookmarkSQLiteIndexContract]
}

enum AndroidBookmarkRoomV12TestSupportError: Error, Equatable {
    case fixtureMissing
    case sqlite(String)
}

/**
 Materializes the Android-derived Room-v12 SQL fixture in a temporary SQLite database.

 - Returns: URL of the populated strict fixture database; the caller owns cleanup.
 - Side effects: Creates one temporary SQLite file and executes the checked-in fixture SQL.
 - Failure modes: Throws when the fixture file is unavailable or SQLite rejects any statement.
 */
func makeAndroidBookmarkRoomV12Fixture() throws -> URL {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/android-bookmark-room-v12.sql")
    guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
        throw AndroidBookmarkRoomV12TestSupportError.fixtureMissing
    }
    let sql = try String(contentsOf: fixtureURL, encoding: .utf8)
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("android-bookmark-room-v12-\(UUID().uuidString).sqlite3")
    try withAndroidBookmarkSQLiteDatabase(at: databaseURL) { database in
        try executeAndroidBookmarkSQLite(sql, in: database)
    }
    return databaseURL
}

/**
 Reads a SQLite bookmark database into structured Room schema metadata.

 - Parameter databaseURL: SQLite database whose schema should be inspected.
 - Returns: Structured version, identity, table/view columns, foreign keys, and indexes.
 - Side effects: Opens the database read-only for metadata queries.
 - Failure modes: Throws when SQLite cannot open or inspect the database.
 */
func androidBookmarkSQLiteSchemaContract(at databaseURL: URL) throws -> AndroidBookmarkSQLiteSchemaContract {
    try withAndroidBookmarkSQLiteDatabase(at: databaseURL, flags: SQLITE_OPEN_READONLY) { database in
        let tables = try androidBookmarkSQLiteStrings(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
            in: database
        )
        let views = try androidBookmarkSQLiteStrings(
            "SELECT name FROM sqlite_master WHERE type = 'view' ORDER BY name",
            in: database
        )
        var columns: [AndroidBookmarkSQLiteColumnContract] = []
        var foreignKeys: [AndroidBookmarkSQLiteForeignKeyContract] = []
        var indexes: [AndroidBookmarkSQLiteIndexContract] = []

        for objectName in tables + views {
            try withAndroidBookmarkSQLiteStatement(
                sql: "PRAGMA table_info(`\(objectName)`)",
                database: database
            ) { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    columns.append(
                        AndroidBookmarkSQLiteColumnContract(
                            objectName: objectName,
                            ordinal: Int(sqlite3_column_int(statement, 0)),
                            name: androidBookmarkSQLiteRequiredText(statement, column: 1),
                            type: androidBookmarkSQLiteRequiredText(statement, column: 2),
                            notNull: sqlite3_column_int(statement, 3) != 0,
                            defaultValue: androidBookmarkSQLiteOptionalText(statement, column: 4),
                            primaryKeyOrdinal: Int(sqlite3_column_int(statement, 5))
                        )
                    )
                }
            }
        }

        for tableName in tables {
            try withAndroidBookmarkSQLiteStatement(
                sql: "PRAGMA foreign_key_list(`\(tableName)`)",
                database: database
            ) { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    foreignKeys.append(
                        AndroidBookmarkSQLiteForeignKeyContract(
                            tableName: tableName,
                            identifier: Int(sqlite3_column_int(statement, 0)),
                            sequence: Int(sqlite3_column_int(statement, 1)),
                            referencedTable: androidBookmarkSQLiteRequiredText(statement, column: 2),
                            sourceColumn: androidBookmarkSQLiteRequiredText(statement, column: 3),
                            targetColumn: androidBookmarkSQLiteRequiredText(statement, column: 4),
                            onUpdate: androidBookmarkSQLiteRequiredText(statement, column: 5),
                            onDelete: androidBookmarkSQLiteRequiredText(statement, column: 6),
                            match: androidBookmarkSQLiteRequiredText(statement, column: 7)
                        )
                    )
                }
            }

            try withAndroidBookmarkSQLiteStatement(
                sql: "PRAGMA index_list(`\(tableName)`)",
                database: database
            ) { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    let indexName = androidBookmarkSQLiteRequiredText(statement, column: 1)
                    let indexColumns = try androidBookmarkSQLiteStrings(
                        "SELECT name FROM pragma_index_info('\(indexName)') ORDER BY seqno",
                        in: database
                    )
                    indexes.append(
                        AndroidBookmarkSQLiteIndexContract(
                            tableName: tableName,
                            name: indexName,
                            unique: sqlite3_column_int(statement, 2) != 0,
                            origin: androidBookmarkSQLiteRequiredText(statement, column: 3),
                            partial: sqlite3_column_int(statement, 4) != 0,
                            columns: indexColumns
                        )
                    )
                }
            }
        }

        let userVersion = try androidBookmarkSQLiteInt("PRAGMA user_version", in: database)
        let identityHash = try androidBookmarkSQLiteOptionalString(
            "SELECT identity_hash FROM room_master_table WHERE id = 42",
            in: database
        )
        return AndroidBookmarkSQLiteSchemaContract(
            userVersion: userVersion,
            roomIdentityHash: identityHash,
            tables: tables,
            views: views,
            columns: columns,
            foreignKeys: foreignKeys.sorted(by: androidBookmarkForeignKeySort),
            indexes: indexes.sorted(by: androidBookmarkIndexSort)
        )
    }
}

/**
 Applies every sparse bookmark row in an iOS patch to the strict Android fixture.

 - Parameters:
   - patchURL: Generated iOS bookmark patch database.
   - fixtureURL: Populated Room-v12 database receiving patch rows.
 - Side effects: Attaches the patch, writes data in Android table order, and enables foreign keys.
 - Failure modes: Throws when schema drift, nullability, or relationships make SQLite reject rows.
 */
func applyIOSBookmarkPatch(_ patchURL: URL, toAndroidFixture fixtureURL: URL) throws {
    try withAndroidBookmarkSQLiteDatabase(at: fixtureURL) { database in
        try executeAndroidBookmarkSQLite("PRAGMA foreign_keys = ON", in: database)
        try withAndroidBookmarkSQLiteStatement(sql: "ATTACH DATABASE ? AS patch", database: database) { statement in
            sqlite3_bind_text(statement, 1, patchURL.path, -1, androidBookmarkContractSQLiteTransient)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw androidBookmarkSQLiteError(database)
            }
        }
        defer { try? executeAndroidBookmarkSQLite("DETACH DATABASE patch", in: database) }

        try executeAndroidBookmarkSQLite("BEGIN IMMEDIATE", in: database)
        do {
            for tableName in [
                "Label",
                "BibleBookmark",
                "BibleBookmarkNotes",
                "BibleBookmarkToLabel",
                "GenericBookmark",
                "GenericBookmarkNotes",
                "GenericBookmarkToLabel",
                "StudyPadTextEntry",
                "StudyPadTextEntryText",
                "LogEntry",
                "SyncConfiguration",
                "SyncStatus",
            ] {
                try executeAndroidBookmarkSQLite(
                    "INSERT OR REPLACE INTO main.`\(tableName)` SELECT * FROM patch.`\(tableName)`",
                    in: database
                )
            }
            try executeAndroidBookmarkSQLite("COMMIT", in: database)
        } catch {
            try? executeAndroidBookmarkSQLite("ROLLBACK", in: database)
            throw error
        }

        let violations = try androidBookmarkSQLiteInt(
            "SELECT COUNT(*) FROM pragma_foreign_key_check",
            in: database
        )
        guard violations == 0 else {
            throw AndroidBookmarkRoomV12TestSupportError.sqlite("foreign_key_check returned \(violations) rows")
        }
    }
}

func withAndroidBookmarkSQLiteDatabase<T>(
    at url: URL,
    flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
    _ body: (OpaquePointer) throws -> T
) throws -> T {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw AndroidBookmarkRoomV12TestSupportError.sqlite("unable to open \(url.lastPathComponent)")
    }
    defer { sqlite3_close(database) }
    return try body(database)
}

func executeAndroidBookmarkSQLite(_ sql: String, in database: OpaquePointer) throws {
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
        let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
        sqlite3_free(message)
        throw AndroidBookmarkRoomV12TestSupportError.sqlite(detail)
    }
}

func androidBookmarkSQLiteInt(_ sql: String, in database: OpaquePointer) throws -> Int {
    try withAndroidBookmarkSQLiteStatement(sql: sql, database: database) { statement in
        guard sqlite3_step(statement) == SQLITE_ROW else { throw androidBookmarkSQLiteError(database) }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

func androidBookmarkSQLiteOptionalString(_ sql: String, in database: OpaquePointer) throws -> String? {
    try withAndroidBookmarkSQLiteStatement(sql: sql, database: database) { statement in
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return androidBookmarkSQLiteOptionalText(statement, column: 0)
    }
}

func androidBookmarkSQLiteStrings(_ sql: String, in database: OpaquePointer) throws -> [String] {
    try withAndroidBookmarkSQLiteStatement(sql: sql, database: database) { statement in
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(androidBookmarkSQLiteRequiredText(statement, column: 0))
        }
        return values
    }
}

private func withAndroidBookmarkSQLiteStatement<T>(
    sql: String,
    database: OpaquePointer,
    _ body: (OpaquePointer) throws -> T
) throws -> T {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw androidBookmarkSQLiteError(database)
    }
    defer { sqlite3_finalize(statement) }
    return try body(statement)
}

private func androidBookmarkSQLiteRequiredText(_ statement: OpaquePointer, column: Int32) -> String {
    guard let value = sqlite3_column_text(statement, column) else { return "" }
    return String(cString: value)
}

private func androidBookmarkSQLiteOptionalText(_ statement: OpaquePointer, column: Int32) -> String? {
    guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
    return androidBookmarkSQLiteRequiredText(statement, column: column)
}

private func androidBookmarkSQLiteError(_ database: OpaquePointer) -> AndroidBookmarkRoomV12TestSupportError {
    .sqlite(String(cString: sqlite3_errmsg(database)))
}

private func androidBookmarkForeignKeySort(
    _ lhs: AndroidBookmarkSQLiteForeignKeyContract,
    _ rhs: AndroidBookmarkSQLiteForeignKeyContract
) -> Bool {
    (lhs.tableName, lhs.identifier, lhs.sequence) < (rhs.tableName, rhs.identifier, rhs.sequence)
}

private func androidBookmarkIndexSort(
    _ lhs: AndroidBookmarkSQLiteIndexContract,
    _ rhs: AndroidBookmarkSQLiteIndexContract
) -> Bool {
    (lhs.tableName, lhs.name) < (rhs.tableName, rhs.name)
}
