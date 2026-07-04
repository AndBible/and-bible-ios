// RemoteSyncProgressPatchApplyService.swift - Incremental Android patch replay for Progress

import CLibSword
import Foundation
import SQLite3

private let remoteSyncProgressPatchApplySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum RemoteSyncProgressPatchApplyError: Error, Equatable {
    case invalidLogEntryIdentifier(table: String)
    case missingPatchRow(table: String, id: UUID)
    case invalidSQLiteDatabase
}

public struct RemoteSyncProgressPatchApplyReport: Sendable, Equatable {
    public let appliedPatchCount: Int
    public let appliedLogEntryCount: Int
    public let skippedLogEntryCount: Int
    public let readingCount: Int
    public let memorizedVerseCount: Int
    public let targetCount: Int
}

/**
 Replays sparse Android Progress patch archives into local reading and memorization progress stores.
 */
public final class RemoteSyncProgressPatchApplyService {
    private static let progressOrdinalRange = JSwordKJVAVersification.progressOrdinalRange

    private let metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService
    private let snapshotService: RemoteSyncProgressSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL

    public init(
        metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService(),
        snapshotService: RemoteSyncProgressSnapshotService = RemoteSyncProgressSnapshotService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) {
        self.metadataRestoreService = metadataRestoreService
        self.snapshotService = snapshotService
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
    }

    public func applyPatchArchives(
        _ stagedArchives: [RemoteSyncStagedPatchArchive],
        settingsStore: SettingsStore
    ) throws -> RemoteSyncProgressPatchApplyReport {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let currentSnapshot = snapshotService.snapshotCurrentState(settingsStore: settingsStore)

        var memorizedRowsByID = Dictionary(
            uniqueKeysWithValues: currentSnapshot.memorizedVerseRowsByKey.values.map { ($0.id, $0) }
        )
        var chapterRowsByID = Dictionary(
            uniqueKeysWithValues: currentSnapshot.chapterHistoryRowsByKey.values.map { ($0.id, $0) }
        )
        var targetRowsByID = Dictionary(
            uniqueKeysWithValues: currentSnapshot.memorizationTargetRowsByKey.values.map { ($0.id, $0) }
        )
        var settingsRow = currentSnapshot.settingsRowsByKey.values.first ??
            RemoteSyncCurrentProgressSettingsRow(
                id: RemoteSyncProgressSnapshotService.globalSettingsID,
                settings: ReadingProgressSettingsSnapshot()
            )
        var logEntriesByKey = Dictionary(
            uniqueKeysWithValues: logEntryStore.entries(for: .progress).map {
                (logEntryStore.key(for: .progress, entry: $0), $0)
            }
        )

        var appliedPatchStatuses: [RemoteSyncPatchStatus] = []
        var appliedLogEntryCount = 0
        var skippedLogEntryCount = 0

        for stagedArchive in stagedArchives {
            let patchDatabaseURL = temporaryDatabaseURL(prefix: "remote-sync-progress-patch-", suffix: ".sqlite3")
            defer { try? fileManager.removeItem(at: patchDatabaseURL) }

            let archiveData = try Data(contentsOf: stagedArchive.archiveFileURL)
            let databaseData = try Self.gunzip(archiveData)
            try databaseData.write(to: patchDatabaseURL, options: .atomic)

            let metadataSnapshot = try metadataRestoreService.readSnapshot(from: patchDatabaseURL)
            let patchLogEntries = metadataSnapshot.logEntries.filter { Self.progressTableNames.contains($0.tableName) }
            let filteredLogEntries = patchLogEntries.filter { entry in
                let key = logEntryStore.key(for: .progress, entry: entry)
                guard let localEntry = logEntriesByKey[key] else {
                    return true
                }
                return entry.lastUpdated > localEntry.lastUpdated
            }
            skippedLogEntryCount += patchLogEntries.count - filteredLogEntries.count
            guard !filteredLogEntries.isEmpty else {
                continue
            }

            try withSQLiteDatabase(at: patchDatabaseURL) { database in
                try applyMemorizedVerseOperations(
                    filteredLogEntries.filter { $0.tableName == RemoteSyncProgressSnapshotService.memorizedVerseTable },
                    database: database,
                    rowsByID: &memorizedRowsByID,
                    logEntriesByKey: &logEntriesByKey,
                    logEntryStore: logEntryStore
                )
                try applyChapterHistoryOperations(
                    filteredLogEntries.filter { $0.tableName == RemoteSyncProgressSnapshotService.chapterReadHistoryTable },
                    database: database,
                    rowsByID: &chapterRowsByID,
                    logEntriesByKey: &logEntriesByKey,
                    logEntryStore: logEntryStore
                )
                try applyTargetOperations(
                    filteredLogEntries.filter { $0.tableName == RemoteSyncProgressSnapshotService.memorizationTargetTable },
                    database: database,
                    rowsByID: &targetRowsByID,
                    logEntriesByKey: &logEntriesByKey,
                    logEntryStore: logEntryStore
                )
                try applySettingsOperations(
                    filteredLogEntries.filter { $0.tableName == RemoteSyncProgressSnapshotService.globalSettingsTable },
                    database: database,
                    row: &settingsRow,
                    logEntriesByKey: &logEntriesByKey,
                    logEntryStore: logEntryStore
                )
            }

            appliedLogEntryCount += filteredLogEntries.count
            appliedPatchStatuses.append(
                RemoteSyncPatchStatus(
                    sourceDevice: stagedArchive.patch.sourceDevice,
                    patchNumber: stagedArchive.patch.patchNumber,
                    sizeBytes: stagedArchive.patch.file.size,
                    appliedDate: stagedArchive.patch.file.timestamp
                )
            )
        }

        let readingSnapshot = ReadingProgressSnapshot(
            history: chapterRowsByID.values
                .map {
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
                }
                .sorted {
                    if $0.readAt != $1.readAt {
                        return $0.readAt < $1.readAt
                    }
                    return $0.id.uuidString < $1.id.uuidString
                },
            settings: settingsRow.settings
        )
        let memorizationSnapshot = MemorizationProgressSnapshot(
            memorizedVerses: memorizedRowsByID.values
                .map { MemorizedVerseProgress(id: $0.id, bookInitials: "", kjvOrdinal: $0.kjvOrdinal, memorizedAt: $0.memorizedAt) },
            targetRows: targetRowsByID.values
                .map {
                    MemorizationTargetRow(
                        id: $0.id,
                        bookInitials: "",
                        startOrdinal: $0.kjvOrdinalStart,
                        endOrdinal: $0.kjvOrdinalEnd,
                        createdAt: $0.createdAt
                    )
                }
        )
        let report = try AndroidDatabaseBackupProgressMapper.replaceLocalSnapshots(
            reading: readingSnapshot,
            memorization: memorizationSnapshot,
            settingsStore: settingsStore
        )

        logEntryStore.replaceEntries(logEntriesByKey.values.sorted(by: Self.logEntrySort), for: .progress)
        patchStatusStore.addStatuses(appliedPatchStatuses, for: .progress)
        snapshotService.refreshBaselineFingerprints(settingsStore: settingsStore)

        return RemoteSyncProgressPatchApplyReport(
            appliedPatchCount: appliedPatchStatuses.count,
            appliedLogEntryCount: appliedLogEntryCount,
            skippedLogEntryCount: skippedLogEntryCount,
            readingCount: report.readingCount,
            memorizedVerseCount: report.memorizedVerseCount,
            targetCount: report.targetCount
        )
    }

    private func applyMemorizedVerseOperations(
        _ logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        rowsByID: inout [UUID: RemoteSyncCurrentProgressMemorizedVerseRow],
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        for entry in logEntries.filter({ $0.type == .upsert }).sorted(by: Self.logEntrySort) {
            let rowID = try uuid(from: entry.entityID1, tableName: entry.tableName)
            guard let row = try fetchMemorizedVerse(id: rowID, from: database) else {
                throw RemoteSyncProgressPatchApplyError.missingPatchRow(table: entry.tableName, id: rowID)
            }
            if let duplicate = rowsByID.first(where: { $0.value.kjvOrdinal == row.kjvOrdinal }) {
                rowsByID.removeValue(forKey: duplicate.key)
            }
            rowsByID[row.id] = row
            logEntriesByKey[logEntryStore.key(for: .progress, entry: entry)] = entry
        }
        for entry in logEntries.filter({ $0.type == .delete }).sorted(by: Self.logEntrySort) {
            let rowID = try uuid(from: entry.entityID1, tableName: entry.tableName)
            rowsByID.removeValue(forKey: rowID)
            logEntriesByKey[logEntryStore.key(for: .progress, entry: entry)] = entry
        }
    }

    private func applyChapterHistoryOperations(
        _ logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        rowsByID: inout [UUID: RemoteSyncCurrentProgressChapterReadHistoryRow],
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        for entry in logEntries.filter({ $0.type == .upsert }).sorted(by: Self.logEntrySort) {
            let rowID = try uuid(from: entry.entityID1, tableName: entry.tableName)
            guard let row = try fetchChapterHistory(id: rowID, from: database) else {
                throw RemoteSyncProgressPatchApplyError.missingPatchRow(table: entry.tableName, id: rowID)
            }
            rowsByID[row.id] = row
            logEntriesByKey[logEntryStore.key(for: .progress, entry: entry)] = entry
        }
        for entry in logEntries.filter({ $0.type == .delete }).sorted(by: Self.logEntrySort) {
            let rowID = try uuid(from: entry.entityID1, tableName: entry.tableName)
            rowsByID.removeValue(forKey: rowID)
            logEntriesByKey[logEntryStore.key(for: .progress, entry: entry)] = entry
        }
    }

    private func applyTargetOperations(
        _ logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        rowsByID: inout [UUID: RemoteSyncCurrentProgressMemorizationTargetRow],
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        for entry in logEntries.filter({ $0.type == .upsert }).sorted(by: Self.logEntrySort) {
            let rowID = try uuid(from: entry.entityID1, tableName: entry.tableName)
            guard let row = try fetchTarget(id: rowID, from: database) else {
                throw RemoteSyncProgressPatchApplyError.missingPatchRow(table: entry.tableName, id: rowID)
            }
            rowsByID[row.id] = row
            logEntriesByKey[logEntryStore.key(for: .progress, entry: entry)] = entry
        }
        for entry in logEntries.filter({ $0.type == .delete }).sorted(by: Self.logEntrySort) {
            let rowID = try uuid(from: entry.entityID1, tableName: entry.tableName)
            rowsByID.removeValue(forKey: rowID)
            logEntriesByKey[logEntryStore.key(for: .progress, entry: entry)] = entry
        }
    }

    private func applySettingsOperations(
        _ logEntries: [RemoteSyncLogEntry],
        database: OpaquePointer,
        row: inout RemoteSyncCurrentProgressSettingsRow,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        for entry in logEntries.filter({ $0.type == .upsert }).sorted(by: Self.logEntrySort) {
            let rowID = try uuid(from: entry.entityID1, tableName: entry.tableName)
            guard let fetched = try fetchSettings(id: rowID, from: database) else {
                throw RemoteSyncProgressPatchApplyError.missingPatchRow(table: entry.tableName, id: rowID)
            }
            row = fetched
            logEntriesByKey[logEntryStore.key(for: .progress, entry: entry)] = entry
        }
        for entry in logEntries.filter({ $0.type == .delete }).sorted(by: Self.logEntrySort) {
            row = RemoteSyncCurrentProgressSettingsRow(
                id: RemoteSyncProgressSnapshotService.globalSettingsID,
                settings: ReadingProgressSettingsSnapshot()
            )
            logEntriesByKey[logEntryStore.key(for: .progress, entry: entry)] = entry
        }
    }

    private func fetchMemorizedVerse(
        id: UUID,
        from database: OpaquePointer
    ) throws -> RemoteSyncCurrentProgressMemorizedVerseRow? {
        let statement = try prepare(
            "SELECT id, kjvOrdinal, memorizedAt FROM MemorizedVerse WHERE id = ? LIMIT 1;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let kjvOrdinal = Int(sqlite3_column_int(statement, 1))
        guard Self.progressOrdinalRange.contains(kjvOrdinal) else {
            throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
        }
        return RemoteSyncCurrentProgressMemorizedVerseRow(
            id: try uuidFromBlob(statement: statement, column: 0),
            kjvOrdinal: kjvOrdinal,
            memorizedAt: sqlite3_column_int64(statement, 2)
        )
    }

    private func fetchChapterHistory(
        id: UUID,
        from database: OpaquePointer
    ) throws -> RemoteSyncCurrentProgressChapterReadHistoryRow? {
        let statement = try prepare(
            """
            SELECT id, kjvBookOrdinal, chapter, cycle, readAt, bookInitials, source
            FROM ChapterReadHistory
            WHERE id = ?
            LIMIT 1;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return RemoteSyncCurrentProgressChapterReadHistoryRow(
            id: try uuidFromBlob(statement: statement, column: 0),
            kjvBookOrdinal: Int(sqlite3_column_int(statement, 1)),
            chapter: Int(sqlite3_column_int(statement, 2)),
            cycle: Int(sqlite3_column_int(statement, 3)),
            readAt: sqlite3_column_int64(statement, 4),
            bookInitials: stringColumn(statement: statement, index: 5),
            source: ReadingProgressSource(bridgeValue: stringColumn(statement: statement, index: 6))
        )
    }

    private func fetchTarget(
        id: UUID,
        from database: OpaquePointer
    ) throws -> RemoteSyncCurrentProgressMemorizationTargetRow? {
        let statement = try prepare(
            "SELECT id, kjvOrdinalStart, kjvOrdinalEnd, createdAt FROM MemorizationTarget WHERE id = ? LIMIT 1;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let startOrdinal = Int(sqlite3_column_int(statement, 1))
        let endOrdinal = Int(sqlite3_column_int(statement, 2))
        guard Self.progressOrdinalRange.contains(startOrdinal),
              Self.progressOrdinalRange.contains(endOrdinal),
              endOrdinal >= startOrdinal else {
            throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
        }
        return RemoteSyncCurrentProgressMemorizationTargetRow(
            id: try uuidFromBlob(statement: statement, column: 0),
            kjvOrdinalStart: startOrdinal,
            kjvOrdinalEnd: endOrdinal,
            createdAt: sqlite3_column_int64(statement, 3)
        )
    }

    private func fetchSettings(
        id: UUID,
        from database: OpaquePointer
    ) throws -> RemoteSyncCurrentProgressSettingsRow? {
        let statement = try prepare(
            """
            SELECT id, autoTrackReading, autoMarkMemorized, memorizeTypeFullWords, memorizeWordVisibility,
                   memorizeErrorHeatmap, memorizeScrambleHideUsed, memorizeIncludeReference, activeCycle
            FROM GlobalReadingProgressSettings
            WHERE id = ?
            LIMIT 1;
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return RemoteSyncCurrentProgressSettingsRow(
            id: try uuidFromBlob(statement: statement, column: 0),
            settings: ReadingProgressSettingsSnapshot(
                autoTrackReading: sqlite3_column_int(statement, 1) != 0,
                activeCycle: Int(sqlite3_column_int(statement, 8)),
                autoMarkMemorized: sqlite3_column_int(statement, 2) != 0,
                memorizeTypeFullWords: sqlite3_column_int(statement, 3) != 0,
                memorizeWordVisibility: stringColumn(statement: statement, index: 4),
                memorizeErrorHeatmap: sqlite3_column_int(statement, 5) != 0,
                memorizeScrambleHideUsed: sqlite3_column_int(statement, 6) != 0,
                memorizeIncludeReference: sqlite3_column_int(statement, 7) != 0
            )
        )
    }

    private func uuid(from value: RemoteSyncSQLiteValue, tableName: String) throws -> UUID {
        switch value.kind {
        case .blob:
            guard let data = value.blobData, data.count == 16 else {
                throw RemoteSyncProgressPatchApplyError.invalidLogEntryIdentifier(table: tableName)
            }
            return try uuidFromData(data)
        case .text:
            guard let textValue = value.textValue, let uuid = UUID(uuidString: textValue) else {
                throw RemoteSyncProgressPatchApplyError.invalidLogEntryIdentifier(table: tableName)
            }
            return uuid
        default:
            throw RemoteSyncProgressPatchApplyError.invalidLogEntryIdentifier(table: tableName)
        }
    }

    private func withSQLiteDatabase<T>(at url: URL, body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }
        return try body(database)
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
        }
        return statement
    }

    private func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
        let data = RemoteSyncProgressSnapshotService.uuidBlob(uuid)
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), remoteSyncProgressPatchApplySQLiteTransient)
        }
    }

    private func uuidFromBlob(statement: OpaquePointer?, column: Int32) throws -> UUID {
        guard let bytes = sqlite3_column_blob(statement, column),
              sqlite3_column_bytes(statement, column) == 16 else {
            throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
        }
        return try uuidFromData(Data(bytes: bytes, count: 16))
    }

    private func uuidFromData(_ data: Data) throws -> UUID {
        guard data.count == 16 else {
            throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
        }
        let bytes = Array(data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func stringColumn(statement: OpaquePointer?, index: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: raw)
    }

    private func temporaryDatabaseURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    private static func gunzip(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> Data in
            guard let baseAddress = pointer.baseAddress else {
                throw RemoteSyncArchiveStagingError.decompressionFailed
            }
            var outputLength: UInt = 0
            guard let output = gunzip_data(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                UInt(data.count),
                &outputLength
            ) else {
                throw RemoteSyncArchiveStagingError.decompressionFailed
            }
            defer { gunzip_free(output) }
            return Data(bytes: output, count: Int(outputLength))
        }
    }

    private static let progressTableNames: Set<String> = [
        RemoteSyncProgressSnapshotService.memorizedVerseTable,
        RemoteSyncProgressSnapshotService.chapterReadHistoryTable,
        RemoteSyncProgressSnapshotService.memorizationTargetTable,
        RemoteSyncProgressSnapshotService.globalSettingsTable,
    ]

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
