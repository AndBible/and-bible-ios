#!/usr/bin/env python3
"""Report which locales still ship the English "What's New" text.

    python3 scripts/appstore_release_notes.py            # status
    python3 scripts/appstore_release_notes.py --digest   # source_sha to record
    python3 scripts/appstore_release_notes.py --list     # bare locale list

appstore/release_notes.txt is the English master. A locale's translation lives in
appstore/release_notes_translations/<apple-locale>.yml and is used only while its
source_sha matches the current English text; otherwise that locale ships English.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import appstore_metadata as meta

REPO_ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    android_root = meta.resolve_android_root(REPO_ROOT)
    if android_root is None:
        print(
            "No Android store copy found. Clone AndBible/and-bible into "
            ".and-bible-android/.",
            file=sys.stderr,
        )
        return 2
    sources = meta.load_sources(android_root, REPO_ROOT / "appstore")
    english = sources.release_notes.strip()

    if "--digest" in sys.argv:
        print(meta.release_notes_digest(english))
        return 0

    todo = meta.untranslated_release_notes_locales(sources)
    if "--list" in sys.argv:
        print("\n".join(todo))
        return 0

    if not english:
        print("appstore/release_notes.txt is empty: no What's New will be uploaded.")
        return 0
    total = len(sources.locale_config.mappings)
    print(f"Release notes digest: {meta.release_notes_digest(english)}")
    if todo:
        print(
            f"{len(todo)} of {total - 1} non-English locales would ship English; "
            "translate them with the appstore-copy skill (release notes section):"
        )
        print("  " + " ".join(todo))
    else:
        print(f"All {total} locales have current release notes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
