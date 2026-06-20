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

enum BibleBridgeCallIdRequest: Equatable {
    case requestMoreToBeginning(Int)
    case requestMoreToEnd(Int)
    case refChooserDialog(Int)
    case parseRef(callId: Int, text: String)
    case getMyDocumentPageRawContent(callId: Int, bookInitials: String, pageKey: String)
}

enum BibleBridgeCallIdRequestParseResult: Equatable {
    case request(BibleBridgeCallIdRequest)
    case malformed
}

enum BibleBridgeCallIdRequestDispatchResult: Equatable {
    case notCallIdRequest
    case handled
    case malformed
}

enum BibleBridgeMessageDispatchResult: Equatable {
    case handled
    case malformed
    case unhandled
}

private enum BibleBridgeOptionalValue<T> {
    case value(T?)
    case malformed
}

private struct BibleBridgeMessageArguments {
    let method: String
    let values: [Any]

    var isEmpty: Bool { values.isEmpty }

    func string(_ index: Int) -> String? {
        value(index, as: String.self, expected: "String")
    }

    func int(_ index: Int) -> Int? {
        value(index, as: Int.self, expected: "Int")
    }

    func bool(_ index: Int) -> Bool? {
        value(index, as: Bool.self, expected: "Bool")
    }

    func optionalString(_ index: Int) -> BibleBridgeOptionalValue<String> {
        optionalValue(index, as: String.self, expected: "String")
    }

    func optionalBool(_ index: Int) -> BibleBridgeOptionalValue<Bool> {
        optionalValue(index, as: Bool.self, expected: "Bool")
    }

    func logMalformed(_ reason: String) {
        logger.warning(
            """
            Malformed bridge message: method=\(method, privacy: .public), \
            reason=\(reason, privacy: .public), argCount=\(values.count), \
            argTypes=\(argumentTypes, privacy: .public)
            """
        )
    }

    private func value<T>(_ index: Int, as type: T.Type, expected: String) -> T? {
        guard let rawValue = values[safe: index] else {
            logMalformed("missing arg \(index), expected \(expected)")
            return nil
        }
        guard let typedValue = rawValue as? T else {
            logMalformed("arg \(index) expected \(expected), actual \(Self.typeDescription(rawValue))")
            return nil
        }
        return typedValue
    }

    private func optionalValue<T>(
        _ index: Int,
        as type: T.Type,
        expected: String
    ) -> BibleBridgeOptionalValue<T> {
        guard let rawValue = values[safe: index], !(rawValue is NSNull) else {
            return .value(nil)
        }
        guard let typedValue = rawValue as? T else {
            logMalformed("arg \(index) expected \(expected) or null, actual \(Self.typeDescription(rawValue))")
            return .malformed
        }
        return .value(typedValue)
    }

    private var argumentTypes: String {
        values.map(Self.typeDescription).joined(separator: ", ")
    }

    private static func typeDescription(_ value: Any) -> String {
        if value is NSNull { return "null" }
        return String(describing: type(of: value))
    }
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
    /// Navigates to the next chapter without appending content to the current rendered document.
    func bridgeDidRequestGoToNextChapter(_ bridge: BibleBridge)
    /// Navigates to the previous chapter without prepending content to the current rendered document.
    func bridgeDidRequestGoToPreviousChapter(_ bridge: BibleBridge)

    // MARK: - Bookmarks
    /**
     Creates or edits a verse bookmark for the current Bible document selection.

     Android equivalent: `BibleJavascriptInterface.addBookmark(...)`.
     */
    func bridge(_ bridge: BibleBridge, addBookmark bookInitials: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool)
    /// Creates or edits a bookmark for non-Bible content such as dictionaries or general books.
    func bridge(_ bridge: BibleBridge, addGenericBookmark bookInitials: String, osisRef: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool)
    /// Creates a Bible paragraph-break bookmark using the shared Android-style bridge surface.
    func bridge(_ bridge: BibleBridge, addParagraphBreakBookmark bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    /// Creates a non-Bible paragraph-break bookmark using the shared Android-style bridge surface.
    func bridge(_ bridge: BibleBridge, addGenericParagraphBreakBookmark bookInitials: String, osisRef: String, startOrdinal: Int, endOrdinal: Int)
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
    /// Shares a persisted Bible bookmark identified by the web-client bookmark UUID.
    func bridge(_ bridge: BibleBridge, shareBookmarkVerse bookmarkId: String)
    /// Copies the selected verse range to the system pasteboard.
    func bridge(_ bridge: BibleBridge, copyVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    /// Requests an Android-style compare document for the selected verse range.
    func bridge(_ bridge: BibleBridge, compareVerses bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    /// Starts text-to-speech playback for the selected verse range and versification.
    func bridge(_ bridge: BibleBridge, speak bookInitials: String, v11n: String, startOrdinal: Int, endOrdinal: Int)
    /// Starts repeated text-to-speech playback for the selected memorization range and versification.
    func bridge(_ bridge: BibleBridge, speakMemorizationLoop bookInitials: String, v11n: String, startOrdinal: Int, endOrdinal: Int)
    /// Opens the memorization workflow for the selected verse range.
    func bridge(_ bridge: BibleBridge, memorize bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    /// Marks the selected verse range as a memorized range.
    func bridge(_ bridge: BibleBridge, markAsMemorized bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    /// Adds the selected verse range to memorization targets.
    func bridge(_ bridge: BibleBridge, addMemorizationTarget bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    /// Removes the selected verse range from memorization targets.
    func bridge(_ bridge: BibleBridge, removeMemorizationTarget bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    /// Removes the selected verse range from memorized ranges.
    func bridge(_ bridge: BibleBridge, unmarkMemorized bookInitials: String, startOrdinal: Int, endOrdinal: Int)
    /// Records one chapter-read history row for Android-compatible reading progress.
    func bridge(_ bridge: BibleBridge, recordChapterRead bookInitials: String, startOrdinal: Int, chapter: Int, source: String)
    /// Opens native chapter-read history for the supplied Bible chapter identity.
    func bridge(_ bridge: BibleBridge, openChapterReadHistory bookInitials: String, startOrdinal: Int, chapter: Int)
    /// Opens native reading-progress UI with Android-compatible tab position semantics.
    func bridge(_ bridge: BibleBridge, openReadingProgress tab: Int)
    /// Opens native reading-progress settings UI.
    func bridgeDidRequestOpenReadingProgressSettings(_ bridge: BibleBridge)
    /// Persists Android-compatible reading-progress settings JSON.
    func bridge(_ bridge: BibleBridge, setReadingProgressSettings json: String)
    /// Clears read status for one chapter in the active reading-progress cycle.
    func bridge(_ bridge: BibleBridge, unmarkChapterRead bookInitials: String, startOrdinal: Int, chapter: Int)
    /// Resolves one My Documents page and returns its raw editable content payload.
    func bridge(_ bridge: BibleBridge, getMyDocumentPageRawContent callId: Int, bookInitials: String, pageKey: String)
    /// Copies one My Documents page's raw editable content to the system pasteboard.
    func bridge(_ bridge: BibleBridge, copyMyDocumentContent bookInitials: String, pageKey: String)
    /// Shares one My Documents page's raw editable content through native sharing UI.
    func bridge(_ bridge: BibleBridge, shareMyDocumentContent bookInitials: String, pageKey: String)
    /// Persists raw editable content for one My Documents page.
    func bridge(_ bridge: BibleBridge, saveMyDocumentPageContent bookInitials: String, pageId: String, content: String, title: String?)
    /// Reloads the visible rendered My Documents page for the supplied document initials.
    func bridge(_ bridge: BibleBridge, reloadMyDocumentPage bookInitials: String)
    /// Requests regeneration for an AI-generated My Documents page.
    func bridge(_ bridge: BibleBridge, regenerateMyDocumentPage pageId: String)
    /// Deletes an AI-generated My Documents page.
    func bridge(_ bridge: BibleBridge, deleteMyDocumentPage pageId: String)

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
    /// Toggles a compare document on or off in the shared Vue reader state.
    func bridge(_ bridge: BibleBridge, toggleCompareDocument documentId: String)

    // MARK: - EPUB Navigation
    /// Navigates from one EPUB anchor to another anchor or key within the same module.
    func bridge(_ bridge: BibleBridge, openEpubLink bookInitials: String, toKey: String, toId: String)

    // MARK: - Fullscreen
    /// Toggles native fullscreen mode in response to a client-side double tap gesture.
    func bridgeDidRequestToggleFullScreen(_ bridge: BibleBridge)
}

public extension BibleBridgeDelegate {
    /// Default no-op to preserve source compatibility for clients that do not handle TTS loops.
    func bridge(_ bridge: BibleBridge, speakMemorizationLoop bookInitials: String, v11n: String, startOrdinal: Int, endOrdinal: Int) {}

    /// Default no-op to preserve source compatibility for clients that do not handle memorization.
    func bridge(_ bridge: BibleBridge, memorize bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}

    /// Default no-op to preserve source compatibility for clients that do not handle memorization.
    func bridge(_ bridge: BibleBridge, markAsMemorized bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}

    /// Default no-op to preserve source compatibility for clients that do not handle memorization.
    func bridge(_ bridge: BibleBridge, addMemorizationTarget bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}

    /// Default no-op to preserve source compatibility for clients that do not handle memorization.
    func bridge(_ bridge: BibleBridge, removeMemorizationTarget bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}

    /// Default no-op to preserve source compatibility for clients that do not handle memorization.
    func bridge(_ bridge: BibleBridge, unmarkMemorized bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}

    /// Default no-op to preserve source compatibility for clients that do not handle reading progress.
    func bridge(_ bridge: BibleBridge, recordChapterRead bookInitials: String, startOrdinal: Int, chapter: Int, source: String) {}

    /// Default no-op to preserve source compatibility for clients that do not handle reading progress.
    func bridge(_ bridge: BibleBridge, openChapterReadHistory bookInitials: String, startOrdinal: Int, chapter: Int) {}

    /// Default no-op to preserve source compatibility for clients that do not handle reading progress.
    func bridge(_ bridge: BibleBridge, openReadingProgress tab: Int) {}

    /// Default no-op to preserve source compatibility for clients that do not handle reading progress.
    func bridgeDidRequestOpenReadingProgressSettings(_ bridge: BibleBridge) {}

    /// Default no-op to preserve source compatibility for clients that do not handle reading progress.
    func bridge(_ bridge: BibleBridge, setReadingProgressSettings json: String) {}

    /// Default no-op to preserve source compatibility for clients that do not handle reading progress.
    func bridge(_ bridge: BibleBridge, unmarkChapterRead bookInitials: String, startOrdinal: Int, chapter: Int) {}

    /// Default no-op to preserve source compatibility for clients that do not handle manual chapter navigation.
    func bridgeDidRequestGoToNextChapter(_ bridge: BibleBridge) {}

    /// Default no-op to preserve source compatibility for clients that do not handle manual chapter navigation.
    func bridgeDidRequestGoToPreviousChapter(_ bridge: BibleBridge) {}

    /// Default null response to preserve source compatibility for clients without My Documents storage.
    func bridge(_ bridge: BibleBridge, getMyDocumentPageRawContent callId: Int, bookInitials: String, pageKey: String) {
        bridge.sendResponse(callId: callId, value: "null")
    }

    /// Default no-op to preserve source compatibility for clients without My Documents storage.
    func bridge(_ bridge: BibleBridge, copyMyDocumentContent bookInitials: String, pageKey: String) {}

    /// Default no-op to preserve source compatibility for clients without My Documents storage.
    func bridge(_ bridge: BibleBridge, shareMyDocumentContent bookInitials: String, pageKey: String) {}

    /// Default no-op to preserve source compatibility for clients without My Documents storage.
    func bridge(_ bridge: BibleBridge, saveMyDocumentPageContent bookInitials: String, pageId: String, content: String, title: String?) {}

    /// Default no-op to preserve source compatibility for clients without My Documents storage.
    func bridge(_ bridge: BibleBridge, reloadMyDocumentPage bookInitials: String) {}

    /// Default no-op to preserve source compatibility for clients without My Documents AI actions.
    func bridge(_ bridge: BibleBridge, regenerateMyDocumentPage pageId: String) {}

    /// Default no-op to preserve source compatibility for clients without My Documents AI actions.
    func bridge(_ bridge: BibleBridge, deleteMyDocumentPage pageId: String) {}
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

    /// Test-only observer used to record emitted JavaScript without constructing a live WKWebView.
    var javaScriptEvaluationObserver: ((String) -> Void)?

    /// Whether the ambiguous selection modal should be size-limited.
    public var limitAmbiguousModalSize: Bool = false

    /// Fires on every bridge message — used to detect user interaction for active window tracking.
    public var onAnyMessage: (() -> Void)?

    /**
     Fires when UIKit observes native interaction with the embedded web view.

     This covers taps, drags, and swipes that may not produce a JavaScript bridge message, matching
     Android's `BibleView.onTouchEvent` focus behavior. The callback has no payload; callers use it
     only as an interaction signal. It is synchronous on the main thread because UIKit gesture
     delivery and `WKWebView` scroll callbacks are main-thread only.
     */
    public var onNativeUserInteraction: (() -> Void)?

    /// Fires for native user-driven webview scroll deltas (positive = down).
    public var onNativeScrollDeltaY: ((Double) -> Void)?

    /// Fires for native user-driven horizontal swipe gestures.
    public var onNativeHorizontalSwipe: ((NativeHorizontalSwipeDirection) -> Void)?

    /// Creates a new bridge instance before it is attached to a web view.
    public override init() {
        super.init()
    }

    /// Refreshes the weak web view reference from WebKit lifecycle callbacks.
    func bindWebView(_ webView: WKWebView) {
        self.webView = webView
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
        if let webView = message.webView {
            bindWebView(webView)
        }

        guard let body = message.body as? [String: Any],
              let method = body["method"] as? String else {
            logger.warning("Invalid bridge message: \(String(describing: message.body))")
            return
        }

        let args = body["args"] as? [Any] ?? []

        dispatchMessage(method: method, args: args)
    }

    @discardableResult
    func dispatchMessage(method: String, args: [Any]) -> BibleBridgeMessageDispatchResult {
        let arguments = BibleBridgeMessageArguments(method: method, values: args)

        // Notify listener for active window tracking, but skip passive/background
        // messages that don't represent user interaction to avoid focus ping-pong.
        switch method {
        case "console", "jsLog", "reportModalState", "reportInputFocus",
             "setClientReady", "saveState", "setLimitAmbiguousModalSize",
             "selectionCleared", "setEditing", "scrolledToOrdinal":
            break
        default:
            onAnyMessage?()
        }

        switch dispatchCallIdRequest(method: method, args: args) {
        case .handled:
            return .handled
        case .malformed:
            return .malformed
        case .notCallIdRequest:
            break
        }

        switch method {
        // --- Logging & state sync from JavaScript to native ---
        case "console":
            handleConsole(args)
            return .handled
        case "jsLog":
            // Routed from console.log/error/warn interceptor in BibleWebView.swift
            guard let level = arguments.string(0),
                  let msg = arguments.string(1) else { return .malformed }
            switch level {
            case "ERROR":
                logger.error("[JS] \(msg)")
            case "WARN":
                logger.warning("[JS] \(msg)")
            default:
                logger.info("[JS] \(msg)")
            }
            return .handled
        case "toast":
            guard let text = arguments.string(0) else { return .malformed }
            logger.info("Toast: \(text)")
            delegate?.bridge(self, showToast: text)
            return .handled
        case "setClientReady":
            delegate?.bridgeDidSetClientReady(self)
            return .handled
        case "reportModalState":
            guard let isOpen = arguments.bool(0) else { return .malformed }
            delegate?.bridge(self, reportModalState: isOpen)
            return .handled
        case "reportInputFocus":
            guard let focused = arguments.bool(0) else { return .malformed }
            delegate?.bridge(self, reportInputFocus: focused)
            return .handled
        case "setLimitAmbiguousModalSize":
            guard let shouldLimit = arguments.bool(0) else { return .malformed }
            limitAmbiguousModalSize = shouldLimit
            return .handled
        case "selectionCleared":
            delegate?.bridgeSelectionCleared(self)
            return .handled
        case "selectionChanged":
            guard let text = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, selectionChanged: text)
            return .handled
        case "setEditing":
            guard let isEditing = arguments.bool(0) else { return .malformed }
            delegate?.bridge(self, setEditing: isEditing)
            return .handled
        case "saveState":
            guard let state = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, saveState: state)
            return .handled
        case "onKeyDown":
            guard let key = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, onKeyDown: key)
            return .handled

        // --- Navigation & scroll position ---
        case "scrolledToOrdinal":
            guard let key = arguments.string(0),
                  let ordinal = arguments.int(1) else { return .malformed }
            guard case .value(let atChapterTopValue) = arguments.optionalBool(2) else { return .malformed }
            let atChapterTop = atChapterTopValue ?? false
            delegate?.bridge(self, didScrollToOrdinal: ordinal, key: key, atChapterTop: atChapterTop)
            return .handled

        // --- Bookmark CRUD and label assignment ---
        case "addBookmark":
            guard let initials = arguments.string(0),
                  let start = arguments.int(1),
                  let end = arguments.int(2),
                  let addNote = arguments.bool(3) else { return .malformed }
            delegate?.bridge(self, addBookmark: initials, startOrdinal: start, endOrdinal: end <= 0 ? start : end, addNote: addNote)
            return .handled
        case "addGenericBookmark":
            guard let initials = arguments.string(0),
                  let osisRef = arguments.string(1),
                  let start = arguments.int(2),
                  let end = arguments.int(3),
                  let addNote = arguments.bool(4) else { return .malformed }
            delegate?.bridge(self, addGenericBookmark: initials, osisRef: osisRef, startOrdinal: start, endOrdinal: end < 0 ? start : end, addNote: addNote)
            return .handled
        case "removeBookmark":
            guard let id = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, removeBookmark: id)
            return .handled
        case "removeGenericBookmark":
            guard let id = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, removeGenericBookmark: id)
            return .handled
        case "saveBookmarkNote":
            guard let id = arguments.string(0) else { return .malformed }
            guard case .value(let note) = arguments.optionalString(1) else { return .malformed }
            delegate?.bridge(self, saveBookmarkNote: id, note: note)
            return .handled
        case "saveGenericBookmarkNote":
            guard let id = arguments.string(0) else { return .malformed }
            guard case .value(let note) = arguments.optionalString(1) else { return .malformed }
            delegate?.bridge(self, saveBookmarkNote: id, note: note)
            return .handled
        case "assignLabels":
            guard let id = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, assignLabels: id)
            return .handled
        case "genericAssignLabels":
            guard let id = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, assignLabels: id)
            return .handled
        case "toggleBookmarkLabel", "toggleGenericBookmarkLabel":
            guard let bmId = arguments.string(0),
                  let lblId = arguments.string(1) else { return .malformed }
            delegate?.bridge(self, toggleBookmarkLabel: bmId, labelId: lblId)
            return .handled
        case "removeBookmarkLabel", "removeGenericBookmarkLabel":
            guard let bmId = arguments.string(0),
                  let lblId = arguments.string(1) else { return .malformed }
            delegate?.bridge(self, removeBookmarkLabel: bmId, labelId: lblId)
            return .handled
        case "setAsPrimaryLabel", "setAsPrimaryLabelGeneric":
            guard let bmId = arguments.string(0),
                  let lblId = arguments.string(1) else { return .malformed }
            delegate?.bridge(self, setPrimaryLabel: bmId, labelId: lblId)
            return .handled
        case "setBookmarkWholeVerse", "setGenericBookmarkWholeVerse":
            guard let id = arguments.string(0),
                  let val = arguments.bool(1) else { return .malformed }
            delegate?.bridge(self, setBookmarkWholeVerse: id, value: val)
            return .handled
        case "setBookmarkCustomIcon", "setGenericBookmarkCustomIcon":
            guard let id = arguments.string(0) else { return .malformed }
            guard case .value(let value) = arguments.optionalString(1) else { return .malformed }
            delegate?.bridge(self, setBookmarkCustomIcon: id, value: value)
            return .handled

        // --- Content actions (share/copy/compare/speak) ---
        // Note: JavaScript sends endOrdinal=-1 to mean "single verse" (same as start).
        // Normalize here so delegate methods don't need to handle -1.
        case "shareVerse":
            guard let initials = arguments.string(0),
                  let start = arguments.int(1),
                  let end = arguments.int(2) else { return .malformed }
            delegate?.bridge(self, shareVerse: initials, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            return .handled
        case "copyVerse":
            guard let initials = arguments.string(0),
                  let start = arguments.int(1),
                  let end = arguments.int(2) else { return .malformed }
            delegate?.bridge(self, copyVerse: initials, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            return .handled
        case "copyMyDocumentContent":
            guard let initials = arguments.string(0),
                  let pageKey = arguments.string(1) else { return .malformed }
            delegate?.bridge(self, copyMyDocumentContent: initials, pageKey: pageKey)
            return .handled
        case "shareMyDocumentContent":
            guard let initials = arguments.string(0),
                  let pageKey = arguments.string(1) else { return .malformed }
            delegate?.bridge(self, shareMyDocumentContent: initials, pageKey: pageKey)
            return .handled
        case "saveMyDocumentPageContent":
            guard let initials = arguments.string(0),
                  let pageId = arguments.string(1),
                  let content = arguments.string(2) else { return .malformed }
            guard case .value(let title) = arguments.optionalString(3) else { return .malformed }
            delegate?.bridge(self, saveMyDocumentPageContent: initials, pageId: pageId, content: content, title: title)
            return .handled
        case "reloadMyDocumentPage":
            guard let initials = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, reloadMyDocumentPage: initials)
            return .handled
        case "regenerateMyDocumentPage":
            guard let pageId = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, regenerateMyDocumentPage: pageId)
            return .handled
        case "deleteMyDocumentPage":
            guard let pageId = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, deleteMyDocumentPage: pageId)
            return .handled
        case "shareBookmarkVerse":
            guard let bookmarkId = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, shareBookmarkVerse: bookmarkId)
            return .handled
        case "compare":
            guard let initials = arguments.string(0),
                  let start = arguments.int(1),
                  let end = arguments.int(2) else { return .malformed }
            delegate?.bridge(self, compareVerses: initials, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            return .handled
        case "speak", "speakGeneric":
            guard let initials = arguments.string(0),
                  let v11n = arguments.string(1),
                  let start = arguments.int(2),
                  let end = arguments.int(3) else { return .malformed }
            delegate?.bridge(self, speak: initials, v11n: v11n, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            return .handled
        case "speakMemorizationLoop":
            guard let initials = arguments.string(0),
                  let v11n = arguments.string(1),
                  let start = arguments.int(2),
                  let end = arguments.int(3) else { return .malformed }
            delegate?.bridge(
                self,
                speakMemorizationLoop: initials,
                v11n: v11n,
                startOrdinal: start,
                endOrdinal: end < 0 ? start : end
            )
            return .handled
        case "memorize":
            guard let initials = arguments.string(0),
                  let start = arguments.int(1),
                  let end = arguments.int(2) else { return .malformed }
            delegate?.bridge(self, memorize: initials, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            return .handled
        case "markAsMemorized":
            guard let initials = arguments.string(0),
                  let start = arguments.int(1),
                  let end = arguments.int(2) else { return .malformed }
            delegate?.bridge(self, markAsMemorized: initials, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            return .handled
        case "addMemorizationTarget":
            guard let initials = arguments.string(0),
                  let start = arguments.int(1),
                  let end = arguments.int(2) else { return .malformed }
            delegate?.bridge(self, addMemorizationTarget: initials, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            return .handled
        case "removeMemorizationTarget":
            guard let initials = arguments.string(0),
                  let start = arguments.int(1),
                  let end = arguments.int(2) else { return .malformed }
            delegate?.bridge(self, removeMemorizationTarget: initials, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            return .handled
        case "unmarkMemorized":
            guard let initials = arguments.string(0),
                  let start = arguments.int(1),
                  let end = arguments.int(2) else { return .malformed }
            delegate?.bridge(self, unmarkMemorized: initials, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            return .handled
        case "recordChapterRead", "markChapterRead":
            guard let initials = arguments.string(0),
                  let start = arguments.int(1),
                  let chapter = arguments.int(2),
                  let source = arguments.string(3) else { return .malformed }
            delegate?.bridge(self, recordChapterRead: initials, startOrdinal: start, chapter: chapter, source: source)
            return .handled
        case "openChapterReadHistory":
            guard let initials = arguments.string(0),
                  let start = arguments.int(1),
                  let chapter = arguments.int(2) else { return .malformed }
            delegate?.bridge(self, openChapterReadHistory: initials, startOrdinal: start, chapter: chapter)
            return .handled
        case "openReadingProgress":
            guard let tab = arguments.int(0) else { return .malformed }
            delegate?.bridge(self, openReadingProgress: tab)
            return .handled
        case "openReadingProgressSettings":
            guard arguments.isEmpty else { return .malformed }
            delegate?.bridgeDidRequestOpenReadingProgressSettings(self)
            return .handled
        case "setReadingProgressSettings":
            guard let json = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, setReadingProgressSettings: json)
            return .handled
        case "unmarkChapterRead":
            guard let initials = arguments.string(0),
                  let start = arguments.int(1),
                  let chapter = arguments.int(2) else { return .malformed }
            delegate?.bridge(self, unmarkChapterRead: initials, startOrdinal: start, chapter: chapter)
            return .handled
        case "goToNextChapter":
            guard arguments.isEmpty else { return .malformed }
            delegate?.bridgeDidRequestGoToNextChapter(self)
            return .handled
        case "goToPreviousChapter":
            guard arguments.isEmpty else { return .malformed }
            delegate?.bridgeDidRequestGoToPreviousChapter(self)
            return .handled
        case "addParagraphBreakBookmark":
            guard let initials = arguments.string(0),
                  let start = arguments.int(1),
                  let end = arguments.int(2) else { return .malformed }
            delegate?.bridge(self, addParagraphBreakBookmark: initials, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            return .handled
        case "addGenericParagraphBreakBookmark":
            guard let initials = arguments.string(0),
                  let osisRef = arguments.string(1),
                  let start = arguments.int(2),
                  let end = arguments.int(3) else { return .malformed }
            delegate?.bridge(self, addGenericParagraphBreakBookmark: initials, osisRef: osisRef, startOrdinal: start, endOrdinal: end < 0 ? start : end)
            return .handled

        // --- StudyPad editing and ordering ---
        case "openStudyPad":
            guard let labelId = arguments.string(0),
                  let bmId = arguments.string(1) else { return .malformed }
            delegate?.bridge(self, openStudyPad: labelId, bookmarkId: bmId)
            return .handled
        case "openMyNotes":
            guard let v11n = arguments.string(0),
                  let ordinal = arguments.int(1) else { return .malformed }
            delegate?.bridge(self, openMyNotes: v11n, ordinal: ordinal)
            return .handled
        case "deleteStudyPadEntry":
            guard let id = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, deleteStudyPadEntry: id)
            return .handled
        case "createNewStudyPadEntry":
            guard let labelId = arguments.string(0),
                  let entryType = arguments.string(1),
                  let afterId = arguments.string(2) else { return .malformed }
            delegate?.bridge(self, createNewStudyPadEntry: labelId, entryType: entryType, afterEntryId: afterId)
            return .handled
        case "setStudyPadCursor":
            guard let labelId = arguments.string(0),
                  let orderNumber = arguments.int(1) else { return .malformed }
            delegate?.bridge(self, setStudyPadCursor: labelId, orderNumber: orderNumber)
            return .handled
        case "updateOrderNumber":
            guard let labelId = arguments.string(0),
                  let data = arguments.string(1) else { return .malformed }
            delegate?.bridge(self, updateOrderNumber: labelId, data: data)
            return .handled
        case "updateStudyPadTextEntry":
            guard let data = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, updateStudyPadTextEntry: data)
            return .handled
        case "updateStudyPadTextEntryText":
            guard let id = arguments.string(0),
                  let text = arguments.string(1) else { return .malformed }
            delegate?.bridge(self, updateStudyPadTextEntryText: id, text: text)
            return .handled
        case "updateBookmarkToLabel":
            guard let data = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, updateBookmarkToLabel: data)
            return .handled
        case "updateGenericBookmarkToLabel":
            guard let data = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, updateGenericBookmarkToLabel: data)
            return .handled
        case "setBookmarkEditAction":
            guard let bmId = arguments.string(0),
                  let value = arguments.string(1) else { return .malformed }
            delegate?.bridge(self, setBookmarkEditAction: bmId, value: value)
            return .handled

        // --- Navigation and link handling ---
        case "openExternalLink":
            guard let link = arguments.string(0) else { return .malformed }
            logger.info("openExternalLink received from JS: '\(link)', delegate=\(self.delegate != nil)")
            delegate?.bridge(self, openExternalLink: link)
            return .handled
        case "openEpubLink":
            guard let bookInitials = arguments.string(0),
                  let toKey = arguments.string(1),
                  let toId = arguments.string(2) else { return .malformed }
            delegate?.bridge(self, openEpubLink: bookInitials, toKey: toKey, toId: toId)
            return .handled
        case "openDownloads":
            delegate?.bridgeDidRequestOpenDownloads(self)
            return .handled
        case "toggleCompareDocument":
            guard let docId = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, toggleCompareDocument: docId)
            return .handled

        // --- Dialog and async request entry points ---
        case "helpDialog":
            guard let content = arguments.string(0) else { return .malformed }
            guard case .value(let title) = arguments.optionalString(1) else { return .malformed }
            delegate?.bridge(self, helpDialog: content, title: title)
            return .handled
        case "helpBookmarks":
            delegate?.bridge(self, helpDialog: "Bookmarks Help", title: "Bookmarks")
            return .handled
        case "shareHtml":
            guard let html = arguments.string(0) else { return .malformed }
            delegate?.bridge(self, shareHtml: html)
            return .handled
        case "getActiveLanguages":
            return .handled // Handled synchronously via proxy shim (see BibleWebView.swift)

        case "toggleFullScreen":
            delegate?.bridgeDidRequestToggleFullScreen(self)
            return .handled

        default:
            logger.debug("Unhandled bridge method: \(method)")
            return .unhandled
        }
    }

    // MARK: - CallId Requests

    func callIdRequest(method: String, args: [Any]) -> BibleBridgeCallIdRequestParseResult? {
        switch method {
        case "requestMoreToBeginning":
            guard let callId = args.first as? Int else { return .malformed }
            return .request(.requestMoreToBeginning(callId))
        case "requestMoreToEnd":
            guard let callId = args.first as? Int else { return .malformed }
            return .request(.requestMoreToEnd(callId))
        case "refChooserDialog":
            guard let callId = args.first as? Int else { return .malformed }
            return .request(.refChooserDialog(callId))
        case "parseRef":
            guard let callId = args[safe: 0] as? Int,
                  let text = args[safe: 1] as? String else { return .malformed }
            return .request(.parseRef(callId: callId, text: text))
        case "getMyDocumentPageRawContent":
            guard let callId = args[safe: 0] as? Int,
                  let bookInitials = args[safe: 1] as? String,
                  let pageKey = args[safe: 2] as? String else { return .malformed }
            return .request(.getMyDocumentPageRawContent(
                callId: callId,
                bookInitials: bookInitials,
                pageKey: pageKey
            ))
        default:
            return nil
        }
    }

    @discardableResult
    func dispatchCallIdRequest(method: String, args: [Any]) -> BibleBridgeCallIdRequestDispatchResult {
        guard let parseResult = callIdRequest(method: method, args: args) else { return .notCallIdRequest }
        guard case .request(let request) = parseResult else {
            let argTypes = args.map { String(describing: type(of: $0)) }.joined(separator: ", ")
            logger.warning(
                "Malformed callId bridge message: method=\(method, privacy: .public), argCount=\(args.count), argTypes=\(argTypes, privacy: .public)"
            )
            return .malformed
        }

        switch request {
        case .requestMoreToBeginning(let callId):
            delegate?.bridge(self, requestMoreToBeginning: callId)
        case .requestMoreToEnd(let callId):
            delegate?.bridge(self, requestMoreToEnd: callId)
        case .refChooserDialog(let callId):
            delegate?.bridge(self, refChooserDialog: callId)
        case .parseRef(let callId, let text):
            delegate?.bridge(self, parseRef: callId, text: text)
        case .getMyDocumentPageRawContent(let callId, let bookInitials, let pageKey):
            delegate?.bridge(
                self,
                getMyDocumentPageRawContent: callId,
                bookInitials: bookInitials,
                pageKey: pageKey
            )
        }

        return .handled
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
     Emits a raw JSON event into the Vue.js client without waiting for a response.

     Native code uses this overload when it already has a complete JSON expression, such as a
     rendered document payload or `null`. Call `emitEncoded(event:data:)` when the payload is a
     Swift value that still needs JSON encoding, including scalar `String` values.

     - Parameters:
       - event: Vue event name passed to `bibleView.emit`.
       - data: Raw JavaScript/JSON expression to pass as the second `bibleView.emit` argument.
     - Returns: `true` when JavaScript was queued for an attached web view or recording observer.
     - Side effects: Evaluates JavaScript in the attached web view or recording observer.
     - Failure modes: JavaScript runtime failures are caught in the generated wrapper and reported
       through the bridge console message path; returns `false` when no web view or observer is
       attached.
     */
    @discardableResult
    public func emit(event: String, data: String = "null") -> Bool {
        let js = "try { void bibleView.emit('\(event)', \(data)); } catch(e) { window.webkit.messageHandlers.bibleView.postMessage({method:'console',args:['BRIDGE','JS EMIT ERROR in \(event): ' + e.message + ' ' + e.stack]}); }"
        return evaluateJavaScript(js)
    }

    /**
     Encodes a Swift event payload as JSON and emits it to Vue.js.

     This method is intentionally distinct from the raw `String` overload so callers can encode
     scalar string payloads as JSON string literals instead of accidentally interpolating them as
     JavaScript source.

     - Parameters:
       - event: Vue event name passed to `bibleView.emit`.
       - data: Encodable Swift payload to serialize as the second `bibleView.emit` argument.
     - Side effects: Evaluates JavaScript in the attached web view or recording observer.
     - Failure modes: Silently returns when JSON encoding fails; JavaScript runtime failures are
       caught in the generated wrapper and reported through the bridge console message path.
     */
    public func emitEncoded<T: Encodable>(event: String, data: T) {
        guard let jsonData = try? bridgeEncoder.encode(data),
              let json = String(data: jsonData, encoding: .utf8) else { return }
        emit(event: event, data: json)
    }

    /// Encodes an event payload as JSON and emits it to Vue.js.
    public func emit<T: Encodable>(event: String, data: T) {
        emitEncoded(event: event, data: data)
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

    @discardableResult
    private func evaluateJavaScript(_ js: String) -> Bool {
        let execute = { [weak self] () -> Bool in
            if let observer = self?.javaScriptEvaluationObserver {
                observer(js)
                return true
            }
            guard let webView = self?.webView else {
                NSLog("BRIDGE-JS: webView is nil! Cannot evaluate: %@", String(js.prefix(200)))
                return false
            }
            webView.evaluateJavaScript(js) { _, error in
                if let error {
                    NSLog("BRIDGE-JS ERROR: %@ for JS: %@", error.localizedDescription, String(js.prefix(200)))
                }
            }
            return true
        }

        if Thread.isMainThread {
            return execute()
        } else {
            return DispatchQueue.main.sync {
                execute()
            }
        }
    }

    // MARK: - Handlers

    private func handleConsole(_ args: [Any]) {
        let loggerName = args[safe: 0] as? String ?? "unknown"
        let message = args[safe: 1] as? String ?? ""
        logger.debug("[\(loggerName)] \(message)")
    }

}

// MARK: - Array Safe Subscript

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
