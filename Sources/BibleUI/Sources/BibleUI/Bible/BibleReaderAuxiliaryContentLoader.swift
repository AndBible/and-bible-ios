// BibleReaderAuxiliaryContentLoader.swift - Dictionary, general-book, and map document loading

import Foundation
import BibleCore
import BibleView
import SwordKit

/**
 Describes one SWORD-backed auxiliary document load request.

 Dictionary, general book, and map modules all follow the same Android-style reader workflow:
 resolve a module/key, wrap rendered module HTML in an OSIS-like fragment, emit a single Vue
 document, and update the native rendered-content state. This request captures the category-specific
 labels and fallback messages while keeping mutable controller state outside the loader.

 - Side effects: None; this is an immutable request value.
 - Failure modes: None during initialization. Missing module/key cases are rendered as fallback
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
    /// Title shown when no module is selected.
    let noModuleTitle: String
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
 books, and maps: reset transient reader state, build fallback or entry XML, emit bridge events, and
 update the rendered-content state token.

 Side effects:
 - invokes controller-supplied reset, rendered-state, persistence, and background closures
 - moves the selected `SwordModule` cursor to the requested key before rendering text
 - emits `clear_document`, `add_documents`, and `setup_content` events through `BibleBridge`

 Failure modes:
 - if document JSON serialization fails, no document event is emitted after any required state reset
 - missing modules and missing keys produce deterministic fallback documents instead of throwing
 - empty rendered module text produces a no-content document for the selected key
 */
struct BibleReaderAuxiliaryContentLoader {
    /// Updates the controller's compact rendered-content state after a document is emitted.
    typealias RenderedContentStateSetter = (DocumentCategory, String?, String, String?) -> Void

    /// Shared setup payload used by auxiliary single-document loads.
    private static let setupContentPayload = """
    {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
    """

    /// Bridge used to emit Vue reader events.
    private let bridge: BibleBridge
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
       - bridge: Web bridge used to emit document events.
       - documentPayloadFactory: Factory configured from the controller's current reader state.
       - resetReaderState: Clears transient selection/editing/special-document flags.
       - setRenderedContentState: Records the rendered category/module/book/key for UI tests.
       - applyNightModeBackground: Reapplies background styling after the Vue document changes.
     - Side effects: None during initialization.
     - Failure modes: None during initialization.
     */
    init(
        bridge: BibleBridge,
        documentPayloadFactory: BibleReaderDocumentPayloadFactory,
        resetReaderState: @escaping () -> Void,
        setRenderedContentState: @escaping RenderedContentStateSetter,
        applyNightModeBackground: @escaping () -> Void
    ) {
        self.bridge = bridge
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
     - Failure modes: Missing module/key states render fallback documents; document serialization
       failure stops before emitting `add_documents`.
     */
    @discardableResult
    func loadModuleEntry(_ request: BibleReaderAuxiliaryModuleEntryRequest) -> String? {
        resetReaderState()

        guard let module = request.module else {
            emitFallbackDocument(
                request: request,
                title: request.noModuleTitle,
                message: request.noModuleMessage,
                bookName: request.fallbackBookName,
                bookInitials: "none",
                renderedModuleName: request.moduleName,
                renderedBook: request.fallbackBookName,
                renderedKey: "none"
            )
            return nil
        }

        let entryKey = request.requestedKey ?? request.currentKey
        guard let entryKey else {
            let moduleName = request.moduleName ?? request.fallbackBookName
            emitFallbackDocument(
                request: request,
                title: moduleName,
                message: request.noSelectionMessage,
                bookName: moduleName,
                bookInitials: moduleName,
                renderedModuleName: moduleName,
                renderedBook: moduleName,
                renderedKey: "none"
            )
            return nil
        }

        module.setKey(entryKey)
        let text = module.renderText()
        let moduleName = request.moduleName ?? request.fallbackBookName
        request.persistResolvedKey(entryKey)

        let xml: String
        if text.isEmpty {
            xml = paragraphDocumentXML(
                title: entryKey,
                message: "No \(request.noContentNoun) available for \"\(entryKey)\" in \(moduleName)."
            )
        } else {
            xml = htmlDocumentXML(title: entryKey, html: text)
        }

        emitDocument(
            request: request,
            xml: xml,
            bookName: entryKey,
            bookInitials: moduleName,
            renderedModuleName: moduleName,
            renderedBook: entryKey,
            renderedKey: entryKey
        )
        return entryKey
    }

    /**
     Emits a deterministic reader document for missing-module or missing-key auxiliary states.

     - Parameters:
       - request: Category-specific document metadata and fallback copy.
       - title: Title written into the generated OSIS-like XML.
       - message: Paragraph shown to the user inside the reader surface.
       - bookName: Document book name sent to Vue.
       - bookInitials: Module initials sent to Vue, or `"none"` when no module exists.
       - renderedModuleName: Module token recorded in the compact rendered-content state.
       - renderedBook: Book token recorded in rendered-content state.
       - renderedKey: Key token recorded in rendered-content state.
     - Side effects: Emits the same bridge events and rendered-state update as concrete content.
     - Failure modes: Delegates serialization failure handling to `emitDocument`.
     */
    private func emitFallbackDocument(
        request: BibleReaderAuxiliaryModuleEntryRequest,
        title: String,
        message: String,
        bookName: String,
        bookInitials: String,
        renderedModuleName: String?,
        renderedBook: String,
        renderedKey: String
    ) {
        emitDocument(
            request: request,
            xml: paragraphDocumentXML(title: title, message: message),
            bookName: bookName,
            bookInitials: bookInitials,
            renderedModuleName: renderedModuleName,
            renderedBook: renderedBook,
            renderedKey: renderedKey
        )
    }

    /**
     Serializes and emits one auxiliary document through the shared Vue reader bridge.

     - Parameters:
       - request: Category metadata for the generated document.
       - xml: OSIS-like fragment containing fallback copy or rendered module HTML.
       - bookName: Document book name sent to Vue.
       - bookInitials: Module initials sent to Vue.
       - renderedModuleName: Module token recorded in rendered-content state.
       - renderedBook: Book token recorded in rendered-content state.
       - renderedKey: Key token recorded in rendered-content state.
     - Side effects: Emits `clear_document`, `add_documents`, and `setup_content`, updates the
       controller-rendered content state through a closure, and reapplies reader background styling.
     - Failure modes: If document serialization fails, the reader is cleared but no replacement
       document/setup event is emitted, matching the previous inline controller behavior.
     */
    private func emitDocument(
        request: BibleReaderAuxiliaryModuleEntryRequest,
        xml: String,
        bookName: String,
        bookInitials: String,
        renderedModuleName: String?,
        renderedBook: String,
        renderedKey: String
    ) {
        bridge.emit(event: "clear_document")
        guard let document = documentPayloadFactory.documentJSON(
            BibleReaderDocumentPayloadRequest(
                osisBookId: request.osisBookId,
                bookName: bookName,
                chapter: 1,
                verseCount: 1,
                isNewTestament: false,
                xml: xml,
                bookCategory: request.bookCategory,
                bookInitials: bookInitials
            )
        ) else {
            return
        }
        bridge.emit(event: "add_documents", data: document)
        bridge.emit(event: "setup_content", data: Self.setupContentPayload)
        setRenderedContentState(request.category, renderedModuleName, renderedBook, renderedKey)
        applyNightModeBackground()
    }

    /**
     Wraps plain fallback copy in the OSIS-like structure accepted by the Vue document renderer.

     - Parameters:
       - title: Visible generated title.
       - message: Plain paragraph text.
     - Returns: XML fragment matching the legacy auxiliary fallback document shape.
     - Side effects: None.
     - Failure modes: Input is inserted verbatim, preserving the previous caller-owned escaping
       contract for these fixed/native strings.
     */
    private func paragraphDocumentXML(title: String, message: String) -> String {
        "<div><title type=\"x-gen\">\(title)</title><div type=\"paragraph\"><p>\(message)</p></div></div>"
    }

    /**
     Wraps rendered module HTML in the OSIS-like paragraph shell expected by Vue.

     - Parameters:
       - title: Resolved module key shown as the generated title.
       - html: HTML returned by SWORD `renderText()`.
     - Returns: XML fragment containing the rendered HTML without additional escaping.
     - Side effects: None.
     - Failure modes: Preserves the previous trust boundary where SWORD-rendered HTML is passed
       through for web rendering.
     */
    private func htmlDocumentXML(title: String, html: String) -> String {
        "<div><title type=\"x-gen\">\(title)</title><div type=\"paragraph\">\(html)</div></div>"
    }
}
