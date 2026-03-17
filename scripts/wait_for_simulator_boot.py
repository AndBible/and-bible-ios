#!/usr/bin/env python3
"""Boot an iOS simulator and fail fast with diagnostics if boot never completes."""

from __future__ import annotations

import argparse
import subprocess
import sys


def list_available_devices() -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available"],
        capture_output=True,
        text=True,
    )


def dump_diagnostics() -> None:
    diagnostic_commands = [
        ["xcrun", "simctl", "list", "devices", "available"],
        ["xcrun", "simctl", "list", "runtimes", "available"],
    ]
    for command in diagnostic_commands:
        print(f"Diagnostic command: {' '.join(command)}")
        result = subprocess.run(command, capture_output=True, text=True)
        if result.stdout:
            print(result.stdout)
        if result.stderr:
            print(result.stderr)


def simulator_is_booted(simulator_id: str) -> bool:
    result = list_available_devices()
    if result.stdout:
        for line in result.stdout.splitlines():
            if simulator_id in line and "(Booted)" in line:
                return True
    return False


def wait_for_boot(simulator_id: str, timeout_seconds: int) -> int:
    command = ["xcrun", "simctl", "bootstatus", simulator_id, "-b"]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        if simulator_is_booted(simulator_id):
            print(
                "simctl bootstatus timed out, but the selected simulator is already reported as "
                f"Booted: {simulator_id}"
            )
            return 0
        print(f"Simulator {simulator_id} did not finish booting within {timeout_seconds} seconds.")
        dump_diagnostics()
        return 1

    if result.stdout:
        print(result.stdout)
    if result.stderr:
        print(result.stderr)

    if result.returncode != 0:
        if simulator_is_booted(simulator_id):
            print(
                "simctl bootstatus returned a non-zero status, but the selected simulator is "
                f"already reported as Booted: {simulator_id}"
            )
            return 0
        print(f"simctl bootstatus exited with status {result.returncode}")
        dump_diagnostics()
        return result.returncode

    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--simulator-id", required=True, help="Simulator UDID")
    parser.add_argument("--timeout-seconds", type=int, default=300, help="Boot wait timeout")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    return wait_for_boot(args.simulator_id, args.timeout_seconds)


if __name__ == "__main__":
    sys.exit(main())
