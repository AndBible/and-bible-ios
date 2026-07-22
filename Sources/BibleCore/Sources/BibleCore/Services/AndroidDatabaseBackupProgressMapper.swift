// AndroidDatabaseBackupProgressMapper.swift -- Android progress.sqlite3 backup mapper

import Foundation
import SQLite3

/**
 Summary for applying Android's `progress.sqlite3` database.
 */
public struct AndroidDatabaseBackupProgressReport: Sendable, Equatable {
    /// Number of reading-history rows present after apply.
    public let readingCount: Int

    /// Number of unique KJV memorized verse ordinals present after apply.
    public let memorizedVerseCount: Int

    /// Number of memorization target ranges present after apply.
    public let targetCount: Int
}

/**
 Maps Android's reading and memorization progress database to iOS's local progress stores.

 Android stores memorization state as KJV-normalized global rows. iOS preserves that contract by
 importing Android memorized-verse timestamps and independent target rows with an empty
 `bookInitials` field. Reader calls for any module can then see the same KJV ordinal state instead
 of a module-specific copy. The accepted ordinal range follows JSword's `SystemKJVA`
 `maximumOrdinal()` contract rather than SWORD module-local ordinals, matching Android's progress
 database semantics.
 */
enum AndroidDatabaseBackupProgressMapper {
    private struct Snapshot {
        var reading: ReadingProgressSnapshot
        var memorization: MemorizationProgressSnapshot
    }

    private static let singletonSettingsID = UUID(uuidString: "b2000000-0000-0000-0000-000000000001")!
    /// Android progress rows use one-based JSword KJVA ordinals for stored verse ranges.
    private static let jswordKJVAOrdinalRange = JSwordKJVAVersification.progressOrdinalRange

    /**
     Applies Android progress rows using Restore or Import semantics.

     - Parameters:
       - databaseURL: Extracted Android `progress.sqlite3` file.
       - mode: Restore replaces local progress; Import keeps local rows first and adds missing rows.
       - settingsStore: Local store backing iOS progress JSON snapshots.
     - Returns: Counts present after apply.
     - Side effects: Rewrites local reading and memorization progress snapshots in `SettingsStore`.
     - Failure modes: Throws a `RemoteSyncAndroidDatabaseContractError` for Room version, identity,
       schema, index, row, or scalar drift; `ProgressPersistenceSnapshotError` for malformed local
       JSON; or an Android backup, encoding, settings-fetch, or persistence error before replacement.
     */
    static func apply(
        from databaseURL: URL,
        mode: AndroidDatabaseBackupApplyMode,
        settingsStore: SettingsStore
    ) throws -> AndroidDatabaseBackupProgressReport {
        _ = try strictLocalSnapshot(settingsStore: settingsStore)
        let imported = try readSnapshot(from: databaseURL)
        let finalSnapshot: Snapshot
        switch mode {
        case .restore:
            finalSnapshot = imported
        case .import:
            finalSnapshot = try mergeForImport(imported: imported, settingsStore: settingsStore)
        }
        let losslessSnapshot = try preservingUnverifiedRows(
            in: finalSnapshot,
            settingsStore: settingsStore
        )
        try save(losslessSnapshot, settingsStore: settingsStore)
        return report(for: losslessSnapshot, settingsStore: settingsStore)
    }

    /**
     Writes an Android-compatible `progress.sqlite3` database from current iOS progress state.

     - Parameters:
       - databaseURL: Destination SQLite URL.
       - settingsStore: Local store containing current progress snapshots.
     - Returns: Counts written into the database.
     - Side effects: Creates or replaces the SQLite database file.
     - Failure modes: Throws `ProgressPersistenceSnapshotError` for malformed local JSON,
       `RemoteSyncWireIntegerError` for values outside Android's signed 32-bit wire range, or an
       Android backup/filesystem error when SQLite creation or insertion fails.
     */
    @discardableResult
    static func writeDatabase(
        at databaseURL: URL,
        settingsStore: SettingsStore
    ) throws -> AndroidDatabaseBackupProgressReport {
        let readingSnapshot = try ReadingProgressStore(
            settingsStore: settingsStore
        ).strictSnapshot()
        let memorizationSnapshot = try MemorizationProgressStore(
            settingsStore: settingsStore
        ).persistenceSnapshotStrict()
        let snapshot = Snapshot(reading: readingSnapshot, memorization: memorizationSnapshot)
        try? FileManager.default.removeItem(at: databaseURL)

        try AndroidDatabaseBackupSQLite.withDatabase(
            at: databaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        ) { database in
            let fileName = databaseURL.lastPathComponent
            try AndroidDatabaseBackupSQLite.execute(
                RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: .progress),
                on: database,
                fileName: fileName
            )
            for verse in exportableMemorizedVerses(in: snapshot.memorization.memorizedVerses) {
                try insertMemorizedVerse(verse, into: database, fileName: fileName)
            }
            for target in exportableMemorizationTargets(in: snapshot.memorization.targetRows) {
                try insertMemorizationTarget(target, into: database, fileName: fileName)
            }
            for row in snapshot.reading.history {
                try insertChapterHistory(row, into: database, fileName: fileName)
            }
            try insertGlobalSettings(snapshot.reading.settings, into: database, fileName: fileName)
        }

        return report(for: snapshot, settingsStore: settingsStore)
    }

    /**
     Replaces local progress stores from an already decoded Android-shaped snapshot.

     Remote patch replay validates sparse Android progress rows into the same in-memory models used
     by database backup restore. This helper keeps the final JSON rewrite, normalization, and report
     generation in one place.

     - Parameters:
       - reading: Final reading-progress snapshot to persist.
       - memorization: Final memorization-progress snapshot to persist.
       - settingsStore: Local store backing iOS progress JSON snapshots.
     - Returns: Counts present after replacement.
     - Side effects: Rewrites local reading and memorization progress snapshots in `SettingsStore`.
     - Failure modes: Throws `ProgressPersistenceSnapshotError` when current local JSON is malformed,
       or propagates encoding, settings-fetch, and persistence errors without a partial replacement.
     */
    @discardableResult
    static func replaceLocalSnapshots(
        reading: ReadingProgressSnapshot,
        memorization: MemorizationProgressSnapshot,
        settingsStore: SettingsStore
    ) throws -> AndroidDatabaseBackupProgressReport {
        let snapshot = try preservingUnverifiedRows(
            in: Snapshot(reading: reading, memorization: memorization),
            settingsStore: settingsStore
        )
        try save(snapshot, settingsStore: settingsStore)
        return report(for: snapshot, settingsStore: settingsStore)
    }

    /**
     Decodes a complete Android Progress Room database after verifying its exact wire contract.

     - Parameter databaseURL: Read-only inbound `progress.sqlite3` file.
     - Returns: Validated reading and memorization rows ready for an atomic local replacement.
     - Side effects: Opens and reads the SQLite file; local settings are not mutated.
     - Throws: A typed Room contract error for version, identity, schema, or index drift, or an
       Android backup error when validated rows contain unsupported values.
     */
    private static func readSnapshot(from databaseURL: URL) throws -> Snapshot {
        try AndroidDatabaseBackupSQLite.withDatabase(at: databaseURL) { database in
            try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                database,
                category: .progress
            )
            let fileName = databaseURL.lastPathComponent
            let memorizedVerses = try readMemorizedVerses(from: database, fileName: fileName)
            let targetRows = try readTargetRows(from: database, fileName: fileName)
            let history = try readChapterHistory(from: database, fileName: fileName)
            let settings = try readGlobalSettings(from: database, fileName: fileName)
            return Snapshot(
                reading: ReadingProgressSnapshot(history: history, settings: settings),
                memorization: MemorizationProgressSnapshot(
                    memorizedVerses: memorizedVerses,
                    targetRows: targetRows
                )
            )
        }
    }

    private static func mergeForImport(
        imported: Snapshot,
        settingsStore: SettingsStore
    ) throws -> Snapshot {
        let local = try strictLocalSnapshot(settingsStore: settingsStore)
        let localReading = local.reading
        let localMemorization = local.memorization

        var historyByID = Dictionary(uniqueKeysWithValues: localReading.history.map { ($0.id, $0) })
        for row in imported.reading.history where historyByID[row.id] == nil {
            historyByID[row.id] = row
        }
        let keepLocalReadingSettings = settingsStore.getString(ReadingProgressStore.settingsKey) != nil
        var memorizedVersesByID: [UUID: MemorizedVerseProgress] = [:]
        for localRow in localMemorization.memorizedVerses {
            if let existing = memorizedVersesByID[localRow.id],
               existing.memorizedAt >= localRow.memorizedAt {
                continue
            }
            memorizedVersesByID[localRow.id] = localRow
        }
        for importedRow in imported.memorization.memorizedVerses {
            guard let localRow = memorizedVersesByID[importedRow.id] else {
                memorizedVersesByID[importedRow.id] = importedRow
                continue
            }
            if !localRow.hasTrustedPersistedOrdinals || importedRow.memorizedAt > localRow.memorizedAt {
                memorizedVersesByID[importedRow.id] = importedRow
            }
        }
        var targetRowsByID: [UUID: MemorizationTargetRow] = [:]
        for localRow in localMemorization.targetRows {
            if let existing = targetRowsByID[localRow.id],
               existing.createdAt >= localRow.createdAt {
                continue
            }
            targetRowsByID[localRow.id] = localRow
        }
        for importedRow in imported.memorization.targetRows {
            guard let localRow = targetRowsByID[importedRow.id] else {
                targetRowsByID[importedRow.id] = importedRow
                continue
            }
            if !localRow.hasTrustedPersistedOrdinals || importedRow.createdAt > localRow.createdAt {
                targetRowsByID[importedRow.id] = importedRow
            }
        }

        return Snapshot(
            reading: ReadingProgressSnapshot(
                history: historyByID.values.sorted {
                    if $0.readAt != $1.readAt {
                        return $0.readAt < $1.readAt
                    }
                    return $0.id.uuidString < $1.id.uuidString
                },
                settings: keepLocalReadingSettings ? localReading.settings : imported.reading.settings
            ),
            memorization: MemorizationProgressSnapshot(
                memorizedVerses: Array(memorizedVersesByID.values),
                targetRows: Array(targetRowsByID.values)
            )
        )
    }

    /**
     Retains quarantined local memorization rows across destructive Android or patch replacement.

     - Parameters:
       - snapshot: Incoming final progress snapshot.
       - settingsStore: Store containing the current raw memorization persistence snapshot.
     - Returns: Incoming snapshot plus non-colliding unverified local rows. Incoming rows win exact
       identifier collisions because validated remote data is authoritative at that boundary.
     - Side effects: Reads current memorization JSON.
     - Throws: `ProgressPersistenceSnapshotError` when either current Progress JSON value is malformed.
     */
    private static func preservingUnverifiedRows(
        in snapshot: Snapshot,
        settingsStore: SettingsStore
    ) throws -> Snapshot {
        let current = try strictLocalSnapshot(settingsStore: settingsStore).memorization
        let incomingVerseIDs = Set(snapshot.memorization.memorizedVerses.map(\.id))
        let incomingTargetIDs = Set(snapshot.memorization.targetRows.map(\.id))
        let preservedVerses = current.memorizedVerses.filter {
            !$0.hasTrustedPersistedOrdinals && !incomingVerseIDs.contains($0.id)
        }
        let preservedTargets = current.targetRows.filter {
            !$0.hasTrustedPersistedOrdinals && !incomingTargetIDs.contains($0.id)
        }
        return Snapshot(
            reading: snapshot.reading,
            memorization: MemorizationProgressSnapshot(
                memorizedVerses: snapshot.memorization.memorizedVerses + preservedVerses,
                targetRows: snapshot.memorization.targetRows + preservedTargets
            )
        )
    }

    /** Reads both local Progress payloads strictly before a destructive replacement can begin. */
    private static func strictLocalSnapshot(settingsStore: SettingsStore) throws -> Snapshot {
        Snapshot(
            reading: try ReadingProgressStore(settingsStore: settingsStore).strictSnapshot(),
            memorization: try MemorizationProgressStore(
                settingsStore: settingsStore
            ).persistenceSnapshotStrict()
        )
    }

    private static func save(_ snapshot: Snapshot, settingsStore: SettingsStore) throws {
        let encoder = JSONEncoder()
        let readingData = try encoder.encode(snapshot.reading)
        let memorizationData = try encoder.encode(snapshot.memorization)
        guard let readingValue = String(data: readingData, encoding: .utf8),
              let memorizationValue = String(data: memorizationData, encoding: .utf8) else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase("progress.sqlite3")
        }
        settingsStore.setString(ReadingProgressStore.settingsKey, value: readingValue)
        settingsStore.setString(MemorizationProgressStore.settingsKey, value: memorizationValue)
    }

    private static func report(
        for _: Snapshot,
        settingsStore: SettingsStore
    ) -> AndroidDatabaseBackupProgressReport {
        let normalizedMemorization = MemorizationProgressStore(settingsStore: settingsStore).snapshot()
        let normalizedReading = ReadingProgressStore(settingsStore: settingsStore).snapshot()
        return AndroidDatabaseBackupProgressReport(
            readingCount: normalizedReading.history.count,
            memorizedVerseCount: exportableMemorizedVerses(in: normalizedMemorization.memorizedVerses).count,
            targetCount: exportableMemorizationTargets(in: normalizedMemorization.targetRows).count
        )
    }

    private static func readMemorizedVerses(
        from database: OpaquePointer,
        fileName: String
    ) throws -> [MemorizedVerseProgress] {
        let statement = try AndroidDatabaseBackupSQLite.prepare(
            "SELECT id, kjvOrdinal, memorizedAt FROM MemorizedVerse ORDER BY kjvOrdinal;",
            on: database,
            fileName: fileName
        )
        defer { sqlite3_finalize(statement) }

        var verses: [MemorizedVerseProgress] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
            }
            let ordinal = try validatedKJVAOrdinal(
                AndroidDatabaseBackupSQLite.int(statement, column: 1),
                fileName: fileName
            )
            verses.append(
                MemorizedVerseProgress(
                    id: try AndroidDatabaseBackupSQLite.uuidFromBlob(statement, column: 0, fileName: fileName),
                    bookInitials: "",
                    kjvOrdinal: ordinal,
                    memorizedAt: AndroidDatabaseBackupSQLite.int64(statement, column: 2),
                    ordinalTrust: PersistedOrdinalTrustPolicy.androidImportMetadata(
                        sourceVersification: "KJVA",
                        sourceOrdinalStart: ordinal,
                        sourceOrdinalEnd: ordinal,
                        kjvaOrdinalStart: ordinal,
                        kjvaOrdinalEnd: ordinal
                    )
                )
            )
        }
        return verses
    }

    private static func readTargetRows(
        from database: OpaquePointer,
        fileName: String
    ) throws -> [MemorizationTargetRow] {
        let statement = try AndroidDatabaseBackupSQLite.prepare(
            """
            SELECT id, kjvOrdinalStart, kjvOrdinalEnd, createdAt
            FROM MemorizationTarget
            ORDER BY createdAt DESC, kjvOrdinalStart, kjvOrdinalEnd;
            """,
            on: database,
            fileName: fileName
        )
        defer { sqlite3_finalize(statement) }

        var rows: [MemorizationTargetRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
            }
            let range = try validatedKJVARange(
                startOrdinal: AndroidDatabaseBackupSQLite.int(statement, column: 1),
                endOrdinal: AndroidDatabaseBackupSQLite.int(statement, column: 2),
                fileName: fileName
            )
            rows.append(
                MemorizationTargetRow(
                    id: try AndroidDatabaseBackupSQLite.uuidFromBlob(statement, column: 0, fileName: fileName),
                    bookInitials: range.bookInitials,
                    startOrdinal: range.startOrdinal,
                    endOrdinal: range.endOrdinal,
                    createdAt: AndroidDatabaseBackupSQLite.int64(statement, column: 3),
                    ordinalTrust: PersistedOrdinalTrustPolicy.androidImportMetadata(
                        sourceVersification: "KJVA",
                        sourceOrdinalStart: range.startOrdinal,
                        sourceOrdinalEnd: range.endOrdinal,
                        kjvaOrdinalStart: range.startOrdinal,
                        kjvaOrdinalEnd: range.endOrdinal
                    )
                )
            )
        }
        return rows
    }

    private static func readChapterHistory(
        from database: OpaquePointer,
        fileName: String
    ) throws -> [ReadingProgressHistoryRow] {
        let statement = try AndroidDatabaseBackupSQLite.prepare(
            """
            SELECT id, kjvBookOrdinal, chapter, cycle, readAt, bookInitials, source
            FROM ChapterReadHistory
            ORDER BY readAt, id;
            """,
            on: database,
            fileName: fileName
        )
        defer { sqlite3_finalize(statement) }

        var rows: [ReadingProgressHistoryRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                break
            }
            guard result == SQLITE_ROW else {
                throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
            }
            let kjvBookOrdinal = AndroidDatabaseBackupSQLite.int(statement, column: 1)
            let chapter = AndroidDatabaseBackupSQLite.int(statement, column: 2)
            guard let identity = ReadingProgressKJVAIdentity(
                androidKJVBookOrdinal: kjvBookOrdinal,
                chapter: chapter
            ) else {
                throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
            }
            let cycle = AndroidDatabaseBackupSQLite.int(statement, column: 3)
            let sourceValue = try requiredUTF8Text(
                statement,
                column: 6,
                maximumByteCount: 32,
                fileName: fileName
            )
            guard cycle >= 0,
                  let source = ReadingProgressSource(rawValue: sourceValue) else {
                throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
            }
            rows.append(
                ReadingProgressHistoryRow(
                    id: try AndroidDatabaseBackupSQLite.uuidFromBlob(statement, column: 0, fileName: fileName),
                    bookInitials: try requiredUTF8Text(
                        statement,
                        column: 5,
                        maximumByteCount: 4_096,
                        fileName: fileName
                    ),
                    identity: identity,
                    cycle: cycle,
                    readAt: AndroidDatabaseBackupSQLite.int64(statement, column: 4),
                    source: source
                )
            )
        }
        return rows
    }

    private static func readGlobalSettings(
        from database: OpaquePointer,
        fileName: String
    ) throws -> ReadingProgressSettingsSnapshot {
        let statement = try AndroidDatabaseBackupSQLite.prepare(
            """
            SELECT autoTrackReading,
                   autoMarkMemorized,
                   memorizeTypeFullWords,
                   memorizeWordVisibility,
                   memorizeErrorHeatmap,
                   memorizeScrambleHideUsed,
                   memorizeIncludeReference,
                   activeCycle
            FROM GlobalReadingProgressSettings
            LIMIT 1;
            """,
            on: database,
            fileName: fileName
        )
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            return ReadingProgressSettingsSnapshot()
        }
        guard result == SQLITE_ROW else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        let activeCycle = AndroidDatabaseBackupSQLite.int(statement, column: 7)
        let visibility = try requiredUTF8Text(
            statement,
            column: 3,
            maximumByteCount: 16,
            fileName: fileName
        )
        guard activeCycle >= 0,
              ReadingProgressSettingsSnapshot.isValidWordVisibility(visibility) else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        return ReadingProgressSettingsSnapshot(
            autoTrackReading: AndroidDatabaseBackupSQLite.bool(statement, column: 0),
            activeCycle: activeCycle,
            autoMarkMemorized: AndroidDatabaseBackupSQLite.bool(statement, column: 1),
            memorizeTypeFullWords: AndroidDatabaseBackupSQLite.bool(statement, column: 2),
            memorizeWordVisibility: visibility,
            memorizeErrorHeatmap: AndroidDatabaseBackupSQLite.bool(statement, column: 4),
            memorizeScrambleHideUsed: AndroidDatabaseBackupSQLite.bool(statement, column: 5),
            memorizeIncludeReference: AndroidDatabaseBackupSQLite.bool(statement, column: 6)
        )
    }

    /**
     Decodes one required bounded SQLite text cell without C-string truncation or replacement.

     - Parameters:
       - statement: Active statement positioned on a row.
       - column: Zero-based required text column.
       - maximumByteCount: Maximum UTF-8 bytes admitted by the Progress wire contract.
       - fileName: Backup section name used by the public error contract.
     - Returns: Exact UTF-8 string, including embedded NUL scalars when present.
     - Side effects: Copies at most `maximumByteCount` bytes from SQLite.
     - Throws: `invalidSQLiteDatabase` for the wrong storage type, oversize bytes, or invalid UTF-8.
     */
    private static func requiredUTF8Text(
        _ statement: OpaquePointer?,
        column: Int32,
        maximumByteCount: Int,
        fileName: String
    ) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount >= 0, byteCount <= maximumByteCount else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        if byteCount == 0 { return "" }
        guard let bytes = sqlite3_column_text(statement, column),
              let value = String(
                  data: Data(bytes: bytes, count: byteCount),
                  encoding: .utf8
              ) else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        return value
    }

    private static func insertMemorizedVerse(
        _ verse: MemorizedVerseProgress,
        into database: OpaquePointer,
        fileName: String
    ) throws {
        let statement = try AndroidDatabaseBackupSQLite.prepare(
            "INSERT INTO MemorizedVerse (id, kjvOrdinal, memorizedAt) VALUES (?, ?, ?);",
            on: database,
            fileName: fileName
        )
        defer { sqlite3_finalize(statement) }
        AndroidDatabaseBackupSQLite.bindUUIDBlob(verse.id, to: statement, index: 1)
        sqlite3_bind_int(
            statement,
            2,
            try RemoteSyncWireInteger.int32(exactly: verse.kjvOrdinal, field: "MemorizedVerse.kjvOrdinal")
        )
        sqlite3_bind_int64(statement, 3, verse.memorizedAt)
        try AndroidDatabaseBackupSQLite.stepDone(statement, fileName: fileName)
    }

    private static func insertMemorizationTarget(
        _ row: MemorizationTargetRow,
        into database: OpaquePointer,
        fileName: String
    ) throws {
        let statement = try AndroidDatabaseBackupSQLite.prepare(
            "INSERT INTO MemorizationTarget (id, kjvOrdinalStart, kjvOrdinalEnd, createdAt) VALUES (?, ?, ?, ?);",
            on: database,
            fileName: fileName
        )
        defer { sqlite3_finalize(statement) }
        AndroidDatabaseBackupSQLite.bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_int(
            statement,
            2,
            try RemoteSyncWireInteger.int32(
                exactly: row.startOrdinal,
                field: "MemorizationTarget.kjvOrdinalStart"
            )
        )
        sqlite3_bind_int(
            statement,
            3,
            try RemoteSyncWireInteger.int32(
                exactly: row.endOrdinal,
                field: "MemorizationTarget.kjvOrdinalEnd"
            )
        )
        sqlite3_bind_int64(statement, 4, row.createdAt)
        try AndroidDatabaseBackupSQLite.stepDone(statement, fileName: fileName)
    }

    private static func insertChapterHistory(
        _ row: ReadingProgressHistoryRow,
        into database: OpaquePointer,
        fileName: String
    ) throws {
        let statement = try AndroidDatabaseBackupSQLite.prepare(
            """
            INSERT INTO ChapterReadHistory (
                id,
                kjvBookOrdinal,
                chapter,
                cycle,
                readAt,
                bookInitials,
                source
            ) VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            on: database,
            fileName: fileName
        )
        defer { sqlite3_finalize(statement) }
        AndroidDatabaseBackupSQLite.bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_int(
            statement,
            2,
            try RemoteSyncWireInteger.int32(
                exactly: row.kjvBookOrdinal,
                field: "ChapterReadHistory.kjvBookOrdinal"
            )
        )
        sqlite3_bind_int(
            statement,
            3,
            try RemoteSyncWireInteger.int32(
                exactly: row.chapter,
                field: "ChapterReadHistory.chapter"
            )
        )
        sqlite3_bind_int(
            statement,
            4,
            try RemoteSyncWireInteger.int32(
                exactly: row.cycle,
                field: "ChapterReadHistory.cycle"
            )
        )
        sqlite3_bind_int64(statement, 5, row.readAt)
        AndroidDatabaseBackupSQLite.bindText(row.bookInitials, to: statement, index: 6)
        AndroidDatabaseBackupSQLite.bindText(row.source.rawValue, to: statement, index: 7)
        try AndroidDatabaseBackupSQLite.stepDone(statement, fileName: fileName)
    }

    private static func insertGlobalSettings(
        _ settings: ReadingProgressSettingsSnapshot,
        into database: OpaquePointer,
        fileName: String
    ) throws {
        let statement = try AndroidDatabaseBackupSQLite.prepare(
            """
            INSERT INTO GlobalReadingProgressSettings (
                id,
                autoTrackReading,
                autoMarkMemorized,
                memorizeTypeFullWords,
                memorizeWordVisibility,
                memorizeErrorHeatmap,
                memorizeScrambleHideUsed,
                memorizeIncludeReference,
                activeCycle
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            on: database,
            fileName: fileName
        )
        defer { sqlite3_finalize(statement) }
        AndroidDatabaseBackupSQLite.bindUUIDBlob(singletonSettingsID, to: statement, index: 1)
        AndroidDatabaseBackupSQLite.bindBool(settings.autoTrackReading, to: statement, index: 2)
        AndroidDatabaseBackupSQLite.bindBool(settings.autoMarkMemorized, to: statement, index: 3)
        AndroidDatabaseBackupSQLite.bindBool(settings.memorizeTypeFullWords, to: statement, index: 4)
        AndroidDatabaseBackupSQLite.bindText(settings.memorizeWordVisibility, to: statement, index: 5)
        AndroidDatabaseBackupSQLite.bindBool(settings.memorizeErrorHeatmap, to: statement, index: 6)
        AndroidDatabaseBackupSQLite.bindBool(settings.memorizeScrambleHideUsed, to: statement, index: 7)
        AndroidDatabaseBackupSQLite.bindBool(settings.memorizeIncludeReference, to: statement, index: 8)
        sqlite3_bind_int(
            statement,
            9,
            try RemoteSyncWireInteger.int32(
                exactly: settings.activeCycle,
                field: "GlobalReadingProgressSettings.activeCycle"
            )
        )
        try AndroidDatabaseBackupSQLite.stepDone(statement, fileName: fileName)
    }

    /**
     Validates a stored Android progress ordinal against JSword's KJVA address space.

     - Parameters:
       - ordinal: Raw `kjvOrdinal` value read from Android `progress.sqlite3`.
       - fileName: Database file name used for section-level error reporting.
     - Returns: The original ordinal when it is inside Android's KJVA domain.
     - Side effects: none.
     - Failure modes: Throws `invalidSQLiteDatabase` when a user-supplied backup contains an
       ordinal Android cannot normally create through JSword-backed progress flows.
     */
    private static func validatedKJVAOrdinal(_ ordinal: Int, fileName: String) throws -> Int {
        guard jswordKJVAOrdinalRange.contains(ordinal) else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        return ordinal
    }

    /**
     Validates and builds an Android global memorization range.

     Android stores memorization target endpoints as KJVA ordinals. The row is accepted only when
     both endpoints are inside JSword's KJVA domain and the end is not before the start.

     - Parameters:
       - startOrdinal: Raw `kjvOrdinalStart` value from Android `MemorizationTarget`.
       - endOrdinal: Raw `kjvOrdinalEnd` value from Android `MemorizationTarget`.
       - fileName: Database file name used for section-level error reporting.
     - Returns: A global iOS memorization range with empty `bookInitials`.
     - Side effects: none.
     - Failure modes: Throws `invalidSQLiteDatabase` for out-of-domain or reversed ranges.
     */
    private static func validatedKJVARange(
        startOrdinal: Int,
        endOrdinal: Int,
        fileName: String
    ) throws -> MemorizationProgressRange {
        guard endOrdinal >= startOrdinal else {
            throw AndroidDatabaseBackupError.invalidSQLiteDatabase(fileName)
        }
        return MemorizationProgressRange(
            bookInitials: "",
            startOrdinal: try validatedKJVAOrdinal(startOrdinal, fileName: fileName),
            endOrdinal: try validatedKJVAOrdinal(endOrdinal, fileName: fileName)
        )
    }

    /**
     Checks whether a local memorization range can be represented in Android's progress database.

     - Parameter range: Local iOS memorization range.
     - Returns: `true` when the endpoints are ordered and inside JSword's KJVA ordinal domain.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func isKJVAOrdinalRange(_ range: MemorizationProgressRange) -> Bool {
        jswordKJVAOrdinalRange.contains(range.startOrdinal) &&
            jswordKJVAOrdinalRange.contains(range.endOrdinal) &&
            range.endOrdinal >= range.startOrdinal
    }

    /**
     Filters and de-duplicates memorized verse rows for Android export.

     Android's `MemorizedVerse` table has a unique KJVA ordinal index and no module identity. If a
     legacy iOS snapshot contains multiple module-scoped rows for the same ordinal, export keeps one
     global Android row with the newest timestamp instead of inventing multiple Android rows.

     - Parameter verses: Local memorized verse rows from the persisted snapshot.
     - Returns: Sorted global Android rows whose ordinals fit JSword's KJVA domain.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func exportableMemorizedVerses(
        in verses: [MemorizedVerseProgress]
    ) -> [MemorizedVerseProgress] {
        var rowByOrdinal: [Int: MemorizedVerseProgress] = [:]
        for verse in verses where verse.hasTrustedPersistedOrdinals && jswordKJVAOrdinalRange.contains(verse.kjvOrdinal) {
            let existing = rowByOrdinal[verse.kjvOrdinal]
            guard existing == nil || (existing?.memorizedAt ?? 0) < verse.memorizedAt else {
                continue
            }
            rowByOrdinal[verse.kjvOrdinal] = MemorizedVerseProgress(
                id: verse.id,
                bookInitials: "",
                kjvOrdinal: verse.kjvOrdinal,
                memorizedAt: verse.memorizedAt,
                ordinalTrust: verse.ordinalTrust
            )
        }
        return rowByOrdinal.values.sorted { $0.kjvOrdinal < $1.kjvOrdinal }
    }

    /**
     Filters memorization target rows for Android export without collapsing duplicates.

     Android stores target rows independently, so duplicate ranges remain separate rows and target
     totals count them independently. The only export filter is KJVA-domain validity.

     - Parameter rows: Local target rows from the persisted snapshot.
     - Returns: Rows whose endpoints fit Android's JSword KJVA ordinal domain.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func exportableMemorizationTargets(
        in rows: [MemorizationTargetRow]
    ) -> [MemorizationTargetRow] {
        rows.filter { $0.hasTrustedPersistedOrdinals && isKJVAOrdinalRange($0.range) }
    }

}
