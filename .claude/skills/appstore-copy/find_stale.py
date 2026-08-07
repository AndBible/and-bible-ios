#!/usr/bin/env python3
"""List App Store locales whose iOS copy is missing or out of date.

Prints one locale per line, prefixed with its reason, so the caller can dispatch
one translation agent per line. Pass --digest to print the English source's
current digest instead - the value every translation file must record as
source_sha.
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import appstore_metadata as meta


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

    if "--digest" in sys.argv:
        print(meta.ios_source_digest(sources.ios_source))
        return 0

    for locale in meta.missing_translation_locales(sources):
        print(f"missing {locale}")
    for locale in meta.stale_translation_locales(sources):
        print(f"stale {locale}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
