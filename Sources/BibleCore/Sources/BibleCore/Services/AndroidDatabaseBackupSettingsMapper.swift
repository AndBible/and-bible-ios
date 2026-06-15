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
       database cannot be read as schema version 1 or contains an unsupported registered
       preference value.
     */
    static func restore(
        from databaseURL: URL,
        settingsStore: SettingsStore
    ) throws -> AndroidDatabaseBackupSettingsReport {
        let fileName = databaseURL.lastPathComponent
        let snapshot = try readSnapshot(from: databaseURL)
        try validate(snapshot, fileName: fileName)
        settingsStore.resetApplicationPreferences()

        var appliedCount = 0
        for definition in AppPreferenceRegistry.definitions where definition.storage != .action {
            guard try apply(definition, from: snapshot, to: settingsStore, fileName: fileName) else {
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
        to settingsStore: SettingsStore,
        fileName: String
    ) throws -> Bool {
        switch definition.valueType {
        case .bool:
            guard let value = snapshot.booleans[definition.key.rawValue] else { return false }
            settingsStore.setBool(definition.key, value: value)
            return true
        case .int:
            if let value = try intValue(definition, from: snapshot, fileName: fileName) {
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

    /**
     Validates registered Android preference values before the destructive Settings reset.

     - Parameters:
       - snapshot: Parsed Android settings rows.
       - fileName: Backup database name used in thrown errors.
     - Side effects: none.
     - Failure modes: Throws `invalidSQLiteDatabase` when a registered integer preference cannot
       be represented on the current platform or falls outside Android's declared preference range.
     */
    private static func validate(_ snapshot: Snapshot, fileName: String) throws {
        for definition in AppPreferenceRegistry.definitions
            where definition.storage != .action && definition.valueType == .int {
            _ = try intValue(definition, from: snapshot, fileName: fileName)
        }
    }

    /**
     Reads and validates a registered integer preference from Android settings rows.

     Android stores app integer preferences in `LongSetting`. The string fallback is retained for
     tolerance of older or manually-created fixtures, but any value that decodes as an integer must
     still satisfy the registry's Android domain metadata.

     - Parameters:
       - definition: Registered parity preference definition.
       - snapshot: Parsed Android settings rows.
       - fileName: Backup database name used in thrown errors.
     - Returns: Validated integer value, or `nil` when no decodable row exists.
     - Side effects: none.
     - Failure modes: Throws `invalidSQLiteDatabase` when the value is unrepresentable as Swift
       `Int` or violates Android's registered integer range.
     */
    private static func intValue(
        _ definition: AppPreferenceDefinition,
        from snapshot: Snapshot,
        fileName: String
    ) throws -> Int? {
        if let value = snapshot.longs[definition.key.rawValue] {
            return try validatedInt(value, for: definition, fileName: fileName)
        }
        if let stringValue = snapshot.strings[definition.key.rawValue], let value = Int(stringValue) {
            return try validatedInt(value, for: definition, fileName: fileName)
        }
        return nil
    }

    /**
     Converts an Android `LongSetting` integer into a registry-valid Swift integer.

     - Parameters:
       - value: Raw SQLite 64-bit integer.
       - definition: Registered parity preference definition.
       - fileName: Backup database name used in thrown errors.
     - Returns: Swift `Int` when representable and Android-valid.
     - Side effects: none.
     - Failure modes: Throws `invalidSQLiteDatabase` when the raw value cannot be represented by
       `Int` or falls outside the Android-supported range for the preference.
     */
    private static func validatedInt(
        _ value: Int64,
        for definition: AppPreferenceDefinition,
        fileName: String
    ) throws -> Int {
        guard let intValue = Int(exactly: value) else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        return try validatedInt(intValue, for: definition, fileName: fileName)
    }

    /**
     Checks a decoded integer against the registry's Android-supported value domain.

     - Parameters:
       - value: Decoded preference value.
       - definition: Registered parity preference definition.
       - fileName: Backup database name used in thrown errors.
     - Returns: `value` when it satisfies the registered domain.
     - Side effects: none.
     - Failure modes: Throws `invalidSQLiteDatabase` for values outside Android's declared range.
     */
    private static func validatedInt(
        _ value: Int,
        for definition: AppPreferenceDefinition,
        fileName: String
    ) throws -> Int {
        if let range = definition.intRange, !range.contains(value) {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        return value
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
