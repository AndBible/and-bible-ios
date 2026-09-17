#!/usr/bin/env python3
"""Extract complete, provenance-backed UI timings from xcresult bundles."""

from __future__ import annotations

import argparse
import json
import subprocess
from datetime import date
from pathlib import Path
from typing import Any, Mapping, Sequence

from build_ui_test_shards import discover_ui_test_identifiers_from_files
from run_xcodebuild_with_test_selection import (
    PASSING_TEST_RESULTS,
    test_cases_from_xcresult_nodes,
)


def extract_ui_test_timings(
    xcresult_payload: Mapping[str, object],
    *,
    test_target: str,
    test_case_class: str,
) -> dict[str, float]:
    """Extract one successful duration for each matching structured test node."""
    timings: dict[str, float] = {}
    identifier_prefix = f"{test_target}/{test_case_class}/"
    for test_case in test_cases_from_xcresult_nodes(xcresult_payload):
        if not test_case.identifier.startswith(identifier_prefix):
            continue
        if test_case.identifier in timings:
            raise ValueError(
                f"{test_case.identifier} appears more than once; "
                "retry/restart attempts cannot provide one authoritative duration."
            )
        if test_case.result not in PASSING_TEST_RESULTS:
            raise ValueError(
                f"{test_case.identifier} reported {test_case.result}; "
                "only passing executions can update the timing manifest."
            )
        if test_case.duration_seconds is None or test_case.duration_seconds < 0:
            raise ValueError(
                f"{test_case.identifier} has no valid durationInSeconds value."
            )
        timings[test_case.identifier] = test_case.duration_seconds
    return dict(sorted(timings.items()))


def merge_ui_test_timings(
    xcresult_payloads: Sequence[Mapping[str, object]],
    *,
    test_target: str,
    test_case_class: str,
) -> dict[str, float]:
    """Merge disjoint shard reports without hiding duplicate executions."""
    merged: dict[str, float] = {}
    for payload in xcresult_payloads:
        for identifier, duration in extract_ui_test_timings(
            payload,
            test_target=test_target,
            test_case_class=test_case_class,
        ).items():
            if identifier in merged:
                raise ValueError(
                    f"{identifier} appears in more than one xcresult bundle; "
                    "the shard set is not disjoint."
                )
            merged[identifier] = duration
    return dict(sorted(merged.items()))


def reconcile_discovered_timings(
    timings: Mapping[str, float],
    discovered_identifiers: Sequence[str],
) -> None:
    """Require timing output to match the current source-discovered inventory."""
    if len(discovered_identifiers) != len(set(discovered_identifiers)):
        raise ValueError("Source discovery returned duplicate UI test identifiers.")
    expected = set(discovered_identifiers)
    actual = set(timings)
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    errors: list[str] = []
    if missing:
        errors.append(f"missing discovered tests: {', '.join(missing)}")
    if unexpected:
        errors.append(f"unexpected reported tests: {', '.join(unexpected)}")
    if errors:
        raise ValueError("Timing extraction was incomplete: " + "; ".join(errors))


def build_timing_manifest(
    timings: Mapping[str, float],
    *,
    source_kind: str,
    source_identifier: str,
    collected_on: str,
    limitations: str | None = None,
) -> dict[str, Any]:
    """Build the versioned timing document consumed by the shard planner."""
    try:
        date.fromisoformat(collected_on)
    except ValueError as error:
        raise ValueError("--collected-on must be an ISO date in YYYY-MM-DD form.") from error
    provenance: dict[str, object] = {
        "status": "measured",
        "collected_through": collected_on,
        "sources": [
            {
                "kind": source_kind,
                "identifier": source_identifier,
                "collected_on": collected_on,
            }
        ],
    }
    if limitations:
        provenance["limitations"] = limitations
    return {
        "schema_version": 1,
        "provenance": provenance,
        "timings": dict(sorted(timings.items())),
    }


def load_xcresult_payload(xcresult_path: Path) -> dict[str, Any]:
    """Load Apple's structured test-results node report from one bundle."""
    command = [
        "xcrun",
        "xcresulttool",
        "get",
        "test-results",
        "tests",
        "--path",
        str(xcresult_path),
        "--compact",
    ]
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    payload = json.loads(completed.stdout)
    if not isinstance(payload, dict):
        raise ValueError("xcresult test-results payload root must be a JSON object.")
    return payload


def create_argument_parser() -> argparse.ArgumentParser:
    """Create the CLI parser."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--xcresult-path",
        required=True,
        action="append",
        type=Path,
        help="One shard result bundle; repeat for every shard in the run.",
    )
    parser.add_argument("--test-source", required=True, nargs="+", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--test-target", default="AndBibleUITests")
    parser.add_argument("--test-case-class", default="AndBibleUITests")
    parser.add_argument(
        "--source-kind",
        required=True,
        choices=("github-actions-run", "local-run"),
    )
    parser.add_argument("--source-identifier", required=True)
    parser.add_argument("--collected-on", required=True)
    parser.add_argument("--limitations")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Extract, reconcile, and print a versioned UI timing manifest."""
    parser = create_argument_parser()
    args = parser.parse_args(argv)

    payloads = [load_xcresult_payload(path) for path in args.xcresult_path]
    timings = merge_ui_test_timings(
        payloads,
        test_target=args.test_target,
        test_case_class=args.test_case_class,
    )
    discovered_identifiers = discover_ui_test_identifiers_from_files(
        args.test_source,
        test_target=args.test_target,
        test_case_class=args.test_case_class,
    )
    reconcile_discovered_timings(timings, discovered_identifiers)
    manifest = build_timing_manifest(
        timings,
        source_kind=args.source_kind,
        source_identifier=args.source_identifier,
        collected_on=args.collected_on,
        limitations=args.limitations,
    )
    output = json.dumps(manifest, indent=2, sort_keys=True)

    if args.output is not None:
        args.output.write_text(output + "\n")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
