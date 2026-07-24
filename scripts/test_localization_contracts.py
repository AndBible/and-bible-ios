#!/usr/bin/env python3
"""Localization and presentation-boundary contract tests."""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_settings_localization_guardrails import (
    ANDROID_SHARED_KEY_MAPPINGS,
    PRODUCT_FEEDBACK_ANDROID_KEYS,
    PRODUCT_FEEDBACK_IOS_FALLBACKS,
    REMOVED_PRODUCT_FEEDBACK_KEYS,
    build_android_shared_localization,
    default_android_root,
    discover_ai_localization_keys,
    parse_ios_strings,
    product_feedback_values_for_locale,
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


class ProductFeedbackLocalizationContractTests(unittest.TestCase):
    """Keeps the complete manual feedback and crash-evidence copy synchronized."""

    def test_every_shipped_locale_contains_complete_product_feedback_copy(self) -> None:
        """Both resource trees must carry Android values and every truthful iOS fallback."""
        android_root = default_android_root()
        self.assertTrue(android_root.exists(), f"Android resources missing: {android_root}")
        catalog = build_android_shared_localization(REPO_ROOT, android_root)

        locale_sets = [
            {
                path.name.removesuffix(".lproj")
                for path in (REPO_ROOT / tree).glob("*.lproj")
            }
            for tree in ("AndBible", "Localizations")
        ]
        self.assertEqual(locale_sets[0], locale_sets[1])

        expected_keys = set(PRODUCT_FEEDBACK_ANDROID_KEYS) | set(
            PRODUCT_FEEDBACK_IOS_FALLBACKS
        )
        for locale in sorted(locale_sets[0]):
            expected = product_feedback_values_for_locale(catalog, locale)
            self.assertEqual(set(expected), expected_keys)
            values_by_tree = []
            for tree in ("AndBible", "Localizations"):
                raw_values = parse_ios_strings(
                    REPO_ROOT / tree / f"{locale}.lproj" / "Localizable.strings"
                )
                actual = {
                    key: unescape_ios(raw_values[key])
                    for key in expected_keys
                    if key in raw_values
                }
                self.assertEqual(set(actual), expected_keys, f"{tree}:{locale}")
                self.assertEqual(
                    REMOVED_PRODUCT_FEEDBACK_KEYS & set(raw_values),
                    set(),
                    f"{tree}:{locale}",
                )
                values_by_tree.append(actual)
            self.assertEqual(values_by_tree[0], expected, locale)
            self.assertEqual(values_by_tree[0], values_by_tree[1], locale)

    def test_product_feedback_source_uses_android_provenance_and_no_superseded_keys(self) -> None:
        """Runtime copy must stay linked to Android resources or declared iOS-only fallbacks."""
        catalog = build_android_shared_localization(REPO_ROOT, default_android_root())
        for key in PRODUCT_FEEDBACK_ANDROID_KEYS:
            self.assertEqual(catalog.source_key_by_key.get(key), key)

        source_paths = [
            "AndroidBugReportDialog.swift",
            "ProductFeedbackLogExporter.swift",
            "ProductFeedbackReportExport.swift",
            "ProductFeedbackReportPreparation.swift",
            "ShareSheet.swift",
        ]
        source_root = REPO_ROOT / "Sources/BibleUI/Sources/BibleUI/Shared"
        source = "\n".join(
            (source_root / name).read_text(encoding="utf-8")
            for name in source_paths
        )
        for key in PRODUCT_FEEDBACK_ANDROID_KEYS:
            self.assertIn(f'localized: "{key}"', source, key)
        for key in PRODUCT_FEEDBACK_IOS_FALLBACKS:
            self.assertIn(f'localized: "{key}"', source, key)
        for key in REMOVED_PRODUCT_FEEDBACK_KEYS:
            self.assertNotIn(f'localized: "{key}"', source, key)

    def test_ios_only_product_feedback_keys_stay_ios_only_until_android_owns_them(self) -> None:
        """A sanctioned iOS-only key must move to Android sourcing once Android owns it.

        The iOS-only registry exists only for strings absent from Android's committed catalog.
        When this test fails, Android has gained the listed keys (for example after the staged
        `android-ios-report-strings.patch` merges upstream and the pinned Android ref advances):
        move each key from ``PRODUCT_FEEDBACK_IOS_FALLBACKS`` into
        ``PRODUCT_FEEDBACK_ANDROID_KEYS`` and re-run the product-feedback sync so real
        translations replace the English fallback.
        """
        catalog = build_android_shared_localization(REPO_ROOT, default_android_root())
        android_owned = sorted(
            key for key in PRODUCT_FEEDBACK_IOS_FALLBACKS if key in catalog.english_by_key
        )
        self.assertEqual(
            android_owned,
            [],
            "Android now owns these product-feedback keys; move them to "
            "PRODUCT_FEEDBACK_ANDROID_KEYS and re-sync: " + ", ".join(android_owned),
        )
        from check_settings_localization_guardrails import PRODUCT_FEEDBACK_IOS_TRANSLATIONS

        unknown = sorted(
            set(PRODUCT_FEEDBACK_IOS_TRANSLATIONS) - set(PRODUCT_FEEDBACK_IOS_FALLBACKS)
        )
        self.assertEqual(
            unknown,
            [],
            "PRODUCT_FEEDBACK_IOS_TRANSLATIONS keys must be registered iOS-only fallbacks",
        )


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
