// RemoteSyncMyDocumentPatchUploadService.swift -- Android-shaped outbound My Documents patch creation and upload

import Foundation
import SQLite3
import SwiftData

private let remoteSyncMyDocumentPatchUploadSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while exporting and uploading an outbound Android My Documents patch.
 */
public enum RemoteSyncMyDocumentPatchUploadError: Error, Equatable {
    /// The category is not ready for upload because no remote device folder identifier is known locally.
    case missingDeviceFolderID

    /// The generated temporary SQLite patch database could not be opened for writing.
    case invalidSQLiteDatabase

    /// Persisted outbox metadata is malformed or incompatible with the active destination.
    case invalidPendingUpload

    /// The highest accepted local or remote patch number cannot be incremented safely.
    case patchNumberOverflow

    /// The requested wire schema is not the exact Android Room contract supported by this build.
    case unsupportedSchemaVersion(Int)
}

/**
 Summary of one successful outbound My Documents patch upload.
 */
public struct RemoteSyncMyDocumentPatchUploadReport: Sendable, Equatable {
    /// Remote file metadata returned by the backend after upload succeeded.
    public let uploadedFile: RemoteSyncFile

    /// Monotonic patch number assigned within the current device folder.
    public let patchNumber: Int64

    /// Number of `MyDocument` rows written into the patch database.
    public let upsertedDocumentCount: Int

    /// Number of `MyDocumentPage` rows written into the patch database.
    public let upsertedPageCount: Int

    /// Number of `MyDocumentPageContent` rows written into the patch database.
    public let upsertedPageContentCount: Int

    /// Number of `AiPageCacheEntry` rows written into the patch database.
    public let upsertedAiPageCacheEntryCount: Int

    /// Number of `DELETE` log entries emitted for rows removed locally.
    public let deletedRowCount: Int

    /// Total number of Android `LogEntry` rows written into the patch database.
    public let logEntryCount: Int

    /// Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
    public let lastUpdated: Int64

    /**
     Creates one outbound My Documents patch-upload summary.
     */
    public init(
        uploadedFile: RemoteSyncFile,
        patchNumber: Int64,
        upsertedDocumentCount: Int,
        upsertedPageCount: Int,
        upsertedPageContentCount: Int,
        upsertedAiPageCacheEntryCount: Int,
        deletedRowCount: Int,
        logEntryCount: Int,
        lastUpdated: Int64
    ) {
        self.uploadedFile = uploadedFile
        self.patchNumber = patchNumber
        self.upsertedDocumentCount = upsertedDocumentCount
        self.upsertedPageCount = upsertedPageCount
        self.upsertedPageContentCount = upsertedPageContentCount
        self.upsertedAiPageCacheEntryCount = upsertedAiPageCacheEntryCount
        self.deletedRowCount = deletedRowCount
        self.logEntryCount = logEntryCount
        self.lastUpdated = lastUpdated
    }
}

/**
 Creates Android-shaped sparse My Documents patch databases and uploads them to the active backend.
 */
public final class RemoteSyncMyDocumentPatchUploadService {
    /** Immutable strict projection and metadata used to build one My Documents archive. */
    private struct UploadGeneration {
        let acceptedBaseline: RemoteSyncMyDocumentAcceptedBaseline
        let expectedAcceptedBaselineRevision: UUID?
        let expectedAcceptedBaselineExists: Bool
        let changeSet: ChangeSet
        let patchNumber: Int64
        let sourceDevice: String
        let timestamp: Int64
    }

    /**
     Durable My Documents upload generation retained until remote and local acceptance both succeed.

     Persisting archive identity and exact accepted bookkeeping makes retries restart-safe even when
     the live document graph changes after upload begins.
     */
    private struct PendingUpload: Codable, Equatable {
        let generationID: UUID
        let deviceFolderID: String
        let sourceDevice: String
        let patchNumber: Int64
        let schemaVersion: Int
        let patchFileName: String
        let archiveFileName: String
        let archiveSHA256: String
        let archiveSize: Int64
        let timestamp: Int64
        let updatedEntries: [RemoteSyncLogEntry]
        let uploadedEntries: [RemoteSyncLogEntry]?
        let acceptedBaseline: RemoteSyncMyDocumentAcceptedBaseline
        let expectedAcceptedBaselineRevision: UUID?
        let expectedAcceptedBaselineExists: Bool
        let upsertedDocumentCount: Int
        let upsertedPageCount: Int
        let upsertedPageContentCount: Int
        let upsertedAiPageCacheEntryCount: Int
        let deletedRowCount: Int
        let logEntryCount: Int
        var publicationIdentity: RemoteSyncPublicationIdentity? = nil
    }

    private struct ChangeSet {
        let documentRowsByKey: [String: RemoteSyncAndroidMyDocument]
        let pageRowsByKey: [String: RemoteSyncAndroidMyDocumentPage]
        let pageContentRowsByKey: [String: RemoteSyncAndroidMyDocumentPageContent]
        let aiPageCacheEntryRowsByKey: [String: RemoteSyncAndroidAiPageCacheEntry]
        let logEntries: [RemoteSyncLogEntry]
        let updatedEntriesByKey: [String: RemoteSyncLogEntry]

        var deletedRowCount: Int {
            logEntries.filter { $0.type == .delete }.count
        }
    }

    private static let supportedTableNames: Set<String> = [
        "MyDocument",
        "MyDocumentPage",
        "MyDocumentPageContent",
        "AiPageCacheEntry",
    ]

    private let adapter: any RemoteSyncAdapting
    private let remotePatchReconciler: RemoteSyncRemotePatchReconciler
    private let snapshotService: RemoteSyncMyDocumentSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let outboxDirectory: URL
    private let nowProvider: () -> Int64

    /// Settings row containing the current My Documents outbox generation.
    static let pendingUploadKey = "remote_sync.pending_upload.mydocuments"

    /**
     Creates a My Documents patch upload service for one remote backend.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        snapshotService: RemoteSyncMyDocumentSnapshotService = RemoteSyncMyDocumentSnapshotService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        outboxDirectory: URL? = nil,
        nowProvider: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000.0)
        }
    ) {
        self.adapter = adapter
        self.remotePatchReconciler = RemoteSyncRemotePatchReconciler(adapter: adapter)
        self.snapshotService = snapshotService
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.outboxDirectory = outboxDirectory
            ?? temporaryDirectory?.appendingPathComponent("remote-sync-mydocuments-outbox", isDirectory: true)
            ?? Self.defaultOutboxDirectory(fileManager: fileManager)
        self.nowProvider = nowProvider
    }

    /**
     Builds and uploads the next sparse My Documents patch when local state differs from the baseline.
     */
    public func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion
    ) async throws -> RemoteSyncMyDocumentPatchUploadReport? {
        try await uploadPendingPatch(
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion,
            acceptanceCheckpoint: {}
        )
    }

    /**
     Resumes an existing My Documents outbox without projecting or creating a new generation.

     - Parameters:
       - bootstrapState: Ready category state identifying the pending destination.
       - modelContext: Clean context containing My Documents and settings rows.
       - settingsStore: Settings store constructed from `modelContext`.
       - schemaVersion: Android My Documents schema version.
     - Returns: Accepted pending-generation report, or `nil` when no outbox exists.
     - Side effects: May reconcile/upload the persisted archive and atomically publish accepted state.
     - Failure modes: Throws for malformed state, destination/schema mismatch, stale baseline revision,
       missing/conflicting bytes, transport failure, or local acceptance failure.
     - Important: This method never projects the live graph and never allocates a patch number.
     */
    public func resumePendingUploadIfPresent(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion
    ) async throws -> RemoteSyncMyDocumentPatchUploadReport? {
        try await resumePendingUploadIfPresent(
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion,
            acceptanceCheckpoint: {}
        )
    }

    /**
     Explicitly discards an unaccepted My Documents outbox at a destination-replacement boundary.

     - Parameters:
       - modelContext: Clean context containing local sync settings.
       - settingsStore: Store containing the pending manifest.
     - Side effects: Atomically removes the pending marker, then best-effort removes its archive;
       accepted metadata and live rows remain unchanged and therefore dirty.
     - Failure modes: Rethrows malformed-manifest or settings transaction failures without removing
       the archive.
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
     Resumes a My Documents outbox with a deterministic local-acceptance checkpoint for tests.

     - Parameters:
       - bootstrapState: Ready category state identifying the pending destination.
       - modelContext: Clean context containing My Documents and settings rows.
       - settingsStore: Settings store constructed from `modelContext`.
       - schemaVersion: Android My Documents schema version.
       - acceptanceCheckpoint: Callback invoked after all acceptance mutations and before commit.
     - Returns: Pending-generation report, or `nil` when no outbox exists.
     - Side effects: Reconciles/uploads and accepts only an already-persisted generation.
     - Failure modes: Rethrows destination, manifest, transport, baseline-CAS, transaction, and
       checkpoint failures.
     */
    func resumePendingUploadIfPresent(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion,
        acceptanceCheckpoint: @escaping () throws -> Void
    ) async throws -> RemoteSyncMyDocumentPatchUploadReport? {
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncMyDocumentPatchUploadError.missingDeviceFolderID
        }
        guard let pendingUpload = try settingsStore.performAtomicBatch(in: modelContext, {
            try loadPendingUpload(settingsStore: settingsStore)
        }) else {
            return nil
        }
        guard pendingUpload.schemaVersion == schemaVersion,
              pendingUpload.deviceFolderID == deviceFolderID else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidPendingUpload
        }
        return try await finishPendingUpload(
            pendingUpload,
            modelContext: modelContext,
            settingsStore: settingsStore,
            acceptanceCheckpoint: acceptanceCheckpoint
        )
    }

    /**
     Executes My Documents upload with a deterministic final local-acceptance checkpoint.

     - Parameters:
       - bootstrapState: Ready category bootstrap state.
       - modelContext: Clean context containing My Documents and settings rows.
       - settingsStore: Settings store constructed from `modelContext`.
       - schemaVersion: Android My Documents schema version.
       - acceptanceCheckpoint: Callback invoked after all acceptance mutations and before commit.
     - Returns: Upload report, or `nil` for a fully baselined unchanged projection.
     - Side effects: Persists/resumes a durable outbox, reconciles or uploads one remote archive, and
       atomically publishes accepted log, status, progress, fingerprints, and row identities.
     - Failure modes: Rethrows strict reads, settings transactions, filesystem, transport,
       reconciliation, and checkpoint failures without advancing accepted state.
     */
    func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = RemoteSyncMyDocumentRestoreService.supportedAndroidSchemaVersion,
        acceptanceCheckpoint: @escaping () throws -> Void
    ) async throws -> RemoteSyncMyDocumentPatchUploadReport? {
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncMyDocumentPatchUploadError.missingDeviceFolderID
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
                for: .myDocuments,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            return try !mutationJournal.pendingMutations(
                for: .myDocuments,
                settingsStore: settingsStore
            ).isEmpty
        }
        guard hasPendingMutations else {
            return nil
        }

        let highestRemotePatchNumber = try await highestRemotePatchNumber(in: deviceFolderID)
        let generation: UploadGeneration? = try settingsStore.performAtomicBatch(in: modelContext) {
            let sourceDevice = Self.sourceDeviceName(from: deviceFolderID)
            let wallClockTimestamp = nowProvider()
            let mutationJournal = RemoteSyncMutationJournalService(nowProvider: nowProvider)
            try mutationJournal.recordLocalChanges(
                for: .myDocuments,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            let pendingMutations = try mutationJournal.pendingMutations(
                for: .myDocuments,
                settingsStore: settingsStore
            )
            let snapshot = try snapshotService.snapshotCurrentStateThrowing(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            let previousBaseline = try snapshotService.storedAcceptedBaseline(settingsStore: settingsStore)
            let acceptedBaseline = try snapshotService.acceptedBaselineThrowing(from: snapshot)
            let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
            let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
            let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
            let existingEntriesByKey = Dictionary(
                uniqueKeysWithValues: try logEntryStore.entriesStrict(for: .myDocuments).map {
                    (logEntryStore.key(for: .myDocuments, entry: $0), $0)
                }
            )
            let patchStatuses = try patchStatusStore.statusesStrict(for: .myDocuments)
            let progressState = RemoteSyncStateStore(settingsStore: settingsStore)
                .progressState(for: .myDocuments)
            let timestamp = try RemoteSyncLogicalSequence.nextTimestamp(
                now: wallClockTimestamp,
                highWatermarks: existingEntriesByKey.values.map(\.lastUpdated)
                    + patchStatuses.map(\.appliedDate)
                    + [progressState.lastPatchWritten, progressState.lastSynchronized].compactMap { $0 }
            )
            var acceptedRowsByKey = Dictionary(
                uniqueKeysWithValues: (previousBaseline?.rowIdentities ?? []).map { ($0.key, $0) }
            )
            for (key, entry) in existingEntriesByKey
            where entry.type != .delete && Self.supportedTableNames.contains(entry.tableName) {
                acceptedRowsByKey[key] = RemoteSyncMyDocumentAcceptedRowIdentity(
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
                throw RemoteSyncMyDocumentPatchUploadError.patchNumberOverflow
            }
            return UploadGeneration(
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

        let databaseURL = temporaryURL(prefix: "remote-sync-mydocuments-upload-", suffix: ".sqlite3")
        defer {
            try? fileManager.removeItem(at: databaseURL)
        }

        try writePatchDatabase(
            at: databaseURL,
            schemaVersion: schemaVersion,
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
     Persists one exact My Documents archive and its acceptance metadata before network upload.

     - Parameters:
       - generation: Strict preflight generation.
       - databaseURL: Complete SQLite patch database to compress into the durable outbox.
       - patchFileName: Android patch filename.
       - deviceFolderID: Destination device folder.
       - schemaVersion: Android My Documents schema version.
       - modelContext: Clean context shared by graph and settings.
       - settingsStore: Store receiving the pending manifest.
     - Returns: Durable pending generation.
     - Side effects: Writes one outbox archive and atomically stores its manifest.
     - Failure modes: Rethrows filesystem, encoding, or settings transaction errors and removes the
       archive when manifest publication fails.
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
        let archiveFileName = "mydocuments-\(generationID.uuidString.lowercased()).sqlite3.gz"
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
            upsertedDocumentCount: generation.changeSet.documentRowsByKey.count,
            upsertedPageCount: generation.changeSet.pageRowsByKey.count,
            upsertedPageContentCount: generation.changeSet.pageContentRowsByKey.count,
            upsertedAiPageCacheEntryCount: generation.changeSet.aiPageCacheEntryRowsByKey.count,
            deletedRowCount: generation.changeSet.deletedRowCount,
            logEntryCount: generation.changeSet.logEntries.count
        )
        pendingUpload.publicationIdentity = try RemoteSyncPublicationIdentity.patch(
            category: .myDocuments,
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
                    throw RemoteSyncMyDocumentPatchUploadError.invalidPendingUpload
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
     Reconciles or uploads one pending My Documents generation and accepts it atomically.

     Existing same-name remote files are downloaded and compared against the persisted archive digest.
     This closes the process-death window after remote commit without regenerating bytes from live data.

     - Parameters:
       - pendingUpload: Durable generation to finish.
       - modelContext: Clean shared context.
       - settingsStore: Store containing pending and accepted metadata.
       - acceptanceCheckpoint: Deterministic final in-transaction test checkpoint.
     - Returns: Upload report for the persisted generation.
     - Side effects: Lists/downloads/uploads remote data, atomically publishes local accepted state,
       and removes the outbox archive after commit.
     - Failure modes: Throws for missing/conflicting bytes, transport, settings, or checkpoint errors;
       the complete old bookkeeping and pending generation remain on local acceptance failure.
     */
    private func finishPendingUpload(
        _ pendingUpload: PendingUpload,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        acceptanceCheckpoint: @escaping () throws -> Void
    ) async throws -> RemoteSyncMyDocumentPatchUploadReport {
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
                throw RemoteSyncMyDocumentPatchUploadError.invalidPendingUpload
            }
            try snapshotService.validateAcceptedBaselineRevision(
                expectedRevision: pendingUpload.expectedAcceptedBaselineRevision,
                expectedBaselineExists: pendingUpload.expectedAcceptedBaselineExists,
                settingsStore: settingsStore
            )
            let currentSnapshot = try snapshotService.snapshotCurrentStateThrowing(
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
                category: .myDocuments,
                settingsStore: settingsStore
            )
            let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
            _ = try patchStatusStore.statusesStrict(for: .myDocuments)
            patchStatusStore.addStatus(
                RemoteSyncPatchStatus(
                    sourceDevice: pendingUpload.sourceDevice,
                    patchNumber: pendingUpload.patchNumber,
                    sizeBytes: acceptedRemoteFile.size,
                    appliedDate: acceptedRemoteFile.timestamp
                ),
                for: .myDocuments
            )
            let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
            var progressState = stateStore.progressState(for: .myDocuments)
            progressState.lastPatchWritten = pendingUpload.timestamp
            stateStore.setProgressState(progressState, for: .myDocuments)
            try snapshotService.acceptBaseline(
                pendingUpload.acceptedBaseline,
                settingsStore: settingsStore
            )
            try acceptanceCheckpoint()
            settingsStore.remove(Self.pendingUploadKey)
        }

        try? fileManager.removeItem(at: archiveURL)
        return RemoteSyncMyDocumentPatchUploadReport(
            uploadedFile: acceptedRemoteFile,
            patchNumber: pendingUpload.patchNumber,
            upsertedDocumentCount: pendingUpload.upsertedDocumentCount,
            upsertedPageCount: pendingUpload.upsertedPageCount,
            upsertedPageContentCount: pendingUpload.upsertedPageContentCount,
            upsertedAiPageCacheEntryCount: pendingUpload.upsertedAiPageCacheEntryCount,
            deletedRowCount: pendingUpload.deletedRowCount,
            logEntryCount: pendingUpload.logEntryCount,
            lastUpdated: pendingUpload.timestamp
        )
    }

    /**
     Invalidates a My Documents outbox only after explicit lifecycle destination replacement.

     - Parameters:
       - pendingUpload: Old destination-bound generation.
       - modelContext: Clean shared context.
       - settingsStore: Store containing its manifest.
     - Side effects: Atomically removes only the pending marker and then removes its archive best effort.
     - Failure modes: Rethrows manifest validation or settings transaction errors.
     */
    private func invalidatePendingUpload(
        _ pendingUpload: PendingUpload,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws {
        try settingsStore.performAtomicBatch(in: modelContext) {
            guard try loadPendingUpload(settingsStore: settingsStore) == pendingUpload else {
                throw RemoteSyncMyDocumentPatchUploadError.invalidPendingUpload
            }
            settingsStore.remove(Self.pendingUploadKey)
        }
        if let archiveURL = try? pendingArchiveURL(for: pendingUpload) {
            try? fileManager.removeItem(at: archiveURL)
        }
    }

    /** Reads and decodes the pending My Documents upload manifest. */
    private func loadPendingUpload(settingsStore: SettingsStore) throws -> PendingUpload? {
        guard let payload = settingsStore.getString(Self.pendingUploadKey) else { return nil }
        guard let data = payload.data(using: .utf8),
              let pendingUpload = try? JSONDecoder().decode(PendingUpload.self, from: data) else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidPendingUpload
        }
        guard let publicationIdentity = pendingUpload.publicationIdentity else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidPendingUpload
        }
        var acceptancePayload = pendingUpload
        acceptancePayload.publicationIdentity = nil
        do {
            try publicationIdentity.validate(
                kind: .patch,
                category: .myDocuments,
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
            throw RemoteSyncMyDocumentPatchUploadError.invalidPendingUpload
        }
        return pendingUpload
    }

    /**
     Returns every operation count bound to one My Documents publication.

     - Parameter pendingUpload: Identity-free or decoded My Documents outbox envelope.
     - Returns: Nonempty count dictionary covering all Android My Documents row families.
     - Side effects: none.
     - Failure modes: This deterministic projection cannot fail.
     */
    private static func publicationRowCounts(for pendingUpload: PendingUpload) -> [String: Int] {
        [
            "documents": pendingUpload.upsertedDocumentCount,
            "pages": pendingUpload.upsertedPageCount,
            "pageContents": pendingUpload.upsertedPageContentCount,
            "aiPageCacheEntries": pendingUpload.upsertedAiPageCacheEntryCount,
            "deletions": pendingUpload.deletedRowCount,
            "logEntries": pendingUpload.logEntryCount
        ]
    }

    /** Encodes and stores one complete pending My Documents upload manifest. */
    private func storePendingUpload(_ pendingUpload: PendingUpload, settingsStore: SettingsStore) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pendingUpload)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidPendingUpload
        }
        settingsStore.setString(Self.pendingUploadKey, value: payload)
    }

    /** Resolves a safe pending archive basename beneath the configured outbox. */
    private func pendingArchiveURL(for pendingUpload: PendingUpload) throws -> URL {
        guard pendingUpload.archiveFileName == URL(fileURLWithPath: pendingUpload.archiveFileName).lastPathComponent,
              !pendingUpload.archiveFileName.isEmpty else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidPendingUpload
        }
        return outboxDirectory.appendingPathComponent(pendingUpload.archiveFileName, isDirectory: false)
    }

    /**
     Reads the highest Android patch number already present in one My Documents device folder.

     - Parameter deviceFolderID: Active remote device-folder identifier.
     - Returns: Highest valid Android patch number, or zero when no patch archive exists.
     - Side effects: Performs one unfiltered remote folder listing.
     - Failure modes: Rethrows backend listing failures so generation creation fails closed.
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

    /** Resolves the production My Documents outbox beneath Application Support. */
    static func defaultOutboxDirectory(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent("AndBible", isDirectory: true)
            .appendingPathComponent("RemoteSyncOutbox", isDirectory: true)
            .appendingPathComponent("mydocuments", isDirectory: true)
    }

    private func buildChangeSet(
        snapshot: RemoteSyncMyDocumentCurrentSnapshot,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        acceptedRowsByKey: [String: RemoteSyncMyDocumentAcceptedRowIdentity],
        fingerprintStore: RemoteSyncRowFingerprintStore,
        pendingMutations: [String: RemoteSyncPendingMutation],
        timestamp: Int64,
        sourceDevice: String
    ) throws -> ChangeSet {
        var documentRowsByKey: [String: RemoteSyncAndroidMyDocument] = [:]
        var pageRowsByKey: [String: RemoteSyncAndroidMyDocumentPage] = [:]
        var pageContentRowsByKey: [String: RemoteSyncAndroidMyDocumentPageContent] = [:]
        var aiPageCacheEntryRowsByKey: [String: RemoteSyncAndroidAiPageCacheEntry] = [:]
        var logEntries: [RemoteSyncLogEntry] = []
        var updatedEntriesByKey = existingEntriesByKey

        for (key, row) in snapshot.documentRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
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
                category: .myDocuments,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                    tableName: "MyDocument",
                    entityID1: .blob(RemoteSyncMyDocumentSnapshotService.uuidBlob(row.id)),
                    entityID2: RemoteSyncMyDocumentSnapshotService.emptySecondaryEntityID,
                    type: .upsert,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                )
            documentRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.pageRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
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
                category: .myDocuments,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                    tableName: "MyDocumentPage",
                    entityID1: .blob(RemoteSyncMyDocumentSnapshotService.uuidBlob(row.id)),
                    entityID2: RemoteSyncMyDocumentSnapshotService.emptySecondaryEntityID,
                    type: .upsert,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                )
            pageRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.pageContentRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
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
                category: .myDocuments,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                    tableName: "MyDocumentPageContent",
                    entityID1: .blob(RemoteSyncMyDocumentSnapshotService.uuidBlob(row.pageId)),
                    entityID2: RemoteSyncMyDocumentSnapshotService.emptySecondaryEntityID,
                    type: .upsert,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                )
            pageContentRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.aiPageCacheEntryRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
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
                category: .myDocuments,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                    tableName: "AiPageCacheEntry",
                    entityID1: .blob(RemoteSyncMyDocumentSnapshotService.uuidBlob(row.pageId)),
                    entityID2: RemoteSyncMyDocumentSnapshotService.emptySecondaryEntityID,
                    type: .upsert,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                )
            aiPageCacheEntryRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        var deletionRowsByKey = acceptedRowsByKey
        for (key, mutation) in pendingMutations where mutation.entry.type == .delete {
            deletionRowsByKey[key] = RemoteSyncMyDocumentAcceptedRowIdentity(
                key: key,
                tableName: mutation.entry.tableName,
                entityID1: mutation.entry.entityID1,
                entityID2: mutation.entry.entityID2
            )
        }
        for (key, identity) in deletionRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard Self.supportedTableNames.contains(identity.tableName) else {
                continue
            }
            guard !currentRowExists(forKey: key, in: snapshot) else {
                continue
            }
            guard existingEntriesByKey[key]?.type != .delete || pendingMutations[key] != nil else {
                continue
            }
            let deleteEntry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: nil,
                type: .delete,
                category: .myDocuments,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                    tableName: identity.tableName,
                    entityID1: identity.entityID1,
                    entityID2: identity.entityID2,
                    type: .delete,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                )
            logEntries.append(deleteEntry)
            updatedEntriesByKey[key] = deleteEntry
        }

        return ChangeSet(
            documentRowsByKey: documentRowsByKey,
            pageRowsByKey: pageRowsByKey,
            pageContentRowsByKey: pageContentRowsByKey,
            aiPageCacheEntryRowsByKey: aiPageCacheEntryRowsByKey,
            logEntries: logEntries.sorted(by: Self.logEntrySort),
            updatedEntriesByKey: updatedEntriesByKey
        )
    }

    private func shouldUploadCurrentRow(
        key: String,
        currentFingerprint: String?,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore
    ) -> Bool {
        guard let currentFingerprint else {
            return false
        }

        guard let existingEntry = existingEntriesByKey[key] else {
            if let existingFingerprint = fingerprintStore.fingerprint(
                forLogKey: key,
                category: .myDocuments
            ) {
                return existingFingerprint != currentFingerprint
            }
            return true
        }

        guard Self.supportedTableNames.contains(existingEntry.tableName) else {
            return false
        }

        if existingEntry.type == .delete {
            return true
        }

        let existingFingerprint = fingerprintStore.fingerprint(
            for: .myDocuments,
            tableName: existingEntry.tableName,
            entityID1: existingEntry.entityID1,
            entityID2: existingEntry.entityID2
        )
        guard let existingFingerprint else {
            return true
        }
        return existingFingerprint != currentFingerprint
    }

    private func currentRowExists(forKey key: String, in snapshot: RemoteSyncMyDocumentCurrentSnapshot) -> Bool {
        snapshot.documentRowsByKey[key] != nil
            || snapshot.pageRowsByKey[key] != nil
            || snapshot.pageContentRowsByKey[key] != nil
            || snapshot.aiPageCacheEntryRowsByKey[key] != nil
    }

    private func writePatchDatabase(
        at url: URL,
        schemaVersion: Int,
        changeSet: ChangeSet
    ) throws {
        guard schemaVersion == RemoteSyncAndroidDatabaseContract.schemaVersion(for: .myDocuments) else {
            throw RemoteSyncMyDocumentPatchUploadError.unsupportedSchemaVersion(schemaVersion)
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let database else {
            if let database {
                sqlite3_close(database)
            }
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        try execute(
            RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: .myDocuments),
            in: database
        )

        try execute("BEGIN IMMEDIATE TRANSACTION;", in: database)
        do {
            for row in changeSet.documentRowsByKey.values.sorted(by: Self.myDocumentSort) {
                try insertMyDocumentRow(row, in: database)
            }
            for row in changeSet.pageRowsByKey.values.sorted(by: Self.myDocumentPageSort) {
                try insertMyDocumentPageRow(row, in: database)
            }
            for row in changeSet.pageContentRowsByKey.values.sorted(by: Self.myDocumentPageContentSort) {
                try insertMyDocumentPageContentRow(row, in: database)
            }
            for row in changeSet.aiPageCacheEntryRowsByKey.values.sorted(by: Self.aiPageCacheEntrySort) {
                try insertAiPageCacheEntryRow(row, in: database)
            }
            for entry in changeSet.logEntries {
                try insertLogEntry(entry, in: database)
            }
            try execute("COMMIT;", in: database)
        } catch {
            try? execute("ROLLBACK;", in: database)
            throw error
        }
    }

    private func insertMyDocumentRow(_ row: RemoteSyncAndroidMyDocument, in database: OpaquePointer) throws {
        let sql = "INSERT INTO MyDocument (id, name, description, initials, orderNumber, createdAt, updatedAt, sourcePromptId) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.id, to: statement, index: 1)
        Self.bindText(row.name, to: statement, index: 2)
        Self.bindOptionalText(row.documentDescription, to: statement, index: 3)
        Self.bindText(row.initials, to: statement, index: 4)
        sqlite3_bind_int(statement, 5, Int32(row.orderNumber))
        sqlite3_bind_int64(statement, 6, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        sqlite3_bind_int64(statement, 7, Int64(row.updatedAt.timeIntervalSince1970 * 1000.0))
        Self.bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 8)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func insertMyDocumentPageRow(_ row: RemoteSyncAndroidMyDocumentPage, in database: OpaquePointer) throws {
        let sql = "INSERT INTO MyDocumentPage (id, documentId, title, pageKey, contentType, orderNumber, createdAt, updatedAt, sourcePromptId, languageCode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.id, to: statement, index: 1)
        Self.bindUUIDBlob(row.documentId, to: statement, index: 2)
        Self.bindText(row.title, to: statement, index: 3)
        Self.bindText(row.pageKey, to: statement, index: 4)
        Self.bindText(row.contentType.rawValue, to: statement, index: 5)
        sqlite3_bind_int(statement, 6, Int32(row.orderNumber))
        sqlite3_bind_int64(statement, 7, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        sqlite3_bind_int64(statement, 8, Int64(row.updatedAt.timeIntervalSince1970 * 1000.0))
        Self.bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 9)
        Self.bindOptionalText(row.languageCode, to: statement, index: 10)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func insertMyDocumentPageContentRow(
        _ row: RemoteSyncAndroidMyDocumentPageContent,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO MyDocumentPageContent (pageId, content) VALUES (?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.pageId, to: statement, index: 1)
        Self.bindText(row.content, to: statement, index: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func insertAiPageCacheEntryRow(
        _ row: RemoteSyncAndroidAiPageCacheEntry,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO AiPageCacheEntry (pageId, sourcePromptId, sourceContext, kjvOrdinalStart, kjvOrdinalEnd, contextHash, usedWriteTools, sourceModelName, sourceBookInitials, sourceBookKey) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.pageId, to: statement, index: 1)
        Self.bindUUIDBlob(row.sourcePromptId, to: statement, index: 2)
        Self.bindOptionalText(row.sourceContext, to: statement, index: 3)
        Self.bindOptionalInt(row.kjvOrdinalStart, to: statement, index: 4)
        Self.bindOptionalInt(row.kjvOrdinalEnd, to: statement, index: 5)
        Self.bindOptionalText(row.contextHash, to: statement, index: 6)
        Self.bindBool(row.usedWriteTools, to: statement, index: 7)
        Self.bindOptionalText(row.sourceModelName, to: statement, index: 8)
        Self.bindOptionalText(row.sourceBookInitials, to: statement, index: 9)
        Self.bindOptionalText(row.sourceBookKey, to: statement, index: 10)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func insertLogEntry(_ entry: RemoteSyncLogEntry, in database: OpaquePointer) throws {
        let sql = "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindText(entry.tableName, to: statement, index: 1)
        Self.bindSQLiteValue(entry.entityID1, to: statement, index: 2)
        Self.bindSQLiteValue(entry.entityID2, to: statement, index: 3)
        Self.bindText(entry.type.rawValue, to: statement, index: 4)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        Self.bindText(entry.sourceDevice, to: statement, index: 6)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncMyDocumentPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func temporaryURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    private static func sourceDeviceName(from deviceFolderID: String) -> String {
        let trimmed = deviceFolderID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? deviceFolderID
    }

    private static func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, remoteSyncMyDocumentPatchUploadSQLiteTransient)
    }

    private static func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindText(value, to: statement, index: index)
    }

    private static func bindBool(_ value: Bool, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_int(statement, index, value ? 1 : 0)
    }

    private static func bindOptionalInt(_ value: Int?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int64(statement, index, Int64(value))
    }

    private static func bindUUIDBlob(_ value: UUID, to statement: OpaquePointer?, index: Int32) {
        let blob = RemoteSyncMyDocumentSnapshotService.uuidBlob(value)
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(blob.count),
                remoteSyncMyDocumentPatchUploadSQLiteTransient
            )
        }
    }

    private static func bindOptionalUUIDBlob(_ value: UUID?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindUUIDBlob(value, to: statement, index: index)
    }

    private static func bindSQLiteValue(
        _ value: RemoteSyncSQLiteValue,
        to statement: OpaquePointer?,
        index: Int32
    ) {
        switch value.kind {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer:
            sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
        case .real:
            sqlite3_bind_double(statement, index, value.realValue ?? 0)
        case .text:
            sqlite3_bind_text(statement, index, value.textValue ?? "", -1, remoteSyncMyDocumentPatchUploadSQLiteTransient)
        case .blob:
            let data = value.blobData ?? Data()
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    index,
                    bytes.baseAddress,
                    Int32(data.count),
                    remoteSyncMyDocumentPatchUploadSQLiteTransient
                )
            }
        }
    }

    private static func logEntrySort(_ lhs: RemoteSyncLogEntry, _ rhs: RemoteSyncLogEntry) -> Bool {
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
            return sortKey(for: lhs.entityID1) < sortKey(for: rhs.entityID1)
        }
        return sortKey(for: lhs.entityID2) < sortKey(for: rhs.entityID2)
    }

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

    private static func myDocumentSort(_ lhs: RemoteSyncAndroidMyDocument, _ rhs: RemoteSyncAndroidMyDocument) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            if lhs.name == rhs.name {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.name < rhs.name
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    private static func myDocumentPageSort(_ lhs: RemoteSyncAndroidMyDocumentPage, _ rhs: RemoteSyncAndroidMyDocumentPage) -> Bool {
        if lhs.documentId == rhs.documentId {
            if lhs.orderNumber == rhs.orderNumber {
                if lhs.title == rhs.title {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.title < rhs.title
            }
            return lhs.orderNumber < rhs.orderNumber
        }
        return lhs.documentId.uuidString < rhs.documentId.uuidString
    }

    private static func myDocumentPageContentSort(
        _ lhs: RemoteSyncAndroidMyDocumentPageContent,
        _ rhs: RemoteSyncAndroidMyDocumentPageContent
    ) -> Bool {
        lhs.pageId.uuidString < rhs.pageId.uuidString
    }

    private static func aiPageCacheEntrySort(
        _ lhs: RemoteSyncAndroidAiPageCacheEntry,
        _ rhs: RemoteSyncAndroidAiPageCacheEntry
    ) -> Bool {
        lhs.pageId.uuidString < rhs.pageId.uuidString
    }
}
