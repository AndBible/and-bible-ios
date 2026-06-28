import XCTest
@testable import BibleView

#if os(iOS)
import UIKit
import WebKit

/**
 BibleView bridge behavior that requires iOS WebKit/UIKit types.

 These tests protect bridge lifecycle, native user-interaction reporting, and JavaScript emission
 contracts without booting the app host or importing BibleUI. They intentionally live in
 `BibleViewTests` because the behavior under test is owned by the view bridge layer.
 */
final class BridgeIOSTests: XCTestCase {
    @MainActor
    func testBridgeBindsWeakWebViewReferenceFromLifecycleCallbacks() {
        let bridge = BibleBridge()
        let webView = WKWebView()

        bridge.bindWebView(webView)

        XCTAssertTrue(bridge.webView === webView)
    }

    @MainActor
    func testWebViewCoordinatorInstallsPassiveTapRecognizerForNativeFocus() {
        let bridge = BibleBridge()
        let coordinator = WebViewCoordinator(bridge: bridge)
        let webView = UIView()

        coordinator.installSwipeRecognizersIfNeeded(on: webView)

        let passiveTap = webView.gestureRecognizers?
            .compactMap { $0 as? UITapGestureRecognizer }
            .first { gesture in
                !gesture.cancelsTouchesInView && gesture.delegate === coordinator
            }
        XCTAssertNotNil(passiveTap)
    }

    @MainActor
    func testWebViewCoordinatorReportsNativeTapAndDragAsInteraction() {
        let bridge = BibleBridge()
        let coordinator = WebViewCoordinator(bridge: bridge)
        let scrollView = UIScrollView()
        var interactionCount = 0
        bridge.onNativeUserInteraction = {
            interactionCount += 1
        }

        coordinator.handleNativeTap(UITapGestureRecognizer())
        coordinator.scrollViewWillBeginDragging(scrollView)

        XCTAssertEqual(interactionCount, 2)
    }

    @MainActor
    func testBridgeEmitUsesFireAndForgetJavaScript() {
        let (bridge, recordedScripts) = makeRecordingBridge()

        XCTAssertTrue(bridge.emit(event: "set_config", data: #"{"theme":"light"}"#))

        let script = recordedScripts().first ?? ""
        XCTAssertTrue(script.contains("void bibleView.emit('set_config'"))
    }

    /**
     Verifies raw bridge emits expose whether JavaScript was actually dispatched.

     Detached bridge reporting remains observable so callers can distinguish JavaScript dispatch
     failure from a queued fire-and-forget emit when they need delivery diagnostics.
     */
    @MainActor
    func testBridgeEmitReportsDetachedDispatchFailure() {
        let bridge = BibleBridge()

        XCTAssertFalse(bridge.emit(event: "set_config", data: #"{"theme":"light"}"#))
    }

    /**
     Verifies bridge test helpers extract the outer emit payload instead of stopping at wrapper-like text.

     - Setup: Records a fire-and-forget bridge emission whose raw payload includes `); } catch`, the same
       suffix used by `BibleBridge.emit` after the payload argument.
     - Expected result: Extraction returns the complete payload text through the final wrapper suffix.
     - Failure meaning: A failure means bridge contract tests can hallucinate malformed payloads when
       user-facing text happens to resemble the JavaScript error wrapper.
     */
    @MainActor
    func testBridgeEmissionPayloadExtractionIgnoresWrapperSuffixInsidePayloadText() throws {
        let (bridge, recordedScripts) = makeRecordingBridge()

        bridge.emit(event: "sample_event", data: #"'value before "); } catch value after'"#)

        let payload = try bridgeEmissionPayloadJSON(from: recordedScripts(), event: "sample_event")

        XCTAssertEqual(payload, #"'value before "); } catch value after'"#)
    }
}
#endif
