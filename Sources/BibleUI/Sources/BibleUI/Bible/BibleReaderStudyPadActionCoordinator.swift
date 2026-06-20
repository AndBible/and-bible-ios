import Foundation
import BibleCore
import BibleView

/**
 Coordinates StudyPad bridge mutations and turns their persistence effects into Vue bridge events.

 `BibleReaderController` remains the `BibleBridgeDelegate` and still owns web-view emission,
 navigation state, logging, and UI-test revision counters. This coordinator owns the cohesive
 StudyPad action rules that Android keeps behind `BibleJavascriptInterface` plus
 `BookmarkControl`: parsing JavaScript payloads, mutating `BookmarkService`, and projecting only
 the Android event shapes that should be emitted afterward.

 Inputs:
 - string payloads received from the shared BibleView JavaScript bridge
 - bookmark persistence through `BookmarkService`
 - current notes content type for newly-created journal rows
 - annotation payload projection for StudyPad text and bookmark-to-label DTOs

 Outputs:
 - `BibleReaderStudyPadActionResult` values that describe whether the StudyPad accessibility
   revision should advance and which bridge events the controller should emit

 Side effects:
 - mutates StudyPad entries and bookmark-to-label relationships through `BookmarkService`

 Failure modes:
 - invalid identifiers, malformed JSON, missing labels, or missing relationships return
   `.noChange` without throwing so bridge calls remain tolerant of stale client state
 */
struct BibleReaderStudyPadActionCoordinator {
    /// Persistence facade used for every StudyPad action mutation.
    private let bookmarkService: BookmarkService
    /// Payload projector shared with document rendering so event DTOs stay in one bridge schema.
    private let payloadFactory: BibleReaderAnnotationPayloadFactory
    /// Supplies the active Android-compatible notes content type for newly-created journal rows.
    private let currentNotesContentType: () -> String

    /**
     Creates a coordinator for one reader controller.

     - Parameters:
       - bookmarkService: Persistence facade for bookmark, label, and StudyPad mutations.
       - payloadFactory: Factory that projects persisted models into typed Vue bridge DTOs.
       - currentNotesContentType: Closure returning the current notes-content-type preference for
         new journal rows.
     - Side effects: None during initialization.
     - Failure modes: None.
     */
    init(
        bookmarkService: BookmarkService,
        payloadFactory: BibleReaderAnnotationPayloadFactory,
        currentNotesContentType: @escaping () -> String
    ) {
        self.bookmarkService = bookmarkService
        self.payloadFactory = payloadFactory
        self.currentNotesContentType = currentNotesContentType
    }

    /**
     Creates a StudyPad journal row after the row referenced by JavaScript.

     Android resolves the `afterEntryId` order number by `entryType` and then inserts the new row
     at `afterOrder + 1`. iOS keeps the same valid-input behavior while returning `.noChange` for
     invalid or stale identifiers rather than crashing the app process.

     - Parameters:
       - labelId: UUID string for the StudyPad label.
       - entryType: Shared client row type (`bookmark`, `generic-bookmark`, `journal`, or `none`).
       - afterEntryId: UUID string for the referenced row, or an empty value for `none`.
     - Returns: A result containing one `add_or_update_study_pad` event when creation succeeds.
     - Side effects: Inserts a `StudyPadTextEntry`, creates its text row, and bumps affected order
       numbers through `BookmarkService`.
     - Failure modes: Returns `.noChange` when the label id is invalid or creation fails.
     */
    func createNewStudyPadEntry(
        labelId: String,
        entryType: String,
        afterEntryId: String
    ) -> BibleReaderStudyPadActionResult {
        guard let labelUUID = UUID(uuidString: labelId),
              let result = bookmarkService.createStudyPadEntry(
                labelId: labelUUID,
                afterOrderNumber: orderNumber(afterEntryId: afterEntryId, entryType: entryType, labelId: labelUUID),
                contentType: currentNotesContentType()
              )
        else {
            return .noChange
        }

        return .studyPadRevision(
            events: [
                .studyPadUpdated(
                    studyPadUpdatePayload(
                        newEntry: result.0,
                        changedBibleBtls: result.1,
                        changedGenericBtls: result.2,
                        changedEntries: result.3
                    )
                ),
            ]
        )
    }

    /**
     Deletes a StudyPad journal row and emits Android's delete-plus-reorder event sequence.

     - Parameter studyPadId: UUID string for the journal row to remove.
     - Returns: A result containing `delete_study_pad_text_entry` and any resulting
       `add_or_update_study_pad` reorder payload.
     - Side effects: Deletes the entry through `BookmarkService` and sanitizes remaining order
       numbers.
     - Failure modes: Returns `.noChange` when the identifier is invalid or the entry no longer
       exists.
     */
    func deleteStudyPadEntry(_ studyPadId: String) -> BibleReaderStudyPadActionResult {
        guard let uuid = UUID(uuidString: studyPadId),
              let result = bookmarkService.deleteStudyPadEntry(id: uuid)
        else {
            return .noChange
        }

        return .studyPadRevision(
            events: [
                .studyPadTextEntryDeleted(result.0),
                .studyPadUpdated(
                    studyPadUpdatePayload(
                        newEntry: nil,
                        changedBibleBtls: result.2,
                        changedGenericBtls: result.3,
                        changedEntries: result.4
                    )
                ),
            ]
        )
    }

    /**
     Updates non-text metadata for a StudyPad journal row.

     - Parameter data: JSON object from BibleView containing `id` plus optional `orderNumber` and
       `indentLevel` fields.
     - Returns: A StudyPad revision result with the updated row payload when the row exists.
     - Side effects: Mutates the entry metadata through `BookmarkService`.
     - Failure modes: Returns `.noChange` for malformed JSON, invalid UUIDs, or missing rows.
     */
    func updateStudyPadTextEntry(data: String) -> BibleReaderStudyPadActionResult {
        guard let payload = decodeStudyPadBridgePayload(StudyPadTextEntryMutationPayload.self, from: data) else {
            return .noChange
        }

        bookmarkService.updateStudyPadTextEntry(
            id: payload.id,
            orderNumber: payload.orderNumber,
            indentLevel: payload.indentLevel
        )

        guard let entry = bookmarkService.studyPadEntry(id: payload.id) else {
            return .noChange
        }

        return .studyPadRevision(events: [.studyPadUpdated(studyPadUpdatePayload(newEntry: entry))])
    }

    /**
     Updates the text payload for a StudyPad journal row.

     Android posts a `StudyPadOrderEvent` with the changed entry after this mutation; returning the
     same `add_or_update_study_pad` event keeps other web views and the active StudyPad map aligned
     with Android behavior.

     - Parameters:
       - id: UUID string for the journal row.
       - text: New serialized text content.
     - Returns: A StudyPad revision result with the updated row payload when the row exists.
     - Side effects: Upserts the detached StudyPad text row through `BookmarkService`.
     - Failure modes: Returns `.noChange` for invalid UUIDs or missing rows.
     */
    func updateStudyPadTextEntryText(id: String, text: String) -> BibleReaderStudyPadActionResult {
        guard let uuid = UUID(uuidString: id),
              bookmarkService.studyPadEntry(id: uuid) != nil else {
            return .noChange
        }

        bookmarkService.updateStudyPadTextEntryText(id: uuid, text: text)

        guard let entry = bookmarkService.studyPadEntry(id: uuid) else {
            return .noChange
        }

        return .studyPadRevision(events: [.studyPadUpdated(studyPadUpdatePayload(newEntry: entry))])
    }

    /**
     Applies drag/drop StudyPad ordering emitted by the shared BibleView client.

     Android parses the keys `bookmarks`, `genericBookmarks`, and `studyPadTextItems`; these names
     are intentionally used here rather than the older iOS-only names so iOS consumes the same
     client payload as Android.

     - Parameters:
       - labelId: UUID string for the StudyPad label being reordered.
       - data: JSON object containing Android order-pair arrays.
     - Returns: A StudyPad revision result with changed rows in Android's order-update event shape.
     - Side effects: Mutates order numbers for the referenced bookmark-to-label and journal rows.
     - Failure modes: Returns `.noChange` for malformed JSON or invalid label identifiers.
     */
    func updateOrderNumber(labelId: String, data: String) -> BibleReaderStudyPadActionResult {
        guard let labelUUID = UUID(uuidString: labelId),
              let payload = decodeStudyPadBridgePayload(StudyPadOrderMutationPayload.self, from: data)
        else {
            return .noChange
        }

        bookmarkService.updateOrderNumbers(
            labelId: labelUUID,
            bibleBookmarkOrders: payload.bookmarks.map { ($0.id, $0.orderNumber) },
            genericBookmarkOrders: payload.genericBookmarks.map { ($0.id, $0.orderNumber) },
            studyPadEntryOrders: payload.studyPadTextItems.map { ($0.id, $0.orderNumber) }
        )

        let bibleBtls = payload.bookmarks.compactMap {
            bookmarkService.bibleBookmarkToLabel(bookmarkId: $0.id, labelId: labelUUID)
        }
        let genericBtls = payload.genericBookmarks.compactMap {
            bookmarkService.genericBookmarkToLabel(bookmarkId: $0.id, labelId: labelUUID)
        }
        let entries = payload.studyPadTextItems.compactMap {
            bookmarkService.studyPadEntry(id: $0.id)
        }

        return .studyPadRevision(
            events: [
                .studyPadUpdated(
                    studyPadUpdatePayload(
                        newEntry: nil,
                        changedBibleBtls: bibleBtls,
                        changedGenericBtls: genericBtls,
                        changedEntries: entries
                    )
                ),
            ]
        )
    }

    /**
     Updates a Bible bookmark-to-label StudyPad relation from the shared client payload.

     - Parameter data: JSON object containing bookmark id, label id, and optional StudyPad relation
       metadata.
     - Returns: A relationship update event when the relation exists after mutation.
     - Side effects: Mutates relation metadata and bumps the bookmark timestamp through
       `BookmarkService`.
     - Failure modes: Returns `.noChange` for malformed JSON, invalid UUIDs, missing relations, or
       labels that can no longer be serialized.
     */
    func updateBookmarkToLabel(data: String) -> BibleReaderStudyPadActionResult {
        guard let payload = decodeStudyPadBridgePayload(BookmarkToLabelMutationPayload.self, from: data) else {
            return .noChange
        }

        bookmarkService.updateBibleBookmarkToLabel(
            bookmarkId: payload.bookmarkId,
            labelId: payload.labelId,
            orderNumber: payload.orderNumber,
            indentLevel: payload.indentLevel,
            expandContent: payload.expandContent
        )

        guard let relation = bookmarkService.bibleBookmarkToLabel(
            bookmarkId: payload.bookmarkId,
            labelId: payload.labelId
        ),
              let relationPayload = payloadFactory.bibleBookmarkToLabelJSON(relation) else {
            return .noChange
        }

        return BibleReaderStudyPadActionResult(events: [.bookmarkToLabelUpdated(relationPayload)])
    }

    /**
     Updates a generic bookmark-to-label StudyPad relation from the shared client payload.

     - Parameter data: JSON object containing bookmark id, label id, and optional StudyPad relation
       metadata.
     - Returns: A relationship update event when the relation exists after mutation.
     - Side effects: Mutates relation metadata and bumps the generic bookmark timestamp through
       `BookmarkService`.
     - Failure modes: Returns `.noChange` for malformed JSON, invalid UUIDs, missing relations, or
       labels that can no longer be serialized.
     */
    func updateGenericBookmarkToLabel(data: String) -> BibleReaderStudyPadActionResult {
        guard let payload = decodeStudyPadBridgePayload(BookmarkToLabelMutationPayload.self, from: data) else {
            return .noChange
        }

        bookmarkService.updateGenericBookmarkToLabel(
            bookmarkId: payload.bookmarkId,
            labelId: payload.labelId,
            orderNumber: payload.orderNumber,
            indentLevel: payload.indentLevel,
            expandContent: payload.expandContent
        )

        guard let relation = bookmarkService.genericBookmarkToLabel(
            bookmarkId: payload.bookmarkId,
            labelId: payload.labelId
        ),
              let relationPayload = payloadFactory.genericBookmarkToLabelJSON(relation) else {
            return .noChange
        }

        return BibleReaderStudyPadActionResult(events: [.bookmarkToLabelUpdated(relationPayload)])
    }

    /**
     Resolves the order number after which a new journal row should be inserted.

     - Parameters:
       - afterEntryId: UUID string for the referenced row.
       - entryType: Shared client row type.
       - labelId: Parsed label id that scopes bookmark-to-label lookups.
     - Returns: The referenced row order number, or `-1` for `none`, invalid ids, stale rows, or
       unknown row types.
     - Side effects: Reads persisted StudyPad relations and entries.
     - Failure modes: Cannot throw; stale inputs fall back to beginning insertion for bridge
       tolerance.
     */
    private func orderNumber(afterEntryId: String, entryType: String, labelId: UUID) -> Int {
        guard let afterUUID = UUID(uuidString: afterEntryId) else {
            return -1
        }

        switch entryType {
        case "bookmark":
            return bookmarkService.bibleBookmarkToLabel(bookmarkId: afterUUID, labelId: labelId)?.orderNumber ?? -1
        case "generic-bookmark":
            return bookmarkService.genericBookmarkToLabel(bookmarkId: afterUUID, labelId: labelId)?.orderNumber ?? -1
        case "journal":
            return bookmarkService.studyPadEntry(id: afterUUID)?.orderNumber ?? -1
        default:
            return -1
        }
    }

    /**
     Builds the StudyPad update event payload used by Android's `StudyPadOrderEvent` bridge path.

     - Parameters:
       - newEntry: Newly created or updated journal row, if any.
       - changedBibleBtls: Bible bookmark-to-label rows whose order metadata changed.
       - changedGenericBtls: Generic bookmark-to-label rows whose order metadata changed.
       - changedEntries: Journal rows whose order metadata changed.
     - Returns: Typed bridge event payload with explicit `nil` for absent `studyPadTextEntry`.
     - Side effects: Projects persisted rows into bridge DTOs; projection may read active module
       state supplied to the payload factory.
     - Failure modes: Deleted label relationships are filtered out by the payload factory.
     */
    private func studyPadUpdatePayload(
        newEntry: StudyPadTextEntry?,
        changedBibleBtls: [BibleBookmarkToLabel] = [],
        changedGenericBtls: [GenericBookmarkToLabel] = [],
        changedEntries: [StudyPadTextEntry] = []
    ) -> StudyPadUpdatePayload {
        StudyPadUpdatePayload(
            studyPadTextEntry: newEntry.map { payloadFactory.studyPadEntryJSON($0) },
            bookmarkToLabelsOrdered: changedBibleBtls.compactMap { payloadFactory.bibleBookmarkToLabelJSON($0) },
            genericBookmarkToLabelsOrdered: changedGenericBtls.compactMap {
                payloadFactory.genericBookmarkToLabelJSON($0)
            },
            studyPadItemsOrdered: changedEntries.map { payloadFactory.studyPadEntryJSON($0) }
        )
    }

    /**
     Decodes a UTF-8 JSON bridge payload into a typed mutation request.

     - Parameters:
       - type: Decodable request type expected for the bridge action.
       - data: Raw JSON string from BibleView.
     - Returns: Decoded payload, or `nil` when the JSON is malformed.
     - Side effects: None.
     - Failure modes: Decode failures are intentionally swallowed so stale web clients cannot crash
       the native bridge.
     */
    private func decodeStudyPadBridgePayload<T: Decodable>(_ type: T.Type, from data: String) -> T? {
        guard let jsonData = data.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: jsonData)
    }
}

/**
 Result returned by StudyPad action coordination.

 The controller uses this value to apply native revision bookkeeping separately from the
 persistence/action logic, and then emits each event into its currently active bridge.
 */
struct BibleReaderStudyPadActionResult {
    /// Whether the controller should advance the StudyPad mutation revision for UI-test snapshots.
    let incrementsStudyPadRevision: Bool
    /// Ordered bridge events that should be emitted after the persistence mutation.
    let events: [BibleReaderStudyPadActionEvent]

    /// Result used when malformed or stale bridge input produces no persistence or bridge effects.
    static let noChange = BibleReaderStudyPadActionResult(events: [])

    /**
     Creates an action result.

     - Parameters:
       - incrementsStudyPadRevision: Whether native StudyPad revision state should advance.
       - events: Ordered bridge events to emit.
     - Side effects: None.
     - Failure modes: None.
     */
    init(
        incrementsStudyPadRevision: Bool = false,
        events: [BibleReaderStudyPadActionEvent]
    ) {
        self.incrementsStudyPadRevision = incrementsStudyPadRevision
        self.events = events
    }

    /**
     Creates a result for mutations that affect StudyPad journal/order state.

     - Parameter events: Ordered bridge events to emit after the mutation.
     - Returns: Result with StudyPad revision bookkeeping enabled.
     - Side effects: None.
     - Failure modes: None.
     */
    static func studyPadRevision(
        events: [BibleReaderStudyPadActionEvent]
    ) -> BibleReaderStudyPadActionResult {
        BibleReaderStudyPadActionResult(incrementsStudyPadRevision: true, events: events)
    }
}

/**
 Bridge events produced by StudyPad action coordination.
 */
enum BibleReaderStudyPadActionEvent {
    /// Emits Android's `add_or_update_study_pad` payload after journal/order changes.
    case studyPadUpdated(StudyPadUpdatePayload)
    /// Emits Android's `delete_study_pad_text_entry` payload after journal deletion.
    case studyPadTextEntryDeleted(UUID)
    /// Emits Android's `add_or_update_bookmark_to_label` payload after relation metadata edits.
    case bookmarkToLabelUpdated(BookmarkToLabelData)
}

/**
 Decodable payload for StudyPad text entry metadata updates.
 */
private struct StudyPadTextEntryMutationPayload: Decodable {
    /// Journal row identifier.
    let id: UUID
    /// Optional updated StudyPad order number.
    let orderNumber: Int?
    /// Optional updated StudyPad indentation level.
    let indentLevel: Int?
}

/**
 Decodable Android/shared-client StudyPad reorder payload.
 */
private struct StudyPadOrderMutationPayload: Decodable {
    /// Bible bookmark order pairs emitted by BibleView as `bookmarks`.
    let bookmarks: [StudyPadOrderPair]
    /// Generic bookmark order pairs emitted by BibleView as `genericBookmarks`.
    let genericBookmarks: [StudyPadOrderPair]
    /// Journal row order pairs emitted by BibleView as `studyPadTextItems`.
    let studyPadTextItems: [StudyPadOrderPair]

    /// Coding keys matching the shared BibleView payload consumed by Android.
    private enum CodingKeys: String, CodingKey {
        case bookmarks
        case genericBookmarks
        case studyPadTextItems
    }

    /**
     Decodes Android reorder arrays, defaulting missing arrays to empty for stale-client tolerance.
     */
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookmarks = try container.decodeIfPresent([StudyPadOrderPair].self, forKey: .bookmarks) ?? []
        genericBookmarks = try container.decodeIfPresent([StudyPadOrderPair].self, forKey: .genericBookmarks) ?? []
        studyPadTextItems = try container.decodeIfPresent([StudyPadOrderPair].self, forKey: .studyPadTextItems) ?? []
    }
}

/**
 Decodable `{first, second}` order pair emitted by the shared BibleView StudyPad client.
 */
private struct StudyPadOrderPair: Decodable {
    /// Entity identifier stored in the JavaScript `first` field.
    let id: UUID
    /// Updated order number stored in the JavaScript `second` field.
    let orderNumber: Int

    /**
     Decodes Android's pair-object shape into named Swift fields.
     */
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .first)
        orderNumber = try container.decode(Int.self, forKey: .second)
    }

    /// Coding keys matching Android's Kotlin `Pair<String, Int>` JSON object.
    private enum CodingKeys: String, CodingKey {
        case first
        case second
    }
}

/**
 Decodable payload for bookmark-to-label StudyPad metadata updates.
 */
private struct BookmarkToLabelMutationPayload: Decodable {
    /// Bookmark identifier for the relationship row.
    let bookmarkId: UUID
    /// Label identifier for the relationship row.
    let labelId: UUID
    /// Optional updated StudyPad order number.
    let orderNumber: Int?
    /// Optional updated StudyPad indentation level.
    let indentLevel: Int?
    /// Optional updated expansion state for nested content.
    let expandContent: Bool?
}
