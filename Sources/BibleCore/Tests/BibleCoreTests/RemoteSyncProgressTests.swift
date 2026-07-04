import Foundation
import SQLite3
import XCTest
@testable import BibleCore

private let progressSyncTestSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class RemoteSyncProgressTests: XCTestCase {
    func testProgressPatchUploadWritesSparseAndroidPatchAndRefreshesBaseline() async throws {
        let settingsStore = try makeInMemorySettingsStore()
        let memorizedID = UUID(uuidString: "15000000-0000-0000-0000-000000001001")!
        let historyID = UUID(uuidString: "15000000-0000-0000-0000-000000001002")!
        let targetID = UUID(uuidString: "15000000-0000-0000-0000-000000001003")!
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [
                .init(id: memorizedID, kjvOrdinal: 15, memorizedAt: 1_700_000_100),
            ],
            chapterHistory: [
                .init(
                    id: historyID,
                    kjvBookOrdinal: 1,
                    chapter: 1,
                    cycle: 2,
                    readAt: 1_700_000_200,
                    bookInitials: "",
                    source: .manual
                ),
            ],
            targets: [
                .init(id: targetID, kjvOrdinalStart: 20, kjvOrdinalEnd: 22, createdAt: 1_700_000_300),
            ],
            settings: ReadingProgressSettingsSnapshot(autoTrackReading: true, activeCycle: 2)
        )
        let adapter = RemoteSyncMockAdapter()
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/progress/device-ios/1.9.sqlite3.gz",
                name: "1.9.sqlite3.gz",
                size: 0,
                timestamp: 2_000,
                parentID: "/progress/device-ios",
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let service = RemoteSyncProgressPatchUploadService(
            adapter: adapter,
            nowProvider: { 1_800_000_000 }
        )

        let report = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-ios"),
            settingsStore: settingsStore
        )

        let uploadReport = try XCTUnwrap(report)
        XCTAssertEqual(uploadReport.patchNumber, 1)
        XCTAssertEqual(uploadReport.upsertedMemorizedVerseCount, 1)
        XCTAssertEqual(uploadReport.upsertedChapterHistoryCount, 1)
        XCTAssertEqual(uploadReport.upsertedTargetCount, 1)
        XCTAssertEqual(uploadReport.upsertedSettingsCount, 1)
        XCTAssertEqual(uploadReport.deletedRowCount, 0)
        XCTAssertEqual(uploadReport.logEntryCount, 4)

        let uploadedFiles = await adapter.uploadedFilesSnapshot()
        let uploaded = try XCTUnwrap(uploadedFiles.first)
        XCTAssertEqual(uploaded.name, "1.9.sqlite3.gz")
        XCTAssertEqual(uploaded.parentID, "/progress/device-ios")
        let patchDatabaseURL = try materializeProgressArchive(uploaded.data)
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM MemorizedVerse WHERE id = x'\(hex(memorizedID))';", at: patchDatabaseURL), 1)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM ChapterReadHistory WHERE id = x'\(hex(historyID))';", at: patchDatabaseURL), 1)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM MemorizationTarget WHERE id = x'\(hex(targetID))';", at: patchDatabaseURL), 1)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM GlobalReadingProgressSettings;", at: patchDatabaseURL), 1)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM LogEntry;", at: patchDatabaseURL), 4)

        let secondReport = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-ios"),
            settingsStore: settingsStore
        )
        XCTAssertNil(secondReport)
        let uploadedFilesAfterSecondRun = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(uploadedFilesAfterSecondRun.count, 1)

        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot(autoTrackReading: true, activeCycle: 2)
        )
        await adapter.enqueueUploadResult(
            RemoteSyncFile(
                id: "/progress/device-ios/2.9.sqlite3.gz",
                name: "2.9.sqlite3.gz",
                size: 0,
                timestamp: 3_000,
                parentID: "/progress/device-ios",
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        )

        let deleteReport = try await service.uploadPendingPatch(
            bootstrapState: RemoteSyncBootstrapState(deviceFolderID: "/progress/device-ios"),
            settingsStore: settingsStore
        )

        let deleteUploadReport = try XCTUnwrap(deleteReport)
        XCTAssertEqual(deleteUploadReport.patchNumber, 2)
        XCTAssertEqual(deleteUploadReport.upsertedMemorizedVerseCount, 0)
        XCTAssertEqual(deleteUploadReport.upsertedChapterHistoryCount, 0)
        XCTAssertEqual(deleteUploadReport.upsertedTargetCount, 0)
        XCTAssertEqual(deleteUploadReport.upsertedSettingsCount, 0)
        XCTAssertEqual(deleteUploadReport.deletedRowCount, 3)
        XCTAssertEqual(deleteUploadReport.logEntryCount, 3)

        let uploadedFilesAfterDelete = await adapter.uploadedFilesSnapshot()
        XCTAssertEqual(uploadedFilesAfterDelete.count, 2)
        let deleteUpload = try XCTUnwrap(uploadedFilesAfterDelete.last)
        XCTAssertEqual(deleteUpload.name, "2.9.sqlite3.gz")
        let deletePatchDatabaseURL = try materializeProgressArchive(deleteUpload.data)
        defer { try? FileManager.default.removeItem(at: deletePatchDatabaseURL) }
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM MemorizedVerse;", at: deletePatchDatabaseURL), 0)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM ChapterReadHistory;", at: deletePatchDatabaseURL), 0)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM MemorizationTarget;", at: deletePatchDatabaseURL), 0)
        XCTAssertEqual(try progressSQLiteInteger("SELECT COUNT(*) FROM LogEntry WHERE type = 'DELETE';", at: deletePatchDatabaseURL), 3)
    }

    func testProgressPatchApplyReplaysNewerRowsAndDeletesByAndroidLogEntry() throws {
        let settingsStore = try makeInMemorySettingsStore()
        let deletedID = UUID(uuidString: "15000000-0000-0000-0000-000000002001")!
        let insertedID = UUID(uuidString: "15000000-0000-0000-0000-000000002002")!
        let historyID = UUID(uuidString: "15000000-0000-0000-0000-000000002003")!
        seedProgress(
            settingsStore: settingsStore,
            memorizedVerses: [
                .init(id: deletedID, kjvOrdinal: 15, memorizedAt: 100),
            ],
            chapterHistory: [],
            targets: [],
            settings: ReadingProgressSettingsSnapshot()
        )
        let patchDatabaseURL = try makeProgressPatchDatabase(
            memorizedVerses: [
                .init(id: insertedID, kjvOrdinal: 16, memorizedAt: 300),
            ],
            chapterHistory: [
                .init(
                    id: historyID,
                    kjvBookOrdinal: 1,
                    chapter: 2,
                    cycle: 1,
                    readAt: 400,
                    bookInitials: "",
                    source: .autoTts
                ),
            ],
            targets: [],
            settings: ReadingProgressSettingsSnapshot(autoTrackReading: true, activeCycle: 4),
            logEntries: [
                .init(
                    tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
                    entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(deletedID)),
                    entityID2: .text(""),
                    type: .delete,
                    lastUpdated: 500,
                    sourceDevice: "android"
                ),
                .init(
                    tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
                    entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(insertedID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 501,
                    sourceDevice: "android"
                ),
                .init(
                    tableName: RemoteSyncProgressSnapshotService.chapterReadHistoryTable,
                    entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(historyID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 502,
                    sourceDevice: "android"
                ),
                .init(
                    tableName: RemoteSyncProgressSnapshotService.globalSettingsTable,
                    entityID1: .blob(RemoteSyncProgressSnapshotService.uuidBlob(RemoteSyncProgressSnapshotService.globalSettingsID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: 503,
                    sourceDevice: "android"
                ),
            ]
        )
        defer { try? FileManager.default.removeItem(at: patchDatabaseURL) }
        let stagedArchive = try makeProgressPatchArchive(
            patchDatabaseURL: patchDatabaseURL,
            sourceDevice: "android",
            patchNumber: 1,
            fileTimestamp: 900
        )
        defer { try? FileManager.default.removeItem(at: stagedArchive.archiveFileURL) }

        let report = try RemoteSyncProgressPatchApplyService().applyPatchArchives(
            [stagedArchive],
            settingsStore: settingsStore
        )

        XCTAssertEqual(report.appliedPatchCount, 1)
        XCTAssertEqual(report.appliedLogEntryCount, 4)
        XCTAssertEqual(report.skippedLogEntryCount, 0)
        XCTAssertEqual(report.readingCount, 1)
        XCTAssertEqual(report.memorizedVerseCount, 1)
        XCTAssertEqual(report.targetCount, 0)
        let memorizationSnapshot = MemorizationProgressStore(settingsStore: settingsStore).snapshot()
        XCTAssertEqual(memorizationSnapshot.memorizedVerses.map(\.id), [insertedID])
        XCTAssertEqual(memorizationSnapshot.memorizedVerses.map(\.kjvOrdinal), [16])
        let readingSnapshot = ReadingProgressStore(settingsStore: settingsStore).snapshot()
        XCTAssertEqual(readingSnapshot.history.map(\.id), [historyID])
        XCTAssertEqual(readingSnapshot.history.first?.source, .autoTts)
        XCTAssertTrue(readingSnapshot.settings.autoTrackReading)
        XCTAssertEqual(readingSnapshot.settings.activeCycle, 4)
        XCTAssertEqual(RemoteSyncPatchStatusStore(settingsStore: settingsStore).statuses(for: .progress).map(\.patchNumber), [1])
        XCTAssertEqual(RemoteSyncLogEntryStore(settingsStore: settingsStore).entries(for: .progress).count, 4)
    }
}

private struct ProgressMemorizedVerseFixture {
    let id: UUID
    let kjvOrdinal: Int
    let memorizedAt: Int64
}

private struct ProgressChapterReadHistoryFixture {
    let id: UUID
    let kjvBookOrdinal: Int
    let chapter: Int
    let cycle: Int
    let readAt: Int64
    let bookInitials: String
    let source: ReadingProgressSource
}

private struct ProgressTargetFixture {
    let id: UUID
    let kjvOrdinalStart: Int
    let kjvOrdinalEnd: Int
    let createdAt: Int64
}

private func seedProgress(
    settingsStore: SettingsStore,
    memorizedVerses: [ProgressMemorizedVerseFixture],
    chapterHistory: [ProgressChapterReadHistoryFixture],
    targets: [ProgressTargetFixture],
    settings: ReadingProgressSettingsSnapshot
) {
    let readingSnapshot = ReadingProgressSnapshot(
        history: chapterHistory.map {
            ReadingProgressHistoryRow(
                id: $0.id,
                bookInitials: $0.bookInitials,
                startOrdinal: 0,
                kjvBookOrdinal: $0.kjvBookOrdinal,
                chapter: $0.chapter,
                cycle: $0.cycle,
                readAt: $0.readAt,
                source: $0.source
            )
        },
        settings: settings
    )
    let memorizationSnapshot = MemorizationProgressSnapshot(
        memorizedVerses: memorizedVerses.map {
            MemorizedVerseProgress(id: $0.id, kjvOrdinal: $0.kjvOrdinal, memorizedAt: $0.memorizedAt)
        },
        targetRows: targets.map {
            MemorizationTargetRow(
                id: $0.id,
                startOrdinal: $0.kjvOrdinalStart,
                endOrdinal: $0.kjvOrdinalEnd,
                createdAt: $0.createdAt
            )
        }
    )
    let encoder = JSONEncoder()
    settingsStore.setString(
        ReadingProgressStore.settingsKey,
        value: String(data: try! encoder.encode(readingSnapshot), encoding: .utf8)!
    )
    settingsStore.setString(
        MemorizationProgressStore.settingsKey,
        value: String(data: try! encoder.encode(memorizationSnapshot), encoding: .utf8)!
    )
}

private func makeProgressPatchDatabase(
    memorizedVerses: [ProgressMemorizedVerseFixture],
    chapterHistory: [ProgressChapterReadHistoryFixture],
    targets: [ProgressTargetFixture],
    settings: ReadingProgressSettingsSnapshot,
    logEntries: [RemoteSyncLogEntry]
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-sync-progress-test-\(UUID().uuidString).sqlite3")
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(db) }

    XCTAssertEqual(sqlite3_exec(db, progressSchemaSQL, nil, nil, nil), SQLITE_OK)
    for row in memorizedVerses {
        let statement = try progressPrepare(
            "INSERT INTO MemorizedVerse (id, kjvOrdinal, memorizedAt) VALUES (?, ?, ?);",
            db
        )
        bindProgressUUID(row.id, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(row.kjvOrdinal))
        sqlite3_bind_int64(statement, 3, row.memorizedAt)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }
    for row in chapterHistory {
        let statement = try progressPrepare(
            """
            INSERT INTO ChapterReadHistory (id, kjvBookOrdinal, chapter, cycle, readAt, bookInitials, source)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            db
        )
        bindProgressUUID(row.id, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(row.kjvBookOrdinal))
        sqlite3_bind_int(statement, 3, Int32(row.chapter))
        sqlite3_bind_int(statement, 4, Int32(row.cycle))
        sqlite3_bind_int64(statement, 5, row.readAt)
        sqlite3_bind_text(statement, 6, row.bookInitials, -1, progressSyncTestSQLiteTransient)
        sqlite3_bind_text(statement, 7, row.source.rawValue, -1, progressSyncTestSQLiteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }
    for row in targets {
        let statement = try progressPrepare(
            "INSERT INTO MemorizationTarget (id, kjvOrdinalStart, kjvOrdinalEnd, createdAt) VALUES (?, ?, ?, ?);",
            db
        )
        bindProgressUUID(row.id, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(row.kjvOrdinalStart))
        sqlite3_bind_int(statement, 3, Int32(row.kjvOrdinalEnd))
        sqlite3_bind_int64(statement, 4, row.createdAt)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }
    let settingsRow = RemoteSyncCurrentProgressSettingsRow(
        id: RemoteSyncProgressSnapshotService.globalSettingsID,
        settings: settings
    )
    let settingsStatement = try progressPrepare(
        """
        INSERT INTO GlobalReadingProgressSettings (
            id, autoTrackReading, autoMarkMemorized, memorizeTypeFullWords, memorizeWordVisibility,
            memorizeErrorHeatmap, memorizeScrambleHideUsed, memorizeIncludeReference, activeCycle
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """,
        db
    )
    bindProgressUUID(settingsRow.id, to: settingsStatement, index: 1)
    sqlite3_bind_int(settingsStatement, 2, settingsRow.autoTrackReading ? 1 : 0)
    sqlite3_bind_int(settingsStatement, 3, settingsRow.autoMarkMemorized ? 1 : 0)
    sqlite3_bind_int(settingsStatement, 4, settingsRow.memorizeTypeFullWords ? 1 : 0)
    sqlite3_bind_text(settingsStatement, 5, settingsRow.memorizeWordVisibility, -1, progressSyncTestSQLiteTransient)
    sqlite3_bind_int(settingsStatement, 6, settingsRow.memorizeErrorHeatmap ? 1 : 0)
    sqlite3_bind_int(settingsStatement, 7, settingsRow.memorizeScrambleHideUsed ? 1 : 0)
    sqlite3_bind_int(settingsStatement, 8, settingsRow.memorizeIncludeReference ? 1 : 0)
    sqlite3_bind_int(settingsStatement, 9, Int32(settingsRow.activeCycle))
    XCTAssertEqual(sqlite3_step(settingsStatement), SQLITE_DONE)
    sqlite3_finalize(settingsStatement)

    for entry in logEntries {
        let statement = try progressPrepare(
            "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?);",
            db
        )
        sqlite3_bind_text(statement, 1, entry.tableName, -1, progressSyncTestSQLiteTransient)
        bindProgressSQLiteValue(entry.entityID1, to: statement, index: 2)
        bindProgressSQLiteValue(entry.entityID2, to: statement, index: 3)
        sqlite3_bind_text(statement, 4, entry.type.rawValue, -1, progressSyncTestSQLiteTransient)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        sqlite3_bind_text(statement, 6, entry.sourceDevice, -1, progressSyncTestSQLiteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
    }

    return url
}

private func makeProgressPatchArchive(
    patchDatabaseURL: URL,
    sourceDevice: String,
    patchNumber: Int64,
    fileTimestamp: Int64
) throws -> RemoteSyncStagedPatchArchive {
    let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: patchDatabaseURL))
    let archiveURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-sync-progress-test-\(UUID().uuidString).sqlite3.gz")
    try archiveData.write(to: archiveURL, options: .atomic)
    return RemoteSyncStagedPatchArchive(
        patch: RemoteSyncDiscoveredPatch(
            sourceDevice: sourceDevice,
            patchNumber: patchNumber,
            schemaVersion: 9,
            file: RemoteSyncFile(
                id: "/progress/\(sourceDevice)/\(patchNumber).9.sqlite3.gz",
                name: "\(patchNumber).9.sqlite3.gz",
                size: Int64(archiveData.count),
                timestamp: fileTimestamp,
                parentID: "/progress/\(sourceDevice)",
                mimeType: NextCloudSyncAdapter.gzipMimeType
            )
        ),
        archiveFileURL: archiveURL
    )
}

private func materializeProgressArchive(_ data: Data) throws -> URL {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("remote-sync-progress-upload-\(UUID().uuidString).sqlite3")
    try gunzipTestData(data).write(to: databaseURL, options: .atomic)
    return databaseURL
}

private func progressSQLiteInteger(_ sql: String, at url: URL) throws -> Int {
    var db: OpaquePointer?
    guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
        throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
    }
    defer { sqlite3_close(db) }
    let statement = try progressPrepare(sql, db)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
    }
    return Int(sqlite3_column_int(statement, 0))
}

private func progressPrepare(_ sql: String, _ database: OpaquePointer) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
        throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
    }
    return statement
}

private func bindProgressUUID(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
    let data = RemoteSyncProgressSnapshotService.uuidBlob(uuid)
    _ = data.withUnsafeBytes {
        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), progressSyncTestSQLiteTransient)
    }
}

private func bindProgressSQLiteValue(_ value: RemoteSyncSQLiteValue, to statement: OpaquePointer?, index: Int32) {
    switch value.kind {
    case .null:
        sqlite3_bind_null(statement, index)
    case .integer:
        sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
    case .real:
        sqlite3_bind_double(statement, index, value.realValue ?? 0)
    case .text:
        sqlite3_bind_text(statement, index, value.textValue ?? "", -1, progressSyncTestSQLiteTransient)
    case .blob:
        let data = value.blobData ?? Data()
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), progressSyncTestSQLiteTransient)
        }
    }
}

private func hex(_ uuid: UUID) -> String {
    RemoteSyncProgressSnapshotService.uuidBlob(uuid).map { String(format: "%02x", $0) }.joined()
}

private let progressSchemaSQL = """
CREATE TABLE MemorizedVerse (
    id BLOB NOT NULL PRIMARY KEY,
    kjvOrdinal INTEGER NOT NULL,
    memorizedAt INTEGER NOT NULL
);
CREATE UNIQUE INDEX index_MemorizedVerse_kjvOrdinal ON MemorizedVerse (kjvOrdinal);
CREATE TABLE MemorizationTarget (
    id BLOB NOT NULL PRIMARY KEY,
    kjvOrdinalStart INTEGER NOT NULL,
    kjvOrdinalEnd INTEGER NOT NULL,
    createdAt INTEGER NOT NULL
);
CREATE TABLE ChapterReadHistory (
    id BLOB NOT NULL PRIMARY KEY,
    kjvBookOrdinal INTEGER NOT NULL,
    chapter INTEGER NOT NULL,
    cycle INTEGER NOT NULL DEFAULT 1,
    readAt INTEGER NOT NULL,
    bookInitials TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT 'MANUAL'
);
CREATE TABLE GlobalReadingProgressSettings (
    id BLOB NOT NULL PRIMARY KEY,
    autoTrackReading INTEGER NOT NULL DEFAULT 0,
    autoMarkMemorized INTEGER NOT NULL DEFAULT 1,
    memorizeTypeFullWords INTEGER NOT NULL DEFAULT 0,
    memorizeWordVisibility TEXT NOT NULL DEFAULT 'light',
    memorizeErrorHeatmap INTEGER NOT NULL DEFAULT 1,
    memorizeScrambleHideUsed INTEGER NOT NULL DEFAULT 0,
    memorizeIncludeReference INTEGER NOT NULL DEFAULT 1,
    activeCycle INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE LogEntry (
    tableName TEXT NOT NULL,
    entityId1 BLOB,
    entityId2 BLOB,
    type TEXT NOT NULL,
    lastUpdated INTEGER NOT NULL,
    sourceDevice TEXT NOT NULL
);
PRAGMA user_version = 9;
"""
