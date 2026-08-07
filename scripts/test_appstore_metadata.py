"""Unit tests for the App Store metadata assembler."""

import contextlib
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import appstore_metadata as meta
import assemble_appstore_metadata as cli


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

    def test_a_non_txt_stale_file_is_reported_and_removed(self) -> None:
        meta.write_tree({"fi/name.txt": "x\n"}, self.out)
        (self.out / "fi" / "ratings_config.json").write_text("{}", encoding="utf-8")
        problems = meta.compare_tree({"fi/name.txt": "x\n"}, self.out)
        self.assertTrue(any("ratings_config.json" in problem for problem in problems))
        meta.write_tree({"fi/name.txt": "x\n"}, self.out)
        self.assertFalse((self.out / "fi" / "ratings_config.json").exists())


class CliTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)
        self.output_root = self.tmp / "fastlane" / "metadata"
        self.lock_file = self.tmp / "android_source.lock"
        self._patch_output_root = mock.patch.object(cli, "OUTPUT_ROOT", self.output_root)
        self._patch_lock_file = mock.patch.object(cli, "LOCK_FILE", self.lock_file)
        self._patch_output_root.start()
        self._patch_lock_file.start()
        self.addCleanup(self._patch_output_root.stop)
        self.addCleanup(self._patch_lock_file.stop)

    def run_cli(self, *args: str) -> tuple[int, str, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        argv = ["assemble_appstore_metadata.py", *args]
        with mock.patch.object(sys, "argv", argv):
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                exit_code = cli.main()
        return exit_code, stdout.getvalue(), stderr.getvalue()

    def test_read_lock_skips_comments_and_blanks(self) -> None:
        self.lock_file.parent.mkdir(parents=True, exist_ok=True)
        self.lock_file.write_text("# a comment\n\nabc123\n", encoding="utf-8")
        self.assertEqual(cli.read_lock(), "abc123")

    def test_read_lock_returns_none_when_the_file_is_absent(self) -> None:
        self.assertIsNone(cli.read_lock())

    def test_head_sha_returns_none_for_a_non_repository(self) -> None:
        self.assertIsNone(cli.head_sha(self.tmp))

    def test_is_dirty_returns_false_for_a_non_repository(self) -> None:
        self.assertFalse(cli.is_dirty(self.tmp))

    def test_is_dirty_detects_uncommitted_changes(self) -> None:
        repo = self.tmp / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True, capture_output=True)
        subprocess.run(
            ["git", "config", "user.email", "test@example.com"],
            cwd=repo, check=True, capture_output=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Test"],
            cwd=repo, check=True, capture_output=True,
        )
        (repo / "file.txt").write_text("a\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=repo, check=True, capture_output=True)
        subprocess.run(
            ["git", "commit", "-q", "-m", "init"], cwd=repo, check=True, capture_output=True,
        )
        self.assertFalse(cli.is_dirty(repo))
        (repo / "file.txt").write_text("b\n", encoding="utf-8")
        self.assertTrue(cli.is_dirty(repo))

    def test_check_writes_nothing(self) -> None:
        android_root = android_root_or_skip(self)
        exit_code, _stdout, _stderr = self.run_cli(
            "--check", "--android-root", str(android_root)
        )
        self.assertEqual(exit_code, 1)
        self.assertFalse(self.output_root.exists())
        self.assertFalse(self.lock_file.exists())

    def test_lock_mismatch_warns_and_continues_by_default(self) -> None:
        android_root = android_root_or_skip(self)
        self.lock_file.parent.mkdir(parents=True, exist_ok=True)
        self.lock_file.write_text("deadbeef\n", encoding="utf-8")
        exit_code, _stdout, stderr = self.run_cli(
            "--android-root", str(android_root)
        )
        self.assertIn("warning:", stderr)
        self.assertIn("android_source.lock says deadbeef", stderr)
        self.assertNotEqual(exit_code, 2)

    def test_lock_mismatch_fails_under_require_pinned(self) -> None:
        android_root = android_root_or_skip(self)
        self.lock_file.parent.mkdir(parents=True, exist_ok=True)
        self.lock_file.write_text("deadbeef\n", encoding="utf-8")
        exit_code, _stdout, stderr = self.run_cli(
            "--require-pinned", "--android-root", str(android_root)
        )
        self.assertEqual(exit_code, 2)
        self.assertIn("android_source.lock says deadbeef", stderr)

    def test_require_pinned_fails_when_the_lock_file_is_absent(self) -> None:
        android_root = android_root_or_skip(self)
        self.assertFalse(self.lock_file.exists())
        exit_code, _stdout, stderr = self.run_cli(
            "--require-pinned", "--android-root", str(android_root)
        )
        self.assertEqual(exit_code, 2)
        self.assertIn(str(self.lock_file), stderr)

    def test_require_pinned_fails_when_the_lock_file_has_no_sha(self) -> None:
        android_root = android_root_or_skip(self)
        self.lock_file.parent.mkdir(parents=True, exist_ok=True)
        self.lock_file.write_text("# just a comment\n\n", encoding="utf-8")
        exit_code, _stdout, stderr = self.run_cli(
            "--require-pinned", "--android-root", str(android_root)
        )
        self.assertEqual(exit_code, 2)
        self.assertIn(str(self.lock_file), stderr)

    def test_dirty_checkout_leaves_the_lock_file_untouched(self) -> None:
        android_root = android_root_or_skip(self)
        with mock.patch.object(cli, "is_dirty", return_value=True):
            exit_code, _stdout, stderr = self.run_cli(
                "--android-root", str(android_root)
            )
        self.assertEqual(exit_code, 0)
        self.assertFalse(self.lock_file.exists())
        self.assertIn("uncommitted changes", stderr)


if __name__ == "__main__":
    unittest.main()
