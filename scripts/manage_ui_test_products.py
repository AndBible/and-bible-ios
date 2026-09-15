#!/usr/bin/env python3
"""Package and verify portable Xcode UI-test products for one CI workflow run."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import stat
import subprocess
import tarfile
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


MANIFEST_VERSION = 1
MANIFEST_NAME = "ui-test-products-manifest.json"
PRODUCTS_RELATIVE_PATH = Path(".derivedData/Build/Products")
FIXTURE_RELATIVE_PATH = Path(".build/debug/UITestFixtureTool")
FIXTURE_MANIFEST_RELATIVE_PATH = Path(".ui-test/fixtures/ui_test_fixture_manifest.json")
SWORD_FIXTURE_RELATIVE_PATH = Path(".ui-test/fixtures/sword")
FIXTURE_RESOURCE_BUNDLE_NAMES = ("AndBible_BibleCore.bundle", "AndBible_SwordKit.bundle")
SWORD_MODULE_PAYLOAD_FAMILIES = frozenset(
    {"comments", "genbook", "images", "lexdict", "maps", "texts"}
)
ALLOWED_ARCHIVE_ROOTS = frozenset({".derivedData", ".build", ".ui-test", MANIFEST_NAME})
RUNNER_LOCAL_TEST_ENVIRONMENT_KEYS = frozenset(
    {
        "CFFIXED_USER_HOME",
        "DEVELOPER_DIR",
        "HOME",
        "TMPDIR",
        "UITEST_DEVELOPER_DIR",
    }
)
RUNNER_LOCAL_UI_TEST_ENVIRONMENT_KEYS = RUNNER_LOCAL_TEST_ENVIRONMENT_KEYS | frozenset(
    {
        "PERFORMANCE_LIBRARY_SCALE",
        "UITEST_BUNDLE_ID",
        "UITEST_FIXTURE_MANIFEST_PATH",
        "UITEST_FIXTURE_SERVICE_DIRECTORY",
        "UITEST_FIXTURE_TOOL_PATH",
        "UITEST_SIMULATOR_ID",
        "UITEST_SWORD_FIXTURE_PATH",
    }
)


class ProductArchiveError(RuntimeError):
    """Raised when reusable UI-test products do not satisfy the portability contract."""


@dataclass(frozen=True)
class ToolchainProvenance:
    """Toolchain and runner facts that must match between producer and consumer."""

    xcode_version: str
    simulator_sdk_version: str
    runner_architecture: str

    def as_dict(self) -> dict[str, str]:
        return {
            "xcode_version": self.xcode_version,
            "simulator_sdk_version": self.simulator_sdk_version,
            "runner_architecture": self.runner_architecture,
        }


def _run_text(command: Sequence[str]) -> str:
    """Run one read-only toolchain command and return trimmed stdout."""
    completed = subprocess.run(command, check=True, capture_output=True, text=True)
    return completed.stdout.strip()


def current_toolchain_provenance(
    run_text: Callable[[Sequence[str]], str] = _run_text,
) -> ToolchainProvenance:
    """Read the selected Xcode, simulator SDK, and runner architecture."""
    return ToolchainProvenance(
        xcode_version=run_text(("xcodebuild", "-version")),
        simulator_sdk_version=run_text(("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version")),
        runner_architecture=run_text(("uname", "-m")),
    )


def sha256_file(path: Path) -> str:
    """Return a streaming SHA-256 digest for one regular file."""
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def discover_single_xctestrun(products_path: Path) -> Path:
    """Return the single top-level xctestrun emitted by build-for-testing."""
    candidates = sorted(products_path.glob("*.xctestrun"))
    if len(candidates) != 1:
        raise ProductArchiveError(
            f"Expected exactly one .xctestrun in {products_path}; found {len(candidates)}."
        )
    return candidates[0]


def macho_architectures(path: Path) -> list[str]:
    """Read the actual architecture slices from one Mach-O executable."""
    architectures = sorted(set(_run_text(("xcrun", "lipo", "-archs", str(path))).split()))
    if not architectures:
        raise ProductArchiveError(f"No Mach-O architecture slices found in {path}.")
    return architectures


def _bundle_executable(bundle_path: Path) -> Path:
    """Resolve a built bundle's executable from its generated Info.plist."""
    info_plist = bundle_path / "Info.plist"
    if not info_plist.is_file():
        raise ProductArchiveError(f"Built bundle is missing Info.plist: {bundle_path}")
    with info_plist.open("rb") as source:
        payload = plistlib.load(source)
    executable = payload.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable:
        raise ProductArchiveError(f"Built bundle has no CFBundleExecutable: {bundle_path}")
    executable_path = bundle_path / executable
    if not executable_path.is_file():
        raise ProductArchiveError(f"Built bundle executable is missing: {executable_path}")
    return executable_path


def _xctestrun_targets(payload: Mapping[str, object]) -> list[Mapping[str, object]]:
    """Return generated test targets from xctestrun format one or two."""
    configurations = payload.get("TestConfigurations")
    if isinstance(configurations, list):
        targets: list[Mapping[str, object]] = []
        for configuration in configurations:
            if not isinstance(configuration, Mapping):
                continue
            configuration_targets = configuration.get("TestTargets")
            if not isinstance(configuration_targets, list):
                continue
            targets.extend(
                target for target in configuration_targets if isinstance(target, Mapping)
            )
        return targets
    return [
        value
        for key, value in payload.items()
        if key != "__xctestrun_metadata__" and isinstance(value, Mapping)
    ]


def _xctestrun_target(payload: Mapping[str, object], blueprint_name: str) -> Mapping[str, object]:
    """Return the one generated target entry for a blueprint name."""
    candidates = [
        target for target in _xctestrun_targets(payload)
        if target.get("BlueprintName") == blueprint_name
    ]
    if len(candidates) != 1:
        raise ProductArchiveError(
            f"Expected one {blueprint_name} entry in xctestrun metadata; found {len(candidates)}."
        )
    return candidates[0]


def strip_runner_local_ui_test_environment(xctestrun_path: Path) -> set[str]:
    """Remove consumer-specific UI runner values from one staged xctestrun product."""
    with xctestrun_path.open("rb") as source:
        payload = plistlib.load(source)
    if not isinstance(payload, dict):
        raise ProductArchiveError(f"Expected dictionary xctestrun payload at {xctestrun_path}.")

    removed: set[str] = set()
    for target in _xctestrun_targets(payload):
        keys = RUNNER_LOCAL_TEST_ENVIRONMENT_KEYS
        if target.get("IsUITestBundle") is True:
            keys = RUNNER_LOCAL_UI_TEST_ENVIRONMENT_KEYS
        for environment_name in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            environment = target.get(environment_name)
            if environment is None:
                continue
            if not isinstance(environment, dict):
                raise ProductArchiveError(
                    f"Expected {environment_name} dictionary in UI xctestrun target."
                )
            for key in keys:
                if key in environment:
                    removed.add(key)
                    del environment[key]

    if removed:
        with xctestrun_path.open("wb") as output:
            plistlib.dump(payload, output)
    return removed


def _resolve_xctestrun_product_path(
    value: object,
    *,
    products_path: Path,
    test_host_path: Path | None = None,
) -> Path:
    """Resolve Xcode test-root/test-host placeholders and enforce product-root containment."""
    if not isinstance(value, str) or not value:
        raise ProductArchiveError(f"Expected generated xctestrun product path, found {value!r}.")
    resolved = value.replace("__TESTROOT__", str(products_path))
    if "__TESTHOST__" in resolved:
        if test_host_path is None:
            raise ProductArchiveError(f"Cannot resolve __TESTHOST__ without its host: {value}")
        resolved = resolved.replace("__TESTHOST__", str(test_host_path))
    if "__" in resolved:
        raise ProductArchiveError(f"Unsupported placeholder in xctestrun product path: {value}")
    path = Path(resolved)
    try:
        path.relative_to(products_path)
    except ValueError as error:
        raise ProductArchiveError(f"xctestrun product path escapes Build/Products: {value}") from error
    return path


def required_product_executables(
    products_path: Path,
    fixture_tool: Path,
    xctestrun_path: Path,
) -> list[Path]:
    """Resolve actual generated app/test bundles and return their executables for validation."""
    with xctestrun_path.open("rb") as source:
        payload = plistlib.load(source)
    if not isinstance(payload, Mapping):
        raise ProductArchiveError(f"Expected dictionary xctestrun payload at {xctestrun_path}.")
    app_host_target = _xctestrun_target(payload, "AndBibleTests")
    ui_target = _xctestrun_target(payload, "AndBibleUITests")
    app = required_app_bundle(products_path, xctestrun_path)
    unit_test_bundle = _resolve_xctestrun_product_path(
        app_host_target.get("TestBundlePath"),
        products_path=products_path,
        test_host_path=app,
    )
    runner = _resolve_xctestrun_product_path(
        ui_target.get("TestHostPath"),
        products_path=products_path,
    )
    ui_test_bundle = _resolve_xctestrun_product_path(
        ui_target.get("TestBundlePath"),
        products_path=products_path,
        test_host_path=runner,
    )
    executables = [
        _bundle_executable(app),
        _bundle_executable(unit_test_bundle),
        _bundle_executable(runner),
        _bundle_executable(ui_test_bundle),
        fixture_tool,
    ]
    debug_dylib = app / "AndBible.debug.dylib"
    if debug_dylib.is_file():
        executables.append(debug_dylib)
    return executables


def required_app_bundle(products_path: Path, xctestrun_path: Path) -> Path:
    """Resolve the one app shared by generated app-host and UI-test metadata."""
    with xctestrun_path.open("rb") as source:
        payload = plistlib.load(source)
    if not isinstance(payload, Mapping):
        raise ProductArchiveError(f"Expected dictionary xctestrun payload at {xctestrun_path}.")
    app_host_target = _xctestrun_target(payload, "AndBibleTests")
    ui_target = _xctestrun_target(payload, "AndBibleUITests")
    app = _resolve_xctestrun_product_path(
        app_host_target.get("TestHostPath"),
        products_path=products_path,
    )
    ui_app = _resolve_xctestrun_product_path(
        ui_target.get("UITargetAppPath"),
        products_path=products_path,
    )
    if ui_app != app:
        raise ProductArchiveError(
            f"App-host and UI tests reference different apps: {app} and {ui_app}."
        )
    return app


def validate_app_excludes_bundled_sword_modules(app: Path) -> None:
    """Reject SWORD module stores copied into the shipping portion of the built app bundle."""
    if not app.is_dir():
        raise ProductArchiveError(f"Built application bundle is missing: {app}")
    test_plugins = app / "PlugIns"
    forbidden: list[Path] = []
    for directory in app.rglob("*"):
        if not directory.is_dir():
            continue
        try:
            directory.relative_to(test_plugins)
        except ValueError:
            pass
        else:
            continue
        if directory.name == "mods.d":
            forbidden.append(directory)
            continue
        if directory.name != "modules":
            continue
        for family in SWORD_MODULE_PAYLOAD_FAMILIES:
            payload_root = directory / family
            if payload_root.is_dir():
                forbidden.append(payload_root)
    if forbidden:
        relative = sorted(path.relative_to(app).as_posix() for path in forbidden)
        raise ProductArchiveError(
            "Built application bundles SWORD module payloads: " + ", ".join(relative)
        )


def required_fixture_resource_bundles(fixture_tool: Path) -> list[Path]:
    """Resolve the bounded SwiftPM resource bundles linked by UITestFixtureTool dependencies."""
    bundles = [fixture_tool.parent / name for name in FIXTURE_RESOURCE_BUNDLE_NAMES]
    missing = [str(bundle) for bundle in bundles if not bundle.is_dir()]
    empty = [
        str(bundle)
        for bundle in bundles
        if bundle.is_dir() and not any(path.is_file() for path in bundle.rglob("*"))
    ]
    if missing or empty:
        details = []
        if missing:
            details.append("missing " + ", ".join(missing))
        if empty:
            details.append("empty " + ", ".join(empty))
        raise ProductArchiveError(
            "UITestFixtureTool resource bundles are incomplete: " + "; ".join(details)
        )
    return bundles


def product_architectures(
    *,
    root: Path,
    products_path: Path,
    fixture_tool: Path,
    xctestrun_path: Path,
    expected_architecture: str,
    architecture_reader: Callable[[Path], Sequence[str]] = macho_architectures,
) -> dict[str, list[str]]:
    """Record actual Mach-O slices and require compatibility with the producer host."""
    architectures: dict[str, list[str]] = {}
    for executable in required_product_executables(products_path, fixture_tool, xctestrun_path):
        relative = executable.relative_to(root).as_posix()
        slices = sorted(set(architecture_reader(executable)))
        if not slices:
            raise ProductArchiveError(f"No Mach-O architecture slices found in {executable}.")
        architectures[relative] = slices
    incompatible = {
        path: slices
        for path, slices in architectures.items()
        if expected_architecture not in slices
    }
    if incompatible:
        raise ProductArchiveError(
            f"UI-test products do not support runner architecture "
            f"{expected_architecture!r}: {incompatible}."
        )
    return architectures


def _inventory_paths(root: Path, paths: Sequence[Path]) -> list[dict[str, object]]:
    """Describe the supplied paths relative to one artifact root."""
    entries: list[dict[str, object]] = []
    for path in sorted(paths, key=lambda candidate: candidate.as_posix()):
        relative = path.relative_to(root).as_posix()
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if path.is_symlink():
            entries.append(
                {"path": relative, "kind": "symlink", "mode": mode, "target": os.readlink(path)}
            )
        elif path.is_dir():
            entries.append({"path": relative, "kind": "directory", "mode": mode})
        elif path.is_file():
            entries.append(
                {
                    "path": relative,
                    "kind": "file",
                    "mode": mode,
                    "size": metadata.st_size,
                    "sha256": sha256_file(path),
                }
            )
        else:
            raise ProductArchiveError(f"Unsupported filesystem entry in UI product payload: {path}")
    return entries


def inventory_payload(root: Path) -> list[dict[str, object]]:
    """Describe only the portable product roots, excluding unrelated destination files."""
    paths: list[Path] = []
    for relative_root in (Path(".build"), Path(".derivedData"), Path(".ui-test")):
        product_root = root / relative_root
        if product_root.exists() or product_root.is_symlink():
            paths.append(product_root)
            paths.extend(product_root.rglob("*"))
    return _inventory_paths(root, paths)


def validate_required_products(
    products_path: Path,
    fixture_tool: Path,
    fixture_manifest: Path,
    sword_fixture: Path,
) -> Path:
    """Require the app, hosted/unit tests, UI products, fixture inputs, and xctestrun."""
    if not fixture_tool.is_file() or not os.access(fixture_tool, os.X_OK):
        raise ProductArchiveError(f"Expected executable host fixture tool at {fixture_tool}.")
    required_fixture_resource_bundles(fixture_tool)
    if not fixture_manifest.is_file():
        raise ProductArchiveError(f"Expected UI fixture manifest at {fixture_manifest}.")
    required_sword_files = (
        sword_fixture / "mods.d/kjv.conf",
        sword_fixture / "modules/texts/ztext/kjv/ot.bzs",
    )
    missing_sword_files = [str(path) for path in required_sword_files if not path.is_file()]
    if missing_sword_files:
        raise ProductArchiveError(
            "SWORD fixture is incomplete: " + ", ".join(missing_sword_files)
        )
    xctestrun_path = discover_single_xctestrun(products_path)
    validate_app_excludes_bundled_sword_modules(
        required_app_bundle(products_path, xctestrun_path)
    )
    # Resolving every required bundle here makes missing/malformed generated products fail before
    # staging, even when callers inject architecture reading in behavioral tests.
    required_product_executables(products_path, fixture_tool, xctestrun_path)
    return xctestrun_path


def _write_manifest(stage_root: Path, manifest: Mapping[str, object]) -> None:
    (stage_root / MANIFEST_NAME).write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def package_products(
    *,
    products_path: Path,
    fixture_tool: Path,
    fixture_manifest: Path,
    sword_fixture: Path,
    output_path: Path,
    commit_sha: str,
    configuration: str,
    code_signing_allowed: str,
    provenance: ToolchainProvenance,
    architecture_reader: Callable[[Path], Sequence[str]] = macho_architectures,
) -> Mapping[str, object]:
    """Stage the complete build products and write a self-verifying tar archive."""
    xctestrun_path = validate_required_products(
        products_path,
        fixture_tool,
        fixture_manifest,
        sword_fixture,
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    stage_root = output_path.parent / "ui-test-products-stage"
    if stage_root.exists():
        shutil.rmtree(stage_root)
    (stage_root / PRODUCTS_RELATIVE_PATH.parent).mkdir(parents=True, exist_ok=True)
    (stage_root / FIXTURE_RELATIVE_PATH.parent).mkdir(parents=True, exist_ok=True)
    (stage_root / FIXTURE_MANIFEST_RELATIVE_PATH.parent).mkdir(parents=True, exist_ok=True)
    shutil.copytree(products_path, stage_root / PRODUCTS_RELATIVE_PATH, symlinks=True)
    shutil.copy2(fixture_tool, stage_root / FIXTURE_RELATIVE_PATH, follow_symlinks=False)
    for resource_bundle in required_fixture_resource_bundles(fixture_tool):
        shutil.copytree(
            resource_bundle,
            stage_root / FIXTURE_RELATIVE_PATH.parent / resource_bundle.name,
            symlinks=True,
        )
    shutil.copy2(
        fixture_manifest,
        stage_root / FIXTURE_MANIFEST_RELATIVE_PATH,
        follow_symlinks=False,
    )
    shutil.copytree(
        sword_fixture,
        stage_root / SWORD_FIXTURE_RELATIVE_PATH,
        symlinks=True,
    )

    staged_xctestrun = stage_root / PRODUCTS_RELATIVE_PATH / xctestrun_path.name
    strip_runner_local_ui_test_environment(staged_xctestrun)
    manifest: dict[str, object] = {
        "version": MANIFEST_VERSION,
        "commit_sha": commit_sha,
        "configuration": configuration,
        "code_signing_allowed": code_signing_allowed,
        "toolchain": provenance.as_dict(),
        "xctestrun_path": (PRODUCTS_RELATIVE_PATH / xctestrun_path.name).as_posix(),
        "product_architectures": product_architectures(
            root=stage_root,
            products_path=stage_root / PRODUCTS_RELATIVE_PATH,
            fixture_tool=stage_root / FIXTURE_RELATIVE_PATH,
            xctestrun_path=staged_xctestrun,
            expected_architecture=provenance.runner_architecture,
            architecture_reader=architecture_reader,
        ),
        "payload": inventory_payload(stage_root),
    }
    _write_manifest(stage_root, manifest)

    if output_path.exists():
        output_path.unlink()
    with tarfile.open(output_path, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for path in sorted(stage_root.iterdir(), key=lambda candidate: candidate.name):
            archive.add(path, arcname=path.name, recursive=True)
    shutil.rmtree(stage_root)
    return manifest


def _validate_archive_members(archive: tarfile.TarFile) -> None:
    """Reject paths that could escape or add unrelated roots during extraction."""
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            raise ProductArchiveError(f"Unsafe archive member path: {member.name}")
        if path.parts[0] not in ALLOWED_ARCHIVE_ROOTS:
            raise ProductArchiveError(f"Unexpected archive root: {member.name}")
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise ProductArchiveError(f"Unsupported archive member type: {member.name}")
        if member.issym() or member.islnk():
            link_target = PurePosixPath(member.linkname)
            if link_target.is_absolute():
                raise ProductArchiveError(
                    f"Unsafe archive link target for {member.name}: {member.linkname}"
                )
            pending_parts = (
                list(path.parent.parts) + list(link_target.parts)
                if member.issym()
                else list(link_target.parts)
            )
            resolved_parts: list[str] = []
            for part in pending_parts:
                if part in ("", "."):
                    continue
                if part == "..":
                    if not resolved_parts:
                        raise ProductArchiveError(
                            f"Unsafe archive link target for {member.name}: {member.linkname}"
                        )
                    resolved_parts.pop()
                else:
                    resolved_parts.append(part)
            if not resolved_parts or resolved_parts[0] not in ALLOWED_ARCHIVE_ROOTS:
                raise ProductArchiveError(
                    f"Unsafe archive link target for {member.name}: {member.linkname}"
                )


def _validate_inventory(root: Path, expected_entries: object) -> None:
    if not isinstance(expected_entries, list):
        raise ProductArchiveError("Manifest payload must be a list.")
    actual_entries = inventory_payload(root)
    if actual_entries != expected_entries:
        raise ProductArchiveError("Restored UI-test product inventory does not match its manifest.")


def verify_products(
    *,
    archive_path: Path,
    destination: Path,
    expected_commit_sha: str,
    expected_configuration: str,
    expected_code_signing_allowed: str,
    provenance: ToolchainProvenance,
    architecture_reader: Callable[[Path], Sequence[str]] = macho_architectures,
) -> Path:
    """Extract and verify a same-runner-class UI-test product archive."""
    destination.mkdir(parents=True, exist_ok=True)
    occupied_roots = [
        name for name in ALLOWED_ARCHIVE_ROOTS if (destination / name).exists()
        or (destination / name).is_symlink()
    ]
    if occupied_roots:
        raise ProductArchiveError(
            "UI-test product destination already contains managed roots: "
            + ", ".join(sorted(occupied_roots))
        )
    with tarfile.open(archive_path, "r:gz") as archive:
        _validate_archive_members(archive)
        # `_validate_archive_members` applies the traversal, root, type, and link-target checks
        # needed by this fixed-format archive on Python versions predating tarfile's `filter=` API.
        archive.extractall(destination)

    manifest_path = destination / MANIFEST_NAME
    if not manifest_path.is_file():
        raise ProductArchiveError(f"Archive is missing {MANIFEST_NAME}.")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    expected_scalars = {
        "version": MANIFEST_VERSION,
        "commit_sha": expected_commit_sha,
        "configuration": expected_configuration,
        "code_signing_allowed": expected_code_signing_allowed,
        "toolchain": provenance.as_dict(),
    }
    for key, expected in expected_scalars.items():
        if manifest.get(key) != expected:
            raise ProductArchiveError(
                f"UI-test product manifest {key} mismatch: expected {expected!r}, "
                f"found {manifest.get(key)!r}."
            )

    _validate_inventory(destination, manifest.get("payload"))
    xctestrun_value = manifest.get("xctestrun_path")
    if not isinstance(xctestrun_value, str):
        raise ProductArchiveError("Manifest xctestrun_path must be a string.")
    relative_xctestrun = PurePosixPath(xctestrun_value)
    expected_xctestrun_root = PurePosixPath(PRODUCTS_RELATIVE_PATH.as_posix())
    if (
        relative_xctestrun.is_absolute()
        or ".." in relative_xctestrun.parts
        or relative_xctestrun.parent != expected_xctestrun_root
    ):
        raise ProductArchiveError(f"Unsafe manifest xctestrun_path: {xctestrun_value}")
    xctestrun_path = destination / Path(*relative_xctestrun.parts)
    restored_products = destination / PRODUCTS_RELATIVE_PATH
    discovered_xctestrun = validate_required_products(
        restored_products,
        destination / FIXTURE_RELATIVE_PATH,
        destination / FIXTURE_MANIFEST_RELATIVE_PATH,
        destination / SWORD_FIXTURE_RELATIVE_PATH,
    )
    if xctestrun_path != discovered_xctestrun:
        raise ProductArchiveError(
            "Manifest xctestrun_path does not match the restored build-for-testing product."
        )
    actual_architectures = product_architectures(
        root=destination,
        products_path=restored_products,
        fixture_tool=destination / FIXTURE_RELATIVE_PATH,
        xctestrun_path=xctestrun_path,
        expected_architecture=provenance.runner_architecture,
        architecture_reader=architecture_reader,
    )
    if actual_architectures != manifest.get("product_architectures"):
        raise ProductArchiveError("Restored Mach-O architectures do not match the product manifest.")
    return xctestrun_path


def _write_github_output(output_path: Path, destination: Path, xctestrun_path: Path) -> None:
    """Append verified consumer paths usable from a different process directory.

    Paths refer to the restoring checkout, never the producer's checkout. The
    output file is appended without changing restored products; filesystem
    errors propagate to the verification command.
    """
    destination = destination.absolute()
    xctestrun_path = xctestrun_path.absolute()
    with output_path.open("a", encoding="utf-8") as output:
        output.write(f"xctestrun_path={xctestrun_path}\n")
        output.write(f"fixture_tool_path={destination / FIXTURE_RELATIVE_PATH}\n")
        output.write(f"fixture_manifest_path={destination / FIXTURE_MANIFEST_RELATIVE_PATH}\n")
        output.write(f"sword_fixture_path={destination / SWORD_FIXTURE_RELATIVE_PATH}\n")


def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    package = subparsers.add_parser("package")
    package.add_argument("--products-path", type=Path, required=True)
    package.add_argument("--fixture-tool", type=Path, required=True)
    package.add_argument("--fixture-manifest", type=Path, required=True)
    package.add_argument("--sword-fixture", type=Path, required=True)
    package.add_argument("--output", type=Path, required=True)
    package.add_argument("--commit-sha", required=True)
    package.add_argument("--configuration", default="Debug")
    package.add_argument("--code-signing-allowed", default="NO")

    verify = subparsers.add_parser("verify")
    verify.add_argument("--archive", type=Path, required=True)
    verify.add_argument("--destination", type=Path, default=Path.cwd())
    verify.add_argument("--expected-commit-sha", required=True)
    verify.add_argument("--expected-configuration", default="Debug")
    verify.add_argument("--expected-code-signing-allowed", default="NO")
    verify.add_argument("--github-output", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = create_parser().parse_args(argv)
    provenance = current_toolchain_provenance()
    if args.command == "package":
        manifest = package_products(
            products_path=args.products_path,
            fixture_tool=args.fixture_tool,
            fixture_manifest=args.fixture_manifest,
            sword_fixture=args.sword_fixture,
            output_path=args.output,
            commit_sha=args.commit_sha,
            configuration=args.configuration,
            code_signing_allowed=args.code_signing_allowed,
            provenance=provenance,
        )
        print(
            f"Packaged {len(manifest['payload'])} UI-test product entries at {args.output} "
            f"with {len(manifest['product_architectures'])} verified Mach-O executables."
        )
        return 0

    xctestrun_path = verify_products(
        archive_path=args.archive,
        destination=args.destination,
        expected_commit_sha=args.expected_commit_sha,
        expected_configuration=args.expected_configuration,
        expected_code_signing_allowed=args.expected_code_signing_allowed,
        provenance=provenance,
    )
    if args.github_output:
        _write_github_output(args.github_output, args.destination, xctestrun_path)
    print(f"Verified reusable UI-test products at {xctestrun_path}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError, tarfile.TarError, ProductArchiveError) as error:
        print(f"error: {error}", file=os.sys.stderr)
        raise SystemExit(1) from error
