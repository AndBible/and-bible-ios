// BibleBridge.swift — WKScriptMessageHandler bridging Vue.js ↔ Swift

import Foundation
import WebKit
import BibleCore
import os.log

private let logger = Logger(subsystem: "org.andbible", category: "BibleBridge")

/**
 Direction reported by native `UISwipeGestureRecognizer` handlers installed on the web view.

 `BibleReaderView` maps these values onto Android-style chapter or page navigation depending
 on the current `bible_view_swipe_mode` setting.
 */
public enum NativeHorizontalSwipeDirection: Sendable {
    case left
    case right
}

/// Protocol for handling bridge events from the Vue.js WebView.
public protocol BibleBridgeDelegate: AnyObject {
    // MARK: - Navigation & Scroll
    /**
     Reports the verse ordinal currently nearest the top of the rendered document.

     Vue.js sends this when scrolling so native code can persist reading position and history.
     Android equivalent: `BibleJavascriptInterface.scrolledToOrdinal(...)`.
     */
    func bridge(_ bridge: BibleBridge, didScrollToOrdinal ordinal: Int, key: String, atChapterTop: Bool)
    /**
     Requests additional content before the currently rendered range.

     Used by infinite-scroll style chapter expansion. The delegate should respond with
     `sendResponse(callId:value:)` once more content has been loaded.
     */
    func bridge(_ bridge: BibleBridge, requestMoreToBeginning callId: Int)
    /**
     Requests additional content after the currently rendered range.

     Used by infinite-scroll style chapter expansion. The delegate should respond with
     `sendResponse(callId:value:)` once more content has been loaded.
     */
    func bridge(_ bridge: BibleBridge, requestMoreToEnd callId: Int)

    // MARK: - Bookmarks
    /**
     Creates or edits a verse bookmark for the current Bible document selection.

     Android equivalent: `BibleJavascriptInterface.addBookmark(...)`.
     */
    func bridge(_ bridge: BibleBridge, addBookmark bookInitials: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool)
    /// Creates or edits a bookmark for non-Bible content such as dictionaries or general books.
    func bridge(_ bridge: BibleBridge, addGenericBookmark bookInitials: String, osisRef: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool)
    /// Deletes a Bible bookmark identified by its persisted UUID string.
    func bridge(_ bridge: BibleBridge, removeBookmark bookmarkId: String)
    /// Deletes a non-Bible bookmark identified by its persisted UUID string.
    func bridge(_ bridge: BibleBridge, removeGenericBookmark bookmarkId: String)
    /// Persists a note attached to an existing bookmark.
    func bridge(_ bridge: BibleBridge, saveBookmarkNote bookmarkId: String, note: String?)
    /// Opens the native label assignment UI for the specified bookmark.
    func bridge(_ bridge: BibleBridge, assignLabels bookmarkId: String)
    /// Toggles a label assignment on a bookmark.
    func bridge(_ bridge: BibleBridge, toggleBookmarkLabel bookmarkId: String, labelId: String)
    /// Removes a label assignment from a bookmark.
    func bridge(_ bridge: BibleBridge, removeBookmarkLabel bookmarkId: String, labelId: String)
    /// Marks one label as the bookmark's primary label for styling and StudyPad grouping.
    func bridge(_ bridge: BibleBridge, setPrimaryLabel bookmarkId: String, labelId: String)
    /// Switches a bookmark between whole-verse highlighting and partial-selection highlighting.
    func bridge(_ bridge: BibleBridge, setBookmarkWholeVerse bookmarkId: String, value: Bool)
    /// Sets or clears a custom icon override for a bookmark.
    func bridge(_ bridge: BibleBridge, setBookmarkCustomIcon bookmarkId: String, value: String?)

    // MARK: - Content Actions
    /// Shares the selected verse range using native share UI.
    func bridge(_ bridge: BibleBridge, shareVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    /// Copies the selected verse range to the system pasteboard.
    func bridge(_ bridge: BibleBridge, copyVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    /// Opens the compare view for the selected verse range.
    func bridge(_ bridge: BibleBridge, compareVerses bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    /// Starts text-to-speech playback for the selected verse range and versification.
    func bridge(_ bridge: BibleBridge, speak bookInitials: String, v11n: String, startOrdinal: Int, endOrdinal: Int)

    // MARK: - Navigation Actions
    /// Opens the StudyPad view focused on the supplied label and bookmark.
    func bridge(_ bridge: BibleBridge, openStudyPad labelId: String, bookmarkId: String)
    /// Opens the "My Notes" view for the current versification and verse ordinal.
    func bridge(_ bridge: BibleBridge, openMyNotes v11n: String, ordinal: Int)
    /// Handles an app-internal or external hyperlink tapped in the web content.
    func bridge(_ bridge: BibleBridge, openExternalLink link: String)
    /// Opens the downloads/module management UI.
    func bridgeDidRequestOpenDownloads(_ bridge: BibleBridge)

    // MARK: - Dialogs
    /// Requests the native reference chooser and expects an async response via `sendResponse`.
    func bridge(_ bridge: BibleBridge, refChooserDialog callId: Int)
    /// Requests native reference parsing for free-form user input.
    func bridge(_ bridge: BibleBridge, parseRef callId: Int, text: String)
    /// Shows help content generated by the web client in a native dialog.
    func bridge(_ bridge: BibleBridge, helpDialog content: String, title: String?)

    // MARK: - Selection
    /// Reports the plain-text value of the current DOM selection.
    func bridge(_ bridge: BibleBridge, selectionChanged text: String)
    /// Reports that the DOM selection has been cleared or collapsed.
    func bridgeSelectionCleared(_ bridge: BibleBridge)

    // MARK: - StudyPad
    /// Creates a new StudyPad entry after the supplied entry identifier.
    func bridge(_ bridge: BibleBridge, createNewStudyPadEntry labelId: String, entryType: String, afterEntryId: String)
    /// Deletes a StudyPad entry by identifier.
    func bridge(_ bridge: BibleBridge, deleteStudyPadEntry studyPadId: String)
    /// Replaces a full serialized StudyPad text entry payload.
    func bridge(_ bridge: BibleBridge, updateStudyPadTextEntry data: String)
    /// Updates only the text field of an existing StudyPad text entry.
    func bridge(_ bridge: BibleBridge, updateStudyPadTextEntryText id: String, text: String)
    /// Persists reordered StudyPad items for a label.
    func bridge(_ bridge: BibleBridge, updateOrderNumber labelId: String, data: String)
    /// Persists reordered or reparented bookmark-to-label relationships.
    func bridge(_ bridge: BibleBridge, updateBookmarkToLabel data: String)
    /// Persists reordered or reparented generic-bookmark-to-label relationships.
    func bridge(_ bridge: BibleBridge, updateGenericBookmarkToLabel data: String)
    /// Stores the bookmark editing mode requested by the StudyPad UI.
    func bridge(_ bridge: BibleBridge, setBookmarkEditAction bookmarkId: String, value: String)
    /// Reports whether the web StudyPad editor has entered editing mode.
    func bridge(_ bridge: BibleBridge, setEditing enabled: Bool)
    /// Persists the current StudyPad cursor location for a label.
    func bridge(_ bridge: BibleBridge, setStudyPadCursor labelId: String, orderNumber: Int)

    // MARK: - State
    /// Saves opaque client-side UI state such as scroll position and expanded document ranges.
    func bridge(_ bridge: BibleBridge, saveState state: String)
    /// Signals that the Vue.js client finished bootstrapping and can receive events safely.
    func bridgeDidSetClientReady(_ bridge: BibleBridge)
    /// Reports whether the web client currently has a modal dialog open.
    func bridge(_ bridge: BibleBridge, reportModalState isOpen: Bool)
    /// Reports whether an editable field inside the web client currently has keyboard focus.
    func bridge(_ bridge: BibleBridge, reportInputFocus focused: Bool)
    /// Forwards raw key presses from the web client to native code.
    func bridge(_ bridge: BibleBridge, onKeyDown key: String)

    // MARK: - Toast & Sharing
    /// Requests a transient native toast/banner message.
    func bridge(_ bridge: BibleBridge, showToast text: String)
    /// Shares HTML rendered by the client rather than plain verse text.
    func bridge(_ bridge: BibleBridge, shareHtml html: String)
    /// Toggles a compare document on or off in the native compare state.
    func bridge(_ bridge: BibleBridge, toggleCompareDocument documentId: String)

    // MARK: - EPUB Navigation
    /// Navigates from one EPUB anchor to another anchor or key within the same module.
    func bridge(_ bridge: BibleBridge, openEpubLink bookInitials: String, toKey: String, toId: String)

    // MARK: - Fullscreen
    /// Toggles native fullscreen mode in response to a client-side double tap gesture.
    func bridgeDidRequestToggleFullScreen(_ bridge: BibleBridge)
}

/**
 WKScriptMessageHandler that bridges all 56+ methods between Vue.js and Swift.

 Receives messages from JavaScript via:
 ```javascript
 window.webkit.messageHandlers.bibleView.postMessage({ method, args })
 ```

 Sends responses/events to JavaScript via:
 ```swift
 webView.evaluateJavaScript("bibleView.response(\(callId), \(jsonData))")
 webView.evaluateJavaScript("bibleView.emit('\(event)', \(jsonData))")
 ```
 */
public final class BibleBridge: NSObject, WKScriptMessageHandler {
    /// The message handler name registered with WKWebView.
    public static let handlerName = "bibleView"

    /// Delegate for handling bridge events.
    public weak var delegate: BibleBridgeDelegate?

    /// Reference to the web view for sending responses.
    public weak var webView: WKWebView?

    /// Whether the ambiguous selection modal should be size-limited.
    public var limitAmbiguousModalSize: Bool = false

    /// Fires on every bridge message — used to detect user interaction for active window tracking.
    public var onAnyMessage: (() -> Void)?

    /// Fires for native user-driven webview scroll deltas (positive = down).
    public var onNativeScrollDeltaY: ((Double) -> Void)?

    /// Fires for native user-driven horizontal swipe gestures.
    public var onNativeHorizontalSwipe: ((NativeHorizontalSwipeDirection) -> Void)?

    /// Creates a new bridge instance before it is attached to a web view.
    public override init() {
        super.init()
    }

    // MARK: - WKScriptMessageHandler

    /**
     Dispatches a message posted by the Vue.js client into typed native delegate callbacks.

     Messages arrive as `{ method, args }` dictionaries through the registered
     `window.webkit.messageHandlers.bibleView` handler. This method is the central routing point
     for all client-originated actions.
     */
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

        // Notify listener for active window tracking, but skip passive/background
        // messages that don't represent user interaction to avoid focus ping-pong.
        switch method {
        case "console", "jsLog", "reportModalState", "reportInputFocus",
             "setClientReady", "saveState", "setLimitAmbiguousModalSize",
             "selectionCleared", "setEditing":
            break
        default:
            onAnyMessage?()
        }

        switch method {
        // --- Logging & state sync from JavaScript to native ---
        case "console":
            handleConsole(args)
        case "jsLog":
            // Routed from console.log/error/warn interceptor in BibleWebView.swift
            if let level = args.first as? String, let msg = args.last as? String {
                switch level {
                case "ERROR":
                    logger.error("[JS] \(msg)")
                case "WARN":
                    logger.warning("[JS] \(msg)")
                default:
                    logger.info("[JS] \(msg)")
                }
            }
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

        // --- Navigation & scroll position ---
        case "scrolledToOrdinal":
            if let key = args[safe: 0] as? String, let ordinal = args[safe: 1] as? Int {
                let atChapterTop = args[safe: 2] as? Bool ?? false
                delegate?.bridge(self, didScrollToOrdinal: ordinal, key: key, atChapterTop: atChapterTop)
            }
        case "requestMoreToBeginning":
            if let callId = args.first as? Int {
                delegate?.bridge(self, requestMoreToBeginning: callId)
            }
        case "requestMoreToEnd":
            if let callId = args.first as? Int {
                delegate?.bridge(self, requestMoreToEnd: callId)
            }

        // --- Bookmark CRUD and label assignment ---
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

        // --- Content actions (share/copy/compare/speak) ---
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

        // --- StudyPad editing and ordering ---
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

        // --- Navigation and link handling ---
        case "openExternalLink":
            if let link = args.first as? String {
                logger.info("openExternalLink received from JS: '\(link)', delegate=\(self.delegate != nil)")
                delegate?.bridge(self, openExternalLink: link)
            } else {
                logger.error("openExternalLink: args missing or not a string, args=\(String(describing: args))")
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

        // --- Dialog and async request entry points ---
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

    /**
     Sends a raw JSON response payload back to a pending JavaScript bridge call.

     JavaScript Promise-based bridge methods include a numeric `callId`; native code must answer
     with `bibleView.response(callId, value)` once the async work completes.
     */
    public func sendResponse(callId: Int, value: String) {
        let js = "bibleView.response(\(callId), \(value));"
        evaluateJavaScript(js)
    }

    /// Encodes an async response payload as JSON and sends it back to JavaScript.
    public func sendResponse<T: Encodable>(callId: Int, value: T) {
        guard let data = try? bridgeEncoder.encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        sendResponse(callId: callId, value: json)
    }

    /**
     Emits an event into the Vue.js client without waiting for a response.

     Native code uses events such as `set_config`, `set_document`, and `update_bookmarks` to push
     refreshed state into the already-loaded client.
     */
    public func emit(event: String, data: String = "null") {
        let js = "try { bibleView.emit('\(event)', \(data)); } catch(e) { window.webkit.messageHandlers.bibleView.postMessage({method:'console',args:['BRIDGE','JS EMIT ERROR in \(event): ' + e.message + ' ' + e.stack]}); }"
        evaluateJavaScript(js)
    }

    /// Encodes an event payload as JSON and emits it to Vue.js.
    public func emit<T: Encodable>(event: String, data: T) {
        guard let jsonData = try? bridgeEncoder.encode(data),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        emit(event: event, data: json)
    }

    /**
     Queries the current DOM selection directly from the web view.

     This is the lightweight fallback path used when native code only needs plain text and verse
     ordinals. For richer selection details including offsets, callers should use a higher-level
     bridge API exposed by the web client.

     - Returns: The selected text and optional start/end ordinals, or `nil` if no usable
       selection is active.
     */
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

    /// Clears the current browser selection in the web client.
    public func clearSelection() {
        evaluateJavaScript("window.getSelection().removeAllRanges();")
    }

    /**
     Updates the cached active-language list stored in the JavaScript bootstrap shim.

     The web client reads this synchronously through `window.android.getActiveLanguages()` during
     rendering, so native code refreshes it whenever installed modules change.
     */
    public func updateActiveLanguages(_ languages: [String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: languages),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluateJavaScript("window.__activeLanguages__ = '\(json)';")
    }

    private func evaluateJavaScript(_ js: String) {
        let execute = { [weak self] in
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

        if Thread.isMainThread {
            execute()
        } else {
            DispatchQueue.main.async(execute: execute)
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
