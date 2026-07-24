// ReadingProgressStore.swift - Local chapter reading-progress persistence

import Foundation

/** Fail-visible decoding errors for persisted local Progress snapshots. */
enum ProgressPersistenceSnapshotError: Error, Equatable {
    /// Present reading-progress JSON is malformed or contains unsupported semantic values.
    case invalidReadingProgress

    /// Present memorization-progress JSON is malformed.
    case invalidMemorizationProgress

    /// A new Android reading cycle cannot be represented by Swift's integer domain.
    case readingCycleExhausted
}

public enum ReadingProgressSource: String, Codable, Equatable, Hashable, Sendable {
    case manual = "MANUAL"
    case autoScroll = "AUTO_SCROLL"
    case autoTts = "AUTO_TTS"

    public init(bridgeValue: String) {
        self = Self(rawValue: bridgeValue.uppercased()) ?? .manual
    }
}

/** One Android-compatible `ChapterReadHistory` row. */
public struct ReadingProgressHistoryRow: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let bookInitials: String
    /**
     Legacy source-domain field retained only for source compatibility.

     Android does not persist this value. New and decoded rows always expose zero, and encoding
     intentionally omits it so source ordinals cannot be mistaken for KJVA provenance.
     */
    public let startOrdinal: Int
    public let kjvBookOrdinal: Int
    public let chapter: Int
    public let cycle: Int
    public let readAt: Int64
    public let source: ReadingProgressSource

    /**
     Creates a history row through the legacy source-compatible initializer.

     - Parameters:
       - id: Stable Android-compatible row identifier.
       - bookInitials: Source module initials; Android permits an empty string.
       - startOrdinal: Ignored legacy iOS source ordinal.
       - kjvBookOrdinal: Android JSword KJV `BibleBook.ordinal`.
       - chapter: One-based source chapter retained by Android.
       - cycle: Positive reading cycle.
       - readAt: Unix epoch milliseconds.
       - source: Android reading source.
     - Side effects: none.
     - Failure modes: Validation occurs at `ReadingProgressStore` persistence boundaries.
     */
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
        self.startOrdinal = 0
        self.kjvBookOrdinal = kjvBookOrdinal
        self.chapter = chapter
        self.cycle = cycle
        self.readAt = readAt
        self.source = source
    }

    /**
     Creates a validated Android chapter-history row.

     - Parameters:
       - id: Stable Android-compatible row identifier.
       - bookInitials: Source module initials; Android permits an empty string.
       - identity: Validated KJVA book/chapter identity.
       - cycle: Positive reading cycle.
       - readAt: Unix epoch milliseconds.
       - source: Android reading source.
     - Side effects: none.
     - Failure modes: This initializer cannot fail after identity validation.
     */
    public init(
        id: UUID = UUID(),
        bookInitials: String,
        identity: ReadingProgressKJVAIdentity,
        cycle: Int,
        readAt: Int64,
        source: ReadingProgressSource
    ) {
        self.id = id
        self.bookInitials = bookInitials
        startOrdinal = 0
        kjvBookOrdinal = identity.kjvBookOrdinal
        chapter = identity.chapter
        self.cycle = cycle
        self.readAt = readAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bookInitials
        case kjvBookOrdinal
        case chapter
        case cycle
        case readAt
        case source
    }

    /** Decodes Android fields while ignoring pre-parity iOS `startOrdinal` data. */
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        bookInitials = try container.decodeIfPresent(String.self, forKey: .bookInitials) ?? ""
        startOrdinal = 0
        kjvBookOrdinal = try container.decode(Int.self, forKey: .kjvBookOrdinal)
        chapter = try container.decode(Int.self, forKey: .chapter)
        cycle = try container.decodeIfPresent(Int.self, forKey: .cycle) ?? 1
        readAt = try container.decode(Int64.self, forKey: .readAt)
        source = try container.decodeIfPresent(ReadingProgressSource.self, forKey: .source) ?? .manual
    }

    /** Encodes only Android `ChapterReadHistory` fields. */
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bookInitials, forKey: .bookInitials)
        try container.encode(kjvBookOrdinal, forKey: .kjvBookOrdinal)
        try container.encode(chapter, forKey: .chapter)
        try container.encode(cycle, forKey: .cycle)
        try container.encode(readAt, forKey: .readAt)
        try container.encode(source, forKey: .source)
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

    /**
     Decodes local reading progress without converting corrupt persistence into an empty snapshot.

     Missing persistence retains the normal default meaning. Present JSON must decode exactly, use a
     supported Android visibility, and contain no negative cycle before any sync or restore mutation.

     - Returns: The decoded local snapshot without lossy semantic normalization.
     - Side effects: Reads one settings value.
     - Throws: `ProgressPersistenceSnapshotError.invalidReadingProgress` for malformed JSON,
       unsupported visibility, or negative history/settings cycles.
     */
    func strictSnapshot() throws -> ReadingProgressSnapshot {
        guard let rawValue = settingsStore.getString(Self.settingsKey) else {
            return ReadingProgressSnapshot()
        }
        guard let data = rawValue.data(using: .utf8),
              let snapshot = try? decoder.decode(ReadingProgressSnapshot.self, from: data),
              snapshot.settings.activeCycle >= 0,
              ReadingProgressSettingsSnapshot.isValidWordVisibility(
                  snapshot.settings.memorizeWordVisibility
              ),
              snapshot.history.allSatisfy(Self.isStoredRowValid) else {
            throw ProgressPersistenceSnapshotError.invalidReadingProgress
        }
        return snapshot
    }

    public func currentCycle() -> Int {
        Self.currentCycle(in: snapshot())
    }

    /** Returns Android's latest persisted cycle, defaulting to one for empty history. */
    public func latestCycle() -> Int {
        snapshot().history.map(\.cycle).max() ?? 1
    }

    /**
     Selects one positive reading cycle.

     - Parameter cycle: Positive Android cycle number.
     - Returns: Effective selected cycle.
     - Side effects: Persists `activeCycle` in the settings snapshot.
     - Failure modes: Non-positive values select cycle one; corruption, journaling, and save errors
       are thrown without replacing the persisted snapshot.
     */
    @discardableResult
    public func setActiveCycle(_ cycle: Int) throws -> Int {
        var current = try strictSnapshot()
        current.settings.activeCycle = max(cycle, 1)
        return try save(current).settings.activeCycle
    }

    /**
     Starts Android's next cycle and selects it.

     - Returns: Newly selected cycle number.
     - Side effects: Persists `activeCycle`.
     - Failure modes: Corrupt persistence, cycle overflow, journal failure, or save failure throws.
     */
    @discardableResult
    public func startNewCycle() throws -> Int {
        let latest = try strictSnapshot().history.map(\.cycle).max() ?? 1
        let (next, overflow) = latest.addingReportingOverflow(1)
        guard !overflow else { throw ProgressPersistenceSnapshotError.readingCycleExhausted }
        return try setActiveCycle(next)
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
    @available(*, deprecated, message: "Use recordChapterRead(bookInitials:identity:source:readAt:) with a verified KJVA identity.")
    public func recordChapterRead(
        bookInitials: String,
        startOrdinal: Int,
        kjvBookOrdinal: Int,
        chapter: Int,
        source: ReadingProgressSource,
        readAt: Int64? = nil
    ) -> Int {
        chapterReadCount(kjvBookOrdinal: kjvBookOrdinal, chapter: chapter)
    }

    /**
     Records one chapter read at the validated Android-compatible persistence boundary.

     - Parameters:
       - bookInitials: Source module initials; an empty string is valid Android history.
       - identity: Validated KJVA book ordinal and chapter.
       - source: Android reading source.
       - readAt: Optional Unix epoch milliseconds, defaulting to the current clock.
     - Returns: Read count for the chapter in the active cycle after insertion.
     - Side effects: Appends and persists one Android-shaped history row.
     - Failure modes: Corrupt persistence, encoding, journal, and storage failures are thrown.
     */
    @discardableResult
    public func recordChapterRead(
        bookInitials: String,
        identity: ReadingProgressKJVAIdentity,
        source: ReadingProgressSource,
        readAt: Int64? = nil
    ) throws -> Int {

        var snapshot = try strictSnapshot()
        let cycle = Self.currentCycle(in: snapshot)
        let recordedAt = readAt ?? Self.currentTimeMilliseconds()
        snapshot.history.append(
            ReadingProgressHistoryRow(
                bookInitials: bookInitials,
                identity: identity,
                cycle: cycle,
                readAt: recordedAt,
                source: source
            )
        )
        let savedSnapshot = try save(snapshot)
        return Self.chapterReadCount(
            in: savedSnapshot,
            kjvBookOrdinal: identity.kjvBookOrdinal,
            chapter: identity.chapter
        )
    }

    @discardableResult
    public func clearChapterReadStatus(kjvBookOrdinal: Int, chapter: Int) throws -> Int {
        guard ReadingProgressKJVAIdentity(
            androidKJVBookOrdinal: kjvBookOrdinal,
            chapter: chapter
        ) != nil else { return 0 }
        var snapshot = try strictSnapshot()
        let cycle = Self.currentCycle(in: snapshot)
        snapshot.history.removeAll { row in
            row.kjvBookOrdinal == kjvBookOrdinal &&
                row.chapter == chapter &&
                row.cycle == cycle
        }
        let savedSnapshot = try save(snapshot)
        return Self.chapterReadCount(in: savedSnapshot, kjvBookOrdinal: kjvBookOrdinal, chapter: chapter)
    }

    public func chapterReadCount(kjvBookOrdinal: Int, chapter: Int) -> Int {
        Self.chapterReadCount(in: snapshot(), kjvBookOrdinal: kjvBookOrdinal, chapter: chapter)
    }

    public func chapterReadHistory(kjvBookOrdinal: Int, chapter: Int) -> [ReadingProgressHistoryRow] {
        guard ReadingProgressKJVAIdentity(
            androidKJVBookOrdinal: kjvBookOrdinal,
            chapter: chapter
        ) != nil else { return [] }
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

    /**
     Deletes one Android chapter-history row by identifier.

     - Parameter id: Stable history-row UUID.
     - Returns: `true` when a row was removed.
     - Side effects: Persists the updated history snapshot.
     - Failure modes: Missing identifiers return `false`; corruption, journal, and save failures throw.
     */
    @discardableResult
    public func deleteHistoryEntry(id: UUID) throws -> Bool {
        var current = try strictSnapshot()
        let originalCount = current.history.count
        current.history.removeAll { $0.id == id }
        guard current.history.count != originalCount else { return false }
        try save(current)
        return true
    }

    /**
     Deletes Android Read History rows as one persistence transaction.

     Android stages any number of row removals inside `ReadHistoryDialog` and applies the complete
     set when the dialog closes. Saving the filtered snapshot once preserves that all-or-nothing
     interaction contract and avoids exposing observers to intermediate progress states.

     - Parameter ids: Stable history-row identifiers staged by the dialog.
     - Returns: Number of stored rows removed; unknown identifiers are ignored.
     - Side effects: Persists at most one normalized reading-progress snapshot.
     - Failure modes: Corrupt input, journal, or persistence failures throw before a successful
       replacement snapshot is reported. An empty or entirely unknown set performs no write.
     */
    @discardableResult
    public func deleteHistoryEntries(ids: Set<UUID>) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var current = try strictSnapshot()
        let originalCount = current.history.count
        current.history.removeAll { ids.contains($0.id) }
        let removedCount = originalCount - current.history.count
        guard removedCount > 0 else { return 0 }
        try save(current)
        return removedCount
    }

    /**
     Builds Android's reading-progress analytics for the active cycle.

     - Parameters:
       - now: End of the 52-week calendar window.
       - calendar: Local calendar used for DST-safe day buckets.
       - recentLimit: Maximum recent rows returned.
     - Returns: Cycle controls, statistics, 66-book heatmap data, calendar buckets, and history.
     - Side effects: Reads the persisted snapshot.
     - Failure modes: Invalid stored rows are removed by snapshot normalization.
     */
    public func presentation(
        asOf now: Date = Date(),
        calendar: Calendar = .current,
        recentLimit: Int = 20
    ) -> ReadingProgressPresentationSnapshot {
        let current = snapshot()
        let cycle = Self.currentCycle(in: current)
        let rows = current.history.filter { $0.cycle == cycle }
        var chapterKeys = Set<ChapterKey>()
        var countsByBook: [Int: [Int: Int]] = [:]
        var totalByBook: [Int: Int] = [:]
        var dayCounts: [Int64: Int] = [:]
        var activeDays = Set<Int64>()

        let calendarEnd = now
        let calendarStart = calendar.date(byAdding: .weekOfYear, value: -52, to: now) ?? now
        for row in rows {
            chapterKeys.insert(ChapterKey(kjvBookOrdinal: row.kjvBookOrdinal, chapter: row.chapter))
            countsByBook[row.kjvBookOrdinal, default: [:]][row.chapter, default: 0] += 1
            totalByBook[row.kjvBookOrdinal, default: 0] += 1

            let date = AndroidTimestamp.date(from: row.readAt)
            let day = calendar.startOfDay(for: date)
            let dayMillis = (try? AndroidTimestamp.milliseconds(from: day)) ?? row.readAt
            activeDays.insert(dayMillis)
            if date >= calendarStart && date <= calendarEnd {
                dayCounts[dayMillis, default: 0] += 1
            }
        }

        let books = ReadingProgressKJVAIdentity.scriptureBooks.map { book in
            ReadingProgressBookSummary(
                book: book,
                chapterReadCounts: countsByBook[book.bibleBookOrdinal, default: [:]],
                totalReadCount: totalByBook[book.bibleBookOrdinal, default: 0]
            )
        }
        let recentRows = rows.sorted(by: Self.isMoreRecent).prefix(max(recentLimit, 0))

        return ReadingProgressPresentationSnapshot(
            cycle: cycle,
            latestCycle: current.history.map(\.cycle).max() ?? 1,
            distinctChapterCount: chapterKeys.count,
            activeDayCount: activeDays.count,
            totalBibleChapterCount: books.reduce(0) { $0 + $1.book.chapterCount },
            books: books,
            calendar: dayCounts.keys.sorted().map {
                ReadingProgressDayCount(dayStartMilliseconds: $0, count: dayCounts[$0, default: 0])
            },
            recentRows: Array(recentRows)
        )
    }

    public func settingsBundle() -> ReadingProgressSettingsBundle {
        ReadingProgressSettingsBundle(settings: snapshot().settings)
    }

    public func settingsBundleJSON() -> String {
        settingsBundle().jsonString()
    }

    @discardableResult
    public func saveSettings(
        _ settings: ReadingProgressSettingsSnapshot
    ) throws -> ReadingProgressSettingsSnapshot {
        var snapshot = try strictSnapshot()
        snapshot.settings = settings
        return try save(snapshot).settings
    }

    @discardableResult
    public func applySettingsBundle(json: String) throws -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Self.settingsBundleKeys,
              !dictionary.values.contains(where: { $0 is NSNull }),
              let patch = try? decoder.decode(ReadingProgressSettingsPatch.self, from: data) else {
            return false
        }

        var snapshot = try strictSnapshot()
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
        try save(snapshot)
        return true
    }

    @discardableResult
    private func save(_ snapshot: ReadingProgressSnapshot) throws -> ReadingProgressSnapshot {
        let normalized = Self.normalized(snapshot)
        let data = try encoder.encode(normalized)
        guard let rawValue = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try settingsStore.performJournaledSave {
            settingsStore.setString(Self.settingsKey, value: rawValue)
            try RemoteSyncMutationJournalService().recordLocalChanges(
                for: .progress,
                modelContext: nil,
                settingsStore: settingsStore
            )
        }
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

    private static func isStoredRowValid(_ row: ReadingProgressHistoryRow) -> Bool {
        row.cycle > 0 && ReadingProgressKJVAIdentity(
            androidKJVBookOrdinal: row.kjvBookOrdinal,
            chapter: row.chapter
        ) != nil
    }

    private static func currentTimeMilliseconds() -> Int64 {
        AndroidTimestamp.currentMilliseconds()
    }
}
