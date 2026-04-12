// StrongsSheetView.swift — Bottom sheet for Strong's/dictionary definitions
//
// Presents a Vue.js MultiDocument in a dedicated BibleWebView inside a UIKit sheet.
// Handles recursive Strong's navigation (ab-w://), "Find all occurrences" (ab-find-all://),
// and ThML cross-reference links within definitions.

import SwiftUI
import BibleView
import BibleCore
import os.log

#if os(iOS)
import UIKit

private let logger = Logger(subsystem: "org.andbible", category: "StrongsSheet")

/**
 Presents a Strong's definition sheet using UIKit rather than SwiftUI sheet state.

 This entry point is used by web-view bridge callbacks, where the call site is outside the normal
 SwiftUI view-state mutation flow. The presented sheet hosts a dedicated `BibleWebView` that renders
 a Vue `MultiFragmentDocument`.

 - Parameters:
   - multiDocJSON: Serialized MultiDocument payload to render initially.
   - configJSON: Serialized reader configuration passed to the embedded web view.
   - backgroundColorInt: Signed ARGB background color matching the parent reader theme.
   - controller: Reader controller used for recursive Strong's lookups.
   - onFindAll: Callback invoked when the sheet requests a "find all occurrences" search.
 - Side effects: Walks UIKit presentation state, may dismiss an already-presented sheet, and presents
   a new page-sheet navigation controller.
 - Failure modes: Returns without presenting anything if no active `UIWindowScene` or root view
   controller is available.
 */
func presentStrongsSheet(
    multiDocJSON: String,
    configJSON: String,
    backgroundColorInt: Int,
    controller: BibleReaderController,
    onFindAll: ((String) -> Void)?
) {
    guard let windowScene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).first,
          let rootVC = windowScene.windows.first?.rootViewController else { return }

    let doPresent = {
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        // Back button (hidden initially, shown when history exists)
        let backButton = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: nil,
            action: nil
        )
        backButton.isHidden = true

        var content = StrongsSheetContent(
            multiDocJSON: multiDocJSON,
            configJSON: configJSON,
            backgroundColorInt: backgroundColorInt,
            controller: controller,
            onFindAll: onFindAll
        )
        content.onDelegateReady = { delegate in
            // Wire back button action
            backButton.primaryAction = UIAction { _ in
                delegate.goBack()
            }
            // Update back button visibility when history changes
            delegate.onHistoryChanged = { canGoBack in
                backButton.isHidden = !canGoBack
            }
        }

        let hostingVC = UIHostingController(rootView: content)
        let nav = UINavigationController(rootViewController: hostingVC)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.prefersGrabberVisible = true
        }
        hostingVC.navigationItem.title = String(localized: "definition")
        hostingVC.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { _ in nav.dismiss(animated: true) }
        )
        hostingVC.navigationItem.rightBarButtonItem = backButton
        topVC.present(nav, animated: true)
    }

    // If a VC is being dismissed (e.g. previous Strong's sheet swiped down),
    // present() silently fails. Dismiss first, then present after transition.
    var topVC = rootVC
    while let presented = topVC.presentedViewController {
        topVC = presented
    }
    if topVC.isBeingDismissed || rootVC.presentedViewController?.isBeingDismissed == true {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { doPresent() }
    } else if rootVC.presentedViewController != nil {
        // Another sheet is up — dismiss it first, then present
        rootVC.presentedViewController?.dismiss(animated: true) { doPresent() }
    } else {
        doPresent()
    }
}

/**
 SwiftUI root content embedded inside the UIKit Strong's sheet.

 The view creates a dedicated `BibleBridge`, hosts a `BibleWebView`, and attaches a
 `StrongsSheetDelegate` that handles recursive link navigation within the sheet.
 */
struct StrongsSheetContent: View {
    /// Initial MultiDocument payload rendered in the sheet.
    let multiDocJSON: String

    /// Reader configuration emitted into the embedded web view.
    let configJSON: String

    /// Signed ARGB background color matching the parent reader theme.
    let backgroundColorInt: Int

    /// Reader controller used for follow-up Strong's lookups.
    let controller: BibleReaderController

    /// Callback invoked when the sheet requests a "find all occurrences" search.
    let onFindAll: ((String) -> Void)?

    /// Set by presentStrongsSheet to allow updating the back button.
    var onDelegateReady: ((StrongsSheetDelegate) -> Void)?

    /// Bridge instance dedicated to the sheet's embedded web view.
    @State private var bridge = BibleBridge()

    /// Retained delegate handling the embedded web-view bridge lifecycle.
    @State private var sheetDelegate: StrongsSheetDelegate?

    /**
     Builds the embedded web view and installs the sheet-specific bridge delegate on appear.
     */
    var body: some View {
        BibleWebView(bridge: bridge, backgroundColorInt: backgroundColorInt)
            .onAppear {
                let delegate = StrongsSheetDelegate(
                    bridge: bridge,
                    multiDocJSON: multiDocJSON,
                    configJSON: configJSON,
                    backgroundColorInt: backgroundColorInt,
                    controller: controller,
                    onFindAll: onFindAll
                )
                bridge.delegate = delegate
                sheetDelegate = delegate // retain
                onDelegateReady?(delegate)
            }
    }
}

/**
 Lightweight `BibleBridgeDelegate` used by the Strong's definition sheet.

 The delegate owns the current document JSON, an in-sheet back stack for recursive Strong's
 navigation, and the bridge callbacks needed to load documents and handle link taps.

 All unrelated `BibleBridgeDelegate` requirements are intentionally left as no-ops because the
 Strong's sheet only needs document loading and link handling.
 */
final class StrongsSheetDelegate: NSObject, BibleBridgeDelegate {
    /// Bridge connected to the sheet's embedded web view.
    private let bridge: BibleBridge

    /// Current document payload rendered in the sheet.
    private var currentDocJSON: String

    /// Previously rendered document payloads used for in-sheet back navigation.
    private var historyStack: [String] = []

    /// Callback notifying UIKit when back-navigation availability changes.
    var onHistoryChanged: ((Bool) -> Void)?

    /// Reader configuration emitted into the embedded web view on load.
    private let configJSON: String

    /// Signed ARGB background color matching the parent reader theme.
    private let backgroundColorInt: Int

    /// Reader controller used for recursive Strong's lookups.
    private weak var controller: BibleReaderController?

    /// Callback invoked when the sheet requests a "find all occurrences" search.
    private let onFindAll: ((String) -> Void)?

    /// Whether the in-sheet Strong's history stack currently allows navigating back.
    var canGoBack: Bool { !historyStack.isEmpty }

    /**
     Creates the Strong's sheet bridge delegate.

     - Parameters:
       - bridge: Bridge connected to the embedded web view.
       - multiDocJSON: Initial MultiDocument payload to render.
       - configJSON: Serialized reader configuration.
       - backgroundColorInt: Signed ARGB background color.
       - controller: Reader controller used for recursive Strong's lookups.
       - onFindAll: Callback invoked for "find all occurrences" requests.
     */
    init(bridge: BibleBridge, multiDocJSON: String, configJSON: String,
         backgroundColorInt: Int,
         controller: BibleReaderController, onFindAll: ((String) -> Void)?) {
        self.bridge = bridge
        self.currentDocJSON = multiDocJSON
        self.configJSON = configJSON
        self.backgroundColorInt = backgroundColorInt
        self.controller = controller
        self.onFindAll = onFindAll
        super.init()
    }

    /**
     Pops the in-sheet history stack and re-renders the previous Strong's document.

     Failure modes:
     - returns without changes when there is no prior document in the history stack
     */
    func goBack() {
        guard let previousJSON = historyStack.popLast() else { return }
        currentDocJSON = previousJSON
        bridge.emit(event: "clear_document")
        bridge.emit(event: "add_documents", data: previousJSON)
        bridge.emit(event: "setup_content", data: """
        {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
        """)
        onHistoryChanged?(canGoBack)
    }

    // MARK: - Core: Client Ready → Load Document

    /**
     Emits configuration and document payloads once the embedded web client reports readiness.

     Side effects:
     - emits config/document/setup events into the embedded bridge
     - injects CSS and debug click logging into the hosted web view
     */
    func bridgeDidSetClientReady(_ bridge: BibleBridge) {
        logger.info("StrongsSheet: client ready, sending config + document")
        bridge.emit(event: "set_config", data: configJSON)
        bridge.emit(event: "clear_document")
        bridge.emit(event: "add_documents", data: currentDocJSON)
        bridge.emit(event: "setup_content", data: """
        {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
        """)

        // Apply background and text colors matching the main WebView
        let bg = Self.cssColor(fromArgbInt: backgroundColorInt)
        bridge.webView?.evaluateJavaScript("""
        document.documentElement.style.backgroundColor = '\(bg)';
        document.body.style.backgroundColor = '\(bg)';
        if (!document.getElementById('ios-strongs-fix')) {
            var s = document.createElement('style');
            s.id = 'ios-strongs-fix';
            s.textContent = '#content { padding-left: 16px !important; padding-right: 16px !important; max-width: none !important; } ol, ul { padding-left: 1.5em; margin: 0.3em 0; } li { margin: 0.15em 0; } dl { margin: 0.3em 0; } dd { margin-left: 1.5em; } blockquote { margin-left: 1.5em; padding-left: 0.5em; border-left: 2px solid rgba(128,128,128,0.3); }';
            document.head.appendChild(s);
        }
        // Debug logging for click events in Strong's sheet
        if (!window.__strongsDebug__) {
            window.__strongsDebug__ = true;
            document.addEventListener('click', function(event) {
                var ef = event.eventFunctions;
                var efCount = 0;
                var efKeys = [];
                if (ef) {
                    efKeys = Object.keys(ef);
                    efKeys.forEach(function(k) { efCount += ef[k].length; });
                }
                console.log('[StrongsSheet] click event: target=' + event.target.tagName +
                    ', href=' + (event.target.getAttribute && event.target.getAttribute('href') || 'none') +
                    ', eventFunctions=' + efCount + ' (priorities: ' + efKeys.join(',') + ')' +
                    ', bubbles=' + event.bubbles +
                    ', defaultPrevented=' + event.defaultPrevented);
            }, true); // capture phase - fires before Vue handlers
            document.addEventListener('click', function(event) {
                var ef = event.eventFunctions;
                var efCount = 0;
                var efKeys = [];
                if (ef) {
                    efKeys = Object.keys(ef);
                    efKeys.forEach(function(k) { efCount += ef[k].length; });
                }
                console.log('[StrongsSheet] click BUBBLE: eventFunctions=' + efCount +
                    ' (priorities: ' + efKeys.join(',') + ')');
            }, false); // bubble phase - fires after Vue handlers
        }
        """)
    }

    /**
     Converts a signed ARGB integer into a CSS hex color string without alpha.

     - Parameter value: Signed ARGB integer emitted by the native reader theme state.
     - Returns: Lowercase CSS hex color string in `#rrggbb` form.
     */
    private static func cssColor(fromArgbInt value: Int) -> String {
        let uint = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
        let r = (uint >> 16) & 0xFF
        let g = (uint >> 8) & 0xFF
        let b = uint & 0xFF
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    // MARK: - Link Handling

    /**
     Routes Strong's-sheet links to recursive lookup, find-all search, or external URL handling.

     - Parameter link: Link emitted by the embedded Bible web view.
     */
    func bridge(_ bridge: BibleBridge, openExternalLink link: String) {
        logger.info("StrongsSheet openExternalLink: '\(link)'")
        // Recursive Strong's navigation within the sheet
        if link.hasPrefix("ab-w://") {
            logger.info("StrongsSheet: handling as Strong's link")
            handleStrongsLink(link)
            return
        }
        // "Find all occurrences" → dismiss sheet and open search
        if link.hasPrefix("ab-find-all://") {
            logger.info("StrongsSheet: handling as find-all link")
            handleFindAllLink(link)
            return
        }
        // Missing-document fallbacks use a generic `download://` route into Downloads.
        if link.hasPrefix("download://") {
            logger.info("StrongsSheet: handling as downloads link")
            if let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
               let rootVC = windowScene.windows.first?.rootViewController {
                var topVC = rootVC
                while let presented = topVC.presentedViewController {
                    topVC = presented
                }
                topVC.dismiss(animated: true) { [weak controller] in
                    controller?.bridgeDidRequestOpenDownloads(bridge)
                }
            }
            return
        }
        // External links
        logger.info("StrongsSheet: handling as external URL")
        if let url = URL(string: link) {
            UIApplication.shared.open(url)
        }
    }

    /**
     Handles recursive `ab-w://` links by building a new Strong's document in place.

     Side effects:
     - resolves new document JSON through `BibleReaderController`
     - appends the current document to the in-sheet history stack
     - emits clear/add/setup events into the embedded bridge

     Failure modes:
     - returns without changes when the URL cannot be parsed, no Strong's/Robinson values exist,
       or the backing controller can no longer build a follow-up document
     */
    private func handleStrongsLink(_ link: String) {
        guard let components = URLComponents(string: link) else {
            logger.error("handleStrongsLink: failed to parse URL: '\(link)'")
            return
        }
        let items = components.queryItems ?? []

        var strongs: [String] = []
        var robinson: [String] = []

        for item in items {
            guard let value = item.value, !value.isEmpty else { continue }
            switch item.name {
            case "strong": strongs.append(value)
            case "robinson": robinson.append(value)
            default: break
            }
        }

        logger.info("handleStrongsLink: strongs=\(strongs), robinson=\(robinson)")

        guard !strongs.isEmpty || !robinson.isEmpty else {
            logger.error("handleStrongsLink: no strongs or robinson values found")
            return
        }

        // Use the controller to look up definitions (it has SwordManager access)
        logger.info("handleStrongsLink: controller is \(self.controller == nil ? "nil" : "alive")")
        let currentStateJSON = extractStateJSON(from: currentDocJSON)
        guard let newJSON = self.controller?.buildStrongsMultiDocJSON(
            strongs: strongs,
            robinson: robinson,
            stateJSON: currentStateJSON
        ) else {
            logger.error("handleStrongsLink: buildStrongsMultiDocJSON returned nil")
            return
        }

        // Push current to history, then navigate in-place within the sheet
        logger.info("handleStrongsLink: navigating in-place, JSON length=\(newJSON.count)")
        historyStack.append(currentDocJSON)
        currentDocJSON = newJSON
        onHistoryChanged?(canGoBack)
        bridge.emit(event: "clear_document")
        bridge.emit(event: "add_documents", data: newJSON)
        bridge.emit(event: "setup_content", data: """
        {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
        """)
    }

    /**
     Handles `ab-find-all://` links by dismissing the sheet and forwarding a search request.

     Failure modes:
     - returns without action when the URL cannot be parsed or no lookup name can be derived
     - if no presented UIKit controller is available, the sheet cannot dismiss itself and the
       callback is not invoked
     */
    private func handleFindAllLink(_ link: String) {
        guard let components = URLComponents(string: link) else { return }
        let items = components.queryItems ?? []
        let type = items.first(where: { $0.name == "type" })?.value
        var name = items.first(where: { $0.name == "name" })?.value ?? ""

        if !name.isEmpty && name.first?.isLetter != true {
            if type == "hebrew" { name = "H\(name)" }
            else if type == "greek" { name = "G\(name)" }
        }

        guard !name.isEmpty else { return }

        // Dismiss the sheet, then open search
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            topVC.dismiss(animated: true) { [onFindAll] in
                onFindAll?(name)
            }
        }
    }

    /**
     Extracts the serialized client-side state object from one Strong's document payload.

     - Parameter documentJSON: JSON emitted into the embedded web client.
     - Returns: Compact serialized JSON object for the `state` field, or `nil` when absent.
     */
    private func extractStateJSON(from documentJSON: String) -> String? {
        guard let data = documentJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = object["state"],
              !(state is NSNull),
              JSONSerialization.isValidJSONObject(state),
              let stateData = try? JSONSerialization.data(withJSONObject: state),
              let stateJSON = String(data: stateData, encoding: .utf8) else {
            return nil
        }
        return stateJSON
    }

    /**
     Rewrites the current document payload with the latest tab-selection state from the web client.

     - Parameters:
       - documentJSON: Existing rendered document payload.
       - stateJSON: Serialized state emitted by `android.saveState(JSON.stringify(...))`.
     - Returns: Updated document payload when parsing succeeds, otherwise the original payload.
     */
    private func updatingDocumentJSON(_ documentJSON: String, withStateJSON stateJSON: String?) -> String {
        guard let data = documentJSON.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return documentJSON
        }

        if let stateJSON,
           let stateData = stateJSON.data(using: .utf8),
           let stateObject = try? JSONSerialization.jsonObject(with: stateData) {
            object["state"] = stateObject
        } else {
            object.removeValue(forKey: "state")
        }

        guard JSONSerialization.isValidJSONObject(object),
              let updatedData = try? JSONSerialization.data(withJSONObject: object),
              let updatedJSON = String(data: updatedData, encoding: .utf8) else {
            return documentJSON
        }
        return updatedJSON
    }

    // MARK: - No-op implementations for remaining protocol methods

    /// No-op because the Strong's sheet does not react to ordinal-scroll callbacks.
    func bridge(_ bridge: BibleBridge, didScrollToOrdinal ordinal: Int, key: String, atChapterTop: Bool) {}

    /// No-op because the Strong's sheet does not support paged loading toward the beginning.
    func bridge(_ bridge: BibleBridge, requestMoreToBeginning callId: Int) {}

    /// No-op because the Strong's sheet does not support paged loading toward the end.
    func bridge(_ bridge: BibleBridge, requestMoreToEnd callId: Int) {}

    /// No-op because bookmark creation is handled in the main reader, not the Strong's sheet.
    func bridge(_ bridge: BibleBridge, addBookmark bookInitials: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool) {}

    /// No-op because generic bookmark creation is handled in the main reader.
    func bridge(_ bridge: BibleBridge, addGenericBookmark bookInitials: String, osisRef: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool) {}

    /// No-op because bookmark removal is out of scope for the Strong's sheet.
    func bridge(_ bridge: BibleBridge, removeBookmark bookmarkId: String) {}

    /// No-op because generic bookmark removal is out of scope for the Strong's sheet.
    func bridge(_ bridge: BibleBridge, removeGenericBookmark bookmarkId: String) {}

    /// No-op because bookmark note editing is not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, saveBookmarkNote bookmarkId: String, note: String?) {}

    /// No-op because label assignment is not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, assignLabels bookmarkId: String) {}

    /// No-op because label toggling is not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, toggleBookmarkLabel bookmarkId: String, labelId: String) {}

    /// No-op because label removal is not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, removeBookmarkLabel bookmarkId: String, labelId: String) {}

    /// No-op because primary-label selection is not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, setPrimaryLabel bookmarkId: String, labelId: String) {}

    /// No-op because bookmark verse-scope editing is not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, setBookmarkWholeVerse bookmarkId: String, value: Bool) {}

    /// No-op because bookmark icon editing is not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, setBookmarkCustomIcon bookmarkId: String, value: String?) {}

    /// No-op because verse sharing is handled in the main reader.
    func bridge(_ bridge: BibleBridge, shareVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}

    /// No-op because verse copying is handled in the main reader.
    func bridge(_ bridge: BibleBridge, copyVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}

    /// No-op because verse comparison is handled in the main reader.
    func bridge(_ bridge: BibleBridge, compareVerses bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}

    /// No-op because TTS actions are handled in the main reader.
    func bridge(_ bridge: BibleBridge, speak bookInitials: String, v11n: String, startOrdinal: Int, endOrdinal: Int) {}

    /// No-op because Study Pad navigation is not initiated from the Strong's sheet.
    func bridge(_ bridge: BibleBridge, openStudyPad labelId: String, bookmarkId: String) {}

    /// No-op because My Notes navigation is not initiated from the Strong's sheet.
    func bridge(_ bridge: BibleBridge, openMyNotes v11n: String, ordinal: Int) {}

    /// No-op because the Strong's sheet does not open the downloads screen.
    func bridgeDidRequestOpenDownloads(_ bridge: BibleBridge) {}

    /// No-op because reference chooser dialogs are not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, refChooserDialog callId: Int) {}

    /// No-op because reference parsing is not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, parseRef callId: Int, text: String) {}

    /// No-op because help dialogs are not presented from the Strong's sheet.
    func bridge(_ bridge: BibleBridge, helpDialog content: String, title: String?) {}

    /// No-op because selection-change callbacks are not consumed in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, selectionChanged text: String) {}

    /// No-op because selection-cleared callbacks are not consumed in the Strong's sheet.
    func bridgeSelectionCleared(_ bridge: BibleBridge) {}

    /// No-op because Study Pad entry creation is not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, createNewStudyPadEntry labelId: String, entryType: String, afterEntryId: String) {}

    /// No-op because Study Pad entry deletion is not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, deleteStudyPadEntry studyPadId: String) {}

    /// No-op because Study Pad entry updates are not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, updateStudyPadTextEntry data: String) {}

    /// No-op because Study Pad text updates are not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, updateStudyPadTextEntryText id: String, text: String) {}

    /// No-op because Study Pad ordering is not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, updateOrderNumber labelId: String, data: String) {}

    /// No-op because bookmark-to-label updates are not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, updateBookmarkToLabel data: String) {}

    /// No-op because generic bookmark-to-label updates are not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, updateGenericBookmarkToLabel data: String) {}

    /// No-op because bookmark edit-action changes are not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, setBookmarkEditAction bookmarkId: String, value: String) {}

    /// No-op because edit-mode changes are not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, setEditing enabled: Bool) {}

    /// No-op because Study Pad cursor updates are not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, setStudyPadCursor labelId: String, orderNumber: Int) {}

    /// Persists transient Strong's-sheet tab selection state for recursive navigation and backstack.
    func bridge(_ bridge: BibleBridge, saveState state: String) {
        currentDocJSON = updatingDocumentJSON(currentDocJSON, withStateJSON: state)
    }

    /// No-op because the Strong's sheet does not track nested modal state.
    func bridge(_ bridge: BibleBridge, reportModalState isOpen: Bool) {}

    /// No-op because the Strong's sheet does not react to input-focus changes.
    func bridge(_ bridge: BibleBridge, reportInputFocus focused: Bool) {}

    /// No-op because raw key-down events are not handled in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, onKeyDown key: String) {}

    /// No-op because toast display is handled by the main reader host.
    func bridge(_ bridge: BibleBridge, showToast text: String) {}

    /// No-op because HTML sharing is not triggered from the Strong's sheet.
    func bridge(_ bridge: BibleBridge, shareHtml html: String) {}

    /// No-op because compare-document toggling is not supported in the Strong's sheet.
    func bridge(_ bridge: BibleBridge, toggleCompareDocument documentId: String) {}

    /// No-op because EPUB links are not opened from the Strong's sheet.
    func bridge(_ bridge: BibleBridge, openEpubLink bookInitials: String, toKey: String, toId: String) {}

    /// No-op because fullscreen toggling is not driven from the Strong's sheet.
    func bridgeDidRequestToggleFullScreen(_ bridge: BibleBridge) {}
}
#endif
