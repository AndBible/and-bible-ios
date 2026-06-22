import XCTest
import SwiftUI
@testable import BibleCore
@testable import BibleUI

extension AndBibleTests {
    func testApplicationPreferenceIconsComeFromAndroidSettingsXml() {
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "navigate_to_verse_pref")?.androidDrawableName,
            "ic_chapter_verse_numbers_24dp"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "open_links_in_special_window_pref")?.androidDrawableName,
            "ic_link_window_24dp"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "sync_settings_shortcut")?.androidDrawableName,
            "ic_syncdb_24dp"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "reading_progress_settings_shortcut")?.androidDrawableName,
            "ic_baseline_check_circle_24"
        )
    }

    func testApplicationPreferenceIconAssetNamesAreStableAndNamespaced() {
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "navigate_to_verse_pref")?.assetName,
            "SettingsIconChapterVerseNumbers"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "sync_settings_shortcut")?.assetName,
            "SettingsIconSync"
        )
    }

    func testApplicationPreferenceLookAndFeelRowsExposeGlobalTextOptionsShortcut() {
        XCTAssertEqual(
            ApplicationSettingsPresentation.lookAndFeelRows.first?.androidKey,
            "global_text_display_settings"
        )
        XCTAssertEqual(
            ApplicationSettingsPresentation.lookAndFeelRows.first?.icon?.androidDrawableName,
            "ic_text_format_white_24dp"
        )
    }

    func testSyncSettingsIconsComeFromAndroidSyncSettingsXml() {
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "sync_bookmarks")?.androidDrawableName,
            "ic_bookmark_24dp"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "sync_ai")?.androidDrawableName,
            "icon_robot"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "sync_reading_progress")?.androidDrawableName,
            "ic_baseline_check_circle_24"
        )
    }

    func testSyncSettingsPresentationUsesAndroidBackedRows() {
        XCTAssertEqual(
            SyncSettingsPresentation.backend.androidKey,
            "sync_adapter"
        )
        XCTAssertEqual(
            SyncSettingsPresentation.backend.icon?.androidDrawableName,
            "ic_syncdb_24dp"
        )
        XCTAssertEqual(
            SyncSettingsPresentation.nextCloudCredential.icon?.androidDrawableName,
            "outline_shield_24"
        )
        XCTAssertEqual(
            SyncSettingsPresentation.resetOrSignOut.icon?.androidDrawableName,
            "baseline_logout_24"
        )
    }

    func testSyncSettingsVisibleCategoryRowsMatchAndroidRuntimeVisibility() {
        XCTAssertEqual(
            SyncSettingsPresentation.visibleCategoryRows,
            [
                .active(.bookmarks),
                .active(.workspaces),
                .active(.myDocuments),
                .deferred(.aiSettings),
                .deferred(.progress),
            ]
        )
    }

    func testSyncCategoryPresentationMatchesAndroidCategoryIcons() {
        XCTAssertEqual(
            SyncSettingsPresentation.category(.bookmarks).androidKey,
            "sync_bookmarks"
        )
        XCTAssertEqual(
            SyncSettingsPresentation.category(.bookmarks).icon?.androidDrawableName,
            "ic_bookmark_24dp"
        )
        XCTAssertEqual(
            SyncSettingsPresentation.category(.workspaces).icon?.androidDrawableName,
            "ic_baseline_workspace_24"
        )
        XCTAssertEqual(
            SyncSettingsPresentation.category(.readingPlans).icon?.androidDrawableName,
            "ic_reading_plan_24dp"
        )
        XCTAssertEqual(
            SyncSettingsPresentation.category(.myDocuments).icon?.androidDrawableName,
            "ic_baseline_description_gray_24"
        )
        XCTAssertEqual(
            SyncSettingsPresentation.deferredCategory(.aiSettings).androidKey,
            "sync_ai"
        )
        XCTAssertEqual(
            SyncSettingsPresentation.deferredCategory(.aiSettings).icon?.androidDrawableName,
            "icon_robot"
        )
        XCTAssertEqual(
            SyncSettingsPresentation.deferredCategory(.progress).androidKey,
            "sync_reading_progress"
        )
        XCTAssertEqual(
            SyncSettingsPresentation.deferredCategory(.progress).icon?.androidDrawableName,
            "ic_baseline_check_circle_24"
        )
    }

    /**
     Verifies progress sync copy uses Android's distinct title and summary string resources.

     Setup:
     - reads the shared native iOS sync category localization descriptor that backs both the
       settings row and lifecycle sync error copy
     - compares Progress against Android's `progress_sync_title` and `progress_sync_contents`
       strings from `app/src/main/res/values/strings.xml`

     Expected result:
     - the title remains "Reading Progress"
     - the content description uses "Memorized verses and chapter reading records"
     - active and deferred Progress rows share the same Android string contract

     Failure meaning:
     - iOS duplicated category string switches have drifted from Android and may show a row title
       where Android expects explanatory summary copy.
     */
    func testSyncSettingsProgressTextUsesAndroidTitleAndContentsKeys() {
        let active = RemoteSyncCategoryLocalization.text(for: .progress)
        let deferred = RemoteSyncCategoryLocalization.deferredText(for: .progress)

        XCTAssertEqual(active.title.key, "progress_sync_title")
        XCTAssertEqual(active.title.defaultValue, "Reading Progress")
        XCTAssertEqual(active.contents.key, "progress_sync_contents")
        XCTAssertEqual(active.contents.defaultValue, "Memorized verses and chapter reading records")
        XCTAssertEqual(active, deferred)
        XCTAssertNotEqual(active.title.key, active.contents.key)
    }

    func testDeferredSyncCategoriesReserveAndroidCompatibleKeysAndTrackingIssues() {
        XCTAssertEqual(RemoteSyncDeferredCategory.aiSettings.androidSyncEnabledKey, "sync_enable_ai_settings")
        XCTAssertEqual(RemoteSyncDeferredCategory.aiSettings.trackingIssueNumber, 74)
        XCTAssertEqual(RemoteSyncDeferredCategory.progress.androidSyncEnabledKey, "sync_enable_progress")
        XCTAssertEqual(RemoteSyncDeferredCategory.progress.trackingIssueNumber, 73)
    }

    func testTextDisplayIconsComeFromAndroidOptionsMenuItems() {
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "REDLETTERS")?.androidDrawableName,
            "ic_red_letter_24dp"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "VERSEPERLINE")?.androidDrawableName,
            "ic_one_verse_per_line_24dp"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "JUSTIFY")?.assetName,
            "SettingsIconJustifyText"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "MARGINSIZE")?.androidDrawableName,
            "ic_margin_size_24dp"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "TOPMARGIN")?.androidDrawableName,
            "ic_margin_top_24dp"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "BOOKMARKS_HIDELABELS")?.androidDrawableName,
            "ic_labels_hide_24dp"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "ORDINALS")?.androidDrawableName,
            "ic_baseline_star_24"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "open_workspace_settings")?.androidDrawableName,
            "ic_workspace_overlay_24dp"
        )
        XCTAssertEqual(
            AndBibleIconCatalog.settingsIcon(forAndroidKey: "open_global_settings")?.androidDrawableName,
            "ic_settings_black_24dp"
        )
    }

    func testTextDisplayPresentationMatchesAndroidRenderedOrder() {
        XCTAssertEqual(
            TextDisplaySettingsPresentation.androidRows.map(\.androidKey),
            [
                "STRONGS",
                "MORPH",
                "NON_STRONGS_WORD_ITALIC",
                "FOOTNOTES",
                "FOOTNOTES_INLINE",
                "XREFS",
                "EXPAND_XREFS",
                "SECTIONTITLES",
                "TITLE_SCROLL_BUTTON",
                "VERSENUMBERS",
                "COLORS",
                "FONTSIZE",
                "FONTFAMILY",
                "MARGINSIZE",
                "TOPMARGIN",
                "LINE_SPACING",
                "REDLETTERS",
                "VERSEPERLINE",
                "JUSTIFY",
                "HYPHENATION",
                "PAGENUMBER",
                "BOOKMARKS_SHOW",
                "MYNOTES",
                "BOOKMARKS_HIDELABELS",
                "INFINITE_SCROLL",
                "PAGE_SCROLL_AMOUNT",
                "SCROLL_HELPER_LINES",
                "SCROLL_HELPER_LINE_STYLE",
                "PAGE_BUTTONS",
                "ORDINALS",
                "AI_DOC_MARKERS",
                "MARK_AS_READ_BUTTON",
                "MEMORIZATION_INDICATORS",
                "AUTO_TRACK_READING",
            ]
        )
    }

    func testTextDisplaySectionTitlesMatchAndroidRenderedMenu() {
        XCTAssertEqual(
            TextDisplaySettingsPresentation.Section.allCases.map(\.titleDefault),
            [
                "Formatting",
                "Appearance",
                "Bookmark & My Notes settings",
                "Page Scrolling",
                "Reading & Memorization",
            ]
        )
    }

    func testTextDisplayRowTitlesMatchAndroidXml() {
        let titlesByKey = Dictionary(
            uniqueKeysWithValues: TextDisplaySettingsPresentation.androidRows.map {
                ($0.androidKey, $0.titleDefault)
            }
        )

        XCTAssertEqual(
            titlesByKey,
            [
                "COLORS": "Color settings",
                "FONTSIZE": "Font size",
                "FONTFAMILY": "Font family",
                "LINE_SPACING": "Line spacing",
                "REDLETTERS": "Red Letter",
                "MARGINSIZE": "Change margin size",
                "TOPMARGIN": "Top margin",
                "JUSTIFY": "Justify-align text",
                "HYPHENATION": "Hyphenation",
                "VERSEPERLINE": "One verse per line",
                "STRONGS": "Strong's numbers",
                "MORPH": "Morphological codes",
                "NON_STRONGS_WORD_ITALIC": "Italicize added words",
                "FOOTNOTES": "Footnotes",
                "FOOTNOTES_INLINE": "Footnotes inline",
                "XREFS": "Cross references",
                "EXPAND_XREFS": "Inline cross references",
                "VERSENUMBERS": "Chapter & verse numbers",
                "SECTIONTITLES": "Section titles",
                "TITLE_SCROLL_BUTTON": "Title scroll button",
                "PAGENUMBER": "Relative page number",
                "INFINITE_SCROLL": "Infinite scroll",
                "PAGE_SCROLL_AMOUNT": "Page scroll amount",
                "SCROLL_HELPER_LINES": "Scroll helper lines",
                "SCROLL_HELPER_LINE_STYLE": "Helper line style",
                "PAGE_BUTTONS": "Page scroll buttons",
                "ORDINALS": "Show ordinal numbers",
                "BOOKMARKS_SHOW": "Show bookmarks",
                "MYNOTES": "Show My Note icons",
                "AI_DOC_MARKERS": "Show AI document markers",
                "BOOKMARKS_HIDELABELS": "Hide specified labels",
                "MARK_AS_READ_BUTTON": "Mark as read button",
                "MEMORIZATION_INDICATORS": "Memorization indicators",
                "AUTO_TRACK_READING": "Auto-track reading",
            ]
        )
    }

    /**
     Protects Android text-display scope parity.

     Android renders parent-scope links above the shared text-display rows: window settings can
     jump to workspace and global settings, workspace settings can jump to global settings, and
     global settings hide the parent-links category. A failure here means iOS has drifted from
     Android's visible scope ladder in `TextDisplaySettings.kt`.
     */
    func testTextDisplayVisibleRowsMatchAndroidScopeVisibility() {
        let editableRows = [
            "STRONGS",
            "MORPH",
            "NON_STRONGS_WORD_ITALIC",
            "FOOTNOTES",
            "FOOTNOTES_INLINE",
            "XREFS",
            "EXPAND_XREFS",
            "SECTIONTITLES",
            "TITLE_SCROLL_BUTTON",
            "VERSENUMBERS",
            "COLORS",
            "FONTSIZE",
            "FONTFAMILY",
            "MARGINSIZE",
            "TOPMARGIN",
            "LINE_SPACING",
            "REDLETTERS",
            "VERSEPERLINE",
            "JUSTIFY",
            "HYPHENATION",
            "PAGENUMBER",
            "INFINITE_SCROLL",
            "PAGE_SCROLL_AMOUNT",
            "ORDINALS",
            "BOOKMARKS_SHOW",
            "MYNOTES",
            "AI_DOC_MARKERS",
            "BOOKMARKS_HIDELABELS",
            "MARK_AS_READ_BUTTON",
            "MEMORIZATION_INDICATORS",
        ]

        XCTAssertEqual(
            TextDisplaySettingsPresentation.iosWindowVisibleAndroidKeys,
            ["open_workspace_settings", "open_global_settings"] + editableRows
        )
        XCTAssertEqual(
            TextDisplaySettingsPresentation.iosWorkspaceVisibleAndroidKeys,
            ["open_global_settings"] + editableRows
        )
        XCTAssertEqual(TextDisplaySettingsPresentation.iosGlobalVisibleAndroidKeys, editableRows)
    }

    func testTextDisplayImplementedRowsExposeSupportedIosConfigKeys() {
        XCTAssertTrue(TextDisplaySettingsPresentation.implementedAndroidKeys.contains("COLORS"))
        XCTAssertTrue(TextDisplaySettingsPresentation.implementedAndroidKeys.contains("MARGINSIZE"))
        XCTAssertTrue(TextDisplaySettingsPresentation.implementedAndroidKeys.contains("TOPMARGIN"))
        XCTAssertTrue(TextDisplaySettingsPresentation.implementedAndroidKeys.contains("PAGENUMBER"))
        XCTAssertTrue(TextDisplaySettingsPresentation.implementedAndroidKeys.contains("BOOKMARKS_HIDELABELS"))
        XCTAssertTrue(TextDisplaySettingsPresentation.implementedAndroidKeys.contains("NON_STRONGS_WORD_ITALIC"))
        XCTAssertTrue(TextDisplaySettingsPresentation.implementedAndroidKeys.contains("TITLE_SCROLL_BUTTON"))
        XCTAssertTrue(TextDisplaySettingsPresentation.implementedAndroidKeys.contains("INFINITE_SCROLL"))
        XCTAssertTrue(TextDisplaySettingsPresentation.implementedAndroidKeys.contains("PAGE_SCROLL_AMOUNT"))
        XCTAssertTrue(TextDisplaySettingsPresentation.implementedAndroidKeys.contains("ORDINALS"))
        XCTAssertTrue(TextDisplaySettingsPresentation.implementedAndroidKeys.contains("AI_DOC_MARKERS"))
        XCTAssertTrue(TextDisplaySettingsPresentation.implementedAndroidKeys.contains("MARK_AS_READ_BUTTON"))
        XCTAssertTrue(TextDisplaySettingsPresentation.implementedAndroidKeys.contains("MEMORIZATION_INDICATORS"))
    }

    /**
     Verifies the iOS color editor exposes Android's durable color rows by scope.

     Android's root global color activity inflates the `workspace_color` row, but the commit path
     writes workspace color only from a `SettingsLevel.WORKSPACE` bundle into workspace metadata.
     iOS must therefore avoid giving true global settings an active-workspace side effect while
     still exposing the row from workspace-scoped text options and hiding it for windows.

     Failure meaning:
     - true global settings can mutate workspace metadata
     - workspace settings can no longer edit Android's action-bar color
     - window settings expose a workspace-owned row
     */
    func testColorSettingsVisibleAndroidKeysMatchAndroidDurableScopeRules() {
        let expectedWorkspaceKeys = [
            "workspace_color",
            "text_color_day",
            "background_color_day",
            "noise_day",
            "text_color_night",
            "background_color_night",
            "noise_night",
        ]
        XCTAssertEqual(
            ColorSettingsView.visibleAndroidKeys(scope: .global),
            [
                "text_color_day",
                "background_color_day",
                "noise_day",
                "text_color_night",
                "background_color_night",
                "noise_night",
            ]
        )
        XCTAssertEqual(
            ColorSettingsView.visibleAndroidKeys(scope: .workspace),
            expectedWorkspaceKeys
        )
        XCTAssertEqual(
            ColorSettingsView.visibleAndroidKeys(scope: .window),
            [
                "text_color_day",
                "background_color_day",
                "noise_day",
                "text_color_night",
                "background_color_night",
                "noise_night",
            ]
        )
    }

    /**
     Verifies color reset only resets workspace metadata when the caller owns a workspace binding.

     Android resets `WorkspaceSettings.workspaceColor` from workspace-level Text Options, but root
     global and window routes must not overwrite workspace metadata. This test exercises the shared
     reset helper with and without a workspace binding so reset behavior follows the same ownership
     contract as row visibility.
     */
    func testColorSettingsResetOnlyMutatesWorkspaceColorForWorkspaceOwnedScope() {
        var settings = TextDisplaySettings.appDefaults
        settings.dayTextColor = Int(Int32(bitPattern: 0xFF123456))
        settings.dayBackground = Int(Int32(bitPattern: 0xFF654321))
        settings.dayNoise = 42
        settings.nightTextColor = Int(Int32(bitPattern: 0xFFABCDEF))
        settings.nightBackground = Int(Int32(bitPattern: 0xFF0F0F0F))
        settings.nightNoise = 73
        var workspaceColor: Int? = Int(Int32(bitPattern: 0xFF336699))

        let settingsBinding = Binding<TextDisplaySettings>(
            get: { settings },
            set: { settings = $0 }
        )
        let workspaceColorBinding = Binding<Int?>(
            get: { workspaceColor },
            set: { workspaceColor = $0 }
        )

        ColorSettingsView.resetThemeColorsToDefaults(
            settings: settingsBinding,
            workspaceColor: workspaceColorBinding
        )
        XCTAssertEqual(settings.dayTextColor, -16777216)
        XCTAssertEqual(settings.dayBackground, -1)
        XCTAssertEqual(settings.dayNoise, 0)
        XCTAssertEqual(settings.nightTextColor, -1)
        XCTAssertEqual(settings.nightBackground, -16777216)
        XCTAssertEqual(settings.nightNoise, 0)
        XCTAssertEqual(workspaceColor, Workspace.defaultWorkspaceColor)

        workspaceColor = Int(Int32(bitPattern: 0xFF223344))
        ColorSettingsView.resetThemeColorsToDefaults(
            settings: settingsBinding,
            workspaceColor: nil
        )
        XCTAssertEqual(workspaceColor, Int(Int32(bitPattern: 0xFF223344)))
    }

    /**
     Protects Android's workspace-color application contract for reader chrome.

     Android stores `workspace_color` with workspace metadata and applies it to action-bar chrome
     in day mode. It does not replace the reader content background. Night mode uses black toolbar
     chrome while tinting the drawer/home affordance with the workspace color, and monochrome mode
     forces black-on-white day chrome.

     Failure meaning:
     - iOS can persist workspace color without changing the visible toolbar, or it can drift into
       applying workspace color to reader content instead of Android's action-bar surface.
     */
    func testReaderToolbarChromeUsesAndroidWorkspaceColorContract() {
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

    /**
     Protects the reader chrome state boundary for Android workspace color.

     Android persists workspace color as `WorkspaceSettings.workspaceColor`, outside the
     `TextDisplaySettings` value that drives page content colors. The SwiftUI reader therefore
     needs a separate chrome-color state value instead of relying on text-display state changes to
     invalidate the toolbar after a workspace-color edit.

     Failure meaning:
     - workspace color edits can persist without repainting the native toolbar
     - active-window workspace color can be ignored in favor of an unrelated fallback workspace
     - legacy nil values no longer use Android's `#ff444444` default
     */
    func testReaderWorkspaceChromeColorResolvesFromWorkspaceMetadata() {
        let activeWorkspace = Workspace(name: "Active")
        activeWorkspace.workspaceColor = Int(Int32(bitPattern: 0xFF224466))

        let windowWorkspace = Workspace(name: "Window")
        windowWorkspace.workspaceColor = Int(Int32(bitPattern: 0xFF336699))
        let activeWindow = Window()
        activeWindow.workspace = windowWorkspace

        XCTAssertEqual(
            ReaderWorkspaceChromeColor.resolved(
                activeWindow: activeWindow,
                activeWorkspace: activeWorkspace
            ),
            windowWorkspace.workspaceColor
        )
        XCTAssertEqual(
            ReaderWorkspaceChromeColor.resolved(
                activeWindow: nil,
                activeWorkspace: activeWorkspace
            ),
            activeWorkspace.workspaceColor
        )

        activeWorkspace.workspaceColor = nil
        XCTAssertEqual(
            ReaderWorkspaceChromeColor.resolved(
                activeWindow: nil,
                activeWorkspace: activeWorkspace
            ),
            Workspace.defaultWorkspaceColor
        )
    }

    /**
     Verifies iOS normalizes background-noise edits to Android's seekbar range.

     Android `noise_day` and `noise_night` use a `SeekBarPreference` with max 100 and default 0.
     This protects iOS from persisting out-of-range slider values into the shared
     `TextDisplaySettings` sync/reader contract, including non-finite edits that fall back to a
     previously restored out-of-range value.
     */
    func testColorSettingsNoiseValuesNormalizeToAndroidSeekbarRange() {
        XCTAssertEqual(ColorSettingsView.normalizedNoiseValue(-4.6, fallback: 12), 0)
        XCTAssertEqual(ColorSettingsView.normalizedNoiseValue(44.5, fallback: 12), 45)
        XCTAssertEqual(ColorSettingsView.normalizedNoiseValue(120.2, fallback: 12), 100)
        XCTAssertEqual(ColorSettingsView.normalizedNoiseValue(Double.nan, fallback: 12), 12)
        XCTAssertEqual(ColorSettingsView.normalizedNoiseValue(Double.nan, fallback: -7), 0)
        XCTAssertEqual(ColorSettingsView.normalizedNoiseValue(Double.nan, fallback: 120), 100)
    }

    func testTextDisplaySliderIntegerRoundsSteppedFloatingPointValues() {
        XCTAssertEqual(TextDisplaySettingsView.sliderInteger(639.999999999, fallback: 600), 640)
        XCTAssertEqual(TextDisplaySettingsView.sliderInteger(640.000000001, fallback: 600), 640)
        XCTAssertEqual(TextDisplaySettingsView.sliderInteger(.nan, fallback: 600), 600)
    }

    /**
     Verifies page-scroll amount normalization matches Android's `PageScrollAmountPreference`.

     Android accepts only the values from `pageScrollAmountValues` and falls back to the final
     `100%` option when storage contains an unknown value. A failure here means migrated or synced
     iOS settings could surface untagged picker selections or feed invalid percentages into the
     WebView paging contract.
     */
    func testTextDisplayPageScrollAmountNormalizesToAndroidValues() {
        XCTAssertEqual(TextDisplaySettings.pageScrollAmountValues, [25, 33, 50, 66, 75, 100])
        XCTAssertEqual(TextDisplaySettings.normalizedPageScrollAmount(nil), 100)
        XCTAssertEqual(TextDisplaySettings.normalizedPageScrollAmount(25), 25)
        XCTAssertEqual(TextDisplaySettings.normalizedPageScrollAmount(66), 66)
        XCTAssertEqual(TextDisplaySettings.normalizedPageScrollAmount(100), 100)
        XCTAssertEqual(TextDisplaySettings.normalizedPageScrollAmount(0), 100)
        XCTAssertEqual(TextDisplaySettings.normalizedPageScrollAmount(150), 100)

        var windowSettings = TextDisplaySettings()
        windowSettings.pageScrollAmount = 150

        let resolved = TextDisplaySettings.fullyResolved(window: windowSettings, workspace: nil)
        XCTAssertEqual(resolved.pageScrollAmount, 100)
    }

    /**
     Verifies issue #174 moved Android reader-renderer rows out of the deferred bucket.

     The visible settings rows are only useful when Swift settings, the bridge payload, and
     bibleview-js renderer consumers all exist. A failure here means iOS is either showing stale
     deferred metadata or has accidentally reclassified implemented Android fields as future work.
     */
    func testTextDisplayDeferredRowsExcludeIssue174ImplementedRendererFields() {
        let deferredRows = TextDisplaySettingsPresentation.androidRows
            .filter { $0.disposition == .deferred }

        XCTAssertEqual(deferredRows.map(\.androidKey), [])
    }

    func testTextDisplayEinkRowsAreDocumentedPlatformDivergences() {
        XCTAssertEqual(
            TextDisplaySettingsPresentation.androidRows
                .filter { $0.disposition == .platformDivergence }
                .map(\.androidKey),
            [
                "SCROLL_HELPER_LINES",
                "SCROLL_HELPER_LINE_STYLE",
                "PAGE_BUTTONS",
            ]
        )
    }
}
