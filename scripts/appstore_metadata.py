"""Assemble App Store Connect metadata from the Android store copy plus iOS overrides.

The Android repository is the source of truth for the description prose: it holds
an English master and human translations maintained through Transifex. This module
merges those sources with an iOS override layer and renders the per-locale files
that `fastlane deliver` uploads.

Everything here is pure: loading returns data, rendering returns a mapping of
relative path to file content. The CLI (`assemble_appstore_metadata.py`) is the
only part that touches the output tree.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

import yaml

# Where the Android store copy might be. CLAUDE.md forbids hard-coding a sibling
# path, and names `.and-bible-android/` as the documented local location; the
# `../and-bible` fallback matches scripts/ensure_android_reference_checkout.sh,
# which is what .github/workflows/ios-ci.yml already uses.
ANDROID_ROOT_CANDIDATES = (".and-bible-android", "../and-bible")


def resolve_android_root(
    repo_root: Path, explicit: str | None = None
) -> Path | None:
    """Locate a readable Android checkout, or None if there is none.

    Order: explicit argument, $ANDBIBLE_ANDROID_ROOT, then the candidates above.
    A candidate counts only if it actually holds the store copy, so a stale empty
    directory does not shadow a real checkout.
    """
    candidates: list[str] = []
    if explicit:
        candidates.append(explicit)
    from_environment = os.environ.get("ANDBIBLE_ANDROID_ROOT")
    if from_environment:
        candidates.append(from_environment)
    candidates.extend(ANDROID_ROOT_CANDIDATES)

    for candidate in candidates:
        path = Path(candidate).expanduser()
        if not path.is_absolute():
            path = repo_root / path
        if (path / "play" / "constants.yml").is_file():
            return path.resolve()
    return None


@dataclass(frozen=True)
class Substitution:
    """A literal text replacement applied to rendered copy."""

    source: str
    target: str


@dataclass(frozen=True)
class LocaleConfig:
    """The Play-to-Apple locale map and the platform-name rewrite rules."""

    mappings: tuple[tuple[str, str], ...]
    default_substitutions: tuple[Substitution, ...]
    locale_substitutions: Mapping[str, tuple[Substitution, ...]]


def _parse_substitutions(items: object) -> tuple[Substitution, ...]:
    if not items:
        return ()
    if not isinstance(items, list):
        raise ValueError("platform_substitutions entries must be lists")
    return tuple(
        Substitution(str(item["from"]), str(item["to"])) for item in items
    )


def load_locale_config(path: Path) -> LocaleConfig:
    """Read `locales.yml`."""
    raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    mappings = tuple(
        (str(play), str(apple))
        for play, apple in (raw.get("mappings") or {}).items()
    )
    substitutions = raw.get("platform_substitutions") or {}
    locale_rules = {
        str(locale): _parse_substitutions(items)
        for locale, items in substitutions.items()
        if locale != "default"
    }
    return LocaleConfig(
        mappings=mappings,
        default_substitutions=_parse_substitutions(substitutions.get("default")),
        locale_substitutions=locale_rules,
    )


def apply_platform_substitutions(
    text: str, apple_locale: str, config: LocaleConfig
) -> str:
    """Rewrite other-platform names, locale-specific rules first.

    Locale rules run before the default rule so that an inflected form
    (Polish "Androida") becomes the spelling that language uses for an
    invariant foreign noun ("iOS-a") instead of the default rule's "iOSa".
    """
    result = text
    for substitution in config.locale_substitutions.get(apple_locale, ()):
        result = result.replace(substitution.source, substitution.target)
    for substitution in config.default_substitutions:
        result = result.replace(substitution.source, substitution.target)
    return result
