// AIReaderWindowDocumentRouter.swift -- Verified live-pane routing for AI document tools

import BibleCore
import Foundation

/**
 Routes Android's set-window-document tool through the owning live reader controller.

 A successful result is built from state observed after the controller mutation. Missing panes,
 unknown documents, invalid exact keys, and failed module preflights throw instead of allowing the
 agent to report a navigation that the UI did not perform.
 */
@MainActor
final class AIReaderWindowDocumentRouter: BibleUIAgentWindowDocumentRouting {
    private weak var windowManager: WindowManager?
    private let myDocumentStore: MyDocumentStore

    /** Creates a router over the shared window registry and exact My Documents store. */
    init(windowManager: WindowManager, myDocumentStore: MyDocumentStore) {
        self.windowManager = windowManager
        self.myDocumentStore = myDocumentStore
    }

    /**
     Switches one exact live pane to an installed document and optional exact key.

     - Parameters:
       - windowID: Existing window identity owned by the active workspace.
       - documentInitials: Installed SWORD, SQLite, or My Documents initials.
       - key: Optional OSIS reference or exact generic page key.
     - Returns: Document and key state read back from the target controller.
     - Side effects: Mutates and persists the target pane, then emits its replacement content.
     - Failure modes: Throws a stable domain error for a missing pane, unknown document, failed
       module switch, or key that the selected document cannot render exactly.
     */
    func setDocument(
        windowID: UUID,
        documentInitials: String,
        key: String?
    ) async throws -> BibleUIAgentWindowDocumentState {
        let initials = documentInitials.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !initials.isEmpty,
              let controller = windowManager?.controllers[windowID] as? BibleReaderController else {
            throw failure("WINDOW_NOT_FOUND", "The requested reader window is not available.")
        }

        if controller.installedModules(for: .bible).contains(where: { $0.name == initials }) {
            controller.switchBibleDocument(to: initials)
            if let normalizedKey, !normalizedKey.isEmpty,
               !controller.navigateToRef(normalizedKey) {
                throw failure("KEY_NOT_FOUND", "The requested Bible reference is not available.")
            }
        } else if controller.installedModules(for: .commentary).contains(where: { $0.name == initials }) {
            if let normalizedKey, !normalizedKey.isEmpty,
               !controller.navigateToRef(normalizedKey) {
                throw failure("KEY_NOT_FOUND", "The requested commentary reference is not available.")
            }
            controller.switchCommentaryDocument(to: initials)
        } else if controller.installedModules(for: .dictionary).contains(where: { $0.name == initials }) {
            try requireSuccessfulSwitch(controller.switchDictionaryDocument(to: initials))
            if let normalizedKey, !normalizedKey.isEmpty {
                guard try controller.activeDictionaryKeys().contains(normalizedKey) else {
                    throw failure("KEY_NOT_FOUND", "The requested dictionary key is not available.")
                }
                controller.loadDictionaryEntry(key: normalizedKey)
            }
        } else if controller.installedModules(for: .generalBook).contains(where: { $0.name == initials }) {
            try requireSuccessfulSwitch(controller.switchGeneralBookDocument(to: initials))
            if let normalizedKey, !normalizedKey.isEmpty {
                controller.loadGeneralBookEntry(key: normalizedKey)
                guard controller.currentGeneralBookKey == normalizedKey else {
                    throw failure("KEY_NOT_FOUND", "The requested document key is not available.")
                }
            }
        } else if controller.installedModules(for: .map).contains(where: { $0.name == initials }) {
            try requireSuccessfulSwitch(controller.switchMapDocument(to: initials))
            if let normalizedKey, !normalizedKey.isEmpty {
                controller.loadMapEntry(key: normalizedKey)
                guard controller.currentMapKey == normalizedKey else {
                    throw failure("KEY_NOT_FOUND", "The requested map key is not available.")
                }
            }
        } else if let document = myDocumentStore.document(initials: initials) {
            let pageKey = normalizedKey.flatMap { $0.isEmpty ? nil : $0 }
                ?? (document.pages ?? []).sorted(by: Self.pageOrder).first?.pageKey
            guard let pageKey,
                  myDocumentStore.page(bookInitials: initials, pageKey: pageKey) != nil,
                  controller.loadMyDocumentPage(bookInitials: initials, pageKey: pageKey) else {
                throw failure("KEY_NOT_FOUND", "The requested My Documents page is not available.")
            }
        } else {
            throw failure("BOOK_NOT_FOUND", "The requested document is not installed.")
        }

        let observedInitials = controller.activeModuleName(for: controller.currentCategory)
        guard let observedInitials, observedInitials == initials else {
            throw failure("NAVIGATION_FAILED", "The requested document could not be opened.")
        }
        let observedKey = currentKey(controller)
        if let normalizedKey, !normalizedKey.isEmpty,
           controller.currentCategory != .bible,
           controller.currentCategory != .commentary,
           observedKey != normalizedKey {
            throw failure("NAVIGATION_FAILED", "The requested document key could not be opened.")
        }
        let name = controller.installedModules(for: controller.currentCategory)
            .first(where: { $0.name == initials })?.description
            ?? myDocumentStore.document(initials: initials)?.name
            ?? initials
        return BibleUIAgentWindowDocumentState(
            windowID: windowID,
            documentInitials: observedInitials,
            documentName: name,
            currentKey: observedKey,
            currentKeyName: observedKey
        )
    }

    /** Converts retryable generic preflight outcomes into the tool's fail-closed contract. */
    private func requireSuccessfulSwitch(_ outcome: BibleReaderGenericModuleSwitchOutcome) throws {
        if case .failed = outcome {
            throw failure("NAVIGATION_FAILED", "The requested document could not be opened.")
        }
    }

    /** Returns the key domain owned by the controller's observed category. */
    private func currentKey(_ controller: BibleReaderController) -> String? {
        switch controller.currentCategory {
        case .bible, .commentary:
            let osisID = controller.osisBookId(for: controller.currentBook)
            guard !osisID.isEmpty else { return nil }
            return "\(osisID).\(controller.currentChapter).\(controller.currentVerse)"
        case .dictionary:
            return controller.currentDictionaryKey
        case .generalBook:
            return controller.currentGeneralBookKey
        case .map:
            return controller.currentMapKey
        case .epub:
            return controller.currentEpubHref
        case .dailyDevotion:
            return nil
        }
    }

    /** Orders My Documents pages exactly as their reader chooser does. */
    private static func pageOrder(_ lhs: MyDocumentPage, _ rhs: MyDocumentPage) -> Bool {
        if lhs.orderNumber != rhs.orderNumber { return lhs.orderNumber < rhs.orderNumber }
        return lhs.pageKey < rhs.pageKey
    }

    /** Builds one credential-free model-facing navigation failure. */
    private func failure(_ code: String, _ message: String) -> BibleUIAgentDomainError {
        BibleUIAgentDomainError(code: code, message: message)
    }
}
