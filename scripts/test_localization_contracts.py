#!/usr/bin/env python3
"""Localization and presentation-boundary contract tests."""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_settings_localization_guardrails import (
    ANDROID_SHARED_KEY_MAPPINGS,
    build_android_shared_localization,
    default_android_root,
    discover_ai_localization_keys,
    parse_ios_strings,
    unescape_ios,
)


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_INSTALL_LOCALIZATION_KEYS = {
    "error_occurred",
    "extracting_zip_file",
    "install_failed_reason",
    "install_zip_successfull",
    "module_install_phase_committing",
    "module_install_phase_downloading",
    "module_install_phase_queued",
    "storage_space_warning",
}
EXPECTED_ANDROID_SOURCES = {
    "error_occurred": "error_occurred",
    "extracting_zip_file": "extracting_zip_file",
    "install_failed_reason": "install_failed_reason",
    "install_zip_successfull": "install_zip_successfull",
    "module_install_phase_committing": "install_zip_title",
    "module_install_phase_downloading": "download_document_confirm_prefix",
    "module_install_phase_queued": "please_wait",
    "storage_space_warning": "storage_space_warning",
}


class LocalizationContractTests(unittest.TestCase):
    """Keeps every shipped locale and module-install presentation path in one contract."""

    def test_every_shipped_locale_contains_exact_android_backed_values(self) -> None:
        """Both resource trees must contain all module-install keys with Android-derived values."""
        android_root = default_android_root()
        self.assertTrue(android_root.exists(), f"Android resources missing: {android_root}")
        catalog = build_android_shared_localization(REPO_ROOT, android_root)
        self.assertTrue(MODULE_INSTALL_LOCALIZATION_KEYS.issubset(catalog.english_by_key))

        locale_sets = []
        for tree in ("AndBible", "Localizations"):
            locale_sets.append(
                {
                    path.name.removesuffix(".lproj")
                    for path in (REPO_ROOT / tree).glob("*.lproj")
                }
            )
        self.assertEqual(locale_sets[0], locale_sets[1])

        for locale in sorted(locale_sets[0]):
            values_by_tree = []
            for tree in ("AndBible", "Localizations"):
                raw_values = parse_ios_strings(
                    REPO_ROOT / tree / f"{locale}.lproj" / "Localizable.strings"
                )
                values_by_tree.append(
                    {
                        key: unescape_ios(raw_values[key])
                        for key in MODULE_INSTALL_LOCALIZATION_KEYS
                        if key in raw_values
                    }
                )
            self.assertEqual(set(values_by_tree[0]), MODULE_INSTALL_LOCALIZATION_KEYS, locale)
            self.assertEqual(values_by_tree[0], values_by_tree[1], locale)

            expected = {
                key: catalog.translations_by_locale.get(locale, {}).get(
                    key,
                    catalog.english_by_key[key],
                )
                for key in MODULE_INSTALL_LOCALIZATION_KEYS
            }
            self.assertEqual(values_by_tree[0], expected, locale)

    def test_android_key_provenance_and_swift_usage_remain_explicit(self) -> None:
        """Presentation code must not regress to English-only keys or raw storage errors."""
        for ios_key, android_key in EXPECTED_ANDROID_SOURCES.items():
            self.assertEqual(ANDROID_SHARED_KEY_MAPPINGS.get(ios_key), android_key)

        browser_source = (
            REPO_ROOT
            / "Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserView.swift"
        ).read_text(encoding="utf-8")
        error_source = (
            REPO_ROOT
            / "Sources/BibleUI/Sources/BibleUI/Downloads/ModuleInstallErrorPresentation.swift"
        ).read_text(encoding="utf-8")
        self.assertNotIn('localized: "module_install_phase_extracting"', browser_source)
        self.assertNotIn('localized: "module_install_phase_complete"', browser_source)
        self.assertNotIn('localized: "error_download_failed"', browser_source)
        self.assertIn('localized: "extracting_zip_file"', browser_source)
        self.assertIn('localized: "install_zip_successfull"', browser_source)
        self.assertIn('localized: "storage_space_warning"', error_source)
        self.assertIn('localized: "install_failed_reason"', error_source)


class AILocalizationContractTests(unittest.TestCase):
    """Verifies Android-owned AI text across both shipped localization trees."""

    def test_every_android_ai_translation_is_shipped_in_both_ios_trees(self) -> None:
        """Source-referenced AI keys must exactly match Android wherever Android translates them."""
        android_root = default_android_root()
        self.assertTrue(android_root.exists(), f"Android resources missing: {android_root}")
        keys = discover_ai_localization_keys(REPO_ROOT)
        catalog = build_android_shared_localization(REPO_ROOT, android_root)
        self.assertTrue(keys)
        self.assertEqual(keys - set(catalog.english_by_key), set())

        locale_sets = [
            {
                path.name.removesuffix(".lproj")
                for path in (REPO_ROOT / tree).glob("*.lproj")
            }
            for tree in ("AndBible", "Localizations")
        ]
        self.assertEqual(locale_sets[0], locale_sets[1])

        for locale in sorted(locale_sets[0]):
            expected = (
                {key: catalog.english_by_key[key] for key in keys}
                if locale == "en"
                else {
                    key: value
                    for key, value in catalog.translations_by_locale.get(locale, {}).items()
                    if key in keys
                }
            )
            for tree in ("AndBible", "Localizations"):
                raw_values = parse_ios_strings(
                    REPO_ROOT / tree / f"{locale}.lproj" / "Localizable.strings"
                )
                actual = {
                    key: unescape_ios(raw_values[key])
                    for key in expected
                    if key in raw_values
                }
                self.assertEqual(set(actual), set(expected), f"{tree}:{locale}")
                self.assertEqual(actual, expected, f"{tree}:{locale}")


if __name__ == "__main__":
    unittest.main()
