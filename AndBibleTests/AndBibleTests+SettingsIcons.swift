import XCTest
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

    func testTextDisplayVisibleRowsMatchAndroidScopeVisibility() {
        let windowVisibleRows = [
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
        let workspaceVisibleRows = windowVisibleRows
        let globalVisibleRows = windowVisibleRows

        XCTAssertEqual(TextDisplaySettingsPresentation.iosWindowVisibleAndroidKeys, windowVisibleRows)
        XCTAssertEqual(TextDisplaySettingsPresentation.iosWorkspaceVisibleAndroidKeys, workspaceVisibleRows)
        XCTAssertEqual(TextDisplaySettingsPresentation.iosGlobalVisibleAndroidKeys, globalVisibleRows)
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

    func testTextDisplaySliderIntegerRoundsSteppedFloatingPointValues() {
        XCTAssertEqual(TextDisplaySettingsView.sliderInteger(639.999999999, fallback: 600), 640)
        XCTAssertEqual(TextDisplaySettingsView.sliderInteger(640.000000001, fallback: 600), 640)
        XCTAssertEqual(TextDisplaySettingsView.sliderInteger(.nan, fallback: 600), 600)
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
