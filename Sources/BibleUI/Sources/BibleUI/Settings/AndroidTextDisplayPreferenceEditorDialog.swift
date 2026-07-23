// AndroidTextDisplayPreferenceEditorDialog.swift -- Shared staged text preference dialog

import BibleCore
import SwiftUI

/**
 Reusable app-owned implementation of Android's non-Boolean text-display preference dialogs.

 Android opens the same preference widget from both All Text Options and the recent-settings window
 popup. This component owns that common staged draft, AppCompat-style chrome, controls, and
 Reset/Cancel/OK semantics so neither entry point can drift into a platform sheet or a separate
 approximation.

 Inputs: exact editor type, current-scope settings binding, scope inheritance semantics, and the
 owning reader/workspace palette

 Outputs: committed or reset settings through the binding and explicit terminal callbacks

 Side effects: only OK and Reset mutate the supplied settings binding; Cancel/outside tap discard
 the draft

 Failure modes: invalid legacy values are clamped for presentation and normalized by existing draft
 helpers; unknown font names render with the system fallback without rewriting storage
 */
struct AndroidTextDisplayPreferenceEditorDialog: View {
    /// Exact Android preference widget being presented.
    let editor: TextDisplayPreferenceEditorKind

    /// Current scope settings mutated only by terminal commit/reset actions.
    @Binding var settings: TextDisplaySettings

    /// Android inheritance level used by neutral Reset behavior.
    let scope: TextDisplaySettingsScope

    /// Owning reader/workspace palette used by the shared app-owned seek bar.
    let surfacePalette: ReaderThemeSurfacePalette

    /// Invoked after OK commits the staged value.
    let onCommit: () -> Void

    /// Invoked after Reset clears the setting back to its parent/default owner.
    let onReset: () -> Void

    /// Invoked by Cancel or an outside tap without mutating `settings`.
    let onCancel: () -> Void

    /// Dialog-local values copied from `settings` at presentation time.
    @State private var draft: TextDisplayPreferenceEditorDraft

    /// Current appearance used by the shared Android dialog palette.
    @Environment(\.colorScheme) private var colorScheme

    /** Creates a fresh staged editor for one presentation. */
    init(
        editor: TextDisplayPreferenceEditorKind,
        settings: Binding<TextDisplaySettings>,
        scope: TextDisplaySettingsScope,
        surfacePalette: ReaderThemeSurfacePalette,
        onCommit: @escaping () -> Void,
        onReset: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.editor = editor
        self._settings = settings
        self.scope = scope
        self.surfacePalette = surfacePalette
        self.onCommit = onCommit
        self.onReset = onReset
        self.onCancel = onCancel
        _draft = State(initialValue: TextDisplayPreferenceEditorDraft(settings: settings.wrappedValue))
    }

    var body: some View {
        AndroidDialogWindow(
            colorScheme: colorScheme,
            accessibilityIdentifier: "textDisplayPreferenceEditorDialog",
            onOutsideTap: onCancel
        ) {
            AndroidDialogScaffold(title: title) {
                editorContent
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
            } actions: {
                AndroidDialogTextAction(
                    title: String(localized: "reset_generic", defaultValue: "Reset"),
                    accessibilityIdentifier: "textDisplayPreferenceEditorResetButton",
                    action: reset
                )
                Spacer(minLength: 8)
                AndroidDialogTextAction(
                    title: String(localized: "cancel"),
                    accessibilityIdentifier: "textDisplayPreferenceEditorCancelButton",
                    action: onCancel
                )
                AndroidDialogTextAction(
                    title: String(localized: "ok", defaultValue: "OK"),
                    accessibilityIdentifier: "textDisplayPreferenceEditorOKButton",
                    action: commit
                )
            }
        }
    }

    /// Android-equivalent staged controls for the selected preference type.
    @ViewBuilder
    private var editorContent: some View {
        switch editor {
        case .strongsMode:
            choiceList(
                options: strongsModeOptions,
                selection: draftIntBinding(\.strongsMode, fallback: 0)
            )
        case .fontSize:
            VStack(alignment: .leading, spacing: 14) {
                fontSampleText(size: displayedFontSize)
                numericSlider(
                    title: String(localized: "font_size_title", defaultValue: "Font size"),
                    valueText: String.localizedStringWithFormat(
                        String(localized: "font_size_pt", defaultValue: "%d pt"),
                        displayedFontSize
                    ),
                    binding: draftDoubleBinding(
                        \.fontSize,
                        fallback: TextDisplaySettings.appDefaults.fontSize ?? 16
                    ),
                    range: Double(TextDisplaySettingsView.androidFontSizeRange.lowerBound)...Double(TextDisplaySettingsView.androidFontSizeRange.upperBound)
                )
            }
        case .fontFamily:
            VStack(alignment: .leading, spacing: 14) {
                fontSampleText(size: displayedFontSize)
                Text(String(localized: "pref_font_family_label", defaultValue: "Font family"))
                    .font(.callout)
                    .foregroundStyle(primaryText)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(TextDisplaySettingsView.androidFontFamilyOptions()) { option in
                            fontFamilyChoiceRow(option)
                            Divider().background(secondaryText.opacity(0.18))
                        }
                    }
                }
                .frame(maxHeight: 260)
                .accessibilityIdentifier("textDisplayFontFamilyOptionList")
            }
        case .margins:
            VStack(alignment: .leading, spacing: 16) {
                numericSlider(
                    title: String(localized: "text_display_left_margin_label", defaultValue: "Left margin"),
                    valueText: millimeterValueText(displayedMarginLeft),
                    binding: draftDoubleBinding(
                        \.marginLeft,
                        fallback: TextDisplaySettings.appDefaults.marginLeft ?? 3
                    ),
                    range: Double(TextDisplaySettingsView.androidMarginRange.lowerBound)...Double(TextDisplaySettingsView.androidMarginRange.upperBound)
                )
                numericSlider(
                    title: String(localized: "text_display_right_margin_label", defaultValue: "Right margin"),
                    valueText: millimeterValueText(displayedMarginRight),
                    binding: draftDoubleBinding(
                        \.marginRight,
                        fallback: TextDisplaySettings.appDefaults.marginRight ?? 3
                    ),
                    range: Double(TextDisplaySettingsView.androidMarginRange.lowerBound)...Double(TextDisplaySettingsView.androidMarginRange.upperBound)
                )
                numericSlider(
                    title: String(localized: "text_display_max_width_label", defaultValue: "Maximum width of text"),
                    valueText: millimeterValueText(displayedMaxWidth),
                    binding: draftDoubleBinding(
                        \.maxWidth,
                        fallback: TextDisplaySettings.appDefaults.maxWidth ?? 170
                    ),
                    range: Double(TextDisplaySettingsView.androidMaxTextWidthRange.lowerBound)...Double(TextDisplaySettingsView.androidMaxTextWidthRange.upperBound)
                )
            }
        case .topMargin:
            numericSlider(
                title: String(localized: "prefs_top_margin_title", defaultValue: "Top margin"),
                valueText: millimeterValueText(displayedTopMargin),
                binding: draftDoubleBinding(\.topMargin, fallback: 0),
                range: Double(TextDisplaySettingsView.androidTopMarginRange.lowerBound)...Double(TextDisplaySettingsView.androidTopMarginRange.upperBound)
            )
        case .lineSpacing:
            numericSlider(
                title: String(localized: "line_spacing_title", defaultValue: "Line spacing"),
                valueText: String.localizedStringWithFormat(
                    String(localized: "prefs_line_spacing_pt", defaultValue: "Line spacing %1.1fx"),
                    Double(displayedLineSpacing) / 10.0
                ),
                binding: draftDoubleBinding(
                    \.lineSpacing,
                    fallback: TextDisplaySettings.appDefaults.lineSpacing ?? 16
                ),
                range: Double(TextDisplaySettingsView.androidLineSpacingRange.lowerBound)...Double(TextDisplaySettingsView.androidLineSpacingRange.upperBound)
            )
        case .pageScrollAmount:
            choiceList(
                options: TextDisplaySettings.pageScrollAmountValues.map { ($0, "\($0)%") },
                selection: draftIntBinding(\.pageScrollAmount, fallback: 100)
            )
        }
    }

    /// Android localized dialog title from the shared presentation catalog.
    private var title: String {
        let type = editor.androidSettingType
        return type.localizedTitle(settings: settings)
    }

    /// Android Strong's mode choice order.
    private var strongsModeOptions: [(value: Int, label: String)] {
        [
            (0, String(localized: "off")),
            (1, String(localized: "inline")),
            (2, String(localized: "links")),
            (3, String(localized: "hidden")),
        ]
    }

    /// Shared single-choice list used by Strong's and page-scroll dialogs.
    private func choiceList(
        options: [(value: Int, label: String)],
        selection: Binding<Int>
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(options, id: \.value) { option in
                    AndroidRadioRow(
                        title: option.label,
                        value: option.value,
                        selection: selection,
                        foregroundColor: primaryText,
                        secondaryColor: secondaryText,
                        accentColor: accent,
                        accessibilityIdentifier: "textDisplayPreferenceChoice::\(option.value)"
                    )
                    Divider().background(secondaryText.opacity(0.18))
                }
            }
        }
        .frame(maxHeight: 320)
    }

    /// Shared Android seekbar row for numeric editor types.
    private func numericSlider(
        title: String,
        valueText: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(primaryText)
                Text(valueText).font(.callout.monospacedDigit()).foregroundStyle(secondaryText)
            }
            AndroidSeekBar(
                value: binding,
                range: range,
                step: TextDisplaySettingsView.androidNumericSliderStep,
                palette: surfacePalette,
                accessibilityIdentifier: "textDisplayPreferenceEditorSeekBar::\(title)"
            )
        }
    }

    /// Android font-family radio row retaining source values and ordering.
    private func fontFamilyChoiceRow(_ option: TextDisplayFontFamilyOption) -> some View {
        let selectedIndex = TextDisplaySettingsView.androidFontFamilySelectedIndex(for: draft.fontFamily)
        let isSelected = option.androidIndex == selectedIndex
        return AndroidRadioRow(
            title: option.label,
            value: option.androidIndex,
            selection: Binding(
                get: { selectedIndex },
                set: { _ in draft.fontFamily = option.value }
            ),
            foregroundColor: primaryText,
            secondaryColor: secondaryText,
            accentColor: accent,
            titleFont: previewFont(for: option.value, size: 16),
            accessibilityIdentifier: "textDisplayFontFamilyOption::\(option.androidIndex)"
        )
        .accessibilityValue(isSelected ? "selected" : "unselected")
    }

    /// Shared Android font preview used by font size and family editors.
    private func fontSampleText(size: Int) -> some View {
        Text(
            String(
                localized: "prefs_text_size_sample_text",
                defaultValue: "The quick brown fox jumps over the lazy dog."
            )
        )
        .font(previewFont(for: draft.fontFamily ?? "sans-serif", size: CGFloat(size)))
        .foregroundStyle(secondaryText)
        .lineLimit(2)
        .frame(height: 60, alignment: .bottomLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("textDisplayPreferenceEditorSampleText")
    }

    /// Maps Android design-family strings to the closest iOS preview font without changing storage.
    private func previewFont(for family: String, size: CGFloat) -> Font {
        if family.contains("monospace") { return .system(size: size, design: .monospaced) }
        if family == "serif" { return .system(size: size, design: .serif) }
        if family == "casual" || family == "cursive" {
            return .system(size: size, design: .rounded)
        }
        return .system(size: size)
    }

    /// Staged integer binding for radio-list editors.
    private func draftIntBinding(
        _ keyPath: WritableKeyPath<TextDisplayPreferenceEditorDraft, Int?>,
        fallback: Int
    ) -> Binding<Int> {
        Binding(
            get: { draft[keyPath: keyPath] ?? fallback },
            set: { draft[keyPath: keyPath] = $0 }
        )
    }

    /// Staged rounded numeric binding for seekbar editors.
    private func draftDoubleBinding(
        _ keyPath: WritableKeyPath<TextDisplayPreferenceEditorDraft, Int?>,
        fallback: Int
    ) -> Binding<Double> {
        Binding(
            get: { Double(draft[keyPath: keyPath] ?? fallback) },
            set: {
                draft[keyPath: keyPath] = TextDisplaySettingsView.sliderInteger(
                    $0,
                    fallback: fallback
                )
            }
        )
    }

    /// Applies the staged value using the shared Android scope semantics.
    private func commit() {
        draft.commit(editor, scope: scope, to: &settings)
        onCommit()
    }

    /// Clears the selected override to its Android parent/default owner.
    private func reset() {
        draft.reset(editor, scope: scope)
        draft.commit(editor, scope: scope, to: &settings)
        onReset()
    }

    private var displayedFontSize: Int {
        draft.fontSize ?? TextDisplaySettings.appDefaults.fontSize ?? 16
    }

    private var displayedMarginLeft: Int {
        draft.marginLeft ?? TextDisplaySettings.appDefaults.marginLeft ?? 3
    }

    private var displayedMarginRight: Int {
        draft.marginRight ?? TextDisplaySettings.appDefaults.marginRight ?? 3
    }

    private var displayedMaxWidth: Int {
        draft.maxWidth ?? TextDisplaySettings.appDefaults.maxWidth ?? 170
    }

    private var displayedTopMargin: Int {
        draft.topMargin ?? TextDisplaySettings.appDefaults.topMargin ?? 0
    }

    private var displayedLineSpacing: Int {
        min(
            max(
                draft.lineSpacing ?? TextDisplaySettings.appDefaults.lineSpacing ?? 16,
                TextDisplaySettingsView.androidLineSpacingRange.lowerBound
            ),
            TextDisplaySettingsView.androidLineSpacingRange.upperBound
        )
    }

    /// Formats Android millimeter summaries used by margin dialogs.
    private func millimeterValueText(_ value: Int) -> String {
        String.localizedStringWithFormat(
            String(localized: "value_mm", defaultValue: "%d mm"),
            value
        )
    }

    private var primaryText: Color {
        AndroidDialogSurfacePalette.primaryText(for: colorScheme)
    }

    private var secondaryText: Color {
        AndroidDialogSurfacePalette.secondaryText(for: colorScheme)
    }

    private var accent: Color {
        AndroidDialogSurfacePalette.accent(for: colorScheme)
    }
}
