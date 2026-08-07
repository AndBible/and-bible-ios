# App Store Metadata Automation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate the App Store Connect text metadata tree for 34 locales from the Android `play/` sources plus an iOS override layer, validate it locally against Apple's field limits and platform-name rule, and push it with `fastlane deliver` — without ever touching screenshots.

**Architecture:** A pure Python library (`scripts/appstore_metadata.py`) turns loaded sources into a `dict` of `relative path → file content`. Everything above it is thin: a CLI writes or diffs that dict, a `Deliverfile` uploads the resulting tree. Because the core is a pure function from data to a path→content map, every rule (merge order, locale mapping, platform substitution, length limits) is unit-testable without touching the filesystem or the network, and `--check` is a dictionary comparison.

**Tech Stack:** Python 3.12 (stdlib + PyYAML), `unittest`, fastlane `deliver`/`precheck`, GNU Make, GitHub Actions.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-07-appstore-metadata-automation-design.md`. Read it before Task 1.
- **Commit messages are enforced** by `scripts/check_repo_standards.py commits`. Every commit uses `<type>(<scope>): <summary>` followed by a body with `Why:`, `What Changed:`, `Validation:`, `Impact:` sections. Every commit step in this plan shows the full message — use it verbatim.
- **Tests are `unittest`, not pytest.** CI runs `python3 -m unittest discover -s scripts -p 'test_*.py'`. All new tests live in `scripts/test_appstore_metadata.py`.
- **PyYAML is the only new Python dependency**, pinned in `scripts/requirements-appstore.txt`. Do not add Jinja2 — the Play templates contain no control structures (verified: `grep -rn "{%" play/` is empty), so a placeholder expander in the library covers them.
- **Never modify the Android checkout.** It is read-only input. Do not invoke `scripts/ensure_android_reference_checkout.sh` from the generator — it detaches HEAD and refuses a dirty tree.
- **Never hard-code a sibling path to the Android repository.** `CLAUDE.md` forbids it: the documented local location is the gitignored `.and-bible-android/` at the repo root. Everything resolves the checkout through `resolve_android_root` (Task 1), which tries `--android-root`, then `$ANDBIBLE_ANDROID_ROOT` (what `ios-ci.yml` already sets), then `.and-bible-android/`, then `../and-bible` (matching the existing `ensure_android_reference_checkout.sh` fallback).
- **Lengths are counted in characters, never bytes.** Python `len()` on a `str` already does this; the tests must prove it with a multi-byte script.
- **Locale count is 34.** `en-GB`, `en-AU`, `en-CA`, `es-MX`, `fr-CA` are deliberately not generated.
- **Field limits:** name 30, subtitle 30, keywords 100, promotional_text 170, description 4000, release_notes 4000.
- **Forbidden substrings in any rendered field** (case-insensitive): `android`, `google play`, `play store`.
- **Copyright string:** `2026 Tuomas Airaksinen, Jared Murrell and the AndBible contributors`
- **URLs:** marketing `https://andbible.org`, support `https://github.com/AndBible/and-bible/wiki/Support`, privacy `https://andbible.org/privacy.html`
- **Categories:** primary `REFERENCE`, secondary `BOOKS`.
- **`skip_screenshots true` in the Deliverfile is load-bearing** — screenshots are uploaded by hand and deliver must not touch them.
- **Tasks 8, 10 and parts of 9 cannot be verified in the Linux dev container.** They are marked `[macOS]` or `[operator]`. Do them, commit them, and say plainly that they are unverified rather than claiming they pass.

---

### Task 1: Locale configuration and platform substitutions

The Play→Apple locale map and the `Android`→`iOS` rewrite, as pure data plus pure functions.

**Files:**
- Create: `scripts/appstore_metadata.py`
- Create: `scripts/test_appstore_metadata.py`
- Create: `scripts/requirements-appstore.txt`
- Create: `appstore/locales.yml`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Substitution(source: str, target: str)` — frozen dataclass
  - `LocaleConfig(mappings: tuple[tuple[str, str], ...], default_substitutions: tuple[Substitution, ...], locale_substitutions: Mapping[str, tuple[Substitution, ...]])` — frozen dataclass; `mappings` entries are `(play_locale, apple_locale)`
  - `load_locale_config(path: Path) -> LocaleConfig`
  - `apply_platform_substitutions(text: str, apple_locale: str, config: LocaleConfig) -> str`
  - `resolve_android_root(repo_root: Path, explicit: str | None = None) -> Path | None`

- [ ] **Step 1: Pin the dependency**

Create `scripts/requirements-appstore.txt`:

```
PyYAML==6.0.3
```

- [ ] **Step 2: Write the failing tests**

Create `scripts/test_appstore_metadata.py`:

```python
"""Unit tests for the App Store metadata assembler."""

import tempfile
import unittest
from pathlib import Path

import appstore_metadata as meta


def write(directory: Path, name: str, content: str) -> Path:
    path = directory / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return path


class LocaleConfigTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def config(self) -> meta.LocaleConfig:
        path = write(
            self.root,
            "locales.yml",
            """
mappings:
  en-US: en-US
  fi-FI: fi
  pl-PL: pl
platform_substitutions:
  default:
    - from: Android
      to: iOS
  pl:
    - from: Androida
      to: iOS-a
""",
        )
        return meta.load_locale_config(path)

    def test_mappings_are_loaded_as_play_apple_pairs(self) -> None:
        config = self.config()
        self.assertIn(("fi-FI", "fi"), config.mappings)

    def test_default_substitution_applies_to_an_unlisted_locale(self) -> None:
        config = self.config()
        result = meta.apply_platform_substitutions(
            "an app for Android", "fi", config
        )
        self.assertEqual(result, "an app for iOS")

    def test_locale_rule_wins_over_the_default_rule(self) -> None:
        config = self.config()
        result = meta.apply_platform_substitutions(
            "aplikacja na Androida", "pl", config
        )
        self.assertEqual(result, "aplikacja na iOS-a")

    def test_substitution_leaves_other_text_untouched(self) -> None:
        config = self.config()
        self.assertEqual(
            meta.apply_platform_substitutions("no platform here", "fi", config),
            "no platform here",
        )


class AndroidRootTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def make_checkout(self, relative: str) -> Path:
        checkout = self.root / "repo" / relative
        write(checkout / "play", "constants.yml", "homepage_url: https://x\n")
        return checkout.resolve()

    def test_prefers_the_gitignored_local_checkout(self) -> None:
        expected = self.make_checkout(".and-bible-android")
        self.make_checkout("../and-bible")
        self.assertEqual(
            meta.resolve_android_root(self.root / "repo"), expected
        )

    def test_falls_back_to_the_sibling_checkout(self) -> None:
        expected = self.make_checkout("../and-bible")
        self.assertEqual(
            meta.resolve_android_root(self.root / "repo"), expected
        )

    def test_an_explicit_path_wins(self) -> None:
        self.make_checkout(".and-bible-android")
        expected = self.make_checkout("../elsewhere")
        self.assertEqual(
            meta.resolve_android_root(self.root / "repo", str(expected)), expected
        )

    def test_returns_none_when_nothing_is_available(self) -> None:
        self.assertIsNone(meta.resolve_android_root(self.root / "repo"))


def android_root_or_skip(test: unittest.TestCase) -> Path:
    """Locate the Android checkout, skipping the test when it is absent."""
    root = meta.resolve_android_root(REPO_ROOT)
    if root is None:
        test.skipTest("Android reference checkout not available")
    return root


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd /path/to/and-bible-ios && python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'appstore_metadata'`.

- [ ] **Step 4: Write the minimal implementation**

Create `scripts/appstore_metadata.py`:

```python
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: 4 tests PASS.

- [ ] **Step 6: Create the real locale map**

Create `appstore/locales.yml`:

```yaml
# Play Store locale -> App Store Connect locale.
#
# Only locales App Store Connect actually supports appear here. The 17 Android
# translations with no App Store equivalent (af, bg, bn-BD, eo, et, fil, kk, lt,
# my-MM, ne-NP, sl, sr, sw, ta-IN, te-IN, ur, yue) are simply absent.
#
# en-GB, en-AU, en-CA, es-MX and fr-CA are deliberately not generated: the App
# Store falls back to en-US / es-ES / fr-FR in those storefronts, so generating
# them would add five identical copies to maintain and nothing else.
mappings:
  ar: ar-SA
  ca: ca
  cs-CZ: cs
  da-DK: da
  de-DE: de-DE
  el-GR: el
  en-US: en-US
  es-ES: es-ES
  fi-FI: fi
  fr-FR: fr-FR
  hi-IN: hi
  hr: hr
  hu-HU: hu
  id: id
  it-IT: it
  iw-IL: he
  ja-JP: ja
  ko-KR: ko
  ms-MY: ms
  nl-NL: nl-NL
  no-NO: "no"
  pl-PL: pl
  pt-BR: pt-BR
  pt-PT: pt-PT
  ro: ro
  ru-RU: ru
  sk: sk
  sv-SE: sv
  th: th
  tr-TR: tr
  uk: uk
  vi: vi
  zh-CN: zh-Hans
  zh-TW: zh-Hant

# App Store Review Guideline 2.3.10 forbids other-platform names in metadata.
# The word occurs exactly once per translation, in paragraph_1_1, and is an
# invariant proper noun in most languages. Locales that inflect it get an
# explicit rule so the result is the hyphenated spelling they actually use.
platform_substitutions:
  default:
    - from: Android
      to: iOS
  hu:
    - from: Androidra
      to: iOS-ra
  pl:
    - from: Androida
      to: iOS-a
  hr:
    - from: Androidu
      to: iOS-u
  sl:
    - from: Androidu
      to: iOS-u
```

Note: `no-NO: "no"` must stay quoted — unquoted `no` is a YAML boolean.

- [ ] **Step 7: Add a test that the real map has 34 entries and no unsupported locale**

Append to `scripts/test_appstore_metadata.py`, above `if __name__`:

```python
REPO_ROOT = Path(__file__).resolve().parent.parent

APPLE_SUPPORTED_LOCALES = {
    "ar-SA", "ca", "cs", "da", "de-DE", "el", "en-AU", "en-CA", "en-GB",
    "en-US", "es-ES", "es-MX", "fi", "fr-CA", "fr-FR", "he", "hi", "hr",
    "hu", "id", "it", "ja", "ko", "ms", "nl-NL", "no", "pl", "pt-BR",
    "pt-PT", "ro", "ru", "sk", "sv", "th", "tr", "uk", "vi", "zh-Hans",
    "zh-Hant",
}


class RealLocaleMapTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = meta.load_locale_config(REPO_ROOT / "appstore" / "locales.yml")

    def test_generates_thirty_four_locales(self) -> None:
        self.assertEqual(len(self.config.mappings), 34)

    def test_every_target_is_an_app_store_locale(self) -> None:
        for _, apple in self.config.mappings:
            self.assertIn(apple, APPLE_SUPPORTED_LOCALES)

    def test_apple_locales_are_unique(self) -> None:
        apple = [apple for _, apple in self.config.mappings]
        self.assertEqual(len(apple), len(set(apple)))

    def test_norwegian_is_a_string_not_a_boolean(self) -> None:
        self.assertIn(("no-NO", "no"), self.config.mappings)

    def test_every_play_locale_has_an_android_translation(self) -> None:
        android = android_root_or_skip(self) / "play" / "description-translations"
        available = {path.stem for path in android.glob("*.yml")}
        for play, _ in self.config.mappings:
            self.assertIn(play, available)
```

- [ ] **Step 8: Run the tests**

Run: `python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: 13 tests PASS (`test_every_play_locale_has_an_android_translation` reports `skipped` when no Android checkout is reachable).

- [ ] **Step 9: Commit**

```bash
git add scripts/appstore_metadata.py scripts/test_appstore_metadata.py \
        scripts/requirements-appstore.txt appstore/locales.yml
git commit -F - <<'EOF'
feat(appstore): map Play locales to App Store locales

Why:
App Store Connect supports a different locale set from Play, and Apple
forbids other-platform names in metadata. Both rules are data, so they
belong in a configuration file rather than in code.

What Changed:
Adds appstore/locales.yml with the 34 Play-to-Apple locale mappings and
the platform-name substitution rules, plus the loader and the
substitution function in scripts/appstore_metadata.py. Locale-specific
rules run before the default rule so inflected forms get the hyphenated
spelling. PyYAML is pinned in scripts/requirements-appstore.txt.

Validation:
python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py'

Impact:
New tooling only; nothing consumes it yet.
EOF
```

---

### Task 2: Placeholder expansion and source merging

The Play copy stores prose as keyed YAML whose values embed `{{ variable }}` references, and layers translations over an English master. This task reproduces that behaviour.

**Files:**
- Modify: `scripts/appstore_metadata.py`
- Modify: `scripts/test_appstore_metadata.py`

**Interfaces:**
- Consumes: nothing from Task 1 (independent functions in the same module).
- Produces:
  - `expand_placeholders(text: str, variables: Mapping[str, str]) -> str`
  - `load_yaml_mapping(path: Path) -> dict[str, str]`
  - `merge_layers(*layers: Mapping[str, str]) -> dict[str, str]`
  - `resolve_variables(raw: Mapping[str, str]) -> dict[str, str]`

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test_appstore_metadata.py`, above `if __name__`:

```python
class PlaceholderTests(unittest.TestCase):
    def test_substitutes_a_variable(self) -> None:
        self.assertEqual(
            meta.expand_placeholders("Hello {{ name }}", {"name": "World"}),
            "Hello World",
        )

    def test_tolerates_missing_whitespace(self) -> None:
        self.assertEqual(
            meta.expand_placeholders("{{name}}", {"name": "X"}), "X"
        )

    def test_expands_nested_references(self) -> None:
        variables = {"outer": "{{ inner }}!", "inner": "deep"}
        self.assertEqual(
            meta.expand_placeholders("{{ outer }}", variables), "deep!"
        )

    def test_leaves_an_unknown_placeholder_in_place(self) -> None:
        self.assertEqual(
            meta.expand_placeholders("{{ missing }}", {}), "{{ missing }}"
        )

    def test_raises_on_a_self_referential_loop(self) -> None:
        with self.assertRaises(ValueError):
            meta.expand_placeholders("{{ a }}", {"a": "{{ b }}", "b": "{{ a }}"})


class MergeTests(unittest.TestCase):
    def test_later_layers_win(self) -> None:
        merged = meta.merge_layers({"k": "base"}, {"k": "override"})
        self.assertEqual(merged["k"], "override")

    def test_blank_values_do_not_override(self) -> None:
        merged = meta.merge_layers({"k": "base"}, {"k": "   "})
        self.assertEqual(merged["k"], "base")

    def test_resolve_expands_values_against_each_other(self) -> None:
        resolved = meta.resolve_variables(
            {"title": "AndBible", "line": '"{{ title }}" is free'}
        )
        self.assertEqual(resolved["line"], '"AndBible" is free')

    def test_resolve_strips_folded_block_trailing_newlines(self) -> None:
        resolved = meta.resolve_variables({"k": "text\n"})
        self.assertEqual(resolved["k"], "text")
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: FAIL with `AttributeError: module 'appstore_metadata' has no attribute 'expand_placeholders'`.

- [ ] **Step 3: Implement**

Add to `scripts/appstore_metadata.py`, after the imports:

```python
import re

PLACEHOLDER_PATTERN = re.compile(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}")
MAX_EXPANSION_PASSES = 8
```

and after `apply_platform_substitutions`:

```python
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: 22 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/appstore_metadata.py scripts/test_appstore_metadata.py
git commit -F - <<'EOF'
feat(appstore): expand and merge the keyed store copy

Why:
The Play store copy is keyed YAML whose values embed {{ variable }}
references and whose translations are overlays on an English master.
Reproducing that behaviour is a prerequisite for rendering iOS copy from
the same sources.

What Changed:
Adds expand_placeholders, load_yaml_mapping, merge_layers and
resolve_variables to scripts/appstore_metadata.py. Unknown placeholders
are left verbatim so the validator can report them, and blank
translation values fall back to English instead of blanking the line.

Validation:
python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py'

Impact:
New tooling only; nothing consumes it yet.
EOF
```

---

### Task 3: Field validation

Every rule that can reject a listing, checked locally in under a second.

**Files:**
- Modify: `scripts/appstore_metadata.py`
- Modify: `scripts/test_appstore_metadata.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `FIELD_LIMITS: dict[str, int]`
  - `FORBIDDEN_SUBSTRINGS: tuple[str, ...]`
  - `validate_fields(apple_locale: str, fields: Mapping[str, str]) -> list[str]` — returns human-readable problem strings, empty when clean

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test_appstore_metadata.py`, above `if __name__`:

```python
class ValidationTests(unittest.TestCase):
    def test_clean_fields_produce_no_problems(self) -> None:
        self.assertEqual(
            meta.validate_fields("fi", {"name": "AndBible", "subtitle": "Study"}),
            [],
        )

    def test_a_field_at_its_limit_is_accepted(self) -> None:
        self.assertEqual(meta.validate_fields("fi", {"subtitle": "x" * 30}), [])

    def test_a_field_one_over_its_limit_is_rejected(self) -> None:
        problems = meta.validate_fields("fi", {"subtitle": "x" * 31})
        self.assertEqual(len(problems), 1)
        self.assertIn("subtitle", problems[0])

    def test_length_is_counted_in_characters_not_bytes(self) -> None:
        # Telugu characters are three bytes each in UTF-8. 200 of them are well
        # inside the 4000-character description limit but would blow a 4000-byte
        # one, which is exactly the mistake this guards against.
        telugu = "అ" * 200
        self.assertGreater(len(telugu.encode("utf-8")), 500)
        self.assertEqual(meta.validate_fields("te", {"description": telugu}), [])

    def test_platform_name_is_rejected_in_any_field(self) -> None:
        problems = meta.validate_fields("fi", {"description": "built for Android"})
        self.assertEqual(len(problems), 1)
        self.assertIn("android", problems[0].lower())

    def test_platform_check_is_case_insensitive(self) -> None:
        self.assertTrue(meta.validate_fields("fi", {"description": "ANDROID"}))

    def test_store_name_is_rejected(self) -> None:
        self.assertTrue(
            meta.validate_fields("fi", {"promotional_text": "on Google Play now"})
        )

    def test_unresolved_placeholder_is_rejected(self) -> None:
        problems = meta.validate_fields("fi", {"description": "{{ missing }}"})
        self.assertEqual(len(problems), 1)
        self.assertIn("placeholder", problems[0])

    def test_problems_name_the_locale(self) -> None:
        problems = meta.validate_fields("pt-BR", {"subtitle": "x" * 99})
        self.assertIn("pt-BR", problems[0])

    def test_an_unlimited_field_is_not_length_checked(self) -> None:
        self.assertEqual(
            meta.validate_fields("fi", {"support_url": "https://" + "x" * 500}), []
        )
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: FAIL with `AttributeError: module 'appstore_metadata' has no attribute 'validate_fields'`.

- [ ] **Step 3: Implement**

Append to `scripts/appstore_metadata.py`:

```python
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: 32 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/appstore_metadata.py scripts/test_appstore_metadata.py
git commit -F - <<'EOF'
feat(appstore): validate store fields against Apple's limits

Why:
A rejected listing costs a round trip to App Store Connect. Every rule
that can reject one — field lengths, other-platform names, unresolved
template placeholders — is checkable locally in under a second.

What Changed:
Adds FIELD_LIMITS, FORBIDDEN_SUBSTRINGS and validate_fields to
scripts/appstore_metadata.py. Lengths are counted in characters, with a
Telugu test case proving a byte-based count would be wrong.

Validation:
python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py'

Impact:
New tooling only; nothing consumes it yet.
EOF
```

---

### Task 4: Source loading and tree rendering

The heart: sources in, `path → content` map out.

**Files:**
- Modify: `scripts/appstore_metadata.py`
- Modify: `scripts/test_appstore_metadata.py`

**Interfaces:**
- Consumes: `LocaleConfig`, `apply_platform_substitutions`, `merge_layers`, `resolve_variables`, `expand_placeholders`, `validate_fields`.
- Produces:
  - `LoadedSources` — frozen dataclass with fields `locale_config: LocaleConfig`, `constants: dict[str, str]`, `android_master: dict[str, str]`, `android_translations: Mapping[str, dict[str, str]]` (keyed by **play** locale), `ios_source: dict[str, str]`, `ios_translations: Mapping[str, dict[str, str]]` (keyed by **apple** locale), `template: str`, `app_info: dict[str, str]`, `release_notes: str`, `review_information: dict[str, str]`
  - `load_sources(android_root: Path, appstore_root: Path) -> LoadedSources`
  - `build_locale_fields(sources: LoadedSources, play_locale: str, apple_locale: str) -> dict[str, str]`
  - `render_tree(sources: LoadedSources) -> dict[str, str]` — keys are paths relative to `fastlane/metadata`, values end with a trailing newline
  - `validate_tree(sources: LoadedSources) -> list[str]`
  - `missing_translation_locales(sources: LoadedSources) -> list[str]`
  - `LOCALE_FIELD_FILES: dict[str, str]`

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test_appstore_metadata.py`, above `if __name__`:

```python
def build_fixture_sources() -> meta.LoadedSources:
    config = meta.LocaleConfig(
        mappings=(("en-US", "en-US"), ("fi-FI", "fi")),
        default_substitutions=(meta.Substitution("Android", "iOS"),),
        locale_substitutions={},
    )
    return meta.LoadedSources(
        locale_config=config,
        constants={"homepage_url": "https://andbible.org"},
        android_master={
            "title": "AndBible: Bible Study",
            "paragraph_1_1": '"{{ title }}" is an app for Android.',
            "feature_08": "Sync across devices",
        },
        android_translations={
            "en-US": {},
            "fi-FI": {
                "title": "AndBible: Raamattu",
                "paragraph_1_1": '"{{ title }}" on sovellus Androidille.',
                "feature_08": "",
            },
        },
        ios_source={
            "subtitle": "Offline Bible study",
            "keywords": "bible,study",
            "promotional_text": "Ad-free and open source.",
            "feature_08": "Sync over iCloud or NextCloud/WebDAV",
        },
        ios_translations={
            "fi": {"subtitle": "Raamatun tutkimista"},
        },
        template="{{ paragraph_1_1 }}\n\n * {{ feature_08 }}\n * {{ homepage_url }}",
        app_info={
            "primary_category": "REFERENCE",
            "secondary_category": "BOOKS",
            "copyright": "2026 The Contributors",
            "marketing_url": "https://andbible.org",
            "support_url": "https://example.org/support",
            "privacy_url": "https://andbible.org/privacy.html",
        },
        release_notes="Initial release.",
        review_information={"notes": "No account is required."},
    )


class RenderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.sources = build_fixture_sources()

    def test_name_comes_from_the_translated_title(self) -> None:
        fields = meta.build_locale_fields(self.sources, "fi-FI", "fi")
        self.assertEqual(fields["name"], "AndBible: Raamattu")

    def test_description_uses_the_translation(self) -> None:
        fields = meta.build_locale_fields(self.sources, "fi-FI", "fi")
        self.assertIn("on sovellus", fields["description"])

    def test_platform_name_is_substituted_in_the_description(self) -> None:
        fields = meta.build_locale_fields(self.sources, "fi-FI", "fi")
        self.assertIn("iOSille", fields["description"])
        self.assertNotIn("Android", fields["description"])

    def test_ios_override_beats_the_android_key(self) -> None:
        fields = meta.build_locale_fields(self.sources, "en-US", "en-US")
        self.assertIn("iCloud or NextCloud/WebDAV", fields["description"])
        self.assertNotIn("Sync across devices", fields["description"])

    def test_blank_translation_value_falls_back_to_the_ios_override(self) -> None:
        fields = meta.build_locale_fields(self.sources, "fi-FI", "fi")
        self.assertIn("iCloud or NextCloud/WebDAV", fields["description"])

    def test_ios_translation_beats_the_ios_source(self) -> None:
        fields = meta.build_locale_fields(self.sources, "fi-FI", "fi")
        self.assertEqual(fields["subtitle"], "Raamatun tutkimista")

    def test_missing_ios_translation_falls_back_to_english(self) -> None:
        fields = meta.build_locale_fields(self.sources, "en-US", "en-US")
        self.assertEqual(fields["subtitle"], "Offline Bible study")

    def test_constants_are_available_to_the_template(self) -> None:
        fields = meta.build_locale_fields(self.sources, "en-US", "en-US")
        self.assertIn("https://andbible.org", fields["description"])

    def test_urls_come_from_app_info(self) -> None:
        fields = meta.build_locale_fields(self.sources, "fi-FI", "fi")
        self.assertEqual(fields["support_url"], "https://example.org/support")

    def test_release_notes_are_the_same_in_every_locale(self) -> None:
        english = meta.build_locale_fields(self.sources, "en-US", "en-US")
        finnish = meta.build_locale_fields(self.sources, "fi-FI", "fi")
        self.assertEqual(english["release_notes"], finnish["release_notes"])


class TreeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tree = meta.render_tree(build_fixture_sources())

    def test_emits_one_directory_per_locale(self) -> None:
        self.assertIn("fi/name.txt", self.tree)
        self.assertIn("en-US/name.txt", self.tree)

    def test_emits_every_localized_field_file(self) -> None:
        for filename in meta.LOCALE_FIELD_FILES.values():
            self.assertIn(f"fi/{filename}", self.tree)

    def test_emits_app_level_files(self) -> None:
        self.assertEqual(self.tree["copyright.txt"], "2026 The Contributors\n")
        self.assertEqual(self.tree["primary_category.txt"], "REFERENCE\n")
        self.assertEqual(self.tree["secondary_category.txt"], "BOOKS\n")

    def test_emits_review_information(self) -> None:
        self.assertEqual(
            self.tree["review_information/notes.txt"], "No account is required.\n"
        )

    def test_every_file_ends_with_a_newline(self) -> None:
        for path, content in self.tree.items():
            self.assertTrue(content.endswith("\n"), path)

    def test_no_unmapped_locale_is_emitted(self) -> None:
        directories = {path.split("/")[0] for path in self.tree if "/" in path}
        self.assertEqual(directories, {"en-US", "fi", "review_information"})


class TreeValidationTests(unittest.TestCase):
    def test_a_clean_tree_reports_no_problems(self) -> None:
        self.assertEqual(meta.validate_tree(build_fixture_sources()), [])

    def test_an_over_long_subtitle_is_reported(self) -> None:
        sources = build_fixture_sources()
        broken = dict(sources.ios_source, subtitle="x" * 31)
        sources = meta.replace_sources(sources, ios_source=broken)
        problems = meta.validate_tree(sources)
        self.assertTrue(any("subtitle" in problem for problem in problems))

    def test_a_surviving_platform_name_is_reported(self) -> None:
        sources = build_fixture_sources()
        config = meta.LocaleConfig(
            mappings=sources.locale_config.mappings,
            default_substitutions=(),
            locale_substitutions={},
        )
        sources = meta.replace_sources(sources, locale_config=config)
        problems = meta.validate_tree(sources)
        self.assertTrue(any("android" in problem.lower() for problem in problems))

    def test_missing_translations_are_listed(self) -> None:
        self.assertEqual(
            meta.missing_translation_locales(build_fixture_sources()), ["en-US"]
        )
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: FAIL with `AttributeError: module 'appstore_metadata' has no attribute 'LoadedSources'`.

- [ ] **Step 3: Implement**

Add `import dataclasses` to the imports, then append to `scripts/appstore_metadata.py`:

```python
LOCALE_FIELD_FILES = {
    "name": "name.txt",
    "subtitle": "subtitle.txt",
    "description": "description.txt",
    "keywords": "keywords.txt",
    "promotional_text": "promotional_text.txt",
    "release_notes": "release_notes.txt",
    "support_url": "support_url.txt",
    "marketing_url": "marketing_url.txt",
    "privacy_url": "privacy_url.txt",
}

APP_LEVEL_FILES = {
    "copyright": "copyright.txt",
    "primary_category": "primary_category.txt",
    "secondary_category": "secondary_category.txt",
}

IOS_ONLY_FIELDS = ("subtitle", "keywords", "promotional_text")


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
        review_information=load_yaml_mapping(
            appstore_root / "review_information.yml"
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
            sources.ios_translations.get(apple_locale, {}),
        )
    )
    fields = {
        "name": variables["title"],
        "description": expand_placeholders(sources.template, variables).strip(),
        "release_notes": sources.release_notes.strip(),
        "support_url": sources.app_info["support_url"],
        "marketing_url": sources.app_info["marketing_url"],
        "privacy_url": sources.app_info["privacy_url"],
    }
    for field in IOS_ONLY_FIELDS:
        fields[field] = variables[field]
    return {
        field: apply_platform_substitutions(
            value, apple_locale, sources.locale_config
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
    for key, filename in APP_LEVEL_FILES.items():
        tree[filename] = sources.app_info[key].strip() + "\n"
    for name, value in sources.review_information.items():
        tree[f"review_information/{name}.txt"] = value.strip() + "\n"
    return tree


def validate_tree(sources: LoadedSources) -> list[str]:
    """Validate every locale. Returns every problem, not just the first."""
    problems: list[str] = []
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: 52 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/appstore_metadata.py scripts/test_appstore_metadata.py
git commit -F - <<'EOF'
feat(appstore): render the metadata tree from loaded sources

Why:
Rendering has to be a pure function from data to a path-to-content map so
that every rule is unit-testable without touching the filesystem, and so
that a drift check is a dictionary comparison rather than a directory
walk.

What Changed:
Adds LoadedSources, load_sources, build_locale_fields, render_tree,
validate_tree and missing_translation_locales to
scripts/appstore_metadata.py. Merge order is constants, Android master,
Android translation, iOS source, iOS translation, with blanks falling
back. Locales with no iOS translation fall back to English and are
reported rather than blocking generation.

Validation:
python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py'

Impact:
New tooling only; no metadata tree is written yet.
EOF
```

---

### Task 5: The real iOS copy sources

Content, not code. Everything the renderer reads from `appstore/`.

**Files:**
- Create: `appstore/description_template.txt`
- Create: `appstore/ios_source.yml`
- Create: `appstore/app_info.yml`
- Create: `appstore/release_notes.txt`
- Create: `appstore/review_information.yml`
- Modify: `scripts/appstore_metadata.py`
- Modify: `scripts/test_appstore_metadata.py`

**Interfaces:**
- Consumes: `load_sources`, `validate_tree`, `render_tree` from Task 4.
- Produces:
  - `merge_review_information(public: Mapping[str, str], local: Mapping[str, str]) -> dict[str, str]`
  - the `appstore/` source tree that Task 6's CLI reads

- [ ] **Step 1: Copy the Android plaintext template**

The description must stay identical to Android's apart from the key overrides — no iOS-specific paragraph, by decision. Copy the Android plain-text template verbatim:

```bash
ANDROID_ROOT=$(python3 -c "import sys;sys.path.insert(0,'scripts');import appstore_metadata as m,pathlib;print(m.resolve_android_root(pathlib.Path('.')))")
cp "$ANDROID_ROOT/play/full_description_template_plaintext.txt" \
   appstore/description_template.txt
```

Leave the template's contents alone otherwise — including the stray space in
`{{paragraph_4_1 }}`, which `PLACEHOLDER_PATTERN` already tolerates.

Verify the template has no control structures, and record which feature keys it
actually renders (it does **not** render `feature_12`):

```bash
grep -c '{%' appstore/description_template.txt    # expect 0 matches -> grep exits 1
grep -o '{{[^}]*}}' appstore/description_template.txt | sort -u
```

- [ ] **Step 2: Write the iOS source copy**

Create `appstore/ios_source.yml`:

```yaml
# iOS-only App Store fields, and overrides of Android description keys.
#
# This file is the English master. Per-locale translations live in
# ios_translations/<apple-locale>.yml and use the same keys.
#
# Keys that are NOT here come from the Android store copy unchanged; the
# description is deliberately the same text as the Play listing apart from the
# four overrides below.

# --- iOS-only fields (no Android counterpart) ---

# App Store subtitle, max 30 characters.
subtitle: "Offline Bible study toolkit"

# App Store keywords, max 100 characters, comma separated, no spaces after
# commas (they count against the limit).
keywords: "study,offline,commentary,strongs,greek,hebrew,sword,notes,highlight,memorize,reading plan"

# App Store promotional text, max 170 characters. Can be changed without
# submitting a new build.
promotional_text: >
  Ad-free and open source. Split views, commentaries, Strong's, powerful search,
  bookmarks and notes - all offline once your documents are installed.

# --- Overrides of Android description keys ---

# Android's sync includes Google Drive. iOS deliberately does not: the backends
# are iCloud and NextCloud/WebDAV only (RemoteSyncBackend).
feature_08: >
  Cross-device sync over iCloud or NextCloud/WebDAV: keep your workspaces,
  bookmarks, notes, and reading progress in sync across all your devices

# Android's wording promises "reading goals", which has no iOS counterpart.
# What exists is reading plans plus progress tracking.
feature_09: >
  Reading plans and progress tracking - chapters read, active days and reading
  cycles - plus verse memorization with interactive Word Scramble, Word Order,
  Word Blur, and Type It modes

# The AI agent must be described as opt-in and bring-your-own-key.
feature_11: >
  Optional AI study agent - off by default, and requires your own API key from a
  third-party provider. Explore your installed commentaries and dictionaries with
  AI assistance in your chosen language. A built-in permission system keeps you in
  full control of what the agent can do.
```

- [ ] **Step 3: Write the app-level metadata**

Create `appstore/app_info.yml`:

```yaml
# App-level App Store Connect metadata. These values are the same in every
# locale; deliver reads the categories and copyright from the metadata root and
# the three URLs from each locale directory.
primary_category: REFERENCE
secondary_category: BOOKS
copyright: "2026 Tuomas Airaksinen, Jared Murrell and the AndBible contributors"
marketing_url: "https://andbible.org"
support_url: "https://github.com/AndBible/and-bible/wiki/Support"
privacy_url: "https://andbible.org/privacy.html"
```

Create `appstore/release_notes.txt`:

```
First App Store release of AndBible for iPhone and iPad.
```

Release notes are English only, by decision, and are written verbatim into every locale.

- [ ] **Step 4: Write the review notes**

Create `appstore/review_information.yml`:

```yaml
# Notes shown to the App Store reviewer. Public information only.
#
# The reviewer CONTACT DETAILS (name, phone, email) are personal data and must
# never be committed to this public repository. They come from a gitignored
# appstore/review_information.local.yml, or from ASC_REVIEW_* environment
# variables; see docs/howto/appstore-metadata.md.
notes: |
  The app ships with no Bible texts. On first launch it prompts you to download
  a document from a SWORD repository or import a file; until you do, the reader
  is empty by design. Any module from the default CrossWire repository is enough
  to exercise the app.

  Discrete mode (Settings > Discrete mode) replaces the launcher icon with a
  calculator and gates entry behind a PIN. It exists so that users in countries
  where possessing religious material is dangerous can keep the app
  inconspicuous. It hides nothing from you: it is documented in the app's own
  settings and every feature stays reachable. It is not encryption and is not
  marketed as security.

  The AI study agent is off by default. It requires the user's own API key from
  a third-party provider, stores that key only in the device Keychain, and asks
  permission before each tool call. No AI feature works without a key the user
  supplies.

  The app declares App Transport Security exceptions for crosswire.org,
  ebible.org, ibtrussia.org, stepbible.org and github.io because several SWORD
  module repositories are still HTTP-only. They are document download endpoints;
  no user data is sent to them.

  AndBible is a non-profit, open-source project distributed under the GPL. It
  contains no advertising and no in-app purchases.
```

- [ ] **Step 5: Let local reviewer contact details override the public notes**

The reviewer's name, phone and email are personal data and must never reach this
public repository, but `deliver` needs them. Write the failing tests first —
append to `scripts/test_appstore_metadata.py`, above `if __name__`:

```python
class ReviewInformationTests(unittest.TestCase):
    def test_without_a_local_file_only_the_public_notes_remain(self) -> None:
        merged = meta.merge_review_information({"notes": "public"}, {})
        self.assertEqual(merged, {"notes": "public"})

    def test_local_contact_details_are_added(self) -> None:
        merged = meta.merge_review_information(
            {"notes": "public"},
            {"first_name": "Ada", "email_address": "ada@example.org"},
        )
        self.assertEqual(merged["first_name"], "Ada")
        self.assertEqual(merged["notes"], "public")

    def test_local_values_win(self) -> None:
        merged = meta.merge_review_information(
            {"notes": "public"}, {"notes": "local"}
        )
        self.assertEqual(merged["notes"], "local")
```

Run them (`python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`);
expect `AttributeError: … has no attribute 'merge_review_information'`.

Then append to `scripts/appstore_metadata.py`:

```python
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
```

and in `load_sources`, replace the `review_information=` argument with:

```python
        review_information=merge_review_information(
            load_yaml_mapping(appstore_root / "review_information.yml"),
            load_yaml_mapping(appstore_root / REVIEW_INFORMATION_LOCAL_FILE)
            if (appstore_root / REVIEW_INFORMATION_LOCAL_FILE).is_file()
            else {},
        ),
```

Run the tests again; expect PASS.

- [ ] **Step 6: Write a test that the real sources render and validate**

Append to `scripts/test_appstore_metadata.py`, above `if __name__`:

```python
class RealSourcesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.sources = meta.load_sources(
            android_root_or_skip(self), REPO_ROOT / "appstore"
        )

    def test_the_real_tree_validates(self) -> None:
        self.assertEqual(meta.validate_tree(self.sources), [])

    def test_the_real_tree_covers_every_locale(self) -> None:
        tree = meta.render_tree(self.sources)
        directories = {path.split("/")[0] for path in tree if "/" in path}
        directories.discard("review_information")
        self.assertEqual(len(directories), 34)

    def test_english_description_is_within_the_limit(self) -> None:
        fields = meta.build_locale_fields(self.sources, "en-US", "en-US")
        self.assertLessEqual(len(fields["description"]), 4000)

    def test_the_ios_overrides_reach_the_description(self) -> None:
        fields = meta.build_locale_fields(self.sources, "en-US", "en-US")
        self.assertIn("iCloud or NextCloud/WebDAV", fields["description"])
        self.assertIn("off by default", fields["description"])
```

- [ ] **Step 7: Run the tests**

Run: `python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: 59 tests PASS.

If `test_the_real_tree_validates` fails on a length limit, shorten the offending value in `appstore/ios_source.yml` — do not raise the limit. If it fails on a forbidden platform reference in a locale not covered by `locales.yml`, add that locale's inflected form to `platform_substitutions` and re-run.

- [ ] **Step 8: Commit**

```bash
git add appstore/description_template.txt appstore/ios_source.yml \
        appstore/app_info.yml appstore/release_notes.txt \
        appstore/review_information.yml \
        scripts/appstore_metadata.py scripts/test_appstore_metadata.py
git commit -F - <<'EOF'
feat(appstore): add the iOS store copy sources

Why:
Three Android description keys are wrong for iOS: sync lists Google Drive,
reading "goals" do not exist, and the AI agent must be described as
opt-in and bring-your-own-key. Three App Store fields have no Android
counterpart at all.

What Changed:
Adds the description template (the Android plain-text template verbatim),
ios_source.yml with the three overrides plus subtitle, keywords and
promotional text, app_info.yml with categories, copyright and URLs,
English release notes, and reviewer notes covering discrete mode, the AI
agent, the ATS exceptions and the absence of preinstalled modules. The
reviewer's contact details stay out of this public repository: they are
overlaid from a gitignored review_information.local.yml, and when it is
absent those fields are simply not emitted.

Validation:
python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py'
renders and validates all 34 locales against the real Android sources.

Impact:
No generated tree yet; the CLI lands in the next commit.
EOF
```

---

### Task 6: The CLI, the lock file and the drift check

**Files:**
- Create: `scripts/assemble_appstore_metadata.py`
- Modify: `scripts/appstore_metadata.py`
- Modify: `scripts/test_appstore_metadata.py`

(`appstore/android_source.lock` is written by this CLI but first committed in Task 7.)

**Interfaces:**
- Consumes: `load_sources`, `render_tree`, `validate_tree`, `missing_translation_locales`.
- Produces:
  - `compare_tree(tree: Mapping[str, str], output_root: Path) -> list[str]` — problems describing added, removed and changed files
  - `write_tree(tree: Mapping[str, str], output_root: Path) -> None` — writes the tree and deletes files it no longer contains
  - CLI `python3 scripts/assemble_appstore_metadata.py [--check] [--require-pinned] [--android-root PATH]`

- [ ] **Step 1: Write the failing tests**

Append to `scripts/test_appstore_metadata.py`, above `if __name__`:

```python
class TreeIOTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.out = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_write_then_compare_is_clean(self) -> None:
        tree = {"fi/name.txt": "AndBible\n", "copyright.txt": "2026\n"}
        meta.write_tree(tree, self.out)
        self.assertEqual(meta.compare_tree(tree, self.out), [])

    def test_compare_reports_a_changed_file(self) -> None:
        meta.write_tree({"fi/name.txt": "old\n"}, self.out)
        problems = meta.compare_tree({"fi/name.txt": "new\n"}, self.out)
        self.assertEqual(len(problems), 1)
        self.assertIn("fi/name.txt", problems[0])

    def test_compare_reports_a_missing_file(self) -> None:
        problems = meta.compare_tree({"fi/name.txt": "x\n"}, self.out)
        self.assertTrue(any("fi/name.txt" in problem for problem in problems))

    def test_compare_reports_a_stale_file(self) -> None:
        meta.write_tree({"fi/name.txt": "x\n", "fi/old.txt": "y\n"}, self.out)
        problems = meta.compare_tree({"fi/name.txt": "x\n"}, self.out)
        self.assertTrue(any("fi/old.txt" in problem for problem in problems))

    def test_write_removes_a_stale_file(self) -> None:
        meta.write_tree({"fi/old.txt": "y\n"}, self.out)
        meta.write_tree({"fi/name.txt": "x\n"}, self.out)
        self.assertFalse((self.out / "fi" / "old.txt").exists())
        self.assertTrue((self.out / "fi" / "name.txt").exists())
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: FAIL with `AttributeError: module 'appstore_metadata' has no attribute 'write_tree'`.

- [ ] **Step 3: Implement the tree I/O**

Append to `scripts/appstore_metadata.py`:

```python
def _existing_files(output_root: Path) -> set[str]:
    if not output_root.is_dir():
        return set()
    return {
        str(path.relative_to(output_root))
        for path in output_root.rglob("*.txt")
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: 64 tests PASS.

- [ ] **Step 5: Write the CLI**

Create `scripts/assemble_appstore_metadata.py`:

```python
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
```

- [ ] **Step 6: Make it executable and smoke-test the check path**

```bash
chmod +x scripts/assemble_appstore_metadata.py
python3 scripts/assemble_appstore_metadata.py --check
```

Expected: exits 1, listing 34 locales' worth of `missing:` entries (nothing is committed yet) and noting that 34 locales fall back to English. That is the correct pre-bootstrap state.

- [ ] **Step 7: Commit**

```bash
git add scripts/assemble_appstore_metadata.py scripts/appstore_metadata.py \
        scripts/test_appstore_metadata.py
git commit -F - <<'EOF'
feat(appstore): add the metadata generator CLI

Why:
The rendered tree has to be committed so that it is reviewable in a diff
and uploadable without the Android checkout present, which means there
has to be a way to detect drift between the sources and the committed
output.

What Changed:
Adds scripts/assemble_appstore_metadata.py with --check (compare, write
nothing) and --require-pinned (fail unless the Android checkout matches
android_source.lock), plus compare_tree and write_tree in
scripts/appstore_metadata.py. A lock mismatch is a warning locally and an
error in CI, so a developer whose sibling checkout sits on another
commit can still validate.

Validation:
python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py'
python3 scripts/assemble_appstore_metadata.py --check reports the
expected pre-bootstrap drift.

Impact:
The metadata tree is still not generated; that is the next commit.
EOF
```

---

### Task 7: Bootstrap the committed metadata tree

**Files:**
- Create: `fastlane/metadata/**` (generated, 34 locales)
- Create: `appstore/android_source.lock`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: the CLI from Task 6.
- Produces: the committed `fastlane/metadata/` tree that Task 8's `deliver` uploads.

- [ ] **Step 1: Keep local reviewer contact details out of git**

Append to `.gitignore`, under the existing `# Environment` section:

```
# App Store reviewer contact details are personal data; the public notes live in
# appstore/review_information.yml.
appstore/*.local.yml
```

- [ ] **Step 2: Generate the tree**

```bash
python3 scripts/assemble_appstore_metadata.py
```

Expected: `Wrote 310 files to .../fastlane/metadata` — 34 locales × 9 files = 306, plus `copyright.txt`, `primary_category.txt`, `secondary_category.txt` and `review_information/notes.txt` — preceded by the note that 34 locales fall back to English. If `appstore/review_information.local.yml` exists locally the count is higher by one per contact field; that is expected and those files are gitignored at the source, not the output, so **do not commit them** — check `git status` before staging.

- [ ] **Step 3: Inspect the output before trusting it**

```bash
cat fastlane/metadata/en-US/description.txt
echo "--- lengths ---"
for f in name subtitle keywords promotional_text description; do
  printf '%s: ' "$f"
  python3 -c "import sys;print(len(open(sys.argv[1],encoding='utf-8').read().rstrip('\n')))" \
    "fastlane/metadata/en-US/$f.txt"
done
echo "--- platform substitution in the four inflecting locales ---"
grep -h -o '.\{0,40\}iOS.\{0,20\}' fastlane/metadata/{pl,hu,hr,sl}/description.txt
echo "--- no platform name survives anywhere ---"
grep -ril 'android' fastlane/metadata/ || echo "clean"
```

Read the Polish, Hungarian, Croatian and Slovenian lines and confirm the substituted form reads naturally. If one does not, fix its rule in `appstore/locales.yml`, regenerate, and re-inspect.

- [ ] **Step 4: Verify the check is now clean**

Run: `python3 scripts/assemble_appstore_metadata.py --check`
Expected: `Metadata is up to date (310 files).`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add .gitignore appstore/android_source.lock fastlane/metadata
git commit -F - <<'EOF'
feat(appstore): generate the App Store metadata tree

Why:
The rendered tree is committed so that the listing copy is reviewable in
a diff, and so that an upload does not require the Android checkout to be
present.

What Changed:
Generates fastlane/metadata for 34 locales from the Android store copy
plus the iOS overrides, records the Android commit it was generated from
in appstore/android_source.lock, and gitignores the local reviewer
contact file. The subtitle, keywords and promotional text are English in
every locale for now; per-locale translations follow.

Validation:
python3 scripts/assemble_appstore_metadata.py --check is clean.
grep -ril android fastlane/metadata finds nothing.
The Polish, Hungarian, Croatian and Slovenian substitutions were read and
confirmed to read naturally.

Impact:
Nothing uploads yet; the fastlane configuration follows.
EOF
```

---

### Task 8: fastlane configuration and the publishing pipeline `[macOS]`

Extract the App Store Connect key handling so there is one implementation, then wire `deliver`.

**Files:**
- Create: `scripts/lib-asc-api-key.sh`
- Create: `scripts/deliver-appstore-metadata.sh`
- Create: `fastlane/Appfile`
- Create: `fastlane/Deliverfile`
- Modify: `scripts/upload-testflight.sh`
- Modify: `Makefile`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: the committed tree from Task 7.
- Produces: shell function `asc_prepare_api_key` which sets `ASC_KEY_FILE` (path to the decrypted `.p8`), `ASC_KEY_JSON` (path to a fastlane `--api_key_path` JSON) and `ASC_TEAM_ID`, and registers an exit trap that ejects the RAM disk.

**This task cannot be verified in the Linux dev container** — `hdiutil`, `diskutil`, fastlane and the YubiKey are all macOS-side. Write it, commit it, and report it as unverified.

- [ ] **Step 1: Extract the key handling**

Create `scripts/lib-asc-api-key.sh` by moving the RAM-disk logic out of `scripts/upload-testflight.sh` verbatim (the `hdiutil attach`, `diskutil erasevolume`, `touch`/`chmod 600`/`gpg --decrypt` sequence and the `cleanup` trap), wrapped in a function and extended to also emit the JSON form fastlane needs:

```bash
#!/usr/bin/env bash
# Decrypt the App Store Connect API key onto a RAM-backed volume.
#
# Source this file and call asc_prepare_api_key. It sets:
#   ASC_KEY_FILE  path to AuthKey_<id>.p8   (xcodebuild / Transporter)
#   ASC_KEY_JSON  path to asc_api_key.json  (fastlane --api_key_path)
#   ASC_TEAM_ID   the resolved Apple Developer team
# and registers an EXIT trap that ejects the volume.
#
# The key is GPG-encrypted to the developer's YubiKey. Apple's tooling requires
# it as a file on disk, so it is decrypted onto a RAM disk rather than the normal
# filesystem. That is not an absolute guarantee - macOS can still page memory to
# swap or capture it in a crash dump.

asc_prepare_api_key() {
	local key_id="${ASC_KEY_ID:?Set ASC_KEY_ID to the App Store Connect API key ID}"
	local issuer_id="${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to the App Store Connect API issuer UUID}"
	local enc_key="${ASC_KEY_GPG:-$HOME/.appstoreconnect/private_keys/AuthKey_${key_id}.p8.gpg}"
	local signing_xcconfig="${ASC_SIGNING_XCCONFIG:-Config/Secrets.xcconfig.local}"

	[ -f "$enc_key" ] || { echo "Encrypted key not found: $enc_key" >&2; return 1; }

	ASC_TEAM_ID="${ASC_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
	if [ -z "$ASC_TEAM_ID" ] && [ -f "$signing_xcconfig" ]; then
		ASC_TEAM_ID="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' "$signing_xcconfig" | tr -d '[:space:]')"
	fi
	[ -n "$ASC_TEAM_ID" ] || {
		echo "Could not resolve the Apple Developer team. Set ASC_TEAM_ID or DEVELOPMENT_TEAM in $signing_xcconfig." >&2
		return 1
	}

	# hdiutil pads the device node with trailing whitespace - trim it, or
	# diskutil cannot find the disk. Register cleanup immediately after
	# attaching so a later failure never leaves the RAM disk mounted.
	ASC_RAM_DEV="$(hdiutil attach -nomount ram://40960 | tr -d '[:space:]')"
	# shellcheck disable=SC2064
	trap "asc_cleanup_api_key" EXIT

	local volume_name="asckey-$$"
	diskutil erasevolume HFS+ "$volume_name" "$ASC_RAM_DEV" >/dev/null
	local keydir="/Volumes/$volume_name"
	[ -d "$keydir" ] || { echo "RAM disk mount not found: $keydir" >&2; return 1; }

	ASC_KEY_FILE="$keydir/AuthKey_${key_id}.p8"
	ASC_KEY_JSON="$keydir/asc_api_key.json"

	# Create both files and lock their permissions BEFORE any plaintext is
	# written, so the decrypted key is never even momentarily readable by
	# other users. The > redirect truncates without changing the mode.
	touch "$ASC_KEY_FILE" "$ASC_KEY_JSON"
	chmod 600 "$ASC_KEY_FILE" "$ASC_KEY_JSON"
	echo ">> Decrypting API key onto RAM disk (YubiKey PIN + touch may be required)…"
	gpg --quiet --decrypt "$enc_key" > "$ASC_KEY_FILE"

	KEY_ID="$key_id" ISSUER_ID="$issuer_id" KEY_PATH="$ASC_KEY_FILE" \
		python3 -c '
import json, os
print(json.dumps({
    "key_id": os.environ["KEY_ID"],
    "issuer_id": os.environ["ISSUER_ID"],
    "key": open(os.environ["KEY_PATH"], encoding="utf-8").read(),
    "in_house": False,
}))' > "$ASC_KEY_JSON"

	export ASC_KEY_FILE ASC_KEY_JSON ASC_TEAM_ID
}

asc_cleanup_api_key() {
	if [ -n "${ASC_RAM_DEV:-}" ]; then
		hdiutil detach "$ASC_RAM_DEV" >/dev/null 2>&1 \
			|| diskutil eject "$ASC_RAM_DEV" >/dev/null 2>&1 || true
		ASC_RAM_DEV=""
	fi
}
```

- [ ] **Step 2: Refactor `upload-testflight.sh` onto the shared helper**

In `scripts/upload-testflight.sh`, replace the inline key block (from `RAM_DEV="$(hdiutil attach…` through the `gpg --quiet --decrypt … > "$KEYFILE"` line) with:

```bash
# shellcheck source=scripts/lib-asc-api-key.sh
. "$SCRIPT_DIR/lib-asc-api-key.sh"

INFOPLIST_BAK=""
cleanup() {
	# Restore the original Info.plist byte-for-byte. PlistBuddy reorders keys on
	# write, so restoring a saved copy (not re-setting the version) keeps the tree
	# clean.
	[ -n "$INFOPLIST_BAK" ] && [ -f "$INFOPLIST_BAK" ] && mv -f "$INFOPLIST_BAK" "$INFOPLIST"
	asc_cleanup_api_key
}
trap cleanup EXIT

asc_prepare_api_key
KEYFILE="$ASC_KEY_FILE"
KEYDIR="$(dirname "$KEYFILE")"
TEAM_ID="$ASC_TEAM_ID"
```

Delete the now-duplicated `KEY_ID`/`ISSUER_ID`/`ENC_KEY`/`TEAM_ID` resolution lines above it. Leave everything from the ExportOptions generation onwards untouched.

Note the trap ordering: `asc_prepare_api_key` installs its own trap, so this script's `trap cleanup EXIT` must be registered **after** sourcing but **before** calling `asc_prepare_api_key`, and `cleanup` must call `asc_cleanup_api_key` itself.

- [ ] **Step 3: Write the fastlane configuration**

Create `fastlane/Appfile`:

```ruby
app_identifier "org.andbible.ios"
```

Create `fastlane/Deliverfile`:

```ruby
# Text metadata only. The binary goes through scripts/upload-testflight.sh, and
# screenshots are uploaded by hand - skip_screenshots keeps deliver from
# deleting or reordering them.
app_identifier "org.andbible.ios"
metadata_path "./fastlane/metadata"

skip_binary_upload true
skip_screenshots true
submit_for_review false

# Skip the interactive HTML preview confirmation; this runs non-interactively.
force true

precheck_include_in_app_purchases false
```

- [ ] **Step 4: Write the deliver script**

Create `scripts/deliver-appstore-metadata.sh`:

```bash
#!/usr/bin/env bash
# Upload App Store Connect text metadata with fastlane deliver.
#
# Text only: no binary, no screenshots, no review submission. Screenshots are
# uploaded by hand and the Deliverfile is configured not to touch them.
#
#   ./scripts/deliver-appstore-metadata.sh            # upload
#   ./scripts/deliver-appstore-metadata.sh precheck   # Apple's metadata rules
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
cd "$REPO_ROOT"

MODE="${1:-deliver}"

command -v fastlane >/dev/null || {
	echo "fastlane is not installed. brew install fastlane" >&2
	exit 1
}

echo ">> Validating the metadata tree before uploading…"
python3 scripts/assemble_appstore_metadata.py --check

# shellcheck source=scripts/lib-asc-api-key.sh
. "$SCRIPT_DIR/lib-asc-api-key.sh"
asc_prepare_api_key

case "$MODE" in
	deliver)
		fastlane deliver --api_key_path "$ASC_KEY_JSON" --team_id "$ASC_TEAM_ID"
		;;
	precheck)
		fastlane precheck --api_key_path "$ASC_KEY_JSON" --team_id "$ASC_TEAM_ID"
		;;
	*)
		echo "Unknown mode: $MODE (expected 'deliver' or 'precheck')" >&2
		exit 2
		;;
esac
```

```bash
chmod +x scripts/deliver-appstore-metadata.sh
```

- [ ] **Step 5: Add the Make targets**

Append to `Makefile`:

```make
.PHONY: appstore-metadata
appstore-metadata: ## Generate the App Store metadata tree from the Android store copy
	@python3 scripts/assemble_appstore_metadata.py

.PHONY: appstore-validate
appstore-validate: ## Check the metadata tree for drift and rule violations (offline)
	@python3 scripts/assemble_appstore_metadata.py --check

.PHONY: appstore-precheck
appstore-precheck: ## Run Apple's own metadata rules against the live listing (macOS)
	@scripts/deliver-appstore-metadata.sh precheck

.PHONY: appstore-deliver
appstore-deliver: ## Upload App Store text metadata (macOS, YubiKey)
	@scripts/deliver-appstore-metadata.sh
```

Leave the existing `export` line alone. Reviewer contact details reach the
generator through `appstore/review_information.local.yml` (Task 5), not through
the environment — one mechanism, not two.

- [ ] **Step 6: Ignore fastlane's run artefacts**

Append to `.gitignore`:

```
# fastlane run artefacts
/fastlane/report.xml
/fastlane/Preview.html
/fastlane/*.json
```

- [ ] **Step 7: Verify what can be verified here**

```bash
bash -n scripts/lib-asc-api-key.sh
bash -n scripts/deliver-appstore-metadata.sh
bash -n scripts/upload-testflight.sh
make -n appstore-validate
make appstore-validate
```

Expected: no syntax errors, and `appstore-validate` reports the tree is up to date. The two macOS targets are **not** runnable here.

- [ ] **Step 8: Commit**

```bash
git add scripts/lib-asc-api-key.sh scripts/deliver-appstore-metadata.sh \
        scripts/upload-testflight.sh fastlane/Appfile fastlane/Deliverfile \
        Makefile .gitignore
git commit -F - <<'EOF'
feat(appstore): upload text metadata with fastlane deliver

Why:
The App Store listing copy was typed into App Store Connect by hand. It
now has a source tree, so it needs a one-command upload that reuses the
existing App Store Connect key handling rather than duplicating it.

What Changed:
Extracts the RAM-disk API key decryption from upload-testflight.sh into
scripts/lib-asc-api-key.sh, which now also emits the JSON form fastlane
needs, and refactors upload-testflight.sh onto it. Adds fastlane
Appfile and Deliverfile, scripts/deliver-appstore-metadata.sh, and the
appstore-metadata, appstore-validate, appstore-precheck and
appstore-deliver Make targets. skip_screenshots is set so deliver never
touches the hand-uploaded screenshots.

Validation:
bash -n on all three shell scripts; make appstore-validate is clean.
The macOS paths (hdiutil, gpg/YubiKey, fastlane deliver and precheck)
are NOT verified - they need a Mac and the App Store Connect listing.

Impact:
upload-testflight.sh is refactored and must be re-tested on the Mac
before the next TestFlight upload.
EOF
```

---

### Task 9: CI drift guard

**Files:**
- Modify: `.github/workflows/ios-ci.yml`

**Interfaces:**
- Consumes: `scripts/assemble_appstore_metadata.py --check --require-pinned`.
- Produces: a CI job named `appstore-metadata`.

- [ ] **Step 1: Read the existing job structure**

Look at the `localization-guardrails` job in `.github/workflows/ios-ci.yml` — it already does exactly the shape needed (checkout, `actions/setup-python@v6` with 3.12, Android reference checkout, run a Python guardrail). Copy that shape.

- [ ] **Step 2: Add the job**

Add to `.github/workflows/ios-ci.yml`, after the `localization-guardrails` job, at the same indentation:

```yaml
  appstore-metadata:
    name: App Store metadata
    runs-on: ubuntu-latest
    steps:
      - name: Check out the repository
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v6
        with:
          python-version: "3.12"

      - name: Install Python dependencies
        run: python3 -m pip install --requirement scripts/requirements-appstore.txt

      - name: Check out the Android store copy at the pinned commit
        run: |
          set -euo pipefail
          sha="$(grep -v '^#' appstore/android_source.lock | head -n 1 | tr -d '[:space:]')"
          git init ../and-bible
          git -C ../and-bible fetch --depth 1 https://github.com/AndBible/and-bible.git "$sha"
          git -C ../and-bible checkout --detach FETCH_HEAD

      - name: Run the metadata unit tests
        run: python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v

      - name: Check the metadata tree for drift
        run: python3 scripts/assemble_appstore_metadata.py --check --require-pinned
```

Note this job runs on `ubuntu-latest`, not macOS: it needs neither Xcode nor credentials.

- [ ] **Step 3: Validate the workflow syntax**

```bash
python3 -c "
import yaml, sys
data = yaml.safe_load(open('.github/workflows/ios-ci.yml', encoding='utf-8'))
assert 'appstore-metadata' in data['jobs'], 'job missing'
print('jobs:', ', '.join(data['jobs']))
"
```

Expected: the job list includes `appstore-metadata`.

- [ ] **Step 4: Verify the lock SHA is fetchable**

```bash
grep -v '^#' appstore/android_source.lock | head -n 1
ANDROID_ROOT=$(python3 -c "import sys;sys.path.insert(0,'scripts');import appstore_metadata as m,pathlib;print(m.resolve_android_root(pathlib.Path('.')))")
git -C "$ANDROID_ROOT" cat-file -t "$(grep -v '^#' appstore/android_source.lock | head -n 1 | tr -d '[:space:]')"
```

Expected: `commit`. If the SHA only exists on a local container branch and has not been pushed to `github.com/AndBible/and-bible`, CI cannot fetch it — regenerate against a pushed commit before relying on this job, and say so.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ios-ci.yml
git commit -F - <<'EOF'
ci(appstore): guard the metadata tree against drift

Why:
The metadata tree is generated but committed, so nothing stops it from
drifting away from its sources. A drift check is only meaningful against
a known Android commit, which is what android_source.lock records.

What Changed:
Adds an appstore-metadata job to ios-ci.yml that installs PyYAML, checks
out the Android repository at the SHA in android_source.lock, runs the
metadata unit tests and runs the generator with --check --require-pinned.
Runs on ubuntu-latest; it needs neither Xcode nor credentials.

Validation:
The workflow parses and the job is present. The lock SHA was confirmed to
resolve to a commit in the local Android checkout.

Impact:
A pull request that edits the store copy without regenerating now fails.
EOF
```

---

### Task 10: Per-locale translations of the iOS copy

**Files:**
- Create: `.claude/skills/appstore-copy/SKILL.md`
- Create: `.claude/skills/appstore-copy/find_stale.py`
- Create: `appstore/ios_translations/<apple-locale>.yml` × 34
- Modify: `scripts/appstore_metadata.py`
- Modify: `scripts/test_appstore_metadata.py`
- Modify: `fastlane/metadata/**` (regenerated)

**Interfaces:**
- Consumes: `LoadedSources`, `missing_translation_locales`.
- Produces: `ios_source_digest(ios_source: Mapping[str, str]) -> str` — a stable SHA-256 hex digest of the English source, recorded in each translation as `source_sha`.

- [ ] **Step 1: Write the failing test for the digest and the staleness rule**

Append to `scripts/test_appstore_metadata.py`, above `if __name__`:

```python
class DigestTests(unittest.TestCase):
    def test_digest_is_stable_across_key_order(self) -> None:
        first = meta.ios_source_digest({"a": "1", "b": "2"})
        second = meta.ios_source_digest({"b": "2", "a": "1"})
        self.assertEqual(first, second)

    def test_digest_changes_when_a_value_changes(self) -> None:
        self.assertNotEqual(
            meta.ios_source_digest({"a": "1"}), meta.ios_source_digest({"a": "2"})
        )

    def test_digest_ignores_the_source_sha_key(self) -> None:
        self.assertEqual(
            meta.ios_source_digest({"a": "1"}),
            meta.ios_source_digest({"a": "1", "source_sha": "deadbeef"}),
        )

    def test_stale_translations_are_reported(self) -> None:
        sources = build_fixture_sources()
        digest = meta.ios_source_digest(sources.ios_source)
        fresh = {"fi": {"subtitle": "x", "source_sha": digest}}
        self.assertEqual(meta.stale_translation_locales(
            meta.replace_sources(sources, ios_translations=fresh)
        ), [])
        stale = {"fi": {"subtitle": "x", "source_sha": "old"}}
        self.assertEqual(meta.stale_translation_locales(
            meta.replace_sources(sources, ios_translations=stale)
        ), ["fi"])


class SourceShaExclusionTests(unittest.TestCase):
    def test_source_sha_is_not_rendered_into_any_field(self) -> None:
        sources = build_fixture_sources()
        translations = {
            "fi": {"subtitle": "Raamattu", "source_sha": "deadbeef"},
        }
        sources = meta.replace_sources(sources, ios_translations=translations)
        fields = meta.build_locale_fields(sources, "fi-FI", "fi")
        for value in fields.values():
            self.assertNotIn("deadbeef", value)


class TranslationKeyTests(unittest.TestCase):
    def test_a_key_absent_from_the_english_source_is_rejected(self) -> None:
        sources = build_fixture_sources()
        sources = meta.replace_sources(
            sources,
            ios_translations={"fi": {"subtitle": "x", "sbutitle": "typo"}},
        )
        problems = meta.validate_tree(sources)
        self.assertTrue(any("sbutitle" in problem for problem in problems))
```

A misspelt key would otherwise be silently ignored: the value never reaches the
listing and the English text ships instead, with nothing to notice.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: FAIL with `AttributeError: module 'appstore_metadata' has no attribute 'ios_source_digest'`.

- [ ] **Step 3: Implement**

Add `import hashlib` and `import json` to the imports of `scripts/appstore_metadata.py`, then append:

```python
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
```

and call it from `validate_tree` — change its body to start with:

```python
    problems: list[str] = validate_translation_keys(sources)
```

And in `build_locale_fields`, drop the bookkeeping key before merging — change the `sources.ios_translations.get(apple_locale, {})` argument of `merge_layers` to:

```python
            {
                key: value
                for key, value in sources.ios_translations.get(
                    apple_locale, {}
                ).items()
                if key != SOURCE_SHA_KEY
            },
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s scripts -p 'test_appstore_metadata.py' -v`
Expected: 70 tests PASS.

- [ ] **Step 5: Report staleness from the CLI**

In `scripts/assemble_appstore_metadata.py`, after the `missing` block in `main()`, add:

```python
    stale = meta.stale_translation_locales(sources)
    if stale:
        print(
            f"note: {len(stale)} locale(s) were translated against an older "
            "English source: " + ", ".join(stale),
            file=sys.stderr,
        )
```

- [ ] **Step 6: Write the staleness reporter**

Create `.claude/skills/appstore-copy/find_stale.py`:

```python
#!/usr/bin/env python3
"""List App Store locales whose iOS copy is missing or out of date.

Prints one locale per line, prefixed with its reason, so the caller can dispatch
one translation agent per line.
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
    for locale in meta.missing_translation_locales(sources):
        print(f"missing {locale}")
    for locale in meta.stale_translation_locales(sources):
        print(f"stale {locale}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 7: Write the skill**

Create `.claude/skills/appstore-copy/SKILL.md`:

````markdown
---
name: appstore-copy
description: Use when App Store listing copy needs translating or refreshing - the subtitle, keywords and promotional text in appstore/ios_source.yml, and the iOS overrides of the Android description keys. Trigger on "translate the App Store copy", "appstore-validate says locales fall back to English", or after editing appstore/ios_source.yml.
---

# Translating the App Store copy

The App Store description prose comes from the Android repository's Transifex
translations and needs no work here. What this skill covers is the iOS-only
layer: `appstore/ios_source.yml`, translated into
`appstore/ios_translations/<apple-locale>.yml`.

## Find what needs work

```bash
python3 .claude/skills/appstore-copy/find_stale.py
```

Each line is `missing <locale>` (never translated) or `stale <locale>`
(translated against an older English source). Dispatch **one subagent per
locale**, five to eight in parallel.

## What each subagent is given

- the full English `appstore/ios_source.yml`
- the matching Android translation, `<android-root>/play/description-translations/<play-locale>.yml`,
  as the authority for terminology and register — the Play copy is human-translated
  and the App Store copy must not contradict it
- the character limits, as hard constraints

## What each subagent writes

`appstore/ios_translations/<apple-locale>.yml`, with every key from
`ios_source.yml` plus `source_sha`:

```yaml
source_sha: <the digest printed by find_stale.py's --digest flag>
subtitle: "..."
keywords: "..."
promotional_text: >
  ...
feature_08: >
  ...
```

## Rules the subagents must follow

- **Translate idiomatically, not literally.** This is marketing copy. Match the
  register of the Android translation for the same language.
- **The character limits are constraints on the writing, not a truncation step.**
  subtitle 30, keywords 100, promotional_text 170. A translation that overflows
  must be rewritten shorter, never cut off mid-word.
- **Keywords are search terms, not a sentence.** Comma separated, no space after
  the comma (it counts against the limit). Do not repeat words that already
  appear in the app name or subtitle — the App Store indexes those anyway.
- **Never write the words Android, Google Play or Play Store.** The validator
  rejects them in any field, in any locale.
- **Leave `{{ variable }}` references untouched** and in a grammatical position.
- **Leave a key out rather than guess.** An absent key falls back to English,
  which is better than a wrong translation.

## Finish

```bash
make appstore-metadata
make appstore-validate
```

`appstore-validate` enforces every limit. If a locale overflows, send it back to
a subagent with the measured length — do not truncate it yourself.
````

- [ ] **Step 8: Print the digest from the reporter**

So the skill's instructions are executable, add a `--digest` flag to
`.claude/skills/appstore-copy/find_stale.py` — insert before the `for locale in` loops in `main()`:

```python
    if "--digest" in sys.argv:
        print(meta.ios_source_digest(sources.ios_source))
        return 0
```

- [ ] **Step 9: Run the translations**

```bash
python3 .claude/skills/appstore-copy/find_stale.py
python3 .claude/skills/appstore-copy/find_stale.py --digest
```

Then follow the skill: dispatch one subagent per locale for all 34, five to eight in parallel, each writing `appstore/ios_translations/<apple-locale>.yml`.

`en-US` is the exception: it needs no translation, but it does need a file so it is not reported as missing. Write `appstore/ios_translations/en-US.yml` containing only `source_sha: <digest>`.

- [ ] **Step 10: Regenerate and validate**

```bash
make appstore-metadata
make appstore-validate
python3 .claude/skills/appstore-copy/find_stale.py    # expect no output
```

Expected: `appstore-validate` is clean, no locale falls back to English, and every subtitle, keywords and promotional_text value is within its limit. Spot-check Finnish, German and Japanese by reading `fastlane/metadata/{fi,de-DE,ja}/subtitle.txt`.

- [ ] **Step 11: Commit**

```bash
git add scripts/appstore_metadata.py scripts/assemble_appstore_metadata.py \
        scripts/test_appstore_metadata.py .claude/skills/appstore-copy \
        appstore/ios_translations fastlane/metadata
git commit -F - <<'EOF'
feat(appstore): localize the iOS-only store copy

Why:
The subtitle, keywords and promotional text have no Android counterpart,
and Android's subtitle_1 exceeds the App Store's 30-character limit in 22
of the 34 locales, so it cannot simply be reused. Leaving all three in
English would put an English line at the top of every non-English
listing and make the app unfindable in non-English search.

What Changed:
Adds appstore/ios_translations for all 34 locales, a source_sha digest so
a changed English source marks its translations stale, and the
appstore-copy skill that finds and dispatches the work. Regenerates the
metadata tree.

Validation:
make appstore-validate is clean; find_stale.py reports nothing; the
Finnish, German and Japanese subtitles were read and are within limits.

Impact:
Every locale's listing is now fully localized.
EOF
```

---

### Task 11: Documentation and end-to-end verification

**Files:**
- Create: `docs/howto/appstore-metadata.md`
- Modify: `CLAUDE.md`
- Create: `appstore/app_rating.json` `[operator, macOS]`

**Interfaces:**
- Consumes: everything.
- Produces: the operator-facing documentation.

- [ ] **Step 1: Write the how-to**

Create `docs/howto/appstore-metadata.md`:

````markdown
# App Store metadata

The App Store listing text for all 34 locales is generated from source and
uploaded with `fastlane deliver`. Screenshots are **not** part of this pipeline —
they are uploaded by hand, and the Deliverfile is configured so `deliver` never
touches them.

## Where the text comes from

| Layer | Where | Who maintains it |
|---|---|---|
| Description prose, in 51 languages | the Android repo's `play/` | Transifex translators, via the Android project |
| iOS overrides + subtitle/keywords/promo | `appstore/ios_source.yml` | here, English |
| Translations of those | `appstore/ios_translations/*.yml` | the `appstore-copy` skill |
| Categories, URLs, copyright | `appstore/app_info.yml` | here |
| Release notes | `appstore/release_notes.txt` | here, English only |
| Reviewer notes | `appstore/review_information.yml` | here |
| The uploaded tree | `fastlane/metadata/` | **generated — never edit by hand** |

## Commands

```bash
make appstore-metadata    # generate fastlane/metadata (Linux or macOS)
make appstore-validate    # drift + field limits + platform-name rule (offline)
make appstore-precheck    # Apple's own metadata rules (macOS, YubiKey)
make appstore-deliver     # upload the text metadata (macOS, YubiKey)
```

Generation and validation need nothing but Python and a checkout of the Android
repository. Clone `https://github.com/AndBible/and-bible` into the gitignored
`.and-bible-android/` at the repo root, or point `ANDBIBLE_ANDROID_ROOT` at an
existing checkout. Only the two upload targets need macOS and the App Store
Connect API key.

## Changing the copy

- **Shared prose** (any description bullet not overridden for iOS): change it in
  the Android project and let Transifex translate it. Then bump
  `appstore/android_source.lock` to the new Android commit, run
  `make appstore-metadata`, and commit the regenerated tree.
- **iOS-only text**: edit `appstore/ios_source.yml`, then run the `appstore-copy`
  skill to refresh the translations (the `source_sha` digest marks them stale
  automatically), then `make appstore-metadata`.
- **Never edit `fastlane/metadata/`.** `make appstore-validate` will reject it.

## Why the description differs from Play's

Four keys are overridden in `appstore/ios_source.yml`, each with the reason in a
comment: sync backends (no Google Drive on iOS), reading plans instead of
"reading goals", the AI agent's opt-in and bring-your-own-key framing, and the
offline claim (no modules ship with the app). One further difference is
mechanical: App Store Review Guideline 2.3.10 forbids naming other platforms, so
`appstore/locales.yml` rewrites `Android` to `iOS` in the rendered text, with
per-locale rules for the languages that inflect it.

## Reviewer contact details

`appstore/review_information.yml` holds only the notes — public information. The
contact details are personal data and must not be committed to this public
repository. Put them in `appstore/review_information.local.yml` (gitignored):

```yaml
first_name: "..."
last_name: "..."
phone_number: "+358..."
email_address: "..."
```

When the file is absent, those fields are omitted and `deliver` leaves whatever
App Store Connect already has.

## Age rating

`appstore/app_rating.json` holds the age-rating questionnaire answers in
`deliver`'s format. Its key set is defined by the installed fastlane version, so
do **not** hand-write it. Bootstrap it once from the live listing:

```bash
fastlane deliver download_metadata --api_key_path "$ASC_KEY_JSON"
cp fastlane/metadata/app_rating_config.json appstore/app_rating.json
```

then add `app_rating_config_path "./appstore/app_rating.json"` to the
`Deliverfile` and commit both.

## First release checklist

1. Create the app record in App Store Connect (bundle ID `org.andbible.ios`),
   set pricing and territories. `deliver` updates an existing record; it does not
   create one.
2. Confirm `https://andbible.org/privacy.html` is live — App Store Connect
   requires the privacy URL.
3. `make appstore-validate`
4. `make appstore-deliver`
5. `make appstore-precheck`
6. Upload screenshots by hand.
7. Fill in the age rating (or bootstrap `app_rating.json`, above).
8. Attach the build and submit for review.
````

- [ ] **Step 2: Point `CLAUDE.md` at it**

Add a section to `CLAUDE.md` next to the existing TestFlight material:

```markdown
## App Store metadata

Listing text for 34 locales is generated from the Android store copy plus an iOS
override layer and uploaded with `fastlane deliver`:
`make appstore-metadata` / `appstore-validate` / `appstore-precheck` /
`appstore-deliver`. Sources live in `appstore/`; `fastlane/metadata/` is
generated and must never be hand-edited. Screenshots are uploaded by hand and
`deliver` is configured not to touch them. See
`docs/howto/appstore-metadata.md`.
```

- [ ] **Step 3: Run the full verification**

```bash
python3 -m unittest discover -s scripts -p 'test_*.py' 2>&1 | tail -5
make appstore-validate
python3 .claude/skills/appstore-copy/find_stale.py
grep -ril 'android' fastlane/metadata/ || echo "no platform references"
python3 scripts/check_repo_standards.py commits --base-ref origin/main --head-ref HEAD
```

Expected: the whole `scripts/` test suite passes (not just the new file — confirm the refactor in Task 8 broke nothing), validation is clean, no locale is missing or stale, no platform reference survives, and every commit message in this branch satisfies the repo standard.

- [ ] **Step 4: Commit**

```bash
git add docs/howto/appstore-metadata.md CLAUDE.md
git commit -F - <<'EOF'
docs(appstore): document the metadata pipeline

Why:
The pipeline spans two repositories, four Make targets and a translation
skill, and half of it only runs on macOS. None of that is guessable from
the code.

What Changed:
Adds docs/howto/appstore-metadata.md covering where each layer of text
comes from, the four commands and where they run, how to change shared
versus iOS-only copy, why the description differs from Play's, how the
reviewer contact details stay out of this public repository, how to
bootstrap the age-rating file from the live listing, and a first-release
checklist. CLAUDE.md points at it.

Validation:
Full scripts/ test suite, make appstore-validate, find_stale.py and the
commit-message guardrail all pass.

Impact:
Documentation only.
EOF
```

---

## Notes for the executor

**What cannot be verified in the Linux dev container**, and must be reported as
unverified rather than claimed to pass:

- Task 8 entirely: `hdiutil`, `diskutil`, `gpg` with the YubiKey, `fastlane
  deliver` and `fastlane precheck` are all macOS-side. `bash -n` proves syntax,
  nothing more. **`upload-testflight.sh` is refactored in Task 8 and must be
  re-tested on the Mac before the next TestFlight upload.**
- Task 11's `app_rating.json` bootstrap: needs the live App Store Connect
  listing. Document it (Step 1 does); do not fabricate the file.
- The CI job in Task 9 runs for real only on GitHub, and only if the SHA in
  `android_source.lock` has been pushed to `github.com/AndBible/and-bible`. If it
  has not, say so.

**Pushing:** this work happens inside the gie container. Commit locally on the
container branch; the user pushes from the host. Never push from the container.
Commit the superrepo gitlink bump after each submodule commit.
