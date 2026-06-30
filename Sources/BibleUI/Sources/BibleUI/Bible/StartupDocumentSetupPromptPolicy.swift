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

/**
 Android startup setup presentation contract.

 Android's first-download page is a full setup screen, not a transient action sheet. This value
 keeps the startup action set explicit so the reader can render a route-backed surface while tests
 assert behavior instead of SwiftUI implementation details.

 Failure modes:
 - unsupported locales simply omit Easy Start because Android exposes it for English only
 - first-run setup may be skipped because iOS can already show a bundled fallback Bible
 - no-Bible setup intentionally cannot be skipped because Android blocks on first-download setup
 */
struct StartupDocumentSetupPresentation: Equatable {
    /// Android first-download action exposed by the startup setup surface.
    enum Action: Equatable {
        /// English-only default document download flow.
        case easyStart

        /// Open the document download screen.
        case downloadDocuments

        /// Open document loading from local files.
        case loadDocumentsFromFiles

        /// Open database restore.
        case restoreDatabase

        /// Skip the non-blocking first-run setup prompt.
        case skip
    }

    /// Reason the setup screen is being shown.
    let reason: StartupDocumentSetupPromptPolicy.PromptReason

    /// Whether Android's English-only Easy Start row should be present.
    let isEasyStartAvailable: Bool

    /// The startup surface is reader-stack backed to match Android's full setup page.
    var usesReaderStackSurface: Bool {
        true
    }

    /// Skip is allowed only for iOS's non-blocking first-run setup path.
    var allowsSkip: Bool {
        reason == .firstRunSetup
    }

    /// Ordered actions matching Android's first-download layout with iOS's skip extension last.
    var actions: [Action] {
        var startupActions: [Action] = []
        if isEasyStartAvailable {
            startupActions.append(.easyStart)
        }
        startupActions.append(.downloadDocuments)
        startupActions.append(.restoreDatabase)
        startupActions.append(.loadDocumentsFromFiles)
        if allowsSkip {
            startupActions.append(.skip)
        }
        return startupActions
    }
}
