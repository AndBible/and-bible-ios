// TextDisplaySettingsView.swift — Text display settings

import SwiftUI
import BibleCore
import SwiftData

/**
 One Android `FontDefinition` row exposed by the text-display font-family dialog.

 Android builds this list from add-on fonts followed by fixed platform family names in
 `FontSizeWidget.kt`. iOS currently has no Android add-on font provider, so the built-in rows are
 the durable parity contract. `androidIndex` is part of the identity because Android's source list
 intentionally contains a duplicated `sans-serif-condensed` value and Spinner selection resolves the
 first matching value after updates.

 - Note: This type is value-only and has no file, database, or UI side effects.
 */
struct TextDisplayFontFamilyOption: Equatable, Identifiable, Sendable {
    /// Android list position used for stable identity even when values are duplicated.
    let androidIndex: Int

    /// User-visible label produced from Android's `FontDefinition.name` convention.
    let label: String

    /// Stored `TextDisplaySettings.fontFamily` value written by Android's `realFontFamily`.
    let value: String

    /// Stable SwiftUI identity for list rendering.
    var id: String { "\(androidIndex)::\(value)" }
}

/**
 Non-switch text-display editor kinds that Android opens through dialogs.

 Each case maps to one `TextDisplaySettings.Types` preference whose Android implementation stages
 local dialog state and applies changes only from OK or Reset. The enum is shared by tests and UI so
 source-level route checks and mutation tests exercise the same behavioral contract.
 */
enum TextDisplayPreferenceEditorKind: String, Identifiable, Sendable {
    /// Android `STRONGS` single-choice editor.
    case strongsMode

    /// Android `FONTSIZE` numeric editor.
    case fontSize

    /// Android `FONTFAMILY` spinner editor.
    case fontFamily

    /// Android `MARGINSIZE` multi-field numeric editor.
    case margins

    /// Android `TOPMARGIN` numeric editor.
    case topMargin

    /// Android `LINE_SPACING` numeric editor.
    case lineSpacing

    /// Android `PAGE_SCROLL_AMOUNT` single-choice editor.
    case pageScrollAmount

    /// Stable identity for SwiftUI overlay presentation.
    var id: String { rawValue }
}

/**
 Draft state for Android-style text-display preference dialogs.

 Android widgets keep mutable values inside the dialog view and commit through the positive button;
 cancelling closes the dialog without writing settings. This value mirrors that contract for iOS by
 separating temporary editor values from the bound `TextDisplaySettings` model until `commit` or
 `reset` is invoked.

 - Important: `reset` follows Android's scope ownership: global settings receive concrete app
   defaults, while workspace/window settings become `nil` so parent inheritance can resolve them.
 - Note: This type performs no persistence and is deterministic for a given input settings value.
 */
struct TextDisplayPreferenceEditorDraft: Equatable, Sendable {
    /// Draft Strong's mode value.
    var strongsMode: Int?

    /// Draft font-size value in points.
    var fontSize: Int?

    /// Draft Android font-family value.
    var fontFamily: String?

    /// Draft left margin in millimeters.
    var marginLeft: Int?

    /// Draft right margin in millimeters.
    var marginRight: Int?

    /// Draft maximum text width in millimeters.
    var maxWidth: Int?

    /// Draft top margin in millimeters.
    var topMargin: Int?

    /// Draft line-spacing value in Android tenths.
    var lineSpacing: Int?

    /// Draft page-scroll amount percentage.
    var pageScrollAmount: Int?

    /**
     Seeds a draft from the currently stored scope settings.

     - Parameter settings: Scope-owned text-display settings currently bound to the editor.
     - Side effects: none.
     */
    init(settings: TextDisplaySettings) {
        strongsMode = settings.strongsMode
        fontSize = settings.fontSize
        fontFamily = settings.fontFamily
        marginLeft = settings.marginLeft
        marginRight = settings.marginRight
        maxWidth = settings.maxWidth
        topMargin = settings.topMargin
        lineSpacing = settings.lineSpacing
        pageScrollAmount = settings.pageScrollAmount
    }

    /**
     Commits one edited field group into stored text-display settings.

     - Parameters:
       - editor: Dialog whose values should be persisted.
       - scope: Current settings owner. Included for API symmetry with `reset`; commit writes the
         current draft value, including `nil` values produced by a scope reset.
       - settings: Stored settings value to mutate.
     - Side effects: Mutates only `settings`; callers own persistence callbacks.
     - Failure modes: Unknown values are not rejected here because Android preferences also write the
       selected widget value directly. Normalization happens before draft mutation.
     */
    func commit(_ editor: TextDisplayPreferenceEditorKind, scope: TextDisplaySettingsScope, to settings: inout TextDisplaySettings) {
        switch editor {
        case .strongsMode:
            settings.strongsMode = strongsMode
        case .fontSize:
            settings.fontSize = fontSize
        case .fontFamily:
            settings.fontFamily = fontFamily
        case .margins:
            settings.marginLeft = marginLeft
            settings.marginRight = marginRight
            settings.maxWidth = maxWidth
        case .topMargin:
            settings.topMargin = topMargin
        case .lineSpacing:
            settings.lineSpacing = lineSpacing
        case .pageScrollAmount:
            settings.pageScrollAmount = pageScrollAmount
        }
    }

    /**
     Applies Android's neutral Reset behavior to one dialog field group.

     - Parameters:
       - editor: Dialog whose values should be reset.
       - scope: Current settings owner. Global uses app defaults; workspace/window use `nil` to
         restore inheritance.
     - Side effects: Mutates only this draft.
     - Failure modes: none; every editor maps to a fixed set of optional fields.
     */
    mutating func reset(_ editor: TextDisplayPreferenceEditorKind, scope: TextDisplaySettingsScope) {
        let useDefaults = scope == .global
        let defaults = TextDisplaySettings.appDefaults
        switch editor {
        case .strongsMode:
            strongsMode = useDefaults ? defaults.strongsMode : nil
        case .fontSize:
            fontSize = useDefaults ? defaults.fontSize : nil
        case .fontFamily:
            fontFamily = useDefaults ? defaults.fontFamily : nil
        case .margins:
            marginLeft = useDefaults ? defaults.marginLeft : nil
            marginRight = useDefaults ? defaults.marginRight : nil
            maxWidth = useDefaults ? defaults.maxWidth : nil
        case .topMargin:
            topMargin = useDefaults ? defaults.topMargin : nil
        case .lineSpacing:
            lineSpacing = useDefaults ? defaults.lineSpacing : nil
        case .pageScrollAmount:
            pageScrollAmount = useDefaults ? defaults.pageScrollAmount : nil
        }
    }
}

/**
 Flat Android-style preference editor for text presentation settings used by the Bible reader.

 The view renders the user-verified Android All Text Options category and row inventory. Rows that
 already have a complete iOS model, bridge, and renderer path are interactive; Android rows in that
 target that are not yet backed on iOS remain visible in their Android position but disabled.
 Newer Android-source rows that are not part of the screenshot-backed target stay tracked in
 `TextDisplaySettingsPresentation` instead of being injected into this surface. Non-switch rows are
 rendered as preference rows that open an editor, matching Android's `PreferenceFragmentCompat`
 behavior more closely than SwiftUI's grouped `Form` rows with inline sliders.

 Data dependencies:
 - `settings` is the persisted display-settings model owned by the parent screen
 - `workspaceColor`, when supplied by global/workspace callers, exposes Android's workspace accent
   row from the nested color editor while keeping that metadata separate from inherited text-display
   settings; window callers omit it
 - `scope` determines which Android parent-scope links are visible
 - SwiftData labels back the Android `BOOKMARKS_HIDELABELS` picker
 - `onChange` lets the parent push updated settings into the reader after each mutation

 Side effects:
 - every binding write mutates `settings` and invokes `onChange`
 - parent-scope link taps invoke parent routing closures without mutating `settings`
 - hidden bookmark-label choices mutate `settings.bookmarksHideLabels`
 - non-switch editor dialogs stage a draft and mutate `settings` only from OK or Reset
 */
public struct TextDisplaySettingsView: View {
    /// App-owned child activities launched from Android preference rows.
    private enum ActivityDestination {
        case colors
        case hiddenLabels
    }

    /// Shared text display settings being edited by the form.
    @Binding var settings: TextDisplaySettings

    /// Callback invoked after any user-visible settings mutation.
    var onChange: (() -> Void)?

    /// Optional workspace accent-color binding passed to the nested Android color editor.
    private var workspaceColor: Binding<Int?>?

    /// Localized navigation title that reflects the Android settings scope currently being edited.
    private let navigationTitleText: String

    /// Android text-display scope currently being edited by this screen.
    private let scope: TextDisplaySettingsScope

    /// Workspace name used when rendering Android's workspace parent-link title.
    private let workspaceName: String?

    /// Parent route invoked by Android's `open_workspace_settings` row.
    private let onOpenWorkspaceSettings: (() -> Void)?

    /// Parent route invoked by Android's `open_global_settings` row.
    private let onOpenGlobalSettings: (() -> Void)?

    /// Reader/workspace-owned colors shared by this activity and every child activity.
    private let surfacePalette: ReaderThemeSurfacePalette

    /// Explicit Android Up action supplied by the reader destination owner.
    private let onBack: (() -> Void)?

    /// User-visible and system labels available for the hidden-bookmark-label picker.
    @Query private var allLabels: [BibleCore.Label]

    /// Hosting dismissal fallback for standalone settings callers.
    @Environment(\.dismiss) private var dismiss

    /// Durable Android-compatible recent-setting history shared with window popup menus.
    @Environment(\.modelContext) private var modelContext

    /// Active non-switch preference editor dialog, if one is open.
    @State private var activePreferenceEditor: TextDisplayPreferenceEditorKind?

    /// Current full app-owned child activity, replacing native navigation presentation.
    @State private var activityDestination: ActivityDestination?

    /// Whether Android's full-scope reset confirmation is visible.
    @State private var showsResetConfirmation = false

    /// Whether Android's scope-specific Text Options help dialog is visible.
    @State private var showsHelp = false

    /// Inclusive Android-backed slider bounds used by `FONTSIZE`.
    static let androidFontSizeRange: ClosedRange<Int> = 1...60

    /// Inclusive Android-backed slider bounds used by left and right `MARGINSIZE` controls.
    static let androidMarginRange: ClosedRange<Int> = 0...30

    /// Inclusive Android-backed slider bounds used by the maximum text-width `MARGINSIZE` control.
    static let androidMaxTextWidthRange: ClosedRange<Int> = 0...500

    /// Inclusive Android-backed slider bounds used by `TOPMARGIN`.
    static let androidTopMarginRange: ClosedRange<Int> = 0...60

    /// Inclusive Android-backed slider bounds used by `LINE_SPACING`.
    static let androidLineSpacingRange: ClosedRange<Int> = 10...30

    /// Android seekbar-backed text-display numeric editors all move in whole-number increments.
    static let androidNumericSliderStep: Double = 1

    /**
     Creates a text-display settings editor bound to a persisted settings model.

     - Parameters:
       - settings: Shared display settings value to mutate from the form.
       - workspaceColor: Optional workspace accent color edited from Android's color settings
         screen. Global/workspace routes supply this binding; window routes omit it because Android
         hides `workspace_color` only for window-specific color settings.
       - navigationTitle: Optional Android-scope title shown by the surrounding navigation stack.
         Passing `nil` uses the localized global text-options title.
       - scope: Android text-display scope currently being edited.
       - workspaceName: Optional active workspace name used by parent-link titles.
       - onOpenWorkspaceSettings: Optional route for Android's workspace parent-link row.
       - onOpenGlobalSettings: Optional route for Android's global parent-link row.
       - onChange: Optional callback invoked after current-scope setting changes.
     */
    public init(
        settings: Binding<TextDisplaySettings>,
        workspaceColor: Binding<Int?>? = nil,
        navigationTitle: String? = nil,
        scope: TextDisplaySettingsScope = .global,
        workspaceName: String? = nil,
        onOpenWorkspaceSettings: (() -> Void)? = nil,
        onOpenGlobalSettings: (() -> Void)? = nil,
        onChange: (() -> Void)? = nil
    ) {
        self._settings = settings
        self.workspaceColor = workspaceColor
        self.navigationTitleText = navigationTitle ?? String(
            localized: "global_text_display_settings_title",
            defaultValue: "Global text options"
        )
        self.scope = scope
        self.workspaceName = workspaceName
        self.onOpenWorkspaceSettings = onOpenWorkspaceSettings
        self.onOpenGlobalSettings = onOpenGlobalSettings
        self.onChange = onChange
        surfacePalette = .standard
        onBack = nil
    }

    /**
     Creates an app-owned reader Text Options activity with explicit owner palette and Up action.

     The reader route uses this initializer so the action bar, rows, nested Colors/Hide Labels
     activities, and controls all resolve from the same workspace/window palette. The public
     initializer remains source-compatible for standalone hosts and uses the standard palette.

     - Parameters: Existing public editor inputs plus the owner palette and explicit Back action.
     - Side effects: none until a user changes a setting or invokes Back.
     - Failure modes: none.
     */
    init(
        settings: Binding<TextDisplaySettings>,
        workspaceColor: Binding<Int?>? = nil,
        navigationTitle: String? = nil,
        scope: TextDisplaySettingsScope = .global,
        workspaceName: String? = nil,
        surfacePalette: ReaderThemeSurfacePalette,
        onBack: (() -> Void)?,
        onOpenWorkspaceSettings: (() -> Void)? = nil,
        onOpenGlobalSettings: (() -> Void)? = nil,
        onChange: (() -> Void)? = nil
    ) {
        self._settings = settings
        self.workspaceColor = workspaceColor
        navigationTitleText = navigationTitle ?? String(
            localized: "global_text_display_settings_title",
            defaultValue: "Global text options"
        )
        self.scope = scope
        self.workspaceName = workspaceName
        self.surfacePalette = surfacePalette
        self.onBack = onBack
        self.onOpenWorkspaceSettings = onOpenWorkspaceSettings
        self.onOpenGlobalSettings = onOpenGlobalSettings
        self.onChange = onChange
    }

    /**
     User-visible Strong's mode labels in Android dialog order.

     - Returns: Value/label pairs used by the flat row editor.
     - Side effects: none.
     - Failure modes: Missing localization keys fall back through SwiftUI localization behavior.
     */
    private var strongsModeOptions: [(value: Int, label: String)] {
        [
            (0, String(localized: "off")),
            (1, String(localized: "inline")),
            (2, String(localized: "links")),
            (3, String(localized: "hidden")),
        ]
    }

    /**
     Android page-scroll amount choices from `arrays.xml`.

     - Returns: Discrete percentage values accepted by Android's
       `PageScrollAmountPreference`.
     - Side effects: none.
     - Failure modes: none; this list is intentionally fixed to the Android source values.
     */
    private var pageScrollAmountOptions: [(value: Int, label: String)] {
        TextDisplaySettings.pageScrollAmountValues.map { value in
            (value, "\(value)%")
        }
    }

    /**
     Current line-spacing value constrained to the visible Android-backed slider range.

     Persisted values can predate the current 10...30 control bounds, so the row summary and slider
     must present a bounded value even when storage contains an older lower or higher value. The
     persisted setting is only updated when the user moves the slider.

     - Returns: Stored line spacing clamped to the supported slider range.
     - Side effects: none.
     - Failure modes: none; nil settings fall back to Android-compatible default spacing.
     */
    private var displayedLineSpacing: Int {
        min(
            max(settings.lineSpacing ?? TextDisplaySettings.appDefaults.lineSpacing ?? 16, Self.androidLineSpacingRange.lowerBound),
            Self.androidLineSpacingRange.upperBound
        )
    }

    /**
     Converts a SwiftUI slider value into a stable integer setting value.

     SwiftUI sliders emit `Double` values even when their visual control is stepped to integer
     increments. Binary floating-point representation can leave values just below the displayed
     step, so truncating would persist an off-by-one value such as 639 for a visible 640 max width.

     - Parameters:
       - value: Finite value emitted by a slider binding after SwiftUI applies its step.
       - fallback: Existing stored value to preserve if a future caller passes a non-finite value.
     - Returns: Nearest integer value suitable for persistence in `TextDisplaySettings`.
     - Side effects: none.
     - Failure modes: Does not throw; non-finite inputs return `fallback`.
     */
    static func sliderInteger(_ value: Double, fallback: Int) -> Int {
        guard value.isFinite else { return fallback }
        return Int(value.rounded())
    }

    /// Optional hidden-label IDs normalized for the nested picker screen.
    private var bookmarksHideLabelsBinding: Binding<[UUID]?> {
        Binding(
            get: { settings.bookmarksHideLabels },
            set: {
                settings.bookmarksHideLabels = $0
                recordRecentSetting(.bookmarksHideLabels)
                onChange?()
            }
        )
    }

    /**
     Creates a `Bool` binding for optional toggle-backed fields in `TextDisplaySettings`.

     - Parameters:
       - keyPath: Optional Boolean field being edited.
       - defaultValue: Fallback used when the field is currently `nil`.
     - Returns: A non-optional binding suitable for SwiftUI toggle controls.
     */
    private func boolBinding(
        _ keyPath: WritableKeyPath<TextDisplaySettings, Bool?>,
        default defaultValue: Bool,
        androidType: AndroidTextDisplaySettingType
    ) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] ?? defaultValue },
            set: {
                settings[keyPath: keyPath] = $0
                recordRecentSetting(androidType)
                onChange?()
            }
        )
    }

    /// User-created labels sorted for stable `BOOKMARKS_HIDELABELS` presentation.
    private var userLabels: [BibleCore.Label] {
        allLabels
            .filter(\.isRealLabel)
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Current hidden-label count shown on the Android `BOOKMARKS_HIDELABELS` row.
    private var hiddenBookmarkLabelsDetail: String {
        let hiddenLabelIds = Set(settings.bookmarksHideLabels ?? [])
        let visibleHiddenCount = userLabels
            .filter { hiddenLabelIds.contains($0.id) }
            .count
        if visibleHiddenCount == 0 {
            return String(localized: "no_hidden_labels", defaultValue: "No hidden labels")
        }
        return String(
            format: String(localized: "hidden_labels_count", defaultValue: "%d hidden"),
            visibleHiddenCount
        )
    }

    /// Android dynamic `FONTSIZE` row title containing the current point size.
    private var fontSizeTitle: String {
        String.localizedStringWithFormat(
            String(
                localized: "text_display_font_size_title_format",
                defaultValue: "Font size (%d pt)"
            ),
            settings.fontSize ?? TextDisplaySettings.appDefaults.fontSize ?? 16
        )
    }

    /// Android dynamic `FONTFAMILY` row title containing the persisted font-family value.
    private var fontFamilyTitle: String {
        String.localizedStringWithFormat(
            String(
                localized: "text_display_font_family_title_format",
                defaultValue: "Font family (%@)"
            ),
            settings.fontFamily ?? "sans-serif"
        )
    }

    /// Android dynamic `LINE_SPACING` row title containing the current line-spacing multiplier.
    private var lineSpacingTitle: String {
        String.localizedStringWithFormat(
            String(
                localized: "text_display_line_spacing_title_format",
                defaultValue: "Line spacing (%1.1fx)"
            ),
            Double(displayedLineSpacing) / 10.0
        )
    }

    /// Android dynamic `MARGINSIZE` row title containing left/right/max-width values.
    private var marginSizeTitle: String {
        String.localizedStringWithFormat(
            String(
                localized: "text_display_margin_size_title_format",
                defaultValue: "Margin size (%d/%d/%d mm)"
            ),
            settings.marginLeft ?? TextDisplaySettings.appDefaults.marginLeft ?? 3,
            settings.marginRight ?? TextDisplaySettings.appDefaults.marginRight ?? 3,
            settings.maxWidth ?? TextDisplaySettings.appDefaults.maxWidth ?? 170
        )
    }

    /// Android dynamic `TOPMARGIN` row title containing the current top margin.
    private var topMarginTitle: String {
        String.localizedStringWithFormat(
            String(
                localized: "text_display_top_margin_title_format",
                defaultValue: "Top margin (%d mm)"
            ),
            settings.topMargin ?? 0
        )
    }

    /// Android dynamic `PAGE_SCROLL_AMOUNT` row title containing the current percentage.
    private var pageScrollAmountTitle: String {
        String.localizedStringWithFormat(
            String(
                localized: "text_display_page_scroll_amount_title_format",
                defaultValue: "Page scroll amount (%d%%)"
            ),
            TextDisplaySettings.normalizedPageScrollAmount(settings.pageScrollAmount)
        )
    }

    /// Current user-visible Strong's mode value shown in the row editor.
    private var strongsModeDetail: String {
        let selectedValue = settings.strongsMode ?? 0
        return strongsModeOptions.first { $0.value == selectedValue }?.label ?? String(localized: "off")
    }

    /// Accessibility-exported state for the currently edited justify-text preference.
    private var accessibilityState: String {
        let justifyState = (settings.justifyText ?? false) ? "justifyTextOn" : "justifyTextOff"
        let editorState = activePreferenceEditor.map { "preferenceEditor=\($0.rawValue)" } ?? "preferenceEditor=none"
        return "\(justifyState)|\(editorState)|scope=\(scope.rawValue)"
    }

    /// Whether Android's parent-settings category should be visible for the current scope.
    private var showsParentSettingsSection: Bool {
        scope != .global
    }

    /// Android-localized title for the workspace parent-link row.
    private var workspaceParentLinkTitle: String {
        let titleFormat = String(
            localized: "workspace_text_options_link",
            defaultValue: "Workspace text options - %@"
        )
        return String.localizedStringWithFormat(titleFormat, workspaceName ?? "")
    }

    /**
     Builds the Android-ordered text-display preference list.
     */
    public var body: some View {
        let footnotesBinding = boolBinding(
            \.showFootNotes,
            default: false,
            androidType: .footnotes
        )
        let xrefsBinding = boolBinding(\.showXrefs, default: false, androidType: .xrefs)
        let justifyTextBinding = boolBinding(\.justifyText, default: false, androidType: .justify)

        ZStack(alignment: .topLeading) {
            AndroidActivityScreen(
                    title: navigationTitleText,
                    accessibilityIdentifier: "textDisplaySettingsTopAppBar",
                    palette: surfacePalette,
                    onBack: close
                ) {
                    AndroidActivityTopAppBarActionButton(
                        icon: .asset("ActivityReset"),
                        accessibilityLabel: String(localized: "reset_settings", defaultValue: "Reset"),
                        accessibilityIdentifier: "textDisplaySettingsResetButton",
                        foregroundColor: surfacePalette.toolbarForegroundColor,
                        action: { showsResetConfirmation = true }
                    )
                    AndroidActivityTopAppBarActionButton(
                        icon: .asset("DrawerHelp"),
                        accessibilityLabel: String(localized: "help", defaultValue: "Help"),
                        accessibilityIdentifier: "textDisplaySettingsHelpButton",
                        foregroundColor: surfacePalette.toolbarForegroundColor,
                        action: { showsHelp = true }
                    )
                } content: {
                    ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                    if showsParentSettingsSection {
                        parentSettingsSection
                    }

                    preferenceSection(.formatting) {
                        preferenceActionRow(
                            androidKey: "STRONGS",
                            title: androidTitle("STRONGS"),
                            summary: androidSummary("STRONGS"),
                            detail: strongsModeDetail,
                            accessibilityIdentifier: "textDisplayStrongsModeButton"
                        ) {
                            openPreferenceEditor(.strongsMode)
                        }
                        preferenceSwitchRow(
                            androidKey: "MORPH",
                            title: androidTitle("MORPH"),
                            summary: androidSummary("MORPH"),
                            isOn: boolBinding(\.showMorphology, default: false, androidType: .morphology)
                        )
                        preferenceSwitchRow(
                            androidKey: "NON_STRONGS_WORD_ITALIC",
                            title: androidTitle("NON_STRONGS_WORD_ITALIC"),
                            summary: androidSummary("NON_STRONGS_WORD_ITALIC"),
                            isOn: boolBinding(
                                \.nonStrongsWordItalic,
                                default: false,
                                androidType: .nonStrongsWordItalic
                            )
                        )
                        preferenceSwitchRow(
                            androidKey: "FOOTNOTES",
                            title: androidTitle("FOOTNOTES"),
                            summary: androidSummary("FOOTNOTES"),
                            isOn: footnotesBinding
                        )
                        preferenceSwitchRow(
                            androidKey: "FOOTNOTES_INLINE",
                            title: androidTitle("FOOTNOTES_INLINE"),
                            summary: androidSummary("FOOTNOTES_INLINE"),
                            isOn: boolBinding(
                                \.showFootNotesInline,
                                default: false,
                                androidType: .footnotesInline
                            ),
                            isEnabled: footnotesBinding.wrappedValue
                        )
                        preferenceSwitchRow(
                            androidKey: "XREFS",
                            title: androidTitle("XREFS"),
                            summary: androidSummary("XREFS"),
                            isOn: xrefsBinding
                        )
                        preferenceSwitchRow(
                            androidKey: "EXPAND_XREFS",
                            title: androidTitle("EXPAND_XREFS"),
                            summary: androidSummary("EXPAND_XREFS"),
                            isOn: boolBinding(
                                \.expandXrefs,
                                default: false,
                                androidType: .expandXrefs
                            ),
                            isEnabled: xrefsBinding.wrappedValue
                        )
                        preferenceSwitchRow(
                            androidKey: "SECTIONTITLES",
                            title: androidTitle("SECTIONTITLES"),
                            summary: androidSummary("SECTIONTITLES"),
                            isOn: boolBinding(
                                \.showSectionTitles,
                                default: true,
                                androidType: .sectionTitles
                            )
                        )
                        preferenceSwitchRow(
                            androidKey: "TITLE_SCROLL_BUTTON",
                            title: androidTitle("TITLE_SCROLL_BUTTON"),
                            summary: androidSummary("TITLE_SCROLL_BUTTON"),
                            isOn: boolBinding(
                                \.showTitleScrollButton,
                                default: false,
                                androidType: .titleScrollButton
                            )
                        )
                        preferenceSwitchRow(
                            androidKey: "VERSENUMBERS",
                            title: androidTitle("VERSENUMBERS"),
                            summary: androidSummary("VERSENUMBERS"),
                            isOn: boolBinding(
                                \.showVerseNumbers,
                                default: true,
                                androidType: .verseNumbers
                            )
                        )
                    }

                    preferenceSection(.appearance) {
                        preferenceActionRow(
                            androidKey: "COLORS",
                            title: androidTitle("COLORS"),
                            summary: androidSummary("COLORS"),
                            accessibilityIdentifier: "textDisplayColorsLink"
                        ) {
                            activityDestination = .colors
                        }

                        preferenceActionRow(
                            androidKey: "FONTSIZE",
                            title: fontSizeTitle,
                            summary: androidSummary("FONTSIZE"),
                            accessibilityIdentifier: "textDisplayFontSizeButton"
                        ) {
                            openPreferenceEditor(.fontSize)
                        }

                        preferenceActionRow(
                            androidKey: "FONTFAMILY",
                            title: fontFamilyTitle,
                            summary: androidSummary("FONTFAMILY"),
                            accessibilityIdentifier: "textDisplayFontFamilyButton"
                        ) {
                            openPreferenceEditor(.fontFamily)
                        }

                        preferenceActionRow(
                            androidKey: "MARGINSIZE",
                            title: marginSizeTitle,
                            summary: androidSummary("MARGINSIZE"),
                            accessibilityIdentifier: "textDisplayMarginSizeButton"
                        ) {
                            openPreferenceEditor(.margins)
                        }
                        preferenceActionRow(
                            androidKey: "TOPMARGIN",
                            title: topMarginTitle,
                            summary: androidSummary("TOPMARGIN"),
                            accessibilityIdentifier: "textDisplayTopMarginButton"
                        ) {
                            openPreferenceEditor(.topMargin)
                        }
                        preferenceActionRow(
                            androidKey: "LINE_SPACING",
                            title: lineSpacingTitle,
                            summary: androidSummary("LINE_SPACING"),
                            accessibilityIdentifier: "textDisplayLineSpacingButton"
                        ) {
                            openPreferenceEditor(.lineSpacing)
                        }
                        preferenceSwitchRow(
                            androidKey: "REDLETTERS",
                            title: androidTitle("REDLETTERS"),
                            summary: androidSummary("REDLETTERS"),
                            isOn: boolBinding(\.showRedLetters, default: true, androidType: .redLetters)
                        )
                        preferenceSwitchRow(
                            androidKey: "VERSEPERLINE",
                            title: androidTitle("VERSEPERLINE"),
                            summary: androidSummary("VERSEPERLINE"),
                            isOn: boolBinding(
                                \.showVersePerLine,
                                default: false,
                                androidType: .versePerLine
                            )
                        )
                        preferenceSwitchRow(
                            androidKey: "JUSTIFY",
                            title: androidTitle("JUSTIFY"),
                            summary: androidSummary("JUSTIFY"),
                            isOn: justifyTextBinding,
                            rowAccessibilityIdentifier: "textDisplayJustifyTextToggleButton",
                            switchAccessibilityIdentifier: "textDisplayJustifyTextToggle"
                        )
                        preferenceSwitchRow(
                            androidKey: "HYPHENATION",
                            title: androidTitle("HYPHENATION"),
                            summary: androidSummary("HYPHENATION"),
                            isOn: boolBinding(\.hyphenation, default: true, androidType: .hyphenation)
                        )
                        preferenceSwitchRow(
                            androidKey: "PAGENUMBER",
                            title: androidTitle("PAGENUMBER"),
                            summary: androidSummary("PAGENUMBER"),
                            isOn: boolBinding(\.showPageNumber, default: false, androidType: .pageNumber)
                        )
                    }

                    preferenceSection(.pageScrolling) {
                        preferenceSwitchRow(
                            androidKey: "INFINITE_SCROLL",
                            title: androidTitle("INFINITE_SCROLL"),
                            summary: androidSummary("INFINITE_SCROLL"),
                            isOn: boolBinding(
                                \.infiniteScroll,
                                default: true,
                                androidType: .infiniteScroll
                            )
                        )
                        preferenceActionRow(
                            androidKey: "PAGE_SCROLL_AMOUNT",
                            title: pageScrollAmountTitle,
                            summary: androidSummary("PAGE_SCROLL_AMOUNT"),
                            accessibilityIdentifier: "textDisplayPageScrollAmountButton"
                        ) {
                            openPreferenceEditor(.pageScrollAmount)
                        }
                        preferenceSwitchRow(
                            androidKey: "ORDINALS",
                            title: androidTitle("ORDINALS"),
                            summary: androidSummary("ORDINALS"),
                            isOn: boolBinding(\.showOrdinals, default: false, androidType: .ordinals)
                        )
                    }

                    preferenceSection(.textBookmarks) {
                        preferenceSwitchRow(
                            androidKey: "BOOKMARKS_SHOW",
                            title: androidTitle("BOOKMARKS_SHOW"),
                            summary: androidSummary("BOOKMARKS_SHOW"),
                            isOn: boolBinding(
                                \.showBookmarks,
                                default: true,
                                androidType: .bookmarksShow
                            )
                        )
                        preferenceSwitchRow(
                            androidKey: "MYNOTES",
                            title: androidTitle("MYNOTES"),
                            summary: androidSummary("MYNOTES"),
                            isOn: boolBinding(\.showMyNotes, default: true, androidType: .myNotes)
                        )
                        preferenceSwitchRow(
                            androidKey: "AI_DOC_MARKERS",
                            title: androidTitle("AI_DOC_MARKERS"),
                            summary: androidSummary("AI_DOC_MARKERS"),
                            isOn: boolBinding(
                                \.showAiDocMarkers,
                                default: true,
                                androidType: .aiDocumentMarkers
                            )
                        )
                        preferenceActionRow(
                            androidKey: "BOOKMARKS_HIDELABELS",
                            title: androidTitle("BOOKMARKS_HIDELABELS"),
                            summary: androidSummary("BOOKMARKS_HIDELABELS"),
                            detail: hiddenBookmarkLabelsDetail,
                            accessibilityIdentifier: "textDisplayHiddenBookmarkLabelsLink"
                        ) {
                            activityDestination = .hiddenLabels
                        }
                    }

                    preferenceSection(.readingAndMemorization) {
                        preferenceSwitchRow(
                            androidKey: "MARK_AS_READ_BUTTON",
                            title: androidTitle("MARK_AS_READ_BUTTON"),
                            summary: androidSummary("MARK_AS_READ_BUTTON"),
                            isOn: boolBinding(
                                \.showMarkAsReadButton,
                                default: true,
                                androidType: .markAsReadButton
                            )
                        )
                        preferenceSwitchRow(
                            androidKey: "MEMORIZATION_INDICATORS",
                            title: androidTitle("MEMORIZATION_INDICATORS"),
                            summary: androidSummary("MEMORIZATION_INDICATORS"),
                            isOn: boolBinding(
                                \.showMemorizationIndicators,
                                default: false,
                                androidType: .memorizationIndicators
                            )
                        )
                    }
                    }
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("textDisplaySettingsScrollView")
            }

            textDisplaySettingsStateExport
            textDisplayPreferenceEditorOverlay
            textDisplayActivityOverlay
            textDisplayResetOverlay
            textDisplayHelpOverlay
        }
    }

    /**
     Resolves the Android-sourced default title for one text-display row.

     - Parameter androidKey: Android preference key from `text_display_settings.xml`.
     - Returns: English Android title from the presentation catalog, or the key when uncataloged.
     - Side effects: none.
     - Failure modes: Missing catalog entries fall back to the key rather than failing.
     */
    private func androidTitle(_ androidKey: String) -> String {
        TextDisplaySettingsPresentation.rowByAndroidKey[androidKey]?.titleDefault ?? androidKey
    }

    /**
     Resolves the Android-sourced default summary for one text-display row.

     - Parameter androidKey: Android preference key from `text_display_settings.xml`.
     - Returns: English Android summary from the presentation catalog, or `nil` when Android has
       no summary for the key.
     - Side effects: none.
     - Failure modes: Missing catalog entries simply omit the summary.
     */
    private func androidSummary(_ androidKey: String) -> String? {
        TextDisplaySettingsPresentation.rowByAndroidKey[androidKey]?.summaryDefault
    }

    /**
     Builds Android's parent-settings category for non-global text-display scopes.

     Window scope exposes both workspace and global parent routes. Workspace scope exposes only the
     global route. Global scope hides the category entirely because it is already the root
     text-display owner.
     */
    @ViewBuilder
    private var parentSettingsSection: some View {
        preferenceSectionHeader(String(localized: "parent_settings_category_title", defaultValue: "Parent settings")) {
            if scope == .window {
                preferenceActionRow(
                    androidKey: "open_workspace_settings",
                    title: workspaceParentLinkTitle,
                    summary: androidSummary("open_workspace_settings"),
                    accessibilityIdentifier: "textDisplayOpenWorkspaceSettingsButton"
                ) {
                    onOpenWorkspaceSettings?()
                }
            }

            preferenceActionRow(
                androidKey: "open_global_settings",
                title: String(localized: "global_text_options_link", defaultValue: "Global text options"),
                summary: androidSummary("open_global_settings"),
                accessibilityIdentifier: "textDisplayOpenGlobalSettingsButton"
            ) {
                onOpenGlobalSettings?()
            }
        }
    }

    /**
     Accessibility-only state export for UI tests and reader route assertions.

     SwiftUI `ScrollView` does not reliably refresh its own accessibility value after child state
     mutations, so the screen state lives on a tiny non-interactive element layered above the list.
     Rows remain accessible as normal controls because this element does not contain or replace them.

     - Returns: A one-point accessibility element with the stable Text Display screen identifier.
     - Side effects: none.
     - Failure modes: This helper cannot fail; missing state simply reflects the current bindings.
     */
    private var textDisplaySettingsStateExport: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("textDisplaySettingsScreen")
            .accessibilityLabel("textDisplaySettingsScreen")
            .accessibilityValue(accessibilityState)
            .allowsHitTesting(false)
    }

    /**
     Presents nested Android activities above the owning Text Options activity.

     Colors and Hide Labels keep their own action bars and return through an explicit Up action;
     no iOS navigation stack, sheet, or modal transition owns either route.

     - Returns: The selected full app-owned child activity, or no overlay for the root list.
     - Side effects: Child activity commands mutate their supplied bindings and invoke `onChange`.
     - Failure modes: none.
     */
    @ViewBuilder
    private var textDisplayActivityOverlay: some View {
        switch activityDestination {
        case .colors:
            ColorSettingsView(
                settings: $settings,
                workspaceColor: workspaceColor,
                surfacePalette: surfacePalette,
                activityTitle: String(localized: "colors", defaultValue: "Colors"),
                onBack: { activityDestination = nil },
                onChange: {
                    recordRecentSetting(.colors)
                    onChange?()
                }
            )
            .zIndex(15)
        case .hiddenLabels:
            AndroidHiddenLabelsActivityView(
                labels: allLabels,
                hiddenLabelIDs: bookmarksHideLabelsBinding,
                isWindow: scope == .window,
                surfacePalette: surfacePalette,
                onDismiss: { activityDestination = nil },
                onChange: {
                    recordRecentSetting(.bookmarksHideLabels)
                    onChange?()
                }
            )
            .zIndex(15)
        case nil:
            EmptyView()
        }
    }

    /** Android's confirmation dialog for clearing every override at the current settings scope. */
    @ViewBuilder
    private var textDisplayResetOverlay: some View {
        if showsResetConfirmation {
            AndroidDecisionDialog(
                title: "",
                message: String(
                    localized: "reset_are_you_sure",
                    defaultValue: "Are you sure that you want to reset all of these values?"
                ),
                actions: [
                    .init(
                        id: "yes",
                        title: String(localized: "yes", defaultValue: "Yes"),
                        style: .destructive
                    ) {
                        resetAllTextDisplaySettings()
                    },
                    .init(
                        id: "no",
                        title: String(localized: "no", defaultValue: "No"),
                        style: .normal
                    ) {
                        showsResetConfirmation = false
                    },
                ],
                accessibilityIdentifier: "textDisplaySettingsResetDialog"
            )
            .zIndex(30)
        }
    }

    /** Android's scope-specific Text Options help content in the shared app-owned dialog. */
    @ViewBuilder
    private var textDisplayHelpOverlay: some View {
        if showsHelp {
            AndroidTextDisplayHelpDialog(scope: scope) {
                showsHelp = false
            }
            .zIndex(30)
        }
    }

    /**
     Applies Android's activity-level reset contract and exits the current scope.

     Android writes an empty `TextDisplaySettings` object so every field inherits from the next
     owner (or bundled defaults at global scope). Persisting concrete iOS defaults here would break
     later parent propagation, so this deliberately clears the complete override object.

     - Side effects: Clears current-scope settings, invokes persistence, dismisses confirmation, and
       closes the activity.
     - Failure modes: Persistence failures retain the existing soft-failure behavior of `onChange`.
     */
    private func resetAllTextDisplaySettings() {
        settings = TextDisplaySettings()
        onChange?()
        showsResetConfirmation = false
        close()
    }

    /** Closes the current app-owned activity through its explicit owner or hosting fallback. */
    private func close() {
        if activityDestination != nil {
            activityDestination = nil
        } else if let onBack {
            onBack()
        } else {
            dismiss()
        }
    }

    /**
     Builds one Android-style preference section with a flat header and full-width rows.

     - Parameters:
       - section: Android rendered section represented by the rows.
       - content: Rows to display below the section title.
     - Returns: A flat preference section without SwiftUI grouped-card styling.
     - Side effects: none; row content owns setting mutation.
     - Failure modes: This helper cannot fail.
     */
    private func preferenceSection<Content: View>(
        _ section: TextDisplaySettingsPresentation.Section,
        @ViewBuilder content: () -> Content
    ) -> some View {
        preferenceSectionHeader(section.titleDefault, content: content)
    }

    /**
     Builds one Android-style preference section with an explicit header title.

     - Parameters:
       - title: Header text rendered above the flat Android-style rows.
       - content: Rows to display below the section title.
     - Returns: A flat preference section without SwiftUI grouped-card styling.
     - Side effects: none; row content owns setting mutation and navigation callbacks.
     - Failure modes: This helper cannot fail.
     */
    private func preferenceSectionHeader<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        AndroidPreferenceSection(title: title, palette: surfacePalette, content: content)
    }

    /**
     Builds a preference row that opens an editor when tapped.

     - Parameters:
       - androidKey: Android preference key used for icon lookup.
       - title: Primary row title.
       - summary: Optional secondary row text.
       - detail: Optional tertiary state text.
       - accessibilityIdentifier: Stable UI-test identifier for the row button.
       - action: Mutation that presents the destination editor.
     - Returns: A tappable flat preference row with a chevron accessory.
     - Side effects: Invokes `action` when tapped.
     - Failure modes: This helper cannot fail; destination presentation failures are handled by
       SwiftUI sheet/navigation state.
     */
    @ViewBuilder
    private func preferenceActionRow(
        androidKey: String,
        title: String,
        summary: String? = nil,
        detail: String? = nil,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        AndroidCatalogActionPreferenceRow(
            title: title,
            summary: summary,
            detail: detail,
            icon: AndBibleIconCatalog.settingsIcon(forAndroidKey: androidKey),
            palette: surfacePalette,
            accessibilityIdentifier: accessibilityIdentifier,
            action: action
        )
        preferenceDivider()
    }

    /**
     Builds a flat Android-style switch row.

     - Parameters:
       - androidKey: Android preference key used for icon lookup.
       - title: Primary row title.
       - summary: Optional secondary row text.
       - isOn: Binding that stores the preference value.
       - isEnabled: Whether the row can mutate the binding.
       - rowAccessibilityIdentifier: Optional UI-test identifier for the row tap target.
       - switchAccessibilityIdentifier: Optional UI-test identifier for the switch itself.
     - Returns: One shared app-owned Android switch preference row.
     - Side effects: Tapping the row mutates `isOn`.
     - Failure modes: Disabled rows ignore taps and keep the binding unchanged.
     */
    @ViewBuilder
    private func preferenceSwitchRow(
        androidKey: String,
        title: String,
        summary: String? = nil,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        rowAccessibilityIdentifier: String? = nil,
        switchAccessibilityIdentifier: String? = nil
    ) -> some View {
        AndroidCatalogSwitchPreferenceRow(
            title: title,
            summary: summary,
            icon: AndBibleIconCatalog.settingsIcon(forAndroidKey: androidKey),
            isOn: isOn,
            isEnabled: isEnabled,
            palette: surfacePalette,
            accessibilityIdentifier: rowAccessibilityIdentifier
                ?? switchAccessibilityIdentifier
                ?? "textDisplaySwitchRow-\(androidKey)"
        )
        preferenceDivider()
    }

    /**
     Builds a disabled switch row for Android parity targets that are not implemented on iOS yet.

     - Parameter androidKey: Android preference key from `text_display_settings.xml`.
     - Returns: Disabled flat switch row that keeps Android ordering visible.
     - Side effects: none; the constant binding cannot write.
     - Failure modes: Unknown keys still render with the key as the title and no icon.
     */
    private func disabledPreferenceSwitchRow(androidKey: String) -> some View {
        preferenceSwitchRow(
            androidKey: androidKey,
            title: androidTitle(androidKey),
            summary: androidSummary(androidKey),
            isOn: .constant(false),
            isEnabled: false,
            rowAccessibilityIdentifier: "textDisplayDisabled-\(androidKey)"
        )
    }

    /**
     Builds the flat row divider used between Android-style preference rows.

     - Returns: Divider aligned after the icon gutter, matching Android preference separators.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func preferenceDivider() -> some View {
        AndroidPreferenceDivider(palette: surfacePalette)
    }

    /**
     Opens a non-switch Android preference editor with a fresh staged draft.

     - Parameter editor: Editor selected from the flat row list.
     - Side effects: Presents the shared in-place Android dialog with a fresh staged draft.
     - Failure modes: none; every enum case is renderable by the overlay.
     */
    private func openPreferenceEditor(_ editor: TextDisplayPreferenceEditorKind) {
        activePreferenceEditor = editor
    }

    /**
     Builds the dimmed modal layer used for Android-style text-display preference dialogs.

     The overlay is owned by this settings screen rather than SwiftUI sheet presentation so the
     editor matches Android's in-place `AlertDialog` behavior. Tapping the dimmer follows Android's
     cancel path and discards the draft.

     - Returns: Full-screen modal dimmer and centered editor dialog when an editor is active.
     - Side effects: Child button actions can mutate the draft, commit settings, reset settings, or
       dismiss the overlay.
     - Failure modes: If no editor is active, renders no overlay.
     */
    @ViewBuilder
    private var textDisplayPreferenceEditorOverlay: some View {
        if let editor = activePreferenceEditor {
            AndroidTextDisplayPreferenceEditorDialog(
                editor: editor,
                settings: $settings,
                scope: scope,
                surfacePalette: surfacePalette,
                onCommit: {
                    activePreferenceEditor = nil
                    recordRecentSetting(editor.androidSettingType)
                    onChange?()
                },
                onReset: {
                    activePreferenceEditor = nil
                    onChange?()
                },
                onCancel: { activePreferenceEditor = nil }
            )
            .zIndex(20)
            .androidDialogAccessibilityIdentity(
                accessibilityIdentifier: "textDisplayPreferenceEditorOverlay",
                accessibilityValue: editor.rawValue
            )
        }
    }

    /**
     Records one committed text-setting type using Android's shared five-item history.

     - Parameter type: Exact Android enum identity for the setting that changed.
     - Side effects: Persists `lastDisplaySettings` in the shared app settings store.
     - Failure modes: Malformed prior JSON is replaced only after a valid new payload is encoded.
     */
    private func recordRecentSetting(_ type: AndroidTextDisplaySettingType) {
        AndroidTextDisplayRecentSettings.record(
            type,
            settingsStore: SettingsStore(modelContext: modelContext)
        )
    }

    /// Android built-in font families from `FontSizeWidget.kt`, preserving source order and duplicates.
    static let androidStandardFontFamilies: [String] = [
        "sans-serif-thin",
        "sans-serif-light",
        "sans-serif",
        "sans-serif-medium",
        "sans-serif-black",
        "sans-serif-condensed-light",
        "sans-serif-condensed",
        "sans-serif-condensed-medium",
        "sans-serif-condensed",
        "serif",
        "monospace",
        "serif-monospace",
        "casual",
        "cursive",
        "sans-serif-smallcaps",
    ]

    /**
     Builds Android's font-family option list for the text-display dialog.

     - Parameter providedFonts: Optional Android add-on font names that would precede the standard
       list on Android. iOS currently passes no add-on fonts because those files are not installed
       through the iOS document pipeline.
     - Returns: Font option rows in Android widget order.
     - Side effects: none.
     - Failure modes: none; empty input still returns the Android standard family list.
     */
    static func androidFontFamilyOptions(providedFonts: [String] = []) -> [TextDisplayFontFamilyOption] {
        (providedFonts + androidStandardFontFamilies)
            .enumerated()
            .map { index, value in
                TextDisplayFontFamilyOption(
                    androidIndex: index,
                    label: androidFontFamilyDisplayName(value),
                    value: value
                )
            }
    }

    /**
     Mirrors Android `FontDefinition.name` for built-in font-family labels.

     Android replaces hyphens with spaces and capitalizes only the first character. This deliberately
     does not title-case each word because that would make iOS look nicer while drifting from the
     source widget.

     - Parameter fontFamily: Android font-family value.
     - Returns: User-visible label matching Android's built-in family naming convention.
     - Side effects: none.
     - Failure modes: Empty strings return an empty label.
     */
    static func androidFontFamilyDisplayName(_ fontFamily: String) -> String {
        let normalized = fontFamily.replacingOccurrences(of: "-", with: " ")
        guard let first = normalized.first else { return normalized }
        return String(first).uppercased() + normalized.dropFirst()
    }

    /**
     Resolves the first Android option index matching a stored font-family value.

     Android's spinner calls `availableFonts.find { it.realFontFamily == fontFamilyVal }`, so the
     duplicated `sans-serif-condensed` row resolves to the first duplicate after updates.

     - Parameter value: Stored font-family value, or `nil` to use the Android default.
     - Returns: First matching Android option index, falling back to the default `sans-serif` row.
     - Side effects: none.
     - Failure modes: Unknown values fall back to index `0` when even the default is unavailable.
     */
    static func androidFontFamilySelectedIndex(for value: String?) -> Int {
        let resolvedValue = value ?? TextDisplaySettings.appDefaults.fontFamily ?? "sans-serif"
        let options = androidFontFamilyOptions()
        if let exactIndex = options.firstIndex(where: { $0.value == resolvedValue }) {
            return exactIndex
        }
        return options.firstIndex(where: { $0.value == "sans-serif" }) ?? 0
    }
}
