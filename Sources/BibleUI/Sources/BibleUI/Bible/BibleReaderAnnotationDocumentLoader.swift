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
 Emits annotation-backed fake documents into the shared BibleView renderer.

 Android represents My Notes, StudyPad, and Memorize as reader documents rather than native sheets.
 This loader owns the payload assembly and bridge emission sequence for those Android-shaped
 documents while `BibleReaderController` keeps pane state ownership: which special document is
 visible, current selection/editing flags, and the active rendered-content export.

 Inputs:
 - live bookmark/study-pad persistence through `BookmarkService`
 - active reader coordinates and SWORD verse lookup closures supplied by the controller
 - payload factories shared with bookmark bridge events
 - bridge event and rendered-content callbacks

 Outputs:
 - `clear_document`, `add_documents`, and `setup_content` bridge events consumed by Vue/BibleView
 - rendered-content state updates through the supplied callback
 - My Notes mutation revision increments through the supplied callback

 Side effects:
 - reads bookmark, StudyPad, reading-progress, and memorization stores
 - mutates the active SWORD module cursor while building Memorize text, matching the previous
   controller behavior
 - emits JavaScript bridge events through `BibleBridge`

 Failure modes:
 - returns `false` when required client/module/range/label data cannot be resolved
 - logs failed payload serialization or stale StudyPad labels without throwing
 */
struct BibleReaderAnnotationDocumentLoader {
    /// Resolved ordinal range for one chapter.
    typealias ChapterOrdinalRange = (start: Int, end: Int, verseCount: Int)
    /// Resolves a visible chapter range from the active SWORD/JSword versification.
    typealias ChapterRangeProvider = () -> ChapterOrdinalRange?
    /// Returns current-chapter note-backed bookmarks.
    typealias MyNotesBookmarkProvider = () -> [BibleBookmark]
    /// Projects a Bible bookmark into the shared Vue bridge DTO.
    typealias BibleBookmarkPayloadBuilder = (BibleBookmark) -> BibleBookmarkData
    /// Projects a generic bookmark into the shared Vue bridge DTO.
    typealias GenericBookmarkPayloadBuilder = (GenericBookmark) -> GenericBookmarkData
    /// Projects a persisted label into the shared Vue bridge DTO.
    typealias LabelPayloadBuilder = (Label) -> LabelData?
    /// Projects a Bible bookmark-label relationship into the shared Vue bridge DTO.
    typealias BibleBookmarkToLabelPayloadBuilder = (BibleBookmarkToLabel) -> BookmarkToLabelData?
    /// Projects a generic bookmark-label relationship into the shared Vue bridge DTO.
    typealias GenericBookmarkToLabelPayloadBuilder = (GenericBookmarkToLabel) -> BookmarkToLabelData?
    /// Projects a StudyPad text entry into the shared Vue bridge DTO.
    typealias StudyPadEntryPayloadBuilder = (StudyPadTextEntry) -> StudyPadTextItemData
    /// Resolves a persisted ordinal into the active reader chapter/verse.
    typealias VerseReferenceProvider = (String, Int) -> VerseKeyReference?
    /// Parses a SWORD key such as `Genesis 1:1`.
    typealias VerseKeyParser = (String) -> (String, Int, Int)?
    /// Produces no-module placeholder text for Memorize documents.
    typealias PlaceholderVerseTextProvider = (String, Int, Int) -> String
    /// Reads memorization state for a rendered ordinal range.
    typealias OrdinalProgressProvider = (String, Int, Int) -> [Int]
    /// Updates the compact rendered-content state owned by the controller.
    typealias RenderedContentStateSetter = (
        DocumentCategory,
        String?,
        String,
        Int?,
        String?,
        ReaderRenderedDocumentKind
    ) -> Void

    /// Bridge used for Vue event emission.
    private let bridge: BibleBridge
    /// Optional persistence facade for bookmark and StudyPad documents.
    private let bookmarkService: BookmarkService?
    /// Emits the current label list before annotation documents that render bookmark labels.
    private let sendLabels: () -> Void
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
       - bridge: Active WebView bridge.
       - bookmarkService: Bookmark/StudyPad persistence facade, or `nil` when annotations are
         unavailable.
       - sendLabels: Callback that emits label state to Vue.
       - setRenderedContentState: Callback that updates controller-owned rendered-content state.
       - incrementMyNotesRevision: Callback that advances My Notes visible-state revision.
       - applyNightModeBackground: Callback that reapplies reader background styling.
       - clearSelection: Callback that clears native WebView selection.
     - Side effects: None during initialization.
     - Failure modes: None.
     */
    init(
        bridge: BibleBridge,
        bookmarkService: BookmarkService?,
        sendLabels: @escaping () -> Void,
        setRenderedContentState: @escaping RenderedContentStateSetter,
        incrementMyNotesRevision: @escaping () -> Void,
        applyNightModeBackground: @escaping () -> Void,
        clearSelection: @escaping () -> Void
    ) {
        self.bridge = bridge
        self.bookmarkService = bookmarkService
        self.sendLabels = sendLabels
        self.setRenderedContentState = setRenderedContentState
        self.incrementMyNotesRevision = incrementMyNotesRevision
        self.applyNightModeBackground = applyNightModeBackground
        self.clearSelection = clearSelection
    }

    /**
     Emits the My Notes fake document for the active chapter.

     - Parameters:
       - currentBook: Active display book name.
       - currentChapter: Active chapter number.
       - osisBookId: Active OSIS book identifier.
       - jumpToOrdinal: Optional row ordinal to scroll to after Vue renders the document.
       - chapterRange: Closure resolving the current chapter ordinal range.
       - bookmarks: Closure returning note-backed bookmarks for the current chapter.
       - bookmarkPayload: Shared bookmark payload projector.
       - prepareVisibleState: Controller callback that marks My Notes as visible before range
         validation, preserving the previous pending-visible behavior.
     - Returns: `true` when the document was emitted; otherwise `false`.
     - Side effects: Emits bridge events, sends labels, updates rendered-content state, and
       increments the My Notes mutation revision on success.
     - Failure modes: Returns `false` when the active chapter range cannot be resolved.
     */
    @discardableResult
    func loadMyNotesDocument(
        currentBook: String,
        currentChapter: Int,
        osisBookId: String,
        jumpToOrdinal: Int?,
        chapterRange: ChapterRangeProvider,
        bookmarks: MyNotesBookmarkProvider,
        bookmarkPayload: BibleBookmarkPayloadBuilder,
        prepareVisibleState: () -> Void
    ) -> Bool {
        prepareVisibleState()
        guard let range = chapterRange() else {
            annotationDocumentLoaderLogger.error(
                "Failed to resolve My Notes chapter range for \(currentBook, privacy: .public) \(currentChapter)"
            )
            return false
        }

        let verseRange = "\(currentBook) \(currentChapter):1-\(range.verseCount)"
        let docId = "\(osisBookId).\(currentChapter).1-\(osisBookId).\(currentChapter).\(range.verseCount)"
        let document = MyNotesDocumentPayload(
            id: docId,
            type: "notes",
            bookmarks: bookmarks().map { bookmarkPayload($0) },
            verseRange: verseRange,
            ordinalRange: [range.start, range.end]
        )

        bridge.emit(event: "clear_document")
        sendLabels()
        bridge.emit(event: "add_documents", data: document)
        bridge.emit(
            event: "setup_content",
            data: ReaderSetupContentPayload(jumpToOrdinal: jumpToOrdinal)
        )
        setRenderedContentState(.bible, "My Notes", "My Notes", currentChapter, docId, .standard)
        incrementMyNotesRevision()
        return true
    }

    /**
     Emits a StudyPad fake document for one label.

     - Parameters:
       - labelId: StudyPad label identifier.
       - bookmarkId: Optional bookmark row to scroll to after Vue renders the document.
       - labelPayload: Shared label payload projector.
       - bookmarkPayload: Shared Bible bookmark payload projector.
       - genericBookmarkPayload: Shared generic bookmark payload projector.
       - bibleBookmarkToLabelPayload: Shared Bible bookmark-label relationship projector.
       - genericBookmarkToLabelPayload: Shared generic bookmark-label relationship projector.
       - studyPadEntryPayload: Shared StudyPad text entry projector.
       - prepareVisibleState: Controller callback that applies visible StudyPad state after the
         label has been validated but before payload rows are fetched.
     - Returns: `true` when the document was emitted; otherwise `false`.
     - Side effects: Reads StudyPad rows, emits bridge events, sends labels, updates
       rendered-content state, and reapplies background styling.
     - Failure modes: Returns `false` when annotations are unavailable, the label is stale, or the
       label payload cannot be serialized.
     */
    @discardableResult
    func loadStudyPadDocument(
        labelId: UUID,
        bookmarkId: UUID?,
        labelPayload: LabelPayloadBuilder,
        bookmarkPayload: BibleBookmarkPayloadBuilder,
        genericBookmarkPayload: GenericBookmarkPayloadBuilder,
        bibleBookmarkToLabelPayload: BibleBookmarkToLabelPayloadBuilder,
        genericBookmarkToLabelPayload: GenericBookmarkToLabelPayloadBuilder,
        studyPadEntryPayload: StudyPadEntryPayloadBuilder,
        prepareVisibleState: (String) -> Void
    ) -> Bool {
        guard let bookmarkService else { return false }
        guard let label = bookmarkService.label(id: labelId) else {
            annotationDocumentLoaderLogger.warning("loadStudyPadDocument: label not found for \(labelId)")
            return false
        }
        guard let labelData = labelPayload(label) else {
            annotationDocumentLoaderLogger.warning("loadStudyPadDocument: label deleted before serialization for \(labelId)")
            return false
        }

        prepareVisibleState(label.name)

        let document = StudyPadDocumentPayload(
            id: "journal_\(labelId.uuidString)",
            type: "journal",
            label: labelData,
            bookmarks: bookmarkService.bibleBookmarks(withLabel: labelId).map { bookmarkPayload($0) },
            genericBookmarks: bookmarkService.genericBookmarks(withLabel: labelId).map { genericBookmarkPayload($0) },
            bookmarkToLabels: bookmarkService.bibleBookmarkToLabels(labelId: labelId).compactMap {
                bibleBookmarkToLabelPayload($0)
            },
            genericBookmarkToLabels: bookmarkService.genericBookmarkToLabels(labelId: labelId).compactMap {
                genericBookmarkToLabelPayload($0)
            },
            journalTextEntries: bookmarkService.studyPadEntries(labelId: labelId).map { studyPadEntryPayload($0) }
        )

        bridge.emit(event: "clear_document")
        sendLabels()
        bridge.emit(event: "add_documents", data: document)
        bridge.emit(
            event: "setup_content",
            data: ReaderSetupContentPayload(jumpToId: bookmarkId?.uuidString)
        )
        setRenderedContentState(.bible, "StudyPad", label.name, nil, "journal_\(labelId.uuidString)", .studyPad)
        applyNightModeBackground()
        return true
    }

    /**
     Emits the Memorize fake document for a selected verse range.

     - Parameters:
       - request: Active reader/module data needed to build the Memorize document.
       - prepareVisibleState: Controller callback that clears competing visible special-document
         state after the document can be built.
     - Returns: `true` when the document was emitted; otherwise `false`.
     - Side effects: May move the active SWORD module cursor, emits bridge events, updates
       rendered-content state, clears selection, and reapplies background styling.
     - Failure modes: Returns `false` when the selected ordinals do not map to visible verses or
       JSON serialization fails.
     */
    @discardableResult
    func loadMemorizeDocument(
        request: MemorizeDocumentRequest,
        prepareVisibleState: () -> Void
    ) -> Bool {
        guard let ordinalRange = memorizeOrdinalRange(request) else { return false }
        guard let document = buildMemorizeDocumentJSON(request) else { return false }
        prepareVisibleState()
        bridge.emit(event: "clear_document")
        bridge.emit(event: "add_documents", data: document)
        bridge.emit(event: "setup_content", data: ReaderSetupContentPayload())
        setRenderedContentState(
            .bible,
            request.activeModuleName,
            "Memorize",
            request.currentChapter,
            "memorize:\(request.bookInitials):\(ordinalRange.start)-\(ordinalRange.end)",
            .memorize
        )
        clearSelection()
        applyNightModeBackground()
        return true
    }

    /**
     Builds serialized Memorize document JSON for the Vue reader.

     - Parameter request: Active reader state and store providers.
     - Returns: JSON string for one Memorize document, or `nil` when no verse text can be resolved.
     - Side effects: May move the active SWORD module cursor while collecting verse text.
     - Failure modes: Returns `nil` for invalid ordinal ranges or JSON serialization failure.
     */
    private func buildMemorizeDocumentJSON(_ request: MemorizeDocumentRequest) -> String? {
        guard let ordinalRange = memorizeOrdinalRange(request) else { return nil }
        let textItems = memorizeTextItems(request)
        guard !textItems.isEmpty else { return nil }

        let document: [String: Any] = [
            "id": "memorize-\(request.bookInitials)-\(ordinalRange.start)-\(ordinalRange.end)",
            "type": "memorize",
            "title": memorizeReferenceTitle(request),
            "texts": textItems,
            "state": memorizeDocumentState(from: request.stateJSON),
            "bookInitials": request.bookInitials,
            "v11n": "KJVA",
            "osisRef": memorizeOsisRef(request),
            "startOrdinal": ordinalRange.start,
            "endOrdinal": ordinalRange.end,
            "memorizedOrdinals": request.memorizedOrdinals(
                request.bookInitials,
                ordinalRange.start,
                ordinalRange.end
            ),
            "targetOrdinals": request.targetOrdinals(
                request.bookInitials,
                ordinalRange.start,
                ordinalRange.end
            ),
            "readingProgressSettings": request.readingProgressSettings(),
        ]

        guard JSONSerialization.isValidJSONObject(document),
              let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            annotationDocumentLoaderLogger.error("Failed to serialize Memorize document JSON")
            return nil
        }
        return json
    }

    private func memorizeDocumentState(from rawState: String?) -> [String: Any] {
        if let rawState,
           let data = rawState.data(using: .utf8),
           let state = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
           JSONSerialization.isValidJSONObject(state) {
            return state
        }

        return [
            "memorize": [
                "mode": "blur",
                "modeConfig": [String: Any](),
            ] as [String: Any],
        ]
    }

    /**
     Builds ordered verse text rows for Memorize.

     - Parameter request: Active reader/module data.
     - Returns: Verse key/text rows for each concrete verse in the selected range.
     - Side effects: May move the active SWORD module cursor.
     - Failure modes: Returns an empty array when ordinals cannot be mapped to visible verses.
     */
    private func memorizeTextItems(_ request: MemorizeDocumentRequest) -> [[String: String]] {
        let references = memorizeVerseReferences(request)
        guard !references.isEmpty else { return [] }

        if let activeModule = request.activeModule {
            return swordMemorizeTextItems(
                module: activeModule,
                request: request,
                references: references
            )
        }

        return references.compactMap { reference in
            let boundedEndVerse = BibleReaderBookCatalog.verseCount(
                for: request.currentBook,
                chapter: reference.chapter
            )
            guard reference.verse <= boundedEndVerse else { return nil }
            return [
                "key": reference.osisRef,
                "text": request.placeholderVerseText(request.currentBook, reference.chapter, reference.verse),
            ]
        }
    }

    /**
     Builds Memorize rows from a live SWORD module.

     - Parameters:
       - module: Active Bible module.
       - request: Active reader state.
       - references: Concrete verse references in selected ordinal order.
     - Returns: Non-empty verse text rows when SWORD exposes text for the selected range.
     - Side effects: Moves the module cursor through selected verse keys.
     - Failure modes: Skips references whose exact SWORD key cannot be validated or has no text.
     */
    private func swordMemorizeTextItems(
        module: SwordModule,
        request: MemorizeDocumentRequest,
        references: [VerseKeyReference]
    ) -> [[String: String]] {
        references.compactMap { reference in
            module.setKey("=\(reference.osisRef)")
            let key = module.currentKey()
            guard let (_, parsedChapter, parsedVerse) = request.parseVerseKey(key),
                  parsedChapter == reference.chapter,
                  parsedVerse == reference.verse else { return nil }
            let verseText = module.stripText().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !verseText.isEmpty else { return nil }
            return [
                "key": reference.osisRef,
                "text": verseText,
            ]
        }
    }

    /**
     Resolves the selected ordinal range using Android's `endOrdinal <= 0` behavior.

     - Parameter request: Active reader state.
     - Returns: Inclusive rendered ordinal range, or `nil` for invalid start ordinals.
     - Side effects: None.
     - Failure modes: Invalid start ordinals return `nil`.
     */
    private func memorizeOrdinalRange(_ request: MemorizeDocumentRequest) -> (start: Int, end: Int)? {
        guard request.startOrdinal > 0 else { return nil }
        let effectiveEnd = request.endOrdinal > 0 ? request.endOrdinal : request.startOrdinal
        guard effectiveEnd > 0 else { return nil }
        return (
            start: min(request.startOrdinal, effectiveEnd),
            end: max(request.startOrdinal, effectiveEnd)
        )
    }

    /**
     Resolves every concrete verse reference in the selected Memorize ordinal range.

     - Parameter request: Active reader state.
     - Returns: Ordered verse references, excluding SWORD intro/title ordinals.
     - Side effects: May query active SWORD versification through the supplied closure.
     - Failure modes: Invalid ranges or non-verse ordinals produce an empty array.
     */
    private func memorizeVerseReferences(_ request: MemorizeDocumentRequest) -> [VerseKeyReference] {
        guard let ordinalRange = memorizeOrdinalRange(request) else { return [] }
        return (ordinalRange.start...ordinalRange.end).compactMap { ordinal in
            request.verseReference(request.currentBook, ordinal)
        }
    }

    /**
     Resolves the first and last concrete verse reference for the selected Memorize range.

     - Parameter request: Active reader state.
     - Returns: Boundary references for title and OSIS formatting.
     - Side effects: May query active SWORD versification through the supplied closure.
     - Failure modes: Returns `nil` when the range contains no concrete verses.
     */
    private func memorizeReferenceRange(
        _ request: MemorizeDocumentRequest
    ) -> (start: VerseKeyReference, end: VerseKeyReference)? {
        let references = memorizeVerseReferences(request)
        guard let start = references.first,
              let end = references.last else { return nil }
        return (start, end)
    }

    /**
     Builds the human-readable Memorize title.

     - Parameter request: Active reader state.
     - Returns: Android-style range title when ordinals resolve, otherwise `Book chapter`.
     - Side effects: May query active SWORD versification through the supplied closure.
     - Failure modes: Falls back to chapter-only title for invalid ordinals.
     */
    private func memorizeReferenceTitle(_ request: MemorizeDocumentRequest) -> String {
        guard let range = memorizeReferenceRange(request) else {
            return "\(request.currentBook) \(request.currentChapter)"
        }
        if range.start.chapter == range.end.chapter {
            let verseSuffix = range.start.verse == range.end.verse ?
                "\(range.start.verse)" :
                "\(range.start.verse)-\(range.end.verse)"
            return "\(request.currentBook) \(range.start.chapter):\(verseSuffix)"
        }

        return "\(request.currentBook) \(range.start.chapter):\(range.start.verse)-\(range.end.chapter):\(range.end.verse)"
    }

    /**
     Builds the OSIS reference for the Memorize document.

     - Parameter request: Active reader state.
     - Returns: Verse OSIS range when ordinals resolve, otherwise chapter OSIS reference.
     - Side effects: May query active SWORD versification through the supplied closure.
     - Failure modes: Falls back to chapter-only OSIS reference for invalid ordinals.
     */
    private func memorizeOsisRef(_ request: MemorizeDocumentRequest) -> String {
        guard let range = memorizeReferenceRange(request) else {
            return "\(request.osisBookId).\(request.currentChapter)"
        }
        return range.start.osisRef == range.end.osisRef ?
            range.start.osisRef :
            "\(range.start.osisRef)-\(range.end.osisRef)"
    }
}

/**
 Active reader state needed to build one Memorize fake document.

 The request is intentionally immutable so tests can verify Memorize payload construction without
 needing a full `BibleReaderController`. It mirrors Android's bridge handoff: selected module,
 selected ordinal range, active chapter context, and progress state are read at document-open time.

 Side effects: None during initialization.
 Failure modes: None during initialization; invalid values are rejected by the loader.
 */
struct MemorizeDocumentRequest {
    /// Selected module initials.
    let bookInitials: String
    /// Selected start ordinal.
    let startOrdinal: Int
    /// Selected end ordinal.
    let endOrdinal: Int
    /// Active Bible module initials shown in rendered-content state.
    let activeModuleName: String
    /// Active display book name.
    let currentBook: String
    /// Active chapter number.
    let currentChapter: Int
    /// Active OSIS book identifier.
    let osisBookId: String
    /// Active SWORD module, or `nil` for no-module placeholder behavior.
    let activeModule: SwordModule?
    /// Saved Vue document state from the active page manager.
    let stateJSON: String?
    /// Resolves ordinals using active versification.
    let verseReference: BibleReaderAnnotationDocumentLoader.VerseReferenceProvider
    /// Parses SWORD verse keys.
    let parseVerseKey: BibleReaderAnnotationDocumentLoader.VerseKeyParser
    /// Supplies no-module placeholder text.
    let placeholderVerseText: BibleReaderAnnotationDocumentLoader.PlaceholderVerseTextProvider
    /// Reads memorized ordinals for the selected range.
    let memorizedOrdinals: BibleReaderAnnotationDocumentLoader.OrdinalProgressProvider
    /// Reads target ordinals for the selected range.
    let targetOrdinals: BibleReaderAnnotationDocumentLoader.OrdinalProgressProvider
    /// Builds current reading-progress settings payload.
    let readingProgressSettings: () -> [String: Any]
}
