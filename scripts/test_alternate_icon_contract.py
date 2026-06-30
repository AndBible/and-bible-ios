"""Guardrails for the iOS alternate app icon bundle contract."""

from __future__ import annotations

import plistlib
import struct
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
APP_DIR = REPO_ROOT / "AndBible"
PROJECT_FILE = REPO_ROOT / "AndBible.xcodeproj" / "project.pbxproj"


def png_size(path: Path) -> tuple[int, int]:
    """Return the pixel dimensions from a PNG IHDR chunk."""
    with path.open("rb") as png:
        header = png.read(24)

    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError(f"{path.relative_to(REPO_ROOT)} is not a PNG file")

    return struct.unpack(">II", header[16:24])


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
