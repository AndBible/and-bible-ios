#!/usr/bin/env python3
"""Fixture tests for external distribution-release evidence validation."""

from __future__ import annotations

from copy import deepcopy
from datetime import datetime, timedelta, timezone
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

from validate_distribution_release_readiness import (
    ReleaseArchiveIdentity,
    canonical_directory_sha256,
    is_app_store_distribution_profile,
    release_archive_identity,
    release_binding_payload,
    run_plist_command,
    validate_external_evidence,
)


EXPECTED_COMMIT_SHA = "a" * 40
VALIDATION_TIME = datetime(2026, 7, 20, 12, 0, tzinfo=timezone.utc)


def archive_identities() -> dict[str, ReleaseArchiveIdentity]:
    """Return exact synthetic archive identities shared by evidence-binding tests."""
    return {
        "standard": ReleaseArchiveIdentity(
            sha256="1" * 64,
            version="1.2.3",
            build="123",
            created_at=VALIDATION_TIME - timedelta(hours=2),
        ),
        "calculator": ReleaseArchiveIdentity(
            sha256="2" * 64,
            version="1.2.3",
            build="123",
            created_at=VALIDATION_TIME - timedelta(hours=1),
        ),
    }


def complete_evidence() -> dict[str, object]:
    """Return complete synthetic evidence bound to the current commit and archive identities."""
    evidence = release_binding_payload(EXPECTED_COMMIT_SHA, archive_identities())
    evidence["release_binding"]["validated_at"] = "2026-07-20T12:00:00Z"
    evidence.update({
        "developer_portal": {
            "standard": {
                "app_id_identifier": "org.andbible.ios",
                "app_id_record_id": "APPID-STANDARD",
                "provisioning_profile_uuid": "PROFILE-STANDARD",
                "cloudkit_container_identifier": "iCloud.org.andbible.ios",
                "app_id_container_association_verified": True,
                "evidence_id": "portal-standard.pdf",
            },
            "calculator": {
                "app_id_identifier": "com.app.calculator.ios",
                "app_id_record_id": "APPID-CALCULATOR",
                "provisioning_profile_uuid": "PROFILE-CALCULATOR",
                "cloudkit_container_identifier": "iCloud.com.app.calculator.ios",
                "app_id_container_association_verified": True,
                "evidence_id": "portal-calculator.pdf",
            },
        },
        "cloudkit": {
            "iCloud.org.andbible.ios": {
                "development_schema_deployed": True,
                "production_schema_deployed": True,
                "evidence_id": "cloudkit-standard.pdf",
            },
            "iCloud.com.app.calculator.ios": {
                "development_schema_deployed": True,
                "production_schema_deployed": True,
                "evidence_id": "cloudkit-calculator.pdf",
            },
        },
        "app_store_connect": {
            "standard": {
                "bundle_identifier": "org.andbible.ios",
                "app_record_id": "ASC-STANDARD",
                "evidence_id": "asc-standard.pdf",
            },
            "calculator": {
                "bundle_identifier": "com.app.calculator.ios",
                "app_record_id": "ASC-CALCULATOR",
                "evidence_id": "asc-calculator.pdf",
            },
        },
        "device_validation": {
            key: {"passed": True, "evidence_id": f"device-{key}.xcresult"}
            for key in (
                "both_products_coinstalled",
                "standard_cloudkit_round_trip",
                "calculator_cloudkit_round_trip",
                "cross_product_store_isolation",
            )
        },
    })
    return evidence


class DistributionReleaseReadinessTests(unittest.TestCase):
    """Ensures missing external facts cannot be represented as release-ready."""

    def test_complete_external_evidence_passes_shape_validation(self) -> None:
        """Accepts exact archive, commit, portal, schema, and fresh device evidence bindings."""
        self.assertEqual(
            validate_external_evidence(
                complete_evidence(),
                expected_commit_sha=EXPECTED_COMMIT_SHA,
                archive_identities=archive_identities(),
                now=VALIDATION_TIME,
            ),
            [],
        )

    def test_missing_profile_and_failed_isolation_block_readiness(self) -> None:
        """Rejects absent provisioning evidence and a failed cross-product isolation check."""
        evidence = deepcopy(complete_evidence())
        evidence["developer_portal"]["calculator"]["provisioning_profile_uuid"] = ""
        evidence["device_validation"]["cross_product_store_isolation"]["passed"] = False

        failures = validate_external_evidence(
            evidence,
            expected_commit_sha=EXPECTED_COMMIT_SHA,
            archive_identities=archive_identities(),
            now=VALIDATION_TIME,
        )

        self.assertIn(
            "developer_portal.calculator.provisioning_profile_uuid is required",
            failures,
        )
        self.assertIn(
            "device_validation.cross_product_store_isolation.passed must be true",
            failures,
        )

    def test_evidence_rejects_commit_archive_and_version_drift(self) -> None:
        """Evidence from another workflow commit or either different archive must block release."""
        evidence = complete_evidence()
        evidence["release_binding"]["commit_sha"] = "b" * 40
        evidence["release_binding"]["archives"]["standard"]["sha256"] = "3" * 64
        evidence["release_binding"]["archives"]["calculator"]["build"] = "122"

        failures = validate_external_evidence(
            evidence,
            expected_commit_sha=EXPECTED_COMMIT_SHA,
            archive_identities=archive_identities(),
            now=VALIDATION_TIME,
        )

        self.assertIn(
            f"release_binding.commit_sha must equal {EXPECTED_COMMIT_SHA}",
            failures,
        )
        self.assertIn(
            f"release_binding.archives.standard.sha256 must equal {'1' * 64}",
            failures,
        )
        self.assertIn(
            "release_binding.archives.calculator.build must equal 123",
            failures,
        )

    def test_evidence_rejects_stale_or_pre_archive_device_validation(self) -> None:
        """Physical-device proof must be recent and must postdate both exact archive builds."""
        stale = complete_evidence()
        stale["release_binding"]["validated_at"] = "2026-07-01T12:00:00Z"
        stale_failures = validate_external_evidence(
            stale,
            expected_commit_sha=EXPECTED_COMMIT_SHA,
            archive_identities=archive_identities(),
            now=VALIDATION_TIME,
        )
        self.assertTrue(any("is stale" in failure for failure in stale_failures))
        self.assertTrue(any("predates the archives" in failure for failure in stale_failures))

        future = complete_evidence()
        future["release_binding"]["validated_at"] = "2026-07-20T12:06:00Z"
        future_failures = validate_external_evidence(
            future,
            expected_commit_sha=EXPECTED_COMMIT_SHA,
            archive_identities=archive_identities(),
            now=VALIDATION_TIME,
        )
        self.assertIn(
            "release_binding.validated_at must not be in the future",
            future_failures,
        )

    def test_archive_identity_hashes_tree_and_reads_processed_versions(self) -> None:
        """Binding generation covers archive bytes plus Xcode and application release metadata."""
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "AndBible.xcarchive"
            app = archive / "Products" / "Applications" / "AndBible.app"
            app.mkdir(parents=True)
            with (archive / "Info.plist").open("wb") as handle:
                plistlib.dump({"CreationDate": VALIDATION_TIME}, handle)
            with (app / "Info.plist").open("wb") as handle:
                plistlib.dump(
                    {"CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "123"},
                    handle,
                )
            (app / "payload.bin").write_bytes(b"first")

            first = release_archive_identity(archive)
            (app / "payload.bin").write_bytes(b"second")
            second_hash = canonical_directory_sha256(archive)

        self.assertEqual(first.version, "1.2.3")
        self.assertEqual(first.build, "123")
        self.assertEqual(first.created_at, VALIDATION_TIME)
        self.assertNotEqual(first.sha256, second_hash)

    def test_archive_hash_survives_tar_handoff_with_symlinks_and_modes(self) -> None:
        """Tar transport must preserve the exact candidate tree used by physical validation.

        The fixture includes an executable and a relative symlink, matching the archive structures
        that direct artifact-directory upload can rewrite. A hash mismatch means validation could
        reject its own prepared candidate or silently measure a different tree.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source_parent = root / "source"
            source = source_parent / "AndBible.xcarchive"
            binary = source / "Products" / "Applications" / "AndBible.app" / "AndBible"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"signed-binary")
            binary.chmod(0o755)
            (binary.parent / "Current").symlink_to("AndBible")
            expected_hash = canonical_directory_sha256(source)
            tar_path = root / "AndBible.xcarchive.tar"
            restored_parent = root / "restored"
            restored_parent.mkdir()

            subprocess.run(
                ["tar", "-C", str(source_parent), "-cpf", str(tar_path), source.name],
                check=True,
            )
            subprocess.run(
                ["tar", "-C", str(restored_parent), "-xpf", str(tar_path)],
                check=True,
            )

            restored = restored_parent / source.name
            actual_hash = canonical_directory_sha256(restored)
            restored_symlink = (
                restored / "Products" / "Applications" / "AndBible.app" / "Current"
            ).is_symlink()

        self.assertEqual(actual_hash, expected_hash)
        self.assertTrue(restored_symlink)

    def test_signing_plist_can_be_emitted_on_stderr(self) -> None:
        """Accepts the output stream used by `codesign --display` on Apple hosts."""
        payload = {"application-identifier": "TEAM.org.andbible.ios"}
        completed = subprocess.CompletedProcess(
            args=["codesign"],
            returncode=0,
            stdout=b"",
            stderr=b"Executable=/tmp/AndBible.app\n" + plistlib.dumps(payload),
        )

        with patch(
            "validate_distribution_release_readiness.subprocess.run",
            return_value=completed,
        ):
            self.assertEqual(run_plist_command(["codesign"]), payload)

    def test_only_app_store_distribution_profile_kind_is_accepted(self) -> None:
        """Rejects device-limited Ad Hoc/development and all-device enterprise profiles."""
        self.assertTrue(is_app_store_distribution_profile({"UUID": "APP-STORE"}))
        self.assertFalse(
            is_app_store_distribution_profile(
                {"UUID": "AD-HOC", "ProvisionedDevices": ["DEVICE-UDID"]}
            )
        )
        self.assertFalse(
            is_app_store_distribution_profile(
                {"UUID": "ENTERPRISE", "ProvisionsAllDevices": True}
            )
        )


if __name__ == "__main__":
    unittest.main()
