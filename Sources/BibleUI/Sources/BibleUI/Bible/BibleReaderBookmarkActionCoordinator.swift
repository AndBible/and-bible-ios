import Foundation
import BibleCore
import BibleView
import SwordKit

/**
 Declares whether a Bible bookmark mutation creates a new Android entity or updates one identity.

 Android's `BaseBookmarkWithNotes.new` flag makes this distinction explicit: new objects are
 inserted even when their ranges overlap, while existing objects are updated by UUID. Carrying the
 identity at the iOS action boundary prevents positional de-duplication from collapsing distinct
 highlights.
 */
enum BibleBookmarkMutationIdentity: Equatable {
    /// Insert a new bookmark with a new UUID.
    case create
    /// Update only the bookmark with this stable UUID.
    case update(UUID)
}

/**
 Coordinates bookmark bridge mutations and turns their persistence effects into Vue bridge events.

 `BibleReaderController` remains the `BibleBridgeDelegate` and still owns web-view emission,
 controller state, logging, and UI-test revision counters. This coordinator owns the cohesive
 bookmark action rules that Android keeps behind `BibleJavascriptInterface`, `BibleView`, and
 `BookmarkControl`: bookmark creation, note persistence, label edits, primary label selection,
 whole-verse toggles, custom icons, and edit actions.

 Inputs:
 - bridge identifiers and payloads received from the shared BibleView JavaScript runtime
 - bookmark persistence through `BookmarkService`
 - workspace settings needed for Android-compatible auto-label and StudyPad cursor behavior
 - annotation payload projection for bookmark DTOs

 Outputs:
 - `BibleReaderBookmarkActionResult` values that describe native state changes and bridge events
   the controller should emit

 Side effects:
 - mutates bookmark, note, label, and bookmark-to-label persistence through `BookmarkService`

 Failure modes:
 - invalid identifiers, missing bookmarks, missing labels, or malformed optional JSON return
   `.noChange` where the existing iOS bridge is tolerant of stale client state
 */
struct BibleReaderBookmarkActionCoordinator {
    /// Persistence facade used for every bookmark action mutation.
    private let bookmarkService: BookmarkService
    /// Payload projector shared with document rendering so event DTOs stay in one bridge schema.
    private let payloadFactory: BibleReaderAnnotationPayloadFactory
    /// Current reader book name used for legacy bookmark rows that do not carry their own book.
    private let currentBook: String
    /// Resolves exact source coordinates into a typed, verified KJVA persistence contract.
    private let verifiedKJVAOrdinalRange: (String, Int, Int) -> VerifiedKJVAOrdinalRange?
    /// Supplies the active Android-compatible notes content type for newly-created note rows.
    private let currentNotesContentType: () -> String

    /**
     Creates a coordinator for one reader controller.

     - Parameters:
       - bookmarkService: Persistence facade for bookmark, label, note, and StudyPad mutations.
       - payloadFactory: Factory that projects persisted models into typed Vue bridge DTOs.
       - currentBook: Current reader book name to store on newly-created Bible bookmarks.
       - verifiedKJVAOrdinalRange: Closure resolving module initials and source ordinals into a
         typed mapping contract with exact source references.
       - currentNotesContentType: Closure returning the current notes-content-type preference for
         new note rows.
     - Side effects: None during initialization.
     - Failure modes: Bookmark writes later return no change when the resolver cannot prove the
       source-to-KJVA mapping.
     */
    init(
        bookmarkService: BookmarkService,
        payloadFactory: BibleReaderAnnotationPayloadFactory,
        currentBook: String,
        verifiedKJVAOrdinalRange: @escaping (String, Int, Int) -> VerifiedKJVAOrdinalRange?,
        currentNotesContentType: @escaping () -> String
    ) {
        self.bookmarkService = bookmarkService
        self.payloadFactory = payloadFactory
        self.currentBook = currentBook
        self.verifiedKJVAOrdinalRange = verifiedKJVAOrdinalRange
        self.currentNotesContentType = currentNotesContentType
    }

    /**
     Creates or updates a Bible bookmark requested by the web bridge or native selection action.

     Android applies workspace auto-assigned labels and primary label before deciding whether to
     open the label modal. It opens the modal only when no initial labels exist, or when the caller
     explicitly requested note editing.

     - Parameters:
       - bookInitials: Module initials associated with the selected text.
       - startOrdinal: Inclusive source-versification starting verse ordinal.
       - endOrdinal: Inclusive source-versification ending verse ordinal, or `0` for a single-verse selection.
       - addNote: Whether the bookmark sheet should open directly to note editing.
       - wholeVerse: Whether the new bookmark highlights whole verses.
       - startOffset: Optional text-range start offset.
       - endOffset: Optional text-range end offset.
       - identity: Explicit create or UUID-targeted update operation.
       - workspaceSettings: Active workspace settings for auto labels and StudyPad cursors.
     - Returns: Bookmark update and optional modal/config persistence events.
     - Side effects: May insert a Bible bookmark and bookmark-to-label rows.
     - Failure modes: Missing labels in workspace settings are ignored by `BookmarkService`.
       Unresolvable KJVA projection returns `.noChange`; source ordinals are never persisted in the
       KJVA columns.
     */
    func addOrUpdateBibleBookmark(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int,
        addNote: Bool,
        wholeVerse: Bool,
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        identity: BibleBookmarkMutationIdentity,
        workspaceSettings: WorkspaceSettings?
    ) -> BibleReaderBookmarkActionResult {
        let effectiveEndOrdinal = endOrdinal > 0 ? endOrdinal : startOrdinal
        let sourceStart = min(startOrdinal, effectiveEndOrdinal)
        let sourceEnd = max(startOrdinal, effectiveEndOrdinal)
        guard let storageRange = verifiedKJVAOrdinalRange(
            bookInitials,
            sourceStart,
            sourceEnd
        ) else {
            return .noChange
        }
        let bookmark: BibleBookmark
        let isNew: Bool
        switch identity {
        case .create:
            bookmark = bookmarkService.addBibleBookmark(
                ordinalRange: storageRange,
                wholeVerse: wholeVerse,
                startOffset: startOffset,
                endOffset: endOffset,
                addNote: addNote
            )
            applyAutoAssignPrimaryLabel(to: bookmark, workspaceSettings: workspaceSettings)
            isNew = true
        case .update(let id):
            guard let updated = bookmarkService.updateBibleBookmark(
                id: id,
                ordinalRange: storageRange,
                wholeVerse: wholeVerse,
                startOffset: startOffset,
                endOffset: endOffset
            ) else {
                return .noChange
            }
            bookmark = updated
            isNew = false
        }
        bookmark.book = currentBook

        let assignment = isNew
            ? bookmarkService.applyInitialLabels(
                bookmarkId: bookmark.id,
                labelIds: workspaceSettings?.autoAssignLabels ?? [],
                workspaceSettings: workspaceSettings
            )
            : nil

        var events: [BibleReaderBookmarkActionEvent] = [.bookmarksUpdated([payloadFactory.bookmarkJSONForStudyPad(bookmark)])]
        if shouldOpenBookmarkModal(isNew: isNew, addNote: addNote, workspaceSettings: workspaceSettings) {
            events.append(.bookmarkClicked(id: bookmark.id.uuidString, openLabels: true, openNotes: addNote))
        }

        return BibleReaderBookmarkActionResult(
            events: events,
            updatedWorkspaceSettings: assignment?.updatedWorkspaceSettings,
            requiresPersistState: assignment?.changedWorkspaceSettings ?? false,
            refreshesConfig: assignment?.changedWorkspaceSettings ?? false
        )
    }

    /**
     Creates a generic bookmark for non-Bible content.

     Android's generic bookmark path shares the same auto-label, primary-label, and modal-opening
     semantics as Bible bookmark creation. This primitive adapter remains for existing Vue and
     non-SWORD callers; generic SWORD content uses the seed overload below.

     - Parameters:
       - bookInitials: Exact source document initials.
       - osisRef: Exact persisted source key.
       - startOrdinal: Optional local start ordinal; `nil` denotes a whole entry.
       - endOrdinal: Optional local end ordinal; `nil` denotes a whole entry.
       - addNote: Whether to open note editing after creation.
       - wholeVerse: Whether offsets are hidden from the client styling range.
       - startOffset: Optional UTF-16 offset in the first selected anchor.
       - endOffset: Optional UTF-16 offset in the last selected anchor.
       - workspaceSettings: Active workspace auto-label and StudyPad cursor state.
     - Returns: Persistence and bridge events for the newly created generic bookmark.
     - Side effects: Inserts the bookmark, applies labels, and may advance StudyPad cursor state.
     - Failure modes: Missing configured labels are ignored by `BookmarkService`.
     */
    func addGenericBookmark(
        bookInitials: String,
        osisRef: String,
        startOrdinal: Int?,
        endOrdinal: Int?,
        addNote: Bool,
        wholeVerse: Bool,
        startOffset: Int? = nil,
        endOffset: Int? = nil,
        workspaceSettings: WorkspaceSettings?
    ) -> BibleReaderBookmarkActionResult {
        let bookmark = bookmarkService.addGenericBookmark(
            bookInitials: bookInitials,
            key: osisRef,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            wholeVerse: wholeVerse,
            startOffset: startOffset,
            endOffset: endOffset
        )
        return completeGenericBookmarkCreation(
            bookmark,
            addNote: addNote,
            workspaceSettings: workspaceSettings,
            payload: { payloadFactory.genericBookmarkJSONForStudyPad(bookmark) }
        )
    }

    /**
     Creates a generic SWORD bookmark from its immutable exact-source contract.

     The seed crosses the persistence boundary as Android's nullable `GenericBookmark` columns and
     supplies the immediate Vue payload directly, so creation never reloads a nearest key or borrows
     the active Bible. Later refreshes resolve the same persisted initials/key through the raw-fragment API again.

     - Parameters:
       - seed: Validated source, local ordinal range, paired UTF-16 offsets, and whole-entry flags.
       - addNote: Whether to open note editing after creation.
       - workspaceSettings: Active workspace auto-label and StudyPad cursor state.
     - Returns: Persistence and bridge events for the newly created generic bookmark.
     - Side effects: Inserts the bookmark, applies labels, and may advance StudyPad cursor state.
     - Failure modes: Missing configured labels are ignored. Seed validation rejects malformed selections before
       this boundary, and this method performs no active-source or nearest-key fallback.
     */
    func addGenericBookmark(
        seed: SwordGenericBookmarkSeed,
        addNote: Bool,
        workspaceSettings: WorkspaceSettings?
    ) -> BibleReaderBookmarkActionResult {
        let bookmark = bookmarkService.addGenericBookmark(seed: seed)
        return completeGenericBookmarkCreation(
            bookmark,
            addNote: addNote,
            workspaceSettings: workspaceSettings,
            payload: {
                payloadFactory.genericBookmarkJSONForStudyPad(bookmark, sourceSeed: seed)
            }
        )
    }

    /**
     Applies Android's shared label/modal behavior after any generic bookmark insertion.

     - Parameters:
       - bookmark: Newly inserted generic bookmark.
       - addNote: Whether note editing should open immediately.
       - workspaceSettings: Active workspace auto-label and StudyPad cursor state.
       - payload: Deferred exact-source payload projection run after label assignment.
     - Returns: Bookmark update, optional modal event, and workspace persistence flags.
     - Side effects: Applies primary/initial labels and may advance StudyPad cursor state.
     - Failure modes: Missing labels are ignored by `BookmarkService`; payload projection fails
       closed to stored source identifiers.
     */
    private func completeGenericBookmarkCreation(
        _ bookmark: GenericBookmark,
        addNote: Bool,
        workspaceSettings: WorkspaceSettings?,
        payload: () -> GenericBookmarkData
    ) -> BibleReaderBookmarkActionResult {
        applyAutoAssignPrimaryLabel(to: bookmark, workspaceSettings: workspaceSettings)
        let assignment = bookmarkService.applyInitialLabels(
            bookmarkId: bookmark.id,
            labelIds: workspaceSettings?.autoAssignLabels ?? [],
            workspaceSettings: workspaceSettings
        )

        var events: [BibleReaderBookmarkActionEvent] = [
            .genericBookmarksUpdated([payload()]),
        ]
        if shouldOpenBookmarkModal(isNew: true, addNote: addNote, workspaceSettings: workspaceSettings) {
            events.append(.bookmarkClicked(id: bookmark.id.uuidString, openLabels: true, openNotes: addNote))
        }

        return BibleReaderBookmarkActionResult(
            events: events,
            updatedWorkspaceSettings: assignment?.updatedWorkspaceSettings,
            requiresPersistState: assignment?.changedWorkspaceSettings ?? false,
            refreshesConfig: assignment?.changedWorkspaceSettings ?? false
        )
    }

    /**
     Creates a Bible paragraph-break bookmark using the same KJVA storage projection as normal
     Bible bookmarks.

     - Parameters:
       - bookInitials: Module initials associated with the selected verse.
       - startOrdinal: Source-versification start ordinal reported by Vue.
       - endOrdinal: Source-versification end ordinal reported by Vue, or `0` for a single-verse
         paragraph marker.
     - Returns: Bridge update result containing the inserted paragraph-break bookmark payload.
     - Side effects: Inserts a Bible bookmark and attaches Android's paragraph-break system label.
     - Failure modes: Unresolvable KJVA projection returns `.noChange`; source ordinals are never
       persisted in the KJVA columns.
     */
    func addParagraphBreakBibleBookmark(
        bookInitials: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> BibleReaderBookmarkActionResult {
        let effectiveEndOrdinal = endOrdinal > 0 ? endOrdinal : startOrdinal
        let sourceStart = min(startOrdinal, effectiveEndOrdinal)
        let sourceEnd = max(startOrdinal, effectiveEndOrdinal)
        guard let storageRange = verifiedKJVAOrdinalRange(
            bookInitials,
            sourceStart,
            sourceEnd
        ) else {
            return .noChange
        }
        let bookmark = bookmarkService.addParagraphBreakBibleBookmark(
            ordinalRange: storageRange,
            book: currentBook
        )
        return BibleReaderBookmarkActionResult(
            events: [.bookmarksUpdated([payloadFactory.bookmarkJSONForStudyPad(bookmark)])],
            refreshesLabels: true
        )
    }

    /**
     Creates a generic paragraph-break bookmark.
     */
    func addGenericParagraphBreakBookmark(
        bookInitials: String,
        osisRef: String,
        startOrdinal: Int,
        endOrdinal: Int
    ) -> BibleReaderBookmarkActionResult {
        let bookmark = bookmarkService.addParagraphBreakGenericBookmark(
            bookInitials: bookInitials,
            key: osisRef,
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal
        )
        return BibleReaderBookmarkActionResult(
            events: [.genericBookmarksUpdated([payloadFactory.genericBookmarkJSONForStudyPad(bookmark)])],
            refreshesLabels: true
        )
    }

    /**
     Removes a Bible bookmark and emits the bridge delete event expected by BibleView.
     */
    func removeBookmark(_ bookmarkId: String) -> BibleReaderBookmarkActionResult {
        guard let uuid = UUID(uuidString: bookmarkId) else {
            return .noChange
        }
        bookmarkService.removeBibleBookmark(id: uuid)
        return BibleReaderBookmarkActionResult(
            incrementsMyNotesRevision: true,
            events: [.bookmarksDeleted([bookmarkId])]
        )
    }

    /// Removes a generic bookmark and emits Android's shared Vue deletion event.
    func removeGenericBookmark(_ bookmarkId: String) -> BibleReaderBookmarkActionResult {
        guard let uuid = UUID(uuidString: bookmarkId) else {
            return .noChange
        }
        bookmarkService.removeGenericBookmark(id: uuid)
        return BibleReaderBookmarkActionResult(events: [.bookmarksDeleted([bookmarkId])])
    }

    /**
     Saves, updates, or clears a bookmark note for Bible or generic bookmarks.
     */
    func saveBookmarkNote(bookmarkId: String, note: String?) -> BibleReaderBookmarkActionResult {
        guard let uuid = UUID(uuidString: bookmarkId) else {
            return .noChange
        }
        bookmarkService.saveBibleBookmarkNote(
            bookmarkId: uuid,
            note: note,
            defaultContentType: currentNotesContentType()
        )
        let bibleNote = bookmarkService.bibleBookmark(id: uuid)?.notes
        let genericNote = bookmarkService.genericBookmark(id: uuid)?.notes
        let savedNote = bibleNote?.notes ?? genericNote?.notes
        let notesContentType = bibleNote?.contentType ?? genericNote?.contentType
        return BibleReaderBookmarkActionResult(
            incrementsMyNotesRevision: true,
            events: [
                .bookmarkNoteModified(
                    BookmarkNoteModifiedPayload(
                        id: uuid.uuidString,
                        notes: savedNote ?? "",
                        notesContentType: notesContentType,
                        lastUpdatedOn: Int(Date().timeIntervalSince1970 * 1000)
                    )
                ),
            ]
        )
    }

    /**
     Toggles one label assignment on a Bible or generic bookmark.
     */
    func toggleBookmarkLabel(bookmarkId: String, labelId: String) -> BibleReaderBookmarkActionResult {
        guard let bookmarkUUID = UUID(uuidString: bookmarkId),
              let labelUUID = UUID(uuidString: labelId),
              let type = bookmarkService.toggleLabel(bookmarkId: bookmarkUUID, labelId: labelUUID),
              let event = bookmarkUpdateEvent(bookmarkId: bookmarkUUID, preferredType: type) else {
            return .noChange
        }
        return BibleReaderBookmarkActionResult(
            events: [event],
            refreshesLabels: true,
            recentLabelId: labelId
        )
    }

    /**
     Removes one label assignment from a Bible or generic bookmark.
     */
    func removeBookmarkLabel(bookmarkId: String, labelId: String) -> BibleReaderBookmarkActionResult {
        guard let bookmarkUUID = UUID(uuidString: bookmarkId),
              let labelUUID = UUID(uuidString: labelId) else {
            return .noChange
        }
        bookmarkService.removeLabel(bookmarkId: bookmarkUUID, labelId: labelUUID)
        guard let event = bookmarkUpdateEvent(bookmarkId: bookmarkUUID) else {
            return .noChange
        }
        return BibleReaderBookmarkActionResult(events: [event])
    }

    /**
     Sets the primary label for a Bible or generic bookmark.
     */
    func setPrimaryLabel(bookmarkId: String, labelId: String) -> BibleReaderBookmarkActionResult {
        guard let bookmarkUUID = UUID(uuidString: bookmarkId),
              let labelUUID = UUID(uuidString: labelId),
              labelUUID != Label.unlabeledId,
              bookmarkService.label(id: labelUUID) != nil else {
            return .noChange
        }
        bookmarkService.setPrimaryLabel(bookmarkId: bookmarkUUID, labelId: labelUUID)
        guard let event = bookmarkUpdateEvent(bookmarkId: bookmarkUUID) else {
            return .noChange
        }
        return BibleReaderBookmarkActionResult(events: [event], recentLabelId: labelId)
    }

    /**
     Updates whether a bookmark should render as whole-verse or text-range.
     */
    func setBookmarkWholeVerse(bookmarkId: String, value: Bool) -> BibleReaderBookmarkActionResult {
        guard let bookmarkUUID = UUID(uuidString: bookmarkId),
              bookmarkHasTextRangeIfNeeded(bookmarkId: bookmarkUUID, value: value) else {
            return .noChange
        }
        bookmarkService.setWholeVerse(bookmarkId: bookmarkUUID, value: value)
        guard let event = bookmarkUpdateEvent(bookmarkId: bookmarkUUID) else {
            return .noChange
        }
        return BibleReaderBookmarkActionResult(events: [event])
    }

    /**
     Updates the custom icon attached to a Bible or generic bookmark.
     */
    func setBookmarkCustomIcon(bookmarkId: String, value: String?) -> BibleReaderBookmarkActionResult {
        guard let bookmarkUUID = UUID(uuidString: bookmarkId) else {
            return .noChange
        }
        bookmarkService.setCustomIcon(bookmarkId: bookmarkUUID, value: value)
        guard let event = bookmarkUpdateEvent(bookmarkId: bookmarkUUID) else {
            return .noChange
        }
        return BibleReaderBookmarkActionResult(events: [event])
    }

    /**
     Persists an optional bookmark edit action configured in the web client.
     */
    func setBookmarkEditAction(bookmarkId: String, value: String) -> BibleReaderBookmarkActionResult {
        guard let bookmarkUUID = UUID(uuidString: bookmarkId) else {
            return .noChange
        }
        bookmarkService.setBookmarkEditAction(bookmarkId: bookmarkUUID, editAction: editAction(from: value))
        guard let event = bookmarkUpdateEvent(bookmarkId: bookmarkUUID) else {
            return .noChange
        }
        return BibleReaderBookmarkActionResult(events: [event])
    }

    private func applyAutoAssignPrimaryLabel(to bookmark: BibleBookmark, workspaceSettings: WorkspaceSettings?) {
        guard let labelId = workspaceSettings?.autoAssignPrimaryLabel,
              bookmarkService.label(id: labelId) != nil else {
            return
        }
        bookmark.primaryLabelId = labelId
    }

    private func applyAutoAssignPrimaryLabel(to bookmark: GenericBookmark, workspaceSettings: WorkspaceSettings?) {
        guard let labelId = workspaceSettings?.autoAssignPrimaryLabel,
              bookmarkService.label(id: labelId) != nil else {
            return
        }
        bookmark.primaryLabelId = labelId
    }

    private func shouldOpenBookmarkModal(
        isNew: Bool,
        addNote: Bool,
        workspaceSettings: WorkspaceSettings?
    ) -> Bool {
        addNote || (isNew && (workspaceSettings?.autoAssignLabels.isEmpty ?? true))
    }

    private func bookmarkUpdateEvent(
        bookmarkId: UUID,
        preferredType: String? = nil
    ) -> BibleReaderBookmarkActionEvent? {
        if preferredType != "generic", let bookmark = bookmarkService.bibleBookmark(id: bookmarkId) {
            return .bookmarksUpdated([payloadFactory.bookmarkJSONForStudyPad(bookmark)])
        }
        if let bookmark = bookmarkService.genericBookmark(id: bookmarkId) {
            return .genericBookmarksUpdated([payloadFactory.genericBookmarkJSONForStudyPad(bookmark)])
        }
        return nil
    }

    private func bookmarkHasTextRangeIfNeeded(bookmarkId: UUID, value: Bool) -> Bool {
        if value {
            return bookmarkService.bibleBookmark(id: bookmarkId) != nil
                || bookmarkService.genericBookmark(id: bookmarkId) != nil
        }
        if let bookmark = bookmarkService.bibleBookmark(id: bookmarkId) {
            return bookmark.startOffset != nil && bookmark.endOffset != nil
        }
        if let bookmark = bookmarkService.genericBookmark(id: bookmarkId) {
            return bookmark.startOffset != nil && bookmark.endOffset != nil
        }
        return false
    }

    private func editAction(from value: String) -> EditAction? {
        guard value != "null", !value.isEmpty else {
            return nil
        }
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let mode = (object["mode"] as? String).flatMap { EditActionMode(rawValue: $0) }
        return EditAction(mode: mode, content: object["content"] as? String)
    }
}

/**
 Result returned by bookmark action coordination.
 */
struct BibleReaderBookmarkActionResult {
    /// Whether the controller should advance the My Notes mutation revision for UI-test snapshots.
    let incrementsMyNotesRevision: Bool
    /// Ordered bridge events that should be emitted after the persistence mutation.
    let events: [BibleReaderBookmarkActionEvent]
    /// Updated workspace settings after Android-style StudyPad cursor movement.
    let updatedWorkspaceSettings: WorkspaceSettings?
    /// Whether the controller should persist workspace state after applying settings.
    let requiresPersistState: Bool
    /// Whether label payloads should be refreshed in Vue.js.
    let refreshesLabels: Bool
    /// Whether config payloads should be refreshed in Vue.js.
    let refreshesConfig: Bool
    /// Recently used label identifier to track in controller-owned app settings.
    let recentLabelId: String?

    /// Result used when malformed or stale bridge input produces no persistence or bridge effects.
    static let noChange = BibleReaderBookmarkActionResult(events: [])

    /**
     Creates a bookmark action result.
     */
    init(
        incrementsMyNotesRevision: Bool = false,
        events: [BibleReaderBookmarkActionEvent],
        updatedWorkspaceSettings: WorkspaceSettings? = nil,
        requiresPersistState: Bool = false,
        refreshesLabels: Bool = false,
        refreshesConfig: Bool = false,
        recentLabelId: String? = nil
    ) {
        self.incrementsMyNotesRevision = incrementsMyNotesRevision
        self.events = events
        self.updatedWorkspaceSettings = updatedWorkspaceSettings
        self.requiresPersistState = requiresPersistState
        self.refreshesLabels = refreshesLabels
        self.refreshesConfig = refreshesConfig
        self.recentLabelId = recentLabelId
    }
}

/**
 Bridge events produced by bookmark action coordination.
 */
enum BibleReaderBookmarkActionEvent {
    /// Emits Android's `add_or_update_bookmarks` payload for Bible bookmarks.
    case bookmarksUpdated([BibleBookmarkData])
    /// Emits Android's `add_or_update_bookmarks` payload for generic bookmarks.
    case genericBookmarksUpdated([GenericBookmarkData])
    /// Emits BibleView's `delete_bookmarks` payload after Bible bookmark deletion.
    case bookmarksDeleted([String])
    /// Emits BibleView's `bookmark_clicked` payload for modal opening.
    case bookmarkClicked(id: String, openLabels: Bool, openNotes: Bool)
    /// Emits BibleView's `bookmark_note_modified` payload after note persistence.
    case bookmarkNoteModified(BookmarkNoteModifiedPayload)
}

/**
 Payload emitted after bookmark note persistence.
 */
struct BookmarkNoteModifiedPayload: Encodable {
    /// Bookmark identifier.
    let id: String
    /// Persisted note text, or an empty string when the note row was deleted.
    let notes: String
    /// Persisted Android notes content type, or `nil` when no note row exists.
    let notesContentType: String?
    /// Client timestamp in integer milliseconds.
    let lastUpdatedOn: Int

    /// Bridge payload keys consumed by BibleView.
    private enum CodingKeys: String, CodingKey {
        case id
        case notes
        case notesContentType
        case lastUpdatedOn
    }

    /**
     Encodes nullable fields explicitly so Vue receives the same shape Android emits.
     */
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(notes, forKey: .notes)
        try container.encode(lastUpdatedOn, forKey: .lastUpdatedOn)
        if let notesContentType {
            try container.encode(notesContentType, forKey: .notesContentType)
        } else {
            try container.encodeNil(forKey: .notesContentType)
        }
    }
}
