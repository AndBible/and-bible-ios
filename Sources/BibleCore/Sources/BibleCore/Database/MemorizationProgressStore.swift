// MemorizationProgressStore.swift - Local memorization state persistence

import Foundation

/**
 * A normalized verse range used by the local iOS memorization progress store.
 *
 * Android stores memorization state as KJVA-normalized ordinals without a module identity. An empty
 * `bookInitials` value represents that global Android domain. Non-empty values are still decoded so
 * older local state and imported fixtures remain readable, but new reader mutations should write
 * KJVA-global rows.
 */
public struct MemorizationProgressRange: Codable, Equatable, Hashable {
    public let bookInitials: String
    public let startOrdinal: Int
    public let endOrdinal: Int

    public init(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        self.bookInitials = bookInitials
        self.startOrdinal = startOrdinal
        self.endOrdinal = endOrdinal
    }
}

/**
 * Android-shaped memorized verse row.
 *
 * Android persists one `MemorizedVerse` row per KJVA ordinal with a `memorizedAt` timestamp. The
 * optional `bookInitials` compatibility field remains only so pre-parity iOS module-scoped rows can
 * be decoded and queried until they are rewritten by normal user actions.
 */
public struct MemorizedVerseProgress: Codable, Equatable, Hashable {
    public let bookInitials: String
    public let kjvOrdinal: Int
    public let memorizedAt: Int64

    public init(bookInitials: String = "", kjvOrdinal: Int, memorizedAt: Int64 = 0) {
        self.bookInitials = bookInitials
        self.kjvOrdinal = kjvOrdinal
        self.memorizedAt = memorizedAt
    }
}

/**
 * Consecutive memorized verses grouped for Android's Reading Progress Memorization list.
 */
public struct MemorizedVerseRangeWithTimestamp: Equatable {
    public let range: MemorizationProgressRange
    public let latestMemorizedAt: Int64

    public init(range: MemorizationProgressRange, latestMemorizedAt: Int64) {
        self.range = range
        self.latestMemorizedAt = latestMemorizedAt
    }
}

/**
 * Android-shaped memorization target row.
 *
 * Android stores targets as independent rows. Two rows may cover the same KJVA ordinal range, and
 * target totals count both rows. The iOS store therefore keeps row identity and creation time
 * instead of collapsing targets into a range union.
 */
public struct MemorizationTargetRow: Codable, Equatable, Hashable, Identifiable {
    public let id: UUID
    public let bookInitials: String
    public let startOrdinal: Int
    public let endOrdinal: Int
    public let createdAt: Int64

    public init(
        id: UUID = UUID(),
        bookInitials: String = "",
        startOrdinal: Int,
        endOrdinal: Int,
        createdAt: Int64 = 0
    ) {
        self.id = id
        self.bookInitials = bookInitials
        self.startOrdinal = startOrdinal
        self.endOrdinal = endOrdinal
        self.createdAt = createdAt
    }

    public var range: MemorizationProgressRange {
        MemorizationProgressRange(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    public var verseCount: Int {
        max(0, endOrdinal - startOrdinal + 1)
    }
}

/**
 * Android-style memorization target progress summary.
 */
public struct MemorizationTargetProgress: Equatable {
    public let memorized: Int
    public let total: Int

    public init(memorized: Int, total: Int) {
        self.memorized = memorized
        self.total = total
    }
}

/**
 * Android-style memorization mutation delta.
 *
 * The shared reader client receives only the ordinals added or removed by a mutation. Store methods
 * return KJVA-domain deltas; reader bridge code projects them back to the currently rendered ordinal
 * domain before emitting `update_memorization_data`.
 */
public struct MemorizationProgressDelta: Equatable {
    public static let empty = MemorizationProgressDelta()

    public var addedMemorized: [Int]
    public var removedMemorized: [Int]
    public var addedTargets: [Int]
    public var removedTargets: [Int]

    public init(
        addedMemorized: [Int] = [],
        removedMemorized: [Int] = [],
        addedTargets: [Int] = [],
        removedTargets: [Int] = []
    ) {
        self.addedMemorized = addedMemorized.sorted()
        self.removedMemorized = removedMemorized.sorted()
        self.addedTargets = addedTargets.sorted()
        self.removedTargets = removedTargets.sorted()
    }

    public var isEmpty: Bool {
        addedMemorized.isEmpty &&
            removedMemorized.isEmpty &&
            addedTargets.isEmpty &&
            removedTargets.isEmpty
    }

    public mutating func merge(_ other: MemorizationProgressDelta) {
        addedMemorized = Self.merged(addedMemorized, other.addedMemorized)
        removedMemorized = Self.merged(removedMemorized, other.removedMemorized)
        addedTargets = Self.merged(addedTargets, other.addedTargets)
        removedTargets = Self.merged(removedTargets, other.removedTargets)
    }

    private static func merged(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
        Array(Set(lhs).union(rhs)).sorted()
    }
}

/**
 * Persisted local memorization progress.
 *
 * New JSON uses Android-shaped per-verse memorized rows and independent target rows. The
 * `memorizedRanges` and `targetRanges` accessors remain as compatibility projections for older
 * code and legacy JSON; they are not the owning storage shape.
 */
public struct MemorizationProgressSnapshot: Codable, Equatable {
    public var memorizedVerses: [MemorizedVerseProgress]
    public var targetRows: [MemorizationTargetRow]

    public var memorizedRanges: [MemorizationProgressRange] {
        get { Self.ranges(from: memorizedVerses) }
        set { memorizedVerses = Self.verses(from: newValue) }
    }

    public var targetRanges: [MemorizationProgressRange] {
        get { targetRows.map(\.range) }
        set { targetRows = newValue.map { Self.targetRow(from: $0) } }
    }

    public init(
        memorizedRanges: [MemorizationProgressRange] = [],
        targetRanges: [MemorizationProgressRange] = [],
        memorizedVerses: [MemorizedVerseProgress] = [],
        targetRows: [MemorizationTargetRow] = []
    ) {
        self.memorizedVerses = Self.normalizedVerses(memorizedVerses + Self.verses(from: memorizedRanges))
        self.targetRows = Self.normalizedTargets(targetRows + targetRanges.map { Self.targetRow(from: $0) })
    }

    private enum CodingKeys: String, CodingKey {
        case memorizedVerses
        case targetRows
        case memorizedRanges
        case targetRanges
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let memorizedVerses = try container.decodeIfPresent([MemorizedVerseProgress].self, forKey: .memorizedVerses)
        let targetRows = try container.decodeIfPresent([MemorizationTargetRow].self, forKey: .targetRows)
        let legacyMemorizedRanges = try container.decodeIfPresent(
            [MemorizationProgressRange].self,
            forKey: .memorizedRanges
        ) ?? []
        let legacyTargetRanges = try container.decodeIfPresent(
            [MemorizationProgressRange].self,
            forKey: .targetRanges
        ) ?? []

        self.init(
            memorizedRanges: memorizedVerses == nil ? legacyMemorizedRanges : [],
            targetRanges: targetRows == nil ? legacyTargetRanges : [],
            memorizedVerses: memorizedVerses ?? [],
            targetRows: targetRows ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(memorizedVerses, forKey: .memorizedVerses)
        try container.encode(targetRows, forKey: .targetRows)
    }

    private static func verses(from ranges: [MemorizationProgressRange]) -> [MemorizedVerseProgress] {
        ranges.flatMap { range -> [MemorizedVerseProgress] in
            guard isRangeValid(range) else { return [] }
            return (range.startOrdinal...range.endOrdinal).map {
                MemorizedVerseProgress(bookInitials: range.bookInitials, kjvOrdinal: $0)
            }
        }
    }

    private static func ranges(from verses: [MemorizedVerseProgress]) -> [MemorizationProgressRange] {
        let sorted = normalizedVerses(verses).sorted {
            if $0.bookInitials != $1.bookInitials {
                return $0.bookInitials < $1.bookInitials
            }
            return $0.kjvOrdinal < $1.kjvOrdinal
        }
        guard let first = sorted.first else { return [] }

        var ranges: [MemorizationProgressRange] = []
        var bookInitials = first.bookInitials
        var start = first.kjvOrdinal
        var end = first.kjvOrdinal

        for verse in sorted.dropFirst() {
            if verse.bookInitials == bookInitials && verse.kjvOrdinal == end + 1 {
                end = verse.kjvOrdinal
                continue
            }
            ranges.append(MemorizationProgressRange(bookInitials: bookInitials, startOrdinal: start, endOrdinal: end))
            bookInitials = verse.bookInitials
            start = verse.kjvOrdinal
            end = verse.kjvOrdinal
        }

        ranges.append(MemorizationProgressRange(bookInitials: bookInitials, startOrdinal: start, endOrdinal: end))
        return ranges
    }

    private static func targetRow(from range: MemorizationProgressRange) -> MemorizationTargetRow {
        MemorizationTargetRow(
            bookInitials: range.bookInitials,
            startOrdinal: range.startOrdinal,
            endOrdinal: range.endOrdinal
        )
    }

    fileprivate static func normalizedVerses(_ verses: [MemorizedVerseProgress]) -> [MemorizedVerseProgress] {
        var resultByKey: [String: MemorizedVerseProgress] = [:]
        for verse in verses where verse.kjvOrdinal > 0 {
            let key = "\(verse.bookInitials)\u{0}\(verse.kjvOrdinal)"
            guard let existing = resultByKey[key],
                  existing.memorizedAt >= verse.memorizedAt else {
                resultByKey[key] = verse
                continue
            }
        }
        return resultByKey.values.sorted {
            if $0.bookInitials != $1.bookInitials {
                return $0.bookInitials < $1.bookInitials
            }
            return $0.kjvOrdinal < $1.kjvOrdinal
        }
    }

    fileprivate static func normalizedTargets(_ rows: [MemorizationTargetRow]) -> [MemorizationTargetRow] {
        rows.filter { row in
            row.startOrdinal > 0 && row.endOrdinal >= row.startOrdinal
        }
        .sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            if $0.startOrdinal != $1.startOrdinal {
                return $0.startOrdinal < $1.startOrdinal
            }
            if $0.endOrdinal != $1.endOrdinal {
                return $0.endOrdinal < $1.endOrdinal
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func isRangeValid(_ range: MemorizationProgressRange) -> Bool {
        range.startOrdinal > 0 && range.endOrdinal >= range.startOrdinal
    }
}

/**
 * Local store for memorized verses and memorization targets.
 *
 * The store is intentionally backed by `SettingsStore` JSON so #76 can give the bridge real native
 * behavior without forcing a SwiftData schema migration. New bridge writes use Android-compatible
 * KJVA-global rows, and the same snapshot feeds Android database backup export/import.
 */
public final class MemorizationProgressStore {
    public static let settingsKey = "memorization_progress_state_v1"

    private let settingsStore: SettingsStore
    private let currentTimeMilliseconds: () -> Int64
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public convenience init(settingsStore: SettingsStore) {
        self.init(settingsStore: settingsStore, currentTimeMilliseconds: Self.defaultCurrentTimeMilliseconds)
    }

    public init(
        settingsStore: SettingsStore,
        currentTimeMilliseconds: @escaping () -> Int64
    ) {
        self.settingsStore = settingsStore
        self.currentTimeMilliseconds = currentTimeMilliseconds
    }

    public func snapshot() -> MemorizationProgressSnapshot {
        guard let rawValue = settingsStore.getString(Self.settingsKey),
              let data = rawValue.data(using: .utf8),
              let snapshot = try? decoder.decode(MemorizationProgressSnapshot.self, from: data) else {
            return MemorizationProgressSnapshot()
        }
        return Self.normalized(snapshot)
    }

    public func memorizedVerseRangesWithTimestamps() -> [MemorizedVerseRangeWithTimestamp] {
        Self.memorizedVerseRangesWithTimestamps(in: snapshot())
    }

    public func memorizationTargets() -> [MemorizationTargetRow] {
        snapshot().targetRows
    }

    public func incompleteMemorizationTargets() -> [MemorizationTargetRow] {
        let snapshot = snapshot()
        return snapshot.targetRows.filter { row in
            Self.memorizedOrdinalCount(in: row.range, snapshot: snapshot) < row.verseCount
        }
    }

    public func memorizationTargetProgress() -> MemorizationTargetProgress {
        let snapshot = snapshot()
        let total = snapshot.targetRows.reduce(0) { $0 + $1.verseCount }
        let memorized = snapshot.targetRows.reduce(0) { total, row in
            total + Self.memorizedOrdinalCount(in: row.range, snapshot: snapshot)
        }
        return MemorizationTargetProgress(memorized: memorized, total: total)
    }

    @discardableResult
    public func addMemorizationTargetIfNeeded(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> MemorizationProgressDelta {
        guard let range = Self.range(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal) else {
            return .empty
        }
        let snapshot = snapshot()
        guard !snapshot.targetRows.contains(where: { row in
            Self.matchesStoredRange(row.range, query: range) &&
                row.startOrdinal == range.startOrdinal &&
                row.endOrdinal == range.endOrdinal
        }) else {
            return .empty
        }
        return addMemorizationTarget(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal)
    }

    @discardableResult
    public func addMemorizationTarget(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> MemorizationProgressDelta {
        guard let range = Self.range(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal) else {
            return .empty
        }
        var snapshot = snapshot()
        snapshot.targetRows.append(
            MemorizationTargetRow(
                bookInitials: range.bookInitials,
                startOrdinal: range.startOrdinal,
                endOrdinal: range.endOrdinal,
                createdAt: currentTimeMilliseconds()
            )
        )
        save(snapshot)
        return MemorizationProgressDelta(addedTargets: Self.ordinalArray(in: range))
    }

    @discardableResult
    public func removeMemorizationTarget(
        id: UUID
    ) -> MemorizationProgressDelta {
        var snapshot = snapshot()
        guard let index = snapshot.targetRows.firstIndex(where: { $0.id == id }) else {
            return .empty
        }
        let row = snapshot.targetRows.remove(at: index)
        save(snapshot)
        return MemorizationProgressDelta(removedTargets: Self.ordinalArray(in: row.range))
    }

    @discardableResult
    public func removeMemorizationTarget(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> MemorizationProgressDelta {
        guard let removal = Self.range(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal) else {
            return .empty
        }
        var snapshot = snapshot()
        let splitCreatedAt = currentTimeMilliseconds()
        var remainingRows: [MemorizationTargetRow] = []
        var removedOrdinals: [Int] = []

        for row in snapshot.targetRows {
            let rowRange = row.range
            guard Self.matchesStoredRange(rowRange, query: removal),
                  row.endOrdinal >= removal.startOrdinal,
                  row.startOrdinal <= removal.endOrdinal else {
                remainingRows.append(row)
                continue
            }

            let removedStart = max(row.startOrdinal, removal.startOrdinal)
            let removedEnd = min(row.endOrdinal, removal.endOrdinal)
            removedOrdinals.append(contentsOf: removedStart...removedEnd)

            if row.startOrdinal < removal.startOrdinal {
                remainingRows.append(
                    MemorizationTargetRow(
                        bookInitials: row.bookInitials,
                        startOrdinal: row.startOrdinal,
                        endOrdinal: removal.startOrdinal - 1,
                        createdAt: splitCreatedAt
                    )
                )
            }
            if row.endOrdinal > removal.endOrdinal {
                remainingRows.append(
                    MemorizationTargetRow(
                        bookInitials: row.bookInitials,
                        startOrdinal: removal.endOrdinal + 1,
                        endOrdinal: row.endOrdinal,
                        createdAt: splitCreatedAt
                    )
                )
            }
        }

        guard !removedOrdinals.isEmpty else {
            return .empty
        }
        snapshot.targetRows = remainingRows
        save(snapshot)
        return MemorizationProgressDelta(removedTargets: removedOrdinals)
    }

    @discardableResult
    public func markAsMemorized(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> MemorizationProgressDelta {
        guard let range = Self.range(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal) else {
            return .empty
        }
        var snapshot = snapshot()
        let existing = Set(Self.memorizedOrdinals(in: range, snapshot: snapshot))
        let added = Self.ordinalArray(in: range).filter { !existing.contains($0) }
        guard !added.isEmpty else {
            return .empty
        }
        let memorizedAt = currentTimeMilliseconds()
        snapshot.memorizedVerses.append(
            contentsOf: added.map {
                MemorizedVerseProgress(bookInitials: range.bookInitials, kjvOrdinal: $0, memorizedAt: memorizedAt)
            }
        )
        save(snapshot)
        return MemorizationProgressDelta(addedMemorized: added)
    }

    @discardableResult
    public func unmarkMemorized(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> MemorizationProgressDelta {
        guard let range = Self.range(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal) else {
            return .empty
        }
        var snapshot = snapshot()
        snapshot.memorizedVerses.removeAll { verse in
            Self.matchesStoredVerse(verse, query: range) &&
                verse.kjvOrdinal >= range.startOrdinal &&
                verse.kjvOrdinal <= range.endOrdinal
        }
        save(snapshot)
        return MemorizationProgressDelta(removedMemorized: Self.ordinalArray(in: range))
    }

    public func memorizedOrdinals(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> [Int] {
        guard let query = Self.range(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        ) else {
            return []
        }
        return Self.memorizedOrdinals(in: query, snapshot: snapshot())
    }

    public func targetOrdinals(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> [Int] {
        guard let query = Self.range(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        ) else {
            return []
        }
        var ordinals: [Int] = []
        for row in snapshot().targetRows where Self.matchesStoredRange(row.range, query: query) {
            let start = max(row.startOrdinal, query.startOrdinal)
            let end = min(row.endOrdinal, query.endOrdinal)
            guard start <= end else { continue }
            ordinals.append(contentsOf: start...end)
        }
        return ordinals.sorted()
    }

    private func save(_ snapshot: MemorizationProgressSnapshot) {
        let normalized = Self.normalized(snapshot)
        guard let data = try? encoder.encode(normalized),
              let rawValue = String(data: data, encoding: .utf8) else {
            return
        }
        settingsStore.setString(Self.settingsKey, value: rawValue)
    }

    private static func normalized(_ snapshot: MemorizationProgressSnapshot) -> MemorizationProgressSnapshot {
        MemorizationProgressSnapshot(
            memorizedVerses: MemorizationProgressSnapshot.normalizedVerses(snapshot.memorizedVerses),
            targetRows: MemorizationProgressSnapshot.normalizedTargets(snapshot.targetRows)
        )
    }

    private static func range(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> MemorizationProgressRange? {
        guard startOrdinal > 0,
              endOrdinal >= startOrdinal else {
            return nil
        }
        return MemorizationProgressRange(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    private static func memorizedOrdinals(
        in range: MemorizationProgressRange,
        snapshot: MemorizationProgressSnapshot
    ) -> [Int] {
        snapshot.memorizedVerses
            .filter { verse in
                matchesStoredVerse(verse, query: range) &&
                    verse.kjvOrdinal >= range.startOrdinal &&
                    verse.kjvOrdinal <= range.endOrdinal
            }
            .map(\.kjvOrdinal)
            .sorted()
    }

    private static func memorizedOrdinalCount(
        in range: MemorizationProgressRange,
        snapshot: MemorizationProgressSnapshot
    ) -> Int {
        Set(memorizedOrdinals(in: range, snapshot: snapshot)).count
    }

    private static func memorizedVerseRangesWithTimestamps(
        in snapshot: MemorizationProgressSnapshot
    ) -> [MemorizedVerseRangeWithTimestamp] {
        let sorted = snapshot.memorizedVerses.sorted {
            if $0.bookInitials != $1.bookInitials {
                return $0.bookInitials < $1.bookInitials
            }
            return $0.kjvOrdinal < $1.kjvOrdinal
        }
        guard let first = sorted.first else { return [] }

        var ranges: [MemorizedVerseRangeWithTimestamp] = []
        var bookInitials = first.bookInitials
        var start = first.kjvOrdinal
        var end = first.kjvOrdinal
        var latest = first.memorizedAt

        for verse in sorted.dropFirst() {
            if verse.bookInitials == bookInitials && verse.kjvOrdinal == end + 1 {
                end = verse.kjvOrdinal
                latest = max(latest, verse.memorizedAt)
                continue
            }
            ranges.append(
                MemorizedVerseRangeWithTimestamp(
                    range: MemorizationProgressRange(bookInitials: bookInitials, startOrdinal: start, endOrdinal: end),
                    latestMemorizedAt: latest
                )
            )
            bookInitials = verse.bookInitials
            start = verse.kjvOrdinal
            end = verse.kjvOrdinal
            latest = verse.memorizedAt
        }

        ranges.append(
            MemorizedVerseRangeWithTimestamp(
                range: MemorizationProgressRange(bookInitials: bookInitials, startOrdinal: start, endOrdinal: end),
                latestMemorizedAt: latest
            )
        )
        return ranges.sorted {
            if $0.latestMemorizedAt != $1.latestMemorizedAt {
                return $0.latestMemorizedAt > $1.latestMemorizedAt
            }
            return $0.range.startOrdinal < $1.range.startOrdinal
        }
    }

    private static func ordinalArray(in range: MemorizationProgressRange) -> [Int] {
        Array(range.startOrdinal...range.endOrdinal)
    }

    private static func matchesStoredVerse(
        _ verse: MemorizedVerseProgress,
        query: MemorizationProgressRange
    ) -> Bool {
        verse.bookInitials.isEmpty || verse.bookInitials == query.bookInitials
    }

    private static func matchesStoredRange(
        _ range: MemorizationProgressRange,
        query: MemorizationProgressRange
    ) -> Bool {
        range.bookInitials.isEmpty || range.bookInitials == query.bookInitials
    }

    private static func defaultCurrentTimeMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
    }
}
