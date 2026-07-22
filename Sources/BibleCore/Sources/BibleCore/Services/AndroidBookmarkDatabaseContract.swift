// AndroidBookmarkDatabaseContract.swift -- Android Room v12 bookmark database contract

import Foundation

/**
 Defines the Android bookmark database contract shared by backup and remote-sync boundaries.

 The schema is transcribed from Android's checked-in Room schema
 `net.bible.android.database.BookmarkDatabase/12.json`. Keeping the DDL in one place prevents the
 full-backup and sparse-patch writers from drifting independently. This type also owns Android's
 single-column `LogEntry` key convention: `entityId2` is a non-null empty text value, not SQLite
 `NULL`.
 */
enum AndroidBookmarkDatabaseContract {
    /// Current Android Room bookmark schema version.
    static let schemaVersion = 12

    /// Room identity hash recorded by Android schema version 12.
    static let identityHash = "0492abbf5bd840e0fcc87744a8af6f11"

    /// Android's secondary `LogEntry` identifier for tables with a single primary-key column.
    static let emptySecondaryEntityID = RemoteSyncSQLiteValue.text("")

    /// Bookmark tables whose Android log triggers write an empty secondary identifier.
    static let singleIdentifierTables: Set<String> = [
        "Label",
        "BibleBookmark",
        "BibleBookmarkNotes",
        "GenericBookmark",
        "GenericBookmarkNotes",
        "StudyPadTextEntry",
        "StudyPadTextEntryText",
    ]

    /// Android v12 fixed identifier for the Speak label.
    static let speakLabelID = UUID(uuidString: "00000000-0000-ab1e-0000-5bea400001a1")!

    /// Android v12 fixed identifier for the Unlabelled label.
    static let unlabeledLabelID = UUID(uuidString: "00000000-0000-ab1e-0000-001abe1ed001")!

    /// Android v12 fixed identifier for the Paragraph Break label.
    static let paragraphBreakLabelID = UUID(uuidString: "00000000-0000-ab1e-0000-ba4a64a30001")!

    /// Android v12 fixed identifier for the AI label.
    static let aiLabelID = UUID(uuidString: "00000000-0000-ab1e-0000-a100000001a1")!

    /**
     Returns the Android fixed identifier for one reserved label name.

     - Parameter name: Persisted Android label name.
     - Returns: Android v12 fixed identifier, or `nil` for a user label.
     - Side effects: none.
     - Failure modes: Unknown names return `nil`.
     */
    static func fixedLabelID(forName name: String) -> UUID? {
        switch name {
        case Label.speakLabelName:
            speakLabelID
        case Label.unlabeledName:
            unlabeledLabelID
        case Label.paragraphBreakLabelName:
            paragraphBreakLabelID
        case "__AI_LABEL__":
            aiLabelID
        default:
            nil
        }
    }

    /**
     Normalizes one bookmark-category log row onto Android's v12 primary-key representation.

     Older iOS builds persisted SQLite `NULL` for single-column secondary identifiers. Android Room
     declares the column `NOT NULL` and its triggers write `''`, so this compatibility boundary
     rewrites only those known bookmark tables. Composite junction identifiers are preserved.

     - Parameter entry: Bookmark-category log row read from local state or a staged database.
     - Returns: Row with Android's empty secondary identifier when the table has one primary key.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func normalizedLogEntry(_ entry: RemoteSyncLogEntry) -> RemoteSyncLogEntry {
        guard singleIdentifierTables.contains(entry.tableName) else {
            return entry
        }
        return RemoteSyncLogEntry(
            tableName: entry.tableName,
            entityID1: entry.entityID1,
            entityID2: emptySecondaryEntityID,
            type: entry.type,
            lastUpdated: entry.lastUpdated,
            sourceDevice: entry.sourceDevice
        )
    }

    /**
     Returns Android Room's complete bookmark schema version 12 DDL.

     - Returns: Executable SQLite batch containing every Room table, foreign key, index, view,
       `room_master_table` identity row, and `user_version` value.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static var createSchemaSQL: String {
        """
        PRAGMA user_version = 12;
        CREATE TABLE IF NOT EXISTS `BibleBookmark` (`kjvOrdinalStart` INTEGER NOT NULL, `kjvOrdinalEnd` INTEGER NOT NULL, `ordinalStart` INTEGER NOT NULL, `ordinalEnd` INTEGER NOT NULL, `v11n` TEXT NOT NULL, `playbackSettings` TEXT, `id` BLOB NOT NULL, `createdAt` INTEGER NOT NULL, `book` TEXT, `startOffset` INTEGER, `endOffset` INTEGER, `primaryLabelId` BLOB DEFAULT NULL, `lastUpdatedOn` INTEGER NOT NULL DEFAULT 0, `wholeVerse` INTEGER NOT NULL DEFAULT 0, `type` TEXT DEFAULT NULL, `customIcon` TEXT DEFAULT NULL, `sourcePromptId` BLOB DEFAULT NULL, `editAction_mode` TEXT, `editAction_content` TEXT, PRIMARY KEY(`id`), FOREIGN KEY(`primaryLabelId`) REFERENCES `Label`(`id`) ON UPDATE NO ACTION ON DELETE SET NULL );
        CREATE INDEX IF NOT EXISTS `index_BibleBookmark_kjvOrdinalStart` ON `BibleBookmark` (`kjvOrdinalStart`);
        CREATE INDEX IF NOT EXISTS `index_BibleBookmark_kjvOrdinalEnd` ON `BibleBookmark` (`kjvOrdinalEnd`);
        CREATE INDEX IF NOT EXISTS `index_BibleBookmark_primaryLabelId` ON `BibleBookmark` (`primaryLabelId`);
        CREATE TABLE IF NOT EXISTS `BibleBookmarkNotes` (`bookmarkId` BLOB NOT NULL, `notes` TEXT NOT NULL, `contentType` TEXT DEFAULT NULL, `sourcePromptId` BLOB DEFAULT NULL, PRIMARY KEY(`bookmarkId`), FOREIGN KEY(`bookmarkId`) REFERENCES `BibleBookmark`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
        CREATE TABLE IF NOT EXISTS `BibleBookmarkToLabel` (`bookmarkId` BLOB NOT NULL, `labelId` BLOB NOT NULL, `orderNumber` INTEGER NOT NULL DEFAULT -1, `indentLevel` INTEGER NOT NULL DEFAULT 0, `expandContent` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(`bookmarkId`, `labelId`), FOREIGN KEY(`bookmarkId`) REFERENCES `BibleBookmark`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE , FOREIGN KEY(`labelId`) REFERENCES `Label`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
        CREATE INDEX IF NOT EXISTS `index_BibleBookmarkToLabel_labelId` ON `BibleBookmarkToLabel` (`labelId`);
        CREATE TABLE IF NOT EXISTS `GenericBookmark` (`id` BLOB NOT NULL, `key` TEXT NOT NULL, `createdAt` INTEGER NOT NULL, `bookInitials` TEXT NOT NULL DEFAULT '', `ordinalStart` INTEGER, `ordinalEnd` INTEGER, `startOffset` INTEGER, `endOffset` INTEGER, `primaryLabelId` BLOB DEFAULT NULL, `lastUpdatedOn` INTEGER NOT NULL DEFAULT 0, `wholeVerse` INTEGER NOT NULL DEFAULT 0, `playbackSettings` TEXT, `customIcon` TEXT DEFAULT NULL, `sourcePromptId` BLOB DEFAULT NULL, `editAction_mode` TEXT, `editAction_content` TEXT, PRIMARY KEY(`id`), FOREIGN KEY(`primaryLabelId`) REFERENCES `Label`(`id`) ON UPDATE NO ACTION ON DELETE SET NULL );
        CREATE INDEX IF NOT EXISTS `index_GenericBookmark_bookInitials_key` ON `GenericBookmark` (`bookInitials`, `key`);
        CREATE INDEX IF NOT EXISTS `index_GenericBookmark_primaryLabelId` ON `GenericBookmark` (`primaryLabelId`);
        CREATE TABLE IF NOT EXISTS `GenericBookmarkNotes` (`bookmarkId` BLOB NOT NULL, `notes` TEXT NOT NULL, `contentType` TEXT DEFAULT NULL, `sourcePromptId` BLOB DEFAULT NULL, PRIMARY KEY(`bookmarkId`), FOREIGN KEY(`bookmarkId`) REFERENCES `GenericBookmark`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
        CREATE TABLE IF NOT EXISTS `GenericBookmarkToLabel` (`bookmarkId` BLOB NOT NULL, `labelId` BLOB NOT NULL, `orderNumber` INTEGER NOT NULL DEFAULT -1, `indentLevel` INTEGER NOT NULL DEFAULT 0, `expandContent` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(`bookmarkId`, `labelId`), FOREIGN KEY(`bookmarkId`) REFERENCES `GenericBookmark`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE , FOREIGN KEY(`labelId`) REFERENCES `Label`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
        CREATE INDEX IF NOT EXISTS `index_GenericBookmarkToLabel_labelId` ON `GenericBookmarkToLabel` (`labelId`);
        CREATE TABLE IF NOT EXISTS `Label` (`id` BLOB NOT NULL, `name` TEXT NOT NULL, `color` INTEGER NOT NULL DEFAULT 0, `markerStyle` INTEGER NOT NULL DEFAULT 0, `markerStyleWholeVerse` INTEGER NOT NULL DEFAULT 0, `underlineStyle` INTEGER NOT NULL DEFAULT 0, `underlineStyleWholeVerse` INTEGER NOT NULL DEFAULT 0, `hideStyle` INTEGER NOT NULL DEFAULT 0, `hideStyleWholeVerse` INTEGER NOT NULL DEFAULT 0, `favourite` INTEGER NOT NULL DEFAULT 0, `type` TEXT DEFAULT NULL, `customIcon` TEXT DEFAULT NULL, PRIMARY KEY(`id`));
        CREATE INDEX IF NOT EXISTS `index_Label_favourite` ON `Label` (`favourite`);
        CREATE TABLE IF NOT EXISTS `StudyPadTextEntry` (`id` BLOB NOT NULL, `labelId` BLOB NOT NULL, `orderNumber` INTEGER NOT NULL, `indentLevel` INTEGER NOT NULL, `contentType` TEXT DEFAULT NULL, `sourcePromptId` BLOB DEFAULT NULL, PRIMARY KEY(`id`), FOREIGN KEY(`labelId`) REFERENCES `Label`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
        CREATE INDEX IF NOT EXISTS `index_StudyPadTextEntry_labelId` ON `StudyPadTextEntry` (`labelId`);
        CREATE TABLE IF NOT EXISTS `StudyPadTextEntryText` (`studyPadTextEntryId` BLOB NOT NULL, `text` TEXT NOT NULL, PRIMARY KEY(`studyPadTextEntryId`), FOREIGN KEY(`studyPadTextEntryId`) REFERENCES `StudyPadTextEntry`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
        CREATE TABLE IF NOT EXISTS `LogEntry` (`tableName` TEXT NOT NULL, `entityId1` BLOB NOT NULL, `entityId2` BLOB NOT NULL, `type` TEXT NOT NULL, `lastUpdated` INTEGER NOT NULL DEFAULT 0, `sourceDevice` TEXT NOT NULL, PRIMARY KEY(`tableName`, `entityId1`, `entityId2`));
        CREATE INDEX IF NOT EXISTS `index_LogEntry_lastUpdated` ON `LogEntry` (`lastUpdated`);
        CREATE INDEX IF NOT EXISTS `index_LogEntry_sourceDevice` ON `LogEntry` (`sourceDevice`);
        CREATE TABLE IF NOT EXISTS `SyncConfiguration` (`keyName` TEXT NOT NULL, `stringValue` TEXT, `longValue` INTEGER, `booleanValue` INTEGER, PRIMARY KEY(`keyName`));
        CREATE TABLE IF NOT EXISTS `SyncStatus` (`sourceDevice` TEXT NOT NULL, `patchNumber` INTEGER NOT NULL, `sizeBytes` INTEGER NOT NULL, `appliedDate` INTEGER NOT NULL, PRIMARY KEY(`sourceDevice`, `patchNumber`));
        CREATE VIEW `BibleBookmarkWithNotes` AS SELECT b.*, bn.notes, bn.contentType AS notesContentType, bn.sourcePromptId AS notesSourcePromptId FROM BibleBookmark b LEFT OUTER JOIN BibleBookmarkNotes bn ON b.id = bn.bookmarkId;
        CREATE VIEW `GenericBookmarkWithNotes` AS SELECT b.*, bn.notes, bn.contentType AS notesContentType, bn.sourcePromptId AS notesSourcePromptId FROM GenericBookmark b LEFT OUTER JOIN GenericBookmarkNotes bn ON b.id = bn.bookmarkId;
        CREATE VIEW `StudyPadTextEntryWithText` AS SELECT e.*, t.text FROM StudyPadTextEntry e INNER JOIN StudyPadTextEntryText t ON e.id = t.studyPadTextEntryId;
        CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY,identity_hash TEXT);
        INSERT OR REPLACE INTO room_master_table (id,identity_hash) VALUES(42, '0492abbf5bd840e0fcc87744a8af6f11');
        """
    }
}
