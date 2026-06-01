// TextDisplaySettingsView.swift — Text display settings

import SwiftUI
import BibleCore
#if os(iOS)
import UIKit
#endif

/**
 Form-driven editor for text presentation settings used by the Bible reader.

 The view exposes bindings for typography, spacing, content toggles, annotation visibility, and
 Strong's display modes by mutating a shared `TextDisplaySettings` value.

 Data dependencies:
 - `settings` is the persisted display-settings model owned by the parent screen
 - `onChange` lets the parent push updated settings into the reader after each mutation

 Side effects:
 - every binding write mutates `settings` and invokes `onChange`
 - on iOS, presenting the font picker bridges into `UIFontPickerViewController`
 */
public struct TextDisplaySettingsView: View {
    /// Shared text display settings being edited by the form.
    @Binding var settings: TextDisplaySettings

    /// Callback invoked after any user-visible settings mutation.
    var onChange: (() -> Void)?

    #if os(iOS)
    /// Whether the native iOS font picker sheet is currently presented.
    @State private var showFontPicker = false
    #endif

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
            set: { settings.fontSize = Int($0); onChange?() }
        )
    }

    /// Picker binding that maps the optional stored font family to a concrete selection value.
    private var fontFamilyBinding: Binding<String> {
        Binding(
            get: { settings.fontFamily ?? "sans-serif" },
            set: { settings.fontFamily = $0; onChange?() }
        )
    }

    /// Slider binding that maps the optional stored line spacing to a concrete numeric control.
    private var lineSpacingBinding: Binding<Double> {
        Binding(
            get: { Double(settings.lineSpacing ?? 10) },
            set: { settings.lineSpacing = Int($0); onChange?() }
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
     Builds the grouped typography, layout, content, and annotation settings form.
     */
    public var body: some View {
        Form {
            Section {
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
                    Slider(value: fontSizeBinding, in: 10...30, step: 1)
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
            } header: {
                textDisplaySectionHeader(String(localized: "settings_font"))
            }

            Section {
                let justifyTextBinding = boolBinding(\.justifyText, default: false)
                VStack(alignment: .leading, spacing: 8) {
                    textDisplayRowLabel(
                        androidKey: "LINE_SPACING",
                        title: String(localized: "line_spacing"),
                        summary: String(
                            format: String(
                                localized: "line_spacing_summary",
                                defaultValue: "Set the space between lines. Current value: %d"
                            ),
                            settings.lineSpacing ?? 10
                        )
                    )
                    Slider(value: lineSpacingBinding, in: 0...20, step: 1)
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
                textDisplaySectionHeader(String(localized: "settings_layout"))
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
                Toggle(isOn: boolBinding(\.showFootNotes, default: false)) {
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
                        )
                    )
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
                Toggle(isOn: boolBinding(\.showXrefs, default: false)) {
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
                        )
                    )
                }
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
                textDisplaySectionHeader(String(localized: "settings_content"))
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
            } header: {
                textDisplaySectionHeader(String(localized: "settings_annotations"))
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
