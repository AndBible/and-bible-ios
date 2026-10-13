import XCTest
import SwiftData
import SQLite3
@testable import BibleCore

/**
 Exercises real historical Room layouts through the manual restore/import boundary and re-export.
 Literal fixture contents make missing notes, label relationships, or StudyPad ordering observable.
 */
@MainActor
final class AndroidBookmarkMigrationTests: XCTestCase {
    private let bibleID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private let genericID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    private let padID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!

    /// Every exported Android generation must survive restore and a second import without data loss.
    func testHistoricalBackupsPreserveStudyDataThroughRestoreAndImport() throws {
        for version in 1...12 {
            try XCTContext.runActivity(named: "Android bookmark schema \(version)") { _ in
                let databaseURL = try fixture(version)
                defer { try? FileManager.default.removeItem(at: databaseURL) }
                let originalBytes = try Data(contentsOf: databaseURL)
                let container = try makeBookmarkRestoreModelContainer()
                let context = ModelContext(container)
                let settings = SettingsStore(modelContext: context)
                let archive = AndroidDatabaseBackupArchive(
                    manifest: nil,
                    sections: [.init(category: .bookmarks, fileName: "bookmarks.sqlite3",
                                     databaseFileURL: databaseURL, databaseVersion: version,
                                     declaredInManifest: true, support: .supported)],
                    temporaryDirectory: databaseURL.deletingLastPathComponent()
                )
                let service = AndroidDatabaseBackupService()
                for mode in [AndroidDatabaseBackupApplyMode.restore, .import] {
                    // Re-import the original historical database, not the already migrated staging file.
                    if mode == .import {
                        try originalBytes.write(to: databaseURL)
                        let localBible = try XCTUnwrap(context.fetch(FetchDescriptor<BibleBookmark>()).first)
                        localBible.notes?.notes = "Edited locally"
                        let localPad = try XCTUnwrap(context.fetch(FetchDescriptor<StudyPadTextEntry>()).first)
                        localPad.textEntry?.text = "Edited StudyPad locally"
                        let localLabel = try XCTUnwrap(context.fetch(FetchDescriptor<Label>()).first { $0.name == "Personal study" })
                        localLabel.name = "Local label name"
                        try context.save()
                    }
                    _ = try service.apply(archive: archive, selections: [.init(category: .bookmarks, mode: mode)],
                                          modelContext: context, settingsStore: settings)
                    let exported = try RemoteSyncInitialBackupUploadService.buildAndroidDatabaseBackupDatabase(
                        for: .bookmarks, modelContext: context, settingsStore: settings, schemaVersion: 12
                    )
                    defer { try? FileManager.default.removeItem(at: exported) }
                    let snapshot = try RemoteSyncBookmarkRestoreService().readSnapshot(from: exported)
                    let bible = try XCTUnwrap(snapshot.bibleBookmarks.first { $0.id == bibleID })
                    XCTAssertEqual(snapshot.bibleBookmarks.count, 1)
                    XCTAssertEqual(bible.notes, mode == .restore ? "My Bible note — preserved" : "Edited locally")
                    XCTAssertEqual(bible.kjvOrdinalStart, 4)
                    XCTAssertEqual(bible.kjvOrdinalEnd, 5)
                    XCTAssertEqual(bible.startOffset, 2)
                    XCTAssertEqual(bible.endOffset, 8)
                    XCTAssertEqual(bible.primaryLabelID, AndroidBookmarkDatabaseContract.speakLabelID)
                    XCTAssertEqual(bible.labelLinks.count, 2)
                    let userLink = try XCTUnwrap(bible.labelLinks.first { $0.orderNumber == 7 })
                    XCTAssertEqual(userLink.indentLevel, 2)
                    XCTAssertTrue(userLink.expandContent)
                    XCTAssertEqual(snapshot.labels.first { $0.id == userLink.labelID }?.name, mode == .restore ? "Personal study" : "Local label name")
                    XCTAssertEqual(snapshot.labels.filter { $0.name == "__SPEAK_LABEL__" }.count, 1)
                    let pad = try XCTUnwrap(snapshot.studyPadEntries.first { $0.id == padID })
                    XCTAssertEqual(pad.labelID, AndroidBookmarkDatabaseContract.speakLabelID)
                    XCTAssertEqual(pad.text, mode == .restore ? "StudyPad text — preserved" : "Edited StudyPad locally")
                    XCTAssertEqual(pad.orderNumber, 12)
                    XCTAssertEqual(pad.indentLevel, 3)
                    XCTAssertEqual(snapshot.genericBookmarks.count, version >= 3 ? 1 : 0)
                    if version >= 3 {
                        let generic = try XCTUnwrap(snapshot.genericBookmarks.first { $0.id == genericID })
                        XCTAssertEqual(generic.notes, "My commentary note")
                        XCTAssertEqual(generic.bookInitials, "Westminster21")
                        XCTAssertEqual(generic.key, "/WCF/Ch 6")
                        XCTAssertEqual(generic.ordinalStart, 2)
                        XCTAssertEqual(generic.ordinalEnd, 4)
                        XCTAssertEqual(generic.primaryLabelID, AndroidBookmarkDatabaseContract.speakLabelID)
                        XCTAssertEqual(generic.labelLinks.first?.orderNumber, 10)
                    }
                }
            }
        }
    }

    /// Canonical label metadata and colliding junctions win, exactly as Android INSERT OR IGNORE.
    func testSpecialLabelMergePreservesCanonicalRowsAndAllReferences() throws {
        let url = try fixture(11)
        defer { try? FileManager.default.removeItem(at: url) }
        try sql("""
            INSERT INTO Label(id,name,color) VALUES(X'000000000000ab1e00005bea400001a1','__SPEAK_LABEL__',456);
            INSERT INTO BibleBookmarkToLabel(bookmarkId,labelId,orderNumber,indentLevel,expandContent)
              VALUES(X'30000000000000000000000000000001',X'000000000000ab1e00005bea400001a1',42,4,0);
            """, at: url)
        let snapshot = try RemoteSyncBookmarkRestoreService().readSnapshot(from: url)
        XCTAssertEqual(snapshot.labels.first { $0.name == "__SPEAK_LABEL__" }?.color, 456)
        let link = try XCTUnwrap(snapshot.bibleBookmarks.first?.labelLinks.first { $0.labelID == AndroidBookmarkDatabaseContract.speakLabelID })
        XCTAssertEqual(link.orderNumber, 42)
        XCTAssertEqual(link.indentLevel, 4)
        XCTAssertFalse(link.expandContent)
        XCTAssertEqual(snapshot.genericBookmarks.first?.primaryLabelID, AndroidBookmarkDatabaseContract.speakLabelID)
        XCTAssertEqual(snapshot.studyPadEntries.first?.labelID, AndroidBookmarkDatabaseContract.speakLabelID)
        XCTAssertEqual(try scalar("SELECT count(*) FROM pragma_foreign_key_check", at: url), "0")
        let bytes = try Data(contentsOf: url)
        _ = try RemoteSyncBookmarkRestoreService().readSnapshot(from: url)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "A completed migration must not run again")
    }

    /// All three Android special labels merge; equally named ordinary labels remain distinct.
    func testOnlyAndroidSpecialLabelNamesAreMerged() throws {
        for (name, canonical) in [
            ("__UNLABELED__", AndroidBookmarkDatabaseContract.unlabeledLabelID),
            ("__PARAGRAPH_BREAK_LABEL__", AndroidBookmarkDatabaseContract.paragraphBreakLabelID),
            ("Ordinary duplicate name", UUID(uuidString: "20000000-0000-0000-0000-000000000001")!),
        ] {
            let url = try fixture(11)
            defer { try? FileManager.default.removeItem(at: url) }
            try sql("UPDATE Label SET name = '\(name)' WHERE name = '__SPEAK_LABEL__'", at: url)
            let snapshot = try RemoteSyncBookmarkRestoreService().readSnapshot(from: url)
            let isSpecial = name.hasPrefix("__")
            XCTAssertEqual(snapshot.labels.filter { $0.name == name }.count, isSpecial ? 1 : 2)
            XCTAssertEqual(snapshot.bibleBookmarks.first?.primaryLabelID, canonical)
            if isSpecial {
                XCTAssertEqual(snapshot.studyPadEntries.first?.labelID, canonical)
                XCTAssertEqual(snapshot.genericBookmarks.first?.labelLinks.first?.labelID, canonical)
            }
        }
    }

    /// Schema/data reshaping must not manufacture user edits in Android's synchronization journal.
    func testMigrationDisablesSyncTriggersAndPreservesHistoricalLogEntries() throws {
        let url = try fixture(3)
        defer { try? FileManager.default.removeItem(at: url) }
        try sql("""
            CREATE TRIGGER fixtureGenericUpdate AFTER UPDATE ON GenericBookmark
            WHEN NOT EXISTS(SELECT 1 FROM SyncConfiguration WHERE keyName='triggersDisabled' AND booleanValue=1)
            BEGIN
              INSERT OR REPLACE INTO LogEntry(tableName,entityId1,entityId2,type,lastUpdated,sourceDevice)
              VALUES('GenericBookmark',NEW.id,'','UPSERT',1900000000000,'unexpected-migration-edit');
            END;
            """, at: url)
        let snapshot = try RemoteSyncBookmarkRestoreService().readSnapshot(from: url)
        XCTAssertEqual(snapshot.logEntries.count, 1)
        XCTAssertEqual(snapshot.logEntries.first?.sourceDevice, "android")
        XCTAssertEqual(try scalar("SELECT count(*) FROM SyncConfiguration WHERE keyName='triggersDisabled'", at: url), "0")
    }

    /// A late SQL failure rolls back early note extraction and leaves the user's local data intact.
    func testFailedMigrationRollsBackStagingAndPreservesLocalData() throws {
        let url = try fixture(1)
        defer { try? FileManager.default.removeItem(at: url) }
        try sql("ALTER TABLE Label ADD COLUMN customIcon TEXT", at: url)
        let container = try makeBookmarkRestoreModelContainer()
        let context = ModelContext(container)
        let localLabel = Label(name: "Keep my study")
        context.insert(localLabel)
        try context.save()
        let service = RemoteSyncBookmarkRestoreService()
        XCTAssertThrowsError(try service.replaceLocalBookmarks(
            from: service.readSnapshot(from: url), modelContext: context,
            settingsStore: SettingsStore(modelContext: context)
        )) { error in
            guard case RemoteSyncBookmarkDatabaseMigrationError.migrationFailed(from: 8, to: 9, reason: _) = error else {
                return XCTFail("Unexpected failure: \(error)")
            }
        }
        XCTAssertEqual(try scalar("PRAGMA user_version", at: url), "1")
        XCTAssertEqual(try scalar("SELECT notes FROM Bookmark", at: url), "My Bible note — preserved")
        XCTAssertEqual(try scalar("SELECT text FROM StudyPadTextEntry", at: url), "StudyPad text — preserved")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Label>()).map(\.name), ["Keep my study"])
    }

    /// Unknown versions fail before any schema writes; no guessing a version from available columns.
    func testUnknownVersionsAreRejectedWithoutMutation() throws {
        for version in [0, 13] {
            let url = try fixture(12)
            defer { try? FileManager.default.removeItem(at: url) }
            try sql("PRAGMA user_version = \(version)", at: url)
            let bytes = try Data(contentsOf: url)
            XCTAssertThrowsError(try RemoteSyncBookmarkRestoreService().readSnapshot(from: url)) { error in
                XCTAssertEqual(error as? RemoteSyncBookmarkDatabaseMigrationError, .unsupportedSourceVersion(version))
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    /// Initial sync must read renamed log entries after migrating the content schema.
    func testInitialSyncMigratesBeforeReadingItsLog() throws {
        let url = try fixture(1)
        defer { try? FileManager.default.removeItem(at: url) }
        let container = try makeBookmarkRestoreModelContainer()
        let context = ModelContext(container)
        let settings = SettingsStore(modelContext: context)
        let backup = RemoteSyncStagedInitialBackup(
            remoteFile: .init(id: "initial", name: "initial.sqlite3.gz", size: 2048,
                              timestamp: 1700000001000, parentID: "bookmarks", mimeType: "application/gzip"),
            databaseFileURL: url, schemaVersion: 1
        )
        _ = try RemoteSyncInitialBackupRestoreService().restoreInitialBackup(
            backup, category: .bookmarks, modelContext: context, settingsStore: settings
        )
        let entries = RemoteSyncLogEntryStore(settingsStore: settings).entries(for: .bookmarks)
        XCTAssertEqual(entries.map(\.tableName), ["BibleBookmark"])
        XCTAssertEqual(entries.first?.lastUpdated, 1700000001000)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BibleBookmark>()).first?.notes?.notes, "My Bible note — preserved")
    }

    /// Executes a fixture mutation, surfacing SQLite failures rather than continuing with partial data.
    private func sql(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "FixtureSQL", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    /// Reads an independent SQL assertion from the staged database, including after rollback.
    private func scalar(_ sql: String, at url: URL) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase }
        return String(cString: value)
    }

    /// Creates an isolated writable staged database using Android's exported DDL and literal data.
    private func fixture(_ version: Int) throws -> URL {
        let resource = try XCTUnwrap(Bundle.module.url(forResource: String(version), withExtension: "sql", subdirectory: "bookmark-history"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bookmark-history-\(UUID()).sqlite3")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase }
        defer { sqlite3_close(db) }
        let sql = try String(contentsOf: resource, encoding: .utf8)
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            XCTFail(String(cString: sqlite3_errmsg(db)))
            throw RemoteSyncBookmarkRestoreError.invalidSQLiteDatabase
        }
        return url
    }
}
