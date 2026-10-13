// Android BookmarkMigrations.kt (Room 1–12) and Utilities.kt trigger lifecycle.
import Foundation
import SQLite3

/// Failures while upgrading an extracted Android bookmark database; no local user data is changed.
enum RemoteSyncBookmarkDatabaseMigrationError: Error, Equatable, LocalizedError {
    /// The staged file cannot be opened or queried as SQLite.
    case invalidSQLiteDatabase
    /// No authoritative Android Room migration chain exists for this generation.
    case unsupportedSourceVersion(Int)
    /// A schema transition failed; its transaction has been rolled back.
    case migrationFailed(from: Int, to: Int, reason: String)

    /// Describes the failing schema transition and SQLite diagnosis.
    var errorDescription: String? {
        switch self {
        case .invalidSQLiteDatabase:
            return "The bookmark backup could not be read as a SQLite database."
        case .unsupportedSourceVersion(let version):
            return "Bookmark database version \(version) is not supported. Supported Android versions are 1–12."
        case let .migrationFailed(from, to, reason):
            return "The bookmark backup could not be upgraded from version \(from) to \(to): \(reason)"
        }
    }
}

/**
 Runs Android's BookmarkMigrations.kt chain on an extracted, disposable database before decoding.

 The archive and SwiftData store remain untouched. All steps commit together; failure rolls back
 the staged database. Sync triggers are disabled while migrating, as in Android's Utilities.kt,
 so note extraction and label merging do not invent new synchronization history.
 */
enum RemoteSyncBookmarkDatabaseMigrator {
    /// Every generation from 1 through 12 has a checked-in Android Room schema and migration path.
    static func supportsSourceVersion(_ version: Int) -> Bool { (1...12).contains(version) }

    /**
     Upgrades a caller-owned staged SQLite file to Room v12, preserving content and relationships.

     - Parameter databaseURL: Writable extracted backup, never the live database or archive.
     - Throws: A typed unsupported-version, open, or SQL-transition error. SQL errors roll back.
     - Side Effects: Rewrites only this staged file. Repeating on version 12 performs no writes.
     */
    static func migrateStagedDatabase(at databaseURL: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database = handle else {
            if let handle { sqlite3_close(handle) }
            throw RemoteSyncBookmarkDatabaseMigrationError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw RemoteSyncBookmarkDatabaseMigrationError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw RemoteSyncBookmarkDatabaseMigrationError.invalidSQLiteDatabase
        }
        let sourceVersion = Int(sqlite3_column_int(statement, 0))
        // Release the read cursor before schema writes and COMMIT.
        sqlite3_reset(statement)
        guard supportsSourceVersion(sourceVersion) else {
            throw RemoteSyncBookmarkDatabaseMigrationError.unsupportedSourceVersion(sourceVersion)
        }
        guard sourceVersion < 12 else { return }
        try execute("PRAGMA foreign_keys = ON", in: database, from: sourceVersion)
        try execute("BEGIN IMMEDIATE", in: database, from: sourceVersion)
        do {
            for version in sourceVersion..<12 {
                try execute("INSERT OR REPLACE INTO SyncConfiguration (keyName, booleanValue) VALUES ('triggersDisabled', 1)", in: database, from: version)
                for sql in statements(from: version) {
                    try execute(sql, in: database, from: version)
                }
                try execute("DELETE FROM SyncConfiguration WHERE keyName = 'triggersDisabled'", in: database, from: version)
            }
            try execute("CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT)", in: database, from: sourceVersion)
            try execute("INSERT OR REPLACE INTO room_master_table(id, identity_hash) VALUES (42, '0492abbf5bd840e0fcc87744a8af6f11')", in: database, from: sourceVersion)
            try execute("PRAGMA user_version = 12", in: database, from: sourceVersion)
            try execute("COMMIT", in: database, from: sourceVersion)
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Executes one trusted migration statement, retaining SQLite's structural failure diagnosis.
    private static func execute(_ sql: String, in database: OpaquePointer, from version: Int) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncBookmarkDatabaseMigrationError.migrationFailed(
                from: version, to: version + 1, reason: String(cString: sqlite3_errmsg(database))
            )
        }
    }

    /// Exact Android Room steps; added fields retain Android defaults and historical text is moved.
    private static func statements(from version: Int) -> [String] {
        switch version {
        case 1:
            return [
                "CREATE TABLE IF NOT EXISTS `BookmarkNotes` (`bookmarkId` BLOB NOT NULL, `notes` TEXT NOT NULL, PRIMARY KEY(`bookmarkId`), FOREIGN KEY(`bookmarkId`) REFERENCES `Bookmark`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE )",
                "CREATE TABLE IF NOT EXISTS `StudyPadTextEntryText` (`studyPadTextEntryId` BLOB NOT NULL, `text` TEXT NOT NULL, PRIMARY KEY(`studyPadTextEntryId`), FOREIGN KEY(`studyPadTextEntryId`) REFERENCES `StudyPadTextEntry`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE )",
                "INSERT INTO BookmarkNotes (bookmarkId, notes) SELECT id, notes FROM Bookmark WHERE notes IS NOT NULL",
                "INSERT INTO StudyPadTextEntryText (studyPadTextEntryId, text) SELECT id, text FROM StudyPadTextEntry",
                "ALTER TABLE Bookmark DROP COLUMN notes",
                "ALTER TABLE StudyPadTextEntry DROP COLUMN text",
                "CREATE VIEW `BookmarkWithNotes` AS SELECT b.*, bn.notes FROM Bookmark b LEFT OUTER JOIN BookmarkNotes bn ON b.id = bn.bookmarkId",
                "CREATE VIEW `StudyPadTextEntryWithText` AS SELECT e.*, t.text FROM StudyPadTextEntry e INNER JOIN StudyPadTextEntryText t ON e.id = t.studyPadTextEntryId",
            ]
        case 2:
            return [
                "CREATE TABLE IF NOT EXISTS `GenericBookmark` (`id` BLOB NOT NULL, `key` TEXT NOT NULL, `createdAt` INTEGER NOT NULL, `book` TEXT, `ordinalStart` INTEGER NOT NULL, `ordinalEnd` INTEGER NOT NULL, `startOffset` INTEGER, `endOffset` INTEGER, `primaryLabelId` BLOB DEFAULT NULL, `lastUpdatedOn` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(`id`), FOREIGN KEY(`primaryLabelId`) REFERENCES `Label`(`id`) ON UPDATE NO ACTION ON DELETE SET NULL )",
                "CREATE INDEX IF NOT EXISTS `index_GenericBookmark_book_key` ON `GenericBookmark` (`book`, `key`)",
                "CREATE TABLE IF NOT EXISTS `GenericBookmarkNotes` (`bookmarkId` BLOB NOT NULL, `notes` TEXT NOT NULL, PRIMARY KEY(`bookmarkId`), FOREIGN KEY(`bookmarkId`) REFERENCES `GenericBookmark`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE )",
                "CREATE TABLE IF NOT EXISTS `GenericBookmarkToLabel` (`bookmarkId` BLOB NOT NULL, `labelId` BLOB NOT NULL, `orderNumber` INTEGER NOT NULL DEFAULT -1, `indentLevel` INTEGER NOT NULL DEFAULT 0, `expandContent` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(`bookmarkId`, `labelId`), FOREIGN KEY(`bookmarkId`) REFERENCES `GenericBookmark`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE , FOREIGN KEY(`labelId`) REFERENCES `Label`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE )",
                "CREATE INDEX IF NOT EXISTS `index_GenericBookmarkToLabel_labelId` ON `GenericBookmarkToLabel` (`labelId`)",
                "CREATE VIEW `GenericBookmarkWithNotes` AS SELECT b.*, bn.notes FROM GenericBookmark b LEFT OUTER JOIN GenericBookmarkNotes bn ON b.id = bn.bookmarkId",
                "ALTER TABLE Bookmark RENAME TO BibleBookmark",
                "ALTER TABLE BookmarkNotes RENAME TO BibleBookmarkNotes",
                "ALTER TABLE BookmarkToLabel RENAME TO BibleBookmarkToLabel",
                "UPDATE LogEntry SET tableName='BibleBookmark' WHERE tableName='Bookmark'",
                "UPDATE LogEntry SET tableName='BibleBookmarkNotes' WHERE tableName='BookmarkNotes'",
                "UPDATE LogEntry SET tableName='BibleBookmarkToLabel' WHERE tableName='BookmarkToLabel'",
                "DROP VIEW BookmarkWithNotes",
                "CREATE VIEW `BibleBookmarkWithNotes` AS SELECT b.*, bn.notes FROM BibleBookmark b LEFT OUTER JOIN BibleBookmarkNotes bn ON b.id = bn.bookmarkId",
            ]
        case 3:
            return [
                "ALTER TABLE GenericBookmark ADD COLUMN bookInitials TEXT NOT NULL DEFAULT ''",
                "UPDATE GenericBookmark SET bookInitials = book",
                "DROP INDEX `index_GenericBookmark_book_key`",
                "ALTER TABLE GenericBookmark DROP COLUMN book",
                "CREATE INDEX IF NOT EXISTS `index_GenericBookmark_bookInitials_key` ON `GenericBookmark` (`bookInitials`, `key`)",
            ]
        case 4:
            return [
                "ALTER TABLE GenericBookmark ADD COLUMN wholeVerse INTEGER NOT NULL DEFAULT 0",
            ]
        case 5:
            return [
                "ALTER TABLE GenericBookmark ADD COLUMN playbackSettings TEXT DEFAULT NULL",
            ]
        case 6:
            return [
                "CREATE INDEX IF NOT EXISTS `index_GenericBookmark_primaryLabelId` ON `GenericBookmark` (`primaryLabelId`)",
            ]
        case 7:
            return [
                "ALTER TABLE Label ADD COLUMN hideStyle INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE Label ADD COLUMN hideStyleWholeVerse INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE Label ADD COLUMN favourite INTEGER NOT NULL DEFAULT 0",
                "CREATE INDEX IF NOT EXISTS `index_Label_favourite` ON `Label` (`favourite`)",
            ]
        case 8:
            return [
                "ALTER TABLE Label ADD COLUMN customIcon TEXT DEFAULT NULL",
                "ALTER TABLE BibleBookmark ADD COLUMN customIcon TEXT DEFAULT NULL",
                "ALTER TABLE GenericBookmark ADD COLUMN customIcon TEXT DEFAULT NULL",
            ]
        case 9:
            return [
                "ALTER TABLE BibleBookmark ADD COLUMN editAction_mode TEXT DEFAULT NULL",
                "ALTER TABLE BibleBookmark ADD COLUMN editAction_content TEXT DEFAULT NULL",
                "ALTER TABLE GenericBookmark ADD COLUMN editAction_mode TEXT DEFAULT NULL",
                "ALTER TABLE GenericBookmark ADD COLUMN editAction_content TEXT DEFAULT NULL",
            ]
        case 10:
            return [
                "ALTER TABLE BibleBookmark ADD COLUMN sourcePromptId BLOB DEFAULT NULL",
                "ALTER TABLE GenericBookmark ADD COLUMN sourcePromptId BLOB DEFAULT NULL",
                "ALTER TABLE GenericBookmark RENAME COLUMN ordinalStart TO ordinalStart_old",
                "ALTER TABLE GenericBookmark RENAME COLUMN ordinalEnd TO ordinalEnd_old",
                "ALTER TABLE GenericBookmark ADD COLUMN ordinalStart INTEGER DEFAULT NULL",
                "ALTER TABLE GenericBookmark ADD COLUMN ordinalEnd INTEGER DEFAULT NULL",
                "UPDATE GenericBookmark SET ordinalStart = ordinalStart_old, ordinalEnd = ordinalEnd_old",
                "ALTER TABLE GenericBookmark DROP COLUMN ordinalStart_old",
                "ALTER TABLE GenericBookmark DROP COLUMN ordinalEnd_old",
                "ALTER TABLE BibleBookmarkNotes ADD COLUMN contentType TEXT DEFAULT NULL",
                "ALTER TABLE BibleBookmarkNotes ADD COLUMN sourcePromptId BLOB DEFAULT NULL",
                "ALTER TABLE GenericBookmarkNotes ADD COLUMN contentType TEXT DEFAULT NULL",
                "ALTER TABLE GenericBookmarkNotes ADD COLUMN sourcePromptId BLOB DEFAULT NULL",
                "ALTER TABLE StudyPadTextEntry ADD COLUMN contentType TEXT DEFAULT NULL",
                "ALTER TABLE StudyPadTextEntry ADD COLUMN sourcePromptId BLOB DEFAULT NULL",
                "DROP VIEW IF EXISTS BibleBookmarkWithNotes",
                "CREATE VIEW `BibleBookmarkWithNotes` AS SELECT b.*, bn.notes, bn.contentType AS notesContentType, bn.sourcePromptId AS notesSourcePromptId FROM BibleBookmark b LEFT OUTER JOIN BibleBookmarkNotes bn ON b.id = bn.bookmarkId",
                "DROP VIEW IF EXISTS GenericBookmarkWithNotes",
                "CREATE VIEW `GenericBookmarkWithNotes` AS SELECT b.*, bn.notes, bn.contentType AS notesContentType, bn.sourcePromptId AS notesSourcePromptId FROM GenericBookmark b LEFT OUTER JOIN GenericBookmarkNotes bn ON b.id = bn.bookmarkId",
                "DROP VIEW IF EXISTS StudyPadTextEntryWithText",
                "CREATE VIEW `StudyPadTextEntryWithText` AS SELECT e.*, t.text FROM StudyPadTextEntry e INNER JOIN StudyPadTextEntryText t ON e.id = t.studyPadTextEntryId",
            ]
        case 11:
            return specialLabelStatements()
        default:
            preconditionFailure("No Android bookmark migration for version \(version)")
        }
    }

    /// Mirrors Android 11→12: canonical rows win collisions; all references move before deletion.
    /// AI labels are deliberately excluded because Android migrates only these three names.
    private static func specialLabelStatements() -> [String] {
        let labels = [
            ("__SPEAK_LABEL__", "000000000000ab1e00005bea400001a1"),
            ("__UNLABELED__", "000000000000ab1e0000001abe1ed001"),
            ("__PARAGRAPH_BREAK_LABEL__", "000000000000ab1e0000ba4a64a30001"),
        ]
        return labels.flatMap { name, hex -> [String] in
            let oldIDs = "SELECT id FROM Label WHERE name = '\(name)' AND id != X'\(hex)'"
            var sql = ["""
                INSERT OR IGNORE INTO Label (id, name, color, markerStyle, markerStyleWholeVerse,
                    underlineStyle, underlineStyleWholeVerse, hideStyle, hideStyleWholeVerse,
                    favourite, type, customIcon)
                SELECT X'\(hex)', name, color, markerStyle, markerStyleWholeVerse,
                    underlineStyle, underlineStyleWholeVerse, hideStyle, hideStyleWholeVerse,
                    favourite, type, customIcon
                FROM Label WHERE name = '\(name)' ORDER BY id LIMIT 1
                """]
            for table in ["BibleBookmarkToLabel", "GenericBookmarkToLabel"] {
                sql.append("""
                    INSERT OR IGNORE INTO \(table) (bookmarkId, labelId, orderNumber, indentLevel, expandContent)
                    SELECT bookmarkId, X'\(hex)', orderNumber, indentLevel, expandContent
                    FROM \(table) WHERE labelId IN (\(oldIDs))
                    """)
                sql.append("DELETE FROM \(table) WHERE labelId IN (\(oldIDs))")
            }
            for table in ["BibleBookmark", "GenericBookmark"] {
                sql.append("UPDATE \(table) SET primaryLabelId = X'\(hex)' WHERE primaryLabelId IN (\(oldIDs))")
            }
            sql.append("UPDATE StudyPadTextEntry SET labelId = X'\(hex)' WHERE labelId IN (\(oldIDs))")
            sql.append("DELETE FROM Label WHERE name = '\(name)' AND id != X'\(hex)'")
            return sql
        }
    }
}
