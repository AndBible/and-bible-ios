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
        self.assertIn("isElementVisible(button, within: syncScreen)", resolver_body)
        self.assertIn("isElementVisible(lastCandidate, within: syncScreen)", resolver_body)
        self.assertNotIn("become hittable within", resolver_body)

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
