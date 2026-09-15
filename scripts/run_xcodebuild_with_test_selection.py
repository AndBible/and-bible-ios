#!/usr/bin/env python3
"""Run xcodebuild with newline-delimited test selection arguments."""

from __future__ import annotations

import argparse
import contextlib
import glob
import json
import os
import plistlib
import shutil
import signal
import shlex
import subprocess
import sys
import tempfile
import uuid
from collections.abc import Callable, Iterator, MutableMapping
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence
from urllib.parse import unquote, urlparse

from build_ui_test_shards import discover_ui_test_identifiers_from_files
from ui_test_fixture_service import (
    FixtureServiceConfiguration,
    FixtureServiceError,
    UITestFixtureService,
    install_simulator_application,
)


PASSING_TEST_RESULTS = frozenset({"Passed", "Expected Failure"})


class ResultBundleValidationError(RuntimeError):
    """Raised when xcresult evidence does not match the requested test contract."""


@dataclass(frozen=True)
class ResultBundleTestReport:
    """Structured summary and per-test results read from one xcresult bundle."""

    summary: Mapping[str, object]
    test_results: Mapping[str, tuple[str, ...]]


@dataclass(frozen=True)
class ResultBundleTestCase:
    """One reported XCTest attempt from the structured test-results report."""

    identifier: str
    result: str
    duration_seconds: float | None


@dataclass(frozen=True)
class UITestApplicationProduct:
    """One simulator application explicitly named by the UI-test xctestrun."""

    path: Path
    bundle_identifier: str


def parse_test_selection_args(selection_text: str) -> list[str]:
    """Split newline-delimited xcodebuild selection arguments."""
    return [line.strip() for line in selection_text.splitlines() if line.strip()]


def requested_test_identifiers(
    selection_text: str,
    discovered_identifiers: Sequence[str] = (),
) -> list[str]:
    """Return exact test identities selected by xcodebuild arguments.

    Method-level selectors are already exact. Target/class selectors are expanded
    against source-discovered identities when the caller supplies them. Skip
    selectors are applied to both forms.
    """
    arguments = parse_test_selection_args(selection_text)
    only_selectors = [
        argument.removeprefix("-only-testing:").rstrip("/")
        for argument in arguments
        if argument.startswith("-only-testing:")
    ]
    skip_selectors = [
        argument.removeprefix("-skip-testing:").rstrip("/")
        for argument in arguments
        if argument.startswith("-skip-testing:")
    ]

    def selector_matches(identifier: str, selector: str) -> bool:
        return identifier == selector or identifier.startswith(f"{selector}/")

    if discovered_identifiers:
        return sorted(
            identifier
            for identifier in set(discovered_identifiers)
            if (not only_selectors or any(selector_matches(identifier, item) for item in only_selectors))
            and not any(selector_matches(identifier, item) for item in skip_selectors)
        )

    return sorted(
        {
            selector
            for selector in only_selectors
            if selector.count("/") >= 2
            and not any(selector_matches(selector, skipped) for skipped in skip_selectors)
        }
    )


def selected_xcode_developer_dir_from_link(
    link_path: str = "/var/db/xcode_select_link",
) -> str | None:
    """Return the global xcode-select developer directory without honoring DEVELOPER_DIR."""
    try:
        selected_path = os.readlink(link_path).strip()
    except OSError:
        return None
    if not selected_path:
        return None
    if selected_path.endswith(".app"):
        return os.path.join(selected_path, "Contents", "Developer")
    return selected_path


def selected_ui_test_developer_dir(
    environment: Mapping[str, str],
    selected_xcode_developer_dir: Callable[[], str | None] = selected_xcode_developer_dir_from_link,
) -> str | None:
    """Return the selected Xcode developer directory for UI-test host commands."""
    ui_test_developer_dir = environment.get("UITEST_DEVELOPER_DIR")
    if ui_test_developer_dir:
        return ui_test_developer_dir

    sdk_root = environment.get("MD_APPLE_SDK_ROOT")
    if sdk_root:
        return os.path.join(sdk_root, "Contents", "Developer")

    xcode_select_developer_dir = selected_xcode_developer_dir()
    if xcode_select_developer_dir:
        return xcode_select_developer_dir

    developer_dir = environment.get("DEVELOPER_DIR")
    if developer_dir:
        return developer_dir

    return None


def selection_requests_ui_tests(selection_text: str) -> bool:
    """Return whether the xcodebuild selection explicitly asks for UI tests."""
    return any(
        argument.startswith("-only-testing:AndBibleUITests")
        for argument in parse_test_selection_args(selection_text)
    )


def simulator_id_from_destination(destination: str) -> str:
    """Return the one canonical simulator UUID in an explicit xcodebuild destination."""
    destination_fields: dict[str, list[str]] = {}
    for component in destination.split(","):
        key, separator, value = component.strip().partition("=")
        if not separator or not key or not value:
            continue
        destination_fields.setdefault(key.strip().lower(), []).append(value.strip())
    identifiers = destination_fields.get("id", [])
    if len(identifiers) != 1:
        raise ValueError(
            "UI-test fixture service requires one explicit simulator id in --destination"
        )
    try:
        parsed = uuid.UUID(identifiers[0])
    except ValueError as error:
        raise ValueError(
            f"UI-test destination id must be a simulator UUID: {identifiers[0]!r}"
        ) from error
    if str(parsed).lower() != identifiers[0].lower():
        raise ValueError("UI-test destination id must be a canonical simulator UUID")
    return identifiers[0]


def fixture_service_configuration(
    *,
    directory: Path,
    destination: str,
    environment: Mapping[str, str],
) -> FixtureServiceConfiguration:
    """Resolve the bounded fixture-service inputs owned by this wrapper invocation."""
    simulator_id = simulator_id_from_destination(destination)
    configured_simulator_id = environment.get("UITEST_SIMULATOR_ID")
    if configured_simulator_id is None:
        raise ValueError("UI tests require UITEST_SIMULATOR_ID")
    if configured_simulator_id.casefold() != simulator_id.casefold():
        raise ValueError(
            "UITEST_SIMULATOR_ID does not match the explicit --destination simulator id"
        )
    required_environment = {
        "UITEST_FIXTURE_TOOL_PATH": "fixture_tool_path",
        "UITEST_FIXTURE_MANIFEST_PATH": "fixture_manifest_path",
        "UITEST_SWORD_FIXTURE_PATH": "sword_fixture_path",
        "UITEST_BUNDLE_ID": "bundle_identifier",
    }
    missing = [key for key in required_environment if not environment.get(key)]
    if missing:
        raise ValueError("UI tests require fixture inputs: " + ", ".join(missing))
    performance_scale = environment.get("PERFORMANCE_LIBRARY_SCALE")
    if performance_scale is not None and performance_scale not in {
        "small",
        "10",
        "1000",
        "10000",
    }:
        raise ValueError(
            "PERFORMANCE_LIBRARY_SCALE must be small, 10, 1000, or 10000 for UI tests"
        )
    additional_scenarios = (
        frozenset({f"performance-bookmarks-{performance_scale}"})
        if performance_scale not in {None, "small"}
        else frozenset()
    )
    return FixtureServiceConfiguration(
        directory=directory,
        simulator_id=simulator_id,
        bundle_identifier=environment["UITEST_BUNDLE_ID"],
        fixture_tool_path=Path(environment["UITEST_FIXTURE_TOOL_PATH"]),
        fixture_manifest_path=Path(environment["UITEST_FIXTURE_MANIFEST_PATH"]),
        sword_fixture_path=Path(environment["UITEST_SWORD_FIXTURE_PATH"]),
        additional_allowed_scenarios=additional_scenarios,
    )


@contextlib.contextmanager
def ui_test_fixture_service_session(
    *,
    destination: str,
    environment: MutableMapping[str, str],
    application_path: Path,
    install_diagnostic_path: Path | None = None,
    service_factory: Callable[..., UITestFixtureService] | None = None,
    application_installer: Callable[..., None] | None = None,
) -> Iterator[Path]:
    """Install the target, run its private service, and restore the environment."""
    previous_directory = environment.get("UITEST_FIXTURE_SERVICE_DIRECTORY")
    with tempfile.TemporaryDirectory(prefix="andbible-ui-fixture-service-") as temporary_root:
        service_directory = Path(temporary_root) / "requests"
        configuration = fixture_service_configuration(
            directory=service_directory,
            destination=destination,
            environment=environment,
        )
        service = (service_factory or UITestFixtureService)(configuration)
        (application_installer or install_simulator_application)(
            simulator_id=configuration.simulator_id,
            application_path=application_path,
            bundle_identifier=configuration.bundle_identifier,
            diagnostic_path=install_diagnostic_path,
        )
        service.start()
        environment["UITEST_FIXTURE_SERVICE_DIRECTORY"] = str(service_directory)
        try:
            yield service_directory
        finally:
            try:
                service.stop()
            finally:
                if previous_directory is None:
                    environment.pop("UITEST_FIXTURE_SERVICE_DIRECTORY", None)
                else:
                    environment["UITEST_FIXTURE_SERVICE_DIRECTORY"] = previous_directory


def discover_single_xctestrun_path(derived_data_path: str | None) -> str | None:
    """Return the sole .xctestrun file from a derived-data build output, if unambiguous."""
    if derived_data_path is None:
        return None
    products_glob = os.path.join(derived_data_path, "Build", "Products", "*.xctestrun")
    xctestrun_paths = sorted(glob.glob(products_glob))
    if len(xctestrun_paths) != 1:
        return None
    return xctestrun_paths[0]


def fixture_host_diagnostic_path(result_bundle_path: str) -> Path:
    """Return the install-timeout artifact adjacent to the requested result bundle."""
    result_path = Path(result_bundle_path)
    if not result_path.name:
        raise ValueError("result bundle path must name a file")
    return result_path.with_suffix(".fixture-host-diagnostic.json")


def _xctestrun_test_targets(xctestrun: Mapping[str, object]) -> list[Mapping[str, object]]:
    """Return format-one and format-two test-target dictionaries."""
    targets = [
        value
        for key, value in xctestrun.items()
        if key != "__xctestrun_metadata__" and isinstance(value, dict)
    ]
    configurations = xctestrun.get("TestConfigurations", [])
    if isinstance(configurations, list):
        for configuration in configurations:
            if not isinstance(configuration, dict):
                continue
            test_targets = configuration.get("TestTargets", [])
            if isinstance(test_targets, list):
                targets.extend(target for target in test_targets if isinstance(target, dict))
    return targets


def resolve_ui_test_application_product(
    xctestrun_path: str,
    *,
    expected_bundle_identifier: str,
) -> UITestApplicationProduct:
    """Resolve and verify the simulator app that a UI-test xctestrun will launch."""
    path = Path(xctestrun_path)
    try:
        with path.open("rb") as plist_file:
            xctestrun = plistlib.load(plist_file)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ValueError(f"cannot read UI-test xctestrun product: {error}") from error
    if not isinstance(xctestrun, dict):
        raise ValueError("UI-test xctestrun product must be a property-list dictionary")

    ui_targets = [
        target
        for target in _xctestrun_test_targets(xctestrun)
        if target.get("IsUITestBundle") is True
    ]
    if not ui_targets:
        raise ValueError("the selected .xctestrun product contains no UI-test bundle")

    declared_paths: set[str] = set()
    for target in ui_targets:
        declared_path = target.get("UITargetAppPath")
        if not isinstance(declared_path, str) or not declared_path:
            raise ValueError("UI-test xctestrun bundle is missing UITargetAppPath")
        declared_paths.add(declared_path)
        declared_bundle_identifier = target.get("UITargetAppBundleIdentifier")
        if (
            declared_bundle_identifier is not None
            and declared_bundle_identifier != expected_bundle_identifier
        ):
            raise ValueError(
                "UI-test xctestrun target bundle identifier does not match "
                f"UITEST_BUNDLE_ID: {declared_bundle_identifier!r}"
            )
    if len(declared_paths) != 1:
        raise ValueError("UI-test xctestrun bundles do not identify one target application")

    declared_path = declared_paths.pop()
    test_root_token = "__TESTROOT__/"
    if not declared_path.startswith(test_root_token):
        raise ValueError("UITargetAppPath must be rooted at __TESTROOT__")
    relative_path = Path(declared_path.removeprefix(test_root_token))
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise ValueError("UITargetAppPath escapes the xctestrun product directory")
    test_root = path.parent.resolve()
    application_path = (test_root / relative_path).resolve()
    try:
        application_path.relative_to(test_root)
    except ValueError as error:
        raise ValueError("UITargetAppPath escapes the xctestrun product directory") from error
    if application_path.suffix != ".app" or not application_path.is_dir():
        raise ValueError(
            f"UI-test target application is missing: {application_path}"
        )

    info_path = application_path / "Info.plist"
    try:
        with info_path.open("rb") as plist_file:
            info = plistlib.load(plist_file)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ValueError(f"cannot read UI-test target application Info.plist: {error}") from error
    if not isinstance(info, dict):
        raise ValueError("UI-test target application Info.plist must be a dictionary")
    actual_bundle_identifier = info.get("CFBundleIdentifier")
    if actual_bundle_identifier != expected_bundle_identifier:
        raise ValueError(
            "UI-test target application bundle identifier does not match "
            f"UITEST_BUNDLE_ID: {actual_bundle_identifier!r}"
        )
    supported_platforms = info.get("CFBundleSupportedPlatforms")
    if not isinstance(supported_platforms, list) or "iPhoneSimulator" not in supported_platforms:
        raise ValueError("UI-test target application is not an iOS Simulator product")
    platform_name = info.get("DTPlatformName")
    if platform_name is not None and platform_name != "iphonesimulator":
        raise ValueError("UI-test target application has a non-simulator platform identity")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        raise ValueError("UI-test target application has no CFBundleExecutable")
    executable_path = application_path / executable_name
    if not executable_path.is_file():
        raise ValueError(
            f"UI-test target application executable is missing: {executable_path}"
        )
    return UITestApplicationProduct(
        path=application_path,
        bundle_identifier=actual_bundle_identifier,
    )


def ui_test_host_environment_variables(environment: Mapping[str, str]) -> dict[str, str]:
    """Export allowlisted client inputs with paths anchored to the invoking host.

    XCTest's working directory differs from the host checkout. Resolve relative
    manifest and service paths before crossing that process boundary; preserve
    non-path values and never forward unrelated host environment variables.
    This reads no fixture contents and does not mutate the caller's mapping.
    """
    fixture_keys = (
        "UITEST_FIXTURE_MANIFEST_PATH",
        "UITEST_SIMULATOR_ID",
        "UITEST_BUNDLE_ID",
        "UITEST_FIXTURE_SERVICE_DIRECTORY",
        "PERFORMANCE_LIBRARY_SCALE",
    )
    client_environment = {
        key: environment[key]
        for key in fixture_keys
        if environment.get(key)
    }
    for key in ("UITEST_FIXTURE_MANIFEST_PATH", "UITEST_FIXTURE_SERVICE_DIRECTORY"):
        if key in client_environment:
            client_environment[key] = str(Path(client_environment[key]).absolute())
    return client_environment


def patch_xctestrun_ui_test_environment(
    xctestrun_path: str,
    host_environment: Mapping[str, str] | None = None,
) -> bool:
    """Inject the bounded UI-test client inputs into an .xctestrun file."""
    with open(xctestrun_path, "rb") as plist_file:
        xctestrun = plistlib.load(plist_file)

    host_environment_variables = ui_test_host_environment_variables(host_environment or os.environ)
    patched = False
    test_targets = _xctestrun_test_targets(xctestrun)
    for test_configuration in test_targets:
        if test_configuration.get("IsUITestBundle") is not True:
            continue
        for environment_key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            environment = test_configuration.setdefault(environment_key, {})
            environment.update(host_environment_variables)
            patched = True

    if patched:
        with open(xctestrun_path, "wb") as plist_file:
            plistlib.dump(xctestrun, plist_file)
    return patched


@contextlib.contextmanager
def temporary_patched_xctestrun_ui_test_environment(
    xctestrun_path: str,
    host_environment: Mapping[str, str] | None = None,
) -> Iterator[str]:
    """Yield a same-directory patched copy while preserving the portable product."""
    source = Path(xctestrun_path)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{source.stem}-ui-environment-",
        suffix=source.suffix,
        dir=source.parent,
    )
    os.close(descriptor)
    temporary_path = Path(temporary_name)
    try:
        shutil.copy2(source, temporary_path)
        if not patch_xctestrun_ui_test_environment(
            str(temporary_path),
            host_environment=host_environment,
        ):
            raise ValueError("the selected .xctestrun product contains no UI-test bundle")
        yield str(temporary_path)
    finally:
        temporary_path.unlink(missing_ok=True)


def build_xcodebuild_command(
    *,
    project: str | None,
    scheme: str | None,
    configuration: str | None,
    destination: str,
    derived_data_path: str | None,
    result_bundle_path: str,
    code_signing_allowed: str,
    selection_args_text: str,
    action: str,
    xctestrun_path: str | None = None,
    collect_test_diagnostics: str | None = None,
) -> list[str]:
    """Construct one explicit project or ``.xctestrun`` xcodebuild invocation.

    ``collect_test_diagnostics`` accepts only Xcode's public ``on-failure`` and
    ``never`` values. Omitting it preserves Xcode's default diagnostic behavior.
    The option is rejected for build-only actions because they execute no tests.

    Returns the deterministic argument vector without starting a subprocess.
    Raises ``ValueError`` for invalid mode inputs or diagnostic policy values.
    """
    selection_args = parse_test_selection_args(selection_args_text)
    supported_diagnostic_policies = {"on-failure", "never"}
    if (
        collect_test_diagnostics is not None
        and collect_test_diagnostics not in supported_diagnostic_policies
    ):
        raise ValueError(
            "collect_test_diagnostics must be on-failure, never, or omitted."
        )
    if collect_test_diagnostics is not None and action != "test-without-building":
        raise ValueError(
            "collect_test_diagnostics can only be used with test-without-building."
        )
    diagnostic_arguments = (
        ["-collect-test-diagnostics", collect_test_diagnostics]
        if collect_test_diagnostics is not None
        else []
    )
    if xctestrun_path is not None:
        if action != "test-without-building":
            raise ValueError("xctestrun_path can only be used with test-without-building.")
        return [
            "xcodebuild",
            "-xctestrun",
            xctestrun_path,
            "-destination",
            destination,
            "-resultBundlePath",
            result_bundle_path,
            *diagnostic_arguments,
            f"CODE_SIGNING_ALLOWED={code_signing_allowed}",
            *selection_args,
            action,
        ]

    required_project_args = {
        "project": project,
        "scheme": scheme,
        "configuration": configuration,
        "derived_data_path": derived_data_path,
    }
    missing_args = [name for name, value in required_project_args.items() if value is None]
    if missing_args:
        raise ValueError(
            "project, scheme, configuration, and derived_data_path are required "
            "when xctestrun_path is not provided. Missing: "
            + ", ".join(missing_args)
            + "."
        )

    return [
        "xcodebuild",
        "-project",
        project,
        "-scheme",
        scheme,
        "-configuration",
        configuration,
        "-destination",
        destination,
        "-derivedDataPath",
        derived_data_path,
        "-resultBundlePath",
        result_bundle_path,
        *diagnostic_arguments,
        f"CODE_SIGNING_ALLOWED={code_signing_allowed}",
        *selection_args,
        action,
    ]


def create_argument_parser() -> argparse.ArgumentParser:
    """Create the CLI parser."""
    parser = argparse.ArgumentParser(
        description="Run xcodebuild with newline-delimited test selection arguments."
    )
    parser.add_argument("--project")
    parser.add_argument("--scheme")
    parser.add_argument("--configuration")
    parser.add_argument("--destination", required=True)
    parser.add_argument("--derived-data-path")
    parser.add_argument("--result-bundle-path", required=True)
    parser.add_argument("--test-selection-args")
    parser.add_argument("--test-source", nargs="+", type=Path)
    parser.add_argument("--test-target")
    parser.add_argument("--test-case-class")
    parser.add_argument("--code-signing-allowed", default="NO")
    parser.add_argument("--xctestrun-path")
    parser.add_argument(
        "--collect-test-diagnostics",
        choices=("on-failure", "never"),
        help=(
            "Set Xcode's public test-diagnostics policy for this test run. "
            "Omit to preserve Xcode's default on-failure behavior."
        ),
    )
    parser.add_argument(
        "--action",
        required=True,
        choices=("build-for-testing", "test-without-building"),
    )
    return parser


def _read_xcresult_json(result_bundle_path: str, report_name: str) -> Mapping[str, object]:
    """Read one documented xcresult test-results report as JSON."""
    command = [
        "xcrun",
        "xcresulttool",
        "get",
        "test-results",
        report_name,
        "--path",
        result_bundle_path,
        "--compact",
    ]
    completed = subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
    )
    payload = json.loads(completed.stdout)
    if not isinstance(payload, dict):
        raise ResultBundleValidationError(
            f"xcresulttool {report_name} output must be a JSON object."
        )
    return payload


def _normalized_test_component(value: object) -> str:
    """Normalize one xcresult display-name or identifier component."""
    if not isinstance(value, str):
        return ""
    normalized = unquote(value).strip().rstrip("()")
    if normalized.endswith(".xctest"):
        normalized = normalized.removesuffix(".xctest")
    return normalized


def _identifier_from_node_identifier(value: object) -> str | None:
    """Derive target/class/method from a documented xcresult node identifier."""
    normalized = _normalized_test_component(value)
    if not normalized:
        return None
    parsed = urlparse(normalized)
    candidate = parsed.path if parsed.scheme else normalized
    parts = [part for part in candidate.split("/") if part]
    if len(parts) < 3:
        return None
    target, test_class, method = parts[-3:]
    method = _normalized_test_component(method)
    if not method.startswith("test"):
        return None
    return (
        f"{_normalized_test_component(target)}/"
        f"{_normalized_test_component(test_class)}/{method}"
    )


def test_cases_from_xcresult_nodes(
    payload: Mapping[str, object],
) -> tuple[ResultBundleTestCase, ...]:
    """Collect canonical XCTest attempts from documented xcresult test nodes."""
    test_cases: list[ResultBundleTestCase] = []

    def visit(
        node: object,
        *,
        bundle_name: str | None = None,
        suite_names: tuple[str, ...] = (),
    ) -> None:
        if not isinstance(node, dict):
            return
        node_type = node.get("nodeType")
        node_name = _normalized_test_component(node.get("name"))
        current_bundle = bundle_name
        current_suites = suite_names
        if node_type in {"Unit test bundle", "UI test bundle"} and node_name:
            current_bundle = node_name
            current_suites = ()
        elif node_type == "Test Suite" and node_name:
            current_suites = (*suite_names, node_name)

        if node_type == "Test Case":
            identifier = _identifier_from_node_identifier(node.get("nodeIdentifier"))
            if identifier is None:
                identifier = _identifier_from_node_identifier(node.get("nodeIdentifierURL"))
            if identifier is None and current_bundle and node_name.startswith("test"):
                test_class = next(
                    (
                        suite
                        for suite in reversed(current_suites)
                        if suite not in {"All tests", "Selected tests"}
                    ),
                    None,
                )
                if test_class:
                    identifier = f"{current_bundle}/{test_class}/{node_name}"
            if identifier is not None:
                result = node.get("result")
                result_name = result if isinstance(result, str) else "unknown"
                raw_duration = node.get("durationInSeconds")
                duration_seconds = (
                    float(raw_duration)
                    if isinstance(raw_duration, (int, float))
                    and not isinstance(raw_duration, bool)
                    else None
                )
                test_cases.append(
                    ResultBundleTestCase(
                        identifier=identifier,
                        result=result_name,
                        duration_seconds=duration_seconds,
                    )
                )

        children = node.get("children", [])
        if isinstance(children, list):
            for child in children:
                visit(child, bundle_name=current_bundle, suite_names=current_suites)

    root_nodes = payload.get("testNodes", [])
    if isinstance(root_nodes, list):
        for root_node in root_nodes:
            visit(root_node)
    return tuple(test_cases)


def test_results_from_xcresult_nodes(payload: Mapping[str, object]) -> dict[str, tuple[str, ...]]:
    """Collect canonical XCTest identities and results from xcresult test nodes."""
    results: dict[str, list[str]] = {}
    for test_case in test_cases_from_xcresult_nodes(payload):
        results.setdefault(test_case.identifier, []).append(test_case.result)
    return {identifier: tuple(statuses) for identifier, statuses in results.items()}


def result_bundle_reports_passing_tests(
    result_bundle_path: str,
    expected_test_identifiers: Sequence[str],
) -> bool:
    """Validate action status and exact selected-test execution from xcresult."""
    summary = _read_xcresult_json(result_bundle_path, "summary")
    tests_payload = _read_xcresult_json(result_bundle_path, "tests")
    report = ResultBundleTestReport(
        summary=summary,
        test_results=test_results_from_xcresult_nodes(tests_payload),
    )

    validation_errors: list[str] = []
    if report.summary.get("result") != "Passed":
        validation_errors.append(
            f"action result was {report.summary.get('result')!r}, expected 'Passed'"
        )
    if report.summary.get("totalTestCount", 0) <= 0:
        validation_errors.append("action reported no tests")
    if report.summary.get("failedTests", 0) != 0:
        validation_errors.append(
            f"action reported {report.summary.get('failedTests')} failed tests"
        )
    expected = set(expected_test_identifiers)
    reported = set(report.test_results)
    missing = sorted(expected - reported)
    unexpected = sorted(reported - expected)
    if missing:
        validation_errors.append(f"missing requested tests: {', '.join(missing)}")
    if unexpected:
        validation_errors.append(f"unexpected reported tests: {', '.join(unexpected)}")
    for identifier, statuses in sorted(report.test_results.items()):
        if len(statuses) != 1:
            validation_errors.append(
                f"{identifier} reported {len(statuses)} attempts: {', '.join(statuses)}"
            )
        elif statuses[0] not in PASSING_TEST_RESULTS:
            validation_errors.append(f"{identifier} reported {statuses[0]}")

    if validation_errors:
        print("xcresult execution reconciliation failed:", file=sys.stderr)
        for error in validation_errors:
            print(f"- {error}", file=sys.stderr)
        return False
    return True


def main(argv: Sequence[str] | None = None) -> int:
    """Run the selected xcodebuild action."""
    parser = create_argument_parser()
    args = parser.parse_args(argv)
    project_mode_args = (
        ("--project", args.project),
        ("--scheme", args.scheme),
        ("--configuration", args.configuration),
        ("--derived-data-path", args.derived_data_path),
    )
    if args.xctestrun_path is not None:
        if args.action != "test-without-building":
            parser.error("--xctestrun-path can only be used with --action test-without-building")
        forbidden_args = [option for option, value in project_mode_args if value is not None]
        if forbidden_args:
            parser.error(
                "the following arguments cannot be used with --xctestrun-path: "
                + ", ".join(forbidden_args)
            )
    else:
        missing_args = [
            option
            for option, value in project_mode_args
            if value is None
        ]
        if missing_args:
            parser.error(
                "the following arguments are required without --xctestrun-path: "
                + ", ".join(missing_args)
            )
    if args.collect_test_diagnostics is not None and args.action != "test-without-building":
        parser.error(
            "--collect-test-diagnostics can only be used with --action test-without-building"
        )

    selection_args_text = args.test_selection_args
    if selection_args_text is None:
        selection_args_text = os.environ.get("TEST_SELECTION_ARGS", "")
    if bool(args.test_source) != bool(args.test_target and args.test_case_class):
        parser.error(
            "--test-source requires both --test-target and --test-case-class, and vice versa"
        )
    discovered_test_identifiers = (
        discover_ui_test_identifiers_from_files(
            args.test_source,
            test_target=args.test_target,
            test_case_class=args.test_case_class,
        )
        if args.test_source
        else []
    )
    expected_test_identifiers = requested_test_identifiers(
        selection_args_text,
        discovered_test_identifiers,
    )
    if args.test_source and not expected_test_identifiers:
        parser.error("the supplied sources and selection arguments selected no tests")
    developer_dir = selected_ui_test_developer_dir(os.environ)
    if developer_dir:
        os.environ["UITEST_DEVELOPER_DIR"] = developer_dir
        os.environ["DEVELOPER_DIR"] = developer_dir
    needs_fixture_service = (
        args.action == "test-without-building"
        and selection_requests_ui_tests(selection_args_text)
    )
    if needs_fixture_service and developer_dir is None:
        parser.error("UI tests require a selected Xcode developer directory")
    with contextlib.ExitStack() as resources:
        effective_xctestrun_path = args.xctestrun_path
        if needs_fixture_service:
            if effective_xctestrun_path is None:
                effective_xctestrun_path = discover_single_xctestrun_path(args.derived_data_path)
            if effective_xctestrun_path is None or not os.path.exists(effective_xctestrun_path):
                parser.error(
                    "UI tests require one existing .xctestrun product so the fixture service "
                    "directory can be forwarded to the test host"
                )
            try:
                application_product = resolve_ui_test_application_product(
                    effective_xctestrun_path,
                    expected_bundle_identifier=os.environ.get("UITEST_BUNDLE_ID", ""),
                )
                resources.enter_context(
                    ui_test_fixture_service_session(
                        destination=args.destination,
                        environment=os.environ,
                        application_path=application_product.path,
                        install_diagnostic_path=fixture_host_diagnostic_path(
                            args.result_bundle_path
                        ),
                    )
                )
            except (ValueError, FixtureServiceError) as error:
                parser.error(str(error))

        if needs_fixture_service:
            try:
                effective_xctestrun_path = resources.enter_context(
                    temporary_patched_xctestrun_ui_test_environment(
                        effective_xctestrun_path,
                        host_environment=os.environ,
                    )
                )
            except (OSError, ValueError, plistlib.InvalidFileException) as error:
                parser.error(str(error))
        command = build_xcodebuild_command(
            project=args.project,
            scheme=args.scheme,
            configuration=args.configuration,
            destination=args.destination,
            derived_data_path=args.derived_data_path,
            result_bundle_path=args.result_bundle_path,
            code_signing_allowed=args.code_signing_allowed,
            selection_args_text=selection_args_text,
            action=args.action,
            xctestrun_path=effective_xctestrun_path,
            collect_test_diagnostics=args.collect_test_diagnostics,
        )
        print("Running:", shlex.join(command))
        try:
            subprocess.run(command, check=True)
        except subprocess.CalledProcessError as exc:
            if args.action == "test-without-building" and exc.returncode == -signal.SIGSEGV:
                try:
                    if expected_test_identifiers and result_bundle_reports_passing_tests(
                        args.result_bundle_path,
                        expected_test_identifiers,
                    ):
                        print(
                            "xcodebuild terminated with SIGSEGV after the xcresult bundle "
                            "reported every requested test passed; treating this as an "
                            "xcodebuild post-processing crash."
                        )
                        return 0
                except (
                    json.JSONDecodeError,
                    ResultBundleValidationError,
                    subprocess.CalledProcessError,
                ):
                    pass
            raise
        if args.action == "test-without-building" and expected_test_identifiers:
            if not result_bundle_reports_passing_tests(
                args.result_bundle_path,
                expected_test_identifiers,
            ):
                raise ResultBundleValidationError(
                    "xcresult test execution did not exactly match the requested/discovered tests."
                )
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
