#!/usr/bin/env python3
"""
Structural guards retained for Sync Settings routing, test seams, and reachability.

Executable native and app tests own credential editing and validation behavior.
"""

from __future__ import annotations

from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class SyncSettingsUITestContractTests(unittest.TestCase):
    """Reads source for the remaining structural policies; does not prove UI behavior."""

    def test_app_level_route_uses_the_shared_android_activity_back_action(self) -> None:
        """Runtime-safe Sync Settings ownership must not restore native iOS navigation chrome."""
        app_source = (REPO_ROOT / "AndBible" / "AndBibleApp.swift").read_text()
        helper_source = (
            REPO_ROOT / "Tests" / "UI" / "AndBibleUITests" / "AndBibleUITestListSupport.swift"
        ).read_text()
        route_start = app_source.index("private var syncSettingsRouteContent")
        route_end = app_source.index("/**", route_start)
        route_body = app_source[route_start:route_end]
        helper_start = helper_source.index("func dismissSyncSettings(")
        helper_end = helper_source.index("/**", helper_start)
        helper_body = helper_source[helper_start:helper_end]

        self.assertIn("SyncSettingsView(onBack: dismissSyncSettingsRoute)", route_body)
        self.assertNotIn("NavigationStack", route_body)
        self.assertNotIn(".toolbar", route_body)
        self.assertNotIn("syncSettingsDoneButton", route_body)
        self.assertIn('"syncSettingsTopAppBarBackButton"', helper_body)
        self.assertNotIn("dismissSheetByDraggingDown", helper_body)

    def test_icloud_ui_test_declares_and_bounds_the_unavailable_cloudkit_edge(self) -> None:
        """The simulator test seam must be explicit, DEBUG-only, and omit fake CloudKit monitoring."""
        app_source = (REPO_ROOT / "AndBible" / "AndBibleApp.swift").read_text()
        test_source = (
            REPO_ROOT / "Tests" / "UI" / "AndBibleUITests" / "AndBibleUITests+SettingsAndSync.swift"
        ).read_text()
        test_start = test_source.index("func testSyncSettingsICloudToggleDoesNotRequireRestart()")
        test_end = test_source.index("/**", test_start)
        test_body = test_source[test_start:test_end]
        runtime_start = app_source.index("private func makeICloudRuntimeModeChange(")
        runtime_end = app_source.index("/**", runtime_start)
        runtime_body = app_source[runtime_start:runtime_end]

        self.assertIn('app.launchEnvironment["UITEST_LOCAL_ICLOUD_RUNTIME_CONTAINER"] = "1"', test_body)
        self.assertIn("#if DEBUG", app_source)
        self.assertIn('environment["UITEST_SESSION_ID"]', app_source)
        self.assertIn("usesUITestLocalICloudRuntimeContainer", runtime_body)
        self.assertIn("requestedICloudEnabled: usesLocalUITestContainer ? false : requestedEnabled", runtime_body)
        self.assertIn("cloudKitMonitoringContainer: effectiveICloudEnabled && !usesLocalUITestContainer", runtime_body)
        self.assertIn("modelContainer: change.cloudKitMonitoringContainer", app_source)

    def test_sync_settings_button_resolution_accepts_visible_viewport_row(self) -> None:
        """The Sync resolver must use the real scroll owner and accept a visible viewport row.

        The CI shard failure showed SwiftUI can expose the NextCloud test-connection row as a
        native button while `isHittable` stays false long enough to exhaust the helper timeout.
        The accessibility marker is not a scroll surface, so swiping it cannot reveal lazy rows.
        A failure here means the resolver can regress to either mistake.
        """
        sync_view_source = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Settings"
            / "SyncSettingsView.swift"
        ).read_text()
        source = (
            REPO_ROOT / "Tests" / "UI" / "AndBibleUITests" / "AndBibleUITestStateSupport.swift"
        ).read_text()
        resolver_start = source.index("func requireReachableSyncSettingsButton(")
        resolver_end = source.index("func toggledSwitchValue(", resolver_start)
        resolver_body = source[resolver_start:resolver_end]

        self.assertIn('.accessibilityIdentifier("syncSettingsScrollView")', sync_view_source)
        self.assertIn('"syncSettingsScreen"', resolver_body)
        self.assertIn(
            'let scrollView = app.scrollViews["syncSettingsScrollView"].firstMatch',
            resolver_body,
        )
        self.assertIn("scrollView.waitForExistence", resolver_body)
        self.assertIn("dismissKeyboardIfPresent(in: app)", resolver_body)
        self.assertRegex(
            resolver_body,
            r"waitForElementToBecomeHittable\([^)]+\)\s*\|\|\s*"
            r"isElementVisible\([^,]+,\s*within:\s*scrollView\)",
        )
        self.assertIn("scrollView.swipeUp()", resolver_body)
        self.assertIn("scrollView.swipeDown()", resolver_body)
        self.assertIn("isElementVisible(lastCandidate, within: scrollView)", resolver_body)
        self.assertNotIn("syncScreen.swipe", resolver_body)
        self.assertNotIn("app.swipe", resolver_body)
        self.assertNotIn("become hittable within", resolver_body)
        self.assertIn("revealPasses < minimumRevealPasses", resolver_body)


if __name__ == "__main__":
    unittest.main()
