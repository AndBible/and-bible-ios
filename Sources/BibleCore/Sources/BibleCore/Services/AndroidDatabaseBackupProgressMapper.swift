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
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when the Android
       database cannot be read as schema version 9.
     */
    static func apply(
        from databaseURL: URL,
        mode: AndroidDatabaseBackupApplyMode,
        settingsStore: SettingsStore
    ) throws -> AndroidDatabaseBackupProgressReport {
        let imported = try readSnapshot(from: databaseURL)
        let finalSnapshot: Snapshot
        switch mode {
        case .restore:
            finalSnapshot = imported
        case .import:
            finalSnapshot = mergeForImport(imported: imported, settingsStore: settingsStore)
        }
        try save(finalSnapshot, settingsStore: settingsStore)
        return report(for: finalSnapshot, settingsStore: settingsStore)
    }

    /**
     Writes an Android-compatible `progress.sqlite3` database from current iOS progress state.

     - Parameters:
       - databaseURL: Destination SQLite URL.
       - settingsStore: Local store containing current progress snapshots.
     - Returns: Counts written into the database.
     - Side effects: Creates or replaces the SQLite database file.
     - Failure modes: Throws `AndroidDatabaseBackupError.invalidSQLiteDatabase` when SQLite rejects
       schema creation or row insertion.
     */
    @discardableResult
    static func writeDatabase(
        at databaseURL: URL,
        settingsStore: SettingsStore
    ) throws -> AndroidDatabaseBackupProgressReport {
        let readingSnapshot = ReadingProgressStore(settingsStore: settingsStore).snapshot()
        let memorizationSnapshot = MemorizationProgressStore(settingsStore: settingsStore).snapshot()
        let snapshot = Snapshot(reading: readingSnapshot, memorization: memorizationSnapshot)
        try? FileManager.default.removeItem(at: databaseURL)

        try AndroidDatabaseBackupSQLite.withDatabase(
            at: databaseURL,
            flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        ) { database in
            let fileName = databaseURL.lastPathComponent
            try AndroidDatabaseBackupSQLite.execute(schemaSQL, on: database, fileName: fileName)
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

    private static func readSnapshot(from databaseURL: URL) throws -> Snapshot {
        try AndroidDatabaseBackupSQLite.withDatabase(at: databaseURL) { database in
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

    private static func mergeForImport(imported: Snapshot, settingsStore: SettingsStore) -> Snapshot {
        let localReading = ReadingProgressStore(settingsStore: settingsStore).snapshot()
        let localMemorization = MemorizationProgressStore(settingsStore: settingsStore).snapshot()

        var historyByID = Dictionary(uniqueKeysWithValues: localReading.history.map { ($0.id, $0) })
        for row in imported.reading.history where historyByID[row.id] == nil {
            historyByID[row.id] = row
        }
        let keepLocalReadingSettings = settingsStore.getString(ReadingProgressStore.settingsKey) != nil
        let localMemorizedOrdinals = Set(localMemorization.memorizedVerses.map(\.kjvOrdinal))
        let importedMemorizedVerses = imported.memorization.memorizedVerses.filter {
            !localMemorizedOrdinals.contains($0.kjvOrdinal)
        }
        let localTargetIDs = Set(localMemorization.targetRows.map(\.id))
        let importedTargetRows = imported.memorization.targetRows.filter {
            !localTargetIDs.contains($0.id)
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
                memorizedVerses: localMemorization.memorizedVerses + importedMemorizedVerses,
                targetRows: localMemorization.targetRows + importedTargetRows
            )
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
            "SELECT kjvOrdinal, memorizedAt FROM MemorizedVerse ORDER BY kjvOrdinal;",
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
                AndroidDatabaseBackupSQLite.int(statement, column: 0),
                fileName: fileName
            )
            verses.append(
                MemorizedVerseProgress(
                    bookInitials: "",
                    kjvOrdinal: ordinal,
                    memorizedAt: AndroidDatabaseBackupSQLite.int64(statement, column: 1)
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
                    createdAt: AndroidDatabaseBackupSQLite.int64(statement, column: 3)
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
            rows.append(
                ReadingProgressHistoryRow(
                    id: try AndroidDatabaseBackupSQLite.uuidFromBlob(statement, column: 0, fileName: fileName),
                    bookInitials: AndroidDatabaseBackupSQLite.text(statement, column: 5),
                    startOrdinal: 0,
                    kjvBookOrdinal: AndroidDatabaseBackupSQLite.int(statement, column: 1),
                    chapter: AndroidDatabaseBackupSQLite.int(statement, column: 2),
                    cycle: AndroidDatabaseBackupSQLite.int(statement, column: 3),
                    readAt: AndroidDatabaseBackupSQLite.int64(statement, column: 4),
                    source: ReadingProgressSource(
                        bridgeValue: AndroidDatabaseBackupSQLite.text(statement, column: 6)
                    )
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
        return ReadingProgressSettingsSnapshot(
            autoTrackReading: AndroidDatabaseBackupSQLite.bool(statement, column: 0),
            activeCycle: AndroidDatabaseBackupSQLite.int(statement, column: 7),
            autoMarkMemorized: AndroidDatabaseBackupSQLite.bool(statement, column: 1),
            memorizeTypeFullWords: AndroidDatabaseBackupSQLite.bool(statement, column: 2),
            memorizeWordVisibility: AndroidDatabaseBackupSQLite.text(statement, column: 3),
            memorizeErrorHeatmap: AndroidDatabaseBackupSQLite.bool(statement, column: 4),
            memorizeScrambleHideUsed: AndroidDatabaseBackupSQLite.bool(statement, column: 5),
            memorizeIncludeReference: AndroidDatabaseBackupSQLite.bool(statement, column: 6)
        )
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
        AndroidDatabaseBackupSQLite.bindUUIDBlob(UUID(), to: statement, index: 1)
        sqlite3_bind_int(statement, 2, Int32(verse.kjvOrdinal))
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
        sqlite3_bind_int(statement, 2, Int32(row.startOrdinal))
        sqlite3_bind_int(statement, 3, Int32(row.endOrdinal))
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
        sqlite3_bind_int(statement, 2, Int32(row.kjvBookOrdinal))
        sqlite3_bind_int(statement, 3, Int32(row.chapter))
        sqlite3_bind_int(statement, 4, Int32(row.cycle))
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
        sqlite3_bind_int(statement, 9, Int32(settings.activeCycle))
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
        for verse in verses where jswordKJVAOrdinalRange.contains(verse.kjvOrdinal) {
            let existing = rowByOrdinal[verse.kjvOrdinal]
            guard existing == nil || (existing?.memorizedAt ?? 0) < verse.memorizedAt else {
                continue
            }
            rowByOrdinal[verse.kjvOrdinal] = MemorizedVerseProgress(
                bookInitials: "",
                kjvOrdinal: verse.kjvOrdinal,
                memorizedAt: verse.memorizedAt
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
        rows.filter { isKJVAOrdinalRange($0.range) }
    }

    private static var schemaSQL: String {
        """
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
        CREATE INDEX index_ChapterReadHistory_kjvBookOrdinal_chapter_cycle
            ON ChapterReadHistory (kjvBookOrdinal, chapter, cycle);
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
        PRAGMA user_version = 9;
        """
    }
}
