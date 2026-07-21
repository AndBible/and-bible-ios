import BibleCore
import Foundation

/**
 Projects reader configuration and window-state inputs into Android-compatible Vue bridge payloads.

 The coordinator owns the fallback hidden-compare set used before a controller is attached to a
 persisted workspace, computes active-window state from `WindowManager`, and builds the typed
 `set_config` payload consumed by bibleview-js. Keeping these rules outside
 `BibleReaderController` prevents window/workspace state projection from being duplicated across
 content reload, settings reload, and compare-toggle paths.

 - Side effects: Mutates workspace settings only through `persistHiddenCompareDocuments` and
   `toggleHiddenCompareDocument`; all payload-building methods are side-effect free.
 - Failure modes: JSON encoding returns `nil` if the typed payload unexpectedly stops being
   encodable. Missing workspace/window inputs fall back to controller-local hidden compare state and
   the existing iOS startup active-window defaults.
 */
struct BibleReaderConfigurationCoordinator {
    /// Controller-local hidden compare fallback used when no workspace settings are available.
    private var fallbackHiddenCompareDocuments: Set<String>

    /**
     Creates a coordinator with optional preloaded hidden compare state.

     - Parameter fallbackHiddenCompareDocuments: Initial controller-local hidden compare modules.
     - Side effects: None.
     - Failure modes: None.
     */
    init(fallbackHiddenCompareDocuments: Set<String> = []) {
        self.fallbackHiddenCompareDocuments = fallbackHiddenCompareDocuments
    }

    /**
     Computes the active-pane projection sent to Vue.

     Android treats a pane as active when `windowControl.activeWindow.id == window.id`; before iOS has
     both a `Window` and `WindowManager`, existing bridge behavior treats the pane as active while
     suppressing the active indicator unless there are multiple known visible windows.

     - Parameters:
       - activeWindow: Window owned by the controller being projected.
       - windowManager: Manager that owns the focused window and visible-window list.
       - activeIndicatorEnabled: Resolved app preference for showing the active pane indicator.
     - Returns: The active-state flags and preformatted `set_active` event JSON.
     - Side effects: None.
     - Failure modes: Missing window or manager falls back to active state to preserve startup/test
       behavior from `BibleReaderController.computeIsActiveWindow()`.
     */
    func activeWindowState(
        activeWindow: Window?,
        windowManager: WindowManager?,
        activeIndicatorEnabled: Bool
    ) -> BibleReaderActiveWindowState {
        let isActive: Bool
        if let activeWindow, let windowManager {
            isActive = windowManager.activeWindow?.id == activeWindow.id
        } else {
            isActive = true
        }

        let visibleWindowCount = windowManager?.visibleWindows.count ?? 0
        return BibleReaderActiveWindowState(
            isActive: isActive,
            hasActiveIndicator: activeIndicatorEnabled && isActive && visibleWindowCount > 1
        )
    }

    /**
     Resolves the hidden compare-document set for the current pane.

     - Parameter activeWindow: Optional persisted window whose workspace may own the durable setting.
     - Returns: Workspace-owned hidden module initials when available; otherwise the coordinator's
       controller-local fallback set.
     - Side effects: None.
     - Failure modes: Missing workspace settings are treated as an empty/fallback set.
     */
    func hiddenCompareDocuments(activeWindow: Window?) -> Set<String> {
        if let workspaceDocuments = activeWindow?.workspace?.workspaceSettings?.hideCompareDocuments {
            return workspaceDocuments
        }
        return fallbackHiddenCompareDocuments
    }

    /**
     Toggles one hidden compare document and persists the resulting set.

     - Parameters:
       - documentId: Module initials shown or hidden in compare output.
       - activeWindow: Optional persisted window whose workspace should own the durable setting.
       - persist: Callback used by the controller to save SwiftData after workspace mutation.
     - Returns: The updated hidden compare set.
     - Side effects: Updates the fallback cache. When a workspace is attached, mutates
       `WorkspaceSettings.hideCompareDocuments`, normalizes auto-assignment settings, and invokes
       `persist` once.
     - Failure modes: Missing workspace mutates only the fallback cache and does not call `persist`.
     */
    @discardableResult
    mutating func toggleHiddenCompareDocument(
        _ documentId: String,
        activeWindow: Window?,
        persist: () -> Void
    ) -> Set<String> {
        var documents = hiddenCompareDocuments(activeWindow: activeWindow)
        if documents.contains(documentId) {
            documents.remove(documentId)
        } else {
            documents.insert(documentId)
        }
        persistHiddenCompareDocuments(documents, activeWindow: activeWindow, persist: persist)
        return documents
    }

    /**
     Persists hidden compare module state to workspace settings when possible.

     - Parameters:
       - documents: Module initials hidden from Vue compare output.
       - activeWindow: Optional persisted window whose workspace owns durable compare settings.
       - persist: Callback used by the controller to save SwiftData after workspace mutation.
     - Side effects: Always updates the fallback cache. When a workspace is attached, updates
       `WorkspaceSettings.hideCompareDocuments`, normalizes label assignment state, and invokes
       `persist`.
     - Failure modes: Missing workspace exits after updating fallback state.
     */
    mutating func persistHiddenCompareDocuments(
        _ documents: Set<String>,
        activeWindow: Window?,
        persist: () -> Void
    ) {
        fallbackHiddenCompareDocuments = documents
        guard let workspace = activeWindow?.workspace else { return }

        var settings = workspace.workspaceSettings ?? WorkspaceSettings()
        settings.hideCompareDocuments = documents
        settings.normalizeAutoAssignPrimaryLabel()
        workspace.workspaceSettings = settings
        persist()
    }

    /**
     Builds the typed reader configuration payload consumed by Vue.

     - Parameter context: Fully resolved controller inputs collected at emission time.
     - Returns: The bridge payload for the existing `set_config` `{ config, appSettings, initial }`
       envelope.
     - Side effects: None.
     - Failure modes: None; unset display values fall back through `TextDisplaySettings.appDefaults`
       and the same literal defaults used before extraction.
     */
    func configPayload(context: BibleReaderConfigurationContext) -> BibleReaderSetConfigPayload {
        BibleReaderSetConfigPayload(
            config: BibleReaderDisplayConfig(settings: context.displaySettings, defaults: context.defaults),
            appSettings: BibleReaderAppSettings(context: context),
            initial: false
        )
    }

    /**
     Encodes the current reader configuration payload as JSON for `BibleBridge.emit`.

     - Parameter context: Fully resolved controller inputs collected at emission time.
     - Returns: UTF-8 JSON string, or `nil` if encoding unexpectedly fails.
     - Side effects: None.
     - Failure modes: Returns `nil` instead of emitting malformed JSON.
     */
    func configJSON(context: BibleReaderConfigurationContext) -> String? {
        let payload = configPayload(context: context)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/**
 Active-window state projected to Vue bridge payloads.

 - `isActive` mirrors Android's focused-window comparison.
 - `hasActiveIndicator` additionally requires the active-indicator preference and more than one
   visible window.
 */
struct BibleReaderActiveWindowState: Equatable {
    /// Whether the controller's pane is currently the focused window.
    let isActive: Bool
    /// Whether Vue should render the active-pane indicator decoration.
    let hasActiveIndicator: Bool

    /**
     Preformatted payload for the `set_active` bridge event.

     - Returns: Stable JSON matching the prior controller string shape and key order.
     - Side effects: None.
     - Failure modes: None.
     */
    var eventJSON: String {
        "{\"hasActiveIndicator\":\(hasActiveIndicator),\"isActive\":\(isActive)}"
    }
}

/**
 Fully resolved inputs needed to build one `set_config` payload.

 The controller owns live services and preferences; this context snapshots their primitive values so
 the coordinator can project the Vue contract without reaching back into controller state.
 */
struct BibleReaderConfigurationContext {
    /// Window/workspace/global-resolved text display settings for the pane.
    let displaySettings: TextDisplaySettings
    /// App-level fallback text display settings.
    let defaults: TextDisplaySettings
    /// Resolved reader night-mode flag.
    let nightMode: Bool
    /// Resolved error-box app preference.
    let errorBox: Bool
    /// Favourite bookmark label IDs encoded for Vue.
    let favouriteLabelIds: [String]
    /// Recently used bookmark label IDs encoded for Vue.
    let recentLabelIds: [String]
    /// Workspace StudyPad cursor positions keyed by label ID.
    let studyPadCursors: [UUID: Int]
    /// Workspace auto-assigned bookmark label IDs.
    let autoAssignLabelIds: Set<UUID>
    /// Compare document initials hidden in Vue compare output.
    let hiddenCompareDocuments: Set<String>
    /// Current active-window projection for this pane.
    let activeWindowState: BibleReaderActiveWindowState
    /// Disabled Bible bookmark modal button identifiers.
    let disableBibleModalButtons: [String]
    /// Disabled generic bookmark modal button identifiers.
    let disableGenericModalButtons: [String]
    /// Resolved monochrome-mode app preference.
    let monochromeMode: Bool
    /// Resolved animation disabling app preference.
    let disableAnimations: Bool
    /// Resolved click-to-edit disabling app preference.
    let disableClickToEdit: Bool
    /// Android-normalized notes content type used by new note rows.
    let notesContentType: String
    /// Font size multiplier in Vue's decimal format.
    let fontSizeMultiplier: Double
    /// Enabled experimental feature identifiers.
    let enabledExperimentalFeatures: [String]
    /// Whether at least one provider row satisfies Android's AI-action visibility prerequisite.
    let llmConfigured: Bool
    /// Whether reading progress should auto-track chapter reads.
    let autoTrackReading: Bool
    /// Memorization/reading progress settings bundle sent beside app settings.
    let readingProgressSettings: ReadingProgressSettingsBundle

    /**
     Creates one immutable snapshot of the reader's complete Vue configuration inputs.

     - Parameters:
       - displaySettings: Resolved pane display settings.
       - defaults: App-level display fallbacks.
       - nightMode: Current reader night-mode state.
       - errorBox: Whether Vue error diagnostics are visible.
       - favouriteLabelIds: Favourite label identities.
       - recentLabelIds: Recently used label identities.
       - studyPadCursors: Workspace StudyPad positions.
       - autoAssignLabelIds: Workspace auto-assigned label identities.
       - hiddenCompareDocuments: Compare modules hidden in this workspace.
       - activeWindowState: Current pane focus projection.
       - disableBibleModalButtons: Disabled Bible selection actions.
       - disableGenericModalButtons: Disabled generic selection actions.
       - monochromeMode: Current monochrome display state.
       - disableAnimations: Current reduced-motion setting.
       - disableClickToEdit: Whether click-to-edit is suppressed.
       - notesContentType: Android-normalized note content type.
       - fontSizeMultiplier: Vue font scaling factor.
       - enabledExperimentalFeatures: Enabled feature identifiers.
       - llmConfigured: Whether Android's provider-row prerequisite is met; defaults to fail-closed.
       - autoTrackReading: Whether chapter reading is tracked automatically.
       - readingProgressSettings: Memorization and reading-progress configuration.
     - Side effects: None.
     - Failure modes: None; callers that do not yet project AI readiness receive `false`.
     */
    init(
        displaySettings: TextDisplaySettings,
        defaults: TextDisplaySettings,
        nightMode: Bool,
        errorBox: Bool,
        favouriteLabelIds: [String],
        recentLabelIds: [String],
        studyPadCursors: [UUID: Int],
        autoAssignLabelIds: Set<UUID>,
        hiddenCompareDocuments: Set<String>,
        activeWindowState: BibleReaderActiveWindowState,
        disableBibleModalButtons: [String],
        disableGenericModalButtons: [String],
        monochromeMode: Bool,
        disableAnimations: Bool,
        disableClickToEdit: Bool,
        notesContentType: String,
        fontSizeMultiplier: Double,
        enabledExperimentalFeatures: [String],
        llmConfigured: Bool = false,
        autoTrackReading: Bool,
        readingProgressSettings: ReadingProgressSettingsBundle
    ) {
        self.displaySettings = displaySettings
        self.defaults = defaults
        self.nightMode = nightMode
        self.errorBox = errorBox
        self.favouriteLabelIds = favouriteLabelIds
        self.recentLabelIds = recentLabelIds
        self.studyPadCursors = studyPadCursors
        self.autoAssignLabelIds = autoAssignLabelIds
        self.hiddenCompareDocuments = hiddenCompareDocuments
        self.activeWindowState = activeWindowState
        self.disableBibleModalButtons = disableBibleModalButtons
        self.disableGenericModalButtons = disableGenericModalButtons
        self.monochromeMode = monochromeMode
        self.disableAnimations = disableAnimations
        self.disableClickToEdit = disableClickToEdit
        self.notesContentType = notesContentType
        self.fontSizeMultiplier = fontSizeMultiplier
        self.enabledExperimentalFeatures = enabledExperimentalFeatures
        self.llmConfigured = llmConfigured
        self.autoTrackReading = autoTrackReading
        self.readingProgressSettings = readingProgressSettings
    }
}

/**
 Wire payload for the Vue.js `set_config` event.

 The shape preserves the current `bibleView.emit('set_config', { config, appSettings, initial })`
 envelope: a fully resolved text-display config, native app settings needed by the web reader, and an
 initial-load marker. Individual app-setting parity gaps remain tracked by #146.
 */
struct BibleReaderSetConfigPayload: Encodable, Equatable {
    /// Fully resolved reader display settings consumed by the Vue text renderer.
    let config: BibleReaderDisplayConfig
    /// Application/runtime settings consumed by Vue components outside text rendering.
    let appSettings: BibleReaderAppSettings
    /// Whether this config is sent as part of first WebView attachment.
    let initial: Bool
}

/**
 Text-display configuration sent to the Vue reader.

 - Parameters:
   - settings: Window/workspace/global-resolved settings currently active for the pane.
   - defaults: App-level fallback values for unset fields.
 - Side effects: None.
 - Failure modes: None; unset settings fall back through `defaults` and Android-compatible bridge
   defaults preserved for missing persisted data.
 */
struct BibleReaderDisplayConfig: Encodable, Equatable {
    let developmentMode: Bool
    let testMode: Bool
    let showAnnotations: Bool
    let showChapterNumbers: Bool
    let showVerseNumbers: Bool
    let strongsMode: Int
    let showMorphology: Bool
    let showRedLetters: Bool
    let showVersePerLine: Bool
    let showNonCanonical: Bool
    let makeNonCanonicalItalic: Bool
    let showSectionTitles: Bool
    let showStrongsSeparately: Bool
    let showFootNotes: Bool
    let showFootNotesInline: Bool
    let showXrefs: Bool
    let expandXrefs: Bool
    let fontFamily: String
    let fontSize: Int
    let disableBookmarking: Bool
    let showBookmarks: Bool
    let showMyNotes: Bool
    let bookmarksHideLabels: [String]
    let bookmarksAssignLabels: [String]
    let colors: BibleReaderDisplayColors
    let hyphenation: Bool
    let lineSpacing: Int
    let justifyText: Bool
    let marginSize: BibleReaderDisplayMarginSize
    let topMargin: Int
    let showPageNumber: Bool
    let infiniteScroll: Bool
    let nonStrongsWordItalic: Bool
    let showMarkAsReadButton: Bool
    let showTitleScrollButton: Bool
    let showMemorizationIndicators: Bool
    let showAiDocMarkers: Bool
    let pageScrollAmount: Int
    let showOrdinals: Bool

    init(settings s: TextDisplaySettings, defaults d: TextDisplaySettings) {
        self.developmentMode = false
        self.testMode = false
        self.showAnnotations = true
        self.showChapterNumbers = true
        self.showVerseNumbers = s.showVerseNumbers ?? d.showVerseNumbers ?? true
        let rawStrongsMode = s.strongsMode ?? d.strongsMode ?? 0
        self.strongsMode = StrongsMode(rawValue: rawStrongsMode)?.rawValue ?? StrongsMode.hiddenLinks.rawValue
        self.showMorphology = s.showMorphology ?? d.showMorphology ?? false
        self.showRedLetters = s.showRedLetters ?? d.showRedLetters ?? true
        self.showVersePerLine = s.showVersePerLine ?? d.showVersePerLine ?? false
        self.showNonCanonical = true
        self.makeNonCanonicalItalic = true
        self.showSectionTitles = s.showSectionTitles ?? d.showSectionTitles ?? true
        self.showStrongsSeparately = false
        self.showFootNotes = s.showFootNotes ?? d.showFootNotes ?? false
        self.showFootNotesInline = s.showFootNotesInline ?? d.showFootNotesInline ?? false
        self.showXrefs = s.showXrefs ?? d.showXrefs ?? false
        self.expandXrefs = s.expandXrefs ?? d.expandXrefs ?? false
        self.fontFamily = s.fontFamily ?? d.fontFamily ?? "sans-serif"
        self.fontSize = s.fontSize ?? d.fontSize ?? 18
        self.disableBookmarking = false
        self.showBookmarks = s.showBookmarks ?? d.showBookmarks ?? true
        self.showMyNotes = s.showMyNotes ?? d.showMyNotes ?? true
        self.bookmarksHideLabels = (s.bookmarksHideLabels ?? d.bookmarksHideLabels ?? []).map(\.uuidString)
        self.bookmarksAssignLabels = []
        self.colors = BibleReaderDisplayColors(settings: s, defaults: d)
        self.hyphenation = s.hyphenation ?? d.hyphenation ?? true
        self.lineSpacing = s.lineSpacing ?? d.lineSpacing ?? 10
        self.justifyText = s.justifyText ?? d.justifyText ?? false
        self.marginSize = BibleReaderDisplayMarginSize(settings: s, defaults: d)
        self.topMargin = s.topMargin ?? d.topMargin ?? 0
        self.showPageNumber = s.showPageNumber ?? d.showPageNumber ?? false
        self.infiniteScroll = s.infiniteScroll ?? d.infiniteScroll ?? true
        self.nonStrongsWordItalic = s.nonStrongsWordItalic ?? d.nonStrongsWordItalic ?? false
        self.showMarkAsReadButton = s.showMarkAsReadButton ?? d.showMarkAsReadButton ?? true
        self.showTitleScrollButton = s.showTitleScrollButton ?? d.showTitleScrollButton ?? false
        self.showMemorizationIndicators = s.showMemorizationIndicators ?? d.showMemorizationIndicators ?? false
        self.showAiDocMarkers = s.showAiDocMarkers ?? d.showAiDocMarkers ?? true
        self.pageScrollAmount = TextDisplaySettings.normalizedPageScrollAmount(s.pageScrollAmount ?? d.pageScrollAmount)
        self.showOrdinals = s.showOrdinals ?? d.showOrdinals ?? false
    }
}

/**
 Color sub-object inside the Vue reader `config` payload.

 - Side effects: None.
 - Failure modes: None; every field falls back to the bridge defaults preserved from the controller.
 */
struct BibleReaderDisplayColors: Encodable, Equatable {
    let dayBackground: Int
    let dayNoise: Int
    let nightBackground: Int
    let nightNoise: Int
    let dayTextColor: Int
    let nightTextColor: Int

    init(settings s: TextDisplaySettings, defaults d: TextDisplaySettings) {
        self.dayBackground = s.dayBackground ?? d.dayBackground ?? -1
        self.dayNoise = s.dayNoise ?? d.dayNoise ?? 0
        self.nightBackground = s.nightBackground ?? d.nightBackground ?? -16777216
        self.nightNoise = s.nightNoise ?? d.nightNoise ?? 0
        self.dayTextColor = s.dayTextColor ?? d.dayTextColor ?? -16777216
        self.nightTextColor = s.nightTextColor ?? d.nightTextColor ?? -1
    }
}

/**
 Margin sub-object inside the Vue reader `config` payload.

 - Side effects: None.
 - Failure modes: None; every field falls back through app defaults and then Android's
   `WorkspaceEntities.kt` text-display baseline (`3`, `3`, `170`) when persisted data is absent.
 */
struct BibleReaderDisplayMarginSize: Encodable, Equatable {
    let marginLeft: Int
    let marginRight: Int
    let maxWidth: Int

    init(settings s: TextDisplaySettings, defaults d: TextDisplaySettings) {
        let appDefaults = TextDisplaySettings.appDefaults
        self.marginLeft = s.marginLeft ?? d.marginLeft ?? appDefaults.marginLeft ?? 3
        self.marginRight = s.marginRight ?? d.marginRight ?? appDefaults.marginRight ?? 3
        self.maxWidth = s.maxWidth ?? d.maxWidth ?? appDefaults.maxWidth ?? 170
    }
}

/**
 Native app settings included in the Vue reader `set_config` payload.

 These values are not part of `TextDisplaySettings` on Android, but Android sends them beside
 `config` in the same `set_config` event.
 */
struct BibleReaderAppSettings: Encodable, Equatable {
    let nightMode: Bool
    let errorBox: Bool
    let favouriteLabels: [String]
    let recentLabels: [String]
    let studyPadCursors: [String: Int]
    let autoAssignLabels: [String]
    let hideCompareDocuments: [String]
    let activeWindow: Bool
    let rightToLeft: Bool
    let actionMode: Bool
    let hasActiveIndicator: Bool
    let activeSince: Int
    let limitAmbiguousModalSize: Bool
    let windowId: String
    let disableBibleModalButtons: [String]
    let disableGenericModalButtons: [String]
    let monochromeMode: Bool
    let disableAnimations: Bool
    let disableClickToEdit: Bool
    let notesContentType: String
    let fontSizeMultiplier: Double
    let enabledExperimentalFeatures: [String]
    /// Whether Vue should expose Android's AI selection actions.
    let llmConfigured: Bool
    /// Native-localized Android AI action label consumed by the Vue selection menu.
    let llmActionLabel: String
    let autoTrackReading: Bool
    let readingProgressSettings: ReadingProgressSettingsBundle

    /**
     Projects one immutable native reader snapshot into Vue's Android-compatible app settings.

     - Parameter context: Fully resolved native values for the current reader pane. AI readiness must
       represent provider-row existence, matching Android's `CommonUtils.settings.llmConfigured`.
     - Side effects: Resolves the localized AI action label from the current process locale and reads
       the current clock for Android's active-window timestamp. It performs no persistence or I/O.
     - Failure modes: Localization falls back to the supplied English value. All other inputs are
       already concrete and cannot fail during projection.
     - Note: The projection is deterministic except for `activeSince`, which preserves the existing
       current-time behavior and is unrelated to AI action visibility.
     */
    init(context: BibleReaderConfigurationContext) {
        self.nightMode = context.nightMode
        self.errorBox = context.errorBox
        self.favouriteLabels = context.favouriteLabelIds
        self.recentLabels = context.recentLabelIds
        self.studyPadCursors = Dictionary(
            uniqueKeysWithValues: context.studyPadCursors.map { ($0.key.uuidString, $0.value) }
        )
        self.autoAssignLabels = context.autoAssignLabelIds.map(\.uuidString)
        self.hideCompareDocuments = context.hiddenCompareDocuments.sorted()
        self.activeWindow = context.activeWindowState.isActive
        self.rightToLeft = false
        self.actionMode = false
        self.hasActiveIndicator = context.activeWindowState.hasActiveIndicator
        self.activeSince = Int(Date().timeIntervalSince1970 * 1000) - 1000
        self.limitAmbiguousModalSize = false
        self.windowId = ""
        self.disableBibleModalButtons = context.disableBibleModalButtons
        self.disableGenericModalButtons = context.disableGenericModalButtons
        self.monochromeMode = context.monochromeMode
        self.disableAnimations = context.disableAnimations
        self.disableClickToEdit = context.disableClickToEdit
        self.notesContentType = context.notesContentType
        self.fontSizeMultiplier = context.fontSizeMultiplier
        self.enabledExperimentalFeatures = context.enabledExperimentalFeatures
        self.llmConfigured = context.llmConfigured
        self.llmActionLabel = String(localized: "llm_actions", defaultValue: "AI actions")
        self.autoTrackReading = context.autoTrackReading
        self.readingProgressSettings = context.readingProgressSettings
    }
}
