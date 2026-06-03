// RemoteSyncStateStore.swift — Category-scoped remote sync metadata persistence

import Foundation

/**
 Identifies the logical data categories Android syncs as separate patch streams.

 Android's `SyncableDatabaseDefinition` uses independent categories for bookmarks, workspaces,
 reading plans, and My Documents. The iOS remote-sync implementation preserves that separation so
 remote folder naming, bootstrap state, and patch progress can be tracked per category instead of
 collapsing all user data into one opaque sync stream.
 */
public enum RemoteSyncCategory: String, CaseIterable, Sendable {
    /// Bookmark, label, note, and StudyPad data.
    case bookmarks = "bookmarks"

    /// Workspace, window, and page-manager layout data.
    case workspaces = "workspaces"

    /// Reading-plan definitions and completion progress.
    case readingPlans = "readingplans"

    /// My Documents document/page/content data.
    case myDocuments = "mydocuments"

    /**
     Categories currently backed by iOS sync engines and eligible for lifecycle sweeps.

     Android hides the Reading Plans settings toggle at runtime even though the database remains
     syncable, so visible settings rows are curated separately by the UI presentation layer.
     */
    public static var activeSyncCases: [RemoteSyncCategory] {
        [.bookmarks, .workspaces, .readingPlans, .myDocuments]
    }

    /// Highest Android SQLite schema version iOS can currently read and write for this category.
    public var currentSchemaVersion: Int {
        switch self {
        case .myDocuments:
            RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion
        case .bookmarks, .workspaces, .readingPlans:
            1
        }
    }

    /**
     Builds the Android-style remote sync folder name for this category.

     Android names each top-level sync folder as `{packageName}-sync-{categoryName}`.

     - Parameter bundleIdentifier: App bundle identifier or another package-like identifier.
     - Returns: Remote sync folder name for this category.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public func syncFolderName(bundleIdentifier: String) -> String {
        "\(bundleIdentifier)-sync-\(rawValue)"
    }
}

/**
 Persisted bootstrap identifiers for one remote sync category.

 These values correspond to Android's per-database `SyncConfiguration` entries that identify the
 chosen global sync folder, the device-specific patch folder, and the NextCloud secret marker file
 used to prove sync-folder ownership.
 */
public struct RemoteSyncBootstrapState: Sendable, Equatable {
    /// Remote identifier for the category's global sync folder.
    public var syncFolderID: String?

    /// Remote identifier for the current device's patch folder.
    public var deviceFolderID: String?

    /// NextCloud secret marker filename used to prove sync-folder ownership.
    public var secretFileName: String?

    /**
     Creates one category bootstrap state payload.

     - Parameters:
       - syncFolderID: Remote identifier for the category's global sync folder.
       - deviceFolderID: Remote identifier for the current device's patch folder.
       - secretFileName: NextCloud secret marker filename used to prove sync-folder ownership.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        syncFolderID: String? = nil,
        deviceFolderID: String? = nil,
        secretFileName: String? = nil
    ) {
        self.syncFolderID = syncFolderID
        self.deviceFolderID = deviceFolderID
        self.secretFileName = secretFileName
    }
}

/**
 Persisted patch progress values for one remote sync category.

 Android tracks these values in its `SyncConfiguration` table to coordinate upload/download order
 and version compatibility. iOS stores the same concepts locally so the future patch engine can
 resume after app restarts without re-discovering remote state from scratch.
 */
public struct RemoteSyncProgressState: Sendable, Equatable {
    /// Millisecond timestamp of the last locally written patch.
    public var lastPatchWritten: Int64?

    /// Millisecond timestamp of the last successful remote synchronization sweep.
    public var lastSynchronized: Int64?

    /// Local schema version for which remote sync was disabled due to incompatibility.
    public var disabledForVersion: Int?

    /**
     Creates one category patch-progress payload.

     - Parameters:
       - lastPatchWritten: Millisecond timestamp of the last locally written patch.
       - lastSynchronized: Millisecond timestamp of the last successful remote synchronization sweep.
       - disabledForVersion: Local schema version for which remote sync was disabled.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        lastPatchWritten: Int64? = nil,
        lastSynchronized: Int64? = nil,
        disabledForVersion: Int? = nil
    ) {
        self.lastPatchWritten = lastPatchWritten
        self.lastSynchronized = lastSynchronized
        self.disabledForVersion = disabledForVersion
    }
}

/**
 Persists Android-aligned remote sync metadata in iOS's local-only settings store.

 Android uses a dedicated `SyncConfiguration` key-value table per syncable database. iOS does not
 have an equivalent table yet, so this store namespaces the same raw Android keys inside the
 existing local-only `Setting` table. That keeps the persisted semantics aligned with Android while
 avoiding CloudKit sync for backend bookkeeping.

 Data dependencies:
 - `SettingsStore` provides durable local-only key-value persistence backed by SwiftData `Setting`
   rows in the `LocalStore`

 Side effects:
 - all writes persist values into local SwiftData through `SettingsStore`
 - clear operations remove only the scoped category keys they manage

 Failure modes:
 - underlying `SettingsStore` writes swallow save errors, so callers should treat this store as
   best-effort persistence and surface user-visible sync errors elsewhere
 */
public final class RemoteSyncStateStore {
    private let settingsStore: SettingsStore

    private enum Keys {
        static let scopePrefix = "remote_sync"
        static let syncFolderID = "syncId"
        static let deviceFolderID = "deviceFolderId"
        static let secretFileName = "nextCloudSecretFile"
        static let lastPatchWritten = "lastPatchWritten"
        static let lastSynchronized = "lastSynchronized"
        static let disabledForVersion = "disabledForVersion"
    }

    /**
     Creates a remote sync metadata store bound to a local settings store.

     - Parameter settingsStore: Local-only settings store used for persistence.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
     Reads the persisted bootstrap identifiers for one category.

     - Parameter category: Logical sync category whose bootstrap state should be read.
     - Returns: Persisted folder and marker identifiers, or `nil` values when a field has not been stored yet.
     - Side effects: none.
     - Failure modes: Missing or malformed values are returned as `nil` fields.
     */
    public func bootstrapState(for category: RemoteSyncCategory) -> RemoteSyncBootstrapState {
        RemoteSyncBootstrapState(
            syncFolderID: getNonEmptyString(Keys.syncFolderID, category: category),
            deviceFolderID: getNonEmptyString(Keys.deviceFolderID, category: category),
            secretFileName: getNonEmptyString(Keys.secretFileName, category: category)
        )
    }

    /**
     Persists the bootstrap identifiers for one category.

     - Parameters:
       - state: Bootstrap identifiers to persist.
       - category: Logical sync category being updated.
     - Side effects:
       - writes Android-aligned raw keys scoped under the category namespace into `SettingsStore`
     - Failure modes:
       - write failures are swallowed by `SettingsStore`
     */
    public func setBootstrapState(_ state: RemoteSyncBootstrapState, for category: RemoteSyncCategory) {
        setOptionalString(state.syncFolderID, for: Keys.syncFolderID, category: category)
        setOptionalString(state.deviceFolderID, for: Keys.deviceFolderID, category: category)
        setOptionalString(state.secretFileName, for: Keys.secretFileName, category: category)
    }

    /**
     Reads the persisted patch progress for one category.

     - Parameter category: Logical sync category whose patch progress should be read.
     - Returns: Persisted patch timestamps and compatibility flag, or `nil` fields when absent.
     - Side effects: none.
     - Failure modes: Missing or malformed numeric values are returned as `nil` fields.
     */
    public func progressState(for category: RemoteSyncCategory) -> RemoteSyncProgressState {
        RemoteSyncProgressState(
            lastPatchWritten: getInt64(Keys.lastPatchWritten, category: category),
            lastSynchronized: getInt64(Keys.lastSynchronized, category: category),
            disabledForVersion: getInt(Keys.disabledForVersion, category: category)
        )
    }

    /**
     Persists patch progress for one category.

     - Parameters:
       - state: Patch progress values to persist.
       - category: Logical sync category being updated.
     - Side effects:
       - writes Android-aligned raw keys scoped under the category namespace into `SettingsStore`
     - Failure modes:
       - write failures are swallowed by `SettingsStore`
     */
    public func setProgressState(_ state: RemoteSyncProgressState, for category: RemoteSyncCategory) {
        setOptionalInt64(state.lastPatchWritten, for: Keys.lastPatchWritten, category: category)
        setOptionalInt64(state.lastSynchronized, for: Keys.lastSynchronized, category: category)
        setOptionalInt(state.disabledForVersion, for: Keys.disabledForVersion, category: category)
    }

    /**
     Clears all bootstrap and progress metadata for one category.

     - Parameter category: Logical sync category whose persisted metadata should be removed.
     - Side effects:
       - clears all scoped metadata keys managed by this store for the given category
     - Failure modes:
       - write failures are swallowed by `SettingsStore`
     */
    public func clearCategory(_ category: RemoteSyncCategory) {
        let keys = [
            Keys.syncFolderID,
            Keys.deviceFolderID,
            Keys.secretFileName,
            Keys.lastPatchWritten,
            Keys.lastSynchronized,
            Keys.disabledForVersion,
        ]
        for key in keys {
            settingsStore.setString(scopedKey(key, category: category), value: "")
        }
    }

    /**
     Returns the fully scoped key used for the given Android raw key and category.

     - Parameters:
       - key: Android-aligned raw key name, such as `syncId`.
       - category: Logical sync category.
     - Returns: Category-scoped local settings key.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    public func scopedKey(_ key: String, category: RemoteSyncCategory) -> String {
        "\(Keys.scopePrefix).\(category.rawValue).\(key)"
    }

    private func getNonEmptyString(_ key: String, category: RemoteSyncCategory) -> String? {
        let value = settingsStore.getString(scopedKey(key, category: category))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func setOptionalString(_ value: String?, for key: String, category: RemoteSyncCategory) {
        settingsStore.setString(scopedKey(key, category: category), value: value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    private func getInt64(_ key: String, category: RemoteSyncCategory) -> Int64? {
        guard let stringValue = getNonEmptyString(key, category: category) else {
            return nil
        }
        return Int64(stringValue)
    }

    private func setOptionalInt64(_ value: Int64?, for key: String, category: RemoteSyncCategory) {
        settingsStore.setString(scopedKey(key, category: category), value: value.map(String.init) ?? "")
    }

    private func getInt(_ key: String, category: RemoteSyncCategory) -> Int? {
        guard let stringValue = getNonEmptyString(key, category: category) else {
            return nil
        }
        return Int(stringValue)
    }

    private func setOptionalInt(_ value: Int?, for key: String, category: RemoteSyncCategory) {
        settingsStore.setString(scopedKey(key, category: category), value: value.map(String.init) ?? "")
    }
}
