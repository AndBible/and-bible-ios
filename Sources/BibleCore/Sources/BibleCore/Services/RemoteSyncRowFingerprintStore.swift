// RemoteSyncRowFingerprintStore.swift — Local content-hash bookkeeping for outbound sync diffs

import Foundation

/**
 Persists Android-row content fingerprints in the local settings table.

 Android uses SQLite triggers and `LogEntry` timestamps to know which rows changed since the last
 upload. SwiftData does not expose the underlying SQLite trigger surface cleanly, so iOS keeps a
 parallel best-effort fingerprint map keyed by the same `(tableName, entityId1, entityId2)`
 composite identifier used by `RemoteSyncLogEntryStore`. Outbound patch creation can then detect
 new, changed, and deleted rows without guessing from view-layer mutation paths.

 Data dependencies:
 - `SettingsStore` provides durable local-only persistence
 - `RemoteSyncLogEntryStore` supplies the canonical Android composite-key encoding used by sync

 Side effects:
 - writes and deletes local `Setting` rows in the `LocalStore`

 Failure modes:
 - underlying `SettingsStore` save failures are swallowed, so callers must treat this store as
   best-effort diff bookkeeping rather than transactional state

 Concurrency:
 - this type inherits the confinement requirements of the supplied `SettingsStore`
 */
public final class RemoteSyncRowFingerprintStore {
    private let settingsStore: SettingsStore
    private let keyBuilder: RemoteSyncLogEntryStore

    private enum Keys {
        static let prefix = "remote_sync.row_fingerprints"
    }

    /**
     Creates a row-fingerprint store bound to one local settings store.

     - Parameter settingsStore: Local-only settings store used for persistence.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.keyBuilder = RemoteSyncLogEntryStore(settingsStore: settingsStore)
    }

    /**
     Persists one row fingerprint for the supplied Android composite key.

     - Parameters:
       - fingerprint: Stable content fingerprint for the row.
       - category: Logical sync category that owns the row.
       - tableName: Android table name that owns the row.
       - entityID1: First composite identifier component.
       - entityID2: Second composite identifier component.
     - Side effects:
       - writes one namespaced local `Setting` row
     - Failure modes:
       - underlying `SettingsStore` save failures are swallowed
     */
    public func setFingerprint(
        _ fingerprint: String,
        for category: RemoteSyncCategory,
        tableName: String,
        entityID1: RemoteSyncSQLiteValue,
        entityID2: RemoteSyncSQLiteValue
    ) {
        settingsStore.setString(
            key(
                for: category,
                tableName: tableName,
                entityID1: entityID1,
                entityID2: entityID2
            ),
            value: fingerprint
        )
    }

    /**
     Reads one stored row fingerprint when it exists.

     - Parameters:
       - category: Logical sync category to inspect.
       - tableName: Android table name that owns the row.
       - entityID1: First composite identifier component.
       - entityID2: Second composite identifier component.
     - Returns: Stored fingerprint when present; otherwise `nil`.
     - Side effects: reads local `Setting` rows.
     - Failure modes:
       - missing rows return `nil`
     */
    public func fingerprint(
        for category: RemoteSyncCategory,
        tableName: String,
        entityID1: RemoteSyncSQLiteValue,
        entityID2: RemoteSyncSQLiteValue
    ) -> String? {
        settingsStore.getString(
            key(
                for: category,
                tableName: tableName,
                entityID1: entityID1,
                entityID2: entityID2
            )
        )
    }

    /**
     Reads one stored row fingerprint using the canonical Android log-entry key.

     Outbound diffing sometimes starts from a preserved composite key before it has resolved a full
     `RemoteSyncLogEntry`. This helper lets callers reuse the same fingerprint namespace without
     reconstructing the individual SQLite value components first.

     - Parameters:
       - logKey: Canonical Android log-entry key built by `RemoteSyncLogEntryStore`.
       - category: Logical sync category that owns the row.
     - Returns: Stored fingerprint when present; otherwise `nil`.
     - Side effects: reads local `Setting` rows.
     - Failure modes:
       - returns `nil` when the supplied key does not belong to the category or no fingerprint exists
     */
    public func fingerprint(
        forLogKey logKey: String,
        category: RemoteSyncCategory
    ) -> String? {
        let logPrefix = keyBuilder.prefix(for: category)
        guard logKey.hasPrefix(logPrefix) else {
            return nil
        }
        let suffix = String(logKey.dropFirst(logPrefix.count))
        return settingsStore.getString("\(prefix(for: category))\(suffix)")
    }

    /**
     Removes one stored row fingerprint.

     - Parameters:
       - category: Logical sync category that owns the row.
       - tableName: Android table name that owns the row.
       - entityID1: First composite identifier component.
       - entityID2: Second composite identifier component.
     - Side effects:
       - deletes one namespaced local `Setting` row when present
     - Failure modes:
       - underlying `SettingsStore` delete failures are swallowed
     */
    public func removeFingerprint(
        for category: RemoteSyncCategory,
        tableName: String,
        entityID1: RemoteSyncSQLiteValue,
        entityID2: RemoteSyncSQLiteValue
    ) {
        settingsStore.remove(
            key(
                for: category,
                tableName: tableName,
                entityID1: entityID1,
                entityID2: entityID2
            )
        )
    }

    /**
     Clears all stored fingerprints for one category.

     - Parameter category: Logical sync category whose fingerprints should be removed.
     - Side effects:
       - deletes all matching fingerprint rows from `SettingsStore`
     - Failure modes:
       - underlying `SettingsStore` delete failures are swallowed
     */
    public func clearCategory(_ category: RemoteSyncCategory) {
        for entry in settingsStore.entries(withPrefix: prefix(for: category)) {
            settingsStore.remove(entry.key)
        }
    }

    /**
     Builds the fully scoped settings key for one fingerprinted row.

     - Parameters:
       - category: Logical sync category that owns the row.
       - tableName: Android table name that owns the row.
       - entityID1: First composite identifier component.
       - entityID2: Second composite identifier component.
     - Returns: Fully scoped local settings key.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public func key(
        for category: RemoteSyncCategory,
        tableName: String,
        entityID1: RemoteSyncSQLiteValue,
        entityID2: RemoteSyncSQLiteValue
    ) -> String {
        let logPrefix = keyBuilder.prefix(for: category)
        let logKey = keyBuilder.key(
            for: category,
            tableName: tableName,
            entityID1: entityID1,
            entityID2: entityID2
        )
        let suffix = String(logKey.dropFirst(logPrefix.count))
        return "\(prefix(for: category))\(suffix)"
    }

    /**
     Returns the category-specific prefix used for fingerprint rows.

     - Parameter category: Logical sync category to scope.
     - Returns: Category-specific fingerprint prefix ending in a dot.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public func prefix(for category: RemoteSyncCategory) -> String {
        "\(Keys.prefix).\(category.rawValue)."
    }
}
