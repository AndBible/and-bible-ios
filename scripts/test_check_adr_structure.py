#!/usr/bin/env python3
"""Synthetic parser tests for the repository ADR structural checker."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_adr_structure import validate_adr_directory


MODERN_ADR = """\
---
adr: ADR-{number}
title: "{title}"
status: proposed
review-status: pending_review
extends: []
extended-by: []
amends: []
amended-by: []
supersedes: []
superseded-by: null
related-adrs: [{relationships}]
---

# ADR-{number}: {title}

## Decision

Synthetic decision text.
"""


class AdrStructureTests(unittest.TestCase):
    """Exercise modern and legacy identity, index, and relationship contracts."""

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.adr_dir = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write(self, name: str, text: str) -> None:
        (self.adr_dir / name).write_text(text, encoding="utf-8")

    def write_index(self, *names: str) -> None:
        links = "\n".join(f"- [{name[:4]}: Record]({name})" for name in names)
        self.write("README.md", f"# Architecture Decision Records\n\n{links}\n")

    def messages(self) -> list[str]:
        return [issue.message for issue in validate_adr_directory(self.adr_dir)]

    def test_accepts_current_front_matter_and_legacy_body_records(self) -> None:
        modern = "0002-modern-record.md"
        legacy = "0001-legacy-record.md"
        self.write(
            modern,
            MODERN_ADR.format(number="0002", title="Modern Record", relationships="ADR-0001"),
        )
        self.write(
            legacy,
            "# 0001: Legacy Record\n\n"
            "Status: Superseded by [ADR 0002](0002-modern-record.md)\n\n"
            "Date: 2026-01-01\n\n## Decision\n\nHistorical decision.\n",
        )
        self.write_index(legacy, modern)

        self.assertEqual([], self.messages())

    def test_rejects_duplicate_identifiers_even_when_filenames_differ(self) -> None:
        first = "0001-first-record.md"
        second = "0001-second-record.md"
        self.write(first, "# 0001: First Record\n")
        self.write(second, "# 0001: Second Record\n")
        self.write_index(first, second)

        self.assertIn(
            "ADR-0001 is claimed by multiple files: 0001-first-record.md, 0001-second-record.md",
            self.messages(),
        )

    def test_rejects_identity_disagreement_between_path_metadata_and_heading(self) -> None:
        name = "0003-mismatched-record.md"
        self.write(
            name,
            MODERN_ADR.format(number="0004", title="Mismatched Record", relationships=""),
        )
        self.write_index(name)

        self.assertIn(
            "filename, front matter adr, and first ADR heading must use the same identifier",
            self.messages(),
        )

    def test_reports_missing_duplicate_and_stale_index_entries(self) -> None:
        first = "0001-first-record.md"
        second = "0002-second-record.md"
        self.write(first, "# 0001: First Record\n")
        self.write(second, "# 0002: Second Record\n")
        self.write(
            "README.md",
            "# Architecture Decision Records\n\n"
            f"- [0001: First]({first})\n"
            f"- [0001: First Again]({first})\n"
            "- [0009: Missing](0009-missing-record.md)\n",
        )

        messages = self.messages()
        self.assertIn(f"ADR index lists {first} 2 times", messages)
        self.assertIn(f"ADR index is missing {second}", messages)
        self.assertIn("ADR index target does not exist: 0009-missing-record.md", messages)

    def test_rejects_unresolvable_metadata_and_legacy_link_relationships(self) -> None:
        modern = "0001-modern-record.md"
        legacy = "0002-legacy-record.md"
        self.write(
            modern,
            MODERN_ADR.format(number="0001", title="Modern Record", relationships="ADR-0042"),
        )
        self.write(
            legacy,
            "# 0002: Legacy Record\n\n"
            "Status: Superseded by [ADR 0043](0043-missing-record.md)\n",
        )
        self.write_index(modern, legacy)

        messages = self.messages()
        self.assertIn("ADR-0042 relationship does not resolve", messages)
        self.assertIn("ADR-0043 relationship does not resolve", messages)
        self.assertIn("Markdown ADR target does not exist: 0043-missing-record.md", messages)


if __name__ == "__main__":
    unittest.main()
