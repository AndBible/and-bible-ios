// RemoteSyncInitialBackupUploadService.swift — Full initial-backup export and upload for remote sync

import Foundation
import SQLite3
import SwiftData

private let remoteSyncInitialBackupUploadSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/**
 Errors raised while building or uploading Android-style initial backups.
 */
public enum RemoteSyncInitialBackupUploadError: Error, Equatable {
    /// The category is not bootstrapped with a remote sync-folder identifier yet.
    case missingSyncFolderID

    /// One JSON-backed Android column could not be serialized safely.
    case jsonEncodingFailed(field: String)

    /// The temporary SQLite database could not be opened or written safely.
    case invalidSQLiteDatabase

    /// A built outbound database does not satisfy the exact inbound Android Room contract.
    case invalidBuiltDatabaseContract(RemoteSyncCategory)

    /// Upload was requested from a builder-only service that has no remote backend.
    case missingRemoteAdapter

    /// The requested category does not yet have an initial-backup export pipeline.
    case unsupportedCategory(RemoteSyncCategory)

    /// Bookmark initial backups must use Android Room bookmark schema version 12 exactly.
    case unsupportedBookmarkSchemaVersion(Int)

    /// A category export requested a schema other than the exact Android Room contract this build supports.
    case unsupportedSchemaVersion(category: RemoteSyncCategory, version: Int)

    /// A durable prepared-upload archive or its exact acceptance metadata was missing or corrupted.
    case invalidPendingUploadArtifact

    /// A durable prepared upload belongs to another explicit bootstrap generation.
    case pendingUploadDestinationMismatch

    /// Android database sync cannot reconstruct active device-local custom plan definitions.
    case unsupportedCustomReadingPlans([String])
}

/**
 Summary of one successful Android-style initial-backup upload.

 Android treats the initial backup as patch zero for a category. The uploaded archive itself is not
 an incremental patch, but local patch-status bookkeeping records it so later discovery logic can
 skip the already accepted baseline.
 */
public struct RemoteSyncInitialBackupUploadReport: Sendable, Equatable {
    /// Logical sync category whose full baseline was uploaded.
    public let category: RemoteSyncCategory

    /// Remote file descriptor returned by the backend for the uploaded initial archive.
    public let uploadedFile: RemoteSyncFile

    /// Patch-zero status recorded locally after the upload succeeds.
    public let patchZeroStatus: RemoteSyncPatchStatus

    /**
     Creates one initial-backup upload summary.

     - Parameters:
       - category: Logical sync category whose full baseline was uploaded.
       - uploadedFile: Remote file descriptor returned by the backend for the uploaded initial archive.
       - patchZeroStatus: Patch-zero status recorded locally after the upload succeeds.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        category: RemoteSyncCategory,
        uploadedFile: RemoteSyncFile,
        patchZeroStatus: RemoteSyncPatchStatus
    ) {
        self.category = category
        self.uploadedFile = uploadedFile
        self.patchZeroStatus = patchZeroStatus
    }
}

/**
 Builds and uploads full Android-shaped category databases as `initial.sqlite3.gz` archives.

 Android's "copy this device to cloud" branch creates a brand-new remote sync folder, uploads a
 full category database as `initial.sqlite3.gz`, records patch zero locally, and then continues
 with normal ready-state synchronization. iOS needs the same export path so the NextCloud/WebDAV
 flow can mirror Android's bootstrap semantics instead of inventing a patch-only baseline.

 Data dependencies:
 - `RemoteSyncAdapting` uploads the compressed initial-backup archive
 - category snapshot services project live SwiftData rows into Android-shaped tables
 - the reading-plan snapshot service rejects active custom plans because Android syncs only Room
   rows and cannot reconstruct device-local `.properties` files
 - `RemoteSyncPatchStatusStore`, `RemoteSyncStateStore`, and category snapshot services persist the
   accepted local baseline after upload
 - `RemoteSyncWorkspaceFidelityStore` preserves Android history aliases for synthesized workspace
   history rows

 Side effects:
 - creates temporary SQLite and gzip files beneath the configured temporary directory
 - rejects active custom reading plans before exporting the reading-plan category
 - uploads one `initial.sqlite3.gz` archive into the category sync folder
 - clears category-scoped `LogEntry` bookkeeping, publishes the exact accepted-row identity manifest,
   clears prior `SyncStatus` rows, and records patch zero
 - resets category progress bookkeeping before the next ready-state synchronization pass
 - refreshes outbound fingerprint baselines so the uploaded initial state is not re-emitted as a
   sparse patch immediately afterwards
 - may rewrite workspace history aliases when the workspace category synthesizes Android history ids

 Failure modes:
 - throws `RemoteSyncInitialBackupUploadError.missingSyncFolderID` when bootstrap state is incomplete
 - throws `RemoteSyncInitialBackupUploadError.jsonEncodingFailed` when one Android JSON payload cannot be serialized
 - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects schema or row writes
 - rethrows strict graph/history snapshot and deferred settings-read failures without uploading an
   incomplete baseline
 - throws `unsupportedCustomReadingPlans` before transport because Android database sync cannot
   carry an active custom plan's local definition file
 - rethrows transport failures from the backend adapter
 - rethrows filesystem read and write failures while staging the temporary archive
 - rethrows gzip-compression failures from `RemoteSyncArchiveStagingService`
 - local acceptance failures roll back patch zero, progress, fingerprints, aliases, and any joined
   lifecycle mutation as one generation

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement rules of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncInitialBackupUploadService {
    /** Immutable fingerprint and accepted-row generation captured before network suspension. */
    private enum AcceptedFingerprintGeneration: Codable {
        case readingPlans(RemoteSyncReadingPlanAcceptedGeneration)
        case bookmarks(RemoteSyncBookmarkAcceptedBaseline)
        case workspaces(RemoteSyncWorkspaceAcceptedGeneration)
        case myDocuments(RemoteSyncMyDocumentAcceptedBaseline)
        case progress(RemoteSyncProgressAcceptedGeneration)
    }

    /** Codable workspace-history alias retained with a durable initial-upload retry. */
    private struct StoredWorkspaceHistoryAlias: Codable {
        let remoteHistoryItemID: Int64
        let localHistoryItemID: UUID

        init(_ alias: RemoteSyncWorkspaceFidelityStore.HistoryItemAlias) {
            remoteHistoryItemID = alias.remoteHistoryItemID
            localHistoryItemID = alias.localHistoryItemID
        }

        var runtimeValue: RemoteSyncWorkspaceFidelityStore.HistoryItemAlias {
            RemoteSyncWorkspaceFidelityStore.HistoryItemAlias(
                remoteHistoryItemID: remoteHistoryItemID,
                localHistoryItemID: localHistoryItemID
            )
        }
    }

    /** Exact local metadata that must be accepted only after its matching archive uploads. */
    private struct AcceptedInitialBackup: Codable {
        let timestamp: Int64
        let fingerprintGeneration: AcceptedFingerprintGeneration
        let workspaceHistoryAliases: [StoredWorkspaceHistoryAlias]
    }

    /** Durable descriptor for one prepared initial archive and its exact acceptance generation. */
    private struct PendingInitialUploadMetadata: Codable {
        let categoryRawValue: String
        let syncFolderID: String
        let deviceFolderID: String?
        let schemaVersion: Int
        let archiveSize: Int64
        let archiveSHA256: String
        let acceptedInitialBackup: AcceptedInitialBackup
        var publicationIdentity: RemoteSyncPublicationIdentity?
    }

    /** Prepared archive reused across transport or post-upload local-acceptance retries. */
    private struct PendingInitialUpload {
        let archiveURL: URL
        let metadata: PendingInitialUploadMetadata
    }

    /** Category represented by one immutable accepted fingerprint generation. */
    private static func category(
        for generation: AcceptedFingerprintGeneration
    ) -> RemoteSyncCategory {
        switch generation {
        case .readingPlans:
            return .readingPlans
        case .bookmarks:
            return .bookmarks
        case .workspaces:
            return .workspaces
        case .myDocuments:
            return .myDocuments
        case .progress:
            return .progress
        }
    }

    /**
     Carries the staged database and any category-specific bookkeeping needed after upload acceptance.

     - Parameters:
       - databaseURL: Temporary SQLite database that will be archived and uploaded.
       - acceptedInitialBackup: Exact fingerprints, row identities, timestamp, and side metadata
         projected in the same strict read batch as `databaseURL`.
     - Side effects: none.
     - Failure modes: This value type cannot fail to initialize.
     */
    private struct BuiltInitialBackup {
        let databaseURL: URL
        let acceptedInitialBackup: AcceptedInitialBackup

        init(
            databaseURL: URL,
            acceptedInitialBackup: AcceptedInitialBackup
        ) {
            self.databaseURL = databaseURL
            self.acceptedInitialBackup = acceptedInitialBackup
        }
    }

    private let adapter: (any RemoteSyncAdapting)?
    private let deviceIdentifier: String
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let retryDirectory: URL
    private let nowProvider: () -> Int64
    private let readingPlanSnapshotService: RemoteSyncReadingPlanSnapshotService

    /**
     Creates an initial-backup upload service for one remote backend.

     - Parameters:
       - adapter: Remote backend adapter used for initial-backup uploads.
       - deviceIdentifier: Stable device identifier used for patch-zero bookkeeping.
       - readingPlanSnapshotService: Snapshot service bound to this device's custom-plan directory.
       - userPlanDirectory: Local custom-definition directory used by snapshot recovery.
       - fileManager: File manager used for temporary staging and cleanup.
       - temporaryDirectory: Optional staging directory override.
       - retryDirectory: Optional durable prepared-upload directory override used by tests.
       - nowProvider: Optional millisecond clock used for local sync bookkeeping resets. The
         Android-compatible runtime clock is selected inside the initializer when omitted.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        deviceIdentifier: String,
        readingPlanSnapshotService: RemoteSyncReadingPlanSnapshotService? = nil,
        userPlanDirectory: URL = ReadingPlanService.defaultUserReadingPlanDirectory(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        retryDirectory: URL? = nil,
        nowProvider: (() -> Int64)? = nil
    ) {
        self.adapter = adapter
        self.deviceIdentifier = deviceIdentifier
        self.readingPlanSnapshotService = readingPlanSnapshotService
            ?? RemoteSyncReadingPlanSnapshotService(
                userPlanDirectory: userPlanDirectory,
                fileManager: fileManager
            )
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.retryDirectory = retryDirectory
            ?? Self.defaultRetryDirectory(fileManager: fileManager)
        self.nowProvider = nowProvider ?? {
            AndroidTimestamp.currentMilliseconds()
        }
    }

    /**
     Creates a builder-only service for local Android-compatible database export.

     Manual Android database backup export reuses the same category SQLite writers as remote sync,
     but it must not upload, record patch-zero state, or persist workspace history aliases. This
     initializer keeps that export path local while sharing the schema and row projection logic.

     - Parameters:
       - fileManager: File manager used for temporary SQLite output.
       - temporaryDirectory: Optional staging directory override.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    private init(
        fileManager: FileManager,
        temporaryDirectory: URL?
    ) {
        adapter = nil
        deviceIdentifier = "manual-database-backup-export"
        readingPlanSnapshotService = RemoteSyncReadingPlanSnapshotService(fileManager: fileManager)
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        retryDirectory = self.temporaryDirectory
        nowProvider = {
            AndroidTimestamp.currentMilliseconds()
        }
    }

    /**
     Builds one local Android-shaped SQLite database without remote-sync side effects.

     - Parameters:
       - category: Logical category whose current local state should be exported.
       - modelContext: SwiftData context that owns the current local category graph.
       - settingsStore: Local-only settings store backing Android fidelity metadata.
       - schemaVersion: SQLite `user_version` written into the exported Android database.
       - fileManager: File manager used for temporary SQLite output.
       - temporaryDirectory: Optional staging directory override.
     - Returns: Temporary SQLite database URL; the caller owns cleanup.
     - Side effects:
       - captures graph and settings through the same strict read batch used by remote initial upload
       - writes one temporary SQLite database beneath the configured temporary directory
       - for manual bookmark backups, copies normalized local Android `LogEntry` metadata into the
         exported database so a later Import can enforce Android's timestamp conflict rules
     - Failure modes: Rethrows dirty/mismatched context, strict graph/history fetch, deferred
       settings-read, cancellation, SQLite, and JSON-encoding failures; shared builder failures
       remove any temporary database they created.
     */
    static func buildAndroidDatabaseBackupDatabase(
        for category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int,
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) throws -> URL {
        let service = RemoteSyncInitialBackupUploadService(
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        )
        let built = try service.buildInitialBackup(
            for: category,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion
        )
        if category == .bookmarks {
            try service.appendManualBookmarkLogEntries(
                to: built.databaseURL,
                settingsStore: settingsStore
            )
        }
        return built.databaseURL
    }

    /**
     Copies the retained bookmark conflict baseline into a manual Android database backup.

     Android's manual backup copies the live Room file after checkpointing it, so its `LogEntry`
     rows travel with the bookmark data. iOS stores those rows outside SwiftData and must append
     them explicitly. Legacy iOS `NULL` secondary keys are normalized to Android's empty-text key,
     and rows that collide after normalization retain the deterministic latest entry.

     - Parameters:
       - databaseURL: Writable Android Room-v12 bookmark database produced by the shared builder.
       - settingsStore: Local settings store containing retained bookmark `LogEntry` rows.
     - Side effects: opens and writes the exported SQLite database in one transaction.
     - Failure modes: Throws `invalidSQLiteDatabase` when SQLite cannot open the database or
       rejects a normalized log row.
     - Note: Remote initial-backup upload does not call this helper because Android clears its log
       immediately before copying `initial.sqlite3.gz`.
     */
    private func appendManualBookmarkLogEntries(
        to databaseURL: URL,
        settingsStore: SettingsStore
    ) throws {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        var entriesByKey: [String: RemoteSyncLogEntry] = [:]
        for rawEntry in try logEntryStore.entriesStrict(for: .bookmarks) {
            let entry = AndroidBookmarkDatabaseContract.normalizedLogEntry(rawEntry)
            let key = logEntryStore.key(for: .bookmarks, entry: entry)
            if entriesByKey[key].map({
                RemoteSyncLogEntryConflictOrder.isNewer(entry, than: $0)
            }) ?? true {
                entriesByKey[key] = entry
            }
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            if let database {
                sqlite3_close(database)
            }
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        try execute("BEGIN IMMEDIATE TRANSACTION;", in: database)
        do {
            for key in entriesByKey.keys.sorted() {
                guard let entry = entriesByKey[key] else { continue }
                try insertLogEntry(entry, in: database)
            }
            try execute("COMMIT;", in: database)
        } catch {
            try? execute("ROLLBACK;", in: database)
            throw error
        }
    }

    /**
     Builds and uploads one category's full Android-style initial backup.

     - Parameters:
       - category: Logical sync category whose current local state should become the remote baseline.
       - bootstrapState: Ready bootstrap state containing the category sync-folder identifier.
       - modelContext: SwiftData context that owns the current local category graph.
       - settingsStore: Local-only settings store backing fidelity and sync bookkeeping.
       - schemaVersion: Optional explicit Android schema version. Omit it to use the category's
         canonical Room contract.
     - Returns: Summary of the uploaded initial archive and locally recorded patch zero.
     - Side effects:
       - captures one exact graph/settings generation inside a strict read batch
       - writes temporary SQLite and gzip files
       - reconciles `initial.sqlite3.gz` by exact bytes and conditionally creates it when absent
       - atomically clears local Android operations, publishes the exact captured identity manifest, clears prior patch
         statuses, records patch zero, resets progress, publishes captured fingerprints, and may
         rewrite workspace history aliases
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.missingSyncFolderID` when `bootstrapState.syncFolderID` is missing or empty
       - rethrows strict snapshot/settings reads, SQLite, JSON-encoding, compression, transport,
         filesystem, cancellation, and atomic acceptance failures from the lower layers
     */
    public func uploadInitialBackup(
        for category: RemoteSyncCategory,
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int? = nil
    ) async throws -> RemoteSyncInitialBackupUploadReport {
        try await uploadInitialBackup(
            for: category,
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion ?? category.currentSchemaVersion,
            acceptedBaselineMutations: {}
        )
    }

    /**
     Uploads an initial backup and joins caller-owned lifecycle mutations to local acceptance.

     The remote upload necessarily completes before local acceptance. After it succeeds, patch-zero,
     progress, fingerprints, workspace aliases, and `acceptedBaselineMutations` publish through one
     settings-backed transaction. A local failure leaves the previous generation intact so retrying
     may safely upload again without reporting the bootstrap as ready.

     - Parameters:
       - category: Logical sync category whose current local state becomes the remote baseline.
       - bootstrapState: Prepared bootstrap state containing the category sync folder.
       - modelContext: Clean SwiftData context shared by graph and settings reads.
       - settingsStore: Settings store bound to `modelContext`.
       - schemaVersion: Android SQLite schema version written to the backup.
       - acceptedBaselineMutations: Synchronous caller mutations that must commit with local baseline acceptance.
     - Returns: Summary of the uploaded archive and accepted patch-zero status.
     - Side Effects: Builds a durable retry archive, reconciles it with the remote destination, then
       atomically publishes local acceptance bookkeeping and caller mutations. The temporary SQLite
       source is removed after preparation; the durable archive and metadata remain after transport
       or local-acceptance failure and are removed only after successful acceptance or explicit
       destination replacement.
     - Throws: Rethrows strict snapshot/settings reads, SQLite/filesystem work, transport, caller
       mutation, cancellation, and atomic commit failures.
     */
    func uploadInitialBackup(
        for category: RemoteSyncCategory,
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int,
        acceptedBaselineMutations: () throws -> Void
    ) async throws -> RemoteSyncInitialBackupUploadReport {
        guard let syncFolderID = bootstrapState.syncFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !syncFolderID.isEmpty else {
            throw RemoteSyncInitialBackupUploadError.missingSyncFolderID
        }
        guard let adapter else {
            throw RemoteSyncInitialBackupUploadError.missingRemoteAdapter
        }

        let pendingUpload = try prepareInitialUpload(
            for: category,
            syncFolderID: syncFolderID,
            deviceFolderID: bootstrapState.deviceFolderID,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion
        )

        let reconciliation = try await RemoteSyncRemotePatchReconciler(adapter: adapter).reconcile(
            archive: RemoteSyncDurablePatchArchive(
                fileName: RemoteSyncPatchDiscoveryService.initialBackupFilename,
                fileURL: pendingUpload.archiveURL,
                sha256: pendingUpload.metadata.archiveSHA256,
                size: pendingUpload.metadata.archiveSize,
                parentID: syncFolderID,
                contentType: NextCloudSyncAdapter.gzipMimeType
            )
        )
        let uploadedFile: RemoteSyncFile
        switch reconciliation {
        case .created(let file), .matchedExisting(let file):
            uploadedFile = file
        }

        try resetAcceptedBaseline(
            for: category,
            uploadedFile: uploadedFile,
            settingsStore: settingsStore,
            modelContext: modelContext,
            acceptedInitialBackup: pendingUpload.metadata.acceptedInitialBackup,
            acceptedBaselineMutations: acceptedBaselineMutations
        )
        removePendingInitialUpload(for: category)

        let patchZeroStatus = RemoteSyncPatchStatus(
            sourceDevice: deviceIdentifier,
            patchNumber: 0,
            sizeBytes: uploadedFile.size,
            appliedDate: uploadedFile.timestamp
        )

        return RemoteSyncInitialBackupUploadReport(
            category: category,
            uploadedFile: uploadedFile,
            patchZeroStatus: patchZeroStatus
        )
    }

    /**
     Loads or creates the durable archive and immutable metadata for one initial upload.

     A prepared generation is persisted before transport begins. Retries for the same category,
     destination, and schema reuse those exact bytes and acceptance metadata. A destination or
     schema mismatch fails closed so ordinary retries cannot discard an ambiguously published
     generation; explicit reset/replacement must abandon it before a new generation is built.

     - Parameters:
       - category: Logical category being prepared.
       - syncFolderID: Remote initial-backup destination.
       - deviceFolderID: Device-folder identity paired with the bootstrap generation.
       - modelContext: Clean context containing the graph generation to export.
       - settingsStore: Settings store paired with `modelContext`.
       - schemaVersion: Android database schema written into the archive.
     - Returns: Durable prepared archive and its exact local acceptance payload.
     - Side Effects: May build a temporary database and atomically write archive/metadata files.
     - Throws: Rethrows strict build, schema validation, compression, encoding, hashing, and
       filesystem failures; corrupt retry artifacts and destination/schema mismatches fail closed.
     */
    private func prepareInitialUpload(
        for category: RemoteSyncCategory,
        syncFolderID: String,
        deviceFolderID: String?,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int
    ) throws -> PendingInitialUpload {
        if let pendingUpload = try loadPendingInitialUpload(
            for: category,
            syncFolderID: syncFolderID,
            deviceFolderID: deviceFolderID,
            schemaVersion: schemaVersion
        ) {
            return pendingUpload
        }

        let builtBackup = try buildInitialBackup(
            for: category,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion
        )
        defer { try? fileManager.removeItem(at: builtBackup.databaseURL) }
        try Self.validateBuiltInitialBackupDatabase(
            at: builtBackup.databaseURL,
            category: category
        )

        let archiveURL = pendingArchiveURL(for: category)
        let metadataURL = pendingMetadataURL(for: category)
        try fileManager.createDirectory(
            at: retryDirectory,
            withIntermediateDirectories: true
        )
        var keepsPreparedUpload = false
        defer {
            if !keepsPreparedUpload {
                try? fileManager.removeItem(at: archiveURL)
                try? fileManager.removeItem(at: metadataURL)
            }
        }
        let archiveFingerprint = try RemoteSyncArchiveStagingService.gzipInitialBackupDatabase(
            at: builtBackup.databaseURL,
            to: archiveURL
        )
        var metadata = PendingInitialUploadMetadata(
            categoryRawValue: category.rawValue,
            syncFolderID: syncFolderID,
            deviceFolderID: deviceFolderID,
            schemaVersion: schemaVersion,
            archiveSize: archiveFingerprint.byteCount,
            archiveSHA256: archiveFingerprint.sha256,
            acceptedInitialBackup: builtBackup.acceptedInitialBackup,
            publicationIdentity: nil
        )
        metadata.publicationIdentity = try RemoteSyncPublicationIdentity.initialBackup(
            category: category,
            destinationID: syncFolderID,
            sourceDevice: deviceIdentifier,
            schemaVersion: schemaVersion,
            remoteFileName: RemoteSyncPatchDiscoveryService.initialBackupFilename,
            archiveFileName: archiveURL.lastPathComponent,
            archiveSHA256: metadata.archiveSHA256,
            archiveSize: metadata.archiveSize,
            rowCounts: Self.acceptedRowCounts(in: builtBackup.acceptedInitialBackup),
            acceptancePayload: metadata
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
        } catch {
            throw error
        }
        keepsPreparedUpload = true
        return PendingInitialUpload(archiveURL: archiveURL, metadata: metadata)
    }

    /**
     Validates one built outbound database through the same exact contract used on inbound restore.

     - Parameters:
       - databaseURL: Closed SQLite database produced by a category initial-backup builder.
       - category: Category whose Android Room schema and identity must match.
     - Side Effects: Opens the database read-only and closes it before returning.
     - Throws:
       - `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite cannot open the file
       - `RemoteSyncInitialBackupUploadError.invalidBuiltDatabaseContract` when version, identity,
         runtime triggers, or complete schema differ
         from the inbound contract
     */
    static func validateBuiltInitialBackupDatabase(
        at databaseURL: URL,
        category: RemoteSyncCategory
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK,
        let database else {
            if let database {
                sqlite3_close(database)
            }
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_close(database) }

        do {
            try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
                database,
                category: category
            )
        } catch {
            throw RemoteSyncInitialBackupUploadError.invalidBuiltDatabaseContract(category)
        }
    }

    /**
     Loads a matching durable prepared upload when one exists.

     - Parameters:
       - category: Logical category being retried.
       - syncFolderID: Current remote initial-backup destination.
       - deviceFolderID: Current device-folder identity.
       - schemaVersion: Current Android schema version.
     - Returns: Matching prepared upload, or `nil` when no generation exists.
     - Side Effects: Reads the durable metadata and archive without mutating either.
     - Throws:
       - `invalidPendingUploadArtifact` when metadata or archive integrity is invalid and rebuilding
         could acknowledge bytes different from a prior remote upload
       - `pendingUploadDestinationMismatch` when explicit reset/replacement has not abandoned a
         generation bound to another destination or schema
     */
    private func loadPendingInitialUpload(
        for category: RemoteSyncCategory,
        syncFolderID: String,
        deviceFolderID: String?,
        schemaVersion: Int
    ) throws -> PendingInitialUpload? {
        let archiveURL = pendingArchiveURL(for: category)
        let metadataURL = pendingMetadataURL(for: category)
        let hasArchive = fileManager.fileExists(atPath: archiveURL.path)
        let hasMetadata = fileManager.fileExists(atPath: metadataURL.path)
        guard hasArchive || hasMetadata else { return nil }
        guard hasArchive, hasMetadata else {
            do {
                if hasArchive {
                    try fileManager.removeItem(at: archiveURL)
                }
                if hasMetadata {
                    try fileManager.removeItem(at: metadataURL)
                }
            } catch {
                throw RemoteSyncInitialBackupUploadError.invalidPendingUploadArtifact
            }
            return nil
        }

        let metadata: PendingInitialUploadMetadata
        do {
            metadata = try JSONDecoder().decode(
                PendingInitialUploadMetadata.self,
                from: RemoteSyncBoundedFileIO.readRegularFile(
                    at: metadataURL,
                    maximumByteCount: 4 * 1_024 * 1_024
                )
            )
        } catch {
            throw RemoteSyncInitialBackupUploadError.invalidPendingUploadArtifact
        }

        guard metadata.categoryRawValue == category.rawValue else {
            throw RemoteSyncInitialBackupUploadError.invalidPendingUploadArtifact
        }
        guard metadata.syncFolderID == syncFolderID,
              metadata.deviceFolderID == deviceFolderID,
              metadata.schemaVersion == schemaVersion else {
            throw RemoteSyncInitialBackupUploadError.pendingUploadDestinationMismatch
        }

        guard let publicationIdentity = metadata.publicationIdentity else {
            throw RemoteSyncInitialBackupUploadError.invalidPendingUploadArtifact
        }
        var acceptancePayload = metadata
        acceptancePayload.publicationIdentity = nil
        do {
            try publicationIdentity.validate(
                kind: .initialBackup,
                category: category,
                destinationID: syncFolderID,
                sourceDevice: deviceIdentifier,
                patchNumber: 0,
                schemaVersion: schemaVersion,
                remoteFileName: RemoteSyncPatchDiscoveryService.initialBackupFilename,
                archiveFileName: archiveURL.lastPathComponent,
                archiveSHA256: metadata.archiveSHA256,
                archiveSize: metadata.archiveSize,
                rowCounts: Self.acceptedRowCounts(in: metadata.acceptedInitialBackup),
                acceptancePayload: acceptancePayload
            )
        } catch {
            throw RemoteSyncInitialBackupUploadError.invalidPendingUploadArtifact
        }

        let archiveFingerprint: RemoteSyncRegularFileFingerprint
        do {
            archiveFingerprint = try RemoteSyncBoundedFileIO.fingerprintRegularFile(
                at: archiveURL,
                maximumByteCount: RemoteSyncArchiveStagingService.maximumCompressedInitialBackupByteCount
            )
        } catch {
            throw RemoteSyncInitialBackupUploadError.invalidPendingUploadArtifact
        }
        guard archiveFingerprint.byteCount == metadata.archiveSize,
              archiveFingerprint.sha256 == metadata.archiveSHA256 else {
            throw RemoteSyncInitialBackupUploadError.invalidPendingUploadArtifact
        }
        return PendingInitialUpload(archiveURL: archiveURL, metadata: metadata)
    }

    /**
     Removes one category's durable prepared-upload generation after acceptance or replacement.

     - Parameter category: Logical category whose prepared archive is no longer needed.
     - Side Effects: Best-effort removal of the archive and metadata sidecar.
     - Failure modes: Cleanup errors are intentionally ignored after durable local acceptance.
     */
    private func removePendingInitialUpload(for category: RemoteSyncCategory) {
        try? fileManager.removeItem(at: pendingArchiveURL(for: category))
        try? fileManager.removeItem(at: pendingMetadataURL(for: category))
    }

    /** Returns the production durable initial-upload directory beneath Application Support. */
    static func defaultRetryDirectory(fileManager: FileManager) -> URL {
        let root = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return root.appendingPathComponent("RemoteSyncInitialUploads", isDirectory: true)
    }

    /** Returns the stable durable archive path for one category and retry root. */
    static func pendingArchiveURL(
        for category: RemoteSyncCategory,
        retryDirectory: URL
    ) -> URL {
        retryDirectory.appendingPathComponent("\(category.rawValue)-pending.sqlite3.gz")
    }

    /** Returns the stable durable metadata path for one category and retry root. */
    static func pendingMetadataURL(
        for category: RemoteSyncCategory,
        retryDirectory: URL
    ) -> URL {
        retryDirectory.appendingPathComponent("\(category.rawValue)-pending.json")
    }

    /** Returns the configured durable archive path for one category. */
    private func pendingArchiveURL(for category: RemoteSyncCategory) -> URL {
        Self.pendingArchiveURL(for: category, retryDirectory: retryDirectory)
    }

    /** Returns the configured durable metadata path for one category. */
    private func pendingMetadataURL(for category: RemoteSyncCategory) -> URL {
        Self.pendingMetadataURL(for: category, retryDirectory: retryDirectory)
    }

    /**
     Counts the exact accepted Android rows bound to one initial-backup generation.

     - Parameter acceptedInitialBackup: Immutable category baseline captured with the archive.
     - Returns: Nonempty table-name counts plus an `acceptedRows` total.
     - Side effects: none.
     - Failure modes: This exhaustive projection cannot fail.
     */
    private static func acceptedRowCounts(
        in acceptedInitialBackup: AcceptedInitialBackup
    ) -> [String: Int] {
        let tableNames: [String]
        switch acceptedInitialBackup.fingerprintGeneration {
        case .readingPlans(let generation):
            tableNames = generation.rowsByKey.values.map(\.tableName)
        case .bookmarks(let baseline):
            tableNames = baseline.rowIdentities.map(\.tableName)
        case .workspaces(let generation):
            tableNames = generation.rowsByKey.values.map(\.tableName)
        case .myDocuments(let baseline):
            tableNames = baseline.rowIdentities.map(\.tableName)
        case .progress(let generation):
            tableNames = generation.rowsByKey.values.map(\.tableName)
        }
        var counts = Dictionary(grouping: tableNames, by: { $0 }).mapValues(\.count)
        counts["acceptedRows"] = tableNames.count
        return counts
    }

    /**
     Builds one temporary Android-shaped category database from an exact local generation.

     Remote initial upload and manual Android database export share this strict read boundary. All
     graph categories use throwing snapshot projections, workspace history fetches throw, and soft
     settings reads are promoted to a batch failure. If a deferred settings error surfaces after a
     writer created its SQLite file, that artifact is removed before the error escapes.

     - Parameters:
       - category: Logical sync category whose current local state should be exported.
       - modelContext: SwiftData context that owns the current local category graph.
       - settingsStore: Local-only settings store backing fidelity metadata.
       - schemaVersion: SQLite user-version written into the exported database.
     - Returns: Temporary SQLite database file and any synthesized workspace history aliases.
     - Side Effects: Reads one graph/settings generation and writes one temporary SQLite database
       beneath the configured temporary directory.
     - Throws: Rethrows dirty/mismatched context, strict graph/history fetch, deferred settings-read,
       cancellation, SQLite, and JSON-encoding failures; removes any created database on failure.
     */
    private func buildInitialBackup(
        for category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int
    ) throws -> BuiltInitialBackup {
        var createdDatabaseURL: URL?
        do {
            return try settingsStore.performAtomicBatch(in: modelContext) {
                let builtBackup: BuiltInitialBackup
                switch category {
                case .readingPlans:
                    builtBackup = try buildReadingPlanInitialBackup(
                        modelContext: modelContext,
                        settingsStore: settingsStore,
                        schemaVersion: schemaVersion
                    )
                case .bookmarks:
                    builtBackup = try buildBookmarkInitialBackup(
                        modelContext: modelContext,
                        settingsStore: settingsStore,
                        schemaVersion: schemaVersion
                    )
                case .workspaces:
                    builtBackup = try buildWorkspaceInitialBackup(
                        modelContext: modelContext,
                        settingsStore: settingsStore,
                        schemaVersion: schemaVersion
                    )
                case .myDocuments:
                    builtBackup = try buildMyDocumentInitialBackup(
                        modelContext: modelContext,
                        settingsStore: settingsStore,
                        schemaVersion: schemaVersion
                    )
                case .progress:
                    builtBackup = try buildProgressInitialBackup(
                        settingsStore: settingsStore,
                        schemaVersion: schemaVersion
                    )
                }
                createdDatabaseURL = builtBackup.databaseURL
                return builtBackup
            }
        } catch {
            if let createdDatabaseURL {
                try? fileManager.removeItem(at: createdDatabaseURL)
            }
            throw error
        }
    }

    /**
     Persists the accepted post-upload baseline for one category.

     - Parameters:
       - category: Logical sync category whose baseline was accepted remotely.
       - uploadedFile: Remote file metadata returned by the successful upload.
       - settingsStore: Local-only settings store backing sync bookkeeping.
       - modelContext: SwiftData context that owns the atomic settings transaction.
       - acceptedInitialBackup: Immutable local manifest and side metadata captured with the uploaded archive.
       - acceptedBaselineMutations: Caller-owned lifecycle mutations that must publish with baseline acceptance.
     - Side Effects:
       - clears category log entries and publishes the exact accepted-row identity manifest
       - records patch zero with the uploaded archive metadata
       - resets category progress state and advances `lastPatchWritten`
       - publishes the category row fingerprints captured with the uploaded archive
       - may rewrite workspace history aliases
       - commits caller lifecycle mutations in the same settings-backed transaction
     - Throws: Rethrows strict fingerprint projection, settings fetch/save, cancellation, caller
       mutation, and transaction failures after rolling the shared context back to its old generation.
     */
    private func resetAcceptedBaseline(
        for category: RemoteSyncCategory,
        uploadedFile: RemoteSyncFile,
        settingsStore: SettingsStore,
        modelContext: ModelContext,
        acceptedInitialBackup: AcceptedInitialBackup,
        acceptedBaselineMutations: () throws -> Void
    ) throws {
        guard Self.category(for: acceptedInitialBackup.fingerprintGeneration) == category else {
            throw RemoteSyncInitialBackupUploadError.invalidPendingUploadArtifact
        }
        do {
            try settingsStore.performAtomicBatch(in: modelContext) {
                RemoteSyncLogEntryStore(settingsStore: settingsStore).clearCategory(category)

                let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
                patchStatusStore.clearCategory(category)
                patchStatusStore.addStatus(
                    RemoteSyncPatchStatus(
                        sourceDevice: deviceIdentifier,
                        patchNumber: 0,
                        sizeBytes: uploadedFile.size,
                        appliedDate: uploadedFile.timestamp
                    ),
                    for: category
                )

                let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
                stateStore.setProgressState(
                    RemoteSyncProgressState(
                        lastPatchWritten: acceptedInitialBackup.timestamp,
                        lastSynchronized: nil,
                        disabledForVersion: nil
                    ),
                    for: category
                )

                switch acceptedInitialBackup.fingerprintGeneration {
                case .readingPlans(let generation):
                    try RemoteSyncReadingPlanSnapshotService().acceptBaselineFingerprints(
                        generation,
                        settingsStore: settingsStore
                    )
                case .bookmarks(let baseline):
                    try RemoteSyncBookmarkSnapshotService().acceptBaseline(
                        baseline,
                        settingsStore: settingsStore
                    )
                case .workspaces(let generation):
                    synchronizeWorkspaceHistoryAliases(
                        acceptedInitialBackup.workspaceHistoryAliases.map(\.runtimeValue),
                        settingsStore: settingsStore
                    )
                    try RemoteSyncWorkspaceSnapshotService().acceptBaselineFingerprints(
                        generation,
                        settingsStore: settingsStore
                    )
                case .myDocuments(let baseline):
                    try RemoteSyncMyDocumentSnapshotService().acceptBaseline(
                        baseline,
                        settingsStore: settingsStore
                    )
                case .progress(let generation):
                    try RemoteSyncProgressSnapshotService().acceptBaselineFingerprints(
                        generation,
                        settingsStore: settingsStore
                    )
                }
                try acceptedBaselineMutations()
            }
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /**
     Synchronizes the stored workspace-history alias set with the aliases emitted by a fresh export.

     - Parameters:
       - aliases: Synthesized or reused history aliases emitted by the exported workspace baseline.
       - settingsStore: Local-only settings store backing workspace fidelity data.
     - Side effects:
       - removes stale workspace-history alias rows
       - persists the supplied alias set
     - Failure modes: Ordinary callers retain `SettingsStore` soft-write behavior; when invoked by
       accepted-baseline publication, any recorded settings failure invalidates the enclosing batch.
     */
    private func synchronizeWorkspaceHistoryAliases(
        _ aliases: [RemoteSyncWorkspaceFidelityStore.HistoryItemAlias],
        settingsStore: SettingsStore
    ) {
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        let expectedRemoteIDs = Set(aliases.map(\.remoteHistoryItemID))
        for existing in fidelityStore.allHistoryItemAliases() where !expectedRemoteIDs.contains(existing.remoteHistoryItemID) {
            fidelityStore.removeHistoryItemAlias(for: existing.remoteHistoryItemID)
        }
        for alias in aliases {
            fidelityStore.setHistoryItemAlias(
                remoteHistoryItemID: alias.remoteHistoryItemID,
                localHistoryItemID: alias.localHistoryItemID
            )
        }
    }

    /**
     Builds one full Android reading-plan database from the current local snapshot.

     - Parameters:
       - modelContext: SwiftData context that owns the current reading-plan graph.
       - settingsStore: Local-only settings store that preserves Android fidelity side data.
       - schemaVersion: SQLite user-version written into the exported database.
     - Returns: Temporary SQLite database containing the current reading-plan baseline.
     - Side effects:
       - reads reading-plan rows from `modelContext`
       - writes one temporary SQLite database beneath the configured temporary directory
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects schema creation or row insertion
       - remote upload throws `unsupportedCustomReadingPlans` before creating a database for active
         custom plans because Android's database sync does not carry local `.properties` files
     - Note: Builder-only manual database export preserves Android's public Room rows for local
       custom plans and never adds an iOS-only definition table.
     */
    private func buildReadingPlanInitialBackup(
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int
    ) throws -> BuiltInitialBackup {
        guard schemaVersion == RemoteSyncAndroidDatabaseContract.schemaVersion(for: .readingPlans) else {
            throw RemoteSyncInitialBackupUploadError.unsupportedSchemaVersion(
                category: .readingPlans,
                version: schemaVersion
            )
        }
        let snapshot = try readingPlanSnapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        if adapter != nil {
            let unsupportedPlanCodes = readingPlanSnapshotService
                .unsupportedCustomPlanCodes(in: snapshot)
            guard unsupportedPlanCodes.isEmpty else {
                throw RemoteSyncInitialBackupUploadError.unsupportedCustomReadingPlans(
                    unsupportedPlanCodes
                )
            }
        }
        let acceptedTimestamp = try nextAcceptedTimestamp(
            for: .readingPlans,
            settingsStore: settingsStore
        )
        let acceptedGeneration = readingPlanSnapshotService.acceptedGeneration(from: snapshot)
        let databaseURL = temporaryURL(prefix: "remote-sync-readingplans-initial-", suffix: ".sqlite3")
        do {
            var database: OpaquePointer?
            guard sqlite3_open_v2(
                databaseURL.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                nil
            ) == SQLITE_OK, let database else {
                throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
            }
            defer { sqlite3_close(database) }

            try execute(
                RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: .readingPlans),
                in: database
            )

            for row in snapshot.planRowsByKey.values.sorted(by: Self.readingPlanSort) {
                try insertReadingPlanRow(row, in: database)
            }
            for row in snapshot.statusRowsByKey.values.sorted(by: Self.readingPlanStatusSort) {
                try insertReadingPlanStatusRow(row, in: database)
            }
            return BuiltInitialBackup(
                databaseURL: databaseURL,
                acceptedInitialBackup: AcceptedInitialBackup(
                    timestamp: acceptedTimestamp,
                    fingerprintGeneration: .readingPlans(acceptedGeneration),
                    workspaceHistoryAliases: []
                )
            )
        } catch {
            try? fileManager.removeItem(at: databaseURL)
            throw error
        }
    }

    /**
     Builds one full Android Progress database from the current local reading and memorization state.

     - Parameters:
       - settingsStore: Local-only settings store containing the progress JSON snapshots.
       - schemaVersion: SQLite user-version written into the exported database.
     - Returns: Temporary SQLite database containing the current Progress baseline and the timestamp
       used for its accepted baseline `LogEntry` rows.
     - Side effects: writes one temporary SQLite database beneath the configured temporary directory.
     - Failure modes: rethrows SQLite failures from the Android progress mapper or metadata schema creation.
     */
    private func buildProgressInitialBackup(
        settingsStore: SettingsStore,
        schemaVersion: Int
    ) throws -> BuiltInitialBackup {
        guard schemaVersion == RemoteSyncAndroidDatabaseContract.schemaVersion(for: .progress) else {
            throw RemoteSyncInitialBackupUploadError.unsupportedSchemaVersion(
                category: .progress,
                version: schemaVersion
            )
        }
        let databaseURL = temporaryURL(prefix: "remote-sync-progress-initial-", suffix: ".sqlite3")
        let snapshotService = RemoteSyncProgressSnapshotService()
        let snapshot = try snapshotService.snapshotCurrentStateStrict(settingsStore: settingsStore)
        let acceptedTimestamp = try nextAcceptedTimestamp(
            for: .progress,
            settingsStore: settingsStore
        )
        let acceptedGeneration = snapshotService.acceptedGeneration(from: snapshot)
        do {
            try AndroidDatabaseBackupProgressMapper.writeDatabase(
                at: databaseURL,
                settingsStore: settingsStore
            )
            var database: OpaquePointer?
            guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
                  let database else {
                throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
            }
            defer { sqlite3_close(database) }

            try execute(
                RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: .progress),
                in: database
            )

            return BuiltInitialBackup(
                databaseURL: databaseURL,
                acceptedInitialBackup: AcceptedInitialBackup(
                    timestamp: acceptedTimestamp,
                    fingerprintGeneration: .progress(acceptedGeneration),
                    workspaceHistoryAliases: []
                )
            )
        } catch {
            try? fileManager.removeItem(at: databaseURL)
            throw error
        }
    }

    /**
     Builds one full Android bookmark database from the current local snapshot.

     - Parameters:
       - modelContext: SwiftData context that owns the current bookmark graph.
       - settingsStore: Local-only settings store that preserves Android fidelity side data.
       - schemaVersion: SQLite user-version written into the exported database.
     - Returns: Temporary SQLite database containing the current bookmark baseline.
     - Side effects:
       - reads bookmark-category rows from `modelContext`
       - writes one temporary SQLite database beneath the configured temporary directory
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects schema creation or row insertion
     */
    private func buildBookmarkInitialBackup(
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int
    ) throws -> BuiltInitialBackup {
        guard schemaVersion == AndroidBookmarkDatabaseContract.schemaVersion else {
            throw RemoteSyncInitialBackupUploadError.unsupportedBookmarkSchemaVersion(schemaVersion)
        }
        let snapshotService = RemoteSyncBookmarkSnapshotService()
        let snapshot = try snapshotService.snapshotCurrentStateThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let acceptedTimestamp = try nextAcceptedTimestamp(
            for: .bookmarks,
            settingsStore: settingsStore
        )
        let acceptedBaseline = snapshotService.acceptedBaseline(from: snapshot)
        let databaseURL = temporaryURL(prefix: "remote-sync-bookmarks-initial-", suffix: ".sqlite3")
        do {
            var database: OpaquePointer?
            guard sqlite3_open_v2(
                databaseURL.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                nil
            ) == SQLITE_OK, let database else {
                throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
            }
            defer { sqlite3_close(database) }

            try execute(AndroidBookmarkDatabaseContract.createSchemaSQL, in: database)

            for row in snapshot.labelRowsByKey.values.sorted(by: Self.bookmarkLabelSort) {
                try insertLabelRow(row, in: database)
            }
            for row in snapshot.bibleBookmarkRowsByKey.values.sorted(by: Self.bibleBookmarkSort) {
                try insertBibleBookmarkRow(row, in: database)
            }
            for row in snapshot.bibleNoteRowsByKey.values.sorted(by: Self.bookmarkNoteSort) {
                try insertBookmarkNoteRow(row, tableName: "BibleBookmarkNotes", in: database)
            }
            for row in snapshot.bibleLinkRowsByKey.values.sorted(by: Self.bookmarkLabelLinkSort) {
                try insertBookmarkLabelLinkRow(row, tableName: "BibleBookmarkToLabel", in: database)
            }
            for row in snapshot.genericBookmarkRowsByKey.values.sorted(by: Self.genericBookmarkSort) {
                try insertGenericBookmarkRow(row, in: database)
            }
            for row in snapshot.genericNoteRowsByKey.values.sorted(by: Self.bookmarkNoteSort) {
                try insertBookmarkNoteRow(row, tableName: "GenericBookmarkNotes", in: database)
            }
            for row in snapshot.genericLinkRowsByKey.values.sorted(by: Self.bookmarkLabelLinkSort) {
                try insertBookmarkLabelLinkRow(row, tableName: "GenericBookmarkToLabel", in: database)
            }
            for row in snapshot.studyPadEntryRowsByKey.values.sorted(by: Self.studyPadEntrySort) {
                try insertStudyPadEntryRow(row, in: database)
            }
            for row in snapshot.studyPadTextRowsByKey.values.sorted(by: Self.studyPadTextSort) {
                try insertStudyPadTextRow(row, in: database)
            }

            return BuiltInitialBackup(
                databaseURL: databaseURL,
                acceptedInitialBackup: AcceptedInitialBackup(
                    timestamp: acceptedTimestamp,
                    fingerprintGeneration: .bookmarks(acceptedBaseline),
                    workspaceHistoryAliases: []
                )
            )
        } catch {
            try? fileManager.removeItem(at: databaseURL)
            throw error
        }
    }

    /**
     Builds one full Android workspace database from the current local snapshot.

     - Parameters:
       - modelContext: SwiftData context that owns the current workspace graph.
       - settingsStore: Local-only settings store that preserves Android fidelity side data.
       - schemaVersion: SQLite user-version written into the exported database.
     - Returns: Temporary SQLite database and any synthesized workspace-history aliases for the baseline.
     - Side effects:
       - reads workspace rows and history items from `modelContext`
       - writes one temporary SQLite database beneath the configured temporary directory
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects schema creation or row insertion
       - rethrows lower-level JSON-encoding failures from workspace fidelity serialization when Android payloads cannot be encoded
     */
    private func buildWorkspaceInitialBackup(
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int
    ) throws -> BuiltInitialBackup {
        guard schemaVersion == RemoteSyncAndroidDatabaseContract.schemaVersion(for: .workspaces) else {
            throw RemoteSyncInitialBackupUploadError.unsupportedSchemaVersion(
                category: .workspaces,
                version: schemaVersion
            )
        }
        let snapshotService = RemoteSyncWorkspaceSnapshotService()
        let snapshot = try snapshotService.snapshotCurrentStateStrict(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let projectedHistory = try projectWorkspaceHistory(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let acceptedTimestamp = try nextAcceptedTimestamp(
            for: .workspaces,
            settingsStore: settingsStore
        )
        let acceptedGeneration = snapshotService.acceptedGeneration(from: snapshot)
        let databaseURL = temporaryURL(prefix: "remote-sync-workspaces-initial-", suffix: ".sqlite3")
        do {
            var database: OpaquePointer?
            guard sqlite3_open_v2(
                databaseURL.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                nil
            ) == SQLITE_OK, let database else {
                throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
            }
            defer { sqlite3_close(database) }

            try execute(
                RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: .workspaces),
                in: database
            )
            for row in snapshot.workspaceRowsByKey.values.sorted(by: Self.workspaceSort) {
                try insertWorkspaceRow(row, in: database)
            }
            for row in snapshot.windowRowsByKey.values.sorted(by: Self.windowSort) {
                try insertWindowRow(row, in: database)
            }
            for row in snapshot.pageManagerRowsByKey.values.sorted(by: Self.pageManagerSort) {
                try insertPageManagerRow(row, in: database)
            }
            for row in snapshot.labelOverrideRowsByKey.values.sorted(by: Self.labelOverrideSort) {
                try insertWorkspaceLabelOverrideRow(row, in: database)
            }
            for row in snapshot.globalTextDisplayRowsByKey.values.sorted(by: {
                $0.id.uuidString < $1.id.uuidString
            }) {
                try insertGlobalTextDisplaySettingsRow(row, in: database)
            }
            for row in projectedHistory.rows {
                try insertWorkspaceHistoryRow(row, in: database)
            }

            return BuiltInitialBackup(
                databaseURL: databaseURL,
                acceptedInitialBackup: AcceptedInitialBackup(
                    timestamp: acceptedTimestamp,
                    fingerprintGeneration: .workspaces(acceptedGeneration),
                    workspaceHistoryAliases: projectedHistory.aliases.map(StoredWorkspaceHistoryAlias.init)
                )
            )
        } catch {
            try? fileManager.removeItem(at: databaseURL)
            throw error
        }
    }

    /**
     Builds one full Android My Documents database from the current local snapshot.

     - Parameters:
       - modelContext: SwiftData context that owns the current My Documents graph.
       - settingsStore: Local-only settings store that preserves sync bookkeeping.
       - schemaVersion: SQLite user-version written into the exported database.
     - Returns: Temporary SQLite database containing the current My Documents baseline.
     - Side effects:
       - reads My Documents rows from `modelContext`
       - writes one temporary SQLite database beneath the configured temporary directory
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects schema creation or row insertion
     */
    private func buildMyDocumentInitialBackup(
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int
    ) throws -> BuiltInitialBackup {
        guard schemaVersion == RemoteSyncAndroidDatabaseContract.schemaVersion(for: .myDocuments) else {
            throw RemoteSyncInitialBackupUploadError.unsupportedSchemaVersion(
                category: .myDocuments,
                version: schemaVersion
            )
        }
        let snapshotService = RemoteSyncMyDocumentSnapshotService()
        let snapshot = try snapshotService.snapshotCurrentStateThrowing(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let acceptedTimestamp = try nextAcceptedTimestamp(
            for: .myDocuments,
            settingsStore: settingsStore
        )
        let acceptedBaseline = snapshotService.acceptedBaseline(from: snapshot)
        let databaseURL = temporaryURL(prefix: "remote-sync-mydocuments-initial-", suffix: ".sqlite3")
        do {
            var database: OpaquePointer?
            guard sqlite3_open_v2(
                databaseURL.path,
                &database,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
                nil
            ) == SQLITE_OK, let database else {
                if let database {
                    sqlite3_close(database)
                }
                throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
            }
            defer { sqlite3_close(database) }

            try execute(
                RemoteSyncAndroidDatabaseContract.createSchemaSQL(for: .myDocuments),
                in: database
            )
            try execute("BEGIN IMMEDIATE TRANSACTION;", in: database)
            do {
                for row in snapshot.documentRowsByKey.values.sorted(by: Self.myDocumentSort) {
                    try insertMyDocumentRow(row, in: database)
                }
                for row in snapshot.pageRowsByKey.values.sorted(by: Self.myDocumentPageSort) {
                    try insertMyDocumentPageRow(row, in: database)
                }
                for row in snapshot.pageContentRowsByKey.values.sorted(by: Self.myDocumentPageContentSort) {
                    try insertMyDocumentPageContentRow(row, in: database)
                }
                for row in snapshot.aiPageCacheEntryRowsByKey.values.sorted(by: Self.aiPageCacheEntrySort) {
                    try insertAiPageCacheEntryRow(row, in: database)
                }
                try execute("COMMIT;", in: database)
            } catch {
                try? execute("ROLLBACK;", in: database)
                throw error
            }

            return BuiltInitialBackup(
                databaseURL: databaseURL,
                acceptedInitialBackup: AcceptedInitialBackup(
                    timestamp: acceptedTimestamp,
                    fingerprintGeneration: .myDocuments(acceptedBaseline),
                    workspaceHistoryAliases: []
                )
            )
        } catch {
            try? fileManager.removeItem(at: databaseURL)
            throw error
        }
    }

    private struct ProjectedWorkspaceHistory {
        let rows: [RemoteSyncAndroidWorkspaceHistoryItem]
        let aliases: [RemoteSyncWorkspaceFidelityStore.HistoryItemAlias]
    }

    /**
     Projects the current local workspace history into Android `HistoryItem` rows.

     - Parameters:
       - modelContext: SwiftData context that owns the current workspace-history graph.
       - settingsStore: Local-only settings store that preserves Android history-item aliases.
     - Returns: Android-shaped history rows plus the alias rows that should be retained after export.
     - Side effects:
       - reads current `HistoryItem` rows from `modelContext`
       - reads preserved history aliases from `RemoteSyncWorkspaceFidelityStore`
     - Failure modes:
       - rethrows history fetch failures so an initial backup cannot omit history or alias rows
     */
    private func projectWorkspaceHistory(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> ProjectedWorkspaceHistory {
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        let aliasesByLocalID = Dictionary(
            uniqueKeysWithValues: fidelityStore.allHistoryItemAliases().map { ($0.localHistoryItemID, $0.remoteHistoryItemID) }
        )
        let historyItems = try modelContext.fetch(FetchDescriptor<HistoryItem>())
            .sorted { lhs, rhs in
                let lhsWindow = lhs.window?.id.uuidString ?? ""
                let rhsWindow = rhs.window?.id.uuidString ?? ""
                if lhsWindow == rhsWindow {
                    if lhs.createdAt == rhs.createdAt {
                        if lhs.document == rhs.document {
                            if lhs.key == rhs.key {
                                return lhs.id.uuidString < rhs.id.uuidString
                            }
                            return lhs.key < rhs.key
                        }
                        return lhs.document < rhs.document
                    }
                    return lhs.createdAt < rhs.createdAt
                }
                return lhsWindow < rhsWindow
            }

        var nextGeneratedRemoteID = (aliasesByLocalID.values.max() ?? 0) + 1
        var rows: [RemoteSyncAndroidWorkspaceHistoryItem] = []
        var aliases: [RemoteSyncWorkspaceFidelityStore.HistoryItemAlias] = []

        for historyItem in historyItems {
            guard let windowID = historyItem.window?.id else {
                continue
            }
            let remoteID = aliasesByLocalID[historyItem.id] ?? nextGeneratedRemoteID
            if aliasesByLocalID[historyItem.id] == nil {
                nextGeneratedRemoteID += 1
            }
            rows.append(
                RemoteSyncAndroidWorkspaceHistoryItem(
                    remoteID: remoteID,
                    windowID: windowID,
                    createdAt: historyItem.createdAt,
                    document: historyItem.document,
                    key: historyItem.key,
                    anchorOrdinal: historyItem.anchorOrdinal
                )
            )
            aliases.append(
                RemoteSyncWorkspaceFidelityStore.HistoryItemAlias(
                    remoteHistoryItemID: remoteID,
                    localHistoryItemID: historyItem.id
                )
            )
        }

        return ProjectedWorkspaceHistory(rows: rows, aliases: aliases)
    }

    /**
     Sorts reading-plan rows into a deterministic export order.

     - Parameters:
       - lhs: First reading-plan row to compare.
       - rhs: Second reading-plan row to compare.
     - Returns: True when `lhs` should be serialized before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func readingPlanSort(_ lhs: RemoteSyncCurrentReadingPlanRow, _ rhs: RemoteSyncCurrentReadingPlanRow) -> Bool {
        if lhs.planCode == rhs.planCode {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.planCode < rhs.planCode
    }

    /**
     Sorts reading-plan status rows into a deterministic export order.

     - Parameters:
       - lhs: First reading-plan status row to compare.
       - rhs: Second reading-plan status row to compare.
     - Returns: True when `lhs` should be serialized before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func readingPlanStatusSort(_ lhs: RemoteSyncCurrentReadingPlanStatusRow, _ rhs: RemoteSyncCurrentReadingPlanStatusRow) -> Bool {
        if lhs.planCode == rhs.planCode {
            if lhs.planDay == rhs.planDay {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.planDay < rhs.planDay
        }
        return lhs.planCode < rhs.planCode
    }

    /**
     Sorts label rows into a deterministic export order.

     - Parameters:
       - lhs: First label row to compare.
       - rhs: Second label row to compare.
     - Returns: True when `lhs` should be serialized before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func bookmarkLabelSort(_ lhs: RemoteSyncAndroidLabel, _ rhs: RemoteSyncAndroidLabel) -> Bool {
        if lhs.name == rhs.name {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.name < rhs.name
    }

    /**
     Sorts Bible bookmark rows into a deterministic export order.

     - Parameters:
       - lhs: First Bible bookmark row to compare.
       - rhs: Second Bible bookmark row to compare.
     - Returns: True when `lhs` should be serialized before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func bibleBookmarkSort(_ lhs: RemoteSyncAndroidBibleBookmark, _ rhs: RemoteSyncAndroidBibleBookmark) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
    }

    /**
     Sorts generic bookmark rows into a deterministic export order.

     - Parameters:
       - lhs: First generic bookmark row to compare.
       - rhs: Second generic bookmark row to compare.
     - Returns: True when `lhs` should be serialized before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func genericBookmarkSort(_ lhs: RemoteSyncAndroidGenericBookmark, _ rhs: RemoteSyncAndroidGenericBookmark) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
    }

    /**
     Sorts detached bookmark-note rows into a deterministic export order.

     - Parameters:
       - lhs: First note row to compare.
       - rhs: Second note row to compare.
     - Returns: True when `lhs` should be serialized before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func bookmarkNoteSort(_ lhs: RemoteSyncCurrentBookmarkNoteRow, _ rhs: RemoteSyncCurrentBookmarkNoteRow) -> Bool {
        lhs.bookmarkID.uuidString < rhs.bookmarkID.uuidString
    }

    /**
     Sorts bookmark-to-label rows into a deterministic export order.

     - Parameters:
       - lhs: First junction row to compare.
       - rhs: Second junction row to compare.
     - Returns: True when `lhs` should be serialized before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func bookmarkLabelLinkSort(_ lhs: RemoteSyncCurrentBookmarkLabelLinkRow, _ rhs: RemoteSyncCurrentBookmarkLabelLinkRow) -> Bool {
        if lhs.bookmarkID == rhs.bookmarkID {
            return lhs.labelID.uuidString < rhs.labelID.uuidString
        }
        return lhs.bookmarkID.uuidString < rhs.bookmarkID.uuidString
    }

    /**
     Sorts StudyPad entry rows into a deterministic export order.

     - Parameters:
       - lhs: First StudyPad entry row to compare.
       - rhs: Second StudyPad entry row to compare.
     - Returns: True when `lhs` should be serialized before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func studyPadEntrySort(_ lhs: RemoteSyncAndroidStudyPadEntry, _ rhs: RemoteSyncAndroidStudyPadEntry) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    /**
     Sorts detached StudyPad text rows into a deterministic export order.

     - Parameters:
       - lhs: First StudyPad text row to compare.
       - rhs: Second StudyPad text row to compare.
     - Returns: True when `lhs` should be serialized before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func studyPadTextSort(_ lhs: RemoteSyncCurrentStudyPadTextRow, _ rhs: RemoteSyncCurrentStudyPadTextRow) -> Bool {
        lhs.entryID.uuidString < rhs.entryID.uuidString
    }

    /**
     Sorts workspace rows into a deterministic export order.

     - Parameters:
       - lhs: First workspace row to compare.
       - rhs: Second workspace row to compare.
     - Returns: True when `lhs` should be serialized before `rhs`.
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
     Sorts workspace-window rows into a deterministic export order.

     - Parameters:
       - lhs: First workspace-window row to compare.
       - rhs: Second workspace-window row to compare.
     - Returns: True when `lhs` should be serialized before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func windowSort(_ lhs: RemoteSyncCurrentWorkspaceWindowRow, _ rhs: RemoteSyncCurrentWorkspaceWindowRow) -> Bool {
        if lhs.workspaceID == rhs.workspaceID {
            if lhs.orderNumber == rhs.orderNumber {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.orderNumber < rhs.orderNumber
        }
        return lhs.workspaceID.uuidString < rhs.workspaceID.uuidString
    }

    /**
     Sorts page-manager rows into a deterministic export order.

     - Parameters:
       - lhs: First page-manager row to compare.
       - rhs: Second page-manager row to compare.
     - Returns: True when `lhs` should be serialized before `rhs`.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func pageManagerSort(_ lhs: RemoteSyncCurrentWorkspacePageManagerRow, _ rhs: RemoteSyncCurrentWorkspacePageManagerRow) -> Bool {
        lhs.windowID.uuidString < rhs.windowID.uuidString
    }

    /**
     Sorts workspace-label overrides by the complete Android composite identity.

     - Parameters:
       - lhs: First override row.
       - rhs: Second override row.
     - Returns: True when `lhs` should be serialized before `rhs`.
     - Side Effects: none.
     - Failure Modes: This helper cannot fail.
     */
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
     Sorts My Documents rows into a deterministic export order.
     */
    private static func myDocumentSort(_ lhs: RemoteSyncAndroidMyDocument, _ rhs: RemoteSyncAndroidMyDocument) -> Bool {
        if lhs.orderNumber == rhs.orderNumber {
            if lhs.name == rhs.name {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.name < rhs.name
        }
        return lhs.orderNumber < rhs.orderNumber
    }

    /**
     Sorts My Document page rows into a deterministic export order.
     */
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

    /**
     Sorts My Document page-content rows into a deterministic export order.
     */
    private static func myDocumentPageContentSort(
        _ lhs: RemoteSyncAndroidMyDocumentPageContent,
        _ rhs: RemoteSyncAndroidMyDocumentPageContent
    ) -> Bool {
        lhs.pageId.uuidString < rhs.pageId.uuidString
    }

    /**
     Sorts AI page-cache rows into a deterministic export order.
     */
    private static func aiPageCacheEntrySort(
        _ lhs: RemoteSyncAndroidAiPageCacheEntry,
        _ rhs: RemoteSyncAndroidAiPageCacheEntry
    ) -> Bool {
        lhs.pageId.uuidString < rhs.pageId.uuidString
    }

    /**
     Inserts one Android `LogEntry` row into the open initial-backup database.

     - Parameters:
       - entry: Android sync log entry to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `LogEntry` table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
     */
    private func insertLogEntry(_ entry: RemoteSyncLogEntry, in database: OpaquePointer) throws {
        let sql = """
        INSERT INTO LogEntry (tableName, entityId1, entityId2, type, lastUpdated, sourceDevice)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindText(entry.tableName, to: statement, index: 1)
        bindSQLiteValue(entry.entityID1, to: statement, index: 2)
        bindSQLiteValue(entry.entityID2, to: statement, index: 3)
        bindText(entry.type.rawValue, to: statement, index: 4)
        sqlite3_bind_int64(statement, 5, entry.lastUpdated)
        bindText(entry.sourceDevice, to: statement, index: 6)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `ReadingPlan` row into the open initial-backup database.

     - Parameters:
       - row: Android-shaped reading-plan row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `ReadingPlan` table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
     */
    private func insertReadingPlanRow(_ row: RemoteSyncCurrentReadingPlanRow, in database: OpaquePointer) throws {
        let sql = "INSERT INTO ReadingPlan (planCode, planStartDate, planCurrentDay, id) VALUES (?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindText(row.planCode, to: statement, index: 1)
        sqlite3_bind_int64(statement, 2, row.planStartDateMillis)
        sqlite3_bind_int(
            statement,
            3,
            try RemoteSyncWireInteger.int32(
                exactly: row.planCurrentDay,
                field: "ReadingPlan.planCurrentDay"
            )
        )
        bindUUIDBlob(row.id, to: statement, index: 4)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `ReadingPlanStatus` row into the open initial-backup database.

     - Parameters:
       - row: Android-shaped reading-plan status row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `ReadingPlanStatus` table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
     */
    private func insertReadingPlanStatusRow(_ row: RemoteSyncCurrentReadingPlanStatusRow, in database: OpaquePointer) throws {
        let sql = "INSERT INTO ReadingPlanStatus (planCode, planDay, readingStatus, id) VALUES (?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindText(row.planCode, to: statement, index: 1)
        sqlite3_bind_int(
            statement,
            2,
            try RemoteSyncWireInteger.int32(
                exactly: row.planDay,
                field: "ReadingPlanStatus.planDay"
            )
        )
        bindText(row.readingStatusJSON, to: statement, index: 3)
        bindUUIDBlob(row.id, to: statement, index: 4)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `Label` row into the open initial-backup database.

     - Parameters:
       - row: Android-shaped label row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `Label` table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
     */
    private func insertLabelRow(_ row: RemoteSyncAndroidLabel, in database: OpaquePointer) throws {
        let sql = "INSERT INTO Label (id, name, color, markerStyle, markerStyleWholeVerse, underlineStyle, underlineStyleWholeVerse, hideStyle, hideStyleWholeVerse, favourite, type, customIcon) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.id, to: statement, index: 1)
        bindText(row.name, to: statement, index: 2)
        bindAndroidSignedInt32(row.color, to: statement, index: 3)
        bindBool(row.markerStyle, to: statement, index: 4)
        bindBool(row.markerStyleWholeVerse, to: statement, index: 5)
        bindBool(row.underlineStyle, to: statement, index: 6)
        bindBool(row.underlineStyleWholeVerse, to: statement, index: 7)
        bindBool(row.hideStyle, to: statement, index: 8)
        bindBool(row.hideStyleWholeVerse, to: statement, index: 9)
        bindBool(row.favourite, to: statement, index: 10)
        bindOptionalText(row.type, to: statement, index: 11)
        bindOptionalText(row.customIcon, to: statement, index: 12)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `BibleBookmark` row into the open initial-backup database.

     - Parameters:
       - row: Android-shaped Bible bookmark row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `BibleBookmark` table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
     */
    private func insertBibleBookmarkRow(_ row: RemoteSyncAndroidBibleBookmark, in database: OpaquePointer) throws {
        let sql = "INSERT INTO BibleBookmark (kjvOrdinalStart, kjvOrdinalEnd, ordinalStart, ordinalEnd, v11n, playbackSettings, id, createdAt, book, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, type, customIcon, sourcePromptId, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(row.kjvOrdinalStart))
        sqlite3_bind_int(statement, 2, Int32(row.kjvOrdinalEnd))
        sqlite3_bind_int(statement, 3, Int32(row.ordinalStart))
        sqlite3_bind_int(statement, 4, Int32(row.ordinalEnd))
        bindText(row.v11n, to: statement, index: 5)
        bindOptionalText(row.playbackSettingsJSON, to: statement, index: 6)
        bindUUIDBlob(row.id, to: statement, index: 7)
        sqlite3_bind_int64(statement, 8, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        bindOptionalText(row.book, to: statement, index: 9)
        bindOptionalInt(row.startOffset, to: statement, index: 10)
        bindOptionalInt(row.endOffset, to: statement, index: 11)
        bindOptionalUUIDBlob(row.primaryLabelID, to: statement, index: 12)
        sqlite3_bind_int64(statement, 13, Int64(row.lastUpdatedOn.timeIntervalSince1970 * 1000.0))
        bindBool(row.wholeVerse, to: statement, index: 14)
        bindOptionalText(row.type, to: statement, index: 15)
        bindOptionalText(row.customIcon, to: statement, index: 16)
        bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 17)
        bindOptionalText(row.editAction?.mode?.rawValue, to: statement, index: 18)
        bindOptionalText(row.editAction?.content, to: statement, index: 19)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one detached bookmark-note row into the open initial-backup database.

     - Parameters:
       - row: Android-shaped bookmark-note row to insert.
       - tableName: Either `BibleBookmarkNotes` or `GenericBookmarkNotes`.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the supplied note table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
     */
    private func insertBookmarkNoteRow(
        _ row: RemoteSyncCurrentBookmarkNoteRow,
        tableName: String,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO \(tableName) (bookmarkId, notes, contentType, sourcePromptId) VALUES (?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.bookmarkID, to: statement, index: 1)
        bindText(row.notes, to: statement, index: 2)
        bindOptionalText(row.contentType, to: statement, index: 3)
        bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 4)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one bookmark-to-label junction row into the open initial-backup database.

     - Parameters:
       - row: Android-shaped bookmark-to-label row to insert.
       - tableName: Either `BibleBookmarkToLabel` or `GenericBookmarkToLabel`.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the supplied junction table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
     */
    private func insertBookmarkLabelLinkRow(
        _ row: RemoteSyncCurrentBookmarkLabelLinkRow,
        tableName: String,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO \(tableName) (bookmarkId, labelId, orderNumber, indentLevel, expandContent) VALUES (?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.bookmarkID, to: statement, index: 1)
        bindUUIDBlob(row.labelID, to: statement, index: 2)
        sqlite3_bind_int(statement, 3, Int32(row.orderNumber))
        sqlite3_bind_int(statement, 4, Int32(row.indentLevel))
        bindBool(row.expandContent, to: statement, index: 5)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `GenericBookmark` row into the open initial-backup database.

     - Parameters:
       - row: Android-shaped generic bookmark row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `GenericBookmark` table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
     */
    private func insertGenericBookmarkRow(_ row: RemoteSyncAndroidGenericBookmark, in database: OpaquePointer) throws {
        let sql = "INSERT INTO GenericBookmark (id, `key`, createdAt, bookInitials, ordinalStart, ordinalEnd, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, playbackSettings, customIcon, sourcePromptId, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.id, to: statement, index: 1)
        bindText(row.key, to: statement, index: 2)
        sqlite3_bind_int64(statement, 3, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        bindText(row.bookInitials, to: statement, index: 4)
        bindOptionalInt(row.ordinalStart, to: statement, index: 5)
        bindOptionalInt(row.ordinalEnd, to: statement, index: 6)
        bindOptionalInt(row.startOffset, to: statement, index: 7)
        bindOptionalInt(row.endOffset, to: statement, index: 8)
        bindOptionalUUIDBlob(row.primaryLabelID, to: statement, index: 9)
        sqlite3_bind_int64(statement, 10, Int64(row.lastUpdatedOn.timeIntervalSince1970 * 1000.0))
        bindBool(row.wholeVerse, to: statement, index: 11)
        bindOptionalText(row.playbackSettingsJSON, to: statement, index: 12)
        bindOptionalText(row.customIcon, to: statement, index: 13)
        bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 14)
        bindOptionalText(row.editAction?.mode?.rawValue, to: statement, index: 15)
        bindOptionalText(row.editAction?.content, to: statement, index: 16)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `StudyPadTextEntry` row into the open initial-backup database.

     - Parameters:
       - row: Android-shaped StudyPad entry row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `StudyPadTextEntry` table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
     */
    private func insertStudyPadEntryRow(_ row: RemoteSyncAndroidStudyPadEntry, in database: OpaquePointer) throws {
        let sql = "INSERT INTO StudyPadTextEntry (id, labelId, orderNumber, indentLevel, contentType, sourcePromptId) VALUES (?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.id, to: statement, index: 1)
        bindUUIDBlob(row.labelID, to: statement, index: 2)
        sqlite3_bind_int(statement, 3, Int32(row.orderNumber))
        sqlite3_bind_int(statement, 4, Int32(row.indentLevel))
        bindOptionalText(row.contentType, to: statement, index: 5)
        bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 6)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one detached StudyPad text row into the open initial-backup database.

     - Parameters:
       - row: Android-shaped StudyPad text row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `StudyPadTextEntryText` table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
     */
    private func insertStudyPadTextRow(_ row: RemoteSyncCurrentStudyPadTextRow, in database: OpaquePointer) throws {
        let sql = "INSERT INTO StudyPadTextEntryText (studyPadTextEntryId, text) VALUES (?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.entryID, to: statement, index: 1)
        bindText(row.text, to: statement, index: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `Workspace` row into the open initial-backup database.

     - Parameters:
       - row: Android-shaped workspace row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `Workspace` table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
       - rethrows JSON-encoding failures from `bindTextDisplaySettings` and `bindWorkspaceSettings`
     */
    private func insertWorkspaceRow(_ row: RemoteSyncCurrentWorkspaceRow, in database: OpaquePointer) throws {
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
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        bindText(row.name, to: statement, index: index)
        index += 1
        bindOptionalText(row.contentsText, to: statement, index: index)
        index += 1
        bindUUIDBlob(row.id, to: statement, index: index)
        index += 1
        sqlite3_bind_int(statement, index, Int32(row.orderNumber))
        index += 1
        bindOptionalFloat(row.unPinnedWeight, to: statement, index: index)
        index += 1
        bindOptionalUUIDBlob(row.maximizedWindowID, to: statement, index: index)
        index += 1
        bindOptionalUUIDBlob(row.primaryTargetLinksWindowID, to: statement, index: index)
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
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `Window` row into the open initial-backup database.

     - Parameters:
       - row: Android-shaped workspace-window row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `Window` table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
     */
    private func insertWindowRow(_ row: RemoteSyncCurrentWorkspaceWindowRow, in database: OpaquePointer) throws {
        let sql = "INSERT INTO \"Window\" (workspaceId, isSynchronized, isPinMode, isLinksWindow, id, orderNumber, targetLinksWindowId, syncGroup, window_layout_state, window_layout_weight) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.workspaceID, to: statement, index: 1)
        bindBool(row.isSynchronized, to: statement, index: 2)
        bindBool(row.isPinMode, to: statement, index: 3)
        bindBool(row.isLinksWindow, to: statement, index: 4)
        bindUUIDBlob(row.id, to: statement, index: 5)
        sqlite3_bind_int(statement, 6, Int32(row.orderNumber))
        bindOptionalUUIDBlob(row.targetLinksWindowID, to: statement, index: 7)
        sqlite3_bind_int(statement, 8, Int32(row.syncGroup))
        bindText(row.layoutState, to: statement, index: 9)
        sqlite3_bind_double(statement, 10, Double(row.layoutWeight))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `HistoryItem` row into the open initial-backup database.

     - Parameters:
       - row: Android-shaped workspace-history row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `HistoryItem` table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
     */
    private func insertWorkspaceHistoryRow(_ row: RemoteSyncAndroidWorkspaceHistoryItem, in database: OpaquePointer) throws {
        let sql = "INSERT INTO \"HistoryItem\" (windowId, createdAt, document, key, anchorOrdinal, id) VALUES (?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.windowID, to: statement, index: 1)
        sqlite3_bind_int64(statement, 2, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        bindText(row.document, to: statement, index: 3)
        bindText(row.key, to: statement, index: 4)
        bindOptionalInt(row.anchorOrdinal, to: statement, index: 5)
        sqlite3_bind_int64(statement, 6, row.remoteID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `PageManager` row into the open initial-backup database.

     - Parameters:
       - row: Android-shaped page-manager row to insert.
       - database: Open SQLite database handle.
     - Side effects: writes one row into the `PageManager` table.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects prepare, bind, or step work
       - rethrows JSON-encoding failures from `bindTextDisplaySettings`
     */
    private func insertPageManagerRow(_ row: RemoteSyncCurrentWorkspacePageManagerRow, in database: OpaquePointer) throws {
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
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        bindUUIDBlob(row.windowID, to: statement, index: index)
        index += 1
        bindText(row.currentCategoryName, to: statement, index: index)
        index += 1
        bindOptionalText(row.jsState, to: statement, index: index)
        index += 1
        bindOptionalText(row.bibleDocument, to: statement, index: index)
        index += 1
        bindText(row.bibleVersification, to: statement, index: index)
        index += 1
        sqlite3_bind_int(statement, index, Int32(row.bibleBook))
        index += 1
        sqlite3_bind_int(statement, index, Int32(row.bibleChapterNo))
        index += 1
        sqlite3_bind_int(statement, index, Int32(row.bibleVerseNo))
        index += 1
        bindOptionalText(row.commentaryDocument, to: statement, index: index)
        index += 1
        bindOptionalInt(row.commentaryAnchorOrdinal, to: statement, index: index)
        index += 1
        bindOptionalText(row.commentarySourceBookAndKey, to: statement, index: index)
        index += 1
        bindOptionalText(row.dictionaryDocument, to: statement, index: index)
        index += 1
        bindOptionalText(row.dictionaryKey, to: statement, index: index)
        index += 1
        bindOptionalInt(row.dictionaryAnchorOrdinal, to: statement, index: index)
        index += 1
        bindOptionalText(row.generalBookDocument, to: statement, index: index)
        index += 1
        bindOptionalText(row.generalBookKey, to: statement, index: index)
        index += 1
        bindOptionalInt(row.generalBookAnchorOrdinal, to: statement, index: index)
        index += 1
        bindOptionalText(row.mapDocument, to: statement, index: index)
        index += 1
        bindOptionalText(row.mapKey, to: statement, index: index)
        index += 1
        bindOptionalInt(row.mapAnchorOrdinal, to: statement, index: index)
        index += 1
        try bindTextDisplaySettings(
            row.textDisplaySettings,
            fidelity: row.textDisplayFidelity,
            to: statement,
            index: &index
        )
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android workspace-label override into the full initial database.

     - Parameters:
       - row: Composite-key override row to serialize.
       - database: Open writable SQLite database.
     - Side Effects: Inserts one `WorkspaceLabelOverride` row.
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
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.workspaceID, to: statement, index: 1)
        bindUUIDBlob(row.labelID, to: statement, index: 2)
        bindOptionalInt(row.overrideMode, to: statement, index: 3)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts Android's complete global text-display singleton into the full initial database.

     - Parameters:
       - row: Canonical singleton with all native and Android-only fields.
       - database: Open writable SQLite database.
     - Side Effects: Inserts one `GlobalTextDisplaySettings` row.
     - Throws: SQLite failures or hidden-label JSON encoding errors.
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
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        var index: Int32 = 1
        bindUUIDBlob(row.id, to: statement, index: index)
        index += 1
        try bindTextDisplaySettings(
            row.textDisplaySettings,
            fidelity: row.fidelity,
            to: statement,
            index: &index
        )
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `MyDocument` row into the open initial-backup database.
     */
    private func insertMyDocumentRow(_ row: RemoteSyncAndroidMyDocument, in database: OpaquePointer) throws {
        let sql = "INSERT INTO MyDocument (id, name, description, initials, orderNumber, createdAt, updatedAt, sourcePromptId) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.id, to: statement, index: 1)
        bindText(row.name, to: statement, index: 2)
        bindOptionalText(row.documentDescription, to: statement, index: 3)
        bindText(row.initials, to: statement, index: 4)
        sqlite3_bind_int(statement, 5, Int32(row.orderNumber))
        sqlite3_bind_int64(statement, 6, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        sqlite3_bind_int64(statement, 7, Int64(row.updatedAt.timeIntervalSince1970 * 1000.0))
        bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 8)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `MyDocumentPage` row into the open initial-backup database.
     */
    private func insertMyDocumentPageRow(_ row: RemoteSyncAndroidMyDocumentPage, in database: OpaquePointer) throws {
        let sql = "INSERT INTO MyDocumentPage (id, documentId, title, pageKey, contentType, orderNumber, createdAt, updatedAt, sourcePromptId, languageCode) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.id, to: statement, index: 1)
        bindUUIDBlob(row.documentId, to: statement, index: 2)
        bindText(row.title, to: statement, index: 3)
        bindText(row.pageKey, to: statement, index: 4)
        bindText(row.contentType.rawValue, to: statement, index: 5)
        sqlite3_bind_int(statement, 6, Int32(row.orderNumber))
        sqlite3_bind_int64(statement, 7, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        sqlite3_bind_int64(statement, 8, Int64(row.updatedAt.timeIntervalSince1970 * 1000.0))
        bindOptionalUUIDBlob(row.sourcePromptId, to: statement, index: 9)
        bindOptionalText(row.languageCode, to: statement, index: 10)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `MyDocumentPageContent` row into the open initial-backup database.
     */
    private func insertMyDocumentPageContentRow(
        _ row: RemoteSyncAndroidMyDocumentPageContent,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO MyDocumentPageContent (pageId, content) VALUES (?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.pageId, to: statement, index: 1)
        bindText(row.content, to: statement, index: 2)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Inserts one Android `AiPageCacheEntry` row into the open initial-backup database.
     */
    private func insertAiPageCacheEntryRow(
        _ row: RemoteSyncAndroidAiPageCacheEntry,
        in database: OpaquePointer
    ) throws {
        let sql = "INSERT INTO AiPageCacheEntry (pageId, sourcePromptId, sourceContext, kjvOrdinalStart, kjvOrdinalEnd, contextHash, usedWriteTools, sourceModelName, sourceBookInitials, sourceBookKey) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.pageId, to: statement, index: 1)
        bindUUIDBlob(row.sourcePromptId, to: statement, index: 2)
        bindOptionalText(row.sourceContext, to: statement, index: 3)
        bindOptionalInt(row.kjvOrdinalStart, to: statement, index: 4)
        bindOptionalInt(row.kjvOrdinalEnd, to: statement, index: 5)
        bindOptionalText(row.contextHash, to: statement, index: 6)
        bindBool(row.usedWriteTools, to: statement, index: 7)
        bindOptionalText(row.sourceModelName, to: statement, index: 8)
        bindOptionalText(row.sourceBookInitials, to: statement, index: 9)
        bindOptionalText(row.sourceBookKey, to: statement, index: 10)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
    }

    /**
     Binds one optional text-display-settings payload into a workspace or page-manager insert row.

     - Parameters:
       - value: Optional text-display settings to serialize.
       - statement: Prepared SQLite statement receiving the bound values.
       - index: In-out one-based SQLite bind slot advanced across all serialized columns.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes:
       - rethrows JSON-encoding failures when Android array payloads such as hidden-label UUIDs cannot be serialized
     */
    private func bindTextDisplaySettings(
        _ value: TextDisplaySettings?,
        fidelity: RemoteSyncWorkspaceTextDisplaySettingsFidelity,
        to statement: OpaquePointer,
        index: inout Int32
    ) throws {
        let values = try RemoteSyncWorkspaceTextDisplaySettingsWire(
            settings: value,
            fidelity: fidelity
        ).sqliteValues()
        for sqliteValue in values {
            bindSQLiteValue(sqliteValue, to: statement, index: index)
            index += 1
        }
    }

    /**
     Binds one workspace-settings payload into a workspace insert row.

     - Parameters:
       - value: Workspace settings to serialize.
       - speakSettingsJSON: Optional raw Android speak-settings JSON preserved in the fidelity store.
       - workspaceColor: Optional Android signed ARGB workspace color.
       - statement: Prepared SQLite statement receiving the bound values.
       - index: In-out one-based SQLite bind slot advanced across all serialized columns.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes:
       - rethrows JSON-encoding failures when Android set or dictionary payloads cannot be serialized
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

        bindBool(normalizedValue.enableTiltToScroll, to: statement, index: index)
        index += 1
        bindBool(normalizedValue.enableReverseSplitMode, to: statement, index: index)
        index += 1
        bindBool(normalizedValue.autoPin, to: statement, index: index)
        index += 1
        bindBool(normalizedValue.restoreButtonsVisible, to: statement, index: index)
        index += 1
        bindOptionalText(speakSettingsJSON, to: statement, index: index)
        index += 1

        let recentLabelsJSON = try encodeRecentLabelsJSON(normalizedValue.recentLabels)
        bindOptionalText(recentLabelsJSON, to: statement, index: index)
        index += 1

        let autoAssignLabelsJSON = try encodeSortedUUIDSetJSON(
            normalizedValue.autoAssignLabels,
            field: "workspace_settings_autoAssignLabels"
        )
        bindOptionalText(autoAssignLabelsJSON, to: statement, index: index)
        index += 1

        bindOptionalUUIDBlob(normalizedValue.autoAssignPrimaryLabel, to: statement, index: index)
        index += 1

        let studyPadCursorsJSON = try encodeStudyPadCursorsJSON(normalizedValue.studyPadCursors)
        bindOptionalText(studyPadCursorsJSON, to: statement, index: index)
        index += 1

        let hideCompareDocumentsJSON = try encodeSortedStringSetJSON(
            normalizedValue.hideCompareDocuments,
            field: "workspace_settings_hideCompareDocuments"
        )
        bindOptionalText(hideCompareDocumentsJSON, to: statement, index: index)
        index += 1

        bindBool(normalizedValue.limitAmbiguousModalSize, to: statement, index: index)
        index += 1
        bindOptionalAndroidSignedInt32(workspaceColor, to: statement, index: index)
        index += 1
    }

    /**
     Encodes recent-label metadata into Android's JSON payload shape.

     - Parameter value: Recent-label rows to encode.
     - Returns: JSON string payload, or `nil` when the collection is empty.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.jsonEncodingFailed` when JSON encoding fails
     */
    private func encodeRecentLabelsJSON(_ value: [RecentLabel]) throws -> String? {
        guard !value.isEmpty else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        do {
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8)
        } catch {
            throw RemoteSyncInitialBackupUploadError.jsonEncodingFailed(field: "workspace_settings_recentLabels")
        }
    }

    /**
     Encodes one UUID set as a lowercase-sorted Android JSON string array.

     - Parameters:
       - value: UUID set to encode.
       - field: Android field name used for error reporting.
     - Returns: JSON string payload, or `nil` when the set is empty.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.jsonEncodingFailed` when JSON encoding fails
     */
    private func encodeSortedUUIDSetJSON(_ value: Set<UUID>, field: String) throws -> String? {
        guard !value.isEmpty else {
            return nil
        }
        do {
            let array = value.map { $0.uuidString.lowercased() }.sorted()
            let data = try JSONEncoder().encode(array)
            return String(data: data, encoding: .utf8)
        } catch {
            throw RemoteSyncInitialBackupUploadError.jsonEncodingFailed(field: field)
        }
    }

    /**
     Encodes one UUID array as Android's lowercase JSON string array payload.

     - Parameters:
       - value: UUID array to encode.
       - field: Android field name used for error reporting.
     - Returns: JSON string payload, or `"[]"` when the array is empty.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.jsonEncodingFailed` when JSON encoding fails
     */
    private func encodeUUIDArrayJSON(_ value: [UUID], field: String) throws -> String? {
        guard !value.isEmpty else {
            return "[]"
        }
        do {
            let array = value.map { $0.uuidString.lowercased() }
            let data = try JSONEncoder().encode(array)
            return String(data: data, encoding: .utf8)
        } catch {
            throw RemoteSyncInitialBackupUploadError.jsonEncodingFailed(field: field)
        }
    }

    /**
     Encodes StudyPad cursor offsets into Android's keyed JSON payload.

     - Parameter value: Dictionary keyed by StudyPad entry UUID.
     - Returns: JSON string payload, or `nil` when the dictionary is empty.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.jsonEncodingFailed` when JSON encoding fails
     */
    private func encodeStudyPadCursorsJSON(_ value: [UUID: Int]) throws -> String? {
        guard !value.isEmpty else {
            return nil
        }
        let payload = Dictionary(uniqueKeysWithValues: value.map { ($0.key.uuidString.lowercased(), $0.value) })
        do {
            let data = try JSONEncoder().encode(payload)
            return String(data: data, encoding: .utf8)
        } catch {
            throw RemoteSyncInitialBackupUploadError.jsonEncodingFailed(field: "workspace_settings_studyPadCursors")
        }
    }

    /**
     Encodes one string set as a sorted Android JSON string array.

     - Parameters:
       - value: String set to encode.
       - field: Android field name used for error reporting.
     - Returns: JSON string payload, or `nil` when the set is empty.
     - Side effects: none.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.jsonEncodingFailed` when JSON encoding fails
     */
    private func encodeSortedStringSetJSON(_ value: Set<String>, field: String) throws -> String? {
        guard !value.isEmpty else {
            return nil
        }
        do {
            let data = try JSONEncoder().encode(value.sorted())
            return String(data: data, encoding: .utf8)
        } catch {
            throw RemoteSyncInitialBackupUploadError.jsonEncodingFailed(field: field)
        }
    }

    /**
     Allocates the accepted baseline timestamp for a full initial upload.

     - Parameters:
       - category: Category whose old accepted generation is being replaced.
       - settingsStore: Local store containing log, status, and cursor high-water marks.
     - Returns: A logical timestamp greater than wall time and every retained category mark.
     - Side Effects: Reads strict category sync metadata.
     - Throws: Rethrows malformed log/status metadata and
       `RemoteSyncLogicalSequenceError.timestampExhausted`.
     */
    private func nextAcceptedTimestamp(
        for category: RemoteSyncCategory,
        settingsStore: SettingsStore
    ) throws -> Int64 {
        let logEntries = try RemoteSyncLogEntryStore(settingsStore: settingsStore)
            .entriesStrict(for: category)
        let statuses = try RemoteSyncPatchStatusStore(settingsStore: settingsStore)
            .statusesStrict(for: category)
        let progress = RemoteSyncStateStore(settingsStore: settingsStore)
            .progressState(for: category)
        return try RemoteSyncLogicalSequence.nextTimestamp(
            now: nowProvider(),
            highWatermarks: logEntries.map(\.lastUpdated)
                + statuses.map(\.appliedDate)
                + [progress.lastPatchWritten, progress.lastSynchronized].compactMap { $0 }
        )
    }

    /**
     Executes one schema or pragma SQL batch against the open initial-backup database.

     - Parameters:
       - sql: SQL batch to execute.
       - database: Open SQLite database handle.
     - Side effects: mutates the open SQLite database schema or metadata.
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects the batch
     */
    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
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
     Binds one required text value into a prepared SQLite statement parameter.

     - Parameters:
       - value: Text payload to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, remoteSyncInitialBackupUploadSQLiteTransient)
    }

    /**
     Binds one Android sync metadata value into a prepared SQLite statement parameter.

     - Parameters:
       - value: Typed SQLite payload from a preserved or synthesized Android metadata row.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail; SQLite binding errors are surfaced by the caller's
       later `sqlite3_step` check.
     */
    private func bindSQLiteValue(_ value: RemoteSyncSQLiteValue, to statement: OpaquePointer?, index: Int32) {
        switch value.kind {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer:
            sqlite3_bind_int64(statement, index, value.integerValue ?? 0)
        case .real:
            sqlite3_bind_double(statement, index, value.realValue ?? 0)
        case .text:
            sqlite3_bind_text(statement, index, value.textValue ?? "", -1, remoteSyncInitialBackupUploadSQLiteTransient)
        case .blob:
            let data = value.blobData ?? Data()
            _ = data.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), remoteSyncInitialBackupUploadSQLiteTransient)
            }
        }
    }

    /**
     Binds one optional text value into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional text payload to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindText(value, to: statement, index: index)
    }

    /**
     Binds one Boolean value into a prepared SQLite statement parameter as Android's integer form.

     - Parameters:
       - value: Boolean payload to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private func bindBool(_ value: Bool, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_int(statement, index, value ? 1 : 0)
    }

    /**
     Binds one optional Boolean value into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional Boolean payload to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private func bindOptionalBool(_ value: Bool?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindBool(value, to: statement, index: index)
    }

    /**
     Binds one optional integer value into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional integer payload to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private func bindOptionalInt(_ value: Int?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_int(statement, index, Int32(value))
    }

    /**
     Binds one Android signed 32-bit integer that may currently live in a wider Swift `Int`.

     Android color values are persisted as raw signed 32-bit integers. Some iOS call sites carry
     the same bit pattern as a positive 64-bit `Int` literal, so direct `Int32(value)` conversion
     traps. This helper preserves the low 32 bits exactly before binding.

     - Parameters:
       - value: Signed Android integer whose low 32 bits should be preserved.
       - statement: SQLite statement receiving the bound value.
       - index: One-based SQLite bind slot.
     - Side effects: binds one integer parameter onto `statement`.
     - Failure modes: This helper cannot fail; SQLite binding errors are surfaced by the caller's
       later `sqlite3_step` check.
     */
    private func bindAndroidSignedInt32(_ value: Int, to statement: OpaquePointer?, index: Int32) {
        let signedValue = Int32(bitPattern: UInt32(truncatingIfNeeded: value))
        sqlite3_bind_int(statement, index, signedValue)
    }

    /**
     Binds one optional Android signed 32-bit integer that may currently live in a wider Swift `Int`.

     - Parameters:
       - value: Optional signed Android integer whose low 32 bits should be preserved.
       - statement: SQLite statement receiving the bound value.
       - index: One-based SQLite bind slot.
     - Side effects: binds one integer or null parameter onto `statement`.
     - Failure modes: This helper cannot fail; SQLite binding errors are surfaced by the caller's
       later `sqlite3_step` check.
     */
    private func bindOptionalAndroidSignedInt32(_ value: Int?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindAndroidSignedInt32(value, to: statement, index: index)
    }

    /**
     Binds one optional floating-point value into a prepared SQLite statement parameter.

     - Parameters:
       - value: Optional floating-point payload to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private func bindOptionalFloat(_ value: Float?, to statement: OpaquePointer?, index: Int32) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_double(statement, index, Double(value))
    }

    /**
     Binds one required UUID into a prepared SQLite statement parameter as Android's raw 16-byte blob.

     - Parameters:
       - uuid: UUID to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private func bindUUIDBlob(_ uuid: UUID, to statement: OpaquePointer?, index: Int32) {
        let data = uuidBlob(uuid)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), remoteSyncInitialBackupUploadSQLiteTransient)
        }
    }

    /**
     Binds one optional UUID into a prepared SQLite statement parameter.

     - Parameters:
       - uuid: Optional UUID to bind.
       - statement: Prepared SQLite statement receiving the bound value.
       - index: One-based SQLite bind parameter index.
     - Side effects: mutates the prepared SQLite statement's bound-parameter state.
     - Failure modes: This helper cannot fail.
     */
    private func bindOptionalUUIDBlob(_ uuid: UUID?, to statement: OpaquePointer?, index: Int32) {
        guard let uuid else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindUUIDBlob(uuid, to: statement, index: index)
    }

    /**
     Converts one UUID into Android's raw 16-byte blob representation.

     - Parameter uuid: UUID to encode.
     - Returns: Raw 16-byte UUID payload suitable for Android SQLite BLOB columns.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func uuidBlob(_ uuid: UUID) -> Data {
        var value = uuid.uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
