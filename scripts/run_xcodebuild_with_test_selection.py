#!/usr/bin/env python3
"""Run xcodebuild with newline-delimited test selection arguments."""

from __future__ import annotations

import argparse
import json
import os
import signal
import shlex
import subprocess
from typing import Sequence


def parse_test_selection_args(selection_text: str) -> list[str]:
    """Split newline-delimited xcodebuild selection arguments."""
    return [line.strip() for line in selection_text.splitlines() if line.strip()]


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
            "when xctestrun_path is not provided."
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
    if args.xctestrun_path is not None:
        if args.action != "test-without-building":
            parser.error("--xctestrun-path can only be used with --action test-without-building")
    else:
        missing_args = [
            option
            for option, value in (
                ("--project", args.project),
                ("--scheme", args.scheme),
                ("--configuration", args.configuration),
                ("--derived-data-path", args.derived_data_path),
            )
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
        xctestrun_path=args.xctestrun_path,
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
