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

    /// Stable content fingerprints for every row in the snapshot keyed by Android composite key.
    public let fingerprintsByKey: [String: String]

    /**
     Creates one current-state reading-plan snapshot.

     - Parameters:
       - planRowsByKey: Android-shaped current `ReadingPlan` rows keyed by local settings/log-entry key.
       - statusRowsByKey: Android-shaped current `ReadingPlanStatus` rows keyed by local settings/log-entry key.
       - fingerprintsByKey: Stable content fingerprints for every row in the snapshot keyed by Android composite key.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        planRowsByKey: [String: RemoteSyncCurrentReadingPlanRow],
        statusRowsByKey: [String: RemoteSyncCurrentReadingPlanStatusRow],
        fingerprintsByKey: [String: String]
    ) {
        self.planRowsByKey = planRowsByKey
        self.statusRowsByKey = statusRowsByKey
        self.fingerprintsByKey = fingerprintsByKey
    }
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
 - synthesized status identifiers are deterministic so later uploads keep stable row keys even
   before Android-origin status metadata exists

 Data dependencies:
 - `ModelContext` provides live `ReadingPlan` and `ReadingPlanDay` rows
 - `RemoteSyncReadingPlanStatusStore` provides preserved Android status payloads and optional remote ids
 - `RemoteSyncLogEntryStore` provides canonical Android composite-key encoding
 - `RemoteSyncRowFingerprintStore` persists baseline fingerprints after restore/replay or upload

 Side effects:
 - `snapshotCurrentState` reads local SwiftData and settings rows
 - `refreshBaselineFingerprints` rewrites local fingerprint rows for the reading-plan category

 Failure modes:
 - fetch failures from `ModelContext` are swallowed and treated as an empty local plan set to stay
   aligned with the repo's existing store behavior

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement rules of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncReadingPlanSnapshotService {
    private struct SynthesizedReadingStatusPayload: Codable {
        let chapterReadArray: [SynthesizedChapterRead]
    }

    private struct SynthesizedChapterRead: Codable {
        let readingNumber: Int
        let isRead: Bool
    }

    /**
     Creates a reading-plan snapshot service.

     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init() {}

    /**
     Projects the current local reading-plan state into Android-shaped rows and row fingerprints.

     - Parameters:
       - modelContext: SwiftData context that owns the current reading-plan graph.
       - settingsStore: Local-only settings store that holds preserved Android status payloads.
     - Returns: Android-shaped current rows and their stable fingerprints keyed by Android composite key.
     - Side effects:
       - reads current `ReadingPlan` rows from SwiftData
       - reads preserved Android `ReadingPlanStatus` payloads from `SettingsStore`
     - Failure modes:
       - fetch failures from `ModelContext` are swallowed and treated as an empty snapshot
     */
    public func snapshotCurrentState(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) -> RemoteSyncReadingPlanCurrentSnapshot {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
        let localPlans = ((try? modelContext.fetch(FetchDescriptor<ReadingPlan>())) ?? [])
            .sorted { lhs, rhs in
                if lhs.planCode == rhs.planCode {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.planCode < rhs.planCode
            }

        let storedStatuses = Dictionary(
            uniqueKeysWithValues: statusStore.allStatuses().map {
                (Self.statusKey(planCode: $0.planCode, dayNumber: $0.dayNumber), $0)
            }
        )

        var planRowsByKey: [String: RemoteSyncCurrentReadingPlanRow] = [:]
        var statusRowsByKey: [String: RemoteSyncCurrentReadingPlanStatusRow] = [:]
        var fingerprintsByKey: [String: String] = [:]

        for plan in localPlans {
            let planRow = RemoteSyncCurrentReadingPlanRow(
                id: plan.id,
                planCode: plan.planCode,
                planStartDateMillis: Int64(plan.startDate.timeIntervalSince1970 * 1000.0),
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
       - fetch failures while reading the current plan graph are swallowed and treated as an empty snapshot
     */
    public func refreshBaselineFingerprints(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) {
        let snapshot = snapshotCurrentState(modelContext: modelContext, settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)

        for entry in logEntryStore.entries(for: .readingPlans) {
            let key = logEntryStore.key(for: .readingPlans, entry: entry)
            if !snapshot.fingerprintsByKey.keys.contains(key) {
                fingerprintStore.removeFingerprint(
                    for: .readingPlans,
                    tableName: entry.tableName,
                    entityID1: entry.entityID1,
                    entityID2: entry.entityID2
                )
            }
        }

        for (key, row) in snapshot.planRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .readingPlans,
                tableName: "ReadingPlan",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
        }

        for (key, row) in snapshot.statusRowsByKey {
            guard let fingerprint = snapshot.fingerprintsByKey[key] else {
                continue
            }
            fingerprintStore.setFingerprint(
                fingerprint,
                for: .readingPlans,
                tableName: "ReadingPlanStatus",
                entityID1: .blob(Self.uuidBlob(row.id)),
                entityID2: .text("")
            )
        }
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

        let readingCount = Self.expectedReadingCount(for: day.readings)
        let payload = SynthesizedReadingStatusPayload(
            chapterReadArray: (1...readingCount).map {
                SynthesizedChapterRead(readingNumber: $0, isRead: true)
            }
        )
        let encoder = JSONEncoder()
        let readingStatusJSON = String(
            data: (try? encoder.encode(payload)) ?? Data("{}".utf8),
            encoding: .utf8
        ) ?? "{}"

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
    private static func syntheticStatusID(planID: UUID, dayNumber: Int) -> UUID {
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
     Counts how many logical readings are present in one local plan-day assignment string.

     Android date-based plans prefix the actual comma-delimited reading list with a leading
     `Mon-1;`-style token. That token is not itself a reading and must be removed before counting.

     - Parameter readings: Local reading-assignment string for one plan day.
     - Returns: Number of logical readings represented by the assignment string.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func expectedReadingCount(for readings: String) -> Int {
        let regex = try! NSRegularExpression(pattern: #"^[A-Za-z]{3}-\d{1,2};"#)
        let range = NSRange(readings.startIndex..<readings.endIndex, in: readings)

        let readingsPortion: String
        if regex.firstMatch(in: readings, options: [], range: range) != nil,
           let separatorIndex = readings.firstIndex(of: ";") {
            readingsPortion = String(readings[readings.index(after: separatorIndex)...])
        } else {
            readingsPortion = readings
        }

        return readingsPortion
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }
}
