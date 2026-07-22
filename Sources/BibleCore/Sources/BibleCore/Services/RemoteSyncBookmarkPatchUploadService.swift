// RemoteSyncBookmarkPatchUploadService.swift — Android-shaped outbound bookmark patch creation and upload

import Foundation
import SQLite3
import SwiftData

private let remoteSyncBookmarkPatchUploadSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while exporting and uploading an outbound Android bookmark patch.
 */
public enum RemoteSyncBookmarkPatchUploadError: Error, Equatable {
    /// The category is not ready for upload because no remote device folder identifier is known locally.
    case missingDeviceFolderID

    /// The generated temporary SQLite patch database could not be opened for writing.
    case invalidSQLiteDatabase

    /// Bookmark patches must use Android Room bookmark schema version 12 exactly.
    case unsupportedSchemaVersion(Int)

    /// Persisted outbox metadata is malformed or belongs to a different upload destination.
    case invalidPendingUpload

    /// The highest accepted local or remote patch number cannot be incremented safely.
    case patchNumberOverflow
}

/**
 Summary of one successful outbound bookmark patch upload.

 Android bookmark sync spans nine content tables plus `LogEntry`. This report keeps enough detail to
 confirm that an outbound upload actually serialized the expected mix of bookmark-category rows.
 */
public struct RemoteSyncBookmarkPatchUploadReport: Sendable, Equatable {
    /// Remote file metadata returned by the backend after upload succeeded.
    public let uploadedFile: RemoteSyncFile

    /// Monotonic patch number assigned within the current device folder.
    public let patchNumber: Int64

    /// Number of `Label` rows written into the patch database.
    public let upsertedLabelCount: Int

    /// Number of `BibleBookmark` rows written into the patch database.
    public let upsertedBibleBookmarkCount: Int

    /// Number of `GenericBookmark` rows written into the patch database.
    public let upsertedGenericBookmarkCount: Int

    /// Number of `StudyPadTextEntry` rows written into the patch database.
    public let upsertedStudyPadEntryCount: Int

    /// Number of auxiliary note, link, and StudyPad-text rows written into the patch database.
    public let upsertedAuxiliaryRowCount: Int

    /// Number of `DELETE` log entries emitted for rows removed locally.
    public let deletedRowCount: Int

    /// Total number of Android `LogEntry` rows written into the patch database.
    public let logEntryCount: Int

    /// Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
    public let lastUpdated: Int64

    /**
     Creates one outbound bookmark patch-upload summary.

     - Parameters:
       - uploadedFile: Remote file metadata returned by the backend after upload succeeded.
       - patchNumber: Monotonic patch number assigned within the current device folder.
       - upsertedLabelCount: Number of `Label` rows written into the patch database.
       - upsertedBibleBookmarkCount: Number of `BibleBookmark` rows written into the patch database.
       - upsertedGenericBookmarkCount: Number of `GenericBookmark` rows written into the patch database.
       - upsertedStudyPadEntryCount: Number of `StudyPadTextEntry` rows written into the patch database.
       - upsertedAuxiliaryRowCount: Number of auxiliary note, link, and StudyPad-text rows written into the patch database.
       - deletedRowCount: Number of `DELETE` log entries emitted for rows removed locally.
       - logEntryCount: Total number of Android `LogEntry` rows written into the patch database.
       - lastUpdated: Millisecond timestamp recorded as `lastUpdated` for the emitted Android log entries.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        uploadedFile: RemoteSyncFile,
        patchNumber: Int64,
        upsertedLabelCount: Int,
        upsertedBibleBookmarkCount: Int,
        upsertedGenericBookmarkCount: Int,
        upsertedStudyPadEntryCount: Int,
        upsertedAuxiliaryRowCount: Int,
        deletedRowCount: Int,
        logEntryCount: Int,
        lastUpdated: Int64
    ) {
        self.uploadedFile = uploadedFile
        self.patchNumber = patchNumber
        self.upsertedLabelCount = upsertedLabelCount
        self.upsertedBibleBookmarkCount = upsertedBibleBookmarkCount
        self.upsertedGenericBookmarkCount = upsertedGenericBookmarkCount
        self.upsertedStudyPadEntryCount = upsertedStudyPadEntryCount
        self.upsertedAuxiliaryRowCount = upsertedAuxiliaryRowCount
        self.deletedRowCount = deletedRowCount
        self.logEntryCount = logEntryCount
        self.lastUpdated = lastUpdated
    }
}

/**
 Creates Android-shaped sparse bookmark patch databases and uploads them to the active backend.

 The service mirrors the outbound half of Android's bookmark sync contract:
 - project current local SwiftData bookmark state into Android `Label`, bookmark, note, link, and
   StudyPad rows
 - atomically compare that projection against accepted row identities, Android `LogEntry` rows,
   local fingerprints, and strict patch-status bookkeeping
 - emit sparse `UPSERT` and `DELETE` `LogEntry` rows for only the changed Android keys
 - resume an existing destination-bound outbox before projecting a newer local generation
 - inspect remote patch filenames before allocating a fresh patch number, then persist an
   Android-compatible gzip archive and immutable acceptance manifest in Application Support
 - reconcile an existing remote `<patchNumber>.<schemaVersion>.sqlite3.gz` by exact archive bytes,
   or upload the durable archive when that name is absent
 - atomically advance local `LogEntry`, `SyncStatus`, `lastPatchWritten`, playback-fidelity state,
   accepted row identities, and exact-generation fingerprints only after remote success

 Data dependencies:
 - `RemoteSyncAdapting` performs the remote file upload
 - `RemoteSyncBookmarkSnapshotService` projects live SwiftData and local-only bookmark fidelity data
   into Android-shaped rows
 - `RemoteSyncLogEntryStore` provides the Android conflict baseline and is updated after success
 - `RemoteSyncBookmarkPlaybackSettingsStore` preserves accepted raw Android playback JSON for
   uploaded bookmark rows
 - `RemoteSyncPatchStatusStore` strictly validates accepted patch bookkeeping and contributes the
   local side of fresh patch-number allocation
 - `RemoteSyncStateStore` persists Android-aligned `lastPatchWritten` bookkeeping
 - `RemoteSyncArchiveStagingService` provides gzip compression for the generated SQLite patch file
 - the configured outbox directory durably retains exact archive bytes across process restarts;
   production places it beneath Application Support

 Side effects:
 - reads live bookmark-category state from SwiftData and local-only fidelity settings
 - lists the active device folder before allocating a fresh patch number
 - creates and removes one temporary SQLite file beneath the configured scratch directory
 - writes a durable gzip archive and pending manifest before performing remote I/O
 - reconciles or uploads exactly one remote gzip patch archive
 - atomically publishes accepted bookmark playback JSON, Android `LogEntry`, `SyncStatus`,
   `lastPatchWritten`, row-identity, and fingerprint state
 - removes the accepted outbox archive and manifest after local publication commits
 - fails closed when a pending outbox targets another destination; explicit lifecycle replacement
   cleanup removes only that pending generation and leaves accepted state dirty for a later rebuild

 Failure modes:
 - throws `RemoteSyncBookmarkPatchUploadError.missingDeviceFolderID` when the category is not bootstrapped for outbound upload
 - throws `RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase` when the temporary SQLite patch file cannot be created
 - throws `RemoteSyncBookmarkPatchUploadError.invalidPendingUpload` when the durable manifest is malformed
 - throws `RemoteSyncRemotePatchReconciliationError` when durable bytes change, an occupied remote
   filename contains another generation, or the backend lacks create-only publication support
 - rethrows strict snapshot, patch-status, transaction, local filesystem, remote listing/download,
   upload, and acceptance-checkpoint failures without advancing accepted local state
 - rethrows bounded file-to-file gzip failures from `RemoteSyncArchiveStagingService`

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement rules of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncBookmarkPatchUploadService {
    /**
     Immutable local projection and metadata generation used to build one outbound archive.
     */
    private struct UploadGeneration {
        let snapshot: RemoteSyncBookmarkCurrentSnapshot
        let acceptedBaseline: RemoteSyncBookmarkAcceptedBaseline
        let expectedAcceptedBaselineRevision: UUID?
        let expectedAcceptedBaselineExists: Bool
        let changeSet: ChangeSet
        let patchNumber: Int64
        let sourceDevice: String
        let timestamp: Int64
    }

    /**
     One accepted playback payload whose source row fingerprint must still match before publication.
     */
    private struct PlaybackAcceptance: Codable, Equatable {
        let rowKey: String
        let sourceFingerprint: String
        let bookmarkID: UUID
        let kind: RemoteSyncBookmarkPlaybackSettingsStore.BookmarkKind
        let playbackSettingsJSON: String?
    }

    /**
     One uploaded bookmark deletion whose playback side data may be removed only while the row stays absent.
     */
    private struct PlaybackDeletion: Codable, Equatable {
        let rowKey: String
        let bookmarkID: UUID
        let kind: RemoteSyncBookmarkPlaybackSettingsStore.BookmarkKind
    }

    /**
     Durable bookmark upload generation retained until remote success and local acceptance both complete.

     The manifest intentionally carries acceptance metadata alongside the archive digest. A process restart
     therefore reuses the same patch number and bytes instead of projecting a newer live graph under the old
     remote identity.
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
        let acceptedBaseline: RemoteSyncBookmarkAcceptedBaseline
        let expectedAcceptedBaselineRevision: UUID?
        let expectedAcceptedBaselineExists: Bool
        let playbackAcceptances: [PlaybackAcceptance]
        let playbackDeletions: [PlaybackDeletion]
        let upsertedLabelCount: Int
        let upsertedBibleBookmarkCount: Int
        let upsertedGenericBookmarkCount: Int
        let upsertedStudyPadEntryCount: Int
        let upsertedAuxiliaryRowCount: Int
        let deletedRowCount: Int
        let logEntryCount: Int
        var publicationIdentity: RemoteSyncPublicationIdentity? = nil
    }

    private struct ChangeSet {
        let labelRowsByKey: [String: RemoteSyncAndroidLabel]
        let bibleBookmarkRowsByKey: [String: RemoteSyncAndroidBibleBookmark]
        let bibleNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow]
        let bibleLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow]
        let genericBookmarkRowsByKey: [String: RemoteSyncAndroidGenericBookmark]
        let genericNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow]
        let genericLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow]
        let studyPadEntryRowsByKey: [String: RemoteSyncAndroidStudyPadEntry]
        let studyPadTextRowsByKey: [String: RemoteSyncCurrentStudyPadTextRow]
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

        /**
         Returns the total number of auxiliary upsert rows in the change set.

         - Returns: Number of note, link, and StudyPad-text upserts.
         - Side effects: none.
         - Failure modes: This helper cannot fail.
         */
        var auxiliaryUpsertCount: Int {
            bibleNoteRowsByKey.count
                + bibleLinkRowsByKey.count
                + genericNoteRowsByKey.count
                + genericLinkRowsByKey.count
                + studyPadTextRowsByKey.count
        }
    }

    private let adapter: any RemoteSyncAdapting
    private let remotePatchReconciler: RemoteSyncRemotePatchReconciler
    private let snapshotService: RemoteSyncBookmarkSnapshotService
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let outboxDirectory: URL
    private let nowProvider: () -> Int64

    /// Settings row containing the currently pending bookmark outbox generation.
    static let pendingUploadKey = "remote_sync.pending_upload.bookmarks"

    /**
     Creates a bookmark patch upload service for one remote backend.

     - Parameters:
       - adapter: Remote backend adapter used for the final archive upload.
       - snapshotService: Snapshot service used to project current local bookmark state into Android rows.
       - fileManager: File manager used for scratch-file and durable-outbox lifecycle operations.
       - temporaryDirectory: Scratch directory for temporary SQLite files. Defaults to the process temporary directory.
       - outboxDirectory: Durable archive directory. Production defaults to Application Support;
         callers with an injected scratch directory get an isolated sibling outbox by default.
       - nowProvider: Millisecond clock used for Android `LogEntry.lastUpdated` and local `lastPatchWritten`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        snapshotService: RemoteSyncBookmarkSnapshotService = RemoteSyncBookmarkSnapshotService(),
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
            ?? temporaryDirectory?.appendingPathComponent("remote-sync-bookmark-outbox", isDirectory: true)
            ?? Self.defaultOutboxDirectory(fileManager: fileManager)
        self.nowProvider = nowProvider
    }

    /**
     Builds and uploads the next sparse bookmark patch when local state differs from the baseline.

     Missing fingerprint baselines are treated as upload-needed. This mirrors Android's log-driven
     pending-change behavior and prevents a lost or incomplete local baseline from suppressing a
     real local row.

     - Parameters:
       - bootstrapState: Ready bootstrap state for the bookmark category.
       - modelContext: SwiftData context that owns the live bookmark graph.
       - settingsStore: Local-only settings store backing preserved Android sync metadata.
       - schemaVersion: Schema version to encode into the generated patch filename and SQLite user version.
     - Returns: Upload summary when a sparse patch was emitted, or `nil` when no local changes need upload.
     - Side effects:
       - resumes a destination-matched durable outbox before inspecting current local state
       - lists remote patch filenames before allocating a fresh patch number
       - creates and removes a temporary SQLite database when a new generation is needed
       - persists exact gzip bytes and an immutable acceptance manifest in the Application Support outbox
       - reconciles an occupied remote filename by exact bytes or uploads the durable archive
       - atomically publishes the uploaded generation's `LogEntry`, `SyncStatus`, `lastPatchWritten`,
         playback-fidelity, row-identity, and fingerprint state after remote success
       - fails closed when a pending outbox belongs to another destination; lifecycle replacement
         must explicitly discard that generation before retrying
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchUploadError.missingDeviceFolderID` when `bootstrapState.deviceFolderID` is missing or empty
       - throws `RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase` when the temporary SQLite patch file cannot be opened
       - throws `RemoteSyncBookmarkPatchUploadError.invalidPendingUpload` or a
         `RemoteSyncRemotePatchReconciliationError` when durable or remote generation identity
         cannot be validated or safely created
       - rethrows strict snapshot, patch-status, transaction, filesystem, compression, remote
         listing/download, upload, and local acceptance failures
     - Important: Remote success does not authorize a newer live projection. Retries reuse the exact
       pending archive and acceptance manifest until local publication commits.
     */
    public func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = 12
    ) async throws -> RemoteSyncBookmarkPatchUploadReport? {
        try await uploadPendingPatch(
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion,
            acceptanceCheckpoint: {}
        )
    }

    /**
     Resumes an existing bookmark outbox without projecting or creating a new generation.

     Synchronization orchestration calls this before inbound replay so a remotely accepted outbound
     generation can publish its exact local bookkeeping before any newer baseline is installed.

     - Parameters:
       - bootstrapState: Ready bookmark bootstrap state identifying the pending destination.
       - modelContext: Clean SwiftData context containing bookmark graph and settings rows.
       - settingsStore: Settings store constructed from `modelContext`.
       - schemaVersion: Android bookmark Room schema version.
     - Returns: Accepted pending-generation report, or `nil` when no bookmark outbox exists.
     - Side effects: May reconcile/upload the persisted archive and atomically publish its accepted state.
     - Failure modes: Throws for malformed state, destination/schema mismatch, stale baseline revision,
       missing/conflicting bytes, transport failure, or local acceptance failure.
     - Important: This method never projects the live graph and never allocates a patch number.
     */
    public func resumePendingUploadIfPresent(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = 12
    ) async throws -> RemoteSyncBookmarkPatchUploadReport? {
        try await resumePendingUploadIfPresent(
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion,
            acceptanceCheckpoint: {}
        )
    }

    /**
     Explicitly discards an unaccepted bookmark outbox at a destination-replacement boundary.

     - Parameters:
       - modelContext: Clean context containing local sync settings.
       - settingsStore: Store containing the pending manifest.
     - Side effects: Atomically removes the pending marker, then best-effort removes its archive;
       accepted fingerprints, identities, logs, and live rows remain unchanged and therefore dirty.
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
     Resumes a bookmark outbox with a deterministic local-acceptance checkpoint for tests.

     - Parameters:
       - bootstrapState: Ready bookmark bootstrap state identifying the pending destination.
       - modelContext: Clean context containing bookmark graph and settings rows.
       - settingsStore: Settings store constructed from `modelContext`.
       - schemaVersion: Android bookmark Room schema version.
       - acceptanceCheckpoint: Callback invoked after all acceptance mutations and before commit.
     - Returns: Pending-generation report, or `nil` when no outbox exists.
     - Side effects: Reconciles/uploads and accepts only an already-persisted generation.
     - Failure modes: Rethrows schema, destination, manifest, transport, baseline-CAS, transaction,
       and checkpoint failures.
     */
    func resumePendingUploadIfPresent(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = 12,
        acceptanceCheckpoint: @escaping () throws -> Void
    ) async throws -> RemoteSyncBookmarkPatchUploadReport? {
        guard schemaVersion == AndroidBookmarkDatabaseContract.schemaVersion else {
            throw RemoteSyncBookmarkPatchUploadError.unsupportedSchemaVersion(schemaVersion)
        }
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncBookmarkPatchUploadError.missingDeviceFolderID
        }
        guard let pendingUpload = try settingsStore.performAtomicBatch(in: modelContext, {
            try loadPendingUpload(settingsStore: settingsStore)
        }) else {
            return nil
        }
        guard pendingUpload.schemaVersion == schemaVersion,
              pendingUpload.deviceFolderID == deviceFolderID else {
            throw RemoteSyncBookmarkPatchUploadError.invalidPendingUpload
        }
        return try await finishPendingUpload(
            pendingUpload,
            modelContext: modelContext,
            settingsStore: settingsStore,
            acceptanceCheckpoint: acceptanceCheckpoint
        )
    }

    /**
     Executes bookmark upload with a deterministic checkpoint at the end of local acceptance.

     Tests use the checkpoint to prove that every accepted-state setting, including the pending
     outbox marker, rolls back as one generation after remote success. Production uses the public
     overload, which supplies a no-op checkpoint.

     - Parameters:
       - bootstrapState: Ready bookmark bootstrap state.
       - modelContext: Clean SwiftData context containing bookmark graph and settings rows.
       - settingsStore: Settings store constructed from `modelContext`.
       - schemaVersion: Android bookmark Room schema version.
       - acceptanceCheckpoint: Synchronous callback invoked after all acceptance mutations and before commit.
     - Returns: Upload report, or `nil` when the strict projected generation matches its complete baseline.
     - Side effects: May persist or resume a durable outbox, reconcile/upload one remote archive, and
       atomically publish local accepted bookkeeping.
     - Failure modes: Rethrows strict projection, settings transaction, filesystem, transport,
       reconciliation, and checkpoint failures without advancing accepted local state.
     - Important: A pending outbox always takes precedence over a new projection so retries preserve
       the exact patch number and archive bytes across process restarts.
     */
    func uploadPendingPatch(
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = 12,
        acceptanceCheckpoint: @escaping () throws -> Void
    ) async throws -> RemoteSyncBookmarkPatchUploadReport? {
        guard schemaVersion == AndroidBookmarkDatabaseContract.schemaVersion else {
            throw RemoteSyncBookmarkPatchUploadError.unsupportedSchemaVersion(schemaVersion)
        }
        guard let deviceFolderID = bootstrapState.deviceFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceFolderID.isEmpty else {
            throw RemoteSyncBookmarkPatchUploadError.missingDeviceFolderID
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
                for: .bookmarks,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            return try !mutationJournal.pendingMutations(
                for: .bookmarks,
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
                for: .bookmarks,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            let pendingMutations = try mutationJournal.pendingMutations(
                for: .bookmarks,
                settingsStore: settingsStore
            )
            let snapshot = try snapshotService.snapshotCurrentStateThrowing(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            let previousBaseline = try snapshotService.storedAcceptedBaseline(settingsStore: settingsStore)
            let acceptedBaseline = try snapshotService.acceptedBaselineThrowing(
                from: snapshot,
                preserving: previousBaseline
            )
            let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
            let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)
            let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)

            var existingEntriesByKey: [String: RemoteSyncLogEntry] = [:]
            for rawEntry in try logEntryStore.entriesStrict(for: .bookmarks) {
                let entry = AndroidBookmarkDatabaseContract.normalizedLogEntry(rawEntry)
                let key = logEntryStore.key(for: .bookmarks, entry: entry)
                if existingEntriesByKey[key].map({
                    RemoteSyncLogEntryConflictOrder.isNewer(entry, than: $0)
                }) ?? true {
                    existingEntriesByKey[key] = entry
                }
            }
            let patchStatuses = try patchStatusStore.statusesStrict(for: .bookmarks)
            let progressState = RemoteSyncStateStore(settingsStore: settingsStore)
                .progressState(for: .bookmarks)
            let timestamp = try RemoteSyncLogicalSequence.nextTimestamp(
                now: wallClockTimestamp,
                highWatermarks: existingEntriesByKey.values.map(\.lastUpdated)
                    + patchStatuses.map(\.appliedDate)
                    + [progressState.lastPatchWritten, progressState.lastSynchronized].compactMap { $0 }
            )

            var acceptedRowsByKey = Dictionary(
                uniqueKeysWithValues: (previousBaseline?.rowIdentities ?? []).map { ($0.key, $0) }
            )
            for (key, entry) in existingEntriesByKey where entry.type != .delete {
                acceptedRowsByKey[key] = RemoteSyncBookmarkAcceptedRowIdentity(
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
                throw RemoteSyncBookmarkPatchUploadError.patchNumberOverflow
            }
            return UploadGeneration(
                snapshot: snapshot,
                acceptedBaseline: acceptedBaseline,
                expectedAcceptedBaselineRevision: previousBaseline?.revision,
                expectedAcceptedBaselineExists: previousBaseline != nil,
                changeSet: changeSet,
                patchNumber: patchNumber,
                sourceDevice: sourceDevice,
                timestamp: timestamp
            )
        }

        guard let generation else {
            return nil
        }

        let patchFileName = "\(generation.patchNumber).\(schemaVersion).sqlite3.gz"

        let databaseURL = temporaryURL(prefix: "remote-sync-bookmarks-upload-", suffix: ".sqlite3")
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
     Persists one exact bookmark archive and its acceptance manifest before network upload begins.

     The archive is written atomically first. The manifest is then committed through `SettingsStore`;
     if that commit fails, the unreferenced archive is removed. A crash between those two writes can
     only leave an orphan file and cannot expose an upload generation without its acceptance metadata.

     - Parameters:
       - generation: Strict preflight projection and sparse change set.
       - databaseURL: Complete SQLite patch database to compress into the durable outbox.
       - patchFileName: Android patch filename for the generation.
       - deviceFolderID: Remote device folder that owns the patch number.
       - schemaVersion: Android bookmark schema version encoded in the filename and database.
       - modelContext: Clean context shared by graph and settings.
       - settingsStore: Store receiving the pending manifest.
     - Returns: Durable pending upload manifest.
     - Side effects: Creates the outbox directory, writes one archive, and commits one settings row.
     - Failure modes: Rethrows directory, file-write, encoding, or atomic settings failures; removes
       the archive when manifest publication fails.
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
        try fileManager.createDirectory(
            at: outboxDirectory,
            withIntermediateDirectories: true
        )
        let generationID = UUID()
        let archiveFileName = "bookmark-\(generationID.uuidString.lowercased()).sqlite3.gz"
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

        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        var playbackAcceptances: [PlaybackAcceptance] = []
        for (key, row) in generation.changeSet.bibleBookmarkRowsByKey {
            guard let fingerprint = generation.snapshot.fingerprintsByKey[key] else {
                throw RemoteSyncBookmarkAcceptedBaselineError.missingProjectedFingerprint(key)
            }
            playbackAcceptances.append(
                PlaybackAcceptance(
                    rowKey: key,
                    sourceFingerprint: fingerprint,
                    bookmarkID: row.id,
                    kind: .bible,
                    playbackSettingsJSON: row.playbackSettingsJSON
                )
            )
        }
        for (key, row) in generation.changeSet.genericBookmarkRowsByKey {
            guard let fingerprint = generation.snapshot.fingerprintsByKey[key] else {
                throw RemoteSyncBookmarkAcceptedBaselineError.missingProjectedFingerprint(key)
            }
            playbackAcceptances.append(
                PlaybackAcceptance(
                    rowKey: key,
                    sourceFingerprint: fingerprint,
                    bookmarkID: row.id,
                    kind: .generic,
                    playbackSettingsJSON: row.playbackSettingsJSON
                )
            )
        }

        let playbackDeletions = generation.changeSet.logEntries.compactMap { entry -> PlaybackDeletion? in
            guard entry.type == .delete, let bookmarkID = Self.uuid(from: entry.entityID1) else {
                return nil
            }
            let kind: RemoteSyncBookmarkPlaybackSettingsStore.BookmarkKind
            switch entry.tableName {
            case "BibleBookmark": kind = .bible
            case "GenericBookmark": kind = .generic
            default: return nil
            }
            return PlaybackDeletion(
                rowKey: logEntryStore.key(for: .bookmarks, entry: entry),
                bookmarkID: bookmarkID,
                kind: kind
            )
        }

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
            playbackAcceptances: playbackAcceptances.sorted { $0.rowKey < $1.rowKey },
            playbackDeletions: playbackDeletions.sorted { $0.rowKey < $1.rowKey },
            upsertedLabelCount: generation.changeSet.labelRowsByKey.count,
            upsertedBibleBookmarkCount: generation.changeSet.bibleBookmarkRowsByKey.count,
            upsertedGenericBookmarkCount: generation.changeSet.genericBookmarkRowsByKey.count,
            upsertedStudyPadEntryCount: generation.changeSet.studyPadEntryRowsByKey.count,
            upsertedAuxiliaryRowCount: generation.changeSet.auxiliaryUpsertCount,
            deletedRowCount: generation.changeSet.deletedRowCount,
            logEntryCount: generation.changeSet.logEntries.count
        )
        pendingUpload.publicationIdentity = try RemoteSyncPublicationIdentity.patch(
            category: .bookmarks,
            destinationID: deviceFolderID,
            sourceDevice: pendingUpload.sourceDevice,
            patchNumber: pendingUpload.patchNumber,
            schemaVersion: schemaVersion,
            remoteFileName: patchFileName,
            archiveFileName: archiveFileName,
            archiveSHA256: pendingUpload.archiveSHA256,
            archiveSize: pendingUpload.archiveSize,
            rowCounts: Self.publicationRowCounts(for: pendingUpload),
            acceptancePayload: pendingUpload
        )

        do {
            try settingsStore.performAtomicBatch(in: modelContext) {
                guard try loadPendingUpload(settingsStore: settingsStore) == nil else {
                    throw RemoteSyncBookmarkPatchUploadError.invalidPendingUpload
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
     Reconciles or uploads one durable bookmark outbox generation and atomically accepts it locally.

     Remote reconciliation downloads an existing same-name patch and verifies its full SHA-256 and
     byte count. A matching remote file is accepted without another upload; a mismatch fails closed.
     Local acceptance publishes the exact persisted fingerprint generation, not a live re-projection.

     - Parameters:
       - pendingUpload: Durable outbox manifest to finish.
       - modelContext: Clean context shared by bookmark graph and settings.
       - settingsStore: Settings store containing pending and accepted metadata.
       - acceptanceCheckpoint: Deterministic final in-transaction test checkpoint.
     - Returns: Report reconstructed from the persisted generation and remote file metadata.
     - Side effects: Lists/downloads/uploads remote data, mutates accepted settings atomically, and
       removes the local outbox archive after commit.
     - Failure modes: Throws for missing/conflicting bytes, transport errors, strict current playback
       projection failures, settings transaction failures, or checkpoint errors. The pending generation
       remains durable whenever local acceptance fails.
     */
    private func finishPendingUpload(
        _ pendingUpload: PendingUpload,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        acceptanceCheckpoint: @escaping () throws -> Void
    ) async throws -> RemoteSyncBookmarkPatchUploadReport {
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
                throw RemoteSyncBookmarkPatchUploadError.invalidPendingUpload
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
            let playbackSettingsStore = RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore)
            for acceptance in pendingUpload.playbackAcceptances {
                guard currentSnapshot.fingerprintsByKey[acceptance.rowKey] == acceptance.sourceFingerprint else {
                    continue
                }
                if let payload = acceptance.playbackSettingsJSON, !payload.isEmpty {
                    playbackSettingsStore.setPlaybackSettingsJSON(
                        payload,
                        for: acceptance.bookmarkID,
                        kind: acceptance.kind
                    )
                } else {
                    playbackSettingsStore.removePlaybackSettings(
                        for: acceptance.bookmarkID,
                        kind: acceptance.kind
                    )
                }
            }
            for deletion in pendingUpload.playbackDeletions
            where currentSnapshot.fingerprintsByKey[deletion.rowKey] == nil {
                playbackSettingsStore.removePlaybackSettings(
                    for: deletion.bookmarkID,
                    kind: deletion.kind
                )
            }

            try RemoteSyncMutationJournalService().mergeAcceptedLogEntries(
                acceptedEntries: pendingUpload.updatedEntries,
                uploadedEntries: pendingUpload.uploadedEntries ?? pendingUpload.updatedEntries.filter {
                    $0.lastUpdated == pendingUpload.timestamp && $0.sourceDevice == pendingUpload.sourceDevice
                },
                acceptedFingerprints: pendingUpload.acceptedBaseline.fingerprintsByKey,
                currentFingerprints: currentSnapshot.fingerprintsByKey,
                category: .bookmarks,
                settingsStore: settingsStore
            )
            let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
            _ = try patchStatusStore.statusesStrict(for: .bookmarks)
            patchStatusStore.addStatus(
                RemoteSyncPatchStatus(
                    sourceDevice: pendingUpload.sourceDevice,
                    patchNumber: pendingUpload.patchNumber,
                    sizeBytes: acceptedRemoteFile.size,
                    appliedDate: acceptedRemoteFile.timestamp
                ),
                for: .bookmarks
            )
            let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
            var progressState = stateStore.progressState(for: .bookmarks)
            progressState.lastPatchWritten = pendingUpload.timestamp
            stateStore.setProgressState(progressState, for: .bookmarks)
            try snapshotService.acceptBaseline(
                pendingUpload.acceptedBaseline,
                settingsStore: settingsStore
            )
            try acceptanceCheckpoint()
            settingsStore.remove(Self.pendingUploadKey)
        }

        try? fileManager.removeItem(at: archiveURL)
        return RemoteSyncBookmarkPatchUploadReport(
            uploadedFile: acceptedRemoteFile,
            patchNumber: pendingUpload.patchNumber,
            upsertedLabelCount: pendingUpload.upsertedLabelCount,
            upsertedBibleBookmarkCount: pendingUpload.upsertedBibleBookmarkCount,
            upsertedGenericBookmarkCount: pendingUpload.upsertedGenericBookmarkCount,
            upsertedStudyPadEntryCount: pendingUpload.upsertedStudyPadEntryCount,
            upsertedAuxiliaryRowCount: pendingUpload.upsertedAuxiliaryRowCount,
            deletedRowCount: pendingUpload.deletedRowCount,
            logEntryCount: pendingUpload.logEntryCount,
            lastUpdated: pendingUpload.timestamp
        )
    }

    /**
     Invalidates a destination-bound outbox only after explicit lifecycle replacement cleanup.

     Removing the pending generation leaves current rows dirty against the unchanged accepted baseline.

     - Parameters:
       - pendingUpload: Destination-bound generation to discard.
       - modelContext: Clean shared context.
       - settingsStore: Store containing the pending manifest.
     - Side effects: Atomically removes only the pending manifest, then best-effort removes its archive.
     - Failure modes: Rethrows manifest validation or transaction failures without deleting the archive.
     */
    private func invalidatePendingUpload(
        _ pendingUpload: PendingUpload,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws {
        try settingsStore.performAtomicBatch(in: modelContext) {
            guard try loadPendingUpload(settingsStore: settingsStore) == pendingUpload else {
                throw RemoteSyncBookmarkPatchUploadError.invalidPendingUpload
            }
            settingsStore.remove(Self.pendingUploadKey)
        }
        if let archiveURL = try? pendingArchiveURL(for: pendingUpload) {
            try? fileManager.removeItem(at: archiveURL)
        }
    }

    /** Reads and decodes the pending bookmark upload manifest from local settings. */
    private func loadPendingUpload(settingsStore: SettingsStore) throws -> PendingUpload? {
        guard let payload = settingsStore.getString(Self.pendingUploadKey) else { return nil }
        guard let data = payload.data(using: .utf8),
              let pendingUpload = try? JSONDecoder().decode(PendingUpload.self, from: data) else {
            throw RemoteSyncBookmarkPatchUploadError.invalidPendingUpload
        }
        guard let publicationIdentity = pendingUpload.publicationIdentity else {
            throw RemoteSyncBookmarkPatchUploadError.invalidPendingUpload
        }
        var acceptancePayload = pendingUpload
        acceptancePayload.publicationIdentity = nil
        do {
            try publicationIdentity.validate(
                kind: .patch,
                category: .bookmarks,
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
            throw RemoteSyncBookmarkPatchUploadError.invalidPendingUpload
        }
        return pendingUpload
    }

    /**
     Returns the complete named operation counts bound to one bookmark publication.

     - Parameter pendingUpload: Identity-free or decoded bookmark outbox envelope.
     - Returns: Nonempty deterministic count dictionary covering all bookmark patch row families.
     - Side effects: none.
     - Failure modes: This projection cannot fail.
     */
    private static func publicationRowCounts(for pendingUpload: PendingUpload) -> [String: Int] {
        [
            "labels": pendingUpload.upsertedLabelCount,
            "bibleBookmarks": pendingUpload.upsertedBibleBookmarkCount,
            "genericBookmarks": pendingUpload.upsertedGenericBookmarkCount,
            "studyPadEntries": pendingUpload.upsertedStudyPadEntryCount,
            "auxiliaryRows": pendingUpload.upsertedAuxiliaryRowCount,
            "deletions": pendingUpload.deletedRowCount,
            "logEntries": pendingUpload.logEntryCount
        ]
    }

    /** Encodes and stores one complete pending bookmark upload manifest. */
    private func storePendingUpload(_ pendingUpload: PendingUpload, settingsStore: SettingsStore) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pendingUpload)
        guard let payload = String(data: data, encoding: .utf8) else {
            throw RemoteSyncBookmarkPatchUploadError.invalidPendingUpload
        }
        settingsStore.setString(Self.pendingUploadKey, value: payload)
    }

    /** Resolves a pending archive basename beneath the configured durable outbox directory. */
    private func pendingArchiveURL(for pendingUpload: PendingUpload) throws -> URL {
        guard pendingUpload.archiveFileName == URL(fileURLWithPath: pendingUpload.archiveFileName).lastPathComponent,
              !pendingUpload.archiveFileName.isEmpty else {
            throw RemoteSyncBookmarkPatchUploadError.invalidPendingUpload
        }
        return outboxDirectory.appendingPathComponent(pendingUpload.archiveFileName, isDirectory: false)
    }

    /**
     Reads the highest Android patch number already present in one bookmark device folder.

     - Parameter deviceFolderID: Active remote device-folder identifier.
     - Returns: Highest valid Android patch number, or zero when the folder has no patch archives.
     - Side effects: Performs one unfiltered remote folder listing.
     - Failure modes: Rethrows backend listing failures so fresh generation creation fails closed.
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

    /** Resolves the production bookmark outbox beneath Application Support. */
    static func defaultOutboxDirectory(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root
            .appendingPathComponent("AndBible", isDirectory: true)
            .appendingPathComponent("RemoteSyncOutbox", isDirectory: true)
            .appendingPathComponent("bookmarks", isDirectory: true)
    }

    /**
     Computes the sparse Android row diff for the current bookmark snapshot.

     - Parameters:
       - snapshot: Current local bookmark state projected into Android-shaped rows.
       - existingEntriesByKey: Existing Android `LogEntry` baseline keyed by Android composite key.
       - acceptedRowsByKey: Durable accepted identities, including rows from initial backups that had no log entry.
       - fingerprintStore: Local fingerprint store used to compare current rows against the last uploaded baseline.
       - timestamp: Millisecond timestamp to assign to any emitted outbound `LogEntry` rows.
       - sourceDevice: Local source-device folder name that should own the outbound patch rows.
     - Returns: Sparse change set containing upserted rows, delete entries, and the updated local metadata baseline.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func buildChangeSet(
        snapshot: RemoteSyncBookmarkCurrentSnapshot,
        existingEntriesByKey: [String: RemoteSyncLogEntry],
        acceptedRowsByKey: [String: RemoteSyncBookmarkAcceptedRowIdentity],
        fingerprintStore: RemoteSyncRowFingerprintStore,
        pendingMutations: [String: RemoteSyncPendingMutation],
        timestamp: Int64,
        sourceDevice: String
    ) throws -> ChangeSet {
        var labelRowsByKey: [String: RemoteSyncAndroidLabel] = [:]
        var bibleBookmarkRowsByKey: [String: RemoteSyncAndroidBibleBookmark] = [:]
        var bibleNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow] = [:]
        var bibleLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow] = [:]
        var genericBookmarkRowsByKey: [String: RemoteSyncAndroidGenericBookmark] = [:]
        var genericNoteRowsByKey: [String: RemoteSyncCurrentBookmarkNoteRow] = [:]
        var genericLinkRowsByKey: [String: RemoteSyncCurrentBookmarkLabelLinkRow] = [:]
        var studyPadEntryRowsByKey: [String: RemoteSyncAndroidStudyPadEntry] = [:]
        var studyPadTextRowsByKey: [String: RemoteSyncCurrentStudyPadTextRow] = [:]
        var logEntries: [RemoteSyncLogEntry] = []
        var updatedEntriesByKey = existingEntriesByKey

        func upsertEntry(
            key: String,
            tableName: String,
            entityID1: RemoteSyncSQLiteValue,
            entityID2: RemoteSyncSQLiteValue
        ) throws -> RemoteSyncLogEntry {
            try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: snapshot.fingerprintsByKey[key],
                type: .upsert,
                category: .bookmarks,
                pendingMutations: pendingMutations
            ) ?? RemoteSyncLogEntry(
                tableName: tableName,
                entityID1: entityID1,
                entityID2: entityID2,
                type: .upsert,
                lastUpdated: timestamp,
                sourceDevice: sourceDevice
            )
        }

        for (key, row) in snapshot.labelRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try upsertEntry(
                key: key,
                tableName: "Label",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.id)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
            labelRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.bibleBookmarkRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try upsertEntry(
                key: key,
                tableName: "BibleBookmark",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.id)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
            bibleBookmarkRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.bibleNoteRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try upsertEntry(
                key: key,
                tableName: "BibleBookmarkNotes",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.bookmarkID)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
            bibleNoteRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.bibleLinkRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try upsertEntry(
                key: key,
                tableName: "BibleBookmarkToLabel",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.bookmarkID)),
                entityID2: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.labelID))
            )
            bibleLinkRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.genericBookmarkRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try upsertEntry(
                key: key,
                tableName: "GenericBookmark",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.id)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
            genericBookmarkRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.genericNoteRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try upsertEntry(
                key: key,
                tableName: "GenericBookmarkNotes",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.bookmarkID)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
            genericNoteRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.genericLinkRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try upsertEntry(
                key: key,
                tableName: "GenericBookmarkToLabel",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.bookmarkID)),
                entityID2: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.labelID))
            )
            genericLinkRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.studyPadEntryRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try upsertEntry(
                key: key,
                tableName: "StudyPadTextEntry",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.id)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
            studyPadEntryRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        for (key, row) in snapshot.studyPadTextRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard shouldUploadCurrentRow(
                key: key,
                currentFingerprint: snapshot.fingerprintsByKey[key],
                existingEntriesByKey: existingEntriesByKey,
                fingerprintStore: fingerprintStore
            ) else {
                continue
            }
            let entry = try upsertEntry(
                key: key,
                tableName: "StudyPadTextEntryText",
                entityID1: .blob(RemoteSyncBookmarkSnapshotService.uuidBlob(row.entryID)),
                entityID2: AndroidBookmarkDatabaseContract.emptySecondaryEntityID
            )
            studyPadTextRowsByKey[key] = row
            logEntries.append(entry)
            updatedEntriesByKey[key] = entry
        }

        var deletionRowsByKey = acceptedRowsByKey
        for (key, mutation) in pendingMutations where mutation.entry.type == .delete {
            deletionRowsByKey[key] = RemoteSyncBookmarkAcceptedRowIdentity(
                key: key,
                tableName: mutation.entry.tableName,
                entityID1: mutation.entry.entityID1,
                entityID2: mutation.entry.entityID2
            )
        }
        for (key, identity) in deletionRowsByKey.sorted(by: { $0.key < $1.key }) {
            guard !snapshot.suppressedKeys.contains(key) else {
                continue
            }
            guard snapshot.fingerprintsByKey[key] == nil else {
                continue
            }
            guard existingEntriesByKey[key]?.type != .delete || pendingMutations[key] != nil else {
                continue
            }
            let deleteEntry = try RemoteSyncMutationJournalService().entryForUpload(
                key: key,
                stateFingerprint: nil,
                type: .delete,
                category: .bookmarks,
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
            labelRowsByKey: labelRowsByKey,
            bibleBookmarkRowsByKey: bibleBookmarkRowsByKey,
            bibleNoteRowsByKey: bibleNoteRowsByKey,
            bibleLinkRowsByKey: bibleLinkRowsByKey,
            genericBookmarkRowsByKey: genericBookmarkRowsByKey,
            genericNoteRowsByKey: genericNoteRowsByKey,
            genericLinkRowsByKey: genericLinkRowsByKey,
            studyPadEntryRowsByKey: studyPadEntryRowsByKey,
            studyPadTextRowsByKey: studyPadTextRowsByKey,
            logEntries: logEntries.sorted(by: Self.logEntrySort),
            updatedEntriesByKey: updatedEntriesByKey
        )
    }

    /**
     Returns whether one current snapshot row should be emitted as an outbound `UPSERT`.

     A missing fingerprint is upload-needed even when the row already has a preserved non-delete
     Android `LogEntry`. Without a trusted content baseline, treating the row as unchanged could
     silently omit a local edit.

     - Parameters:
       - key: Android composite key for the row.
       - currentFingerprint: Current stable row fingerprint, if one was computed.
       - existingEntriesByKey: Existing Android `LogEntry` baseline keyed by Android composite key.
       - fingerprintStore: Local fingerprint store used to read the prior baseline for the row.
     - Returns: `true` when the row should be emitted as an outbound upsert.
     - Side effects: reads preserved local fingerprint rows from `SettingsStore`.
     - Failure modes: This helper cannot fail.
     */
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
                category: .bookmarks
            ) {
                return existingFingerprint != currentFingerprint
            }
            return true
        }

        if existingEntry.type == .delete {
            return true
        }

        let existingFingerprint = fingerprintStore.fingerprint(
            for: .bookmarks,
            tableName: existingEntry.tableName,
            entityID1: existingEntry.entityID1,
            entityID2: existingEntry.entityID2
        )
        guard let existingFingerprint else { return true }
        return existingFingerprint != currentFingerprint
    }

    /**
     Writes one sparse Android bookmark patch database to the supplied SQLite URL.

     - Parameters:
       - url: Temporary SQLite file URL to create.
       - schemaVersion: SQLite user version that should be written to the patch database.
       - changeSet: Sparse current-row diff that should be serialized.
     - Side effects:
       - creates and writes a temporary SQLite database file
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase` when the file cannot be opened for writing
       - rethrows SQLite execution failures from schema creation or row inserts
     */
    private func writePatchDatabase(
        at url: URL,
        schemaVersion: Int,
        changeSet: ChangeSet
    ) throws {
        guard schemaVersion == AndroidBookmarkDatabaseContract.schemaVersion else {
            throw RemoteSyncBookmarkPatchUploadError.unsupportedSchemaVersion(schemaVersion)
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
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        try execute(AndroidBookmarkDatabaseContract.createSchemaSQL, in: database)

        for row in changeSet.labelRowsByKey.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try insertLabelRow(row, in: database)
        }
        for row in changeSet.bibleBookmarkRowsByKey.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try insertBibleBookmarkRow(row, in: database)
        }
        for row in changeSet.bibleNoteRowsByKey.values.sorted(by: { $0.bookmarkID.uuidString < $1.bookmarkID.uuidString }) {
            try insertBookmarkNoteRow(row, tableName: "BibleBookmarkNotes", in: database)
        }
        for row in changeSet.bibleLinkRowsByKey.values.sorted(by: Self.labelLinkSort) {
            try insertBookmarkLabelLinkRow(row, tableName: "BibleBookmarkToLabel", in: database)
        }
        for row in changeSet.genericBookmarkRowsByKey.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try insertGenericBookmarkRow(row, in: database)
        }
        for row in changeSet.genericNoteRowsByKey.values.sorted(by: { $0.bookmarkID.uuidString < $1.bookmarkID.uuidString }) {
            try insertBookmarkNoteRow(row, tableName: "GenericBookmarkNotes", in: database)
        }
        for row in changeSet.genericLinkRowsByKey.values.sorted(by: Self.labelLinkSort) {
            try insertBookmarkLabelLinkRow(row, tableName: "GenericBookmarkToLabel", in: database)
        }
        for row in changeSet.studyPadEntryRowsByKey.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            try insertStudyPadEntryRow(row, in: database)
        }
        for row in changeSet.studyPadTextRowsByKey.values.sorted(by: { $0.entryID.uuidString < $1.entryID.uuidString }) {
            try insertStudyPadTextRow(row, in: database)
        }
        for entry in changeSet.logEntries {
            try insertLogEntry(entry, in: database)
        }
    }

    /**
     Inserts one Android `Label` row into the open patch database.

     - Parameters:
       - row: Android-shaped label row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `Label` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertLabelRow(_ row: RemoteSyncAndroidLabel, in database: OpaquePointer) throws {
        let sql = "INSERT INTO Label (id, name, color, markerStyle, markerStyleWholeVerse, underlineStyle, underlineStyleWholeVerse, hideStyle, hideStyleWholeVerse, favourite, type, customIcon) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, row.name, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        Self.bindAndroidSignedInt32(row.color, to: statement, index: 3)
        sqlite3_bind_int(statement, 4, row.markerStyle ? 1 : 0)
        sqlite3_bind_int(statement, 5, row.markerStyleWholeVerse ? 1 : 0)
        sqlite3_bind_int(statement, 6, row.underlineStyle ? 1 : 0)
        sqlite3_bind_int(statement, 7, row.underlineStyleWholeVerse ? 1 : 0)
        sqlite3_bind_int(statement, 8, row.hideStyle ? 1 : 0)
        sqlite3_bind_int(statement, 9, row.hideStyleWholeVerse ? 1 : 0)
        sqlite3_bind_int(statement, 10, row.favourite ? 1 : 0)
        Self.bindOptionalText(row.type, to: statement, index: 11)
        Self.bindOptionalText(row.customIcon, to: statement, index: 12)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `BibleBookmark` row into the open patch database.

     - Parameters:
       - row: Android-shaped Bible bookmark row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `BibleBookmark` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertBibleBookmarkRow(_ row: RemoteSyncAndroidBibleBookmark, in database: OpaquePointer) throws {
        let sql = "INSERT INTO BibleBookmark (kjvOrdinalStart, kjvOrdinalEnd, ordinalStart, ordinalEnd, v11n, playbackSettings, id, createdAt, book, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, type, customIcon, sourcePromptId, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(row.kjvOrdinalStart))
        sqlite3_bind_int(statement, 2, Int32(row.kjvOrdinalEnd))
        sqlite3_bind_int(statement, 3, Int32(row.ordinalStart))
        sqlite3_bind_int(statement, 4, Int32(row.ordinalEnd))
        sqlite3_bind_text(statement, 5, row.v11n, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        Self.bindOptionalText(row.playbackSettingsJSON, to: statement, index: 6)
        Self.bindUUIDBlob(row.id, to: statement, index: 7)
        sqlite3_bind_int64(statement, 8, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        Self.bindOptionalText(row.book, to: statement, index: 9)
        Self.bindOptionalInt(row.startOffset, to: statement, index: 10)
        Self.bindOptionalInt(row.endOffset, to: statement, index: 11)
        Self.bindOptionalUUIDBlob(row.primaryLabelID, to: statement, index: 12)
        sqlite3_bind_int64(statement, 13, Int64(row.lastUpdatedOn.timeIntervalSince1970 * 1000.0))
        sqlite3_bind_int(statement, 14, row.wholeVerse ? 1 : 0)
        Self.bindOptionalText(row.type, to: statement, index: 15)
        Self.bindOptionalText(row.customIcon, to: statement, index: 16)
        Self.bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 17)
        Self.bindOptionalText(row.editAction?.mode?.rawValue, to: statement, index: 18)
        Self.bindOptionalText(row.editAction?.content, to: statement, index: 19)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one detached bookmark-note row into the open patch database.

     - Parameters:
       - row: Android-shaped bookmark-note row to insert.
       - tableName: Either `BibleBookmarkNotes` or `GenericBookmarkNotes`.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the supplied note table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertBookmarkNoteRow(
        _ row: RemoteSyncCurrentBookmarkNoteRow,
        tableName: String,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO \(tableName) (bookmarkId, notes, contentType, sourcePromptId) VALUES (?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.bookmarkID, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, row.notes, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        Self.bindOptionalText(row.contentType, to: statement, index: 3)
        Self.bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 4)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one bookmark-to-label junction row into the open patch database.

     - Parameters:
       - row: Android-shaped bookmark-to-label row to insert.
       - tableName: Either `BibleBookmarkToLabel` or `GenericBookmarkToLabel`.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the supplied junction table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertBookmarkLabelLinkRow(
        _ row: RemoteSyncCurrentBookmarkLabelLinkRow,
        tableName: String,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO \(tableName) (bookmarkId, labelId, orderNumber, indentLevel, expandContent) VALUES (?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.bookmarkID, to: statement, index: 1)
        Self.bindUUIDBlob(row.labelID, to: statement, index: 2)
        sqlite3_bind_int(statement, 3, Int32(row.orderNumber))
        sqlite3_bind_int(statement, 4, Int32(row.indentLevel))
        sqlite3_bind_int(statement, 5, row.expandContent ? 1 : 0)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `GenericBookmark` row into the open patch database.

     - Parameters:
       - row: Android-shaped generic bookmark row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `GenericBookmark` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertGenericBookmarkRow(_ row: RemoteSyncAndroidGenericBookmark, in database: OpaquePointer) throws {
        let sql = "INSERT INTO GenericBookmark (id, `key`, createdAt, bookInitials, ordinalStart, ordinalEnd, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, playbackSettings, customIcon, sourcePromptId, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.id, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, row.key, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        sqlite3_bind_int64(statement, 3, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        sqlite3_bind_text(statement, 4, row.bookInitials, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        Self.bindOptionalInt(row.ordinalStart, to: statement, index: 5)
        Self.bindOptionalInt(row.ordinalEnd, to: statement, index: 6)
        Self.bindOptionalInt(row.startOffset, to: statement, index: 7)
        Self.bindOptionalInt(row.endOffset, to: statement, index: 8)
        Self.bindOptionalUUIDBlob(row.primaryLabelID, to: statement, index: 9)
        sqlite3_bind_int64(statement, 10, Int64(row.lastUpdatedOn.timeIntervalSince1970 * 1000.0))
        sqlite3_bind_int(statement, 11, row.wholeVerse ? 1 : 0)
        Self.bindOptionalText(row.playbackSettingsJSON, to: statement, index: 12)
        Self.bindOptionalText(row.customIcon, to: statement, index: 13)
        Self.bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 14)
        Self.bindOptionalText(row.editAction?.mode?.rawValue, to: statement, index: 15)
        Self.bindOptionalText(row.editAction?.content, to: statement, index: 16)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `StudyPadTextEntry` row into the open patch database.

     - Parameters:
       - row: Android-shaped StudyPad entry row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `StudyPadTextEntry` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertStudyPadEntryRow(_ row: RemoteSyncAndroidStudyPadEntry, in database: OpaquePointer) throws {
        let sql = "INSERT INTO StudyPadTextEntry (id, labelId, orderNumber, indentLevel, contentType, sourcePromptId) VALUES (?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.id, to: statement, index: 1)
        Self.bindUUIDBlob(row.labelID, to: statement, index: 2)
        sqlite3_bind_int(statement, 3, Int32(row.orderNumber))
        sqlite3_bind_int(statement, 4, Int32(row.indentLevel))
        Self.bindOptionalText(row.contentType, to: statement, index: 5)
        Self.bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 6)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `StudyPadTextEntryText` row into the open patch database.

     - Parameters:
       - row: Android-shaped StudyPad text row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `StudyPadTextEntryText` table.
     - Failure modes:
       - rethrows SQLite prepare, bind, or step failures
     */
    private func insertStudyPadTextRow(_ row: RemoteSyncCurrentStudyPadTextRow, in database: OpaquePointer) throws {
        let sql = "INSERT INTO StudyPadTextEntryText (studyPadTextEntryId, text) VALUES (?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        Self.bindUUIDBlob(row.entryID, to: statement, index: 1)
        sqlite3_bind_text(statement, 2, row.text, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
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
    private func insertLogEntry(_ entry: RemoteSyncLogEntry, in database: OpaquePointer) throws {
        let sql = "INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice) VALUES (?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, entry.tableName, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        Self.bindSQLiteValue(entry.entityID1, to: statement, index: 2)
        Self.bindSQLiteValue(entry.entityID2, to: statement, index: 3)
        sqlite3_bind_text(statement, 4, entry.type.rawValue, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        sqlite3_bind_text(statement, 6, entry.sourceDevice, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Executes one schema or pragma SQL batch against the open patch database.

     - Parameters:
       - sql: SQL batch to execute.
       - database: Open SQLite database handle.
     - Side effects: mutates the open SQLite database schema or metadata.
     - Failure modes:
       - throws `RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase` when SQLite rejects the statement batch
     */
    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncBookmarkPatchUploadError.invalidSQLiteDatabase
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
     Binds one required UUID into a prepared SQLite statement parameter as Android's raw 16-byte blob.

     - Parameters:
       - uuid: UUID to bind.
       - statement: Prepared SQLite statement receiving the value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
        let data = RemoteSyncBookmarkSnapshotService.uuidBlob(uuid)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(data.count),
                remoteSyncBookmarkPatchUploadSQLiteTransient
            )
        }
    }

    /**
     Binds one optional UUID into a prepared SQLite statement parameter.

     - Parameters:
       - uuid: Optional UUID to bind.
       - statement: Prepared SQLite statement receiving the value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalUUIDBlob(_ uuid: UUID?, to statement: OpaquePointer?, index: Int32) {
        guard let uuid else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindUUIDBlob(uuid, to: statement, index: index)
    }

    /**
     Binds one optional text value into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional text payload to bind.
       - statement: Prepared SQLite statement receiving the value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, remoteSyncBookmarkPatchUploadSQLiteTransient)
    }

    /**
     Binds one optional integer value into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional integer payload to bind.
       - statement: Prepared SQLite statement receiving the value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private static func bindOptionalInt(_ value: Int?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(value))
    }

    /**
     Binds an Android signed 32-bit color while preserving a wider Swift integer's low-bit pattern.

     Android stores ARGB colors as signed `Int` values. Swift can retain the same bit pattern as a
     positive 64-bit `Int`, where a checked `Int32` conversion would trap during patch generation.

     - Parameters:
       - value: Android color value whose low 32 bits are authoritative.
       - statement: Prepared SQLite statement receiving the value.
       - index: One-based SQLite bind parameter index.
     - Side effects: binds one integer parameter onto `statement`.
     - Failure modes: This helper cannot fail; SQLite step errors are checked by the caller.
     */
    private static func bindAndroidSignedInt32(
        _ value: Int,
        to statement: OpaquePointer?,
        index: Int32
    ) {
        sqlite3_bind_int(statement, index, Int32(bitPattern: UInt32(truncatingIfNeeded: value)))
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
            sqlite3_bind_text(
                statement,
                index,
                value.textValue ?? "",
                -1,
                remoteSyncBookmarkPatchUploadSQLiteTransient
            )
        case .blob:
            let data = value.blobData ?? Data()
            _ = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    index,
                    bytes.baseAddress,
                    Int32(data.count),
                    remoteSyncBookmarkPatchUploadSQLiteTransient
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
     Sorts bookmark-to-label rows into a deterministic order for patch serialization.

     - Parameters:
       - lhs: First bookmark-to-label row to compare.
       - rhs: Second bookmark-to-label row to compare.
     - Returns: `true` when `lhs` should appear before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func labelLinkSort(
        _ lhs: RemoteSyncCurrentBookmarkLabelLinkRow,
        _ rhs: RemoteSyncCurrentBookmarkLabelLinkRow
    ) -> Bool {
        if lhs.bookmarkID == rhs.bookmarkID {
            if lhs.orderNumber == rhs.orderNumber {
                return lhs.labelID.uuidString < rhs.labelID.uuidString
            }
            return lhs.orderNumber < rhs.orderNumber
        }
        return lhs.bookmarkID.uuidString < rhs.bookmarkID.uuidString
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
