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

    /// Shared Android link-marker asset used for links-window controls.
    static let paneLinksIconName = "SettingsIconLink"

    /// Android links-window marker icon size used inside compact window buttons.
    static let paneLinksIconSize: CGFloat = 14

    /// Android `ic_sync_white_24dp` status overlay asset used inside window buttons.
    static let paneSyncIconName = "WindowSyncStatus"

    /// Android `ic_pin` status overlay asset used inside window buttons.
    static let panePinIconName = "WindowPinStatus"

    /// Android status-overlay `ImageView` box (12dip in `window_button.xml`).
    static let paneStatusIconBoxSize: CGFloat = 12

    /// Android status-overlay internal padding (2.5dip start, and top for the sync icon).
    static let paneStatusIconInset: CGFloat = 2.5

    /// Rendered status glyph size after Android's internal 2.5dip `ImageView` padding.
    static let paneStatusIconSize: CGFloat = paneStatusIconBoxSize - paneStatusIconInset

    /// Android sync-group label text size (10sp on `syncGroup`).
    static let paneSyncGroupTextSize: CGFloat = 10

    /// Android sync-group label leading padding (1dip after the sync icon).
    static let paneSyncGroupLeadingPadding: CGFloat = 1

    /**
     Pin overlay top inset: below the 12dip sync box plus the fit-center offset of the square pin
     drawable inside its 9.5x12 padded content area.
     */
    static let panePinIconTopInset: CGFloat =
        paneStatusIconBoxSize + ((paneStatusIconBoxSize - paneStatusIconSize) / 2)

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

    /// Fill used behind the footer restore-button strip.
    let restoreStripBackgroundColor: Color

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

    /// Tint for Android links-window icons inside top-right pane buttons.
    let paneLinksIconColor: Color

    /// Tint for sync and pin overlays.
    let statusIconColor: Color

    /// Text color for top-right non-restore pane buttons.
    let paneButtonTextColor: Color

    /// Fill used by the active top-right non-restore pane button.
    let activePaneButtonBackgroundColor: Color

    /// Fill used by inactive top-right non-restore pane buttons.
    let inactivePaneButtonBackgroundColor: Color

    /// Stroke color used by top-right non-restore pane buttons.
    let paneButtonStrokeColor: Color

    /// Whether Android's monochrome widget override is active.
    let usesMonochromeStyle: Bool

    /**
     Resolves Android day/night window-button colors from the active reader surface.

     - Parameter surfacePalette: Reader chrome palette derived from text display settings.
     - Returns: An Android resource color tuple represented as SwiftUI colors.
     - Side effects: None.
     - Failure modes: None; color integer parsing is deterministic for all inputs.
     */
    static func resolved(
        for surfacePalette: ReaderThemeSurfacePalette,
        monochromeMode: Bool = false
    ) -> AndroidWindowButtonPalette {
        let palette: AndroidWindowButtonPalette
        if isDarkSurface(surfacePalette.backgroundColorInt) {
            palette = AndroidWindowButtonPalette(
                visibleButtonBackgroundColor: color(argb: 0xFF6A6A6A),
                hiddenButtonBackgroundColor: color(argb: 0xFF2E2E2E),
                addButtonBackgroundColor: color(argb: 0xB7525252),
                restoreStripBackgroundColor: surfacePalette.backgroundColor,
                strokeColor: color(argb: 0xFF686868),
                activeStrokeColor: color(argb: 0xFF002AFF),
                windowButtonTextColor: color(argb: 0xFF939393),
                categoryIconColor: color(argb: 0xFF939393),
                linksIconColor: color(argb: 0xFF7088FF),
                paneLinksIconColor: color(argb: 0xFF7088FF),
                statusIconColor: color(argb: 0xFF939393),
                paneButtonTextColor: color(argb: 0x32FFFFFF),
                activePaneButtonBackgroundColor: color(argb: 0xB7525252),
                inactivePaneButtonBackgroundColor: color(argb: 0x118D8D8D),
                paneButtonStrokeColor: .clear,
                usesMonochromeStyle: false
            )
        } else {
            palette = AndroidWindowButtonPalette(
                visibleButtonBackgroundColor: color(argb: 0xFF535353),
                hiddenButtonBackgroundColor: color(argb: 0xFF878787),
                addButtonBackgroundColor: color(argb: 0xB7525252),
                restoreStripBackgroundColor: surfacePalette.backgroundColor,
                strokeColor: color(argb: 0xFF686868),
                activeStrokeColor: color(argb: 0xFF002AFF),
                windowButtonTextColor: color(argb: 0xFFE8E8E8),
                categoryIconColor: color(argb: 0xFFAAAAAA),
                linksIconColor: color(argb: 0xFF7088FF),
                paneLinksIconColor: color(argb: 0xFF7088FF),
                statusIconColor: color(argb: 0xFFE8E8E8),
                paneButtonTextColor: color(argb: 0x86FFFFFF),
                activePaneButtonBackgroundColor: color(argb: 0xB7525252),
                inactivePaneButtonBackgroundColor: color(argb: 0x118D8D8D),
                paneButtonStrokeColor: .clear,
                usesMonochromeStyle: false
            )
        }

        return monochromeMode ? palette.applyingMonochromeStyle() : palette
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
     Returns the foreground color for a document footer button.

     Android monochrome mode inverts visible restore buttons: visible buttons are black with white
     foreground, while minimized buttons are white with black foreground. Non-monochrome mode keeps
     the normal restore-strip text resource color.

     - Parameter isVisible: Whether the represented window is visible rather than minimized.
     - Returns: Android restore-button foreground color.
     - Side effects: None.
     - Failure modes: None.
     */
    func footerButtonForegroundColor(isVisible: Bool) -> Color {
        guard usesMonochromeStyle else { return windowButtonTextColor }
        return isVisible ? Self.color(argb: 0xFFFFFFFF) : Self.color(argb: 0xFF000000)
    }

    /**
     Returns the icon tint for a document footer button.

     - Parameters:
       - isLinksWindow: Whether the represented window is Android's links target.
       - isVisible: Whether the represented window is visible rather than minimized.
     - Returns: Android restore-button icon tint.
     - Side effects: None.
     - Failure modes: None.
     */
    func footerIconColor(isLinksWindow: Bool, isVisible: Bool) -> Color {
        guard usesMonochromeStyle else {
            return isLinksWindow ? linksIconColor : categoryIconColor
        }
        return footerButtonForegroundColor(isVisible: isVisible)
    }

    /**
     Returns the overlay icon tint for sync and pin status inside footer buttons.

     - Parameter isVisible: Whether the represented window is visible rather than minimized.
     - Returns: Android restore-button status tint.
     - Side effects: None.
     - Failure modes: None.
     */
    func footerStatusIconColor(isVisible: Bool) -> Color {
        usesMonochromeStyle ? footerButtonForegroundColor(isVisible: isVisible) : statusIconColor
    }

    /**
     Returns the border width for a document footer button.

     Android monochrome mode uses a 2dp active stroke and 1dp inactive stroke. Non-monochrome iOS
     retains the existing active emphasis used by the restore strip.

     - Parameter isActive: Whether the represented window is active.
     - Returns: Stroke width in logical points.
     - Side effects: None.
     - Failure modes: None.
     */
    func footerButtonStrokeWidth(isActive: Bool) -> CGFloat {
        if usesMonochromeStyle {
            return isActive ? 2 : 1
        }
        return isActive ? 3 : 1
    }

    /**
     Returns the border width for Android's maximized-window restore button.

     Android creates the unmaximize affordance as a restore button while the repository is
     maximized. In that state `WindowButtonWidget` intentionally reports `isActive == false`, so
     the control uses the visible-window border instead of the active-window border.

     - Returns: Android restore-button stroke width for the maximized-window affordance.
     - Side effects: None.
     - Failure modes: None.
     */
    func unmaximizeButtonStrokeWidth() -> CGFloat {
        footerButtonStrokeWidth(isActive: false)
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
     Returns the border width for a top-right non-restore pane button.

     - Parameter isActive: Whether the pane owns Android's active window.
     - Returns: Stroke width in logical points.
     - Side effects: None.
     - Failure modes: None.
     */
    func paneButtonStrokeWidth(isActive: Bool) -> CGFloat {
        guard usesMonochromeStyle else { return 0 }
        return isActive ? 2 : 1
    }

    /**
     Applies Android's global monochrome/e-ink override to the window-button widget family.

     - Returns: A palette matching `WindowButtonWidget.applyMonochromeStyle`.
     - Side effects: None.
     - Failure modes: None.
     */
    private func applyingMonochromeStyle() -> AndroidWindowButtonPalette {
        AndroidWindowButtonPalette(
            visibleButtonBackgroundColor: Self.color(argb: 0xFF000000),
            hiddenButtonBackgroundColor: Self.color(argb: 0xFFFFFFFF),
            addButtonBackgroundColor: Self.color(argb: 0xFFFFFFFF),
            restoreStripBackgroundColor: Self.color(argb: 0xFFFFFFFF),
            strokeColor: Self.color(argb: 0xFF000000),
            activeStrokeColor: Self.color(argb: 0xFF000000),
            windowButtonTextColor: Self.color(argb: 0xFF000000),
            categoryIconColor: Self.color(argb: 0xFF000000),
            linksIconColor: Self.color(argb: 0xFF000000),
            paneLinksIconColor: Self.color(argb: 0xFF000000),
            statusIconColor: Self.color(argb: 0xFF000000),
            paneButtonTextColor: Self.color(argb: 0xFF000000),
            activePaneButtonBackgroundColor: Self.color(argb: 0xFFFFFFFF),
            inactivePaneButtonBackgroundColor: Self.color(argb: 0xFFFFFFFF),
            paneButtonStrokeColor: Self.color(argb: 0xFF000000),
            usesMonochromeStyle: true
        )
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
