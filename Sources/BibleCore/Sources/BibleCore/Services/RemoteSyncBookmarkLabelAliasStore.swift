// RemoteSyncBookmarkLabelAliasStore.swift — Local preservation of Android-to-iOS special-label ID remaps

import Foundation

/**
 Preserves Android-to-iOS label identifier remaps for special bookmark labels.

 iOS canonicalizes the three reserved system labels (`speak`, `unlabeled`, and paragraph-break)
 onto deterministic UUIDs, while Android sync databases persist whatever random `IdType` values
 existed on the source device. Initial-backup restore therefore needs an alias map so later patch
 application can translate Android system-label IDs back onto the canonical iOS records.

 Data dependencies:
 - `SettingsStore` provides local-only key-value persistence in the `LocalStore`

 Side effects:
 - writes and removes namespaced `Setting` rows in the local SwiftData settings table

 Failure modes:
 - underlying `SettingsStore` writes swallow persistence failures, so callers should treat this
   store as best-effort bookkeeping rather than transactional state

 Concurrency:
 - this type inherits the confinement requirements of the supplied `SettingsStore`
 */
public final class RemoteSyncBookmarkLabelAliasStore {
    /**
     One preserved Android-to-iOS label identifier alias.

     The alias is directional: `remoteLabelID` is the identifier from Android sync payloads, while
     `localLabelID` is the canonical identifier used by the restored iOS SwiftData graph.
     */
    public struct Alias: Sendable, Equatable {
        /// Label identifier found in Android sync payloads.
        public let remoteLabelID: UUID

        /// Canonical iOS label identifier that now represents the same logical label.
        public let localLabelID: UUID

        /**
         Creates one preserved label alias.

         - Parameters:
           - remoteLabelID: Label identifier found in Android sync payloads.
           - localLabelID: Canonical iOS label identifier that represents the same logical label.
         - Side effects: none.
         - Failure modes: This initializer cannot fail.
         */
        public init(remoteLabelID: UUID, localLabelID: UUID) {
            self.remoteLabelID = remoteLabelID
            self.localLabelID = localLabelID
        }
    }

    private let settingsStore: SettingsStore

    private enum Keys {
        static let prefix = "remote_sync.bookmarks.label_alias"
    }

    /**
     Creates a local-only store for preserved Android-to-iOS label identifier aliases.

     - Parameter settingsStore: Local settings store used for persistence.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
     Stores or replaces one Android-to-iOS label identifier alias.

     - Parameters:
       - remoteLabelID: Label identifier found in Android sync payloads.
       - localLabelID: Canonical iOS label identifier representing the same logical label.
     - Side effects:
       - writes one namespaced local `Setting` row
     - Failure modes:
       - persistence failures are swallowed by `SettingsStore`
     */
    public func setAlias(remoteLabelID: UUID, localLabelID: UUID) {
        settingsStore.setString(scopedKey(remoteLabelID: remoteLabelID), value: localLabelID.uuidString.lowercased())
    }

    /**
     Reads one preserved Android-to-iOS label identifier alias.

     - Parameter remoteLabelID: Label identifier found in Android sync payloads.
     - Returns: The canonical iOS label identifier, or `nil` when no alias has been stored.
     - Side effects: none.
     - Failure modes:
       - malformed stored UUID strings return `nil`
     */
    public func localLabelID(forRemoteLabelID remoteLabelID: UUID) -> UUID? {
        guard let value = settingsStore.getString(scopedKey(remoteLabelID: remoteLabelID)), !value.isEmpty else {
            return nil
        }
        return UUID(uuidString: value)
    }

    /**
     Returns every preserved Android-to-iOS label identifier alias.

     - Returns: Preserved aliases sorted by remote UUID string.
     - Side effects: none.
     - Failure modes:
       - malformed keys or UUID payloads are skipped rather than throwing
     */
    public func allAliases() -> [Alias] {
        settingsStore.entries(withPrefix: Keys.prefix)
            .compactMap { decodeAlias($0) }
            .sorted { $0.remoteLabelID.uuidString < $1.remoteLabelID.uuidString }
    }

    /**
     Removes one preserved Android-to-iOS label identifier alias.

     - Parameter remoteLabelID: Label identifier found in Android sync payloads.
     - Side effects:
       - deletes one namespaced local `Setting` row when present
     - Failure modes:
       - persistence failures are swallowed by `SettingsStore`
     */
    public func removeAlias(forRemoteLabelID remoteLabelID: UUID) {
        settingsStore.remove(scopedKey(remoteLabelID: remoteLabelID))
    }

    /**
     Removes all preserved Android-to-iOS label identifier aliases.

     - Side effects:
       - deletes every namespaced local `Setting` row managed by this store
     - Failure modes:
       - persistence failures are swallowed by `SettingsStore`
     */
    public func clearAll() {
        for entry in settingsStore.entries(withPrefix: Keys.prefix) {
            settingsStore.remove(entry.key)
        }
    }

    private func scopedKey(remoteLabelID: UUID) -> String {
        "\(Keys.prefix).\(remoteLabelID.uuidString.lowercased())"
    }

    private func decodeAlias(_ entry: Setting) -> Alias? {
        let prefix = "\(Keys.prefix)."
        guard entry.key.hasPrefix(prefix),
              let remoteLabelID = UUID(uuidString: String(entry.key.dropFirst(prefix.count))),
              let localLabelID = UUID(uuidString: entry.value),
              !entry.value.isEmpty else {
            return nil
        }

        return Alias(remoteLabelID: remoteLabelID, localLabelID: localLabelID)
    }
}
