#!/usr/bin/env python3
"""Run selected UI tests in fixture-seeded scenario groups."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
from pathlib import Path
from typing import Sequence

from run_xcodebuild_with_test_selection import (
    build_xcodebuild_command,
    parse_test_selection_args,
)

ONLY_TEST_PREFIX = "-only-testing:"
DEFAULT_BUNDLE_IDENTIFIER = "org.andbible.ios"


def selection_arg_to_identifier(selection_arg: str) -> str:
    """Extract the XCTest identifier from one `-only-testing:` argument."""
    if not selection_arg.startswith(ONLY_TEST_PREFIX):
        raise ValueError(
            f"Unsupported selection argument '{selection_arg}'. "
            f"Expected it to start with '{ONLY_TEST_PREFIX}'."
        )
    return selection_arg[len(ONLY_TEST_PREFIX) :]


def load_fixture_manifest(manifest_path: Path) -> dict[str, str]:
    """Load the test-to-scenario fixture manifest."""
    raw_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(raw_manifest, dict):
        raise ValueError("Fixture manifest must be a JSON object.")

    manifest: dict[str, str] = {}
    for test_identifier, scenario in raw_manifest.items():
        if not isinstance(test_identifier, str):
            raise ValueError("Fixture manifest keys must be strings.")
        if not isinstance(scenario, str) or not scenario.strip():
            raise ValueError(
                f"Fixture manifest entry for '{test_identifier}' must be a non-empty string."
            )
        manifest[test_identifier] = scenario.strip()
    return manifest


def group_selection_args_by_fixture(
    selection_args: Sequence[str],
    fixture_manifest: dict[str, str],
) -> list[tuple[str, list[str]]]:
    """Group selected UI tests by their required fixture scenario."""
    groups: dict[str, list[str]] = {}
    scenario_order: list[str] = []

    for selection_arg in selection_args:
        identifier = selection_arg_to_identifier(selection_arg)
        if identifier not in fixture_manifest:
            raise ValueError(
                "Fixture manifest is missing an entry for "
                f"'{identifier}'. Update scripts/ui_test_fixture_manifest.json."
            )
        scenario = fixture_manifest[identifier]
        if scenario not in groups:
            groups[scenario] = []
            scenario_order.append(scenario)
        groups[scenario].append(selection_arg)

    return [(scenario, groups[scenario]) for scenario in scenario_order]


def derive_group_result_bundle_path(
    base_result_bundle_path: Path,
    *,
    scenario: str,
    group_index: int,
    total_groups: int,
) -> Path:
    """Derive a unique result bundle path for one grouped xcodebuild invocation."""
    if total_groups <= 1:
        return base_result_bundle_path

    scenario_slug = re.sub(r"[^A-Za-z0-9]+", "-", scenario).strip("-").lower() or "scenario"
    return base_result_bundle_path.with_name(
        f"{base_result_bundle_path.stem}-group-{group_index:02d}-{scenario_slug}"
        f"{base_result_bundle_path.suffix}"
    )


def infer_app_path(
    *,
    derived_data_path: Path,
    configuration: str,
    scheme: str,
) -> Path:
    """Infer the built simulator app path from DerivedData and scheme/configuration."""
    return (
        derived_data_path
        / "Build"
        / "Products"
        / f"{configuration}-iphonesimulator"
        / f"{scheme}.app"
    )


def run_command(
    command: Sequence[str],
    *,
    capture_output: bool = False,
) -> subprocess.CompletedProcess[str]:
    """Run one subprocess and echo the exact command line."""
    print("Running:", shlex.join(command))
    return subprocess.run(
        list(command),
        check=True,
        text=True,
        capture_output=capture_output,
    )


def ensure_app_installed(
    *,
    simulator_id: str,
    bundle_identifier: str,
    app_path: Path,
) -> Path:
    """Install the built app on the target simulator and return its data container path."""
    if not app_path.exists():
        raise FileNotFoundError(
            f"Built app was not found at '{app_path}'. Run build-for-testing first."
        )

    subprocess.run(
        ["xcrun", "simctl", "terminate", simulator_id, bundle_identifier],
        check=False,
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    run_command(["xcrun", "simctl", "install", simulator_id, str(app_path)])
    container = run_command(
        ["xcrun", "simctl", "get_app_container", simulator_id, bundle_identifier, "data"],
        capture_output=True,
    )
    container_path = Path(container.stdout.strip())
    if not container_path.exists():
        raise FileNotFoundError(
            f"Simulator data container '{container_path}' does not exist after install."
        )
    return container_path


def reset_and_seed_fixture(
    *,
    fixture_tool_path: Path,
    data_container_path: Path,
    bundle_identifier: str,
    scenario: str,
) -> None:
    """Reset the simulator container and seed one named fixture scenario."""
    if not fixture_tool_path.exists():
        raise FileNotFoundError(
            f"Fixture tool was not found at '{fixture_tool_path}'. Build UITestFixtureTool first."
        )

    run_command(
        [
            str(fixture_tool_path),
            "reset",
            "--data-container",
            str(data_container_path),
            "--bundle-id",
            bundle_identifier,
        ]
    )
    run_command(
        [
            str(fixture_tool_path),
            "seed",
            "--data-container",
            str(data_container_path),
            "--scenario",
            scenario,
            "--bundle-id",
            bundle_identifier,
        ]
    )


def run_grouped_ui_tests(
    *,
    project: str,
    scheme: str,
    configuration: str,
    destination: str,
    simulator_id: str,
    derived_data_path: Path,
    result_bundle_path: Path,
    code_signing_allowed: str,
    selection_args_text: str,
    fixture_manifest_path: Path,
    fixture_tool_path: Path,
    bundle_identifier: str,
    app_path: Path | None,
) -> int:
    """Run selected UI tests as multiple xcodebuild invocations grouped by fixture scenario."""
    selection_args = parse_test_selection_args(selection_args_text)
    if not selection_args:
        raise ValueError("Grouped UI execution requires at least one selected UI test.")

    fixture_manifest = load_fixture_manifest(fixture_manifest_path)
    groups = group_selection_args_by_fixture(selection_args, fixture_manifest)
    resolved_app_path = app_path or infer_app_path(
        derived_data_path=derived_data_path,
        configuration=configuration,
        scheme=scheme,
    )
    data_container_path = ensure_app_installed(
        simulator_id=simulator_id,
        bundle_identifier=bundle_identifier,
        app_path=resolved_app_path,
    )

    total_groups = len(groups)
    for group_index, (scenario, group_selection_args) in enumerate(groups, start=1):
        subprocess.run(
            ["xcrun", "simctl", "terminate", simulator_id, bundle_identifier],
            check=False,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        reset_and_seed_fixture(
            fixture_tool_path=fixture_tool_path,
            data_container_path=data_container_path,
            bundle_identifier=bundle_identifier,
            scenario=scenario,
        )
        group_result_bundle_path = derive_group_result_bundle_path(
            result_bundle_path,
            scenario=scenario,
            group_index=group_index,
            total_groups=total_groups,
        )
        command = build_xcodebuild_command(
            project=project,
            scheme=scheme,
            configuration=configuration,
            destination=destination,
            derived_data_path=str(derived_data_path),
            result_bundle_path=str(group_result_bundle_path),
            code_signing_allowed=code_signing_allowed,
            selection_args_text="\n".join(group_selection_args),
            action="test-without-building",
        )
        run_command(command)
    return 0


def create_argument_parser() -> argparse.ArgumentParser:
    """Create the CLI parser."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--scheme", required=True)
    parser.add_argument("--configuration", required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--simulator-id", required=True)
    parser.add_argument("--derived-data-path", required=True, type=Path)
    parser.add_argument("--result-bundle-path", required=True, type=Path)
    parser.add_argument("--fixture-manifest", required=True, type=Path)
    parser.add_argument("--fixture-tool-path", required=True, type=Path)
    parser.add_argument("--bundle-id", default=DEFAULT_BUNDLE_IDENTIFIER)
    parser.add_argument("--app-path", type=Path)
    parser.add_argument("--test-selection-args")
    parser.add_argument("--code-signing-allowed", default="NO")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Run the requested grouped UI test flow."""
    parser = create_argument_parser()
    args = parser.parse_args(argv)
    selection_args_text = args.test_selection_args
    if selection_args_text is None:
        selection_args_text = os.environ.get("TEST_SELECTION_ARGS", "")
    return run_grouped_ui_tests(
        project=args.project,
        scheme=args.scheme,
        configuration=args.configuration,
        destination=args.destination,
        simulator_id=args.simulator_id,
        derived_data_path=args.derived_data_path,
        result_bundle_path=args.result_bundle_path,
        code_signing_allowed=args.code_signing_allowed,
        selection_args_text=selection_args_text,
        fixture_manifest_path=args.fixture_manifest,
        fixture_tool_path=args.fixture_tool_path,
        bundle_identifier=args.bundle_id,
        app_path=args.app_path,
    )


if __name__ == "__main__":
    raise SystemExit(main())
