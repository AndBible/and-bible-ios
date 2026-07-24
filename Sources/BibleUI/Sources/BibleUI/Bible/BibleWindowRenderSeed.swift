// BibleWindowRenderSeed.swift — First-render bridge and WebView-session ownership

import BibleView

/**
 Creates the bridge/render-session pair needed before a pane controller exists.

 SwiftUI constructs the WebView host before `BibleWindowPane.onAppear` initializes the reader
 controller. Keeping the pair in one state-owned reference lets that first host be adopted by the
 controller instead of creating a second `WKWebView`. On later pane appearances the registered
 controller's retained session wins and this seed remains unused.

 Side effects:
 - creates one bridge and one lazy `BibleWebViewSession`

 Failure modes:
 - none; the session does not instantiate WebKit until the representable requests its WebView
 */
final class BibleWindowRenderSeed {
    /// Bridge adopted by a newly created reader controller.
    let bridge: BibleBridge

    /// Lazy render session paired with `bridge`.
    let webViewSession: BibleWebViewSession

    /**
     Creates a mutually paired bridge and render session.

     - Side Effects: Allocates native coordination objects but does not create or load a WebView.
     - Failure Modes: None.
     */
    init() {
        let bridge = BibleBridge()
        self.bridge = bridge
        self.webViewSession = BibleWebViewSession(bridge: bridge)
    }
}
