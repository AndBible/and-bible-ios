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
     - Failure modes: none; oversized widths are clamped to the available horizontal space.
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
        let availableWidth = max(0, containerSize.width - leadingInset - trailingInset)
        let width = min(max(0, popupWidth), availableWidth)
        let trailingRightEdge = containerSize.width - trailingInset
        let fallbackBottomEdge = safeAreaInsets.top + 38
        let resolvedBottomEdge = triggerRect?.maxY ?? fallbackBottomEdge
        let maximumX = max(leadingInset, containerSize.width - width - trailingInset)
        let x = min(max(leadingInset, trailingRightEdge - width), maximumX)
        let y = max(safeAreaInsets.top + verticalGap, resolvedBottomEdge + verticalGap)
        let maximumHeight = max(0, containerSize.height - y - safeAreaInsets.bottom - bottomInset)

        return ReaderToolbarPopupPlacement(
            offset: CGSize(width: x, height: y),
            maximumHeight: maximumHeight
        )
    }
}
