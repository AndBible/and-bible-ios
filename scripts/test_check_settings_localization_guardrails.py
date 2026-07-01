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
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_settings_localization_guardrails as localization_guardrails
from check_settings_localization_guardrails import (
    LocalePrefOption,
    PARITY_KEYS,
    audit_android_shared_translations,
    audit_locale_pref_contract,
    build_android_non_english_by_key,
    build_android_shared_localization,
    load_android_locale_pref_options_from_snapshot,
    load_android_non_english_snapshot,
    parse_ios_strings,
    sync_android_shared_translations,
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

    def write_ios_strings(self, root: Path, tree: str, locale: str, values: dict[str, str]) -> None:
        """Create one iOS Localizable.strings fixture with deterministic key ordering.

        Tests use this helper to model both bundled `AndBible` resources and the
        mirrored `Localizations` tree. A failure in callers usually means the
        Android-shared localization audit can pass while one iOS resource tree
        remains unsynchronized.
        """
        path = root / tree / f"{locale}.lproj" / "Localizable.strings"
        path.parent.mkdir(parents=True, exist_ok=True)
        body = "".join(f'"{key}" = "{value}";\n' for key, value in sorted(values.items()))
        path.write_text(body, encoding="utf-8")

    def write_android_strings(
        self,
        android_root: Path,
        qualifier: str,
        values: dict[str, str],
    ) -> None:
        """Create one Android strings.xml fixture for source-of-truth parity tests.

        The helper writes only `<string>` resources because the shared-key audit
        intentionally ignores Android arrays and plurals. Failures in tests that
        use this fixture mean same-name iOS/Android string contracts are no
        longer derived from Android's XML resource shape.
        """
        path = android_root / qualifier / "strings.xml"
        path.parent.mkdir(parents=True, exist_ok=True)
        rows = ["<resources>"]
        rows.extend(f'  <string name="{key}">{value}</string>' for key, value in sorted(values.items()))
        rows.append("</resources>")
        path.write_text("\n".join(rows) + "\n", encoding="utf-8")

    def make_shared_translation_repo(self, root: Path, locales: list[str]) -> None:
        """Create the minimum non-localization files required by existing audits.

        Shared-key tests call focused helpers directly, but they still need both
        iOS localization trees to exist so missing-tree failures are meaningful.
        The helper has no cleanup side effects outside the caller's temporary
        directory.
        """
        for tree in ["AndBible", "Localizations"]:
            for locale in locales:
                (root / tree / f"{locale}.lproj").mkdir(parents=True, exist_ok=True)

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

    def test_default_android_root_uses_shared_android_checkout_env(self) -> None:
        """Derives the Android resource path from the shared checkout env var.

        CI exposes ANDBIBLE_ANDROID_ROOT as the repository root so all parity
        scripts agree on one cloned checkout. A failure means localization can
        keep using stale snapshots while other parity checks use live Android.
        """
        with mock.patch.dict("os.environ", {"ANDBIBLE_ANDROID_ROOT": "/tmp/and-bible"}):
            self.assertEqual(
                localization_guardrails.default_android_root(),
                Path("/tmp/and-bible/app/src/main/res"),
            )

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

    def test_android_non_english_builder_uses_semantic_android_escapes(self) -> None:
        """Avoids false translated-locale coverage from Android XML escaping.

        Android English may escape quotes as backslash sequences while a locale
        file contains the same runtime text without the escape. The settings
        guardrail should not classify that locale as translated, or iOS will be
        forced to replace a correct English fallback with an identical value.
        """
        with tempfile.TemporaryDirectory() as tmp:
            android_root = Path(tmp)
            base_values = {key: "Base" for key in PARITY_KEYS}
            locale_values = {key: "Base" for key in PARITY_KEYS}
            base_values[PARITY_KEYS[0]] = r'Show \"Selection\"'
            locale_values[PARITY_KEYS[0]] = r'Show \"Selection\"'
            self.write_android_strings(android_root, "values", base_values)
            self.write_android_strings(android_root, "values-fr", locale_values)

            non_english_by_key = build_android_non_english_by_key(android_root)

        self.assertNotIn("fr", non_english_by_key[PARITY_KEYS[0]])

    def test_shared_catalog_uses_same_name_keys_with_matching_english_text(self) -> None:
        """Selects Android-backed iOS strings using runtime text semantics.

        Setup creates same-name keys that differ only by Android XML escaping,
        unquoted whitespace, or Android `%s` format tokens. The expected result
        proves those keys are still Android-sourced for iOS after converting them
        to the runtime text and printf syntax iOS actually uses.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            android_root = root / "android"
            self.make_shared_translation_repo(root, ["en", "fr"])
            self.write_ios_strings(
                root,
                "AndBible",
                "en",
                {
                    "app_name": "AndBible",
                    "safe_title": "Safe title",
                    "quote_key": r'Show \"Selection\"',
                    "placeholder_key": "Current: %@",
                    "position_key": "Window %1$d (%2$@:%3$@)",
                    "spaced_key": "Choose cloud service.",
                    "ios_only": "iOS only",
                    "needs_mapping": "iOS wording",
                },
            )
            self.write_android_strings(
                android_root,
                "values",
                {
                    "app_name_andbible": "AndBible",
                    "safe_title": "Safe title",
                    "quote_key": r'Show \"Selection\"',
                    "placeholder_key": "Current: %s",
                    "position_key": "Window %1$d (%2$s:%3$s)",
                    "spaced_key": "\n        Choose cloud service.\n    ",
                    "android_only": "Android only",
                    "needs_mapping": "Android wording",
                },
            )
            self.write_android_strings(
                android_root,
                "values-fr",
                {
                    "app_name_andbible": "Bible Android",
                    "safe_title": "Titre sur",
                    "quote_key": r'Afficher \"Selection\"',
                    "placeholder_key": "Actuel : %s",
                    "position_key": "Fenetre %1$d (%2$s:%3$s)",
                    "spaced_key": "\n        Choisir le service cloud.\n    ",
                    "needs_mapping": "Libelle Android",
                },
            )

            catalog = build_android_shared_localization(root, android_root)

        self.assertEqual(
            catalog.safe_keys,
            [
                "app_name",
                "needs_mapping",
                "placeholder_key",
                "position_key",
                "quote_key",
                "safe_title",
                "spaced_key",
            ],
        )
        self.assertEqual(catalog.english_mismatch_keys, ["needs_mapping"])
        self.assertEqual(
            catalog.english_by_key,
            {
                "app_name": "AndBible",
                "needs_mapping": "Android wording",
                "placeholder_key": "Current: %@",
                "position_key": "Window %1$d (%2$@:%3$@)",
                "quote_key": 'Show "Selection"',
                "safe_title": "Safe title",
                "spaced_key": "Choose cloud service.",
            },
        )
        self.assertEqual(catalog.source_key_by_key["app_name"], "app_name_andbible")
        self.assertEqual(catalog.source_key_by_key["safe_title"], "safe_title")
        self.assertEqual(
            catalog.non_english_by_key,
            {
                "app_name": ["fr"],
                "needs_mapping": ["fr"],
                "placeholder_key": ["fr"],
                "position_key": ["fr"],
                "quote_key": ["fr"],
                "safe_title": ["fr"],
                "spaced_key": ["fr"],
            },
        )
        self.assertEqual(
            catalog.translations_by_locale["fr"],
            {
                "app_name": "Bible Android",
                "needs_mapping": "Libelle Android",
                "placeholder_key": "Actuel : %@",
                "position_key": "Fenetre %1$d (%2$@:%3$@)",
                "quote_key": 'Afficher "Selection"',
                "safe_title": "Titre sur",
                "spaced_key": "Choisir le service cloud.",
            },
        )

    def test_shared_catalog_excludes_same_name_semantic_collisions(self) -> None:
        """Prevents broad same-name matching from importing unrelated Android text.

        Some iOS keys share a resource name with Android but not a product
        meaning. The catalog must leave those iOS-owned keys out of automatic
        same-name sourcing while still allowing an explicit cross-name mapping
        to use the same Android source key for the Android-equivalent iOS
        surface.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            android_root = root / "android"
            self.make_shared_translation_repo(root, ["en", "fr"])
            self.write_ios_strings(
                root,
                "AndBible",
                "en",
                {
                    "disable_sync": "Disable Sync",
                    "hidden": "Hidden",
                    "safe_title": "Safe title",
                    "window_disable_sync": "Disable synchronize",
                },
            )
            self.write_android_strings(
                android_root,
                "values",
                {
                    "disable_sync": "Disable synchronize",
                    "hidden": "hidden",
                    "safe_title": "Safe title",
                },
            )
            self.write_android_strings(
                android_root,
                "values-fr",
                {
                    "disable_sync": "Desactiver synchroniser",
                    "hidden": "masque",
                    "safe_title": "Titre sur",
                },
            )

            catalog = build_android_shared_localization(root, android_root)

        self.assertEqual(catalog.safe_keys, ["safe_title", "window_disable_sync"])
        self.assertEqual(catalog.source_key_by_key["safe_title"], "safe_title")
        self.assertEqual(catalog.source_key_by_key["window_disable_sync"], "disable_sync")
        self.assertNotIn("disable_sync", catalog.source_key_by_key)
        self.assertNotIn("hidden", catalog.source_key_by_key)

    def test_shared_audit_reports_missing_placeholders_and_android_drift(self) -> None:
        """Reports every safe shared key that is not using Android's translation.

        The fixture covers three failure classes: a missing locale key, an iOS
        English placeholder, and a non-English iOS value that still differs from
        Android. A failure means the systemic localization guardrail can miss a
        source-of-truth violation outside the old settings-only key list.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            android_root = root / "android"
            self.make_shared_translation_repo(root, ["en", "fr"])
            english_values = {
                "missing_key": "Missing key",
                "placeholder_key": "Placeholder key",
                "drift_key": "Drift key",
            }
            for tree in ["AndBible", "Localizations"]:
                self.write_ios_strings(root, tree, "en", english_values)
                self.write_ios_strings(
                    root,
                    tree,
                    "fr",
                    {
                        "placeholder_key": "Placeholder key",
                        "drift_key": "Ancienne valeur",
                    },
                )
            self.write_android_strings(android_root, "values", english_values)
            self.write_android_strings(
                android_root,
                "values-fr",
                {
                    "missing_key": "Cle manquante",
                    "placeholder_key": "Cle fictive",
                    "drift_key": "Valeur Android",
                },
            )
            catalog = build_android_shared_localization(root, android_root)

            audit = audit_android_shared_translations(root, catalog)

        self.assertEqual(audit.english_value_mismatch_by_key, {})
        self.assertEqual(audit.missing_key_by_key, {"missing_key": ["fr"]})
        self.assertEqual(audit.english_placeholder_by_key, {"placeholder_key": ["fr"]})
        self.assertEqual(
            audit.value_mismatch_by_key,
            {
                "drift_key": ["fr"],
                "placeholder_key": ["fr"],
            },
        )

    def test_sync_shared_translations_updates_both_ios_resource_trees(self) -> None:
        """Writes Android English and translations into both iOS resource trees.

        The sync fixture includes an existing English placeholder, an existing
        divergent translation, a missing locale key, and English text that
        intentionally differs from Android. The expected result proves the repair
        path updates the app-bundled `AndBible` tree and the mirrored
        `Localizations` tree together so CI and runtime resources do not drift.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            android_root = root / "android"
            self.make_shared_translation_repo(root, ["en", "fr"])
            english_values = {
                "placeholder_key": "Placeholder key",
                "drift_key": "Drift key",
                "missing_key": "Missing key",
                "english_drift_key": "iOS wording",
            }
            for tree in ["AndBible", "Localizations"]:
                self.write_ios_strings(root, tree, "en", english_values)
                self.write_ios_strings(
                    root,
                    tree,
                    "fr",
                    {
                        "placeholder_key": "Placeholder key",
                        "drift_key": "Ancienne valeur",
                        "english_drift_key": "Ancienne valeur anglaise",
                    },
                )
            android_english_values = {
                **english_values,
                "english_drift_key": "Android wording",
            }
            self.write_android_strings(android_root, "values", android_english_values)
            self.write_android_strings(
                android_root,
                "values-fr",
                {
                    "placeholder_key": "Cle fictive",
                    "drift_key": "Valeur Android",
                    "missing_key": "Cle manquante",
                    "english_drift_key": "Libelle Android",
                },
            )
            catalog = build_android_shared_localization(root, android_root)

            result = sync_android_shared_translations(root, catalog)

            for tree in ["AndBible", "Localizations"]:
                english = parse_ios_strings(root / tree / "en.lproj" / "Localizable.strings")
                self.assertEqual(english["english_drift_key"], "Android wording")
                values = parse_ios_strings(root / tree / "fr.lproj" / "Localizable.strings")
                self.assertEqual(values["placeholder_key"], "Cle fictive")
                self.assertEqual(values["drift_key"], "Valeur Android")
                self.assertEqual(values["missing_key"], "Cle manquante")
                self.assertEqual(values["english_drift_key"], "Libelle Android")

        self.assertEqual(result.files_changed, 4)
        self.assertEqual(result.values_written, 10)

    def test_sync_shared_translations_normalizes_android_escape_sequences(self) -> None:
        """Converts Android XML escapes before writing iOS string resources.

        Android stores newline and tab escapes as backslash sequences in XML.
        The iOS sync must write them as `.strings` escapes that round-trip to
        the same runtime characters; otherwise the broad audit can keep failing
        after sync even though the visible Android value was imported.
        """
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            android_root = root / "android"
            self.make_shared_translation_repo(root, ["en", "fr"])
            for tree in ["AndBible", "Localizations"]:
                self.write_ios_strings(root, tree, "en", {"escaped_key": "Escaped"})
                self.write_ios_strings(root, tree, "fr", {"escaped_key": "Escaped"})
            self.write_android_strings(android_root, "values", {"escaped_key": "Escaped"})
            self.write_android_strings(
                android_root,
                "values-fr",
                {"escaped_key": r"Ligne\tune\nLigne deux"},
            )
            catalog = build_android_shared_localization(root, android_root)

            sync_android_shared_translations(root, catalog)

            values = parse_ios_strings(root / "AndBible" / "fr.lproj" / "Localizable.strings")

        self.assertEqual(values["escaped_key"], r"Ligne\tune\nLigne deux")
        self.assertEqual(
            values["escaped_key"].replace(r"\t", "\t").replace(r"\n", "\n"),
            "Ligne\tune\nLigne deux",
        )


if __name__ == "__main__":
    unittest.main()
