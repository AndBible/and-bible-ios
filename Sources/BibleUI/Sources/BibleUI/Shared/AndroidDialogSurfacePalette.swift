// AndroidDialogSurfacePalette.swift — Android-parity dialog surface colors

import SwiftUI

/**
 Android-aligned dialog surface colors used by iOS management screens that intentionally mirror the
 Android AppCompat DayNight dialog treatment.

 These values are derived from the Android workspace prompt flow, which inherits its colors from
 `Theme.AppCompat.DayNight.DarkActionBar` rather than from the reader's custom day/night palette.
 */
enum AndroidDialogSurfacePalette {
    /// Dialog background surface.
    static func background(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? color(argb: 0xFF424242) : color(argb: 0xFFFFFFFF)
    }

    /// Primary body text color shown on the dialog surface.
    static func primaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? color(argb: 0xFFFFFFFF) : color(argb: 0xDE000000)
    }

    /// Secondary text and hint color shown on the dialog surface.
    static func secondaryText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? color(argb: 0x80FFFFFF) : color(argb: 0x80000000)
    }

    /// Accent color used for confirm actions and interactive emphasis on the dialog surface.
    static func accent(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? color(argb: 0xFF80CBC4) : color(argb: 0xFF009688)
    }

    /// Subtle input fill that keeps text fields distinct without diverging from the dialog surface.
    static func fieldBackground(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? color(argb: 0x1FFFFFFF) : color(argb: 0x0F000000)
    }

    /// Input border color that stays visible against the matching Android-parity dialog background.
    static func fieldBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? color(argb: 0x33FFFFFF) : color(argb: 0x29000000)
    }

    private static func color(argb: UInt32) -> Color {
        Color(argbInt: Int(Int32(bitPattern: argb)))
    }
}
