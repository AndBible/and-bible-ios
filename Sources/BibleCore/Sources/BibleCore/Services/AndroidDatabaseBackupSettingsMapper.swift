// AndroidDatabaseBackupSettingsMapper.swift -- Android settings.sqlite3 backup mapper

import Foundation
import SQLite3

/**
 Summary for applying Android's `settings.sqlite3` database.
 */
public struct AndroidDatabaseBackupSettingsReport: Sendable, Equatable {
    /// Number of registered Android application preferences applied from the backup.
    public let appliedSettingCount: Int
}

/**
 Maps Android's Settings Room database to iOS's registered application preference store.

 Android treats `settings.sqlite3` as a restore-only database during manual backup apply. iOS cannot
 raw-copy that Room file, so this mapper translates the supported preference rows through
 `AppPreferenceRegistry` and `SettingsStore` while preserving the same user-visible replacement
 semantics.
 */
enum AndroidDatabaseBackupSettingsMapper {
    private struct Snapshot {
        var booleans: [String: Bool] = [:]
        var longs: [String: Int64] = [:]
        var strings: [String: String] = [:]
        var doubles: [String: Double] = [:]
    }

    /**
     Restores Android settings rows into the registered iOS app preferences.

     - Parameters:
       - databaseURL: Extracted Android `settings.sqlite3` file.
       - settingsStore: iOS settings store to mutate.
     - Returns: Count of registered preference rows applied from the backup.
     - Side effects:
       - clears existing registered app preferences first
       - writes supported Android preference values through `SettingsStore`
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when the Android
       database cannot be read as schema version 1.
     */
    static func restore(
        from databaseURL: URL,
        settingsStore: SettingsStore
    ) throws -> AndroidDatabaseBackupSettingsReport {
        let snapshot = try readSnapshot(from: databaseURL)
        settingsStore.resetApplicationPreferences()

        var appliedCount = 0
        for definition in AppPreferenceRegistry.definitions where definition.storage != .action {
            guard apply(definition, from: snapshot, to: settingsStore) else {
                continue
            }
            appliedCount += 1
        }
        return AndroidDatabaseBackupSettingsReport(appliedSettingCount: appliedCount)
    }

    /**
     Writes an Android-compatible `settings.sqlite3` database from current iOS preference values.

     - Parameters:
       - databaseURL: Destination SQLite URL.
       - settingsStore: Current iOS settings store.
     - Returns: Number of registered preference rows written.
     - Side effects: Creates or replaces the SQLite database file.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when SQLite rejects
       schema creation or row insertion.
     */
    @discardableResult
    static func writeDatabase(at databaseURL: URL, settingsStore: SettingsStore) throws -> Int {
        try? FileManager.default.removeItem(at: databaseURL)
        return try AndroidDatabaseBackupSQLite.withDatabase(
            at: databaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        ) { database in
            let fileName = databaseURL.lastPathComponent
            try AndroidDatabaseBackupSQLite.execute(
                """
                CREATE TABLE BooleanSetting (`key` TEXT NOT NULL PRIMARY KEY, value INTEGER NOT NULL);
                CREATE TABLE LongSetting (`key` TEXT NOT NULL PRIMARY KEY, value INTEGER NOT NULL);
                CREATE TABLE StringSetting (`key` TEXT NOT NULL PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE DoubleSetting (`key` TEXT NOT NULL PRIMARY KEY, value REAL NOT NULL);
                PRAGMA user_version = 1;
                """,
                on: database,
                fileName: fileName
            )

            var writtenCount = 0
            for definition in AppPreferenceRegistry.definitions where definition.storage != .action {
                try insert(definition, settingsStore: settingsStore, database: database, fileName: fileName)
                writtenCount += 1
            }
            return writtenCount
        }
    }

    private static func readSnapshot(from databaseURL: URL) throws -> Snapshot {
        try AndroidDatabaseBackupSQLite.withDatabase(at: databaseURL) { database in
            let fileName = databaseURL.lastPathComponent
            return Snapshot(
                booleans: try readBooleanSettings(from: database, fileName: fileName),
                longs: try readLongSettings(from: database, fileName: fileName),
                strings: try readStringSettings(from: database, fileName: fileName),
                doubles: try readDoubleSettings(from: database, fileName: fileName)
            )
        }
    }

    private static func apply(
        _ definition: AppPreferenceDefinition,
        from snapshot: Snapshot,
        to settingsStore: SettingsStore
    ) -> Bool {
        switch definition.valueType {
        case .bool:
            guard let value = snapshot.booleans[definition.key.rawValue] else { return false }
            settingsStore.setBool(definition.key, value: value)
            return true
        case .int:
            if let value = snapshot.longs[definition.key.rawValue] {
                settingsStore.setInt(definition.key, value: Int(value))
                return true
            }
            if let stringValue = snapshot.strings[definition.key.rawValue], let value = Int(stringValue) {
                settingsStore.setInt(definition.key, value: value)
                return true
            }
            return false
        case .string:
            guard let value = snapshot.strings[definition.key.rawValue] else { return false }
            settingsStore.setString(definition.key, value: normalizedString(value, for: definition.key))
            return true
        case .csvStringSet:
            guard let value = snapshot.strings[definition.key.rawValue] else { return false }
            settingsStore.setStringSet(definition.key, values: AppPreferenceRegistry.decodeCSVSet(value))
            return true
        case .action:
            return false
        }
    }

    private static func insert(
        _ definition: AppPreferenceDefinition,
        settingsStore: SettingsStore,
        database: OpaquePointer,
        fileName: String
    ) throws {
        switch definition.valueType {
        case .bool:
            try insertKeyValue(
                tableName: "BooleanSetting",
                key: definition.key.rawValue,
                bindValue: { statement in
                    AndroidDatabaseBackupSQLite.bindBool(settingsStore.getBool(definition.key), to: statement, index: 2)
                },
                database: database,
                fileName: fileName
            )
        case .int:
            try insertKeyValue(
                tableName: "LongSetting",
                key: definition.key.rawValue,
                bindValue: { statement in
                    sqlite3_bind_int64(statement, 2, Int64(settingsStore.getInt(definition.key)))
                },
                database: database,
                fileName: fileName
            )
        case .string:
            try insertKeyValue(
                tableName: "StringSetting",
                key: definition.key.rawValue,
                bindValue: { statement in
                    AndroidDatabaseBackupSQLite.bindText(
                        normalizedString(settingsStore.getString(definition.key), for: definition.key),
                        to: statement,
                        index: 2
                    )
                },
                database: database,
                fileName: fileName
            )
        case .csvStringSet:
            try insertKeyValue(
                tableName: "StringSetting",
                key: definition.key.rawValue,
                bindValue: { statement in
                    AndroidDatabaseBackupSQLite.bindText(
                        AppPreferenceRegistry.encodeCSVSet(settingsStore.getStringSet(definition.key)),
                        to: statement,
                        index: 2
                    )
                },
                database: database,
                fileName: fileName
            )
        case .action:
            break
        }
    }

    private static func readBooleanSettings(
        from database: OpaquePointer,
        fileName: String
    ) throws -> [String: Bool] {
        try readRows("SELECT `key`, value FROM BooleanSetting;", from: database, fileName: fileName) { statement in
            (AndroidDatabaseBackupSQLite.text(statement, column: 0), AndroidDatabaseBackupSQLite.bool(statement, column: 1))
        }
    }

    private static func readLongSettings(
        from database: OpaquePointer,
        fileName: String
    ) throws -> [String: Int64] {
        try readRows("SELECT `key`, value FROM LongSetting;", from: database, fileName: fileName) { statement in
            (AndroidDatabaseBackupSQLite.text(statement, column: 0), AndroidDatabaseBackupSQLite.int64(statement, column: 1))
        }
    }

    private static func readStringSettings(
        from database: OpaquePointer,
        fileName: String
    ) throws -> [String: String] {
        try readRows("SELECT `key`, value FROM StringSetting;", from: database, fileName: fileName) { statement in
            (AndroidDatabaseBackupSQLite.text(statement, column: 0), AndroidDatabaseBackupSQLite.text(statement, column: 1))
        }
    }

    private static func readDoubleSettings(
        from database: OpaquePointer,
        fileName: String
    ) throws -> [String: Double] {
        try readRows("SELECT `key`, value FROM DoubleSetting;", from: database, fileName: fileName) { statement in
            (AndroidDatabaseBackupSQLite.text(statement, column: 0), AndroidDatabaseBackupSQLite.double(statement, column: 1))
        }
    }

    private static func readRows<Value>(
        _ sql: String,
        from database: OpaquePointer,
        fileName: String,
        map: (OpaquePointer) throws -> (String, Value)
    ) throws -> [String: Value] {
        let statement = try AndroidDatabaseBackupSQLite.prepare(sql, on: database, fileName: fileName)
        defer { sqlite3_finalize(statement) }

        var values: [String: Value] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
            }
            let row = try map(statement)
            values[row.0] = row.1
        }
        return values
    }

    private static func insertKeyValue(
        tableName: String,
        key: String,
        bindValue: (OpaquePointer?) -> Void,
        database: OpaquePointer,
        fileName: String
    ) throws {
        let statement = try AndroidDatabaseBackupSQLite.prepare(
            "INSERT INTO \(tableName) (`key`, value) VALUES (?, ?);",
            on: database,
            fileName: fileName
        )
        defer { sqlite3_finalize(statement) }
        AndroidDatabaseBackupSQLite.bindText(key, to: statement, index: 1)
        bindValue(statement)
        try AndroidDatabaseBackupSQLite.stepDone(statement, fileName: fileName)
    }

    private static func normalizedString(_ value: String, for key: AppPreferenceKey) -> String {
        switch key {
        case .notesContentType:
            AppPreferenceValueNormalizer.notesContentType(value)
        default:
            value
        }
    }
}
