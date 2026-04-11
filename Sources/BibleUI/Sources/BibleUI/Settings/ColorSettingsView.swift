// ColorSettingsView.swift — Color/theme settings

import SwiftUI
import BibleCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Color {
    /// Cross-platform system background color used by color-related settings views.
    static var systemBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /**
     Creates a `Color` from a signed ARGB integer using the Vue reader's color convention.

     `-1` maps to white (`0xFFFFFFFF`) and `-16777216` maps to black (`0xFF000000`).
     */
    init(argbInt: Int) {
        let uint = UInt32(bitPattern: Int32(truncatingIfNeeded: argbInt))
        let a = Double((uint >> 24) & 0xFF) / 255.0
        let r = Double((uint >> 16) & 0xFF) / 255.0
        let g = Double((uint >> 8) & 0xFF) / 255.0
        let b = Double(uint & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /**
     Clamps one floating-point color component into a byte for ARGB serialization.

     UIKit's color picker can surface transient out-of-range component values while a user edits
     the hex field. We must sanitize those intermediate values before converting back to `UInt32`
     or the app can trap on partial input.
     */
    static func clampedARGBByte(_ component: CGFloat) -> UInt32 {
        let boundedComponent: CGFloat
        if component.isFinite {
            boundedComponent = min(max(component, 0), 1)
        } else {
            boundedComponent = 0
        }
        return UInt32((boundedComponent * 255).rounded())
    }

    /// Convert to signed ARGB integer (Vue.js convention).
    var argbInt: Int {
        #if os(iOS)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif os(macOS)
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        let ai = Self.clampedARGBByte(a)
        let ri = Self.clampedARGBByte(r)
        let gi = Self.clampedARGBByte(g)
        let bi = Self.clampedARGBByte(b)
        let uint = (ai << 24) | (ri << 16) | (gi << 8) | bi
        return Int(Int32(bitPattern: uint))
    }
}

/**
 Form-driven editor for day and night theme colors stored in `TextDisplaySettings`.

 The view converts between SwiftUI `Color` values and the signed ARGB integer format expected by the
 Vue-based reader configuration.

 Data dependencies:
 - `settings` is the shared display-settings model whose color fields are being edited
 - `onChange` lets the parent re-emit updated settings to the reader after any color mutation

 Side effects:
 - each color picker mutation writes an ARGB integer back into `settings` and invokes `onChange`
 - the reset action restores the standard light and dark theme defaults in one batch
 */
public struct ColorSettingsView: View {
    /// Shared display settings whose theme colors are being edited.
    @Binding var settings: TextDisplaySettings

    /// Callback invoked after any theme-color mutation.
    var onChange: (() -> Void)?

    /**
     Creates a color settings editor bound to a shared display-settings model.

     - Parameters:
       - settings: Shared display settings value whose color fields should be edited.
       - onChange: Optional callback invoked after any color mutation.
     */
    public init(settings: Binding<TextDisplaySettings>, onChange: (() -> Void)? = nil) {
        self._settings = settings
        self.onChange = onChange
    }

    /// Whether the currently edited color tuple matches the standard light/dark defaults.
    private var usesDefaultThemeColors: Bool {
        settings.dayTextColor == -16777216 &&
        settings.dayBackground == -1 &&
        settings.nightTextColor == -1 &&
        settings.nightBackground == -16777216 &&
        settings.dayNoise == 0 &&
        settings.nightNoise == 0
    }

    /// Accessibility-exported state label used to detect reset completion.
    private var colorStateLabel: String {
        usesDefaultThemeColors ? "colorDefaults" : "colorCustom"
    }

    /**
     Restores the standard day and night color defaults.

     Side effects:
     - writes the default ARGB values and noise levels back into `settings`
     - invokes `onChange` so the parent can re-emit the updated display settings

     Failure modes: This helper cannot fail.
     */
    private func resetThemeColorsToDefaults() {
        settings.dayTextColor = -16777216
        settings.dayBackground = -1
        settings.dayNoise = 0
        settings.nightTextColor = -1
        settings.nightBackground = -16777216
        settings.nightNoise = 0
        onChange?()
    }

    /**
     Creates a `Color` binding backed by a signed ARGB field in `TextDisplaySettings`.

     - Parameters:
       - keyPath: Optional ARGB integer field to edit.
       - defaultValue: Fallback ARGB color used when the field is currently `nil`.
     - Returns: A SwiftUI `Color` binding suitable for `ColorPicker`.
     */
    private func colorBinding(for keyPath: WritableKeyPath<TextDisplaySettings, Int?>, default defaultValue: Int) -> Binding<Color> {
        Binding(
            get: { Color(argbInt: settings[keyPath: keyPath] ?? defaultValue) },
            set: { settings[keyPath: keyPath] = $0.argbInt; onChange?() }
        )
    }

    /**
     Builds the day-theme, night-theme, and reset-to-defaults color settings form.
     */
    public var body: some View {
        Form {
            Section(String(localized: "day_theme")) {
                ColorPicker(String(localized: "text_color"), selection: colorBinding(for: \.dayTextColor, default: -16777216))
                ColorPicker(String(localized: "background"), selection: colorBinding(for: \.dayBackground, default: -1))
            }

            Section(String(localized: "night_theme")) {
                ColorPicker(String(localized: "text_color"), selection: colorBinding(for: \.nightTextColor, default: -1))
                ColorPicker(String(localized: "background"), selection: colorBinding(for: \.nightBackground, default: -16777216))
            }

            Section {
                Button(String(localized: "reset_to_defaults"), action: resetThemeColorsToDefaults)
                    .accessibilityIdentifier("colorSettingsResetButton")
            }

        }
        .accessibilityIdentifier("colorSettingsScreen")
        .accessibilityValue(colorStateLabel)
        .navigationTitle(String(localized: "colors"))
    }
}
