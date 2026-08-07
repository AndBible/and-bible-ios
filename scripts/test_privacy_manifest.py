"""Unit tests for the privacy-manifest guardrail."""

import plistlib
import tempfile
import unittest
from pathlib import Path

import privacy_manifest as guard

REPO_ROOT = Path(__file__).resolve().parent.parent

RESOURCES_ENTRY = (
    "\t\tAAAA /* PrivacyInfo.xcprivacy in Resources */ = "
    "{isa = PBXBuildFile; fileRef = BBBB /* PrivacyInfo.xcprivacy */; };\n"
)


def write_fixture(
    root: Path,
    *,
    manifest: dict,
    swift: str = "let x = 1\n",
    in_resources: bool = True,
) -> None:
    """Lay out a minimal repo: a manifest, one Swift source, and a project file."""
    (root / "AndBible").mkdir(parents=True, exist_ok=True)
    (root / "AndBible" / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(manifest))
    (root / "AndBible" / "Sample.swift").write_text(swift, encoding="utf-8")
    (root / "AndBible.xcodeproj").mkdir(parents=True, exist_ok=True)
    (root / "AndBible.xcodeproj" / "project.pbxproj").write_text(
        RESOURCES_ENTRY if in_resources else "\t\t/* nothing */\n", encoding="utf-8"
    )


def manifest_with(*categories: tuple[str, list[str]]) -> dict:
    """Build a manifest declaring the given categories and reason codes."""
    return {
        "NSPrivacyTracking": False,
        "NSPrivacyTrackingDomains": [],
        "NSPrivacyCollectedDataTypes": [],
        "NSPrivacyAccessedAPITypes": [
            {
                "NSPrivacyAccessedAPIType": category,
                "NSPrivacyAccessedAPITypeReasons": reasons,
            }
            for category, reasons in categories
        ],
    }


USER_DEFAULTS = "NSPrivacyAccessedAPICategoryUserDefaults"
DISK_SPACE = "NSPrivacyAccessedAPICategoryDiskSpace"


class ValidateTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.addCleanup(self._tmp.cleanup)

    def test_a_declared_and_used_category_is_clean(self) -> None:
        write_fixture(
            self.root,
            manifest=manifest_with((USER_DEFAULTS, ["CA92.1"])),
            swift="UserDefaults.standard.set(1, forKey: \"x\")\n",
        )
        self.assertEqual(guard.validate(self.root), [])

    def test_a_used_but_undeclared_category_is_reported_with_evidence(self) -> None:
        write_fixture(
            self.root,
            manifest=manifest_with(),
            swift="UserDefaults.standard.set(1, forKey: \"x\")\n",
        )
        problems = guard.validate(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn(USER_DEFAULTS, problems[0])
        self.assertIn("Sample.swift:1", problems[0])

    def test_a_declared_category_with_no_reason_code_is_reported(self) -> None:
        write_fixture(
            self.root,
            manifest=manifest_with((USER_DEFAULTS, [])),
            swift="UserDefaults.standard.set(1, forKey: \"x\")\n",
        )
        problems = guard.validate(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("no reason code", problems[0])

    def test_a_declared_but_unused_category_is_reported(self) -> None:
        write_fixture(self.root, manifest=manifest_with((DISK_SPACE, ["85F4.1"])))
        problems = guard.validate(self.root)
        self.assertEqual(len(problems), 1)
        self.assertIn("no shipping code reaches it", problems[0])

    def test_a_manifest_outside_the_resources_phase_is_reported(self) -> None:
        write_fixture(self.root, manifest=manifest_with(), in_resources=False)
        problems = guard.validate(self.root)
        self.assertTrue(
            any("Copy Bundle Resources" in problem for problem in problems), problems
        )

    def test_tracking_must_be_explicitly_false(self) -> None:
        manifest = manifest_with()
        del manifest["NSPrivacyTracking"]
        write_fixture(self.root, manifest=manifest)
        problems = guard.validate(self.root)
        self.assertTrue(
            any("NSPrivacyTracking" in problem for problem in problems), problems
        )

    def test_a_missing_manifest_is_reported(self) -> None:
        (self.root / "AndBible").mkdir(parents=True)
        self.assertTrue(
            any("missing" in problem for problem in guard.validate(self.root))
        )

    def test_test_sources_do_not_count_as_usage(self) -> None:
        write_fixture(self.root, manifest=manifest_with())
        tests = self.root / "Sources" / "Pkg" / "Tests" / "PkgTests"
        tests.mkdir(parents=True)
        (tests / "Spec.swift").write_text("UserDefaults.standard\n", encoding="utf-8")
        self.assertEqual(guard.validate(self.root), [])


class RealManifestTests(unittest.TestCase):
    """The committed manifest must actually be consistent with the committed code."""

    def test_the_real_manifest_validates(self) -> None:
        self.assertEqual(guard.validate(REPO_ROOT), [])

    def test_the_real_manifest_declares_the_three_categories_the_app_uses(self) -> None:
        reasons = guard.declared_reasons(guard.load_manifest(REPO_ROOT))
        self.assertEqual(reasons["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        self.assertEqual(
            reasons["NSPrivacyAccessedAPICategoryDiskSpace"], ["85F4.1", "E174.1"]
        )
        self.assertEqual(
            reasons["NSPrivacyAccessedAPICategoryFileTimestamp"], ["C617.1"]
        )

    def test_the_real_manifest_collects_nothing_and_does_not_track(self) -> None:
        manifest = guard.load_manifest(REPO_ROOT)
        self.assertEqual(manifest["NSPrivacyCollectedDataTypes"], [])
        self.assertEqual(manifest["NSPrivacyTracking"], False)
        self.assertEqual(manifest["NSPrivacyTrackingDomains"], [])


if __name__ == "__main__":
    unittest.main()
