#!/usr/bin/env python3
"""Tests for source and processed-product boundary checks."""

from __future__ import annotations

from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_product_boundaries import (
    CALCULATOR,
    EXPECTED_STANDARD_DOCUMENT_TYPES,
    ProductContract,
    STANDARD,
    validate_processed_app,
    validate_source_contract,
)


REPO_ROOT = Path(__file__).resolve().parents[1]


class ProductBoundaryTests(unittest.TestCase):
    """Protect source target ownership and built-product metadata assertions."""

    def write_plist(self, path: Path, value: dict[str, object]) -> None:
        """Write one deterministic binary-independent plist fixture."""
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as stream:
            plistlib.dump(value, stream)

    def make_built_product(
        self,
        root: Path,
        contract: ProductContract,
    ) -> tuple[Path, Path]:
        """Create a minimal processed app and entitlement fixture for one product."""
        app_path = root / f"{contract.display_name}.app"
        info: dict[str, object] = {
            "CFBundleIdentifier": contract.bundle_identifier,
            "CFBundleDisplayName": contract.display_name,
            "AndBibleBuildIdentity": contract.build_identity,
            "AndBibleCloudKitContainerIdentifier": contract.cloudkit_container,
            "BGTaskSchedulerPermittedIdentifiers": [
                f"{contract.bundle_identifier}.remote-sync-refresh"
            ],
        }
        if contract.owns_external_document_types:
            info["CFBundleDocumentTypes"] = [
                {
                    "CFBundleTypeName": name,
                    "LSItemContentTypes": list(content_types),
                }
                for name, content_types in EXPECTED_STANDARD_DOCUMENT_TYPES.items()
            ]
        self.write_plist(app_path / "Info.plist", info)
        entitlements_path = root / f"{contract.name}.xcent"
        self.write_plist(
            entitlements_path,
            {
                "com.apple.developer.icloud-container-identifiers": [
                    contract.cloudkit_container
                ],
                "com.apple.developer.icloud-services": ["CloudKit"],
            },
        )
        return app_path, entitlements_path

    def test_repository_source_contract(self) -> None:
        """Runs the static target/plist/runtime audit against the actual checkout."""
        self.assertEqual(validate_source_contract(REPO_ROOT), [])

    def test_built_standard_and_calculator_contracts_are_separate(self) -> None:
        """Accepts exact processed metadata for each product and distinct CloudKit stores."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            standard_app, standard_entitlements = self.make_built_product(root, STANDARD)
            calculator_app, calculator_entitlements = self.make_built_product(root, CALCULATOR)

            standard_failures = validate_processed_app(
                standard_app,
                standard_entitlements,
                STANDARD,
            )
            calculator_failures = validate_processed_app(
                calculator_app,
                calculator_entitlements,
                CALCULATOR,
            )

        self.assertEqual(standard_failures, [])
        self.assertEqual(calculator_failures, [])
        self.assertNotEqual(STANDARD.cloudkit_container, CALCULATOR.cloudkit_container)

    def test_built_calculator_rejects_external_document_associations(self) -> None:
        """Fails when Calculator advertises SWORD ZIP, EPUB, font, or any document type."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            app_path, entitlements_path = self.make_built_product(root, CALCULATOR)
            info_path = app_path / "Info.plist"
            with info_path.open("rb") as stream:
                info = plistlib.load(stream)
            info["CFBundleDocumentTypes"] = [
                {
                    "CFBundleTypeName": "EPUB Document",
                    "LSItemContentTypes": ["org.idpf.epub-container"],
                }
            ]
            self.write_plist(info_path, info)

            failures = validate_processed_app(app_path, entitlements_path, CALCULATOR)

        self.assertIn(
            "Calculator built product advertises external association key: CFBundleDocumentTypes",
            failures,
        )


if __name__ == "__main__":
    unittest.main()
