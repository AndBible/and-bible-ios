"""Tests for the Android Workspace and Progress Room authority drift guard."""

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

import check_android_workspace_schema_authority as guard


class AndroidWorkspaceSchemaAuthorityTests(unittest.TestCase):
    """Exercise pinned schemas, trigger sources, and live-checkout drift detection."""

    def test_repository_fixtures_match_pinned_commit_digests(self) -> None:
        """Every checked-in workspace schema and migration source retains its pinned bytes."""
        guard.validate_local_fixtures()

    def test_matching_android_checkout_passes_and_one_byte_drift_fails(self) -> None:
        """An exact reconstructed authority commit passes until one generated schema byte changes."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            android_root = Path(temporary_directory)
            manifest = self.make_authority_checkout(android_root)

            guard.validate_android_checkout(android_root, manifest=manifest)

            schema_root = android_root / guard.ANDROID_SCHEMA_RELATIVE_PATH
            current_path = schema_root / f"{manifest['currentVersion']}.json"
            current_export = json.loads(current_path.read_text(encoding="utf-8"))
            current_export["database"]["identityHash"] = "drift"
            current_path.write_text(json.dumps(current_export), encoding="utf-8")
            with self.assertRaisesRegex(guard.AuthorityDriftError, "schema v24 drift"):
                guard.validate_android_checkout(android_root, manifest=manifest)

    def test_progress_runtime_source_and_exact_head_drift_are_rejected(self) -> None:
        """Progress schema, runtime-trigger sources, and repository HEAD are independent gates."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            android_root = Path(temporary_directory)
            manifest = self.make_authority_checkout(android_root)

            progress_path = android_root / guard.ANDROID_PROGRESS_SCHEMA_RELATIVE_PATH
            progress_path.write_bytes(progress_path.read_bytes() + b"\n")
            with self.assertRaisesRegex(guard.AuthorityDriftError, "ProgressDatabase v9"):
                guard.validate_android_checkout(android_root, manifest=manifest)

            progress_path.write_bytes(
                (guard.FIXTURE_ROOT / "ProgressDatabase-v9.json").read_bytes()
            )
            source_relative_path = next(iter(manifest["androidSourceSHA256"]))
            source_path = android_root / source_relative_path
            source_path.write_bytes(source_path.read_bytes() + b"drift")
            with self.assertRaisesRegex(guard.AuthorityDriftError, "authority source drift"):
                guard.validate_android_checkout(android_root, manifest=manifest)

            source_path.write_text(source_relative_path, encoding="utf-8")
            (android_root / "unrelated.txt").write_text("new commit", encoding="utf-8")
            subprocess.run(
                ["git", "-C", str(android_root), "add", "."],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            subprocess.run(
                ["git", "-C", str(android_root), "commit", "-m", "Authority drift"],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            with self.assertRaisesRegex(guard.AuthorityDriftError, "checkout HEAD drift"):
                guard.validate_android_checkout(android_root, manifest=manifest)

    def test_non_git_authority_directory_is_rejected(self) -> None:
        """Matching bytes cannot substitute for the pinned Android repository commit."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            android_root = Path(temporary_directory)
            manifest = self.make_authority_checkout(android_root, initialize_git=False)
            with self.assertRaisesRegex(guard.AuthorityDriftError, "checkout HEAD drift"):
                guard.validate_android_checkout(android_root, manifest=manifest)

    def make_authority_checkout(
        self,
        android_root: Path,
        initialize_git: bool = True,
    ) -> dict[str, Any]:
        """Create a hermetic Android authority tree and return hashes pinned to its exact commit."""
        manifest = json.loads(json.dumps(guard.load_manifest()))
        schema_root = android_root / guard.ANDROID_SCHEMA_RELATIVE_PATH
        schema_root.parent.mkdir(parents=True)
        shutil.copytree(guard.FIXTURE_ROOT / "WorkspaceDatabase", schema_root)

        migration_path = android_root / guard.ANDROID_MIGRATION_RELATIVE_PATH
        utility_path = android_root / guard.ANDROID_UTILITY_RELATIVE_PATH
        migration_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(guard.FIXTURE_ROOT / "WorkspaceMigrations.kt", migration_path)
        shutil.copyfile(guard.FIXTURE_ROOT / "WorkspaceMigrationUtilities.kt", utility_path)

        progress_path = android_root / guard.ANDROID_PROGRESS_SCHEMA_RELATIVE_PATH
        progress_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(guard.FIXTURE_ROOT / "ProgressDatabase-v9.json", progress_path)

        for relative_path in manifest["androidSourceSHA256"]:
            source_path = android_root / relative_path
            source_path.parent.mkdir(parents=True, exist_ok=True)
            source_path.write_text(relative_path, encoding="utf-8")
            manifest["androidSourceSHA256"][relative_path] = guard.sha256(source_path)

        if not initialize_git:
            return manifest
        subprocess.run(
            ["git", "init", "-q", str(android_root)],
            check=True,
        )
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
        manifest["androidCommit"] = guard.android_head(android_root)
        return manifest


if __name__ == "__main__":
    unittest.main()
