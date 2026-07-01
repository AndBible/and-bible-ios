// MemorizationProgressStore.swift - Local memorization state persistence

import Foundation

/**
 * A normalized verse range used by the local iOS memorization progress store.
 *
 * Android stores memorization state as KJVA-normalized ordinals without a module identity. An empty
 * `bookInitials` value represents that global Android domain. Non-empty values are still decoded so
 * older local state and imported fixtures remain readable, but new reader mutations should write
 * KJVA-global ranges.
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
 * Ranges are kept normalized and non-overlapping per book/module identity. The frontend only needs
 * ordinal membership sets, so this representation can support Android-style set difference for
 * target removal without introducing a new SwiftData schema.
 */
public struct MemorizationProgressSnapshot: Codable, Equatable {
    public var memorizedRanges: [MemorizationProgressRange]
    public var targetRanges: [MemorizationProgressRange]

    public init(
        memorizedRanges: [MemorizationProgressRange] = [],
        targetRanges: [MemorizationProgressRange] = []
    ) {
        self.memorizedRanges = memorizedRanges
        self.targetRanges = targetRanges
    }
}

/**
 * Local store for memorized verses and memorization targets.
 *
 * The store is intentionally backed by `SettingsStore` JSON so #76 can give the bridge real native
 * behavior without forcing a SwiftData schema migration. New bridge writes use Android-compatible
 * KJVA-global ranges, and the same snapshot feeds Android database backup export/import.
 */
public final class MemorizationProgressStore {
    public static let settingsKey = "memorization_progress_state_v1"

    private let settingsStore: SettingsStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    public func snapshot() -> MemorizationProgressSnapshot {
        guard let rawValue = settingsStore.getString(Self.settingsKey),
              let data = rawValue.data(using: .utf8),
              let snapshot = try? decoder.decode(MemorizationProgressSnapshot.self, from: data) else {
            return MemorizationProgressSnapshot()
        }
        return MemorizationProgressSnapshot(
            memorizedRanges: Self.normalized(snapshot.memorizedRanges),
            targetRanges: Self.normalized(snapshot.targetRanges)
        )
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
        var snapshot = snapshot()
        guard !Self.contains(range, in: snapshot.targetRanges) else { return .empty }
        let before = Self.ordinals(from: snapshot.targetRanges, matching: range)
        snapshot.targetRanges = Self.add(range, to: snapshot.targetRanges)
        let after = Self.ordinals(from: snapshot.targetRanges, matching: range)
        save(snapshot)
        return MemorizationProgressDelta(addedTargets: Array(after.subtracting(before)))
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
        let before = Self.ordinals(from: snapshot.targetRanges, matching: range)
        snapshot.targetRanges = Self.add(range, to: snapshot.targetRanges)
        let after = Self.ordinals(from: snapshot.targetRanges, matching: range)
        let delta = MemorizationProgressDelta(addedTargets: Array(after.subtracting(before)))
        guard !delta.isEmpty else { return .empty }
        save(snapshot)
        return delta
    }

    @discardableResult
    public func removeMemorizationTarget(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> MemorizationProgressDelta {
        guard let range = Self.range(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal) else {
            return .empty
        }
        var snapshot = snapshot()
        let before = Self.ordinals(from: snapshot.targetRanges, matching: range)
        snapshot.targetRanges = Self.subtract(range, from: snapshot.targetRanges)
        let after = Self.ordinals(from: snapshot.targetRanges, matching: range)
        let delta = MemorizationProgressDelta(removedTargets: Array(before.subtracting(after)))
        guard !delta.isEmpty else { return .empty }
        save(snapshot)
        return delta
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
        let before = Self.ordinals(from: snapshot.memorizedRanges, matching: range)
        snapshot.memorizedRanges = Self.add(range, to: snapshot.memorizedRanges)
        let after = Self.ordinals(from: snapshot.memorizedRanges, matching: range)
        let delta = MemorizationProgressDelta(addedMemorized: Array(after.subtracting(before)))
        guard !delta.isEmpty else { return .empty }
        save(snapshot)
        return delta
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
        let before = Self.ordinals(from: snapshot.memorizedRanges, matching: range)
        snapshot.memorizedRanges = Self.subtract(range, from: snapshot.memorizedRanges)
        let after = Self.ordinals(from: snapshot.memorizedRanges, matching: range)
        let delta = MemorizationProgressDelta(removedMemorized: Array(before.subtracting(after)))
        guard !delta.isEmpty else { return .empty }
        save(snapshot)
        return delta
    }

    public func memorizedOrdinals(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> [Int] {
        ordinals(
            from: snapshot().memorizedRanges,
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    public func targetOrdinals(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> [Int] {
        ordinals(
            from: snapshot().targetRanges,
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    private func save(_ snapshot: MemorizationProgressSnapshot) {
        let normalized = MemorizationProgressSnapshot(
            memorizedRanges: Self.normalized(snapshot.memorizedRanges),
            targetRanges: Self.normalized(snapshot.targetRanges)
        )
        guard let data = try? encoder.encode(normalized),
              let rawValue = String(data: data, encoding: .utf8) else {
            return
        }
        settingsStore.setString(Self.settingsKey, value: rawValue)
    }

    private func ordinals(
        from ranges: [MemorizationProgressRange],
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

        return Self.ordinals(from: ranges, matching: query).sorted()
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

    private static func ordinals(
        from ranges: [MemorizationProgressRange],
        matching query: MemorizationProgressRange
    ) -> Set<Int> {
        var result = Set<Int>()
        for range in ranges where matchesStoredRange(range, query: query) {
            let start = max(range.startOrdinal, query.startOrdinal)
            let end = min(range.endOrdinal, query.endOrdinal)
            guard start <= end else { continue }
            for ordinal in start...end {
                result.insert(ordinal)
            }
        }
        return result
    }

    private static func add(
        _ range: MemorizationProgressRange,
        to ranges: [MemorizationProgressRange]
    ) -> [MemorizationProgressRange] {
        normalized(ranges + [range])
    }

    private static func contains(
        _ candidate: MemorizationProgressRange,
        in ranges: [MemorizationProgressRange]
    ) -> Bool {
        ranges.contains { range in
            matchesStoredRange(range, query: candidate) &&
                range.startOrdinal <= candidate.startOrdinal &&
                range.endOrdinal >= candidate.endOrdinal
        }
    }

    private static func subtract(
        _ removal: MemorizationProgressRange,
        from ranges: [MemorizationProgressRange]
    ) -> [MemorizationProgressRange] {
        normalized(
            ranges.flatMap { range -> [MemorizationProgressRange] in
                guard matchesStoredRange(range, query: removal),
                      range.startOrdinal <= removal.endOrdinal,
                      range.endOrdinal >= removal.startOrdinal else {
                    return [range]
                }

                var remaining: [MemorizationProgressRange] = []
                if range.startOrdinal < removal.startOrdinal {
                    remaining.append(
                        MemorizationProgressRange(
                            bookInitials: range.bookInitials,
                            startOrdinal: range.startOrdinal,
                            endOrdinal: removal.startOrdinal - 1
                        )
                    )
                }
                if range.endOrdinal > removal.endOrdinal {
                    remaining.append(
                        MemorizationProgressRange(
                            bookInitials: range.bookInitials,
                            startOrdinal: removal.endOrdinal + 1,
                            endOrdinal: range.endOrdinal
                        )
                    )
                }
                return remaining
            }
        )
    }

    private static func normalized(_ ranges: [MemorizationProgressRange]) -> [MemorizationProgressRange] {
        let sorted = ranges
            .filter(isStoredRangeValid)
            .sorted {
                if $0.bookInitials != $1.bookInitials {
                    return $0.bookInitials < $1.bookInitials
                }
                if $0.startOrdinal != $1.startOrdinal {
                    return $0.startOrdinal < $1.startOrdinal
                }
                return $0.endOrdinal < $1.endOrdinal
            }

        var result: [MemorizationProgressRange] = []
        for range in sorted {
            guard let last = result.last,
                  last.bookInitials == range.bookInitials,
                  range.startOrdinal <= last.endOrdinal + 1 else {
                result.append(range)
                continue
            }

            result[result.count - 1] = MemorizationProgressRange(
                bookInitials: last.bookInitials,
                startOrdinal: last.startOrdinal,
                endOrdinal: max(last.endOrdinal, range.endOrdinal)
            )
        }
        return result
    }

    private static func isStoredRangeValid(_ range: MemorizationProgressRange) -> Bool {
        range.startOrdinal > 0 && range.endOrdinal >= range.startOrdinal
    }

    private static func matchesStoredRange(
        _ range: MemorizationProgressRange,
        query: MemorizationProgressRange
    ) -> Bool {
        range.bookInitials.isEmpty || range.bookInitials == query.bookInitials
    }
}
