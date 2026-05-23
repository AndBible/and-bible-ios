// ReadingProgressStore.swift - Local chapter reading-progress persistence

import Foundation

public enum ReadingProgressSource: String, Codable, Equatable, Hashable {
    case manual = "MANUAL"
    case autoScroll = "AUTO_SCROLL"
    case autoTts = "AUTO_TTS"

    public init(bridgeValue: String) {
        self = Self(rawValue: bridgeValue.uppercased()) ?? .manual
    }
}

public struct ReadingProgressHistoryRow: Codable, Equatable, Hashable {
    public let id: UUID
    public let bookInitials: String
    public let startOrdinal: Int
    public let kjvBookOrdinal: Int
    public let chapter: Int
    public let cycle: Int
    public let readAt: Int64
    public let source: ReadingProgressSource

    public init(
        id: UUID = UUID(),
        bookInitials: String,
        startOrdinal: Int,
        kjvBookOrdinal: Int,
        chapter: Int,
        cycle: Int,
        readAt: Int64,
        source: ReadingProgressSource
    ) {
        self.id = id
        self.bookInitials = bookInitials
        self.startOrdinal = startOrdinal
        self.kjvBookOrdinal = kjvBookOrdinal
        self.chapter = chapter
        self.cycle = cycle
        self.readAt = readAt
        self.source = source
    }
}

public struct ReadingProgressSettingsSnapshot: Codable, Equatable {
    public var autoTrackReading: Bool
    public var activeCycle: Int
    public var autoMarkMemorized: Bool
    public var memorizeTypeFullWords: Bool
    public var memorizeWordVisibility: String
    public var memorizeErrorHeatmap: Bool
    public var memorizeScrambleHideUsed: Bool
    public var memorizeIncludeReference: Bool

    public init(
        autoTrackReading: Bool = false,
        activeCycle: Int = 0,
        autoMarkMemorized: Bool = true,
        memorizeTypeFullWords: Bool = false,
        memorizeWordVisibility: String = "light",
        memorizeErrorHeatmap: Bool = true,
        memorizeScrambleHideUsed: Bool = false,
        memorizeIncludeReference: Bool = true
    ) {
        self.autoTrackReading = autoTrackReading
        self.activeCycle = max(0, activeCycle)
        self.autoMarkMemorized = autoMarkMemorized
        self.memorizeTypeFullWords = memorizeTypeFullWords
        self.memorizeWordVisibility = memorizeWordVisibility
        self.memorizeErrorHeatmap = memorizeErrorHeatmap
        self.memorizeScrambleHideUsed = memorizeScrambleHideUsed
        self.memorizeIncludeReference = memorizeIncludeReference
    }
}

public struct ReadingProgressSnapshot: Codable, Equatable {
    public var history: [ReadingProgressHistoryRow]
    public var settings: ReadingProgressSettingsSnapshot

    public init(
        history: [ReadingProgressHistoryRow] = [],
        settings: ReadingProgressSettingsSnapshot = ReadingProgressSettingsSnapshot()
    ) {
        self.history = history
        self.settings = settings
    }
}

/**
 * Local store for Android-compatible chapter reading progress.
 *
 * The store keeps append-only chapter-read history in `SettingsStore` JSON so the first bridge
 * mutation slice can persist real native state without introducing a SwiftData migration. Remote
 * Android `progress` sync and fuller KJVA migration semantics remain separate #73 work.
 */
public final class ReadingProgressStore {
    public static let settingsKey = "reading_progress_state_v1"

    private let settingsStore: SettingsStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    public func snapshot() -> ReadingProgressSnapshot {
        guard let rawValue = settingsStore.getString(Self.settingsKey),
              let data = rawValue.data(using: .utf8),
              let snapshot = try? decoder.decode(ReadingProgressSnapshot.self, from: data) else {
            return ReadingProgressSnapshot()
        }
        return Self.normalized(snapshot)
    }

    public func currentCycle() -> Int {
        Self.currentCycle(in: snapshot())
    }

    @discardableResult
    public func recordChapterRead(
        bookInitials: String,
        startOrdinal: Int,
        kjvBookOrdinal: Int,
        chapter: Int,
        source: ReadingProgressSource,
        readAt: Int64? = nil
    ) -> Int {
        guard Self.isValid(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            kjvBookOrdinal: kjvBookOrdinal,
            chapter: chapter
        ) else {
            return chapterReadCount(kjvBookOrdinal: kjvBookOrdinal, chapter: chapter)
        }

        var snapshot = snapshot()
        let cycle = Self.currentCycle(in: snapshot)
        let recordedAt = readAt ?? Self.currentTimeMilliseconds()
        snapshot.history.append(
            ReadingProgressHistoryRow(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                kjvBookOrdinal: kjvBookOrdinal,
                chapter: chapter,
                cycle: cycle,
                readAt: recordedAt,
                source: source
            )
        )
        let savedSnapshot = save(snapshot)
        return Self.chapterReadCount(in: savedSnapshot, kjvBookOrdinal: kjvBookOrdinal, chapter: chapter)
    }

    @discardableResult
    public func clearChapterReadStatus(kjvBookOrdinal: Int, chapter: Int) -> Int {
        guard kjvBookOrdinal > 0, chapter > 0 else { return 0 }
        var snapshot = snapshot()
        let cycle = Self.currentCycle(in: snapshot)
        snapshot.history.removeAll { row in
            row.kjvBookOrdinal == kjvBookOrdinal &&
                row.chapter == chapter &&
                row.cycle == cycle
        }
        let savedSnapshot = save(snapshot)
        return Self.chapterReadCount(in: savedSnapshot, kjvBookOrdinal: kjvBookOrdinal, chapter: chapter)
    }

    public func chapterReadCount(kjvBookOrdinal: Int, chapter: Int) -> Int {
        Self.chapterReadCount(in: snapshot(), kjvBookOrdinal: kjvBookOrdinal, chapter: chapter)
    }

    @discardableResult
    private func save(_ snapshot: ReadingProgressSnapshot) -> ReadingProgressSnapshot {
        let normalized = Self.normalized(snapshot)
        guard let data = try? encoder.encode(normalized),
              let rawValue = String(data: data, encoding: .utf8) else {
            return normalized
        }
        settingsStore.setString(Self.settingsKey, value: rawValue)
        return normalized
    }

    private static func chapterReadCount(
        in snapshot: ReadingProgressSnapshot,
        kjvBookOrdinal: Int,
        chapter: Int
    ) -> Int {
        let cycle = Self.currentCycle(in: snapshot)
        return snapshot.history.filter { row in
            row.kjvBookOrdinal == kjvBookOrdinal &&
                row.chapter == chapter &&
                row.cycle == cycle
        }.count
    }

    private static func currentCycle(in snapshot: ReadingProgressSnapshot) -> Int {
        if snapshot.settings.activeCycle > 0 {
            return snapshot.settings.activeCycle
        }
        return snapshot.history.map(\.cycle).max() ?? 1
    }

    private static func normalized(_ snapshot: ReadingProgressSnapshot) -> ReadingProgressSnapshot {
        let history = snapshot.history
            .filter {
                isValid(
                    bookInitials: $0.bookInitials,
                    startOrdinal: $0.startOrdinal,
                    kjvBookOrdinal: $0.kjvBookOrdinal,
                    chapter: $0.chapter
                ) && $0.cycle > 0
            }
            .sorted {
                if $0.readAt != $1.readAt {
                    return $0.readAt < $1.readAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
        return ReadingProgressSnapshot(
            history: history,
            settings: ReadingProgressSettingsSnapshot(
                autoTrackReading: snapshot.settings.autoTrackReading,
                activeCycle: snapshot.settings.activeCycle,
                autoMarkMemorized: snapshot.settings.autoMarkMemorized,
                memorizeTypeFullWords: snapshot.settings.memorizeTypeFullWords,
                memorizeWordVisibility: snapshot.settings.memorizeWordVisibility,
                memorizeErrorHeatmap: snapshot.settings.memorizeErrorHeatmap,
                memorizeScrambleHideUsed: snapshot.settings.memorizeScrambleHideUsed,
                memorizeIncludeReference: snapshot.settings.memorizeIncludeReference
            )
        )
    }

    private static func isValid(
        bookInitials: String,
        startOrdinal: Int,
        kjvBookOrdinal: Int,
        chapter: Int
    ) -> Bool {
        !bookInitials.isEmpty && startOrdinal > 0 && kjvBookOrdinal > 0 && chapter > 0
    }

    private static func currentTimeMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    }
}
