// RemoteSyncReadingPlanTimestampStore.swift -- Exact Android reading-plan timestamp fidelity

import Foundation

/** Fail-visible corruption errors for exact reading-plan timestamp sidecars. */
enum RemoteSyncReadingPlanTimestampStoreError: Error, Equatable {
    /// A namespaced row has an invalid UUID key or signed-Int64 decimal value.
    case malformedTimestamp(String)
}

/** Preserves Android's exact `Long` start-date value beside the Date-backed SwiftData model. */
final class RemoteSyncReadingPlanTimestampStore {
    private static let prefix = "remote_sync.readingplans.start_date_millis"
    private let settingsStore: SettingsStore

    /** Creates a sidecar over the same settings transaction used by reading-plan persistence. */
    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
     Reads and validates the complete timestamp namespace.

     - Returns: Exact milliseconds keyed by local/Android plan UUID.
     - Side Effects: Reads namespaced settings rows.
     - Throws: `malformedTimestamp` when any present row cannot round-trip exactly.
     */
    func allMilliseconds() throws -> [UUID: Int64] {
        var result: [UUID: Int64] = [:]
        let prefix = "\(Self.prefix)."
        for entry in settingsStore.entries(withPrefix: prefix).sorted(by: { $0.key < $1.key }) {
            let suffix = String(entry.key.dropFirst(prefix.count))
            guard let id = UUID(uuidString: suffix),
                  id.uuidString.lowercased() == suffix.lowercased(),
                  let milliseconds = Int64(entry.value),
                  String(milliseconds) == entry.value,
                  result[id] == nil else {
                throw RemoteSyncReadingPlanTimestampStoreError.malformedTimestamp(entry.key)
            }
            result[id] = milliseconds
        }
        return result
    }

    /** Stages one exact signed-Int64 timestamp in the caller's settings transaction. */
    func setMilliseconds(_ milliseconds: Int64, for planID: UUID) {
        settingsStore.setString(key(for: planID), value: String(milliseconds))
    }

    /** Stages removal of one plan's exact timestamp sidecar. */
    func removeMilliseconds(for planID: UUID) {
        settingsStore.remove(key(for: planID))
    }

    /** Removes every exact timestamp sidecar in the caller's settings transaction. */
    func clearAll() {
        for entry in settingsStore.entries(withPrefix: Self.prefix) {
            settingsStore.remove(entry.key)
        }
    }

    /** Returns the deterministic settings key for one plan UUID. */
    private func key(for planID: UUID) -> String {
        "\(Self.prefix).\(planID.uuidString.lowercased())"
    }
}
