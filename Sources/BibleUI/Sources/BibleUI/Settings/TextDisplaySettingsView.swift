// TextDisplaySettingsView.swift — Text display settings

import SwiftUI
import BibleCore
import SwiftData
#if os(iOS)
import UIKit
#endif

/**
 Form-driven editor for text presentation settings used by the Bible reader.

 The view renders Android's All Text Options category and row inventory. Rows that already have a
 complete iOS model, bridge, and renderer path are interactive; Android rows that are not yet backed
 on iOS remain visible in their Android position but disabled.

 Data dependencies:
 - `settings` is the persisted display-settings model owned by the parent screen
 - SwiftData labels back the Android `BOOKMARKS_HIDELABELS` picker
 - `workspaceSettings` optionally backs Android's window-scope parent link to workspace text options
 - `globalSettings` optionally backs Android's window/workspace parent link to global text options
 - `onChange` lets the parent push updated settings into the reader after each mutation

 Side effects:
 - every binding write mutates `settings` and invokes `onChange`
 - hidden bookmark-label choices mutate `settings.bookmarksHideLabels`
 - workspace/global parent-link edits mutate their supplied bindings
 - on iOS, presenting the font picker bridges into `UIFontPickerViewController`
 */
public struct TextDisplaySettingsView: View {
    /// Shared text display settings being edited by the form.
    @Binding var settings: TextDisplaySettings

    /// Callback invoked after any user-visible settings mutation.
    var onChange: (() -> Void)?

    /// Optional workspace text-display binding used by Android's window-level parent section.
    private let workspaceSettings: Binding<TextDisplaySettings>?

    /// User-visible workspace name used in Android's window-level parent link title.
    private let workspaceName: String?

    /// Callback invoked after workspace parent-link settings mutate.
    private let onWorkspaceSettingsChanged: (() -> Void)?

    /// Optional global text-display binding used by Android's workspace-level parent section.
    private let globalSettings: Binding<TextDisplaySettings>?

    /// Callback invoked after global parent-link settings mutate.
    private let onGlobalSettingsChanged: (() -> Void)?

    /// Navigation title that reflects the Android settings scope currently being edited.
    private let navigationTitleText: String

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
       - workspaceSettings: Optional workspace text-display settings for the window-scope parent link.
       - workspaceName: Workspace name used in Android's dynamic parent-link title.
       - globalSettings: Optional global text-display settings for the Android parent link.
       - navigationTitle: Android-scope title shown by the surrounding navigation stack.
       - onChange: Optional callback invoked after current-scope setting changes.
       - onWorkspaceSettingsChanged: Optional callback invoked after workspace parent-link changes.
       - onGlobalSettingsChanged: Optional callback invoked after global parent-link changes.
     */
    public init(
        settings: Binding<TextDisplaySettings>,
        workspaceSettings: Binding<TextDisplaySettings>? = nil,
        workspaceName: String? = nil,
        globalSettings: Binding<TextDisplaySettings>? = nil,
        navigationTitle: String = "Global text options",
        onChange: (() -> Void)? = nil,
        onWorkspaceSettingsChanged: (() -> Void)? = nil,
        onGlobalSettingsChanged: (() -> Void)? = nil
    ) {
        self._settings = settings
        self.workspaceSettings = workspaceSettings
        self.workspaceName = workspaceName
        self.globalSettings = globalSettings
        self.navigationTitleText = navigationTitle
        self.onChange = onChange
        self.onWorkspaceSettingsChanged = onWorkspaceSettingsChanged
        self.onGlobalSettingsChanged = onGlobalSettingsChanged
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

    /// Android dynamic `FONTSIZE` row title containing the current point size.
    private var fontSizeTitle: String {
        String(format: "Font size (%d pt)", settings.fontSize ?? 18)
    }

    /// Android dynamic `FONTFAMILY` row title containing the persisted font-family value.
    private var fontFamilyTitle: String {
        String(format: "Font family (%@)", settings.fontFamily ?? "sans-serif")
    }

    /// Android dynamic `LINE_SPACING` row title containing the current line-spacing multiplier.
    private var lineSpacingTitle: String {
        String(format: "Line spacing (%1.1fx)", Double(displayedLineSpacing) / 10.0)
    }

    /// Android dynamic `MARGINSIZE` row title containing left/right/max-width values.
    private var marginSizeTitle: String {
        String(
            format: "Margin size (%d/%d/%d mm)",
            settings.marginLeft ?? 2,
            settings.marginRight ?? 2,
            settings.maxWidth ?? 600
        )
    }

    /// Android dynamic `TOPMARGIN` row title containing the current top margin.
    private var topMarginTitle: String {
        String(format: "Top margin (%d mm)", settings.topMargin ?? 0)
    }

    /// Android window-level parent link title scoped to the active workspace name.
    private var workspaceSettingsLinkTitle: String {
        guard let workspaceName, !workspaceName.isEmpty else {
            return androidTitle("open_workspace_settings")
        }
        return "Workspace text options — \(workspaceName)"
    }

    /// Android workspace-level settings screen title scoped to the active workspace name.
    private var workspaceSettingsTitle: String {
        guard let workspaceName, !workspaceName.isEmpty else {
            return "Text options"
        }
        return "Text options - \(workspaceName)"
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
            if workspaceSettings != nil || globalSettings != nil {
                Section {
                    if let workspaceSettings {
                        NavigationLink {
                            TextDisplaySettingsView(
                                settings: workspaceSettings,
                                globalSettings: globalSettings,
                                navigationTitle: workspaceSettingsTitle,
                                onChange: onWorkspaceSettingsChanged,
                                onGlobalSettingsChanged: onGlobalSettingsChanged
                            )
                        } label: {
                            textDisplayRowLabel(
                                androidKey: "open_workspace_settings",
                                title: workspaceSettingsLinkTitle,
                                summary: androidSummary("open_workspace_settings")
                            )
                        }
                        .accessibilityIdentifier("textDisplayWorkspaceSettingsLink")
                    }

                    if let globalSettings {
                        NavigationLink {
                            TextDisplaySettingsView(
                                settings: globalSettings,
                                navigationTitle: "Global text options",
                                onChange: onGlobalSettingsChanged
                            )
                        } label: {
                            textDisplayRowLabel(
                                androidKey: "open_global_settings",
                                title: androidTitle("open_global_settings"),
                                summary: androidSummary("open_global_settings")
                            )
                        }
                        .accessibilityIdentifier("textDisplayGlobalSettingsLink")
                    }
                } header: {
                    textDisplaySectionHeader(TextDisplaySettingsPresentation.Section.parent.titleDefault)
                }
            }

            Section {
                NavigationLink {
                    ColorSettingsView(settings: $settings, onChange: onChange)
                } label: {
                    textDisplayRowLabel(
                        androidKey: "COLORS",
                        title: androidTitle("COLORS"),
                        summary: androidSummary("COLORS")
                    )
                }
                .accessibilityIdentifier("textDisplayColorsLink")

                VStack(alignment: .leading, spacing: 8) {
                    textDisplayRowLabel(
                        androidKey: "FONTSIZE",
                        title: fontSizeTitle,
                        summary: androidSummary("FONTSIZE")
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
                        title: fontFamilyTitle,
                        summary: androidSummary("FONTFAMILY")
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
                        title: fontFamilyTitle,
                        summary: androidSummary("FONTFAMILY")
                    )
                }
                #endif

                VStack(alignment: .leading, spacing: 8) {
                    textDisplayRowLabel(
                        androidKey: "LINE_SPACING",
                        title: lineSpacingTitle,
                        summary: androidSummary("LINE_SPACING")
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
                        title: androidTitle("REDLETTERS"),
                        summary: androidSummary("REDLETTERS")
                    )
                }
            } header: {
                textDisplaySectionHeader(TextDisplaySettingsPresentation.Section.fontAndColors.titleDefault)
            }

            Section {
                let justifyTextBinding = boolBinding(\.justifyText, default: false)
                VStack(alignment: .leading, spacing: 8) {
                    textDisplayRowLabel(
                        androidKey: "MARGINSIZE",
                        title: marginSizeTitle,
                        summary: androidSummary("MARGINSIZE")
                    )
                    VStack(alignment: .leading, spacing: 10) {
                        marginSlider(
                            title: String(format: "Left margin (%d mm)", settings.marginLeft ?? 2),
                            value: settings.marginLeft ?? 2,
                            binding: marginLeftBinding,
                            range: 0...30,
                            step: 1
                        )
                        marginSlider(
                            title: String(format: "Right margin (%d mm)", settings.marginRight ?? 2),
                            value: settings.marginRight ?? 2,
                            binding: marginRightBinding,
                            range: 0...30,
                            step: 1
                        )
                        marginSlider(
                            title: String(format: "Maximum width of text (%d mm)", settings.maxWidth ?? 600),
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
                        title: topMarginTitle,
                        summary: androidSummary("TOPMARGIN")
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
                            title: androidTitle("JUSTIFY"),
                            summary: androidSummary("JUSTIFY")
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("textDisplayJustifyTextToggleButton")

                    Toggle("", isOn: justifyTextBinding)
                        .labelsHidden()
                        .accessibilityIdentifier("textDisplayJustifyTextToggle")
                        .accessibilityValue((settings.justifyText ?? false) ? "justifyTextOn" : "justifyTextOff")
                }
                Toggle(isOn: boolBinding(\.hyphenation, default: true)) {
                    textDisplayRowLabel(
                        androidKey: "HYPHENATION",
                        title: androidTitle("HYPHENATION"),
                        summary: androidSummary("HYPHENATION")
                    )
                }
                Toggle(isOn: boolBinding(\.showVersePerLine, default: false)) {
                    textDisplayRowLabel(
                        androidKey: "VERSEPERLINE",
                        title: androidTitle("VERSEPERLINE"),
                        summary: androidSummary("VERSEPERLINE")
                    )
                }
            } header: {
                textDisplaySectionHeader(TextDisplaySettingsPresentation.Section.textLayout.titleDefault)
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
                        title: androidTitle("STRONGS"),
                        summary: androidSummary("STRONGS")
                    )
                }
                Toggle(isOn: boolBinding(\.showMorphology, default: false)) {
                    textDisplayRowLabel(
                        androidKey: "MORPH",
                        title: androidTitle("MORPH"),
                        summary: androidSummary("MORPH")
                    )
                }
                disabledAndroidToggle(androidKey: "NON_STRONGS_WORD_ITALIC")
            } header: {
                textDisplaySectionHeader(TextDisplaySettingsPresentation.Section.strongsAndMorphology.titleDefault)
            }

            Section {
                let footnotesBinding = boolBinding(\.showFootNotes, default: false)
                let xrefsBinding = boolBinding(\.showXrefs, default: false)
                Toggle(isOn: footnotesBinding) {
                    textDisplayRowLabel(
                        androidKey: "FOOTNOTES",
                        title: androidTitle("FOOTNOTES"),
                        summary: androidSummary("FOOTNOTES")
                    )
                }
                Toggle(isOn: boolBinding(\.showFootNotesInline, default: false)) {
                    textDisplayRowLabel(
                        androidKey: "FOOTNOTES_INLINE",
                        title: androidTitle("FOOTNOTES_INLINE"),
                        summary: androidSummary("FOOTNOTES_INLINE"),
                        isEnabled: footnotesBinding.wrappedValue
                    )
                }
                .disabled(!footnotesBinding.wrappedValue)

                Toggle(isOn: xrefsBinding) {
                    textDisplayRowLabel(
                        androidKey: "XREFS",
                        title: androidTitle("XREFS"),
                        summary: androidSummary("XREFS")
                    )
                }
                Toggle(isOn: boolBinding(\.expandXrefs, default: false)) {
                    textDisplayRowLabel(
                        androidKey: "EXPAND_XREFS",
                        title: androidTitle("EXPAND_XREFS"),
                        summary: androidSummary("EXPAND_XREFS"),
                        isEnabled: xrefsBinding.wrappedValue
                    )
                }
                .disabled(!xrefsBinding.wrappedValue)
            } header: {
                textDisplaySectionHeader(TextDisplaySettingsPresentation.Section.footnotesAndXrefs.titleDefault)
            }

            Section {
                Toggle(isOn: boolBinding(\.showVerseNumbers, default: true)) {
                    textDisplayRowLabel(
                        androidKey: "VERSENUMBERS",
                        title: androidTitle("VERSENUMBERS"),
                        summary: androidSummary("VERSENUMBERS")
                    )
                }
                Toggle(isOn: boolBinding(\.showSectionTitles, default: true)) {
                    textDisplayRowLabel(
                        androidKey: "SECTIONTITLES",
                        title: androidTitle("SECTIONTITLES"),
                        summary: androidSummary("SECTIONTITLES")
                    )
                }
                disabledAndroidToggle(androidKey: "TITLE_SCROLL_BUTTON")
                Toggle(isOn: boolBinding(\.showPageNumber, default: false)) {
                    textDisplayRowLabel(
                        androidKey: "PAGENUMBER",
                        title: androidTitle("PAGENUMBER"),
                        summary: androidSummary("PAGENUMBER")
                    )
                }
            } header: {
                textDisplaySectionHeader(TextDisplaySettingsPresentation.Section.versesAndHeadings.titleDefault)
            }

            Section {
                disabledAndroidToggle(androidKey: "INFINITE_SCROLL")
                disabledAndroidRow(androidKey: "PAGE_SCROLL_AMOUNT")
                disabledAndroidToggle(androidKey: "ORDINALS")
            } header: {
                textDisplaySectionHeader(TextDisplaySettingsPresentation.Section.pageScrolling.titleDefault)
            }

            Section {
                Toggle(isOn: boolBinding(\.showBookmarks, default: true)) {
                    textDisplayRowLabel(
                        androidKey: "BOOKMARKS_SHOW",
                        title: androidTitle("BOOKMARKS_SHOW"),
                        summary: androidSummary("BOOKMARKS_SHOW")
                    )
                }
                Toggle(isOn: boolBinding(\.showMyNotes, default: true)) {
                    textDisplayRowLabel(
                        androidKey: "MYNOTES",
                        title: androidTitle("MYNOTES"),
                        summary: androidSummary("MYNOTES")
                    )
                }
                disabledAndroidToggle(androidKey: "AI_DOC_MARKERS")
                NavigationLink {
                    HiddenBookmarkLabelsView(
                        labels: userLabels,
                        hiddenLabelIds: bookmarksHideLabelsBinding,
                        onChange: onChange
                    )
                } label: {
                    textDisplayRowLabel(
                        androidKey: "BOOKMARKS_HIDELABELS",
                        title: androidTitle("BOOKMARKS_HIDELABELS"),
                        summary: androidSummary("BOOKMARKS_HIDELABELS"),
                        detail: hiddenBookmarkLabelsDetail
                    )
                }
                .accessibilityIdentifier("textDisplayHiddenBookmarkLabelsLink")
            } header: {
                textDisplaySectionHeader(TextDisplaySettingsPresentation.Section.textBookmarks.titleDefault)
            }

            Section {
                disabledAndroidToggle(androidKey: "MARK_AS_READ_BUTTON")
                disabledAndroidToggle(androidKey: "MEMORIZATION_INDICATORS")
                disabledAndroidToggle(androidKey: "AUTO_TRACK_READING")
            } header: {
                textDisplaySectionHeader(TextDisplaySettingsPresentation.Section.readingAndMemorization.titleDefault)
            }
        }
        .accessibilityIdentifier("textDisplaySettingsScreen")
        .accessibilityValue(accessibilityState)
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
     Builds a disabled Android-parity row for settings that exist in Android but are not yet backed
     by iOS storage and renderer behavior.

     - Parameter androidKey: Android preference key from `text_display_settings.xml`.
     - Returns: A disabled preference-shaped row using Android's title, summary, and icon.
     - Side effects: none; the row intentionally does not mutate settings.
     - Failure modes: Unknown keys still render with the key as the title and no icon.
     */
    private func disabledAndroidRow(androidKey: String) -> some View {
        textDisplayRowLabel(
            androidKey: androidKey,
            title: androidTitle(androidKey),
            summary: androidSummary(androidKey),
            isEnabled: false
        )
        .accessibilityIdentifier("textDisplayDisabled-\(androidKey)")
        .disabled(true)
    }

    /**
     Builds a disabled Android-style switch row for unsupported boolean settings.

     - Parameter androidKey: Android preference key from `text_display_settings.xml`.
     - Returns: A disabled switch row that preserves Android's row shape without pretending the
       setting is functional on iOS.
     - Side effects: none; the constant binding cannot write.
     - Failure modes: Unknown keys still render with the key as the title and no icon.
     */
    private func disabledAndroidToggle(androidKey: String) -> some View {
        Toggle(isOn: .constant(false)) {
            textDisplayRowLabel(
                androidKey: androidKey,
                title: androidTitle(androidKey),
                summary: androidSummary(androidKey),
                isEnabled: false
            )
        }
        .accessibilityIdentifier("textDisplayDisabled-\(androidKey)")
        .disabled(true)
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
