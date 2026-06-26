import Foundation
import BibleCore
import BibleView

/**
 Owns bookmark and StudyPad bridge event application for one reader pane.

 `BibleReaderBookmarkActionCoordinator` and `BibleReaderStudyPadActionCoordinator` own the
 Android-aligned persistence rules. This coordinator owns the remaining bridge boundary: creating
 those action coordinators, applying their native state effects, and emitting the shared BibleView
 event names/payload shapes. Keeping that boundary outside `BibleReaderController` prevents the
 controller from mixing bookmark persistence, StudyPad ordering, workspace cursor persistence, and
 JavaScript event emission.

 Inputs:
 - bridge callbacks and payload strings from the shared BibleView runtime
 - controller state closures for mutation revisions, workspace settings, recent labels, labels,
   config, and state persistence
 - bookmark persistence through `BookmarkService`
 - annotation payload projection through `BibleReaderAnnotationPayloadFactory`

 Outputs:
 - JavaScript bridge events consumed by Vue/BibleView
 - controller-owned revision and workspace mutations applied through closures

 Side effects:
 - mutates bookmark and StudyPad persistence through the composed action coordinators
 - mutates controller-owned revision counters and workspace settings through injected closures
 - emits bridge events and optional label/config refresh events

 Failure modes:
 - returns `false` for note persistence when no bookmark service exists or a stale identifier
   produces no native/bridge effect
 - stale or malformed action inputs are delegated to the action coordinators, which return
   no-change results instead of throwing
 */
struct BibleReaderAnnotationBridgeCoordinator {
    /// Active bridge instance for the pane callback being handled.
    private let bridge: BibleBridge
    /// Persistence facade for bookmark and StudyPad mutations.
    private let bookmarkService: BookmarkService
    /// Payload projector shared with document rendering.
    private let payloadFactory: BibleReaderAnnotationPayloadFactory
    /// Current reader book name used by bookmark creation.
    private let currentBook: String
    /// Active notes content type supplier for note and StudyPad journal creation.
    private let currentNotesContentType: () -> String
    /// Current workspace settings supplier for auto-label and cursor mutations.
    private let workspaceSettings: () -> WorkspaceSettings?
    /// Applies updated workspace settings back to the active workspace.
    private let setWorkspaceSettings: (WorkspaceSettings) -> Void
    /// Persists reader/window state after workspace-affecting bridge actions.
    private let persistState: () -> Void
    /// Advances My Notes mutation revision for UI-test exports and document refresh tracking.
    private let incrementMyNotesRevision: () -> Void
    /// Advances StudyPad mutation revision for UI-test exports and document refresh tracking.
    private let incrementStudyPadRevision: () -> Void
    /// Tracks recently used labels in the app settings model.
    private let trackRecentLabel: (String) -> Void
    /// Emits the latest label list to Vue.
    private let sendLabels: () -> Void
    /// Builds the current config payload to refresh Vue app settings.
    private let buildConfigJSON: () -> String

    /**
     Creates an annotation bridge coordinator for one controller callback.

     - Parameters:
       - bridge: Active BibleView bridge for event emission.
       - bookmarkService: Bookmark persistence facade.
       - payloadFactory: Projection factory for typed bridge DTOs.
       - currentBook: Current book name for new Bible bookmark rows.
       - currentNotesContentType: Closure returning the active notes content type.
       - workspaceSettings: Closure returning the active workspace settings.
       - setWorkspaceSettings: Closure applying updated workspace settings.
       - persistState: Closure persisting reader/window state.
       - incrementMyNotesRevision: Closure advancing My Notes mutation revision.
       - incrementStudyPadRevision: Closure advancing StudyPad mutation revision.
       - trackRecentLabel: Closure recording recent label usage.
       - sendLabels: Closure emitting current labels to Vue.
       - buildConfigJSON: Closure building the current `set_config` payload.
     - Side effects: None during initialization.
     - Failure modes: None.
     */
    init(
        bridge: BibleBridge,
        bookmarkService: BookmarkService,
        payloadFactory: BibleReaderAnnotationPayloadFactory,
        currentBook: String,
        currentNotesContentType: @escaping () -> String,
        workspaceSettings: @escaping () -> WorkspaceSettings?,
        setWorkspaceSettings: @escaping (WorkspaceSettings) -> Void,
        persistState: @escaping () -> Void,
        incrementMyNotesRevision: @escaping () -> Void,
        incrementStudyPadRevision: @escaping () -> Void,
        trackRecentLabel: @escaping (String) -> Void,
        sendLabels: @escaping () -> Void,
        buildConfigJSON: @escaping () -> String
    ) {
        self.bridge = bridge
        self.bookmarkService = bookmarkService
        self.payloadFactory = payloadFactory
        self.currentBook = currentBook
        self.currentNotesContentType = currentNotesContentType
        self.workspaceSettings = workspaceSettings
        self.setWorkspaceSettings = setWorkspaceSettings
        self.persistState = persistState
        self.incrementMyNotesRevision = incrementMyNotesRevision
        self.incrementStudyPadRevision = incrementStudyPadRevision
        self.trackRecentLabel = trackRecentLabel
        self.sendLabels = sendLabels
        self.buildConfigJSON = buildConfigJSON
    }

    /**
     Creates or updates a Bible bookmark and applies all bridge/state effects.
     */
    func addOrUpdateBibleBookmark(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int,
        addNote: Bool,
        wholeVerse: Bool,
        startOffset: Int? = nil,
        endOffset: Int? = nil
    ) {
        apply(
            bookmarkCoordinator.addOrUpdateBibleBookmark(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                addNote: addNote,
                wholeVerse: wholeVerse,
                startOffset: startOffset,
                endOffset: endOffset,
                workspaceSettings: workspaceSettings()
            )
        )
    }

    /**
     Creates a generic bookmark and applies all bridge/state effects.
     */
    func addGenericBookmark(
        bookInitials: String,
        osisRef: String,
        startOrdinal: Int,
        endOrdinal: Int,
        addNote: Bool
    ) {
        apply(
            bookmarkCoordinator.addGenericBookmark(
                bookInitials: bookInitials,
                osisRef: osisRef,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal,
                addNote: addNote,
                workspaceSettings: workspaceSettings()
            )
        )
    }

    /// Creates a Bible paragraph-break bookmark and emits the resulting update.
    func addParagraphBreakBibleBookmark(bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        apply(
            bookmarkCoordinator.addParagraphBreakBibleBookmark(
                bookInitials: bookInitials,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal
            )
        )
    }

    /// Creates a generic paragraph-break bookmark and emits the resulting update.
    func addGenericParagraphBreakBookmark(
        bookInitials: String,
        osisRef: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) {
        apply(
            bookmarkCoordinator.addGenericParagraphBreakBookmark(
                bookInitials: bookInitials,
                osisRef: osisRef,
                startOrdinal: startOrdinal,
                endOrdinal: endOrdinal
            )
        )
    }

    /// Deletes a Bible bookmark and emits Android's delete event.
    func removeBookmark(_ bookmarkId: String) {
        apply(bookmarkCoordinator.removeBookmark(bookmarkId))
    }

    /// Deletes a generic bookmark.
    func removeGenericBookmark(_ bookmarkId: String) {
        apply(bookmarkCoordinator.removeGenericBookmark(bookmarkId))
    }

    /**
     Saves bookmark note text and emits the resulting note-modified event.

     - Returns: `true` when the action produced a native revision increment or bridge event.
     */
    @discardableResult
    func saveBookmarkNote(bookmarkId: String, note: String?) -> Bool {
        let result = bookmarkCoordinator.saveBookmarkNote(bookmarkId: bookmarkId, note: note)
        apply(result)
        return result.incrementsMyNotesRevision || !result.events.isEmpty
    }

    /// Refreshes one bookmark payload after native label assignment dismisses.
    func refreshBookmark(bookmarkId: UUID) {
        guard let bookmark = bookmarkService.bibleBookmark(id: bookmarkId) else { return }
        bridge.emit(event: "add_or_update_bookmarks", data: [payloadFactory.bookmarkJSONForStudyPad(bookmark)])
        sendLabels()
        emitConfig()
    }

    /// Toggles one label assignment on a bookmark and emits the resulting update.
    func toggleBookmarkLabel(bookmarkId: String, labelId: String) {
        apply(bookmarkCoordinator.toggleBookmarkLabel(bookmarkId: bookmarkId, labelId: labelId))
    }

    /// Removes one label assignment from a bookmark and emits the resulting update.
    func removeBookmarkLabel(bookmarkId: String, labelId: String) {
        apply(bookmarkCoordinator.removeBookmarkLabel(bookmarkId: bookmarkId, labelId: labelId))
    }

    /// Sets the primary label for a bookmark and emits the resulting update.
    func setPrimaryLabel(bookmarkId: String, labelId: String) {
        apply(bookmarkCoordinator.setPrimaryLabel(bookmarkId: bookmarkId, labelId: labelId))
    }

    /// Updates whole-verse highlighting state for a bookmark and emits the resulting update.
    func setBookmarkWholeVerse(bookmarkId: String, value: Bool) {
        apply(bookmarkCoordinator.setBookmarkWholeVerse(bookmarkId: bookmarkId, value: value))
    }

    /// Updates a bookmark custom icon and emits the resulting update.
    func setBookmarkCustomIcon(bookmarkId: String, value: String?) {
        apply(bookmarkCoordinator.setBookmarkCustomIcon(bookmarkId: bookmarkId, value: value))
    }

    /// Persists a bookmark edit action and emits the resulting update.
    func setBookmarkEditAction(bookmarkId: String, value: String) {
        apply(bookmarkCoordinator.setBookmarkEditAction(bookmarkId: bookmarkId, value: value))
    }

    /// Creates a StudyPad journal row and emits the resulting reorder/update event sequence.
    func createNewStudyPadEntry(labelId: String, entryType: String, afterEntryId: String) {
        apply(
            studyPadCoordinator.createNewStudyPadEntry(
                labelId: labelId,
                entryType: entryType,
                afterEntryId: afterEntryId
            )
        )
    }

    /// Deletes a StudyPad journal row and emits the resulting delete/reorder events.
    func deleteStudyPadEntry(_ studyPadId: String) {
        apply(studyPadCoordinator.deleteStudyPadEntry(studyPadId))
    }

    /// Updates StudyPad journal row metadata from a shared-client payload.
    func updateStudyPadTextEntry(data: String) {
        apply(studyPadCoordinator.updateStudyPadTextEntry(data: data))
    }

    /// Updates StudyPad journal text and emits the resulting row payload.
    func updateStudyPadTextEntryText(id: String, text: String) {
        apply(studyPadCoordinator.updateStudyPadTextEntryText(id: id, text: text))
    }

    /// Updates StudyPad row ordering from Android/shared-client payload keys.
    func updateOrderNumber(labelId: String, data: String) {
        apply(studyPadCoordinator.updateOrderNumber(labelId: labelId, data: data))
    }

    /// Updates one Bible bookmark-to-label relation from a StudyPad payload.
    func updateBookmarkToLabel(data: String) {
        apply(studyPadCoordinator.updateBookmarkToLabel(data: data))
    }

    /// Updates one generic bookmark-to-label relation from a StudyPad payload.
    func updateGenericBookmarkToLabel(data: String) {
        apply(studyPadCoordinator.updateGenericBookmarkToLabel(data: data))
    }

    /**
     Persists the current StudyPad insertion cursor and re-emits config for Vue.
     */
    func setStudyPadCursor(labelId: String, orderNumber: Int) {
        guard let uuid = UUID(uuidString: labelId) else { return }
        var settings = workspaceSettings() ?? WorkspaceSettings()
        settings.studyPadCursors[uuid] = orderNumber
        settings.normalizeAutoAssignPrimaryLabel()
        setWorkspaceSettings(settings)
        persistState()
        emitConfig()
    }

    private var bookmarkCoordinator: BibleReaderBookmarkActionCoordinator {
        BibleReaderBookmarkActionCoordinator(
            bookmarkService: bookmarkService,
            payloadFactory: payloadFactory,
            currentBook: currentBook,
            currentNotesContentType: currentNotesContentType
        )
    }

    private var studyPadCoordinator: BibleReaderStudyPadActionCoordinator {
        BibleReaderStudyPadActionCoordinator(
            bookmarkService: bookmarkService,
            payloadFactory: payloadFactory,
            currentNotesContentType: currentNotesContentType
        )
    }

    private func apply(_ result: BibleReaderBookmarkActionResult) {
        if result.incrementsMyNotesRevision {
            incrementMyNotesRevision()
        }
        if var updatedWorkspaceSettings = result.updatedWorkspaceSettings {
            updatedWorkspaceSettings.normalizeAutoAssignPrimaryLabel()
            setWorkspaceSettings(updatedWorkspaceSettings)
        }
        if result.requiresPersistState {
            persistState()
        }
        if let recentLabelId = result.recentLabelId {
            trackRecentLabel(recentLabelId)
        }
        for event in result.events {
            emit(event)
        }
        if result.refreshesLabels {
            sendLabels()
        }
        if result.refreshesConfig {
            emitConfig()
        }
    }

    private func emit(_ event: BibleReaderBookmarkActionEvent) {
        switch event {
        case .bookmarksUpdated(let payloads):
            bridge.emit(event: "add_or_update_bookmarks", data: payloads)
        case .genericBookmarksUpdated(let payloads):
            bridge.emit(event: "add_or_update_bookmarks", data: payloads)
        case .bookmarksDeleted(let ids):
            bridge.emitEncoded(event: "delete_bookmarks", data: ids)
        case .bookmarkClicked(let id, let openLabels, let openNotes):
            bridge.emit(
                event: "bookmark_clicked",
                data: "\"\(id)\", {\"openLabels\":\(openLabels),\"openNotes\":\(openNotes)}"
            )
        case .bookmarkNoteModified(let payload):
            bridge.emit(event: "bookmark_note_modified", data: payload)
        }
    }

    private func apply(_ result: BibleReaderStudyPadActionResult) {
        if result.incrementsStudyPadRevision {
            incrementStudyPadRevision()
        }
        for event in result.events {
            emit(event)
        }
    }

    private func emit(_ event: BibleReaderStudyPadActionEvent) {
        switch event {
        case .studyPadUpdated(let payload):
            bridge.emit(event: "add_or_update_study_pad", data: payload)
        case .studyPadTextEntryDeleted(let id):
            bridge.emitEncoded(event: "delete_study_pad_text_entry", data: id.uuidString)
        case .bookmarkToLabelUpdated(let payload):
            bridge.emit(event: "add_or_update_bookmark_to_label", data: payload)
        }
    }

    private func emitConfig() {
        bridge.emit(event: "set_config", data: buildConfigJSON())
    }
}
