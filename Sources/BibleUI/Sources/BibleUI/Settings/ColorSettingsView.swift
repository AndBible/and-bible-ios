// ColorSettingsView.swift — Color/theme settings

import SwiftUI
import BibleCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension Color {
    static var systemBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// Create a Color from a signed ARGB integer (Vue.js convention).
    /// -1 = white (0xFFFFFFFF), -16777216 = black (0xFF000000).
    init(argbInt: Int) {
        let uint = UInt32(bitPattern: Int32(argbInt))
        let a = Double((uint >> 24) & 0xFF) / 255.0
        let r = Double((uint >> 16) & 0xFF) / 255.0
        let g = Double((uint >> 8) & 0xFF) / 255.0
        let b = Double(uint & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
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
        let ai = UInt32(a * 255) & 0xFF
        let ri = UInt32(r * 255) & 0xFF
        let gi = UInt32(g * 255) & 0xFF
        let bi = UInt32(b * 255) & 0xFF
        let uint = (ai << 24) | (ri << 16) | (gi << 8) | bi
        return Int(Int32(bitPattern: uint))
    }
}

/// Settings for controlling colors and theming.
/// Binds to TextDisplaySettings color fields for persistence.
public struct ColorSettingsView: View {
    @Binding var settings: TextDisplaySettings
    var onChange: (() -> Void)?

    public init(settings: Binding<TextDisplaySettings>, onChange: (() -> Void)? = nil) {
        self._settings = settings
        self.onChange = onChange
    }

    private func colorBinding(for keyPath: WritableKeyPath<TextDisplaySettings, Int?>, default defaultValue: Int) -> Binding<Color> {
        Binding(
            get: { Color(argbInt: settings[keyPath: keyPath] ?? defaultValue) },
            set: { settings[keyPath: keyPath] = $0.argbInt; onChange?() }
        )
    }

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
                Button(String(localized: "reset_to_defaults")) {
                    settings.dayTextColor = -16777216
                    settings.dayBackground = -1
                    settings.dayNoise = 0
                    settings.nightTextColor = -1
                    settings.nightBackground = -16777216
                    settings.nightNoise = 0
                    onChange?()
                }
            }
        }
        .navigationTitle(String(localized: "colors"))
    }
}
