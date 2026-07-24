import XCTest
import BibleView
@testable import BibleUI

/**
 Protects the controller ownership boundary that keeps a window's rendered Vue client alive.

 `WindowManager` retains each `BibleReaderController` while its window is minimized. These tests
 avoid constructing WebKit and instead verify that the controller retains the exact supplied
 render session, then releases it when the controller lifetime ends.
 */
@MainActor
final class BibleReaderRenderSessionTests: XCTestCase {
    /**
     Verifies the pre-controller render seed cannot split bridge and WebView ownership.

     `BibleWindowPane` must render with the same bridge/session pair that it later gives the
     controller. A failure would let the first Vue client send callbacks to one bridge while the
     registered controller emits document events through another.
     */
    func testWindowRenderSeedPairsOneBridgeWithItsSession() {
        let seed = BibleWindowRenderSeed()

        XCTAssertTrue(seed.webViewSession.bridge === seed.bridge)
    }

    /**
     Verifies a pane controller adopts and owns the session used by its first SwiftUI render pass.

     The local strong session reference leaves scope after controller creation. The session must
     remain alive and preserve identity until the controller is released, after which it must
     deallocate. A failure means minimizing can either lose the cached WebView or leak it after the
     window closes.
     */
    func testControllerRetainsSuppliedRenderSessionOnlyForItsOwnLifetime() {
        let bridge = BibleBridge()
        weak var retainedSession: BibleWebViewSession?
        var controller: BibleReaderController?

        do {
            let session = BibleWebViewSession(bridge: bridge)
            retainedSession = session
            controller = BibleReaderController(
                bridge: bridge,
                webViewSession: session,
                initializesSword: false
            )

            XCTAssertTrue(controller?.webViewSession === session)
        }

        XCTAssertNotNil(retainedSession)
        controller = nil
        XCTAssertNil(retainedSession)
    }
}
