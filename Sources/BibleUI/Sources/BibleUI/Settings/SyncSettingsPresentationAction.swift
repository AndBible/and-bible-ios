// SyncSettingsPresentationAction.swift -- app-owned Sync Settings presentation hook

import SwiftUI

/**
 Opens the production Sync Settings surface from reader-owned actions.

 The default action is intentionally unhandled so package previews and non-app hosts continue to
 use the reader-owned fallback presentation. The production app installs a handler above the
 SwiftData runtime boundary so live iCloud mode changes can prepare or apply the data-stack update
 without dismissing the open Sync Settings surface.
 */
public struct SyncSettingsPresentationAction {
    /// Optional handler installed by the app shell.
    private let handler: (() -> Void)?

    /**
     Creates a Sync Settings presentation action.

     - Parameter handler: Optional app-shell handler that presents Sync Settings.
     */
    public init(_ handler: (() -> Void)? = nil) {
        self.handler = handler
    }

    /**
     Runs the app-shell presentation handler when one is installed.

     - Returns: `true` when a handler presented Sync Settings; `false` when callers should fall
       back to their local presentation.
     */
    @discardableResult
    public func callAsFunction() -> Bool {
        guard let handler else {
            return false
        }
        handler()
        return true
    }
}

private struct SyncSettingsPresentationActionKey: EnvironmentKey {
    static let defaultValue = SyncSettingsPresentationAction()
}

public extension EnvironmentValues {
    /// App-owned Sync Settings presenter used by reader drawer actions.
    var presentSyncSettings: SyncSettingsPresentationAction {
        get { self[SyncSettingsPresentationActionKey.self] }
        set { self[SyncSettingsPresentationActionKey.self] = newValue }
    }
}
