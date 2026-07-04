// RemoteSyncProgressPatchUploadService.swift - Android-shaped outbound progress patch creation

import Foundation
import SQLite3

private let remoteSyncProgressPatchUploadSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum RemoteSyncProgressPatchUploadError: Error, Equatable {
    case missingDeviceFolderID
    case invalidSQLiteDatabase
}

public struct RemoteSyncProgressPatchUploadReport: Sendable, Equatable {
    public let uploadedFile: RemoteSyncFile
    public let patchNumber: Int64
    public let upsertedMemorizedVerseCount: Int
    public let upsertedChapterHistoryCount: Int
    public let upsertedTargetCount: Int
    public let upsertedSettingsCount: Int
    public let deletedRowCount: Int
    public let logEntryCount: Int
    public let lastUpdated: Int64
}

/**
 Creates Android-compatible sparse `progress.sqlite3` patches and uploads them to the device folder.
 */
public final class RemoteSyncProgressPatchUploadService {
    private struct ChangeSet {
        let memorizedVerseRowsByKey: [String: RemoteSyncCurrentProgressMemorizedVerseRow]
        let chapterHistoryRowsByKey: [String: RemoteSyncCurrentProgressChapterReadHistoryRow]
        let targetRowsByKey: [String: RemoteSyncCurrentProgressMemorizationTargetRow]
        let settingsRowsByKey: [String: RemoteSyncCurrentProgressSettingsRow]
        let logEntries: [RemoteSyncLogEntry]
        let updatedEntriesByKey: [String: RemoteSyncLogEntry]

        var deletedRowCount: Int {
            logEntries.filter { $0.type == .delete }.count
        }
    }

    private let adapter: any RemoteSyncAdapting
    private let snapshotService: RemoteSyncProgressSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let nowProvider: () -> Int64

    public init(
        adapter: any RemoteSyncAdapting,
        snapshotService: RemoteSyncProgressSnapshotService = RemoteSyncProgressSnapshotService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        nowProvider: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000.0)
        }
    ) {
        self.adapter = adapter
        self.snapshotService = snapshotService
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.nowProvider = nowProvider
    }

    public func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        settingsStore: SettingsStore,
        schemaVersion: Int = 9
    ) async throws -> RemoteSyncProgressPatchUploadReport? {
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncProgressPatchUploadError.missingDeviceFolderID
        }

        let sourceDevice = Self.sourceDeviceName(from: deviceFolderID)
        let timestamp = nowProvider()
        let snapshot = snapshotService.snapshotCurrentState(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let existingEntriesByKey = Dictionary(
            uniqueKeysWithValues: logEntryStore.entries(for: .progress).map {
                (logEntryStore.key(for: .progress, entry: $0), $0)
            }
        )

        let hadMissingFingerprintBaseline = existingEntriesByKey.contains { key, entry in
            entry.type != .delete &&
                snapshot.containsRow(for: key) &&
                fingerprintStore.fingerprint(
                    for: .progress,
                    tableName: entry.tableName,
                    entityID1: entry.entityID1,
                    entityID2: entry.entityID2
                ) == nil
        }

        let changeSet = buildChangeSet(
            snapshot: snapshot,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            timestamp: timestamp,
            sourceDevice: sourceDevice
        )

        if changeSet.logEntries.isEmpty {
            if hadMissingFingerprintBaseline {
                snapshotService.refreshBaselineFingerprints(settingsStore: settingsStore)
            }
            return nil
        }

        let patchNumber = (patchStatusStore.lastPatchNumber(for: .progress, sourceDevice: sourceDevice) ?? 0) + 1
        let patchFileName = "\(patchNumber).\(schemaVersion).sqlite3.gz"
        let databaseURL = temporaryURL(prefix: "remote-sync-progress-upload-", suffix: ".sqlite3")
        let archiveURL = temporaryURL(prefix: "remote-sync-progress-upload-", suffix: ".sqlite3.gz")
        defer {
            try? fileManager.removeItem(at: databaseURL)
            try? fileManager.removeItem(at: archiveURL)
        }

        try writePatchDatabase(at: databaseURL, schemaVersion: schemaVersion, changeSet: changeSet)
        let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: databaseURL))
        try archiveData.write(to: archiveURL, options: .atomic)

        let uploadedFile = try await adapter.upload(
            name: patchFileName,
            fileURL: archiveURL,
            parentID: deviceFolderID,
            contentType: NextCloudSyncAdapter.gzipMimeType
        )

        logEntryStore.replaceEntries(changeSet.updatedEntriesByKey.values.sorted(by: Self.logEntrySort), for: .progress)
        patchStatusStore.addStatus(
            RemoteSyncPatchStatus(
                sourceDevice: sourceDevice,
                patchNumber: patchNumber,
                sizeBytes: uploadedFile.size,
                appliedDate: timestamp
            ),
            for: .progress
        )
        var progressState = stateStore.progressState(for: .progress)
        progressState.lastPatchWritten = timestamp
        stateStore.setProgressState(progressState, for: .progress)
        snapshotService.refreshBaselineFingerprints(settingsStore: settingsStore)

        return RemoteSyncProgressPatchUploadReport(
            uploadedFile: uploadedFile,
            patchNumber: patchNumber,
            upsertedMemorizedVerseCount: changeSet.memorizedVerseRowsByKey.count,
            upsertedChapterHistoryCount: changeSet.chapterHistoryRowsByKey.count,
            upsertedTargetCount: changeSet.targetRowsByKey.count,
            upsertedSettingsCount: changeSet.settingsRowsByKey.count,
            deletedRowCount: changeSet.deletedRowCount,
            logEntryCount: changeSet.logEntries.count,
            lastUpdated: timestamp
        )
    }

    private func buildChangeSet(
        snapshot: RemoteSyncProgressCurrentSnapshot,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore,
        timestamp: Int64,
        sourceDevice: String
    ) -> ChangeSet {
        var memorizedVerseRowsByKey: [String: RemoteSyncCurrentProgressMemorizedVerseRow] = [:]
        var chapterHistoryRowsByKey: [String: RemoteSyncCurrentProgressChapterReadHistoryRow] = [:]
        var targetRowsByKey: [String: RemoteSyncCurrentProgressMemorizationTargetRow] = [:]
        var settingsRowsByKey: [String: RemoteSyncCurrentProgressSettingsRow] = [:]
        var logEntries: [RemoteSyncLogEntry] = []
        var updatedEntriesByKey = existingEntriesByKey

        appendUpserts(
            rowsByKey: snapshot.memorizedVerseRowsByKey,
            tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
            fingerprintsByKey: snapshot.fingerprintsByKey,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            timestamp: timestamp,
            sourceDevice: sourceDevice,
            collectedRows: &memorizedVerseRowsByKey,
            logEntries: &logEntries,
            updatedEntriesByKey: &updatedEntriesByKey
        )
        appendUpserts(
            rowsByKey: snapshot.chapterHistoryRowsByKey,
            tableName: RemoteSyncProgressSnapshotService.chapterReadHistoryTable,
            fingerprintsByKey: snapshot.fingerprintsByKey,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            timestamp: timestamp,
            sourceDevice: sourceDevice,
            collectedRows: &chapterHistoryRowsByKey,
            logEntries: &logEntries,
            updatedEntriesByKey: &updatedEntriesByKey
        )
        appendUpserts(
            rowsByKey: snapshot.memorizationTargetRowsByKey,
            tableName: RemoteSyncProgressSnapshotService.memorizationTargetTable,
            fingerprintsByKey: snapshot.fingerprintsByKey,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            timestamp: timestamp,
            sourceDevice: sourceDevice,
            collectedRows: &targetRowsByKey,
            logEntries: &logEntries,
            updatedEntriesByKey: &updatedEntriesByKey
        )
        appendUpserts(
            rowsByKey: snapshot.settingsRowsByKey,
            tableName: RemoteSyncProgressSnapshotService.globalSettingsTable,
            fingerprintsByKey: snapshot.fingerprintsByKey,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            timestamp: timestamp,
            sourceDevice: sourceDevice,
            collectedRows: &settingsRowsByKey,
            logEntries: &logEntries,
            updatedEntriesByKey: &updatedEntriesByKey
        )

        for (key, entry) in existingEntriesByKey.sorted(by: { $0.key < $1.key }) {
            guard entry.type != .delete, !snapshot.containsRow(for: key) else {
                continue
            }
            let deleteEntry = RemoteSyncLogEntry(
                tableName: entry.tableName,
                entityID1: entry.entityID1,
                entityID2: entry.entityID2,
                type: .delete,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            logEntries.append(deleteEntry)
            updatedEntriesByKey[key] = deleteEntry
        }

        return ChangeSet(
            memorizedVerseRowsByKey: memorizedVerseRowsByKey,
            chapterHistoryRowsByKey: chapterHistoryRowsByKey,
            targetRowsByKey: targetRowsByKey,
            settingsRowsByKey: settingsRowsByKey,
            logEntries: logEntries.sorted(by: Self.logEntrySort),
            updatedEntriesByKey: updatedEntriesByKey
        )
    }

    private func appendUpserts<Row>(
        rowsByKey: [String: Row],
        tableName: String,
        fingerprintsByKey: [String: String],
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore,
        timestamp: Int64,
        sourceDevice: String,
        collectedRows: inout [String: Row],
        logEntries: inout [RemoteSyncLogEntry],
        updatedEntriesByKey: inout [String: RemoteSyncLogEntry]
    ) {
        for (key, row) in rowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = RemoteSyncLogEntry(
                tableName: tableName,
                entityID1: Self.entityID1(fromLogKeyEntry: existingEntriesByKey[key], row: row),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            collectedRows[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }
    }

    private func shouldUploadCurrentRow(
        key: String,
        currentFingerprint: String?,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore
    ) -> Bool {
        guard let currentFingerprint else {
            return false
        }
        guard let existingEntry = existingEntriesByKey[key] else {
            if let existingFingerprint = fingerprintStore.fingerprint(forLogKey: key, category: .progress) {
                return existingFingerprint != currentFingerprint
            }
            return true
        }
        if existingEntry.type == .delete {
            return true
        }
        guard let existingFingerprint = fingerprintStore.fingerprint(
            for: .progress,
            tableName: existingEntry.tableName,
            entityID1: existingEntry.entityID1,
            entityID2: existingEntry.entityID2
        ) else {
            return false
        }
        return existingFingerprint != currentFingerprint
    }

    private static func entityID1<Row>(fromLogKeyEntry entry: RemoteSyncLogEntry?, row: Row) -> RemoteSyncSQLiteValue {
        if let entry {
            return entry.entityID1
        }
        switch row {
        case let row as RemoteSyncCurrentProgressMemorizedVerseRow:
            return .blob(RemoteSyncProgressSnapshotService.uuidBlob(row.id))
        case let row as RemoteSyncCurrentProgressChapterReadHistoryRow:
            return .blob(RemoteSyncProgressSnapshotService.uuidBlob(row.id))
        case let row as RemoteSyncCurrentProgressMemorizationTargetRow:
            return .blob(RemoteSyncProgressSnapshotService.uuidBlob(row.id))
        case let row as RemoteSyncCurrentProgressSettingsRow:
            return .blob(RemoteSyncProgressSnapshotService.uuidBlob(row.id))
        default:
            return .null()
        }
    }

    private func writePatchDatabase(at url: URL, schemaVersion: Int, changeSet: ChangeSet) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let database else {
            throw RemoteSyncProgressPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        try execute(progressPatchSchemaSQL(schemaVersion: schemaVersion), in: database)
        for row in changeSet.memorizedVerseRowsByKey.values.sorted(by: { $0.kjvOrdinal < $1.kjvOrdinal }) {
            try insertMemorizedVerse(row, in: database)
        }
        for row in changeSet.chapterHistoryRowsByKey.values.sorted(by: { $0.readAt < $1.readAt }) {
            try insertChapterHistory(row, in: database)
        }
        for row in changeSet.targetRowsByKey.values.sorted(by: { $0.createdAt > $1.createdAt }) {
            try insertTarget(row, in: database)
        }
        for row in changeSet.settingsRowsByKey.values {
            try insertSettings(row, in: database)
        }
        for entry in changeSet.logEntries {
            try insertLogEntry(entry, in: database)
        }
    }

    private func insertMemorizedVerse(_ row: RemoteSyncCurrentProgressMemorizedVerseRow, in database: OpaquePointer) throws {
        let statement = try prepare("INSERT INTO MemorizedVerse (id, kjvOrdinal, memorizedAt) VALUES (?, ?, ?);", in: database)
        defer { sqlite3_finalize(statement) }
        bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(row.kjvOrdinal))
        sqlite3_bind_int64(statement, 3, row.memorizedAt)
        try stepDone(statement)
    }

    private func insertChapterHistory(_ row: RemoteSyncCurrentProgressChapterReadHistoryRow, in database: OpaquePointer) throws {
        let statement = try prepare(
            """
            INSERT INTO ChapterReadHistory (id, kjvBookOrdinal, chapter, cycle, readAt, bookInitials, source)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(row.kjvBookOrdinal))
        sqlite3_bind_int(statement, 3, Int32(row.chapter))
        sqlite3_bind_int(statement, 4, Int32(row.cycle))
        sqlite3_bind_int64(statement, 5, row.readAt)
        bindText(row.bookInitials, to: statement, index: 6)
        bindText(row.source.rawValue, to: statement, index: 7)
        try stepDone(statement)
    }

    private func insertTarget(_ row: RemoteSyncCurrentProgressMemorizationTargetRow, in database: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT INTO MemorizationTarget (id, kjvOrdinalStart, kjvOrdinalEnd, createdAt) VALUES (?, ?, ?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(row.kjvOrdinalStart))
        sqlite3_bind_int(statement, 3, Int32(row.kjvOrdinalEnd))
        sqlite3_bind_int64(statement, 4, row.createdAt)
        try stepDone(statement)
    }

    private func insertSettings(_ row: RemoteSyncCurrentProgressSettingsRow, in database: OpaquePointer) throws {
        let statement = try prepare(
            """
            INSERT INTO GlobalReadingProgressSettings (
                id, autoTrackReading, autoMarkMemorized, memorizeTypeFullWords, memorizeWordVisibility,
                memorizeErrorHeatmap, memorizeScrambleHideUsed, memorizeIncludeReference, activeCycle
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, row.autoTrackReading ? 1 : 0)
        sqlite3_bind_int(statement, 3, row.autoMarkMemorized ? 1 : 0)
        sqlite3_bind_int(statement, 4, row.memorizeTypeFullWords ? 1 : 0)
        bindText(row.memorizeWordVisibility, to: statement, index: 5)
        sqlite3_bind_int(statement, 6, row.memorizeErrorHeatmap ? 1 : 0)
        sqlite3_bind_int(statement, 7, row.memorizeScrambleHideUsed ? 1 : 0)
        sqlite3_bind_int(statement, 8, row.memorizeIncludeReference ? 1 : 0)
        sqlite3_bind_int(statement, 9, Int32(row.activeCycle))
        try stepDone(statement)
    }

    private func insertLogEntry(_ entry: RemoteSyncLogEntry, in database: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bindText(entry.tableName, to: statement, index: 1)
        Self.bindSQLiteValue(entry.entityID1, to: statement, index: 2)
        Self.bindSQLiteValue(entry.entityID2, to: statement, index: 3)
        bindText(entry.type.rawValue, to: statement, index: 4)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        bindText(entry.sourceDevice, to: statement, index: 6)
        try stepDone(statement)
    }

    private func progressPatchSchemaSQL(schemaVersion: Int) -> String {
        """
        PRAGMA user_version = \(schemaVersion);
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
        """
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncProgressPatchUploadError.invalidSQLiteDatabase
        }
        return statement
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncProgressPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncProgressPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
        let data = RemoteSyncProgressSnapshotService.uuidBlob(uuid)
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), remoteSyncProgressPatchUploadSQLiteTransient)
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, remoteSyncProgressPatchUploadSQLiteTransient)
    }

    private static func bindSQLiteValue(_ value: RemoteSyncSQLiteValue, to statement: OpaquePointer?, index: Int32) {
        switch value.kind {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer:
            sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
        case .real:
            sqlite3_bind_double(statement, index, value.realValue ?? 0)
        case .text:
            sqlite3_bind_text(statement, index, value.textValue ?? "", -1, remoteSyncProgressPatchUploadSQLiteTransient)
        case .blob:
            let data = value.blobData ?? Data()
            _ = data.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), remoteSyncProgressPatchUploadSQLiteTransient)
            }
        }
    }

    private func temporaryURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    private static func sourceDeviceName(from deviceFolderID: String) -> String {
        let trimmed = deviceFolderID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? deviceFolderID
    }

    private static func logEntrySort(_ lhs: RemoteSyncLogEntry, _ rhs: RemoteSyncLogEntry) -> Bool {
        if lhs.tableName != rhs.tableName {
            return lhs.tableName < rhs.tableName
        }
        if lhs.lastUpdated != rhs.lastUpdated {
            return lhs.lastUpdated < rhs.lastUpdated
        }
        return "\(lhs.entityID1)-\(lhs.entityID2)" < "\(rhs.entityID1)-\(rhs.entityID2)"
    }
}
