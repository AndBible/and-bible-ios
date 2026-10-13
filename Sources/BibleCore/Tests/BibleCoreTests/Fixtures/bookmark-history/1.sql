-- Android Room BookmarkDatabase/1.json; unmodified exported DDL.
PRAGMA user_version = 1;
CREATE TABLE IF NOT EXISTS `Bookmark` (`kjvOrdinalStart` INTEGER NOT NULL, `kjvOrdinalEnd` INTEGER NOT NULL, `ordinalStart` INTEGER NOT NULL, `ordinalEnd` INTEGER NOT NULL, `v11n` TEXT NOT NULL, `playbackSettings` TEXT, `id` BLOB NOT NULL, `createdAt` INTEGER NOT NULL, `book` TEXT, `startOffset` INTEGER, `endOffset` INTEGER, `primaryLabelId` BLOB DEFAULT NULL, `notes` TEXT DEFAULT NULL, `lastUpdatedOn` INTEGER NOT NULL DEFAULT 0, `wholeVerse` INTEGER NOT NULL DEFAULT 0, `type` TEXT DEFAULT NULL, PRIMARY KEY(`id`), FOREIGN KEY(`primaryLabelId`) REFERENCES `Label`(`id`) ON UPDATE NO ACTION ON DELETE SET NULL );
CREATE INDEX IF NOT EXISTS `index_Bookmark_kjvOrdinalStart` ON `Bookmark` (`kjvOrdinalStart`);
CREATE INDEX IF NOT EXISTS `index_Bookmark_kjvOrdinalEnd` ON `Bookmark` (`kjvOrdinalEnd`);
CREATE INDEX IF NOT EXISTS `index_Bookmark_primaryLabelId` ON `Bookmark` (`primaryLabelId`);
CREATE TABLE IF NOT EXISTS `Label` (`id` BLOB NOT NULL, `name` TEXT NOT NULL, `color` INTEGER NOT NULL DEFAULT 0, `markerStyle` INTEGER NOT NULL DEFAULT 0, `markerStyleWholeVerse` INTEGER NOT NULL DEFAULT 0, `underlineStyle` INTEGER NOT NULL DEFAULT 0, `underlineStyleWholeVerse` INTEGER NOT NULL DEFAULT 0, `type` TEXT DEFAULT NULL, PRIMARY KEY(`id`));
CREATE TABLE IF NOT EXISTS `StudyPadTextEntry` (`id` BLOB NOT NULL, `labelId` BLOB NOT NULL, `text` TEXT NOT NULL, `orderNumber` INTEGER NOT NULL, `indentLevel` INTEGER NOT NULL, PRIMARY KEY(`id`), FOREIGN KEY(`labelId`) REFERENCES `Label`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
CREATE INDEX IF NOT EXISTS `index_StudyPadTextEntry_labelId` ON `StudyPadTextEntry` (`labelId`);
CREATE TABLE IF NOT EXISTS `BookmarkToLabel` (`bookmarkId` BLOB NOT NULL, `labelId` BLOB NOT NULL, `orderNumber` INTEGER NOT NULL DEFAULT -1, `indentLevel` INTEGER NOT NULL DEFAULT 0, `expandContent` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(`bookmarkId`, `labelId`), FOREIGN KEY(`bookmarkId`) REFERENCES `Bookmark`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE , FOREIGN KEY(`labelId`) REFERENCES `Label`(`id`) ON UPDATE NO ACTION ON DELETE CASCADE );
CREATE INDEX IF NOT EXISTS `index_BookmarkToLabel_labelId` ON `BookmarkToLabel` (`labelId`);
CREATE TABLE IF NOT EXISTS `LogEntry` (`tableName` TEXT NOT NULL, `entityId1` BLOB NOT NULL, `entityId2` BLOB NOT NULL, `type` TEXT NOT NULL, `lastUpdated` INTEGER NOT NULL DEFAULT 0, `sourceDevice` TEXT NOT NULL, PRIMARY KEY(`tableName`, `entityId1`, `entityId2`));
CREATE INDEX IF NOT EXISTS `index_LogEntry_lastUpdated` ON `LogEntry` (`lastUpdated`);
CREATE INDEX IF NOT EXISTS `index_LogEntry_sourceDevice` ON `LogEntry` (`sourceDevice`);
CREATE TABLE IF NOT EXISTS `SyncConfiguration` (`keyName` TEXT NOT NULL, `stringValue` TEXT, `longValue` INTEGER, `booleanValue` INTEGER, PRIMARY KEY(`keyName`));
CREATE TABLE IF NOT EXISTS `SyncStatus` (`sourceDevice` TEXT NOT NULL, `patchNumber` INTEGER NOT NULL, `sizeBytes` INTEGER NOT NULL, `appliedDate` INTEGER NOT NULL, PRIMARY KEY(`sourceDevice`, `patchNumber`));
CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY,identity_hash TEXT);
INSERT OR REPLACE INTO room_master_table (id,identity_hash) VALUES(42, 'ff001a92878ddd1e85ad8b5d25fabc95');

-- Populated preservation fixture: literal UUIDs, text, offsets and StudyPad ordering.
INSERT INTO Label(id,name,color) VALUES(X'10000000000000000000000000000001','Personal study',123);
INSERT INTO Label(id,name,color) VALUES(X'20000000000000000000000000000001','__SPEAK_LABEL__',123);
INSERT INTO Label(id,name,color) VALUES(X'20000000000000000000000000000002','__SPEAK_LABEL__',123);
INSERT INTO Bookmark(id,kjvOrdinalStart,kjvOrdinalEnd,ordinalStart,ordinalEnd,v11n,createdAt,lastUpdatedOn,book,startOffset,endOffset,primaryLabelId,wholeVerse,notes) VALUES(X'30000000000000000000000000000001',4,5,4,5,'KJVA',1700000000000,1700000001000,'KJV',2,8,X'20000000000000000000000000000001',0,'My Bible note — preserved');
INSERT INTO BookmarkToLabel(bookmarkId,labelId,orderNumber,indentLevel,expandContent) VALUES(X'30000000000000000000000000000001',X'10000000000000000000000000000001',7,2,1);
INSERT INTO BookmarkToLabel(bookmarkId,labelId,orderNumber,indentLevel,expandContent) VALUES(X'30000000000000000000000000000001',X'20000000000000000000000000000001',8,2,1);
INSERT INTO BookmarkToLabel(bookmarkId,labelId,orderNumber,indentLevel,expandContent) VALUES(X'30000000000000000000000000000001',X'20000000000000000000000000000002',9,2,1);
INSERT INTO StudyPadTextEntry(id,labelId,orderNumber,indentLevel,text) VALUES(X'50000000000000000000000000000001',X'20000000000000000000000000000002',12,3,'StudyPad text — preserved');
INSERT INTO LogEntry(tableName,entityId1,entityId2,type,lastUpdated,sourceDevice) VALUES('Bookmark',X'30000000000000000000000000000001','','UPSERT',1700000001000,'android');
