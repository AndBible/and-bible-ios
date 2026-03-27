#!/usr/bin/env python3
"""Extract per-test UI durations from an xcresult bundle."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any, Sequence


def typed_value(node: Any) -> Any:
    """Unwrap one xcresult typed value node."""
    if isinstance(node, dict) and "_value" in node:
        value = node["_value"]
        type_name = node.get("_type", {}).get("_name")
        if type_name == "Double":
            return float(value)
        if type_name == "Int":
            return int(value)
        if type_name == "Bool":
            return value.lower() == "true"
        return value
    return node


def typed_array(node: Any) -> list[Any]:
    """Unwrap one xcresult typed array node."""
    if isinstance(node, dict) and "_values" in node:
        values = node["_values"]
        if isinstance(values, list):
            return values
    return []


def find_tests_ref_id(invocation_payload: dict[str, Any]) -> str | None:
    """Extract the first `testsRef` identifier from an invocation record payload."""
    for action in typed_array(invocation_payload.get("actions")):
        action_result = action.get("actionResult") if isinstance(action, dict) else None
        tests_ref = action_result.get("testsRef") if isinstance(action_result, dict) else None
        tests_ref_id = typed_value(tests_ref.get("id")) if isinstance(tests_ref, dict) else None
        if isinstance(tests_ref_id, str) and tests_ref_id:
            return tests_ref_id
    return None


def normalize_test_identifier(
    raw_identifier: str,
    *,
    test_target: str,
    test_case_class: str,
) -> str | None:
    """Normalize one xcresult test identifier to `target/class/method` form."""
    normalized = raw_identifier.strip().rstrip("()")
    if normalized.count("/") == 2:
        return normalized
    if normalized.count("/") == 1:
        target, method = normalized.split("/", 1)
        if target == test_target and method.startswith("test"):
            return f"{test_target}/{test_case_class}/{method}"
    return None


def extract_ui_test_timings(
    xcresult_payload: dict[str, Any],
    *,
    test_target: str,
    test_case_class: str,
) -> dict[str, float]:
    """Extract per-test durations from one legacy xcresult JSON payload."""
    timings: dict[str, float] = {}

    def visit(summary: dict[str, Any]) -> None:
        subtests = typed_array(summary.get("subtests"))
        if subtests:
            for subtest in subtests:
                if isinstance(subtest, dict):
                    visit(subtest)
            return

        identifier = typed_value(summary.get("identifier"))
        duration = typed_value(summary.get("duration"))
        if not isinstance(identifier, str) or not isinstance(duration, (int, float)):
            return
        normalized = normalize_test_identifier(
            identifier,
            test_target=test_target,
            test_case_class=test_case_class,
        )
        if normalized is not None:
            timings[normalized] = float(duration)

    for plan_summary in typed_array(xcresult_payload.get("summaries")):
        for testable_summary in typed_array(plan_summary.get("testableSummaries")):
            if typed_value(testable_summary.get("testKind")) != "UI":
                continue
            for top_level_summary in typed_array(testable_summary.get("tests")):
                if isinstance(top_level_summary, dict):
                    visit(top_level_summary)

    return dict(sorted(timings.items()))


def run_xcresulttool_get_object(xcresult_path: Path, *, object_id: str | None = None) -> dict[str, Any]:
    """Load one xcresult object as legacy JSON."""
    command = [
        "xcrun",
        "xcresulttool",
        "get",
        "object",
        "--legacy",
        "--path",
        str(xcresult_path),
        "--format",
        "json",
    ]
    if object_id is not None:
        command.extend(["--id", object_id])
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    payload = json.loads(completed.stdout)
    if not isinstance(payload, dict):
        raise ValueError("xcresult payload root must be a JSON object.")
    return payload


def load_xcresult_payload(xcresult_path: Path) -> dict[str, Any]:
    """Load the xcresult tests payload, following `testsRef` from the invocation record."""
    root_payload = run_xcresulttool_get_object(xcresult_path)
    if "summaries" in root_payload:
        return root_payload

    tests_ref_id = find_tests_ref_id(root_payload)
    if tests_ref_id is None:
        raise ValueError("Unable to locate testsRef in the xcresult invocation record.")
    return run_xcresulttool_get_object(xcresult_path, object_id=tests_ref_id)


def create_argument_parser() -> argparse.ArgumentParser:
    """Create the CLI parser."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcresult-path", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--test-target", default="AndBibleUITests")
    parser.add_argument("--test-case-class", default="AndBibleUITests")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Extract and print per-test UI timings."""
    parser = create_argument_parser()
    args = parser.parse_args(argv)

    payload = load_xcresult_payload(args.xcresult_path)
    timings = extract_ui_test_timings(
        payload,
        test_target=args.test_target,
        test_case_class=args.test_case_class,
    )
    output = json.dumps(timings, indent=2, sort_keys=True)

    if args.output is not None:
        args.output.write_text(output + "\n")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
