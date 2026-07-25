import XCTest
import BibleCore
@testable import BibleUI

/**
 Protects the Android shared window-control style used by pane hamburgers and footer buttons.

 Android renders both controls through the same `WindowButtonWidget` family, with the top-right
 pane button using the non-restore style and the bottom strip using restore-button resources. These
 tests keep iOS from drifting back to SF Symbol/iOS control styling for pane buttons while preserving
 the existing footer semantics.
 */
final class AndroidWindowControlStyleTests: XCTestCase {
    /**
     Verifies the top-right pane hamburger uses Android's non-restore window-button metrics.

     Android's `window_button.xml` resolves the control to a 40dp square, 6dp radius surface with
     the literal hamburger glyph. A failure means iOS is likely rendering an iOS-native button
     instead of the Android pane control.
     */
    func testPaneButtonMetricsMatchAndroidNonRestoreWindowButton() {
        XCTAssertEqual(AndroidWindowButtonMetrics.buttonSize, 40)
        XCTAssertEqual(AndroidWindowButtonMetrics.cornerRadius, 6)
        XCTAssertEqual(AndroidWindowButtonMetrics.paneMenuGlyph, "☰")
        XCTAssertEqual(AndroidWindowButtonMetrics.paneMenuTextSize, 22)
        XCTAssertEqual(AndroidWindowButtonMetrics.paneLinksIconName, "SettingsIconLink")
        XCTAssertEqual(AndroidWindowButtonMetrics.paneLinksIconSize, 14)
        XCTAssertEqual(WindowTabBarLayout.fixedButtonSize, AndroidWindowButtonMetrics.buttonSize)
    }

    /**
     Verifies the pane sync/pin status overlays mirror Android's `window_button.xml` anatomy.

     Android overlays a 12dip `ic_sync_white_24dp` ImageView with 2.5dip start/top padding in the
     button's top-left corner, a 10sp sync-group number 1dip after it, and a 12dip `ic_pin`
     ImageView directly below the sync box. A failure means the pane button lost the Android
     status-overlay geometry or drifted to different assets.
     */
    func testPaneStatusOverlayMetricsMatchAndroidWindowButtonLayout() {
        XCTAssertEqual(AndroidWindowButtonMetrics.paneSyncIconName, "WindowSyncStatus")
        XCTAssertEqual(AndroidWindowButtonMetrics.panePinIconName, "WindowPinStatus")
        XCTAssertEqual(AndroidWindowButtonMetrics.paneStatusIconBoxSize, 12)
        XCTAssertEqual(AndroidWindowButtonMetrics.paneStatusIconInset, 2.5)
        XCTAssertEqual(AndroidWindowButtonMetrics.paneStatusIconSize, 9.5)
        XCTAssertEqual(AndroidWindowButtonMetrics.paneSyncGroupTextSize, 10)
        XCTAssertEqual(AndroidWindowButtonMetrics.paneSyncGroupLeadingPadding, 1)
        XCTAssertEqual(AndroidWindowButtonMetrics.panePinIconTopInset, 13.25)
    }

    /**
     Verifies the pane status-overlay tint matches Android's `bar_window_button_icon_tint`.

     Android tints both mini overlays with `bar_window_button_icon_tint` (#E8E8E8 day, #939393
     night) and rewrites them to black in monochrome mode. A failure means the pane sync/pin
     overlays no longer track Android's day/night/e-ink resources.
     */
    func testPaneStatusOverlayTintMatchesAndroidBarWindowButtonIconTint() {
        let day = AndroidWindowButtonPalette.resolved(for: .standard)
        XCTAssertEqual(day.statusIconColor.argbInt, Int(Int32(bitPattern: 0xFFE8E8E8)))

        let night = AndroidWindowButtonPalette.resolved(
            for: ReaderThemeSurfacePalette(settings: .appDefaults, nightMode: true)
        )
        XCTAssertEqual(night.statusIconColor.argbInt, Int(Int32(bitPattern: 0xFF939393)))

        let monochrome = AndroidWindowButtonPalette.resolved(for: .standard, monochromeMode: true)
        XCTAssertEqual(monochrome.statusIconColor.argbInt, Int(Int32(bitPattern: 0xFF000000)))
    }

    /**
     Verifies day-mode pane button colors match Android resource values.

     Android non-restore pane buttons use `window_button_active` for the active pane and
     `window_button` for inactive visible panes, unlike restore buttons which use the footer
     `bar_window_button*` colors. A failure here means iOS is conflating the two Android roles.
     */
    func testDayPaneButtonPaletteMatchesAndroidResources() {
        let palette = AndroidWindowButtonPalette.resolved(for: .standard)

        XCTAssertEqual(palette.paneButtonTextColor.argbInt, Int(Int32(bitPattern: 0x86FFFFFF)))
        XCTAssertEqual(palette.paneButtonBackgroundColor(isActive: true).argbInt, Int(Int32(bitPattern: 0xB7525252)))
        XCTAssertEqual(palette.paneButtonBackgroundColor(isActive: false).argbInt, Int(Int32(bitPattern: 0x118D8D8D)))
    }

    /**
     Verifies night-mode pane button colors follow Android night resources.

     Android night resources dim only `window_button_text_colour` for this non-restore control; the
     background attributes remain the same. A failure means night pane buttons no longer match the
     Android side-window affordance.
    */
    func testNightPaneButtonPaletteMatchesAndroidResources() {
        let palette = AndroidWindowButtonPalette.resolved(
            for: ReaderThemeSurfacePalette(settings: .appDefaults, nightMode: true)
        )

        XCTAssertEqual(palette.paneButtonTextColor.argbInt, Int(Int32(bitPattern: 0x32FFFFFF)))
        XCTAssertEqual(palette.paneButtonBackgroundColor(isActive: true).argbInt, Int(Int32(bitPattern: 0xB7525252)))
        XCTAssertEqual(palette.paneButtonBackgroundColor(isActive: false).argbInt, Int(Int32(bitPattern: 0x118D8D8D)))
    }

    /**
     Verifies Android monochrome mode rewrites top-right pane buttons to black-on-white.

     Android's `WindowButtonWidget.applyMonochromeStyle` overrides the normal active/inactive
     non-restore resources with a white fill, black foreground, and black stroke. A failure means
     the iOS pane button is still using theme colors after the global e-ink mode is enabled.
     */
    func testMonochromePaneButtonPaletteMatchesAndroidWidgetRewrite() {
        let palette = AndroidWindowButtonPalette.resolved(for: .standard, monochromeMode: true)

        XCTAssertEqual(palette.paneButtonTextColor.argbInt, Int(Int32(bitPattern: 0xFF000000)))
        XCTAssertEqual(palette.paneLinksIconColor.argbInt, Int(Int32(bitPattern: 0xFF000000)))
        XCTAssertEqual(palette.paneButtonBackgroundColor(isActive: true).argbInt, Int(Int32(bitPattern: 0xFFFFFFFF)))
        XCTAssertEqual(palette.paneButtonBackgroundColor(isActive: false).argbInt, Int(Int32(bitPattern: 0xFFFFFFFF)))
        XCTAssertEqual(palette.paneButtonStrokeColor.argbInt, Int(Int32(bitPattern: 0xFF000000)))
        XCTAssertEqual(palette.paneButtonStrokeWidth(isActive: true), 2)
        XCTAssertEqual(palette.paneButtonStrokeWidth(isActive: false), 1)
    }

    /**
     Verifies Android monochrome mode inverts visible restore-strip buttons.

     Android restore buttons are black with white foreground while visible, but white with black
     foreground when minimized/hidden. A failure means iOS is applying one flat monochrome color to
     every restore button rather than preserving Android's per-window visibility contract.
     */
    func testMonochromeRestoreButtonPaletteInvertsVisibleButtons() {
        let palette = AndroidWindowButtonPalette.resolved(for: .standard, monochromeMode: true)

        XCTAssertEqual(palette.backgroundColor(isActive: false, isVisible: true).argbInt, Int(Int32(bitPattern: 0xFF000000)))
        XCTAssertEqual(palette.backgroundColor(isActive: false, isVisible: false).argbInt, Int(Int32(bitPattern: 0xFFFFFFFF)))
        XCTAssertEqual(palette.restoreStripBackgroundColor.argbInt, Int(Int32(bitPattern: 0xFFFFFFFF)))
        XCTAssertEqual(palette.footerButtonForegroundColor(isVisible: true).argbInt, Int(Int32(bitPattern: 0xFFFFFFFF)))
        XCTAssertEqual(palette.footerButtonForegroundColor(isVisible: false).argbInt, Int(Int32(bitPattern: 0xFF000000)))
        XCTAssertEqual(
            palette.footerIconColor(isLinksWindow: true, isVisible: true).argbInt,
            Int(Int32(bitPattern: 0xFFFFFFFF))
        )
        XCTAssertEqual(palette.footerButtonStrokeWidth(isActive: true), 2)
        XCTAssertEqual(palette.footerButtonStrokeWidth(isActive: false), 1)
        XCTAssertEqual(palette.unmaximizeButtonStrokeWidth(), 1)
    }

    /**
     Verifies top-right pane-button drag gestures follow Android window-button actions.

     Android maps vertical swipes on the pane button to maximize/minimize and ignores non-vertical
     movement. A failure means the iOS pane button either lost Android gesture affordances or became
     too eager to mutate window state for diagonal/horizontal drags.
     */
    func testPaneButtonVerticalDragClassifierMatchesAndroidActions() {
        XCTAssertEqual(
            AndroidPaneWindowButtonGestureAction.action(forDragTranslation: CGSize(width: 0, height: -44)),
            .maximize
        )
        XCTAssertEqual(
            AndroidPaneWindowButtonGestureAction.action(forDragTranslation: CGSize(width: 0, height: 44)),
            .minimize
        )
        XCTAssertEqual(
            AndroidPaneWindowButtonGestureAction.action(forDragTranslation: CGSize(width: 44, height: 8)),
            .none
        )
        XCTAssertEqual(
            AndroidPaneWindowButtonGestureAction.action(forDragTranslation: CGSize(width: 8, height: 10)),
            .none
        )
    }
}
