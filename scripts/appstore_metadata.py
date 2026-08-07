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

import dataclasses
import hashlib
import json
import os
import re
import unicodedata
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


def _is_cjk_character(char: str) -> bool:
    """True for a Han ideograph, kana, or CJK punctuation character.

    Deliberately EXCLUDES Hangul (Jamo U+1100-U+11FF, Compatibility Jamo
    U+3130-U+318F, Syllables U+AC00-U+D7A3): Korean uses spaces between words
    like other space-delimited languages, so a space between two Hangul
    syllables is a normal word space, not a folding artifact, and must not be
    treated as CJK for this rule.
    """
    code = ord(char)
    return (
        0x3040 <= code <= 0x30FF  # Hiragana, Katakana
        or 0x3400 <= code <= 0x4DBF  # CJK Unified Ideographs Extension A
        or 0x4E00 <= code <= 0x9FFF  # CJK Unified Ideographs
        or 0xF900 <= code <= 0xFAFF  # CJK Compatibility Ideographs
        or 0x3000 <= code <= 0x303F  # CJK Symbols and Punctuation (、。「」etc.)
    )


def find_cjk_adjacent_spaces(text: str) -> list[int]:
    """Return the index of every space with a CJK character on both sides.

    A YAML folded scalar (`key: >`) turns every internal line break into a
    single space. That is an invisible, correct word space in space-delimited
    languages - it lands exactly where a word space belongs - but Japanese and
    Chinese have no inter-word spaces, so a space with CJK on both sides is
    always a folding artifact, never intentional text. A space next to a
    Latin character (e.g. "AI 探索", a recommended Chinese typographic
    convention at a Latin/CJK boundary) has a non-CJK neighbour and does not
    match; neither does a space between two Thai or Hangul characters, since
    neither script is treated as CJK by `_is_cjk_character`.
    """
    return [
        index
        for index, char in enumerate(text)
        if char == " "
        and 0 < index < len(text) - 1
        and _is_cjk_character(text[index - 1])
        and _is_cjk_character(text[index + 1])
    ]


# Zero-width characters that are always an artifact in store copy, never
# meaningful. Deliberately NOT including U+200C/U+200D (ZWNJ/ZWJ): those are
# real letters-joining controls in Persian, Hindi and Arabic script, and
# stripping them would corrupt words rather than clean them up.
ZERO_WIDTH_CHARACTERS = "\u200b\ufeff"

# Whitespace App Store Connect accepts. Newlines are only ever meaningful in
# `description`, but no field is harmed by allowing them here.
PLAIN_WHITESPACE = " \n"


def normalize_whitespace(text: str) -> str:
    """Fold every exotic space into a plain one and drop zero-width characters.

    App Store Connect rejects an upload outright when a field carries anything
    but ordinary whitespace ("'name' must not contain invalid whitespace
    characters"), and `deliver` is not atomic - a rejection part-way through
    leaves the live listing half-written. Both sources of this are upstream, in
    the Android translations that this pipeline only reads: French typography
    puts U+202F NARROW NO-BREAK SPACE before a colon ("AndBible : Bible
    Study"), and machine-assisted Portuguese carries stray U+200B ZERO WIDTH
    SPACE mid-sentence. A plain space reads identically in every storefront, so
    normalising is preferable to failing the render and blocking a release on a
    translation nobody here maintains.

    U+3000 IDEOGRAPHIC SPACE is folded too. It is legitimate CJK typography in
    prose, but in a store field it is far more often an artifact - and folding
    it means `find_cjk_adjacent_spaces` sees it and reports it, rather than it
    shipping unexamined.
    """
    characters = []
    for char in text:
        if char in PLAIN_WHITESPACE:
            characters.append(char)
        elif char in ZERO_WIDTH_CHARACTERS:
            continue
        elif char.isspace() or unicodedata.category(char) == "Zs":
            characters.append(" ")
        else:
            characters.append(char)
    return "".join(characters)


def find_invalid_whitespace(text: str) -> list[tuple[int, str]]:
    """Return every (index, character) Apple would reject as whitespace.

    A backstop behind `normalize_whitespace`: if a future exotic character slips
    past the fold, this fails the offline render rather than the live upload.
    """
    return [
        (index, char)
        for index, char in enumerate(text)
        if char not in PLAIN_WHITESPACE
        and (
            char.isspace()
            or char in ZERO_WIDTH_CHARACTERS
            or unicodedata.category(char) == "Zs"
        )
    ]


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
        for index in find_cjk_adjacent_spaces(value):
            problems.append(
                f"{apple_locale}/{field}: space between CJK characters at "
                f"index {index} (likely a YAML fold artifact - see Defect 1)"
            )
        for index, char in find_invalid_whitespace(value):
            problems.append(
                f"{apple_locale}/{field}: U+{ord(char):04X} at index {index} "
                "(App Store Connect rejects non-plain whitespace)"
            )
    return problems


LOCALE_FIELD_FILES = {
    "name": "name.txt",
    "subtitle": "subtitle.txt",
    "description": "description.txt",
    "keywords": "keywords.txt",
    "promotional_text": "promotional_text.txt",
    "support_url": "support_url.txt",
    "marketing_url": "marketing_url.txt",
    "privacy_url": "privacy_url.txt",
}

# The App Store locale that release notes are written in. "What's New" is
# deliberately NOT localised: it describes one release, is rewritten for the
# next one, and would sit stale in the other 33 locales long before a
# translator saw it. App Store Connect shows the primary locale's text in a
# storefront whose localisation has none, so English-only degrades cleanly.
RELEASE_NOTES_LOCALE = "en-US"

# Rendered into RELEASE_NOTES_LOCALE only, and only when there is text to
# render: a blank appstore/release_notes.txt emits no release_notes file
# anywhere, which is what a first release wants - there is no previous version
# for "What's New" to describe, and App Store Connect rejects release notes on
# an app's very first version.
ENGLISH_ONLY_FIELD_FILES = {
    "release_notes": "release_notes.txt",
}

APP_LEVEL_FILES = {
    "copyright": "copyright.txt",
    "primary_category": "primary_category.txt",
    "secondary_category": "secondary_category.txt",
}

IOS_ONLY_FIELDS = ("subtitle", "keywords", "promotional_text")

# The review_information keys `deliver` actually recognises. render_tree emits
# review_information/{name}.txt for ANY key present in review_information.yml
# (public) or review_information.local.yml (gitignored, personal data), with
# no allowlist of its own - a typo like `email` instead of `email_address`
# would otherwise render a file deliver silently ignores, so the reviewer
# never gets that contact detail and nothing reports the mistake.
REVIEW_INFORMATION_KEYS = (
    "first_name",
    "last_name",
    "phone_number",
    "email_address",
    "demo_user",
    "demo_password",
    "demo_required",
    "notes",
)


@dataclass(frozen=True)
class LoadedSources:
    """Every input the renderer needs, already read from disk."""

    locale_config: LocaleConfig
    constants: Mapping[str, str]
    android_master: Mapping[str, str]
    android_translations: Mapping[str, Mapping[str, str]]
    ios_source: Mapping[str, str]
    ios_translations: Mapping[str, Mapping[str, str]]
    template: str
    app_info: Mapping[str, str]
    release_notes: str
    review_information: Mapping[str, str]


def replace_sources(sources: LoadedSources, **changes: object) -> LoadedSources:
    """Return a copy of `sources` with the named fields replaced (test helper)."""
    return dataclasses.replace(sources, **changes)


REVIEW_INFORMATION_LOCAL_FILE = "review_information.local.yml"


def merge_review_information(
    public: Mapping[str, str], local: Mapping[str, str]
) -> dict[str, str]:
    """Overlay local reviewer contact details on the committed public notes.

    The contact details are personal data and live in a gitignored file. When it
    is absent the contact fields are simply not emitted, and deliver leaves
    whatever App Store Connect already holds.
    """
    return merge_layers(public, local)


def load_sources(android_root: Path, appstore_root: Path) -> LoadedSources:
    """Read every source file. The Android checkout is only ever read."""
    play = android_root / "play"
    locale_config = load_locale_config(appstore_root / "locales.yml")
    translations_dir = play / "description-translations"
    android_translations = {
        play_locale: load_yaml_mapping(translations_dir / f"{play_locale}.yml")
        for play_locale, _ in locale_config.mappings
    }
    ios_translations_dir = appstore_root / "ios_translations"
    ios_translations = {
        apple_locale: load_yaml_mapping(ios_translations_dir / f"{apple_locale}.yml")
        for _, apple_locale in locale_config.mappings
        if (ios_translations_dir / f"{apple_locale}.yml").is_file()
    }
    return LoadedSources(
        locale_config=locale_config,
        constants=load_yaml_mapping(play / "constants.yml"),
        android_master=load_yaml_mapping(play / "playstore-description.yml"),
        android_translations=android_translations,
        ios_source=load_yaml_mapping(appstore_root / "ios_source.yml"),
        ios_translations=ios_translations,
        template=(appstore_root / "description_template.txt").read_text(
            encoding="utf-8"
        ),
        app_info=load_yaml_mapping(appstore_root / "app_info.yml"),
        release_notes=(appstore_root / "release_notes.txt").read_text(
            encoding="utf-8"
        ),
        review_information=merge_review_information(
            load_yaml_mapping(appstore_root / "review_information.yml"),
            load_yaml_mapping(appstore_root / REVIEW_INFORMATION_LOCAL_FILE)
            if (appstore_root / REVIEW_INFORMATION_LOCAL_FILE).is_file()
            else {},
        ),
    )


def build_locale_fields(
    sources: LoadedSources, play_locale: str, apple_locale: str
) -> dict[str, str]:
    """Render one locale's App Store fields.

    Merge order, later winning: constants, Android master, Android translation,
    iOS source, iOS translation.
    """
    variables = resolve_variables(
        merge_layers(
            sources.constants,
            sources.android_master,
            sources.android_translations.get(play_locale, {}),
            sources.ios_source,
            {
                key: value
                for key, value in sources.ios_translations.get(
                    apple_locale, {}
                ).items()
                if key != SOURCE_SHA_KEY
            },
        )
    )
    fields = {
        "name": variables["title"],
        "description": expand_placeholders(sources.template, variables).strip(),
        "support_url": sources.app_info["support_url"],
        "marketing_url": sources.app_info["marketing_url"],
        "privacy_url": sources.app_info["privacy_url"],
    }
    for field in IOS_ONLY_FIELDS:
        fields[field] = variables[field]
    if apple_locale == RELEASE_NOTES_LOCALE and sources.release_notes.strip():
        fields["release_notes"] = sources.release_notes.strip()
    return {
        field: normalize_whitespace(
            apply_platform_substitutions(value, apple_locale, sources.locale_config)
        )
        for field, value in fields.items()
    }


def render_tree(sources: LoadedSources) -> dict[str, str]:
    """Render the whole `fastlane/metadata` tree as relative path to content."""
    tree: dict[str, str] = {}
    for play_locale, apple_locale in sources.locale_config.mappings:
        fields = build_locale_fields(sources, play_locale, apple_locale)
        for field, filename in LOCALE_FIELD_FILES.items():
            tree[f"{apple_locale}/{filename}"] = fields[field] + "\n"
        for field, filename in ENGLISH_ONLY_FIELD_FILES.items():
            if field in fields:
                tree[f"{apple_locale}/{filename}"] = fields[field] + "\n"
    for key, filename in APP_LEVEL_FILES.items():
        tree[filename] = sources.app_info[key].strip() + "\n"
    for name, value in sources.review_information.items():
        tree[f"review_information/{name}.txt"] = value.strip() + "\n"
    return tree


def validate_review_information_keys(sources: LoadedSources) -> list[str]:
    """Reject review_information keys that `deliver` does not recognise.

    Mirrors validate_translation_keys: a misspelt key (e.g. `email` for
    `email_address`) would otherwise render into the tree and be silently
    dropped by `deliver`, with nothing to notice.
    """
    unknown = sorted(set(sources.review_information) - set(REVIEW_INFORMATION_KEYS))
    return [
        f"review_information: unknown key {key!r} (deliver does not recognise it)"
        for key in unknown
    ]


def validate_app_level_fields(sources: LoadedSources) -> list[str]:
    """Validate the app-level rendered output the same way a locale field is.

    `copyright.txt` (public listing metadata) and `review_information/notes.txt`
    (reviewer-facing prose) are the only free-text app-level output; both can
    carry a forbidden platform reference or an unresolved template placeholder
    just as easily as a translated locale field can, but validate_tree never
    looked at them before this.
    """
    fields = {"copyright": sources.app_info["copyright"]}
    if "notes" in sources.review_information:
        fields["notes"] = sources.review_information["notes"]
    return validate_fields("app-level", fields)


def validate_tree(sources: LoadedSources) -> list[str]:
    """Validate every locale. Returns every problem, not just the first."""
    problems: list[str] = validate_translation_keys(sources)
    problems.extend(validate_review_information_keys(sources))
    problems.extend(validate_app_level_fields(sources))
    for play_locale, apple_locale in sources.locale_config.mappings:
        fields = build_locale_fields(sources, play_locale, apple_locale)
        problems.extend(validate_fields(apple_locale, fields))
    return problems


def missing_translation_locales(sources: LoadedSources) -> list[str]:
    """Apple locales with no iOS translation file, which fall back to English."""
    return sorted(
        apple_locale
        for _, apple_locale in sources.locale_config.mappings
        if apple_locale not in sources.ios_translations
    )


def _existing_files(output_root: Path) -> set[str]:
    if not output_root.is_dir():
        return set()
    return {
        str(path.relative_to(output_root))
        for path in output_root.rglob("*")
        if path.is_file()
    }


def compare_tree(tree: Mapping[str, str], output_root: Path) -> list[str]:
    """Describe every difference between the rendered tree and the one on disk."""
    problems: list[str] = []
    existing = _existing_files(output_root)
    for relative_path in sorted(set(tree) - existing):
        problems.append(f"missing: {relative_path}")
    for relative_path in sorted(existing - set(tree)):
        problems.append(f"stale: {relative_path}")
    for relative_path in sorted(set(tree) & existing):
        on_disk = (output_root / relative_path).read_text(encoding="utf-8")
        if on_disk != tree[relative_path]:
            problems.append(f"changed: {relative_path}")
    return problems


def write_tree(tree: Mapping[str, str], output_root: Path) -> None:
    """Write the rendered tree, deleting files it no longer contains."""
    for relative_path in sorted(_existing_files(output_root) - set(tree)):
        (output_root / relative_path).unlink()
    for relative_path, content in sorted(tree.items()):
        target = output_root / relative_path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")


SOURCE_SHA_KEY = "source_sha"


def ios_source_digest(ios_source: Mapping[str, str]) -> str:
    """A stable digest of the English iOS copy, used to detect stale translations.

    Serialized as sorted JSON so the digest is independent of key order and
    cannot be confused by a value that happens to contain the separator.
    """
    payload = json.dumps(
        {
            key: value.strip()
            for key, value in ios_source.items()
            if key != SOURCE_SHA_KEY
        },
        sort_keys=True,
        ensure_ascii=False,
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def stale_translation_locales(sources: LoadedSources) -> list[str]:
    """Locales whose translation was made against an older English source."""
    digest = ios_source_digest(sources.ios_source)
    return sorted(
        apple_locale
        for apple_locale, translation in sources.ios_translations.items()
        if translation.get(SOURCE_SHA_KEY) != digest
    )


def validate_translation_keys(sources: LoadedSources) -> list[str]:
    """Reject translation keys that do not exist in the English iOS source.

    A misspelt key is otherwise invisible: it never reaches the listing and the
    English text ships in its place, with nothing to notice.
    """
    known = set(sources.ios_source) | {SOURCE_SHA_KEY}
    problems: list[str] = []
    for apple_locale, translation in sorted(sources.ios_translations.items()):
        for key in sorted(set(translation) - known):
            problems.append(
                f"{apple_locale}: unknown key {key!r} (not in ios_source.yml)"
            )
    return problems
