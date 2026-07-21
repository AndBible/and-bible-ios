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

    /// User-visible and system labels available for the hidden-bookmark-label picker.
    @Query private var allLabels: [BibleCore.Label]

    /// Current system appearance used by the Android dialog color palette.
    @Environment(\.colorScheme) private var colorScheme

    /// Active non-switch preference editor dialog, if one is open.
    @State private var activePreferenceEditor: TextDisplayPreferenceEditorKind?

    /// Local staged editor values that mirror Android dialog widgets.
    @State private var preferenceEditorDraft = TextDisplayPreferenceEditorDraft(settings: TextDisplaySettings())

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
            set: { settings.bookmarksHideLabels = $0; onChange?() }
        )
    }

    /**
     Creates a `Bool` binding for optional toggle-backed fields in `TextDisplaySettings`.

     - Parameters:
       - keyPath: Optional Boolean field being edited.
       - defaultValue: Fallback used when the field is currently `nil`.
     - Returns: A non-optional binding suitable for SwiftUI toggle controls.
     */
    private func boolBinding(_ keyPath: WritableKeyPath<TextDisplaySettings, Bool?>, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] ?? defaultValue },
            set: { settings[keyPath: keyPath] = $0; onChange?() }
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
        let footnotesBinding = boolBinding(\.showFootNotes, default: false)
        let xrefsBinding = boolBinding(\.showXrefs, default: false)
        let justifyTextBinding = boolBinding(\.justifyText, default: false)

        ZStack(alignment: .topLeading) {
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
                            isOn: boolBinding(\.showMorphology, default: false)
                        )
                        preferenceSwitchRow(
                            androidKey: "NON_STRONGS_WORD_ITALIC",
                            title: androidTitle("NON_STRONGS_WORD_ITALIC"),
                            summary: androidSummary("NON_STRONGS_WORD_ITALIC"),
                            isOn: boolBinding(\.nonStrongsWordItalic, default: false)
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
                            isOn: boolBinding(\.showFootNotesInline, default: false),
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
                            isOn: boolBinding(\.expandXrefs, default: false),
                            isEnabled: xrefsBinding.wrappedValue
                        )
                        preferenceSwitchRow(
                            androidKey: "SECTIONTITLES",
                            title: androidTitle("SECTIONTITLES"),
                            summary: androidSummary("SECTIONTITLES"),
                            isOn: boolBinding(\.showSectionTitles, default: true)
                        )
                        preferenceSwitchRow(
                            androidKey: "TITLE_SCROLL_BUTTON",
                            title: androidTitle("TITLE_SCROLL_BUTTON"),
                            summary: androidSummary("TITLE_SCROLL_BUTTON"),
                            isOn: boolBinding(\.showTitleScrollButton, default: false)
                        )
                        preferenceSwitchRow(
                            androidKey: "VERSENUMBERS",
                            title: androidTitle("VERSENUMBERS"),
                            summary: androidSummary("VERSENUMBERS"),
                            isOn: boolBinding(\.showVerseNumbers, default: true)
                        )
                    }

                    preferenceSection(.appearance) {
                        NavigationLink {
                            ColorSettingsView(
                                settings: $settings,
                                workspaceColor: workspaceColor,
                                onChange: onChange
                            )
                        } label: {
                            preferenceRowContent(
                                androidKey: "COLORS",
                                title: androidTitle("COLORS"),
                                summary: androidSummary("COLORS")
                            ) {
                                rowChevron
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("textDisplayColorsLink")
                        preferenceDivider()

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
                            isOn: boolBinding(\.showRedLetters, default: true)
                        )
                        preferenceSwitchRow(
                            androidKey: "VERSEPERLINE",
                            title: androidTitle("VERSEPERLINE"),
                            summary: androidSummary("VERSEPERLINE"),
                            isOn: boolBinding(\.showVersePerLine, default: false)
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
                            isOn: boolBinding(\.hyphenation, default: true)
                        )
                        preferenceSwitchRow(
                            androidKey: "PAGENUMBER",
                            title: androidTitle("PAGENUMBER"),
                            summary: androidSummary("PAGENUMBER"),
                            isOn: boolBinding(\.showPageNumber, default: false)
                        )
                    }

                    preferenceSection(.pageScrolling) {
                        preferenceSwitchRow(
                            androidKey: "INFINITE_SCROLL",
                            title: androidTitle("INFINITE_SCROLL"),
                            summary: androidSummary("INFINITE_SCROLL"),
                            isOn: boolBinding(\.infiniteScroll, default: true)
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
                            isOn: boolBinding(\.showOrdinals, default: false)
                        )
                    }

                    preferenceSection(.textBookmarks) {
                        preferenceSwitchRow(
                            androidKey: "BOOKMARKS_SHOW",
                            title: androidTitle("BOOKMARKS_SHOW"),
                            summary: androidSummary("BOOKMARKS_SHOW"),
                            isOn: boolBinding(\.showBookmarks, default: true)
                        )
                        preferenceSwitchRow(
                            androidKey: "MYNOTES",
                            title: androidTitle("MYNOTES"),
                            summary: androidSummary("MYNOTES"),
                            isOn: boolBinding(\.showMyNotes, default: true)
                        )
                        preferenceSwitchRow(
                            androidKey: "AI_DOC_MARKERS",
                            title: androidTitle("AI_DOC_MARKERS"),
                            summary: androidSummary("AI_DOC_MARKERS"),
                            isOn: boolBinding(\.showAiDocMarkers, default: true)
                        )
                        NavigationLink {
                            HiddenBookmarkLabelsView(
                                labels: userLabels,
                                hiddenLabelIds: bookmarksHideLabelsBinding,
                                onChange: onChange
                            )
                        } label: {
                            preferenceRowContent(
                                androidKey: "BOOKMARKS_HIDELABELS",
                                title: androidTitle("BOOKMARKS_HIDELABELS"),
                                summary: androidSummary("BOOKMARKS_HIDELABELS"),
                                detail: hiddenBookmarkLabelsDetail
                            ) {
                                rowChevron
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("textDisplayHiddenBookmarkLabelsLink")
                        preferenceDivider()
                    }

                    preferenceSection(.readingAndMemorization) {
                        preferenceSwitchRow(
                            androidKey: "MARK_AS_READ_BUTTON",
                            title: androidTitle("MARK_AS_READ_BUTTON"),
                            summary: androidSummary("MARK_AS_READ_BUTTON"),
                            isOn: boolBinding(\.showMarkAsReadButton, default: true)
                        )
                        preferenceSwitchRow(
                            androidKey: "MEMORIZATION_INDICATORS",
                            title: androidTitle("MEMORIZATION_INDICATORS"),
                            summary: androidSummary("MEMORIZATION_INDICATORS"),
                            isOn: boolBinding(\.showMemorizationIndicators, default: false)
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            .accessibilityIdentifier("textDisplaySettingsScrollView")

            textDisplaySettingsStateExport
            textDisplayPreferenceEditorOverlay
        }
        .background(textDisplayScreenBackground.ignoresSafeArea())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(navigationTitleText)
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
     Platform background for the flat Android-style preference surface.

     - Returns: A system background color on iOS and a transparent fallback on macOS package builds.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private var textDisplayScreenBackground: Color {
        #if os(iOS)
        Color(.systemBackground)
        #else
        Color.clear
        #endif
    }

    /**
     Leading inset for Android-style row dividers.

     - Returns: Horizontal inset that starts dividers at the row text column after the icon gutter.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private var preferenceDividerLeadingInset: CGFloat {
        AndBibleSettingsPreferenceLayout.dividerLeadingInset
    }

    /**
     Chevron accessory used for rows that open another editor.

     - Returns: A secondary chevron image aligned to the trailing edge of a preference row.
     - Side effects: none.
     - Failure modes: Missing SF Symbols would render SwiftUI's symbol fallback.
     */
    private var rowChevron: some View {
        Image(systemName: "chevron.right")
            .font(.body.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
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
        VStack(alignment: .leading, spacing: 0) {
            textDisplaySectionHeader(title)
                .padding(.bottom, AndBibleSettingsPreferenceLayout.sectionHeaderBottomPadding)
            content()
        }
        .padding(.bottom, AndBibleSettingsPreferenceLayout.sectionBottomPadding)
    }

    /**
     Builds the shared label/accessory layout for one flat preference row.

     - Parameters:
       - androidKey: Android preference key used for icon lookup.
       - title: Primary row title.
       - summary: Optional secondary row text.
       - detail: Optional tertiary state text.
       - isEnabled: Whether text and icon should use enabled emphasis.
       - accessory: Trailing control or navigation affordance.
     - Returns: A single preference row content block.
     - Side effects: Renders Android-sourced icon assets through `textDisplayRowLabel`.
     - Failure modes: Unknown Android keys render without an icon.
     */
    private func preferenceRowContent<Accessory: View>(
        androidKey: String,
        title: String,
        summary: String? = nil,
        detail: String? = nil,
        isEnabled: Bool = true,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .center, spacing: AndBibleSettingsPreferenceLayout.accessorySpacing) {
            textDisplayRowLabel(
                androidKey: androidKey,
                title: title,
                summary: summary,
                detail: detail,
                isEnabled: isEnabled
            )
            .layoutPriority(1)

            accessory()
        }
        .padding(.horizontal, AndBibleSettingsPreferenceLayout.rowHorizontalPadding)
        .background(textDisplayScreenBackground)
        .contentShape(Rectangle())
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
        Button(action: action) {
            preferenceRowContent(
                androidKey: androidKey,
                title: title,
                summary: summary,
                detail: detail
            ) {
                rowChevron
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier(accessibilityIdentifier)
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
     - Returns: A row label and native switch aligned like an Android preference row.
     - Side effects: Tapping the row label or switch mutates `isOn`.
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
        HStack(alignment: .center, spacing: AndBibleSettingsPreferenceLayout.accessorySpacing) {
            Button {
                if isEnabled {
                    isOn.wrappedValue.toggle()
                }
            } label: {
                textDisplayRowLabel(
                    androidKey: androidKey,
                    title: title,
                    summary: summary,
                    isEnabled: isEnabled
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(rowAccessibilityIdentifier ?? "textDisplaySwitchRow-\(androidKey)")
            .layoutPriority(1)
            .disabled(!isEnabled)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .disabled(!isEnabled)
                .accessibilityIdentifier(switchAccessibilityIdentifier ?? "textDisplaySwitch-\(androidKey)")
                .accessibilityValue(isOn.wrappedValue ? "on" : "off")
        }
        .padding(.horizontal, AndBibleSettingsPreferenceLayout.rowHorizontalPadding)
        .background(textDisplayScreenBackground)
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
        Divider()
            .padding(.leading, preferenceDividerLeadingInset)
    }

    /**
     Opens a non-switch Android preference editor with a fresh staged draft.

     - Parameter editor: Editor selected from the flat row list.
     - Side effects: Copies the current stored settings into `preferenceEditorDraft` and presents the
       in-place Android dialog overlay.
     - Failure modes: none; every enum case is renderable by the overlay.
     */
    private func openPreferenceEditor(_ editor: TextDisplayPreferenceEditorKind) {
        preferenceEditorDraft = TextDisplayPreferenceEditorDraft(settings: settings)
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
            ZStack {
                Color.black.opacity(colorScheme == .dark ? 0.45 : 0.32)
                    .ignoresSafeArea()
                    .onTapGesture {
                        cancelPreferenceEditor()
                    }
                    .accessibilityHidden(true)

                makePreferenceEditorDialog(editor)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(20)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("textDisplayPreferenceEditorOverlay")
            .accessibilityValue(editor.rawValue)
        }
    }

    /**
     Builds one centered AppCompat-style editor dialog.

     - Parameter editor: Active Android preference editor being rendered.
     - Returns: Dialog chrome with title, field content, and Reset/Cancel/OK actions.
     - Side effects: Action buttons call reset, cancel, or commit helpers; field controls only mutate
       `preferenceEditorDraft`.
     - Failure modes: none; unsupported editor cases would be compile-time switch failures.
     */
    private func makePreferenceEditorDialog(_ editor: TextDisplayPreferenceEditorKind) -> some View {
        VStack(spacing: 0) {
            Text(preferenceEditorTitle(editor))
                .font(.headline)
                .foregroundStyle(dialogPrimaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Divider()
                .background(dialogSecondaryText.opacity(0.25))

            preferenceEditorDialogContent(editor)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)

            Divider()
                .background(dialogSecondaryText.opacity(0.25))

            HStack(spacing: 16) {
                Button(String(localized: "reset_generic", defaultValue: "Reset")) {
                    resetPreferenceEditor(editor)
                }
                .accessibilityIdentifier("textDisplayPreferenceEditorResetButton")

                Spacer(minLength: 8)

                Button(String(localized: "cancel")) {
                    cancelPreferenceEditor()
                }
                .accessibilityIdentifier("textDisplayPreferenceEditorCancelButton")

                Button(String(localized: "ok", defaultValue: "OK")) {
                    commitPreferenceEditor(editor)
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("textDisplayPreferenceEditorOKButton")
            }
            .buttonStyle(.plain)
            .foregroundStyle(dialogAccent)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(maxWidth: 430)
        .background(dialogBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(dialogSecondaryText.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 20, x: 0, y: 12)
        .accessibilityIdentifier("textDisplayPreferenceEditorDialog")
    }

    /**
     Dispatches active editor content to the Android-equivalent widget body.

     - Parameter editor: Active preference editor whose controls should be shown.
     - Returns: Staged controls for the selected editor.
     - Side effects: Controls mutate only `preferenceEditorDraft`.
     - Failure modes: none.
     */
    @ViewBuilder
    private func preferenceEditorDialogContent(_ editor: TextDisplayPreferenceEditorKind) -> some View {
        switch editor {
        case .strongsMode:
            dialogChoiceList(
                options: strongsModeOptions,
                selection: draftIntBinding(\.strongsMode, fallback: 0)
            )
        case .fontSize:
            VStack(alignment: .leading, spacing: 14) {
                fontSampleText(size: displayedDraftFontSize)
                dialogNumericSlider(
                    title: String(
                        localized: "font_size_title",
                        defaultValue: "Font size"
                    ),
                    valueText: String.localizedStringWithFormat(
                        String(localized: "font_size_pt", defaultValue: "%d pt"),
                        displayedDraftFontSize
                    ),
                    binding: draftDoubleBinding(\.fontSize, fallback: TextDisplaySettings.appDefaults.fontSize ?? 16),
                    range: Double(Self.androidFontSizeRange.lowerBound)...Double(Self.androidFontSizeRange.upperBound),
                    step: Self.androidNumericSliderStep
                )
            }
        case .fontFamily:
            VStack(alignment: .leading, spacing: 14) {
                fontSampleText(size: displayedDraftFontSize)
                Text(String(localized: "pref_font_family_label", defaultValue: "Font family"))
                    .font(.callout)
                    .foregroundStyle(dialogPrimaryText)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Self.androidFontFamilyOptions()) { option in
                            fontFamilyChoiceRow(option)
                            Divider()
                                .background(dialogSecondaryText.opacity(0.18))
                        }
                    }
                }
                .frame(maxHeight: 260)
                .accessibilityIdentifier("textDisplayFontFamilyOptionList")
            }
        case .margins:
            VStack(alignment: .leading, spacing: 16) {
                dialogNumericSlider(
                    title: String(localized: "text_display_left_margin_label", defaultValue: "Left margin"),
                    valueText: millimeterValueText(displayedDraftMarginLeft),
                    binding: draftDoubleBinding(\.marginLeft, fallback: TextDisplaySettings.appDefaults.marginLeft ?? 3),
                    range: Double(Self.androidMarginRange.lowerBound)...Double(Self.androidMarginRange.upperBound),
                    step: Self.androidNumericSliderStep
                )
                dialogNumericSlider(
                    title: String(localized: "text_display_right_margin_label", defaultValue: "Right margin"),
                    valueText: millimeterValueText(displayedDraftMarginRight),
                    binding: draftDoubleBinding(\.marginRight, fallback: TextDisplaySettings.appDefaults.marginRight ?? 3),
                    range: Double(Self.androidMarginRange.lowerBound)...Double(Self.androidMarginRange.upperBound),
                    step: Self.androidNumericSliderStep
                )
                dialogNumericSlider(
                    title: String(localized: "text_display_max_width_label", defaultValue: "Maximum width of text"),
                    valueText: millimeterValueText(displayedDraftMaxWidth),
                    binding: draftDoubleBinding(\.maxWidth, fallback: TextDisplaySettings.appDefaults.maxWidth ?? 170),
                    range: Double(Self.androidMaxTextWidthRange.lowerBound)...Double(Self.androidMaxTextWidthRange.upperBound),
                    step: Self.androidNumericSliderStep
                )
            }
        case .topMargin:
            dialogNumericSlider(
                title: String(localized: "prefs_top_margin_title", defaultValue: "Top margin"),
                valueText: millimeterValueText(displayedDraftTopMargin),
                binding: draftDoubleBinding(\.topMargin, fallback: 0),
                range: Double(Self.androidTopMarginRange.lowerBound)...Double(Self.androidTopMarginRange.upperBound),
                step: Self.androidNumericSliderStep
            )
        case .lineSpacing:
            dialogNumericSlider(
                title: String(localized: "line_spacing_title", defaultValue: "Line spacing"),
                valueText: String.localizedStringWithFormat(
                    String(localized: "prefs_line_spacing_pt", defaultValue: "Line spacing %1.1fx"),
                    Double(displayedDraftLineSpacing) / 10.0
                ),
                binding: draftDoubleBinding(\.lineSpacing, fallback: TextDisplaySettings.appDefaults.lineSpacing ?? 16),
                range: Double(Self.androidLineSpacingRange.lowerBound)...Double(Self.androidLineSpacingRange.upperBound),
                step: Self.androidNumericSliderStep
            )
        case .pageScrollAmount:
            dialogChoiceList(
                options: pageScrollAmountOptions,
                selection: draftIntBinding(\.pageScrollAmount, fallback: 100)
            )
        }
    }

    /**
     Resolves the dialog title for one non-switch Android preference.

     - Parameter editor: Active editor selected by the user.
     - Returns: Android row title used as the dialog title.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func preferenceEditorTitle(_ editor: TextDisplayPreferenceEditorKind) -> String {
        switch editor {
        case .strongsMode:
            return androidTitle("STRONGS")
        case .fontSize:
            return androidTitle("FONTSIZE")
        case .fontFamily:
            return androidTitle("FONTFAMILY")
        case .margins:
            return androidTitle("MARGINSIZE")
        case .topMargin:
            return androidTitle("TOPMARGIN")
        case .lineSpacing:
            return androidTitle("LINE_SPACING")
        case .pageScrollAmount:
            return androidTitle("PAGE_SCROLL_AMOUNT")
        }
    }

    /**
     Builds a single-choice list matching Android `AlertDialog.setSingleChoiceItems`.

     - Parameters:
       - options: Value/label pairs in Android dialog order.
       - selection: Staged selection binding.
     - Returns: Scrollable radio-list rows for the dialog.
     - Side effects: Row taps mutate only `selection`.
     - Failure modes: Empty option arrays render an empty scroll region.
     */
    private func dialogChoiceList(
        options: [(value: Int, label: String)],
        selection: Binding<Int>
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(options, id: \.value) { option in
                    Button {
                        selection.wrappedValue = option.value
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: selection.wrappedValue == option.value ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(selection.wrappedValue == option.value ? dialogAccent : dialogSecondaryText)
                            Text(option.label)
                                .font(.body)
                                .foregroundStyle(dialogPrimaryText)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("textDisplayPreferenceChoice::\(option.value)")
                    .accessibilityValue(selection.wrappedValue == option.value ? "selected" : "unselected")
                    Divider()
                        .background(dialogSecondaryText.opacity(0.18))
                }
            }
        }
        .frame(maxHeight: 320)
    }

    /**
     Builds one Android-like numeric seekbar row for a staged dialog value.

     - Parameters:
       - title: User-visible setting label.
       - valueText: Current value text shown below the slider.
       - binding: Draft binding mutated by the slider.
       - range: Inclusive Android seekbar range.
       - step: Slider increment.
     - Returns: Labeled slider and current value text.
     - Side effects: Moving the slider mutates only `preferenceEditorDraft`.
     - Failure modes: Non-finite values are normalized by `draftDoubleBinding`.
     */
    private func dialogNumericSlider(
        title: String,
        valueText: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(dialogPrimaryText)
                Text(valueText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(dialogSecondaryText)
            }
            Slider(value: binding, in: range, step: step)
        }
    }

    /**
     Builds one row in the Android font-family selection list.

     - Parameter option: Font-family option from Android's widget list.
     - Returns: Tappable row with Android-style first-match selection semantics.
     - Side effects: Row taps mutate only `preferenceEditorDraft.fontFamily`.
     - Failure modes: Unknown font family names fall back to SwiftUI's default font rendering.
     */
    private func fontFamilyChoiceRow(_ option: TextDisplayFontFamilyOption) -> some View {
        let selectedIndex = Self.androidFontFamilySelectedIndex(for: preferenceEditorDraft.fontFamily)
        let isSelected = option.androidIndex == selectedIndex
        return Button {
            preferenceEditorDraft.fontFamily = option.value
        } label: {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? dialogAccent : dialogSecondaryText)
                Text(option.label)
                    .font(fontPreview(for: option.value, size: 16))
                    .foregroundStyle(dialogPrimaryText)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("textDisplayFontFamilyOption::\(option.androidIndex)")
        .accessibilityValue(isSelected ? "selected" : "unselected")
    }

    /**
     Builds Android's sample text preview for font-size and font-family dialogs.

     - Parameter size: Point size used for the sample.
     - Returns: Two-line preview text rendered with the draft font family.
     - Side effects: none.
     - Failure modes: Unknown Android font-family names fall back to SwiftUI system font rendering.
     */
    private func fontSampleText(size: Int) -> some View {
        Text(String(localized: "prefs_text_size_sample_text", defaultValue: "The quick brown fox jumps over the lazy dog."))
            .font(fontPreview(for: preferenceEditorDraft.fontFamily ?? "sans-serif", size: CGFloat(size)))
            .foregroundStyle(dialogSecondaryText)
            .lineLimit(2)
            .frame(height: 60, alignment: .bottomLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("textDisplayPreferenceEditorSampleText")
    }

    /**
     Resolves an Android font-family string to the nearest SwiftUI preview font.

     Android and iOS do not share platform font implementations, but the dialog should preview the
     broad design family instead of dumping every row into the same system font. Stored values remain
     the Android strings; this helper affects only visual preview.

     - Parameters:
       - family: Android font-family value.
       - size: Point size for the preview font.
     - Returns: SwiftUI font that approximates the Android family category.
     - Side effects: none.
     - Failure modes: Unknown values use the default system design.
     */
    private func fontPreview(for family: String, size: CGFloat) -> Font {
        if family.contains("monospace") || family == "monospace" {
            return .system(size: size, design: .monospaced)
        }
        if family == "serif" {
            return .system(size: size, design: .serif)
        }
        if family == "casual" || family == "cursive" {
            return .system(size: size, design: .rounded)
        }
        return .system(size: size)
    }

    /**
     Creates a staged integer binding for single-choice Android dialog rows.

     - Parameters:
       - keyPath: Draft optional integer field being edited.
       - fallback: Value used when the draft currently inherits from a parent scope.
     - Returns: Non-optional binding suitable for radio-list rows.
     - Side effects: Setting the binding mutates only `preferenceEditorDraft`.
     - Failure modes: none.
     */
    private func draftIntBinding(
        _ keyPath: WritableKeyPath<TextDisplayPreferenceEditorDraft, Int?>,
        fallback: Int
    ) -> Binding<Int> {
        Binding(
            get: { preferenceEditorDraft[keyPath: keyPath] ?? fallback },
            set: { preferenceEditorDraft[keyPath: keyPath] = $0 }
        )
    }

    /**
     Creates a staged numeric binding for Android seekbar-style dialog rows.

     - Parameters:
       - keyPath: Draft optional integer field being edited.
       - fallback: Value used when the draft currently inherits from a parent scope.
     - Returns: Slider-compatible binding that stores rounded integer values in the draft.
     - Side effects: Setting the binding mutates only `preferenceEditorDraft`.
     - Failure modes: Non-finite slider values preserve the current fallback through
       `sliderInteger`.
     */
    private func draftDoubleBinding(
        _ keyPath: WritableKeyPath<TextDisplayPreferenceEditorDraft, Int?>,
        fallback: Int
    ) -> Binding<Double> {
        Binding(
            get: { Double(preferenceEditorDraft[keyPath: keyPath] ?? fallback) },
            set: { preferenceEditorDraft[keyPath: keyPath] = Self.sliderInteger($0, fallback: fallback) }
        )
    }

    /// Draft font size shown in the active dialog.
    private var displayedDraftFontSize: Int {
        preferenceEditorDraft.fontSize ?? TextDisplaySettings.appDefaults.fontSize ?? 16
    }

    /// Draft left margin shown in the active dialog.
    private var displayedDraftMarginLeft: Int {
        preferenceEditorDraft.marginLeft ?? TextDisplaySettings.appDefaults.marginLeft ?? 3
    }

    /// Draft right margin shown in the active dialog.
    private var displayedDraftMarginRight: Int {
        preferenceEditorDraft.marginRight ?? TextDisplaySettings.appDefaults.marginRight ?? 3
    }

    /// Draft maximum text width shown in the active dialog.
    private var displayedDraftMaxWidth: Int {
        preferenceEditorDraft.maxWidth ?? TextDisplaySettings.appDefaults.maxWidth ?? 170
    }

    /// Draft top margin shown in the active dialog.
    private var displayedDraftTopMargin: Int {
        preferenceEditorDraft.topMargin ?? TextDisplaySettings.appDefaults.topMargin ?? 0
    }

    /// Draft line-spacing value clamped to Android's 10...30 seekbar range.
    private var displayedDraftLineSpacing: Int {
        min(
            max(
                preferenceEditorDraft.lineSpacing ?? TextDisplaySettings.appDefaults.lineSpacing ?? 16,
                Self.androidLineSpacingRange.lowerBound
            ),
            Self.androidLineSpacingRange.upperBound
        )
    }

    /**
     Formats a millimeter value using Android's value-label convention.

     - Parameter value: Integer millimeter value.
     - Returns: Localized value string for slider detail text.
     - Side effects: none.
     - Failure modes: Missing localization uses the default `"%d mm"` format.
     */
    private func millimeterValueText(_ value: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "value_mm", defaultValue: "%d mm"),
            value
        )
    }

    /**
     Commits the active staged editor values to persisted settings and closes the dialog.

     - Parameter editor: Dialog whose draft field group should be persisted.
     - Side effects: Mutates `settings`, invokes `onChange`, and dismisses the overlay.
     - Failure modes: none; draft values are normalized by their controls before commit.
     */
    private func commitPreferenceEditor(_ editor: TextDisplayPreferenceEditorKind) {
        preferenceEditorDraft.commit(editor, scope: scope, to: &settings)
        activePreferenceEditor = nil
        onChange?()
    }

    /**
     Applies Android's neutral Reset action for the active editor and closes the dialog.

     - Parameter editor: Dialog whose field group should reset.
     - Side effects: Mutates the draft, commits the reset value into `settings`, invokes `onChange`,
       and dismisses the overlay.
     - Failure modes: none.
     */
    private func resetPreferenceEditor(_ editor: TextDisplayPreferenceEditorKind) {
        preferenceEditorDraft.reset(editor, scope: scope)
        preferenceEditorDraft.commit(editor, scope: scope, to: &settings)
        activePreferenceEditor = nil
        onChange?()
    }

    /**
     Cancels the active editor without writing staged values.

     - Side effects: Dismisses the overlay and leaves `settings` unchanged.
     - Failure modes: none.
     */
    private func cancelPreferenceEditor() {
        activePreferenceEditor = nil
    }

    /// Android-dialog background color for the current system appearance.
    private var dialogBackground: Color {
        AndroidDialogSurfacePalette.background(for: colorScheme)
    }

    /// Android-dialog primary text color for the current system appearance.
    private var dialogPrimaryText: Color {
        AndroidDialogSurfacePalette.primaryText(for: colorScheme)
    }

    /// Android-dialog secondary text color for the current system appearance.
    private var dialogSecondaryText: Color {
        AndroidDialogSurfacePalette.secondaryText(for: colorScheme)
    }

    /// Android-dialog accent color for interactive editor actions.
    private var dialogAccent: Color {
        AndroidDialogSurfacePalette.accent(for: colorScheme)
    }

    /**
     Builds one Android-shaped text-display settings row label using Android dynamic icon metadata.

     - Parameters:
       - androidKey: `TextDisplaySettings.Types` name from Android `OptionsMenuItems.kt`.
       - title: Primary row title.
       - summary: Optional secondary row text.
       - detail: Optional tertiary state text.
       - isEnabled: Whether the row should render with enabled or disabled emphasis.
     - Returns: Shared row label aligned with Android preference geometry.
     - Side effects: Renders an image from the module bundle when the key has catalog metadata.
     - Failure modes: Unknown keys simply produce an un-iconed but aligned row.
     */
    private func textDisplayRowLabel(
        androidKey: String,
        title: String,
        summary: String? = nil,
        detail: String? = nil,
        isEnabled: Bool = true
    ) -> AndBibleSettingsRowLabel {
        AndBibleSettingsRowLabel(
            title: title,
            summary: summary,
            detail: detail,
            icon: AndBibleIconCatalog.settingsIcon(forAndroidKey: androidKey),
            isEnabled: isEnabled
        )
    }

    /**
     Builds an Android-shaped text-display section header using the active app accent color.

     - Parameter title: User-visible section title.
     - Returns: Section header aligned with row text rather than the icon column.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func textDisplaySectionHeader(_ title: String) -> AndBibleSettingsSectionHeader {
        AndBibleSettingsSectionHeader(title: title)
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

/**
 Nested Android `BOOKMARKS_HIDELABELS` picker backed by the persisted label catalog.

 - Parameters:
   - labels: User-visible labels available for hiding bookmark highlights.
   - hiddenLabelIds: Optional label IDs written into `TextDisplaySettings.bookmarksHideLabels`.
   - onChange: Callback invoked after each toggle mutation.
 - Returns: A SwiftUI list of label toggles with Android-style color swatches.
 - Side effects: Toggle changes mutate `hiddenLabelIds` and invoke `onChange`.
 - Failure modes: Missing labels produce an empty-state row instead of failing.
 */
private struct HiddenBookmarkLabelsView: View {
    /// User-visible labels available for hidden-bookmark filtering.
    let labels: [BibleCore.Label]

    /// Optional hidden label IDs persisted in text-display settings.
    @Binding var hiddenLabelIds: [UUID]?

    /// Callback invoked after a hidden-label mutation.
    var onChange: (() -> Void)?

    /// Stable set of label IDs visible in the current SwiftData query.
    private var visibleLabelIds: Set<UUID> {
        Set(labels.map(\.id))
    }

    /**
     Creates a toggle binding for one label while preserving hidden IDs that are not currently
     visible in the label picker.

     - Parameter label: Label whose hidden state should be edited.
     - Returns: Toggle binding backed by `hiddenLabelIds`.
     - Side effects: Writes a normalized hidden-label list and invokes `onChange`.
     - Failure modes: This helper cannot fail.
     */
    private func hiddenBinding(for label: BibleCore.Label) -> Binding<Bool> {
        Binding(
            get: { Set(hiddenLabelIds ?? []).contains(label.id) },
            set: { isHidden in
                var ids = hiddenLabelIds ?? []
                let preservedHiddenIds = ids.filter { !visibleLabelIds.contains($0) }
                let visibleHiddenIds = ids.filter { visibleLabelIds.contains($0) && $0 != label.id }
                ids = preservedHiddenIds + visibleHiddenIds
                if isHidden {
                    ids.append(label.id)
                }
                hiddenLabelIds = ids
                onChange?()
            }
        )
    }

    /**
     Builds the hidden-label picker list.
     */
    var body: some View {
        List {
            if labels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "no_labels", defaultValue: "No labels"))
                        .font(.body)
                    Text(
                        String(
                            localized: "no_labels_to_hide_summary",
                            defaultValue: "Create labels before hiding bookmark highlights by label."
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(labels, id: \.id) { label in
                    Toggle(isOn: hiddenBinding(for: label)) {
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color(argbInt: label.color))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                                )
                            Text(label.name)
                        }
                    }
                    .accessibilityIdentifier("textDisplayHiddenBookmarkLabel::\(label.id.uuidString)")
                }
            }
        }
        .accessibilityIdentifier("textDisplayHiddenBookmarkLabelsScreen")
        .navigationTitle(String(localized: "hide_labels", defaultValue: "Hide labels"))
    }
}
