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


REPO_ROOT = Path(__file__).resolve().parent.parent

APPLE_SUPPORTED_LOCALES = {
    "ar-SA", "ca", "cs", "da", "de-DE", "el", "en-AU", "en-CA", "en-GB",
    "en-US", "es-ES", "es-MX", "fi", "fr-CA", "fr-FR", "he", "hi", "hr",
    "hu", "id", "it", "ja", "ko", "ms", "nl-NL", "no", "pl", "pt-BR",
    "pt-PT", "ro", "ru", "sk", "sv", "th", "tr", "uk", "vi", "zh-Hans",
    "zh-Hant",
}


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


if __name__ == "__main__":
    unittest.main()
