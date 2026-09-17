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

/** Copied outcome of one bounded auxiliary source read. */
enum BibleReaderAuxiliarySourceCapture: Sendable {
    /// Exact structural SWORD fragment ready for annotation capture and encoding.
    case fragment(SwordRawOSISFragment)
    /// User-visible structural/read failure retained without carrying an Error across queues.
    case failure(String)
}

/** Bridge-ready auxiliary result returned to its main publication owner. */
enum BibleReaderPreparedAuxiliaryResult: Sendable {
    /// Encoded document plus the exact resolved source identity committed after bridge acceptance.
    case document(
        json: String,
        sourceInitials: String,
        key: String,
        keyName: String,
        sourceProvenance: BibleReaderRenderSourceProvenance,
        ownerIdentity: BibleReaderGenericDocumentOwnerIdentity,
        sourceDependencies: [BibleReaderPreparationSourceDependency]
    )
    /// Source/read/encoding failure rendered through the existing error-document path.
    case failure(String)
}

/** Applies family-specific effects around the shared prepared-document publication transaction. */
extension BibleReaderAuxiliaryContentLoader {
    /** Persists only the exact authorized document key; failures do not change selection. */
    func commitPreparedSelection(
        _ result: BibleReaderPreparedAuxiliaryResult,
        request: BibleReaderAuxiliaryModuleEntryRequest
    ) {
        guard case .document(_, _, let key, _, _, _, _) = result else { return }
        request.persistResolvedKey(key)
    }

    /** Dispatches one prepared document or bounded error payload without committing render state. */
    func dispatchPreparedModuleEntry(
        _ result: BibleReaderPreparedAuxiliaryResult,
        request: BibleReaderAuxiliaryModuleEntryRequest
    ) -> Bool {
        switch result {
        case .failure(let message):
            guard let document = documentPayloadFactory.errorDocumentJSON(message: message) else {
                return false
            }
            return documentReplacement.replace(
                documentJSON: document,
                setup: Self.setupContentPayload
            )
        case .document(let json, _, _, _, _, _, _):
            return documentReplacement.replace(
                documentJSON: json,
                setup: Self.setupContentPayload
            )
        }
    }

    /** Commits rendered identity and background only after the prepared dispatch is accepted. */
    func commitPreparedRender(
        _ result: BibleReaderPreparedAuxiliaryResult,
        request: BibleReaderAuxiliaryModuleEntryRequest
    ) {
        switch result {
        case .failure:
            let hasModule = request.module != nil
            let selectedKey = request.requestedKey ?? request.currentKey
            setRenderedContentState(
                request.category,
                request.moduleName,
                hasModule ? (selectedKey ?? request.moduleName ?? request.fallbackBookName)
                    : request.fallbackBookName,
                hasModule ? (selectedKey ?? "none") : "none",
                .independent
            )
        case .document(_, let sourceInitials, let key, let keyName, let provenance, _, _):
            setRenderedContentState(request.category, sourceInitials, keyName, key, provenance)
        }
        applyNightModeBackground()
    }
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
    typealias RenderedContentStateSetter = (
        DocumentCategory,
        String?,
        String,
        String?,
        BibleReaderRenderSourceProvenance
    ) -> Void

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

    /** Publishes a bounded missing-module or missing-key result without reading native content. */
    func publishUnavailableModuleEntry(
        _ request: BibleReaderAuxiliaryModuleEntryRequest,
        message: String
    ) {
        resetReaderState()
        let result = BibleReaderPreparedAuxiliaryResult.failure(message)
        guard dispatchPreparedModuleEntry(result, request: request) else { return }
        commitPreparedRender(result, request: request)
    }
}
