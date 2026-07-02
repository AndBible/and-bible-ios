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

 Each pane uses the `BibleBridge` and `BibleReaderController` registered for its `Window`, while
 delegating sheet/alert/toast presentation back to `BibleReaderView` through callback closures.
 Keeping that controller/bridge pair scoped to the window, not transient SwiftUI appearances, lets
 multiple panes render different modules and references simultaneously while still sharing
 workspace-level state from `WindowManager`.

 Data dependencies:
 - `window`, `displaySettings`, `nightMode`, `monochromeMode`, `disableTwoStepBookmarking`, and
   `hideWindowButtons` drive pane rendering and controller updates
 - `WindowManager` is required from the environment for controller registration, layout actions,
   active-window coordination, and window-menu actions
 - `modelContext` is required from the environment so the pane can construct stores and persist
   bookmark, history, and settings mutations initiated by the controller

 Side effects:
 - `onAppear` lazily creates or reuses the pane controller and registers it with `WindowManager`
 - window removal or workspace switching unregisters controllers from `WindowManager`
 - `onChange` for `nightMode` and `displaySettings` pushes updated display state into the
   embedded web view via `BibleReaderController.updateDisplaySettings`
 */
struct BibleWindowPane: View {
    /// Window model that owns this pane's persisted position, layout, and history state.
    let window: Window

    /// Fully resolved text-display settings pushed into the pane's controller and web view.
    let displaySettings: TextDisplaySettings

    /// Whether the pane should render using night-mode colors and styling.
    let nightMode: Bool

    /// Whether Android's monochrome/e-ink preference should affect native pane chrome.
    let monochromeMode: Bool

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

    /// Whether the custom Android-style pane hamburger menu is visible.
    @State private var isWindowMenuPresented = false

    /// Shared workspace/window coordinator used for controller registration and layout actions.
    @Environment(WindowManager.self) private var windowManager

    /// Current platform color scheme used by custom Android-style popup surfaces.
    @Environment(\.colorScheme) private var colorScheme

    /// SwiftData context used to build stores and persist pane-driven mutations.
    @Environment(\.modelContext) private var modelContext

    /// Bridge that should back the current `BibleWebView` render pass.
    private var webBridge: BibleBridge {
        if let controller {
            return controller.bridge
        }
        if let registeredController = windowManager.controllers[window.id] as? BibleReaderController {
            return registeredController.bridge
        }
        return bridge
    }

    /// Requests the parent reader to present the book chooser.
    var onShowBookChooser: (() -> Void)?

    /// Requests the parent reader to present search UI.
    var onShowSearch: (() -> Void)?

    /// Requests the parent reader to present bookmark UI.
    var onShowBookmarks: (() -> Void)?

    /// Requests the parent reader to present settings UI.
    var onShowSettings: (() -> Void)?

    /// Requests the parent reader to present this pane's window-scoped text-display settings.
    var onShowWindowTextOptions: (() -> Void)?

    /// Requests the parent reader to present this pane's window-scoped color settings.
    var onShowWindowColorSettings: (() -> Void)?

    /// Requests the parent reader to toggle this pane's section-title visibility.
    var onToggleWindowSectionTitles: (() -> Void)?

    /// Requests the parent reader to present this pane's Strong's-number mode chooser.
    var onShowWindowStrongsMode: (() -> Void)?

    /// Requests the parent reader to toggle this pane's chapter-and-verse number visibility.
    var onToggleWindowVerseNumbers: (() -> Void)?

    /// Requests the parent reader to copy this pane's text settings to another visible window.
    var onCopyWindowSettingsToWindow: ((UUID) -> Void)?

    /// Requests the parent reader to copy this pane's text settings to the active workspace.
    var onCopyWindowSettingsToWorkspace: (() -> Void)?

    /// Requests the parent reader to copy this pane's text settings to global defaults.
    var onCopyWindowSettingsToGlobal: (() -> Void)?

    /// Requests the parent reader to present download/module-management UI with optional search.
    var onShowDownloads: ((String?) -> Void)?

    /// Requests the parent reader to present navigation history UI.
    var onShowHistory: (() -> Void)?

    /// Requests the parent reader to present compare UI.
    var onShowCompare: (() -> Void)?

    /// Requests the parent reader to present reading-plan UI.
    var onShowReadingPlans: (() -> Void)?

    /// Requests the parent reader to present reading-progress UI.
    var onShowReadingProgress: ((Int) -> Void)?

    /// Requests the parent reader to present reading-progress settings UI.
    var onShowReadingProgressSettings: (() -> Void)?

    /// Requests the parent reader to present chapter read-history UI.
    var onShowChapterReadHistory: ((ChapterReadHistoryTarget) -> Void)?

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

    /// Requests the parent reader to open the reference chooser dialog and return a result.
    var onRefChooserDialog: ((@escaping (String?) -> Void) -> Void)?

    /// Requests app-owned label assignment for a WebView-created or WebView-selected bookmark.
    var onAssignLabels: ((UUID) -> Void)?

    /// Reports user-driven vertical scroll deltas to the parent reader.
    var onUserScrollDeltaY: ((Double) -> Void)?

    /// Reports native horizontal swipe gestures to the parent reader.
    var onUserHorizontalSwipe: ((NativeHorizontalSwipeDirection) -> Void)?

    /// Active reading-background color encoded as the signed ARGB integer expected by BibleWebView.
    private var activeBackgroundColorInt: Int {
        surfacePalette.backgroundColorInt
    }

    /// Reader-surface colors derived from this pane's resolved text-display settings.
    private var surfacePalette: ReaderThemeSurfacePalette {
        ReaderThemeSurfacePalette(
            settings: displaySettings,
            nightMode: nightMode,
            monochromeMode: monochromeMode
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            BibleWebView(bridge: webBridge, backgroundColorInt: activeBackgroundColorInt)
                .ignoresSafeArea(edges: .bottom)

            // Selection action bar — shows when text is long-press selected
            if controller?.hasActiveSelection == true {
                selectionActionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            // Window menu button — matches Android's hamburger button in top-right of each pane
            if !hideWindowButtons && !windowManager.isMaximized {
                windowMenuButton
                    .padding(AndroidWindowButtonMetrics.paneOverlayInset)
            }
        }
        .overlay {
            if isWindowMenuPresented {
                windowMenuOverlay
            }
        }
        .onAppear {
            if controller == nil {
                initializeController()
            } else {
                let workspaceStore = WorkspaceStore(modelContext: modelContext)
                let settingsStore = SettingsStore(modelContext: modelContext)
                configureController(controller!, workspaceStore: workspaceStore, settingsStore: settingsStore)
                registerController(controller!)
            }
        }
        .onChange(of: nightMode) { _, newValue in
            controller?.updateDisplaySettings(displaySettings, nightMode: newValue)
        }
        .onChange(of: displaySettings) { _, newValue in
            controller?.updateDisplaySettings(newValue, nightMode: nightMode)
        }
    }

    /**
     Hamburger menu overlay providing pane-scoped content, layout, and sync actions.
     Opening the menu also marks this pane active, matching Android's pane menu behavior.
    */
    private var windowMenuButton: some View {
        let buttonPalette = AndroidWindowButtonPalette.resolved(
            for: surfacePalette,
            monochromeMode: monochromeMode
        )
        let isActive = windowManager.activeWindow?.id == window.id

        return ZStack(alignment: .topTrailing) {
            Text(AndroidWindowButtonMetrics.paneMenuGlyph)
                .font(.system(size: AndroidWindowButtonMetrics.paneMenuTextSize, weight: .bold))
                .foregroundStyle(buttonPalette.paneButtonTextColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if window.isLinksWindow {
                ToolbarAssetIcon(
                    name: AndroidWindowButtonMetrics.paneLinksIconName,
                    size: AndroidWindowButtonMetrics.paneLinksIconSize
                )
                .foregroundStyle(buttonPalette.paneLinksIconColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 2)
                .padding(.trailing, 2)
            }
        }
            .frame(
                width: AndroidWindowButtonMetrics.buttonSize,
                height: AndroidWindowButtonMetrics.buttonSize
            )
            .background(
                buttonPalette.paneButtonBackgroundColor(isActive: isActive),
                in: RoundedRectangle(cornerRadius: AndroidWindowButtonMetrics.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AndroidWindowButtonMetrics.cornerRadius)
                    .strokeBorder(
                        buttonPalette.paneButtonStrokeColor,
                        lineWidth: buttonPalette.paneButtonStrokeWidth(isActive: isActive)
                    )
            )
            .contentShape(Rectangle())
            .gesture(windowMenuTapOrLongPressGesture)
            .simultaneousGesture(windowMenuDragGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("windowPaneMenuButton::\(window.orderNumber)")
            .accessibilityLabel(
                String(localized: "window_menu_accessibility_label", defaultValue: "Window menu")
            )
            .accessibilityHint(
                String(localized: "window_menu_accessibility_hint", defaultValue: "Opens window actions")
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                performPaneWindowButtonAction(.openMenu)
            }
    }

    /**
     Builds Android's mutually exclusive tap/long-press pane-button gesture.

     - Returns: A gesture that opens the pane menu on tap and minimizes on long press.
     - Side effects: Invokes the same window-state mutations as Android's `WindowButtonWidget`.
     - Failure modes: Cancelled long presses do not mutate window state.
     */
    private var windowMenuTapOrLongPressGesture: some Gesture {
        LongPressGesture().exclusively(before: TapGesture()).onEnded { value in
            switch value {
            case .first(true):
                performPaneWindowButtonAction(.minimize)
            case .second:
                performPaneWindowButtonAction(.openMenu)
            case .first(false):
                break
            }
        }
    }

    /**
     Builds Android's vertical swipe pane-button gesture.

     - Returns: A drag gesture that maps upward swipes to maximize and downward swipes to minimize.
     - Side effects: Invokes window layout mutations when the drag classifier accepts the gesture.
     - Failure modes: Short, horizontal, diagonal, or non-finite translations are ignored.
     */
    private var windowMenuDragGesture: some Gesture {
        DragGesture(minimumDistance: 12).onEnded { value in
            performPaneWindowButtonAction(
                AndroidPaneWindowButtonGestureAction.action(forDragTranslation: value.translation)
            )
        }
    }

    /**
     Applies Android pane-window-button actions to this pane.

     - Parameter action: Gesture action resolved from tap, long press, or drag.
     - Side effects: Marks this pane active, opens the popup menu, or mutates window layout.
     - Failure modes: `.none` is ignored; layout actions rely on `WindowManager` guards.
     */
    private func performPaneWindowButtonAction(_ action: AndroidPaneWindowButtonGestureAction) {
        guard action != .none else { return }
        windowManager.activeWindow = window
        switch action {
        case .openMenu:
            withAnimation(.easeOut(duration: 0.12)) {
                isWindowMenuPresented.toggle()
            }
        case .minimize:
            isWindowMenuPresented = false
            windowManager.minimizeWindow(window)
        case .maximize:
            isWindowMenuPresented = false
            windowManager.maximizeWindow(window)
        case .none:
            break
        }
    }

    /**
     Full-pane dismiss area plus an anchored custom popup for pane-scoped Android menu actions.

     The popup is anchored below the pane hamburger button rather than using `SwiftUI.Menu`, so
     iOS does not substitute platform-native row styling or submenu presentation. Terminal actions
     close the popup before mutating window state, matching Android's popup dismissal behavior.
     */
    private var windowMenuOverlay: some View {
        GeometryReader { proxy in
            let width = min(max(proxy.size.width - 12, 220), 320)
            let maximumHeight = max(proxy.size.height - 52, 120)
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.12)) {
                            isWindowMenuPresented = false
                        }
                    }
                    .accessibilityIdentifier("windowPaneMenuDismissArea::\(window.orderNumber)")

                BibleWindowPaneMenuPopup(
                    items: BibleWindowPaneMenuModel(snapshot: windowMenuSnapshot).items,
                    colorScheme: colorScheme,
                    maximumHeight: maximumHeight
                ) { action in
                    withAnimation(.easeOut(duration: 0.12)) {
                        isWindowMenuPresented = false
                    }
                    performWindowMenuAction(action)
                }
                .frame(width: width, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.45 : 0.12), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.18), radius: 14, y: 6)
                .padding(.top, 42)
                .padding(.trailing, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
    }

    private var windowMenuSnapshot: BibleWindowPaneMenuSnapshot {
        let capabilities = BibleWindowPaneMenuCapabilities(window: window, controller: controller)
        let resolvedSettings = displaySettings
        return BibleWindowPaneMenuSnapshot(
            windowID: window.id,
            isLinksWindow: window.isLinksWindow,
            isPinned: window.isPinMode,
            isSynchronized: window.isSynchronized,
            syncGroup: window.syncGroup,
            isVisible: window.layoutState != "minimized",
            isMaximized: windowManager.isMaximized,
            canMinimize: window.layoutState != "minimized" && windowManager.visibleWindows.count > 1,
            canClose: windowManager.allWindows.count > 1,
            canSync: capabilities.canSyncWindow,
            canCopyLink: currentCopyLinkURL != nil,
            autoPinEnabled: windowManager.activeWorkspace?.workspaceSettings?.autoPin ?? false,
            moduleHasStrongs: controller?.hasStrongs ?? false,
            sectionTitlesEnabled: resolvedSettings.showSectionTitles ?? true,
            verseNumbersEnabled: resolvedSettings.showVerseNumbers ?? true,
            allWindowsInPersistedOrder: windowSummaries(windowManager.windowsInPersistedOrder),
            visibleWindows: windowSummaries(windowManager.visibleWindows)
        )
    }

    private func windowSummaries(_ windows: [Window]) -> [BibleWindowPaneMenuWindowSummary] {
        windows.enumerated().map { index, candidate in
            let candidateController = windowManager.controllers[candidate.id] as? BibleReaderController
            return BibleWindowPaneMenuWindowSummary(
                id: candidate.id,
                position: index,
                documentAbbreviation: documentAbbreviation(for: candidate, controller: candidateController),
                referenceName: referenceName(for: candidate, controller: candidateController),
                isPinned: candidate.isPinMode
            )
        }
    }

    private func documentAbbreviation(for window: Window, controller: BibleReaderController?) -> String? {
        if let controller {
            return controller.activeModuleName(for: controller.currentCategory)
        }
        guard let pageManager = window.pageManager else { return nil }
        switch pageManager.currentCategoryName {
        case DocumentCategory.bible.pageManagerKey:
            return pageManager.bibleDocument
        case DocumentCategory.commentary.pageManagerKey:
            return pageManager.commentaryDocument
        case DocumentCategory.dictionary.pageManagerKey:
            return pageManager.dictionaryDocument
        case DocumentCategory.generalBook.pageManagerKey:
            return pageManager.generalBookDocument
        case DocumentCategory.map.pageManagerKey:
            return pageManager.mapDocument
        case DocumentCategory.epub.pageManagerKey:
            return pageManager.epubIdentifier
        default:
            return pageManager.bibleDocument
        }
    }

    private func referenceName(for window: Window, controller: BibleReaderController?) -> String? {
        if let controller {
            switch controller.currentCategory {
            case .bible, .commentary:
                return "\(controller.currentBook) \(controller.currentChapter)"
            case .dictionary:
                return controller.currentDictionaryKey
            case .generalBook:
                return controller.currentGeneralBookKey
            case .map:
                return controller.currentMapKey
            case .epub:
                return controller.currentEpubTitle ?? controller.currentEpubHref
            case .dailyDevotion:
                return nil
            }
        }
        guard let pageManager = window.pageManager else { return nil }
        switch pageManager.currentCategoryName {
        case DocumentCategory.bible.pageManagerKey, DocumentCategory.commentary.pageManagerKey:
            if let book = pageManager.bibleBibleBook, let chapter = pageManager.bibleChapterNo {
                return "\(book):\(chapter)"
            }
            return nil
        case DocumentCategory.dictionary.pageManagerKey:
            return pageManager.dictionaryKey
        case DocumentCategory.generalBook.pageManagerKey:
            return pageManager.generalBookKey
        case DocumentCategory.map.pageManagerKey:
            return pageManager.mapKey
        case DocumentCategory.epub.pageManagerKey:
            return pageManager.epubHref
        default:
            return nil
        }
    }

    private func performWindowMenuAction(_ action: BibleWindowPaneMenuAction) {
        windowManager.activeWindow = window
        switch action {
        case .newWindow:
            windowManager.addWindow(from: window)
        case .maximize:
            windowManager.maximizeWindow(window)
        case .minimize:
            windowManager.minimizeWindow(window)
        case .changeToNormalWindow:
            windowManager.changeLinksWindowToNormal(window)
        case .moveToPosition(let position):
            windowManager.moveWindow(window, toPosition: position)
        case .togglePin:
            windowManager.setPinMode(window, value: !window.isPinMode)
        case .disableSync:
            windowManager.setSynchronized(window, value: false)
        case .selectSyncGroup(let group):
            windowManager.changeSyncGroup(window, groupNumber: group)
        case .openColorSettings:
            onShowWindowColorSettings?()
        case .toggleSectionTitles:
            onToggleWindowSectionTitles?()
        case .openStrongsMode:
            onShowWindowStrongsMode?()
        case .toggleVerseNumbers:
            onToggleWindowVerseNumbers?()
        case .openAllTextOptions:
            onShowWindowTextOptions?()
        case .copySettingsToWindow(let targetWindowID):
            onCopyWindowSettingsToWindow?(targetWindowID)
        case .copySettingsToWorkspace:
            onCopyWindowSettingsToWorkspace?()
        case .copySettingsToGlobal:
            onCopyWindowSettingsToGlobal?()
        case .copyLink:
            copyReference()
        case .close:
            windowManager.removeWindow(window)
        }
    }

    /// Copies the pane's Android-compatible reference URL and triggers toast feedback.
    private func copyReference() {
        guard let url = currentCopyLinkURL else { return }

        #if os(iOS)
        UIPasteboard.general.string = url
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        #endif
        onShowToast?(localizedDrawerString("reference_copied_to_clipboard", default: "Reference copied to clipboard"))
    }

    private var currentCopyLinkURL: String? {
        guard let ctrl = controller else { return nil }
        guard !ctrl.isShowingAndroidMultiDocument else { return nil }
        guard ctrl.currentCategory == .bible || ctrl.currentCategory == .commentary else { return nil }

        let documentInitials: String
        if ctrl.currentCategory == .commentary, let commentaryInitials = ctrl.activeCommentaryModuleName {
            documentInitials = commentaryInitials
        } else {
            documentInitials = ctrl.activeModuleName
        }

        let osisBookId = ctrl.osisBookId(for: ctrl.currentBook)
        guard !osisBookId.isEmpty else { return nil }
        let osisRef = "\(osisBookId).\(ctrl.currentChapter).\(ctrl.currentVerse)"
        let ordinal = ctrl.activeModule?.verseOrdinal(
            osisBookId: osisBookId,
            chapter: ctrl.currentChapter,
            verse: ctrl.currentVerse
        )
        return AndBibleReferenceURLBuilder.urlString(
            osisRef: osisRef,
            documentInitials: documentInitials,
            ordinal: ordinal
        )
    }

    /**
     Creates and wires the controller/bridge stack for this pane.

     The setup flow:
     1. build pane-scoped stores/services from `modelContext`
     2. create `BibleReaderController` and inject display, speak, and workspace dependencies
     3. copy shared module state from an existing controller before any fallback SWORD setup
     4. restore the persisted position
     5. wire pane-to-parent callbacks and register the controller with `WindowManager`
     */
    private func initializeController() {
        guard controller == nil else { return }

        let workspaceStore = WorkspaceStore(modelContext: modelContext)
        let store = SettingsStore(modelContext: modelContext)

        if let existingController = windowManager.controllers[window.id] as? BibleReaderController {
            bridge = existingController.bridge
            controller = existingController
            configureController(existingController, workspaceStore: workspaceStore, settingsStore: store)
            registerController(existingController)
            return
        }

        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        let sharedControllers = windowManager.controllers.values
            .compactMap { $0 as? BibleReaderController }
        let ctrl = BibleReaderController(
            bridge: bridge,
            bookmarkService: bookmarkService,
            initializesSword: sharedControllers.isEmpty
        )
        configureController(ctrl, workspaceStore: workspaceStore, settingsStore: store)

        if !sharedControllers.isEmpty {
            let didCopyModuleState = sharedControllers.contains { ctrl.copyModuleState(from: $0) }
            if !didCopyModuleState {
                logger.warning("Unable to copy SWORD state from registered controllers; initializing pane controller independently")
                ctrl.initializeSwordIfNeeded()
            }
        }

        ctrl.restoreSavedPosition()

        controller = ctrl
        registerController(ctrl)
    }

    /// Wires transient view dependencies back into a pane-scoped controller.
    private func configureController(
        _ ctrl: BibleReaderController,
        workspaceStore: WorkspaceStore,
        settingsStore store: SettingsStore
    ) {
        ctrl.displaySettings = displaySettings
        ctrl.nightMode = nightMode
        ctrl.speakService = speakService
        ctrl.workspaceStore = workspaceStore
        ctrl.activeWindow = window
        ctrl.settingsStore = store
        ctrl.myDocumentStore = MyDocumentStore(modelContext: modelContext)

        ctrl.onShareVerseText = { text in onShareText?(text) }
        ctrl.onRequestOpenDownloads = { initialSearchText in onShowDownloads?(initialSearchText) }
        ctrl.onShowStrongsSearch = { strongsNum in onSearchForStrongs?(strongsNum) }
        ctrl.onShowCrossReferences = { refs in onShowCrossReferences?(refs) }
        ctrl.onShowReadingProgress = { tab in onShowReadingProgress?(tab) }
        ctrl.onShowReadingProgressSettings = { onShowReadingProgressSettings?() }
        ctrl.onShowChapterReadHistory = { target in onShowChapterReadHistory?(target) }
        ctrl.onAssignLabels = { bookmarkId in
            logger.info("onAssignLabels triggered: bookmarkId=\(bookmarkId)")
            onAssignLabels?(bookmarkId)
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

        // Focus-on-interaction: bridge messages and native web-view gestures from this pane set it
        // active. The native callback covers plain taps that do not emit JavaScript messages,
        // matching Android's onTouchEvent -> activeWindow = window behavior.
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
        ctrl.bridge.onAnyMessage = { [weak ctrl] in
            ctrl?.handleUserInteraction()
        }
        ctrl.bridge.onNativeUserInteraction = { [weak ctrl] in
            ctrl?.handleUserInteraction()
        }
        ctrl.bridge.onNativeScrollDeltaY = { [weak ctrl, weak windowManager] deltaY in
            guard let ctrl else { return }
            guard ctrl.shouldTreatNativeScrollDeltaAsUserInteraction() else { return }
            if windowManager?.activeWindow?.id != window.id {
                ctrl.handleUserInteraction()
            }
            onUserScrollDeltaY?(deltaY)
        }
        ctrl.bridge.onNativeHorizontalSwipe = { direction in
            onUserHorizontalSwipe?(direction)
        }

        // Wire WindowManager reference for synchronized scrolling
        ctrl.windowManagerRef = windowManager

        /**
         Resolves the Android-style links target window for link results from this pane.

         - Parameter wm: Window manager that owns the source window and controller registry.
         - Returns: The existing or newly created links window, or `nil` when the manager cannot
           create another window.
         - Side effects: may create or unminimize the workspace primary links window, may create a
           chained target for a source links window, and refreshes visible windows.
         - Failure modes: returns `nil` when window creation is refused by the manager.
         */
        func prepareLinksWindow(using wm: WindowManager) -> Window? {
            wm.linksWindow(for: window)
        }

        /**
         Runs a link-result load as soon as the destination pane controller exists.

         SwiftUI creates the new pane and registers its controller on the next layout pass. Android
         sets the links-window document in the same navigation flow, so this retries briefly instead
         of imposing a visible fixed delay where the cloned Bible pane is shown first.

         - Parameters:
           - linksWindow: Destination window returned by `prepareLinksWindow(using:)`.
           - wm: Window manager whose controller registry owns the destination controller.
           - attempt: Current retry count.
           - fallback: Source-pane work to run if the links controller never registers.
           - action: Work to run against the destination controller.
         - Side effects: Schedules short main-queue retries until the controller is available.
         - Failure modes: Runs `fallback` after the retry budget is exhausted.
         */
        func withLinksController(
            for linksWindow: Window,
            using wm: WindowManager,
            attempt: Int = 0,
            fallback: @escaping () -> Void,
            action: @escaping (BibleReaderController) -> Void
        ) {
            if let ctrl = wm.controllers[linksWindow.id] as? BibleReaderController {
                action(ctrl)
                return
            }

            guard attempt < 20 else {
                fallback()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withLinksController(
                    for: linksWindow,
                    using: wm,
                    attempt: attempt + 1,
                    fallback: fallback,
                    action: action
                )
            }
        }

        // Links window support: single OSIS references open in a links window
        ctrl.onOpenInLinksWindow = { [weak ctrl, weak windowManager] book, chapter in
            guard let ctrl else { return }
            let useLinksWindow = store.getBool(.openLinksInSpecialWindowPref)
            guard useLinksWindow else {
                ctrl.navigateTo(book: book, chapter: chapter)
                return
            }

            guard let wm = windowManager,
                  let linksWindow = prepareLinksWindow(using: wm) else { return }

            withLinksController(
                for: linksWindow,
                using: wm,
                fallback: { ctrl.navigateTo(book: book, chapter: chapter) }
            ) { targetController in
                targetController.navigateTo(book: book, chapter: chapter)
            }
        }

        ctrl.onOpenMultiReferenceDocumentInLinksWindow = { [weak ctrl, weak windowManager] documentJSON in
            guard let ctrl else { return }
            let useLinksWindow = store.getBool(.openLinksInSpecialWindowPref)
            guard useLinksWindow else {
                ctrl.loadMultiReferenceDocument(documentJSON)
                return
            }

            guard let wm = windowManager,
                  let linksWindow = prepareLinksWindow(using: wm) else { return }

            withLinksController(
                for: linksWindow,
                using: wm,
                fallback: { ctrl.loadMultiReferenceDocument(documentJSON) }
            ) { targetController in
                targetController.loadMultiReferenceDocument(documentJSON)
            }
        }

        ctrl.onOpenDefinitionDocumentInLinksWindow = {
            [weak ctrl, weak windowManager] documentJSON, renderedBook, renderedKey in
            guard let ctrl else { return }
            let useLinksWindow = store.getBool(.openLinksInSpecialWindowPref)
            guard useLinksWindow else {
                ctrl.loadDefinitionDocument(
                    documentJSON,
                    renderedBook: renderedBook,
                    renderedKey: renderedKey
                )
                return
            }

            guard let wm = windowManager,
                  let linksWindow = prepareLinksWindow(using: wm) else { return }

            withLinksController(
                for: linksWindow,
                using: wm,
                fallback: {
                    ctrl.loadDefinitionDocument(
                        documentJSON,
                        renderedBook: renderedBook,
                        renderedKey: renderedKey
                    )
                }
            ) { targetController in
                targetController.loadDefinitionDocument(
                    documentJSON,
                    renderedBook: renderedBook,
                    renderedKey: renderedKey
                )
            }
        }
    }

    /// Registers the pane controller and nudges SwiftUI to re-evaluate registry-backed UI.
    private func registerController(_ ctrl: BibleReaderController) {
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

    /**
     Resolves one Android reader-menu string with an English fallback.

     - Parameters:
       - key: Android string resource key mirrored into iOS localization files when available.
       - defaultValue: English fallback used when the key is not present locally.
     - Returns: Localized menu text for pane-scoped Android parity rows.
     - Side effects: none.
     - Failure modes: Missing localizations fall back to `defaultValue`.
     */
    private func localizedDrawerString(_ key: String, default defaultValue: String) -> String {
        let localized = Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        return localized == key ? defaultValue : localized
    }

    /// Floating action bar shown while the pane has an active text selection.
    private var selectionActionBar: some View {
        HStack(spacing: 20) {
            if controller?.canUseBibleReferenceActions == true {
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
            if controller?.canUseBibleReferenceActions == true {
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
