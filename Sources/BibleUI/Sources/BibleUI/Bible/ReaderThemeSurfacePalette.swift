// ReaderThemeSurfacePalette.swift -- Reader-shell colors derived from text display settings

import SwiftUI
import BibleCore

/**
 Resolves the native reader shell colors from the same day/night theme settings used by the WebView.

 The Vue reader receives `TextDisplaySettings` through the bridge and applies those ARGB colors to
 document content. Native SwiftUI chrome around that document must derive from the same values so
 the header, root background, and window tab bar do not fall back to unrelated system surfaces.

 Inputs:
 - `settings`: a fully or partially resolved text-display settings value
 - `nightMode`: selects the day or night color tuple
 - `defaults`: fallback settings used when the selected tuple is missing values

 Outputs:
 - signed ARGB integers for testable parity with the WebView payload
 - SwiftUI `Color` projections for native surfaces

 Side effects: none.
 Failure modes: missing settings fall back to the hard-coded reader defaults.
 Determinism: pure value derivation with no shared state.
 */
struct ReaderThemeSurfacePalette: Equatable {
    /// Background color encoded with the Android/Vue signed ARGB convention.
    let backgroundColorInt: Int

    /// Foreground/text color encoded with the Android/Vue signed ARGB convention.
    let foregroundColorInt: Int

    /// Default light-mode reader palette used by call sites that have not yet received settings.
    static let standard = ReaderThemeSurfacePalette(settings: .appDefaults, nightMode: false)

    /**
     Creates a reader-shell palette from resolved display settings.

     - Parameters:
       - settings: Active text-display settings for the relevant reader surface.
       - nightMode: Whether to select the night color tuple.
       - defaults: Fallback values used when `settings` omits a color field.
     */
    init(
        settings: TextDisplaySettings,
        nightMode: Bool,
        defaults: TextDisplaySettings = .appDefaults
    ) {
        if nightMode {
            backgroundColorInt = settings.nightBackground ?? defaults.nightBackground ?? -16777216
            foregroundColorInt = settings.nightTextColor ?? defaults.nightTextColor ?? -1
        } else {
            backgroundColorInt = settings.dayBackground ?? defaults.dayBackground ?? -1
            foregroundColorInt = settings.dayTextColor ?? defaults.dayTextColor ?? -16777216
        }
    }

    /// SwiftUI background color for reader chrome surfaces.
    var backgroundColor: Color {
        Color(argbInt: backgroundColorInt)
    }

    /// SwiftUI foreground color for reader chrome labels and icons.
    var foregroundColor: Color {
        Color(argbInt: foregroundColorInt)
    }

    /// Low-contrast foreground color for secondary labels, inactive dots, and neutral borders.
    var secondaryForegroundColor: Color {
        foregroundColor.opacity(0.58)
    }

    /// Disabled foreground color for unavailable reader chrome controls.
    var disabledForegroundColor: Color {
        secondaryForegroundColor.opacity(0.55)
    }

    /// Subtle fill used for neutral controls on top of the reader background.
    var controlFillColor: Color {
        foregroundColor.opacity(0.10)
    }

    /// Border color for inactive chrome controls on top of the reader background.
    var inactiveBorderColor: Color {
        foregroundColor.opacity(0.24)
    }
}
