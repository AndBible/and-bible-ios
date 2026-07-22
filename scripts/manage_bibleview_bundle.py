#!/usr/bin/env python3
"""Validate, compare, synchronize, and inspect generated BibleView web bundles."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import shutil
import sys
import tempfile
import uuid


INLINE_SOURCE_MAP_MARKER = b"sourceMappingURL=data:"
SOURCE_MAP_MARKER = b"sourceMappingURL="
MACHINE_PATH_MARKERS = (
    b"/Users/",
    b"/home/runner/",
    b"/private/var/folders/",
    b"file://",
)
WINDOWS_USER_PATH = re.compile(rb"[A-Za-z]:\\\\Users\\\\")
ABSOLUTE_VUE_FILE_METADATA = re.compile(
    rb"__file[\"']?\s*[:=]\s*[\"'](?:/|[A-Za-z]:\\\\)"
)
HTML_RESOURCE_REFERENCE = re.compile(rb"(?:src|href)=[\"']\./([^\"']+)[\"']")


class BundleContractError(ValueError):
    """Reports a generated bundle that cannot satisfy the app packaging contract.

    Inputs are human-readable validation failures. The exception has no side effects and preserves
    deterministic messages so CI output can identify the stale or unsafe artifact. Callers are
    expected to catch it at a command boundary and fail the build.
    """


def bundle_files(root: Path) -> list[Path]:
    """Return every regular bundle file in stable relative-path order.

    The input must be an existing directory. The result excludes directories and symlinks because
    generated web bundles are required to contain ordinary files only. Filesystem traversal is
    read-only and deterministic. Missing roots or symlinks raise ``BundleContractError``.
    """
    if not root.is_dir():
        raise BundleContractError(f"bundle directory does not exist: {root}")
    symlinks = sorted(path.relative_to(root).as_posix() for path in root.rglob("*") if path.is_symlink())
    if symlinks:
        raise BundleContractError(f"bundle contains symlinks: {', '.join(symlinks)}")
    return sorted(
        (path for path in root.rglob("*") if path.is_file()),
        key=lambda path: path.relative_to(root).as_posix(),
    )


def bundle_digest(root: Path) -> str:
    """Return a stable SHA-256 digest over bundle paths and bytes.

    The directory is read without mutation. Relative paths, file lengths, and file contents are
    framed into the digest so renames and concatenation ambiguities cannot collide accidentally.
    Invalid bundle roots propagate ``BundleContractError`` from ``bundle_files``.
    """
    digest = hashlib.sha256()
    for path in bundle_files(root):
        relative = path.relative_to(root).as_posix().encode("utf-8")
        data = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


def validate_bundle(root: Path, mode: str) -> None:
    """Validate one generated bundle's completeness and source-map safety.

    ``mode`` must be ``production`` or ``debug``. Both modes reject machine-specific paths and
    broken references from ``index.html``. Production rejects all source maps; debug requires an
    inline map so diagnostics remain available without creating untracked companion files. The
    check performs read-only file I/O and raises ``BundleContractError`` for every contract breach.
    """
    if mode not in {"production", "debug"}:
        raise BundleContractError(f"unsupported bundle mode: {mode}")

    files = bundle_files(root)
    relative_files = {path.relative_to(root).as_posix() for path in files}
    if "index.html" not in relative_files:
        raise BundleContractError("bundle is missing index.html")
    if not any(relative.startswith("assets/") for relative in relative_files):
        raise BundleContractError("bundle has no generated assets")
    map_files = sorted(relative for relative in relative_files if relative.endswith(".map"))
    if map_files:
        raise BundleContractError(f"bundle contains external source maps: {', '.join(map_files)}")

    inline_map_found = False
    for path in files:
        data = path.read_bytes()
        inline_map_found = inline_map_found or INLINE_SOURCE_MAP_MARKER in data
        for marker in MACHINE_PATH_MARKERS:
            if marker in data:
                relative = path.relative_to(root).as_posix()
                raise BundleContractError(
                    f"bundle contains machine-specific path marker {marker.decode()!r}: {relative}"
                )
        if WINDOWS_USER_PATH.search(data):
            relative = path.relative_to(root).as_posix()
            raise BundleContractError(f"bundle contains a Windows user path: {relative}")
        if ABSOLUTE_VUE_FILE_METADATA.search(data):
            relative = path.relative_to(root).as_posix()
            raise BundleContractError(f"bundle contains absolute Vue __file metadata: {relative}")
        if mode == "production" and SOURCE_MAP_MARKER in data:
            relative = path.relative_to(root).as_posix()
            raise BundleContractError(f"production bundle contains a source map: {relative}")

    if mode == "debug" and not inline_map_found:
        raise BundleContractError("debug bundle does not contain an inline source map")

    index_data = (root / "index.html").read_bytes()
    for reference in HTML_RESOURCE_REFERENCE.findall(index_data):
        relative = reference.decode("utf-8")
        if relative not in relative_files:
            raise BundleContractError(f"index.html references missing bundle file: {relative}")


def compare_bundles(expected: Path, actual: Path, mode: str) -> None:
    """Require two generated bundles to contain byte-identical trees.

    Both inputs are validated for the requested mode before their stable digests are compared. The
    operation is read-only and deterministic. A different file set or any byte drift raises
    ``BundleContractError`` with enough detail to regenerate the committed or packaged artifact.
    """
    validate_bundle(expected, mode)
    validate_bundle(actual, mode)
    expected_files = {
        path.relative_to(expected).as_posix(): path.read_bytes() for path in bundle_files(expected)
    }
    actual_files = {
        path.relative_to(actual).as_posix(): path.read_bytes() for path in bundle_files(actual)
    }
    if expected_files.keys() != actual_files.keys():
        missing = sorted(expected_files.keys() - actual_files.keys())
        unexpected = sorted(actual_files.keys() - expected_files.keys())
        raise BundleContractError(
            "bundle file set differs"
            f"; missing={missing or 'none'}; unexpected={unexpected or 'none'}"
        )
    changed = sorted(
        relative for relative, data in expected_files.items() if actual_files[relative] != data
    )
    if changed:
        raise BundleContractError(f"bundle bytes differ: {', '.join(changed)}")


def synchronize_bundle(source: Path, destination: Path, mode: str) -> None:
    """Atomically replace the packaged BibleView resource with a validated generated tree.

    The source is validated before any destination mutation. A temporary sibling copy is promoted
    only after it also validates, while an existing destination is retained as a rollback backup
    until promotion succeeds. Filesystem errors raise normally; rollback restores the previous
    destination whenever replacement fails.
    """
    validate_bundle(source, mode)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary_root = Path(tempfile.mkdtemp(prefix=".bibleview-bundle-", dir=destination.parent))
    replacement = temporary_root / destination.name
    backup = destination.with_name(f".{destination.name}.backup-{uuid.uuid4().hex}")
    moved_existing = False
    try:
        shutil.copytree(source, replacement)
        validate_bundle(replacement, mode)
        if destination.exists():
            destination.rename(backup)
            moved_existing = True
        replacement.rename(destination)
    except Exception:
        if destination.exists() and moved_existing:
            shutil.rmtree(destination)
        if moved_existing and backup.exists():
            backup.rename(destination)
        raise
    finally:
        shutil.rmtree(temporary_root, ignore_errors=True)
        if backup.exists():
            shutil.rmtree(backup, ignore_errors=True)


def archive_bibleview_bundle(archive: Path) -> Path:
    """Resolve the single packaged BibleView resource directory in an Xcode archive.

    The input archive is inspected without mutation. Exactly one application and one nested
    ``bibleview-js/index.html`` resource must exist. Missing or ambiguous products raise
    ``BundleContractError`` so archive validation cannot accidentally inspect an unrelated copy.
    """
    applications = sorted((archive / "Products" / "Applications").glob("*.app"))
    if len(applications) != 1:
        raise BundleContractError(f"archive must contain exactly one app: {archive}")
    candidates = sorted(
        path.parent
        for path in applications[0].rglob("index.html")
        if path.parent.name == "bibleview-js"
    )
    if len(candidates) != 1:
        raise BundleContractError(
            f"archive must contain exactly one BibleView bundle, found {len(candidates)}: {archive}"
        )
    return candidates[0]


def verify_archive_bundle(archive: Path, expected: Path) -> None:
    """Require an archive to embed the exact validated production bundle.

    The expected build and archive are read without mutation. The embedded resource is resolved by
    structure and compared byte-for-byte, catching SwiftPM resource-cache or build-order drift.
    Missing resources and byte differences raise ``BundleContractError``.
    """
    compare_bundles(expected, archive_bibleview_bundle(archive), "production")


def build_parser() -> argparse.ArgumentParser:
    """Create the command-line contract for bundle validation and synchronization.

    No filesystem work occurs while constructing the parser. The returned parser rejects unknown
    commands and missing paths through standard argparse errors.
    """
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate = subparsers.add_parser("validate", help="validate one generated bundle")
    validate.add_argument("--bundle", type=Path, required=True)
    validate.add_argument("--mode", choices=("production", "debug"), required=True)

    compare = subparsers.add_parser("compare", help="compare two generated bundles")
    compare.add_argument("--expected", type=Path, required=True)
    compare.add_argument("--actual", type=Path, required=True)
    compare.add_argument("--mode", choices=("production", "debug"), required=True)

    sync = subparsers.add_parser("sync", help="replace a packaged resource bundle")
    sync.add_argument("--source", type=Path, required=True)
    sync.add_argument("--destination", type=Path, required=True)
    sync.add_argument("--mode", choices=("production", "debug"), required=True)

    archive = subparsers.add_parser("verify-archive", help="inspect a packaged Xcode archive")
    archive.add_argument("--archive", type=Path, required=True)
    archive.add_argument("--expected", type=Path, required=True)
    return parser


def main() -> int:
    """Execute one bundle operation and return a CI-friendly process status.

    Parsed paths are read and ``sync`` may atomically replace its destination. Contract or filesystem
    failures are printed once to stderr and return status 1; successful commands print the resulting
    bundle digest and return 0.
    """
    args = build_parser().parse_args()
    try:
        if args.command == "validate":
            validate_bundle(args.bundle, args.mode)
            digest_root = args.bundle
        elif args.command == "compare":
            compare_bundles(args.expected, args.actual, args.mode)
            digest_root = args.actual
        elif args.command == "sync":
            synchronize_bundle(args.source, args.destination, args.mode)
            digest_root = args.destination
        else:
            verify_archive_bundle(args.archive, args.expected)
            digest_root = archive_bibleview_bundle(args.archive)
    except (BundleContractError, OSError) as exc:
        print(f"BibleView bundle contract failed: {exc}", file=sys.stderr)
        return 1
    print(f"BibleView bundle contract passed: {bundle_digest(digest_root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
