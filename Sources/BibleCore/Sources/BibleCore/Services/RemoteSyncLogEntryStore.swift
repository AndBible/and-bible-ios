// RemoteSyncLogEntryStore.swift — Local preservation of Android LogEntry sync metadata

import Foundation

/**
Represents one SQLite scalar value persisted inside Android sync metadata tables.

Android's `LogEntry.entityId1` and `entityId2` columns are declared as `BLOB`, but SQLite's
dynamic typing means the staged value can still arrive as a blob, string, integer, real, or null
depending on the originating table and trigger expression. iOS preserves the exact scalar kind so
later patch merge logic can compare Android composite identifiers without guessing how they were
encoded.
*/
public struct RemoteSyncSQLiteValue: Codable, Sendable, Equatable {
    /**
    Storage kind observed in the staged SQLite value.
    */
    public enum Kind: String, Codable, Sendable {
        /// SQLite `NULL`.
        case null

        /// SQLite signed 64-bit integer.
        case integer

        /// SQLite floating-point value.
        case real

        /// SQLite UTF-8 text value.
        case text

        /// SQLite raw blob payload.
        case blob
    }

    /// Storage kind observed in the staged SQLite value.
    public let kind: Kind

    /// Integer payload when `kind == .integer`.
    public let integerValue: Int64?

    /// Floating-point payload when `kind == .real`.
    public let realValue: Double?

    /// Text payload when `kind == .text`.
    public let textValue: String?

    /// Base64-encoded blob payload when `kind == .blob`.
    public let blobBase64Value: String?

    /**
    Creates one typed SQLite value payload.

    - Parameters:
      - kind: Storage kind observed in the staged SQLite value.
      - integerValue: Integer payload when `kind == .integer`.
      - realValue: Floating-point payload when `kind == .real`.
      - textValue: Text payload when `kind == .text`.
      - blobBase64Value: Base64-encoded blob payload when `kind == .blob`.
    - Side effects: none.
    - Failure modes: This initializer cannot fail.
    */
    public init(
        kind: Kind,
        integerValue: Int64? = nil,
        realValue: Double? = nil,
        textValue: String? = nil,
        blobBase64Value: String? = nil
    ) {
        self.kind = kind
        self.integerValue = integerValue
        self.realValue = realValue
        self.textValue = textValue
        self.blobBase64Value = blobBase64Value
    }

    /**
    Creates one SQLite `NULL` payload.

    - Returns: Null SQLite value payload.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    public static func null() -> RemoteSyncSQLiteValue {
        RemoteSyncSQLiteValue(kind: .null)
    }

    /**
    Creates one SQLite integer payload.

    - Parameter value: Integer payload.
    - Returns: Integer SQLite value payload.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    public static func integer(_ value: Int64) -> RemoteSyncSQLiteValue {
        RemoteSyncSQLiteValue(kind: .integer, integerValue: value)
    }

    /**
    Creates one SQLite floating-point payload.

    - Parameter value: Floating-point payload.
    - Returns: Floating-point SQLite value payload.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    public static func real(_ value: Double) -> RemoteSyncSQLiteValue {
        RemoteSyncSQLiteValue(kind: .real, realValue: value)
    }

    /**
    Creates one SQLite text payload.

    - Parameter value: UTF-8 text payload.
    - Returns: Text SQLite value payload.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    public static func text(_ value: String) -> RemoteSyncSQLiteValue {
        RemoteSyncSQLiteValue(kind: .text, textValue: value)
    }

    /**
    Creates one SQLite blob payload.

    - Parameter value: Raw blob payload bytes.
    - Returns: Blob SQLite value payload encoded as Base64.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    public static func blob(_ value: Data) -> RemoteSyncSQLiteValue {
        RemoteSyncSQLiteValue(kind: .blob, blobBase64Value: value.base64EncodedString())
    }

    /**
    Returns the raw blob bytes when this value stores a blob payload.

    - Returns: Raw blob bytes, or `nil` when this value is not a blob or the stored Base64 is malformed.
    - Side effects: none.
    - Failure modes:
      - malformed Base64 payloads return `nil`
    */
    public var blobData: Data? {
        guard let blobBase64Value else {
            return nil
        }
        return Data(base64Encoded: blobBase64Value)
    }
}

/**
Operation type persisted by Android's `LogEntry` table.
*/
public enum RemoteSyncLogEntryType: String, Codable, Sendable {
    /// Row should be inserted or updated during patch replay.
    case upsert = "UPSERT"

    /// Row should be deleted during patch replay.
    case delete = "DELETE"
}

/**
One Android `LogEntry` row preserved in iOS local-only storage.

Android uses `LogEntry` rows to decide whether an incoming patch row is newer than the local row.
iOS preserves the same payload so later patch replay and patch creation can use Android's
conflict-resolution rules without requiring the original Room tables.
*/
public struct RemoteSyncLogEntry: Codable, Sendable, Equatable {
    /// Android table name that owns the mutated entity.
    public let tableName: String

    /// First composite-identifier component stored in `LogEntry.entityId1`.
    public let entityID1: RemoteSyncSQLiteValue

    /// Second composite-identifier component stored in `LogEntry.entityId2`.
    public let entityID2: RemoteSyncSQLiteValue

    /// Operation type recorded by Android.
    public let type: RemoteSyncLogEntryType

    /// Millisecond timestamp when Android recorded the mutation.
    public let lastUpdated: Int64

    /// Android device identifier that originally wrote the mutation.
    public let sourceDevice: String

    /**
    Creates one Android log-entry payload.

    - Parameters:
      - tableName: Android table name that owns the mutated entity.
      - entityID1: First composite-identifier component stored in `LogEntry.entityId1`.
      - entityID2: Second composite-identifier component stored in `LogEntry.entityId2`.
      - type: Operation type recorded by Android.
      - lastUpdated: Millisecond timestamp when Android recorded the mutation.
      - sourceDevice: Android device identifier that originally wrote the mutation.
    - Side effects: none.
    - Failure modes: This initializer cannot fail.
    */
    public init(
        tableName: String,
        entityID1: RemoteSyncSQLiteValue,
        entityID2: RemoteSyncSQLiteValue,
        type: RemoteSyncLogEntryType,
        lastUpdated: Int64,
        sourceDevice: String
    ) {
        self.tableName = tableName
        self.entityID1 = entityID1
        self.entityID2 = entityID2
        self.type = type
        self.lastUpdated = lastUpdated
        self.sourceDevice = sourceDevice
    }
}

/**
Persists Android `LogEntry` rows in the local settings table on iOS.

Android uses a dedicated `LogEntry` SQLite table per syncable database. iOS does not yet expose
equivalent raw sync tables, so this store mirrors the same payload inside local-only `Setting`
rows. The stored rows remain category-scoped and keyed by Android's composite primary key
`(tableName, entityId1, entityId2)`.

Data dependencies:
- `SettingsStore` provides durable local-only persistence and prefix-based key enumeration

Side effects:
- writes and deletes local `Setting` rows in the `LocalStore`

Failure modes:
- malformed stored JSON values are ignored during reads
- underlying `SettingsStore` writes swallow save errors, so callers should treat persistence as
  best-effort sync bookkeeping rather than transactional state

Concurrency:
- this type inherits the confinement requirements of the supplied `SettingsStore`
*/
public final class RemoteSyncLogEntryStore {
    private let settingsStore: SettingsStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private enum Keys {
        static let prefix = "remote_sync.log_entries"
    }

    /**
    Creates a log-entry store bound to a local settings store.

    - Parameter settingsStore: Local-only settings store used for persistence.
    - Side effects: none.
    - Failure modes: This initializer cannot fail.
    */
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
    Persists one Android log entry for the supplied category.

    - Parameters:
      - entry: Android log entry to store.
      - category: Logical sync category the log entry belongs to.
    - Side effects:
      - encodes the log entry as JSON and writes it into `SettingsStore`
    - Failure modes:
      - encoding failures skip the write silently
      - underlying `SettingsStore` save failures are swallowed
    */
    public func addEntry(_ entry: RemoteSyncLogEntry, for category: RemoteSyncCategory) {
        guard let data = try? encoder.encode(entry),
              let payload = String(data: data, encoding: .utf8) else {
            return
        }
        settingsStore.setString(key(for: category, entry: entry), value: payload)
    }

    /**
    Replaces all stored Android log entries for one category.

    - Parameters:
      - entries: Complete replacement set of Android log entries.
      - category: Logical sync category the log entries belong to.
    - Side effects:
      - removes existing log-entry rows for the category
      - writes one JSON-encoded `Setting` row per supplied log entry
    - Failure modes:
      - malformed or unsavable individual records are skipped while the rest continue
    */
    public func replaceEntries(_ entries: [RemoteSyncLogEntry], for category: RemoteSyncCategory) {
        clearCategory(category)
        for entry in entries {
            addEntry(entry, for: category)
        }
    }

    /**
    Reads one stored Android log entry by its Android primary-key components.

    - Parameters:
      - category: Logical sync category to inspect.
      - tableName: Android table name that owns the entity.
      - entityID1: First composite identifier component.
      - entityID2: Second composite identifier component.
    - Returns: Stored log entry when present and decodable; otherwise `nil`.
    - Side effects: reads local `Setting` rows.
    - Failure modes:
      - missing rows return `nil`
      - malformed JSON payloads return `nil`
    */
    public func entry(
        for category: RemoteSyncCategory,
        tableName: String,
        entityID1: RemoteSyncSQLiteValue,
        entityID2: RemoteSyncSQLiteValue
    ) -> RemoteSyncLogEntry? {
        guard let payload = settingsStore.getString(
            key(
                for: category,
                tableName: tableName,
                entityID1: entityID1,
                entityID2: entityID2
            )
        ),
        let data = payload.data(using: .utf8) else {
            return nil
        }
        return try? decoder.decode(RemoteSyncLogEntry.self, from: data)
    }

    /**
    Reads all stored Android log entries for one category.

    - Parameter category: Logical sync category to inspect.
    - Returns: Decodable log entries for the category, sorted deterministically for replay.
    - Side effects: reads local `Setting` rows via prefix enumeration.
    - Failure modes: Malformed stored JSON values are ignored.
    */
    public func entries(for category: RemoteSyncCategory) -> [RemoteSyncLogEntry] {
        settingsStore.entries(withPrefix: prefix(for: category))
            .compactMap { entry in
                guard let data = entry.value.data(using: .utf8) else {
                    return nil
                }
                return try? decoder.decode(RemoteSyncLogEntry.self, from: data)
            }
            .sorted(by: Self.replaySort)
    }

    /**
    Clears all stored Android log entries for one category.

    - Parameter category: Logical sync category whose log entries should be removed.
    - Side effects:
      - deletes all matching log-entry rows from `SettingsStore`
    - Failure modes:
      - underlying `SettingsStore` delete failures are swallowed
    */
    public func clearCategory(_ category: RemoteSyncCategory) {
        for entry in settingsStore.entries(withPrefix: prefix(for: category)) {
            settingsStore.remove(entry.key)
        }
    }

    /**
    Builds the fully scoped settings key for one Android log entry.

    - Parameters:
      - category: Logical sync category that owns the log entry.
      - entry: Android log entry whose key should be built.
    - Returns: Fully scoped local settings key for the entry.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    public func key(for category: RemoteSyncCategory, entry: RemoteSyncLogEntry) -> String {
        key(
            for: category,
            tableName: entry.tableName,
            entityID1: entry.entityID1,
            entityID2: entry.entityID2
        )
    }

    /**
    Builds the fully scoped settings key for one Android log-entry primary key.

    - Parameters:
      - category: Logical sync category that owns the log entry.
      - tableName: Android table name that owns the entity.
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
        "\(prefix(for: category))\(encodeKeySegment(tableName)).\(keySegment(for: entityID1)).\(keySegment(for: entityID2))"
    }

    /**
    Returns the category-specific prefix used for stored log entries.

    - Parameter category: Logical sync category to scope.
    - Returns: Category-specific log-entry prefix ending in a dot.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    public func prefix(for category: RemoteSyncCategory) -> String {
        "\(Keys.prefix).\(category.rawValue)."
    }

    /**
    Converts one typed SQLite value into a deterministic, settings-key-safe segment.

    - Parameter value: Typed SQLite value that participates in Android's composite log-entry key.
    - Returns: URL-safe Base64 segment preserving both the SQLite storage kind and payload.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    private func keySegment(for value: RemoteSyncSQLiteValue) -> String {
        let rawValue: String
        switch value.kind {
        case .null:
            rawValue = "n:"
        case .integer:
            rawValue = "i:\(value.integerValue ?? 0)"
        case .real:
            rawValue = "r:\(value.realValue?.bitPattern ?? 0)"
        case .text:
            rawValue = "t:\(value.textValue ?? "")"
        case .blob:
            rawValue = "b:\(value.blobBase64Value ?? "")"
        }
        return encodeKeySegment(rawValue)
    }

    /**
    Encodes one settings-key segment using URL-safe Base64 without padding.

    - Parameter rawValue: Raw key component to embed in a dotted settings key.
    - Returns: URL-safe Base64 segment with `+`, `/`, and `=` removed or substituted.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    private func encodeKeySegment(_ rawValue: String) -> String {
        let data = Data(rawValue.utf8)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /**
    Sorts log entries into a deterministic order suitable for later replay work.

    - Parameters:
      - lhs: First log entry to compare.
      - rhs: Second log entry to compare.
    - Returns: `true` when `lhs` should appear before `rhs`.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    private static func replaySort(_ lhs: RemoteSyncLogEntry, _ rhs: RemoteSyncLogEntry) -> Bool {
        if lhs.lastUpdated != rhs.lastUpdated {
            return lhs.lastUpdated < rhs.lastUpdated
        }
        if lhs.tableName != rhs.tableName {
            return lhs.tableName < rhs.tableName
        }
        if lhs.type != rhs.type {
            return lhs.type.rawValue < rhs.type.rawValue
        }
        if lhs.sourceDevice != rhs.sourceDevice {
            return lhs.sourceDevice < rhs.sourceDevice
        }
        if lhs.entityID1 != rhs.entityID1 {
            return canonicalSortKey(for: lhs.entityID1) < canonicalSortKey(for: rhs.entityID1)
        }
        return canonicalSortKey(for: lhs.entityID2) < canonicalSortKey(for: rhs.entityID2)
    }

    /**
    Builds a deterministic text representation used only for stable local sorting.

    - Parameter value: Typed SQLite identifier component.
    - Returns: Canonical string representation of the value's storage kind and payload.
    - Side effects: none.
    - Failure modes: This helper cannot fail.
    */
    private static func canonicalSortKey(for value: RemoteSyncSQLiteValue) -> String {
        switch value.kind {
        case .null:
            return "null"
        case .integer:
            return "integer:\(value.integerValue ?? 0)"
        case .real:
            return "real:\(value.realValue?.bitPattern ?? 0)"
        case .text:
            return "text:\(value.textValue ?? "")"
        case .blob:
            return "blob:\(value.blobBase64Value ?? "")"
        }
    }
}
