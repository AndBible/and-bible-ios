#!/usr/bin/env python3
"""Generate balanced GitHub Actions matrix entries for AndBible UI tests."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

TEST_METHOD_PATTERN = re.compile(
    r"^\s*(?:(?:@\w+(?:\([^)]*\))?|[A-Za-z_][A-Za-z0-9_]*)\s+)*"
    r"func\s+(test[A-Z][A-Za-z0-9_]*)\s*\(",
    re.MULTILINE,
)


@dataclass(frozen=True)
class UITestCase:
    """One discovered UI test with its estimated runtime."""

    identifier: str
    estimated_seconds: float


def discover_ui_test_identifiers(
    swift_source: str,
    *,
    test_target: str,
    test_case_class: str,
) -> list[str]:
    """Extract XCTest UI method identifiers from one Swift source file."""
    identifiers: list[str] = []
    for match in TEST_METHOD_PATTERN.finditer(swift_source):
        method_name = match.group(1)
        identifiers.append(f"{test_target}/{test_case_class}/{method_name}")
    return identifiers


def normalize_test_identifier(
    raw_identifier: str,
    *,
    test_target: str,
    test_case_class: str,
) -> str:
    """Normalize one test identifier into `target/class/method` form."""
    normalized = raw_identifier.strip().rstrip("()")
    if normalized.count("/") == 2:
        return normalized
    if normalized.count("/") == 1:
        target, method = normalized.split("/", 1)
        if target == test_target:
            return f"{test_target}/{test_case_class}/{method}"
    if "/" not in normalized and normalized.startswith("test"):
        return f"{test_target}/{test_case_class}/{normalized}"
    raise ValueError(
        "Unsupported test identifier format "
        f"'{raw_identifier}'. Expected one of: "
        f"'{test_target}/{test_case_class}/testMethod', "
        f"'{test_target}/testMethod', or 'testMethod'."
    )


def load_timing_manifest(
    manifest_path: Path | None,
    *,
    test_target: str,
    test_case_class: str,
) -> dict[str, float]:
    """Load one optional test-duration manifest."""
    if manifest_path is None or not manifest_path.exists():
        return {}

    raw_manifest = json.loads(manifest_path.read_text())
    if not isinstance(raw_manifest, dict):
        raise ValueError("Timing manifest must be a JSON object.")

    timings: dict[str, float] = {}
    for raw_identifier, duration in raw_manifest.items():
        if not isinstance(raw_identifier, str):
            raise ValueError("Timing manifest keys must be strings.")
        if not isinstance(duration, (int, float)):
            raise ValueError("Timing manifest values must be numbers.")
        try:
            normalized = normalize_test_identifier(
                raw_identifier,
                test_target=test_target,
                test_case_class=test_case_class,
            )
        except ValueError as error:
            raise ValueError(f"Invalid timing manifest key '{raw_identifier}': {error}") from error
        timings[normalized] = float(duration)
    return timings


def build_ui_test_cases(
    identifiers: Sequence[str],
    timings: dict[str, float],
    *,
    default_duration_seconds: float,
) -> list[UITestCase]:
    """Attach estimated durations to each discovered UI test."""
    return [
        UITestCase(
            identifier=identifier,
            estimated_seconds=timings.get(identifier, default_duration_seconds),
        )
        for identifier in identifiers
    ]


def assign_cases_to_shards(cases: Sequence[UITestCase], *, shard_count: int) -> list[list[UITestCase]]:
    """Greedily balance UI tests across shards by estimated duration."""
    if shard_count <= 0:
        raise ValueError("Shard count must be positive.")
    if not cases:
        raise ValueError("At least one UI test case is required.")

    effective_shard_count = min(shard_count, len(cases))

    shards: list[list[UITestCase]] = [[] for _ in range(effective_shard_count)]
    shard_totals = [0.0 for _ in range(effective_shard_count)]

    for case in sorted(cases, key=lambda item: (-item.estimated_seconds, item.identifier)):
        shard_index = min(
            range(effective_shard_count),
            key=lambda idx: (shard_totals[idx], len(shards[idx]), idx),
        )
        shards[shard_index].append(case)
        shard_totals[shard_index] += case.estimated_seconds

    for shard in shards:
        shard.sort(key=lambda item: item.identifier)
    return shards


def choose_shard_count(
    cases: Sequence[UITestCase],
    *,
    minimum_shard_count: int,
    target_shard_duration_seconds: float | None,
    maximum_shard_count: int | None,
) -> int:
    """Choose one effective shard count from suite size and runtime budget."""
    if minimum_shard_count <= 0:
        raise ValueError("Minimum shard count must be positive.")
    if maximum_shard_count is not None and maximum_shard_count <= 0:
        raise ValueError("Maximum shard count must be positive when provided.")
    if target_shard_duration_seconds is not None and target_shard_duration_seconds <= 0:
        raise ValueError("Target shard duration must be positive when provided.")
    if not cases:
        raise ValueError("At least one UI test case is required.")

    shard_count = minimum_shard_count
    if target_shard_duration_seconds is not None:
        total_estimated_seconds = sum(case.estimated_seconds for case in cases)
        shard_count = max(
            shard_count,
            math.ceil(total_estimated_seconds / target_shard_duration_seconds),
        )
    if maximum_shard_count is not None:
        shard_count = min(shard_count, maximum_shard_count)
    return min(shard_count, len(cases))


def build_matrix(
    shards: Sequence[Sequence[UITestCase]],
    *,
    timeout_minutes: int,
) -> dict[str, list[dict[str, object]]]:
    """Build the GitHub Actions matrix payload for the UI shards."""
    include: list[dict[str, object]] = []
    shard_count = len(shards)
    for index, shard in enumerate(shards, start=1):
        selection_args = "\n".join(f"-only-testing:{case.identifier}" for case in shard)
        estimated_seconds = round(sum(case.estimated_seconds for case in shard), 3)
        include.append(
            {
                "job_name": f"UI Tests (Simulator, Shard {index}/{shard_count})",
                "artifact_suffix": f"ui-shard-{index}",
                "timeout_minutes": timeout_minutes,
                "build_xcresult_bundle_path": f".artifacts/AndBibleBuild-ui-shard-{index}.xcresult",
                "test_xcresult_bundle_path": f".artifacts/AndBibleTests-ui-shard-{index}.xcresult",
                "test_selection_args": selection_args,
                "estimated_duration_seconds": estimated_seconds,
                "test_count": len(shard),
            }
        )
    return {"include": include}


def write_github_outputs(
    github_output_path: Path,
    *,
    matrix_json: str,
    shard_count: int,
) -> None:
    """Write matrix outputs for GitHub Actions."""
    with github_output_path.open("a", encoding="utf-8") as handle:
        handle.write("matrix<<__CODEX_EOF__\n")
        handle.write(matrix_json)
        handle.write("\n__CODEX_EOF__\n")
        handle.write(f"shard_count={shard_count}\n")


def create_argument_parser() -> argparse.ArgumentParser:
    """Create the CLI parser."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test-file", required=True, type=Path)
    parser.add_argument("--timings-file", type=Path)
    parser.add_argument("--shard-count", type=int, default=2)
    parser.add_argument("--target-shard-duration-seconds", type=float)
    parser.add_argument("--max-shard-count", type=int)
    parser.add_argument("--default-duration-seconds", type=float, default=60.0)
    parser.add_argument("--timeout-minutes", type=int, default=90)
    parser.add_argument("--test-target", default="AndBibleUITests")
    parser.add_argument("--test-case-class", default="AndBibleUITests")
    parser.add_argument("--github-output", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Generate and print one UI shard matrix."""
    parser = create_argument_parser()
    args = parser.parse_args(argv)

    swift_source = args.test_file.read_text()
    identifiers = discover_ui_test_identifiers(
        swift_source,
        test_target=args.test_target,
        test_case_class=args.test_case_class,
    )
    if not identifiers:
        raise SystemExit("No UI tests were discovered.")

    timings = load_timing_manifest(
        args.timings_file,
        test_target=args.test_target,
        test_case_class=args.test_case_class,
    )
    cases = build_ui_test_cases(
        identifiers,
        timings,
        default_duration_seconds=args.default_duration_seconds,
    )
    effective_shard_count = choose_shard_count(
        cases,
        minimum_shard_count=args.shard_count,
        target_shard_duration_seconds=args.target_shard_duration_seconds,
        maximum_shard_count=args.max_shard_count,
    )
    shards = assign_cases_to_shards(cases, shard_count=effective_shard_count)
    matrix = build_matrix(shards, timeout_minutes=args.timeout_minutes)
    matrix_json = json.dumps(matrix, separators=(",", ":"), sort_keys=True)

    for index, shard in enumerate(shards, start=1):
        estimated_seconds = sum(case.estimated_seconds for case in shard)
        print(
            f"Shard {index}/{len(shards)}: {len(shard)} tests, "
            f"estimated {estimated_seconds:.3f}s"
        )

    print(matrix_json)

    github_output = args.github_output or (
        Path(os.environ["GITHUB_OUTPUT"]) if "GITHUB_OUTPUT" in os.environ else None
    )
    if github_output is not None:
        write_github_outputs(github_output, matrix_json=matrix_json, shard_count=len(shards))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
