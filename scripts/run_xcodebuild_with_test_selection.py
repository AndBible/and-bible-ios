#!/usr/bin/env python3
"""Run xcodebuild with newline-delimited test selection arguments."""

from __future__ import annotations

import argparse
import os
import signal
import shlex
import subprocess
import sys
from typing import Sequence

TIMEOUT_EXIT_CODE = 124
TIMEOUT_TERMINATION_GRACE_SECONDS = 10


def parse_test_selection_args(selection_text: str) -> list[str]:
    """Split newline-delimited xcodebuild selection arguments."""
    return [line.strip() for line in selection_text.splitlines() if line.strip()]


def build_xcodebuild_command(
    *,
    project: str,
    scheme: str,
    configuration: str,
    destination: str,
    derived_data_path: str,
    result_bundle_path: str,
    code_signing_allowed: str,
    selection_args_text: str,
    action: str,
) -> list[str]:
    """Construct the full xcodebuild invocation."""
    selection_args = parse_test_selection_args(selection_args_text)
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


def run_xcodebuild_command(command: Sequence[str], *, timeout_seconds: int | None) -> int:
    """Run xcodebuild while bounding hangs in the spawned XCTest process tree.

    The command inherits stdout and stderr so GitHub Actions receives the normal xcodebuild log
    stream. When a timeout is supplied, xcodebuild runs in its own process group so the timeout path
    can terminate xcodebuild and child XCTest processes together before returning a controlled
    failure code.
    """
    process = subprocess.Popen(list(command), start_new_session=True)
    try:
        return_code = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        print(
            f"xcodebuild timed out after {timeout_seconds}s; terminating process group.",
            file=sys.stderr,
            flush=True,
        )
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=TIMEOUT_TERMINATION_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            print(
                "xcodebuild did not exit after SIGTERM; sending SIGKILL.",
                file=sys.stderr,
                flush=True,
            )
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        return TIMEOUT_EXIT_CODE

    if return_code != 0:
        raise subprocess.CalledProcessError(return_code, list(command))
    return 0


def create_argument_parser() -> argparse.ArgumentParser:
    """Create the CLI parser."""
    parser = argparse.ArgumentParser(
        description="Run xcodebuild with newline-delimited test selection arguments."
    )
    parser.add_argument("--project", required=True)
    parser.add_argument("--scheme", required=True)
    parser.add_argument("--configuration", required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--derived-data-path", required=True)
    parser.add_argument("--result-bundle-path", required=True)
    parser.add_argument("--test-selection-args")
    parser.add_argument("--code-signing-allowed", default="NO")
    parser.add_argument("--timeout-seconds", type=int)
    parser.add_argument(
        "--action",
        required=True,
        choices=("build-for-testing", "test-without-building"),
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Run the selected xcodebuild action."""
    parser = create_argument_parser()
    args = parser.parse_args(argv)
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
    )
    print("Running:", shlex.join(command))
    return run_xcodebuild_command(command, timeout_seconds=args.timeout_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
