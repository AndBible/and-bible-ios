// AndroidWindowButtonStyle.swift -- Shared Android window-control metrics and colors

import CoreGraphics
import SwiftUI

/**
 Shared Android window-button metrics used by reader pane and footer controls.

 Android renders both top-right pane buttons and bottom restore-strip buttons through the
 `WindowButtonWidget` family. The visual roles differ, but the core control size and corner radius
 come from the same `window_button.xml`/`barstyles.xml` resource contract.
 */
enum AndroidWindowButtonMetrics {
    /// Android `?windowButtonHeight`, mirrored as a logical iOS point size.
    static let buttonSize: CGFloat = 40

    /// Android `window_button.xml` corner radius.
    static let cornerRadius: CGFloat = 6

    /// Android's modern pane-menu text glyph for non-restore window buttons.
    static let paneMenuGlyph = "☰"

    /// Android pane-menu glyph text size in scalable pixels, mirrored as points.
    static let paneMenuTextSize: CGFloat = 22

    /// Android pane button sits directly on the pane corner rather than inside extra native inset.
    static let paneOverlayInset: CGFloat = 0
}

/**
 Classifies Android pane-window-button gestures without touching window state.

 Android maps vertical swipes on the non-restore pane button to maximize/minimize while taps open
 the popup menu and long presses minimize. SwiftUI supplies drag translations instead of Android's
 `GestureDetector` events, so this classifier keeps the iOS thresholding testable and isolated from
 view mutation.
 */
enum AndroidPaneWindowButtonGestureAction: Equatable {
    /// No Android pane-window action should run for the gesture.
    case none

    /// Open the pane popup menu.
    case openMenu

    /// Minimize the pane window.
    case minimize

    /// Maximize the pane window.
    case maximize

    /// Minimum vertical movement required before a drag becomes a window-control swipe.
    private static let verticalSwipeThreshold: CGFloat = 28

    /**
     Resolves a SwiftUI drag translation into Android's vertical pane-button action.

     - Parameter translation: Final drag translation reported by SwiftUI.
     - Returns: `.maximize` for an upward vertical swipe, `.minimize` for downward, otherwise
       `.none` for short, horizontal, or ambiguous drags.
     - Side effects: None.
     - Failure modes: None; all finite and non-finite values resolve deterministically.
     */
    static func action(forDragTranslation translation: CGSize) -> AndroidPaneWindowButtonGestureAction {
        guard translation.width.isFinite, translation.height.isFinite else { return .none }
        let verticalDistance = abs(translation.height)
        let horizontalDistance = abs(translation.width)
        guard verticalDistance >= verticalSwipeThreshold, verticalDistance > horizontalDistance else {
            return .none
        }
        return translation.height < 0 ? .maximize : .minimize
    }
}

/**
 Maps Android window-button resource colors into SwiftUI colors.

 Android uses one widget family for both pane buttons and restore-strip buttons, but resource
 overlays differ by role:
 - pane buttons use the non-restore `window_button*` resources
 - footer restore buttons use `bar_window_button*` resources

 Keeping both roles in one palette prevents the iOS pane hamburger from drifting into native iOS
 styling while preserving the existing compact footer strip.
 */
struct AndroidWindowButtonPalette {
    /// Fill used by visible window restore buttons.
    let visibleButtonBackgroundColor: Color

    /// Fill used by minimized or otherwise non-visible restore buttons.
    let hiddenButtonBackgroundColor: Color

    /// Fill used by the add-window button.
    let addButtonBackgroundColor: Color

    /// Neutral restore-button border color.
    let strokeColor: Color

    /// Active restore-button border color.
    let activeStrokeColor: Color

    /// Text color for compact footer title/document labels.
    let windowButtonTextColor: Color

    /// Tint for ordinary document category icons.
    let categoryIconColor: Color

    /// Tint for Android links-window icons.
    let linksIconColor: Color

    /// Tint for sync and pin overlays.
    let statusIconColor: Color

    /// Text color for top-right non-restore pane buttons.
    let paneButtonTextColor: Color

    /// Fill used by the active top-right non-restore pane button.
    let activePaneButtonBackgroundColor: Color

    /// Fill used by inactive top-right non-restore pane buttons.
    let inactivePaneButtonBackgroundColor: Color

    /**
     Resolves Android day/night window-button colors from the active reader surface.

     - Parameter surfacePalette: Reader chrome palette derived from text display settings.
     - Returns: An Android resource color tuple represented as SwiftUI colors.
     - Side effects: None.
     - Failure modes: None; color integer parsing is deterministic for all inputs.
     */
    static func resolved(for surfacePalette: ReaderThemeSurfacePalette) -> AndroidWindowButtonPalette {
        if isDarkSurface(surfacePalette.backgroundColorInt) {
            return AndroidWindowButtonPalette(
                visibleButtonBackgroundColor: color(argb: 0xFF6A6A6A),
                hiddenButtonBackgroundColor: color(argb: 0xFF2E2E2E),
                addButtonBackgroundColor: color(argb: 0xB7525252),
                strokeColor: color(argb: 0xFF686868),
                activeStrokeColor: color(argb: 0xFF002AFF),
                windowButtonTextColor: color(argb: 0xFF939393),
                categoryIconColor: color(argb: 0xFF939393),
                linksIconColor: color(argb: 0xFF7088FF),
                statusIconColor: color(argb: 0xFF939393),
                paneButtonTextColor: color(argb: 0x32FFFFFF),
                activePaneButtonBackgroundColor: color(argb: 0xB7525252),
                inactivePaneButtonBackgroundColor: color(argb: 0x118D8D8D)
            )
        }

        return AndroidWindowButtonPalette(
            visibleButtonBackgroundColor: color(argb: 0xFF535353),
            hiddenButtonBackgroundColor: color(argb: 0xFF878787),
            addButtonBackgroundColor: color(argb: 0xB7525252),
            strokeColor: color(argb: 0xFF686868),
            activeStrokeColor: color(argb: 0xFF002AFF),
            windowButtonTextColor: color(argb: 0xFFE8E8E8),
            categoryIconColor: color(argb: 0xFFAAAAAA),
            linksIconColor: color(argb: 0xFF7088FF),
            statusIconColor: color(argb: 0xFFE8E8E8),
            paneButtonTextColor: color(argb: 0x86FFFFFF),
            activePaneButtonBackgroundColor: color(argb: 0xB7525252),
            inactivePaneButtonBackgroundColor: color(argb: 0x118D8D8D)
        )
    }

    /**
     Returns the fill color for a document footer button.

     - Parameters:
       - isActive: Whether the represented window is the active reader window.
       - isVisible: Whether the represented window is currently visible rather than minimized.
     - Returns: Android visible or hidden restore-button fill color.
     - Side effects: None.
     - Failure modes: None.
     */
    func backgroundColor(isActive: Bool, isVisible: Bool) -> Color {
        isActive || isVisible ? visibleButtonBackgroundColor : hiddenButtonBackgroundColor
    }

    /**
     Returns the fill color for a top-right non-restore pane button.

     - Parameter isActive: Whether the pane owns Android's active window.
     - Returns: Android active or inactive non-restore pane-button fill color.
     - Side effects: None.
     - Failure modes: None.
     */
    func paneButtonBackgroundColor(isActive: Bool) -> Color {
        isActive ? activePaneButtonBackgroundColor : inactivePaneButtonBackgroundColor
    }

    /**
     Converts an Android unsigned ARGB resource value into SwiftUI `Color`.

     - Parameter argb: Android ARGB resource value, including alpha.
     - Returns: SwiftUI color using the app's signed-ARGB bridge initializer.
     - Side effects: None.
     - Failure modes: None; bit-pattern conversion preserves all 32 bits.
     */
    private static func color(argb: UInt32) -> Color {
        Color(argbInt: Int(Int32(bitPattern: argb)))
    }

    /**
     Classifies the active reader surface as dark or light for Android resource selection.

     - Parameter argbInt: Signed Android ARGB integer from `ReaderThemeSurfacePalette`.
     - Returns: `true` when relative luminance is below the midpoint.
     - Side effects: None.
     - Failure modes: None; invalid sign-extension cases are normalized by truncating to 32 bits.
     */
    private static func isDarkSurface(_ argbInt: Int) -> Bool {
        let value = UInt32(bitPattern: Int32(truncatingIfNeeded: argbInt))
        let red = Double((value >> 16) & 0xFF)
        let green = Double((value >> 8) & 0xFF)
        let blue = Double(value & 0xFF)
        let luminance = ((0.2126 * red) + (0.7152 * green) + (0.0722 * blue)) / 255
        return luminance < 0.5
    }
}

/// Compatibility alias for the existing footer code while the shared palette owns both roles.
typealias AndroidWindowTabPalette = AndroidWindowButtonPalette
