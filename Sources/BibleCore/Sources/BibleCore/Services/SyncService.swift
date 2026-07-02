// SyncService.swift — iCloud/CloudKit sync monitoring

import Foundation
import Observation
import CloudKit
import SwiftData

/// Current sync state.
public enum SyncState: Sendable, Equatable {
    case disabled
    case noAccount
    case idle
    case syncing
    case error(String)
    /// User toggled sync in a host that cannot rebuild the runtime data stack in-session.
    case pendingRestart
}

/**
 Result produced after a host app applies a requested iCloud sync mode change.

 `SyncService` owns the persisted toggle and public status, but the app shell owns SwiftData
 container construction. Returning the effective mode keeps CloudKit startup recovery honest: if a
 requested CloudKit container fails and the app falls back to local storage, the visible toggle
 returns to disabled instead of requiring a relaunch.
 */
public struct SyncModeChangeResult {
    /// Runtime mode that actually became active after the app rebuilt its data stack.
    public let effectiveEnabled: Bool

    /**
     Container the service should monitor for CloudKit remote-change notifications.

     Return `nil` when `effectiveEnabled` is false, or when a non-app host intentionally accepts
     state-only behavior. If `effectiveEnabled` is true and this is `nil`, `SyncService` will update
     visible state but will not restart remote-change monitoring.
     */
    public let modelContainer: ModelContainer?

    /**
     Creates one live sync-mode change result.

     - Parameters:
       - effectiveEnabled: Runtime iCloud mode after the app attempted the change.
       - modelContainer: Container to monitor when `effectiveEnabled` is true. Passing `nil` leaves
         remote-change monitoring stopped for this result.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(effectiveEnabled: Bool, modelContainer: ModelContainer? = nil) {
        self.effectiveEnabled = effectiveEnabled
        self.modelContainer = modelContainer
    }
}

/**
 Manages iCloud/CloudKit sync status monitoring.

 SwiftData handles actual data sync automatically when configured with
 `cloudKitDatabase: .private(...)`. This service monitors account status,
 observes remote change notifications, and exposes state to the UI.

 ## Conflict Resolution
 SwiftData's CloudKit integration uses NSPersistentCloudKitContainer under
 the hood, which applies **last-writer-wins** conflict resolution automatically.
 When the same record is modified on two devices, the most recent write wins
 after CloudKit reconciles. No explicit merge policy code is needed.
 */
@Observable
public final class SyncService {
    /// Host callback that rebuilds SwiftData for a requested iCloud mode.
    public typealias ModeChangeHandler = @MainActor (_ requestedEnabled: Bool) throws -> SyncModeChangeResult

    /// Current sync state.
    public private(set) var state: SyncState = .disabled

    /// Last time a remote change notification was received.
    public private(set) var lastSyncDate: Date?

    /**
     Whether iCloud sync is enabled (persisted in UserDefaults).
     This reflects the active runtime mode after any installed mode-change handler completes.
     */
    public private(set) var isEnabled: Bool = false

    /// Whether the current host requires a restart because no live mode-change handler is installed.
    public private(set) var requiresRestart: Bool = false

    /// The iCloud account display name, if available.
    public private(set) var accountDescription: String?

    /**
     The sync mode that is currently active for this service.

     App startup seeds this value from the loaded SwiftData container. When the production app
     installs a live mode-change handler, `toggleSync()` updates it after the app shell rebuilds
     the container; hosts without that handler leave it unchanged and enter `.pendingRestart`.
     */
    private var activeMode: Bool = false

    private var notificationObserver: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?
    private let defaults: UserDefaults
    private let syncEnabledKey: String
    private var modeChangeHandler: ModeChangeHandler?

    /**
     Creates an idle sync monitor. Call `setInitialState(enabled:)` during app startup before
     `startMonitoring(container:)`.

     - Parameters:
       - defaults: Preference store that owns the iCloud sync toggle.
       - syncEnabledKey: Preference key for the iCloud sync toggle.
     - Side effects: none.
     - Failure modes: This initializer cannot fail.
     */
    public init(
        defaults: UserDefaults = .standard,
        syncEnabledKey: String = "icloud_sync_enabled"
    ) {
        self.defaults = defaults
        self.syncEnabledKey = syncEnabledKey
    }

    deinit {
        stopMonitoring()
    }

    /**
     Set the enabled state without triggering side effects.
     Called during app init before monitoring starts.
     */
    public func setInitialState(enabled: Bool) {
        isEnabled = enabled
        activeMode = enabled
        requiresRestart = false
        state = enabled ? .idle : .disabled
    }

    /**
     Installs the app-shell hook that can rebuild SwiftData for iCloud mode changes.

     Production app startup installs this handler so Settings can apply the toggle immediately.
     Test hosts and previews may leave it unset; `toggleSync()` then preserves the old explicit
     restart-required fallback instead of silently pretending a container was rebuilt.
     */
    @MainActor
    public func setModeChangeHandler(_ handler: ModeChangeHandler?) {
        modeChangeHandler = handler
    }

    // MARK: - Monitoring

    /**
     Start monitoring iCloud account status and remote change notifications.
     Call after ModelContainer is created.
     */
    public func startMonitoring(container: ModelContainer) {
        guard activeMode else {
            state = .disabled
            return
        }

        checkAccountStatus()

        // Observe remote change notifications from NSPersistentCloudKitContainer
        notificationObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSPersistentStoreRemoteChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.requiresRestart else { return }
            self.recordRemoteChange()
        }

        // Observe iCloud account changes (sign in/out)
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.requiresRestart else { return }
            self.checkAccountStatus()
        }
    }

    /// Stop all monitoring.
    public func stopMonitoring() {
        if let obs = notificationObserver {
            NotificationCenter.default.removeObserver(obs)
            notificationObserver = nil
        }
        if let obs = accountObserver {
            NotificationCenter.default.removeObserver(obs)
            accountObserver = nil
        }
    }

    /**
     Records that the active runtime received a remote-change notification.

     Tests call this directly to validate sync state transitions without constructing a CloudKit
     container; production reaches the same path from `NSPersistentStoreRemoteChangeNotification`.

     - Parameter date: Timestamp to store as the latest sync event.
     - Side effects:
       - updates `lastSyncDate`
       - returns non-error states to `.idle` after a remote change
     - Failure modes: none.
     */
    func recordRemoteChange(at date: Date = Date()) {
        lastSyncDate = date
        if case .error = state { return }
        state = .idle
    }

    // MARK: - Account Status

    /// Check the current iCloud account status.
    public func checkAccountStatus() {
        guard activeMode, !requiresRestart else { return }

        let container = CKContainer(identifier: "iCloud.org.andbible.ios")
        container.accountStatus { [weak self] status, error in
            DispatchQueue.main.async {
                guard let self, self.activeMode, !self.requiresRestart else { return }
                if let error {
                    self.state = .error(error.localizedDescription)
                    return
                }
                switch status {
                case .available:
                    self.state = .idle
                    self.fetchAccountDescription(container: container)
                case .noAccount:
                    self.state = .noAccount
                    self.accountDescription = nil
                case .restricted:
                    self.state = .error(String(localized: "icloud_restricted"))
                    self.accountDescription = nil
                case .couldNotDetermine:
                    self.state = .error(String(localized: "icloud_could_not_determine"))
                    self.accountDescription = nil
                case .temporarilyUnavailable:
                    self.state = .error(String(localized: "icloud_temporarily_unavailable"))
                    self.accountDescription = nil
                @unknown default:
                    self.state = .error("Unknown iCloud status")
                    self.accountDescription = nil
                }
            }
        }
    }

    /// Fetch the iCloud account user identity for display.
    private func fetchAccountDescription(container: CKContainer) {
        container.fetchUserRecordID { recordID, error in
            guard error == nil, recordID != nil else {
                DispatchQueue.main.async {
                    self.recordAccountDescription(String(localized: "icloud_signed_in"))
                }
                return
            }
            DispatchQueue.main.async {
                self.recordAccountDescription(String(localized: "icloud_signed_in"))
            }
        }
    }

    /**
     Records the user-visible iCloud account description for the active runtime.

     Tests call this directly to validate runtime rollback behavior without depending on CloudKit
     account APIs. Production reaches the same path after account identity lookup.

     - Parameter description: Display text for the current iCloud account, or `nil` when unavailable.
     - Side effects: Updates `accountDescription`.
     - Failure modes: none.
     */
    func recordAccountDescription(_ description: String?) {
        accountDescription = description
    }

    // MARK: - Toggle

    /**
     Toggles iCloud sync.

     When the host app has installed a mode-change handler, this applies the requested mode in the
     current session by rebuilding the SwiftData stack and restarting monitoring against the new
     container. Without a handler it preserves the legacy explicit restart-required fallback used
     by previews and non-app hosts.
     */
    @MainActor
    public func toggleSync() {
        let previousMode = isEnabled
        let requestedMode = !previousMode

        guard let modeChangeHandler else {
            isEnabled = requestedMode
            defaults.set(isEnabled, forKey: syncEnabledKey)
            requiresRestart = true
            state = .pendingRestart
            return
        }

        defaults.set(requestedMode, forKey: syncEnabledKey)
        requiresRestart = false
        state = .syncing

        do {
            let result = try modeChangeHandler(requestedMode)
            stopMonitoring()
            defaults.set(result.effectiveEnabled, forKey: syncEnabledKey)
            applyRuntimeMode(enabled: result.effectiveEnabled)
            if result.effectiveEnabled, let modelContainer = result.modelContainer {
                startMonitoring(container: modelContainer)
            }
        } catch {
            defaults.set(previousMode, forKey: syncEnabledKey)
            isEnabled = previousMode
            activeMode = previousMode
            requiresRestart = false
            state = .error(error.localizedDescription)
        }
    }

    /// Reset sync state (for troubleshooting).
    public func resetSync() {
        lastSyncDate = nil
        if activeMode && !requiresRestart {
            state = .idle
            checkAccountStatus()
        } else if requiresRestart {
            state = .pendingRestart
        } else {
            state = .disabled
        }
    }

    /**
     Applies an already-rebuilt runtime mode to the service state.

     - Parameter enabled: Effective CloudKit mode after container construction completed.
     - Side effects: Clears stale account and sync timestamps because they describe the previous
       container mode.
     - Failure modes: none.
     */
    private func applyRuntimeMode(enabled: Bool) {
        isEnabled = enabled
        activeMode = enabled
        requiresRestart = false
        accountDescription = nil
        lastSyncDate = nil
        state = enabled ? .idle : .disabled
    }
}
