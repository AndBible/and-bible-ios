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
        """The create flow waits for prompt-owned controls before falling back to field resolution.

        The failing CI shard showed generic prompt-surface lookup could hang when it used the wrong
        container types. The opener should prefer prompt-owned buttons and the prompt surface before
        using the editable field as a final readiness signal.
        """
        source = (
            REPO_ROOT / "AndBibleUITests" / "AndBibleUITestListSupport.swift"
        ).read_text()
        open_prompt_start = source.index("func openWorkspaceCreatePrompt(")
        open_prompt_end = source.index("func requireWorkspaceNamePromptField(", open_prompt_start)
        open_prompt_body = source[open_prompt_start:open_prompt_end]

        self.assertIn('"workspaceNamePromptConfirmButton"', open_prompt_body)
        self.assertIn('"workspaceNamePromptCancelButton"', open_prompt_body)
        self.assertIn('"workspaceNamePromptScreen"', open_prompt_body)
        self.assertIn('"workspaceNamePromptTextField"', open_prompt_body)

    def test_workspace_prompt_field_candidates_avoid_custom_identifier_and_focus_queries(self) -> None:
        """The prompt field lookup stays on title candidates instead of custom identifier queries.

        Android presents create/rename/clone as an `AlertDialog` with an `EditText` from
        `WorkspaceSelectorActivity`; iOS exposes the equivalent SwiftUI text field most reliably
        through its visible title. A failure here means the lookup can regress to the custom
        accessibility identifier or focused-descendant scans that can stall hosted XCTest.
        """
        source = (
            REPO_ROOT / "AndBibleUITests" / "AndBibleUITestElementSupport.swift"
        ).read_text()
        candidates_start = source.index("func workspaceNamePromptTextFieldCandidates")
        candidates_end = source.index("func workspaceNamePromptButtonCandidates", candidates_start)
        candidates_body = source[candidates_start:candidates_end]

        self.assertIn('["Name", "name"]', candidates_body)
        self.assertIn("app.textFields[title].firstMatch", candidates_body)
        self.assertNotIn('let identifier = "workspaceNamePromptTextField"', candidates_body)
        self.assertNotIn("workspaceNamePromptScreenCandidates(in: app)", candidates_body)
        self.assertNotIn("hasKeyboardFocus", candidates_body)
        self.assertNotIn("descendants(matching: .any)", candidates_body)
        self.assertNotIn("prompt.textFields", candidates_body)

    def test_workspace_prompt_button_candidates_stay_on_prompt_buttons(self) -> None:
        """The prompt button lookup avoids unrelated containers that can stall hosted XCTest.

        The prompt confirm and cancel controls are selector-owned overlay buttons. They should not
        be looked up through navigation bars, toolbars, table rows, scroll views, or generic
        `otherElements` before the actual button surface has had a chance to appear.
        """
        source = (
            REPO_ROOT / "AndBibleUITests" / "AndBibleUITestElementSupport.swift"
        ).read_text()
        candidates_start = source.index("func workspaceNamePromptButtonCandidates")
        candidates_end = source.index("func semanticStateCandidates", candidates_start)
        candidates_body = source[candidates_start:candidates_end]

        self.assertIn("app.buttons[identifier].firstMatch", candidates_body)
        self.assertIn("app.buttons[title].firstMatch", candidates_body)
        self.assertNotIn("app.navigationBars.buttons[identifier]", candidates_body)
        self.assertNotIn("app.toolbars.buttons[identifier]", candidates_body)
        self.assertNotIn("app.collectionViews.buttons[identifier]", candidates_body)
        self.assertNotIn("app.tables.buttons[identifier]", candidates_body)
        self.assertNotIn("app.scrollViews.buttons[identifier]", candidates_body)
        self.assertNotIn("app.otherElements[identifier]", candidates_body)

    def test_workspace_prompt_screen_uses_prompt_specific_container_lookup(self) -> None:
        """The prompt surface lookup must stay bounded and must not drive text-entry focus.

        The CI shard failure timed out while `waitForAnyElement(["workspaceNamePromptScreen"])`
        evaluated generic table/collection/scroll candidates before reaching the SwiftUI prompt's
        actual accessibility node. A later shard failure showed that even the bounded prompt-root
        query can wedge if the typing helper reads the root frame for a tap coordinate after the
        text field is already resolved. A failure here means the create-workspace test can regress
        to a hosted XCTest snapshot path that stalls before text entry.
        """
        source = (
            REPO_ROOT / "AndBibleUITests" / "AndBibleUITestElementSupport.swift"
        ).read_text()
        state_source = (
            REPO_ROOT / "AndBibleUITests" / "AndBibleUITestStateSupport.swift"
        ).read_text()
        prompt_candidates_start = source.index("func workspaceNamePromptScreenCandidates")
        prompt_candidates_end = source.index(
            "func workspaceNamePromptTextFieldCandidates",
            prompt_candidates_start,
        )
        prompt_candidates_body = source[prompt_candidates_start:prompt_candidates_end]
        element_candidates_start = source.index("func elementCandidates(")
        element_candidates_end = source.index("func resolvedElement(", element_candidates_start)
        element_candidates_body = source[element_candidates_start:element_candidates_end]
        coordinate_start = state_source.index('case "workspaceNamePromptTextField":')
        coordinate_end = state_source.index("default:", coordinate_start)
        coordinate_body = state_source[coordinate_start:coordinate_end]

        self.assertIn("app.otherElements[identifier].firstMatch", prompt_candidates_body)
        self.assertNotIn("app.collectionViews[identifier]", prompt_candidates_body)
        self.assertNotIn("app.scrollViews[identifier]", prompt_candidates_body)
        self.assertNotIn("workspaceNamePromptScreenCandidates(in: app)", coordinate_body)
        self.assertNotIn('app.collectionViews["workspaceNamePromptScreen"]', coordinate_body)
        self.assertNotIn('app.scrollViews["workspaceNamePromptScreen"]', coordinate_body)
        self.assertIn("return nil", coordinate_body)
        self.assertIn(
            'case "workspaceNamePromptScreen":\n'
            "            return workspaceNamePromptScreenCandidates(in: app)",
            element_candidates_body,
        )
        self.assertNotIn(
            '"historyScreen", "readingPlanListScreen", "availablePlansScreen", '
            '"workspaceNamePromptScreen"',
            element_candidates_body,
        )

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
