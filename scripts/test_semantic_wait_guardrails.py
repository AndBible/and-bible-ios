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
