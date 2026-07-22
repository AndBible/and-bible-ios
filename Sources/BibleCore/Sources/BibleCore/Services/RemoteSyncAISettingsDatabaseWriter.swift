// RemoteSyncAISettingsDatabaseWriter.swift -- Android v23 AI settings SQLite publication

import Foundation
import SQLite3

private let remoteSyncAISettingsWriterSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

/**
 Selects whether an AI settings publication contains the complete current generation or only rows
 named by the supplied Android `LogEntry` operations.
 */
public enum RemoteSyncAISettingsDatabaseWriteMode: Sendable, Equatable {
    /// Inserts every row from the supplied snapshot, as required by an initial backup.
    case full

    /// Inserts only rows named by UPSERT log entries; DELETE entries carry no content row.
    case sparse
}

/**
 Fail-closed errors raised while materializing Android's AI settings Room database.

 Filesystem errors are rethrown directly so callers retain the destination path and Cocoa error code.
 No destination is replaced unless schema creation, row insertion, contract validation, and SQLite
 commit all succeed in a staged sibling file.
 */
public enum RemoteSyncAISettingsDatabaseWriterError: Error, Equatable {
    /// A caller requested a schema generation other than Android's supported v23 contract.
    case unsupportedSchemaVersion(Int)

    /// SQLite could not create, populate, validate, commit, or close the staged database.
    case invalidSQLiteDatabase

    /// More than one snapshot row used the same Android table primary key.
    case duplicateIdentifier(table: String, id: UUID)

    /// More than one row used an Android unique composite identity.
    case duplicateCompositeIdentity(table: String, first: String, second: String)

    /// A present global settings row did not use Android's fixed singleton UUID.
    case invalidGlobalSettingsIdentity(UUID)

    /// More than one global settings row was supplied.
    case duplicateGlobalSettings

    /// A formal Android foreign-key reference did not resolve in the complete source snapshot.
    case orphanFormalReference(table: String, id: UUID, parentTable: String, parentID: UUID)

    /// A floating-point value could not be represented as a finite SQLite REAL.
    case invalidFloatingPointValue(table: String, id: UUID)

    /// A selected log entry named a table outside Android's seven synchronized AI tables.
    case unsupportedLogTable(String)

    /// A selected log identity was not Android's UUID BLOB plus empty-text secondary identifier.
    case invalidLogIdentity(table: String)

    /// More than one selected log entry addressed the same Android row.
    case duplicateLogIdentity(table: String, id: UUID)

    /// A sparse UPSERT selected an identity absent from the current snapshot.
    case missingUpsertRow(table: String, id: UUID)

    /// A full publication paired a DELETE operation with a row that is still present.
    case inconsistentDeleteRow(table: String, id: UUID)
}

/** Counts written for one successfully published Android AI settings database. */
public struct RemoteSyncAISettingsDatabaseWriteReport: Sendable, Equatable {
    /// Exact Android Room schema version written to `PRAGMA user_version`.
    public let schemaVersion: Int

    /// Number of non-secret provider rows written.
    public let providerCount: Int

    /// Number of configured-model rows written.
    public let configuredModelCount: Int

    /// Number of agent-prompt rows written.
    public let agentPromptCount: Int

    /// Number of global-settings singleton rows written.
    public let globalSettingsCount: Int

    /// Number of per-device usage rows written.
    public let usageRecordCount: Int

    /// Number of user prompt-category rows written.
    public let promptCategoryCount: Int

    /// Number of built-in prompt override rows written.
    public let builtinPromptOverrideCount: Int

    /// Number of Android conflict/tombstone rows written.
    public let logEntryCount: Int

    /// Always zero because raw model logs are device-local and excluded from publication.
    public let rawLogRecordCount: Int
}

/**
 Writes Android-compatible `AiSettingsDatabase` v23 files from credential-free iOS snapshots.

 The writer always creates the complete Room schema shell supplied by
 `RemoteSyncAndroidDatabaseContract`, including the intentionally empty `LlmRawLogRecord` table.
 It accepts no credential store or API-key value, so secrets cannot enter the database through this
 API. Full publications insert every snapshot row. Sparse publications use the passed `LogEntry`
 values as the exact row selection: UPSERT includes the matching current row, while DELETE includes
 only its tombstone.

 Side effects:
 - creates a temporary SQLite file beside the destination
 - executes Android's v23 DDL and inserts selected content and metadata in one transaction
 - validates the completed file against the exact Room schema and bounded payload contract
 - atomically moves or replaces the destination only after SQLite closes successfully

 Failure modes:
 - rejects duplicate identities, invalid singleton state, formal foreign-key orphans, non-finite
   values, malformed log identities, inconsistent full-backup logs, and any schema other than v23
 - rethrows filesystem errors and reports SQLite failures as
   `RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase`

 Concurrency:
 - instances hold only an injected `FileManager`, but callers must serialize writes to one destination
 - each invocation uses a unique sibling staging file and is deterministic for equivalent row sets
 */
public final class RemoteSyncAISettingsDatabaseWriter {
    /// Exact Android `AiSettingsDatabase` generation emitted by this writer.
    public static let supportedAndroidSchemaVersion = 23

    private static let synchronizedTables: Set<String> = [
        "LlmProviderConfig",
        "LlmConfiguredModel",
        "AgentPrompt",
        "GlobalAiSettings",
        "LlmUsageRecord",
        "PromptCategory",
        "BuiltinPromptOverride",
    ]

    private let fileManager: FileManager

    /**
     Creates an AI settings database writer.

     - Parameter fileManager: Filesystem implementation used for staging and atomic publication.
     - Side Effects: none; directories and files are created only by a write method.
     - Failure modes: This initializer cannot fail.
     */
    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /**
     Atomically writes a complete Android AI settings initial-backup database.

     - Parameters:
       - destinationURL: Final SQLite file URL to create or replace.
       - snapshot: Complete current seven-table AI settings projection.
       - logEntries: Selected Android metadata rows to include; initial backups normally pass none.
       - schemaVersion: Must equal 23.
     - Returns: Exact counts committed to the published file.
     - Side Effects: Creates and atomically publishes one complete v23 SQLite database.
     - Throws: Typed snapshot, log, schema, SQLite, or filesystem failures; the previous destination
       remains unchanged on failure.
     */
    public func writeFullDatabase(
        at destinationURL: URL,
        snapshot: RemoteSyncAISettingsCurrentSnapshot,
        logEntries: [RemoteSyncLogEntry] = [],
        schemaVersion: Int = supportedAndroidSchemaVersion
    ) throws -> RemoteSyncAISettingsDatabaseWriteReport {
        try writeDatabase(
            at: destinationURL,
            snapshot: snapshot,
            selectedLogEntries: logEntries,
            mode: .full,
            schemaVersion: schemaVersion
        )
    }

    /**
     Atomically writes one sparse Android AI settings patch database.

     UPSERT rows present in `snapshot` are included. Metadata-only UPSERTs remain valid because
     Android can retain their `LogEntry` after formal-FK cleanup removes the payload row. Selected
     DELETE operations also write only `LogEntry`; unselected snapshot rows are not inserted.

     - Parameters:
       - destinationURL: Final SQLite file URL to create or replace.
       - snapshot: Complete current seven-table projection used to resolve UPSERT identities.
       - selectedLogEntries: Exact Android operations carried by this patch.
       - schemaVersion: Must equal 23.
     - Returns: Counts of sparse content rows and log entries committed to the file.
     - Side Effects: Creates and atomically publishes one sparse v23 SQLite database.
     - Throws: Typed snapshot, log, schema, SQLite, or filesystem failures; the previous destination
       remains unchanged on failure.
     */
    public func writeSparseDatabase(
        at destinationURL: URL,
        snapshot: RemoteSyncAISettingsCurrentSnapshot,
        selectedLogEntries: [RemoteSyncLogEntry],
        schemaVersion: Int = supportedAndroidSchemaVersion
    ) throws -> RemoteSyncAISettingsDatabaseWriteReport {
        try writeDatabase(
            at: destinationURL,
            snapshot: snapshot,
            selectedLogEntries: selectedLogEntries,
            mode: .sparse,
            schemaVersion: schemaVersion
        )
    }

    /**
     Writes a full or sparse database through the shared validated publication path.

     - Parameters:
       - destinationURL: Final SQLite file URL to create or replace.
       - snapshot: Complete current source generation.
       - selectedLogEntries: Metadata rows to write and, in sparse mode, row-selection operations.
       - mode: Complete initial-backup or sparse patch behavior.
       - schemaVersion: Must equal 23.
     - Returns: Counts committed to the published database.
     - Side Effects: Stages, validates, commits, closes, and atomically publishes a SQLite file.
     - Throws: Rethrows every validation, SQLite, and filesystem failure without publishing a partial
       destination.
     */
    public func writeDatabase(
        at destinationURL: URL,
        snapshot: RemoteSyncAISettingsCurrentSnapshot,
        selectedLogEntries: [RemoteSyncLogEntry],
        mode: RemoteSyncAISettingsDatabaseWriteMode,
        schemaVersion: Int = supportedAndroidSchemaVersion
    ) throws -> RemoteSyncAISettingsDatabaseWriteReport {
        guard schemaVersion == Self.supportedAndroidSchemaVersion,
              RemoteSyncAndroidDatabaseContract.schemaVersion(for: .aiSettings) == schemaVersion else {
            throw RemoteSyncAISettingsDatabaseWriterError.unsupportedSchemaVersion(schemaVersion)
        }

        let allRows = try Self.validatedRows(from: snapshot)
        let logIdentities = try Self.validatedLogIdentities(selectedLogEntries)
        let rows = try Self.selectedRows(
            from: allRows,
            logEntries: selectedLogEntries,
            identities: logIdentities,
            mode: mode
        )

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stagingURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        try? fileManager.removeItem(at: stagingURL)
        var keepStagingFile = false
        defer {
            if !keepStagingFile {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        try writeStagedDatabase(
            at: stagingURL,
            rows: rows,
            logEntries: selectedLogEntries
        )
        try publish(stagingURL: stagingURL, destinationURL: destinationURL)
        keepStagingFile = true

        return RemoteSyncAISettingsDatabaseWriteReport(
            schemaVersion: schemaVersion,
            providerCount: rows.providers.count,
            configuredModelCount: rows.configuredModels.count,
            agentPromptCount: rows.agentPrompts.count,
            globalSettingsCount: rows.globalSettings.count,
            usageRecordCount: rows.usageRecords.count,
            promptCategoryCount: rows.promptCategories.count,
            builtinPromptOverrideCount: rows.builtinOverrides.count,
            logEntryCount: selectedLogEntries.count,
            rawLogRecordCount: 0
        )
    }

    /** Complete validated source rows keyed by Android UUID identities. */
    private struct ValidatedRows {
        let providers: [RemoteSyncAndroidAIProvider]
        let configuredModels: [RemoteSyncAndroidAIConfiguredModel]
        let agentPrompts: [RemoteSyncAndroidAIAgentPrompt]
        let globalSettings: [RemoteSyncAndroidGlobalAISettings]
        let usageRecords: [RemoteSyncAndroidAIUsageRecord]
        let promptCategories: [RemoteSyncAndroidAIPromptCategory]
        let builtinOverrides: [RemoteSyncAndroidAIBuiltinPromptOverride]

        var providersByID: [UUID: RemoteSyncAndroidAIProvider] {
            Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        }

        var configuredModelsByID: [UUID: RemoteSyncAndroidAIConfiguredModel] {
            Dictionary(uniqueKeysWithValues: configuredModels.map { ($0.id, $0) })
        }

        var agentPromptsByID: [UUID: RemoteSyncAndroidAIAgentPrompt] {
            Dictionary(uniqueKeysWithValues: agentPrompts.map { ($0.id, $0) })
        }

        var globalSettingsByID: [UUID: RemoteSyncAndroidGlobalAISettings] {
            Dictionary(uniqueKeysWithValues: globalSettings.map { ($0.id, $0) })
        }

        var usageRecordsByID: [UUID: RemoteSyncAndroidAIUsageRecord] {
            Dictionary(uniqueKeysWithValues: usageRecords.map { ($0.id, $0) })
        }

        var promptCategoriesByID: [UUID: RemoteSyncAndroidAIPromptCategory] {
            Dictionary(uniqueKeysWithValues: promptCategories.map { ($0.id, $0) })
        }

        var builtinOverridesByID: [UUID: RemoteSyncAndroidAIBuiltinPromptOverride] {
            Dictionary(uniqueKeysWithValues: builtinOverrides.map { ($0.id, $0) })
        }
    }

    /** Sparse or full rows selected for one physical SQLite file. */
    private struct SelectedRows {
        var providers: [RemoteSyncAndroidAIProvider] = []
        var configuredModels: [RemoteSyncAndroidAIConfiguredModel] = []
        var agentPrompts: [RemoteSyncAndroidAIAgentPrompt] = []
        var globalSettings: [RemoteSyncAndroidGlobalAISettings] = []
        var usageRecords: [RemoteSyncAndroidAIUsageRecord] = []
        var promptCategories: [RemoteSyncAndroidAIPromptCategory] = []
        var builtinOverrides: [RemoteSyncAndroidAIBuiltinPromptOverride] = []
    }

    /** UUID decoded from one already validated Android log identity. */
    private struct LogIdentity {
        let tableName: String
        let id: UUID
    }

    /**
     Validates complete snapshot invariants before any filesystem mutation begins.

     Logical references (`AgentPrompt.categoryId`, global default model, and usage model) deliberately
     remain unchecked because Android permits them to dangle. Only physical Room foreign keys are
     enforced here.
     */
    private static func validatedRows(
        from snapshot: RemoteSyncAISettingsCurrentSnapshot
    ) throws -> ValidatedRows {
        let rows = ValidatedRows(
            providers: Array(snapshot.providerRowsByKey.values),
            configuredModels: Array(snapshot.configuredModelRowsByKey.values),
            agentPrompts: Array(snapshot.agentPromptRowsByKey.values),
            globalSettings: Array(snapshot.globalSettingsRowsByKey.values),
            usageRecords: Array(snapshot.usageRowsByKey.values),
            promptCategories: Array(snapshot.promptCategoryRowsByKey.values),
            builtinOverrides: Array(snapshot.builtinOverrideRowsByKey.values)
        )

        try requireUniqueIDs(rows.providers, table: "LlmProviderConfig", id: \.id)
        try requireUniqueIDs(rows.configuredModels, table: "LlmConfiguredModel", id: \.id)
        try requireUniqueIDs(rows.agentPrompts, table: "AgentPrompt", id: \.id)
        try requireUniqueIDs(rows.globalSettings, table: "GlobalAiSettings", id: \.id)
        try requireUniqueIDs(rows.usageRecords, table: "LlmUsageRecord", id: \.id)
        try requireUniqueIDs(rows.promptCategories, table: "PromptCategory", id: \.id)
        try requireUniqueIDs(rows.builtinOverrides, table: "BuiltinPromptOverride", id: \.id)

        guard rows.globalSettings.count <= 1 else {
            throw RemoteSyncAISettingsDatabaseWriterError.duplicateGlobalSettings
        }
        if let global = rows.globalSettings.first, global.id != GlobalAISettings.singletonID {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidGlobalSettingsIdentity(global.id)
        }

        try requireUniqueComposite(
            rows.configuredModels,
            table: "LlmConfiguredModel",
            first: { $0.providerConfigId.uuidString.lowercased() },
            second: \.modelId
        )
        try requireUniqueComposite(
            rows.usageRecords,
            table: "LlmUsageRecord",
            first: { $0.configuredModelId.uuidString.lowercased() },
            second: \.deviceId
        )

        let providerIDs = Set(rows.providers.map(\.id))
        let configuredModelIDs = Set(rows.configuredModels.map(\.id))
        for row in rows.configuredModels where !providerIDs.contains(row.providerConfigId) {
            throw RemoteSyncAISettingsDatabaseWriterError.orphanFormalReference(
                table: "LlmConfiguredModel",
                id: row.id,
                parentTable: "LlmProviderConfig",
                parentID: row.providerConfigId
            )
        }
        for row in rows.agentPrompts {
            if let parentID = row.configuredModelId, !configuredModelIDs.contains(parentID) {
                throw RemoteSyncAISettingsDatabaseWriterError.orphanFormalReference(
                    table: "AgentPrompt",
                    id: row.id,
                    parentTable: "LlmConfiguredModel",
                    parentID: parentID
                )
            }
        }
        for row in rows.builtinOverrides {
            if let parentID = row.configuredModelId, !configuredModelIDs.contains(parentID) {
                throw RemoteSyncAISettingsDatabaseWriterError.orphanFormalReference(
                    table: "BuiltinPromptOverride",
                    id: row.id,
                    parentTable: "LlmConfiguredModel",
                    parentID: parentID
                )
            }
        }
        for row in rows.configuredModels where !row.inputPricePerMillion.isFinite
            || !row.outputPricePerMillion.isFinite
            || !row.cacheCreationPricePerMillion.isFinite
            || !row.cacheReadPricePerMillion.isFinite {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidFloatingPointValue(
                table: "LlmConfiguredModel",
                id: row.id
            )
        }
        for row in rows.usageRecords where !row.estimatedCostUsd.isFinite {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidFloatingPointValue(
                table: "LlmUsageRecord",
                id: row.id
            )
        }
        return rows
    }

    /** Validates log table membership, UUID storage, empty secondary identity, and uniqueness. */
    private static func validatedLogIdentities(
        _ entries: [RemoteSyncLogEntry]
    ) throws -> [LogIdentity] {
        var seen: Set<String> = []
        var result: [LogIdentity] = []
        for entry in entries {
            guard synchronizedTables.contains(entry.tableName) else {
                throw RemoteSyncAISettingsDatabaseWriterError.unsupportedLogTable(entry.tableName)
            }
            guard entry.entityID1.kind == .blob,
                  let data = entry.entityID1.blobData,
                  let id = RemoteSyncAISettingsSnapshotService.uuid(from: data),
                  entry.entityID2.kind == .text,
                  entry.entityID2.textValue == "" else {
                throw RemoteSyncAISettingsDatabaseWriterError.invalidLogIdentity(table: entry.tableName)
            }
            if entry.tableName == "GlobalAiSettings", id != GlobalAISettings.singletonID {
                throw RemoteSyncAISettingsDatabaseWriterError.invalidGlobalSettingsIdentity(id)
            }
            let key = "\(entry.tableName)\u{0}\(id.uuidString.lowercased())"
            guard seen.insert(key).inserted else {
                throw RemoteSyncAISettingsDatabaseWriterError.duplicateLogIdentity(
                    table: entry.tableName,
                    id: id
                )
            }
            result.append(LogIdentity(tableName: entry.tableName, id: id))
        }
        return result
    }

    /** Builds a deterministic full set or resolves sparse UPSERT operations against current rows. */
    private static func selectedRows(
        from rows: ValidatedRows,
        logEntries: [RemoteSyncLogEntry],
        identities: [LogIdentity],
        mode: RemoteSyncAISettingsDatabaseWriteMode
    ) throws -> SelectedRows {
        switch mode {
        case .full:
            for (entry, identity) in zip(logEntries, identities) {
                let rowIsPresent = containsRow(identity, in: rows)
                if entry.type == .upsert, !rowIsPresent {
                    throw missingUpsert(identity)
                }
                if entry.type == .delete, rowIsPresent {
                    throw RemoteSyncAISettingsDatabaseWriterError.inconsistentDeleteRow(
                        table: identity.tableName,
                        id: identity.id
                    )
                }
            }
            return SelectedRows(
                providers: rows.providers.sorted(by: providerSort),
                configuredModels: rows.configuredModels.sorted(by: configuredModelSort),
                agentPrompts: rows.agentPrompts.sorted(by: promptSort),
                globalSettings: rows.globalSettings,
                usageRecords: rows.usageRecords.sorted(by: usageSort),
                promptCategories: rows.promptCategories.sorted(by: categorySort),
                builtinOverrides: rows.builtinOverrides.sorted { $0.id.uuidString < $1.id.uuidString }
            )
        case .sparse:
            var selected = SelectedRows()
            for (entry, identity) in zip(logEntries, identities) where entry.type == .upsert {
                switch identity.tableName {
                case "LlmProviderConfig":
                    if let row = rows.providersByID[identity.id] { selected.providers.append(row) }
                case "LlmConfiguredModel":
                    if let row = rows.configuredModelsByID[identity.id] {
                        selected.configuredModels.append(row)
                    }
                case "AgentPrompt":
                    if let row = rows.agentPromptsByID[identity.id] { selected.agentPrompts.append(row) }
                case "GlobalAiSettings":
                    if let row = rows.globalSettingsByID[identity.id] {
                        selected.globalSettings.append(row)
                    }
                case "LlmUsageRecord":
                    if let row = rows.usageRecordsByID[identity.id] {
                        selected.usageRecords.append(row)
                    }
                case "PromptCategory":
                    if let row = rows.promptCategoriesByID[identity.id] {
                        selected.promptCategories.append(row)
                    }
                case "BuiltinPromptOverride":
                    if let row = rows.builtinOverridesByID[identity.id] {
                        selected.builtinOverrides.append(row)
                    }
                default:
                    throw RemoteSyncAISettingsDatabaseWriterError.unsupportedLogTable(identity.tableName)
                }
            }
            selected.providers.sort(by: providerSort)
            selected.configuredModels.sort(by: configuredModelSort)
            selected.agentPrompts.sort(by: promptSort)
            selected.usageRecords.sort(by: usageSort)
            selected.promptCategories.sort(by: categorySort)
            selected.builtinOverrides.sort { $0.id.uuidString < $1.id.uuidString }
            return selected
        }
    }

    /** Returns whether one validated complete source generation contains a selected identity. */
    private static func containsRow(_ identity: LogIdentity, in rows: ValidatedRows) -> Bool {
        switch identity.tableName {
        case "LlmProviderConfig": rows.providersByID[identity.id] != nil
        case "LlmConfiguredModel": rows.configuredModelsByID[identity.id] != nil
        case "AgentPrompt": rows.agentPromptsByID[identity.id] != nil
        case "GlobalAiSettings": rows.globalSettingsByID[identity.id] != nil
        case "LlmUsageRecord": rows.usageRecordsByID[identity.id] != nil
        case "PromptCategory": rows.promptCategoriesByID[identity.id] != nil
        case "BuiltinPromptOverride": rows.builtinOverridesByID[identity.id] != nil
        default: false
        }
    }

    /** Constructs the typed error used when a sparse UPSERT has no corresponding content row. */
    private static func missingUpsert(
        _ identity: LogIdentity
    ) -> RemoteSyncAISettingsDatabaseWriterError {
        .missingUpsertRow(table: identity.tableName, id: identity.id)
    }

    /** Rejects repeated primary UUIDs without using a trapping dictionary initializer. */
    private static func requireUniqueIDs<Row>(
        _ rows: [Row],
        table: String,
        id: (Row) -> UUID
    ) throws {
        var seen: Set<UUID> = []
        for row in rows {
            let value = id(row)
            guard seen.insert(value).inserted else {
                throw RemoteSyncAISettingsDatabaseWriterError.duplicateIdentifier(table: table, id: value)
            }
        }
    }

    /** Rejects repeated Android unique-index pairs before SQLite insertion. */
    private static func requireUniqueComposite<Row>(
        _ rows: [Row],
        table: String,
        first: (Row) -> String,
        second: (Row) -> String
    ) throws {
        var seen: Set<String> = []
        for row in rows {
            let firstValue = first(row)
            let secondValue = second(row)
            let key = "\(firstValue.utf8.count):\(firstValue)\(secondValue.utf8.count):\(secondValue)"
            guard seen.insert(key).inserted else {
                throw RemoteSyncAISettingsDatabaseWriterError.duplicateCompositeIdentity(
                    table: table,
                    first: firstValue,
                    second: secondValue
                )
            }
        }
    }

    /** Creates and validates a committed sibling SQLite file without exposing it at the destination. */
    private func writeStagedDatabase(
        at url: URL,
        rows: SelectedRows,
        logEntries: [RemoteSyncLogEntry]
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
        }
        sqlite3_extended_result_codes(database, 1)

        do {
            try execute("BEGIN IMMEDIATE TRANSACTION;", in: database)
            try execute(
                RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: .aiSettings),
                in: database
            )
            for row in rows.providers { try insertProvider(row, in: database) }
            for row in rows.configuredModels { try insertConfiguredModel(row, in: database) }
            for row in rows.agentPrompts { try insertAgentPrompt(row, in: database) }
            for row in rows.globalSettings { try insertGlobalSettings(row, in: database) }
            for row in rows.usageRecords { try insertUsageRecord(row, in: database) }
            for row in rows.promptCategories { try insertPromptCategory(row, in: database) }
            for row in rows.builtinOverrides { try insertBuiltinOverride(row, in: database) }
            for entry in logEntries { try insertLogEntry(entry, in: database) }

            try rejectAnyRawLogRows(in: database)
            try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(database, category: .aiSettings)
            try execute("COMMIT;", in: database)
        } catch {
            try? execute("ROLLBACK;", in: database)
            sqlite3_close(database)
            throw error
        }

        guard sqlite3_close(database) == SQLITE_OK else {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
        }
    }

    /** Atomically adopts the closed staging file while preserving an existing destination on failure. */
    private func publish(stagingURL: URL, destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    /** Inserts one exact Android `LlmProviderConfig` row without any credential field. */
    private func insertProvider(_ row: RemoteSyncAndroidAIProvider, in database: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT INTO LlmProviderConfig (id, providerType, displayName, endpoint, apiFormat, orderNumber) VALUES (?, ?, ?, ?, ?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bindUUID(row.id, to: statement, index: 1)
        try bindText(row.providerType, to: statement, index: 2)
        try bindText(row.displayName, to: statement, index: 3)
        try bindOptionalText(row.endpoint, to: statement, index: 4)
        try bindOptionalText(row.apiFormat, to: statement, index: 5)
        try bindInt32(row.orderNumber, field: "LlmProviderConfig.orderNumber", to: statement, index: 6)
        try stepDone(statement)
    }

    /** Inserts one exact Android `LlmConfiguredModel` row. */
    private func insertConfiguredModel(
        _ row: RemoteSyncAndroidAIConfiguredModel,
        in database: OpaquePointer
    ) throws {
        let statement = try prepare(
            "INSERT INTO LlmConfiguredModel (id, providerConfigId, modelId, orderNumber, inputPricePerMillion, outputPricePerMillion, cacheCreationPricePerMillion, cacheReadPricePerMillion) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bindUUID(row.id, to: statement, index: 1)
        try bindUUID(row.providerConfigId, to: statement, index: 2)
        try bindText(row.modelId, to: statement, index: 3)
        try bindInt32(row.orderNumber, field: "LlmConfiguredModel.orderNumber", to: statement, index: 4)
        try bindDouble(row.inputPricePerMillion, to: statement, index: 5)
        try bindDouble(row.outputPricePerMillion, to: statement, index: 6)
        try bindDouble(row.cacheCreationPricePerMillion, to: statement, index: 7)
        try bindDouble(row.cacheReadPricePerMillion, to: statement, index: 8)
        try stepDone(statement)
    }

    /** Inserts one exact Android `AgentPrompt` row while preserving raw converter strings. */
    private func insertAgentPrompt(_ row: RemoteSyncAndroidAIAgentPrompt, in database: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT INTO AgentPrompt (id, name, description, promptTemplate, showIn, orderNumber, createdAt, strictContextMatching, permissionMode, allowedTools, deniedTools, configuredModelId, editBeforeRun, noDocumentCreation, maxIterations, autoIncludeDocuments, autoIncludeCommentaries, bibleOnly, isTextTransformation, categoryId) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bindUUID(row.id, to: statement, index: 1)
        try bindText(row.name, to: statement, index: 2)
        try bindOptionalText(row.promptDescription, to: statement, index: 3)
        try bindText(row.promptTemplate, to: statement, index: 4)
        try bindText(row.showIn, to: statement, index: 5)
        try bindInt32(row.orderNumber, field: "AgentPrompt.orderNumber", to: statement, index: 6)
        try bindInt64(row.createdAt, to: statement, index: 7)
        try bindBool(row.strictContextMatching, to: statement, index: 8)
        try bindOptionalText(row.permissionMode, to: statement, index: 9)
        try bindOptionalText(row.allowedTools, to: statement, index: 10)
        try bindOptionalText(row.deniedTools, to: statement, index: 11)
        try bindOptionalUUID(row.configuredModelId, to: statement, index: 12)
        try bindBool(row.editBeforeRun, to: statement, index: 13)
        try bindBool(row.noDocumentCreation, to: statement, index: 14)
        try bindOptionalInt32(row.maxIterations, field: "AgentPrompt.maxIterations", to: statement, index: 15)
        try bindBool(row.autoIncludeDocuments, to: statement, index: 16)
        try bindBool(row.autoIncludeCommentaries, to: statement, index: 17)
        try bindBool(row.bibleOnly, to: statement, index: 18)
        try bindBool(row.isTextTransformation, to: statement, index: 19)
        try bindOptionalUUID(row.categoryId, to: statement, index: 20)
        try stepDone(statement)
    }

    /** Inserts Android's exact `GlobalAiSettings` singleton row. */
    private func insertGlobalSettings(
        _ row: RemoteSyncAndroidGlobalAISettings,
        in database: OpaquePointer
    ) throws {
        let statement = try prepare(
            "INSERT INTO GlobalAiSettings (id, agentPermissionMode, permanentlyAllowedTools, permanentlyDeniedTools, aiExcludedDocuments, commentaryMaxResponseTokens, hiddenBuiltInPrompts, maxIterations, commentaryDeselected, defaultModelId, aiLanguage, askModelBeforeRun, aiDisclaimerAccepted, hiddenBuiltInCategories, customAgentSystemPrompt, customTextTransformationSystemPrompt, favoritePrompts, rawLogRetentionDays, autoHideAgentLogOnCompletion) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bindUUID(row.id, to: statement, index: 1)
        try bindOptionalText(row.agentPermissionMode, to: statement, index: 2)
        try bindOptionalText(row.permanentlyAllowedTools, to: statement, index: 3)
        try bindOptionalText(row.permanentlyDeniedTools, to: statement, index: 4)
        try bindText(row.aiExcludedDocuments, to: statement, index: 5)
        try bindInt32(row.commentaryMaxResponseTokens, field: "GlobalAiSettings.commentaryMaxResponseTokens", to: statement, index: 6)
        try bindText(row.hiddenBuiltInPrompts, to: statement, index: 7)
        try bindInt32(row.maxIterations, field: "GlobalAiSettings.maxIterations", to: statement, index: 8)
        try bindText(row.commentaryDeselected, to: statement, index: 9)
        try bindOptionalUUID(row.defaultModelId, to: statement, index: 10)
        try bindOptionalText(row.aiLanguage, to: statement, index: 11)
        try bindBool(row.askModelBeforeRun, to: statement, index: 12)
        try bindBool(row.aiDisclaimerAccepted, to: statement, index: 13)
        try bindText(row.hiddenBuiltInCategories, to: statement, index: 14)
        try bindOptionalText(row.customAgentSystemPrompt, to: statement, index: 15)
        try bindOptionalText(row.customTextTransformationSystemPrompt, to: statement, index: 16)
        try bindText(row.favoritePrompts, to: statement, index: 17)
        try bindOptionalInt32(row.rawLogRetentionDays, field: "GlobalAiSettings.rawLogRetentionDays", to: statement, index: 18)
        try bindBool(row.autoHideAgentLogOnCompletion, to: statement, index: 19)
        try stepDone(statement)
    }

    /** Inserts one exact Android `LlmUsageRecord` row. */
    private func insertUsageRecord(_ row: RemoteSyncAndroidAIUsageRecord, in database: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT INTO LlmUsageRecord (id, configuredModelId, deviceId, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, estimatedCostUsd) VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bindUUID(row.id, to: statement, index: 1)
        try bindUUID(row.configuredModelId, to: statement, index: 2)
        try bindText(row.deviceId, to: statement, index: 3)
        try bindInt64(row.inputTokens, to: statement, index: 4)
        try bindInt64(row.outputTokens, to: statement, index: 5)
        try bindInt64(row.cacheCreationTokens, to: statement, index: 6)
        try bindInt64(row.cacheReadTokens, to: statement, index: 7)
        try bindDouble(row.estimatedCostUsd, to: statement, index: 8)
        try stepDone(statement)
    }

    /** Inserts one exact Android `PromptCategory` row. */
    private func insertPromptCategory(
        _ row: RemoteSyncAndroidAIPromptCategory,
        in database: OpaquePointer
    ) throws {
        let statement = try prepare(
            "INSERT INTO PromptCategory (id, name, orderNumber, hidden) VALUES (?, ?, ?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bindUUID(row.id, to: statement, index: 1)
        try bindText(row.name, to: statement, index: 2)
        try bindInt32(row.orderNumber, field: "PromptCategory.orderNumber", to: statement, index: 3)
        try bindBool(row.hidden, to: statement, index: 4)
        try stepDone(statement)
    }

    /** Inserts one exact Android `BuiltinPromptOverride` row. */
    private func insertBuiltinOverride(
        _ row: RemoteSyncAndroidAIBuiltinPromptOverride,
        in database: OpaquePointer
    ) throws {
        let statement = try prepare(
            "INSERT INTO BuiltinPromptOverride (id, configuredModelId) VALUES (?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bindUUID(row.id, to: statement, index: 1)
        try bindOptionalUUID(row.configuredModelId, to: statement, index: 2)
        try stepDone(statement)
    }

    /** Inserts one validated Android conflict or tombstone row. */
    private func insertLogEntry(_ entry: RemoteSyncLogEntry, in database: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bindText(entry.tableName, to: statement, index: 1)
        try bindSQLiteValue(entry.entityID1, to: statement, index: 2)
        try bindSQLiteValue(entry.entityID2, to: statement, index: 3)
        try bindText(entry.type.rawValue, to: statement, index: 4)
        try bindInt64(entry.lastUpdated, to: statement, index: 5)
        try bindText(entry.sourceDevice, to: statement, index: 6)
        try stepDone(statement)
    }

    /** Ensures no device-local raw model log entered the publication through schema-side mutation. */
    private func rejectAnyRawLogRows(in database: OpaquePointer) throws {
        let statement = try prepare("SELECT 1 FROM LlmRawLogRecord LIMIT 1;", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
        }
    }

    /** Prepares one SQLite statement or reports a fail-closed database error. */
    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
        }
        return statement
    }

    /** Executes one SQLite statement batch and rejects any non-success status. */
    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
        }
    }

    /** Requires one prepared insert to finish exactly once. */
    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
        }
    }

    /** Binds one UUID using Android Room's raw 16-byte BLOB representation. */
    private func bindUUID(_ value: UUID, to statement: OpaquePointer?, index: Int32) throws {
        let data = RemoteSyncAISettingsSnapshotService.uuidBlob(value)
        let result = data.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, 16, remoteSyncAISettingsWriterSQLiteTransient)
        }
        guard result == SQLITE_OK else {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
        }
    }

    /** Binds a nullable UUID without converting it to text. */
    private func bindOptionalUUID(_ value: UUID?, to statement: OpaquePointer?, index: Int32) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
            }
            return
        }
        try bindUUID(value, to: statement, index: index)
    }

    /** Binds UTF-8 text with an explicit length so embedded NUL bytes round-trip verbatim. */
    private func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) throws {
        let bytes = value.utf8CString
        let length = try RemoteSyncWireInteger.int32(exactly: bytes.count - 1, field: "SQLite.textByteCount")
        let result = bytes.withUnsafeBufferPointer {
            sqlite3_bind_text(
                statement,
                index,
                $0.baseAddress,
                length,
                remoteSyncAISettingsWriterSQLiteTransient
            )
        }
        guard result == SQLITE_OK else {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
        }
    }

    /** Binds nullable UTF-8 text while preserving nil versus empty. */
    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
            }
            return
        }
        try bindText(value, to: statement, index: index)
    }

    /** Binds an Android Kotlin `Int` after exact signed-32-bit validation. */
    private func bindInt32(
        _ value: Int,
        field: String,
        to statement: OpaquePointer?,
        index: Int32
    ) throws {
        let wireValue = try RemoteSyncWireInteger.int32(exactly: value, field: field)
        guard sqlite3_bind_int(statement, index, wireValue) == SQLITE_OK else {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
        }
    }

    /** Binds a nullable Android Kotlin `Int` after exact signed-32-bit validation. */
    private func bindOptionalInt32(
        _ value: Int?,
        field: String,
        to statement: OpaquePointer?,
        index: Int32
    ) throws {
        guard let value else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
            }
            return
        }
        try bindInt32(value, field: field, to: statement, index: index)
    }

    /** Binds one Android Kotlin `Long` without narrowing. */
    private func bindInt64(_ value: Int64, to statement: OpaquePointer?, index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
        }
    }

    /** Binds one finite Android REAL value. */
    private func bindDouble(_ value: Double, to statement: OpaquePointer?, index: Int32) throws {
        guard value.isFinite, sqlite3_bind_double(statement, index, value) == SQLITE_OK else {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
        }
    }

    /** Binds one Boolean as Android's exact INTEGER 0 or 1 representation. */
    private func bindBool(_ value: Bool, to statement: OpaquePointer?, index: Int32) throws {
        guard sqlite3_bind_int(statement, index, value ? 1 : 0) == SQLITE_OK else {
            throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
        }
    }

    /** Binds one typed Android sync identity without normalizing its SQLite storage class. */
    private func bindSQLiteValue(
        _ value: RemoteSyncSQLiteValue,
        to statement: OpaquePointer?,
        index: Int32
    ) throws {
        switch value.kind {
        case .null:
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
            }
        case .integer:
            guard let payload = value.integerValue else {
                throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
            }
            try bindInt64(payload, to: statement, index: index)
        case .real:
            guard let payload = value.realValue, payload.isFinite else {
                throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
            }
            try bindDouble(payload, to: statement, index: index)
        case .text:
            guard let payload = value.textValue else {
                throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
            }
            try bindText(payload, to: statement, index: index)
        case .blob:
            guard let payload = value.blobData else {
                throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
            }
            let length = try RemoteSyncWireInteger.int32(
                exactly: payload.count,
                field: "LogEntry.identityByteCount"
            )
            let result = payload.withUnsafeBytes {
                sqlite3_bind_blob(
                    statement,
                    index,
                    $0.baseAddress,
                    length,
                    remoteSyncAISettingsWriterSQLiteTransient
                )
            }
            guard result == SQLITE_OK else {
                throw RemoteSyncAISettingsDatabaseWriterError.invalidSQLiteDatabase
            }
        }
    }

    private static func providerSort(
        _ lhs: RemoteSyncAndroidAIProvider,
        _ rhs: RemoteSyncAndroidAIProvider
    ) -> Bool {
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func configuredModelSort(
        _ lhs: RemoteSyncAndroidAIConfiguredModel,
        _ rhs: RemoteSyncAndroidAIConfiguredModel
    ) -> Bool {
        if lhs.providerConfigId != rhs.providerConfigId {
            return lhs.providerConfigId.uuidString < rhs.providerConfigId.uuidString
        }
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        if lhs.modelId != rhs.modelId { return lhs.modelId < rhs.modelId }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func promptSort(
        _ lhs: RemoteSyncAndroidAIAgentPrompt,
        _ rhs: RemoteSyncAndroidAIAgentPrompt
    ) -> Bool {
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func usageSort(
        _ lhs: RemoteSyncAndroidAIUsageRecord,
        _ rhs: RemoteSyncAndroidAIUsageRecord
    ) -> Bool {
        if lhs.configuredModelId != rhs.configuredModelId {
            return lhs.configuredModelId.uuidString < rhs.configuredModelId.uuidString
        }
        if lhs.deviceId != rhs.deviceId { return lhs.deviceId < rhs.deviceId }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func categorySort(
        _ lhs: RemoteSyncAndroidAIPromptCategory,
        _ rhs: RemoteSyncAndroidAIPromptCategory
    ) -> Bool {
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
