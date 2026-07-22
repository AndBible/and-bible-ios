// RemoteSyncInitialBackupRestoreService.swift — Category-level initial-backup restore dispatch

import Foundation
import SQLite3
import SwiftData

/**
 Summary payload returned after a staged initial backup is restored.

 The enum preserves category-specific report shapes without erasing the details needed by higher
 layers for telemetry, logging, or later UI.
 */
public enum RemoteSyncInitialBackupRestoreReport: Sendable, Equatable {
    /// Successful restore report for the bookmark sync category.
    case bookmarks(RemoteSyncBookmarkRestoreReport)

    /// Successful restore report for the reading-plan sync category.
    case readingPlans(RemoteSyncReadingPlanRestoreReport)

    /// Successful restore report for the workspace sync category.
    case workspaces(RemoteSyncWorkspaceRestoreReport)

    /// Successful restore report for the My Documents sync category.
    case myDocuments(RemoteSyncMyDocumentRestoreReport)

    /// Successful restore report for the Progress sync category.
    case progress(AndroidDatabaseBackupProgressReport)
}

/**
 Restores staged remote initial backups into local SwiftData using category-specific services.

Android sync treats bookmarks, workspaces, and reading plans as separate SQLite databases with
different schemas. This dispatcher preserves that boundary on iOS: it selects the correct
category restore implementation for a staged backup instead of forcing unrelated categories
through one generic SQLite importer.

 Data dependencies:
 - `RemoteSyncBookmarkRestoreService` restores staged Android `bookmarks.sqlite3` backups
 - `RemoteSyncReadingPlanRestoreService` restores staged Android `readingplans.sqlite3` backups
 - `RemoteSyncWorkspaceRestoreService` restores staged Android `workspaces.sqlite3` backups
 - `RemoteSyncMyDocumentRestoreService` restores staged Android `mydocuments.sqlite3` backups
 - `RemoteSyncInitialBackupMetadataRestoreService` preserves staged Android `LogEntry` and
   `SyncStatus` rows needed for later patch replay
 - `RemoteSyncBookmarkSnapshotService` refreshes outbound bookmark fingerprint baselines after
   successful bookmark restores
 - `RemoteSyncWorkspaceSnapshotService` refreshes outbound workspace fingerprint baselines after
   successful workspace restores
 - `RemoteSyncMyDocumentSnapshotService` refreshes outbound My Documents fingerprint baselines
   after successful My Documents restores
 - `SettingsStore` provides local-only persistence for fidelity-preserving side stores such as
  `RemoteSyncReadingPlanStatusStore`, `RemoteSyncBookmarkPlaybackSettingsStore`, and
  `RemoteSyncBookmarkLabelAliasStore`, `RemoteSyncWorkspaceFidelityStore`,
  `RemoteSyncLogEntryStore`, and `RemoteSyncPatchStatusStore`

 Side effects:
 - mutates live local SwiftData records for the supported category
 - installs authoritative reading-plan definition files before reading-plan graph reconstruction
 - may write local-only settings rows needed to preserve Android-only fidelity
 - replaces local Android sync metadata rows for the category after content restore succeeds
 - refreshes outbound bookmark, workspace, reading-plan, and My Documents fingerprint baselines
   after successful restores for those categories

 Failure modes:
 - rethrows category-specific restore errors from the selected restore service
 - rethrows reading-plan definition validation, installation, and rollback errors
 - rethrows staged sync-metadata read errors when Android `LogEntry` or `SyncStatus` tables are
   present but malformed

 Concurrency:
 - this type inherits the confinement rules of the supplied `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncInitialBackupRestoreService {
    private let bookmarkRestoreService: RemoteSyncBookmarkRestoreService
    private let readingPlanRestoreService: RemoteSyncReadingPlanRestoreService
    private let workspaceRestoreService: RemoteSyncWorkspaceRestoreService
    private let myDocumentRestoreService: RemoteSyncMyDocumentRestoreService
    private let metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService
    private let bookmarkSnapshotService: RemoteSyncBookmarkSnapshotService
    private let workspaceSnapshotService: RemoteSyncWorkspaceSnapshotService
    private let readingPlanSnapshotService: RemoteSyncReadingPlanSnapshotService
    private let myDocumentSnapshotService: RemoteSyncMyDocumentSnapshotService
    private let progressSnapshotService: RemoteSyncProgressSnapshotService

    /**
     Creates a category-level initial-backup restore dispatcher.

     - Parameters:
       - bookmarkRestoreService: Restore service used for the bookmark category.
       - readingPlanRestoreService: Restore service used for the reading-plan category.
       - workspaceRestoreService: Restore service used for the workspace category.
       - myDocumentRestoreService: Restore service used for the My Documents category.
       - metadataRestoreService: Restore service used to preserve Android `LogEntry` and `SyncStatus`
         rows after content restore succeeds.
       - bookmarkSnapshotService: Snapshot service used to refresh outbound bookmark fingerprint
         baselines after successful bookmark restores.
       - workspaceSnapshotService: Snapshot service used to refresh outbound workspace fingerprint
         baselines after successful workspace restores.
       - readingPlanSnapshotService: Snapshot service used to refresh outbound reading-plan
         fingerprint baselines after successful remote restores.
       - myDocumentSnapshotService: Snapshot service used to refresh outbound My Documents
         fingerprint baselines after successful remote restores.
       - progressSnapshotService: Snapshot service used to refresh outbound Progress fingerprint
         baselines after successful remote restores.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        bookmarkRestoreService: RemoteSyncBookmarkRestoreService = RemoteSyncBookmarkRestoreService(),
        readingPlanRestoreService: RemoteSyncReadingPlanRestoreService = RemoteSyncReadingPlanRestoreService(),
        workspaceRestoreService: RemoteSyncWorkspaceRestoreService = RemoteSyncWorkspaceRestoreService(),
        myDocumentRestoreService: RemoteSyncMyDocumentRestoreService = RemoteSyncMyDocumentRestoreService(),
        metadataRestoreService: RemoteSyncInitialBackupMetadataRestoreService = RemoteSyncInitialBackupMetadataRestoreService(),
        bookmarkSnapshotService: RemoteSyncBookmarkSnapshotService = RemoteSyncBookmarkSnapshotService(),
        workspaceSnapshotService: RemoteSyncWorkspaceSnapshotService = RemoteSyncWorkspaceSnapshotService(),
        readingPlanSnapshotService: RemoteSyncReadingPlanSnapshotService = RemoteSyncReadingPlanSnapshotService(),
        myDocumentSnapshotService: RemoteSyncMyDocumentSnapshotService = RemoteSyncMyDocumentSnapshotService(),
        progressSnapshotService: RemoteSyncProgressSnapshotService = RemoteSyncProgressSnapshotService()
    ) {
        self.bookmarkRestoreService = bookmarkRestoreService
        self.readingPlanRestoreService = readingPlanRestoreService
        self.workspaceRestoreService = workspaceRestoreService
        self.myDocumentRestoreService = myDocumentRestoreService
        self.metadataRestoreService = metadataRestoreService
        self.bookmarkSnapshotService = bookmarkSnapshotService
        self.workspaceSnapshotService = workspaceSnapshotService
        self.readingPlanSnapshotService = readingPlanSnapshotService
        self.myDocumentSnapshotService = myDocumentSnapshotService
        self.progressSnapshotService = progressSnapshotService
    }

    /**
     Restores one staged initial backup into the local store for the requested sync category.

     - Parameters:
       - stagedBackup: Previously downloaded and extracted initial-backup database.
       - category: Logical sync category that owns the staged backup.
       - modelContext: SwiftData context whose live category records should be replaced.
       - settingsStore: Local-only settings store used by category-specific fidelity helpers.
     - Returns: Category-specific restore summary describing the applied restore.
     - Side effects:
       - atomically replaces live category content, Android-only fidelity, sync metadata, and
         outbound fingerprint baselines through the supplied settings context
       - for reading plans, installs definitions before graph reconstruction and restores prior bytes
         if any later content, metadata, fingerprint, or commit step fails
     - Failure modes:
       - rethrows category-specific snapshot and restore errors from the selected service
       - rethrows staged sync-metadata read errors when present Android metadata tables are malformed
       - throws `SettingsStoreAtomicBatchError` for mismatched or dirty contexts
       - rethrows cancellation, strict fetch, encoding, and commit failures after rolling the
         complete category publish back
     */
    public func restoreInitialBackup(
        _ stagedBackup: RemoteSyncStagedInitialBackup,
        category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncInitialBackupRestoreReport {
        try restoreInitialBackup(
            stagedBackup,
            category: category,
            modelContext: modelContext,
            settingsStore: settingsStore,
            publishCheckpoint: { try Task.checkCancellation() }
        )
    }

    /**
     Restores one initial backup with a deterministic checkpoint inside the atomic publish.

     Category content, Android sync metadata, and outbound fingerprint baselines publish through
     one settings-backed SwiftData transaction. Category restore services join that outer batch,
     including the settings-only Progress path, so no successful content restore can retain stale
     retry or outbound-diff bookkeeping. Reading-plan definition installation wraps that complete
     publication so identity and progress are never reconstructed before their custom file exists.

     - Parameters:
       - stagedBackup: Downloaded and extracted Android initial database.
       - category: Sync category represented by the database.
       - modelContext: Exact clean context shared by graph and settings models.
       - settingsStore: Settings store bound to `modelContext`.
       - publishCheckpoint: Throwing callback before category mutation and after all content and
         metadata mutations have staged.
     - Returns: Category-specific restore report after the single commit succeeds.
     - Side Effects: Reads the staged database and atomically replaces content, metadata, and
       fingerprint state for one category; reading-plan restores also transactionally replace custom
       definition files before graph reconstruction.
     - Throws: Rethrows exact Room schema/bounds, parsing, category restore, context-contract,
       source-generation mismatch, checkpoint, cancellation, strict fetch, encoding, and commit
       errors; final failure rolls the category publish back.
     */
    func restoreInitialBackup(
        _ stagedBackup: RemoteSyncStagedInitialBackup,
        category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        publishCheckpoint: @escaping () throws -> Void
    ) throws -> RemoteSyncInitialBackupRestoreReport {
        let readingPlanSnapshot: RemoteSyncAndroidReadingPlanSnapshot?
        if category == .readingPlans {
            readingPlanSnapshot = try readingPlanRestoreService.readSnapshot(
                from: stagedBackup.databaseFileURL
            )
        } else {
            readingPlanSnapshot = nil
        }
        let workspaceSnapshot: RemoteSyncAndroidWorkspaceSnapshot?
        if category == .workspaces {
            workspaceSnapshot = try workspaceRestoreService.readSnapshot(
                from: stagedBackup.databaseFileURL,
                expectedSourceVersion: stagedBackup.schemaVersion
            )
        } else {
            workspaceSnapshot = nil
        }
        if category == .progress {
            try Self.validateProgressDatabaseBeforeMetadata(
                at: stagedBackup.databaseFileURL
            )
        }
        let metadataSnapshot = try metadataRestoreService.readSnapshot(
            from: stagedBackup.databaseFileURL
        )

        let publish: () throws -> RemoteSyncInitialBackupRestoreReport = { [self] in
            try settingsStore.performAtomicBatch(in: modelContext) {
                try publishCheckpoint()
                let report: RemoteSyncInitialBackupRestoreReport
                switch category {
                case .bookmarks:
                    let snapshot = try bookmarkRestoreService.readSnapshot(
                        from: stagedBackup.databaseFileURL
                    )
                    let bookmarkReport = try bookmarkRestoreService.replaceLocalBookmarks(
                        from: snapshot,
                        modelContext: modelContext,
                        settingsStore: settingsStore,
                        preserveUnverifiedLocalBookmarks: true
                    )
                    report = .bookmarks(bookmarkReport)
                case .readingPlans:
                    guard let readingPlanSnapshot else {
                        throw RemoteSyncReadingPlanRestoreError.invalidSQLiteDatabase
                    }
                    let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
                    let readingPlanReport = try readingPlanRestoreService.replaceLocalReadingPlans(
                        from: readingPlanSnapshot,
                        modelContext: modelContext,
                        statusStore: statusStore,
                        mutationCheckpoint: { try Task.checkCancellation() }
                    )
                    report = .readingPlans(readingPlanReport)
                case .workspaces:
                    guard let workspaceSnapshot else {
                        throw RemoteSyncWorkspaceRestoreError.invalidSQLiteDatabase
                    }
                    let workspaceReport = try workspaceRestoreService.replaceLocalWorkspaces(
                        from: workspaceSnapshot,
                        modelContext: modelContext,
                        settingsStore: settingsStore
                    )
                    report = .workspaces(workspaceReport)
                case .myDocuments:
                    let snapshot = try myDocumentRestoreService.readSnapshot(
                        from: stagedBackup.databaseFileURL
                    )
                    let myDocumentReport = try myDocumentRestoreService.replaceLocalMyDocuments(
                        from: snapshot,
                        modelContext: modelContext,
                        settingsStore: settingsStore
                    )
                    report = .myDocuments(myDocumentReport)
                case .progress:
                    let progressReport = try AndroidDatabaseBackupProgressMapper.apply(
                        from: stagedBackup.databaseFileURL,
                        mode: .restore,
                        settingsStore: settingsStore
                    )
                    report = .progress(progressReport)
                }

                _ = metadataRestoreService.replaceLocalMetadata(
                    from: metadataSnapshot,
                    category: category,
                    settingsStore: settingsStore
                )
                if category == .bookmarks {
                    try bookmarkSnapshotService.refreshBaselineFingerprintsThrowing(
                        modelContext: modelContext,
                        settingsStore: settingsStore
                    )
                } else if category == .workspaces {
                    try workspaceSnapshotService.refreshBaselineFingerprintsStrict(
                        modelContext: modelContext,
                        settingsStore: settingsStore
                    )
                } else if category == .readingPlans {
                    try readingPlanSnapshotService.refreshBaselineFingerprintsStrict(
                        modelContext: modelContext,
                        settingsStore: settingsStore
                    )
                } else if category == .myDocuments {
                    try myDocumentSnapshotService.refreshBaselineFingerprintsThrowing(
                        modelContext: modelContext,
                        settingsStore: settingsStore
                    )
                } else if category == .progress {
                    progressSnapshotService.refreshBaselineFingerprints(settingsStore: settingsStore)
                }
                try publishCheckpoint()
                return report
            }
        }

        return try publish()
    }

    /**
     Validates a Progress initial backup before the generic metadata reader allocates any rows.

     - Parameter databaseURL: Extracted `progress.sqlite3` file staged for restore.
     - Side effects: Opens the database read-only and compares its complete Room and payload contract.
     - Throws: Exact typed database-contract failures, or `invalidDatabase` when SQLite cannot open it.
     */
    private static func validateProgressDatabaseBeforeMetadata(at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let database else {
            throw RemoteSyncAndroidDatabaseContractError.invalidDatabase
        }
        defer { sqlite3_close(database) }
        try RemoteSyncAndroidDatabaseContract.validateInboundDatabase(
            database,
            category: .progress
        )
    }
}
