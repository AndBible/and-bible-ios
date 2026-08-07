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
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

import yaml

PLACEHOLDER_PATTERN = re.compile(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}")
MAX_EXPANSION_PASSES = 8

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


def expand_placeholders(text: str, variables: Mapping[str, str]) -> str:
    """Replace `{{ name }}` references, repeatedly, until the text settles.

    An unknown name is left verbatim rather than blanked, so the validator can
    report it as an unresolved placeholder instead of silently shipping a gap.
    """
    current = text
    for _ in range(MAX_EXPANSION_PASSES):
        expanded = PLACEHOLDER_PATTERN.sub(
            lambda match: variables.get(match.group(1), match.group(0)), current
        )
        if expanded == current:
            return current
        current = expanded
    raise ValueError(f"Placeholder expansion did not converge: {text!r}")


def load_yaml_mapping(path: Path) -> dict[str, str]:
    """Read a flat `key: value` YAML file into a string mapping."""
    raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if not isinstance(raw, dict):
        raise ValueError(f"{path} must contain a mapping")
    return {str(key): str(value) for key, value in raw.items() if value is not None}


def merge_layers(*layers: Mapping[str, str]) -> dict[str, str]:
    """Overlay mappings, later layers winning. Blank values do not override.

    A translator who leaves a key empty should fall back to English rather than
    blank the line, which is how the Android renderer behaves too.
    """
    merged: dict[str, str] = {}
    for layer in layers:
        merged.update(
            {key: value for key, value in layer.items() if value.strip()}
        )
    return merged


def resolve_variables(raw: Mapping[str, str]) -> dict[str, str]:
    """Expand every value against every other value."""
    stripped = {key: value.strip() for key, value in raw.items()}
    return {
        key: expand_placeholders(value, stripped) for key, value in stripped.items()
    }


FIELD_LIMITS = {
    "name": 30,
    "subtitle": 30,
    "keywords": 100,
    "promotional_text": 170,
    "description": 4000,
    "release_notes": 4000,
}

# App Store Review Guideline 2.3.10: no other-platform names in metadata.
FORBIDDEN_SUBSTRINGS = ("android", "google play", "play store")


def validate_fields(apple_locale: str, fields: Mapping[str, str]) -> list[str]:
    """Return every problem found in one locale's fields.

    Lengths are character counts, not byte counts: a Telugu description is
    roughly three bytes per character and a byte-based limit would reject
    perfectly valid copy.
    """
    problems: list[str] = []
    for field, value in sorted(fields.items()):
        limit = FIELD_LIMITS.get(field)
        if limit is not None and len(value) > limit:
            problems.append(
                f"{apple_locale}/{field}: {len(value)} characters, limit {limit}"
            )
        lowered = value.lower()
        for forbidden in FORBIDDEN_SUBSTRINGS:
            if forbidden in lowered:
                problems.append(
                    f"{apple_locale}/{field}: forbidden platform reference "
                    f"{forbidden!r}"
                )
        if "{{" in value or "}}" in value:
            problems.append(
                f"{apple_locale}/{field}: unresolved template placeholder"
            )
    return problems
