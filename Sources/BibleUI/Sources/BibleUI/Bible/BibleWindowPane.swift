// BibleWindowPane.swift -- Per-window Bible rendering pane

import SwiftUI
import SwiftData
import BibleView
import BibleCore
import SwordKit
import os.log

private let logger = Logger(subsystem: "org.andbible", category: "BibleWindowPane")

/**
 Applies a complete Android Bible-link reference inside a destination pane controller.

 `BibleWindowPane` uses this boundary for current-pane navigation, links-window navigation, and
 delayed-controller fallback. Keeping the source passage intact through this call prevents pane
 orchestration from reducing a `BookAndKey`-equivalent range to book/chapter coordinates.
 */
enum BibleWindowPaneReferenceRouter {
    /**
     Strictly maps and opens one source-owned Bible reference in `controller`.

     - Parameters:
       - reference: Complete source passage, source versification, and optional forced target
         document supplied by the emitting controller.
       - controller: Existing or newly registered destination pane controller.
     - Returns: `true` when the destination accepted and navigated the exact mapped passage.
     - Side effects: May switch the destination Bible document/category, persist pane state, record
       history, and emit reader content.
     - Failure modes: Returns `false` without navigation when the destination has no active Bible or
       strict source-to-target mapping fails.
     */
    @discardableResult
    static func navigate(
        _ reference: OsisRef,
        in controller: BibleReaderController
    ) -> Bool {
        controller.navigateToBibleLink(reference)
    }
}

/**
 Hosts one fully independent reading pane inside the multi-window reader.

 Each pane uses the `BibleBridge`, `BibleWebViewSession`, and `BibleReaderController` registered for
 its `Window`, while delegating sheet/alert/toast presentation back to `BibleReaderView` through
 callback closures. Keeping the controller, bridge, and actual WebView host scoped to the window—not
 transient SwiftUI appearances—lets minimized panes reattach instantly and lets multiple panes
 render different modules and references simultaneously.

 Data dependencies:
 - `window`, `displaySettings`, `nightMode`, `monochromeMode`, `disableTwoStepBookmarking`, and
   `hideWindowButtons` drive pane rendering and controller updates
 - `WindowManager` is required from the environment for controller registration, layout actions,
   active-window coordination, and window-menu actions
 - `modelContext` is required from the environment so the pane can construct stores and persist
   bookmark, history, and settings mutations initiated by the controller

 Side effects:
 - `onAppear` lazily creates or reuses the pane controller and its retained WebView session, then
   registers the controller with `WindowManager`
 - window removal or workspace switching unregisters controllers from `WindowManager`
 - `onChange` for `nightMode` and `displaySettings` pushes updated display state into the
   embedded web view via `BibleReaderController.updateDisplaySettings`
 */
struct BibleWindowPane: View {
    /// Window model that owns this pane's persisted position, layout, and history state.
    let window: BibleCore.Window

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

    /// Reader-session owner for Android's typed Copy/Open reference contract.
    let windowMenuReferenceStore: BibleWindowMenuReferenceStore

    /// First-appearance bridge/session pair adopted by a newly created pane controller.
    @State private var renderSeed = BibleWindowRenderSeed()

    /// Controller that owns module state, navigation, and bridge callbacks for this pane.
    @State private var controller: BibleReaderController?

    /// Whether the custom Android-style pane hamburger menu is visible.
    @State private var isWindowMenuPresented = false

    /// Whether Android's two-step bookmark popup is visible above the selection action bar.
    @State private var isSelectionBookmarkMenuPresented = false

  /// Native help content requested by this pane's bundled BibleView bridge.
  @State private var readerHelpPresentation: AIReaderHelpPresentation?

  /// Pane-scoped Android-compatible AI chooser, execution, and permission coordinator.
  @State private var aiRunCoordinator: AIReaderRunCoordinator?

    /// Shared workspace/window coordinator used for controller registration and layout actions.
    @Environment(WindowManager.self) private var windowManager

    /// Current platform color scheme used by custom Android-style popup surfaces.
    @Environment(\.colorScheme) private var colorScheme

    /// SwiftData context used to build stores and persist pane-driven mutations.
    @Environment(\.modelContext) private var modelContext

  /// Shared search index used by Android-compatible AI search tools.
  @Environment(SearchIndexService.self) private var searchIndexService

    /**
     Render session that should back the current SwiftUI representable pass.

     - Returns: The local controller session, the manager-registered controller session during
       restoration, or the initial seed before any controller exists.
     - Side Effects: None.
     - Failure Modes: None; the seed guarantees a session for the first render.
     */
    private var webViewSession: BibleWebViewSession {
        if let controller {
            return controller.webViewSession
        }
        if let registeredController = windowManager.controllers[window.id] as? BibleReaderController {
            return registeredController.webViewSession
        }
        return renderSeed.webViewSession
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

    /// Requests the parent reader to execute one Android recent text-setting action for this pane.
    var onEditWindowTextSetting: ((AndroidTextDisplaySettingType) -> Void)?

    /// Requests the canonical single-label Study Pad archive workflow.
    var onExportStudyPadArchive: ((UUID) -> Void)?

    /// Requests the canonical bookmark CSV workflow filtered to one Study Pad label.
    var onExportStudyPadCSV: ((UUID) -> Void)?

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

    /// Requests reader navigation for Android's full PromptEditActivity-equivalent screen.
    var onShowAIPromptEditor: ((UUID) -> Void)?

    /// Forwards shareable plain-text content to the parent share presenter.
    var onShareText: ((String) -> Void)?

    /// Forwards My Documents content with Android's separate native subject and body values.
    var onShareMyDocument: ((MyDocumentSharePayload) -> Void)?

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
            workspaceColor: window.workspace?.workspaceColor
                ?? windowManager.activeWorkspace?.workspaceColor,
            monochromeMode: monochromeMode
        )
    }

    /**
     Renders the cached WebView host with pane-owned overlays and lifecycle wiring.

     The `BibleWebView` receives the stable session resolved from the registered controller, so
     removing this pane from the split hierarchy detaches rather than destroys its Vue client.

     - Returns: One pane surface with selection, window-menu, help, and AI overlays.
     - Side Effects: Appearance creates/configures/registers the pane controller; display-setting
       changes emit updated configuration through that controller.
     - Failure Modes: Before controller registration, the render seed supplies the first host and
       is adopted by the controller during `onAppear`.
     */
    var body: some View {
        ZStack(alignment: .bottom) {
            BibleWebView(session: webViewSession, backgroundColorInt: activeBackgroundColorInt)
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
    .overlay {
      if let readerHelpPresentation {
        AIReaderHelpDialog(
          presentation: readerHelpPresentation,
          onDismiss: { self.readerHelpPresentation = nil }
        )
      }
    }
    .overlay {
      if let aiRunCoordinator {
        AIReaderCoordinatorHost(
          coordinator: aiRunCoordinator,
          surfacePalette: surfacePalette,
          onPresentPromptEditor: { promptID in onShowAIPromptEditor?(promptID) }
        )
      }
    }
        .androidAnchoredPopupMenu(
            anchorID: "selectionBookmarkMenuAnchor",
            isPresented: $isSelectionBookmarkMenuPresented,
            menuWidth: 220,
            estimatedMenuHeight: 92,
            accessibilityIdentifier: "selectionBookmarkMenu"
        ) {
            selectionBookmarkPopup
        }
        .onAppear {
            if controller == nil {
                initializeController()
            } else {
                let workspaceStore = WorkspaceStore(modelContext: modelContext)
                let settingsStore = SettingsStore(modelContext: modelContext)
        configureController(
          controller!, workspaceStore: workspaceStore, settingsStore: settingsStore)
        configureAICoordinator(for: controller!)
                registerController(controller!)
            }
        }
        .onChange(of: nightMode) { _, newValue in
            controller?.updateDisplaySettings(displaySettings, nightMode: newValue)
        }
        .onChange(of: displaySettings) { _, newValue in
            controller?.updateDisplaySettings(newValue, nightMode: nightMode)
        }
        .onChange(of: controller?.hasActiveSelection == true) { _, hasSelection in
            if !hasSelection {
                isSelectionBookmarkMenuPresented = false
            }
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
        windowManager.activateWindow(window)
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
                    surfacePalette: surfacePalette,
                    maximumHeight: maximumHeight
                ) { action in
                    withAnimation(.easeOut(duration: 0.12)) {
                        isWindowMenuPresented = false
                    }
                    performWindowMenuAction(action)
                }
                .frame(width: width, alignment: .topLeading)
                .padding(.top, 42)
                .padding(.trailing, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
    }

    private var windowMenuSnapshot: BibleWindowPaneMenuSnapshot {
        BibleWindowPaneMenuSnapshotFactory.snapshot(
            for: window,
            windowManager: windowManager,
            displaySettings: displaySettings,
            isAIConfigured: isAIConfigured,
            referenceStore: windowMenuReferenceStore,
            recentTextSettings: AndroidTextDisplayRecentSettings.displayedTypes(
                settingsStore: SettingsStore(modelContext: modelContext)
            )
        )
    }

    private func performWindowMenuAction(_ action: BibleWindowPaneMenuAction) {
        BibleWindowPaneMenuActionHandler(
            windowManager: windowManager,
            window: window,
            onEditTextSetting: onEditWindowTextSetting,
            onShowWindowTextOptions: onShowWindowTextOptions,
            onCopyWindowSettingsToWindow: onCopyWindowSettingsToWindow,
            onCopyWindowSettingsToWorkspace: onCopyWindowSettingsToWorkspace,
            onCopyWindowSettingsToGlobal: onCopyWindowSettingsToGlobal,
            onAddWholePageBookmark: {
                _ = resolvedWindowMenuController?.createWindowMenuWholePageBookmark()
            },
            onExportHTML: {
                resolvedWindowMenuController?.requestWindowMenuHTMLExport()
            },
            onExportStudyPad: {
                guard let labelID = resolvedWindowMenuController?.windowMenuStudyPadLabelID else {
                    return
                }
                onExportStudyPadArchive?(labelID)
            },
            onExportStudyPadCSV: {
                guard let labelID = resolvedWindowMenuController?.windowMenuStudyPadLabelID else {
                    return
                }
                onExportStudyPadCSV?(labelID)
            },
            onOpenAIActions: presentWindowAIActions,
            onCopyLink: copyReference,
            onOpenCopiedReference: openCopiedReference,
            onOpenSpeakReference: openSpeakReference
        ).perform(action)
    }

    /// Controller currently registered for this immutable pane target.
    private var resolvedWindowMenuController: BibleReaderController? {
        controller ?? windowManager.controllers[window.id] as? BibleReaderController
    }

    /// Copies the pane's typed Android-compatible reference and URL.
    private func copyReference() {
        guard let reference = resolvedWindowMenuController?.windowMenuReference() else { return }
        windowMenuReferenceStore.copy(reference, onShowToast: onShowToast)
    }

    /// Opens Android's last typed Copy-reference destination in this exact pane.
    private func openCopiedReference() {
        guard let reference = windowMenuReferenceStore.reference else { return }
        navigateToWindowMenuReference(reference)
    }

    /// Opens the current source-owned speech position in this exact pane.
    private func openSpeakReference() {
        guard speakService.isSpeaking,
              let position = speakService.currentPosition,
              let reference = BibleWindowMenuReference.speechPosition(position) else {
            return
        }
        navigateToWindowMenuReference(reference)
    }

    /** Applies one typed popup reference and keeps failures visible instead of silently retargeting. */
    private func navigateToWindowMenuReference(_ reference: BibleWindowMenuReference) {
        guard let controller = resolvedWindowMenuController else {
            onShowToast?(
                String(localized: "error_occurred", defaultValue: "An error has occurred")
            )
            return
        }
        do {
            try controller.navigateToWindowMenuReference(reference)
        } catch {
            onShowToast?(
                error.localizedDescription.isEmpty
                    ? String(localized: "error_occurred", defaultValue: "An error has occurred")
                    : error.localizedDescription
            )
        }
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
            controller = existingController
            configureController(existingController, workspaceStore: workspaceStore, settingsStore: store)
      configureAICoordinator(for: existingController)
            registerController(existingController)
            return
        }

        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        let sharedControllers = windowManager.controllers.values
            .compactMap { $0 as? BibleReaderController }
        let ctrl = BibleReaderController(
            bridge: renderSeed.bridge,
            webViewSession: renderSeed.webViewSession,
            bookmarkService: bookmarkService,
            initializesSword: sharedControllers.isEmpty
        )
        configureController(ctrl, workspaceStore: workspaceStore, settingsStore: store)

        if !sharedControllers.isEmpty {
            let didCopyModuleState = sharedControllers.contains { ctrl.copyModuleState(from: $0) }
            if !didCopyModuleState {
        logger.warning(
          "Unable to copy SWORD state from registered controllers; initializing pane controller independently"
        )
                ctrl.initializeSwordIfNeeded()
            }
        }

    configureAICoordinator(for: ctrl)

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
        ctrl.onShareMyDocumentContent = { payload in onShareMyDocument?(payload) }
    ctrl.onDeleteActiveMyDocumentPage = { [weak windowManager] in
      guard let windowManager else { return .showBible }
      return MyDocumentPageDeletionWindowLifecycle.resolve(
        window: window,
        windowManager: windowManager
      )
    }
        ctrl.onRequestOpenDownloads = { initialSearchText in onShowDownloads?(initialSearchText) }
        ctrl.onShowStrongsSearch = { strongsNum in onSearchForStrongs?(strongsNum) }
        ctrl.onShowReadingProgress = { tab in onShowReadingProgress?(tab) }
        ctrl.onShowReadingProgressSettings = { onShowReadingProgressSettings?() }
        ctrl.onShowChapterReadHistory = { target in onShowChapterReadHistory?(target) }
        ctrl.onAssignLabels = { bookmarkId in
            logger.info("onAssignLabels triggered: bookmarkId=\(bookmarkId)")
            onAssignLabels?(bookmarkId)
        }
        ctrl.onPersistState = { try? modelContext.save() }
        ctrl.onShowToast = { text in onShowToast?(text) }
    ctrl.onShowReaderHelp = { presentation in
      readerHelpPresentation = presentation
    }
        // The reader owns all system-share presentation so the handoff stays bound to the
        // active reader scene rather than whichever UIWindowScene happens to be first.
        ctrl.onShareHtml = { html in onShareText?(html) }

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
                wm.activateWindow(window)
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
        func prepareLinksWindow(using wm: WindowManager) -> BibleCore.Window? {
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
            for linksWindow: BibleCore.Window,
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

    // Links window support: single contiguous OSIS passages open in a links window.
    ctrl.onOpenInLinksWindow = { [weak ctrl, weak windowManager] reference in
      guard let ctrl else { return }
      let useLinksWindow = store.getBool(.openLinksInSpecialWindowPref)
      guard useLinksWindow else {
        BibleWindowPaneReferenceRouter.navigate(reference, in: ctrl)
        return
      }

      guard let wm = windowManager,
        let linksWindow = prepareLinksWindow(using: wm)
      else { return }

      withLinksController(
        for: linksWindow,
        using: wm,
        fallback: {
          BibleWindowPaneReferenceRouter.navigate(reference, in: ctrl)
        }
      ) { targetController in
        BibleWindowPaneReferenceRouter.navigate(reference, in: targetController)
      }
    }

    ctrl.onOpenAIDocumentPageInLinksWindow = { [weak ctrl, weak windowManager] request in
            guard let ctrl else { return }
            let useLinksWindow = store.getBool(.openLinksInSpecialWindowPref)
            guard useLinksWindow else {
        ctrl.loadMyDocumentPage(
          bookInitials: request.documentInitials,
          pageKey: request.pageKey
        )
                return
            }

            guard let wm = windowManager,
        let linksWindow = prepareLinksWindow(using: wm)
      else { return }

            withLinksController(
                for: linksWindow,
                using: wm,
        fallback: {
          ctrl.loadMyDocumentPage(
            bookInitials: request.documentInitials,
            pageKey: request.pageKey
          )
        }
            ) { targetController in
        targetController.loadMyDocumentPage(
          bookInitials: request.documentInitials,
          pageKey: request.pageKey
        )
            }
        }

    ctrl.onOpenMultiReferenceDocumentInLinksWindow = {
      [weak ctrl, weak windowManager] documentJSON in
            guard let ctrl else { return }
            let useLinksWindow = store.getBool(.openLinksInSpecialWindowPref)
            guard useLinksWindow else {
                ctrl.loadMultiReferenceDocument(documentJSON)
                return
            }

            guard let wm = windowManager,
        let linksWindow = prepareLinksWindow(using: wm)
      else { return }

            withLinksController(
                for: linksWindow,
                using: wm,
                fallback: { ctrl.loadMultiReferenceDocument(documentJSON) }
            ) { targetController in
                targetController.loadMultiReferenceDocument(documentJSON)
            }
        }

        ctrl.onOpenMemorizeDocumentInLinksWindow = { [weak ctrl, weak windowManager] emission in
            guard let ctrl else { return }
            let useLinksWindow = store.getBool(.openLinksInSpecialWindowPref)
            guard useLinksWindow else {
                ctrl.renderMemorizeDocument(emission)
                return
            }

            guard let wm = windowManager,
        let linksWindow = prepareLinksWindow(using: wm)
      else { return }

            withLinksController(
                for: linksWindow,
                using: wm,
                fallback: { ctrl.renderMemorizeDocument(emission) }
            ) { targetController in
                targetController.renderMemorizeDocument(emission)
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
        let linksWindow = prepareLinksWindow(using: wm)
      else { return }

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

  /** Whether Android's AI action rows should be visible for this installation. */
  private var isAIConfigured: Bool {
    guard let providers = try? AISettingsStore(modelContext: modelContext).providers() else {
      return false
    }
    return !providers.isEmpty
  }

  /**
   Builds the pane-scoped AI domain and wires every reader and menu entry point.

   - Parameter ctrl: Live controller whose SWORD registry and persistence services are ready.
   - Side effects: Creates one coordinator, discovers Android SQLite documents, and installs
     bridge/menu callbacks. No provider request occurs.
   - Failure modes: Returns without wiring until SWORD, bookmark, and My Documents services are
     available; the next controller configuration retries.
   */
  private func configureAICoordinator(for ctrl: BibleReaderController) {
    let aiSettingsStore = AISettingsStore(modelContext: modelContext)
    ctrl.isAIProviderConfigured = {
      guard let providers = try? aiSettingsStore.providers() else { return false }
      return !providers.isEmpty
    }
    if let aiRunCoordinator {
      wireAIEntryPoints(ctrl, coordinator: aiRunCoordinator)
      return
    }
    guard let swordManager = ctrl.swordManager,
      let bookmarkService = ctrl.bookmarkService,
      let myDocumentStore = ctrl.myDocumentStore
    else {
      return
    }

    let sqliteLibrary = SQLiteDocumentModuleLibrary(
      moduleRootURL: URL(fileURLWithPath: swordManager.modulePath, isDirectory: true)
    )
    let appSettingsStore = SettingsStore(modelContext: modelContext)
    let documentAccessPolicy = BibleUIAgentSettingsDocumentAccessPolicy(
      settingsStore: aiSettingsStore
    )
    let windowRouter = AIReaderWindowDocumentRouter(
      windowManager: windowManager,
      myDocumentStore: myDocumentStore
    )
    let domain = BibleUIAgentDomainAdapter(
      swordManager: swordManager,
      sqliteLibrary: sqliteLibrary,
      searchIndexService: searchIndexService,
      bookmarkService: bookmarkService,
      labelConfigurationService: WorkspaceLabelConfigurationService(modelContext: modelContext),
      myDocumentLibraryStore: MyDocumentLibraryStore(modelContext: modelContext),
      myDocumentStore: myDocumentStore,
      windowManager: windowManager,
      documentAccessPolicy: documentAccessPolicy,
      windowDocumentRouter: windowRouter
    )
    let textBacking = BibleUIAITextTargetBacking(
      bookmarkService: bookmarkService,
      myDocumentStore: myDocumentStore
    )
    let coordinator = AIReaderRunCoordinator(
      modelContext: modelContext,
      swordManager: swordManager,
      domain: domain,
      myDocumentStore: myDocumentStore,
      textTargetBacking: textBacking,
      referenceEnvironmentProvider: {
        AIReaderReferenceEnvironmentResolver.resolve(
          swordManager: swordManager,
          sqliteLibrary: sqliteLibrary,
          searchIndexService: searchIndexService,
          settingsStore: appSettingsStore,
          aiSettingsStore: aiSettingsStore
        )
      },
      isInstalledBible: { initials in
        if let module = swordManager.module(named: initials) {
          return module.info.category == .bible
        }
        return sqliteLibrary.module(named: initials)?.info.category == .bible
      },
      openMyDocument: { [weak ctrl] initials, pageKey in
        _ = ctrl?.loadMyDocumentPage(bookInitials: initials, pageKey: pageKey)
      },
      openStudyPad: { [weak ctrl] labelID, entryID in
        ctrl?.loadStudyPadDocument(labelId: labelID, bookmarkId: entryID)
      },
      showTransientDocument: { [weak ctrl] document in
        ctrl?.loadTransientAIDocument(document)
      },
      showToast: { text in
        onShowToast?(text)
      }
    )
    aiRunCoordinator = coordinator
    wireAIEntryPoints(ctrl, coordinator: coordinator)
  }

  /** Installs exact bridge, generated-page, prompt-editor, and workspace callbacks. */
  private func wireAIEntryPoints(
    _ ctrl: BibleReaderController,
    coordinator: AIReaderRunCoordinator
  ) {
    ctrl.onRequestAIAction = { [weak ctrl, weak coordinator] request in
      guard let ctrl, let coordinator else { return }
      let isBible = request.osisRef == nil
      let sourceBounds = isBible
        ? AIReaderSourceRange.bibleBounds(
          start: request.startOrdinal,
          end: request.endOrdinal
        )
        : AIReaderSourceRange.genericBounds(
          start: request.startOrdinal,
          end: request.endOrdinal
        )
      guard let sourceBounds else {
        onShowToast?(
          String(
            localized: "error_no_content",
            defaultValue: "No content is available for this selection."))
        return
      }
      let verifiedRange =
        isBible
        ? ctrl.aiVerifiedKJVARange(
          bookInitials: request.bookInitials,
          startOrdinal: request.startOrdinal,
          endOrdinal: request.endOrdinal
        )
        : nil
      let sourceContext: AIReaderSourceContext?
      if isBible {
        sourceContext = ctrl.aiSourceContext(
          expectedDocumentInitials: request.bookInitials,
          selectionOrdinalStart: sourceBounds.start,
          selectionOrdinalEnd: sourceBounds.end
        )
      } else {
        sourceContext = ctrl.aiSourceContext(
          expectedDocumentInitials: request.bookInitials,
          requestedSourceKey: request.osisRef
        )
      }
      guard let sourceContext else {
        onShowToast?(
          String(
            localized: "error_no_content",
            defaultValue: "No content is available for this selection."))
        return
      }
      let pane = aiPaneSnapshot(
        controller: ctrl,
        sourceContext: sourceContext,
        verifiedKJVARange: verifiedRange
      )
      guard
        let action = AIReaderBridgeActionResolver.selection(
          request,
          pane: pane,
          verifiedKJVARange: verifiedRange
        )
      else {
        onShowToast?(
          String(
            localized: "error_no_content",
            defaultValue: "No content is available for this selection."))
        return
      }
      coordinator.presentActions(for: action)
    }
    ctrl.onRequestNoteEditorAIAction = { [weak ctrl, weak coordinator] request in
      guard let ctrl, let coordinator else { return }
      presentNoteEditorAIActions(request, controller: ctrl, coordinator: coordinator)
    }
    ctrl.onRegenerateMyDocumentPage = { [weak coordinator] context in
      coordinator?.presentRegeneration(
        context,
        workspaceID: windowManager.activeWorkspace?.id,
        windowID: window.id
      )
    }
    ctrl.onChooseAIDocumentPage = { [weak coordinator] markers in
      coordinator?.presentDocumentMarkers(markers)
    }
    ctrl.onOpenAIPromptEditor = { [weak coordinator] promptID in
      coordinator?.presentPromptEditor(promptID)
    }
    ctrl.onRequestWorkspaceAIAction = { [weak coordinator] in
      guard let coordinator else { return }
      coordinator.presentActions(for: workspaceAIActionRequest())
    }
    ctrl.onRequestWindowAIAction = { [weak ctrl, weak coordinator] in
      guard let ctrl, let coordinator, let sourceContext = ctrl.aiSourceContext() else {
        return
      }
      let pane = aiPaneSnapshot(controller: ctrl, sourceContext: sourceContext)
      guard let action = AIReaderBridgeActionResolver.window(pane) else { return }
      coordinator.presentActions(for: action)
    }
  }

  /** Resolves an editor bridge request to an existing typed writeback target. */
  private func presentNoteEditorAIActions(
    _ request: AINoteEditorActionRequest,
    controller ctrl: BibleReaderController,
    coordinator: AIReaderRunCoordinator
  ) {
    guard let id = UUID(uuidString: request.entityId),
      let entityType = NoteEditorEntityType(rawValue: request.entityType)
    else {
      onShowToast?(String(localized: "error_occurred", defaultValue: "An error has occurred."))
      return
    }

    let target: AITextTarget
    var bibleContext: AIReaderBibleBookmarkContext?
    switch entityType {
    case .bookmarkNote:
      guard let bookmarkService = ctrl.bookmarkService else { return }
      if let bookmark = bookmarkService.bibleBookmark(id: id) {
        guard let sourceContext = ctrl.aiBibleSourceContext(
          bookInitials: bookmark.bookInitials,
          startOrdinal: bookmark.ordinalStart,
          endOrdinal: bookmark.ordinalEnd
        ), let sourceRange = sourceContext.sourceOrdinalRange,
          let sourceOSISRange = sourceContext.sourceOSISRange
        else {
          return
        }
        let kjvaRange = AIReaderSourceRange.bibleBounds(
          start: bookmark.kjvOrdinalStart,
          end: bookmark.kjvOrdinalEnd
        )?.closedRange
        target = .bibleBookmarkNote(id)
        bibleContext = AIReaderBibleBookmarkContext(
          bookInitials: sourceContext.sourceDocumentInitials,
          sourceBookKey: sourceContext.sourceBookKey,
          sourceOSISRange: sourceOSISRange,
          sourceOrdinalRange: sourceRange,
          kjvaOrdinalRange: kjvaRange,
          selectedContent: sourceContext.selectedContent,
          selectedText: sourceContext.selectedText
        )
      } else if bookmarkService.genericBookmark(id: id) != nil {
        target = .genericBookmarkNote(id)
      } else {
        return
      }
    case .studyPadText:
      guard let bookmarkService = ctrl.bookmarkService else { return }
      guard bookmarkService.studyPadEntry(id: id) != nil else { return }
      target = .studyPadText(id)
    case .myDocumentPage:
      guard let myDocumentStore = ctrl.myDocumentStore else { return }
      guard myDocumentStore.page(pageId: id) != nil else { return }
      target = .myDocumentPage(id)
    }

    let pane = aiPaneSnapshot(controller: ctrl, sourceContext: nil)
    guard
      let action = AIReaderBridgeActionResolver.noteEditor(
        request,
        target: target,
        pane: pane,
        bibleBookmark: bibleContext
      )
    else {
      return
    }
    coordinator.presentActions(for: action)
  }

  /** Presents Android's whole-window AI context from the pane's exact current document/key. */
  private func presentWindowAIActions() {
    guard let controller, let aiRunCoordinator else { return }
    guard let sourceContext = controller.aiSourceContext() else {
      onShowToast?(
        String(
          localized: "error_no_content", defaultValue: "No content is available for this selection."
        ))
      return
    }
    let pane = aiPaneSnapshot(controller: controller, sourceContext: sourceContext)
    guard let action = AIReaderBridgeActionResolver.window(pane) else { return }
    aiRunCoordinator.presentActions(for: action)
  }

  /** Captures immutable pane identity without allowing later focus changes to retarget a run. */
  private func aiPaneSnapshot(
    controller ctrl: BibleReaderController,
    sourceContext: AIReaderSourceContext?,
    verifiedKJVARange: ClosedRange<Int>? = nil
  ) -> AIReaderPaneSnapshot {
    let sourceOrdinalRange = sourceContext?.sourceOrdinalRange
    let sourceCategory: DocumentCategory? = sourceContext.map { context in
      context.sourceOrdinalRange == nil ? ctrl.currentCategory : .bible
    }
    let resolvedKJVARange: ClosedRange<Int>? =
      verifiedKJVARange
      ?? {
        guard sourceCategory == .bible,
          let sourceOrdinalRange,
          let initials = sourceContext?.sourceDocumentInitials
        else {
          return nil
        }
        return ctrl.aiVerifiedKJVARange(
          bookInitials: initials,
          startOrdinal: sourceOrdinalRange.lowerBound,
          endOrdinal: sourceOrdinalRange.upperBound
        )
      }()
    return AIReaderPaneSnapshot(
      workspaceID: windowManager.activeWorkspace?.id,
      windowID: window.id,
      documentCategory: sourceCategory,
      activeDocumentInitials: sourceContext?.sourceDocumentInitials,
      sourceBookKey: sourceContext?.sourceBookKey,
      sourceOSISRange: sourceContext?.sourceOSISRange,
      selectedContent: sourceContext?.selectedContent,
      selectedText: sourceContext?.selectedText,
      sourceOrdinalRange: sourceOrdinalRange,
      kjvaOrdinalRange: resolvedKJVARange
    )
  }

  /** Builds Android's visible/minimised workspace summary for workspace-level prompts. */
  private func workspaceAIActionRequest() -> AIReaderActionRequest {
    let workspace = windowManager.activeWorkspace
    let windows = windowManager.allWindows.filter { $0.layoutState != "closed" }
    let visible = windows.filter { $0.layoutState != "minimized" }
    let minimised = windows.filter { $0.layoutState == "minimized" }
    var summary = "Workspace: \(workspace?.name ?? "")\n"
    summary +=
      "Windows: \(windows.count) total (\(visible.count) visible, \(minimised.count) minimised)\n\n"

    func append(_ candidates: [BibleCore.Window], title: String) {
      guard !candidates.isEmpty else { return }
      summary += "\(title):\n"
      for candidate in candidates {
        let candidateController = windowManager.controllers[candidate.id] as? BibleReaderController
        let initials =
          BibleWindowPaneMenuSnapshotFactory.documentAbbreviation(
            for: candidate,
            controller: candidateController
          ) ?? "unknown"
        let name =
          candidateController.flatMap {
            $0.installedModules(for: $0.currentCategory)
              .first(where: { $0.name == initials })?.description
          } ?? "unknown"
        summary += "- \(initials) (\(name))"
        if let key = BibleWindowPaneMenuSnapshotFactory.referenceName(
          for: candidate,
          controller: candidateController
        ) {
          summary += " at \(key)"
        }
        if candidate.id == windowManager.activeWindow?.id {
          summary += " [ACTIVE]"
        }
        summary += "\n"
      }
    }
    append(visible, title: "Visible windows")
    if !visible.isEmpty, !minimised.isEmpty { summary += "\n" }
    append(minimised, title: "Minimised windows")
    return AIReaderBridgeActionResolver.workspace(
      workspaceID: workspace?.id,
      activeWindowID: windowManager.activeWindow?.id,
      summary: summary
    )
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
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "readerSelectionActionBar",
            backgroundColor: surfacePalette.toolbarBackgroundColor,
            primaryTextColor: surfacePalette.toolbarForegroundColor,
            secondaryTextColor: surfacePalette.toolbarSecondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            HStack(spacing: 20) {
            if controller?.canUseBibleReferenceActions == true {
                if disableTwoStepBookmarking {
          Button {
            controller?.bookmarkSelection(wholeVerse: false)
          } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "bookmark")
              Text(
                String(
                                localized: "add_bookmark3",
                                defaultValue: "Selection"
                )
              )
                            .font(.caption2)
                        }
                    }
          Button {
            controller?.bookmarkSelection(wholeVerse: true)
          } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "bookmark.fill")
              Text(
                String(
                                localized: "add_bookmark_whole_verse1",
                                defaultValue: "Verses"
                )
              )
                            .font(.caption2)
                        }
                    }
                } else {
                    Button {
                        isSelectionBookmarkMenuPresented.toggle()
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "bookmark")
                            Text(String(localized: "bookmark")).font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .androidPopupMenuAnchor(id: "selectionBookmarkMenuAnchor")
                    .accessibilityIdentifier("selectionBookmarkMenuButton")
                }
            } else {
        Button {
          controller?.bookmarkSelection(wholeVerse: true)
        } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "bookmark")
                        Text(String(localized: "bookmark")).font(.caption2)
                    }
                }
            }
      Button {
        controller?.copySelection()
      } label: {
                VStack(spacing: 2) {
                    Image(systemName: "doc.on.doc")
                    Text(String(localized: "copy")).font(.caption2)
                }
            }
            if controller?.canUseBibleReferenceActions == true {
        Button {
          controller?.shareSelection()
        } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "square.and.arrow.up")
                        Text(String(localized: "share")).font(.caption2)
                    }
                }
        Button {
          controller?.compareSelection()
        } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "text.justify.left")
                        Text(String(localized: "compare")).font(.caption2)
                    }
                }
            }
      Button {
        controller?.speakSelection()
      } label: {
                VStack(spacing: 2) {
                    Image(systemName: "speaker.wave.2")
                    Text(String(localized: "speak")).font(.caption2)
                }
            }
      Button {
        controller?.webSearchSelection()
      } label: {
                VStack(spacing: 2) {
                    Image(systemName: "magnifyingglass")
                    Text(String(localized: "search_web")).font(.caption2)
                }
            }
            if controller?.hasWordLookupDictionaries == true {
        Button {
          controller?.lookupSelectionInDictionaries()
        } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "book.closed")
                        Text(String(localized: "dictionary")).font(.caption2)
                    }
                }
            }
            }
            .font(.body)
            .foregroundStyle(surfacePalette.toolbarForegroundColor)
            .tint(surfacePalette.toolbarForegroundColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .padding(.bottom, 8)
    }

    /**
     Builds Android's two-row bookmark popup using the shared application menu surface.

     Android exposes Selection and Verses from one contextual action when two-step bookmarking is
     enabled. Each row dismisses the popup before forwarding the exact whole-verse flag to the pane
     controller; an absent controller leaves the menu safely dismissed without persistence.

     - Returns: A reader-palette-owned popup containing Android's two bookmark commands.
     - Side effects: Dismisses popup state and may create a bookmark through the pane controller.
     - Failure modes: Missing controller makes the selected command a no-op.
     */
    private var selectionBookmarkPopup: some View {
        AndroidPopupMenuSurface(
            colorScheme: colorScheme,
            accessibilityIdentifier: "selectionBookmarkMenuSurface",
            backgroundColor: surfacePalette.backgroundColor,
            primaryTextColor: surfacePalette.foregroundColor,
            secondaryTextColor: surfacePalette.secondaryForegroundColor,
            accentColor: surfacePalette.controlAccentColor
        ) {
            AndroidPopupMenuRow(
                title: String(localized: "add_bookmark3", defaultValue: "Selection"),
                accessibilityIdentifier: "selectionBookmarkSelectionAction"
            ) {
                isSelectionBookmarkMenuPresented = false
                controller?.bookmarkSelection(wholeVerse: false)
            }
            Divider().overlay(surfacePalette.inactiveBorderColor)
            AndroidPopupMenuRow(
                title: String(
                    localized: "add_bookmark_whole_verse1",
                    defaultValue: "Verses"
                ),
                accessibilityIdentifier: "selectionBookmarkWholeVerseAction"
            ) {
                isSelectionBookmarkMenuPresented = false
                controller?.bookmarkSelection(wholeVerse: true)
            }
        }
    }
}
