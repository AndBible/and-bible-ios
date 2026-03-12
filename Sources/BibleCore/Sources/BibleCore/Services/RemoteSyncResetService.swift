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
    private let settingsStore: SettingsStore

    /**
     Creates a local remote-sync reset service.

     - Parameter settingsStore: Local-only settings store bound to the current `ModelContext`.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /**
     Clears Android-aligned local remote-sync metadata for every sync category.

     - Side effects:
       - disables all remote-sync category toggles in `RemoteSyncSettingsStore`
       - clears bootstrap and progress metadata in `RemoteSyncStateStore`
       - clears applied-patch bookkeeping in `RemoteSyncPatchStatusStore`
       - clears preserved Android log-entry and fidelity payload stores
       - clears the global remote-sync throttle timestamp
     - Failure modes:
       - underlying `SettingsStore` writes are best-effort and may be swallowed by the individual stores
     */
    public func resetAllCategories() {
        let remoteSettingsStore = RemoteSyncSettingsStore(settingsStore: settingsStore)
        let stateStore = RemoteSyncStateStore(settingsStore: settingsStore)
        let patchStatusStore = RemoteSyncPatchStatusStore(settingsStore: settingsStore)
        let logEntryStore = RemoteSyncLogEntryStore(settingsStore: settingsStore)

        for category in RemoteSyncCategory.allCases {
            remoteSettingsStore.setSyncEnabled(false, for: category)
            stateStore.clearCategory(category)
            patchStatusStore.clearCategory(category)
            logEntryStore.clearCategory(category)
        }

        remoteSettingsStore.globalLastSynchronized = nil
        RemoteSyncReadingPlanStatusStore(settingsStore: settingsStore).clearAll()
        RemoteSyncBookmarkPlaybackSettingsStore(settingsStore: settingsStore).clearAll()
        RemoteSyncBookmarkLabelAliasStore(settingsStore: settingsStore).clearAll()
        RemoteSyncWorkspaceFidelityStore(settingsStore: settingsStore).clearAll()
    }
}
