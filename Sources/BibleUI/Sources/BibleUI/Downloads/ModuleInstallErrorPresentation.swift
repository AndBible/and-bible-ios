// ModuleInstallErrorPresentation.swift -- localized module-install failure boundary

import Foundation
import SwordKit

/**
 Converts repository errors into localized text before they enter Downloads or import state.

 Repository errors retain technical English descriptions for logs and non-UI clients. This adapter
 owns the application-bundle localization boundary so insufficient-storage and generic install
 failures never bypass shipped locale resources.
 */
enum ModuleInstallErrorPresentation {
    /**
     Resolves the localized detail for one repository or filesystem error.

     - Parameter error: Error produced before or during module installation.
     - Returns: Android's localized storage warning for capacity failures; otherwise the original
       technical detail for inclusion in a localized failure sentence.
     - Side effects: Reads application localization resources.
     - Failure modes: Missing resources use the supplied English fallback.
     */
    static func detail(for error: Error) -> String {
        if case ModuleRepositoryError.insufficientStorage = error {
            return String(
                localized: "storage_space_warning",
                defaultValue: "Insufficient local storage space."
            )
        }
        return error.localizedDescription
    }

    /**
     Formats technical install detail with Android's localized failure contract.

     - Parameter detail: Module, transport, archive, or filesystem failure detail.
     - Returns: Localized install-failure sentence containing `detail`.
     - Side effects: Reads application localization resources.
     - Failure modes: Missing resources use the supplied English fallback.
     */
    static func failureMessage(detail: String) -> String {
        String(
            format: String(
                localized: "install_failed_reason",
                defaultValue: "Installing module failed for the following reason: %@."
            ),
            detail
        )
    }
}
