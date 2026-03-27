#!/usr/bin/env python3
"""Resolve a preferred iOS simulator destination for GitHub Actions builds."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path


DEFAULT_PREFERRED_ORDER = [
    "iPhone 17",
    "iPhone 16 Pro",
    "iPhone 16",
    "iPhone 15 Pro",
    "iPhone 15",
]


def parse_candidates(text: str) -> list[tuple[str, str, str]]:
    candidates: list[tuple[str, str, str]] = []
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if "{ platform:iOS Simulator" not in line:
            continue
        if not (line.startswith("{") and line.endswith("}")):
            continue

        parts = [part.strip() for part in line[1:-1].split(",")]
        fields: dict[str, str] = {}
        for part in parts:
            if ":" not in part:
                continue
            key, value = part.split(":", 1)
            fields[key.strip()] = value.strip()

        name = fields.get("name", "")
        simulator_id = fields.get("id", "")
        os_version = fields.get("OS", "")
        platform = fields.get("platform", "")

        if platform != "iOS Simulator":
            continue
        if name == "Any iOS Simulator Device":
            continue
        if simulator_id.startswith("dvtdevice-"):
            continue
        if not name.startswith("iPhone"):
            continue

        candidates.append((name, os_version, simulator_id))

    return candidates


def has_simulator_placeholder(text: str) -> bool:
    return "Any iOS Simulator Device" in text


def choose_candidate(
    candidates: list[tuple[str, str, str]],
    preferred_order: list[str] | None = None,
) -> tuple[str, str, str]:
    if not candidates:
        raise ValueError("No iPhone simulator candidates were found")

    preferred = preferred_order or DEFAULT_PREFERRED_ORDER
    for preferred_name in preferred:
        for candidate in candidates:
            if candidate[0] == preferred_name:
                return candidate
    return candidates[0]


def parse_version(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", value))


def discover_candidates(project: str, scheme: str, retries: int, delay_seconds: float) -> tuple[list[tuple[str, str, str]], str]:
    command = [
        "xcodebuild",
        "-project",
        project,
        "-scheme",
        scheme,
        "-showdestinations",
    ]

    output_text = ""
    candidates: list[tuple[str, str, str]] = []
    for attempt in range(1, retries + 1):
        result = subprocess.run(command, capture_output=True, text=True)
        output_text = f"{result.stdout}\n{result.stderr}"
        candidates = parse_candidates(output_text)
        if result.returncode == 0 and candidates:
            break

        print(f"showdestinations attempt {attempt} failed; retrying")
        print(output_text)
        if attempt < retries:
            time.sleep(delay_seconds)

    return candidates, output_text


def read_simctl_json(*args: str) -> dict[str, object]:
    command = ["xcrun", "simctl", "list", *args, "-j"]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"simctl command failed: {' '.join(command)}\n{result.stdout}\n{result.stderr}")
    return json.loads(result.stdout)


def choose_runtime(runtimes_payload: dict[str, object]) -> dict[str, object] | None:
    runtimes = [
        runtime
        for runtime in runtimes_payload.get("runtimes", [])
        if isinstance(runtime, dict)
        and runtime.get("isAvailable") is True
        and "SimRuntime.iOS-" in str(runtime.get("identifier", ""))
    ]
    if not runtimes:
        return None

    runtimes.sort(
        key=lambda runtime: parse_version(str(runtime.get("version", runtime.get("identifier", "")))),
        reverse=True,
    )
    return runtimes[0]


def choose_device_type(runtime: dict[str, object], preferred_order: list[str] | None = None) -> dict[str, object] | None:
    supported_types = [
        device_type
        for device_type in runtime.get("supportedDeviceTypes", [])
        if isinstance(device_type, dict)
        and device_type.get("productFamily") == "iPhone"
        and str(device_type.get("name", "")).startswith("iPhone")
    ]
    if not supported_types:
        return None

    preferred = preferred_order or DEFAULT_PREFERRED_ORDER
    for preferred_name in preferred:
        for device_type in supported_types:
            if device_type.get("name") == preferred_name:
                return device_type
    return supported_types[0]


def choose_existing_device(
    devices_payload: dict[str, object],
    runtime_identifier: str,
    preferred_order: list[str] | None = None,
) -> dict[str, object] | None:
    devices = [
        device
        for device in devices_payload.get("devices", {}).get(runtime_identifier, [])
        if isinstance(device, dict)
        and device.get("isAvailable") is True
        and str(device.get("name", "")).startswith("iPhone")
    ]
    if not devices:
        return None

    preferred = preferred_order or DEFAULT_PREFERRED_ORDER
    for preferred_name in preferred:
        for device in devices:
            if device.get("name") == preferred_name:
                return device
    return devices[0]


def provision_simulator(
    preferred_order: list[str] | None = None,
    *,
    reuse_existing: bool = True,
    device_name_prefix: str = "AndBible CI",
) -> tuple[str, str, str] | None:
    runtimes_payload = read_simctl_json("runtimes", "available")
    runtime = choose_runtime(runtimes_payload)
    if runtime is None:
        print("No available iOS simulator runtime was found via simctl.")
        return None

    runtime_identifier = str(runtime.get("identifier", ""))
    devices_payload = read_simctl_json("devices", "available")
    if reuse_existing:
        existing_device = choose_existing_device(devices_payload, runtime_identifier, preferred_order)
        if existing_device is not None:
            print(
                "Reusing existing simulator: "
                f"{existing_device.get('name')} ({runtime.get('name', runtime.get('version', 'unknown runtime'))})"
            )
            return (
                str(existing_device.get("udid", "")),
                str(existing_device.get("name", "")),
                str(runtime.get("version", "")),
            )

    device_type = choose_device_type(runtime, preferred_order)
    if device_type is None:
        print("No supported iPhone device type was available for the installed iOS runtime.")
        return None

    device_name = f"{device_name_prefix} {device_type['name']}"
    command = [
        "xcrun",
        "simctl",
        "create",
        device_name,
        str(device_type["identifier"]),
        runtime_identifier,
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        print("Unable to create a concrete iPhone simulator device via simctl.")
        print(result.stdout)
        print(result.stderr)
        return None

    simulator_id = result.stdout.strip()
    print(f"Created simulator: {device_name} ({runtime.get('name', runtime.get('version', 'unknown runtime'))})")
    return (
        simulator_id,
        str(device_type["name"]),
        str(runtime.get("version", "")),
    ) if simulator_id else None


def find_candidate_by_simulator_id(
    candidates: list[tuple[str, str, str]],
    simulator_id: str,
) -> tuple[str, str, str] | None:
    for candidate in candidates:
        if candidate[2] == simulator_id:
            return candidate
    return None


def write_github_output(
    output_path: Path,
    destination: str,
    device_name: str,
    os_version: str,
    *,
    simulator_created: bool,
) -> None:
    simulator_id = destination.removeprefix("id=")
    with output_path.open("a", encoding="utf-8") as file_handle:
        file_handle.write(f"destination={destination}\n")
        file_handle.write(f"simulator_id={simulator_id}\n")
        file_handle.write(f"device_name={device_name}\n")
        file_handle.write(f"os_version={os_version}\n")
        file_handle.write(f"simulator_created={'true' if simulator_created else 'false'}\n")


def print_resolved_output(
    destination: str,
    device_name: str,
    os_version: str,
    *,
    simulator_created: bool,
) -> None:
    simulator_id = destination.removeprefix("id=")
    print(f"destination={destination}")
    print(f"simulator_id={simulator_id}")
    print(f"device_name={device_name}")
    print(f"os_version={os_version}")
    print(f"simulator_created={'true' if simulator_created else 'false'}")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default="AndBible.xcodeproj", help="Xcode project path")
    parser.add_argument("--scheme", default="AndBible", help="Xcode scheme name")
    parser.add_argument("--retries", type=int, default=3, help="Number of xcodebuild retries")
    parser.add_argument("--delay-seconds", type=float, default=2.0, help="Delay between retries")
    parser.add_argument(
        "--create-dedicated-device",
        action="store_true",
        help="Create a fresh simulator device for this run instead of reusing an existing one",
    )
    parser.add_argument(
        "--device-name-prefix",
        default="AndBible CI",
        help="Prefix to use when creating a dedicated simulator device",
    )
    parser.add_argument(
        "--github-output",
        default=os.environ.get("GITHUB_OUTPUT"),
        help="Path to the GitHub Actions output file; defaults to GITHUB_OUTPUT",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    created_simulator: tuple[str, str, str] | None = None

    if args.create_dedicated_device:
        created_simulator = provision_simulator(
            reuse_existing=False,
            device_name_prefix=args.device_name_prefix,
        )
        if created_simulator:
            time.sleep(args.delay_seconds)

    candidates, output_text = discover_candidates(
        project=args.project,
        scheme=args.scheme,
        retries=args.retries,
        delay_seconds=args.delay_seconds,
    )

    if not candidates and has_simulator_placeholder(output_text) and created_simulator is None:
        print("No concrete iPhone simulator destinations were available; attempting to provision one.")
        provisioned = provision_simulator()
        if provisioned:
            time.sleep(args.delay_seconds)
            candidates, output_text = discover_candidates(
                project=args.project,
                scheme=args.scheme,
                retries=args.retries,
                delay_seconds=args.delay_seconds,
            )

    if not candidates:
        print("Unable to discover iPhone simulators from xcodebuild -showdestinations output")
        print(output_text)
        return 1

    selected_candidate = None
    if created_simulator is not None:
        selected_candidate = find_candidate_by_simulator_id(candidates, created_simulator[0])
        if selected_candidate is None:
            print(
                "Created simulator did not appear in xcodebuild -showdestinations output; "
                "using the created simulator directly."
            )
            selected_candidate = created_simulator[1], created_simulator[2], created_simulator[0]

    name, os_version, simulator_id = selected_candidate or choose_candidate(candidates)
    destination = f"id={simulator_id}"

    print(f"Selected simulator: {name} (iOS {os_version})")

    if args.github_output:
        write_github_output(
            Path(args.github_output),
            destination,
            name,
            os_version,
            simulator_created=created_simulator is not None,
        )
    else:
        print_resolved_output(
            destination,
            name,
            os_version,
            simulator_created=created_simulator is not None,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
