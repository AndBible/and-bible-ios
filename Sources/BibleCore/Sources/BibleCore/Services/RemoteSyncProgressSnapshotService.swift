// RemoteSyncProgressSnapshotService.swift - Android-shaped local progress snapshots for remote sync

import CryptoKit
import Foundation

/**
 Current local representation of one Android `MemorizedVerse` row.
 */
public struct RemoteSyncCurrentProgressMemorizedVerseRow: Sendable, Equatable, Codable {
    public let id: UUID
    public let kjvOrdinal: Int
    public let memorizedAt: Int64

    public init(id: UUID, kjvOrdinal: Int, memorizedAt: Int64) {
        self.id = id
        self.kjvOrdinal = kjvOrdinal
        self.memorizedAt = memorizedAt
    }
}

/**
 Current local representation of one Android `ChapterReadHistory` row.
 */
public struct RemoteSyncCurrentProgressChapterReadHistoryRow: Sendable, Equatable, Codable {
    public let id: UUID
    public let kjvBookOrdinal: Int
    public let chapter: Int
    public let cycle: Int
    public let readAt: Int64
    public let bookInitials: String
    public let source: ReadingProgressSource

    public init(
        id: UUID,
        kjvBookOrdinal: Int,
        chapter: Int,
        cycle: Int,
        readAt: Int64,
        bookInitials: String,
        source: ReadingProgressSource
    ) {
        self.id = id
        self.kjvBookOrdinal = kjvBookOrdinal
        self.chapter = chapter
        self.cycle = cycle
        self.readAt = readAt
        self.bookInitials = bookInitials
        self.source = source
    }
}

/**
 Current local representation of one Android `MemorizationTarget` row.
 */
public struct RemoteSyncCurrentProgressMemorizationTargetRow: Sendable, Equatable, Codable {
    public let id: UUID
    public let kjvOrdinalStart: Int
    public let kjvOrdinalEnd: Int
    public let createdAt: Int64

    public init(id: UUID, kjvOrdinalStart: Int, kjvOrdinalEnd: Int, createdAt: Int64) {
        self.id = id
        self.kjvOrdinalStart = kjvOrdinalStart
        self.kjvOrdinalEnd = kjvOrdinalEnd
        self.createdAt = createdAt
    }
}

/**
 Current local representation of Android's singleton `GlobalReadingProgressSettings` row.
 */
public struct RemoteSyncCurrentProgressSettingsRow: Sendable, Equatable, Codable {
    public let id: UUID
    public let autoTrackReading: Bool
    public let autoMarkMemorized: Bool
    public let memorizeTypeFullWords: Bool
    public let memorizeWordVisibility: String
    public let memorizeErrorHeatmap: Bool
    public let memorizeScrambleHideUsed: Bool
    public let memorizeIncludeReference: Bool
    public let activeCycle: Int

    public init(id: UUID, settings: ReadingProgressSettingsSnapshot) {
        self.id = id
        self.autoTrackReading = settings.autoTrackReading
        self.autoMarkMemorized = settings.autoMarkMemorized
        self.memorizeTypeFullWords = settings.memorizeTypeFullWords
        self.memorizeWordVisibility = settings.memorizeWordVisibility
        self.memorizeErrorHeatmap = settings.memorizeErrorHeatmap
        self.memorizeScrambleHideUsed = settings.memorizeScrambleHideUsed
        self.memorizeIncludeReference = settings.memorizeIncludeReference
        self.activeCycle = settings.activeCycle
    }

    public var settings: ReadingProgressSettingsSnapshot {
        ReadingProgressSettingsSnapshot(
            autoTrackReading: autoTrackReading,
            activeCycle: activeCycle,
            autoMarkMemorized: autoMarkMemorized,
            memorizeTypeFullWords: memorizeTypeFullWords,
            memorizeWordVisibility: memorizeWordVisibility,
            memorizeErrorHeatmap: memorizeErrorHeatmap,
            memorizeScrambleHideUsed: memorizeScrambleHideUsed,
            memorizeIncludeReference: memorizeIncludeReference
        )
    }
}

/**
 Snapshot of local reading and memorization progress expressed as Android progress rows.
 */
public struct RemoteSyncProgressCurrentSnapshot: Sendable, Equatable {
    public let memorizedVerseRowsByKey: [String: RemoteSyncCurrentProgressMemorizedVerseRow]
    public let chapterHistoryRowsByKey: [String: RemoteSyncCurrentProgressChapterReadHistoryRow]
    public let memorizationTargetRowsByKey: [String: RemoteSyncCurrentProgressMemorizationTargetRow]
    public let settingsRowsByKey: [String: RemoteSyncCurrentProgressSettingsRow]
    public let fingerprintsByKey: [String: String]

    public init(
        memorizedVerseRowsByKey: [String: RemoteSyncCurrentProgressMemorizedVerseRow],
        chapterHistoryRowsByKey: [String: RemoteSyncCurrentProgressChapterReadHistoryRow],
        memorizationTargetRowsByKey: [String: RemoteSyncCurrentProgressMemorizationTargetRow],
        settingsRowsByKey: [String: RemoteSyncCurrentProgressSettingsRow],
        fingerprintsByKey: [String: String]
    ) {
        self.memorizedVerseRowsByKey = memorizedVerseRowsByKey
        self.chapterHistoryRowsByKey = chapterHistoryRowsByKey
        self.memorizationTargetRowsByKey = memorizationTargetRowsByKey
        self.settingsRowsByKey = settingsRowsByKey
        self.fingerprintsByKey = fingerprintsByKey
    }

    public func containsRow(for key: String) -> Bool {
        memorizedVerseRowsByKey[key] != nil ||
            chapterHistoryRowsByKey[key] != nil ||
            memorizationTargetRowsByKey[key] != nil ||
            settingsRowsByKey[key] != nil
    }
}

/**
 Projects local progress JSON snapshots into Android's `progress.sqlite3` row model.

 Android sync treats Progress as a normal database with UUID-keyed rows in
 `MemorizedVerse`, `ChapterReadHistory`, `MemorizationTarget`, and
 `GlobalReadingProgressSettings`. iOS stores the same user-facing state in JSON-backed stores, so
 this service provides the Android-shaped row projection and content fingerprints needed by remote
 patch upload and baseline refresh.
 */
public final class RemoteSyncProgressSnapshotService {
    public static let memorizedVerseTable = "MemorizedVerse"
    public static let chapterReadHistoryTable = "ChapterReadHistory"
    public static let memorizationTargetTable = "MemorizationTarget"
    public static let globalSettingsTable = "GlobalReadingProgressSettings"
    public static let globalSettingsID = UUID(uuidString: "b2000000-0000-0000-0000-000000000001")!

    private static let progressOrdinalRange = JSwordKJVAVersification.progressOrdinalRange

    public init() {}

    /**
     Projects current local progress into Android-shaped rows and row fingerprints.

     - Parameter settingsStore: Local-only settings store containing progress JSON payloads.
     - Returns: Current Android progress rows keyed by Android `LogEntry` identity.
     - Side effects: reads local progress snapshots.
     - Failure modes: malformed local JSON is treated as the stores' default empty snapshots.
     */
    public func snapshotCurrentState(settingsStore: SettingsStore) -> RemoteSyncProgressCurrentSnapshot {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let readingSnapshot = ReadingProgressStore(settingsStore: settingsStore).snapshot()
        let memorizationSnapshot = MemorizationProgressStore(settingsStore: settingsStore).snapshot()

        var memorizedVerseRowsByKey: [String: RemoteSyncCurrentProgressMemorizedVerseRow] = [:]
        var chapterHistoryRowsByKey: [String: RemoteSyncCurrentProgressChapterReadHistoryRow] = [:]
        var memorizationTargetRowsByKey: [String: RemoteSyncCurrentProgressMemorizationTargetRow] = [:]
        var settingsRowsByKey: [String: RemoteSyncCurrentProgressSettingsRow] = [:]
        var fingerprintsByKey: [String: String] = [:]

        for row in Self.exportableMemorizedVerses(in: memorizationSnapshot.memorizedVerses) {
            let key = key(for: Self.memorizedVerseTable, id: row.id, logEntryStore: logEntryStore)
            memorizedVerseRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        for row in Self.exportableChapterHistory(in: readingSnapshot.history) {
            let key = key(for: Self.chapterReadHistoryTable, id: row.id, logEntryStore: logEntryStore)
            chapterHistoryRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        for row in Self.exportableTargets(in: memorizationSnapshot.targetRows) {
            let key = key(for: Self.memorizationTargetTable, id: row.id, logEntryStore: logEntryStore)
            memorizationTargetRowsByKey[key] = row
            fingerprintsByKey[key] = Self.fingerprintHex(for: row)
        }

        let settingsRow = RemoteSyncCurrentProgressSettingsRow(
            id: Self.globalSettingsID,
            settings: readingSnapshot.settings
        )
        let settingsKey = key(for: Self.globalSettingsTable, id: settingsRow.id, logEntryStore: logEntryStore)
        settingsRowsByKey[settingsKey] = settingsRow
        fingerprintsByKey[settingsKey] = Self.fingerprintHex(for: settingsRow)

        return RemoteSyncProgressCurrentSnapshot(
            memorizedVerseRowsByKey: memorizedVerseRowsByKey,
            chapterHistoryRowsByKey: chapterHistoryRowsByKey,
            memorizationTargetRowsByKey: memorizationTargetRowsByKey,
            settingsRowsByKey: settingsRowsByKey,
            fingerprintsByKey: fingerprintsByKey
        )
    }

    /**
     Replaces stored Progress row fingerprints with the current local Android-shaped snapshot.

     - Parameter settingsStore: Local-only settings store backing progress and fingerprint rows.
     - Side effects: clears and rewrites `.progress` row fingerprints.
     - Failure modes: underlying settings persistence is best-effort and swallows save failures.
     */
    public func refreshBaselineFingerprints(settingsStore: SettingsStore) {
        let snapshot = snapshotCurrentState(settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        fingerprintStore.clearCategory(.progress)

        for row in snapshot.memorizedVerseRowsByKey.values {
            setFingerprint(
                snapshot.fingerprintsByKey,
                tableName: Self.memorizedVerseTable,
                id: row.id,
                logEntryStore: logEntryStore,
                fingerprintStore: fingerprintStore
            )
        }
        for row in snapshot.chapterHistoryRowsByKey.values {
            setFingerprint(
                snapshot.fingerprintsByKey,
                tableName: Self.chapterReadHistoryTable,
                id: row.id,
                logEntryStore: logEntryStore,
                fingerprintStore: fingerprintStore
            )
        }
        for row in snapshot.memorizationTargetRowsByKey.values {
            setFingerprint(
                snapshot.fingerprintsByKey,
                tableName: Self.memorizationTargetTable,
                id: row.id,
                logEntryStore: logEntryStore,
                fingerprintStore: fingerprintStore
            )
        }
        for row in snapshot.settingsRowsByKey.values {
            setFingerprint(
                snapshot.fingerprintsByKey,
                tableName: Self.globalSettingsTable,
                id: row.id,
                logEntryStore: logEntryStore,
                fingerprintStore: fingerprintStore
            )
        }
    }

    /**
     Builds Android `LogEntry` rows that describe the accepted current Progress baseline.

     Initial backups are full snapshots, but later sparse DELETE patches still need a remembered
     key set for rows that existed in that baseline. Android carries that through `LogEntry`; iOS
     mirrors it here so deleting a row after an iOS-created Progress baseline emits a DELETE patch.

     - Parameters:
       - settingsStore: Local-only settings store containing the progress JSON payloads.
       - sourceDevice: Android source-device name to record on the baseline entries.
       - lastUpdated: Millisecond timestamp assigned to each baseline entry.
     - Returns: Android-compatible upsert `LogEntry` rows for every current Progress row.
     - Side effects: reads local progress snapshots.
     - Failure modes: malformed local JSON is treated as the stores' default empty snapshots.
     */
    public func acceptedBaselineLogEntries(
        settingsStore: SettingsStore,
        sourceDevice: String,
        lastUpdated: Int64
    ) -> [RemoteSyncLogEntry] {
        let snapshot = snapshotCurrentState(settingsStore: settingsStore)
        var entries: [RemoteSyncLogEntry] = []
        entries += snapshot.memorizedVerseRowsByKey.values.map {
            baselineLogEntry(
                tableName: Self.memorizedVerseTable,
                id: $0.id,
                sourceDevice: sourceDevice,
                lastUpdated: lastUpdated
            )
        }
        entries += snapshot.chapterHistoryRowsByKey.values.map {
            baselineLogEntry(
                tableName: Self.chapterReadHistoryTable,
                id: $0.id,
                sourceDevice: sourceDevice,
                lastUpdated: lastUpdated
            )
        }
        entries += snapshot.memorizationTargetRowsByKey.values.map {
            baselineLogEntry(
                tableName: Self.memorizationTargetTable,
                id: $0.id,
                sourceDevice: sourceDevice,
                lastUpdated: lastUpdated
            )
        }
        entries += snapshot.settingsRowsByKey.values.map {
            baselineLogEntry(
                tableName: Self.globalSettingsTable,
                id: $0.id,
                sourceDevice: sourceDevice,
                lastUpdated: lastUpdated
            )
        }
        return entries.sorted(by: Self.logEntrySort)
    }

    private func key(
        for tableName: String,
        id: UUID,
        logEntryStore: RemoteSyncLogEntryStore
    ) -> String {
        logEntryStore.key(
            for: .progress,
            tableName: tableName,
            entityID1: .blob(Self.uuidBlob(id)),
            entityID2: .text("")
        )
    }

    private func setFingerprint(
        _ fingerprintsByKey: [String: String],
        tableName: String,
        id: UUID,
        logEntryStore: RemoteSyncLogEntryStore,
        fingerprintStore: RemoteSyncRowFingerprintStore
    ) {
        let key = logEntryStore.key(
            for: .progress,
            tableName: tableName,
            entityID1: .blob(Self.uuidBlob(id)),
            entityID2: .text("")
        )
        guard let fingerprint = fingerprintsByKey[key] else { return }
        fingerprintStore.setFingerprint(
            fingerprint,
            for: .progress,
            tableName: tableName,
            entityID1: .blob(Self.uuidBlob(id)),
            entityID2: .text("")
        )
    }

    private func baselineLogEntry(
        tableName: String,
        id: UUID,
        sourceDevice: String,
        lastUpdated: Int64
    ) -> RemoteSyncLogEntry {
        RemoteSyncLogEntry(
            tableName: tableName,
            entityID1: .blob(Self.uuidBlob(id)),
            entityID2: .text(""),
            type: .upsert,
            lastUpdated: lastUpdated,
            sourceDevice: sourceDevice
        )
    }

    private static func exportableMemorizedVerses(
        in verses: [MemorizedVerseProgress]
    ) -> [RemoteSyncCurrentProgressMemorizedVerseRow] {
        var rowsByOrdinal: [Int: MemorizedVerseProgress] = [:]
        for verse in verses where progressOrdinalRange.contains(verse.kjvOrdinal) {
            guard let existing = rowsByOrdinal[verse.kjvOrdinal] else {
                rowsByOrdinal[verse.kjvOrdinal] = verse
                continue
            }
            if existing.memorizedAt < verse.memorizedAt ||
                (existing.memorizedAt == verse.memorizedAt && existing.id.uuidString > verse.id.uuidString) {
                rowsByOrdinal[verse.kjvOrdinal] = verse
            }
        }
        return rowsByOrdinal.values
            .map {
                RemoteSyncCurrentProgressMemorizedVerseRow(
                    id: $0.id,
                    kjvOrdinal: $0.kjvOrdinal,
                    memorizedAt: $0.memorizedAt
                )
            }
            .sorted { $0.kjvOrdinal < $1.kjvOrdinal }
    }

    private static func exportableChapterHistory(
        in rows: [ReadingProgressHistoryRow]
    ) -> [RemoteSyncCurrentProgressChapterReadHistoryRow] {
        rows
            .filter { $0.kjvBookOrdinal > 0 && $0.chapter > 0 && $0.cycle > 0 }
            .map {
                RemoteSyncCurrentProgressChapterReadHistoryRow(
                    id: $0.id,
                    kjvBookOrdinal: $0.kjvBookOrdinal,
                    chapter: $0.chapter,
                    cycle: $0.cycle,
                    readAt: $0.readAt,
                    bookInitials: $0.bookInitials,
                    source: $0.source
                )
            }
            .sorted {
                if $0.readAt != $1.readAt {
                    return $0.readAt < $1.readAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    private static func exportableTargets(
        in rows: [MemorizationTargetRow]
    ) -> [RemoteSyncCurrentProgressMemorizationTargetRow] {
        rows
            .filter {
                progressOrdinalRange.contains($0.startOrdinal) &&
                    progressOrdinalRange.contains($0.endOrdinal) &&
                    $0.endOrdinal >= $0.startOrdinal
            }
            .map {
                RemoteSyncCurrentProgressMemorizationTargetRow(
                    id: $0.id,
                    kjvOrdinalStart: $0.startOrdinal,
                    kjvOrdinalEnd: $0.endOrdinal,
                    createdAt: $0.createdAt
                )
            }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    static func fingerprintHex(for value: RemoteSyncCurrentProgressMemorizedVerseRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.id.uuidString.lowercased(),
                String(value.kjvOrdinal),
                String(value.memorizedAt),
            ].joined(separator: "|")
        )
    }

    static func fingerprintHex(for value: RemoteSyncCurrentProgressChapterReadHistoryRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.id.uuidString.lowercased(),
                String(value.kjvBookOrdinal),
                String(value.chapter),
                String(value.cycle),
                String(value.readAt),
                value.bookInitials,
                value.source.rawValue,
            ].joined(separator: "|")
        )
    }

    static func fingerprintHex(for value: RemoteSyncCurrentProgressMemorizationTargetRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.id.uuidString.lowercased(),
                String(value.kjvOrdinalStart),
                String(value.kjvOrdinalEnd),
                String(value.createdAt),
            ].joined(separator: "|")
        )
    }

    static func fingerprintHex(for value: RemoteSyncCurrentProgressSettingsRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.id.uuidString.lowercased(),
                value.autoTrackReading ? "1" : "0",
                value.autoMarkMemorized ? "1" : "0",
                value.memorizeTypeFullWords ? "1" : "0",
                value.memorizeWordVisibility,
                value.memorizeErrorHeatmap ? "1" : "0",
                value.memorizeScrambleHideUsed ? "1" : "0",
                value.memorizeIncludeReference ? "1" : "0",
                String(value.activeCycle),
            ].joined(separator: "|")
        )
    }

    private static func fingerprintHex(canonicalValue: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func uuidBlob(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
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
