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

/// Present a Strong's definition sheet using UIKit (reliable from WKScriptMessageHandler callbacks).
/// The sheet contains a Vue.js WebView that renders a MultiFragmentDocument.
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

    var topVC = rootVC
    while let presented = topVC.presentedViewController {
        topVC = presented
    }

    let content = StrongsSheetContent(
        multiDocJSON: multiDocJSON,
        configJSON: configJSON,
        backgroundColorInt: backgroundColorInt,
        controller: controller,
        onFindAll: onFindAll
    )
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
    topVC.present(nav, animated: true)
}

/// SwiftUI content for the Strong's definition sheet.
/// Contains a BibleWebView with a lightweight bridge delegate that renders the MultiDocument.
struct StrongsSheetContent: View {
    let multiDocJSON: String
    let configJSON: String
    let backgroundColorInt: Int
    let controller: BibleReaderController
    let onFindAll: ((String) -> Void)?

    @State private var bridge = BibleBridge()
    @State private var sheetDelegate: StrongsSheetDelegate?

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
            }
    }
}

/// Lightweight BibleBridgeDelegate for the Strong's definition sheet.
/// Only handles client_ready (to load the document) and openExternalLink (for navigation).
/// All other bridge methods are no-ops.
final class StrongsSheetDelegate: NSObject, BibleBridgeDelegate {
    private let bridge: BibleBridge
    private var currentDocJSON: String
    private let configJSON: String
    private let backgroundColorInt: Int
    private weak var controller: BibleReaderController?
    private let onFindAll: ((String) -> Void)?

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

    // MARK: - Core: Client Ready → Load Document

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
            s.textContent = '#content { padding-left: 16px !important; padding-right: 16px !important; max-width: none !important; } .sense { display: block; margin-left: 1.5em; margin-top: 0.15em; } .entryFree { display: none; } ol, ul { padding-left: 1.5em; margin: 0.3em 0; } li { margin: 0.15em 0; } dl { margin: 0.3em 0; } dd { margin-left: 1.5em; } blockquote { margin-left: 1.5em; padding-left: 0.5em; border-left: 2px solid rgba(128,128,128,0.3); }';
            document.head.appendChild(s);
        }
        """)
    }

    private static func cssColor(fromArgbInt value: Int) -> String {
        let uint = UInt32(bitPattern: Int32(value))
        let r = (uint >> 16) & 0xFF
        let g = (uint >> 8) & 0xFF
        let b = uint & 0xFF
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    // MARK: - Link Handling

    func bridge(_ bridge: BibleBridge, openExternalLink link: String) {
        // Recursive Strong's navigation within the sheet
        if link.hasPrefix("ab-w://") {
            handleStrongsLink(link)
            return
        }
        // "Find all occurrences" → dismiss sheet and open search
        if link.hasPrefix("ab-find-all://") {
            handleFindAllLink(link)
            return
        }
        // External links
        if let url = URL(string: link) {
            UIApplication.shared.open(url)
        }
    }

    private func handleStrongsLink(_ link: String) {
        guard let components = URLComponents(string: link) else { return }
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

        guard !strongs.isEmpty || !robinson.isEmpty else { return }

        // Use the controller to look up definitions (it has SwordManager access)
        guard let newJSON = controller?.buildStrongsMultiDocJSON(strongs: strongs, robinson: robinson) else { return }

        // Navigate in-place within the sheet
        currentDocJSON = newJSON
        bridge.emit(event: "clear_document")
        bridge.emit(event: "add_documents", data: newJSON)
        bridge.emit(event: "setup_content", data: """
        {"jumpToOrdinal":null,"jumpToAnchor":null,"jumpToId":null,"topOffset":0,"bottomOffset":0}
        """)
    }

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

    // MARK: - No-op implementations for remaining protocol methods

    func bridge(_ bridge: BibleBridge, didScrollToOrdinal ordinal: Int, key: String) {}
    func bridge(_ bridge: BibleBridge, requestMoreToBeginning callId: Int) {}
    func bridge(_ bridge: BibleBridge, requestMoreToEnd callId: Int) {}
    func bridge(_ bridge: BibleBridge, addBookmark bookInitials: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool) {}
    func bridge(_ bridge: BibleBridge, addGenericBookmark bookInitials: String, osisRef: String, startOrdinal: Int, endOrdinal: Int, addNote: Bool) {}
    func bridge(_ bridge: BibleBridge, removeBookmark bookmarkId: String) {}
    func bridge(_ bridge: BibleBridge, removeGenericBookmark bookmarkId: String) {}
    func bridge(_ bridge: BibleBridge, saveBookmarkNote bookmarkId: String, note: String?) {}
    func bridge(_ bridge: BibleBridge, assignLabels bookmarkId: String) {}
    func bridge(_ bridge: BibleBridge, toggleBookmarkLabel bookmarkId: String, labelId: String) {}
    func bridge(_ bridge: BibleBridge, removeBookmarkLabel bookmarkId: String, labelId: String) {}
    func bridge(_ bridge: BibleBridge, setPrimaryLabel bookmarkId: String, labelId: String) {}
    func bridge(_ bridge: BibleBridge, setBookmarkWholeVerse bookmarkId: String, value: Bool) {}
    func bridge(_ bridge: BibleBridge, setBookmarkCustomIcon bookmarkId: String, value: String?) {}
    func bridge(_ bridge: BibleBridge, shareVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}
    func bridge(_ bridge: BibleBridge, copyVerse bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}
    func bridge(_ bridge: BibleBridge, compareVerses bookInitials: String, startOrdinal: Int, endOrdinal: Int) {}
    func bridge(_ bridge: BibleBridge, speak bookInitials: String, v11n: String, startOrdinal: Int, endOrdinal: Int) {}
    func bridge(_ bridge: BibleBridge, openStudyPad labelId: String, bookmarkId: String) {}
    func bridge(_ bridge: BibleBridge, openMyNotes v11n: String, ordinal: Int) {}
    func bridgeDidRequestOpenDownloads(_ bridge: BibleBridge) {}
    func bridge(_ bridge: BibleBridge, refChooserDialog callId: Int) {}
    func bridge(_ bridge: BibleBridge, parseRef callId: Int, text: String) {}
    func bridge(_ bridge: BibleBridge, helpDialog content: String, title: String?) {}
    func bridge(_ bridge: BibleBridge, selectionChanged text: String) {}
    func bridgeSelectionCleared(_ bridge: BibleBridge) {}
    func bridge(_ bridge: BibleBridge, createNewStudyPadEntry labelId: String, entryType: String, afterEntryId: String) {}
    func bridge(_ bridge: BibleBridge, deleteStudyPadEntry studyPadId: String) {}
    func bridge(_ bridge: BibleBridge, updateStudyPadTextEntry data: String) {}
    func bridge(_ bridge: BibleBridge, updateStudyPadTextEntryText id: String, text: String) {}
    func bridge(_ bridge: BibleBridge, updateOrderNumber labelId: String, data: String) {}
    func bridge(_ bridge: BibleBridge, updateBookmarkToLabel data: String) {}
    func bridge(_ bridge: BibleBridge, updateGenericBookmarkToLabel data: String) {}
    func bridge(_ bridge: BibleBridge, setBookmarkEditAction bookmarkId: String, value: String) {}
    func bridge(_ bridge: BibleBridge, setEditing enabled: Bool) {}
    func bridge(_ bridge: BibleBridge, setStudyPadCursor labelId: String, orderNumber: Int) {}
    func bridge(_ bridge: BibleBridge, saveState state: String) {}
    func bridge(_ bridge: BibleBridge, reportModalState isOpen: Bool) {}
    func bridge(_ bridge: BibleBridge, reportInputFocus focused: Bool) {}
    func bridge(_ bridge: BibleBridge, onKeyDown key: String) {}
    func bridge(_ bridge: BibleBridge, showToast text: String) {}
    func bridge(_ bridge: BibleBridge, shareHtml html: String) {}
    func bridge(_ bridge: BibleBridge, toggleCompareDocument documentId: String) {}
    func bridge(_ bridge: BibleBridge, openEpubLink bookInitials: String, toKey: String, toId: String) {}
    func bridgeDidRequestToggleFullScreen(_ bridge: BibleBridge) {}
}
#endif
