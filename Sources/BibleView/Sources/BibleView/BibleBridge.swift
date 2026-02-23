// BibleBridge.swift — WKScriptMessageHandler bridging Vue.js ↔ Swift

import Foundation
import WebKit
import BibleCore
import os.log

private let logger = Logger(subsystem: "org.andbible", category: "BibleBridge")

/// Protocol for handling bridge events from the Vue.js WebView.
public protocol BibleBridgeDelegate: AnyObject {
    // MARK: - Navigation & Scroll
    func bridge(_ bridge: BibleBridge, didScrollToOrdinal ordinal: Int, key: String)
    func bridge(_ bridge: BibleBridge, requestMoreToBeginning callId: Int)
    func bridge(_ bridge: BibleBridge, requestMoreToEnd callId: Int)

    // MARK: - Bookmarks
    func bridge(_ bridge: BibleBridge, addBookmark bookInitials: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool)
    func bridge(_ bridge: BibleBridge, addGenericBookmark bookInitials: String, osisRef: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool)
    func bridge(_ bridge: BibleBridge, removeBookmark bookmarkId: String)
    func bridge(_ bridge: BibleBridge, removeGenericBookmark bookmarkId: String)
    func bridge(_ bridge: BibleBridge, saveBookmarkNote bookmarkId: String, note: String?)
    func bridge(_ bridge: BibleBridge, assignLabels bookmarkId: String)
    func bridge(_ bridge: BibleBridge, toggleBookmarkLabel bookmarkId: String, labelId: String)
    func bridge(_ bridge: BibleBridge, removeBookmarkLabel bookmarkId: String, labelId: String)
    func bridge(_ bridge: BibleBridge, setPrimaryLabel bookmarkId: String, labelId: String)
    func bridge(_ bridge: BibleBridge, setBookmarkWholeVerse bookmarkId: String, value: Bool)
    func bridge(_ bridge: BibleBridge, setBookmarkCustomIcon bookmarkId: String, value: String?)

    // MARK: - Content Actions
    func bridge(_ bridge: BibleBridge, shareVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    func bridge(_ bridge: BibleBridge, copyVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    func bridge(_ bridge: BibleBridge, compareVerses bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    func bridge(_ bridge: BibleBridge, speak bookInitials: String, v11n: String, startOrdinal: Int, endOrdinal: Int)

    // MARK: - Navigation Actions
    func bridge(_ bridge: BibleBridge, openStudyPad labelId: String, bookmarkId: String)
    func bridge(_ bridge: BibleBridge, openMyNotes v11n: String, ordinal: Int)
    func bridge(_ bridge: BibleBridge, openExternalLink link: String)
    func bridgeDidRequestOpenDownloads(_ bridge: BibleBridge)

    // MARK: - Dialogs
    func bridge(_ bridge: BibleBridge, refChooserDialog callId: Int)
    func bridge(_ bridge: BibleBridge, parseRef callId: Int, text: String)
    func bridge(_ bridge: BibleBridge, helpDialog content: String, title: String?)

    // MARK: - Selection
    func bridge(_ bridge: BibleBridge, selectionChanged text: String)
    func bridgeSelectionCleared(_ bridge: BibleBridge)

    // MARK: - StudyPad
    func bridge(_ bridge: BibleBridge, createNewStudyPadEntry labelId: String, entryType: String, afterEntryId: String)
    func bridge(_ bridge: BibleBridge, deleteStudyPadEntry studyPadId: String)
    func bridge(_ bridge: BibleBridge, updateStudyPadTextEntry data: String)
    func bridge(_ bridge: BibleBridge, updateStudyPadTextEntryText id: String, text: String)
    func bridge(_ bridge: BibleBridge, updateOrderNumber labelId: String, data: String)
    func bridge(_ bridge: BibleBridge, updateBookmarkToLabel data: String)
    func bridge(_ bridge: BibleBridge, updateGenericBookmarkToLabel data: String)
    func bridge(_ bridge: BibleBridge, setBookmarkEditAction bookmarkId: String, value: String)
    func bridge(_ bridge: BibleBridge, setEditing enabled: Bool)
    func bridge(_ bridge: BibleBridge, setStudyPadCursor labelId: String, orderNumber: Int)

    // MARK: - State
    func bridge(_ bridge: BibleBridge, saveState state: String)
    func bridgeDidSetClientReady(_ bridge: BibleBridge)
    func bridge(_ bridge: BibleBridge, reportModalState isOpen: Bool)
    func bridge(_ bridge: BibleBridge, reportInputFocus focused: Bool)
    func bridge(_ bridge: BibleBridge, onKeyDown key: String)

    // MARK: - Toast & Sharing
    func bridge(_ bridge: BibleBridge, showToast text: String)
    func bridge(_ bridge: BibleBridge, shareHtml html: String)
    func bridge(_ bridge: BibleBridge, toggleCompareDocument documentId: String)

    // MARK: - EPUB Navigation
    func bridge(_ bridge: BibleBridge, openEpubLink bookInitials: String, toKey: String, toId: String)

    // MARK: - Fullscreen
    func bridgeDidRequestToggleFullScreen(_ bridge: BibleBridge)
}

/// WKScriptMessageHandler that bridges all 56+ methods between Vue.js and Swift.
///
/// Receives messages from JavaScript via:
/// ```javascript
/// window.webkit.messageHandlers.bibleView.postMessage({ method, args })
/// ```
///
/// Sends responses/events to JavaScript via:
/// ```swift
/// webView.evaluateJavaScript("bibleView.response(\(callId), \(jsonData))")
/// webView.evaluateJavaScript("bibleView.emit('\(event)', \(jsonData))")
/// ```
public final class BibleBridge: NSObject, WKScriptMessageHandler {
    /// The message handler name registered with WKWebView.
    public static let handlerName = "bibleView"

    /// Delegate for handling bridge events.
    public weak var delegate: BibleBridgeDelegate?

    /// Reference to the web view for sending responses.
    public weak var webView: WKWebView?

    /// Whether the ambiguous selection modal should be size-limited.
    public var limitAmbiguousModalSize: Bool = false

    public override init() {
        super.init()
    }

    // MARK: - WKScriptMessageHandler

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String else {
            logger.warning("Invalid bridge message: \(String(describing: message.body))")
            return
        }

        let args = body["args"] as? [Any] ?? []

        switch method {
        // --- Tier 1: Logging & State ---
        case "console":
            handleConsole(args)
        case "toast":
            handleToast(args)
        case "setClientReady":
            delegate?.bridgeDidSetClientReady(self)
        case "reportModalState":
            delegate?.bridge(self, reportModalState: args.first as? Bool ?? false)
        case "reportInputFocus":
            delegate?.bridge(self, reportInputFocus: args.first as? Bool ?? false)
        case "setLimitAmbiguousModalSize":
            limitAmbiguousModalSize = args.first as? Bool ?? false
        case "selectionCleared":
            delegate?.bridgeSelectionCleared(self)
        case "selectionChanged":
            if let text = args.first as? String {
                delegate?.bridge(self, selectionChanged: text)
            }
        case "setEditing":
            delegate?.bridge(self, setEditing: args.first as? Bool ?? false)
        case "saveState":
            if let state = args.first as? String {
                delegate?.bridge(self, saveState: state)
            }
        case "onKeyDown":
            if let key = args.first as? String {
                delegate?.bridge(self, onKeyDown: key)
            }

        // --- Navigation & Scroll ---
        case "scrolledToOrdinal":
            if let key = args[safe: 0] as? String, let ordinal = args[safe: 1] as? Int {
                delegate?.bridge(self, didScrollToOrdinal: ordinal, key: key)
            }
        case "requestMoreToBeginning":
            if let callId = args.first as? Int {
                delegate?.bridge(self, requestMoreToBeginning: callId)
            }
        case "requestMoreToEnd":
            if let callId = args.first as? Int {
                delegate?.bridge(self, requestMoreToEnd: callId)
            }

        // --- Bookmark Operations ---
        case "addBookmark":
            if let initials = args[safe: 0] as? String,
               let start = args[safe: 1] as? Int,
               let end = args[safe: 2] as? Int,
               let addNote = args[safe: 3] as? Bool {
                delegate?.bridge(self, addBookmark: initials, startOrdinal: start, endOrdinal: end <= 0 ? start : end, addNote: addNote)
            }
        case "addGenericBookmark":
            if let initials = args[safe: 0] as? String,
               let osisRef = args[safe: 1] as? String,
               let start = args[safe: 2] as? Int,
               let end = args[safe: 3] as? Int,
               let addNote = args[safe: 4] as? Bool {
                delegate?.bridge(self, addGenericBookmark: initials, osisRef: osisRef, startOrdinal: start, endOrdinal: end < 0 ? start : end, addNote: addNote)
            }
        case "removeBookmark":
            if let id = args.first as? String {
                delegate?.bridge(self, removeBookmark: id)
            }
        case "removeGenericBookmark":
            if let id = args.first as? String {
                delegate?.bridge(self, removeGenericBookmark: id)
            }
        case "saveBookmarkNote":
            if let id = args[safe: 0] as? String {
                let note = args[safe: 1] as? String
                delegate?.bridge(self, saveBookmarkNote: id, note: note)
            }
        case "saveGenericBookmarkNote":
            if let id = args[safe: 0] as? String {
                let note = args[safe: 1] as? String
                delegate?.bridge(self, saveBookmarkNote: id, note: note)
            }
        case "assignLabels":
            if let id = args.first as? String {
                delegate?.bridge(self, assignLabels: id)
            }
        case "genericAssignLabels":
            if let id = args.first as? String {
                delegate?.bridge(self, assignLabels: id)
            }
        case "toggleBookmarkLabel", "toggleGenericBookmarkLabel":
            if let bmId = args[safe: 0] as? String, let lblId = args[safe: 1] as? String {
                delegate?.bridge(self, toggleBookmarkLabel: bmId, labelId: lblId)
            }
        case "removeBookmarkLabel", "removeGenericBookmarkLabel":
            if let bmId = args[safe: 0] as? String, let lblId = args[safe: 1] as? String {
                delegate?.bridge(self, removeBookmarkLabel: bmId, labelId: lblId)
            }
        case "setAsPrimaryLabel", "setAsPrimaryLabelGeneric":
            if let bmId = args[safe: 0] as? String, let lblId = args[safe: 1] as? String {
                delegate?.bridge(self, setPrimaryLabel: bmId, labelId: lblId)
            }
        case "setBookmarkWholeVerse", "setGenericBookmarkWholeVerse":
            if let id = args[safe: 0] as? String, let val = args[safe: 1] as? Bool {
                delegate?.bridge(self, setBookmarkWholeVerse: id, value: val)
            }
        case "setBookmarkCustomIcon", "setGenericBookmarkCustomIcon":
            if let id = args[safe: 0] as? String {
                delegate?.bridge(self, setBookmarkCustomIcon: id, value: args[safe: 1] as? String)
            }

        // --- Content Actions ---
        // Note: JavaScript sends endOrdinal=-1 to mean "single verse" (same as start).
        // Normalize here so delegate methods don't need to handle -1.
        case "shareVerse":
            if let initials = args[safe: 0] as? String,
               let start = args[safe: 1] as? Int,
               let end = args[safe: 2] as? Int {
                delegate?.bridge(self, shareVerse: initials, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            }
        case "copyVerse":
            if let initials = args[safe: 0] as? String,
               let start = args[safe: 1] as? Int,
               let end = args[safe: 2] as? Int {
                delegate?.bridge(self, copyVerse: initials, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            }
        case "shareBookmarkVerse":
            if let bookmark = args.first as? [String: Any],
               let ordinalRange = bookmark["ordinalRange"] as? [Int],
               ordinalRange.count >= 2 {
                let initials = bookmark["bookInitials"] as? String ?? ""
                delegate?.bridge(self, shareVerse: initials, startOrdinal: ordinalRange[0], endOrdinal: ordinalRange[1])
            }
        case "compare":
            if let initials = args[safe: 0] as? String,
               let start = args[safe: 1] as? Int,
               let end = args[safe: 2] as? Int {
                delegate?.bridge(self, compareVerses: initials, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            }
        case "speak", "speakGeneric":
            if let initials = args[safe: 0] as? String,
               let v11n = args[safe: 1] as? String,
               let start = args[safe: 2] as? Int,
               let end = args[safe: 3] as? Int {
                delegate?.bridge(self, speak: initials, v11n: v11n, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            }
        case "memorize":
            break // Memorize mode — future feature, not yet implemented on iOS
        case "addParagraphBreakBookmark", "addGenericParagraphBreakBookmark":
            break // Paragraph break bookmarks — Android-specific, not applicable on iOS

        // --- StudyPad ---
        case "openStudyPad":
            if let labelId = args[safe: 0] as? String, let bmId = args[safe: 1] as? String {
                delegate?.bridge(self, openStudyPad: labelId, bookmarkId: bmId)
            }
        case "openMyNotes":
            if let v11n = args[safe: 0] as? String, let ordinal = args[safe: 1] as? Int {
                delegate?.bridge(self, openMyNotes: v11n, ordinal: ordinal)
            }
        case "deleteStudyPadEntry":
            if let id = args.first as? String {
                delegate?.bridge(self, deleteStudyPadEntry: id)
            }
        case "createNewStudyPadEntry":
            if let labelId = args[safe: 0] as? String,
               let entryType = args[safe: 1] as? String,
               let afterId = args[safe: 2] as? String {
                delegate?.bridge(self, createNewStudyPadEntry: labelId, entryType: entryType, afterEntryId: afterId)
            }
        case "setStudyPadCursor":
            if let labelId = args[safe: 0] as? String,
               let orderNumber = args[safe: 1] as? Int {
                delegate?.bridge(self, setStudyPadCursor: labelId, orderNumber: orderNumber)
            }
        case "updateOrderNumber":
            if let labelId = args[safe: 0] as? String,
               let data = args[safe: 1] as? String {
                delegate?.bridge(self, updateOrderNumber: labelId, data: data)
            }
        case "updateStudyPadTextEntry":
            if let data = args.first as? String {
                delegate?.bridge(self, updateStudyPadTextEntry: data)
            }
        case "updateStudyPadTextEntryText":
            if let id = args[safe: 0] as? String,
               let text = args[safe: 1] as? String {
                delegate?.bridge(self, updateStudyPadTextEntryText: id, text: text)
            }
        case "updateBookmarkToLabel":
            if let data = args.first as? String {
                delegate?.bridge(self, updateBookmarkToLabel: data)
            }
        case "updateGenericBookmarkToLabel":
            if let data = args.first as? String {
                delegate?.bridge(self, updateGenericBookmarkToLabel: data)
            }
        case "setBookmarkEditAction":
            if let bmId = args[safe: 0] as? String,
               let value = args[safe: 1] as? String {
                delegate?.bridge(self, setBookmarkEditAction: bmId, value: value)
            }

        // --- Navigation ---
        case "openExternalLink":
            if let link = args.first as? String {
                delegate?.bridge(self, openExternalLink: link)
            }
        case "openEpubLink":
            if let bookInitials = args[safe: 0] as? String,
               let toKey = args[safe: 1] as? String,
               let toId = args[safe: 2] as? String {
                delegate?.bridge(self, openEpubLink: bookInitials, toKey: toKey, toId: toId)
            }
        case "openDownloads":
            delegate?.bridgeDidRequestOpenDownloads(self)
        case "toggleCompareDocument":
            if let docId = args.first as? String {
                delegate?.bridge(self, toggleCompareDocument: docId)
            }

        // --- Dialogs ---
        case "refChooserDialog":
            if let callId = args.first as? Int {
                delegate?.bridge(self, refChooserDialog: callId)
            }
        case "parseRef":
            if let callId = args[safe: 0] as? Int, let text = args[safe: 1] as? String {
                delegate?.bridge(self, parseRef: callId, text: text)
            }
        case "helpDialog":
            if let content = args[safe: 0] as? String {
                delegate?.bridge(self, helpDialog: content, title: args[safe: 1] as? String)
            }
        case "helpBookmarks":
            delegate?.bridge(self, helpDialog: "Bookmarks Help", title: "Bookmarks")
        case "shareHtml":
            if let html = args.first as? String {
                delegate?.bridge(self, shareHtml: html)
            }
        case "getActiveLanguages":
            break // Handled synchronously via proxy shim (see BibleWebView.swift)

        case "toggleFullScreen":
            delegate?.bridgeDidRequestToggleFullScreen(self)

        default:
            logger.debug("Unhandled bridge method: \(method)")
        }
    }

    // MARK: - Send to JavaScript

    /// Send an async response back to JavaScript.
    public func sendResponse(callId: Int, value: String) {
        let js = "bibleView.response(\(callId), \(value));"
        evaluateJavaScript(js)
    }

    /// Send an async response with a JSON-encodable value.
    public func sendResponse<T: Encodable>(callId: Int, value: T) {
        guard let data = try? bridgeEncoder.encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        sendResponse(callId: callId, value: json)
    }

    /// Emit an event to Vue.js.
    public func emit(event: String, data: String = "null") {
        let js = "try { bibleView.emit('\(event)', \(data)); } catch(e) { window.webkit.messageHandlers.bibleView.postMessage({method:'console',args:['BRIDGE','JS EMIT ERROR in \(event): ' + e.message + ' ' + e.stack]}); }"
        evaluateJavaScript(js)
    }

    /// Emit an event with a JSON-encodable payload.
    public func emit<T: Encodable>(event: String, data: T) {
        guard let jsonData = try? bridgeEncoder.encode(data),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        emit(event: event, data: json)
    }

    /// Query the current text selection from the WebView DOM.
    /// Returns ordinal range and text, or nil if no selection.
    @MainActor
    public func querySelection() async -> (text: String, startOrdinal: Int?, endOrdinal: Int?)? {
        guard let webView else { return nil }
        let js = """
        (function() {
            var sel = window.getSelection();
            if (!sel || sel.rangeCount === 0 || sel.getRangeAt(0).collapsed) return null;
            var text = sel.toString().trim();
            if (!text) return null;
            var range = sel.getRangeAt(0);
            function findOrdinal(node) {
                var el = (node.nodeType === 1) ? node : node.parentElement;
                while (el && el !== document.body) {
                    if (el.dataset && el.dataset.ordinal) return parseInt(el.dataset.ordinal);
                    var closest = el.closest ? el.closest('[data-ordinal]') : null;
                    if (closest) return parseInt(closest.dataset.ordinal);
                    el = el.parentElement;
                }
                return null;
            }
            var startOrd = findOrdinal(range.startContainer);
            var endOrd = findOrdinal(range.endContainer);
            return JSON.stringify({text: text, startOrdinal: startOrd, endOrdinal: endOrd});
        })()
        """
        do {
            let result = try await webView.evaluateJavaScript(js)
            if let jsonStr = result as? String,
               let data = jsonStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let text = dict["text"] as? String ?? ""
                let startOrd = dict["startOrdinal"] as? Int
                let endOrd = dict["endOrdinal"] as? Int
                return (text, startOrd, endOrd)
            }
        } catch {
            logger.debug("querySelection JS error: \(error.localizedDescription)")
        }
        return nil
    }

    /// Clear the current text selection in the WebView.
    public func clearSelection() {
        evaluateJavaScript("window.getSelection().removeAllRanges();")
    }

    /// Update the cached active languages in the WebView's JavaScript context.
    /// Called when modules are installed/uninstalled so `getActiveLanguages()` returns current data.
    public func updateActiveLanguages(_ languages: [String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: languages),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluateJavaScript("window.__activeLanguages__ = '\(json)';")
    }

    private func evaluateJavaScript(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            guard let webView = self?.webView else {
                NSLog("BRIDGE-JS: webView is nil! Cannot evaluate: %@", String(js.prefix(200)))
                return
            }
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    NSLog("BRIDGE-JS ERROR: %@ for JS: %@", error.localizedDescription, String(js.prefix(200)))
                }
            }
        }
    }

    // MARK: - Handlers

    private func handleConsole(_ args: [Any]) {
        let loggerName = args[safe: 0] as? String ?? "unknown"
        let message = args[safe: 1] as? String ?? ""
        logger.debug("[\(loggerName)] \(message)")
    }

    private func handleToast(_ args: [Any]) {
        guard let text = args.first as? String else { return }
        logger.info("Toast: \(text)")
        delegate?.bridge(self, showToast: text)
    }
}

// MARK: - Array Safe Subscript

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
