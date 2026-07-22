// RemoteSyncProgressPatchUploadService.swift - Android-shaped outbound progress patch creation

import CryptoKit
import Foundation
import SQLite3

private let remoteSyncProgressPatchUploadSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Describes failures that prevent creation, resumption, transport, or local acceptance of an
 outbound Progress patch.

 Callers use these cases to distinguish missing destination state, corrupt local metadata, stale
 accepted generations, and exhausted numbering from adapter or filesystem errors. Constructing and
 comparing these values has no side effects and is deterministic for the same failed invariant.
 */
public enum RemoteSyncProgressPatchUploadError: Error, Equatable {
    /// The category has no validated remote device folder.
    case missingDeviceFolderID

    /// The temporary Android SQLite patch cannot be created or populated.
    case invalidSQLiteDatabase

    /// The durable outbox payload is malformed, missing during acceptance, or changed unexpectedly.
    case invalidPendingPatch

    /// Persisted Progress log or fingerprint metadata cannot form one trustworthy accepted baseline.
    case invalidLocalMetadata

    /// A pending generation belongs to a different device folder than the active bootstrap state.
    case pendingPatchDestinationMismatch

    /// Accepted log or fingerprint state changed after generation and cannot be overwritten safely.
    case acceptedBaselineChanged

    /// An exportable Progress row did not receive the fingerprint required for safe publication.
    case missingCurrentFingerprint(String)

    /// Local and remote patch history exhausted the signed 64-bit Android patch-number range.
    case patchNumberExhausted

    /// The requested wire schema is not the exact Android Room contract supported by this build.
    case unsupportedSchemaVersion(Int)
}

/**
 Reports the exact Progress generation accepted after remote reconciliation succeeds.

 The report carries adapter-owned file metadata, the accepted patch number, sparse operation counts,
 and the generation watermark used for dirty-row detection. Creating or reading a report has no side
 effects; reports are deterministic for one persisted pending generation and reconciled remote file.
 */
public struct RemoteSyncProgressPatchUploadReport: Sendable, Equatable {
    /// Adapter metadata for the successful upload attempt.
    public let uploadedFile: RemoteSyncFile
    /// Monotonic patch number encoded in the remote filename.
    public let patchNumber: Int64
    /// Number of memorized-verse upserts in the patch.
    public let upsertedMemorizedVerseCount: Int
    /// Number of chapter-history upserts in the patch.
    public let upsertedChapterHistoryCount: Int
    /// Number of memorization-target upserts in the patch.
    public let upsertedTargetCount: Int
    /// Number of global-settings upserts in the patch.
    public let upsertedSettingsCount: Int
    /// Number of Android delete operations in the patch.
    public let deletedRowCount: Int
    /// Total Android log operations in the patch.
    public let logEntryCount: Int
    /// Generation watermark used for log timestamps and `lastPatchWritten`.
    public let lastUpdated: Int64
}

/**
 Creates restart-safe Android-compatible sparse `progress.sqlite3` patches.

 The service atomically freezes one local generation into a small settings manifest plus a durable
 Application Support archive before remote transport. Retries reconcile the same filename and digest.
 Successful local acceptance uses compare-and-swap against the captured accepted baseline, then
 publishes the exact generation while retaining newer local Progress changes for the following patch.
 */
public final class RemoteSyncProgressPatchUploadService {
    /**
     Immutable bookkeeping and archive identity for one remote Progress patch generation.

     The manifest is persisted before upload and references a separately durable archive by filename,
     byte count, and SHA-256. Local acceptance consumes only this generation and cannot overwrite a
     baseline changed by inbound replay while transport was suspended.
     */
    private struct PendingPatch: Codable, Equatable {
        let formatVersion: Int
        let deviceFolderID: String
        let sourceDevice: String
        let schemaVersion: Int
        let patchNumber: Int64
        let timestamp: Int64
        let archiveFileName: String
        let archiveSize: Int64
        let archiveSHA256: String
        let acceptedBaselineRevision: Int64
        let acceptedLogEntriesSHA256: String
        let acceptedGeneration: RemoteSyncProgressAcceptedGeneration
        let updatedLogEntries: [RemoteSyncLogEntry]
        let uploadedLogEntries: [RemoteSyncLogEntry]?
        let upsertedMemorizedVerseCount: Int
        let upsertedChapterHistoryCount: Int
        let upsertedTargetCount: Int
        let upsertedSettingsCount: Int
        let deletedRowCount: Int
        let logEntryCount: Int
        var publicationIdentity: RemoteSyncPublicationIdentity? = nil

        /// Android-compatible filename derived from the durable patch identity.
        var fileName: String {
            "\(patchNumber).\(schemaVersion).sqlite3.gz"
        }
    }

    /**
     Holds sparse Android rows and log operations derived from one immutable Progress projection.

     The value is created during the settings transaction that freezes a pending generation and is
     consumed while writing its SQLite archive. It performs no I/O itself and preserves deterministic
     row ordering through the archive writer rather than mutable collection state.
     */
    private struct ChangeSet {
        let memorizedVerseRowsByKey: [String: RemoteSyncCurrentProgressMemorizedVerseRow]
        let chapterHistoryRowsByKey: [String: RemoteSyncCurrentProgressChapterReadHistoryRow]
        let targetRowsByKey: [String: RemoteSyncCurrentProgressMemorizationTargetRow]
        let settingsRowsByKey: [String: RemoteSyncCurrentProgressSettingsRow]
        let logEntries: [RemoteSyncLogEntry]
        let updatedEntriesByKey: [String: RemoteSyncLogEntry]

        /// Number of delete operations represented by `logEntries`.
        var deletedRowCount: Int {
            logEntries.filter { $0.type == .delete }.count
        }
    }

    private let adapter: any RemoteSyncAdapting
    private let remotePatchReconciler: RemoteSyncRemotePatchReconciler
    private let snapshotService: RemoteSyncProgressSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let outboxDirectory: URL
    private let nowProvider: () -> Int64

    /// Settings key containing the one durable outbound Progress generation awaiting acceptance.
    static let pendingPatchSettingKey = "remote_sync.pending_patch.progress"
    private static let pendingPatchFormatVersion = 1

    /**
     Creates an outbound Progress uploader for one remote backend.

     - Parameters:
       - adapter: Backend used for idempotent patch-file uploads.
       - snapshotService: Android-row projector and baseline publisher.
       - fileManager: File manager used for temporary and durable patch files.
       - temporaryDirectory: Optional scratch directory; defaults to the process temporary directory.
       - outboxDirectory: Durable archive directory. Production defaults to Application Support;
         tests with an injected scratch directory get an isolated sibling outbox by default.
       - nowProvider: Millisecond generation clock used for log entries and `lastPatchWritten`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        snapshotService: RemoteSyncProgressSnapshotService = RemoteSyncProgressSnapshotService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        outboxDirectory: URL? = nil,
        nowProvider: @escaping () -> Int64 = {
            AndroidTimestamp.currentMilliseconds()
        }
    ) {
        self.adapter = adapter
        self.remotePatchReconciler = RemoteSyncRemotePatchReconciler(adapter: adapter)
        self.snapshotService = snapshotService
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.outboxDirectory = outboxDirectory
            ?? temporaryDirectory?.appendingPathComponent("remote-sync-progress-outbox", isDirectory: true)
            ?? Self.defaultOutboxDirectory(fileManager: fileManager)
        self.nowProvider = nowProvider
    }

    /**
     Uploads the next Progress patch or resumes the durable generation left by an interrupted upload.

     Snapshot projection, baseline reads, patch numbering, archive creation, and outbox persistence
     occur in one strict settings transaction. Once a generation exists, retries upload its exact
     bytes and patch number until the local acceptance transaction succeeds.

     - Parameters:
       - bootstrapState: Ready Progress bootstrap state containing the destination device folder.
       - settingsStore: Settings-backed Progress content and synchronization metadata store.
       - schemaVersion: Android Progress schema version for newly generated patches. A durable
         pending generation retains its original schema version across retries.
     - Returns: Accepted upload report, or `nil` when no local change needs publication.
     - Side effects: Persists a durable outbox, writes temporary files, uploads one gzip archive,
       and atomically accepts logs, status, progress metadata, and exact generation fingerprints.
     - Throws: Rethrows strict settings, SQLite, filesystem, compression, transport, outbox
       validation, cancellation, and acceptance transaction failures.
     - Important: A remote success followed by local failure intentionally leaves the outbox intact,
       allowing a restart to repeat the same idempotent remote filename and byte payload.
     */
    public func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        settingsStore: SettingsStore,
        schemaVersion: Int = 9
    ) async throws -> RemoteSyncProgressPatchUploadReport? {
        try await uploadPendingPatch(
            bootstrapState: bootstrapState,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion,
            acceptanceCheckpoint: {}
        )
    }

    /**
     Resumes an existing Progress generation without projecting or publishing newer local changes.

     Synchronization orchestration calls this before inbound replay. Returning `nil` means no
     generation is pending; it never means a fresh patch was created. A destination mismatch fails
     closed until lifecycle reset explicitly discards the old outbox.

     - Parameters:
       - bootstrapState: Progress bootstrap state containing the validated destination folder.
       - settingsStore: Store owning the durable pending manifest and accepted metadata.
     - Returns: Accepted report for a resumed generation, or `nil` when no generation exists.
     - Side effects: Reconciles or uploads only an already-persisted archive and atomically accepts it.
     - Throws: Rethrows destination, outbox, filesystem, transport, baseline-CAS, cancellation, and
       acceptance transaction failures.
     */
    public func resumePendingPatchIfPresent(
        bootstrapState: RemoteSyncBootstrapState,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncProgressPatchUploadReport? {
        try await resumePendingPatchIfPresent(
            bootstrapState: bootstrapState,
            settingsStore: settingsStore,
            acceptanceCheckpoint: {}
        )
    }

    /**
     Discards an unaccepted Progress generation at an explicit destination replacement boundary.

     Reset and re-adoption flows must call this only after deciding that the prior device folder is
     no longer authoritative. The accepted log and fingerprint baseline remains untouched, so all
     current rows represented by the discarded generation are re-diffed for the replacement folder.

     - Parameter settingsStore: Store owning the durable Progress outbox.
     - Side effects: Removes only the pending Progress manifest in one strict settings transaction,
       then best-effort deletes its referenced archive.
     - Throws: Rethrows strict settings, cancellation, or transaction commit failures.
     - Important: Ordinary upload retries must not call this method; they must reuse the pending bytes.
     */
    func discardPendingPatchForDestinationReplacement(settingsStore: SettingsStore) throws {
        var archiveFileName: String?
        try settingsStore.performAtomicBatch {
            if let payload = settingsStore.getString(Self.pendingPatchSettingKey),
               let data = payload.data(using: .utf8),
               let pendingPatch = try? JSONDecoder().decode(PendingPatch.self, from: data),
               pendingPatch.formatVersion == Self.pendingPatchFormatVersion {
                archiveFileName = pendingPatch.archiveFileName
            }
            settingsStore.remove(Self.pendingPatchSettingKey)
        }
        if let archiveFileName,
           URL(fileURLWithPath: archiveFileName).lastPathComponent == archiveFileName {
            try? fileManager.removeItem(
                at: outboxDirectory.appendingPathComponent(archiveFileName, isDirectory: false)
            )
        }
    }

    /**
     Testable upload path with a final checkpoint inside the local acceptance transaction.

     - Parameters:
       - bootstrapState: Ready Progress bootstrap state containing the destination device folder.
       - settingsStore: Settings-backed Progress content and synchronization metadata store.
       - schemaVersion: Android Progress schema version for newly generated patches.
       - acceptanceCheckpoint: Deterministic failure seam invoked after all acceptance mutations and
         outbox removal are staged but before the atomic transaction commits.
     - Returns: Accepted upload report, or `nil` when no local change needs publication.
     - Side effects: Matches the public upload path; a thrown checkpoint rolls back all local
       acceptance mutations while preserving the durable outbox.
     - Throws: Rethrows all public upload failures and any checkpoint error.
     */
    func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        settingsStore: SettingsStore,
        schemaVersion: Int = 9,
        acceptanceCheckpoint: @escaping () throws -> Void
    ) async throws -> RemoteSyncProgressPatchUploadReport? {
        let deviceFolderID = try validatedDeviceFolderID(from: bootstrapState)
        if let pendingPatch = try pendingPatchForDestination(
            deviceFolderID,
            settingsStore: settingsStore
        ) {
            return try await finishPendingPatch(
                pendingPatch,
                settingsStore: settingsStore,
                acceptanceCheckpoint: acceptanceCheckpoint
            )
        }

        let hasPendingMutations = try settingsStore.performAtomicBatch {
            let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
            _ = try strictEntriesByKey(
                strictLogEntries(
                    settingsStore: settingsStore,
                    logEntryStore: logEntryStore
                ),
                logEntryStore: logEntryStore
            )
            let mutationJournal = RemoteSyncMutationJournalService(nowProvider: nowProvider)
            try mutationJournal.recordLocalChanges(
                for: .progress,
                modelContext: nil,
                settingsStore: settingsStore
            )
            return try !mutationJournal.pendingMutations(
                for: .progress,
                settingsStore: settingsStore
            ).isEmpty
        }
        guard hasPendingMutations else {
            return nil
        }

        let remoteFiles = try await adapter.listFiles(
            parentIDs: [deviceFolderID],
            name: nil,
            mimeType: nil,
            modifiedAtLeast: nil
        )
        let highestRemotePatchNumber = remoteFiles.compactMap {
            RemoteSyncPatchDiscoveryService.parsePatchFileName($0.name)?.patchNumber
        }.max() ?? 0

        guard let pendingPatch = try prepareNewPendingPatch(
            deviceFolderID: deviceFolderID,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion,
            highestRemotePatchNumber: highestRemotePatchNumber
        ) else {
            return nil
        }

        return try await finishPendingPatch(
            pendingPatch,
            settingsStore: settingsStore,
            acceptanceCheckpoint: acceptanceCheckpoint
        )
    }

    /**
     Resumes a previously persisted Progress generation without creating new outbound work.

     - Parameters:
       - bootstrapState: Active bootstrap state whose destination must match the pending manifest.
       - settingsStore: Store containing the durable pending manifest and accepted metadata.
       - acceptanceCheckpoint: Deterministic test checkpoint invoked after acceptance mutations are
         staged and before the atomic settings transaction commits.
     - Returns: The accepted upload report, or `nil` when no pending Progress generation exists.
     - Side effects: May read the durable archive, reconcile it with the remote destination, update
       local accepted metadata atomically, and remove the archive after acceptance commits.
     - Throws: Destination, manifest, archive, transport, compare-and-swap, settings, and checkpoint
       errors. A failure before local commit preserves the pending generation for an exact-byte retry.
     */
    func resumePendingPatchIfPresent(
        bootstrapState: RemoteSyncBootstrapState,
        settingsStore: SettingsStore,
        acceptanceCheckpoint: @escaping () throws -> Void
    ) async throws -> RemoteSyncProgressPatchUploadReport? {
        let deviceFolderID = try validatedDeviceFolderID(from: bootstrapState)
        guard let pendingPatch = try pendingPatchForDestination(
            deviceFolderID,
            settingsStore: settingsStore
        ) else {
            return nil
        }
        return try await finishPendingPatch(
            pendingPatch,
            settingsStore: settingsStore,
            acceptanceCheckpoint: acceptanceCheckpoint
        )
    }

    /**
     Extracts the nonempty remote Progress destination from bootstrap state.

     - Parameter bootstrapState: Bootstrap state expected to contain a device-folder identifier.
     - Returns: The identifier after trimming surrounding whitespace and newlines.
     - Side effects: none.
     - Throws: `missingDeviceFolderID` when no usable destination is available.
     */
    private func validatedDeviceFolderID(from bootstrapState: RemoteSyncBootstrapState) throws -> String {
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncProgressPatchUploadError.missingDeviceFolderID
        }
        return deviceFolderID
    }

    /**
     Loads a pending generation and verifies it belongs to the requested destination.

     - Parameters:
       - deviceFolderID: Validated active Progress destination.
       - settingsStore: Store containing the optional pending manifest.
     - Returns: Destination-matched pending generation, or `nil` when no outbox exists.
     - Side effects: Performs one strict settings transaction.
     - Throws: `pendingPatchDestinationMismatch` for any changed destination; reset code must discard
       deliberately before another generation can be built.
     */
    private func pendingPatchForDestination(
        _ deviceFolderID: String,
        settingsStore: SettingsStore
    ) throws -> PendingPatch? {
        try settingsStore.performAtomicBatch {
            guard let pendingPatch = try loadPendingPatch(settingsStore: settingsStore) else {
                return nil
            }
            guard pendingPatch.deviceFolderID == deviceFolderID else {
                throw RemoteSyncProgressPatchUploadError.pendingPatchDestinationMismatch
            }
            return pendingPatch
        }
    }

    /**
     Builds and durably records one fresh outbound Progress generation before network transport.

     - Parameters:
       - deviceFolderID: Validated remote destination folder.
       - settingsStore: Store owning Progress content, metadata, and the durable outbox.
       - schemaVersion: Android schema version for a newly created patch.
       - highestRemotePatchNumber: Highest valid patch filename observed in the device folder.
     - Returns: Existing race-winning or newly persisted pending patch, or `nil` when no changes exist.
     - Side effects: Strictly snapshots content and accepted metadata, computes the sparse change set,
       streams and fsyncs a bounded durable archive, and persists its small manifest in one settings
       transaction.
     - Throws: Rethrows cancellation, bounded-file, atomic settings, SQLite, filesystem,
       compression, and outbox errors. Partial output is removed.
     */
    private func prepareNewPendingPatch(
        deviceFolderID: String,
        settingsStore: SettingsStore,
        schemaVersion: Int,
        highestRemotePatchNumber: Int64
    ) throws -> PendingPatch? {
        let databaseURL = temporaryURL(prefix: "remote-sync-progress-upload-", suffix: ".sqlite3")
        defer { try? fileManager.removeItem(at: databaseURL) }
        let archiveFileName = "progress-\(UUID().uuidString.lowercased()).sqlite3.gz"
        let archiveURL = outboxDirectory.appendingPathComponent(archiveFileName, isDirectory: false)

        do {
            return try settingsStore.performAtomicBatch {
            if let pendingPatch = try loadPendingPatch(settingsStore: settingsStore) {
                guard pendingPatch.deviceFolderID == deviceFolderID else {
                    throw RemoteSyncProgressPatchUploadError.pendingPatchDestinationMismatch
                }
                return pendingPatch
            }

            let sourceDevice = Self.sourceDeviceName(from: deviceFolderID)
            let wallClockTimestamp = nowProvider()
            let mutationJournal = RemoteSyncMutationJournalService(nowProvider: nowProvider)
            try mutationJournal.recordLocalChanges(
                for: .progress,
                modelContext: nil,
                settingsStore: settingsStore
            )
            let pendingMutations = try mutationJournal.pendingMutations(
                for: .progress,
                settingsStore: settingsStore
            )
            let snapshot = try snapshotService.snapshotCurrentStateStrict(settingsStore: settingsStore)
            try snapshotService.validateExportableFingerprints(in: snapshot)
            let previousBaseline = try snapshotService.storedAcceptedBaseline(settingsStore: settingsStore)
            let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
            let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
            let existingLogEntries = try strictLogEntries(
                settingsStore: settingsStore,
                logEntryStore: logEntryStore
            )
            let existingEntriesByKey = try strictEntriesByKey(
                existingLogEntries,
                logEntryStore: logEntryStore
            )
            let storedFingerprintsByKey = strictFingerprintsByLogKey(settingsStore: settingsStore)
            if let previousBaseline,
               previousBaseline.generation.fingerprintsByKey != storedFingerprintsByKey {
                throw RemoteSyncProgressPatchUploadError.invalidLocalMetadata
            }
            let legacyGeneration = previousBaseline == nil
                ? try snapshotService.legacyAcceptedGeneration(settingsStore: settingsStore)
                : nil
            let existingFingerprintsByKey = previousBaseline?.generation.fingerprintsByKey
                ?? storedFingerprintsByKey
            var acceptedRowsByKey = previousBaseline?.generation.rowsByKey
                ?? legacyGeneration?.rowsByKey
                ?? [:]
            for (key, entry) in existingEntriesByKey where entry.type != .delete {
                acceptedRowsByKey[key] = RemoteSyncProgressAcceptedRowIdentity(
                    tableName: entry.tableName,
                    entityID1: entry.entityID1,
                    entityID2: entry.entityID2
                )
            }
            let acceptedGeneration = snapshotService.acceptedGeneration(
                from: snapshot,
                preserving: previousBaseline?.generation ?? legacyGeneration
            )
            let existingPatchStatuses = try patchStatusStore.statusesStrict(for: .progress)
            let progressState = RemoteSyncStateStore(settingsStore: settingsStore)
                .progressState(for: .progress)
            let timestamp = try RemoteSyncLogicalSequence.nextTimestamp(
                now: wallClockTimestamp,
                highWatermarks: existingLogEntries.map(\.lastUpdated)
                    + existingPatchStatuses.map(\.appliedDate)
                    + [progressState.lastPatchWritten, progressState.lastSynchronized].compactMap { $0 }
            )
            let changeSet = try buildChangeSet(
                snapshot: snapshot,
                existingEntriesByKey: existingEntriesByKey,
                acceptedRowsByKey: acceptedRowsByKey,
                existingFingerprintsByKey: existingFingerprintsByKey,
                pendingMutations: pendingMutations,
                timestamp: timestamp,
                sourceDevice: sourceDevice
            )

            guard !changeSet.logEntries.isEmpty else {
                if previousBaseline == nil {
                    try snapshotService.acceptBaselineFingerprints(
                        acceptedGeneration,
                        settingsStore: settingsStore,
                        expectedRevision: 0
                    )
                }
                return nil
            }

            let highestLocalPatchNumber = existingPatchStatuses
                .filter { $0.sourceDevice == sourceDevice }
                .map(\.patchNumber)
                .max() ?? 0
            let patchNumber: Int64
            do {
                patchNumber = try RemoteSyncPublicationIdentity.nextPatchNumber(
                    after: [highestLocalPatchNumber, highestRemotePatchNumber]
                )
            } catch {
                throw RemoteSyncProgressPatchUploadError.patchNumberExhausted
            }
            try writePatchDatabase(
                at: databaseURL,
                schemaVersion: schemaVersion,
                changeSet: changeSet
            )
            try fileManager.createDirectory(at: outboxDirectory, withIntermediateDirectories: true)
            let archiveFingerprint = try RemoteSyncArchiveStagingService.gzipPatchDatabase(
                at: databaseURL,
                to: archiveURL
            )
            var pendingPatch = PendingPatch(
                formatVersion: Self.pendingPatchFormatVersion,
                deviceFolderID: deviceFolderID,
                sourceDevice: sourceDevice,
                schemaVersion: schemaVersion,
                patchNumber: patchNumber,
                timestamp: timestamp,
                archiveFileName: archiveFileName,
                archiveSize: archiveFingerprint.byteCount,
                archiveSHA256: archiveFingerprint.sha256,
                acceptedBaselineRevision: previousBaseline?.revision ?? 0,
                acceptedLogEntriesSHA256: try Self.logEntriesSHA256(existingLogEntries),
                acceptedGeneration: acceptedGeneration,
                updatedLogEntries: changeSet.updatedEntriesByKey.values.sorted(by: Self.logEntrySort),
                uploadedLogEntries: changeSet.logEntries,
                upsertedMemorizedVerseCount: changeSet.memorizedVerseRowsByKey.count,
                upsertedChapterHistoryCount: changeSet.chapterHistoryRowsByKey.count,
                upsertedTargetCount: changeSet.targetRowsByKey.count,
                upsertedSettingsCount: changeSet.settingsRowsByKey.count,
                deletedRowCount: changeSet.deletedRowCount,
                logEntryCount: changeSet.logEntries.count
            )
            pendingPatch.publicationIdentity = try RemoteSyncPublicationIdentity.patch(
                category: .progress,
                destinationID: pendingPatch.deviceFolderID,
                sourceDevice: pendingPatch.sourceDevice,
                patchNumber: pendingPatch.patchNumber,
                schemaVersion: pendingPatch.schemaVersion,
                remoteFileName: pendingPatch.fileName,
                archiveFileName: pendingPatch.archiveFileName,
                archiveSHA256: pendingPatch.archiveSHA256,
                archiveSize: pendingPatch.archiveSize,
                rowCounts: Self.publicationRowCounts(for: pendingPatch),
                acceptancePayload: pendingPatch
            )
            try persistPendingPatch(pendingPatch, settingsStore: settingsStore)
            return pendingPatch
        }
        } catch {
            try? fileManager.removeItem(at: archiveURL)
            throw error
        }
    }

    /**
     Reconciles one durable Progress generation and atomically accepts its exact local metadata.

     The shared reconciler verifies local and occupied remote bytes by size, SHA-256, and direct
     equality, and uses create-only transport when the name is absent. This method never performs an
     unconditional overwrite.

     - Parameters:
       - pendingPatch: Destination-bound durable generation to finish.
       - settingsStore: Store containing its manifest and accepted Progress metadata.
       - acceptanceCheckpoint: Final deterministic checkpoint inside local publication.
     - Returns: Report reconstructed from the pending generation and accepted remote metadata.
     - Side effects: Reconciles one remote archive, atomically accepts local bookkeeping, and removes
       the durable local archive after publication commits.
     - Throws: Rethrows reconciliation, baseline-CAS, strict metadata, cancellation, checkpoint, and
       transaction failures without discarding the pending generation.
     */
    private func finishPendingPatch(
        _ pendingPatch: PendingPatch,
        settingsStore: SettingsStore,
        acceptanceCheckpoint: @escaping () throws -> Void
    ) async throws -> RemoteSyncProgressPatchUploadReport {
        let reconciliation = try await remotePatchReconciler.reconcile(
            archive: RemoteSyncDurablePatchArchive(
                fileName: pendingPatch.fileName,
                fileURL: pendingArchiveURL(for: pendingPatch),
                sha256: pendingPatch.archiveSHA256,
                size: pendingPatch.archiveSize,
                parentID: pendingPatch.deviceFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let uploadedFile: RemoteSyncFile
        switch reconciliation {
        case .created(let file), .matchedExisting(let file):
            uploadedFile = file
        }

        try acceptUploadedPatch(
            pendingPatch,
            uploadedFile: uploadedFile,
            settingsStore: settingsStore,
            acceptanceCheckpoint: acceptanceCheckpoint
        )
        return RemoteSyncProgressPatchUploadReport(
            uploadedFile: uploadedFile,
            patchNumber: pendingPatch.patchNumber,
            upsertedMemorizedVerseCount: pendingPatch.upsertedMemorizedVerseCount,
            upsertedChapterHistoryCount: pendingPatch.upsertedChapterHistoryCount,
            upsertedTargetCount: pendingPatch.upsertedTargetCount,
            upsertedSettingsCount: pendingPatch.upsertedSettingsCount,
            deletedRowCount: pendingPatch.deletedRowCount,
            logEntryCount: pendingPatch.logEntryCount,
            lastUpdated: pendingPatch.timestamp
        )
    }

    /**
     Atomically accepts a remotely uploaded generation and removes its durable outbox record.

     - Parameters:
       - pendingPatch: Exact generation uploaded to the remote device folder.
       - uploadedFile: Successful adapter result supplying Android `SyncStatus` size and applied date.
       - settingsStore: Store receiving accepted sync bookkeeping.
       - acceptanceCheckpoint: Final deterministic failure seam before transaction commit.
     - Side effects: Replaces Progress logs and fingerprints, records patch status, advances
       `lastPatchWritten`, and removes the pending generation in one transaction.
     - Throws: Rethrows strict settings, outbox validation, cancellation, checkpoint, or commit errors.
     */
    private func acceptUploadedPatch(
        _ pendingPatch: PendingPatch,
        uploadedFile: RemoteSyncFile,
        settingsStore: SettingsStore,
        acceptanceCheckpoint: () throws -> Void
    ) throws {
        try settingsStore.performAtomicBatch {
            guard try loadPendingPatch(settingsStore: settingsStore) == pendingPatch else {
                throw RemoteSyncProgressPatchUploadError.invalidPendingPatch
            }

            let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
            let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
            let currentLogEntries = try strictLogEntries(
                settingsStore: settingsStore,
                logEntryStore: logEntryStore
            )
            _ = try strictEntriesByKey(
                currentLogEntries,
                logEntryStore: logEntryStore
            )
            let currentBaseline = try snapshotService.storedAcceptedBaseline(settingsStore: settingsStore)
            let currentFingerprintsByKey = strictFingerprintsByLogKey(settingsStore: settingsStore)
            if let currentBaseline,
               currentBaseline.generation.fingerprintsByKey != currentFingerprintsByKey {
                throw RemoteSyncProgressPatchUploadError.invalidLocalMetadata
            }
            _ = try patchStatusStore.statusesStrict(for: .progress)
            let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
            let currentSnapshot = try snapshotService.snapshotCurrentStateStrict(
                settingsStore: settingsStore
            )
            try snapshotService.validateExportableFingerprints(in: currentSnapshot)
            try snapshotService.acceptBaselineFingerprints(
                pendingPatch.acceptedGeneration,
                settingsStore: settingsStore,
                expectedRevision: pendingPatch.acceptedBaselineRevision
            )
            try RemoteSyncMutationJournalService().mergeAcceptedLogEntries(
                acceptedEntries: pendingPatch.updatedLogEntries,
                uploadedEntries: pendingPatch.uploadedLogEntries ?? pendingPatch.updatedLogEntries.filter {
                    $0.lastUpdated == pendingPatch.timestamp && $0.sourceDevice == pendingPatch.sourceDevice
                },
                acceptedFingerprints: pendingPatch.acceptedGeneration.fingerprintsByKey,
                currentFingerprints: currentSnapshot.fingerprintsByKey,
                category: .progress,
                settingsStore: settingsStore
            )
            try patchStatusStore.addStatusStrict(
                RemoteSyncPatchStatus(
                    sourceDevice: pendingPatch.sourceDevice,
                    patchNumber: pendingPatch.patchNumber,
                    sizeBytes: uploadedFile.size,
                    appliedDate: uploadedFile.timestamp
                ),
                for: .progress
            )
            var progressState = stateStore.progressState(for: .progress)
            progressState.lastPatchWritten = pendingPatch.timestamp
            stateStore.setProgressState(progressState, for: .progress)
            settingsStore.remove(Self.pendingPatchSettingKey)
            try acceptanceCheckpoint()
        }
        try? fileManager.removeItem(at: pendingArchiveURL(for: pendingPatch))
    }

    /**
     Reads and validates the durable pending Progress generation.

     - Parameter settingsStore: Store containing the optional outbox payload.
     - Returns: Decoded pending generation, or `nil` when no generation exists.
     - Side effects: Reads one settings row.
     - Throws: `invalidPendingPatch` when the stored JSON is malformed.
     */
    private func loadPendingPatch(settingsStore: SettingsStore) throws -> PendingPatch? {
        guard let payload = settingsStore.getString(Self.pendingPatchSettingKey) else {
            return nil
        }
        guard let data = payload.data(using: .utf8),
              let pendingPatch = try? JSONDecoder().decode(PendingPatch.self, from: data),
              pendingPatch.formatVersion == Self.pendingPatchFormatVersion,
              pendingPatch.patchNumber > 0,
              pendingPatch.archiveSize >= 0,
              pendingPatch.archiveSHA256.count == 64,
              URL(fileURLWithPath: pendingPatch.archiveFileName).lastPathComponent
                == pendingPatch.archiveFileName else {
            throw RemoteSyncProgressPatchUploadError.invalidPendingPatch
        }
        guard let publicationIdentity = pendingPatch.publicationIdentity else {
            throw RemoteSyncProgressPatchUploadError.invalidPendingPatch
        }
        var acceptancePayload = pendingPatch
        acceptancePayload.publicationIdentity = nil
        do {
            try publicationIdentity.validate(
                kind: .patch,
                category: .progress,
                destinationID: pendingPatch.deviceFolderID,
                sourceDevice: pendingPatch.sourceDevice,
                patchNumber: pendingPatch.patchNumber,
                schemaVersion: pendingPatch.schemaVersion,
                remoteFileName: pendingPatch.fileName,
                archiveFileName: pendingPatch.archiveFileName,
                archiveSHA256: pendingPatch.archiveSHA256,
                archiveSize: pendingPatch.archiveSize,
                rowCounts: Self.publicationRowCounts(for: pendingPatch),
                acceptancePayload: acceptancePayload
            )
        } catch {
            throw RemoteSyncProgressPatchUploadError.invalidPendingPatch
        }
        return pendingPatch
    }

    /**
     Returns every operation count bound to one Progress publication.

     - Parameter pendingPatch: Identity-free or decoded Progress outbox envelope.
     - Returns: Nonempty count dictionary covering all Android Progress row families.
     - Side effects: none.
     - Failure modes: This deterministic projection cannot fail.
     */
    private static func publicationRowCounts(for pendingPatch: PendingPatch) -> [String: Int] {
        [
            "memorizedVerses": pendingPatch.upsertedMemorizedVerseCount,
            "chapterReadHistory": pendingPatch.upsertedChapterHistoryCount,
            "memorizationTargets": pendingPatch.upsertedTargetCount,
            "globalSettings": pendingPatch.upsertedSettingsCount,
            "deletions": pendingPatch.deletedRowCount,
            "logEntries": pendingPatch.logEntryCount
        ]
    }

    /**
     Persists one complete pending Progress generation into the current settings transaction.

     - Parameters:
       - pendingPatch: Immutable generation containing exact archive bytes and acceptance metadata.
       - settingsStore: Store receiving the encoded outbox payload.
     - Side effects: Stages one settings upsert; the owning atomic batch performs the durable commit.
     - Throws: `invalidPendingPatch` if the encoded payload cannot be represented as UTF-8 JSON.
     */
    private func persistPendingPatch(
        _ pendingPatch: PendingPatch,
        settingsStore: SettingsStore
    ) throws {
        let data = try JSONEncoder().encode(pendingPatch)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw RemoteSyncProgressPatchUploadError.invalidPendingPatch
        }
        settingsStore.setString(Self.pendingPatchSettingKey, value: payload)
    }

    /**
     Resolves a pending manifest's validated archive filename inside the configured outbox directory.

     - Parameter pendingPatch: Decoded manifest whose filename passed traversal validation.
     - Returns: Local URL containing the immutable gzip archive for that generation.
     - Side effects: none; the filesystem is not read or modified.
     - Failure modes: This deterministic path join cannot fail after manifest validation.
     */
    private func pendingArchiveURL(for pendingPatch: PendingPatch) -> URL {
        outboxDirectory.appendingPathComponent(pendingPatch.archiveFileName, isDirectory: false)
    }

    /**
     Reads every Progress `LogEntry` record without silently dropping malformed metadata.

     - Parameters:
       - settingsStore: Store containing namespaced log-entry settings.
       - logEntryStore: Key builder supplying the Progress log prefix.
     - Returns: Fully decoded local Progress log manifest.
     - Side effects: Enumerates matching settings rows.
     - Throws: `invalidLocalMetadata` when any stored log payload is malformed.
     */
    private func strictLogEntries(
        settingsStore: SettingsStore,
        logEntryStore: RemoteSyncLogEntryStore
    ) throws -> [RemoteSyncLogEntry] {
        try settingsStore.entries(withPrefix: logEntryStore.prefix(for: .progress)).map { setting in
            guard let data = setting.value.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(RemoteSyncLogEntry.self, from: data),
                  setting.key == logEntryStore.key(for: .progress, entry: entry) else {
                throw RemoteSyncProgressPatchUploadError.invalidLocalMetadata
            }
            return entry
        }
    }

    /**
     Builds the accepted Android identity manifest while rejecting duplicate decoded identities.

     - Parameters:
       - entries: Strictly decoded Progress log entries.
       - logEntryStore: Canonical key builder for Android composite identities.
     - Returns: One log entry per canonical accepted Android key.
     - Side effects: none.
     - Throws: `invalidLocalMetadata` when two persisted rows decode to the same accepted identity.
     */
    private func strictEntriesByKey(
        _ entries: [RemoteSyncLogEntry],
        logEntryStore: RemoteSyncLogEntryStore
    ) throws -> [String: RemoteSyncLogEntry] {
        var entriesByKey: [String: RemoteSyncLogEntry] = [:]
        for entry in entries {
            let key = logEntryStore.key(for: .progress, entry: entry)
            guard entriesByKey.updateValue(entry, forKey: key) == nil else {
                throw RemoteSyncProgressPatchUploadError.invalidLocalMetadata
            }
        }
        return entriesByKey
    }

    /**
     Reads the exact accepted Progress fingerprint generation as Android log keys.

     - Parameter settingsStore: Store containing category-scoped fingerprint rows.
     - Returns: Accepted fingerprints keyed identically to Progress `LogEntry` rows.
     - Side effects: Enumerates matching settings rows inside the caller's atomic batch.
     - Failure modes: Settings fetch failures are recorded by `SettingsStore` and abort the batch.
     */
    private func strictFingerprintsByLogKey(settingsStore: SettingsStore) -> [String: String] {
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fingerprintPrefix = fingerprintStore.prefix(for: .progress)
        let logPrefix = logEntryStore.prefix(for: .progress)
        return Dictionary(
            uniqueKeysWithValues: settingsStore.entries(withPrefix: fingerprintPrefix).map { setting in
                let suffix = setting.key.dropFirst(fingerprintPrefix.count)
                return ("\(logPrefix)\(suffix)", setting.value)
            }
        )
    }

    /**
     Computes a stable SHA-256 digest for one exact accepted Android log generation.

     - Parameter entries: Strictly decoded Progress log entries captured during preflight.
     - Returns: Lowercase digest of sorted, sorted-key JSON bytes.
     - Side effects: none.
     - Throws: JSON encoding errors; no partial digest or metadata mutation is produced.
     */
    private static func logEntriesSHA256(_ entries: [RemoteSyncLogEntry]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return sha256Hex(try encoder.encode(entries.sorted(by: logEntrySort)))
    }

    /**
     Computes the sparse Android row operations represented by one immutable Progress snapshot.

     - Parameters:
       - snapshot: Projected local Progress generation.
       - existingEntriesByKey: Accepted Android key manifest and latest operations.
       - acceptedRowsByKey: Typed accepted row identities, including initial-backup rows without logs.
       - existingFingerprintsByKey: Exact accepted row fingerprints used for content comparison.
       - timestamp: Timestamp assigned to new Android log operations.
       - sourceDevice: Device name owning the outbound operations.
     - Returns: Sparse row payloads, emitted operations, and the accepted log manifest after upload.
     - Side effects: none.
     - Throws: `missingCurrentFingerprint` when any exportable row lacks a computed fingerprint.
     */
    private func buildChangeSet(
        snapshot: RemoteSyncProgressCurrentSnapshot,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        acceptedRowsByKey: [String: RemoteSyncProgressAcceptedRowIdentity],
        existingFingerprintsByKey: [String: String],
        pendingMutations: [String: RemoteSyncPendingMutation],
        timestamp: Int64,
        sourceDevice: String
    ) throws -> ChangeSet {
        var memorizedVerseRowsByKey: [String: RemoteSyncCurrentProgressMemorizedVerseRow] = [:]
        var chapterHistoryRowsByKey: [String: RemoteSyncCurrentProgressChapterReadHistoryRow] = [:]
        var targetRowsByKey: [String: RemoteSyncCurrentProgressMemorizationTargetRow] = [:]
        var settingsRowsByKey: [String: RemoteSyncCurrentProgressSettingsRow] = [:]
        var logEntries: [RemoteSyncLogEntry] = []
        var updatedEntriesByKey = existingEntriesByKey

        try appendUpserts(
            rowsByKey: snapshot.memorizedVerseRowsByKey,
            tableName: RemoteSyncProgressSnapshotService.memorizedVerseTable,
            fingerprintsByKey: snapshot.fingerprintsByKey,
            existingEntriesByKey: existingEntriesByKey,
            acceptedRowsByKey: acceptedRowsByKey,
            existingFingerprintsByKey: existingFingerprintsByKey,
            pendingMutations: pendingMutations,
            timestamp: timestamp,
            sourceDevice: sourceDevice,
            collectedRows: &memorizedVerseRowsByKey,
            logEntries: &logEntries,
            updatedEntriesByKey: &updatedEntriesByKey
        )
        try appendUpserts(
            rowsByKey: snapshot.chapterHistoryRowsByKey,
            tableName: RemoteSyncProgressSnapshotService.chapterReadHistoryTable,
            fingerprintsByKey: snapshot.fingerprintsByKey,
            existingEntriesByKey: existingEntriesByKey,
            acceptedRowsByKey: acceptedRowsByKey,
            existingFingerprintsByKey: existingFingerprintsByKey,
            pendingMutations: pendingMutations,
            timestamp: timestamp,
            sourceDevice: sourceDevice,
            collectedRows: &chapterHistoryRowsByKey,
            logEntries: &logEntries,
            updatedEntriesByKey: &updatedEntriesByKey
        )
        try appendUpserts(
            rowsByKey: snapshot.memorizationTargetRowsByKey,
            tableName: RemoteSyncProgressSnapshotService.memorizationTargetTable,
            fingerprintsByKey: snapshot.fingerprintsByKey,
            existingEntriesByKey: existingEntriesByKey,
            acceptedRowsByKey: acceptedRowsByKey,
            existingFingerprintsByKey: existingFingerprintsByKey,
            pendingMutations: pendingMutations,
            timestamp: timestamp,
            sourceDevice: sourceDevice,
            collectedRows: &targetRowsByKey,
            logEntries: &logEntries,
            updatedEntriesByKey: &updatedEntriesByKey
        )
        try appendUpserts(
            rowsByKey: snapshot.settingsRowsByKey,
            tableName: RemoteSyncProgressSnapshotService.globalSettingsTable,
            fingerprintsByKey: snapshot.fingerprintsByKey,
            existingEntriesByKey: existingEntriesByKey,
            acceptedRowsByKey: acceptedRowsByKey,
            existingFingerprintsByKey: existingFingerprintsByKey,
            pendingMutations: pendingMutations,
            timestamp: timestamp,
            sourceDevice: sourceDevice,
            collectedRows: &settingsRowsByKey,
            logEntries: &logEntries,
            updatedEntriesByKey: &updatedEntriesByKey
        )

        var deletionRowsByKey = acceptedRowsByKey
        for (key, entry) in existingEntriesByKey where entry.type != .delete {
            deletionRowsByKey[key] = RemoteSyncProgressAcceptedRowIdentity(
                tableName: entry.tableName,
                entityID1: entry.entityID1,
                entityID2: entry.entityID2
            )
        }
        for (key, row) in deletionRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard !snapshot.containsRow(for: key) else {
                continue
            }
            guard existingEntriesByKey[key]?.type != .delete || pendingMutations[key] != nil else {
                continue
            }
            let deleteEntry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: nil,
                type: .delete,
                category: .progress,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                    tableName: row.tableName,
                    entityID1: row.entityID1,
                    entityID2: row.entityID2,
                    type: .delete,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                )
            logEntries.append(deleteEntry)
            updatedEntriesByKey[key] = deleteEntry
        }

        return ChangeSet(
            memorizedVerseRowsByKey: memorizedVerseRowsByKey,
            chapterHistoryRowsByKey: chapterHistoryRowsByKey,
            targetRowsByKey: targetRowsByKey,
            settingsRowsByKey: settingsRowsByKey,
            logEntries: logEntries.sorted(by: Self.logEntrySort),
            updatedEntriesByKey: updatedEntriesByKey
        )
    }

    private func appendUpserts<Row>(
        rowsByKey: [String: Row],
        tableName: String,
        fingerprintsByKey: [String: String],
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        acceptedRowsByKey: [String: RemoteSyncProgressAcceptedRowIdentity],
        existingFingerprintsByKey: [String: String],
        pendingMutations: [String: RemoteSyncPendingMutation],
        timestamp: Int64,
        sourceDevice: String,
        collectedRows: inout [String: Row],
        logEntries: inout [RemoteSyncLogEntry],
        updatedEntriesByKey: inout [String: RemoteSyncLogEntry]
    ) throws {
        for (key, row) in rowsByKey.sorted(by: { $0.key < $1.key }) {
            guard let currentFingerprint = fingerprintsByKey[key] else {
                throw RemoteSyncProgressPatchUploadError.missingCurrentFingerprint(key)
            }
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: currentFingerprint,
                existingEntriesByKey: existingEntriesByKey,
                acceptedRowsByKey: acceptedRowsByKey,
                existingFingerprintsByKey: existingFingerprintsByKey
            ) else {
                continue
            }
            let entry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: currentFingerprint,
                type: .upsert,
                category: .progress,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                    tableName: tableName,
                    entityID1: Self.entityID1(
                        fromLogKeyEntry: existingEntriesByKey[key],
                        acceptedIdentity: acceptedRowsByKey[key],
                        row: row
                    ),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                )
            collectedRows[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }
    }

    /**
     Decides whether a current row must be represented in the next outbound patch.

     Missing fingerprints are upload-needed rather than assumed unchanged. This conservative rule
     prevents baseline loss or partial migration from silently suppressing a real local row.

     - Parameters:
       - key: Android composite row key.
       - currentFingerprint: Fingerprint of the immutable projected row.
       - existingEntriesByKey: Accepted Android operation manifest.
       - acceptedRowsByKey: Typed accepted row identities, including initial-backup rows without logs.
       - existingFingerprintsByKey: Exact accepted row fingerprints from preflight.
     - Returns: `true` when the row is new, changed, resurrected, or lacks a trustworthy baseline.
     - Side effects: none.
     - Failure modes: This deterministic comparison cannot fail.
     */
    private func shouldUploadCurrentRow(
        key: String,
        currentFingerprint: String,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        acceptedRowsByKey: [String: RemoteSyncProgressAcceptedRowIdentity],
        existingFingerprintsByKey: [String: String]
    ) -> Bool {
        if existingEntriesByKey[key]?.type == .delete {
            return true
        }
        guard acceptedRowsByKey[key] != nil || existingEntriesByKey[key] != nil else {
            return true
        }
        guard let existingFingerprint = existingFingerprintsByKey[key] else {
            return true
        }
        return existingFingerprint != currentFingerprint
    }

    private static func entityID1<Row>(
        fromLogKeyEntry entry: RemoteSyncLogEntry?,
        acceptedIdentity: RemoteSyncProgressAcceptedRowIdentity?,
        row: Row
    ) -> RemoteSyncSQLiteValue {
        if let entry {
            return entry.entityID1
        }
        if let acceptedIdentity {
            return acceptedIdentity.entityID1
        }
        switch row {
        case let row as RemoteSyncCurrentProgressMemorizedVerseRow:
            return .blob(RemoteSyncProgressSnapshotService.uuidBlob(row.id))
        case let row as RemoteSyncCurrentProgressChapterReadHistoryRow:
            return .blob(RemoteSyncProgressSnapshotService.uuidBlob(row.id))
        case let row as RemoteSyncCurrentProgressMemorizationTargetRow:
            return .blob(RemoteSyncProgressSnapshotService.uuidBlob(row.id))
        case let row as RemoteSyncCurrentProgressSettingsRow:
            return .blob(RemoteSyncProgressSnapshotService.uuidBlob(row.id))
        default:
            return .null()
        }
    }

    private func writePatchDatabase(at url: URL, schemaVersion: Int, changeSet: ChangeSet) throws {
        guard schemaVersion == RemoteSyncAndroidDatabaseContract.schemaVersion(for: .progress) else {
            throw RemoteSyncProgressPatchUploadError.unsupportedSchemaVersion(schemaVersion)
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let database else {
            throw RemoteSyncProgressPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        try execute(
            RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: .progress),
            in: database
        )
        for row in changeSet.memorizedVerseRowsByKey.values.sorted(by: { $0.kjvOrdinal < $1.kjvOrdinal }) {
            try insertMemorizedVerse(row, in: database)
        }
        for row in changeSet.chapterHistoryRowsByKey.values.sorted(by: { $0.readAt < $1.readAt }) {
            try insertChapterHistory(row, in: database)
        }
        for row in changeSet.targetRowsByKey.values.sorted(by: { $0.createdAt > $1.createdAt }) {
            try insertTarget(row, in: database)
        }
        for row in changeSet.settingsRowsByKey.values {
            try insertSettings(row, in: database)
        }
        for entry in changeSet.logEntries {
            try insertLogEntry(entry, in: database)
        }
    }

    private func insertMemorizedVerse(_ row: RemoteSyncCurrentProgressMemorizedVerseRow, in database: OpaquePointer) throws {
        let statement = try prepare("INSERT INTO MemorizedVerse (id, kjvOrdinal, memorizedAt) VALUES (?, ?, ?);", in: database)
        defer { sqlite3_finalize(statement) }
        try bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_int(
            statement,
            2,
            try RemoteSyncWireInteger.int32(
                exactly: row.kjvOrdinal,
                field: "MemorizedVerse.kjvOrdinal"
            )
        )
        sqlite3_bind_int64(statement, 3, row.memorizedAt)
        try stepDone(statement)
    }

    private func insertChapterHistory(_ row: RemoteSyncCurrentProgressChapterReadHistoryRow, in database: OpaquePointer) throws {
        let statement = try prepare(
            """
            INSERT INTO ChapterReadHistory (id, kjvBookOrdinal, chapter, cycle, readAt, bookInitials, source)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_int(
            statement,
            2,
            try RemoteSyncWireInteger.int32(
                exactly: row.kjvBookOrdinal,
                field: "ChapterReadHistory.kjvBookOrdinal"
            )
        )
        sqlite3_bind_int(
            statement,
            3,
            try RemoteSyncWireInteger.int32(
                exactly: row.chapter,
                field: "ChapterReadHistory.chapter"
            )
        )
        sqlite3_bind_int(
            statement,
            4,
            try RemoteSyncWireInteger.int32(
                exactly: row.cycle,
                field: "ChapterReadHistory.cycle"
            )
        )
        sqlite3_bind_int64(statement, 5, row.readAt)
        bindText(row.bookInitials, to: statement, index: 6)
        bindText(row.source.rawValue, to: statement, index: 7)
        try stepDone(statement)
    }

    private func insertTarget(_ row: RemoteSyncCurrentProgressMemorizationTargetRow, in database: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT INTO MemorizationTarget (id, kjvOrdinalStart, kjvOrdinalEnd, createdAt) VALUES (?, ?, ?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_int(
            statement,
            2,
            try RemoteSyncWireInteger.int32(
                exactly: row.kjvOrdinalStart,
                field: "MemorizationTarget.kjvOrdinalStart"
            )
        )
        sqlite3_bind_int(
            statement,
            3,
            try RemoteSyncWireInteger.int32(
                exactly: row.kjvOrdinalEnd,
                field: "MemorizationTarget.kjvOrdinalEnd"
            )
        )
        sqlite3_bind_int64(statement, 4, row.createdAt)
        try stepDone(statement)
    }

    private func insertSettings(_ row: RemoteSyncCurrentProgressSettingsRow, in database: OpaquePointer) throws {
        let statement = try prepare(
            """
            INSERT INTO GlobalReadingProgressSettings (
                id, autoTrackReading, autoMarkMemorized, memorizeTypeFullWords, memorizeWordVisibility,
                memorizeErrorHeatmap, memorizeScrambleHideUsed, memorizeIncludeReference, activeCycle
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_int(statement, 2, row.autoTrackReading ? 1 : 0)
        sqlite3_bind_int(statement, 3, row.autoMarkMemorized ? 1 : 0)
        sqlite3_bind_int(statement, 4, row.memorizeTypeFullWords ? 1 : 0)
        bindText(row.memorizeWordVisibility, to: statement, index: 5)
        sqlite3_bind_int(statement, 6, row.memorizeErrorHeatmap ? 1 : 0)
        sqlite3_bind_int(statement, 7, row.memorizeScrambleHideUsed ? 1 : 0)
        sqlite3_bind_int(statement, 8, row.memorizeIncludeReference ? 1 : 0)
        sqlite3_bind_int(
            statement,
            9,
            try RemoteSyncWireInteger.int32(
                exactly: row.activeCycle,
                field: "GlobalReadingProgressSettings.activeCycle"
            )
        )
        try stepDone(statement)
    }

    private func insertLogEntry(_ entry: RemoteSyncLogEntry, in database: OpaquePointer) throws {
        let statement = try prepare(
            "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?);",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        bindText(entry.tableName, to: statement, index: 1)
        try Self.bindSQLiteValue(entry.entityID1, to: statement, index: 2)
        try Self.bindSQLiteValue(entry.entityID2, to: statement, index: 3)
        bindText(entry.type.rawValue, to: statement, index: 4)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        bindText(entry.sourceDevice, to: statement, index: 6)
        try stepDone(statement)
    }

    private func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncProgressPatchUploadError.invalidSQLiteDatabase
        }
        return statement
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncProgressPatchUploadError.invalidSQLiteDatabase
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncProgressPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Binds one UUID in Android Room's exact 16-byte blob representation.

     - Parameters:
       - uuid: Stable row identifier to encode without textual normalization.
       - statement: Prepared SQLite statement receiving the blob.
       - index: One-based SQLite bind parameter index.
     - Side effects: Mutates the prepared statement's bound-parameter state.
     - Throws: `RemoteSyncWireIntegerError.outOfRange` if the encoded byte count cannot fit the
       SQLite signed 32-bit length argument; SQLite bind status is checked by the caller's step.
     - Note: Encoding is deterministic for a given UUID.
     */
    private func bindUUIDBlob(
        _ uuid: UUID,
        to statement: OpaquePointer?,
        index: Int32
    ) throws {
        let data = RemoteSyncProgressSnapshotService.uuidBlob(uuid)
        let byteCount = try RemoteSyncWireInteger.int32(
            exactly: data.count,
            field: "UUID.byteCount"
        )
        _ = data.withUnsafeBytes {
            sqlite3_bind_blob(
                statement,
                index,
                $0.baseAddress,
                byteCount,
                remoteSyncProgressPatchUploadSQLiteTransient
            )
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, remoteSyncProgressPatchUploadSQLiteTransient)
    }

    /**
     Binds one typed log-entry identity without narrowing blob lengths.

     - Parameters:
       - value: Typed SQLite scalar preserving Android's null, numeric, text, or blob identity.
       - statement: Prepared SQLite statement receiving the value.
       - index: One-based SQLite bind parameter index.
     - Side effects: Mutates the prepared statement's bound-parameter state.
     - Throws: `RemoteSyncWireIntegerError.outOfRange` when a blob length cannot fit SQLite's
       signed 32-bit byte-count argument; SQLite bind status is checked by the caller's step.
     - Note: Scalar values are bound losslessly in their represented SQLite storage class.
     */
    private static func bindSQLiteValue(
        _ value: RemoteSyncSQLiteValue,
        to statement: OpaquePointer?,
        index: Int32
    ) throws {
        switch value.kind {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer:
            sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
        case .real:
            sqlite3_bind_double(statement, index, value.realValue ?? 0)
        case .text:
            sqlite3_bind_text(statement, index, value.textValue ?? "", -1, remoteSyncProgressPatchUploadSQLiteTransient)
        case .blob:
            let data = value.blobData ?? Data()
            let byteCount = try RemoteSyncWireInteger.int32(
                exactly: data.count,
                field: "LogEntry.entityId.byteCount"
            )
            _ = data.withUnsafeBytes {
                sqlite3_bind_blob(
                    statement,
                    index,
                    $0.baseAddress,
                    byteCount,
                    remoteSyncProgressPatchUploadSQLiteTransient
                )
            }
        }
    }

    /**
     Resolves the production Application Support directory used for durable Progress patch archives.

     - Parameter fileManager: Filesystem provider used to locate the user Application Support root.
     - Returns: The category-specific outbox URL, falling back to the process temporary root only when
       Application Support cannot be resolved.
     - Side effects: none; directory creation is performed only when a generation is persisted.
     - Failure modes: This path construction does not throw.
     */
    static func defaultOutboxDirectory(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent("AndBible", isDirectory: true)
            .appendingPathComponent("RemoteSyncOutbox", isDirectory: true)
            .appendingPathComponent("Progress", isDirectory: true)
    }

    /**
     Computes the lowercase SHA-256 digest that binds durable archive or metadata bytes.

     - Parameter data: Exact immutable bytes to identify.
     - Returns: A deterministic 64-character lowercase hexadecimal digest.
     - Side effects: none.
     - Failure modes: CryptoKit hashing is total for in-memory data and does not throw.
     */
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    private static func sourceDeviceName(from deviceFolderID: String) -> String {
        let trimmed = deviceFolderID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? deviceFolderID
    }

    private static func logEntrySort(_ lhs: RemoteSyncLogEntry, _ rhs: RemoteSyncLogEntry) -> Bool {
        if lhs.tableName != rhs.tableName {
            return lhs.tableName < rhs.tableName
        }
        if lhs.lastUpdated != rhs.lastUpdated {
            return lhs.lastUpdated < rhs.lastUpdated
        }
        return "\(lhs.entityID1)-\(lhs.entityID2)" < "\(rhs.entityID1)-\(rhs.entityID2)"
    }
}
