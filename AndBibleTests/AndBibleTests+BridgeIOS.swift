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

        bridge.emit(event: "set_config", data: #"{"theme":"light"}"#)

        let script = recordedScripts().first ?? ""
        XCTAssertTrue(script.contains("void bibleView.emit('set_config'"))
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
