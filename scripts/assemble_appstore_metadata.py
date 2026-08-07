#!/usr/bin/env python3
"""Generate the App Store Connect metadata tree, or check it for drift.

The Android repository supplies the description prose and its translations; the
appstore/ directory supplies the iOS overrides and the App Store-only fields.
This script renders the two into fastlane/metadata/.

    python3 scripts/assemble_appstore_metadata.py           # write the tree
    python3 scripts/assemble_appstore_metadata.py --check    # fail on drift

The Android checkout is only ever read. This script deliberately does not call
scripts/ensure_android_reference_checkout.sh, which detaches HEAD and refuses a
dirty tree - fine for CI, destructive for a developer's working copy.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import appstore_metadata as meta

REPO_ROOT = Path(__file__).resolve().parent.parent
APPSTORE_ROOT = REPO_ROOT / "appstore"
OUTPUT_ROOT = REPO_ROOT / "fastlane" / "metadata"
LOCK_FILE = APPSTORE_ROOT / "android_source.lock"


def head_sha(repository: Path) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository), "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip()


def is_dirty(repository: Path) -> bool:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository), "status", "--porcelain"],
            capture_output=True,
            text=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return False
    return bool(result.stdout.strip())


def read_lock() -> str | None:
    if not LOCK_FILE.is_file():
        return None
    for line in LOCK_FILE.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            return stripped
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Compare against the committed tree and fail on drift; write nothing.",
    )
    parser.add_argument(
        "--require-pinned",
        action="store_true",
        help="Fail if the Android checkout is not at the SHA in android_source.lock.",
    )
    parser.add_argument(
        "--android-root",
        help=(
            "Path to the and-bible checkout. Default: $ANDBIBLE_ANDROID_ROOT, "
            "then .and-bible-android/, then ../and-bible."
        ),
    )
    args = parser.parse_args()

    android_root = meta.resolve_android_root(REPO_ROOT, args.android_root)
    if android_root is None:
        print(
            "No Android store copy found. Clone AndBible/and-bible into "
            ".and-bible-android/, or pass --android-root.",
            file=sys.stderr,
        )
        return 2

    locked = read_lock()
    actual = head_sha(android_root)
    if args.require_pinned and locked is None:
        print(
            f"{LOCK_FILE} is missing or has no commit SHA; --require-pinned "
            "has nothing to pin against.",
            file=sys.stderr,
        )
        return 2
    pinned = locked is not None and actual is not None and locked == actual
    if not pinned and locked is not None:
        message = (
            f"Android checkout is at {actual}, android_source.lock says {locked}. "
            "Any drift reported below is most likely caused by this."
        )
        if args.require_pinned:
            print(message, file=sys.stderr)
            return 2
        print(f"warning: {message}", file=sys.stderr)

    sources = meta.load_sources(android_root, APPSTORE_ROOT)

    problems = meta.validate_tree(sources)
    if problems:
        print("Metadata validation failed:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    missing = meta.missing_translation_locales(sources)
    if missing:
        print(
            f"note: {len(missing)} locale(s) fall back to English: "
            + ", ".join(missing),
            file=sys.stderr,
        )

    tree = meta.render_tree(sources)

    if args.check:
        drift = meta.compare_tree(tree, OUTPUT_ROOT)
        if drift:
            print("Generated metadata differs from the committed tree:", file=sys.stderr)
            for entry in drift:
                print(f"  {entry}", file=sys.stderr)
            print(
                "Run: python3 scripts/assemble_appstore_metadata.py",
                file=sys.stderr,
            )
            return 1
        print(f"Metadata is up to date ({len(tree)} files).")
        return 0

    meta.write_tree(tree, OUTPUT_ROOT)
    if actual:
        if is_dirty(android_root):
            print(
                "warning: android_source.lock left unchanged - the Android "
                "checkout has uncommitted changes, so the SHA would not "
                "describe what was just rendered.",
                file=sys.stderr,
            )
        else:
            LOCK_FILE.write_text(
                "# Commit in AndBible/and-bible that the committed App Store metadata\n"
                "# was generated from. CI checks out exactly this SHA.\n"
                f"{actual}\n",
                encoding="utf-8",
            )
    print(f"Wrote {len(tree)} files to {OUTPUT_ROOT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
