// ModuleDownloadRowActionPlanner.swift - Android Downloads row action parity

import Foundation

/**
 Secondary actions exposed from one Downloads module row.

 The cases mirror Android's download/document context actions: about, delete, delete index, and
 unlock. iOS names the destructive module removal action `uninstall` in the UI, but it represents
 Android's `delete` action for an installed SWORD document.

 Side effects:
 - none; this enum only describes available UI actions

 Failure modes:
 - none
 */
public enum ModuleDownloadRowAction: Sendable, Equatable {
    /// Show Android-style module/about metadata for the row.
    case about

    /// Remove the installed module from local SWORD storage.
    case uninstall

    /// Remove the local full-text search index for the installed module.
    case deleteIndex

    /// Prompt for a cipher key for an encrypted installed module.
    case unlock
}

/**
 Computes Android-compatible secondary actions for a Downloads row.

 Android exposes an inline About button for rows that are not actively installing and shows
 management actions from the contextual document menu when the row is already installed. iOS keeps
 that decision isolated from SwiftUI so row rendering, context menus, and tests share the same
 parity rule.

 Inputs:
 - the matching installed module snapshot, when present
 - whether this row is currently in Android's `BEING_INSTALLED` state
 - the complete installed inventory, when available, so the last Bible cannot expose delete

 Outputs:
 - ordered actions to show in iOS row affordances

 Side effects:
 - none; this is a deterministic value mapper

 Failure modes:
 - none; every production consumer is wired to the shared manager-backed unlock coordinator
 */
public struct ModuleDownloadRowActionPlanner: Sendable {
    /**
     Returns the ordered row actions for one Downloads row.

     - Parameters:
       - installedModule: Installed module with the same initials, or `nil` when the module is not
         installed locally.
       - isBeingInstalled: Whether the row is in the active install/update state.
       - installedModules: Complete installed inventory. Pass `nil` only from compatibility callers
         that cannot yet provide inventory; service-level uninstall remains authoritative.
     - Returns: Android-ordered row actions available for the supplied state.
     - Side effects: none.
     - Failure modes: none.
     */
    public static func availableActions(
        installedModule: ModuleInfo?,
        isBeingInstalled: Bool,
        installedModules: [ModuleInfo]? = nil
    ) -> [ModuleDownloadRowAction] {
        var actions: [ModuleDownloadRowAction] = []

        if !isBeingInstalled {
            actions.append(.about)
        }

        guard let installedModule else {
            return actions
        }

        let canUninstall = installedModule.category != .bible
            || (installedModules.map { inventory in
                inventory.lazy.filter { $0.category == .bible }.count > 1
            } ?? true)
        if canUninstall {
            actions.append(.uninstall)
        }
        actions.append(.deleteIndex)

        if installedModule.isEncrypted {
            actions.append(.unlock)
        }

        return actions
    }
}
