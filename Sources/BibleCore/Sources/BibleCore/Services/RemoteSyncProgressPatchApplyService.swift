// RemoteSyncProgressPatchApplyService.swift - Incremental Android patch replay for Progress

import Foundation
import SQLite3

private let remoteSyncProgressPatchApplySQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum RemoteSyncProgressPatchApplyError: Error, Equatable {
    case tooManyPatchArchives(Int)
    case invalidLogEntryIdentifier(table: String)
    case missingPatchRow(table: String, id: UUID)
    case invalidSQLiteDatabase
    case compressedArchiveTooLarge(Int64)
    case expandedArchiveTooLarge(UInt64)
    case cumulativeArchiveTooLarge(UInt64)
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

 Archives are applied in caller order. Each archive publishes accepted reading, memorization, log,
 patch-status, and fingerprint rows through its own settings transaction, matching Android's
 independently committed archive loop. The complete batch is size-preflighted before the first
 archive commits.

 Data dependencies:
 - gzip patch archives containing Android Progress tables and `LogEntry` rows
 - `SettingsStore` namespaces used by progress and remote-sync bookkeeping stores

Side effects:
- materializes temporary SQLite patch databases and removes them after replay
- atomically rewrites Progress content and sync metadata settings once per archive

Failure modes:
- malformed archives, identifiers, rows, ordinals, or SQLite data throw explicit errors
- settings fetch, cancellation, encoding, and commit failures roll back the failing archive publish

 Concurrency:
 - inherits the confinement of the supplied `SettingsStore`; callers must not mutate it concurrently
 */
public final class RemoteSyncProgressPatchApplyService {
    private static let progressOrdinalRange = JSwordKJVAVersification.progressOrdinalRange

    /// Maximum archives admitted by one bounded replay request.
    private static let maximumPatchArchiveCount = 1_000

    /// Maximum compressed bytes accepted from one staged Progress patch.
    private static let maximumCompressedPatchByteCount = 16 * 1_024 * 1_024

    /// Maximum expanded SQLite bytes accepted from one staged Progress patch.
    private static let maximumExpandedPatchByteCount = 64 * 1_024 * 1_024

    /// Maximum aggregate expanded bytes accepted across one replay call.
    private static let maximumCumulativeExpandedPatchByteCount = 256 * 1_024 * 1_024

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

    /**
     Replays an ordered batch of Android Progress patches with one commit per archive.

     - Parameters:
       - stagedArchives: Downloaded patch archives in Android application order.
       - settingsStore: Store owning reading, memorization, and sync bookkeeping rows.
     - Returns: Aggregate counts for committed patches and the final Progress content.
     - Side Effects: Preflights the complete batch, then reads and commits each patch independently.
     - Throws: Rethrows archive, replay, validation, cancellation, strict fetch, encoding, and
       transaction errors. A later failure preserves each earlier archive's complete commit.
     */
    public func applyPatchArchives(
        _ stagedArchives: [RemoteSyncStagedPatchArchive],
        settingsStore: SettingsStore
    ) throws -> RemoteSyncProgressPatchApplyReport {
        try applyPatchArchives(
            stagedArchives,
            settingsStore: settingsStore,
            publishCheckpoint: { try Task.checkCancellation() }
        )
    }

    /**
     Replays Progress patches with a deterministic checkpoint inside the atomic settings publish.

     Progress content, Android log entries, patch status, and fingerprint baselines all live in the
     same local settings context. Each archive publishes those namespaces through one transaction;
     after a successful commit, a later archive failure does not roll that archive back.

     - Parameters:
       - stagedArchives: Downloaded Progress patches in Android replay order.
       - settingsStore: Settings store owning all Progress and sync metadata rows.
       - publishCheckpoint: Throwing callback before strict reads and after final mutations stage.
     - Returns: Aggregate replay counts after all per-archive transactions commit.
     - Side Effects: Preflights every archive, then atomically replaces Progress sync settings once
       per archive.
     - Throws: Rethrows replay, checkpoint, strict fetch, cancellation, encoding, and commit errors;
       the failing archive rolls back while earlier archive commits remain.
     */
    func applyPatchArchives(
        _ stagedArchives: [RemoteSyncStagedPatchArchive],
        settingsStore: SettingsStore,
        publishCheckpoint: () throws -> Void
    ) throws -> RemoteSyncProgressPatchApplyReport {
        guard stagedArchives.count <= Self.maximumPatchArchiveCount else {
            throw RemoteSyncProgressPatchApplyError.tooManyPatchArchives(stagedArchives.count)
        }
        try preflightArchiveBounds(stagedArchives)
        if stagedArchives.count > 1 {
            var appliedPatchCount = 0
            var appliedLogEntryCount = 0
            var skippedLogEntryCount = 0
            var readingCount = 0
            var memorizedVerseCount = 0
            var targetCount = 0
            for stagedArchive in stagedArchives {
                let report = try applyPatchArchives(
                    [stagedArchive],
                    settingsStore: settingsStore,
                    publishCheckpoint: publishCheckpoint
                )
                appliedPatchCount += report.appliedPatchCount
                appliedLogEntryCount += report.appliedLogEntryCount
                skippedLogEntryCount += report.skippedLogEntryCount
                readingCount = report.readingCount
                memorizedVerseCount = report.memorizedVerseCount
                targetCount = report.targetCount
            }
            return RemoteSyncProgressPatchApplyReport(
                appliedPatchCount: appliedPatchCount,
                appliedLogEntryCount: appliedLogEntryCount,
                skippedLogEntryCount: skippedLogEntryCount,
                readingCount: readingCount,
                memorizedVerseCount: memorizedVerseCount,
                targetCount: targetCount
            )
        }

        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let initialState = try settingsStore.performAtomicBatch {
            try publishCheckpoint()
            return (
                try snapshotService.snapshotCurrentStateStrict(settingsStore: settingsStore),
                try logEntryStore.entriesStrict(for: .progress)
            )
        }
        let currentSnapshot = initialState.0

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
            uniqueKeysWithValues: initialState.1.map {
                (logEntryStore.key(for: .progress, entry: $0), $0)
            }
        )

        var appliedPatchStatuses: [RemoteSyncPatchStatus] = []
        var appliedLogEntryCount = 0
        var skippedLogEntryCount = 0
        var cumulativeExpandedByteCount: UInt64 = 0

        for stagedArchive in stagedArchives {
            try Task.checkCancellation()
            let patchDatabaseURL = temporaryDatabaseURL(prefix: "remote-sync-progress-patch-", suffix: ".sqlite3")
            defer { try? fileManager.removeItem(at: patchDatabaseURL) }

            let member: RemoteSyncGzipMember
            do {
                member = try RemoteSyncBoundedFileIO.inspectGzip(
                    at: stagedArchive.archiveFileURL,
                    maximumCompressedByteCount: Self.maximumCompressedPatchByteCount,
                    maximumExpandedByteCount: Self.maximumExpandedPatchByteCount
                )
            } catch RemoteSyncBoundedFileError.compressedSizeExceeded(let size) {
                throw RemoteSyncProgressPatchApplyError.compressedArchiveTooLarge(size)
            } catch RemoteSyncBoundedFileError.expandedSizeExceeded(let size) {
                throw RemoteSyncProgressPatchApplyError.expandedArchiveTooLarge(size)
            } catch {
                throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
            }
            let (nextCumulative, overflow) = cumulativeExpandedByteCount
                .addingReportingOverflow(member.expandedByteCount)
            guard !overflow,
                  nextCumulative <= UInt64(Self.maximumCumulativeExpandedPatchByteCount) else {
                throw RemoteSyncProgressPatchApplyError.cumulativeArchiveTooLarge(
                    overflow ? UInt64.max : nextCumulative
                )
            }
            cumulativeExpandedByteCount = nextCumulative
            do {
                try RemoteSyncBoundedFileIO.inflateGzip(
                    member,
                    from: stagedArchive.archiveFileURL,
                    to: patchDatabaseURL,
                    maximumExpandedByteCount: Self.maximumExpandedPatchByteCount
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
            }

            try withSQLiteDatabase(at: patchDatabaseURL) { database in
                try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                    database,
                    category: .progress
                )
                try validateGlobalSettingsSingletonIdentity(in: database)
            }

            let metadataSnapshot = try metadataRestoreService.readSnapshot(from: patchDatabaseURL)
            let patchLogEntries = metadataSnapshot.logEntries.filter { Self.progressTableNames.contains($0.tableName) }
            let filteredLogEntries = patchLogEntries.filter { entry in
                let key = logEntryStore.key(for: .progress, entry: entry)
                guard let localEntry = logEntriesByKey[key] else {
                    return true
                }
                return RemoteSyncLogEntryConflictOrder.isNewer(entry, than: localEntry)
            }
            skippedLogEntryCount += patchLogEntries.count - filteredLogEntries.count

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

        let readingHistory = try chapterRowsByID.values
            .map { row -> ReadingProgressHistoryRow in
                guard let identity = ReadingProgressKJVAIdentity(
                    androidKJVBookOrdinal: row.kjvBookOrdinal,
                    chapter: row.chapter
                ) else {
                    throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
                }
                return ReadingProgressHistoryRow(
                    id: row.id,
                    bookInitials: row.bookInitials,
                    identity: identity,
                    cycle: row.cycle,
                    readAt: row.readAt,
                    source: row.source
                )
            }
            .sorted {
                if $0.readAt != $1.readAt {
                    return $0.readAt < $1.readAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        let readingSnapshot = ReadingProgressSnapshot(
            history: readingHistory,
            settings: settingsRow.settings
        )
        let memorizationSnapshot = MemorizationProgressSnapshot(
            memorizedVerses: memorizedRowsByID.values
                .map {
                    MemorizedVerseProgress(
                        id: $0.id,
                        bookInitials: "",
                        kjvOrdinal: $0.kjvOrdinal,
                        memorizedAt: $0.memorizedAt,
                        ordinalTrust: PersistedOrdinalTrustPolicy.androidImportMetadata(
                            sourceVersification: "KJVA",
                            sourceOrdinalStart: $0.kjvOrdinal,
                            sourceOrdinalEnd: $0.kjvOrdinal,
                            kjvaOrdinalStart: $0.kjvOrdinal,
                            kjvaOrdinalEnd: $0.kjvOrdinal
                        )
                    )
                },
            targetRows: targetRowsByID.values
                .map {
                    MemorizationTargetRow(
                        id: $0.id,
                        bookInitials: "",
                        startOrdinal: $0.kjvOrdinalStart,
                        endOrdinal: $0.kjvOrdinalEnd,
                        createdAt: $0.createdAt,
                        ordinalTrust: PersistedOrdinalTrustPolicy.androidImportMetadata(
                            sourceVersification: "KJVA",
                            sourceOrdinalStart: $0.kjvOrdinalStart,
                            sourceOrdinalEnd: $0.kjvOrdinalEnd,
                            kjvaOrdinalStart: $0.kjvOrdinalStart,
                            kjvaOrdinalEnd: $0.kjvOrdinalEnd
                        )
                    )
                }
        )
        let report = try settingsStore.performAtomicBatch {
            let report = try AndroidDatabaseBackupProgressMapper.replaceLocalSnapshots(
                reading: readingSnapshot,
                memorization: memorizationSnapshot,
                settingsStore: settingsStore
            )

            logEntryStore.replaceEntries(logEntriesByKey.values.sorted(by: Self.logEntrySort), for: .progress)
            patchStatusStore.addStatuses(appliedPatchStatuses, for: .progress)
            snapshotService.refreshBaselineFingerprints(settingsStore: settingsStore)
            try publishCheckpoint()
            return report
        }

        return RemoteSyncProgressPatchApplyReport(
            appliedPatchCount: appliedPatchStatuses.count,
            appliedLogEntryCount: appliedLogEntryCount,
            skippedLogEntryCount: skippedLogEntryCount,
            readingCount: report.readingCount,
            memorizedVerseCount: report.memorizedVerseCount,
            targetCount: report.targetCount
        )
    }

    /**
     Verifies every compressed member and aggregate expanded size before the first archive commits.

     - Parameter stagedArchives: Caller-ordered Progress patch files.
     - Side effects: Opens each archive with no-follow semantics and reads bounded gzip metadata only.
     - Throws: Typed compressed, expanded, cumulative, or malformed-archive errors. No SQLite file is
       inflated and no local setting is mutated by this preflight.
     */
    private func preflightArchiveBounds(
        _ stagedArchives: [RemoteSyncStagedPatchArchive]
    ) throws {
        var cumulativeExpandedByteCount: UInt64 = 0
        for stagedArchive in stagedArchives {
            try Task.checkCancellation()
            let member: RemoteSyncGzipMember
            do {
                member = try RemoteSyncBoundedFileIO.inspectGzip(
                    at: stagedArchive.archiveFileURL,
                    maximumCompressedByteCount: Self.maximumCompressedPatchByteCount,
                    maximumExpandedByteCount: Self.maximumExpandedPatchByteCount
                )
            } catch RemoteSyncBoundedFileError.compressedSizeExceeded(let size) {
                throw RemoteSyncProgressPatchApplyError.compressedArchiveTooLarge(size)
            } catch RemoteSyncBoundedFileError.expandedSizeExceeded(let size) {
                throw RemoteSyncProgressPatchApplyError.expandedArchiveTooLarge(size)
            } catch {
                throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
            }
            let (next, overflow) = cumulativeExpandedByteCount.addingReportingOverflow(
                member.expandedByteCount
            )
            guard !overflow,
                  next <= UInt64(Self.maximumCumulativeExpandedPatchByteCount) else {
                throw RemoteSyncProgressPatchApplyError.cumulativeArchiveTooLarge(
                    overflow ? UInt64.max : next
                )
            }
            cumulativeExpandedByteCount = next
        }
    }

    /**
     Applies Android memorized-verse operations with SQLite unique-index conflict semantics.

     An UPSERT that collides on `kjvOrdinal` updates the existing row while preserving that row's
     primary-key UUID, exactly as Android's `ON CONFLICT DO UPDATE` statement does. A later DELETE
     for the discarded incoming UUID therefore leaves the preserved row intact.

     - Parameters:
       - logEntries: Strictly newer operations for `MemorizedVerse`.
       - database: Validated sparse Progress patch database.
       - rowsByID: Mutable current generation keyed by authoritative primary-key UUID.
       - logEntriesByKey: Mutable Android conflict baseline.
       - logEntryStore: Canonical composite-key builder for the Progress category.
     - Side effects: Mutates only the supplied in-memory row and log dictionaries.
     - Throws: Identifier, missing-row, ordinal, or SQLite decoding failures before publication.
     */
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
            if let duplicate = rowsByID.first(where: { $0.value.kjvOrdinal == row.kjvOrdinal }),
               duplicate.key != row.id {
                rowsByID[duplicate.key] = RemoteSyncCurrentProgressMemorizedVerseRow(
                    id: duplicate.key,
                    kjvOrdinal: row.kjvOrdinal,
                    memorizedAt: row.memorizedAt
                )
            } else {
                rowsByID[row.id] = row
            }
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
        try bindUUIDBlob(id, to: statement, index: 1)
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
        try bindUUIDBlob(id, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let kjvBookOrdinal = Int(sqlite3_column_int(statement, 1))
        let chapter = Int(sqlite3_column_int(statement, 2))
        guard ReadingProgressKJVAIdentity(
            androidKJVBookOrdinal: kjvBookOrdinal,
            chapter: chapter
        ) != nil else {
            throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
        }
        return RemoteSyncCurrentProgressChapterReadHistoryRow(
            id: try uuidFromBlob(statement: statement, column: 0),
            kjvBookOrdinal: kjvBookOrdinal,
            chapter: chapter,
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
        try bindUUIDBlob(id, to: statement, index: 1)
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
        try bindUUIDBlob(id, to: statement, index: 1)
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

    /**
     Rejects Progress patches that replace Android's fixed global-settings identity.

     Both the singleton table row and every matching log operation must use Android's exact UUID.
     This check runs before metadata decoding so a foreign delete identifier cannot reset local
     settings or enter the conflict journal.

     - Parameter database: Schema-validated Progress patch database.
     - Side Effects: Reads singleton and log identifier BLOBs without mutating the database.
     - Throws: `invalidSQLiteDatabase` for a foreign identifier, wrong storage class, malformed
       BLOB, or SQLite read failure.
     */
    private func validateGlobalSettingsSingletonIdentity(
        in database: OpaquePointer
    ) throws {
        let statement = try prepare(
            """
            SELECT id
            FROM GlobalReadingProgressSettings
            UNION ALL
            SELECT entityId1
            FROM LogEntry
            WHERE tableName = 'GlobalReadingProgressSettings';
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }

        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard sqlite3_column_type(statement, 0) == SQLITE_BLOB,
                      let bytes = sqlite3_column_blob(statement, 0),
                      sqlite3_column_bytes(statement, 0) == 16 else {
                    throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
                }
                let identifier = try uuidFromData(Data(bytes: bytes, count: 16))
                guard identifier == RemoteSyncProgressSnapshotService.globalSettingsID else {
                    throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
                }
            case SQLITE_DONE:
                return
            default:
                throw RemoteSyncProgressPatchApplyError.invalidSQLiteDatabase
            }
        }
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

    /** Binds one UUID BLOB with an exactly represented SQLite byte count. */
    private func bindUUIDBlob(
        _ uuid: UUID,
        to statement: OpaquePointer?,
        index: Int32
    ) throws {
        let data = RemoteSyncProgressSnapshotService.uuidBlob(uuid)
        let byteCount = try RemoteSyncWireInteger.int32(
            exactly: data.count,
            field: "UUID.byteCount"
        )
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(
                statement,
                index,
                $0.baseAddress,
                byteCount,
                remoteSyncProgressPatchApplySQLiteTransient
            )
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
