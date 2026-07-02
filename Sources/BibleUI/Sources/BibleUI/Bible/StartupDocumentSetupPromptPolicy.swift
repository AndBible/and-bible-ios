import Foundation

/**
 Selects the startup document-setup prompt reason independently from SWORD module discovery.

 Android keeps its first-download screen visible only while the installed module store has no
 Bibles. iOS follows the same predicate directly so app upgrades do not show Easy Start again when
 users already have Bible modules installed.

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
    }

    /// Startup prompt decision plus whether installed-module inventory was resolved.
    struct Evaluation: Equatable {
        /// Prompt reason to present after inventory resolves, or `nil` when setup is not due.
        let promptReason: PromptReason?

        /// Whether the caller supplied a resolved installed-module inventory snapshot.
        let didEvaluateInventory: Bool
    }

    /**
     Resolves startup prompt state while preserving unresolved inventory as pending.

     Android's first-download gate is based on a resolved `SwordDocumentFacade.bibles` snapshot.
     iOS keeps the same contract: temporary reader-controller or SWORD-manager unavailability
     should not mark startup evaluation complete because a later controller registration can
     provide the installed-module inventory.

     - Parameter hasNoBibleModules: `true` when resolved inventory contains no Bible modules,
       `false` when it contains at least one Bible, or `nil` while inventory is unavailable.
     - Returns: Prompt decision plus whether inventory was resolved.
     */
    static func evaluation(hasNoBibleModules: Bool?) -> Evaluation {
        guard let hasNoBibleModules else {
            return Evaluation(promptReason: nil, didEvaluateInventory: false)
        }
        return Evaluation(
            promptReason: promptReason(hasNoBibleModules: hasNoBibleModules),
            didEvaluateInventory: true
        )
    }

    /**
     Resolves which startup prompt, if any, should be presented.

     - Parameter hasNoBibleModules: Whether the installed module store currently lacks Bible
       modules.
     - Returns: `.noBibleModules` when reading cannot start from installed Bible modules, or `nil`
       when no startup setup is due.
     */
    static func promptReason(hasNoBibleModules: Bool) -> PromptReason? {
        hasNoBibleModules ? .noBibleModules : nil
    }
}

/**
 Android startup setup presentation contract.

 Android's first-download page is a full setup screen, not a transient action sheet. This value
 keeps the startup action set explicit so the reader can render a route-backed surface while tests
 assert behavior instead of SwiftUI implementation details.

 Failure modes:
 - unsupported locales simply omit Easy Start because Android exposes it for English only
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

        /// Startup-specific BackupActivity category target, when the action opens a file picker.
        var restoreImportTarget: RestoreWorkflowTarget? {
            switch self {
            case .restoreDatabase:
                return .database
            case .loadDocumentsFromFiles:
                return .documents
            case .easyStart, .downloadDocuments:
                return nil
            }
        }
    }

    /// Reason the setup screen is being shown.
    let reason: StartupDocumentSetupPromptPolicy.PromptReason

    /// Whether Android's English-only Easy Start row should be present.
    let isEasyStartAvailable: Bool

    /// The startup surface is reader-stack backed to match Android's full setup page.
    var usesReaderStackSurface: Bool {
        true
    }

    /// Startup setup is blocking until a Bible is installed, matching Android first-download.
    var allowsSkip: Bool {
        false
    }

    /// Ordered actions matching Android's first-download layout.
    var actions: [Action] {
        var startupActions: [Action] = []
        if isEasyStartAvailable {
            startupActions.append(.easyStart)
        }
        startupActions.append(.downloadDocuments)
        startupActions.append(.restoreDatabase)
        startupActions.append(.loadDocumentsFromFiles)
        return startupActions
    }
}
