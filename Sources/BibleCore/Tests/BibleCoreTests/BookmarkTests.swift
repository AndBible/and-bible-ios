// BookmarkTests.swift — Tests for BibleCore bookmark models

import XCTest
@testable import BibleCore

final class BookmarkModelTests: XCTestCase {
    func testBibleBookmarkDefaults() {
        let bookmark = BibleBookmark()
        XCTAssertEqual(bookmark.v11n, "KJVA")
        XCTAssertTrue(bookmark.wholeVerse)
        XCTAssertNil(bookmark.startOffset)
        XCTAssertNil(bookmark.endOffset)
        XCTAssertNil(bookmark.primaryLabelId)
        XCTAssertNil(bookmark.customIcon)
    }

    func testLabelConstants() {
        XCTAssertEqual(Label.speakLabelName, "__SPEAK_LABEL__")
        XCTAssertEqual(Label.unlabeledName, "__UNLABELED__")
        XCTAssertEqual(Label.paragraphBreakLabelName, "__PARAGRAPH_BREAK_LABEL__")
    }

    func testLabelSystemDetection() {
        let userLabel = Label(name: "My Study")
        XCTAssertTrue(userLabel.isRealLabel)
        XCTAssertFalse(userLabel.isSystemLabel)

        let speakLabel = Label(name: Label.speakLabelName)
        XCTAssertFalse(speakLabel.isRealLabel)
        XCTAssertTrue(speakLabel.isSystemLabel)
    }

    func testEditAction() {
        var action = EditAction()
        XCTAssertNil(action.mode)
        XCTAssertNil(action.content)

        action = EditAction(mode: .append, content: "test")
        XCTAssertEqual(action.mode, .append)
        XCTAssertEqual(action.content, "test")
    }

    func testBookmarkStylePresetColors() {
        XCTAssertEqual(BookmarkStylePreset.blueHighlight.color, 0xFF91A7FF)
        XCTAssertEqual(BookmarkStylePreset.redHighlight.color, 0xFFFF9999)
        XCTAssertNotEqual(BookmarkStylePreset.yellowStar.color, BookmarkStylePreset.greenHighlight.color)
    }

    func testTextDisplaySettingsInheritance() {
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

        // Window overrides workspace
        let resolvedSize = TextDisplaySettings.resolved(
            \.fontSize,
            window: windowSettings,
            workspace: workspaceSettings,
            global: globalSettings,
            defaults: defaults
        )
        XCTAssertEqual(resolvedSize, 18)

        // Window nil → falls to workspace
        let resolvedFamily = TextDisplaySettings.resolved(
            \.fontFamily,
            window: windowSettings,
            workspace: workspaceSettings,
            global: globalSettings,
            defaults: defaults
        )
        XCTAssertEqual(resolvedFamily, "serif")

        // Window and workspace nil → falls to global
        let resolvedSpacing = TextDisplaySettings.resolved(
            \.lineSpacing,
            window: windowSettings,
            workspace: workspaceSettings,
            global: globalSettings,
            defaults: defaults
        )
        XCTAssertEqual(resolvedSpacing, 125)

        // Window, workspace, and global nil → falls to defaults
        let resolvedTopMargin = TextDisplaySettings.resolved(
            \.topMargin,
            window: windowSettings,
            workspace: workspaceSettings,
            global: globalSettings,
            defaults: defaults
        )
        XCTAssertNil(resolvedTopMargin)
    }

    func testTextDisplaySettingsFullyResolvedUsesGlobalBeforeDefaults() {
        var globalSettings = TextDisplaySettings()
        globalSettings.dayBackground = 0xFFFAF4E8
        globalSettings.nightTextColor = 0xFFF1E7D0

        var workspaceSettings = TextDisplaySettings()
        workspaceSettings.nightTextColor = 0xFFCCCCCC

        let resolved = TextDisplaySettings.fullyResolved(
            window: nil,
            workspace: workspaceSettings,
            global: globalSettings
        )

        XCTAssertEqual(resolved.dayBackground, 0xFFFAF4E8)
        XCTAssertEqual(resolved.nightTextColor, 0xFFCCCCCC)
        XCTAssertEqual(resolved.dayTextColor, TextDisplaySettings.appDefaults.dayTextColor)
    }
}
