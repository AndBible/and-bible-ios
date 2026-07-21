// RemoteSyncReadingPlanPatchUploadService.swift — Android-shaped outbound reading-plan patch creation and upload

import Foundation
import SQLite3
import SwiftData

private let remoteSyncReadingPlanPatchUploadSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while exporting and uploading an outbound Android reading-plan patch.
 */
public enum RemoteSyncReadingPlanPatchUploadError: Error, Equatable {
    /// The category is not ready for upload because no remote device folder identifier is known locally.
    case missingDeviceFolderID

    /// The generated temporary SQLite patch database could not be opened for writing.
    case invalidSQLiteDatabase

    /// Durable pending-upload metadata could not be encoded or decoded safely.
    case invalidPendingUpload

    /// A pending archive belongs to a different destination and requires deliberate reset handling.
    case pendingUploadDestinationMismatch(stored: String, requested: String)

    /// One preserved Android log row was malformed or stored under the wrong key.
    case invalidStoredLogEntry(String)

    /// The requested wire schema is not the exact Android Room contract supported by this build.
    case unsupportedSchemaVersion(Int)

    /// Local and remote patch history exhausted Android's signed 64-bit number range.
    case patchNumberExhausted

    /// Android database sync cannot reconstruct active device-local custom plan definitions.
    case unsupportedCustomReadingPlans([String])
}

/**
 Summary of one successful outbound reading-plan patch upload.

 Android sync tracks patch creation per device folder and relies on `LogEntry` rows for sparse row
 replay. This report preserves the same core counters so higher layers can verify that an upload
 actually contained the expected Android-shaped mutations.
 */
public struct RemoteSyncReadingPlanPatchUploadReport: Sendable, Equatable {
    /// Remote file metadata returned by the backend after upload succeeded.
    public let uploadedFile: RemoteSyncFile

    /// Monotonic patch number assigned within the current device folder.
    public let patchNumber: Int64

    /// Number of `ReadingPlan` rows written into the patch database.
    public let upsertedPlanCount: Int

    /// Number of `ReadingPlanStatus` rows written into the patch database.
    public let upsertedStatusCount: Int

    /// Number of `DELETE` log entries emitted for rows removed locally.
    public let deletedRowCount: Int

    /// Total number of Android `LogEntry` rows written into the patch database.
    public let logEntryCount: Int

    /// Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
    public let lastUpdated: Int64

    /**
     Creates one outbound reading-plan patch-upload summary.

     - Parameters:
       - uploadedFile: Remote file metadata returned by the backend after upload succeeded.
       - patchNumber: Monotonic patch number assigned within the current device folder.
       - upsertedPlanCount: Number of `ReadingPlan` rows written into the patch database.
       - upsertedStatusCount: Number of `ReadingPlanStatus` rows written into the patch database.
       - deletedRowCount: Number of `DELETE` log entries emitted for rows removed locally.
       - logEntryCount: Total number of Android `LogEntry` rows written into the patch database.
       - lastUpdated: Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        uploadedFile: RemoteSyncFile,
        patchNumber: Int64,
        upsertedPlanCount: Int,
        upsertedStatusCount: Int,
        deletedRowCount: Int,
        logEntryCount: Int,
        lastUpdated: Int64
    ) {
        self.uploadedFile = uploadedFile
        self.patchNumber = patchNumber
        self.upsertedPlanCount = upsertedPlanCount
        self.upsertedStatusCount = upsertedStatusCount
        self.deletedRowCount = deletedRowCount
        self.logEntryCount = logEntryCount
        self.lastUpdated = lastUpdated
    }
}

/**
 Creates Android-shaped sparse reading-plan patch databases and uploads them to the active backend.

 The service mirrors the outbound half of Android's reading-plan sync contract for the one category
 that currently has a full iOS fidelity bridge:
 - project current local SwiftData state into Android `ReadingPlan` and `ReadingPlanStatus` rows
 - compare native Android rows against the preserved `LogEntry` baseline and local fingerprints
 - emit sparse `UPSERT` and `DELETE` `LogEntry` rows for only the changed Android keys
 - stream an Android-compatible SQLite patch database into the bounded gzip outbox contract
 - upload `<patchNumber>.<schemaVersion>.sqlite3.gz` into the device folder
 - advance local `LogEntry`, `SyncStatus`, `lastPatchWritten`, and fingerprint baselines only after upload succeeds

 Data dependencies:
 - `RemoteSyncAdapting` performs the remote file upload
 - `RemoteSyncReadingPlanSnapshotService` projects live SwiftData and local-only status metadata into Android-shaped rows
 - `RemoteSyncLogEntryStore` provides the Android conflict baseline and is updated after successful upload
 - `RemoteSyncReadingPlanStatusStore` preserves the accepted Android status payloads for later local diffs
 - `RemoteSyncPatchStatusStore` tracks the highest uploaded patch number for the local device folder
 - `RemoteSyncStateStore` persists Android-aligned `lastPatchWritten` bookkeeping
 - `RemoteSyncArchiveStagingService` streams the generated SQLite patch into the bounded gzip contract

 Side effects:
 - reads live `ReadingPlan` state and preserved status/log metadata
 - creates and removes temporary SQLite files and manages one durable Application Support gzip outbox
 - uploads a gzip patch archive into the ready device folder
 - rewrites preserved Android status payloads for uploaded or deleted reading-plan status rows
 - rewrites local Android `LogEntry` and fingerprint baselines for `.readingPlans` after successful upload
 - appends one local patch status row and updates `lastPatchWritten`

 Failure modes:
 - throws `RemoteSyncReadingPlanPatchUploadError.missingDeviceFolderID` when the category is not bootstrapped for outbound upload
 - throws `RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase` when the temporary SQLite patch file cannot be created
 - rethrows local filesystem write failures while building the temporary SQLite or gzip files
 - rethrows backend transport and local-file validation failures
 - rethrows cancellation and bounded gzip failures from `gzipPatchDatabase(at:to:)`

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement rules of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncReadingPlanPatchUploadService {
    /**
     Records one generated Android status identifier that may be merged after upload acceptance.

     Only statuses that already existed without a remote id enter this list. Acceptance therefore
     cannot recreate a status deleted while transport was suspended, and it preserves any newer
     payload stored under the same logical plan/day key.
     */
    private struct GeneratedStatusIdentity: Codable, Equatable {
        let planCode: String
        let dayNumber: Int
        let remoteStatusID: UUID
    }

    /**
     Durable metadata for one exact reading-plan patch archive awaiting local acceptance.

     The archive itself is file-backed so retries after process termination publish byte-identical
     content for the same patch number. This envelope carries all local acceptance inputs so retry
     never reprojects the live graph.
     */
    private struct PendingUpload: Codable, Equatable {
        let formatVersion: Int
        let deviceFolderID: String
        let sourceDevice: String
        let patchNumber: Int64
        let schemaVersion: Int
        let timestamp: Int64
        let archiveFileName: String
        let archiveSHA256: String
        let archiveSize: Int64
        let expectedBaselineRevision: Int64
        let acceptedGeneration: RemoteSyncReadingPlanAcceptedGeneration
        let updatedLogEntries: [RemoteSyncLogEntry]
        let uploadedLogEntries: [RemoteSyncLogEntry]?
        let generatedStatusIdentities: [GeneratedStatusIdentity]
        let upsertedPlanCount: Int
        let upsertedStatusCount: Int
        let deletedRowCount: Int
        let logEntryCount: Int
        var publicationIdentity: RemoteSyncPublicationIdentity? = nil

        /// Android-compatible archive name derived from the durable patch identity.
        var patchFileName: String {
            "\(patchNumber).\(schemaVersion).sqlite3.gz"
        }
    }

    /**
     In-memory generation used only until its exact archive and acceptance envelope are durable.
     */
    private struct UploadGeneration {
        let deviceFolderID: String
        let sourceDevice: String
        let patchNumber: Int64
        let schemaVersion: Int
        let timestamp: Int64
        let expectedBaselineRevision: Int64
        let acceptedGeneration: RemoteSyncReadingPlanAcceptedGeneration
        let updatedLogEntries: [RemoteSyncLogEntry]
        let generatedStatusIdentities: [GeneratedStatusIdentity]
        let changeSet: ChangeSet
    }

    /**
     Result of the single atomic preflight read boundary.
     */
    private enum PreflightResult {
        case noChanges
        case pending(PendingUpload)
        case generation(UploadGeneration)
    }

    private struct ChangeSet {
        let planRowsByKey: [String: RemoteSyncCurrentReadingPlanRow]
        let statusRowsByKey: [String: RemoteSyncCurrentReadingPlanStatusRow]
        let logEntries: [RemoteSyncLogEntry]
        let updatedEntriesByKey: [String: RemoteSyncLogEntry]

        /**
         Returns the total number of delete log entries in the change set.

         - Returns: Number of emitted delete operations.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        var deletedRowCount: Int {
            logEntries.filter { $0.type == .delete }.count
        }
    }

    private let adapter: any RemoteSyncAdapting
    private let remotePatchReconciler: RemoteSyncRemotePatchReconciler
    private let snapshotService: RemoteSyncReadingPlanSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let outboxDirectory: URL
    private let nowProvider: () -> Int64
    private let finalAcceptanceCheckpoint: () throws -> Void
    /// Local-only settings key holding the pending reading-plan upload envelope.
    static let pendingUploadKey = "remote_sync.readingplans.pending_upload"

    /// Current durable envelope format.
    private static let pendingUploadFormatVersion = 2

    /**
     Creates a reading-plan patch upload service for one remote backend.

     - Parameters:
       - adapter: Remote backend adapter used for the final archive upload.
       - snapshotService: Snapshot service used to project current local reading-plan state into Android rows.
       - userPlanDirectory: Local custom-definition directory used by snapshot recovery.
       - fileManager: File manager used for temporary-file cleanup.
       - temporaryDirectory: Scratch directory for temporary SQLite and gzip files. Defaults to the process temporary directory.
       - nowProvider: Millisecond clock used for Android `LogEntry.lastUpdated` and local `lastPatchWritten`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public convenience init(
        adapter: any RemoteSyncAdapting,
        snapshotService: RemoteSyncReadingPlanSnapshotService? = nil,
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        outboxDirectory: URL? = nil,
        nowProvider: @escaping () -> Int64 = {
            AndroidTimestamp.currentMilliseconds()
        }
    ) {
        self.init(
            adapter: adapter,
            snapshotService: snapshotService,
            userPlanDirectory: userPlanDirectory,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            outboxDirectory: outboxDirectory,
            nowProvider: nowProvider,
            finalAcceptanceCheckpoint: {}
        )
    }

    /**
     Creates a reading-plan uploader with an internal final-acceptance checkpoint.

     - Parameters:
       - adapter: Remote backend adapter used for archive upload.
       - snapshotService: Strict graph projector and accepted-baseline publisher.
       - userPlanDirectory: Local custom-definition directory used by snapshot recovery.
       - fileManager: File manager used for temporary and durable outbox files.
       - temporaryDirectory: Scratch directory for SQLite construction.
       - outboxDirectory: Durable directory that survives process termination.
       - nowProvider: Millisecond clock used for patch metadata.
       - finalAcceptanceCheckpoint: Synchronous checkpoint run after every local acceptance mutation
         but before the atomic batch commits.
     - Side effects: none until upload is requested.
     - Failure modes: The initializer cannot fail; checkpoint failures are surfaced by upload.
     */
    init(
        adapter: any RemoteSyncAdapting,
        snapshotService: RemoteSyncReadingPlanSnapshotService? = nil,
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        outboxDirectory: URL? = nil,
        nowProvider: @escaping () -> Int64 = {
            AndroidTimestamp.currentMilliseconds()
        },
        finalAcceptanceCheckpoint: @escaping () throws -> Void
    ) {
        self.adapter = adapter
        self.remotePatchReconciler = RemoteSyncRemotePatchReconciler(adapter: adapter)
        self.snapshotService = snapshotService ?? RemoteSyncReadingPlanSnapshotService(
            userPlanDirectory: userPlanDirectory,
            fileManager: fileManager
        )
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.outboxDirectory = outboxDirectory ?? Self.defaultOutboxDirectory(fileManager: fileManager)
        self.nowProvider = nowProvider
        self.finalAcceptanceCheckpoint = finalAcceptanceCheckpoint
    }

    /**
     Builds and uploads the next sparse reading-plan patch when local state differs from the baseline.

     The service is intentionally conservative about missing fingerprint baselines. When it finds a
     preserved Android `LogEntry` row with no matching local fingerprint, it assumes the row came
     from a pre-fingerprint restore or replay and refreshes the baseline without uploading a patch.
     That avoids fabricating large false-positive patches the first time outbound diffing is enabled
     on an existing install.

     - Parameters:
       - bootstrapState: Ready bootstrap state for the reading-plan category.
       - modelContext: SwiftData context that owns the live reading-plan graph.
       - settingsStore: Local-only settings store backing preserved Android sync metadata.
       - schemaVersion: Schema version to encode into the generated patch filename and SQLite user version.
     - Returns: Upload summary when a sparse patch was emitted, or `nil` when no local changes need upload.
     - Side effects:
       - may refresh the fingerprint baseline without uploading when the service encounters historical rows with no stored fingerprints
       - creates and removes temporary SQLite and gzip files
       - uploads a gzip patch archive when local changes exist
       - rewrites local `LogEntry`, patch-status, progress, and fingerprint state after successful upload
     - Failure modes:
       - throws `RemoteSyncReadingPlanPatchUploadError.missingDeviceFolderID` when `bootstrapState.deviceFolderID` is missing or empty
       - throws `RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase` when the temporary SQLite patch file cannot be opened
       - rethrows filesystem, compression, and backend upload failures
     */
    public func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = 1
    ) async throws -> RemoteSyncReadingPlanPatchUploadReport? {
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncReadingPlanPatchUploadError.missingDeviceFolderID
        }

        if let resumed = try await resumePendingUploadIfPresent(
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore
        ) {
            return resumed
        }

        let hasPendingWork = try settingsStore.performAtomicBatch(in: modelContext) {
            let snapshot = try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            let unsupportedPlanCodes = snapshotService
                .unsupportedCustomPlanCodes(in: snapshot)
            guard unsupportedPlanCodes.isEmpty else {
                throw RemoteSyncReadingPlanPatchUploadError.unsupportedCustomReadingPlans(
                    unsupportedPlanCodes
                )
            }
            let mutationJournal = RemoteSyncMutationJournalService(
                nowProvider: nowProvider,
                readingPlanSnapshotService: snapshotService
            )
            try mutationJournal.recordLocalChanges(
                for: .readingPlans,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            return try !mutationJournal.pendingMutations(
                for: .readingPlans,
                settingsStore: settingsStore
            ).isEmpty
        }
        guard hasPendingWork else {
            return nil
        }

        let sourceDevice = Self.sourceDeviceName(from: deviceFolderID)
        let remotePatchNumber = try await maximumRemotePatchNumber(deviceFolderID: deviceFolderID)
        let preflight = try settingsStore.performAtomicBatch(in: modelContext) {
            try Task.checkCancellation()
            if let pendingUpload = try loadPendingUpload(settingsStore: settingsStore) {
                guard pendingUpload.deviceFolderID == deviceFolderID else {
                    throw RemoteSyncReadingPlanPatchUploadError.pendingUploadDestinationMismatch(
                        stored: pendingUpload.deviceFolderID,
                        requested: deviceFolderID
                    )
                }
                return PreflightResult.pending(pendingUpload)
            }

            let wallClockTimestamp = nowProvider()
            let snapshot = try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            let unsupportedPlanCodes = snapshotService
                .unsupportedCustomPlanCodes(in: snapshot)
            guard unsupportedPlanCodes.isEmpty else {
                throw RemoteSyncReadingPlanPatchUploadError.unsupportedCustomReadingPlans(
                    unsupportedPlanCodes
                )
            }
            let mutationJournal = RemoteSyncMutationJournalService(
                nowProvider: nowProvider,
                readingPlanSnapshotService: snapshotService
            )
            try mutationJournal.recordLocalChanges(
                for: .readingPlans,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            let pendingMutations = try mutationJournal.pendingMutations(
                for: .readingPlans,
                settingsStore: settingsStore
            )
            try snapshotService.validateExportableFingerprints(in: snapshot)
            let acceptedBaseline = try snapshotService.storedAcceptedBaseline(
                settingsStore: settingsStore
            )
            let acceptedGeneration = snapshotService.acceptedGeneration(
                from: snapshot,
                preserving: acceptedBaseline?.generation
            )
            let acceptedRows = acceptedBaseline?.generation.rowsByKey
            let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
            let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
            let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
            let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
            let patchStatuses = try patchStatusStore.statusesStrict(for: .readingPlans)

            let existingEntriesByKey = Dictionary(
                uniqueKeysWithValues: try strictLogEntries(
                    settingsStore: settingsStore,
                    logEntryStore: logEntryStore
                ).map {
                    (logEntryStore.key(for: .readingPlans, entry: $0), $0)
                }
            )
            let progressState = RemoteSyncStateStore(settingsStore: settingsStore)
                .progressState(for: .readingPlans)
            let timestamp = try RemoteSyncLogicalSequence.nextTimestamp(
                now: wallClockTimestamp,
                highWatermarks: existingEntriesByKey.values.map(\.lastUpdated)
                    + patchStatuses.map(\.appliedDate)
                    + [progressState.lastPatchWritten, progressState.lastSynchronized].compactMap { $0 }
            )
            let changeSet = try buildChangeSet(
                snapshot: snapshot,
                acceptedRowsByKey: acceptedRows ?? [:],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore,
                pendingMutations: pendingMutations,
                timestamp: timestamp,
                sourceDevice: sourceDevice
            )

            if changeSet.logEntries.isEmpty {
                if acceptedBaseline == nil {
                    try snapshotService.acceptBaselineFingerprints(
                        acceptedGeneration,
                        settingsStore: settingsStore,
                        expectedRevision: 0
                    )
                }
                return PreflightResult.noChanges
            }

            let generatedStatusIdentities: [GeneratedStatusIdentity] = try changeSet.statusRowsByKey.values.compactMap {
                row -> GeneratedStatusIdentity? in
                guard let status = try statusStore.storedStatusStrict(
                    planCode: row.planCode,
                    dayNumber: row.planDay
                ), status.remoteStatusID == nil else {
                    return nil
                }
                return GeneratedStatusIdentity(
                    planCode: row.planCode,
                    dayNumber: row.planDay,
                    remoteStatusID: row.id
                )
            }
            let localPatchNumber = patchStatuses
                .filter { $0.sourceDevice == sourceDevice }
                .map(\.patchNumber)
                .max() ?? 0
            let patchNumber: Int64
            do {
                patchNumber = try RemoteSyncPublicationIdentity.nextPatchNumber(
                    after: [localPatchNumber, remotePatchNumber]
                )
            } catch {
                throw RemoteSyncReadingPlanPatchUploadError.patchNumberExhausted
            }
            return PreflightResult.generation(
                UploadGeneration(
                    deviceFolderID: deviceFolderID,
                    sourceDevice: sourceDevice,
                    patchNumber: patchNumber,
                    schemaVersion: schemaVersion,
                    timestamp: timestamp,
                    expectedBaselineRevision: acceptedBaseline?.revision ?? 0,
                    acceptedGeneration: acceptedGeneration,
                    updatedLogEntries: changeSet.updatedEntriesByKey.values.sorted(by: Self.logEntrySort),
                    generatedStatusIdentities: generatedStatusIdentities,
                    changeSet: changeSet
                )
            )
        }

        let pendingUpload: PendingUpload
        switch preflight {
        case .noChanges:
            return nil
        case .pending(let existingUpload):
            pendingUpload = existingUpload
        case .generation(let generation):
            pendingUpload = try persistPendingUpload(
                generation,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }
        return try await finishPendingUpload(
            pendingUpload,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
    }

    /**
     Resumes an already-durable reading-plan generation without projecting or creating new work.

     Synchronization calls this before inbound replay so a remotely published generation is accepted
     against the baseline revision it was built from. A destination mismatch remains fail-closed and
     must be cleared only by the explicit category reset/replacement boundary.

     - Parameters:
       - bootstrapState: Ready bootstrap state naming the current device folder.
       - modelContext: Clean context shared by the graph and settings store.
       - settingsStore: Local store containing any durable pending envelope.
     - Returns: Accepted upload report, or `nil` when no pending generation exists.
     - Side effects: May reconcile exact remote bytes and atomically accept one durable generation.
     - Throws: Rethrows destination, outbox, transport, cancellation, CAS, and acceptance failures.
     */
    public func resumePendingUploadIfPresent(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncReadingPlanPatchUploadReport? {
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncReadingPlanPatchUploadError.missingDeviceFolderID
        }
        let pendingUpload = try settingsStore.performAtomicBatch(in: modelContext) {
            try Task.checkCancellation()
            return try loadPendingUpload(settingsStore: settingsStore)
        }
        guard let pendingUpload else {
            return nil
        }
        guard pendingUpload.deviceFolderID == deviceFolderID else {
            throw RemoteSyncReadingPlanPatchUploadError.pendingUploadDestinationMismatch(
                stored: pendingUpload.deviceFolderID,
                requested: deviceFolderID
            )
        }
        return try await finishPendingUpload(
            pendingUpload,
            modelContext: modelContext,
            settingsStore: settingsStore
        )
    }

    /**
     Reconciles one durable archive remotely and publishes its exact local acceptance generation.

     - Parameters:
       - pendingUpload: Persisted outbox envelope to finish.
       - modelContext: Clean context shared by graph and settings.
       - settingsStore: Local synchronization metadata store.
     - Returns: Report reconstructed from the durable generation and accepted remote metadata.
     - Side effects: Conditionally creates or verifies the remote patch, atomically publishes local
       metadata, and removes the archive only after local commit.
     - Throws: Rethrows durable-byte, remote conflict, cancellation, stale-baseline, and atomic failures.
     */
    private func finishPendingUpload(
        _ pendingUpload: PendingUpload,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncReadingPlanPatchUploadReport {
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
        let uploadedFile: RemoteSyncFile
        switch reconciliation {
        case .created(let file), .matchedExisting(let file):
            uploadedFile = file
        }
        try Task.checkCancellation()

        try settingsStore.performAtomicBatch(in: modelContext) {
            guard try loadPendingUpload(settingsStore: settingsStore) == pendingUpload else {
                throw RemoteSyncReadingPlanPatchUploadError.invalidPendingUpload
            }
            try validateStoredStatuses(settingsStore: settingsStore)
            let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
            try mergeGeneratedStatusIdentities(
                pendingUpload.generatedStatusIdentities,
                into: statusStore
            )
            let currentSnapshot = try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            try snapshotService.validateExportableFingerprints(in: currentSnapshot)
            try RemoteSyncMutationJournalService().mergeAcceptedLogEntries(
                acceptedEntries: pendingUpload.updatedLogEntries,
                uploadedEntries: pendingUpload.uploadedLogEntries ?? pendingUpload.updatedLogEntries.filter {
                    $0.lastUpdated == pendingUpload.timestamp && $0.sourceDevice == pendingUpload.sourceDevice
                },
                acceptedFingerprints: pendingUpload.acceptedGeneration.fingerprintsByKey,
                currentFingerprints: currentSnapshot.fingerprintsByKey,
                category: .readingPlans,
                settingsStore: settingsStore
            )
            try RemoteSyncPatchStatusStore(settingsStore: settingsStore).addStatusStrict(
                RemoteSyncPatchStatus(
                    sourceDevice: pendingUpload.sourceDevice,
                    patchNumber: pendingUpload.patchNumber,
                    sizeBytes: uploadedFile.size,
                    appliedDate: uploadedFile.timestamp
                ),
                for: .readingPlans
            )
            let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
            settingsStore.setString(
                stateStore.scopedKey("lastPatchWritten", category: .readingPlans),
                value: String(pendingUpload.timestamp)
            )
            try snapshotService.acceptBaselineFingerprints(
                pendingUpload.acceptedGeneration,
                settingsStore: settingsStore,
                expectedRevision: pendingUpload.expectedBaselineRevision
            )
            settingsStore.remove(Self.pendingUploadKey)
            try finalAcceptanceCheckpoint()
        }

        try? fileManager.removeItem(at: archiveURL)
        return RemoteSyncReadingPlanPatchUploadReport(
            uploadedFile: uploadedFile,
            patchNumber: pendingUpload.patchNumber,
            upsertedPlanCount: pendingUpload.upsertedPlanCount,
            upsertedStatusCount: pendingUpload.upsertedStatusCount,
            deletedRowCount: pendingUpload.deletedRowCount,
            logEntryCount: pendingUpload.logEntryCount,
            lastUpdated: pendingUpload.timestamp
        )
    }

    /**
     Computes the sparse Android row diff for the current snapshot.

     - Parameters:
       - snapshot: Current local reading-plan state projected into Android-shaped rows.
       - acceptedRowsByKey: Durable accepted-row identities used to detect baseline rows deleted locally.
       - existingEntriesByKey: Existing Android `LogEntry` baseline keyed by Android composite key.
       - fingerprintStore: Local fingerprint store used to compare current rows against the last uploaded baseline.
       - timestamp: Millisecond timestamp to assign to any emitted outbound `LogEntry` rows.
       - sourceDevice: Local source-device folder name that should own the outbound patch rows.
     - Returns: Sparse change set containing upserted rows, delete entries, and the updated local metadata baseline.
     - Side effects: none.
     - Throws: `RemoteSyncReadingPlanSnapshotError.missingProjectedFingerprint` when an exportable
       row has no hash; strict settings failures are surfaced by the enclosing preflight batch.
     */
    private func buildChangeSet(
        snapshot: RemoteSyncReadingPlanCurrentSnapshot,
        acceptedRowsByKey: [String: RemoteSyncReadingPlanAcceptedRowIdentity],
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore,
        pendingMutations: [String: RemoteSyncPendingMutation],
        timestamp: Int64,
        sourceDevice: String
    ) throws -> ChangeSet {
        var planRowsByKey: [String: RemoteSyncCurrentReadingPlanRow] = [:]
        var statusRowsByKey: [String: RemoteSyncCurrentReadingPlanStatusRow] = [:]
        var logEntries: [RemoteSyncLogEntry] = []
        var updatedEntriesByKey = existingEntriesByKey

        for (key, row) in snapshot.planRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard !snapshot.suppressedKeys.contains(key) else {
                continue
            }
            guard let currentFingerprint = snapshot.fingerprintsByKey[key] else {
                throw RemoteSyncReadingPlanSnapshotError.missingProjectedFingerprint(key)
            }
            let shouldUpload = shouldUploadCurrentRow(
                key: key,
                currentFingerprint: currentFingerprint,
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            )
            guard shouldUpload else {
                continue
            }

            let entry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: currentFingerprint,
                type: .upsert,
                category: .readingPlans,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                    tableName: "ReadingPlan",
                    entityID1: .blob(RemoteSyncReadingPlanSnapshotService.uuidBlob(row.id)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                )
            planRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.statusRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard !snapshot.suppressedKeys.contains(key) else {
                continue
            }
            guard let currentFingerprint = snapshot.fingerprintsByKey[key] else {
                throw RemoteSyncReadingPlanSnapshotError.missingProjectedFingerprint(key)
            }
            let shouldUpload = shouldUploadCurrentRow(
                key: key,
                currentFingerprint: currentFingerprint,
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            )
            guard shouldUpload else {
                continue
            }

            let entry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: currentFingerprint,
                type: .upsert,
                category: .readingPlans,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                    tableName: "ReadingPlanStatus",
                    entityID1: .blob(RemoteSyncReadingPlanSnapshotService.uuidBlob(row.id)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                )
            statusRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        let acceptedDeletionCandidates = acceptedRowsByKey.mapValues { identity in
            RemoteSyncLogEntry(
                tableName: identity.tableName,
                entityID1: identity.entityID1,
                entityID2: identity.entityID2,
                type: .upsert,
                lastUpdated: 0,
                sourceDevice: sourceDevice
            )
        }.merging(existingEntriesByKey) { _, logEntry in logEntry }

        for (key, entry) in acceptedDeletionCandidates.sorted(by: { $0.key < $1.key }) {
            guard !snapshot.suppressedKeys.contains(key) else {
                continue
            }
            guard snapshot.planRowsByKey[key] == nil,
                  snapshot.statusRowsByKey[key] == nil else {
                continue
            }
            guard entry.type != .delete || acceptedRowsByKey[key] != nil || pendingMutations[key] != nil else {
                continue
            }
            let deleteEntry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: nil,
                type: .delete,
                category: .readingPlans,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                    tableName: entry.tableName,
                    entityID1: entry.entityID1,
                    entityID2: entry.entityID2,
                    type: .delete,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                )
            logEntries.append(deleteEntry)
            updatedEntriesByKey[key] = deleteEntry
        }

        return ChangeSet(
            planRowsByKey: planRowsByKey,
            statusRowsByKey: statusRowsByKey,
            logEntries: logEntries.sorted(by: Self.logEntrySort),
            updatedEntriesByKey: updatedEntriesByKey
        )
    }

    /**
     Reads all preserved reading-plan log rows without dropping malformed metadata.

     - Parameters:
       - settingsStore: Store containing category-scoped log rows.
       - logEntryStore: Canonical log-key encoder for key/payload validation.
     - Returns: Complete decoded reading-plan log history.
     - Side effects: Reads settings rows inside the caller's atomic preflight.
     - Throws: `invalidStoredLogEntry` for malformed JSON or a key/payload mismatch.
     */
    private func strictLogEntries(
        settingsStore: SettingsStore,
        logEntryStore: RemoteSyncLogEntryStore
    ) throws -> [RemoteSyncLogEntry] {
        try settingsStore.entries(withPrefix: logEntryStore.prefix(for: .readingPlans)).map { entry in
            guard let data = entry.value.data(using: .utf8),
                  let logEntry = try? JSONDecoder().decode(RemoteSyncLogEntry.self, from: data),
                  entry.key == logEntryStore.key(for: .readingPlans, entry: logEntry) else {
                throw RemoteSyncReadingPlanPatchUploadError.invalidStoredLogEntry(entry.key)
            }
            return logEntry
        }
    }

    /**
     Replaces reading-plan log metadata with one fully encoded accepted generation.

     - Parameters:
       - entries: Exact accepted log rows from the durable outbox.
       - settingsStore: Store receiving the replacement.
     - Side effects: Removes prior category log rows and stages encoded replacements.
     - Throws: Rethrows JSON encoding failures; settings failures invalidate acceptance atomically.
     */
    private func replaceLogEntriesStrict(
        _ entries: [RemoteSyncLogEntry],
        settingsStore: SettingsStore
    ) throws {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        for entry in settingsStore.entries(withPrefix: logEntryStore.prefix(for: .readingPlans)) {
            settingsStore.remove(entry.key)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for entry in entries {
            let data = try encoder.encode(entry)
            settingsStore.setString(
                logEntryStore.key(for: .readingPlans, entry: entry),
                value: String(decoding: data, as: UTF8.self)
            )
        }
    }

    /**
     Validates that no preserved Android reading status disappeared through a soft decoder.

     - Parameter settingsStore: Store containing preserved reading status metadata.
     - Side effects: Reads status settings inside the atomic acceptance transaction.
     - Throws: `invalidStoredStatusMetadata` when any stored row cannot be projected.
     */
    private func validateStoredStatuses(settingsStore: SettingsStore) throws {
        let rawStatuses = settingsStore.entries(
            withPrefix: "remote_sync.readingplans.android_status"
        )
        let decodedStatuses = try RemoteSyncReadingPlanStatusStore(
            settingsStore: settingsStore
        ).allStatusesStrict()
        guard rawStatuses.count == decodedStatuses.count else {
            throw RemoteSyncReadingPlanSnapshotError.invalidStoredStatusMetadata
        }
    }

    /**
     Returns the highest Android patch filename currently present in this device folder.

     - Parameter deviceFolderID: Ready remote device-folder identifier.
     - Returns: Highest valid Android patch number, or zero when none exists.
     - Side effects: Performs one strict remote folder listing.
     - Throws: Rethrows cancellation and backend listing failures.
     */
    private func maximumRemotePatchNumber(deviceFolderID: String) async throws -> Int64 {
        try Task.checkCancellation()
        let files = try await adapter.listFiles(
            parentIDs: [deviceFolderID],
            name: nil,
            mimeType: nil,
            modifiedAtLeast: nil
        )
        try Task.checkCancellation()
        return files.compactMap {
            RemoteSyncPatchDiscoveryService.parsePatchFileName($0.name)?.patchNumber
        }.max() ?? 0
    }

    /**
     Conditionally merges generated remote ids into statuses that still exist after transport.

     - Parameters:
       - identities: Generated ids captured from the immutable upload generation.
       - statusStore: Current local Android-status metadata store.
     - Side effects: Adds an id only when the same logical status still exists without one; newer
       status JSON is preserved verbatim and deleted statuses are not recreated.
     - Throws: Rethrows status-envelope encoding failures; settings persistence failures invalidate
       the enclosing atomic acceptance batch.
     */
    private func mergeGeneratedStatusIdentities(
        _ identities: [GeneratedStatusIdentity],
        into statusStore: RemoteSyncReadingPlanStatusStore
    ) throws {
        for identity in identities {
            guard let current = try statusStore.storedStatusStrict(
                planCode: identity.planCode,
                dayNumber: identity.dayNumber
            ), current.remoteStatusID == nil else {
                continue
            }
            try statusStore.setStatusThrowing(
                RemoteSyncReadingPlanStatusStore.Status(
                    planCode: current.planCode,
                    dayNumber: current.dayNumber,
                    readingStatusJSON: current.readingStatusJSON,
                    remoteStatusID: identity.remoteStatusID
                )
            )
        }
    }

    /**
     Builds and durably records one exact archive before any remote transport begins.

     - Parameters:
       - generation: Atomic preflight generation to serialize.
       - modelContext: Clean context shared by the graph and settings store.
       - settingsStore: Local-only store receiving the durable pending-upload envelope.
     - Returns: Durable pending upload whose archive bytes and acceptance generation are fixed.
     - Side effects: Writes a temporary SQLite database, streams and fsyncs a bounded durable gzip
       archive, and commits one pending-upload setting before returning.
     - Throws: Rethrows cancellation, bounded-file, SQLite, compression, filesystem, encoding, and
       atomic settings failures. Partial or race-losing archives are removed.
     */
    private func persistPendingUpload(
        _ generation: UploadGeneration,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> PendingUpload {
        let databaseURL = temporaryURL(prefix: "remote-sync-readingplans-upload-", suffix: ".sqlite3")
        defer { try? fileManager.removeItem(at: databaseURL) }

        try writePatchDatabase(
            at: databaseURL,
            schemaVersion: generation.schemaVersion,
            changeSet: generation.changeSet
        )
        try fileManager.createDirectory(
            at: outboxDirectory,
            withIntermediateDirectories: true
        )
        let archiveFileName = "reading-plans-\(UUID().uuidString.lowercased()).sqlite3.gz"
        let archiveURL = outboxDirectory.appendingPathComponent(archiveFileName, isDirectory: false)
        var preserveArchive = false
        defer {
            if !preserveArchive {
                try? fileManager.removeItem(at: archiveURL)
            }
        }
        let archiveFingerprint = try RemoteSyncArchiveStagingService.gzipPatchDatabase(
            at: databaseURL,
            to: archiveURL
        )

        var pendingUpload = PendingUpload(
            formatVersion: Self.pendingUploadFormatVersion,
            deviceFolderID: generation.deviceFolderID,
            sourceDevice: generation.sourceDevice,
            patchNumber: generation.patchNumber,
            schemaVersion: generation.schemaVersion,
            timestamp: generation.timestamp,
            archiveFileName: archiveFileName,
            archiveSHA256: archiveFingerprint.sha256,
            archiveSize: archiveFingerprint.byteCount,
            expectedBaselineRevision: generation.expectedBaselineRevision,
            acceptedGeneration: generation.acceptedGeneration,
            updatedLogEntries: generation.updatedLogEntries,
            uploadedLogEntries: generation.changeSet.logEntries,
            generatedStatusIdentities: generation.generatedStatusIdentities,
            upsertedPlanCount: generation.changeSet.planRowsByKey.count,
            upsertedStatusCount: generation.changeSet.statusRowsByKey.count,
            deletedRowCount: generation.changeSet.deletedRowCount,
            logEntryCount: generation.changeSet.logEntries.count
        )
        pendingUpload.publicationIdentity = try RemoteSyncPublicationIdentity.patch(
            category: .readingPlans,
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

        var selectedUpload = pendingUpload
        try settingsStore.performAtomicBatch(in: modelContext) {
            if let existingUpload = try loadPendingUpload(settingsStore: settingsStore) {
                guard existingUpload.deviceFolderID == generation.deviceFolderID else {
                    throw RemoteSyncReadingPlanPatchUploadError.pendingUploadDestinationMismatch(
                        stored: existingUpload.deviceFolderID,
                        requested: generation.deviceFolderID
                    )
                }
                selectedUpload = existingUpload
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(pendingUpload)
                settingsStore.setString(
                    Self.pendingUploadKey,
                    value: String(decoding: data, as: UTF8.self)
                )
            }
        }
        preserveArchive = selectedUpload == pendingUpload
        return selectedUpload
    }

    /**
     Loads the durable pending-upload envelope when one exists.

     - Parameter settingsStore: Local-only store containing the envelope.
     - Returns: Decoded pending upload, or `nil` when no upload awaits acceptance.
     - Side effects: Reads one local setting row.
     - Throws: `RemoteSyncReadingPlanPatchUploadError.invalidPendingUpload` for malformed or future
       envelope data.
     */
    private func loadPendingUpload(settingsStore: SettingsStore) throws -> PendingUpload? {
        guard let rawValue = settingsStore.getString(Self.pendingUploadKey) else {
            return nil
        }
        guard let data = rawValue.data(using: .utf8),
              let pendingUpload = try? JSONDecoder().decode(PendingUpload.self, from: data),
              pendingUpload.formatVersion == Self.pendingUploadFormatVersion else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidPendingUpload
        }
        guard let publicationIdentity = pendingUpload.publicationIdentity else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidPendingUpload
        }
        var acceptancePayload = pendingUpload
        acceptancePayload.publicationIdentity = nil
        do {
            try publicationIdentity.validate(
                kind: .patch,
                category: .readingPlans,
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
            throw RemoteSyncReadingPlanPatchUploadError.invalidPendingUpload
        }
        return pendingUpload
    }

    /**
     Returns every operation count bound to one reading-plan publication.

     - Parameter pendingUpload: Identity-free or decoded reading-plan outbox envelope.
     - Returns: Nonempty count dictionary for plan rows, status rows, deletions, and log entries.
     - Side effects: none.
     - Failure modes: This deterministic projection cannot fail.
     */
    private static func publicationRowCounts(for pendingUpload: PendingUpload) -> [String: Int] {
        [
            "readingPlans": pendingUpload.upsertedPlanCount,
            "readingPlanStatuses": pendingUpload.upsertedStatusCount,
            "deletions": pendingUpload.deletedRowCount,
            "logEntries": pendingUpload.logEntryCount
        ]
    }

    /**
     Resolves the durable archive path for one pending retry.

     - Parameter pendingUpload: Envelope naming and hashing the expected archive.
     - Returns: Durable archive URL confined beneath the configured outbox directory.
     - Side effects: none.
     - Throws: `invalidPendingUpload` when the manifest contains a path rather than a basename.
       Byte existence, size, and digest are validated by `RemoteSyncRemotePatchReconciler`.
     */
    private func pendingArchiveURL(for pendingUpload: PendingUpload) throws -> URL {
        guard URL(fileURLWithPath: pendingUpload.archiveFileName).lastPathComponent
                == pendingUpload.archiveFileName else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidPendingUpload
        }
        return outboxDirectory.appendingPathComponent(
            pendingUpload.archiveFileName,
            isDirectory: false
        )
    }

    /**
     Deliberately discards a pending archive at a category destination-replacement boundary.

     Reset/re-adoption code must call this before changing the category folder. The accepted
     fingerprint/log baseline remains untouched, so current local rows stay dirty and the next
     upload builds a new patch for the replacement destination.

     - Parameter settingsStore: Local-only store containing any pending upload envelope.
     - Side effects: Atomically removes the pending envelope, then best-effort deletes its archive.
     - Throws: Rethrows malformed-envelope and atomic settings failures.
     */
    func discardPendingUploadForDestinationReplacement(
        settingsStore: SettingsStore
    ) throws {
        var archiveFileName: String?
        try settingsStore.performAtomicBatch {
            archiveFileName = try loadPendingUpload(settingsStore: settingsStore)?.archiveFileName
            settingsStore.remove(Self.pendingUploadKey)
        }
        if let archiveFileName {
            try? fileManager.removeItem(
                at: outboxDirectory.appendingPathComponent(archiveFileName, isDirectory: false)
            )
        }
    }

    /**
     Returns the production durable outbox directory for reading-plan patches.

     - Parameter fileManager: File manager used to locate Application Support.
     - Returns: Category-specific Application Support directory, falling back to a stable temporary
       subdirectory only when the platform exposes no Application Support location.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    static func defaultOutboxDirectory(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent("AndBible", isDirectory: true)
            .appendingPathComponent("RemoteSyncOutbox", isDirectory: true)
            .appendingPathComponent("ReadingPlans", isDirectory: true)
    }

    /**
     Returns whether one current snapshot row should be emitted as an outbound `UPSERT`.

     A missing fingerprint is treated as upload-needed. Silently accepting a current row without a
     hash can suppress a real edit, while a redundant Android upsert is idempotent and recoverable.

     - Parameters:
       - key: Android composite key for the row.
       - currentFingerprint: Current stable row fingerprint validated during strict projection.
       - existingEntriesByKey: Existing Android `LogEntry` baseline keyed by Android composite key.
       - fingerprintStore: Local fingerprint store used to read the prior baseline for the row.
     - Returns: `true` when the row should be emitted as an outbound upsert.
     - Side effects: reads preserved local fingerprint rows from `SettingsStore`.
     - Failure modes: This helper cannot fail.
     */
    private func shouldUploadCurrentRow(
        key: String,
        currentFingerprint: String,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore
    ) -> Bool {
        guard let existingEntry = existingEntriesByKey[key] else {
            if let existingFingerprint = fingerprintStore.fingerprint(
                forLogKey: key,
                category: .readingPlans
            ) {
                return existingFingerprint != currentFingerprint
            }
            return true
        }

        if existingEntry.type == .delete {
            return true
        }

        let existingFingerprint = fingerprintStore.fingerprint(
            for: .readingPlans,
            tableName: existingEntry.tableName,
            entityID1: existingEntry.entityID1,
            entityID2: existingEntry.entityID2
        )
        return existingFingerprint != currentFingerprint
    }

    /**
     Writes one sparse Android reading-plan patch database to the supplied SQLite URL.

     - Parameters:
       - url: Temporary SQLite file URL to create.
       - schemaVersion: SQLite user version that should be written to the patch database.
       - changeSet: Sparse current-row diff that should be serialized.
     - Side effects:
       - creates and writes a temporary SQLite database file
     - Failure modes:
       - throws `RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase` when the file cannot be opened for writing
       - rethrows SQLite execution failures from schema creation or row inserts
     */
    private func writePatchDatabase(
        at url: URL,
        schemaVersion: Int,
        changeSet: ChangeSet
    ) throws {
        guard schemaVersion == RemoteSyncAndroidDatabaseContract.schemaVersion(for: .readingPlans) else {
            throw RemoteSyncReadingPlanPatchUploadError.unsupportedSchemaVersion(schemaVersion)
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
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        try execute(
            RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: .readingPlans),
            in: database
        )

        for row in changeSet.planRowsByKey.values.sorted(by: { lhs, rhs in
            if lhs.planCode == rhs.planCode {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.planCode < rhs.planCode
        }) {
            try insertReadingPlanRow(row, in: database)
        }

        for row in changeSet.statusRowsByKey.values.sorted(by: { lhs, rhs in
            if lhs.planCode == rhs.planCode {
                if lhs.planDay == rhs.planDay {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.planDay < rhs.planDay
            }
            return lhs.planCode < rhs.planCode
        }) {
            try insertReadingPlanStatusRow(row, in: database)
        }

        for entry in changeSet.logEntries {
            try insertLogEntry(entry, in: database)
        }
    }

    /**
     Inserts one Android `ReadingPlan` row into the open patch database.

     - Parameters:
       - row: Android-shaped reading-plan row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `ReadingPlan` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertReadingPlanRow(
        _ row: RemoteSyncCurrentReadingPlanRow,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO ReadingPlan (planCode, planStartDate, planCurrentDay, id) VALUES (?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, row.planCode, -1, remoteSyncReadingPlanPatchUploadSQLiteTransient)
        sqlite3_bind_int64(statement, 2, row.planStartDateMillis)
        sqlite3_bind_int(
            statement,
            3,
            try RemoteSyncWireInteger.int32(
                exactly: row.planCurrentDay,
                field: "ReadingPlan.planCurrentDay"
            )
        )
        let blob = RemoteSyncReadingPlanSnapshotService.uuidBlob(row.id)
        let blobByteCount = try RemoteSyncWireInteger.int32(
            exactly: blob.count,
            field: "ReadingPlan.id.byteCount"
        )
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                4,
                bytes.baseAddress,
                blobByteCount,
                remoteSyncReadingPlanPatchUploadSQLiteTransient
            )
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `ReadingPlanStatus` row into the open patch database.

     - Parameters:
       - row: Android-shaped reading-plan-status row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `ReadingPlanStatus` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertReadingPlanStatusRow(
        _ row: RemoteSyncCurrentReadingPlanStatusRow,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO ReadingPlanStatus (planCode, planDay, readingStatus, id) VALUES (?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, row.planCode, -1, remoteSyncReadingPlanPatchUploadSQLiteTransient)
        sqlite3_bind_int(
            statement,
            2,
            try RemoteSyncWireInteger.int32(
                exactly: row.planDay,
                field: "ReadingPlanStatus.planDay"
            )
        )
        sqlite3_bind_text(statement, 3, row.readingStatusJSON, -1, remoteSyncReadingPlanPatchUploadSQLiteTransient)
        let blob = RemoteSyncReadingPlanSnapshotService.uuidBlob(row.id)
        let blobByteCount = try RemoteSyncWireInteger.int32(
            exactly: blob.count,
            field: "ReadingPlanStatus.id.byteCount"
        )
        _ = blob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                4,
                bytes.baseAddress,
                blobByteCount,
                remoteSyncReadingPlanPatchUploadSQLiteTransient
            )
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `LogEntry` row into the open patch database.

     - Parameters:
       - entry: Android log entry to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `LogEntry` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertLogEntry(
        _ entry: RemoteSyncLogEntry,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, entry.tableName, -1, remoteSyncReadingPlanPatchUploadSQLiteTransient)
        try Self.bindSQLiteValue(entry.entityID1, to: statement, index: 2)
        try Self.bindSQLiteValue(entry.entityID2, to: statement, index: 3)
        sqlite3_bind_text(statement, 4, entry.type.rawValue, -1, remoteSyncReadingPlanPatchUploadSQLiteTransient)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        sqlite3_bind_text(statement, 6, entry.sourceDevice, -1, remoteSyncReadingPlanPatchUploadSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Executes one schema or pragma SQL batch against the open patch database.

     - Parameters:
       - sql: SQL batch to execute.
       - database: Open SQLite database handle.
     - Side effects: mutates the open SQLite database schema or metadata.
     - Failure modes:
       - throws `RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase` when SQLite rejects the statement batch
     */
    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncReadingPlanPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Creates a new unique temporary URL beneath the configured temporary directory.

     - Parameters:
       - prefix: File-name prefix for the temporary file.
       - suffix: File-name suffix for the temporary file.
     - Returns: Temporary file URL that does not currently exist.
     - Side effects: none.
     - Failure modes: UUID path generation and URL composition are nonthrowing.
     */
    private func temporaryURL(prefix: String, suffix: String) -> URL {
        temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)\(suffix)")
    }

    /**
     Derives the Android source-device name from the ready device-folder identifier.

     - Parameter deviceFolderID: Remote device-folder identifier stored in the bootstrap state.
     - Returns: Final path component used as the Android source-device name.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func sourceDeviceName(from deviceFolderID: String) -> String {
        let trimmed = deviceFolderID.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? deviceFolderID
    }

    /**
     Binds one typed SQLite scalar value into a prepared statement parameter.

     - Parameters:
       - value: Typed SQLite value to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Throws: `RemoteSyncWireIntegerError.outOfRange` when a blob length cannot fit SQLite's
       signed 32-bit byte-count argument; SQLite bind status is checked by the caller's step.
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
            sqlite3_bind_text(
                statement,
                index,
                value.textValue ?? "",
                -1,
                remoteSyncReadingPlanPatchUploadSQLiteTransient
            )
        case .blob:
            let data = value.blobData ?? Data()
            let byteCount = try RemoteSyncWireInteger.int32(
                exactly: data.count,
                field: "LogEntry.entityId.byteCount"
            )
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    index,
                    bytes.baseAddress,
                    byteCount,
                    remoteSyncReadingPlanPatchUploadSQLiteTransient
                )
            }
        }
    }

    /**
     Decodes one UUID from a typed SQLite scalar when the payload is a 16-byte BLOB.

     - Parameter value: Typed SQLite scalar value to decode.
     - Returns: UUID represented by the blob, or `nil` when the value is not a 16-byte blob.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func uuid(from value: RemoteSyncSQLiteValue) -> UUID? {
        guard value.kind == .blob,
              let data = value.blobData,
              data.count == 16 else {
            return nil
        }
        let bytes = Array(data)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /**
     Sorts Android log entries into a deterministic patch-write order.

     - Parameters:
       - lhs: First log entry to compare.
       - rhs: Second log entry to compare.
     - Returns: `true` when `lhs` should appear before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
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

    /**
     Builds a deterministic string key used only for local ordering of SQLite value payloads.

     - Parameter value: Typed SQLite scalar value.
     - Returns: Canonical string preserving storage kind and payload.
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
