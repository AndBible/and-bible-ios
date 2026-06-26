#!/usr/bin/env python3
"""Run xcodebuild with newline-delimited test selection arguments."""

from __future__ import annotations

import argparse
import glob
import json
import os
import plistlib
import signal
import shlex
import subprocess
from collections.abc import Callable
from typing import Mapping, Sequence


def parse_test_selection_args(selection_text: str) -> list[str]:
    """Split newline-delimited xcodebuild selection arguments."""
    return [line.strip() for line in selection_text.splitlines() if line.strip()]


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


def discover_single_xctestrun_path(derived_data_path: str | None) -> str | None:
    """Return the sole .xctestrun file from a derived-data build output, if unambiguous."""
    if derived_data_path is None:
        return None
    products_glob = os.path.join(derived_data_path, "Build", "Products", "*.xctestrun")
    xctestrun_paths = sorted(glob.glob(products_glob))
    if len(xctestrun_paths) != 1:
        return None
    return xctestrun_paths[0]


def patch_xctestrun_ui_test_developer_dir(xctestrun_path: str, developer_dir: str) -> bool:
    """Inject selected Xcode paths into UI-test host environments in an .xctestrun file."""
    with open(xctestrun_path, "rb") as plist_file:
        xctestrun = plistlib.load(plist_file)

    patched = False
    for test_configuration in xctestrun.values():
        if not isinstance(test_configuration, dict):
            continue
        if test_configuration.get("IsUITestBundle") is not True:
            continue
        for environment_key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            environment = test_configuration.setdefault(environment_key, {})
            environment["DEVELOPER_DIR"] = developer_dir
            environment["UITEST_DEVELOPER_DIR"] = developer_dir
            patched = True

    if patched:
        with open(xctestrun_path, "wb") as plist_file:
            plistlib.dump(xctestrun, plist_file)
    return patched


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
) -> list[str]:
    """Construct the full xcodebuild invocation for project or .xctestrun mode."""
    selection_args = parse_test_selection_args(selection_args_text)
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
    parser.add_argument("--code-signing-allowed", default="NO")
    parser.add_argument("--xctestrun-path")
    parser.add_argument(
        "--action",
        required=True,
        choices=("build-for-testing", "test-without-building"),
    )
    return parser


def result_bundle_reports_passing_tests(result_bundle_path: str) -> bool:
    """Return whether an xcresult bundle reports a completed passing test action."""
    summary_command = [
        "xcrun",
        "xcresulttool",
        "get",
        "test-results",
        "summary",
        "--path",
        result_bundle_path,
        "--compact",
    ]
    completed = subprocess.run(
        summary_command,
        check=True,
        capture_output=True,
        text=True,
    )
    summary = json.loads(completed.stdout)
    return (
        summary.get("result") == "Passed"
        and summary.get("totalTestCount", 0) > 0
        and summary.get("failedTests", 0) == 0
    )


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

    selection_args_text = args.test_selection_args
    if selection_args_text is None:
        selection_args_text = os.environ.get("TEST_SELECTION_ARGS", "")
    developer_dir = selected_ui_test_developer_dir(os.environ)
    if developer_dir:
        os.environ["UITEST_DEVELOPER_DIR"] = developer_dir
        os.environ["DEVELOPER_DIR"] = developer_dir
    effective_xctestrun_path = args.xctestrun_path
    if (
        args.action == "test-without-building"
        and developer_dir is not None
        and selection_requests_ui_tests(selection_args_text)
    ):
        if effective_xctestrun_path is None:
            effective_xctestrun_path = discover_single_xctestrun_path(args.derived_data_path)
        if effective_xctestrun_path is not None and os.path.exists(effective_xctestrun_path):
            patch_xctestrun_ui_test_developer_dir(effective_xctestrun_path, developer_dir)
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
    )
    print("Running:", shlex.join(command))
    try:
        subprocess.run(command, check=True)
    except subprocess.CalledProcessError as exc:
        if args.action == "test-without-building" and exc.returncode == -signal.SIGSEGV:
            try:
                if result_bundle_reports_passing_tests(args.result_bundle_path):
                    print(
                        "xcodebuild terminated with SIGSEGV after the xcresult bundle "
                        "reported all selected tests passed; treating this as an "
                        "xcodebuild post-processing crash."
                    )
                    return 0
            except (json.JSONDecodeError, subprocess.CalledProcessError):
                pass
        raise
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
