// BibleWebView.swift — WKWebView container for Vue.js Bible rendering

import BibleCore
import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#endif

/**
 SwiftUI wrapper around WKWebView that loads the Vue.js Bible frontend.

 Usage:
 ```swift
 BibleWebView(session: BibleWebViewSession(bridge: bridge))
     .onAppear { bridge.emit(event: "loadDocument", data: documentJson) }
 ```
 */
#if os(iOS)
/**
 Transient UIKit host for one session-owned reader WebView.

 Using a view controller instead of a bare `UIViewRepresentable` keeps the WebView in UIKit's full
 responder chain. SwiftUI may construct overlapping controllers while changing layout, so loading a
 controller does not grant ownership. `viewWillAppear` registers an appearance-committed candidate
 with `BibleWebViewSession`; disappearance/dismantle releases that candidate idempotently.

 Side effects:
 - appearance callbacks request and release the session's exclusive WebView attachment lease
 - the current lease owner installs keyboard-guide constraints and native background colors

 Failure modes:
 - speculative controllers remain empty until they appear and receive the lease
 - stale disappearance callbacks cannot detach the WebView from a newer session owner
 */
public class BibleWebViewController: UIViewController {
    /// Persistent rendered surface shared only through `session`'s exclusive attachment lease.
    let webView: WKWebView

    /// Native/Vue message bridge paired with the session for its complete lifetime.
    let bridge: BibleBridge

    /// Session that owns the cached WebView, coordinator, and attachment ordering.
    let session: BibleWebViewSession

    /// Active constraints installed only while this controller owns the session attachment lease.
    private var sessionWebViewConstraints: [NSLayoutConstraint] = []

    /// Current Android-style background color reapplied across transient host updates.
    var backgroundColorInt: Int = -1

    /**
     Creates an unattached UIKit candidate for one session-owned WebView.

     - Parameters:
       - webView: Cached rendered surface returned by `session`.
       - bridge: Bridge paired with `session` and `webView`.
       - session: Window-scoped owner that grants attachment after appearance.
     - Side Effects: None; UIKit hierarchy mutation waits for an appearance-committed lease.
     - Failure Modes: Mismatched identities are rejected by the session when appearance requests
       attachment.
     */
    init(webView: WKWebView, bridge: BibleBridge, session: BibleWebViewSession) {
        self.webView = webView
        self.bridge = bridge
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /**
     Loads the transient native backing surface without claiming the session WebView.

     SwiftUI may load speculative controllers before deciding which hierarchy becomes visible.
     Attachment therefore waits for `viewWillAppear`; eagerly adding the cached WebView here would
     remove it from the still-visible owner and strand the focused Vue editor.

     Side effects:
     - applies the current native background palette

     Failure modes:
     - the controller intentionally remains empty until appearance commits and the session grants it
       ownership
     */
    public override func viewDidLoad() {
        super.viewDidLoad()
        applyBackground()
    }

    /**
     Commits this appearing controller as an eligible session attachment host.

     UIKit normally sends the incoming host `viewWillAppear` before the outgoing host receives
     `viewDidDisappear`. Registering at this boundary guarantees the outgoing release can transfer
     directly instead of briefly detaching the focused WebView while waiting for `viewDidAppear`.

     - Parameter animated: UIKit appearance flag forwarded unchanged to `super`.
     - Side Effects: Registers or refreshes this host in the session's ordered weak lease candidates;
       may attach the WebView immediately when no current visible owner exists.
     - Failure Modes: A still-visible current owner keeps this controller waiting without reparenting.
     */
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        session.attachmentHostWillAppear(self)
    }

    /**
     Releases this controller's visible-host registration after UIKit appearance ends.

     - Parameter animated: UIKit appearance flag forwarded unchanged to `super`.
     - Side Effects: May detach the WebView and transfer it to the newest remaining visible host.
     - Failure Modes: Repeated or stale disappearance is idempotent and cannot detach a newer owner.
     */
    public override func viewDidDisappear(_ animated: Bool) {
        session.attachmentHostDidDisappear(self)
        super.viewDidDisappear(animated)
    }

    /**
     Installs the session WebView and Android-parity keyboard layout contract for the lease owner.

     Android resizes `mainBibleView` by the IME inset so fixed-position note modals remain focusable
     and dismissible. The iOS lease owner pins the WebView to `UIKeyboardLayoutGuide.topAnchor`, while
     the surrounding SwiftUI split hierarchy ignores keyboard-safe-area orientation changes.

     - Side Effects: Adds the cached WebView directly to this controller (letting UIKit atomically
       reparent it from a prepared prior owner), disables the keyboard guide's bottom-safe-area floor,
       activates four edge constraints, and reapplies native colors.
     - Failure Modes: Repeated calls while already attached are idempotent; floating keyboards retain
       WebKit's normal cursor-scrolling behavior rather than resizing the full-width surface.
     - Important: Called only by `BibleWebViewSession` on the main actor after exclusive lease grant.
     */
    @MainActor
    func attachSessionWebViewIfNeeded() {
        guard webView.superview !== view else {
            applyBackground()
            return
        }

        NSLayoutConstraint.deactivate(sessionWebViewConstraints)
        sessionWebViewConstraints.removeAll()
        view.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        let keyboardLayoutGuide = view.keyboardLayoutGuide
        keyboardLayoutGuide.usesBottomSafeArea = false
        sessionWebViewConstraints = [
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ]
        NSLayoutConstraint.activate(sessionWebViewConstraints)
        applyBackground()
    }

    /**
     Deactivates this owner's constraints while leaving the WebView attached for direct reparenting.

     Avoiding an intermediate `removeFromSuperview` keeps a focused `WKContentView` in the same window
     during legitimate owner-to-owner transfer, so UIKit can preserve first-responder continuity.

     - Side Effects: Deactivates and clears only this controller's WebView constraints.
     - Failure Modes: Repeated preparation is idempotent; the WebView hierarchy is never removed.
     - Important: Called only by `BibleWebViewSession` on the main actor immediately before transfer.
     */
    @MainActor
    func prepareSessionWebViewForTransfer() {
        NSLayoutConstraint.deactivate(sessionWebViewConstraints)
        sessionWebViewConstraints.removeAll()
    }

    /**
     Removes the cached WebView only when this controller still owns its actual superview.

     - Side Effects: Deactivates this host's keyboard constraints and removes the WebView from this
       controller before a lease transfer or detached-session retention.
     - Failure Modes: If a stale callback arrives after another host owns the WebView, this method
       clears only this controller's recorded constraints and never removes the newer attachment.
     - Important: Called only by `BibleWebViewSession` on the main actor.
     */
    @MainActor
    func detachSessionWebViewIfOwned() {
        prepareSessionWebViewForTransfer()
        guard webView.superview === view else { return }
        webView.removeFromSuperview()
    }

    /**
     Applies the configured Android-style ARGB background to every native WebView surface.

     Android keeps both `BibleView` and its owning `BibleFrame` opaque and painted with the
     resolved window background while Vue replaces documents. Matching that ownership on iOS
     prevents WebKit's transparent compositor backing from exposing its default dark surface
     between the old and replacement document frames.

     - Side effects: Makes the hosted WebView opaque and updates the WebView, scroll view,
       controller view, and under-page colors.
     - Failure modes: Invalid or truncated ARGB inputs retain the existing byte-wise conversion
       behavior; this method performs no asynchronous WebKit work.
     */
    func applyBackground() {
        let color = BibleWebView.uiColor(fromArgbInt: backgroundColorInt)
        webView.isOpaque = true
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
        view.backgroundColor = color
        if #available(iOS 15.0, *) {
            webView.underPageBackgroundColor = color
        }
    }
}

/**
 SwiftUI wrapper that hosts the Vue.js Bible client inside `WKWebView`.

 A window-scoped `BibleWebViewSession` owns the rendered `WKWebView` and coordinator. SwiftUI may
 dismantle this representable while a pane is minimized, but recreating it with the same session
 wraps and reattaches the already-loaded Vue client instead of constructing and replaying another
 `WKWebView`.
 */
public struct BibleWebView: UIViewControllerRepresentable {
    public typealias UIViewControllerType = BibleWebViewController

    /// Window-scoped owner of the bridge, coordinator, and cached WebView.
    let session: BibleWebViewSession

    /// Optional serialized bootstrap state retained for compatibility with existing callers.
    let initialState: String?

    /// Android-style signed ARGB color applied to every native host surface.
    var backgroundColorInt: Int

    /**
     Creates a transient SwiftUI wrapper around one persistent window render session.

     - Parameters:
       - session: Per-window session whose cached WebView should be attached by this representable.
       - initialState: Reserved serialized bootstrap state retained for API compatibility.
       - backgroundColorInt: Signed Android ARGB color for the WebView and native backing surfaces.
     - Side Effects: None; WebView creation remains lazy until SwiftUI calls `makeUIViewController`.
     - Failure Modes: Overlapping visible wrappers are serialized by the session lease; only the
       current owner renders until its appearance ends.
     */
    public init(
        session: BibleWebViewSession,
        initialState: String? = nil,
        backgroundColorInt: Int = -1
    ) {
        self.session = session
        self.initialState = initialState
        self.backgroundColorInt = backgroundColorInt
    }

    /**
     Creates an unattached controller candidate around the session's cached WebView.

     - Parameter context: SwiftUI representable context whose coordinator is session-owned.
     - Returns: A transient UIKit controller that requests attachment only after `viewWillAppear`.
     - Side Effects: First use creates the cached WebView and starts packaged Vue bundle navigation;
       controller creation itself does not alter the current native hierarchy.
     - Failure Modes: Bundle lookup retains the existing placeholder fallback behavior; speculative
       controllers can remain intentionally empty without stealing the cached surface.
     */
    public func makeUIViewController(context: Context) -> BibleWebViewController {
        let webView = session.webView {
            createWebView(coordinator: context.coordinator)
        }
        let viewController = BibleWebViewController(
            webView: webView,
            bridge: session.bridge,
            session: session
        )
        viewController.backgroundColorInt = backgroundColorInt
        return viewController
    }

    /**
     Reapplies native palette state when SwiftUI updates either a current or waiting host.

     - Parameters:
       - vc: Transient controller whose native backing color must match the reader theme.
       - context: Current representable context; no coordinator mutation is needed.
     - Side Effects: Updates the controller color token and every cached WebView backing surface.
     - Failure Modes: Waiting hosts update their native view safely without claiming attachment.
     */
    public func updateUIViewController(_ vc: BibleWebViewController, context: Context) {
        vc.backgroundColorInt = backgroundColorInt
        vc.applyBackground()
    }

    /**
     Removes a transient controller from the session's visible attachment candidates.

     SwiftUI may dismantle a host without a balanced appearance callback. Routing both lifecycle
     paths through the same idempotent session operation guarantees cached WebView retention and
     prevents a stale controller from detaching a newer owner.

     - Parameters:
       - uiViewController: Transient host being removed by SwiftUI.
       - coordinator: Session-owned coordinator retained for protocol symmetry; no mutation is needed.
     - Side Effects: Releases/cancels this host's attachment registration and may transfer the cached
       WebView to another appearance-committed host.
     - Failure Modes: Repeated teardown is ignored safely.
     */
    public static func dismantleUIViewController(
        _ uiViewController: BibleWebViewController,
        coordinator: WebViewCoordinator
    ) {
        uiViewController.session.attachmentHostDidDisappear(uiViewController)
    }

    /// Converts a signed Android-style ARGB integer into `UIColor`.
    static func uiColor(fromArgbInt value: Int) -> UIColor {
        let uint = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
        let a = CGFloat((uint >> 24) & 0xFF) / 255.0
        let r = CGFloat((uint >> 16) & 0xFF) / 255.0
        let g = CGFloat((uint >> 8) & 0xFF) / 255.0
        let b = CGFloat(uint & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    /**
     Returns the coordinator retained by the per-window session.

     - Returns: Stable coordinator identity for the cached host's complete lifetime.
     - Side Effects: None.
     - Failure Modes: None.
     */
    public func makeCoordinator() -> WebViewCoordinator {
        session.coordinator
    }
}
#elseif os(macOS)
/**
 WKWebView subclass that reports native macOS user input without reclassifying web telemetry.

 The iOS host gets touch and drag callbacks from `UIScrollViewDelegate`/gesture recognizers. macOS
 does not expose that path through the shared coordinator, so this view reports mouse, keyboard,
 and wheel events directly before allowing WebKit to handle them normally.

 Side effects:
 - invokes `onNativeUserInteraction` before forwarding native input to `WKWebView`

 Failure modes:
 - programmatic scroll and web `scrolledToOrdinal` telemetry do not pass through these overrides,
   keeping passive synchronized-scroll feedback separate from explicit user input
 */
final class InteractionReportingWKWebView: WKWebView {
    var onNativeUserInteraction: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onNativeUserInteraction?()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        onNativeUserInteraction?()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        onNativeUserInteraction?()
        super.otherMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onNativeUserInteraction?()
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onNativeUserInteraction?()
        super.scrollWheel(with: event)
    }
}

/// macOS variant of `BibleWebView` using `NSViewRepresentable`.
public struct BibleWebView: NSViewRepresentable {
    public typealias NSViewType = WKWebView

    /// Window-scoped owner of the bridge, coordinator, and cached AppKit WebView.
    let session: BibleWebViewSession

    /// Optional serialized bootstrap state retained for compatibility with existing callers.
    let initialState: String?

    /// Android-style signed ARGB color retained for cross-platform API symmetry.
    var backgroundColorInt: Int

    /**
     Creates a transient SwiftUI wrapper around one persistent window render session.

     - Parameters:
       - session: Per-window session whose cached WebView should be attached.
       - initialState: Reserved serialized bootstrap state retained for API compatibility.
       - backgroundColorInt: Signed Android ARGB color retained for cross-platform API symmetry.
     - Side Effects: None; host creation remains lazy until SwiftUI calls `makeNSView`.
     - Failure Modes: Reusing one session in simultaneous visible hierarchies violates the session
       ownership contract.
     */
    public init(
        session: BibleWebViewSession,
        initialState: String? = nil,
        backgroundColorInt: Int = -1
    ) {
        self.session = session
        self.initialState = initialState
        self.backgroundColorInt = backgroundColorInt
    }

    /**
     Attaches the session's cached AppKit WebView, creating and loading it only on first use.

     - Parameter context: SwiftUI representable context whose coordinator is session-owned.
     - Returns: The same `WKWebView` across pane detach/reattach cycles.
     - Side Effects: First use creates a WebView and starts the packaged Vue bundle navigation.
     - Failure Modes: Bundle lookup retains the existing placeholder fallback behavior.
     */
    public func makeNSView(context: Context) -> WKWebView {
        session.webView {
            let webView = createWebView(coordinator: context.coordinator)
            webView.setValue(false, forKey: "drawsBackground")
            return webView
        }
    }

    /// macOS currently has no incremental update work beyond the bridge itself.
    public func updateNSView(_ webView: WKWebView, context: Context) {}

    /**
     Returns the coordinator retained by the per-window session.

     - Returns: Stable coordinator identity for the cached host's complete lifetime.
     - Side Effects: None.
     - Failure Modes: None.
     */
    public func makeCoordinator() -> WebViewCoordinator {
        session.coordinator
    }
}
#endif

// MARK: - Shared WebView Creation

extension BibleWebView {
    #if os(iOS)
    /// Maps one UIKit idiom to the device-class token exported to the web client.
    static func iosDeviceClass(for userInterfaceIdiom: UIUserInterfaceIdiom) -> String {
        userInterfaceIdiom == .pad ? "ios-pad" : "ios-phone"
    }
    #endif

    /// Returns the current iOS device-class token exported to the web client.
    static func iosDeviceClass() -> String {
        #if os(iOS)
        iosDeviceClass(for: UIDevice.current.userInterfaceIdiom)
        #else
        "ios-phone"
        #endif
    }

    /// Returns the bootstrap script injected into the packaged web client before it loads.
    static func platformBootstrapScriptSource(deviceClass: String) -> String {
        """
        window.__PLATFORM__ = 'ios';
        window.__activeLanguages__ = '["en"]';
        window.__IOS_DEVICE_CLASS__ = '\(deviceClass)';
        window.bibleView = {};
        window.bibleViewDebug = {};
        (function() {
            function applyPlatformClasses() {
                if (!document.documentElement) return;
                document.documentElement.classList.add('platform-ios');
                document.documentElement.classList.add('\(deviceClass)');
            }
            if (document.documentElement) {
                applyPlatformClasses();
            } else {
                document.addEventListener('DOMContentLoaded', applyPlatformClasses, { once: true });
            }
        })();
        window.android = new Proxy({}, {
            get: function(target, prop) {
                if (prop === 'getActiveLanguages') {
                    return function() { return window.__activeLanguages__; };
                }
                return function() {
                    var args = Array.prototype.slice.call(arguments);
                    window.webkit.messageHandlers.bibleView.postMessage({
                        method: String(prop),
                        args: args
                    });
                };
            }
        });
        // Prevent iOS tap highlight and fix Strong's link colors for night mode
        var style = document.createElement('style');
        style.textContent = [
            '* { -webkit-tap-highlight-color: transparent; }',
            '::selection { background: rgba(100,149,237,0.3); }',
            // Make Strong's number links use theme-aware colors.
            // Must override <a> tag default link/visited colors with pseudo-class selectors.
            '.w-base { color: var(--verse-number-color, #aaa) !important; }',
            'a.strongs, a.strongs:link, a.strongs:visited, a.strongs:active { color: var(--verse-number-color, #aaa) !important; }',
            'a.morph, a.morph:link, a.morph:visited, a.morph:active { color: var(--verse-number-color, #aaa) !important; }',
        ].join(' ');
        (document.head || document.documentElement).appendChild(style);
        // Route console.log/error/warn to native bridge for debugging
        (function() {
            var origLog = console.log;
            var origError = console.error;
            var origWarn = console.warn;
            console.log = function() {
                origLog.apply(console, arguments);
                try {
                    var msg = Array.prototype.slice.call(arguments).map(function(a) {
                        return typeof a === 'object' ? JSON.stringify(a) : String(a);
                    }).join(' ');
                    window.webkit.messageHandlers.bibleView.postMessage({
                        method: 'jsLog', args: ['LOG', msg]
                    });
                } catch(e) {}
            };
            console.error = function() {
                origError.apply(console, arguments);
                try {
                    var msg = Array.prototype.slice.call(arguments).map(function(a) {
                        return typeof a === 'object' ? JSON.stringify(a) : String(a);
                    }).join(' ');
                    window.webkit.messageHandlers.bibleView.postMessage({
                        method: 'jsLog', args: ['ERROR', msg]
                    });
                } catch(e) {}
            };
            console.warn = function() {
                origWarn.apply(console, arguments);
                try {
                    var msg = Array.prototype.slice.call(arguments).map(function(a) {
                        return typeof a === 'object' ? JSON.stringify(a) : String(a);
                    }).join(' ');
                    window.webkit.messageHandlers.bibleView.postMessage({
                        method: 'jsLog', args: ['WARN', msg]
                    });
                } catch(e) {}
            };
        })();
        // Double-tap toggles fullscreen mode (matching Android behavior). Android's
        // GestureDetector pairs taps within 300 ms and ~100 px of slop; the DOM dblclick
        // event instead follows the host pointer's double-click interval (the macOS system
        // setting under Mac Catalyst and the simulator), which pairs unrelated taps into
        // accidental fullscreen toggles. Detect the double tap manually with Android's
        // timing so single taps never toggle.
        (function() {
            var lastTap = null;
            document.addEventListener('click', function(e) {
                // Don't toggle fullscreen if clicking on interactive elements
                if (e.target.closest('a, button, input, textarea, [contenteditable]')) {
                    lastTap = null;
                    return;
                }
                var now = Date.now();
                if (lastTap && (now - lastTap.time) <= 300
                        && Math.abs(e.clientX - lastTap.x) <= 50
                        && Math.abs(e.clientY - lastTap.y) <= 50) {
                    lastTap = null;
                    window.webkit.messageHandlers.bibleView.postMessage({
                        method: 'toggleFullScreen',
                        args: []
                    });
                    return;
                }
                lastTap = { time: now, x: e.clientX, y: e.clientY };
            });
        })();
        """
    }

    /**
     Creates and configures the shared `WKWebView` used on both iOS and macOS.

     This method installs the native bridge handler, injects the Android compatibility shim
     used by the Vue.js client, attaches coordinator delegates, and loads the packaged
     `bibleview-js` bundle from SwiftPM resources.
     */
    func createWebView(coordinator: WebViewCoordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(EpubResourceSchemeHandler(), forURLScheme: EpubResourceLocator.scheme)
        let iosDeviceClass = Self.iosDeviceClass()

        // Register bridge message handler
        let contentController = WKUserContentController()
        contentController.add(session.bridge, name: BibleBridge.handlerName)

        // Inject platform detection and Android API shim before page loads.
        // The Vue.js code calls window.android.xxx() directly (from android.ts).
        // This Proxy routes those calls to the iOS WKScriptMessageHandler bridge.
        let platformScript = WKUserScript(
            source: Self.platformBootstrapScriptSource(deviceClass: iosDeviceClass),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        contentController.addUserScript(platformScript)

        // Inject selection detection script. Fires selectionChanged when text
        // is selected and selectionCleared when it collapses.
        let selectionScript = WKUserScript(
            source: """
            (function() {
                var __selTimer = null;
                document.addEventListener('selectionchange', function() {
                    clearTimeout(__selTimer);
                    __selTimer = setTimeout(function() {
                        var sel = window.getSelection();
                        if (sel && sel.rangeCount > 0 && !sel.getRangeAt(0).collapsed) {
                            var text = sel.toString().trim();
                            if (text.length > 0) {
                                window.webkit.messageHandlers.bibleView.postMessage({
                                    method: 'selectionChanged',
                                    args: [text]
                                });
                            }
                        } else {
                            window.webkit.messageHandlers.bibleView.postMessage({
                                method: 'selectionCleared',
                                args: []
                            });
                        }
                    }, 150);
                });
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        contentController.addUserScript(selectionScript)

        config.userContentController = contentController

        // Allow file access for local bundle
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        #if os(macOS)
        let webView = InteractionReportingWKWebView(frame: .zero, configuration: config)
        webView.onNativeUserInteraction = { [weak bridge = session.bridge] in
            bridge?.onNativeUserInteraction?()
        }
        #else
        let webView = WKWebView(frame: .zero, configuration: config)
        #endif
        webView.isInspectable = true

        #if os(iOS)
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = true
        // Ensure taps pass through to web content without delay
        webView.scrollView.delaysContentTouches = false
        webView.scrollView.canCancelContentTouches = true
        webView.scrollView.delegate = coordinator
        coordinator.installSwipeRecognizersIfNeeded(on: webView)
        #endif

        session.bridge.webView = webView
        coordinator.webView = webView
        webView.navigationDelegate = coordinator

        loadBibleViewBundle(into: webView)

        return webView
    }

    /// Loads the packaged Vue.js bundle, falling back to the placeholder page in development.
    private func loadBibleViewBundle(into webView: WKWebView) {
        // Look for the Vue.js built bundle first (bibleview-js/index.html)
        if let bundleURL = Self.moduleResourceURL(
            forResource: "index",
            withExtension: "html",
            subdirectories: ["bibleview-js", "Resources/bibleview-js"]
        ) {
            let bundleDir = bundleURL.deletingLastPathComponent()
            webView.loadFileURL(bundleURL, allowingReadAccessTo: bundleDir)
        } else if let bundleURL = Self.moduleResourceURL(
            forResource: "index",
            withExtension: "html",
            subdirectories: [nil, "Resources"]
        ) {
            // Fallback to placeholder
            let bundleDir = bundleURL.deletingLastPathComponent()
            webView.loadFileURL(bundleURL, allowingReadAccessTo: bundleDir)
        } else {
            webView.loadHTMLString("""
                <html><body style="background:#1a1a1a;color:#ccc;font-family:system-ui;padding:20px;">
                <h2>BibleView</h2>
                <p>Vue.js bundle not found. Build bibleview-js and copy output to Resources/</p>
                </body></html>
            """, baseURL: nil)
        }
    }

    private static func moduleResourceURL(
        forResource name: String,
        withExtension ext: String,
        subdirectories: [String?]
    ) -> URL? {
        for subdirectory in subdirectories {
            if let url = Bundle.module.url(
                forResource: name,
                withExtension: ext,
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        return nil
    }
}
