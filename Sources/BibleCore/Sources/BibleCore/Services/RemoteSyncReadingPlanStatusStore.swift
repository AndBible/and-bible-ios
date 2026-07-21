// RemoteSyncReadingPlanStatusStore.swift — Local preservation of Android reading-plan progress payloads

import Foundation
import SwiftData

/** Fail-visible corruption errors for locally preserved Android reading-plan status rows. */
public enum RemoteSyncReadingPlanStatusPersistenceError: Error, Equatable, Sendable {
    /// A present settings row has an invalid key, envelope, or Android status payload.
    case malformedStoredStatus(String)

    /// The decoded envelope identity does not match the composite settings key.
    case storedStatusIdentityMismatch(String)
}

/**
 Preserves Android reading-plan per-reading progress payloads in iOS's local-only settings store.

 Android sync stores granular JSON status for each `(planCode, planDay)` pair, while the current
 iOS reading-plan model only persists day-level completion. This store keeps the original Android
 payloads locally so initial-backup restore can avoid throwing away data that iOS does not yet
 render natively.

 Data dependencies:
 - `SettingsStore` provides local-only key-value persistence in the `LocalStore`

 Side effects:
 - writes and removes namespaced `Setting` rows in the local SwiftData settings table

 Failure modes:
 - ordinary writes inherit `SettingsStore`'s soft-failure behavior
 - restore callers can opt into the internal atomic batch bridge, which surfaces persistence errors
   and joins these rows to the same SwiftData commit as the restored object graph

 Concurrency:
 - this type inherits the confinement requirements of the supplied `SettingsStore`
 */
public final class RemoteSyncReadingPlanStatusStore {
    private let settingsStore: SettingsStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let prefix = "remote_sync.readingplans.android_status"
    }

    /**
     One preserved Android reading-plan status payload.

     - Important: `readingStatusJSON` is stored verbatim so future sync work can rehydrate the
       original Android semantics without lossy translation.
     */
    public struct Status: Sendable, Equatable, Codable {
        /// Android reading-plan code that owns the status row.
        public let planCode: String

        /// One-based day number within the Android plan definition.
        public let dayNumber: Int

        /// Raw Android JSON payload from `ReadingPlanStatus.readingStatus`.
        public let readingStatusJSON: String

        /// Android `ReadingPlanStatus.id` value when preserved during restore or patch replay.
        public let remoteStatusID: UUID?

        /**
         Creates a preserved Android reading-plan status payload.

         - Parameters:
           - planCode: Android reading-plan code that owns the status row.
           - dayNumber: One-based day number within the plan definition.
           - readingStatusJSON: Raw Android JSON payload from `ReadingPlanStatus.readingStatus`.
           - remoteStatusID: Android `ReadingPlanStatus.id` value when available from restore or patch replay.
         - Side effects: none.
         - Failure modes: This initializer cannot fail.
         */
        public init(
            planCode: String,
            dayNumber: Int,
            readingStatusJSON: String,
            remoteStatusID: UUID? = nil
        ) {
            self.planCode = planCode
            self.dayNumber = dayNumber
            self.readingStatusJSON = readingStatusJSON
            self.remoteStatusID = remoteStatusID
        }
    }

    /**
     Creates a local-only store for preserved Android reading-plan status payloads.

     - Parameter settingsStore: Local settings store used for persistence.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
     Exposes the exact settings transaction boundary to the definition publication coordinator.

     - Returns: The same `SettingsStore` supplied at initialization.
     - Side effects: none.
     - Failure modes: This accessor cannot fail.
     - Important: Internal restore code uses this only to bind filesystem generation recovery to the
       same graph/status commit; it does not broaden the public status-store API.
     */
    var definitionPublicationSettingsStore: SettingsStore {
        settingsStore
    }

    /**
     Executes a graph-and-status replacement through the underlying settings store's atomic boundary.

     The supplied context must be the exact clean context owned by the underlying `SettingsStore`.
     This bridge exists so reading-plan restore can include plan/day models and preserved status
     `Setting` rows in one primary save, with durable compensation across separate configurations,
     without exposing the settings store itself.

     - Parameters:
       - modelContext: Exact clean context shared by the graph and underlying settings store.
       - durableRecovery: Optional graph recovery registered with the outer settings batch.
       - mutations: Graph and status mutations that must commit or roll back together.
     - Returns: Value returned by `mutations` after the primary final save succeeds.
     - Side Effects: Delegates save deferral, one primary save, rollback, and durable recovery to
       `SettingsStore.performAtomicBatch(in:_:)`.
     - Throws: Rethrows context-contract, cancellation, mutation, fetch, and save errors from the
       underlying atomic batch.
     */
    func performAtomicBatch<Result>(
        in modelContext: ModelContext,
        durableRecovery: ((ModelContainer) throws -> Void)? = nil,
        _ mutations: () throws -> Result
    ) throws -> Result {
        try settingsStore.performAtomicBatch(
            in: modelContext,
            durableRecovery: durableRecovery,
            mutations
        )
    }

    /**
     Stores or replaces one raw Android reading-plan status payload.

     - Parameters:
       - readingStatusJSON: Raw JSON payload to preserve.
       - planCode: Android reading-plan code that owns the payload.
       - dayNumber: One-based day number within the plan definition.
     - Side effects:
       - writes one namespaced local `Setting` row
     - Failure modes:
       - persistence failures are swallowed outside an explicit atomic batch and invalidate the
         outer batch when one is active
     */
    public func setStatus(_ readingStatusJSON: String, planCode: String, dayNumber: Int) {
        setStatus(
            readingStatusJSON,
            planCode: planCode,
            dayNumber: dayNumber,
            remoteStatusID: nil
        )
    }

    /**
     Stores or replaces one raw Android reading-plan status payload together with its remote row id.

     - Parameters:
       - readingStatusJSON: Raw JSON payload to preserve.
       - planCode: Android reading-plan code that owns the payload.
       - dayNumber: One-based day number within the plan definition.
       - remoteStatusID: Android `ReadingPlanStatus.id` value associated with the payload.
     - Side effects:
       - writes one namespaced local `Setting` row
     - Failure modes:
       - JSON-encoding failures skip the ordinary write silently
       - persistence failures are swallowed outside an explicit atomic batch and invalidate the
         outer batch when one is active
     */
    public func setStatus(
        _ readingStatusJSON: String,
        planCode: String,
        dayNumber: Int,
        remoteStatusID: UUID?
    ) {
        let status = Status(
            planCode: planCode,
            dayNumber: dayNumber,
            readingStatusJSON: readingStatusJSON,
            remoteStatusID: remoteStatusID
        )
        try? setStatusThrowing(status)
    }

    /**
     Encodes and stages one status while allowing an atomic restore to observe encoding failures.

     - Parameter status: Fully typed Android status envelope to encode and persist.
     - Side Effects: Upserts one namespaced `Setting`; its save is deferred when called inside
       `performAtomicBatch(in:_:)` and remains immediate otherwise.
     - Throws: Rethrows `JSONEncoder` failures. Settings fetch/save failures are captured and surfaced
       by the enclosing settings batch.
     */
    func setStatusThrowing(_ status: Status) throws {
        guard Int32(exactly: status.dayNumber) != nil,
              (try? AndroidReadingPlanStatusPayload(
                androidJSON: status.readingStatusJSON
              )) != nil else {
            throw RemoteSyncReadingPlanStatusPersistenceError.malformedStoredStatus(
                scopedKey(planCode: status.planCode, dayNumber: status.dayNumber)
            )
        }
        let data = try encoder.encode(status)
        let payload = String(decoding: data, as: UTF8.self)
        settingsStore.setString(
            scopedKey(planCode: status.planCode, dayNumber: status.dayNumber),
            value: payload
        )
    }

    /**
     Reads one preserved Android reading-plan status payload.

     - Parameters:
       - planCode: Android reading-plan code that owns the payload.
       - dayNumber: One-based day number within the plan definition.
     - Returns: The preserved raw JSON payload, or `nil` when no value has been stored.
     - Side effects: none.
     - Failure modes:
       - malformed or missing stored keys return `nil`
     */
    public func status(planCode: String, dayNumber: Int) -> String? {
        storedStatus(planCode: planCode, dayNumber: dayNumber)?.readingStatusJSON
    }

    /**
     Reads one preserved Android reading-plan status payload together with its remote row id.

     - Parameters:
       - planCode: Android reading-plan code that owns the payload.
       - dayNumber: One-based day number within the plan definition.
     - Returns: Decoded preserved status payload, or `nil` when no usable value has been stored.
     - Side effects: none.
     - Failure modes:
       - malformed or missing stored keys return `nil`
       - legacy pre-envelope payloads are decoded with `remoteStatusID == nil`
     */
    public func storedStatus(planCode: String, dayNumber: Int) -> Status? {
        try? storedStatusStrict(planCode: planCode, dayNumber: dayNumber)
    }

    /**
     Reads one stored status without interpreting malformed persistence as absence.

     - Parameters:
       - planCode: Exact Android plan code.
       - dayNumber: Signed-Int32 Android plan day.
     - Returns: Preserved status, or `nil` only when the exact key is absent.
     - Side Effects: Reads one settings row.
     - Throws: `RemoteSyncReadingPlanStatusPersistenceError` for malformed keys, envelopes, identity
       mismatches, or malformed Android `readingStatus` JSON.
     */
    func storedStatusStrict(planCode: String, dayNumber: Int) throws -> Status? {
        let key = scopedKey(planCode: planCode, dayNumber: dayNumber)
        guard let entry = settingsStore.entries(withPrefix: key).first(where: { $0.key == key }) else {
            return nil
        }
        return try decodeEntryStrict(entry)
    }

    /**
     Reads one preserved Android reading-plan status payload by Android row id.

     - Parameter remoteStatusID: Android `ReadingPlanStatus.id` value to locate.
     - Returns: Decoded preserved status payload, or `nil` when no stored payload carries that id.
     - Side effects:
       - enumerates local `Setting` rows managed by this store
     - Failure modes:
       - malformed stored keys or payloads are skipped during the lookup
       - legacy pre-envelope payloads are ignored because they do not carry a remote row id
     */
    public func status(remoteStatusID: UUID) -> Status? {
        allStatuses().first { $0.remoteStatusID == remoteStatusID }
    }

    /**
     Removes one preserved Android reading-plan status payload.

     - Parameters:
       - planCode: Android reading-plan code that owns the payload.
       - dayNumber: One-based day number within the plan definition.
     - Side effects:
       - deletes one namespaced local `Setting` row when present
     - Failure modes:
       - persistence failures are swallowed outside an explicit atomic batch and invalidate the
         outer batch when one is active
     */
    public func removeStatus(planCode: String, dayNumber: Int) {
        removeStatusThrowing(planCode: planCode, dayNumber: dayNumber)
    }

    /** Stages one status deletion for an enclosing fail-visible transaction. */
    func removeStatusThrowing(planCode: String, dayNumber: Int) {
        settingsStore.remove(scopedKey(planCode: planCode, dayNumber: dayNumber))
    }

    /**
     Returns every preserved Android reading-plan status payload.

     - Returns: Decoded status payloads sorted by plan code and day number.
     - Side effects: none.
     - Failure modes:
       - malformed keys are skipped rather than throwing
     */
    public func allStatuses() -> [Status] {
        (try? allStatusesStrict()) ?? []
    }

    /**
     Reads the complete status namespace without dropping malformed rows.

     - Returns: Every decoded status sorted by plan code, day, and remote identity.
     - Side Effects: Reads namespaced settings rows.
     - Throws: The first corruption error in deterministic key order.
     */
    func allStatusesStrict() throws -> [Status] {
        try settingsStore.entries(withPrefix: Keys.prefix)
            .sorted { $0.key < $1.key }
            .map(decodeEntryStrict)
            .sorted {
            if $0.planCode == $1.planCode {
                if $0.dayNumber == $1.dayNumber {
                    return ($0.remoteStatusID?.uuidString ?? "")
                        < ($1.remoteStatusID?.uuidString ?? "")
                }
                return $0.dayNumber < $1.dayNumber
            }
            return $0.planCode < $1.planCode
        }
    }

    /**
     Removes all preserved Android reading-plan status payloads.

     - Side effects:
       - deletes every namespaced local `Setting` row managed by this store
     - Failure modes:
       - persistence failures are swallowed outside an explicit atomic batch and invalidate the
         outer batch when one is active
     */
    public func clearAll() {
        for entry in settingsStore.entries(withPrefix: Keys.prefix) {
            settingsStore.remove(entry.key)
        }
    }

    private func scopedKey(planCode: String, dayNumber: Int) -> String {
        "\(Keys.prefix).\(encodeKeySegment(planCode)).\(dayNumber)"
    }

    private func decodeEntry(_ entry: Setting) -> Status? {
        try? decodeEntryStrict(entry)
    }

    /** Decodes and validates one key-bound envelope or valid legacy raw Android payload. */
    private func decodeEntryStrict(_ entry: Setting) throws -> Status {
        let prefix = "\(Keys.prefix)."
        guard entry.key.hasPrefix(prefix) else {
            throw RemoteSyncReadingPlanStatusPersistenceError.malformedStoredStatus(entry.key)
        }

        let suffix = String(entry.key.dropFirst(prefix.count))
        guard let separator = suffix.lastIndex(of: ".") else {
            throw RemoteSyncReadingPlanStatusPersistenceError.malformedStoredStatus(entry.key)
        }

        let encodedPlanCode = String(suffix[..<separator])
        let dayString = String(suffix[suffix.index(after: separator)...])
        guard let dayNumber = Int32(dayString).map(Int.init) else {
            throw RemoteSyncReadingPlanStatusPersistenceError.malformedStoredStatus(entry.key)
        }

        guard let planCode = decodeKeySegment(encodedPlanCode), !entry.value.isEmpty else {
            throw RemoteSyncReadingPlanStatusPersistenceError.malformedStoredStatus(entry.key)
        }

        if let data = entry.value.data(using: .utf8),
           let status = try? decoder.decode(Status.self, from: data) {
            guard status.planCode == planCode, status.dayNumber == dayNumber else {
                throw RemoteSyncReadingPlanStatusPersistenceError.storedStatusIdentityMismatch(
                    entry.key
                )
            }
            guard (try? AndroidReadingPlanStatusPayload(
                androidJSON: status.readingStatusJSON
            )) != nil else {
                throw RemoteSyncReadingPlanStatusPersistenceError.malformedStoredStatus(entry.key)
            }
            return status
        }

        guard (try? AndroidReadingPlanStatusPayload(androidJSON: entry.value)) != nil else {
            throw RemoteSyncReadingPlanStatusPersistenceError.malformedStoredStatus(entry.key)
        }
        return Status(planCode: planCode, dayNumber: dayNumber, readingStatusJSON: entry.value)
    }

    /**
     Encodes one plan-code segment for safe embedding in `Setting.key`.

     Plan codes can contain punctuation that would interfere with the store's dotted composite-key
     format. This helper uses URL-safe Base64 without padding so later decoding can recover the exact
     original plan code.

     - Parameter rawValue: Raw Android/iOS reading-plan code to embed in a settings key.
     - Returns: URL-safe Base64 segment with `+`, `/`, and `=` removed or substituted.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func encodeKeySegment(_ rawValue: String) -> String {
        let data = Data(rawValue.utf8)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /**
     Decodes one URL-safe Base64 settings-key segment back into a plan code.

     - Parameter encodedValue: URL-safe Base64 segment previously produced by `encodeKeySegment(_:)`.
     - Returns: Original plan code string, or `nil` when the encoded payload is not valid Base64 or
       not valid UTF-8.
     - Side effects: none.
     - Failure modes:
       - returns `nil` instead of throwing when the stored segment is malformed or undecodable
     */
    private func decodeKeySegment(_ encodedValue: String) -> String? {
        var base64 = encodedValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
