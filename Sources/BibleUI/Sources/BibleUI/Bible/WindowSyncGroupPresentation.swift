// WindowSyncGroupPresentation.swift -- Stored-to-display sync-group mapping

import Foundation

/**
 Formats Android's zero-based persisted synchronization groups for one-based presentation.

 Storage and manager actions continue to use `0...5`; only user-facing titles map those values to
 `Group 1...6`, matching `SplitBibleArea.kt`'s `i + 1` formatting contract.
 */
enum WindowSyncGroupPresentation {
    /// Complete stored group range accepted by `WindowManager.changeSyncGroup`.
    static let storedGroups = 0..<6

    /**
     Returns a localized one-based title for a stored synchronization group.

     - Parameter group: Zero-based persisted group in `storedGroups`.
     - Returns: Localized display title such as `Group 1` or `Group 6`.
     - Side Effects: Reads the process localization bundle.
     - Failure Modes: Values outside the supported range are still formatted arithmetically; callers
       constrain input with `storedGroups`.
     */
    static func title(forStoredGroup group: Int) -> String {
        String(
            format: String(localized: "sync_group_n", defaultValue: "Group %d"),
            group + 1
        )
    }
}
