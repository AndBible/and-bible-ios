"""Guardrails for seeded Search UI fixture contracts."""

from __future__ import annotations

import json
from pathlib import Path
import re
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]
SEEDED_SEARCH_FIXTURES = {"search-indexed", "search-multi-translation"}


def swift_function_body(source: str, name: str) -> str:
    """Return a Swift function body from a source string for contract checks."""
    match = re.search(rf"\bfunc\s+{re.escape(name)}\b", source)
    if match is None:
        raise AssertionError(f"Expected Swift function {name} to exist.")

    brace_index = source.find("{", match.end())
    if brace_index == -1:
        raise AssertionError(f"Expected Swift function {name} to have a body.")

    depth = 0
    for index in range(brace_index, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace_index + 1 : index]

    raise AssertionError(f"Expected Swift function {name} body to close.")


class SearchFixtureGuardrailsTests(unittest.TestCase):
    """Protects Search UI tests from silently falling back to runtime index creation."""

    def test_search_fixture_manifest_maps_search_workflows_to_seeded_indexes(self) -> None:
        """Document which normal Search UI tests are expected to start indexed."""
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
            "AndBibleUITests/AndBibleUITests/testSearchOptionControlsMutateVisibleState",
            search_entries,
        )
        self.assertEqual(
            "search-multi-translation",
            search_entries["AndBibleUITests/AndBibleUITests/testSearchOptionControlsMutateVisibleState"],
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
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestSearchSupport.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("seededSearchFixtureScenarios", support_source)
        for scenario in SEEDED_SEARCH_FIXTURES:
            self.assertIn(f'"{scenario}"', support_source)
        self.assertIn("let allowsRuntimeIndexCreation = !isSeededSearchFixtureScenario", support_source)
        self.assertIn("allowsRuntimeIndexCreation: allowsRuntimeIndexCreation", support_source)

    def test_search_open_path_preserves_call_site_failure_attribution(self) -> None:
        """Ensure seeded fixture failures point at the invoking Search UI test."""
        support_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestSearchSupport.swift"
        ).read_text(encoding="utf-8")

        self.assertRegex(
            support_source,
            re.compile(
                r"func openSearch\(\s*in app: XCUIApplication,\s*"
                r"file: StaticString = #filePath,\s*line: UInt = #line",
                re.DOTALL,
            ),
        )
        open_search_body = swift_function_body(support_source, "openSearch")
        presentation_body = swift_function_body(support_source, "presentSearchFromReader")

        for expected_pattern in [
            r"resolveFixtureScenario\(\s*environment:\s*ProcessInfo\.processInfo\.environment,"
            r"\s*file:\s*file,\s*line:\s*line\s*\)",
            r"presentSearchFromReader\(\s*in:\s*app\s*,\s*timeout:\s*20,\s*file:\s*file,"
            r"\s*line:\s*line\s*\)",
        ]:
            self.assertRegex(open_search_body, re.compile(expected_pattern, re.DOTALL))

        for expected_pattern in [
            r"tapReaderSearchEntry\(\s*in:\s*app\s*,[\s\S]*?file:\s*file,"
            r"\s*line:\s*line\s*\)",
            r"tapReaderAction\(\s*\"readerOpenSearchAction\",\s*in:\s*app,[\s\S]*?file:\s*file,"
            r"\s*line:\s*line\s*\)",
        ]:
            self.assertRegex(presentation_body, re.compile(expected_pattern, re.DOTALL))

        readiness_calls = re.findall(
            r"waitForSearchInteractionReady\([\s\S]*?"
            r"allowsRuntimeIndexCreation:\s*allowsRuntimeIndexCreation,\s*"
            r"file:\s*file,\s*line:\s*line\s*\)",
            support_source,
        )
        self.assertEqual(2, len(readiness_calls))

    def test_seeded_open_search_readiness_uses_reduced_budget(self) -> None:
        """Ensure normal seeded Search tests no longer inherit index-creation timeouts."""
        support_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestSearchSupport.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("seededSearchReadinessTimeout", support_source)
        self.assertIn("runtimeSearchIndexReadinessTimeout", support_source)
        self.assertRegex(
            support_source,
            re.compile(r"seededSearchReadinessTimeout:\s*TimeInterval\s*=\s*20\b"),
        )
        self.assertRegex(
            support_source,
            re.compile(r"runtimeSearchIndexReadinessTimeout:\s*TimeInterval\s*=\s*120\b"),
        )

        open_search_body = swift_function_body(support_source, "openSearch")
        normalized_open_search_body = re.sub(r"\s+", " ", open_search_body)
        self.assertIn(
            "let allowsRuntimeIndexCreation = !isSeededSearchFixtureScenario",
            normalized_open_search_body,
        )
        self.assertIn(
            "let readinessTimeout = searchReadinessTimeout( "
            "allowsRuntimeIndexCreation: allowsRuntimeIndexCreation "
            ")",
            normalized_open_search_body,
        )
        self.assertNotRegex(open_search_body, re.compile(r"timeout:\s*120\b"))
        readiness_calls = re.findall(
            r"waitForSearchInteractionReady\([\s\S]*?"
            r"timeout:\s*readinessTimeout,[\s\S]*?"
            r"allowsRuntimeIndexCreation:\s*allowsRuntimeIndexCreation,\s*"
            r"file:\s*file,\s*line:\s*line\s*\)",
            open_search_body,
        )
        self.assertEqual(2, len(readiness_calls))

    def test_search_state_waits_use_shared_semantic_wait_helper(self) -> None:
        """Keep Search's pure state waits on one shared diagnostic helper."""
        support_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestSearchSupport.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("func waitForSearchSemanticState", support_source)
        for function_name in [
            "waitForSearchState",
            "waitForSearchResultCount",
            "waitForSearchSelectedModules",
            "waitForSearchResultRow",
        ]:
            body = swift_function_body(support_source, function_name)
            self.assertIn(
                "waitForSearchSemanticState",
                body,
                f"{function_name} must use the shared Search state waiter.",
            )

    def test_search_readiness_failure_reports_final_state_and_needs_index_history(self) -> None:
        """Keep readiness failures actionable when seeded indexes are missing or stale."""
        support_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestSearchSupport.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("observedNeedsIndex", support_source)
        self.assertIn("last Search state", support_source)
        self.assertIn("state=needsIndex observed", support_source)
        self.assertIn("index creation requested", support_source)
        self.assertIn("Create-index prompt observed", support_source)

        needs_index_branch = re.search(
            r"if sawNeedsIndex \{(?P<body>[\s\S]*?tapElementReliably\(createButton,[\s\S]*?continue)"
            r"\s*\n\s*\}",
            support_source,
        )
        self.assertIsNotNone(needs_index_branch)
        branch_body = needs_index_branch.group("body")
        expected_order = [
            "observedNeedsIndex = true",
            "if !allowsRuntimeIndexCreation",
            "let createButton = resolveSearchCreateIndexButton(in: app)",
            "observedCreatePrompt = true",
            "tapElementReliably(createButton",
        ]
        positions = [branch_body.find(token) for token in expected_order]
        self.assertNotIn(-1, positions)
        self.assertEqual(sorted(positions), positions)

    def test_search_tests_document_seeded_index_contract_near_workflow_tests(self) -> None:
        """Keep the fixture expectation visible where future Search UI tests are added."""
        search_source = (REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITests+Search.swift").read_text(
            encoding="utf-8"
        )

        self.assertRegex(
            search_source,
            re.compile(
                r"search-multi-translation.*state=needsIndex",
                re.IGNORECASE | re.DOTALL,
            ),
        )


if __name__ == "__main__":
    unittest.main()
