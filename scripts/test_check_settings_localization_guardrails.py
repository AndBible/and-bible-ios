#!/usr/bin/env python3
"""
Unit tests for settings localization guardrails.
"""

from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_settings_localization_guardrails import (
    LocalePrefOption,
    audit_locale_pref_contract,
)


class SettingsLocalizationGuardrailTests(unittest.TestCase):
    """Covers the Android-backed locale_pref picker contract."""

    def make_repo(
        self,
        root: Path,
        swift_options: list[LocalePrefOption],
        ios_locales: list[str],
    ) -> None:
        for tree in ["AndBible", "Localizations"]:
            for locale in ios_locales:
                (root / tree / f"{locale}.lproj").mkdir(parents=True)

        settings_path = (
            root
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Settings"
            / "SettingsView.swift"
        )
        settings_path.parent.mkdir(parents=True)
        option_lines = [
            "    private static let localeOptions: [LocaleOption] = [",
        ]
        for option in swift_options:
            option_lines.append(
                "        "
                f'.init(value: "{option.value}", '
                f'labelKey: "{option.label_key}", '
                f'labelDefault: "{option.label_key}")'
            )
        option_lines.append("    ]")
        settings_path.write_text("\n".join(option_lines) + "\n", encoding="utf-8")

    def test_locale_pref_contract_keeps_supported_android_values_only(self) -> None:
        android_options = [
            LocalePrefOption("", "lang_default"),
            LocalePrefOption("en", "lang_english"),
            LocalePrefOption("iw", "lang_hebrew"),
            LocalePrefOption("ca", "lang_catalan"),
        ]
        swift_options = [
            LocalePrefOption("", "lang_default"),
            LocalePrefOption("en", "lang_english"),
            LocalePrefOption("iw", "lang_hebrew"),
        ]

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_repo(root, swift_options, ["en", "he"])

            audit = audit_locale_pref_contract(root, android_options)

        self.assertEqual(audit.supported_values, ["", "en", "iw"])
        self.assertEqual(audit.unsupported_values, ["ca"])
        self.assertEqual(audit.failures, [])

    def test_locale_pref_contract_reports_missing_supported_value(self) -> None:
        android_options = [
            LocalePrefOption("", "lang_default"),
            LocalePrefOption("en", "lang_english"),
            LocalePrefOption("iw", "lang_hebrew"),
        ]
        swift_options = [
            LocalePrefOption("", "lang_default"),
            LocalePrefOption("en", "lang_english"),
        ]

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_repo(root, swift_options, ["en", "he"])

            audit = audit_locale_pref_contract(root, android_options)

        self.assertIn("locale_pref missing supported Android values: iw", audit.failures)

    def test_locale_pref_contract_reports_unsupported_swift_value(self) -> None:
        android_options = [
            LocalePrefOption("", "lang_default"),
            LocalePrefOption("en", "lang_english"),
            LocalePrefOption("ca", "lang_catalan"),
        ]
        swift_options = [
            LocalePrefOption("", "lang_default"),
            LocalePrefOption("en", "lang_english"),
            LocalePrefOption("ca", "lang_catalan"),
        ]

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_repo(root, swift_options, ["en"])

            audit = audit_locale_pref_contract(root, android_options)

        self.assertIn("locale_pref shows unsupported Android values: ca", audit.failures)

    def test_locale_pref_contract_maps_android_values_to_ios_resource_names(self) -> None:
        android_options = [
            LocalePrefOption("", "lang_default"),
            LocalePrefOption("iw", "lang_hebrew"),
            LocalePrefOption("in", "lang_indonesian"),
            LocalePrefOption("zh-Hant-TW", "lang_chinese_traditional"),
            LocalePrefOption("zh-Hans-CN", "lang_chinese_simplified"),
        ]

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.make_repo(root, android_options, ["en", "he", "id", "zh-Hant", "zh-Hans"])

            audit = audit_locale_pref_contract(root, android_options)

        self.assertEqual(audit.supported_values, ["", "iw", "in", "zh-Hant-TW", "zh-Hans-CN"])
        self.assertEqual(audit.failures, [])


if __name__ == "__main__":
    unittest.main()
