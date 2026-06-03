// TextDisplaySettingsView.swift — Text display settings

import SwiftUI
import BibleCore
import SwiftData
#if os(iOS)
import UIKit
#endif

/**
 Form-driven editor for text presentation settings used by the Bible reader.

 The view exposes the Android All Text Options rows that already have complete iOS model, bridge,
 and renderer support. Unsupported Android rows stay documented in
 `TextDisplaySettingsPresentation` instead of appearing as inert controls.

 Data dependencies:
 - `settings` is the persisted display-settings model owned by the parent screen
 - SwiftData labels back the Android `BOOKMARKS_HIDELABELS` picker
 - `onChange` lets the parent push updated settings into the reader after each mutation

 Side effects:
 - every binding write mutates `settings` and invokes `onChange`
 - hidden bookmark-label choices mutate `settings.bookmarksHideLabels`
 - on iOS, presenting the font picker bridges into `UIFontPickerViewController`
 */
public struct TextDisplaySettingsView: View {
    /// Shared text display settings being edited by the form.
    @Binding var settings: TextDisplaySettings

    /// Callback invoked after any user-visible settings mutation.
    var onChange: (() -> Void)?

    /// User-visible and system labels available for the hidden-bookmark-label picker.
    @Query private var allLabels: [BibleCore.Label]

    #if os(iOS)
    /// Whether the native iOS font picker sheet is currently presented.
    @State private var showFontPicker = false
    #endif

    /// Inclusive Android-backed slider bounds used by `LINE_SPACING`.
    private static let lineSpacingRange: ClosedRange<Int> = 10...30

    /**
     Creates a text-display settings editor bound to a persisted settings model.

     - Parameters:
       - settings: Shared display settings value to mutate from the form.
       - onChange: Optional callback invoked after any setting changes.
     */
    public init(settings: Binding<TextDisplaySettings>, onChange: (() -> Void)? = nil) {
        self._settings = settings
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

    /// Human-readable current font label used by the iOS font picker row.
    private var currentFontName: String {
        let family = settings.fontFamily ?? "sans-serif"
        if family == "sans-serif" { return "Sans Serif (Default)" }
        if family == "serif" { return "Serif" }
        if family == "monospace" { return "Monospace" }
        return family
    }

    /// Accessibility-exported state for the currently edited justify-text preference.
    private var accessibilityState: String {
        let justifyState = (settings.justifyText ?? false) ? "justifyTextOn" : "justifyTextOff"
        #if os(iOS)
        let fontPickerState = showFontPicker ? "fontPickerPresented" : "fontPickerHidden"
        return "\(justifyState)|\(fontPickerState)"
        #else
        return "\(justifyState)|fontPickerUnavailable"
        #endif
    }

    /**
     Builds the Android-ordered text-display settings form.
     */
    public var body: some View {
        Form {
            Section {
                NavigationLink {
                    ColorSettingsView(settings: $settings, onChange: onChange)
                } label: {
                    textDisplayRowLabel(
                        androidKey: "COLORS",
                        title: String(localized: "colors", defaultValue: "Colors"),
                        summary: String(
                            localized: "prefs_colors_summary",
                            defaultValue: "Configure reader text and background colors"
                        )
                    )
                }
                .accessibilityIdentifier("textDisplayColorsLink")

                VStack(alignment: .leading, spacing: 8) {
                    textDisplayRowLabel(
                        androidKey: "FONTSIZE",
                        title: String(localized: "font_size"),
                        summary: String(
                            format: String(
                                localized: "prefs_font_text_size_summary",
                                defaultValue: "Set the text size. Current value: %d"
                            ),
                            settings.fontSize ?? 18
                        )
                    )
                    Slider(value: fontSizeBinding, in: 1...60, step: 1)
                        .padding(.leading, 66)
                }
                #if os(iOS)
                Button {
                    showFontPicker = true
                } label: {
                    textDisplayRowLabel(
                        androidKey: "FONTFAMILY",
                        title: String(localized: "font_family"),
                        summary: String(
                            localized: "prefs_font_family_summary",
                            defaultValue: "Choose font family"
                        ),
                        detail: currentFontName
                    )
                }
                .accessibilityIdentifier("textDisplayFontFamilyButton")
                .sheet(isPresented: $showFontPicker) {
                    FontPickerView(selectedFamily: fontFamilyBinding)
                }
                #else
                Picker(selection: fontFamilyBinding) {
                    ForEach(Self.fontOptions, id: \.value) { option in
                        Text(option.label)
                            .font(.custom(option.previewFont, size: 16))
                            .tag(option.value)
                    }
                } label: {
                    textDisplayRowLabel(
                        androidKey: "FONTFAMILY",
                        title: String(localized: "font_family"),
                        summary: String(
                            localized: "prefs_font_family_summary",
                            defaultValue: "Choose font family"
                        ),
                        detail: currentFontName
                    )
                }
                #endif

                VStack(alignment: .leading, spacing: 8) {
                    textDisplayRowLabel(
                        androidKey: "LINE_SPACING",
                        title: String(localized: "line_spacing"),
                        summary: String(
                            format: String(
                                localized: "line_spacing_summary",
                                defaultValue: "Set the space between lines. Current value: %d"
                            ),
                            displayedLineSpacing
                        )
                    )
                    Slider(
                        value: lineSpacingBinding,
                        in: Double(Self.lineSpacingRange.lowerBound)...Double(Self.lineSpacingRange.upperBound),
                        step: 1
                    )
                        .padding(.leading, 66)
                }

                Toggle(isOn: boolBinding(\.showRedLetters, default: true)) {
                    textDisplayRowLabel(
                        androidKey: "REDLETTERS",
                        title: String(localized: "red_letters"),
                        summary: String(
                            localized: "prefs_red_letter_summary",
                            defaultValue: "Show words of Christ in red"
                        )
                    )
                }
            } header: {
                textDisplaySectionHeader(String(localized: "prefs_font_and_colors_title", defaultValue: "Font and colors"))
            }

            Section {
                let justifyTextBinding = boolBinding(\.justifyText, default: false)
                VStack(alignment: .leading, spacing: 8) {
                    textDisplayRowLabel(
                        androidKey: "MARGINSIZE",
                        title: String(localized: "margins", defaultValue: "Margins"),
                        summary: String(
                            localized: "prefs_margins_summary",
                            defaultValue: "Set reader side margins and maximum text width"
                        )
                    )
                    VStack(alignment: .leading, spacing: 10) {
                        marginSlider(
                            title: String(localized: "left_margin", defaultValue: "Left"),
                            value: settings.marginLeft ?? 2,
                            binding: marginLeftBinding,
                            range: 0...30,
                            step: 1
                        )
                        marginSlider(
                            title: String(localized: "right_margin", defaultValue: "Right"),
                            value: settings.marginRight ?? 2,
                            binding: marginRightBinding,
                            range: 0...30,
                            step: 1
                        )
                        marginSlider(
                            title: String(localized: "max_width", defaultValue: "Max width"),
                            value: settings.maxWidth ?? 600,
                            binding: maxWidthBinding,
                            range: 0...1000,
                            step: 10
                        )
                    }
                    .padding(.leading, 66)
                }

                VStack(alignment: .leading, spacing: 8) {
                    textDisplayRowLabel(
                        androidKey: "TOPMARGIN",
                        title: String(localized: "top_margin", defaultValue: "Top margin"),
                        summary: String(
                            format: String(
                                localized: "top_margin_summary",
                                defaultValue: "Set the top margin. Current value: %d"
                            ),
                            settings.topMargin ?? 0
                        )
                    )
                    Slider(value: topMarginBinding, in: 0...60, step: 1)
                        .padding(.leading, 66)
                }

                HStack(alignment: .top, spacing: 12) {
                    Button {
                        justifyTextBinding.wrappedValue.toggle()
                    } label: {
                        textDisplayRowLabel(
                            androidKey: "JUSTIFY",
                            title: String(localized: "justify_text"),
                            summary: String(
                                localized: "prefs_justify_summary",
                                defaultValue: "Align text in justify style, meaning left and right margins of the text are in line"
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("textDisplayJustifyTextToggleButton")

                    Toggle("", isOn: justifyTextBinding)
                        .labelsHidden()
                        .accessibilityIdentifier("textDisplayJustifyTextToggle")
                        .accessibilityValue((settings.justifyText ?? false) ? "justifyTextOn" : "justifyTextOff")
                }
                Toggle(isOn: boolBinding(\.showVersePerLine, default: false)) {
                    textDisplayRowLabel(
                        androidKey: "VERSEPERLINE",
                        title: String(localized: "verse_per_line"),
                        summary: String(
                            localized: "prefs_verse_per_line_summary",
                            defaultValue: "Show each verse on a different line"
                        )
                    )
                }
                Toggle(isOn: boolBinding(\.hyphenation, default: true)) {
                    textDisplayRowLabel(
                        androidKey: "HYPHENATION",
                        title: String(localized: "hyphenation"),
                        summary: String(
                            localized: "prefs_hyphenation_summary",
                            defaultValue: "Automatically hyphenate words, if language is supported"
                        )
                    )
                }
            } header: {
                textDisplaySectionHeader(String(localized: "prefs_text_layout_title", defaultValue: "Text layout"))
            }

            Section {
                Picker(selection: Binding(
                    get: { settings.strongsMode ?? 0 },
                    set: { settings.strongsMode = $0; onChange?() }
                )) {
                    Text(String(localized: "off")).tag(0)
                    Text(String(localized: "inline")).tag(1)
                    Text(String(localized: "links")).tag(2)
                    Text(String(localized: "hidden")).tag(3)
                } label: {
                    textDisplayRowLabel(
                        androidKey: "STRONGS",
                        title: String(localized: "strongs_numbers"),
                        summary: String(
                            localized: "prefs_show_strongs_summary",
                            defaultValue: "Links to Greek and Hebrew definitions"
                        )
                    )
                }
                Toggle(isOn: boolBinding(\.showMorphology, default: false)) {
                    textDisplayRowLabel(
                        androidKey: "MORPH",
                        title: String(localized: "morphology"),
                        summary: String(
                            localized: "prefs_show_morphology_summary",
                            defaultValue: "Show Robinson's Greek morphology"
                        )
                    )
                }
            } header: {
                textDisplaySectionHeader(
                    String(localized: "prefs_strongs_and_morphology_title", defaultValue: "Strong's and morphology")
                )
            }

            Section {
                let footnotesBinding = boolBinding(\.showFootNotes, default: false)
                let xrefsBinding = boolBinding(\.showXrefs, default: false)
                Toggle(isOn: footnotesBinding) {
                    textDisplayRowLabel(
                        androidKey: "FOOTNOTES",
                        title: String(localized: "footnotes"),
                        summary: String(
                            localized: "prefs_show_footnotes_summary",
                            defaultValue: "Show footnotes, if they are available in the document"
                        )
                    )
                }
                Toggle(isOn: boolBinding(\.showFootNotesInline, default: false)) {
                    textDisplayRowLabel(
                        androidKey: "FOOTNOTES_INLINE",
                        title: String(localized: "inline_footnotes"),
                        summary: String(
                            localized: "prefs_show_footnotes_inline_summary",
                            defaultValue: "Show footnotes inline with the text instead of as clickable handles"
                        ),
                        isEnabled: footnotesBinding.wrappedValue
                    )
                }
                .disabled(!footnotesBinding.wrappedValue)

                Toggle(isOn: xrefsBinding) {
                    textDisplayRowLabel(
                        androidKey: "XREFS",
                        title: String(localized: "cross_references"),
                        summary: String(
                            localized: "prefs_show_xrefs_summary",
                            defaultValue: "Show cross references, if they are available in the document"
                        )
                    )
                }
                Toggle(isOn: boolBinding(\.expandXrefs, default: false)) {
                    textDisplayRowLabel(
                        androidKey: "EXPAND_XREFS",
                        title: String(localized: "expand_cross_references"),
                        summary: String(
                            localized: "prefs_expand_footnotes_summary",
                            defaultValue: "Show cross reference content inline within the text, instead of a link that opens a pop-up dialog"
                        ),
                        isEnabled: xrefsBinding.wrappedValue
                    )
                }
                .disabled(!xrefsBinding.wrappedValue)
            } header: {
                textDisplaySectionHeader(
                    String(localized: "prefs_footnotes_and_xrefs_title", defaultValue: "Footnotes and cross references")
                )
            }

            Section {
                Toggle(isOn: boolBinding(\.showVerseNumbers, default: true)) {
                    textDisplayRowLabel(
                        androidKey: "VERSENUMBERS",
                        title: String(localized: "verse_numbers"),
                        summary: String(
                            localized: "prefs_show_verseno_summary",
                            defaultValue: "Show verse numbers"
                        )
                    )
                }
                Toggle(isOn: boolBinding(\.showSectionTitles, default: true)) {
                    textDisplayRowLabel(
                        androidKey: "SECTIONTITLES",
                        title: String(localized: "section_titles"),
                        summary: String(
                            localized: "prefs_section_title_summary",
                            defaultValue: "Show non-canonical section titles"
                        )
                    )
                }
                Toggle(isOn: boolBinding(\.showPageNumber, default: false)) {
                    textDisplayRowLabel(
                        androidKey: "PAGENUMBER",
                        title: String(localized: "page_number", defaultValue: "Page number"),
                        summary: String(
                            localized: "prefs_page_number_summary",
                            defaultValue: "Show page numbers when available"
                        )
                    )
                }
            } header: {
                textDisplaySectionHeader(
                    String(localized: "prefs_verses_and_headings_title", defaultValue: "Verses and headings")
                )
            }

            Section {
                Toggle(isOn: boolBinding(\.showBookmarks, default: true)) {
                    textDisplayRowLabel(
                        androidKey: "BOOKMARKS_SHOW",
                        title: String(localized: "show_bookmarks"),
                        summary: String(
                            localized: "prefs_show_bookmarks_summary",
                            defaultValue: "Uncheck to hide all bookmarks"
                        )
                    )
                }
                Toggle(isOn: boolBinding(\.showMyNotes, default: true)) {
                    textDisplayRowLabel(
                        androidKey: "MYNOTES",
                        title: String(localized: "show_my_notes"),
                        summary: String(
                            localized: "prefs_show_mynotes_summary",
                            defaultValue: "Show icon in verses with My Note"
                        )
                    )
                }
                NavigationLink {
                    HiddenBookmarkLabelsView(
                        labels: userLabels,
                        hiddenLabelIds: bookmarksHideLabelsBinding,
                        onChange: onChange
                    )
                } label: {
                    textDisplayRowLabel(
                        androidKey: "BOOKMARKS_HIDELABELS",
                        title: String(localized: "hide_labels", defaultValue: "Hide labels"),
                        summary: String(
                            localized: "prefs_bookmarks_hide_labels_summary",
                            defaultValue: "Hide bookmarks assigned to selected labels"
                        ),
                        detail: hiddenBookmarkLabelsDetail
                    )
                }
                .accessibilityIdentifier("textDisplayHiddenBookmarkLabelsLink")
            } header: {
                textDisplaySectionHeader(String(localized: "prefs_text_bookmarks_title", defaultValue: "Text bookmarks"))
            }
        }
        .accessibilityIdentifier("textDisplaySettingsScreen")
        .accessibilityValue(accessibilityState)
        .navigationTitle(String(localized: "text_display"))
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
