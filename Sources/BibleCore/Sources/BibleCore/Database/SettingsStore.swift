// SettingsStore.swift — App-level settings persistence

import Foundation
import SwiftData

/// A key-value setting stored in the database.
@Model
public final class Setting {
    @Attribute(.unique) public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Manages app-level key-value settings.
@Observable
public final class SettingsStore {
    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - String

    public func getString(_ key: String) -> String? {
        fetchSetting(key)?.value
    }

    public func setString(_ key: String, value: String) {
        upsert(key: key, value: value)
    }

    // MARK: - Bool

    public func getBool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let str = getString(key) else { return defaultValue }
        return str == "true"
    }

    public func setBool(_ key: String, value: Bool) {
        upsert(key: key, value: value ? "true" : "false")
    }

    // MARK: - Int

    public func getInt(_ key: String, default defaultValue: Int = 0) -> Int {
        guard let str = getString(key) else { return defaultValue }
        return Int(str) ?? defaultValue
    }

    public func setInt(_ key: String, value: Int) {
        upsert(key: key, value: String(value))
    }

    // MARK: - Double

    public func getDouble(_ key: String, default defaultValue: Double = 0.0) -> Double {
        guard let str = getString(key) else { return defaultValue }
        return Double(str) ?? defaultValue
    }

    public func setDouble(_ key: String, value: Double) {
        upsert(key: key, value: String(value))
    }

    // MARK: - Active Workspace

    /// Key for the currently active workspace ID.
    public static let activeWorkspaceKey = "active_workspace_id"

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
