"""Guardrails for shared UI-test semantic state waiting."""

from __future__ import annotations

from pathlib import Path
import re
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]


def swift_function_body(source: str, name: str) -> str:
    """Return the Swift function body for focused source-contract checks."""
    match = re.search(rf"\bfunc\s+{re.escape(name)}\b", source)
    if match is None:
        raise AssertionError(f"Expected Swift function {name} to exist.")

    brace_index = source.find("{", match.end())
    if brace_index == -1:
        raise AssertionError(f"Expected Swift function {name} to have a body.")

    depth = 0
    for index in range(brace_index, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace_index + 1 : index]

    raise AssertionError(f"Expected Swift function {name} body to close.")


def swift_function_bodies(source: str, name: str) -> list[str]:
    """Return every Swift function body with a matching overloaded function name."""
    bodies: list[str] = []
    search_start = 0
    while True:
        match = re.search(rf"\bfunc\s+{re.escape(name)}\b", source[search_start:])
        if match is None:
            break
        absolute_match_start = search_start + match.start()
        brace_index = source.find("{", search_start + match.end())
        if brace_index == -1:
            raise AssertionError(f"Expected Swift function {name} to have a body.")

        depth = 0
        for index in range(brace_index, len(source)):
            char = source[index]
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    bodies.append(source[brace_index + 1 : index])
                    search_start = index + 1
                    break
        else:
            raise AssertionError(f"Expected Swift function {name} body to close.")

        if search_start <= absolute_match_start:
            raise AssertionError(f"Parser did not advance after Swift function {name}.")

    if not bodies:
        raise AssertionError(f"Expected Swift function {name} to exist.")
    return bodies


def swift_property_body(source: str, name: str) -> str:
    """Return the Swift computed property body for focused source-contract checks."""
    match = re.search(rf"\bvar\s+{re.escape(name)}\b", source)
    if match is None:
        raise AssertionError(f"Expected Swift property {name} to exist.")

    brace_index = source.find("{", match.end())
    if brace_index == -1:
        raise AssertionError(f"Expected Swift property {name} to have a body.")

    depth = 0
    for index in range(brace_index, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace_index + 1 : index]

    raise AssertionError(f"Expected Swift property {name} body to close.")


class SemanticWaitGuardrailsTests(unittest.TestCase):
    """Protects pure semantic-state waits from regressing to ad hoc run-loop polling."""

    def test_workspace_create_prompt_waits_on_prompt_controls_without_root_probe(self) -> None:
        """Avoid hosted XCTest stalls from probing the prompt root before controls."""
        list_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestListSupport.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(list_source, "openWorkspaceCreatePrompt")

        prompt_root = '"workspaceNamePromptScreen"'
        prompt_field = '"workspaceNamePromptTextField"'
        confirm_button = '"workspaceNamePromptConfirmButton"'
        cancel_button = '"workspaceNamePromptCancelButton"'

        for identifier in [prompt_field, confirm_button, cancel_button]:
            self.assertIn(identifier, body)
        self.assertNotIn(prompt_root, body)

        self.assertLess(body.find(prompt_field), body.find(confirm_button))
        self.assertLess(body.find(prompt_field), body.find(cancel_button))

    def test_workspace_prompt_button_candidates_prefer_prompt_scope_and_titles(self) -> None:
        """Keep workspace prompt button lookup off expensive app-wide identifier queries first."""
        element_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestElementSupport.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(element_source, "workspaceNamePromptButtonCandidates")

        prompt_candidate = 'app.otherElements["workspaceNamePromptScreen"].firstMatch'
        scoped_button_candidates = "modalButtonCandidates("
        title_candidate = "app.buttons[title].firstMatch"
        identifier_candidate = "app.buttons[identifier].firstMatch"

        for snippet in [
            prompt_candidate,
            scoped_button_candidates,
            title_candidate,
            identifier_candidate,
        ]:
            self.assertIn(snippet, body)

        self.assertLess(body.find(prompt_candidate), body.find(identifier_candidate))
        self.assertLess(body.find(scoped_button_candidates), body.find(identifier_candidate))
        self.assertLess(body.find(title_candidate), body.find(identifier_candidate))

    def test_search_state_candidates_prefer_hidden_export_before_screen_root(self) -> None:
        """Keep Search state polling on the dedicated lightweight export before the root."""
        element_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestElementSupport.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(element_source, "semanticStateValueCandidates")
        search_case_start = body.find('case "searchStateExport":')
        bookmark_case_start = body.find('case "bookmarkListStateExport":')
        self.assertNotEqual(search_case_start, -1)
        self.assertNotEqual(bookmark_case_start, -1)

        search_case = body[search_case_start:bookmark_case_start]
        root_candidate = 'app.otherElements["searchScreen"].firstMatch'
        hidden_export_candidate = (
            'screenScopedStateCandidates(identifier, within: "searchScreen", in: app)'
        )

        self.assertIn(root_candidate, search_case)
        self.assertIn(hidden_export_candidate, search_case)
        self.assertLess(
            search_case.find(hidden_export_candidate),
            search_case.find(root_candidate),
        )

    def test_search_interaction_ready_does_not_read_state_before_poll_loop(self) -> None:
        """Keep the Search readiness timeout from being consumed by a pre-loop XCTest snapshot."""
        search_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestSearchSupport.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(search_source, "waitForSearchInteractionReady")
        loop_start = body.find("while Date() < deadline")
        self.assertNotEqual(loop_start, -1)

        pre_loop = body[:loop_start]
        self.assertNotIn("resolvedSearchStateValue", pre_loop)
        self.assertNotIn("searchScreen.value", pre_loop)

    def test_search_opening_verifies_presentation_before_success(self) -> None:
        """Keep reader-triggered Search opening state-driven instead of tap-assumption driven."""
        search_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestSearchSupport.swift"
        ).read_text(encoding="utf-8")
        open_body = swift_function_body(search_source, "openSearch")
        presentation_body = swift_function_body(search_source, "presentSearchFromReader")

        self.assertIn("presentSearchFromReader", open_body)
        self.assertNotIn("tapReaderSearchEntry", open_body)
        self.assertIn("resolvedSearchScreenElement", presentation_body)
        self.assertIn('readerRenderedContentStateContains("searchVisible=true"', presentation_body)
        drawer_action = re.search(
            r"tapReaderAction\s*\(\s*\"readerOpenSearchAction\"",
            presentation_body,
        )
        self.assertIsNotNone(drawer_action)
        self.assertLess(
            presentation_body.find("tapReaderSearchEntry"),
            drawer_action.start(),
        )

    def test_window_tab_bar_identifier_belongs_to_scroll_view_container(self) -> None:
        """Keep tab-button lookup scoped to the actual container that owns the buttons."""
        source = (
            REPO_ROOT / "Sources/BibleUI/Sources/BibleUI/Bible/WindowTabBar.swift"
        ).read_text(encoding="utf-8")
        body_start = source.find("var body: some View")
        footer_start = source.find("private func footerStrip")
        self.assertNotEqual(body_start, -1)
        self.assertNotEqual(footer_start, -1)

        body_section = source[body_start:footer_start]
        footer_body = swift_function_body(source, "footerStrip")
        scroll_view = "ScrollView(.horizontal, showsIndicators: false)"
        identifier = '.accessibilityIdentifier("windowTabBar")'

        self.assertNotIn(identifier, body_section)
        self.assertIn(scroll_view, footer_body)
        self.assertIn(identifier, footer_body)
        self.assertLess(footer_body.find(scroll_view), footer_body.find(identifier))

    def test_window_tab_helpers_avoid_app_wide_button_fallbacks(self) -> None:
        """Keep tab selection from falling back to expensive full-hierarchy button queries."""
        element_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestElementSupport.swift"
        ).read_text(encoding="utf-8")
        reader_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestReaderSupport.swift"
        ).read_text(encoding="utf-8")

        candidates_body = swift_function_body(element_source, "windowTabBarButtonCandidates")
        tap_body = swift_function_body(element_source, "tapWindowTab")
        coordinate_tap_body = swift_function_body(
            element_source,
            "tapWindowTabAtExpectedFooterCoordinate",
        )
        add_body = swift_function_body(element_source, "addWindowTab")
        existence_body = swift_function_body(reader_source, "waitForElementExistence")

        self.assertIn('app.scrollViews["windowTabBar"].firstMatch', candidates_body)
        self.assertIn('app.otherElements["windowTabBar"].firstMatch', candidates_body)
        self.assertNotIn("app.buttons[identifier]", candidates_body)
        self.assertNotIn("app.collectionViews.buttons[identifier]", candidates_body)
        self.assertNotIn("app.cells.buttons[identifier]", candidates_body)

        self.assertIn("requireWindowTabBarButton", tap_body)
        self.assertNotIn("requireElement(identifier", tap_body)
        self.assertIn("tapWindowTabAtExpectedFooterCoordinate", tap_body)
        self.assertIn('waitForReaderRenderedContentStateIfPresent', coordinate_tap_body)
        self.assertIn('"windowOrder=\\(order)"', coordinate_tap_body)
        self.assertIn("requireWindowTabBarButton", add_body)
        self.assertIn("resolvedWindowTabBarButton", add_body)
        self.assertIn("isWindowTabBarButtonIdentifier", existence_body)
        self.assertIn("resolvedWindowTabBarButton", existence_body)

    def test_reader_state_export_includes_window_tab_orders_for_tab_fallback(self) -> None:
        """Expose tab order metadata so tests can tap the real footer without stale queries."""
        source = (
            REPO_ROOT / "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        ).read_text(encoding="utf-8")
        body = swift_property_body(source, "readerRenderedContentStateValue")

        self.assertIn("windowTabOrders=", body)
        self.assertIn("windowManager.allWindows", body)
        self.assertIn('return "\\(windowToken);\\(contentToken);\\(tabOrdersToken);', body)

    def test_resolved_semantic_wait_uses_xctest_waiter_not_run_loop_polling(self) -> None:
        """Ensure the shared pure-observation wait is backed by XCTest wait primitives."""
        state_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestStateSupport.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(state_source, "waitForResolvedSemanticState")

        self.assertIn("XCTNSPredicateExpectation", body)
        self.assertIn("XCTWaiter", body)
        self.assertNotIn("RunLoop.current.run", body)
        self.assertNotRegex(body, re.compile(r"\brepeat\s*\{"))

    def test_resolved_semantic_wait_failure_reports_elapsed_and_final_state(self) -> None:
        """Keep timeout failures actionable without reintroducing custom polling loops."""
        state_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestStateSupport.swift"
        ).read_text(encoding="utf-8")
        body = swift_function_body(state_source, "waitForResolvedSemanticState")

        self.assertIn("elapsed", body)
        self.assertIn("final observed state", body)
        self.assertIn("last observed state", body)
        self.assertRegex(body, re.compile(r"valueProvider\(\)[\s\S]*success\(finalValue\)"))
        self.assertRegex(
            body,
            re.compile(
                r"let\s+lastObservedBeforeFinalRead\s*=\s*lastObservedValue"
                r"[\s\S]*if\s+let\s+finalValue\s*=\s*valueProvider\(\)"
            ),
        )
        self.assertRegex(
            body,
            re.compile(
                r"let\s+lastObservedState\s*=\s*lastObservedBeforeFinalRead\s*\?\?\s*\"<none>\""
            ),
        )
        self.assertNotIn("lastObservedValue = finalValue", body)

    def test_representative_pure_observation_waits_use_shared_helper(self) -> None:
        """Keep migrated value/state waits on the shared XCTest-backed helper."""
        reader_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestReaderSupport.swift"
        ).read_text(encoding="utf-8")
        list_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestListSupport.swift"
        ).read_text(encoding="utf-8")

        for body in swift_function_bodies(reader_source, "waitForElementValue"):
            self.assertIn("waitForResolvedSemanticState", body)
            self.assertNotIn("RunLoop.current.run", body)

        bookmark_rows_body = swift_function_body(list_source, "waitForBookmarkListRows")
        self.assertIn("waitForResolvedSemanticState", bookmark_rows_body)
        self.assertNotIn("RunLoop.current.run", bookmark_rows_body)

    def test_reader_and_sync_state_waits_use_shared_semantic_waiter(self) -> None:
        """Keep exported reader/sync state checks hook-driven instead of run-loop polling."""
        element_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestElementSupport.swift"
        ).read_text(encoding="utf-8")
        state_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestStateSupport.swift"
        ).read_text(encoding="utf-8")

        migrated_waits = [
            swift_function_body(element_source, "waitForReaderRenderedContentState"),
            swift_function_body(element_source, "waitForReaderRenderedContentStateIfPresent"),
            swift_function_body(state_source, "waitForSyncState"),
        ]

        for body in migrated_waits:
            self.assertIn("waitForResolvedSemanticState", body)
            self.assertNotIn("RunLoop.current.run", body)

    def test_settings_and_reading_plan_state_waits_use_shared_semantic_waiter(self) -> None:
        """Keep Settings and Reading Plan exported state waits off manual polling loops."""
        element_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestElementSupport.swift"
        ).read_text(encoding="utf-8")
        interaction_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestInteractionSupport.swift"
        ).read_text(encoding="utf-8")
        list_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestListSupport.swift"
        ).read_text(encoding="utf-8")

        reading_plan_exclusion_body = swift_function_body(
            list_source,
            "waitForReadingPlanListStateToExclude",
        )
        migrated_waits = [
            swift_function_body(interaction_source, "waitForSettingsState"),
            reading_plan_exclusion_body,
        ]

        for body in migrated_waits:
            self.assertIn("waitForResolvedSemanticState", body)
            self.assertNotIn("RunLoop.current.run", body)
        self.assertNotIn("missingCountsAsSuccess: true", reading_plan_exclusion_body)

        candidates_body = swift_function_body(element_source, "semanticStateValueCandidates")
        self.assertIn('case "settingsForm":', candidates_body)
        self.assertIn('screenRootCandidates("settingsForm", in: app)', candidates_body)

    def test_value_state_waits_use_shared_semantic_waiter(self) -> None:
        """Keep pure accessibility-value waits on XCTest predicates, not run-loop polling."""
        state_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestStateSupport.swift"
        ).read_text(encoding="utf-8")
        search_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestSearchSupport.swift"
        ).read_text(encoding="utf-8")
        element_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestElementSupport.swift"
        ).read_text(encoding="utf-8")

        migrated_waits = [
            swift_function_body(state_source, "waitForSwitchValue"),
            swift_function_body(search_source, "waitForSearchTranslationSelectToggleValue"),
            swift_function_body(element_source, "requireReaderReferenceValue"),
            swift_function_body(element_source, "waitForReaderReferenceValueToChange"),
        ]

        for body in migrated_waits:
            self.assertIn("waitForResolvedSemanticState", body)
            self.assertNotIn("RunLoop.current.run", body)

    def test_search_boolean_state_waits_use_shared_semantic_waiter(self) -> None:
        """Keep Search boolean state probes on the shared waiter without recording failures."""
        search_source = (
            REPO_ROOT / "Tests/UI/AndBibleUITests/AndBibleUITestSearchSupport.swift"
        ).read_text(encoding="utf-8")

        migrated_waits = [
            swift_function_body(search_source, "searchTranslationPickerStateIsOpen"),
            swift_function_body(search_source, "waitForSearchFieldFocusToClear"),
        ]

        for body in migrated_waits:
            self.assertIn("waitForResolvedSemanticState", body)
            self.assertIn("recordsFailure: false", body)
            self.assertNotIn("RunLoop.current.run", body)


if __name__ == "__main__":
    unittest.main()
