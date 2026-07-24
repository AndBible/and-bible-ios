// ReaderThemeSurfacePaletteTests.swift -- Reader chrome theme color coverage

import XCTest
import BibleCore
@testable import BibleUI

/**
 Regression tests for native reader chrome colors derived from `TextDisplaySettings`.

 These tests are pure value checks with no persistence, simulator, file-system, or asynchronous side
 effects. Failures mean native SwiftUI reader surfaces can diverge from the WebView color payload.
 */
final class ReaderThemeSurfacePaletteTests: XCTestCase {
    /**
     Protects the reader-shell color contract for issue #190.

     Setup:
     - Builds a fully populated `TextDisplaySettings` value with distinct day and night theme
       colors so accidental fallback to app defaults is visible.

     Expected result:
     - The palette exposes the same background and foreground ARGB values that the WebView reader
       receives for the selected day/night mode.

     Failure meaning:
     - Native reader chrome can drift away from the Vue reader surface, recreating mismatched
       header/tab/pane colors in split-window layouts.
     */
    func testPaletteUsesResolvedDayAndNightThemeColors() throws {
        var settings = TextDisplaySettings.appDefaults
        let dayBackground = Int(Int32(bitPattern: 0xFFFAF4E8))
        let dayTextColor = Int(Int32(bitPattern: 0xFF17130F))
        let nightBackground = Int(Int32(bitPattern: 0xFF20242A))
        let nightTextColor = Int(Int32(bitPattern: 0xFFF4EDE1))
        settings.dayBackground = dayBackground
        settings.dayTextColor = dayTextColor
        settings.nightBackground = nightBackground
        settings.nightTextColor = nightTextColor

        let dayPalette = ReaderThemeSurfacePalette(settings: settings, nightMode: false)
        XCTAssertEqual(dayPalette.backgroundColorInt, dayBackground)
        XCTAssertEqual(dayPalette.foregroundColorInt, dayTextColor)

        let nightPalette = ReaderThemeSurfacePalette(settings: settings, nightMode: true)
        XCTAssertEqual(nightPalette.backgroundColorInt, nightBackground)
        XCTAssertEqual(nightPalette.foregroundColorInt, nightTextColor)
    }

    /**
     Protects Android's independent app, workspace, and window color ownership.

     Setup:
     - Builds day, night, and monochrome palettes with a conspicuous custom workspace color and
       custom reader content colors.

     Expected result:
     - Controls use AppCompat's DayNight accent.
     - The custom workspace color remains limited to toolbar/navigation chrome.
     - Monochrome toolbar behavior does not replace the global application accent.

     Failure meaning:
     - A workspace or window color has leaked into shared application controls, causing menus,
       switches, and settings across unrelated activities to change color with the reader pane.
     */
    func testControlAccentUsesGlobalDayNightThemeInsteadOfWorkspaceOrWindowColors() {
        var settings = TextDisplaySettings.appDefaults
        settings.dayBackground = Int(Int32(bitPattern: 0xFFFAF4E8))
        settings.dayTextColor = Int(Int32(bitPattern: 0xFF17130F))
        let workspaceColor = Int(Int32(bitPattern: 0xFFFF00FF))

        let dayPalette = ReaderThemeSurfacePalette(
            settings: settings,
            nightMode: false,
            workspaceColor: workspaceColor
        )
        let nightPalette = ReaderThemeSurfacePalette(
            settings: settings,
            nightMode: true,
            workspaceColor: workspaceColor
        )
        let monochromePalette = ReaderThemeSurfacePalette(
            settings: settings,
            nightMode: false,
            workspaceColor: workspaceColor,
            monochromeMode: true
        )

        XCTAssertEqual(
            dayPalette.controlAccentColor,
            AndroidDialogSurfacePalette.accent(for: .light)
        )
        XCTAssertEqual(
            nightPalette.controlAccentColor,
            AndroidDialogSurfacePalette.accent(for: .dark)
        )
        XCTAssertEqual(
            monochromePalette.controlAccentColor,
            AndroidDialogSurfacePalette.accent(for: .light)
        )
        XCTAssertEqual(dayPalette.toolbarBackgroundColorInt, workspaceColor)
        XCTAssertEqual(nightPalette.navigationDrawerColorInt, workspaceColor)
        XCTAssertEqual(monochromePalette.toolbarBackgroundColorInt, -1)
    }

}
