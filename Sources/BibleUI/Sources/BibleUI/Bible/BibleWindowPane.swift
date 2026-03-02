// BibleWindowPane.swift — Per-window Bible rendering pane
//
// Each pane has its own BibleBridge, BibleReaderController, and BibleWebView,
// enabling true multi-window split-screen viewing with independent content.

import SwiftUI
import SwiftData
import BibleView
import BibleCore
import SwordKit
import os.log

private let logger = Logger(subsystem: "org.andbible", category: "BibleWindowPane")

/// A self-contained Bible rendering pane for a single window.
/// Contains its own bridge, controller, and WebView — multiple panes show independent content.
struct BibleWindowPane: View {
    let window: Window
    let isFocused: Bool
    let displaySettings: TextDisplaySettings
    let nightMode: Bool
    let speakService: SpeakService

    @State private var bridge = BibleBridge()
    @State private var controller: BibleReaderController?
    @State private var pendingLabelBookmarkId: UUID?
    @State private var showGoToRefAlert = false
    @State private var goToRefText = ""
    @Environment(WindowManager.self) private var windowManager
    @Environment(\.modelContext) private var modelContext

    // Callbacks to parent BibleReaderView for sheet presentations
    var onShowBookChooser: (() -> Void)?
    var onShowSearch: (() -> Void)?
    var onShowBookmarks: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onShowDownloads: (() -> Void)?
    var onShowHistory: (() -> Void)?
    var onShowCompare: (() -> Void)?
    var onShowReadingPlans: (() -> Void)?
    var onShowSpeakControls: (() -> Void)?
    var onShareText: ((String) -> Void)?
    var onShowCrossReferences: (([CrossReference]) -> Void)?
    var onShowModulePicker: ((DocumentCategory) -> Void)?
    var onShowToast: ((String) -> Void)?
    var onShowWorkspaces: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    var onSearchForStrongs: ((String) -> Void)?
    var onShowStrongsSheet: ((String, String) -> Void)?
    var onRefChooserDialog: ((@escaping (String?) -> Void) -> Void)?

    /// The active background color as an ARGB integer.
    private var activeBackgroundColorInt: Int {
        let d = TextDisplaySettings.appDefaults
        if nightMode {
            return displaySettings.nightBackground ?? d.nightBackground ?? -16777216
        } else {
            return displaySettings.dayBackground ?? d.dayBackground ?? -1
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            BibleWebView(bridge: bridge, backgroundColorInt: activeBackgroundColorInt)
                .ignoresSafeArea(edges: .bottom)

            // Selection action bar — shows when text is long-press selected
            if controller?.hasActiveSelection == true {
                selectionActionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            // Window menu button — matches Android's hamburger button in top-right of each pane
            if windowManager.visibleWindows.count > 1 || windowManager.allWindows.count > 1 {
                windowMenuButton
                    .padding(6)
            }
        }
        .border(isFocused && windowManager.visibleWindows.count > 1 ? Color.accentColor : Color.clear, width: 2)
        .onAppear {
            if controller == nil {
                initializeController()
            } else {
                // Re-register existing controller — onDisappear may have cleared the
                // registry during a ForEach re-layout (e.g. when adding/removing windows).
                windowManager.registerController(controller!, for: window.id)
                // Async nudge (same reason as initializeController — see comment there).
                let wm = windowManager
                let wid = window.id
                let ctrl = controller!
                Task { @MainActor in
                    wm.registerController(ctrl, for: wid)
                }
            }
        }
        .onDisappear {
            // Unregister controller when pane is removed
            windowManager.unregisterController(for: window.id)
        }
        .onChange(of: nightMode) { _, newValue in
            controller?.updateDisplaySettings(displaySettings, nightMode: newValue)
        }
        .onChange(of: displaySettings) { _, newValue in
            controller?.updateDisplaySettings(newValue, nightMode: nightMode)
        }
        .sheet(item: $pendingLabelBookmarkId) { bookmarkId in
            let _ = logger.info("LabelAssignment sheet PRESENTING for bookmarkId=\(bookmarkId)")
            NavigationStack {
                LabelAssignmentView(
                    bookmarkId: bookmarkId,
                    onDismiss: {
                        let id = bookmarkId
                        logger.info("LabelAssignment sheet onDismiss: refreshing bookmark \(id)")
                        pendingLabelBookmarkId = nil
                        controller?.refreshBookmarkInVueJS(bookmarkId: id)
                    }
                )
            }
        }
        .alert(String(localized: "go_to_reference"), isPresented: $showGoToRefAlert) {
            TextField(String(localized: "go_to_reference_placeholder"), text: $goToRefText)
            Button(String(localized: "go")) {
                if !(controller?.navigateToRef(goToRefText) ?? false) {
                    onShowToast?(String(localized: "go_to_reference_invalid"))
                }
            }
            Button(String(localized: "browse"), role: nil) {
                onShowBookChooser?()
            }
            Button(String(localized: "cancel"), role: .cancel) { }
        } message: {
            Text(String(localized: "go_to_reference_message"))
        }
    }

    /// Hamburger menu button overlay for per-window actions (matching Android's BibleFrame).
    private var windowMenuButton: some View {
        Menu {
            // Content actions
            Button(String(localized: "copy_reference"), systemImage: "doc.on.clipboard") {
                copyReference()
            }

            Button(String(localized: "go_to_reference"), systemImage: "arrow.right.doc.on.clipboard") {
                windowManager.activeWindow = window
                goToRefText = ""
                showGoToRefAlert = true
            }

            Divider()

            // Move window actions
            if windowManager.visibleWindows.count > 1 {
                let sorted = windowManager.visibleWindows.sorted { $0.orderNumber < $1.orderNumber }
                let currentIndex = sorted.firstIndex(where: { $0.id == window.id })

                Button(String(localized: "move_up"), systemImage: "arrow.up") {
                    guard let idx = currentIndex, idx > 0 else { return }
                    windowManager.swapWindowOrder(window, sorted[idx - 1])
                }
                .disabled(currentIndex == nil || currentIndex == 0)

                Button(String(localized: "move_down"), systemImage: "arrow.down") {
                    guard let idx = currentIndex, idx < sorted.count - 1 else { return }
                    windowManager.swapWindowOrder(window, sorted[idx + 1])
                }
                .disabled(currentIndex == nil || currentIndex == sorted.count - 1)

                Divider()
            }

            // Layout actions
            if windowManager.isMaximized {
                Button(String(localized: "restore_size"), systemImage: "arrow.down.right.and.arrow.up.left") {
                    windowManager.unmaximize()
                }
            } else {
                Button(String(localized: "maximize"), systemImage: "arrow.up.left.and.arrow.down.right") {
                    windowManager.maximizeWindow(window)
                }
            }

            Button(String(localized: "minimize"), systemImage: "minus") {
                windowManager.minimizeWindow(window)
            }
            .disabled(windowManager.visibleWindows.count <= 1)

            Divider()

            Toggle(isOn: Binding(
                get: { window.isSynchronized },
                set: { window.isSynchronized = $0 }
            )) {
                SwiftUI.Label(String(localized: "sync_scrolling"), systemImage: "arrow.triangle.2.circlepath")
            }

            Toggle(isOn: Binding(
                get: { window.isPinMode },
                set: { window.isPinMode = $0 }
            )) {
                SwiftUI.Label(String(localized: "pin"), systemImage: "pin")
            }

            // Sync group picker
            Menu(String(localized: "sync_group")) {
                ForEach(0..<6) { group in
                    Button {
                        window.syncGroup = group
                    } label: {
                        if window.syncGroup == group {
                            SwiftUI.Label(String(localized: "Group \(group)"), systemImage: "checkmark")
                        } else {
                            Text(String(localized: "Group \(group)"))
                        }
                    }
                }
            }

            Divider()

            Button(String(localized: "close"), systemImage: "xmark", role: .destructive) {
                windowManager.removeWindow(window)
            }
            .disabled(windowManager.allWindows.count <= 1)
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Copy the current reference (e.g. "Genesis 1 (KJV)") to clipboard.
    private func copyReference() {
        guard let ctrl = controller else { return }
        let ref = "\(ctrl.currentBook) \(ctrl.currentChapter) (\(ctrl.activeModuleName))"
        #if os(iOS)
        UIPasteboard.general.string = ref
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ref, forType: .string)
        #endif
        onShowToast?(String(localized: "reference_copied"))
    }

    private func initializeController() {
        guard controller == nil else { return }

        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        let workspaceStore = WorkspaceStore(modelContext: modelContext)
        let store = SettingsStore(modelContext: modelContext)

        let ctrl = BibleReaderController(bridge: bridge, bookmarkService: bookmarkService)
        ctrl.displaySettings = displaySettings
        ctrl.nightMode = nightMode
        ctrl.speakService = speakService
        ctrl.workspaceStore = workspaceStore
        ctrl.activeWindow = window
        ctrl.settingsStore = store

        // Share module discovery from an existing controller to avoid
        // creating multiple conflicting SwordManager C++ instances.
        if let existingCtrl = windowManager.controllers.values.first(where: { $0 !== ctrl }) as? BibleReaderController {
            ctrl.copyModuleState(from: existingCtrl)
        }

        ctrl.restoreSavedPosition()

        // Wire callbacks to parent
        ctrl.onShareVerseText = { text in onShareText?(text) }
        ctrl.onRequestOpenDownloads = { onShowDownloads?() }
        ctrl.onShowStrongsDefinition = { json, config in onShowStrongsSheet?(json, config) }
        ctrl.onShowStrongsSearch = { strongsNum in onSearchForStrongs?(strongsNum) }
        ctrl.onShowCrossReferences = { refs in onShowCrossReferences?(refs) }
        ctrl.onCompareVerses = { [weak ctrl] book, chapter, moduleName, startVerse, endVerse in
            #if os(iOS)
            let osisId = ctrl?.osisBookId(for: book)
            presentCompareView(book: book, chapter: chapter, currentModuleName: moduleName, startVerse: startVerse, endVerse: endVerse, osisBookId: osisId)
            #endif
        }
        ctrl.onAssignLabels = { bookmarkId in
            logger.info("onAssignLabels triggered: bookmarkId=\(bookmarkId)")
            pendingLabelBookmarkId = bookmarkId
        }
        ctrl.onPersistState = { try? modelContext.save() }
        ctrl.onShowToast = { text in onShowToast?(text) }
        ctrl.onShareHtml = { html in
            #if os(iOS)
            guard let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
                  let rootVC = windowScene.windows.first?.rootViewController else { return }
            var topVC = rootVC
            while let presented = topVC.presentedViewController { topVC = presented }
            let activityVC = UIActivityViewController(activityItems: [html], applicationActivities: nil)
            topVC.present(activityVC, animated: true)
            #endif
        }

        ctrl.onToggleFullScreen = { onToggleFullScreen?() }

        // Reference chooser dialog: present book chooser and return OSIS ref
        ctrl.onRefChooserDialog = { completion in
            onRefChooserDialog?(completion)
        }

        // Focus-on-interaction: any bridge message from this pane sets it as active.
        // Wire to bridge.onAnyMessage so ANY user interaction (tap, scroll, selection)
        // triggers focus — matching Android's onTouchEvent → activeWindow = window.
        let focusHandler: () -> Void = { [weak windowManager] in
            guard let wm = windowManager else { return }
            if wm.activeWindow?.id != window.id {
                wm.activeWindow = window
                // Notify all controllers to update their active state in Vue.js
                for (_, controllerObj) in wm.controllers {
                    if let controller = controllerObj as? BibleReaderController {
                        controller.emitActiveState()
                    }
                }
            }
        }
        ctrl.onInteraction = focusHandler
        bridge.onAnyMessage = focusHandler

        // Wire WindowManager reference for synchronized scrolling
        ctrl.windowManagerRef = windowManager

        // Links window support: single OSIS references open in a links window
        ctrl.onOpenInLinksWindow = { [weak windowManager] book, chapter in
            guard let wm = windowManager else { return }
            // Find or create a links window for this source window
            let linksWindow: Window
            if let existingId = window.targetLinksWindowId,
               let existing = wm.allWindows.first(where: { $0.id == existingId }) {
                linksWindow = existing
                if existing.layoutState == "minimized" {
                    existing.layoutState = "split"
                }
            } else if let newWindow = wm.addWindow(from: window) {
                newWindow.isLinksWindow = true
                newWindow.isPinMode = true
                newWindow.isSynchronized = false
                window.targetLinksWindowId = newWindow.id
                linksWindow = newWindow
            } else {
                return
            }
            wm.refreshWindows()
            // Navigate the links window's controller to the reference
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let ctrl = wm.controllers[linksWindow.id] as? BibleReaderController {
                    ctrl.navigateTo(book: book, chapter: chapter)
                }
            }
        }

        controller = ctrl

        // Register controller with WindowManager — the single source of truth.
        // BibleReaderView reads from windowManager.controllers via focusedController,
        // and controllerVersion ensures SwiftUI re-evaluates the toolbar.
        windowManager.registerController(ctrl, for: window.id)

        // Re-register asynchronously to guarantee a re-render.  The synchronous
        // registration above runs during onAppear, which SwiftUI may coalesce with
        // the current layout pass — preventing controllerVersion from triggering a
        // toolbar update.  The async call bumps controllerVersion in a new run-loop
        // iteration where SwiftUI reliably picks up the change.
        let wm = windowManager
        let wid = window.id
        Task { @MainActor in
            wm.registerController(ctrl, for: wid)
        }
    }

    private var selectionActionBar: some View {
        HStack(spacing: 20) {
            Button { controller?.bookmarkSelection() } label: {
                VStack(spacing: 2) {
                    Image(systemName: "bookmark")
                    Text(String(localized: "bookmark")).font(.caption2)
                }
            }
            Button { controller?.copySelection() } label: {
                VStack(spacing: 2) {
                    Image(systemName: "doc.on.doc")
                    Text(String(localized: "copy")).font(.caption2)
                }
            }
            Button { controller?.shareSelection() } label: {
                VStack(spacing: 2) {
                    Image(systemName: "square.and.arrow.up")
                    Text(String(localized: "share")).font(.caption2)
                }
            }
            Button { controller?.compareSelection() } label: {
                VStack(spacing: 2) {
                    Image(systemName: "text.justify.left")
                    Text(String(localized: "compare")).font(.caption2)
                }
            }
            Button { controller?.speakSelection() } label: {
                VStack(spacing: 2) {
                    Image(systemName: "speaker.wave.2")
                    Text(String(localized: "speak")).font(.caption2)
                }
            }
            Button { controller?.webSearchSelection() } label: {
                VStack(spacing: 2) {
                    Image(systemName: "magnifyingglass")
                    Text(String(localized: "search_web")).font(.caption2)
                }
            }
        }
        .font(.body)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4)
        .padding(.bottom, 8)
    }
}
