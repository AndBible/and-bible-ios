// RemoteSyncStateStore.swift — Category-scoped remote sync metadata persistence

import Foundation

/**
 Identifies the logical data categories Android syncs as separate patch streams.

 Android's `SyncableDatabaseDefinition` uses independent categories for bookmarks, workspaces,
 reading plans, My Documents, Progress, and AI settings. The iOS implementation preserves that separation so
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

    /// Reading and memorization progress data.
    case progress = "progress"

    /// Non-secret AI prompts, provider configuration, model metadata, preferences, and usage.
    case aiSettings = "ai_settings"

    /**
     Categories currently backed by iOS sync engines and eligible for lifecycle sweeps.

     Android hides the Reading Plans settings toggle at runtime even though the database remains
     syncable, so visible settings rows are curated separately by the UI presentation layer.
     */
    public static var activeSyncCases: [RemoteSyncCategory] {
        [.bookmarks, .workspaces, .readingPlans, .myDocuments, .aiSettings, .progress]
    }

    /// Highest Android SQLite schema version iOS can currently read and write for this category.
    public var currentSchemaVersion: Int {
        RemoteSyncAndroidDatabaseContract.schemaVersion(for: self)
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
 Persisted lifecycle phase for one remote sync category's initial baseline exchange.

 A category is not ready for incremental patch synchronization until its initial remote backup has
 either been restored locally or its local baseline has been uploaded. Unknown persisted values are
 retained as unsupported so a newer lifecycle state can never be mistaken for `ready` by an older
 build.
 */
public enum RemoteSyncBootstrapPhase: Sendable, Equatable {
    /// Initial baseline exchange completed; incremental patch synchronization may proceed.
    case ready

    /// Remote folder setup completed, but its initial backup still needs to be restored locally.
    case awaitingRemoteInitialRestore

    /// Remote folder setup completed, but the current local baseline still needs to be uploaded.
    case awaitingLocalInitialUpload

    /// A newer build persisted a phase this build does not understand; synchronization must fail closed.
    case unsupported(String)
}

/**
 Persisted bootstrap identifiers and lifecycle phase for one remote sync category.

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

    /// Initial-baseline lifecycle phase that determines whether incremental sync may begin.
    public var phase: RemoteSyncBootstrapPhase

    /**
     Creates one category bootstrap state payload.

     - Parameters:
       - syncFolderID: Remote identifier for the category's global sync folder.
       - deviceFolderID: Remote identifier for the current device's patch folder.
       - secretFileName: NextCloud secret marker filename used to prove sync-folder ownership.
       - phase: Initial-baseline lifecycle phase; absent legacy state defaults to ready.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        syncFolderID: String? = nil,
        deviceFolderID: String? = nil,
        secretFileName: String? = nil,
        phase: RemoteSyncBootstrapPhase = .ready
    ) {
        self.syncFolderID = syncFolderID
        self.deviceFolderID = deviceFolderID
        self.secretFileName = secretFileName
        self.phase = phase
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
 - ordinary setters preserve the existing best-effort `SettingsStore` behavior
 - `setBootstrapStateAtomically` surfaces strict fetch, cancellation, and commit failures after rollback
 */
public final class RemoteSyncStateStore {
    private let settingsStore: SettingsStore

    private enum Keys {
        static let scopePrefix = "remote_sync"
        static let syncFolderID = "syncId"
        static let deviceFolderID = "deviceFolderId"
        static let secretFileName = "nextCloudSecretFile"
        static let bootstrapPhase = "bootstrapPhase"
        static let pendingPublicationReset = "pendingPublicationReset"
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
     - Returns: Persisted identifiers and lifecycle phase. Missing legacy phase data maps to `.ready`.
     - Side effects: none.
     - Failure modes: Missing identifiers return as `nil`; unknown phase data is retained as `.unsupported`.
     */
    public func bootstrapState(for category: RemoteSyncCategory) -> RemoteSyncBootstrapState {
        RemoteSyncBootstrapState(
            syncFolderID: getNonEmptyString(Keys.syncFolderID, category: category),
            deviceFolderID: getNonEmptyString(Keys.deviceFolderID, category: category),
            secretFileName: getNonEmptyString(Keys.secretFileName, category: category),
            phase: bootstrapPhase(for: category)
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
        setOptionalString(serializedBootstrapPhase(state.phase), for: Keys.bootstrapPhase, category: category)
    }

    /**
     Persists one bootstrap state as a single durable settings transaction.

     - Parameters:
       - state: Folder identifiers and initial-baseline phase to persist together.
       - category: Logical sync category being updated.
     - Side Effects: Defers the individual setting upserts and commits them through one atomic batch.
     - Throws: Rethrows strict fetch, cancellation, mutation, or commit failures after rollback.
     */
    public func setBootstrapStateAtomically(
        _ state: RemoteSyncBootstrapState,
        for category: RemoteSyncCategory
    ) throws {
        try settingsStore.performAtomicBatch {
            setBootstrapState(state, for: category)
        }
    }

    /**
     Persists bootstrap state for a newly selected destination and resets generation-scoped gates.

     Remote setup has already succeeded when this method is called. The cleanup marker is committed
     with the new identifiers so a restart cannot begin initial restore/upload while an outbox for the
     former destination remains authoritative. Cursor and compatibility values belong to that same
     former generation, so clearing them in this transaction forces an unfiltered first discovery
     and permits the current local schema to re-evaluate remote compatibility.

     - Parameters:
       - state: New destination identifiers and lifecycle phase.
       - category: Logical category whose destination changed.
     - Side Effects: Atomically replaces bootstrap state, clears patch/cursor/version gates, and
       records pending-publication cleanup.
     - Throws: Rethrows strict fetch, cancellation, mutation, or commit failures after rollback.
     */
    func setBootstrapStateForNewDestinationAtomically(
        _ state: RemoteSyncBootstrapState,
        for category: RemoteSyncCategory
    ) throws {
        try settingsStore.performAtomicBatch {
            setBootstrapState(state, for: category)
            setOptionalInt64(nil, for: Keys.lastPatchWritten, category: category)
            setOptionalInt64(nil, for: Keys.lastSynchronized, category: category)
            setOptionalInt(nil, for: Keys.disabledForVersion, category: category)
            setOptionalString("true", for: Keys.pendingPublicationReset, category: category)
        }
    }

    /**
     Reports whether stale publications must be abandoned before using the persisted destination.

     - Parameter category: Logical category whose replacement boundary is being resumed.
     - Returns: `true` for the persisted marker and for any unknown nonempty token; otherwise `false`.
     - Side Effects: Reads one local setting.
     - Failure modes: Settings fetch failures retain `SettingsStore` behavior; unknown values fail closed.
     */
    func requiresPendingPublicationReset(for category: RemoteSyncCategory) -> Bool {
        getNonEmptyString(Keys.pendingPublicationReset, category: category) != nil
    }

    /**
     Marks explicit destination-replacement cleanup complete after all outbox files are abandoned.

     - Parameter category: Logical category whose cleanup completed.
     - Side Effects: Atomically removes the durable cleanup marker.
     - Throws: Rethrows strict fetch, cancellation, mutation, or commit failures after rollback.
     */
    func markPendingPublicationResetComplete(for category: RemoteSyncCategory) throws {
        try settingsStore.performAtomicBatch {
            setOptionalString(nil, for: Keys.pendingPublicationReset, category: category)
        }
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
            Keys.bootstrapPhase,
            Keys.pendingPublicationReset,
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

    /**
     Decodes the persisted initial-baseline phase without treating unknown future values as ready.

     - Parameter category: Logical sync category whose phase should be decoded.
     - Returns: Legacy absent values as `.ready`, known values as their phase, and unknown values as
       `.unsupported` with the original payload retained.
     - Side Effects: none.
     - Failure modes: This helper does not throw; malformed values fail closed as unsupported.
     */
    private func bootstrapPhase(for category: RemoteSyncCategory) -> RemoteSyncBootstrapPhase {
        guard let value = getNonEmptyString(Keys.bootstrapPhase, category: category) else {
            return .ready
        }
        switch value {
        case "ready":
            return .ready
        case "awaitingRemoteInitialRestore":
            return .awaitingRemoteInitialRestore
        case "awaitingLocalInitialUpload":
            return .awaitingLocalInitialUpload
        default:
            return .unsupported(value)
        }
    }

    /**
     Encodes one initial-baseline phase for durable settings storage.

     - Parameter phase: Lifecycle phase to encode.
     - Returns: Stable persisted token, preserving unsupported payloads byte-for-byte.
     - Side Effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func serializedBootstrapPhase(_ phase: RemoteSyncBootstrapPhase) -> String {
        switch phase {
        case .ready:
            return "ready"
        case .awaitingRemoteInitialRestore:
            return "awaitingRemoteInitialRestore"
        case .awaitingLocalInitialUpload:
            return "awaitingLocalInitialUpload"
        case .unsupported(let value):
            return value
        }
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
