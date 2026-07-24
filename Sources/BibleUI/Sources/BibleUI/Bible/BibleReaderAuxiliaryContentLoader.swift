// BibleReaderAuxiliaryContentLoader.swift - Dictionary, general-book, and map document loading

import Foundation
import BibleCore
import BibleView
import SwordKit

/**
 Describes one SWORD-backed auxiliary document load request.

 Dictionary, general book, and map modules all follow the same Android-style reader workflow:
 resolve an exact module/key, read structural OSIS, emit a single Vue document, and update the
 native rendered-content state. This request captures the category-specific labels and error
 messages while keeping mutable controller state outside the loader.

 - Side effects: None; this is an immutable request value.
 - Failure modes: None during initialization. Missing module/key cases are rendered as error
   documents by `BibleReaderAuxiliaryContentLoader`.
 */
struct BibleReaderAuxiliaryModuleEntryRequest {
    /// High-level document category represented by the module.
    let category: DocumentCategory
    /// Active SWORD module, if one is selected.
    let module: SwordModule?
    /// Active module initials/name used by the web document.
    let moduleName: String?
    /// Explicit key requested by the browser/search UI.
    let requestedKey: String?
    /// Previously selected key restored from pane state.
    let currentKey: String?
    /// Pseudo OSIS book identifier for the generated document.
    let osisBookId: String
    /// Display document name used when no concrete entry key is available.
    let fallbackBookName: String
    /// Bridge category raw value emitted into document metadata.
    let bookCategory: String
    /// Paragraph shown when no module is selected.
    let noModuleMessage: String
    /// Paragraph shown when a module exists but no entry key is selected.
    let noSelectionMessage: String
    /// Phrase used for empty-entry messages.
    let noContentNoun: String
    /// Persists a resolved entry key back into the controller/PageManager.
    let persistResolvedKey: (String) -> Void
}

/**
 Loads auxiliary SWORD module content into the Vue reader.

 `BibleReaderController` owns active module state, persistence, and public entry points. This
 collaborator owns the repeated auxiliary-module rendering workflow shared by dictionaries, general
 books, and maps: reset transient reader state, read exact structural fragments, emit bridge events,
 and update the rendered-content state token.

 Side effects:
 - invokes controller-supplied reset, rendered-state, persistence, and background closures
 - reads the selected exact `SwordModule` key through `SwordRawOSISFragment`
 - emits one atomic `clear_document`, `set_config`, `add_documents`, and `setup_content`
   transaction through the shared replacement emitter

 Failure modes:
 - if document JSON serialization fails, no document event is emitted after any required state reset
 - missing modules, keys, empty entries, and malformed structural content produce deterministic
   error documents instead of rendered-text or synthetic-XML fallbacks
 */
struct BibleReaderAuxiliaryContentLoader {
    /// Updates the controller's compact rendered-content state after a document is emitted.
    typealias RenderedContentStateSetter = (DocumentCategory, String?, String, String?) -> Void

    /// Shared setup payload used by auxiliary single-document loads.
    private static let setupContentPayload = ReaderSetupContentPayload()

    /// Shared Android-parity Vue document replacement transaction.
    private let documentReplacement: BibleReaderDocumentReplacementEmitter
    /// Factory that owns document JSON schema assembly.
    private let documentPayloadFactory: BibleReaderDocumentPayloadFactory
    /// Controller callback that clears transient reader state before replacing content.
    private let resetReaderState: () -> Void
    /// Controller callback that updates `renderedContentState`.
    private let setRenderedContentState: RenderedContentStateSetter
    /// Controller callback that reapplies active reader background colors.
    private let applyNightModeBackground: () -> Void

    /**
     Creates an auxiliary content loader for one render pass.

     - Parameters:
       - documentReplacement: Shared atomic Vue document replacement transaction.
       - documentPayloadFactory: Factory configured from the controller's current reader state.
       - resetReaderState: Clears transient selection/editing/special-document flags.
       - setRenderedContentState: Records the rendered category/module/book/key for UI tests.
       - applyNightModeBackground: Reapplies background styling after the Vue document changes.
     - Side effects: None during initialization.
     - Failure modes: None during initialization.
     */
    init(
        documentReplacement: BibleReaderDocumentReplacementEmitter,
        documentPayloadFactory: BibleReaderDocumentPayloadFactory,
        resetReaderState: @escaping () -> Void,
        setRenderedContentState: @escaping RenderedContentStateSetter,
        applyNightModeBackground: @escaping () -> Void
    ) {
        self.documentReplacement = documentReplacement
        self.documentPayloadFactory = documentPayloadFactory
        self.resetReaderState = resetReaderState
        self.setRenderedContentState = setRenderedContentState
        self.applyNightModeBackground = applyNightModeBackground
    }

    /**
     Loads one dictionary, general-book, or map entry.

     - Parameter request: Category-specific module/key/fallback details.
     - Returns: The resolved entry key when concrete module content was selected; otherwise `nil`.
     - Side effects: Resets transient reader state, may persist the resolved key, moves the module
       cursor, emits Vue document/setup events, updates rendered-content state, and reapplies the
       reader background.
     - Failure modes: Missing module/key states render error documents; document serialization
       failure stops before emitting `add_documents`.
     */
    @discardableResult
    func loadModuleEntry(_ request: BibleReaderAuxiliaryModuleEntryRequest) -> String? {
        resetReaderState()

        guard let module = request.module else {
            emitErrorDocument(
                request: request,
                message: request.noModuleMessage,
                renderedModuleName: request.moduleName,
                renderedBook: request.fallbackBookName,
                renderedKey: "none"
            )
            return nil
        }

        let entryKey = request.requestedKey ?? request.currentKey
        guard let entryKey else {
            let moduleName = request.moduleName ?? request.fallbackBookName
            emitErrorDocument(
                request: request,
                message: request.noSelectionMessage,
                renderedModuleName: moduleName,
                renderedBook: moduleName,
                renderedKey: "none"
            )
            return nil
        }

        let moduleName = request.moduleName ?? request.fallbackBookName
        let fragment: SwordRawOSISFragment
        do {
            fragment = try module.rawOSISFragment(forKey: entryKey)
        } catch {
            emitErrorDocument(
                request: request,
                message: error.localizedDescription,
                renderedModuleName: moduleName,
                renderedBook: entryKey,
                renderedKey: entryKey
            )
            return nil
        }
        guard fragment.hasRenderableContent else {
            emitErrorDocument(
                request: request,
                message: "No \(request.noContentNoun) available for \"\(entryKey)\" in \(moduleName).",
                renderedModuleName: moduleName,
                renderedBook: entryKey,
                renderedKey: entryKey
            )
            return nil
        }
        request.persistResolvedKey(fragment.key)

        emitDocument(
            request: request,
            fragment: fragment,
            renderedModuleName: moduleName,
            renderedBook: fragment.keyName,
            renderedKey: fragment.key
        )
        return fragment.key
    }

    /**
     Serializes and emits one auxiliary document through the shared Vue reader bridge.

     - Parameters:
       - request: Category metadata for the generated document.
       - fragment: Exact structural fragment read from SWORD.
       - renderedModuleName: Module token recorded in rendered-content state.
       - renderedBook: Book token recorded in rendered-content state.
       - renderedKey: Key token recorded in rendered-content state.
     - Side effects: Emits one Android-parity replacement transaction, updates the
       controller-rendered content state through a closure, and reapplies reader background styling.
     - Failure modes: If document serialization or transaction dispatch fails, the existing reader
       document remains visible and rendered-content state is not advanced.
     */
    private func emitDocument(
        request: BibleReaderAuxiliaryModuleEntryRequest,
        fragment: SwordRawOSISFragment,
        renderedModuleName: String?,
        renderedBook: String,
        renderedKey: String
    ) {
        let source = fragment.source
        let contentOrdinalRange = fragment.contentOrdinalRange
        guard let document = documentPayloadFactory.documentJSON(
            BibleReaderDocumentPayloadRequest(
                osisBookId: request.osisBookId,
                bookName: fragment.keyName,
                chapter: 1,
                verseCount: 1,
                isNewTestament: fragment.isNewTestament,
                xml: fragment.xml,
                bookCategory: request.bookCategory,
                bookInitials: source.initials,
                addChapter: false,
                documentKey: fragment.key,
                keyName: fragment.keyName,
                ordinalRangeOverride: [
                    contentOrdinalRange.lowerBound,
                    contentOrdinalRange.upperBound,
                ],
                fragmentOrdinalRange: fragment.keyOrdinalRange.map {
                    [$0.lowerBound, $0.upperBound]
                },
                fragmentKey: fragment.fragmentKey,
                fragmentOsisRef: fragment.osisRef,
                annotateRef: fragment.annotateRef,
                fragmentFeatures: fragment.features,
                moduleName: source.name,
                moduleAbbreviation: source.abbreviation,
                versificationName: source.versification,
                language: source.language,
                direction: source.direction,
                sourceHasStrongs: source.hasStrongs
            )
        ) else {
            return
        }
        guard documentReplacement.replace(
            documentJSON: document,
            setup: Self.setupContentPayload
        ) else {
            return
        }
        setRenderedContentState(request.category, renderedModuleName, renderedBook, renderedKey)
        applyNightModeBackground()
    }

    /**
     Emits a non-structural auxiliary failure as a Vue error document.

     - Parameters:
       - request: Category metadata used for rendered-state projection.
       - message: User-visible no-content or structural failure message.
       - renderedModuleName: Module token recorded in rendered state.
       - renderedBook: Book token recorded in rendered state.
       - renderedKey: Key token recorded in rendered state.
     - Side effects: Emits one Android-parity replacement transaction and updates rendered
       state/background.
     - Failure modes: Serialization or dispatch failure leaves the existing reader document and
       rendered state unchanged.
     */
    private func emitErrorDocument(
        request: BibleReaderAuxiliaryModuleEntryRequest,
        message: String,
        renderedModuleName: String?,
        renderedBook: String,
        renderedKey: String
    ) {
        guard let document = documentPayloadFactory.errorDocumentJSON(message: message) else { return }
        guard documentReplacement.replace(
            documentJSON: document,
            setup: Self.setupContentPayload
        ) else {
            return
        }
        setRenderedContentState(request.category, renderedModuleName, renderedBook, renderedKey)
        applyNightModeBackground()
    }
}
