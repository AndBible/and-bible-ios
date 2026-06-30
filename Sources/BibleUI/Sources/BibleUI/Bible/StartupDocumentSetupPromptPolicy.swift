import Foundation

/**
 Selects the startup document-setup prompt reason independently from SWORD module discovery.

 Android keeps its first-download screen visible until the user has at least one Bible, while iOS
 also ships a bundled fallback Bible. This policy keeps the no-Bible prompt as the highest-priority
 blocking state, then separately surfaces the one-time first-run setup path when a fallback Bible is
 already present.

 Failure modes:
 - malformed or missing persistence should be normalized by the caller before invoking this policy
 - unsupported locale decisions are intentionally outside this policy so UI actions can stay
   Android-parity English-only where default document bundles require English catalog data
 */
struct StartupDocumentSetupPromptPolicy {
    /// Reason the reader should present a startup document-setup prompt.
    enum PromptReason: Equatable {
        /// No installed Bible module is available, so reading setup is required.
        case noBibleModules

        /// A fallback Bible exists, but the user has not seen the recommended setup path.
        case firstRunSetup
    }

    /**
     Resolves which startup prompt, if any, should be presented.

     - Parameters:
       - hasNoBibleModules: Whether the installed module store currently lacks Bible modules.
       - hasHandledFirstRunSetup: Whether the user has already entered or skipped first-run setup.
     - Returns: `.noBibleModules` when reading cannot start from installed modules,
       `.firstRunSetup` for the one-time recommended setup prompt, or `nil` when no prompt is due.
     */
    static func promptReason(
        hasNoBibleModules: Bool,
        hasHandledFirstRunSetup: Bool
    ) -> PromptReason? {
        if hasNoBibleModules {
            return .noBibleModules
        }
        if !hasHandledFirstRunSetup {
            return .firstRunSetup
        }
        return nil
    }
}
