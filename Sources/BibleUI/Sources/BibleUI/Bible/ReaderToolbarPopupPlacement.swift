import SwiftUI

/**
 Computes Android-style toolbar popup placement for reader overlays.

 Android toolbar popups open from the trailing app-bar rail even when the triggering icon is not
 the final overflow icon. This helper keeps that behavior shared between the reader overflow menu
 and the Bible quick selector: the trigger supplies vertical placement, while the popup right edge
 is pinned to the screen trailing inset. The calculation is deterministic and has no side effects.
 */
struct ReaderToolbarPopupPlacement: Equatable {
    /// Top-leading overlay offset used by SwiftUI's `.offset` modifier.
    let offset: CGSize

    /// Maximum visible popup height below the toolbar trigger and above the bottom safe area.
    let maximumHeight: CGFloat

    /**
     Bounds a toolbar popup width to the currently visible overlay space.

     SwiftUI can report transient zero or near-zero geometry during presentation and rotation
     transitions. Popup callers use this value for both placement and `.frame(width:)`, so the
     returned width is clamped before layout receives it.

     - Parameters:
       - containerWidth: Full overlay coordinate-space width.
       - safeAreaInsets: Safe-area insets reported by the overlay `GeometryProxy`.
       - preferredWidth: Width the popup would use when enough horizontal space exists.
       - maximumWidth: Maximum Android-style popup width for the concrete menu.
       - leadingInset: Minimum leading screen inset for very narrow containers.
       - trailingInset: Trailing inset for the shared app-bar popup rail.
     - Returns: A non-negative width no larger than the preferred width, maximum width, or
       available container width after safe-area and toolbar popup margins.
     - Side effects: none.
     - Failure modes: none; negative or undersized geometry is clamped to zero.
     */
    static func boundedWidth(
        containerWidth: CGFloat,
        safeAreaInsets: EdgeInsets = EdgeInsets(),
        preferredWidth: CGFloat,
        maximumWidth: CGFloat,
        leadingInset: CGFloat = 8,
        trailingInset: CGFloat = 8
    ) -> CGFloat {
        let resolvedLeadingInset = safeAreaInsets.leading + leadingInset
        let resolvedTrailingInset = safeAreaInsets.trailing + trailingInset
        let availableWidth = max(0, containerWidth - resolvedLeadingInset - resolvedTrailingInset)
        return min(max(0, preferredWidth), min(max(0, maximumWidth), availableWidth))
    }

    /**
     Resolves the top-leading offset for a trailing toolbar popup.

     - Parameters:
       - containerSize: Size of the overlay coordinate space.
       - safeAreaInsets: Safe-area insets reported by the overlay `GeometryProxy`.
       - triggerRect: Toolbar trigger bounds, if SwiftUI has reported them.
       - popupWidth: Final popup width chosen by the caller.
       - leadingInset: Minimum leading screen inset for very narrow containers.
       - trailingInset: Trailing inset for the shared app-bar popup rail.
       - verticalGap: Gap between the trigger bottom and popup top.
       - bottomInset: Minimum gap above the bottom safe area for scrollable popup content.
     - Returns: A placement whose right edge is pinned to the trailing rail and whose top follows
       the trigger bottom, falling back to a toolbar-height estimate when the trigger is unavailable,
       plus the remaining visible height available to scrollable popup content.
     - Side effects: none.
     - Failure modes: none; oversized widths are clamped to the safe horizontal space.
     */
    static func trailingToolbarPopup(
        containerSize: CGSize,
        safeAreaInsets: EdgeInsets,
        triggerRect: CGRect?,
        popupWidth: CGFloat,
        leadingInset: CGFloat = 8,
        trailingInset: CGFloat = 8,
        verticalGap: CGFloat = 6,
        bottomInset: CGFloat = 8
    ) -> ReaderToolbarPopupPlacement {
        let resolvedLeadingInset = safeAreaInsets.leading + leadingInset
        let resolvedTrailingInset = safeAreaInsets.trailing + trailingInset
        let availableWidth = max(0, containerSize.width - resolvedLeadingInset - resolvedTrailingInset)
        let width = min(max(0, popupWidth), availableWidth)
        let trailingRightEdge = containerSize.width - resolvedTrailingInset
        let fallbackBottomEdge = safeAreaInsets.top + 38
        let resolvedBottomEdge = triggerRect?.maxY ?? fallbackBottomEdge
        let maximumX = max(resolvedLeadingInset, containerSize.width - width - resolvedTrailingInset)
        let x = min(max(resolvedLeadingInset, trailingRightEdge - width), maximumX)
        let y = max(safeAreaInsets.top + verticalGap, resolvedBottomEdge + verticalGap)
        let maximumHeight = max(0, containerSize.height - y - safeAreaInsets.bottom - bottomInset)

        return ReaderToolbarPopupPlacement(
            offset: CGSize(width: x, height: y),
            maximumHeight: maximumHeight
        )
    }
}
