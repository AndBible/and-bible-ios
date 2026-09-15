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

    /// A journal-owned boundary cannot accept durable recovery registered by an atomic child.
    case nestedDurableRecoveryRequiresAtomicOwner
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
 Owns one synchronous settings persistence boundary for an exact SwiftData context.

 The owner contains only call-stack-local transaction state. `SettingsStoreAtomicScope` retains it
 for the duration of the synchronous mutation closure so separately constructed facades on the same
 context defer saves, report handled failures, and register successful publications with one owner.
 */
private final class SettingsStoreAtomicOwner: NSObject {
    enum Kind {
        case atomicRestore
        case journaledSave
    }

    let modelContext: ModelContext
    let kind: Kind
    var firstFailure: Error?
    var recoveryActions: [(ModelContainer) throws -> Void]
    var successfulCommitActions: [() -> Void]

    init(
        modelContext: ModelContext,
        kind: Kind,
        recoveryActions: [(ModelContainer) throws -> Void] = [],
        successfulCommitActions: [() -> Void] = []
    ) {
        self.modelContext = modelContext
        self.kind = kind
        self.recoveryActions = recoveryActions
        self.successfulCommitActions = successfulCommitActions
    }

    func recordFailure(_ error: Error) {
        if firstFailure == nil {
            firstFailure = error
        }
    }
}

/**
 Tracks nested synchronous persistence owners on the current thread.

 The public batch closures cannot suspend and every participating `SettingsStore` inherits the
 supplied `ModelContext`'s thread confinement. A stack therefore makes ownership context-wide for
 the complete synchronous call tree without a process-global context registry. Searching ancestors
 preserves an outer A-context owner across a nested B-context operation. The entry is removed with
 `defer` before any success publication runs, so later or reentrant work starts a new boundary.

 This mechanism must be replaced by explicit ownership propagation before a persistence mutation
 closure becomes asynchronous or permits its context to cross threads.
 */
private enum SettingsStoreAtomicScope {
    private static let threadDictionaryKey =
        "org.andbible.ios.SettingsStoreAtomicScope.ownerStack"

    private final class Stack: NSObject {
        var owners: [SettingsStoreAtomicOwner] = []
    }

    static func owner(for modelContext: ModelContext) -> SettingsStoreAtomicOwner? {
        guard let stack = Thread.current.threadDictionary[threadDictionaryKey] as? Stack else {
            return nil
        }
        return stack.owners.reversed().first { $0.modelContext === modelContext }
    }

    static func withOwner<Result>(
        _ owner: SettingsStoreAtomicOwner,
        _ operation: () throws -> Result
    ) rethrows -> Result {
        let dictionary = Thread.current.threadDictionary
        let stack: Stack
        if let existing = dictionary[threadDictionaryKey] as? Stack {
            stack = existing
        } else {
            stack = Stack()
            dictionary[threadDictionaryKey] = stack
        }
        stack.owners.append(owner)
        defer {
            precondition(stack.owners.last === owner)
            stack.owners.removeLast()
            if stack.owners.isEmpty {
                dictionary.removeObject(forKey: threadDictionaryKey)
            }
        }
        return try operation()
    }
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
     `ModelContext.transaction(block:)`. Nested calls through any `SettingsStore` facade on the exact
     context join the outer synchronous scope and register their durable recovery actions with that
     commit owner; a nested error marks the whole outer batch failed even if an intermediate caller
     catches it.

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
       - afterSuccessfulCommit: Optional nonthrowing publication registered with this batch. Nested
         publications join the outer owner and run only after its complete transaction succeeds.
       - mutations: Synchronous mutations whose SwiftData effects must commit or roll back together.
     - Returns: Value returned by `mutations` after the primary save succeeds.
     - Side Effects:
       - temporarily disables autosave on the shared context for the outermost scope
       - defers nested `SettingsStore` SwiftData saves
       - commits the shared context exactly once on success through SwiftData's native transaction
       - rolls back pending state on mutation, cancellation, fetch, or commit failure
       - restores pre-commit settings and attempts every registered graph recovery after a partial
         store commit; graph recoveries run in reverse registration order
       - invokes registered success publications in registration order after resetting batch state
     - Throws:
       - `SettingsStoreAtomicBatchError.modelContextMismatch` when contexts differ
       - `SettingsStoreAtomicBatchError.pendingModelChanges` when the outer context is not clean
       - `CancellationError` when the current task is cancelled before the final save
       - any error thrown by `mutations`, a strict in-batch settings fetch, or transaction commit
       - `SettingsStoreAtomicRecoveryError` when durable recovery fails after a commit error
     - Important: This method is synchronous and inherits `ModelContext` confinement. A caller must
       not mutate or save any participating configuration from another context until this method
       returns; durable compensation restores whole generations and would overwrite such writes.
       Facade-wide ownership relies on this closure remaining synchronous and on the context staying
       on its current thread for the complete call tree.
     */
    public func performAtomicBatch<Result>(
        in modelContext: ModelContext,
        durableRecovery: ((ModelContainer) throws -> Void)? = nil,
        afterSuccessfulCommit: (() -> Void)? = nil,
        _ mutations: () throws -> Result
    ) throws -> Result {
        guard self.modelContext === modelContext else {
            throw SettingsStoreAtomicBatchError.modelContextMismatch
        }

        if let owner = SettingsStoreAtomicScope.owner(for: modelContext) {
            if let durableRecovery {
                guard owner.kind == .atomicRestore else {
                    let error = SettingsStoreAtomicBatchError
                        .nestedDurableRecoveryRequiresAtomicOwner
                    owner.recordFailure(error)
                    throw error
                }
                owner.recoveryActions.append(durableRecovery)
            }
            if let afterSuccessfulCommit {
                owner.successfulCommitActions.append(afterSuccessfulCommit)
            }
            do {
                return try mutations()
            } catch {
                owner.recordFailure(error)
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
        let owner = SettingsStoreAtomicOwner(
            modelContext: modelContext,
            kind: .atomicRestore,
            recoveryActions: durableRecovery.map { [$0] } ?? [],
            successfulCommitActions: afterSuccessfulCommit.map { [$0] } ?? []
        )
        let previousAutosaveEnabled = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        var didRestoreAutosave = false
        defer {
            if !didRestoreAutosave {
                modelContext.autosaveEnabled = previousAutosaveEnabled
            }
        }

        var result: Result?
        var reachedCommitBoundary = false
        do {
            try SettingsStoreAtomicScope.withOwner(owner) {
                try modelContext.transaction {
                    try Task.checkCancellation()
                    result = try mutations()
                    if let failure = owner.firstFailure {
                        throw failure
                    }
                    try Task.checkCancellation()
                    reachedCommitBoundary = true
                }
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
                for recovery in owner.recoveryActions.reversed() {
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
        modelContext.autosaveEnabled = previousAutosaveEnabled
        didRestoreAutosave = true
        for action in owner.successfulCommitActions {
            action()
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

     - Parameters:
       - afterSuccessfulCommit: Optional nonthrowing publication invoked after the outermost batch
         commits and resets its ownership state.
       - mutations: Synchronous settings mutations that must commit or roll back together.
     - Returns: Value returned by `mutations` after the transaction commits.
     - Side Effects: Delegates autosave suppression, deferred nested saves, one commit, and rollback
       to `performAtomicBatch(in:_:)` using this store's context.
     - Throws: Rethrows pending-change, cancellation, mutation, strict fetch, and commit errors.
     */
    public func performAtomicBatch<Result>(
        afterSuccessfulCommit: (() -> Void)? = nil,
        _ mutations: () throws -> Result
    ) throws -> Result {
        try performAtomicBatch(
            in: modelContext,
            afterSuccessfulCommit: afterSuccessfulCommit,
            mutations
        )
    }

    /**
     Commits already-staged graph mutations and their remote-sync journal rows as one save boundary.

     Database stores call this after mutating their graph but before saving. Unlike
     `performAtomicBatch(in:_:)`, this boundary intentionally accepts pending model changes owned by
     the caller. Settings writes performed by `mutations` defer their normal eager saves, and the
     shared context transaction commits the graph and journal together. Existing scopes on the exact
     context absorb nested calls from every `SettingsStore` facade without starting another
     transaction.

     - Parameters:
       - modelContext: Exact context used to construct this settings store and stage the graph change.
       - afterSuccessfulCommit: Optional nonthrowing publication invoked only after the outermost
         transaction commits and resets its ownership state.
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
       complete unsaved context generation. A nested atomic child may register durable recovery only
       when the outer owner is an atomic restore boundary; a journal owner rejects that unsupported
       composition instead of dropping the recovery action.
     */
    func performJournaledSave<Result>(
        in modelContext: ModelContext,
        afterSuccessfulCommit: (() -> Void)? = nil,
        _ mutations: () throws -> Result
    ) throws -> Result {
        guard self.modelContext === modelContext else {
            throw SettingsStoreAtomicBatchError.modelContextMismatch
        }

        if let owner = SettingsStoreAtomicScope.owner(for: modelContext) {
            if let afterSuccessfulCommit {
                owner.successfulCommitActions.append(afterSuccessfulCommit)
            }
            do {
                return try mutations()
            } catch {
                owner.recordFailure(error)
                throw error
            }
        }

        let owner = SettingsStoreAtomicOwner(
            modelContext: modelContext,
            kind: .journaledSave,
            successfulCommitActions: afterSuccessfulCommit.map { [$0] } ?? []
        )
        let previousAutosaveEnabled = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        var didRestoreAutosave = false
        defer {
            if !didRestoreAutosave {
                modelContext.autosaveEnabled = previousAutosaveEnabled
            }
        }

        var result: Result?
        do {
            try SettingsStoreAtomicScope.withOwner(owner) {
                try modelContext.transaction {
                    try Task.checkCancellation()
                    result = try mutations()
                    if let failure = owner.firstFailure {
                        throw failure
                    }
                    try Task.checkCancellation()
                }
            }
        } catch {
            if modelContext.hasChanges {
                modelContext.rollback()
            }
            throw error
        }
        modelContext.autosaveEnabled = previousAutosaveEnabled
        didRestoreAutosave = true
        for action in owner.successfulCommitActions {
            action()
        }
        return result!
    }

    /**
     Commits settings-backed mutations and their remote-sync journal through the owned context.

     - Parameters:
       - afterSuccessfulCommit: Optional nonthrowing publication invoked after the outermost
         transaction commits and resets its ownership state.
       - mutations: Settings and journal writes that form one local mutation generation.
     - Returns: Value returned by `mutations` after commit.
     - Side Effects: Delegates save deferral, transaction commit, and rollback to the context-taking
       overload.
     - Throws: Rethrows cancellation, mutation, strict-read, and persistence failures.
     */
    func performJournaledSave<Result>(
        afterSuccessfulCommit: (() -> Void)? = nil,
        _ mutations: () throws -> Result
    ) throws -> Result {
        try performJournaledSave(
            in: modelContext,
            afterSuccessfulCommit: afterSuccessfulCommit,
            mutations
        )
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
     Reads persisted settings whose keys have Swift's exact semantic prefix.

     SQLite's binary string ordering can bound ASCII prefixes without materializing unrelated
     settings. The final `hasPrefix` check remains authoritative. Empty and non-ASCII prefixes, plus
     the three ASCII scalars with canonically equivalent non-ASCII spellings, use the complete fetch
     so SQL cannot exclude a key that Swift considers a semantic prefix match.

     - Parameter prefix: Leading key prefix to match using `String.hasPrefix` semantics.
     - Returns: Matching rows. Callers apply their own deterministic ordering.
     - Side effects: Reads the owned `ModelContext` and records an active atomic-batch failure.
     - Failure modes: Fetch errors are swallowed and reported as an empty array, matching the
       existing fail-soft settings reads.
     */
    public func entries(withPrefix prefix: String) -> [Setting] {
        let descriptor: FetchDescriptor<Setting>
        if let bounds = Self.binaryPrefixBounds(for: prefix) {
            let lowerBound = bounds.lowerBound
            let upperBound = bounds.upperBound
            descriptor = FetchDescriptor<Setting>(
                predicate: #Predicate {
                    $0.key >= lowerBound && $0.key < upperBound
                }
            )
        } else {
            descriptor = FetchDescriptor<Setting>()
        }
        do {
            return try modelContext.fetch(descriptor).filter { $0.key.hasPrefix(prefix) }
        } catch {
            recordAtomicBatchFailure(error)
            return []
        }
    }

    /**
     Returns a binary-order range that is a superset of Swift prefix matches for safe ASCII input.

     Swift strings compare canonically equivalent Unicode spellings as equal. Greek question mark,
     Kelvin sign, and Greek varia canonically map to ASCII semicolon, uppercase K, and grave accent,
     respectively. A binary ASCII range would omit those spellings, so prefixes containing any of
     those scalars use the complete-fetch fallback. Non-ASCII input also falls back because this
     helper does not assume a persistence collation can represent Swift's Unicode prefix semantics.

     - Parameter prefix: Candidate semantic prefix.
     - Returns: Half-open binary bounds, or `nil` when only a complete fetch is a proven superset.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func binaryPrefixBounds(
        for prefix: String
    ) -> (lowerBound: String, upperBound: String)? {
        guard !prefix.isEmpty else { return nil }

        for scalar in prefix.unicodeScalars {
            guard scalar.value <= 0x7F else { return nil }
            switch scalar.value {
            case 0x3B, 0x4B, 0x60:
                return nil
            default:
                break
            }
        }

        guard let finalScalar = prefix.unicodeScalars.last,
              let successor = UnicodeScalar(finalScalar.value + 1) else {
            return nil
        }
        return (prefix, String(prefix.unicodeScalars.dropLast()) + String(successor))
    }

    /**
     Reads the rows inside one dot-delimited settings namespace without materializing unrelated
     settings.

     The persisted key range from `namespace + "."` through `namespace + "/"` contains every key
     whose next byte is the namespace delimiter under the store's binary ordering. A final exact
     prefix check keeps the API's semantics explicit even if a future persistence backend uses a
     broader comparison collation.

     - Parameter namespace: Namespace without its trailing dot delimiter.
     - Returns: Matching rows in persistence order. Callers apply their own deterministic ordering.
     - Side effects: Reads the owned local `ModelContext` and records an active atomic-batch failure.
     - Failure modes: Fetch errors are swallowed and reported as an empty array, matching the
       existing fail-soft settings reads.
     */
    func entries(inExactNamespace namespace: String) -> [Setting] {
        let lowerBound = "\(namespace)."
        let upperBound = "\(namespace)/"
        let descriptor = FetchDescriptor<Setting>(
            predicate: #Predicate {
                $0.key >= lowerBound && $0.key < upperBound
            }
        )
        do {
            return try modelContext.fetch(descriptor).filter { $0.key.hasPrefix(lowerBound) }
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
     Saves ordinary settings mutations immediately unless an exact-context synchronous batch owns
     the commit.

     - Side Effects: Calls `modelContext.save()` only when no atomic batch is active.
     - Failure modes: Save errors remain intentionally swallowed for ordinary settings flows; the
       explicit batch performs its own throwing transaction commit after all nested mutations finish.
     */
    private func saveSoftlyUnlessBatching() {
        guard SettingsStoreAtomicScope.owner(for: modelContext) == nil else {
            return
        }
        try? modelContext.save()
    }

    /**
     Records the first otherwise-soft settings failure for the active exact-context batch.

     - Parameter error: Fetch or nested-batch error that must invalidate the outer batch.
     - Side Effects: Stores the first error while an atomic scope is active.
     - Failure modes: Outside an atomic scope this remains a no-op, preserving ordinary soft reads.
     */
    private func recordAtomicBatchFailure(_ error: Error) {
        SettingsStoreAtomicScope.owner(for: modelContext)?.recordFailure(error)
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
