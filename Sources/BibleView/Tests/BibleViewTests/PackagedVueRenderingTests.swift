import Foundation
import XCTest
@testable import BibleView

#if os(iOS)
import UIKit
import WebKit

/**
 Exercises the production packaged Vue renderer through an attached, real WKWebView.

 These tests own their synthetic source text and fixed ordinal identities. They do not use the
 native payload recorder, manually signal client readiness, or substitute Vue with a JavaScript
 stub. Passing proves rendered content and viewport behavior at the native/web boundary; it does
 not prove native source extraction, app navigation gestures, or physical-device performance.
 */
@MainActor
final class PackagedVueRenderingTests: XCTestCase {
    /**
     Verifies appended content survives a configuration change and receives a loaded-range jump.

     Uses two independently authored chapter payloads, awaits actual text and viewport geometry,
     and sends each action once. An incorrect clear/replacement or a dropped scroll fails even if
     JavaScript dispatch itself succeeds. Setup and teardown affect only an isolated native window.
     */
    func testAppendedChapterSurvivesConfigurationAndScrollsIntoView() async throws {
        let surface = Surface()
        defer { surface.close() }
        try await waitForClientReady(surface)

        XCTAssertTrue(surface.bridge.replaceDocument(
            configData: config(night: false, initial: true),
            documentData: try chapter(id: "first", chapter: 1, start: 1),
            setupData: setup(ordinal: 1)
        ))
        try await waitForVisibleVerse(1, text: "Fixture chapter 1 verse 1", in: surface.webView)

        XCTAssertTrue(surface.bridge.emit(
            event: "add_documents", data: try chapter(id: "second", chapter: 2, start: 101)
        ))
        try await waitUntil(surface.webView, expression:
            "document.querySelector('#doc-second #o-101')?.textContent.includes('Fixture chapter 2 verse 1') === true"
        )
        XCTAssertTrue(surface.bridge.emit(event: "set_config", data: config(night: true, initial: false)))
        XCTAssertTrue(surface.bridge.emit(
            event: "scroll_to_verse",
            data: #"{"ordinal":110,"now":true,"force":true,"highlight":true,"ordinalStart":110,"ordinalEnd":112,"bookInitials":"Fixture","osisRef":"Gen.2"}"#
        ))
        try await waitForVisibleVerse(110, text: "Fixture chapter 2 verse 10", in: surface.webView)
        try await waitUntil(surface.webView, expression: """
        Array.from(document.querySelectorAll('#doc-second .isHighlighted'))
            .map(e => e.closest('[data-ordinal]').dataset.ordinal).join(',') === '110,111,112'
        """)
        let retainedChapters = try await surface.webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.bible-document')).map(e => e.id).join(',')"
        ) as? String
        XCTAssertEqual(retainedChapters, "doc-first,doc-second")
        try await attachSnapshot(of: surface.webView, name: "appended-chapter-after-config-and-scroll")

        XCTAssertTrue(surface.bridge.emit(
            event: "scroll_to_verse",
            data: #"{"ordinal":101,"targetId":"doc-second","now":true,"force":true}"#
        ))
        try await waitUntil(surface.webView, expression: """
        (() => {
            const chapter = document.getElementById('doc-second');
            const r = chapter.getBoundingClientRect();
            return r.top >= -1 && r.top < 100 && chapter.innerText.includes('Fixture chapter 2 verse 1');
        })()
        """)
    }

    /**
     Verifies successive replacement requests leave only the newest document at its requested verse.

     Deliberately dispatches A, B and C before waiting for document preparation. Expectations inspect
     the final DOM identity, content and settled viewport rather than an internal generation token.
     */
    func testRapidReplacementsRenderOnlyLatestContentAtRequestedPosition() async throws {
        let surface = Surface()
        defer { surface.close() }
        try await waitForClientReady(surface)
        for (id, number, start) in [("old-a", 1, 1), ("old-b", 2, 101), ("current", 3, 201)] {
            XCTAssertTrue(surface.bridge.replaceDocument(
                configData: config(night: false, initial: true),
                documentData: try chapter(id: id, chapter: number, start: start),
                setupData: setup(ordinal: start + 9)
            ))
        }
        try await waitForVisibleVerse(210, text: "Fixture chapter 3 verse 10", in: surface.webView)
        let identity = try await surface.webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.bible-document')).map(e => e.id).join(',')"
        ) as? String
        XCTAssertEqual(identity, "doc-current")
        let text = try await surface.webView.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertFalse(text?.contains("Fixture chapter 1") ?? true)
        XCTAssertFalse(text?.contains("Fixture chapter 2") ?? true)
    }

    /**
     Verifies a commentary prepend held by an active touch preserves the rendered viewport.

     Each case loads the packaged production bundle, requests the previous commentary block through
     the visible manual control, and returns the payload through `BibleBridge.sendResponse`. The DOM
     is measured before the native response and after `touchend` or `touchcancel`; the existing marker
     must retain its actual WebKit viewport position while the prior block appears exactly once.
     */
    func testTouchHeldCommentaryPrependPreservesViewportOnReleaseAndCancellation() async throws {
        for releaseEvent in ["touchend", "touchcancel"] {
            try await assertTouchHeldCommentaryPrependPreservesViewport(releaseEvent: releaseEvent)
        }
    }

    /**
     Verifies replacement retires a resolved commentary prepend before the held touch is released.

     The native response is allowed to resolve and enter the touch-deferred state before one packaged
     replacement clears the document generation. Releasing with either touch terminal event must leave
     only the replacement DOM; the retired commentary block and prior document cannot reappear.
     */
    func testClearedTouchHeldCommentaryResponseCannotReviveOnReleaseOrCancellation() async throws {
        for releaseEvent in ["touchend", "touchcancel"] {
            try await assertClearedTouchHeldCommentaryResponseCannotRevive(releaseEvent: releaseEvent)
        }
    }

    /**
     Retains the real bridge readiness callback for one packaged-renderer fixture.

     The packaged surface intentionally has no BibleUI controller. Unused application callbacks are
     no-ops because these tests author all content and exercise only the web renderer lifecycle.
     */
    private final class ClientReadinessDelegate: BibleBridgeDelegate {
        var isReady = false

        func bridge(_ bridge: BibleBridge, didScrollToOrdinal ordinal: Int, key: String, atChapterTop: Bool) {}
        func bridge(_ bridge: BibleBridge, requestMoreToBeginning callId: Int) {}
        func bridge(_ bridge: BibleBridge, requestMoreToEnd callId: Int) {}
        func bridgeDidRequestGoToNextChapter(_ bridge: BibleBridge) {}
        func bridgeDidRequestGoToPreviousChapter(_ bridge: BibleBridge) {}
        func bridge(_ bridge: BibleBridge, addBookmark bookInitials: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool) {}
        func bridge(_ bridge: BibleBridge, addGenericBookmark bookInitials: String, osisRef: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool) {}
        func bridge(_ bridge: BibleBridge, createGenericWholePageBookmark request: GenericWholePageBookmarkRequest) {}
        func bridge(_ bridge: BibleBridge, addParagraphBreakBookmark bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}
        func bridge(_ bridge: BibleBridge, addGenericParagraphBreakBookmark bookInitials: String, osisRef: String, startOrdinal: Int, endOrdinal: Int) {}
        func bridge(_ bridge: BibleBridge, removeBookmark bookmarkId: String) {}
        func bridge(_ bridge: BibleBridge, removeGenericBookmark bookmarkId: String) {}
        func bridge(_ bridge: BibleBridge, saveBookmarkNote bookmarkId: String, note: String?) {}
        func bridge(_ bridge: BibleBridge, assignLabels bookmarkId: String) {}
        func bridge(_ bridge: BibleBridge, toggleBookmarkLabel bookmarkId: String, labelId: String) {}
        func bridge(_ bridge: BibleBridge, removeBookmarkLabel bookmarkId: String, labelId: String) {}
        func bridge(_ bridge: BibleBridge, setPrimaryLabel bookmarkId: String, labelId: String) {}
        func bridge(_ bridge: BibleBridge, setBookmarkWholeVerse bookmarkId: String, value: Bool) {}
        func bridge(_ bridge: BibleBridge, setBookmarkCustomIcon bookmarkId: String, value: String?) {}
        func bridge(_ bridge: BibleBridge, shareVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}
        func bridge(_ bridge: BibleBridge, shareBookmarkVerse bookmarkId: String) {}
        func bridge(_ bridge: BibleBridge, copyVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}
        func bridge(_ bridge: BibleBridge, compareVerses bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}
        func bridge(_ bridge: BibleBridge, speak bookInitials: String, v11n: String, startOrdinal: Int, endOrdinal: Int) {}
        func bridge(_ bridge: BibleBridge, speakGeneric bookInitials: String, osisRef: String, startOrdinal: Int, endOrdinal: Int) {}
        func bridge(_ bridge: BibleBridge, speakMemorizationLoop bookInitials: String, v11n: String, startOrdinal: Int, endOrdinal: Int) {}
        func bridge(_ bridge: BibleBridge, memorize bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}
        func bridge(_ bridge: BibleBridge, markAsMemorized bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}
        func bridge(_ bridge: BibleBridge, addMemorizationTarget bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}
        func bridge(_ bridge: BibleBridge, removeMemorizationTarget bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}
        func bridge(_ bridge: BibleBridge, unmarkMemorized bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}
        func bridge(_ bridge: BibleBridge, recordChapterRead bookInitials: String, startOrdinal: Int, chapter: Int, source: String) {}
        func bridge(_ bridge: BibleBridge, openChapterReadHistory bookInitials: String, startOrdinal: Int, chapter: Int) {}
        func bridge(_ bridge: BibleBridge, openReadingProgress tab: Int) {}
        func bridgeDidRequestOpenReadingProgressSettings(_ bridge: BibleBridge) {}
        func bridge(_ bridge: BibleBridge, setReadingProgressSettings json: String) {}
        func bridge(_ bridge: BibleBridge, unmarkChapterRead bookInitials: String, startOrdinal: Int, chapter: Int) {}
        func bridge(_ bridge: BibleBridge, getMyDocumentPageRawContent callId: Int, bookInitials: String, pageKey: String) {}
        func bridge(_ bridge: BibleBridge, copyMyDocumentContent bookInitials: String, pageKey: String) {}
        func bridge(_ bridge: BibleBridge, shareMyDocumentContent bookInitials: String, pageKey: String) {}
        func bridge(_ bridge: BibleBridge, saveMyDocumentPageContent bookInitials: String, pageId: String, content: String, title: String?) {}
        func bridge(_ bridge: BibleBridge, reloadMyDocumentPage bookInitials: String) {}
        func bridge(_ bridge: BibleBridge, regenerateMyDocumentPage pageId: String) {}
        func bridge(_ bridge: BibleBridge, deleteMyDocumentPage pageId: String) {}
        func bridge(_ bridge: BibleBridge, openStudyPad labelId: String, bookmarkId: String) {}
        func bridge(_ bridge: BibleBridge, openMyNotes v11n: String, ordinal: Int) {}
        func bridge(_ bridge: BibleBridge, openAIDocumentPage request: AIDocumentPageRequest) {}
        func bridge(_ bridge: BibleBridge, openExternalLink link: String) {}
        func bridgeDidRequestOpenDownloads(_ bridge: BibleBridge) {}
        func bridge(_ bridge: BibleBridge, refChooserDialog callId: Int) {}
        func bridge(_ bridge: BibleBridge, parseRef callId: Int, text: String) {}
        func bridge(_ bridge: BibleBridge, helpDialog content: String, title: String?) {}
        func bridgeDidRequestBookmarkHelp(_ bridge: BibleBridge) {}
        func bridge(_ bridge: BibleBridge, showHelp scope: BibleBridgeHelpScope) {}
        func bridge(_ bridge: BibleBridge, requestAIAction request: AISelectionActionRequest) {}
        func bridge(_ bridge: BibleBridge, requestNoteEditorAIAction request: AINoteEditorActionRequest) {}
        func bridge(_ bridge: BibleBridge, chooseAIDocumentPage markers: [AIDocumentPageMarker]) {}
        func bridge(_ bridge: BibleBridge, openPromptEditor promptID: UUID) {}
        func bridge(_ bridge: BibleBridge, selectionChanged text: String) {}
        func bridgeSelectionCleared(_ bridge: BibleBridge) {}
        func bridge(_ bridge: BibleBridge, createNewStudyPadEntry labelId: String, entryType: String, afterEntryId: String) {}
        func bridge(_ bridge: BibleBridge, deleteStudyPadEntry studyPadId: String) {}
        func bridge(_ bridge: BibleBridge, updateStudyPadTextEntry data: String) {}
        func bridge(_ bridge: BibleBridge, updateStudyPadTextEntryText id: String, text: String) {}
        func bridge(_ bridge: BibleBridge, updateOrderNumber labelId: String, data: String) {}
        func bridge(_ bridge: BibleBridge, updateBookmarkToLabel data: String) {}
        func bridge(_ bridge: BibleBridge, updateGenericBookmarkToLabel data: String) {}
        func bridge(_ bridge: BibleBridge, setBookmarkEditAction bookmarkId: String, value: String) {}
        func bridge(_ bridge: BibleBridge, setEditing enabled: Bool) {}
        func bridge(_ bridge: BibleBridge, setStudyPadCursor labelId: String, orderNumber: Int) {}
        func bridge(_ bridge: BibleBridge, saveState state: String) {}
        func bridgeDidSetClientReady(_ bridge: BibleBridge) { isReady = true }
        func bridge(_ bridge: BibleBridge, reportModalState isOpen: Bool) {}
        func bridge(_ bridge: BibleBridge, reportInputFocus focused: Bool) {}
        func bridge(_ bridge: BibleBridge, onKeyDown key: String) {}
        func bridge(_ bridge: BibleBridge, showToast text: String) {}
        func bridge(_ bridge: BibleBridge, shareHtml html: String) {}
        func bridge(_ bridge: BibleBridge, toggleCompareDocument documentId: String) {}
        func bridge(_ bridge: BibleBridge, openEpubLink bookInitials: String, toKey: String, toId: String) {}
        func bridgeDidRequestToggleFullScreen(_ bridge: BibleBridge) {}
    }

    /**
     Owns an attached production WebView for one test and releases its native window on completion.

     Uses the same bootstrap, coordinator, resource resolution and retained session as the app.
     WebKit may create its normal auxiliary process; no app data or modules are opened.
     */
    private final class Surface {
        let bridge = BibleBridge()
        let clientReadiness = ClientReadinessDelegate()
        let session: BibleWebViewSession
        let webView: WKWebView
        let window: UIWindow
        let controller: BibleWebViewController

        /** Creates and displays one isolated reader host; production bundle loading starts once. */
        init() {
            bridge.delegate = clientReadiness
            let newSession = BibleWebViewSession(bridge: bridge)
            session = newSession
            let representation = BibleWebView(session: newSession)
            webView = newSession.webView { representation.createWebView(coordinator: newSession.coordinator) }
            controller = BibleWebViewController(webView: webView, bridge: bridge, session: session)
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.isHidden = false
            controller.loadViewIfNeeded()
            controller.beginAppearanceTransition(true, animated: false)
            controller.endAppearanceTransition()
            controller.view.layoutIfNeeded()
        }

        /** Stops test navigation and releases the native attachment without changing application data. */
        func close() {
            webView.stopLoading()
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /** Exercises one real-WebKit touch terminal path for valid commentary prepend compensation. */
    private func assertTouchHeldCommentaryPrependPreservesViewport(releaseEvent: String) async throws {
        let surface = Surface()
        defer { surface.close() }
        try await waitForClientReady(surface)

        XCTAssertTrue(surface.bridge.replaceDocument(
            configData: manualNavigationConfig(initial: true),
            documentData: try commentary(id: "current", block: 2, start: 101),
            setupData: try setup(elementID: "v-110")
        ))
        try await waitForVisibleCommentaryEntry(
            110,
            text: "Fixture commentary 2 entry 10",
            in: surface.webView
        )
        let started = try await surface.webView.evaluateJavaScript("""
        (() => {
            const marker = document.getElementById('v-110');
            const load = document.querySelector('.chapter-nav.top button:nth-child(2)');
            if (!marker || !load) return false;
            window.__commentaryMarkerTop = marker.getBoundingClientRect().top;
            window.dispatchEvent(new Event('touchstart'));
            load.click();
            return true;
        })()
        """) as? Bool
        XCTAssertEqual(started, true, "Expected the packaged commentary control to start one request")
        try await waitUntil(surface.webView, expression:
            "document.querySelector('.chapter-nav.top button:nth-child(2)')?.disabled === true"
        )

        XCTAssertTrue(surface.bridge.sendResponse(
            callId: 0,
            value: try commentary(id: "previous", block: 1, start: 1)
        ))
        try await waitUntil(surface.webView, expression: """
        document.getElementById('doc-previous') === null
            && document.querySelector('.chapter-nav.top button:nth-child(2)')?.disabled === false
        """)

        let released = try await surface.webView.evaluateJavaScript(
            "window.dispatchEvent(new Event('\(releaseEvent)')); true"
        ) as? Bool
        XCTAssertEqual(released, true)
        try await waitUntil(surface.webView, expression: """
        (async () => {
            const marker = document.getElementById('v-110');
            const previous = document.getElementById('doc-previous');
            if (!marker || !previous) return false;
            await new Promise(requestAnimationFrame);
            await new Promise(requestAnimationFrame);
            return Math.abs(marker.getBoundingClientRect().top - window.__commentaryMarkerTop) < 1;
        })()
        """)

        let identities = try await surface.webView.evaluateJavaScript(
            "Array.from(document.querySelectorAll('.document')).map(e => e.id).join(',')"
        ) as? String
        XCTAssertEqual(identities, "doc-previous,doc-current")
        let markerTopValue = try await surface.webView.evaluateJavaScript(
            "document.getElementById('v-110').getBoundingClientRect().top"
        )
        let originalMarkerTopValue = try await surface.webView.evaluateJavaScript(
            "window.__commentaryMarkerTop"
        )
        let markerTop = try XCTUnwrap(markerTopValue as? NSNumber).doubleValue
        let originalMarkerTop = try XCTUnwrap(originalMarkerTopValue as? NSNumber).doubleValue
        XCTAssertEqual(markerTop, originalMarkerTop, accuracy: 1)
    }

    /** Exercises one real-WebKit terminal path after a deferred response loses its generation. */
    private func assertClearedTouchHeldCommentaryResponseCannotRevive(releaseEvent: String) async throws {
        let surface = Surface()
        defer { surface.close() }
        try await waitForClientReady(surface)

        XCTAssertTrue(surface.bridge.replaceDocument(
            configData: manualNavigationConfig(initial: true),
            documentData: try commentary(id: "retired", block: 2, start: 101),
            setupData: try setup(elementID: "v-110")
        ))
        try await waitForVisibleCommentaryEntry(
            110,
            text: "Fixture commentary 2 entry 10",
            in: surface.webView
        )
        let started = try await surface.webView.evaluateJavaScript("""
        (() => {
            const load = document.querySelector('.chapter-nav.top button:nth-child(2)');
            if (!load) return false;
            window.dispatchEvent(new Event('touchstart'));
            load.click();
            return true;
        })()
        """) as? Bool
        XCTAssertEqual(started, true)
        try await waitUntil(surface.webView, expression:
            "document.querySelector('.chapter-nav.top button:nth-child(2)')?.disabled === true"
        )

        XCTAssertTrue(surface.bridge.sendResponse(
            callId: 0,
            value: try commentary(id: "stale-previous", block: 1, start: 1)
        ))
        try await waitUntil(surface.webView, expression: """
        document.getElementById('doc-stale-previous') === null
            && document.querySelector('.chapter-nav.top button:nth-child(2)')?.disabled === false
        """)

        XCTAssertTrue(surface.bridge.replaceDocument(
            configData: manualNavigationConfig(initial: true),
            documentData: try commentary(id: "replacement", block: 3, start: 201),
            setupData: try setup(elementID: "v-210")
        ))
        try await waitForVisibleCommentaryEntry(
            210,
            text: "Fixture commentary 3 entry 10",
            in: surface.webView
        )
        _ = try await surface.webView.evaluateJavaScript(
            "window.dispatchEvent(new Event('\(releaseEvent)')); true"
        )
        try await waitUntil(surface.webView, expression: """
        (async () => {
            await new Promise(requestAnimationFrame);
            await new Promise(requestAnimationFrame);
            const ids = Array.from(document.querySelectorAll('.document')).map(e => e.id);
            return ids.join(',') === 'doc-replacement'
                && document.body.innerText.includes('Fixture commentary 3 entry 10')
                && !document.body.innerText.includes('Fixture commentary 1')
                && !document.body.innerText.includes('Fixture commentary 2');
        })()
        """)
    }

    /** Returns a complete independent Bible fixture in the shared Android client document shape. */
    private func chapter(id: String, chapter: Int, start: Int) throws -> String {
        let xml = "<div>" + (0..<25).map { offset in
            "<div><verse osisID=\"Gen.\(chapter).\(offset + 1)\" verseOrdinal=\"\(start + offset)\">"
                + "Fixture chapter \(chapter) verse \(offset + 1). "
                + String(repeating: "Visible reader content for viewport testing. ", count: 5)
                + "</verse></div>"
        }.joined() + "</div>"
        let fragment = OsisFragment(
            xml: xml, key: "Gen.\(chapter)", keyName: "Genesis \(chapter)", v11n: "KJV",
            bookInitials: "Fixture", osisRef: "Gen.\(chapter)", ordinalRange: [start, start + 24]
        )
        let fragmentObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fragment))
        let payload: [String: Any] = [
            "id": id, "type": "bible", "osisFragment": fragmentObject, "bookInitials": "Fixture",
            "bookCategory": "BIBLE", "bookAbbreviation": "Fixture", "bookName": "Fixture Bible",
            "key": "Gen.\(chapter)", "v11n": "KJV", "osisRef": "Gen.\(chapter)", "annotateRef": "",
            "genericBookmarks": [], "ordinalRange": [start, start + 24], "isNativeHtml": false,
            "bookmarks": [], "bibleBookName": "Genesis", "addChapter": true,
            "chapterNumber": chapter, "originalOrdinalRange": NSNull(),
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    /** Returns one ordinary non-AI commentary block in the shared Android OSIS document shape. */
    private func commentary(id: String, block: Int, start: Int) throws -> String {
        let xml = "<div>" + (0..<25).map { offset in
            "<div><verse osisID=\"Gen.\(block).\(offset + 1)\" verseOrdinal=\"\(start + offset)\">"
                + "Fixture commentary \(block) entry \(offset + 1). "
                + String(repeating: "Rendered commentary content for viewport testing. ", count: 5)
                + "</verse></div>"
        }.joined() + "</div>"
        let fragment = OsisFragment(
            xml: xml, key: "Gen.\(block)", keyName: "Commentary block \(block)", v11n: "KJV",
            bookInitials: "FixtureCommentary", osisRef: "Gen.\(block)",
            ordinalRange: [start, start + 24]
        )
        let fragmentObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fragment))
        let payload: [String: Any] = [
            "id": id, "type": "osis", "osisFragment": fragmentObject,
            "bookInitials": "FixtureCommentary", "bookCategory": "COMMENTARY",
            "bookAbbreviation": "Fixture commentary", "bookName": "Fixture commentary",
            "key": "Gen.\(block)", "v11n": "KJV", "osisRef": "Gen.\(block)",
            "annotateRef": "Gen.\(block)", "genericBookmarks": [],
            "ordinalRange": [start, start + 24], "isNativeHtml": false,
            "highlightedOrdinalRange": NSNull(), "isAiDocument": false,
            "commentaryRange": [
                "startOsisRef": "Gen.\(block).1", "endOsisRef": "Gen.\(block).25",
                "name": "Commentary block \(block)",
            ],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    }

    /** Returns presentation configuration without overriding production animation behavior. */
    private func config(night: Bool, initial: Bool) -> String {
        "{\"config\":{},\"appSettings\":{\"nightMode\":\(night),\"windowId\":\"render-test\"},\"initial\":\(initial)}"
    }

    /** Returns production config with Android's manual adjacent-content controls visible. */
    private func manualNavigationConfig(initial: Bool) -> String {
        "{\"config\":{\"infiniteScroll\":false},\"appSettings\":{\"nightMode\":false,\"windowId\":\"render-test\"},\"initial\":\(initial)}"
    }

    /** Returns the Android setup payload for the independently specified ordinal. */
    private func setup(ordinal: Int) -> String {
        "{\"jumpToOrdinal\":\(ordinal),\"topOffset\":0,\"bottomOffset\":0}"
    }

    /** Returns setup targeting an exact generic OSIS DOM marker rather than a Bible-only ordinal ID. */
    private func setup(elementID: String) throws -> String {
        let quotedID = String(decoding: try JSONEncoder().encode(elementID), as: UTF8.self)
        return "{\"jumpToId\":\(quotedID),\"topOffset\":0,\"bottomOffset\":0}"
    }

    /**
     Awaits real text with nonzero visible geometry across two animation frames at a stable position.

     The observer reads DOM geometry only; it never scrolls, focuses, or repeats the tested action.
     Throws after a bounded timeout so a missing render cannot pass as a successful dispatch.
     */
    private func waitForVisibleVerse(_ ordinal: Int, text: String, in webView: WKWebView) async throws {
        let quotedText = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        try await waitUntil(webView, expression: """
        (async () => {
            const element = document.getElementById('o-\(ordinal)');
            if (!element || !element.textContent.includes(\(quotedText))) return false;
            const r = element.getBoundingClientRect();
            if (!(r.width > 0 && r.height > 0 && r.top >= -1 && r.top < innerHeight && r.bottom > 0)) return false;
            await new Promise(requestAnimationFrame);
            await new Promise(requestAnimationFrame);
            return element.isConnected && Math.abs(element.getBoundingClientRect().top - r.top) < 1;
        })()
        """)
    }

    /**
     Awaits the packaged client's real bridge-ready message across cold WebKit process startup.

     Startup has its own bounded budget because a fresh simulator can spend most of the ordinary
     DOM assertion budget launching GPU and WebContent processes. Later rendered-content checks
     retain their narrower timeout and begin only after Vue has reported production readiness.
     */
    private func waitForClientReady(_ surface: Surface) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            if surface.clientReadiness.isReady { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        let diagnostics = (try? await surface.webView.callAsyncJavaScript(
            "return JSON.stringify({readyState: document.readyState, bridgeType: typeof window.bibleView?.emit, url: location.href});",
            arguments: [:], in: nil, contentWorld: .page
        )) as? String ?? "WebKit diagnostics unavailable"
        XCTFail("Timed out waiting for packaged client readiness: \(diagnostics)")
        throw NSError(domain: "PackagedVueRenderingTests.ClientReady", code: 1)
    }

    /**
     Awaits one visible generic OSIS verse wrapper using its production `v-<ordinal>` identity.

     Commentary is rendered by `OsisDocument`, whose verses intentionally lack Bible-only `o-*`
     anchor IDs. The observer uses the outer `v-*` wrapper, verifies text and nonzero WebKit geometry,
     and requires the viewport position to remain stable across two animation frames.
     */
    private func waitForVisibleCommentaryEntry(
        _ ordinal: Int,
        text: String,
        in webView: WKWebView
    ) async throws {
        let quotedText = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
        try await waitUntil(webView, expression: """
        (async () => {
            const element = document.getElementById('v-\(ordinal)');
            if (!element || !element.textContent.includes(\(quotedText))) return false;
            const r = element.getBoundingClientRect();
            if (!(r.width > 0 && r.height > 0 && r.top >= -1 && r.top < innerHeight && r.bottom > 0)) return false;
            await new Promise(requestAnimationFrame);
            await new Promise(requestAnimationFrame);
            return element.isConnected && Math.abs(element.getBoundingClientRect().top - r.top) < 1;
        })()
        """, diagnostics: """
        JSON.stringify((() => {
            const marker = document.getElementById('v-\(ordinal)');
            const rect = marker?.getBoundingClientRect();
            return {
                requestedMarker: 'v-\(ordinal)',
                markerConnected: marker?.isConnected ?? false,
                markerRect: rect ? {
                    top: rect.top, bottom: rect.bottom, width: rect.width, height: rect.height
                } : null,
                verseMarkerIDs: Array.from(document.querySelectorAll('[id^="v-"], [id^="o-"]'))
                    .slice(0, 60).map(element => element.id),
                documentIDs: Array.from(document.querySelectorAll('.document')).map(element => element.id),
                documentCategories: Array.from(document.querySelectorAll('.document'))
                    .map(element => element.dataset.bookCategory),
                scrollY: window.scrollY,
                innerHeight: window.innerHeight,
                infiniteScroll: window.bibleViewDebug?.config?.infiniteScroll,
            };
        })())
        """)
    }

    /**
     Polls a read-only DOM predicate while yielding the main actor.

     An optional read-only diagnostic expression is evaluated only after timeout so renderer-specific
     failures can report identity, geometry, and configuration without changing the interaction path.
     */
    private func waitUntil(
        _ webView: WKWebView,
        expression: String,
        diagnostics: String? = nil
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if (try? await webView.callAsyncJavaScript(
                "return await (\(expression));", arguments: [:], in: nil, contentWorld: .page
            )) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        let body = (try? await webView.evaluateJavaScript("document.body.innerText")) as? String ?? "no DOM"
        let diagnosticValue: String
        if let diagnostics {
            diagnosticValue = (try? await webView.callAsyncJavaScript(
                "return (\(diagnostics));", arguments: [:], in: nil, contentWorld: .page
            )) as? String ?? "diagnostics unavailable"
        } else {
            diagnosticValue = "no additional diagnostics requested"
        }
        XCTFail(
            "Timed out waiting for rendered content: \(expression)\n"
                + "Diagnostics: \(diagnosticValue)\n\(body.prefix(1500))"
        )
        throw NSError(domain: "PackagedVueRenderingTests", code: 1)
    }

    /** Retains the actual rendered viewport as supporting evidence, not an expected image snapshot. */
    private func attachSnapshot(of webView: WKWebView, name: String) async throws {
        let snapshot = try await webView.takeSnapshot(configuration: nil)
        let attachment = XCTAttachment(image: snapshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
