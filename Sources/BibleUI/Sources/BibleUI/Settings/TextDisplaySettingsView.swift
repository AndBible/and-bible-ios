// TextDisplaySettingsView.swift — Text display settings

import SwiftUI
import BibleCore

/// Settings for controlling how Bible text is displayed.
/// Binds to a TextDisplaySettings struct for persistence.
public struct TextDisplaySettingsView: View {
    @Binding var settings: TextDisplaySettings
    var onChange: (() -> Void)?

    public init(settings: Binding<TextDisplaySettings>, onChange: (() -> Void)? = nil) {
        self._settings = settings
        self.onChange = onChange
    }

    // Computed bindings that map optional Int/Bool to concrete slider/toggle values
    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { Double(settings.fontSize ?? 18) },
            set: { settings.fontSize = Int($0); onChange?() }
        )
    }

    private var fontFamilyBinding: Binding<String> {
        Binding(
            get: { settings.fontFamily ?? "sans-serif" },
            set: { settings.fontFamily = $0; onChange?() }
        )
    }

    private var lineSpacingBinding: Binding<Double> {
        Binding(
            get: { Double(settings.lineSpacing ?? 10) },
            set: { settings.lineSpacing = Int($0); onChange?() }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<TextDisplaySettings, Bool?>, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] ?? defaultValue },
            set: { settings[keyPath: keyPath] = $0; onChange?() }
        )
    }

    public var body: some View {
        Form {
            Section(String(localized: "settings_font")) {
                HStack {
                    Text(String(localized: "font_size"))
                    Slider(value: fontSizeBinding, in: 10...30, step: 1)
                    Text("\(settings.fontSize ?? 18)")
                        .monospacedDigit()
                }
                Picker(String(localized: "font_family"), selection: fontFamilyBinding) {
                    ForEach(Self.fontOptions, id: \.value) { option in
                        Text(option.label)
                            .font(.custom(option.previewFont, size: 16))
                            .tag(option.value)
                    }
                }
            }

            Section(String(localized: "settings_layout")) {
                HStack {
                    Text(String(localized: "line_spacing"))
                    Slider(value: lineSpacingBinding, in: 0...20, step: 1)
                    Text("\(settings.lineSpacing ?? 10)")
                        .monospacedDigit()
                }
                Toggle(String(localized: "justify_text"), isOn: boolBinding(\.justifyText, default: false))
                Toggle(String(localized: "verse_per_line"), isOn: boolBinding(\.showVersePerLine, default: false))
                Toggle(String(localized: "hyphenation"), isOn: boolBinding(\.hyphenation, default: true))
            }

            Section(String(localized: "settings_content")) {
                Toggle(String(localized: "verse_numbers"), isOn: boolBinding(\.showVerseNumbers, default: true))
                Toggle(String(localized: "section_titles"), isOn: boolBinding(\.showSectionTitles, default: true))
                Toggle(String(localized: "footnotes"), isOn: boolBinding(\.showFootNotes, default: false))
                Toggle(String(localized: "inline_footnotes"), isOn: boolBinding(\.showFootNotesInline, default: false))
                Toggle(String(localized: "red_letters"), isOn: boolBinding(\.showRedLetters, default: true))
                Toggle(String(localized: "cross_references"), isOn: boolBinding(\.showXrefs, default: false))
                Toggle(String(localized: "expand_cross_references"), isOn: boolBinding(\.expandXrefs, default: false))
                Picker(String(localized: "strongs_numbers"), selection: Binding(
                    get: { settings.strongsMode ?? 0 },
                    set: { settings.strongsMode = $0; onChange?() }
                )) {
                    Text(String(localized: "off")).tag(0)
                    Text(String(localized: "inline")).tag(1)
                    Text(String(localized: "links")).tag(2)
                    Text(String(localized: "hidden")).tag(3)
                }
                Toggle(String(localized: "morphology"), isOn: boolBinding(\.showMorphology, default: false))
            }

            Section(String(localized: "settings_annotations")) {
                Toggle(String(localized: "show_bookmarks"), isOn: boolBinding(\.showBookmarks, default: true))
                Toggle(String(localized: "show_my_notes"), isOn: boolBinding(\.showMyNotes, default: true))
            }
        }
        .navigationTitle(String(localized: "text_display"))
    }

    // MARK: - Font Options

    private struct FontOption {
        let label: String
        /// CSS font-family value sent to Vue.js WebView
        let value: String
        /// iOS font name for preview rendering
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
