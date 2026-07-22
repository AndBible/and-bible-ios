// ModuleUnlockActionCoordinator.swift -- Shared encrypted-module unlock behavior

import Foundation
import SwordKit

/**
 Coordinates the synchronous encrypted-module unlock contract shared by Downloads and the reader
 document picker.

 Both Android surfaces submit the selected module initials and passphrase to the installed-book
 manager, then refresh their local document snapshot only after the key is accepted. Keeping that
 behavior here prevents one surface from persisting or reporting keys differently from the other.

 Side effects:
 - invokes the supplied unlock closure exactly once per non-empty submission
 - invokes the accepted callback exactly once after a successful unlock

 Failure modes:
 - an empty key returns `false` without invoking the manager or accepted callback
 - a manager-rejected key returns `false` without invoking the accepted callback
 - manager-specific validation and persistence failures are represented by the unlock closure's
   `false` result
 */
enum ModuleUnlockActionCoordinator {
    /// Delay used to dismiss and re-present SwiftUI's passphrase alert after a rejected key.
    static let retryPresentationDelay: TimeInterval = 0.2

    /**
     Submits one passphrase through the manager-backed unlock operation.

     - Parameters:
       - module: Installed encrypted module selected by the user.
       - cipherKey: Passphrase entered in the shared unlock prompt.
       - unlockModule: Manager adapter that validates and persists the passphrase for module initials.
       - onAccepted: Surface-specific success work, such as clearing prompt state, refreshing module
         inventory, and selecting the newly unlocked reader document.
     - Returns: `true` only when the manager accepts the passphrase.
     - Side effects: For a non-empty key, calls `unlockModule` once and calls `onAccepted` once on
       success.
     - Failure modes: An empty key returns `false` before `unlockModule` is called. Manager rejection
       returns `false`; no success work runs and callers retain responsibility for retry feedback.
     */
    @discardableResult
    static func submit(
        module: ModuleInfo,
        cipherKey: String,
        unlockModule: (String, String) -> Bool,
        onAccepted: () -> Void
    ) -> Bool {
        guard !cipherKey.isEmpty else {
            return false
        }
        guard unlockModule(module.name, cipherKey) else {
            return false
        }
        onAccepted()
        return true
    }

    /**
     Builds Android's module-scoped passphrase prompt title.

     - Parameter module: Locked installed module being unlocked.
     - Returns: Localized title containing the module initials.
     - Side effects: Reads localization resources.
     - Failure modes: Missing localization uses the supplied English format string.
     */
    static func promptTitle(for module: ModuleInfo) -> String {
        String(
            format: String(
                localized: "give_passphrase_for_module",
                defaultValue: "Document %@ is encrypted and needs passphrase to be unlocked"
            ),
            module.name
        )
    }

    /**
     Returns Android-compatible retry feedback for a rejected module passphrase.

     - Returns: Localized invalid-passphrase message.
     - Side effects: Reads localization resources.
     - Failure modes: Missing localization uses the supplied English retry message.
     */
    static var failureMessage: String {
        String(
            localized: "module_unlock_failed",
            defaultValue: "The passphrase was not accepted. Try again."
        )
    }
}
