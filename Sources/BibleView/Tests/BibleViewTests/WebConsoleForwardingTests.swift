import XCTest
import WebKit
@testable import BibleView

/** Executes the production bootstrap in real WebKit to verify logging cost and error visibility. */
@MainActor
final class WebConsoleForwardingTests: XCTestCase {
    /** Ordinary reading forwards warnings/errors without serializing verbose document objects. */
    func testOrdinaryLoggingSkipsVerboseSerializationAndPreservesWarningsAndErrors() async throws {
        try await verifyForwarding(verbose: false)
    }

    /** An explicit diagnostic run can still collect verbose native logs exactly once. */
    func testVerboseLoggingCanBeEnabledExplicitly() async throws {
        try await verifyForwarding(verbose: true)
    }

    /**
     Loads an isolated page with the actual bootstrap, then observes native messages and toJSON work.

     The object conversion counter is independent of the implementation: a disabled native log must
     not invoke user object serialization. WebKit's ordinary console still receives the original
     value. Only the native handler and navigation completion are recorded; no JavaScript engine or
     bridge serialization is replaced. Teardown removes the handler and stops page loading.
     */
    private func verifyForwarding(verbose: Bool) async throws {
        let loaded = expectation(description: "WebKit loaded isolated logging page")
        let forwarded = expectation(description: "Native diagnostic messages arrived")
        forwarded.expectedFulfillmentCount = verbose ? 3 : 2
        let recorder = Recorder(loaded: loaded, forwarded: forwarded)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(recorder, name: BibleBridge.handlerName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: BibleWebView.platformBootstrapScriptSource(
                deviceClass: "ios-phone", forwardsVerboseConsole: verbose
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = recorder
        defer {
            webView.stopLoading()
            configuration.userContentController.removeScriptMessageHandler(forName: BibleBridge.handlerName)
        }
        webView.loadHTMLString("<!doctype html><html><head></head><body>Logging contract</body></html>", baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)
        let conversions = try await webView.evaluateJavaScript("""
        (() => {
            let conversions = 0;
            const documentValue = {toJSON() { conversions++; return 'x'.repeat(262144); }};
            console.log('document', documentValue);
            console.warn('warning remains visible');
            console.error('error remains visible');
            return conversions;
        })()
        """) as? Int
        await fulfillment(of: [forwarded], timeout: 10)
        XCTAssertEqual(conversions, verbose ? 1 : 0)
        XCTAssertEqual(recorder.messages.map(\.level), verbose ? ["LOG", "WARN", "ERROR"] : ["WARN", "ERROR"])
        XCTAssertEqual(recorder.messages.suffix(2).map(\.text), ["warning remains visible", "error remains visible"])
        if verbose {
            XCTAssertGreaterThan(recorder.messages[0].text.utf8.count, 262144)
        }
    }

    /** Records actual WebKit delivery without participating in serialization or logging policy. */
    @MainActor
    private final class Recorder: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let loaded: XCTestExpectation
        let forwarded: XCTestExpectation
        var messages: [(level: String, text: String)] = []

        /** Stores the two bounded asynchronous endpoints for this isolated WebKit page. */
        init(loaded: XCTestExpectation, forwarded: XCTestExpectation) {
            self.loaded = loaded
            self.forwarded = forwarded
        }

        /** Records only diagnostic messages, preserving delivery order and original text. */
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], body["method"] as? String == "jsLog",
                  let arguments = body["args"] as? [String], arguments.count == 2 else { return }
            messages.append((arguments[0], arguments[1]))
            forwarded.fulfill()
        }

        /** Signals real navigation completion before the test evaluates its console actions. */
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded.fulfill()
        }
    }
}
