// AndroidBibleReferenceOverlay.swift -- Shared fullscreen reader reference resource

import SwiftUI

/**
 Projects Android's `bible_reference_overlay` drawable and `SplitBibleArea` text treatment.

 Android owns this as a globally themed reader resource rather than a platform material. Keeping
 the ARGB colors and drawable geometry here prevents reader callers from substituting iOS blur,
 workspace-specific guesses, or feature-local screenshot colors.

 Inputs: the already-localized current reference and the active global light/night appearance

 Output: one non-interactive, single-line Android reference badge

 Side effects: none

 Failure modes: empty text renders an empty padded badge; the owner decides whether to present it
 */
struct AndroidBibleReferenceOverlay: View {
    /// Current book/chapter/verse label supplied by the reader owner.
    let reference: String

    /// Global application appearance used by Android's day/night color resources.
    @Environment(\.colorScheme) private var colorScheme

    /** Renders Android's 18sp text, 8dp inset, 6dp corners, and ARGB resource color. */
    var body: some View {
        Text(reference)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(AndroidDialogSurfacePalette.primaryText(for: colorScheme))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(8)
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .accessibilityIdentifier("androidBibleReferenceOverlay")
            .allowsHitTesting(false)
    }

    /// Android `bible_reference_overlay` ARGB color for the active day/night resource tree.
    private var backgroundColor: Color {
        let channel = colorScheme == .dark ? 0x5A : 0xE4
        return Color(
            red: Double(channel) / 255,
            green: Double(channel) / 255,
            blue: Double(channel) / 255,
            opacity: Double(0xDE) / 255
        )
    }
}
