#!/usr/bin/env python3
"""Verify AI settings Room authority against one exact Android commit."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any

import check_android_workspace_schema_authority as shared


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
FIXTURE_ROOT = (
    REPOSITORY_ROOT
    / "Sources"
    / "BibleCore"
    / "Tests"
    / "Fixtures"
    / "AndroidRoomSchemas"
)
MANIFEST_PATH = FIXTURE_ROOT / "ai-settings-authority.json"
MIGRATION_SQL_PATH = FIXTURE_ROOT / "AiSettingsMigrationSQL.json"
ANDROID_SCHEMA_RELATIVE_PATH = Path(
    "app/schemas/net.bible.android.database.AiSettingsDatabase"
)
ANDROID_MIGRATION_RELATIVE_PATH = Path(
    "app/src/main/java/net/bible/android/database/migrations/AiSettingsMigrations.kt"
)
ANDROID_UTILITY_RELATIVE_PATH = Path(
    "app/src/main/java/net/bible/android/database/migrations/Utilities.kt"
)
ANDROID_ROOM_VERSION_RELATIVE_PATH = Path("build.gradle.kts")
REQUIRED_ANDROID_SOURCE_RELATIVE_PATHS = {
    "app/src/main/java/net/bible/android/database/Databases.kt",
    "app/src/main/java/net/bible/service/cloudsync/SyncUtilities.kt",
    "app/src/main/java/net/bible/service/common/AiSettings.kt",
    "app/src/main/java/net/bible/service/db/DatabaseContainer.kt",
    "app/src/main/java/net/bible/service/llm/AgentPromptEntities.kt",
    "app/src/main/java/net/bible/service/llm/LlmCostTracking.kt",
}
DERIVED_SCHEMA_AUTHORITY = {
    "12": {
        "baseExportVersion": 11,
        "canonicalSchemaSHA256": "1fcdbebe0865065824e82c0a995c7c216bce2de8e483f90f6daec3746aa39149",
        "identityHash": "ce84fdcfd2da69ec7a3dbb0a48598c5b",
        "introducingAndroidCommit": "b75638905579b061a60485e4559396d5adf755da",
        "migrationFromVersion": 11,
        "migrationToVersion": 12,
        "roomCompilerVersion": "2.7.2",
    }
}
VERSION_12_MIGRATION_STATEMENTS = {
    'ALTER TABLE `AgentPrompt` ADD COLUMN `autoIncludeDocuments` INTEGER NOT NULL DEFAULT 0',
    'ALTER TABLE `AgentPrompt` ADD COLUMN `autoIncludeCommentaries` INTEGER NOT NULL DEFAULT 0',
}

AuthorityDriftError = shared.AuthorityDriftError


def normalize_sql(value: str) -> str:
    """Collapse formatting-only whitespace while preserving SQL token order and spelling."""
    return " ".join(value.split()).removesuffix(";")


def room_272_identity_hash(database: dict[str, Any]) -> str:
    """Derive Room 2.7.2's database identity from one exported schema object.

    This is an independent Python implementation of Room compiler 2.7.2's
    ``SchemaIdentityKey`` algorithm. Entity, field, primary-key, index, and foreign-key keys use
    Room's exact punctuation, boolean spelling, case-insensitive ordering, separator, and MD5
    composition. AI settings has no views; encountering one fails instead of approximating its
    compiler query identity.
    """

    def boolean(value: Any) -> str:
        return "true" if bool(value) else "false"

    def kotlin_list(values: list[str]) -> str:
        return f"[{', '.join(values)}]"

    def digest(values: list[str]) -> str:
        payload = "".join(f"{value}?:?" for value in values)
        return hashlib.md5(payload.encode("utf-8"), usedforsecurity=False).hexdigest()

    def field_key(field: dict[str, Any]) -> str:
        key = (
            f"{field['columnName']}-{field.get('affinity') or 'TEXT'}-"
            f"{boolean(field.get('notNull', False))}"
        )
        if field.get("defaultValue") is not None:
            key += f"-defaultValue={field['defaultValue']}"
        return key

    def primary_key(primary_key: dict[str, Any]) -> str:
        return (
            f"{boolean(primary_key.get('autoGenerate', False))}-"
            f"{kotlin_list(primary_key['columnNames'])}"
        )

    def index_key(index: dict[str, Any]) -> str:
        key = (
            f"{boolean(index.get('unique', False))}-{index['name']}-"
            f"{','.join(index['columnNames'])}"
        )
        orders = index.get("orders", [])
        if orders:
            key += f"-{','.join(orders)}"
        return key

    def foreign_key(foreign_key: dict[str, Any]) -> str:
        return (
            f"{foreign_key['table']}-{','.join(foreign_key['referencedColumns'])}-"
            f"{','.join(foreign_key['columns'])}-{foreign_key['onDelete']}-"
            f"{foreign_key['onUpdate']}-{boolean(foreign_key.get('deferred', False))}"
        )

    def entity_key(entity: dict[str, Any]) -> str:
        values = [entity["tableName"], primary_key(entity["primaryKey"])]
        values.extend(sorted((field_key(value) for value in entity["fields"]), key=str.lower))
        values.extend(
            sorted((index_key(value) for value in entity.get("indices", [])), key=str.lower)
        )
        values.extend(
            sorted(
                (foreign_key(value) for value in entity.get("foreignKeys", [])),
                key=str.lower,
            )
        )
        return digest(values)

    if database.get("views"):
        raise AuthorityDriftError("AI settings Room identity derivation does not accept views")
    entities = database.get("entities")
    if not isinstance(entities, list):
        raise AuthorityDriftError("AI settings Room export has no entity list")
    return digest(sorted((entity_key(entity) for entity in entities), key=str.lower))


def derive_version_12_database(
    version_11_export: dict[str, Any],
    migration_statements: list[str],
) -> dict[str, Any]:
    """Apply Android's 11-to-12 add-column declarations to the v11 Room export model.

    The derivation parses the copied Android SQL instead of embedding the two resulting fields a
    second time. It returns a detached schema object used only for Room identity calculation and
    fails when the migration shape cannot be represented exactly as an exported Room field.
    """
    database = json.loads(json.dumps(version_11_export.get("database")))
    if not isinstance(database, dict) or database.get("version") != 11:
        raise AuthorityDriftError("AI settings v12 derivation requires the v11 Room export")
    entities = database.get("entities")
    if not isinstance(entities, list):
        raise AuthorityDriftError("AI settings v11 Room export has no entity list")
    entity_by_name = {entity.get("tableName"): entity for entity in entities}
    add_column_pattern = re.compile(
        r"ALTER TABLE `([^`]+)` ADD COLUMN `([^`]+)` ([A-Z]+)"
        r"( NOT NULL)?(?: DEFAULT (.+))?"
    )
    for statement in migration_statements:
        match = add_column_pattern.fullmatch(normalize_sql(statement))
        if match is None:
            raise AuthorityDriftError(
                f"unsupported Android AI v12 identity derivation SQL: {statement}"
            )
        table_name, column_name, affinity, not_null, default_value = match.groups()
        entity = entity_by_name.get(table_name)
        if not isinstance(entity, dict) or not isinstance(entity.get("fields"), list):
            raise AuthorityDriftError(f"AI settings v12 derivation table missing: {table_name}")
        if any(field.get("columnName") == column_name for field in entity["fields"]):
            raise AuthorityDriftError(
                f"AI settings v12 derivation column already exists: {table_name}.{column_name}"
            )
        field: dict[str, Any] = {
            "fieldPath": column_name,
            "columnName": column_name,
            "affinity": affinity,
            "notNull": not_null is not None,
        }
        if default_value is not None:
            field["defaultValue"] = default_value
        entity["fields"].append(field)
    database["version"] = 12
    return database


def extract_room_compiler_version(source: str) -> str:
    """Read Android's single root ``roomVersion`` declaration without evaluating Gradle."""
    matches = re.findall(r'val roomVersion by extra\("([^"]+)"\)', source)
    if len(matches) != 1:
        raise AuthorityDriftError("Android Room compiler version declaration drift")
    return matches[0]


def extract_android_migration_sql(source: str) -> dict[str, list[str]]:
    """Extract every literal `db.execSQL` statement from Android's contiguous migration edges."""
    block_pattern = re.compile(
        r"private val \w+ = makeMigration\((\d+)\.\.(\d+)\) \{ db ->\n(.*?)\n\}",
        re.DOTALL,
    )
    statement_pattern = re.compile(
        r'db\.execSQL\((?:"""(.*?)"""|"((?:\\.|[^"\\])*)")\)',
        re.DOTALL,
    )
    result: dict[str, list[str]] = {}
    for block in block_pattern.finditer(source):
        source_version = int(block.group(1))
        target_version = int(block.group(2))
        if target_version != source_version + 1:
            raise AuthorityDriftError(
                f"non-contiguous Android AI migration {source_version}..{target_version}"
            )
        statements: list[str] = []
        for statement in statement_pattern.finditer(block.group(3)):
            triple_quoted, quoted = statement.groups()
            if triple_quoted is not None:
                value = triple_quoted
            else:
                value = json.loads(f'"{quoted}"')
            statements.append(normalize_sql(value))
        if not statements:
            raise AuthorityDriftError(
                f"Android AI migration {source_version}..{target_version} has no SQL"
            )
        result[str(source_version)] = statements
    expected_edges = {str(version) for version in range(1, 23)}
    if set(result) != expected_edges:
        raise AuthorityDriftError(
            "Android AI migration edge set drift: "
            f"expected {sorted(expected_edges)}, actual {sorted(result)}"
        )
    return result


def load_manifest(path: Path = MANIFEST_PATH) -> dict[str, Any]:
    """Load the pinned AI settings schema, migration, and runtime-source manifest."""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuthorityDriftError(f"invalid authority manifest {path}: {error}") from error
    if not isinstance(value, dict):
        raise AuthorityDriftError(f"authority manifest must be an object: {path}")
    return value


def validate_local_fixtures(
    fixture_root: Path = FIXTURE_ROOT,
    manifest: dict[str, Any] | None = None,
) -> None:
    """Require every copied AI Room artifact to retain its pinned Android bytes."""
    manifest = manifest or load_manifest(fixture_root / "ai-settings-authority.json")
    if not shared.is_lower_hex(manifest.get("androidCommit"), 40):
        raise AuthorityDriftError("androidCommit must be a lowercase 40-character commit")

    schema_hashes = manifest.get("schemaSHA256")
    if not isinstance(schema_hashes, dict) or not schema_hashes:
        raise AuthorityDriftError("schemaSHA256 must be a nonempty object")
    expected_versions = {int(version) for version in schema_hashes}
    schema_root = fixture_root / "AiSettingsDatabase"
    actual_versions = shared.exported_versions(schema_root)
    if actual_versions != expected_versions:
        raise AuthorityDriftError(
            "local AI settings export set drift: "
            f"expected {sorted(expected_versions)}, actual {sorted(actual_versions)}"
        )
    for version_text, expected_digest in schema_hashes.items():
        path = schema_root / f"{version_text}.json"
        if shared.sha256(path) != expected_digest:
            raise AuthorityDriftError(f"local AI settings schema v{version_text} digest drift")
        try:
            exported_schema = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise AuthorityDriftError(
                f"invalid AI settings schema v{version_text}: {error}"
            ) from error
        database = exported_schema.get("database", {})
        if room_272_identity_hash(database) != database.get("identityHash"):
            raise AuthorityDriftError(
                f"AI settings schema v{version_text} Room identity derivation drift"
            )

    if manifest.get("derivedSchemaAuthority") != DERIVED_SCHEMA_AUTHORITY:
        raise AuthorityDriftError("derived AI settings schema authority drift")

    migration_path = fixture_root / "AiSettingsMigrations.kt"
    utility_path = fixture_root / "AiSettingsMigrationUtilities.kt"
    migration_sql_path = fixture_root / "AiSettingsMigrationSQL.json"
    if shared.sha256(migration_path) != manifest.get("migrationSHA256"):
        raise AuthorityDriftError("local AiSettingsMigrations.kt digest drift")
    if shared.sha256(utility_path) != manifest.get("utilitySHA256"):
        raise AuthorityDriftError("local AI migration Utilities.kt digest drift")
    migration_source = migration_path.read_text(encoding="utf-8")
    for statement in VERSION_12_MIGRATION_STATEMENTS:
        if migration_source.count(statement) != 1:
            raise AuthorityDriftError("Android AI v12 derivation migration drift")
    if shared.sha256(migration_sql_path) != manifest.get("migrationSQLSHA256"):
        raise AuthorityDriftError("local AI migration SQL fixture digest drift")
    try:
        migration_sql = json.loads(migration_sql_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise AuthorityDriftError(f"invalid AI migration SQL fixture: {error}") from error
    if migration_sql != extract_android_migration_sql(migration_source):
        raise AuthorityDriftError("AI migration SQL fixture differs from Android source")
    version_11_export = json.loads(
        (schema_root / "11.json").read_text(encoding="utf-8")
    )
    derived_version_12 = derive_version_12_database(
        version_11_export,
        migration_sql["11"],
    )
    expected_version_12_identity = manifest["derivedSchemaAuthority"]["12"]["identityHash"]
    if room_272_identity_hash(derived_version_12) != expected_version_12_identity:
        raise AuthorityDriftError("derived AI settings v12 Room identity drift")

    current_version = manifest.get("currentVersion")
    current_fixture = fixture_root / f"AiSettingsDatabase-v{current_version}.json"
    nested_fixture = schema_root / f"{current_version}.json"
    if current_fixture.read_bytes() != nested_fixture.read_bytes():
        raise AuthorityDriftError("current AI settings fixture differs from predecessor set")
    current_export = json.loads(current_fixture.read_text(encoding="utf-8"))
    database = current_export.get("database", {})
    if database.get("version") != current_version:
        raise AuthorityDriftError("current AI settings fixture version drift")
    if database.get("identityHash") != manifest.get("currentIdentityHash"):
        raise AuthorityDriftError("current AI settings fixture identity drift")

    source_hashes = manifest.get("androidSourceSHA256")
    if not isinstance(source_hashes, dict):
        raise AuthorityDriftError("androidSourceSHA256 must be an object")
    if set(source_hashes) != REQUIRED_ANDROID_SOURCE_RELATIVE_PATHS:
        raise AuthorityDriftError(
            "androidSourceSHA256 paths drift: "
            f"expected {sorted(REQUIRED_ANDROID_SOURCE_RELATIVE_PATHS)}, "
            f"actual {sorted(source_hashes)}"
        )
    for relative_path, digest in source_hashes.items():
        if not shared.is_lower_hex(digest, 64):
            raise AuthorityDriftError(
                f"androidSourceSHA256 digest must be lowercase SHA-256: {relative_path}"
            )


def validate_android_checkout(
    android_root: Path,
    fixture_root: Path = FIXTURE_ROOT,
    manifest: dict[str, Any] | None = None,
) -> None:
    """Require the exact Android commit, AI exports, migrations, and owning source files."""
    manifest = manifest or load_manifest(fixture_root / "ai-settings-authority.json")
    validate_local_fixtures(fixture_root, manifest)
    live_head = shared.android_head(android_root)
    if live_head != manifest.get("androidCommit"):
        raise AuthorityDriftError(
            "Android checkout HEAD drift: "
            f"expected {manifest.get('androidCommit')}, actual {live_head}"
        )

    android_schema_root = android_root / ANDROID_SCHEMA_RELATIVE_PATH
    expected_versions = {int(version) for version in manifest["schemaSHA256"]}
    actual_versions = shared.exported_versions(android_schema_root)
    if actual_versions != expected_versions:
        raise AuthorityDriftError(
            "Android AI settings export set drift: "
            f"expected {sorted(expected_versions)}, actual {sorted(actual_versions)}"
        )
    local_schema_root = fixture_root / "AiSettingsDatabase"
    for version in sorted(expected_versions):
        if (local_schema_root / f"{version}.json").read_bytes() != (
            android_schema_root / f"{version}.json"
        ).read_bytes():
            raise AuthorityDriftError(f"Android AI settings schema v{version} drift")

    source_pairs = [
        (fixture_root / "AiSettingsMigrations.kt", android_root / ANDROID_MIGRATION_RELATIVE_PATH),
        (fixture_root / "AiSettingsMigrationUtilities.kt", android_root / ANDROID_UTILITY_RELATIVE_PATH),
    ]
    for local_path, android_path in source_pairs:
        if local_path.read_bytes() != android_path.read_bytes():
            raise AuthorityDriftError(f"Android AI migration source drift: {android_path}")
    for relative_path, expected_digest in manifest["androidSourceSHA256"].items():
        if shared.sha256(android_root / relative_path) != expected_digest:
            raise AuthorityDriftError(f"Android AI authority source drift: {relative_path}")
    room_version_source = (
        android_root / ANDROID_ROOM_VERSION_RELATIVE_PATH
    ).read_text(encoding="utf-8")
    expected_room_version = manifest["derivedSchemaAuthority"]["12"]["roomCompilerVersion"]
    if extract_room_compiler_version(room_version_source) != expected_room_version:
        raise AuthorityDriftError("Android Room compiler version drift")


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
        print(f"Android AI Room authority check failed: {error}", file=sys.stderr)
        return 1
    print(
        "AI settings Room authority verified: "
        f"pinned={manifest['androidCommit']} "
        f"live={shared.android_head(args.android_root.resolve())}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
