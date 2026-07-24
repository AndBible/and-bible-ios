// BibleWebViewSession.swift — Per-window native WebView lifetime owner

import WebKit

/**
 Retains one bridge-backed WebView host for the lifetime of a reader window.

 Android's `BibleViewFactory.windowBibleViewMap` keeps the actual `BibleView` alive while its
 `BibleFrame` is detached for minimization. This session provides the same ownership boundary for
 iOS and macOS: SwiftUI may remove and later recreate a representable, but the pane controller keeps
 this session alive and the representable reattaches the already-bootstrapped `WKWebView`.

 The session owns the original `WebViewCoordinator` because WebKit delegate properties are weak.
 Keeping the coordinator beside the cached host preserves navigation, native interaction, and
 scroll callbacks across detach/reattach cycles.

 Side effects:
 - lazily retains the first `WKWebView` returned by a resolver factory
 - retains one coordinator bound to `bridge`

 Failure modes:
 - callers must use the session only with the bridge supplied at initialization
 - WebView creation still propagates any failure behavior of the supplied factory

 Concurrency:
 - WebKit and representable lifecycle access must remain on the main thread
 - one session must not be attached to two visible view hierarchies concurrently
 */
public final class BibleWebViewSession {
    /// Bridge shared by the cached WebView host and its owning reader controller.
    public let bridge: BibleBridge

    /**
     Coordinator retained independently of transient SwiftUI representable instances.

     WebKit stores navigation and scroll delegates weakly, so retaining this coordinator is required
     for a cached WebView to keep routing callbacks after the original representable is dismantled.
     */
    let coordinator: WebViewCoordinator

    /// Rendered Vue surface retained while its reader window is minimized or hidden by layout.
    private var cachedWebView: WKWebView?

    /**
     Creates an empty per-window render session.

     - Parameter bridge: Window-scoped native/Vue bridge that must remain paired with the cached
       host for the session's complete lifetime.
     - Side Effects: Creates and retains a coordinator; no `WKWebView` or bundle navigation starts
       until the platform representable first requests a WebView.
     - Failure Modes: None.
     */
    public init(bridge: BibleBridge) {
        self.bridge = bridge
        self.coordinator = WebViewCoordinator(bridge: bridge)
    }

    /**
     Returns the existing rendered WebView or creates it exactly once.

     - Parameter create: Main-thread factory that builds the bridge-backed WebView on first use.
     - Returns: The identical `WKWebView` instance for every call during this session's lifetime.
     - Side Effects: Retains the first WebView produced by `create`.
     - Failure Modes: The factory is not called after a WebView has been cached.
     */
    func webView(create: () -> WKWebView) -> WKWebView {
        if let cachedWebView {
            return cachedWebView
        }
        let webView = create()
        cachedWebView = webView
        return webView
    }
}
