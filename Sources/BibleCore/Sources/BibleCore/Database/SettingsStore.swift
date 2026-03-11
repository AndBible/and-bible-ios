// SettingsStore.swift — App-level settings persistence

import Foundation
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
 * Manages app-level key-value settings stored in `LocalStore`.
 *
 * This store owns two related responsibilities:
 * - persist global local-only settings such as the active workspace ID
 * - route Android parity preferences to either SwiftData, `UserDefaults`, or no-op action storage
 *
 * Reading-display inheritance is intentionally outside this store. That chain is resolved through:
 * `PageManager.textDisplaySettings` -> `Workspace.textDisplaySettings` ->
 * `TextDisplaySettings.appDefaults`.
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
 *
 * - Important: `SettingsStore` is only as thread-safe as the supplied `ModelContext`.
 *   Callers must respect SwiftData context confinement and avoid cross-thread mutation.
 */
@Observable
public final class SettingsStore {
    /// SwiftData context used for all `Setting` reads and writes that target the local store.
    private let modelContext: ModelContext

    /**
     * Creates a settings store bound to the caller's SwiftData context.
     * - Parameter modelContext: Context used for `Setting` persistence.
     * - Important: The caller owns the lifecycle and actor/thread confinement of this context.
     */
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

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
        try? modelContext.save()
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
        return (try? modelContext.fetch(descriptor).filter { $0.key.hasPrefix(prefix) }) ?? []
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
        return try? modelContext.fetch(descriptor).first
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
        try? modelContext.save()
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
