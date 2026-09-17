// AIReaderWindowDocumentRouter.swift -- Verified live-pane routing for AI document tools

import BibleCore
import Foundation
import SwordKit

/**
 Routes Android's set-window-document tool through the owning live reader controller.

 A successful result is built from selected native state observed after the controller mutation,
 matching Android's page-manager boundary. Missing panes, unknown documents, invalid exact keys,
 and failed selection work throw instead of allowing the agent to report a navigation that the UI
 did not select. WebView replacement remains an asynchronous reader concern.
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
       mutating, then persists the target pane's selected document and key. Entry families wait for
       their asynchronous selected-key transaction before state is read back, but do not treat local
       bridge acceptance as a Vue-render acknowledgment.
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
            if let authorizedKey,
               controller.currentDictionaryKey.map({
                   SwordJavaStringIdentity.equals($0, authorizedKey)
               }) != true {
                try requireCommittedSelection(
                    await controller.loadDictionaryEntryAwaitingCommittedSelection(key: authorizedKey),
                    expectedKey: authorizedKey
                )
            }

        case .generalBook:
            try requireSuccessfulSwitch(controller.switchGeneralBookDocument(to: resolvedInitials))
            if let authorizedKey,
               controller.currentGeneralBookKey.map({
                   SwordJavaStringIdentity.equals($0, authorizedKey)
               }) != true {
                try requireCommittedSelection(
                    await controller.loadInstalledGeneralBookEntryAwaitingCommittedSelection(
                        key: authorizedKey
                    ),
                    expectedKey: authorizedKey
                )
            }

        case .map:
            try requireSuccessfulSwitch(controller.switchMapDocument(to: resolvedInitials))
            if let authorizedKey,
               controller.currentMapKey.map({
                   SwordJavaStringIdentity.equals($0, authorizedKey)
               }) != true {
                try requireCommittedSelection(
                    await controller.loadMapEntryAwaitingCommittedSelection(key: authorizedKey),
                    expectedKey: authorizedKey
                )
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
                  myDocumentStore.page(bookInitials: resolvedInitials, pageKey: pageKey) != nil else {
                throw failure("KEY_NOT_FOUND", "The requested My Documents page is not available.")
            }
            try requireCommittedSelection(
                await controller.loadMyDocumentPageAwaitingCommittedSelection(
                    bookInitials: resolvedInitials,
                    pageKey: pageKey
                ),
                expectedKey: pageKey
            )

            resolvedName = SwordJavaStringIdentity.trim(document.name)

        case .epub(let reader):
            resolvedInitials = reader.initials
            let epubSettlement = await controller.switchEpubAwaitingSelection(
                identifier: reader.identifier,
                key: normalizedKey.flatMap { $0.isEmpty ? nil : $0 }
            )
            guard let selectedEpubKey = epubSettlement.committedKey else {
                if normalizedKey.map({ !$0.isEmpty }) == true,
                   case .failed = epubSettlement.publicationDisposition {
                    throw failure("KEY_NOT_FOUND", "The requested EPUB key is not available.")
                }
                throw failure("NAVIGATION_FAILED", "The requested document could not be opened.")
            }
            try requireCommittedSelection(
                epubSettlement,
                expectedKey: selectedEpubKey
            )
            guard controller.activeModuleName(for: .generalBook).map({
                SwordJavaStringIdentity.equals($0, resolvedInitials)
            }) == true else {
                throw failure("NAVIGATION_FAILED", "The requested document could not be opened.")
            }
            guard
                  controller.currentGeneralBookKey.map({
                      SwordJavaStringIdentity.equals($0, selectedEpubKey)
                  }) == true else {
                throw failure("KEY_NOT_FOUND", "The requested EPUB key is not available.")
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

    /**
     Requires a request-owned native selection receipt without imposing a WebView acknowledgment.

     Android's window-document tool returns the page-manager selection immediately after its
     synchronous mutation; its later document load is asynchronous. Matching that boundary allows
     a bridge-rejected selection to succeed and remain replayable, while failed, cancelled, and
     stale work cannot borrow matching state from an earlier request.

     - Parameters:
       - settlement: Terminal preparation result plus the key committed by this exact request.
       - expectedKey: Exact canonical key authorized for the requested owner.
     - Side effects: None; the receipt is checked without reading unrelated prior state.
     - Throws: `NAVIGATION_FAILED` when no exact current selection was committed by this request.
     */
    private func requireCommittedSelection(
        _ settlement: BibleReaderPreparationSelectionSettlement,
        expectedKey: String
    ) throws {
        guard settlement.committedKey.map({
            SwordJavaStringIdentity.equals($0, expectedKey)
        }) == true else {
            throw failure("NAVIGATION_FAILED", "The requested document could not be displayed.")
        }
        switch settlement.publicationDisposition {
        case .accepted, .bridgeRejected:
            return
        case .failed, .stale, .cancelled, .dispatchedStale:
            throw failure("NAVIGATION_FAILED", "The requested document could not be displayed.")
        }
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
