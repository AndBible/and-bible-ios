// BibleWindowPane.swift -- Per-window Bible rendering pane

import SwiftUI
import SwiftData
import BibleView
import BibleCore
import SwordKit
import os.log

private let logger = Logger(subsystem: "org.andbible", category: "BibleWindowPane")

/**
 Hosts one fully independent reading pane inside the multi-window reader.

 Each pane owns its own `BibleBridge`, `BibleReaderController`, and `BibleWebView`, while
 delegating sheet/alert/toast presentation back to `BibleReaderView` through callback closures.
 This separation lets multiple panes render different modules and references simultaneously
 while still sharing workspace-level state from `WindowManager`.

 Data dependencies:
 - `window`, `isFocused`, `displaySettings`, `nightMode`, `disableTwoStepBookmarking`, and
   `hideWindowButtons` drive pane rendering and controller updates
 - `WindowManager` is required from the environment for controller registration, layout actions,
   active-window coordination, and window-menu actions
 - `modelContext` is required from the environment so the pane can construct stores and persist
   bookmark, history, and settings mutations initiated by the controller

 Side effects:
 - `onAppear` lazily creates the pane controller and registers it with `WindowManager`
 - `onDisappear` unregisters the controller when the pane leaves the hierarchy
 - `onChange` for `nightMode` and `displaySettings` pushes updated display state into the
   embedded web view via `BibleReaderController.updateDisplaySettings`
 */
struct BibleWindowPane: View {
    /// Window model that owns this pane's persisted position, layout, and history state.
    let window: Window

    /// Whether this pane is currently the active/focused pane in the workspace.
    let isFocused: Bool

    /// Fully resolved text-display settings pushed into the pane's controller and web view.
    let displaySettings: TextDisplaySettings

    /// Whether the pane should render using night-mode colors and styling.
    let nightMode: Bool

    /// Android-parity bookmarking mode toggle for the selection action bar.
    let disableTwoStepBookmarking: Bool

    /// Whether the per-pane hamburger button should be hidden.
    let hideWindowButtons: Bool

    /// Shared TTS service used by controllers when speaking selections or chapters.
    let speakService: SpeakService

    /// Native/web bridge for this pane's WKWebView instance.
    @State private var bridge = BibleBridge()

    /// Controller that owns module state, navigation, and bridge callbacks for this pane.
    @State private var controller: BibleReaderController?

    /// Bookmark awaiting label-assignment sheet presentation.
    @State private var pendingLabelBookmarkId: UUID?

    /// Controls presentation of the typed-reference alert from the pane menu.
    @State private var showGoToRefAlert = false

    /// Draft typed-reference text bound to the pane alert text field.
    @State private var goToRefText = ""

    /// Shared workspace/window coordinator used for controller registration and layout actions.
    @Environment(WindowManager.self) private var windowManager

    /// SwiftData context used to build stores and persist pane-driven mutations.
    @Environment(\.modelContext) private var modelContext

    /// Requests the parent reader to present the book chooser.
    var onShowBookChooser: (() -> Void)?

    /// Requests the parent reader to present search UI.
    var onShowSearch: (() -> Void)?

    /// Requests the parent reader to present bookmark UI.
    var onShowBookmarks: (() -> Void)?

    /// Requests the parent reader to present settings UI.
    var onShowSettings: (() -> Void)?

    /// Requests the parent reader to present download/module-management UI.
    var onShowDownloads: (() -> Void)?

    /// Requests the parent reader to present navigation history UI.
    var onShowHistory: (() -> Void)?

    /// Requests the parent reader to present compare UI.
    var onShowCompare: (() -> Void)?

    /// Requests the parent reader to present reading-plan UI.
    var onShowReadingPlans: (() -> Void)?

    /// Requests the parent reader to present speak controls.
    var onShowSpeakControls: (() -> Void)?

    /// Forwards shareable plain-text content to the parent share presenter.
    var onShareText: ((String) -> Void)?

    /// Forwards cross-reference payloads for parent-managed presentation.
    var onShowCrossReferences: (([CrossReference]) -> Void)?

    /// Requests the parent reader to open the module picker for a document category.
    var onShowModulePicker: ((DocumentCategory) -> Void)?

    /// Emits transient toast text through the parent reader.
    var onShowToast: ((String) -> Void)?

    /// Requests the parent reader to show workspace-selection UI.
    var onShowWorkspaces: (() -> Void)?

    /// Toggles fullscreen mode in the parent reader.
    var onToggleFullScreen: (() -> Void)?

    /// Starts a Strong's-number search in the parent search UI.
    var onSearchForStrongs: ((String) -> Void)?

    /// Presents the Strong's definition sheet with raw JSON/config payloads.
    var onShowStrongsSheet: ((String, String) -> Void)?

    /// Requests the parent reader to open the reference chooser dialog and return a result.
    var onRefChooserDialog: ((@escaping (String?) -> Void) -> Void)?

    /// Reports user-driven vertical scroll deltas to the parent reader.
    var onUserScrollDeltaY: ((Double) -> Void)?

    /// Reports native horizontal swipe gestures to the parent reader.
    var onUserHorizontalSwipe: ((NativeHorizontalSwipeDirection) -> Void)?

    /// Active reading-background color encoded as the signed ARGB integer expected by BibleWebView.
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
            if !hideWindowButtons && (windowManager.visibleWindows.count > 1 || windowManager.allWindows.count > 1) {
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

    /// Hamburger menu overlay providing pane-scoped content, layout, and sync actions.
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

    /// Copies the pane's current reference string and triggers toast feedback.
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

    /**
     Creates and wires the controller/bridge stack for this pane.

     The setup flow:
     1. build pane-scoped stores/services from `modelContext`
     2. create `BibleReaderController` and inject display, speak, and workspace dependencies
     3. optionally copy shared module state from an existing controller to avoid duplicate SWORD setup
     4. restore the persisted position
     5. wire pane-to-parent callbacks and register the controller with `WindowManager`
     */
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
        bridge.onNativeScrollDeltaY = { deltaY in
            onUserScrollDeltaY?(deltaY)
        }
        bridge.onNativeHorizontalSwipe = { direction in
            onUserHorizontalSwipe?(direction)
        }

        // Wire WindowManager reference for synchronized scrolling
        ctrl.windowManagerRef = windowManager

        // Links window support: single OSIS references open in a links window
        ctrl.onOpenInLinksWindow = { [weak windowManager] book, chapter in
            let useLinksWindow = store.getBool(.openLinksInSpecialWindowPref)
            guard useLinksWindow else {
                ctrl.navigateTo(book: book, chapter: chapter)
                return
            }

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

    /// Floating action bar shown while the pane has an active text selection.
    private var selectionActionBar: some View {
        HStack(spacing: 20) {
            if controller?.currentCategory == .bible {
                if disableTwoStepBookmarking {
                    Button { controller?.bookmarkSelection(wholeVerse: false) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "bookmark")
                            Text(String(
                                localized: "add_bookmark3",
                                defaultValue: "Selection"
                            ))
                            .font(.caption2)
                        }
                    }
                    Button { controller?.bookmarkSelection(wholeVerse: true) } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "bookmark.fill")
                            Text(String(
                                localized: "add_bookmark_whole_verse1",
                                defaultValue: "Verses"
                            ))
                            .font(.caption2)
                        }
                    }
                } else {
                    Menu {
                        Button(String(
                            localized: "add_bookmark3",
                            defaultValue: "Selection"
                        )) {
                            controller?.bookmarkSelection(wholeVerse: false)
                        }
                        Button(String(
                            localized: "add_bookmark_whole_verse1",
                            defaultValue: "Verses"
                        )) {
                            controller?.bookmarkSelection(wholeVerse: true)
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "bookmark")
                            Text(String(localized: "bookmark")).font(.caption2)
                        }
                    }
                }
            } else {
                Button { controller?.bookmarkSelection(wholeVerse: true) } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "bookmark")
                        Text(String(localized: "bookmark")).font(.caption2)
                    }
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
            if controller?.hasWordLookupDictionaries == true {
                Button { controller?.lookupSelectionInDictionaries() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "book.closed")
                        Text(String(localized: "dictionary")).font(.caption2)
                    }
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
