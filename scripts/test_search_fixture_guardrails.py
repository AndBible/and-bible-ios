"""Guardrails for Search UI fixtures that pre-seed the base KJV index."""

from __future__ import annotations

import json
from pathlib import Path
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]
SEEDED_BASE_SEARCH_INDEX_FIXTURES = {
    "search-indexed",
    "search-complete-preview",
    "search-complete-preview-multi",
    # This scenario seeds KJV before installing UITESTLOCKED. The selected encrypted source is
    # intentionally unavailable for index verification; the UI journey owns that behavior proof.
    "locked-picker-downloads",
}

LOCKED_TRANSLATION_SEARCH_WORKFLOW = (
    "AndBibleUITests/AndBibleUITests/"
    "testSearchLockedTranslationSelectionFailsExplicitlyWithoutDroppingIt"
)


class SearchFixtureGuardrailsTests(unittest.TestCase):
    """Protects the declared base-index fixture contract, not product parity."""

    def test_search_fixture_manifest_maps_search_workflows_to_seeded_indexes(self) -> None:
        """Require each declared Search journey to start with its base KJV index seeded."""
        manifest = json.loads(
            (REPO_ROOT / "Tests/UI/Fixtures/ui_test_fixture_manifest.json").read_text(encoding="utf-8")
        )
        search_entries = {
            test_identifier: scenario
            for test_identifier, scenario in manifest.items()
            if "/testSearch" in test_identifier
        }

        self.assertTrue(search_entries, "Expected manifest entries for Search UI tests.")
        self.assertIn(
            "AndBibleUITests/AndBibleUITests/testSearchMenuEntryTypingAndResultNavigation",
            search_entries,
        )
        self.assertEqual(
            "search-indexed",
            search_entries[
                "AndBibleUITests/AndBibleUITests/testSearchMenuEntryTypingAndResultNavigation"
            ],
        )
        self.assertEqual(
            "locked-picker-downloads",
            search_entries[LOCKED_TRANSLATION_SEARCH_WORKFLOW],
        )
        for test_identifier, scenario in search_entries.items():
            self.assertIn(
                scenario,
                SEEDED_BASE_SEARCH_INDEX_FIXTURES,
                f"{test_identifier} must seed its base KJV Search index or be split into "
                "intentional runtime index-creation coverage.",
            )

if __name__ == "__main__":
    unittest.main()
