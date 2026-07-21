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
    /// Quarantined local row keys omitted from export but protected from inferred deletes.
    public let suppressedKeys: Set<String>

    public init(
        memorizedVerseRowsByKey: [String: RemoteSyncCurrentProgressMemorizedVerseRow],
        chapterHistoryRowsByKey: [String: RemoteSyncCurrentProgressChapterReadHistoryRow],
        memorizationTargetRowsByKey: [String: RemoteSyncCurrentProgressMemorizationTargetRow],
        settingsRowsByKey: [String: RemoteSyncCurrentProgressSettingsRow],
        fingerprintsByKey: [String: String],
        suppressedKeys: Set<String> = []
    ) {
        self.memorizedVerseRowsByKey = memorizedVerseRowsByKey
        self.chapterHistoryRowsByKey = chapterHistoryRowsByKey
        self.memorizationTargetRowsByKey = memorizationTargetRowsByKey
        self.settingsRowsByKey = settingsRowsByKey
        self.fingerprintsByKey = fingerprintsByKey
        self.suppressedKeys = suppressedKeys
    }

    /**
     Reports whether a key is either exportable now or intentionally suppressed in local quarantine.

     - Parameter key: Android composite progress-row key.
     - Returns: `true` for current trusted rows and quarantined local rows, preventing omission from
       being interpreted as deletion.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public func containsRow(for key: String) -> Bool {
        memorizedVerseRowsByKey[key] != nil ||
            chapterHistoryRowsByKey[key] != nil ||
            memorizationTargetRowsByKey[key] != nil ||
            settingsRowsByKey[key] != nil ||
            suppressedKeys.contains(key)
    }
}

/**
 Preserves the Android table and composite-key identity for one accepted Progress row.

 The immutable value lets later generations emit deletions even when Android's initial backup kept
 `LogEntry` empty. Encoding and comparing an identity has no side effects and is deterministic for the
 same Android row key.
 */
struct RemoteSyncProgressAcceptedRowIdentity: Codable, Sendable, Equatable {
    /// Android table that owns the accepted row.
    let tableName: String

    /// First Android composite-key component.
    let entityID1: RemoteSyncSQLiteValue

    /// Second Android composite-key component.
    let entityID2: RemoteSyncSQLiteValue
}

/**
 Immutable Progress generation accepted after initial upload, inbound replay, or outbound upload.

 Android keeps the initial database's `LogEntry` table empty. This separate manifest retains the
 exact row identities needed for later deletions without inventing local Android operations.
 */
struct RemoteSyncProgressAcceptedGeneration: Codable, Sendable, Equatable {
    /// Exact fingerprints for rows in this accepted generation.
    let fingerprintsByKey: [String: String]

    /// Exact accepted row identities keyed by Android's canonical composite key.
    let rowsByKey: [String: RemoteSyncProgressAcceptedRowIdentity]

    /// Quarantined keys whose previously accepted identity and fingerprint remain protected.
    let suppressedKeys: Set<String>
}

/**
 Stores one complete accepted Progress generation with its monotonic local revision.

 Outbound acceptance compares the captured revision before replacing fingerprints and identities, so
 an inbound or initial-upload publication cannot be overwritten after a network suspension. Encoding,
 decoding, and comparing this value have no side effects.
 */
struct RemoteSyncProgressAcceptedBaseline: Codable, Sendable, Equatable {
    /// Monotonic local revision advanced by each accepted generation.
    let revision: Int64

    /// Complete accepted generation associated with `revision`.
    let generation: RemoteSyncProgressAcceptedGeneration
}

/**
 Describes failures that prevent Progress projection or accepted-baseline publication from proving a
 complete, trustworthy generation.

 The cases distinguish malformed local content, incomplete identity/fingerprint manifests, stale
 compare-and-swap revisions, and revision exhaustion. Constructing and comparing them has no side
 effects and is deterministic for the violated invariant.
 */
enum RemoteSyncProgressSnapshotError: Error, Equatable {
    /// Persisted chapter-reading progress JSON is present but structurally invalid.
    case invalidReadingProgressSnapshot

    /// Persisted memorization progress JSON is present but structurally invalid.
    case invalidMemorizationProgressSnapshot

    /// The stored accepted Progress generation cannot be decoded or validated safely.
    case invalidAcceptedBaseline

    /// A projected or accepted fingerprint has no matching typed row identity.
    case incompleteAcceptedGeneration(String)

    /// An exportable typed row did not receive a stable content fingerprint.
    case missingProjectedFingerprint(String)

    /// Another accepted generation advanced while an outbound archive was in flight.
    case staleAcceptedBaseline(expected: Int64, actual: Int64)

    /// The local accepted-generation revision exhausted its signed 64-bit range.
    case acceptedBaselineRevisionExhausted
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

    /// Local-only setting containing the revisioned accepted Progress generation.
    static let acceptedBaselineKey = "remote_sync.progress.accepted_baseline"

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
        let readingSnapshot = ReadingProgressStore(settingsStore: settingsStore).snapshot()
        let memorizationStore = MemorizationProgressStore(settingsStore: settingsStore)
        let memorizationSnapshot = memorizationStore.persistenceSnapshot()
        return projectCurrentState(
            readingSnapshot: readingSnapshot,
            memorizationSnapshot: memorizationSnapshot,
            settingsStore: settingsStore
        )
    }

    /**
     Projects current Progress while surfacing malformed persistence to destructive sync callers.

     Missing settings retain the same empty/default meaning as the ordinary stores. Present but
     malformed JSON throws instead of becoming an empty snapshot. When called inside an atomic batch,
     underlying settings fetch failures are also recorded by `SettingsStore` and abort that batch.

     - Parameter settingsStore: Store containing reading and memorization Progress JSON.
     - Returns: Current Android-shaped Progress rows and fingerprints.
     - Side effects: Reads both Progress settings rows and Android log-key metadata.
     - Throws: `RemoteSyncProgressSnapshotError` for malformed persisted Progress JSON.
     */
    func snapshotCurrentStateStrict(
        settingsStore: SettingsStore
    ) throws -> RemoteSyncProgressCurrentSnapshot {
        let readingSnapshot: ReadingProgressSnapshot
        do {
            readingSnapshot = try ReadingProgressStore(settingsStore: settingsStore).strictSnapshot()
        } catch {
            throw RemoteSyncProgressSnapshotError.invalidReadingProgressSnapshot
        }
        let memorizationSnapshot: MemorizationProgressSnapshot
        do {
            memorizationSnapshot = try MemorizationProgressStore(
                settingsStore: settingsStore
            ).persistenceSnapshotStrict()
        } catch {
            throw RemoteSyncProgressSnapshotError.invalidMemorizationProgressSnapshot
        }

        return projectCurrentState(
            readingSnapshot: readingSnapshot,
            memorizationSnapshot: memorizationSnapshot,
            settingsStore: settingsStore
        )
    }

    /**
     Converts already-decoded Progress generations into Android row dictionaries and fingerprints.

     - Parameters:
       - readingSnapshot: Decoded chapter history and global Progress settings.
       - memorizationSnapshot: Decoded trusted and quarantined memorization persistence.
       - settingsStore: Store used only to construct canonical Android composite keys.
     - Returns: Android-shaped current Progress generation.
     - Side effects: Reads no Progress content; constructs local log-key helpers only.
     - Failure modes: This deterministic projection cannot fail.
     */
    private func projectCurrentState(
        readingSnapshot: ReadingProgressSnapshot,
        memorizationSnapshot: MemorizationProgressSnapshot,
        settingsStore: SettingsStore
    ) -> RemoteSyncProgressCurrentSnapshot {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)

        var memorizedVerseRowsByKey: [String: RemoteSyncCurrentProgressMemorizedVerseRow] = [:]
        var chapterHistoryRowsByKey: [String: RemoteSyncCurrentProgressChapterReadHistoryRow] = [:]
        var memorizationTargetRowsByKey: [String: RemoteSyncCurrentProgressMemorizationTargetRow] = [:]
        var settingsRowsByKey: [String: RemoteSyncCurrentProgressSettingsRow] = [:]
        var fingerprintsByKey: [String: String] = [:]
        var suppressedKeys: Set<String> = []

        for row in memorizationSnapshot.memorizedVerses where !row.hasTrustedPersistedOrdinals {
            suppressedKeys.insert(key(for: Self.memorizedVerseTable, id: row.id, logEntryStore: logEntryStore))
        }
        for row in memorizationSnapshot.targetRows where !row.hasTrustedPersistedOrdinals {
            suppressedKeys.insert(key(for: Self.memorizationTargetTable, id: row.id, logEntryStore: logEntryStore))
        }

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
            fingerprintsByKey: fingerprintsByKey,
            suppressedKeys: suppressedKeys
        )
    }

    /**
     Refreshes the revisioned accepted Progress baseline from the current local projection.

     Compatibility callers retain soft failure behavior. Transactional restore/replay code should
     use `snapshotCurrentStateStrict`, `acceptedGeneration`, and `acceptBaselineFingerprints` inside
     its existing atomic publication batch.

     - Parameter settingsStore: Local-only store containing Progress content and accepted metadata.
     - Side effects: Atomically advances the accepted generation and its exact fingerprints.
     - Failure modes: Projection, validation, encoding, and transaction failures leave the prior
       baseline intact and are swallowed for compatibility with this public soft API.
     */
    public func refreshBaselineFingerprints(settingsStore: SettingsStore) {
        try? settingsStore.performAtomicBatch {
            try refreshBaselineFingerprintsStrict(settingsStore: settingsStore)
        }
    }

    /**
     Refreshes the accepted Progress generation while surfacing every projection/publication failure.

     Restore and patch-apply workers call this inside their existing atomic transaction so content,
     Android logs, patch status, typed identities, fingerprints, and revision commit or roll back together.

     - Parameter settingsStore: Local-only store containing Progress content and accepted metadata.
     - Side effects: Stages one exact accepted generation and advances its revision.
     - Throws: Strict content decoding, accepted-baseline validation, encoding, and settings failures.
     */
    func refreshBaselineFingerprintsStrict(settingsStore: SettingsStore) throws {
        let snapshot = try snapshotCurrentStateStrict(settingsStore: settingsStore)
        let previousBaseline = try storedAcceptedBaseline(settingsStore: settingsStore)
        let preservedGeneration: RemoteSyncProgressAcceptedGeneration
        if let previousGeneration = previousBaseline?.generation {
            preservedGeneration = previousGeneration
        } else {
            preservedGeneration = try legacyAcceptedGeneration(settingsStore: settingsStore)
        }
        try validateExportableFingerprints(in: snapshot)
        try acceptBaselineFingerprints(
            acceptedGeneration(from: snapshot, preserving: preservedGeneration),
            settingsStore: settingsStore
        )
    }

    /**
     Reconstructs the trustworthy portion of the pre-manifest Progress baseline.

     Older iOS builds persisted fingerprints and Android `LogEntry` rows separately. A row is accepted
     here only when both stores describe the same canonical non-delete identity, preserving quarantine
     evidence without importing anonymous fingerprints into the revisioned generation.

     - Parameter settingsStore: Local store containing legacy Progress logs and fingerprints.
     - Returns: A typed generation containing only exact identity/fingerprint pairs.
     - Side effects: Strictly enumerates Progress log and fingerprint settings; performs no writes.
     - Throws: `RemoteSyncProgressSnapshotError.invalidAcceptedBaseline` when a legacy log payload is
       malformed or stored under a key that does not match its decoded Android identity.
     */
    func legacyAcceptedGeneration(
        settingsStore: SettingsStore
    ) throws -> RemoteSyncProgressAcceptedGeneration {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let logPrefix = logEntryStore.prefix(for: .progress)
        let fingerprintPrefix = fingerprintStore.prefix(for: .progress)
        var rowsByKey: [String: RemoteSyncProgressAcceptedRowIdentity] = [:]

        for setting in settingsStore.entries(withPrefix: logPrefix) {
            guard let data = setting.value.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(RemoteSyncLogEntry.self, from: data),
                  setting.key == logEntryStore.key(for: .progress, entry: entry) else {
                throw RemoteSyncProgressSnapshotError.invalidAcceptedBaseline
            }
            guard entry.type != .delete else { continue }
            rowsByKey[setting.key] = RemoteSyncProgressAcceptedRowIdentity(
                tableName: entry.tableName,
                entityID1: entry.entityID1,
                entityID2: entry.entityID2
            )
        }

        var fingerprintsByKey: [String: String] = [:]
        for setting in settingsStore.entries(withPrefix: fingerprintPrefix) {
            let suffix = setting.key.dropFirst(fingerprintPrefix.count)
            guard !suffix.isEmpty else {
                throw RemoteSyncProgressSnapshotError.invalidAcceptedBaseline
            }
            let logKey = "\(logPrefix)\(suffix)"
            guard rowsByKey[logKey] != nil else { continue }
            fingerprintsByKey[logKey] = setting.value
        }
        rowsByKey = rowsByKey.filter { fingerprintsByKey[$0.key] != nil }

        return RemoteSyncProgressAcceptedGeneration(
            fingerprintsByKey: fingerprintsByKey,
            rowsByKey: rowsByKey,
            suppressedKeys: []
        )
    }

    /**
     Builds the immutable accepted generation represented by one exact Progress snapshot.

     Suppressed quarantine keys retain their prior identity and fingerprint so their temporary
     omission cannot become a delete or erase accepted evidence.

     - Parameters:
       - snapshot: Complete Progress projection whose rows and fingerprints share one generation.
       - previousGeneration: Prior accepted generation used only for currently suppressed keys.
     - Returns: Typed row identities, exact fingerprints, and quarantine preservation metadata.
     - Side effects: none.
     - Failure modes: This deterministic conversion cannot fail.
     */
    func acceptedGeneration(
        from snapshot: RemoteSyncProgressCurrentSnapshot,
        preserving previousGeneration: RemoteSyncProgressAcceptedGeneration? = nil
    ) -> RemoteSyncProgressAcceptedGeneration {
        var rowsByKey: [String: RemoteSyncProgressAcceptedRowIdentity] = [:]
        func addIdentity(key: String, tableName: String, id: UUID) {
            guard !snapshot.suppressedKeys.contains(key) else { return }
            rowsByKey[key] = RemoteSyncProgressAcceptedRowIdentity(
                tableName: tableName,
                entityID1: .blob(Self.uuidBlob(id)),
                entityID2: .text("")
            )
        }

        for (key, row) in snapshot.memorizedVerseRowsByKey {
            addIdentity(key: key, tableName: Self.memorizedVerseTable, id: row.id)
        }
        for (key, row) in snapshot.chapterHistoryRowsByKey {
            addIdentity(key: key, tableName: Self.chapterReadHistoryTable, id: row.id)
        }
        for (key, row) in snapshot.memorizationTargetRowsByKey {
            addIdentity(key: key, tableName: Self.memorizationTargetTable, id: row.id)
        }
        for (key, row) in snapshot.settingsRowsByKey {
            addIdentity(key: key, tableName: Self.globalSettingsTable, id: row.id)
        }

        var fingerprintsByKey = snapshot.fingerprintsByKey.filter {
            !snapshot.suppressedKeys.contains($0.key)
        }
        for key in snapshot.suppressedKeys {
            if let priorFingerprint = previousGeneration?.fingerprintsByKey[key] {
                fingerprintsByKey[key] = priorFingerprint
            }
            if let priorIdentity = previousGeneration?.rowsByKey[key] {
                rowsByKey[key] = priorIdentity
            }
        }
        return RemoteSyncProgressAcceptedGeneration(
            fingerprintsByKey: fingerprintsByKey,
            rowsByKey: rowsByKey,
            suppressedKeys: snapshot.suppressedKeys
        )
    }

    /**
     Validates that every exportable Progress row has exactly one stable fingerprint.

     - Parameter snapshot: Strict current Progress projection to validate.
     - Side effects: none.
     - Throws: `missingProjectedFingerprint` or `incompleteAcceptedGeneration` when exportable row
       and fingerprint key sets differ.
     */
    func validateExportableFingerprints(in snapshot: RemoteSyncProgressCurrentSnapshot) throws {
        let rowKeys = Set(snapshot.memorizedVerseRowsByKey.keys)
            .union(snapshot.chapterHistoryRowsByKey.keys)
            .union(snapshot.memorizationTargetRowsByKey.keys)
            .union(snapshot.settingsRowsByKey.keys)
            .subtracting(snapshot.suppressedKeys)
        let fingerprintKeys = Set(snapshot.fingerprintsByKey.keys)
            .subtracting(snapshot.suppressedKeys)
        if let missingKey = rowKeys.subtracting(fingerprintKeys).sorted().first {
            throw RemoteSyncProgressSnapshotError.missingProjectedFingerprint(missingKey)
        }
        if let orphanKey = fingerprintKeys.subtracting(rowKeys).sorted().first {
            throw RemoteSyncProgressSnapshotError.incompleteAcceptedGeneration(orphanKey)
        }
    }

    /**
     Reads the complete revisioned accepted Progress baseline when one has been published.

     - Parameter settingsStore: Local-only store containing accepted Progress metadata.
     - Returns: Accepted baseline, or `nil` before initial baseline publication.
     - Side effects: Reads one settings row.
     - Throws: `invalidAcceptedBaseline` for malformed, negative-revision, or internally incomplete data.
     */
    func storedAcceptedBaseline(
        settingsStore: SettingsStore
    ) throws -> RemoteSyncProgressAcceptedBaseline? {
        guard let rawValue = settingsStore.getString(Self.acceptedBaselineKey) else {
            return nil
        }
        guard let data = rawValue.data(using: .utf8),
              let baseline = try? JSONDecoder().decode(RemoteSyncProgressAcceptedBaseline.self, from: data),
              baseline.revision >= 0 else {
            throw RemoteSyncProgressSnapshotError.invalidAcceptedBaseline
        }
        try validateAcceptedGeneration(baseline.generation)
        return baseline
    }

    /**
     Reads the accepted row-identity manifest used for deletion detection without synthetic logs.

     - Parameter settingsStore: Local settings store containing the revisioned Progress baseline.
     - Returns: Exact accepted identities keyed by Android composite key, or `nil` before publication.
     - Side effects: Reads one settings row and performs no mutation.
     - Throws: `invalidAcceptedBaseline` or generation-validation errors when persisted data is unsafe.
     */
    func acceptedRowsByKey(
        settingsStore: SettingsStore
    ) throws -> [String: RemoteSyncProgressAcceptedRowIdentity]? {
        try storedAcceptedBaseline(settingsStore: settingsStore)?.generation.rowsByKey
    }

    /**
     Atomically stages one exact Progress generation and advances its local CAS revision.

     Callers invoke this inside their existing `SettingsStore.performAtomicBatch`. Android `LogEntry`
     rows are deliberately untouched; the typed row manifest carries initial-backup deletion evidence.

     - Parameters:
       - generation: Immutable fingerprints, identities, and suppressed-key preservation state.
       - settingsStore: Local settings store receiving accepted fingerprints and generation metadata.
       - expectedRevision: Optional compare-and-swap revision captured before network suspension.
     - Returns: Newly accepted revision.
     - Side effects: Replaces the exact accepted fingerprint generation and writes one revisioned manifest.
     - Throws: Validation, stale-revision, revision-overflow, encoding, and strict settings failures.
     */
    @discardableResult
    func acceptBaselineFingerprints(
        _ generation: RemoteSyncProgressAcceptedGeneration,
        settingsStore: SettingsStore,
        expectedRevision: Int64? = nil
    ) throws -> Int64 {
        try validateAcceptedGeneration(generation)
        let currentBaseline = try storedAcceptedBaseline(settingsStore: settingsStore)
        let currentRevision = currentBaseline?.revision ?? 0
        if let expectedRevision, expectedRevision != currentRevision {
            throw RemoteSyncProgressSnapshotError.staleAcceptedBaseline(
                expected: expectedRevision,
                actual: currentRevision
            )
        }

        replaceBaselineFingerprints(
            with: generation.fingerprintsByKey,
            settingsStore: settingsStore
        )
        let (nextRevision, overflow) = currentRevision.addingReportingOverflow(1)
        guard !overflow else {
            throw RemoteSyncProgressSnapshotError.acceptedBaselineRevisionExhausted
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            RemoteSyncProgressAcceptedBaseline(revision: nextRevision, generation: generation)
        )
        settingsStore.setString(Self.acceptedBaselineKey, value: String(decoding: data, as: UTF8.self))
        return nextRevision
    }

    /**
     Verifies that accepted fingerprints and typed identities form a complete one-to-one generation.

     - Parameter generation: Candidate generation captured from strict projected Progress content.
     - Side effects: none.
     - Throws: `missingProjectedFingerprint` for an identity without a fingerprint, or
       `incompleteAcceptedGeneration` for a fingerprint without a typed identity.
     */
    private func validateAcceptedGeneration(
        _ generation: RemoteSyncProgressAcceptedGeneration
    ) throws {
        let rowKeys = Set(generation.rowsByKey.keys)
        let fingerprintKeys = Set(generation.fingerprintsByKey.keys)
        if let missingKey = rowKeys.subtracting(fingerprintKeys).sorted().first {
            throw RemoteSyncProgressSnapshotError.missingProjectedFingerprint(missingKey)
        }
        if let orphanKey = fingerprintKeys.subtracting(rowKeys).sorted().first {
            throw RemoteSyncProgressSnapshotError.incompleteAcceptedGeneration(orphanKey)
        }
    }

    /**
     Replaces the accepted Progress fingerprint generation without re-reading live Progress content.

     All prior fingerprint rows are removed before the supplied generation is written. Suppressed
     accepted fingerprints have already been copied into that typed generation from its prior baseline;
     preserving anonymous leftovers here would separate fingerprints from their required identities.

     - Parameters:
       - fingerprintsByKey: Exact accepted fingerprints keyed by Android `LogEntry` identity.
       - settingsStore: Local settings store owning Progress fingerprint rows.
     - Side effects: Replaces every Progress fingerprint with the exact supplied generation.
     - Failure modes: Ordinary callers retain soft settings persistence; callers inside
       `SettingsStore.performAtomicBatch` surface fetch and commit failures atomically.
     */
    private func replaceBaselineFingerprints(
        with fingerprintsByKey: [String: String],
        settingsStore: SettingsStore
    ) {
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)

        let logPrefix = logEntryStore.prefix(for: .progress)
        let fingerprintPrefix = fingerprintStore.prefix(for: .progress)
        for existing in settingsStore.entries(withPrefix: fingerprintPrefix) {
            settingsStore.remove(existing.key)
        }

        for (logKey, fingerprint) in fingerprintsByKey.sorted(by: { $0.key < $1.key }) {
            guard logKey.hasPrefix(logPrefix) else {
                continue
            }
            let suffix = logKey.dropFirst(logPrefix.count)
            settingsStore.setString("\(fingerprintPrefix)\(suffix)", value: fingerprint)
        }
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

    private static func exportableMemorizedVerses(
        in verses: [MemorizedVerseProgress]
    ) -> [RemoteSyncCurrentProgressMemorizedVerseRow] {
        var rowsByOrdinal: [Int: MemorizedVerseProgress] = [:]
        for verse in verses where verse.hasTrustedPersistedOrdinals && progressOrdinalRange.contains(verse.kjvOrdinal) {
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
            .filter {
                $0.cycle > 0 && ReadingProgressKJVAIdentity(
                    androidKJVBookOrdinal: $0.kjvBookOrdinal,
                    chapter: $0.chapter
                ) != nil
            }
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
                $0.hasTrustedPersistedOrdinals &&
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

}
