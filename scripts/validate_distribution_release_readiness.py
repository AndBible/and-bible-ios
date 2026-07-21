#!/usr/bin/env python3
"""Fail distribution readiness unless signed archives and Apple-side evidence are complete."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys

from check_product_boundaries import (
    CALCULATOR,
    EXTERNAL_ASSOCIATION_KEYS,
    STANDARD,
    ProductContract,
    document_type_contract,
    EXPECTED_STANDARD_DOCUMENT_TYPES,
    load_plist,
)


EVIDENCE_SCHEMA_VERSION = 2
DEFAULT_EVIDENCE_MAX_AGE_HOURS = 168
EVIDENCE_CLOCK_SKEW = timedelta(minutes=5)
COMMIT_SHA_PATTERN = re.compile(r"[0-9a-f]{40}")


@dataclass(frozen=True)
class ReleaseArchiveIdentity:
    """Binds external validation to one exact Xcode archive tree.

    Inputs are derived from an archive's bytes and processed metadata. Instances are immutable,
    deterministic for an unchanged archive, and perform no I/O after construction. Missing archive
    metadata is rejected by ``release_archive_identity`` rather than represented with placeholders.
    """

    sha256: str
    version: str
    build: str
    created_at: datetime


def canonical_directory_sha256(root: Path) -> str:
    """Return a stable SHA-256 over every path and payload in a directory tree.

    The input must be an existing directory. Relative directory names, regular-file bytes, and
    symlink targets, and permission modes are framed into one digest; timestamps and host-specific
    ownership are excluded so a tar-restored ``.xcarchive`` retains the same identity. The operation is read-only and
    raises ``ValueError`` for missing roots or unsupported filesystem entries.
    """
    if not root.is_dir():
        raise ValueError(f"archive directory does not exist: {root}")
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        if path.is_symlink():
            kind = b"L"
            payload = path.readlink().as_posix().encode("utf-8")
        elif path.is_dir():
            kind = b"D"
            payload = b""
        elif path.is_file():
            kind = b"F"
            payload = path.read_bytes()
        else:
            raise ValueError(f"archive contains unsupported filesystem entry: {path}")
        mode = stat.S_IMODE(path.lstat().st_mode)
        digest.update(kind)
        digest.update(mode.to_bytes(4, "big"))
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def normalized_utc_timestamp(value: datetime) -> str:
    """Render one timezone-aware timestamp in canonical UTC evidence form.

    The input is converted without side effects and emitted with second precision plus a trailing
    ``Z``. Naive values are rejected because their actual instant is ambiguous.
    """
    if value.tzinfo is None:
        raise ValueError("release timestamp must include a timezone")
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_utc_timestamp(value: object, label: str) -> datetime:
    """Parse a required ISO-8601 evidence timestamp and normalize it to UTC.

    ``value`` must be a non-empty string with an explicit timezone. Parsing is deterministic and has
    no side effects. Invalid or timezone-free values raise ``ValueError`` naming the evidence field.
    """
    if not nonempty_string(value):
        raise ValueError(f"{label} is required")
    text = str(value).strip()
    try:
        parsed = datetime.fromisoformat(text.removesuffix("Z") + ("+00:00" if text.endswith("Z") else ""))
    except ValueError as exc:
        raise ValueError(f"{label} must be an ISO-8601 timestamp") from exc
    if parsed.tzinfo is None:
        raise ValueError(f"{label} must include a timezone")
    return parsed.astimezone(timezone.utc)


def release_archive_identity(archive: Path) -> ReleaseArchiveIdentity:
    """Derive the immutable hash, version, build, and creation time for one archive.

    The archive and its single application Info.plist are read without mutation. Xcode's archive
    ``CreationDate`` and both app version fields are mandatory so evidence cannot bind only to a
    filename. Missing or malformed metadata raises ``ValueError`` or ``plistlib.InvalidFileException``.
    """
    app = archive_app_path(archive)
    app_info = load_plist(app / "Info.plist")
    archive_info = load_plist(archive / "Info.plist")
    version = app_info.get("CFBundleShortVersionString")
    build = app_info.get("CFBundleVersion")
    created_at = archive_info.get("CreationDate")
    if not nonempty_string(version):
        raise ValueError(f"archive has no CFBundleShortVersionString: {archive}")
    if not nonempty_string(build):
        raise ValueError(f"archive has no CFBundleVersion: {archive}")
    if not isinstance(created_at, datetime):
        raise ValueError(f"archive has no CreationDate: {archive}")
    if created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=timezone.utc)
    return ReleaseArchiveIdentity(
        sha256=canonical_directory_sha256(archive),
        version=str(version).strip(),
        build=str(build).strip(),
        created_at=created_at.astimezone(timezone.utc),
    )


def release_binding_payload(
    expected_commit_sha: str,
    archive_identities: dict[str, ReleaseArchiveIdentity],
) -> dict[str, object]:
    """Create the machine-readable binding block operators attach to release evidence.

    The commit SHA and both ``standard`` and ``calculator`` identities are required. The result is
    deterministic and leaves ``validated_at`` empty because physical-device validation must happen
    after archive creation. No files are written; invalid commit or missing products raise
    ``ValueError``.
    """
    if COMMIT_SHA_PATTERN.fullmatch(expected_commit_sha) is None:
        raise ValueError("expected commit SHA must be 40 lowercase hexadecimal characters")
    missing = sorted({"standard", "calculator"} - archive_identities.keys())
    if missing:
        raise ValueError(f"archive identities missing products: {', '.join(missing)}")
    return {
        "schema_version": EVIDENCE_SCHEMA_VERSION,
        "release_binding": {
            "commit_sha": expected_commit_sha,
            "validated_at": "",
            "archives": {
                sku: {
                    "sha256": identity.sha256,
                    "version": identity.version,
                    "build": identity.build,
                    "created_at": normalized_utc_timestamp(identity.created_at),
                }
                for sku, identity in sorted(archive_identities.items())
            },
        },
    }


def nonempty_string(value: object) -> bool:
    """Return whether an external evidence field is a non-empty string."""
    return isinstance(value, str) and bool(value.strip())


def is_app_store_distribution_profile(profile: dict[str, object]) -> bool:
    """Return whether a provisioning profile excludes device and enterprise distribution."""
    return "ProvisionedDevices" not in profile and profile.get("ProvisionsAllDevices") is not True


def validate_external_evidence(
    payload: object,
    *,
    expected_commit_sha: str,
    archive_identities: dict[str, ReleaseArchiveIdentity],
    now: datetime | None = None,
    max_age: timedelta = timedelta(hours=DEFAULT_EVIDENCE_MAX_AGE_HOURS),
) -> list[str]:
    """Validate Apple-side evidence and its binding to the current archives.

    The payload must use schema v2 and identify the workflow commit, exact standard and Calculator
    archive trees, processed versions/builds, archive creation times, and a fresh post-build device
    validation timestamp. Portal, CloudKit, App Store Connect, and device proof remain mandatory.
    Validation is read-only and deterministic when ``now`` is supplied; malformed fields accumulate
    human-readable failures instead of raising.
    """
    failures: list[str] = []
    if not isinstance(payload, dict):
        return ["release evidence root must be an object"]
    if payload.get("schema_version") != EVIDENCE_SCHEMA_VERSION:
        failures.append(
            f"release evidence schema_version must equal {EVIDENCE_SCHEMA_VERSION}"
        )

    release_binding = payload.get("release_binding")
    if not isinstance(release_binding, dict):
        failures.append("release evidence missing release_binding object")
        release_binding = {}
    if release_binding.get("commit_sha") != expected_commit_sha:
        failures.append(f"release_binding.commit_sha must equal {expected_commit_sha}")
    archives = release_binding.get("archives")
    if not isinstance(archives, dict):
        failures.append("release_binding.archives must be an object")
        archives = {}
    for sku in ("standard", "calculator"):
        expected_identity = archive_identities.get(sku)
        if expected_identity is None:
            failures.append(f"validator missing {sku} archive identity")
            continue
        archive = archives.get(sku)
        if not isinstance(archive, dict):
            failures.append(f"release_binding.archives.{sku} must be an object")
            archive = {}
        expected_fields = {
            "sha256": expected_identity.sha256,
            "version": expected_identity.version,
            "build": expected_identity.build,
            "created_at": normalized_utc_timestamp(expected_identity.created_at),
        }
        for key, expected in expected_fields.items():
            if archive.get(key) != expected:
                failures.append(
                    f"release_binding.archives.{sku}.{key} must equal {expected}"
                )

    current_time = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    try:
        validated_at = parse_utc_timestamp(
            release_binding.get("validated_at"),
            "release_binding.validated_at",
        )
    except ValueError as exc:
        failures.append(str(exc))
    else:
        if validated_at > current_time + EVIDENCE_CLOCK_SKEW:
            failures.append("release_binding.validated_at must not be in the future")
        if current_time - validated_at > max_age:
            failures.append(
                "release_binding.validated_at is stale; physical-device evidence must be "
                f"newer than {int(max_age.total_seconds() // 3600)} hours"
            )
        latest_archive = max(
            (identity.created_at for identity in archive_identities.values()),
            default=None,
        )
        if latest_archive is not None and validated_at + EVIDENCE_CLOCK_SKEW < latest_archive:
            failures.append(
                "release_binding.validated_at predates the archives; device evidence must exercise "
                "these exact builds"
            )

    developer_portal = payload.get("developer_portal")
    if not isinstance(developer_portal, dict):
        failures.append("release evidence missing developer_portal object")
        developer_portal = {}
    app_store_connect = payload.get("app_store_connect")
    if not isinstance(app_store_connect, dict):
        failures.append("release evidence missing app_store_connect object")
        app_store_connect = {}

    for sku, contract in (("standard", STANDARD), ("calculator", CALCULATOR)):
        portal = developer_portal.get(sku)
        if not isinstance(portal, dict):
            failures.append(f"developer_portal.{sku} must be an object")
            portal = {}
        expected_portal = {
            "app_id_identifier": contract.bundle_identifier,
            "cloudkit_container_identifier": contract.cloudkit_container,
        }
        for key, expected in expected_portal.items():
            if portal.get(key) != expected:
                failures.append(f"developer_portal.{sku}.{key} must equal {expected}")
        for key in ("app_id_record_id", "provisioning_profile_uuid", "evidence_id"):
            if not nonempty_string(portal.get(key)):
                failures.append(f"developer_portal.{sku}.{key} is required")
        if portal.get("app_id_container_association_verified") is not True:
            failures.append(
                f"developer_portal.{sku}.app_id_container_association_verified must be true"
            )

        app_store = app_store_connect.get(sku)
        if not isinstance(app_store, dict):
            failures.append(f"app_store_connect.{sku} must be an object")
            app_store = {}
        if app_store.get("bundle_identifier") != contract.bundle_identifier:
            failures.append(
                f"app_store_connect.{sku}.bundle_identifier must equal "
                f"{contract.bundle_identifier}"
            )
        for key in ("app_record_id", "evidence_id"):
            if not nonempty_string(app_store.get(key)):
                failures.append(f"app_store_connect.{sku}.{key} is required")

    cloudkit = payload.get("cloudkit")
    if not isinstance(cloudkit, dict):
        failures.append("release evidence missing cloudkit object")
        cloudkit = {}
    for contract in (STANDARD, CALCULATOR):
        container = cloudkit.get(contract.cloudkit_container)
        if not isinstance(container, dict):
            failures.append(f"cloudkit.{contract.cloudkit_container} must be an object")
            container = {}
        for key in ("development_schema_deployed", "production_schema_deployed"):
            if container.get(key) is not True:
                failures.append(f"cloudkit.{contract.cloudkit_container}.{key} must be true")
        if not nonempty_string(container.get("evidence_id")):
            failures.append(f"cloudkit.{contract.cloudkit_container}.evidence_id is required")

    device_validation = payload.get("device_validation")
    if not isinstance(device_validation, dict):
        failures.append("release evidence missing device_validation object")
        device_validation = {}
    for key in (
        "both_products_coinstalled",
        "standard_cloudkit_round_trip",
        "calculator_cloudkit_round_trip",
        "cross_product_store_isolation",
    ):
        result = device_validation.get(key)
        if not isinstance(result, dict):
            failures.append(f"device_validation.{key} must be an object")
            result = {}
        if result.get("passed") is not True:
            failures.append(f"device_validation.{key}.passed must be true")
        if not nonempty_string(result.get("evidence_id")):
            failures.append(f"device_validation.{key}.evidence_id is required")

    return failures


def run_plist_command(arguments: list[str]) -> dict[str, object]:
    """Run an Apple signing command and decode the plist embedded in its output."""
    result = subprocess.run(arguments, check=False, capture_output=True)
    if result.returncode != 0:
        diagnostic = (result.stderr or result.stdout).decode("utf-8", errors="replace")
        raise ValueError(f"command failed ({' '.join(arguments)}): {diagnostic.strip()}")
    parse_errors: list[str] = []
    for stream_name, output in (("stdout", result.stdout), ("stderr", result.stderr)):
        xml_offset = output.find(b"<?xml")
        binary_offset = output.find(b"bplist")
        offsets = [offset for offset in (xml_offset, binary_offset) if offset >= 0]
        if not offsets:
            continue
        try:
            value = plistlib.loads(output[min(offsets) :])
        except plistlib.InvalidFileException as exc:
            parse_errors.append(f"{stream_name}: {exc}")
            continue
        if not isinstance(value, dict):
            raise ValueError(
                f"command plist root is not a dictionary: {' '.join(arguments)}"
            )
        return value
    detail = f" ({'; '.join(parse_errors)})" if parse_errors else ""
    raise ValueError(f"command did not emit a valid plist{detail}: {' '.join(arguments)}")


def archive_app_path(archive: Path) -> Path:
    """Resolve the single application bundle inside one Xcode archive."""
    applications = sorted((archive / "Products" / "Applications").glob("*.app"))
    if len(applications) != 1:
        raise ValueError(f"archive must contain exactly one app: {archive}")
    return applications[0]


def validate_signed_archive(
    archive: Path,
    contract: ProductContract,
    sku: str,
    team_identifier: str,
    evidence: dict[str, object],
) -> list[str]:
    """Verify processed metadata, signature, embedded profile, App ID, and CloudKit entitlement."""
    failures: list[str] = []
    try:
        app = archive_app_path(archive)
        info = load_plist(app / "Info.plist")
    except (OSError, ValueError, plistlib.InvalidFileException) as exc:
        return [f"{sku} archive invalid: {exc}"]

    expected_info = {
        "CFBundleIdentifier": contract.bundle_identifier,
        "CFBundleDisplayName": contract.display_name,
        "AndBibleBuildIdentity": contract.build_identity,
        "AndBibleCloudKitContainerIdentifier": contract.cloudkit_container,
    }
    for key, expected in expected_info.items():
        if info.get(key) != expected:
            failures.append(f"{sku} archive {key} mismatch")
    if sku == "standard":
        if document_type_contract(info) != EXPECTED_STANDARD_DOCUMENT_TYPES:
            failures.append("standard archive document associations are incomplete")
    else:
        for key in EXTERNAL_ASSOCIATION_KEYS:
            if key in info:
                failures.append(
                    f"Calculator archive advertises external association key: {key}"
                )

    verify = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
        check=False,
        capture_output=True,
        text=True,
    )
    if verify.returncode != 0:
        failures.append(f"{sku} archive signature verification failed: {verify.stderr.strip()}")
        return failures

    signature = subprocess.run(
        ["/usr/bin/codesign", "--display", "--verbose=4", str(app)],
        check=False,
        capture_output=True,
        text=True,
    )
    signature_text = signature.stdout + signature.stderr
    if signature.returncode != 0 or f"TeamIdentifier={team_identifier}" not in signature_text:
        failures.append(f"{sku} archive signature team identifier mismatch")
    if "Signature=adhoc" in signature_text:
        failures.append(f"{sku} archive is ad-hoc signed")
    if not any(
        authority in signature_text
        for authority in ("Authority=Apple Distribution:", "Authority=iPhone Distribution:")
    ):
        failures.append(f"{sku} archive is not signed by an Apple distribution certificate")

    try:
        signed_entitlements = run_plist_command(
            ["/usr/bin/codesign", "--display", "--entitlements", ":-", str(app)]
        )
    except ValueError as exc:
        failures.append(f"{sku} signed entitlements unavailable: {exc}")
        return failures
    expected_application_identifier = f"{team_identifier}.{contract.bundle_identifier}"
    if signed_entitlements.get("application-identifier") != expected_application_identifier:
        failures.append(f"{sku} signed application-identifier mismatch")
    if signed_entitlements.get("com.apple.developer.icloud-container-identifiers") != [
        contract.cloudkit_container
    ]:
        failures.append(f"{sku} signed CloudKit container mismatch")

    profile_path = app / "embedded.mobileprovision"
    if not profile_path.is_file():
        failures.append(f"{sku} archive has no embedded.mobileprovision")
        return failures
    try:
        profile = run_plist_command(
            ["/usr/bin/security", "cms", "-D", "-i", str(profile_path)]
        )
    except ValueError as exc:
        failures.append(f"{sku} embedded profile cannot be decoded: {exc}")
        return failures

    portal = evidence["developer_portal"][sku]
    if profile.get("UUID") != portal.get("provisioning_profile_uuid"):
        failures.append(f"{sku} embedded profile UUID does not match release evidence")
    if team_identifier not in profile.get("TeamIdentifier", []):
        failures.append(f"{sku} embedded profile team identifier mismatch")
    if not is_app_store_distribution_profile(profile):
        failures.append(f"{sku} embedded profile is not an App Store distribution profile")
    expiration = profile.get("ExpirationDate")
    if isinstance(expiration, datetime) and expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    if not isinstance(expiration, datetime) or expiration <= datetime.now(timezone.utc):
        failures.append(f"{sku} embedded profile is expired or missing expiration")
    profile_entitlements = profile.get("Entitlements", {})
    if profile_entitlements.get("application-identifier") != expected_application_identifier:
        failures.append(f"{sku} profile application-identifier mismatch")
    if profile_entitlements.get("com.apple.developer.icloud-container-identifiers") != [
        contract.cloudkit_container
    ]:
        failures.append(f"{sku} profile CloudKit container mismatch")
    if profile_entitlements.get("get-task-allow") is True:
        failures.append(f"{sku} archive uses a development provisioning profile")

    return failures


def main() -> int:
    """Write an archive binding or validate signed archives against completed evidence.

    Both modes read the standard and Calculator archives and derive their canonical identities.
    ``--write-binding`` writes a post-build template without claiming device validation; normal mode
    validates the supplied evidence, signatures, profiles, and product metadata. Invalid inputs print
    deterministic failures and return 1 without modifying either archive.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--standard-archive", type=Path, required=True)
    parser.add_argument("--calculator-archive", type=Path, required=True)
    parser.add_argument("--expected-commit-sha", required=True)
    parser.add_argument("--team-identifier")
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--write-binding", type=Path)
    parser.add_argument(
        "--max-evidence-age-hours",
        type=int,
        default=DEFAULT_EVIDENCE_MAX_AGE_HOURS,
    )
    args = parser.parse_args()

    failures: list[str] = []
    for label, path in (
        ("standard archive", args.standard_archive),
        ("Calculator archive", args.calculator_archive),
    ):
        if not path.exists():
            failures.append(f"missing required {label}: {path}")
    if COMMIT_SHA_PATTERN.fullmatch(args.expected_commit_sha) is None:
        failures.append("expected commit SHA must be 40 lowercase hexadecimal characters")
    if args.max_evidence_age_hours <= 0:
        failures.append("max evidence age must be greater than zero hours")
    if args.write_binding is None:
        if args.evidence is None or not args.evidence.exists():
            failures.append(f"missing required release evidence: {args.evidence}")
        if not nonempty_string(args.team_identifier):
            failures.append("team identifier must not be empty")
    if failures:
        for failure in failures:
            print(f"- {failure}")
        return 1

    try:
        archive_identities = {
            "standard": release_archive_identity(args.standard_archive),
            "calculator": release_archive_identity(args.calculator_archive),
        }
    except (OSError, ValueError, plistlib.InvalidFileException) as exc:
        print(f"- release archive identity cannot be derived: {exc}")
        return 1

    if args.write_binding is not None:
        payload = release_binding_payload(args.expected_commit_sha, archive_identities)
        try:
            args.write_binding.parent.mkdir(parents=True, exist_ok=True)
            args.write_binding.write_text(
                json.dumps(payload, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
        except OSError as exc:
            print(f"- release binding cannot be written: {exc}")
            return 1
        print(f"Release archive binding written: {args.write_binding}")
        return 0

    try:
        assert args.evidence is not None
        evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"- release evidence cannot be read: {exc}")
        return 1
    failures.extend(
        validate_external_evidence(
            evidence,
            expected_commit_sha=args.expected_commit_sha,
            archive_identities=archive_identities,
            max_age=timedelta(hours=args.max_evidence_age_hours),
        )
    )
    if not failures:
        assert args.team_identifier is not None
        failures.extend(
            validate_signed_archive(
                args.standard_archive,
                STANDARD,
                "standard",
                args.team_identifier,
                evidence,
            )
        )
        failures.extend(
            validate_signed_archive(
                args.calculator_archive,
                CALCULATOR,
                "calculator",
                args.team_identifier,
                evidence,
            )
        )

    print("Distribution release-readiness summary")
    print(f"- signed archives supplied: 2")
    print(f"- external evidence contract: {'FAIL' if failures else 'PASS'}")
    if failures:
        print("FAILURES:")
        for failure in failures:
            print(f"- {failure}")
        return 1
    print("Release readiness passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
