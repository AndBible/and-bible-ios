// RemoteSyncInitialBackupMetadataRestoreService.swift — Preservation of Android LogEntry and SyncStatus metadata

import Foundation
import SQLite3

private let remoteSyncMetadataSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
Errors raised while reading or restoring Android sync metadata from staged initial backups.
*/
public enum RemoteSyncInitialBackupMetadataRestoreError: Error, Equatable {
    /// The staged file could not be opened as a readable SQLite database.
    case invalidSQLiteDatabase

    /// One present metadata table omitted a required column.
    case missingColumn(table: String, column: String)

    /// One required metadata column contained an unsupported or malformed value.
    case invalidColumnValue(table: String, column: String)

    /// One `LogEntry.type` value did not match Android's supported operation set.
    case invalidLogEntryType(String)
}

/**
Read-only snapshot of Android sync metadata preserved in a staged initial backup.

Android initial backups contain the full sync database, including the `LogEntry` and `SyncStatus`
tables used later for patch conflict resolution and applied-patch bookkeeping. iOS preserves those
rows locally so later patch replay can compare against Android's original conflict baseline instead
of inferring history from the restored content tables alone.
*/
public struct RemoteSyncAndroidSyncMetadataSnapshot: Sendable, Equatable {
    /// Android `LogEntry` rows recovered from the staged initial backup.
    public let logEntries: [RemoteSyncLogEntry]

    /// Android `SyncStatus` rows recovered from the staged initial backup.
    public let patchStatuses: [RemoteSyncPatchStatus]

    /**
    Creates one staged sync-metadata snapshot.

    - Parameters:
      - logEntries: Android `LogEntry` rows recovered from the staged initial backup.
      - patchStatuses: Android `SyncStatus` rows recovered from the staged initial backup.
    - Side effects: none.
    - Failure modes: This initializer cannot fail.
    */
    public init(logEntries: [RemoteSyncLogEntry], patchStatuses: [RemoteSyncPatchStatus]) {
        self.logEntries = logEntries
        self.patchStatuses = patchStatuses
    }
}

/**
Summary of one successful Android sync-metadata restore.
*/
public struct RemoteSyncInitialBackupMetadataRestoreReport: Sendable, Equatable {
    /// Number of Android `LogEntry` rows persisted locally.
    public let importedLogEntryCount: Int

    /// Number of Android `SyncStatus` rows persisted locally.
    public let importedPatchStatusCount: Int

    /**
    Creates a sync-metadata restore summary.

    - Parameters:
      - importedLogEntryCount: Number of Android `LogEntry` rows persisted locally.
      - importedPatchStatusCount: Number of Android `SyncStatus` rows persisted locally.
    - Side effects: none.
    - Failure modes: This initializer cannot fail.
    */
    public init(importedLogEntryCount: Int, importedPatchStatusCount: Int) {
        self.importedLogEntryCount = importedLogEntryCount
        self.importedPatchStatusCount = importedPatchStatusCount
    }
}

/**
Reads and restores Android sync metadata preserved in staged initial-backup databases.

Android patch application depends on two metadata tables that are part of the full initial-backup
SQLite database:
- `LogEntry`, which records the latest mutation timestamp and operation for each syncable row
- `SyncStatus`, which records already-applied patch numbers per source device

The current iOS restore services rebuild content tables faithfully, but patch replay also needs the
Android conflict baseline carried by those metadata tables. This service imports that metadata into
local-only stores after a successful initial restore.

Data dependencies:
- `RemoteSyncLogEntryStore` persists Android `LogEntry` rows locally per category
- `RemoteSyncPatchStatusStore` persists Android `SyncStatus` rows locally per category
- staged SQLite databases are opened read-only through SQLite C APIs

Side effects:
- opens staged SQLite databases in read-only mode while reading snapshots
- clears and replaces local metadata stores for the requested category during restore

Failure modes:
- throws `RemoteSyncInitialBackupMetadataRestoreError.invalidSQLiteDatabase` when the staged file
  cannot be opened or queried as SQLite
- throws `RemoteSyncInitialBackupMetadataRestoreError.missingColumn` when a present metadata table
  omits one required Android column
- throws `RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue` when one required column
  contains an unsupported SQLite type or malformed payload
- throws `RemoteSyncInitialBackupMetadataRestoreError.invalidLogEntryType` when one `LogEntry.type`
  payload is not `UPSERT` or `DELETE`

Concurrency:
- this type is not `Sendable`; callers should keep SQLite access and settings-store mutation on the
  same execution context that owns the supplied dependencies
*/
public final class RemoteSyncInitialBackupMetadataRestoreService {
    /**
    Creates an initial-backup metadata restore service.

    - Side effects: none.
    - Failure modes: This initializer cannot fail.
    */
    public init() {}

    /**
    Reads Android sync metadata from one staged initial-backup database.

    Missing metadata tables are treated as an empty snapshot so older or partially staged backups do
    not fail content restore. When a metadata table is present, however, its required Android schema
    is enforced strictly.

    - Parameter databaseURL: Local URL of the extracted Android initial-backup SQLite database.
    - Returns: Typed snapshot of Android `LogEntry` and `SyncStatus` rows.
    - Side effects:
      - opens the staged SQLite database in read-only mode
    - Failure modes:
      - throws `RemoteSyncInitialBackupMetadataRestoreError.invalidSQLiteDatabase` when the file cannot be opened or queried as SQLite
      - throws `RemoteSyncInitialBackupMetadataRestoreError.missingColumn` when a present metadata table omits one required column
      - throws `RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue` when one required column contains an unsupported SQLite type or malformed payload
      - throws `RemoteSyncInitialBackupMetadataRestoreError.invalidLogEntryType` when one `LogEntry.type` payload is not recognized
    */
    public func readSnapshot(from databaseURL: URL) throws -> RemoteSyncAndroidSyncMetadataSnapshot {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw RemoteSyncInitialBackupMetadataRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(db) }

        let logEntries = try tableExists(named: "LogEntry", in: db) ? fetchLogEntries(from: db) : []
        let patchStatuses = try tableExists(named: "SyncStatus", in: db) ? fetchPatchStatuses(from: db) : []
        return RemoteSyncAndroidSyncMetadataSnapshot(logEntries: logEntries, patchStatuses: patchStatuses)
    }

    /**
    Replaces the local metadata stores for one sync category with a staged Android snapshot.

    - Parameters:
      - snapshot: Android metadata snapshot previously read from a staged initial backup.
      - category: Logical sync category that owns the metadata.
      - settingsStore: Local-only settings store backing the metadata side stores.
    - Returns: Import summary describing how many metadata rows were persisted.
    - Side effects:
      - clears and rewrites the category-scoped rows in `RemoteSyncLogEntryStore`
      - clears and rewrites the category-scoped rows in `RemoteSyncPatchStatusStore`
    - Failure modes:
      - this method does not throw, but underlying `SettingsStore` persistence remains best-effort
        because its save failures are swallowed by design
    */
    public func replaceLocalMetadata(
        from snapshot: RemoteSyncAndroidSyncMetadataSnapshot,
        category: RemoteSyncCategory,
        settingsStore: SettingsStore
    ) -> RemoteSyncInitialBackupMetadataRestoreReport {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        logEntryStore.replaceEntries(snapshot.logEntries, for: category)
        patchStatusStore.clearCategory(category)
        patchStatusStore.addStatuses(snapshot.patchStatuses, for: category)

        return RemoteSyncInitialBackupMetadataRestoreReport(
            importedLogEntryCount: snapshot.logEntries.count,
            importedPatchStatusCount: snapshot.patchStatuses.count
        )
    }

    /**
    Returns whether the staged database currently exposes one named table.

    - Parameters:
      - name: Exact SQLite table name to look for.
      - db: Open SQLite database handle.
    - Returns: `true` when the named table exists.
    - Side effects:
      - prepares and steps a `sqlite_master` metadata query
    - Failure modes:
      - throws `RemoteSyncInitialBackupMetadataRestoreError.invalidSQLiteDatabase` when the metadata query cannot be prepared
    */
    private func tableExists(named name: String, in db: OpaquePointer) throws -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupMetadataRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, name, -1, remoteSyncMetadataSQLiteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /**
    Reads all `LogEntry` rows from the open staged database.

    - Parameter db: Open SQLite database handle.
    - Returns: Sorted Android log-entry rows.
    - Side effects:
      - prepares and steps a read-only `LogEntry` query
    - Failure modes:
      - throws `RemoteSyncInitialBackupMetadataRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
      - throws `RemoteSyncInitialBackupMetadataRestoreError.missingColumn` when one required `LogEntry` column is absent
      - throws `RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue` when one required column contains an unsupported or malformed payload
      - throws `RemoteSyncInitialBackupMetadataRestoreError.invalidLogEntryType` when one `type` payload is not recognized
    */
    private func fetchLogEntries(from db: OpaquePointer) throws -> [RemoteSyncLogEntry] {
        let tableName = "LogEntry"
        let sql = "SELECT * FROM \"LogEntry\""
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupMetadataRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        let columnMap = try columnIndexMap(for: statement, table: tableName)
        let tableNameIndex = try requiredColumnIndex("tableName", in: columnMap, table: tableName)
        let entityID1Index = try requiredColumnIndex("entityId1", in: columnMap, table: tableName)
        let entityID2Index = try requiredColumnIndex("entityId2", in: columnMap, table: tableName)
        let typeIndex = try requiredColumnIndex("type", in: columnMap, table: tableName)
        let lastUpdatedIndex = try requiredColumnIndex("lastUpdated", in: columnMap, table: tableName)
        let sourceDeviceIndex = try requiredColumnIndex("sourceDevice", in: columnMap, table: tableName)

        var rows: [RemoteSyncLogEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rawType = try requiredTextColumn(typeIndex, in: statement, table: tableName, column: "type")
            guard let type = RemoteSyncLogEntryType(rawValue: rawType) else {
                throw RemoteSyncInitialBackupMetadataRestoreError.invalidLogEntryType(rawType)
            }
            rows.append(
                RemoteSyncLogEntry(
                    tableName: try requiredTextColumn(tableNameIndex, in: statement, table: tableName, column: "tableName"),
                    entityID1: try sqliteValueColumn(entityID1Index, in: statement, table: tableName, column: "entityId1"),
                    entityID2: try sqliteValueColumn(entityID2Index, in: statement, table: tableName, column: "entityId2"),
                    type: type,
                    lastUpdated: try requiredInt64Column(lastUpdatedIndex, in: statement, table: tableName, column: "lastUpdated"),
                    sourceDevice: try requiredTextColumn(sourceDeviceIndex, in: statement, table: tableName, column: "sourceDevice")
                )
            )
        }

        return rows.sorted(by: logEntrySort)
    }

    /**
    Reads all `SyncStatus` rows from the open staged database.

    - Parameter db: Open SQLite database handle.
    - Returns: Sorted Android patch-status rows.
    - Side effects:
      - prepares and steps a read-only `SyncStatus` query
    - Failure modes:
      - throws `RemoteSyncInitialBackupMetadataRestoreError.invalidSQLiteDatabase` when the query cannot be prepared
      - throws `RemoteSyncInitialBackupMetadataRestoreError.missingColumn` when one required `SyncStatus` column is absent
      - throws `RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue` when one required column contains an unsupported or malformed payload
    */
    private func fetchPatchStatuses(from db: OpaquePointer) throws -> [RemoteSyncPatchStatus] {
        let tableName = "SyncStatus"
        let sql = "SELECT * FROM \"SyncStatus\""
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupMetadataRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        let columnMap = try columnIndexMap(for: statement, table: tableName)
        let sourceDeviceIndex = try requiredColumnIndex("sourceDevice", in: columnMap, table: tableName)
        let patchNumberIndex = try requiredColumnIndex("patchNumber", in: columnMap, table: tableName)
        let sizeBytesIndex = try requiredColumnIndex("sizeBytes", in: columnMap, table: tableName)
        let appliedDateIndex = try requiredColumnIndex("appliedDate", in: columnMap, table: tableName)

        var rows: [RemoteSyncPatchStatus] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                RemoteSyncPatchStatus(
                    sourceDevice: try requiredTextColumn(sourceDeviceIndex, in: statement, table: tableName, column: "sourceDevice"),
                    patchNumber: try requiredInt64Column(patchNumberIndex, in: statement, table: tableName, column: "patchNumber"),
                    sizeBytes: try requiredInt64Column(sizeBytesIndex, in: statement, table: tableName, column: "sizeBytes"),
                    appliedDate: try requiredInt64Column(appliedDateIndex, in: statement, table: tableName, column: "appliedDate")
                )
            )
        }

        return rows.sorted(by: patchStatusSort)
    }

    /**
    Maps result-set column names to their zero-based indices.

    - Parameters:
      - statement: Prepared SQLite statement whose result columns should be indexed.
      - table: Table name used only for error reporting.
    - Returns: Map from SQLite column name to its zero-based index.
    - Side effects: none.
    - Failure modes:
      - throws `RemoteSyncInitialBackupMetadataRestoreError.invalidSQLiteDatabase` when SQLite does not expose column metadata for the prepared statement
    */
    private func columnIndexMap(for statement: OpaquePointer, table: String) throws -> [String: Int32] {
        let count = sqlite3_column_count(statement)
        guard count > 0 else {
            throw RemoteSyncInitialBackupMetadataRestoreError.invalidSQLiteDatabase
        }

        var result: [String: Int32] = [:]
        for index in 0..<count {
            guard let cString = sqlite3_column_name(statement, index) else {
                throw RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue(table: table, column: "<unknown>")
            }
            result[String(cString: cString)] = index
        }
        return result
    }

    /**
    Resolves one required result-set column index.

    - Parameters:
      - column: Required column name.
      - columnMap: Result-set column map built from SQLite metadata.
      - table: Table name used for error reporting.
    - Returns: Zero-based column index for the requested column.
    - Side effects: none.
    - Failure modes:
      - throws `RemoteSyncInitialBackupMetadataRestoreError.missingColumn` when the column is absent
    */
    private func requiredColumnIndex(_ column: String, in columnMap: [String: Int32], table: String) throws -> Int32 {
        guard let index = columnMap[column] else {
            throw RemoteSyncInitialBackupMetadataRestoreError.missingColumn(table: table, column: column)
        }
        return index
    }

    /**
    Reads one required UTF-8 text column.

    - Parameters:
      - index: Zero-based SQLite column index.
      - statement: Prepared SQLite statement positioned on a row.
      - table: Table name used for error reporting.
      - column: Column name used for error reporting.
    - Returns: Decoded UTF-8 text payload.
    - Side effects: none.
    - Failure modes:
      - throws `RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue` when the column is null, not text, or not valid UTF-8
    */
    private func requiredTextColumn(
        _ index: Int32,
        in statement: OpaquePointer,
        table: String,
        column: String
    ) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT else {
            throw RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue(table: table, column: column)
        }

        let length = Int(sqlite3_column_bytes(statement, index))
        guard let pointer = sqlite3_column_text(statement, index) else {
            if length == 0 {
                return ""
            }
            throw RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue(table: table, column: column)
        }

        let data = Data(bytes: pointer, count: length)
        guard let value = String(data: data, encoding: .utf8) else {
            throw RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue(table: table, column: column)
        }
        return value
    }

    /**
    Reads one required integer-backed column.

    - Parameters:
      - index: Zero-based SQLite column index.
      - statement: Prepared SQLite statement positioned on a row.
      - table: Table name used for error reporting.
      - column: Column name used for error reporting.
    - Returns: Int64 payload stored in the column.
    - Side effects: none.
    - Failure modes:
      - throws `RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue` when the column is null or not integer-backed
    */
    private func requiredInt64Column(
        _ index: Int32,
        in statement: OpaquePointer,
        table: String,
        column: String
    ) throws -> Int64 {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue(table: table, column: column)
        }
        return sqlite3_column_int64(statement, index)
    }

    /**
    Reads one SQLite value while preserving the observed dynamic storage kind.

    - Parameters:
      - index: Zero-based SQLite column index.
      - statement: Prepared SQLite statement positioned on a row.
      - table: Table name used for error reporting.
      - column: Column name used for error reporting.
    - Returns: Typed SQLite scalar value preserving both kind and payload.
    - Side effects: none.
    - Failure modes:
      - throws `RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue` when SQLite reports an unsupported type or the payload cannot be decoded faithfully
    */
    private func sqliteValueColumn(
        _ index: Int32,
        in statement: OpaquePointer,
        table: String,
        column: String
    ) throws -> RemoteSyncSQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null()
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            return .text(try requiredTextColumn(index, in: statement, table: table, column: column))
        case SQLITE_BLOB:
            let length = Int(sqlite3_column_bytes(statement, index))
            if length == 0 {
                return .blob(Data())
            }
            guard let pointer = sqlite3_column_blob(statement, index) else {
                throw RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue(table: table, column: column)
            }
            return .blob(Data(bytes: pointer, count: length))
        default:
            throw RemoteSyncInitialBackupMetadataRestoreError.invalidColumnValue(table: table, column: column)
        }
    }

    /**
    Sorts Android `LogEntry` rows into a deterministic local replay order.

    - Parameters:
      - lhs: First log-entry row to compare.
      - rhs: Second log-entry row to compare.
    - Returns: `true` when `lhs` should appear before `rhs`.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    private func logEntrySort(_ lhs: RemoteSyncLogEntry, _ rhs: RemoteSyncLogEntry) -> Bool {
        if lhs.lastUpdated != rhs.lastUpdated {
            return lhs.lastUpdated < rhs.lastUpdated
        }
        if lhs.tableName != rhs.tableName {
            return lhs.tableName < rhs.tableName
        }
        if lhs.type != rhs.type {
            return lhs.type.rawValue < rhs.type.rawValue
        }
        if lhs.sourceDevice != rhs.sourceDevice {
            return lhs.sourceDevice < rhs.sourceDevice
        }
        if lhs.entityID1 != rhs.entityID1 {
            return sortKey(for: lhs.entityID1) < sortKey(for: rhs.entityID1)
        }
        return sortKey(for: lhs.entityID2) < sortKey(for: rhs.entityID2)
    }

    /**
    Sorts Android `SyncStatus` rows into a deterministic local order.

    - Parameters:
      - lhs: First patch-status row to compare.
      - rhs: Second patch-status row to compare.
    - Returns: `true` when `lhs` should appear before `rhs`.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    private func patchStatusSort(_ lhs: RemoteSyncPatchStatus, _ rhs: RemoteSyncPatchStatus) -> Bool {
        if lhs.sourceDevice != rhs.sourceDevice {
            return lhs.sourceDevice < rhs.sourceDevice
        }
        return lhs.patchNumber < rhs.patchNumber
    }

    /**
    Builds a deterministic string key used only for local sorting of preserved SQLite values.

    - Parameter value: Typed SQLite value to serialize for comparison.
    - Returns: Canonical string preserving storage kind and payload.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    private func sortKey(for value: RemoteSyncSQLiteValue) -> String {
        switch value.kind {
        case .null:
            return "null"
        case .integer:
            return "integer:\(value.integerValue ?? 0)"
        case .real:
            return "real:\(value.realValue?.bitPattern ?? 0)"
        case .text:
            return "text:\(value.textValue ?? "")"
        case .blob:
            return "blob:\(value.blobBase64Value ?? "")"
        }
    }
}
