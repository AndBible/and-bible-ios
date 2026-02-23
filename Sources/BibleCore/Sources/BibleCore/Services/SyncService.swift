// SyncService.swift — iCloud/CloudKit sync

import Foundation
import Observation

/// Sync state for the service.
public enum SyncState: Sendable {
    case idle
    case syncing
    case error(String)
    case complete
}

/// Manages synchronization of app data via iCloud/CloudKit.
///
/// Phase 7 implementation — this is a stub for the sync infrastructure.
@Observable
public final class SyncService {
    /// Current sync state.
    public private(set) var state: SyncState = .idle

    /// Last successful sync timestamp.
    public private(set) var lastSyncDate: Date?

    /// Whether iCloud sync is enabled.
    public var isEnabled: Bool = false

    public init() {}

    /// Trigger a manual sync.
    public func sync() async {
        guard isEnabled else { return }
        state = .syncing

        // CloudKit sync implementation will go here in Phase 7.
        // Key steps:
        // 1. Query CKDatabase for changes since lastSyncDate
        // 2. Resolve conflicts (last-writer-wins or merge)
        // 3. Push local changes to CKDatabase
        // 4. Update lastSyncDate

        state = .complete
        lastSyncDate = Date()
    }

    /// Reset sync state (for troubleshooting).
    public func resetSync() {
        lastSyncDate = nil
        state = .idle
    }
}
