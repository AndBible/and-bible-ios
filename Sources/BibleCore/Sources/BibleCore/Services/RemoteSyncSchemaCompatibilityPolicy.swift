// RemoteSyncSchemaCompatibilityPolicy.swift -- Shared Android schema incompatibility behavior

import Foundation

/**
 Reports that incremental sync is intentionally paused for the current local schema generation.

 The user's category toggle remains enabled. Installing a build with a different supported schema
 clears the stale gate and retries automatically, matching Android's `disabledForVersion` contract.
 */
public enum RemoteSyncSchemaCompatibilityPolicyError: Error, Equatable {
    /// Incremental patch replay is disabled until the local schema version changes.
    case disabledForCurrentVersion(category: RemoteSyncCategory, version: Int)
}

/**
 Applies one authoritative incompatibility policy across lifecycle and manual synchronization.

 Initial backups are the required baseline and cannot be skipped, so an incompatible initial backup
 disables the category toggle. Incremental patch incompatibility records `disabledForVersion` while
 retaining the user's intent. A later app build whose local schema differs clears that stale gate
 before attempting synchronization again.
 */
struct RemoteSyncSchemaCompatibilityPolicy {
    private let settingsStore: SettingsStore

    /** Creates a policy bound to the synchronization operation's settings context. */
    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
     Validates or clears the category's incremental compatibility gate before normal sync.

     - Parameters:
       - category: Category about to synchronize.
       - currentSchemaVersion: Exact local Android Room schema version.
     - Side Effects: Atomically clears a stale gate written by an older local schema version.
     - Throws: `disabledForCurrentVersion` when the same local schema already rejected a patch, or
       rethrows strict settings transaction failures.
     */
    func prepareForSynchronization(
        category: RemoteSyncCategory,
        currentSchemaVersion: Int
    ) throws {
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let progress = stateStore.progressState(for: category)
        guard let disabledVersion = progress.disabledForVersion else {
            return
        }
        guard disabledVersion != currentSchemaVersion else {
            throw RemoteSyncSchemaCompatibilityPolicyError.disabledForCurrentVersion(
                category: category,
                version: currentSchemaVersion
            )
        }

        try settingsStore.performAtomicBatch {
            var refreshed = stateStore.progressState(for: category)
            refreshed.disabledForVersion = nil
            stateStore.setProgressState(refreshed, for: category)
        }
    }

    /**
     Clears an incremental gate before an explicit destination adoption or replacement.

     - Parameter category: Category whose destination generation is being replaced deliberately.
     - Side Effects: Atomically clears `disabledForVersion`; destination publication then resets the
       remaining cursor state through `RemoteSyncStateStore`.
     - Throws: Rethrows strict settings transaction failures.
     */
    func prepareForExplicitBootstrap(category: RemoteSyncCategory) throws {
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        try settingsStore.performAtomicBatch {
            var progress = stateStore.progressState(for: category)
            progress.disabledForVersion = nil
            stateStore.setProgressState(progress, for: category)
        }
    }

    /**
     Persists Android-compatible policy for a schema incompatibility emitted by a sync phase.

     - Parameters:
       - error: Failure emitted by initial staging or incremental discovery.
       - category: Category that encountered the failure.
       - currentSchemaVersion: Local Room schema used for this attempt.
     - Returns: `true` when `error` was a recognized schema incompatibility.
     - Side Effects:
       - initial incompatibility disables the category toggle and clears incremental gating
       - patch incompatibility retains the toggle and stores `disabledForVersion`
     - Throws: Rethrows strict settings transaction failures.
     */
    @discardableResult
    func recordIfSchemaIncompatibility(
        _ error: Error,
        category: RemoteSyncCategory,
        currentSchemaVersion: Int
    ) throws -> Bool {
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        if case RemoteSyncArchiveStagingError.incompatibleInitialBackupVersion = error {
            let remoteSettings = RemoteSyncSettingsStore(settingsStore: settingsStore)
            try settingsStore.performAtomicBatch {
                remoteSettings.setSyncEnabled(false, for: category)
                var progress = stateStore.progressState(for: category)
                progress.disabledForVersion = nil
                stateStore.setProgressState(progress, for: category)
            }
            return true
        }

        if case RemoteSyncPatchDiscoveryError.incompatiblePatchVersion = error {
            try settingsStore.performAtomicBatch {
                var progress = stateStore.progressState(for: category)
                progress.disabledForVersion = currentSchemaVersion
                stateStore.setProgressState(progress, for: category)
            }
            return true
        }
        return false
    }
}
