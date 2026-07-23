#!/usr/bin/env python3
"""Android-owned persisted-name and progress-copy localization contracts."""

from __future__ import annotations

from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


def source(relative_path: str) -> str:
    """Return one production source file without mutating the checkout."""
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


class AndroidLocalizedSeedContractTests(unittest.TestCase):
    """Prevents user-visible seeded values from reverting to iOS-only English."""

    def test_bundled_reading_plan_order_and_metadata_use_android_resources(self) -> None:
        """Every Android bundled plan must keep Android order, name, and description keys."""
        reading_plan_source = source(
            "Sources/BibleCore/Sources/BibleCore/Services/ReadingPlanService.swift"
        )
        definition_block = reading_plan_source.split(
            "private static let bundledPlanDefinitions: [BundledPlanDefinition] = [",
            maxsplit=1,
        )[1].split("\n    ]", maxsplit=1)[0]

        expected_codes = [
            "y1ntpspr",
            "y1ot1nt1_chronological",
            "y1ot1nt1_OTandNT",
            "y1ot1nt1_OTthenNT",
            "y1ot1nt2_mcheyne",
            "y1ot6nt4_profHorner",
            "y2ot1ntps2",
        ]
        self.assertEqual(
            re.findall(r'\bcode:\s*"([^"]+)"', definition_block),
            expected_codes,
        )
        for code in expected_codes:
            self.assertIn(f'localized: "plan_name_{code}"', definition_block)
            self.assertIn(f'localized: "plan_description_{code}"', definition_block)
        self.assertIsNone(re.search(r'\b(?:name|description):\s*"', definition_block))

    def test_default_bookmark_labels_use_android_resources(self) -> None:
        """Default label names are persisted localized values, not English iOS deviations."""
        bookmark_source = source(
            "Sources/BibleCore/Sources/BibleCore/Services/BookmarkService.swift"
        )

        for key in (
            "label_red",
            "label_green",
            "label_blue",
            "label_underline",
            "label_salvation",
        ):
            self.assertIn(f'localized: "{key}"', bookmark_source)
        for english_name in ("Red", "Green", "Blue", "Underline", "Salvation"):
            self.assertNotIn(f'name: "{english_name}"', bookmark_source)

    def test_default_workspace_and_index_progress_use_android_resources(self) -> None:
        """First-run workspace and search progress must follow Android locale resources."""
        app_source = source("AndBible/AndBibleApp.swift")
        search_source = source("Sources/BibleUI/Sources/BibleUI/Search/SearchView.swift")

        self.assertIn('localized: "workspace_number"', app_source)
        self.assertNotIn('createWorkspace(name: "Default")', app_source)
        self.assertIn('localized: "creating_index_for"', search_source)
        self.assertNotIn("Creating index. Processing", search_source)


if __name__ == "__main__":
    unittest.main()
