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
        try await waitUntil(surface.webView, expression: "typeof window.bibleView.emit === 'function'")

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
        try await waitUntil(surface.webView, expression: "typeof window.bibleView.emit === 'function'")
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
     Owns an attached production WebView for one test and releases its native window on completion.

     Uses the same bootstrap, coordinator, resource resolution and retained session as the app.
     WebKit may create its normal auxiliary process; no app data or modules are opened.
     */
    private final class Surface {
        let bridge = BibleBridge()
        let session: BibleWebViewSession
        let webView: WKWebView
        let window: UIWindow
        let controller: BibleWebViewController

        /** Creates and displays one isolated reader host; production bundle loading starts once. */
        init() {
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

    /** Returns presentation configuration without overriding production animation behavior. */
    private func config(night: Bool, initial: Bool) -> String {
        "{\"config\":{},\"appSettings\":{\"nightMode\":\(night),\"windowId\":\"render-test\"},\"initial\":\(initial)}"
    }

    /** Returns the Android setup payload for the independently specified ordinal. */
    private func setup(ordinal: Int) -> String {
        "{\"jumpToOrdinal\":\(ordinal),\"topOffset\":0,\"bottomOffset\":0}"
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

    /** Polls a read-only DOM predicate while yielding the main actor; fails with the current DOM. */
    private func waitUntil(_ webView: WKWebView, expression: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if (try? await webView.callAsyncJavaScript(
                "return await (\(expression));", arguments: [:], in: nil, contentWorld: .page
            )) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        let body = (try? await webView.evaluateJavaScript("document.body.innerText")) as? String ?? "no DOM"
        XCTFail("Timed out waiting for rendered content: \(expression)\n\(body.prefix(1500))")
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
