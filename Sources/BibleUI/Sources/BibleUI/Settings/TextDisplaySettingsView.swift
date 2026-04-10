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
            Section(String(localized: "settings_font")) {
                HStack {
                    Text(String(localized: "font_size"))
                    Slider(value: fontSizeBinding, in: 10...30, step: 1)
                    Text("\(settings.fontSize ?? 18)")
                        .monospacedDigit()
                }
                #if os(iOS)
                Button {
                    showFontPicker = true
                } label: {
                    HStack {
                        Text(String(localized: "font_family"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(currentFontName)
                            .font(.custom(settings.fontFamily ?? "sans-serif", size: 16))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("textDisplayFontFamilyButton")
                .sheet(isPresented: $showFontPicker) {
                    FontPickerView(selectedFamily: fontFamilyBinding)
                }
                #else
                Picker(String(localized: "font_family"), selection: fontFamilyBinding) {
                    ForEach(Self.fontOptions, id: \.value) { option in
                        Text(option.label)
                            .font(.custom(option.previewFont, size: 16))
                            .tag(option.value)
                    }
                }
                #endif
            }

            Section(String(localized: "settings_layout")) {
                let justifyTextBinding = boolBinding(\.justifyText, default: false)
                HStack {
                    Text(String(localized: "line_spacing"))
                    Slider(value: lineSpacingBinding, in: 0...20, step: 1)
                    Text("\(settings.lineSpacing ?? 10)")
                        .monospacedDigit()
                }
                HStack {
                    Button {
                        justifyTextBinding.wrappedValue.toggle()
                    } label: {
                        Text(String(localized: "justify_text"))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("textDisplayJustifyTextToggleButton")

                    Toggle("", isOn: justifyTextBinding)
                        .labelsHidden()
                        .accessibilityIdentifier("textDisplayJustifyTextToggle")
                        .accessibilityValue((settings.justifyText ?? false) ? "justifyTextOn" : "justifyTextOff")
                }
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
        .accessibilityIdentifier("textDisplaySettingsScreen")
        .accessibilityValue(accessibilityState)
        .navigationTitle(String(localized: "text_display"))
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
