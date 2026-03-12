// RemoteSyncWorkspaceFidelityStore.swift — Local preservation of Android-only workspace fidelity payloads

import Foundation

/**
 Preserves Android-only workspace restore data in iOS's local-only settings store.

 Android's workspace sync database contains several values that the current iOS SwiftData models do
 not represent directly:
 - raw `WorkspaceSettings.speakSettings` JSON
 - raw `PageManager.currentCategoryName` strings, which use Android enum-style names instead of the
   lower-case page-manager keys persisted by iOS
 - commentary/dictionary/general-book/map anchor fields that iOS does not store in `PageManager`
 - Android `HistoryItem.id` integer primary keys, which need alias rows because iOS history items
   use UUID identifiers instead

 This store preserves that data locally so initial-backup restore can remain faithful to Android's
 persisted state without polluting the synced SwiftData graph.

 Data dependencies:
 - `SettingsStore` provides local-only key-value persistence in the `LocalStore`

 Side effects:
 - writes and removes namespaced `Setting` rows in the local SwiftData settings table

 Failure modes:
 - underlying `SettingsStore` writes swallow persistence failures, so callers should treat this
   store as best-effort fidelity preservation rather than transactional storage

 Concurrency:
 - this type inherits the confinement requirements of the supplied `SettingsStore`
 */
public final class RemoteSyncWorkspaceFidelityStore {
    /**
     One preserved Android workspace-level fidelity payload.

     `speakSettingsJSON` is stored verbatim because iOS does not yet project Android's richer
     workspace speech settings into a native model.
     */
    public struct WorkspaceEntry: Sendable, Equatable {
        /// Workspace identifier shared by Android and iOS.
        public let workspaceID: UUID

        /// Raw Android `WorkspaceSettings.speakSettings` JSON payload.
        public let speakSettingsJSON: String

        /**
         Creates one preserved Android workspace-level fidelity payload.

         - Parameters:
           - workspaceID: Workspace identifier shared by Android and iOS.
           - speakSettingsJSON: Raw Android `WorkspaceSettings.speakSettings` JSON payload.
         - Side effects: none.
         - Failure modes: This initializer cannot fail.
         */
        public init(workspaceID: UUID, speakSettingsJSON: String) {
            self.workspaceID = workspaceID
            self.speakSettingsJSON = speakSettingsJSON
        }
    }

    /**
     One preserved Android page-manager fidelity payload.

     The entry records the raw Android active category name for every restored page manager and any
     Android-only fields that do not have direct iOS storage.
     */
    public struct PageManagerEntry: Sendable, Equatable {
        /// Window identifier shared by the owning Android page-manager row and the iOS window.
        public let windowID: UUID

        /// Raw Android `currentCategoryName` string, such as `BIBLE` or `MYNOTE`.
        public let rawCurrentCategoryName: String

        /// Raw Android `commentary_sourceBookAndKey` payload when present.
        public let commentarySourceBookAndKey: String?

        /// Raw Android `dictionary_anchorOrdinal` value when present.
        public let dictionaryAnchorOrdinal: Int?

        /// Raw Android `general_book_anchorOrdinal` value when present.
        public let generalBookAnchorOrdinal: Int?

        /// Raw Android `map_anchorOrdinal` value when present.
        public let mapAnchorOrdinal: Int?

        /**
         Creates one preserved Android page-manager fidelity payload.

         - Parameters:
           - windowID: Window identifier shared by the Android page-manager row and the iOS window.
           - rawCurrentCategoryName: Raw Android `currentCategoryName` string.
           - commentarySourceBookAndKey: Raw Android `commentary_sourceBookAndKey` payload.
           - dictionaryAnchorOrdinal: Raw Android `dictionary_anchorOrdinal` value.
           - generalBookAnchorOrdinal: Raw Android `general_book_anchorOrdinal` value.
           - mapAnchorOrdinal: Raw Android `map_anchorOrdinal` value.
         - Side effects: none.
         - Failure modes: This initializer cannot fail.
         */
        public init(
            windowID: UUID,
            rawCurrentCategoryName: String,
            commentarySourceBookAndKey: String?,
            dictionaryAnchorOrdinal: Int?,
            generalBookAnchorOrdinal: Int?,
            mapAnchorOrdinal: Int?
        ) {
            self.windowID = windowID
            self.rawCurrentCategoryName = rawCurrentCategoryName
            self.commentarySourceBookAndKey = commentarySourceBookAndKey
            self.dictionaryAnchorOrdinal = dictionaryAnchorOrdinal
            self.generalBookAnchorOrdinal = generalBookAnchorOrdinal
            self.mapAnchorOrdinal = mapAnchorOrdinal
        }
    }

    /**
     One preserved alias between an Android history-row identifier and its iOS UUID replacement.

     Android uses integer primary keys for `HistoryItem`, while iOS persists UUID identifiers. The
     alias is therefore required for later patch translation and reconciliation.
     */
    public struct HistoryItemAlias: Sendable, Equatable {
        /// Android `HistoryItem.id` primary-key value.
        public let remoteHistoryItemID: Int64

        /// UUID assigned to the restored iOS `HistoryItem` row.
        public let localHistoryItemID: UUID

        /**
         Creates one preserved Android-to-iOS history-item identifier alias.

         - Parameters:
           - remoteHistoryItemID: Android `HistoryItem.id` primary-key value.
           - localHistoryItemID: UUID assigned to the restored iOS `HistoryItem` row.
         - Side effects: none.
         - Failure modes: This initializer cannot fail.
         */
        public init(remoteHistoryItemID: Int64, localHistoryItemID: UUID) {
            self.remoteHistoryItemID = remoteHistoryItemID
            self.localHistoryItemID = localHistoryItemID
        }
    }

    /**
     Serialized page-manager fidelity payload stored inside one local settings row.

     The store uses this DTO so the persisted JSON shape stays explicit and stable even if the
     public `PageManagerEntry` acquires non-persisted helpers later.
     */
    private struct StoredPageManagerEntry: Codable, Sendable, Equatable {
        let rawCurrentCategoryName: String
        let commentarySourceBookAndKey: String?
        let dictionaryAnchorOrdinal: Int?
        let generalBookAnchorOrdinal: Int?
        let mapAnchorOrdinal: Int?
    }

    /// Local-only settings persistence dependency shared by every fidelity operation.
    private let settingsStore: SettingsStore

    /// JSON encoder used for `StoredPageManagerEntry` payloads.
    private let encoder = JSONEncoder()

    /// JSON decoder used for `StoredPageManagerEntry` payloads.
    private let decoder = JSONDecoder()

    /**
     Namespaced key prefixes used to partition the three fidelity payload families.
     */
    private enum Keys {
        static let workspacePrefix = "remote_sync.workspaces.fidelity.workspace"
        static let pageManagerPrefix = "remote_sync.workspaces.fidelity.page_manager"
        static let historyAliasPrefix = "remote_sync.workspaces.fidelity.history_alias"
    }

    /**
     Creates a local-only fidelity store for Android workspace restore metadata.

     - Parameter settingsStore: Local settings store used for persistence.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
     Stores or replaces one raw Android workspace speech-settings payload.

     - Parameters:
       - speakSettingsJSON: Raw Android `WorkspaceSettings.speakSettings` JSON payload.
       - workspaceID: Workspace identifier that owns the payload.
     - Side effects:
       - writes one namespaced local `Setting` row
     - Failure modes:
       - persistence failures are swallowed by `SettingsStore`
     */
    public func setSpeakSettingsJSON(_ speakSettingsJSON: String, for workspaceID: UUID) {
        settingsStore.setString(workspaceScopedKey(workspaceID: workspaceID), value: speakSettingsJSON)
    }

    /**
     Reads one preserved Android workspace speech-settings payload.

     - Parameter workspaceID: Workspace identifier that owns the payload.
     - Returns: The preserved raw JSON payload, or `nil` when no value has been stored.
     - Side effects: none.
     - Failure modes:
       - missing stored values return `nil`
     */
    public func speakSettingsJSON(for workspaceID: UUID) -> String? {
        guard let value = settingsStore.getString(workspaceScopedKey(workspaceID: workspaceID)), !value.isEmpty else {
            return nil
        }
        return value
    }

    /**
     Returns every preserved Android workspace speech-settings payload.

     - Returns: Preserved workspace entries sorted by workspace UUID string.
     - Side effects: none.
     - Failure modes:
       - malformed keys are skipped rather than throwing
     */
    public func allWorkspaceEntries() -> [WorkspaceEntry] {
        settingsStore.entries(withPrefix: Keys.workspacePrefix)
            .compactMap { entry in
                decodeWorkspaceEntry(entry)
            }
            .sorted { $0.workspaceID.uuidString < $1.workspaceID.uuidString }
    }

    /**
     Removes one preserved Android workspace speech-settings payload.

     - Parameter workspaceID: Workspace identifier that owns the payload.
     - Side effects:
       - deletes one namespaced local `Setting` row when present
     - Failure modes:
       - persistence failures are swallowed by `SettingsStore`
     */
    public func removeWorkspaceEntry(for workspaceID: UUID) {
        settingsStore.remove(workspaceScopedKey(workspaceID: workspaceID))
    }

    /**
     Stores or replaces one Android page-manager fidelity payload.

     - Parameter entry: Page-manager fidelity payload to persist.
     - Side effects:
       - writes one namespaced local `Setting` row containing JSON-encoded fidelity metadata
     - Failure modes:
       - JSON-encoding failures are ignored
       - persistence failures are swallowed by `SettingsStore`
     */
    public func setPageManagerEntry(_ entry: PageManagerEntry) {
        let storedEntry = StoredPageManagerEntry(
            rawCurrentCategoryName: entry.rawCurrentCategoryName,
            commentarySourceBookAndKey: entry.commentarySourceBookAndKey,
            dictionaryAnchorOrdinal: entry.dictionaryAnchorOrdinal,
            generalBookAnchorOrdinal: entry.generalBookAnchorOrdinal,
            mapAnchorOrdinal: entry.mapAnchorOrdinal
        )
        guard let data = try? encoder.encode(storedEntry),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }
        settingsStore.setString(pageManagerScopedKey(windowID: entry.windowID), value: payload)
    }

    /**
     Reads one preserved Android page-manager fidelity payload.

     - Parameter windowID: Window identifier that owns the page-manager payload.
     - Returns: Decoded fidelity payload, or `nil` when no usable value has been stored.
     - Side effects: none.
     - Failure modes:
       - malformed keys or JSON payloads return `nil`
     */
    public func pageManagerEntry(for windowID: UUID) -> PageManagerEntry? {
        let key = pageManagerScopedKey(windowID: windowID)
        guard let entry = settingsStore.entries(withPrefix: key).first(where: { $0.key == key }) else {
            return nil
        }
        return decodePageManagerEntry(entry)
    }

    /**
     Returns every preserved Android page-manager fidelity payload.

     - Returns: Page-manager fidelity entries sorted by window UUID string.
     - Side effects: none.
     - Failure modes:
       - malformed keys or JSON payloads are skipped rather than throwing
     */
    public func allPageManagerEntries() -> [PageManagerEntry] {
        settingsStore.entries(withPrefix: Keys.pageManagerPrefix)
            .compactMap { entry in
                decodePageManagerEntry(entry)
            }
            .sorted { $0.windowID.uuidString < $1.windowID.uuidString }
    }

    /**
     Removes one preserved Android page-manager fidelity payload.

     - Parameter windowID: Window identifier that owns the payload.
     - Side effects:
       - deletes one namespaced local `Setting` row when present
     - Failure modes:
       - persistence failures are swallowed by `SettingsStore`
     */
    public func removePageManagerEntry(for windowID: UUID) {
        settingsStore.remove(pageManagerScopedKey(windowID: windowID))
    }

    /**
     Stores or replaces one Android-to-iOS history-item identifier alias.

     - Parameters:
       - remoteHistoryItemID: Android `HistoryItem.id` primary-key value.
       - localHistoryItemID: UUID assigned to the restored iOS `HistoryItem` row.
     - Side effects:
       - writes one namespaced local `Setting` row
     - Failure modes:
       - persistence failures are swallowed by `SettingsStore`
     */
    public func setHistoryItemAlias(remoteHistoryItemID: Int64, localHistoryItemID: UUID) {
        settingsStore.setString(
            historyAliasScopedKey(remoteHistoryItemID: remoteHistoryItemID),
            value: localHistoryItemID.uuidString.lowercased()
        )
    }

    /**
     Reads one Android-to-iOS history-item identifier alias.

     - Parameter remoteHistoryItemID: Android `HistoryItem.id` primary-key value.
     - Returns: UUID assigned to the restored iOS row, or `nil` when no alias exists.
     - Side effects: none.
     - Failure modes:
       - malformed stored UUID payloads return `nil`
     */
    public func localHistoryItemID(for remoteHistoryItemID: Int64) -> UUID? {
        guard let value = settingsStore.getString(historyAliasScopedKey(remoteHistoryItemID: remoteHistoryItemID)),
              !value.isEmpty else {
            return nil
        }
        return UUID(uuidString: value)
    }

    /**
     Returns every preserved Android-to-iOS history-item identifier alias.

     - Returns: History-item aliases sorted by Android history identifier.
     - Side effects: none.
     - Failure modes:
       - malformed keys or UUID payloads are skipped rather than throwing
     */
    public func allHistoryItemAliases() -> [HistoryItemAlias] {
        settingsStore.entries(withPrefix: Keys.historyAliasPrefix)
            .compactMap { entry in
                decodeHistoryAlias(entry)
            }
            .sorted { $0.remoteHistoryItemID < $1.remoteHistoryItemID }
    }

    /**
     Removes one Android-to-iOS history-item identifier alias.

     - Parameter remoteHistoryItemID: Android `HistoryItem.id` primary-key value.
     - Side effects:
       - deletes one namespaced local `Setting` row when present
     - Failure modes:
       - persistence failures are swallowed by `SettingsStore`
     */
    public func removeHistoryItemAlias(for remoteHistoryItemID: Int64) {
        settingsStore.remove(historyAliasScopedKey(remoteHistoryItemID: remoteHistoryItemID))
    }

    /**
     Removes all preserved Android workspace fidelity payloads managed by this store.

     - Side effects:
       - deletes every namespaced local `Setting` row managed by this store
     - Failure modes:
       - persistence failures are swallowed by `SettingsStore`
     */
    public func clearAll() {
        for prefix in [Keys.workspacePrefix, Keys.pageManagerPrefix, Keys.historyAliasPrefix] {
            for entry in settingsStore.entries(withPrefix: prefix) {
                settingsStore.remove(entry.key)
            }
        }
    }

    /**
     Builds the local settings key for one workspace-level fidelity payload.

     - Parameter workspaceID: Workspace identifier that owns the fidelity payload.
     - Returns: Fully qualified settings key under the workspace fidelity namespace.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func workspaceScopedKey(workspaceID: UUID) -> String {
        "\(Keys.workspacePrefix).\(workspaceID.uuidString.lowercased())"
    }

    /**
     Builds the local settings key for one page-manager fidelity payload.

     - Parameter windowID: Window identifier that owns the page-manager payload.
     - Returns: Fully qualified settings key under the page-manager fidelity namespace.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func pageManagerScopedKey(windowID: UUID) -> String {
        "\(Keys.pageManagerPrefix).\(windowID.uuidString.lowercased())"
    }

    /**
     Builds the local settings key for one Android-to-iOS history identifier alias.

     - Parameter remoteHistoryItemID: Android `HistoryItem.id` primary-key value.
     - Returns: Fully qualified settings key under the history-alias namespace.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func historyAliasScopedKey(remoteHistoryItemID: Int64) -> String {
        "\(Keys.historyAliasPrefix).\(remoteHistoryItemID)"
    }

    /**
     Decodes one workspace fidelity settings row back into a typed workspace entry.

     - Parameter entry: Raw settings row fetched from `SettingsStore`.
     - Returns: Decoded workspace fidelity entry, or `nil` when the key/value pair is malformed.
     - Side effects: none.
     - Failure modes:
       - malformed UUID suffixes or empty payloads return `nil`
     */
    private func decodeWorkspaceEntry(_ entry: Setting) -> WorkspaceEntry? {
        let prefix = "\(Keys.workspacePrefix)."
        guard entry.key.hasPrefix(prefix),
              !entry.value.isEmpty,
              let workspaceID = UUID(uuidString: String(entry.key.dropFirst(prefix.count))) else {
            return nil
        }
        return WorkspaceEntry(workspaceID: workspaceID, speakSettingsJSON: entry.value)
    }

    /**
     Decodes one JSON-backed page-manager fidelity settings row.

     - Parameter entry: Raw settings row fetched from `SettingsStore`.
     - Returns: Decoded page-manager fidelity entry, or `nil` when the key or JSON payload is malformed.
     - Side effects: none.
     - Failure modes:
       - malformed UUID suffixes or invalid JSON payloads return `nil`
     */
    private func decodePageManagerEntry(_ entry: Setting) -> PageManagerEntry? {
        let prefix = "\(Keys.pageManagerPrefix)."
        guard entry.key.hasPrefix(prefix),
              let windowID = UUID(uuidString: String(entry.key.dropFirst(prefix.count))),
              let data = entry.value.data(using: .utf8),
              let payload = try? decoder.decode(StoredPageManagerEntry.self, from: data) else {
            return nil
        }

        return PageManagerEntry(
            windowID: windowID,
            rawCurrentCategoryName: payload.rawCurrentCategoryName,
            commentarySourceBookAndKey: payload.commentarySourceBookAndKey,
            dictionaryAnchorOrdinal: payload.dictionaryAnchorOrdinal,
            generalBookAnchorOrdinal: payload.generalBookAnchorOrdinal,
            mapAnchorOrdinal: payload.mapAnchorOrdinal
        )
    }

    /**
     Decodes one Android history-item alias row back into typed identifiers.

     - Parameter entry: Raw settings row fetched from `SettingsStore`.
     - Returns: Decoded alias entry, or `nil` when the key or UUID payload is malformed.
     - Side effects: none.
     - Failure modes:
       - malformed integer suffixes or malformed UUID payloads return `nil`
     */
    private func decodeHistoryAlias(_ entry: Setting) -> HistoryItemAlias? {
        let prefix = "\(Keys.historyAliasPrefix)."
        guard entry.key.hasPrefix(prefix),
              let remoteHistoryItemID = Int64(String(entry.key.dropFirst(prefix.count))),
              let localHistoryItemID = UUID(uuidString: entry.value),
              !entry.value.isEmpty else {
            return nil
        }
        return HistoryItemAlias(
            remoteHistoryItemID: remoteHistoryItemID,
            localHistoryItemID: localHistoryItemID
        )
    }
}
