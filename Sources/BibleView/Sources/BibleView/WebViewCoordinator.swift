// WebViewCoordinator.swift — WKWebView navigation delegate

import Foundation
import WebKit
import os.log

private let logger = Logger(subsystem: "org.andbible", category: "WebViewCoordinator")

/// Coordinator for the WKWebView, handling navigation events and lifecycle.
public class WebViewCoordinator: NSObject, WKNavigationDelegate {
    let bridge: BibleBridge
    weak var webView: WKWebView?

    init(bridge: BibleBridge) {
        self.bridge = bridge
        super.init()
    }

    // MARK: - WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logger.info("BibleView page loaded successfully")
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        logger.error("BibleView navigation failed: \(error.localizedDescription)")
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Allow local file navigation, intercept external and app-internal links
        if let url = navigationAction.request.url {
            if url.isFileURL {
                decisionHandler(.allow)
            } else if url.scheme == "osis" || url.scheme == "multi" {
                // Cross-reference links: osis://?osis=Matt.1.1&v11n=KJV
                bridge.delegate?.bridge(bridge, openExternalLink: url.absoluteString)
                decisionHandler(.cancel)
            } else if url.scheme == "ab-w" {
                // ab-w:// links (Strong's/morphology) are handled via postMessage
                // from navigateLink() in Vue.js — just cancel the <a> tag navigation.
                decisionHandler(.cancel)
            } else if url.scheme == "ab-find-all" {
                // "Find all occurrences" links from FeaturesLink.vue
                bridge.delegate?.bridge(bridge, openExternalLink: url.absoluteString)
                decisionHandler(.cancel)
            } else if url.scheme == "https" || url.scheme == "http" {
                // External links through bridge delegate
                bridge.delegate?.bridge(bridge, openExternalLink: url.absoluteString)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        } else {
            decisionHandler(.allow)
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        logger.error("BibleView provisional navigation failed: \(error.localizedDescription)")
    }
}
