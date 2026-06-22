// WindowTabBarLayout.swift -- Android-parity sizing for reader window buttons

import CoreGraphics

/**
 Defines the compact window-button metrics used by the reader footer.

 Android renders each bottom window control from `window_button.xml`, whose root button width and
 height both resolve to `?windowButtonHeight = 40dp`. In multi-window mode, Android reserves the
 separate 20dp touch extension and 30dp hide/restore arrow before the restore buttons; iOS mirrors
 those fixed logical sizes instead of keeping the add-window control visible in every mode.

 Inputs:
 - `tabWidth`: document button width used by occupied-strip calculations.
 - `windowCount`: number of open document windows represented by fixed buttons.

 Outputs:
 - fixed button width for each document window
 - occupied strip width including horizontal padding, inter-button spacing, and the active footer
   control for the current window mode
 - reserved footer height for the reader content when Android keeps the restore buttons visible

 Side effects: none.
 Failure modes: occupied-width calculations clamp negative widths and negative window counts into
   deterministic non-negative layout results.
 Determinism: pure value calculations; no UI state, filesystem, or platform calls are involved.
 */
enum WindowTabBarLayout {
    /// Android `windowButtonHeight`, mirrored as a logical iOS point size.
    static let fixedButtonSize: CGFloat = 40

    /// Smallest supported document tab width; equal to Android's fixed button width.
    static let minimumTabWidth: CGFloat = fixedButtonSize

    /// Largest supported document tab width; equal to Android's fixed button width.
    static let maximumTabWidth: CGFloat = fixedButtonSize

    /// Horizontal spacing between compact window buttons.
    static let spacing: CGFloat = 6

    /// Total horizontal inset around the scrollable button strip; callers split it per side.
    static let horizontalPadding: CGFloat = 24

    /// Vertical inset around the 40pt Android-style button.
    static let verticalPadding: CGFloat = 6

    /// Full footer height needed by a 40pt button plus vertical padding.
    static let barHeight: CGFloat = fixedButtonSize + (verticalPadding * 2)

    /// Reader layout height reserved when Android collapses the multi-window restore strip.
    static let collapsedBarHeight: CGFloat = 0

    /// Android `hideRestoreButtonExtension` width that expands the restore-toggle tap target.
    static let restoreToggleTouchExtensionWidth: CGFloat = 20

    /// Android `hideRestoreButton` width that draws the left/right restore-strip arrow.
    static let restoreToggleButtonWidth: CGFloat = 30

    /// Footer control width used when Android shows only the add-window button.
    static let singleWindowControlWidth: CGFloat = fixedButtonSize

    /// Footer control width used when Android shows the multi-window restore-strip toggle.
    static let multiWindowControlWidth: CGFloat = restoreToggleTouchExtensionWidth + restoreToggleButtonWidth

    /// Width of the hidden restore-strip affordance left reachable at the trailing screen edge.
    static let collapsedControlWidth: CGFloat = multiWindowControlWidth + horizontalPadding

    /**
     Returns the Android-parity fixed tab width for the current footer.

     - Returns: `40`, matching Android's `windowButtonHeight` dimension.
     - Side effects: None.
     - Failure modes: None.
     */
    static func tabWidth() -> CGFloat {
        return fixedButtonSize
    }

    /**
     Computes multi-window footer width with Android's restore-strip toggle.

     - Parameters:
       - tabWidth: Width used for each document window button.
       - windowCount: Number of open document windows. Negative counts are treated as zero.
     - Returns: Width consumed by padding, restore-toggle control, document buttons, and spacing.
     - Side effects: None.
     - Failure modes: None; invalid inputs are clamped to a non-negative result.
     */
    static func multiWindowOccupiedWidth(tabWidth: CGFloat, windowCount: Int) -> CGFloat {
        let count = max(0, windowCount)
        let buttonWidth = max(0, tabWidth)
        guard count > 0 else {
            return horizontalPadding + multiWindowControlWidth
        }

        return horizontalPadding
            + multiWindowControlWidth
            + (buttonWidth * CGFloat(count))
            + (spacing * CGFloat(count))
    }

    /**
     Computes the height that should be reserved below the reader content.

     Android's WebView bottom offset includes `windowButtonHeight` only while the restore buttons
     are visible. When the multi-window strip is hidden, Android translates the button container so
     only the restore affordance remains reachable, but it does not reserve button height for the
     document content. Single-window mode remains expanded because Android forces
     `restoreButtonsVisible = true` while showing the add-window button.

     - Parameters:
       - restoreButtonsVisible: Persisted Android restore-strip visibility flag.
       - isSingleWindowFooterMode: Whether the footer is showing Android's single-window add button.
     - Returns: Full footer height when content should reserve the button strip, otherwise zero.
     - Side effects: None.
     - Failure modes: None; this is a pure mapping of Android footer state to layout height.
     */
    static func reservedHeight(
        restoreButtonsVisible: Bool,
        isSingleWindowFooterMode: Bool
    ) -> CGFloat {
        if isSingleWindowFooterMode || restoreButtonsVisible {
            return barHeight
        }
        return collapsedBarHeight
    }
}
