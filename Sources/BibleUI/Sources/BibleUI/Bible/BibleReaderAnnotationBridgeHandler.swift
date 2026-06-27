import Foundation
import BibleCore
import BibleView
import os.log

private let annotationBridgeHandlerLogger = Logger(
    subsystem: "org.andbible",
    category: "BibleReaderAnnotationBridgeHandler"
)

/**
 Routes bookmark, My Notes, and StudyPad bridge delegate calls for one reader pane.

 `BibleReaderController` must remain the `BibleBridgeDelegate`, but bookmark and StudyPad bridge
 behavior is a coherent annotation boundary rather than reader orchestration. This handler keeps the
 delegate method routing, Android-compatible logging, UI-test mutation guards, native label
 assignment handoff, and coordinator lookup together while the lower-level
 `BibleReaderAnnotationBridgeCoordinator` continues to own persistence-result application and Vue
 event emission.

 Inputs:
 - `BibleBridge` delegate callback parameters from BibleView
 - a coordinator factory bound to the controller's current bookmark service and bridge state hooks
 - controller state closures for editing mode, visible My Notes/StudyPad state, and UI-test
   annotation fixtures

 Outputs:
 - calls into `BibleReaderAnnotationBridgeCoordinator`
 - native label-assignment callback requests
 - editing-mode updates through the injected setter

 Side effects:
 - mutates bookmark/StudyPad persistence through the annotation bridge coordinator
 - may emit BibleView bridge events through the coordinator
 - mutates controller editing state and one-shot UI-test annotation guards

 Failure modes:
 - missing bookmark persistence logs or returns without side effects, matching the previous
   controller behavior
 - malformed UUIDs, stale StudyPad rows, or disabled UI-test fixture configuration are ignored
   without throwing
 */
struct BibleReaderAnnotationBridgeHandler {
    /// Builds the coordinator that performs persistence and bridge event application.
    private let coordinator: (BibleBridge) -> BibleReaderAnnotationBridgeCoordinator?
    /// Supplies the currently configured bookmark service for UI-test StudyPad row lookup.
    private let bookmarkService: () -> BookmarkService?
    /// Indicates whether My Notes is currently the visible document.
    private let isShowingMyNotes: () -> Bool
    /// Indicates whether StudyPad is currently the visible document.
    private let isShowingStudyPad: () -> Bool
    /// Supplies the active StudyPad label id when StudyPad is visible.
    private let activeStudyPadLabelId: () -> UUID?
    /// Supplies note-backed bookmarks currently visible in My Notes.
    private let currentChapterMyNotesBookmarks: () -> [BibleBookmark]
    /// Applies WebView editing state back to the controller.
    private let setEditingInWebView: (Bool) -> Void
    /// Requests native label-assignment UI from the owning SwiftUI view.
    private let assignLabels: (UUID) -> Void

    /// One-shot guard for UI-test My Notes append fixtures.
    private var didApplyUITestMyNotesAppendText = false
    /// One-shot guard for UI-test StudyPad created-note fixtures.
    private var didApplyUITestStudyPadCreatedNoteText = false

    /**
     Creates a bridge handler bound to a controller's current state accessors.

     - Parameters:
       - coordinator: Factory for a bridge-specific annotation coordinator.
       - bookmarkService: Bookmark persistence supplier used for UI-test StudyPad row lookup.
       - isShowingMyNotes: Closure returning whether My Notes is visible.
       - isShowingStudyPad: Closure returning whether StudyPad is visible.
       - activeStudyPadLabelId: Closure returning the active StudyPad label id.
       - currentChapterMyNotesBookmarks: Closure returning visible My Notes bookmark rows.
       - setEditingInWebView: Closure applying editing-mode state to the controller.
       - assignLabels: Closure requesting native label assignment.
     - Side effects: None during initialization.
     - Failure modes: None.
     */
    init(
        coordinator: @escaping (BibleBridge) -> BibleReaderAnnotationBridgeCoordinator?,
        bookmarkService: @escaping () -> BookmarkService?,
        isShowingMyNotes: @escaping () -> Bool,
        isShowingStudyPad: @escaping () -> Bool,
        activeStudyPadLabelId: @escaping () -> UUID?,
        currentChapterMyNotesBookmarks: @escaping () -> [BibleBookmark],
        setEditingInWebView: @escaping (Bool) -> Void,
        assignLabels: @escaping (UUID) -> Void
    ) {
        self.coordinator = coordinator
        self.bookmarkService = bookmarkService
        self.isShowingMyNotes = isShowingMyNotes
        self.isShowingStudyPad = isShowingStudyPad
        self.activeStudyPadLabelId = activeStudyPadLabelId
        self.currentChapterMyNotesBookmarks = currentChapterMyNotesBookmarks
        self.setEditingInWebView = setEditingInWebView
        self.assignLabels = assignLabels
    }

    /// Shared bookmark creation/update path used by JS bridge and native selection actions.
    mutating func addOrUpdateBibleBookmark(
        bridge: BibleBridge,
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int,
        addNote: Bool,
        wholeVerse: Bool,
        startOffset: Int? = nil,
        endOffset: Int? = nil
    ) {
        guard let coordinator = coordinator(bridge) else {
            annotationBridgeHandlerLogger.warning("addBookmark: bookmarkService is nil")
            return
        }
        coordinator.addOrUpdateBibleBookmark(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            addNote: addNote,
            wholeVerse: wholeVerse,
            startOffset: startOffset,
            endOffset: endOffset
        )
    }

    /// Creates a Bible bookmark requested from the web client.
    mutating func addBookmark(
        bridge: BibleBridge,
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int,
        addNote: Bool
    ) {
        addOrUpdateBibleBookmark(
            bridge: bridge,
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            addNote: addNote,
            wholeVerse: true
        )
    }

    /// Creates a generic bookmark for non-Bible content from a web-client request.
    func addGenericBookmark(
        bridge: BibleBridge,
        bookInitials: String,
        osisRef: String,
        startOrdinal: Int,
        endOrdinal: Int,
        addNote: Bool
    ) {
        annotationBridgeHandlerLogger.info("Add generic bookmark: \(bookInitials) ref=\(osisRef)")
        coordinator(bridge)?.addGenericBookmark(
            bookInitials: bookInitials,
            osisRef: osisRef,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            addNote: addNote
        )
    }

    /// Creates a Bible paragraph-break bookmark requested from the web client.
    func addParagraphBreakBookmark(bridge: BibleBridge, bookInitials: String, startOrdinal: Int, endOrdinal: Int) {
        annotationBridgeHandlerLogger.info("Add paragraph break bookmark: \(bookInitials)")
        coordinator(bridge)?.addParagraphBreakBibleBookmark(
            bookInitials: bookInitials,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    /// Creates a generic paragraph-break bookmark requested from the web client.
    func addGenericParagraphBreakBookmark(
        bridge: BibleBridge,
        bookInitials: String,
        osisRef: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) {
        annotationBridgeHandlerLogger.info("Add generic paragraph break bookmark: \(bookInitials) ref=\(osisRef)")
        coordinator(bridge)?.addGenericParagraphBreakBookmark(
            bookInitials: bookInitials,
            osisRef: osisRef,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
    }

    /// Deletes a Bible bookmark requested from the web client.
    func removeBookmark(bridge: BibleBridge, bookmarkId: String) {
        annotationBridgeHandlerLogger.info("Remove bookmark: \(bookmarkId)")
        coordinator(bridge)?.removeBookmark(bookmarkId)
    }

    /// Deletes a generic bookmark requested from the web client.
    func removeGenericBookmark(bridge: BibleBridge, bookmarkId: String) {
        annotationBridgeHandlerLogger.info("Remove generic bookmark: \(bookmarkId)")
        coordinator(bridge)?.removeGenericBookmark(bookmarkId)
    }

    /// Persists note text for an existing bookmark and notifies the web client.
    func saveBookmarkNote(bridge: BibleBridge, bookmarkId: String, note: String?) {
        annotationBridgeHandlerLogger.info("Save bookmark note: \(bookmarkId)")
        _ = coordinator(bridge)?.saveBookmarkNote(bookmarkId: bookmarkId, note: note)
    }

    /// Requests native label-assignment UI for a bookmark from the owning SwiftUI view.
    func assignLabels(bookmarkId: String) {
        annotationBridgeHandlerLogger.info("Assign labels requested for: \(bookmarkId)")
        guard let uuid = UUID(uuidString: bookmarkId) else { return }
        assignLabels(uuid)
    }

    /// Refreshes one bookmark payload after native label assignment dismisses.
    func refreshBookmark(bridge: BibleBridge, bookmarkId: UUID) {
        coordinator(bridge)?.refreshBookmark(bookmarkId: bookmarkId)
    }

    /// Toggles one label assignment on a bookmark and re-emits updated state.
    func toggleBookmarkLabel(bridge: BibleBridge, bookmarkId: String, labelId: String) {
        annotationBridgeHandlerLogger.info("Toggle label \(labelId) on bookmark \(bookmarkId)")
        coordinator(bridge)?.toggleBookmarkLabel(bookmarkId: bookmarkId, labelId: labelId)
    }

    /// Removes one label assignment from a bookmark and re-emits updated state.
    func removeBookmarkLabel(bridge: BibleBridge, bookmarkId: String, labelId: String) {
        annotationBridgeHandlerLogger.info("Remove label \(labelId) from bookmark \(bookmarkId)")
        coordinator(bridge)?.removeBookmarkLabel(bookmarkId: bookmarkId, labelId: labelId)
    }

    /// Sets the primary label used to style a bookmark in Vue.js.
    func setPrimaryLabel(bridge: BibleBridge, bookmarkId: String, labelId: String) {
        annotationBridgeHandlerLogger.info("Set primary label \(labelId) on bookmark \(bookmarkId)")
        coordinator(bridge)?.setPrimaryLabel(bookmarkId: bookmarkId, labelId: labelId)
    }

    /// Updates whether a bookmark should highlight whole verses or a text-range selection.
    func setBookmarkWholeVerse(bridge: BibleBridge, bookmarkId: String, value: Bool) {
        annotationBridgeHandlerLogger.info("Set whole verse \(value) for bookmark \(bookmarkId)")
        coordinator(bridge)?.setBookmarkWholeVerse(bookmarkId: bookmarkId, value: value)
    }

    /// Updates the custom icon attached to a bookmark.
    func setBookmarkCustomIcon(bridge: BibleBridge, bookmarkId: String, value: String?) {
        annotationBridgeHandlerLogger.info("Set custom icon for bookmark \(bookmarkId)")
        coordinator(bridge)?.setBookmarkCustomIcon(bookmarkId: bookmarkId, value: value)
    }

    /// Creates a new StudyPad text entry relative to an existing bookmark or note row.
    mutating func createNewStudyPadEntry(
        bridge: BibleBridge,
        labelId: String,
        entryType: String,
        afterEntryId: String
    ) {
        annotationBridgeHandlerLogger.info("Create StudyPad entry type=\(entryType) after \(afterEntryId) in label \(labelId)")
        coordinator(bridge)?.createNewStudyPadEntry(
            labelId: labelId,
            entryType: entryType,
            afterEntryId: afterEntryId
        )
        applyUITestStudyPadCreatedNoteTextIfNeeded(bridge: bridge)
    }

    /// Deletes one StudyPad text entry and emits the resulting reordered state.
    func deleteStudyPadEntry(bridge: BibleBridge, studyPadId: String) {
        annotationBridgeHandlerLogger.info("Delete StudyPad entry: \(studyPadId)")
        coordinator(bridge)?.deleteStudyPadEntry(studyPadId)
    }

    /// Updates StudyPad entry metadata such as indent level or order number.
    func updateStudyPadTextEntry(bridge: BibleBridge, data: String) {
        annotationBridgeHandlerLogger.info("Update StudyPad text entry metadata")
        coordinator(bridge)?.updateStudyPadTextEntry(data: data)
    }

    /// Persists edited text for one StudyPad text entry.
    func updateStudyPadTextEntryText(bridge: BibleBridge, id: String, text: String) {
        annotationBridgeHandlerLogger.info("Update StudyPad entry text: \(id)")
        _ = coordinator(bridge)?.updateStudyPadTextEntryText(id: id, text: text)
    }

    /// Persists reordered StudyPad rows and bookmark associations for one label.
    func updateOrderNumber(bridge: BibleBridge, labelId: String, data: String) {
        annotationBridgeHandlerLogger.info("Update order numbers for label \(labelId)")
        coordinator(bridge)?.updateOrderNumber(labelId: labelId, data: data)
    }

    /// Updates one `BibleBookmarkToLabel` association from a JSON payload emitted by Vue.js.
    func updateBookmarkToLabel(bridge: BibleBridge, data: String) {
        annotationBridgeHandlerLogger.info("Update BibleBookmarkToLabel")
        coordinator(bridge)?.updateBookmarkToLabel(data: data)
    }

    /// Updates one `GenericBookmarkToLabel` association from a JSON payload emitted by Vue.js.
    func updateGenericBookmarkToLabel(bridge: BibleBridge, data: String) {
        annotationBridgeHandlerLogger.info("Update GenericBookmarkToLabel")
        coordinator(bridge)?.updateGenericBookmarkToLabel(data: data)
    }

    /// Persists an optional bookmark edit action configured in the web client.
    func setBookmarkEditAction(bridge: BibleBridge, bookmarkId: String, value: String) {
        annotationBridgeHandlerLogger.info("Set edit action on bookmark \(bookmarkId): \(value)")
        coordinator(bridge)?.setBookmarkEditAction(bookmarkId: bookmarkId, value: value)
    }

    /**
     Tracks whether the embedded web client is currently editing content.

     When UI-test fixture hooks are active, entering editing mode is also the deterministic signal
     that the created note/editor row exists and can receive seeded text.
     */
    mutating func setEditing(bridge: BibleBridge, enabled: Bool) {
        annotationBridgeHandlerLogger.info("WebView editing mode: \(enabled)")
        setEditingInWebView(enabled)
        if enabled {
            applyUITestMyNotesAppendTextIfNeeded(bridge: bridge)
            applyUITestStudyPadCreatedNoteTextIfNeeded(bridge: bridge)
        }
    }

    /// Persists the current insertion cursor position for a StudyPad label.
    func setStudyPadCursor(bridge: BibleBridge, labelId: String, orderNumber: Int) {
        annotationBridgeHandlerLogger.info("StudyPad cursor: label=\(labelId) order=\(orderNumber)")
        coordinator(bridge)?.setStudyPadCursor(labelId: labelId, orderNumber: orderNumber)
    }

    @discardableResult
    private mutating func applyUITestMyNotesAppendTextIfNeeded(bridge: BibleBridge) -> Bool {
        guard !didApplyUITestMyNotesAppendText,
              let appendText = UITestRuntimeConfiguration.myNotesAppendText,
              appendUITestTextToFirstVisibleMyNotesNote(appendText, bridge: bridge) else {
            return false
        }
        didApplyUITestMyNotesAppendText = true
        return true
    }

    @discardableResult
    private func appendUITestTextToFirstVisibleMyNotesNote(_ text: String, bridge: BibleBridge) -> Bool {
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports,
              isShowingMyNotes(),
              !text.isEmpty,
              let bookmark = currentChapterMyNotesBookmarks().first
        else {
            return false
        }

        let currentNote = bookmark.notes?.notes ?? ""
        return coordinator(bridge)?.saveBookmarkNote(
            bookmarkId: bookmark.id.uuidString,
            note: currentNote + text
        ) ?? false
    }

    @discardableResult
    private mutating func applyUITestStudyPadCreatedNoteTextIfNeeded(bridge: BibleBridge) -> Bool {
        guard !didApplyUITestStudyPadCreatedNoteText,
              let noteText = UITestRuntimeConfiguration.studyPadCreatedNoteText,
              updateNewestVisibleStudyPadTextEntry(noteText, bridge: bridge) else {
            return false
        }
        didApplyUITestStudyPadCreatedNoteText = true
        return true
    }

    @discardableResult
    private func updateNewestVisibleStudyPadTextEntry(_ text: String, bridge: BibleBridge) -> Bool {
        guard UITestRuntimeConfiguration.enablesDetailedAccessibilityExports,
              isShowingStudyPad(),
              !text.isEmpty,
              let service = bookmarkService(),
              let labelId = activeStudyPadLabelId(),
              let coordinator = coordinator(bridge),
              let entry = service.studyPadEntries(labelId: labelId).max(by: { lhs, rhs in
                  if lhs.orderNumber != rhs.orderNumber {
                      return lhs.orderNumber < rhs.orderNumber
                  }
                  return lhs.id.uuidString < rhs.id.uuidString
              })
        else {
            return false
        }

        return coordinator.updateStudyPadTextEntryText(id: entry.id.uuidString, text: text)
    }
}
