// AIReaderWindowDocumentRouter.swift -- Verified live-pane routing for AI document tools

import BibleCore
import Foundation
import SwordKit

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
     Switches one exact live pane to the globally owned installed or local document.

     - Parameters:
       - windowID: Existing window identity owned by the active workspace.
       - documentInitials: Installed/local initials or full-name token at any JSword exact/case tier.
       - key: Optional OSIS reference or exact generic page key.
     - Returns: Document and key state read back from the target controller.
     - Side effects: Preflights source authorization and the optional exact key/reference before
       mutating; success then persists the target pane and emits its replacement content.
     - Failure modes: Throws a stable domain error for a missing pane, unknown local
       document, failed module switch, or key the selected document cannot render exactly. Locked
       installed owners never fall through to colliding My Documents or EPUB content.
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

        let installedInfo = controller.registeredInstalledModuleInfo(named: initials)
        var resolvedInitials = installedInfo?.name ?? initials
        var resolvedName = installedInfo?.description ?? initials
        var expectedEpubKey: String?

        if let installedInfo {
            let preflight = controller.preflightInstalledWindowDocument(
                named: resolvedInitials,
                category: installedInfo.category,
                key: normalizedKey.flatMap { $0.isEmpty ? nil : $0 }
            )
            let authorizedKey: String?
            switch preflight {
            case .authorized(let key):
                authorizedKey = key
            case .sourceUnavailable:
                throw failure("NAVIGATION_FAILED", "The requested document could not be opened.")
            case .keyUnavailable:
                throw failure("KEY_NOT_FOUND", "The requested document key is not available.")
            }
            switch installedInfo.category {
        case .bible:
            guard controller.switchBibleDocument(to: resolvedInitials) == .switched else {
                throw failure("NAVIGATION_FAILED", "The requested document could not be opened.")
            }
            if let authorizedKey, !controller.navigateToRef(authorizedKey) {
                throw failure("KEY_NOT_FOUND", "The requested Bible reference is not available.")
            }

        case .commentary:
            try requireSuccessfulSwitch(controller.switchCommentaryDocument(to: resolvedInitials))
            if let authorizedKey, !controller.navigateToRef(authorizedKey) {
                throw failure("KEY_NOT_FOUND", "The requested commentary reference is not available.")
            }

        case .dictionary, .glossary:
            try requireSuccessfulSwitch(controller.switchDictionaryDocument(to: resolvedInitials))
            if let authorizedKey {
                controller.loadDictionaryEntry(key: authorizedKey)
            }

        case .generalBook:
            try requireSuccessfulSwitch(controller.switchGeneralBookDocument(to: resolvedInitials))
            if let authorizedKey {
                controller.loadGeneralBookEntry(key: authorizedKey)
                guard controller.currentGeneralBookKey.map({
                    SwordJavaStringIdentity.equals($0, authorizedKey)
                }) == true else {
                    throw failure("KEY_NOT_FOUND", "The requested document key is not available.")
                }
            }

        case .map:
            try requireSuccessfulSwitch(controller.switchMapDocument(to: resolvedInitials))
            if let authorizedKey {
                controller.loadMapEntry(key: authorizedKey)
                guard controller.currentMapKey.map({
                    SwordJavaStringIdentity.equals($0, authorizedKey)
                }) == true else {
                    throw failure("KEY_NOT_FOUND", "The requested map key is not available.")
                }
            }

        case .dailyDevotion, .questionable, .essays, .images, .addon, .unknown:
            throw failure("NAVIGATION_FAILED", "The requested document could not be opened.")
            }
        } else if let localDocument = controller.localGeneralBookDocument(named: initials) {
            switch localDocument {
        case .myDocument(let document):
            resolvedInitials = document.initials
            let pageKey = normalizedKey.flatMap { $0.isEmpty ? nil : $0 }
                ?? (document.pages ?? []).sorted(by: Self.pageOrder).first?.pageKey
            guard let pageKey,
                  myDocumentStore.page(bookInitials: resolvedInitials, pageKey: pageKey) != nil,
                  controller.loadMyDocumentPage(
                      bookInitials: resolvedInitials,
                      pageKey: pageKey
                  ) else {
                throw failure("KEY_NOT_FOUND", "The requested My Documents page is not available.")
            }

            resolvedName = SwordJavaStringIdentity.trim(document.name)

        case .epub(let reader):
            resolvedInitials = reader.initials
            if let normalizedKey, !normalizedKey.isEmpty {
                guard controller.registeredInstalledModuleInfo(named: resolvedInitials) == nil,
                      let content = reader.content(forKey: normalizedKey) else {
                    throw failure("KEY_NOT_FOUND", "The requested EPUB key is not available.")
                }
                expectedEpubKey = content.persistedKey
            }
            controller.switchEpub(identifier: reader.identifier)
            guard controller.activeModuleName(for: .generalBook).map({
                SwordJavaStringIdentity.equals($0, resolvedInitials)
            }) == true else {
                throw failure("NAVIGATION_FAILED", "The requested document could not be opened.")
            }
            if let normalizedKey, !normalizedKey.isEmpty {
                controller.loadEpubEntry(key: normalizedKey)
                guard let expectedEpubKey,
                      controller.currentGeneralBookKey.map({
                          SwordJavaStringIdentity.equals($0, expectedEpubKey)
                      }) == true else {
                    throw failure("KEY_NOT_FOUND", "The requested EPUB key is not available.")
                }
            }
            resolvedName = SwordJavaStringIdentity.trim(reader.title)
            }
        } else {
            throw failure("BOOK_NOT_FOUND", "The requested document is not installed.")
        }

        let observedInitials = controller.activeModuleName(for: controller.currentCategory)
        guard let observedInitials,
              SwordJavaStringIdentity.equals(observedInitials, resolvedInitials) else {
            throw failure("NAVIGATION_FAILED", "The requested document could not be opened.")
        }
        let observedKey = currentKey(controller)
        if let normalizedKey, !normalizedKey.isEmpty,
           controller.currentCategory != .bible,
           controller.currentCategory != .commentary,
           controller.activeEpubReader == nil,
           observedKey.map({ SwordJavaStringIdentity.equals($0, normalizedKey) }) != true {
            throw failure("NAVIGATION_FAILED", "The requested document key could not be opened.")
        }
        return BibleUIAgentWindowDocumentState(
            windowID: windowID,
            documentInitials: observedInitials,
            documentName: resolvedName,
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

    /**
     Converts a commentary activation result into the AI tool's fail-closed navigation contract.

     - Parameter outcome: Typed result returned after the controller's fresh access/category preflight.
     - Side effects: None.
     - Throws: `NAVIGATION_FAILED` when the target was locked, missing, unavailable, or invalid; the
       caller performs no key navigation after this failure.
     */
    private func requireSuccessfulSwitch(
        _ outcome: BibleReaderCommentaryModuleSwitchOutcome
    ) throws {
        guard outcome == .switched else {
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
