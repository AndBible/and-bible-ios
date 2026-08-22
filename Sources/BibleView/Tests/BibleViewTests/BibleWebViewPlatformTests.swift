import XCTest
@testable import BibleView

#if os(iOS)
import UIKit
import WebKit

/**
 Package-lane coverage for iOS platform bootstrap values owned by `BibleWebView`.

 These tests validate the native wrapper's static platform contract without starting the app host or
 constructing a `WKWebView`, keeping renderer bootstrap behavior in the BibleView test target.
 */
final class BibleWebViewPlatformTests: XCTestCase {
    /**
     Verifies that UIKit idioms map to the CSS/JavaScript device classes consumed by the Vue reader.

     A failure means the shared web client may receive the wrong platform class and apply phone/iPad
     behavior inconsistently before the bridge sends reader content.
     */
    func testBibleWebViewMapsDeviceClassFromInterfaceIdiom() {
        XCTAssertEqual(BibleWebView.iosDeviceClass(for: .phone), "ios-phone")
        XCTAssertEqual(BibleWebView.iosDeviceClass(for: .pad), "ios-pad")
    }

    /**
     Verifies that the injected platform script exposes iOS and device-class globals to Vue startup.

     Setup:
     - generates the script from a deterministic device class
     - checks the bootstrap globals and root CSS classes the web bundle consumes

     Failure meaning:
     - the renderer can boot without the native iOS platform identity expected by shared Vue code.
     */
    func testBibleWebViewInjectsPlatformDeviceClassIntoUserScript() {
        let expectedDeviceClass = "ios-phone"
        let platformScript = BibleWebView.platformBootstrapScriptSource(deviceClass: expectedDeviceClass)

        XCTAssertTrue(platformScript.contains("window.__PLATFORM__ = 'ios';"))
        XCTAssertTrue(platformScript.contains("window.__IOS_DEVICE_CLASS__ = '\(expectedDeviceClass)';"))
        XCTAssertTrue(platformScript.contains("document.documentElement.classList.add('platform-ios');"))
        XCTAssertTrue(platformScript.contains("document.documentElement.classList.add('\(expectedDeviceClass)');"))
    }

    /**
     Protects Android's IME-resize contract for the iOS reader host.

     Android shrinks `mainBibleView` by the visible IME inset so fixed-position bookmark-note
     modals keep their editor and close controls inside the interactive viewport. The iOS host must
     therefore end at `keyboardLayoutGuide.topAnchor`, not behind the keyboard at `view.bottom`.

     Setup:
     - creates the production UIKit host around a detached `WKWebView`
     - loads the controller view without navigating or starting the Vue client

     Expected result:
     - the WebView bottom is constrained directly to the keyboard layout guide's top
     - the guide does not use its default bottom-safe-area floor, preserving the edge-to-edge reader
       when no docked keyboard is present

     Failure meaning:
     - note editors can again become trapped behind iOS WebKit's keyboard/visual-viewport pan

     Side effects and cleanup:
     - constructs only in-memory UIKit/WebKit objects; no navigation, persistence, or simulator
       state is changed
     */
    @MainActor
    func testBibleWebViewKeepsLayoutViewportAboveDockedKeyboard() {
        let bridge = BibleBridge()
        let webView = WKWebView()
        let controller = BibleWebViewController(webView: webView, bridge: bridge)

        controller.loadViewIfNeeded()

        let keyboardGuide = controller.view.keyboardLayoutGuide
        XCTAssertFalse(
            keyboardGuide.usesBottomSafeArea,
            "A hidden keyboard must restore the reader to the view bottom, not the safe-area bottom"
        )
        let keyboardBottomConstraint = controller.view.constraints.first { constraint in
            (constraint.firstItem as? WKWebView) === webView
                && constraint.firstAttribute == .bottom
                && (constraint.secondItem as? UIKeyboardLayoutGuide) === keyboardGuide
                && constraint.secondAttribute == .top
        }
        XCTAssertNotNil(keyboardBottomConstraint)
    }

    /**
     Verifies a persistent reader WebView can move between transient UIKit hosts safely.

     SwiftUI recreates `BibleWebViewController` when a window pane detaches and reappears, while the
     session deliberately retains the loaded `WKWebView`. UIKit must remove constraints owned by the
     first host before the second host installs its keyboard-layout contract.

     - Setup: Loads two production controllers sequentially around the same detached WebView.
     - Expected result: The WebView belongs to the second controller, the first controller retains
       no constraint that references it, and the second keyboard guide owns the active bottom edge.
     - Failure meaning: Reattaching a retained Vue session can leave cross-hierarchy constraints,
       causing layout warnings or preventing the note editor from following the current keyboard.
     - Side effects: Constructs and reparents only in-memory UIKit/WebKit objects; no navigation or
       persistent state is changed.
     */
    @MainActor
    func testBibleWebViewReattachmentMovesKeyboardConstraintsToCurrentController() {
        let bridge = BibleBridge()
        let webView = WKWebView()
        let firstController = BibleWebViewController(webView: webView, bridge: bridge)
        firstController.loadViewIfNeeded()
        XCTAssertTrue(webView.superview === firstController.view)

        let secondController = BibleWebViewController(webView: webView, bridge: bridge)
        secondController.loadViewIfNeeded()

        XCTAssertTrue(webView.superview === secondController.view)
        XCTAssertFalse(firstController.view.constraints.contains { constraint in
            (constraint.firstItem as? WKWebView) === webView
                || (constraint.secondItem as? WKWebView) === webView
        })
        let secondKeyboardGuide = secondController.view.keyboardLayoutGuide
        XCTAssertFalse(secondKeyboardGuide.usesBottomSafeArea)
        XCTAssertTrue(secondController.view.constraints.contains { constraint in
            (constraint.firstItem as? WKWebView) === webView
                && constraint.firstAttribute == .bottom
                && (constraint.secondItem as? UIKeyboardLayoutGuide) === secondKeyboardGuide
                && constraint.secondAttribute == .top
        })
    }
}
#endif
