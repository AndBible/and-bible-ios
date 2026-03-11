// SettingsStore.swift — App-level settings persistence

import Foundation
import SwiftData

/// A key-value setting stored in the database.
@Model
public final class Setting {
    /// Unique setting key.
    @Attribute(.unique) public var key: String
    /// Persisted string value.
    public var value: String

    /// Creates a persisted key-value setting row.
    /// - Parameters:
    ///   - key: Unique setting key.
    ///   - value: Persisted string payload.
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Manages app-level key-value settings stored in `LocalStore`.
///
/// This store is for global app preferences and bookkeeping records such as the active workspace.
/// It is intentionally separate from reading display inheritance, which is resolved through
/// `PageManager.textDisplaySettings` -> `Workspace.textDisplaySettings` ->
/// `TextDisplaySettings.appDefaults`.
///
/// For Android parity settings keyed by `AppPreferenceKey`, this store also routes persistence to
/// the correct backend:
/// - `.swiftData`: stored here as string values
/// - `.userDefaults`: stored in `UserDefaults`
/// - `.action`: read as defaults and ignored on write because the preference represents a button
///   rather than durable state
@Observable
public final class SettingsStore {
    private let modelContext: ModelContext

    /// Creates a settings store bound to the caller's SwiftData context.
    /// - Parameter modelContext: Context used for `Setting` persistence.
    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - String

    /// Reads a raw string setting from SwiftData.
    /// - Parameter key: Persisted setting key.
    /// - Returns: Stored string value, or `nil` when absent.
    public func getString(_ key: String) -> String? {
        fetchSetting(key)?.value
    }

    /// Writes a raw string setting to SwiftData.
    /// - Parameters:
    ///   - key: Persisted setting key.
    ///   - value: New string value.
    public func setString(_ key: String, value: String) {
        upsert(key: key, value: value)
    }

    // MARK: - Bool

    /// Reads a boolean setting from SwiftData using `"true"`/`"false"` storage.
    /// - Parameters:
    ///   - key: Persisted setting key.
    ///   - defaultValue: Fallback when the key is absent or malformed.
    /// - Returns: Decoded boolean value.
    public func getBool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let str = getString(key) else { return defaultValue }
        return str == "true"
    }

    /// Writes a boolean setting to SwiftData using `"true"`/`"false"` storage.
    /// - Parameters:
    ///   - key: Persisted setting key.
    ///   - value: Boolean value to store.
    public func setBool(_ key: String, value: Bool) {
        upsert(key: key, value: value ? "true" : "false")
    }

    // MARK: - Int

    /// Reads an integer setting from SwiftData.
    /// - Parameters:
    ///   - key: Persisted setting key.
    ///   - defaultValue: Fallback when the key is absent or malformed.
    /// - Returns: Decoded integer value.
    public func getInt(_ key: String, default defaultValue: Int = 0) -> Int {
        guard let str = getString(key) else { return defaultValue }
        return Int(str) ?? defaultValue
    }

    /// Writes an integer setting to SwiftData.
    /// - Parameters:
    ///   - key: Persisted setting key.
    ///   - value: Integer value to store.
    public func setInt(_ key: String, value: Int) {
        upsert(key: key, value: String(value))
    }

    // MARK: - Double

    /// Reads a double setting from SwiftData.
    /// - Parameters:
    ///   - key: Persisted setting key.
    ///   - defaultValue: Fallback when the key is absent or malformed.
    /// - Returns: Decoded double value.
    public func getDouble(_ key: String, default defaultValue: Double = 0.0) -> Double {
        guard let str = getString(key) else { return defaultValue }
        return Double(str) ?? defaultValue
    }

    /// Writes a double setting to SwiftData.
    /// - Parameters:
    ///   - key: Persisted setting key.
    ///   - value: Double value to store.
    public func setDouble(_ key: String, value: Double) {
        upsert(key: key, value: String(value))
    }

    // MARK: - Active Workspace

    /// Key for the currently active workspace ID.
    public static let activeWorkspaceKey = "active_workspace_id"

    /// Gets or sets the active workspace UUID stored in the global settings table.
    public var activeWorkspaceId: UUID? {
        get { getString(SettingsStore.activeWorkspaceKey).flatMap(UUID.init) }
        set { setString(SettingsStore.activeWorkspaceKey, value: newValue?.uuidString ?? "") }
    }

    // MARK: - Private

    private func fetchSetting(_ key: String) -> Setting? {
        var descriptor = FetchDescriptor<Setting>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func upsert(key: String, value: String) {
        if let existing = fetchSetting(key) {
            existing.value = value
        } else {
            modelContext.insert(Setting(key: key, value: value))
        }
        try? modelContext.save()
    }
}

// MARK: - AppPreferenceKey Accessors

public extension SettingsStore {
    /// Reads a parity preference as a string from its configured storage backend.
    /// - Parameter key: Android parity preference key.
    /// - Returns: Stored value or the registry default when no value has been persisted.
    func getString(_ key: AppPreferenceKey) -> String {
        if let stored = readStoredValue(for: key) {
            return stored
        }
        return AppPreferenceRegistry.stringDefault(for: key) ?? ""
    }

    /// Writes a parity preference string to its configured storage backend.
    /// - Parameters:
    ///   - key: Android parity preference key.
    ///   - value: New string value.
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

    /// Reads a parity preference as a boolean from its configured storage backend.
    /// - Parameter key: Android parity preference key.
    /// - Returns: Stored or default boolean value.
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

    /// Writes a parity preference boolean to its configured storage backend.
    /// - Parameters:
    ///   - key: Android parity preference key.
    ///   - value: New boolean value.
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

    /// Reads a parity preference as an integer from its configured storage backend.
    /// - Parameter key: Android parity preference key.
    /// - Returns: Stored or default integer value.
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

    /// Writes a parity preference integer to its configured storage backend.
    /// - Parameters:
    ///   - key: Android parity preference key.
    ///   - value: New integer value.
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

    /// Reads a parity preference string set from its configured storage backend.
    /// - Parameter key: Android parity preference key.
    /// - Returns: Stored values decoded from CSV or array form.
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

    /// Writes a parity preference string set to its configured storage backend.
    /// - Parameters:
    ///   - key: Android parity preference key.
    ///   - values: Values to encode and persist.
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
