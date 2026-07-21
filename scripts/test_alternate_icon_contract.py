"""Guardrails for iOS runtime and static Calculator identity contracts."""

from __future__ import annotations

import json
import plistlib
import struct
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
APP_DIR = REPO_ROOT / "AndBible"
PROJECT_FILE = REPO_ROOT / "AndBible.xcodeproj" / "project.pbxproj"
DISCRETE_SCHEME = (
    REPO_ROOT
    / "AndBible.xcodeproj"
    / "xcshareddata"
    / "xcschemes"
    / "AndBibleDiscrete.xcscheme"
)


def png_size(path: Path) -> tuple[int, int]:
    """Return the pixel dimensions from a PNG IHDR chunk."""
    with path.open("rb") as png:
        header = png.read(24)

    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError(f"{path.relative_to(REPO_ROOT)} is not a PNG file")

    return struct.unpack(">II", header[16:24])


def png_has_alpha(path: Path) -> bool:
    """Return whether PNG color type or transparency chunks carry alpha information."""
    data = path.read_bytes()
    if len(data) < 33 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError(f"{path.relative_to(REPO_ROOT)} is not a PNG file")
    if data[25] in (4, 6):
        return True

    offset = 8
    while offset + 12 <= len(data):
        chunk_length = struct.unpack(">I", data[offset : offset + 4])[0]
        chunk_type = data[offset + 4 : offset + 8]
        if chunk_type == b"tRNS":
            return True
        offset += 12 + chunk_length
        if chunk_type == b"IEND":
            break
    return False


class AlternateIconContractTests(unittest.TestCase):
    """Protect the calculator alternate icon from App Store and runtime regressions."""

    def test_calculator_alternate_icon_declares_iphone_and_ipad_icon_sets(self) -> None:
        """Keep alternate-icon plist declarations aligned with the bundled PNG base names."""
        with (APP_DIR / "Info.plist").open("rb") as plist_file:
            info_plist = plistlib.load(plist_file)

        iphone_icon = info_plist["CFBundleIcons"]["CFBundleAlternateIcons"]["CalculatorIcon"]
        ipad_icon = info_plist["CFBundleIcons~ipad"]["CFBundleAlternateIcons"]["CalculatorIcon"]

        self.assertEqual(iphone_icon["CFBundleIconFiles"], ["CalculatorIcon"])
        self.assertEqual(ipad_icon["CFBundleIconFiles"], ["CalculatorIcon-76"])
        self.assertFalse(iphone_icon["UIPrerenderedIcon"])
        self.assertFalse(ipad_icon["UIPrerenderedIcon"])

    def test_calculator_alternate_icon_pngs_cover_required_iphone_and_ipad_sizes(self) -> None:
        """App Store Connect expects the alternate iPad icon to include an exact 152px PNG."""
        expected_sizes = {
            "CalculatorIcon.png": (60, 60),
            "CalculatorIcon@2x.png": (120, 120),
            "CalculatorIcon@3x.png": (180, 180),
            "CalculatorIcon-76.png": (76, 76),
            "CalculatorIcon-76@2x.png": (152, 152),
        }

        for filename, expected_size in expected_sizes.items():
            with self.subTest(filename=filename):
                self.assertEqual(png_size(APP_DIR / filename), expected_size)

    def test_calculator_alternate_icon_pngs_are_copied_by_xcode(self) -> None:
        """Declaring alternate icon files is insufficient unless Xcode bundles each PNG."""
        project = PROJECT_FILE.read_text(encoding="utf-8")

        for filename in [
            "CalculatorIcon.png",
            "CalculatorIcon@2x.png",
            "CalculatorIcon@3x.png",
            "CalculatorIcon-76.png",
            "CalculatorIcon-76@2x.png",
        ]:
            with self.subTest(filename=filename):
                self.assertIn(f"/* {filename} */", project)
                self.assertIn(f"/* {filename} in Resources */", project)

    def test_every_primary_and_alternate_icon_png_is_opaque(self) -> None:
        """App Store icon assets must have neither alpha color types nor tRNS chunks."""
        icon_paths = [
            APP_DIR / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png",
            APP_DIR
            / "Assets.xcassets"
            / "CalculatorAppIcon.appiconset"
            / "CalculatorAppIcon.png",
            APP_DIR / "CalculatorIcon.png",
            APP_DIR / "CalculatorIcon@2x.png",
            APP_DIR / "CalculatorIcon@3x.png",
            APP_DIR / "CalculatorIcon-76.png",
            APP_DIR / "CalculatorIcon-76@2x.png",
        ]

        for path in icon_paths:
            with self.subTest(path=path.relative_to(REPO_ROOT)):
                self.assertFalse(png_has_alpha(path))


class DiscreteBuildContractTests(unittest.TestCase):
    """Protect the separately distributable Calculator SKU's signed identity."""

    def test_target_plists_require_build_owned_identity_values(self) -> None:
        """Both app targets must resolve identity, privacy, and CloudKit from build settings."""
        for filename in ("Info.plist", "Info-Discrete.plist"):
            with self.subTest(filename=filename):
                with (APP_DIR / filename).open("rb") as plist_file:
                    info_plist = plistlib.load(plist_file)

                self.assertEqual(info_plist["CFBundleDisplayName"], "$(APP_DISPLAY_NAME)")
                self.assertEqual(
                    info_plist["AndBibleBuildIdentity"],
                    "$(ANDBIBLE_BUILD_IDENTITY)",
                )
                self.assertEqual(
                    info_plist["AndBibleCloudKitContainerIdentifier"],
                    "$(ANDBIBLE_CLOUDKIT_CONTAINER_IDENTIFIER)",
                )
                self.assertEqual(
                    info_plist["NSMotionUsageDescription"],
                    "$(MOTION_USAGE_DESCRIPTION)",
                )

    def test_discrete_target_has_distinct_product_identity_and_resources(self) -> None:
        """The privacy contract requires a real app target, not an alternate-icon-only scheme."""
        project = PROJECT_FILE.read_text(encoding="utf-8")

        expected_fragments = [
            "D15C09000000000000000301 /* AndBibleDiscrete */ = {",
            "productName = Calculator;",
            "path = Calculator.app;",
            "PRODUCT_BUNDLE_IDENTIFIER = com.app.calculator.ios;",
            "APP_DISPLAY_NAME = Calculator;",
            "ANDBIBLE_BUILD_IDENTITY = discrete;",
            "ASSETCATALOG_COMPILER_APPICON_NAME = CalculatorAppIcon;",
            "CODE_SIGN_ENTITLEMENTS = AndBible/AndBibleDiscrete.entitlements;",
            "DiscreteBuildBootstrap.m in Sources",
        ]
        for fragment in expected_fragments:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, project)

        self.assertIn("APP_DISPLAY_NAME = AndBible;", project)
        self.assertIn("ANDBIBLE_BUILD_IDENTITY = standard;", project)

    def test_discrete_scheme_builds_calculator_target(self) -> None:
        """The shared scheme must archive and launch the distinct Calculator product."""
        root = ET.parse(DISCRETE_SCHEME).getroot()
        references = root.findall(".//BuildableReference")

        self.assertTrue(references)
        for reference in references:
            self.assertEqual(reference.attrib["BlueprintIdentifier"], "D15C09000000000000000301")
            self.assertEqual(reference.attrib["BlueprintName"], "AndBibleDiscrete")
            self.assertEqual(reference.attrib["BuildableName"], "Calculator.app")

    def test_discrete_primary_icon_and_cloud_identity_are_isolated(self) -> None:
        """Calculator must not reuse AndBible's launcher art or CloudKit container identity."""
        app_icon_dir = APP_DIR / "Assets.xcassets" / "CalculatorAppIcon.appiconset"
        contents = json.loads((app_icon_dir / "Contents.json").read_text(encoding="utf-8"))
        ios_image = next(
            image
            for image in contents["images"]
            if image.get("platform") == "ios" and image.get("idiom") == "universal"
        )
        self.assertEqual(ios_image["filename"], "CalculatorAppIcon.png")
        self.assertEqual(png_size(app_icon_dir / ios_image["filename"]), (1024, 1024))

        with (APP_DIR / "AndBibleDiscrete.entitlements").open("rb") as plist_file:
            entitlements = plistlib.load(plist_file)
        self.assertEqual(
            entitlements["com.apple.developer.icloud-container-identifiers"],
            ["iCloud.com.app.calculator.ios"],
        )

    def test_discrete_localized_launcher_names_are_target_only(self) -> None:
        """Bundle Android-derived Calculator names without renaming the standard target."""
        project = PROJECT_FILE.read_text(encoding="utf-8")
        snapshot_path = (
            REPO_ROOT
            / "scripts"
            / "fixtures"
            / "settings-localization"
            / "localization-android.json"
        )
        snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
        expected_locales = set(snapshot["discrete_app_names"])
        localization_root = REPO_ROOT / "AndBibleDiscreteLocalizations"
        actual_locales = {
            path.name.removesuffix(".lproj")
            for path in localization_root.glob("*.lproj")
            if path.is_dir()
        }

        self.assertEqual(actual_locales, expected_locales)
        self.assertIn("AndBibleDiscreteLocalizations", project)
        self.assertIn("InfoPlist.strings in Resources", project)

        standard_resources = project.split(
            "104C1005819D47319DC4C432 /* Resources */ = {", 1
        )[1].split("};", 1)[0]
        discrete_resources = project.split(
            "D15C09000000000000000303 /* Resources */ = {", 1
        )[1].split("};", 1)[0]
        self.assertNotIn("InfoPlist.strings", standard_resources)
        self.assertIn("InfoPlist.strings", discrete_resources)

    def test_discrete_bootstrap_enforces_calculator_gate_only_in_discrete_target(self) -> None:
        """The gate must remain a target invariant without changing the shared app entry point."""
        bootstrap = (APP_DIR / "DiscreteBuildBootstrap.m").read_text(encoding="utf-8")
        project = PROJECT_FILE.read_text(encoding="utf-8")

        self.assertIn('setBool:YES forKey:@"show_calculator"', bootstrap)
        self.assertIn("volatileDomainForName:NSArgumentDomain", bootstrap)
        self.assertIn("setVolatileDomain:argumentDefaults forName:NSArgumentDomain", bootstrap)
        self.assertIn('argumentDefaults[@"show_calculator"] = @YES', bootstrap)
        self.assertNotIn('forKey:@"discrete_mode"', bootstrap)

        standard_sources = project.split(
            "F77914906747B2B1F88AC7BA /* Sources */ = {", 1
        )[1].split("};", 1)[0]
        discrete_sources = project.split(
            "D15C09000000000000000302 /* Sources */ = {", 1
        )[1].split("};", 1)[0]
        self.assertNotIn("DiscreteBuildBootstrap.m", standard_sources)
        self.assertIn("DiscreteBuildBootstrap.m", discrete_sources)
