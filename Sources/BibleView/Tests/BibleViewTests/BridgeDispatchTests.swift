import XCTest
@testable import BibleView

/**
 BibleView bridge message parsing and dispatch classification coverage.

 These tests protect the raw Swift-to-Vue bridge contract before any BibleUI reader controller
 handles the messages. They intentionally live in `BibleViewTests` because `BibleBridge` owns the
 request classification, malformed-argument rejection, and passive-scroll focus behavior.
 */
final class BridgeDispatchTests: XCTestCase {
    func testBridgeCallIdRequestMappingMatchesWebClientContract() {
        let bridge = BibleBridge()

        XCTAssertEqual(
            bridge.callIdRequest(method: "requestMoreToBeginning", args: [41]),
            .request(.requestMoreToBeginning(41))
        )
        XCTAssertEqual(
            bridge.callIdRequest(method: "requestMoreToEnd", args: [42]),
            .request(.requestMoreToEnd(42))
        )
        XCTAssertEqual(
            bridge.callIdRequest(method: "refChooserDialog", args: [43]),
            .request(.refChooserDialog(43))
        )
        XCTAssertEqual(
            bridge.callIdRequest(method: "parseRef", args: [44, "Genesis 1:1"]),
            .request(.parseRef(callId: 44, text: "Genesis 1:1"))
        )
        XCTAssertEqual(
            bridge.callIdRequest(method: "getMyDocumentPageRawContent", args: [45, "MYDOC", "intro"]),
            .request(.getMyDocumentPageRawContent(callId: 45, bookInitials: "MYDOC", pageKey: "intro"))
        )

        for malformedRequest in malformedCallIdRequests {
            XCTAssertEqual(
                bridge.callIdRequest(method: malformedRequest.method, args: malformedRequest.args),
                .malformed,
                "Expected \(malformedRequest.method) to reject malformed args"
            )
        }

        XCTAssertNil(bridge.callIdRequest(method: "helpDialog", args: [46]))
    }

    func testBridgeCallIdDispatchClassifiesKnownMalformedMessages() {
        let bridge = BibleBridge()

        XCTAssertEqual(
            bridge.dispatchCallIdRequest(method: "requestMoreToBeginning", args: [41]),
            .handled
        )

        for malformedRequest in malformedCallIdRequests {
            XCTAssertEqual(
                bridge.dispatchCallIdRequest(method: malformedRequest.method, args: malformedRequest.args),
                .malformed,
                "Expected \(malformedRequest.method) to classify malformed args"
            )
        }

        XCTAssertEqual(bridge.dispatchCallIdRequest(method: "getMyDocumentPageRawContent", args: [45, "MYDOC", "intro"]), .handled)
        XCTAssertEqual(bridge.dispatchCallIdRequest(method: "helpDialog", args: [46]), .notCallIdRequest)
    }

    /**
     Protects exact Android-parity document action payload parsing before controller integration.

     The setup passes punctuation-sensitive module/key values to the same parsers used by dispatch.
     The expected requests must preserve both fields exactly and reject missing, extra, or mistyped
     arguments. A failure means native persistence/navigation could act on inferred reader state
     rather than the marker or page the user actually clicked. The test has no WebKit, persistence,
     or asynchronous side effects.
     */
    func testDocumentActionRequestsPreserveExactBridgePayloads() throws {
        let bridge = BibleBridge()

        XCTAssertEqual(
            try XCTUnwrap(
                bridge.genericWholePageBookmarkRequest(
                    args: ["COMM.Dict", "entry/alpha?x=1"]
                )
            ),
            GenericWholePageBookmarkRequest(
                sourceInitials: "COMM.Dict",
                sourceKey: "entry/alpha?x=1"
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(bridge.aiDocumentPageRequest(args: ["AI.Documents", "page:key/42"])),
            AIDocumentPageRequest(documentInitials: "AI.Documents", pageKey: "page:key/42")
        )

        XCTAssertNil(bridge.genericWholePageBookmarkRequest(args: ["COMM.Dict"]))
        XCTAssertNil(
            bridge.genericWholePageBookmarkRequest(
                args: ["COMM.Dict", "entry/alpha?x=1", "unexpected"]
            )
        )
        XCTAssertNil(bridge.genericWholePageBookmarkRequest(args: ["COMM.Dict", 42]))
        XCTAssertNil(bridge.aiDocumentPageRequest(args: ["AI.Documents"]))
        XCTAssertNil(bridge.aiDocumentPageRequest(args: ["AI.Documents", 42]))
        XCTAssertNil(bridge.aiDocumentPageRequest(args: ["AI.Documents", "page:key/42", "unexpected"]))
    }

    /**
     Verifies every Android AI-only bridge payload is typed, exact, and fail-closed.

     The fixture covers Bible and generic selections, note-editor JSON, marker chooser JSON,
     source-prompt UUIDs, and the sole allowlisted help scope. Expected values preserve exact source
     identity and normalize only Android's negative end-ordinal sentinel. Unknown help scopes,
     unknown note targets, malformed JSON, wrong argument types, and extra arguments must fail.
     The test performs no WebKit, persistence, Keychain, or network work.
     */
    func testAIBridgeRequestsPreservePayloadsAndRejectUnknownScopes() throws {
        let bridge = BibleBridge()
        let promptID = UUID(uuidString: "a1000000-0000-0000-0000-000000000099")!

        XCTAssertEqual(
            bridge.aiSelectionActionRequest(
                method: "llmAction",
                args: ["KJV", 101, -1, "selected text"]
            ),
            AISelectionActionRequest(
                bookInitials: "KJV",
                startOrdinal: 101,
                endOrdinal: 101,
                text: "selected text"
            )
        )
        XCTAssertEqual(
            bridge.aiSelectionActionRequest(
                method: "llmActionGeneric",
                args: ["COMM.Dict", "entry/alpha?x=1", 3, 7, "generic text"]
            ),
            AISelectionActionRequest(
                bookInitials: "COMM.Dict",
                osisRef: "entry/alpha?x=1",
                startOrdinal: 3,
                endOrdinal: 7,
                text: "generic text"
            )
        )
        XCTAssertEqual(
            bridge.aiNoteEditorActionRequest(
                args: [
                    #"{"entityType":"BOOKMARK_NOTE","entityId":"bookmark-id","currentText":"before","contentType":"MARKDOWN"}"#,
                ]
            ),
            AINoteEditorActionRequest(
                entityType: "BOOKMARK_NOTE",
                entityId: "bookmark-id",
                currentText: "before",
                contentType: "MARKDOWN"
            )
        )
        XCTAssertEqual(
            bridge.aiDocumentPageMarkers(
                args: [
                    #"[{"title":"First","documentInitials":"AI.Documents","pageKey":"page:key/42"}]"#,
                ]
            ),
            [
                AIDocumentPageMarker(
                    title: "First",
                    documentInitials: "AI.Documents",
                    pageKey: "page:key/42"
                ),
            ]
        )
        XCTAssertEqual(bridge.promptEditorRequest(args: [promptID.uuidString]), promptID)
        XCTAssertEqual(bridge.scopedHelpRequest(args: ["memorize"]), .memorize)

        XCTAssertNil(bridge.aiSelectionActionRequest(method: "llmAction", args: ["KJV", 101, -1]))
        XCTAssertNil(bridge.aiSelectionActionRequest(method: "llmActionGeneric", args: ["KJV", "Gen.1.1", 1, 1, "", true]))
        XCTAssertNil(
            bridge.aiNoteEditorActionRequest(
                args: [
                    #"{"entityType":"UNKNOWN","entityId":"bookmark-id","currentText":"","contentType":"HTML"}"#,
                ]
            )
        )
        XCTAssertNil(bridge.aiNoteEditorActionRequest(args: ["not-json"]))
        XCTAssertNil(bridge.aiDocumentPageMarkers(args: [#"[{"title":"Missing target"}]"#]))
        XCTAssertNil(bridge.promptEditorRequest(args: ["not-a-uuid"]))
        XCTAssertNil(bridge.scopedHelpRequest(args: ["unknown"]))
        XCTAssertNil(bridge.scopedHelpRequest(args: ["memorize", "unexpected"]))
        XCTAssertNil(bridge.scopedHelpRequest(args: [7]))
    }

    func testBridgeMessageDispatchClassifiesKnownMalformedMessages() {
        let bridge = BibleBridge()

        for malformedMessage in malformedBridgeMessages {
            XCTAssertEqual(
                bridge.dispatchMessage(method: malformedMessage.method, args: malformedMessage.args),
                .malformed,
                "Expected \(malformedMessage.method) to classify malformed args"
            )
        }

        XCTAssertEqual(bridge.dispatchMessage(method: "shareBookmarkVerse", args: ["bookmark-id"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "copyMyDocumentContent", args: ["MYDOC", "intro"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "shareMyDocumentContent", args: ["MYDOC", "intro"]), .handled)
        XCTAssertEqual(
            bridge.dispatchMessage(method: "saveMyDocumentPageContent", args: ["MYDOC", "page-id", "content", NSNull()]),
            .handled
        )
        XCTAssertEqual(
            bridge.dispatchMessage(method: "saveMyDocumentPageContent", args: ["MYDOC", "page-id", "content", "Renamed"]),
            .handled
        )
        XCTAssertEqual(bridge.dispatchMessage(method: "reloadMyDocumentPage", args: ["MYDOC"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "regenerateMyDocumentPage", args: ["page-id"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "deleteMyDocumentPage", args: ["page-id"]), .handled)
        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "createWholePageBookmark",
                args: ["COMM.Dict", "entry/alpha?x=1"]
            ),
            .handled
        )
        XCTAssertEqual(bridge.dispatchMessage(method: "openAiDocPage", args: ["AI.Documents", "page:key/42"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "llmAction", args: ["KJV", 1, -1, "text"]), .handled)
        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "llmActionGeneric",
                args: ["COMM.Dict", "entry", 1, -1, "text"]
            ),
            .handled
        )
        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "noteEditorLlmAction",
                args: [#"{"entityType":"STUDYPAD_TEXT","entityId":"entry-id","currentText":"text","contentType":"MARKDOWN"}"#]
            ),
            .handled
        )
        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "openAiDocPageChooser",
                args: [#"[{"title":"First","documentInitials":"AI.Documents","pageKey":"page-1"}]"#]
            ),
            .handled
        )
        XCTAssertEqual(
            bridge.dispatchMessage(
                method: "openPromptEditor",
                args: ["a1000000-0000-0000-0000-000000000099"]
            ),
            .handled
        )
        XCTAssertEqual(bridge.dispatchMessage(method: "showHelpDialog", args: ["memorize"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "createWholePageBookmark", args: ["COMM.Dict"]), .malformed)
        XCTAssertEqual(bridge.dispatchMessage(method: "openAiDocPage", args: ["AI.Documents"]), .malformed)
        XCTAssertEqual(bridge.dispatchMessage(method: "llmAction", args: ["KJV", 1, -1]), .malformed)
        XCTAssertEqual(bridge.dispatchMessage(method: "noteEditorLlmAction", args: ["not-json"]), .malformed)
        XCTAssertEqual(bridge.dispatchMessage(method: "openAiDocPageChooser", args: ["not-json"]), .malformed)
        XCTAssertEqual(bridge.dispatchMessage(method: "openPromptEditor", args: ["not-a-uuid"]), .malformed)
        XCTAssertEqual(bridge.dispatchMessage(method: "showHelpDialog", args: ["unknown"]), .malformed)
        XCTAssertEqual(bridge.dispatchMessage(method: "showHelpDialog", args: []), .malformed)
        XCTAssertEqual(bridge.dispatchMessage(method: "saveBookmarkNote", args: ["bookmark-id", NSNull()]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "helpDialog", args: ["content", NSNull()]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "scrolledToOrdinal", args: ["main", 1]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "helpBookmarks", args: []), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "speakMemorizationLoop", args: ["KJV", "KJV", 1, -1]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "memorize", args: ["KJV", 1, -1]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "recordChapterRead", args: ["KJV", 1, 1, "AUTO_SCROLL"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "markChapterRead", args: ["KJV", 1, 1, "MANUAL"]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "openChapterReadHistory", args: ["KJV", 1, 1]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "openReadingProgress", args: [1]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "openReadingProgressSettings", args: []), .handled)
        XCTAssertEqual(
            bridge.dispatchMessage(method: "setReadingProgressSettings", args: [#"{"autoMarkMemorized":true}"#]),
            .handled
        )
        XCTAssertEqual(bridge.dispatchMessage(method: "unmarkChapterRead", args: ["KJV", 1, 1]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "goToNextChapter", args: []), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "goToPreviousChapter", args: []), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "addParagraphBreakBookmark", args: ["KJV", 1, -1]), .handled)
        XCTAssertEqual(
            bridge.dispatchMessage(method: "addGenericParagraphBreakBookmark", args: ["KJV", "Gen.1.1", 1, -1]),
            .handled
        )
        XCTAssertEqual(bridge.dispatchMessage(method: "missingMethod", args: []), .unhandled)
    }

    /**
     Protects the Android-parity focus contract for passive scroll maintenance messages.

     Android treats visible-position and infinite-scroll callbacks from the web document as
     document maintenance, while native touch/drag callbacks decide which pane is active. The
     setup registers an interaction observer on the bridge and dispatches passive scroll messages
     followed by an active selection message. The expected result is that scroll maintenance
     remains handled without invoking the focus observer; a failure means synchronized secondary
     panes can steal focus before the reader controller can suppress rebroadcast.
     */
    func testScrolledToOrdinalBridgeMessageDoesNotReportInteraction() {
        let bridge = BibleBridge()
        var interactionCount = 0
        bridge.onAnyMessage = {
            interactionCount += 1
        }

        XCTAssertEqual(bridge.dispatchMessage(method: "scrolledToOrdinal", args: ["Gen.1", 1, false]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "requestMoreToBeginning", args: [41]), .handled)
        XCTAssertEqual(bridge.dispatchMessage(method: "requestMoreToEnd", args: [42]), .handled)
        XCTAssertEqual(interactionCount, 0)

        XCTAssertEqual(bridge.dispatchMessage(method: "selectionChanged", args: ["In the beginning"]), .handled)
        XCTAssertEqual(interactionCount, 1)
    }
}

private let malformedCallIdRequests: [(method: String, args: [Any])] = [
    ("requestMoreToBeginning", []),
    ("requestMoreToBeginning", ["41"]),
    ("requestMoreToEnd", []),
    ("requestMoreToEnd", ["42"]),
    ("refChooserDialog", []),
    ("refChooserDialog", ["43"]),
    ("parseRef", [44]),
    ("parseRef", ["Genesis 1:1", 44]),
    ("getMyDocumentPageRawContent", [45, "MYDOC"]),
    ("getMyDocumentPageRawContent", ["MYDOC", "intro", 45]),
]

private let malformedBridgeMessages: [(method: String, args: [Any])] = [
    ("jsLog", ["WARN"]),
    ("toast", []),
    ("reportModalState", []),
    ("reportInputFocus", []),
    ("setLimitAmbiguousModalSize", []),
    ("selectionChanged", []),
    ("setEditing", []),
    ("saveState", []),
    ("onKeyDown", []),
    ("scrolledToOrdinal", ["main"]),
    ("scrolledToOrdinal", ["main", 1, "true"]),
    ("addBookmark", ["KJV", 1, 1]),
    ("addGenericBookmark", ["KJV", "Gen.1.1", 1, 1]),
    ("removeBookmark", []),
    ("removeGenericBookmark", []),
    ("saveBookmarkNote", []),
    ("saveBookmarkNote", ["bookmark-id", 7]),
    ("saveGenericBookmarkNote", []),
    ("saveGenericBookmarkNote", ["bookmark-id", 7]),
    ("assignLabels", []),
    ("genericAssignLabels", []),
    ("toggleBookmarkLabel", ["bookmark-id"]),
    ("toggleGenericBookmarkLabel", ["bookmark-id"]),
    ("removeBookmarkLabel", ["bookmark-id"]),
    ("removeGenericBookmarkLabel", ["bookmark-id"]),
    ("setAsPrimaryLabel", ["bookmark-id"]),
    ("setAsPrimaryLabelGeneric", ["bookmark-id"]),
    ("setBookmarkWholeVerse", ["bookmark-id"]),
    ("setGenericBookmarkWholeVerse", ["bookmark-id"]),
    ("setBookmarkCustomIcon", []),
    ("setBookmarkCustomIcon", ["bookmark-id", 7]),
    ("setGenericBookmarkCustomIcon", []),
    ("setGenericBookmarkCustomIcon", ["bookmark-id", 7]),
    ("shareVerse", ["KJV", 1]),
    ("copyVerse", ["KJV", 1]),
    ("copyMyDocumentContent", ["MYDOC"]),
    ("shareMyDocumentContent", ["MYDOC"]),
    ("saveMyDocumentPageContent", ["MYDOC", "page-id"]),
    ("saveMyDocumentPageContent", ["MYDOC", "page-id", "content", 7]),
    ("reloadMyDocumentPage", []),
    ("regenerateMyDocumentPage", []),
    ("deleteMyDocumentPage", []),
    ("shareBookmarkVerse", [["id": "bookmark-id"]]),
    ("compare", ["KJV", 1]),
    ("speak", ["KJV", "KJV", 1]),
    ("speakGeneric", ["KJV", "Gen.1.1", 1]),
    ("speakMemorizationLoop", ["KJV", "KJV", 1]),
    ("memorize", ["KJV", 1]),
    ("markAsMemorized", ["KJV", 1]),
    ("addMemorizationTarget", ["KJV", 1]),
    ("removeMemorizationTarget", ["KJV", 1]),
    ("unmarkMemorized", ["KJV", 1]),
    ("recordChapterRead", ["KJV", 1, 1]),
    ("recordChapterRead", ["KJV", 1, 1, 7]),
    ("markChapterRead", ["KJV", 1, 1]),
    ("markChapterRead", ["KJV", 1, 1, 7]),
    ("openChapterReadHistory", ["KJV", 1]),
    ("openChapterReadHistory", ["KJV", 1, "1"]),
    ("openReadingProgress", []),
    ("openReadingProgress", ["1"]),
    ("openReadingProgressSettings", [1]),
    ("setReadingProgressSettings", []),
    ("setReadingProgressSettings", [["autoMarkMemorized": true]]),
    ("unmarkChapterRead", ["KJV", 1]),
    ("unmarkChapterRead", ["KJV", 1, "1"]),
    ("goToNextChapter", [1]),
    ("goToPreviousChapter", [1]),
    ("addParagraphBreakBookmark", ["KJV", 1]),
    ("addGenericParagraphBreakBookmark", ["KJV", "Gen.1.1", 1]),
    ("openStudyPad", ["label-id"]),
    ("openMyNotes", ["KJV"]),
    ("deleteStudyPadEntry", []),
    ("createNewStudyPadEntry", ["label-id", "journal"]),
    ("setStudyPadCursor", ["label-id"]),
    ("updateOrderNumber", ["label-id"]),
    ("updateStudyPadTextEntry", []),
    ("updateStudyPadTextEntryText", ["entry-id"]),
    ("updateBookmarkToLabel", []),
    ("updateGenericBookmarkToLabel", []),
    ("setBookmarkEditAction", ["bookmark-id"]),
    ("openExternalLink", []),
    ("openEpubLink", ["module", "key"]),
    ("toggleCompareDocument", []),
    ("helpDialog", []),
    ("helpDialog", ["content", 7]),
    ("shareHtml", []),
]
