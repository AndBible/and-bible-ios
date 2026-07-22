// RemoteSyncAISettingsPatchApplyService.swift -- Incremental Android AI settings patch replay

import Foundation
import SwiftData

/**
 Errors raised while replaying Android AI settings patch archives against the local SwiftData graph.
 */
public enum RemoteSyncAISettingsPatchApplyError: Error, Equatable {
    /// One Android `LogEntry` identifier could not be converted into the expected UUID row key.
    case invalidLogEntryIdentifier(table: String, field: String)
}

/**
 Summary of one successful Android AI settings patch replay batch.

 The final row counts describe the normalized seven-table graph after Android-compatible formal
 foreign-key cleanup. Accepted log entries remain counted even when cleanup prunes their rows.
 */
public struct RemoteSyncAISettingsPatchApplyReport: Sendable, Equatable {
    /// Number of archives evaluated and recorded in patch status, including all-skipped archives.
    public let appliedPatchCount: Int

    /// Number of newer remote log entries accepted, including entries whose rows were later pruned.
    public let appliedLogEntryCount: Int

    /// Number of remote log entries skipped because local metadata was newer or equal.
    public let skippedLogEntryCount: Int

    /// Number of provider rows remaining after replay normalization.
    public let providerCount: Int

    /// Number of configured-model rows remaining after replay normalization.
    public let configuredModelCount: Int

    /// Number of agent-prompt rows remaining after replay normalization.
    public let agentPromptCount: Int

    /// Number of global-settings rows remaining after replay normalization.
    public let globalSettingsCount: Int

    /// Number of usage rows remaining after replay normalization.
    public let usageRecordCount: Int

    /// Number of prompt-category rows remaining after replay normalization.
    public let promptCategoryCount: Int

    /// Number of built-in prompt override rows remaining after replay normalization.
    public let builtinOverrideCount: Int

    /**
     Creates one successful replay report from patch and final-row counts.

     - Parameters:
       - appliedPatchCount: Number of archives fully evaluated and recorded in patch status.
       - appliedLogEntryCount: Number of strictly newer remote operations accepted.
       - skippedLogEntryCount: Number of older or equal remote operations ignored.
       - providerCount: Final provider-row count.
       - configuredModelCount: Final configured-model-row count.
       - agentPromptCount: Final agent-prompt-row count.
       - globalSettingsCount: Final global-settings-row count.
       - usageRecordCount: Final usage-row count.
       - promptCategoryCount: Final prompt-category-row count.
       - builtinOverrideCount: Final built-in override-row count.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        appliedPatchCount: Int,
        appliedLogEntryCount: Int,
        skippedLogEntryCount: Int,
        providerCount: Int,
        configuredModelCount: Int,
        agentPromptCount: Int,
        globalSettingsCount: Int,
        usageRecordCount: Int,
        promptCategoryCount: Int,
        builtinOverrideCount: Int
    ) {
        self.appliedPatchCount = appliedPatchCount
        self.appliedLogEntryCount = appliedLogEntryCount
        self.skippedLogEntryCount = skippedLogEntryCount
        self.providerCount = providerCount
        self.configuredModelCount = configuredModelCount
        self.agentPromptCount = agentPromptCount
        self.globalSettingsCount = globalSettingsCount
        self.usageRecordCount = usageRecordCount
        self.promptCategoryCount = promptCategoryCount
        self.builtinOverrideCount = builtinOverrideCount
    }
}

/**
 Replays Android `AI_SETTINGS` patch archives into the seven synchronized SwiftData tables.

 Android evaluates sparse SQLite patches in table order and accepts a mutation only when its
 `lastUpdated` value is strictly greater than the local `LogEntry` watermark. This service mirrors
 that contract across an entire downloaded batch before publishing any mutation:

 - current SwiftData rows and strict local metadata seed an in-memory working state
 - archives are decompressed under the same per-file and cumulative bounds as other categories
 - accepted upserts and deletes replay in Android's seven-table order
 - formal foreign-key violations are pruned while logical dangling references remain intact
 - accepted metadata survives cleanup even when a newly accepted row is pruned
 - graph rows, log metadata, patch statuses, and fingerprints publish in one atomic transaction

 `LlmRawLogRecord` is not synchronized: inbound rows are bounded and counted, while local rows are
 never mutated or published. Provider credentials are structurally absent from every row type used
 by this service and remain in the device-local credential store.

 Data dependencies:
 - `RemoteSyncInitialBackupMetadataRestoreService` reads staged `LogEntry` metadata
 - `RemoteSyncAISettingsRestoreService` reads patch rows and stages the final graph replacement
 - `RemoteSyncAISettingsSnapshotService` projects current rows and refreshes accepted fingerprints
 - `RemoteSyncLogEntryStore` and `RemoteSyncPatchStatusStore` preserve sync bookkeeping

 Side effects:
 - reads gzip archives and creates short-lived extracted SQLite files
 - reads the local seven-table AI settings graph and settings-backed sync metadata
 - atomically replaces synchronized AI rows when at least one remote operation is accepted
 - atomically replaces category log metadata, appends patch statuses, and refreshes fingerprints

 Failure modes:
 - rethrows bounded decompression, SQLite decoding, SwiftData fetch, validation, and commit errors
 - throws `RemoteSyncAISettingsPatchApplyError` for malformed UUID identities
 - rethrows cancellation before publication, between archives, and at the final durable checkpoint
 - atomic publication rolls SwiftData and settings metadata back together on failure

 Concurrency:
 - this type is not `Sendable`; callers must use the execution context owning `ModelContext` and
   `SettingsStore`
 */
public final class RemoteSyncAISettingsPatchApplyService {
    /**
     Mutable Android-shaped graph used to evaluate a complete patch batch before publication.

     Every dictionary is keyed by the sole UUID primary key used by its Android table. Logical
     references deliberately remain scalar UUIDs rather than being resolved into SwiftData links.
     */
    private struct WorkingSnapshot {
        var providersByID: [UUID: RemoteSyncAndroidAIProvider]
        var configuredModelsByID: [UUID: RemoteSyncAndroidAIConfiguredModel]
        var agentPromptsByID: [UUID: RemoteSyncAndroidAIAgentPrompt]
        var globalSettingsByID: [UUID: RemoteSyncAndroidGlobalAISettings]
        var usageRecordsByID: [UUID: RemoteSyncAndroidAIUsageRecord]
        var promptCategoriesByID: [UUID: RemoteSyncAndroidAIPromptCategory]
        var builtinOverridesByID: [UUID: RemoteSyncAndroidAIBuiltinPromptOverride]

        /**
         Upserts one configured model with Android's unique-index replacement behavior.

         Android declares `(providerConfigId, modelId)` unique and replays patch rows with
         `ON CONFLICT DO UPDATE`. When another row already occupies that composite key, SQLite keeps
         the existing primary UUID and updates its non-identity columns from the incoming row.

         - Parameter row: Accepted configured-model row to insert or replace.
         - Side effects: Mutates the configured-model dictionary.
         - Failure modes: This helper cannot fail.
         */
        mutating func upsertConfiguredModel(_ row: RemoteSyncAndroidAIConfiguredModel) {
            if let conflictingRow = configuredModelsByID.values.first(where: {
                $0.providerConfigId == row.providerConfigId && $0.modelId == row.modelId
            }) {
                configuredModelsByID[conflictingRow.id] = RemoteSyncAndroidAIConfiguredModel(
                    id: conflictingRow.id,
                    providerConfigId: row.providerConfigId,
                    modelId: row.modelId,
                    orderNumber: row.orderNumber,
                    inputPricePerMillion: row.inputPricePerMillion,
                    outputPricePerMillion: row.outputPricePerMillion,
                    cacheCreationPricePerMillion: row.cacheCreationPricePerMillion,
                    cacheReadPricePerMillion: row.cacheReadPricePerMillion
                )
                return
            }
            configuredModelsByID[row.id] = row
        }

        /**
         Upserts one usage row with Android's unique-index replacement behavior.

         Android declares `(configuredModelId, deviceId)` unique. SQLite's conflict update preserves
         the existing primary UUID while replacing its cumulative counters and estimated cost.

         - Parameter row: Accepted usage record to insert or replace.
         - Side effects: Mutates the usage-record dictionary.
         - Failure modes: This helper cannot fail.
         */
        mutating func upsertUsageRecord(_ row: RemoteSyncAndroidAIUsageRecord) {
            if let conflictingRow = usageRecordsByID.values.first(where: {
                $0.configuredModelId == row.configuredModelId && $0.deviceId == row.deviceId
            }) {
                usageRecordsByID[conflictingRow.id] = RemoteSyncAndroidAIUsageRecord(
                    id: conflictingRow.id,
                    configuredModelId: row.configuredModelId,
                    deviceId: row.deviceId,
                    inputTokens: row.inputTokens,
                    outputTokens: row.outputTokens,
                    cacheCreationTokens: row.cacheCreationTokens,
                    cacheReadTokens: row.cacheReadTokens,
                    estimatedCostUsd: row.estimatedCostUsd
                )
                return
            }
            usageRecordsByID[row.id] = row
        }

        /**
         Removes rows in one table that violate Android's declared AI settings foreign keys.

         Android applies patches with foreign keys disabled and then deletes rows reported by
         `pragma_foreign_key_check`. The equivalent graph rules are:

         - configured models require an existing provider
         - prompts with a configured model require that model
         - built-in overrides with a configured model require that model

         `AgentPrompt.categoryId`, `GlobalAiSettings.defaultModelId`, and
         `LlmUsageRecord.configuredModelId` are logical references in Android's schema and therefore
         remain unchanged when their target is absent.

         - Parameter tableName: Table currently at Android's post-upsert FK-check phase.
         - Side effects: Mutates only the named table's dictionary when it owns a formal foreign key.
         - Failure modes: This helper cannot fail.
         - Note: Accepted `LogEntry` metadata is stored separately and is never removed here.
         */
        mutating func pruneFormalForeignKeyViolations(in tableName: String) {
            switch tableName {
            case "LlmConfiguredModel":
                let validProviderIDs = Set(providersByID.keys)
                configuredModelsByID = configuredModelsByID.filter { _, row in
                    validProviderIDs.contains(row.providerConfigId)
                }
            case "AgentPrompt":
                let validConfiguredModelIDs = Set(configuredModelsByID.keys)
                agentPromptsByID = agentPromptsByID.filter { _, row in
                    guard let configuredModelID = row.configuredModelId else {
                        return true
                    }
                    return validConfiguredModelIDs.contains(configuredModelID)
                }
            case "BuiltinPromptOverride":
                let validConfiguredModelIDs = Set(configuredModelsByID.keys)
                builtinOverridesByID = builtinOverridesByID.filter { _, row in
                    guard let configuredModelID = row.configuredModelId else {
                        return true
                    }
                    return validConfiguredModelIDs.contains(configuredModelID)
                }
            default:
                break
            }
        }

        /**
         Converts mutable dictionaries into the deterministic snapshot accepted by the restore path.

         - Returns: Seven-table Android-shaped snapshot with no formal foreign-key violations.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        func materializedSnapshot() -> RemoteSyncAndroidAISettingsSnapshot {
            RemoteSyncAndroidAISettingsSnapshot(
                providers: providersByID.values.sorted(by: Self.providerSort),
                configuredModels: configuredModelsByID.values.sorted(by: Self.configuredModelSort),
                agentPrompts: agentPromptsByID.values.sorted(by: Self.agentPromptSort),
                globalSettings: globalSettingsByID.values.sorted(by: Self.globalSettingsSort),
                usageRecords: usageRecordsByID.values.sorted(by: Self.usageRecordSort),
                promptCategories: promptCategoriesByID.values.sorted(by: Self.promptCategorySort),
                builtinOverrides: builtinOverridesByID.values.sorted(by: Self.builtinOverrideSort)
            )
        }

        /** Orders provider rows deterministically without changing Android's primary order. */
        private static func providerSort(
            _ lhs: RemoteSyncAndroidAIProvider,
            _ rhs: RemoteSyncAndroidAIProvider
        ) -> Bool {
            if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
            if lhs.displayName != rhs.displayName { return lhs.displayName < rhs.displayName }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        /** Orders configured models deterministically by provider, configured order, and identity. */
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

        /** Orders agent prompts deterministically by configured order, creation time, and identity. */
        private static func agentPromptSort(
            _ lhs: RemoteSyncAndroidAIAgentPrompt,
            _ rhs: RemoteSyncAndroidAIAgentPrompt
        ) -> Bool {
            if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        /** Orders the singleton global-settings table by identity for deterministic materialization. */
        private static func globalSettingsSort(
            _ lhs: RemoteSyncAndroidGlobalAISettings,
            _ rhs: RemoteSyncAndroidGlobalAISettings
        ) -> Bool {
            lhs.id.uuidString < rhs.id.uuidString
        }

        /** Orders usage rows deterministically by logical model, device, and row identity. */
        private static func usageRecordSort(
            _ lhs: RemoteSyncAndroidAIUsageRecord,
            _ rhs: RemoteSyncAndroidAIUsageRecord
        ) -> Bool {
            if lhs.configuredModelId != rhs.configuredModelId {
                return lhs.configuredModelId.uuidString < rhs.configuredModelId.uuidString
            }
            if lhs.deviceId != rhs.deviceId { return lhs.deviceId < rhs.deviceId }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        /** Orders custom prompt categories using Android's visible order with deterministic ties. */
        private static func promptCategorySort(
            _ lhs: RemoteSyncAndroidAIPromptCategory,
            _ rhs: RemoteSyncAndroidAIPromptCategory
        ) -> Bool {
            if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        /** Orders built-in prompt override rows by their stable built-in prompt identity. */
        private static func builtinOverrideSort(
            _ lhs: RemoteSyncAndroidAIBuiltinPromptOverride,
            _ rhs: RemoteSyncAndroidAIBuiltinPromptOverride
        ) -> Bool {
            lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Android's exact incremental `AI_SETTINGS` table order; raw logs are intentionally absent.
    private static let androidTableOrder = [
        "LlmProviderConfig",
        "LlmConfiguredModel",
        "AgentPrompt",
        "GlobalAiSettings",
        "LlmUsageRecord",
        "PromptCategory",
        "BuiltinPromptOverride",
    ]

    /// Membership set used to discard tables outside Android's incremental AI sync contract.
    private static let supportedTableNames = Set(androidTableOrder)

    /// Reader for Android `LogEntry` metadata staged in each patch database.
    private let metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService

    /// Reader and final graph writer for Android-shaped AI settings rows.
    private let restoreService: RemoteSyncAISettingsRestoreService

    /// Projector and accepted-fingerprint publisher for the local seven-table graph.
    private let snapshotService: RemoteSyncAISettingsSnapshotService

    /// File manager used to clean temporary expanded patch databases.
    private let fileManager: FileManager

    /// Scratch directory receiving uniquely named expanded SQLite patch files.
    private let temporaryDirectory: URL

    /**
     Creates an AI settings patch replay service with injectable readers and scratch storage.

     - Parameters:
       - metadataRestoreService: Reader for Android patch metadata tables.
       - restoreService: Reader for sparse AI rows and writer for the final normalized graph.
       - snapshotService: Strict local projector and fingerprint baseline service.
       - fileManager: File manager used for temporary database lifecycle.
       - temporaryDirectory: Optional scratch directory; defaults to process temporary storage.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService(),
        restoreService: RemoteSyncAISettingsRestoreService = RemoteSyncAISettingsRestoreService(),
        snapshotService: RemoteSyncAISettingsSnapshotService = RemoteSyncAISettingsSnapshotService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) {
        self.metadataRestoreService = metadataRestoreService
        self.restoreService = restoreService
        self.snapshotService = snapshotService
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
    }

    /**
     Applies one ordered batch of staged Android AI settings patch archives.

     - Parameters:
       - stagedArchives: Downloaded gzip patches sorted in Android application order.
       - modelContext: Clean SwiftData context containing the seven synchronized AI tables.
       - settingsStore: Settings store bound to the exact supplied model context.
     - Returns: Accepted/skipped operation counts and final normalized row counts.
     - Side effects:
       - extracts each archive into temporary storage and removes it after evaluation
       - atomically publishes synchronized AI rows, metadata, statuses, and fingerprints
     - Throws:
       - rethrows bounded archive, metadata, row decode, SwiftData, transaction, and cancellation errors
       - throws `RemoteSyncAISettingsPatchApplyError` for malformed identities
     */
    public func applyPatchArchives(
        _ stagedArchives: [RemoteSyncStagedPatchArchive],
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncAISettingsPatchApplyReport {
        try applyPatchArchives(
            stagedArchives,
            modelContext: modelContext,
            settingsStore: settingsStore,
            publishCheckpoint: { try Task.checkCancellation() }
        )
    }

    /**
     Replays patches with an injectable checkpoint around the atomic publication boundary.

     The checkpoint makes cancellation and rollback deterministic in focused tests while production
     callers use `Task.checkCancellation`. All archive mutations remain in memory until the final
     settings-backed SwiftData transaction.

     - Parameters:
       - stagedArchives: Downloaded patches in Android replay order.
       - modelContext: Exact clean context shared by AI models and settings metadata.
       - settingsStore: Settings store bound to `modelContext`.
       - publishCheckpoint: Throwing callback before the initial strict read and after final staging.
     - Returns: Successful replay summary after the atomic transaction commits.
     - Side effects: Reads patch files and atomically publishes AI sync state.
     - Throws: Rethrows checkpoint, archive, decode, validation, context, fetch, and commit errors.
     */
    func applyPatchArchives(
        _ stagedArchives: [RemoteSyncStagedPatchArchive],
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        publishCheckpoint: () throws -> Void
    ) throws -> RemoteSyncAISettingsPatchApplyReport {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

        let initialState = try settingsStore.performAtomicBatch(in: modelContext) {
            try publishCheckpoint()
            return (
                try currentSnapshot(from: modelContext, settingsStore: settingsStore),
                try seededLogEntriesByKey(logEntryStore: logEntryStore)
            )
        }
        var workingSnapshot = initialState.0
        var logEntriesByKey = initialState.1
        var appliedPatchStatuses: [RemoteSyncPatchStatus] = []
        var appliedLogEntryCount = 0
        var skippedLogEntryCount = 0
        var cumulativeExpandedByteCount = UInt64(0)

        for stagedArchive in stagedArchives {
            try Task.checkCancellation()
            let patchDatabaseURL = temporaryDatabaseURL(
                prefix: "remote-sync-ai-settings-patch-",
                suffix: ".sqlite3"
            )
            defer { try? fileManager.removeItem(at: patchDatabaseURL) }

            let expandedByteCount = try RemoteSyncBoundedFileIO.inflateGzip(
                at: stagedArchive.archiveFileURL,
                to: patchDatabaseURL,
                maximumCompressedByteCount: RemoteSyncArchiveStagingService.maximumCompressedPatchByteCount,
                maximumExpandedByteCount: RemoteSyncArchiveStagingService.maximumExpandedPatchByteCount
            )
            let (nextCumulativeByteCount, overflow) = cumulativeExpandedByteCount
                .addingReportingOverflow(expandedByteCount)
            guard !overflow,
                  nextCumulativeByteCount <= UInt64(
                    RemoteSyncArchiveStagingService.maximumCumulativeExpandedPatchByteCount
                  ) else {
                throw RemoteSyncBoundedFileError.expandedSizeExceeded(
                    overflow ? UInt64.max : nextCumulativeByteCount
                )
            }
            cumulativeExpandedByteCount = nextCumulativeByteCount
            try Task.checkCancellation()

            let patchSnapshot = try restoreService.readSparsePatchSnapshot(
                from: patchDatabaseURL,
                expectedSourceVersion: stagedArchive.patch.schemaVersion
            )
            let metadataSnapshot = try metadataRestoreService.readSnapshot(from: patchDatabaseURL)
            let patchLogEntries = metadataSnapshot.logEntries.filter {
                Self.supportedTableNames.contains($0.tableName)
            }
            let canonicalPatchLogEntries = try patchLogEntries.map(canonicalLogEntry)
            let acceptedLogEntries = canonicalPatchLogEntries.filter { entry in
                let key = logEntryStore.key(for: .aiSettings, entry: entry)
                guard let localEntry = logEntriesByKey[key] else {
                    return true
                }
                return RemoteSyncLogEntryConflictOrder.isNewer(entry, than: localEntry)
            }

            skippedLogEntryCount += patchLogEntries.count - acceptedLogEntries.count
            for tableName in Self.androidTableOrder {
                try applyOperations(
                    tableName: tableName,
                    logEntries: acceptedLogEntries.filter { $0.tableName == tableName },
                    patchSnapshot: patchSnapshot,
                    workingSnapshot: &workingSnapshot,
                    logEntriesByKey: &logEntriesByKey,
                    logEntryStore: logEntryStore
                )
            }
            try Task.checkCancellation()

            appliedLogEntryCount += acceptedLogEntries.count
            appliedPatchStatuses.append(
                RemoteSyncPatchStatus(
                    sourceDevice: stagedArchive.patch.sourceDevice,
                    patchNumber: stagedArchive.patch.patchNumber,
                    sizeBytes: stagedArchive.patch.file.size,
                    appliedDate: stagedArchive.patch.file.timestamp
                )
            )
        }

        try Task.checkCancellation()
        let materializedSnapshot = workingSnapshot.materializedSnapshot()
        try settingsStore.performAtomicBatch(in: modelContext) {
            if appliedLogEntryCount > 0 {
                _ = try restoreService.replaceLocalAISettings(
                    from: materializedSnapshot,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            }
            logEntryStore.replaceEntries(
                logEntriesByKey.values.sorted(by: Self.logEntrySort),
                for: .aiSettings
            )
            patchStatusStore.addStatuses(appliedPatchStatuses, for: .aiSettings)
            try snapshotService.refreshBaselineFingerprintsStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            try publishCheckpoint()
        }

        return RemoteSyncAISettingsPatchApplyReport(
            appliedPatchCount: appliedPatchStatuses.count,
            appliedLogEntryCount: appliedLogEntryCount,
            skippedLogEntryCount: skippedLogEntryCount,
            providerCount: materializedSnapshot.providers.count,
            configuredModelCount: materializedSnapshot.configuredModels.count,
            agentPromptCount: materializedSnapshot.agentPrompts.count,
            globalSettingsCount: materializedSnapshot.globalSettings.count,
            usageRecordCount: materializedSnapshot.usageRecords.count,
            promptCategoryCount: materializedSnapshot.promptCategories.count,
            builtinOverrideCount: materializedSnapshot.builtinOverrides.count
        )
    }

    /**
     Seeds the conflict map from strictly decoded local AI settings log metadata.

     Supported identifiers are canonicalized to UUID blobs with empty text secondary IDs so legacy
     text UUIDs and current blobs share one logical key. Malformed supported identifiers fail closed,
     and metadata for tables outside the seven-table contract is discarded rather than allowing raw
     logs or future unknown tables to leak into iOS publication state.

     - Parameter logEntryStore: Strict local metadata reader and key builder.
     - Returns: Latest deterministic local entry for every persisted AI settings key.
     - Side effects: Reads settings-backed local metadata.
     - Throws: Rethrows strict metadata decoding errors.
     */
    private func seededLogEntriesByKey(
        logEntryStore: RemoteSyncLogEntryStore
    ) throws -> [String: RemoteSyncLogEntry] {
        var entriesByKey: [String: RemoteSyncLogEntry] = [:]
        for entry in try logEntryStore.entriesStrict(for: .aiSettings)
            where Self.supportedTableNames.contains(entry.tableName) {
            let keyedEntry = try canonicalLogEntry(entry)
            let key = logEntryStore.key(for: .aiSettings, entry: keyedEntry)
            guard let existingEntry = entriesByKey[key] else {
                entriesByKey[key] = keyedEntry
                continue
            }
            if Self.logEntrySort(existingEntry, keyedEntry) {
                entriesByKey[key] = keyedEntry
            }
        }
        return entriesByKey
    }

    /**
     Projects the current seven-table SwiftData graph into mutable UUID-keyed dictionaries.

     - Parameters:
       - modelContext: SwiftData context to read strictly.
       - settingsStore: Settings store used to create Android-compatible projection keys.
     - Returns: Complete current AI settings working snapshot.
     - Side effects: Reads the seven synchronized AI settings model tables.
     - Throws: Rethrows strict snapshot projection and SwiftData fetch errors.
     */
    private func currentSnapshot(
        from modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> WorkingSnapshot {
        let current = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        return WorkingSnapshot(
            providersByID: Self.rowsByID(current.providerRowsByKey.values, id: \.id),
            configuredModelsByID: Self.rowsByID(current.configuredModelRowsByKey.values, id: \.id),
            agentPromptsByID: Self.rowsByID(current.agentPromptRowsByKey.values, id: \.id),
            globalSettingsByID: Self.rowsByID(current.globalSettingsRowsByKey.values, id: \.id),
            usageRecordsByID: Self.rowsByID(current.usageRowsByKey.values, id: \.id),
            promptCategoriesByID: Self.rowsByID(current.promptCategoryRowsByKey.values, id: \.id),
            builtinOverridesByID: Self.rowsByID(current.builtinOverrideRowsByKey.values, id: \.id)
        )
    }

    /**
     Builds a UUID-keyed dictionary from a snapshot collection already validated for uniqueness.

     - Parameters:
       - rows: Strict snapshot rows to index.
       - id: Key path selecting each row's Android UUID identity.
     - Returns: Dictionary keyed by the selected UUID.
     - Side effects: none.
     - Failure modes: Duplicate identities retain the later iteration value; strict projection has
       already rejected duplicates before this helper is called.
     */
    private static func rowsByID<Rows: Sequence, Row>(
        _ rows: Rows,
        id: KeyPath<Row, UUID>
    ) -> [UUID: Row] where Rows.Element == Row {
        Dictionary(rows.map { ($0[keyPath: id], $0) }, uniquingKeysWith: { _, replacement in replacement })
    }

    /**
     Replays one Android table's accepted operations against the mutable working graph.

     - Parameters:
       - tableName: One name from Android's ordered seven-table contract.
       - logEntries: Strictly newer canonical operations for that table.
       - patchSnapshot: Sparse staged rows read from the current patch database.
       - workingSnapshot: Full in-memory graph being evaluated across the batch.
       - logEntriesByKey: Accepted metadata map updated independently of cleanup.
       - logEntryStore: Store used to create canonical category keys.
     - Side effects: Mutates working rows and accepted log metadata.
     - Throws: Throws typed identity errors; unknown table names are ignored because this helper is
       called only from the fixed Android table-order constant.
     */
    private func applyOperations(
        tableName: String,
        logEntries: [RemoteSyncLogEntry],
        patchSnapshot: RemoteSyncAndroidAISettingsSnapshot,
        workingSnapshot: inout WorkingSnapshot,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        switch tableName {
        case "LlmProviderConfig":
            try applySingleIDOperations(
                logEntries: logEntries,
                tableName: tableName,
                patchRows: Self.rowsByID(patchSnapshot.providers, id: \.id),
                upsert: { workingSnapshot.providersByID[$0.id] = $0 },
                delete: { workingSnapshot.providersByID.removeValue(forKey: $0) },
                afterUpserts: { workingSnapshot.pruneFormalForeignKeyViolations(in: tableName) },
                logEntriesByKey: &logEntriesByKey,
                logEntryStore: logEntryStore
            )
        case "LlmConfiguredModel":
            try applySingleIDOperations(
                logEntries: logEntries,
                tableName: tableName,
                patchRows: Self.rowsByID(patchSnapshot.configuredModels, id: \.id),
                upsert: { workingSnapshot.upsertConfiguredModel($0) },
                delete: { workingSnapshot.configuredModelsByID.removeValue(forKey: $0) },
                afterUpserts: { workingSnapshot.pruneFormalForeignKeyViolations(in: tableName) },
                logEntriesByKey: &logEntriesByKey,
                logEntryStore: logEntryStore
            )
        case "AgentPrompt":
            try applySingleIDOperations(
                logEntries: logEntries,
                tableName: tableName,
                patchRows: Self.rowsByID(patchSnapshot.agentPrompts, id: \.id),
                upsert: { workingSnapshot.agentPromptsByID[$0.id] = $0 },
                delete: { workingSnapshot.agentPromptsByID.removeValue(forKey: $0) },
                afterUpserts: { workingSnapshot.pruneFormalForeignKeyViolations(in: tableName) },
                logEntriesByKey: &logEntriesByKey,
                logEntryStore: logEntryStore
            )
        case "GlobalAiSettings":
            try applySingleIDOperations(
                logEntries: logEntries,
                tableName: tableName,
                patchRows: Self.rowsByID(patchSnapshot.globalSettings, id: \.id),
                upsert: { workingSnapshot.globalSettingsByID[$0.id] = $0 },
                delete: { workingSnapshot.globalSettingsByID.removeValue(forKey: $0) },
                afterUpserts: { workingSnapshot.pruneFormalForeignKeyViolations(in: tableName) },
                logEntriesByKey: &logEntriesByKey,
                logEntryStore: logEntryStore
            )
        case "LlmUsageRecord":
            try applySingleIDOperations(
                logEntries: logEntries,
                tableName: tableName,
                patchRows: Self.rowsByID(patchSnapshot.usageRecords, id: \.id),
                upsert: { workingSnapshot.upsertUsageRecord($0) },
                delete: { workingSnapshot.usageRecordsByID.removeValue(forKey: $0) },
                afterUpserts: { workingSnapshot.pruneFormalForeignKeyViolations(in: tableName) },
                logEntriesByKey: &logEntriesByKey,
                logEntryStore: logEntryStore
            )
        case "PromptCategory":
            try applySingleIDOperations(
                logEntries: logEntries,
                tableName: tableName,
                patchRows: Self.rowsByID(patchSnapshot.promptCategories, id: \.id),
                upsert: { workingSnapshot.promptCategoriesByID[$0.id] = $0 },
                delete: { workingSnapshot.promptCategoriesByID.removeValue(forKey: $0) },
                afterUpserts: { workingSnapshot.pruneFormalForeignKeyViolations(in: tableName) },
                logEntriesByKey: &logEntriesByKey,
                logEntryStore: logEntryStore
            )
        case "BuiltinPromptOverride":
            try applySingleIDOperations(
                logEntries: logEntries,
                tableName: tableName,
                patchRows: Self.rowsByID(patchSnapshot.builtinOverrides, id: \.id),
                upsert: { workingSnapshot.builtinOverridesByID[$0.id] = $0 },
                delete: { workingSnapshot.builtinOverridesByID.removeValue(forKey: $0) },
                afterUpserts: { workingSnapshot.pruneFormalForeignKeyViolations(in: tableName) },
                logEntriesByKey: &logEntriesByKey,
                logEntryStore: logEntryStore
            )
        default:
            return
        }
    }

    /**
     Applies UUID-keyed upserts followed by deletes for one Android AI settings table.

     Android applies upserts, prunes formal-FK violations for the current table, applies deletes, and
     then accepts metadata. A metadata-only UPSERT is valid when its source row was already pruned;
     it advances the watermark without inventing or mutating a payload row.

     - Parameters:
       - logEntries: Canonical newer operations for one table.
       - tableName: Android table name used for diagnostics.
       - patchRows: Sparse staged upsert rows keyed by UUID.
       - upsert: In-memory insertion or replacement callback.
       - delete: In-memory deletion callback.
       - afterUpserts: Table-local formal-FK cleanup callback run before deletes, even with no rows.
       - logEntriesByKey: Local metadata map receiving accepted watermarks.
       - logEntryStore: Store used to compute category metadata keys.
     - Side effects: Mutates caller-owned working rows and metadata through supplied inout state.
     - Throws:
       - `RemoteSyncAISettingsPatchApplyError.invalidLogEntryIdentifier` for malformed UUID keys
     */
    private func applySingleIDOperations<Row>(
        logEntries: [RemoteSyncLogEntry],
        tableName: String,
        patchRows: [UUID: Row],
        upsert: (Row) -> Void,
        delete: (UUID) -> Void,
        afterUpserts: () -> Void,
        logEntriesByKey: inout [String: RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws {
        let upserts = logEntries.filter { $0.type == .upsert }.sorted(by: Self.logEntrySort)
        let deletes = logEntries.filter { $0.type == .delete }.sorted(by: Self.logEntrySort)
        for entry in upserts {
            let canonicalEntry = try canonicalLogEntry(entry)
            let rowID = try uuid(
                from: canonicalEntry.entityID1,
                tableName: tableName,
                field: "entityId1"
            )
            if let row = patchRows[rowID] {
                upsert(row)
            }
            logEntriesByKey[logEntryStore.key(for: .aiSettings, entry: canonicalEntry)] = canonicalEntry
        }

        afterUpserts()

        for entry in deletes {
            let canonicalEntry = try canonicalLogEntry(entry)
            let rowID = try uuid(
                from: canonicalEntry.entityID1,
                tableName: tableName,
                field: "entityId1"
            )
            delete(rowID)
            logEntriesByKey[logEntryStore.key(for: .aiSettings, entry: canonicalEntry)] = canonicalEntry
        }
    }

    /**
     Canonicalizes one supported AI settings log identity to Android's UUID-blob representation.

     - Parameter entry: Supported staged or local log entry.
     - Returns: Entry with a 16-byte UUID `entityID1` and empty-text `entityID2`.
     - Side effects: none.
     - Throws: `RemoteSyncAISettingsPatchApplyError.invalidLogEntryIdentifier` when the primary
       identity is neither a valid UUID blob nor UUID string.
     */
    private func canonicalLogEntry(_ entry: RemoteSyncLogEntry) throws -> RemoteSyncLogEntry {
        guard Self.supportedTableNames.contains(entry.tableName) else {
            return entry
        }
        let rowID = try uuid(
            from: entry.entityID1,
            tableName: entry.tableName,
            field: "entityId1"
        )
        return RemoteSyncLogEntry(
            tableName: entry.tableName,
            entityID1: .blob(RemoteSyncAISettingsSnapshotService.uuidBlob(rowID)),
            entityID2: RemoteSyncAISettingsSnapshotService.emptySecondaryEntityID,
            type: entry.type,
            lastUpdated: entry.lastUpdated,
            sourceDevice: entry.sourceDevice
        )
    }

    /**
     Decodes one Android AI row identity from SQLite blob or text storage.

     - Parameters:
       - value: Raw `LogEntry.entityId1` SQLite value.
       - tableName: Table name used for a typed diagnostic.
       - field: Column name used for a typed diagnostic.
     - Returns: UUID represented by the SQLite value.
     - Side effects: none.
     - Throws: `RemoteSyncAISettingsPatchApplyError.invalidLogEntryIdentifier` for invalid kinds,
       malformed blobs, or malformed UUID text.
     */
    private func uuid(
        from value: RemoteSyncSQLiteValue,
        tableName: String,
        field: String
    ) throws -> UUID {
        switch value.kind {
        case .blob:
            guard let data = value.blobData,
                  let uuid = RemoteSyncAISettingsSnapshotService.uuid(from: data) else {
                throw RemoteSyncAISettingsPatchApplyError.invalidLogEntryIdentifier(
                    table: tableName,
                    field: field
                )
            }
            return uuid
        case .text:
            guard let textValue = value.textValue,
                  let uuid = UUID(uuidString: textValue) else {
                throw RemoteSyncAISettingsPatchApplyError.invalidLogEntryIdentifier(
                    table: tableName,
                    field: field
                )
            }
            return uuid
        default:
            throw RemoteSyncAISettingsPatchApplyError.invalidLogEntryIdentifier(
                table: tableName,
                field: field
            )
        }
    }

    /**
     Creates a unique temporary SQLite destination beneath configured scratch storage.

     - Parameters:
       - prefix: Human-readable filename prefix for diagnostics.
       - suffix: Filename suffix including extension.
     - Returns: Unique candidate URL that the bounded inflater may create.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func temporaryDatabaseURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    /**
     Provides deterministic ordering for persisted Android log metadata.

     - Parameters:
       - lhs: First accepted or seeded log entry.
       - rhs: Second accepted or seeded log entry.
     - Returns: `true` when `lhs` sorts before `rhs`; this order never changes conflict precedence.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func logEntrySort(_ lhs: RemoteSyncLogEntry, _ rhs: RemoteSyncLogEntry) -> Bool {
        if lhs.lastUpdated != rhs.lastUpdated { return lhs.lastUpdated < rhs.lastUpdated }
        if lhs.tableName != rhs.tableName { return lhs.tableName < rhs.tableName }
        if lhs.type != rhs.type { return lhs.type.rawValue < rhs.type.rawValue }
        if lhs.sourceDevice != rhs.sourceDevice { return lhs.sourceDevice < rhs.sourceDevice }
        if lhs.entityID1 != rhs.entityID1 {
            return sortKey(for: lhs.entityID1) < sortKey(for: rhs.entityID1)
        }
        return sortKey(for: lhs.entityID2) < sortKey(for: rhs.entityID2)
    }

    /**
     Converts one SQLite scalar into a stable deterministic metadata sort key.

     - Parameter value: SQLite scalar to canonicalize for iteration order only.
     - Returns: Kind-prefixed string representation.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func sortKey(for value: RemoteSyncSQLiteValue) -> String {
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
