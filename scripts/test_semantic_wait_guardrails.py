"""Guardrails for shared UI-test semantic state waiting."""

from __future__ import annotations

from pathlib import Path
import re
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]


def swift_function_body(source: str, name: str) -> str:
    """Return the Swift function body for focused source-contract checks."""
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


def swift_function_bodies(source: str, name: str) -> list[str]:
    """Return every Swift function body with a matching overloaded function name."""
    bodies: list[str] = []
    search_start = 0
    while True:
        match = re.search(rf"\bfunc\s+{re.escape(name)}\b", source[search_start:])
        if match is None:
            break
        absolute_match_start = search_start + match.start()
        brace_index = source.find("{", search_start + match.end())
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
                    bodies.append(source[brace_index + 1 : index])
                    search_start = index + 1
                    break
        else:
            raise AssertionError(f"Expected Swift function {name} body to close.")

        if search_start <= absolute_match_start:
            raise AssertionError(f"Parser did not advance after Swift function {name}.")

    if not bodies:
        raise AssertionError(f"Expected Swift function {name} to exist.")
    return bodies


class SemanticWaitGuardrailsTests(unittest.TestCase):
    """Protects pure semantic-state waits from regressing to ad hoc run-loop polling."""

    def test_workspace_create_prompt_waits_on_prompt_root_before_buttons(self) -> None:
        """Avoid hosted XCTest stalls from proving absent prompt buttons before root exists."""
        list_source = (
            REPO_ROOT / "AndBibleUITests/AndBibleUITestListSupport.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(list_source, "openWorkspaceCreatePrompt")

        prompt_root = '"workspaceNamePromptScreen"'
        prompt_field = '"workspaceNamePromptTextField"'
        confirm_button = '"workspaceNamePromptConfirmButton"'
        cancel_button = '"workspaceNamePromptCancelButton"'

        for identifier in [prompt_root, prompt_field, confirm_button, cancel_button]:
            self.assertIn(identifier, body)

        self.assertLess(body.find(prompt_root), body.find(confirm_button))
        self.assertLess(body.find(prompt_field), body.find(confirm_button))
        self.assertLess(body.find(prompt_root), body.find(cancel_button))
        self.assertLess(body.find(prompt_field), body.find(cancel_button))

    def test_workspace_prompt_button_candidates_prefer_prompt_scope_and_titles(self) -> None:
        """Keep workspace prompt button lookup off expensive app-wide identifier queries first."""
        element_source = (
            REPO_ROOT / "AndBibleUITests/AndBibleUITestElementSupport.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(element_source, "workspaceNamePromptButtonCandidates")

        prompt_candidate = 'app.otherElements["workspaceNamePromptScreen"].firstMatch'
        scoped_button_candidates = "modalButtonCandidates("
        title_candidate = "app.buttons[title].firstMatch"
        identifier_candidate = "app.buttons[identifier].firstMatch"

        for snippet in [
            prompt_candidate,
            scoped_button_candidates,
            title_candidate,
            identifier_candidate,
        ]:
            self.assertIn(snippet, body)

        self.assertLess(body.find(prompt_candidate), body.find(identifier_candidate))
        self.assertLess(body.find(scoped_button_candidates), body.find(identifier_candidate))
        self.assertLess(body.find(title_candidate), body.find(identifier_candidate))

    def test_search_state_candidates_use_screen_root_without_hidden_export_fallback(self) -> None:
        """Keep Search readiness polling off the volatile hidden static-text export."""
        element_source = (
            REPO_ROOT / "AndBibleUITests/AndBibleUITestElementSupport.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(element_source, "semanticStateValueCandidates")
        search_case_start = body.find('case "searchStateExport":')
        bookmark_case_start = body.find('case "bookmarkListStateExport":')
        self.assertNotEqual(search_case_start, -1)
        self.assertNotEqual(bookmark_case_start, -1)

        search_case = body[search_case_start:bookmark_case_start]
        root_candidate = 'app.otherElements["searchScreen"].firstMatch'
        hidden_export_candidate = (
            'screenScopedStateCandidates(identifier, within: "searchScreen", in: app)'
        )

        self.assertIn(root_candidate, search_case)
        self.assertNotIn(hidden_export_candidate, search_case)

    def test_search_interaction_ready_does_not_read_state_before_poll_loop(self) -> None:
        """Keep the Search readiness timeout from being consumed by a pre-loop XCTest snapshot."""
        search_source = (
            REPO_ROOT / "AndBibleUITests/AndBibleUITestSearchSupport.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(search_source, "waitForSearchInteractionReady")
        loop_start = body.find("while Date() < deadline")
        self.assertNotEqual(loop_start, -1)

        pre_loop = body[:loop_start]
        self.assertNotIn("resolvedSearchStateValue", pre_loop)
        self.assertNotIn("searchScreen.value", pre_loop)

    def test_resolved_semantic_wait_uses_xctest_waiter_not_run_loop_polling(self) -> None:
        """Ensure the shared pure-observation wait is backed by XCTest wait primitives."""
        state_source = (
            REPO_ROOT / "AndBibleUITests/AndBibleUITestStateSupport.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(state_source, "waitForResolvedSemanticState")

        self.assertIn("XCTNSPredicateExpectation", body)
        self.assertIn("XCTWaiter", body)
        self.assertNotIn("RunLoop.current.run", body)
        self.assertNotRegex(body, re.compile(r"\brepeat\s*\{"))

    def test_resolved_semantic_wait_failure_reports_elapsed_and_final_state(self) -> None:
        """Keep timeout failures actionable without reintroducing custom polling loops."""
        state_source = (
            REPO_ROOT / "AndBibleUITests/AndBibleUITestStateSupport.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(state_source, "waitForResolvedSemanticState")

        self.assertIn("elapsed", body)
        self.assertIn("final observed state", body)
        self.assertIn("last observed state", body)
        self.assertRegex(body, re.compile(r"valueProvider\(\)[\s\S]*success\(finalValue\)"))
        self.assertRegex(
            body,
            re.compile(
                r"let\s+lastObservedBeforeFinalRead\s*=\s*lastObservedValue"
                r"[\s\S]*if\s+let\s+finalValue\s*=\s*valueProvider\(\)"
            ),
        )
        self.assertRegex(
            body,
            re.compile(
                r"let\s+lastObservedState\s*=\s*lastObservedBeforeFinalRead\s*\?\?\s*\"<none>\""
            ),
        )
        self.assertNotIn("lastObservedValue = finalValue", body)

    def test_representative_pure_observation_waits_use_shared_helper(self) -> None:
        """Keep migrated value/state waits on the shared XCTest-backed helper."""
        reader_source = (
            REPO_ROOT / "AndBibleUITests/AndBibleUITestReaderSupport.swift"
        ).read_text(encoding="utf-8")
        list_source = (
            REPO_ROOT / "AndBibleUITests/AndBibleUITestListSupport.swift"
        ).read_text(encoding="utf-8")

        for body in swift_function_bodies(reader_source, "waitForElementValue"):
            self.assertIn("waitForResolvedSemanticState", body)
            self.assertNotIn("RunLoop.current.run", body)

        bookmark_rows_body = swift_function_body(list_source, "waitForBookmarkListRows")
        self.assertIn("waitForResolvedSemanticState", bookmark_rows_body)
        self.assertNotIn("RunLoop.current.run", bookmark_rows_body)


if __name__ == "__main__":
    unittest.main()
