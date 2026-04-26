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

#if os(iOS)
/**
 Presents `CompareView` from UIKit instead of SwiftUI sheet state.

 This entry point is used by bridge-driven actions that originate from the embedded WKWebView,
 where no SwiftUI view state mutation hook is available at the call site.

 - Parameters:
   - book: User-visible book name for the comparison session.
   - chapter: One-based chapter number to compare.
   - currentModuleName: Active Bible module that should anchor the comparison.
   - startVerse: Optional starting verse for range-limited comparisons.
   - endVerse: Optional ending verse for range-limited comparisons.
   - osisBookId: Optional OSIS book identifier when the caller already resolved it.
 - Important: This function walks UIKit presentation state and presents a page sheet from the
   top-most view controller. It should only be called on iOS.
 - Failure modes: If no active `UIWindowScene` or root view controller is available, the function
   returns without presenting anything.
 */
func presentCompareView(book: String, chapter: Int, currentModuleName: String, startVerse: Int? = nil, endVerse: Int? = nil, osisBookId: String? = nil) {
    guard let windowScene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).first,
          let rootVC = windowScene.windows.first?.rootViewController else { return }

    var topVC = rootVC
    while let presented = topVC.presentedViewController {
        topVC = presented
    }

    let content = CompareView(book: book, chapter: chapter, currentModuleName: currentModuleName, startVerse: startVerse, endVerse: endVerse, resolvedOsisBookId: osisBookId)
    let hostingVC = UIHostingController(rootView: NavigationStack { content })
    hostingVC.modalPresentationStyle = .pageSheet
    if let sheet = hostingVC.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    topVC.present(hostingVC, animated: true)
}

// Label assignment is now presented via SwiftUI .sheet() in BibleWindowPane
// (no UIKit hosting needed — avoids gesture/toolbar conflicts)
#else
/**
 No-op macOS placeholder for UIKit-only compare-sheet presentation requests.

 - Parameters:
   - book: Ignored on macOS.
   - chapter: Ignored on macOS.
   - currentModuleName: Ignored on macOS.
   - startVerse: Ignored on macOS.
   - endVerse: Ignored on macOS.
   - osisBookId: Ignored on macOS.
 - Note: Compare presentation on macOS is currently handled through native SwiftUI paths only.
 */
func presentCompareView(book: String, chapter: Int, currentModuleName: String, startVerse: Int? = nil, endVerse: Int? = nil, osisBookId: String? = nil) {
    // macOS: no-op for now
}
// Label assignment presented via SwiftUI .sheet() in BibleWindowPane (cross-platform)
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
    private enum ReaderSheet: String, Identifiable {
        case bookmarks
        case settings
        case downloads
        case history
        case readingPlans
        case workspaces
        case about

        var id: String { rawValue }
    }

    /// Internal reader-overflow destinations that should run only after the overflow sheet dismisses.
    private enum ReaderOverflowPresentation {
        case labelManager
        case compare
        case bookmarks
        case history
        case readingPlans
        case settings
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

    /// Presents the full-text search sheet for the focused module.
    @State private var showSearch = false

    /// Presents the current top-level reader sheet driven by the overflow menu and shortcuts.
    @State private var activeReaderSheet: ReaderSheet?

    /// Presents the reader's overflow action sheet.
    @State private var showReaderOverflowMenu = false

    /// Presents the Android-style left navigation drawer from the reader header.
    @State private var showReaderNavigationDrawer = false

    /// Presents the Android-style Strong's mode chooser launched from the overflow menu.
    @State private var showReaderStrongsModeDialog = false

    /// Queues one follow-up presentation until the reader overflow sheet finishes dismissing.
    @State private var pendingReaderOverflowPresentation: ReaderOverflowPresentation?

    /// Queues one side-effect-only reader overflow action until the sheet finishes dismissing.
    @State private var pendingReaderOverflowCallback: (() -> Void)?

    /// Presents the sync settings editor directly for focused workflow testing.
    @State private var showSyncSettings = false

    /// Presents the text-display editor directly for focused workflow testing.
    @State private var showTextDisplaySettings = false

    /// Presents the color-settings editor directly for focused workflow testing.
    @State private var showColorSettings = false

    /// Presents import and export management UI.
    @State private var showImportExport = false



    /// Presents the compare-translations sheet.
    @State private var showCompare = false


    /// Presents the expanded speech controls sheet.
    @State private var showSpeakControls = false

    /// Last search-toolbar activation timestamp used to mirror Android button prioritization.
    @AppStorage("search-last-used") private var searchLastUsed = 0.0

    /// Last speak-toolbar activation timestamp used to mirror Android button prioritization.
    @AppStorage("speak-last-used") private var speakLastUsed = 0.0

    /// Text and color settings resolved for the currently active pane and toolbar state.
    @State private var displaySettings: TextDisplaySettings = .appDefaults

    /// App-level text-display defaults edited from the full Application Settings flow.
    @State private var globalDisplaySettings: TextDisplaySettings = .appDefaults

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

    /// Presents the document-category-specific module picker.
    @State private var showModulePicker = false

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

    /// Cached scroll direction used to accumulate auto-fullscreen distance per direction.
    @State private var autoFullscreenDirectionDown: Bool?

    /// Accumulated user scroll distance toward the auto-fullscreen threshold.
    @State private var autoFullscreenDistance: Double = 0

    /// Presents the dictionary key browser for the active dictionary module.
    @State private var showDictionaryBrowser = false

    /// Presents the general-book key browser for the active general-book module.
    @State private var showGeneralBookBrowser = false

    /// Presents the map browser for the active map module.
    @State private var showMapBrowser = false

    /// Presents the EPUB library chooser.
    @State private var showEpubLibrary = false

    /// Presents the current EPUB table-of-contents browser.
    @State private var showEpubBrowser = false

    /// Presents EPUB full-text search UI.
    @State private var showEpubSearch = false

    /// Initial query forwarded into `SearchView`, usually from Strong's lookups.
    @State private var searchInitialQuery = ""

    /// Window that owns the currently presented pane-scoped sheet or chooser flow.
    @State private var panePresentationTargetWindowId: UUID?

    /// Ensures the launch-seeded UI-test Search sheet is only auto-presented once per app session.
    @State private var didPresentUITestLaunchSearch = false

    /// Presents label-management UI from the toolbar ellipsis menu.
    @State private var showLabelManager = false

    /// Presents the in-app help and tips screen.
    @State private var showHelp = false

    /// Presents the StudyPad label selector from the Android-style drawer.
    @State private var showStudyPadSelector = false

    /// Presents the Android-style choose-document surface from the drawer.
    @State private var showChooseDocumentSheet = false


    /// Presents the reference chooser used by bridge-driven dialogs.
    @State private var showRefChooser = false

    /// Completion callback for the bridge-driven reference chooser flow.
    @State private var refChooserCompletion: ((String?) -> Void)?
    #if os(iOS)
    /// Motion-driven scroll helper used when tilt-to-scroll is enabled for the workspace.
    @State private var tiltScrollService = TiltScrollService()
    #endif

    /// Minimum cumulative scroll distance before auto-fullscreen toggles the reader chrome.
    private let autoFullscreenScrollThreshold: Double = 56.0

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

    /// Controller that owns the currently presented pane-scoped modal flow.
    private var panePresentationController: BibleReaderController? {
        if let panePresentationTargetWindowId,
           let targetController = controller(for: panePresentationTargetWindowId) {
            return targetController
        }
        return focusedController
    }

    /// Captures the window that should own the next pane-scoped presentation.
    private func setPanePresentationTarget(_ windowId: UUID?) {
        panePresentationTargetWindowId = windowId ?? windowManager.activeWindow?.id
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
        let contentToken = focusedController?.renderedContentState
            ?? BibleReaderController.emptyRenderedContentState
        let strongsMode = resolvedDisplaySettings(for: windowManager.activeWindow).strongsMode
            ?? TextDisplaySettings.appDefaults.strongsMode
            ?? 0
        let drawerToken = "drawerVisible=\(showReaderNavigationDrawer ? "true" : "false")"
        let overflowToken = "overflowVisible=\(showReaderOverflowMenu ? "true" : "false")"
        let sheetToken = "readerSheet=\(activeReaderSheet?.rawValue ?? "none")"
        let searchToken = "searchVisible=\(showSearch ? "true" : "false")"
        return "\(windowToken);\(contentToken);strongsMode=\(strongsMode);\(drawerToken);\(overflowToken);\(sheetToken);\(searchToken)"
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

    /// Whether the floating fullscreen Bible reference capsule should be displayed.
    private var shouldShowBibleReferenceOverlay: Bool {
        isFullScreen &&
            !hideBibleReferenceOverlayPref &&
            focusedController?.currentCategory == .bible
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
        VStack(spacing: 0) {
            // Document header bar — hidden in fullscreen mode
            if !isFullScreen {
                documentHeader
            }

            // Split content — one BibleWindowPane per visible window
            splitContent

            // Persistent mini-player when speaking (visible even in fullscreen)
            if speakService.isSpeaking {
                speakMiniPlayer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Bottom window tab bar — hidden in fullscreen mode
            if shouldShowWindowTabBar {
                WindowTabBar(
                    onShowToast: { text in
                        toastWorkItem?.cancel()
                        withAnimation { toastMessage = text }
                        let work = DispatchWorkItem {
                            withAnimation { toastMessage = nil }
                        }
                        toastWorkItem = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
                    },
                    onShowBookChooser: {
                        setPanePresentationTarget(windowManager.activeWindow?.id)
                        showBookChooser = true
                    },
                    onGoToTypedRef: { window, text in
                        guard let ctrl = windowManager.controllers[window.id] as? BibleReaderController else { return false }
                        return ctrl.navigateToRef(text)
                    }
                )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFullScreen)
        .overlay(alignment: .bottom) {
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
        .overlay(alignment: .bottom) {
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
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("readerRenderedContentState")
                .accessibilityValue(readerRenderedContentStateValue)
        }
        .overlay {
            if showReaderNavigationDrawer {
                readerNavigationDrawerOverlay
            }
        }
        .overlayPreferenceValue(ReaderOverflowButtonBoundsPreferenceKey.self) { anchor in
            if showReaderOverflowMenu {
                readerOverflowMenuOverlay(anchor: anchor)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toastMessage)
        .animation(.easeInOut(duration: 0.2), value: showReaderNavigationDrawer)
        .animation(.easeInOut(duration: 0.16), value: showReaderOverflowMenu)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReaderSceneMetricsPreferenceKey.self,
                    value: ReaderSceneMetrics(size: proxy.size, safeAreaInsets: proxy.safeAreaInsets)
                )
            }
        }
        .onPreferenceChange(ReaderSceneMetricsPreferenceKey.self) { metrics in
            readerSceneMetrics = metrics
        }
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .onAppear {
            // Load persisted settings
            let store = SettingsStore(modelContext: modelContext)
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

            // Wire TTS settings persistence and restore saved speed
            speakService.settingsStore = store
            speakService.restoreSettings()

            syncActiveDisplaySettings()

            // TTS callbacks — dynamically resolve the focused controller so TTS
            // always operates on the active window (not the last-initialized pane).
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

            // Set up synchronized scrolling callback
            windowManager.onSyncVerseChanged = { [weak windowManager] sourceWindow, ordinal, key in
                guard let wm = windowManager else { return }
                let syncTargets = wm.syncedWindows(for: sourceWindow)
                    .filter { $0.id != sourceWindow.id }
                for target in syncTargets {
                    if let ctrl = wm.controllers[target.id] as? BibleReaderController {
                        // Same book+chapter: scroll to verse. Different: navigate.
                        let sourceBook = sourceWindow.pageManager?.bibleBibleBook
                        let sourceChapter = sourceWindow.pageManager?.bibleChapterNo
                        let targetBook = target.pageManager?.bibleBibleBook
                        let targetChapter = target.pageManager?.bibleChapterNo
                        if sourceBook == targetBook && sourceChapter == targetChapter {
                            ctrl.scrollToOrdinal(ordinal)
                        } else {
                            // Parse key like "Gen.3.5" to navigate
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
            }

            presentUITestLaunchSearchIfNeeded()
        }
        .onChange(of: windowManager.activeWindow?.id) { _, _ in
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
        .sheet(isPresented: $showBookChooser) {
            NavigationStack {
                BookChooserView(
                    books: panePresentationController?.bookList ?? BibleReaderController.defaultBooks,
                    navigateToVerse: navigateToVersePref
                ) { book, chapter, verse in
                    showBookChooser = false
                    panePresentationController?.navigateTo(book: book, chapter: chapter, verse: verse)
                }
            }
        }
        .sheet(isPresented: $showSearch, onDismiss: { searchInitialQuery = "" }) {
            NavigationStack {
                SearchView(
                    swordModule: panePresentationController?.activeModule,
                    swordManager: panePresentationController?.swordManager,
                    searchIndexService: searchIndexService,
                    installedBibleModules: panePresentationController?.installedBibleModules ?? [],
                    currentBook: panePresentationController?.currentBook ?? "Genesis",
                    currentOsisBookId: panePresentationController?.osisBookId(for: panePresentationController?.currentBook ?? "Genesis") ?? BibleReaderController.osisBookId(for: panePresentationController?.currentBook ?? "Genesis"),
                    initialQuery: searchInitialQuery,
                    onNavigate: { book, chapter in
                        showSearch = false
                        panePresentationController?.navigateTo(book: book, chapter: chapter)
                    }
                )
            }
        }
        .sheet(item: $activeReaderSheet) { presentedSheet in
            switch presentedSheet {
            case .bookmarks:
                NavigationStack {
                    BookmarkListView(
                        onNavigate: { book, chapter in
                            activeReaderSheet = nil
                            panePresentationController?.navigateTo(book: book, chapter: chapter)
                        },
                        onOpenStudyPad: { labelId in
                            panePresentationController?.loadStudyPadDocument(labelId: labelId)
                        }
                    )
                }
            case .settings:
                NavigationStack {
                    SettingsView(
                        displaySettings: $globalDisplaySettings,
                        nightMode: $nightMode,
                        nightModeMode: $nightModeMode,
                        onSettingsChanged: applyGlobalDisplaySettingsChange
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { activeReaderSheet = nil }
                        }
                    }
                }
            case .downloads:
                NavigationStack {
                    ModuleBrowserView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(String(localized: "done")) { activeReaderSheet = nil }
                            }
                        }
                }
            case .history:
                NavigationStack {
                    HistoryView(
                        bookNameResolver: { [weak ctrl = panePresentationController] osisId in
                            ctrl?.bookName(forOsisId: osisId)
                        }
                    ) { key in
                        activeReaderSheet = nil
                        _ = panePresentationController?.navigateToRef(key)
                    }
                }
            case .readingPlans:
                NavigationStack {
                    ReadingPlanListView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(String(localized: "done")) { activeReaderSheet = nil }
                            }
                        }
                }
            case .workspaces:
                NavigationStack {
                    WorkspaceSelectorView()
                }
            case .about:
                NavigationStack {
                    AboutView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(String(localized: "done")) { activeReaderSheet = nil }
                                    .accessibilityIdentifier("aboutDoneButton")
                            }
                        }
                }
                .accessibilityIdentifier("aboutSheetScreen")
            }
        }
        .sheet(isPresented: $showTextDisplaySettings) {
            NavigationStack {
                TextDisplaySettingsView(settings: $globalDisplaySettings, onChange: applyGlobalDisplaySettingsChange)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showTextDisplaySettings = false }
                        }
                }
            }
        }
        .sheet(isPresented: $showSyncSettings) {
            NavigationStack {
                SyncSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showSyncSettings = false }
                                .accessibilityIdentifier("syncSettingsDoneButton")
                        }
                    }
            }
        }
        .sheet(isPresented: $showColorSettings) {
            NavigationStack {
                ColorSettingsView(settings: $globalDisplaySettings, onChange: applyGlobalDisplaySettingsChange)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showColorSettings = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showImportExport) {
            NavigationStack {
                ImportExportView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showImportExport = false }
                        }
                }
            }
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
        .onChange(of: activeReaderSheet) { oldValue, newValue in
            if oldValue == .settings, newValue == nil {
                reloadBehaviorPreferences()
            }
            if oldValue == .downloads, newValue == nil {
                for (_, ctrl) in windowManager.controllers {
                    (ctrl as? BibleReaderController)?.refreshInstalledModules()
                }
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
        .sheet(isPresented: $showCompare) {
            NavigationStack {
                CompareView(
                    book: panePresentationController?.currentBook ?? "Genesis",
                    chapter: panePresentationController?.currentChapter ?? 1,
                    currentModuleName: panePresentationController?.activeModuleName ?? "",
                    resolvedOsisBookId: panePresentationController.flatMap { $0.osisBookId(for: $0.currentBook) }
                )
            }
        }
        .sheet(isPresented: $showSpeakControls) {
            SpeakControlView(speakService: speakService)
                .presentationDetents([.height(400), .large])
        }
        .sheet(isPresented: Binding(
            get: { shareText != nil },
            set: { if !$0 { shareText = nil } }
        )) {
            if let text = shareText {
                ShareSheet(items: [text])
            }
        }
        .sheet(isPresented: $showModulePicker) {
            modulePicker
        }
        .sheet(isPresented: Binding(
            get: { crossReferences != nil },
            set: { if !$0 { crossReferences = nil } }
        )) {
            if let refs = crossReferences {
                CrossReferenceView(references: refs) { book, chapter in
                    crossReferences = nil
                    panePresentationController?.navigateTo(book: book, chapter: chapter)
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showDictionaryBrowser) {
            if let module = panePresentationController?.activeDictionaryModule {
                DictionaryBrowserView(module: module) { key in
                    showDictionaryBrowser = false
                    panePresentationController?.loadDictionaryEntry(key: key)
                }
            }
        }
        .sheet(isPresented: $showGeneralBookBrowser) {
            if let module = panePresentationController?.activeGeneralBookModule {
                GeneralBookBrowserView(
                    module: module,
                    title: panePresentationController?.activeGeneralBookModuleName ?? String(localized: "general_book")
                ) { key in
                    showGeneralBookBrowser = false
                    panePresentationController?.loadGeneralBookEntry(key: key)
                }
            }
        }
        .sheet(isPresented: $showMapBrowser) {
            if let module = panePresentationController?.activeMapModule {
                GeneralBookBrowserView(
                    module: module,
                    title: panePresentationController?.activeMapModuleName ?? String(localized: "map")
                ) { key in
                    showMapBrowser = false
                    panePresentationController?.loadMapEntry(key: key)
                }
            }
        }
        .sheet(isPresented: $showEpubLibrary) {
            EpubLibraryView { identifier in
                showEpubLibrary = false
                panePresentationController?.switchEpub(identifier: identifier)
                panePresentationController?.switchCategory(to: .epub)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showEpubBrowser = true
                }
            }
        }
        .sheet(isPresented: $showEpubBrowser) {
            if let reader = panePresentationController?.activeEpubReader {
                EpubBrowserView(reader: reader) { href in
                    showEpubBrowser = false
                    panePresentationController?.loadEpubEntry(href: href)
                }
            } else {
                // No EPUB loaded — redirect to library
                EpubLibraryView { identifier in
                    showEpubBrowser = false
                    panePresentationController?.switchEpub(identifier: identifier)
                    panePresentationController?.switchCategory(to: .epub)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showEpubBrowser = true
                    }
                }
            }
        }
        .sheet(isPresented: $showEpubSearch) {
            if let reader = panePresentationController?.activeEpubReader {
                EpubSearchView(reader: reader) { href in
                    showEpubSearch = false
                    panePresentationController?.loadEpubEntry(href: href)
                }
            } else {
                // No EPUB loaded — dismiss
                Text(String(localized: "reader_no_epub_loaded"))
                    .padding()
            }
        }
        .sheet(isPresented: $showLabelManager) {
            NavigationStack {
                LabelManagerView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showLabelManager = false }
                        }
                }
            }
        }
        .sheet(isPresented: $showStudyPadSelector) {
            NavigationStack {
                LabelManagerView(onOpenStudyPad: { labelId in
                    showStudyPadSelector = false
                    panePresentationController?.loadStudyPadDocument(labelId: labelId)
                })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "done")) { showStudyPadSelector = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showChooseDocumentSheet) {
            readerChooseDocumentSheet
        }
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                HelpView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showHelp = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showRefChooser) {
            NavigationStack {
                BookChooserView(books: panePresentationController?.bookList ?? BibleReaderController.defaultBooks) { book, chapter, _ in
                    showRefChooser = false
                    let osisId = panePresentationController?.osisBookId(for: book) ?? BibleReaderController.osisBookId(for: book)
                    refChooserCompletion?("\(osisId).\(chapter)")
                    refChooserCompletion = nil
                }
            }
            .presentationDetents([.large])
        }
        // MARK: - Keyboard Shortcuts (iPad/Mac)
        .background {
            Group {
                Button("") { presentSearch(from: windowManager.activeWindow?.id) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") {
                    setPanePresentationTarget(windowManager.activeWindow?.id)
                    showBookChooser = true
                }
                    .keyboardShortcut("g", modifiers: .command)
                Button("") {
                    setPanePresentationTarget(windowManager.activeWindow?.id)
                    activeReaderSheet = .bookmarks
                }
                    .keyboardShortcut("b", modifiers: .command)
                Button("") { focusedController?.navigatePrevious() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("") { focusedController?.navigateNext() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("") {
                    setPanePresentationTarget(windowManager.activeWindow?.id)
                    activeReaderSheet = .downloads
                }
                    .keyboardShortcut("d", modifiers: .command)
                Button("") {
                    setPanePresentationTarget(windowManager.activeWindow?.id)
                    activeReaderSheet = .settings
                }
                    .keyboardShortcut(",", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
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
                showLabelManager = true
            case .compare:
                setPanePresentationTarget(windowManager.activeWindow?.id)
                showCompare = true
            case .bookmarks:
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .bookmarks
            case .history:
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .history
            case .readingPlans:
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .readingPlans
            case .settings:
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .settings
            case .workspaces:
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .workspaces
            case .downloads:
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .downloads
            case .epubLibrary:
                setPanePresentationTarget(windowManager.activeWindow?.id)
                showEpubLibrary = true
            case .epubBrowser:
                setPanePresentationTarget(windowManager.activeWindow?.id)
                showEpubBrowser = true
            case .epubSearch:
                setPanePresentationTarget(windowManager.activeWindow?.id)
                showEpubSearch = true
            case .help:
                showHelp = true
            case .about:
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .about
            }
        }
    }

    /** Opens Bookmarks from the reader shell. */
    private func openBookmarksFromReaderAction() {
        setPanePresentationTarget(windowManager.activeWindow?.id)
        activeReaderSheet = .bookmarks
    }

    /** Opens History from the reader shell. */
    private func openHistoryFromReaderAction() {
        setPanePresentationTarget(windowManager.activeWindow?.id)
        activeReaderSheet = .history
    }

    /** Opens Reading Plans from the reader shell. */
    private func openReadingPlansFromReaderAction() {
        setPanePresentationTarget(windowManager.activeWindow?.id)
        activeReaderSheet = .readingPlans
    }

    /** Opens Settings from the reader shell. */
    private func openSettingsFromReaderAction() {
        setPanePresentationTarget(windowManager.activeWindow?.id)
        activeReaderSheet = .settings
    }

    /** Opens Workspaces from the reader shell. */
    private func openWorkspacesFromReaderAction() {
        setPanePresentationTarget(windowManager.activeWindow?.id)
        activeReaderSheet = .workspaces
    }

    /** Opens Downloads from the reader shell. */
    private func openDownloadsFromReaderAction() {
        setPanePresentationTarget(windowManager.activeWindow?.id)
        activeReaderSheet = .downloads
    }

    /** Opens About from the reader shell. */
    private func openAboutFromReaderAction() {
        setPanePresentationTarget(windowManager.activeWindow?.id)
        activeReaderSheet = .about
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
            onShowBookChooser: {
                setPanePresentationTarget(window.id)
                showBookChooser = true
            },
            onShowSearch: { presentSearch(from: window.id) },
            onShowBookmarks: {
                setPanePresentationTarget(window.id)
                activeReaderSheet = .bookmarks
            },
            onShowSettings: {
                setPanePresentationTarget(window.id)
                activeReaderSheet = .settings
            },
            onShowDownloads: {
                setPanePresentationTarget(window.id)
                activeReaderSheet = .downloads
            },
            onShowHistory: {
                setPanePresentationTarget(window.id)
                activeReaderSheet = .history
            },
            onShowCompare: {
                setPanePresentationTarget(window.id)
                showCompare = true
            },
            onShowReadingPlans: {
                setPanePresentationTarget(window.id)
                activeReaderSheet = .readingPlans
            },
            onShowSpeakControls: { showSpeakControls = true },
            onShareText: { text in shareText = text },
            onShowCrossReferences: { refs in
                setPanePresentationTarget(window.id)
                crossReferences = refs
            },
            onShowModulePicker: { category in
                setPanePresentationTarget(window.id)
                pickerCategory = category
                showModulePicker = true
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
            onShowWorkspaces: {
                setPanePresentationTarget(window.id)
                activeReaderSheet = .workspaces
            },
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
            onShowStrongsSheet: { json, config in
                #if os(iOS)
                if let ctrl = controller(for: window.id) {
                    let d = TextDisplaySettings.appDefaults
                    let bgInt = nightMode
                        ? (displaySettings.nightBackground ?? d.nightBackground ?? -16777216)
                        : (displaySettings.dayBackground ?? d.dayBackground ?? -1)
                    presentStrongsSheet(
                        multiDocJSON: json,
                        configJSON: config,
                        backgroundColorInt: bgInt,
                        controller: ctrl,
                        onFindAll: { strongsNum in presentSearch(from: window.id, initialQuery: strongsNum) }
                    )
                }
                #endif
            },
            onRefChooserDialog: { completion in
                // Present book chooser and return OSIS ref
                setPanePresentationTarget(window.id)
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

    // MARK: - Module Picker

    /**
     Presents the module picker for the currently requested document category.

     The picker auto-routes dictionary, general-book, map, and EPUB selections into their
     respective browser sheets after switching the focused controller to the chosen module.
     */
    private var modulePicker: some View {
        NavigationStack {
            List {
                let modules = panePresentationController?.installedModules(for: pickerCategory) ?? []
                let activeNameForCategory = panePresentationController?.activeModuleName(for: pickerCategory)
                let emptyMessage: String = {
                    switch pickerCategory {
                    case .commentary: return String(localized: "picker_no_commentary_modules")
                    case .dictionary: return String(localized: "picker_no_dictionary_modules")
                    case .generalBook: return String(localized: "picker_no_general_book_modules")
                    case .map: return String(localized: "picker_no_map_modules")
                    default: return String(localized: "picker_no_bible_modules")
                    }
                }()
                if modules.isEmpty {
                    VStack(spacing: 12) {
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "download_modules")) {
                            showModulePicker = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                activeReaderSheet = .downloads
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                } else {
                    ForEach(modules, id: \.name) { (module: ModuleInfo) in
                        Button {
                            switch pickerCategory {
                            case .commentary:
                                panePresentationController?.switchCommentaryModule(to: module.name)
                                if panePresentationController?.currentCategory != .commentary {
                                    panePresentationController?.switchCategory(to: .commentary)
                                }
                            case .dictionary:
                                panePresentationController?.switchDictionaryModule(to: module.name)
                                panePresentationController?.switchCategory(to: .dictionary)
                                showModulePicker = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showDictionaryBrowser = true
                                }
                                return
                            case .generalBook:
                                panePresentationController?.switchGeneralBookModule(to: module.name)
                                panePresentationController?.switchCategory(to: .generalBook)
                                showModulePicker = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showGeneralBookBrowser = true
                                }
                                return
                            case .map:
                                panePresentationController?.switchMapModule(to: module.name)
                                panePresentationController?.switchCategory(to: .map)
                                showModulePicker = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showMapBrowser = true
                                }
                                return
                            default:
                                panePresentationController?.switchModule(to: module.name)
                                if panePresentationController?.currentCategory != .bible {
                                    panePresentationController?.switchCategory(to: .bible)
                                }
                            }
                            showModulePicker = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(module.name)
                                        .font(.headline)
                                    Text(module.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(Locale.current.localizedString(forLanguageCode: module.language) ?? module.language)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if module.name == activeNameForCategory {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .fontWeight(.semibold)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("modulePickerRow::\(module.name)")
                    }
                }
            }
            .accessibilityIdentifier("modulePickerScreen")
            .navigationTitle({
                switch pickerCategory {
                case .commentary: return String(localized: "picker_select_commentary")
                case .dictionary: return String(localized: "picker_select_dictionary")
                case .generalBook: return String(localized: "picker_select_general_book")
                case .map: return String(localized: "picker_select_map")
                default: return String(localized: "picker_select_translation")
                }
            }())
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { showModulePicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Speak Mini Player

    /// Compact speech-control bar shown while text-to-speech is active.
    private var speakMiniPlayer: some View {
        Button(action: { showSpeakControls = true }) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.body)
                    .foregroundStyle(.secondary)

                Text(speakService.currentTitle ?? currentReference)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                Spacer()

                Button {
                    speakService.skipBackward()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }

                Button {
                    if speakService.isPaused {
                        speakService.resume()
                    } else {
                        speakService.pause()
                    }
                } label: {
                    Image(systemName: speakService.isPaused ? "play.fill" : "pause.fill")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }

                Button {
                    speakService.skipForward()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }

                Button {
                    speakService.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
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
            onOpenNavigationDrawer: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showReaderNavigationDrawer = true
                }
            },
            onNavigatePrevious: { controller?.navigatePrevious() },
            onShowBookChooser: {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                showBookChooser = true
            },
            onNavigateNext: { controller?.navigateNext() },
            onReturnFromMyNotes: { controller?.returnFromMyNotes() },
            onReturnFromStudyPad: { controller?.returnFromStudyPad() },
            onReturnFromAuxiliary: { controller?.switchCategory(to: .bible) },
            onBrowseAuxiliary: {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                switch controller?.currentCategory {
                case .dictionary: showDictionaryBrowser = true
                case .generalBook: showGeneralBookBrowser = true
                case .map: showMapBrowser = true
                case .epub: showEpubBrowser = true
                default: break
                }
            }
        ) {
            readerToolbarActions(controller: controller)
        }
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
            dismissReaderOverflowMenuAndQueue(.settings)
        }
    }

    /// Full-screen dismiss area plus anchored trailing popup for Android-style overflow actions.
    private func readerOverflowMenuOverlay(anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { proxy in
            let buttonRect = anchor.map { proxy[$0] }
            let width = min(proxy.size.width - 16, CGFloat(236))
            let leadingInset: CGFloat = 8
            let trailingInset: CGFloat = 8
            let resolvedRightEdge = buttonRect?.maxX ?? (proxy.size.width - trailingInset)
            let resolvedBottomEdge = buttonRect?.maxY ?? (proxy.safeAreaInsets.top + 38)
            let x = min(
                max(leadingInset, resolvedRightEdge - width),
                proxy.size.width - width - trailingInset
            )
            let y = max(proxy.safeAreaInsets.top + 6, resolvedBottomEdge + 6)

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
                    .offset(x: x, y: y)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
    }

    /// Full-screen dimmer plus left drawer panel mirroring Android's main navigation drawer.
    private var readerNavigationDrawerOverlay: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissReaderNavigationDrawer() }
                    .accessibilityIdentifier("readerNavigationDrawerDismissArea")

                BibleReaderNavigationDrawer(
                    width: min(306, max(252, proxy.size.width * 0.756)),
                    colorScheme: colorScheme,
                    versionText: readerNavigationDrawerVersionText,
                    onAction: handleReaderNavigationDrawerAction
                )
                    .transition(.move(edge: .leading))
            }
        }
    }

    /// Choose-document sheet that reuses the existing module/category infrastructure.
    private var readerChooseDocumentSheet: some View {
        BibleReaderChooseDocumentSheet(
            activeChoice: activeReaderDocumentChoice,
            subtitle: readerDocumentChoiceSubtitle,
            onSelect: handleReaderDocumentChoice,
            onDismiss: { showChooseDocumentSheet = false }
        )
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
                setPanePresentationTarget(windowManager.activeWindow?.id)
                showChooseDocumentSheet = true
            }
        case .search:
            dismissReaderNavigationDrawerAndPerform {
                presentSearch(from: windowManager.activeWindow?.id)
            }
        case .speak:
            dismissReaderNavigationDrawerAndPerform {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                speakLastUsed = Date().timeIntervalSince1970
                if speakService.isSpeaking {
                    showSpeakControls = true
                } else {
                    panePresentationController?.speakCurrentChapter()
                    showSpeakControls = true
                }
            }
        case .bookmarks:
            dismissReaderNavigationDrawerAndPerform {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .bookmarks
            }
        case .studyPads:
            dismissReaderNavigationDrawerAndPerform {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                showStudyPadSelector = true
            }
        case .myNotes:
            dismissReaderNavigationDrawerAndPerform {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                panePresentationController?.loadMyNotesDocument()
            }
        case .readingPlans:
            dismissReaderNavigationDrawerAndPerform {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .readingPlans
            }
        case .history:
            dismissReaderNavigationDrawerAndPerform {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .history
            }
        case .downloads:
            dismissReaderNavigationDrawerAndPerform {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .downloads
            }
        case .importExport:
            dismissReaderNavigationDrawerAndPerform { showImportExport = true }
        case .syncSettings:
            dismissReaderNavigationDrawerAndPerform { showSyncSettings = true }
        case .settings:
            dismissReaderNavigationDrawerAndPerform {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .settings
            }
        case .help:
            dismissReaderNavigationDrawerAndPerform { showHelp = true }
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
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .about
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
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    /// Optional subtitle shown beneath each choose-document category.
    private func readerDocumentChoiceSubtitle(_ choice: BibleReaderDocumentChoice) -> String? {
        guard let controller = panePresentationController else { return nil }
        switch choice {
        case .bible:
            return controller.activeModule?.info.description ?? controller.activeModuleName
        case .commentary:
            return controller.activeCommentaryModule?.info.description ?? controller.activeCommentaryModuleName
        case .dictionary:
            return controller.activeDictionaryModule?.info.description ?? controller.activeDictionaryModuleName
        case .generalBook:
            return controller.activeGeneralBookModule?.info.description ?? controller.activeGeneralBookModuleName
        case .map:
            return controller.activeMapModule?.info.description ?? controller.activeMapModuleName
        case .epub:
            return controller.currentEpubTitle
        }
    }

    /// Whether one choose-document row matches the currently focused category.
    private var activeReaderDocumentChoice: BibleReaderDocumentChoice {
        let activeCategory = panePresentationController?.currentCategory ?? .bible
        switch activeCategory {
        case .commentary:
            return .commentary
        case .dictionary:
            return .dictionary
        case .generalBook:
            return .generalBook
        case .map:
            return .map
        case .epub:
            return .epub
        default:
            return .bible
        }
    }

    /// Routes the choose-document selection into the existing reader module/category infrastructure.
    private func handleReaderDocumentChoice(_ choice: BibleReaderDocumentChoice) {
        showChooseDocumentSheet = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard let controller = panePresentationController else { return }
            switch choice {
            case .bible:
                pickerCategory = .bible
                showModulePicker = true
            case .commentary:
                pickerCategory = .commentary
                showModulePicker = true
            case .dictionary:
                let modules = controller.installedDictionaryModules
                if modules.isEmpty {
                    activeReaderSheet = .downloads
                } else if modules.count == 1 {
                    controller.switchDictionaryModule(to: modules[0].name)
                    controller.switchCategory(to: .dictionary)
                    showDictionaryBrowser = true
                } else {
                    pickerCategory = .dictionary
                    showModulePicker = true
                }
            case .generalBook:
                let modules = controller.installedGeneralBookModules
                if modules.isEmpty {
                    activeReaderSheet = .downloads
                } else if modules.count == 1 {
                    controller.switchGeneralBookModule(to: modules[0].name)
                    controller.switchCategory(to: .generalBook)
                    showGeneralBookBrowser = true
                } else {
                    pickerCategory = .generalBook
                    showModulePicker = true
                }
            case .map:
                let modules = controller.installedMapModules
                if modules.isEmpty {
                    activeReaderSheet = .downloads
                } else if modules.count == 1 {
                    controller.switchMapModule(to: modules[0].name)
                    controller.switchCategory(to: .map)
                    showMapBrowser = true
                } else {
                    pickerCategory = .map
                    showModulePicker = true
                }
            case .epub:
                if !EpubReader.installedEpubs().isEmpty {
                    if controller.activeEpubReader != nil {
                        controller.switchCategory(to: .epub)
                        showEpubBrowser = true
                    } else {
                        showEpubLibrary = true
                    }
                } else {
                    activeReaderSheet = .downloads
                }
            }
        }
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

    /// Current effective Section Titles toggle after resolving workspace defaults.
    private var sectionTitlesEnabled: Bool {
        displaySettings.showSectionTitles ?? TextDisplaySettings.appDefaults.showSectionTitles ?? true
    }

    /// Current effective Chapter & Verse Numbers toggle after resolving workspace defaults.
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
            onShowSearch: { presentSearch(from: windowManager.activeWindow?.id) },
            onShowSpeak: {
                speakLastUsed = Date().timeIntervalSince1970
                if speakService.isSpeaking {
                    showSpeakControls = true
                } else {
                    controller?.speakCurrentChapter()
                    showSpeakControls = true
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
            onShowWorkspaces: {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                activeReaderSheet = .workspaces
            }
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
     - Side effects: Persists the updated Strong's mode into the active window's page-manager
       overrides, refreshes the active pane controller, and re-syncs the focused toolbar state.
     - Failure modes: If no active window or page manager exists, the method only updates the
       in-memory focused settings state. SwiftData save failures are intentionally swallowed.
     */
    private func applyStrongsMode(_ mode: Int) {
        if let activeWindow = windowManager.activeWindow,
           let pageManager = activeWindow.pageManager {
            var windowSettings = pageManager.textDisplaySettings ?? TextDisplaySettings()
            windowSettings.strongsMode = mode
            pageManager.textDisplaySettings = windowSettings
            try? modelContext.save()

            let resolved = resolvedDisplaySettings(for: activeWindow)
            displaySettings = resolved
            if let ctrl = controller(for: activeWindow.id) {
                ctrl.updateDisplaySettings(resolved, nightMode: nightMode)
            }
            return
        }

        displaySettings.strongsMode = mode
    }

    /**
     Toggles one optional Boolean text-display field and pushes the updated value to all readers.

     - Parameters:
       - keyPath: Writable `TextDisplaySettings` field to flip.
       - defaultValue: Effective fallback used when the current value is unset.
     */
    private func toggleDisplaySetting(
        _ keyPath: WritableKeyPath<TextDisplaySettings, Bool?>,
        default defaultValue: Bool
    ) {
        let previousWorkspaceSettings = resolvedWorkspaceDisplaySettings()
        let currentValue = previousWorkspaceSettings[keyPath: keyPath] ?? defaultValue
        var workspaceSettings = windowManager.activeWorkspace?.textDisplaySettings ?? TextDisplaySettings()
        workspaceSettings[keyPath: keyPath] = !currentValue
        persistWorkspaceDisplaySettings(workspaceSettings, previousResolvedSettings: previousWorkspaceSettings)
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
     Persists one workspace-scope settings value without copying inherited global theme colors.

     - Parameters:
       - workspaceSettings: Workspace-level overrides to persist.
       - previousResolvedSettings: Effective workspace settings before this mutation.
     */
    private func persistWorkspaceDisplaySettings(
        _ workspaceSettings: TextDisplaySettings,
        previousResolvedSettings: TextDisplaySettings
    ) {
        if let workspace = windowManager.activeWorkspace {
            let hadWorkspaceThemeColors = workspace.textDisplaySettings?.hasThemeColorOverrides ?? false
            var workspaceScopedSettings = workspaceSettings
            if !hadWorkspaceThemeColors {
                workspaceScopedSettings.clearThemeColors()
            }
            _ = workspaceScopedSettings.clearRedundantOverrides(matching: globalDisplaySettings)
            if hadWorkspaceThemeColors {
                workspaceScopedSettings.restoreThemeColors(from: workspaceSettings)
            }

            workspace.textDisplaySettings = workspaceScopedSettings
            let resolvedSettings = TextDisplaySettings.fullyResolved(
                window: nil,
                workspace: workspaceScopedSettings,
                global: globalDisplaySettings
            )
            for window in windowManager.allWindows {
                guard var windowSettings = window.pageManager?.textDisplaySettings else {
                    continue
                }
                if windowSettings.clearOverridesMatchingParent(
                    resolvedSettings,
                    changedFrom: previousResolvedSettings,
                    to: resolvedSettings
                ) {
                    window.pageManager?.textDisplaySettings = windowSettings
                }
            }
            try? modelContext.save()
        }

        refreshVisibleControllerDisplaySettings()
        syncActiveDisplaySettings()
        reloadBehaviorPreferences()
    }

    /**
     Persists app-level text-display defaults and refreshes reader controllers.

     This mirrors Android's global text-display layer: application Settings edits the global
     fallback, while workspace and window overrides remain separate scopes in the inheritance chain.

     - Side effects:
       - writes `globalDisplaySettings` through `SettingsStore`
       - pushes each visible reader its own resolved display settings
       - reloads behavior preferences so non-display settings changed from the same Settings screen
         stay in sync
     - Failure modes: Settings-store persistence failures are intentionally swallowed by
       `SettingsStore`.
     */
    private func applyGlobalDisplaySettingsChange() {
        let store = SettingsStore(modelContext: modelContext)
        store.setGlobalTextDisplaySettings(globalDisplaySettings)
        refreshVisibleControllerDisplaySettings()
        syncActiveDisplaySettings()
        reloadBehaviorPreferences()
    }

    /// Resolves text-display settings for one specific window using the normal inheritance chain.
    private func resolvedDisplaySettings(for window: Window?) -> TextDisplaySettings {
        TextDisplaySettings.fullyResolved(
            window: window?.pageManager?.textDisplaySettings,
            workspace: windowManager.activeWorkspace?.textDisplaySettings,
            global: globalDisplaySettings
        )
    }

    /// Resolves the workspace-scoped settings editor state without applying window overrides.
    private func resolvedWorkspaceDisplaySettings() -> TextDisplaySettings {
        TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: windowManager.activeWorkspace?.textDisplaySettings,
            global: globalDisplaySettings
        )
    }

    /// Re-syncs the focused toolbar/settings state from the current active window.
    private func syncActiveDisplaySettings() {
        displaySettings = resolvedDisplaySettings(for: windowManager.activeWindow)
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
     Otherwise it opens the Bible picker sheet.

     - Parameter controller: Focused pane controller, if one is currently registered.
     */
    private func performBibleMenuAction(_ controller: BibleReaderController?) {
        guard let controller else {
            performBibleChooserAction()
            return
        }
        if controller.installedBibleModules.count == 2 {
            cycleToNextModule(
                modules: controller.installedBibleModules,
                activeName: controller.activeModuleName
            ) { nextName in
                controller.switchModule(to: nextName)
                controller.switchCategory(to: .bible)
            }
            return
        }
        performBibleChooserAction()
    }

    /**
     Presents the Bible module chooser.

     - Note: This is the SwiftUI-sheet equivalent of Android's document chooser activity.
     */
    private func performBibleChooserAction() {
        setPanePresentationTarget(windowManager.activeWindow?.id)
        pickerCategory = .bible
        showModulePicker = true
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
            controller.switchModule(to: nextName)
            controller.switchCategory(to: .bible)
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
        setPanePresentationTarget(windowManager.activeWindow?.id)
        pickerCategory = .commentary
        showModulePicker = true
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
        autoFullscreenDirectionDown = nil
        autoFullscreenDistance = 0
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
        guard autoFullscreenPref else {
            resetAutoFullscreenTracking()
            return
        }
        guard deltaY != 0 else { return }

        let isDirectionDown = deltaY > 0
        if autoFullscreenDirectionDown != isDirectionDown {
            autoFullscreenDirectionDown = isDirectionDown
            autoFullscreenDistance = 0
        }

        autoFullscreenDistance += abs(deltaY)
        guard autoFullscreenDistance >= autoFullscreenScrollThreshold else { return }
        autoFullscreenDistance = 0

        // Match Android: when fullscreen was entered by double-tap, scrolling
        // should not auto-toggle fullscreen until fullscreen has been exited.
        guard !lastFullScreenByDoubleTap else { return }

        if !isFullScreen && isDirectionDown {
            withAnimation(.easeInOut(duration: 0.2)) { isFullScreen = true }
        } else if isFullScreen && !isDirectionDown {
            withAnimation(.easeInOut(duration: 0.2)) { isFullScreen = false }
        }
    }

    /**
     Dispatches horizontal swipe gestures according to the configured Bible swipe mode.

     - Parameters:
       - window: Pane whose native swipe gesture triggered the callback.
       - direction: Swipe direction detected by the native web-view wrapper.
     - Side effects: May trigger chapter navigation through the focused `BibleReaderController` or
       emit page-scroll commands into the active web view.
     - Failure modes: Returns without action when the gesture did not originate from the active
       window, no focused controller is registered, an in-page text selection is active, or the
       configured swipe mode is `.none`.
     */
    private func handleHorizontalSwipe(from window: Window, direction: NativeHorizontalSwipeDirection) {
        guard windowManager.activeWindow?.id == window.id else { return }
        guard let ctrl = windowManager.controllers[window.id] as? BibleReaderController else { return }
        guard !ctrl.hasActiveSelection else { return }

        switch BibleSwipeMode(rawValue: bibleViewSwipeMode) ?? .chapter {
        case .chapter:
            if direction == .left {
                ctrl.navigateNext()
            } else {
                ctrl.navigatePrevious()
            }
        case .page:
            if direction == .left {
                ctrl.scrollPageDown()
            } else {
                ctrl.scrollPageUp()
            }
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

/// Horizontal swipe modes for Bible panes, mirroring the Android preference values.
private enum BibleSwipeMode: String {
    /// Swiping left or right changes chapter.
    case chapter = "CHAPTER"

    /// Swiping left or right scrolls by page height within the current document.
    case page = "PAGE"

    /// Horizontal swipe gestures are ignored.
    case none = "NONE"
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
