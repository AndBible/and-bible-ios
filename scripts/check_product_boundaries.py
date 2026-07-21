#!/usr/bin/env python3
"""Validate product identity, document ownership, and CloudKit boundaries."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import plistlib
import sys


EXTERNAL_ASSOCIATION_KEYS = {
    "CFBundleDocumentTypes",
    "CFBundleURLTypes",
    "UTExportedTypeDeclarations",
    "UTImportedTypeDeclarations",
}
EXPECTED_STANDARD_DOCUMENT_TYPES = {
    "SWORD Module ZIP": ("public.zip-archive",),
    "EPUB Document": ("org.idpf.epub-container",),
    "TrueType Font": ("public.truetype-ttf-font",),
}


@dataclass(frozen=True)
class ProductContract:
    """Expected processed metadata for one independently installed product."""

    name: str
    bundle_identifier: str
    display_name: str
    build_identity: str
    cloudkit_container: str
    owns_external_document_types: bool


STANDARD = ProductContract(
    name="standard",
    bundle_identifier="org.andbible.ios",
    display_name="AndBible",
    build_identity="standard",
    cloudkit_container="iCloud.org.andbible.ios",
    owns_external_document_types=True,
)
CALCULATOR = ProductContract(
    name="Calculator",
    bundle_identifier="com.app.calculator.ios",
    display_name="Calculator",
    build_identity="discrete",
    cloudkit_container="iCloud.com.app.calculator.ios",
    owns_external_document_types=False,
)


def load_plist(path: Path) -> dict[str, object]:
    """Load one XML or binary property list and require a dictionary root."""
    with path.open("rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        raise ValueError(f"plist root is not a dictionary: {path}")
    return value


def document_type_contract(info: dict[str, object]) -> dict[str, tuple[str, ...]]:
    """Normalize declared document types into names and content-type tuples."""
    result: dict[str, tuple[str, ...]] = {}
    raw_types = info.get("CFBundleDocumentTypes", [])
    if not isinstance(raw_types, list):
        raise ValueError("CFBundleDocumentTypes must be an array")
    for raw_type in raw_types:
        if not isinstance(raw_type, dict):
            raise ValueError("CFBundleDocumentTypes entries must be dictionaries")
        name = raw_type.get("CFBundleTypeName")
        content_types = raw_type.get("LSItemContentTypes")
        if not isinstance(name, str) or not isinstance(content_types, list):
            raise ValueError("document type requires a name and LSItemContentTypes array")
        if not all(isinstance(value, str) for value in content_types):
            raise ValueError(f"document type has a non-string content type: {name}")
        result[name] = tuple(content_types)
    return result


def validate_entitlements(
    path: Path,
    contract: ProductContract,
) -> list[str]:
    """Check one source or processed entitlement plist against its product contract."""
    failures: list[str] = []
    entitlements = load_plist(path)
    actual_containers = entitlements.get("com.apple.developer.icloud-container-identifiers")
    if actual_containers != [contract.cloudkit_container]:
        failures.append(
            f"{contract.name} entitlement container mismatch: {actual_containers!r}"
        )
    if entitlements.get("com.apple.developer.icloud-services") != ["CloudKit"]:
        failures.append(f"{contract.name} entitlement must enable only CloudKit iCloud service")
    return failures


def validate_source_contract(repo_root: Path) -> list[str]:
    """Audit target-owned source metadata and the single runtime CloudKit contract."""
    failures: list[str] = []
    app_root = repo_root / "AndBible"
    standard_info = load_plist(app_root / "Info.plist")
    calculator_info = load_plist(app_root / "Info-Discrete.plist")

    standard_without_documents = dict(standard_info)
    standard_without_documents.pop("CFBundleDocumentTypes", None)
    if calculator_info != standard_without_documents:
        differing_keys = sorted(
            key
            for key in set(calculator_info) | set(standard_without_documents)
            if calculator_info.get(key) != standard_without_documents.get(key)
        )
        failures.append(
            "product plist sibling-key drift outside document ownership: "
            + ", ".join(differing_keys)
        )

    if document_type_contract(standard_info) != EXPECTED_STANDARD_DOCUMENT_TYPES:
        failures.append("standard plist document types do not match SWORD ZIP/EPUB/font contract")
    for key in EXTERNAL_ASSOCIATION_KEYS:
        if key in calculator_info:
            failures.append(f"Calculator plist advertises external association key: {key}")

    for info_name, info in (("standard", standard_info), ("Calculator", calculator_info)):
        if info.get("AndBibleCloudKitContainerIdentifier") != (
            "$(ANDBIBLE_CLOUDKIT_CONTAINER_IDENTIFIER)"
        ):
            failures.append(f"{info_name} plist does not consume target CloudKit build setting")
        if info.get("BGTaskSchedulerPermittedIdentifiers") != [
            "$(PRODUCT_BUNDLE_IDENTIFIER).remote-sync-refresh"
        ]:
            failures.append(f"{info_name} plist leaks a sibling background-task identifier")

    failures.extend(validate_entitlements(app_root / "AndBible.entitlements", STANDARD))
    failures.extend(
        validate_entitlements(app_root / "AndBibleDiscrete.entitlements", CALCULATOR)
    )

    project = (repo_root / "AndBible.xcodeproj" / "project.pbxproj").read_text(
        encoding="utf-8"
    )
    expected_project_lines = {
        "ANDBIBLE_CLOUDKIT_CONTAINER_IDENTIFIER = iCloud.org.andbible.ios;": 2,
        "ANDBIBLE_CLOUDKIT_CONTAINER_IDENTIFIER = iCloud.com.app.calculator.ios;": 2,
        "INFOPLIST_FILE = AndBible/Info.plist;": 2,
        'INFOPLIST_FILE = "AndBible/Info-Discrete.plist";': 2,
        "CODE_SIGN_ENTITLEMENTS = AndBible/AndBible.entitlements;": 2,
        "CODE_SIGN_ENTITLEMENTS = AndBible/AndBibleDiscrete.entitlements;": 2,
    }
    for line, expected_count in expected_project_lines.items():
        actual_count = project.count(line)
        if actual_count != expected_count:
            failures.append(
                f"project setting count mismatch for {line!r}: "
                f"expected={expected_count}, actual={actual_count}"
            )

    for relative_path in (
        "AndBible/AndBibleApp.swift",
        "Sources/BibleCore/Sources/BibleCore/Services/SyncService.swift",
    ):
        source = (repo_root / relative_path).read_text(encoding="utf-8")
        for container in (STANDARD.cloudkit_container, CALCULATOR.cloudkit_container):
            if container in source:
                failures.append(
                    f"runtime source duplicates product CloudKit container: {relative_path}"
                )

    app_source = (repo_root / "AndBible/AndBibleApp.swift").read_text(encoding="utf-8")
    sync_source = (
        repo_root / "Sources/BibleCore/Sources/BibleCore/Services/SyncService.swift"
    ).read_text(encoding="utf-8")
    expected_runtime_fragments = {
        "app resolves the build-owned CloudKit contract": (
            app_source,
            "ProductCloudKitContainerIdentifier.required(",
        ),
        "SwiftData consumes the typed product CloudKit contract": (
            app_source,
            "cloudKitDatabase: .private(cloudKitContainerIdentifier.value)",
        ),
        "SyncService consumes the same injected contract": (
            sync_source,
            "CKContainer(identifier: cloudKitContainerIdentifier.value)",
        ),
    }
    for description, (source, fragment) in expected_runtime_fragments.items():
        if fragment not in source:
            failures.append(f"runtime CloudKit contract missing: {description}")

    if "D15C09000000000000000112 /* BibleUI in Frameworks */" not in project:
        failures.append("Calculator target no longer links BibleUI in-app import implementation")
    for relative_path in (
        "Sources/BibleUI/Sources/BibleUI/Settings/ImportExportView.swift",
        "Sources/BibleUI/Sources/BibleUI/Shared/ExternalDocumentImportService.swift",
    ):
        if not (repo_root / relative_path).is_file():
            failures.append(f"in-app import implementation missing: {relative_path}")

    return failures


def validate_processed_app(
    app_path: Path,
    entitlements_path: Path,
    contract: ProductContract,
) -> list[str]:
    """Validate one built app's processed Info.plist and generated entitlements."""
    failures: list[str] = []
    info = load_plist(app_path / "Info.plist")
    expected_values = {
        "CFBundleIdentifier": contract.bundle_identifier,
        "CFBundleDisplayName": contract.display_name,
        "AndBibleBuildIdentity": contract.build_identity,
        "AndBibleCloudKitContainerIdentifier": contract.cloudkit_container,
    }
    for key, expected in expected_values.items():
        actual = info.get(key)
        if actual != expected:
            failures.append(
                f"{contract.name} processed {key} mismatch: expected={expected!r}, actual={actual!r}"
            )
    expected_task = f"{contract.bundle_identifier}.remote-sync-refresh"
    if info.get("BGTaskSchedulerPermittedIdentifiers") != [expected_task]:
        failures.append(f"{contract.name} processed background-task identifier mismatch")

    if contract.owns_external_document_types:
        if document_type_contract(info) != EXPECTED_STANDARD_DOCUMENT_TYPES:
            failures.append("standard built product lost required document associations")
    else:
        for key in EXTERNAL_ASSOCIATION_KEYS:
            if key in info:
                failures.append(f"Calculator built product advertises external association key: {key}")

    failures.extend(validate_entitlements(entitlements_path, contract))
    return failures


def main() -> int:
    """Run source checks and, when supplied, require both built-product contracts."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--standard-app", type=Path)
    parser.add_argument("--calculator-app", type=Path)
    parser.add_argument("--standard-entitlements", type=Path)
    parser.add_argument("--calculator-entitlements", type=Path)
    args = parser.parse_args()

    failures = validate_source_contract(args.repo_root)
    built_arguments = (
        args.standard_app,
        args.calculator_app,
        args.standard_entitlements,
        args.calculator_entitlements,
    )
    if any(built_arguments) and not all(built_arguments):
        failures.append("built-product validation requires both apps and both entitlement plists")
    elif all(built_arguments):
        failures.extend(
            validate_processed_app(args.standard_app, args.standard_entitlements, STANDARD)
        )
        failures.extend(
            validate_processed_app(args.calculator_app, args.calculator_entitlements, CALCULATOR)
        )

    print("Product-boundary summary")
    print(f"- source contract: {'FAIL' if failures else 'PASS'}")
    print(f"- built products checked: {2 if all(built_arguments) else 0}")
    if failures:
        print("FAILURES:")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("Product boundaries passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
