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

    /// Upload was requested from a builder-only service that has no remote backend.
    case missingRemoteAdapter

    /// The requested category does not yet have an initial-backup export pipeline.
    case unsupportedCategory(RemoteSyncCategory)
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
 - `RemoteSyncLogEntryStore`, `RemoteSyncPatchStatusStore`, and `RemoteSyncStateStore` persist the
   accepted local baseline after upload
 - `RemoteSyncWorkspaceFidelityStore` preserves Android history aliases for synthesized workspace
   history rows

 Side effects:
 - creates temporary SQLite and gzip files beneath the configured temporary directory
 - uploads one `initial.sqlite3.gz` archive into the category sync folder
 - clears category-scoped `LogEntry` and `SyncStatus` bookkeeping and records patch zero
 - resets category progress bookkeeping before the next ready-state synchronization pass
 - refreshes outbound fingerprint baselines so the uploaded initial state is not re-emitted as a
   sparse patch immediately afterwards
 - may rewrite workspace history aliases when the workspace category synthesizes Android history ids

 Failure modes:
 - throws `RemoteSyncInitialBackupUploadError.missingSyncFolderID` when bootstrap state is incomplete
 - throws `RemoteSyncInitialBackupUploadError.jsonEncodingFailed` when one Android JSON payload cannot be serialized
 - throws `RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase` when SQLite rejects schema or row writes
 - rethrows transport failures from the backend adapter
 - rethrows filesystem read and write failures while staging the temporary archive
 - rethrows gzip-compression failures from `RemoteSyncArchiveStagingService`

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement rules of the supplied
   `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncInitialBackupUploadService {
    private struct BuiltInitialBackup {
        let databaseURL: URL
        let workspaceHistoryAliases: [RemoteSyncWorkspaceFidelityStore.HistoryItemAlias]
    }

    private let adapter: (any RemoteSyncAdapting)?
    private let deviceIdentifier: String
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let nowProvider: () -> Int64

    /**
     Creates an initial-backup upload service for one remote backend.

     - Parameters:
       - adapter: Remote backend adapter used for initial-backup uploads.
       - deviceIdentifier: Stable device identifier used for patch-zero bookkeeping.
       - fileManager: File manager used for temporary staging and cleanup.
       - temporaryDirectory: Optional staging directory override.
       - nowProvider: Millisecond clock used for local sync bookkeeping resets.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        deviceIdentifier: String,
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        nowProvider: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000.0)
        }
    ) {
        self.adapter = adapter
        self.deviceIdentifier = deviceIdentifier
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        self.nowProvider = nowProvider
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
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory ?? fileManager.temporaryDirectory
        nowProvider = {
            Int64(Date().timeIntervalSince1970 * 1000.0)
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
     - Side effects: writes one temporary SQLite database beneath the configured temporary directory.
     - Failure modes: Rethrows SQLite and JSON-encoding failures from the category-specific writers.
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
        return try service.buildInitialBackup(
            for: category,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion
        ).databaseURL
    }

    /**
     Builds and uploads one category's full Android-style initial backup.

     - Parameters:
       - category: Logical sync category whose current local state should become the remote baseline.
       - bootstrapState: Ready bootstrap state containing the category sync-folder identifier.
       - modelContext: SwiftData context that owns the current local category graph.
       - settingsStore: Local-only settings store backing fidelity and sync bookkeeping.
       - schemaVersion: SQLite user-version written into the exported Android database.
     - Returns: Summary of the uploaded initial archive and locally recorded patch zero.
     - Side effects:
       - writes temporary SQLite and gzip files
       - uploads `initial.sqlite3.gz` into the remote sync folder
       - clears category log-entry and patch-status bookkeeping and records patch zero
       - resets category progress state and refreshes fingerprint baselines
       - may rewrite workspace history aliases for the exported workspace baseline
     - Failure modes:
       - throws `RemoteSyncInitialBackupUploadError.missingSyncFolderID` when `bootstrapState.syncFolderID` is missing or empty
       - rethrows SQLite, JSON-encoding, compression, transport, and filesystem failures from the lower layers
     */
    public func uploadInitialBackup(
        for category: RemoteSyncCategory,
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int = 1
    ) async throws -> RemoteSyncInitialBackupUploadReport {
        guard let syncFolderID = bootstrapState.syncFolderID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !syncFolderID.isEmpty else {
            throw RemoteSyncInitialBackupUploadError.missingSyncFolderID
        }
        guard let adapter else {
            throw RemoteSyncInitialBackupUploadError.missingRemoteAdapter
        }

        let builtBackup = try buildInitialBackup(
            for: category,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: schemaVersion
        )
        let archiveURL = temporaryURL(prefix: "remote-sync-initial-upload-", suffix: ".sqlite3.gz")
        defer {
            try? fileManager.removeItem(at: builtBackup.databaseURL)
            try? fileManager.removeItem(at: archiveURL)
        }

        let archiveData = try RemoteSyncArchiveStagingService.gzip(Data(contentsOf: builtBackup.databaseURL))
        try archiveData.write(to: archiveURL, options: .atomic)

        let uploadedFile = try await adapter.upload(
            name: RemoteSyncPatchDiscoveryService.initialBackupFilename,
            fileURL: archiveURL,
            parentID: syncFolderID,
            contentType: NextCloudSyncAdapter.gzipMimeType
        )

        resetAcceptedBaseline(
            for: category,
            uploadedFile: uploadedFile,
            settingsStore: settingsStore,
            modelContext: modelContext,
            workspaceHistoryAliases: builtBackup.workspaceHistoryAliases
        )

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
     Builds one temporary Android-shaped category database for initial-backup upload.

     - Parameters:
       - category: Logical sync category whose current local state should be exported.
       - modelContext: SwiftData context that owns the current local category graph.
       - settingsStore: Local-only settings store backing fidelity metadata.
       - schemaVersion: SQLite user-version written into the exported database.
     - Returns: Temporary SQLite database file and any synthesized workspace history aliases.
     - Side effects: writes one temporary SQLite database beneath the configured temporary directory.
     - Failure modes: rethrows SQLite and JSON-encoding failures from the category-specific writers.
     */
    private func buildInitialBackup(
        for category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int
    ) throws -> BuiltInitialBackup {
        switch category {
        case .readingPlans:
            return try buildReadingPlanInitialBackup(
                modelContext: modelContext,
                settingsStore: settingsStore,
                schemaVersion: schemaVersion
            )
        case .bookmarks:
            return try buildBookmarkInitialBackup(
                modelContext: modelContext,
                settingsStore: settingsStore,
                schemaVersion: schemaVersion
            )
        case .workspaces:
            return try buildWorkspaceInitialBackup(
                modelContext: modelContext,
                settingsStore: settingsStore,
                schemaVersion: schemaVersion
            )
        case .myDocuments:
            return try buildMyDocumentInitialBackup(
                modelContext: modelContext,
                settingsStore: settingsStore,
                schemaVersion: schemaVersion
            )
        case .progress:
            throw RemoteSyncInitialBackupUploadError.unsupportedCategory(category)
        }
    }

    /**
     Persists the accepted post-upload baseline for one category.

     - Parameters:
       - category: Logical sync category whose baseline was accepted remotely.
       - uploadedFile: Remote file metadata returned by the successful upload.
       - settingsStore: Local-only settings store backing sync bookkeeping.
       - modelContext: SwiftData context used to refresh outbound fingerprints.
       - workspaceHistoryAliases: Synthesized workspace history aliases that should be persisted after a workspace export.
     - Side effects:
       - clears category log-entry and patch-status rows
       - records patch zero with the uploaded archive metadata
       - resets category progress state and advances `lastPatchWritten`
       - refreshes category row-fingerprint baselines
       - may rewrite workspace history aliases
     - Failure modes: Local settings persistence remains best effort and swallows save failures through `SettingsStore`.
     */
    private func resetAcceptedBaseline(
        for category: RemoteSyncCategory,
        uploadedFile: RemoteSyncFile,
        settingsStore: SettingsStore,
        modelContext: ModelContext,
        workspaceHistoryAliases: [RemoteSyncWorkspaceFidelityStore.HistoryItemAlias]
    ) {
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        logEntryStore.clearCategory(category)

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
                lastPatchWritten: nowProvider(),
                lastSynchronized: nil,
                disabledForVersion: nil
            ),
            for: category
        )

        switch category {
        case .readingPlans:
            RemoteSyncReadingPlanSnapshotService().refreshBaselineFingerprints(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        case .bookmarks:
            RemoteSyncBookmarkSnapshotService().refreshBaselineFingerprints(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        case .workspaces:
            synchronizeWorkspaceHistoryAliases(workspaceHistoryAliases, settingsStore: settingsStore)
            RemoteSyncWorkspaceSnapshotService().refreshBaselineFingerprints(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        case .myDocuments:
            RemoteSyncMyDocumentSnapshotService().refreshBaselineFingerprints(
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        case .progress:
            break
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
     - Failure modes: Persistence failures are swallowed by `SettingsStore`.
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
     */
    private func buildReadingPlanInitialBackup(
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        schemaVersion: Int
    ) throws -> BuiltInitialBackup {
        let snapshotService = RemoteSyncReadingPlanSnapshotService()
        let snapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
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
                """
                PRAGMA user_version = \(schemaVersion);
                CREATE TABLE ReadingPlan (
                    planCode TEXT NOT NULL,
                    planStartDate INTEGER NOT NULL,
                    planCurrentDay INTEGER NOT NULL DEFAULT 1,
                    id BLOB NOT NULL PRIMARY KEY
                );
                CREATE TABLE ReadingPlanStatus (
                    planCode TEXT NOT NULL,
                    planDay INTEGER NOT NULL,
                    readingStatus TEXT NOT NULL,
                    id BLOB NOT NULL PRIMARY KEY
                );
                CREATE TABLE LogEntry (
                    tableName TEXT NOT NULL,
                    entityId1 BLOB NOT NULL,
                    entityId2 BLOB NOT NULL,
                    type TEXT NOT NULL,
                    lastUpdated INTEGER NOT NULL DEFAULT 0,
                    sourceDevice TEXT NOT NULL,
                    PRIMARY KEY(tableName, entityId1, entityId2)
                );
                CREATE TABLE SyncConfiguration (
                    keyName TEXT NOT NULL,
                    stringValue TEXT,
                    longValue INTEGER,
                    booleanValue INTEGER,
                    PRIMARY KEY(keyName)
                );
                CREATE TABLE SyncStatus (
                    sourceDevice TEXT NOT NULL,
                    patchNumber INTEGER NOT NULL,
                    sizeBytes INTEGER NOT NULL,
                    appliedDate INTEGER NOT NULL,
                    PRIMARY KEY(sourceDevice, patchNumber)
                );
                """,
                in: database
            )

            for row in snapshot.planRowsByKey.values.sorted(by: Self.readingPlanSort) {
                try insertReadingPlanRow(row, in: database)
            }
            for row in snapshot.statusRowsByKey.values.sorted(by: Self.readingPlanStatusSort) {
                try insertReadingPlanStatusRow(row, in: database)
            }

            return BuiltInitialBackup(databaseURL: databaseURL, workspaceHistoryAliases: [])
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
        let snapshotService = RemoteSyncBookmarkSnapshotService()
        let snapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
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

            try execute(
                """
                PRAGMA user_version = \(schemaVersion);
                CREATE TABLE Label (
                    id BLOB NOT NULL PRIMARY KEY,
                    name TEXT NOT NULL,
                    color INTEGER NOT NULL DEFAULT 0,
                    markerStyle INTEGER NOT NULL DEFAULT 0,
                    markerStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                    underlineStyle INTEGER NOT NULL DEFAULT 0,
                    underlineStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                    hideStyle INTEGER NOT NULL DEFAULT 0,
                    hideStyleWholeVerse INTEGER NOT NULL DEFAULT 0,
                    favourite INTEGER NOT NULL DEFAULT 0,
                    type TEXT DEFAULT NULL,
                    customIcon TEXT DEFAULT NULL
                );
                CREATE TABLE BibleBookmark (
                    kjvOrdinalStart INTEGER NOT NULL,
                    kjvOrdinalEnd INTEGER NOT NULL,
                    ordinalStart INTEGER NOT NULL,
                    ordinalEnd INTEGER NOT NULL,
                    v11n TEXT NOT NULL,
                    playbackSettings TEXT DEFAULT NULL,
                    id BLOB NOT NULL PRIMARY KEY,
                    createdAt INTEGER NOT NULL,
                    book TEXT DEFAULT NULL,
                    startOffset INTEGER DEFAULT NULL,
                    endOffset INTEGER DEFAULT NULL,
                    primaryLabelId BLOB DEFAULT NULL,
                    lastUpdatedOn INTEGER NOT NULL DEFAULT 0,
                    wholeVerse INTEGER NOT NULL DEFAULT 0,
                    type TEXT DEFAULT NULL,
                    customIcon TEXT DEFAULT NULL,
                    editAction_mode TEXT DEFAULT NULL,
                    editAction_content TEXT DEFAULT NULL
                );
                CREATE TABLE BibleBookmarkNotes (
                    bookmarkId BLOB NOT NULL PRIMARY KEY,
                    notes TEXT NOT NULL,
                    contentType TEXT DEFAULT NULL
                );
                CREATE TABLE BibleBookmarkToLabel (
                    bookmarkId BLOB NOT NULL,
                    labelId BLOB NOT NULL,
                    orderNumber INTEGER NOT NULL DEFAULT -1,
                    indentLevel INTEGER NOT NULL DEFAULT 0,
                    expandContent INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(bookmarkId, labelId)
                );
                CREATE TABLE GenericBookmark (
                    id BLOB NOT NULL PRIMARY KEY,
                    `key` TEXT NOT NULL,
                    createdAt INTEGER NOT NULL,
                    bookInitials TEXT NOT NULL DEFAULT '',
                    ordinalStart INTEGER NOT NULL,
                    ordinalEnd INTEGER NOT NULL,
                    startOffset INTEGER DEFAULT NULL,
                    endOffset INTEGER DEFAULT NULL,
                    primaryLabelId BLOB DEFAULT NULL,
                    lastUpdatedOn INTEGER NOT NULL DEFAULT 0,
                    wholeVerse INTEGER NOT NULL DEFAULT 0,
                    playbackSettings TEXT DEFAULT NULL,
                    customIcon TEXT DEFAULT NULL,
                    editAction_mode TEXT DEFAULT NULL,
                    editAction_content TEXT DEFAULT NULL
                );
                CREATE TABLE GenericBookmarkNotes (
                    bookmarkId BLOB NOT NULL PRIMARY KEY,
                    notes TEXT NOT NULL,
                    contentType TEXT DEFAULT NULL
                );
                CREATE TABLE GenericBookmarkToLabel (
                    bookmarkId BLOB NOT NULL,
                    labelId BLOB NOT NULL,
                    orderNumber INTEGER NOT NULL DEFAULT -1,
                    indentLevel INTEGER NOT NULL DEFAULT 0,
                    expandContent INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(bookmarkId, labelId)
                );
                CREATE TABLE StudyPadTextEntry (
                    id BLOB NOT NULL PRIMARY KEY,
                    labelId BLOB NOT NULL,
                    orderNumber INTEGER NOT NULL,
                    indentLevel INTEGER NOT NULL DEFAULT 0,
                    contentType TEXT DEFAULT NULL
                );
                CREATE TABLE StudyPadTextEntryText (
                    studyPadTextEntryId BLOB NOT NULL PRIMARY KEY,
                    text TEXT NOT NULL
                );
                CREATE TABLE LogEntry (
                    tableName TEXT NOT NULL,
                    entityId1 BLOB NOT NULL,
                    entityId2 BLOB NOT NULL,
                    type TEXT NOT NULL,
                    lastUpdated INTEGER NOT NULL DEFAULT 0,
                    sourceDevice TEXT NOT NULL,
                    PRIMARY KEY(tableName, entityId1, entityId2)
                );
                CREATE TABLE SyncConfiguration (
                    keyName TEXT NOT NULL,
                    stringValue TEXT,
                    longValue INTEGER,
                    booleanValue INTEGER,
                    PRIMARY KEY(keyName)
                );
                CREATE TABLE SyncStatus (
                    sourceDevice TEXT NOT NULL,
                    patchNumber INTEGER NOT NULL,
                    sizeBytes INTEGER NOT NULL,
                    appliedDate INTEGER NOT NULL,
                    PRIMARY KEY(sourceDevice, patchNumber)
                );
                CREATE INDEX index_LogEntry_tableName_entityId1 ON LogEntry (tableName, entityId1);
                CREATE INDEX index_LogEntry_lastUpdated ON LogEntry (lastUpdated);
                """,
                in: database
            )

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

            return BuiltInitialBackup(databaseURL: databaseURL, workspaceHistoryAliases: [])
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
        let snapshotService = RemoteSyncWorkspaceSnapshotService()
        let snapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        let projectedHistory = projectWorkspaceHistory(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
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
                """
                PRAGMA user_version = \(schemaVersion);
                CREATE TABLE "Workspace" (
                    name TEXT NOT NULL,
                    contentsText TEXT,
                    id BLOB NOT NULL PRIMARY KEY,
                    orderNumber INTEGER NOT NULL,
                    unPinnedWeight REAL DEFAULT NULL,
                    maximizedWindowId BLOB DEFAULT NULL,
                    primaryTargetLinksWindowId BLOB DEFAULT NULL,
                    text_display_settings_strongsMode INTEGER DEFAULT NULL,
                    text_display_settings_showMorphology INTEGER DEFAULT NULL,
                    text_display_settings_showFootNotes INTEGER DEFAULT NULL,
                    text_display_settings_showFootNotesInline INTEGER DEFAULT NULL,
                    text_display_settings_expandXrefs INTEGER DEFAULT NULL,
                    text_display_settings_showXrefs INTEGER DEFAULT NULL,
                    text_display_settings_showRedLetters INTEGER DEFAULT NULL,
                    text_display_settings_showSectionTitles INTEGER DEFAULT NULL,
                    text_display_settings_showVerseNumbers INTEGER DEFAULT NULL,
                    text_display_settings_showVersePerLine INTEGER DEFAULT NULL,
                    text_display_settings_showBookmarks INTEGER DEFAULT NULL,
                    text_display_settings_showMyNotes INTEGER DEFAULT NULL,
                    text_display_settings_justifyText INTEGER DEFAULT NULL,
                    text_display_settings_hyphenation INTEGER DEFAULT NULL,
                    text_display_settings_topMargin INTEGER DEFAULT NULL,
                    text_display_settings_fontSize INTEGER DEFAULT NULL,
                    text_display_settings_fontFamily TEXT DEFAULT NULL,
                    text_display_settings_lineSpacing INTEGER DEFAULT NULL,
                    text_display_settings_bookmarksHideLabels TEXT DEFAULT NULL,
                    text_display_settings_showPageNumber INTEGER DEFAULT NULL,
                    text_display_settings_margin_size_marginLeft INTEGER DEFAULT NULL,
                    text_display_settings_margin_size_marginRight INTEGER DEFAULT NULL,
                    text_display_settings_margin_size_maxWidth INTEGER DEFAULT NULL,
                    text_display_settings_colors_dayTextColor INTEGER DEFAULT NULL,
                    text_display_settings_colors_dayBackground INTEGER DEFAULT NULL,
                    text_display_settings_colors_dayNoise INTEGER DEFAULT NULL,
                    text_display_settings_colors_nightTextColor INTEGER DEFAULT NULL,
                    text_display_settings_colors_nightBackground INTEGER DEFAULT NULL,
                    text_display_settings_colors_nightNoise INTEGER DEFAULT NULL,
                    workspace_settings_enableTiltToScroll INTEGER NOT NULL DEFAULT 0,
                    workspace_settings_enableReverseSplitMode INTEGER NOT NULL DEFAULT 0,
                    workspace_settings_autoPin INTEGER NOT NULL DEFAULT 0,
                    workspace_settings_speakSettings TEXT DEFAULT NULL,
                    workspace_settings_recentLabels TEXT DEFAULT NULL,
                    workspace_settings_autoAssignLabels TEXT DEFAULT NULL,
                    workspace_settings_autoAssignPrimaryLabel BLOB DEFAULT NULL,
                    workspace_settings_studyPadCursors TEXT DEFAULT NULL,
                    workspace_settings_hideCompareDocuments TEXT DEFAULT NULL,
                    workspace_settings_limitAmbiguousModalSize INTEGER NOT NULL DEFAULT 0,
                    workspace_settings_workspaceColor INTEGER DEFAULT NULL
                );
                CREATE TABLE "Window" (
                    workspaceId BLOB NOT NULL,
                    isSynchronized INTEGER NOT NULL,
                    isPinMode INTEGER NOT NULL,
                    isLinksWindow INTEGER NOT NULL,
                    id BLOB NOT NULL PRIMARY KEY,
                    orderNumber INTEGER NOT NULL,
                    targetLinksWindowId BLOB DEFAULT NULL,
                    syncGroup INTEGER NOT NULL DEFAULT 0,
                    window_layout_state TEXT NOT NULL,
                    window_layout_weight REAL NOT NULL,
                    FOREIGN KEY(workspaceId) REFERENCES "Workspace"(id) ON DELETE CASCADE
                );
                CREATE TABLE "HistoryItem" (
                    windowId BLOB NOT NULL,
                    createdAt INTEGER NOT NULL,
                    document TEXT NOT NULL,
                    key TEXT NOT NULL,
                    anchorOrdinal INTEGER DEFAULT NULL,
                    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                    FOREIGN KEY(windowId) REFERENCES "Window"(id) ON DELETE CASCADE
                );
                CREATE TABLE "PageManager" (
                    windowId BLOB NOT NULL PRIMARY KEY,
                    currentCategoryName TEXT NOT NULL,
                    jsState TEXT,
                    bible_document TEXT,
                    bible_verse_versification TEXT NOT NULL,
                    bible_verse_bibleBook INTEGER NOT NULL,
                    bible_verse_chapterNo INTEGER NOT NULL,
                    bible_verse_verseNo INTEGER NOT NULL,
                    commentary_document TEXT,
                    commentary_anchorOrdinal INTEGER DEFAULT NULL,
                    commentary_sourceBookAndKey TEXT DEFAULT NULL,
                    dictionary_document TEXT,
                    dictionary_key TEXT,
                    dictionary_anchorOrdinal INTEGER DEFAULT NULL,
                    general_book_document TEXT,
                    general_book_key TEXT,
                    general_book_anchorOrdinal INTEGER DEFAULT NULL,
                    map_document TEXT,
                    map_key TEXT,
                    map_anchorOrdinal INTEGER DEFAULT NULL,
                    text_display_settings_strongsMode INTEGER DEFAULT NULL,
                    text_display_settings_showMorphology INTEGER DEFAULT NULL,
                    text_display_settings_showFootNotes INTEGER DEFAULT NULL,
                    text_display_settings_showFootNotesInline INTEGER DEFAULT NULL,
                    text_display_settings_expandXrefs INTEGER DEFAULT NULL,
                    text_display_settings_showXrefs INTEGER DEFAULT NULL,
                    text_display_settings_showRedLetters INTEGER DEFAULT NULL,
                    text_display_settings_showSectionTitles INTEGER DEFAULT NULL,
                    text_display_settings_showVerseNumbers INTEGER DEFAULT NULL,
                    text_display_settings_showVersePerLine INTEGER DEFAULT NULL,
                    text_display_settings_showBookmarks INTEGER DEFAULT NULL,
                    text_display_settings_showMyNotes INTEGER DEFAULT NULL,
                    text_display_settings_justifyText INTEGER DEFAULT NULL,
                    text_display_settings_hyphenation INTEGER DEFAULT NULL,
                    text_display_settings_topMargin INTEGER DEFAULT NULL,
                    text_display_settings_fontSize INTEGER DEFAULT NULL,
                    text_display_settings_fontFamily TEXT DEFAULT NULL,
                    text_display_settings_lineSpacing INTEGER DEFAULT NULL,
                    text_display_settings_bookmarksHideLabels TEXT DEFAULT NULL,
                    text_display_settings_showPageNumber INTEGER DEFAULT NULL,
                    text_display_settings_margin_size_marginLeft INTEGER DEFAULT NULL,
                    text_display_settings_margin_size_marginRight INTEGER DEFAULT NULL,
                    text_display_settings_margin_size_maxWidth INTEGER DEFAULT NULL,
                    text_display_settings_colors_dayTextColor INTEGER DEFAULT NULL,
                    text_display_settings_colors_dayBackground INTEGER DEFAULT NULL,
                    text_display_settings_colors_dayNoise INTEGER DEFAULT NULL,
                    text_display_settings_colors_nightTextColor INTEGER DEFAULT NULL,
                    text_display_settings_colors_nightBackground INTEGER DEFAULT NULL,
                    text_display_settings_colors_nightNoise INTEGER DEFAULT NULL,
                    FOREIGN KEY(windowId) REFERENCES "Window"(id) ON DELETE CASCADE
                );
                CREATE TABLE LogEntry (
                    tableName TEXT NOT NULL,
                    entityId1 BLOB NOT NULL,
                    entityId2 BLOB NOT NULL DEFAULT '',
                    type TEXT NOT NULL,
                    lastUpdated INTEGER NOT NULL DEFAULT 0,
                    sourceDevice TEXT NOT NULL,
                    PRIMARY KEY(tableName, entityId1, entityId2)
                );
                CREATE TABLE SyncConfiguration (
                    keyName TEXT NOT NULL,
                    stringValue TEXT,
                    longValue INTEGER,
                    booleanValue INTEGER,
                    PRIMARY KEY(keyName)
                );
                CREATE TABLE SyncStatus (
                    sourceDevice TEXT NOT NULL,
                    patchNumber INTEGER NOT NULL,
                    sizeBytes INTEGER NOT NULL,
                    appliedDate INTEGER NOT NULL,
                    PRIMARY KEY(sourceDevice, patchNumber)
                );
                CREATE INDEX index_LogEntry_tableName_entityId1 ON LogEntry (tableName, entityId1);
                CREATE INDEX index_LogEntry_lastUpdated ON LogEntry (lastUpdated);
                """,
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
            for row in projectedHistory.rows {
                try insertWorkspaceHistoryRow(row, in: database)
            }

            return BuiltInitialBackup(databaseURL: databaseURL, workspaceHistoryAliases: projectedHistory.aliases)
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
        let snapshotService = RemoteSyncMyDocumentSnapshotService()
        let snapshot = snapshotService.snapshotCurrentState(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
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
                """
                PRAGMA foreign_keys = ON;
                PRAGMA user_version = \(schemaVersion);
                CREATE TABLE MyDocument (
                    id BLOB NOT NULL PRIMARY KEY,
                    name TEXT NOT NULL,
                    description TEXT DEFAULT NULL,
                    initials TEXT NOT NULL,
                    orderNumber INTEGER NOT NULL,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL,
                    sourcePromptId BLOB DEFAULT NULL
                );
                CREATE TABLE MyDocumentPage (
                    id BLOB NOT NULL PRIMARY KEY,
                    documentId BLOB NOT NULL,
                    title TEXT NOT NULL,
                    pageKey TEXT NOT NULL,
                    contentType TEXT NOT NULL,
                    orderNumber INTEGER NOT NULL,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL,
                    sourcePromptId BLOB DEFAULT NULL,
                    languageCode TEXT DEFAULT NULL,
                    FOREIGN KEY(documentId) REFERENCES MyDocument(id) ON DELETE CASCADE
                );
                CREATE TABLE MyDocumentPageContent (
                    pageId BLOB NOT NULL PRIMARY KEY,
                    content TEXT NOT NULL,
                    FOREIGN KEY(pageId) REFERENCES MyDocumentPage(id) ON DELETE CASCADE
                );
                CREATE TABLE AiPageCacheEntry (
                    pageId BLOB NOT NULL PRIMARY KEY,
                    sourcePromptId BLOB NOT NULL,
                    sourceContext TEXT DEFAULT NULL,
                    kjvOrdinalStart INTEGER DEFAULT NULL,
                    kjvOrdinalEnd INTEGER DEFAULT NULL,
                    contextHash TEXT DEFAULT NULL,
                    usedWriteTools INTEGER NOT NULL,
                    sourceModelName TEXT DEFAULT NULL,
                    sourceBookInitials TEXT DEFAULT NULL,
                    sourceBookKey TEXT DEFAULT NULL,
                    FOREIGN KEY(pageId) REFERENCES MyDocumentPage(id) ON DELETE CASCADE
                );
                CREATE TABLE LogEntry (
                    tableName TEXT NOT NULL,
                    entityId1 BLOB NOT NULL,
                    entityId2 BLOB NOT NULL,
                    type TEXT NOT NULL,
                    lastUpdated INTEGER NOT NULL DEFAULT 0,
                    sourceDevice TEXT NOT NULL,
                    PRIMARY KEY(tableName, entityId1, entityId2)
                );
                CREATE TABLE SyncConfiguration (
                    keyName TEXT NOT NULL,
                    stringValue TEXT,
                    longValue INTEGER,
                    booleanValue INTEGER,
                    PRIMARY KEY(keyName)
                );
                CREATE TABLE SyncStatus (
                    sourceDevice TEXT NOT NULL,
                    patchNumber INTEGER NOT NULL,
                    sizeBytes INTEGER NOT NULL,
                    appliedDate INTEGER NOT NULL,
                    PRIMARY KEY(sourceDevice, patchNumber)
                );
                CREATE TABLE room_master_table (
                    id INTEGER PRIMARY KEY,
                    identity_hash TEXT
                );
                INSERT OR REPLACE INTO room_master_table (id, identity_hash)
                    VALUES(42, '3f0946602099d896c8d47129233c1794');
                CREATE UNIQUE INDEX index_MyDocument_initials ON MyDocument (initials);
                CREATE INDEX index_MyDocumentPage_documentId ON MyDocumentPage (documentId);
                CREATE UNIQUE INDEX index_MyDocumentPage_documentId_pageKey ON MyDocumentPage (documentId, pageKey);
                CREATE INDEX index_AiPageCacheEntry_sourcePromptId_contextHash ON AiPageCacheEntry (sourcePromptId, contextHash);
                CREATE INDEX index_AiPageCacheEntry_sourcePromptId_kjvOrdinalStart_kjvOrdinalEnd ON AiPageCacheEntry (sourcePromptId, kjvOrdinalStart, kjvOrdinalEnd);
                CREATE INDEX index_AiPageCacheEntry_kjvOrdinalStart_kjvOrdinalEnd ON AiPageCacheEntry (kjvOrdinalStart, kjvOrdinalEnd);
                CREATE INDEX index_AiPageCacheEntry_sourceBookInitials_sourceBookKey ON AiPageCacheEntry (sourceBookInitials, sourceBookKey);
                CREATE INDEX index_LogEntry_lastUpdated ON LogEntry (lastUpdated);
                CREATE INDEX index_LogEntry_sourceDevice ON LogEntry (sourceDevice);
                CREATE VIEW MyDocumentPageWithContent AS
                    SELECT p.*, c.content
                    FROM MyDocumentPage p
                    LEFT OUTER JOIN MyDocumentPageContent c ON p.id = c.pageId;
                CREATE VIEW AiCachedPageWithContent AS
                    SELECT c.pageId, c.sourcePromptId, c.sourceContext, c.kjvOrdinalStart,
                           c.kjvOrdinalEnd, c.contextHash, c.usedWriteTools, c.sourceModelName,
                           c.sourceBookInitials, c.sourceBookKey,
                           p.title, p.pageKey, p.contentType, p.documentId,
                           p.orderNumber, p.createdAt, p.updatedAt, p.languageCode, cnt.content
                    FROM AiPageCacheEntry c
                    INNER JOIN MyDocumentPage p ON c.pageId = p.id
                    LEFT OUTER JOIN MyDocumentPageContent cnt ON p.id = cnt.pageId;
                """,
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

            return BuiltInitialBackup(databaseURL: databaseURL, workspaceHistoryAliases: [])
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
       - fetch failures from `ModelContext` are swallowed and treated as an empty local history set
     */
    private func projectWorkspaceHistory(
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) -> ProjectedWorkspaceHistory {
        let fidelityStore = RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore)
        let aliasesByLocalID = Dictionary(
            uniqueKeysWithValues: fidelityStore.allHistoryItemAliases().map { ($0.localHistoryItemID, $0.remoteHistoryItemID) }
        )
        let historyItems = ((try? modelContext.fetch(FetchDescriptor<HistoryItem>())) ?? [])
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
        sqlite3_bind_int(statement, 3, Int32(row.planCurrentDay))
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
        sqlite3_bind_int(statement, 2, Int32(row.planDay))
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
        let sql = "INSERT INTO BibleBookmark (kjvOrdinalStart, kjvOrdinalEnd, ordinalStart, ordinalEnd, v11n, playbackSettings, id, createdAt, book, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, type, customIcon, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
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
        bindOptionalText(row.editAction?.mode?.rawValue, to: statement, index: 17)
        bindOptionalText(row.editAction?.content, to: statement, index: 18)
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
        let sql = "INSERT INTO \(tableName) (bookmarkId, notes, contentType) VALUES (?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.bookmarkID, to: statement, index: 1)
        bindText(row.notes, to: statement, index: 2)
        bindOptionalText(row.contentType, to: statement, index: 3)
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
        let sql = "INSERT INTO GenericBookmark (id, `key`, createdAt, bookInitials, ordinalStart, ordinalEnd, startOffset, endOffset, primaryLabelId, lastUpdatedOn, wholeVerse, playbackSettings, customIcon, editAction_mode, editAction_content) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RemoteSyncInitialBackupUploadError.invalidSQLiteDatabase
        }
        defer { sqlite3_finalize(statement) }

        bindUUIDBlob(row.id, to: statement, index: 1)
        bindText(row.key, to: statement, index: 2)
        sqlite3_bind_int64(statement, 3, Int64(row.createdAt.timeIntervalSince1970 * 1000.0))
        bindText(row.bookInitials, to: statement, index: 4)
        sqlite3_bind_int(statement, 5, Int32(row.ordinalStart))
        sqlite3_bind_int(statement, 6, Int32(row.ordinalEnd))
        bindOptionalInt(row.startOffset, to: statement, index: 7)
        bindOptionalInt(row.endOffset, to: statement, index: 8)
        bindOptionalUUIDBlob(row.primaryLabelID, to: statement, index: 9)
        sqlite3_bind_int64(statement, 10, Int64(row.lastUpdatedOn.timeIntervalSince1970 * 1000.0))
        bindBool(row.wholeVerse, to: statement, index: 11)
        bindOptionalText(row.playbackSettingsJSON, to: statement, index: 12)
        bindOptionalText(row.customIcon, to: statement, index: 13)
        bindOptionalText(row.editAction?.mode?.rawValue, to: statement, index: 14)
        bindOptionalText(row.editAction?.content, to: statement, index: 15)
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
        let sql = "INSERT INTO StudyPadTextEntry (id, labelId, orderNumber, indentLevel, contentType) VALUES (?, ?, ?, ?, ?)"
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
        let sql = "INSERT INTO \"Workspace\" (name, contentsText, id, orderNumber, unPinnedWeight, maximizedWindowId, primaryTargetLinksWindowId, text_display_settings_strongsMode, text_display_settings_showMorphology, text_display_settings_showFootNotes, text_display_settings_showFootNotesInline, text_display_settings_expandXrefs, text_display_settings_showXrefs, text_display_settings_showRedLetters, text_display_settings_showSectionTitles, text_display_settings_showVerseNumbers, text_display_settings_showVersePerLine, text_display_settings_showBookmarks, text_display_settings_showMyNotes, text_display_settings_justifyText, text_display_settings_hyphenation, text_display_settings_topMargin, text_display_settings_fontSize, text_display_settings_fontFamily, text_display_settings_lineSpacing, text_display_settings_bookmarksHideLabels, text_display_settings_showPageNumber, text_display_settings_margin_size_marginLeft, text_display_settings_margin_size_marginRight, text_display_settings_margin_size_maxWidth, text_display_settings_colors_dayTextColor, text_display_settings_colors_dayBackground, text_display_settings_colors_dayNoise, text_display_settings_colors_nightTextColor, text_display_settings_colors_nightBackground, text_display_settings_colors_nightNoise, workspace_settings_enableTiltToScroll, workspace_settings_enableReverseSplitMode, workspace_settings_autoPin, workspace_settings_speakSettings, workspace_settings_recentLabels, workspace_settings_autoAssignLabels, workspace_settings_autoAssignPrimaryLabel, workspace_settings_studyPadCursors, workspace_settings_hideCompareDocuments, workspace_settings_limitAmbiguousModalSize, workspace_settings_workspaceColor) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
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
        try bindTextDisplaySettings(row.textDisplaySettings, to: statement, index: &index)
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
        let sql = "INSERT INTO PageManager (windowId, currentCategoryName, jsState, bible_document, bible_verse_versification, bible_verse_bibleBook, bible_verse_chapterNo, bible_verse_verseNo, commentary_document, commentary_anchorOrdinal, commentary_sourceBookAndKey, dictionary_document, dictionary_key, dictionary_anchorOrdinal, general_book_document, general_book_key, general_book_anchorOrdinal, map_document, map_key, map_anchorOrdinal, text_display_settings_strongsMode, text_display_settings_showMorphology, text_display_settings_showFootNotes, text_display_settings_showFootNotesInline, text_display_settings_expandXrefs, text_display_settings_showXrefs, text_display_settings_showRedLetters, text_display_settings_showSectionTitles, text_display_settings_showVerseNumbers, text_display_settings_showVersePerLine, text_display_settings_showBookmarks, text_display_settings_showMyNotes, text_display_settings_justifyText, text_display_settings_hyphenation, text_display_settings_topMargin, text_display_settings_fontSize, text_display_settings_fontFamily, text_display_settings_lineSpacing, text_display_settings_bookmarksHideLabels, text_display_settings_showPageNumber, text_display_settings_margin_size_marginLeft, text_display_settings_margin_size_marginRight, text_display_settings_margin_size_maxWidth, text_display_settings_colors_dayTextColor, text_display_settings_colors_dayBackground, text_display_settings_colors_dayNoise, text_display_settings_colors_nightTextColor, text_display_settings_colors_nightBackground, text_display_settings_colors_nightNoise) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
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
        try bindTextDisplaySettings(row.textDisplaySettings, to: statement, index: &index)
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
        to statement: OpaquePointer,
        index: inout Int32
    ) throws {
        let settings = value
        bindOptionalInt(settings?.strongsMode, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showMorphology, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showFootNotes, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showFootNotesInline, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.expandXrefs, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showXrefs, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showRedLetters, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showSectionTitles, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showVerseNumbers, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showVersePerLine, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showBookmarks, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.showMyNotes, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.justifyText, to: statement, index: index)
        index += 1
        bindOptionalBool(settings?.hyphenation, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.topMargin, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.fontSize, to: statement, index: index)
        index += 1
        bindOptionalText(settings?.fontFamily, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.lineSpacing, to: statement, index: index)
        index += 1
        if let bookmarksHideLabels = settings?.bookmarksHideLabels {
            let bookmarksHideLabelsJSON = try encodeUUIDArrayJSON(
                bookmarksHideLabels,
                field: "text_display_settings_bookmarksHideLabels"
            )
            bindOptionalText(bookmarksHideLabelsJSON, to: statement, index: index)
        } else {
            sqlite3_bind_null(statement, index)
        }
        index += 1
        bindOptionalBool(settings?.showPageNumber, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.marginLeft, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.marginRight, to: statement, index: index)
        index += 1
        bindOptionalInt(settings?.maxWidth, to: statement, index: index)
        index += 1
        bindOptionalAndroidSignedInt32(settings?.dayTextColor, to: statement, index: index)
        index += 1
        bindOptionalAndroidSignedInt32(settings?.dayBackground, to: statement, index: index)
        index += 1
        bindOptionalAndroidSignedInt32(settings?.dayNoise, to: statement, index: index)
        index += 1
        bindOptionalAndroidSignedInt32(settings?.nightTextColor, to: statement, index: index)
        index += 1
        bindOptionalAndroidSignedInt32(settings?.nightBackground, to: statement, index: index)
        index += 1
        bindOptionalAndroidSignedInt32(settings?.nightNoise, to: statement, index: index)
        index += 1
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
        bindBool(value.enableTiltToScroll, to: statement, index: index)
        index += 1
        bindBool(value.enableReverseSplitMode, to: statement, index: index)
        index += 1
        bindBool(value.autoPin, to: statement, index: index)
        index += 1
        bindOptionalText(speakSettingsJSON, to: statement, index: index)
        index += 1

        let recentLabelsJSON = try encodeRecentLabelsJSON(value.recentLabels)
        bindOptionalText(recentLabelsJSON, to: statement, index: index)
        index += 1

        let autoAssignLabelsJSON = try encodeSortedUUIDSetJSON(
            value.autoAssignLabels,
            field: "workspace_settings_autoAssignLabels"
        )
        bindOptionalText(autoAssignLabelsJSON, to: statement, index: index)
        index += 1

        bindOptionalUUIDBlob(value.autoAssignPrimaryLabel, to: statement, index: index)
        index += 1

        let studyPadCursorsJSON = try encodeStudyPadCursorsJSON(value.studyPadCursors)
        bindOptionalText(studyPadCursorsJSON, to: statement, index: index)
        index += 1

        let hideCompareDocumentsJSON = try encodeSortedStringSetJSON(
            value.hideCompareDocuments,
            field: "workspace_settings_hideCompareDocuments"
        )
        bindOptionalText(hideCompareDocumentsJSON, to: statement, index: index)
        index += 1

        bindBool(value.limitAmbiguousModalSize, to: statement, index: index)
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
