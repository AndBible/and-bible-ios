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

    def test_invalid_server_url_test_uses_android_edit_validation_contract(self) -> None:
        """Invalid URL coverage must not depend on the iOS-only offscreen connection button.

        Android's `SyncSettingsFragment` rejects malformed `cloud_sync_server_url` edits from the
        preference change listener. If the iOS shard test scrolls to the lower manual connection row,
        it is asserting an iOS drift point and can wedge inside XCUI Form geometry queries before it
        reaches the behavior under test.
        """
        source = (
            REPO_ROOT / "AndBibleUITests" / "AndBibleUITests+SettingsAndSync.swift"
        ).read_text()
        test_start = source.index(
            "func testSyncSettingsCategoryDisableAndBackendSwitchPersistAcrossDirectReopen()"
        )
        test_end = source.index("/**", test_start)
        test_body = source[test_start:test_end]

        self.assertNotIn("triggerSyncConnectionTest", test_body)
        self.assertNotIn("dismissKeyboardAfterFocusedTextEntry", test_body)
        self.assertIn('"syncNextCloudServerURLCommitButton"', test_body)
        self.assertIn("tapElementReliably(commitButton", test_body)
        self.assertIn(
            'waitForElementValue("syncSettingsState", toContain: "remoteStatus=failureInvalidURL"',
            test_body,
        )

    def test_sync_settings_validates_server_url_when_editing_commits(self) -> None:
        """Sync Settings should reject malformed NextCloud server URLs at the edit boundary.

        Android handles this in `serverUrlPref.setOnPreferenceChangeListener`, before the invalid
        value is written to preferences. The iOS inline TextField needs an equivalent commit/focus
        validation path so users and tests do not have to reach an unrelated lower Form row.
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
        credential_start = source.index(
            'TextField(String(localized: "auth_server_uri"), text: $serverURL)'
        )
        credential_end = source.index('TextField(String(localized: "auth_username")', credential_start)
        credential_body = source[credential_start:credential_end]
        persist_start = source.index("private func persistRemoteSettings()")
        persist_end = source.index("/**", persist_start)
        persist_body = source[persist_start:persist_end]
        validation_start = source.index("private func validateNextCloudServerURLAfterEditing()")
        validation_end = source.index("/**", validation_start)
        validation_body = source[validation_start:validation_end]

        self.assertIn("validateNextCloudServerURLAfterEditing()", credential_body)
        self.assertIn("focusedNextCloudCredentialField", credential_body)
        self.assertIn("_ = validateNextCloudServerURLAfterEditing()", credential_body)
        self.assertNotIn("if validateNextCloudServerURLAfterEditing()", credential_body)
        self.assertIn('"syncNextCloudServerURLCommitButton"', source)
        self.assertIn("ToolbarItemGroup(placement: .keyboard)", source)
        commit_button_start = source.index('"syncNextCloudServerURLCommitButton"')
        toolbar_commit_body = source[source.rfind("Button(String(localized: \"ok\"))", 0, commit_button_start):commit_button_start]
        self.assertIn("_ = validateNextCloudServerURLAfterEditing()", toolbar_commit_body)
        self.assertIn("focusedNextCloudCredentialField = nil", toolbar_commit_body)
        self.assertNotIn("if validateNextCloudServerURLAfterEditing()", toolbar_commit_body)
        self.assertIn("-> Bool", validation_body)
        self.assertIn("@State private var lastCommittedServerURL", source)
        self.assertIn("lastCommittedServerURL = serverURL", persist_body)
        self.assertIn("isAndroidValidNextCloudServerURL(serverURL)", persist_body)
        self.assertIn("return", persist_body)
        self.assertIn("serverURL = lastCommittedServerURL", validation_body)

    def test_sync_settings_button_resolution_accepts_visible_viewport_row(self) -> None:
        """The Sync Settings resolver must not depend only on XCTest `isHittable`.

        The CI shard failure showed SwiftUI can expose the NextCloud test-connection row as a
        native button while `isHittable` stays false long enough to exhaust the helper timeout.
        A failure here means the resolver can regress to burning the whole timeout before treating
        a visible Form row as reachable.
        """
        source = (
            REPO_ROOT / "AndBibleUITests" / "AndBibleUITestStateSupport.swift"
        ).read_text()
        resolver_start = source.index("func requireReachableSyncSettingsButton(")
        resolver_end = source.index("func toggledSwitchValue(", resolver_start)
        resolver_body = source[resolver_start:resolver_end]

        self.assertIn("let syncScreen = requireElement(", resolver_body)
        self.assertIn('"syncSettingsScreen"', resolver_body)
        self.assertIn("dismissKeyboardIfPresent(in: app)", resolver_body)
        self.assertRegex(
            resolver_body,
            r"waitForElementToBecomeHittable\([^)]+\)\s*\|\|\s*"
            r"isElementVisible\([^,]+,\s*within:\s*syncScreen\)",
        )
        self.assertIn("isElementVisible(lastCandidate, within: syncScreen)", resolver_body)
        self.assertNotIn("become hittable within", resolver_body)
        self.assertIn("revealPasses < minimumRevealPasses", resolver_body)

    def test_sync_connection_trigger_does_not_recheck_hittability_after_resolution(self) -> None:
        """Triggering the connection test uses the resolved row instead of a second hittability wait.

        `requireReachableSyncSettingsButton` owns the scroll/reachability contract. Requiring the
        returned Form row to stay `isHittable` before every tap recreates the shard failure when
        XCTest marks a visible SwiftUI row non-hittable.
        """
        source = (
            REPO_ROOT / "AndBibleUITests" / "AndBibleUITestStateSupport.swift"
        ).read_text()
        trigger_start = source.index("func triggerSyncConnectionTest(")
        trigger_end = source.index("func syncStateToken(", trigger_start)
        trigger_body = source[trigger_start:trigger_end]

        self.assertIn("tapElementReliably(button, timeout: 1", trigger_body)
        self.assertNotIn("waitForElementToBecomeHittable(button, timeout: 5)", trigger_body)
        self.assertNotIn("stay hittable while triggering", trigger_body)


if __name__ == "__main__":
    unittest.main()
