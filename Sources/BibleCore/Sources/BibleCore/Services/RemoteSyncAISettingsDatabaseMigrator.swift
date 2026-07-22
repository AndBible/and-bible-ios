// RemoteSyncAISettingsDatabaseMigrator.swift -- Android-equivalent staged AI Room migrations

import Foundation
import SQLite3

/** Typed failures emitted before a staged AI settings database can be imported as Room v23. */
enum RemoteSyncAISettingsDatabaseMigrationError: Error, Equatable {
    /// The staged file could not be opened or queried as an existing SQLite database.
    case invalidSQLiteDatabase

    /// Android has no authoritative or deterministically derivable Room source schema.
    case unsupportedSourceVersion(Int)

    /// Archive metadata and the staged database disagree about their source generation.
    case sourceVersionMismatch(expected: Int, actual: Int)

    /// One exact Android migration step failed and the staged transaction was rolled back.
    case migrationFailed(from: Int, to: Int)
}

/**
 Migrates writable staged Android AI settings databases through the production Room chain.

 Every accepted predecessor is backed by an Android `AiSettingsDatabase` schema that its production
 migration chain can advance. Android omitted the generated v12 export, but that schema is derived
 exactly from exported v11 plus Android's 11-to-12 migration and Room 2.7.2 identity algorithm.
 Version 17 is a transient export created in the same Android feature commit as v18; it contains a
 column that no migration creates or removes, so Android cannot migrate that fresh schema forward.
 Migration runs only on downloaded temporary files; live app persistence is never opened here.
 */
enum RemoteSyncAISettingsDatabaseMigrator {
    /// Android generations with exported or exactly derivable Room schemas accepted for import.
    static let supportedSourceVersions: Set<Int> = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12,
        13, 14, 15, 16, 18, 19, 20, 21, 22, 23,
    ]

    /** Returns whether Android supplies an authoritative AI settings schema for one source version. */
    static func supportsSourceVersion(_ version: Int) -> Bool {
        supportedSourceVersions.contains(version)
    }

    /**
     Migrates and validates one staged AI settings database before any row decoding.

     - Parameters:
       - databaseURL: Existing writable staged SQLite file; live app databases must never be passed.
       - expectedSourceVersion: Optional version encoded by archive metadata. When supplied, it must
         equal the staged database's pre-migration `user_version`.
     - Side Effects:
       - opens the staged file read-write
       - executes every Android migration edge in one transaction
       - suppresses predecessor sync triggers during data-changing steps
       - replaces Room identity metadata and `user_version` with exact v23 values
       - commits only after complete v23 schema and payload validation succeeds
     - Throws: Typed source/open/migration failures or exact database-contract errors. Every failed
       predecessor migration rolls the staged file back to its original generation.
     */
    static func migrateAndValidateStagedDatabase(
        at databaseURL: URL,
        expectedSourceVersion: Int? = nil
    ) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw RemoteSyncAISettingsDatabaseMigrationError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        let sourceVersion = try userVersion(in: database)
        if let expectedSourceVersion, expectedSourceVersion != sourceVersion {
            throw RemoteSyncAISettingsDatabaseMigrationError.sourceVersionMismatch(
                expected: expectedSourceVersion,
                actual: sourceVersion
            )
        }
        guard supportsSourceVersion(sourceVersion) else {
            throw RemoteSyncAISettingsDatabaseMigrationError.unsupportedSourceVersion(sourceVersion)
        }
        let validatedRuntimeTriggerNames = try RemoteSyncAndroidDatabaseContract
            .validateAISettingsSourceDatabase(database, sourceVersion: sourceVersion)

        let targetVersion = RemoteSyncAndroidDatabaseContract.schemaVersion(for: .aiSettings)
        let targetIdentityHash = RemoteSyncAndroidDatabaseContract.identityHash(for: .aiSettings)
        if sourceVersion == targetVersion {
            try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                database,
                category: .aiSettings
            )
            return
        }

        try execute("PRAGMA foreign_keys = ON;", in: database, from: sourceVersion, to: targetVersion)
        try execute("BEGIN IMMEDIATE TRANSACTION;", in: database, from: sourceVersion, to: targetVersion)
        do {
            for version in sourceVersion..<targetVersion {
                try applyMigration(from: version, in: database)
            }
            try dropRuntimeSyncTriggers(
                validatedRuntimeTriggerNames,
                in: database,
                from: sourceVersion,
                to: targetVersion
            )
            try execute(
                "CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY,identity_hash TEXT);",
                in: database,
                from: sourceVersion,
                to: targetVersion
            )
            try execute(
                "INSERT OR REPLACE INTO room_master_table (id,identity_hash) VALUES(42, '\(targetIdentityHash)');",
                in: database,
                from: sourceVersion,
                to: targetVersion
            )
            try execute(
                "PRAGMA user_version = \(targetVersion);",
                in: database,
                from: sourceVersion,
                to: targetVersion
            )
            try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                database,
                category: .aiSettings
            )
            try execute("COMMIT;", in: database, from: sourceVersion, to: targetVersion)
        } catch {
            _ = try? execute("ROLLBACK;", in: database, from: sourceVersion, to: targetVersion)
            throw error
        }
    }

    /** Executes one Android migration while matching its sync-trigger suppression lifecycle. */
    private static func applyMigration(from version: Int, in database: OpaquePointer) throws {
        let nextVersion = version + 1
        do {
            try setSyncTriggersDisabled(true, in: database, from: version, to: nextVersion)
            do {
                for statement in migrationStatements(from: version) {
                    try execute(statement, in: database, from: version, to: nextVersion)
                }
            } catch {
                try? setSyncTriggersDisabled(false, in: database, from: version, to: nextVersion)
                throw error
            }
            try setSyncTriggersDisabled(false, in: database, from: version, to: nextVersion)
        } catch let error as RemoteSyncAISettingsDatabaseMigrationError {
            throw error
        } catch {
            throw RemoteSyncAISettingsDatabaseMigrationError.migrationFailed(
                from: version,
                to: nextVersion
            )
        }
    }

    /** Mirrors Android's per-step `SyncConfiguration.triggersDisabled` lifecycle. */
    private static func setSyncTriggersDisabled(
        _ disabled: Bool,
        in database: OpaquePointer,
        from: Int,
        to: Int
    ) throws {
        guard try tableExists("SyncConfiguration", in: database, from: from, to: to) else {
            return
        }
        let sql = disabled
            ? "INSERT OR REPLACE INTO SyncConfiguration (keyName, booleanValue) VALUES ('triggersDisabled', 1);"
            : "DELETE FROM SyncConfiguration WHERE keyName = 'triggersDisabled';"
        try execute(sql, in: database, from: from, to: to)
    }

    /** Removes only source triggers authenticated before migration started. */
    private static func dropRuntimeSyncTriggers(
        _ triggerNames: Set<String>,
        in database: OpaquePointer,
        from: Int,
        to: Int
    ) throws {
        for triggerName in triggerNames.sorted() {
            let quotedName = "\"\(triggerName.replacingOccurrences(of: "\"", with: "\"\""))\""
            try execute("DROP TRIGGER IF EXISTS \(quotedName);", in: database, from: from, to: to)
        }
    }

    /** Returns whether one migration-support table exists without creating it. */
    private static func tableExists(
        _ table: String,
        in database: OpaquePointer,
        from: Int,
        to: Int
    ) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw RemoteSyncAISettingsDatabaseMigrationError.migrationFailed(from: from, to: to)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(
            statement,
            1,
            table,
            -1,
            unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        ) == SQLITE_OK,
        sqlite3_step(statement) == SQLITE_ROW else {
            throw RemoteSyncAISettingsDatabaseMigrationError.migrationFailed(from: from, to: to)
        }
        return sqlite3_column_int64(statement, 0) > 0
    }

    /** Reads an exact nonnegative SQLite `user_version` that fits Swift `Int`. */
    private static func userVersion(in database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RemoteSyncAISettingsDatabaseMigrationError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              let value = Int(exactly: sqlite3_column_int64(statement, 0)),
              value >= 0,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncAISettingsDatabaseMigrationError.invalidSQLiteDatabase
        }
        return value
    }

    /** Executes one migration statement and maps SQLite diagnostics to its exact version edge. */
    private static func execute(
        _ sql: String,
        in database: OpaquePointer,
        from: Int,
        to: Int
    ) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncAISettingsDatabaseMigrationError.migrationFailed(from: from, to: to)
        }
    }

    /** Returns the exact SQL statements from Android `AiSettingsMigrations.kt` for one edge. */
    static func migrationStatements(from version: Int) -> [String] {
        switch version {
        case 1:
            return ["ALTER TABLE `AgentPrompt` ADD COLUMN `editBeforeRun` INTEGER NOT NULL DEFAULT 0"]
        case 2:
            return ["ALTER TABLE `AgentPrompt` ADD COLUMN `noDocumentCreation` INTEGER NOT NULL DEFAULT 0"]
        case 3:
            return addGlobalSettingsAndUsage
        case 4:
            return setCommentaryTokenDefault
        case 5:
            return ["ALTER TABLE `GlobalAiSettings` ADD COLUMN `hiddenBuiltInPrompts` TEXT NOT NULL DEFAULT ''"]
        case 6:
            return [
                "ALTER TABLE `GlobalAiSettings` ADD COLUMN `maxIterations` INTEGER NOT NULL DEFAULT 10",
                "ALTER TABLE `AgentPrompt` ADD COLUMN `maxIterations` INTEGER DEFAULT NULL",
            ]
        case 7:
            return ["ALTER TABLE `GlobalAiSettings` ADD COLUMN `commentaryDeselected` TEXT NOT NULL DEFAULT ''"]
        case 8:
            return addConfiguredModels
        case 9:
            return raiseCommentaryTokenDefault
        case 10:
            return ["ALTER TABLE `GlobalAiSettings` ADD COLUMN `aiLanguage` TEXT DEFAULT NULL"]
        case 11:
            return [
                "ALTER TABLE `AgentPrompt` ADD COLUMN `autoIncludeDocuments` INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE `AgentPrompt` ADD COLUMN `autoIncludeCommentaries` INTEGER NOT NULL DEFAULT 0",
            ]
        case 12:
            return ["ALTER TABLE `GlobalAiSettings` ADD COLUMN `askModelBeforeRun` INTEGER NOT NULL DEFAULT 0"]
        case 13:
            return ["ALTER TABLE `AgentPrompt` ADD COLUMN `bibleOnly` INTEGER NOT NULL DEFAULT 0"]
        case 14:
            return ["ALTER TABLE `AgentPrompt` ADD COLUMN `isTextTransformation` INTEGER NOT NULL DEFAULT 0"]
        case 15:
            return ["ALTER TABLE `GlobalAiSettings` ADD COLUMN `aiDisclaimerAccepted` INTEGER NOT NULL DEFAULT 0"]
        case 16:
            return addPromptCategories
        case 17:
            return [
                "ALTER TABLE `PromptCategory` ADD COLUMN `hidden` INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE `GlobalAiSettings` ADD COLUMN `hiddenBuiltInCategories` TEXT NOT NULL DEFAULT ''",
            ]
        case 18:
            return [
                "ALTER TABLE `GlobalAiSettings` ADD COLUMN `customAgentSystemPrompt` TEXT DEFAULT NULL",
                "ALTER TABLE `GlobalAiSettings` ADD COLUMN `customTextTransformationSystemPrompt` TEXT DEFAULT NULL",
            ]
        case 19:
            return ["ALTER TABLE `GlobalAiSettings` ADD COLUMN `favoritePrompts` TEXT NOT NULL DEFAULT ''"]
        case 20:
            return addRawLogTable
        case 21:
            return addBuiltinPromptOverride
        case 22:
            return [
                "ALTER TABLE `GlobalAiSettings` ADD COLUMN `autoHideAgentLogOnCompletion` INTEGER NOT NULL DEFAULT 0"
            ]
        default:
            return []
        }
    }

    /// Android's exact v3-to-v4 table and column additions.
    private static let addGlobalSettingsAndUsage = [
        """
        CREATE TABLE IF NOT EXISTS `GlobalAiSettings` (
            `id` BLOB NOT NULL PRIMARY KEY,
            `agentPermissionMode` TEXT DEFAULT NULL,
            `permanentlyAllowedTools` TEXT DEFAULT NULL,
            `permanentlyDeniedTools` TEXT DEFAULT NULL,
            `aiExcludedDocuments` TEXT NOT NULL,
            `commentaryMaxResponseTokens` INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS `LlmUsageRecord` (
            `id` BLOB NOT NULL PRIMARY KEY,
            `providerConfigId` BLOB NOT NULL,
            `deviceId` TEXT NOT NULL,
            `inputTokens` INTEGER NOT NULL DEFAULT 0,
            `outputTokens` INTEGER NOT NULL DEFAULT 0,
            `cacheCreationTokens` INTEGER NOT NULL DEFAULT 0,
            `cacheReadTokens` INTEGER NOT NULL DEFAULT 0,
            `estimatedCostUsd` REAL NOT NULL DEFAULT 0.0,
            FOREIGN KEY(`providerConfigId`) REFERENCES `LlmProviderConfig`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS `index_LlmUsageRecord_providerConfigId` ON `LlmUsageRecord` (`providerConfigId`)",
        "CREATE UNIQUE INDEX IF NOT EXISTS `index_LlmUsageRecord_providerConfigId_deviceId` ON `LlmUsageRecord` (`providerConfigId`, `deviceId`)",
        "ALTER TABLE `LlmProviderConfig` ADD COLUMN `customInputPrice` REAL NOT NULL DEFAULT 0.0",
        "ALTER TABLE `LlmProviderConfig` ADD COLUMN `customOutputPrice` REAL NOT NULL DEFAULT 0.0",
    ]

    /// Android's exact v4-to-v5 default-normalizing table rebuild.
    private static let setCommentaryTokenDefault = [
        """
        CREATE TABLE IF NOT EXISTS `GlobalAiSettings_new` (
            `id` BLOB NOT NULL PRIMARY KEY,
            `agentPermissionMode` TEXT DEFAULT NULL,
            `permanentlyAllowedTools` TEXT DEFAULT NULL,
            `permanentlyDeniedTools` TEXT DEFAULT NULL,
            `aiExcludedDocuments` TEXT NOT NULL,
            `commentaryMaxResponseTokens` INTEGER NOT NULL DEFAULT 4000
        )
        """,
        """
        INSERT INTO `GlobalAiSettings_new` (`id`, `agentPermissionMode`, `permanentlyAllowedTools`, `permanentlyDeniedTools`, `aiExcludedDocuments`, `commentaryMaxResponseTokens`)
        SELECT `id`, `agentPermissionMode`, `permanentlyAllowedTools`, `permanentlyDeniedTools`, `aiExcludedDocuments`,
            CASE WHEN `commentaryMaxResponseTokens` = 0 THEN 4000 ELSE `commentaryMaxResponseTokens` END
        FROM `GlobalAiSettings`
        """,
        "DROP TABLE `GlobalAiSettings`",
        "ALTER TABLE `GlobalAiSettings_new` RENAME TO `GlobalAiSettings`",
    ]

    /// Android's exact v8-to-v9 provider/model/prompt/usage restructuring.
    private static let addConfiguredModels = [
        """
        CREATE TABLE IF NOT EXISTS `LlmConfiguredModel` (
            `id` BLOB NOT NULL PRIMARY KEY,
            `providerConfigId` BLOB NOT NULL,
            `modelId` TEXT NOT NULL,
            `orderNumber` INTEGER NOT NULL DEFAULT 0,
            `inputPricePerMillion` REAL NOT NULL DEFAULT 0.0,
            `outputPricePerMillion` REAL NOT NULL DEFAULT 0.0,
            `cacheCreationPricePerMillion` REAL NOT NULL DEFAULT 0.0,
            `cacheReadPricePerMillion` REAL NOT NULL DEFAULT 0.0,
            FOREIGN KEY(`providerConfigId`) REFERENCES `LlmProviderConfig`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE
        )
        """,
        "CREATE INDEX IF NOT EXISTS `index_LlmConfiguredModel_providerConfigId` ON `LlmConfiguredModel` (`providerConfigId`)",
        "CREATE UNIQUE INDEX IF NOT EXISTS `index_LlmConfiguredModel_providerConfigId_modelId` ON `LlmConfiguredModel` (`providerConfigId`, `modelId`)",
        """
        CREATE TABLE IF NOT EXISTS `LlmProviderConfig_new` (
            `id` BLOB NOT NULL PRIMARY KEY,
            `providerType` TEXT NOT NULL,
            `displayName` TEXT NOT NULL,
            `endpoint` TEXT DEFAULT NULL,
            `apiFormat` TEXT DEFAULT NULL,
            `orderNumber` INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        INSERT INTO `LlmProviderConfig_new` (`id`, `providerType`, `displayName`, `endpoint`, `apiFormat`, `orderNumber`)
        SELECT `id`, `providerType`, `displayName`, `endpoint`, `apiFormat`, `orderNumber` FROM `LlmProviderConfig`
        """,
        "DROP TABLE `LlmProviderConfig`",
        "ALTER TABLE `LlmProviderConfig_new` RENAME TO `LlmProviderConfig`",
        "CREATE INDEX IF NOT EXISTS `index_LlmProviderConfig_orderNumber` ON `LlmProviderConfig` (`orderNumber`)",
        """
        CREATE TABLE IF NOT EXISTS `AgentPrompt_new` (
            `id` BLOB NOT NULL PRIMARY KEY,
            `name` TEXT NOT NULL,
            `description` TEXT DEFAULT NULL,
            `promptTemplate` TEXT NOT NULL,
            `showIn` TEXT NOT NULL,
            `orderNumber` INTEGER NOT NULL DEFAULT 0,
            `createdAt` INTEGER NOT NULL DEFAULT 0,
            `strictContextMatching` INTEGER NOT NULL DEFAULT 1,
            `permissionMode` TEXT DEFAULT NULL,
            `allowedTools` TEXT DEFAULT NULL,
            `deniedTools` TEXT DEFAULT NULL,
            `configuredModelId` BLOB DEFAULT NULL,
            `editBeforeRun` INTEGER NOT NULL DEFAULT 0,
            `noDocumentCreation` INTEGER NOT NULL DEFAULT 0,
            `maxIterations` INTEGER DEFAULT NULL,
            FOREIGN KEY(`configuredModelId`) REFERENCES `LlmConfiguredModel`(`id`) ON UPDATE NO ACTION ON DELETE SET NULL
        )
        """,
        """
        INSERT INTO `AgentPrompt_new` (`id`, `name`, `description`, `promptTemplate`, `showIn`, `orderNumber`, `createdAt`, `strictContextMatching`, `permissionMode`, `allowedTools`, `deniedTools`, `configuredModelId`, `editBeforeRun`, `noDocumentCreation`, `maxIterations`)
        SELECT `id`, `name`, `description`, `promptTemplate`, `showIn`, `orderNumber`, `createdAt`, `strictContextMatching`, `permissionMode`, `allowedTools`, `deniedTools`, NULL, `editBeforeRun`, `noDocumentCreation`, `maxIterations` FROM `AgentPrompt`
        """,
        "DROP TABLE `AgentPrompt`",
        "ALTER TABLE `AgentPrompt_new` RENAME TO `AgentPrompt`",
        "CREATE INDEX IF NOT EXISTS `index_AgentPrompt_orderNumber` ON `AgentPrompt` (`orderNumber`)",
        "CREATE INDEX IF NOT EXISTS `index_AgentPrompt_createdAt` ON `AgentPrompt` (`createdAt`)",
        "CREATE INDEX IF NOT EXISTS `index_AgentPrompt_configuredModelId` ON `AgentPrompt` (`configuredModelId`)",
        """
        CREATE TABLE IF NOT EXISTS `LlmUsageRecord_new` (
            `id` BLOB NOT NULL PRIMARY KEY,
            `configuredModelId` BLOB NOT NULL,
            `deviceId` TEXT NOT NULL,
            `inputTokens` INTEGER NOT NULL DEFAULT 0,
            `outputTokens` INTEGER NOT NULL DEFAULT 0,
            `cacheCreationTokens` INTEGER NOT NULL DEFAULT 0,
            `cacheReadTokens` INTEGER NOT NULL DEFAULT 0,
            `estimatedCostUsd` REAL NOT NULL DEFAULT 0.0
        )
        """,
        "DROP TABLE `LlmUsageRecord`",
        "ALTER TABLE `LlmUsageRecord_new` RENAME TO `LlmUsageRecord`",
        "CREATE INDEX IF NOT EXISTS `index_LlmUsageRecord_configuredModelId` ON `LlmUsageRecord` (`configuredModelId`)",
        "CREATE UNIQUE INDEX IF NOT EXISTS `index_LlmUsageRecord_configuredModelId_deviceId` ON `LlmUsageRecord` (`configuredModelId`, `deviceId`)",
        "ALTER TABLE `GlobalAiSettings` ADD COLUMN `defaultModelId` BLOB DEFAULT NULL",
    ]

    /// Android's exact v9-to-v10 commentary-token default normalization.
    private static let raiseCommentaryTokenDefault = [
        """
        CREATE TABLE IF NOT EXISTS `GlobalAiSettings_new` (
            `id` BLOB NOT NULL PRIMARY KEY,
            `agentPermissionMode` TEXT DEFAULT NULL,
            `permanentlyAllowedTools` TEXT DEFAULT NULL,
            `permanentlyDeniedTools` TEXT DEFAULT NULL,
            `aiExcludedDocuments` TEXT NOT NULL,
            `commentaryMaxResponseTokens` INTEGER NOT NULL DEFAULT 15000,
            `hiddenBuiltInPrompts` TEXT NOT NULL,
            `maxIterations` INTEGER NOT NULL DEFAULT 10,
            `commentaryDeselected` TEXT NOT NULL,
            `defaultModelId` BLOB DEFAULT NULL
        )
        """,
        """
        INSERT INTO `GlobalAiSettings_new` (`id`, `agentPermissionMode`, `permanentlyAllowedTools`, `permanentlyDeniedTools`, `aiExcludedDocuments`, `commentaryMaxResponseTokens`, `hiddenBuiltInPrompts`, `maxIterations`, `commentaryDeselected`, `defaultModelId`)
        SELECT `id`, `agentPermissionMode`, `permanentlyAllowedTools`, `permanentlyDeniedTools`, `aiExcludedDocuments`,
            CASE WHEN `commentaryMaxResponseTokens` = 4000 THEN 15000 ELSE `commentaryMaxResponseTokens` END,
            `hiddenBuiltInPrompts`, `maxIterations`, `commentaryDeselected`, `defaultModelId`
        FROM `GlobalAiSettings`
        """,
        "DROP TABLE `GlobalAiSettings`",
        "ALTER TABLE `GlobalAiSettings_new` RENAME TO `GlobalAiSettings`",
    ]

    /// Android's exact v16-to-v17 prompt-category additions.
    private static let addPromptCategories = [
        """
        CREATE TABLE IF NOT EXISTS `PromptCategory` (
            `id` BLOB NOT NULL PRIMARY KEY,
            `name` TEXT NOT NULL,
            `orderNumber` INTEGER NOT NULL DEFAULT 0
        )
        """,
        "ALTER TABLE `AgentPrompt` ADD COLUMN `categoryId` BLOB DEFAULT NULL",
        "CREATE INDEX IF NOT EXISTS `index_AgentPrompt_categoryId` ON `AgentPrompt` (`categoryId`)",
    ]

    /// Android's exact v20-to-v21 local raw-log schema addition.
    private static let addRawLogTable = [
        """
        CREATE TABLE IF NOT EXISTS `LlmRawLogRecord` (
            `id` BLOB NOT NULL PRIMARY KEY,
            `promptId` BLOB DEFAULT NULL,
            `promptName` TEXT NOT NULL DEFAULT '',
            `promptDescription` TEXT DEFAULT NULL,
            `configuredModelId` BLOB DEFAULT NULL,
            `modelName` TEXT NOT NULL DEFAULT '',
            `providerType` TEXT NOT NULL DEFAULT '',
            `timestamp` INTEGER NOT NULL DEFAULT 0,
            `totalInputTokens` INTEGER NOT NULL DEFAULT 0,
            `totalOutputTokens` INTEGER NOT NULL DEFAULT 0,
            `estimatedCostUsd` REAL NOT NULL DEFAULT 0.0,
            `logData` BLOB NOT NULL,
            `iterationCount` INTEGER NOT NULL DEFAULT 0,
            `wasError` INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS `index_LlmRawLogRecord_timestamp` ON `LlmRawLogRecord` (`timestamp`)",
        "CREATE INDEX IF NOT EXISTS `index_LlmRawLogRecord_promptId` ON `LlmRawLogRecord` (`promptId`)",
        "CREATE INDEX IF NOT EXISTS `index_LlmRawLogRecord_configuredModelId` ON `LlmRawLogRecord` (`configuredModelId`)",
        "ALTER TABLE `GlobalAiSettings` ADD COLUMN `rawLogRetentionDays` INTEGER DEFAULT 30",
    ]

    /// Android's exact v21-to-v22 built-in prompt override addition.
    private static let addBuiltinPromptOverride = [
        """
        CREATE TABLE IF NOT EXISTS `BuiltinPromptOverride` (
            `id` BLOB NOT NULL PRIMARY KEY,
            `configuredModelId` BLOB DEFAULT NULL,
            FOREIGN KEY(`configuredModelId`) REFERENCES `LlmConfiguredModel`(`id`) ON UPDATE NO ACTION ON DELETE SET NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS `index_BuiltinPromptOverride_configuredModelId` ON `BuiltinPromptOverride` (`configuredModelId`)",
    ]
}
