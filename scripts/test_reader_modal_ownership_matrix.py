#!/usr/bin/env python3
"""
Regression tests for the reader modal ownership matrix.
"""

from __future__ import annotations

from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
READER_VIEW = (
    REPO_ROOT
    / "Sources"
    / "BibleUI"
    / "Sources"
    / "BibleUI"
    / "Bible"
    / "BibleReaderView.swift"
)
MATRIX = REPO_ROOT / "docs" / "parity" / "reader" / "modal-ownership-matrix.md"


def swift_enum_cases(source: str, enum_name: str) -> list[str]:
    """Return simple `case name` entries from one Swift enum declaration."""
    match = re.search(rf"\benum\s+{re.escape(enum_name)}\b[^\{{]*\{{", source)
    if match is None:
        raise AssertionError(f"Expected enum {enum_name} to exist.")

    start = match.end()
    depth = 1
    index = start
    while index < len(source) and depth > 0:
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        index += 1

    if depth != 0:
        raise AssertionError(f"Expected enum {enum_name} body to close.")

    body = source[start : index - 1]
    cases: list[str] = []
    for line in body.splitlines():
        case_match = re.match(r"\s*case\s+([A-Za-z_][A-Za-z0-9_]*)\b", line)
        if case_match is not None:
            cases.append(case_match.group(1))

    if not cases:
        raise AssertionError(f"Expected enum {enum_name} to define cases.")
    return cases


def matrix_row(matrix: str, token: str) -> list[str]:
    """Return the Markdown table cells for one reader presentation route."""
    for line in matrix.splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if cells and cells[0] == f"`{token}`":
            return cells

    raise AssertionError(f"Expected {token} to be classified in the matrix.")


class ReaderModalOwnershipMatrixTests(unittest.TestCase):
    """Keeps reader presentation routes classified under ADR 0006."""

    def test_reader_sheet_cases_are_classified(self) -> None:
        """Every `ReaderSheet` case appears as a matrix route token."""
        source = READER_VIEW.read_text(encoding="utf-8")
        matrix = MATRIX.read_text(encoding="utf-8")

        for case in swift_enum_cases(source, "ReaderSheet"):
            self.assertIn(f"`ReaderSheet.{case}`", matrix)

    def test_reader_destination_cases_are_classified(self) -> None:
        """Every `ReaderDestination` case appears as a matrix route token."""
        source = READER_VIEW.read_text(encoding="utf-8")
        matrix = MATRIX.read_text(encoding="utf-8")

        for case in swift_enum_cases(source, "ReaderDestination"):
            self.assertIn(f"`ReaderDestination.{case}`", matrix)

    def test_reader_modal_cases_are_classified(self) -> None:
        """Every `ReaderModal` case appears as a matrix route token."""
        source = READER_VIEW.read_text(encoding="utf-8")
        matrix = MATRIX.read_text(encoding="utf-8")

        for case in swift_enum_cases(source, "ReaderModal"):
            self.assertIn(f"`ReaderModal.{case}`", matrix)

    def test_standalone_transient_routes_are_classified(self) -> None:
        """State-backed reader presentations outside the enums remain documented."""
        matrix = MATRIX.read_text(encoding="utf-8")

        for token in [
            "`showSearch`",
            "`showStartupDownloadPrompt`",
            "`showReaderStrongsModeDialog`",
            "`shareSheetBinding`",
            "`crossReferenceSheetBinding`",
            "`showRefChooser`",
        ]:
            self.assertIn(token, matrix)

    def test_high_risk_routes_keep_expected_owner_classification(self) -> None:
        """
        Protect Android parity ownership for routes most likely to drift.

        The matrix is not just an inventory. These routes sit at different
        ownership boundaries in Android: search and chooser flows are
        app-owned, sharing is an OS boundary, and cross references are
        document/WebView-owned. A failure here means a future docs or reader
        change has altered that contract and needs product review before parity
        is claimed.
        """
        matrix = MATRIX.read_text(encoding="utf-8")

        expected_owners = {
            "showSearch": "`Android app-owned`",
            "showRefChooser": "`Android app-owned`",
            "ReaderModal.chooseDocument": "`Android app-owned`",
            "ReaderModal.modulePicker": "`Android app-owned`",
            "ReaderModal.labelManager": "`Android app-owned`",
            "ReaderModal.studyPadSelector": "`Android app-owned`",
            "shareSheetBinding": "`iOS system boundary`",
            "crossReferenceSheetBinding": "`Vue/WebView-owned`",
        }

        for token, owner in expected_owners.items():
            self.assertEqual(owner, matrix_row(matrix, token)[2])

    def test_known_partial_routes_link_to_their_follow_up_issues(self) -> None:
        """
        Keep incomplete reader modal routes tied to explicit follow-up work.

        Android parity is not satisfied by labeling an iOS sheet as native.
        These rows intentionally remain partial, so their issue references must
        stay visible in the disposition column until the owning behavior is
        migrated or completed.
        """
        matrix = MATRIX.read_text(encoding="utf-8")

        expected_issues = {
            "ReaderModal.chooseDocument": "#245",
            "ReaderModal.modulePicker": "#245",
            "ReaderModal.labelManager": "#246",
            "ReaderModal.studyPadSelector": "#246",
        }

        for token, issue in expected_issues.items():
            self.assertIn(issue, matrix_row(matrix, token)[4])

    def test_legacy_cross_reference_sheet_is_not_a_document_pipeline_substitute(self) -> None:
        """
        Preserve the post-#124 ownership contract for cross-reference routing.

        Multi-reference Android parity is protected by the shared Vue
        `MultiDocument` path. The remaining Swift sheet row is a legacy callback,
        so future reader work should either keep it quarantined or remove it
        rather than treating it as an acceptable native replacement.
        """
        matrix = MATRIX.read_text(encoding="utf-8")
        disposition = matrix_row(matrix, "crossReferenceSheetBinding")[4]

        self.assertIn("already bypass this route", disposition)
        self.assertIn("Do not expand the legacy sheet", disposition)

    def test_matrix_links_back_to_durable_modal_ownership_adr(self) -> None:
        """The reader matrix stays tied to the cross-domain ownership policy."""
        matrix = MATRIX.read_text(encoding="utf-8")

        self.assertIn("ADR 0006", matrix)
        self.assertIn("../../adr/0006-modal-presentation-ownership-for-android-parity.md", matrix)


if __name__ == "__main__":
    unittest.main()
