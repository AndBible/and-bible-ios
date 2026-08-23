import XCTest
@testable import BibleView

#if os(iOS)
import UIKit
import WebKit

/**
 Records whether a lease transfer introduces an explicit detached-superview interval.

 UIKit can reparent a view directly when `addSubview` targets a new owner. An explicit
 `removeFromSuperview` first reports `nil`, which can also remove WebKit's focused content view from
 its window and resign the note editor. The recorder deliberately omits navigation and responder
 internals; it observes only the production hierarchy contract.

 Side effects:
- while `recordsTransitions` is enabled, records explicit superview detachment and loss of the
  native window

 Failure modes:
 - does not model WebKit JavaScript focus; a passing assertion proves the native prerequisite that
   transfer contains no explicit detached-superview interval
 */
private final class AttachmentTransitionRecordingWebView: WKWebView {
    /// Whether hierarchy transitions should currently contribute to the regression assertion.
    var recordsTransitions = false

    /// Whether UIKit was asked to move the WebView to no superview during the recorded interval.
    private(set) var observedDetachedTransition = false

    /// Whether the WebView left its native window during the recorded interval.
    private(set) var observedWindowDetachment = false

    /**
     Records explicit detachment before forwarding the hierarchy callback to WebKit.

     - Parameter newSuperview: Destination superview supplied by UIKit, or `nil` for detachment.
     - Side Effects: Sets `observedDetachedTransition` when recording and `newSuperview` is `nil`.
     - Failure Modes: None; always forwards to `super` exactly once.
     */
    override func willMove(toSuperview newSuperview: UIView?) {
        if recordsTransitions && newSuperview == nil {
            observedDetachedTransition = true
        }
        super.willMove(toSuperview: newSuperview)
    }

    /**
     Records native-window loss before forwarding WebKit's hierarchy callback.

     - Side Effects: Sets `observedWindowDetachment` when recording and the WebView has no window.
     - Failure Modes: None; always forwards to `super` exactly once.
     */
    override func didMoveToWindow() {
        if recordsTransitions && window == nil {
            observedWindowDetachment = true
        }
        super.didMoveToWindow()
    }
}

/**
 Package-lane coverage for iOS platform bootstrap values owned by `BibleWebView`.

 These tests validate static bootstrap values and in-memory UIKit/WebKit attachment lifecycles without
 starting the app host or navigating the packaged Vue bundle.
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
     - creates the production session and UIKit host around a detached `WKWebView`
     - commits that host through the same appearance-lease boundary used by the app

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
        let session = BibleWebViewSession(bridge: bridge)
        XCTAssertTrue(session.webView { webView } === webView)
        let controller = BibleWebViewController(webView: webView, bridge: bridge, session: session)

        controller.loadViewIfNeeded()
        XCTAssertNil(webView.superview, "viewDidLoad must not steal a cached WebView")
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()

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
        controller.beginAppearanceTransition(false, animated: false)
        controller.endAppearanceTransition()
    }

    /**
     Verifies an appearance-committed replacement cannot steal from a still-visible host.

     SwiftUI may load and then appear a replacement before dismantling the current reader pane. The
     session must retain the focused WebView in the current host until that host disappears, then move
     constraints atomically. A stale second release from the old host must leave the new owner intact.

     - Setup: Mounts both transient hosts in one native window, fully appears owner A, then begins B's
       appearance before ending A's disappearance, matching UIKit replacement ordering.
     - Expected result: Loading/appearing the replacement does not steal; releasing the first transfers
       once, clears old constraints, and a stale old-host release cannot detach the second.
     - Failure meaning: A keyboard-driven SwiftUI update can blank the visible reader or strand the
       note editor's focused WebView in a discarded host.
     - Side effects: Constructs and reparents only in-memory UIKit/WebKit objects; no navigation or
       persistent state is changed.
     */
    @MainActor
    func testBibleWebViewAttachmentLeaseWaitsForVisibleOwnerReleaseAndIgnoresStaleRelease() {
        let bridge = BibleBridge()
        let webView = AttachmentTransitionRecordingWebView()
        let session = BibleWebViewSession(bridge: bridge)
        XCTAssertTrue(session.webView { webView } === webView)
        let firstController = BibleWebViewController(
            webView: webView,
            bridge: bridge,
            session: session
        )
        firstController.loadViewIfNeeded()
        firstController.beginAppearanceTransition(true, animated: false)
        firstController.endAppearanceTransition()
        XCTAssertTrue(webView.superview === firstController.view)

        let secondController = BibleWebViewController(
            webView: webView,
            bridge: bridge,
            session: session
        )
        secondController.loadViewIfNeeded()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let container = UIViewController()
        window.rootViewController = container
        container.loadViewIfNeeded()
        container.addChild(firstController)
        container.view.addSubview(firstController.view)
        firstController.didMove(toParent: container)
        container.addChild(secondController)
        container.view.addSubview(secondController.view)
        secondController.didMove(toParent: container)
        window.isHidden = false
        XCTAssertTrue(firstController.view.window === window)
        XCTAssertTrue(secondController.view.window === window)
        XCTAssertTrue(webView.window === window)
        XCTAssertTrue(
            webView.superview === firstController.view,
            "A speculative viewDidLoad must not reparent the focused WebView"
        )
        secondController.beginAppearanceTransition(true, animated: false)
        XCTAssertTrue(
            webView.superview === firstController.view,
            "An incoming viewWillAppear host must wait for the current owner to disappear"
        )

        webView.recordsTransitions = true
        firstController.beginAppearanceTransition(false, animated: false)
        firstController.endAppearanceTransition()

        XCTAssertTrue(webView.superview === secondController.view)
        XCTAssertFalse(
            webView.observedDetachedTransition,
            "Owner-to-owner transfer must directly reparent the WebView to preserve editor focus"
        )
        XCTAssertFalse(
            webView.observedWindowDetachment,
            "Owner-to-owner transfer must preserve native-window membership for the focused editor"
        )
        XCTAssertTrue(webView.window === window)
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
        secondController.endAppearanceTransition()

        session.attachmentHostDidDisappear(firstController)
        XCTAssertTrue(
            webView.superview === secondController.view,
            "A stale old-host release must not detach the current owner's WebView"
        )
        secondController.beginAppearanceTransition(false, animated: false)
        secondController.endAppearanceTransition()
        XCTAssertNil(webView.superview)
    }

    /**
     Protects deterministic fallback when multiple SwiftUI replacement hosts overlap.

     A single pending slot loses host B when newer host C appears and is then discarded before owner A
     dismantles. The session instead retains weak registrations for all appearance-committed hosts.

     - Setup: Appearance-commits owner A, then waiting hosts B and C; C dismantles first.
     - Expected result: A remains owner until dismantle, after which B receives the identical WebView;
       neither the discarded C nor an empty host strands the rendered session.
     - Failure meaning: Rapid layout reconciliation can blank the reader even with a nominal lease.
     - Side Effects: Uses only in-memory hosts and the production dismantle callback; no WebKit
       navigation, persistence, or simulator state is changed.
     - Determinism: Session-local generations make the newest remaining visible host selection stable.
     */
    @MainActor
    func testBibleWebViewAttachmentLeaseFallsBackWhenNewestWaitingHostIsDiscarded() {
        let bridge = BibleBridge()
        let webView = WKWebView()
        let session = BibleWebViewSession(bridge: bridge)
        XCTAssertTrue(session.webView { webView } === webView)
        let owner = BibleWebViewController(webView: webView, bridge: bridge, session: session)
        let earlierReplacement = BibleWebViewController(
            webView: webView,
            bridge: bridge,
            session: session
        )
        let laterReplacement = BibleWebViewController(
            webView: webView,
            bridge: bridge,
            session: session
        )
        owner.loadViewIfNeeded()
        earlierReplacement.loadViewIfNeeded()
        laterReplacement.loadViewIfNeeded()

        session.attachmentHostWillAppear(owner)
        session.attachmentHostWillAppear(earlierReplacement)
        session.attachmentHostWillAppear(laterReplacement)
        XCTAssertTrue(webView.superview === owner.view)

        BibleWebView.dismantleUIViewController(
            laterReplacement,
            coordinator: session.coordinator
        )
        XCTAssertTrue(webView.superview === owner.view)

        BibleWebView.dismantleUIViewController(owner, coordinator: session.coordinator)
        XCTAssertTrue(webView.superview === earlierReplacement.view)

        BibleWebView.dismantleUIViewController(
            earlierReplacement,
            coordinator: session.coordinator
        )
        XCTAssertNil(webView.superview)
    }
}
#endif
