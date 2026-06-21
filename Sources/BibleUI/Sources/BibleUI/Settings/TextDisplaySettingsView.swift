// TextDisplaySettingsView.swift — Text display settings

import SwiftUI
import BibleCore
import SwiftData
#if os(iOS)
import UIKit
#endif

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
 - `workspaceColor`, when supplied by workspace-scoped callers, exposes Android's workspace accent
   row from the nested color editor while keeping that metadata separate from inherited text-display
   settings
 - `scope` determines which Android parent-scope links are visible
 - SwiftData labels back the Android `BOOKMARKS_HIDELABELS` picker
 - `onChange` lets the parent push updated settings into the reader after each mutation

 Side effects:
 - every binding write mutates `settings` and invokes `onChange`
 - parent-scope link taps invoke parent routing closures without mutating `settings`
 - hidden bookmark-label choices mutate `settings.bookmarksHideLabels`
 - on iOS, presenting the font picker bridges into `UIFontPickerViewController`
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

    /**
     Non-switch Android preferences whose value editors are presented from the flat row list.

     Android keeps these controls as rows and opens a dialog or activity when the user taps them.
     The enum tracks the active SwiftUI editor sheet without changing the persisted settings model.
     */
    private enum ActivePreferenceEditor: String, Identifiable {
        /// Android `STRONGS` single-choice editor.
        case strongsMode

        /// Android `FONTSIZE` numeric editor.
        case fontSize

        /// Android `FONTFAMILY` editor used by the macOS fallback.
        case fontFamily

        /// Android `MARGINSIZE` multi-field numeric editor.
        case margins

        /// Android `TOPMARGIN` numeric editor.
        case topMargin

        /// Android `LINE_SPACING` numeric editor.
        case lineSpacing

        /// Android `PAGE_SCROLL_AMOUNT` single-choice editor.
        case pageScrollAmount

        /// Stable identity for SwiftUI sheet presentation.
        var id: String { rawValue }
    }

    #if os(iOS)
    /// Whether the native iOS font picker sheet is currently presented.
    @State private var showFontPicker = false
    #endif

    /// Active non-switch preference editor sheet, if one is open.
    @State private var activePreferenceEditor: ActivePreferenceEditor?

    /// Inclusive Android-backed slider bounds used by `LINE_SPACING`.
    private static let lineSpacingRange: ClosedRange<Int> = 10...30

    /**
     Creates a text-display settings editor bound to a persisted settings model.

     - Parameters:
       - settings: Shared display settings value to mutate from the form.
       - workspaceColor: Optional workspace accent color edited from Android's color settings
         screen. Supplying this binding exposes the workspace color row for workspace-owned routes;
         omitting it keeps true global/window routes from mutating workspace metadata.
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

    /// Slider binding that maps the optional stored font size to a concrete numeric control.
    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(settings.fontSize ?? 18) },
            set: { settings.fontSize = Self.sliderInteger($0, fallback: settings.fontSize ?? 18); onChange?() }
        )
    }

    /// Picker binding that maps the optional stored font family to a concrete selection value.
    private var fontFamilyBinding: Binding<String> {
        Binding(
            get: { settings.fontFamily ?? "sans-serif" },
            set: { settings.fontFamily = $0; onChange?() }
        )
    }

    /// Single-choice binding for Android's `STRONGS` preference editor.
    private var strongsModeBinding: Binding<Int> {
        Binding(
            get: { settings.strongsMode ?? 0 },
            set: { settings.strongsMode = $0; onChange?() }
        )
    }

    /// Single-choice binding for Android's `PAGE_SCROLL_AMOUNT` preference editor.
    private var pageScrollAmountBinding: Binding<Int> {
        Binding(
            get: { TextDisplaySettings.normalizedPageScrollAmount(settings.pageScrollAmount) },
            set: {
                settings.pageScrollAmount = TextDisplaySettings.normalizedPageScrollAmount($0)
                onChange?()
            }
        )
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
        min(max(settings.lineSpacing ?? 10, Self.lineSpacingRange.lowerBound), Self.lineSpacingRange.upperBound)
    }

    /// Slider binding that maps the optional stored line spacing to a concrete numeric control.
    private var lineSpacingBinding: Binding<Double> {
        Binding(
            get: { Double(displayedLineSpacing) },
            set: { settings.lineSpacing = Self.sliderInteger($0, fallback: displayedLineSpacing); onChange?() }
        )
    }

    /// Left margin slider binding backed by the Android `MARGINSIZE` setting.
    private var marginLeftBinding: Binding<Double> {
        Binding(
            get: { Double(settings.marginLeft ?? 2) },
            set: { settings.marginLeft = Self.sliderInteger($0, fallback: settings.marginLeft ?? 2); onChange?() }
        )
    }

    /// Right margin slider binding backed by the Android `MARGINSIZE` setting.
    private var marginRightBinding: Binding<Double> {
        Binding(
            get: { Double(settings.marginRight ?? 2) },
            set: { settings.marginRight = Self.sliderInteger($0, fallback: settings.marginRight ?? 2); onChange?() }
        )
    }

    /// Maximum text width slider binding backed by the Android `MARGINSIZE` setting.
    private var maxWidthBinding: Binding<Double> {
        Binding(
            get: { Double(settings.maxWidth ?? 600) },
            set: { settings.maxWidth = Self.sliderInteger($0, fallback: settings.maxWidth ?? 600); onChange?() }
        )
    }

    /// Top margin slider binding backed by the Android `TOPMARGIN` setting.
    private var topMarginBinding: Binding<Double> {
        Binding(
            get: { Double(settings.topMargin ?? 0) },
            set: { settings.topMargin = Self.sliderInteger($0, fallback: settings.topMargin ?? 0); onChange?() }
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
            settings.fontSize ?? 18
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
            settings.marginLeft ?? 2,
            settings.marginRight ?? 2,
            settings.maxWidth ?? 600
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
        #if os(iOS)
        let fontPickerState = showFontPicker ? "fontPickerPresented" : "fontPickerHidden"
        return "\(justifyState)|\(fontPickerState)|scope=\(scope.rawValue)"
        #else
        return "\(justifyState)|fontPickerUnavailable|scope=\(scope.rawValue)"
        #endif
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
                            activePreferenceEditor = .strongsMode
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
                            activePreferenceEditor = .fontSize
                        }

                        #if os(iOS)
                        preferenceActionRow(
                            androidKey: "FONTFAMILY",
                            title: fontFamilyTitle,
                            summary: androidSummary("FONTFAMILY"),
                            accessibilityIdentifier: "textDisplayFontFamilyButton"
                        ) {
                            showFontPicker = true
                        }
                        #else
                        preferenceActionRow(
                            androidKey: "FONTFAMILY",
                            title: fontFamilyTitle,
                            summary: androidSummary("FONTFAMILY"),
                            accessibilityIdentifier: "textDisplayFontFamilyButton"
                        ) {
                            activePreferenceEditor = .fontFamily
                        }
                        #endif

                        preferenceActionRow(
                            androidKey: "MARGINSIZE",
                            title: marginSizeTitle,
                            summary: androidSummary("MARGINSIZE"),
                            accessibilityIdentifier: "textDisplayMarginSizeButton"
                        ) {
                            activePreferenceEditor = .margins
                        }
                        preferenceActionRow(
                            androidKey: "TOPMARGIN",
                            title: topMarginTitle,
                            summary: androidSummary("TOPMARGIN"),
                            accessibilityIdentifier: "textDisplayTopMarginButton"
                        ) {
                            activePreferenceEditor = .topMargin
                        }
                        preferenceActionRow(
                            androidKey: "LINE_SPACING",
                            title: lineSpacingTitle,
                            summary: androidSummary("LINE_SPACING"),
                            accessibilityIdentifier: "textDisplayLineSpacingButton"
                        ) {
                            activePreferenceEditor = .lineSpacing
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
                            activePreferenceEditor = .pageScrollAmount
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
        }
        .background(textDisplayScreenBackground.ignoresSafeArea())
        .navigationTitle(navigationTitleText)
        .sheet(item: $activePreferenceEditor) { editor in
            preferenceEditorSheet(editor)
        }
        #if os(iOS)
        .sheet(isPresented: $showFontPicker) {
            FontPickerView(selectedFamily: fontFamilyBinding)
        }
        #endif
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
     Presents the editor for a non-switch Android preference.

     - Parameter editor: Active preference editor selected from the flat row list.
     - Returns: Navigation-wrapped editor content suitable for a SwiftUI sheet.
     - Side effects: Slider and picker writes mutate `settings`; Done clears presentation state.
     - Failure modes: This helper does not throw; invalid slider input is normalized by bindings.
     */
    private func preferenceEditorSheet(_ editor: ActivePreferenceEditor) -> some View {
        NavigationStack {
            Form {
                switch editor {
                case .strongsMode:
                    Picker(androidTitle("STRONGS"), selection: strongsModeBinding) {
                        ForEach(strongsModeOptions, id: \.value) { option in
                            Text(option.label)
                                .tag(option.value)
                        }
                    }
                    .pickerStyle(.inline)
                case .fontSize:
                    numericSlider(
                        title: fontSizeTitle,
                        value: settings.fontSize ?? 18,
                        binding: fontSizeBinding,
                        range: 1...60,
                        step: 1
                    )
                case .fontFamily:
                    Picker(androidTitle("FONTFAMILY"), selection: fontFamilyBinding) {
                        ForEach(Self.fontOptions, id: \.value) { option in
                            Text(option.label)
                                .font(.custom(option.previewFont, size: 16))
                                .tag(option.value)
                        }
                    }
                case .margins:
                    marginSlider(
                        title: String.localizedStringWithFormat(
                            String(
                                localized: "text_display_left_margin_title_format",
                                defaultValue: "Left margin (%d mm)"
                            ),
                            settings.marginLeft ?? 2
                        ),
                        value: settings.marginLeft ?? 2,
                        binding: marginLeftBinding,
                        range: 0...30,
                        step: 1
                    )
                    marginSlider(
                        title: String.localizedStringWithFormat(
                            String(
                                localized: "text_display_right_margin_title_format",
                                defaultValue: "Right margin (%d mm)"
                            ),
                            settings.marginRight ?? 2
                        ),
                        value: settings.marginRight ?? 2,
                        binding: marginRightBinding,
                        range: 0...30,
                        step: 1
                    )
                    marginSlider(
                        title: String.localizedStringWithFormat(
                            String(
                                localized: "text_display_max_width_title_format",
                                defaultValue: "Maximum width of text (%d mm)"
                            ),
                            settings.maxWidth ?? 600
                        ),
                        value: settings.maxWidth ?? 600,
                        binding: maxWidthBinding,
                        range: 0...1000,
                        step: 10
                    )
                case .topMargin:
                    numericSlider(
                        title: topMarginTitle,
                        value: settings.topMargin ?? 0,
                        binding: topMarginBinding,
                        range: 0...60,
                        step: 1
                    )
                case .lineSpacing:
                    numericSlider(
                        title: lineSpacingTitle,
                        value: displayedLineSpacing,
                        binding: lineSpacingBinding,
                        range: Double(Self.lineSpacingRange.lowerBound)...Double(Self.lineSpacingRange.upperBound),
                        step: 1
                    )
                case .pageScrollAmount:
                    Picker(androidTitle("PAGE_SCROLL_AMOUNT"), selection: pageScrollAmountBinding) {
                        ForEach(pageScrollAmountOptions, id: \.value) { option in
                            Text(option.label)
                                .tag(option.value)
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle(preferenceEditorTitle(editor))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done", defaultValue: "Done")) {
                        activePreferenceEditor = nil
                    }
                }
            }
        }
    }

    /**
     Resolves the editor sheet title for one non-switch Android preference.

     - Parameter editor: Active editor selected by the user.
     - Returns: Android row title used as the sheet title.
     - Side effects: none.
     - Failure modes: This helper cannot fail.
     */
    private func preferenceEditorTitle(_ editor: ActivePreferenceEditor) -> String {
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
     Builds a generic labeled numeric slider for editor sheets.

     - Parameters:
       - title: User-visible slider title.
       - value: Current integer value displayed beside the title.
       - binding: Slider binding that persists value changes.
       - range: Allowed slider range.
       - step: Slider increment.
     - Returns: A compact editor row for one numeric preference value.
     - Side effects: Moving the slider mutates `binding`.
     - Failure modes: This helper cannot fail; non-finite values are handled by the binding setter.
     */
    private func numericSlider(
        title: String,
        value: Int,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range, step: step)
        }
        .padding(.vertical, 4)
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

    /**
     Builds one numeric slider row nested beneath the Android `MARGINSIZE` label.

     - Parameters:
       - title: User-visible subfield title.
       - value: Current numeric value shown beside the subfield.
       - binding: Slider binding that writes back into `TextDisplaySettings`.
       - range: Allowed slider range.
       - step: Slider increment.
     - Returns: A compact labeled slider aligned beneath the parent row text.
     - Side effects: Mutating the slider writes through `binding`.
     - Failure modes: This helper cannot fail.
     */
    private func marginSlider(
        title: String,
        value: Int,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.callout)
                Spacer()
                Text("\(value)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range, step: step)
        }
    }

    /**
     Static font option descriptor used by the macOS fallback picker.
     */
    private struct FontOption {
        /// User-visible label shown in the picker.
        let label: String

        /// Stored font-family value written back to `TextDisplaySettings`.
        let value: String

        /// Preview font name used to render the picker label.
        let previewFont: String
    }

    /// MacOS fallback font-family choices used when the UIKit font picker is unavailable.
    private static let fontOptions: [FontOption] = [
        FontOption(label: "Sans Serif (Default)", value: "sans-serif", previewFont: ".AppleSystemUIFont"),
        FontOption(label: "Serif", value: "serif", previewFont: "Georgia"),
        FontOption(label: "Georgia", value: "Georgia", previewFont: "Georgia"),
        FontOption(label: "Palatino", value: "Palatino", previewFont: "Palatino"),
        FontOption(label: "Times New Roman", value: "Times New Roman", previewFont: "TimesNewRomanPSMT"),
        FontOption(label: "Baskerville", value: "Baskerville", previewFont: "Baskerville"),
        FontOption(label: "Didot", value: "Didot", previewFont: "Didot"),
        FontOption(label: "American Typewriter", value: "American Typewriter", previewFont: "AmericanTypewriter"),
        FontOption(label: "Courier New", value: "Courier New", previewFont: "CourierNewPSMT"),
        FontOption(label: "Menlo", value: "Menlo", previewFont: "Menlo-Regular"),
        FontOption(label: "Monospace", value: "monospace", previewFont: "Menlo-Regular"),
    ]
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

// MARK: - UIFontPickerViewController Wrapper (iOS only)

#if os(iOS)
/**
 UIKit bridge that presents the native iOS font picker and writes the selected family name back to
 the SwiftUI settings form.
 */
private struct FontPickerView: UIViewControllerRepresentable {
    /// Bound font family updated when the user chooses a font.
    @Binding var selectedFamily: String

    /// Dismiss action used to close the presented picker sheet.
    @Environment(\.dismiss) private var dismiss

    /// Creates the configured UIKit font picker controller.
    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let config = UIFontPickerViewController.Configuration()
        config.includeFaces = false
        let picker = UIFontPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    /// No-op updater because the UIKit picker is configured once during presentation.
    func updateUIViewController(_ uiViewController: UIFontPickerViewController, context: Context) {}

    /// Creates the delegate coordinator that forwards picker events back into SwiftUI.
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /**
     Delegate bridge that handles UIKit font-picker callbacks.
     */
    class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        /// Parent SwiftUI wrapper updated by UIKit delegate callbacks.
        let parent: FontPickerView

        /// Creates a coordinator bound to one picker wrapper instance.
        init(_ parent: FontPickerView) {
            self.parent = parent
        }

        /// Writes the selected font family back into the SwiftUI binding and dismisses the sheet.
        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            guard let descriptor = viewController.selectedFontDescriptor else { return }
            if let family = descriptor.object(forKey: .family) as? String {
                parent.selectedFamily = family
            }
            parent.dismiss()
        }

        /// Dismisses the picker without mutating the selected font family.
        func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
            parent.dismiss()
        }
    }
}
#endif
