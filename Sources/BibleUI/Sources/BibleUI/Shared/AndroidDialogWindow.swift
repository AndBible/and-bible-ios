// AndroidDialogWindow.swift -- Shared app-owned Android dialog presentation

import SwiftUI

/**
 Applies Android's `wrap_content` dialog measurement inside a finite window viewport.

 AppCompat measures an AlertDialog's content against an `AT_MOST` height constraint, then reports
 the content's measured height instead of expanding the dialog to that constraint. SwiftUI's
 flexible `frame(maxHeight:)` does the opposite: it accepts all proposed height and makes short
 dialogs appear full-screen. This layout preserves the finite proposal needed by adaptive scroll
 regions while returning the child's shorter measured height whenever its content fits.

 Inputs: one dialog content view and the parent window's finite proposal

 Output: the content's measured height capped only by the available dialog viewport

 Side effects: none

 Failure modes: an empty layout reports zero size; callers must provide one dialog content view
 */
struct AndroidDialogViewportLayout: Layout {
    /**
     Measures the dialog with Android's `AT_MOST` height contract.

     - Parameters:
       - proposal: Finite parent geometry after the shared outer margin.
       - subviews: The single caller-owned dialog content hierarchy.
       - cache: Unused because dialog content can change while presented.
     - Returns: Child-measured width and intrinsic-or-capped height.
     - Side effects: asks the child to measure once under the bounded proposal.
     - Failure modes: an absent child reports zero size.
     */
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let content = subviews.first else {
            return .zero
        }

        let availableHeight = proposal.height.map { max($0, 0) }
        let measuredSize = content.sizeThatFits(
            ProposedViewSize(width: proposal.width, height: availableHeight)
        )

        return CGSize(
            width: measuredSize.width,
            height: availableHeight.map {
                min(max(measuredSize.height, 0), $0)
            } ?? max(measuredSize.height, 0)
        )
    }

    /**
     Places the measured dialog content in the viewport reported by `sizeThatFits`.

     - Parameters:
       - bounds: Final intrinsic-or-capped dialog bounds.
       - proposal: Parent proposal retained for the Layout protocol contract.
       - subviews: The single caller-owned dialog content hierarchy.
       - cache: Unused.
     - Side effects: places the child at the viewport origin.
     - Failure modes: an absent child performs no placement.
     */
    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.first else {
            return
        }

        content.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

/**
 Presents feature content inside the application's shared Android-style dialog window.

 The window centralizes the scrim, AppCompat DayNight surface palette, Android `wrap_content`
 measurement, outside-tap policy, and accessibility containment. Callers provide semantic dialog
 content and decide whether outside taps may dismiss while work is active.

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
     - Failure modes: Long caller content is capped to the viewport; semantic overflow regions must
       still provide scrolling.
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

            AndroidDialogViewportLayout {
                content
            }
                .frame(maxWidth: 640)
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
