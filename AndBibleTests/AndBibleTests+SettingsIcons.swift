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
    }
}
