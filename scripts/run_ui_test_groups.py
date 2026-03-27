#!/usr/bin/env python3
"""Run selected UI tests in fixture-seeded scenario groups."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import time
from pathlib import Path
from typing import Sequence

from run_xcodebuild_with_test_selection import (
    build_xcodebuild_command,
    parse_test_selection_args,
)

ONLY_TEST_PREFIX = "-only-testing:"
DEFAULT_BUNDLE_IDENTIFIER = "org.andbible.ios"
SIMCTL_TERMINATE_TIMEOUT_SECONDS = 15
SIMCTL_UNINSTALL_TIMEOUT_SECONDS = 30
SIMCTL_INSTALL_TIMEOUT_SECONDS = 120
SIMCTL_GET_CONTAINER_TIMEOUT_SECONDS = 30
SIMCTL_CREATE_TIMEOUT_SECONDS = 30
SIMCTL_DELETE_TIMEOUT_SECONDS = 30
SIMCTL_LIST_RETRIES = 3
SIMCTL_LIST_DELAY_SECONDS = 2
GROUP_TRANSITION_DELAY_SECONDS = 15


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
    timeout_seconds: int | None = None,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run one subprocess and echo the exact command line."""
    print("Running:", shlex.join(command), flush=True)
    return subprocess.run(
        list(command),
        check=True,
        text=True,
        capture_output=capture_output,
        env=env,
        timeout=timeout_seconds,
    )


def read_simctl_json(*args: str) -> dict[str, object]:
    """Read structured simulator metadata via `simctl list`."""
    command = ["xcrun", "simctl", "list", *args, "-j"]
    last_stderr = ""
    for attempt in range(1, SIMCTL_LIST_RETRIES + 1):
        print("Running:", shlex.join(command), flush=True)
        result = subprocess.run(
            command,
            check=False,
            text=True,
            capture_output=True,
        )
        if result.returncode == 0:
            return json.loads(result.stdout)

        last_stderr = result.stderr.strip()
        print(
            f"simctl list failed on attempt {attempt} with exit code {result.returncode}; "
            f"{'retrying' if attempt < SIMCTL_LIST_RETRIES else 'failing.'}",
            flush=True,
        )
        if last_stderr:
            print(last_stderr, flush=True)
        if attempt < SIMCTL_LIST_RETRIES:
            time.sleep(SIMCTL_LIST_DELAY_SECONDS)

    raise RuntimeError(
        "simctl list failed after "
        f"{SIMCTL_LIST_RETRIES} attempts for {' '.join(args)}.\n{last_stderr}"
    )


def terminate_app_if_running(
    *,
    simulator_id: str,
    bundle_identifier: str,
    timeout_seconds: int = SIMCTL_TERMINATE_TIMEOUT_SECONDS,
) -> None:
    """Best-effort terminate the app on the target simulator without allowing indefinite hangs."""
    command = ["xcrun", "simctl", "terminate", simulator_id, bundle_identifier]
    print(f"Running: {shlex.join(command)} (best-effort)", flush=True)
    try:
        subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired:
        print(
            "simctl terminate timed out after "
            f"{timeout_seconds}s for {bundle_identifier}; continuing.",
            flush=True,
        )


def shutdown_simulator_if_running(
    *,
    simulator_id: str,
    timeout_seconds: int = SIMCTL_TERMINATE_TIMEOUT_SECONDS,
) -> None:
    """Best-effort shut down a simulator without allowing indefinite hangs."""
    command = ["xcrun", "simctl", "shutdown", simulator_id]
    print(f"Running: {shlex.join(command)} (best-effort)", flush=True)
    try:
        subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired:
        print(
            f"simctl shutdown timed out after {timeout_seconds}s for {simulator_id}; continuing.",
            flush=True,
        )


def delete_simulator_if_present(
    *,
    simulator_id: str,
    timeout_seconds: int = SIMCTL_DELETE_TIMEOUT_SECONDS,
) -> None:
    """Best-effort delete a simulator device without allowing indefinite hangs."""
    command = ["xcrun", "simctl", "delete", simulator_id]
    print(f"Running: {shlex.join(command)} (best-effort)", flush=True)
    try:
        subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired:
        print(
            f"simctl delete timed out after {timeout_seconds}s for {simulator_id}; continuing.",
            flush=True,
        )


def resolve_simulator_runtime_and_device_metadata(simulator_id: str) -> tuple[str, str, str]:
    """Resolve the runtime identifier, device-type identifier, and display name for a simulator."""
    payload = read_simctl_json("devices", "available")
    for runtime_identifier, devices in payload.get("devices", {}).items():
        if not isinstance(runtime_identifier, str) or not isinstance(devices, list):
            continue
        for device in devices:
            if not isinstance(device, dict):
                continue
            if str(device.get("udid", "")) == simulator_id:
                return (
                    runtime_identifier,
                    str(device.get("deviceTypeIdentifier", "")),
                    str(device.get("name", "")),
                )
    raise ValueError(f"Unable to resolve runtime metadata for simulator '{simulator_id}'.")


def create_group_simulator(
    *,
    base_simulator_id: str,
    scenario: str,
    group_index: int,
) -> tuple[str, str]:
    """Create a fresh simulator for one grouped UI-test invocation."""
    runtime_identifier, device_type_identifier, device_name = (
        resolve_simulator_runtime_and_device_metadata(base_simulator_id)
    )
    if not device_type_identifier:
        raise ValueError(
            f"Simulator '{base_simulator_id}' did not expose a deviceTypeIdentifier."
        )
    scenario_slug = re.sub(r"[^A-Za-z0-9]+", "-", scenario).strip("-") or "scenario"
    display_device_name = device_type_identifier.rsplit(".", 1)[-1].replace("-", " ")
    if not display_device_name or display_device_name == device_type_identifier:
        display_device_name = device_name or "iPhone"
    group_device_name = f"AndBible Group {group_index} {scenario_slug} {display_device_name}"
    result = run_command(
        [
            "xcrun",
            "simctl",
            "create",
            group_device_name,
            device_type_identifier,
            runtime_identifier,
        ],
        capture_output=True,
        timeout_seconds=SIMCTL_CREATE_TIMEOUT_SECONDS,
    )
    created_simulator_id = result.stdout.strip()
    if not created_simulator_id:
        raise RuntimeError(
            f"simctl create did not return a simulator identifier for '{group_device_name}'."
        )
    return created_simulator_id, f"id={created_simulator_id}"


def uninstall_app_if_installed(
    *,
    simulator_id: str,
    bundle_identifier: str,
    timeout_seconds: int = SIMCTL_UNINSTALL_TIMEOUT_SECONDS,
) -> None:
    """Best-effort uninstall the app on the target simulator without allowing indefinite hangs."""
    command = ["xcrun", "simctl", "uninstall", simulator_id, bundle_identifier]
    print(f"Running: {shlex.join(command)} (best-effort)", flush=True)
    try:
        subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired:
        print(
            "simctl uninstall timed out after "
            f"{timeout_seconds}s for {bundle_identifier}; continuing.",
            flush=True,
        )


def install_app_with_retry(
    *,
    simulator_id: str,
    app_path: Path,
    bundle_identifier: str,
    timeout_seconds: int = SIMCTL_INSTALL_TIMEOUT_SECONDS,
) -> None:
    """Install the app on the target simulator, retrying once after a clean uninstall."""
    command = ["xcrun", "simctl", "install", simulator_id, str(app_path)]
    last_error: subprocess.TimeoutExpired | subprocess.CalledProcessError | None = None

    for attempt in (1, 2):
        try:
            run_command(command, timeout_seconds=timeout_seconds)
            return
        except subprocess.TimeoutExpired as exc:
            last_error = exc
            print(
                "simctl install timed out after "
                f"{timeout_seconds}s on attempt {attempt}; "
                f"{'retrying after uninstall' if attempt == 1 else 'failing.'}",
                flush=True,
            )
        except subprocess.CalledProcessError as exc:
            last_error = exc
            print(
                "simctl install failed on attempt "
                f"{attempt} with exit code {exc.returncode}; "
                f"{'retrying after uninstall' if attempt == 1 else 'failing.'}",
                flush=True,
            )

        if attempt == 1:
            terminate_app_if_running(
                simulator_id=simulator_id,
                bundle_identifier=bundle_identifier,
            )
            uninstall_app_if_installed(
                simulator_id=simulator_id,
                bundle_identifier=bundle_identifier,
            )
            continue

        assert last_error is not None
        raise last_error


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

    print(
        f"Preparing simulator app install for {bundle_identifier} from {app_path}",
        flush=True,
    )
    terminate_app_if_running(
        simulator_id=simulator_id,
        bundle_identifier=bundle_identifier,
    )
    uninstall_app_if_installed(
        simulator_id=simulator_id,
        bundle_identifier=bundle_identifier,
    )
    install_app_with_retry(
        simulator_id=simulator_id,
        app_path=app_path,
        bundle_identifier=bundle_identifier,
    )
    container = run_command(
        ["xcrun", "simctl", "get_app_container", simulator_id, bundle_identifier, "data"],
        capture_output=True,
        timeout_seconds=SIMCTL_GET_CONTAINER_TIMEOUT_SECONDS,
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
    fresh_simulator_per_group: bool = False,
) -> int:
    """Run selected UI tests as multiple xcodebuild invocations grouped by fixture scenario."""
    selection_args = parse_test_selection_args(selection_args_text)
    if not selection_args:
        raise ValueError("Grouped UI execution requires at least one selected UI test.")

    fixture_manifest = load_fixture_manifest(fixture_manifest_path)
    groups = group_selection_args_by_fixture(selection_args, fixture_manifest)
    total_groups = len(groups)
    test_runner_bundle_identifier = f"{bundle_identifier.removesuffix('.ios')}.AndBibleUITests.xctrunner"
    failed_groups: list[tuple[int, str, int]] = []

    for group_index, (scenario, group_selection_args) in enumerate(groups, start=1):
        print(
            f"Running fixture group {group_index}/{total_groups}: {scenario} "
            f"({len(group_selection_args)} test(s))",
            flush=True,
        )
        group_simulator_id = simulator_id
        group_destination = destination
        created_group_simulator_id: str | None = None
        if fresh_simulator_per_group:
            group_simulator_id, group_destination = create_group_simulator(
                base_simulator_id=simulator_id,
                scenario=scenario,
                group_index=group_index,
            )
            created_group_simulator_id = group_simulator_id
        group_result_bundle_path = derive_group_result_bundle_path(
            result_bundle_path,
            scenario=scenario,
            group_index=group_index,
            total_groups=total_groups,
        )
        group_env = os.environ.copy()
        group_env["UITEST_FIXTURE_SCENARIO"] = scenario
        group_env["UITEST_FIXTURE_TOOL_PATH"] = str(fixture_tool_path.resolve())
        group_env["UITEST_BUNDLE_ID"] = bundle_identifier
        group_env["UITEST_SIMULATOR_ID"] = group_simulator_id
        command = build_xcodebuild_command(
            project=project,
            scheme=scheme,
            configuration=configuration,
            destination=group_destination,
            derived_data_path=str(derived_data_path),
            result_bundle_path=str(group_result_bundle_path),
            code_signing_allowed=code_signing_allowed,
            selection_args_text="\n".join(group_selection_args),
            action="test-without-building",
        )
        try:
            run_command(command, env=group_env)
        except subprocess.CalledProcessError as exc:
            print(
                f"Fixture group {group_index}/{total_groups} ({scenario}) failed with exit code "
                f"{exc.returncode}. Continuing to the next group.",
                flush=True,
            )
            failed_groups.append((group_index, scenario, exc.returncode))
        finally:
            terminate_app_if_running(
                simulator_id=group_simulator_id,
                bundle_identifier=bundle_identifier,
            )
            terminate_app_if_running(
                simulator_id=group_simulator_id,
                bundle_identifier=test_runner_bundle_identifier,
            )
            if created_group_simulator_id is not None:
                shutdown_simulator_if_running(simulator_id=created_group_simulator_id)
                delete_simulator_if_present(simulator_id=created_group_simulator_id)
        if group_index < total_groups and not fresh_simulator_per_group:
            print(
                "Waiting "
                f"{GROUP_TRANSITION_DELAY_SECONDS}s for simulator app install state to settle "
                "before the next fixture group.",
                flush=True,
            )
            time.sleep(GROUP_TRANSITION_DELAY_SECONDS)
    if failed_groups:
        print("One or more fixture groups failed:", flush=True)
        for group_index, scenario, returncode in failed_groups:
            print(
                f"- group {group_index}/{total_groups} ({scenario}) exit code {returncode}",
                flush=True,
            )
        return 1
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
    parser.add_argument(
        "--fresh-simulator-per-group",
        action="store_true",
        help="Create a fresh simulator device for each fixture group instead of reusing one simulator",
    )
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
        fresh_simulator_per_group=args.fresh_simulator_per_group,
    )


if __name__ == "__main__":
    raise SystemExit(main())
