import WebKit
import XCTest
@testable import BibleView

/**
 Verifies Android-style per-window native WebView retention in the BibleView layer.

 The tests exercise the platform host resolver without loading the packaged Vue bundle. Stable
 host and coordinator identity is the deterministic contract needed for SwiftUI pane
 detach/reattach; document replay behavior remains covered by reader-controller bridge tests.
 */
@MainActor
final class BibleWebViewSessionTests: XCTestCase {
    /**
     Proves a render session creates one WebView and reuses it after a simulated reattach.

     Two resolver calls represent SwiftUI constructing the same window pane before and after
     minimization. The second factory must not execute, and the representable must return the
     coordinator retained by the session. A failure means restore can rebuild the `WKWebView`,
     restart Vue, and replay the document instead of reattaching rendered state.
     */
    func testSessionReusesWebViewAndCoordinatorAcrossRepresentableLifetimes() {
        let bridge = BibleBridge()
        let session = BibleWebViewSession(bridge: bridge)
        var hostCreationCount = 0

        let first = session.webView {
            hostCreationCount += 1
            return WKWebView()
        }
        let second = session.webView {
            hostCreationCount += 1
            return WKWebView()
        }
        let representableCoordinator = BibleWebView(session: session).makeCoordinator()

        XCTAssertTrue(first === second)
        XCTAssertEqual(hostCreationCount, 1)
        XCTAssertTrue(representableCoordinator === session.coordinator)
    }
}
