// RemoteSyncAISettingsPatchUploadService.swift -- Android-shaped outbound AI settings patch publication

import Foundation
import SwiftData

/**
 Errors raised while projecting, persisting, reconciling, or accepting an outbound AI settings patch.

 The service fails closed so malformed outbox state or an unsupported Android schema can never
 advance local acceptance metadata.
 */
public enum RemoteSyncAISettingsPatchUploadError: Error, Equatable {
    /// No nonempty remote device-folder identifier is available for the AI settings category.
    case missingDeviceFolderID

    /// Persisted outbox metadata is malformed, tampered with, or targets another destination.
    case invalidPendingUpload

    /// The highest accepted local or remote patch number cannot be incremented safely.
    case patchNumberOverflow

    /// The requested wire schema is not Android's supported AI settings Room schema.
    case unsupportedSchemaVersion(Int)

    /// The database writer committed counts that differ from the service's signed sparse projection.
    case databaseWriteReportMismatch
}

/**
 Counts the changed rows emitted for one synchronized Android AI settings table.

 Counts include only rows present in the sparse patch. `LlmRawLogRecord` is deliberately not a
 synchronized table and therefore never appears in this report.
 */
public struct RemoteSyncAISettingsPatchTableReport: Sendable, Equatable {
    /// Exact Android Room table name.
    public let tableName: String

    /// Number of complete rows emitted for `UPSERT` operations.
    public let upsertedRowCount: Int

    /// Number of tombstones emitted for `DELETE` operations.
    public let deletedRowCount: Int

    /**
     Creates one deterministic table-level sparse-patch summary.

     - Parameters:
       - tableName: Exact synchronized Android table name.
       - upsertedRowCount: Number of complete rows included in the patch.
       - deletedRowCount: Number of delete-only log entries included in the patch.
     - Side effects: None.
     - Failure modes: This value initializer does not validate counts; production reports are built
       only from validated outbox manifests.
     */
    public init(tableName: String, upsertedRowCount: Int, deletedRowCount: Int) {
        self.tableName = tableName
        self.upsertedRowCount = upsertedRowCount
        self.deletedRowCount = deletedRowCount
    }
}

/**
 Summary of one remotely committed and locally accepted AI settings patch.

 The report describes the exact durable generation that was reconciled. It does not re-read the live
 AI settings graph, which may already contain newer local edits retained for a later patch.
 */
public struct RemoteSyncAISettingsPatchUploadReport: Sendable, Equatable {
    /// Remote file metadata returned by reconciliation after the archive was created or matched.
    public let uploadedFile: RemoteSyncFile

    /// Monotonic patch number assigned within the current device folder.
    public let patchNumber: Int64

    /// Seven table summaries in Android's synchronization order.
    public let tableReports: [RemoteSyncAISettingsPatchTableReport]

    /// Total number of Android `LogEntry` rows emitted for upserts and tombstones.
    public let logEntryCount: Int

    /// Logical millisecond timestamp allocated to synthetic entries in this generation.
    public let lastUpdated: Int64

    /**
     Creates one accepted AI settings patch summary.

     - Parameters:
       - uploadedFile: Accepted remote patch metadata.
       - patchNumber: Monotonic source-device patch number.
       - tableReports: Per-table upsert and delete counts.
       - logEntryCount: Total emitted Android log rows.
       - lastUpdated: Logical generation timestamp.
     - Side effects: None.
     - Failure modes: This value initializer cannot fail.
     */
    public init(
        uploadedFile: RemoteSyncFile,
        patchNumber: Int64,
        tableReports: [RemoteSyncAISettingsPatchTableReport],
        logEntryCount: Int,
        lastUpdated: Int64
    ) {
        self.uploadedFile = uploadedFile
        self.patchNumber = patchNumber
        self.tableReports = tableReports
        self.logEntryCount = logEntryCount
        self.lastUpdated = lastUpdated
    }
}

/**
 Creates Android Room v23 sparse AI settings patches and publishes them through a durable outbox.

 The service diffs only Android's seven `AI_SETTINGS` tables. Provider credentials and raw LLM logs
 are not accepted as inputs, so neither can enter initial row projections, sparse rows, manifests, or
 publication identity payloads. `RemoteSyncAISettingsDatabaseWriter` creates the complete Room v23
 shell, including an empty `LlmRawLogRecord` table, and inserts only the rows supplied here.

 Side effects include strict SwiftData reads, settings-backed mutation-journal and outbox writes,
 temporary and Application Support file I/O, remote list/download/upload requests, and atomic accepted
 metadata updates. Failed transport or local acceptance leaves the durable generation intact for an
 idempotent retry. Conflict timestamps are never regenerated for journaled mutations; strict `>`
 acceptance remains centralized in the shared mutation-log reconciliation contract.
 */
public final class RemoteSyncAISettingsPatchUploadService {
    /** Immutable strict projection and metadata used to build one archive generation. */
    private struct UploadGeneration {
        /// Complete credential-free snapshot used by the writer to validate sparse row selection.
        let sourceSnapshot: RemoteSyncAISettingsCurrentSnapshot

        /// Full accepted baseline represented by the projected graph.
        let acceptedBaseline: RemoteSyncAISettingsAcceptedBaseline

        /// Baseline revision that must still be current during local acceptance.
        let expectedAcceptedBaselineRevision: UUID?

        /// Distinguishes a missing baseline from a legacy baseline whose revision is absent.
        let expectedAcceptedBaselineExists: Bool

        /// Sparse seven-table row and log projection.
        let changeSet: ChangeSet

        /// Monotonic source-device patch number.
        let patchNumber: Int64

        /// Android source-device name derived from the destination folder.
        let sourceDevice: String

        /// Logical timestamp used only when no mutation-time timestamp exists.
        let timestamp: Int64
    }

    /**
     Durable AI settings upload generation retained until remote and local acceptance both succeed.

     The manifest signs archive identity, row counts, mutation-time log entries, and baseline compare-
     and-swap metadata. It contains no provider credential field or arbitrary payload bytes.
     */
    private struct PendingUpload: Codable, Equatable {
        /// Stable local generation identifier used in the archive basename.
        let generationID: UUID

        /// Remote destination folder this generation is permanently bound to.
        let deviceFolderID: String

        /// Android source-device identity represented in log entries.
        let sourceDevice: String

        /// Monotonic source-device patch number.
        let patchNumber: Int64

        /// Exact Android Room schema version used to create the archive.
        let schemaVersion: Int

        /// Android-compatible remote patch filename.
        let patchFileName: String

        /// Safe local durable archive basename.
        let archiveFileName: String

        /// SHA-256 digest used for remote reconciliation and manifest validation.
        let archiveSHA256: String

        /// Exact compressed archive byte count.
        let archiveSize: Int64

        /// Logical generation timestamp.
        let timestamp: Int64

        /// Complete accepted log map after applying this generation.
        let updatedEntries: [RemoteSyncLogEntry]

        /// Exact log entries emitted into the sparse database.
        let uploadedEntries: [RemoteSyncLogEntry]?

        /// Immutable projected accepted baseline.
        let acceptedBaseline: RemoteSyncAISettingsAcceptedBaseline

        /// Baseline revision captured before archive creation.
        let expectedAcceptedBaselineRevision: UUID?

        /// Whether a baseline existed before archive creation.
        let expectedAcceptedBaselineExists: Bool

        /// Upsert counts keyed by each of the seven synchronized Android tables.
        let upsertCountsByTable: [String: Int]

        /// Delete counts keyed by each of the seven synchronized Android tables.
        let deleteCountsByTable: [String: Int]

        /// Total Android log rows emitted into the patch.
        let logEntryCount: Int

        /// Self-authenticating publication identity; omitted while its payload is encoded.
        var publicationIdentity: RemoteSyncPublicationIdentity? = nil
    }

    /** Sparse rows and preserved log operations for one outbound generation. */
    private struct ChangeSet {
        /// Changed provider configuration rows keyed by Android log identity.
        var providerRowsByKey: [String: RemoteSyncAndroidAIProvider] = [:]

        /// Changed configured-model rows keyed by Android log identity.
        var configuredModelRowsByKey: [String: RemoteSyncAndroidAIConfiguredModel] = [:]

        /// Changed custom-prompt rows keyed by Android log identity.
        var agentPromptRowsByKey: [String: RemoteSyncAndroidAIAgentPrompt] = [:]

        /// Changed singleton global-settings rows keyed by Android log identity.
        var globalSettingsRowsByKey: [String: RemoteSyncAndroidGlobalAISettings] = [:]

        /// Changed per-device usage rows keyed by Android log identity.
        var usageRowsByKey: [String: RemoteSyncAndroidAIUsageRecord] = [:]

        /// Changed prompt-category rows keyed by Android log identity.
        var promptCategoryRowsByKey: [String: RemoteSyncAndroidAIPromptCategory] = [:]

        /// Changed built-in prompt override rows keyed by Android log identity.
        var builtinOverrideRowsByKey: [String: RemoteSyncAndroidAIBuiltinPromptOverride] = [:]

        /// Sorted Android operations emitted into the sparse patch.
        var logEntries: [RemoteSyncLogEntry] = []

        /// Complete accepted log map after overlaying emitted operations.
        var updatedEntriesByKey: [String: RemoteSyncLogEntry] = [:]

        /** Returns deterministic upsert counts for all seven synchronized tables. */
        var upsertCountsByTable: [String: Int] {
            [
                "LlmProviderConfig": providerRowsByKey.count,
                "LlmConfiguredModel": configuredModelRowsByKey.count,
                "AgentPrompt": agentPromptRowsByKey.count,
                "GlobalAiSettings": globalSettingsRowsByKey.count,
                "LlmUsageRecord": usageRowsByKey.count,
                "PromptCategory": promptCategoryRowsByKey.count,
                "BuiltinPromptOverride": builtinOverrideRowsByKey.count,
            ]
        }

        /** Returns deterministic delete counts for all seven synchronized tables. */
        var deleteCountsByTable: [String: Int] {
            var counts = Dictionary(
                uniqueKeysWithValues: RemoteSyncAISettingsPatchUploadService.supportedTableNames.map { ($0, 0) }
            )
            for entry in logEntries where entry.type == .delete {
                counts[entry.tableName, default: 0] += 1
            }
            return counts
        }
    }

    /** Changed rows and preserved operations collected for one synchronized table. */
    private struct ChangedRows<Row> {
        /// Sparse current rows keyed by Android log identity.
        let rowsByKey: [String: Row]

        /// Mutation-time or synthetic upsert operations paired with the sparse rows.
        let logEntries: [RemoteSyncLogEntry]

        /// Upsert operations keyed by the same canonical Android identities as `rowsByKey`.
        let entriesByKey: [String: RemoteSyncLogEntry]
    }

    /// Exact Android `AI_SETTINGS` table order used for patches and public reports.
    private static let supportedTableNames = [
        "LlmProviderConfig",
        "LlmConfiguredModel",
        "AgentPrompt",
        "GlobalAiSettings",
        "LlmUsageRecord",
        "PromptCategory",
        "BuiltinPromptOverride",
    ]

    /// Fast membership set paired with `supportedTableNames`' deterministic order.
    private static let supportedTableNameSet = Set(supportedTableNames)

    /// Active remote backend used for discovery and publication.
    private let adapter: any RemoteSyncAdapting

    /// Digest-aware remote same-name patch reconciler.
    private let remotePatchReconciler: RemoteSyncRemotePatchReconciler

    /// Strict seven-table SwiftData projector and baseline store.
    private let snapshotService: RemoteSyncAISettingsSnapshotService

    /// Complete Android Room v23 sparse-database writer.
    private let databaseWriter: RemoteSyncAISettingsDatabaseWriter

    /// Filesystem dependency shared by temporary and durable archive operations.
    private let fileManager: FileManager

    /// Directory used for uncompressed transient SQLite databases.
    private let temporaryDirectory: URL

    /// Directory retaining restart-safe compressed outbox archives.
    private let outboxDirectory: URL

    /// Millisecond clock used to allocate monotonic synthetic operation timestamps.
    private let nowProvider: () -> Int64

    /// Settings row containing the current AI settings outbox generation.
    static let pendingUploadKey = "remote_sync.pending_upload.ai_settings"

    /**
     Creates an AI settings patch upload service for one remote backend.

     - Parameters:
       - adapter: Backend used to list, reconcile, and upload patch archives.
       - snapshotService: Strict projector for the seven non-secret synchronized tables.
       - fileManager: Filesystem dependency used by writer and outbox operations.
       - temporaryDirectory: Optional uncompressed-database directory override.
       - outboxDirectory: Optional durable archive directory override.
       - nowProvider: Millisecond clock; generated timestamps are advanced beyond all watermarks.
     - Side effects: Construction creates no files and performs no reads or network requests.
     - Failure modes: Construction cannot fail.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        snapshotService: RemoteSyncAISettingsSnapshotService = RemoteSyncAISettingsSnapshotService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        outboxDirectory: URL? = nil,
        nowProvider: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000.0)
        }
    ) {
        self.adapter = adapter
        remotePatchReconciler = RemoteSyncRemotePatchReconciler(adapter: adapter)
        self.snapshotService = snapshotService
        databaseWriter = RemoteSyncAISettingsDatabaseWriter(fileManager: fileManager)
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.outboxDirectory = outboxDirectory
            ?? temporaryDirectory?.appendingPathComponent("remote-sync-ai-settings-outbox", isDirectory: true)
            ?? Self.defaultOutboxDirectory(fileManager: fileManager)
        self.nowProvider = nowProvider
    }

    /**
     Builds and uploads the next sparse AI settings patch when local state differs from its baseline.

     - Parameters:
       - bootstrapState: Ready AI settings category state identifying the remote device folder.
       - modelContext: Clean context containing all seven synchronized AI models and settings rows.
       - settingsStore: Settings store constructed from `modelContext`.
       - schemaVersion: Exact Android Room schema version; only v23 is accepted.
     - Returns: Accepted generation report, or `nil` when no local mutation exists.
     - Side effects: Records local mutations, persists/resumes an outbox, performs remote I/O, and
       atomically publishes accepted log, status, progress, fingerprint, and row-identity state.
     - Throws: Projection, journal, schema, filesystem, transport, reconciliation, or transaction errors.
     - Important: Journaled mutation timestamps and tombstones are preserved across retries.
     */
    public func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = RemoteSyncCategory.aiSettings.currentSchemaVersion
    ) async throws -> RemoteSyncAISettingsPatchUploadReport? {
        try await uploadPendingPatch(
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion,
            acceptanceCheckpoint: {}
        )
    }

    /**
     Resumes an existing AI settings outbox without projecting a new generation.

     - Parameters:
       - bootstrapState: Ready category state identifying the pending destination.
       - modelContext: Clean context containing AI settings and synchronization metadata.
       - settingsStore: Settings store constructed from `modelContext`.
       - schemaVersion: Exact Android Room schema version expected by the manifest.
     - Returns: Accepted pending-generation report, or `nil` when no outbox exists.
     - Side effects: May reconcile/upload persisted bytes and atomically accept their metadata.
     - Throws: Malformed state, destination/schema mismatch, stale baseline, transport, or local
       acceptance errors.
     - Important: This method never projects the live graph or allocates another patch number.
     */
    public func resumePendingUploadIfPresent(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = RemoteSyncCategory.aiSettings.currentSchemaVersion
    ) async throws -> RemoteSyncAISettingsPatchUploadReport? {
        try await resumePendingUploadIfPresent(
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion,
            acceptanceCheckpoint: {}
        )
    }

    /**
     Explicitly discards an unaccepted AI settings outbox at a destination-replacement boundary.

     - Parameters:
       - modelContext: Clean context containing local synchronization settings.
       - settingsStore: Store containing the pending manifest.
     - Side effects: Atomically removes the manifest, then best-effort removes its archive. Accepted
       metadata and live AI rows remain unchanged and therefore dirty.
     - Throws: Malformed-manifest or settings transaction errors leave the archive untouched.
     */
    public func discardPendingUploadForDestinationReplacement(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws {
        guard let pendingUpload = try settingsStore.performAtomicBatch(in: modelContext, {
            try loadPendingUpload(settingsStore: settingsStore)
        }) else {
            return
        }
        try invalidatePendingUpload(
            pendingUpload,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
    }

    /**
     Resumes a durable generation with a deterministic pre-commit checkpoint for failure tests.

     - Parameters:
       - bootstrapState: Ready category state identifying the pending destination.
       - modelContext: Clean context containing AI settings and synchronization metadata.
       - settingsStore: Store containing the pending manifest.
       - schemaVersion: Exact Android Room schema version expected by the manifest.
       - acceptanceCheckpoint: Callback after all acceptance mutations and before commit.
     - Returns: Accepted pending-generation report, or `nil` when no outbox exists.
     - Side effects: Reconciles/uploads and accepts only the existing persisted generation.
     - Throws: Destination, manifest, transport, baseline compare-and-swap, transaction, and
       checkpoint failures.
     */
    func resumePendingUploadIfPresent(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = RemoteSyncCategory.aiSettings.currentSchemaVersion,
        acceptanceCheckpoint: @escaping () throws -> Void
    ) async throws -> RemoteSyncAISettingsPatchUploadReport? {
        let deviceFolderID = try Self.validatedDeviceFolderID(from: bootstrapState)
        guard let pendingUpload = try settingsStore.performAtomicBatch(in: modelContext, {
            try loadPendingUpload(settingsStore: settingsStore)
        }) else {
            return nil
        }
        guard pendingUpload.schemaVersion == schemaVersion,
              pendingUpload.deviceFolderID == deviceFolderID else {
            throw RemoteSyncAISettingsPatchUploadError.invalidPendingUpload
        }
        return try await finishPendingUpload(
            pendingUpload,
            modelContext: modelContext,
            settingsStore: settingsStore,
            acceptanceCheckpoint: acceptanceCheckpoint
        )
    }

    /**
     Executes AI settings upload with a deterministic final local-acceptance checkpoint.

     - Parameters:
       - bootstrapState: Ready AI settings category bootstrap state.
       - modelContext: Clean context containing synchronized AI models and settings rows.
       - settingsStore: Store constructed from the supplied context.
       - schemaVersion: Exact Android Room schema version; values other than v23 fail closed.
       - acceptanceCheckpoint: Callback after acceptance mutations and before transaction commit.
     - Returns: Accepted generation report, or `nil` for an unchanged baselined projection.
     - Side effects: Records mutations, creates or resumes a durable outbox, performs remote I/O, and
       atomically publishes accepted synchronization metadata.
     - Throws: Strict reads, journal, schema, settings, filesystem, transport, reconciliation, and
       checkpoint failures without advancing accepted state.
     */
    func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = RemoteSyncCategory.aiSettings.currentSchemaVersion,
        acceptanceCheckpoint: @escaping () throws -> Void
    ) async throws -> RemoteSyncAISettingsPatchUploadReport? {
        let deviceFolderID = try Self.validatedDeviceFolderID(from: bootstrapState)
        guard schemaVersion == RemoteSyncCategory.aiSettings.currentSchemaVersion else {
            throw RemoteSyncAISettingsPatchUploadError.unsupportedSchemaVersion(schemaVersion)
        }

        if let resumed = try await resumePendingUploadIfPresent(
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion,
            acceptanceCheckpoint: acceptanceCheckpoint
        ) {
            return resumed
        }

        let hasPendingMutations = try settingsStore.performAtomicBatch(in: modelContext) {
            let mutationJournal = RemoteSyncMutationJournalService(nowProvider: nowProvider)
            try mutationJournal.recordLocalChanges(
                for: .aiSettings,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            return try !mutationJournal.pendingMutations(
                for: .aiSettings,
                settingsStore: settingsStore
            ).isEmpty
        }
        guard hasPendingMutations else {
            return nil
        }

        let highestRemotePatchNumber = try await highestRemotePatchNumber(in: deviceFolderID)
        let generation: UploadGeneration? = try settingsStore.performAtomicBatch(in: modelContext) {
            let sourceDevice = Self.sourceDeviceName(from: deviceFolderID)
            let mutationJournal = RemoteSyncMutationJournalService(nowProvider: nowProvider)
            try mutationJournal.recordLocalChanges(
                for: .aiSettings,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            let pendingMutations = try mutationJournal.pendingMutations(
                for: .aiSettings,
                settingsStore: settingsStore
            )
            let snapshot = try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            let previousBaseline = try snapshotService.storedAcceptedBaseline(settingsStore: settingsStore)
            let acceptedBaseline = try snapshotService.acceptedBaseline(from: snapshot)
            let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
            let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
            let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
            let existingEntriesByKey = Dictionary(
                uniqueKeysWithValues: try logEntryStore.entriesStrict(for: .aiSettings).map {
                    (logEntryStore.key(for: .aiSettings, entry: $0), $0)
                }
            )
            let patchStatuses = try patchStatusStore.statusesStrict(for: .aiSettings)
            let progressState = RemoteSyncStateStore(settingsStore: settingsStore)
                .progressState(for: .aiSettings)
            let timestamp = try RemoteSyncLogicalSequence.nextTimestamp(
                now: nowProvider(),
                highWatermarks: existingEntriesByKey.values.map(\.lastUpdated)
                    + patchStatuses.map(\.appliedDate)
                    + [progressState.lastPatchWritten, progressState.lastSynchronized].compactMap { $0 }
            )
            var acceptedRowsByKey = Dictionary(
                uniqueKeysWithValues: (previousBaseline?.rowIdentities ?? []).map { ($0.key, $0) }
            )
            for (key, entry) in existingEntriesByKey
            where entry.type != .delete
                && Self.supportedTableNameSet.contains(entry.tableName)
                && currentRowExists(forKey: key, in: snapshot) {
                acceptedRowsByKey[key] = RemoteSyncAISettingsAcceptedRowIdentity(
                    key: key,
                    tableName: entry.tableName,
                    entityID1: entry.entityID1,
                    entityID2: entry.entityID2
                )
            }

            let changeSet = try buildChangeSet(
                snapshot: snapshot,
                existingEntriesByKey: existingEntriesByKey,
                acceptedRowsByKey: acceptedRowsByKey,
                fingerprintStore: fingerprintStore,
                pendingMutations: pendingMutations,
                timestamp: timestamp,
                sourceDevice: sourceDevice
            )
            if changeSet.logEntries.isEmpty {
                if previousBaseline == nil {
                    try snapshotService.acceptBaseline(acceptedBaseline, settingsStore: settingsStore)
                }
                return nil
            }

            let highestAcceptedPatchNumber = patchStatuses
                .filter { $0.sourceDevice == sourceDevice }
                .map(\.patchNumber)
                .max() ?? 0
            let patchNumber: Int64
            do {
                patchNumber = try RemoteSyncPublicationIdentity.nextPatchNumber(
                    after: [highestAcceptedPatchNumber, highestRemotePatchNumber]
                )
            } catch {
                throw RemoteSyncAISettingsPatchUploadError.patchNumberOverflow
            }
            return UploadGeneration(
                sourceSnapshot: snapshot,
                acceptedBaseline: acceptedBaseline,
                expectedAcceptedBaselineRevision: previousBaseline?.revision,
                expectedAcceptedBaselineExists: previousBaseline != nil,
                changeSet: changeSet,
                patchNumber: patchNumber,
                sourceDevice: sourceDevice,
                timestamp: timestamp
            )
        }

        guard let generation else { return nil }
        let patchFileName = "\(generation.patchNumber).\(schemaVersion).sqlite3.gz"
        let databaseURL = temporaryURL(prefix: "remote-sync-ai-settings-upload-", suffix: ".sqlite3")
        defer { try? fileManager.removeItem(at: databaseURL) }

        try writePatchDatabase(
            at: databaseURL,
            schemaVersion: schemaVersion,
            snapshot: generation.sourceSnapshot,
            changeSet: generation.changeSet
        )
        let pendingUpload = try persistPendingUpload(
            generation: generation,
            databaseURL: databaseURL,
            patchFileName: patchFileName,
            deviceFolderID: deviceFolderID,
            schemaVersion: schemaVersion,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        return try await finishPendingUpload(
            pendingUpload,
            modelContext: modelContext,
            settingsStore: settingsStore,
            acceptanceCheckpoint: acceptanceCheckpoint
        )
    }

    /**
     Persists one exact compressed archive and signed acceptance manifest before network upload.

     - Parameters:
       - generation: Strict immutable sparse-patch generation.
       - databaseURL: Complete Android Room v23 patch database to compress.
       - patchFileName: Android-compatible remote patch filename.
       - deviceFolderID: Permanent remote destination for this generation.
       - schemaVersion: Exact Android Room schema version.
       - modelContext: Clean context shared by AI settings and synchronization settings.
       - settingsStore: Store receiving the pending manifest.
     - Returns: Complete durable pending generation.
     - Side effects: Writes one outbox archive and atomically stores its signed manifest.
     - Throws: Filesystem, compression, encoding, identity, or settings transaction errors; the
       archive is removed when manifest publication fails.
     */
    private func persistPendingUpload(
        generation: UploadGeneration,
        databaseURL: URL,
        patchFileName: String,
        deviceFolderID: String,
        schemaVersion: Int,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> PendingUpload {
        try fileManager.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)
        let generationID = UUID()
        let archiveFileName = "ai-settings-\(generationID.uuidString.lowercased()).sqlite3.gz"
        let archiveURL = outboxDirectory.appendingPathComponent(archiveFileName, isDirectory: false)
        var keepsArchive = false
        defer {
            if !keepsArchive {
                try? fileManager.removeItem(at: archiveURL)
            }
        }
        let archiveFingerprint = try RemoteSyncArchiveStagingService.gzipPatchDatabase(
            at: databaseURL,
            to: archiveURL
        )

        var pendingUpload = PendingUpload(
            generationID: generationID,
            deviceFolderID: deviceFolderID,
            sourceDevice: generation.sourceDevice,
            patchNumber: generation.patchNumber,
            schemaVersion: schemaVersion,
            patchFileName: patchFileName,
            archiveFileName: archiveFileName,
            archiveSHA256: archiveFingerprint.sha256,
            archiveSize: archiveFingerprint.byteCount,
            timestamp: generation.timestamp,
            updatedEntries: generation.changeSet.updatedEntriesByKey.values.sorted(by: Self.logEntrySort),
            uploadedEntries: generation.changeSet.logEntries,
            acceptedBaseline: generation.acceptedBaseline,
            expectedAcceptedBaselineRevision: generation.expectedAcceptedBaselineRevision,
            expectedAcceptedBaselineExists: generation.expectedAcceptedBaselineExists,
            upsertCountsByTable: generation.changeSet.upsertCountsByTable,
            deleteCountsByTable: generation.changeSet.deleteCountsByTable,
            logEntryCount: generation.changeSet.logEntries.count
        )
        pendingUpload.publicationIdentity = try RemoteSyncPublicationIdentity.patch(
            category: .aiSettings,
            destinationID: pendingUpload.deviceFolderID,
            sourceDevice: pendingUpload.sourceDevice,
            patchNumber: pendingUpload.patchNumber,
            schemaVersion: pendingUpload.schemaVersion,
            remoteFileName: pendingUpload.patchFileName,
            archiveFileName: pendingUpload.archiveFileName,
            archiveSHA256: pendingUpload.archiveSHA256,
            archiveSize: pendingUpload.archiveSize,
            rowCounts: Self.publicationRowCounts(for: pendingUpload),
            acceptancePayload: pendingUpload
        )
        do {
            try settingsStore.performAtomicBatch(in: modelContext) {
                guard try loadPendingUpload(settingsStore: settingsStore) == nil else {
                    throw RemoteSyncAISettingsPatchUploadError.invalidPendingUpload
                }
                try storePendingUpload(pendingUpload, settingsStore: settingsStore)
            }
        } catch {
            throw error
        }
        keepsArchive = true
        return pendingUpload
    }

    /**
     Reconciles or uploads one persisted generation and publishes local acceptance atomically.

     Existing same-name remote files are downloaded and compared with the durable archive digest.
     This closes the process-death window after remote commit without regenerating bytes from a live
     graph that may already have changed.

     - Parameters:
       - pendingUpload: Durable generation to reconcile and accept.
       - modelContext: Clean shared SwiftData context.
       - settingsStore: Store containing pending and accepted synchronization metadata.
       - acceptanceCheckpoint: Deterministic callback after acceptance mutation and before commit.
     - Returns: Report describing the exact accepted generation.
     - Side effects: Lists/downloads/uploads remote data, atomically publishes accepted local state,
       and removes the outbox archive after commit.
     - Throws: Missing/conflicting bytes, transport, stale baseline, settings, transaction, or
       checkpoint errors; the outbox remains resumable on failure.
     */
    private func finishPendingUpload(
        _ pendingUpload: PendingUpload,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        acceptanceCheckpoint: @escaping () throws -> Void
    ) async throws -> RemoteSyncAISettingsPatchUploadReport {
        let archiveURL = try pendingArchiveURL(for: pendingUpload)
        let reconciliation = try await remotePatchReconciler.reconcile(
            archive: RemoteSyncDurablePatchArchive(
                fileName: pendingUpload.patchFileName,
                fileURL: archiveURL,
                sha256: pendingUpload.archiveSHA256,
                size: pendingUpload.archiveSize,
                parentID: pendingUpload.deviceFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let acceptedRemoteFile: RemoteSyncFile
        switch reconciliation {
        case .created(let file), .matchedExisting(let file):
            acceptedRemoteFile = file
        }

        try settingsStore.performAtomicBatch(in: modelContext) {
            guard try loadPendingUpload(settingsStore: settingsStore) == pendingUpload else {
                throw RemoteSyncAISettingsPatchUploadError.invalidPendingUpload
            }
            try snapshotService.validateAcceptedBaselineRevision(
                expectedRevision: pendingUpload.expectedAcceptedBaselineRevision,
                expectedBaselineExists: pendingUpload.expectedAcceptedBaselineExists,
                settingsStore: settingsStore
            )
            let currentSnapshot = try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            try RemoteSyncMutationJournalService().mergeAcceptedLogEntries(
                acceptedEntries: pendingUpload.updatedEntries,
                uploadedEntries: pendingUpload.uploadedEntries ?? pendingUpload.updatedEntries.filter {
                    $0.lastUpdated == pendingUpload.timestamp && $0.sourceDevice == pendingUpload.sourceDevice
                },
                acceptedFingerprints: pendingUpload.acceptedBaseline.fingerprintsByKey,
                currentFingerprints: currentSnapshot.fingerprintsByKey,
                category: .aiSettings,
                settingsStore: settingsStore
            )
            let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
            _ = try patchStatusStore.statusesStrict(for: .aiSettings)
            patchStatusStore.addStatus(
                RemoteSyncPatchStatus(
                    sourceDevice: pendingUpload.sourceDevice,
                    patchNumber: pendingUpload.patchNumber,
                    sizeBytes: acceptedRemoteFile.size,
                    appliedDate: acceptedRemoteFile.timestamp
                ),
                for: .aiSettings
            )
            let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
            var progressState = stateStore.progressState(for: .aiSettings)
            progressState.lastPatchWritten = pendingUpload.timestamp
            stateStore.setProgressState(progressState, for: .aiSettings)
            try snapshotService.acceptBaseline(
                pendingUpload.acceptedBaseline,
                settingsStore: settingsStore
            )
            try acceptanceCheckpoint()
            settingsStore.remove(Self.pendingUploadKey)
        }

        try? fileManager.removeItem(at: archiveURL)
        return RemoteSyncAISettingsPatchUploadReport(
            uploadedFile: acceptedRemoteFile,
            patchNumber: pendingUpload.patchNumber,
            tableReports: Self.tableReports(for: pendingUpload),
            logEntryCount: pendingUpload.logEntryCount,
            lastUpdated: pendingUpload.timestamp
        )
    }

    /**
     Invalidates an AI settings outbox only after explicit lifecycle destination replacement.

     - Parameters:
       - pendingUpload: Old destination-bound generation.
       - modelContext: Clean shared context.
       - settingsStore: Store containing its manifest.
     - Side effects: Atomically removes only the pending marker and then removes its archive best effort.
     - Throws: Manifest validation or settings transaction errors leave state unchanged.
     */
    private func invalidatePendingUpload(
        _ pendingUpload: PendingUpload,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws {
        try settingsStore.performAtomicBatch(in: modelContext) {
            guard try loadPendingUpload(settingsStore: settingsStore) == pendingUpload else {
                throw RemoteSyncAISettingsPatchUploadError.invalidPendingUpload
            }
            settingsStore.remove(Self.pendingUploadKey)
        }
        if let archiveURL = try? pendingArchiveURL(for: pendingUpload) {
            try? fileManager.removeItem(at: archiveURL)
        }
    }

    /**
     Reads, validates, and authenticates the pending AI settings manifest.

     - Parameter settingsStore: Store containing the optional pending manifest.
     - Returns: Validated manifest, or `nil` when no generation exists.
     - Side effects: Reads one settings value.
     - Throws: `invalidPendingUpload` for malformed JSON, counts, or publication identity.
     */
    private func loadPendingUpload(settingsStore: SettingsStore) throws -> PendingUpload? {
        guard let payload = settingsStore.getString(Self.pendingUploadKey) else { return nil }
        guard let data = payload.data(using: .utf8),
              let pendingUpload = try? JSONDecoder().decode(PendingUpload.self, from: data),
              Set(pendingUpload.upsertCountsByTable.keys) == Self.supportedTableNameSet,
              Set(pendingUpload.deleteCountsByTable.keys) == Self.supportedTableNameSet,
              pendingUpload.upsertCountsByTable.values.allSatisfy({ $0 >= 0 }),
              pendingUpload.deleteCountsByTable.values.allSatisfy({ $0 >= 0 }),
              Self.totalOperationCount(for: pendingUpload) == pendingUpload.logEntryCount,
              let publicationIdentity = pendingUpload.publicationIdentity else {
            throw RemoteSyncAISettingsPatchUploadError.invalidPendingUpload
        }
        var acceptancePayload = pendingUpload
        acceptancePayload.publicationIdentity = nil
        do {
            try publicationIdentity.validate(
                kind: .patch,
                category: .aiSettings,
                destinationID: pendingUpload.deviceFolderID,
                sourceDevice: pendingUpload.sourceDevice,
                patchNumber: pendingUpload.patchNumber,
                schemaVersion: pendingUpload.schemaVersion,
                remoteFileName: pendingUpload.patchFileName,
                archiveFileName: pendingUpload.archiveFileName,
                archiveSHA256: pendingUpload.archiveSHA256,
                archiveSize: pendingUpload.archiveSize,
                rowCounts: Self.publicationRowCounts(for: pendingUpload),
                acceptancePayload: acceptancePayload
            )
        } catch {
            throw RemoteSyncAISettingsPatchUploadError.invalidPendingUpload
        }
        return pendingUpload
    }

    /**
     Returns all signed operation counts for one AI settings publication.

     - Parameter pendingUpload: Identity-free or decoded outbox envelope.
     - Returns: Stable count dictionary covering all seven upsert/delete families and log rows.
     - Side effects: None.
     - Failure modes: This deterministic projection cannot fail for a validated manifest.
     */
    private static func publicationRowCounts(for pendingUpload: PendingUpload) -> [String: Int] {
        var counts: [String: Int] = ["LogEntry.rows": pendingUpload.logEntryCount]
        for tableName in supportedTableNames {
            counts["\(tableName).upserts"] = pendingUpload.upsertCountsByTable[tableName] ?? -1
            counts["\(tableName).deletes"] = pendingUpload.deleteCountsByTable[tableName] ?? -1
        }
        return counts
    }

    /**
     Builds deterministic public table reports from one validated manifest.

     - Parameter pendingUpload: Accepted pending generation.
     - Returns: Seven reports in Android synchronization order.
     - Side effects: None.
     - Failure modes: Validated manifests always contain all required counts.
     */
    private static func tableReports(
        for pendingUpload: PendingUpload
    ) -> [RemoteSyncAISettingsPatchTableReport] {
        supportedTableNames.map { tableName in
            RemoteSyncAISettingsPatchTableReport(
                tableName: tableName,
                upsertedRowCount: pendingUpload.upsertCountsByTable[tableName] ?? 0,
                deletedRowCount: pendingUpload.deleteCountsByTable[tableName] ?? 0
            )
        }
    }

    /**
     Computes the exact operation total without overflowing on a malformed persisted manifest.

     - Parameter pendingUpload: Decoded pending manifest.
     - Returns: Total upserts plus deletes, or `nil` when integer addition overflows.
     - Side effects: None.
     - Failure modes: Overflow is represented as `nil` and causes manifest rejection.
     */
    private static func totalOperationCount(for pendingUpload: PendingUpload) -> Int? {
        var total = 0
        for value in pendingUpload.upsertCountsByTable.values {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        for value in pendingUpload.deleteCountsByTable.values {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    /**
     Encodes and stores one complete pending AI settings upload manifest.

     - Parameters:
       - pendingUpload: Signed durable generation.
       - settingsStore: Store receiving sorted JSON metadata.
     - Side effects: Replaces one settings value.
     - Throws: Encoding or UTF-8 conversion failures as `invalidPendingUpload`.
     */
    private func storePendingUpload(
        _ pendingUpload: PendingUpload,
        settingsStore: SettingsStore
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pendingUpload)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw RemoteSyncAISettingsPatchUploadError.invalidPendingUpload
        }
        settingsStore.setString(Self.pendingUploadKey, value: payload)
    }

    /**
     Resolves a safe pending archive basename beneath the configured outbox.

     - Parameter pendingUpload: Validated manifest containing the local archive basename.
     - Returns: Archive URL constrained beneath `outboxDirectory`.
     - Side effects: None.
     - Throws: `invalidPendingUpload` for empty or path-bearing names.
     */
    private func pendingArchiveURL(for pendingUpload: PendingUpload) throws -> URL {
        guard pendingUpload.archiveFileName == URL(fileURLWithPath: pendingUpload.archiveFileName).lastPathComponent,
              !pendingUpload.archiveFileName.isEmpty else {
            throw RemoteSyncAISettingsPatchUploadError.invalidPendingUpload
        }
        return outboxDirectory.appendingPathComponent(pendingUpload.archiveFileName, isDirectory: false)
    }

    /**
     Reads the highest Android patch number already present in one AI settings device folder.

     - Parameter deviceFolderID: Active remote device-folder identifier.
     - Returns: Highest valid Android patch number, or zero when no patch archive exists.
     - Side effects: Performs one unfiltered remote folder listing.
     - Throws: Backend listing failures so generation creation fails closed.
     */
    private func highestRemotePatchNumber(in deviceFolderID: String) async throws -> Int64 {
        try await adapter.listFiles(
            parentIDs: [deviceFolderID],
            name: nil,
            mimeType: nil,
            modifiedAtLeast: nil
        )
        .compactMap { RemoteSyncPatchDiscoveryService.parsePatchFileName($0.name)?.patchNumber }
        .max() ?? 0
    }

    /**
     Resolves the production AI settings outbox beneath Application Support.

     - Parameter fileManager: Filesystem dependency used to locate Application Support.
     - Returns: Stable category-specific durable outbox directory.
     - Side effects: None; the directory is created only when a generation is persisted.
     - Failure modes: Falls back to the process temporary directory when Application Support is absent.
     */
    static func defaultOutboxDirectory(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent("AndBible", isDirectory: true)
            .appendingPathComponent("RemoteSyncOutbox", isDirectory: true)
            .appendingPathComponent("ai-settings", isDirectory: true)
    }

    /**
     Diffs all seven current row maps against accepted fingerprints and durable tombstone identities.

     - Parameters:
       - snapshot: Strict complete current AI settings projection.
       - existingEntriesByKey: Accepted local/remote Android log map.
       - acceptedRowsByKey: Durable identities for rows accepted in prior generations.
       - fingerprintStore: Accepted row fingerprint store.
       - pendingMutations: Mutation-time operations captured before projection.
       - timestamp: Logical fallback timestamp for legacy unjournaled differences.
       - sourceDevice: Source device for fallback operations.
     - Returns: Sparse rows plus preserved upsert/delete log operations.
     - Side effects: Reads accepted fingerprints; does not mutate persistence.
     - Throws: Mutation-journal identity or state-fingerprint validation errors.
     */
    private func buildChangeSet(
        snapshot: RemoteSyncAISettingsCurrentSnapshot,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        acceptedRowsByKey: [String: RemoteSyncAISettingsAcceptedRowIdentity],
        fingerprintStore: RemoteSyncRowFingerprintStore,
        pendingMutations: [String: RemoteSyncPendingMutation],
        timestamp: Int64,
        sourceDevice: String
    ) throws -> ChangeSet {
        var changeSet = ChangeSet(updatedEntriesByKey: existingEntriesByKey)

        let providers = try changedRows(
            snapshot.providerRowsByKey,
            tableName: "LlmProviderConfig",
            id: \.id,
            snapshot: snapshot,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            pendingMutations: pendingMutations,
            timestamp: timestamp,
            sourceDevice: sourceDevice
        )
        changeSet.providerRowsByKey = providers.rowsByKey
        merge(providers, into: &changeSet)

        let configuredModels = try changedRows(
            snapshot.configuredModelRowsByKey,
            tableName: "LlmConfiguredModel",
            id: \.id,
            snapshot: snapshot,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            pendingMutations: pendingMutations,
            timestamp: timestamp,
            sourceDevice: sourceDevice
        )
        changeSet.configuredModelRowsByKey = configuredModels.rowsByKey
        merge(configuredModels, into: &changeSet)

        let agentPrompts = try changedRows(
            snapshot.agentPromptRowsByKey,
            tableName: "AgentPrompt",
            id: \.id,
            snapshot: snapshot,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            pendingMutations: pendingMutations,
            timestamp: timestamp,
            sourceDevice: sourceDevice
        )
        changeSet.agentPromptRowsByKey = agentPrompts.rowsByKey
        merge(agentPrompts, into: &changeSet)

        let globalSettings = try changedRows(
            snapshot.globalSettingsRowsByKey,
            tableName: "GlobalAiSettings",
            id: \.id,
            snapshot: snapshot,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            pendingMutations: pendingMutations,
            timestamp: timestamp,
            sourceDevice: sourceDevice
        )
        changeSet.globalSettingsRowsByKey = globalSettings.rowsByKey
        merge(globalSettings, into: &changeSet)

        let usageRecords = try changedRows(
            snapshot.usageRowsByKey,
            tableName: "LlmUsageRecord",
            id: \.id,
            snapshot: snapshot,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            pendingMutations: pendingMutations,
            timestamp: timestamp,
            sourceDevice: sourceDevice
        )
        changeSet.usageRowsByKey = usageRecords.rowsByKey
        merge(usageRecords, into: &changeSet)

        let promptCategories = try changedRows(
            snapshot.promptCategoryRowsByKey,
            tableName: "PromptCategory",
            id: \.id,
            snapshot: snapshot,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            pendingMutations: pendingMutations,
            timestamp: timestamp,
            sourceDevice: sourceDevice
        )
        changeSet.promptCategoryRowsByKey = promptCategories.rowsByKey
        merge(promptCategories, into: &changeSet)

        let builtinOverrides = try changedRows(
            snapshot.builtinOverrideRowsByKey,
            tableName: "BuiltinPromptOverride",
            id: \.id,
            snapshot: snapshot,
            existingEntriesByKey: existingEntriesByKey,
            fingerprintStore: fingerprintStore,
            pendingMutations: pendingMutations,
            timestamp: timestamp,
            sourceDevice: sourceDevice
        )
        changeSet.builtinOverrideRowsByKey = builtinOverrides.rowsByKey
        merge(builtinOverrides, into: &changeSet)

        var deletionRowsByKey = acceptedRowsByKey
        for (key, mutation) in pendingMutations where mutation.entry.type == .delete {
            deletionRowsByKey[key] = RemoteSyncAISettingsAcceptedRowIdentity(
                key: key,
                tableName: mutation.entry.tableName,
                entityID1: mutation.entry.entityID1,
                entityID2: mutation.entry.entityID2
            )
        }
        for (key, identity) in deletionRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard Self.supportedTableNameSet.contains(identity.tableName),
                  !currentRowExists(forKey: key, in: snapshot),
                  existingEntriesByKey[key]?.type != .delete || pendingMutations[key] != nil else {
                continue
            }
            let deleteEntry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: nil,
                type: .delete,
                category: .aiSettings,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                tableName: identity.tableName,
                entityID1: identity.entityID1,
                entityID2: identity.entityID2,
                type: .delete,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            changeSet.logEntries.append(deleteEntry)
            changeSet.updatedEntriesByKey[key] = deleteEntry
        }

        changeSet.logEntries.sort(by: Self.logEntrySort)
        return changeSet
    }

    /**
     Collects changed rows for one UUID-keyed synchronized table without altering timestamps.

     - Parameters:
       - rows: Complete current table projection keyed by Android log identity.
       - tableName: Exact Android synchronized table name.
       - id: Stable UUID extractor for the row family.
       - snapshot: Complete snapshot containing deterministic row fingerprints.
       - existingEntriesByKey: Accepted Android log map.
       - fingerprintStore: Accepted fingerprint store.
       - pendingMutations: Mutation-time journal operations.
       - timestamp: Logical timestamp used only for unjournaled legacy differences.
       - sourceDevice: Source device used only for unjournaled legacy differences.
     - Returns: Sparse rows paired with their exact upsert operations.
     - Side effects: Reads accepted fingerprints; does not mutate persistence.
     - Throws: Journal state mismatch errors from `entryForUpload`.
     */
    private func changedRows<Row>(
        _ rows: [String: Row],
        tableName: String,
        id: (Row) -> UUID,
        snapshot: RemoteSyncAISettingsCurrentSnapshot,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore,
        pendingMutations: [String: RemoteSyncPendingMutation],
        timestamp: Int64,
        sourceDevice: String
    ) throws -> ChangedRows<Row> {
        var rowsByKey: [String: Row] = [:]
        var logEntries: [RemoteSyncLogEntry] = []
        var entriesByKey: [String: RemoteSyncLogEntry] = [:]
        for (key, row) in rows.sorted(by: { $0.key < $1.key }) {
            let hasPendingUpsert = pendingMutations[key]?.entry.type == .upsert
            guard hasPendingUpsert || shouldUploadCurrentRow(
                    key: key,
                    currentFingerprint: snapshot.fingerprintsByKey[key],
                    existingEntriesByKey: existingEntriesByKey,
                    fingerprintStore: fingerprintStore
                  ) else {
                continue
            }
            let entry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: snapshot.fingerprintsByKey[key],
                type: .upsert,
                category: .aiSettings,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                tableName: tableName,
                entityID1: .blob(RemoteSyncAISettingsSnapshotService.uuidBlob(id(row))),
                entityID2: RemoteSyncAISettingsSnapshotService.emptySecondaryEntityID,
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            rowsByKey[key] = row
            logEntries.append(entry)
            entriesByKey[key] = entry
        }
        return ChangedRows(
            rowsByKey: rowsByKey,
            logEntries: logEntries,
            entriesByKey: entriesByKey
        )
    }

    /**
     Overlays one table's changed operations onto the generation-wide accepted log map.

     - Parameters:
       - changedRows: Sparse rows and keyed upsert operations produced for one table.
       - changeSet: Generation accumulator receiving the operations.
     - Side effects: Mutates only the in-memory change set.
     - Failure modes: This deterministic overlay cannot fail.
     */
    private func merge<Row>(_ changedRows: ChangedRows<Row>, into changeSet: inout ChangeSet) {
        changeSet.logEntries.append(contentsOf: changedRows.logEntries)
        for (key, entry) in changedRows.entriesByKey {
            changeSet.updatedEntriesByKey[key] = entry
        }
    }

    /**
     Determines whether one current row differs from accepted state.

     - Parameters:
       - key: Canonical Android log identity key.
       - currentFingerprint: Fingerprint of the complete current wire row.
       - existingEntriesByKey: Accepted Android log map.
       - fingerprintStore: Accepted row fingerprint store.
     - Returns: `true` when fingerprint state requires an upsert. The caller separately treats a
       matching mutation-journal marker as authoritative even when replay refreshed the baseline.
     - Side effects: Reads settings-backed fingerprints.
     - Failure modes: Missing accepted fingerprints fail dirty rather than suppressing publication.
     */
    private func shouldUploadCurrentRow(
        key: String,
        currentFingerprint: String?,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore
    ) -> Bool {
        guard let currentFingerprint else { return false }
        guard let existingEntry = existingEntriesByKey[key] else {
            if let existingFingerprint = fingerprintStore.fingerprint(
                forLogKey: key,
                category: .aiSettings
            ) {
                return existingFingerprint != currentFingerprint
            }
            return true
        }
        guard Self.supportedTableNameSet.contains(existingEntry.tableName) else { return false }
        if existingEntry.type == .delete { return true }
        guard let existingFingerprint = fingerprintStore.fingerprint(
            for: .aiSettings,
            tableName: existingEntry.tableName,
            entityID1: existingEntry.entityID1,
            entityID2: existingEntry.entityID2
        ) else {
            return true
        }
        return existingFingerprint != currentFingerprint
    }

    /**
     Checks whether any of the seven synchronized row maps contains one Android log identity.

     - Parameters:
       - key: Canonical Android log key.
       - snapshot: Complete current seven-table projection.
     - Returns: `true` when the identity still has a current row.
     - Side effects: None.
     - Failure modes: This dictionary lookup cannot fail.
     */
    private func currentRowExists(
        forKey key: String,
        in snapshot: RemoteSyncAISettingsCurrentSnapshot
    ) -> Bool {
        snapshot.providerRowsByKey[key] != nil
            || snapshot.configuredModelRowsByKey[key] != nil
            || snapshot.agentPromptRowsByKey[key] != nil
            || snapshot.globalSettingsRowsByKey[key] != nil
            || snapshot.usageRowsByKey[key] != nil
            || snapshot.promptCategoryRowsByKey[key] != nil
            || snapshot.builtinOverrideRowsByKey[key] != nil
    }

    /**
     Delegates complete Room v23 shell creation and sparse row insertion to the AI database writer.

     - Parameters:
       - url: Destination for the uncompressed SQLite database.
       - schemaVersion: Exact Android AI settings schema version.
       - snapshot: Complete credential-free source projection used to resolve sparse UPSERT rows.
       - changeSet: Seven-table sparse rows and preserved Android log entries.
     - Side effects: Creates and writes one SQLite file; `LlmRawLogRecord` remains empty.
     - Throws: Unsupported schema or database-writer failures.
     */
    private func writePatchDatabase(
        at url: URL,
        schemaVersion: Int,
        snapshot: RemoteSyncAISettingsCurrentSnapshot,
        changeSet: ChangeSet
    ) throws {
        guard schemaVersion == RemoteSyncCategory.aiSettings.currentSchemaVersion else {
            throw RemoteSyncAISettingsPatchUploadError.unsupportedSchemaVersion(schemaVersion)
        }
        let report = try databaseWriter.writeSparseDatabase(
            at: url,
            snapshot: snapshot,
            selectedLogEntries: changeSet.logEntries,
            schemaVersion: schemaVersion
        )
        let expected = changeSet.upsertCountsByTable
        guard report.schemaVersion == schemaVersion,
              report.providerCount == (expected["LlmProviderConfig"] ?? -1),
              report.configuredModelCount == (expected["LlmConfiguredModel"] ?? -1),
              report.agentPromptCount == (expected["AgentPrompt"] ?? -1),
              report.globalSettingsCount == (expected["GlobalAiSettings"] ?? -1),
              report.usageRecordCount == (expected["LlmUsageRecord"] ?? -1),
              report.promptCategoryCount == (expected["PromptCategory"] ?? -1),
              report.builtinPromptOverrideCount == (expected["BuiltinPromptOverride"] ?? -1),
              report.logEntryCount == changeSet.logEntries.count,
              report.rawLogRecordCount == 0 else {
            throw RemoteSyncAISettingsPatchUploadError.databaseWriteReportMismatch
        }
    }

    /**
     Validates and normalizes the destination folder identifier.

     - Parameter bootstrapState: Category state containing the optional remote folder ID.
     - Returns: Trimmed nonempty folder identifier.
     - Side effects: None.
     - Throws: `missingDeviceFolderID` when no usable destination exists.
     */
    private static func validatedDeviceFolderID(
        from bootstrapState: RemoteSyncBootstrapState
    ) throws -> String {
        guard let deviceFolderID = bootstrapState.deviceFolderID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncAISettingsPatchUploadError.missingDeviceFolderID
        }
        return deviceFolderID
    }

    /** Creates a unique transient file URL without touching the filesystem. */
    private func temporaryURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    /** Derives Android's source-device name from the final destination path component. */
    private static func sourceDeviceName(from deviceFolderID: String) -> String {
        let trimmed = deviceFolderID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? deviceFolderID
    }

    /** Orders Android log operations deterministically without altering their conflict timestamps. */
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

    /** Encodes one SQLite identity into a stable lexical sort key. */
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
