// RemoteSyncInitialBackupRestoreService.swift — Category-level initial-backup restore dispatch

import Foundation
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
- `SettingsStore` provides local-only persistence for fidelity-preserving side stores such as
  `RemoteSyncReadingPlanStatusStore`, `RemoteSyncBookmarkPlaybackSettingsStore`, and
  `RemoteSyncBookmarkLabelAliasStore`, and `RemoteSyncWorkspaceFidelityStore`

 Side effects:
 - mutates live local SwiftData records for the supported category
 - may write local-only settings rows needed to preserve Android-only fidelity

 Failure modes:
 - rethrows category-specific restore errors from the selected restore service

 Concurrency:
 - this type inherits the confinement rules of the supplied `ModelContext` and `SettingsStore`
 */
public final class RemoteSyncInitialBackupRestoreService {
    private let bookmarkRestoreService: RemoteSyncBookmarkRestoreService
    private let readingPlanRestoreService: RemoteSyncReadingPlanRestoreService
    private let workspaceRestoreService: RemoteSyncWorkspaceRestoreService

    /**
     Creates a category-level initial-backup restore dispatcher.

     - Parameters:
       - bookmarkRestoreService: Restore service used for the bookmark category.
       - readingPlanRestoreService: Restore service used for the reading-plan category.
       - workspaceRestoreService: Restore service used for the workspace category.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        bookmarkRestoreService: RemoteSyncBookmarkRestoreService = RemoteSyncBookmarkRestoreService(),
        readingPlanRestoreService: RemoteSyncReadingPlanRestoreService = RemoteSyncReadingPlanRestoreService(),
        workspaceRestoreService: RemoteSyncWorkspaceRestoreService = RemoteSyncWorkspaceRestoreService()
    ) {
        self.bookmarkRestoreService = bookmarkRestoreService
        self.readingPlanRestoreService = readingPlanRestoreService
        self.workspaceRestoreService = workspaceRestoreService
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
       - mutates live SwiftData state for the supported category
       - may persist local-only helper state needed to preserve Android-only fidelity
     - Failure modes:
       - rethrows category-specific snapshot and restore errors from the selected service
     */
    public func restoreInitialBackup(
        _ stagedBackup: RemoteSyncStagedInitialBackup,
        category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncInitialBackupRestoreReport {
        switch category {
        case .bookmarks:
            let snapshot = try bookmarkRestoreService.readSnapshot(from: stagedBackup.databaseFileURL)
            let report = try bookmarkRestoreService.replaceLocalBookmarks(
                from: snapshot,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            return .bookmarks(report)
        case .readingPlans:
            let snapshot = try readingPlanRestoreService.readSnapshot(from: stagedBackup.databaseFileURL)
            let statusStore = RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
            let report = try readingPlanRestoreService.replaceLocalReadingPlans(
                from: snapshot,
                modelContext: modelContext,
                statusStore: statusStore
            )
            return .readingPlans(report)
        case .workspaces:
            let snapshot = try workspaceRestoreService.readSnapshot(from: stagedBackup.databaseFileURL)
            let report = try workspaceRestoreService.replaceLocalWorkspaces(
                from: snapshot,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            return .workspaces(report)
        }
    }
}
