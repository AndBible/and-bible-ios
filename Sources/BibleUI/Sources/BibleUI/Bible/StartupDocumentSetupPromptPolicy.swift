import Foundation
import SwordKit

/**
 Selects the startup document-setup prompt reason independently from SWORD module discovery.

 Android attempts its app-owned unlock queue before entering the reader when every installed Bible
 is locked, and returns to the first-download surface if none becomes readable. iOS consumes the
 locked-only reason by running the same full startup queue before setup. If every queued credential
 is declined or rejected, the reason remains available to Android's blocking first-download surface
 with the same download, restore, and local-import recovery actions.

 - Failure modes:
   - malformed or missing persistence should be normalized by the caller before invoking this policy
   - unsupported locale decisions are intentionally outside this policy so UI actions can stay
     Android-parity English-only where default document bundles require English catalog data
 */
struct StartupDocumentSetupPromptPolicy {
    /// Reason the reader should present a startup document-setup prompt.
    enum PromptReason: Equatable {
        /// No installed Bible module is available, so document installation is required.
        case noBibleModules

        /// Bible modules are installed but every current manager snapshot still requires unlock.
        case lockedBibleModules
    }

    /// Startup prompt decision plus whether installed-module inventory was resolved.
    struct Evaluation: Equatable {
        /// Prompt reason to present after inventory resolves, or `nil` when setup is not due.
        let promptReason: PromptReason?

        /// Whether the caller supplied a resolved installed-module inventory snapshot.
        let didEvaluateInventory: Bool
    }

    /**
     Tests whether an installed inventory can supply a readable Bible without user interaction.

     The input is expected to combine a fresh native access snapshot with validated, unshadowed
     Android SQLite books. Native session unlock state must be current. Locked modules remain in
     that inclusive inventory for the full chooser and Downloads, but they do not satisfy reader
     startup.

     - Parameter modules: Fresh cross-backend installed metadata, including locked native rows.
     - Returns: `true` when no unencrypted or currently unlocked Bible exists.
     - Side effects: None.
     - Failure modes: Empty, non-Bible, and locked-only inventories return `true` so startup fails
       closed onto the existing setup route.
     */
    static func hasNoReadableBibleModules(in modules: [ModuleInfo]) -> Bool {
        promptReason(in: modules) != nil
    }

    /**
     Classifies one fresh inclusive inventory without collapsing locked-only into no-Bible setup.

     - Parameter modules: Fresh cross-backend metadata, including encrypted locked native rows.
     - Returns: `.noBibleModules` when no Bible is installed, `.lockedBibleModules` when installed
       Bibles all require a passphrase, or `nil` when at least one Bible is currently readable.
     - Side effects: None.
     - Failure modes: Empty and non-Bible inventories fail closed as `.noBibleModules`; mixed
       inventories remain readable as soon as one Bible is unencrypted or currently unlocked.
     */
    static func promptReason(in modules: [ModuleInfo]) -> PromptReason? {
        let bibleModules = modules.filter { $0.category == .bible }
        guard !bibleModules.isEmpty else {
            return .noBibleModules
        }
        guard !bibleModules.contains(where: { !$0.isEncrypted || $0.isUnlocked }) else {
            return nil
        }
        return .lockedBibleModules
    }

    /**
     Resolves startup prompt state from one optional fresh inclusive inventory snapshot.

     This is also the post-queue reconciliation contract. After every initially locked row is
     processed, one new manager snapshot decides whether a newly readable Bible enters the reader or
     locked-only/empty inventory returns to the matching blocking setup reason.

     - Parameter modules: Fresh cross-backend installed modules, or `nil` while inventory cannot
       be resolved.
     - Returns: Prompt decision plus whether inventory was resolved.
     - Side effects: None.
     - Failure modes: Unresolved inventory remains pending instead of dismissing blocking setup.
     */
    static func evaluation(modules: [ModuleInfo]?) -> Evaluation {
        guard let modules else {
            return Evaluation(promptReason: nil, didEvaluateInventory: false)
        }
        return Evaluation(
            promptReason: promptReason(in: modules),
            didEvaluateInventory: true
        )
    }

    /**
     Resolves startup prompt state while preserving unresolved inventory as pending.

     This legacy Boolean entry point remains source-compatible for callers that cannot distinguish
     empty from locked-only inventory. New startup and post-queue callers must use
     `evaluation(modules:)` so locked-only inventory can start the automatic credential queue.

     - Parameter hasNoBibleModules: `true` when resolved inventory contains no readable Bible,
       `false` when it contains at least one readable Bible, or `nil` while inventory is unavailable.
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

     - Parameter hasNoBibleModules: Whether the installed module store currently lacks a readable
       Bible. The historical parameter name remains source-compatible with existing app callers.
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

 - Side effects: None; the value only projects resolved startup state into ordered actions.
 - Failure modes:
   - unsupported locales simply omit Easy Start because Android exposes it for English only
   - both no-Bible and locked-only setup intentionally remain blocking until a Bible is readable
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

    /// Startup setup is blocking until an installed Bible is readable, matching Android startup.
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
