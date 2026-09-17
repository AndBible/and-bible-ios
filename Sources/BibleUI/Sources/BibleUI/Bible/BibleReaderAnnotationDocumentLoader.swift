// BibleReaderAnnotationDocumentLoader.swift -- My Notes, StudyPad, and Memorize document emission

import Foundation
import BibleCore
import BibleView
import SwordKit
import os.log

private let annotationDocumentLoaderLogger = Logger(
    subsystem: "org.andbible",
    category: "BibleReaderAnnotationDocumentLoader"
)

/**
 Exact source identity and concrete references retained for Memorize reconstruction.

 Inputs are copied from one authorized native SWORD Bible request. The value produces no output or
 side effect itself; the destination controller uses it to construct a fresh request after settings
 invalidation or client recreation. An empty reference array is invalid and rejected by the request
 builder before publication. The immutable copy is safe to retain across asynchronous UI events.
 */
struct MemorizeDocumentSource: Sendable {
    /// Exact readable SWORD Bible initials.
    let bookInitials: String

    /// Ordered source-domain verse references included by the Memorize document.
    let references: [VerseKeyReference]
}

/**
 Prebuilt Memorize fake-document emission ready for a destination reader controller.

 Android routes Memorize through `FakeBookFactory.memorizeDocument`, so the source pane must be able
 to build the Vue payload once and then let the owning window decide whether the current pane or the
 links pane renders it. This value carries both the serialized document and the native state tokens
 the destination controller needs to expose Android's commentary-category fake document.

 Inputs:
 - serialized Vue Memorize document JSON
 - selected source module initials and ordinal range
 - Android-visible reference title

 Outputs:
 - immutable emission data consumed by the loader's Memorize dispatch and render-commit methods
   and pane-level links-window routing

 Side effects: None.
 Failure modes: Construction is caller-validated; invalid JSON is still treated as opaque bridge
 payload text by the downstream emitter, matching the existing bridge contract.
 */
struct MemorizeDocumentEmission: Sendable {
    /// Serialized Vue document payload to pass to `add_documents`.
    let documentJSON: String

    /// Source module initials used by Android Memorize progress and rendered-state keys.
    let bookInitials: String

    /// First selected ordinal in the resolved Memorize range.
    let startOrdinal: Int

    /// Last selected ordinal in the resolved Memorize range.
    let endOrdinal: Int

    /// Source reference title shown inside the Vue Memorize document.
    let title: String

    /// Android `BookAndKeySerialized` JSON used to restore the source range.
    let sourceBookAndKeyJSON: String?

    /// Typed source inputs used to re-extract text after extraction settings change.
    let source: MemorizeDocumentSource

    init(
        documentJSON: String,
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int,
        title: String,
        sourceBookAndKeyJSON: String?,
        source: MemorizeDocumentSource
    ) {
        self.documentJSON = documentJSON
        self.bookInitials = bookInitials
        self.startOrdinal = startOrdinal
        self.endOrdinal = endOrdinal
        self.title = title
        self.sourceBookAndKeyJSON = sourceBookAndKeyJSON
        self.source = source
    }

    /** Copies the payload while attaching its source-owned routed authorization. */
    func authorized(
        by sourceAuthorization: BibleReaderRoutedSourceAuthorization
    ) -> BibleReaderMemorizeRenderRequest {
        BibleReaderMemorizeRenderRequest(
            emission: self,
            sourceAuthorization: sourceAuthorization
        )
    }

    /// Stable rendered-content key for UI tests and client-ready replay.
    var renderedKey: String {
        "memorize:\(bookInitials):\(startOrdinal)-\(endOrdinal)"
    }
}

/** Prepared Memorize payload paired with required source-owned destination authorization. */
struct BibleReaderMemorizeRenderRequest: Sendable {
    let emission: MemorizeDocumentEmission
    let sourceAuthorization: BibleReaderRoutedSourceAuthorization
}


/**
 Emits annotation-backed fake documents into the shared BibleView renderer.

 Android represents My Notes, StudyPad, and Memorize as reader documents rather than native sheets.
 This loader owns the payload assembly and bridge emission sequence for those Android-shaped
 documents while `BibleReaderController` keeps pane state ownership: which special document is
 visible, current selection/editing flags, and the active rendered-content export.

 Inputs:
 - immutable My Notes and StudyPad documents prepared by the controller-owned coordinator
 - the shared Android-parity replacement emitter and rendered-content callbacks

Outputs:
 - one atomic `clear_document`, `set_config`, `add_documents`, and `setup_content` transaction
   consumed by Vue/BibleView
 - rendered-content state updates through the supplied callback
 - My Notes mutation revision increments through the supplied callback

 Side effects:
 - emits JavaScript bridge events through `BibleReaderDocumentReplacementEmitter`

 Failure modes:
 - returns `false` when required client/module/range/label data cannot be resolved
 - logs failed payload serialization or stale StudyPad labels without throwing
 */
struct BibleReaderAnnotationDocumentLoader {
    /// Updates the compact rendered-content state owned by the controller.
    typealias RenderedContentStateSetter = (
        DocumentCategory,
        String?,
        String,
        Int?,
        String?,
        BibleReaderRenderSourceProvenance,
        ReaderRenderedDocumentKind
    ) -> Void

    /// Shared Android-parity Vue document replacement transaction.
    private let documentReplacement: BibleReaderDocumentReplacementEmitter
    /// Emits the exact prepared label list before annotation documents that render bookmarks.
    private let sendLabels: ([LabelData]) -> Void
    /// Applies rendered-content identity to controller-owned state.
    private let setRenderedContentState: RenderedContentStateSetter
    /// Advances My Notes mutation revision after successful document emission.
    private let incrementMyNotesRevision: () -> Void
    /// Applies reader background after special document emission.
    private let applyNightModeBackground: () -> Void
    /// Clears the current WebView selection after Memorize document emission.
    private let clearSelection: () -> Void

    /**
     Creates an annotation document loader for one reader pane.

     - Parameters:
       - documentReplacement: Shared atomic Vue document replacement transaction.
       - sendLabels: Callback that emits the frozen label state retained by the prepared result.
       - setRenderedContentState: Callback that updates controller-owned rendered-content state.
       - incrementMyNotesRevision: Callback that advances My Notes visible-state revision.
       - applyNightModeBackground: Callback that reapplies reader background styling.
       - clearSelection: Callback that clears native WebView selection.
     - Side effects: None during initialization.
     - Failure modes: None.
     */
    init(
        documentReplacement: BibleReaderDocumentReplacementEmitter,
        sendLabels: @escaping ([LabelData]) -> Void,
        setRenderedContentState: @escaping RenderedContentStateSetter,
        incrementMyNotesRevision: @escaping () -> Void,
        applyNightModeBackground: @escaping () -> Void,
        clearSelection: @escaping () -> Void
    ) {
        self.documentReplacement = documentReplacement
        self.sendLabels = sendLabels
        self.setRenderedContentState = setRenderedContentState
        self.incrementMyNotesRevision = incrementMyNotesRevision
        self.applyNightModeBackground = applyNightModeBackground
        self.clearSelection = clearSelection
    }

    /** Sends the copied My Notes labels before the destination replacement transaction. */
    func prepareMyNotesDispatch(_ result: BibleReaderEncodedMyNotesDocument) {
        sendLabels(result.prepared.labels)
    }

    /** Dispatches one fully prepared My Notes document without committing rendered state. */
    @discardableResult
    func dispatchMyNotesDocument(_ result: BibleReaderEncodedMyNotesDocument) -> Bool {
        let prepared = result.prepared
        guard documentReplacement.replace(
            documentJSON: result.documentJSON,
            setup: ReaderSetupContentPayload(jumpToOrdinal: prepared.jumpToOrdinal)
        ) else {
            annotationDocumentLoaderLogger.error("Failed to emit My Notes document replacement")
            return false
        }
        return true
    }

    /** Commits My Notes rendered identity only after the bridge accepts its prepared document. */
    func commitMyNotesRender(_ result: BibleReaderEncodedMyNotesDocument) {
        let prepared = result.prepared
        setRenderedContentState(
            .bible,
            "My Notes",
            "My Notes",
            prepared.reference.mappedKJVAStart.chapter,
            prepared.documentID,
            .compositeMayUseSword,
            .standard
        )
        incrementMyNotesRevision()
    }

    /** Sends the copied StudyPad labels before the destination replacement transaction. */
    func prepareStudyPadDispatch(_ result: BibleReaderEncodedStudyPadDocument) {
        sendLabels(result.prepared.labels)
    }

    /** Dispatches one fully prepared StudyPad document without committing rendered state. */
    @discardableResult
    func dispatchStudyPadDocument(_ result: BibleReaderEncodedStudyPadDocument) -> Bool {
        let prepared = result.prepared
        guard documentReplacement.replace(
            documentJSON: result.documentJSON,
            setup: ReaderSetupContentPayload(jumpToId: prepared.jumpToID)
        ) else {
            annotationDocumentLoaderLogger.error("Failed to emit StudyPad document replacement")
            return false
        }
        return true
    }

    /** Commits StudyPad rendered identity only after the bridge accepts its prepared document. */
    func commitStudyPadRender(_ result: BibleReaderEncodedStudyPadDocument) {
        let prepared = result.prepared
        setRenderedContentState(
            .bible,
            "StudyPad",
            prepared.label.name,
            nil,
            prepared.documentID,
            .compositeMayUseSword,
            .studyPad
        )
        applyNightModeBackground()
    }

    /**
     Emits a prebuilt Memorize fake document into the selected destination controller.

     - Parameters:
       - emission: Serialized Vue payload and native fake-document metadata.
       - prepareVisibleState: Controller callback that applies Android's commentary/Memorize
         PageManager identity and clears competing visible special-document state.
     - Returns: `true` only when the complete document replacement reaches the bridge.
     - Side effects: Emits bridge events, updates rendered-content state, clears selection, and
       reapplies background styling.
     - Failure modes: Bridge rejection returns `false`, logs the failure, and leaves rendered state
       uncommitted; payload syntax remains the upstream builder's responsibility.
     */
    @discardableResult
    func dispatchMemorizeDocument(_ emission: MemorizeDocumentEmission) -> Bool {
        guard documentReplacement.replace(
            documentJSON: emission.documentJSON,
            setup: ReaderSetupContentPayload()
        ) else {
            annotationDocumentLoaderLogger.error("Failed to emit Memorize document replacement")
            return false
        }
        return true
    }

    /** Commits Memorize render identity after its prepared replacement is accepted. */
    func commitMemorizeRender(_ emission: MemorizeDocumentEmission) {
        setRenderedContentState(
            AndroidSpecialDocumentIdentity.memorizeDocumentCategory,
            AndroidSpecialDocumentIdentity.memorizeDocumentInitials,
            emission.title,
            nil,
            emission.renderedKey,
            .swordModules([emission.bookInitials]),
            .memorize
        )
        clearSelection()
        applyNightModeBackground()
    }

}
