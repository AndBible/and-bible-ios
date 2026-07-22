#!/usr/bin/env python3
"""Generate the iOS Speak divine-name catalog from Android string arrays.

Android resolves each array resource independently after replacing the active resource locale with
the source document language. Missing locale arrays inherit the English base array, while an
explicitly empty locale array remains empty. The generated JSON records those resolved arrays so
iOS command synthesis can reproduce that behavior without shipping Android XML parsing code.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


ARRAY_NAMES = ("speak_divinename_original", "speak_divinename_replace")

# Android constructs Locale(book.language.code), so resource selection is language-based. Legacy
# Android language aliases and BCP-47 resource directories are mapped to the language identifiers
# iOS receives from SWORD modules.
LANGUAGE_TO_ANDROID_VALUES = {
    "af": "values-af",
    "ar": "values-ar",
    "az": "values-az",
    "bg": "values-bg",
    "bn": "values-bn",
    "ca": "values-ca",
    "cs": "values-cs",
    "da": "values-da",
    "de": "values-de",
    "el": "values-el",
    "en": "values",
    "eo": "values-eo",
    "es": "values-es",
    "et": "values-et",
    "fi": "values-fi",
    "fil": "values-fil",
    "fr": "values-fr",
    "he": "values-iw",
    "hi": "values-hi",
    "hr": "values-hr",
    "hu": "values-hu",
    "id": "values-id",
    "it": "values-it",
    "ja": "values-ja",
    "kk": "values-kk",
    "ko": "values-ko",
    "lt": "values-lt",
    "ml": "values-ml",
    "ms": "values-ms",
    "my": "values-my",
    "nb": "values-nb",
    "ne": "values-ne",
    "nl": "values-nl",
    "pl": "values-pl",
    "pt": "values-pt",
    "ro": "values-ro",
    "ru": "values-ru",
    "sk": "values-sk",
    "sl": "values-sl",
    "sr": "values-b+sr",
    "sv": "values-sv",
    "sw": "values-sw",
    "ta": "values-ta",
    "te": "values-te",
    "th": "values-th",
    "tr": "values-tr",
    "uk": "values-uk",
    "ur": "values-ur",
    "uz": "values-uz",
    "vi": "values-vi",
    "yue": "values-yue",
    "zh": "values-zh",
}


def default_repo_root() -> Path:
    """Return the repository root containing this generator."""
    return Path(__file__).resolve().parents[1]


def default_android_root() -> Path:
    """Return the conventional sibling Android resource directory."""
    return default_repo_root().parent / "and-bible" / "app" / "src" / "main" / "res"


def parse_arrays(path: Path) -> dict[str, list[str]]:
    """Read only the two Speak arrays from one Android XML resource file.

    Missing array resources are omitted from the result; explicitly empty arrays are represented by
    an empty list so callers can distinguish Android inheritance from an intentional empty override.
    """
    if not path.exists():
        return {}
    root = ET.parse(path).getroot()
    result: dict[str, list[str]] = {}
    for node in root.findall("string-array"):
        name = node.get("name")
        if name in ARRAY_NAMES:
            result[name] = ["".join(item.itertext()) for item in node.findall("item")]
    return result


def build_catalog(android_root: Path) -> dict[str, object]:
    """Build deterministic language entries with Android's per-array fallback behavior.

    - Parameter android_root: Android `app/src/main/res` directory.
    - Returns: JSON-compatible generated catalog.
    - Side effects: Reads Android XML resources.
    - Failure modes: Raises when the English source arrays are absent.
    """
    base = parse_arrays(android_root / "values" / "strings.xml")
    missing = [name for name in ARRAY_NAMES if name not in base]
    if missing:
        raise ValueError(f"Android base Speak arrays missing: {', '.join(missing)}")

    languages: dict[str, object] = {}
    for language, qualifier in sorted(LANGUAGE_TO_ANDROID_VALUES.items()):
        localized = parse_arrays(android_root / qualifier / "strings.xml")
        languages[language] = {
            "resourceQualifier": qualifier,
            "original": localized.get(ARRAY_NAMES[0], base[ARRAY_NAMES[0]]),
            "replacement": localized.get(ARRAY_NAMES[1], base[ARRAY_NAMES[1]]),
        }

    return {
        "schemaVersion": 1,
        "sourceAndroidRes": "app/src/main/res",
        "default": {
            "resourceQualifier": "values",
            "original": base[ARRAY_NAMES[0]],
            "replacement": base[ARRAY_NAMES[1]],
        },
        "languages": languages,
    }


def encoded_catalog(catalog: dict[str, object]) -> bytes:
    """Return stable UTF-8 JSON bytes for one generated catalog."""
    return (json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def main() -> int:
    """Generate or verify the committed resource and report drift through the process status."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--android-root", type=Path, default=default_android_root())
    parser.add_argument(
        "--output",
        type=Path,
        default=default_repo_root()
        / "Sources"
        / "BibleCore"
        / "Sources"
        / "BibleCore"
        / "Resources"
        / "speak"
        / "divine-name-replacements.json",
    )
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    expected = encoded_catalog(build_catalog(args.android_root))
    if args.check:
        if not args.output.exists() or args.output.read_bytes() != expected:
            print(f"Speak divine-name catalog is stale: {args.output}", file=sys.stderr)
            return 1
        print(f"Speak divine-name catalog is current: {args.output}")
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(expected)
    print(f"Wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
