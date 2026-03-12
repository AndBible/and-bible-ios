// RemoteSyncSynchronizationService.swift — End-to-end remote patch download/apply orchestration

import Foundation
import SwiftData

/**
 Errors raised while coordinating Android-style remote synchronization phases.

 The lower-level restore, staging, discovery, and patch-apply services already expose detailed
 domain errors. This coordinator adds only the cross-phase failures that are specific to Android's
 sync orchestration contract.
 */
public enum RemoteSyncSynchronizationError: Error, Equatable {
    /// A remotely adopted sync folder did not contain the required Android initial-backup archive.
    case missingInitialBackup(RemoteSyncCategory)
}

/**
 Category-specific patch replay summary returned after one ready-state synchronization run.

 The category-specific apply services intentionally keep their native report types because each sync
 stream exposes different fidelity counters. This wrapper preserves that detail while still letting
 higher layers treat synchronization results uniformly.
 */
public enum RemoteSyncCategoryPatchReplayReport: Sendable, Equatable {
    /// Bookmark-category patch replay summary.
    case bookmarks(RemoteSyncBookmarkPatchApplyReport)

    /// Workspace-category patch replay summary.
    case workspaces(RemoteSyncWorkspacePatchApplyReport)

    /// Reading-plan-category patch replay summary.
    case readingPlans(RemoteSyncReadingPlanPatchApplyReport)
}

/**
 Category-specific outbound patch upload summary returned after one synchronization run.

 Upload support is landing incrementally by category. This wrapper lets the coordinator surface
 upload results for categories that already have a local export pipeline without blocking the rest
 of the synchronization contract on unfinished categories.
 */
public enum RemoteSyncCategoryPatchUploadReport: Sendable, Equatable {
    /// Reading-plan-category outbound patch upload summary.
    case readingPlans(RemoteSyncReadingPlanPatchUploadReport)
}

/**
 Summary of one successful category synchronization pass.

 A synchronization pass may include:
 - no local mutation when bootstrap still needs a user decision
 - a remote initial-backup restore immediately after remote-folder adoption
 - incremental patch download and replay for an already ready category
 - an outbound sparse patch upload when the category supports local export and local state changed

 This report captures only the successful ready-state path after any required bootstrap choice has
 already been made.
 */
public struct RemoteSyncCategorySynchronizationReport: Sendable, Equatable {
    /// Logical sync category that was synchronized.
    public let category: RemoteSyncCategory

    /// Ready bootstrap state used for the synchronization pass.
    public let bootstrapState: RemoteSyncBootstrapState

    /// Initial-backup restore summary when this pass restored a remote initial backup first.
    public let initialRestoreReport: RemoteSyncInitialBackupRestoreReport?

    /// Category-specific patch replay summary when pending patches were applied.
    public let patchReplayReport: RemoteSyncCategoryPatchReplayReport?

    /// Category-specific outbound patch upload summary when the pass emitted a local patch.
    public let patchUploadReport: RemoteSyncCategoryPatchUploadReport?

    /// Number of pending remote patches discovered for this synchronization pass.
    public let discoveredPatchCount: Int

    /// Persisted `lastPatchWritten` value after synchronization completed.
    public let lastPatchWritten: Int64?

    /// Persisted `lastSynchronized` value after synchronization completed.
    public let lastSynchronized: Int64?

    /**
     Creates one category synchronization summary.

     - Parameters:
       - category: Logical sync category that was synchronized.
       - bootstrapState: Ready bootstrap state used for the synchronization pass.
       - initialRestoreReport: Initial-backup restore summary when the pass restored a remote backup first.
       - patchReplayReport: Category-specific patch replay summary when pending patches were applied.
       - patchUploadReport: Category-specific outbound patch upload summary when the pass emitted a local patch.
       - discoveredPatchCount: Number of pending remote patches discovered for the pass.
       - lastPatchWritten: Persisted `lastPatchWritten` value after synchronization completed.
       - lastSynchronized: Persisted `lastSynchronized` value after synchronization completed.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        category: RemoteSyncCategory,
        bootstrapState: RemoteSyncBootstrapState,
        initialRestoreReport: RemoteSyncInitialBackupRestoreReport?,
        patchReplayReport: RemoteSyncCategoryPatchReplayReport?,
        patchUploadReport: RemoteSyncCategoryPatchUploadReport?,
        discoveredPatchCount: Int,
        lastPatchWritten: Int64?,
        lastSynchronized: Int64?
    ) {
        self.category = category
        self.bootstrapState = bootstrapState
        self.initialRestoreReport = initialRestoreReport
        self.patchReplayReport = patchReplayReport
        self.patchUploadReport = patchUploadReport
        self.discoveredPatchCount = discoveredPatchCount
        self.lastPatchWritten = lastPatchWritten
        self.lastSynchronized = lastSynchronized
    }
}

/**
 High-level outcome from attempting to synchronize one category.

 Android's `CloudSync.initializeSync()` can stop before any restore or patch download happens when a
 same-named remote folder exists and the user must choose between adopting it or replacing it. iOS
 needs the same decision point so the settings UI can present an explicit choice instead of
 guessing.
 */
public enum RemoteSyncSynchronizationOutcome: Sendable, Equatable {
    /// Synchronization cannot continue until the caller chooses whether to adopt a discovered folder.
    case requiresRemoteAdoption(RemoteSyncBootstrapCandidate)

    /// Synchronization cannot continue until the caller chooses to create a fresh remote folder.
    case requiresRemoteCreation(RemoteSyncBootstrapCreation)

    /// Synchronization completed against a ready bootstrap state.
    case synchronized(RemoteSyncCategorySynchronizationReport)
}

/**
 Coordinates Android-aligned remote bootstrap inspection, initial-backup restore, patch replay, and
 outbound patch upload where a category exporter exists.

 This service mirrors Android's synchronization flow as far as the current category exporters allow:
 - inspect or validate the category bootstrap state
 - surface adopt-versus-create decisions without mutating local data
 - after remote adoption, download and restore `initial.sqlite3.gz`
 - for ready categories, discover, stage, download, and replay incremental remote patches
 - after remote replay, upload one outbound sparse patch when the category supports local export
 - persist Android-aligned `lastPatchWritten` and `lastSynchronized` bookkeeping

 Bookmark and workspace upload orchestration are intentionally left to follow-up work because iOS
 does not yet have outbound patch-export services for those categories.

 Data dependencies:
 - `RemoteSyncBootstrapCoordinator` validates or creates ready bootstrap state
 - `RemoteSyncPatchDiscoveryService` finds remote initial backups and pending patch archives
 - `RemoteSyncArchiveStagingService` downloads initial-backup and patch archives into temporary files
 - `RemoteSyncInitialBackupRestoreService` restores staged initial backups into local SwiftData
 - category-specific patch apply services replay staged Android patch archives into local SwiftData
 - `RemoteSyncReadingPlanPatchUploadService` exports and uploads outbound sparse reading-plan patches
 - `RemoteSyncStateStore` persists Android-aligned bootstrap and progress metadata locally
 - `RemoteSyncPatchStatusStore` records patch zero after remote initial-backup adoption, matching Android

 Side effects:
 - performs remote backend listing, download, marker, and device-folder creation requests
 - may restore a full staged initial backup into local SwiftData
 - may replay staged remote patches into local SwiftData and local-only fidelity stores
 - may upload one outbound sparse reading-plan patch and rewrite local baseline metadata after success
 - persists bootstrap, patch-status, and progress metadata through `SettingsStore`
 - creates and removes temporary staged archive files beneath the configured temporary directory

 Failure modes:
 - throws `RemoteSyncSynchronizationError.missingInitialBackup` when a remotely adopted folder has no `initial.sqlite3.gz`
 - rethrows remote transport failures from the backend adapter
 - rethrows archive staging, initial-backup restore, discovery, and patch-apply failures from the lower layers
 - only reverts `lastSynchronized` automatically for Android's incompatible-patch-version branch

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement requirements of the supplied
   `SettingsStore` and `ModelContext`
 */
public final class RemoteSyncSynchronizationService {
    private let adapter: any RemoteSyncAdapting
    private let bundleIdentifier: String
    private let deviceIdentifier: String
    private let initialBackupRestoreService: RemoteSyncInitialBackupRestoreService
    private let readingPlanPatchApplyService: RemoteSyncReadingPlanPatchApplyService
    private let readingPlanPatchUploadService: RemoteSyncReadingPlanPatchUploadService
    private let bookmarkPatchApplyService: RemoteSyncBookmarkPatchApplyService
    private let workspacePatchApplyService: RemoteSyncWorkspacePatchApplyService
    private let fileManager: FileManager
    private let temporaryDirectory: URL?
    private let nowProvider: () -> Int64

    /**
     Creates a synchronization coordinator for one remote backend.

     - Parameters:
       - adapter: Remote backend adapter used for bootstrap inspection, discovery, and downloads.
       - bundleIdentifier: App bundle identifier used to build Android-style sync folder names.
       - deviceIdentifier: Stable device identifier used for device folders and patch-zero bookkeeping.
       - initialBackupRestoreService: Service used to restore staged initial backups.
       - readingPlanPatchApplyService: Reading-plan patch replay service.
       - readingPlanPatchUploadService: Reading-plan outbound patch upload service.
       - bookmarkPatchApplyService: Bookmark patch replay service.
       - workspacePatchApplyService: Workspace patch replay service.
       - fileManager: File manager used for staging cleanup.
       - temporaryDirectory: Optional staging directory override.
       - nowProvider: Millisecond clock used for Android-aligned sync progress timestamps.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        adapter: any RemoteSyncAdapting,
        bundleIdentifier: String,
        deviceIdentifier: String,
        initialBackupRestoreService: RemoteSyncInitialBackupRestoreService = RemoteSyncInitialBackupRestoreService(),
        readingPlanPatchApplyService: RemoteSyncReadingPlanPatchApplyService = RemoteSyncReadingPlanPatchApplyService(),
        readingPlanPatchUploadService: RemoteSyncReadingPlanPatchUploadService? = nil,
        bookmarkPatchApplyService: RemoteSyncBookmarkPatchApplyService = RemoteSyncBookmarkPatchApplyService(),
        workspacePatchApplyService: RemoteSyncWorkspacePatchApplyService = RemoteSyncWorkspacePatchApplyService(),
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        nowProvider: @escaping () -> Int64 = {
            Int64(Date().timeIntervalSince1970 * 1000.0)
        }
    ) {
        self.adapter = adapter
        self.bundleIdentifier = bundleIdentifier
        self.deviceIdentifier = deviceIdentifier
        self.initialBackupRestoreService = initialBackupRestoreService
        self.readingPlanPatchApplyService = readingPlanPatchApplyService
        self.readingPlanPatchUploadService = readingPlanPatchUploadService
            ?? RemoteSyncReadingPlanPatchUploadService(
                adapter: adapter,
                nowProvider: nowProvider
            )
        self.bookmarkPatchApplyService = bookmarkPatchApplyService
        self.workspacePatchApplyService = workspacePatchApplyService
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
        self.nowProvider = nowProvider
    }

    /**
     Synchronizes one category when its bootstrap state is either already ready or still requires a user decision.

     The method mirrors Android's top-level branch point:
     - ready categories proceed directly into remote patch discovery/application
     - same-named remote folders surface an adoption decision
     - missing remote folders surface a create-new decision

     - Parameters:
       - category: Logical sync category to synchronize.
       - modelContext: SwiftData context whose category-specific models may be rewritten.
       - settingsStore: Local-only settings store backing bootstrap and sync metadata.
       - currentSchemaVersion: Highest schema version the caller can safely read from remote archives.
     - Returns: Either a user-decision requirement or a completed synchronization report.
     - Side effects:
       - may perform remote bootstrap validation requests
       - may stage and replay remote patches when the category is already ready
       - may update `lastSynchronized` bookkeeping in `RemoteSyncStateStore`
     - Failure modes:
       - rethrows bootstrap validation, discovery, staging, and patch-apply failures from the lower layers
     */
    public func synchronize(
        _ category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        currentSchemaVersion: Int = 1
    ) async throws -> RemoteSyncSynchronizationOutcome {
        let bootstrapCoordinator = makeBootstrapCoordinator(settingsStore: settingsStore)

        switch try await bootstrapCoordinator.inspect(category) {
        case .ready(let bootstrapState):
            let report = try await synchronizeReadyCategory(
                category,
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore,
                currentSchemaVersion: currentSchemaVersion,
                initialRestoreReport: nil
            )
            return .synchronized(report)
        case .requiresRemoteAdoption(let candidate):
            return .requiresRemoteAdoption(candidate)
        case .requiresRemoteCreation(let creation):
            return .requiresRemoteCreation(creation)
        }
    }

    /**
     Adopts a discovered remote folder, restores its initial backup, and then applies any newer patches.

     This method mirrors Android's "copy from cloud" branch after the user chooses to adopt a
     same-named remote sync folder:
     - mark the folder as owned locally
     - create the current device's patch folder
     - download and restore `initial.sqlite3.gz`
     - record patch zero for the current device
     - continue with normal pending-patch discovery/application

     - Parameters:
       - category: Logical sync category being adopted.
       - remoteFolderID: Remote identifier of the existing category sync folder to adopt.
       - modelContext: SwiftData context whose category-specific models may be rewritten.
       - settingsStore: Local-only settings store backing bootstrap and sync metadata.
       - currentSchemaVersion: Highest schema version the caller can safely read from remote archives.
     - Returns: Completed synchronization report including the initial-backup restore summary.
     - Side effects:
       - uploads a new secret marker file and creates the device folder beneath the adopted sync folder
       - downloads and restores `initial.sqlite3.gz`
       - records patch zero for the current device in `RemoteSyncPatchStatusStore`
       - updates `lastPatchWritten` and `lastSynchronized` bookkeeping in `RemoteSyncStateStore`
       - may stage and replay newer remote patches after the initial restore
     - Failure modes:
       - throws `RemoteSyncSynchronizationError.missingInitialBackup` when the adopted folder has no remote initial backup
       - rethrows bootstrap, staging, restore, discovery, and patch-apply failures from the lower layers
     */
    public func adoptRemoteFolderAndSynchronize(
        for category: RemoteSyncCategory,
        remoteFolderID: String,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        currentSchemaVersion: Int = 1
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let bootstrapCoordinator = makeBootstrapCoordinator(settingsStore: settingsStore)
        let discoveryService = makePatchDiscoveryService(settingsStore: settingsStore)
        let stagingService = makeArchiveStagingService()

        let bootstrapState = try await bootstrapCoordinator.adoptRemoteFolder(
            for: category,
            remoteFolderID: remoteFolderID
        )
        guard let syncFolderID = bootstrapState.syncFolderID,
              let initialBackup = try await discoveryService.findInitialBackup(syncFolderID: syncFolderID) else {
            throw RemoteSyncSynchronizationError.missingInitialBackup(category)
        }

        let stagedBackup = try await stagingService.downloadInitialBackup(
            initialBackup,
            currentSchemaVersion: currentSchemaVersion
        )
        defer { stagingService.cleanupInitialBackup(stagedBackup) }

        let initialRestoreReport = try initialBackupRestoreService.restoreInitialBackup(
            stagedBackup,
            category: category,
            modelContext: modelContext,
            settingsStore: settingsStore
        )

        patchStatusStore.addStatus(
            RemoteSyncPatchStatus(
                sourceDevice: deviceIdentifier,
                patchNumber: 0,
                sizeBytes: initialBackup.size,
                appliedDate: initialBackup.timestamp
            ),
            for: category
        )

        var progressState = stateStore.progressState(for: category)
        progressState.lastPatchWritten = nowProvider()
        stateStore.setProgressState(progressState, for: category)

        return try await synchronizeReadyCategory(
            category,
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            currentSchemaVersion: currentSchemaVersion,
            initialRestoreReport: initialRestoreReport
        )
    }

    /**
     Synchronizes a category that already has a ready bootstrap state.

     The method persists Android-style `lastSynchronized` bookkeeping before discovery so a later
     sync can still see patches that are uploaded while the current run is in flight. Android also
     retries once from `lastSynchronized = 0` when incremental discovery proves patches were
     skipped, and that behavior is preserved here.

     - Parameters:
       - category: Logical sync category that already has a valid bootstrap state.
       - bootstrapState: Ready bootstrap identifiers for the category.
       - modelContext: SwiftData context whose category-specific models may be rewritten.
       - settingsStore: Local-only settings store backing bootstrap and sync metadata.
       - currentSchemaVersion: Highest schema version the caller can safely read from remote archives.
       - initialRestoreReport: Optional initial-backup restore summary that should be carried into the final report.
     - Returns: Completed synchronization report for the ready category.
     - Side effects:
       - updates `lastSynchronized` bookkeeping in `RemoteSyncStateStore`
       - may stage and replay remote patches
     - Failure modes:
       - rethrows discovery, staging, and patch-apply failures from the lower layers
       - retries once after `RemoteSyncPatchDiscoveryError.patchFilesSkipped`
       - restores the previous `lastSynchronized` value for `RemoteSyncPatchDiscoveryError.incompatiblePatchVersion`
     */
    private func synchronizeReadyCategory(
        _ category: RemoteSyncCategory,
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        currentSchemaVersion: Int,
        initialRestoreReport: RemoteSyncInitialBackupRestoreReport?
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let originalProgressState = stateStore.progressState(for: category)

        do {
            return try await synchronizeReadyAttempt(
                category,
                bootstrapState: bootstrapState,
                progressState: originalProgressState,
                modelContext: modelContext,
                settingsStore: settingsStore,
                currentSchemaVersion: currentSchemaVersion,
                initialRestoreReport: initialRestoreReport
            )
        } catch RemoteSyncPatchDiscoveryError.patchFilesSkipped {
            var resetProgressState = originalProgressState
            resetProgressState.lastSynchronized = 0
            stateStore.setProgressState(resetProgressState, for: category)

            return try await synchronizeReadyAttempt(
                category,
                bootstrapState: bootstrapState,
                progressState: resetProgressState,
                modelContext: modelContext,
                settingsStore: settingsStore,
                currentSchemaVersion: currentSchemaVersion,
                initialRestoreReport: initialRestoreReport
            )
        } catch RemoteSyncPatchDiscoveryError.incompatiblePatchVersion(let version) {
            stateStore.setProgressState(originalProgressState, for: category)
            throw RemoteSyncPatchDiscoveryError.incompatiblePatchVersion(version)
        } catch {
            throw error
        }
    }

    /**
     Runs one ready-state synchronization attempt without the outer skipped-patch retry wrapper.

     - Parameters:
       - category: Logical sync category being synchronized.
       - bootstrapState: Ready bootstrap identifiers for the category.
       - progressState: Progress state that should be used as the Android discovery baseline.
       - modelContext: SwiftData context whose category-specific models may be rewritten.
       - settingsStore: Local-only settings store backing bootstrap and sync metadata.
       - currentSchemaVersion: Highest schema version the caller can safely read from remote archives.
       - initialRestoreReport: Optional initial-backup restore summary that should be carried into the final report.
     - Returns: Completed synchronization report for one ready-state attempt.
     - Side effects:
       - persists `lastSynchronized` before remote discovery
       - stages, downloads, and replays remote patches when discovery finds any
       - may upload one outbound sparse patch after replay when the category supports local export
         and the pass did not just restore remote baseline state from `initial.sqlite3.gz`
       - removes staged patch archives after application or failure
     - Failure modes:
       - rethrows discovery, staging, patch-apply, and patch-upload failures from the lower layers
     */
    private func synchronizeReadyAttempt(
        _ category: RemoteSyncCategory,
        bootstrapState: RemoteSyncBootstrapState,
        progressState: RemoteSyncProgressState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        currentSchemaVersion: Int,
        initialRestoreReport: RemoteSyncInitialBackupRestoreReport?
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let discoveryService = makePatchDiscoveryService(settingsStore: settingsStore)
        let stagingService = makeArchiveStagingService()

        let syncStartedAt = nowProvider()
        var updatedProgressState = progressState
        updatedProgressState.lastSynchronized = syncStartedAt
        stateStore.setProgressState(updatedProgressState, for: category)

        let discoveryResult = try await discoveryService.discoverPendingPatches(
            for: category,
            bootstrapState: bootstrapState,
            progressState: progressState,
            currentSchemaVersion: currentSchemaVersion
        )

        let patchReplayReport: RemoteSyncCategoryPatchReplayReport?
        if discoveryResult.pendingPatches.isEmpty {
            patchReplayReport = nil
        } else {
            let stagedArchives = try await stagingService.downloadPatchArchives(discoveryResult.pendingPatches)
            defer { stagingService.cleanupPatchArchives(stagedArchives) }
            patchReplayReport = try applyPendingPatches(
                for: category,
                stagedArchives: stagedArchives,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }

        let patchUploadReport: RemoteSyncCategoryPatchUploadReport?
        if initialRestoreReport == nil {
            patchUploadReport = try await uploadPendingPatchIfSupported(
                for: category,
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        } else {
            patchUploadReport = nil
        }

        let finalProgressState = stateStore.progressState(for: category)
        return RemoteSyncCategorySynchronizationReport(
            category: category,
            bootstrapState: bootstrapState,
            initialRestoreReport: initialRestoreReport,
            patchReplayReport: patchReplayReport,
            patchUploadReport: patchUploadReport,
            discoveredPatchCount: discoveryResult.pendingPatches.count,
            lastPatchWritten: finalProgressState.lastPatchWritten,
            lastSynchronized: finalProgressState.lastSynchronized
        )
    }

    /**
     Applies staged patch archives using the category-specific replay engine.

     - Parameters:
       - category: Logical sync category whose replay engine should be used.
       - stagedArchives: Previously staged patch archives in application order.
       - modelContext: SwiftData context whose category-specific models may be rewritten.
       - settingsStore: Local-only settings store backing fidelity metadata and sync bookkeeping.
     - Returns: Category-specific patch replay summary.
     - Side effects:
       - rewrites category-specific SwiftData rows and local-only sync metadata
     - Failure modes:
       - rethrows category-specific patch-apply failures from the lower layers
     */
    private func applyPendingPatches(
        for category: RemoteSyncCategory,
        stagedArchives: [RemoteSyncStagedPatchArchive],
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) throws -> RemoteSyncCategoryPatchReplayReport {
        switch category {
        case .bookmarks:
            return .bookmarks(
                try bookmarkPatchApplyService.applyPatchArchives(
                    stagedArchives,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            )
        case .workspaces:
            return .workspaces(
                try workspacePatchApplyService.applyPatchArchives(
                    stagedArchives,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            )
        case .readingPlans:
            return .readingPlans(
                try readingPlanPatchApplyService.applyPatchArchives(
                    stagedArchives,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            )
        }
    }

    /**
     Uploads one outbound sparse patch when the category already has a local export pipeline.

     Reading plans are currently the only category with a finished outbound exporter. Bookmark and
     workspace uploads remain follow-up work, so those categories intentionally return `nil` here
     even when local state has diverged.

     - Parameters:
       - category: Logical sync category whose outbound exporter should run.
       - bootstrapState: Ready bootstrap identifiers for the category.
       - modelContext: SwiftData context whose category-specific models define the local snapshot.
       - settingsStore: Local-only settings store backing preserved sync metadata.
     - Returns: Category-specific outbound upload summary when one patch was emitted; otherwise `nil`.
     - Side effects:
       - may upload one outbound sparse patch and rewrite local sync bookkeeping
     - Failure modes:
       - rethrows category-specific patch-upload failures from the lower layers
       - bookmark and workspace categories intentionally return `nil`
     */
    private func uploadPendingPatchIfSupported(
        for category: RemoteSyncCategory,
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncCategoryPatchUploadReport? {
        switch category {
        case .readingPlans:
            if let report = try await readingPlanPatchUploadService.uploadPendingPatch(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            ) {
                return .readingPlans(report)
            }
            return nil
        case .bookmarks, .workspaces:
            return nil
        }
    }

    /**
     Builds a bootstrap coordinator bound to the supplied local settings store.

     - Parameter settingsStore: Local-only settings store backing bootstrap metadata.
     - Returns: Bootstrap coordinator configured for this service's backend and device identity.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func makeBootstrapCoordinator(settingsStore: SettingsStore) -> RemoteSyncBootstrapCoordinator {
        RemoteSyncBootstrapCoordinator(
            adapter: adapter,
            stateStore: RemoteSyncStateStore(settingsStore: settingsStore),
            bundleIdentifier: bundleIdentifier,
            deviceIdentifier: deviceIdentifier
        )
    }

    /**
     Builds a patch-discovery service bound to the supplied local settings store.

     - Parameter settingsStore: Local-only settings store backing applied-patch bookkeeping.
     - Returns: Patch-discovery service configured for this service's backend.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func makePatchDiscoveryService(settingsStore: SettingsStore) -> RemoteSyncPatchDiscoveryService {
        RemoteSyncPatchDiscoveryService(
            adapter: adapter,
            statusStore: RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        )
    }

    /**
     Builds an archive-staging service that shares this coordinator's temporary-file settings.

     - Returns: Archive-staging service configured for this service's backend and staging directory.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func makeArchiveStagingService() -> RemoteSyncArchiveStagingService {
        RemoteSyncArchiveStagingService(
            adapter: adapter,
            fileManager: fileManager,
            temporaryDirectory: temporaryDirectory
        )
    }
}
