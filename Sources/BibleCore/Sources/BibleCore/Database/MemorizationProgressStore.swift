// MemorizationProgressStore.swift - Local memorization state persistence

import Foundation

/**
 * A normalized verse range used by the local iOS memorization progress store.
 *
 * Android stores memorization state as KJV-normalized ordinals. iOS does not yet have the full
 * Android progress database, so this first bridge-backed model keeps the module/book identity with
 * the ordinals supplied by the embedded reader. That prevents ordinal collisions across books while
 * preserving the bridge contract's `endOrdinal < 0` single-verse semantics before values reach the
 * store.
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
 * behavior without forcing a SwiftData schema migration. Remote Android `progress` sync and richer
 * KJV-normalization remain separate parity work.
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

    public func addMemorizationTargetIfNeeded(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) {
        guard let range = Self.range(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal) else {
            return
        }
        var snapshot = snapshot()
        guard !Self.contains(range, in: snapshot.targetRanges) else { return }
        snapshot.targetRanges = Self.add(range, to: snapshot.targetRanges)
        save(snapshot)
    }

    public func addMemorizationTarget(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) {
        guard let range = Self.range(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal) else {
            return
        }
        var snapshot = snapshot()
        snapshot.targetRanges = Self.add(range, to: snapshot.targetRanges)
        save(snapshot)
    }

    public func removeMemorizationTarget(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) {
        guard let range = Self.range(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal) else {
            return
        }
        var snapshot = snapshot()
        snapshot.targetRanges = Self.subtract(range, from: snapshot.targetRanges)
        save(snapshot)
    }

    public func markAsMemorized(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) {
        guard let range = Self.range(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal) else {
            return
        }
        var snapshot = snapshot()
        snapshot.memorizedRanges = Self.add(range, to: snapshot.memorizedRanges)
        save(snapshot)
    }

    public func unmarkMemorized(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) {
        guard let range = Self.range(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal) else {
            return
        }
        var snapshot = snapshot()
        snapshot.memorizedRanges = Self.subtract(range, from: snapshot.memorizedRanges)
        save(snapshot)
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

        var result = Set<Int>()
        for range in ranges where range.bookInitials == query.bookInitials {
            let start = max(range.startOrdinal, query.startOrdinal)
            let end = min(range.endOrdinal, query.endOrdinal)
            guard start <= end else { continue }
            for ordinal in start...end {
                result.insert(ordinal)
            }
        }
        return result.sorted()
    }

    private static func range(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> MemorizationProgressRange? {
        guard !bookInitials.isEmpty,
              startOrdinal > 0,
              endOrdinal >= startOrdinal else {
            return nil
        }
        return MemorizationProgressRange(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
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
            range.bookInitials == candidate.bookInitials &&
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
                guard range.bookInitials == removal.bookInitials,
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
            .filter { !$0.bookInitials.isEmpty && $0.startOrdinal > 0 && $0.endOrdinal >= $0.startOrdinal }
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
}
