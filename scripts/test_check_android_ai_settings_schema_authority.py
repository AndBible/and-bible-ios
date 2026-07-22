"""Tests for the Android AI settings Room authority drift guard."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_android_ai_settings_schema_authority as guard


class AndroidAISettingsSchemaAuthorityTests(unittest.TestCase):
    """Exercise pinned AI schemas, migrations, runtime sources, and commit provenance."""

    def test_repository_fixtures_match_pinned_commit_digests(self) -> None:
        """Every copied AI schema and migration source retains its pinned bytes."""
        guard.validate_local_fixtures()

    def test_derived_version_12_authority_is_pinned_separately_from_exported_schemas(self) -> None:
        """The Android-derived v12 contract cannot drift or masquerade as a copied Room export."""
        manifest = json.loads(json.dumps(guard.load_manifest()))
        manifest["derivedSchemaAuthority"]["12"]["identityHash"] = "0" * 32

        with self.assertRaisesRegex(
            guard.AuthorityDriftError,
            "derived AI settings schema authority drift",
        ):
            guard.validate_local_fixtures(manifest=manifest)

    def test_version_12_identity_is_independently_derived_from_v11_and_android_sql(self) -> None:
        """Room 2.7.2 identity calculation catches a coordinated wrong v12 constant."""
        version_11_export = json.loads(
            (
                guard.FIXTURE_ROOT
                / "AiSettingsDatabase"
                / "11.json"
            ).read_text(encoding="utf-8")
        )
        migration_sql = json.loads(
            guard.MIGRATION_SQL_PATH.read_text(encoding="utf-8")
        )
        derived_database = guard.derive_version_12_database(
            version_11_export,
            migration_sql["11"],
        )

        self.assertEqual(
            guard.room_272_identity_hash(derived_database),
            "ce84fdcfd2da69ec7a3dbb0a48598c5b",
        )
        agent_prompt = next(
            entity
            for entity in derived_database["entities"]
            if entity["tableName"] == "AgentPrompt"
        )
        auto_include_documents = next(
            field
            for field in agent_prompt["fields"]
            if field["columnName"] == "autoIncludeDocuments"
        )
        auto_include_documents["defaultValue"] = "1"
        self.assertNotEqual(
            guard.room_272_identity_hash(derived_database),
            "ce84fdcfd2da69ec7a3dbb0a48598c5b",
        )

    def test_migration_sql_fixture_must_match_copied_android_source(self) -> None:
        """A self-consistent fixture rewrite still fails when it differs from Android Kotlin SQL."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture_root = Path(temporary_directory) / "AndroidRoomSchemas"
            shutil.copytree(guard.FIXTURE_ROOT, fixture_root)
            manifest = guard.load_manifest(fixture_root / "ai-settings-authority.json")
            migration_sql_path = fixture_root / "AiSettingsMigrationSQL.json"
            migration_sql = json.loads(migration_sql_path.read_text(encoding="utf-8"))
            migration_sql["1"][0] += " INVALID"
            migration_sql_path.write_text(
                json.dumps(migration_sql, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            manifest["migrationSQLSHA256"] = guard.shared.sha256(migration_sql_path)

            with self.assertRaisesRegex(
                guard.AuthorityDriftError,
                "differs from Android source",
            ):
                guard.validate_local_fixtures(fixture_root=fixture_root, manifest=manifest)

    def test_matching_android_checkout_passes_and_schema_drift_fails(self) -> None:
        """An exact authority checkout passes until one generated schema byte changes."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            android_root = Path(temporary_directory)
            manifest = self.make_authority_checkout(android_root)

            guard.validate_android_checkout(android_root, manifest=manifest)

            schema_path = android_root / guard.ANDROID_SCHEMA_RELATIVE_PATH / "23.json"
            schema_path.write_bytes(schema_path.read_bytes() + b"\n")
            with self.assertRaisesRegex(guard.AuthorityDriftError, "schema v23 drift"):
                guard.validate_android_checkout(android_root, manifest=manifest)

    def test_migration_runtime_source_and_head_drift_are_independent_gates(self) -> None:
        """Migration bytes, owning source bytes, and exact repository HEAD each fail closed."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            android_root = Path(temporary_directory)
            manifest = self.make_authority_checkout(android_root)

            migration_path = android_root / guard.ANDROID_MIGRATION_RELATIVE_PATH
            migration_path.write_bytes(migration_path.read_bytes() + b"drift")
            with self.assertRaisesRegex(guard.AuthorityDriftError, "migration source drift"):
                guard.validate_android_checkout(android_root, manifest=manifest)

            shutil.copyfile(guard.FIXTURE_ROOT / "AiSettingsMigrations.kt", migration_path)
            source_relative_path = next(iter(manifest["androidSourceSHA256"]))
            source_path = android_root / source_relative_path
            source_path.write_bytes(source_path.read_bytes() + b"drift")
            with self.assertRaisesRegex(guard.AuthorityDriftError, "authority source drift"):
                guard.validate_android_checkout(android_root, manifest=manifest)

            source_path.write_text(source_relative_path, encoding="utf-8")
            room_version_path = android_root / guard.ANDROID_ROOM_VERSION_RELATIVE_PATH
            room_version_path.write_text(
                'val roomVersion by extra("9.9.9")\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(guard.AuthorityDriftError, "Room compiler version drift"):
                guard.validate_android_checkout(android_root, manifest=manifest)

            room_version_path.write_text(
                'val roomVersion by extra("2.7.2")\n',
                encoding="utf-8",
            )
            (android_root / "unrelated.txt").write_text("new commit", encoding="utf-8")
            subprocess.run(
                ["git", "-C", str(android_root), "add", "."],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            subprocess.run(
                ["git", "-C", str(android_root), "commit", "-q", "-m", "Authority drift"],
                check=True,
            )
            with self.assertRaisesRegex(guard.AuthorityDriftError, "checkout HEAD drift"):
                guard.validate_android_checkout(android_root, manifest=manifest)

    def make_authority_checkout(
        self,
        android_root: Path,
    ) -> dict[str, Any]:
        """Create a hermetic Android authority tree and pin its exact synthetic commit."""
        manifest = json.loads(json.dumps(guard.load_manifest()))
        schema_root = android_root / guard.ANDROID_SCHEMA_RELATIVE_PATH
        schema_root.parent.mkdir(parents=True)
        shutil.copytree(guard.FIXTURE_ROOT / "AiSettingsDatabase", schema_root)

        migration_path = android_root / guard.ANDROID_MIGRATION_RELATIVE_PATH
        utility_path = android_root / guard.ANDROID_UTILITY_RELATIVE_PATH
        migration_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(guard.FIXTURE_ROOT / "AiSettingsMigrations.kt", migration_path)
        shutil.copyfile(guard.FIXTURE_ROOT / "AiSettingsMigrationUtilities.kt", utility_path)

        for relative_path in manifest["androidSourceSHA256"]:
            source_path = android_root / relative_path
            source_path.parent.mkdir(parents=True, exist_ok=True)
            source_path.write_text(relative_path, encoding="utf-8")
            manifest["androidSourceSHA256"][relative_path] = guard.shared.sha256(source_path)
        (android_root / guard.ANDROID_ROOM_VERSION_RELATIVE_PATH).write_text(
            'val roomVersion by extra("2.7.2")\n',
            encoding="utf-8",
        )

        subprocess.run(["git", "init", "-q", str(android_root)], check=True)
        subprocess.run(
            ["git", "-C", str(android_root), "config", "user.email", "test@example.invalid"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(android_root), "config", "user.name", "Authority Test"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(android_root), "add", "."],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(android_root), "commit", "-q", "-m", "Pinned authority"],
            check=True,
        )
        manifest["androidCommit"] = guard.shared.android_head(android_root)
        return manifest


if __name__ == "__main__":
    unittest.main()
