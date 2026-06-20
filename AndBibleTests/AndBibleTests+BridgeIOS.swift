import XCTest
import AVFoundation
@testable import BibleCore
import CLibSword
@testable import SwordKit
import SwiftData
import SQLite3
@testable import BibleUI
@testable import BibleView
import struct SwiftUI.Binding
import enum SwiftUI.ColorScheme
import struct SwiftUI.EdgeInsets
import struct SwiftUI.EmptyView
#if os(iOS)
import UIKit
import WebKit
import struct SwiftUI.Color
#endif

extension AndBibleTests {
    #if os(iOS)
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

     The synchronized-scroll feedback guard uses this delivery signal to avoid suppressing later
     real user scrolls after a detached bridge failed to receive `scroll_to_verse`.
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

    @MainActor
    func testReaderBridgeModalStateBlocksKeyNavigationAndRequestsClose() {
        let (bridge, recordedScripts) = makeRecordingBridge()
        let controller = BibleReaderController(bridge: bridge)

        XCTAssertFalse(controller.webModalIsOpen)
        XCTAssertEqual(bridge.dispatchMessage(method: "reportModalState", args: [true]), .handled)
        XCTAssertTrue(controller.webModalIsOpen)

        XCTAssertEqual(bridge.dispatchMessage(method: "onKeyDown", args: ["ArrowRight"]), .handled)
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 1)

        XCTAssertEqual(bridge.dispatchMessage(method: "onKeyDown", args: ["Escape"]), .handled)
        XCTAssertTrue(recordedScripts().contains { $0.contains("bibleView.emit('close_modals'") })

        XCTAssertEqual(bridge.dispatchMessage(method: "reportModalState", args: [false]), .handled)
        XCTAssertFalse(controller.webModalIsOpen)

        XCTAssertEqual(bridge.dispatchMessage(method: "onKeyDown", args: ["ArrowRight"]), .handled)
        XCTAssertEqual(controller.currentBook, "Genesis")
        XCTAssertEqual(controller.currentChapter, 2)
    }
    #endif

}
