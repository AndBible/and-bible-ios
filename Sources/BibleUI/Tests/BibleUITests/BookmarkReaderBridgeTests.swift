import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
@testable import BibleView
@testable import SwordKit

/**
 Package-lane coverage for bookmark, note, and StudyPad reader bridge contracts owned by BibleUI.

 The suite exercises Android-compatible bridge payloads, label-assignment routing, StudyPad
 action events, bookmark-list reference text, and reader accessibility snapshots without the
 app-host XCTest bundle. It still uses the bundled SWORD fixture when payloads need real JSword
 ordinal and verse-range behavior.
 */
final class BookmarkReaderBridgeTests: BibleUISwordFixtureTestCase {

    /**
     Verifies that bridge hash-code normalization preserves the existing non-negative StudyPad DOM
     key contract without trapping on Swift's one unrepresentable absolute value.
     *
     * Setup:
     * - calls the pure annotation payload helper directly with representative positive, negative,
     *   zero, and `Int.min` values because `String.hashValue` is process-randomized and cannot
     *   deterministically produce the overflow edge.
     *
     * Expected result:
     * - ordinary values match the previous `abs(hashValue)` semantics
     * - `Int.min` maps to a non-negative sentinel instead of crashing
     *
     * Failure meaning:
     * - StudyPad/bookmark bridge payloads could either drift from their existing hash semantics or
     *   still crash while building Vue DOM identifiers for a rare hash value.
     *
     * Side effects: None.
     */
    func testBridgeHashCodeNormalizationAvoidsIntMinOverflow() {
        XCTAssertEqual(BibleReaderAnnotationPayloadFactory.normalizedBridgeHashCode(from: 12), 12)
        XCTAssertEqual(BibleReaderAnnotationPayloadFactory.normalizedBridgeHashCode(from: -12), 12)
        XCTAssertEqual(BibleReaderAnnotationPayloadFactory.normalizedBridgeHashCode(from: 0), 0)
        XCTAssertEqual(
            BibleReaderAnnotationPayloadFactory.normalizedBridgeHashCode(from: Int.min),
            Int.max
        )
    }

    /**
     Verifies that bookmark-label serialization falls back to the synthetic unlabeled payload when
     a relationship still points at a deleted in-memory label object.
     *
     * Data dependencies:
     * - creates an in-memory bookmark schema with one Bible bookmark, one label, and one junction
     *   row
     *
     * Side effects:
     * - inserts and saves live bookmark data
     * - deletes the label in the same `ModelContext` without first detaching the junction row so
     *   the helper sees the stale relationship shape that previously crashed the reader
     *
     * Failure modes:
     * - throws if the in-memory SwiftData container cannot be created or saved
     * - fails if serialization no longer produces an unlabeled fallback for the deleted relation
     */
    func testBookmarkLabelSerializationSkipsDeletedBibleLabels() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)

        let label = Label(name: "Temp")
        let bookmark = BibleBookmark(
            kjvOrdinalStart: 1,
            kjvOrdinalEnd: 1,
            ordinalStart: 1,
            ordinalEnd: 1,
            v11n: "KJVA"
        )
        bookmark.primaryLabelId = label.id

        let link = BibleBookmarkToLabel(orderNumber: 3, indentLevel: 1, expandContent: true)
        link.bookmark = bookmark
        link.label = label
        bookmark.bookmarkToLabels = [link]

        modelContext.insert(label)
        modelContext.insert(bookmark)
        modelContext.insert(link)
        try modelContext.save()

        modelContext.delete(label)

        let payload = BookmarkLabelSerializationSupport.biblePayload(
            bookmarkID: bookmark.id,
            links: bookmark.bookmarkToLabels,
            unlabeledLabelID: "UNLABELED"
        )

        XCTAssertEqual(payload.labelIDs, ["UNLABELED"])
        XCTAssertEqual(payload.relationItems.count, 1)
        XCTAssertEqual(payload.relationItems.first?.labelId, "UNLABELED")
        XCTAssertEqual(payload.relationItems.first?.type, "BibleBookmarkToLabel")
        XCTAssertEqual(
            BookmarkLabelSerializationSupport.primaryLabelID(
                primaryLabelID: bookmark.primaryLabelId,
                validLabelIDs: payload.labelIDs
            ),
            nil
        )
    }

    /**
     Verifies bookmark-list range text keeps JSword's same-chapter shorthand.
     *
     Android reconstructs a JSword `VerseRange` from stored ordinals and displays the range name.
     For a range within one chapter, JSword emits `Book chapter:start-end`, so the iOS bookmark
     list should not expand the repeated chapter or collapse a real multi-verse range.
     */
    func testBookmarkListVerseReferenceFormatsSameChapterRangeLikeJSword() {
        let bookmark = BibleBookmark(
            kjvOrdinalStart: 5,
            kjvOrdinalEnd: 7,
            ordinalStart: 5,
            ordinalEnd: 7,
            v11n: "KJVA"
        )
        bookmark.book = "Genesis"

        let reference = BookmarkListView.verseReference(for: bookmark) { _, ordinal in
            [
                5: BookmarkListVerseReference(chapter: 1, verse: 5),
                7: BookmarkListVerseReference(chapter: 1, verse: 7),
            ][ordinal]
        }

        XCTAssertEqual(reference, "Genesis 1:5-7")
    }

    /**
     Verifies bookmark-list range text preserves the end chapter when a stored ordinal range crosses
     a chapter boundary.
     *
     JSword `VerseRange` names same-book cross-chapter ranges as `Book startChapter:startVerse-
     endChapter:endVerse`. A failure here means two different ranges such as `Genesis 1:5-2:5` and
     `Genesis 1:5` can be rendered ambiguously or collapsed in the iOS bookmark list.
     */
    func testBookmarkListVerseReferenceKeepsCrossChapterEndChapterLikeJSword() {
        let bookmark = BibleBookmark(
            kjvOrdinalStart: 5,
            kjvOrdinalEnd: 45,
            ordinalStart: 5,
            ordinalEnd: 45,
            v11n: "KJVA"
        )
        bookmark.book = "Genesis"

        let reference = BookmarkListView.verseReference(for: bookmark) { _, ordinal in
            [
                5: BookmarkListVerseReference(chapter: 1, verse: 5),
                45: BookmarkListVerseReference(chapter: 2, verse: 5),
            ][ordinal]
        }

        XCTAssertEqual(reference, "Genesis 1:5-2:5")
    }

    /**
     Verifies the reader WebView bridge hands label assignment to native reader-owned routing.

     Android opens `ManageLabels.Mode.ASSIGN` from `BibleView.assignLabels` rather than letting the
     web document own label assignment. iOS mirrors that by translating the WebView `assignLabels`
     bridge call into `BibleReaderController.onAssignLabels`, which the SwiftUI reader coordinator
     presents as the app-owned label assignment route.

     Expected result:
     - a valid bookmark UUID is forwarded exactly once to the native assignment callback
     - malformed bookmark identifiers are ignored without presenting a stale route

     Failure meaning:
     - reader-origin bookmark label editing has drifted back toward WebView-owned or invalid native
     routing instead of Android's app-owned assignment flow.
     */
    @MainActor
    func testReaderAssignLabelsBridgeRequestsNativeLabelAssignment() {
        let bookmarkId = UUID(uuidString: "10000000-0000-0000-0000-000000000246")!
        let controller = BibleReaderController(bridge: BibleBridge())
        var requestedBookmarkIds: [UUID] = []
        controller.onAssignLabels = { requestedBookmarkIds.append($0) }

        controller.bridge(BibleBridge(), assignLabels: "not-a-uuid")
        controller.bridge(BibleBridge(), assignLabels: bookmarkId.uuidString)

        XCTAssertEqual(requestedBookmarkIds, [bookmarkId])
    }

    /**
     Verifies that a Bible bookmark update emits the typed Vue bookmark payload shape used by Android.
     *
     * Setup:
     * - creates an in-memory Bible bookmark with a note
     * - refreshes it through the reader bridge instead of calling the payload factory directly
     *
     * Expected result:
     * - timestamp fields remain integer JSON values
     * - optional Android/Vue DTO fields are present as explicit `null` values
     * - label relationships and note content are encoded with the same keys consumed by the web client
     *
     * Failure meaning:
     * - the native bookmark bridge has drifted from the Android-compatible Vue payload contract even
     *   though storage still contains a valid bookmark.
     */
    @MainActor
    func testReaderBookmarkBridgeUpdateEmitsTypedPayloadShape() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        let controller = BibleReaderController(bridge: bridge)
        controller.bookmarkService = bookmarkService

        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            wholeVerse: true
        )
        bookmark.book = "Genesis"
        bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "Quoted \"note\"\nsecond line")

        controller.refreshBookmarkInVueJS(bookmarkId: bookmark.id)

        let payloadJSON = try bridgeEmissionPayloadJSON(
            from: recordedScripts(),
            event: "add_or_update_bookmarks"
        )
        assertBridgeJSONIntegerField("createdAt", in: payloadJSON)
        assertBridgeJSONIntegerField("lastUpdatedOn", in: payloadJSON)

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_or_update_bookmarks") as? [[String: Any]]
        )
        let bookmarkObject = try XCTUnwrap(payload.first)
        XCTAssertEqual(bookmarkObject["type"] as? String, "bookmark")
        XCTAssertEqual(bookmarkObject["notes"] as? String, "Quoted \"note\"\nsecond line")
        XCTAssertEqual(bookmarkObject["notesContentType"] as? String, "HTML")
        XCTAssertEqual(bookmarkObject["hasNote"] as? Bool, true)
        XCTAssertTrue(bookmarkObject["offsetRange"] is NSNull)
        XCTAssertTrue(bookmarkObject["primaryLabelId"] is NSNull)
        XCTAssertTrue(bookmarkObject["customIcon"] is NSNull)
        XCTAssertTrue(bookmarkObject["osisFragment"] is NSNull)
        XCTAssertEqual(bookmarkObject["labels"] as? [String], [Label.unlabeledId.uuidString])

        let editAction = try XCTUnwrap(bookmarkObject["editAction"] as? [String: Any])
        XCTAssertTrue(editAction["mode"] is NSNull)
        XCTAssertTrue(editAction["content"] is NSNull)

        let relations = try XCTUnwrap(bookmarkObject["bookmarkToLabels"] as? [[String: Any]])
        let relation = try XCTUnwrap(relations.first)
        XCTAssertEqual(relation["type"] as? String, "BibleBookmarkToLabel")
        XCTAssertEqual(relation["bookmarkId"] as? String, bookmark.id.uuidString)
        XCTAssertEqual(relation["labelId"] as? String, Label.unlabeledId.uuidString)
    }

    /**
     Verifies My Notes requests made before the Vue client is ready replay after client-ready.

     Android's `ChooseDocument` can select the My Notes fake document while the reader surface is
     still bootstrapping. iOS must preserve that visible document intent instead of dropping the tap
     at `clientReady == false`, then emit the same notes payload and pending row jump once Vue is
     able to receive bridge events.
     */
    @MainActor
    func testReaderMyNotesDocumentRequestedBeforeClientReadyReplaysAfterClientReady() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bookmarkService = bookmarkService
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let startOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 1))

        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: startOrdinal,
            endOrdinal: startOrdinal,
            wholeVerse: true
        )
        bookmark.book = "Genesis"
        bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "Replay note")

        controller.loadMyNotesDocument(jumpToOrdinal: 1)

        XCTAssertFalse(recordedScripts().contains { $0.contains("emit('add_documents'") })
        XCTAssertTrue(controller.myNotesAccessibilityState.contains("myNotesVisible=true"))

        controller.bridgeDidSetClientReady(bridge)

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_documents") as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "notes")
        let bookmarks = try XCTUnwrap(payload["bookmarks"] as? [[String: Any]])
        let bookmarkObject = try XCTUnwrap(bookmarks.first)
        XCTAssertEqual(bookmarkObject["notes"] as? String, "Replay note")

        let setupPayload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "setup_content") as? [String: Any]
        )
        XCTAssertEqual(setupPayload["jumpToOrdinal"] as? Int, 1)
    }

    /**
     Verifies native reader label assignment refreshes generic bookmarks as well as Bible
     bookmarks.

     Android's bookmark bridge event model emits both Bible and generic bookmark payloads through
     the same `add_or_update_bookmarks` event. iOS label assignment supports `GenericBookmark`
     records too, so the reader refresh path must not silently drop generic bookmark updates after
     the native label editor dismisses.

     Failure meaning:
     - the reader label-assignment refresh path only supports Bible bookmarks and leaves generic
       bookmark rows stale in Vue after native label edits.
     */
    @MainActor
    func testReaderBookmarkBridgeRefreshEmitsGenericBookmarkPayload() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        let controller = BibleReaderController(bridge: bridge)
        controller.bookmarkService = bookmarkService

        let bookmark = bookmarkService.addGenericBookmark(
            bookInitials: "MHC",
            key: "Gen.1.1",
            startOrdinal: 1,
            endOrdinal: 1
        )
        bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "Generic note")

        controller.refreshBookmarkInVueJS(bookmarkId: bookmark.id)

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_or_update_bookmarks") as? [[String: Any]]
        )
        let bookmarkObject = try XCTUnwrap(payload.first)
        XCTAssertEqual(bookmarkObject["type"] as? String, "generic-bookmark")
        XCTAssertEqual(bookmarkObject["bookInitials"] as? String, "MHC")
        XCTAssertEqual(bookmarkObject["key"] as? String, "Gen.1.1")
        XCTAssertEqual(bookmarkObject["notes"] as? String, "Generic note")
    }

    /**
     Verifies bookmark bridge payloads derive range fields from the same ordinal-backed
     JSword-style verse range Android serializes through `ClientBibleBookmark`.
     *
     Data dependencies:
     * - copies the bundled KJV SWORD module into a temporary module path
     * - creates one Bible bookmark that spans Genesis 1:31 through Genesis 2:2
     *
     * Failure modes:
     * - throws if bundled KJV cannot be loaded or its ordinals cannot be resolved
     * - fails if iOS collapses cross-chapter ranges to the start chapter, emits a non-JSword OSIS
     *   ref, or omits verse text from the end chapter
     */
    @MainActor
    func testReaderBookmarkBridgeUpdateEmitsJSwordCrossChapterRangePayload() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bookmarkService = bookmarkService
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let startOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 31))
        let endOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 2))

        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            wholeVerse: true
        )
        bookmark.book = "Genesis"

        controller.refreshBookmarkInVueJS(bookmarkId: bookmark.id)

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_or_update_bookmarks") as? [[String: Any]]
        )
        let bookmarkObject = try XCTUnwrap(payload.first)
        XCTAssertEqual(bookmarkObject["osisRef"] as? String, "Gen.1.31-Gen.2.2")
        XCTAssertEqual(bookmarkObject["verseRange"] as? String, "Genesis 1:31-2:2")
        XCTAssertEqual(bookmarkObject["verseRangeOnlyNumber"] as? String, "31-2")
        XCTAssertEqual(bookmarkObject["verseRangeAbbreviated"] as? String, "Gen 1:31-2:2")

        let fullText = try XCTUnwrap(bookmarkObject["fullText"] as? String)
        XCTAssertTrue(
            fullText.contains("the heavens and the earth were finished"),
            "Expected bridge payload text to include Genesis 2:1 content; got: \(fullText)"
        )
    }

    /**
     Verifies StudyPad bookmark payloads use the same JSword-style cross-chapter range projection
     as live bookmark update events.
     *
     Android serializes Study Pad bookmarks through the same `ClientBibleBookmark` DTO as bookmark
     update events. A failure means iOS has reintroduced drift between equivalent bridge payloads.
     */
    @MainActor
    func testReaderStudyPadDocumentBridgeEmissionUsesJSwordCrossChapterRangePayload() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let modulePath = try makeTemporaryBundledSwordPath()
        let manager = try XCTUnwrap(SwordManager(modulePath: modulePath))
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        let controller = BibleReaderController(bridge: bridge, swordManagerOverride: manager)
        controller.bookmarkService = bookmarkService
        let module = try XCTUnwrap(manager.module(named: controller.activeModuleName))
        let startOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 1, verse: 31))
        let endOrdinal = try XCTUnwrap(module.verseOrdinal(osisBookId: "Gen", chapter: 2, verse: 2))

        let label = bookmarkService.createLabel(name: "Cross Chapter", color: Label.defaultColor)
        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: startOrdinal,
            endOrdinal: endOrdinal,
            wholeVerse: true
        )
        bookmark.book = "Genesis"
        _ = bookmarkService.toggleLabel(bookmarkId: bookmark.id, labelId: label.id)

        controller.bridgeDidSetClientReady(bridge)
        let scriptCount = recordedScripts().count
        controller.loadStudyPadDocument(labelId: label.id, bookmarkId: bookmark.id)
        let studyPadScripts = Array(recordedScripts().dropFirst(scriptCount))

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: studyPadScripts, event: "add_documents") as? [String: Any]
        )
        let bookmarks = try XCTUnwrap(payload["bookmarks"] as? [[String: Any]])
        let bookmarkObject = try XCTUnwrap(bookmarks.first)
        XCTAssertEqual(bookmarkObject["osisRef"] as? String, "Gen.1.31-Gen.2.2")
        XCTAssertEqual(bookmarkObject["verseRange"] as? String, "Genesis 1:31-2:2")
        XCTAssertEqual(bookmarkObject["verseRangeOnlyNumber"] as? String, "31-2")
        XCTAssertEqual(bookmarkObject["verseRangeAbbreviated"] as? String, "Gen 1:31-2:2")

        let fullText = try XCTUnwrap(bookmarkObject["fullText"] as? String)
        XCTAssertTrue(
            fullText.contains("the heavens and the earth were finished"),
            "Expected StudyPad bridge payload text to include Genesis 2:1 content; got: \(fullText)"
        )
    }

    /**
     Verifies that StudyPad document bridge events retain the nested Android/Vue payload structure.
     *
     * Setup:
     * - creates a label with a Bible bookmark, a generic bookmark note, and a text entry
     * - loads the StudyPad document through the reader bridge after Vue client readiness
     *
     * Expected result:
     * - the emitted journal document contains label metadata, Bible bookmarks, generic bookmarks,
     *   bookmark-label relationships, text entries, and integer timestamp fields under their Android
     *   bridge keys
     *
     * Failure meaning:
     * - StudyPad rendering may still work locally, but the native-to-Vue contract no longer matches
     *   the Android-compatible object graph expected by the shared web client.
     */
    @MainActor
    func testReaderStudyPadDocumentBridgeEmissionUsesTypedNestedPayloads() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        let controller = BibleReaderController(bridge: bridge)
        controller.bookmarkService = bookmarkService

        let label = bookmarkService.createLabel(name: "Study \"Notes\"", color: Label.defaultColor)
        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            wholeVerse: true
        )
        bookmark.book = "Genesis"
        _ = bookmarkService.toggleLabel(bookmarkId: bookmark.id, labelId: label.id)
        let genericBookmark = bookmarkService.addGenericBookmark(
            bookInitials: "DICT",
            key: "entry-key",
            startOrdinal: 2,
            endOrdinal: 2
        )
        _ = bookmarkService.toggleLabel(bookmarkId: genericBookmark.id, labelId: label.id)
        bookmarkService.saveBibleBookmarkNote(bookmarkId: genericBookmark.id, note: "Generic \"note\"")
        let createdEntry = try XCTUnwrap(
            bookmarkService.createStudyPadEntry(labelId: label.id, afterOrderNumber: -1)
        ).0
        bookmarkService.updateStudyPadTextEntryText(id: createdEntry.id, text: "Entry with \"quotes\"\nand newline")

        controller.bridgeDidSetClientReady(bridge)
        let scriptCount = recordedScripts().count
        controller.loadStudyPadDocument(labelId: label.id, bookmarkId: bookmark.id)
        let studyPadScripts = Array(recordedScripts().dropFirst(scriptCount))

        let payloadJSON = try bridgeEmissionPayloadJSON(
            from: studyPadScripts,
            event: "add_documents"
        )
        assertBridgeJSONIntegerField("createdAt", in: payloadJSON)
        assertBridgeJSONIntegerField("lastUpdatedOn", in: payloadJSON)

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(
                from: studyPadScripts,
                event: "add_documents"
            ) as? [String: Any]
        )
        XCTAssertEqual(payload["type"] as? String, "journal")
        XCTAssertFalse(controller.allowsHorizontalDocumentNavigation)

        let labelObject = try XCTUnwrap(payload["label"] as? [String: Any])
        XCTAssertEqual(labelObject["name"] as? String, "Study \"Notes\"")
        let labelStyle = try XCTUnwrap(labelObject["style"] as? [String: Any])
        XCTAssertTrue(labelStyle["customIcon"] is NSNull)

        let bookmarks = try XCTUnwrap(payload["bookmarks"] as? [[String: Any]])
        let bookmarkObject = try XCTUnwrap(bookmarks.first)
        XCTAssertEqual(bookmarkObject["id"] as? String, bookmark.id.uuidString)
        XCTAssertTrue(bookmarkObject["primaryLabelId"] is NSNull)

        let genericBookmarks = try XCTUnwrap(payload["genericBookmarks"] as? [[String: Any]])
        let genericBookmarkObject = try XCTUnwrap(genericBookmarks.first)
        XCTAssertEqual(genericBookmarkObject["id"] as? String, genericBookmark.id.uuidString)
        XCTAssertEqual(genericBookmarkObject["type"] as? String, "generic-bookmark")
        XCTAssertEqual(genericBookmarkObject["notes"] as? String, "Generic \"note\"")
        XCTAssertEqual(genericBookmarkObject["notesContentType"] as? String, "HTML")
        XCTAssertTrue(genericBookmarkObject["primaryLabelId"] is NSNull)

        let relationships = try XCTUnwrap(payload["bookmarkToLabels"] as? [[String: Any]])
        let relationship = try XCTUnwrap(relationships.first)
        XCTAssertEqual(relationship["type"] as? String, "BibleBookmarkToLabel")
        XCTAssertEqual(relationship["labelId"] as? String, label.id.uuidString)

        let entries = try XCTUnwrap(payload["journalTextEntries"] as? [[String: Any]])
        let entryObject = try XCTUnwrap(entries.first)
        XCTAssertEqual(entryObject["id"] as? String, createdEntry.id.uuidString)
        XCTAssertEqual(entryObject["text"] as? String, "Entry with \"quotes\"\nand newline")
        XCTAssertEqual(entryObject["contentType"] as? String, "HTML")
    }

    /**
     Verifies the extracted StudyPad bridge action boundary creates a new journal row using
     Android's `BibleJavascriptInterface.createNewStudyPadEntry` insertion semantics.
     *
     * Setup:
     * - creates one label and one Bible bookmark-to-label row in an in-memory bookmark store
     * - sets the referenced bookmark row to order `3`, matching Android's lookup of the row after
     *   which the new StudyPad entry should be inserted
     *
     * Expected result:
     * - the coordinator inserts the new journal at order `4`
     * - the emitted `add_or_update_study_pad` payload carries the new journal and no unrelated
     *   reorder arrays
     *
     * Failure meaning:
     * - iOS either diverged from Android's bridge insertion rule or the refactor moved bridge event
     *   construction into a broad refresh shortcut instead of preserving the event contract.
     */
    func testStudyPadActionCoordinatorCreatesEntryAfterBibleBookmarkLikeAndroidBridge() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let label = bookmarkService.createLabel(name: "Study", color: Label.defaultColor)
        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            wholeVerse: true
        )
        _ = bookmarkService.toggleLabel(bookmarkId: bookmark.id, labelId: label.id)
        bookmarkService.updateBibleBookmarkToLabel(
            bookmarkId: bookmark.id,
            labelId: label.id,
            orderNumber: 3,
            indentLevel: 1,
            expandContent: true
        )
        let coordinator = makeStudyPadActionCoordinator(
            bookmarkService: bookmarkService,
            notesContentType: "MARKDOWN"
        )

        let result = coordinator.createNewStudyPadEntry(
            labelId: label.id.uuidString,
            entryType: "bookmark",
            afterEntryId: bookmark.id.uuidString
        )

        XCTAssertTrue(result.incrementsStudyPadRevision)
        XCTAssertEqual(result.events.count, 1)
        guard case .studyPadUpdated(let payload) = try XCTUnwrap(result.events.first) else {
            return XCTFail("Expected add_or_update_study_pad event")
        }
        let entry = try XCTUnwrap(payload.studyPadTextEntry)
        XCTAssertEqual(entry.type, "journal")
        XCTAssertEqual(entry.labelId, label.id.uuidString)
        XCTAssertEqual(entry.orderNumber, 4)
        XCTAssertEqual(entry.contentType, "MARKDOWN")
        XCTAssertTrue(payload.bookmarkToLabelsOrdered.isEmpty)
        XCTAssertTrue(payload.genericBookmarkToLabelsOrdered.isEmpty)
        XCTAssertTrue(payload.studyPadItemsOrdered.isEmpty)
        XCTAssertEqual(bookmarkService.studyPadEntries(labelId: label.id).first?.orderNumber, 4)
    }

    /**
     Verifies StudyPad drag/drop reordering accepts the exact payload keys emitted by the shared
     BibleView client and parsed by Android.
     *
     * Android parity source:
     * - `app/bibleview-js/src/composables/android.ts` sends `bookmarks`, `genericBookmarks`, and
     *   `studyPadTextItems`
     * - `BibleJavascriptInterface.updateOrderNumber` deserializes those three keys before calling
     *   `BookmarkControl.updateOrderNumbers`
     *
     * Expected result:
     * - the coordinator persists all three order updates and emits Android's
     *   `add_or_update_study_pad` reorder payload with the updated ordered rows.
     *
     * Failure meaning:
     * - iOS is preserving an iOS-only reorder payload shape that the shared web client does not
     *   send, leaving StudyPad drag/drop broken or dependent on accidental compatibility.
     */
    func testStudyPadActionCoordinatorReordersUsingAndroidPayloadKeys() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let label = bookmarkService.createLabel(name: "Study", color: Label.defaultColor)
        let bibleBookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            wholeVerse: true
        )
        let genericBookmark = bookmarkService.addGenericBookmark(
            bookInitials: "DICT",
            key: "entry-key",
            startOrdinal: 2,
            endOrdinal: 2
        )
        _ = bookmarkService.toggleLabel(bookmarkId: bibleBookmark.id, labelId: label.id)
        _ = bookmarkService.toggleLabel(bookmarkId: genericBookmark.id, labelId: label.id)
        let entry = try XCTUnwrap(
            bookmarkService.createStudyPadEntry(labelId: label.id, afterOrderNumber: -1)
        ).0
        let coordinator = makeStudyPadActionCoordinator(bookmarkService: bookmarkService)
        let data = """
        {
            "bookmarks": [{"first": "\(bibleBookmark.id.uuidString)", "second": 2}],
            "genericBookmarks": [{"first": "\(genericBookmark.id.uuidString)", "second": 1}],
            "studyPadTextItems": [{"first": "\(entry.id.uuidString)", "second": 0}]
        }
        """

        let result = coordinator.updateOrderNumber(labelId: label.id.uuidString, data: data)

        XCTAssertTrue(result.incrementsStudyPadRevision)
        XCTAssertEqual(result.events.count, 1)
        guard case .studyPadUpdated(let payload) = try XCTUnwrap(result.events.first) else {
            return XCTFail("Expected add_or_update_study_pad event")
        }
        XCTAssertNil(payload.studyPadTextEntry)
        XCTAssertEqual(payload.bookmarkToLabelsOrdered.first?.bookmarkId, bibleBookmark.id.uuidString)
        XCTAssertEqual(payload.bookmarkToLabelsOrdered.first?.orderNumber, 2)
        XCTAssertEqual(payload.genericBookmarkToLabelsOrdered.first?.bookmarkId, genericBookmark.id.uuidString)
        XCTAssertEqual(payload.genericBookmarkToLabelsOrdered.first?.orderNumber, 1)
        XCTAssertEqual(payload.studyPadItemsOrdered.first?.id, entry.id.uuidString)
        XCTAssertEqual(payload.studyPadItemsOrdered.first?.orderNumber, 0)
        XCTAssertEqual(
            bookmarkService.bibleBookmarkToLabel(bookmarkId: bibleBookmark.id, labelId: label.id)?.orderNumber,
            2
        )
        XCTAssertEqual(
            bookmarkService.genericBookmarkToLabel(bookmarkId: genericBookmark.id, labelId: label.id)?.orderNumber,
            1
        )
        XCTAssertEqual(bookmarkService.studyPadEntry(id: entry.id)?.orderNumber, 0)
    }

    /**
     Verifies StudyPad text edits return Android's changed-entry update event.
     *
     * Android parity source:
     * - `BookmarkControl.updateStudyPadTextEntryText` upserts the text row and posts
     *   `StudyPadOrderEvent` with the changed `StudyPadTextEntryWithText`
     * - `BibleView.onEvent(StudyPadOrderEvent)` emits `add_or_update_study_pad`
     *
     * Expected result:
     * - the coordinator persists the text and returns one StudyPad update event containing the
     *   changed journal row
     *
     * Failure meaning:
     * - iOS has restored its previous silent text-update path, which can leave other StudyPad views
     *   or event-driven client state stale compared with Android.
     */
    func testStudyPadActionCoordinatorUpdatesTextLikeAndroidBridge() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let label = bookmarkService.createLabel(name: "Study", color: Label.defaultColor)
        let entry = try XCTUnwrap(
            bookmarkService.createStudyPadEntry(labelId: label.id, afterOrderNumber: -1)
        ).0
        let coordinator = makeStudyPadActionCoordinator(bookmarkService: bookmarkService)

        let result = coordinator.updateStudyPadTextEntryText(
            id: entry.id.uuidString,
            text: "Updated StudyPad text"
        )

        XCTAssertTrue(result.incrementsStudyPadRevision)
        XCTAssertEqual(result.events.count, 1)
        guard case .studyPadUpdated(let payload) = try XCTUnwrap(result.events.first) else {
            return XCTFail("Expected add_or_update_study_pad event")
        }
        XCTAssertEqual(payload.studyPadTextEntry?.id, entry.id.uuidString)
        XCTAssertEqual(payload.studyPadTextEntry?.text, "Updated StudyPad text")
        XCTAssertEqual(bookmarkService.studyPadEntry(id: entry.id)?.textEntry?.text, "Updated StudyPad text")
    }

    /**
     Verifies stale StudyPad text edits do not create detached text rows.
     *
     * Android parity source:
     * - `BookmarkControl.updateStudyPadTextEntryText` updates the text table for an existing
     *   StudyPad entry and then emits the changed entry; a stale id does not become a new visible
     *   StudyPad row
     *
     * Expected result:
     * - the coordinator returns no bridge event and does not insert an orphan
     *   `StudyPadTextEntryText` row when the journal row is missing
     *
     * Failure meaning:
     * - iOS accepted stale bridge state as persistent detached data, which can later surface as
     *   backup/restore or sync drift outside Android's visible StudyPad model.
     */
    func testStudyPadActionCoordinatorIgnoresStaleTextUpdateWithoutDetachedRow() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let coordinator = makeStudyPadActionCoordinator(bookmarkService: bookmarkService)
        let staleId = UUID()

        let result = coordinator.updateStudyPadTextEntryText(
            id: staleId.uuidString,
            text: "Detached text"
        )

        XCTAssertFalse(result.incrementsStudyPadRevision)
        XCTAssertTrue(result.events.isEmpty)
        let texts = try modelContext.fetch(FetchDescriptor<StudyPadTextEntryText>())
        XCTAssertTrue(texts.isEmpty)
    }

    /**
     Verifies StudyPad bookmark relationship edits preserve Android's distinct
     `BookmarkToLabelAddedOrUpdatedEvent` bridge path.
     *
     * Setup:
     * - creates one Bible bookmark-to-label relation and sends the same JSON object produced by
     *   `android.updateStudyPadEntry` in the shared BibleView client
     *
     * Expected result:
     * - the coordinator mutates only that relationship and returns one
     *   `add_or_update_bookmark_to_label` event
     *
     * Failure meaning:
     * - iOS has collapsed relationship edits into a generic StudyPad refresh, drifting from the
     *   Android event split and making future ordering/text regressions harder to isolate.
     */
    func testStudyPadActionCoordinatorUpdatesBookmarkToLabelLikeAndroidBridge() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let label = bookmarkService.createLabel(name: "Study", color: Label.defaultColor)
        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            wholeVerse: true
        )
        _ = bookmarkService.toggleLabel(bookmarkId: bookmark.id, labelId: label.id)
        let coordinator = makeStudyPadActionCoordinator(bookmarkService: bookmarkService)
        let data = """
        {
            "bookmarkId": "\(bookmark.id.uuidString)",
            "labelId": "\(label.id.uuidString)",
            "orderNumber": 5,
            "indentLevel": 2,
            "expandContent": false
        }
        """

        let result = coordinator.updateBookmarkToLabel(data: data)

        XCTAssertFalse(result.incrementsStudyPadRevision)
        XCTAssertEqual(result.events.count, 1)
        guard case .bookmarkToLabelUpdated(let payload) = try XCTUnwrap(result.events.first) else {
            return XCTFail("Expected add_or_update_bookmark_to_label event")
        }
        XCTAssertEqual(payload.type, "BibleBookmarkToLabel")
        XCTAssertEqual(payload.bookmarkId, bookmark.id.uuidString)
        XCTAssertEqual(payload.labelId, label.id.uuidString)
        XCTAssertEqual(payload.orderNumber, 5)
        XCTAssertEqual(payload.indentLevel, 2)
        XCTAssertEqual(payload.expandContent, false)
    }

    /**
     Verifies the public reader bridge path accepts the StudyPad reorder payload emitted by the
     shared BibleView client.
     *
     * Android parity source:
     * - `app/bibleview-js/src/composables/android.ts` sends `bookmarks`, `genericBookmarks`, and
     *   `studyPadTextItems` to `window.android.updateOrderNumber`
     *
     * Expected result:
     * - `BibleReaderController` delegates the action to the StudyPad coordinator, persists the new
     *   order, and emits `add_or_update_study_pad` with the changed relationship row
     *
     * Failure meaning:
     * - the extraction left the user-facing bridge on the old iOS-only key names even if the
     *   collaborator itself understands Android's payload.
     */
    @MainActor
    func testReaderStudyPadUpdateOrderNumberBridgeAcceptsAndroidPayloadKeys() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let controller = BibleReaderController(bridge: bridge)
        controller.bookmarkService = bookmarkService
        let label = bookmarkService.createLabel(name: "Study", color: Label.defaultColor)
        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            wholeVerse: true
        )
        _ = bookmarkService.toggleLabel(bookmarkId: bookmark.id, labelId: label.id)
        let data = """
        {
            "bookmarks": [{"first": "\(bookmark.id.uuidString)", "second": 6}],
            "genericBookmarks": [],
            "studyPadTextItems": []
        }
        """

        controller.bridge(bridge, updateOrderNumber: label.id.uuidString, data: data)

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "add_or_update_study_pad") as? [String: Any]
        )
        XCTAssertTrue(payload["studyPadTextEntry"] is NSNull)
        let relationships = try XCTUnwrap(payload["bookmarkToLabelsOrdered"] as? [[String: Any]])
        let relationship = try XCTUnwrap(relationships.first)
        XCTAssertEqual(relationship["bookmarkId"] as? String, bookmark.id.uuidString)
        XCTAssertEqual(relationship["orderNumber"] as? Int, 6)
        XCTAssertEqual(
            bookmarkService.bibleBookmarkToLabel(bookmarkId: bookmark.id, labelId: label.id)?.orderNumber,
            6
        )
    }

    /**
     Verifies the public reader bridge emits Android's StudyPad deletion payload as a JavaScript
     string instead of a raw UUID token.
     *
     * Android parity source:
     * - `BibleView.onEvent(StudyPadTextEntryDeleted)` calls
     *   `bibleView.emit("delete_study_pad_text_entry", "${event.studyPadTextEntryId}")`, making
     *   the second JavaScript argument a quoted string.
     *
     * Expected result:
     * - deleting a StudyPad journal through `BibleReaderController` emits
     *   `delete_study_pad_text_entry` with a JSON string payload containing the deleted entry id.
     *
     * Failure meaning:
     * - the bridge emitted an invalid raw UUID expression or otherwise drifted from Android's
     *   StudyPad delete event contract, leaving the Vue client unable to consume the deletion.
     */
    @MainActor
    func testReaderStudyPadDeleteBridgeEmitsAndroidStringPayload() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let controller = BibleReaderController(bridge: bridge)
        controller.bookmarkService = bookmarkService
        let label = bookmarkService.createLabel(name: "Study", color: Label.defaultColor)
        let entry = try XCTUnwrap(
            bookmarkService.createStudyPadEntry(labelId: label.id, afterOrderNumber: -1)
        ).0

        controller.bridge(bridge, deleteStudyPadEntry: entry.id.uuidString)

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "delete_study_pad_text_entry") as? String
        )
        XCTAssertEqual(payload, entry.id.uuidString)
        XCTAssertNil(bookmarkService.studyPadEntry(id: entry.id))
    }

    /**
     Verifies that the reader bridge applies Android's global `notes_content_type` preference when
     creating a new note row.
     *
     * Setup:
     * - configures the controller settings store with `notes_content_type = MARKDOWN`
     * - saves a note through the same delegate entry point used by the Vue bridge
     *
     * Expected result:
     * - the persisted note row records `MARKDOWN`, making the note's renderer stable even if the
     *   global preference changes later
     *
     * Failure meaning:
     * - a failure means iOS is only rendering from the current global setting and is not preserving
     *   Android-compatible per-note content type state
     */
    @MainActor
    func testReaderSaveBookmarkNoteUsesConfiguredMarkdownContentTypeForNewNote() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let settingsStore = try makeInMemorySettingsStore()
        settingsStore.setString(.notesContentType, value: "MARKDOWN")
        let controller = BibleReaderController(bridge: BibleBridge())
        controller.bookmarkService = bookmarkService
        controller.settingsStore = settingsStore

        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            wholeVerse: true
        )

        controller.bridge(BibleBridge(), saveBookmarkNote: bookmark.id.uuidString, note: "**Markdown** note")

        let bibleNote = try XCTUnwrap(try modelContext.fetch(FetchDescriptor<BibleBookmarkNotes>()).first)
        XCTAssertEqual(bibleNote.contentType, "MARKDOWN")
    }

    /**
     Verifies Android bridge parity for notes cleared to whitespace-only text.

     Android's `BibleJavascriptInterface.saveBookmarkNote` trims only to decide whether a save should
     become `null`; whitespace-only bookmark and generic notes therefore delete the detached note row
     rather than persisting a blank row with a content type. This exercises the iOS reader delegate
     path so the web editor, bridge, and service cannot drift from that behavior.
     */
    @MainActor
    func testReaderSaveBookmarkNoteDeletesWhitespaceOnlyNotesLikeAndroidBridge() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let controller = BibleReaderController(bridge: bridge)
        controller.bookmarkService = bookmarkService

        let bibleBookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            wholeVerse: true
        )
        let genericBookmark = bookmarkService.addGenericBookmark(
            bookInitials: "DICT",
            key: "entry-key",
            startOrdinal: 2,
            endOrdinal: 2
        )
        bookmarkService.saveBibleBookmarkNote(bookmarkId: bibleBookmark.id, note: "Bible note")
        bookmarkService.saveBibleBookmarkNote(bookmarkId: genericBookmark.id, note: "Generic note")

        controller.bridge(bridge, saveBookmarkNote: bibleBookmark.id.uuidString, note: " \n\t ")
        controller.bridge(bridge, saveBookmarkNote: genericBookmark.id.uuidString, note: " \n\t ")

        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<BibleBookmarkNotes>()).isEmpty)
        XCTAssertTrue(try modelContext.fetch(FetchDescriptor<GenericBookmarkNotes>()).isEmpty)

        let payload = try XCTUnwrap(
            bridgeEmissionPayload(from: recordedScripts(), event: "bookmark_note_modified") as? [String: Any]
        )
        XCTAssertEqual(payload["id"] as? String, bibleBookmark.id.uuidString)
        XCTAssertEqual(payload["notes"] as? String, "")
        XCTAssertTrue(payload["notesContentType"] is NSNull)
    }

    /**
     Verifies the bookmark action collaborator applies Android's auto-label creation contract.

     Android `BibleView.makeBookmark` assigns both `autoAssignLabels` and `autoAssignPrimaryLabel`,
     then opens the bookmark label modal only when there are no initial labels or notes are requested.
     This protects the extraction from preserving the old iOS-only behavior where auto-assigned
     bookmarks still opened the label modal and never received the configured primary label.
     */
    @MainActor
    func testBookmarkActionCoordinatorAppliesAndroidAutoAssignPrimaryLabelAndSuppressesLabelModal() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let assignedLabel = bookmarkService.createLabel(name: "Assigned")
        let primaryLabel = bookmarkService.createLabel(name: "Primary")
        let coordinator = makeBookmarkActionCoordinator(bookmarkService: bookmarkService)
        let workspaceSettings = WorkspaceSettings(
            autoAssignLabels: [assignedLabel.id, primaryLabel.id],
            autoAssignPrimaryLabel: primaryLabel.id,
            studyPadCursors: [assignedLabel.id: 7]
        )

        let result = coordinator.addOrUpdateBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            addNote: false,
            wholeVerse: true,
            workspaceSettings: workspaceSettings
        )

        let bookmark = try XCTUnwrap(bookmarkService.bookmarks(for: 1, endOrdinal: 1, book: "Genesis").first)
        XCTAssertEqual(bookmark.primaryLabelId, primaryLabel.id)
        XCTAssertNotNil(bookmarkService.bibleBookmarkToLabel(bookmarkId: bookmark.id, labelId: assignedLabel.id))
        XCTAssertEqual(result.updatedWorkspaceSettings?.studyPadCursors[assignedLabel.id], 1)
        XCTAssertTrue(result.requiresPersistState)

        guard case .bookmarksUpdated(let payloads) = result.events.first else {
            return XCTFail("Expected add_or_update_bookmarks event")
        }
        XCTAssertEqual(payloads.first?.id, bookmark.id.uuidString)
        XCTAssertFalse(
            result.events.contains { event in
                if case .bookmarkClicked = event { return true }
                return false
            },
            "Android does not open the label modal when auto labels are already assigned and notes were not requested."
        )
    }

    /**
     Verifies bookmark creation does not treat an orphan auto-assign primary as an implicit label.

     Android passes only `autoAssignLabels` into bookmark creation; if a stale primary is not among
     those labels, bookmark primary repair falls back to an actually assigned label.
     */
    @MainActor
    func testBookmarkActionCoordinatorDoesNotImplicitlyAssignOrphanAutoAssignPrimaryLabel() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let assignedLabel = bookmarkService.createLabel(name: "Assigned")
        let orphanPrimaryLabel = bookmarkService.createLabel(name: "Orphan Primary")
        let coordinator = makeBookmarkActionCoordinator(bookmarkService: bookmarkService)
        var workspaceSettings = WorkspaceSettings(autoAssignLabels: [assignedLabel.id])
        workspaceSettings.autoAssignPrimaryLabel = orphanPrimaryLabel.id

        _ = coordinator.addOrUpdateBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            addNote: false,
            wholeVerse: true,
            workspaceSettings: workspaceSettings
        )

        let bookmark = try XCTUnwrap(bookmarkService.bookmarks(for: 1, endOrdinal: 1, book: "Genesis").first)
        XCTAssertEqual(bookmark.primaryLabelId, assignedLabel.id)
        XCTAssertNotNil(bookmarkService.bibleBookmarkToLabel(bookmarkId: bookmark.id, labelId: assignedLabel.id))
        XCTAssertNil(bookmarkService.bibleBookmarkToLabel(bookmarkId: bookmark.id, labelId: orphanPrimaryLabel.id))
    }

    /**
     Verifies primary-label changes reject Android's reserved unlabelled system label.

     Android `BibleJavascriptInterface.setAsPrimaryLabel` returns before mutation when the selected
     label is the synthetic unlabelled label. The extracted iOS collaborator must not preserve the
     previous drift where any valid UUID could become `primaryLabelId`.
     */
    @MainActor
    func testBookmarkActionCoordinatorRejectsUnlabeledPrimaryLabelLikeAndroidBridge() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let coordinator = makeBookmarkActionCoordinator(bookmarkService: bookmarkService)
        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            wholeVerse: true
        )

        let result = coordinator.setPrimaryLabel(
            bookmarkId: bookmark.id.uuidString,
            labelId: Label.unlabeledId.uuidString
        )

        XCTAssertNil(bookmarkService.bibleBookmark(id: bookmark.id)?.primaryLabelId)
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertNil(result.recentLabelId)
    }

    /**
     Verifies whole-verse bridge edits keep Android's text-range guard.

     Android refuses to turn off whole-verse rendering when a bookmark has no text range, because
     there is no partial selection to restore. This test exercises both the guarded no-op and the
     allowed mutation once offsets exist.
     */
    @MainActor
    func testBookmarkActionCoordinatorRejectsWholeVerseOffWithoutTextRangeLikeAndroidBridge() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkService = BookmarkService(store: BookmarkStore(modelContext: modelContext))
        let coordinator = makeBookmarkActionCoordinator(bookmarkService: bookmarkService)
        let bookmark = bookmarkService.addBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: 1,
            endOrdinal: 1,
            wholeVerse: true
        )

        let rejected = coordinator.setBookmarkWholeVerse(bookmarkId: bookmark.id.uuidString, value: false)
        XCTAssertTrue(bookmarkService.bibleBookmark(id: bookmark.id)?.wholeVerse ?? false)
        XCTAssertTrue(rejected.events.isEmpty)

        bookmark.startOffset = 3
        bookmark.endOffset = 8
        let accepted = coordinator.setBookmarkWholeVerse(bookmarkId: bookmark.id.uuidString, value: false)

        XCTAssertFalse(bookmarkService.bibleBookmark(id: bookmark.id)?.wholeVerse ?? true)
        guard case .bookmarksUpdated(let payloads) = accepted.events.first else {
            return XCTFail("Expected whole-verse mutation to re-emit the updated bookmark")
        }
        XCTAssertEqual(payloads.first?.wholeVerse, false)
    }

    /**
     Builds the proposed StudyPad action coordinator with production payload projection.
     */
    private func makeStudyPadActionCoordinator(
        bookmarkService: BookmarkService,
        notesContentType: String = "HTML"
    ) -> BibleReaderStudyPadActionCoordinator {
        BibleReaderStudyPadActionCoordinator(
            bookmarkService: bookmarkService,
            payloadFactory: BibleReaderAnnotationPayloadFactory(
                currentBook: "Genesis",
                activeModuleName: "KJV",
                activeModule: nil,
                bookCatalog: BibleReaderBookCatalog(activeModule: nil, moduleBookList: []),
                unlabeledLabelID: Label.unlabeledId.uuidString
            ),
            currentNotesContentType: { notesContentType }
        )
    }

    /**
     Builds the proposed bookmark action coordinator with production payload projection.

     The helper intentionally mirrors the controller seam: the coordinator owns bookmark mutation
     rules while the test supplies the same annotation payload factory the reader would use. A compile
     failure here means the extraction seam has not been implemented yet; assertion failures mean the
     seam exists but no longer matches Android's bridge contract.
     */
    private func makeBookmarkActionCoordinator(
        bookmarkService: BookmarkService,
        notesContentType: String = "HTML"
    ) -> BibleReaderBookmarkActionCoordinator {
        BibleReaderBookmarkActionCoordinator(
            bookmarkService: bookmarkService,
            payloadFactory: BibleReaderAnnotationPayloadFactory(
                currentBook: "Genesis",
                activeModuleName: "KJV",
                activeModule: nil,
                bookCatalog: BibleReaderBookCatalog(activeModule: nil, moduleBookList: []),
                unlabeledLabelID: Label.unlabeledId.uuidString
            ),
            currentBook: "Genesis",
            currentNotesContentType: { notesContentType }
        )
    }

    /**
     Verifies that My Notes accessibility export caps detailed row and note tokens.
     *
     * Setup:
     * - creates more notes than the UI test runtime detail limit in an in-memory bookmark store
     * - reads the controller-owned encoded accessibility state after navigating to the note chapter
     *
     * Expected result:
     * - the total note count reflects all notes
     * - detailed row and note tokens are limited to `UITestRuntimeConfiguration`'s cap
     *
     * Failure meaning:
     * - UI tests and accessibility consumers could receive unbounded encoded state, increasing
     *   flakiness and masking the compact-reader state contract.
     */
    func testMyNotesAccessibilityStateCapsDetailedRowAndNoteTokens() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        let controller = BibleReaderController(bridge: BibleBridge())
        controller.bookmarkService = bookmarkService
        controller.navigateTo(book: "Psalms", chapter: 119, verse: 1)

        for verse in 1...60 {
            let ordinal = (119 - 1) * 40 + verse
            let bookmark = BibleBookmark(
                kjvOrdinalStart: ordinal,
                kjvOrdinalEnd: ordinal,
                ordinalStart: ordinal,
                ordinalEnd: ordinal,
                v11n: "KJVA"
            )
            bookmark.book = "Psalms"
            modelContext.insert(bookmark)
            try modelContext.save()
            bookmarkService.saveBibleBookmarkNote(bookmarkId: bookmark.id, note: "Note \(verse)")
        }

        let snapshot = controller.myNotesAccessibilitySnapshot

        XCTAssertEqual(snapshot.totalCount, 60)
        XCTAssertEqual(snapshot.rowReferenceTokens.count, UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
        XCTAssertEqual(snapshot.noteTokens.count, UITestRuntimeConfiguration.detailedAccessibilityRowTokenLimit)
        XCTAssertEqual(controller.myNotesAccessibilityState, snapshot.encodedValue)
    }

    /**
     Verifies the extracted accessibility snapshot factory owns My Notes and StudyPad export assembly
     without depending on `BibleReaderController`.
     *
     * Setup:
     * - creates in-memory bookmark storage with one Bible note and one StudyPad text entry
     * - supplies explicit ordinal and verse-reference closures matching the reader's current chapter
     *
     * Expected result:
     * - My Notes exports the visible note reference, revision, and sanitized note token
     * - StudyPad exports the visible label, revision, entry count, and sanitized text token
     *
     * Failure meaning:
     * - UI automation state export has leaked back into controller-specific behavior or no longer
     *   matches the compact token contract consumed by reader UI tests.
     */
    func testAccessibilitySnapshotFactoryBuildsMyNotesAndStudyPadState() throws {
        let container = try makeBookmarkRestoreModelContainer()
        let modelContext = ModelContext(container)
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        let noteOrdinal = (119 - 1) * 40 + 3
        let noteBookmark = BibleBookmark(
            kjvOrdinalStart: noteOrdinal,
            kjvOrdinalEnd: noteOrdinal,
            ordinalStart: noteOrdinal,
            ordinalEnd: noteOrdinal,
            v11n: "KJVA"
        )
        noteBookmark.book = "Psalms"
        modelContext.insert(noteBookmark)
        try modelContext.save()
        bookmarkService.saveBibleBookmarkNote(bookmarkId: noteBookmark.id, note: "Line=One;Two|Three")

        let label = bookmarkService.createLabel(name: "Study=Pad;One", color: Label.defaultColor)
        let createdEntry = try XCTUnwrap(bookmarkService.createStudyPadEntry(labelId: label.id, afterOrderNumber: -1))
        bookmarkService.updateStudyPadTextEntryText(id: createdEntry.0.id, text: "Entry|One,Two")

        let factory = BibleReaderAccessibilitySnapshotFactory(
            bookmarkService: bookmarkService,
            currentBook: "Psalms",
            currentChapter: 119,
            showingMyNotes: true,
            showingStudyPad: true,
            editingInWebView: true,
            myNotesMutationRevision: 7,
            studyPadMutationRevision: 8,
            activeStudyPadLabelId: label.id,
            activeStudyPadLabelName: label.name,
            rowLimit: 2,
            chapterOrdinalRange: { (start: noteOrdinal - 2, end: noteOrdinal + 2, verseCount: 5) },
            verseReference: { _, ordinal in
                VerseKeyReference(
                    osisBookId: "Ps",
                    chapter: 119,
                    verse: ordinal - ((119 - 1) * 40),
                    ordinal: ordinal
                )
            }
        )

        let myNotesSnapshot = factory.myNotesAccessibilitySnapshot()
        XCTAssertTrue(myNotesSnapshot.isVisible)
        XCTAssertTrue(myNotesSnapshot.isEditing)
        XCTAssertEqual(myNotesSnapshot.revision, 7)
        XCTAssertEqual(myNotesSnapshot.totalCount, 1)
        XCTAssertEqual(myNotesSnapshot.rowReferenceTokens, ["Psalms_119_3"])
        XCTAssertEqual(myNotesSnapshot.noteTokens.map(\.encodedValue), ["|Psalms_119_3=Line_One_Two_Three|"])

        let studyPadSnapshot = factory.studyPadAccessibilitySnapshot()
        XCTAssertTrue(studyPadSnapshot.isVisible)
        XCTAssertTrue(studyPadSnapshot.isEditing)
        XCTAssertEqual(studyPadSnapshot.revision, 8)
        XCTAssertEqual(studyPadSnapshot.labelToken, "Study_Pad_One")
        XCTAssertEqual(studyPadSnapshot.textEntryCount, 1)
        XCTAssertEqual(studyPadSnapshot.textTokens.map(\.encodedValue), ["|0=Entry_One_Two|"])
    }

    /**
     Creates an in-memory bookmark schema for BibleUI reader bridge tests.

     The helper intentionally mirrors the BibleCore package bookmark fixture because these tests
     exercise BibleUI payload projection while still needing realistic SwiftData bookmark graphs.
     Keeping the fixture local avoids adding a test-target dependency from BibleUI tests to
     BibleCore tests, which SwiftPM does not support.

     - Returns: A transient bookmark `ModelContainer`.
     - Side effects: Allocates in-memory SwiftData storage for the current test only.
     - Failure modes: Throws if SwiftData cannot initialize the model container.
     */
    private func makeBookmarkRestoreModelContainer() throws -> ModelContainer {
        let schema = Schema([
            BibleBookmark.self,
            BibleBookmarkNotes.self,
            BibleBookmarkToLabel.self,
            GenericBookmark.self,
            GenericBookmarkNotes.self,
            GenericBookmarkToLabel.self,
            Label.self,
            StudyPadTextEntry.self,
            StudyPadTextEntryText.self,
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /**
     Asserts that a bridge payload contains an integer timestamp field.

     Bookmark bridge payloads include millisecond timestamps whose exact values vary by runtime.
     The helper preserves the Android payload-shape contract without making migrated tests depend
     on wall-clock values.

     - Parameters:
      - field: JSON key expected to contain an integer value.
       - json: Raw bridge payload JSON.
       - file: XCTest source file used for failure reporting.
       - line: XCTest source line used for failure reporting.
     - Side effects: Records an XCTest failure if the field is absent or non-integer.
     - Failure modes: Fails the current test through `XCTAssertNotNil`.
     */
    private func assertBridgeJSONIntegerField(
        _ field: String,
        in json: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let escapedField = NSRegularExpression.escapedPattern(for: field)
        let integerPattern = #"""# + escapedField + #""\s*:\s*\d+(?=[,}])"#
        let decimalPattern = #"""# + escapedField + #""\s*:\s*\d+\.\d+"#
        XCTAssertNotNil(
            json.range(of: integerPattern, options: .regularExpression),
            "Expected \(field) to be emitted as an integer JSON number in \(json)",
            file: file,
            line: line
        )
        XCTAssertNil(
            json.range(of: decimalPattern, options: .regularExpression),
            "Expected \(field) to avoid decimal JSON encoding in \(json)",
            file: file,
            line: line
        )
    }
}
