// BibleReaderView.swift — Main Bible reading screen (coordinator)
//
// This view coordinates the toolbar, sheets, and overlays for multi-window
// Bible reading. Each window's WebView is rendered by a BibleWindowPane.

import SwiftUI
import SwiftData
import BibleView
import BibleCore
import SwordKit
#if os(iOS)
import StoreKit
#endif

/// Captures the reader overflow trigger bounds so the popup can anchor to the real button.
private struct ReaderOverflowButtonBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Captures the reader root's live scene size and safe-area insets.
private struct ReaderSceneMetrics: Equatable {
    var size: CGSize = .zero
    var safeAreaInsets: EdgeInsets = .init()
}

/// Feeds root scene metrics back into the reader so iPad windowed layouts can adapt.
private struct ReaderSceneMetricsPreferenceKey: PreferenceKey {
    static var defaultValue = ReaderSceneMetrics()

    static func reduce(value: inout ReaderSceneMetrics, nextValue: () -> ReaderSceneMetrics) {
        value = nextValue()
    }
}

/// Pure layout heuristic for reserving space for iPadOS floating window controls.
struct ReaderWindowControlsAvoidanceMetrics {
    static let minimumTopClearance: CGFloat = 34
    static let minimumLeadingClearance: CGFloat = 56

    static func documentHeaderInsets(
        isPad: Bool,
        sceneSize: CGSize,
        screenWidth: CGFloat,
        safeAreaInsets: EdgeInsets
    ) -> EdgeInsets {
        guard isPad else {
            return .init()
        }
        guard sceneSize.width > 0, screenWidth > 0 else {
            return .init()
        }
        guard sceneSize.width < (screenWidth - 1) else {
            return .init()
        }

        return EdgeInsets(
            top: max(0, minimumTopClearance - safeAreaInsets.top),
            leading: max(0, minimumLeadingClearance - safeAreaInsets.leading),
            bottom: 0,
            trailing: 0
        )
    }
}

/**
 Coordinates the primary reading experience, including panes, toolbars, sheets, and overlays.

 `BibleReaderView` is the top-level SwiftUI coordinator for the reading screen. It resolves the
 focused pane from `WindowManager`, owns sheet presentation state for cross-cutting features, and
 pushes workspace-level display and behavior preferences into each `BibleWindowPane`.

 Data dependencies:
 - `WindowManager` from the environment provides pane layout, active-window focus, controller
   registration, workspace settings, and synchronization callbacks
 - `SearchIndexService` from the environment is passed into search flows
 - `modelContext` from the environment persists workspace, settings, and toolbar-toggle changes
 - `colorScheme` from the environment participates in effective night-mode resolution

 Side effects:
 - `onAppear` loads persisted preferences, wires TTS callbacks, restores speech settings, and
   registers synchronized-scrolling callbacks on `WindowManager`
 - iOS `onAppear` and `onDisappear` start and stop tilt-to-scroll based on workspace settings
 - sheet dismissals reload behavior preferences or refresh installed-module lists where needed
 - toolbar toggles and helper actions mutate SwiftData-backed workspace/settings state and push
   display updates into active pane controllers
 */
public struct BibleReaderView: View {
    /// Top-level sheets launched from the reader shell or its global shortcuts.
    enum ReaderSheet: String, Identifiable {
        case bookmarks
        case downloads
        case history
        case readingPlans
        case readingProgress
        case readingProgressSettings
        case chapterReadHistory
        case workspaces
        case about

        var id: String { rawValue }
    }

    /// Reader-stack destinations opened from global reader actions.
    enum ReaderDestination: String, Identifiable, Hashable {
        case settings
        case globalTextOptions
        case workspaceTextOptions = "textOptions"
        case windowTextOptions

        var id: String { rawValue }
    }

    /// Coordinator-owned modal flows that do not require payload-backed sheet state.
    private enum ReaderModal: String, Identifiable {
        case syncSettings
        case importExport
        case speakControls
        case modulePicker
        case dictionaryBrowser
        case generalBookBrowser
        case mapBrowser
        case epubLibrary
        case epubBrowser
        case epubSearch
        case labelManager
        case studyPadSelector
        case chooseDocument
        case help

        var id: String { rawValue }

        var shouldCapturePanePresentationTarget: Bool {
            switch self {
            case .syncSettings, .importExport, .help:
                return false
            default:
                return true
            }
        }
    }

    /// Internal reader-overflow destinations that should run only after the overflow sheet dismisses.
    private enum ReaderOverflowPresentation {
        case labelManager
        case bookmarks
        case history
        case readingPlans
        case settings
        case textOptions
        case workspaces
        case downloads
        case epubLibrary
        case epubBrowser
        case epubSearch
        case help
        case about
    }

    /// Shared workspace/window coordinator that owns panes, focus, and controller registration.
    @Environment(WindowManager.self) private var windowManager

    /// Search index service passed through to `SearchView` for FTS index inspection and creation.
    @Environment(SearchIndexService.self) private var searchIndexService

    /// SwiftData context used to persist workspace settings and display-configuration changes.
    @Environment(\.modelContext) private var modelContext

    /// System color scheme used to resolve automatic night-mode behavior.
    @Environment(\.colorScheme) private var colorScheme

    /// Horizontal size class used to collapse toolbar actions on narrow iPhone layouts.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Presents the book/chapter/verse chooser flow for the focused controller.
    @State private var showBookChooser = false

    /// Snapshot-backed chooser progress context captured when the chooser is presented.
    @State private var passageChooserProgressContext = PassageChooserProgressContext.empty

    /// Presents the full-text search sheet for the focused module.
    @State private var showSearch = false

    /// Presents the current top-level reader sheet driven by the overflow menu and shortcuts.
    @State private var activeReaderSheet: ReaderSheet?

    /// Presents the current reader-stack destination driven by drawer and overflow actions.
    @State private var activeReaderDestination: ReaderDestination?

    /// Initial search applied when Downloads is opened from an Android-compatible download link.
    @State private var downloadsInitialSearchText = ""

    /// Default-document mode applied to the next Downloads sheet presentation.
    @State private var downloadsDefaultDownloadMode: ModuleBrowserDefaultDownloadMode = .disabled

    /// Tracks whether Android Easy Start default downloads are still refreshing or installing.
    @State private var startupDefaultDownloadsInFlight = false

    /// Whether the no-Bible startup prompt should be visible.
    @State private var showStartupDownloadPrompt = false

    /// Guards startup prompt evaluation so it does not reappear repeatedly in one session.
    @State private var didEvaluateStartupDownloadPrompt = false

    /// Initial tab requested by the Android-compatible reading-progress bridge.
    @State private var readingProgressInitialTab: ReadingProgressTab = .reading

    /// Chapter history target requested by the embedded reader bridge.
    @State private var chapterReadHistoryTarget: ChapterReadHistoryTarget?

    /// Presents the current coordinator-owned modal flow.
    @State private var activeReaderModal: ReaderModal?

    /// Presents the reader's overflow action sheet.
    @State private var showReaderOverflowMenu = false

    /// Presents Android's compact Bible-module quick selector anchored to the toolbar button.
    @State private var showBibleQuickModuleSelector = false

    /// Presents the Android-style left navigation drawer from the reader header.
    @State private var showReaderNavigationDrawer = false

    /// Presents the Android-style Strong's mode chooser launched from the overflow menu.
    @State private var showReaderStrongsModeDialog = false

    /// Queues one follow-up presentation until the reader overflow sheet finishes dismissing.
    @State private var pendingReaderOverflowPresentation: ReaderOverflowPresentation?

    /// Queues one side-effect-only reader overflow action until the sheet finishes dismissing.
    @State private var pendingReaderOverflowCallback: (() -> Void)?

    /// Last search-toolbar activation timestamp used to mirror Android button prioritization.
    @AppStorage("search-last-used") private var searchLastUsed = 0.0

    /// Last speak-toolbar activation timestamp used to mirror Android button prioritization.
    @AppStorage("speak-last-used") private var speakLastUsed = 0.0

    /// Text and color settings resolved for the currently active pane and toolbar state.
    @State private var displaySettings: TextDisplaySettings = .appDefaults

    /// App-level text-display defaults edited from the full Application Settings flow.
    @State private var globalDisplaySettings: TextDisplaySettings = .appDefaults

    /// Window-scoped text-display state edited from Android's pane/window All Text Options route.
    @State private var windowDisplaySettings: TextDisplaySettings = .appDefaults

    /// Workspace-scoped text-display state edited from Android's main reader All Text Options route.
    @State private var workspaceDisplaySettings: TextDisplaySettings = .appDefaults

    /// Effective night-mode value currently applied to pane controllers and overlays.
    @State private var nightMode = false

    /// Stored night-mode strategy (`system`, `manual`, or other Android-parity raw values).
    @State private var nightModeMode = AppPreferenceRegistry.stringDefault(for: .nightModePref3) ?? NightModeSetting.system.rawValue

    /// Shared text-to-speech service used by all panes and speak-related overlays.
    @StateObject private var speakService = SpeakService()

    /// Pending plain-text payload for the native share sheet.
    @State private var shareText: String?

    /// Pending cross-reference payload for modal presentation.
    @State private var crossReferences: [CrossReference]?

    /// Active module category that the picker should display.
    @State private var pickerCategory: DocumentCategory = .bible


    /// Transient toast text shown above the bottom edge of the reader.
    @State private var toastMessage: String?

    /// Pending dismissal work item for the transient toast overlay.
    @State private var toastWorkItem: DispatchWorkItem?

    /// Whether the reader is currently hiding its standard chrome in fullscreen mode.
    @State private var isFullScreen = false

    /// Latest root-scene metrics used to avoid iPadOS floating window controls.
    @State private var readerSceneMetrics = ReaderSceneMetrics()

    /// Android-parity preference controlling whether navigation drills down to verse selection.
    @State private var navigateToVersePref = AppPreferenceRegistry.boolDefault(for: .navigateToVersePref) ?? false

    /// Android-parity preference enabling automatic fullscreen while scrolling.
    @State private var autoFullscreenPref = AppPreferenceRegistry.boolDefault(for: .autoFullscreenPref) ?? false

    /// Android-parity preference switching bookmark actions between one-step and two-step flows.
    @State private var disableTwoStepBookmarkingPref =
        AppPreferenceRegistry.boolDefault(for: .disableTwoStepBookmarking) ?? false

    /// Stored Android-parity toolbar gesture mode for Bible/commentary buttons.
    @State private var toolbarButtonActionsMode =
        AppPreferenceRegistry.stringDefault(for: .toolbarButtonActions) ?? "default"

    /// Stored Android-parity horizontal swipe mode for the Bible view.
    @State private var bibleViewSwipeMode =
        AppPreferenceRegistry.stringDefault(for: .bibleViewSwipeMode) ?? "CHAPTER"

    /// Preference controlling whether the window tab bar hides in fullscreen.
    @State private var fullScreenHideButtonsPref =
        AppPreferenceRegistry.boolDefault(for: .fullScreenHideButtonsPref) ?? true

    /// Preference controlling whether each pane's hamburger button is hidden.
    @State private var hideWindowButtonsPref =
        AppPreferenceRegistry.boolDefault(for: .hideWindowButtons) ?? false

    /// Preference controlling whether the floating fullscreen reference capsule is hidden.
    @State private var hideBibleReferenceOverlayPref =
        AppPreferenceRegistry.boolDefault(for: .hideBibleReferenceOverlay) ?? false

    /// Suppresses the tap handler that SwiftUI fires after a completed Bible-button long press.
    @State private var suppressBibleTapAfterLongPress = false

    /// Suppresses the tap handler that SwiftUI fires after a completed commentary-button long press.
    @State private var suppressCommentaryTapAfterLongPress = false

    /// Tracks whether fullscreen was last entered by the double-tap gesture instead of scrolling.
    @State private var lastFullScreenByDoubleTap = false

    /// Accumulated user scroll state toward the auto-fullscreen threshold.
    @State private var autoFullscreenTracking = ReaderAutoFullscreenTracking()

    /// Initial query forwarded into `SearchView`, usually from Strong's lookups.
    @State private var searchInitialQuery = ""

    /// Window that owns the currently presented pane-scoped sheet or chooser flow.
    @State private var panePresentationTargetWindowId: UUID?

    /// Ensures the launch-seeded UI-test Search sheet is only auto-presented once per app session.
    @State private var didPresentUITestLaunchSearch = false

    /// Presents the reference chooser used by bridge-driven dialogs.
    @State private var showRefChooser = false

    /// Completion callback for the bridge-driven reference chooser flow.
    @State private var refChooserCompletion: ((String?) -> Void)?
    #if os(iOS)
    /// Motion-driven scroll helper used when tilt-to-scroll is enabled for the workspace.
    @State private var tiltScrollService = TiltScrollService()
    #endif

    /**
     The focused window's controller resolved from `WindowManager`'s single source of truth.

     Referencing `controllerVersion` guarantees SwiftUI re-evaluates when controllers are
     registered or unregistered because dictionary subscript mutations alone are unreliable.
     */
    private var focusedController: BibleReaderController? {
        _ = windowManager.controllerVersion
        guard let activeId = windowManager.activeWindow?.id else { return nil }
        return windowManager.controllers[activeId] as? BibleReaderController
    }

    /// Controller for one specific window ID, or `nil` when that pane is no longer registered.
    private func controller(for windowId: UUID?) -> BibleReaderController? {
        _ = windowManager.controllerVersion
        guard let windowId else { return nil }
        return windowManager.controllers[windowId] as? BibleReaderController
    }

    /**
     Controller that owns the currently presented pane-scoped modal flow.

     When a modal captured a specific window, this deliberately does not fall back to the currently
     focused controller if that target is still pending. Pane-scoped actions must either use their
     captured controller or wait for that pane to finish registration.
    */
    private var panePresentationController: BibleReaderController? {
        _ = windowManager.controllerVersion
        if let panePresentationTargetWindowId {
            return controller(for: panePresentationTargetWindowId)
        }
        return focusedController
    }

    /**
     Whether the modal's target pane exists but is still waiting for controller registration.

     - Returns: `true` for a visible target window that has not registered its controller yet.
     - Side Effects: Reads `WindowManager` readiness state only.
     - Failure Modes: Missing target or active window identifiers return `false`.
    */
    private var isPanePresentationControllerPending: Bool {
        // Controller registry updates bump this marker; the pending check is derived from registry state.
        _ = windowManager.controllerVersion
        if let panePresentationTargetWindowId {
            return windowManager.isControllerRegistrationPending(for: panePresentationTargetWindowId)
        }
        guard let activeId = windowManager.activeWindow?.id else { return false }
        return windowManager.isControllerRegistrationPending(for: activeId)
    }

    /**
     Builds the fallback surface for pane-scoped modals whose controller or active module is unavailable.

     - Returns: A reader-preparation view that distinguishes pending registration from unavailable state.
     - Side Effects: None.
     - Failure Modes: None.
     */
    private var readerPanePreparationContent: some View {
        ReaderPanePreparationView(
            isPending: isPanePresentationControllerPending,
            onDismiss: dismissReaderModal
        )
    }

    /// Captures the window that should own the next pane-scoped presentation.
    private func setPanePresentationTarget(_ windowId: UUID?) {
        panePresentationTargetWindowId = windowId ?? windowManager.activeWindow?.id
    }

    /// Window captured for the currently presented pane-scoped destination, if it is still loaded.
    private var panePresentationTargetWindow: Window? {
        guard let panePresentationTargetWindowId else {
            return windowManager.activeWindow
        }
        return windowManager.allWindows.first { $0.id == panePresentationTargetWindowId }
    }

    /// Android-style window-level All Text Options navigation title for the captured pane.
    private var textOptionsWindowTitle: String {
        let titleFormat = String(
            localized: "window_text_display_settings_title",
            defaultValue: "Text options - Window %d"
        )
        guard let window = panePresentationTargetWindow else {
            return String.localizedStringWithFormat(titleFormat, 1)
        }
        let position = windowManager.allWindows.firstIndex { $0.id == window.id }
            .map { $0 + 1 } ?? (window.orderNumber + 1)
        return String.localizedStringWithFormat(titleFormat, position)
    }

    /// Android-style workspace-level All Text Options navigation title for the active workspace.
    private var textOptionsWorkspaceTitle: String {
        let titleFormat = String(
            localized: "workspace_text_display_settings_title",
            defaultValue: "Text options - %@"
        )
        return String.localizedStringWithFormat(
            titleFormat,
            panePresentationTargetWindow?.workspace?.name ?? windowManager.activeWorkspace?.name ?? ""
        )
    }

    /// User-visible reference string for the currently focused Bible location.
    private var currentReference: String {
        guard let ctrl = focusedController else { return "Genesis 1" }
        return "\(ctrl.currentBook) \(ctrl.currentChapter)"
    }

    /// Android-style page title including verse when one is currently focused.
    private var currentToolbarTitle: String {
        guard let ctrl = focusedController else { return "Genesis 1:1" }
        let bookName = toolbarBookName(for: ctrl.currentBook)
        if let verse = ctrl.activeWindow?.pageManager?.bibleVerseNo, verse > 0 {
            return "\(bookName) \(ctrl.currentChapter):\(verse)"
        }
        return "\(bookName) \(ctrl.currentChapter)"
    }

    /// Android-style document subtitle showing the active module description.
    private var currentToolbarSubtitle: String {
        guard let ctrl = focusedController else { return "King James Version" }
        switch ctrl.currentCategory {
        case .commentary:
            return ctrl.activeCommentaryModule?.info.description ?? ctrl.activeCommentaryModuleName ?? String(localized: "commentaries")
        case .bible:
            return ctrl.activeModule?.info.description ?? ctrl.activeModuleName
        default:
            return ctrl.activeModule?.info.description ?? ctrl.activeModuleName
        }
    }

    /// Accessibility-exported state for the content most recently rendered in the active pane.
    private var readerRenderedContentStateValue: String {
        let windowToken = windowManager.activeWindow.map { "windowOrder=\($0.orderNumber)" } ?? "windowOrder=none"
        let exportController = focusedController
        let contentToken = exportController?.renderedContentState
            ?? BibleReaderController.emptyRenderedContentState
        let myNotesToken = exportController?.myNotesAccessibilityState
            ?? MyNotesAccessibilitySnapshot.empty.encodedValue
        let studyPadToken = exportController?.studyPadAccessibilityState
            ?? StudyPadAccessibilitySnapshot.empty.encodedValue
        let strongsMode = resolvedDisplaySettings(for: windowManager.activeWindow).strongsMode
            ?? TextDisplaySettings.appDefaults.strongsMode
            ?? 0
        let drawerToken = "drawerVisible=\(showReaderNavigationDrawer ? "true" : "false")"
        let overflowToken = "overflowVisible=\(showReaderOverflowMenu ? "true" : "false")"
        let sheetToken = "readerSheet=\(activeReaderSheet?.rawValue ?? "none")"
        let destinationToken = "readerDestination=\(activeReaderDestination?.rawValue ?? "none")"
        let modalToken = "readerModal=\(activeReaderModal?.rawValue ?? "none")"
        let searchToken = "searchVisible=\(showSearch ? "true" : "false")"
        return "\(windowToken);\(contentToken);\(myNotesToken);\(studyPadToken);strongsMode=\(strongsMode);\(drawerToken);\(overflowToken);\(sheetToken);\(destinationToken);\(modalToken);\(searchToken)"
    }

    /// Compact dedicated state export used by UI tests instead of snapshotting the full reader.
    @ViewBuilder
    private var readerRenderedContentStateExport: some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            Text(readerRenderedContentStateValue)
                .font(.system(size: 1))
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier("readerRenderedContentState")
                .accessibilityLabel("readerRenderedContentState")
                .accessibilityValue(readerRenderedContentStateValue)
        }
    }

    /// Converts SWORD Roman-numeral book prefixes into Android-style Arabic numerals for toolbar display.
    private func toolbarBookName(for rawName: String) -> String {
        let replacements = [
            "III ": "3 ",
            "II ": "2 ",
            "I ": "1 ",
        ]
        for (prefix, replacement) in replacements {
            if rawName.hasPrefix(prefix) {
                return replacement + rawName.dropFirst(prefix.count)
            }
        }
        return rawName
    }

    /// Preferred SwiftUI color-scheme override derived from the stored night-mode strategy.
    private var preferredColorSchemeOverride: ColorScheme? {
        switch NightModeSettingsResolver.effectiveMode(from: nightModeMode) {
        case .system:
            return nil
        case .automatic, .manual:
            return nightMode ? .dark : .light
        }
    }

    /// Whether the quick night-mode toggle should be shown in the ellipsis menu.
    private var isNightModeQuickToggleEnabled: Bool {
        NightModeSettingsResolver.isManualMode(rawValue: nightModeMode)
    }

    /// Whether the bottom window tab bar should remain visible in the current fullscreen state.
    private var shouldShowWindowTabBar: Bool {
        !isFullScreen || !fullScreenHideButtonsPref
    }

    /// Whether Android's English-only Easy Start default download action should be offered.
    private var isStartupEasyStartAvailable: Bool {
        Locale.current.language.languageCode?.identifier == "en"
    }

    /// Whether the floating fullscreen Bible reference capsule should be displayed.
    private var shouldShowBibleReferenceOverlay: Bool {
        isFullScreen &&
            !hideBibleReferenceOverlayPref &&
            focusedController?.currentCategory == .bible
    }

    /// Reader-shell palette derived from the active pane's text-display colors.
    private var readerThemeSurfacePalette: ReaderThemeSurfacePalette {
        ReaderThemeSurfacePalette(settings: displaySettings, nightMode: nightMode)
    }

    /// Bottom inset for the floating reference capsule, accounting for other bottom chrome.
    private var bibleReferenceOverlayBottomPadding: CGFloat {
        var padding: CGFloat = shouldShowWindowTabBar ? 58 : 16
        if speakService.isSpeaking {
            padding += 56
        }
        return padding
    }

    /**
     Binding that presents the native share sheet while a share payload exists.

     - Returns: A Boolean binding derived from `shareText`.
     - Side effects: Setting the binding to `false` clears the pending share payload.
     - Failure modes: none.
     */
    private var shareSheetBinding: Binding<Bool> {
        Binding(
            get: { shareText != nil },
            set: { isPresented in
                if !isPresented {
                    shareText = nil
                }
            }
        )
    }

    /**
     Binding that presents the cross-reference sheet while cross-reference payload exists.

     - Returns: A Boolean binding derived from `crossReferences`.
     - Side effects: Setting the binding to `false` clears the pending cross-reference payload.
     - Failure modes: none.
     */
    private var crossReferenceSheetBinding: Binding<Bool> {
        Binding(
            get: { crossReferences != nil },
            set: { isPresented in
                if !isPresented {
                    crossReferences = nil
                }
            }
        )
    }

    /**
     Creates the reader coordinator view.

     - Note: This initializer performs no work directly. The view resolves its dependencies from
       the SwiftUI environment when rendered.
     */
    public init() {}

    /**
     Builds the full reading-screen hierarchy.

     The body composes the document header, split pane layout, sheet presenters, keyboard
     shortcuts, fullscreen overlays, toast feedback, and speech mini-player around the current
     `WindowManager` state.
     */
    public var body: some View {
        readerScreenContent
        .animation(.easeInOut(duration: 0.2), value: isFullScreen)
        .overlay(alignment: .bottom) {
            bibleReferenceOverlay
        }
        .overlay(alignment: .bottom) {
            toastOverlay
        }
        .overlay(alignment: .topLeading) {
            readerRenderedContentStateExport
        }
        .overlay {
            if showReaderNavigationDrawer {
                readerNavigationDrawerOverlay
            }
            if showBookChooser {
                bookChooserDrawerOverlay
            }
        }
        .overlayPreferenceValue(ReaderOverflowButtonBoundsPreferenceKey.self) { anchor in
            if showReaderOverflowMenu {
                readerOverflowMenuOverlay(anchor: anchor)
            }
        }
        .overlayPreferenceValue(ReaderBibleToolbarButtonBoundsPreferenceKey.self) { anchor in
            if showBibleQuickModuleSelector {
                bibleQuickModuleSelectorOverlay(anchor: anchor)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toastMessage)
        .animation(.easeInOut(duration: 0.2), value: showReaderNavigationDrawer)
        .animation(.easeInOut(duration: 0.2), value: showBookChooser)
        .animation(.easeInOut(duration: 0.16), value: showReaderOverflowMenu)
        .animation(.easeInOut(duration: 0.16), value: showBibleQuickModuleSelector)
        .background {
            readerSceneMetricsBackground
        }
        .onPreferenceChange(ReaderSceneMetricsPreferenceKey.self) { metrics in
            readerSceneMetrics = metrics
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            handleReaderAppear()
        }
        .onChange(of: windowManager.activeWindow?.id) { _, _ in
            dismissBibleQuickSelector()
            syncActiveDisplaySettings()
        }
        #if os(iOS)
        .onAppear {
            // Auto-start tilt scroll if workspace has it enabled
            if windowManager.activeWorkspace?.workspaceSettings?.enableTiltToScroll ?? false {
                startTiltToScroll()
            }
        }
        .onDisappear {
            tiltScrollService.stop()
        }
        #endif
        .preferredColorScheme(preferredColorSchemeOverride)
        .sheet(isPresented: $showSearch, onDismiss: { searchInitialQuery = "" }) {
            searchSheetContent
        }
        .sheet(item: $activeReaderSheet) { presentedSheet in
            activeReaderSheetContent(presentedSheet)
        }
        .navigationDestination(item: $activeReaderDestination) { destination in
            readerDestinationContent(destination)
        }
        .confirmationDialog(
            String(localized: "picker_no_bible_modules"),
            isPresented: $showStartupDownloadPrompt,
            titleVisibility: .visible
        ) {
            startupDownloadPromptActions
        } message: {
            startupDownloadPromptMessage
        }
        .sheet(item: $activeReaderModal) { modal in
            readerModalContent(modal)
        }
        .confirmationDialog(
            localizedAndroidOverflowString(
                androidKey: "strongs_mode_title",
                fallbackKey: nil,
                default: "Choose Strong's mode"
            ),
            isPresented: $showReaderStrongsModeDialog,
            titleVisibility: .visible
        ) {
            strongsModeDialogActions
        }
        .onChange(of: activeReaderSheet) { oldValue, newValue in
            handleActiveReaderSheetChange(from: oldValue, to: newValue)
        }
        .onChange(of: activeReaderDestination) { oldValue, newValue in
            handleActiveReaderDestinationChange(from: oldValue, to: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: SwordModuleStore.modulesDidChangeNotification)) { _ in
            Task { @MainActor in
                handleModuleStoreDidChange()
            }
        }
        .onChange(of: showReaderOverflowMenu) { oldValue, newValue in
            guard oldValue, !newValue else {
                return
            }
            DispatchQueue.main.async {
                presentPendingReaderOverflowPresentation()
            }
        }
        .onChange(of: colorScheme) { _, _ in
            let store = SettingsStore(modelContext: modelContext)
            let manualNightMode = store.getBool("night_mode")
            nightMode = NightModeSettingsResolver.isNightMode(
                rawValue: nightModeMode,
                manualNightMode: manualNightMode,
                systemIsDark: colorScheme == .dark
            )
        }
        .onChange(of: isFullScreen) { _, fullScreen in
            if !fullScreen {
                lastFullScreenByDoubleTap = false
            }
        }
        .sheet(isPresented: shareSheetBinding) {
            shareSheetContent
        }
        .sheet(isPresented: crossReferenceSheetBinding) {
            crossReferenceSheetContent
        }
        .sheet(isPresented: $showRefChooser, onDismiss: resetPassageChooserProgressContext) {
            refChooserSheetContent
        }
        // MARK: - Keyboard Shortcuts (iPad/Mac)
        .background {
            keyboardShortcutSurface
        }
    }

    /// Main reader layout before transient overlays and presentation modifiers are attached.
    @ViewBuilder
    private var readerScreenContent: some View {
        let surfacePalette = readerThemeSurfacePalette
        VStack(spacing: 0) {
            // Document header bar — hidden in fullscreen mode
            if !isFullScreen {
                documentHeader
            }

            // Split content — one BibleWindowPane per visible window
            splitContent

            // Persistent mini-player when speaking (visible even in fullscreen)
            if speakService.isSpeaking {
                BibleReaderSpeakMiniPlayer(
                    speakService: speakService,
                    currentReference: currentReference,
                    onShowControls: { presentReaderModal(.speakControls) }
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Bottom window tab bar — hidden in fullscreen mode
            if shouldShowWindowTabBar {
                WindowTabBar(
                    surfacePalette: surfacePalette,
                    onShowToast: showWindowTabToast,
                    onShowBookChooser: { presentBookChooser(from: windowManager.activeWindow?.id) },
                    onGoToTypedRef: navigateWindowTabReference
                )
            }
        }
        .foregroundStyle(surfacePalette.foregroundColor)
        .background(surfacePalette.backgroundColor.ignoresSafeArea())
    }

    /// Floating current-reference capsule shown during fullscreen reading.
    @ViewBuilder
    private var bibleReferenceOverlay: some View {
        if shouldShowBibleReferenceOverlay {
            Text(currentReference)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .padding(.bottom, bibleReferenceOverlayBottomPadding)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// Transient toast shown above the window tab bar.
    @ViewBuilder
    private var toastOverlay: some View {
        if let message = toastMessage {
            Text(message)
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .shadow(radius: 4)
                .padding(.bottom, 80)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    /// Invisible scene-measurement surface used by pane and overlay placement.
    private var readerSceneMetricsBackground: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: ReaderSceneMetricsPreferenceKey.self,
                value: ReaderSceneMetrics(size: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
            )
        }
    }

    /// Workspace name shown in reader-hosted passage chooser titles.
    private var activePassageChooserWorkspaceName: String? {
        panePresentationTargetWindow?.workspace?.name ?? windowManager.activeWorkspace?.name
    }

    /// Active module initials used to match Android/iOS memorization progress ranges.
    private var passageProgressBookInitials: String {
        panePresentationController?.activeModuleName ?? ""
    }

    /// Snapshot of active pane reading progress for chooser progress bars.
    private var passageReadingProgressSnapshot: ReadingProgressSnapshot? {
        panePresentationController?.readingProgressStore?.snapshot()
    }

    /// Snapshot of active pane memorization progress for chooser progress bars.
    private var passageMemorizationProgressSnapshot: MemorizationProgressSnapshot? {
        panePresentationController?.memorizationProgressStore?.snapshot()
    }

    /**
     Creates the immutable progress context used by one passage chooser presentation.

     - Returns: Snapshot-backed progress calculator inputs for the active pane.
     - Side effects: Reads the active pane's reading and memorization progress stores once.
     - Failure modes: Missing controller/store data is represented by `nil` snapshots.
     */
    private func makePassageChooserProgressContext() -> PassageChooserProgressContext {
        PassageChooserProgressContext(
            readingSnapshot: passageReadingProgressSnapshot,
            memorizationSnapshot: passageMemorizationProgressSnapshot,
            activeBookInitials: passageProgressBookInitials
        )
    }

    /// Book chooser content used by toolbar and tab-bar navigation commands.
    private var bookChooserDrawerContent: some View {
        let progressContext = passageChooserProgressContext

        return NavigationStack {
            BookChooserView(
                books: panePresentationController?.bookList ?? BibleReaderController.defaultBooks,
                navigateToVerse: navigateToVersePref,
                currentBook: panePresentationController?.currentBook,
                currentChapter: panePresentationController?.currentChapter,
                currentVerse: panePresentationController?.currentVerse,
                workspaceName: activePassageChooserWorkspaceName,
                verseCountProvider: { book, chapter in
                    guard let panePresentationController else {
                        return BibleReaderController.verseCount(for: book.name, chapter: chapter)
                    }
                    return panePresentationController.verseCountForActiveModule(
                        book: book.name,
                        chapter: chapter
                    )
                },
                bookProgressProvider: { book in
                    progressContext.bookProgress(for: book)
                },
                chapterProgressProvider: { book, chapter in
                    progressContext.chapterProgress(for: book, chapter: chapter)
                },
                verseProgressProvider: { book, chapter, verse in
                    progressContext.verseProgress(for: book, chapter: chapter, verse: verse)
                },
                onCancel: dismissBookChooser
            ) { book, chapter, verse in
                dismissBookChooser()
                panePresentationController?.navigateTo(book: book, chapter: chapter, verse: verse)
            }
        }
        .preferredColorScheme(.dark)
        .background(PassageChooserSurfacePalette.background.swiftUIColor.ignoresSafeArea())
    }

    /// Search sheet seeded from toolbar, keyboard, or Android-compatible link routing.
    private var searchSheetContent: some View {
        NavigationStack {
            SearchView(
                swordModule: panePresentationController?.activeModule,
                swordManager: panePresentationController?.swordManager,
                searchIndexService: searchIndexService,
                installedBibleModules: panePresentationController?.installedBibleModules ?? [],
                currentBook: panePresentationController?.currentBook ?? "Genesis",
                currentOsisBookId: searchSheetCurrentOsisBookId,
                initialQuery: searchInitialQuery,
                onNavigate: navigateFromSearch
            )
        }
    }

    /// OSIS book id shown as the Search sheet's current context.
    private var searchSheetCurrentOsisBookId: String {
        let currentBook = panePresentationController?.currentBook ?? "Genesis"
        return panePresentationController?.osisBookId(for: currentBook)
            ?? BibleReaderController.osisBookId(for: currentBook)
    }

    /// Builds content for the active top-level reader sheet.
    private func activeReaderSheetContent(_ presentedSheet: ReaderSheet) -> some View {
        BibleReaderActiveSheetContent(
            sheet: presentedSheet,
            controller: panePresentationController,
            readingProgressInitialTab: readingProgressInitialTab,
            chapterReadHistoryTarget: chapterReadHistoryTarget,
            downloadsInitialSearchText: downloadsInitialSearchText,
            downloadsDefaultDownloadMode: downloadsDefaultDownloadMode,
            onDefaultDownloadActivityChanged: { isInFlight in
                handleStartupDefaultDownloadActivityChanged(isInFlight: isInFlight)
            },
            onDismiss: dismissReaderSheet
        )
    }

    /// Builds reader-stack destinations opened from the drawer, overflow, or keyboard shortcuts.
    @ViewBuilder
    private func readerDestinationContent(_ destination: ReaderDestination) -> some View {
        switch destination {
        case .settings:
            SettingsView(
                nightMode: $nightMode,
                nightModeMode: $nightModeMode,
                readingProgressController: panePresentationController,
                onSettingsChanged: applyApplicationPreferenceChange
            )
            #if os(iOS)
            .toolbar(.visible, for: .navigationBar)
            #endif
            // The reader shell is removed from the accessibility tree while a destination is
            // pushed, so re-emit the compact reader-state export here. This keeps reader routing
            // tokens (for example `readerSheet=none;readerDestination=settings`) observable by UI
            // tests on the pushed destination without exposing reader internals to SettingsView.
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .globalTextOptions:
            TextDisplaySettingsView(
                settings: $globalDisplaySettings,
                navigationTitle: String(
                    localized: "global_text_display_settings_title",
                    defaultValue: "Global text options"
                ),
                scope: .global,
                workspaceName: windowManager.activeWorkspace?.name,
                onChange: applyGlobalDisplaySettingsChange
            )
            #if os(iOS)
            .toolbar(.visible, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .workspaceTextOptions:
            TextDisplaySettingsView(
                settings: $workspaceDisplaySettings,
                navigationTitle: textOptionsWorkspaceTitle,
                scope: .workspace,
                workspaceName: panePresentationTargetWindow?.workspace?.name ?? windowManager.activeWorkspace?.name,
                onOpenGlobalSettings: { presentGlobalTextOptions(from: panePresentationTargetWindowId) },
                onChange: applyWorkspaceDisplaySettingsChange
            )
            #if os(iOS)
            .toolbar(.visible, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .windowTextOptions:
            TextDisplaySettingsView(
                settings: $windowDisplaySettings,
                navigationTitle: textOptionsWindowTitle,
                scope: .window,
                workspaceName: panePresentationTargetWindow?.workspace?.name ?? windowManager.activeWorkspace?.name,
                onOpenWorkspaceSettings: {
                    presentWorkspaceTextOptions(from: panePresentationTargetWindowId)
                },
                onOpenGlobalSettings: { presentGlobalTextOptions(from: panePresentationTargetWindowId) },
                onChange: applyWindowDisplaySettingsChange
            )
            #if os(iOS)
            .toolbar(.visible, for: .navigationBar)
            #endif
            // Mirror the Settings destination's state export so UI tests can distinguish the
            // window-level All Text Options route from global Application Preferences.
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        }
    }

    /// Buttons shown when startup detects there are no installed Bible modules.
    @ViewBuilder
    private var startupDownloadPromptActions: some View {
        if isStartupEasyStartAvailable {
            Button(String(localized: "easy_start", defaultValue: "Easy Start")) {
                presentStartupDefaultDownloads()
            }
        }
        Button(String(localized: "download_modules")) {
            presentDownloads(from: windowManager.activeWindow?.id)
        }
        Button(String(localized: "cancel"), role: .cancel) {}
    }

    /// Message shown in the no-Bible startup prompt.
    private var startupDownloadPromptMessage: some View {
        Text(
            String(
                localized: "startup_download_prompt",
                defaultValue: "Download Bible modules to start reading."
            )
        )
    }

    /// Strong's mode picker options used by the reader toolbar dialog.
    @ViewBuilder
    private var strongsModeDialogActions: some View {
        ForEach(StrongsMode.allCases) { mode in
            Button {
                applyStrongsMode(mode.rawValue)
            } label: {
                if displaySettings.strongsMode ?? 0 == mode.rawValue {
                    Label(mode.label, systemImage: "checkmark")
                } else {
                    Text(mode.label)
                }
            }
        }
        Button(String(localized: "cancel"), role: .cancel) {}
    }

    /// System share sheet for selected or generated reader text.
    @ViewBuilder
    private var shareSheetContent: some View {
        if let text = shareText {
            ShareSheet(items: [text])
        }
    }

    /// Cross-reference sheet for verse links resolved by the active pane.
    @ViewBuilder
    private var crossReferenceSheetContent: some View {
        if let refs = crossReferences {
            CrossReferenceView(references: refs) { book, chapter in
                crossReferences = nil
                panePresentationController?.navigateTo(book: book, chapter: chapter)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Reference chooser sheet used by web-modal callbacks.
    private var refChooserSheetContent: some View {
        let progressContext = passageChooserProgressContext

        return NavigationStack {
            BookChooserView(
                books: panePresentationController?.bookList ?? BibleReaderController.defaultBooks,
                currentBook: panePresentationController?.currentBook,
                currentChapter: panePresentationController?.currentChapter,
                currentVerse: panePresentationController?.currentVerse,
                workspaceName: activePassageChooserWorkspaceName,
                verseCountProvider: { book, chapter in
                    guard let panePresentationController else {
                        return BibleReaderController.verseCount(for: book.name, chapter: chapter)
                    }
                    return panePresentationController.verseCountForActiveModule(
                        book: book.name,
                        chapter: chapter
                    )
                },
                bookProgressProvider: { book in
                    progressContext.bookProgress(for: book)
                },
                chapterProgressProvider: { book, chapter in
                    progressContext.chapterProgress(for: book, chapter: chapter)
                },
                verseProgressProvider: { book, chapter, verse in
                    progressContext.verseProgress(for: book, chapter: chapter, verse: verse)
                }
            ) { book, chapter, _ in
                showRefChooser = false
                let osisId = panePresentationController?.osisBookId(for: book) ?? BibleReaderController.osisBookId(for: book)
                refChooserCompletion?("\(osisId).\(chapter)")
                refChooserCompletion = nil
            }
        }
        .presentationDetents([.large])
    }

    /// Invisible keyboard shortcut host for iPad and Mac command routing.
    private var keyboardShortcutSurface: some View {
        BibleReaderKeyboardShortcuts(
            onSearch: { presentSearch(from: windowManager.activeWindow?.id) },
            onShowBookChooser: { presentBookChooser(from: windowManager.activeWindow?.id) },
            onOpenBookmarks: { presentReaderSheet(.bookmarks, from: windowManager.activeWindow?.id) },
            onNavigatePrevious: { navigatePreviousIfReaderCanHostNavigate(focusedController) },
            onNavigateNext: { navigateNextIfReaderCanHostNavigate(focusedController) },
            onCloseClientModal: { _ = closeFocusedWebModalIfNeeded() },
            onOpenDownloads: { presentDownloads(from: windowManager.activeWindow?.id) },
            onOpenSettings: { presentSettings(from: windowManager.activeWindow?.id) }
        )
    }

    /**
     Shows transient feedback requested by the bottom window tab bar.

     - Parameter text: Message to display.
     Side effects:
     - cancels any pending toast dismissal
     - updates `toastMessage`
     - schedules automatic dismissal
     Failure modes:
     - none; newer toast requests replace earlier requests
     */
    private func showWindowTabToast(_ text: String) {
        toastWorkItem?.cancel()
        withAnimation { toastMessage = text }
        let work = DispatchWorkItem {
            withAnimation { toastMessage = nil }
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /**
     Attempts typed-reference navigation from the bottom tab bar.

     - Parameters:
       - window: Window whose controller should receive the reference.
       - text: User-entered reference text.
     - Returns: `true` when the reference was accepted by the window controller.
     Side effects:
     - may navigate the targeted pane
     Failure modes:
     - returns `false` when the controller is missing or cannot parse the reference
     */
    private func navigateWindowTabReference(_ window: Window, _ text: String) -> Bool {
        guard let ctrl = windowManager.controllers[window.id] as? BibleReaderController else {
            return false
        }
        return ctrl.navigateToRef(text)
    }

    /**
     Navigates from Search results into the active reader pane.

     - Parameters:
       - book: Book name selected by Search.
       - chapter: Chapter selected by Search.
     Side effects:
     - dismisses the Search sheet
     - updates the active pane's reader location
     Failure modes:
     - does nothing when no pane presentation controller is available
     */
    private func navigateFromSearch(book: String, chapter: Int) {
        showSearch = false
        panePresentationController?.navigateTo(book: book, chapter: chapter)
    }

    // MARK: - Sheet Routing

    /// Presents a top-level reader sheet and captures the pane target that should back it.
    private func presentReaderSheet(_ sheet: ReaderSheet, from windowId: UUID? = nil) {
        setPanePresentationTarget(windowId)
        activeReaderSheet = sheet
    }

    /// Presents a reader-stack destination and captures the pane target that should back it.
    private func presentReaderDestination(_ destination: ReaderDestination, from windowId: UUID? = nil) {
        setPanePresentationTarget(windowId)
        activeReaderDestination = destination
    }

    /// Opens Application preferences as an integrated reader-stack destination.
    private func presentSettings(from windowId: UUID? = nil) {
        presentReaderDestination(.settings, from: windowId)
    }

    /**
     Opens Android's global Text Options route as app-scoped text-display settings.

     - Parameter windowId: Pane context retained for parent-scope navigation.
     - Side effects:
       - refreshes app-level text-display defaults from `SettingsStore`
       - pushes the `.globalTextOptions` reader destination
     - Failure modes: Settings load falls back through `SettingsStore` defaults.
     */
    private func presentGlobalTextOptions(from windowId: UUID? = nil) {
        let store = SettingsStore(modelContext: modelContext)
        globalDisplaySettings = store.globalTextDisplaySettings()
        presentReaderDestination(.globalTextOptions, from: windowId)
    }

    /**
     Opens Android's main reader All Text Options route as workspace-scoped settings.

     - Parameter windowId: Pane whose workspace should own the pushed destination.
     - Side effects:
       - refreshes the workspace editor state from the current workspace/global inheritance chain
       - pushes the `.workspaceTextOptions` reader destination
     - Failure modes: If no active workspace exists, the editor opens against global/app defaults
       and writes become no-ops in `applyWorkspaceDisplaySettingsChange`.
     */
    private func presentWorkspaceTextOptions(from windowId: UUID? = nil) {
        let targetWindow = windowId.flatMap { id in
            windowManager.allWindows.first { $0.id == id }
        } ?? windowManager.activeWindow
        workspaceDisplaySettings = resolvedWorkspaceDisplaySettings(
            for: targetWindow?.workspace ?? windowManager.activeWorkspace
        )
        presentReaderDestination(.workspaceTextOptions, from: targetWindow?.id ?? windowId)
    }

    /**
     Opens Android's per-window All Text Options route as window-scoped text-display settings.

     - Parameter windowId: Pane whose reader stack should own the pushed destination.
     - Side effects:
       - refreshes the window editor state from the current inheritance chain
       - pushes the `.windowTextOptions` reader destination
     - Failure modes: If no active window exists, the editor still opens against workspace/global
       fallback values and writes become no-ops in `applyWindowDisplaySettingsChange`.
     */
    private func presentWindowTextOptions(from windowId: UUID? = nil) {
        let targetWindow = windowId.flatMap { id in
            windowManager.allWindows.first { $0.id == id }
        } ?? windowManager.activeWindow
        windowDisplaySettings = resolvedDisplaySettings(for: targetWindow)
        presentReaderDestination(.windowTextOptions, from: targetWindow?.id ?? windowId)
    }

    /**
     Presents Downloads and seeds its free-text search from an Android `download://` target.

     - Parameters:
       - windowId: Pane whose controller should own the sheet context. When `nil`, the focused pane
         is used.
       - initialSearchText: Optional module initials from the link query. Empty and whitespace-only
         values are normalized away so normal Downloads entry points remain unfiltered.
       - defaultDownloadMode: Optional startup/default-document mode for Android Easy Start.

     Side effects:
     - captures the pane presentation target
     - updates `downloadsInitialSearchText`
     - updates `downloadsDefaultDownloadMode`
     - presents the `.downloads` reader sheet

     Failure modes:
     - invalid search text is normalized to an empty string and opens the standard Downloads view
     */
    private func presentDownloads(
        from windowId: UUID? = nil,
        initialSearchText: String? = nil,
        defaultDownloadMode: ModuleBrowserDefaultDownloadMode = .disabled
    ) {
        downloadsInitialSearchText = normalizedDownloadsSearchText(initialSearchText)
        downloadsDefaultDownloadMode = defaultDownloadMode
        presentReaderSheet(.downloads, from: windowId)
    }

    /**
     Opens Downloads in Android startup Easy Start mode.

     Side effects:
     - hides the startup prompt
     - presents Downloads with `.englishStartup`, which consumes `default_documents_v2.json`

     Failure modes:
     - installation failures are handled inside `ModuleBrowserView`
     */
    private func presentStartupDefaultDownloads() {
        showStartupDownloadPrompt = false
        startupDefaultDownloadsInFlight = true
        presentDownloads(
            from: windowManager.activeWindow?.id,
            defaultDownloadMode: .englishStartup
        )
    }

    /// Closes the currently active top-level reader sheet.
    private func dismissReaderSheet() {
        if activeReaderSheet == .downloads {
            downloadsInitialSearchText = ""
            downloadsDefaultDownloadMode = .disabled
        }
        activeReaderSheet = nil
        chapterReadHistoryTarget = nil
    }

    /**
     Handles side effects that belong to a top-level reader sheet closing.

     - Parameters:
       - previousSheet: Sheet that was visible before SwiftUI reported the change.
       - currentSheet: Sheet now visible after SwiftUI reported the change.

     Side effects:
     - clears Downloads launch state after Downloads closes
     - refreshes installed-module caches for each reader controller
     - reopens the startup prompt when Downloads closes without an installed Bible unless Easy Start
       downloads are still refreshing or installing

     Failure modes:
     - non-closing sheet transitions are ignored
     */
    private func handleActiveReaderSheetChange(
        from previousSheet: ReaderSheet?,
        to currentSheet: ReaderSheet?
    ) {
        guard currentSheet == nil, let previousSheet else {
            return
        }

        switch previousSheet {
        case .downloads:
            downloadsInitialSearchText = ""
            downloadsDefaultDownloadMode = .disabled
            let shouldWaitForStartupDefaultDownloads = startupDefaultDownloadsInFlight
            for (_, ctrl) in windowManager.controllers {
                (ctrl as? BibleReaderController)?.refreshInstalledModules()
            }
            guard !shouldWaitForStartupDefaultDownloads else {
                return
            }
            reevaluateStartupDownloadPromptAfterDownloads()
        default:
            break
        }
    }

    /**
     Handles side effects that belong to a reader-stack destination closing.

     Settings is now a navigation destination instead of a sheet. Reloading behavior preferences on
     pop keeps the same refresh boundary as the former modal route without coupling the behavior to
     sheet state.

     - Parameters:
       - previousDestination: Destination that was visible before SwiftUI reported the change.
       - currentDestination: Destination now visible after SwiftUI reported the change.
     - Side Effects: Reloads reader behavior preferences after Settings closes.
     - Failure: Non-closing destination transitions are ignored.
     */
    private func handleActiveReaderDestinationChange(
        from previousDestination: ReaderDestination?,
        to currentDestination: ReaderDestination?
    ) {
        guard currentDestination == nil, previousDestination == .settings else {
            return
        }
        reloadBehaviorPreferences()
    }

    /**
     Refreshes open reader controllers after the installed SWORD module store changes.

     Settings restores, external ZIP opens, and Downloads installs mutate module files outside the
     reader controllers that own visible picker state. Those controllers must rebuild their
     `SwordManager` instances because SWORD and the C bridge cache module lists per manager.

     Side effects:
     - recreates SWORD managers inside every open `BibleReaderController`
     - hides the no-Bible startup prompt when a newly restored or installed Bible is now available

     Failure modes:
     - controllers that cannot create a replacement `SwordManager` retain their existing state.
     */
    private func handleModuleStoreDidChange() {
        for (_, ctrl) in windowManager.controllers {
            (ctrl as? BibleReaderController)?.refreshInstalledModules()
        }
        if showStartupDownloadPrompt, !startupHasNoBibleModules() {
            showStartupDownloadPrompt = false
        }
    }

    /// Presents a follow-up top-level sheet after another flow already captured the pane target.
    private func presentReaderSheetPreservingPane(_ sheet: ReaderSheet) {
        activeReaderSheet = sheet
    }

    /**
     Presents Downloads after a pane-scoped flow has already captured the owning pane.

     - Parameters:
       - initialSearchText: Optional module initials from an Android-compatible link.
       - defaultDownloadMode: Optional startup/default-document mode for Android Easy Start.
     Side effects mirror `presentDownloads(from:initialSearchText:)` without changing the captured
     pane target.

     Failure modes:
     - invalid search text is normalized to an empty string and opens the standard Downloads view
     */
    private func presentDownloadsPreservingPane(
        initialSearchText: String? = nil,
        defaultDownloadMode: ModuleBrowserDefaultDownloadMode = .disabled
    ) {
        downloadsInitialSearchText = normalizedDownloadsSearchText(initialSearchText)
        downloadsDefaultDownloadMode = defaultDownloadMode
        presentReaderSheetPreservingPane(.downloads)
    }

    /**
     Normalizes an optional Downloads search seed for storage in SwiftUI state.

     - Parameter searchText: Optional module initials from Android-compatible routing.
     - Returns: A trimmed search string, or an empty string when no target should be applied.

     The helper is deterministic and performs no side effects.

     Failure modes:
     - `nil` or whitespace-only input returns an empty string
     */
    private func normalizedDownloadsSearchText(_ searchText: String?) -> String {
        searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Presents the book chooser for the pane that initiated the navigation.
    private func presentBookChooser(from windowId: UUID? = nil) {
        setPanePresentationTarget(windowId)
        passageChooserProgressContext = makePassageChooserProgressContext()
        showReaderNavigationDrawer = false
        showReaderOverflowMenu = false
        showBookChooser = true
    }

    /// Closes the book chooser without changing the current pane target.
    private func dismissBookChooser() {
        showBookChooser = false
        resetPassageChooserProgressContext()
    }

    /// Releases stored chooser progress snapshots after the passage chooser closes.
    private func resetPassageChooserProgressContext() {
        passageChooserProgressContext = .empty
    }

    /**
     Presents Android's Bible-toolbar quick selector for the focused pane.

     - Parameter controller: Pane controller whose installed Bible module list should back the popup.
     - Side effects: Captures the active pane, closes competing reader popups, and shows the anchored
       quick selector overlay.
     - Failure modes: If the active pane cannot be identified, the popup still uses the focused
       controller fallback through `panePresentationController`.
     */
    private func presentBibleQuickSelector(_ controller: BibleReaderController) {
        let targetWindowId = windowManager.controllers.first { _, registeredController in
            (registeredController as? BibleReaderController) === controller
        }?.key
        setPanePresentationTarget(targetWindowId ?? windowManager.activeWindow?.id)
        showReaderOverflowMenu = false
        showReaderNavigationDrawer = false
        showBibleQuickModuleSelector = true
    }

    /// Dismisses the Bible quick selector without changing the captured pane target.
    private func dismissBibleQuickSelector() {
        showBibleQuickModuleSelector = false
    }

    /**
     Resolves the current Bible document name for Android quick-menu row disabling.

     - Parameter controller: Pane controller that owns the quick selector, if still available.
     - Returns: The active Bible module only when the pane is currently displaying a Bible document;
       otherwise `nil` so Bible rows remain selectable from commentary or other document modes.
     - Side effects: none.
     - Failure modes: none; missing controllers are treated as having no current Bible document.
     */
    private func currentBibleQuickSelectorModuleName(for controller: BibleReaderController?) -> String? {
        guard let controller, controller.currentCategory == .bible else {
            return nil
        }
        return controller.activeModuleName
    }

    /**
     Applies a quick-selector Bible module choice to the captured pane.

     - Parameters:
       - module: Installed Bible module selected from the Android-parity quick selector.
       - controller: Pane controller captured when the popup was rendered.
     - Side effects: Dismisses the popup, switches the active module, and ensures the pane is in Bible
       mode so the selection persists through the controller's normal document-switching path.
     - Failure modes: If the controller is no longer available, the selection is ignored.
     */
    private func selectBibleQuickModule(_ module: ModuleInfo, controller: BibleReaderController?) {
        guard let controller else { return }
        dismissBibleQuickSelector()
        controller.switchBibleDocument(to: module.name)
    }

    // MARK: - Modal Routing

    /// Presents a coordinator-owned modal and captures the pane target when that modal needs one.
    private func presentReaderModal(_ modal: ReaderModal, from windowId: UUID? = nil) {
        if modal.shouldCapturePanePresentationTarget {
            setPanePresentationTarget(windowId)
        }
        activeReaderModal = modal
    }

    /// Closes the currently active coordinator-owned modal.
    private func dismissReaderModal() {
        activeReaderModal = nil
    }

    /// Presents the document-category module picker for a pane-scoped action.
    private func presentModulePicker(_ category: DocumentCategory, from windowId: UUID? = nil) {
        pickerCategory = category
        presentReaderModal(.modulePicker, from: windowId)
    }

    /// Presents a follow-up modal after another modal already captured its pane target.
    private func presentReaderModalPreservingPane(_ modal: ReaderModal) {
        activeReaderModal = modal
    }

    @ViewBuilder
    private func readerModalContent(_ modal: ReaderModal) -> some View {
        switch modal {
        case .syncSettings:
            NavigationStack {
                SyncSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done"), action: dismissReaderModal)
                                .accessibilityIdentifier("syncSettingsDoneButton")
                        }
                    }
            }
        case .importExport:
            NavigationStack {
                ImportExportView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done"), action: dismissReaderModal)
                        }
                    }
            }
        case .speakControls:
            SpeakControlView(speakService: speakService)
                .presentationDetents([.height(400), .large])
        case .modulePicker:
            if let controller = panePresentationController {
                BibleReaderModulePicker(
                    controller: controller,
                    category: pickerCategory,
                    onDismiss: dismissReaderModal,
                    onOpenDownloads: { presentDownloadsPreservingPane() },
                    onOpenDictionaryBrowser: { presentReaderModalPreservingPane(.dictionaryBrowser) },
                    onOpenGeneralBookBrowser: { presentReaderModalPreservingPane(.generalBookBrowser) },
                    onOpenMapBrowser: { presentReaderModalPreservingPane(.mapBrowser) }
                )
            } else {
                readerPanePreparationContent
            }
        case .dictionaryBrowser:
            if let controller = panePresentationController,
               let module = controller.activeDictionaryModule {
                DictionaryBrowserView(module: module) { key in
                    dismissReaderModal()
                    controller.loadDictionaryEntry(key: key)
                }
            } else {
                readerPanePreparationContent
            }
        case .generalBookBrowser:
            if let controller = panePresentationController,
               let module = controller.activeGeneralBookModule {
                GeneralBookBrowserView(
                    module: module,
                    title: controller.activeGeneralBookModuleName ?? String(localized: "general_book")
                ) { key in
                    dismissReaderModal()
                    controller.loadGeneralBookEntry(key: key)
                }
            } else {
                readerPanePreparationContent
            }
        case .mapBrowser:
            if let controller = panePresentationController,
               let module = controller.activeMapModule {
                GeneralBookBrowserView(
                    module: module,
                    title: controller.activeMapModuleName ?? String(localized: "map")
                ) { key in
                    dismissReaderModal()
                    controller.loadMapEntry(key: key)
                }
            } else {
                readerPanePreparationContent
            }
        case .epubLibrary:
            EpubLibraryView { identifier in
                dismissReaderModal()
                panePresentationController?.switchEpub(identifier: identifier)
                panePresentationController?.switchCategory(to: .epub)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    presentReaderModalPreservingPane(.epubBrowser)
                }
            }
        case .epubBrowser:
            if let controller = panePresentationController {
                if let reader = controller.activeEpubReader {
                    EpubBrowserView(reader: reader) { href in
                        dismissReaderModal()
                        controller.loadEpubEntry(href: href)
                    }
                } else {
                    EpubLibraryView { identifier in
                        dismissReaderModal()
                        controller.switchEpub(identifier: identifier)
                        controller.switchCategory(to: .epub)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            presentReaderModalPreservingPane(.epubBrowser)
                        }
                    }
                }
            } else {
                readerPanePreparationContent
            }
        case .epubSearch:
            if let reader = panePresentationController?.activeEpubReader {
                EpubSearchView(reader: reader) { href in
                    dismissReaderModal()
                    panePresentationController?.loadEpubEntry(href: href)
                }
            } else {
                Text(String(localized: "reader_no_epub_loaded"))
                    .padding()
            }
        case .labelManager:
            NavigationStack {
                LabelManagerView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done"), action: dismissReaderModal)
                        }
                    }
            }
        case .studyPadSelector:
            NavigationStack {
                LabelManagerView(onOpenStudyPad: { labelId in
                    dismissReaderModal()
                    panePresentationController?.loadStudyPadDocument(labelId: labelId)
                })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "done"), action: dismissReaderModal)
                    }
                }
            }
        case .chooseDocument:
            if let controller = panePresentationController {
                BibleReaderModulePicker(
                    controller: controller,
                    category: controller.currentCategory,
                    startsWithAllTypes: true,
                    onDismiss: dismissReaderModal,
                    onOpenDownloads: { presentDownloadsPreservingPane() },
                    onOpenDictionaryBrowser: { presentReaderModalPreservingPane(.dictionaryBrowser) },
                    onOpenGeneralBookBrowser: { presentReaderModalPreservingPane(.generalBookBrowser) },
                    onOpenMapBrowser: { presentReaderModalPreservingPane(.mapBrowser) }
                )
            } else {
                readerPanePreparationContent
            }
        case .help:
            NavigationStack {
                HelpView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done"), action: dismissReaderModal)
                        }
                    }
            }
        }
    }

    // MARK: - Lifecycle Wiring

    /**
     Performs one-time reader setup when the SwiftUI screen appears.

     This keeps the `body` focused on composition while leaving state loading and callback wiring
     in the coordinator that owns the relevant services.
     */
    private func handleReaderAppear() {
        let store = SettingsStore(modelContext: modelContext)
        loadPersistedReaderSettings(from: store)
        configureSpeakService(with: store)
        syncActiveDisplaySettings()
        installSynchronizedScrollingCallback()
        presentUITestLaunchSearchIfNeeded()
        evaluateStartupDownloadPromptIfNeeded()
    }

    /**
     Shows the no-Bible startup prompt once when the local module store has no Bible modules.

     Android `StartupActivity` stops on its first-download layout whenever `SwordDocumentFacade`
     has no Bibles. iOS is reader-first, so this coordinator presents the equivalent decision as a
     startup prompt over the reader shell: normal Downloads for every locale, and English Easy
     Start when Android would expose it.

     Side effects:
     - reads installed modules through the focused controller or a temporary `SwordManager`
     - mutates `didEvaluateStartupDownloadPrompt` and `showStartupDownloadPrompt`

     Failure modes:
     - if `SwordManager` cannot be created, no prompt is shown and normal reader fallback remains
     */
    private func evaluateStartupDownloadPromptIfNeeded() {
        guard !didEvaluateStartupDownloadPrompt,
              activeReaderSheet == nil,
              activeReaderModal == nil else {
            return
        }
        didEvaluateStartupDownloadPrompt = true
        showStartupDownloadPrompt = startupHasNoBibleModules()
    }

    /**
     Re-runs the no-Bible startup prompt after Downloads closes.

     Android's `afterDownload()` returns to the first-download layout when the user leaves
     Downloads without installing a Bible. This mirrors that behavior without prompting again when a
     Bible is now present.

     Side effects:
     - may reset the startup-prompt guard
     - may show the startup prompt again

     Failure modes:
     - if module discovery fails, the prompt is not shown
     */
    private func reevaluateStartupDownloadPromptAfterDownloads() {
        guard startupHasNoBibleModules() else {
            showStartupDownloadPrompt = false
            return
        }
        didEvaluateStartupDownloadPrompt = false
        evaluateStartupDownloadPromptIfNeeded()
    }

    /**
     Records whether the startup Easy Start download pipeline is still active.

     - Parameter isInFlight: `true` while startup defaults are refreshing or installing, and `false`
       after the pipeline finishes or fails.

     Side effects:
     - mutates `startupDefaultDownloadsInFlight`
     - refreshes reader controller module caches when the pipeline completes
     - re-runs the no-Bible startup prompt after Downloads has already closed and no Bible installed

     Failure modes:
     - module-discovery failures are handled by `reevaluateStartupDownloadPromptAfterDownloads()`
     */
    private func handleStartupDefaultDownloadActivityChanged(isInFlight: Bool) {
        startupDefaultDownloadsInFlight = isInFlight
        guard !isInFlight, activeReaderSheet == nil else {
            return
        }

        for (_, ctrl) in windowManager.controllers {
            (ctrl as? BibleReaderController)?.refreshInstalledModules()
        }
        reevaluateStartupDownloadPromptAfterDownloads()
    }

    /**
     Tests whether the current local module store lacks installed Bible modules.

     - Returns: `true` when no installed Bible module is known.
     - Side effects: may create a temporary `SwordManager` if the focused controller has not
       registered yet.
     - Failure modes: returns `false` if `SwordManager` creation fails.
     */
    private func startupHasNoBibleModules() -> Bool {
        if let focusedController {
            return focusedController.installedBibleModules.isEmpty
        }
        guard let manager = SwordManager() else {
            return false
        }
        return !manager.installedModules().contains { $0.category == .bible }
    }

    /// Loads persisted display, behavior, and fullscreen preferences used by the reader shell.
    private func loadPersistedReaderSettings(from store: SettingsStore) {
        globalDisplaySettings = store.globalTextDisplaySettings()
        nightModeMode = store.getString(.nightModePref3)
        let manualNightMode = store.getBool("night_mode")
        nightMode = NightModeSettingsResolver.isNightMode(
            rawValue: nightModeMode,
            manualNightMode: manualNightMode,
            systemIsDark: colorScheme == .dark
        )
        navigateToVersePref = store.getBool(.navigateToVersePref)
        autoFullscreenPref = store.getBool(.autoFullscreenPref)
        disableTwoStepBookmarkingPref = store.getBool(.disableTwoStepBookmarking)
        toolbarButtonActionsMode = store.getString(.toolbarButtonActions)
        bibleViewSwipeMode = store.getString(.bibleViewSwipeMode)
        fullScreenHideButtonsPref = store.getBool(.fullScreenHideButtonsPref)
        hideWindowButtonsPref = store.getBool(.hideWindowButtons)
        hideBibleReferenceOverlayPref = store.getBool(.hideBibleReferenceOverlay)
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = store.getBool(.screenKeepOnPref)
        #endif
    }

    /// Wires TTS settings and callbacks to the currently active reader pane.
    private func configureSpeakService(with store: SettingsStore) {
        speakService.settingsStore = store
        speakService.restoreSettings()

        let wm = windowManager
        speakService.onRequestNext = {
            if let activeId = wm.activeWindow?.id,
               let ctrl = wm.controllers[activeId] as? BibleReaderController {
                ctrl.navigateNext()
                ctrl.speakCurrentChapter()
            }
        }
        speakService.onRequestPrevious = {
            if let activeId = wm.activeWindow?.id,
               let ctrl = wm.controllers[activeId] as? BibleReaderController {
                ctrl.navigatePrevious()
                ctrl.speakCurrentChapter()
            }
        }
        speakService.onFinishedSpeaking = {
            if let activeId = wm.activeWindow?.id,
               let ctrl = wm.controllers[activeId] as? BibleReaderController {
                guard ctrl.hasNext else { return }
                ctrl.navigateNext()
                ctrl.speakCurrentChapter()
            }
        }
    }

    /// Registers synchronized scrolling behavior across windows in the active workspace.
    private func installSynchronizedScrollingCallback() {
        windowManager.onSyncVerseChanged = { [weak windowManager] sourceWindow, ordinal, key in
            guard let wm = windowManager else { return }
            let syncTargets = wm.syncedWindows(for: sourceWindow)
                .filter { $0.id != sourceWindow.id }
            for target in syncTargets {
                guard let ctrl = wm.controllers[target.id] as? BibleReaderController else {
                    continue
                }

                let sourceBook = sourceWindow.pageManager?.bibleBibleBook
                let sourceChapter = sourceWindow.pageManager?.bibleChapterNo
                let targetBook = target.pageManager?.bibleBibleBook
                let targetChapter = target.pageManager?.bibleChapterNo
                if sourceBook == targetBook && sourceChapter == targetChapter {
                    ctrl.scrollToOrdinal(ordinal)
                    continue
                }

                let parts = key.split(separator: ".")
                if parts.count >= 2,
                   let chapter = Int(parts[1]) {
                    let osisBook = String(parts[0])
                    if let bookName = ctrl.bookName(forOsisId: osisBook) {
                        ctrl.navigateTo(book: bookName, chapter: chapter)
                    }
                }
            }
        }
    }

    // MARK: - Split Content

    /**
     Lays out the visible reading panes and separators for the active workspace.

     The layout orientation follows the current geometry and the workspace reverse-split setting.
     Pane sizes are derived from persisted `layoutWeight` values so resizing survives navigation
     and relayout.
     */
    private var splitContent: some View {
        BibleReaderSplitContent(
            windows: windowManager.visibleWindows,
            reverseSplitMode: windowManager.activeWorkspace?.workspaceSettings?.enableReverseSplitMode ?? false
        ) { window in
            paneView(for: window)
        }
    }

    /// Queues one internal presentation until the reader overflow sheet fully dismisses.
    private func dismissReaderOverflowMenuAndQueue(_ presentation: ReaderOverflowPresentation) {
        pendingReaderOverflowCallback = nil
        pendingReaderOverflowPresentation = presentation
        showReaderOverflowMenu = false
    }

    /// Queues one side-effect-only action until the reader overflow sheet fully dismisses.
    private func dismissReaderOverflowMenuAndPerform(_ action: @escaping () -> Void) {
        pendingReaderOverflowPresentation = nil
        pendingReaderOverflowCallback = action
        showReaderOverflowMenu = false
    }

    /// Presents any pending internal destination after the reader overflow sheet finishes dismissing.
    private func presentPendingReaderOverflowPresentation() {
        let callback = pendingReaderOverflowCallback
        pendingReaderOverflowCallback = nil

        let presentation = pendingReaderOverflowPresentation
        pendingReaderOverflowPresentation = nil

        guard callback != nil || presentation != nil else {
            return
        }

        DispatchQueue.main.async {
            if let callback {
                callback()
                return
            }

            guard let presentation else {
                return
            }

            switch presentation {
            case .labelManager:
                presentReaderModal(.labelManager)
            case .bookmarks:
                presentReaderSheet(.bookmarks, from: windowManager.activeWindow?.id)
            case .history:
                presentReaderSheet(.history, from: windowManager.activeWindow?.id)
            case .readingPlans:
                presentReaderSheet(.readingPlans, from: windowManager.activeWindow?.id)
            case .settings:
                presentSettings(from: windowManager.activeWindow?.id)
            case .textOptions:
                presentWorkspaceTextOptions(from: windowManager.activeWindow?.id)
            case .workspaces:
                presentReaderSheet(.workspaces, from: windowManager.activeWindow?.id)
            case .downloads:
                presentDownloads(from: windowManager.activeWindow?.id)
            case .epubLibrary:
                presentReaderModal(.epubLibrary, from: windowManager.activeWindow?.id)
            case .epubBrowser:
                presentReaderModal(.epubBrowser, from: windowManager.activeWindow?.id)
            case .epubSearch:
                presentReaderModal(.epubSearch, from: windowManager.activeWindow?.id)
            case .help:
                presentReaderModal(.help)
            case .about:
                presentReaderSheet(.about, from: windowManager.activeWindow?.id)
            }
        }
    }

    /** Opens Bookmarks from the reader shell. */
    private func openBookmarksFromReaderAction() {
        presentReaderSheet(.bookmarks, from: windowManager.activeWindow?.id)
    }

    /** Opens History from the reader shell. */
    private func openHistoryFromReaderAction() {
        presentReaderSheet(.history, from: windowManager.activeWindow?.id)
    }

    /** Opens Reading Plans from the reader shell. */
    private func openReadingPlansFromReaderAction() {
        presentReaderSheet(.readingPlans, from: windowManager.activeWindow?.id)
    }

    /** Opens Settings from the reader shell. */
    private func openSettingsFromReaderAction() {
        presentSettings(from: windowManager.activeWindow?.id)
    }

    /** Opens Workspaces from the reader shell. */
    private func openWorkspacesFromReaderAction() {
        presentReaderSheet(.workspaces, from: windowManager.activeWindow?.id)
    }

    /** Opens Downloads from the reader shell. */
    private func openDownloadsFromReaderAction() {
        presentDownloads(from: windowManager.activeWindow?.id)
    }

    /** Opens About from the reader shell. */
    private func openAboutFromReaderAction() {
        presentReaderSheet(.about, from: windowManager.activeWindow?.id)
    }

    /**
     Builds one `BibleWindowPane` and wires all pane-level callbacks back into this coordinator.

     - Parameter window: Persisted window model that owns the pane's category, history, and
       layout state.
     - Returns: A fully configured pane view bound to coordinator-owned presentation state.
     */
    private func paneView(for window: Window) -> some View {
        BibleWindowPane(
            window: window,
            isFocused: window.id == windowManager.activeWindow?.id,
            displaySettings: resolvedDisplaySettings(for: window),
            nightMode: nightMode,
            disableTwoStepBookmarking: disableTwoStepBookmarkingPref,
            hideWindowButtons: hideWindowButtonsPref,
            speakService: speakService,
            onShowBookChooser: { presentBookChooser(from: window.id) },
            onShowSearch: { presentSearch(from: window.id) },
            onShowBookmarks: { presentReaderSheet(.bookmarks, from: window.id) },
            onShowSettings: { presentSettings(from: window.id) },
            onShowWindowTextOptions: { presentWindowTextOptions(from: window.id) },
            onShowDownloads: { initialSearchText in
                presentDownloads(from: window.id, initialSearchText: initialSearchText)
            },
            onShowHistory: { presentReaderSheet(.history, from: window.id) },
            onShowCompare: {
                (windowManager.controllers[window.id] as? BibleReaderController)?.loadCompareDocument()
            },
            onShowReadingPlans: { presentReaderSheet(.readingPlans, from: window.id) },
            onShowReadingProgress: { tab in
                readingProgressInitialTab = ReadingProgressTab(androidTab: tab)
                presentReaderSheet(.readingProgress, from: window.id)
            },
            onShowReadingProgressSettings: {
                presentReaderSheet(.readingProgressSettings, from: window.id)
            },
            onShowChapterReadHistory: { target in
                chapterReadHistoryTarget = target
                presentReaderSheet(.chapterReadHistory, from: window.id)
            },
            onShowSpeakControls: { presentReaderModal(.speakControls, from: window.id) },
            onShareText: { text in shareText = text },
            onShowCrossReferences: { refs in
                setPanePresentationTarget(window.id)
                crossReferences = refs
            },
            onShowModulePicker: { category in
                presentModulePicker(category, from: window.id)
            },
            onShowToast: { text in
                toastWorkItem?.cancel()
                withAnimation { toastMessage = text }
                let work = DispatchWorkItem {
                    withAnimation { toastMessage = nil }
                }
                toastWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
            },
            onShowWorkspaces: { presentReaderSheet(.workspaces, from: window.id) },
            onToggleFullScreen: {
                if isFullScreen {
                    withAnimation(.easeInOut(duration: 0.2)) { isFullScreen = false }
                    lastFullScreenByDoubleTap = false
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) { isFullScreen = true }
                    lastFullScreenByDoubleTap = true
                }
                resetAutoFullscreenTracking()
            },
            onSearchForStrongs: { strongsNum in presentSearch(from: window.id, initialQuery: strongsNum) },
            onRefChooserDialog: { completion in
                // Present book chooser and return OSIS ref
                setPanePresentationTarget(window.id)
                passageChooserProgressContext = makePassageChooserProgressContext()
                refChooserCompletion = completion
                showRefChooser = true
            },
            onUserScrollDeltaY: { deltaY in
                handleAutoFullscreenScroll(from: window, deltaY: deltaY)
            },
            onUserHorizontalSwipe: { direction in
                handleHorizontalSwipe(from: window, direction: direction)
            }
        )
    }

    // MARK: - Document Header

    /**
     Builds the top document header bar for the focused pane state.

     The header switches between Bible navigation chrome and category-specific back/navigation
     controls for notes, study pads, dictionaries, maps, general books, and EPUB content.
     */
    private var documentHeader: some View {
        let controller = focusedController
        return BibleReaderDocumentHeader(
            mode: documentHeaderMode(for: controller),
            currentReference: currentReference,
            avoidanceInsets: readerWindowControlsAvoidanceInsets,
            surfacePalette: readerThemeSurfacePalette,
            onOpenNavigationDrawer: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showReaderNavigationDrawer = true
                }
            },
            onNavigatePrevious: { navigatePreviousIfReaderCanHostNavigate(controller) },
            onShowBookChooser: { presentBookChooser(from: windowManager.activeWindow?.id) },
            onNavigateNext: { navigateNextIfReaderCanHostNavigate(controller) },
            onReturnFromMyNotes: { controller?.returnFromMyNotes() },
            onReturnFromStudyPad: { controller?.returnFromStudyPad() },
            onReturnFromAuxiliary: { controller?.switchCategory(to: .bible) },
            onBrowseAuxiliary: {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                switch controller?.currentCategory {
                case .dictionary: presentReaderModalPreservingPane(.dictionaryBrowser)
                case .generalBook: presentReaderModalPreservingPane(.generalBookBrowser)
                case .map: presentReaderModalPreservingPane(.mapBrowser)
                case .epub: presentReaderModalPreservingPane(.epubBrowser)
                default: break
                }
            }
        ) {
            readerToolbarActions(controller: controller)
        }
        .readerRenderedContentStateAccessibilityValue(readerRenderedContentStateValue)
    }

    /// Extra document-header padding reserved for iPad windowed layouts with floating controls.
    private var readerWindowControlsAvoidanceInsets: EdgeInsets {
        #if os(iOS)
        ReaderWindowControlsAvoidanceMetrics.documentHeaderInsets(
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            sceneSize: readerSceneMetrics.size,
            screenWidth: UIScreen.main.bounds.width,
            safeAreaInsets: readerSceneMetrics.safeAreaInsets
        )
        #else
        .init()
        #endif
    }

    /// Resolves which top-level header layout should be displayed for the focused controller.
    private func documentHeaderMode(for controller: BibleReaderController?) -> BibleReaderDocumentHeaderMode {
        if controller?.showingMyNotes == true {
            return .myNotes
        }
        if controller?.showingStudyPad == true {
            return .studyPad(title: controller?.activeStudyPadLabelName ?? String(localized: "study_pad"))
        }
        if controller?.currentCategory == .dictionary ||
            controller?.currentCategory == .generalBook ||
            controller?.currentCategory == .map ||
            controller?.currentCategory == .epub {
            let category = controller?.currentCategory ?? .dictionary
            return .auxiliary(
                title: controller?.activeModuleName(for: category) ?? "",
                subtitle: auxiliaryDocumentSubtitle(for: controller),
                browseSystemImageName: browseIconName(for: category)
            )
        }
        return .bible(
            title: currentToolbarTitle,
            subtitle: currentToolbarSubtitle,
            hasPrevious: controller?.hasPrevious == true,
            hasNext: controller?.hasNext == true
        )
    }

    /// Subtitle shown beneath auxiliary document titles in the header.
    private func auxiliaryDocumentSubtitle(for controller: BibleReaderController?) -> String? {
        switch controller?.currentCategory {
        case .dictionary:
            return controller?.currentDictionaryKey
        case .generalBook:
            return controller?.currentGeneralBookKey
        case .map:
            return controller?.currentMapKey
        case .epub:
            return controller?.currentEpubTitle
        default:
            return nil
        }
    }

    /**
     Builds the Android-style options menu: window/text-display controls only.
     */
    private var readerOverflowMenu: some View {
        BibleReaderOverflowMenu(
            state: readerOverflowMenuState,
            colorScheme: colorScheme,
            onAction: handleReaderOverflowMenuAction
        )
    }

    private var readerOverflowMenuState: BibleReaderOverflowMenuState {
        BibleReaderOverflowMenuState(
            isFullScreen: isFullScreen,
            showsNightModeToggle: isNightModeQuickToggleEnabled,
            nightMode: nightMode,
            showsTiltToScrollToggle: shouldShowTiltToScrollOverflowToggle,
            tiltToScrollEnabled: windowManager.activeWorkspace?.workspaceSettings?.enableTiltToScroll ?? false,
            showsReverseSplitModeToggle: windowManager.visibleWindows.count > 1,
            reverseSplitModeEnabled: windowManager.activeWorkspace?.workspaceSettings?.enableReverseSplitMode ?? false,
            windowPinningEnabled: windowManager.activeWorkspace?.workspaceSettings?.autoPin ?? false,
            showsBibleDisplayOptions: isBibleContentFocused,
            sectionTitlesEnabled: sectionTitlesEnabled,
            moduleHasStrongs: moduleHasStrongs,
            strongsMenuIconAssetName: strongsMenuIconAssetName,
            verseNumbersEnabled: verseNumbersEnabled
        )
    }

    private var shouldShowTiltToScrollOverflowToggle: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    private func handleReaderOverflowMenuAction(_ action: BibleReaderOverflowMenuAction) {
        switch action {
        case .toggleFullscreen:
            withAnimation(.easeInOut(duration: 0.2)) { isFullScreen.toggle() }
            lastFullScreenByDoubleTap = false
            resetAutoFullscreenTracking()
        case .toggleNightMode:
            let nextValue = !nightMode
            let store = SettingsStore(modelContext: modelContext)
            store.setBool("night_mode", value: nextValue)
            nightMode = NightModeSettingsResolver.isNightMode(
                rawValue: nightModeMode,
                manualNightMode: nextValue,
                systemIsDark: colorScheme == .dark
            )
            for window in windowManager.visibleWindows {
                if let ctrl = windowManager.controllers[window.id] as? BibleReaderController {
                    ctrl.updateDisplaySettings(displaySettings, nightMode: nightMode)
                }
            }
        case .openWorkspaces:
            dismissReaderOverflowMenuAndQueue(.workspaces)
        case .toggleTiltToScroll:
            #if os(iOS)
            let nextValue = !(windowManager.activeWorkspace?.workspaceSettings?.enableTiltToScroll ?? false)
            updateWorkspaceSettings { $0.enableTiltToScroll = nextValue }
            if nextValue {
                startTiltToScroll()
            } else {
                tiltScrollService.stop()
            }
            #else
            break
            #endif
        case .toggleReverseSplitMode:
            let nextValue = !(windowManager.activeWorkspace?.workspaceSettings?.enableReverseSplitMode ?? false)
            updateWorkspaceSettings { $0.enableReverseSplitMode = nextValue }
        case .toggleWindowPinning:
            let nextValue = !(windowManager.activeWorkspace?.workspaceSettings?.autoPin ?? false)
            updateWorkspaceSettings { $0.autoPin = nextValue }
        case .openLabelSettings:
            dismissReaderOverflowMenuAndQueue(.labelManager)
        case .toggleSectionTitles:
            toggleDisplaySetting(\.showSectionTitles, default: true)
        case .openStrongsMode:
            dismissReaderOverflowMenuAndPerform {
                showReaderStrongsModeDialog = true
            }
        case .toggleVerseNumbers:
            toggleDisplaySetting(\.showVerseNumbers, default: true)
        case .openTextOptions:
            dismissReaderOverflowMenuAndQueue(.textOptions)
        }
    }

    /// Full-screen dismiss area plus anchored trailing popup for Android-style overflow actions.
    private func readerOverflowMenuOverlay(anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { proxy in
            let buttonRect = anchor.map { proxy[$0] }
            let width = min(proxy.size.width - 16, CGFloat(236))
            let placement = ReaderToolbarPopupPlacement.trailingToolbarPopup(
                containerSize: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets,
                triggerRect: buttonRect,
                popupWidth: width
            )

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { showReaderOverflowMenu = false }
                    .accessibilityIdentifier("readerOverflowMenuDismissArea")

                readerOverflowMenu
                    .frame(width: width, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.45 : 0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.18), radius: 14, y: 6)
                    .offset(x: placement.offset.width, y: placement.offset.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
    }

    /// Full-screen dismiss area plus anchored Bible quick selector mirroring Android's toolbar popup.
    private func bibleQuickModuleSelectorOverlay(anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { proxy in
            let buttonRect = anchor.map { proxy[$0] }
            let controller = panePresentationController
            let rows = BibleReaderQuickModuleSelectorPresentation.rows(
                for: controller?.installedBibleModules ?? [],
                activeModuleName: currentBibleQuickSelectorModuleName(for: controller)
            )
            let width = min(max(proxy.size.width * 0.42, 156), min(proxy.size.width - 16, 232))
            let placement = ReaderToolbarPopupPlacement.trailingToolbarPopup(
                containerSize: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets,
                triggerRect: buttonRect,
                popupWidth: width
            )

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissBibleQuickSelector() }
                    .accessibilityIdentifier("readerBibleQuickSelectorDismissArea")

                if !rows.isEmpty {
                    BibleReaderQuickModuleSelector(
                        rows: rows,
                        colorScheme: colorScheme,
                        maximumHeight: placement.maximumHeight,
                        onSelect: { module in
                            selectBibleQuickModule(module, controller: controller)
                        }
                    )
                    .frame(width: width, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.45 : 0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.18), radius: 14, y: 6)
                    .offset(x: placement.offset.width, y: placement.offset.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
            }
        }
    }

    /// Full-screen dimmer plus left drawer panel mirroring Android's main navigation drawer.
    private var readerNavigationDrawerOverlay: some View {
        ReaderSideDrawerOverlay(
            colorScheme: colorScheme,
            dismissAreaIdentifier: "readerNavigationDrawerDismissArea",
            onDismiss: dismissReaderNavigationDrawer
        ) { width in
            BibleReaderNavigationDrawer(
                width: width,
                colorScheme: colorScheme,
                versionText: readerNavigationDrawerVersionText,
                onAction: handleReaderNavigationDrawerAction
            )
        }
    }

    /// Full-screen dark chooser panel for Android-style passage selection.
    private var bookChooserDrawerOverlay: some View {
        ReaderPassageChooserOverlay {
            bookChooserDrawerContent
                .accessibilityIdentifier("passageChooserDrawer")
        }
    }

    /// Dismisses the drawer immediately using the shared animation.
    private func dismissReaderNavigationDrawer() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showReaderNavigationDrawer = false
        }
    }

    /// Dismisses the drawer before running a follow-up action that may present another surface.
    private func dismissReaderNavigationDrawerAndPerform(_ action: @escaping () -> Void) {
        if showReaderNavigationDrawer {
            dismissReaderNavigationDrawer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: action)
        } else {
            action()
        }
    }

    /// Runs the coordinator-owned side effect for one drawer row.
    private func handleReaderNavigationDrawerAction(_ action: BibleReaderNavigationDrawerAction) {
        switch action {
        case .chooseDocument:
            dismissReaderNavigationDrawerAndPerform {
                presentReaderModal(.chooseDocument, from: windowManager.activeWindow?.id)
            }
        case .search:
            dismissReaderNavigationDrawerAndPerform {
                presentSearch(from: windowManager.activeWindow?.id)
            }
        case .speak:
            dismissReaderNavigationDrawerAndPerform {
                speakLastUsed = Date().timeIntervalSince1970
                if speakService.isSpeaking {
                    presentReaderModal(.speakControls, from: windowManager.activeWindow?.id)
                } else {
                    panePresentationController?.speakCurrentChapter()
                    presentReaderModal(.speakControls, from: windowManager.activeWindow?.id)
                }
            }
        case .bookmarks:
            dismissReaderNavigationDrawerAndPerform {
                presentReaderSheet(.bookmarks, from: windowManager.activeWindow?.id)
            }
        case .studyPads:
            dismissReaderNavigationDrawerAndPerform {
                presentReaderModal(.studyPadSelector, from: windowManager.activeWindow?.id)
            }
        case .myNotes:
            dismissReaderNavigationDrawerAndPerform {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                panePresentationController?.loadMyNotesDocument()
            }
        case .readingPlans:
            dismissReaderNavigationDrawerAndPerform {
                presentReaderSheet(.readingPlans, from: windowManager.activeWindow?.id)
            }
        case .history:
            dismissReaderNavigationDrawerAndPerform {
                presentReaderSheet(.history, from: windowManager.activeWindow?.id)
            }
        case .downloads:
            dismissReaderNavigationDrawerAndPerform {
                presentDownloads(from: windowManager.activeWindow?.id)
            }
        case .importExport:
            dismissReaderNavigationDrawerAndPerform { presentReaderModal(.importExport) }
        case .syncSettings:
            dismissReaderNavigationDrawerAndPerform { presentReaderModal(.syncSettings) }
        case .settings:
            dismissReaderNavigationDrawerAndPerform {
                presentSettings(from: windowManager.activeWindow?.id)
            }
        case .help:
            dismissReaderNavigationDrawerAndPerform { presentReaderModal(.help) }
        case .sponsorDevelopment:
            dismissReaderNavigationDrawerAndPerform {
                openExternalLink("https://shop.andbible.org")
            }
        case .needHelp:
            dismissReaderNavigationDrawerAndPerform {
                openExternalLink("https://github.com/AndBible/and-bible/wiki/Support")
            }
        case .contribute:
            dismissReaderNavigationDrawerAndPerform {
                openExternalLink("https://github.com/AndBible/and-bible/wiki/How-to-contribute")
            }
        case .about:
            dismissReaderNavigationDrawerAndPerform {
                presentReaderSheet(.about, from: windowManager.activeWindow?.id)
            }
        case .appLicense:
            dismissReaderNavigationDrawerAndPerform {
                openExternalLink("https://www.gnu.org/licenses/gpl-3.0.html")
            }
        case .tellFriend:
            dismissReaderNavigationDrawerAndPerform {
                shareText = String(localized: "tell_friend_message")
            }
        case .rateApp:
            dismissReaderNavigationDrawerAndPerform {
                #if os(iOS)
                if let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first {
                    SKStoreReviewController.requestReview(in: scene)
                }
                #endif
            }
        case .reportBug:
            dismissReaderNavigationDrawerAndPerform {
                openExternalLink("https://github.com/AndBible/and-bible/issues")
            }
        }
    }

    /// Resolves an Android drawer/document string with an English fallback when iOS lacks a key.
    private func localizedDrawerString(_ key: String, default defaultValue: String) -> String {
        Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
    }

    /// Opens an external URL using the platform host application.
    private func openExternalLink(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Current app version string shown in the drawer footer.
    private var readerNavigationDrawerVersionText: String {
        AndBibleAppVersionMetadata.current().drawerFooterText
    }

    /// Category-specific browse icon used when reading non-Bible content.
    private func browseIconName(for category: DocumentCategory?) -> String {
        switch category {
        case .dictionary:
            return "character.book.closed"
        case .generalBook:
            return "books.vertical.fill"
        case .map:
            return "map.fill"
        case .epub:
            return "book.closed.fill"
        default:
            return "list.bullet"
        }
    }

    /**
     Whether the Strong's toggle should be shown for the active module.

     This mirrors Android's `isStrongsInBook` behavior by consulting the focused controller's
     resolved module features instead of a static module-category assumption.
     */
    private var moduleHasStrongs: Bool {
        focusedController?.hasStrongs ?? (activeReaderCategory == .bible)
    }

    /// Whether the currently focused Bible location is in the New Testament.
    private var isCurrentBookNewTestament: Bool {
        guard let controller = focusedController else { return true }
        return controller.isNewTestament(controller.currentBook)
    }

    /// Android vector resource name for the current Strong's testament/mode combination.
    private var strongsIconAssetName: String {
        let isNT = isCurrentBookNewTestament
        switch StrongsMode(rawValue: displaySettings.strongsMode ?? 0) ?? .off {
        case .inline:
            return isNT ? "ToolbarStrongsGreekLinks" : "ToolbarStrongsHebrewLinks"
        case .links:
            return isNT ? "ToolbarStrongsGreekLinksText" : "ToolbarStrongsHebrewLinksText"
        case .off, .hidden:
            return isNT ? "ToolbarStrongsGreek" : "ToolbarStrongsHebrew"
        }
    }

    /// Android base Strong's icon used for the overflow-menu configuration row.
    private var strongsMenuIconAssetName: String {
        isCurrentBookNewTestament ? "ToolbarStrongsGreek" : "ToolbarStrongsHebrew"
    }

    /// Whether the focused pane is currently showing Bible content.
    private var isBibleContentFocused: Bool {
        activeReaderCategory == .bible
    }

    /// Best-effort active reader category, falling back to persisted window state during launch.
    private var activeReaderCategory: DocumentCategory {
        if let category = focusedController?.currentCategory {
            return category
        }
        switch windowManager.activeWindow?.pageManager?.currentCategoryName ?? "bible" {
        case DocumentCategory.commentary.pageManagerKey:
            return .commentary
        case DocumentCategory.dictionary.pageManagerKey:
            return .dictionary
        case DocumentCategory.generalBook.pageManagerKey:
            return .generalBook
        case DocumentCategory.map.pageManagerKey:
            return .map
        case DocumentCategory.epub.pageManagerKey:
            return .epub
        default:
            return .bible
        }
    }

    /// Current effective Section Titles toggle after resolving window/workspace/global defaults.
    private var sectionTitlesEnabled: Bool {
        displaySettings.showSectionTitles ?? TextDisplaySettings.appDefaults.showSectionTitles ?? true
    }

    /// Current effective Chapter & Verse Numbers toggle after resolving window/workspace/global defaults.
    private var verseNumbersEnabled: Bool {
        displaySettings.showVerseNumbers ?? TextDisplaySettings.appDefaults.showVerseNumbers ?? true
    }

    /// Most-recently-used single-button fallback used when the toolbar can only fit one accessory.
    private var preferredSingleToolbarAccessory: BibleReaderToolbarAccessoryButton? {
        if speakService.isSpeaking || speakLastUsed > searchLastUsed {
            .speak
        } else {
            .search
        }
    }

    /// Whether the reader toolbar should collapse to Android's compact portrait action budget.
    private var usesCompactReaderToolbar: Bool {
        horizontalSizeClass == .compact
    }

    /// Width-aware toolbar action cluster that keeps Search available while matching Android's compact-vs-expanded behavior.
    @ViewBuilder
    private func readerToolbarActions(controller: BibleReaderController?) -> some View {
        BibleReaderToolbarActions(
            usesCompactToolbar: usesCompactReaderToolbar,
            preferredSingleAccessory: preferredSingleToolbarAccessory,
            moduleHasStrongs: moduleHasStrongs,
            strongsIconAssetName: strongsIconAssetName,
            strongsMode: displaySettings.strongsMode ?? 0,
            strongsEnabled: strongsEnabled,
            isBibleActive: controller?.currentCategory == .bible,
            isCommentaryActive: controller?.currentCategory == .commentary,
            moduleActionsEnabled: controller != nil,
            onShowSearch: { presentSearch(from: windowManager.activeWindow?.id) },
            onShowSpeak: {
                speakLastUsed = Date().timeIntervalSince1970
                if speakService.isSpeaking {
                    presentReaderModal(.speakControls, from: windowManager.activeWindow?.id)
                } else {
                    controller?.speakCurrentChapter()
                    presentReaderModal(.speakControls, from: windowManager.activeWindow?.id)
                }
            },
            onApplyStrongsMode: { mode in applyStrongsMode(mode) },
            onBibleTap: {
                if suppressBibleTapAfterLongPress {
                    suppressBibleTapAfterLongPress = false
                    return
                }
                handleBibleToolbarTap(controller)
            },
            onBibleLongPress: {
                suppressBibleTapAfterLongPress = true
                handleBibleToolbarLongPress(controller)
            },
            onCommentaryTap: {
                if suppressCommentaryTapAfterLongPress {
                    suppressCommentaryTapAfterLongPress = false
                    return
                }
                handleCommentaryToolbarTap(controller)
            },
            onCommentaryLongPress: {
                suppressCommentaryTapAfterLongPress = true
                handleCommentaryToolbarLongPress(controller)
            },
            onShowWorkspaces: { presentReaderSheet(.workspaces, from: windowManager.activeWindow?.id) }
        ) {
            readerOverflowToolbarButton
        }
    }

    /// Neutral toolbar tint matching Android's white/grey icon-state treatment.
    private func toolbarIconColor(isActive: Bool = true) -> Color {
        isActive ? .primary : .secondary
    }

    /// Trailing overflow trigger that must remain visible even when toolbar actions collapse.
    private var readerOverflowToolbarButton: some View {
        Button {
            showReaderOverflowMenu.toggle()
        } label: {
            ToolbarAssetIcon(name: "ToolbarOverflow")
                .foregroundStyle(toolbarIconColor())
                .frame(width: 24, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("readerMoreMenuButton")
        .anchorPreference(key: ReaderOverflowButtonBoundsPreferenceKey.self, value: .bounds) { $0 }
    }

    /// Whether Strong's numbers are currently enabled (strongsMode > 0).
    private var strongsEnabled: Bool {
        (displaySettings.strongsMode ?? 0) > 0
    }

    /**
     Mutates workspace settings and persists the updated value to SwiftData.

     - Parameter transform: Mutation closure applied to the current workspace settings value.
     - Side effects: Reads the active workspace, mutates its persisted `workspaceSettings`, and
       attempts to save the updated value through `modelContext`.
     - Failure modes: If no active workspace exists, the function returns without mutating state.
       SwiftData save failures are intentionally swallowed via `try?`.
     */
    private func updateWorkspaceSettings(_ transform: (inout WorkspaceSettings) -> Void) {
        guard let workspace = windowManager.activeWorkspace else { return }
        var settings = workspace.workspaceSettings ?? WorkspaceSettings()
        transform(&settings)
        workspace.workspaceSettings = settings
        try? modelContext.save()
    }

    /**
     Applies a Strong's display mode to the active window only and refreshes that pane.

     - Parameter mode: Raw Vue.js/config mode value (`0...3`) matching `StrongsMode`.
     - Side effects: Persists the updated Strong's mode through the window-scope settings helper,
       refreshes the active pane controller, and re-syncs focused toolbar state.
     - Failure modes: If no active window or page manager exists, the persistence helper performs
       only in-memory refreshes. SwiftData save failures are intentionally swallowed.
     */
    private func applyStrongsMode(_ mode: Int) {
        let targetWindow = windowManager.activeWindow
        let previousWindowSettings = resolvedDisplaySettings(for: targetWindow)
        var nextWindowSettings = previousWindowSettings
        nextWindowSettings.strongsMode = mode
        persistWindowDisplaySettings(
            nextWindowSettings,
            for: targetWindow,
            previousResolvedSettings: previousWindowSettings
        )
    }

    /**
     Toggles one optional Boolean text-display field for the active window.

     - Parameters:
       - keyPath: Writable `TextDisplaySettings` field to flip.
       - defaultValue: Effective fallback used when the current value is unset.
     - Side effects: Persists the updated field through the window-scope settings helper and
       refreshes the affected pane.
     - Failure modes: Missing active window results in an in-memory refresh only.
     */
    private func toggleDisplaySetting(
        _ keyPath: WritableKeyPath<TextDisplaySettings, Bool?>,
        default defaultValue: Bool
    ) {
        let targetWindow = windowManager.activeWindow
        let previousWindowSettings = resolvedDisplaySettings(for: targetWindow)
        let currentValue = previousWindowSettings[keyPath: keyPath] ?? defaultValue
        var nextWindowSettings = previousWindowSettings
        nextWindowSettings[keyPath: keyPath] = !currentValue
        persistWindowDisplaySettings(
            nextWindowSettings,
            for: targetWindow,
            previousResolvedSettings: previousWindowSettings
        )
    }

    /**
     Resolves one Android overflow-menu title with an optional iOS-localized fallback key.

     - Parameters:
       - androidKey: Android-parity string identifier when present in the main bundle.
       - fallbackKey: Optional iOS localization key used when the Android key is absent locally.
       - defaultValue: English fallback used when neither key exists.
     - Returns: The best available localized overflow-menu title.
     */
    private func localizedAndroidOverflowString(
        androidKey: String,
        fallbackKey: String?,
        default defaultValue: String
    ) -> String {
        let androidValue = Bundle.main.localizedString(forKey: androidKey, value: nil, table: nil)
        if androidValue != androidKey {
            return androidValue
        }
        if let fallbackKey {
            return Bundle.main.localizedString(forKey: fallbackKey, value: defaultValue, table: nil)
        }
        return defaultValue
    }

    /**
     Persists one window-scope All Text Options value and refreshes that pane.

     This mirrors Android's `SettingsLevel.WINDOW`: the edited value is stored on the target
     `PageManager`, while matching parent values are cleared so workspace/global inheritance still
     works. Theme colors are only stored when the window already owned color overrides or the user
     changed a color during this edit.

     - Parameters:
       - windowSettings: Effective window-level settings from the editor.
       - window: Target window whose page manager should receive overrides.
       - previousResolvedSettings: Effective window settings before this mutation.
     - Side effects:
       - mutates `window.pageManager.textDisplaySettings`
       - attempts a SwiftData save
       - refreshes the target reader controller and active toolbar settings
     - Failure modes: Missing target window or page manager causes an in-memory refresh only;
       SwiftData save failures are swallowed to match surrounding persistence helpers.
     */
    private func persistWindowDisplaySettings(
        _ windowSettings: TextDisplaySettings,
        for window: Window?,
        previousResolvedSettings: TextDisplaySettings
    ) {
        guard let window,
              let pageManager = window.pageManager else {
            syncActiveDisplaySettings()
            reloadBehaviorPreferences()
            return
        }

        let parentSettings = TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: window.workspace?.textDisplaySettings ?? windowManager.activeWorkspace?.textDisplaySettings,
            global: globalDisplaySettings
        )
        let hadWindowThemeColors = pageManager.textDisplaySettings?.hasThemeColorOverrides ?? false
        let changedThemeColors = Self.themeColorsDiffer(windowSettings, previousResolvedSettings)
        let shouldPersistThemeColors = hadWindowThemeColors || changedThemeColors
        var windowScopedSettings = windowSettings
        if !shouldPersistThemeColors {
            windowScopedSettings.clearThemeColors()
        }
        _ = windowScopedSettings.clearRedundantOverrides(matching: parentSettings)
        if shouldPersistThemeColors {
            windowScopedSettings.restoreThemeColors(from: windowSettings)
        }

        pageManager.textDisplaySettings = windowScopedSettings
        try? modelContext.save()

        let resolvedSettings = resolvedDisplaySettings(for: window)
        controller(for: window.id)?.updateDisplaySettings(resolvedSettings, nightMode: nightMode)
        if windowManager.activeWindow?.id == window.id {
            displaySettings = resolvedSettings
        }
        windowDisplaySettings = resolvedSettings
        reloadBehaviorPreferences()
    }

    /**
     Persists the target window's All Text Options editor and refreshes visible state.

     Side effects:
     - writes `windowDisplaySettings` into the captured window's page-manager overrides
     - refreshes that pane's reader controller
     - keeps the active toolbar/display state synchronized

     Failure modes:
     - if the captured window is gone, the persistence helper performs only in-memory refreshes
     */
    private func applyWindowDisplaySettingsChange() {
        let targetWindow = panePresentationTargetWindow
        let previousWindowSettings = resolvedDisplaySettings(for: targetWindow)
        persistWindowDisplaySettings(
            windowDisplaySettings,
            for: targetWindow,
            previousResolvedSettings: previousWindowSettings
        )
    }

    /**
     Persists the global Text Options editor and refreshes every visible pane.

     Android stores global text-display settings in application preferences and then clears child
     values that redundantly match the new parent. `SettingsStore` owns that propagation path on
     iOS, so this route uses the same store API as Application Preferences.

     - Side effects:
       - writes `global_text_display_settings`
       - may clear redundant workspace/window text-display overrides
       - refreshes visible reader controllers and toolbar state
     - Failure modes: SwiftData save failures are swallowed by `SettingsStore`.
     */
    private func applyGlobalDisplaySettingsChange() {
        let store = SettingsStore(modelContext: modelContext)
        store.setGlobalTextDisplaySettings(globalDisplaySettings)
        refreshVisibleControllerDisplaySettings()
        syncActiveDisplaySettings()
        reloadBehaviorPreferences()
    }

    /**
     Persists the active workspace Text Options editor and refreshes visible windows.

     Android stores workspace-level text-display settings on the workspace and clears child window
     overrides for fields that now match the workspace value. This keeps inheritance live without
     erasing window-specific overrides that intentionally differ from the workspace.

     - Side effects:
       - mutates `Workspace.textDisplaySettings`
       - may clear redundant child `PageManager.textDisplaySettings` values
       - attempts a SwiftData save
       - refreshes visible reader controllers and toolbar state
     - Failure modes: Missing active workspace produces only an in-memory state sync; SwiftData save
       failures are swallowed to match surrounding persistence helpers.
     */
    private func applyWorkspaceDisplaySettingsChange() {
        let targetWorkspace = panePresentationTargetWindow?.workspace ?? windowManager.activeWorkspace
        guard let workspace = targetWorkspace else {
            syncActiveDisplaySettings()
            reloadBehaviorPreferences()
            return
        }

        let previousWorkspaceSettings = resolvedWorkspaceDisplaySettings(for: workspace)
        workspace.textDisplaySettings = WorkspaceTextDisplaySettingsPropagation.workspaceScopedSettings(
            editorSettings: workspaceDisplaySettings,
            previousResolvedSettings: previousWorkspaceSettings,
            existingWorkspaceSettings: workspace.textDisplaySettings,
            globalSettings: globalDisplaySettings
        )

        let currentWorkspaceParentSettings = TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: workspace.textDisplaySettings,
            global: globalDisplaySettings
        )
        for window in workspace.windows ?? [] {
            guard let windowSettings = window.pageManager?.textDisplaySettings else {
                continue
            }
            let propagatedSettings = WorkspaceTextDisplaySettingsPropagation.windowSettingsAfterWorkspaceChange(
                windowSettings,
                currentWorkspaceParentSettings: currentWorkspaceParentSettings,
                previousWorkspaceSettings: previousWorkspaceSettings,
                currentWorkspaceEditorSettings: workspaceDisplaySettings
            )
            if propagatedSettings != windowSettings {
                window.pageManager?.textDisplaySettings = propagatedSettings
            }
        }

        try? modelContext.save()
        refreshVisibleControllerDisplaySettings()
        syncActiveDisplaySettings()
        reloadBehaviorPreferences()
    }

    /**
     Refreshes reader controllers after root Application Preferences mutate app-level settings.

     Android exposes Global Text Options from Application Preferences. iOS mirrors that route, so
     this callback reloads the structured global text-display defaults before re-resolving each
     pane. Other root settings still flow through the behavior-preference reload below.

     - Side effects:
       - reloads `global_text_display_settings` from `SettingsStore`
       - pushes each visible reader its resolved display settings and app preference payload
       - reloads behavior preferences mirrored by the SwiftUI reader shell
     - Failure modes: Reader refresh failures are handled by the controller update paths; preference
       reloads fall back through `SettingsStore` defaults.
     */
    private func applyApplicationPreferenceChange() {
        let store = SettingsStore(modelContext: modelContext)
        globalDisplaySettings = store.globalTextDisplaySettings()
        refreshVisibleControllerDisplaySettings()
        syncActiveDisplaySettings()
        reloadBehaviorPreferences()
    }

    /// Resolves text-display settings for one specific window using the normal inheritance chain.
    private func resolvedDisplaySettings(for window: Window?) -> TextDisplaySettings {
        TextDisplaySettings.fullyResolved(
            window: window?.pageManager?.textDisplaySettings,
            workspace: window?.workspace?.textDisplaySettings ?? windowManager.activeWorkspace?.textDisplaySettings,
            global: globalDisplaySettings
        )
    }

    /// Resolves text-display settings for a workspace using global defaults but no window values.
    private func resolvedWorkspaceDisplaySettings(for workspace: Workspace?) -> TextDisplaySettings {
        TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: workspace?.textDisplaySettings ?? windowManager.activeWorkspace?.textDisplaySettings,
            global: globalDisplaySettings
        )
    }

    /// Re-syncs the focused toolbar/settings state from the current active window.
    private func syncActiveDisplaySettings() {
        displaySettings = resolvedDisplaySettings(for: windowManager.activeWindow)
        workspaceDisplaySettings = resolvedWorkspaceDisplaySettings(
            for: panePresentationTargetWindow?.workspace ?? windowManager.activeWorkspace
        )
        windowDisplaySettings = resolvedDisplaySettings(for: panePresentationTargetWindow ?? windowManager.activeWindow)
    }

    /**
     Compares the day/night theme color tuple between two display settings values.

     - Parameters:
       - lhs: First display settings value.
       - rhs: Second display settings value.
     - Returns: `true` when any theme color or noise field differs.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private static func themeColorsDiffer(
        _ lhs: TextDisplaySettings,
        _ rhs: TextDisplaySettings
    ) -> Bool {
        lhs.dayTextColor != rhs.dayTextColor ||
            lhs.dayBackground != rhs.dayBackground ||
            lhs.dayNoise != rhs.dayNoise ||
            lhs.nightTextColor != rhs.nightTextColor ||
            lhs.nightBackground != rhs.nightBackground ||
            lhs.nightNoise != rhs.nightNoise
    }

    /// Refreshes each visible reader pane using that pane's own resolved display settings.
    private func refreshVisibleControllerDisplaySettings() {
        for window in windowManager.visibleWindows {
            if let ctrl = controller(for: window.id) {
                ctrl.updateDisplaySettings(resolvedDisplaySettings(for: window), nightMode: nightMode)
            }
        }
    }

    /// Resolved toolbar gesture mode for the Bible and commentary buttons.
    private var toolbarActionsMode: ToolbarButtonActionsMode {
        ToolbarButtonActionsMode(rawValue: toolbarButtonActionsMode) ?? .defaultMode
    }

    /**
     Handles a primary tap on the Bible toolbar button using the Android-parity gesture mode.

     - Parameter controller: Focused pane controller, if one is currently registered.
     */
    private func handleBibleToolbarTap(_ controller: BibleReaderController?) {
        switch toolbarActionsMode {
        case .defaultMode:
            performBibleMenuAction(controller)
        case .swapMenu, .swapActivity:
            performBibleNextDocumentAction(controller)
        }
    }

    /**
     Handles a long press on the Bible toolbar button using the Android-parity gesture mode.

     - Parameter controller: Focused pane controller, if one is currently registered.
     */
    private func handleBibleToolbarLongPress(_ controller: BibleReaderController?) {
        switch toolbarActionsMode {
        case .swapMenu:
            performBibleMenuAction(controller)
        case .defaultMode, .swapActivity:
            performBibleChooserAction()
        }
    }

    /**
     Handles a primary tap on the commentary toolbar button using the Android-parity gesture mode.

     - Parameter controller: Focused pane controller, if one is currently registered.
     */
    private func handleCommentaryToolbarTap(_ controller: BibleReaderController?) {
        switch toolbarActionsMode {
        case .defaultMode:
            performCommentaryMenuAction(controller)
        case .swapMenu, .swapActivity:
            performCommentaryNextDocumentAction(controller)
        }
    }

    /**
     Handles a long press on the commentary toolbar button using the Android-parity gesture mode.

     - Parameter controller: Focused pane controller, if one is currently registered.
     */
    private func handleCommentaryToolbarLongPress(_ controller: BibleReaderController?) {
        switch toolbarActionsMode {
        case .swapMenu:
            performCommentaryMenuAction(controller)
        case .defaultMode, .swapActivity:
            performCommentaryChooserAction()
        }
    }

    /**
     Handles the Android `menuForDocs` Bible action.

     When exactly two Bible modules are installed, this mirrors Android's auto-cycle shortcut.
     Every other non-empty module list shows the compact anchored popup instead of the full document
     picker sheet.

     - Parameter controller: Focused pane controller, if one is currently registered.
     */
    private func performBibleMenuAction(_ controller: BibleReaderController?) {
        guard let controller else { return }
        switch BibleReaderQuickModuleSelectorPresentation.action(
            for: controller.installedBibleModules,
            activeModuleName: currentBibleQuickSelectorModuleName(for: controller)
        ) {
        case .none:
            return
        case .switchDirectly(let nextName):
            controller.switchBibleDocument(to: nextName)
        case .showPopup:
            presentBibleQuickSelector(controller)
        }
    }

    /**
     Presents the Bible module chooser.

     - Note: This is the SwiftUI-sheet equivalent of Android's document chooser activity.
     */
    private func performBibleChooserAction() {
        presentModulePicker(.bible, from: windowManager.activeWindow?.id)
    }

    /**
     Cycles to the next Bible module or switches back into Bible mode.

     - Parameter controller: Focused pane controller, if one is currently registered.
     */
    private func performBibleNextDocumentAction(_ controller: BibleReaderController?) {
        guard let controller else { return }
        if controller.currentCategory != .bible {
            controller.switchCategory(to: .bible)
            return
        }
        cycleToNextModule(
            modules: controller.installedBibleModules,
            activeName: controller.activeModuleName
        ) { nextName in
            controller.switchBibleDocument(to: nextName)
        }
    }

    /**
     Handles the Android `menuForDocs` commentary action.

     When exactly two commentary modules are installed, this mirrors Android's auto-cycle
     shortcut. Otherwise it opens the commentary picker sheet.

     - Parameter controller: Focused pane controller, if one is currently registered.
     */
    private func performCommentaryMenuAction(_ controller: BibleReaderController?) {
        guard let controller else {
            performCommentaryChooserAction()
            return
        }
        if controller.installedCommentaryModules.count == 2 {
            cycleToNextModule(
                modules: controller.installedCommentaryModules,
                activeName: controller.activeCommentaryModuleName
            ) { nextName in
                controller.switchCommentaryModule(to: nextName)
                controller.switchCategory(to: .commentary)
            }
            return
        }
        performCommentaryChooserAction()
    }

    /**
     Presents the commentary module chooser.

     - Note: This is the SwiftUI-sheet equivalent of Android's document chooser activity.
     */
    private func performCommentaryChooserAction() {
        presentModulePicker(.commentary, from: windowManager.activeWindow?.id)
    }

    /**
     Cycles to the next commentary module or switches back into commentary mode.

     - Parameter controller: Focused pane controller, if one is currently registered.
     */
    private func performCommentaryNextDocumentAction(_ controller: BibleReaderController?) {
        guard let controller else { return }
        if controller.currentCategory != .commentary {
            if controller.activeCommentaryModuleName == nil {
                performCommentaryChooserAction()
            } else {
                controller.switchCategory(to: .commentary)
            }
            return
        }
        cycleToNextModule(
            modules: controller.installedCommentaryModules,
            activeName: controller.activeCommentaryModuleName
        ) { nextName in
            controller.switchCommentaryModule(to: nextName)
            controller.switchCategory(to: .commentary)
        }
    }

    /**
     Advances to the next module in a category, wrapping to the first module when needed.

     - Parameters:
       - modules: Ordered modules available for the active category.
       - activeName: Name of the currently selected module, if any.
       - apply: Closure that switches the controller to the resolved next module name.
     */
    private func cycleToNextModule(
        modules: [ModuleInfo],
        activeName: String?,
        apply: (String) -> Void
    ) {
        guard !modules.isEmpty else { return }
        guard modules.count > 1 else { return }

        if let activeName,
           let index = modules.firstIndex(where: { $0.name == activeName }) {
            let next = modules[(index + 1) % modules.count]
            apply(next.name)
        } else if let first = modules.first {
            apply(first.name)
        }
    }

    /**
     Reloads behavior-related preferences after the settings sheet changes persisted values.

     Side effects:
     - reads multiple persisted values from `SettingsStore`
     - mutates reader-coordinator state for navigation, fullscreen, toolbar, and language/night-mode behavior
     - recalculates effective `nightMode` from persisted settings plus the current system color scheme
     - forwards the updated behavior configuration to `speakService`
     */
    private func reloadBehaviorPreferences() {
        let store = SettingsStore(modelContext: modelContext)
        navigateToVersePref = store.getBool(.navigateToVersePref)
        autoFullscreenPref = store.getBool(.autoFullscreenPref)
        disableTwoStepBookmarkingPref = store.getBool(.disableTwoStepBookmarking)
        toolbarButtonActionsMode = store.getString(.toolbarButtonActions)
        bibleViewSwipeMode = store.getString(.bibleViewSwipeMode)
        fullScreenHideButtonsPref = store.getBool(.fullScreenHideButtonsPref)
        hideWindowButtonsPref = store.getBool(.hideWindowButtons)
        hideBibleReferenceOverlayPref = store.getBool(.hideBibleReferenceOverlay)
        nightModeMode = store.getString(.nightModePref3)
        let manualNightMode = store.getBool("night_mode")
        nightMode = NightModeSettingsResolver.isNightMode(
            rawValue: nightModeMode,
            manualNightMode: manualNightMode,
            systemIsDark: colorScheme == .dark
        )
        speakService.applyBehaviorPreferences()
    }

    /// Clears accumulated scroll-direction state for auto-fullscreen tracking.
    private func resetAutoFullscreenTracking() {
        autoFullscreenTracking.reset()
    }

    /**
     Applies Android-style auto-fullscreen behavior to user-driven vertical scrolling.

     - Parameters:
       - window: Pane whose native scroll delta triggered the callback.
       - deltaY: Signed vertical scroll delta reported by the embedded web view.
     - Side effects: Mutates auto-fullscreen tracking state, may reset accumulated scroll distance,
       and may animate `isFullScreen` on or off.
     - Failure modes: Returns without changing fullscreen when the event did not originate from the
       active window, auto-fullscreen is disabled, the delta is zero, or fullscreen is currently
       locked by a prior double-tap action.
     */
    private func handleAutoFullscreenScroll(from window: Window, deltaY: Double) {
        guard windowManager.activeWindow?.id == window.id else { return }
        let action = ReaderAutoFullscreenPolicy.action(
            deltaY: deltaY,
            isEnabled: autoFullscreenPref,
            isFullScreen: isFullScreen,
            fullscreenLockedByDoubleTap: lastFullScreenByDoubleTap,
            tracking: &autoFullscreenTracking
        )

        switch action {
        case .enterFullscreen:
            withAnimation(.easeInOut(duration: 0.2)) { isFullScreen = true }
        case .exitFullscreen:
            withAnimation(.easeInOut(duration: 0.2)) { isFullScreen = false }
        case .none:
            break
        }
    }

    /**
     Requests dismissal of a Vue modal in the currently focused pane.

     - Returns: `true` when the focused controller reported an open Vue modal and received a
       `close_modals` event request; otherwise `false`.

     Side effects:
     - may emit a `close_modals` event into the focused pane's web bridge

     Failure modes:
     - returns `false` when no pane is focused or the focused pane has no open Vue modal
     - blocking Vue modals may remain open and report their final state later
     */
    @discardableResult
    private func closeFocusedWebModalIfNeeded() -> Bool {
        focusedController?.closeWebModalIfNeeded() ?? false
    }

    /**
     Runs previous-chapter navigation only when the pane is not owned by a Vue modal.

     - Parameter controller: Focused or header-captured reader controller for the pane requesting
       navigation.

     Side effects:
     - calls `navigatePrevious()` on the controller when host navigation is allowed

     Failure modes:
     - returns without action when no controller is available or the controller reports an open
       Vue modal
     */
    private func navigatePreviousIfReaderCanHostNavigate(_ controller: BibleReaderController?) {
        guard let controller, !controller.webModalIsOpen else { return }
        controller.navigatePrevious()
    }

    /**
     Runs next-chapter navigation only when the pane is not owned by a Vue modal.

     - Parameter controller: Focused or header-captured reader controller for the pane requesting
       navigation.

     Side effects:
     - calls `navigateNext()` on the controller when host navigation is allowed

     Failure modes:
     - returns without action when no controller is available or the controller reports an open
       Vue modal
     */
    private func navigateNextIfReaderCanHostNavigate(_ controller: BibleReaderController?) {
        guard let controller, !controller.webModalIsOpen else { return }
        controller.navigateNext()
    }

    /**
     Dispatches horizontal swipe gestures according to the configured Bible swipe mode.

     - Parameters:
       - window: Pane whose native swipe gesture triggered the callback.
       - direction: Swipe direction detected by the native web-view wrapper.
     - Side effects: May trigger chapter navigation through the focused `BibleReaderController` or
       emit page-scroll commands into the active web view.
     - Failure modes: Returns without action when the gesture did not originate from the active
       window, no focused controller is registered, an in-page text selection is active, the Vue
       client reports an open modal, or the configured swipe mode is `.none`.
     */
    private func handleHorizontalSwipe(from window: Window, direction: NativeHorizontalSwipeDirection) {
        guard windowManager.activeWindow?.id == window.id else { return }
        guard let ctrl = windowManager.controllers[window.id] as? BibleReaderController else { return }
        switch ReaderHorizontalSwipePolicy.action(
            modeRawValue: bibleViewSwipeMode,
            direction: direction,
            hasActiveSelection: ctrl.hasActiveSelection,
            hasOpenModal: ctrl.webModalIsOpen
        ) {
        case .navigateNextChapter:
            ctrl.navigateNext()
        case .navigatePreviousChapter:
            ctrl.navigatePrevious()
        case .scrollPageDown:
            ctrl.scrollPageDown()
        case .scrollPageUp:
            ctrl.scrollPageUp()
        case .none:
            return
        }
    }

    /**
     Presents Search after first staging the latest initial-query state.

     Side effects:
     - mutates `searchInitialQuery` so the sheet can seed its query field from the latest caller
     - schedules `showSearch = true` for the next main-actor turn so the staged query wins over
       the current render pass

     Failure modes:
     - uses an asynchronous handoff, so callers should not assume the sheet is visible until the
       next render pass completes
     */
    @MainActor
    private func presentSearch(from windowId: UUID? = nil, initialQuery: String? = nil) {
        setPanePresentationTarget(windowId)
        searchLastUsed = Date().timeIntervalSince1970
        if let initialQuery {
            searchInitialQuery = initialQuery
        } else if let uiTestQuery = UITestSearchQuerySeed.consume() {
            searchInitialQuery = uiTestQuery
        } else {
            searchInitialQuery = ""
        }
        Task { @MainActor in
            await Task.yield()
            showSearch = true
        }
    }

    /// Auto-presents Search once on launch when UI tests seed a query through app launch metadata.
    @MainActor
    private func presentUITestLaunchSearchIfNeeded() {
        guard !didPresentUITestLaunchSearch,
              let launchQuery = UITestSearchQuerySeed.consume() else {
            return
        }

        didPresentUITestLaunchSearch = true
        presentSearch(from: windowManager.activeWindow?.id, initialQuery: launchQuery)
    }

    #if os(iOS)
    /// Start tilt-to-scroll by wiring CoreMotion to the focused WebView.
    private func startTiltToScroll() {
        tiltScrollService.onScroll = { [weak windowManager] pixels in
            guard let wm = windowManager,
                  let activeId = wm.activeWindow?.id,
                  let ctrl = wm.controllers[activeId] as? BibleReaderController else { return }
            ctrl.bridge.webView?.evaluateJavaScript("window.scrollBy(0, \(pixels))", completionHandler: nil)
        }
        tiltScrollService.start()
    }
    #endif
}

/**
 Snapshot-backed passage chooser progress context.

 `BibleReaderView` builds this once when presenting Android-style passage chooser content. The grid
 may ask for progress many times while SwiftUI renders or re-renders cells, so this type keeps the
 persisted reading and memorization snapshots stable for that presentation and delegates the actual
 Android-compatible calculations to `PassageGridProgressCalculator`.
 */
private struct PassageChooserProgressContext {
    /// Empty context used before a chooser presentation captures active pane snapshots.
    static let empty = PassageChooserProgressContext(
        readingSnapshot: nil,
        memorizationSnapshot: nil,
        activeBookInitials: ""
    )

    /// Current reading progress snapshot for the active pane, if available.
    let readingSnapshot: ReadingProgressSnapshot?

    /// Current memorization progress snapshot for the active pane, if available.
    let memorizationSnapshot: MemorizationProgressSnapshot?

    /// Active module initials used to match Android/iOS memorization rows.
    let activeBookInitials: String

    /**
     Computes book-level progress from the captured snapshots.

     - Parameter book: Visible book cell from the active module's book list.
     - Returns: Android-compatible reading and memorization progress.
     - Side effects: none.
     - Failure modes: Missing snapshots or unsupported books produce empty progress.
     */
    func bookProgress(for book: BookInfo) -> PassageGridProgress {
        PassageGridProgressCalculator.bookProgress(
            book: book,
            readingSnapshot: readingSnapshot,
            memorizationSnapshot: memorizationSnapshot,
            activeBookInitials: activeBookInitials
        )
    }

    /**
     Computes chapter-level progress from the captured snapshots.

     - Parameters:
       - book: Selected book from the active module's book list.
       - chapter: One-based chapter number.
     - Returns: Android-compatible reading and memorization progress.
     - Side effects: none.
     - Failure modes: Missing snapshots or unsupported chapters produce empty progress.
     */
    func chapterProgress(for book: BookInfo, chapter: Int) -> PassageGridProgress {
        PassageGridProgressCalculator.chapterProgress(
            book: book,
            chapter: chapter,
            readingSnapshot: readingSnapshot,
            memorizationSnapshot: memorizationSnapshot,
            activeBookInitials: activeBookInitials
        )
    }

    /**
     Computes verse-level progress from the captured snapshots.

     - Parameters:
       - book: Selected book from the active module's book list.
       - chapter: One-based chapter number.
       - verse: One-based verse number.
     - Returns: Android-compatible reading and memorization progress.
     - Side effects: none.
     - Failure modes: Missing snapshots or unsupported verses produce empty progress.
     */
    func verseProgress(for book: BookInfo, chapter: Int, verse: Int) -> PassageGridProgress {
        PassageGridProgressCalculator.verseProgress(
            book: book,
            chapter: chapter,
            verse: verse,
            readingSnapshot: readingSnapshot,
            memorizationSnapshot: memorizationSnapshot,
            activeBookInitials: activeBookInitials
        )
    }
}

/**
 Presents an explicit pane-readiness state for reader modals that require a registered controller.

 `BibleReaderView` shows this instead of constructing picker/browser content with a missing
 controller. That keeps opening/unavailable pane lifecycle separate from genuine empty document
 module states.
 */
private struct ReaderPanePreparationView: View {
    /// Whether the target window is visible and expected to register a controller shortly.
    let isPending: Bool

    /// Dismisses the owning reader modal when the user leaves the readiness state.
    let onDismiss: () -> Void

    /**
     Builds the modal surface for a pane that is pending or no longer available.

     - Returns: Navigation-wrapped content with an optional spinner while registration is expected.
     - Side Effects: The Done toolbar action calls `onDismiss`.
     - Failure Modes: None; this view is intentionally static until parent state changes.
     */
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if isPending {
                    ProgressView()
                } else {
                    Image(systemName: "exclamationmark.circle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(String(localized: "choose_document", defaultValue: "Choose Document"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done"), action: onDismiss)
                }
            }
        }
    }

    /// Primary readiness text shown to the user.
    private var title: String {
        if isPending {
            return String(localized: "reader_pane_preparing_title", defaultValue: "Preparing reader")
        }
        return String(localized: "reader_pane_unavailable_title", defaultValue: "Reader unavailable")
    }

    /// Secondary readiness text shown to the user.
    private var message: String {
        if isPending {
            return String(
                localized: "reader_pane_preparing_message",
                defaultValue: "The selected pane is still opening."
            )
        }
        return String(
            localized: "reader_pane_unavailable_message",
            defaultValue: "The selected pane is no longer available."
        )
    }
}

/// Applies the compact reader state to early reader chrome only for UI automation.
private struct ReaderRenderedContentStateAccessibilityModifier: ViewModifier {
    let value: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
            content.accessibilityValue(value)
        } else {
            content
        }
    }
}

private extension View {
    func readerRenderedContentStateAccessibilityValue(_ value: String) -> some View {
        modifier(ReaderRenderedContentStateAccessibilityModifier(value: value))
    }
}

/**
 Strong's number display modes matching Android's `strongsModeEntries`.

 Vue.js config values: off=`0`, inline=`1`, links=`2`, hidden=`3`.
 */
enum StrongsMode: Int, CaseIterable, Identifiable {
    /// Hide Strong's numbers entirely.
    case off = 0

    /// Render Strong's numbers inline in the verse text.
    case inline = 1

    /// Render Strong's numbers as tappable links only.
    case links = 2

    /// Keep Strong's data available while suppressing visible markers in the text flow.
    case hidden = 3

    /// Stable raw-value identifier for `ForEach` and menu construction.
    var id: Int { rawValue }

    /// Localized label shown in the Strong's display-mode menu.
    var label: String {
        switch self {
        case .off: String(localized: "strongs_off")
        case .inline: String(localized: "strongs_inline")
        case .links: String(localized: "strongs_links")
        case .hidden: String(localized: "strongs_hidden")
        }
    }
}

/// Gesture mappings for the Bible and commentary toolbar buttons.
private enum ToolbarButtonActionsMode: String {
    /// Tap opens the menu and long press opens the chooser.
    case defaultMode = "default"

    /// Tap advances to the next document and long press opens the menu.
    case swapMenu = "swap-menu"

    /// Tap advances to the next document and long press opens the chooser.
    case swapActivity = "swap-activity"
}
