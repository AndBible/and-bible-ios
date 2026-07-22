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

    /// The requested category does not yet support this synchronization phase.
    case unsupportedCategory(RemoteSyncCategory)
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

    /// My Documents-category patch replay summary.
    case myDocuments(RemoteSyncMyDocumentPatchApplyReport)

    /// AI Settings-category patch replay summary.
    case aiSettings(RemoteSyncAISettingsPatchApplyReport)

    /// Progress-category patch replay summary.
    case progress(RemoteSyncProgressPatchApplyReport)
}

/**
 Category-specific outbound patch upload summary returned after one synchronization run.

 The coordinator preserves each category's native upload report because each sync stream exposes
 different counters and fidelity details.
 */
public enum RemoteSyncCategoryPatchUploadReport: Sendable, Equatable {
    /// Bookmark-category outbound patch upload summary.
    case bookmarks(RemoteSyncBookmarkPatchUploadReport)

    /// Workspace-category outbound patch upload summary.
    case workspaces(RemoteSyncWorkspacePatchUploadReport)

    /// Reading-plan-category outbound patch upload summary.
    case readingPlans(RemoteSyncReadingPlanPatchUploadReport)

    /// My Documents-category outbound patch upload summary.
    case myDocuments(RemoteSyncMyDocumentPatchUploadReport)

    /// AI Settings-category outbound patch upload summary.
    case aiSettings(RemoteSyncAISettingsPatchUploadReport)

    /// Progress-category outbound patch upload summary.
    case progress(RemoteSyncProgressPatchUploadReport)
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
 outbound patch upload for every currently supported sync category.

 This service mirrors Android's synchronization flow for the currently supported categories:
 - inspect or validate the category bootstrap state
 - surface adopt-versus-create decisions without mutating local data
 - after remote adoption, download and restore `initial.sqlite3.gz`
 - after remote creation, upload a local `initial.sqlite3.gz` baseline before continuing
 - for ready categories, upload local sparse changes before listing remote patches
 - persist Android's current-time discovery cursor before SEARCH, then stage and replay remote patches
 - resume interrupted initial restore/upload work from persisted bootstrap phases
 - persist Android-aligned `lastPatchWritten` after publication and `lastSynchronized` before listing

 Data dependencies:
 - `RemoteSyncBootstrapCoordinator` validates or creates ready bootstrap state
 - `RemoteSyncPatchDiscoveryService` finds remote initial backups and pending patch archives
 - `RemoteSyncArchiveStagingService` downloads initial-backup and patch archives into temporary files
 - `RemoteSyncInitialBackupRestoreService` restores staged initial backups into local SwiftData
 - `RemoteSyncInitialBackupUploadService` exports and uploads local initial backups into fresh remote folders
 - category-specific patch apply services replay staged Android patch archives into local SwiftData
 - `RemoteSyncBookmarkPatchUploadService` exports and uploads outbound sparse bookmark patches
 - `RemoteSyncWorkspacePatchUploadService` exports and uploads outbound sparse workspace patches
 - `RemoteSyncReadingPlanPatchUploadService` exports and uploads outbound sparse reading-plan patches
 - `RemoteSyncMyDocumentPatchApplyService` replays inbound sparse My Documents patches
 - `RemoteSyncMyDocumentPatchUploadService` exports and uploads outbound sparse My Documents patches
 - `RemoteSyncAISettingsPatchApplyService` replays inbound non-secret AI settings patches
 - `RemoteSyncAISettingsPatchUploadService` exports non-secret AI settings patches
 - `RemoteSyncStateStore` persists Android-aligned bootstrap and progress metadata locally
 - `RemoteSyncPatchStatusStore` records patch zero after remote initial-backup adoption, matching Android

 Side effects:
 - performs remote backend listing, download, marker, and device-folder creation requests
 - may restore a full staged initial backup into local SwiftData
 - may export and upload a full staged initial backup from local SwiftData into a fresh remote folder
 - may replay staged remote patches into local SwiftData and local-only fidelity stores
 - may upload one outbound sparse category patch and rewrite local baseline metadata after success
 - persists bootstrap, patch-status, and progress metadata through `SettingsStore`
 - creates and removes temporary staged archive files beneath the configured temporary directory

 Failure modes:
 - throws `RemoteSyncSynchronizationError.missingInitialBackup` when a remotely adopted folder has no `initial.sqlite3.gz`
 - rethrows remote transport failures from the backend adapter
 - rethrows archive staging, initial-backup restore, discovery, and patch-apply failures from the lower layers
 - ordinary errors and cancellation retain the pre-list current-time cursor, skipped discovery
   retains zero for a full retry, and incompatible schema restores the prior cursor

 Concurrency:
 - this type is not `Sendable`; callers must respect the confinement requirements of the supplied
   `SettingsStore` and `ModelContext`
 */
public final class RemoteSyncSynchronizationService {
    private let adapter: any RemoteSyncAdapting
    private let bundleIdentifier: String
    private let deviceIdentifier: String
    private let initialBackupRestoreService: RemoteSyncInitialBackupRestoreService
    private let initialBackupUploadService: RemoteSyncInitialBackupUploadService
    private let readingPlanPatchApplyService: RemoteSyncReadingPlanPatchApplyService
    private let readingPlanPatchUploadService: RemoteSyncReadingPlanPatchUploadService
    private let bookmarkPatchApplyService: RemoteSyncBookmarkPatchApplyService
    private let bookmarkPatchUploadService: RemoteSyncBookmarkPatchUploadService
    private let workspacePatchApplyService: RemoteSyncWorkspacePatchApplyService
    private let workspacePatchUploadService: RemoteSyncWorkspacePatchUploadService
    private let myDocumentPatchApplyService: RemoteSyncMyDocumentPatchApplyService
    private let myDocumentPatchUploadService: RemoteSyncMyDocumentPatchUploadService
    private let aiSettingsPatchApplyService: RemoteSyncAISettingsPatchApplyService
    private let aiSettingsPatchUploadService: RemoteSyncAISettingsPatchUploadService
    private let progressPatchApplyService: RemoteSyncProgressPatchApplyService
    private let progressPatchUploadService: RemoteSyncProgressPatchUploadService
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
       - initialBackupUploadService: Service used to export and upload local initial backups into fresh remote folders.
       - readingPlanPatchApplyService: Reading-plan patch replay service.
       - readingPlanPatchUploadService: Reading-plan outbound patch upload service.
       - bookmarkPatchApplyService: Bookmark patch replay service.
       - bookmarkPatchUploadService: Bookmark outbound patch upload service.
       - workspacePatchApplyService: Workspace patch replay service.
       - workspacePatchUploadService: Workspace outbound patch upload service.
       - myDocumentPatchApplyService: My Documents patch replay service.
       - myDocumentPatchUploadService: My Documents outbound patch upload service.
       - aiSettingsPatchApplyService: AI Settings patch replay service.
       - aiSettingsPatchUploadService: AI Settings outbound patch upload service.
       - progressPatchApplyService: Progress patch replay service.
       - progressPatchUploadService: Progress outbound patch upload service.
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
        initialBackupUploadService: RemoteSyncInitialBackupUploadService? = nil,
        readingPlanPatchApplyService: RemoteSyncReadingPlanPatchApplyService = RemoteSyncReadingPlanPatchApplyService(),
        readingPlanPatchUploadService: RemoteSyncReadingPlanPatchUploadService? = nil,
        bookmarkPatchApplyService: RemoteSyncBookmarkPatchApplyService = RemoteSyncBookmarkPatchApplyService(),
        bookmarkPatchUploadService: RemoteSyncBookmarkPatchUploadService? = nil,
        workspacePatchApplyService: RemoteSyncWorkspacePatchApplyService = RemoteSyncWorkspacePatchApplyService(),
        workspacePatchUploadService: RemoteSyncWorkspacePatchUploadService? = nil,
        myDocumentPatchApplyService: RemoteSyncMyDocumentPatchApplyService = RemoteSyncMyDocumentPatchApplyService(),
        myDocumentPatchUploadService: RemoteSyncMyDocumentPatchUploadService? = nil,
        aiSettingsPatchApplyService: RemoteSyncAISettingsPatchApplyService = RemoteSyncAISettingsPatchApplyService(),
        aiSettingsPatchUploadService: RemoteSyncAISettingsPatchUploadService? = nil,
        progressPatchApplyService: RemoteSyncProgressPatchApplyService = RemoteSyncProgressPatchApplyService(),
        progressPatchUploadService: RemoteSyncProgressPatchUploadService? = nil,
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
        self.initialBackupUploadService = initialBackupUploadService
            ?? RemoteSyncInitialBackupUploadService(
                adapter: adapter,
                deviceIdentifier: deviceIdentifier,
                nowProvider: nowProvider
            )
        self.readingPlanPatchApplyService = readingPlanPatchApplyService
        self.readingPlanPatchUploadService = readingPlanPatchUploadService
            ?? RemoteSyncReadingPlanPatchUploadService(
                adapter: adapter,
                nowProvider: nowProvider
            )
        self.bookmarkPatchApplyService = bookmarkPatchApplyService
        self.bookmarkPatchUploadService = bookmarkPatchUploadService
            ?? RemoteSyncBookmarkPatchUploadService(
                adapter: adapter,
                nowProvider: nowProvider
            )
        self.workspacePatchApplyService = workspacePatchApplyService
        self.workspacePatchUploadService = workspacePatchUploadService
            ?? RemoteSyncWorkspacePatchUploadService(
                adapter: adapter,
                nowProvider: nowProvider
            )
        self.myDocumentPatchApplyService = myDocumentPatchApplyService
        self.myDocumentPatchUploadService = myDocumentPatchUploadService
            ?? RemoteSyncMyDocumentPatchUploadService(
                adapter: adapter,
                nowProvider: nowProvider
            )
        self.aiSettingsPatchApplyService = aiSettingsPatchApplyService
        self.aiSettingsPatchUploadService = aiSettingsPatchUploadService
            ?? RemoteSyncAISettingsPatchUploadService(
                adapter: adapter,
                nowProvider: nowProvider
            )
        self.progressPatchApplyService = progressPatchApplyService
        self.progressPatchUploadService = progressPatchUploadService
            ?? RemoteSyncProgressPatchUploadService(
                adapter: adapter,
                nowProvider: nowProvider
            )
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
        currentSchemaVersion: Int
    ) async throws -> RemoteSyncSynchronizationOutcome {
        try await RemoteSyncProcessSynchronizationGate.shared.withPermit {
            let compatibilityPolicy = RemoteSyncSchemaCompatibilityPolicy(settingsStore: settingsStore)
            try compatibilityPolicy.prepareForSynchronization(
                category: category,
                currentSchemaVersion: currentSchemaVersion
            )
            do {
                return try await synchronizeWhileHoldingProcessPermit(
                    category,
                    modelContext: modelContext,
                    settingsStore: settingsStore,
                    currentSchemaVersion: currentSchemaVersion
                )
            } catch {
                try compatibilityPolicy.recordIfSchemaIncompatibility(
                    error,
                    category: category,
                    currentSchemaVersion: currentSchemaVersion
                )
                throw error
            }
        }
    }

    /**
     Executes top-level synchronization after the caller acquires the process-wide permit.

     - Parameters:
       - category: Category to inspect or synchronize.
       - modelContext: Context owning synchronized graph state.
       - settingsStore: Local settings store bound to `modelContext`.
       - currentSchemaVersion: Exact Android Room schema supported locally.
     - Returns: Bootstrap decision or completed synchronization outcome.
     - Side Effects: Performs the documented bootstrap, restore, replay, and upload phases.
     - Throws: Rethrows all phase failures; the public wrapper persists schema policy first.
     */
    private func synchronizeWhileHoldingProcessPermit(
        _ category: RemoteSyncCategory,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        currentSchemaVersion: Int
    ) async throws -> RemoteSyncSynchronizationOutcome {
        let bootstrapCoordinator = makeBootstrapCoordinator(settingsStore: settingsStore)

        switch try await bootstrapCoordinator.inspect(category) {
        case .ready(let bootstrapState):
            try finishDestinationReplacementIfNeeded(
                for: category,
                settingsStore: settingsStore
            )
            let report = try await synchronizeReadyCategory(
                category,
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore,
                currentSchemaVersion: currentSchemaVersion,
                initialRestoreReport: nil,
                suppressOutboundUpload: false
            )
            return .synchronized(report)
        case .requiresInitialRestore(let bootstrapState):
            try finishDestinationReplacementIfNeeded(
                for: category,
                settingsStore: settingsStore
            )
            let report = try await restorePendingRemoteInitialBackupAndSynchronize(
                for: category,
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore,
                currentSchemaVersion: currentSchemaVersion,
                initialPublishCheckpoint: { try Task.checkCancellation() }
            )
            return .synchronized(report)
        case .requiresInitialUpload(let bootstrapState):
            try finishDestinationReplacementIfNeeded(
                for: category,
                settingsStore: settingsStore
            )
            let report = try await uploadPendingLocalInitialBackupAndSynchronize(
                for: category,
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore,
                currentSchemaVersion: currentSchemaVersion
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
        currentSchemaVersion: Int
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        try await RemoteSyncProcessSynchronizationGate.shared.withPermit {
            let compatibilityPolicy = RemoteSyncSchemaCompatibilityPolicy(settingsStore: settingsStore)
            try compatibilityPolicy.prepareForExplicitBootstrap(category: category)
            do {
                return try await adoptRemoteFolderAndSynchronize(
                    for: category,
                    remoteFolderID: remoteFolderID,
                    modelContext: modelContext,
                    settingsStore: settingsStore,
                    currentSchemaVersion: currentSchemaVersion,
                    initialPublishCheckpoint: { try Task.checkCancellation() }
                )
            } catch {
                try compatibilityPolicy.recordIfSchemaIncompatibility(
                    error,
                    category: category,
                    currentSchemaVersion: currentSchemaVersion
                )
                throw error
            }
        }
    }

    /**
     Adopts a remote folder with a deterministic checkpoint at the initial publication boundary.

     Tests use the checkpoint to prove that restored graph data, metadata/fingerprints, patch zero,
     `lastPatchWritten`, and readiness roll back together. Production supplies cancellation checking.

     - Parameters:
       - category: Logical sync category being adopted.
       - remoteFolderID: Existing remote category folder selected for adoption.
       - modelContext: Clean SwiftData context shared by graph and settings stores.
       - settingsStore: Settings store bound to `modelContext`.
       - currentSchemaVersion: Highest Android database schema this build can restore.
       - initialPublishCheckpoint: Throwing callback invoked after every initial publication mutation
         has staged and before the outer transaction commits.
     - Returns: Completed synchronization report after initial restore and incremental replay.
     - Side Effects: Creates or reuses remote setup, downloads the initial backup, atomically publishes
       local initial state, and may replay newer patches.
     - Throws: Rethrows setup, download, restore, transaction, checkpoint, cancellation, and replay errors.
     */
    func adoptRemoteFolderAndSynchronize(
        for category: RemoteSyncCategory,
        remoteFolderID: String,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        currentSchemaVersion: Int,
        initialPublishCheckpoint: () throws -> Void
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        let bootstrapCoordinator = makeBootstrapCoordinator(settingsStore: settingsStore)

        let bootstrapState = try await bootstrapCoordinator.adoptRemoteFolder(
            for: category,
            remoteFolderID: remoteFolderID
        )
        try finishDestinationReplacementIfNeeded(
            for: category,
            settingsStore: settingsStore
        )
        return try await restorePendingRemoteInitialBackupAndSynchronize(
            for: category,
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            currentSchemaVersion: currentSchemaVersion,
            initialPublishCheckpoint: initialPublishCheckpoint
        )
    }

    /**
     Restores a previously prepared adopted folder and atomically publishes its initial local state.

     - Parameters:
       - category: Logical sync category awaiting remote initial restore.
       - bootstrapState: Valid marker/device-folder state retained from adoption setup.
       - modelContext: Clean SwiftData context shared by graph and settings stores.
       - settingsStore: Settings store bound to `modelContext`.
       - currentSchemaVersion: Highest Android database schema this build can restore.
       - initialPublishCheckpoint: Throwing callback immediately before the outer commit.
     - Returns: Completed synchronization report after initial publication and incremental replay.
     - Side Effects: Downloads/stages the initial backup, atomically publishes category state and
       lifecycle bookkeeping, removes staged files, and may replay newer patches.
     - Throws: Throws `missingInitialBackup` when absent and rethrows staging, restore, transaction,
       checkpoint, cancellation, discovery, and replay errors. Pending adoption survives every failure.
     */
    private func restorePendingRemoteInitialBackupAndSynchronize(
        for category: RemoteSyncCategory,
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        currentSchemaVersion: Int,
        initialPublishCheckpoint: () throws -> Void
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let discoveryService = makePatchDiscoveryService(settingsStore: settingsStore)
        let stagingService = makeArchiveStagingService()

        guard let syncFolderID = bootstrapState.syncFolderID,
              let initialBackup = try await discoveryService.findInitialBackup(syncFolderID: syncFolderID) else {
            throw RemoteSyncSynchronizationError.missingInitialBackup(category)
        }

        let stagedBackup = try await stagingService.downloadInitialBackup(
            initialBackup,
            category: category,
            currentSchemaVersion: currentSchemaVersion
        )
        defer { stagingService.cleanupInitialBackup(stagedBackup) }

        var readyBootstrapState = bootstrapState
        let initialRestoreReport: RemoteSyncInitialBackupRestoreReport
        do {
            initialRestoreReport = try settingsStore.performAtomicBatch(in: modelContext) {
                let report = try initialBackupRestoreService.restoreInitialBackup(
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

                readyBootstrapState.phase = .ready
                stateStore.setBootstrapState(readyBootstrapState, for: category)
                try initialPublishCheckpoint()
                return report
            }
        } catch {
            modelContext.rollback()
            throw error
        }

        return try await synchronizeReadyCategory(
            category,
            bootstrapState: readyBootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            currentSchemaVersion: currentSchemaVersion,
            initialRestoreReport: initialRestoreReport,
            suppressOutboundUpload: true
        )
    }

    /**
     Creates or replaces a remote folder, uploads the current local baseline as `initial.sqlite3.gz`,
     and then continues with ready-state synchronization.

     This method mirrors Android's "copy this device to cloud" branch after the user chooses to
     replace a discovered folder or create a fresh remote category folder:
     - optionally delete the stale remote folder
     - create the new sync folder, secret marker, and current device folder
     - export and upload the current local category state as `initial.sqlite3.gz`
     - continue with normal pending-patch discovery/application without echoing a sparse local patch
       in the same pass

     - Parameters:
       - category: Logical sync category being uploaded into a fresh remote folder.
       - replacingRemoteFolderID: Optional existing remote folder identifier that should be deleted before creation.
       - modelContext: SwiftData context whose category-specific models define the local baseline.
       - settingsStore: Local-only settings store backing bootstrap and sync metadata.
       - currentSchemaVersion: Highest schema version that should be encoded into the uploaded initial backup.
     - Returns: Completed synchronization report after the initial upload and ready-state replay pass.
     - Side effects:
       - may delete an existing remote folder before creating a replacement
       - creates a new remote sync folder, secret marker, and device folder
       - uploads `initial.sqlite3.gz` built from current local state
       - resets local accepted baseline metadata to patch zero
       - updates `lastSynchronized` bookkeeping in `RemoteSyncStateStore`
     - Failure modes:
       - rethrows bootstrap, upload, discovery, staging, restore, and patch-apply failures from the lower layers
     */
    public func createRemoteFolderAndSynchronize(
        for category: RemoteSyncCategory,
        replacingRemoteFolderID: String? = nil,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        currentSchemaVersion: Int
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        try await RemoteSyncProcessSynchronizationGate.shared.withPermit {
            let compatibilityPolicy = RemoteSyncSchemaCompatibilityPolicy(settingsStore: settingsStore)
            try compatibilityPolicy.prepareForExplicitBootstrap(category: category)
            do {
                return try await createRemoteFolderWhileHoldingProcessPermit(
                    for: category,
                    replacingRemoteFolderID: replacingRemoteFolderID,
                    modelContext: modelContext,
                    settingsStore: settingsStore,
                    currentSchemaVersion: currentSchemaVersion
                )
            } catch {
                try compatibilityPolicy.recordIfSchemaIncompatibility(
                    error,
                    category: category,
                    currentSchemaVersion: currentSchemaVersion
                )
                throw error
            }
        }
    }

    /**
     Creates and publishes a replacement destination after process-wide serialization is acquired.

     - Parameters:
       - category: Category whose destination should be created.
       - replacingRemoteFolderID: Optional remote folder removed before creation.
       - modelContext: Context owning the exported graph.
       - settingsStore: Local settings store bound to `modelContext`.
       - currentSchemaVersion: Exact Android Room schema to publish.
     - Returns: Completed initial upload and ready-state synchronization report.
     - Side Effects: Creates remote bootstrap resources and uploads the local initial generation.
     - Throws: Rethrows bootstrap, upload, replay, cancellation, and policy-publication failures.
     */
    private func createRemoteFolderWhileHoldingProcessPermit(
        for category: RemoteSyncCategory,
        replacingRemoteFolderID: String?,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        currentSchemaVersion: Int
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        let bootstrapCoordinator = makeBootstrapCoordinator(settingsStore: settingsStore)

        let bootstrapState = try await bootstrapCoordinator.createRemoteFolder(
            for: category,
            replacingRemoteFolderID: replacingRemoteFolderID
        )
        try finishDestinationReplacementIfNeeded(
            for: category,
            settingsStore: settingsStore
        )

        return try await uploadPendingLocalInitialBackupAndSynchronize(
            for: category,
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            currentSchemaVersion: currentSchemaVersion
        )
    }

    /**
     Uploads a prepared local initial baseline and transitions the category to ready afterward.

     - Parameters:
       - category: Logical sync category awaiting initial upload.
       - bootstrapState: Valid marker/device-folder state retained from remote setup.
       - modelContext: SwiftData context whose current category graph becomes the remote baseline.
       - settingsStore: Local settings store for baseline and lifecycle bookkeeping.
       - currentSchemaVersion: Android database schema written into the initial backup.
     - Returns: Completed synchronization report after upload acceptance and incremental discovery.
     - Side Effects: Uploads the full baseline, records its accepted baseline, atomically clears the
       pending phase, and performs a ready-state pass without echoing a sparse patch.
     - Throws: Rethrows export, upload, settings transaction, cancellation, discovery, and replay errors;
       upload failure leaves the persisted pending phase available for restart retry.
     */
    private func uploadPendingLocalInitialBackupAndSynchronize(
        for category: RemoteSyncCategory,
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        currentSchemaVersion: Int
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        var readyBootstrapState = bootstrapState
        readyBootstrapState.phase = .ready
        _ = try await initialBackupUploadService.uploadInitialBackup(
            for: category,
            bootstrapState: bootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            schemaVersion: currentSchemaVersion,
            acceptedBaselineMutations: {
                RemoteSyncStateStore(settingsStore: settingsStore).setBootstrapState(
                    readyBootstrapState,
                    for: category
                )
            }
        )

        return try await synchronizeReadyCategory(
            category,
            bootstrapState: readyBootstrapState,
            modelContext: modelContext,
            settingsStore: settingsStore,
            currentSchemaVersion: currentSchemaVersion,
            initialRestoreReport: nil,
            suppressOutboundUpload: true
        )
    }

    /**
     Completes a persisted explicit destination-replacement boundary before synchronization proceeds.

     New or repaired remote setup records a durable cleanup marker with its bootstrap identifiers.
     Cleanup removes only unaccepted sparse/initial publications for the former destination. The marker
     is cleared afterward, so a crash retries cleanup while successful initial-upload retries retain
     their exact durable archive.

     - Parameters:
       - category: Logical category whose destination setup may require cleanup.
       - settingsStore: Local store containing lifecycle and outbox metadata.
     - Side Effects: When required, abandons pending publication markers/files and clears the cleanup marker.
     - Throws: Rethrows strict settings, cancellation, or filesystem cleanup failures; the marker remains
       pending until every cleanup step succeeds.
     */
    private func finishDestinationReplacementIfNeeded(
        for category: RemoteSyncCategory,
        settingsStore: SettingsStore
    ) throws {
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        guard stateStore.requiresPendingPublicationReset(for: category) else { return }
        try RemoteSyncResetService(settingsStore: settingsStore).abandonPendingPublications(
            for: category
        )
        try stateStore.markPendingPublicationResetComplete(for: category)
    }

    /**
     Synchronizes a category that already has a ready bootstrap state.

     Android uploads first, persists the current time before remote listing, and performs one
     inbound-only retry after durably resetting the cursor to zero when discovery reports skipped
     patches. Incompatible schema restores the exact prior cursor; other failures preserve the
     already-published pre-list cursor.

     - Parameters:
       - category: Logical sync category that already has a valid bootstrap state.
       - bootstrapState: Ready bootstrap identifiers for the category.
       - modelContext: SwiftData context whose category-specific models may be rewritten.
       - settingsStore: Local-only settings store backing bootstrap and sync metadata.
       - currentSchemaVersion: Highest schema version the caller can safely read from remote archives.
       - initialRestoreReport: Optional initial-backup restore summary that should be carried into the final report.
       - suppressOutboundUpload: Whether the pass should skip sparse local upload because the same run just adopted or created the remote baseline.
     - Returns: Completed synchronization report for the ready category.
     - Side effects:
       - uploads at most once and updates `lastSynchronized` before remote listing
       - may stage and replay remote patches
       - may suppress sparse local upload when the same pass already exchanged a full initial backup
     - Failure modes:
       - rethrows discovery, staging, and patch-apply failures from the lower layers
       - retries once after `RemoteSyncPatchDiscoveryError.patchFilesSkipped`
       - incompatible schema restores the prior cursor; other failures retain Android's pre-list cursor
     */
    private func synchronizeReadyCategory(
        _ category: RemoteSyncCategory,
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore,
        currentSchemaVersion: Int,
        initialRestoreReport: RemoteSyncInitialBackupRestoreReport?,
        suppressOutboundUpload: Bool
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let originalProgressState = stateStore.progressState(for: category)
        try Task.checkCancellation()

        let resumedPatchUploadReport: RemoteSyncCategoryPatchUploadReport?
        let newPatchUploadReport: RemoteSyncCategoryPatchUploadReport?
        if suppressOutboundUpload {
            resumedPatchUploadReport = nil
            newPatchUploadReport = nil
        } else {
            resumedPatchUploadReport = try await resumePendingPatchIfSupported(
                for: category,
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
            try Task.checkCancellation()
            newPatchUploadReport = try await uploadPendingPatchIfSupported(
                for: category,
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            )
        }

        let syncStartedAt = nowProvider()
        try settingsStore.performAtomicBatch {
            var preListProgressState = stateStore.progressState(for: category)
            preListProgressState.lastSynchronized = syncStartedAt
            stateStore.setProgressState(preListProgressState, for: category)
        }
        let patchUploadReport = newPatchUploadReport ?? resumedPatchUploadReport

        do {
            do {
                return try await synchronizeReadyAttempt(
                    category,
                    bootstrapState: bootstrapState,
                    progressState: originalProgressState,
                    modelContext: modelContext,
                    settingsStore: settingsStore,
                    currentSchemaVersion: currentSchemaVersion,
                    initialRestoreReport: initialRestoreReport,
                    patchUploadReport: patchUploadReport
                )
            } catch RemoteSyncPatchDiscoveryError.patchFilesSkipped {
                var resetProgressState = stateStore.progressState(for: category)
                resetProgressState.lastSynchronized = 0
                try settingsStore.performAtomicBatch {
                    stateStore.setProgressState(resetProgressState, for: category)
                }
                return try await synchronizeReadyAttempt(
                    category,
                    bootstrapState: bootstrapState,
                    progressState: resetProgressState,
                    modelContext: modelContext,
                    settingsStore: settingsStore,
                    currentSchemaVersion: currentSchemaVersion,
                    initialRestoreReport: initialRestoreReport,
                    patchUploadReport: patchUploadReport
                )
            }
        } catch RemoteSyncPatchDiscoveryError.incompatiblePatchVersion(let version) {
            try settingsStore.performAtomicBatch {
                var restoredProgressState = stateStore.progressState(for: category)
                restoredProgressState.lastSynchronized = originalProgressState.lastSynchronized
                stateStore.setProgressState(restoredProgressState, for: category)
            }
            throw RemoteSyncPatchDiscoveryError.incompatiblePatchVersion(version)
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
       - patchUploadReport: Upload result produced once before Android's cursor/listing phase.
     - Returns: Completed synchronization report for one ready-state attempt.
     - Side effects:
       - uses the caller-provided pre-list cursor for Android-compatible discovery
       - stages, downloads, and replays remote patches when discovery finds any
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
        initialRestoreReport: RemoteSyncInitialBackupRestoreReport?,
        patchUploadReport: RemoteSyncCategoryPatchUploadReport?
    ) async throws -> RemoteSyncCategorySynchronizationReport {
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let discoveryService = makePatchDiscoveryService(settingsStore: settingsStore)
        let stagingService = makeArchiveStagingService()

        try Task.checkCancellation()

        let discoveryResult = try await discoveryService.discoverPendingPatches(
            for: category,
            bootstrapState: bootstrapState,
            progressState: progressState,
            currentSchemaVersion: currentSchemaVersion
        )
        try Task.checkCancellation()

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
        try Task.checkCancellation()

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
     Resumes one already-durable outbound generation without projecting newer local state.

     The coordinator invokes this before inbound replay. Category workers validate that any pending
     generation belongs to the active device folder and fail closed on mismatches; an absent pending
     generation returns `nil` without allocating a patch number or creating an archive.

     - Parameters:
       - category: Logical category whose durable outbox may need acceptance.
       - bootstrapState: Ready destination identifiers for the category.
       - modelContext: Clean context shared by graph-backed category workers and settings.
       - settingsStore: Local store containing category outbox and accepted-generation metadata.
     - Returns: Category-specific accepted report, or `nil` when no outbox exists.
     - Side Effects: May reconcile exact remote bytes and atomically accept one existing generation.
     - Throws: Rethrows malformed outbox, destination mismatch, byte conflict, transport, cancellation,
       stale-baseline, and atomic local-acceptance failures from category workers.
     */
    private func resumePendingPatchIfSupported(
        for category: RemoteSyncCategory,
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncCategoryPatchUploadReport? {
        switch category {
        case .bookmarks:
            return try await bookmarkPatchUploadService.resumePendingUploadIfPresent(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            ).map(RemoteSyncCategoryPatchUploadReport.bookmarks)
        case .readingPlans:
            return try await readingPlanPatchUploadService.resumePendingUploadIfPresent(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            ).map(RemoteSyncCategoryPatchUploadReport.readingPlans)
        case .workspaces:
            return try await workspacePatchUploadService.resumePendingUploadIfPresent(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            ).map(RemoteSyncCategoryPatchUploadReport.workspaces)
        case .myDocuments:
            return try await myDocumentPatchUploadService.resumePendingUploadIfPresent(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            ).map(RemoteSyncCategoryPatchUploadReport.myDocuments)
        case .aiSettings:
            return try await aiSettingsPatchUploadService.resumePendingUploadIfPresent(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            ).map(RemoteSyncCategoryPatchUploadReport.aiSettings)
        case .progress:
            return try await progressPatchUploadService.resumePendingPatchIfPresent(
                bootstrapState: bootstrapState,
                settingsStore: settingsStore
            ).map(RemoteSyncCategoryPatchUploadReport.progress)
        }
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
        case .myDocuments:
            return .myDocuments(
                try myDocumentPatchApplyService.applyPatchArchives(
                    stagedArchives,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            )
        case .aiSettings:
            return .aiSettings(
                try aiSettingsPatchApplyService.applyPatchArchives(
                    stagedArchives,
                    modelContext: modelContext,
                    settingsStore: settingsStore
                )
            )
        case .progress:
            return .progress(
                try progressPatchApplyService.applyPatchArchives(
                    stagedArchives,
                    settingsStore: settingsStore
                )
            )
        }
    }

    /**
     Uploads one outbound sparse patch when the category already has a local export pipeline.

     Categories without an outbound exporter intentionally return `nil` here even when local state
     has diverged.

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
     */
    private func uploadPendingPatchIfSupported(
        for category: RemoteSyncCategory,
        bootstrapState: RemoteSyncBootstrapState,
        modelContext: ModelContext,
        settingsStore: SettingsStore
    ) async throws -> RemoteSyncCategoryPatchUploadReport? {
        switch category {
        case .bookmarks:
            if let report = try await bookmarkPatchUploadService.uploadPendingPatch(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            ) {
                return .bookmarks(report)
            }
            return nil
        case .readingPlans:
            if let report = try await readingPlanPatchUploadService.uploadPendingPatch(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            ) {
                return .readingPlans(report)
            }
            return nil
        case .workspaces:
            if let report = try await workspacePatchUploadService.uploadPendingPatch(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            ) {
                return .workspaces(report)
            }
            return nil
        case .myDocuments:
            if let report = try await myDocumentPatchUploadService.uploadPendingPatch(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            ) {
                return .myDocuments(report)
            }
            return nil
        case .aiSettings:
            if let report = try await aiSettingsPatchUploadService.uploadPendingPatch(
                bootstrapState: bootstrapState,
                modelContext: modelContext,
                settingsStore: settingsStore
            ) {
                return .aiSettings(report)
            }
            return nil
        case .progress:
            if let report = try await progressPatchUploadService.uploadPendingPatch(
                bootstrapState: bootstrapState,
                settingsStore: settingsStore
            ) {
                return .progress(report)
            }
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
