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
    /// User toggled sync but app hasn't restarted yet to apply the change.
    case pendingRestart
}

/// Manages iCloud/CloudKit sync status monitoring.
///
/// SwiftData handles actual data sync automatically when configured with
/// `cloudKitDatabase: .private(...)`. This service monitors account status,
/// observes remote change notifications, and exposes state to the UI.
///
/// ## Conflict Resolution
/// SwiftData's CloudKit integration uses NSPersistentCloudKitContainer under
/// the hood, which applies **last-writer-wins** conflict resolution automatically.
/// When the same record is modified on two devices, the most recent write wins
/// after CloudKit reconciles. No explicit merge policy code is needed.
@Observable
public final class SyncService {
    /// Current sync state.
    public private(set) var state: SyncState = .disabled

    /// Last time a remote change notification was received.
    public private(set) var lastSyncDate: Date?

    /// Whether iCloud sync is enabled (persisted in UserDefaults).
    /// This reflects the *persisted* preference. The actual CloudKit mode
    /// is determined at app startup and cannot change mid-session.
    public private(set) var isEnabled: Bool = false

    /// Whether a restart is required to apply sync changes.
    public private(set) var requiresRestart: Bool = false

    /// The iCloud account display name, if available.
    public private(set) var accountDescription: String?

    /// The sync mode that is actually active for this session
    /// (set at startup, does not change until restart).
    private var activeMode: Bool = false

    private var notificationObserver: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?

    /// Creates an idle sync monitor. Call `setInitialState(enabled:)` during app startup before `startMonitoring(container:)`.
    public init() {}

    deinit {
        stopMonitoring()
    }

    /// Set the enabled state without triggering side effects.
    /// Called during app init before monitoring starts.
    public func setInitialState(enabled: Bool) {
        isEnabled = enabled
        activeMode = enabled
        state = enabled ? .idle : .disabled
    }

    // MARK: - Monitoring

    /// Start monitoring iCloud account status and remote change notifications.
    /// Call after ModelContainer is created.
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
            self.lastSyncDate = Date()
            if case .error = self.state { return }
            self.state = .idle
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
                    self.accountDescription = String(localized: "icloud_signed_in")
                }
                return
            }
            DispatchQueue.main.async {
                self.accountDescription = String(localized: "icloud_signed_in")
            }
        }
    }

    // MARK: - Toggle

    /// Toggle sync on/off. Sets `requiresRestart` and moves to `.pendingRestart`
    /// state because the ModelContainer must be reconstructed.
    public func toggleSync() {
        isEnabled.toggle()
        UserDefaults.standard.set(isEnabled, forKey: "icloud_sync_enabled")
        requiresRestart = true
        state = .pendingRestart
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
}
