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
ADR_0006 = REPO_ROOT / "docs" / "adr" / "0006-modal-presentation-ownership-for-android-parity.md"
ADR_0008 = REPO_ROOT / "docs" / "adr" / "0008-parity-documentation-ownership.md"


ROUTE_CLASSIFICATIONS: dict[str, tuple[str, str]] = {
    "ReaderSheet.history": (
        "Android app-owned",
        "Adapted reader shell route with focused UI coverage for selection, clear, and delete.",
    ),
    "ReaderSheet.readingProgress": (
        "Android app-owned",
        "Adapted app-owned route.",
    ),
    "ReaderSheet.readingProgressSettings": (
        "Android app-owned",
        "Adapted app-owned settings route.",
    ),
    "ReaderSheet.chapterReadHistory": (
        "Android app-owned",
        "Adapted app-owned route. Keep pane-target capture intact.",
    ),
    "ReaderSheet.workspaces": (
        "Android app-owned",
        "Adapted reader shell route with UI coverage for create.",
    ),
    "ReaderSheet.about": (
        "Android app-owned",
        "Acceptable app-owned informational route.",
    ),
    "ReaderDestination.search": (
        "Android app-owned",
        "Adapted app-owned route with UI coverage protecting destination presentation.",
    ),
    "ReaderDestination.bookmarks": (
        "Android app-owned",
        "App-owned route. Bookmarks must not be reintroduced as a ReaderSheet route.",
    ),
    "ReaderDestination.studyPads": (
        "Android app-owned",
        "App-owned route. StudyPads must not be reintroduced as a nested selector modal.",
    ),
    "ReaderDestination.myDocuments": (
        "Android app-owned",
        "Drawer-owned app route through the reader My Documents document pipeline.",
    ),
    "ReaderDestination.readingPlans": (
        "Android app-owned",
        "App-owned route. Reading Plans must not be reintroduced as a ReaderSheet route.",
    ),
    "ReaderDestination.settings": (
        "Android app-owned",
        "Adapted app-owned route with Settings UI coverage.",
    ),
    "ReaderDestination.startupDocumentSetup": (
        "Android app-owned",
        "Startup setup route matching Android's first-download activity surface.",
    ),
    "ReaderDestination.downloads": (
        "Android app-owned",
        "Adapted app-owned route.",
    ),
    "ReaderDestination.importExport": (
        "Android app-owned plus iOS system boundary",
        "Startup setup route may use native iOS file boundaries only at OS handoff points.",
    ),
    "ReaderDestination.globalTextOptions": (
        "Android app-owned",
        "App-owned settings route. Scope semantics are governed by ADR 0005.",
    ),
    "ReaderDestination.workspaceTextOptions": (
        "Android app-owned",
        "App-owned settings route. Workspace color behavior is governed by ADR 0005.",
    ),
    "ReaderDestination.windowTextOptions": (
        "Android app-owned",
        "App-owned settings route.",
    ),
    "ReaderDestination.windowColorSettings": (
        "Android app-owned",
        "App-owned settings route.",
    ),
    "ReaderModal.syncSettings": (
        "Android app-owned",
        "Adapted app-owned settings route.",
    ),
    "ReaderModal.importExport": (
        "Android app-owned plus iOS system boundary",
        "App-owned route may use native iOS file/share boundaries only at OS handoff points.",
    ),
    "ReaderModal.speakControls": (
        "Android app-owned",
        "Adapted app-owned route; transport semantics must remain reader/pane-aware.",
    ),
    "ReaderModal.modulePicker": (
        "Android app-owned",
        "App-owned full-screen route.",
    ),
    "ReaderModal.dictionaryBrowser": (
        "Android app-owned",
        "Adapted app-owned browser route.",
    ),
    "ReaderModal.generalBookBrowser": (
        "Android app-owned",
        "Adapted app-owned browser route.",
    ),
    "ReaderModal.mapBrowser": (
        "Android app-owned",
        "Adapted app-owned browser route.",
    ),
    "ReaderModal.epubLibrary": (
        "Android app-owned",
        "Adapted app-owned route.",
    ),
    "ReaderModal.epubBrowser": (
        "Android app-owned",
        "Adapted app-owned route.",
    ),
    "ReaderModal.epubSearch": (
        "Android app-owned",
        "Adapted app-owned route.",
    ),
    "ReaderModal.labelManager": (
        "Android app-owned",
        "Partial. Label/StudyPad ownership details are tracked by #246.",
    ),
    "ReaderModal.chooseDocument": (
        "Android app-owned",
        "App-owned full-screen route.",
    ),
    "ReaderModal.help": (
        "Android app-owned",
        "Adapted informational route. Vue-scoped help remains bridge-owned when invoked from Vue.",
    ),
    "showReaderStrongsModeDialog": (
        "Android app-owned",
        "Acceptable dialog adaptation if choices, reset/default semantics, and preference mutation match Android.",
    ),
    "shareSheetBinding": (
        "iOS system boundary",
        "Acceptable platform boundary when it only hands selected/generated content to OS sharing.",
    ),
    "crossReferenceSheetBinding": (
        "Vue/WebView-owned",
        "Multi-reference links already bypass this route through the Vue MultiDocument path. Do not expand the legacy sheet as a substitute for document-pipeline routing.",
    ),
    "showRefChooser": (
        "Android app-owned",
        "Adapted app-owned chooser route. Keep async callback semantics and pane context intact.",
    ),
    "BibleReaderModulePicker.AndroidPseudoDocument.myNotes": (
        "Vue/WebView-owned",
        "Chooser-owned pseudo-document route. Drawer My Notes/My Documents must route through ReaderDestination.myDocuments.",
    ),
}


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


def swift_function_body(source: str, function_name: str) -> str:
    """Return one Swift function body by matching balanced braces."""
    match = re.search(rf"\bfunc\s+{re.escape(function_name)}\b[^\{{]*\{{", source)
    if match is None:
        raise AssertionError(f"Expected function {function_name} to exist.")

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
        raise AssertionError(f"Expected function {function_name} body to close.")
    return source[start : index - 1]


def swift_switch_case_body(function_body: str, case_name: str) -> str:
    """Return the body for one simple `case .name:` inside a Swift switch."""
    case_match = re.search(rf"^\s*case\s+\.{re.escape(case_name)}\s*:", function_body, re.MULTILINE)
    if case_match is None:
        raise AssertionError(f"Expected switch case .{case_name} to exist.")

    next_case = re.search(r"^\s*case\s+\.", function_body[case_match.end() :], re.MULTILINE)
    if next_case is None:
        return function_body[case_match.end() :]
    return function_body[case_match.end() : case_match.end() + next_case.start()]


def route_classification(token: str) -> tuple[str, str]:
    """Return the durable owner and disposition for one reader presentation route."""
    try:
        return ROUTE_CLASSIFICATIONS[token]
    except KeyError as error:
        raise AssertionError(f"Expected {token} to be classified under ADR 0006.") from error


class ReaderModalOwnershipMatrixTests(unittest.TestCase):
    """Keeps reader presentation routes classified under ADR 0006."""

    def test_reader_sheet_cases_are_classified(self) -> None:
        """Every `ReaderSheet` case has an ADR-owned route classification."""
        source = READER_VIEW.read_text(encoding="utf-8")

        for case in swift_enum_cases(source, "ReaderSheet"):
            route_classification(f"ReaderSheet.{case}")

    def test_reader_destination_cases_are_classified(self) -> None:
        """Every `ReaderDestination` case has an ADR-owned route classification."""
        source = READER_VIEW.read_text(encoding="utf-8")

        for case in swift_enum_cases(source, "ReaderDestination"):
            route_classification(f"ReaderDestination.{case}")

    def test_reader_modal_cases_are_classified(self) -> None:
        """Every `ReaderModal` case has an ADR-owned route classification."""
        source = READER_VIEW.read_text(encoding="utf-8")

        for case in swift_enum_cases(source, "ReaderModal"):
            route_classification(f"ReaderModal.{case}")

    def test_standalone_transient_routes_are_classified(self) -> None:
        """State-backed reader presentations outside the enums remain documented."""
        for token in [
            "showReaderStrongsModeDialog",
            "shareSheetBinding",
            "crossReferenceSheetBinding",
            "showRefChooser",
            "BibleReaderModulePicker.AndroidPseudoDocument.myNotes",
        ]:
            route_classification(token)

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
        expected_owners = {
            "ReaderDestination.search": "Android app-owned",
            "ReaderDestination.bookmarks": "Android app-owned",
            "ReaderDestination.studyPads": "Android app-owned",
            "ReaderDestination.myDocuments": "Android app-owned",
            "ReaderDestination.readingPlans": "Android app-owned",
            "showRefChooser": "Android app-owned",
            "ReaderModal.chooseDocument": "Android app-owned",
            "ReaderModal.modulePicker": "Android app-owned",
            "ReaderModal.labelManager": "Android app-owned",
            "shareSheetBinding": "iOS system boundary",
            "crossReferenceSheetBinding": "Vue/WebView-owned",
            "BibleReaderModulePicker.AndroidPseudoDocument.myNotes": "Vue/WebView-owned",
        }

        for token, owner in expected_owners.items():
            self.assertEqual(owner, route_classification(token)[0])

    def test_drawer_owned_destinations_do_not_route_through_reader_sheets(self) -> None:
        """
        Keep left-drawer app screens on the reader destination stack.

        Android launches Bookmarks, StudyPads, and Reading Plan as app-owned activities from the
        drawer. The iOS drawer route must therefore not preserve the old SwiftUI sheet/modal path
        just because a legacy non-drawer shortcut still has a row in the matrix.
        """
        source = READER_VIEW.read_text(encoding="utf-8")
        drawer_handler = swift_function_body(source, "handleReaderNavigationDrawerAction")

        expected_destinations = {
            "bookmarks": "bookmarks",
            "studyPads": "studyPads",
            "myNotes": "myDocuments",
            "readingPlans": "readingPlans",
        }

        for drawer_case, destination_case in expected_destinations.items():
            body = swift_switch_case_body(drawer_handler, drawer_case)
            self.assertIn(f"presentReaderDestination(.{destination_case}", body)
            self.assertNotIn("presentReaderSheet", body)
            self.assertNotIn("presentReaderModal", body)

    def test_destination_owned_reader_routes_cannot_fall_back_to_legacy_ios_presentations(self) -> None:
        """
        Prevent Android app-owned destination screens from regressing into iOS sheet chrome.

        Bookmarks, StudyPads, and Reading Plans can be launched from several reader surfaces:
        drawer, pane menus, overflow callbacks, keyboard shortcuts, and chooser pseudo-documents.
        Android treats each as an app-owned screen, so iOS must keep those routes on
        `ReaderDestination` instead of preserving legacy `ReaderSheet` or nested modal cases.
        A failure means a route was reintroduced through one of the sibling entry points and the
        user will see platform sheet behavior again.
        """
        source = READER_VIEW.read_text(encoding="utf-8")

        sheet_cases = swift_enum_cases(source, "ReaderSheet")
        modal_cases = swift_enum_cases(source, "ReaderModal")

        self.assertNotIn("bookmarks", sheet_cases)
        self.assertNotIn("readingPlans", sheet_cases)
        self.assertNotIn("studyPadSelector", modal_cases)

        self.assertNotIn("presentReaderSheet(.bookmarks", source)
        self.assertNotIn("presentReaderSheet(.readingPlans", source)
        self.assertNotIn("presentReaderModalPreservingPane(.studyPadSelector", source)
        self.assertIn("presentReaderDestination(.bookmarks", source)
        self.assertIn("presentReaderDestination(.readingPlans", source)
        self.assertIn("onOpenStudyPadSelector: presentStudyPadsDestinationPreservingPane", source)

    def test_known_partial_routes_link_to_their_follow_up_issues(self) -> None:
        """
        Keep incomplete reader modal routes tied to explicit follow-up work.

        Android parity is not satisfied by labeling an iOS sheet as native.
        Routes listed here intentionally remain partial, so their issue
        references must stay visible in the disposition until the owning
        behavior is migrated or completed. Completed chooser routes should not
        remain in this sentinel because that would normalize stale partial-parity
        language.
        """
        expected_issues = {
            "ReaderModal.labelManager": "#246",
        }

        for token, issue in expected_issues.items():
            self.assertIn(issue, route_classification(token)[1])

    def test_legacy_cross_reference_sheet_is_not_a_document_pipeline_substitute(self) -> None:
        """
        Preserve the post-#124 ownership contract for cross-reference routing.

        Multi-reference Android parity is protected by the shared Vue
        `MultiDocument` path. The remaining Swift sheet row is a legacy callback,
        so future reader work should either keep it quarantined or remove it
        rather than treating it as an acceptable native replacement.
        """
        disposition = route_classification("crossReferenceSheetBinding")[1]

        self.assertIn("already bypass this route", disposition)
        self.assertIn("Do not expand the legacy sheet", disposition)

    def test_classifications_link_back_to_durable_modal_ownership_adrs(self) -> None:
        """The route classifications stay tied to the durable ownership ADRs."""
        modal_ownership_adr = ADR_0006.read_text(encoding="utf-8")
        documentation_adr = ADR_0008.read_text(encoding="utf-8")

        self.assertIn("Modal Presentation Ownership For Android Parity", modal_ownership_adr)
        self.assertIn("ADR 0006", documentation_adr)


if __name__ == "__main__":
    unittest.main()
