// RemoteSyncResetService.swift — Local remote-sync bookkeeping reset

import Foundation

/**
 Clears Android-aligned local remote-sync bookkeeping without touching the user data graph.

 Android's Google Drive sign-out path disables per-category sync and clears the local sync metadata
 tables so the next sign-in starts from a clean bootstrap state. iOS keeps the synced user content
 intact, but it must still clear the local-only bookkeeping stores that drive bootstrap inspection,
 patch discovery, and fidelity preservation.
 */
public final class RemoteSyncResetService {
    /** Local setting names owned by durable category publication and accepted-generation state. */
    private enum MetadataKey {
        /// Returns the durable sparse-patch outbox marker for one category.
        static func pendingPublication(for category: RemoteSyncCategory) -> String {
            switch category {
            case .bookmarks:
                return RemoteSyncBookmarkPatchUploadService.pendingUploadKey
            case .workspaces:
                return RemoteSyncWorkspacePatchUploadService.pendingUploadKey
            case .readingPlans:
                return RemoteSyncReadingPlanPatchUploadService.pendingUploadKey
            case .myDocuments:
                return RemoteSyncMyDocumentPatchUploadService.pendingUploadKey
            case .progress:
                return RemoteSyncProgressPatchUploadService.pendingPatchSettingKey
            }
        }

        /// Returns the category snapshot worker's accepted fingerprint and row-identity payload key.
        static func acceptedBaseline(for category: RemoteSyncCategory) -> String {
            switch category {
            case .bookmarks:
                return RemoteSyncBookmarkSnapshotService.acceptedBaselineKey
            case .workspaces:
                return RemoteSyncWorkspaceSnapshotService.acceptedBaselineKey
            case .readingPlans:
                return RemoteSyncReadingPlanSnapshotService.acceptedBaselineKey
            case .myDocuments:
                return RemoteSyncMyDocumentSnapshotService.acceptedBaselineKey
            case .progress:
                return RemoteSyncProgressSnapshotService.acceptedBaselineKey
            }
        }
    }

    private let settingsStore: SettingsStore
    private let fileManager: FileManager
    private let outboxDirectories: [RemoteSyncCategory: URL]
    private let initialUploadRetryDirectory: URL

    /**
     Creates a local remote-sync reset service.

     - Parameter settingsStore: Local-only settings store bound to the current `ModelContext`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public convenience init(settingsStore: SettingsStore) {
        self.init(
            settingsStore: settingsStore,
            fileManager: .default,
            outboxDirectories: nil,
            initialUploadRetryDirectory: nil
        )
    }

    /**
     Creates a reset service with explicit durable-publication roots.

     Tests supply isolated roots so cleanup assertions never touch production Application Support.
     Production callers use the convenience initializer and share the exact locations used by the
     category upload services.

     - Parameters:
       - settingsStore: Local-only settings store bound to the current `ModelContext`.
       - fileManager: File manager used to remove durable outbox artifacts.
       - outboxDirectories: Optional exact sparse-patch outbox locations by category.
       - initialUploadRetryDirectory: Optional prepared initial-upload root override.
     - Side Effects: none until a reset operation is requested.
     - Failure modes: This initializer cannot fail.
     */
    init(
        settingsStore: SettingsStore,
        fileManager: FileManager,
        outboxDirectories: [RemoteSyncCategory: URL]?,
        initialUploadRetryDirectory: URL?
    ) {
        self.settingsStore = settingsStore
        self.fileManager = fileManager
        self.outboxDirectories = outboxDirectories ?? [
            .bookmarks: RemoteSyncBookmarkPatchUploadService.defaultOutboxDirectory(fileManager: fileManager),
            .workspaces: RemoteSyncWorkspacePatchUploadService.defaultOutboxDirectory(fileManager: fileManager),
            .readingPlans: RemoteSyncReadingPlanPatchUploadService.defaultOutboxDirectory(fileManager: fileManager),
            .myDocuments: RemoteSyncMyDocumentPatchUploadService.defaultOutboxDirectory(fileManager: fileManager),
            .progress: RemoteSyncProgressPatchUploadService.defaultOutboxDirectory(fileManager: fileManager),
        ]
        self.initialUploadRetryDirectory = initialUploadRetryDirectory
            ?? RemoteSyncInitialBackupUploadService.defaultRetryDirectory(fileManager: fileManager)
    }

    /**
     Clears Android-aligned local remote-sync metadata for every sync category.

     - Side effects:
       - disables all remote-sync category toggles in `RemoteSyncSettingsStore`
       - clears bootstrap and progress metadata in `RemoteSyncStateStore`
       - clears applied-patch bookkeeping in `RemoteSyncPatchStatusStore`
       - clears preserved Android log-entry and fidelity payload stores
       - clears the global remote-sync throttle timestamp
     - Failure modes: Compatibility callers do not receive reset failures; strict lifecycle callers
       must use `resetAllCategoriesStrict()` so settings or file cleanup failures remain visible.
     */
    public func resetAllCategories() async {
        try? await resetAllCategoriesStrict()
    }

    /**
     Strictly resets every category's complete local synchronization generation.

     User rows remain untouched. Accepted identities, fingerprints, logs, patch status, bootstrap
     state, fidelity payloads, and durable pending publications are all invalidated together so a
     later bootstrap cannot inherit metadata from the abandoned destination.

     - Side Effects:
       - atomically disables categories and clears all settings-backed synchronization metadata
       - removes durable sparse-patch and prepared initial-upload files after settings commit
       - retains every SwiftData user-content row
     - Throws: Rethrows strict settings transaction, cancellation, and filesystem cleanup failures.
     - Important: Settings are cleared before files. A file-cleanup error can leave only an orphaned
       artifact with no live manifest; retrying reset safely removes it.
     */
    func resetAllCategoriesStrict() async throws {
        try await RemoteSyncProcessSynchronizationGate.shared.withPermit {
            try resetAllCategoriesWhileHoldingProcessPermit()
        }
    }

    /**
     Clears the complete local remote-sync generation while the shared process permit is held.

     - Side Effects: Performs the settings and file cleanup documented by
       `resetAllCategoriesStrict()` without acquiring a second permit.
     - Throws: Rethrows strict transaction, cancellation, and filesystem cleanup failures.
     */
    private func resetAllCategoriesWhileHoldingProcessPermit() throws {
        let remoteSettingsStore = RemoteSyncSettingsStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)
        let fingerprintStore = RemoteSyncRowFingerprintStore(settingsStore: settingsStore)

        try settingsStore.performAtomicBatch {
            for category in RemoteSyncCategory.allCases {
                remoteSettingsStore.setSyncEnabled(false, for: category)
                stateStore.clearCategory(category)
                patchStatusStore.clearCategory(category)
                logEntryStore.clearCategory(category)
                fingerprintStore.clearCategory(category)
                settingsStore.remove(MetadataKey.pendingPublication(for: category))
                settingsStore.remove(MetadataKey.acceptedBaseline(for: category))
            }

            remoteSettingsStore.globalLastSynchronized = nil
            RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore).clearAll()
            RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore).clearAll()
            RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore).clearAll()
            RemoteSyncBookmarkAndroidBookStore(settingsStore: settingsStore).clearAll()
            RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore).clearAll()
        }

        for category in RemoteSyncCategory.allCases {
            try removePendingPublicationFiles(for: category)
        }
    }

    /**
     Abandons only unaccepted publications after an explicit category destination change.

     The accepted baseline and user rows remain intact. This ensures ordinary retries never discard
     a generation merely because a destination id differs, while a user-confirmed adopt/replace
     operation can deliberately rebuild local state for the new folder.

     - Parameter category: Category whose old destination is no longer authoritative.
     - Side Effects: Atomically removes the sparse-patch marker, then removes its archive and any
       prepared initial-upload archive/metadata files.
     - Throws: Rethrows strict settings transaction, cancellation, and filesystem cleanup failures.
     */
    func abandonPendingPublications(for category: RemoteSyncCategory) throws {
        try settingsStore.performAtomicBatch {
            settingsStore.remove(MetadataKey.pendingPublication(for: category))
        }
        try removePendingPublicationFiles(for: category)
    }

    /**
     Removes file-backed sparse and initial publication artifacts for one category.

     - Parameter category: Category whose settings-backed marker has already been invalidated.
     - Side Effects: Removes the category outbox directory and both prepared initial-upload files
       when present.
     - Throws: Rethrows filesystem removal failures so explicit reset/replacement cannot report
       success while stale destination-bound artifacts remain.
     */
    private func removePendingPublicationFiles(for category: RemoteSyncCategory) throws {
        if let outboxURL = outboxDirectories[category] {
            if fileManager.fileExists(atPath: outboxURL.path) {
                try fileManager.removeItem(at: outboxURL)
            }
        }

        let initialArchiveURL = RemoteSyncInitialBackupUploadService.pendingArchiveURL(
            for: category,
            retryDirectory: initialUploadRetryDirectory
        )
        let initialMetadataURL = RemoteSyncInitialBackupUploadService.pendingMetadataURL(
            for: category,
            retryDirectory: initialUploadRetryDirectory
        )
        for url in [initialArchiveURL, initialMetadataURL]
        where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
