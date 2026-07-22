// SettingsStore.swift — App-level settings persistence

import Foundation
import Observation
import SwiftData

/**
 * A persisted global key-value record stored in the local SwiftData store.
 *
 * This model backs app-wide preferences and bookkeeping that must survive app restarts
 * but must not participate in CloudKit sync. Values are stored as raw strings so the
 * store can support multiple logical types without schema changes.
 */
@Model
public final class Setting {
    /**
     * Unique logical setting key.
     *
     * The value is unique across the table and is used as the upsert key for all writes.
     */
    @Attribute(.unique) public var key: String
    /**
     * Raw persisted payload for the setting.
     *
     * Callers are responsible for encoding and decoding booleans, integers, doubles,
     * UUIDs, and CSV-backed string sets on top of this string storage.
     */
    public var value: String

    /**
     * Creates a persisted key-value setting row.
     * - Parameters:
     *   - key: Unique setting key.
     *   - value: Raw string payload to persist.
     * - Important: This initializer does not save by itself. Persistence happens only after the
     *   owning `ModelContext` is saved by `SettingsStore`.
     */
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/**
 Errors raised when an explicit settings-backed SwiftData batch cannot establish one atomic commit.

 These errors protect callers that need `Setting` mutations to commit with a larger object graph.
 Ordinary settings access does not use this boundary and retains its historical soft-failure behavior.
 */
public enum SettingsStoreAtomicBatchError: Error, Equatable {
    /// The caller supplied a context other than the exact context owned by this settings store.
    case modelContextMismatch

    /// The context already had unsaved changes that the batch could not safely own or roll back.
    case pendingModelChanges
}

/**
 Reports that an atomic batch failed to restore a pre-commit generation after a store commit error.

 The original commit error remains available for diagnostics, while `recoveryError` identifies the
 store-specific compensation that could not be completed. Callers must treat this error as requiring
 recovery on the next launch because cross-store durability can no longer be guaranteed in-process.
 */
public struct SettingsStoreAtomicRecoveryError: Error {
    /// Error raised by the original multi-store transaction commit.
    public let commitError: Error

    /// Error raised while restoring one pre-commit store generation.
    public let recoveryError: Error
}

/**
 * Manages app-level key-value settings stored in `LocalStore`.
 *
 * This store owns two related responsibilities:
 * - persist global local-only settings such as the active workspace ID
 * - route Android parity preferences to either SwiftData, `UserDefaults`, or no-op action storage
 *
 * Reading-display inheritance is resolved through:
 * `PageManager.textDisplaySettings` -> `Workspace.textDisplaySettings` ->
 * `SettingsStore.globalTextDisplaySettings` -> `TextDisplaySettings.appDefaults`.
 *
 * For Android parity settings keyed by `AppPreferenceKey`, this store routes persistence to the
 * correct backend:
 * - `.swiftData`: stored here as string values
 * - `.userDefaults`: stored in `UserDefaults`
 * - `.action`: read as defaults and ignored on write because the preference represents a button
 *   rather than durable state
 *
 * Failure handling is intentionally soft:
 * - fetch failures fall back to `nil` or the supplied/default registry fallback
 * - write failures are swallowed because the current callers are UI preference flows that should
 *   not crash on persistence errors
 * - callers that need graph-level atomicity can opt into `performAtomicBatch(in:_:)`; only that
 *   explicit scope turns fetch/save failures into thrown errors and rolls back the complete context
 *
 * - Important: `SettingsStore` is only as thread-safe as the supplied `ModelContext`.
 *   Callers must respect SwiftData context confinement and avoid cross-thread mutation.
 */
@Observable
public final class SettingsStore {
    /// SwiftData context used for all `Setting` reads and writes that target the local store.
    private let modelContext: ModelContext

    /**
     Exposes the exact context owned by this store to internal atomic-publication services.

     - Returns: The context supplied at initialization; ownership and actor confinement do not change.
     - Side effects: none.
     - Failure modes: none. Callers must still use `performAtomicBatch` for coordinated mutations.
     */
    var persistenceModelContext: ModelContext { modelContext }

    /// Number of nested explicit atomic scopes currently deferring this store's internal saves.
    @ObservationIgnored private var atomicBatchDepth = 0

    /// First soft persistence failure captured while an explicit atomic scope is active.
    @ObservationIgnored private var atomicBatchFailure: Error?

    /// Store-specific durable recovery actions registered by the outer batch and nested callers.
    @ObservationIgnored private var atomicBatchRecoveryActions: [(ModelContainer) throws -> Void] = []

    /**
     * Creates a settings store bound to the caller's SwiftData context.
     * - Parameter modelContext: Context used for `Setting` persistence.
     * - Important: The caller owns the lifecycle and actor/thread confinement of this context.
     */
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /**
     Performs settings and related SwiftData mutations as one explicit atomic persistence batch.

     All `SettingsStore` SwiftData upserts, removals, and propagation writes reached from `mutations`
     defer their normal immediate saves. The outermost scope then executes one primary save through
     `ModelContext.transaction(block:)`. Nested calls on this same store join the outer scope and
     register their durable recovery actions with that commit owner; a nested error marks the whole
     outer batch failed even if an intermediate caller catches it.

     SwiftData configurations backed by different SQLite files do not share one durable transaction.
     If one configuration commits before another reports a save error, this store restores its exact
     pre-batch `Setting` generation and invokes registered graph recoveries in reverse registration
     order. This compensation makes the complete old generation durable before the error returns.

     This API is intended for restore operations that mutate a SwiftData graph and one or more
     `Setting` rows together. The complete graph mutation must occur inside `mutations`. The supplied
     context must be the exact context used to construct this store and must have no pending changes,
     because rollback necessarily applies to every unsaved mutation in that context. UserDefaults
     writes do not participate in this SwiftData boundary and must not be performed in the closure.

     - Parameters:
       - modelContext: Exact, clean context shared by the settings store and the graph being replaced.
       - durableRecovery: Optional store-specific recovery that restores the pre-commit generation
         through fresh contexts after a partial multi-configuration commit. Nested recoveries join the
         outer batch. The settings store snapshots and recovers all `Setting` rows automatically.
       - mutations: Synchronous mutations whose SwiftData effects must commit or roll back together.
     - Returns: Value returned by `mutations` after the primary save succeeds.
     - Side Effects:
       - temporarily disables autosave on the shared context for the outermost scope
       - defers nested `SettingsStore` SwiftData saves
       - commits the shared context exactly once on success through SwiftData's native transaction
       - rolls back pending state on mutation, cancellation, fetch, or commit failure
       - restores pre-commit settings and attempts every registered graph recovery after a partial
         store commit; graph recoveries run in reverse registration order
     - Throws:
       - `SettingsStoreAtomicBatchError.modelContextMismatch` when contexts differ
       - `SettingsStoreAtomicBatchError.pendingModelChanges` when the outer context is not clean
       - `CancellationError` when the current task is cancelled before the final save
       - any error thrown by `mutations`, a strict in-batch settings fetch, or transaction commit
       - `SettingsStoreAtomicRecoveryError` when durable recovery fails after a commit error
     - Important: This method is synchronous and inherits `ModelContext` confinement. A caller must
       not mutate or save any participating configuration from another context until this method
       returns; durable compensation restores whole generations and would overwrite such writes.
     */
    public func performAtomicBatch<Result>(
        in modelContext: ModelContext,
        durableRecovery: ((ModelContainer) throws -> Void)? = nil,
        _ mutations: () throws -> Result
    ) throws -> Result {
        guard self.modelContext === modelContext else {
            throw SettingsStoreAtomicBatchError.modelContextMismatch
        }

        if atomicBatchDepth > 0 {
            if let durableRecovery {
                atomicBatchRecoveryActions.append(durableRecovery)
            }
            atomicBatchDepth += 1
            defer { atomicBatchDepth -= 1 }
            do {
                return try mutations()
            } catch {
                recordAtomicBatchFailure(error)
                throw error
            }
        }

        guard !modelContext.hasChanges else {
            throw SettingsStoreAtomicBatchError.pendingModelChanges
        }

        let durableSettings = Dictionary(
            uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<Setting>()).map {
                ($0.key, $0.value)
            }
        )

        let previousAutosaveEnabled = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        atomicBatchDepth = 1
        atomicBatchFailure = nil
        atomicBatchRecoveryActions = durableRecovery.map { [$0] } ?? []
        defer {
            atomicBatchFailure = nil
            atomicBatchRecoveryActions.removeAll()
            atomicBatchDepth = 0
            modelContext.autosaveEnabled = previousAutosaveEnabled
        }

        var result: Result?
        var reachedCommitBoundary = false
        do {
            try modelContext.transaction {
                try Task.checkCancellation()
                result = try mutations()
                if let atomicBatchFailure {
                    throw atomicBatchFailure
                }
                try Task.checkCancellation()
                reachedCommitBoundary = true
            }
        } catch {
            if modelContext.hasChanges {
                modelContext.rollback()
            }
            if reachedCommitBoundary {
                var firstRecoveryError: Error?
                do {
                    try Self.restoreDurableSettings(durableSettings, in: modelContext.container)
                } catch {
                    firstRecoveryError = error
                }
                for recovery in atomicBatchRecoveryActions.reversed() {
                    do {
                        try recovery(modelContext.container)
                    } catch where firstRecoveryError == nil {
                        firstRecoveryError = error
                    } catch {
                        // Continue so every independently recoverable store gets a restoration attempt.
                    }
                }
                if let recoveryError = firstRecoveryError {
                    throw SettingsStoreAtomicRecoveryError(
                        commitError: error,
                        recoveryError: recoveryError
                    )
                }
            }
            throw error
        }
        return result!
    }

    /**
     Restores the complete pre-commit `Setting` generation through a fresh context when needed.

     - Parameters:
       - expectedValues: Exact key/value snapshot captured before the outer atomic batch began.
       - container: Model container spanning the same production configurations.
     - Side Effects: When durable settings differ, replaces every `Setting` row and saves only the
       local settings configuration through a fresh context.
     - Failure modes: Rethrows fetch or save failures. No save occurs when the durable generation
       already equals `expectedValues`, including when the settings store was the failed store.
     */
    private static func restoreDurableSettings(
        _ expectedValues: [String: String],
        in container: ModelContainer
    ) throws {
        let recoveryContext = ModelContext(container)
        recoveryContext.autosaveEnabled = false
        let currentSettings = try recoveryContext.fetch(FetchDescriptor<Setting>())
        let currentValues = Dictionary(
            uniqueKeysWithValues: currentSettings.map { ($0.key, $0.value) }
        )
        guard currentValues != expectedValues else {
            return
        }

        for setting in currentSettings {
            recoveryContext.delete(setting)
        }
        for (key, value) in expectedValues.sorted(by: { $0.key < $1.key }) {
            recoveryContext.insert(Setting(key: key, value: value))
        }
        try recoveryContext.save()
    }

    /**
     Performs an atomic batch against the exact context owned by this settings store.

     Settings-only sync categories do not otherwise carry a `ModelContext` through their public
     APIs. This convenience preserves the same clean-context, nested-batch, cancellation, one-save,
     and rollback contract as `performAtomicBatch(in:_:)` without exposing the private context.

     - Parameter mutations: Synchronous settings mutations that must commit or roll back together.
     - Returns: Value returned by `mutations` after the transaction commits.
     - Side Effects: Delegates autosave suppression, deferred nested saves, one commit, and rollback
       to `performAtomicBatch(in:_:)` using this store's context.
     - Throws: Rethrows pending-change, cancellation, mutation, strict fetch, and commit errors.
     */
    public func performAtomicBatch<Result>(
        _ mutations: () throws -> Result
    ) throws -> Result {
        try performAtomicBatch(in: modelContext, mutations)
    }

    /**
     Commits already-staged graph mutations and their remote-sync journal rows as one save boundary.

     Database stores call this after mutating their graph but before saving. Unlike
     `performAtomicBatch(in:_:)`, this boundary intentionally accepts pending model changes owned by
     the caller. Settings writes performed by `mutations` defer their normal eager saves, and the
     shared context transaction commits the graph and journal together. Existing atomic restore
     scopes absorb nested calls without starting another transaction.

     - Parameters:
       - modelContext: Exact context used to construct this settings store and stage the graph change.
       - mutations: Journal and bookkeeping mutations that must accompany the staged graph change.
     - Returns: Value returned by `mutations` after the transaction commits.
     - Side Effects:
       - temporarily disables autosave for the outermost boundary
       - defers ordinary `SettingsStore` saves while journal rows are staged
       - commits pending graph and settings mutations through one `ModelContext.transaction`
       - rolls back all pending context changes when validation or commit fails
     - Throws:
       - `SettingsStoreAtomicBatchError.modelContextMismatch` for a different context
       - `CancellationError` when cancellation is observed before commit
       - any error thrown by `mutations`, a strict settings read, or the transaction commit
     - Important: The caller must own every pending mutation in `modelContext`; rollback affects the
       complete unsaved context generation.
     */
    func performJournaledSave<Result>(
        in modelContext: ModelContext,
        _ mutations: () throws -> Result
    ) throws -> Result {
        guard self.modelContext === modelContext else {
            throw SettingsStoreAtomicBatchError.modelContextMismatch
        }

        if atomicBatchDepth > 0 {
            do {
                return try mutations()
            } catch {
                recordAtomicBatchFailure(error)
                throw error
            }
        }

        let previousAutosaveEnabled = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        atomicBatchDepth = 1
        atomicBatchFailure = nil
        defer {
            atomicBatchFailure = nil
            atomicBatchDepth = 0
            modelContext.autosaveEnabled = previousAutosaveEnabled
        }

        var result: Result?
        do {
            try modelContext.transaction {
                try Task.checkCancellation()
                result = try mutations()
                if let atomicBatchFailure {
                    throw atomicBatchFailure
                }
                try Task.checkCancellation()
            }
        } catch {
            if modelContext.hasChanges {
                modelContext.rollback()
            }
            throw error
        }
        return result!
    }

    /**
     Commits settings-backed mutations and their remote-sync journal through the owned context.

     - Parameter mutations: Settings and journal writes that form one local mutation generation.
     - Returns: Value returned by `mutations` after commit.
     - Side Effects: Delegates save deferral, transaction commit, and rollback to the context-taking
       overload.
     - Throws: Rethrows cancellation, mutation, strict-read, and persistence failures.
     */
    func performJournaledSave<Result>(
        _ mutations: () throws -> Result
    ) throws -> Result {
        try performJournaledSave(in: modelContext, mutations)
    }

    /// Local-only singleton setting key used for Android-style global text-display defaults.
    public static let globalTextDisplaySettingsKey = "global_text_display_settings"

    // MARK: - String

    /**
     * Reads a raw string setting from SwiftData.
     * - Parameter key: Persisted setting key.
     * - Returns: Stored string value, or `nil` when the key does not exist or the fetch fails.
     * - Note: This method has no side effects and does not consult `UserDefaults`.
     */
    public func getString(_ key: String) -> String? {
        fetchSetting(key)?.value
    }

    /**
     * Writes a raw string setting to SwiftData.
     * - Parameters:
     *   - key: Persisted setting key.
     *   - value: New string value.
     * - Side Effects: Inserts or updates a `Setting` row and saves the supplied `ModelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func setString(_ key: String, value: String) {
        upsert(key: key, value: value)
    }

    // MARK: - Global Text Display Settings

    /**
     Reads the persisted app-level text-display defaults when present.

     - Returns: Decoded global settings, or `nil` when the setting has never been saved or cannot
       be decoded.
     - Note: Callers that need an effective fallback should use `globalTextDisplaySettings()`.
     */
    public func storedGlobalTextDisplaySettings() -> TextDisplaySettings? {
        guard let rawValue = getString(Self.globalTextDisplaySettingsKey),
              let data = rawValue.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(TextDisplaySettings.self, from: data)
    }

    /**
     Reads app-level text-display defaults, falling back to bundled defaults on first launch.

     - Returns: Persisted global settings when available, otherwise `TextDisplaySettings.appDefaults`.
     */
    public func globalTextDisplaySettings() -> TextDisplaySettings {
        storedGlobalTextDisplaySettings() ?? .appDefaults
    }

    /**
     Persists app-level text-display defaults.

     - Parameter settings: Fully or partially populated text-display defaults to store.
     - Side Effects:
       - encodes the settings as JSON and upserts the local singleton `Setting` row
       - clears workspace/window overrides that now match the new effective parent values so they
         inherit instead, mirroring Android's parent-setting propagation
     - Failure: Encoding failures are swallowed, matching the soft-failure behavior of other
       settings writes.
     */
    public func setGlobalTextDisplaySettings(_ settings: TextDisplaySettings) {
        let previousSettings = globalTextDisplaySettings()
        guard let data = try? JSONEncoder().encode(settings),
              let rawValue = String(data: data, encoding: .utf8) else {
            return
        }
        try? performJournaledSave {
            setString(Self.globalTextDisplaySettingsKey, value: rawValue)
            propagateGlobalTextDisplaySettingsChange(from: previousSettings, to: settings)
            try RemoteSyncMutationJournalService().recordLocalChanges(
                for: .workspaces,
                modelContext: modelContext,
                settingsStore: self
            )
        }
    }

    // MARK: - Bool

    /**
     * Reads a boolean setting from SwiftData using `"true"`/`"false"` storage.
     * - Parameters:
     *   - key: Persisted setting key.
     *   - defaultValue: Fallback when the key is absent or malformed.
     * - Returns: Decoded boolean value.
     * - Note: Any stored value other than the literal string `"true"` is treated as `false`.
     */
    public func getBool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let str = getString(key) else { return defaultValue }
        return str == "true"
    }

    /**
     * Writes a boolean setting to SwiftData using `"true"`/`"false"` storage.
     * - Parameters:
     *   - key: Persisted setting key.
     *   - value: Boolean value to store.
     * - Side Effects: Mutates SwiftData through `upsert(key:value:)`.
     * - Failure: Save errors are swallowed.
     */
    public func setBool(_ key: String, value: Bool) {
        upsert(key: key, value: value ? "true" : "false")
    }

    // MARK: - Int

    /**
     * Reads an integer setting from SwiftData.
     * - Parameters:
     *   - key: Persisted setting key.
     *   - defaultValue: Fallback when the key is absent or malformed.
     * - Returns: Decoded integer value.
     * - Note: Non-integer payloads fall back to `defaultValue` rather than throwing.
     */
    public func getInt(_ key: String, default defaultValue: Int = 0) -> Int {
        guard let str = getString(key) else { return defaultValue }
        return Int(str) ?? defaultValue
    }

    /**
     * Writes an integer setting to SwiftData.
     * - Parameters:
     *   - key: Persisted setting key.
     *   - value: Integer value to store.
     * - Side Effects: Mutates SwiftData through `upsert(key:value:)`.
     * - Failure: Save errors are swallowed.
     */
    public func setInt(_ key: String, value: Int) {
        upsert(key: key, value: String(value))
    }

    // MARK: - Double

    /**
     * Reads a double setting from SwiftData.
     * - Parameters:
     *   - key: Persisted setting key.
     *   - defaultValue: Fallback when the key is absent or malformed.
     * - Returns: Decoded double value.
     * - Note: Non-numeric payloads fall back to `defaultValue` rather than throwing.
     */
    public func getDouble(_ key: String, default defaultValue: Double = 0.0) -> Double {
        guard let str = getString(key) else { return defaultValue }
        return Double(str) ?? defaultValue
    }

    /**
     * Writes a double setting to SwiftData.
     * - Parameters:
     *   - key: Persisted setting key.
     *   - value: Double value to store.
     * - Side Effects: Mutates SwiftData through `upsert(key:value:)`.
     * - Failure: Save errors are swallowed.
     */
    public func setDouble(_ key: String, value: Double) {
        upsert(key: key, value: String(value))
    }

    /**
     Removes a persisted setting row when present.
     * - Parameter key: Unique setting key to delete.
     * - Side Effects: Deletes the matching `Setting` row and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    public func remove(_ key: String) {
        guard let existing = fetchSetting(key) else {
            return
        }
        modelContext.delete(existing)
        saveSoftlyUnlessBatching()
    }

    /**
     Reads all persisted settings whose keys start with the supplied prefix.
     * - Parameter prefix: Leading key prefix to match.
     * - Returns: Matching `Setting` rows, filtered in memory when the fetch succeeds.
     * - Note: This fetches all `Setting` rows first because the table is small and this avoids
     *   relying on string-prefix support inside SwiftData predicates.
     * - Failure: Fetch errors are swallowed and reported as an empty array.
     */
    public func entries(withPrefix prefix: String) -> [Setting] {
        let descriptor = FetchDescriptor<Setting>()
        do {
            return try modelContext.fetch(descriptor).filter { $0.key.hasPrefix(prefix) }
        } catch {
            recordAtomicBatchFailure(error)
            return []
        }
    }

    // MARK: - Active Workspace

    /**
     * Key for the currently active workspace ID.
     *
     * This entry lives in the same local-only settings table as other global preferences so the
     * app can restore the previously focused workspace on next launch.
     */
    public static let activeWorkspaceKey = "active_workspace_id"

    /**
     * Gets or sets the active workspace UUID stored in the global settings table.
     *
     * Reads decode the raw string as a UUID. Writes store an empty string when clearing the value.
     * - Side Effects: Setting this property writes through `setString(_:value:)`.
     * - Failure: Invalid stored UUID strings read back as `nil`; save errors on write are swallowed.
     */
    public var activeWorkspaceId: UUID? {
        get { getString(SettingsStore.activeWorkspaceKey).flatMap(UUID.init) }
        set { setString(SettingsStore.activeWorkspaceKey, value: newValue?.uuidString ?? "") }
    }

    // MARK: - Private

    /**
     * Fetches at most one `Setting` row for the given key.
     * - Parameter key: Unique setting key.
     * - Returns: The stored row when present, otherwise `nil`.
     * - Failure: Fetch errors are swallowed and reported as `nil`.
     */
    private func fetchSetting(_ key: String) -> Setting? {
        var descriptor = FetchDescriptor<Setting>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            recordAtomicBatchFailure(error)
            return nil
        }
    }

    /**
     * Inserts or updates a raw `Setting` row and saves the context immediately.
     * - Parameters:
     *   - key: Unique setting key.
     *   - value: Raw string payload to persist.
     * - Side Effects: Mutates SwiftData and saves `modelContext`.
     * - Failure: Save errors are swallowed.
     */
    private func upsert(key: String, value: String) {
        if let existing = fetchSetting(key) {
            existing.value = value
        } else {
            modelContext.insert(Setting(key: key, value: value))
        }
        saveSoftlyUnlessBatching()
    }

    /**
     Saves ordinary settings mutations immediately unless an explicit atomic batch owns the commit.

     - Side Effects: Calls `modelContext.save()` only when no atomic batch is active.
     - Failure modes: Save errors remain intentionally swallowed for ordinary settings flows; the
       explicit batch performs its own throwing transaction commit after all nested mutations finish.
     */
    private func saveSoftlyUnlessBatching() {
        guard atomicBatchDepth == 0 else {
            return
        }
        try? modelContext.save()
    }

    /**
     Records the first otherwise-soft settings failure for the active atomic batch.

     - Parameter error: Fetch or nested-batch error that must invalidate the outer batch.
     - Side Effects: Stores the first error while an atomic scope is active.
     - Failure modes: Outside an atomic scope this remains a no-op, preserving ordinary soft reads.
     */
    private func recordAtomicBatchFailure(_ error: Error) {
        guard atomicBatchDepth > 0, atomicBatchFailure == nil else {
            return
        }
        atomicBatchFailure = error
    }

    /**
     Clears redundant workspace and window overrides after a global-settings change.

     Android nulls child values that now match their effective parent so future parent changes keep
     flowing through the inheritance chain. iOS needs the same cleanup to avoid stale workspace or
     page-manager overrides after application Settings edits.
     */
    private func propagateGlobalTextDisplaySettingsChange(
        from previousSettings: TextDisplaySettings,
        to globalSettings: TextDisplaySettings
    ) {
        guard previousSettings != globalSettings else {
            return
        }

        let descriptor = FetchDescriptor<Workspace>()
        let workspaces: [Workspace]
        do {
            workspaces = try modelContext.fetch(descriptor)
        } catch {
            recordAtomicBatchFailure(error)
            return
        }
        var anyChanged = false

        for workspace in workspaces {
            let previousWorkspaceSettings = workspace.textDisplaySettings
            if var workspaceSettings = previousWorkspaceSettings,
               workspaceSettings.clearOverridesMatchingParent(
                   globalSettings,
                   changedFrom: previousSettings,
                   to: globalSettings
               ) {
                workspace.textDisplaySettings = workspaceSettings
                anyChanged = true
            }

            let currentWorkspaceParentSettings = TextDisplaySettings.fullyResolved(
                window: nil,
                workspace: workspace.textDisplaySettings,
                global: globalSettings
            )
            for window in workspace.windows ?? [] {
                guard var windowSettings = window.pageManager?.textDisplaySettings else {
                    continue
                }
                if windowSettings.clearOverridesMatchingParent(
                    currentWorkspaceParentSettings,
                    changedFrom: previousSettings,
                    to: globalSettings
                ) {
                    window.pageManager?.textDisplaySettings = windowSettings
                    anyChanged = true
                }
            }
        }

        if anyChanged {
            saveSoftlyUnlessBatching()
        }
    }
}

/**
 * Adds Android parity preference accessors that route storage through the backend declared in
 * `AppPreferenceRegistry`.
 *
 * The extension preserves Android defaults when no value has been persisted yet and deliberately
 * treats `.action` preferences as non-durable: reads return defaults and writes are ignored.
 */
// MARK: - AppPreferenceKey Accessors

public extension SettingsStore {
    /**
     * Reads a parity preference as a string from its configured storage backend.
     * - Parameter key: Android parity preference key.
     * - Returns: Stored value or the registry default when no value has been persisted.
     * - Side Effects: May read from SwiftData or `UserDefaults` depending on registry metadata.
     * - Failure: Missing or malformed values fall back to the registry default or an empty string.
     */
    func getString(_ key: AppPreferenceKey) -> String {
        if let stored = readStoredValue(for: key) {
            return stored
        }
        return AppPreferenceRegistry.stringDefault(for: key) ?? ""
    }

    /**
     * Writes a parity preference string to its configured storage backend.
     * - Parameters:
     *   - key: Android parity preference key.
     *   - value: New string value.
     * - Side Effects: Writes to SwiftData or `UserDefaults` according to the registry definition.
     * - Failure: SwiftData save errors are swallowed; `.action` preferences intentionally no-op.
     */
    func setString(_ key: AppPreferenceKey, value: String) {
        let definition = AppPreferenceRegistry.definition(for: key)
        switch definition.storage {
        case .swiftData:
            setString(key.rawValue, value: value)
        case .userDefaults:
            UserDefaults.standard.set(value, forKey: key.rawValue)
        case .action:
            break
        }
    }

    /**
     * Reads a parity preference as a boolean from its configured storage backend.
     * - Parameter key: Android parity preference key.
     * - Returns: Stored or default boolean value.
     * - Side Effects: May read from SwiftData or `UserDefaults`.
     * - Failure: Missing or non-boolean payloads fall back to the registry default.
     */
    func getBool(_ key: AppPreferenceKey) -> Bool {
        let fallback = AppPreferenceRegistry.boolDefault(for: key) ?? false
        let definition = AppPreferenceRegistry.definition(for: key)

        switch definition.storage {
        case .swiftData:
            guard let raw = getString(key.rawValue) else { return fallback }
            return raw == "true"
        case .userDefaults:
            if let boolValue = UserDefaults.standard.object(forKey: key.rawValue) as? Bool {
                return boolValue
            }
            if let raw = UserDefaults.standard.string(forKey: key.rawValue) {
                return raw == "true"
            }
            return fallback
        case .action:
            return fallback
        }
    }

    /**
     * Writes a parity preference boolean to its configured storage backend.
     * - Parameters:
     *   - key: Android parity preference key.
     *   - value: New boolean value.
     * - Side Effects: Writes to SwiftData or `UserDefaults` according to the registry definition.
     * - Failure: SwiftData save errors are swallowed; `.action` preferences intentionally no-op.
     */
    func setBool(_ key: AppPreferenceKey, value: Bool) {
        let definition = AppPreferenceRegistry.definition(for: key)
        switch definition.storage {
        case .swiftData:
            setString(key.rawValue, value: value ? "true" : "false")
        case .userDefaults:
            UserDefaults.standard.set(value, forKey: key.rawValue)
        case .action:
            break
        }
    }

    /**
     * Reads a parity preference as an integer from its configured storage backend.
     * - Parameter key: Android parity preference key.
     * - Returns: Stored or default integer value.
     * - Side Effects: May read from SwiftData or `UserDefaults`.
     * - Failure: Missing or malformed payloads fall back to the registry default.
     */
    func getInt(_ key: AppPreferenceKey) -> Int {
        let fallback = AppPreferenceRegistry.intDefault(for: key) ?? 0
        let definition = AppPreferenceRegistry.definition(for: key)

        switch definition.storage {
        case .swiftData:
            guard let raw = getString(key.rawValue) else { return fallback }
            return Int(raw) ?? fallback
        case .userDefaults:
            let object = UserDefaults.standard.object(forKey: key.rawValue)
            if let intValue = object as? Int {
                return intValue
            }
            if let stringValue = object as? String {
                return Int(stringValue) ?? fallback
            }
            return fallback
        case .action:
            return fallback
        }
    }

    /**
     * Writes a parity preference integer to its configured storage backend.
     * - Parameters:
     *   - key: Android parity preference key.
     *   - value: New integer value.
     * - Side Effects: Writes to SwiftData or `UserDefaults` according to the registry definition.
     * - Failure: SwiftData save errors are swallowed; `.action` preferences intentionally no-op.
     */
    func setInt(_ key: AppPreferenceKey, value: Int) {
        let definition = AppPreferenceRegistry.definition(for: key)
        switch definition.storage {
        case .swiftData:
            setString(key.rawValue, value: String(value))
        case .userDefaults:
            UserDefaults.standard.set(value, forKey: key.rawValue)
        case .action:
            break
        }
    }

    /**
     * Reads a parity preference string set from its configured storage backend.
     * - Parameter key: Android parity preference key.
     * - Returns: Stored values decoded from CSV or array form.
     * - Side Effects: May read from SwiftData or `UserDefaults`.
     * - Failure: Missing values decode as an empty array. Malformed CSV tokens are trimmed and
     *   empty members are dropped.
     */
    func getStringSet(_ key: AppPreferenceKey) -> [String] {
        let definition = AppPreferenceRegistry.definition(for: key)
        switch definition.storage {
        case .swiftData:
            let raw = getString(key.rawValue)
            return AppPreferenceRegistry.decodeCSVSet(raw)
        case .userDefaults:
            if let values = UserDefaults.standard.array(forKey: key.rawValue) as? [String] {
                return values
            }
            let raw = UserDefaults.standard.string(forKey: key.rawValue)
            return AppPreferenceRegistry.decodeCSVSet(raw)
        case .action:
            return []
        }
    }

    /**
     * Writes a parity preference string set to its configured storage backend.
     * - Parameters:
     *   - key: Android parity preference key.
     *   - values: Values to encode and persist.
     * - Side Effects: Persists sorted values to SwiftData or `UserDefaults` according to the
     *   registry definition.
     * - Failure: SwiftData save errors are swallowed; `.action` preferences intentionally no-op.
     * - Note: SwiftData storage uses CSV encoding, while `UserDefaults` storage uses a sorted
     *   string array for easier inspection.
     */
    func setStringSet(_ key: AppPreferenceKey, values: [String]) {
        let encoded = AppPreferenceRegistry.encodeCSVSet(values)
        let definition = AppPreferenceRegistry.definition(for: key)
        switch definition.storage {
        case .swiftData:
            setString(key.rawValue, value: encoded)
        case .userDefaults:
            UserDefaults.standard.set(values.sorted(), forKey: key.rawValue)
        case .action:
            break
        }
    }

    /**
     Clears the preferences in Android's explicit Settings reset allowlist back to registry defaults.

     Reset is expressed as removal rather than writing default values so future registry default
     changes are picked up consistently. The key list lives in
     `AppPreferenceRegistry.applicationPreferencesResetKeys`; UI placement and registry membership
     do not expand Android's intentionally narrower reset contract.

     - Side Effects:
       - deletes SwiftData `Setting` rows for resettable `.swiftData` preferences
       - removes `UserDefaults` objects for resettable `.userDefaults` preferences
       - preserves registered values outside Android's reset allowlist and unrelated settings,
         including global text display JSON
     - Failure: SwiftData save failures are swallowed by `remove(_:)`, matching other settings
       writes in this store.
     */
    func resetApplicationPreferences() {
        removeApplicationPreferences(AppPreferenceRegistry.applicationPreferencesResetKeys)
    }

    /**
     Clears every registered persisted application preference before destructive backup restore.

     Android database restore replaces the Settings database rather than invoking the narrower
     user-facing Settings reset action. This method preserves that replacement boundary by clearing
     all registered non-action values, including preferences that the Settings reset allowlist keeps.

     - Side Effects:
       - deletes registered SwiftData-backed preference rows
       - removes registered `UserDefaults`-backed preference values
       - leaves action definitions and unrelated settings intact
     - Failure: SwiftData save failures are swallowed by `remove(_:)`, matching other settings
       writes in this store.
     */
    func clearRegisteredApplicationPreferences() {
        removeApplicationPreferences(AppPreferenceRegistry.persistedPreferenceKeys)
    }

    /**
     Removes the supplied registered preference keys from their configured storage backends.

     - Parameter keys: Registered persisted preference keys to remove.
     - Side Effects: Mutates SwiftData and `UserDefaults` according to registry storage metadata.
     - Failure: Action keys are ignored; SwiftData save failures are swallowed by `remove(_:)`.
     */
    private func removeApplicationPreferences(_ keys: [AppPreferenceKey]) {
        for key in keys {
            let definition = AppPreferenceRegistry.definition(for: key)
            switch definition.storage {
            case .swiftData:
                remove(key.rawValue)
            case .userDefaults:
                UserDefaults.standard.removeObject(forKey: key.rawValue)
            case .action:
                break
            }
        }
    }

    /**
     * Reads a parity preference as a raw string regardless of the configured storage backend.
     * - Parameter key: Android parity preference key.
     * - Returns: Raw stored representation, or `nil` when absent or when the preference is an action.
     * - Side Effects: Reads from SwiftData or `UserDefaults`.
     * - Failure: Unsupported or missing stored types are treated as `nil`.
     */
    private func readStoredValue(for key: AppPreferenceKey) -> String? {
        let definition = AppPreferenceRegistry.definition(for: key)
        switch definition.storage {
        case .swiftData:
            return getString(key.rawValue)
        case .userDefaults:
            let object = UserDefaults.standard.object(forKey: key.rawValue)
            if let boolValue = object as? Bool {
                return boolValue ? "true" : "false"
            }
            if let intValue = object as? Int {
                return String(intValue)
            }
            return object as? String
        case .action:
            return nil
        }
    }
}
