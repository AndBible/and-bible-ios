"""Guardrails for seeded Search UI fixture contracts."""

from __future__ import annotations

import json
from pathlib import Path
import re
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]
SEEDED_SEARCH_FIXTURES = {"search-indexed", "search-multi-translation"}


class SearchFixtureGuardrailsTests(unittest.TestCase):
    """Protects Search UI tests from silently falling back to runtime index creation."""

    def test_search_fixture_manifest_maps_search_workflows_to_seeded_indexes(self) -> None:
        """Document which normal Search UI tests are expected to start indexed."""
        manifest = json.loads(
            (REPO_ROOT / "scripts/ui_test_fixture_manifest.json").read_text(encoding="utf-8")
        )
        search_entries = {
            test_identifier: scenario
            for test_identifier, scenario in manifest.items()
            if "/testSearch" in test_identifier
        }

        self.assertTrue(search_entries, "Expected manifest entries for Search UI tests.")
        self.assertEqual(
            {
                "AndBibleUITests/AndBibleUITests/testSearchMultiTranslationSelectionUpdatesGroupedTotals":
                    "search-multi-translation"
            },
            {
                test_identifier: scenario
                for test_identifier, scenario in search_entries.items()
                if scenario == "search-multi-translation"
            },
        )
        for test_identifier, scenario in search_entries.items():
            self.assertIn(
                scenario,
                SEEDED_SEARCH_FIXTURES,
                f"{test_identifier} must use a seeded Search fixture or be split into intentional "
                "runtime index-creation coverage.",
            )

    def test_search_open_path_rejects_runtime_index_creation_for_seeded_fixtures(self) -> None:
        """Ensure normal seeded Search tests cannot tap Create and hide fixture regressions."""
        support_source = (
            REPO_ROOT / "AndBibleUITests/AndBibleUITestSearchSupport.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("seededSearchFixtureScenarios", support_source)
        for scenario in SEEDED_SEARCH_FIXTURES:
            self.assertIn(f'"{scenario}"', support_source)
        self.assertIn("allowsRuntimeIndexCreation: !isSeededSearchFixtureScenario", support_source)

    def test_search_readiness_failure_reports_final_state_and_needs_index_history(self) -> None:
        """Keep readiness failures actionable when seeded indexes are missing or stale."""
        support_source = (
            REPO_ROOT / "AndBibleUITests/AndBibleUITestSearchSupport.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("observedNeedsIndex", support_source)
        self.assertIn("last Search state", support_source)
        self.assertIn("state=needsIndex observed", support_source)
        self.assertIn("Create-index prompt observed", support_source)

    def test_search_tests_document_seeded_index_contract_near_workflow_tests(self) -> None:
        """Keep the fixture expectation visible where future Search UI tests are added."""
        search_source = (REPO_ROOT / "AndBibleUITests/AndBibleUITests+Search.swift").read_text(
            encoding="utf-8"
        )

        self.assertRegex(
            search_source,
            re.compile(
                r"search-indexed.*search-multi-translation.*state=needsIndex",
                re.IGNORECASE | re.DOTALL,
            ),
        )


if __name__ == "__main__":
    unittest.main()
