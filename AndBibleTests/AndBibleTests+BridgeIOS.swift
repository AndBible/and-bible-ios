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

    /**
     Verifies bridge event routing keeps modal state and host callback dispatch outside the reader controller.

     - Setup: Uses the focused router with closure recorders instead of a full reader controller so
       the test protects routing ownership rather than document payload generation.
     - Expected result: Modal-open key events do not navigate, Escape asks Vue to close modals, host
       callbacks are forwarded through injected closures, and fullscreen honors the injected
       preference gate.
     - Failure meaning: A failure means the #146 extraction has either left routing behavior in the
       controller or changed the existing bridge event semantics while moving it.
     */
    @MainActor
    func testBridgeEventRouterOwnsModalKeyboardAndHostCallbackRouting() {
        var emittedEvents: [String] = []
        var previousCount = 0
        var nextCount = 0
        var toasts: [String] = []
        var sharedHTML: [String] = []
        var downloadSeeds: [String?] = []
        var fullscreenAllowed = false
        var fullscreenToggleCount = 0

        let router = BibleReaderBridgeEventRouter(
            emitBridgeEvent: { event in
                emittedEvents.append(event)
                return true
            },
            navigatePrevious: { previousCount += 1 },
            navigateNext: { nextCount += 1 },
            showToast: { toasts.append($0) },
            shareHtml: { sharedHTML.append($0) },
            openDownloads: { downloadSeeds.append($0) },
            shouldToggleFullScreen: { fullscreenAllowed },
            toggleFullScreen: { fullscreenToggleCount += 1 }
        )

        XCTAssertFalse(router.webModalIsOpen)
        router.reportModalState(true)
        XCTAssertTrue(router.webModalIsOpen)

        router.handleKeyDown("ArrowRight")
        router.handleKeyDown("Escape")
        XCTAssertEqual(nextCount, 0)
        XCTAssertEqual(emittedEvents, ["close_modals"])

        router.reportModalState(false)
        router.handleKeyDown("ArrowLeft")
        router.handleKeyDown("ArrowRight")
        XCTAssertEqual(previousCount, 1)
        XCTAssertEqual(nextCount, 1)

        router.showToast("Saved")
        router.shareHtml("<p>Shared</p>")
        router.requestOpenDownloads(searchText: "KJV")
        XCTAssertEqual(toasts, ["Saved"])
        XCTAssertEqual(sharedHTML, ["<p>Shared</p>"])
        XCTAssertEqual(downloadSeeds.count, 1)
        XCTAssertEqual(downloadSeeds.first ?? nil, "KJV")

        router.requestToggleFullScreen()
        XCTAssertEqual(fullscreenToggleCount, 0)
        fullscreenAllowed = true
        router.requestToggleFullScreen()
        XCTAssertEqual(fullscreenToggleCount, 1)
    }
    #endif

}
