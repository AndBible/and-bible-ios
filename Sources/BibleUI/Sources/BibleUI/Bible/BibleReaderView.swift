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
 - XCUITest launch arguments can seed bookmark/label or history data or present the settings,
   text-display editor, color editor, sync editor, import/export sheet, label manager, or a
   seeded bookmark label-assignment sheet immediately after initial state hydration so automation
   can target nested flows without menu traversal
 - iOS `onAppear` and `onDisappear` start and stop tilt-to-scroll based on workspace settings
 - sheet dismissals reload behavior preferences or refresh installed-module lists where needed
 - toolbar toggles and helper actions mutate SwiftData-backed workspace/settings state and push
   display updates into active pane controllers
 */
public struct BibleReaderView: View {
    /**
     Test-only route used to present one seeded daily-reading screen without depending on list-row
     taps during long XCUITest bundles.
     */
    private struct UITestDailyReadingRoute: Identifiable {
        /// Identifier of the seeded reading plan that `DailyReadingView` should display.
        let id: UUID
    }

    /// Shared workspace/window coordinator that owns panes, focus, and controller registration.
    @Environment(WindowManager.self) private var windowManager

    /// Search index service passed through to `SearchView` for FTS index inspection and creation.
    @Environment(SearchIndexService.self) private var searchIndexService

    /// SwiftData context used to persist workspace settings and display-configuration changes.
    @Environment(\.modelContext) private var modelContext

    /// System color scheme used to resolve automatic night-mode behavior.
    @Environment(\.colorScheme) private var colorScheme

    /// Presents the book/chapter/verse chooser flow for the focused controller.
    @State private var showBookChooser = false

    /// Presents the full-text search sheet for the focused module.
    @State private var showSearch = false

    /// Presents bookmark browsing and navigation UI.
    @State private var showBookmarks = false

    /// Presents the consolidated settings screen.
    @State private var showSettings = false

    /// Presents the sync settings editor directly for focused workflow testing.
    @State private var showSyncSettings = false

    /// Presents the text-display editor directly for focused workflow testing.
    @State private var showTextDisplaySettings = false

    /// Presents the color-settings editor directly for focused workflow testing.
    @State private var showColorSettings = false

    /// Presents import and export management UI.
    @State private var showImportExport = false

    /// Ensures the UI-test-only initial modal presentation runs at most once per view lifetime.
    @State private var hasAppliedUITestInitialPresentation = false

    /// Presents module download and install management.
    @State private var showDownloads = false

    /// Presents reading history for jump-back navigation.
    @State private var showHistory = false

    /// Presents the compare-translations sheet.
    @State private var showCompare = false

    /// Presents reading-plan management UI.
    @State private var showReadingPlans = false

    /// Test-only seeded bookmark identifier used to launch directly into label assignment.
    @State private var uiTestLabelAssignmentBookmarkID: UUID?

    /// Test-only seeded daily-reading route used to launch directly into `DailyReadingView`.
    @State private var uiTestDailyReadingRoute: UITestDailyReadingRoute?

    /// Exported XCUITest-only history workflow state used to diagnose jump-back navigation.
    @State private var uiTestHistoryNavigationState = "idle"

    /// Exported XCUITest-only bookmark workflow state used to diagnose reader navigation.
    @State private var uiTestBookmarkNavigationState = "idle"

    /// Exported XCUITest-only StudyPad note workflow state used to diagnose shell-backed note creation.
    @State private var uiTestStudyPadNoteState = "idle"

    /// Presents the expanded speech controls sheet.
    @State private var showSpeakControls = false

    /// Workspace-resolved text and color settings pushed into every visible pane.
    @State private var displaySettings: TextDisplaySettings = .appDefaults

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

    /// Presents workspace selection and management UI.
    @State private var showWorkspaces = false

    /// Transient toast text shown above the bottom edge of the reader.
    @State private var toastMessage: String?

    /// Pending dismissal work item for the transient toast overlay.
    @State private var toastWorkItem: DispatchWorkItem?

    /// Whether the reader is currently hiding its standard chrome in fullscreen mode.
    @State private var isFullScreen = false

    /// Android-parity preference controlling whether navigation drills down to verse selection.
    @State private var navigateToVersePref = AppPreferenceRegistry.boolDefault(for: .navigateToVersePref) ?? false

    /// Android-parity preference enabling automatic fullscreen while scrolling.
    @State private var autoFullscreenPref = AppPreferenceRegistry.boolDefault(for: .autoFullscreenPref) ?? false

    /// Android-parity preference switching bookmark actions between one-step and two-step flows.
    @State private var disableTwoStepBookmarkingPref =
        AppPreferenceRegistry.boolDefault(for: .disableTwoStepBookmarking) ?? false

    /// Launch-argument override used by XCUITests to present Settings immediately on launch.
    private let uiTestOpensSettingsOnLaunch = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_SETTINGS")

    /// Launch-argument override used by XCUITests to present Text Display immediately on launch.
    private let uiTestOpensTextDisplayOnLaunch = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_TEXT_DISPLAY")

    /// Launch-argument override used by XCUITests to present Sync Settings immediately on launch.
    private let uiTestOpensSyncSettingsOnLaunch = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_SYNC")

    /// Launch-argument override enabling the in-memory XCUITest reader-shell harness.
    private let uiTestUsesInMemoryStores = ProcessInfo.processInfo.arguments.contains("UITEST_USE_IN_MEMORY_STORES")

    /// Launch-argument override used by XCUITests to present Search immediately on launch.
    private let uiTestOpensSearchOnLaunch = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_SEARCH")

    /// Launch-argument override used by XCUITests to present Colors immediately on launch.
    private let uiTestOpensColorsOnLaunch = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_COLORS")

    /// Launch-argument override used by XCUITests to present Import and Export immediately on launch.
    private let uiTestOpensImportExportOnLaunch = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_IMPORT_EXPORT")

    /// Launch-argument override used by XCUITests to present Label Manager immediately on launch.
    private let uiTestOpensLabelManagerOnLaunch = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_LABEL_MANAGER")

    /// Launch-argument override used by XCUITests to present one seeded label-assignment sheet.
    private let uiTestOpensLabelAssignmentOnLaunch = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_LABEL_ASSIGNMENT")

    /// Launch-argument override used by XCUITests to seed bookmark/label data without opening a sheet.
    private let uiTestSeedsBookmarkLabelWorkflowOnLaunch =
        ProcessInfo.processInfo.arguments.contains("UITEST_SEED_BOOKMARK_LABEL_WORKFLOW")

    /// Launch-argument override used by XCUITests to seed one labeled bookmark for StudyPad handoff.
    private let uiTestSeedsBookmarkStudyPadWorkflowOnLaunch =
        ProcessInfo.processInfo.arguments.contains("UITEST_SEED_BOOKMARK_STUDYPAD_WORKFLOW")

    /// Launch-argument override used by XCUITests to seed one bookmark-navigation target.
    private let uiTestSeedsBookmarkNavigationWorkflowOnLaunch =
        ProcessInfo.processInfo.arguments.contains("UITEST_SEED_BOOKMARK_NAVIGATION_WORKFLOW")

    /// Launch-argument override used by XCUITests to seed one persisted history target on launch.
    private let uiTestSeedsHistoryWorkflowOnLaunch =
        ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HISTORY_WORKFLOW")

    /// Launch-argument override used by XCUITests to seed two persisted history targets on launch.
    private let uiTestSeedsHistoryMultiRowWorkflowOnLaunch =
        ProcessInfo.processInfo.arguments.contains("UITEST_SEED_HISTORY_MULTIROW_WORKFLOW")

    /// Launch-argument override used by XCUITests to present Reading Plans immediately on launch.
    private let uiTestOpensReadingPlansOnLaunch = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_READING_PLANS")

    /// Launch-argument override used by XCUITests to seed one active plan and open Reading Plans.
    private let uiTestOpensDailyReadingOnLaunch = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_DAILY_READING")

    /// Launch-argument override used by XCUITests to present Workspaces immediately on launch.
    private let uiTestOpensWorkspacesOnLaunch = ProcessInfo.processInfo.arguments.contains("UITEST_OPEN_WORKSPACES")

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

    /// Presents label-management UI from the toolbar ellipsis menu.
    @State private var showLabelManager = false

    /// Presents the in-app help and tips screen.
    @State private var showHelp = false

    /// Presents the about screen.
    @State private var showAbout = false

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

    /// User-visible reference string for the currently focused Bible location.
    private var currentReference: String {
        guard let ctrl = focusedController else { return "Genesis 1" }
        return "\(ctrl.currentBook) \(ctrl.currentChapter)"
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
        .overlay(alignment: .topTrailing) {
            if uiTestUsesInMemoryStores {
                VStack(alignment: .trailing, spacing: 8) {
                    if uiTestOpensSyncSettingsOnLaunch && !showSyncSettings {
                        Button("Open Sync") {
                            showSyncSettings = true
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityIdentifier("uiTestReopenSyncSettingsButton")
                    }

                    if focusedController?.showingStudyPad == true {
                        Button("Create StudyPad Note") {
                            createUITestStudyPadNote()
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .accessibilityIdentifier("uiTestCreateStudyPadNoteButton")
                    }
                }
                .padding(.top, 12)
                .padding(.trailing, 12)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toastMessage)
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

            // Resolve display settings from workspace inheritance chain
            let workspace = windowManager.activeWorkspace
            let window = windowManager.activeWindow
            displaySettings = TextDisplaySettings.fullyResolved(
                window: window?.pageManager?.textDisplaySettings,
                workspace: workspace?.textDisplaySettings
            )

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

            if !hasAppliedUITestInitialPresentation {
                hasAppliedUITestInitialPresentation = true
                Task { @MainActor in
                    await applyUITestInitialPresentationIfNeeded()
                }
            }
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
        .overlay(alignment: .topTrailing) {
            if uiTestUsesInMemoryStores {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(currentReference)
                        .accessibilityIdentifier("readerCurrentReferenceState")
                    Text(uiTestHistoryNavigationState)
                        .accessibilityIdentifier("uiTestHistoryNavigationState")
                    Text("bookmarkNavigationState")
                        .accessibilityIdentifier("uiTestBookmarkNavigationState")
                        .accessibilityValue(uiTestBookmarkNavigationState)
                    Text("studyPadNoteState")
                        .accessibilityIdentifier("uiTestStudyPadNoteState")
                        .accessibilityValue(uiTestStudyPadNoteState)
                }
                .font(.caption2)
                .foregroundStyle(.clear)
                .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showBookChooser) {
            NavigationStack {
                BookChooserView(
                    books: focusedController?.bookList ?? BibleReaderController.defaultBooks,
                    navigateToVerse: navigateToVersePref
                ) { book, chapter, verse in
                    showBookChooser = false
                    focusedController?.navigateTo(book: book, chapter: chapter, verse: verse)
                }
            }
        }
        .sheet(isPresented: $showSearch, onDismiss: { searchInitialQuery = "" }) {
            NavigationStack {
                SearchView(
                    swordModule: focusedController?.activeModule,
                    swordManager: focusedController?.swordManager,
                    searchIndexService: uiTestUsesInMemoryStores && uiTestOpensSearchOnLaunch ? nil : searchIndexService,
                    installedBibleModules: focusedController?.installedBibleModules ?? [],
                    currentBook: focusedController?.currentBook ?? "Genesis",
                    currentOsisBookId: focusedController?.osisBookId(for: focusedController?.currentBook ?? "Genesis") ?? BibleReaderController.osisBookId(for: focusedController?.currentBook ?? "Genesis"),
                    initialQuery: searchInitialQuery,
                    onNavigate: { book, chapter in
                        showSearch = false
                        focusedController?.navigateTo(book: book, chapter: chapter)
                    }
                )
            }
        }
        .sheet(isPresented: $showBookmarks) {
            NavigationStack {
                BookmarkListView(
                    onNavigate: { book, chapter in
                        let controller = focusedController
                        showBookmarks = false
                        trackBookmarkNavigationForUITests(
                            book: book,
                            chapter: chapter,
                            controller: controller
                        )
                    },
                    onOpenStudyPad: { labelId in
                        showBookmarks = false
                        focusedController?.loadStudyPadDocument(labelId: labelId)
                    }
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(
                    displaySettings: $displaySettings,
                    nightMode: $nightMode,
                    nightModeMode: $nightModeMode,
                    onSettingsChanged: applyDisplaySettingsChange
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "done")) { showSettings = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showTextDisplaySettings) {
            NavigationStack {
                TextDisplaySettingsView(settings: $displaySettings, onChange: applyDisplaySettingsChange)
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
                ColorSettingsView(settings: $displaySettings, onChange: applyDisplaySettingsChange)
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
        .onChange(of: showSettings) { _, isPresented in
            if !isPresented {
                reloadBehaviorPreferences()
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
                    book: focusedController?.currentBook ?? "Genesis",
                    chapter: focusedController?.currentChapter ?? 1,
                    currentModuleName: focusedController?.activeModuleName ?? "",
                    resolvedOsisBookId: focusedController.flatMap { $0.osisBookId(for: $0.currentBook) }
                )
            }
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                HistoryView(
                    bookNameResolver: { [weak ctrl = focusedController] osisId in
                        ctrl?.bookName(forOsisId: osisId)
                    }
                ) { key in
                    uiTestHistoryNavigationState = "selected:\(key)"
                    let controller = focusedController
                    showHistory = false
                    Task { @MainActor in
                        await Task.yield()
                        let didNavigate = controller?.navigateToRef(key) ?? false
                        uiTestHistoryNavigationState = didNavigate ? "navigated:\(key)" : "failed:\(key)"
                    }
                }
            }
        }
        .sheet(isPresented: $showDownloads, onDismiss: {
            // Refresh installed modules list in all controllers after downloads
            for (_, ctrl) in windowManager.controllers {
                (ctrl as? BibleReaderController)?.refreshInstalledModules()
            }
        }) {
            NavigationStack {
                ModuleBrowserView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showDownloads = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showReadingPlans) {
            NavigationStack {
                ReadingPlanListView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showReadingPlans = false }
                        }
                    }
            }
        }
        .sheet(item: $uiTestDailyReadingRoute) { route in
            NavigationStack {
                DailyReadingView(planId: route.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { uiTestDailyReadingRoute = nil }
                        }
                    }
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
        .sheet(isPresented: $showWorkspaces) {
            NavigationStack {
                WorkspaceSelectorView()
            }
        }
        .sheet(isPresented: Binding(
            get: { crossReferences != nil },
            set: { if !$0 { crossReferences = nil } }
        )) {
            if let refs = crossReferences {
                CrossReferenceView(references: refs) { book, chapter in
                    crossReferences = nil
                    focusedController?.navigateTo(book: book, chapter: chapter)
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showDictionaryBrowser) {
            if let module = focusedController?.activeDictionaryModule {
                DictionaryBrowserView(module: module) { key in
                    showDictionaryBrowser = false
                    focusedController?.loadDictionaryEntry(key: key)
                }
            }
        }
        .sheet(isPresented: $showGeneralBookBrowser) {
            if let module = focusedController?.activeGeneralBookModule {
                GeneralBookBrowserView(
                    module: module,
                    title: focusedController?.activeGeneralBookModuleName ?? String(localized: "general_book")
                ) { key in
                    showGeneralBookBrowser = false
                    focusedController?.loadGeneralBookEntry(key: key)
                }
            }
        }
        .sheet(isPresented: $showMapBrowser) {
            if let module = focusedController?.activeMapModule {
                GeneralBookBrowserView(
                    module: module,
                    title: focusedController?.activeMapModuleName ?? String(localized: "map")
                ) { key in
                    showMapBrowser = false
                    focusedController?.loadMapEntry(key: key)
                }
            }
        }
        .sheet(isPresented: $showEpubLibrary) {
            EpubLibraryView { identifier in
                showEpubLibrary = false
                focusedController?.switchEpub(identifier: identifier)
                focusedController?.switchCategory(to: .epub)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showEpubBrowser = true
                }
            }
        }
        .sheet(isPresented: $showEpubBrowser) {
            if let reader = focusedController?.activeEpubReader {
                EpubBrowserView(reader: reader) { href in
                    showEpubBrowser = false
                    focusedController?.loadEpubEntry(href: href)
                }
            } else {
                // No EPUB loaded — redirect to library
                EpubLibraryView { identifier in
                    showEpubBrowser = false
                    focusedController?.switchEpub(identifier: identifier)
                    focusedController?.switchCategory(to: .epub)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showEpubBrowser = true
                    }
                }
            }
        }
        .sheet(isPresented: $showEpubSearch) {
            if let reader = focusedController?.activeEpubReader {
                EpubSearchView(reader: reader) { href in
                    showEpubSearch = false
                    focusedController?.loadEpubEntry(href: href)
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
        .sheet(item: $uiTestLabelAssignmentBookmarkID) { bookmarkId in
            NavigationStack {
                LabelAssignmentView(
                    bookmarkId: bookmarkId,
                    onDismiss: { uiTestLabelAssignmentBookmarkID = nil }
                )
            }
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
        .sheet(isPresented: $showAbout) {
            NavigationStack {
                AboutView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "done")) { showAbout = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showRefChooser) {
            NavigationStack {
                BookChooserView(books: focusedController?.bookList ?? BibleReaderController.defaultBooks) { book, chapter, _ in
                    showRefChooser = false
                    let osisId = focusedController?.osisBookId(for: book) ?? BibleReaderController.osisBookId(for: book)
                    refChooserCompletion?("\(osisId).\(chapter)")
                    refChooserCompletion = nil
                }
            }
            .presentationDetents([.large])
        }
        // MARK: - Keyboard Shortcuts (iPad/Mac)
        .background {
            Group {
                Button("") { presentSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { showBookChooser = true }
                    .keyboardShortcut("g", modifiers: .command)
                Button("") { showBookmarks = true }
                    .keyboardShortcut("b", modifiers: .command)
                Button("") { focusedController?.navigatePrevious() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("") { focusedController?.navigateNext() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("") { showDownloads = true }
                    .keyboardShortcut("d", modifiers: .command)
                Button("") { showSettings = true }
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
            displaySettings: displaySettings,
            nightMode: nightMode,
            disableTwoStepBookmarking: disableTwoStepBookmarkingPref,
            hideWindowButtons: hideWindowButtonsPref,
            speakService: speakService,
            onShowBookChooser: { showBookChooser = true },
            onShowSearch: { presentSearch() },
            onShowBookmarks: { showBookmarks = true },
            onShowSettings: { showSettings = true },
            onShowDownloads: { showDownloads = true },
            onShowHistory: { showHistory = true },
            onShowCompare: { showCompare = true },
            onShowReadingPlans: { showReadingPlans = true },
            onShowSpeakControls: { showSpeakControls = true },
            onShareText: { text in shareText = text },
            onShowCrossReferences: { refs in crossReferences = refs },
            onShowModulePicker: { category in
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
            onShowWorkspaces: { showWorkspaces = true },
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
            onSearchForStrongs: { strongsNum in presentSearch(initialQuery: strongsNum) },
            onShowStrongsSheet: { json, config in
                #if os(iOS)
                if let ctrl = focusedController {
                    let d = TextDisplaySettings.appDefaults
                    let bgInt = nightMode
                        ? (displaySettings.nightBackground ?? d.nightBackground ?? -16777216)
                        : (displaySettings.dayBackground ?? d.dayBackground ?? -1)
                    presentStrongsSheet(
                        multiDocJSON: json,
                        configJSON: config,
                        backgroundColorInt: bgInt,
                        controller: ctrl,
                        onFindAll: { strongsNum in presentSearch(initialQuery: strongsNum) }
                    )
                }
                #endif
            },
            onRefChooserDialog: { completion in
                // Present book chooser and return OSIS ref
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
                let modules = focusedController?.installedModules(for: pickerCategory) ?? []
                let activeNameForCategory = focusedController?.activeModuleName(for: pickerCategory)
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
                                showDownloads = true
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
                                focusedController?.switchCommentaryModule(to: module.name)
                                if focusedController?.currentCategory != .commentary {
                                    focusedController?.switchCategory(to: .commentary)
                                }
                            case .dictionary:
                                focusedController?.switchDictionaryModule(to: module.name)
                                focusedController?.switchCategory(to: .dictionary)
                                showModulePicker = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showDictionaryBrowser = true
                                }
                                return
                            case .generalBook:
                                focusedController?.switchGeneralBookModule(to: module.name)
                                focusedController?.switchCategory(to: .generalBook)
                                showModulePicker = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showGeneralBookBrowser = true
                                }
                                return
                            case .map:
                                focusedController?.switchMapModule(to: module.name)
                                focusedController?.switchCategory(to: .map)
                                showModulePicker = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showMapBrowser = true
                                }
                                return
                            default:
                                focusedController?.switchModule(to: module.name)
                                if focusedController?.currentCategory != .bible {
                                    focusedController?.switchCategory(to: .bible)
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
                    }
                }
            }
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
        return VStack(spacing: 0) {
            HStack {
                if controller?.showingMyNotes == true {
                    // My Notes mode: show back button
                    Button(action: { controller?.returnFromMyNotes() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.semibold))
                            Text(currentReference)
                                .font(.subheadline)
                        }
                    }
                    .accessibilityLabel(String(localized: "back_to_bible"))

                    Spacer()

                    Text(String(localized: "my_notes"))
                        .font(.headline)

                    Spacer()
                    Color.clear.frame(width: 80, height: 1)
                } else if controller?.showingStudyPad == true {
                    // StudyPad mode: show back button
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
                } else if controller?.currentCategory == .dictionary ||
                          controller?.currentCategory == .generalBook ||
                          controller?.currentCategory == .map ||
                          controller?.currentCategory == .epub {
                    // Dictionary/GenBook/Map/EPUB mode: show back button + module/key
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

                    // Browse button to open key browser
                    Button {
                        switch controller?.currentCategory {
                        case .dictionary: showDictionaryBrowser = true
                        case .generalBook: showGeneralBookBrowser = true
                        case .map: showMapBrowser = true
                        case .epub: showEpubBrowser = true
                        default: break
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.body)
                    }
                } else {
                    // Normal Bible mode — navigation + action buttons in one bar
                    // Previous chapter
                    Button(action: { controller?.navigatePrevious() }) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(controller?.hasPrevious == true ? .primary : .tertiary)
                    }
                    .disabled(controller?.hasPrevious != true)
                    .accessibilityLabel(String(localized: "previous_chapter"))

                    Button(action: { showBookChooser = true }) {
                        HStack(spacing: 4) {
                            Text(currentReference)
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("bookChooserButton")
                    .accessibilityValue(currentReference)

                    // Next chapter
                    Button(action: { controller?.navigateNext() }) {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(controller?.hasNext == true ? .primary : .tertiary)
                    }
                    .disabled(controller?.hasNext != true)
                    .accessibilityLabel(String(localized: "next_chapter"))

                    Spacer()

                    // Action buttons — matching Android toolbar order
                    HStack(spacing: 14) {
                        // Search
                        Button(action: { presentSearch() }) {
                            Image(systemName: "magnifyingglass")
                                .font(.body)
                        }
                        .accessibilityIdentifier("readerSearchButton")

                        // Strong's toggle — shown when module has Strong's data
                        // (matching Android MainBibleActivity.kt:1134).
                        // Tap cycles Off→Inline→Links, long-press shows all 4 modes.
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
                                    .opacity(strongsEnabled ? 1.0 : 0.4)
                            } primaryAction: {
                                // Tap cycles through Off(0) → Inline(1) → Links(2) → Off(0)
                                // matching Android's 3-mode quick toggle
                                let current = displaySettings.strongsMode ?? 0
                                let next = (current + 1) % 3
                                applyStrongsMode(next)
                            }
                            .accessibilityLabel(String(localized: "toggle_strongs_numbers"))
                        }

                        // TTS
                        Button {
                            if speakService.isSpeaking {
                                showSpeakControls = true
                            } else {
                                controller?.speakCurrentChapter()
                                showSpeakControls = true
                            }
                        } label: {
                            Image(systemName: "headphones")
                                .font(.body)
                        }

                        // Bible
                        Image(systemName: "book.fill")
                            .font(.body)
                            .opacity(controller?.currentCategory == .bible ? 1.0 : 0.4)
                            .contentShape(Rectangle())
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

                        // Commentary
                        Image(systemName: "text.book.closed.fill")
                            .font(.body)
                            .opacity(controller?.currentCategory == .commentary ? 1.0 : 0.4)
                            .contentShape(Rectangle())
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

                        // Ellipsis menu
                        Menu {
                            // Quick toggles
                            Toggle(isOn: Binding(
                                get: { isFullScreen },
                                set: { newValue in
                                    withAnimation(.easeInOut(duration: 0.2)) { isFullScreen = newValue }
                                    lastFullScreenByDoubleTap = false
                                    resetAutoFullscreenTracking()
                                }
                            )) {
                                SwiftUI.Label(String(localized: "fullscreen"), systemImage: "arrow.up.left.and.arrow.down.right")
                            }

                            if isNightModeQuickToggleEnabled {
                                Toggle(isOn: Binding(
                                    get: { nightMode },
                                    set: { newValue in
                                        let store = SettingsStore(modelContext: modelContext)
                                        store.setBool("night_mode", value: newValue)
                                        nightMode = NightModeSettingsResolver.isNightMode(
                                            rawValue: nightModeMode,
                                            manualNightMode: newValue,
                                            systemIsDark: colorScheme == .dark
                                        )
                                        for window in windowManager.visibleWindows {
                                            if let ctrl = windowManager.controllers[window.id] as? BibleReaderController {
                                                ctrl.updateDisplaySettings(displaySettings, nightMode: nightMode)
                                            }
                                        }
                                    }
                                )) {
                                    SwiftUI.Label(String(localized: "night_mode"), systemImage: "moon.fill")
                                }
                            }

                            #if os(iOS)
                            Toggle(isOn: Binding(
                                get: { windowManager.activeWorkspace?.workspaceSettings?.enableTiltToScroll ?? false },
                                set: { newValue in
                                    updateWorkspaceSettings { $0.enableTiltToScroll = newValue }
                                    if newValue {
                                        startTiltToScroll()
                                    } else {
                                        tiltScrollService.stop()
                                    }
                                }
                            )) {
                                SwiftUI.Label(String(localized: "tilt_to_scroll"), systemImage: "gyroscope")
                            }
                            #endif

                            if windowManager.visibleWindows.count > 1 {
                                Toggle(isOn: Binding(
                                    get: { windowManager.activeWorkspace?.workspaceSettings?.enableReverseSplitMode ?? false },
                                    set: { newValue in
                                        updateWorkspaceSettings { $0.enableReverseSplitMode = newValue }
                                    }
                                )) {
                                    SwiftUI.Label(String(localized: "reversed_split_mode"), systemImage: "rectangle.split.1x2")
                                }
                            }

                            Toggle(isOn: Binding(
                                get: { windowManager.activeWorkspace?.workspaceSettings?.autoPin ?? false },
                                set: { newValue in
                                    updateWorkspaceSettings { $0.autoPin = newValue }
                                }
                            )) {
                                SwiftUI.Label(String(localized: "window_pinning"), systemImage: "pin.fill")
                            }

                            Divider()

                            Button(String(localized: "label_settings"), systemImage: "tag") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showLabelManager = true
                                }
                            }

                            Button(String(localized: "all_text_options"), systemImage: "textformat.size") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showSettings = true
                                }
                            }

                            Divider()

                            Button(String(localized: "bookmarks"), systemImage: "bookmark") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showBookmarks = true
                                }
                            }
                            .accessibilityIdentifier("readerOpenBookmarksAction")
                            Button(String(localized: "history"), systemImage: "clock") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showHistory = true
                                }
                            }
                            .accessibilityIdentifier("readerOpenHistoryAction")
                            Button(String(localized: "compare"), systemImage: "rectangle.split.2x1") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showCompare = true
                                }
                            }
                            Button(String(localized: "reading_plans"), systemImage: "calendar") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showReadingPlans = true
                                }
                            }
                            .accessibilityIdentifier("readerOpenReadingPlansAction")
                            Button(String(localized: "settings"), systemImage: "gear") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showSettings = true
                                }
                            }
                            .accessibilityIdentifier("readerOpenSettingsAction")
                            Divider()
                            Button(String(localized: "workspaces"), systemImage: "square.stack") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showWorkspaces = true
                                }
                            }
                            .accessibilityIdentifier("readerOpenWorkspacesAction")
                            Button(String(localized: "downloads"), systemImage: "arrow.down.circle") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showDownloads = true
                                }
                            }
                            .accessibilityIdentifier("readerOpenDownloadsAction")
                            if !(controller?.installedDictionaryModules.isEmpty ?? true) {
                                Divider()
                                Button(String(localized: "dictionary"), systemImage: "character.book.closed") {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        let modules = controller?.installedDictionaryModules ?? []
                                        if modules.count == 1 {
                                            controller?.switchDictionaryModule(to: modules[0].name)
                                            controller?.switchCategory(to: .dictionary)
                                            showDictionaryBrowser = true
                                        } else {
                                            pickerCategory = .dictionary
                                            showModulePicker = true
                                        }
                                    }
                                }
                            }
                            if !(controller?.installedGeneralBookModules.isEmpty ?? true) {
                                Button(String(localized: "general_book"), systemImage: "books.vertical") {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        let modules = controller?.installedGeneralBookModules ?? []
                                        if modules.count == 1 {
                                            controller?.switchGeneralBookModule(to: modules[0].name)
                                            controller?.switchCategory(to: .generalBook)
                                            showGeneralBookBrowser = true
                                        } else {
                                            pickerCategory = .generalBook
                                            showModulePicker = true
                                        }
                                    }
                                }
                            }
                            if !(controller?.installedMapModules.isEmpty ?? true) {
                                Button(String(localized: "map"), systemImage: "map") {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        let modules = controller?.installedMapModules ?? []
                                        if modules.count == 1 {
                                            controller?.switchMapModule(to: modules[0].name)
                                            controller?.switchCategory(to: .map)
                                            showMapBrowser = true
                                        } else {
                                            pickerCategory = .map
                                            showModulePicker = true
                                        }
                                    }
                                }
                            }
                            if !EpubReader.installedEpubs().isEmpty {
                                Button(String(localized: "epub_library"), systemImage: "book") {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        showEpubLibrary = true
                                    }
                                }
                            }
                            if controller?.activeEpubReader != nil {
                                Button(String(localized: "epub_contents"), systemImage: "list.bullet") {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        showEpubBrowser = true
                                    }
                                }
                                Button(String(localized: "search_epub"), systemImage: "magnifyingglass") {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        showEpubSearch = true
                                    }
                                }
                            }
                            Divider()
                            Button(String(localized: "help_tips"), systemImage: "questionmark.circle") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showHelp = true
                                }
                            }
                            Button(String(localized: "sponsor_development"), systemImage: "heart") {
                                if let url = URL(string: "https://shop.andbible.org") {
                                    #if os(iOS)
                                    UIApplication.shared.open(url)
                                    #elseif os(macOS)
                                    NSWorkspace.shared.open(url)
                                    #endif
                                }
                            }
                            Divider()
                            Button(String(localized: "about"), systemImage: "info.circle") {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    showAbout = true
                                }
                            }
                            .accessibilityIdentifier("readerOpenAboutAction")
                            Button(String(localized: "rate_app"), systemImage: "star") {
                                #if os(iOS)
                                if let scene = UIApplication.shared.connectedScenes
                                    .compactMap({ $0 as? UIWindowScene }).first {
                                    SKStoreReviewController.requestReview(in: scene)
                                }
                                #endif
                            }
                            Button(String(localized: "report_bug"), systemImage: "ladybug") {
                                if let url = URL(string: "https://github.com/AndBible/and-bible/issues") {
                                    #if os(iOS)
                                    UIApplication.shared.open(url)
                                    #elseif os(macOS)
                                    NSWorkspace.shared.open(url)
                                    #endif
                                }
                            }
                            Button(String(localized: "tell_friend"), systemImage: "square.and.arrow.up") {
                                #if os(iOS)
                                let text = String(localized: "tell_friend_message")
                                guard let windowScene = UIApplication.shared.connectedScenes
                                    .compactMap({ $0 as? UIWindowScene }).first,
                                      let rootVC = windowScene.windows.first?.rootViewController else { return }
                                var topVC = rootVC
                                while let presented = topVC.presentedViewController { topVC = presented }
                                let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                                topVC.present(activityVC, animated: true)
                                #endif
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.body)
                        }
                        .accessibilityIdentifier("readerMoreMenuButton")
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// Strong's icon matching Android's "xα'" style.
    private var strongsIcon: some View {
        HStack(spacing: 0) {
            Text("x")
                .font(.system(size: 13, weight: .bold, design: .serif))
                .italic()
            Text("α")
                .font(.system(size: 13, weight: .bold, design: .serif))
            Text("\u{2032}")
                .font(.system(size: 10, weight: .bold))
                .baselineOffset(4)
        }
        .frame(width: 24, height: 22)
    }

    /**
     Whether the Strong's toggle should be shown for the active module.

     This mirrors Android's `isStrongsInBook` behavior by consulting the focused controller's
     resolved module features instead of a static module-category assumption.
     */
    private var moduleHasStrongs: Bool {
        focusedController?.hasStrongs ?? false
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
     Applies a Strong's display mode, persists it, and refreshes visible pane controllers.

     - Parameter mode: Raw Vue.js/config mode value (`0...3`) matching `StrongsMode`.
     - Side effects: Mutates the shared `displaySettings` value, persists it to the active
       workspace when available, and pushes updated display settings into every visible
       `BibleReaderController`.
     - Failure modes: If there is no active workspace, persistence is skipped and only in-memory
       state plus controller refreshes occur. SwiftData save failures are intentionally swallowed
       via `try?`.
     */
    private func applyStrongsMode(_ mode: Int) {
        displaySettings.strongsMode = mode
        if let workspace = windowManager.activeWorkspace {
            workspace.textDisplaySettings = displaySettings
            try? modelContext.save()
        }
        // Update all visible windows
        for window in windowManager.visibleWindows {
            if let ctrl = windowManager.controllers[window.id] as? BibleReaderController {
                ctrl.updateDisplaySettings(displaySettings, nightMode: nightMode)
            }
        }
    }

    /**
     Persists text-display edits and refreshes visible reader controllers.

     - Side effects:
       - writes the current `displaySettings` value into the active workspace when available
       - attempts to save the updated workspace through `modelContext`
       - pushes refreshed display settings into every visible `BibleReaderController`
       - reloads behavior preferences so dependent native toggles stay in sync with the latest
         persisted values
     - Failure modes:
       - if no active workspace exists, persistence is skipped and only in-memory controller
         refreshes occur
       - SwiftData save failures are intentionally swallowed via `try?`
     */
    private func applyDisplaySettingsChange() {
        if let workspace = windowManager.activeWorkspace {
            workspace.textDisplaySettings = displaySettings
            try? modelContext.save()
        }
        for window in windowManager.visibleWindows {
            if let ctrl = windowManager.controllers[window.id] as? BibleReaderController {
                ctrl.updateDisplaySettings(displaySettings, nightMode: nightMode)
            }
        }
        reloadBehaviorPreferences()
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
     Clears persisted reading plans before a direct XCUITest reading-plan workflow.
     *
     * - Side effects:
     *   - fetches all persisted `ReadingPlan` rows from SwiftData
     *   - deletes each fetched plan, relying on cascade rules for child `ReadingPlanDay` rows
     *   - saves the cleared state back to SwiftData
     * - Failure modes:
     *   - returns without mutation when the fetch fails
     *   - silently discards save failures because the reset is only used for test setup
     */
    private func resetReadingPlansForUITests() {
        let descriptor = FetchDescriptor<ReadingPlan>()
        guard let plans = try? modelContext.fetch(descriptor) else { return }
        for plan in plans {
            modelContext.delete(plan)
        }
        try? modelContext.save()
    }

    /**
     Seeds one deterministic reading plan for XCUITest daily-reading workflows.
     *
     * - Returns: Identifier of the started plan, or `nil` when no built-in template is available.
     * - Side effects:
     *   - starts the first built-in reading-plan template through `ReadingPlanService`
     *   - persists the seeded plan and its generated day rows into SwiftData
     * - Failure modes:
     *   - returns `nil` when the bundled template list is unexpectedly empty
     */
    private func seedReadingPlanForUITests() -> UUID? {
        guard let template = ReadingPlanService.availablePlans.first else { return nil }
        return ReadingPlanService.startPlan(template: template, modelContext: modelContext).id
    }

    /**
     Clears user-created labels before a direct XCUITest label-manager workflow.
     *
     * Side effects:
     * - fetches persisted `Label` rows from SwiftData
     * - deletes only real user labels, preserving system labels required by the app
     * - inserts one benign seed label so the label manager stays on its normal list code path
     * - saves the reset label state back to SwiftData
     *
     * Failure modes:
     * - returns without mutation when the fetch fails
     * - silently discards save failures because the reset is only used for test setup
     */
    private func resetLabelsForUITests() {
        let descriptor = FetchDescriptor<BibleCore.Label>()
        guard let labels = try? modelContext.fetch(descriptor) else { return }
        let bookmarkStore = BookmarkStore(modelContext: modelContext)
        let bookmarkService = BookmarkService(store: bookmarkStore)
        for label in labels where label.isRealLabel {
            bookmarkService.deleteLabel(id: label.id)
        }
        modelContext.insert(BibleCore.Label(name: "UI Test Seed"))
        try? modelContext.save()
    }

    /**
     Clears persisted bookmarks before a direct XCUITest bookmark-label workflow.
     *
     * Side effects:
     * - fetches persisted `BibleBookmark` and `GenericBookmark` rows from SwiftData
     * - deletes every fetched bookmark, relying on cascade rules for related notes and label links
     * - saves the cleared bookmark state back to SwiftData
     *
     * Failure modes:
     * - returns without mutation when either bookmark fetch fails
     * - silently discards save failures because the reset is only used for test setup
     */
    private func resetBookmarksForUITests() {
        let bibleDescriptor = FetchDescriptor<BibleBookmark>()
        let genericDescriptor = FetchDescriptor<GenericBookmark>()
        guard let bibleBookmarks = try? modelContext.fetch(bibleDescriptor),
              let genericBookmarks = try? modelContext.fetch(genericDescriptor) else { return }
        for bookmark in bibleBookmarks {
            modelContext.delete(bookmark)
        }
        for bookmark in genericBookmarks {
            modelContext.delete(bookmark)
        }
        try? modelContext.save()
    }

    /**
     Clears persisted history rows for the active window before a seeded XCUITest jump-back flow.
     *
     * Side effects:
     * - fetches all persisted `HistoryItem` rows from SwiftData
     * - deletes only the rows owned by the currently active window so other window fixtures stay
     *   untouched
     * - saves the cleared history state back to SwiftData
     *
     * Failure modes:
     * - returns without mutation when there is no active window or the history fetch fails
     * - silently discards save failures because the reset is only used for test setup
     */
    private func resetHistoryForUITests() {
        guard let activeWindowID = windowManager.activeWindow?.id else { return }
        let descriptor = FetchDescriptor<HistoryItem>()
        guard let historyItems = try? modelContext.fetch(descriptor) else { return }
        for item in historyItems where item.window?.id == activeWindowID {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    /**
     Seeds deterministic history destinations for XCUITest reader workflows.
     *
     * - Parameter keys: Stored history keys that should be appended newest-last for the active window.
     * - Side effects:
     *   - appends one `HistoryItem` row per provided key to the active window's persisted history
     *     through `WorkspaceStore`
     *   - records each key against the focused module so History can render stable rows for jump-back
     *     and row-deletion workflows
     * - Failure modes:
     *   - returns without mutation when there is no active window to own the seeded history rows
     */
    private func seedHistoryForUITests(keys: [String]) {
        guard let activeWindow = windowManager.activeWindow else { return }
        let workspaceStore = WorkspaceStore(modelContext: modelContext)
        let document = focusedController?.activeModuleName ?? "KJV"
        for key in keys {
            workspaceStore.addHistoryItem(
                to: activeWindow,
                document: document,
                key: key
            )
        }
    }

    /**
     Seeds one deterministic whole-verse Bible bookmark for XCUITest workflows.

     - Parameters:
       - book: User-visible book name that the bookmark list and reader navigation should resolve.
       - ordinalStart: Start ordinal whose chapter/verse encoding matches the bookmark list's
         simplified rendering logic.
     - Returns: Identifier of the seeded bookmark, or `nil` when the insert/save path fails.
     - Side effects:
       - inserts one whole-verse `BibleBookmark` into SwiftData
       - persists the bookmark so bookmark-list and label-assignment workflows can fetch it later
     - Failure modes:
       - returns `nil` when the save fails after insertion because the seeded workflow would be
         unable to resolve its target bookmark
     */
    private func seedBookmarkForUITests(book: String, ordinalStart: Int) -> UUID? {
        let bookmark = BibleBookmark(
            kjvOrdinalStart: ordinalStart,
            kjvOrdinalEnd: ordinalStart,
            ordinalStart: ordinalStart,
            ordinalEnd: ordinalStart,
            v11n: "KJVA"
        )
        bookmark.book = book
        modelContext.insert(bookmark)
        guard (try? modelContext.save()) != nil else { return nil }
        return bookmark.id
    }

    /**
     Seeds one deterministic Bible bookmark for direct XCUITest label-assignment workflows.
     *
     * - Returns: Identifier of the seeded bookmark, or `nil` when the insert/save path fails.
     * - Side effects:
     *   - inserts one whole-verse `BibleBookmark` into SwiftData
     *   - persists the bookmark so `LabelAssignmentView` can fetch it by identifier
     * - Failure modes:
     *   - forwards the save failure semantics from `seedBookmarkForUITests(book:ordinalStart:)`
     */
    private func seedLabelAssignmentBookmarkForUITests() -> UUID? {
        seedBookmarkForUITests(book: "Genesis", ordinalStart: 1)
    }

    /**
     Seeds one deterministic labeled bookmark for bookmark-list StudyPad workflows.
     *
     * - Returns: Identifier of the seeded bookmark, or `nil` when the bookmark or label-link save
     *   path fails.
     * - Side effects:
     *   - inserts one `Genesis 1:1` bookmark into SwiftData
     *   - assigns the seeded `UI Test Seed` label to that bookmark so bookmark filtering can expose
     *     the StudyPad handoff action
     * - Failure modes:
     *   - returns `nil` when bookmark insertion fails
     *   - returns `nil` when the seeded label cannot be resolved or the bookmark-to-label link
     *     cannot be created
     */
    private func seedBookmarkStudyPadWorkflowForUITests() -> UUID? {
        guard let bookmarkId = seedBookmarkForUITests(book: "Genesis", ordinalStart: 1) else {
            return nil
        }
        let store = BookmarkStore(modelContext: modelContext)
        guard let labelId = store.labels().first(where: { $0.name == "UI Test Seed" })?.id else {
            return nil
        }
        let service = BookmarkService(store: store)
        guard service.toggleLabel(bookmarkId: bookmarkId, labelId: labelId) != nil else {
            return nil
        }
        return bookmarkId
    }

    /**
     Creates or reuses one deterministic StudyPad note inside the active WebView-backed StudyPad.
     *
     * - Side effects:
     *   - inserts one StudyPad text entry for the active StudyPad label when the deterministic note
     *     does not already exist
     *   - persists the deterministic note text through `BookmarkService`
     *   - reloads the active StudyPad document in `BibleReaderController` so the WebView-backed
     *     StudyPad reflects the saved note
     *   - exports a tokenized success or failure state through `uiTestStudyPadNoteState`
     * - Failure modes:
     *   - exports `failed:missingContext` when no focused StudyPad controller or bookmark service
     *     is available
     *   - exports `failed:create` when StudyPad entry creation fails
     *   - exports `failed:verify` when the saved note cannot be verified after reloading the
     *     StudyPad document
     */
    private func createUITestStudyPadNote() {
        guard let controller = focusedController,
              controller.showingStudyPad,
              let labelId = controller.activeStudyPadLabelId,
              let service = controller.bookmarkService else {
            uiTestStudyPadNoteState = "failed:missingContext"
            return
        }

        let noteText = "UI Test StudyPad Note"
        let noteStateToken = "UI_Test_StudyPad_Note"

        if let existingEntry = service.studyPadEntries(labelId: labelId).first(where: { $0.textEntry?.text == noteText }) {
            controller.loadStudyPadDocument(labelId: labelId)
            let refreshedEntries = service.studyPadEntries(labelId: labelId)
            uiTestStudyPadNoteState = refreshedEntries.contains(where: {
                $0.id == existingEntry.id && $0.textEntry?.text == noteText
            }) ? "created:\(noteStateToken)" : "failed:verify"
            return
        }

        let afterOrderNumber = service.studyPadEntries(labelId: labelId).map(\.orderNumber).max() ?? -1
        guard let result = service.createStudyPadEntry(labelId: labelId, afterOrderNumber: afterOrderNumber) else {
            uiTestStudyPadNoteState = "failed:create"
            return
        }

        let entry = result.0
        service.updateStudyPadTextEntryText(id: entry.id, text: noteText)
        controller.loadStudyPadDocument(labelId: labelId)

        let refreshedEntries = service.studyPadEntries(labelId: labelId)
        uiTestStudyPadNoteState = refreshedEntries.contains(where: {
            $0.id == entry.id && $0.textEntry?.text == noteText
        }) ? "created:\(noteStateToken)" : "failed:verify"
    }

    /**
     Seeds one deterministic bookmark-navigation target for XCUITests.
     *
     * - Returns: Identifier of the seeded bookmark, or `nil` when the insert/save path fails.
     * - Side effects:
     *   - inserts one `Exodus 2:1` bookmark into SwiftData while the reader shell remains on its
     *     default `Genesis 1` position
     * - Failure modes:
     *   - forwards the save failure semantics from `seedBookmarkForUITests(book:ordinalStart:)`
     */
    private func seedBookmarkNavigationTargetForUITests() -> UUID? {
        seedBookmarkForUITests(book: "Exodus", ordinalStart: 41)
    }

    /**
     Seeds non-default theme colors for direct XCUITest color-reset workflows.

     Side effects:
     - overwrites the in-memory `displaySettings` color tuple with non-default ARGB values so the
       Colors screen starts in a known custom state
     - does not persist any settings because the route is only used with the in-memory UI-test
       container

     Failure modes: This helper cannot fail.
     */
    private func seedColorsForUITests() {
        displaySettings.dayTextColor = -1
        displaySettings.dayBackground = -16777216
        displaySettings.dayNoise = 7
        displaySettings.nightTextColor = -16777216
        displaySettings.nightBackground = -1
        displaySettings.nightNoise = 7
    }

    /**
     Seeds one deterministic remote-sync backend configuration for direct XCUITest sync workflows.

     Side effects:
     - clears any persisted WebDAV server, username, folder path, and password through
       `RemoteSyncSettingsStore`
     - persists the requested backend override so `SyncSettingsView` loads the expected section
     - disables all remote category toggles so sync workflow tests start from a clean state unless
       the launch environment explicitly requests seeded enabled categories

     Failure modes:
     - secret-store clear failures are swallowed because the route only serves the in-memory
       XCUITest harness and should not block presentation
     */
    private func seedSyncSettingsForUITests() {
        let store = RemoteSyncSettingsStore(settingsStore: SettingsStore(modelContext: modelContext))
        let backend = ProcessInfo.processInfo.environment["UITEST_SYNC_BACKEND"]
            .flatMap(RemoteSyncBackend.init(rawValue:))
            ?? .iCloud
        try? store.clearWebDAVConfiguration()
        store.selectedBackend = backend
        for category in RemoteSyncCategory.allCases {
            store.setSyncEnabled(false, for: category)
        }
        if let enabledCategories = ProcessInfo.processInfo.environment["UITEST_SYNC_ENABLED_CATEGORIES"] {
            for rawValue in enabledCategories.split(separator: ",").map(String.init) {
                if let category = RemoteSyncCategory(rawValue: rawValue) {
                    store.setSyncEnabled(true, for: category)
                }
            }
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
    private func presentSearch(initialQuery: String? = nil) {
        searchInitialQuery = initialQuery ?? ""
        Task { @MainActor in
            await Task.yield()
            showSearch = true
        }
    }

    /**
     Waits briefly for the focused reader controller to expose an active module before Search opens.

     Side effects:
     - yields on the main actor while SwiftUI and the reader controller finish initialization

     Failure modes:
     - returns after the bounded wait even if the controller still has no active module so UI tests
       can fail on the real missing-module condition instead of hanging indefinitely
     */
    @MainActor
    private func waitForUITestSearchDependencies() async {
        for _ in 0..<40 {
            if focusedController?.activeModule != nil {
                return
            }
            await Task.yield()
        }
    }

    /**
     Applies the requested XCUITest initial presentation only after the reader shell finishes its
     first render pass.
     *
     * - Side effects:
     *   - yields twice on the main actor so SwiftUI finishes mounting the reader shell before any
     *     modal or navigation state changes are applied
     *   - waits for the focused reader controller before direct Search launch so the real module
     *     search path is available to the sheet
     *   - resets or seeds deterministic state for search, color, sync, label, bookmark,
     *     reading-plan, or workspace tests as required by the active launch arguments
     *   - toggles the requested test-only presentation state or seeded navigation route
     * - Failure modes:
     *   - when no XCUITest route launch arguments are present, this helper returns without
     *     mutation
     *   - seed helpers still swallow save failures in the same way as their dedicated reset/seed
     *     helpers because the route is only used for UI automation setup
     */
    @MainActor
    private func applyUITestInitialPresentationIfNeeded() async {
        await Task.yield()
        await Task.yield()

        if uiTestOpensSearchOnLaunch {
            await waitForUITestSearchDependencies()
            presentSearch(initialQuery: ProcessInfo.processInfo.environment["UITEST_SEARCH_QUERY"] ?? "earth")
        } else if uiTestOpensTextDisplayOnLaunch {
            showTextDisplaySettings = true
        } else if uiTestOpensSyncSettingsOnLaunch {
            seedSyncSettingsForUITests()
            showSyncSettings = true
        } else if uiTestOpensColorsOnLaunch {
            seedColorsForUITests()
            showColorSettings = true
        } else if uiTestOpensImportExportOnLaunch {
            showImportExport = true
        } else if uiTestOpensLabelManagerOnLaunch {
            resetLabelsForUITests()
            showLabelManager = true
        } else if uiTestOpensLabelAssignmentOnLaunch {
            resetLabelsForUITests()
            resetBookmarksForUITests()
            uiTestLabelAssignmentBookmarkID = seedLabelAssignmentBookmarkForUITests()
        } else if uiTestSeedsBookmarkLabelWorkflowOnLaunch {
            resetLabelsForUITests()
            resetBookmarksForUITests()
            _ = seedLabelAssignmentBookmarkForUITests()
        } else if uiTestSeedsBookmarkStudyPadWorkflowOnLaunch {
            resetLabelsForUITests()
            resetBookmarksForUITests()
            _ = seedBookmarkStudyPadWorkflowForUITests()
        } else if uiTestSeedsBookmarkNavigationWorkflowOnLaunch {
            resetBookmarksForUITests()
            _ = seedBookmarkNavigationTargetForUITests()
        } else if uiTestSeedsHistoryMultiRowWorkflowOnLaunch {
            resetHistoryForUITests()
            seedHistoryForUITests(keys: ["Exod.2.1", "Matt.3.1"])
        } else if uiTestSeedsHistoryWorkflowOnLaunch {
            resetHistoryForUITests()
            seedHistoryForUITests(keys: ["Exod.2.1"])
        } else if uiTestOpensReadingPlansOnLaunch {
            resetReadingPlansForUITests()
            showReadingPlans = true
        } else if uiTestOpensDailyReadingOnLaunch {
            resetReadingPlansForUITests()
            if let seededPlanID = seedReadingPlanForUITests() {
                uiTestDailyReadingRoute = UITestDailyReadingRoute(id: seededPlanID)
            } else {
                showReadingPlans = true
            }
        } else if uiTestOpensWorkspacesOnLaunch {
            resetWorkspacesForUITests()
            showWorkspaces = true
        } else if uiTestOpensSettingsOnLaunch {
            showSettings = true
        }
    }

    /**
     Tracks bookmark-list navigation completion for XCUITests.
     *
     * - Parameters:
     *   - book: Book name passed into the bookmark navigation callback.
     *   - chapter: Chapter number passed into the bookmark navigation callback.
     *   - controller: Focused reader controller that should receive the navigation after the
     *     bookmark sheet dismisses.
     * - Side effects:
     *   - yields once on the main actor so sheet dismissal completes before reader navigation runs
     *   - calls `navigateTo(book:chapter:)` on the captured reader controller
     *   - updates `uiTestBookmarkNavigationState` as the focused controller accepts or fails the
     *     requested navigation
     *   - forces a SwiftUI state change so hidden reader diagnostics stay current under automation
     * - Failure modes:
     *   - records a `failed:` token when no focused controller is available for bookmark
     *     navigation
     *   - records a `failed:` token after the bounded wait if the focused controller never reports
     *     the requested book and chapter
     */
    @MainActor
    private func trackBookmarkNavigationForUITests(
        book: String,
        chapter: Int,
        controller: BibleReaderController?
    ) {
        guard uiTestUsesInMemoryStores else { return }
        let target = "\(book).\(chapter)"
        uiTestBookmarkNavigationState = "selected:\(target)"
        Task { @MainActor in
            guard let controller else {
                uiTestBookmarkNavigationState = "failed:\(target)"
                return
            }
            await Task.yield()
            controller.navigateTo(book: book, chapter: chapter)
            for _ in 0..<40 {
                if controller.currentBook == book, controller.currentChapter == chapter {
                    uiTestBookmarkNavigationState = "navigated:\(target)"
                    return
                }
                await Task.yield()
            }
            uiTestBookmarkNavigationState = "failed:\(target)"
        }
    }

    /**
     Clears persisted workspaces and recreates one default workspace for direct XCUITest workspace
     workflows.
     *
     * Side effects:
     * - fetches and deletes every persisted `Workspace` graph from SwiftData
     * - recreates one fresh default workspace through `WorkspaceStore`
     * - updates `WindowManager` and `SettingsStore` so the recreated workspace is active
     *
     * Failure modes:
     * - returns without mutation when the workspace fetch fails
     * - silently discards save failures because the reset is only used for test setup
     */
    private func resetWorkspacesForUITests() {
        let descriptor = FetchDescriptor<Workspace>()
        guard let workspaces = try? modelContext.fetch(descriptor) else { return }
        for workspace in workspaces {
            modelContext.delete(workspace)
        }
        try? modelContext.save()

        let workspaceStore = WorkspaceStore(modelContext: modelContext)
        let workspace = workspaceStore.createWorkspace(name: "UI Test Workspace")
        let settingsStore = SettingsStore(modelContext: modelContext)
        settingsStore.activeWorkspaceId = workspace.id
        windowManager.setActiveWorkspace(workspace)
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
