// RemoteSyncReadingPlanSnapshotService.swift — Android-shaped local reading-plan snapshots for outbound sync

import Foundation
import SwiftData
import CryptoKit

/**
 Current local representation of one Android `ReadingPlan` row.
 */
public struct RemoteSyncCurrentReadingPlanRow: Sendable, Equatable, Codable {
    /// Android-compatible row identifier.
    public let id: UUID

    /// Android reading-plan code.
    public let planCode: String

    /// Android millisecond timestamp for the plan start date.
    public let planStartDateMillis: Int64

    /// Android current-day field.
    public let planCurrentDay: Int

    /**
     Creates one Android-shaped current reading-plan row.

     - Parameters:
       - id: Android-compatible row identifier.
       - planCode: Android reading-plan code.
       - planStartDateMillis: Android millisecond timestamp for the plan start date.
       - planCurrentDay: Android current-day field.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(id: UUID, planCode: String, planStartDateMillis: Int64, planCurrentDay: Int) {
        self.id = id
        self.planCode = planCode
        self.planStartDateMillis = planStartDateMillis
        self.planCurrentDay = planCurrentDay
    }
}

/**
 Current local representation of one Android `ReadingPlanStatus` row.
 */
public struct RemoteSyncCurrentReadingPlanStatusRow: Sendable, Equatable, Codable {
    /// Android-compatible row identifier.
    public let id: UUID

    /// Android reading-plan code that owns the status row.
    public let planCode: String

    /// Android one-based plan day.
    public let planDay: Int

    /// Raw Android `readingStatus` JSON payload.
    public let readingStatusJSON: String

    /**
     Creates one Android-shaped current reading-plan status row.

     - Parameters:
       - id: Android-compatible row identifier.
       - planCode: Android reading-plan code that owns the status row.
       - planDay: Android one-based plan day.
       - readingStatusJSON: Raw Android `readingStatus` JSON payload.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(id: UUID, planCode: String, planDay: Int, readingStatusJSON: String) {
        self.id = id
        self.planCode = planCode
        self.planDay = planDay
        self.readingStatusJSON = readingStatusJSON
    }
}

/**
 Snapshot of the current local reading-plan state expressed in Android row form.

 The snapshot carries both the typed row payloads and precomputed fingerprints keyed by Android's
 `(tableName, entityId1, entityId2)` composite identifier so outbound patch creation can diff
 efficiently without re-encoding rows repeatedly.
 */
public struct RemoteSyncReadingPlanCurrentSnapshot: Sendable, Equatable {
    /// Android-shaped current `ReadingPlan` rows keyed by local settings/log-entry key.
    public let planRowsByKey: [String: RemoteSyncCurrentReadingPlanRow]

    /// Android-shaped current `ReadingPlanStatus` rows keyed by local settings/log-entry key.
    public let statusRowsByKey: [String: RemoteSyncCurrentReadingPlanStatusRow]

    /// Stable content fingerprints for Android v1 plan and status rows keyed by composite key.
    public let fingerprintsByKey: [String: String]

    /// Quarantined row keys omitted from export whose accepted baseline must remain intact.
    public let suppressedKeys: Set<String>

    /**
     Creates one current-state reading-plan snapshot.

     - Parameters:
       - planRowsByKey: Android-shaped current `ReadingPlan` rows keyed by local settings/log-entry key.
       - statusRowsByKey: Android-shaped current `ReadingPlanStatus` rows keyed by local settings/log-entry key.
       - fingerprintsByKey: Stable fingerprints for Android v1 plan and status rows.
       - suppressedKeys: Quarantined keys omitted from export and protected from inferred deletes.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        planRowsByKey: [String: RemoteSyncCurrentReadingPlanRow],
        statusRowsByKey: [String: RemoteSyncCurrentReadingPlanStatusRow],
        fingerprintsByKey: [String: String],
        suppressedKeys: Set<String> = []
    ) {
        self.planRowsByKey = planRowsByKey
        self.statusRowsByKey = statusRowsByKey
        self.fingerprintsByKey = fingerprintsByKey
        self.suppressedKeys = suppressedKeys
    }
}

/**
 Identifies one reading-plan row that belongs to an accepted outbound or restored generation.

 The identity deliberately excludes timestamps and operation type. It is a durable manifest key
 used to emit a later delete even when Android's initial `LogEntry` table did not contain a row for
 the accepted entity.
 */
struct RemoteSyncReadingPlanAcceptedRowIdentity: Codable, Sendable, Equatable {
    /// Android table that owns the accepted row.
    let tableName: String

    /// First Android composite-key component.
    let entityID1: RemoteSyncSQLiteValue

    /// Second Android composite-key component.
    let entityID2: RemoteSyncSQLiteValue
}

/**
 Immutable reading-plan baseline accepted after restore, replay, or outbound upload.

 Fingerprints and row identities come from the same projected generation. Keeping them together
 prevents a post-upload live graph read from accepting edits that were not present in the archive.
 */
struct RemoteSyncReadingPlanAcceptedGeneration: Codable, Sendable, Equatable {
    /// Exact row fingerprints carried by the accepted generation.
    let fingerprintsByKey: [String: String]

    /// Exact accepted row identities keyed by Android's canonical composite key.
    let rowsByKey: [String: RemoteSyncReadingPlanAcceptedRowIdentity]

    /// Quarantined keys whose prior accepted identity and fingerprint remain preserved.
    let suppressedKeys: Set<String>
}

/**
 Durable revisioned reading-plan baseline used for compare-and-swap publication.
 */
struct RemoteSyncReadingPlanAcceptedBaseline: Codable, Sendable, Equatable {
    /// Monotonic local revision incremented by every inbound or outbound baseline acceptance.
    let revision: Int64

    /// Complete accepted generation associated with `revision`.
    let generation: RemoteSyncReadingPlanAcceptedGeneration
}

/**
 Errors raised while reading or publishing the durable reading-plan accepted-row manifest.
 */
enum RemoteSyncReadingPlanSnapshotError: Error, Equatable {
    /// The stored accepted baseline could not be decoded safely.
    case invalidAcceptedBaseline

    /// A projected fingerprint had no matching typed row identity.
    case incompleteAcceptedGeneration(String)

    /// One exportable typed row did not have a stable content fingerprint.
    case missingProjectedFingerprint(String)

    /// Preserved Android status metadata could not be projected completely.
    case invalidStoredStatusMetadata

    /// Another accepted generation advanced while an outbound archive was in flight.
    case staleAcceptedBaseline(expected: Int64, actual: Int64)
}

/**
 Projects current local reading-plan state into Android-shaped rows and row fingerprints.

 Outbound reading-plan sync needs the inverse of the restore/replay path:
 - convert local `ReadingPlan` models back into Android `ReadingPlan` rows
 - convert preserved or synthesized per-day progress into Android `ReadingPlanStatus` rows
 - compute stable content fingerprints keyed by Android's composite identifier so later patch
   creation can detect inserts, updates, and deletes without depending on hidden SQLite triggers

 Mapping notes:
 - preserved Android `remoteStatusID` values are reused when present
 - locally completed days without preserved Android status JSON are synthesized as fully-read
   `chapterReadArray` payloads using the current reading assignment count
 - non-date-based days before `currentDay` are not synthesized because Android treats them as
   historic progress derived from the plan row itself
 - synthesized status identifiers are deterministic so later uploads keep stable row keys even
   before Android-origin status metadata exists

 Data dependencies:
 - `ModelContext` provides live `ReadingPlan` and `ReadingPlanDay` rows
 - `RemoteSyncReadingPlanStatusStore` provides preserved Android status payloads and optional remote ids
 - `RemoteSyncReadingPlanDefinitionStore` recovers interrupted local definition publication before
   graph projection
 - `RemoteSyncLogEntryStore` provides canonical Android composite-key encoding
 - `RemoteSyncRowFingerprintStore` persists baseline fingerprints after restore/replay or upload

 Side effects:
 - `snapshotCurrentState` reads local SwiftData and settings rows and may recover an interrupted
   custom-definition publication
 - `refreshBaselineFingerprints` rewrites local fingerprint rows for the reading-plan category

 Failure modes:
 - compatibility entry points swallow SwiftData fetch failures and return an empty snapshot or leave
   the existing baseline unchanged
 - strict entry points rethrow SwiftData fetch, settings, and definition-publication recovery failures
   so synchronization can abort before publishing an incomplete generation

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement rules of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncReadingPlanSnapshotService {
    /// Local-only setting containing the revisioned accepted reading-plan generation.
    static let acceptedBaselineKey = "remote_sync.readingplans.accepted_baseline"

    /// Prefix owned by preserved Android reading-plan status metadata.
    private static let preservedStatusPrefix = "remote_sync.readingplans.android_status"

    /// Fetches the complete local plan graph for snapshot projection.
    private let planFetcher: (ModelContext) throws -> [ReadingPlan]

    /// Recovers interrupted custom-definition publication before graph projection.
    private let definitionStore: RemoteSyncReadingPlanDefinitionStore

    /**
     Creates a reading-plan snapshot service.

     - Parameters:
       - userPlanDirectory: Android-equivalent directory containing custom `.properties` files.
       - fileManager: Filesystem implementation used for definition-publication recovery.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory(),
        fileManager: FileManager = .default
    ) {
        planFetcher = { modelContext in
            try modelContext.fetch(FetchDescriptor<ReadingPlan>())
        }
        definitionStore = RemoteSyncReadingPlanDefinitionStore(
            userPlanDirectory: userPlanDirectory,
            fileManager: fileManager
        )
    }

    /**
     Creates a snapshot service with an explicit plan-fetch behavior.

     This initializer exists for behavior-level tests that must prove destructive synchronization
     fails closed when SwiftData cannot project the current plan graph.

     - Parameters:
       - planFetcher: Throwing operation that returns every current local reading plan.
       - userPlanDirectory: Android-equivalent directory containing custom `.properties` files.
       - fileManager: Filesystem implementation used for definition-publication recovery.
     - Side effects: none until a snapshot is requested.
     - Failure modes: The initializer cannot fail; fetch errors are handled by the selected snapshot
       entry point.
     */
    init(
        planFetcher: @escaping (ModelContext) throws -> [ReadingPlan],
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory(),
        fileManager: FileManager = .default
    ) {
        self.planFetcher = planFetcher
        definitionStore = RemoteSyncReadingPlanDefinitionStore(
            userPlanDirectory: userPlanDirectory,
            fileManager: fileManager
        )
    }

    /**
     Projects the current local reading-plan state into Android-shaped rows and row fingerprints.

     - Parameters:
       - modelContext: SwiftData context that owns the current reading-plan graph.
       - settingsStore: Local-only settings store that holds preserved Android status payloads.
     - Returns: Android-shaped current rows and their stable fingerprints keyed by Android composite key.
     - Side effects:
       - reads current `ReadingPlan` rows from SwiftData
       - reads preserved Android `ReadingPlanStatus` payloads from `SettingsStore`
       - may recover an interrupted custom-definition publication
     - Failure modes:
       - graph, settings, and definition-recovery failures are swallowed and reported as an
         empty snapshot for compatibility with non-destructive upload callers
     */
    public func snapshotCurrentState(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) -> RemoteSyncReadingPlanCurrentSnapshot {
        (try? snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )) ?? RemoteSyncReadingPlanCurrentSnapshot(
            planRowsByKey: [:],
            statusRowsByKey: [:],
            fingerprintsByKey: [:]
        )
    }

    /**
     Projects current local reading-plan state without suppressing graph-read failures.

     Destructive synchronization can use this entry point so a transient SwiftData fetch failure
     cannot be mistaken for an authoritative empty reading-plan graph.

     - Parameters:
       - modelContext: SwiftData context that owns the current reading-plan graph.
       - settingsStore: Local-only settings store that holds preserved Android status payloads.
     - Returns: Android-shaped current rows and stable fingerprints keyed by Android composite key.
     - Side effects:
       - reads current `ReadingPlan` rows from SwiftData
       - reads preserved Android `ReadingPlanStatus` payloads from `SettingsStore`
       - may recover an interrupted custom-definition publication
     - Throws: Rethrows plan-fetch, settings-decoding, and custom-definition recovery failures
       without producing a partial snapshot.
     */
    func snapshotCurrentStateStrict(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncReadingPlanCurrentSnapshot {
        try definitionStore.prepareForSnapshot(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let decodedStoredStatuses = try statusStore.allStatusesStrict()
        let exactTimestamps = try RemoteSyncReadingPlanTimestampStore(
            settingsStore: settingsStore
        ).allMilliseconds()
        let localPlans = try planFetcher(modelContext)
            .sorted { lhs, rhs in
                if lhs.planCode == rhs.planCode {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.planCode < rhs.planCode
            }

        let storedStatuses = Dictionary(
            uniqueKeysWithValues: decodedStoredStatuses.map {
                (Self.statusKey(planCode: $0.planCode, dayNumber: $0.dayNumber), $0)
            }
        )

        var planRowsByKey: [String: RemoteSyncCurrentReadingPlanRow] = [:]
        var statusRowsByKey: [String: RemoteSyncCurrentReadingPlanStatusRow] = [:]
        var fingerprintsByKey: [String: String] = [:]

        for plan in localPlans {
            let planStartDateMillis: Int64
            if let preserved = exactTimestamps[plan.id] {
                planStartDateMillis = preserved
            } else {
                planStartDateMillis = try AndroidTimestamp.milliseconds(from: plan.startDate)
            }
            let planRow = RemoteSyncCurrentReadingPlanRow(
                id: plan.id,
                planCode: plan.planCode,
                planStartDateMillis: planStartDateMillis,
                planCurrentDay: plan.currentDay
            )
            let planKey = logEntryStore.key(
                for: .readingPlans,
                tableName: "ReadingPlan",
                entityID1: .blob(Self.uuidBlob(plan.id)),
                entityID2: .text("")
            )
            planRowsByKey[planKey] = planRow
            fingerprintsByKey[planKey] = Self.fingerprintHex(for: planRow)

            let localDays = (plan.days ?? []).sorted { $0.dayNumber < $1.dayNumber }
            for day in localDays {
                let storedStatus = storedStatuses[Self.statusKey(planCode: plan.planCode, dayNumber: day.dayNumber)]
                guard let statusRow = makeStatusRow(
                    plan: plan,
                    day: day,
                    storedStatus: storedStatus
                ) else {
                    continue
                }

                let statusKey = logEntryStore.key(
                    for: .readingPlans,
                    tableName: "ReadingPlanStatus",
                    entityID1: .blob(Self.uuidBlob(statusRow.id)),
                    entityID2: .text("")
                )
                statusRowsByKey[statusKey] = statusRow
                fingerprintsByKey[statusKey] = Self.fingerprintHex(for: statusRow)
            }
        }

        return RemoteSyncReadingPlanCurrentSnapshot(
            planRowsByKey: planRowsByKey,
            statusRowsByKey: statusRowsByKey,
            fingerprintsByKey: fingerprintsByKey
        )
    }

    /**
     Replaces the stored fingerprint baseline for reading-plan rows with the current local snapshot.

     This method is intended to run after remote initial-backup restores or remote patch replay so
     later outbound patch creation compares local edits against the newly accepted remote baseline
     instead of stale pre-restore content hashes.

     - Parameters:
       - modelContext: SwiftData context that owns the current reading-plan graph.
       - settingsStore: Local-only settings store used by the fingerprint store.
     - Side effects:
       - rewrites fingerprint rows for current `ReadingPlan` and `ReadingPlanStatus` entries
       - removes stale fingerprint rows whose Android keys are no longer present locally
     - Failure modes:
       - fetch failures while reading the current plan graph are swallowed, leaving the existing
         baseline unchanged for compatibility with non-destructive callers
     */
    public func refreshBaselineFingerprints(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) {
        try? refreshBaselineFingerprintsStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
    }

    /**
     Replaces reading-plan fingerprint baselines and propagates graph-projection failures.

     Patch publication calls this method inside its enclosing atomic batch. A failed projection
     therefore aborts and rolls back graph, status, log, patch-status, and fingerprint mutations as
     one generation.

     - Parameters:
       - modelContext: SwiftData context that owns the current reading-plan graph.
       - settingsStore: Local-only settings store used by the fingerprint store.
     - Side effects:
       - rewrites fingerprint rows for current `ReadingPlan` and `ReadingPlanStatus` entries
       - removes stale fingerprint rows whose Android keys are no longer present locally
     - Throws: Rethrows SwiftData plan-fetch failures before accepting an incomplete baseline.
     */
    func refreshBaselineFingerprintsStrict(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws {
        let snapshot = try snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let previousBaseline = try storedAcceptedBaseline(settingsStore: settingsStore)
        try validateExportableFingerprints(in: snapshot)
        try acceptBaselineFingerprints(
            acceptedGeneration(from: snapshot, preserving: previousBaseline?.generation),
            settingsStore: settingsStore
        )
    }

    /**
     Builds the immutable accepted baseline represented by one projected snapshot.

     - Parameter snapshot: Complete reading-plan projection whose rows and fingerprints belong to
       the same generation.
     - Returns: Exact fingerprints and accepted row identities suitable for durable outbox storage.
     - Side effects: none.
     - Failure modes: This helper cannot fail because every projected row has a typed identity.
     */
    func acceptedGeneration(
        from snapshot: RemoteSyncReadingPlanCurrentSnapshot,
        preserving previousGeneration: RemoteSyncReadingPlanAcceptedGeneration? = nil
    ) -> RemoteSyncReadingPlanAcceptedGeneration {
        var rowsByKey: [String: RemoteSyncReadingPlanAcceptedRowIdentity] = [:]
        for (key, row) in snapshot.planRowsByKey where !snapshot.suppressedKeys.contains(key) {
            rowsByKey[key] = RemoteSyncReadingPlanAcceptedRowIdentity(
                tableName: "ReadingPlan",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
        }
        for (key, row) in snapshot.statusRowsByKey where !snapshot.suppressedKeys.contains(key) {
            rowsByKey[key] = RemoteSyncReadingPlanAcceptedRowIdentity(
                tableName: "ReadingPlanStatus",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
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
        return RemoteSyncReadingPlanAcceptedGeneration(
            fingerprintsByKey: fingerprintsByKey,
            rowsByKey: rowsByKey,
            suppressedKeys: snapshot.suppressedKeys
        )
    }

    /**
     Validates that every exportable projected row has one stable fingerprint and no orphan hash.

     - Parameter snapshot: Strict current reading-plan projection to validate.
     - Side effects: none.
     - Throws: `missingProjectedFingerprint` or `incompleteAcceptedGeneration` when row and
       fingerprint key sets differ outside explicitly suppressed quarantine keys.
     */
    func validateExportableFingerprints(
        in snapshot: RemoteSyncReadingPlanCurrentSnapshot
    ) throws {
        let rowKeys = Set(snapshot.planRowsByKey.keys)
            .union(snapshot.statusRowsByKey.keys)
            .subtracting(snapshot.suppressedKeys)
        let fingerprintKeys = Set(snapshot.fingerprintsByKey.keys)
            .subtracting(snapshot.suppressedKeys)
        if let missingKey = rowKeys.subtracting(fingerprintKeys).sorted().first {
            throw RemoteSyncReadingPlanSnapshotError.missingProjectedFingerprint(missingKey)
        }
        if let orphanKey = fingerprintKeys.subtracting(rowKeys).sorted().first {
            throw RemoteSyncReadingPlanSnapshotError.incompleteAcceptedGeneration(orphanKey)
        }
    }

    /**
     Reads the complete revisioned accepted baseline when one has been published.

     - Parameter settingsStore: Local-only settings store containing synchronization metadata.
     - Returns: Accepted baseline, or `nil` before initial baseline publication.
     - Side effects: Reads one settings row.
     - Throws: `invalidAcceptedBaseline` for malformed persisted data; strict settings failures
       invalidate an enclosing atomic batch.
     */
    func storedAcceptedBaseline(
        settingsStore: SettingsStore
    ) throws -> RemoteSyncReadingPlanAcceptedBaseline? {
        guard let rawValue = settingsStore.getString(Self.acceptedBaselineKey) else {
            return nil
        }
        guard let data = rawValue.data(using: .utf8),
              let baseline = try? JSONDecoder().decode(
                  RemoteSyncReadingPlanAcceptedBaseline.self,
                  from: data
              ), baseline.revision >= 0 else {
            throw RemoteSyncReadingPlanSnapshotError.invalidAcceptedBaseline
        }
        return baseline
    }

    /**
     Reads the durable accepted-row manifest used for deletion detection.

     - Parameter settingsStore: Local-only settings store containing the manifest.
     - Returns: Accepted identities keyed by Android composite key, or `nil` when no manifest has
       ever been published for this category.
     - Side effects: Reads one local setting row.
     - Throws: `RemoteSyncReadingPlanSnapshotError.invalidAcceptedBaseline` when stored JSON is
       malformed; callers must fail closed rather than silently forgetting accepted rows.
     */
    func acceptedRowsByKey(
        settingsStore: SettingsStore
    ) throws -> [String: RemoteSyncReadingPlanAcceptedRowIdentity]? {
        try storedAcceptedBaseline(settingsStore: settingsStore)?.generation.rowsByKey
    }

    /**
     Atomically stages fingerprints and accepted identities from one immutable generation.

     Callers place this method inside `SettingsStore.performAtomicBatch`. The method clears every
     prior category fingerprint before writing the supplied generation so deleted rows cannot leave
     stale hashes, then writes the accepted-row manifest from the exact same generation.

     - Parameters:
       - generation: Immutable fingerprints and row identities that were restored, replayed, or uploaded.
       - settingsStore: Local-only settings store receiving the accepted baseline.
     - Side effects: Replaces all reading-plan fingerprint settings and the accepted-row manifest.
     - Throws:
       - `RemoteSyncReadingPlanSnapshotError.incompleteAcceptedGeneration` when a fingerprint lacks
         a matching identity
       - rethrows JSON encoding failures
       - settings persistence failures invalidate the enclosing atomic batch
     */
    @discardableResult
    func acceptBaselineFingerprints(
        _ generation: RemoteSyncReadingPlanAcceptedGeneration,
        settingsStore: SettingsStore,
        expectedRevision: Int64? = nil
    ) throws -> Int64 {
        let currentBaseline = try storedAcceptedBaseline(settingsStore: settingsStore)
        let currentRevision = currentBaseline?.revision ?? 0
        if let expectedRevision, expectedRevision != currentRevision {
            throw RemoteSyncReadingPlanSnapshotError.staleAcceptedBaseline(
                expected: expectedRevision,
                actual: currentRevision
            )
        }

        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fingerprintPrefix = fingerprintStore.prefix(for: .readingPlans)
        let logPrefix = logEntryStore.prefix(for: .readingPlans)
        for entry in settingsStore.entries(withPrefix: fingerprintPrefix) {
            let suffix = String(entry.key.dropFirst(fingerprintPrefix.count))
            let logKey = "\(logPrefix)\(suffix)"
            if !generation.suppressedKeys.contains(logKey) {
                settingsStore.remove(entry.key)
            }
        }
        for (key, fingerprint) in generation.fingerprintsByKey.sorted(by: { $0.key < $1.key }) {
            guard let row = generation.rowsByKey[key] else {
                throw RemoteSyncReadingPlanSnapshotError.incompleteAcceptedGeneration(key)
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .readingPlans,
                tableName: row.tableName,
                entityID1: row.entityID1,
                entityID2: row.entityID2
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let nextRevision = currentRevision + 1
        let manifestData = try encoder.encode(
            RemoteSyncReadingPlanAcceptedBaseline(
                revision: nextRevision,
                generation: generation
            )
        )
        settingsStore.setString(
            Self.acceptedBaselineKey,
            value: String(decoding: manifestData, as: UTF8.self)
        )
        return nextRevision
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one Android `ReadingPlan` row.

     The fingerprint uses a canonical pipe-delimited text form instead of generic JSON encoding so
     repeated refresh and upload passes do not depend on synthesized `Codable` implementation
     details.

     - Parameter value: Android-shaped current `ReadingPlan` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncCurrentReadingPlanRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.id.uuidString.lowercased(),
                value.planCode,
                String(value.planStartDateMillis),
                String(value.planCurrentDay),
            ].joined(separator: "|")
        )
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one Android `ReadingPlanStatus` row.

     - Parameter value: Android-shaped current `ReadingPlanStatus` row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the canonical row payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func fingerprintHex(for value: RemoteSyncCurrentReadingPlanStatusRow) -> String {
        fingerprintHex(
            canonicalValue: [
                value.id.uuidString.lowercased(),
                value.planCode,
                String(value.planDay),
                value.readingStatusJSON,
            ].joined(separator: "|")
        )
    }

    /**
     Finds persisted custom plans that Android cannot reconstruct from its Room rows alone.

     - Parameter snapshot: Strict current reading-plan projection.
     - Returns: Sorted nonbundled plan codes that Android's database-only sync cannot reconstruct.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    func unsupportedCustomPlanCodes(
        in snapshot: RemoteSyncReadingPlanCurrentSnapshot
    ) -> [String] {
        Set(snapshot.planRowsByKey.values.map(\.planCode))
            .filter { !ReadingPlanService.isBundledPlanCode($0) }
            .sorted()
    }

    /**
     Computes the stable hexadecimal SHA-256 fingerprint for one canonical row string.

     - Parameter canonicalValue: Canonical text representation of one Android row.
     - Returns: Lowercase hexadecimal SHA-256 digest of the supplied string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func fingerprintHex(canonicalValue: String) -> String {
        let digest = SHA256.hash(data: Data(canonicalValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /**
     Converts one UUID into Android's raw 16-byte blob representation.

     - Parameter uuid: UUID to serialize.
     - Returns: Raw 16-byte UUID payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func uuidBlob(_ uuid: UUID) -> Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    /**
     Builds the local status-store lookup key for one `(planCode, dayNumber)` pair.

     - Parameters:
       - planCode: Reading-plan code.
       - dayNumber: One-based day number.
     - Returns: Deterministic lookup key used only within this snapshot service.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func statusKey(planCode: String, dayNumber: Int) -> String {
        "\(planCode)|\(dayNumber)"
    }

    /**
     Builds one current Android status row from preserved or synthesized local state.

     - Parameters:
       - plan: Parent reading plan that owns the day row.
       - day: Local reading-plan day under evaluation.
       - storedStatus: Preserved Android status payload for the same `(planCode, dayNumber)` pair when available.
     - Returns: Android-shaped status row, or `nil` when the local day is incomplete and has no preserved Android payload.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func makeStatusRow(
        plan: ReadingPlan,
        day: ReadingPlanDay,
        storedStatus: RemoteSyncReadingPlanStatusStore.Status?
    ) -> RemoteSyncCurrentReadingPlanStatusRow? {
        if let storedStatus {
            return RemoteSyncCurrentReadingPlanStatusRow(
                id: storedStatus.remoteStatusID ?? Self.syntheticStatusID(planID: plan.id, dayNumber: day.dayNumber),
                planCode: plan.planCode,
                planDay: day.dayNumber,
                readingStatusJSON: storedStatus.readingStatusJSON
            )
        }

        guard day.isCompleted else {
            return nil
        }
        guard !Self.isImplicitHistoricStatus(plan: plan, day: day) else {
            return nil
        }

        let assignment = ReadingPlanDayAssignment(rawValue: day.readings)
        let payload = AndroidReadingPlanStatusPayload.settingAll(
            readingCount: assignment.readings.count,
            isRead: true
        )
        guard let readingStatusJSON = try? payload.androidJSON() else {
            return nil
        }

        return RemoteSyncCurrentReadingPlanStatusRow(
            id: Self.syntheticStatusID(planID: plan.id, dayNumber: day.dayNumber),
            planCode: plan.planCode,
            planDay: day.dayNumber,
            readingStatusJSON: readingStatusJSON
        )
    }

    /**
     Generates a deterministic synthetic Android status identifier for one local plan day.

     - Parameters:
       - planID: Parent local plan identifier.
       - dayNumber: One-based day number within the plan.
     - Returns: Deterministic UUID derived from the plan id and day number.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func syntheticStatusID(planID: UUID, dayNumber: Int) -> UUID {
        let seed = "reading-plan-status|\(planID.uuidString.lowercased())|\(dayNumber)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /**
     Checks whether one completed local day is Android-historic progress represented by `currentDay`.

     - Parameters:
       - plan: Parent reading plan containing Android's persisted current-day pointer.
       - day: Local day row being considered for synthesized status upload.
     - Returns: `true` when Android would derive the day as read without a status row.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func isImplicitHistoricStatus(plan: ReadingPlan, day: ReadingPlanDay) -> Bool {
        !ReadingPlanDayAssignment(rawValue: day.readings).isDateBased
            && day.dayNumber < plan.currentDay
    }
}
