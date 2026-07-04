// ReadingProgressStore.swift - Local chapter reading-progress persistence

import Foundation

public enum ReadingProgressSource: String, Codable, Equatable, Hashable, Sendable {
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
    public static let wordVisibilityValues = ["light", "dim", "hidden"]

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
        self.memorizeWordVisibility = Self.normalizedWordVisibility(memorizeWordVisibility)
        self.memorizeErrorHeatmap = memorizeErrorHeatmap
        self.memorizeScrambleHideUsed = memorizeScrambleHideUsed
        self.memorizeIncludeReference = memorizeIncludeReference
    }

    public static func isValidWordVisibility(_ value: String) -> Bool {
        wordVisibilityValues.contains(value)
    }

    public static func normalizedWordVisibility(_ value: String) -> String {
        isValidWordVisibility(value) ? value : "light"
    }
}

public struct ReadingProgressSettingsBundle: Codable, Equatable {
    public var autoMarkMemorized: Bool
    public var memorizeTypeFullWords: Bool
    public var memorizeWordVisibility: String
    public var memorizeErrorHeatmap: Bool
    public var memorizeScrambleHideUsed: Bool
    public var memorizeIncludeReference: Bool

    public init(
        autoMarkMemorized: Bool = true,
        memorizeTypeFullWords: Bool = false,
        memorizeWordVisibility: String = "light",
        memorizeErrorHeatmap: Bool = true,
        memorizeScrambleHideUsed: Bool = false,
        memorizeIncludeReference: Bool = true
    ) {
        self.autoMarkMemorized = autoMarkMemorized
        self.memorizeTypeFullWords = memorizeTypeFullWords
        self.memorizeWordVisibility = ReadingProgressSettingsSnapshot.normalizedWordVisibility(memorizeWordVisibility)
        self.memorizeErrorHeatmap = memorizeErrorHeatmap
        self.memorizeScrambleHideUsed = memorizeScrambleHideUsed
        self.memorizeIncludeReference = memorizeIncludeReference
    }

    public init(settings: ReadingProgressSettingsSnapshot) {
        self.init(
            autoMarkMemorized: settings.autoMarkMemorized,
            memorizeTypeFullWords: settings.memorizeTypeFullWords,
            memorizeWordVisibility: settings.memorizeWordVisibility,
            memorizeErrorHeatmap: settings.memorizeErrorHeatmap,
            memorizeScrambleHideUsed: settings.memorizeScrambleHideUsed,
            memorizeIncludeReference: settings.memorizeIncludeReference
        )
    }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let rawValue = String(data: data, encoding: .utf8) else {
            return Self.fallbackJSONString
        }
        return rawValue
    }

    public static let defaultJSONString = ReadingProgressSettingsBundle().jsonString()

    private static let fallbackJSONString = """
    {"autoMarkMemorized":true,"memorizeErrorHeatmap":true,"memorizeIncludeReference":true,"memorizeScrambleHideUsed":false,"memorizeTypeFullWords":false,"memorizeWordVisibility":"light"}
    """
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

public struct ReadingProgressSummary: Equatable {
    public let cycle: Int
    public let distinctChapterCount: Int
    public let readingCount: Int
    public let recentRows: [ReadingProgressHistoryRow]

    public init(
        cycle: Int,
        distinctChapterCount: Int,
        readingCount: Int,
        recentRows: [ReadingProgressHistoryRow]
    ) {
        self.cycle = cycle
        self.distinctChapterCount = distinctChapterCount
        self.readingCount = readingCount
        self.recentRows = recentRows
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
    private static let settingsBundleKeys: Set<String> = [
        "autoMarkMemorized",
        "memorizeTypeFullWords",
        "memorizeWordVisibility",
        "memorizeErrorHeatmap",
        "memorizeScrambleHideUsed",
        "memorizeIncludeReference",
    ]

    private let settingsStore: SettingsStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private struct ReadingProgressSettingsPatch: Decodable {
        let autoMarkMemorized: Bool?
        let memorizeTypeFullWords: Bool?
        let memorizeWordVisibility: String?
        let memorizeErrorHeatmap: Bool?
        let memorizeScrambleHideUsed: Bool?
        let memorizeIncludeReference: Bool?
    }

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

    public func readingSummary(recentLimit: Int = 20) -> ReadingProgressSummary {
        let snapshot = snapshot()
        return Self.readingSummary(
            in: snapshot,
            cycle: Self.currentCycle(in: snapshot),
            recentLimit: recentLimit
        )
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

    public func chapterReadHistory(kjvBookOrdinal: Int, chapter: Int) -> [ReadingProgressHistoryRow] {
        guard kjvBookOrdinal > 0, chapter > 0 else { return [] }
        let snapshot = snapshot()
        let cycle = Self.currentCycle(in: snapshot)
        return snapshot.history
            .filter { row in
                row.kjvBookOrdinal == kjvBookOrdinal &&
                    row.chapter == chapter &&
                    row.cycle == cycle
            }
            .sorted {
                if $0.readAt != $1.readAt {
                    return $0.readAt > $1.readAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    public func settingsBundle() -> ReadingProgressSettingsBundle {
        ReadingProgressSettingsBundle(settings: snapshot().settings)
    }

    public func settingsBundleJSON() -> String {
        settingsBundle().jsonString()
    }

    @discardableResult
    public func saveSettings(_ settings: ReadingProgressSettingsSnapshot) -> ReadingProgressSettingsSnapshot {
        var snapshot = snapshot()
        snapshot.settings = settings
        return save(snapshot).settings
    }

    @discardableResult
    public func applySettingsBundle(json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Self.settingsBundleKeys,
              !dictionary.values.contains(where: { $0 is NSNull }),
              let patch = try? decoder.decode(ReadingProgressSettingsPatch.self, from: data) else {
            return false
        }

        var snapshot = snapshot()
        var settings = snapshot.settings
        if let autoMarkMemorized = patch.autoMarkMemorized {
            settings.autoMarkMemorized = autoMarkMemorized
        }
        if let memorizeTypeFullWords = patch.memorizeTypeFullWords {
            settings.memorizeTypeFullWords = memorizeTypeFullWords
        }
        if let memorizeWordVisibility = patch.memorizeWordVisibility {
            guard ReadingProgressSettingsSnapshot.isValidWordVisibility(memorizeWordVisibility) else {
                return false
            }
            settings.memorizeWordVisibility = memorizeWordVisibility
        }
        if let memorizeErrorHeatmap = patch.memorizeErrorHeatmap {
            settings.memorizeErrorHeatmap = memorizeErrorHeatmap
        }
        if let memorizeScrambleHideUsed = patch.memorizeScrambleHideUsed {
            settings.memorizeScrambleHideUsed = memorizeScrambleHideUsed
        }
        if let memorizeIncludeReference = patch.memorizeIncludeReference {
            settings.memorizeIncludeReference = memorizeIncludeReference
        }

        snapshot.settings = settings
        save(snapshot)
        return true
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

    private static func readingSummary(
        in snapshot: ReadingProgressSnapshot,
        cycle: Int,
        recentLimit: Int
    ) -> ReadingProgressSummary {
        var chapterKeys = Set<ChapterKey>()
        var readingCount = 0
        var recentRows: [ReadingProgressHistoryRow] = []

        for row in snapshot.history where row.cycle == cycle {
            readingCount += 1
            chapterKeys.insert(ChapterKey(kjvBookOrdinal: row.kjvBookOrdinal, chapter: row.chapter))

            guard recentLimit > 0 else { continue }
            recentRows.append(row)
            recentRows.sort(by: isMoreRecent)
            if recentRows.count > recentLimit {
                recentRows.removeLast()
            }
        }

        return ReadingProgressSummary(
            cycle: cycle,
            distinctChapterCount: chapterKeys.count,
            readingCount: readingCount,
            recentRows: recentRows
        )
    }

    private struct ChapterKey: Hashable {
        let kjvBookOrdinal: Int
        let chapter: Int
    }

    private static func isMoreRecent(_ lhs: ReadingProgressHistoryRow, _ rhs: ReadingProgressHistoryRow) -> Bool {
        if lhs.readAt != rhs.readAt {
            return lhs.readAt > rhs.readAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
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
                isStoredRowValid($0)
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
                memorizeWordVisibility: ReadingProgressSettingsSnapshot.normalizedWordVisibility(
                    snapshot.settings.memorizeWordVisibility
                ),
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

    private static func isStoredRowValid(_ row: ReadingProgressHistoryRow) -> Bool {
        guard row.kjvBookOrdinal > 0,
              row.chapter > 0,
              row.cycle > 0 else {
            return false
        }
        return row.startOrdinal >= 0
    }

    private static func currentTimeMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    }
}
