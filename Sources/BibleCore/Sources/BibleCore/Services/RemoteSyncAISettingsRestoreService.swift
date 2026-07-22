// RemoteSyncAISettingsRestoreService.swift -- Validated Android v23 AI settings restore

import Foundation
import SQLite3
import SwiftData

/**
 Fail-closed errors raised while decoding or replacing Android AI settings.

 Exact schema, Room identity, version, trigger, and bounded-value failures are surfaced directly as
 `RemoteSyncAndroidDatabaseContractError`; this error type covers row materialization and semantic
 graph invariants that remain after the shared contract validator succeeds.
 */
public enum RemoteSyncAISettingsRestoreError: Error, Equatable {
    /// The staged file could not be opened or stepped as a readable SQLite database.
    case invalidSQLiteDatabase

    /// A required column used an unexpected storage class or invalid UTF-8 representation.
    case invalidColumnValue(table: String, column: String)

    /// A UUID column was not an exact 16-byte Android BLOB.
    case invalidIdentifierBlob(table: String, column: String)

    /// More than one row used the same Android table primary key.
    case duplicateIdentifier(table: String, id: UUID)

    /// More than one row used an Android unique composite identity.
    case duplicateCompositeIdentity(table: String, first: String, second: String)

    /// More than one Android global settings singleton row was present.
    case duplicateGlobalSettings

    /// A present global settings row did not use Android's fixed singleton UUID.
    case invalidGlobalSettingsIdentity(UUID)

    /// A row violated one of Android Room's declared foreign keys.
    case orphanFormalReference(table: String, id: UUID, parentTable: String, parentID: UUID)

    /// A synchronized provider endpoint could contain URL-carried credentials or secret material.
    case unsafeSynchronizedEndpoint(providerID: UUID)

    /// A SQLite REAL decoded to a non-finite value that SwiftData must not persist.
    case invalidFloatingPointValue(table: String, id: UUID)
}

/**
 Materialized, credential-free contents of one Android `AiSettingsDatabase` v23 file.

 Only Android's seven `AI_SETTINGS` sync tables are represented. Full Android initial backups can
 contain device-local `LlmRawLogRecord` rows because Android copies the complete Room file; iOS
 counts and ignores those rows. API credentials have no Room column and no property here. Raw
 Room-converter strings remain byte-for-byte UTF-8-equivalent to their SQLite values.
 */
public struct RemoteSyncAndroidAISettingsSnapshot: Sendable, Equatable {
    /// Android `LlmProviderConfig` rows without API keys.
    public let providers: [RemoteSyncAndroidAIProvider]

    /// Android `LlmConfiguredModel` rows.
    public let configuredModels: [RemoteSyncAndroidAIConfiguredModel]

    /// Android `AgentPrompt` rows with raw converter strings preserved.
    public let agentPrompts: [RemoteSyncAndroidAIAgentPrompt]

    /// Zero or one Android global settings singleton row.
    public let globalSettings: [RemoteSyncAndroidGlobalAISettings]

    /// Android per-device model usage rows.
    public let usageRecords: [RemoteSyncAndroidAIUsageRecord]

    /// Android user-defined prompt category rows.
    public let promptCategories: [RemoteSyncAndroidAIPromptCategory]

    /// Android built-in prompt model overrides.
    public let builtinOverrides: [RemoteSyncAndroidAIBuiltinPromptOverride]

    /// Number of bounded incoming device-local raw logs deliberately omitted from the snapshot.
    public let ignoredIncomingRawLogCount: Int

    /**
     Creates a typed Android AI settings restore generation.

     - Parameters:
       - providers: Non-secret provider configuration rows.
       - configuredModels: Provider-owned configured model rows.
       - agentPrompts: User prompt rows.
       - globalSettings: Zero or one fixed-identity singleton row.
       - usageRecords: Per-device usage rows.
       - promptCategories: User category rows.
       - builtinOverrides: Built-in prompt override rows.
       - ignoredIncomingRawLogCount: Bounded incoming raw-log count omitted from materialization.
     - Side Effects: none.
     - Failure modes: This initializer does not validate; restore entry points validate all identities,
       unique composites, finite values, and formal foreign keys before mutation.
     */
    public init(
        providers: [RemoteSyncAndroidAIProvider],
        configuredModels: [RemoteSyncAndroidAIConfiguredModel],
        agentPrompts: [RemoteSyncAndroidAIAgentPrompt],
        globalSettings: [RemoteSyncAndroidGlobalAISettings],
        usageRecords: [RemoteSyncAndroidAIUsageRecord],
        promptCategories: [RemoteSyncAndroidAIPromptCategory],
        builtinOverrides: [RemoteSyncAndroidAIBuiltinPromptOverride],
        ignoredIncomingRawLogCount: Int = 0
    ) {
        self.providers = providers
        self.configuredModels = configuredModels
        self.agentPrompts = agentPrompts
        self.globalSettings = globalSettings
        self.usageRecords = usageRecords
        self.promptCategories = promptCategories
        self.builtinOverrides = builtinOverrides
        self.ignoredIncomingRawLogCount = ignoredIncomingRawLogCount
    }
}

/** Counts produced by one successful atomic AI settings replacement. */
public struct RemoteSyncAISettingsRestoreReport: Sendable, Equatable {
    /// Number of non-secret provider rows restored.
    public let restoredProviderCount: Int

    /// Number of configured-model rows restored.
    public let restoredConfiguredModelCount: Int

    /// Number of agent-prompt rows restored.
    public let restoredAgentPromptCount: Int

    /// Number of global-settings singleton rows restored.
    public let restoredGlobalSettingsCount: Int

    /// Number of per-device usage rows restored.
    public let restoredUsageRecordCount: Int

    /// Number of prompt-category rows restored.
    public let restoredPromptCategoryCount: Int

    /// Number of built-in prompt override rows restored.
    public let restoredBuiltinPromptOverrideCount: Int

    /// Number of bounded Android raw-log rows ignored during materialization.
    public let ignoredIncomingRawLogCount: Int

    /// Number of local iOS raw-log rows left untouched by the replacement.
    public let preservedLocalRawLogCount: Int
}

/**
 Reads authenticated Android AI settings Room generations and atomically replaces iOS's synchronized
 AI models.

 Read behavior:
 - migrates supported writable staged predecessors through Android's production chain
 - opens the resulting SQLite file read-only
 - validates the complete v23 Room schema, identity hash, runtime trigger set, storage classes, and
   allocation bounds through `RemoteSyncAndroidDatabaseContract`
 - materializes only the seven Android `AI_SETTINGS` tables
 - rejects malformed UUIDs, duplicate primary or composite identities, non-finite REALs, and missing
   parents for Room-declared foreign keys
 - preserves Android's deliberately logical dangling references for prompt categories, global default
   models, and usage model identities
 - bounds and counts `LlmRawLogRecord` rows from Android full-database backups but never decodes or
   imports them
 - rejects provider endpoints containing credential-bearing URL components
 - never accepts a credential input

 Replace behavior:
 - captures the existing seven-model durable generation before mutation
 - deletes and recreates only those seven SwiftData model sets
 - commits through `SettingsStore.performAtomicBatch(in:durableRecovery:_:)`
 - leaves every local `LLMRawLogRecord` and Keychain credential untouched
 - restores the prior durable generation through a fresh context if a multi-store commit partially lands

 Failure modes:
 - no SwiftData mutation begins until the complete incoming graph passes validation
 - schema and payload contract failures propagate as `RemoteSyncAndroidDatabaseContractError`
 - decode, identity, foreign-key, fetch, cancellation, save, and durable recovery failures are rethrown

 Concurrency:
 - the service is not `Sendable`; callers must respect the supplied `ModelContext` confinement
 - the settings store must own the exact clean context passed to replacement
 */
public final class RemoteSyncAISettingsRestoreService {
    /// Exact Android `AiSettingsDatabase` generation accepted by this reader.
    public static let supportedAndroidSchemaVersion = 23

    /**
     Creates an AI settings restore service.

     - Side Effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init() {}

    /**
     Reads and validates one staged Android `ai_settings.sqlite3` database.

     - Parameters:
       - databaseURL: Local file URL for the uncompressed Android Room database.
       - expectedSourceVersion: Archive-declared Room generation, or `nil` when the staged file is
         the only source of version authority.
     - Returns: Deterministically ordered rows from only the seven synchronized AI tables, plus the
       bounded count of Android raw-log rows deliberately ignored by iOS.
     - Side Effects:
       - migrates the writable staged copy through Android's supported Room chain when needed
       - validates the complete Room v23 schema and row-storage contract
       - opens the validated staged SQLite database read-only for decoding
     - Throws:
       - migration errors for unsupported, mismatched, or unopenable source generations
       - `RemoteSyncAndroidDatabaseContractError` for noncanonical or out-of-bounds files
       - `RemoteSyncAISettingsRestoreError` for SQLite stepping, malformed UTF-8/UUID values,
         duplicate identities, credential-bearing endpoints, non-finite values, or formal
         foreign-key orphans
     */
    public func readSnapshot(
        from databaseURL: URL,
        expectedSourceVersion: Int? = nil
    ) throws -> RemoteSyncAndroidAISettingsSnapshot {
        try readSnapshot(
            from: databaseURL,
            expectedSourceVersion: expectedSourceVersion,
            requiresCompleteFormalReferences: true
        )
    }

    /**
     Reads one sparse Android AI settings patch without requiring unchanged parent rows in the file.

     Patch databases carry only rows named by their `LogEntry` operations. Formal references are
     therefore validated against the materialized local-plus-patch graph immediately before publish,
     rather than against this intentionally incomplete snapshot.

     - Parameters:
       - databaseURL: Local file URL for the uncompressed Android Room patch database.
       - expectedSourceVersion: Patch-filename Room generation, or `nil` when the staged file is the
         only source of version authority.
     - Returns: Deterministically ordered rows from the seven synchronized AI tables.
     - Side Effects: Migrates and validates the writable staged copy, then opens it read-only for
       deterministic row decoding; no local app persistence is mutated.
     - Throws: Rethrows exact schema, bounds, row decoding, identity, endpoint, and numeric errors.
     */
    func readSparsePatchSnapshot(
        from databaseURL: URL,
        expectedSourceVersion: Int? = nil
    ) throws -> RemoteSyncAndroidAISettingsSnapshot {
        try readSnapshot(
            from: databaseURL,
            expectedSourceVersion: expectedSourceVersion,
            requiresCompleteFormalReferences: false
        )
    }

    /** Reads one full or sparse Android AI database under the requested graph-validation policy. */
    private func readSnapshot(
        from databaseURL: URL,
        expectedSourceVersion: Int?,
        requiresCompleteFormalReferences: Bool
    ) throws -> RemoteSyncAndroidAISettingsSnapshot {
        try RemoteSyncAISettingsDatabaseMigrator.migrateAndValidateStagedDatabase(
            at: databaseURL,
            expectedSourceVersion: expectedSourceVersion
        )

        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RemoteSyncAISettingsRestoreError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        guard RemoteSyncAndroidDatabaseContract.schemaVersion(for: .aiSettings)
            == Self.supportedAndroidSchemaVersion else {
            throw RemoteSyncAISettingsRestoreError.invalidSQLiteDatabase
        }
        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(database, category: .aiSettings)

        let snapshot = RemoteSyncAndroidAISettingsSnapshot(
            providers: try fetchProviders(from: database),
            configuredModels: try fetchConfiguredModels(from: database),
            agentPrompts: try fetchAgentPrompts(from: database),
            globalSettings: try fetchGlobalSettings(from: database),
            usageRecords: try fetchUsageRecords(from: database),
            promptCategories: try fetchPromptCategories(from: database),
            builtinOverrides: try fetchBuiltinPromptOverrides(from: database),
            ignoredIncomingRawLogCount: try rowCount(in: "LlmRawLogRecord", database: database)
        )
        try Self.validate(
            snapshot,
            requiresCompleteFormalReferences: requiresCompleteFormalReferences
        )
        return Self.sorted(snapshot)
    }

    /**
     Reads one staged database and atomically replaces the seven synchronized local AI model sets.

     - Parameters:
       - databaseURL: Local file URL for an authenticated Android Room generation supported by the
         production migration chain.
       - modelContext: Clean context containing AI models and the settings store's local configuration.
       - settingsStore: Store created with the exact same context.
     - Returns: Counts for all restored, ignored, and preserved model groups.
     - Side Effects: Performs one read-only SQLite pass followed by one atomic SwiftData replacement.
     - Throws: Rethrows every read, validation, context-contract, cancellation, save, or durable
       recovery failure. Local synchronized rows and raw logs remain unchanged on failure.
     */
    public func restore(
        from databaseURL: URL,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncAISettingsRestoreReport {
        let snapshot = try readSnapshot(from: databaseURL)
        return try replaceLocalAISettings(
            from: snapshot,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
    }

    /**
     Atomically replaces all seven synchronized AI model sets with one validated generation.

     The method is suitable for initial restore and for a fully reconciled patch generation. Local raw
     model logs are counted but never deleted, inserted, or decoded. Provider credentials remain in the
     separate device-local credential store and are neither removed nor overwritten.

     - Parameters:
       - snapshot: Complete Android-shaped generation to publish.
       - modelContext: Exact clean context shared by the AI models and `settingsStore`.
       - settingsStore: Settings store that owns `modelContext` and the atomic commit boundary.
     - Returns: Typed counts after the outer transaction commits successfully.
     - Side Effects: Deletes and recreates only the seven synchronized SwiftData model sets and saves
       through one settings-backed atomic transaction.
     - Throws: Identity, composite, formal-reference, fetch, context, cancellation, save, or durable
       recovery errors. Any failed publication restores the previous durable generation.
     */
    public func replaceLocalAISettings(
        from snapshot: RemoteSyncAndroidAISettingsSnapshot,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncAISettingsRestoreReport {
        try Self.validate(snapshot, requiresCompleteFormalReferences: true)
        let durableGraph = try Self.captureDurableGraph(from: modelContext)
        let preservedRawLogCount = try modelContext.fetchCount(FetchDescriptor<LLMRawLogRecord>())

        return try settingsStore.performAtomicBatch(
            in: modelContext,
            durableRecovery: { container in
                try Self.restoreDurableGraph(durableGraph, in: container)
            }
        ) {
            try Task.checkCancellation()
            try Self.stage(snapshot, in: modelContext)
            try Task.checkCancellation()
            return Self.report(
                for: snapshot,
                preservedLocalRawLogCount: preservedRawLogCount
            )
        }
    }

    /** Store-independent value generation used only for partial-commit compensation. */
    private struct DurableGraph: Equatable {
        let providers: [RemoteSyncAndroidAIProvider]
        let configuredModels: [RemoteSyncAndroidAIConfiguredModel]
        let agentPrompts: [RemoteSyncAndroidAIAgentPrompt]
        let globalSettings: [RemoteSyncAndroidGlobalAISettings]
        let usageRecords: [RemoteSyncAndroidAIUsageRecord]
        let promptCategories: [RemoteSyncAndroidAIPromptCategory]
        let builtinPromptOverrides: [RemoteSyncAndroidAIBuiltinPromptOverride]
    }

    /** Builds a successful restore report without querying or mutating persistence. */
    private static func report(
        for snapshot: RemoteSyncAndroidAISettingsSnapshot,
        preservedLocalRawLogCount: Int
    ) -> RemoteSyncAISettingsRestoreReport {
        RemoteSyncAISettingsRestoreReport(
            restoredProviderCount: snapshot.providers.count,
            restoredConfiguredModelCount: snapshot.configuredModels.count,
            restoredAgentPromptCount: snapshot.agentPrompts.count,
            restoredGlobalSettingsCount: snapshot.globalSettings.count,
            restoredUsageRecordCount: snapshot.usageRecords.count,
            restoredPromptCategoryCount: snapshot.promptCategories.count,
            restoredBuiltinPromptOverrideCount: snapshot.builtinOverrides.count,
            ignoredIncomingRawLogCount: snapshot.ignoredIncomingRawLogCount,
            preservedLocalRawLogCount: preservedLocalRawLogCount
        )
    }

    /**
     Validates identities and graph semantics not already enforced by the shared SQLite contract.

     Android's logical references intentionally remain unchecked. Formal Room references are checked
     against the complete staged generation and cause the entire restore to fail before mutation.
     */
    private static func validate(
        _ snapshot: RemoteSyncAndroidAISettingsSnapshot,
        requiresCompleteFormalReferences: Bool = true
    ) throws {
        try requireUniqueIDs(snapshot.providers, table: "LlmProviderConfig", id: \.id)
        try requireUniqueIDs(snapshot.configuredModels, table: "LlmConfiguredModel", id: \.id)
        try requireUniqueIDs(snapshot.agentPrompts, table: "AgentPrompt", id: \.id)
        try requireUniqueIDs(snapshot.globalSettings, table: "GlobalAiSettings", id: \.id)
        try requireUniqueIDs(snapshot.usageRecords, table: "LlmUsageRecord", id: \.id)
        try requireUniqueIDs(snapshot.promptCategories, table: "PromptCategory", id: \.id)
        try requireUniqueIDs(snapshot.builtinOverrides, table: "BuiltinPromptOverride", id: \.id)

        for row in snapshot.providers {
            guard RemoteSyncAISettingsEndpointPolicy.isCredentialFree(row.endpoint) else {
                throw RemoteSyncAISettingsRestoreError.unsafeSynchronizedEndpoint(
                    providerID: row.id
                )
            }
        }

        guard snapshot.globalSettings.count <= 1 else {
            throw RemoteSyncAISettingsRestoreError.duplicateGlobalSettings
        }
        if let global = snapshot.globalSettings.first, global.id != GlobalAISettings.singletonID {
            throw RemoteSyncAISettingsRestoreError.invalidGlobalSettingsIdentity(global.id)
        }
        try requireUniqueComposite(
            snapshot.configuredModels,
            table: "LlmConfiguredModel",
            first: { $0.providerConfigId.uuidString.lowercased() },
            second: \.modelId
        )
        try requireUniqueComposite(
            snapshot.usageRecords,
            table: "LlmUsageRecord",
            first: { $0.configuredModelId.uuidString.lowercased() },
            second: \.deviceId
        )

        if requiresCompleteFormalReferences {
            let providerIDs = Set(snapshot.providers.map(\.id))
            let configuredModelIDs = Set(snapshot.configuredModels.map(\.id))
            for row in snapshot.configuredModels where !providerIDs.contains(row.providerConfigId) {
                throw RemoteSyncAISettingsRestoreError.orphanFormalReference(
                    table: "LlmConfiguredModel",
                    id: row.id,
                    parentTable: "LlmProviderConfig",
                    parentID: row.providerConfigId
                )
            }
            for row in snapshot.agentPrompts {
                if let parentID = row.configuredModelId, !configuredModelIDs.contains(parentID) {
                    throw RemoteSyncAISettingsRestoreError.orphanFormalReference(
                        table: "AgentPrompt",
                        id: row.id,
                        parentTable: "LlmConfiguredModel",
                        parentID: parentID
                    )
                }
            }
            for row in snapshot.builtinOverrides {
                if let parentID = row.configuredModelId, !configuredModelIDs.contains(parentID) {
                    throw RemoteSyncAISettingsRestoreError.orphanFormalReference(
                        table: "BuiltinPromptOverride",
                        id: row.id,
                        parentTable: "LlmConfiguredModel",
                        parentID: parentID
                    )
                }
            }
        }
        for row in snapshot.configuredModels where !row.inputPricePerMillion.isFinite
            || !row.outputPricePerMillion.isFinite
            || !row.cacheCreationPricePerMillion.isFinite
            || !row.cacheReadPricePerMillion.isFinite {
            throw RemoteSyncAISettingsRestoreError.invalidFloatingPointValue(
                table: "LlmConfiguredModel",
                id: row.id
            )
        }
        for row in snapshot.usageRecords where !row.estimatedCostUsd.isFinite {
            throw RemoteSyncAISettingsRestoreError.invalidFloatingPointValue(
                table: "LlmUsageRecord",
                id: row.id
            )
        }
    }

    /** Rejects repeated primary UUIDs without relying on a trapping dictionary initializer. */
    private static func requireUniqueIDs<Row>(
        _ rows: [Row],
        table: String,
        id: (Row) -> UUID
    ) throws {
        var seen: Set<UUID> = []
        for row in rows {
            let value = id(row)
            guard seen.insert(value).inserted else {
                throw RemoteSyncAISettingsRestoreError.duplicateIdentifier(table: table, id: value)
            }
        }
    }

    /** Rejects repeated unique-index pairs using a length-delimited identity key. */
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
                throw RemoteSyncAISettingsRestoreError.duplicateCompositeIdentity(
                    table: table,
                    first: firstValue,
                    second: secondValue
                )
            }
        }
    }

    /** Captures the exact synchronized local generation without reading raw logs or credentials. */
    private static func captureDurableGraph(from modelContext: ModelContext) throws -> DurableGraph {
        DurableGraph(
            providers: try modelContext.fetch(FetchDescriptor<LLMProviderConfig>()).map(providerRow).sorted(by: providerSort),
            configuredModels: try modelContext.fetch(FetchDescriptor<LLMConfiguredModel>()).map(configuredModelRow).sorted(by: configuredModelSort),
            agentPrompts: try modelContext.fetch(FetchDescriptor<AgentPrompt>()).map(agentPromptRow).sorted(by: promptSort),
            globalSettings: try modelContext.fetch(FetchDescriptor<GlobalAISettings>()).map(globalSettingsRow).sorted { $0.id.uuidString < $1.id.uuidString },
            usageRecords: try modelContext.fetch(FetchDescriptor<LLMUsageRecord>()).map(usageRow).sorted(by: usageSort),
            promptCategories: try modelContext.fetch(FetchDescriptor<PromptCategory>()).map(promptCategoryRow).sorted(by: categorySort),
            builtinPromptOverrides: try modelContext.fetch(FetchDescriptor<BuiltInPromptOverride>()).map(builtinOverrideRow).sorted { $0.id.uuidString < $1.id.uuidString }
        )
    }

    /** Restores a partially committed old generation through a fresh graph-only context. */
    private static func restoreDurableGraph(
        _ expected: DurableGraph,
        in container: ModelContainer
    ) throws {
        let recoveryContext = ModelContext(container)
        recoveryContext.autosaveEnabled = false
        let current = try captureDurableGraph(from: recoveryContext)
        guard current != expected else { return }

        let snapshot = RemoteSyncAndroidAISettingsSnapshot(
            providers: expected.providers,
            configuredModels: expected.configuredModels,
            agentPrompts: expected.agentPrompts,
            globalSettings: expected.globalSettings,
            usageRecords: expected.usageRecords,
            promptCategories: expected.promptCategories,
            builtinOverrides: expected.builtinPromptOverrides
        )
        try stage(snapshot, in: recoveryContext, checksCancellation: false)
        try recoveryContext.save()
    }

    /**
     Stages one complete seven-model replacement without saving.

     - Parameters:
       - snapshot: Prevalidated synchronized generation.
       - modelContext: Context receiving delete and insert operations.
       - checksCancellation: Whether destructive loops should observe cooperative cancellation.
     - Side Effects: Deletes and inserts only synchronized AI models; raw logs remain untouched.
     - Throws: Rethrows fetch failures and, when enabled, `CancellationError`.
     - Important: The caller owns the save or rollback boundary.
     */
    private static func stage(
        _ snapshot: RemoteSyncAndroidAISettingsSnapshot,
        in modelContext: ModelContext,
        checksCancellation: Bool = true
    ) throws {
        let existingPrompts = try modelContext.fetch(FetchDescriptor<AgentPrompt>())
        let existingOverrides = try modelContext.fetch(FetchDescriptor<BuiltInPromptOverride>())
        let existingUsage = try modelContext.fetch(FetchDescriptor<LLMUsageRecord>())
        let existingGlobalSettings = try modelContext.fetch(FetchDescriptor<GlobalAISettings>())
        let existingConfiguredModels = try modelContext.fetch(FetchDescriptor<LLMConfiguredModel>())
        let existingCategories = try modelContext.fetch(FetchDescriptor<PromptCategory>())
        let existingProviders = try modelContext.fetch(FetchDescriptor<LLMProviderConfig>())

        for row in existingPrompts { modelContext.delete(row); try cancellationCheck(checksCancellation) }
        for row in existingOverrides { modelContext.delete(row); try cancellationCheck(checksCancellation) }
        for row in existingUsage { modelContext.delete(row); try cancellationCheck(checksCancellation) }
        for row in existingGlobalSettings { modelContext.delete(row); try cancellationCheck(checksCancellation) }
        for row in existingConfiguredModels { modelContext.delete(row); try cancellationCheck(checksCancellation) }
        for row in existingCategories { modelContext.delete(row); try cancellationCheck(checksCancellation) }
        for row in existingProviders { modelContext.delete(row); try cancellationCheck(checksCancellation) }

        for row in snapshot.providers {
            modelContext.insert(providerModel(row))
            try cancellationCheck(checksCancellation)
        }
        for row in snapshot.configuredModels {
            modelContext.insert(configuredModel(row))
            try cancellationCheck(checksCancellation)
        }
        for row in snapshot.promptCategories {
            modelContext.insert(promptCategoryModel(row))
            try cancellationCheck(checksCancellation)
        }
        for row in snapshot.agentPrompts {
            modelContext.insert(agentPromptModel(row))
            try cancellationCheck(checksCancellation)
        }
        for row in snapshot.globalSettings {
            modelContext.insert(globalSettingsModel(row))
            try cancellationCheck(checksCancellation)
        }
        for row in snapshot.usageRecords {
            modelContext.insert(usageModel(row))
            try cancellationCheck(checksCancellation)
        }
        for row in snapshot.builtinOverrides {
            modelContext.insert(builtinOverrideModel(row))
            try cancellationCheck(checksCancellation)
        }
    }

    /** Performs an optional cooperative cancellation check between destructive mutations. */
    private static func cancellationCheck(_ enabled: Bool) throws {
        if enabled { try Task.checkCancellation() }
    }

    /** Builds a SwiftData provider while retaining unknown raw Android enum values verbatim. */
    private static func providerModel(_ row: RemoteSyncAndroidAIProvider) -> LLMProviderConfig {
        let model = LLMProviderConfig(
            id: row.id,
            provider: LLMProvider(rawValue: row.providerType) ?? .custom,
            displayName: row.displayName,
            endpoint: row.endpoint,
            apiFormat: row.apiFormat.flatMap(APIFormat.init(rawValue:)),
            orderNumber: row.orderNumber
        )
        model.providerType = row.providerType
        model.endpoint = row.endpoint
        model.apiFormatRawValue = row.apiFormat
        return model
    }

    /** Builds a SwiftData configured-model row with exact pricing values. */
    private static func configuredModel(_ row: RemoteSyncAndroidAIConfiguredModel) -> LLMConfiguredModel {
        LLMConfiguredModel(
            id: row.id,
            providerConfigId: row.providerConfigId,
            modelId: row.modelId,
            orderNumber: row.orderNumber,
            inputPricePerMillion: row.inputPricePerMillion,
            outputPricePerMillion: row.outputPricePerMillion,
            cacheCreationPricePerMillion: row.cacheCreationPricePerMillion,
            cacheReadPricePerMillion: row.cacheReadPricePerMillion
        )
    }

    /** Builds a SwiftData prompt and then restores every raw converter string without normalization. */
    private static func agentPromptModel(_ row: RemoteSyncAndroidAIAgentPrompt) -> AgentPrompt {
        let model = AgentPrompt(
            id: row.id,
            name: row.name,
            description: row.promptDescription,
            promptTemplate: row.promptTemplate,
            orderNumber: row.orderNumber,
            createdAtMilliseconds: row.createdAt,
            strictContextMatching: row.strictContextMatching,
            configuredModelId: row.configuredModelId,
            specifyBeforeRun: row.editBeforeRun,
            noDocumentCreation: row.noDocumentCreation,
            maxIterations: row.maxIterations,
            autoIncludeDocuments: row.autoIncludeDocuments,
            autoIncludeCommentaries: row.autoIncludeCommentaries,
            bibleOnly: row.bibleOnly,
            isTextTransformation: row.isTextTransformation,
            categoryId: row.categoryId
        )
        model.showInRawValue = row.showIn
        model.permissionModeRawValue = row.permissionMode
        model.allowedToolsRawValue = row.allowedTools
        model.deniedToolsRawValue = row.deniedTools
        return model
    }

    /** Builds Android's global singleton and preserves all raw converter payloads verbatim. */
    private static func globalSettingsModel(_ row: RemoteSyncAndroidGlobalAISettings) -> GlobalAISettings {
        let model = GlobalAISettings(id: row.id)
        model.agentPermissionModeRawValue = row.agentPermissionMode
        model.permanentlyAllowedToolsRawValue = row.permanentlyAllowedTools
        model.permanentlyDeniedToolsRawValue = row.permanentlyDeniedTools
        model.aiExcludedDocumentsRawValue = row.aiExcludedDocuments
        model.commentaryMaxResponseTokens = row.commentaryMaxResponseTokens
        model.hiddenBuiltInPromptsRawValue = row.hiddenBuiltInPrompts
        model.maxIterations = row.maxIterations
        model.commentaryDeselectedRawValue = row.commentaryDeselected
        model.defaultModelId = row.defaultModelId
        model.aiLanguage = row.aiLanguage
        model.askModelBeforeRun = row.askModelBeforeRun
        model.aiDisclaimerAccepted = row.aiDisclaimerAccepted
        model.hiddenBuiltInCategoriesRawValue = row.hiddenBuiltInCategories
        model.customAgentSystemPrompt = row.customAgentSystemPrompt
        model.customTextTransformationSystemPrompt = row.customTextTransformationSystemPrompt
        model.favoritePromptsRawValue = row.favoritePrompts
        model.rawLogRetentionDays = row.rawLogRetentionDays
        model.autoHideAgentLogOnCompletion = row.autoHideAgentLogOnCompletion
        return model
    }

    /** Builds one SwiftData per-device cumulative usage row. */
    private static func usageModel(_ row: RemoteSyncAndroidAIUsageRecord) -> LLMUsageRecord {
        let model = LLMUsageRecord(
            id: row.id,
            configuredModelId: row.configuredModelId,
            deviceId: row.deviceId
        )
        model.inputTokens = row.inputTokens
        model.outputTokens = row.outputTokens
        model.cacheCreationTokens = row.cacheCreationTokens
        model.cacheReadTokens = row.cacheReadTokens
        model.estimatedCostUSD = row.estimatedCostUsd
        return model
    }

    /** Builds one SwiftData user prompt-category row. */
    private static func promptCategoryModel(_ row: RemoteSyncAndroidAIPromptCategory) -> PromptCategory {
        PromptCategory(id: row.id, name: row.name, orderNumber: row.orderNumber, hidden: row.hidden)
    }

    /** Builds one SwiftData built-in prompt override row. */
    private static func builtinOverrideModel(
        _ row: RemoteSyncAndroidAIBuiltinPromptOverride
    ) -> BuiltInPromptOverride {
        BuiltInPromptOverride(id: row.id, configuredModelId: row.configuredModelId)
    }

    /** Projects one local provider into its credential-free Android wire row. */
    private static func providerRow(_ value: LLMProviderConfig) -> RemoteSyncAndroidAIProvider {
        RemoteSyncAndroidAIProvider(
            id: value.id,
            providerType: value.providerType,
            displayName: value.displayName,
            endpoint: value.endpoint,
            apiFormat: value.apiFormatRawValue,
            orderNumber: value.orderNumber
        )
    }

    /** Projects one local configured model into its exact Android wire row. */
    private static func configuredModelRow(
        _ value: LLMConfiguredModel
    ) -> RemoteSyncAndroidAIConfiguredModel {
        RemoteSyncAndroidAIConfiguredModel(
            id: value.id,
            providerConfigId: value.providerConfigId,
            modelId: value.modelId,
            orderNumber: value.orderNumber,
            inputPricePerMillion: value.inputPricePerMillion,
            outputPricePerMillion: value.outputPricePerMillion,
            cacheCreationPricePerMillion: value.cacheCreationPricePerMillion,
            cacheReadPricePerMillion: value.cacheReadPricePerMillion
        )
    }

    /** Projects one local prompt without decoding or re-encoding Room converter strings. */
    private static func agentPromptRow(_ value: AgentPrompt) -> RemoteSyncAndroidAIAgentPrompt {
        RemoteSyncAndroidAIAgentPrompt(
            id: value.id,
            name: value.name,
            promptDescription: value.promptDescription,
            promptTemplate: value.promptTemplate,
            showIn: value.showInRawValue,
            orderNumber: value.orderNumber,
            createdAt: value.createdAtMilliseconds,
            strictContextMatching: value.strictContextMatching,
            permissionMode: value.permissionModeRawValue,
            allowedTools: value.allowedToolsRawValue,
            deniedTools: value.deniedToolsRawValue,
            configuredModelId: value.configuredModelId,
            editBeforeRun: value.specifyBeforeRun,
            noDocumentCreation: value.noDocumentCreation,
            maxIterations: value.maxIterations,
            autoIncludeDocuments: value.autoIncludeDocuments,
            autoIncludeCommentaries: value.autoIncludeCommentaries,
            bibleOnly: value.bibleOnly,
            isTextTransformation: value.isTextTransformation,
            categoryId: value.categoryId
        )
    }

    /** Projects one local global singleton without normalizing raw converter strings. */
    private static func globalSettingsRow(
        _ value: GlobalAISettings
    ) -> RemoteSyncAndroidGlobalAISettings {
        RemoteSyncAndroidGlobalAISettings(
            id: value.id,
            agentPermissionMode: value.agentPermissionModeRawValue,
            permanentlyAllowedTools: value.permanentlyAllowedToolsRawValue,
            permanentlyDeniedTools: value.permanentlyDeniedToolsRawValue,
            aiExcludedDocuments: value.aiExcludedDocumentsRawValue,
            commentaryMaxResponseTokens: value.commentaryMaxResponseTokens,
            hiddenBuiltInPrompts: value.hiddenBuiltInPromptsRawValue,
            maxIterations: value.maxIterations,
            commentaryDeselected: value.commentaryDeselectedRawValue,
            defaultModelId: value.defaultModelId,
            aiLanguage: value.aiLanguage,
            askModelBeforeRun: value.askModelBeforeRun,
            aiDisclaimerAccepted: value.aiDisclaimerAccepted,
            hiddenBuiltInCategories: value.hiddenBuiltInCategoriesRawValue,
            customAgentSystemPrompt: value.customAgentSystemPrompt,
            customTextTransformationSystemPrompt: value.customTextTransformationSystemPrompt,
            favoritePrompts: value.favoritePromptsRawValue,
            rawLogRetentionDays: value.rawLogRetentionDays,
            autoHideAgentLogOnCompletion: value.autoHideAgentLogOnCompletion
        )
    }

    /** Projects one local usage row into Android's cumulative per-device wire row. */
    private static func usageRow(_ value: LLMUsageRecord) -> RemoteSyncAndroidAIUsageRecord {
        RemoteSyncAndroidAIUsageRecord(
            id: value.id,
            configuredModelId: value.configuredModelId,
            deviceId: value.deviceId,
            inputTokens: value.inputTokens,
            outputTokens: value.outputTokens,
            cacheCreationTokens: value.cacheCreationTokens,
            cacheReadTokens: value.cacheReadTokens,
            estimatedCostUsd: value.estimatedCostUSD
        )
    }

    /** Projects one local user category into Android's wire row. */
    private static func promptCategoryRow(
        _ value: PromptCategory
    ) -> RemoteSyncAndroidAIPromptCategory {
        RemoteSyncAndroidAIPromptCategory(
            id: value.id,
            name: value.name,
            orderNumber: value.orderNumber,
            hidden: value.hidden
        )
    }

    /** Projects one local built-in override into Android's wire row. */
    private static func builtinOverrideRow(
        _ value: BuiltInPromptOverride
    ) -> RemoteSyncAndroidAIBuiltinPromptOverride {
        RemoteSyncAndroidAIBuiltinPromptOverride(
            id: value.id,
            configuredModelId: value.configuredModelId
        )
    }

    /** Reads every credential-free provider row in deterministic Android display order. */
    private func fetchProviders(from database: OpaquePointer) throws -> [RemoteSyncAndroidAIProvider] {
        let table = "LlmProviderConfig"
        let statement = try prepare(
            "SELECT id, providerType, displayName, endpoint, apiFormat, orderNumber FROM LlmProviderConfig;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var rows: [RemoteSyncAndroidAIProvider] = []
        try forEachRow(statement) {
            rows.append(
                RemoteSyncAndroidAIProvider(
                    id: try uuid(statement, 0, table, "id"),
                    providerType: try text(statement, 1, table, "providerType"),
                    displayName: try text(statement, 2, table, "displayName"),
                    endpoint: try optionalText(statement, 3, table, "endpoint"),
                    apiFormat: try optionalText(statement, 4, table, "apiFormat"),
                    orderNumber: try int(statement, 5, table, "orderNumber")
                )
            )
        }
        return rows
    }

    /** Reads every configured-model row with exact REAL pricing storage. */
    private func fetchConfiguredModels(
        from database: OpaquePointer
    ) throws -> [RemoteSyncAndroidAIConfiguredModel] {
        let table = "LlmConfiguredModel"
        let statement = try prepare(
            "SELECT id, providerConfigId, modelId, orderNumber, inputPricePerMillion, outputPricePerMillion, cacheCreationPricePerMillion, cacheReadPricePerMillion FROM LlmConfiguredModel;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var rows: [RemoteSyncAndroidAIConfiguredModel] = []
        try forEachRow(statement) {
            rows.append(
                RemoteSyncAndroidAIConfiguredModel(
                    id: try uuid(statement, 0, table, "id"),
                    providerConfigId: try uuid(statement, 1, table, "providerConfigId"),
                    modelId: try text(statement, 2, table, "modelId"),
                    orderNumber: try int(statement, 3, table, "orderNumber"),
                    inputPricePerMillion: try real(statement, 4, table, "inputPricePerMillion"),
                    outputPricePerMillion: try real(statement, 5, table, "outputPricePerMillion"),
                    cacheCreationPricePerMillion: try real(statement, 6, table, "cacheCreationPricePerMillion"),
                    cacheReadPricePerMillion: try real(statement, 7, table, "cacheReadPricePerMillion")
                )
            )
        }
        return rows
    }

    /** Reads every agent prompt while preserving all raw Room-converter strings. */
    private func fetchAgentPrompts(
        from database: OpaquePointer
    ) throws -> [RemoteSyncAndroidAIAgentPrompt] {
        let table = "AgentPrompt"
        let statement = try prepare(
            "SELECT id, name, description, promptTemplate, showIn, orderNumber, createdAt, strictContextMatching, permissionMode, allowedTools, deniedTools, configuredModelId, editBeforeRun, noDocumentCreation, maxIterations, autoIncludeDocuments, autoIncludeCommentaries, bibleOnly, isTextTransformation, categoryId FROM AgentPrompt;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var rows: [RemoteSyncAndroidAIAgentPrompt] = []
        try forEachRow(statement) {
            rows.append(
                RemoteSyncAndroidAIAgentPrompt(
                    id: try uuid(statement, 0, table, "id"),
                    name: try text(statement, 1, table, "name"),
                    promptDescription: try optionalText(statement, 2, table, "description"),
                    promptTemplate: try text(statement, 3, table, "promptTemplate"),
                    showIn: try text(statement, 4, table, "showIn"),
                    orderNumber: try int(statement, 5, table, "orderNumber"),
                    createdAt: try int64(statement, 6, table, "createdAt"),
                    strictContextMatching: try bool(statement, 7, table, "strictContextMatching"),
                    permissionMode: try optionalText(statement, 8, table, "permissionMode"),
                    allowedTools: try optionalText(statement, 9, table, "allowedTools"),
                    deniedTools: try optionalText(statement, 10, table, "deniedTools"),
                    configuredModelId: try optionalUUID(statement, 11, table, "configuredModelId"),
                    editBeforeRun: try bool(statement, 12, table, "editBeforeRun"),
                    noDocumentCreation: try bool(statement, 13, table, "noDocumentCreation"),
                    maxIterations: try optionalInt(statement, 14, table, "maxIterations"),
                    autoIncludeDocuments: try bool(statement, 15, table, "autoIncludeDocuments"),
                    autoIncludeCommentaries: try bool(statement, 16, table, "autoIncludeCommentaries"),
                    bibleOnly: try bool(statement, 17, table, "bibleOnly"),
                    isTextTransformation: try bool(statement, 18, table, "isTextTransformation"),
                    categoryId: try optionalUUID(statement, 19, table, "categoryId")
                )
            )
        }
        return rows
    }

    /** Reads Android's zero-or-one global settings singleton without converter normalization. */
    private func fetchGlobalSettings(
        from database: OpaquePointer
    ) throws -> [RemoteSyncAndroidGlobalAISettings] {
        let table = "GlobalAiSettings"
        let statement = try prepare(
            "SELECT id, agentPermissionMode, permanentlyAllowedTools, permanentlyDeniedTools, aiExcludedDocuments, commentaryMaxResponseTokens, hiddenBuiltInPrompts, maxIterations, commentaryDeselected, defaultModelId, aiLanguage, askModelBeforeRun, aiDisclaimerAccepted, hiddenBuiltInCategories, customAgentSystemPrompt, customTextTransformationSystemPrompt, favoritePrompts, rawLogRetentionDays, autoHideAgentLogOnCompletion FROM GlobalAiSettings;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var rows: [RemoteSyncAndroidGlobalAISettings] = []
        try forEachRow(statement) {
            rows.append(
                RemoteSyncAndroidGlobalAISettings(
                    id: try uuid(statement, 0, table, "id"),
                    agentPermissionMode: try optionalText(statement, 1, table, "agentPermissionMode"),
                    permanentlyAllowedTools: try optionalText(statement, 2, table, "permanentlyAllowedTools"),
                    permanentlyDeniedTools: try optionalText(statement, 3, table, "permanentlyDeniedTools"),
                    aiExcludedDocuments: try text(statement, 4, table, "aiExcludedDocuments"),
                    commentaryMaxResponseTokens: try int(statement, 5, table, "commentaryMaxResponseTokens"),
                    hiddenBuiltInPrompts: try text(statement, 6, table, "hiddenBuiltInPrompts"),
                    maxIterations: try int(statement, 7, table, "maxIterations"),
                    commentaryDeselected: try text(statement, 8, table, "commentaryDeselected"),
                    defaultModelId: try optionalUUID(statement, 9, table, "defaultModelId"),
                    aiLanguage: try optionalText(statement, 10, table, "aiLanguage"),
                    askModelBeforeRun: try bool(statement, 11, table, "askModelBeforeRun"),
                    aiDisclaimerAccepted: try bool(statement, 12, table, "aiDisclaimerAccepted"),
                    hiddenBuiltInCategories: try text(statement, 13, table, "hiddenBuiltInCategories"),
                    customAgentSystemPrompt: try optionalText(statement, 14, table, "customAgentSystemPrompt"),
                    customTextTransformationSystemPrompt: try optionalText(statement, 15, table, "customTextTransformationSystemPrompt"),
                    favoritePrompts: try text(statement, 16, table, "favoritePrompts"),
                    rawLogRetentionDays: try optionalInt(statement, 17, table, "rawLogRetentionDays"),
                    autoHideAgentLogOnCompletion: try bool(statement, 18, table, "autoHideAgentLogOnCompletion")
                )
            )
        }
        return rows
    }

    /** Reads every Android per-device cumulative usage row. */
    private func fetchUsageRecords(
        from database: OpaquePointer
    ) throws -> [RemoteSyncAndroidAIUsageRecord] {
        let table = "LlmUsageRecord"
        let statement = try prepare(
            "SELECT id, configuredModelId, deviceId, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, estimatedCostUsd FROM LlmUsageRecord;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var rows: [RemoteSyncAndroidAIUsageRecord] = []
        try forEachRow(statement) {
            rows.append(
                RemoteSyncAndroidAIUsageRecord(
                    id: try uuid(statement, 0, table, "id"),
                    configuredModelId: try uuid(statement, 1, table, "configuredModelId"),
                    deviceId: try text(statement, 2, table, "deviceId"),
                    inputTokens: try int64(statement, 3, table, "inputTokens"),
                    outputTokens: try int64(statement, 4, table, "outputTokens"),
                    cacheCreationTokens: try int64(statement, 5, table, "cacheCreationTokens"),
                    cacheReadTokens: try int64(statement, 6, table, "cacheReadTokens"),
                    estimatedCostUsd: try real(statement, 7, table, "estimatedCostUsd")
                )
            )
        }
        return rows
    }

    /** Reads every user-defined prompt category row. */
    private func fetchPromptCategories(
        from database: OpaquePointer
    ) throws -> [RemoteSyncAndroidAIPromptCategory] {
        let table = "PromptCategory"
        let statement = try prepare(
            "SELECT id, name, orderNumber, hidden FROM PromptCategory;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var rows: [RemoteSyncAndroidAIPromptCategory] = []
        try forEachRow(statement) {
            rows.append(
                RemoteSyncAndroidAIPromptCategory(
                    id: try uuid(statement, 0, table, "id"),
                    name: try text(statement, 1, table, "name"),
                    orderNumber: try int(statement, 2, table, "orderNumber"),
                    hidden: try bool(statement, 3, table, "hidden")
                )
            )
        }
        return rows
    }

    /** Reads every built-in prompt model override row. */
    private func fetchBuiltinPromptOverrides(
        from database: OpaquePointer
    ) throws -> [RemoteSyncAndroidAIBuiltinPromptOverride] {
        let table = "BuiltinPromptOverride"
        let statement = try prepare(
            "SELECT id, configuredModelId FROM BuiltinPromptOverride;",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var rows: [RemoteSyncAndroidAIBuiltinPromptOverride] = []
        try forEachRow(statement) {
            rows.append(
                RemoteSyncAndroidAIBuiltinPromptOverride(
                    id: try uuid(statement, 0, table, "id"),
                    configuredModelId: try optionalUUID(statement, 1, table, "configuredModelId")
                )
            )
        }
        return rows
    }

    /** Returns deterministic Android display/storage ordering for a materialized generation. */
    private static func sorted(
        _ snapshot: RemoteSyncAndroidAISettingsSnapshot
    ) -> RemoteSyncAndroidAISettingsSnapshot {
        RemoteSyncAndroidAISettingsSnapshot(
            providers: snapshot.providers.sorted(by: providerSort),
            configuredModels: snapshot.configuredModels.sorted(by: configuredModelSort),
            agentPrompts: snapshot.agentPrompts.sorted(by: promptSort),
            globalSettings: snapshot.globalSettings.sorted { $0.id.uuidString < $1.id.uuidString },
            usageRecords: snapshot.usageRecords.sorted(by: usageSort),
            promptCategories: snapshot.promptCategories.sorted(by: categorySort),
            builtinOverrides: snapshot.builtinOverrides.sorted { $0.id.uuidString < $1.id.uuidString },
            ignoredIncomingRawLogCount: snapshot.ignoredIncomingRawLogCount
        )
    }

    /** Prepares one read-only query or reports a fail-closed SQLite error. */
    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RemoteSyncAISettingsRestoreError.invalidSQLiteDatabase
        }
        return statement
    }

    /** Counts one already-bounded Android table without materializing any row payload. */
    private func rowCount(in table: String, database: OpaquePointer) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM \(table);", in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              let count = Int(exactly: sqlite3_column_int64(statement, 0)),
              count >= 0 else {
            throw RemoteSyncAISettingsRestoreError.invalidSQLiteDatabase
        }
        return count
    }

    /** Steps every row and rejects any terminal status other than `SQLITE_DONE`. */
    private func forEachRow(
        _ statement: OpaquePointer?,
        _ body: () throws -> Void
    ) throws {
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try body()
            case SQLITE_DONE:
                return
            default:
                throw RemoteSyncAISettingsRestoreError.invalidSQLiteDatabase
            }
        }
    }

    /** Decodes one exact 16-byte Android UUID BLOB. */
    private func uuid(
        _ statement: OpaquePointer?,
        _ column: Int32,
        _ table: String,
        _ name: String
    ) throws -> UUID {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB,
              sqlite3_column_bytes(statement, column) == 16,
              let bytes = sqlite3_column_blob(statement, column),
              let value = RemoteSyncAISettingsSnapshotService.uuid(
                  from: Data(bytes: bytes, count: 16)
              ) else {
            throw RemoteSyncAISettingsRestoreError.invalidIdentifierBlob(table: table, column: name)
        }
        return value
    }

    /** Decodes a nullable Android UUID while preserving SQL NULL. */
    private func optionalUUID(
        _ statement: OpaquePointer?,
        _ column: Int32,
        _ table: String,
        _ name: String
    ) throws -> UUID? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        return try uuid(statement, column, table, name)
    }

    /** Decodes exact UTF-8 SQLite TEXT, including embedded NUL bytes. */
    private func text(
        _ statement: OpaquePointer?,
        _ column: Int32,
        _ table: String,
        _ name: String
    ) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else {
            throw RemoteSyncAISettingsRestoreError.invalidColumnValue(table: table, column: name)
        }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        if byteCount == 0 { return "" }
        guard byteCount > 0, let bytes = sqlite3_column_text(statement, column),
              let value = String(
                  data: Data(bytes: bytes, count: byteCount),
                  encoding: .utf8
              ) else {
            throw RemoteSyncAISettingsRestoreError.invalidColumnValue(table: table, column: name)
        }
        return value
    }

    /** Decodes nullable exact UTF-8 SQLite TEXT without collapsing empty to nil. */
    private func optionalText(
        _ statement: OpaquePointer?,
        _ column: Int32,
        _ table: String,
        _ name: String
    ) throws -> String? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        return try text(statement, column, table, name)
    }

    /** Decodes an Android Kotlin `Int` after exact INTEGER storage validation. */
    private func int(
        _ statement: OpaquePointer?,
        _ column: Int32,
        _ table: String,
        _ name: String
    ) throws -> Int {
        let value = try int64(statement, column, table, name)
        guard let result = Int(exactly: value) else {
            throw RemoteSyncAISettingsRestoreError.invalidColumnValue(table: table, column: name)
        }
        return result
    }

    /** Decodes a nullable Android Kotlin `Int` while preserving SQL NULL. */
    private func optionalInt(
        _ statement: OpaquePointer?,
        _ column: Int32,
        _ table: String,
        _ name: String
    ) throws -> Int? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
        return try int(statement, column, table, name)
    }

    /** Decodes an exact SQLite INTEGER into Android's signed 64-bit domain. */
    private func int64(
        _ statement: OpaquePointer?,
        _ column: Int32,
        _ table: String,
        _ name: String
    ) throws -> Int64 {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else {
            throw RemoteSyncAISettingsRestoreError.invalidColumnValue(table: table, column: name)
        }
        return sqlite3_column_int64(statement, column)
    }

    /** Decodes Android Boolean storage and rejects integers other than zero or one. */
    private func bool(
        _ statement: OpaquePointer?,
        _ column: Int32,
        _ table: String,
        _ name: String
    ) throws -> Bool {
        switch try int64(statement, column, table, name) {
        case 0: false
        case 1: true
        default: throw RemoteSyncAISettingsRestoreError.invalidColumnValue(table: table, column: name)
        }
    }

    /** Decodes one finite SQLite REAL without accepting INTEGER coercion. */
    private func real(
        _ statement: OpaquePointer?,
        _ column: Int32,
        _ table: String,
        _ name: String
    ) throws -> Double {
        guard sqlite3_column_type(statement, column) == SQLITE_FLOAT else {
            throw RemoteSyncAISettingsRestoreError.invalidColumnValue(table: table, column: name)
        }
        let value = sqlite3_column_double(statement, column)
        guard value.isFinite else {
            throw RemoteSyncAISettingsRestoreError.invalidColumnValue(table: table, column: name)
        }
        return value
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
