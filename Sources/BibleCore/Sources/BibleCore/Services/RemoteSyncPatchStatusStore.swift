// RemoteSyncPatchStatusStore.swift — Applied remote patch bookkeeping

import Foundation

/**
 Android-aligned record of one applied remote patch file.

 Android persists these rows in `SyncStatus` so it can detect already applied patches, compute the
 highest applied patch number per source device, and estimate remote-sync storage usage. iOS stores
 the same payload locally so later WebDAV patch download/application logic can preserve Android's
 ordering semantics.
 */
public struct RemoteSyncPatchStatus: Sendable, Equatable, Codable {
    /// Source device folder name that produced the patch.
    public let sourceDevice: String

    /// Monotonic patch number within the source device folder.
    public let patchNumber: Int64

    /// Patch archive size in bytes.
    public let sizeBytes: Int64

    /// Millisecond timestamp when the patch was applied locally.
    public let appliedDate: Int64

    /**
     Creates one applied-patch status payload.

     - Parameters:
       - sourceDevice: Source device folder name that produced the patch.
       - patchNumber: Monotonic patch number within the source device folder.
       - sizeBytes: Patch archive size in bytes.
       - appliedDate: Millisecond timestamp when the patch was applied locally.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(sourceDevice: String, patchNumber: Int64, sizeBytes: Int64, appliedDate: Int64) {
        self.sourceDevice = sourceDevice
        self.patchNumber = patchNumber
        self.sizeBytes = sizeBytes
        self.appliedDate = appliedDate
    }
}

/**
 Persists applied remote patch statuses in the local settings table.

 Android uses a dedicated `SyncStatus` table keyed by `(sourceDevice, patchNumber)`. iOS does not
 have that schema yet, so this store namespaces JSON-encoded status records inside the existing
 local-only `Setting` table. The behavior remains category-aware and preserves the same lookup
 capabilities needed by the patch discovery layer.

 Data dependencies:
 - `SettingsStore` provides durable local-only persistence and prefix-based key enumeration

 Side effects:
 - writes and deletes local `Setting` rows in the `LocalStore`

 Failure modes:
 - malformed stored JSON values are ignored during reads
 - underlying `SettingsStore` writes swallow save errors, so callers should treat persistence as
   best-effort bookkeeping rather than a hard guarantee
 */
public final class RemoteSyncPatchStatusStore {
    private let settingsStore: SettingsStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let prefix = "remote_sync_status"
    }

    /**
     Creates a patch-status store bound to a local settings store.

     - Parameter settingsStore: Local-only settings store used for persistence.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
     Persists one applied patch status for the supplied category.

     - Parameters:
       - status: Applied patch status to store.
       - category: Logical sync category the patch belongs to.
     - Side effects:
       - encodes the status as JSON and writes it into `SettingsStore`
     - Failure modes:
       - encoding failures skip the write silently
       - underlying `SettingsStore` save failures are swallowed
     */
    public func addStatus(_ status: RemoteSyncPatchStatus, for category: RemoteSyncCategory) {
        guard let data = try? encoder.encode(status),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }
        settingsStore.setString(key(for: category, sourceDevice: status.sourceDevice, patchNumber: status.patchNumber), value: payload)
    }

    /**
     Persists multiple applied patch statuses for the supplied category.

     - Parameters:
       - statuses: Applied patch statuses to store.
       - category: Logical sync category the statuses belong to.
     - Side effects:
       - writes one JSON-encoded `Setting` row per status
     - Failure modes:
       - malformed or unsavable individual records are skipped while the rest continue
     */
    public func addStatuses(_ statuses: [RemoteSyncPatchStatus], for category: RemoteSyncCategory) {
        for status in statuses {
            addStatus(status, for: category)
        }
    }

    /**
     Reads one applied patch status when it exists.

     - Parameters:
       - category: Logical sync category to inspect.
       - sourceDevice: Source device folder name that produced the patch.
       - patchNumber: Patch number to look up.
     - Returns: Stored status when present and decodable; otherwise `nil`.
     - Side effects: reads local `Setting` rows.
     - Failure modes:
       - missing rows return `nil`
       - malformed JSON payloads return `nil`
     */
    public func status(
        for category: RemoteSyncCategory,
        sourceDevice: String,
        patchNumber: Int64
    ) -> RemoteSyncPatchStatus? {
        guard let payload = settingsStore.getString(key(for: category, sourceDevice: sourceDevice, patchNumber: patchNumber)),
              let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(RemoteSyncPatchStatus.self, from: data)
    }

    /**
     Returns the highest applied patch number for one source device and category.

     - Parameters:
       - category: Logical sync category to inspect.
       - sourceDevice: Source device folder name whose applied patches should be scanned.
     - Returns: Highest applied patch number, or `nil` when no statuses exist.
     - Side effects: reads local `Setting` rows via prefix enumeration.
     - Failure modes: Malformed stored JSON values are ignored.
     */
    public func lastPatchNumber(
        for category: RemoteSyncCategory,
        sourceDevice: String
    ) -> Int64? {
        statuses(for: category)
            .filter { $0.sourceDevice == sourceDevice }
            .map(\.patchNumber)
            .max()
    }

    /**
     Reads all applied patch statuses for one category.

     - Parameter category: Logical sync category to inspect.
     - Returns: Decodable patch statuses for the category.
     - Side effects: reads local `Setting` rows via prefix enumeration.
     - Failure modes: Malformed stored JSON values are ignored.
     */
    public func statuses(for category: RemoteSyncCategory) -> [RemoteSyncPatchStatus] {
        settingsStore.entries(withPrefix: prefix(for: category))
            .compactMap { entry in
                guard let data = entry.value.data(using: .utf8) else {
                    return nil
                }
                return try? decoder.decode(RemoteSyncPatchStatus.self, from: data)
            }
    }

    /**
     Computes the total bytes represented by applied patch statuses in one category.

     - Parameter category: Logical sync category to inspect.
     - Returns: Sum of all stored `sizeBytes` values for the category.
     - Side effects: reads local `Setting` rows via prefix enumeration.
     - Failure modes: Malformed stored JSON values are ignored.
     */
    public func totalBytesUsed(for category: RemoteSyncCategory) -> Int64 {
        statuses(for: category).reduce(0) { $0 + $1.sizeBytes }
    }

    /**
     Clears all applied patch statuses for one category.

     - Parameter category: Logical sync category whose applied patch statuses should be removed.
     - Side effects:
       - deletes all matching status rows from `SettingsStore`
     - Failure modes:
       - underlying `SettingsStore` delete failures are swallowed
     */
    public func clearCategory(_ category: RemoteSyncCategory) {
        for entry in settingsStore.entries(withPrefix: prefix(for: category)) {
            settingsStore.remove(entry.key)
        }
    }

    /**
     Builds the fully scoped settings key for one applied patch record.

     - Parameters:
       - category: Logical sync category that owns the patch.
       - sourceDevice: Source device folder name that produced the patch.
       - patchNumber: Monotonic patch number within the source device folder.
     - Returns: Fully scoped local settings key.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public func key(
        for category: RemoteSyncCategory,
        sourceDevice: String,
        patchNumber: Int64
    ) -> String {
        "\(prefix(for: category))\(sourceDevice).\(patchNumber)"
    }

    /**
     Returns the category-specific prefix used for applied patch status rows.

     - Parameter category: Logical sync category to scope.
     - Returns: Category-specific status prefix ending in a dot.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public func prefix(for category: RemoteSyncCategory) -> String {
        "\(Keys.prefix).\(category.rawValue)."
    }
}
