// AndroidBackupResetService.swift -- Android BackupActivity reset semantics for iOS stores

import Foundation
import SwiftData
import SwordKit

/**
 Android BackupActivity reset categories that have safe iOS persistence equivalents.

 Android exposes reset buttons from the Backup & Restore screen rather than from each
 feature-specific settings page. iOS mirrors that user-facing grouping while keeping the storage
 plumbing native: categories backed by Android-shaped restore engines are reset through empty
 snapshots, repositories reset through the SWORD repository source manager, and application
 preferences reset through the registry-backed settings store.

 - Note: AI Settings is intentionally not represented because this iOS build does not yet have a
   durable Android-equivalent AI settings store. Adding it requires a real mapper/store first.
 */
public enum AndroidBackupResetCategory: String, CaseIterable, Identifiable, Sendable {
    /// Bookmarks, labels, notes, and StudyPad rows.
    case bookmarks

    /// Workspace/window/page-manager layout rows.
    case workspaces

    /// Reading plan definitions and completion status.
    case readingPlans

    /// Download repository sources and local repository metadata.
    case repositories

    /// Registry-backed application preferences.
    case applicationPreferences

    /// My Documents document/page/content rows.
    case myDocuments

    /// Local memorization and chapter reading progress stores.
    case progress

    /// Stable SwiftUI and collection identifier.
    public var id: String { rawValue }

    /// Android remote-sync category affected by this reset, when the category participates in sync.
    var remoteSyncCategory: RemoteSyncCategory? {
        switch self {
        case .bookmarks:
            return .bookmarks
        case .workspaces:
            return .workspaces
        case .readingPlans:
            return .readingPlans
        case .myDocuments:
            return .myDocuments
        case .repositories, .applicationPreferences, .progress:
            return nil
        }
    }
}

/**
 Summary emitted after an Android BackupActivity reset category completes.

 The report is intentionally category-level rather than row-count-level. Android shows a simple
 success toast after deleting a database file, and row counts can be misleading on iOS because
 reset may recreate required system rows such as reserved bookmark labels.
 */
public struct AndroidBackupResetReport: Sendable, Equatable {
    /// Reset category requested by the caller.
    public let category: AndroidBackupResetCategory

    /**
     Creates a completed reset report.

     - Parameter category: Category whose storage boundary was reset.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(category: AndroidBackupResetCategory) {
        self.category = category
    }
}

/**
 Applies Android BackupActivity reset semantics to iOS persistence.

 The service avoids hand-maintained row-deletion shortcuts. For Android sync-backed categories it
 resets by asking the existing restore engines to install an empty Android-shaped snapshot, so the
 same referential integrity, side-store cleanup, and save behavior used by backup restore remains
 authoritative. Category-scoped remote-sync bookkeeping is cleared after successful resets, matching
 Android's post-restore treatment of manually replaced data.

 Data dependencies:
 - `ModelContext` owns the SwiftData rows being reset
 - `SettingsStore` owns local fidelity, remote-sync, progress, and preference state
 - `RepositorySourceManager` owns `InstallMgr.conf` repository source plumbing

 Failure modes:
 - restore-engine and repository-source errors are rethrown so callers can show a visible failure
 - settings-store preference/progress removals are best-effort, matching existing store semantics
 - this type is not `Sendable`; callers must respect the supplied `ModelContext` confinement
 */
public final class AndroidBackupResetService {
    private let bookmarkRestoreService: RemoteSyncBookmarkRestoreService
    private let workspaceRestoreService: RemoteSyncWorkspaceRestoreService
    private let readingPlanRestoreService: RemoteSyncReadingPlanRestoreService
    private let myDocumentRestoreService: RemoteSyncMyDocumentRestoreService
    private let repositorySourceManager: RepositorySourceManager

    /**
     Creates a reset service with injectable category engines.

     - Parameters:
       - bookmarkRestoreService: Engine used to reset bookmark-category SwiftData and fidelity rows.
       - workspaceRestoreService: Engine used to reset workspace/window/page-manager rows.
       - readingPlanRestoreService: Engine used to reset reading-plan rows and status side stores.
       - myDocumentRestoreService: Engine used to reset My Documents rows.
       - repositorySourceManager: Manager used to restore Android-compatible repository sources.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        bookmarkRestoreService: RemoteSyncBookmarkRestoreService = RemoteSyncBookmarkRestoreService(),
        workspaceRestoreService: RemoteSyncWorkspaceRestoreService = RemoteSyncWorkspaceRestoreService(),
        readingPlanRestoreService: RemoteSyncReadingPlanRestoreService = RemoteSyncReadingPlanRestoreService(),
        myDocumentRestoreService: RemoteSyncMyDocumentRestoreService = RemoteSyncMyDocumentRestoreService(),
        repositorySourceManager: RepositorySourceManager = RepositorySourceManager()
    ) {
        self.bookmarkRestoreService = bookmarkRestoreService
        self.workspaceRestoreService = workspaceRestoreService
        self.readingPlanRestoreService = readingPlanRestoreService
        self.myDocumentRestoreService = myDocumentRestoreService
        self.repositorySourceManager = repositorySourceManager
    }

    /**
     Resets one Android BackupActivity category to its initial empty/default state.

     - Parameters:
       - category: Android reset category selected by the user.
       - modelContext: SwiftData context whose category rows should be reset.
       - settingsStore: Settings store used for preferences, progress, fidelity, and sync metadata.
     - Returns: A category-level report after the reset completes.
     - Side effects:
       - deletes and recreates category rows through restore engines where possible
       - clears category fidelity stores and remote-sync bookkeeping after sync-backed resets
       - rewrites repository source configuration for repository resets
       - removes registry-backed app preferences or local progress settings for local-only resets
     - Throws: Rethrows restore-engine, SwiftData save, and repository-source reset failures.
     - Important: Call this from the actor/queue that owns `modelContext`.
     */
    @discardableResult
    public func reset(
        _ category: AndroidBackupResetCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> AndroidBackupResetReport {
        switch category {
        case .bookmarks:
            _ = try bookmarkRestoreService.replaceLocalBookmarks(
                from: RemoteSyncAndroidBookmarkSnapshot(
                    labels: [],
                    bibleBookmarks: [],
                    genericBookmarks: [],
                    studyPadEntries: []
                ),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        case .workspaces:
            _ = try workspaceRestoreService.replaceLocalWorkspaces(
                from: RemoteSyncAndroidWorkspaceSnapshot(workspaces: []),
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        case .readingPlans:
            _ = try readingPlanRestoreService.replaceLocalReadingPlans(
                from: RemoteSyncAndroidReadingPlanSnapshot(plans: []),
                modelContext: modelContext,
                statusStore: RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore)
            )
        case .repositories:
            try resetRepositories(modelContext: modelContext)
        case .applicationPreferences:
            settingsStore.resetApplicationPreferences()
        case .myDocuments:
            _ = try myDocumentRestoreService.replaceLocalMyDocuments(
                from: RemoteSyncAndroidMyDocumentSnapshot(
                    documents: [],
                    pages: [],
                    pageContents: [],
                    aiPageCacheEntries: []
                ),
                modelContext: modelContext
            )
        case .progress:
            resetProgress(settingsStore: settingsStore)
        }

        if let remoteSyncCategory = category.remoteSyncCategory {
            resetManualBackupSyncState(for: remoteSyncCategory, settingsStore: settingsStore)
        }

        return AndroidBackupResetReport(category: category)
    }

    /**
     Resets repository metadata and Android-compatible source configuration.

     - Parameter modelContext: Context containing any legacy SwiftData `Repository` rows.
     - Side effects:
       - rewrites `InstallMgr.conf` through `RepositorySourceManager.resetToDefaults()`
       - deletes local `Repository` rows
       - saves `modelContext`
     - Throws: SwiftData fetch/save errors or repository source reset errors.
     */
    private func resetRepositories(modelContext: ModelContext) throws {
        try repositorySourceManager.resetToDefaults()
        let repositories = try modelContext.fetch(FetchDescriptor<Repository>())
        for repository in repositories {
            modelContext.delete(repository)
        }
        try modelContext.save()
    }

    /**
     Removes local progress stores that correspond to Android's Progress reset category.

     - Parameter settingsStore: Store containing progress JSON payloads.
     - Side effects: Removes memorization and chapter-reading progress settings.
     - Failure modes: Underlying settings removal is best-effort and swallows save failures,
       matching other `SettingsStore` mutations.
     */
    private func resetProgress(settingsStore: SettingsStore) {
        settingsStore.remove(ReadingProgressStore.settingsKey)
        settingsStore.remove(MemorizationProgressStore.settingsKey)
    }

    /**
     Clears category-scoped remote-sync bookkeeping after manual reset.

     Manual reset changes local state outside Android's patch stream. Clearing the category's sync
     toggles, bootstrap state, patch status, log entries, and fingerprints prevents later sync from
     treating deleted local rows as already reconciled remote data.

     - Parameters:
       - category: Remote-sync category affected by the reset.
       - settingsStore: Settings store containing sync metadata.
     - Side effects: Mutates remote-sync settings and side stores for the category.
     - Failure modes: Underlying settings-store writes are best-effort.
     */
    private func resetManualBackupSyncState(for category: RemoteSyncCategory, settingsStore: SettingsStore) {
        RemoteSyncSettingsStore(settingsStore: settingsStore).setSyncEnabled(false, for: category)
        RemoteSyncStateStore(settingsStore: settingsStore).clearCategory(category)
        RemoteSyncPatchStatusStore(settingsStore: settingsStore).clearCategory(category)
        RemoteSyncLogEntryStore(settingsStore: settingsStore).clearCategory(category)
        RemoteSyncRowFingerprintStore(settingsStore: settingsStore).clearCategory(category)
    }
}
