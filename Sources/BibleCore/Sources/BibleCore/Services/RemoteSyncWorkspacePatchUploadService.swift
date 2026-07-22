// RemoteSyncWorkspacePatchUploadService.swift — Android-shaped outbound workspace patch creation and upload

import Foundation
import SQLite3
import SwiftData

private let remoteSyncWorkspacePatchUploadSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while exporting and uploading an outbound Android workspace patch.
 */
public enum RemoteSyncWorkspacePatchUploadError: Error, Equatable {
    /// The category is not ready for upload because no remote device folder identifier is known locally.
    case missingDeviceFolderID

    /// One current local workspace value could not be serialized into Android's JSON-backed SQLite columns.
    case jsonEncodingFailed(field: String)

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
}

/**
 Summary of one successful outbound workspace patch upload.

 Android's workspace patch stream only mutates three content tables: `Workspace`, `Window`, and
 `PageManager`. This report preserves the per-table row counts so higher layers can confirm the
 upload serialized the expected mix of workspace shell, window layout, and page-state mutations.
 */
public struct RemoteSyncWorkspacePatchUploadReport: Sendable, Equatable {
    /// Remote file metadata returned by the backend after upload succeeded.
    public let uploadedFile: RemoteSyncFile

    /// Monotonic patch number assigned within the current device folder.
    public let patchNumber: Int64

    /// Number of `Workspace` rows written into the patch database.
    public let upsertedWorkspaceCount: Int

    /// Number of `Window` rows written into the patch database.
    public let upsertedWindowCount: Int

    /// Number of `PageManager` rows written into the patch database.
    public let upsertedPageManagerCount: Int

    /// Number of `WorkspaceLabelOverride` rows written into the patch database.
    public let upsertedLabelOverrideCount: Int

    /// Number of `GlobalTextDisplaySettings` rows written into the patch database.
    public let upsertedGlobalTextDisplaySettingsCount: Int

    /// Number of `DELETE` log entries emitted for rows removed locally.
    public let deletedRowCount: Int

    /// Total number of Android `LogEntry` rows written into the patch database.
    public let logEntryCount: Int

    /// Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
    public let lastUpdated: Int64

    /**
     Creates one outbound workspace patch-upload summary.

     - Parameters:
       - uploadedFile: Remote file metadata returned by the backend after upload succeeded.
       - patchNumber: Monotonic patch number assigned within the current device folder.
       - upsertedWorkspaceCount: Number of `Workspace` rows written into the patch database.
       - upsertedWindowCount: Number of `Window` rows written into the patch database.
       - upsertedPageManagerCount: Number of `PageManager` rows written into the patch database.
       - deletedRowCount: Number of `DELETE` log entries emitted for rows removed locally.
       - logEntryCount: Total number of Android `LogEntry` rows written into the patch database.
       - lastUpdated: Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        uploadedFile: RemoteSyncFile,
        patchNumber: Int64,
        upsertedWorkspaceCount: Int,
        upsertedWindowCount: Int,
        upsertedPageManagerCount: Int,
        upsertedLabelOverrideCount: Int = 0,
        upsertedGlobalTextDisplaySettingsCount: Int = 0,
        deletedRowCount: Int,
        logEntryCount: Int,
        lastUpdated: Int64
    ) {
        self.uploadedFile = uploadedFile
        self.patchNumber = patchNumber
        self.upsertedWorkspaceCount = upsertedWorkspaceCount
        self.upsertedWindowCount = upsertedWindowCount
        self.upsertedPageManagerCount = upsertedPageManagerCount
        self.upsertedLabelOverrideCount = upsertedLabelOverrideCount
        self.upsertedGlobalTextDisplaySettingsCount = upsertedGlobalTextDisplaySettingsCount
        self.deletedRowCount = deletedRowCount
        self.logEntryCount = logEntryCount
        self.lastUpdated = lastUpdated
    }
}

/**
 Creates Android-shaped sparse workspace patch databases and uploads them to the active backend.

 The service mirrors the outbound half of Android's incremental workspace sync contract:
 - project the current local SwiftData workspace graph into Android `Workspace`, `Window`, and
   `PageManager` rows
 - compare those rows against the preserved Android `LogEntry` baseline and local fingerprint store
 - emit sparse `UPSERT` and `DELETE` `LogEntry` rows only for changed Android row keys
 - write an Android-compatible SQLite patch database and gzip archive
 - upload `<patchNumber>.<schemaVersion>.sqlite3.gz` into the ready device folder
 - advance local `LogEntry`, `lastPatchWritten`, patch-status, and fingerprint baselines only after
   upload succeeds

 Android's workspace incremental contract does not include `HistoryItem` rows. This exporter
 therefore leaves preserved history metadata untouched and only mutates the three supported tables
 when building outbound patches.

 Data dependencies:
 - `RemoteSyncAdapting` performs the remote file upload
 - `RemoteSyncWorkspaceSnapshotService` projects live SwiftData and local-only workspace fidelity
   state into Android-shaped rows
 - `RemoteSyncLogEntryStore` provides the Android conflict baseline and is updated after success
 - `RemoteSyncPatchStatusStore` tracks the highest uploaded patch number for the local device folder
 - `RemoteSyncStateStore` persists Android-aligned `lastPatchWritten` bookkeeping
 - `RemoteSyncArchiveStagingService` provides gzip compression for the generated SQLite patch file

 Side effects:
 - reads live workspace-category state from SwiftData and local-only fidelity settings
 - creates and removes temporary SQLite and gzip files beneath the configured temporary directory
 - uploads a gzip patch archive into the ready device folder
 - rewrites local Android `LogEntry` and fingerprint baselines for `.workspaces` after success
 - appends one local patch status row and updates `lastPatchWritten`

 Failure modes:
 - throws `RemoteSyncWorkspacePatchUploadError.missingDeviceFolderID` when the category is not bootstrapped for outbound upload
 - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when local workspace settings cannot be serialized into Android JSON-backed columns
 - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when the temporary SQLite patch file cannot be created
 - rethrows local filesystem write failures while building the temporary SQLite or gzip files
 - rethrows backend transport or local-file read failures from `RemoteSyncAdapting.upload`
 - rethrows bounded file-to-file gzip failures from `RemoteSyncArchiveStagingService`

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement rules of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncWorkspacePatchUploadService {
    /**
     Durable metadata for one exact workspace patch archive awaiting local acceptance.

     The file-backed archive survives process termination, while this envelope carries every local
     acceptance input so retry does not reproject concurrent workspace edits.
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
        let acceptedGeneration: RemoteSyncWorkspaceAcceptedGeneration
        let updatedLogEntries: [RemoteSyncLogEntry]
        let uploadedLogEntries: [RemoteSyncLogEntry]?
        let upsertedWorkspaceCount: Int
        let upsertedWindowCount: Int
        let upsertedPageManagerCount: Int
        let upsertedLabelOverrideCount: Int?
        let upsertedGlobalTextDisplaySettingsCount: Int?
        let deletedRowCount: Int
        let logEntryCount: Int
        var publicationIdentity: RemoteSyncPublicationIdentity? = nil

        /// Android-compatible archive name derived from the durable patch identity.
        var patchFileName: String {
            "\(patchNumber).\(schemaVersion).sqlite3.gz"
        }
    }

    /**
     In-memory workspace generation used only until its archive and acceptance envelope are durable.
     */
    private struct UploadGeneration {
        let deviceFolderID: String
        let sourceDevice: String
        let patchNumber: Int64
        let schemaVersion: Int
        let timestamp: Int64
        let expectedBaselineRevision: Int64
        let acceptedGeneration: RemoteSyncWorkspaceAcceptedGeneration
        let updatedLogEntries: [RemoteSyncLogEntry]
        let changeSet: ChangeSet
    }

    /**
     Result of the single atomic workspace preflight read boundary.
     */
    private enum PreflightResult {
        case noChanges
        case pending(PendingUpload)
        case generation(UploadGeneration)
    }

    private struct ChangeSet {
        let workspaceRowsByKey: [String: RemoteSyncCurrentWorkspaceRow]
        let windowRowsByKey: [String: RemoteSyncCurrentWorkspaceWindowRow]
        let pageManagerRowsByKey: [String: RemoteSyncCurrentWorkspacePageManagerRow]
        let labelOverrideRowsByKey: [String: RemoteSyncCurrentWorkspaceLabelOverrideRow]
        let globalTextDisplayRowsByKey: [String: RemoteSyncCurrentGlobalTextDisplaySettingsRow]
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

    private struct AndroidRecentLabelPayload: Encodable {
        let labelId: String
        let lastAccess: Int64
    }

    private static let supportedTableNames: Set<String> = ["Workspace", "Window", "PageManager"]

    private let adapter: any RemoteSyncAdapting
    private let remotePatchReconciler: RemoteSyncRemotePatchReconciler
    private let snapshotService: RemoteSyncWorkspaceSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let outboxDirectory: URL
    private let nowProvider: () -> Int64
    private let jsonEncoder: JSONEncoder
    private let finalAcceptanceCheckpoint: () throws -> Void

    /// Local-only settings key holding the pending workspace upload envelope.
    static let pendingUploadKey = "remote_sync.workspaces.pending_upload"

    /// Current durable envelope format.
    private static let pendingUploadFormatVersion = 2

    /**
     Creates a workspace patch upload service for one remote backend.

     - Parameters:
       - adapter: Remote backend adapter used for the final archive upload.
       - snapshotService: Snapshot service used to project current local workspace state into Android rows.
       - fileManager: File manager used for temporary-file cleanup.
       - temporaryDirectory: Scratch directory for temporary SQLite and gzip files. Defaults to the process temporary directory.
       - nowProvider: Millisecond clock used for Android `LogEntry.lastUpdated` and local `lastPatchWritten`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public convenience init(
        adapter: any RemoteSyncAdapting,
        snapshotService: RemoteSyncWorkspaceSnapshotService = RemoteSyncWorkspaceSnapshotService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        outboxDirectory: URL? = nil,
        nowProvider: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000.0)
        }
    ) {
        self.init(
            adapter: adapter,
            snapshotService: snapshotService,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory,
            outboxDirectory: outboxDirectory,
            nowProvider: nowProvider,
            finalAcceptanceCheckpoint: {}
        )
    }

    /**
     Creates a workspace uploader with an internal final-acceptance checkpoint.

     - Parameters:
       - adapter: Remote backend adapter used for archive upload.
       - snapshotService: Strict graph projector and accepted-baseline publisher.
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
        snapshotService: RemoteSyncWorkspaceSnapshotService = RemoteSyncWorkspaceSnapshotService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        outboxDirectory: URL? = nil,
        nowProvider: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000.0)
        },
        finalAcceptanceCheckpoint: @escaping () throws -> Void
    ) {
        self.adapter = adapter
        self.remotePatchReconciler = RemoteSyncRemotePatchReconciler(adapter: adapter)
        self.snapshotService = snapshotService
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.outboxDirectory = outboxDirectory ?? Self.defaultOutboxDirectory(fileManager: fileManager)
        self.nowProvider = nowProvider
        self.finalAcceptanceCheckpoint = finalAcceptanceCheckpoint

        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.sortedKeys]
        self.jsonEncoder = jsonEncoder
    }

    /**
     Builds and uploads the next sparse workspace patch when local state differs from the baseline.

     The service is intentionally conservative about missing fingerprint baselines. When it finds a
     preserved Android `LogEntry` row for one supported workspace table with no matching local
     fingerprint, it assumes the row came from a pre-fingerprint restore or replay and refreshes
     the baseline without uploading a patch. That avoids fabricating large false-positive uploads
     the first time outbound diffing is enabled on an existing install.

     Unsupported workspace metadata tables, such as `HistoryItem`, are preserved in the local
     `LogEntry` store but are excluded from outbound diffing because Android never mutates them via
     incremental workspace patches.

     - Parameters:
       - bootstrapState: Ready bootstrap state for the workspace category.
       - modelContext: SwiftData context that owns the live workspace graph.
       - settingsStore: Local-only settings store backing preserved Android sync metadata.
       - schemaVersion: Schema version to encode into the generated patch filename and SQLite user version.
     - Returns: Upload summary when a sparse patch was emitted, or `nil` when no local changes need upload.
     - Side effects:
       - may refresh the fingerprint baseline without uploading when the service encounters historical rows with no stored fingerprints
       - creates and removes temporary SQLite and gzip files
       - uploads a gzip patch archive when local changes exist
       - rewrites local `LogEntry`, patch-status, progress, and fingerprint state after successful upload
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.missingDeviceFolderID` when `bootstrapState.deviceFolderID` is missing or empty
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when local settings cannot be serialized into Android row payloads
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when the temporary SQLite patch file cannot be opened
       - rethrows filesystem, compression, and backend upload failures
     */
    public func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = RemoteSyncCategory.workspaces.currentSchemaVersion
    ) async throws -> RemoteSyncWorkspacePatchUploadReport? {
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncWorkspacePatchUploadError.missingDeviceFolderID
        }

        if let resumed = try await resumePendingUploadIfPresent(
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore
        ) {
            return resumed
        }

        let hasPendingMutations = try settingsStore.performAtomicBatch(in: modelContext) {
            let mutationJournal = RemoteSyncMutationJournalService(nowProvider: nowProvider)
            try mutationJournal.recordLocalChanges(
                for: .workspaces,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            return try !mutationJournal.pendingMutations(
                for: .workspaces,
                settingsStore: settingsStore
            ).isEmpty
        }
        guard hasPendingMutations else {
            return nil
        }

        let sourceDevice = Self.sourceDeviceName(from: deviceFolderID)
        let remotePatchNumber = try await maximumRemotePatchNumber(deviceFolderID: deviceFolderID)
        let preflight = try settingsStore.performAtomicBatch(in: modelContext) {
            try Task.checkCancellation()
            if let pendingUpload = try loadPendingUpload(settingsStore: settingsStore) {
                guard pendingUpload.deviceFolderID == deviceFolderID else {
                    throw RemoteSyncWorkspacePatchUploadError.pendingUploadDestinationMismatch(
                        stored: pendingUpload.deviceFolderID,
                        requested: deviceFolderID
                    )
                }
                return PreflightResult.pending(pendingUpload)
            }

            let wallClockTimestamp = nowProvider()
            let mutationJournal = RemoteSyncMutationJournalService(nowProvider: nowProvider)
            try mutationJournal.recordLocalChanges(
                for: .workspaces,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            let pendingMutations = try mutationJournal.pendingMutations(
                for: .workspaces,
                settingsStore: settingsStore
            )
            let snapshot = try snapshotService.snapshotCurrentStateStrict(
                modelContext: modelContext,
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
            let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
            let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
            let patchStatuses = try patchStatusStore.statusesStrict(for: .workspaces)
            let existingEntriesByKey = Dictionary(
                uniqueKeysWithValues: try strictLogEntries(
                    settingsStore: settingsStore,
                    logEntryStore: logEntryStore
                ).map {
                    (logEntryStore.key(for: .workspaces, entry: $0), $0)
                }
            )
            let progressState = RemoteSyncStateStore(settingsStore: settingsStore)
                .progressState(for: .workspaces)
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
                throw RemoteSyncWorkspacePatchUploadError.patchNumberExhausted
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
     Resumes an already-durable workspace generation without projecting or creating new work.

     Synchronization calls this before inbound replay. Destination mismatches remain fail-closed
     until an explicit category reset/replacement discards the stale outbox.

     - Parameters:
       - bootstrapState: Ready bootstrap state naming the current device folder.
       - modelContext: Clean context shared by workspace graph and settings.
       - settingsStore: Local store containing any durable pending envelope.
     - Returns: Accepted upload report, or `nil` when no pending generation exists.
     - Side effects: May reconcile exact remote bytes and atomically accept one durable generation.
     - Throws: Rethrows destination, outbox, transport, cancellation, CAS, and acceptance failures.
     */
    public func resumePendingUploadIfPresent(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncWorkspacePatchUploadReport? {
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncWorkspacePatchUploadError.missingDeviceFolderID
        }
        let pendingUpload = try settingsStore.performAtomicBatch(in: modelContext) {
            try Task.checkCancellation()
            return try loadPendingUpload(settingsStore: settingsStore)
        }
        guard let pendingUpload else {
            return nil
        }
        guard pendingUpload.deviceFolderID == deviceFolderID else {
            throw RemoteSyncWorkspacePatchUploadError.pendingUploadDestinationMismatch(
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
     Reconciles one durable workspace archive and publishes its exact local acceptance generation.

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
    ) async throws -> RemoteSyncWorkspacePatchUploadReport {
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
                throw RemoteSyncWorkspacePatchUploadError.invalidPendingUpload
            }
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
                category: .workspaces,
                settingsStore: settingsStore
            )
            try RemoteSyncPatchStatusStore(settingsStore: settingsStore).addStatusStrict(
                RemoteSyncPatchStatus(
                    sourceDevice: pendingUpload.sourceDevice,
                    patchNumber: pendingUpload.patchNumber,
                    sizeBytes: uploadedFile.size,
                    appliedDate: uploadedFile.timestamp
                ),
                for: .workspaces
            )
            let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
            settingsStore.setString(
                stateStore.scopedKey("lastPatchWritten", category: .workspaces),
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
        return RemoteSyncWorkspacePatchUploadReport(
            uploadedFile: uploadedFile,
            patchNumber: pendingUpload.patchNumber,
            upsertedWorkspaceCount: pendingUpload.upsertedWorkspaceCount,
            upsertedWindowCount: pendingUpload.upsertedWindowCount,
            upsertedPageManagerCount: pendingUpload.upsertedPageManagerCount,
            upsertedLabelOverrideCount: pendingUpload.upsertedLabelOverrideCount ?? 0,
            upsertedGlobalTextDisplaySettingsCount:
                pendingUpload.upsertedGlobalTextDisplaySettingsCount ?? 0,
            deletedRowCount: pendingUpload.deletedRowCount,
            logEntryCount: pendingUpload.logEntryCount,
            lastUpdated: pendingUpload.timestamp
        )
    }

    /**
     Computes the sparse Android row diff for the current workspace snapshot.

     - Parameters:
       - snapshot: Current local workspace state projected into Android-shaped rows.
       - acceptedRowsByKey: Durable accepted-row identities used to detect baseline rows deleted locally.
       - existingEntriesByKey: Existing Android `LogEntry` baseline keyed by Android composite key.
       - fingerprintStore: Local fingerprint store used to compare current rows against the last uploaded baseline.
       - timestamp: Millisecond timestamp to assign to any emitted outbound `LogEntry` rows.
       - sourceDevice: Local source-device folder name that should own the outbound patch rows.
     - Returns: Sparse change set containing upserted rows, delete entries, and the updated local metadata baseline.
     - Side effects: none.
     - Throws: `RemoteSyncWorkspaceSnapshotError.missingProjectedFingerprint` when an exportable
       row has no hash; strict settings failures are surfaced by the enclosing preflight batch.
     */
    private func buildChangeSet(
        snapshot: RemoteSyncWorkspaceCurrentSnapshot,
        acceptedRowsByKey: [String: RemoteSyncWorkspaceAcceptedRowIdentity],
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore,
        pendingMutations: [String: RemoteSyncPendingMutation],
        timestamp: Int64,
        sourceDevice: String
    ) throws -> ChangeSet {
        var workspaceRowsByKey: [String: RemoteSyncCurrentWorkspaceRow] = [:]
        var windowRowsByKey: [String: RemoteSyncCurrentWorkspaceWindowRow] = [:]
        var pageManagerRowsByKey: [String: RemoteSyncCurrentWorkspacePageManagerRow] = [:]
        var labelOverrideRowsByKey: [String: RemoteSyncCurrentWorkspaceLabelOverrideRow] = [:]
        var globalTextDisplayRowsByKey: [String: RemoteSyncCurrentGlobalTextDisplaySettingsRow] = [:]
        var logEntries: [RemoteSyncLogEntry] = []
        var updatedEntriesByKey = existingEntriesByKey

        for (key, row) in snapshot.workspaceRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard !snapshot.suppressedKeys.contains(key) else {
                continue
            }
            guard let currentFingerprint = snapshot.fingerprintsByKey[key] else {
                throw RemoteSyncWorkspaceSnapshotError.missingProjectedFingerprint(key)
            }
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: currentFingerprint,
                hasPendingMutation: pendingMutations[key] != nil,
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: currentFingerprint,
                type: .upsert,
                category: .workspaces,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                    tableName: "Workspace",
                    entityID1: .blob(RemoteSyncWorkspaceSnapshotService.uuidBlob(row.id)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                )
            workspaceRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.windowRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard !snapshot.suppressedKeys.contains(key) else {
                continue
            }
            guard let currentFingerprint = snapshot.fingerprintsByKey[key] else {
                throw RemoteSyncWorkspaceSnapshotError.missingProjectedFingerprint(key)
            }
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: currentFingerprint,
                hasPendingMutation: pendingMutations[key] != nil,
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: currentFingerprint,
                type: .upsert,
                category: .workspaces,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                    tableName: "Window",
                    entityID1: .blob(RemoteSyncWorkspaceSnapshotService.uuidBlob(row.id)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                )
            windowRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.pageManagerRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard !snapshot.suppressedKeys.contains(key) else {
                continue
            }
            guard let currentFingerprint = snapshot.fingerprintsByKey[key] else {
                throw RemoteSyncWorkspaceSnapshotError.missingProjectedFingerprint(key)
            }
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: currentFingerprint,
                hasPendingMutation: pendingMutations[key] != nil,
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: currentFingerprint,
                type: .upsert,
                category: .workspaces,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                    tableName: "PageManager",
                    entityID1: .blob(RemoteSyncWorkspaceSnapshotService.uuidBlob(row.windowID)),
                    entityID2: .text(""),
                    type: .upsert,
                    lastUpdated: timestamp,
                    sourceDevice: sourceDevice
                )
            pageManagerRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.labelOverrideRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard !snapshot.suppressedKeys.contains(key) else { continue }
            guard let currentFingerprint = snapshot.fingerprintsByKey[key] else {
                throw RemoteSyncWorkspaceSnapshotError.missingProjectedFingerprint(key)
            }
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: currentFingerprint,
                hasPendingMutation: pendingMutations[key] != nil,
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: currentFingerprint,
                type: .upsert,
                category: .workspaces,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                tableName: "WorkspaceLabelOverride",
                entityID1: .blob(RemoteSyncWorkspaceSnapshotService.uuidBlob(row.workspaceID)),
                entityID2: .blob(RemoteSyncWorkspaceSnapshotService.uuidBlob(row.labelID)),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            labelOverrideRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.globalTextDisplayRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard !snapshot.suppressedKeys.contains(key) else { continue }
            guard let currentFingerprint = snapshot.fingerprintsByKey[key] else {
                throw RemoteSyncWorkspaceSnapshotError.missingProjectedFingerprint(key)
            }
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: currentFingerprint,
                hasPendingMutation: pendingMutations[key] != nil,
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: currentFingerprint,
                type: .upsert,
                category: .workspaces,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                tableName: "GlobalTextDisplaySettings",
                entityID1: .blob(RemoteSyncWorkspaceSnapshotService.uuidBlob(row.id)),
                entityID2: .text(""),
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
            globalTextDisplayRowsByKey[key] = row
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
            guard Self.supportedTableNames.contains(entry.tableName) else {
                continue
            }
            guard !currentRowExists(forKey: key, in: snapshot) else {
                continue
            }
            guard entry.type != .delete || acceptedRowsByKey[key] != nil || pendingMutations[key] != nil else {
                continue
            }
            let deleteEntry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: nil,
                type: .delete,
                category: .workspaces,
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
            workspaceRowsByKey: workspaceRowsByKey,
            windowRowsByKey: windowRowsByKey,
            pageManagerRowsByKey: pageManagerRowsByKey,
            labelOverrideRowsByKey: labelOverrideRowsByKey,
            globalTextDisplayRowsByKey: globalTextDisplayRowsByKey,
            logEntries: logEntries.sorted(by: Self.logEntrySort),
            updatedEntriesByKey: updatedEntriesByKey
        )
    }

    /**
     Reads every preserved workspace log row without dropping malformed metadata.

     - Parameters:
       - settingsStore: Store containing category-scoped log rows.
       - logEntryStore: Canonical log-key encoder for key/payload validation.
     - Returns: Complete decoded workspace log history.
     - Side effects: Reads settings rows inside the caller's atomic preflight.
     - Throws: `invalidStoredLogEntry` for malformed JSON or a key/payload mismatch.
     */
    private func strictLogEntries(
        settingsStore: SettingsStore,
        logEntryStore: RemoteSyncLogEntryStore
    ) throws -> [RemoteSyncLogEntry] {
        try settingsStore.entries(withPrefix: logEntryStore.prefix(for: .workspaces)).map { entry in
            guard let data = entry.value.data(using: .utf8),
                  let logEntry = try? JSONDecoder().decode(RemoteSyncLogEntry.self, from: data),
                  entry.key == logEntryStore.key(for: .workspaces, entry: logEntry) else {
                throw RemoteSyncWorkspacePatchUploadError.invalidStoredLogEntry(entry.key)
            }
            return logEntry
        }
    }

    /**
     Replaces workspace log metadata with one fully encoded accepted generation.

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
        for entry in settingsStore.entries(withPrefix: logEntryStore.prefix(for: .workspaces)) {
            settingsStore.remove(entry.key)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for entry in entries {
            let data = try encoder.encode(entry)
            settingsStore.setString(
                logEntryStore.key(for: .workspaces, entry: entry),
                value: String(decoding: data, as: UTF8.self)
            )
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
     Builds and durably records one exact workspace archive before remote transport begins.

     - Parameters:
       - generation: Atomic preflight generation to serialize.
       - modelContext: Clean context shared by the graph and settings store.
       - settingsStore: Local-only store receiving the durable pending-upload envelope.
     - Returns: Durable pending upload whose archive bytes and acceptance generation are fixed.
     - Side effects: Writes a temporary SQLite database, atomically writes a durable gzip archive,
       and commits one pending-upload setting before returning.
     - Throws: Rethrows SQLite, JSON, compression, filesystem, encoding, and atomic settings failures.
     */
    private func persistPendingUpload(
        _ generation: UploadGeneration,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> PendingUpload {
        let databaseURL = temporaryURL(prefix: "remote-sync-workspaces-upload-", suffix: ".sqlite3")
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
        let archiveFileName = "workspaces-\(UUID().uuidString.lowercased()).sqlite3.gz"
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
            upsertedWorkspaceCount: generation.changeSet.workspaceRowsByKey.count,
            upsertedWindowCount: generation.changeSet.windowRowsByKey.count,
            upsertedPageManagerCount: generation.changeSet.pageManagerRowsByKey.count,
            upsertedLabelOverrideCount: generation.changeSet.labelOverrideRowsByKey.count,
            upsertedGlobalTextDisplaySettingsCount:
                generation.changeSet.globalTextDisplayRowsByKey.count,
            deletedRowCount: generation.changeSet.deletedRowCount,
            logEntryCount: generation.changeSet.logEntries.count
        )
        pendingUpload.publicationIdentity = try RemoteSyncPublicationIdentity.patch(
            category: .workspaces,
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
        do {
            try settingsStore.performAtomicBatch(in: modelContext) {
                if let existingUpload = try loadPendingUpload(settingsStore: settingsStore) {
                    guard existingUpload.deviceFolderID == generation.deviceFolderID else {
                        throw RemoteSyncWorkspacePatchUploadError.pendingUploadDestinationMismatch(
                            stored: existingUpload.deviceFolderID,
                            requested: generation.deviceFolderID
                        )
                    }
                    selectedUpload = existingUpload
                } else {
                    let data = try jsonEncoder.encode(pendingUpload)
                    settingsStore.setString(
                        Self.pendingUploadKey,
                        value: String(decoding: data, as: UTF8.self)
                    )
                }
            }
        } catch {
            throw error
        }
        if selectedUpload == pendingUpload {
            keepsArchive = true
        }
        return selectedUpload
    }

    /**
     Loads the durable pending workspace-upload envelope when one exists.

     - Parameter settingsStore: Local-only store containing the envelope.
     - Returns: Decoded pending upload, or `nil` when no upload awaits acceptance.
     - Side effects: Reads one local setting row.
     - Throws: `RemoteSyncWorkspacePatchUploadError.invalidPendingUpload` for malformed or future
       envelope data.
     */
    private func loadPendingUpload(settingsStore: SettingsStore) throws -> PendingUpload? {
        guard let rawValue = settingsStore.getString(Self.pendingUploadKey) else {
            return nil
        }
        guard let data = rawValue.data(using: .utf8),
              let pendingUpload = try? JSONDecoder().decode(PendingUpload.self, from: data),
              pendingUpload.formatVersion == Self.pendingUploadFormatVersion else {
            throw RemoteSyncWorkspacePatchUploadError.invalidPendingUpload
        }
        guard let publicationIdentity = pendingUpload.publicationIdentity else {
            throw RemoteSyncWorkspacePatchUploadError.invalidPendingUpload
        }
        var acceptancePayload = pendingUpload
        acceptancePayload.publicationIdentity = nil
        do {
            try publicationIdentity.validate(
                kind: .patch,
                category: .workspaces,
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
            throw RemoteSyncWorkspacePatchUploadError.invalidPendingUpload
        }
        return pendingUpload
    }

    /**
     Returns every operation count bound to one workspace publication.

     - Parameter pendingUpload: Identity-free or decoded workspace outbox envelope.
     - Returns: Nonempty count dictionary covering every Android workspace Room row family.
     - Side effects: none.
     - Failure modes: This deterministic projection cannot fail.
     */
    private static func publicationRowCounts(for pendingUpload: PendingUpload) -> [String: Int] {
        [
            "workspaces": pendingUpload.upsertedWorkspaceCount,
            "windows": pendingUpload.upsertedWindowCount,
            "pageManagers": pendingUpload.upsertedPageManagerCount,
            "labelOverrides": pendingUpload.upsertedLabelOverrideCount ?? 0,
            "globalTextDisplaySettings": pendingUpload.upsertedGlobalTextDisplaySettingsCount ?? 0,
            "deletions": pendingUpload.deletedRowCount,
            "logEntries": pendingUpload.logEntryCount
        ]
    }

    /**
     Resolves the durable archive path for one pending workspace retry.

     - Parameter pendingUpload: Envelope naming and hashing the expected archive.
     - Returns: Durable archive URL confined beneath the configured outbox directory.
     - Side effects: none.
     - Throws: `invalidPendingUpload` when the manifest contains a path rather than a basename.
       Byte existence, size, and digest are validated by `RemoteSyncRemotePatchReconciler`.
     */
    private func pendingArchiveURL(for pendingUpload: PendingUpload) throws -> URL {
        guard URL(fileURLWithPath: pendingUpload.archiveFileName).lastPathComponent
                == pendingUpload.archiveFileName else {
            throw RemoteSyncWorkspacePatchUploadError.invalidPendingUpload
        }
        return outboxDirectory.appendingPathComponent(
            pendingUpload.archiveFileName,
            isDirectory: false
        )
    }

    /**
     Deliberately discards a pending archive at a category destination-replacement boundary.

     Reset/re-adoption code must call this before changing the workspace category folder. The
     accepted fingerprint/log baseline remains untouched, so current rows stay dirty and the next
     upload builds a fresh patch for the replacement destination.

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
     Returns the production durable outbox directory for workspace patches.

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
            .appendingPathComponent("Workspaces", isDirectory: true)
    }

    /**
     Returns whether one current snapshot row should be emitted as an outbound `UPSERT`.

     A missing fingerprint is treated as upload-needed. Silently accepting a current row without a
     hash can suppress a real edit, while a redundant Android upsert is idempotent and recoverable.

     - Parameters:
       - key: Android composite key for the row.
       - currentFingerprint: Current stable row fingerprint validated during strict projection.
       - hasPendingMutation: Whether mutation-time journaling recorded this exact row as dirty.
       - existingEntriesByKey: Existing Android `LogEntry` baseline keyed by Android composite key.
       - fingerprintStore: Local fingerprint store used to read the prior baseline for the row.
     - Returns: `true` when the row should be emitted as an outbound upsert.
     - Side effects: reads preserved local fingerprint rows from `SettingsStore`.
     - Failure modes: This helper cannot fail.
     */
    private func shouldUploadCurrentRow(
        key: String,
        currentFingerprint: String,
        hasPendingMutation: Bool,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        fingerprintStore: RemoteSyncRowFingerprintStore
    ) -> Bool {
        if hasPendingMutation {
            return true
        }
        guard let existingEntry = existingEntriesByKey[key] else {
            if let existingFingerprint = fingerprintStore.fingerprint(
                forLogKey: key,
                category: .workspaces
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
            for: .workspaces,
            tableName: existingEntry.tableName,
            entityID1: existingEntry.entityID1,
            entityID2: existingEntry.entityID2
        )
        return existingFingerprint != currentFingerprint
    }

    /**
     Returns whether the current workspace snapshot still contains one Android composite key.

     - Parameters:
       - key: Android composite key to inspect.
       - snapshot: Current local workspace snapshot.
     - Returns: `true` when the key still resolves to a current `Workspace`, `Window`, or `PageManager` row.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func currentRowExists(forKey key: String, in snapshot: RemoteSyncWorkspaceCurrentSnapshot) -> Bool {
        snapshot.workspaceRowsByKey[key] != nil
            || snapshot.windowRowsByKey[key] != nil
            || snapshot.pageManagerRowsByKey[key] != nil
            || snapshot.labelOverrideRowsByKey[key] != nil
            || snapshot.globalTextDisplayRowsByKey[key] != nil
    }

    /**
     Writes one sparse Android workspace patch database to the supplied SQLite URL.

     - Parameters:
       - url: Temporary SQLite file URL to create.
       - schemaVersion: SQLite user version that should be written to the patch database.
       - changeSet: Sparse current-row diff that should be serialized.
     - Side effects:
       - creates and writes a temporary SQLite database file
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when local settings cannot be serialized into Android JSON columns
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when the file cannot be opened for writing
       - rethrows SQLite execution failures from schema creation or row inserts
     */
    private func writePatchDatabase(
        at url: URL,
        schemaVersion: Int,
        changeSet: ChangeSet
    ) throws {
        guard schemaVersion == RemoteSyncAndroidDatabaseContract.schemaVersion(for: .workspaces) else {
            throw RemoteSyncWorkspacePatchUploadError.unsupportedSchemaVersion(schemaVersion)
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
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        try execute(
            RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: .workspaces),
            in: database
        )

        for row in changeSet.workspaceRowsByKey.values.sorted(by: Self.workspaceSort) {
            try insertWorkspaceRow(row, in: database)
        }
        for row in changeSet.windowRowsByKey.values.sorted(by: Self.windowSort) {
            try insertWindowRow(row, in: database)
        }
        for row in changeSet.pageManagerRowsByKey.values.sorted(by: Self.pageManagerSort) {
            try insertPageManagerRow(row, in: database)
        }
        for row in changeSet.labelOverrideRowsByKey.values.sorted(by: Self.labelOverrideSort) {
            try insertWorkspaceLabelOverrideRow(row, in: database)
        }
        for row in changeSet.globalTextDisplayRowsByKey.values.sorted(by: {
            $0.id.uuidString < $1.id.uuidString
        }) {
            try insertGlobalTextDisplaySettingsRow(row, in: database)
        }
        for entry in changeSet.logEntries {
            try insertLogEntry(entry, in: database)
        }
    }

    /**
     Inserts one Android `Workspace` row into the open patch database.

     - Parameters:
       - row: Android-shaped workspace row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `Workspace` table.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when one JSON-backed settings payload cannot be serialized
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when SQLite cannot prepare or step the insert
     */
    private func insertWorkspaceRow(
        _ row: RemoteSyncCurrentWorkspaceRow,
        in database: OpaquePointer
    ) throws {
        let columns = [
            "name",
            "contentsText",
            "id",
            "orderNumber",
            "unPinnedWeight",
            "maximizedWindowId",
            "primaryTargetLinksWindowId",
        ] + RemoteSyncWorkspaceTextDisplaySettingsWire.columns() + [
            "workspace_settings_enableTiltToScroll",
            "workspace_settings_enableReverseSplitMode",
            "workspace_settings_autoPin",
            "workspace_settings_restoreButtonsVisible",
            "workspace_settings_speakSettings",
            "workspace_settings_recentLabels",
            "workspace_settings_autoAssignLabels",
            "workspace_settings_autoAssignPrimaryLabel",
            "workspace_settings_studyPadCursors",
            "workspace_settings_hideCompareDocuments",
            "workspace_settings_limitAmbiguousModalSize",
            "workspace_settings_workspaceColor",
        ]
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let sql = "INSERT INTO Workspace (\(columns.joined(separator: ", "))) VALUES (\(placeholders))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        Self.bindText(row.name, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.contentsText, to: statement, index: index)
        index += 1
        Self.bindUUIDBlob(row.id, to: statement, index: index)
        index += 1
        sqlite3_bind_int(statement, index, Int32(row.orderNumber))
        index += 1
        Self.bindOptionalFloat(row.unPinnedWeight, to: statement, index: index)
        index += 1
        Self.bindOptionalUUIDBlob(row.maximizedWindowID, to: statement, index: index)
        index += 1
        Self.bindOptionalUUIDBlob(row.primaryTargetLinksWindowID, to: statement, index: index)
        index += 1
        try bindTextDisplaySettings(
            row.textDisplaySettings,
            fidelity: row.textDisplayFidelity,
            to: statement,
            index: &index
        )
        try bindWorkspaceSettings(
            row.workspaceSettings,
            speakSettingsJSON: row.speakSettingsJSON,
            workspaceColor: row.workspaceColor,
            to: statement,
            index: &index
        )

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `Window` row into the open patch database.

     - Parameters:
       - row: Android-shaped window row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `Window` table.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when SQLite cannot prepare or step the insert
     */
    private func insertWindowRow(
        _ row: RemoteSyncCurrentWorkspaceWindowRow,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO \"Window\" (workspaceId, isSynchronized, isPinMode, isLinksWindow, id, orderNumber, targetLinksWindowId, syncGroup, window_layout_state, window_layout_weight) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.workspaceID, to: statement, index: 1)
        Self.bindBool(row.isSynchronized, to: statement, index: 2)
        Self.bindBool(row.isPinMode, to: statement, index: 3)
        Self.bindBool(row.isLinksWindow, to: statement, index: 4)
        Self.bindUUIDBlob(row.id, to: statement, index: 5)
        sqlite3_bind_int(statement, 6, Int32(row.orderNumber))
        Self.bindOptionalUUIDBlob(row.targetLinksWindowID, to: statement, index: 7)
        sqlite3_bind_int(statement, 8, Int32(row.syncGroup))
        Self.bindText(row.layoutState, to: statement, index: 9)
        sqlite3_bind_double(statement, 10, Double(row.layoutWeight))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `PageManager` row into the open patch database.

     - Parameters:
       - row: Android-shaped page-manager row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `PageManager` table.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when one JSON-backed settings payload cannot be serialized
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when SQLite cannot prepare or step the insert
     */
    private func insertPageManagerRow(
        _ row: RemoteSyncCurrentWorkspacePageManagerRow,
        in database: OpaquePointer
    ) throws {
        let columns = [
            "windowId",
            "currentCategoryName",
            "jsState",
            "bible_document",
            "bible_verse_versification",
            "bible_verse_bibleBook",
            "bible_verse_chapterNo",
            "bible_verse_verseNo",
            "commentary_document",
            "commentary_anchorOrdinal",
            "commentary_sourceBookAndKey",
            "dictionary_document",
            "dictionary_key",
            "dictionary_anchorOrdinal",
            "general_book_document",
            "general_book_key",
            "general_book_anchorOrdinal",
            "map_document",
            "map_key",
            "map_anchorOrdinal",
        ] + RemoteSyncWorkspaceTextDisplaySettingsWire.columns()
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let sql = "INSERT INTO PageManager (\(columns.joined(separator: ", "))) VALUES (\(placeholders))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        Self.bindUUIDBlob(row.windowID, to: statement, index: index)
        index += 1
        Self.bindText(row.currentCategoryName, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.jsState, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.bibleDocument, to: statement, index: index)
        index += 1
        Self.bindText(row.bibleVersification, to: statement, index: index)
        index += 1
        sqlite3_bind_int(statement, index, Int32(row.bibleBook))
        index += 1
        sqlite3_bind_int(statement, index, Int32(row.bibleChapterNo))
        index += 1
        sqlite3_bind_int(statement, index, Int32(row.bibleVerseNo))
        index += 1
        Self.bindOptionalText(row.commentaryDocument, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(row.commentaryAnchorOrdinal, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.commentarySourceBookAndKey, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.dictionaryDocument, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.dictionaryKey, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(row.dictionaryAnchorOrdinal, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.generalBookDocument, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.generalBookKey, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(row.generalBookAnchorOrdinal, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.mapDocument, to: statement, index: index)
        index += 1
        Self.bindOptionalText(row.mapKey, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(row.mapAnchorOrdinal, to: statement, index: index)
        index += 1
        try bindTextDisplaySettings(
            row.textDisplaySettings,
            fidelity: row.textDisplayFidelity,
            to: statement,
            index: &index
        )

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `WorkspaceLabelOverride` row into a sparse patch database.

     - Parameters:
       - row: Composite-key label override to serialize.
       - database: Open writable SQLite database.
     - Side Effects: Inserts one content row.
     - Throws: `invalidSQLiteDatabase` when SQLite cannot prepare or execute the insert.
     */
    private func insertWorkspaceLabelOverrideRow(
        _ row: RemoteSyncCurrentWorkspaceLabelOverrideRow,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO WorkspaceLabelOverride (workspaceId, labelId, overrideMode) VALUES (?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.workspaceID, to: statement, index: 1)
        Self.bindUUIDBlob(row.labelID, to: statement, index: 2)
        Self.bindOptionalInt(row.overrideMode, to: statement, index: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts Android's complete global text-display singleton into a sparse patch database.

     - Parameters:
       - row: Canonical singleton and all native/fidelity fields.
       - database: Open writable SQLite database.
     - Side Effects: Inserts one content row.
     - Throws: JSON encoding or SQLite preparation/execution failures.
     */
    private func insertGlobalTextDisplaySettingsRow(
        _ row: RemoteSyncCurrentGlobalTextDisplaySettingsRow,
        in database: OpaquePointer
    ) throws {
        let columns = ["id"] + RemoteSyncWorkspaceTextDisplaySettingsWire.columns()
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        let sql = "INSERT INTO GlobalTextDisplaySettings (\(columns.joined(separator: ", "))) VALUES (\(placeholders))"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        Self.bindUUIDBlob(row.id, to: statement, index: index)
        index += 1
        try bindTextDisplaySettings(
            row.textDisplaySettings,
            fidelity: row.fidelity,
            to: statement,
            index: &index
        )
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `LogEntry` row into the open patch database.

     - Parameters:
       - entry: Android log entry to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `LogEntry` table.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when SQLite cannot prepare or step the insert
     */
    private func insertLogEntry(
        _ entry: RemoteSyncLogEntry,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindText(entry.tableName, to: statement, index: 1)
        Self.bindSQLiteValue(entry.entityID1, to: statement, index: 2)
        Self.bindSQLiteValue(entry.entityID2, to: statement, index: 3)
        Self.bindText(entry.type.rawValue, to: statement, index: 4)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        Self.bindText(entry.sourceDevice, to: statement, index: 6)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Binds one embedded Android text-display settings block into a prepared SQLite statement.

     - Parameters:
       - value: Optional text-display settings override block.
       - statement: Prepared SQLite statement receiving the bound values.
       - index: In-out one-based SQLite parameter index advanced past the bound columns.
     - Side effects: mutates the statement's bound-parameter state.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when `bookmarksHideLabels` cannot be encoded safely
     */
    private func bindTextDisplaySettings(
        _ value: TextDisplaySettings?,
        fidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity,
        to statement: OpaquePointer,
        index: inout Int32
    ) throws {
        let values: [RemoteSyncSQLiteValue]
        do {
            values = try RemoteSyncWorkspaceTextDisplaySettingsWire(
                settings: value,
                fidelity: fidelity
            ).sqliteValues()
        } catch {
            throw RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed(
                field: "text_display_settings_bookmarksHideLabels"
            )
        }
        for sqliteValue in values {
            Self.bindSQLiteValue(sqliteValue, to: statement, index: index)
            index += 1
        }
    }

    /**
     Binds one embedded Android workspace-settings block into a prepared SQLite statement.

     - Parameters:
       - value: Workspace settings payload supported by both Android and iOS.
       - speakSettingsJSON: Raw Android `speakSettings` JSON preserved in the fidelity store.
       - workspaceColor: Optional raw Android workspace color preserved in the fidelity store.
       - statement: Prepared SQLite statement receiving the bound values.
       - index: In-out one-based SQLite parameter index advanced past the bound columns.
     - Side effects: mutates the statement's bound-parameter state.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when one JSON-backed settings payload cannot be serialized safely
     */
    private func bindWorkspaceSettings(
        _ value: WorkspaceSettings,
        speakSettingsJSON: String?,
        workspaceColor: Int?,
        to statement: OpaquePointer,
        index: inout Int32
    ) throws {
        var normalizedValue = value
        normalizedValue.normalizeAutoAssignPrimaryLabel()

        Self.bindBool(normalizedValue.enableTiltToScroll, to: statement, index: index)
        index += 1
        Self.bindBool(normalizedValue.enableReverseSplitMode, to: statement, index: index)
        index += 1
        Self.bindBool(normalizedValue.autoPin, to: statement, index: index)
        index += 1
        Self.bindBool(normalizedValue.restoreButtonsVisible, to: statement, index: index)
        index += 1
        Self.bindOptionalText(speakSettingsJSON, to: statement, index: index)
        index += 1
        if normalizedValue.recentLabels.isEmpty {
            sqlite3_bind_null(statement, index)
        } else {
            let recentLabelsJSON = try encodeRecentLabelsJSON(normalizedValue.recentLabels)
            Self.bindText(recentLabelsJSON, to: statement, index: index)
        }
        index += 1
        if normalizedValue.autoAssignLabels.isEmpty {
            sqlite3_bind_null(statement, index)
        } else {
            let autoAssignLabelsJSON = try encodeSortedUUIDSetJSON(
                normalizedValue.autoAssignLabels,
                field: "workspace_settings_autoAssignLabels"
            )
            Self.bindText(autoAssignLabelsJSON, to: statement, index: index)
        }
        index += 1
        Self.bindOptionalUUIDBlob(normalizedValue.autoAssignPrimaryLabel, to: statement, index: index)
        index += 1
        if normalizedValue.studyPadCursors.isEmpty {
            sqlite3_bind_null(statement, index)
        } else {
            let studyPadCursorsJSON = try encodeStudyPadCursorsJSON(normalizedValue.studyPadCursors)
            Self.bindText(studyPadCursorsJSON, to: statement, index: index)
        }
        index += 1
        if normalizedValue.hideCompareDocuments.isEmpty {
            sqlite3_bind_null(statement, index)
        } else {
            let hiddenCompareDocumentsJSON = try encodeSortedStringSetJSON(
                normalizedValue.hideCompareDocuments,
                field: "workspace_settings_hideCompareDocuments"
            )
            Self.bindText(hiddenCompareDocumentsJSON, to: statement, index: index)
        }
        index += 1
        Self.bindBool(normalizedValue.limitAmbiguousModalSize, to: statement, index: index)
        index += 1
        Self.bindOptionalInt(workspaceColor, to: statement, index: index)
        index += 1
    }

    /**
     Encodes the workspace `recentLabels` array into Android's JSON payload shape.

     - Parameter value: Recent-label array in current order.
     - Returns: JSON string using Android's `{labelId,lastAccess}` millisecond payload.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when the payload cannot be encoded safely
     */
    private func encodeRecentLabelsJSON(_ value: [RecentLabel]) throws -> String {
        let payload = value.map {
            AndroidRecentLabelPayload(
                labelId: $0.labelId.uuidString.lowercased(),
                lastAccess: Int64($0.lastAccess.timeIntervalSince1970 * 1000.0)
            )
        }
        return try encodeJSONString(payload, field: "workspace_settings_recentLabels")
    }

    /**
     Encodes one UUID set into Android's string-array JSON payload shape.

     - Parameters:
       - value: UUID set to encode.
       - field: Android column name used for error reporting.
     - Returns: JSON string containing sorted lower-case UUID strings.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when the payload cannot be encoded safely
     */
    private func encodeSortedUUIDSetJSON(_ value: Set<UUID>, field: String) throws -> String {
        let payload = value.map { $0.uuidString.lowercased() }.sorted()
        return try encodeJSONString(payload, field: field)
    }

    /**
     Encodes one UUID array into Android's string-array JSON payload shape.

     - Parameters:
       - value: UUID array to encode.
       - field: Android column name used for error reporting.
     - Returns: JSON string preserving the current array order.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when the payload cannot be encoded safely
     */
    private func encodeUUIDArrayJSON(_ value: [UUID], field: String) throws -> String {
        let payload = value.map { $0.uuidString.lowercased() }
        return try encodeJSONString(payload, field: field)
    }

    /**
     Encodes one string set into Android's string-array JSON payload shape.

     - Parameters:
       - value: String set to encode.
       - field: Android column name used for error reporting.
     - Returns: JSON string containing sorted strings.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when the payload cannot be encoded safely
     */
    private func encodeSortedStringSetJSON(_ value: Set<String>, field: String) throws -> String {
        try encodeJSONString(value.sorted(), field: field)
    }

    /**
     Encodes one StudyPad-cursor dictionary into Android's JSON object payload shape.

     - Parameter value: Cursor positions keyed by label identifier.
     - Returns: JSON object string keyed by lower-case UUID strings.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when the payload cannot be encoded safely
     */
    private func encodeStudyPadCursorsJSON(_ value: [UUID: Int]) throws -> String {
        let payload = Dictionary(uniqueKeysWithValues: value.map {
            ($0.key.uuidString.lowercased(), $0.value)
        })
        return try encodeJSONString(payload, field: "workspace_settings_studyPadCursors")
    }

    /**
     Encodes one arbitrary `Encodable` payload into a UTF-8 JSON string.

     - Parameters:
       - value: Encodable payload to serialize.
       - field: Android column name used for error reporting.
     - Returns: UTF-8 JSON string.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed` when the payload cannot be encoded safely
     */
    private func encodeJSONString<Value: Encodable>(_ value: Value, field: String) throws -> String {
        let data: Data
        do {
            data = try jsonEncoder.encode(value)
        } catch {
            throw RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed(field: field)
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw RemoteSyncWorkspacePatchUploadError.jsonEncodingFailed(field: field)
        }
        return string
    }

    /**
     Executes one schema or pragma SQL batch against the open patch database.

     - Parameters:
       - sql: SQL batch to execute.
       - database: Open SQLite database handle.
     - Side effects: mutates the open SQLite database schema or metadata.
     - Failure modes:
       - throws `RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase` when SQLite rejects the statement batch
     */
    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncWorkspacePatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Creates a new unique temporary URL beneath the configured temporary directory.

     - Parameters:
       - prefix: File-name prefix for the temporary file.
       - suffix: File-name suffix for the temporary file.
     - Returns: Temporary file URL that does not currently exist.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
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
     Sorts workspace rows into Android display order with UUID tie-breaking.

     - Parameters:
       - lhs: Left-hand workspace row.
       - rhs: Right-hand workspace row.
     - Returns: `true` when `lhs` should be inserted before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func workspaceSort(_ lhs: RemoteSyncCurrentWorkspaceRow, _ rhs: RemoteSyncCurrentWorkspaceRow) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    /**
     Sorts window rows into Android display order with UUID tie-breaking.

     - Parameters:
       - lhs: Left-hand window row.
       - rhs: Right-hand window row.
     - Returns: `true` when `lhs` should be inserted before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func windowSort(_ lhs: RemoteSyncCurrentWorkspaceWindowRow, _ rhs: RemoteSyncCurrentWorkspaceWindowRow) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    /**
     Sorts page-manager rows by owning window identifier.

     - Parameters:
       - lhs: Left-hand page-manager row.
       - rhs: Right-hand page-manager row.
     - Returns: `true` when `lhs` should be inserted before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func pageManagerSort(_ lhs: RemoteSyncCurrentWorkspacePageManagerRow, _ rhs: RemoteSyncCurrentWorkspacePageManagerRow) -> Bool {
        lhs.windowID.uuidString < rhs.windowID.uuidString
    }

    /** Sorts workspace-label overrides by their complete Android composite identity. */
    private static func labelOverrideSort(
        _ lhs: RemoteSyncCurrentWorkspaceLabelOverrideRow,
        _ rhs: RemoteSyncCurrentWorkspaceLabelOverrideRow
    ) -> Bool {
        if lhs.workspaceID == rhs.workspaceID {
            return lhs.labelID.uuidString < rhs.labelID.uuidString
        }
        return lhs.workspaceID.uuidString < rhs.workspaceID.uuidString
    }

    /**
     Binds one typed SQLite scalar value into a prepared statement parameter.

     - Parameters:
       - value: Typed SQLite value to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindSQLiteValue(
        _ value: RemoteSyncSQLiteValue,
        to statement: OpaquePointer,
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
            bindOptionalText(value.textValue, to: statement, index: index)
        case .blob:
            if let data = value.blobData {
                _ = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        bytes.baseAddress,
                        Int32(data.count),
                        remoteSyncWorkspacePatchUploadSQLiteTransient
                    )
                }
            } else {
                sqlite3_bind_null(statement, index)
            }
        }
    }

    /**
     Binds one required UTF-8 string into a prepared SQLite statement parameter.

     - Parameters:
       - value: Required text value.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindText(_ value: String, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, remoteSyncWorkspacePatchUploadSQLiteTransient)
    }

    /**
     Binds one optional UTF-8 string into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional text value.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalText(_ value: String?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindText(value, to: statement, index: index)
    }

    /**
     Binds one Boolean into a prepared SQLite statement parameter using Android's integer convention.

     - Parameters:
       - value: Boolean value to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindBool(_ value: Bool, to statement: OpaquePointer, index: Int32) {
        sqlite3_bind_int(statement, index, value ? 1 : 0)
    }

    /**
     Binds one optional Boolean into a prepared SQLite statement parameter using Android's integer convention.

     - Parameters:
       - value: Optional Boolean value.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalBool(_ value: Bool?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindBool(value, to: statement, index: index)
    }

    /**
     Binds one optional integer into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional integer value.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalInt(_ value: Int?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(value))
    }

    /**
     Binds one optional floating-point value into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional floating-point value.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalFloat(_ value: Float?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, Double(value))
    }

    /**
     Binds one UUID into Android's raw 16-byte SQLite BLOB format.

     - Parameters:
       - value: UUID value to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindUUIDBlob(_ value: UUID, to statement: OpaquePointer, index: Int32) {
        let data = RemoteSyncWorkspaceSnapshotService.uuidBlob(value)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(data.count),
                remoteSyncWorkspacePatchUploadSQLiteTransient
            )
        }
    }

    /**
     Binds one optional UUID into Android's raw 16-byte SQLite BLOB format.

     - Parameters:
       - value: Optional UUID value to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalUUIDBlob(_ value: UUID?, to statement: OpaquePointer, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindUUIDBlob(value, to: statement, index: index)
    }

    /**
     Sorts local Android log-entry payloads deterministically for stable settings persistence.

     - Parameters:
       - lhs: Left-hand log entry.
       - rhs: Right-hand log entry.
     - Returns: `true` when `lhs` should be ordered before `rhs`.
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
