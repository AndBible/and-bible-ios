// MemorizationProgressStore.swift - Local memorization state persistence

import CryptoKit
import Foundation

/**
 Classifies one trust-less memorization row decoded from an older persisted JSON schema.

 Origin-main memorization JSON stored Android-compatible global KJVA ordinals with an empty
 `bookInitials` compatibility field. That schema contract is sufficient provenance for an exact
 KJVA identity mapping, while a nonempty field still denotes a module-scoped legacy row that must
 be resolved before consumers can use it.

 - Parameters:
   - bookInitials: Compatibility field decoded from the persisted row.
   - startOrdinal: Inclusive ordinal stored by the older schema.
   - endOrdinal: Inclusive ordinal stored by the older schema.
 - Returns: Verified legacy-migration metadata for a valid global KJVA range; otherwise pending or
   unresolved metadata from the ordinary fail-closed legacy policy.
 - Side effects: Reads the pinned KJVA canon while validating bounds.
 - Failure modes: Invalid global ranges and module-scoped rows never receive verified trust.
 */
private func decodedLegacyMemorizationTrustMetadata(
    bookInitials: String,
    startOrdinal: Int,
    endOrdinal: Int
) -> PersistedOrdinalTrustMetadata {
    let initials = bookInitials.trimmingCharacters(in: .whitespacesAndNewlines)
    guard initials.isEmpty,
          PersistedOrdinalTrustPolicy.isValidKJVARange(start: startOrdinal, end: endOrdinal) else {
        return PersistedOrdinalTrustPolicy.legacyMetadata(
            sourceBookInitials: bookInitials,
            sourceOrdinalStart: startOrdinal,
            sourceOrdinalEnd: endOrdinal
        )
    }

    return PersistedOrdinalTrustMetadata(
        state: .verifiedMappingV1,
        mappingVersion: PersistedOrdinalTrustPolicy.currentMappingVersion,
        provenance: .legacyMigration,
        sourceBookInitials: "KJVA",
        sourceVersification: "KJVA",
        sourceOrdinalStart: startOrdinal,
        sourceOrdinalEnd: endOrdinal
    )
}

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
    public let id: UUID
    public let bookInitials: String
    public let kjvOrdinal: Int
    public let memorizedAt: Int64

    /// Durable provenance for the value currently stored in `kjvOrdinal`.
    public let ordinalTrust: PersistedOrdinalTrustMetadata

    /**
     Creates one persisted memorized-verse row.

     - Parameters:
       - id: Stable row identifier, synthesized from the legacy identity when omitted.
       - bookInitials: Compatibility module scope; verified KJVA-global rows normally use an empty value.
       - kjvOrdinal: Persisted KJVA ordinal.
       - memorizedAt: Android-compatible millisecond timestamp.
       - ordinalTrust: Explicit provenance supplied by a validated write boundary. When omitted,
         the row is classified as legacy pending or unresolved and cannot enter consumers.
     - Side effects: none.
     - Failure modes: Invalid KJVA values are retained but marked unresolved.
     */
    public init(
        id: UUID? = nil,
        bookInitials: String = "",
        kjvOrdinal: Int,
        memorizedAt: Int64 = 0,
        ordinalTrust: PersistedOrdinalTrustMetadata? = nil
    ) {
        self.id = id ?? Self.stableID(bookInitials: bookInitials, kjvOrdinal: kjvOrdinal)
        self.bookInitials = bookInitials
        self.kjvOrdinal = kjvOrdinal
        self.memorizedAt = memorizedAt
        self.ordinalTrust = ordinalTrust ?? PersistedOrdinalTrustPolicy.legacyMetadata(
            sourceBookInitials: bookInitials,
            sourceOrdinalStart: kjvOrdinal,
            sourceOrdinalEnd: kjvOrdinal
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bookInitials
        case kjvOrdinal
        case memorizedAt
        case ordinalTrust
    }

    /**
     Decodes current and legacy memorized rows at the persisted-schema trust boundary.

     Origin-main rows with no trust object and empty module initials are known global KJVA data and
     receive an exact identity-mapping contract. Module-scoped rows still require startup migration.

     - Parameter decoder: Decoder containing one memorized-verse row.
     - Side effects: none.
     - Failure modes: Structural decoding errors are rethrown. Invalid KJVA ranges remain
       unresolved, and missing trust on a nonempty module scope remains pending.
     */
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bookInitials = try container.decodeIfPresent(String.self, forKey: .bookInitials) ?? ""
        let kjvOrdinal = try container.decode(Int.self, forKey: .kjvOrdinal)
        let memorizedAt = try container.decodeIfPresent(Int64.self, forKey: .memorizedAt) ?? 0
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id),
            bookInitials: bookInitials,
            kjvOrdinal: kjvOrdinal,
            memorizedAt: memorizedAt,
            ordinalTrust: try container.decodeIfPresent(
                PersistedOrdinalTrustMetadata.self,
                forKey: .ordinalTrust
            ) ?? decodedLegacyMemorizationTrustMetadata(
                bookInitials: bookInitials,
                startOrdinal: kjvOrdinal,
                endOrdinal: kjvOrdinal
            )
        )
    }

    /**
     Encodes a memorized row with its durable trust and source metadata.

     - Parameter encoder: Encoder receiving the persisted row.
     - Side effects: Writes to the supplied encoder only.
     - Failure modes: Rethrows encoder failures.
     */
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bookInitials, forKey: .bookInitials)
        try container.encode(kjvOrdinal, forKey: .kjvOrdinal)
        try container.encode(memorizedAt, forKey: .memorizedAt)
        try container.encode(ordinalTrust, forKey: .ordinalTrust)
    }

    /// Whether totals, rendering, sync, and backup may consume this row's KJVA ordinal.
    public var hasTrustedPersistedOrdinals: Bool {
        PersistedOrdinalTrustPolicy.isTrustedKJVARange(
            metadata: ordinalTrust,
            start: kjvOrdinal,
            end: kjvOrdinal
        )
    }

    private static func stableID(bookInitials: String, kjvOrdinal: Int) -> UUID {
        let seed = "memorized-verse|\(bookInitials)|\(kjvOrdinal)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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

    /// Durable provenance for the values currently stored in the KJVA endpoint fields.
    public let ordinalTrust: PersistedOrdinalTrustMetadata

    /**
     Creates one persisted memorization-target row.

     - Parameters:
       - id: Stable Android-compatible row identifier.
       - bookInitials: Compatibility module scope; verified global rows normally use an empty value.
       - startOrdinal: Persisted candidate KJVA start ordinal.
       - endOrdinal: Persisted candidate KJVA end ordinal.
       - createdAt: Android-compatible millisecond creation timestamp.
       - ordinalTrust: Explicit provenance supplied by a validated boundary. Omission fails closed
         as pending or unresolved legacy data.
     - Side effects: none.
     - Failure modes: This initializer retains invalid values for quarantine; trust policy prevents
       consumers from using them.
     */
    public init(
        id: UUID = UUID(),
        bookInitials: String = "",
        startOrdinal: Int,
        endOrdinal: Int,
        createdAt: Int64 = 0,
        ordinalTrust: PersistedOrdinalTrustMetadata? = nil
    ) {
        self.id = id
        self.bookInitials = bookInitials
        self.startOrdinal = startOrdinal
        self.endOrdinal = endOrdinal
        self.createdAt = createdAt
        self.ordinalTrust = ordinalTrust ?? PersistedOrdinalTrustPolicy.legacyMetadata(
            sourceBookInitials: bookInitials,
            sourceOrdinalStart: startOrdinal,
            sourceOrdinalEnd: endOrdinal
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case bookInitials
        case startOrdinal
        case endOrdinal
        case createdAt
        case ordinalTrust
    }

    /**
     Decodes current and legacy target rows at the persisted-schema trust boundary.

     Origin-main rows with no trust object and empty module initials are known global KJVA data and
     receive an exact identity-mapping contract. Module-scoped rows still require startup migration.

     - Parameter decoder: Decoder containing one target row.
     - Side effects: none.
     - Failure modes: Structural decoding errors are rethrown. Invalid KJVA ranges remain
       unresolved, and missing trust on a nonempty module scope remains pending.
     */
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bookInitials = try container.decodeIfPresent(String.self, forKey: .bookInitials) ?? ""
        let startOrdinal = try container.decode(Int.self, forKey: .startOrdinal)
        let endOrdinal = try container.decode(Int.self, forKey: .endOrdinal)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            createdAt: try container.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0,
            ordinalTrust: try container.decodeIfPresent(
                PersistedOrdinalTrustMetadata.self,
                forKey: .ordinalTrust
            ) ?? decodedLegacyMemorizationTrustMetadata(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal
            )
        )
    }

    /**
     Encodes a target row with its durable trust and source metadata.

     - Parameter encoder: Encoder receiving the persisted row.
     - Side effects: Writes to the supplied encoder only.
     - Failure modes: Rethrows encoder failures.
     */
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(bookInitials, forKey: .bookInitials)
        try container.encode(startOrdinal, forKey: .startOrdinal)
        try container.encode(endOrdinal, forKey: .endOrdinal)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(ordinalTrust, forKey: .ordinalTrust)
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

    /// Whether totals, rendering, sync, and backup may consume this target's KJVA range.
    public var hasTrustedPersistedOrdinals: Bool {
        PersistedOrdinalTrustPolicy.isTrustedKJVARange(
            metadata: ordinalTrust,
            start: startOrdinal,
            end: endOrdinal
        )
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
        get { targetRows.filter(\.hasTrustedPersistedOrdinals).map(\.range) }
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
            memorizedVerses: memorizedVerses ?? Self.legacyVerses(from: legacyMemorizedRanges),
            targetRows: targetRows ?? legacyTargetRanges.map(Self.legacyTargetRow(from:))
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
        let sorted = normalizedVerses(verses).filter(\.hasTrustedPersistedOrdinals).sorted {
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

    private static func legacyVerses(from ranges: [MemorizationProgressRange]) -> [MemorizedVerseProgress] {
        ranges.flatMap { range -> [MemorizedVerseProgress] in
            guard isRangeValid(range) else { return [] }
            return (range.startOrdinal...range.endOrdinal).map { ordinal in
                MemorizedVerseProgress(
                    bookInitials: range.bookInitials,
                    kjvOrdinal: ordinal,
                    ordinalTrust: decodedLegacyMemorizationTrustMetadata(
                        bookInitials: range.bookInitials,
                        startOrdinal: ordinal,
                        endOrdinal: ordinal
                    )
                )
            }
        }
    }

    private static func legacyTargetRow(from range: MemorizationProgressRange) -> MemorizationTargetRow {
        MemorizationTargetRow(
            bookInitials: range.bookInitials,
            startOrdinal: range.startOrdinal,
            endOrdinal: range.endOrdinal,
            ordinalTrust: decodedLegacyMemorizationTrustMetadata(
                bookInitials: range.bookInitials,
                startOrdinal: range.startOrdinal,
                endOrdinal: range.endOrdinal
            )
        )
    }

    fileprivate static func normalizedVerses(_ verses: [MemorizedVerseProgress]) -> [MemorizedVerseProgress] {
        var resultByKey: [String: MemorizedVerseProgress] = [:]
        for verse in verses {
            let key = verse.hasTrustedPersistedOrdinals
                ? "verified\u{0}\(verse.kjvOrdinal)"
                : "quarantined\u{0}\(verse.id.uuidString)"
            guard let existing = resultByKey[key] else {
                resultByKey[key] = verse
                continue
            }
            if verse.memorizedAt > existing.memorizedAt ||
                (verse.memorizedAt == existing.memorizedAt && verse.id.uuidString < existing.id.uuidString) {
                resultByKey[key] = verse
            }
        }
        return resultByKey.values.sorted {
            if $0.hasTrustedPersistedOrdinals != $1.hasTrustedPersistedOrdinals {
                return $0.hasTrustedPersistedOrdinals
            }
            if $0.bookInitials != $1.bookInitials {
                return $0.bookInitials < $1.bookInitials
            }
            if $0.kjvOrdinal != $1.kjvOrdinal {
                return $0.kjvOrdinal < $1.kjvOrdinal
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    fileprivate static func normalizedTargets(_ rows: [MemorizationTargetRow]) -> [MemorizationTargetRow] {
        rows.sorted {
            if $0.hasTrustedPersistedOrdinals != $1.hasTrustedPersistedOrdinals {
                return $0.hasTrustedPersistedOrdinals
            }
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

    /**
     Returns only memorization rows whose KJVA provenance is verified.

     - Returns: Normalized trusted rows safe for rendering, totals, navigation, sync, and backup.
     - Side effects: Reads persisted JSON from `SettingsStore`.
     - Failure modes: Missing or malformed JSON produces an empty snapshot; quarantined rows are
       omitted but remain durable in the persistence snapshot.
     */
    public func snapshot() -> MemorizationProgressSnapshot {
        let persisted = persistenceSnapshot()
        return MemorizationProgressSnapshot(
            memorizedVerses: persisted.memorizedVerses.filter(\.hasTrustedPersistedOrdinals),
            targetRows: persisted.targetRows.filter(\.hasTrustedPersistedOrdinals)
        )
    }

    /**
     Returns the complete normalized persistence snapshot, including quarantined legacy rows.

     - Returns: All durable memorization rows for migration and lossless replace operations.
     - Side effects: Reads persisted JSON from `SettingsStore`.
     - Failure modes: Missing or malformed JSON produces an empty snapshot.
     */
    func persistenceSnapshot() -> MemorizationProgressSnapshot {
        guard let rawValue = settingsStore.getString(Self.settingsKey),
              let data = rawValue.data(using: .utf8),
              let snapshot = try? decoder.decode(MemorizationProgressSnapshot.self, from: data) else {
            return MemorizationProgressSnapshot()
        }
        return Self.normalized(snapshot)
    }

    /**
     Decodes the complete local memorization snapshot without treating malformed JSON as empty.

     - Returns: Normalized trusted and quarantined rows, or an empty snapshot when no value exists.
     - Side effects: Reads one settings value.
     - Throws: `ProgressPersistenceSnapshotError.invalidMemorizationProgress` when a present value is
       not valid UTF-8 JSON for `MemorizationProgressSnapshot`.
     */
    func persistenceSnapshotStrict() throws -> MemorizationProgressSnapshot {
        guard let rawValue = settingsStore.getString(Self.settingsKey) else {
            return MemorizationProgressSnapshot()
        }
        guard let data = rawValue.data(using: .utf8),
              let snapshot = try? decoder.decode(MemorizationProgressSnapshot.self, from: data) else {
            throw ProgressPersistenceSnapshotError.invalidMemorizationProgress
        }
        return Self.normalized(snapshot)
    }

    /**
     Reports whether persisted legacy memorization JSON still lacks explicit trust metadata.

     - Returns: `true` when a legacy range collection is nonempty or any current row omits its
       `ordinalTrust` object; otherwise `false`.
     - Side effects: Reads and parses the persisted settings JSON.
     - Failure modes: Missing, malformed, or structurally unexpected JSON returns `false`; normal
       snapshot decoding already treats malformed persistence as empty.
     */
    func requiresOrdinalTrustMetadataBackfill() -> Bool {
        guard let rawValue = settingsStore.getString(Self.settingsKey),
              let data = rawValue.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return false
        }

        for key in ["memorizedRanges", "targetRanges"] {
            if let rows = root[key] as? [Any], !rows.isEmpty {
                return true
            }
        }
        for key in ["memorizedVerses", "targetRows"] {
            guard let rows = root[key] as? [[String: Any]] else { continue }
            if rows.contains(where: { $0["ordinalTrust"] == nil }) {
                return true
            }
        }
        return false
    }

    /**
     Replaces the complete persistence snapshot without discarding quarantined rows.

     - Parameter snapshot: Trusted and untrusted rows to normalize and persist.
     - Side effects: Encodes JSON and writes `memorization_progress_state_v1` through `SettingsStore`.
     - Throws: Encoding or mutation-journal persistence failures. The existing persisted value is
       left unchanged when the journaled save cannot commit.
     */
    func replacePersistenceSnapshot(_ snapshot: MemorizationProgressSnapshot) throws {
        try save(snapshot)
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

    /**
     Rejects the legacy integer-only target write boundary.

     Raw ordinals and module initials cannot prove that KJVA mapping occurred. Callers must build a
     `VerifiedKJVAOrdinalRange` from exact source references and use the typed overload.

     - Parameters:
       - bookInitials: Untrusted legacy module hint; ignored.
       - startOrdinal: Untrusted candidate start ordinal; ignored.
       - endOrdinal: Untrusted candidate end ordinal; ignored.
     - Returns: An empty delta without reading or mutating persistence.
     - Side effects: none.
     - Failure modes: Always fails closed.
     */
    @available(*, deprecated, message: "Use addMemorizationTargetIfNeeded(_:) with VerifiedKJVAOrdinalRange.")
    @discardableResult
    public func addMemorizationTargetIfNeeded(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> MemorizationProgressDelta {
        .empty
    }

    /**
     Adds a natively mapped target only when its exact KJVA range is not already present.

     - Parameter range: Complete source-to-KJVA mapping contract produced by the reader boundary.
     - Returns: KJVA target ordinals added by the mutation, or an empty delta for a duplicate.
     - Side effects: Persists a new target row through `SettingsStore` when needed.
     - Throws: Malformed existing persistence, encoding failure, or mutation-journal failure.
     */
    @discardableResult
    public func addMemorizationTargetIfNeeded(
        _ range: VerifiedKJVAOrdinalRange
    ) throws -> MemorizationProgressDelta {
        let snapshot = try persistenceSnapshotStrict()
        guard !snapshot.targetRows.contains(where: { row in
            row.startOrdinal == range.kjvaOrdinalStart &&
                row.endOrdinal == range.kjvaOrdinalEnd
        }) else {
            return .empty
        }
        return try addMemorizationTarget(range)
    }

    /**
     Rejects the legacy integer-only target insertion boundary.

     - Parameters:
       - bookInitials: Untrusted legacy module hint; ignored.
       - startOrdinal: Untrusted candidate start ordinal; ignored.
       - endOrdinal: Untrusted candidate end ordinal; ignored.
     - Returns: An empty delta without persisting a row.
     - Side effects: none.
     - Failure modes: Always fails closed because numeric KJVA validity is not provenance.
     */
    @available(*, deprecated, message: "Use addMemorizationTarget(_:) with VerifiedKJVAOrdinalRange.")
    @discardableResult
    public func addMemorizationTarget(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> MemorizationProgressDelta {
        .empty
    }

    /**
     Persists one target from an explicit native source-to-KJVA mapping boundary.

     - Parameter range: Complete source and mapped coordinates for the selected range.
     - Returns: Inclusive KJVA target ordinals added by the mutation.
     - Side effects: Appends and persists one KJVA-global target row with exact source metadata.
     - Throws: Malformed existing persistence, encoding failure, or mutation-journal failure.
     */
    @discardableResult
    public func addMemorizationTarget(
        _ range: VerifiedKJVAOrdinalRange
    ) throws -> MemorizationProgressDelta {
        var snapshot = try persistenceSnapshotStrict()
        snapshot.targetRows.append(
            MemorizationTargetRow(
                bookInitials: "",
                startOrdinal: range.kjvaOrdinalStart,
                endOrdinal: range.kjvaOrdinalEnd,
                createdAt: currentTimeMilliseconds(),
                ordinalTrust: range.ordinalTrust
            )
        )
        try save(snapshot)
        return MemorizationProgressDelta(
            addedTargets: Array(range.kjvaOrdinalStart...range.kjvaOrdinalEnd)
        )
    }

    /**
     Removes one trusted memorization target by stable row identity.

     - Parameter id: Identifier of the target row to remove.
     - Returns: Removed KJVA target ordinals, or an empty delta when the row is absent or quarantined.
     - Side effects: Persists the target-row removal through `SettingsStore`.
     - Throws: Malformed existing persistence, encoding failure, or mutation-journal failure.
       Quarantined rows remain durable.
     */
    @discardableResult
    public func removeMemorizationTarget(
        id: UUID
    ) throws -> MemorizationProgressDelta {
        var snapshot = try persistenceSnapshotStrict()
        guard let index = snapshot.targetRows.firstIndex(where: {
            $0.id == id && $0.hasTrustedPersistedOrdinals
        }) else {
            return .empty
        }
        let row = snapshot.targetRows.remove(at: index)
        try save(snapshot)
        return MemorizationProgressDelta(removedTargets: Self.ordinalArray(in: row.range))
    }

    /**
     Removes an inclusive KJVA span from every matching trusted target row.

     Partial overlaps are split only when each retained piece can be assigned exact row-specific
     source endpoints. All candidate rows are prepared in memory before persistence, so one
     non-invertible endpoint aborts the complete mutation and leaves every row unchanged.

     - Parameters:
       - bookInitials: Compatibility scope used by legacy module-specific queries; an empty value
         addresses KJVA-global rows.
       - startOrdinal: Inclusive KJVA removal start.
       - endOrdinal: Inclusive KJVA removal end.
     - Returns: KJVA target ordinals removed across matching rows, or an empty delta on failure.
     - Side effects: Persists the replacement target-row collection after all splits validate.
     - Throws: Malformed existing persistence, encoding failure, or mutation-journal failure.
       Invalid input, quarantined rows, and retained subsets without exact provenance fail closed
       without writing.
     */
    @discardableResult
    public func removeMemorizationTarget(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) throws -> MemorizationProgressDelta {
        guard let removal = Self.range(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal) else {
            return .empty
        }
        var snapshot = try persistenceSnapshotStrict()
        let splitCreatedAt = currentTimeMilliseconds()
        var remainingRows: [MemorizationTargetRow] = []
        var removedOrdinals: [Int] = []

        for row in snapshot.targetRows {
            guard row.hasTrustedPersistedOrdinals else {
                remainingRows.append(row)
                continue
            }
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

            if row.startOrdinal < removedStart {
                let retainedStart = row.startOrdinal
                let retainedEnd = removedStart - 1
                guard let retainedTrust = PersistedOrdinalTrustPolicy.trustedSubsetMetadata(
                    of: row.ordinalTrust,
                    persistedStart: row.startOrdinal,
                    persistedEnd: row.endOrdinal,
                    subsetStart: retainedStart,
                    subsetEnd: retainedEnd
                ) else {
                    return .empty
                }
                remainingRows.append(
                    MemorizationTargetRow(
                        bookInitials: row.bookInitials,
                        startOrdinal: retainedStart,
                        endOrdinal: retainedEnd,
                        createdAt: splitCreatedAt,
                        ordinalTrust: retainedTrust
                    )
                )
            }
            if row.endOrdinal > removedEnd {
                let retainedStart = removedEnd + 1
                let retainedEnd = row.endOrdinal
                guard let retainedTrust = PersistedOrdinalTrustPolicy.trustedSubsetMetadata(
                    of: row.ordinalTrust,
                    persistedStart: row.startOrdinal,
                    persistedEnd: row.endOrdinal,
                    subsetStart: retainedStart,
                    subsetEnd: retainedEnd
                ) else {
                    return .empty
                }
                remainingRows.append(
                    MemorizationTargetRow(
                        bookInitials: row.bookInitials,
                        startOrdinal: retainedStart,
                        endOrdinal: retainedEnd,
                        createdAt: splitCreatedAt,
                        ordinalTrust: retainedTrust
                    )
                )
            }
        }

        guard !removedOrdinals.isEmpty else {
            return .empty
        }
        snapshot.targetRows = remainingRows
        try save(snapshot)
        return MemorizationProgressDelta(removedTargets: removedOrdinals)
    }

    /**
     Rejects the legacy integer-only memorized-verse write boundary.

     - Parameters:
       - bookInitials: Untrusted legacy module hint; ignored.
       - startOrdinal: Untrusted candidate start ordinal; ignored.
       - endOrdinal: Untrusted candidate end ordinal; ignored.
     - Returns: An empty delta without persisting rows.
     - Side effects: none.
     - Failure modes: Always fails closed because numeric KJVA validity is not provenance.
     */
    @available(*, deprecated, message: "Use markAsMemorized(_:) with VerifiedKJVAOrdinalRange.")
    @discardableResult
    public func markAsMemorized(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> MemorizationProgressDelta {
        .empty
    }

    /**
     Persists memorized verses from an explicit native source-to-KJVA mapping boundary.

     Every generated KJVA row receives a single-ordinal source range proven by strict reverse and
     forward conversion. Persisting the whole selection on every row would make partial unmarking
     and future remapping ambiguous.

     - Parameter range: Complete source and mapped coordinates for the selected range.
     - Returns: KJVA ordinals newly marked as memorized.
     - Side effects: Appends and persists KJVA-global memorized rows with exact source metadata.
     - Throws: Malformed existing persistence, encoding failure, or mutation-journal failure. If
       any new KJVA ordinal lacks an exactly reversible source coordinate, the complete mutation
       fails closed before persistence.
     */
    @discardableResult
    public func markAsMemorized(
        _ range: VerifiedKJVAOrdinalRange
    ) throws -> MemorizationProgressDelta {
        var persistedSnapshot = try persistenceSnapshotStrict()
        let query = MemorizationProgressRange(
            bookInitials: "",
            startOrdinal: range.kjvaOrdinalStart,
            endOrdinal: range.kjvaOrdinalEnd
        )
        let trustedSnapshot = MemorizationProgressSnapshot(
            memorizedVerses: persistedSnapshot.memorizedVerses.filter(\.hasTrustedPersistedOrdinals),
            targetRows: persistedSnapshot.targetRows.filter(\.hasTrustedPersistedOrdinals)
        )
        let existing = Set(Self.memorizedOrdinals(in: query, snapshot: trustedSnapshot))
        let added = Array(range.kjvaOrdinalStart...range.kjvaOrdinalEnd).filter {
            !existing.contains($0)
        }
        guard !added.isEmpty else {
            return .empty
        }

        let memorizedAt = currentTimeMilliseconds()
        let addedRows = added.compactMap { ordinal -> MemorizedVerseProgress? in
            guard let exactRange = range.exactSubrange(
                kjvaOrdinalStart: ordinal,
                kjvaOrdinalEnd: ordinal
            ) else {
                return nil
            }
            return MemorizedVerseProgress(
                bookInitials: "",
                kjvOrdinal: ordinal,
                memorizedAt: memorizedAt,
                ordinalTrust: exactRange.ordinalTrust
            )
        }
        guard addedRows.count == added.count else {
            return .empty
        }
        persistedSnapshot.memorizedVerses.append(contentsOf: addedRows)
        try save(persistedSnapshot)
        return MemorizationProgressDelta(addedMemorized: added)
    }

    @discardableResult
    public func unmarkMemorized(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) throws -> MemorizationProgressDelta {
        guard let range = Self.range(bookInitials: bookInitials, startOrdinal: startOrdinal, endOrdinal: endOrdinal) else {
            return .empty
        }
        var snapshot = try persistenceSnapshotStrict()
        snapshot.memorizedVerses.removeAll { verse in
            verse.hasTrustedPersistedOrdinals &&
                Self.matchesStoredVerse(verse, query: range) &&
                verse.kjvOrdinal >= range.startOrdinal &&
                verse.kjvOrdinal <= range.endOrdinal
        }
        try save(snapshot)
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

    private func save(_ snapshot: MemorizationProgressSnapshot) throws {
        let normalized = Self.normalized(snapshot)
        let data = try encoder.encode(normalized)
        let rawValue = String(decoding: data, as: UTF8.self)
        try settingsStore.performJournaledSave {
            settingsStore.setString(Self.settingsKey, value: rawValue)
            try RemoteSyncMutationJournalService().recordLocalChanges(
                for: .progress,
                modelContext: nil,
                settingsStore: settingsStore
            )
        }
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
        AndroidTimestamp.currentMilliseconds()
    }
}
