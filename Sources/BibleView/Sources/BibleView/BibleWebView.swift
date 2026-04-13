// BibleWebView.swift — WKWebView container for Vue.js Bible rendering

import SwiftUI
import WebKit

/**
 SwiftUI wrapper around WKWebView that loads the Vue.js Bible frontend.

 Usage:
 ```swift
 BibleWebView(bridge: bridge)
     .onAppear { bridge.emit(event: "loadDocument", data: documentJson) }
 ```
 */
#if os(iOS)
/**
 UIViewController that hosts the WKWebView.
 Using a view controller (instead of bare UIViewRepresentable) ensures the
 WKWebView participates in the full UIKit responder chain and receives
 touch/click events reliably inside SwiftUI.
 */
public class BibleWebViewController: UIViewController {
    let webView: WKWebView
    let bridge: BibleBridge
    var backgroundColorInt: Int = -1

    /// Creates the UIKit host for a bridge-backed `WKWebView`.
    init(webView: WKWebView, bridge: BibleBridge) {
        self.webView = webView
        self.bridge = bridge
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Installs and pins the web view to the controller's bounds.
    public override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        applyBackground()
    }

    /// Applies the configured ARGB background color to all visible web view surfaces.
    func applyBackground() {
        let color = BibleWebView.uiColor(fromArgbInt: backgroundColorInt)
        webView.isOpaque = false
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

 The native bridge/controller layer owns this view and uses `BibleBridge.emit(event:data:)`
 to push documents, config, and bookmark updates into the already loaded client bundle.
 */
public struct BibleWebView: UIViewControllerRepresentable {
    public typealias UIViewControllerType = BibleWebViewController

    let bridge: BibleBridge
    let initialState: String?
    var backgroundColorInt: Int

    /// Creates a new bridge-backed web view wrapper.
    public init(bridge: BibleBridge, initialState: String? = nil, backgroundColorInt: Int = -1) {
        self.bridge = bridge
        self.initialState = initialState
        self.backgroundColorInt = backgroundColorInt
    }

    /// Builds the UIKit controller wrapper and initial web view.
    public func makeUIViewController(context: Context) -> BibleWebViewController {
        let webView = createWebView(coordinator: context.coordinator)
        let vc = BibleWebViewController(webView: webView, bridge: bridge)
        vc.backgroundColorInt = backgroundColorInt
        return vc
    }

    /// Reapplies visual state that can change after creation.
    public func updateUIViewController(_ vc: BibleWebViewController, context: Context) {
        vc.backgroundColorInt = backgroundColorInt
        vc.applyBackground()
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

    /// Creates the coordinator that owns navigation, logging, and gesture callbacks.
    public func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(bridge: bridge)
    }
}
#elseif os(macOS)
/// macOS variant of `BibleWebView` using `NSViewRepresentable`.
public struct BibleWebView: NSViewRepresentable {
    public typealias NSViewType = WKWebView

    let bridge: BibleBridge
    let initialState: String?
    var backgroundColorInt: Int

    /// Creates a new bridge-backed macOS web view wrapper.
    public init(bridge: BibleBridge, initialState: String? = nil, backgroundColorInt: Int = -1) {
        self.bridge = bridge
        self.initialState = initialState
        self.backgroundColorInt = backgroundColorInt
    }

    /// Builds the `WKWebView` and attaches the coordinator.
    public func makeNSView(context: Context) -> WKWebView {
        let webView = createWebView(coordinator: context.coordinator)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    /// macOS currently has no incremental update work beyond the bridge itself.
    public func updateNSView(_ webView: WKWebView, context: Context) {}

    /// Creates the coordinator that owns navigation and logging callbacks.
    public func makeCoordinator() -> WebViewCoordinator {
        WebViewCoordinator(bridge: bridge)
    }
}
#endif

// MARK: - Shared WebView Creation

extension BibleWebView {
    /**
     Creates and configures the shared `WKWebView` used on both iOS and macOS.

     This method installs the native bridge handler, injects the Android compatibility shim
     used by the Vue.js client, attaches coordinator delegates, and loads the packaged
     `bibleview-js` bundle from SwiftPM resources.
     */
    func createWebView(coordinator: WebViewCoordinator) -> WKWebView {
        let config = WKWebViewConfiguration()
        #if os(iOS)
        let iosDeviceClass = UIDevice.current.userInterfaceIdiom == .pad ? "ios-pad" : "ios-phone"
        #else
        let iosDeviceClass = "ios-phone"
        #endif

        // Register bridge message handler
        let contentController = WKUserContentController()
        contentController.add(bridge, name: BibleBridge.handlerName)

        // Inject platform detection and Android API shim before page loads.
        // The Vue.js code calls window.android.xxx() directly (from android.ts).
        // This Proxy routes those calls to the iOS WKScriptMessageHandler bridge.
        let platformScript = WKUserScript(
            source: """
            window.__PLATFORM__ = 'ios';
            window.__activeLanguages__ = '["en"]';
            window.__IOS_DEVICE_CLASS__ = '\(iosDeviceClass)';
            window.bibleView = {};
            window.bibleViewDebug = {};
            (function() {
                function applyPlatformClasses() {
                    if (!document.documentElement) return;
                    document.documentElement.classList.add('platform-ios');
                    document.documentElement.classList.add('\(iosDeviceClass)');
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
            // Double-click/tap toggles fullscreen mode (matching Android behavior)
            document.addEventListener('dblclick', function(e) {
                // Don't toggle fullscreen if clicking on interactive elements
                if (e.target.closest('a, button, input, textarea, [contenteditable]')) return;
                window.webkit.messageHandlers.bibleView.postMessage({
                    method: 'toggleFullScreen',
                    args: []
                });
            });
            """,
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

        let webView = WKWebView(frame: .zero, configuration: config)
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

        bridge.webView = webView
        coordinator.webView = webView
        webView.navigationDelegate = coordinator

        loadBibleViewBundle(into: webView)

        return webView
    }

    /// Loads the packaged Vue.js bundle, falling back to the placeholder page in development.
    private func loadBibleViewBundle(into webView: WKWebView) {
        // Look for the Vue.js built bundle first (bibleview-js/index.html)
        if let bundleURL = Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "Resources/bibleview-js"
        ) {
            let bundleDir = bundleURL.deletingLastPathComponent()
            webView.loadFileURL(bundleURL, allowingReadAccessTo: bundleDir)
        } else if let bundleURL = Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "Resources"
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
}
