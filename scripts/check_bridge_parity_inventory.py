#!/usr/bin/env python3
"""
Validate the bridge parity gap inventory against the checked-in iOS bridge type.

If an Android reference checkout is available, pass its root with --android-root
to also verify that every Android-only method is represented in the inventory.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_INVENTORY = REPO_ROOT / "docs/parity/bridge/baselines/android-bridge-gap-inventory.json"
ALLOWED_MISSING_STATUSES = {"missing_needs_triage"}
ALLOWED_NO_OP_STATUSES = {"ios_no_op_needs_decision"}
REQUIRED_REFERENCE_KEYS = {
    "androidInterfaceRelativePath": str,
    "androidMethodCount": int,
    "iosBundledMethodCount": int,
}


class InventoryError(ValueError):
    """Raised when the bridge parity inventory is inconsistent."""


def parse_bridge_methods(source: str) -> dict[str, str]:
    """Extract method signatures from the BibleJavascriptInterface type."""
    match = re.search(
        r"export\s+type\s+BibleJavascriptInterface\s*=\s*\{(?P<body>.*?)\n\}",
        source,
        flags=re.S,
    )
    if not match:
        raise InventoryError("BibleJavascriptInterface type not found")

    methods: dict[str, str] = {}
    for line in match.group("body").splitlines():
        method_match = re.match(r"\s*([A-Za-z_]\w*)\s*:\s*(.*?)\s*,?$", line)
        if method_match:
            methods[method_match.group(1)] = method_match.group(2)
    return methods


def load_methods(path: Path) -> dict[str, str]:
    """Load a TypeScript bridge interface file and return method signatures."""
    return parse_bridge_methods(path.read_text())


def require_object(value: Any, label: str) -> dict[str, Any]:
    """Return a JSON object value or raise a clear inventory error."""
    if not isinstance(value, dict):
        raise InventoryError(f"{label} must be an object")
    return value


def require_references(inventory: dict[str, Any]) -> dict[str, Any]:
    """Validate the inventory references block and return it."""
    references = require_object(inventory.get("references"), "references")
    for key, expected_type in REQUIRED_REFERENCE_KEYS.items():
        value = references.get(key)
        if not isinstance(value, expected_type):
            type_name = expected_type.__name__
            raise InventoryError(f"references.{key} must be a {type_name}")
    return references


def require_list(inventory: dict[str, Any], key: str) -> list[Any]:
    """Return one required list section from the inventory."""
    value = inventory.get(key)
    if not isinstance(value, list):
        raise InventoryError(f"{key} must be a list")
    return value


def require_unique_methods(entries: list[Any], section: str) -> set[str]:
    """Return method names from one inventory section after duplicate checks."""
    names: list[str] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise InventoryError(f"{section} entry must be an object")
        method = entry.get("method")
        if not isinstance(method, str) or not method:
            raise InventoryError(f"{section} entry is missing a method name")
        names.append(method)

    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise InventoryError(f"{section} contains duplicate methods: {', '.join(duplicates)}")
    return set(names)


def require_allowed_statuses(entries: list[Any], section: str, allowed_statuses: set[str]) -> set[str]:
    """Return unexpected statuses after validating every status value is a string."""
    unexpected_statuses: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise InventoryError(f"{section} entry must be an object")
        status = entry.get("status")
        if not isinstance(status, str) or not status:
            raise InventoryError(f"{section} entry status must be a non-empty string")
        if status not in allowed_statuses:
            unexpected_statuses.add(status)
    return unexpected_statuses


def validate_inventory(
    inventory_path: Path,
    ios_interface_path: Path,
    android_root: Path | None,
) -> list[str]:
    """Validate inventory consistency and return informational messages."""
    inventory = require_object(json.loads(inventory_path.read_text()), "inventory root")
    messages: list[str] = []

    references = require_references(inventory)
    missing_entries = require_list(inventory, "missingAndroidMethods")
    no_op_entries = require_list(inventory, "iosNoOpMethods")

    ios_methods = load_methods(ios_interface_path)
    expected_ios_count = references.get("iosBundledMethodCount")
    if expected_ios_count != len(ios_methods):
        raise InventoryError(
            f"iOS bridge method count drifted: inventory={expected_ios_count}, actual={len(ios_methods)}"
        )

    missing_methods = require_unique_methods(missing_entries, "missingAndroidMethods")
    no_op_methods = require_unique_methods(no_op_entries, "iosNoOpMethods")

    resolved = sorted(missing_methods.intersection(ios_methods))
    if resolved:
        raise InventoryError(
            "methods marked missing now exist in the iOS bundle; update inventory: "
            + ", ".join(resolved)
        )

    missing_no_ops = sorted(no_op_methods.difference(ios_methods))
    if missing_no_ops:
        raise InventoryError(
            "methods marked iOS no-op are absent from the iOS bundle: "
            + ", ".join(missing_no_ops)
        )

    bad_missing_statuses = sorted(
        require_allowed_statuses(
            missing_entries,
            "missingAndroidMethods",
            ALLOWED_MISSING_STATUSES,
        )
    )
    if bad_missing_statuses:
        raise InventoryError(f"unexpected missing-method statuses: {bad_missing_statuses}")

    bad_no_op_statuses = sorted(
        require_allowed_statuses(
            no_op_entries,
            "iosNoOpMethods",
            ALLOWED_NO_OP_STATUSES,
        )
    )
    if bad_no_op_statuses:
        raise InventoryError(f"unexpected no-op statuses: {bad_no_op_statuses}")

    if android_root is not None:
        android_interface_path = android_root / references["androidInterfaceRelativePath"]
        android_methods = load_methods(android_interface_path)
        expected_android_count = references.get("androidMethodCount")
        if expected_android_count != len(android_methods):
            raise InventoryError(
                "Android bridge method count drifted: "
                f"inventory={expected_android_count}, actual={len(android_methods)}"
            )
        no_ops_missing_from_android = sorted(no_op_methods - set(android_methods))
        if no_ops_missing_from_android:
            raise InventoryError(
                "iOS no-op methods are not present in Android: "
                + ", ".join(no_ops_missing_from_android)
            )
        android_only = set(android_methods) - set(ios_methods)
        missing_from_inventory = sorted(android_only - missing_methods)
        stale_inventory = sorted(missing_methods - android_only)
        if missing_from_inventory:
            raise InventoryError(
                "Android-only methods missing from inventory: " + ", ".join(missing_from_inventory)
            )
        if stale_inventory:
            raise InventoryError(
                "inventory methods are no longer Android-only: " + ", ".join(stale_inventory)
            )
        messages.append(f"Android comparison checked: {len(android_only)} tracked Android-only methods")
    else:
        messages.append("Android comparison skipped; pass --android-root to validate against Android")

    messages.append(
        f"iOS bridge inventory checked: {len(ios_methods)} iOS methods, "
        f"{len(missing_methods)} missing Android methods, {len(no_op_methods)} iOS no-op methods"
    )
    return messages


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, default=DEFAULT_INVENTORY)
    parser.add_argument(
        "--ios-interface",
        type=Path,
        default=REPO_ROOT / "bibleview-js/src/composables/android.ts",
    )
    parser.add_argument("--android-root", type=Path)
    args = parser.parse_args()

    try:
        for message in validate_inventory(args.inventory, args.ios_interface, args.android_root):
            print(message)
    except (FileNotFoundError, InventoryError, json.JSONDecodeError) as error:
        print(f"bridge parity inventory check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
