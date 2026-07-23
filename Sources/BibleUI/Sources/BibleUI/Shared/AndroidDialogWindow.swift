// AndroidDialogWindow.swift -- Shared app-owned Android dialog presentation

import SwiftUI

/**
 Presents feature content inside the application's shared Android-style dialog window.

 The window centralizes the scrim, AppCompat DayNight surface palette, maximum geometry, outside-tap
 policy, and accessibility containment. Callers provide semantic dialog content and decide whether
 outside taps may dismiss while work is active.

 Inputs:
 - current color scheme
 - stable accessibility identifier
 - outside-tap dismissal policy and callback
 - caller-owned dialog content

 Output: a centered app-owned dialog above a dimmed application surface

 Side effects: invokes `onOutsideTap` only when `allowsOutsideDismissal` is true

 Failure modes: none; long content must provide its own scroll container
 */
struct AndroidDialogWindow<Content: View>: View {
    /// Current application scheme used by the shared AppCompat palette.
    let colorScheme: ColorScheme

    /// Stable UI-test identifier for the dialog window.
    let accessibilityIdentifier: String

    /// Whether a scrim tap may close the dialog.
    let allowsOutsideDismissal: Bool

    /// Dismissal callback for accepted scrim taps.
    let onOutsideTap: () -> Void

    /// Semantic dialog content supplied by the feature.
    private let content: Content

    /**
     Creates one shared Android dialog window.

     - Parameters:
       - colorScheme: Active application color scheme.
       - accessibilityIdentifier: Stable identifier for UI automation.
       - allowsOutsideDismissal: Set false while destructive or archive work is active.
       - onOutsideTap: Callback for accepted scrim taps.
       - content: Dialog-specific title, body, and actions.
     - Side effects: none until the scrim is tapped.
     - Failure modes: none.
     */
    init(
        colorScheme: ColorScheme,
        accessibilityIdentifier: String,
        allowsOutsideDismissal: Bool = true,
        onOutsideTap: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.colorScheme = colorScheme
        self.accessibilityIdentifier = accessibilityIdentifier
        self.allowsOutsideDismissal = allowsOutsideDismissal
        self.onOutsideTap = onOutsideTap
        self.content = content()
    }

    /**
     Builds the shared scrim, dialog surface, and isolated UI-test identity marker.

     The marker must remain a sibling of `content`: applying the dialog identifier to the
     composite content container causes SwiftUI to replace identifiers on nested dialog actions.

     - Returns: A centered app-owned Android dialog above its blocking scrim.
     - Side effects: A permitted scrim tap invokes `onOutsideTap`.
     - Failure modes: Long caller content can exceed the fixed maximum unless it supplies a scroll
       container.
     */
    var body: some View {
        ZStack {
            Color.black.opacity(0.64)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    guard allowsOutsideDismissal else { return }
                    onOutsideTap()
                }

            content
                .frame(maxWidth: 640, maxHeight: 760)
                .background(AndroidDialogSurfacePalette.background(for: colorScheme))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
                .padding(24)
                .accessibilityElement(children: .contain)

            if UITestRuntimeConfiguration.enablesDetailedAccessibilityExports {
                AndroidActivityAccessibilityMarker(
                    label: "",
                    accessibilityIdentifier: accessibilityIdentifier,
                    surfaceColor: AndroidDialogSurfacePalette.background(for: colorScheme)
                )
            }
        }
    }
}
