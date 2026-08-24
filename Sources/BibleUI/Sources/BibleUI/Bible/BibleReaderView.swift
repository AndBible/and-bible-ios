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
 - `onAppear` reloads persisted reader preferences and performs lightweight service reactivation;
   the first appearance alone restores speech settings and wires TTS callbacks
 - reader appearances register synchronized-scrolling callbacks on `WindowManager`
 - iOS `onAppear` and `onDisappear` start and stop tilt-to-scroll based on workspace settings
 - sheet dismissals reload behavior preferences or refresh installed-module lists where needed
 - toolbar toggles and helper actions mutate SwiftData-backed workspace/settings state and push
   display updates into active pane controllers
 */
public struct BibleReaderView: View {
    /// Identity used to recreate data-bound reader panes after the app swaps persistence runtimes.
    private let readerContentIdentity: UUID?

    /// Legacy reader-sheet boundary retained only for source guards; it intentionally has no cases.
    enum ReaderSheet {}

    /// Legacy reader-modal boundary retained only for source guards; it intentionally has no cases.
    private enum ReaderModal {}

    /// Reader-stack destinations opened from global reader actions.
    enum ReaderDestination: String, Identifiable, Hashable {
        case search
        /// Drawer-owned bookmark list destination that avoids legacy sheet chrome.
        case bookmarks
        /// Drawer-owned StudyPads selector that opens the selected StudyPad document.
        case studyPads
        /// Drawer-owned My Documents selector that opens the selected document page.
        case myDocuments
        /// Android WorkspaceSelectorActivity-equivalent reader destination.
        case workspaces
        /// Drawer-owned reading-plan list destination that avoids legacy sheet chrome.
        case readingPlans
        /// Android ReadingProgressActivity-equivalent route with captured reader-pane ownership.
        case readingProgress
        /// Android ReadingProgressSettingsActivity-equivalent reader route.
        case readingProgressSettings
        /// Android GridChoosePassageBook-equivalent full reader-stack route.
        case passageChooser
        /// Android ChooseDocument activity for a category-scoped toolbar request.
        case modulePicker
        /// Android ChooseDocument activity opened from the navigation drawer with all types.
        case chooseDocument
        /// Android BibleSpeakActivity-equivalent full reader-stack route.
        case speakControls
        /// Android SyncSettingsActivity-equivalent reader route.
        case syncSettings
        /// Android ChooseDictionaryWord-equivalent reader route.
        case dictionaryBrowser
        /// Android ChooseGeneralBookKey-equivalent reader route.
        case generalBookBrowser
        /// Android ChooseMapKey-equivalent reader route.
        case mapBrowser
        /// Android EpubSearch-equivalent reader route.
        case epubSearch
        /// Android ManageLabels-equivalent reader route.
        case labelManager
        case settings
        /// Drawer-owned AI Settings destination matching Android's Administration shortcut.
        case aiSettings
        /// Android-style startup setup route used instead of transient iOS dialog chrome.
        case startupDocumentSetup
        case downloads
        /// Backup & Restore route opened by startup setup file-import and restore actions.
        case importExport
        case globalTextOptions
        case workspaceTextOptions = "textOptions"
        case windowTextOptions
        case windowColorSettings
        case windowHiddenLabels

        var id: String { rawValue }
    }

    /// Target scope selected from Android's Copy settings to submenu.
    private enum TextSettingsCopyTarget: Hashable {
        case window(UUID)
        case workspace
        case global
    }

    /// Pending Android-style copy-settings dialog request.
    private struct TextSettingsCopyRequest: Identifiable, Hashable {
        let sourceWindowID: UUID
        let target: TextSettingsCopyTarget
        let targetTitle: String

        var id: String {
            switch target {
            case .window(let windowID):
                return "window::\(sourceWindowID.uuidString)::\(windowID.uuidString)"
            case .workspace:
                return "workspace::\(sourceWindowID.uuidString)"
            case .global:
                return "global::\(sourceWindowID.uuidString)"
            }
        }
    }

    /// Target captured while Android's recent-setting popup opens a staged quick editor.
    private struct WindowTextSettingEditorRequest: Identifiable, Equatable {
        let windowID: UUID
        let type: AndroidTextDisplaySettingType

        var id: String { "\(windowID.uuidString)::\(type.rawValue)" }
    }

    /**
     Captures the Android History dialog's source window and title.

     The request is value-based so visibility is independent of SwiftUI focus changes. Selecting a
     row must still resolve through `panePresentationController`, which is pinned by the same ID.
     */
    private struct HistoryDialogRequest: Identifiable {
        let windowID: UUID
        let title: String

        var id: UUID { windowID }
    }

    /** Captures the pane and chapter scope for Android's staged Read History dialog. */
    private struct ChapterReadHistoryDialogRequest: Identifiable {
        let windowID: UUID
        let target: ChapterReadHistoryTarget

        var id: UUID { windowID }
    }

    /** Captures Android PromptEditActivity's prompt identity for reader-stack navigation. */
    private struct AIPromptEditorDestination: Identifiable, Hashable {
        let promptID: UUID

        var id: UUID { promptID }
    }

    /// Label-assignment activity requested by a specific WebView-backed reader pane.
    private struct ReaderLabelAssignmentRoute: Identifiable, Hashable {
        /// Bookmark whose labels should be edited.
        let bookmarkId: UUID

        /// Window whose WebView should be refreshed after label assignment closes.
        let windowId: UUID?

        /// Stable presentation identity for the app-owned reader destination.
        var id: String {
            "labelAssignment::\(windowId?.uuidString ?? "active")::\(bookmarkId.uuidString)"
        }
    }

    /**
     Retains a failed generic quick-selector request so the user can retry the exact pane action.

     The selected module and captured pane identity stay together because the active pane may change
     while the error alert is visible. The value produces a stable SwiftUI identity and carries the
     actionable failure message; it has no side effects, and a missing captured pane safely resolves
     through the reader's active-pane fallback during retry.
     */
    private struct GenericQuickModuleSwitchRetry: Identifiable {
        /// Generic module selected from Android's commentary-adjacent quick menu.
        let module: ModuleInfo

        /// Pane captured when the quick selector was presented.
        let targetWindowId: UUID?

        /// Actionable SWORD validation failure shown in the retry alert.
        let message: String

        /// Stable identity for one pane-and-module retry request.
        var id: String {
            "genericQuickSwitch::\(targetWindowId?.uuidString ?? "active")::\(module.name)"
        }
    }

    /**
     Retains one Android-order locked-Bible snapshot and the manager that owns its unlock session.

     The UUID gives SwiftUI one stable queue identity while credentials are processed. The manager
     must remain alive through completion because accepted keys update its in-memory access state in
     addition to persisted SWORD configuration. The immutable installed snapshot prevents a first
     success or controller refresh from truncating Android's original full queue.

     Side effects: None; this value only retains startup input.

     Failure modes: Callers create a request only when the snapshot contains a locked Bible; an
     unexpectedly empty snapshot remains fail-closed in the startup evaluator.
     */
    private struct StartupLockedBibleUnlockRequest: Identifiable {
        /// Stable presentation identity for this one startup queue run.
        let id = UUID()

        /// Manager that validates and persists each queued credential.
        let manager: SwordManager

        /// Inclusive installed snapshot from which the queue filters locked Bibles in place.
        let installedModules: [ModuleInfo]
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
        case epubBrowser
        case epubSearch
        case help
    }

    /// Shared workspace/window coordinator that owns panes, focus, and controller registration.
    @Environment(WindowManager.self) private var windowManager

    /// Search index service passed through to `SearchView` for FTS index inspection and creation.
    @Environment(SearchIndexService.self) private var searchIndexService

    /// SwiftData context used to persist workspace settings and display-configuration changes.
    @Environment(\.modelContext) private var modelContext

    /// App-owned Sync Settings presenter that can survive runtime data-stack replacement.
    @Environment(\.presentSyncSettings) private var presentSyncSettings

    /// System color scheme used to resolve automatic night-mode behavior.
    @Environment(\.colorScheme) private var colorScheme

    /// Horizontal size class used to collapse toolbar actions on narrow iPhone layouts.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Snapshot-backed chooser progress context captured when the chooser is presented.
    @State private var passageChooserProgressContext = PassageChooserProgressContext.empty

    /// Presents the current reader-stack destination driven by drawer and overflow actions.
    @State private var activeReaderDestination: ReaderDestination?

    /// Android PromptEditActivity-equivalent destination requested by a pane-scoped AI coordinator.
    @State private var activeAIPromptEditorDestination: AIPromptEditorDestination?

    /// Reader-owned Android History dialog, kept outside generic adaptive sheet ownership.
    @State private var historyDialogRequest: HistoryDialogRequest?

    /// Reader-owned Android Read History dialog, including its originating chapter and pane.
    @State private var chapterReadHistoryDialogRequest: ChapterReadHistoryDialogRequest?

    /// Reader-owned Android Help & Tips dialog, separate from generic sheet presentation.
    @State private var isHelpDialogPresented = false

    /// Reader-owned Android Open Source License dialog, separate from browser handoff.
    @State private var isLicenseDialogPresented = false

    /// Reader-owned Android Rate & Review dialog, shown before the system review controller.
    @State private var isRateReviewDialogPresented = false

    /// Reader-owned state for manual evidence collection, consent, and addressed mail handoff.
    @State private var manualBugReportCoordinator = ManualBugReportCoordinator()

    /// Locally prepared evidence retained for consent or explicit export without presenting Mail.
    @State private var manualBugReportPreparedPayload: AddressedMailPayload?

    /// Prepared report assigned only after consent and a successful system-Mail capability check.
    @State private var manualBugReportMailPayload: AddressedMailPayload?

    /// Complete ZIP retained only while the user chooses an export destination after unavailable mail.
    @State private var manualBugReportExport: ProductFeedbackReportExport?

    /// Written ZIP retained for file cleanup on share dismissal paths that clear the sheet item first.
    @State private var manualBugReportExportPendingCleanup: ProductFeedbackReportExport?

    /// Initial search applied when Downloads is opened from an Android-compatible download link.
    @State private var downloadsInitialSearchText = ""

    /// Default-document mode applied to the next Downloads sheet presentation.
    @State private var downloadsDefaultDownloadMode: ModuleBrowserDefaultDownloadMode = .disabled

    /// Tracks whether Android Easy Start default downloads are still refreshing or installing.
    @State private var startupDefaultDownloadsInFlight = false

    /// Reason the startup document-setup prompt should be visible.
    @State private var startupDownloadPromptReason: StartupDocumentSetupPromptPolicy.PromptReason?

    /// Android-parity automatic credential queue shown before locked-only startup setup.
    @State private var startupLockedBibleUnlockRequest: StartupLockedBibleUnlockRequest?

    /// Startup restore/import target passed to Backup & Restore for direct Android-style pickers.
    @State private var startupRestoreImportTarget: RestoreWorkflowTarget?

    /// Guards startup prompt evaluation so it does not reappear repeatedly in one session.
    @State private var didEvaluateStartupDownloadPrompt = false

    /// Optional explicit tab requested by the Android-compatible reading-progress bridge.
    @State private var readingProgressInitialTab: ReadingProgressTab?

    /// Parent activities retained while one app-owned reader destination opens another.
    @State private var readerDestinationBackStack: [ReaderDestination] = []

    /// Pushes WebView-originated bookmark label assignment onto the reader-owned activity stack.
    @State private var activeReaderLabelAssignmentRoute: ReaderLabelAssignmentRoute?

    /// Presents the reader's overflow action sheet.
    @State private var showReaderOverflowMenu = false

    /// Exact restore-strip window whose shared Android popup is currently owned by the reader.
    @State private var windowTabMenuWindowID: UUID?

    /// Whether the reader-wide anchored popup for a restore-strip window is visible.
    @State private var showWindowTabMenu = false

    /// Reader-session owner matching Android's shared typed `clipboardKey` state.
    @State private var windowMenuReferenceStore = BibleWindowMenuReferenceStore()

    /// Canonical single-label Study Pad archive owner used by window-popup export.
    @State private var windowMenuStudyPadArchiveWorkflow = AndroidStudyPadArchiveWorkflow()

    /// Shared Bookmark-list CSV workflow used by Study Pad window-popup export.
    @State private var windowMenuCSVExportWorkflow = AndroidBookmarkCSVExportWorkflow()

    /// Presents Android's compact Bible-module quick selector anchored to the toolbar button.
    @State private var showBibleQuickModuleSelector = false

    /// Rows resolved by the Android-parity quick-selector contract for the active popup instance.
    @State private var bibleQuickModuleSelectorRows: [BibleReaderQuickModuleSelectorPresentation.Row] = []

    /// Window that owns the active Bible quick selector, kept separate from modal routing state.
    @State private var bibleQuickModuleSelectorTargetWindowId: UUID?

    /// Presents Android's compact commentary/document quick selector anchored to the toolbar button.
    @State private var showCommentaryQuickModuleSelector = false

    /// Rows resolved by Android's commentary quick-selector contract for the active popup instance.
    @State private var commentaryQuickModuleSelectorRows: [BibleReaderQuickModuleSelectorPresentation.Row] = []

    /// Window that owns the active commentary quick selector, kept separate from modal routing state.
    @State private var commentaryQuickModuleSelectorTargetWindowId: UUID?

    /// Failed generic quick-selector action retained for an explicit user retry.
    @State private var pendingGenericQuickModuleSwitchRetry: GenericQuickModuleSwitchRetry?

    /// Presents the Android-style left navigation drawer from the reader header.
    @State private var showReaderNavigationDrawer = false

    /// Identifies the only drawer action still allowed to run after its dismissal animation.
    @State private var pendingReaderNavigationDrawerActionID: UUID?

    /// Active shared Android preference dialog opened from a window's recent-setting popup.
    @State private var windowTextSettingEditorRequest: WindowTextSettingEditorRequest?

    /// Staged effective settings mutated by the shared quick preference editor.
    @State private var windowTextSettingEditorSettings: TextDisplaySettings = .appDefaults

    /// Effective target settings captured before a quick editor commit/reset.
    @State private var windowTextSettingEditorPreviousSettings: TextDisplaySettings = .appDefaults

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

    /// Pending Android-style selective copy-settings dialog opened from a pane hamburger menu.
    @State private var textSettingsCopyRequest: TextSettingsCopyRequest?

    /// Workspace-scoped text-display state edited from Android's main reader All Text Options route.
    @State private var workspaceDisplaySettings: TextDisplaySettings = .appDefaults

    /// Workspace metadata color currently driving Android-parity reader toolbar chrome.
    @State private var workspaceChromeColor: Int = Workspace.defaultWorkspaceColor

    /// Effective night-mode value currently applied to pane controllers and overlays.
    @State private var nightMode = false

    /// Stored night-mode strategy (`system`, `manual`, or other Android-parity raw values).
    @State private var nightModeMode = AppPreferenceRegistry.stringDefault(for: .nightModePref3) ?? NightModeSetting.system.rawValue

    /// Shared text-to-speech service used by all panes and speak-related overlays.
    @StateObject private var speakService = SpeakService()

    /// Guards heavyweight speech restoration and callback binding to the first reader appearance.
    @State private var speechLifecycleState = BibleReaderSpeechLifecycleState()

    /// Pending plain-text payload for the native share sheet.
    @State private var shareText: String?

    /// Pending My Documents payload whose title and body must remain separate for native sharing.
    @State private var myDocumentSharePayload: MyDocumentSharePayload?

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

    /// Android monochrome/e-ink preference used by native reader toolbar chrome.
    @State private var monochromeModePref =
        AppPreferenceRegistry.boolDefault(for: .monochromeMode) ?? false

    /// Tracks whether fullscreen was last entered by the double-tap gesture instead of scrolling.
    @State private var lastFullScreenByDoubleTap = false

    /// Accumulated user scroll state toward the auto-fullscreen threshold.
    @State private var autoFullscreenTracking = ReaderAutoFullscreenTracking()

    /// Initial query forwarded into `SearchView`, usually from Strong's lookups.
    @State private var searchInitialQuery = ""

    /// Whether the current Search destination was opened by Strong's Find All.
    @State private var searchIsStrongsFindAll = false

    /// Window that owns the currently presented pane-scoped sheet or chooser flow.
    @State private var panePresentationTargetWindowId: UUID?

    /// Ensures the launch-seeded UI-test Search destination is only auto-presented once per app session.
    @State private var didPresentUITestLaunchSearch = false

    /// One-shot completion state for the bridge-driven reference chooser flow.
    @State private var refChooserRequest = BibleReaderReferenceChooserRequest()

    /// Generation whose bridge-driven full-screen chooser is currently presented.
    @State private var refChooserPresentation: BibleReaderReferenceChooserRequest.Generation?
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
        return BibleReaderPanePresentationTarget.controller(
            targetWindowId: panePresentationTargetWindowId,
            controllers: windowManager.controllers,
            activeWindow: windowManager.activeWindow,
            as: BibleReaderController.self
        )
    }

    /**
     Canonical installed-module root for the active pane-scoped Android add-on surfaces.

     - Returns: The presented pane manager's root, or the app's canonical SWORD root while that
       controller is still registering.
     - Side effects: Reads controller registration state only.
     - Failure modes: A missing controller resolves to the canonical app root rather than an empty
       or omission-tolerant font inventory.
     */
    private var paneModuleStoreRootURL: URL {
        URL(
            fileURLWithPath: panePresentationController?.swordManager?.modulePath
                ?? SwordManager.defaultModulePath(),
            isDirectory: true
        )
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
            surfacePalette: readerThemeSurfacePalette,
            onDismiss: { activeReaderDestination = nil }
        )
    }

    /// Captures the window that should own the next pane-scoped presentation.
    private func setPanePresentationTarget(_ windowId: UUID?) {
        panePresentationTargetWindowId = BibleReaderPanePresentationTarget.capturedWindowId(
            requested: windowId,
            activeWindow: windowManager.activeWindow
        )
    }

    /// Window captured for the currently presented pane-scoped destination, if it is still loaded.
    private var panePresentationTargetWindow: BibleCore.Window? {
        BibleReaderPanePresentationTarget.window(
            targetWindowId: panePresentationTargetWindowId,
            allWindows: windowManager.allWindows,
            activeWindow: windowManager.activeWindow
        )
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

    /**
     Workspace accent-color binding for Android's workspace-scope color settings row.

     The nested color settings screen edits `TextDisplaySettings`, but Android carries
     `workspace_color` as workspace metadata. This binding keeps the metadata separate from the
     inherited text-display model while letting the same color editor persist it through the normal
     workspace save callback.

     - Returns: A binding that resolves nil stored colors to Android's `#ff444444` fallback and
       writes edits to the pane target workspace when available.
     - Side effects: Setting the binding mutates `Workspace.workspaceColor`, refreshes reader chrome,
       and saves the view's model context.
     - Failure modes: If the target workspace no longer exists, writes are ignored.
     */
    private var workspaceColorBinding: Binding<Int?> {
        Binding(
            get: {
                let workspace = panePresentationTargetWindow?.workspace ?? windowManager.activeWorkspace
                return workspace?.workspaceColor ?? Workspace.defaultWorkspaceColor
            },
            set: { newValue in
                let workspaceID = panePresentationTargetWindow?.workspace?.id ?? windowManager.activeWorkspace?.id
                let workspace = workspaceID.flatMap { WorkspaceStore(modelContext: modelContext).workspace(id: $0) }
                let resolvedColor = newValue ?? Workspace.defaultWorkspaceColor
                workspace?.workspaceColor = resolvedColor
                workspaceChromeColor = resolvedColor
                try? modelContext.save()
            }
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
        let tabOrders = windowManager.allWindows
            .map { "\($0.orderNumber)" }
            .joined(separator: ",")
        let tabOrdersToken = "windowTabOrders=\(tabOrders.isEmpty ? "none" : tabOrders)"
        let exportController = focusedController
        let contentToken = exportController?.renderedContentState
            ?? BibleReaderController.emptyRenderedContentState
        let myNotesToken = exportController?.myNotesAccessibilityState
            ?? MyNotesAccessibilitySnapshot.empty.encodedValue
        let studyPadToken = exportController?.studyPadAccessibilityState
            ?? StudyPadAccessibilitySnapshot.empty.encodedValue
        let resolvedDisplay = resolvedDisplaySettings(for: windowManager.activeWindow)
        let strongsMode = resolvedDisplay.strongsMode
            ?? TextDisplaySettings.appDefaults.strongsMode
            ?? 0
        // Rendered-effect assertions still need frame or screenshot evidence; these tokens let
        // tests distinguish "setting never resolved" from "resolved but not rendered" cheaply.
        let displayMaxWidthToken =
            "displayMaxWidth=\(resolvedDisplay.maxWidth ?? TextDisplaySettings.appDefaults.maxWidth ?? 170)"
        let displayFontSizeToken =
            "displayFontSize=\(resolvedDisplay.fontSize ?? TextDisplaySettings.appDefaults.fontSize ?? 16)"
        let drawerToken = "drawerVisible=\(showReaderNavigationDrawer ? "true" : "false")"
        let overflowToken = "overflowVisible=\(showReaderOverflowMenu ? "true" : "false")"
        let destinationToken = "readerDestination=\(activeReaderDestination?.rawValue ?? "none")"
        let modalToken = "readerModal=none"
        let historyDialogToken = "historyDialog=\(historyDialogRequest == nil ? "none" : "presented")"
        let searchToken = "searchVisible=\(activeReaderDestination == .search ? "true" : "false")"
        let nightModeToken = "nightMode=\(nightMode ? "true" : "false")"
        let strongsModeToken = "strongsMode=\(strongsMode)"
        let readerBackgroundToken =
            "readerBackground=\(readerThemeSurfacePalette.backgroundColorInt)"
        return [
            windowToken,
            contentToken,
            tabOrdersToken,
            myNotesToken,
            studyPadToken,
            strongsModeToken,
            drawerToken,
            overflowToken,
            destinationToken,
            modalToken,
            historyDialogToken,
            searchToken,
            nightModeToken,
            readerBackgroundToken,
            displayMaxWidthToken,
            displayFontSizeToken,
        ].joined(separator: ";")
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

    /// Height the Android-parity window tab bar reserves below reader content.
    private var windowTabBarReservedHeight: CGFloat {
        guard shouldShowWindowTabBar else { return 0 }
        let restoreButtonsVisible = windowManager.activeWorkspace?.workspaceSettings?.restoreButtonsVisible ?? true
        let singleWindowFooterMode = !windowManager.isMaximized
            && windowManager.allWindows.count <= 1
            && windowManager.visibleWindows.count <= 1
        return WindowTabBarLayout.reservedHeight(
            restoreButtonsVisible: restoreButtonsVisible,
            isSingleWindowFooterMode: singleWindowFooterMode
        )
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

    /// Reader-shell palette derived from active pane content settings and workspace chrome color.
    private var readerThemeSurfacePalette: ReaderThemeSurfacePalette {
        ReaderThemeSurfacePalette(
            settings: displaySettings,
            nightMode: nightMode,
            workspaceColor: workspaceChromeColor,
            monochromeMode: monochromeModePref
        )
    }

    /// Bottom inset for the floating reference capsule, accounting for other bottom chrome.
    private var bibleReferenceOverlayBottomPadding: CGFloat {
        let reservedTabBarHeight = windowTabBarReservedHeight
        var padding: CGFloat = reservedTabBarHeight > 0
            ? reservedTabBarHeight + 6
            : 16
        if speakService.isSpeaking {
            padding += 56
        }
        return padding
    }

    /**
     Binding that presents the native share sheet while a share payload exists.

     - Returns: A Boolean binding derived from either reader text or My Documents share state.
     - Side effects: Setting the binding to `false` clears both pending share payload forms.
     - Failure modes: none.
     */
    private var shareSheetBinding: Binding<Bool> {
        Binding(
            get: { shareText != nil || myDocumentSharePayload != nil },
            set: { isPresented in
                if !isPresented {
                    shareText = nil
                    myDocumentSharePayload = nil
                }
            }
        )
    }

    /**
     Creates the reader coordinator view.

     - Note: This initializer performs no work directly. The view resolves its dependencies from
       the SwiftUI environment when rendered.
     */
    public init(readerContentIdentity: UUID? = nil) {
        self.readerContentIdentity = readerContentIdentity
    }

    /**
     Builds the reader content plus always-on reader overlays.

     Keeping this chain out of `body` gives Swift smaller expressions to type-check while
     preserving the same runtime view hierarchy.
     */
    private var readerScreenWithReaderOverlays: some View {
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
                textSettingsCopyDialogOverlay
                historyDialogOverlay
                chapterReadHistoryDialogOverlay
                windowMenuTransferDialogOverlay
                helpDialogOverlay
                licenseDialogOverlay
                rateReviewDialogOverlay
                bugReportDialogOverlay
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
            .overlayPreferenceValue(ReaderCommentaryToolbarButtonBoundsPreferenceKey.self) { anchor in
                if showCommentaryQuickModuleSelector {
                    commentaryQuickModuleSelectorOverlay(anchor: anchor)
                }
            }
            .sheet(item: $manualBugReportMailPayload, onDismiss: finishBugReportMailPresentation) { payload in
                AddressedMailComposer(payload: payload, onFinish: {
                    manualBugReportMailPayload = nil
                }, onResult: { result in
                    manualBugReportCoordinator.finishMail(result)
                    manualBugReportPreparedPayload = nil
                })
            }
            .sheet(item: $manualBugReportExport, onDismiss: finishBugReportExportShare) { export in
                ShareSheet(items: [export.fileURL]) { _ in
                    manualBugReportExport = nil
                }
            }
    }

    /**
     Builds the full reading-screen hierarchy.

     The body composes the document header, split pane layout, sheet presenters, keyboard
     shortcuts, fullscreen overlays, toast feedback, and speech mini-player around the current
     `WindowManager` state.
     */
    public var body: some View {
        readerScreenWithLifecycleModifiers
    }

    /// Attaches reader presentation surfaces while keeping SwiftUI's inferred view types bounded.
    private var readerScreenWithPresentationModifiers: some View {
        readerScreenWithReaderOverlays
        .animation(.easeInOut(duration: 0.25), value: toastMessage)
        .animation(.easeInOut(duration: 0.2), value: showReaderNavigationDrawer)
        .animation(.easeInOut(duration: 0.16), value: showReaderOverflowMenu)
        .animation(.easeInOut(duration: 0.16), value: showBibleQuickModuleSelector)
        .animation(.easeInOut(duration: 0.16), value: showCommentaryQuickModuleSelector)
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
            dismissCommentaryQuickSelector()
            syncActiveDisplaySettings()
        }
        .onChange(of: windowManager.controllerVersion) { _, _ in
            evaluateStartupDownloadPromptIfNeeded()
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
        .navigationDestination(item: $activeReaderDestination) { destination in
            readerDestinationContent(destination)
        }
        .navigationDestination(item: $activeAIPromptEditorDestination) { destination in
            aiPromptEditorDestinationContent(destination)
        }
        .navigationDestination(item: $activeReaderLabelAssignmentRoute) { route in
            readerLabelAssignmentContent(route)
        }
        .overlay {
            if let request = windowTextSettingEditorRequest,
               let editor = request.type.editorKind {
                AndroidTextDisplayPreferenceEditorDialog(
                    editor: editor,
                    settings: $windowTextSettingEditorSettings,
                    scope: .window,
                    providedFontNames: TextDisplaySettingsView.admittedFontNames(
                        moduleStoreRootURL: URL(
                            fileURLWithPath: controller(for: request.windowID)?.swordManager?.modulePath
                                ?? SwordManager.defaultModulePath(),
                            isDirectory: true
                        )
                    ),
                    surfacePalette: readerThemeSurfacePalette,
                    onCommit: {
                        finishWindowTextSettingEditor(request, recordsRecentType: true)
                    },
                    onReset: {
                        finishWindowTextSettingEditor(request, recordsRecentType: false)
                    },
                    onCancel: { windowTextSettingEditorRequest = nil }
                )
                .zIndex(40)
            }
        }
        .overlay {
            if let retry = pendingGenericQuickModuleSwitchRetry {
                genericQuickModuleSwitchRetryDialog(retry)
            }
        }
        .overlay {
            if let request = startupLockedBibleUnlockRequest {
                StartupLockedBibleUnlockQueueView(
                    installedModules: request.installedModules,
                    unlockModule: { moduleName, cipherKey in
                        request.manager.unlockModule(
                            named: moduleName,
                            withCipherKey: cipherKey
                        )
                    },
                    onComplete: {
                        completeStartupLockedBibleUnlockQueue(request)
                    }
                )
                .id(request.id)
                .zIndex(50)
            }
        }
    }

    /**
     Builds the shared Android decision dialog for one failed generic quick-module switch.

     - Parameter retry: Captured module, pane identity, and actionable validation message.
     - Returns: A retry/cancel dialog using the application-owned dialog window and palette.
     - Side effects: Cancel clears the pending request; Retry clears it and repeats the exact
       pane-scoped selection once.
     - Failure modes: If the target pane disappeared, the existing selection path applies its
       documented active-pane fallback and reports any subsequent failure normally.
     */
    private func genericQuickModuleSwitchRetryDialog(
        _ retry: GenericQuickModuleSwitchRetry
    ) -> some View {
        AndroidDecisionDialog(
            title: String(localized: "error_occurred"),
            message: retry.message,
            actions: [
                .init(
                    id: "cancel",
                    title: String(localized: "cancel"),
                    style: .normal,
                    perform: { pendingGenericQuickModuleSwitchRetry = nil }
                ),
                .init(
                    id: "retry",
                    title: String(localized: "retry"),
                    style: .normal,
                    perform: {
                        pendingGenericQuickModuleSwitchRetry = nil
                        selectCommentaryQuickModule(
                            retry.module,
                            targetWindowId: retry.targetWindowId
                        )
                    }
                ),
            ],
            accessibilityIdentifier: "genericQuickModuleSwitchRetryDialog"
        )
        .zIndex(40)
    }

    /// Attaches reader lifecycle observation and system handoffs after presentation ownership.
    private var readerScreenWithLifecycleModifiers: some View {
        readerScreenWithPresentationModifiers
        .onChange(of: activeReaderDestination) { oldValue, newValue in
            handleActiveReaderDestinationChange(from: oldValue, to: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: SwordModuleStore.modulesDidChangeNotification)) { _ in
            Task { @MainActor in
                handleModuleStoreDidChange()
            }
        }
        .onChange(of: showReaderOverflowMenu) { _, isPresented in
            handleReaderOverflowMenuChange(isPresented)
        }
        .onChange(of: colorScheme) { _, _ in
            updateNightModeForCurrentColorScheme()
        }
        .onChange(of: isFullScreen) { _, fullScreen in
            handleFullScreenChange(fullScreen)
        }
        .sheet(isPresented: shareSheetBinding) {
            shareSheetContent
        }
        .fileExporter(
            isPresented: Binding(
                get: { windowMenuStudyPadArchiveWorkflow.showsFileExporter },
                set: { windowMenuStudyPadArchiveWorkflow.showsFileExporter = $0 }
            ),
            document: windowMenuStudyPadArchiveWorkflow.exportDocument,
            contentType: .zip,
            defaultFilename: windowMenuStudyPadArchiveWorkflow.exportFileName,
            onCompletion: windowMenuStudyPadArchiveWorkflow.handleFileExportCompletion
        )
        .fileExporter(
            isPresented: Binding(
                get: { windowMenuCSVExportWorkflow.showsFileExporter },
                set: { windowMenuCSVExportWorkflow.showsFileExporter = $0 }
            ),
            document: windowMenuCSVExportWorkflow.exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: windowMenuCSVExportWorkflow.exportFileName,
            onCompletion: windowMenuCSVExportWorkflow.handleFileExportCompletion
        )
        .overlay {
            if let generation = refChooserPresentation {
                ReaderPassageChooserOverlay {
                    refChooserSheetContent(for: generation)
                        .onDisappear {
                            handleReferenceChooserDismissal(for: generation)
                        }
                }
            }
        }
        // MARK: - Keyboard Shortcuts (iPad/Mac)
        .background {
            keyboardShortcutSurface
        }
    }

    /**
     Builds the persistent reader chrome and split-pane hierarchy before transient presentations.

     On iOS the hierarchy ignores keyboard safe-area contraction so presenting a focused Vue editor
     cannot resize the split container or reconstruct pane hosts. Each child `BibleWebViewController`
     still follows `UIKeyboardLayoutGuide`, which alone resizes the interactive web surface above the
     docked keyboard, matching Android's IME-inset behavior.

     - Returns: Reader header, split content, speech controls, and window strip in one stable stack.
     - Side Effects: None during construction; child views retain their documented lifecycle effects.
     - Failure Modes: Floating keyboards intentionally do not contract the web surface; UIKit/WebKit
       retain their standard cursor-scrolling behavior.
     */
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
                .id(readerContentIdentity)

            // Persistent mini-player when speaking (visible even in fullscreen)
            if speakService.isSpeaking {
                BibleReaderSpeakMiniPlayer(
                    speakService: speakService,
                    currentReference: currentReference,
                    onShowControls: { presentReaderDestination(.speakControls) },
                    surfacePalette: surfacePalette
                )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // Bottom window tab bar — hidden in fullscreen mode
            if shouldShowWindowTabBar {
                WindowTabBar(
                    surfacePalette: surfacePalette,
                    monochromeMode: monochromeModePref,
                    onPresentWindowMenu: { presentWindowTabMenu(for: $0) }
                )
            }
        }
        #if os(iOS)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        #endif
        .foregroundStyle(surfacePalette.foregroundColor)
        .background(surfacePalette.backgroundColor.ignoresSafeArea())
        .androidAnchoredPopupMenu(
            anchorID: windowTabMenuWindowID.map { WindowTabMenuAnchor.id(for: $0) }
                ?? "windowTabMenu::none",
            isPresented: $showWindowTabMenu,
            menuWidth: 320,
            estimatedMenuHeight: 440,
            accessibilityIdentifier: "windowTabMenu"
        ) {
            windowTabMenuPopup
        }
    }

    /// Floating current-reference capsule shown during fullscreen reading.
    @ViewBuilder
    private var bibleReferenceOverlay: some View {
        if shouldShowBibleReferenceOverlay {
            AndroidBibleReferenceOverlay(reference: currentReference)
                .padding(.bottom, bibleReferenceOverlayBottomPadding)
                .transition(.opacity)
        }
    }

    /// Transient toast shown above the window tab bar.
    @ViewBuilder
    private var toastOverlay: some View {
        if let message = toastMessage {
            AndroidToastOverlay(message: message, bottomPadding: 80)
        }
    }

    /// Android-style selective copy-settings dialog overlay.
    @ViewBuilder
    private var textSettingsCopyDialogOverlay: some View {
        if let request = textSettingsCopyRequest {
            TextDisplaySettingsCopyDialog(
                targetTitle: request.targetTitle,
                onCancel: { textSettingsCopyRequest = nil },
                onConfirm: { fields in
                    applyTextSettingsCopy(request, fields: fields)
                    textSettingsCopyRequest = nil
                }
            )
            .transition(.opacity)
            .zIndex(20)
        }
    }

    /**
     Presents the app-owned portions of Android's Study Pad window export workflows.

     CSV reuses the Bookmark-list column selector and archive/CSV outcomes reuse shared Android
     decision surfaces. Only the final file destination is a platform handoff.
     */
    @ViewBuilder
    private var windowMenuTransferDialogOverlay: some View {
        if windowMenuCSVExportWorkflow.showsColumnSelector {
            BookmarkCSVColumnSelectionView(
                selectedColumns: windowMenuCSVExportWorkflow.selectedColumns,
                onExport: { columns in
                    windowMenuCSVExportWorkflow.prepareExport(
                        columns: columns,
                        modelContext: modelContext
                    )
                },
                onCancel: windowMenuCSVExportWorkflow.cancelColumnSelection
            )
        } else if let feedback = windowMenuCSVExportWorkflow.feedback {
            AndroidDecisionDialog(
                title: feedback.title,
                message: feedback.message,
                actions: [
                    .init(
                        id: "ok",
                        title: String(localized: "ok", defaultValue: "OK"),
                        style: .normal
                    ) {
                        windowMenuCSVExportWorkflow.feedback = nil
                    },
                ],
                accessibilityIdentifier: "windowMenuCSVExportFeedbackDialog"
            )
        } else if let feedback = windowMenuStudyPadArchiveWorkflow.feedback {
            AndroidDecisionDialog(
                title: feedback.title,
                message: feedback.message,
                actions: [
                    .init(
                        id: "ok",
                        title: String(localized: "ok", defaultValue: "OK"),
                        style: .normal
                    ) {
                        windowMenuStudyPadArchiveWorkflow.feedback = nil
                    },
                ],
                accessibilityIdentifier: "windowMenuStudyPadExportFeedbackDialog"
            )
        }
    }

    /**
     Renders Android's dialog-themed History activity as a reader-owned app window.

     The overlay is present only while a request exists. It deliberately captures the originating
     pane through `panePresentationTargetWindowId`, so a user can change focus behind the dialog
     without selecting or navigating the wrong window.
     */
    @ViewBuilder
    private var historyDialogOverlay: some View {
        if let request = historyDialogRequest {
            AndroidHistoryDialog(
                activeWindowID: request.windowID,
                title: request.title,
                bookNameResolver: { osisID in
                    panePresentationController?.bookName(forOsisId: osisID)
                },
                onDismiss: dismissHistoryDialog,
                onNavigate: { key in
                    let controller = panePresentationController
                    dismissHistoryDialog()
                    _ = controller?.navigateToRef(key)
                }
            )
            .transition(.opacity)
            .zIndex(20)
        }
    }

    /** Renders Android's staged-delete Read History surface as a captured app-owned dialog. */
    @ViewBuilder
    private var chapterReadHistoryDialogOverlay: some View {
        if let request = chapterReadHistoryDialogRequest {
            AndroidChapterReadHistoryDialog(
                store: panePresentationController?.readingProgressStore,
                target: request.target,
                onDismiss: dismissChapterReadHistoryDialog
            )
            .transition(.opacity)
            .zIndex(20)
        }
    }

    /** Renders Android Help & Tips as an app-owned dialog rather than an adaptive sheet. */
    @ViewBuilder
    private var helpDialogOverlay: some View {
        if isHelpDialogPresented {
            AndroidHelpDialog(onDismiss: dismissHelpDialog)
                .transition(.opacity)
                .zIndex(20)
        }
    }

    /** Renders Android's bundled Open Source License dialog without a browser handoff. */
    @ViewBuilder
    private var licenseDialogOverlay: some View {
        if isLicenseDialogPresented {
            AndroidLicenseDialog(onDismiss: dismissLicenseDialog)
                .transition(.opacity)
                .zIndex(20)
        }
    }

    /** Renders Android's explanatory Rate & Review dialog before the system store handoff. */
    @ViewBuilder
    private var rateReviewDialogOverlay: some View {
        if isRateReviewDialogPresented {
            AndroidRateReviewDialog(
                onDismiss: dismissRateReviewDialog,
                onProceed: proceedToSystemReview,
                onContactSupport: { openExternalLink("mailto:help.andbible@gmail.com") },
                onReportBug: { openExternalLink("https://github.com/AndBible/and-bible/issues") },
                onContactMaintainers: { openExternalLink("https://github.com/AndBible/and-bible/issues") },
                onLearnToContribute: { openExternalLink("https://github.com/AndBible/and-bible/wiki/How-to-contribute") }
            )
            .transition(.opacity)
            .zIndex(20)
        }
    }

    /** Renders collection progress, consent, and explicit unavailable-mail state. */
    @ViewBuilder
    private var bugReportDialogOverlay: some View {
        switch manualBugReportCoordinator.phase {
        case .idle, .presentingMail:
            EmptyView()
        case .collecting, .exporting:
            AndroidBugReportPreparationDialog(isExportRetry: manualBugReportCoordinator.phase == .exporting)
                .transition(.opacity)
                .zIndex(20)
        case .awaitingConsent:
            if let payload = manualBugReportPreparedPayload {
                AndroidBugReportDialog(
                    onDismiss: dismissBugReportDialog,
                    onSendReport: { presentPreparedBugReport(payload) }
                )
                .transition(.opacity)
                .zIndex(20)
            }
        case .mailUnavailable, .exportFailed:
            if let payload = manualBugReportPreparedPayload {
                AndroidBugReportUnsentDialog(
                    onDismiss: dismissBugReportDialog,
                    onExport: { exportPreparedBugReport(payload) },
                    exportFailed: manualBugReportCoordinator.phase == .exportFailed
                )
                    .transition(.opacity)
                    .zIndex(20)
            }
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

    /**
     Builds Android's passage chooser as a reader-owned navigation destination.

     `BookChooserView` owns its fixed dark appearance inside its own environment, matching
     Android's separately themed `GridChoosePassageTheme` activity. This destination must not set
     `preferredColorScheme`, because a preference emitted from a pushed SwiftUI destination
     retargets the enclosing window and can be misread by the reader as a system appearance change.

     - Returns: The configured passage chooser and its pane-scoped progress providers.
     - Side effects: Selecting a passage dismisses the destination and navigates the captured pane;
       cancelling only dismisses the destination.
     - Failure modes: Missing pane state falls back to default books and native verse counts.
     - Note: The chooser's visual scheme is intentionally isolated from reader night-mode policy.
     */
    private var bookChooserDestinationContent: some View {
        let progressContext = passageChooserProgressContext

        return BookChooserView(
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
        .background(PassageChooserSurfacePalette.background.swiftUIColor.ignoresSafeArea())
    }

    /// Search destination seeded from toolbar, keyboard, or Android-compatible link routing.
    private var searchSheetContent: some View {
        let controller = panePresentationController
        return SearchView(
            swordModule: controller?.activeModule,
            swordManager: controller?.swordManager,
            searchIndexService: searchIndexService,
            searchIndexSourceRegistry: controller?.makeSearchIndexSourceRegistry(),
            installedBibleModules: controller?.readableBibleModules ?? [],
            currentBook: controller?.currentBook ?? "Genesis",
            currentOsisBookId: searchSheetCurrentOsisBookId,
            selectionPreferences: SearchSelectionPreferences(
                settingsStore: SettingsStore(modelContext: modelContext)
            ),
            isStrongsFindAll: searchIsStrongsFindAll,
            surfacePalette: readerThemeSurfacePalette,
            initialQuery: searchInitialQuery,
            onOpenReference: openReferenceFromSearch,
            onNavigate: navigateFromSearch,
            onOpenResultsInWindow: { results in
                controller?.openSearchResultsInLinksWindow(results) ?? false
            },
            onDismiss: {
                activeReaderDestination = nil
                searchInitialQuery = ""
            }
        )
        .overlay(alignment: .topLeading) {
            readerRenderedContentStateExport
        }
    }

    /// OSIS book id shown as the Search destination's current context.
    private var searchSheetCurrentOsisBookId: String {
        let currentBook = panePresentationController?.currentBook ?? "Genesis"
        return panePresentationController?.osisBookId(for: currentBook)
            ?? BibleReaderController.osisBookId(for: currentBook)
    }

    /// Builds the reader-owned Manage Labels activity for WebView bookmark action events.
    private func readerLabelAssignmentContent(_ route: ReaderLabelAssignmentRoute) -> some View {
        LabelAssignmentView(
            bookmarkId: route.bookmarkId,
            workspace: panePresentationTargetWindow?.workspace ?? windowManager.activeWorkspace,
            surfacePalette: readerThemeSurfacePalette,
            onDismiss: { activeReaderLabelAssignmentRoute = nil }
        )
        .onDisappear {
            refreshReaderLabelAssignment(route)
        }
    }

    /**
     Presents app-owned label assignment for the pane that requested it through the WebView bridge.

     - Parameters:
       - bookmarkId: Bookmark whose labels should be edited.
       - windowId: Originating pane identifier, used to refresh the correct Vue document afterward.
     - Side effects: Captures pane presentation target state and pushes an app-owned reader destination.
     - Failure modes: Missing window identifiers fall back to the currently active pane.
     */
    private func presentReaderLabelAssignment(bookmarkId: UUID, from windowId: UUID?) {
        setPanePresentationTarget(windowId)
        activeReaderLabelAssignmentRoute = ReaderLabelAssignmentRoute(
            bookmarkId: bookmarkId,
            windowId: panePresentationTargetWindowId
        )
    }

    /**
     Refreshes the WebView bookmark row that launched label assignment.

     - Parameter route: Completed label-assignment route.
     - Side effects: Emits the updated bookmark payload into the originating pane's Vue bridge.
     - Failure modes: Returns without action when the originating pane has been closed.
     */
    private func refreshReaderLabelAssignment(_ route: ReaderLabelAssignmentRoute) {
        if let windowId = route.windowId {
            controller(for: windowId)?.refreshBookmarkInVueJS(bookmarkId: route.bookmarkId)
        } else {
            focusedController?.refreshBookmarkInVueJS(bookmarkId: route.bookmarkId)
        }
    }

    /**
     Rebuilds each pane's My Documents store after an isolated library transaction commits.

     SwiftData contexts do not merge an isolated save into models already registered by another
     context. Replacing the reader stores makes a page opened immediately after Save resolve from
     persisted state without forcing the shared scene context to commit unrelated pending edits.

     - Side effects: Replaces the My Documents persistence adapter on every open reader controller.
     - Failure modes: None; controllers that are not Bible readers are ignored.
     */
    private func refreshMyDocumentStores() {
        let container = modelContext.container
        for registeredController in windowManager.controllers.values {
            guard let controller = registeredController as? BibleReaderController else { continue }
            controller.myDocumentStore = MyDocumentStore(modelContext: ModelContext(container))
        }
    }

    /**
     Reconciles a committed EPUB deletion across every reader pane that still holds its generation.

     - Parameter identifier: Stable EPUB library identifier removed from local storage.
     - Side effects: Releases matching reader leases and returns affected panes to their selected
       Bible document. Unrelated panes remain unchanged.
     - Failure modes: Closed panes and non-reader controllers are ignored.
     */
    @MainActor
    private func reconcileDeletedEpubAcrossReaderPanes(_ identifier: String) {
        for registeredController in windowManager.controllers.values {
            guard let controller = registeredController as? BibleReaderController else { continue }
            controller.reconcileDeletedEpub(identifier: identifier)
        }
    }

    /// Builds the prompt editor destination separately to keep the reader's modifier chain type-checkable.
    @ViewBuilder
    private func aiPromptEditorDestinationContent(_ destination: AIPromptEditorDestination) -> some View {
        AIPromptEditorView(
            promptID: destination.promptID,
            swordManager: panePresentationController?.swordManager,
            surfacePalette: readerThemeSurfacePalette,
            onBack: { activeAIPromptEditorDestination = nil },
            onChanged: {}
        )
        .androidAccessibilityIdentityMarker(
            label: String(localized: "edit_prompt", defaultValue: "Edit prompt"),
            accessibilityIdentifier: "aiPromptEditorScreen",
            surfaceColor: readerThemeSurfacePalette.backgroundColor
        )
    }

    /// Applies the configured night-mode policy after a system color-scheme change.
    private func updateNightModeForCurrentColorScheme() {
        let store = SettingsStore(modelContext: modelContext)
        let manualNightMode = store.getBool("night_mode")
        nightMode = NightModeSettingsResolver.isNightMode(
            rawValue: nightModeMode,
            manualNightMode: manualNightMode,
            systemIsDark: colorScheme == .dark
        )
    }

    /// Defers a queued overflow route until the menu's dismissal transaction completes.
    private func presentPendingReaderOverflowPresentationAfterDismissal() {
        DispatchQueue.main.async {
            presentPendingReaderOverflowPresentation()
        }
    }

    /// Presents a queued overflow route only after the menu changes from visible to dismissed.
    private func handleReaderOverflowMenuChange(_ isPresented: Bool) {
        guard !isPresented else {
            return
        }
        presentPendingReaderOverflowPresentationAfterDismissal()
    }

    /// Clears the double-tap fullscreen marker after the reader exits fullscreen mode.
    private func handleFullScreenChange(_ fullScreen: Bool) {
        if !fullScreen {
            lastFullScreenByDoubleTap = false
        } else {
            // Android's MainBibleActivity.toggleFullScreen posts the exit_fullscreen toast on
            // every entry into fullscreen so hidden chrome never becomes a trap. All iOS entry
            // paths (double-tap, overflow menu, auto fullscreen) funnel through this change
            // handler, matching Android's single toggle path.
            showReaderToast(
                String(
                    localized: "exit_fullscreen",
                    defaultValue: "Double-tap screen to exit fullscreen"
                )
            )
        }
    }

    /**
     Shows the transient reader toast and schedules its dismissal.

     - Parameter text: Localized message to display above the reader's bottom edge.
     - Side effects: Cancels any pending toast dismissal, animates the overlay in, and schedules
       one dismissal after 2.5 seconds.
     - Failure modes: None.
     */
    private func showReaderToast(_ text: String) {
        toastWorkItem?.cancel()
        withAnimation { toastMessage = text }
        let work = DispatchWorkItem {
            withAnimation { toastMessage = nil }
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Builds reader-stack destinations opened from the drawer, overflow, or keyboard shortcuts.
    @ViewBuilder
    private func readerDestinationContent(_ destination: ReaderDestination) -> some View {
        switch destination {
        case .search:
            searchSheetContent
        case .bookmarks:
            BookmarkListView(
                surfacePalette: readerThemeSurfacePalette,
                onDismiss: { activeReaderDestination = nil },
                bibleTextResolver: { bookmark in
                    panePresentationController?.bookmarkListTextProjection(for: bookmark) ?? .empty
                },
                genericTextResolver: { bookmark in
                    panePresentationController?.bookmarkListTextProjection(for: bookmark) ?? .empty
                },
                onNavigateTarget: { target in
                    guard let controller = panePresentationController else {
                        throw BibleReaderBookmarkNavigationCommitFailure.readerUnavailable
                    }
                    try controller.navigate(toBookmarkTarget: target)
                },
                workspace: panePresentationTargetWindow?.workspace ?? windowManager.activeWorkspace,
                bibleOrdinalResolver: { book, ordinal in
                    panePresentationController?.bookmarkListVerseReference(book: book, ordinal: ordinal)
                },
                activeReferenceResolver: panePresentationController?.bookmarkListActiveReferenceResolver() ?? nil
            )
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .studyPads:
            StudyPadSelectorView(
                surfacePalette: readerThemeSurfacePalette,
                workspace: panePresentationTargetWindow?.workspace ?? windowManager.activeWorkspace,
                activeLabelID: panePresentationController?.activeStudyPadLabelId,
                onDismiss: {
                    activeReaderDestination = nil
                },
                onOpenStudyPad: { labelId, entryId in
                    panePresentationController?.loadStudyPadDocument(labelId: labelId, bookmarkId: entryId)
                    activeReaderDestination = nil
                }
            )
            #if os(iOS)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .labelManager:
            LabelManagerView(
                workspace: panePresentationTargetWindow?.workspace ?? windowManager.activeWorkspace,
                surfacePalette: readerThemeSurfacePalette,
                onDismiss: { activeReaderDestination = nil }
            )
            #if os(iOS)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .myDocuments:
            MyDocumentsListView(
                reservedInitials: [],
                isInitialsUnavailable: { initials in
                    guard let swordManager = panePresentationController?.swordManager else {
                        throw BibleReaderInstalledDocumentRegistrySnapshotError(
                            detail: "the native module registry is unavailable"
                        )
                    }
                    return try BibleReaderInstalledDocumentRegistrySnapshot.capture(
                        modelContainer: modelContext.container,
                        modulePath: swordManager.modulePath
                    ).ownsDocument(named: initials)
                },
                moduleStoreRootURL: URL(
                    fileURLWithPath: panePresentationController?.swordManager?.modulePath
                        ?? SwordManager.defaultModulePath(),
                    isDirectory: true
                ),
                surfacePalette: readerThemeSurfacePalette,
                onDismiss: { activeReaderDestination = nil },
                onLibrarySaved: refreshMyDocumentStores
            ) { bookInitials, pageKey in
                if panePresentationController?.loadMyDocumentPage(
                    bookInitials: bookInitials,
                    pageKey: pageKey
                ) == true {
                    activeReaderDestination = nil
                }
            }
            #if os(iOS)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .workspaces:
            WorkspaceSelectorView(
                speakService: speakService,
                moduleStoreRootURL: paneModuleStoreRootURL,
                surfacePalette: readerThemeSurfacePalette,
                onDismiss: { activeReaderDestination = nil }
            )
                .overlay(alignment: .topLeading) {
                    readerRenderedContentStateExport
                }
        case .readingPlans:
            ReadingPlanListView(
                surfacePalette: readerThemeSurfacePalette,
                onDismiss: { activeReaderDestination = nil },
                dailyReadingToolbarState: AndroidDailyReadingToolbarState(
                    bibleTitle: panePresentationController?.activeModuleName,
                    commentaryTitle: panePresentationController?.activeCommentaryModuleName,
                    dictionaryTitle: panePresentationController?.activeDictionaryModuleName,
                    isSpeaking: speakService.isSpeaking,
                    isPaused: speakService.isPaused
                ),
                onOpenDailyReadingBible: openDailyReadingBible,
                onOpenDailyReadingCommentary: openDailyReadingCommentary,
                onOpenDailyReadingDictionary: openDailyReadingDictionary,
                onToggleDailyReadingSpeechPause: toggleDailyReadingSpeechPause,
                onStopDailyReadingSpeech: speakService.stop,
                planVersificationResolver: { planCode in
                    guard let controller = panePresentationController else {
                        throw ReadingPlanDefinitionError.unavailable(planCode: planCode)
                    }
                    return try controller.readingPlanVersificationProperty(forPlanCode: planCode)
                },
                onPerformDailyReadingAction: { request in
                    guard let controller = panePresentationController else {
                        throw BibleReaderDailyReadingActionFailure.activeBibleUnavailable
                    }
                    try await controller.performDailyReadingAction(request)
                },
                onReadCompleted: {
                    activeReaderDestination = nil
                }
            )
            #if os(iOS)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .readingProgress:
            ReadingProgressView(
                readingStore: panePresentationController?.readingProgressStore,
                memorizationStore: panePresentationController?.memorizationProgressStore,
                surfacePalette: readerThemeSurfacePalette,
                initialTab: readingProgressInitialTab,
                onBack: { activeReaderDestination = nil },
                onOpenSettings: {
                    presentChildReaderDestination(.readingProgressSettings)
                },
                onOpenMemorizeRange: { range in
                    activeReaderDestination = nil
                    _ = panePresentationController?.openMemorizeKJVARange(
                        startOrdinal: range.startOrdinal,
                        endOrdinal: range.endOrdinal
                    )
                },
                onOpenChapter: { osisId, chapter in
                    activeReaderDestination = nil
                    _ = panePresentationController?.navigateToRef("\(osisId).\(chapter)")
                }
            )
            #if os(iOS)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                AndroidActivityAccessibilityMarker(
                    label: String(localized: "reading_progress_title", defaultValue: "Read/Memory Progress"),
                    accessibilityIdentifier: "readingProgressScreen",
                    surfaceColor: readerThemeSurfacePalette.backgroundColor
                )
            }
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .readingProgressSettings:
            ReadingProgressSettingsView(
                controller: panePresentationController,
                surfacePalette: readerThemeSurfacePalette,
                onBack: dismissReaderDestination
            )
            #if os(iOS)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .passageChooser:
            bookChooserDestinationContent
                .overlay(alignment: .topLeading) {
                    AndroidActivityAccessibilityMarker(
                        label: String(localized: "choose_book", defaultValue: "Choose Book"),
                        accessibilityIdentifier: "passageChooserScreen",
                        surfaceColor: readerThemeSurfacePalette.backgroundColor
                    )
                }
                .overlay(alignment: .topLeading) {
                    readerRenderedContentStateExport
                }
        case .modulePicker:
            documentChooserDestinationContent(
                category: pickerCategory,
                startsWithAllTypes: false
            )
        case .chooseDocument:
            documentChooserDestinationContent(
                category: panePresentationController?.currentCategory ?? pickerCategory,
                startsWithAllTypes: true
            )
        case .speakControls:
            SpeakControlView(
                speakService: speakService,
                surfacePalette: readerThemeSurfacePalette,
                passageBooks: panePresentationController?.bookList ?? BibleReaderController.defaultBooks,
                verseCountProvider: { book, chapter in
                    panePresentationController?.verseCountForActiveModule(
                        book: book.name,
                        chapter: chapter
                    ) ?? BibleReaderController.verseCount(for: book.name, chapter: chapter)
                },
                onBack: { activeReaderDestination = nil }
            )
            #if os(iOS)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                AndroidActivityAccessibilityMarker(
                    label: String(localized: "speak", defaultValue: "Speak"),
                    accessibilityIdentifier: "speakControlsScreen",
                    surfaceColor: readerThemeSurfacePalette.backgroundColor
                )
            }
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .syncSettings:
            SyncSettingsView(
                surfacePalette: readerThemeSurfacePalette,
                onBack: dismissReaderDestination
            )
            #if os(iOS)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .dictionaryBrowser:
            if let controller = panePresentationController,
               let source = controller.activeDictionaryBrowserSource() {
                DictionaryBrowserView(
                    source: source,
                    surfacePalette: readerThemeSurfacePalette,
                    onBack: { activeReaderDestination = nil }
                ) { key in
                    activeReaderDestination = nil
                    controller.loadDictionaryEntry(key: key)
                }
                .overlay(alignment: .topLeading) {
                    AndroidActivityAccessibilityMarker(
                        label: String(localized: "dictionary", defaultValue: "Dictionary"),
                        accessibilityIdentifier: "dictionaryBrowserScreen",
                        surfaceColor: readerThemeSurfacePalette.backgroundColor
                    )
                }
            } else {
                readerPanePreparationContent
            }
        case .generalBookBrowser:
            if let controller = panePresentationController {
                if let reader = controller.activeEpubReader {
                    EpubBrowserView(
                        reader: reader,
                        surfacePalette: readerThemeSurfacePalette,
                        onBack: { activeReaderDestination = nil }
                    ) { key in
                        activeReaderDestination = nil
                        controller.loadEpubEntry(key: key)
                    }
                    .overlay(alignment: .topLeading) {
                        AndroidActivityAccessibilityMarker(
                            label: String(localized: "general_book", defaultValue: "Book"),
                            accessibilityIdentifier: "generalBookBrowserScreen",
                            surfaceColor: readerThemeSurfacePalette.backgroundColor
                        )
                    }
                } else if let module = controller.activeGeneralBookModule {
                    GeneralBookBrowserView(
                        module: module,
                        title: String(localized: "general_book", defaultValue: "Book"),
                        surfacePalette: readerThemeSurfacePalette,
                        onBack: { activeReaderDestination = nil },
                        onEmptyKeys: { firstGlobalKey in
                            controller.handleEmptyGenericKeyChooser(
                                module: module,
                                category: .generalBook,
                                firstGlobalKey: firstGlobalKey
                            )
                        }
                    ) { key in
                        activeReaderDestination = nil
                        controller.loadGeneralBookEntry(key: key)
                    }
                    .overlay(alignment: .topLeading) {
                        AndroidActivityAccessibilityMarker(
                            label: String(localized: "general_book", defaultValue: "Book"),
                            accessibilityIdentifier: "generalBookBrowserScreen",
                            surfaceColor: readerThemeSurfacePalette.backgroundColor
                        )
                    }
                } else {
                    readerPanePreparationContent
                }
            } else {
                readerPanePreparationContent
            }
        case .mapBrowser:
            if let controller = panePresentationController,
               let module = controller.activeMapModule {
                GeneralBookBrowserView(
                    module: module,
                    title: String(localized: "doc_type_map", defaultValue: "Map"),
                    surfacePalette: readerThemeSurfacePalette,
                    onBack: { activeReaderDestination = nil },
                    onEmptyKeys: { firstGlobalKey in
                        controller.handleEmptyGenericKeyChooser(
                            module: module,
                            category: .map,
                            firstGlobalKey: firstGlobalKey
                        )
                    }
                ) { key in
                    activeReaderDestination = nil
                    controller.loadMapEntry(key: key)
                }
                .overlay(alignment: .topLeading) {
                    AndroidActivityAccessibilityMarker(
                        label: String(localized: "doc_type_map", defaultValue: "Map"),
                        accessibilityIdentifier: "mapBrowserScreen",
                        surfaceColor: readerThemeSurfacePalette.backgroundColor
                    )
                }
            } else {
                readerPanePreparationContent
            }
        case .epubSearch:
            if let reader = panePresentationController?.activeEpubReader {
                EpubSearchView(
                    reader: reader,
                    modePreferences: SearchModePreferences(
                        settingsStore: SettingsStore(modelContext: modelContext)
                    ),
                    surfacePalette: readerThemeSurfacePalette,
                    onBack: { activeReaderDestination = nil },
                    onAdoptRebuiltReader: { rebuiltReader in
                        panePresentationController?.adoptRebuiltEpubReader(rebuiltReader) ?? false
                    }
                ) { result in
                    activeReaderDestination = nil
                    panePresentationController?.loadEpubEntry(
                        key: result.key,
                        jumpToOrdinal: result.ordinal
                    )
                }
                .overlay(alignment: .topLeading) {
                    AndroidActivityAccessibilityMarker(
                        label: String(localized: "search", defaultValue: "Find"),
                        accessibilityIdentifier: "epubSearchScreen",
                        surfaceColor: readerThemeSurfacePalette.backgroundColor
                    )
                }
            } else {
                Text(String(localized: "reader_no_epub_loaded"))
                    .padding()
            }
        case .settings:
            SettingsView(
                nightMode: $nightMode,
                nightModeMode: $nightModeMode,
                readingProgressController: panePresentationController,
                surfacePalette: readerThemeSurfacePalette,
                onBack: { activeReaderDestination = nil },
                onOpenActivity: { destination in
                    switch destination {
                    case .globalTextOptions:
                        presentGlobalTextOptions(
                            from: panePresentationTargetWindowId,
                            asChild: true
                        )
                    case .syncSettings:
                        presentChildReaderDestination(.syncSettings)
                    case .aiSettings:
                        presentChildReaderDestination(.aiSettings)
                    case .readingProgressSettings:
                        presentChildReaderDestination(.readingProgressSettings)
                    }
                },
                onSettingsChanged: applyApplicationPreferenceChange
            )
            // The reader shell is removed from the accessibility tree while a destination is
            // pushed, so re-emit the compact reader-state export here. This keeps reader routing
            // tokens (for example `readerSheet=none;readerDestination=settings`) observable by UI
            // tests on the pushed destination without exposing reader internals to SettingsView.
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .aiSettings:
            AISettingsView(
                swordManager: panePresentationController?.swordManager,
                surfacePalette: readerThemeSurfacePalette,
                onBack: dismissReaderDestination
            )
                .overlay(alignment: .topLeading) {
                    AndroidActivityAccessibilityMarker(
                        label: String(localized: "ai_settings", defaultValue: "AI Settings"),
                        accessibilityIdentifier: "aiSettingsScreen",
                        surfaceColor: readerThemeSurfacePalette.backgroundColor
                    )
                }
                .overlay(alignment: .topLeading) {
                    readerRenderedContentStateExport
                }
        case .startupDocumentSetup:
            if let startupDownloadPromptReason {
                StartupDocumentSetupView(
                    presentation: StartupDocumentSetupPresentation(
                        reason: startupDownloadPromptReason,
                        isEasyStartAvailable: isStartupEasyStartAvailable
                    ),
                    versionText: AndBibleAppVersionMetadata.current().drawerFooterText,
                    surfacePalette: readerThemeSurfacePalette,
                    onEasyStart: presentStartupDefaultDownloads,
                    onDownloadDocuments: presentStartupDownloadDocuments,
                    onLoadDocumentsFromFiles: presentStartupLoadDocumentsFromFiles,
                    onRestoreDatabase: presentStartupRestoreDatabase
                )
                .overlay(alignment: .topLeading) {
                    readerRenderedContentStateExport
                }
            } else {
                EmptyView()
            }
        case .downloads:
            ModuleBrowserView(
                initialSearchText: downloadsInitialSearchText,
                defaultDownloadMode: downloadsDefaultDownloadMode,
                surfacePalette: readerThemeSurfacePalette,
                onDefaultDownloadActivityChanged: { isInFlight in
                    handleStartupDefaultDownloadActivityChanged(isInFlight: isInFlight)
                }
            )
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .importExport:
            ImportExportView(
                startupRestoreImportTarget: startupRestoreImportTarget,
                speakService: speakService,
                surfacePalette: readerThemeSurfacePalette,
                onDismiss: { activeReaderDestination = nil }
            )
                #if os(iOS)
                .navigationBarBackButtonHidden(true)
                .toolbar(.hidden, for: .navigationBar)
                #endif
                .overlay(alignment: .topLeading) {
                    readerRenderedContentStateExport
                }
        case .globalTextOptions:
            TextDisplaySettingsView(
                settings: $globalDisplaySettings,
                moduleStoreRootURL: paneModuleStoreRootURL,
                workspaceColor: workspaceColorBinding,
                navigationTitle: String(
                    localized: "global_text_display_settings_title",
                    defaultValue: "Global text options"
                ),
                scope: .global,
                workspaceName: windowManager.activeWorkspace?.name,
                surfacePalette: readerThemeSurfacePalette,
                onBack: dismissReaderDestination,
                onChange: applyGlobalDisplaySettingsChange
            )
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .workspaceTextOptions:
            TextDisplaySettingsView(
                settings: $workspaceDisplaySettings,
                moduleStoreRootURL: paneModuleStoreRootURL,
                workspaceColor: workspaceColorBinding,
                navigationTitle: textOptionsWorkspaceTitle,
                scope: .workspace,
                workspaceName: panePresentationTargetWindow?.workspace?.name ?? windowManager.activeWorkspace?.name,
                surfacePalette: readerThemeSurfacePalette,
                onBack: dismissReaderDestination,
                onOpenGlobalSettings: {
                    presentGlobalTextOptions(
                        from: panePresentationTargetWindowId,
                        asChild: true
                    )
                },
                onChange: applyWorkspaceDisplaySettingsChange
            )
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .windowTextOptions:
            TextDisplaySettingsView(
                settings: $windowDisplaySettings,
                moduleStoreRootURL: paneModuleStoreRootURL,
                navigationTitle: textOptionsWindowTitle,
                scope: .window,
                workspaceName: panePresentationTargetWindow?.workspace?.name ?? windowManager.activeWorkspace?.name,
                surfacePalette: readerThemeSurfacePalette,
                onBack: dismissReaderDestination,
                onOpenWorkspaceSettings: {
                    presentWorkspaceTextOptions(
                        from: panePresentationTargetWindowId,
                        asChild: true
                    )
                },
                onOpenGlobalSettings: {
                    presentGlobalTextOptions(
                        from: panePresentationTargetWindowId,
                        asChild: true
                    )
                },
                onChange: applyWindowDisplaySettingsChange
            )
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            // Mirror the Settings destination's state export so UI tests can distinguish the
            // window-level All Text Options route from global Application Preferences.
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .windowColorSettings:
            ColorSettingsView(
                settings: $windowDisplaySettings,
                surfacePalette: readerThemeSurfacePalette,
                activityTitle: String(localized: "colors", defaultValue: "Colors"),
                onBack: { activeReaderDestination = nil },
                onChange: {
                    recordRecentTextSetting(.colors)
                    applyWindowDisplaySettingsChange()
                }
            )
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        case .windowHiddenLabels:
            AndroidHiddenLabelsActivityView(
                labels: BookmarkStore(modelContext: modelContext).labels(includeSystem: true),
                hiddenLabelIDs: Binding(
                    get: { windowDisplaySettings.bookmarksHideLabels },
                    set: { windowDisplaySettings.bookmarksHideLabels = $0 }
                ),
                isWindow: true,
                surfacePalette: readerThemeSurfacePalette,
                onDismiss: { activeReaderDestination = nil },
                onChange: {
                    recordRecentTextSetting(.bookmarksHideLabels)
                    applyWindowDisplaySettingsChange()
                }
            )
            #if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        }
    }

    /**
     Builds Android's full-screen ChooseDocument activity on the same reader destination host as
     Downloads.

     - Parameters:
       - category: Category-scoped filter requested by the launching toolbar, or the current pane
         category for the drawer's all-types chooser.
       - startsWithAllTypes: Whether Android launched without a type intent extra.
     - Returns: The shared app-owned document-selection screen or pane-readiness fallback.
     - Side effects: Back closes the destination; document-management and key-browser callbacks
       replace it on the existing reader stack while preserving the captured pane.
     - Failure modes: A pane still registering its controller shows the shared preparation state;
       an unavailable pane can be dismissed without changing the reader's active document.
     */
    @ViewBuilder
    private func documentChooserDestinationContent(
        category: DocumentCategory,
        startsWithAllTypes: Bool
    ) -> some View {
        if let controller = panePresentationController {
            BibleReaderModulePicker(
                controller: controller,
                category: category,
                startsWithAllTypes: startsWithAllTypes,
                surfacePalette: readerThemeSurfacePalette,
                onDismiss: { activeReaderDestination = nil },
                onOpenDownloads: { presentDownloadsPreservingPane() },
                onOpenDictionaryBrowser: {
                    presentReaderDestinationPreservingPane(.dictionaryBrowser)
                },
                onOpenGeneralBookBrowser: {
                    presentReaderDestinationPreservingPane(.generalBookBrowser)
                },
                onOpenMapBrowser: {
                    presentReaderDestinationPreservingPane(.mapBrowser)
                },
                onOpenStudyPadSelector: presentStudyPadsDestinationPreservingPane,
                onDeleteEpub: reconcileDeletedEpubAcrossReaderPanes
            )
            #if os(iOS)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .overlay(alignment: .topLeading) {
                readerRenderedContentStateExport
            }
        } else {
            readerPanePreparationContent
        }
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
        if let payload = myDocumentSharePayload {
            #if os(iOS)
            ShareSheet(items: [MyDocumentActivityItemSource(payload: payload)])
            #else
            ShareSheet(items: [payload.body])
            #endif
        } else if let text = shareText {
            ShareSheet(items: [text])
        }
    }

    /**
     Builds the reference chooser sheet for one bridge request generation.

     - Parameter generation: Request identity captured by every selection and dismissal callback.
     - Returns: Verse-level passage chooser seeded from the requesting pane.
     - Side effects: User actions resolve only the matching bridge request generation.
     - Failure modes: Missing/invalid KJVA selections complete the matching request as cancelled;
       stale full-screen callbacks are ignored by `BibleReaderReferenceChooserRequest`.
     */
    private func refChooserSheetContent(
        for generation: BibleReaderReferenceChooserRequest.Generation
    ) -> some View {
        let progressContext = passageChooserProgressContext

        return BookChooserView(
                books: panePresentationController?.bookList ?? BibleReaderController.defaultBooks,
                navigateToVerse: true,
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
                onCancel: {
                    completeReferenceChooser(with: nil, for: generation)
                }
            ) { book, chapter, verse in
                guard let verse else {
                    completeReferenceChooser(with: nil, for: generation)
                    return
                }
                let osisId = panePresentationController?.osisBookId(for: book) ?? BibleReaderController.osisBookId(for: book)
                guard !osisId.isEmpty,
                      let verseName = BibleReaderReferenceChooserResultFormatter.verseName(
                          osisBookId: osisId,
                          chapter: chapter,
                          verse: verse
                      ) else {
                    completeReferenceChooser(with: nil, for: generation)
                    return
                }
                completeReferenceChooser(with: verseName, for: generation)
            }
    }

    /**
     Presents Android's verse-level bridge reference chooser for one reader pane.

     - Parameters:
       - windowId: Pane whose module canon and current passage seed the chooser.
       - completion: Bridge callback receiving Android's JSword short `Verse.name` or cancellation.

     Side effects:
     - targets the requesting pane, captures progress, cancels any superseded bridge request, and
       presents the chooser overlay

     Failure modes:
     - none; a superseded request is completed as cancelled instead of being orphaned
     */
    private func presentReferenceChooser(
        from windowId: UUID,
        completion: @escaping (String?) -> Void
    ) {
        setPanePresentationTarget(windowId)
        passageChooserProgressContext = makePassageChooserProgressContext()
        refChooserPresentation = refChooserRequest.replace(with: completion)
    }

    /**
     Resolves the pending chooser and closes its app-owned overlay.

     - Parameters:
       - verseName: JSword short `Verse.name`, or `nil` for cancellation or invalid selection.
     - generation: Overlay identity that owns the completion attempt.

     Side effects:
     - completes the matching bridge request at most once, dismisses only its overlay, and clears its
       progress snapshot

     Failure modes:
     - stale generations and callbacks after interactive dismissal are no-ops
     */
    private func completeReferenceChooser(
        with verseName: String?,
        for generation: BibleReaderReferenceChooserRequest.Generation
    ) {
        guard refChooserRequest.resolve(for: generation, with: verseName) else { return }
        if refChooserPresentation == generation {
            refChooserPresentation = nil
        }
        resetPassageChooserProgressContext()
    }

    /**
     Completes one interactively dismissed chooser generation as cancelled.

     - Parameter generation: Identity captured by the disappearing sheet content.

     Side effects:
     - resolves only a matching pending bridge request with cancellation and clears its captured
       progress

     Failure modes:
     - stale dismissal after request replacement is ignored and leaves the replacement presented
     */
    private func handleReferenceChooserDismissal(
        for generation: BibleReaderReferenceChooserRequest.Generation
    ) {
        guard refChooserRequest.resolve(for: generation, with: nil) else { return }
        resetPassageChooserProgressContext()
    }

    /// Invisible keyboard shortcut host for iPad and Mac command routing.
    private var keyboardShortcutSurface: some View {
        BibleReaderKeyboardShortcuts(
            onSearch: { presentSearch(from: windowManager.activeWindow?.id) },
            onShowBookChooser: { presentBookChooser(from: windowManager.activeWindow?.id) },
            onOpenBookmarks: { presentReaderDestination(.bookmarks, from: windowManager.activeWindow?.id) },
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
     Opens Android's shared window popup from one bottom restore-strip button.

     - Parameter window: Exact persisted window represented by the long-pressed button.
     - Side effects: Activates visible targets as Android does, dismisses competing reader popups,
       and presents the reader-wide anchored menu without restoring minimized windows.
     - Failure modes: Windows no longer owned by the active workspace are ignored.
     */
    private func presentWindowTabMenu(for window: BibleCore.Window) {
        guard windowManager.allWindows.contains(where: { $0.id == window.id }) else { return }
        if window.layoutState != "minimized" {
            windowManager.activateWindow(window)
        }
        dismissBibleQuickSelector()
        dismissCommentaryQuickSelector()
        showReaderOverflowMenu = false
        windowTabMenuWindowID = window.id
        withAnimation(.easeOut(duration: 0.12)) {
            showWindowTabMenu = true
        }
    }

    /** Reader-owned shared popup for the currently targeted restore-strip window. */
    @ViewBuilder
    private var windowTabMenuPopup: some View {
        if let windowID = windowTabMenuWindowID,
           let window = windowManager.allWindows.first(where: { $0.id == windowID }) {
            let settings = resolvedDisplaySettings(for: window)
            let palette = ReaderThemeSurfacePalette(
                settings: settings,
                nightMode: nightMode,
                workspaceColor: window.workspace?.workspaceColor,
                monochromeMode: monochromeModePref
            )
            let snapshot = BibleWindowPaneMenuSnapshotFactory.snapshot(
                for: window,
                windowManager: windowManager,
                displaySettings: settings,
                isAIConfigured: isAIConfigured,
                referenceStore: windowMenuReferenceStore,
                recentTextSettings: AndroidTextDisplayRecentSettings.displayedTypes(
                    settingsStore: SettingsStore(modelContext: modelContext)
                )
            )
            BibleWindowPaneMenuPopup(
                items: BibleWindowPaneMenuModel(snapshot: snapshot).items,
                colorScheme: colorScheme,
                surfacePalette: palette,
                maximumHeight: 440
            ) { action in
                withAnimation(.easeOut(duration: 0.12)) {
                    showWindowTabMenu = false
                }
                performWindowTabMenuAction(action, for: window)
                windowTabMenuWindowID = nil
            }
        }
    }

    /**
     Routes a restore-strip popup command through the same shared handler as the pane hamburger.

     - Parameters:
       - action: Terminal Android menu command.
       - window: Immutable target captured when the popup was opened.
     - Side effects: May mutate window layout, present window-owned settings/AI UI, or copy a link.
     - Failure modes: Missing controller-only actions are safe no-ops; manager guards reject stale
       or non-removable windows.
     */
    private func performWindowTabMenuAction(
        _ action: BibleWindowPaneMenuAction,
        for window: BibleCore.Window
    ) {
        let controller = windowManager.controllers[window.id] as? BibleReaderController
        BibleWindowPaneMenuActionHandler(
            windowManager: windowManager,
            window: window,
            onEditTextSetting: { type in
                performWindowTextSetting(type, for: window)
            },
            onShowWindowTextOptions: { presentWindowTextOptions(from: window.id) },
            onCopyWindowSettingsToWindow: { targetWindowID in
                presentTextSettingsCopy(from: window.id, target: .window(targetWindowID))
            },
            onCopyWindowSettingsToWorkspace: {
                presentTextSettingsCopy(from: window.id, target: .workspace)
            },
            onCopyWindowSettingsToGlobal: {
                presentTextSettingsCopy(from: window.id, target: .global)
            },
            onAddWholePageBookmark: {
                _ = controller?.createWindowMenuWholePageBookmark()
            },
            onExportHTML: {
                controller?.requestWindowMenuHTMLExport()
            },
            onExportStudyPad: {
                guard let labelID = controller?.windowMenuStudyPadLabelID else { return }
                exportWindowMenuStudyPadArchive(labelID: labelID)
            },
            onExportStudyPadCSV: {
                guard let labelID = controller?.windowMenuStudyPadLabelID else { return }
                exportWindowMenuStudyPadCSV(labelID: labelID)
            },
            onOpenAIActions: { controller?.onRequestWindowAIAction?() },
            onCopyLink: {
                guard let reference = controller?.windowMenuReference() else { return }
                windowMenuReferenceStore.copy(reference, onShowToast: showWindowTabToast)
            },
            onOpenCopiedReference: {
                guard let reference = windowMenuReferenceStore.reference else { return }
                navigateWindowMenuReference(reference, controller: controller)
            },
            onOpenSpeakReference: {
                guard speakService.isSpeaking,
                      let position = speakService.currentPosition,
                      let reference = BibleWindowMenuReference.speechPosition(position) else {
                    return
                }
                navigateWindowMenuReference(reference, controller: controller)
            }
        ).perform(action)
    }

    /** Starts the canonical specialized archive export for one active Study Pad window. */
    private func exportWindowMenuStudyPadArchive(labelID: UUID) {
        windowMenuStudyPadArchiveWorkflow.exportStudyPad(
            labelID: labelID,
            modelContainer: modelContext.container
        )
    }

    /** Starts Bookmark-list's shared Android CSV sequence for one active Study Pad label. */
    private func exportWindowMenuStudyPadCSV(labelID: UUID) {
        let bookmarks = BookmarkStore(modelContext: modelContext)
            .bibleBookmarks(withLabel: labelID)
        windowMenuCSVExportWorkflow.beginExport(
            bookmarks: bookmarks,
            modelContext: modelContext
        )
    }

    /** Applies one typed copied/speech reference to the immutable popup target controller. */
    private func navigateWindowMenuReference(
        _ reference: BibleWindowMenuReference,
        controller: BibleReaderController?
    ) {
        guard let controller else {
            showWindowTabToast(
                String(localized: "error_occurred", defaultValue: "An error has occurred")
            )
            return
        }
        do {
            try controller.navigateToWindowMenuReference(reference)
        } catch {
            showWindowTabToast(error.localizedDescription)
        }
    }

    /**
     Navigates from Search results into the active reader pane.

     - Parameter target: Exact module and canonical verse selected in grouped Search results.
     - Returns: `true` only after the target module and canonical verse were opened.
     - Side effects: Dismisses Search after success, may switch the pane's Bible module, and updates
       the active reader location.
     - Failure modes: Returns `false` without changing Search state when the controller or target
       module is unavailable.
     */
    private func navigateFromSearch(_ target: SearchNavigationTarget) -> Bool {
        guard let controller = panePresentationController,
              controller.navigateToSearchResult(target) else {
            return false
        }
        activeReaderDestination = nil
        searchInitialQuery = ""
        return true
    }

    /**
     Attempts Android-compatible reference navigation before Search compiles a text query.

     - Parameter query: Raw trimmed Search input such as `John 3:16`, a range, a localized book
       name, or a comma-separated passage list.
     - Returns: `true` only when the active reader's canonical reference parser recognized and
       opened the complete input.
     - Side effects: Successful navigation dismisses Search state and clears its seeded query.
     - Failure modes: Missing reader state or unrecognized text returns `false`, allowing normal
       Lucene-compatible text search to continue.
     */
    private func openReferenceFromSearch(_ query: String) -> Bool {
        guard let controller = panePresentationController,
              controller.navigateToRef(query) else {
            return false
        }
        activeReaderDestination = nil
        searchInitialQuery = ""
        return true
    }

    /**
     Opens Android's suggested Bible document and leaves the Daily Reading activity.

     - Side effects: Switches the captured pane to its active Bible and clears the reader destination.
     - Failure modes: Missing pane ownership leaves the activity unchanged.
     */
    private func openDailyReadingBible() {
        guard let controller = panePresentationController else { return }
        controller.switchBibleDocument(to: controller.activeModuleName)
        activeReaderDestination = nil
    }

    /**
     Opens Android's suggested commentary document and leaves the Daily Reading activity.

     - Side effects: Switches the captured pane to its retained commentary and clears the route.
     - Failure modes: Missing pane ownership or commentary selection leaves the activity unchanged.
     */
    private func openDailyReadingCommentary() {
        guard let controller = panePresentationController,
              let moduleName = controller.activeCommentaryModuleName else { return }
        controller.switchCommentaryDocument(to: moduleName)
        activeReaderDestination = nil
    }

    /**
     Opens Android's suggested dictionary and preserves the reader's exact-key fallback contract.

     - Side effects: Clears Daily Reading, switches the captured pane, and may open the dictionary
       key browser or retain retry feedback when the prior key cannot be reused.
     - Failure modes: Missing pane, module name, or installed metadata leaves the activity unchanged.
     */
    private func openDailyReadingDictionary() {
        guard let controller = panePresentationController,
              let moduleName = controller.activeDictionaryModuleName,
              let module = controller.installedDictionaryModules.first(where: {
                  $0.name == moduleName
              }) else { return }
        let targetWindowId = panePresentationTargetWindowId ?? windowManager.activeWindow?.id
        activeReaderDestination = nil
        handleGenericQuickModuleSwitch(
            controller.switchDictionaryDocument(to: moduleName),
            module: module,
            targetWindowId: targetWindowId,
            browser: .dictionaryBrowser
        )
    }

    /**
     Toggles Android's Daily Reading speech action between Pause and Resume.

     - Side effects: Mutates the shared `SpeakService` playback state.
     - Failure modes: A stale non-speaking state is a no-op through `SpeakService` guards.
     */
    private func toggleDailyReadingSpeechPause() {
        if speakService.isPaused {
            speakService.resume()
        } else {
            speakService.pause()
        }
    }

    // MARK: - Sheet and Destination Routing

    /**
     Presents Android's dialog-themed History activity as a reader-owned dialog window.

     - Parameter windowId: Source pane whose History rows and navigation result must be retained.
     - Side effects: Captures the pane target and installs a value request that renders the overlay.
     - Failure modes: Does nothing when no active/captured reader window exists.
     */
    private func presentHistoryDialog(from windowId: UUID? = nil) {
        setPanePresentationTarget(windowId)
        guard let window = panePresentationTargetWindow else { return }
        let position = windowManager.allWindows.firstIndex { $0.id == window.id }
            .map { $0 + 1 } ?? (window.orderNumber + 1)
        let format = String(
            localized: "history_for",
            defaultValue: "History (%@: Window %d)"
        )
        historyDialogRequest = HistoryDialogRequest(
            windowID: window.id,
            title: String.localizedStringWithFormat(format, window.workspace?.name ?? "", position)
        )
    }

    /** Presents Android's Read History dialog with an immutable originating pane and chapter. */
    private func presentChapterReadHistoryDialog(
        target: ChapterReadHistoryTarget,
        from windowId: UUID? = nil
    ) {
        setPanePresentationTarget(windowId)
        guard let window = panePresentationTargetWindow else { return }
        chapterReadHistoryDialogRequest = ChapterReadHistoryDialogRequest(
            windowID: window.id,
            target: target
        )
    }

    /// Closes the reader-owned History dialog without mutating navigation or stored history.
    private func dismissHistoryDialog() {
        historyDialogRequest = nil
    }

    /// Closes Read History, causing its staged deletions to commit from the dialog content's exit.
    private func dismissChapterReadHistoryDialog() {
        chapterReadHistoryDialogRequest = nil
    }

    /// Closes the app-owned Help & Tips dialog without changing reader navigation state.
    private func dismissHelpDialog() {
        isHelpDialogPresented = false
    }

    /// Presents Android's Help & Tips dialog over the reader without generic sheet ownership.
    private func presentHelpDialog() {
        isHelpDialogPresented = true
    }

    /// Closes Android's app-owned Open Source License dialog without navigating the reader.
    private func dismissLicenseDialog() {
        isLicenseDialogPresented = false
    }

    /// Presents Android's bundled Open Source License dialog over the reader.
    private func presentLicenseDialog() {
        isLicenseDialogPresented = true
    }

    /// Closes Android's explanatory Rate & Review dialog without starting a system handoff.
    private func dismissRateReviewDialog() {
        isRateReviewDialogPresented = false
    }

    /// Shows Android's explanatory Rate & Review dialog before requesting an App Store review.
    private func presentRateReviewDialog() {
        isRateReviewDialogPresented = true
    }

    /** Dismisses the app dialog and then invokes the legitimate platform-owned review controller. */
    private func proceedToSystemReview() {
        dismissRateReviewDialog()
        #if os(iOS)
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first {
            SKStoreReviewController.requestReview(in: scene)
        }
        #endif
    }

    /// Cancels collection or consent without opening a system handoff.
    private func dismissBugReportDialog() {
        manualBugReportCoordinator.cancel()
        manualBugReportPreparedPayload = nil
        manualBugReportMailPayload = nil
        if let export = manualBugReportExportPendingCleanup ?? manualBugReportExport {
            ProductFeedbackReportExportBuilder.remove(export)
        }
        manualBugReportExportPendingCleanup = nil
        manualBugReportExport = nil
    }

    /**
     Collects available evidence before showing Android's manual-report consent question.

     Screenshot and device identity are captured on the main actor first; log and crash-diagnostic
     collection then runs off the main actor so large evidence cannot freeze the reader behind the
     blocking collection dialog. A cancellation during collection drops the finished payload.
     */
    private func presentBugReportDialog() {
        guard manualBugReportCoordinator.beginCollection() else { return }
        let uiEvidence = ProductFeedbackReportPreparation.captureUIEvidence()
        Task.detached(priority: .userInitiated) {
            let payload = ProductFeedbackReportPreparation.prepare(uiEvidence: uiEvidence)
            await MainActor.run {
                guard manualBugReportCoordinator.completeCollection() else { return }
                manualBugReportPreparedPayload = payload
            }
        }
    }

    /// Presents addressed mail only after the user has consented to the prepared report.
    private func presentPreparedBugReport(_ payload: AddressedMailPayload) {
        let capability = AddressedMailComposer.capability
        guard manualBugReportCoordinator.requestMail(capability: capability) else { return }
        guard capability == .available else { return }
        manualBugReportMailPayload = payload
    }

    /**
     Builds one complete ZIP only after Mail availability has been made explicit, then shares it.

     The preparation phase ends as soon as the ZIP is written, before the share sheet presents.
     The system share surface cannot guarantee a completion callback on every dismissal path, so no
     coordinator phase may depend on one; `finishBugReportExportShare` owns file cleanup instead.
     */
    private func exportPreparedBugReport(_ payload: AddressedMailPayload) {
        guard manualBugReportCoordinator.beginExport() else { return }
        do {
            let export = try ProductFeedbackReportExportBuilder.write(payload: payload)
            manualBugReportCoordinator.completeExport(success: true)
            manualBugReportPreparedPayload = nil
            manualBugReportExportPendingCleanup = export
            manualBugReportExport = export
        } catch {
            manualBugReportCoordinator.completeExport(success: false)
        }
    }

    /**
     Ends a Mail handoff whose sheet closed without delivering a composer delegate result.

     Mail sheet dismissal is not guaranteed to route through `MFMailComposeViewController`'s
     delegate on every platform path, so the coordinator phase may not depend on one. A normal
     delegate result has already returned the phase to idle, making this cleanup a no-op.
     */
    private func finishBugReportMailPresentation() {
        manualBugReportCoordinator.finishMail(.cancelled)
        manualBugReportMailPayload = nil
        manualBugReportPreparedPayload = nil
    }

    /** Deletes the temporary report ZIP after the share surface closes on any dismissal path. */
    private func finishBugReportExportShare() {
        if let export = manualBugReportExportPendingCleanup {
            ProductFeedbackReportExportBuilder.remove(export)
        }
        manualBugReportExportPendingCleanup = nil
        manualBugReportExport = nil
    }

    /**
     Presents a root app-owned reader destination and captures its pane owner.

     - Parameters:
       - destination: Activity-equivalent destination to show above the reader.
       - windowId: Optional pane whose controller and workspace should back the destination.
     - Side effects: Clears any prior child-activity history, captures the pane target, and updates
       the active destination consumed by SwiftUI navigation.
     - Failure modes: A missing pane identifier falls back through `setPanePresentationTarget`;
       destinations that require a controller render their existing preparation state.
     */
    private func presentReaderDestination(_ destination: ReaderDestination, from windowId: UUID? = nil) {
        readerDestinationBackStack.removeAll()
        setPanePresentationTarget(windowId)
        activeReaderDestination = destination
    }

    /**
     Opens one app-owned destination as a child of the currently visible destination.

     - Parameter destination: Child activity-equivalent destination to present.
     - Side effects: Pushes the current destination onto the app-owned back stack and replaces the
       visible destination without changing the captured reader pane.
     - Failure modes: When no parent is active, the destination becomes a root route. Reopening the
       already-active destination is ignored so duplicate Back entries cannot accumulate.
     */
    private func presentChildReaderDestination(_ destination: ReaderDestination) {
        guard activeReaderDestination != destination else {
            return
        }
        if let parent = activeReaderDestination {
            readerDestinationBackStack.append(parent)
        }
        activeReaderDestination = destination
    }

    /**
     Handles Back for an app-owned reader destination.

     - Side effects: Restores the most recent parent destination, or closes the destination host
       when no parent remains.
     - Failure modes: An empty back stack intentionally returns to the reader shell.
     */
    private func dismissReaderDestination() {
        activeReaderDestination = readerDestinationBackStack.popLast()
    }

    /**
     Opens Android Reading Progress with either an explicit bridge tab or its persisted tab.

     - Parameters:
       - initialTab: Android intent-tab equivalent, or `nil` to restore the last selected tab.
       - windowId: Reader pane that owns progress navigation and its child actions.
     */
    private func presentReadingProgress(
        initialTab: ReadingProgressTab?,
        from windowId: UUID? = nil
    ) {
        readingProgressInitialTab = initialTab
        presentReaderDestination(.readingProgress, from: windowId)
    }

    /// Opens Application preferences as an integrated reader-stack destination.
    private func presentSettings(from windowId: UUID? = nil) {
        presentReaderDestination(.settings, from: windowId)
    }

    /**
     Opens Android's global Text Options route as app-scoped text-display settings.

     - Parameters:
       - windowId: Pane context retained for parent-scope navigation.
       - asChild: Whether to preserve the current app-owned activity as the Back destination.
     - Side effects:
       - refreshes app-level text-display defaults from `SettingsStore`
       - presents `.globalTextOptions` as either a root or child reader destination
     - Failure modes: Settings load falls back through `SettingsStore` defaults.
     */
    private func presentGlobalTextOptions(
        from windowId: UUID? = nil,
        asChild: Bool = false
    ) {
        let store = SettingsStore(modelContext: modelContext)
        globalDisplaySettings = store.globalTextDisplaySettings()
        if asChild {
            presentChildReaderDestination(.globalTextOptions)
        } else {
            presentReaderDestination(.globalTextOptions, from: windowId)
        }
    }

    /**
     Opens Android's main reader All Text Options route as workspace-scoped settings.

     - Parameters:
       - windowId: Pane whose workspace should own the pushed destination.
       - asChild: Whether to preserve the current app-owned activity as the Back destination.
     - Side effects:
       - refreshes the workspace editor state from the current workspace/global inheritance chain
       - presents `.workspaceTextOptions` as either a root or child reader destination
     - Failure modes: If no active workspace exists, the editor opens against global/app defaults
       and writes become no-ops in `applyWorkspaceDisplaySettingsChange`.
     */
    private func presentWorkspaceTextOptions(
        from windowId: UUID? = nil,
        asChild: Bool = false
    ) {
        let targetWindow = windowId.flatMap { id in
            windowManager.allWindows.first { $0.id == id }
        } ?? windowManager.activeWindow
        workspaceDisplaySettings = resolvedWorkspaceDisplaySettings(
            for: targetWindow?.workspace ?? windowManager.activeWorkspace
        )
        if asChild {
            presentChildReaderDestination(.workspaceTextOptions)
        } else {
            presentReaderDestination(.workspaceTextOptions, from: targetWindow?.id ?? windowId)
        }
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
     Opens Android's window-scoped Color settings route directly from the pane menu.

     - Parameter windowId: Pane whose color overrides should be edited.
     - Side effects: refreshes the window editor state and pushes the color settings destination.
     - Failure modes: Missing windows fall back to the active window and inherited settings.
     */
    private func presentWindowColorSettings(from windowId: UUID? = nil) {
        let targetWindow = windowId.flatMap { id in
            windowManager.allWindows.first { $0.id == id }
        } ?? windowManager.activeWindow
        windowDisplaySettings = resolvedDisplaySettings(for: targetWindow)
        presentReaderDestination(.windowColorSettings, from: targetWindow?.id ?? windowId)
    }

    /**
     Presents Android's selective Copy settings dialog for one pane menu target.

     - Parameters:
       - sourceWindowId: Window whose raw text-display overrides are copied.
       - target: Destination selected from the `Copy settings to...` submenu.
     - Side effects: Captures a pending copy request rendered by `TextDisplaySettingsCopyDialog`.
     - Failure modes: Missing source windows are ignored.
     */
    private func presentTextSettingsCopy(from sourceWindowId: UUID, target: TextSettingsCopyTarget) {
        guard windowManager.allWindows.contains(where: { $0.id == sourceWindowId }) else { return }
        textSettingsCopyRequest = TextSettingsCopyRequest(
            sourceWindowID: sourceWindowId,
            target: target,
            targetTitle: textSettingsCopyTargetTitle(target)
        )
    }

    private func textSettingsCopyTargetTitle(_ target: TextSettingsCopyTarget) -> String {
        switch target {
        case .window(let targetWindowID):
            guard let targetWindow = windowManager.visibleWindows.first(where: { $0.id == targetWindowID }) else {
                return localizedAndroidOverflowString(
                    androidKey: "copy_settings_to_window",
                    fallbackKey: nil,
                    default: "Window"
                )
            }
            return windowCopySettingsTitle(targetWindow)
        case .workspace:
            return localizedAndroidOverflowString(
                androidKey: "copy_settings_to_workspace",
                fallbackKey: nil,
                default: "Workspace"
            )
        case .global:
            return localizedAndroidOverflowString(
                androidKey: "copy_settings_to_global",
                fallbackKey: nil,
                default: "Global defaults"
            )
        }
    }

    private func windowCopySettingsTitle(_ window: BibleCore.Window) -> String {
        let visibleWindows = windowManager.visibleWindows
        let position = (visibleWindows.firstIndex(where: { $0.id == window.id }) ?? 0) + 1
        let controller = self.controller(for: window.id)
        let document = controller?.activeModuleName(for: controller?.currentCategory ?? .bible)
            ?? window.pageManager?.bibleDocument
            ?? ""
        let reference: String
        if let controller {
            reference = "\(controller.currentBook) \(controller.currentChapter)"
        } else if let chapter = window.pageManager?.bibleChapterNo {
            reference = "\(chapter)"
        } else {
            reference = ""
        }
        return String(
            format: localizedAndroidOverflowString(
                androidKey: "copy_settings_to_window",
                fallbackKey: nil,
                default: "Window %1$d (%2$@:%3$@)"
            ),
            position,
            document,
            reference
        )
    }

    /**
     Opens Downloads and seeds its free-text search from an Android `download://` target.

     - Parameters:
       - windowId: Pane whose controller should own the destination context. When `nil`, the focused
         pane is used.
       - initialSearchText: Optional module initials from the link query. Empty and whitespace-only
         values are normalized away so normal Downloads entry points remain unfiltered.
       - defaultDownloadMode: Optional startup/default-document mode for Android Easy Start.

     Side effects:
     - captures the pane presentation target
     - updates `downloadsInitialSearchText`
     - updates `downloadsDefaultDownloadMode`
     - pushes the `.downloads` reader destination

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
        presentReaderDestination(.downloads, from: windowId)
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
        startupDownloadPromptReason = nil
        startupDefaultDownloadsInFlight = true
        presentDownloads(
            from: windowManager.activeWindow?.id,
            defaultDownloadMode: .englishStartup
        )
    }

    /**
     Opens the standard document download route from startup setup.

     Side effects:
     - presents Downloads on the reader destination stack
     */
    private func presentStartupDownloadDocuments() {
        presentDownloads(from: windowManager.activeWindow?.id)
    }

    /**
     Opens Backup & Restore so the user can load local document files from startup setup.

     Android launches `InstallZip` directly from this action. iOS keeps the existing import engine
     behind the Android-aligned Backup & Restore screen so startup does not fork file-import logic.

     Side effects:
     - presents Backup & Restore on the reader destination stack with the Documents target
     */
    private func presentStartupLoadDocumentsFromFiles() {
        presentStartupImportExport(for: .documents)
    }

    /**
     Opens the database restore picker from startup setup.

     Side effects:
     - presents Backup & Restore on the reader destination stack with the Database target
     */
    private func presentStartupRestoreDatabase() {
        presentStartupImportExport(for: .database)
    }

    /**
     Routes startup import/restore actions through the existing Android-compatible picker surface.

     Side effects:
     - stores the startup restore/import target for the next Backup & Restore route
     - pushes `.importExport` as the active reader destination
     */
    private func presentStartupImportExport(for restoreImportTarget: RestoreWorkflowTarget) {
        startupRestoreImportTarget = restoreImportTarget
        presentReaderDestination(.importExport, from: windowManager.activeWindow?.id)
    }

    /**
     Handles side effects that belong to a reader-stack destination closing.

     Settings and Downloads are navigation destinations instead of sheets. Reloading behavior
     preferences on Settings pop preserves the former modal refresh boundary; Downloads pop refreshes
     module caches and reopens Android's first-download prompt only if the user still has no Bibles.

     - Parameters:
       - previousDestination: Destination that was visible before SwiftUI reported the change.
       - currentDestination: Destination now visible after SwiftUI reported the change.
     - Side Effects: Reloads reader behavior preferences after Settings closes and refreshes module
       state after Downloads closes.
     - Failure: Non-closing destination transitions are ignored.
     */
    private func handleActiveReaderDestinationChange(
        from previousDestination: ReaderDestination?,
        to currentDestination: ReaderDestination?
    ) {
        guard currentDestination == nil, let previousDestination else {
            return
        }
        readerDestinationBackStack.removeAll()
        switch previousDestination {
        case .search:
            searchInitialQuery = ""
        case .bookmarks, .studyPads, .myDocuments, .readingPlans, .readingProgress,
             .readingProgressSettings, .workspaces, .speakControls, .syncSettings,
             .dictionaryBrowser, .generalBookBrowser, .mapBrowser, .epubSearch, .labelManager,
             .aiSettings, .modulePicker, .chooseDocument:
            break
        case .passageChooser:
            resetPassageChooserProgressContext()
        case .settings:
            reloadBehaviorPreferences()
        case .startupDocumentSetup:
            handleStartupDocumentSetupClosed()
        case .downloads:
            handleDownloadsDestinationClosed()
        case .importExport:
            handleImportExportDestinationClosed()
        case .globalTextOptions, .workspaceTextOptions, .windowTextOptions, .windowColorSettings,
             .windowHiddenLabels:
            break
        }
    }

    /**
     Handles an unexpected close of the startup setup route.

     Startup setup is blocking in Android, so if SwiftUI reports that either no-Bible or locked-only
     setup closed without a setup action, iOS immediately re-evaluates fresh inventory state.

     - Side effects: May re-present startup setup when no readable Bible is available.
     - Failure modes: A cleared prompt reason means setup already completed and needs no retry.
     */
    private func handleStartupDocumentSetupClosed() {
        guard startupDownloadPromptReason != nil else { return }
        didEvaluateStartupDownloadPrompt = false
        evaluateStartupDownloadPromptIfNeeded()
    }

    /**
     Applies Android's after-download behavior after the Downloads destination closes.

     Android `afterDownload()` refreshes document state and returns to the first-download prompt when
     the user exits Downloads without installing a Bible. iOS mirrors that on destination pop instead
     of sheet dismissal because Downloads is a reader-stack route.

     Side effects:
     - clears one-shot Downloads launch state
     - refreshes installed-module snapshots in every open reader controller
     - may re-show the startup no-Bible prompt when no Bible was installed

     Failure modes:
     - module-refresh failures remain isolated inside each controller's refresh path
     */
    private func handleDownloadsDestinationClosed() {
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
    }

    /**
     Refreshes reader module state after the startup import/restore route closes.

     Backup & Restore can install modules or restore Android-compatible backups through existing
     engines. This mirrors Android's `afterDownload()` check by returning to blocking setup when the
     user still has no Bible.

     Side effects:
     - refreshes installed-module snapshots in every open reader controller
     - may re-show the startup no-Bible route
     */
    private func handleImportExportDestinationClosed() {
        startupRestoreImportTarget = nil
        for (_, ctrl) in windowManager.controllers {
            (ctrl as? BibleReaderController)?.refreshInstalledModules()
        }
        reevaluateStartupDownloadPromptAfterDownloads()
    }

    /**
     Refreshes open reader controllers after the installed SWORD module store changes.

     Settings restores, external ZIP opens, and Downloads installs mutate module files outside the
     reader controllers that own visible picker state. Those controllers must rebuild their
     `SwordManager` instances because SWORD and the C bridge cache module lists per manager.

     - Side effects:
       - recreates SWORD managers inside every open `BibleReaderController`
       - updates either blocking startup reason or hides setup when a Bible becomes readable
     - Failure modes: Controllers that cannot create a replacement `SwordManager` retain their
       existing state; unresolved inventory preserves the current blocking reason.
     */
    private func handleModuleStoreDidChange() {
        // Keep Android's initial locked snapshot immutable. Any concurrent store mutation is picked
        // up by the queue's single final refresh instead of changing its length or reader state.
        guard startupLockedBibleUnlockRequest == nil else { return }
        for (_, ctrl) in windowManager.controllers {
            (ctrl as? BibleReaderController)?.refreshInstalledModules()
        }
        guard startupDownloadPromptReason != nil else { return }
        let evaluation = StartupDocumentSetupPromptPolicy.evaluation(
            modules: startupInstalledModules()
        )
        guard evaluation.didEvaluateInventory else { return }
        startupDownloadPromptReason = evaluation.promptReason
        if evaluation.promptReason == nil, activeReaderDestination == .startupDocumentSetup {
            activeReaderDestination = nil
        }
    }

    /// Presents a follow-up reader destination after another flow already captured the pane target.
    private func presentReaderDestinationPreservingPane(_ destination: ReaderDestination) {
        activeReaderDestination = destination
    }

    /**
     Replaces the document chooser destination with its StudyPads destination.

     Android treats StudyPads as an app-owned `ManageLabels` route rather than a nested chooser
     sheet. The chooser has already captured the pane target, so the destination changes without
     changing pane ownership or introducing a second presentation host.

     Side effects:
     - sets `activeReaderDestination` to `.studyPads`

     Failure modes:
     - if no pane controller is available, the destination renders its normal preparation fallback
     */
    private func presentStudyPadsDestinationPreservingPane() {
        presentReaderDestinationPreservingPane(.studyPads)
    }

    /**
     Opens Downloads after a pane-scoped flow has already captured the owning pane.

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
        presentReaderDestinationPreservingPane(.downloads)
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
        presentReaderDestinationPreservingPane(.passageChooser)
    }

    /// Closes the book chooser without changing the current pane target.
    private func dismissBookChooser() {
        activeReaderDestination = nil
        resetPassageChooserProgressContext()
    }

    /// Releases stored chooser progress snapshots after the passage chooser closes.
    private func resetPassageChooserProgressContext() {
        passageChooserProgressContext = .empty
    }

    /**
     Presents Android's Bible-toolbar quick selector for the focused pane.

     - Parameters:
       - controller: Pane controller whose installed Bible module list should back the popup.
       - rows: Android-parity rows resolved by the pure quick-selector presentation contract.
     - Side effects: Captures the active pane, closes competing reader popups, and shows the anchored
       quick selector overlay.
     - Failure modes: If the active pane cannot be identified, the popup still uses the focused
       controller fallback through `panePresentationController`.
     */
    private func presentBibleQuickSelector(
        _ controller: BibleReaderController,
        rows: [BibleReaderQuickModuleSelectorPresentation.Row]
    ) {
        let targetWindowId = windowManager.controllers.first { _, registeredController in
            (registeredController as? BibleReaderController) === controller
        }?.key
        let resolvedTargetWindowId = targetWindowId ?? windowManager.activeWindow?.id
        setPanePresentationTarget(resolvedTargetWindowId)
        bibleQuickModuleSelectorTargetWindowId = resolvedTargetWindowId
        bibleQuickModuleSelectorRows = rows
        showReaderOverflowMenu = false
        showReaderNavigationDrawer = false
        dismissCommentaryQuickSelector()
        showBibleQuickModuleSelector = true
    }

    /// Dismisses the Bible quick selector without changing the captured pane target.
    private func dismissBibleQuickSelector() {
        showBibleQuickModuleSelector = false
        bibleQuickModuleSelectorRows = []
        bibleQuickModuleSelectorTargetWindowId = nil
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
     Resolves the Bible document Android would switch back to from a non-Bible document mode.

     Android's `DocumentControl.suggestedBible` returns the active window's current Bible document
     when Bible is not the visible document type. iOS stores that same pane-scoped choice on
     `PageManager.bibleDocument`; if it is absent, locked, or no longer installed, the readable
     Bible list provides the same default fallback established when the reader is initialized.

     - Parameter controller: Pane controller that owns the toolbar action.
     - Returns: Readable Bible module abbreviation to show, or `nil` when no readable Bible exists.
     - Side effects: Reads fresh native module access state through the controller.
     - Failure modes: Returns `nil` when the pane has no readable Bible modules; the saved locked
       identity remains unchanged for a future app-owned unlock workflow.
     */
    private func suggestedBibleDocumentName(for controller: BibleReaderController) -> String? {
        let readableModules = controller.readableBibleModules
        if let saved = controller.activeWindow?.pageManager?.bibleDocument,
           readableModules.contains(where: { $0.name == saved }) {
            return saved
        }
        return readableModules.first?.name
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
    private func selectBibleQuickModule(_ module: ModuleInfo, targetWindowId: UUID?) {
        let controller = controller(for: targetWindowId)
        dismissBibleQuickSelector()
        guard let controller else { return }
        controller.switchBibleDocument(to: module.name)
    }

    /**
     Presents Android's commentary/document quick selector for the focused pane.

     - Parameters:
       - controller: Pane controller whose installed commentary-adjacent module list backs the popup.
       - rows: Android-parity rows resolved by the pure quick-selector presentation contract.
     - Side effects: Captures the active pane, closes competing reader popups, and shows the anchored
       quick selector overlay.
     - Failure modes: If the active pane cannot be identified, the popup still uses the focused
       controller fallback through `panePresentationController`.
     */
    private func presentCommentaryQuickSelector(
        _ controller: BibleReaderController,
        rows: [BibleReaderQuickModuleSelectorPresentation.Row]
    ) {
        let targetWindowId = windowManager.controllers.first { _, registeredController in
            (registeredController as? BibleReaderController) === controller
        }?.key
        let resolvedTargetWindowId = targetWindowId ?? windowManager.activeWindow?.id
        setPanePresentationTarget(resolvedTargetWindowId)
        commentaryQuickModuleSelectorTargetWindowId = resolvedTargetWindowId
        commentaryQuickModuleSelectorRows = rows
        showReaderOverflowMenu = false
        showReaderNavigationDrawer = false
        dismissBibleQuickSelector()
        showCommentaryQuickModuleSelector = true
    }

    /// Dismisses the commentary quick selector without changing the captured pane target.
    private func dismissCommentaryQuickSelector() {
        showCommentaryQuickModuleSelector = false
        commentaryQuickModuleSelectorRows = []
        commentaryQuickModuleSelectorTargetWindowId = nil
    }

    /**
     Resolves the current commentary-adjacent document name for quick-menu row disabling.

     Android disables whichever document is currently visible in the popup candidate list. The
     commentary toolbar popup can include commentaries, dictionaries, and general books, so the
     disabled row follows the pane's active document category instead of always using commentary.

     - Parameter controller: Pane controller that owns the quick selector, if still available.
     - Returns: Active module abbreviation for commentary, dictionary, or general-book categories;
       otherwise `nil` so rows remain selectable from Bible and other modes.
     - Side effects: none.
     - Failure modes: none; missing controllers are treated as having no current document.
     */
    private func currentCommentaryQuickSelectorModuleName(for controller: BibleReaderController?) -> String? {
        guard let controller else { return nil }
        switch controller.currentCategory {
        case .commentary:
            return controller.activeCommentaryModuleName
        case .dictionary:
            return controller.activeDictionaryModuleName
        case .generalBook:
            return controller.activeGeneralBookModuleName
        default:
            return nil
        }
    }

    /**
     Builds Android's commentary toolbar quick-selector candidate set.

     Android default commentary taps call `menuForDocs` with unlocked commentaries plus general books
     plus dictionaries. In `swap-menu`, commentary long press calls `menuForDocs` with commentaries
     only. This helper preserves that distinction and leaves sorting/labeling to the shared
     presentation contract.

     - Parameters:
       - controller: Pane controller that owns installed module lists.
       - includeAuxiliaryDocuments: Whether to include general books and dictionaries.
     - Returns: Candidate modules in the same category mix Android hands to `menuForDocs`.
     - Side effects: none.
     - Failure modes: none; empty installed lists return an empty candidate list.
     */
    private func commentaryQuickSelectorModules(
        _ controller: BibleReaderController,
        includeAuxiliaryDocuments: Bool
    ) -> [ModuleInfo] {
        var modules = controller.installedCommentaryModules.filter(\.isUnlocked)
        guard includeAuxiliaryDocuments else {
            return modules
        }
        modules += controller.installedGeneralBookModules
        modules += controller.installedDictionaryModules
        return modules
    }

    /**
     Applies a commentary/document quick-selector choice to the captured pane.

     - Parameters:
       - module: Installed module selected from the Android-parity quick selector.
       - targetWindowId: Captured window whose controller owns the popup selection.
     - Side effects: Dismisses the popup and switches the pane through the category-specific
       current-document path. Generic exact keys render immediately, invalid/missing keys open their
       browser, and validation/enumeration failures present a Retry/Cancel alert.
     - Failure modes: If the controller is no longer available, or the selected module category is
       not part of Android's commentary quick popup, the selection is ignored after dismissal.
       SWORD key validation/enumeration failures leave pane state unchanged and remain retryable.
     */
    private func selectCommentaryQuickModule(_ module: ModuleInfo, targetWindowId: UUID?) {
        let controller = controller(for: targetWindowId)
        dismissCommentaryQuickSelector()
        guard let controller else { return }
        switch module.category {
        case .commentary:
            controller.switchCommentaryDocument(to: module.name)
        case .dictionary:
            handleGenericQuickModuleSwitch(
                controller.switchDictionaryDocument(to: module.name),
                module: module,
                targetWindowId: targetWindowId,
                browser: .dictionaryBrowser
            )
        case .generalBook:
            handleGenericQuickModuleSwitch(
                controller.switchGeneralBookDocument(to: module.name),
                module: module,
                targetWindowId: targetWindowId,
                browser: .generalBookBrowser
            )
        default:
            return
        }
    }

    /**
     Routes one generic quick-selector switch through Android's retain-or-choose behavior.

     - Parameters:
       - outcome: Exact-key validation result returned by the reader controller.
       - module: Selected module retained when validation needs an explicit retry.
       - targetWindowId: Pane captured by the quick selector.
       - browser: Category chooser shown only when the previous key is invalid or missing.
     - Side effects: Presents the key browser for invalid keys or an actionable retry alert for
       backend failures. A retained exact key requires no follow-up presentation.
     - Failure modes: Repeated validation/enumeration failures replace the same retry request without
       mutating the target pane's module, key, category, or persisted state. A later transient browser
       failure remains retryable inside the browser.
     */
    private func handleGenericQuickModuleSwitch(
        _ outcome: BibleReaderGenericModuleSwitchOutcome,
        module: ModuleInfo,
        targetWindowId: UUID?,
        browser: ReaderDestination
    ) {
        switch outcome {
        case .switchedPreservingKey:
            return
        case .switchedRequiringKeySelection:
            presentReaderDestinationPreservingPane(browser)
        case .failed(let message):
            pendingGenericQuickModuleSwitchRetry = GenericQuickModuleSwitchRetry(
                module: module,
                targetWindowId: targetWindowId,
                message: message
            )
        }
    }

    /// Presents the document-category module picker for a pane-scoped action.
    private func presentModulePicker(_ category: DocumentCategory, from windowId: UUID? = nil) {
        pickerCategory = category
        presentReaderDestination(.modulePicker, from: windowId)
    }

    // MARK: - Lifecycle Wiring

    /**
     Reactivates the reader whenever SwiftUI makes the root screen visible.

     Persisted reader preferences are intentionally reloaded because a Settings destination may
     change them. Speech restoration and callback binding are separately guarded to the first
     appearance, while later destination returns only refresh the active bookmark owner.

     - Side effects: Reloads reader state, performs first-appearance speech setup when required,
       refreshes lightweight reader bindings, installs synchronized scrolling, and evaluates
       pending launch/test routes.
     - Failure modes: Missing active controllers leave speech bookmark ownership unchanged; startup
       evaluation retains its existing retry behavior.
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
     Shows the startup document-setup prompt once when setup requires user attention.

     Android `StartupActivity` stops on its first-download layout whenever no readable Bible remains
     after its locked-document unlock queue. iOS classifies empty and locked-only inventory
     separately so locked startup first snapshots and presents the same complete sequential queue,
     without introducing a bundled-KJV fallback or first-run marker path.

     - Side effects:
       - reads installed modules through the focused controller or a temporary `SwordManager`
       - mutates `didEvaluateStartupDownloadPrompt` and `startupDownloadPromptReason`
     - Failure modes: If installed-module inventory is unavailable, evaluation remains pending for
       a later controller-registration pass.
     */
    private func evaluateStartupDownloadPromptIfNeeded() {
        guard !didEvaluateStartupDownloadPrompt,
              activeReaderDestination == nil,
              startupLockedBibleUnlockRequest == nil else {
            return
        }
        let manager = focusedController?.swordManager ?? SwordManager()
        let installedModules = manager.map {
            StartupDocumentSetupModuleInventory.modules(manager: $0)
        } ?? focusedController?.installedBibleModules
        let evaluation = StartupDocumentSetupPromptPolicy.evaluation(
            modules: installedModules
        )
        guard evaluation.didEvaluateInventory else { return }
        didEvaluateStartupDownloadPrompt = true
        let promptReason = evaluation.promptReason
        if beginStartupLockedBibleUnlockQueueIfNeeded(
            promptReason: promptReason,
            manager: manager,
            installedModules: installedModules ?? []
        ) {
            startupDownloadPromptReason = nil
            return
        }
        startupDownloadPromptReason = promptReason
        if promptReason != nil {
            presentReaderDestination(.startupDocumentSetup, from: windowManager.activeWindow?.id)
        }
    }

    /**
     Re-runs the startup prompt after Downloads or import closes.

     Android's `afterDownload()` returns to the first-download layout when the user leaves
     Downloads without installing a Bible. This mirrors that behavior without prompting again when a
     readable Bible is now present; locked-only inventory starts the same automatic queue before
     setup is allowed to reappear.

     - Side effects:
       - may reset the startup-prompt guard
       - may show the required no-Bible or locked-only startup prompt again
     - Failure modes: If installed-module inventory is unavailable, evaluation remains pending.
     */
    private func reevaluateStartupDownloadPromptAfterDownloads() {
        guard startupLockedBibleUnlockRequest == nil else { return }
        let manager = focusedController?.swordManager ?? SwordManager()
        let installedModules = manager.map {
            StartupDocumentSetupModuleInventory.modules(manager: $0)
        } ?? focusedController?.installedBibleModules
        let evaluation = StartupDocumentSetupPromptPolicy.evaluation(
            modules: installedModules
        )
        guard evaluation.didEvaluateInventory else {
            didEvaluateStartupDownloadPrompt = false
            return
        }
        didEvaluateStartupDownloadPrompt = true
        let promptReason = evaluation.promptReason
        if beginStartupLockedBibleUnlockQueueIfNeeded(
            promptReason: promptReason,
            manager: manager,
            installedModules: installedModules ?? []
        ) {
            startupDownloadPromptReason = nil
            if activeReaderDestination == .startupDocumentSetup {
                activeReaderDestination = nil
            }
            return
        }
        startupDownloadPromptReason = promptReason
        guard promptReason != nil else {
            if activeReaderDestination == .startupDocumentSetup {
                activeReaderDestination = nil
            }
            return
        }
        if activeReaderDestination == nil {
            presentReaderDestination(.startupDocumentSetup, from: windowManager.activeWindow?.id)
        }
    }

    /**
     Starts Android's automatic locked-only passphrase queue from one resolved startup snapshot.

     - Parameters:
       - promptReason: Fresh startup policy result for the inclusive snapshot.
       - manager: Manager that produced native access state and will validate queued credentials.
       - installedModules: Inclusive native-plus-SQLite snapshot in installed registration order.
     - Returns: `true` only when a non-empty locked-Bible queue was retained for presentation.
     - Side effects: Assigns `startupLockedBibleUnlockRequest`; it does not change navigation,
       select a document, refresh controllers, or re-read inventory.
     - Failure modes: Non-locked reasons, unavailable managers, and inconsistent empty locked
       snapshots return `false`, allowing the caller's existing fail-closed setup route to continue.
     */
    private func beginStartupLockedBibleUnlockQueueIfNeeded(
        promptReason: StartupDocumentSetupPromptPolicy.PromptReason?,
        manager: SwordManager?,
        installedModules: [ModuleInfo]
    ) -> Bool {
        guard promptReason == .lockedBibleModules,
              let manager,
              !StartupLockedBibleUnlockQueue.lockedBibleModules(
                in: installedModules
              ).isEmpty else {
            return false
        }
        startupLockedBibleUnlockRequest = StartupLockedBibleUnlockRequest(
            manager: manager,
            installedModules: installedModules
        )
        return true
    }

    /**
     Finishes the full initial queue with exactly one fresh readability reconciliation.

     Android continues through every locked Bible even after a successful credential. Only after
     that immutable queue is exhausted does startup ask the installed registry whether any Bible is
     readable. iOS first rebuilds open reader managers so persisted accepted keys become available,
     then evaluates one fresh native-plus-SQLite snapshot without selecting any queued module.

     - Parameter request: Queue request whose identity and manager own this completion callback.
     - Side effects:
       - dismisses the queue and refreshes every open reader controller once
       - clears startup setup and enters the existing reader state when any Bible is readable
       - otherwise presents the existing blocking setup route with the fresh reason
     - Failure modes: Stale callbacks are ignored by request identity. If a refreshed controller
       manager is unavailable, a new manager at the request path is attempted before falling back to
       the retained session manager; unresolved inventory fails closed through policy evaluation.
     */
    private func completeStartupLockedBibleUnlockQueue(
        _ request: StartupLockedBibleUnlockRequest
    ) {
        guard startupLockedBibleUnlockRequest?.id == request.id else { return }
        startupLockedBibleUnlockRequest = nil

        for (_, ctrl) in windowManager.controllers {
            (ctrl as? BibleReaderController)?.refreshInstalledModules()
        }

        let reconciliationManager = focusedController?.swordManager
            ?? SwordManager(modulePath: request.manager.modulePath)
            ?? request.manager
        let evaluation = StartupDocumentSetupPromptPolicy.evaluation(
            modules: StartupDocumentSetupModuleInventory.modules(
                manager: reconciliationManager
            )
        )
        didEvaluateStartupDownloadPrompt = true
        startupDownloadPromptReason = evaluation.promptReason

        guard evaluation.promptReason != nil else {
            readerDestinationBackStack.removeAll()
            if activeReaderDestination == .startupDocumentSetup {
                activeReaderDestination = nil
            }
            return
        }
        if activeReaderDestination == nil {
            presentReaderDestination(.startupDocumentSetup, from: windowManager.activeWindow?.id)
        }
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
        guard !isInFlight, activeReaderDestination == nil else {
            return
        }

        for (_, ctrl) in windowManager.controllers {
            (ctrl as? BibleReaderController)?.refreshInstalledModules()
        }
        reevaluateStartupDownloadPromptAfterDownloads()
    }

    /**
     Returns the current local module inventory used for startup setup decisions.

     - Returns: Fresh native modules plus validated, unshadowed Android SQLite Bibles from the
       focused controller's module root, the default root otherwise, or the focused controller's
       Bible cache as a final fallback when manager creation fails.
     - Side effects: May create a temporary `SwordManager`; resolved managers enumerate and validate
       ordinary SQLite Bible files read-only through the shared startup inventory boundary.
     - Failure modes: Returns `nil` if no focused controller exists and `SwordManager` creation
       fails.
     */
    private func startupInstalledModules() -> [ModuleInfo]? {
        if let manager = focusedController?.swordManager {
            return StartupDocumentSetupModuleInventory.modules(manager: manager)
        }
        if let manager = SwordManager() {
            return StartupDocumentSetupModuleInventory.modules(manager: manager)
        }
        return focusedController?.installedBibleModules
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
        monochromeModePref = store.getBool(.monochromeMode)
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = store.getBool(.screenKeepOnPref)
        #endif
    }

    /**
     Coordinates first-appearance speech initialization and repeat reader reactivation.

     - Parameter store: Current persistence boundary for global speech and behavior preferences.
     - Side effects: Performs heavyweight restoration exactly once per `BibleReaderView` identity,
       then refreshes the active bookmark owner on every appearance.
     - Failure modes: Missing active workspace or controller data uses restored global settings and
       leaves bookmark ownership unchanged.
     */
    private func configureSpeakService(with store: SettingsStore) {
        if speechLifecycleState.beginActivation() {
            performInitialSpeakServiceSetup(with: store)
        }
        reactivateSpeakService()
    }

    /**
     Restores persisted speech state and installs reader callbacks once per reader identity.

     - Parameter store: Persistence boundary assigned before restoration.
     - Side effects: Restores global settings and checkpoints, applies the initial workspace
       settings, replaces speech callbacks, and installs late-bound reader session reconstruction.
     - Failure modes: Missing workspace settings retain the restored global value; missing active
       controllers fail closed inside the late-bound session callbacks.
     */
    private func performInitialSpeakServiceSetup(with store: SettingsStore) {
        speakService.settingsStore = store
        speakService.restoreSettings()

        let wm = windowManager
        if let workspaceSettings = wm.activeWorkspace?.workspaceSettings {
            speakService.applySettings(workspaceSettings.speakSettings, persist: false)
        }

        speakService.onRequestNext = nil
        speakService.onRequestPrevious = nil
        speakService.onFinishedSpeaking = nil
        speakService.onSettingsChanged = { settings in
            guard let workspace = wm.activeWorkspace else { return }
            var workspaceSettings = workspace.workspaceSettings ?? WorkspaceSettings()
            workspaceSettings.speakSettings = settings.normalized
            workspace.workspaceSettings = workspaceSettings
            try? modelContext.save()
        }
        BibleReaderSpeechSessionBinding.install(on: speakService) { [weak wm] in
            guard let wm, let activeId = wm.activeWindow?.id else { return nil }
            return wm.controllers[activeId] as? BibleReaderController
        }
    }

    /**
     Refreshes speech state that legitimately follows the currently active reader pane.

     Reusing the same bookmark owner still reloads resume rows so bookmark changes made in a
     destination are visible on return. Assigning a different owner relies on `SpeakService`'s
     `didSet` reload and avoids duplicate database work.

     - Side effects: May replace the weak bookmark persistence owner or reload its resume rows.
     - Failure modes: Returns without mutation until an active Bible reader controller exists.
     */
    private func reactivateSpeakService() {
        guard let activeId = windowManager.activeWindow?.id,
              let controller = windowManager.controllers[activeId] as? BibleReaderController else {
            return
        }
        if speakService.bookmarkManager !== controller.bookmarkService {
            speakService.bookmarkManager = controller.bookmarkService
        } else {
            speakService.reloadResumeBookmarks()
        }
    }

    /**
     Registers target-versification-safe scrolling across synchronized reader windows.

     The callback resolves the source module ordinal back to one authoritative verse identity, then
     asks every target controller to resolve that verse in its own module. A source ordinal is never
     reused directly in a target module because ordinal spaces differ across versifications.

     - Side effects: Replaces `WindowManager.onSyncVerseChanged` and may navigate synchronized target
       panes after a verified source and target conversion.
     - Failure modes: Missing controllers or an unresolvable source verse stop the update; individual
       targets that cannot represent the verse remain unchanged.
     */
    private func installSynchronizedScrollingCallback() {
        windowManager.onSyncVerseChanged = { [weak windowManager] sourceWindow, ordinal, _ in
            guard let wm = windowManager else { return }
            let syncTargets = wm.synchronizedVerseUpdateTargets(for: sourceWindow)
            guard let sourceReference = (wm.controllers[sourceWindow.id] as? BibleReaderController)?
                .synchronizedVerseReference(ordinal: ordinal) else {
                return
            }
            for target in syncTargets {
                guard let ctrl = wm.controllers[target.id] as? BibleReaderController else {
                    continue
                }
                ctrl.scrollToSynchronizedVerse(
                    osisBookId: sourceReference.osisBookId,
                    chapter: sourceReference.chapter,
                    verse: sourceReference.verse
                )
            }
        }
    }

    // MARK: - Split Content

    /**
     Lays out the visible reading panes and separators for the active workspace.

     On iOS the layout orientation follows the owning window bounds and the workspace reverse-split
     setting, while current child geometry controls only pane extents. This mirrors Android
     configuration orientation so keyboard insets cannot change the axis. Pane sizes are derived from
     persisted `layoutWeight` values so resizing survives navigation and relayout.
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
                presentReaderDestination(.labelManager, from: windowManager.activeWindow?.id)
            case .bookmarks:
                presentReaderDestination(.bookmarks, from: windowManager.activeWindow?.id)
            case .history:
                presentHistoryDialog(from: windowManager.activeWindow?.id)
            case .readingPlans:
                presentReaderDestination(.readingPlans, from: windowManager.activeWindow?.id)
            case .settings:
                presentSettings(from: windowManager.activeWindow?.id)
            case .textOptions:
                presentWorkspaceTextOptions(from: windowManager.activeWindow?.id)
            case .workspaces:
                presentReaderDestination(.workspaces, from: windowManager.activeWindow?.id)
            case .downloads:
                presentDownloads(from: windowManager.activeWindow?.id)
            case .epubBrowser:
                presentReaderDestination(.generalBookBrowser, from: windowManager.activeWindow?.id)
            case .epubSearch:
                presentReaderDestination(.epubSearch, from: windowManager.activeWindow?.id)
            case .help:
                presentHelpDialog()
            }
        }
    }

    /** Opens Bookmarks from the reader shell. */
    private func openBookmarksFromReaderAction() {
        presentReaderDestination(.bookmarks, from: windowManager.activeWindow?.id)
    }

    /** Opens History from the reader shell. */
    private func openHistoryFromReaderAction() {
        presentHistoryDialog(from: windowManager.activeWindow?.id)
    }

    /** Opens Reading Plans from the reader shell. */
    private func openReadingPlansFromReaderAction() {
        presentReaderDestination(.readingPlans, from: windowManager.activeWindow?.id)
    }

    /** Opens Settings from the reader shell. */
    private func openSettingsFromReaderAction() {
        presentSettings(from: windowManager.activeWindow?.id)
    }

    /** Opens Workspaces from the reader shell. */
    private func openWorkspacesFromReaderAction() {
        presentReaderDestination(.workspaces, from: windowManager.activeWindow?.id)
    }

    /** Opens Downloads from the reader shell. */
    private func openDownloadsFromReaderAction() {
        presentDownloads(from: windowManager.activeWindow?.id)
    }

    /**
     Builds one `BibleWindowPane` and wires all pane-level callbacks back into this coordinator.

     - Parameter window: Persisted window model that owns the pane's category, history, and
       layout state.
     - Returns: A fully configured pane view bound to coordinator-owned presentation state.
     */
    private func paneView(for window: BibleCore.Window) -> some View {
        BibleWindowPane(
            window: window,
            displaySettings: resolvedDisplaySettings(for: window),
            nightMode: nightMode,
            monochromeMode: monochromeModePref,
            disableTwoStepBookmarking: disableTwoStepBookmarkingPref,
            hideWindowButtons: hideWindowButtonsPref,
            speakService: speakService,
            windowMenuReferenceStore: windowMenuReferenceStore,
            onShowBookChooser: { presentBookChooser(from: window.id) },
            onShowSearch: { presentSearch(from: window.id) },
            onShowBookmarks: { presentReaderDestination(.bookmarks, from: window.id) },
            onShowSettings: { presentSettings(from: window.id) },
            onShowWindowTextOptions: { presentWindowTextOptions(from: window.id) },
            onEditWindowTextSetting: { type in
                performWindowTextSetting(type, for: window)
            },
            onExportStudyPadArchive: { labelID in
                exportWindowMenuStudyPadArchive(labelID: labelID)
            },
            onExportStudyPadCSV: { labelID in
                exportWindowMenuStudyPadCSV(labelID: labelID)
            },
            onCopyWindowSettingsToWindow: { targetWindowID in
                presentTextSettingsCopy(from: window.id, target: .window(targetWindowID))
            },
            onCopyWindowSettingsToWorkspace: {
                presentTextSettingsCopy(from: window.id, target: .workspace)
            },
            onCopyWindowSettingsToGlobal: {
                presentTextSettingsCopy(from: window.id, target: .global)
            },
            onShowDownloads: { initialSearchText in
                presentDownloads(from: window.id, initialSearchText: initialSearchText)
            },
            onShowHistory: { presentHistoryDialog(from: window.id) },
            onShowCompare: {
                (windowManager.controllers[window.id] as? BibleReaderController)?.loadCompareDocument()
            },
            onShowReadingPlans: { presentReaderDestination(.readingPlans, from: window.id) },
            onShowReadingProgress: { tab in
                presentReadingProgress(
                    initialTab: ReadingProgressTab(androidTab: tab),
                    from: window.id
                )
            },
            onShowReadingProgressSettings: {
                presentReaderDestination(.readingProgressSettings, from: window.id)
            },
            onShowChapterReadHistory: { target in
                presentChapterReadHistoryDialog(target: target, from: window.id)
            },
            onShowSpeakControls: { presentReaderDestination(.speakControls, from: window.id) },
            onShowAIPromptEditor: { promptID in
                presentAIPromptEditor(promptID, from: window.id)
            },
            onShareText: { text in
                myDocumentSharePayload = nil
                shareText = text
            },
            onShareMyDocument: { payload in
                shareText = nil
                myDocumentSharePayload = payload
            },
            onShowModulePicker: { category in
                presentModulePicker(category, from: window.id)
            },
            onShowToast: { text in
                showReaderToast(text)
            },
            onShowWorkspaces: { presentReaderDestination(.workspaces, from: window.id) },
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
            onSearchForStrongs: { strongsNum in
                presentSearch(
                    from: window.id,
                    initialQuery: strongsNum,
                    isStrongsFindAll: true
                )
            },
            onRefChooserDialog: { completion in
                presentReferenceChooser(from: window.id, completion: completion)
            },
            onAssignLabels: { bookmarkId in
                presentReaderLabelAssignment(bookmarkId: bookmarkId, from: window.id)
            },
            onUserScrollDeltaY: { deltaY in
                handleAutoFullscreenScroll(from: window, deltaY: deltaY)
            },
            onUserHorizontalSwipe: { direction in
                handleHorizontalSwipe(from: window, direction: direction)
            }
        )
    }

    /** Captures the source pane and opens Android PromptEditActivity as a reader destination. */
    private func presentAIPromptEditor(_ promptID: UUID, from windowID: UUID) {
        setPanePresentationTarget(windowID)
        activeAIPromptEditorDestination = AIPromptEditorDestination(promptID: promptID)
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
                pendingReaderNavigationDrawerActionID = nil
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
                case .dictionary: presentReaderDestinationPreservingPane(.dictionaryBrowser)
                case .generalBook: presentReaderDestinationPreservingPane(.generalBookBrowser)
                case .map: presentReaderDestinationPreservingPane(.mapBrowser)
                case .epub: presentReaderDestinationPreservingPane(.generalBookBrowser)
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
        if controller?.isShowingAndroidMultiDocument == true {
            let summary = controller?.androidMultiDocumentHeaderSummary
            return .androidMulti(
                title: summary?.title ?? AndroidSpecialDocumentIdentity.multiDocumentInitials,
                subtitle: summary?.subtitle ?? Bundle.main.localizedString(
                    forKey: "multi_description",
                    value: "Multiple references",
                    table: nil
                )
            )
        }
        if controller?.currentCategory == .dictionary ||
            controller?.currentCategory == .generalBook ||
            controller?.currentCategory == .map ||
            controller?.currentCategory == .epub {
            let category = controller?.currentCategory ?? .dictionary
            let title = controller?.activeEpubReader?.title
                ?? controller?.activeModuleName(for: category)
                ?? ""
            return .auxiliary(
                title: title,
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
            return controller?.activeEpubReader == nil
                ? controller?.currentGeneralBookKey
                : controller?.currentEpubTitle
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
            surfacePalette: readerThemeSurfacePalette,
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
            windowPinningEnabled: windowManager.activeWorkspace?.workspaceSettings?.autoPin
                ?? WorkspaceSettings.defaultAutoPin,
            showsAIActions: isAIConfigured,
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

    /** Whether Android's workspace-level AI action should appear in the reader overflow menu. */
    private var isAIConfigured: Bool {
        guard let providers = try? AISettingsStore(modelContext: modelContext).providers() else {
            return false
        }
        return !providers.isEmpty
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
            let nextValue = !(
                windowManager.activeWorkspace?.workspaceSettings?.autoPin
                    ?? WorkspaceSettings.defaultAutoPin
            )
            windowManager.setAutoPinEnabled(nextValue)
        case .openLabelSettings:
            dismissReaderOverflowMenuAndQueue(.labelManager)
        case .openAIActions:
            let controller = focusedController
            dismissReaderOverflowMenuAndPerform {
                controller?.onRequestWorkspaceAIAction?()
            }
        case .toggleSectionTitles:
            toggleDisplaySetting(\.showSectionTitles, default: true)
        case .openStrongsMode:
            let targetWindow = windowManager.activeWindow
            dismissReaderOverflowMenuAndPerform {
                guard let targetWindow else { return }
                presentWindowTextSettingEditor(.strongs, for: targetWindow)
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
            let width = ReaderToolbarPopupPlacement.boundedWidth(
                containerWidth: proxy.size.width,
                safeAreaInsets: proxy.safeAreaInsets,
                preferredWidth: 236,
                maximumWidth: 236
            )
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
                    .offset(x: placement.offset.width, y: placement.offset.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
    }

    /// Full-screen dismiss area plus anchored Bible quick selector mirroring Android's toolbar popup.
    private func bibleQuickModuleSelectorOverlay(anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { proxy in
            let buttonRect = anchor.map { proxy[$0] }
            let targetWindowId = bibleQuickModuleSelectorTargetWindowId
            let rows = bibleQuickModuleSelectorRows
            let width = ReaderToolbarPopupPlacement.boundedWidth(
                containerWidth: proxy.size.width,
                safeAreaInsets: proxy.safeAreaInsets,
                preferredWidth: max(proxy.size.width * 0.42, 156),
                maximumWidth: 232
            )
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
                        surfacePalette: readerThemeSurfacePalette,
                        maximumHeight: placement.maximumHeight,
                        onSelect: { module in
                            selectBibleQuickModule(module, targetWindowId: targetWindowId)
                        }
                    )
                    .frame(width: width, alignment: .topLeading)
                    .offset(x: placement.offset.width, y: placement.offset.height)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
            }
        }
    }

    /// Full-screen dismiss area plus anchored commentary quick selector mirroring Android's popup.
    private func commentaryQuickModuleSelectorOverlay(anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { proxy in
            let buttonRect = anchor.map { proxy[$0] }
            let targetWindowId = commentaryQuickModuleSelectorTargetWindowId
            let rows = commentaryQuickModuleSelectorRows
            let width = ReaderToolbarPopupPlacement.boundedWidth(
                containerWidth: proxy.size.width,
                safeAreaInsets: proxy.safeAreaInsets,
                preferredWidth: max(proxy.size.width * 0.42, 156),
                maximumWidth: 232
            )
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
                    .onTapGesture { dismissCommentaryQuickSelector() }
                    .accessibilityIdentifier("readerCommentaryQuickSelectorDismissArea")

                if !rows.isEmpty {
                    BibleReaderQuickModuleSelector(
                        rows: rows,
                        colorScheme: colorScheme,
                        surfacePalette: readerThemeSurfacePalette,
                        maximumHeight: placement.maximumHeight,
                        accessibilityIdentifier: "readerCommentaryQuickSelector",
                        rowAccessibilityIdentifierPrefix: "readerCommentaryQuickSelectorRow",
                        onSelect: { module in
                            selectCommentaryQuickModule(module, targetWindowId: targetWindowId)
                        }
                    )
                    .frame(width: width, alignment: .topLeading)
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

    /// Dismisses the drawer immediately using the shared animation.
    private func dismissReaderNavigationDrawer() {
        pendingReaderNavigationDrawerActionID = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            showReaderNavigationDrawer = false
        }
    }

    /**
     Dismisses the reader drawer before presenting a destination or another transient surface.

     SwiftUI navigation must not begin while the drawer's removal transition still owns the reader
     hierarchy. Starting both animations together can leave the pushed destination partially
     presented, so the follow-up runs from the transaction's removal completion instead of a timer.

     - Parameter action: Main-actor presentation or side-effect closure to run after dismissal.
     - Side effects: Replaces any pending drawer action, hides the reader drawer, and invokes the
       newest action exactly once. When the drawer is already hidden, invokes that action
       synchronously.
     - Failure modes: A superseded action is deliberately discarded. Reduced-motion and interrupted
       animations still complete the SwiftUI transaction for the current action.
     - Important: Callers must provide UI work that is valid on the main actor.
     */
    private func dismissReaderNavigationDrawerAndPerform(_ action: @escaping () -> Void) {
        let actionID = UUID()
        pendingReaderNavigationDrawerActionID = actionID

        guard showReaderNavigationDrawer else {
            pendingReaderNavigationDrawerActionID = nil
            action()
            return
        }

        withAnimation(
            .easeInOut(duration: 0.2),
            completionCriteria: .removed
        ) {
            showReaderNavigationDrawer = false
        } completion: {
            guard pendingReaderNavigationDrawerActionID == actionID,
                  !showReaderNavigationDrawer else {
                return
            }
            pendingReaderNavigationDrawerActionID = nil
            action()
        }
    }

    /// Runs the coordinator-owned side effect for one drawer row.
    private func handleReaderNavigationDrawerAction(_ action: BibleReaderNavigationDrawerAction) {
        switch action {
        case .chooseDocument:
            dismissReaderNavigationDrawerAndPerform {
                presentReaderDestination(.chooseDocument, from: windowManager.activeWindow?.id)
            }
        case .search:
            dismissReaderNavigationDrawerAndPerform {
                presentSearch(from: windowManager.activeWindow?.id)
            }
        case .speak:
            dismissReaderNavigationDrawerAndPerform {
                speakLastUsed = Date().timeIntervalSince1970
                if speakService.isSpeaking {
                    presentReaderDestination(.speakControls, from: windowManager.activeWindow?.id)
                } else {
                    panePresentationController?.speakCurrentChapter()
                    presentReaderDestination(.speakControls, from: windowManager.activeWindow?.id)
                }
            }
        case .bookmarks:
            dismissReaderNavigationDrawerAndPerform {
                presentReaderDestination(.bookmarks, from: windowManager.activeWindow?.id)
            }
        case .studyPads:
            dismissReaderNavigationDrawerAndPerform {
                presentReaderDestination(.studyPads, from: windowManager.activeWindow?.id)
            }
        case .myNotes:
            dismissReaderNavigationDrawerAndPerform {
                presentReaderDestination(.myDocuments, from: windowManager.activeWindow?.id)
            }
        case .readingPlans:
            dismissReaderNavigationDrawerAndPerform {
                presentReaderDestination(.readingPlans, from: windowManager.activeWindow?.id)
            }
        case .readingProgress:
            dismissReaderNavigationDrawerAndPerform {
                presentReadingProgress(initialTab: nil, from: windowManager.activeWindow?.id)
            }
        case .history:
            dismissReaderNavigationDrawerAndPerform {
                presentHistoryDialog(from: windowManager.activeWindow?.id)
            }
        case .downloads:
            dismissReaderNavigationDrawerAndPerform {
                presentDownloads(from: windowManager.activeWindow?.id)
            }
        case .importExport:
            dismissReaderNavigationDrawerAndPerform {
                presentReaderDestination(.importExport, from: windowManager.activeWindow?.id)
            }
        case .syncSettings:
            dismissReaderNavigationDrawerAndPerform {
                if !presentSyncSettings() {
                    presentReaderDestination(.syncSettings, from: windowManager.activeWindow?.id)
                }
            }
        case .aiSettings:
            dismissReaderNavigationDrawerAndPerform {
                presentReaderDestination(.aiSettings, from: windowManager.activeWindow?.id)
            }
        case .settings:
            dismissReaderNavigationDrawerAndPerform {
                presentSettings(from: windowManager.activeWindow?.id)
            }
        case .help:
            dismissReaderNavigationDrawerAndPerform { presentHelpDialog() }
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
        case .appLicense:
            dismissReaderNavigationDrawerAndPerform { presentLicenseDialog() }
        case .tellFriend:
            dismissReaderNavigationDrawerAndPerform {
                shareText = String(localized: "tell_friend_message")
            }
        case .rateApp:
            dismissReaderNavigationDrawerAndPerform { presentRateReviewDialog() }
        case .reportBug:
            dismissReaderNavigationDrawerAndPerform { presentBugReportDialog() }
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
        switch StrongsMode(rawValue: displaySettings.strongsMode ?? 0) ?? .hiddenLinks {
        case .links:
            return isNT ? "ToolbarStrongsGreekLinks" : "ToolbarStrongsHebrewLinks"
        case .textAndLinks:
            return isNT ? "ToolbarStrongsGreekLinksText" : "ToolbarStrongsHebrewLinksText"
        case .hiddenLinks:
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
            surfacePalette: readerThemeSurfacePalette,
            preferredSingleAccessory: preferredSingleToolbarAccessory,
            moduleHasStrongs: moduleHasStrongs,
            strongsIconAssetName: strongsIconAssetName,
            strongsMode: displaySettings.strongsMode ?? 0,
            strongsEnabled: strongsEnabled,
            isBibleActive: controller?.currentCategory == .bible,
            isCommentaryActive: controller?.currentCategory == .commentary,
            searchEnabled: controller?.isCurrentPageSearchable == true,
            speakEnabled: controller?.isCurrentPageSpeakable == true,
            moduleActionsEnabled: controller != nil,
            onShowSearch: { presentSearch(from: windowManager.activeWindow?.id) },
            onShowSpeak: {
                speakLastUsed = Date().timeIntervalSince1970
                if speakService.isSpeaking {
                    presentReaderDestination(.speakControls, from: windowManager.activeWindow?.id)
                } else {
                    controller?.speakCurrentChapter()
                    presentReaderDestination(.speakControls, from: windowManager.activeWindow?.id)
                }
            },
            onApplyStrongsMode: { mode in applyStrongsMode(mode) },
            onShowStrongsModeDialog: {
                guard let window = windowManager.activeWindow else { return }
                presentWindowTextSettingEditor(.strongs, for: window)
            },
            onBibleTap: {
                handleBibleToolbarTap(controller)
            },
            onBibleLongPress: {
                handleBibleToolbarLongPress(controller)
            },
            onCommentaryTap: {
                handleCommentaryToolbarTap(controller)
            },
            onCommentaryLongPress: {
                handleCommentaryToolbarLongPress(controller)
            },
            onShowWorkspaces: { presentReaderDestination(.workspaces, from: windowManager.activeWindow?.id) }
        ) {
            readerOverflowToolbarButton
        }
    }

    /// Neutral toolbar tint matching Android's white/grey icon-state treatment.
    private func toolbarIconColor(isActive: Bool = true) -> Color {
        isActive
            ? readerThemeSurfacePalette.toolbarForegroundColor
            : readerThemeSurfacePalette.toolbarSecondaryForegroundColor
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

    /// Whether Strong's numbers should use Android's fully-bright toolbar state.
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
        settings.normalizeAutoAssignPrimaryLabel()
        workspace.workspaceSettings = settings
        try? modelContext.save()
    }

    /**
     Applies a Strong's display mode to the active window only and refreshes that pane.

     - Parameter mode: Raw Vue.js/config mode value (`0...2`) matching Android `strongsModeEntries`.
     - Side effects: Persists the updated Strong's mode through the window-scope settings helper,
       refreshes the active pane controller, and re-syncs focused toolbar state.
     - Failure modes: If no active window or page manager exists, the persistence helper performs
       only in-memory refreshes. SwiftData save failures are intentionally swallowed.
     */
    private func applyStrongsMode(_ mode: Int) {
        applyStrongsMode(mode, for: windowManager.activeWindow)
    }

    /**
     Applies a Strong's display mode to a specific window and refreshes that pane.

     - Parameters:
       - mode: Raw Vue.js/config mode value (`0...2`) matching Android `strongsModeEntries`.
       - window: Pane whose window-scoped settings should be changed.
     - Side effects: Persists the updated Strong's mode through the window-scope settings helper and
       refreshes the affected pane.
     - Failure modes: Missing window or page manager falls back through the persistence helper.
     */
    private func applyStrongsMode(_ mode: Int, for window: BibleCore.Window?) {
        let targetWindow = window
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
        toggleDisplaySetting(keyPath, default: defaultValue, for: windowManager.activeWindow)
    }

    /**
     Toggles one optional Boolean text-display field for a specific window.

     - Parameters:
       - keyPath: Writable `TextDisplaySettings` field to flip.
       - defaultValue: Effective fallback used when the current value is unset.
       - window: Pane whose window-scoped setting should be changed.
     - Side effects: Persists the updated field through the window-scope settings helper and
       refreshes the affected pane.
     - Failure modes: Missing window results in an in-memory refresh only.
     */
    private func toggleDisplaySetting(
        _ keyPath: WritableKeyPath<TextDisplaySettings, Bool?>,
        default defaultValue: Bool,
        for window: BibleCore.Window?
    ) {
        let targetWindow = window
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
     Executes one Android recent text-setting command against the popup's immutable target window.

     Boolean preferences toggle immediately. Android activity preferences reuse their existing
     full app-owned routes, while dialog preferences reuse the same staged editor component as All
     Text Options. Unsupported platform-divergent types fail closed rather than showing inert UI.
     */
    private func performWindowTextSetting(
        _ type: AndroidTextDisplaySettingType,
        for window: BibleCore.Window
    ) {
        guard type.isAvailableOnIOS else { return }
        switch type {
        case .colors:
            presentWindowColorSettings(from: window.id)
        case .bookmarksHideLabels:
            presentWindowHiddenLabels(from: window.id)
        default:
            if type.editorKind != nil {
                presentWindowTextSettingEditor(type, for: window)
            } else if toggleWindowTextSetting(type, for: window) {
                recordRecentTextSetting(type)
            }
        }
    }

    /** Opens Android's full Manage Labels HIDELABELS activity for one exact pane. */
    private func presentWindowHiddenLabels(from windowID: UUID) {
        let targetWindow = windowManager.allWindows.first { $0.id == windowID }
            ?? windowManager.activeWindow
        windowDisplaySettings = resolvedDisplaySettings(for: targetWindow)
        presentReaderDestination(.windowHiddenLabels, from: targetWindow?.id ?? windowID)
    }

    /** Prepares one reusable staged Android preference dialog over the target reader window. */
    private func presentWindowTextSettingEditor(
        _ type: AndroidTextDisplaySettingType,
        for window: BibleCore.Window
    ) {
        guard type.editorKind != nil else { return }
        let resolvedSettings = resolvedDisplaySettings(for: window)
        windowTextSettingEditorSettings = resolvedSettings
        windowTextSettingEditorPreviousSettings = resolvedSettings
        windowTextSettingEditorRequest = WindowTextSettingEditorRequest(
            windowID: window.id,
            type: type
        )
    }

    /** Persists one shared quick-editor terminal result back to its captured window. */
    private func finishWindowTextSettingEditor(
        _ request: WindowTextSettingEditorRequest,
        recordsRecentType: Bool
    ) {
        let targetWindow = windowManager.allWindows.first { $0.id == request.windowID }
        persistWindowDisplaySettings(
            windowTextSettingEditorSettings,
            for: targetWindow,
            previousResolvedSettings: windowTextSettingEditorPreviousSettings
        )
        if recordsRecentType {
            recordRecentTextSetting(request.type)
        }
        windowTextSettingEditorRequest = nil
    }

    /** Records Android's shared five-item text-setting history after a committed value change. */
    private func recordRecentTextSetting(_ type: AndroidTextDisplaySettingType) {
        AndroidTextDisplayRecentSettings.record(
            type,
            settingsStore: SettingsStore(modelContext: modelContext)
        )
    }

    /** Toggles every iOS-backed Boolean Android text preference through the canonical mutation path. */
    @discardableResult
    private func toggleWindowTextSetting(
        _ type: AndroidTextDisplaySettingType,
        for window: BibleCore.Window
    ) -> Bool {
        switch type {
        case .justify:
            toggleDisplaySetting(\.justifyText, default: true, for: window)
        case .hyphenation:
            toggleDisplaySetting(\.hyphenation, default: true, for: window)
        case .morphology:
            toggleDisplaySetting(\.showMorphology, default: false, for: window)
        case .footnotes:
            toggleDisplaySetting(\.showFootNotes, default: true, for: window)
        case .footnotesInline:
            toggleDisplaySetting(\.showFootNotesInline, default: false, for: window)
        case .expandXrefs:
            toggleDisplaySetting(\.expandXrefs, default: false, for: window)
        case .xrefs:
            toggleDisplaySetting(\.showXrefs, default: true, for: window)
        case .redLetters:
            toggleDisplaySetting(\.showRedLetters, default: true, for: window)
        case .sectionTitles:
            toggleDisplaySetting(\.showSectionTitles, default: true, for: window)
        case .verseNumbers:
            toggleDisplaySetting(\.showVerseNumbers, default: true, for: window)
        case .versePerLine:
            toggleDisplaySetting(\.showVersePerLine, default: false, for: window)
        case .bookmarksShow:
            toggleDisplaySetting(\.showBookmarks, default: true, for: window)
        case .myNotes:
            toggleDisplaySetting(\.showMyNotes, default: true, for: window)
        case .pageNumber:
            toggleDisplaySetting(\.showPageNumber, default: false, for: window)
        case .infiniteScroll:
            toggleDisplaySetting(\.infiniteScroll, default: true, for: window)
        case .nonStrongsWordItalic:
            toggleDisplaySetting(\.nonStrongsWordItalic, default: false, for: window)
        case .markAsReadButton:
            toggleDisplaySetting(\.showMarkAsReadButton, default: true, for: window)
        case .titleScrollButton:
            toggleDisplaySetting(\.showTitleScrollButton, default: false, for: window)
        case .memorizationIndicators:
            toggleDisplaySetting(\.showMemorizationIndicators, default: false, for: window)
        case .aiDocumentMarkers:
            toggleDisplaySetting(\.showAiDocMarkers, default: true, for: window)
        case .ordinals:
            toggleDisplaySetting(\.showOrdinals, default: false, for: window)
        default:
            return false
        }
        return true
    }

    /**
     Opens the Strong's mode chooser for a specific pane.

     - Parameter windowId: Pane whose Strong's setting should receive the selected value.
     - Side effects: Makes the pane active and opens the shared window-scoped preference editor.
     - Failure modes: Missing windows fall back to current active-window behavior.
     */
    private func presentWindowStrongsMode(from windowId: UUID) {
        let targetWindow = windowManager.allWindows.first(where: { $0.id == windowId })
            ?? windowManager.activeWindow
        if let targetWindow {
            windowManager.activateWindow(targetWindow)
            syncActiveDisplaySettings()
            presentWindowTextSettingEditor(.strongs, for: targetWindow)
        }
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
        for window: BibleCore.Window?,
        previousResolvedSettings: TextDisplaySettings
    ) {
        guard let window else {
            syncActiveDisplaySettings()
            reloadBehaviorPreferences()
            return
        }

        let parentSettings = TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: window.workspace?.textDisplaySettings ?? windowManager.activeWorkspace?.textDisplaySettings,
            global: globalDisplaySettings
        )
        guard BibleReaderWindowDisplaySettingsMutation.persist(
            editorSettings: windowSettings,
            for: window,
            parentSettings: parentSettings,
            previousResolvedSettings: previousResolvedSettings
        ) else {
            syncActiveDisplaySettings()
            reloadBehaviorPreferences()
            return
        }
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
     Applies Android's selective Copy settings dialog result.

     Android copies raw page-manager text-display values, field by field, into another window,
     workspace, or global defaults. This method mirrors that raw override behavior and then refreshes
     visible panes through the existing display-settings pipeline.

     - Parameters:
       - request: Source and target captured when the pane menu action was selected.
       - fields: Checked text-display fields from the dialog.
     - Side effects:
       - mutates the selected target scope's text-display settings
       - persists through SwiftData or `SettingsStore`
       - refreshes visible pane controllers and active toolbar state
     - Failure modes: Missing source/target windows or an empty field selection are ignored.
     */
    private func applyTextSettingsCopy(
        _ request: TextSettingsCopyRequest,
        fields: Set<TextDisplaySettingsCopyField>
    ) {
        guard !fields.isEmpty,
              let sourceWindow = windowManager.allWindows.first(where: { $0.id == request.sourceWindowID }) else {
            return
        }

        let sourceSettings = sourceWindow.pageManager?.textDisplaySettings ?? TextDisplaySettings()

        switch request.target {
        case .window(let targetWindowID):
            guard let targetWindow = windowManager.allWindows.first(where: { $0.id == targetWindowID }),
                  let targetPageManager = targetWindow.pageManager else {
                return
            }
            let targetSettings = targetPageManager.textDisplaySettings ?? TextDisplaySettings()
            targetPageManager.textDisplaySettings = targetSettings.copyingSelectedFields(
                from: sourceSettings,
                fields: fields
            )
            try? modelContext.save()
        case .workspace:
            let targetWorkspace = sourceWindow.workspace ?? windowManager.activeWorkspace
            guard let targetWorkspace else { return }
            let targetSettings = targetWorkspace.textDisplaySettings ?? TextDisplaySettings()
            targetWorkspace.textDisplaySettings = targetSettings.copyingSelectedFields(
                from: sourceSettings,
                fields: fields
            )
            try? modelContext.save()
        case .global:
            let store = SettingsStore(modelContext: modelContext)
            let targetSettings = globalDisplaySettings.copyingSelectedFields(
                from: sourceSettings,
                fields: fields
            )
            globalDisplaySettings = targetSettings
            store.setGlobalTextDisplaySettings(targetSettings)
        }

        refreshVisibleControllerDisplaySettings()
        syncActiveDisplaySettings()
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
    private func resolvedDisplaySettings(for window: BibleCore.Window?) -> TextDisplaySettings {
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
        workspaceChromeColor = ReaderWorkspaceChromeColor.resolved(
            activeWindow: windowManager.activeWindow,
            activeWorkspace: windowManager.activeWorkspace
        )
        workspaceDisplaySettings = resolvedWorkspaceDisplaySettings(
            for: panePresentationTargetWindow?.workspace ?? windowManager.activeWorkspace
        )
        windowDisplaySettings = resolvedDisplaySettings(for: panePresentationTargetWindow ?? windowManager.activeWindow)
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
            performCommentaryMenuAction(controller, includeAuxiliaryDocuments: false)
        case .defaultMode, .swapActivity:
            performCommentaryChooserAction()
        }
    }

    /**
     Handles the Android `menuForDocs` Bible action.

     When exactly two readable Bible modules are installed, this mirrors Android's auto-cycle
     shortcut over `SwordDocumentFacade.unlockedBibles`. Every other non-empty readable list shows
     the compact anchored popup; the full document picker remains inclusive so locked rows can use
     its passphrase workflow.

     - Parameter controller: Focused pane controller, if one is currently registered.
     */
    private func performBibleMenuAction(_ controller: BibleReaderController?) {
        guard let controller else { return }
        switch BibleReaderQuickModuleSelectorPresentation.action(
            for: controller.readableBibleModules,
            activeModuleName: currentBibleQuickSelectorModuleName(for: controller)
        ) {
        case .none:
            return
        case .switchDirectly(let row):
            controller.switchBibleDocument(to: row.module.name)
        case .showPopup(let rows):
            presentBibleQuickSelector(controller, rows: rows)
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
     Cycles to the next readable Bible module or switches back into Bible mode.

     - Parameter controller: Focused pane controller, if one is currently registered.
     - Side effects: Reads fresh native module access state and switches through the shared
       controller preflight when a readable candidate exists.
     - Failure modes: Locked-only inventories perform no switch; their inclusive rows remain in the
       full picker for the existing unlock workflow.
     */
    private func performBibleNextDocumentAction(_ controller: BibleReaderController?) {
        guard let controller else { return }
        if controller.currentCategory != .bible {
            guard let moduleName = suggestedBibleDocumentName(for: controller) else { return }
            controller.switchBibleDocument(to: moduleName)
            return
        }
        cycleToNextModule(
            modules: controller.readableBibleModules,
            activeName: controller.activeModuleName
        ) { nextName in
            controller.switchBibleDocument(to: nextName)
        }
    }

    /**
     Handles the Android `menuForDocs` commentary action.

     When exactly two documents are available, this mirrors Android's auto-cycle shortcut. Every
     other non-empty module list shows the compact anchored popup instead of the full document
     picker sheet.

     - Parameters:
       - controller: Focused pane controller, if one is currently registered.
       - includeAuxiliaryDocuments: Whether to include Android's default general-book and dictionary
         candidates in addition to commentaries.
     */
    private func performCommentaryMenuAction(
        _ controller: BibleReaderController?,
        includeAuxiliaryDocuments: Bool = true
    ) {
        guard let controller else { return }
        let modules = commentaryQuickSelectorModules(
            controller,
            includeAuxiliaryDocuments: includeAuxiliaryDocuments
        )
        switch BibleReaderQuickModuleSelectorPresentation.action(
            for: modules,
            activeModuleName: currentCommentaryQuickSelectorModuleName(for: controller)
        ) {
        case .none:
            return
        case .switchDirectly(let row):
            let targetWindowId = windowManager.controllers.first { _, registeredController in
                (registeredController as? BibleReaderController) === controller
            }?.key ?? windowManager.activeWindow?.id
            selectCommentaryQuickModule(row.module, targetWindowId: targetWindowId)
        case .showPopup(let rows):
            presentCommentaryQuickSelector(controller, rows: rows)
        }
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
            if let moduleName = controller.activeCommentaryModuleName {
                controller.switchCommentaryDocument(to: moduleName)
            } else {
                performCommentaryChooserAction()
            }
            return
        }
        cycleToNextModule(
            modules: controller.installedCommentaryModules,
            activeName: controller.activeCommentaryModuleName
        ) { nextName in
            controller.switchCommentaryDocument(to: nextName)
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
        monochromeModePref = store.getBool(.monochromeMode)
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
    private func handleAutoFullscreenScroll(from window: BibleCore.Window, deltaY: Double) {
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
       client reports an open modal, the rendered document blocks host page navigation, or the
       configured swipe mode is `.none`.
     */
    private func handleHorizontalSwipe(
        from window: BibleCore.Window,
        direction: NativeHorizontalSwipeDirection
    ) {
        guard windowManager.activeWindow?.id == window.id else { return }
        guard let ctrl = windowManager.controllers[window.id] as? BibleReaderController else { return }
        switch ReaderHorizontalSwipePolicy.action(
            modeRawValue: bibleViewSwipeMode,
            direction: direction,
            hasActiveSelection: ctrl.hasActiveSelection,
            hasOpenModal: ctrl.webModalIsOpen,
            allowsDocumentNavigation: ctrl.allowsHorizontalDocumentNavigation
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

     - Parameters:
       - windowId: Reader pane that should own Search navigation and module context.
       - initialQuery: Optional text used to seed Search before presentation.
       - isStrongsFindAll: Whether Search must use Android's Strong's-only persisted selection.

     Side effects:
     - mutates `searchInitialQuery` so the Search destination can seed its query field from the latest caller
     - mutates `searchIsStrongsFindAll` so normal and Strong's searches cannot share selections
     - schedules the `.search` destination for the next main-actor turn so the staged query wins over
       the current render pass

     Failure modes:
     - uses an asynchronous handoff, so callers should not assume Search is visible until the
       next render pass completes
     */
    @MainActor
    private func presentSearch(
        from windowId: UUID? = nil,
        initialQuery: String? = nil,
        isStrongsFindAll: Bool = false
    ) {
        setPanePresentationTarget(windowId)
        searchLastUsed = Date().timeIntervalSince1970
        if panePresentationController?.currentCategory == .generalBook,
           panePresentationController?.activeEpubReader != nil {
            presentReaderDestination(.epubSearch, from: windowId)
            return
        }
        searchIsStrongsFindAll = isStrongsFindAll
        if let initialQuery {
            searchInitialQuery = initialQuery
        } else if let uiTestQuery = UITestSearchQuerySeed.consume() {
            searchInitialQuery = uiTestQuery
        } else {
            searchInitialQuery = ""
        }
        Task { @MainActor in
            await Task.yield()
            activeReaderDestination = .search
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

    /// Palette inherited from the captured reader pane's application-owned surface.
    let surfacePalette: ReaderThemeSurfacePalette

    /// Dismisses the owning reader destination when the user leaves the readiness state.
    let onDismiss: () -> Void

    /**
     Builds the app-owned activity surface for a pane that is pending or no longer available.

     - Returns: Shared Android activity chrome with either the common loading indicator or empty
       state on the captured reader palette.
     - Side Effects: The app-bar Up action calls `onDismiss`.
     - Failure Modes: None; this view is intentionally static until parent state changes.
     */
    var body: some View {
        AndroidActivityScreen(
            title: String(localized: "choose_document", defaultValue: "Choose Document"),
            accessibilityIdentifier: "readerPanePreparation",
            palette: surfacePalette,
            onBack: onDismiss,
            actions: { EmptyView() }
        ) {
            if isPending {
                AndroidActivityLoadingView(
                    message: message,
                    palette: surfacePalette,
                    accessibilityIdentifier: "readerPanePreparationLoading"
                )
            } else {
                AndroidActivityEmptyListView(
                    title: title,
                    detail: message,
                    palette: surfacePalette,
                    accessibilityIdentifier: "readerPanePreparationUnavailable"
                )
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

 Vue.js config values: hidden links=`0`, links=`1`, text and links=`2`.
 */
enum StrongsMode: Int, CaseIterable, Identifiable {
    /// Keep Strong's links tappable while hiding visible markers/underlines.
    case hiddenLinks = 0

    /// Render words as tappable underlined Strong's links.
    case links = 1

    /// Render Strong's text next to linked words.
    case textAndLinks = 2

    /// Stable raw-value identifier for `ForEach` and menu construction.
    var id: Int { rawValue }

    /// Localized label shown in the Strong's display-mode menu.
    var label: String {
        switch self {
        case .hiddenLinks: String(localized: "strongs_hidden")
        case .links: String(localized: "strongs_links")
        case .textAndLinks: String(localized: "strongs_inline")
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
