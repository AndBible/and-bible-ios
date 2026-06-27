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

}
