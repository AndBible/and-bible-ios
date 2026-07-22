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
 Form-driven editor for Android color settings stored in `TextDisplaySettings` and `Workspace`.

 The view converts between SwiftUI `Color` values and the signed ARGB integer format expected by the
 Vue-based reader configuration. It mirrors Android's `color_settings.xml`: day/night text colors,
 day/night background colors, day/night noise controls, and the workspace accent color for Android
 workspace scope. Global and workspace callers bind that row to active workspace metadata; only
 window-level callers omit it, matching Android's `isWindow` visibility rule.

 Data dependencies:
 - `settings` is the shared display-settings model whose color fields are being edited
 - `workspaceColor`, when supplied, is the workspace metadata accent color edited by Android's
   non-window color screens
 - `onChange` lets the parent re-emit updated settings to the reader after any color mutation

 Side effects:
 - each color picker or slider mutation writes back to `settings` or `workspaceColor` and invokes
   `onChange`
 - the reset action restores the standard light/dark defaults and the Android workspace color
   default when a workspace-owned color binding is present
 */
public struct ColorSettingsView: View {
    /// Shared display settings whose theme colors are being edited.
    @Binding var settings: TextDisplaySettings

    /// Optional workspace accent color binding; absence means the window-owned row is hidden.
    private var workspaceColor: Binding<Int?>?

    /// Callback invoked after any theme-color mutation.
    var onChange: (() -> Void)?

    /**
     Creates a color settings editor bound to a shared display-settings model.

     - Parameters:
       - settings: Shared display settings value whose color fields should be edited.
       - workspaceColor: Optional workspace accent-color binding. Supplying it exposes Android's
         `workspace_color` row for global/workspace scope; window routes omit it because Android
         hides the row when `isWindow` is true.
       - onChange: Optional callback invoked after any color mutation.
     */
    public init(
        settings: Binding<TextDisplaySettings>,
        workspaceColor: Binding<Int?>? = nil,
        onChange: (() -> Void)? = nil
    ) {
        self._settings = settings
        self.workspaceColor = workspaceColor
        self.onChange = onChange
    }

    /**
     Android preference keys rendered by this view for the supplied row inventory decision.

     - Parameter includesWorkspaceColor: Whether Android's `workspace_color` row is visible.
     - Returns: Android `color_settings.xml` keys in visible order.
     - Side effects: none.
     - Failure modes: none; the inventory is static and test-audited against Android source.
     */
    static func visibleAndroidKeys(includesWorkspaceColor: Bool) -> [String] {
        var keys: [String] = []
        if includesWorkspaceColor {
            keys.append("workspace_color")
        }
        keys.append(contentsOf: [
            "text_color_day",
            "background_color_day",
            "noise_day",
            "text_color_night",
            "background_color_night",
            "noise_night",
        ])
        return keys
    }

    /**
     Android preference-key inventory expected for a caller's color-settings scope.

     Runtime row rendering is controlled by whether the caller supplies `workspaceColor`; this
     helper maps Android text-display scope to that binding policy for tests and call sites. Android
     inflates `workspace_color` for every non-window route and hides it only when `isWindow` is true.

     - Parameter scope: Android text-display settings scope that would launch the color editor.
     - Returns: Android `color_settings.xml` keys in visible order for the iOS binding policy.
     - Side effects: none.
     - Failure modes: none; the inventory is static and test-audited against Android source.
     */
    static func visibleAndroidKeys(scope: TextDisplaySettingsScope) -> [String] {
        visibleAndroidKeys(includesWorkspaceColor: scope != .window)
    }

    /**
     Normalizes a SwiftUI noise slider value to Android's seekbar range.

     Android `noise_day` and `noise_night` use `SeekBarPreference` with default `0` and max `100`.
     SwiftUI emits `Double` values, so this helper rounds to the nearest integer and clamps to the
     Android range before the value is persisted.

     - Parameters:
       - value: Slider value emitted by SwiftUI.
       - fallback: Existing stored value used if `value` is non-finite.
     - Returns: Integer noise value in `0...100`.
     - Side effects: none.
     - Failure modes: Non-finite values return clamped `fallback` instead of trapping.
     */
    static func normalizedNoiseValue(_ value: Double, fallback: Int) -> Int {
        let clampedFallback = min(max(fallback, 0), 100)
        guard value.isFinite else { return clampedFallback }
        return min(max(Int(value.rounded()), 0), 100)
    }

    /// Whether the currently edited color tuple matches the standard light/dark defaults.
    private var usesDefaultThemeColors: Bool {
        let workspaceUsesDefault = workspaceColor.map {
            ($0.wrappedValue ?? Workspace.defaultWorkspaceColor) == Workspace.defaultWorkspaceColor
        } ?? true
        return settings.dayTextColor == -16777216 &&
        settings.dayBackground == -1 &&
        settings.nightTextColor == -1 &&
        settings.nightBackground == -16777216 &&
        settings.dayNoise == 0 &&
        settings.nightNoise == 0 &&
        workspaceUsesDefault
    }

    /// Accessibility-exported state label used to detect reset completion.
    private var colorStateLabel: String {
        usesDefaultThemeColors ? "colorDefaults" : "colorCustom"
    }

    /**
     Applies Android's standard day and night color defaults to the supplied bindings.

     Side effects:
     - writes the default ARGB values and noise levels back into `settings`
     - writes Android's default workspace color when this screen owns a workspace binding

     Failure modes: This helper cannot fail.
     */
    static func resetThemeColorsToDefaults(
        settings: Binding<TextDisplaySettings>,
        workspaceColor: Binding<Int?>?
    ) {
        var updatedSettings = settings.wrappedValue
        updatedSettings.dayTextColor = -16777216
        updatedSettings.dayBackground = -1
        updatedSettings.dayNoise = 0
        updatedSettings.nightTextColor = -1
        updatedSettings.nightBackground = -16777216
        updatedSettings.nightNoise = 0
        settings.wrappedValue = updatedSettings
        workspaceColor?.wrappedValue = Workspace.defaultWorkspaceColor
    }

    /**
     Restores the current editor to standard color defaults.

     Side effects:
     - writes default color values through `settings`
     - resets workspace metadata only when this editor owns a workspace binding
     - invokes `onChange` so the parent can re-emit the updated display settings

     Failure modes: This helper cannot fail.
     */
    private func resetThemeColorsToDefaults() {
        Self.resetThemeColorsToDefaults(settings: $settings, workspaceColor: workspaceColor)
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
     Creates a `Color` binding backed by the optional workspace accent color.

     - Parameters:
       - value: Optional signed ARGB workspace color binding.
       - defaultValue: Android workspace fallback color used for legacy nil values.
     - Returns: A SwiftUI `Color` binding suitable for Android's `workspace_color` picker.
     - Side effects: Setting the binding writes a signed ARGB color and invokes `onChange`.
     - Failure modes: nil stored values render with the supplied Android fallback.
     */
    private func colorBinding(for value: Binding<Int?>, default defaultValue: Int) -> Binding<Color> {
        Binding(
            get: { Color(argbInt: value.wrappedValue ?? defaultValue) },
            set: { value.wrappedValue = $0.argbInt; onChange?() }
        )
    }

    /**
     Creates a slider binding backed by a day/night noise field.

     - Parameter keyPath: Optional noise integer field to edit.
     - Returns: A `Double` binding suitable for SwiftUI's `Slider`.
     - Side effects: Slider writes normalize to Android's `0...100` range and invoke `onChange`.
     - Failure modes: Non-finite values preserve the existing field value.
     */
    private func noiseBinding(for keyPath: WritableKeyPath<TextDisplaySettings, Int?>) -> Binding<Double> {
        Binding(
            get: {
                Double(Self.normalizedNoiseValue(Double(settings[keyPath: keyPath] ?? 0), fallback: 0))
            },
            set: {
                let fallback = settings[keyPath: keyPath] ?? 0
                settings[keyPath: keyPath] = Self.normalizedNoiseValue($0, fallback: fallback)
                onChange?()
            }
        )
    }

    /**
     Builds one Android-style noise seekbar row.

     - Parameters:
       - value: Slider binding normalized to Android's `0...100` range.
       - accessibilityIdentifier: Stable UI-test identifier for the slider.
     - Returns: A labeled slider row with Android's title, summary, and current value.
     - Side effects: User interaction mutates the supplied binding.
     - Failure modes: Missing localizations use the supplied English fallback values.
     */
    private func noiseSlider(
        value: Binding<Double>,
        accessibilityIdentifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "prefs_noise_title", defaultValue: "Background noise"))
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))")
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...100, step: 1)
                .accessibilityIdentifier(accessibilityIdentifier)
                .accessibilityValue("\(Int(value.wrappedValue.rounded()))")
            Text(
                String(
                    localized: "prefs_noise_summary",
                    defaultValue: "Adding some noise to background might make it more comfortable to eyes."
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /**
     Builds the day-theme, night-theme, and reset-to-defaults color settings form.
     */
    public var body: some View {
        Form {
            if let workspaceColor {
                Section {
                    ColorPicker(
                        String(localized: "color_workspace", defaultValue: "Workspace color"),
                        selection: colorBinding(for: workspaceColor, default: Workspace.defaultWorkspaceColor)
                    )
                    .accessibilityIdentifier("colorSettingsWorkspaceColorPicker")
                }
            }

            Section(String(localized: "day_theme")) {
                ColorPicker(String(localized: "text_color"), selection: colorBinding(for: \.dayTextColor, default: -16777216))
                ColorPicker(String(localized: "background"), selection: colorBinding(for: \.dayBackground, default: -1))
                noiseSlider(
                    value: noiseBinding(for: \.dayNoise),
                    accessibilityIdentifier: "colorSettingsDayNoiseSlider"
                )
            }

            Section(String(localized: "night_theme")) {
                ColorPicker(String(localized: "text_color"), selection: colorBinding(for: \.nightTextColor, default: -1))
                ColorPicker(String(localized: "background"), selection: colorBinding(for: \.nightBackground, default: -16777216))
                noiseSlider(
                    value: noiseBinding(for: \.nightNoise),
                    accessibilityIdentifier: "colorSettingsNightNoiseSlider"
                )
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
