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
     Protects Android's workspace-color application contract for reader chrome.

     Setup:
     - Builds display settings whose content colors differ from the workspace color so the app-bar
       decision cannot accidentally pass by reusing reader background values.
     - Exercises normal day mode, night mode, nil workspace fallback, and monochrome day mode.

     Expected result:
     - Day toolbar background uses `Workspace.workspaceColor`, while content background remains
       driven by `TextDisplaySettings`.
     - Night toolbar background uses Android's black actionbar color, and only the drawer/home
       affordance uses workspace color.
     - Nil workspace colors fall back to Android's `#ff444444`.
     - Monochrome day mode follows Android by forcing a white toolbar with black icons.

     Failure meaning:
     - Changing workspace color can persist without affecting the visible reader chrome, or iOS can
       drift into applying workspace color to the wrong day/night surface.
     */
    func testToolbarChromeUsesAndroidWorkspaceColorContract() throws {
        var settings = TextDisplaySettings.appDefaults
        let dayBackground = Int(Int32(bitPattern: 0xFFFAF4E8))
        let dayTextColor = Int(Int32(bitPattern: 0xFF17130F))
        let workspaceColor = Int(Int32(bitPattern: 0xFF336699))
        settings.dayBackground = dayBackground
        settings.dayTextColor = dayTextColor

        let dayPalette = ReaderThemeSurfacePalette(
            settings: settings,
            nightMode: false,
            workspaceColor: workspaceColor,
            monochromeMode: false
        )
        XCTAssertEqual(dayPalette.backgroundColorInt, dayBackground)
        XCTAssertEqual(dayPalette.foregroundColorInt, dayTextColor)
        XCTAssertEqual(dayPalette.toolbarBackgroundColorInt, workspaceColor)
        XCTAssertEqual(dayPalette.toolbarForegroundColorInt, -1)
        XCTAssertEqual(dayPalette.navigationDrawerColorInt, -1)

        let nightPalette = ReaderThemeSurfacePalette(
            settings: settings,
            nightMode: true,
            workspaceColor: workspaceColor,
            monochromeMode: false
        )
        XCTAssertEqual(nightPalette.toolbarBackgroundColorInt, -16777216)
        XCTAssertEqual(nightPalette.toolbarForegroundColorInt, -1)
        XCTAssertEqual(nightPalette.navigationDrawerColorInt, workspaceColor)

        let fallbackPalette = ReaderThemeSurfacePalette(
            settings: settings,
            nightMode: false,
            workspaceColor: nil,
            monochromeMode: false
        )
        XCTAssertEqual(fallbackPalette.toolbarBackgroundColorInt, Workspace.defaultWorkspaceColor)

        let monochromePalette = ReaderThemeSurfacePalette(
            settings: settings,
            nightMode: false,
            workspaceColor: workspaceColor,
            monochromeMode: true
        )
        XCTAssertEqual(monochromePalette.toolbarBackgroundColorInt, -1)
        XCTAssertEqual(monochromePalette.toolbarForegroundColorInt, -16777216)
        XCTAssertEqual(monochromePalette.navigationDrawerColorInt, -16777216)
    }
}
