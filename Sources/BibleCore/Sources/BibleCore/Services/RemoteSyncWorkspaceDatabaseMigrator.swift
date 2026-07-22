// RemoteSyncWorkspaceDatabaseMigrator.swift -- Android-equivalent staged Room migrations

import Foundation
import SQLite3

/** Typed failures emitted before a staged workspace database can be imported as Room v24. */
enum RemoteSyncWorkspaceDatabaseMigrationError: Error, Equatable {
    /// The staged file could not be opened or queried as an existing SQLite database.
    case invalidSQLiteDatabase

    /// Android has no checked-in Room export proving this source generation's schema.
    case unsupportedSourceVersion(Int)

    /// Archive metadata and the staged database disagree about their source generation.
    case sourceVersionMismatch(expected: Int, actual: Int)

    /// One exact Android migration step failed and the staged transaction was rolled back.
    case migrationFailed(from: Int, to: Int)
}

/**
 Migrates writable staged Android workspace databases through the production Room chain.

 Accepted source generations are limited to Android's checked-in `WorkspaceDatabase` exports.
 Versions 10 and 12 remain internal chain steps because Android supplies migrations through them but
 does not supply authoritative generated schemas from which iOS can validate an inbound source.
 */
enum RemoteSyncWorkspaceDatabaseMigrator {
    /// Android generations with checked-in Room exports accepted as staged import sources.
    static let supportedSourceVersions: Set<Int> = [
        1, 2, 3, 4, 5, 6, 7, 8, 9,
        11, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
    ]

    /** Returns whether Android supplies an authoritative workspace schema for one source version. */
    static func supportsSourceVersion(_ version: Int) -> Bool {
        supportedSourceVersions.contains(version)
    }

    /**
     Migrates and validates one staged workspace database before any row or sync metadata decoding.

     - Parameters:
       - databaseURL: Existing writable staged SQLite file; live app databases must never be passed.
       - expectedSourceVersion: Optional version encoded by patch metadata. When supplied, it must
         equal the staged database's pre-migration `user_version`.
     - Side Effects:
       - opens the staged file read-write
       - for predecessors, executes every Android migration step in one transaction
       - mirrors Android's `INSERT OR REPLACE`/`DELETE` trigger-disable protocol around each step
       - installs Room v24 identity metadata and `user_version`
       - commits only after complete schema, foreign-key declaration, and row-storage validation succeeds
     - Throws: Typed source-version/open/migration failures or exact v24 contract validation errors;
       every predecessor failure rolls back the staged file to its prior generation.
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
            throw RemoteSyncWorkspaceDatabaseMigrationError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        let sourceVersion = try userVersion(in: database)
        if let expectedSourceVersion, expectedSourceVersion != sourceVersion {
            throw RemoteSyncWorkspaceDatabaseMigrationError.sourceVersionMismatch(
                expected: expectedSourceVersion,
                actual: sourceVersion
            )
        }
        guard supportsSourceVersion(sourceVersion) else {
            throw RemoteSyncWorkspaceDatabaseMigrationError.unsupportedSourceVersion(sourceVersion)
        }
        let validatedRuntimeTriggerNames = try RemoteSyncAndroidDatabaseContract
            .validateWorkspaceSourceDatabase(
                database,
                sourceVersion: sourceVersion
            )

        let targetVersion = RemoteSyncAndroidDatabaseContract.schemaVersion(for: .workspaces)
        let targetIdentityHash = RemoteSyncAndroidDatabaseContract.identityHash(for: .workspaces)
        if sourceVersion == targetVersion {
            try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                database,
                category: .workspaces
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
                category: .workspaces
            )
            try execute("COMMIT;", in: database, from: sourceVersion, to: targetVersion)
        } catch {
            _ = try? execute("ROLLBACK;", in: database, from: sourceVersion, to: targetVersion)
            throw error
        }
    }

    /**
     Removes only authority-validated source triggers before validating the migrated v24 schema.

     - Parameters:
       - triggerNames: Exact trigger names returned by predecessor contract validation.
       - database: Open staged SQLite database inside the migration transaction.
       - from: Source generation used for typed migration diagnostics.
       - to: Target generation used for typed migration diagnostics.
     - Side Effects: Drops the named trigger objects from the staged database.
     - Throws: `migrationFailed` when SQLite cannot remove one validated trigger.
     */
    private static func dropRuntimeSyncTriggers(
        _ triggerNames: Set<String>,
        in database: OpaquePointer,
        from: Int,
        to: Int
    ) throws {
        for triggerName in triggerNames.sorted() {
            let quotedName = "\"\(triggerName.replacingOccurrences(of: "\"", with: "\"\""))\""
            try execute(
                "DROP TRIGGER \(quotedName);",
                in: database,
                from: from,
                to: to
            )
        }
    }

    /** Executes one Android migration while matching its sync-trigger conflict behavior. */
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
        } catch let error as RemoteSyncWorkspaceDatabaseMigrationError {
            throw error
        } catch {
            throw RemoteSyncWorkspaceDatabaseMigrationError.migrationFailed(
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
        let sql: String
        if disabled {
            sql = "INSERT OR REPLACE INTO SyncConfiguration (keyName, booleanValue) VALUES ('triggersDisabled', 1);"
        } else {
            sql = "DELETE FROM SyncConfiguration WHERE keyName = 'triggersDisabled';"
        }
        try execute(sql, in: database, from: from, to: to)
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
            throw RemoteSyncWorkspaceDatabaseMigrationError.migrationFailed(from: from, to: to)
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
            throw RemoteSyncWorkspaceDatabaseMigrationError.migrationFailed(from: from, to: to)
        }
        return sqlite3_column_int64(statement, 0) > 0
    }

    /** Reads an exact nonnegative SQLite `user_version` that fits Swift `Int`. */
    private static func userVersion(in database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RemoteSyncWorkspaceDatabaseMigrationError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              let value = Int(exactly: sqlite3_column_int64(statement, 0)),
              value >= 0,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncWorkspaceDatabaseMigrationError.invalidSQLiteDatabase
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
            throw RemoteSyncWorkspaceDatabaseMigrationError.migrationFailed(from: from, to: to)
        }
    }

    /** Returns the exact SQL statements from Android `WorkspacesMigrations.kt` for one edge. */
    private static func migrationStatements(from version: Int) -> [String] {
        switch version {
        case 1:
            ["UPDATE Workspace SET maximizedWindowId=NULL"]
        case 2:
            ["ALTER TABLE Workspace DROP COLUMN workspace_settings_favouriteLabels"]
        case 3:
            addColumn("text_display_settings_showPageNumber", type: "INTEGER", to: ["Workspace", "PageManager"])
        case 4:
            ["ALTER TABLE `PageManager` ADD COLUMN `commentary_sourceBookAndKey` TEXT DEFAULT NULL"]
        case 5:
            ["ALTER TABLE `PageManager` ADD COLUMN `jsState` TEXT DEFAULT NULL"]
        case 6:
            ["ALTER TABLE `Workspace` ADD COLUMN `workspace_settings_studyPadCursors` TEXT DEFAULT NULL"]
        case 7:
            addColumn("text_display_settings_showFootNotesInline", type: "INTEGER", to: ["Workspace", "PageManager"])
        case 8:
            ["ALTER TABLE `Workspace` ADD COLUMN `workspace_settings_restoreButtonsVisible` INTEGER DEFAULT 1"]
        case 9:
            [
                "UPDATE `Workspace` SET `text_display_settings_strongsMode` = 0 WHERE `text_display_settings_strongsMode` = 3",
                "UPDATE `PageManager` SET `text_display_settings_strongsMode` = 0 WHERE `text_display_settings_strongsMode` = 3",
            ]
        case 10:
            addColumn("text_display_settings_nonStrongsWordItalic", type: "INTEGER", to: ["Workspace", "PageManager"])
        case 11:
            addColumn("text_display_settings_showTitleScrollButton", type: "INTEGER", to: ["Workspace", "PageManager"])
        case 12:
            [
                """
                CREATE TABLE IF NOT EXISTS `WorkspaceLabelOverride` (
                    `workspaceId` BLOB NOT NULL,
                    `labelId` BLOB NOT NULL,
                    `overrideMode` INTEGER DEFAULT NULL,
                    PRIMARY KEY(`workspaceId`, `labelId`),
                    FOREIGN KEY(`workspaceId`) REFERENCES `Workspace`(`id`) ON DELETE CASCADE
                )
                """,
                "CREATE INDEX IF NOT EXISTS `index_WorkspaceLabelOverride_workspaceId` ON `WorkspaceLabelOverride` (`workspaceId`)",
            ]
        case 13:
            addColumn("text_display_settings_infiniteScroll", type: "INTEGER", to: ["Workspace", "PageManager"])
        case 14:
            addGlobalTextDisplaySettingsStatements
        case 15:
            migrateGlobalTextDisplayIdentifierStatements
        case 16:
            addColumn("text_display_settings_showMarkAsReadButton", type: "INTEGER", to: textDisplayTables)
        case 17:
            addColumn("text_display_settings_showMemorizationIndicators", type: "INTEGER", to: textDisplayTables)
        case 18:
            addColumn("text_display_settings_autoTrackReading", type: "INTEGER", to: textDisplayTables)
        case 19:
            addColumn("text_display_settings_showAiDocMarkers", type: "INTEGER", to: textDisplayTables)
        case 20:
            [
                "text_display_settings_pageScrollAmount",
                "text_display_settings_scrollHelperLines",
                "text_display_settings_scrollHelperLineStyle",
                "text_display_settings_showPageButtons",
            ].flatMap { addColumn($0, type: "INTEGER", to: textDisplayTables) }
        case 21:
            addColumn("text_display_settings_showOrdinals", type: "INTEGER", to: textDisplayTables)
        case 22:
            addColumn("text_display_settings_showReadingProgress", type: "INTEGER", to: textDisplayTables)
        case 23:
            textDisplayTables.flatMap { table in
                [
                    ("text_display_settings_colors_dayBackgroundImage", "TEXT"),
                    ("text_display_settings_colors_nightBackgroundImage", "TEXT"),
                    ("text_display_settings_colors_dayBackgroundImageOpacity", "INTEGER"),
                    ("text_display_settings_colors_nightBackgroundImageOpacity", "INTEGER"),
                ].flatMap { addColumn($0.0, type: $0.1, to: [table]) }
            }
        default:
            []
        }
    }

    /// Android tables carrying the embedded `TextDisplaySettings` value after version 15.
    private static let textDisplayTables = ["Workspace", "PageManager", "GlobalTextDisplaySettings"]

    /** Builds Android's repeated nullable `ALTER TABLE ADD COLUMN` statements in table order. */
    private static func addColumn(_ column: String, type: String, to tables: [String]) -> [String] {
        tables.map { table in
            "ALTER TABLE `\(table)` ADD COLUMN `\(column)` \(type) DEFAULT NULL"
        }
    }

    /// Android 14-to-15 global settings creation and default-normalization statements.
    private static let addGlobalTextDisplaySettingsStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS `GlobalTextDisplaySettings` (
            `id` INTEGER NOT NULL PRIMARY KEY,
            `text_display_settings_margin_size_marginLeft` INTEGER DEFAULT NULL,
            `text_display_settings_margin_size_marginRight` INTEGER DEFAULT NULL,
            `text_display_settings_margin_size_maxWidth` INTEGER DEFAULT NULL,
            `text_display_settings_colors_dayTextColor` INTEGER DEFAULT NULL,
            `text_display_settings_colors_dayBackground` INTEGER DEFAULT NULL,
            `text_display_settings_colors_dayNoise` INTEGER DEFAULT NULL,
            `text_display_settings_colors_nightTextColor` INTEGER DEFAULT NULL,
            `text_display_settings_colors_nightBackground` INTEGER DEFAULT NULL,
            `text_display_settings_colors_nightNoise` INTEGER DEFAULT NULL,
            `text_display_settings_strongsMode` INTEGER DEFAULT NULL,
            `text_display_settings_showMorphology` INTEGER DEFAULT NULL,
            `text_display_settings_showFootNotes` INTEGER DEFAULT NULL,
            `text_display_settings_showFootNotesInline` INTEGER DEFAULT NULL,
            `text_display_settings_expandXrefs` INTEGER DEFAULT NULL,
            `text_display_settings_showXrefs` INTEGER DEFAULT NULL,
            `text_display_settings_showRedLetters` INTEGER DEFAULT NULL,
            `text_display_settings_showSectionTitles` INTEGER DEFAULT NULL,
            `text_display_settings_showVerseNumbers` INTEGER DEFAULT NULL,
            `text_display_settings_showVersePerLine` INTEGER DEFAULT NULL,
            `text_display_settings_showBookmarks` INTEGER DEFAULT NULL,
            `text_display_settings_showMyNotes` INTEGER DEFAULT NULL,
            `text_display_settings_justifyText` INTEGER DEFAULT NULL,
            `text_display_settings_hyphenation` INTEGER DEFAULT NULL,
            `text_display_settings_topMargin` INTEGER DEFAULT NULL,
            `text_display_settings_fontSize` INTEGER DEFAULT NULL,
            `text_display_settings_fontFamily` TEXT DEFAULT NULL,
            `text_display_settings_lineSpacing` INTEGER DEFAULT NULL,
            `text_display_settings_bookmarksHideLabels` TEXT DEFAULT NULL,
            `text_display_settings_showPageNumber` INTEGER DEFAULT NULL,
            `text_display_settings_infiniteScroll` INTEGER DEFAULT NULL,
            `text_display_settings_nonStrongsWordItalic` INTEGER DEFAULT NULL,
            `text_display_settings_showTitleScrollButton` INTEGER DEFAULT NULL
        )
        """,
        "UPDATE Workspace SET text_display_settings_fontSize = NULL WHERE text_display_settings_fontSize = 16",
        "UPDATE Workspace SET text_display_settings_fontFamily = NULL WHERE text_display_settings_fontFamily = 'sans-serif'",
        "UPDATE Workspace SET text_display_settings_strongsMode = NULL WHERE text_display_settings_strongsMode = 0",
        "UPDATE Workspace SET text_display_settings_showMorphology = NULL WHERE text_display_settings_showMorphology = 0",
        "UPDATE Workspace SET text_display_settings_expandXrefs = NULL WHERE text_display_settings_expandXrefs = 0",
        "UPDATE Workspace SET text_display_settings_showFootNotes = NULL WHERE text_display_settings_showFootNotes = 1",
        "UPDATE Workspace SET text_display_settings_showFootNotesInline = NULL WHERE text_display_settings_showFootNotesInline = 0",
        "UPDATE Workspace SET text_display_settings_showXrefs = NULL WHERE text_display_settings_showXrefs = 1",
        "UPDATE Workspace SET text_display_settings_showRedLetters = NULL WHERE text_display_settings_showRedLetters = 1",
        "UPDATE Workspace SET text_display_settings_showSectionTitles = NULL WHERE text_display_settings_showSectionTitles = 1",
        "UPDATE Workspace SET text_display_settings_showVerseNumbers = NULL WHERE text_display_settings_showVerseNumbers = 1",
        "UPDATE Workspace SET text_display_settings_showVersePerLine = NULL WHERE text_display_settings_showVersePerLine = 0",
        "UPDATE Workspace SET text_display_settings_showMyNotes = NULL WHERE text_display_settings_showMyNotes = 1",
        "UPDATE Workspace SET text_display_settings_justifyText = NULL WHERE text_display_settings_justifyText = 1",
        "UPDATE Workspace SET text_display_settings_hyphenation = NULL WHERE text_display_settings_hyphenation = 1",
        "UPDATE Workspace SET text_display_settings_topMargin = NULL WHERE text_display_settings_topMargin = 0",
        "UPDATE Workspace SET text_display_settings_lineSpacing = NULL WHERE text_display_settings_lineSpacing = 16",
        "UPDATE Workspace SET text_display_settings_showBookmarks = NULL WHERE text_display_settings_showBookmarks = 1",
        "UPDATE Workspace SET text_display_settings_showPageNumber = NULL WHERE text_display_settings_showPageNumber = 0",
        "UPDATE Workspace SET text_display_settings_infiniteScroll = NULL WHERE text_display_settings_infiniteScroll = 1",
        "UPDATE Workspace SET text_display_settings_nonStrongsWordItalic = NULL WHERE text_display_settings_nonStrongsWordItalic = 0",
        "UPDATE Workspace SET text_display_settings_showTitleScrollButton = NULL WHERE text_display_settings_showTitleScrollButton = 0",
        "UPDATE Workspace SET text_display_settings_colors_dayBackground = NULL WHERE text_display_settings_colors_dayBackground = -1",
        "UPDATE Workspace SET text_display_settings_colors_dayTextColor = NULL WHERE text_display_settings_colors_dayTextColor = -16777216",
        "UPDATE Workspace SET text_display_settings_colors_nightBackground = NULL WHERE text_display_settings_colors_nightBackground = -16777216",
        "UPDATE Workspace SET text_display_settings_colors_nightTextColor = NULL WHERE text_display_settings_colors_nightTextColor = -1",
        "UPDATE Workspace SET text_display_settings_colors_dayNoise = NULL WHERE text_display_settings_colors_dayNoise = 0",
        "UPDATE Workspace SET text_display_settings_colors_nightNoise = NULL WHERE text_display_settings_colors_nightNoise = 0",
        "UPDATE Workspace SET text_display_settings_margin_size_marginLeft = NULL WHERE text_display_settings_margin_size_marginLeft = 3",
        "UPDATE Workspace SET text_display_settings_margin_size_marginRight = NULL WHERE text_display_settings_margin_size_marginRight = 3",
        "UPDATE Workspace SET text_display_settings_margin_size_maxWidth = NULL WHERE text_display_settings_margin_size_maxWidth = 170",
    ]

    /// Android 15-to-16 BLOB singleton recreation and first-row copy statements.
    private static let migrateGlobalTextDisplayIdentifierStatements: [String] = [
        "ALTER TABLE GlobalTextDisplaySettings RENAME TO GlobalTextDisplaySettings_old",
        """
        CREATE TABLE IF NOT EXISTS GlobalTextDisplaySettings (
            `id` BLOB NOT NULL,
            `text_display_settings_strongsMode` INTEGER DEFAULT NULL,
            `text_display_settings_showMorphology` INTEGER DEFAULT NULL,
            `text_display_settings_showFootNotes` INTEGER DEFAULT NULL,
            `text_display_settings_showFootNotesInline` INTEGER DEFAULT NULL,
            `text_display_settings_expandXrefs` INTEGER DEFAULT NULL,
            `text_display_settings_showXrefs` INTEGER DEFAULT NULL,
            `text_display_settings_showRedLetters` INTEGER DEFAULT NULL,
            `text_display_settings_showSectionTitles` INTEGER DEFAULT NULL,
            `text_display_settings_showVerseNumbers` INTEGER DEFAULT NULL,
            `text_display_settings_showVersePerLine` INTEGER DEFAULT NULL,
            `text_display_settings_showBookmarks` INTEGER DEFAULT NULL,
            `text_display_settings_showMyNotes` INTEGER DEFAULT NULL,
            `text_display_settings_justifyText` INTEGER DEFAULT NULL,
            `text_display_settings_hyphenation` INTEGER DEFAULT NULL,
            `text_display_settings_topMargin` INTEGER DEFAULT NULL,
            `text_display_settings_fontSize` INTEGER DEFAULT NULL,
            `text_display_settings_fontFamily` TEXT DEFAULT NULL,
            `text_display_settings_lineSpacing` INTEGER DEFAULT NULL,
            `text_display_settings_bookmarksHideLabels` TEXT DEFAULT NULL,
            `text_display_settings_showPageNumber` INTEGER DEFAULT NULL,
            `text_display_settings_infiniteScroll` INTEGER DEFAULT NULL,
            `text_display_settings_nonStrongsWordItalic` INTEGER DEFAULT NULL,
            `text_display_settings_showTitleScrollButton` INTEGER DEFAULT NULL,
            `text_display_settings_margin_size_marginLeft` INTEGER DEFAULT NULL,
            `text_display_settings_margin_size_marginRight` INTEGER DEFAULT NULL,
            `text_display_settings_margin_size_maxWidth` INTEGER DEFAULT NULL,
            `text_display_settings_colors_dayTextColor` INTEGER DEFAULT NULL,
            `text_display_settings_colors_dayBackground` INTEGER DEFAULT NULL,
            `text_display_settings_colors_dayNoise` INTEGER DEFAULT NULL,
            `text_display_settings_colors_nightTextColor` INTEGER DEFAULT NULL,
            `text_display_settings_colors_nightBackground` INTEGER DEFAULT NULL,
            `text_display_settings_colors_nightNoise` INTEGER DEFAULT NULL,
            PRIMARY KEY(`id`)
        )
        """,
        """
        INSERT INTO GlobalTextDisplaySettings
        SELECT X'00000000000000000000000000000001',
            text_display_settings_strongsMode,
            text_display_settings_showMorphology,
            text_display_settings_showFootNotes,
            text_display_settings_showFootNotesInline,
            text_display_settings_expandXrefs,
            text_display_settings_showXrefs,
            text_display_settings_showRedLetters,
            text_display_settings_showSectionTitles,
            text_display_settings_showVerseNumbers,
            text_display_settings_showVersePerLine,
            text_display_settings_showBookmarks,
            text_display_settings_showMyNotes,
            text_display_settings_justifyText,
            text_display_settings_hyphenation,
            text_display_settings_topMargin,
            text_display_settings_fontSize,
            text_display_settings_fontFamily,
            text_display_settings_lineSpacing,
            text_display_settings_bookmarksHideLabels,
            text_display_settings_showPageNumber,
            text_display_settings_infiniteScroll,
            text_display_settings_nonStrongsWordItalic,
            text_display_settings_showTitleScrollButton,
            text_display_settings_margin_size_marginLeft,
            text_display_settings_margin_size_marginRight,
            text_display_settings_margin_size_maxWidth,
            text_display_settings_colors_dayTextColor,
            text_display_settings_colors_dayBackground,
            text_display_settings_colors_dayNoise,
            text_display_settings_colors_nightTextColor,
            text_display_settings_colors_nightBackground,
            text_display_settings_colors_nightNoise
        FROM GlobalTextDisplaySettings_old LIMIT 1
        """,
        "DROP TABLE GlobalTextDisplaySettings_old",
    ]
}
