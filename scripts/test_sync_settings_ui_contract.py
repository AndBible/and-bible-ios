#!/usr/bin/env python3
"""
Regression tests for Sync Settings UI-test reachability contracts.
"""

from __future__ import annotations

from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class SyncSettingsUITestContractTests(unittest.TestCase):
    """Guards Sync Settings UI helpers against CI-only SwiftUI Form reachability stalls."""

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

    def test_invalid_server_url_test_uses_android_edit_validation_contract(self) -> None:
        """Invalid URL coverage must not depend on the iOS-only offscreen connection button.

        Android's `SyncSettingsFragment` rejects malformed `cloud_sync_server_url` edits from the
        preference change listener. If the iOS shard test scrolls to the lower manual connection row,
        it is asserting an iOS drift point and can wedge inside XCUI Form geometry queries before it
        reaches the behavior under test.
        """
        source = (
            REPO_ROOT / "Tests" / "UI" / "AndBibleUITests" / "AndBibleUITests+SettingsAndSync.swift"
        ).read_text()
        test_start = source.index(
            "func testSyncSettingsCategoryDisableAndBackendSwitchPersistAcrossDirectReopen()"
        )
        test_end = source.index("/**", test_start)
        test_body = source[test_start:test_end]

        self.assertNotIn("triggerSyncConnectionTest", test_body)
        self.assertNotIn("dismissKeyboardAfterFocusedTextEntry", test_body)
        self.assertIn('"syncNextCloudServerURLRow"', test_body)
        self.assertIn('"syncNextCloudServerURLAction::confirm"', test_body)
        self.assertIn('dialogIdentifier: "syncNextCloudServerURL"', test_body)
        self.assertNotIn('"syncNextCloudServerURLCommitButton"', test_body)
        self.assertIn(
            'waitForElementValue("syncSettingsState", toContain: "remoteStatus=failureInvalidURL"',
            test_body,
        )

    def test_sync_settings_validates_server_url_when_editing_commits(self) -> None:
        """Sync Settings should reject malformed NextCloud server URLs at the edit boundary.

        Android handles this in `serverUrlPref.setOnPreferenceChangeListener`, after the
        `EditTextPreference` dialog closes and before the invalid value is written. iOS must use the
        same shared app-owned preference dialog and error-dialog sequence.
        """
        source = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Settings"
            / "SyncSettingsView.swift"
        ).read_text()
        credential_start = source.index("private var credentialEditorOverlay")
        credential_end = source.index("/** Builds one exact-icon Android credential preference row.", credential_start)
        credential_body = source[credential_start:credential_end]
        commit_start = source.index("private func commitCredential(")
        commit_end = source.index("/// Plain localized status text", commit_start)
        commit_body = source[commit_start:commit_end]
        persist_start = source.index("private func persistRemoteSettings()")
        persist_end = source.index("/**", persist_start)
        persist_body = source[persist_start:persist_end]

        self.assertIn("AndroidEditTextPreferenceDialog(", credential_body)
        self.assertIn("commitCredential(candidate, for: field)", credential_body)
        self.assertIn("activeCredentialEditor = nil", credential_body)
        self.assertNotIn("validator:", credential_body)
        self.assertNotIn("validateNextCloudServerURLAfterEditing", source)
        self.assertIn("isAndroidValidNextCloudServerURL(trimmedCandidate)", commit_body)
        self.assertIn("remoteConnectionStatus = .failure(invalidURLMessage)", commit_body)
        self.assertIn("remoteSyncErrorMessage = invalidURLMessage", commit_body)
        self.assertIn("serverURL = trimmedCandidate", commit_body)
        self.assertIn("return", commit_body)
        self.assertIn("@State private var lastCommittedServerURL", source)
        self.assertIn("lastCommittedServerURL = serverURL", commit_body)
        self.assertIn("lastCommittedServerURL = serverURL", persist_body)
        self.assertIn("isAndroidValidNextCloudServerURL(serverURL)", persist_body)
        self.assertIn("return", persist_body)

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

    def test_sync_connection_trigger_helper_stays_retired(self) -> None:
        """The invalid-URL path must not reintroduce the old connection-test trigger.

        Android validates malformed server URLs at the edit boundary. The retired UI helper tapped
        a lower Form row and carried extra reachability polling for a behavior the invalid-URL test
        no longer needs. A failure here means the shard can regress to the old iOS-only path.
        """
        source = (
            REPO_ROOT / "Tests" / "UI" / "AndBibleUITests" / "AndBibleUITestStateSupport.swift"
        ).read_text()
        settings_source = (
            REPO_ROOT / "Tests" / "UI" / "AndBibleUITests" / "AndBibleUITests+SettingsAndSync.swift"
        ).read_text()

        self.assertNotIn("func triggerSyncConnectionTest(", source)
        self.assertNotIn("triggerSyncConnectionTest(", settings_source)


if __name__ == "__main__":
    unittest.main()
