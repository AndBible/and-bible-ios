#!/usr/bin/env python3
"""
Regression tests for the workspace prompt UI-test lookup contract.
"""

from __future__ import annotations

from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]


class WorkspacePromptUITestContractTests(unittest.TestCase):
    """Guards the CI-stable workspace prompt lookup path used by UI tests."""

    def test_workspace_prompt_entry_waits_for_controls_without_root_probe(self) -> None:
        """The create flow types through prompt-owned controls instead of root/field probing.

        The failing CI shard showed root prompt-surface lookup can hang before the actual controls
        are considered. The live entry helper should prefer prompt-owned action controls, use the
        prompt's autofocus for keyboard input, and avoid using the root surface or field value as a
        readiness signal.
        """
        source = (
            REPO_ROOT / "Tests" / "UI" / "AndBibleUITests" / "AndBibleUITestListSupport.swift"
        ).read_text()
        open_prompt_start = source.index("func typeWorkspaceNamePromptText(")
        open_prompt_end = source.index("/**", open_prompt_start)
        open_prompt_body = source[open_prompt_start:open_prompt_end]

        self.assertIn('"workspaceNamePromptConfirmButton"', open_prompt_body)
        self.assertIn('"workspaceNamePromptCancelButton"', open_prompt_body)
        self.assertIn("app.typeText(text)", open_prompt_body)
        self.assertNotIn('"workspaceNamePromptScreen"', open_prompt_body)
        self.assertNotIn('"workspaceNamePromptTextField"', open_prompt_body)
        self.assertNotIn("currentTextEntryValue", open_prompt_body)

    def test_workspace_prompt_field_candidates_avoid_custom_identifier_and_focus_queries(self) -> None:
        """The prompt field lookup stays on title candidates instead of custom identifier queries.

        Android presents create/rename/clone as an `AlertDialog` with an `EditText` from
        `WorkspaceSelectorActivity`; iOS exposes the equivalent SwiftUI text field most reliably
        through its visible title. A failure here means the lookup can regress to the custom
        accessibility identifier or focused-descendant scans that can stall hosted XCTest.
        """
        source = (
            REPO_ROOT / "Tests" / "UI" / "AndBibleUITests" / "AndBibleUITestElementSupport.swift"
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
            REPO_ROOT / "Tests" / "UI" / "AndBibleUITests" / "AndBibleUITestElementSupport.swift"
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
            REPO_ROOT / "Tests" / "UI" / "AndBibleUITests" / "AndBibleUITestElementSupport.swift"
        ).read_text()
        state_source = (
            REPO_ROOT / "Tests" / "UI" / "AndBibleUITests" / "AndBibleUITestListSupport.swift"
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
        typing_start = state_source.index("func typeWorkspaceNamePromptText(")
        typing_end = state_source.index("/**", typing_start)
        typing_body = state_source[typing_start:typing_end]

        self.assertIn("app.otherElements[identifier].firstMatch", prompt_candidates_body)
        self.assertNotIn("app.collectionViews[identifier]", prompt_candidates_body)
        self.assertNotIn("app.scrollViews[identifier]", prompt_candidates_body)
        self.assertNotIn("workspaceNamePromptScreenCandidates(in: app)", typing_body)
        self.assertNotIn('app.collectionViews["workspaceNamePromptScreen"]', typing_body)
        self.assertNotIn('app.scrollViews["workspaceNamePromptScreen"]', typing_body)
        self.assertNotIn('case "workspaceNamePromptTextField"', typing_body)
        self.assertNotIn("CGVector(dx: 0.5, dy: 0.46)", typing_body)
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

    def test_workspace_prompt_typing_avoids_text_field_value_reads(self) -> None:
        """The workspace prompt typing path verifies submit readiness instead of field value.

        Hosted XCTest can resolve the SwiftUI `Name` text field, focus it through a stable app
        coordinate, and then lose that text-field snapshot when the helper reads `value`. The
        workspace create flow should prove text entry by the prompt submit button becoming enabled
        and by the later workspace-row assertions, not by re-sampling the transient field.
        """
        state_source = (
            REPO_ROOT / "Tests" / "UI" / "AndBibleUITests" / "AndBibleUITestListSupport.swift"
        ).read_text()
        typing_start = state_source.index("func typeWorkspaceNamePromptText(")
        typing_end = state_source.index("/**", typing_start)
        typing_body = state_source[typing_start:typing_end]

        self.assertIn('"workspaceNamePromptConfirmButton"', typing_body)
        self.assertIn('"workspaceNamePromptCancelButton"', typing_body)
        self.assertIn("app.typeText(text)", typing_body)
        self.assertIn("workspaceNamePromptButtonCandidates", typing_body)
        self.assertNotIn("func typePromptText(", state_source)
        self.assertNotIn("promptField.typeText(text)", typing_body)
        self.assertNotIn("requireWorkspaceNamePromptField", typing_body)
        self.assertNotIn("focusResolvedPromptTextEntryElement", typing_body)
        self.assertNotIn("observedPromptTextValue", typing_body)
        self.assertNotIn("currentTextEntryValue", typing_body)

    def test_workspace_prompt_requests_focus_after_attachment(self) -> None:
        """The workspace name prompt owns focus like Android's `EditText` dialog.

        Android calls `requestFocus()` and shows the soft input when creating, renaming, or cloning a
        workspace. The iOS prompt must keep that behavior in product code so tests do not focus the
        field by tapping an approximate screen coordinate that can dismiss the dialog.
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

        self.assertIn(".focused($isNameFieldFocused)", prompt_source)
        self.assertIn(".onAppear { isNameFieldFocused = true }", prompt_source)
        self.assertIn(".task(id: prompt)", prompt_source)
        self.assertIn("await Task.yield()", prompt_source)
        self.assertGreaterEqual(prompt_source.count("isNameFieldFocused = true"), 2)

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
        self.assertIn("private var selectorDialogOverlay", source)
        self.assertIn("if let prompt = workspacePrompt", source)
        self.assertIn("WorkspaceNamePromptView(", source)
        prompt_source = source[source.index("private struct WorkspaceNamePromptView") :]
        self.assertIn("AndroidDialogWindow(", prompt_source)
        self.assertIn("AndroidDialogTextInput(", prompt_source)

    def test_workspace_prompt_screen_exports_accessibility_container(self) -> None:
        """The prompt exports a stable identity without replacing its child-control identities.

        XCTest waits for `workspaceNamePromptScreen` before resolving the text field so failures are
        attributed to prompt presentation instead of broad text-field queries. SwiftUI propagates
        identifiers attached to composite containers into their descendants on current iOS
        releases, so the shared dialog must retain semantic containment on the visible surface and
        export its automation identity from a noninteractive sibling marker.
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
        shared_dialog_source = (
            REPO_ROOT
            / "Sources"
            / "BibleUI"
            / "Sources"
            / "BibleUI"
            / "Shared"
            / "AndroidDialogWindow.swift"
        ).read_text()

        self.assertIn('accessibilityIdentifier: "workspaceNamePromptScreen"', prompt_source)
        self.assertIn(".accessibilityElement(children: .contain)", shared_dialog_source)
        self.assertIn("AndroidActivityAccessibilityMarker(", shared_dialog_source)
        self.assertIn("accessibilityIdentifier: accessibilityIdentifier", shared_dialog_source)
        self.assertIn(
            "UITestRuntimeConfiguration.enablesDetailedAccessibilityExports",
            shared_dialog_source,
        )
        self.assertNotIn(
            ".accessibilityIdentifier(accessibilityIdentifier)",
            shared_dialog_source,
        )

    def test_workspace_selector_identifier_stays_scoped_to_list(self) -> None:
        """The selector screen identifier does not overwrite child or prompt identities.

        The prompt is rendered inside the selector `ZStack`. If `workspaceSelectorScreen` is applied
        directly to that composite tree, SwiftUI can overwrite row and prompt identifiers. The
        selector therefore exports its identity through the shared sibling marker.
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
        list_start = source.index("private var workspaceList")
        row_start = source.index("private func workspaceRow", list_start)
        list_source = source[list_start:row_start]
        selector_start = source.index("private var selectorActivity")
        search_start = source.index("private var workspaceSearchBar", selector_start)
        selector_source = source[selector_start:search_start]

        self.assertNotIn('.accessibilityIdentifier("workspaceSelectorScreen")', list_source)
        self.assertNotIn('.accessibilityIdentifier("workspaceSelectorScreen")', selector_source)
        self.assertIn(".androidAccessibilityIdentityMarker(", selector_source)
        self.assertIn('accessibilityIdentifier: "workspaceSelectorScreen"', selector_source)
        self.assertIn("selectorDialogOverlay", selector_source)

    def test_workspace_selector_uses_shared_android_activity_contracts(self) -> None:
        """The selector cannot regress to native iOS presentation or cosmetic-only parity.

        Android owns the action bar, RecyclerView rows, per-row PopupMenu, Help dialog, staged
        Dismiss/Save boundary, and selective settings-copy workflow. The iOS route must compose the
        shared app-owned equivalents and keep mutations in value drafts until commit.
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

        for required_contract in (
            "AndroidActivityScreen(",
            "AndroidActivityCommitBar(",
            ".androidAnchoredPopupMenu(",
            "AndroidPopupMenuSurface(",
            "AndroidHelpDialog(topics: [.workspaces]",
            "AndroidMultiselectDialogContent(",
            "TextDisplaySettingsView(",
            "WorkspaceSelectorDraft",
            "initialDrafts",
            "private func applyDrafts()",
        ):
            self.assertIn(required_contract, source)

        for forbidden_native_contract in (
            "List {",
            ".contextMenu {",
            ".navigationTitle(",
            ".toolbar {",
            "EditButton(",
            ".sheet(",
        ):
            self.assertNotIn(forbidden_native_contract, source)
        self.assertIsNone(re.search(r"(?<![A-Za-z])Menu\s*\(", source))


if __name__ == "__main__":
    unittest.main()
