#!/usr/bin/env python3
"""
SETPAR-603 localization guardrails for settings parity keys.

Checks:
1. AndBible and Localizations trees must match for tracked settings keys.
2. No iOS locale can remain English for a key when Android has a non-English translation.
3. Per-key English-placeholder count may not exceed committed baseline (plus optional allowance).
4. The iOS locale_pref picker must match Android arrays.xml values that have iOS resources.

Usage:
  python3 scripts/check_settings_localization_guardrails.py
  python3 scripts/check_settings_localization_guardrails.py --write-baseline
  python3 scripts/check_settings_localization_guardrails.py --write-android-snapshot
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from datetime import date
from pathlib import Path
import re
import xml.etree.ElementTree as ET


PARITY_KEYS = [
    "choose_strongs_greek_dictionary_title",
    "choose_strongs_greek_dictionary_summary",
    "choose_strongs_hebrew_dictionary_title",
    "choose_strongs_hebrew_dictionary_summary",
    "choose_strongs_greek_morphology_title",
    "choose_strongs_greek_morphology_summary",
    "choose_word_lookup_dictionary_title",
    "choose_word_lookup_dictionary_summary",
    "prefs_behavior_customization_cat",
    "prefs_display_customization_cat",
    "prefs_advanced_settings_cat",
    "prefs_navigate_to_verse_title",
    "prefs_navigate_to_verse_summary",
    "prefs_open_links_in_special_window_title",
    "prefs_open_links_in_special_window_summary",
    "prefs_screen_keep_on_title",
    "prefs_screen_keep_on_summary",
    "prefs_double_tap_to_fullscreen_title",
    "prefs_double_tap_to_fullscreen_summary",
    "auto_fullscreen",
    "auto_fullscreen_summary",
    "prefs_toolbar_button_action_title",
    "prefs_toolbar_button_action_summary",
    "prefs_disable_two_step_bookmarking_title",
    "prefs_disable_two_step_bookmarking_summary",
    "prefs_bible_view_swipe_mode_title",
    "prefs_bible_view_swipe_mode_summary",
    "prefs_volume_keys_scroll_title",
    "prefs_volume_keys_scroll_summary",
    "prefs_night_mode_title",
    "prefs_night_mode_summary",
    "prefs_interface_locale_title",
    "prefs_interface_locale_summary",
    "prefs_e_ink_mode_title",
    "prefs_eink_mode_summary",
    "prefs_disable_animations_title",
    "prefs_disable_animations_summary",
    "prefs_disable_click_to_edit_title",
    "prefs_disable_click_to_edit_summary",
    "pref_font_size_multiplier_title",
    "full_screen_hide_buttons_pref_title",
    "full_screen_hide_buttons_pref_summary",
    "hide_window_buttons_title",
    "hide_window_buttons_summary",
    "hide_bible_reference_overlay_title",
    "hide_bible_reference_overlay_summary",
    "active_window_indicator_title",
    "active_window_indicator_summary",
    "prefs_experimental_features_title",
    "prefs_experimental_features_summary",
    "prefs_enable_bluetooth_title",
    "prefs_enable_bluetooth_summary",
    "prefs_show_error_box_title",
    "prefs_show_error_box_summary",
    "open_bible_links_title",
    "open_bible_links_summary",
    "crash_app",
    "crash_app_summary",
]


LOCALE_TO_ANDROID_VALUES = {
    "af": "values-af",
    "ar": "values-ar",
    "az": "values-az",
    "bg": "values-bg",
    "bn": "values-bn",
    "cs": "values-cs",
    "de": "values-de",
    "el": "values-el",
    "en": "values",
    "eo": "values-eo",
    "es": "values-es",
    "et": "values-et",
    "fi": "values-fi",
    "fr": "values-fr",
    "he": "values-iw",
    "hi": "values-hi",
    "hr": "values-hr",
    "hu": "values-hu",
    "id": "values-id",
    "it": "values-it",
    "kk": "values-kk",
    "ko": "values-ko",
    "lt": "values-lt",
    "ml": "values-ml",
    "my": "values-my",
    "nb": "values-nb",
    "nl": "values-nl",
    "pl": "values-pl",
    "pt": "values-pt",
    "pt-BR": "values-pt-rBR",
    "ro": "values-ro",
    "ru": "values-ru",
    "sk": "values-sk",
    "sl": "values-sl",
    "sr": "values-b+sr+RS",
    "sr-Latn": "values-b+sr+Latn",
    "sv": "values-sv",
    "ta": "values-ta",
    "te": "values-te",
    "tr": "values-tr",
    "uk": "values-uk",
    "uz": "values-uz",
    "yue": "values-yue",
    "zh-Hans": "values-zh-rCN",
    "zh-Hant": "values-zh-rTW",
}

ANDROID_ROOT_ENV = "ANDBIBLE_ANDROID_ROOT"

LINE_RE = re.compile(r'^"(?P<key>[^"]+)"\s*=\s*"(?P<val>(?:[^"\\]|\\.)*)";\s*$')
LOCALE_OPTIONS_BLOCK_RE = re.compile(
    r"private static let localeOptions:\s*\[LocaleOption\]\s*=\s*\[(?P<body>.*?)\n\s*\]",
    re.DOTALL,
)
SWIFT_LOCALE_OPTION_RE = re.compile(
    r'\.init\(\s*value:\s*"(?P<value>[^"]*)",\s*'
    r'labelKey:\s*"(?P<label_key>[^"]+)",\s*'
    r'labelDefault:\s*"(?P<label_default>[^"]*)"\s*\)',
    re.DOTALL,
)


LOCALE_PREF_RESOURCE_OVERRIDES = {
    "iw": "he",
    "in": "id",
    "zh-Hant-TW": "zh-Hant",
    "zh-Hans-CN": "zh-Hans",
}


def default_repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def default_android_root() -> Path:
    """Return the Android resource tree used for live parity checks.

    ANDBIBLE_ANDROID_ROOT points to the Android repository checkout root so
    bridge and localization guardrails can share one CI/local setup contract.
    """
    android_root_env = os.environ.get(ANDROID_ROOT_ENV)
    if android_root_env:
        return Path(android_root_env).expanduser() / "app" / "src" / "main" / "res"

    return Path(__file__).resolve().parents[2] / "and-bible" / "app" / "src" / "main" / "res"


def default_android_snapshot() -> Path:
    return (
        default_repo_root()
        / "scripts"
        / "fixtures"
        / "settings-localization"
        / "localization-android.json"
    )


def parse_ios_strings(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = LINE_RE.match(line.strip())
        if match:
            values[match.group("key")] = match.group("val")
    return values


def unescape_ios(value: str) -> str:
    return value.replace(r"\\", "\\").replace(r"\"", '"').replace(r"\n", "\n")


def parse_android_strings(path: Path) -> dict[str, str]:
    if not path.exists():
        return {}
    root = ET.parse(path).getroot()
    values: dict[str, str] = {}
    for node in root.findall("string"):
        name = node.get("name")
        if name:
            values[name] = "".join(node.itertext())
    return values


@dataclass(frozen=True)
class LocalePrefOption:
    value: str
    label_key: str


@dataclass
class LocalePrefAudit:
    supported_values: list[str]
    unsupported_values: list[str]
    extra_ios_locales: list[str]
    failures: list[str]


def parse_android_array_items(arrays_path: Path, array_name: str) -> list[str]:
    root = ET.parse(arrays_path).getroot()
    node = root.find(f"string-array[@name='{array_name}']")
    if node is None:
        raise ValueError(f"Android array not found: {array_name}")
    return ["".join(item.itertext()).strip() for item in node.findall("item")]


def build_android_locale_pref_options(android_root: Path) -> list[LocalePrefOption]:
    arrays_path = android_root / "values" / "arrays.xml"
    descriptions = parse_android_array_items(arrays_path, "prefs_interface_locale_descriptions")
    values = parse_android_array_items(arrays_path, "prefs_interface_locale_values")
    if len(descriptions) != len(values):
        raise ValueError(
            "Android locale_pref array length mismatch: "
            f"descriptions={len(descriptions)}, values={len(values)}"
        )

    options: list[LocalePrefOption] = []
    for description, value in zip(descriptions, values):
        if not description.startswith("@string/"):
            raise ValueError(f"Android locale_pref description is not a string ref: {description}")
        options.append(LocalePrefOption(value=value, label_key=description.removeprefix("@string/")))
    return options


def load_snapshot_payload(path: Path) -> dict[str, object]:
    """Load a generated Android parity snapshot as a JSON object.

    Snapshot readers use this boundary so malformed files fail before their
    values can be coerced into plausible-looking audit inputs. The function
    performs only file I/O and JSON decoding, returning the parsed object or
    raising ValueError when the snapshot root shape is not valid.
    """
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"Snapshot root must be an object: {path}")
    return payload


def load_android_locale_pref_options_from_snapshot(path: Path) -> list[LocalePrefOption]:
    """Load locale_pref options from a generated Android parity snapshot.

    The default Android option intentionally uses an empty string value, but
    both snapshot fields must still be present strings. Missing or non-string
    values indicate a corrupt snapshot and are reported immediately so the
    parity audit does not continue with fabricated option values.
    """
    payload = load_snapshot_payload(path)
    raw_options = payload.get("locale_pref_options")
    if not isinstance(raw_options, list):
        raise ValueError(f"Snapshot missing locale_pref_options: {path}")

    options: list[LocalePrefOption] = []
    for index, raw in enumerate(raw_options):
        if not isinstance(raw, dict):
            raise ValueError(f"Invalid locale_pref_options[{index}] in {path}")
        value = raw.get("value")
        if not isinstance(value, str):
            raise ValueError(
                f"Invalid locale_pref_options[{index}].value in {path}: expected string"
            )
        label_key = raw.get("label_key")
        if not isinstance(label_key, str):
            raise ValueError(
                f"Invalid locale_pref_options[{index}].label_key in {path}: expected string"
            )
        options.append(
            LocalePrefOption(
                value=value,
                label_key=label_key,
            )
        )
    return options


def parse_swift_locale_options(settings_view_path: Path) -> list[LocalePrefOption]:
    text = settings_view_path.read_text(encoding="utf-8")
    block = LOCALE_OPTIONS_BLOCK_RE.search(text)
    if block is None:
        raise ValueError(f"Could not find SettingsView.localeOptions in {settings_view_path}")

    options = [
        LocalePrefOption(value=match.group("value"), label_key=match.group("label_key"))
        for match in SWIFT_LOCALE_OPTION_RE.finditer(block.group("body"))
    ]
    if not options:
        raise ValueError(f"Could not parse SettingsView.localeOptions in {settings_view_path}")
    return options


def ios_resource_locale_for_locale_pref(value: str) -> str:
    return LOCALE_PREF_RESOURCE_OVERRIDES.get(value, value)


def ios_localization_locales(repo_root: Path) -> set[str]:
    ios_a_root = repo_root / "AndBible"
    ios_b_root = repo_root / "Localizations"
    locales_a = {
        p.name.removesuffix(".lproj")
        for p in ios_a_root.glob("*.lproj")
        if p.name.endswith(".lproj")
    }
    locales_b = {
        p.name.removesuffix(".lproj")
        for p in ios_b_root.glob("*.lproj")
        if p.name.endswith(".lproj")
    }
    return locales_a & locales_b


def audit_locale_pref_contract(
    repo_root: Path,
    android_options: list[LocalePrefOption],
) -> LocalePrefAudit:
    swift_options = parse_swift_locale_options(
        repo_root / "Sources" / "BibleUI" / "Sources" / "BibleUI" / "Settings" / "SettingsView.swift"
    )
    ios_locales = ios_localization_locales(repo_root)
    android_values = [option.value for option in android_options]
    swift_values = [option.value for option in swift_options]
    supported_options = [
        option
        for option in android_options
        if option.value == "" or ios_resource_locale_for_locale_pref(option.value) in ios_locales
    ]
    supported_values = [option.value for option in supported_options]
    unsupported_values = [
        option.value
        for option in android_options
        if option.value and option.value not in supported_values
    ]
    android_label_by_value = {option.value: option.label_key for option in android_options}
    ios_resource_values = {
        ios_resource_locale_for_locale_pref(value)
        for value in android_values
        if value
    }
    extra_ios_locales = sorted(locale for locale in ios_locales if locale not in ios_resource_values)

    failures: list[str] = []
    if swift_values != supported_values:
        missing = [value for value in supported_values if value not in swift_values]
        unsupported = [value for value in swift_values if value not in supported_values]
        if missing:
            failures.append(f"locale_pref missing supported Android values: {', '.join(missing)}")
        if unsupported:
            failures.append(f"locale_pref shows unsupported Android values: {', '.join(unsupported)}")
        if not missing and not unsupported:
            failures.append(
                "locale_pref order drift: Swift options must preserve Android arrays.xml order "
                "after unsupported iOS locales are removed"
            )

    for option in swift_options:
        expected_label = android_label_by_value.get(option.value)
        if expected_label is None:
            continue
        if option.label_key != expected_label:
            failures.append(
                "locale_pref label key mismatch for "
                f"{option.value or '<default>'}: android={expected_label}, swift={option.label_key}"
            )

    return LocalePrefAudit(
        supported_values=supported_values,
        unsupported_values=unsupported_values,
        extra_ios_locales=extra_ios_locales,
        failures=failures,
    )


def build_android_non_english_by_key(android_root: Path) -> dict[str, list[str]]:
    android_base = parse_android_strings(android_root / "values" / "strings.xml")
    android_base.update(parse_android_strings(android_root / "values" / "untranslated_strings.xml"))
    android_by_locale = {
        loc: parse_android_strings(android_root / qualifier / "strings.xml")
        for loc, qualifier in LOCALE_TO_ANDROID_VALUES.items()
    }

    non_english_by_key: dict[str, list[str]] = {k: [] for k in PARITY_KEYS}
    for key in PARITY_KEYS:
        base_value = android_base.get(key, "")
        for locale, locale_strings in android_by_locale.items():
            locale_value = locale_strings.get(key)
            if locale_value is not None and locale_value != base_value:
                non_english_by_key[key].append(locale)
        non_english_by_key[key].sort()

    return non_english_by_key


def load_android_non_english_snapshot(path: Path) -> dict[str, list[str]]:
    """Load Android translation coverage from a generated parity snapshot.

    Each tracked parity key must be present and mapped to a list of locale
    strings. Rejecting missing keys and non-string locales keeps a corrupt
    baseline from weakening the localization audit through implicit defaults.
    """
    payload = load_snapshot_payload(path)
    raw = payload.get("android_non_english_by_key")
    if not isinstance(raw, dict):
        raise ValueError(f"Snapshot missing android_non_english_by_key: {path}")

    non_english_by_key: dict[str, list[str]] = {}
    for key in PARITY_KEYS:
        values = raw.get(key)
        if not isinstance(values, list):
            raise ValueError(f"Invalid android_non_english_by_key[{key}] in {path}: expected list")

        locales: list[str] = []
        for index, locale in enumerate(values):
            if not isinstance(locale, str):
                raise ValueError(
                    f"Invalid android_non_english_by_key[{key}][{index}] in {path}: "
                    "expected string"
                )
            locales.append(locale)

        non_english_by_key[key] = sorted(locales)
    return non_english_by_key


def write_android_non_english_snapshot(
    path: Path,
    android_root: Path,
    non_english_by_key: dict[str, list[str]],
    locale_pref_options: list[LocalePrefOption],
) -> None:
    payload = {
        "generated_on": date.today().isoformat(),
        "source_android_res": str(android_root),
        "parity_keys": PARITY_KEYS,
        "locale_to_android_values": LOCALE_TO_ANDROID_VALUES,
        "locale_pref_options": [
            {"value": option.value, "label_key": option.label_key}
            for option in locale_pref_options
        ],
        "android_non_english_by_key": non_english_by_key,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


@dataclass
class Audit:
    locales: list[str]
    english_placeholder_by_key: dict[str, list[str]]
    ios_gap_by_key: dict[str, list[str]]
    tree_mismatches: list[str]
    android_source: str


def run_audit(
    repo_root: Path,
    android_non_english_by_key: dict[str, list[str]],
    android_source: str,
) -> Audit:
    ios_a_root = repo_root / "AndBible"
    ios_b_root = repo_root / "Localizations"

    en_a = parse_ios_strings(ios_a_root / "en.lproj" / "Localizable.strings")
    en_b = parse_ios_strings(ios_b_root / "en.lproj" / "Localizable.strings")
    english = {k: unescape_ios(en_a[k]) for k in PARITY_KEYS}

    tree_mismatches: list[str] = []
    for key in PARITY_KEYS:
        if key not in en_a or key not in en_b:
            tree_mismatches.append(f"missing_en_key:{key}")
        elif en_a[key] != en_b[key]:
            tree_mismatches.append(f"en_tree_mismatch:{key}")

    locales = sorted(
        p.name.replace(".lproj", "")
        for p in ios_a_root.glob("*.lproj")
        if p.name.endswith(".lproj") and p.name != "en.lproj"
    )

    english_placeholder_by_key = {k: [] for k in PARITY_KEYS}
    ios_gap_by_key = {k: [] for k in PARITY_KEYS}

    for locale in locales:
        ios_a = parse_ios_strings(ios_a_root / f"{locale}.lproj" / "Localizable.strings")
        ios_b = parse_ios_strings(ios_b_root / f"{locale}.lproj" / "Localizable.strings")

        for key in PARITY_KEYS:
            if key not in ios_a or key not in ios_b:
                tree_mismatches.append(f"missing_locale_key:{locale}:{key}")
                continue

            va = unescape_ios(ios_a[key])
            vb = unescape_ios(ios_b[key])
            if va != vb:
                tree_mismatches.append(f"locale_tree_mismatch:{locale}:{key}")

            ios_is_english = va == english[key]
            if ios_is_english:
                english_placeholder_by_key[key].append(locale)

            if ios_is_english and locale in android_non_english_by_key.get(key, []):
                ios_gap_by_key[key].append(locale)

    for key in PARITY_KEYS:
        english_placeholder_by_key[key].sort()
        ios_gap_by_key[key].sort()

    return Audit(
        locales=locales,
        english_placeholder_by_key=english_placeholder_by_key,
        ios_gap_by_key=ios_gap_by_key,
        tree_mismatches=tree_mismatches,
        android_source=android_source,
    )


def write_baseline(path: Path, audit: Audit) -> None:
    payload = {
        "generated_on": date.today().isoformat(),
        "parity_keys": PARITY_KEYS,
        "locales": audit.locales,
        "english_placeholder_by_key": audit.english_placeholder_by_key,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    repo_root_default = default_repo_root()
    android_root_default = default_android_root()
    android_snapshot_default = default_android_snapshot()

    parser = argparse.ArgumentParser(description="Settings localization parity guardrails (SETPAR-603)")
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=repo_root_default,
        help="Path to and-bible-ios repository root",
    )
    parser.add_argument(
        "--android-root",
        type=Path,
        default=android_root_default,
        help="Path to Android app res directory",
    )
    parser.add_argument(
        "--android-snapshot",
        type=Path,
        default=android_snapshot_default,
        help="Path to committed Android non-English parity snapshot JSON",
    )
    parser.add_argument(
        "--baseline",
        type=Path,
        default=(
            repo_root_default
            / "scripts"
            / "fixtures"
            / "settings-localization"
            / "localization-guardrail.json"
        ),
        help="Baseline JSON path",
    )
    parser.add_argument(
        "--allow-count-increase",
        type=int,
        default=0,
        help="Allowed increase in English-placeholder count per key vs baseline",
    )
    parser.add_argument(
        "--write-baseline",
        action="store_true",
        help="Write baseline file from current state and exit 0",
    )
    parser.add_argument(
        "--write-android-snapshot",
        action="store_true",
        help="Write Android non-English parity snapshot from --android-root and exit 0",
    )
    args = parser.parse_args()

    if args.write_android_snapshot:
        if not args.android_root.exists():
            print(f"Android root not found: {args.android_root}", file=sys.stderr)
            return 2
        non_english_by_key = build_android_non_english_by_key(args.android_root)
        locale_pref_options = build_android_locale_pref_options(args.android_root)
        write_android_non_english_snapshot(
            args.android_snapshot,
            args.android_root,
            non_english_by_key,
            locale_pref_options,
        )
        print(f"Wrote Android snapshot: {args.android_snapshot}")
        return 0

    if args.android_root.exists():
        non_english_by_key = build_android_non_english_by_key(args.android_root)
        locale_pref_options = build_android_locale_pref_options(args.android_root)
        android_source = f"live:{args.android_root}"
    elif args.android_snapshot.exists():
        try:
            non_english_by_key = load_android_non_english_snapshot(args.android_snapshot)
            locale_pref_options = load_android_locale_pref_options_from_snapshot(args.android_snapshot)
        except ValueError as exc:
            print(str(exc), file=sys.stderr)
            return 2
        android_source = f"snapshot:{args.android_snapshot}"
    else:
        print(
            "Neither Android res directory nor snapshot file is available.\n"
            f"  android_root: {args.android_root}\n"
            f"  android_snapshot: {args.android_snapshot}",
            file=sys.stderr,
        )
        return 2

    audit = run_audit(args.repo_root, non_english_by_key, android_source)
    locale_pref_audit = audit_locale_pref_contract(args.repo_root, locale_pref_options)

    if args.write_baseline:
        write_baseline(args.baseline, audit)
        print(f"Wrote baseline: {args.baseline}")
        return 0

    if not args.baseline.exists():
        print(f"Baseline not found: {args.baseline}", file=sys.stderr)
        print("Run with --write-baseline first.", file=sys.stderr)
        return 2

    baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
    base_counts = {
        key: len(locales)
        for key, locales in baseline.get("english_placeholder_by_key", {}).items()
    }

    failures: list[str] = []

    if audit.tree_mismatches:
        failures.append("Tree consistency failures:")
        failures.extend(f"  - {item}" for item in sorted(audit.tree_mismatches))

    ios_gap_count = sum(len(v) for v in audit.ios_gap_by_key.values())
    if ios_gap_count > 0:
        failures.append("iOS-vs-Android translation gaps (must be zero):")
        for key in PARITY_KEYS:
            bad = audit.ios_gap_by_key.get(key, [])
            if bad:
                failures.append(f"  - {key}: {', '.join(bad)}")

    for key in PARITY_KEYS:
        current = len(audit.english_placeholder_by_key.get(key, []))
        baseline_count = int(base_counts.get(key, 0))
        if current > baseline_count + args.allow_count_increase:
            failures.append(
                f"English-placeholder count regression for {key}: "
                f"baseline={baseline_count}, current={current}, "
                f"allowed_increase={args.allow_count_increase}"
            )

    if locale_pref_audit.failures:
        failures.append("locale_pref option contract failures:")
        failures.extend(f"  - {item}" for item in locale_pref_audit.failures)

    print("SETPAR-603 guardrail summary")
    print(f"- tree mismatches: {len(audit.tree_mismatches)}")
    print(f"- ios_gap count: {ios_gap_count}")
    print(f"- android source: {audit.android_source}")
    print(f"- keys checked: {len(PARITY_KEYS)}")
    print(f"- locales checked: {len(audit.locales)}")
    print(f"- locale_pref supported values: {len(locale_pref_audit.supported_values)}")
    print(f"- locale_pref unavailable Android values: {len(locale_pref_audit.unsupported_values)}")
    print(f"- locale_pref extra iOS-only resource locales: {len(locale_pref_audit.extra_ios_locales)}")

    if failures:
        print("\nFAILURES:")
        for line in failures:
            print(line)
        return 1

    print("Guardrails passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
