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

    /// Document categories exposed by the Android-style drawer's choose-document flow.
    private enum ReaderDocumentChoice: String, CaseIterable, Identifiable {
        case bible
        case commentary
        case dictionary
        case generalBook
        case map
        case epub

        var id: String { rawValue }
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

    /// Workspace-scoped display settings edited from the full Settings/Text Display flows.
    @State private var settingsDisplaySettings: TextDisplaySettings = .appDefaults

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
        return "\(windowToken);\(contentToken);strongsMode=\(strongsMode)"
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
            prepareWorkspaceDisplaySettingsEditor()

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
                        displaySettings: $settingsDisplaySettings,
                        nightMode: $nightMode,
                        nightModeMode: $nightModeMode,
                        onSettingsChanged: applyWorkspaceDisplaySettingsChange
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
                TextDisplaySettingsView(settings: $settingsDisplaySettings, onChange: applyWorkspaceDisplaySettingsChange)
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
                ColorSettingsView(settings: $settingsDisplaySettings, onChange: applyWorkspaceDisplaySettingsChange)
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
                    prepareWorkspaceDisplaySettingsEditor()
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
        GeometryReader { geometry in
            let windows = windowManager.visibleWindows
            let naturalHorizontal = geometry.size.width > geometry.size.height
            let reverse = windowManager.activeWorkspace?.workspaceSettings?.enableReverseSplitMode ?? false
            let isHorizontal = reverse ? !naturalHorizontal : naturalHorizontal
            let totalWeight = windows.map(\.layoutWeight).reduce(0, +)
            let normalizedTotal = max(totalWeight, 0.001) // avoid division by zero

            // Always use the same VStack/HStack container regardless of window count.
            // Switching between branches (single vs multi) destroys existing panes,
            // killing their WebView and controller state.
            if isHorizontal {
                HStack(spacing: 0) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        paneView(for: window)
                            .frame(width: windows.count > 1
                                ? geometry.size.width * CGFloat(window.layoutWeight / normalizedTotal)
                                : nil)

                        if index < windows.count - 1 {
                            WindowSeparator(
                                window1: window,
                                window2: windows[index + 1],
                                isVertical: false,
                                totalPaneCount: windows.count,
                                parentSize: geometry.size.width
                            )
                        }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                        paneView(for: window)
                            .frame(height: windows.count > 1
                                ? geometry.size.height * CGFloat(window.layoutWeight / normalizedTotal)
                                : nil)

                        if index < windows.count - 1 {
                            WindowSeparator(
                                window1: window,
                                window2: windows[index + 1],
                                isVertical: true,
                                totalPaneCount: windows.count,
                                parentSize: geometry.size.height
                            )
                        }
                    }
                }
            }
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
                prepareWorkspaceDisplaySettingsEditor()
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
        prepareWorkspaceDisplaySettingsEditor()
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
                prepareWorkspaceDisplaySettingsEditor()
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

    /// High-level header layouts shown above the focused pane.
    private enum DocumentHeaderMode {
        case myNotes
        case studyPad
        case auxiliary
        case bible
    }

    /**
     Builds the top document header bar for the focused pane state.

     The header switches between Bible navigation chrome and category-specific back/navigation
     controls for notes, study pads, dictionaries, maps, general books, and EPUB content.
     */
    private var documentHeader: some View {
        let controller = focusedController
        let avoidanceInsets = readerWindowControlsAvoidanceInsets
        return VStack(spacing: 0) {
            HStack {
                documentHeaderContent(controller: controller)
            }
            .padding(.top, 8 + avoidanceInsets.top)
            .padding(.bottom, 8)
            .padding(.leading, 16 + avoidanceInsets.leading)
            .padding(.trailing, 16)
            .background(.bar)
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

    /**
     Type-erases the active header branch to avoid a device-only SwiftUI EXC_BAD_ACCESS observed
     on iPad hardware when the full conditional header tree is inlined into one large view body.
     */
    private func documentHeaderContent(controller: BibleReaderController?) -> AnyView {
        switch documentHeaderMode(for: controller) {
        case .myNotes:
            return AnyView(myNotesDocumentHeader(controller: controller))
        case .studyPad:
            return AnyView(studyPadDocumentHeader(controller: controller))
        case .auxiliary:
            return AnyView(auxiliaryDocumentHeader(controller: controller))
        case .bible:
            return AnyView(bibleDocumentHeader(controller: controller))
        }
    }

    /// Resolves which top-level header layout should be displayed for the focused controller.
    private func documentHeaderMode(for controller: BibleReaderController?) -> DocumentHeaderMode {
        if controller?.showingMyNotes == true {
            return .myNotes
        }
        if controller?.showingStudyPad == true {
            return .studyPad
        }
        if controller?.currentCategory == .dictionary ||
            controller?.currentCategory == .generalBook ||
            controller?.currentCategory == .map ||
            controller?.currentCategory == .epub {
            return .auxiliary
        }
        return .bible
    }

    /// Header shown while browsing My Notes.
    private func myNotesDocumentHeader(controller: BibleReaderController?) -> some View {
        Group {
            Button(action: { controller?.returnFromMyNotes() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                    Text(currentReference)
                        .font(.subheadline)
                }
            }
            .accessibilityLabel(String(localized: "back_to_bible"))
            .accessibilityIdentifier("readerReturnFromMyNotesButton")

            Spacer()

            Text(String(localized: "my_notes"))
                .font(.headline)
                .accessibilityIdentifier("readerMyNotesTitle")

            Spacer()
            Color.clear.frame(width: 80, height: 1)
        }
    }

    /// Header shown while browsing the StudyPad.
    private func studyPadDocumentHeader(controller: BibleReaderController?) -> some View {
        Group {
            Button(action: { controller?.returnFromStudyPad() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                    Text(currentReference)
                        .font(.subheadline)
                }
            }
            .accessibilityLabel(String(localized: "back_to_bible"))

            Spacer()

            Text(controller?.activeStudyPadLabelName ?? String(localized: "study_pad"))
                .font(.headline)
                .lineLimit(1)
                .accessibilityIdentifier("readerStudyPadTitle")

            Spacer()
            Color.clear.frame(width: 80, height: 1)
        }
    }

    /// Header shown for dictionary, general-book, map, and EPUB categories.
    private func auxiliaryDocumentHeader(controller: BibleReaderController?) -> some View {
        Group {
            Button(action: { controller?.switchCategory(to: .bible) }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                    Text(currentReference)
                        .font(.subheadline)
                }
            }
            .accessibilityLabel(String(localized: "back_to_bible"))

            Spacer()

            VStack(spacing: 1) {
                Text(controller?.activeModuleName(for: controller?.currentCategory ?? .dictionary) ?? "")
                    .font(.headline)
                    .lineLimit(1)
                if let key = controller?.currentCategory == .dictionary ? controller?.currentDictionaryKey :
                                controller?.currentCategory == .generalBook ? controller?.currentGeneralBookKey :
                                controller?.currentCategory == .epub ? controller?.currentEpubTitle :
                                controller?.currentMapKey {
                    Text(key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                switch controller?.currentCategory {
                case .dictionary: showDictionaryBrowser = true
                case .generalBook: showGeneralBookBrowser = true
                case .map: showMapBrowser = true
                case .epub: showEpubBrowser = true
                default: break
                }
            } label: {
                Image(systemName: browseIconName(for: controller?.currentCategory))
                    .font(.body)
            }
        }
    }

    /// Header shown for the normal Bible/commentary reading mode.
    private func bibleDocumentHeader(controller: BibleReaderController?) -> some View {
        Group {
            readerNavigationDrawerButton

            Button(action: { controller?.navigatePrevious() }) {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(controller?.hasPrevious == true ? .primary : .tertiary)
            }
            .disabled(controller?.hasPrevious != true)
            .accessibilityLabel(String(localized: "previous_chapter"))

            Button(action: {
                setPanePresentationTarget(windowManager.activeWindow?.id)
                showBookChooser = true
            }) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(currentToolbarTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    Text(currentToolbarSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("bookChooserButton")
            .accessibilityValue("\(currentToolbarTitle), \(currentToolbarSubtitle)")

            Button(action: { controller?.navigateNext() }) {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(controller?.hasNext == true ? .primary : .tertiary)
            }
            .disabled(controller?.hasNext != true)
            .accessibilityLabel(String(localized: "next_chapter"))

            readerToolbarActions(controller: controller)
                .layoutPriority(1)
        }
    }

    /**
     Builds the Android-style options menu: window/text-display controls only.
     */
    private var readerOverflowMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            readerOverflowToggleRow(
                title: localizedDrawerString("toggle_fullscreen", default: "Fullscreen"),
                assetName: "OverflowFullscreen",
                isOn: isFullScreen,
                identifier: "readerOverflowFullscreenToggle"
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { isFullScreen.toggle() }
                lastFullScreenByDoubleTap = false
                resetAutoFullscreenTracking()
            }

            if isNightModeQuickToggleEnabled {
                Divider()
                readerOverflowToggleRow(
                    title: localizedDrawerString("options_menu_night_mode", default: "Night mode"),
                    assetName: "OverflowNightMode",
                    isOn: nightMode,
                    identifier: "readerOverflowNightModeToggle"
                ) {
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
                }
            }

            Divider()
            readerOverflowButton(
                title: readerOverflowEllipsisTitle(
                    localizedDrawerString("switch_to_workspace", default: "Workspaces")
                ),
                assetName: "OverflowWorkspace",
                identifier: "readerOpenWorkspacesAction"
            ) {
                dismissReaderOverflowMenuAndQueue(.workspaces)
            }

            #if os(iOS)
            Divider()
            readerOverflowToggleRow(
                title: String(localized: "tilt_to_scroll"),
                assetName: "OverflowTiltToScroll",
                isOn: windowManager.activeWorkspace?.workspaceSettings?.enableTiltToScroll ?? false,
                identifier: "readerOverflowTiltToScrollToggle"
            ) {
                let nextValue = !(windowManager.activeWorkspace?.workspaceSettings?.enableTiltToScroll ?? false)
                updateWorkspaceSettings { $0.enableTiltToScroll = nextValue }
                if nextValue {
                    startTiltToScroll()
                } else {
                    tiltScrollService.stop()
                }
            }
            #endif

            if windowManager.visibleWindows.count > 1 {
                Divider()
                readerOverflowToggleRow(
                    title: String(localized: "reversed_split_mode"),
                    assetName: "OverflowSplitMode",
                    isOn: windowManager.activeWorkspace?.workspaceSettings?.enableReverseSplitMode ?? false,
                    identifier: "readerOverflowSplitModeToggle"
                ) {
                    let nextValue = !(windowManager.activeWorkspace?.workspaceSettings?.enableReverseSplitMode ?? false)
                    updateWorkspaceSettings { $0.enableReverseSplitMode = nextValue }
                }
            }

            Divider()
            readerOverflowToggleRow(
                title: localizedDrawerString("window_pinning_menutitle", default: "Window pinning"),
                assetName: "OverflowWindowPinning",
                isOn: windowManager.activeWorkspace?.workspaceSettings?.autoPin ?? false,
                identifier: "readerOverflowWindowPinningToggle"
            ) {
                let nextValue = !(windowManager.activeWorkspace?.workspaceSettings?.autoPin ?? false)
                updateWorkspaceSettings { $0.autoPin = nextValue }
            }

            Divider()
            readerOverflowButton(
                title: readerOverflowEllipsisTitle(String(localized: "label_settings")),
                assetName: "OverflowLabelSettings"
            ) {
                dismissReaderOverflowMenuAndQueue(.labelManager)
            }

            if isBibleContentFocused {
                Divider()
                readerOverflowToggleRow(
                    title: localizedAndroidOverflowString(
                        androidKey: "prefs_section_title_title",
                        fallbackKey: "section_titles",
                        default: "Section titles"
                    ),
                    assetName: "OverflowSectionTitles",
                    isOn: sectionTitlesEnabled,
                    identifier: "readerOverflowSectionTitlesToggle"
                ) {
                    toggleDisplaySetting(\.showSectionTitles, default: true)
                }
            }

            if moduleHasStrongs {
                Divider()
                readerOverflowButton(
                    title: readerOverflowEllipsisTitle(
                        localizedAndroidOverflowString(
                            androidKey: "prefs_show_strongs_title",
                            fallbackKey: "strongs_numbers",
                            default: "Strong's numbers"
                        )
                    ),
                    assetName: strongsMenuIconAssetName,
                    identifier: "readerOverflowStrongsModeAction"
                ) {
                    dismissReaderOverflowMenuAndPerform {
                        showReaderStrongsModeDialog = true
                    }
                }
            }

            if isBibleContentFocused {
                Divider()
                readerOverflowToggleRow(
                    title: localizedAndroidOverflowString(
                        androidKey: "prefs_show_verseno_title",
                        fallbackKey: nil,
                        default: "Chapter & verse numbers"
                    ),
                    assetName: "OverflowChapterVerseNumbers",
                    isOn: verseNumbersEnabled,
                    identifier: "readerOverflowVerseNumbersToggle"
                ) {
                    toggleDisplaySetting(\.showVerseNumbers, default: true)
                }
            }

            Divider()
            readerOverflowButton(
                title: readerOverflowEllipsisTitle(
                    localizedDrawerString("all_text_options_window_menutitle", default: "All text options")
                ),
                assetName: "OverflowTextOptions",
                identifier: "readerOpenSettingsAction"
            ) {
                dismissReaderOverflowMenuAndQueue(.settings)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readerOverflowMenu")
        .background(readerOverflowMenuBackground)
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

    /// Leading drawer trigger matching Android's hamburger navigation affordance.
    private var readerNavigationDrawerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showReaderNavigationDrawer = true
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.semibold))
                .foregroundStyle(toolbarIconColor())
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("readerNavigationDrawerButton")
        .accessibilityLabel(localizedDrawerString("main_menu", default: "Main menu"))
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

                readerNavigationDrawer(width: min(306, max(252, proxy.size.width * 0.756)))
                    .transition(.move(edge: .leading))
            }
        }
    }

    /// Scrollable drawer content grouped the same way as Android's main reader drawer.
    private func readerNavigationDrawer(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    readerNavigationDrawerHeaderIcon
                    Text(localizedDrawerString("app_name_medium", default: "Bible Study (AndBible)"))
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.top, 24)
                .padding(.horizontal, 4)

                readerNavigationDrawerSection {
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("chooce_document", default: "Choose Document"),
                        icon: .asset("DrawerChooseDocument"),
                        identifier: "readerChooseDocumentAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            setPanePresentationTarget(windowManager.activeWindow?.id)
                            showChooseDocumentSheet = true
                        }
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("search", default: "Find"),
                        icon: .asset("DrawerSearch"),
                        identifier: "readerOpenSearchAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            presentSearch(from: windowManager.activeWindow?.id)
                        }
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("speak", default: "Speak"),
                        icon: .asset("DrawerSpeak"),
                        identifier: "readerOpenSpeakAction"
                    ) {
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
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("bookmarks", default: "Bookmarks"),
                        icon: .asset("DrawerBookmarks"),
                        identifier: "readerOpenBookmarksAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            setPanePresentationTarget(windowManager.activeWindow?.id)
                            activeReaderSheet = .bookmarks
                        }
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("studypads", default: "StudyPads"),
                        icon: .asset("DrawerStudyPads"),
                        identifier: "readerOpenStudyPadsAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            setPanePresentationTarget(windowManager.activeWindow?.id)
                            showStudyPadSelector = true
                        }
                    }
                    readerNavigationDrawerRow(
                        title: String(localized: "my_notes"),
                        icon: .asset("DrawerDocuments"),
                        identifier: "readerOpenMyNotesAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            setPanePresentationTarget(windowManager.activeWindow?.id)
                            panePresentationController?.loadMyNotesDocument()
                        }
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("rdg_plan_title", default: "Reading Plan"),
                        icon: .asset("DrawerReadingPlan"),
                        identifier: "readerOpenReadingPlansAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            setPanePresentationTarget(windowManager.activeWindow?.id)
                            activeReaderSheet = .readingPlans
                        }
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("history", default: "History"),
                        icon: .asset("DrawerHistory"),
                        identifier: "readerOpenHistoryAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            setPanePresentationTarget(windowManager.activeWindow?.id)
                            activeReaderSheet = .history
                        }
                    }
                }

                readerNavigationDrawerSection(
                    title: localizedDrawerString("administration", default: "Administration")
                ) {
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("download", default: "Download Documents"),
                        icon: .asset("DrawerDownloads"),
                        identifier: "readerOpenDownloadsAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            setPanePresentationTarget(windowManager.activeWindow?.id)
                            activeReaderSheet = .downloads
                        }
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("backup_and_restore", default: "Backup & Restore"),
                        icon: .asset("DrawerBackupRestore"),
                        identifier: "readerOpenImportExportAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform { showImportExport = true }
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("cloud_sync_title", default: "Device synchronization"),
                        icon: .asset("DrawerSync"),
                        identifier: "readerOpenSyncSettingsAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform { showSyncSettings = true }
                    }
                    readerNavigationDrawerRow(
                        title: "Application preferences",
                        icon: .asset("DrawerSettings"),
                        identifier: "readerOpenSettingsAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            setPanePresentationTarget(windowManager.activeWindow?.id)
                            prepareWorkspaceDisplaySettingsEditor()
                            activeReaderSheet = .settings
                        }
                    }
                }

                readerNavigationDrawerSection(
                    title: localizedDrawerString("information", default: "Information")
                ) {
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("help_and_tips", default: "Help & Tips"),
                        icon: .asset("DrawerHelp"),
                        identifier: "readerOpenHelpAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform { showHelp = true }
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("buy_development", default: "Sponsor app development"),
                        icon: .asset("DrawerSponsorDevelopment"),
                        identifier: "readerSponsorDevelopmentAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            openExternalLink("https://shop.andbible.org")
                        }
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("questions_title", default: "Need Help"),
                        icon: .system("questionmark.bubble"),
                        identifier: "readerNeedHelpAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            openExternalLink("https://github.com/AndBible/and-bible/wiki/Support")
                        }
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("how_to_contribute", default: "How to Contribute"),
                        icon: .system("figure.wave"),
                        identifier: "readerContributeAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            openExternalLink("https://github.com/AndBible/and-bible/wiki/How-to-contribute")
                        }
                    }
                    readerNavigationDrawerRow(
                        title: String(localized: "about"),
                        icon: .system("info.circle"),
                        identifier: "readerOpenAboutAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            setPanePresentationTarget(windowManager.activeWindow?.id)
                            activeReaderSheet = .about
                        }
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("app_licence_title", default: "App Licence"),
                        icon: .system("doc.text"),
                        identifier: "readerOpenAppLicenseAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            openExternalLink("https://www.gnu.org/licenses/gpl-3.0.html")
                        }
                    }
                }

                readerNavigationDrawerSection(
                    title: localizedDrawerString("contact", default: "Contact")
                ) {
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("tell_friend_title", default: "Recommend to a friend"),
                        icon: .system("square.and.arrow.up"),
                        identifier: "readerTellFriendAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            shareText = String(localized: "tell_friend_message")
                        }
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("rate_application", default: "Rate & Review"),
                        icon: .system("star"),
                        identifier: "readerRateAppAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            #if os(iOS)
                            if let scene = UIApplication.shared.connectedScenes
                                .compactMap({ $0 as? UIWindowScene }).first {
                                SKStoreReviewController.requestReview(in: scene)
                            }
                            #endif
                        }
                    }
                    readerNavigationDrawerRow(
                        title: localizedDrawerString("send_bug_report_title", default: "Feedback / bug report"),
                        icon: .system("ladybug"),
                        identifier: "readerReportBugAction"
                    ) {
                        dismissReaderNavigationDrawerAndPerform {
                            openExternalLink("https://github.com/AndBible/and-bible/issues")
                        }
                    }
                }

                VStack(spacing: 10) {
                    Divider()
                    Text(readerNavigationDrawerVersionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 16)
        }
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(readerNavigationDrawerBackground)
        .accessibilityIdentifier("readerNavigationDrawer")
    }

    /// Choose-document sheet that reuses the existing module/category infrastructure.
    private var readerChooseDocumentSheet: some View {
        NavigationStack {
            List {
                ForEach(ReaderDocumentChoice.allCases) { choice in
                    Button {
                        handleReaderDocumentChoice(choice)
                    } label: {
                        HStack(spacing: 12) {
                            readerDocumentChoiceIcon(choice)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(readerDocumentChoiceTitle(choice))
                                    .foregroundStyle(.primary)
                                if let subtitle = readerDocumentChoiceSubtitle(choice) {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if readerDocumentChoiceIsActive(choice) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("readerChooseDocument::\(choice.rawValue)")
                }
            }
            .navigationTitle(localizedDrawerString("chooce_document", default: "Choose Document"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "done")) { showChooseDocumentSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
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

    /// Platform-appropriate background fill used by the left navigation drawer.
    private var readerNavigationDrawerBackground: Color {
        #if os(iOS)
        return colorScheme == .dark
            ? Color(red: 48.0 / 255.0, green: 48.0 / 255.0, blue: 48.0 / 255.0)
            : Color(uiColor: .systemBackground)
        #elseif os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// Drawer header icon using the platform app icon when available.
    @ViewBuilder
    private var readerNavigationDrawerHeaderIcon: some View {
        #if os(iOS)
        Image("DrawerLogo", bundle: .module)
            .renderingMode(.original)
            .interpolation(.high)
            .resizable()
            .scaledToFit()
            .frame(width: 52, height: 52)
        #elseif os(macOS)
        Image("DrawerLogo", bundle: .module)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: 52, height: 52)
        #endif
    }

    /// One grouped drawer section with an optional Android-style header label.
    private func readerNavigationDrawerSection<Content: View>(
        title: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                content()
            }
        }
    }

    /// One tappable row inside the reader navigation drawer.
    @ViewBuilder
    private func readerNavigationDrawerRow(
        title: String,
        icon: ReaderNavigationDrawerIcon,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        if let identifier {
            Button(action: action) {
                readerNavigationDrawerRowLabel(title: title, icon: icon)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
        } else {
            Button(action: action) {
                readerNavigationDrawerRowLabel(title: title, icon: icon)
            }
            .buttonStyle(.plain)
        }
    }

    /// Supported icon sources for one drawer row.
    private enum ReaderNavigationDrawerIcon {
        case system(String)
        case asset(String)
    }

    /// Shared label chrome for drawer rows.
    private func readerNavigationDrawerRowLabel(
        title: String,
        icon: ReaderNavigationDrawerIcon
    ) -> some View {
        HStack(spacing: 12) {
            readerNavigationDrawerRowIcon(icon)
                .frame(width: 20, height: 20)
            Text(title)
                .foregroundStyle(.primary)
                .font(.system(size: 17, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// Resolves one drawer row icon from either asset-catalog vectors or SF Symbols.
    @ViewBuilder
    private func readerNavigationDrawerRowIcon(_ icon: ReaderNavigationDrawerIcon) -> some View {
        switch icon {
        case .system(let systemName):
            Image(systemName: systemName)
                .font(.body)
                .foregroundStyle(.secondary)
        case .asset(let assetName):
            Image(assetName, bundle: .module)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    /// Human-readable title shown for each choose-document category.
    private func readerDocumentChoiceTitle(_ choice: ReaderDocumentChoice) -> String {
        switch choice {
        case .bible:
            return String(localized: "bible")
        case .commentary:
            return String(localized: "commentaries")
        case .dictionary:
            return String(localized: "dictionary")
        case .generalBook:
            return String(localized: "general_book")
        case .map:
            return String(localized: "map")
        case .epub:
            return String(localized: "epub_library")
        }
    }

    /// Optional subtitle shown beneath each choose-document category.
    private func readerDocumentChoiceSubtitle(_ choice: ReaderDocumentChoice) -> String? {
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
    private func readerDocumentChoiceIsActive(_ choice: ReaderDocumentChoice) -> Bool {
        let activeCategory = panePresentationController?.currentCategory ?? .bible
        switch choice {
        case .bible:
            return activeCategory == .bible
        case .commentary:
            return activeCategory == .commentary
        case .dictionary:
            return activeCategory == .dictionary
        case .generalBook:
            return activeCategory == .generalBook
        case .map:
            return activeCategory == .map
        case .epub:
            return activeCategory == .epub
        }
    }

    /// Visual icon used by the choose-document sheet.
    @ViewBuilder
    private func readerDocumentChoiceIcon(_ choice: ReaderDocumentChoice) -> some View {
        switch choice {
        case .bible:
            bibleToolbarIcon
                .foregroundStyle(.primary)
        case .commentary:
            commentaryToolbarIcon
                .foregroundStyle(.primary)
        case .dictionary:
            Image(systemName: "character.book.closed")
                .foregroundStyle(.secondary)
        case .generalBook:
            Image(systemName: "books.vertical.fill")
                .foregroundStyle(.secondary)
        case .map:
            Image(systemName: "map.fill")
                .foregroundStyle(.secondary)
        case .epub:
            Image(systemName: "book.closed.fill")
                .foregroundStyle(.secondary)
        }
    }

    /// Routes the choose-document selection into the existing reader module/category infrastructure.
    private func handleReaderDocumentChoice(_ choice: ReaderDocumentChoice) {
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

    /** Groups one cluster of overflow controls into one Android-style popup section. */
    private func readerOverflowSection<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            content()
        }
    }

    /** Builds one overflow action row with an optional accessibility identifier. */
    @ViewBuilder
    private func readerOverflowButton(
        title: String,
        assetName: String,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        if let identifier {
            Button(action: action) {
                readerOverflowButtonLabel(title: title, assetName: assetName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
        } else {
            Button(action: action) {
                readerOverflowButtonLabel(title: title, assetName: assetName)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
        }
    }

    /** Shared row label used by the reader overflow sheet buttons. */
    private func readerOverflowButtonLabel(
        title: String,
        assetName: String,
        trailingAccessory: ReaderOverflowTrailingAccessory = .none
    ) -> some View {
        HStack(spacing: 12) {
            ToolbarAssetIcon(name: assetName, size: 16)
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15))
            Spacer()
            switch trailingAccessory {
            case .none:
                EmptyView()
            case .checkbox(let isOn):
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isOn ? readerOverflowCheckboxTint : .secondary)
            case .checkmark:
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.blue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    /** Shared row styling used by Android-style popup toggles. */
    @ViewBuilder
    private func readerOverflowToggleRow(
        title: String,
        assetName: String,
        isOn: Bool,
        identifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            readerOverflowButtonLabel(
                title: title,
                assetName: assetName,
                trailingAccessory: .checkbox(isOn)
            )
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "on" : "off")
        if let identifier {
            button.accessibilityIdentifier(identifier)
        } else {
            button
        }
    }

    /// Strong's icon matching Android's testament-aware toolbar glyphs.
    private var strongsIcon: some View {
        ToolbarAssetIcon(name: strongsIconAssetName)
        .frame(width: 24, height: 22)
    }

    /// Bible toolbar icon using Android's packaged vector glyph.
    private var bibleToolbarIcon: some View {
        ToolbarAssetIcon(name: "ToolbarBible")
        .frame(width: 24, height: 22)
    }

    /// Commentary toolbar icon using Android's packaged vector glyph.
    private var commentaryToolbarIcon: some View {
        ToolbarAssetIcon(name: "ToolbarCommentary")
            .frame(width: 24, height: 22)
    }

    /// Workspace toolbar icon using Android's packaged vector glyph.
    private var workspaceToolbarIcon: some View {
        ToolbarAssetIcon(name: "ToolbarWorkspace")
        .frame(width: 24, height: 22)
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

    /// Android-like teal tint used by checked overflow-menu boxes.
    private var readerOverflowCheckboxTint: Color {
        Color(red: 111.0 / 255.0, green: 214.0 / 255.0, blue: 209.0 / 255.0)
    }

    /// Most-recently-used single-button fallback used when the toolbar can only fit one accessory.
    private var preferredSingleToolbarAccessory: ToolbarAccessoryButton? {
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
        if usesCompactReaderToolbar {
            toolbarActionButtons(
                controller: controller,
                showSearch: true,
                showSpeak: false,
                showWorkspace: false
            )
        } else {
            ViewThatFits(in: .horizontal) {
                toolbarActionButtons(
                    controller: controller,
                    showSearch: true,
                    showSpeak: true,
                    showWorkspace: true
                )
                toolbarActionButtons(
                    controller: controller,
                    showSearch: true,
                    showSpeak: true,
                    showWorkspace: false
                )
                toolbarActionButtons(
                    controller: controller,
                    showSearch: preferredSingleToolbarAccessory == .search,
                    showSpeak: preferredSingleToolbarAccessory == .speak,
                    showWorkspace: true
                )
                toolbarActionButtons(
                    controller: controller,
                    showSearch: preferredSingleToolbarAccessory == .search,
                    showSpeak: preferredSingleToolbarAccessory == .speak,
                    showWorkspace: false
                )
                toolbarActionButtons(
                    controller: controller,
                    showSearch: false,
                    showSpeak: false,
                    showWorkspace: true
                )
                toolbarActionButtons(
                    controller: controller,
                    showSearch: false,
                    showSpeak: false,
                    showWorkspace: false
                )
            }
        }
    }

    /// Neutral toolbar tint matching Android's white/grey icon-state treatment.
    private func toolbarIconColor(isActive: Bool = true) -> Color {
        isActive ? .primary : .secondary
    }

    /// One concrete toolbar-button layout candidate for `ViewThatFits`.
    private func toolbarActionButtons(
        controller: BibleReaderController?,
        showSearch: Bool,
        showSpeak: Bool,
        showWorkspace: Bool
    ) -> some View {
        HStack(spacing: 8) {
            if showSearch {
                Button(action: { presentSearch(from: windowManager.activeWindow?.id) }) {
                    Image(systemName: "magnifyingglass")
                        .font(.body)
                        .foregroundStyle(toolbarIconColor())
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("readerSearchButton")
            }

            if showSpeak {
                Button {
                    speakLastUsed = Date().timeIntervalSince1970
                    if speakService.isSpeaking {
                        showSpeakControls = true
                    } else {
                        controller?.speakCurrentChapter()
                        showSpeakControls = true
                    }
                } label: {
                    Image(systemName: "headphones")
                        .font(.body)
                        .foregroundStyle(toolbarIconColor())
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.plain)
            }

            if moduleHasStrongs {
                Menu {
                    ForEach(StrongsMode.allCases) { mode in
                        Button {
                            applyStrongsMode(mode.rawValue)
                        } label: {
                            if displaySettings.strongsMode ?? 0 == mode.rawValue {
                                SwiftUI.Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                } label: {
                    strongsIcon
                        .foregroundStyle(toolbarIconColor(isActive: strongsEnabled))
                } primaryAction: {
                    let current = displaySettings.strongsMode ?? 0
                    let next = (current + 1) % 3
                    applyStrongsMode(next)
                }
                .accessibilityIdentifier("readerStrongsToolbarButton")
                .accessibilityLabel(String(localized: "toggle_strongs_numbers"))
            }

            bibleToolbarIcon
                .foregroundStyle(toolbarIconColor(isActive: controller?.currentCategory == .bible))
                .contentShape(Rectangle())
                .accessibilityIdentifier("readerBibleToolbarButton")
                .accessibilityLabel(String(localized: "bible"))
                .onTapGesture {
                    if suppressBibleTapAfterLongPress {
                        suppressBibleTapAfterLongPress = false
                        return
                    }
                    handleBibleToolbarTap(controller)
                }
                .onLongPressGesture {
                    suppressBibleTapAfterLongPress = true
                    handleBibleToolbarLongPress(controller)
                }

            commentaryToolbarIcon
                .foregroundStyle(toolbarIconColor(isActive: controller?.currentCategory == .commentary))
                .contentShape(Rectangle())
                .accessibilityIdentifier("readerCommentaryToolbarButton")
                .accessibilityLabel(String(localized: "commentaries"))
                .onTapGesture {
                    if suppressCommentaryTapAfterLongPress {
                        suppressCommentaryTapAfterLongPress = false
                        return
                    }
                    handleCommentaryToolbarTap(controller)
                }
                .onLongPressGesture {
                    suppressCommentaryTapAfterLongPress = true
                    handleCommentaryToolbarLongPress(controller)
                }

            if showWorkspace {
                Button {
                    setPanePresentationTarget(windowManager.activeWindow?.id)
                    activeReaderSheet = .workspaces
                } label: {
                    workspaceToolbarIcon
                        .foregroundStyle(toolbarIconColor())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("readerWorkspacesButton")
                .accessibilityLabel(String(localized: "workspaces"))
            }

            readerOverflowToolbarButton
        }
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

    /// Popup surface color tuned closer to Android's dark and light menu treatments.
    private var readerOverflowMenuBackground: some ShapeStyle {
        if colorScheme == .dark {
            return Color(red: 0.22, green: 0.22, blue: 0.22)
        }
        return Color(.systemBackground)
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
        let currentValue = settingsDisplaySettings[keyPath: keyPath]
            ?? resolvedWorkspaceDisplaySettings()[keyPath: keyPath]
            ?? defaultValue
        settingsDisplaySettings[keyPath: keyPath] = !currentValue
        applyWorkspaceDisplaySettingsChange()
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

    /// Appends a typographic ellipsis to one overflow-menu title when it does not already have one.
    private func readerOverflowEllipsisTitle(_ title: String) -> String {
        if title.hasSuffix("…") || title.hasSuffix("...") {
            return title
        }
        return "\(title)…"
    }

    /**
     Persists workspace-scoped text-display edits and refreshes reader controllers per pane.

     - Side effects:
       - writes the current editor value into the active workspace
       - clears window-scoped Strong's overrides when the workspace Strong's mode changes, so the
         full Settings flow continues to behave workspace-wide
       - pushes each visible reader its own resolved display settings
       - reloads behavior preferences so dependent native toggles stay in sync
     - Failure modes:
       - if no active workspace exists, persistence is skipped and only controller refreshes occur
       - SwiftData save failures are intentionally swallowed via `try?`
     */
    private func applyWorkspaceDisplaySettingsChange() {
        let previousWorkspaceSettings = resolvedWorkspaceDisplaySettings()

        if let workspace = windowManager.activeWorkspace {
            workspace.textDisplaySettings = settingsDisplaySettings
            if previousWorkspaceSettings.strongsMode != settingsDisplaySettings.strongsMode {
                for window in windowManager.allWindows {
                    window.pageManager?.textDisplaySettings?.strongsMode = nil
                }
            }
            try? modelContext.save()
        }

        refreshVisibleControllerDisplaySettings()
        syncActiveDisplaySettings()
        prepareWorkspaceDisplaySettingsEditor()
        reloadBehaviorPreferences()
    }

    /// Resolves text-display settings for one specific window using the normal inheritance chain.
    private func resolvedDisplaySettings(for window: Window?) -> TextDisplaySettings {
        TextDisplaySettings.fullyResolved(
            window: window?.pageManager?.textDisplaySettings,
            workspace: windowManager.activeWorkspace?.textDisplaySettings
        )
    }

    /// Resolves the workspace-scoped settings editor state without applying window overrides.
    private func resolvedWorkspaceDisplaySettings() -> TextDisplaySettings {
        TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: windowManager.activeWorkspace?.textDisplaySettings
        )
    }

    /// Re-syncs the focused toolbar/settings state from the current active window.
    private func syncActiveDisplaySettings() {
        displaySettings = resolvedDisplaySettings(for: windowManager.activeWindow)
    }

    /// Seeds the workspace settings editor from the current workspace-level values.
    private func prepareWorkspaceDisplaySettingsEditor() {
        settingsDisplaySettings = resolvedWorkspaceDisplaySettings()
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

/// Width-collapsible accessory buttons that compete for toolbar space ahead of workspaces.
private enum ToolbarAccessoryButton {
    case search
    case speak
}

/// Trailing affordances used by the Android-style reader overflow popup rows.
private enum ReaderOverflowTrailingAccessory {
    case none
    case checkbox(Bool)
    case checkmark
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
