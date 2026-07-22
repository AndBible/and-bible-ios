#!/usr/bin/env python3
"""Verify Workspace and Progress Room authority against one exact Android commit."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_ROOT = (
    REPOSITORY_ROOT
    / "Sources"
    / "BibleCore"
    / "Tests"
    / "Fixtures"
    / "AndroidRoomSchemas"
)
MANIFEST_PATH = FIXTURE_ROOT / "workspace-authority.json"
ANDROID_SCHEMA_RELATIVE_PATH = Path(
    "app/schemas/net.bible.android.database.WorkspaceDatabase"
)
ANDROID_PROGRESS_SCHEMA_RELATIVE_PATH = Path(
    "app/schemas/net.bible.android.database.progress.ProgressDatabase/9.json"
)
ANDROID_MIGRATION_RELATIVE_PATH = Path(
    "app/src/main/java/net/bible/android/database/migrations/WorkspacesMigrations.kt"
)
ANDROID_UTILITY_RELATIVE_PATH = Path(
    "app/src/main/java/net/bible/android/database/migrations/Utilities.kt"
)
REQUIRED_ANDROID_SOURCE_RELATIVE_PATHS = {
    "app/src/main/java/net/bible/android/database/progress/ProgressDatabase.kt",
    "app/src/main/java/net/bible/android/database/progress/ProgressEntities.kt",
    "app/src/main/java/net/bible/service/cloudsync/SyncUtilities.kt",
    "app/src/main/java/net/bible/service/db/DatabaseContainer.kt",
}


class AuthorityDriftError(RuntimeError):
    """Raised when local evidence or the Android checkout differs from pinned authority."""


def is_lower_hex(value: object, length: int) -> bool:
    """Return whether one manifest value is exact-length lowercase hexadecimal text."""
    return (
        isinstance(value, str)
        and len(value) == length
        and all(character in "0123456789abcdef" for character in value)
    )


def sha256(path: Path) -> str:
    """Return one file's lowercase SHA-256 digest."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_manifest(path: Path = MANIFEST_PATH) -> dict[str, Any]:
    """Load the pinned Workspace, Progress, and runtime-trigger authority manifest."""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuthorityDriftError(f"invalid authority manifest {path}: {error}") from error
    if not isinstance(value, dict):
        raise AuthorityDriftError(f"authority manifest must be an object: {path}")
    return value


def exported_versions(schema_root: Path) -> set[int]:
    """Return numeric Room export versions, rejecting unrelated JSON filenames."""
    versions: set[int] = set()
    for path in schema_root.glob("*.json"):
        try:
            versions.add(int(path.stem))
        except ValueError as error:
            raise AuthorityDriftError(f"unexpected schema export filename: {path.name}") from error
    return versions


def validate_local_fixtures(
    fixture_root: Path = FIXTURE_ROOT,
    manifest: dict[str, Any] | None = None,
) -> None:
    """Require every local Workspace and Progress fixture to match pinned authority."""
    manifest = manifest or load_manifest(fixture_root / "workspace-authority.json")
    if not is_lower_hex(manifest.get("androidCommit"), 40):
        raise AuthorityDriftError("androidCommit must be a lowercase 40-character commit")
    schema_hashes = manifest.get("schemaSHA256")
    if not isinstance(schema_hashes, dict) or not schema_hashes:
        raise AuthorityDriftError("schemaSHA256 must be a nonempty object")
    expected_versions = {int(version) for version in schema_hashes}
    schema_root = fixture_root / "WorkspaceDatabase"
    actual_versions = exported_versions(schema_root)
    if actual_versions != expected_versions:
        raise AuthorityDriftError(
            "local workspace export set drift: "
            f"expected {sorted(expected_versions)}, actual {sorted(actual_versions)}"
        )
    for version_text, expected_digest in schema_hashes.items():
        path = schema_root / f"{version_text}.json"
        actual_digest = sha256(path)
        if actual_digest != expected_digest:
            raise AuthorityDriftError(
                f"local workspace schema v{version_text} digest drift: {actual_digest}"
            )

    migration_path = fixture_root / "WorkspaceMigrations.kt"
    utility_path = fixture_root / "WorkspaceMigrationUtilities.kt"
    if sha256(migration_path) != manifest.get("migrationSHA256"):
        raise AuthorityDriftError("local WorkspaceMigrations.kt digest drift")
    if sha256(utility_path) != manifest.get("utilitySHA256"):
        raise AuthorityDriftError("local migration Utilities.kt digest drift")

    current_version = manifest.get("currentVersion")
    current_fixture = fixture_root / f"WorkspaceDatabase-v{current_version}.json"
    nested_fixture = schema_root / f"{current_version}.json"
    if current_fixture.read_bytes() != nested_fixture.read_bytes():
        raise AuthorityDriftError("current workspace schema fixture differs from predecessor set")
    current_export = json.loads(current_fixture.read_text(encoding="utf-8"))
    database = current_export.get("database", {})
    if database.get("version") != current_version:
        raise AuthorityDriftError("current workspace fixture version drift")
    if database.get("identityHash") != manifest.get("currentIdentityHash"):
        raise AuthorityDriftError("current workspace fixture identity drift")

    progress = manifest.get("progress")
    if not isinstance(progress, dict):
        raise AuthorityDriftError("progress authority must be an object")
    progress_fixture = fixture_root / "ProgressDatabase-v9.json"
    if sha256(progress_fixture) != progress.get("schemaSHA256"):
        raise AuthorityDriftError("local ProgressDatabase v9 digest drift")
    progress_export = json.loads(progress_fixture.read_text(encoding="utf-8"))
    progress_database = progress_export.get("database", {})
    if progress_database.get("version") != progress.get("version"):
        raise AuthorityDriftError("current progress fixture version drift")
    if progress_database.get("identityHash") != progress.get("identityHash"):
        raise AuthorityDriftError("current progress fixture identity drift")

    source_hashes = manifest.get("androidSourceSHA256")
    if not isinstance(source_hashes, dict) or not source_hashes:
        raise AuthorityDriftError("androidSourceSHA256 must be a nonempty object")
    if set(source_hashes) != REQUIRED_ANDROID_SOURCE_RELATIVE_PATHS:
        raise AuthorityDriftError(
            "androidSourceSHA256 paths drift: "
            f"expected {sorted(REQUIRED_ANDROID_SOURCE_RELATIVE_PATHS)}, "
            f"actual {sorted(source_hashes)}"
        )
    for relative_path, expected_digest in source_hashes.items():
        if not is_lower_hex(expected_digest, 64):
            raise AuthorityDriftError(
                f"androidSourceSHA256 digest must be lowercase SHA-256: {relative_path}"
            )


def validate_android_checkout(
    android_root: Path,
    fixture_root: Path = FIXTURE_ROOT,
    manifest: dict[str, Any] | None = None,
) -> None:
    """Require exact Android commit, workspace exports, progress export, and sync sources."""
    manifest = manifest or load_manifest(fixture_root / "workspace-authority.json")
    validate_local_fixtures(fixture_root, manifest)
    live_head = android_head(android_root)
    if live_head != manifest.get("androidCommit"):
        raise AuthorityDriftError(
            "Android checkout HEAD drift: "
            f"expected {manifest.get('androidCommit')}, actual {live_head}"
        )
    android_schema_root = android_root / ANDROID_SCHEMA_RELATIVE_PATH
    expected_versions = {int(version) for version in manifest["schemaSHA256"]}
    actual_versions = exported_versions(android_schema_root)
    if actual_versions != expected_versions:
        raise AuthorityDriftError(
            "Android workspace export set drift: "
            f"expected {sorted(expected_versions)}, actual {sorted(actual_versions)}"
        )
    local_schema_root = fixture_root / "WorkspaceDatabase"
    for version in sorted(expected_versions):
        local_path = local_schema_root / f"{version}.json"
        android_path = android_schema_root / f"{version}.json"
        if local_path.read_bytes() != android_path.read_bytes():
            raise AuthorityDriftError(f"Android workspace schema v{version} drift")

    source_pairs = [
        (fixture_root / "WorkspaceMigrations.kt", android_root / ANDROID_MIGRATION_RELATIVE_PATH),
        (fixture_root / "WorkspaceMigrationUtilities.kt", android_root / ANDROID_UTILITY_RELATIVE_PATH),
    ]
    for local_path, android_path in source_pairs:
        if local_path.read_bytes() != android_path.read_bytes():
            raise AuthorityDriftError(f"Android migration source drift: {android_path}")

    local_progress_path = fixture_root / "ProgressDatabase-v9.json"
    android_progress_path = android_root / ANDROID_PROGRESS_SCHEMA_RELATIVE_PATH
    if local_progress_path.read_bytes() != android_progress_path.read_bytes():
        raise AuthorityDriftError("Android ProgressDatabase v9 schema drift")

    for relative_path, expected_digest in manifest["androidSourceSHA256"].items():
        source_path = android_root / relative_path
        if sha256(source_path) != expected_digest:
            raise AuthorityDriftError(f"Android authority source drift: {relative_path}")


def android_head(android_root: Path) -> str:
    """Return the live Android checkout commit or an explicit non-git marker."""
    result = subprocess.run(
        ["git", "-C", str(android_root), "rev-parse", "HEAD"],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else "not-a-git-checkout"


def parse_args() -> argparse.Namespace:
    """Parse the optional Android checkout override."""
    default_android_root = os.environ.get(
        "ANDBIBLE_ANDROID_ROOT",
        str(REPOSITORY_ROOT.parent / "and-bible"),
    )
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--android-root", type=Path, default=Path(default_android_root))
    return parser.parse_args()


def main() -> int:
    """Run local provenance and live Android drift validation."""
    args = parse_args()
    try:
        manifest = load_manifest()
        validate_android_checkout(args.android_root.resolve(), manifest=manifest)
    except (AuthorityDriftError, OSError, json.JSONDecodeError) as error:
        print(f"Android Room authority check failed: {error}", file=sys.stderr)
        return 1
    print(
        "Workspace and Progress Room authority verified: "
        f"pinned={manifest['androidCommit']} live={android_head(args.android_root.resolve())}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
