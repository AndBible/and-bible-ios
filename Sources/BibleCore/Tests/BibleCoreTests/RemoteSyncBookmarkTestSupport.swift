import Foundation
import SQLite3
import SwiftData
import XCTest
@testable import BibleCore

private let bookmarkSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct AndroidBookmarkLogEntryRow {
    let tableName: String
    let entityID1: RemoteSyncSQLiteValue
    let entityID2: RemoteSyncSQLiteValue
    let type: RemoteSyncLogEntryType
    let lastUpdated: Int64
    let sourceDevice: String
}

struct AndroidBookmarkLabelRow {
    let id: UUID
    let name: String
    let colour: Int
    let markerStyle: Bool
    let markerStyleWholeVerse: Bool
    let underlineStyle: Bool
    let underlineStyleWholeVerse: Bool
    let hideStyle: Bool
    let hideStyleWholeVerse: Bool
    let favourite: Bool
    let type: String?
    let customIcon: String?

    init(
        id: UUID,
        name: String,
        colour: Int = Label.defaultColor,
        markerStyle: Bool = false,
        markerStyleWholeVerse: Bool = false,
        underlineStyle: Bool = false,
        underlineStyleWholeVerse: Bool = true,
        hideStyle: Bool = false,
        hideStyleWholeVerse: Bool = false,
        favourite: Bool = false,
        type: String? = nil,
        customIcon: String? = nil
    ) {
        self.id = id
        self.name = name
        self.colour = colour
        self.markerStyle = markerStyle
        self.markerStyleWholeVerse = markerStyleWholeVerse
        self.underlineStyle = underlineStyle
        self.underlineStyleWholeVerse = underlineStyleWholeVerse
        self.hideStyle = hideStyle
        self.hideStyleWholeVerse = hideStyleWholeVerse
        self.favourite = favourite
        self.type = type
        self.customIcon = customIcon
    }
}

struct AndroidBibleBookmarkRow {
    let id: UUID
    let kjvOrdinalStart: Int
    let kjvOrdinalEnd: Int
    let ordinalStart: Int
    let ordinalEnd: Int
    let v11n: String
    let playbackSettingsJSON: String?
    let createdAt: Date
    let book: String?
    let startOffset: Int?
    let endOffset: Int?
    let primaryLabelID: UUID?
    let lastUpdatedOn: Date
    let wholeVerse: Bool
    let type: String?
    let customIcon: String?
    let editActionMode: String?
    let editActionContent: String?

    init(
        id: UUID,
        kjvOrdinalStart: Int,
        kjvOrdinalEnd: Int,
        ordinalStart: Int,
        ordinalEnd: Int,
        v11n: String = "KJVA",
        playbackSettingsJSON: String? = nil,
        createdAt: Date,
        book: String? = nil,
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        primaryLabelID: UUID? = nil,
        lastUpdatedOn: Date,
        wholeVerse: Bool = true,
        type: String? = nil,
        customIcon: String? = nil,
        editActionMode: String? = nil,
        editActionContent: String? = nil
    ) {
        self.id = id
        self.kjvOrdinalStart = kjvOrdinalStart
        self.kjvOrdinalEnd = kjvOrdinalEnd
        self.ordinalStart = ordinalStart
        self.ordinalEnd = ordinalEnd
        self.v11n = v11n
        self.playbackSettingsJSON = playbackSettingsJSON
        self.createdAt = createdAt
        self.book = book
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.primaryLabelID = primaryLabelID
        self.lastUpdatedOn = lastUpdatedOn
        self.wholeVerse = wholeVerse
        self.type = type
        self.customIcon = customIcon
        self.editActionMode = editActionMode
        self.editActionContent = editActionContent
    }
}

struct AndroidGenericBookmarkRow {
    let id: UUID
    let key: String
    let createdAt: Date
    let bookInitials: String
    let ordinalStart: Int
    let ordinalEnd: Int
    let startOffset: Int?
    let endOffset: Int?
    let primaryLabelID: UUID?
    let lastUpdatedOn: Date
    let wholeVerse: Bool
    let playbackSettingsJSON: String?
    let customIcon: String?
    let editActionMode: String?
    let editActionContent: String?

    init(
        id: UUID,
        key: String,
        createdAt: Date,
        bookInitials: String,
        ordinalStart: Int,
        ordinalEnd: Int,
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        primaryLabelID: UUID? = nil,
        lastUpdatedOn: Date,
        wholeVerse: Bool = true,
        playbackSettingsJSON: String? = nil,
        customIcon: String? = nil,
        editActionMode: String? = nil,
        editActionContent: String? = nil
    ) {
        self.id = id
        self.key = key
        self.createdAt = createdAt
        self.bookInitials = bookInitials
        self.ordinalStart = ordinalStart
        self.ordinalEnd = ordinalEnd
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.primaryLabelID = primaryLabelID
        self.lastUpdatedOn = lastUpdatedOn
        self.wholeVerse = wholeVerse
        self.playbackSettingsJSON = playbackSettingsJSON
        self.customIcon = customIcon
        self.editActionMode = editActionMode
        self.editActionContent = editActionContent
    }
}

struct AndroidBookmarkNoteRow {
    let bookmarkID: UUID
    let notes: String
    let contentType: String?

    init(bookmarkID: UUID, notes: String, contentType: String? = nil) {
        self.bookmarkID = bookmarkID
        self.notes = notes
        self.contentType = contentType
    }
}

struct AndroidBookmarkLabelLinkRow {
    let bookmarkID: UUID
    let labelID: UUID
    let orderNumber: Int
    let indentLevel: Int
    let expandContent: Bool
}

struct AndroidBookmarkStudyPadEntryRow {
    let id: UUID
    let labelID: UUID
    let orderNumber: Int
    let indentLevel: Int
    let contentType: String?

    init(id: UUID, labelID: UUID, orderNumber: Int, indentLevel: Int, contentType: String? = nil) {
        self.id = id
        self.labelID = labelID
        self.orderNumber = orderNumber
        self.indentLevel = indentLevel
        self.contentType = contentType
    }
}

struct AndroidBookmarkStudyPadTextRow {
    let entryID: UUID
    let text: String
}

func makeBookmarkRestoreModelContainer() throws -> ModelContainer {
    let schema = Schema([
        BibleBookmark.self,
        BibleBookmarkNotes.self,
        BibleBookmarkToLabel.self,
        GenericBookmark.self,
        GenericBookmarkNotes.self,
        GenericBookmarkToLabel.self,
        Label.self,
        StudyPadTextEntry.self,
        StudyPadTextEntryText.self,
        Setting.self,
    ])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [configuration])
}

/**
 Creates one staged bookmark patch archive from a temporary SQLite database fixture.

 - Parameters:
   - patchDatabaseURL: Local SQLite database containing Android bookmark patch rows.
   - sourceDevice: Android source-device name owning the patch stream.
   - patchNumber: Monotonic patch number within the source-device stream.
   - fileTimestamp: Remote millisecond timestamp that should be recorded on the staged archive.
 - Returns: Staged patch archive pointing at a temporary gzip file.
 - Side effects:
   - reads the supplied SQLite database
   - writes one temporary gzip archive beneath the process temporary directory
 - Failure modes:
   - rethrows filesystem read and write errors
   - rethrows gzip-compression failures from `RemoteSyncArchiveStagingService`
 */
func makeBookmarkPatchArchive(
    patchDatabaseURL: URL,
    sourceDevice: String,
    patchNumber: Int64,
    fileTimestamp: Int64
) throws -> RemoteSyncStagedPatchArchive {
    let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
    let archiveURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("android-bookmarks-patch-\(UUID().uuidString).sqlite3.gz")
    try archiveData.write(to: archiveURL, options: .atomic)

    return RemoteSyncStagedPatchArchive(
        patch: RemoteSyncDiscoveredPatch(
            sourceDevice: sourceDevice,
            patchNumber: patchNumber,
            schemaVersion: 1,
            file: RemoteSyncFile(
                id: "/org.andbible.ios-sync-bookmarks/\(sourceDevice)/\(patchNumber).sqlite3.gz",
                name: "\(patchNumber).sqlite3.gz",
                size: Int64(archiveData.count),
                timestamp: fileTimestamp,
                parentID: "/org.andbible.ios-sync-bookmarks/\(sourceDevice)",
                mimeType: "application/gzip"
            )
        ),
        archiveFileURL: archiveURL
    )
}

/**
 Builds a temporary Android-shaped bookmark SQLite database for restore, import, and sync tests.

 The default schema mirrors current Android bookmark tables, including nullable note and
 StudyPad `contentType` columns. Tests can set `includeContentTypeColumns` to `false` only when
 they intentionally validate backward-compatible reads of older Android databases.

 - Parameters:
   - labels: Android label rows to insert.
   - bibleBookmarks: Android Bible bookmark parent rows to insert.
   - bibleNotes: Detached Bible note rows, including optional Android `TextContentType` values.
   - bibleLinks: Bible bookmark-to-label junction rows.
   - genericBookmarks: Android generic bookmark parent rows to insert.
   - genericNotes: Detached generic note rows, including optional Android `TextContentType` values.
   - genericLinks: Generic bookmark-to-label junction rows.
   - studyPadEntries: StudyPad parent rows, including optional Android `TextContentType` values.
   - studyPadTexts: StudyPad text payload rows.
   - logEntries: Android sync log entries to insert for patch/metadata tests.
   - includeContentTypeColumns: Whether to create current Android content-type columns. Defaults
     to `true`; use `false` only for legacy-schema compatibility tests.
 - Returns: File URL for the temporary SQLite database. The caller is responsible for cleanup.
 - Side effects:
   - writes a temporary SQLite file in the process temporary directory
 - Failure modes:
   - throws when SQLite setup fails or when fixture rows cannot be inserted
 */
func makeAndroidBookmarksDatabase(
    labels: [AndroidBookmarkLabelRow],
    bibleBookmarks: [AndroidBibleBookmarkRow] = [],
    bibleNotes: [AndroidBookmarkNoteRow] = [],
    bibleLinks: [AndroidBookmarkLabelLinkRow] = [],
    genericBookmarks: [AndroidGenericBookmarkRow] = [],
    genericNotes: [AndroidBookmarkNoteRow] = [],
    genericLinks: [AndroidBookmarkLabelLinkRow] = [],
    studyPadEntries: [AndroidBookmarkStudyPadEntryRow] = [],
    studyPadTexts: [AndroidBookmarkStudyPadTextRow] = [],
    logEntries: [AndroidBookmarkLogEntryRow] = [],
    includeContentTypeColumns: Bool = true
) throws -> URL {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("android-bookmarks-\(UUID().uuidString).sqlite3")

    var db: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
        XCTFail("Failed to open temporary Android bookmark database")
        throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(db) }

    XCTAssertEqual(
        sqlite3_exec(
            db,
            """
            CREATE TABLE Label (
                id BLOB NOT NULL PRIMARY KEY,
                name TEXT NOT NULL,
                color INTEGER NOT NULL DEFAULT 0,
                markerStyle INTEGER NOT NULL DEFAULT 0,
                markerStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                underlineStyle INTEGER NOT NULL DEFAULT 0,
                underlineStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                hideStyle INTEGER NOT NULL DEFAULT 0,
                hideStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                favourite INTEGER NOT NULL DEFAULT 0,
                type TEXT DEFAULT NULL,
                customIcon TEXT DEFAULT NULL
            );
            CREATE TABLE BibleBookmark (
                kjvOrdinalStart INTEGER NOT NULL,
                kjvOrdinalEnd INTEGER NOT NULL,
                ordinalStart INTEGER NOT NULL,
                ordinalEnd INTEGER NOT NULL,
                v11n TEXT NOT NULL,
                playbackSettings TEXT DEFAULT NULL,
                id BLOB NOT NULL PRIMARY KEY,
                createdAt INTEGER NOT NULL,
                book TEXT DEFAULT NULL,
                startOffset INTEGER DEFAULT NULL,
                endOffset INTEGER DEFAULT NULL,
                primaryLabelId BLOB DEFAULT NULL,
                lastUpdatedOn INTEGER NOT NULL DEFAULT 0,
                wholeVerse INTEGER NOT NULL DEFAULT 0,
                type TEXT DEFAULT NULL,
                customIcon TEXT DEFAULT NULL,
                editAction_mode TEXT DEFAULT NULL,
                editAction_content TEXT DEFAULT NULL
            );
            CREATE TABLE BibleBookmarkNotes (
                bookmarkId BLOB NOT NULL PRIMARY KEY,
                notes TEXT NOT NULL\(includeContentTypeColumns ? "," : "")
                \(includeContentTypeColumns ? "contentType TEXT DEFAULT NULL" : "")
            );
            CREATE TABLE BibleBookmarkToLabel (
                bookmarkId BLOB NOT NULL,
                labelId BLOB NOT NULL,
                orderNumber INTEGER NOT NULL DEFAULT -1,
                indentLevel INTEGER NOT NULL DEFAULT 0,
                expandContent INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (bookmarkId, labelId)
            );
            CREATE TABLE GenericBookmark (
                id BLOB NOT NULL PRIMARY KEY,
                `key` TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                bookInitials TEXT NOT NULL DEFAULT '',
                ordinalStart INTEGER NOT NULL,
                ordinalEnd INTEGER NOT NULL,
                startOffset INTEGER DEFAULT NULL,
                endOffset INTEGER DEFAULT NULL,
                primaryLabelId BLOB DEFAULT NULL,
                lastUpdatedOn INTEGER NOT NULL DEFAULT 0,
                wholeVerse INTEGER NOT NULL DEFAULT 0,
                playbackSettings TEXT DEFAULT NULL,
                customIcon TEXT DEFAULT NULL,
                editAction_mode TEXT DEFAULT NULL,
                editAction_content TEXT DEFAULT NULL
            );
            CREATE TABLE GenericBookmarkNotes (
                bookmarkId BLOB NOT NULL PRIMARY KEY,
                notes TEXT NOT NULL\(includeContentTypeColumns ? "," : "")
                \(includeContentTypeColumns ? "contentType TEXT DEFAULT NULL" : "")
            );
            CREATE TABLE GenericBookmarkToLabel (
                bookmarkId BLOB NOT NULL,
                labelId BLOB NOT NULL,
                orderNumber INTEGER NOT NULL DEFAULT -1,
                indentLevel INTEGER NOT NULL DEFAULT 0,
                expandContent INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (bookmarkId, labelId)
            );
            CREATE TABLE StudyPadTextEntry (
                id BLOB NOT NULL PRIMARY KEY,
                labelId BLOB NOT NULL,
                orderNumber INTEGER NOT NULL,
                indentLevel INTEGER NOT NULL DEFAULT 0\(includeContentTypeColumns ? "," : "")
                \(includeContentTypeColumns ? "contentType TEXT DEFAULT NULL" : "")
            );
            CREATE TABLE StudyPadTextEntryText (
                studyPadTextEntryId BLOB NOT NULL PRIMARY KEY,
                text TEXT NOT NULL
            );
            CREATE TABLE LogEntry (
                tableName TEXT NOT NULL,
                entityId1 BLOB NOT NULL,
                entityId2 BLOB,
                type TEXT NOT NULL,
                lastUpdated INTEGER NOT NULL,
                sourceDevice TEXT NOT NULL,
                PRIMARY KEY (tableName, entityId1, entityId2)
            );
            """,
            nil,
            nil,
            nil
        ),
        SQLITE_OK
    )

    for label in labels {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "INSERT INTO Label (id, name, color, markerStyle, markerStyleWholeVerse, underlineStyle, underlineStyleWholeVerse, hideStyle, hideStyleWholeVerse, favourite, type, customIcon) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        bindUUIDBlob(label.id, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, label.name, -1, bookmarkSQLiteTransient)
        sqlite3_bind_int(statement, 3, Int32(label.colour))
        sqlite3_bind_int(statement, 4, label.markerStyle ? 1 : 0)
        sqlite3_bind_int(statement, 5, label.markerStyleWholeVerse ? 1 : 0)
        sqlite3_bind_int(statement, 6, label.underlineStyle ? 1 : 0)
        sqlite3_bind_int(statement, 7, label.underlineStyleWholeVerse ? 1 : 0)
        sqlite3_bind_int(statement, 8, label.hideStyle ? 1 : 0)
        sqlite3_bind_int(statement, 9, label.hideStyleWholeVerse ? 1 : 0)
        sqlite3_bind_int(statement, 10, label.favourite ? 1 : 0)
        bindOptionalText(label.type, to: statement, index: 11)
        bindOptionalText(label.customIcon, to: statement, index: 12)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    for bookmark in bibleBookmarks {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "INSERT INTO BibleBookmark (kjvOrdinalStart, kjvOrdinalEnd, ordinalStart, ordinalEnd, v11n, playbackSettings, id, createdAt, book, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, type, customIcon, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_bind_int(statement, 1, Int32(bookmark.kjvOrdinalStart))
        sqlite3_bind_int(statement, 2, Int32(bookmark.kjvOrdinalEnd))
        sqlite3_bind_int(statement, 3, Int32(bookmark.ordinalStart))
        sqlite3_bind_int(statement, 4, Int32(bookmark.ordinalEnd))
        sqlite3_bind_text(statement, 5, bookmark.v11n, -1, bookmarkSQLiteTransient)
        bindOptionalText(bookmark.playbackSettingsJSON, to: statement, index: 6)
        bindUUIDBlob(bookmark.id, to: statement, index: 7)
        sqlite3_bind_int64(statement, 8, Int64(bookmark.createdAt.timeIntervalSince1970 * 1000))
        bindOptionalText(bookmark.book, to: statement, index: 9)
        bindOptionalInt(bookmark.startOffset, to: statement, index: 10)
        bindOptionalInt(bookmark.endOffset, to: statement, index: 11)
        bindOptionalUUIDBlob(bookmark.primaryLabelID, to: statement, index: 12)
        sqlite3_bind_int64(statement, 13, Int64(bookmark.lastUpdatedOn.timeIntervalSince1970 * 1000))
        sqlite3_bind_int(statement, 14, bookmark.wholeVerse ? 1 : 0)
        bindOptionalText(bookmark.type, to: statement, index: 15)
        bindOptionalText(bookmark.customIcon, to: statement, index: 16)
        bindOptionalText(bookmark.editActionMode, to: statement, index: 17)
        bindOptionalText(bookmark.editActionContent, to: statement, index: 18)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    for note in bibleNotes {
        try insertBookmarkNote(
            note,
            tableName: "BibleBookmarkNotes",
            includeContentTypeColumn: includeContentTypeColumns,
            db: db
        )
    }

    for link in bibleLinks {
        try insertBookmarkLabelLink(link, tableName: "BibleBookmarkToLabel", db: db)
    }

    for bookmark in genericBookmarks {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "INSERT INTO GenericBookmark (id, `key`, createdAt, bookInitials, ordinalStart, ordinalEnd, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, playbackSettings, customIcon, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        bindUUIDBlob(bookmark.id, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, bookmark.key, -1, bookmarkSQLiteTransient)
        sqlite3_bind_int64(statement, 3, Int64(bookmark.createdAt.timeIntervalSince1970 * 1000))
        sqlite3_bind_text(statement, 4, bookmark.bookInitials, -1, bookmarkSQLiteTransient)
        sqlite3_bind_int(statement, 5, Int32(bookmark.ordinalStart))
        sqlite3_bind_int(statement, 6, Int32(bookmark.ordinalEnd))
        bindOptionalInt(bookmark.startOffset, to: statement, index: 7)
        bindOptionalInt(bookmark.endOffset, to: statement, index: 8)
        bindOptionalUUIDBlob(bookmark.primaryLabelID, to: statement, index: 9)
        sqlite3_bind_int64(statement, 10, Int64(bookmark.lastUpdatedOn.timeIntervalSince1970 * 1000))
        sqlite3_bind_int(statement, 11, bookmark.wholeVerse ? 1 : 0)
        bindOptionalText(bookmark.playbackSettingsJSON, to: statement, index: 12)
        bindOptionalText(bookmark.customIcon, to: statement, index: 13)
        bindOptionalText(bookmark.editActionMode, to: statement, index: 14)
        bindOptionalText(bookmark.editActionContent, to: statement, index: 15)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    for note in genericNotes {
        try insertBookmarkNote(
            note,
            tableName: "GenericBookmarkNotes",
            includeContentTypeColumn: includeContentTypeColumns,
            db: db
        )
    }

    for link in genericLinks {
        try insertBookmarkLabelLink(link, tableName: "GenericBookmarkToLabel", db: db)
    }

    for entry in studyPadEntries {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                includeContentTypeColumns
                    ? "INSERT INTO StudyPadTextEntry (id, labelId, orderNumber, indentLevel, contentType) VALUES (?, ?, ?, ?, ?)"
                    : "INSERT INTO StudyPadTextEntry (id, labelId, orderNumber, indentLevel) VALUES (?, ?, ?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        bindUUIDBlob(entry.id, to: statement, index: 1)
        bindUUIDBlob(entry.labelID, to: statement, index: 2)
        sqlite3_bind_int(statement, 3, Int32(entry.orderNumber))
        sqlite3_bind_int(statement, 4, Int32(entry.indentLevel))
        if includeContentTypeColumns {
            bindOptionalText(entry.contentType, to: statement, index: 5)
        }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    for text in studyPadTexts {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "INSERT INTO StudyPadTextEntryText (studyPadTextEntryId, text) VALUES (?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        bindUUIDBlob(text.entryID, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, text.text, -1, bookmarkSQLiteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    for entry in logEntries {
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                db,
                "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_bind_text(statement, 1, entry.tableName, -1, bookmarkSQLiteTransient)
        bindSQLiteValue(entry.entityID1, to: statement, index: 2)
        bindSQLiteValue(entry.entityID2, to: statement, index: 3)
        sqlite3_bind_text(statement, 4, entry.type.rawValue, -1, bookmarkSQLiteTransient)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        sqlite3_bind_text(statement, 6, entry.sourceDevice, -1, bookmarkSQLiteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    return databaseURL
}

private func insertBookmarkNote(
    _ note: AndroidBookmarkNoteRow,
    tableName: String,
    includeContentTypeColumn: Bool = true,
    db: OpaquePointer
) throws {
    var statement: OpaquePointer?
    XCTAssertEqual(
        sqlite3_prepare_v2(
            db,
            includeContentTypeColumn
                ? "INSERT INTO \(tableName) (bookmarkId, notes, contentType) VALUES (?, ?, ?)"
                : "INSERT INTO \(tableName) (bookmarkId, notes) VALUES (?, ?)",
            -1,
            &statement,
            nil
        ),
        SQLITE_OK
    )
    bindUUIDBlob(note.bookmarkID, to: statement, index: 1)
    sqlite3_bind_text(statement, 2, note.notes, -1, bookmarkSQLiteTransient)
    if includeContentTypeColumn {
        bindOptionalText(note.contentType, to: statement, index: 3)
    }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    sqlite3_finalize(statement)
}

private func insertBookmarkLabelLink(_ link: AndroidBookmarkLabelLinkRow, tableName: String, db: OpaquePointer) throws {
    var statement: OpaquePointer?
    XCTAssertEqual(
        sqlite3_prepare_v2(
            db,
            "INSERT INTO \(tableName) (bookmarkId, labelId, orderNumber, indentLevel, expandContent) VALUES (?, ?, ?, ?, ?)",
            -1,
            &statement,
            nil
        ),
        SQLITE_OK
    )
    bindUUIDBlob(link.bookmarkID, to: statement, index: 1)
    bindUUIDBlob(link.labelID, to: statement, index: 2)
    sqlite3_bind_int(statement, 3, Int32(link.orderNumber))
    sqlite3_bind_int(statement, 4, Int32(link.indentLevel))
    sqlite3_bind_int(statement, 5, link.expandContent ? 1 : 0)
    XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    sqlite3_finalize(statement)
}

private func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
    let blob = bookmarkUUIDBlob(uuid)
    _ = blob.withUnsafeBytes { bytes in
        sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(blob.count), bookmarkSQLiteTransient)
    }
}

private func bindOptionalUUIDBlob(_ uuid: UUID?, to statement: OpaquePointer?, index: Int32) {
    guard let uuid else {
        sqlite3_bind_null(statement, index)
        return
    }
    bindUUIDBlob(uuid, to: statement, index: index)
}

private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_text(statement, index, value, -1, bookmarkSQLiteTransient)
}

private func bindOptionalInt(_ value: Int?, to statement: OpaquePointer?, index: Int32) {
    guard let value else {
        sqlite3_bind_null(statement, index)
        return
    }
    sqlite3_bind_int(statement, index, Int32(value))
}

/**
 Binds one typed Android SQLite scalar into a fixture statement.

 - Parameters:
   - value: Typed scalar payload that should be bound into SQLite.
   - statement: SQLite statement receiving the bound parameter.
   - index: One-based parameter index.
 - Side effects:
   - mutates the bound SQLite statement parameter state
 - Failure modes: This helper cannot fail.
 */
private func bindSQLiteValue(_ value: RemoteSyncSQLiteValue, to statement: OpaquePointer?, index: Int32) {
    switch value.kind {
    case .null:
        sqlite3_bind_null(statement, index)
    case .integer:
        sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
    case .real:
        sqlite3_bind_double(statement, index, value.realValue ?? 0)
    case .text:
        sqlite3_bind_text(statement, index, value.textValue ?? "", -1, bookmarkSQLiteTransient)
    case .blob:
        let data = value.blobData ?? Data()
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), bookmarkSQLiteTransient)
        }
    }
}

func bookmarkUUIDBlob(_ uuid: UUID) -> Data {
    let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
    var bytes = Data()
    bytes.reserveCapacity(16)

    var index = hex.startIndex
    while index < hex.endIndex {
        let nextIndex = hex.index(index, offsetBy: 2)
        let byteString = hex[index..<nextIndex]
        bytes.append(UInt8(byteString, radix: 16)!)
        index = nextIndex
    }
    return bytes
}
