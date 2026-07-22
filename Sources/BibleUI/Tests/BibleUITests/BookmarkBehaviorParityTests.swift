import Foundation
import SwiftData
import XCTest
@testable import BibleCore
@testable import BibleUI
import BibleView

/**
 Protects bookmark, generic-selection, bridge-event, and list-order behavior against Android's
 checked-in bookmark implementation.

 Every test decodes `Tests/Fixtures/android-bookmark-behavior-parity.json`, whose authority paths point to
 Android `BookmarkControl`, `BookmarksDao`, and `ClientPageObjects`. Tests use transient SwiftData
 containers and recording bridges, so they do not mutate app or simulator state.
 */
final class BookmarkBehaviorParityTests: XCTestCase {
    /**
     Verifies two Android-valid highlights with the same starting verse remain separate entities and
     explicit updates target only the supplied UUID.

     - Setup: Creates two partial KJV highlights from the Android fixture through
       `BibleReaderBookmarkActionCoordinator`, then updates the first result by UUID.
     - Expected result: Both creates persist, their UUIDs differ, and the update changes only the
       selected bookmark's offsets without changing row count.
     - Side effects: Writes only to an in-memory SwiftData container.
     - Failure modes: A failure means iOS has reintroduced positional de-duplication or an ambiguous
       create/update boundary that Android's `BaseBookmarkWithNotes.new` contract does not have.
     */
    func testExplicitIdentityKeepsSameStartHighlightsDistinctAndUpdatesOnlyTargetUUID() throws {
        let fixture = try loadBookmarkBehaviorParityAndroidFixture()
        let firstInput = try XCTUnwrap(fixture.sameStartBibleHighlights.first)
        let secondInput = try XCTUnwrap(fixture.sameStartBibleHighlights.last)
        let container = try makeBookmarkBehaviorParityModelContainer()
        let modelContext = ModelContext(container)
        let store = BookmarkStore(modelContext: modelContext)
        let service = BookmarkService(store: store)
        let coordinator = makeBookmarkActionCoordinator(service: service)

        let firstResult = coordinator.addOrUpdateBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: firstInput.kjvaOrdinalStart,
            endOrdinal: firstInput.kjvaOrdinalStart,
            addNote: false,
            wholeVerse: false,
            startOffset: firstInput.startOffset,
            endOffset: firstInput.endOffset,
            identity: .create,
            workspaceSettings: nil
        )
        let secondResult = coordinator.addOrUpdateBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: secondInput.kjvaOrdinalStart,
            endOrdinal: secondInput.kjvaOrdinalStart,
            addNote: false,
            wholeVerse: false,
            startOffset: secondInput.startOffset,
            endOffset: secondInput.endOffset,
            identity: .create,
            workspaceSettings: nil
        )
        let firstID = try bibleBookmarkID(from: firstResult)
        let secondID = try bibleBookmarkID(from: secondResult)

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<BibleBookmark>()).count, 2)
        XCTAssertEqual(service.bibleBookmark(id: firstID)?.startOffset, firstInput.startOffset)
        XCTAssertEqual(service.bibleBookmark(id: secondID)?.startOffset, secondInput.startOffset)

        _ = coordinator.addOrUpdateBibleBookmark(
            bookInitials: "KJV",
            startOrdinal: firstInput.kjvaOrdinalStart,
            endOrdinal: firstInput.kjvaOrdinalStart,
            addNote: false,
            wholeVerse: false,
            startOffset: 12,
            endOffset: 16,
            identity: .update(firstID),
            workspaceSettings: nil
        )

        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<BibleBookmark>()).count, 2)
        XCTAssertEqual(service.bibleBookmark(id: firstID)?.startOffset, 12)
        XCTAssertEqual(service.bibleBookmark(id: firstID)?.endOffset, 16)
        XCTAssertEqual(service.bibleBookmark(id: secondID)?.startOffset, secondInput.startOffset)
        XCTAssertEqual(service.bibleBookmark(id: secondID)?.endOffset, secondInput.endOffset)
    }

    /**
     Verifies a generic text selection preserves Android's flags, offsets, stored source identity,
     projected text, and Android's partial-selection fragment omission through persistence and a
     parsed Vue emission.

     - Setup: Sends the fixture selection through `BibleReaderAnnotationBridgeCoordinator` while the
       active module name deliberately differs from the stored source initials.
     - Expected result: SwiftData and parsed `add_or_update_bookmarks` JSON retain exact ordinals,
       offsets, `wholeVerse=false`, source metadata, selected/full/highlighted text, and a null
       `osisFragment` because Android only attaches that context to whole-page generic bookmarks.
     - Side effects: Writes to an in-memory store and records JavaScript bridge evaluations.
     - Failure modes: A failure means selection fidelity was dropped or active-reader metadata was
       falsely attributed to a stored-source bookmark.
     */
    func testGenericSelectionPreservesOffsetsStoredSourceAndParsedBridgePayload() throws {
        let fixture = try loadBookmarkBehaviorParityAndroidFixture()
        let input = fixture.genericSelection
        let container = try makeBookmarkBehaviorParityModelContainer()
        let modelContext = ModelContext(container)
        let store = BookmarkStore(modelContext: modelContext)
        let service = BookmarkService(store: store)
        let (bridge, recordedScripts) = makeRecordingBridge()
        var resolvedSourceRequests: [(String, String)] = []
        let payloadFactory = BibleReaderAnnotationPayloadFactory(
            currentBook: "Genesis",
            activeModuleName: input.activeBookInitials,
            activeModule: nil,
            sourceModuleResolver: { _ in nil },
            genericSourceResolver: { initials, key in
                resolvedSourceRequests.append((initials, key))
                return GenericBookmarkSourceContent(
                    bookName: input.source.bookName,
                    bookAbbreviation: input.source.bookAbbreviation,
                    keyName: input.source.keyName,
                    plainText: input.source.plainText,
                    osisFragment: OsisFragment(
                        xml: input.source.xml,
                        key: input.key,
                        keyName: input.source.keyName,
                        v11n: "",
                        bookCategory: "GENERAL_BOOK",
                        bookInitials: input.bookInitials,
                        bookAbbreviation: input.source.bookAbbreviation,
                        osisRef: input.key,
                        ordinalRange: [input.ordinalStart, input.ordinalEnd]
                    )
                )
            },
            bookCatalog: BibleReaderBookCatalog(activeModule: nil, moduleBookList: []),
            unlabeledLabelID: Label.unlabeledId.uuidString
        )
        let coordinator = makeAnnotationBridgeCoordinator(
            bridge: bridge,
            service: service,
            payloadFactory: payloadFactory
        )

        coordinator.addGenericBookmark(
            bookInitials: input.bookInitials,
            osisRef: input.key,
            startOrdinal: input.ordinalStart,
            endOrdinal: input.ordinalEnd,
            addNote: false,
            wholeVerse: input.wholeVerse,
            startOffset: input.startOffset,
            endOffset: input.endOffset
        )

        let persisted = try XCTUnwrap(store.genericBookmarks().first)
        XCTAssertEqual(persisted.bookInitials, input.bookInitials)
        XCTAssertEqual(persisted.key, input.key)
        XCTAssertEqual(persisted.ordinalStart, input.ordinalStart)
        XCTAssertEqual(persisted.ordinalEnd, input.ordinalEnd)
        XCTAssertEqual(persisted.startOffset, input.startOffset)
        XCTAssertEqual(persisted.endOffset, input.endOffset)
        XCTAssertEqual(persisted.wholeVerse, input.wholeVerse)
        XCTAssertEqual(resolvedSourceRequests.map { [$0.0, $0.1] }, [[input.bookInitials, input.key]])

        let payloads = try XCTUnwrap(
            bridgeEmissionPayload(
                from: recordedScripts(),
                event: "add_or_update_bookmarks"
            ) as? [[String: Any]]
        )
        let payload = try XCTUnwrap(payloads.first)
        XCTAssertEqual(payload["type"] as? String, "generic-bookmark")
        XCTAssertEqual(payload["ordinalRange"] as? [Int], [input.ordinalStart, input.ordinalEnd])
        XCTAssertEqual(payload["offsetRange"] as? [Int], [input.startOffset, input.endOffset])
        XCTAssertEqual(payload["wholeVerse"] as? Bool, false)
        XCTAssertEqual(payload["bookInitials"] as? String, input.bookInitials)
        XCTAssertEqual(payload["bookName"] as? String, input.source.bookName)
        XCTAssertEqual(payload["bookAbbreviation"] as? String, input.source.bookAbbreviation)
        XCTAssertEqual(payload["key"] as? String, input.key)
        XCTAssertEqual(payload["keyName"] as? String, input.source.keyName)
        XCTAssertEqual(payload["text"] as? String, input.expected.text)
        XCTAssertEqual(payload["fullText"] as? String, input.expected.fullText)
        XCTAssertEqual(payload["highlightedText"] as? String, input.expected.highlightedText)

        XCTAssertTrue(payload["osisFragment"] is NSNull)
    }

    /**
     Verifies whole-page generic bookmarks keep their stored render context without invented verse
     metadata.

     - Setup: Projects a nullable-ordinal My Documents-style bookmark from a stored-source resolver
       whose legacy fragment contains an empty versification and zero ordinal range.
     - Expected result: Parsed JSON contains the stored fragment, while `v11n` and `ordinalRange`
       are explicit nulls as produced by Android for a non-`VerseRange` key.
     - Side effects: Encodes and parses one in-memory DTO only.
     - Failure modes: A failure means iOS either drops Android's whole-page rendering context or
       fabricates verse metadata for an unnumbered generic page.
     */
    func testWholePageGenericPayloadUsesStoredFragmentWithNullableVerseMetadata() throws {
        let bookmark = GenericBookmark(
            key: "page-alpha",
            bookInitials: "MYDOC-AUTH",
            ordinalStart: nil,
            ordinalEnd: nil,
            wholeVerse: true
        )
        let factory = BibleReaderAnnotationPayloadFactory(
            currentBook: "Genesis",
            activeModuleName: "ACTIVE-WRONG",
            activeModule: nil,
            sourceModuleResolver: { _ in nil },
            genericSourceResolver: { initials, key in
                GenericBookmarkSourceContent(
                    bookName: "Stored Document",
                    bookAbbreviation: initials,
                    keyName: "Page Alpha",
                    plainText: "Stored page content",
                    osisFragment: OsisFragment(
                        xml: "<p>Stored page content</p>",
                        key: key,
                        keyName: "Page Alpha",
                        v11n: "",
                        bookCategory: DocumentCategory.generalBook.rawValue,
                        bookInitials: initials,
                        bookAbbreviation: initials,
                        osisRef: key,
                        ordinalRange: [0, 0],
                        isNativeHtml: true
                    )
                )
            },
            bookCatalog: BibleReaderBookCatalog(activeModule: nil, moduleBookList: []),
            unlabeledLabelID: Label.unlabeledId.uuidString
        )

        let payload = try bridgeJSONObject(factory.genericBookmarkJSONForStudyPad(bookmark))
        let fragment = try XCTUnwrap(payload["osisFragment"] as? [String: Any])

        XCTAssertEqual(fragment["bookInitials"] as? String, bookmark.bookInitials)
        XCTAssertEqual(fragment["key"] as? String, bookmark.key)
        XCTAssertEqual(fragment["xml"] as? String, "<p>Stored page content</p>")
        XCTAssertTrue(fragment["v11n"] is NSNull)
        XCTAssertTrue(fragment["ordinalRange"] is NSNull)
    }

    /**
     Verifies missing stored generic sources fail closed instead of borrowing active-module metadata.

     - Setup: Projects a fixture bookmark with a deliberately unrelated active-module name and no
       stored-source resolver result.
     - Expected result: The parsed DTO keeps stored initials/key as its stable fallback, emits no
       source text or OSIS fragment, and never contains the active module identity.
     - Side effects: Encodes and parses one in-memory DTO only.
     - Failure modes: A failure means stale or missing source content can be misrepresented as the
       currently visible document.
     */
    func testMissingGenericSourceNeverSubstitutesActiveModuleMetadata() throws {
        let input = try loadBookmarkBehaviorParityAndroidFixture().genericSelection
        let bookmark = GenericBookmark(
            id: try XCTUnwrap(UUID(uuidString: input.id)),
            key: input.key,
            bookInitials: input.bookInitials,
            ordinalStart: input.ordinalStart,
            ordinalEnd: input.ordinalEnd,
            wholeVerse: input.wholeVerse
        )
        bookmark.startOffset = input.startOffset
        bookmark.endOffset = input.endOffset
        let factory = BibleReaderAnnotationPayloadFactory(
            currentBook: "Genesis",
            activeModuleName: input.activeBookInitials,
            activeModule: nil,
            sourceModuleResolver: { _ in nil },
            genericSourceResolver: { _, _ in nil },
            bookCatalog: BibleReaderBookCatalog(activeModule: nil, moduleBookList: []),
            unlabeledLabelID: Label.unlabeledId.uuidString
        )

        let payload = try bridgeJSONObject(factory.genericBookmarkJSONForStudyPad(bookmark))

        XCTAssertEqual(payload["bookInitials"] as? String, input.bookInitials)
        XCTAssertEqual(payload["bookName"] as? String, input.bookInitials)
        XCTAssertEqual(payload["bookAbbreviation"] as? String, input.bookInitials)
        XCTAssertEqual(payload["key"] as? String, input.key)
        XCTAssertEqual(payload["keyName"] as? String, input.key)
        XCTAssertEqual(payload["text"] as? String, "")
        XCTAssertEqual(payload["fullText"] as? String, "")
        XCTAssertTrue(payload["osisFragment"] is NSNull)
        XCTAssertFalse(String(describing: payload).contains(input.activeBookInitials))
    }

    /**
     Verifies generic deletion follows Android's `BookmarksDeletedEvent` route into Vue.

     - Setup: Persists the fixture bookmark, calls the public reader delegate deletion method, and
       parses the resulting recording-bridge emission.
     - Expected result: `delete_bookmarks` contains exactly the deleted UUID and the SwiftData row is
       absent immediately afterward.
     - Side effects: Mutates only an in-memory bookmark store and records bridge JavaScript.
     - Failure modes: A failure means Vue can retain a deleted generic annotation until a full page
       reload even though native persistence succeeded.
     */
    @MainActor
    func testGenericDeletionEmitsParsedVueMessageAndRemovesModel() throws {
        let input = try loadBookmarkBehaviorParityAndroidFixture().genericSelection
        let id = try XCTUnwrap(UUID(uuidString: input.id))
        let container = try makeBookmarkBehaviorParityModelContainer()
        let modelContext = ModelContext(container)
        let store = BookmarkStore(modelContext: modelContext)
        let service = BookmarkService(store: store)
        let bookmark = GenericBookmark(
            id: id,
            key: input.key,
            bookInitials: input.bookInitials,
            ordinalStart: input.ordinalStart,
            ordinalEnd: input.ordinalEnd,
            wholeVerse: input.wholeVerse
        )
        store.insert(bookmark)
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)
        controller.bookmarkService = service

        controller.bridge(bridge, removeGenericBookmark: id.uuidString)

        XCTAssertEqual(
            try XCTUnwrap(
                bridgeEmissionPayload(from: recordedScripts(), event: "delete_bookmarks") as? [String]
            ),
            [id.uuidString]
        )
        XCTAssertNil(service.genericBookmark(id: id))
    }

    /**
     Verifies Android DAO ordering across same-verse offsets, last-updated timestamps, selected-label
     order numbers, and generic bookmarks whose ordinals are nullable.

     - Setup: Builds Bible and generic list rows from the shared fixture, including a nil-offset Bible
       row and whole-page generic rows with nil ordinals.
     - Expected result: SQLite-style nil offsets sort first in both Bible directions, `LAST_UPDATED`
       is ascending, selected-label `ORDER_NUMBER` wins, Bible rows precede generic rows, and generic
       rows always use `bookInitials,key` order without synthesizing ordinal zero.
     - Side effects: Creates unsaved model objects only.
     - Failure modes: A failure means the visible iOS list disagrees with Android `BookmarksDao` or
       nullable generic ordinals leak into presentation as fake addresses.
     */
    func testBookmarkListProjectionMatchesAndroidOffsetOrderNumberAndNullableGenericOrdering() throws {
        let fixture = try loadBookmarkBehaviorParityAndroidFixture()
        let firstInput = fixture.sameStartBibleHighlights[0]
        let secondInput = fixture.sameStartBibleHighlights[1]
        let nilOffsetID = UUID(uuidString: "a2000000-0000-0000-0000-000000000000")!
        let firstID = try XCTUnwrap(UUID(uuidString: firstInput.id))
        let secondID = try XCTUnwrap(UUID(uuidString: secondInput.id))
        let nilOffset = bibleListItem(id: nilOffsetID, ordinal: 4, startOffset: nil)
        let first = bibleListItem(id: firstID, ordinal: 4, startOffset: firstInput.startOffset)
        let second = bibleListItem(id: secondID, ordinal: 4, startOffset: secondInput.startOffset)

        XCTAssertEqual(
            projectedIDs([second, nilOffset, first], sortOrder: .bibleOrder),
            [nilOffsetID, firstID, secondID]
        )
        XCTAssertEqual(
            projectedIDs([first, nilOffset, second], sortOrder: .bibleOrderDesc),
            [nilOffsetID, secondID, firstID]
        )

        let updatedIDs = try fixture.sorting.lastUpdatedAscending.map { try XCTUnwrap(UUID(uuidString: $0)) }
        let older = bibleListItem(
            id: updatedIDs[0],
            ordinal: 4,
            lastUpdatedOn: Date(timeIntervalSince1970: 100)
        )
        let newer = bibleListItem(
            id: updatedIDs[1],
            ordinal: 5,
            lastUpdatedOn: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(projectedIDs([newer, older], sortOrder: .lastUpdated), updatedIDs)

        let label = Label(name: "Fixture Label")
        let orderedIDs = try fixture.sorting.labelOrderNumberAscending.map { try XCTUnwrap(UUID(uuidString: $0)) }
        // Android BookmarksDao.orderBy2 orders BibleBookmarkToLabel.orderNumber ascending.
        let earlierOrder = bibleListItem(id: orderedIDs[0], ordinal: 4, label: label, orderNumber: 2)
        let laterOrder = bibleListItem(id: orderedIDs[1], ordinal: 5, label: label, orderNumber: 9)
        XCTAssertEqual(
            BookmarkListProjection.filteredItems(
                [earlierOrder, laterOrder],
                selectedLabelId: label.id,
                searchText: "",
                sortOrder: .orderNumber
            ).map(\.id),
            orderedIDs
        )

        let genericB = genericListItem(
            id: UUID(uuidString: "a2000000-0000-0000-0000-000000000042")!,
            initials: "Z-DICT",
            key: "Beta"
        )
        let genericA = genericListItem(
            id: UUID(uuidString: "a2000000-0000-0000-0000-000000000041")!,
            initials: "A-DICT",
            key: "Alpha"
        )
        let mixed = BookmarkListProjection.filteredItems(
            [genericB, genericA, newer],
            selectedLabelId: nil,
            searchText: "",
            sortOrder: .createdAtDesc
        )
        XCTAssertEqual(mixed.map(\.id), [updatedIDs[1], genericA.id, genericB.id])
        if case .generic(let firstGeneric) = mixed[1].source {
            XCTAssertNil(firstGeneric.ordinalStart)
            XCTAssertNil(firstGeneric.ordinalEnd)
        } else {
            XCTFail("Expected the second partition row to remain a generic bookmark")
        }
    }

    /** Builds an action coordinator with a strict KJV-to-KJVA persistence resolver. */
    private func makeBookmarkActionCoordinator(
        service: BookmarkService
    ) -> BibleReaderBookmarkActionCoordinator {
        BibleReaderBookmarkActionCoordinator(
            bookmarkService: service,
            payloadFactory: BibleReaderAnnotationPayloadFactory(
                currentBook: "Genesis",
                activeModuleName: "KJV",
                activeModule: nil,
                bookCatalog: BibleReaderBookCatalog(activeModule: nil, moduleBookList: []),
                unlabeledLabelID: Label.unlabeledId.uuidString
            ),
            currentBook: "Genesis",
            verifiedKJVAOrdinalRange: { initials, start, end in
                VerifiedKJVAOrdinalRange(
                    resolvingSourceBookInitials: initials,
                    sourceVersification: "KJV",
                    sourceOrdinalStart: start,
                    sourceOrdinalEnd: end
                )
            },
            currentNotesContentType: { "HTML" }
        )
    }

    /**
     Builds the production bridge coordinator with inert workspace callbacks.

     - Parameters:
       - bridge: Recording bridge that receives parsed-contract events.
       - service: In-memory bookmark persistence facade.
       - payloadFactory: Stored-source-aware payload projector.
     - Returns: Coordinator ready to apply bookmark actions.
     - Side effects: None during construction; returned actions mutate `service` and emit on `bridge`.
     - Failure modes: The injected KJV resolver returns `nil` for invalid fixture ordinals.
     */
    private func makeAnnotationBridgeCoordinator(
        bridge: BibleBridge,
        service: BookmarkService,
        payloadFactory: BibleReaderAnnotationPayloadFactory
    ) -> BibleReaderAnnotationBridgeCoordinator {
        BibleReaderAnnotationBridgeCoordinator(
            bridge: bridge,
            bookmarkService: service,
            payloadFactory: payloadFactory,
            currentBook: "Genesis",
            verifiedKJVAOrdinalRange: { initials, start, end in
                VerifiedKJVAOrdinalRange(
                    resolvingSourceBookInitials: initials,
                    sourceVersification: "KJV",
                    sourceOrdinalStart: start,
                    sourceOrdinalEnd: end
                )
            },
            currentNotesContentType: { "HTML" },
            workspaceSettings: { nil },
            setWorkspaceSettings: { _ in },
            persistState: {},
            incrementMyNotesRevision: {},
            incrementStudyPadRevision: {},
            trackRecentLabel: { _ in },
            sendLabels: {},
            buildConfigJSON: { "{}" }
        )
    }

    /**
     Extracts the sole updated Bible bookmark UUID from an action result.

     - Parameter result: Result returned by a fixture create/update action.
     - Returns: UUID carried by the first `bookmarksUpdated` payload.
     - Side effects: May record an XCTest failure through unwrap helpers.
     - Failure modes: Throws when event shape or UUID text does not match the production contract.
     */
    private func bibleBookmarkID(from result: BibleReaderBookmarkActionResult) throws -> UUID {
        guard case .bookmarksUpdated(let payloads) = result.events.first else {
            XCTFail("Expected a bookmarksUpdated action event")
            throw BookmarkBehaviorParityTestError.missingUpdatedBookmark
        }
        return try XCTUnwrap(UUID(uuidString: try XCTUnwrap(payloads.first?.id)))
    }

    /**
     Builds one Bible list item with fixture-controlled offsets, timestamps, and label order.

     - Returns: Unsaved row projected through the same initializer used by `BookmarkListView`.
     - Side effects: May attach an unsaved bookmark-to-label relationship.
     - Failure modes: This fixture builder cannot fail.
     */
    private func bibleListItem(
        id: UUID,
        ordinal: Int,
        startOffset: Int? = nil,
        lastUpdatedOn: Date = Date(timeIntervalSince1970: 100),
        label: Label? = nil,
        orderNumber: Int = -1
    ) -> BookmarkListItem {
        let bookmark = BibleBookmark(
            id: id,
            kjvOrdinalStart: ordinal,
            kjvOrdinalEnd: ordinal,
            ordinalStart: ordinal,
            ordinalEnd: ordinal,
            v11n: "KJVA",
            createdAt: Date(timeIntervalSince1970: 100),
            lastUpdatedOn: lastUpdatedOn
        )
        bookmark.book = "Genesis"
        bookmark.startOffset = startOffset
        if let label {
            let link = BibleBookmarkToLabel(orderNumber: orderNumber)
            link.bookmark = bookmark
            link.label = label
            bookmark.bookmarkToLabels = [link]
        }
        return BookmarkListItem(bibleBookmark: bookmark)
    }

    /**
     Builds a whole-page generic list item with Room-v12 nullable ordinals.

     - Returns: Unsaved generic row projected through the visible list initializer.
     - Side effects: None outside the returned in-memory object graph.
     - Failure modes: This fixture builder cannot fail.
     */
    private func genericListItem(id: UUID, initials: String, key: String) -> BookmarkListItem {
        BookmarkListItem(
            genericBookmark: GenericBookmark(
                id: id,
                key: key,
                bookInitials: initials,
                createdAt: Date(timeIntervalSince1970: 1_000),
                ordinalStart: nil,
                ordinalEnd: nil,
                lastUpdatedOn: Date(timeIntervalSince1970: 1_000),
                wholeVerse: true
            )
        )
    }

    /** Returns visible row UUIDs after applying one list sort with no filters. */
    private func projectedIDs(
        _ items: [BookmarkListItem],
        sortOrder: BookmarkSortOrder
    ) -> [UUID] {
        BookmarkListProjection.filteredItems(
            items,
            selectedLabelId: nil,
            searchText: "",
            sortOrder: sortOrder
        ).map(\.id)
    }
}

/** Error used when an action-result fixture does not contain its promised update event. */
private enum BookmarkBehaviorParityTestError: Error {
    /// The action result omitted a bookmark-update payload.
    case missingUpdatedBookmark
}

/** Decoded Android behavior fixture shared by bookmark parity tests. */
private struct BookmarkBehaviorParityAndroidFixture: Decodable {
    /// Android fixed-label identifiers and authority values.
    let fixedLabelIDs: BookmarkBehaviorParityFixedLabelIDs
    /// Distinct partial highlights that intentionally share one starting verse.
    let sameStartBibleHighlights: [BookmarkBehaviorParityBibleHighlightFixture]
    /// Generic stored-source selection and expected bridge text.
    let genericSelection: BookmarkBehaviorParityGenericSelectionFixture
    /// Android DAO result ordering.
    let sorting: BookmarkBehaviorParitySortingFixture
}

/** Android's four reserved bookmark label identifiers. */
private struct BookmarkBehaviorParityFixedLabelIDs: Decodable {
    /// Speak label UUID text.
    let speak: String
    /// Unlabeled label UUID text.
    let unlabeled: String
    /// Paragraph-break label UUID text.
    let paragraphBreak: String
    /// AI label UUID text.
    let ai: String
}

/** One Android-valid partial Bible highlight input. */
private struct BookmarkBehaviorParityBibleHighlightFixture: Decodable {
    /// Stable fixture UUID text.
    let id: String
    /// Shared KJVA starting ordinal.
    let kjvaOrdinalStart: Int
    /// UTF-16 selection start.
    let startOffset: Int
    /// UTF-16 selection end.
    let endOffset: Int
}

/** One generic selection, stored source, and bridge-text oracle. */
private struct BookmarkBehaviorParityGenericSelectionFixture: Decodable {
    /// Stable fixture UUID text.
    let id: String
    /// Persisted source document initials.
    let bookInitials: String
    /// Deliberately unrelated active document initials.
    let activeBookInitials: String
    /// Persisted source key.
    let key: String
    /// First source ordinal.
    let ordinalStart: Int
    /// Last source ordinal.
    let ordinalEnd: Int
    /// UTF-16 selection start.
    let startOffset: Int
    /// UTF-16 selection end.
    let endOffset: Int
    /// Android whole-entry selection flag.
    let wholeVerse: Bool
    /// Stored-source metadata and content.
    let source: BookmarkBehaviorParityGenericSourceFixture
    /// Android text projection oracle.
    let expected: BookmarkBehaviorParityGenericExpectedTextFixture
}

/** Stored generic source metadata and render content. */
private struct BookmarkBehaviorParityGenericSourceFixture: Decodable {
    /// Display document name.
    let bookName: String
    /// Compact document abbreviation.
    let bookAbbreviation: String
    /// Display key name.
    let keyName: String
    /// Complete visible source text.
    let plainText: String
    /// Render fragment XML.
    let xml: String
}

/** Android `BookmarkControl.addText` output for the generic fixture. */
private struct BookmarkBehaviorParityGenericExpectedTextFixture: Decodable {
    /// Selected text.
    let text: String
    /// Reconstructed complete text.
    let fullText: String
    /// Complete text with the selection wrapped in bold markup.
    let highlightedText: String
}

/** Android DAO UUID order oracles used by list tests. */
private struct BookmarkBehaviorParitySortingFixture: Decodable {
    /// Oldest-to-newest UUIDs for `LAST_UPDATED`.
    let lastUpdatedAscending: [String]
    /// Lowest-to-highest selected-label junction order UUIDs.
    let labelOrderNumberAscending: [String]
}

/**
 Loads the shared Android bookmark behavior fixture from the repository root.

 - Returns: Typed fixture values used by behavior and parsed-bridge assertions.
 - Side effects: Reads one checked-in JSON file.
 - Failure modes: Throws filesystem or JSON decoding errors when fixture provenance or shape drifts.
 */
private func loadBookmarkBehaviorParityAndroidFixture() throws
    -> BookmarkBehaviorParityAndroidFixture {
    let sourceFile = URL(fileURLWithPath: #filePath)
    let repositoryRoot = (0..<5).reduce(sourceFile) { url, _ in
        url.deletingLastPathComponent()
    }
    let fixtureURL = repositoryRoot
        .appendingPathComponent("Tests")
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("android-bookmark-behavior-parity.json")
    return try JSONDecoder().decode(
        BookmarkBehaviorParityAndroidFixture.self,
        from: Data(contentsOf: fixtureURL)
    )
}

/**
 Creates a transient bookmark graph for bookmark behavior parity tests.

 - Returns: In-memory SwiftData container with every bookmark, label, and StudyPad entity.
 - Side effects: Allocates transient test storage only.
 - Failure modes: Throws when SwiftData cannot initialize the schema.
 */
private func makeBookmarkBehaviorParityModelContainer() throws -> ModelContainer {
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
    return try ModelContainer(
        for: schema,
        configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
    )
}
