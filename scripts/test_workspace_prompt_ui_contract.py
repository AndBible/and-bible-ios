#!/usr/bin/env python3
"""
Regression tests for the workspace prompt UI-test lookup contract.
"""

from __future__ import annotations

from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class WorkspacePromptUITestContractTests(unittest.TestCase):
    """Guards the CI-stable workspace prompt lookup path used by UI tests."""

    def test_workspace_prompt_open_waits_for_prompt_surface_before_field_queries(self) -> None:
        """The create flow waits for the prompt surface before resolving the editable field.

        The failing CI shard showed app-wide text-field queries could hang while the prompt was
        absent. A failure here means the UI test can regress to broad field lookup before proving
        the product prompt opened.
        """
        source = (
            REPO_ROOT / "AndBibleUITests" / "AndBibleUITestListSupport.swift"
        ).read_text()
        open_prompt_start = source.index("func openWorkspaceCreatePrompt(")
        open_prompt_end = source.index("func requireWorkspaceNamePromptField(", open_prompt_start)
        open_prompt_body = source[open_prompt_start:open_prompt_end]

        self.assertIn("workspaceNamePromptScreenCandidates(in: app)", open_prompt_body)
        self.assertNotIn('"workspaceNamePromptTextField"', open_prompt_body)

    def test_workspace_prompt_field_candidates_avoid_app_wide_name_fallbacks(self) -> None:
        """The prompt field lookup stays scoped to the visible workspace-name prompt.

        Android presents create/rename/clone as an `AlertDialog` with an `EditText` from
        `WorkspaceSelectorActivity`; iOS must first find the equivalent prompt container, then
        its text field. A failure here means the lookup can wander into unrelated `Name` fields.
        """
        source = (
            REPO_ROOT / "AndBibleUITests" / "AndBibleUITestElementSupport.swift"
        ).read_text()
        candidates_start = source.index("func workspaceNamePromptTextFieldCandidates")
        candidates_end = source.index("func workspaceNamePromptButtonCandidates", candidates_start)
        candidates_body = source[candidates_start:candidates_end]

        self.assertIn("workspaceNamePromptScreenCandidates(in: app)", candidates_body)
        self.assertNotIn('app.textFields["Name"]', candidates_body)
        self.assertNotIn("app.collectionViews.textFields", candidates_body)
        self.assertNotIn("app.tables.textFields", candidates_body)
        self.assertNotIn("app.scrollViews.textFields", candidates_body)

    def test_workspace_prompt_is_selector_owned_instead_of_nested_sheet(self) -> None:
        """The create/rename/clone prompt is owned by the selector, matching Android dialog scope.

        Android shows an `AlertDialog` inside `WorkspaceSelectorActivity` rather than launching a
        second activity. iOS previously used a SwiftUI sheet from inside the selector sheet, which
        failed to present in the shard. A failure here means the product can regress to that nested
        presentation path instead of a selector-owned transient prompt.
        """
        source = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Workspace"
            / "WorkspaceSelectorView.swift"
        ).read_text()

        self.assertNotIn(".sheet(item: $workspacePrompt", source)
        self.assertIn("workspacePromptOverlay(prompt)", source)

    def test_workspace_prompt_screen_exports_accessibility_container(self) -> None:
        """The prompt surface itself is an accessibility container, not only a visual `VStack`.

        XCTest waits for `workspaceNamePromptScreen` before resolving the text field so failures are
        attributed to prompt presentation instead of broad text-field queries. A SwiftUI container
        with only an identifier is not consistently queryable, so the production prompt must export
        the container while preserving child controls.
        """
        source = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Workspace"
            / "WorkspaceSelectorView.swift"
        ).read_text()
        prompt_start = source.index("private struct WorkspaceNamePromptView")
        prompt_source = source[prompt_start:]

        self.assertIn('.accessibilityIdentifier("workspaceNamePromptScreen")', prompt_source)
        self.assertIn(".accessibilityElement(children: .contain)", prompt_source)

    def test_workspace_selector_identifier_stays_scoped_to_list(self) -> None:
        """The selector screen identifier does not overwrite the prompt overlay identity.

        The prompt is rendered inside the selector `ZStack`. If `workspaceSelectorScreen` is applied
        to that outer stack, SwiftUI can export the prompt card with the selector identifier and make
        `workspaceNamePromptScreen` unobservable. The identifier must stay on the list surface.
        """
        source = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Workspace"
            / "WorkspaceSelectorView.swift"
        ).read_text()
        body_start = source.index("public var body: some View")
        overlay_start = source.index("private func workspacePromptOverlay", body_start)
        body_source = source[body_start:overlay_start]

        self.assertIn(
            '.accessibilityIdentifier("workspaceSelectorScreen")\n'
            "            .disabled(workspacePrompt != nil)",
            body_source,
        )
        self.assertNotIn(
            '.accessibilityIdentifier("workspaceSelectorScreen")\n'
            "        .navigationTitle",
            body_source,
        )


if __name__ == "__main__":
    unittest.main()
