// TextDisplaySettingsTests.swift -- BibleCore text-display inheritance coverage

import XCTest
@testable import BibleCore

/**
 Package-level tests for Android-compatible text-display settings inheritance.

 These tests exercise pure `BibleCore` value behavior with no SwiftData container, app host,
 filesystem writes, network access, or simulator UI. Failures mean window/workspace/global/default
 reader settings can persist or resolve differently from Android's durable settings model.
 */
final class TextDisplaySettingsTests: XCTestCase {
    /**
     Protects the Android default for Strong's display.

     Android treats raw mode `0` as hidden links, not disabled Strong's data. The package default
     must keep that value so app resets, global inheritance, and bridge payloads all start from the
     Android default. A failure means a default reset can silently change the reader link contract.
     */
    func testAppDefaultsUseAndroidHiddenLinksStrongsMode() {
        XCTAssertEqual(TextDisplaySettings.appDefaults.strongsMode, 0)
    }

    /**
     Protects the window -> workspace -> global -> app-default inheritance order.

     Setup builds one setting at each level and verifies each field resolves from the nearest level
     with a value. There are no side effects or persisted preferences. A failure means reader panes
     can inherit text options from the wrong owner and drift from Android workspace/window behavior.
     */
    func testInheritanceUsesGlobalBeforeDefaults() {
        var windowSettings = TextDisplaySettings()
        windowSettings.fontSize = 18

        var workspaceSettings = TextDisplaySettings()
        workspaceSettings.fontSize = 16
        workspaceSettings.fontFamily = "serif"

        var globalSettings = TextDisplaySettings()
        globalSettings.lineSpacing = 125

        var defaults = TextDisplaySettings()
        defaults.fontSize = 14
        defaults.fontFamily = "sans-serif"
        defaults.lineSpacing = 150

        XCTAssertEqual(
            TextDisplaySettings.resolved(
                \.fontSize,
                window: windowSettings,
                workspace: workspaceSettings,
                global: globalSettings,
                defaults: defaults
            ),
            18
        )
        XCTAssertEqual(
            TextDisplaySettings.resolved(
                \.fontFamily,
                window: windowSettings,
                workspace: workspaceSettings,
                global: globalSettings,
                defaults: defaults
            ),
            "serif"
        )
        XCTAssertEqual(
            TextDisplaySettings.resolved(
                \.lineSpacing,
                window: windowSettings,
                workspace: workspaceSettings,
                global: globalSettings,
                defaults: defaults
            ),
            125
        )
        XCTAssertNil(
            TextDisplaySettings.resolved(
                \.topMargin,
                window: windowSettings,
                workspace: workspaceSettings,
                global: globalSettings,
                defaults: defaults
            )
        )
    }

    /**
     Protects full settings materialization for WebView/native reader configuration.

     The fully resolved value must preserve explicit global color defaults while allowing a nearer
     workspace override to win for a different field. A failure means the reader bridge can receive
     unresolved nils or incorrectly skip workspace-level overrides.
     */
    func testFullyResolvedUsesGlobalBeforeDefaults() {
        let dayBackground = Int(Int32(bitPattern: 0xFFFAF4E8))
        let nightTextColor = Int(Int32(bitPattern: 0xFFF1E7D0))
        let workspaceNightTextColor = Int(Int32(bitPattern: 0xFFCCCCCC))

        var globalSettings = TextDisplaySettings()
        globalSettings.dayBackground = dayBackground
        globalSettings.nightTextColor = nightTextColor

        var workspaceSettings = TextDisplaySettings()
        workspaceSettings.nightTextColor = workspaceNightTextColor

        let resolved = TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: workspaceSettings,
            global: globalSettings
        )

        XCTAssertEqual(resolved.dayBackground, dayBackground)
        XCTAssertEqual(resolved.nightTextColor, workspaceNightTextColor)
        XCTAssertEqual(resolved.dayTextColor, TextDisplaySettings.appDefaults.dayTextColor)
    }

    /**
     Protects selective dirty-override cleanup after parent text-display changes.

     Setup mirrors the global-change propagation path: only fields that changed in the parent and
     now exactly match the child override should clear. A failure means global/workspace updates can
     either leave redundant dirty overrides behind or erase unrelated explicit window choices.
     */
    func testChangedFieldsOnlyClearMatchingDirtyOverrides() {
        var previousGlobal = TextDisplaySettings()
        previousGlobal.fontSize = 18
        previousGlobal.lineSpacing = 10
        previousGlobal.showVerseNumbers = true

        var currentGlobal = previousGlobal
        currentGlobal.fontSize = 20
        currentGlobal.showVerseNumbers = false

        let changedFields = TextDisplaySettings.changedFields(
            from: previousGlobal,
            to: currentGlobal
        )

        var childOverrides = TextDisplaySettings()
        childOverrides.fontSize = 20
        childOverrides.lineSpacing = 10
        childOverrides.showVerseNumbers = false

        XCTAssertTrue(
            childOverrides.clearOverridesMatchingParent(
                currentGlobal,
                only: changedFields
            )
        )
        XCTAssertNil(childOverrides.fontSize)
        XCTAssertNil(childOverrides.showVerseNumbers)
        XCTAssertEqual(childOverrides.lineSpacing, 10)
    }
}
