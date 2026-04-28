#!/usr/bin/env python3
"""
Unit tests for bridge parity inventory validation.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_bridge_parity_inventory import InventoryError, validate_inventory


class BridgeParityInventoryTests(unittest.TestCase):
    """Covers drift detection for tracked Android bridge gaps."""

    def write_ios_interface(self, root: Path, body: str = "    implemented: () => void,\n") -> Path:
        """Write a minimal iOS bridge interface fixture."""
        ios_interface = root / "ios.ts"
        ios_interface.write_text("export type BibleJavascriptInterface = {\n" + body + "}\n")
        return ios_interface

    def write_inventory(
        self,
        root: Path,
        *,
        ios_count: int = 1,
        android_count: int = 1,
        missing_methods: list[object] | None = None,
        no_op_methods: list[object] | None = None,
    ) -> Path:
        """Write a minimal inventory fixture."""
        inventory = root / "inventory.json"
        inventory.write_text(
            json.dumps(
                {
                    "references": {
                        "iosBundledMethodCount": ios_count,
                        "androidMethodCount": android_count,
                        "androidInterfaceRelativePath": "android.ts",
                    },
                    "missingAndroidMethods": missing_methods or [],
                    "iosNoOpMethods": no_op_methods or [],
                }
            )
        )
        return inventory

    def test_validate_inventory_accepts_missing_and_no_op_methods(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ios_interface = self.write_ios_interface(
                root,
                "    implemented: () => void,\n"
                "    noOp: () => void,\n",
            )
            inventory = root / "inventory.json"
            inventory.write_text(
                json.dumps(
                    {
                        "references": {
                            "iosBundledMethodCount": 2,
                            "androidMethodCount": 3,
                            "androidInterfaceRelativePath": "android.ts",
                        },
                        "missingAndroidMethods": [
                            {"method": "missing", "status": "missing_needs_triage"}
                        ],
                        "iosNoOpMethods": [
                            {"method": "noOp", "status": "ios_no_op_needs_decision"}
                        ],
                    }
                )
            )
            android_root = root / "android"
            android_root.mkdir()
            (android_root / "android.ts").write_text(
                "export type BibleJavascriptInterface = {\n"
                "    implemented: () => void,\n"
                "    noOp: () => void,\n"
                "    missing: () => void,\n"
                "}\n"
            )

            messages = validate_inventory(inventory, ios_interface, android_root)

        self.assertTrue(any("1 tracked Android-only methods" in message for message in messages))

    def test_validate_inventory_fails_when_missing_method_is_added_to_ios(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ios_interface = self.write_ios_interface(root, "    missing: () => void,\n")
            inventory = root / "inventory.json"
            inventory.write_text(
                json.dumps(
                    {
                        "references": {
                            "iosBundledMethodCount": 1,
                            "androidMethodCount": 1,
                            "androidInterfaceRelativePath": "android.ts",
                        },
                        "missingAndroidMethods": [
                            {"method": "missing", "status": "missing_needs_triage"}
                        ],
                        "iosNoOpMethods": [],
                    }
                )
            )

            with self.assertRaisesRegex(InventoryError, "marked missing now exist"):
                validate_inventory(inventory, ios_interface, None)

    def test_validate_inventory_rejects_non_object_root(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ios_interface = self.write_ios_interface(root)
            inventory = root / "inventory.json"
            inventory.write_text(json.dumps([]))

            with self.assertRaisesRegex(InventoryError, "inventory root must be an object"):
                validate_inventory(inventory, ios_interface, None)

    def test_validate_inventory_rejects_non_object_references(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ios_interface = self.write_ios_interface(root)
            inventory = root / "inventory.json"
            inventory.write_text(
                json.dumps(
                    {
                        "references": [],
                        "missingAndroidMethods": [],
                        "iosNoOpMethods": [],
                    }
                )
            )

            with self.assertRaisesRegex(InventoryError, "references must be an object"):
                validate_inventory(inventory, ios_interface, None)

    def test_validate_inventory_requires_android_reference_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ios_interface = self.write_ios_interface(root)
            inventory = root / "inventory.json"
            inventory.write_text(
                json.dumps(
                    {
                        "references": {
                            "iosBundledMethodCount": 1,
                            "androidMethodCount": 1,
                        },
                        "missingAndroidMethods": [],
                        "iosNoOpMethods": [],
                    }
                )
            )

            with self.assertRaisesRegex(
                InventoryError,
                "references.androidInterfaceRelativePath must be a str",
            ):
                validate_inventory(inventory, ios_interface, root)

    def test_validate_inventory_rejects_non_object_section_entry(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ios_interface = self.write_ios_interface(root)
            inventory = self.write_inventory(root, missing_methods=["missing"])

            with self.assertRaisesRegex(
                InventoryError,
                "missingAndroidMethods entry must be an object",
            ):
                validate_inventory(inventory, ios_interface, None)

    def test_validate_inventory_rejects_non_string_missing_method_status(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ios_interface = self.write_ios_interface(root)
            inventory = self.write_inventory(
                root,
                missing_methods=[
                    {"method": "missing", "status": ["missing_needs_triage"]},
                ],
            )

            with self.assertRaisesRegex(
                InventoryError,
                "missingAndroidMethods entry status must be a non-empty string",
            ):
                validate_inventory(inventory, ios_interface, None)

    def test_validate_inventory_rejects_non_string_no_op_status(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ios_interface = self.write_ios_interface(
                root,
                "    implemented: () => void,\n"
                "    noOp: () => void,\n",
            )
            inventory = self.write_inventory(
                root,
                ios_count=2,
                no_op_methods=[
                    {"method": "noOp", "status": {"value": "ios_no_op_needs_decision"}},
                ],
            )

            with self.assertRaisesRegex(
                InventoryError,
                "iosNoOpMethods entry status must be a non-empty string",
            ):
                validate_inventory(inventory, ios_interface, None)

    def test_validate_inventory_requires_no_op_methods_to_exist_in_android(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            ios_interface = self.write_ios_interface(
                root,
                "    implemented: () => void,\n"
                "    noOp: () => void,\n",
            )
            inventory = self.write_inventory(
                root,
                ios_count=2,
                android_count=1,
                no_op_methods=[
                    {"method": "noOp", "status": "ios_no_op_needs_decision"},
                ],
            )
            android_root = root / "android"
            android_root.mkdir()
            (android_root / "android.ts").write_text(
                "export type BibleJavascriptInterface = {\n"
                "    implemented: () => void,\n"
                "}\n"
            )

            with self.assertRaisesRegex(
                InventoryError,
                "iOS no-op methods are not present in Android: noOp",
            ):
                validate_inventory(inventory, ios_interface, android_root)


if __name__ == "__main__":
    unittest.main()
