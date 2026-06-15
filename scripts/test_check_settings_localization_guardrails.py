#!/usr/bin/env python3
"""
Unit tests for settings localization guardrails.
"""

from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_settings_localization_guardrails import (
    LocalePrefOption,
    PARITY_KEYS,
    audit_locale_pref_contract,
    load_android_locale_pref_options_from_snapshot,
    load_android_non_english_snapshot,
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

    def write_snapshot(self, root: Path, payload: object) -> Path:
        """Write a temporary Android snapshot fixture for parser contract tests.

        The helper performs file I/O only inside the caller's temporary
        directory and returns the snapshot path. Tests use it to make malformed
        JSON shapes explicit without depending on the committed baseline file.
        """
        path = root / "snapshot.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

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

    def test_locale_pref_snapshot_loader_preserves_default_empty_value(self) -> None:
        """Protects the Android default locale option while validating snapshot shape.

        Android uses an empty string for the "use system default" value. The
        loader must preserve that value exactly while still requiring generated
        snapshot fields to be present strings. A failure means the fallback
        snapshot path either drops a valid Android option or accepts malformed
        locale picker data.
        """
        with tempfile.TemporaryDirectory() as tmp:
            path = self.write_snapshot(
                Path(tmp),
                {
                    "locale_pref_options": [
                        {"value": "", "label_key": "lang_default"},
                        {"value": "en", "label_key": "lang_english"},
                    ]
                },
            )

            options = load_android_locale_pref_options_from_snapshot(path)

        self.assertEqual(
            options,
            [
                LocalePrefOption("", "lang_default"),
                LocalePrefOption("en", "lang_english"),
            ],
        )

    def test_locale_pref_snapshot_loader_rejects_missing_or_non_string_fields(self) -> None:
        """Rejects corrupt locale_pref snapshot rows at the parser boundary.

        The committed snapshot is generated from Android arrays.xml, so missing,
        null, or non-string fields indicate baseline corruption rather than
        legitimate Android data. A failure means invalid snapshot data can be
        coerced into plausible audit inputs and hide the real contract error.
        """
        cases = [
            ("missing value", {"label_key": "lang_default"}, "value"),
            ("null value", {"value": None, "label_key": "lang_default"}, "value"),
            ("numeric value", {"value": 42, "label_key": "lang_default"}, "value"),
            ("missing label key", {"value": ""}, "label_key"),
            ("numeric label key", {"value": "", "label_key": 42}, "label_key"),
        ]

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, row, field in cases:
                with self.subTest(name=name):
                    path = self.write_snapshot(root, {"locale_pref_options": [row]})

                    with self.assertRaises(ValueError) as failure:
                        load_android_locale_pref_options_from_snapshot(path)

                    self.assertIn(f"locale_pref_options[0].{field}", str(failure.exception))

    def test_non_english_snapshot_loader_rejects_missing_key(self) -> None:
        """Requires generated Android coverage snapshots to contain every parity key.

        Missing keys would make the audit treat Android translation coverage as
        empty for that setting and weaken parity enforcement. A failure means a
        truncated snapshot can silently lower the validation bar.
        """
        with tempfile.TemporaryDirectory() as tmp:
            payload = {
                "android_non_english_by_key": {
                    key: []
                    for key in PARITY_KEYS[:-1]
                }
            }
            path = self.write_snapshot(Path(tmp), payload)

            with self.assertRaises(ValueError) as failure:
                load_android_non_english_snapshot(path)

        self.assertIn(f"android_non_english_by_key[{PARITY_KEYS[-1]}]", str(failure.exception))

    def test_non_english_snapshot_loader_rejects_non_string_locales(self) -> None:
        """Rejects corrupt Android coverage locale lists before audit comparison.

        Generated locale lists should contain Android/iOS locale identifiers as
        strings. A failure means invalid snapshot values can be string-coerced
        and sorted into the audit, producing confusing parity failures later.
        """
        with tempfile.TemporaryDirectory() as tmp:
            payload = {
                "android_non_english_by_key": {
                    key: []
                    for key in PARITY_KEYS
                }
            }
            payload["android_non_english_by_key"][PARITY_KEYS[0]] = ["fr", None]
            path = self.write_snapshot(Path(tmp), payload)

            with self.assertRaises(ValueError) as failure:
                load_android_non_english_snapshot(path)

        self.assertIn(
            f"android_non_english_by_key[{PARITY_KEYS[0]}][1]",
            str(failure.exception),
        )


if __name__ == "__main__":
    unittest.main()
