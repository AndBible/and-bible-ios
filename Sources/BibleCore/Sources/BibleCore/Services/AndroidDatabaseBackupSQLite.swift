// AndroidDatabaseBackupSQLite.swift -- Shared SQLite helpers for Android database backup mappers

import Foundation
import SQLite3

private let androidDatabaseBackupSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Shared SQLite helper functions for Android database backup mappers.

 The helpers intentionally map low-level SQLite failures to `AndroidDatabaseBackupError` so category
 mappers fail before mutating local state when a selected Android database does not match the schema
 this iOS build claims to support.
 */
enum AndroidDatabaseBackupSQLite {
    /**
     Opens a SQLite database, runs a scoped body, and closes the handle.

     - Parameters:
       - url: SQLite database URL.
       - flags: SQLite open flags, such as `SQLITE_OPEN_READONLY`.
       - body: Work to run with the open database handle.
     - Returns: Body return value.
     - Side effects: Opens and closes a SQLite handle.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when the handle
       cannot be opened.
     */
    static func withDatabase<T>(
        at url: URL,
        flags: Int32 = SQLITE_OPEN_READONLY,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(url.lastPathComponent)
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    /**
     Executes a SQLite statement batch.

     - Parameters:
       - sql: SQL statement or statement batch.
       - database: Open SQLite handle.
       - fileName: Database filename used in mapped errors.
     - Side effects: Mutates the SQLite database when the statement batch writes.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when SQLite rejects
       the batch.
     */
    static func execute(_ sql: String, on database: OpaquePointer, fileName: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
    }

    /**
     Prepares a SQLite statement.

     - Parameters:
       - sql: SQL text to prepare.
       - database: Open SQLite handle.
       - fileName: Database filename used in mapped errors.
     - Returns: Prepared SQLite statement.
     - Side effects: Allocates a SQLite statement handle. Caller must finalize it.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when preparation
       fails.
     */
    static func prepare(_ sql: String, on database: OpaquePointer, fileName: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        return statement
    }

    /**
     Ensures a prepared write statement completed successfully.

     - Parameters:
       - statement: Prepared SQLite statement after all bindings are set.
       - fileName: Database filename used in mapped errors.
     - Side effects: Steps the SQLite statement once.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when SQLite does not
       report `SQLITE_DONE`.
     */
    static func stepDone(_ statement: OpaquePointer, fileName: String) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
    }

    static func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, androidDatabaseBackupSQLiteTransient)
    }

    static func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindText(value, to: statement, index: index)
    }

    static func bindBool(_ value: Bool, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_int(statement, index, value ? 1 : 0)
    }

    static func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
        let bytes: [UInt8] = [
            uuid.uuid.0,
            uuid.uuid.1,
            uuid.uuid.2,
            uuid.uuid.3,
            uuid.uuid.4,
            uuid.uuid.5,
            uuid.uuid.6,
            uuid.uuid.7,
            uuid.uuid.8,
            uuid.uuid.9,
            uuid.uuid.10,
            uuid.uuid.11,
            uuid.uuid.12,
            uuid.uuid.13,
            uuid.uuid.14,
            uuid.uuid.15,
        ]
        bytes.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(bytes.count), androidDatabaseBackupSQLiteTransient)
        }
    }

    static func text(_ statement: OpaquePointer?, column: Int32) -> String {
        optionalText(statement, column: column) ?? ""
    }

    static func optionalText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let value = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: value)
    }

    static func bool(_ statement: OpaquePointer?, column: Int32) -> Bool {
        sqlite3_column_int(statement, column) != 0
    }

    static func int(_ statement: OpaquePointer?, column: Int32) -> Int {
        Int(sqlite3_column_int(statement, column))
    }

    static func int64(_ statement: OpaquePointer?, column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    static func double(_ statement: OpaquePointer?, column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    static func uuidFromBlob(_ statement: OpaquePointer?, column: Int32, fileName: String) throws -> UUID {
        guard let bytes = sqlite3_column_blob(statement, column),
              sqlite3_column_bytes(statement, column) == 16 else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        let data = Data(bytes: bytes, count: 16)
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        guard let uuid = UUID(uuidString: uuidString) else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        return uuid
    }
}
