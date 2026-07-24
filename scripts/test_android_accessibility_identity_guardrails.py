#!/usr/bin/env python3
"""Guard app-owned Android presentation identities from masking interactive descendants."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
BIBLE_UI = REPO_ROOT / "Sources" / "BibleUI" / "Sources" / "BibleUI"
APP = REPO_ROOT / "AndBible"


def source(path: Path) -> str:
    """Return one UTF-8 source file used by a structural contract test."""
    return path.read_text(encoding="utf-8")


def source_between(text: str, start: str, end: str) -> str:
    """Return a required source slice bounded by two unique contract anchors."""
    start_index = text.index(start)
    end_index = text.index(end, start_index)
    return text[start_index:end_index]


class AndroidAccessibilityIdentityGuardrailTests(unittest.TestCase):
    """Protect shared presentation identity without weakening semantic UI-test locators."""

    def test_dialog_window_keeps_identity_beside_visible_content(self) -> None:
        """Dialog identity must not replace identifiers on fields, rows, or action buttons."""
        dialog = source(BIBLE_UI / "Shared" / "AndroidDialogWindow.swift")

        self.assertIn(".accessibilityElement(children: .contain)", dialog)
        self.assertIn("AndroidActivityAccessibilityMarker(", dialog)
        self.assertIn("accessibilityIdentifier: accessibilityIdentifier", dialog)
        self.assertNotIn(".accessibilityIdentifier(accessibilityIdentifier)", dialog)

    def test_popup_menu_keeps_identity_beside_interactive_rows(self) -> None:
        """Popup identity must not mask row identifiers at either shared presentation layer."""
        popup = source(BIBLE_UI / "Shared" / "AndroidPopupMenu.swift")
        anchored_popup = source(BIBLE_UI / "Shared" / "AndroidAnchoredPopupMenu.swift")

        self.assertIn(".accessibilityElement(children: .contain)", popup)
        self.assertIn(".androidAccessibilityIdentityMarker(", popup)
        self.assertIn("accessibilityIdentifier: accessibilityIdentifier", popup)
        self.assertNotIn(".accessibilityIdentifier(accessibilityIdentifier)", popup)
        self.assertNotIn(".accessibilityIdentifier(accessibilityIdentifier)", anchored_popup)
        self.assertIn('"\\(accessibilityIdentifier)DismissalLayer"', anchored_popup)

    def test_generic_dialog_families_reuse_the_shared_window_and_scaffold(self) -> None:
        """AI and document-details dialogs cannot retain parallel scrim/card implementations."""
        ai_configuration = source(BIBLE_UI / "AI" / "AIConfigurationDialogPresentation.swift")
        audited_dialogs = {
            "AI models": (
                source(BIBLE_UI / "AI" / "AIModelDialogs.swift"),
                "AIAndroidDialogSurface(",
            ),
            "AI prompts": (
                source(BIBLE_UI / "AI" / "AIPromptDialogPresentation.swift"),
                "AndroidDialogScaffold(",
            ),
            "module details": (
                source(BIBLE_UI / "Downloads" / "ModuleBrowserRowActionPresentation.swift"),
                "AndroidDialogScaffold(",
            ),
        }

        self.assertIn(
            "typealias AIAndroidDialogSurface<Content: View, Actions: View> =",
            ai_configuration,
        )
        self.assertIn("AndroidDialogScaffold<Content, Actions>", ai_configuration)
        self.assertIn("typealias AIAndroidDialogAction = AndroidDialogTextAction", ai_configuration)

        for owner, (dialog_source, shared_surface) in audited_dialogs.items():
            with self.subTest(owner=owner):
                self.assertIn("AndroidDialogWindow(", dialog_source)
                self.assertIn(shared_surface, dialog_source)
                self.assertNotIn(".regularMaterial", dialog_source)

    def test_ai_disclaimer_identifies_its_real_scroll_container(self) -> None:
        """Disclaimer automation must scroll visible content without weakening modal identity."""
        ai_configuration = source(BIBLE_UI / "AI" / "AIConfigurationDialogPresentation.swift")
        adaptive_scroll = source(
            BIBLE_UI / "Shared" / "AndroidAdaptiveDialogScrollView.swift"
        )
        disclaimer = source_between(
            ai_configuration,
            "private struct AIDisclaimerDialog: View",
            "/// Android's distinct title for informational and acceptance dialogs.",
        )

        self.assertIn("AndroidAdaptiveDialogScrollView(", disclaimer)
        self.assertIn(
            'accessibilityIdentifier: "aiDisclaimerScrollView"',
            disclaimer,
        )
        self.assertIn("ScrollView {", adaptive_scroll)
        self.assertIn(
            ".accessibilityIdentifier(accessibilityIdentifier)",
            adaptive_scroll,
        )
        self.assertIn('.accessibilityIdentifier("aiDisclaimerAcceptButton")', disclaimer)
        self.assertIn('accessibilityIdentifier: "aiDisclaimerScreen"', disclaimer)
        self.assertIn(".androidAccessibilityIdentityMarker(", disclaimer)

    def test_app_root_reuses_the_canonical_android_decision_dialog(self) -> None:
        """Lifecycle and external-import prompts must not redraw an iOS material dialog."""
        app_root = source(APP / "AndBibleApp.swift")
        shared_dialog = source(BIBLE_UI / "Shared" / "AndroidDecisionDialog.swift")

        self.assertNotIn("struct AppDecisionDialog", app_root)
        self.assertNotIn(".regularMaterial", app_root)
        self.assertNotIn("Color.black.opacity(0.36)", app_root)
        self.assertEqual(app_root.count("AndroidDecisionDialog("), 6)
        self.assertEqual(app_root.count('accessibilityIdentifier: "appDecisionDialog"'), 6)
        self.assertIn("public struct AndroidDecisionDialog: View", shared_dialog)
        self.assertIn("public struct Action: Identifiable", shared_dialog)

    def test_passage_chooser_overflow_reuses_shared_popup_components(self) -> None:
        """Passage options must use the common anchored popup and row interaction contract."""
        chooser = source(BIBLE_UI / "Navigation" / "BookChooserView.swift")
        popup = chooser[chooser.index("private struct PassageChooserOverflowMenuPopup: View"):]

        self.assertIn(".androidAnchoredPopupMenu(", chooser)
        self.assertIn("AndroidPopupMenuSurface(", popup)
        self.assertIn("AndroidPopupMenuRow(", popup)
        self.assertNotIn("Color.black.opacity", popup)
        self.assertNotIn("RoundedRectangle(", popup)

    def test_multiselect_workflows_reuse_the_shared_dialog_content(self) -> None:
        """CSV, Study Pad, and text-setting selection must share Android multiselect behavior."""
        audited_multiselects = {
            "bookmark CSV": source(BIBLE_UI / "Bookmarks" / "BookmarkCSVTransferDocument.swift"),
            "Study Pad export": source(BIBLE_UI / "Bookmarks" / "StudyPadSelectorSupport.swift"),
            "text settings copy": source(
                BIBLE_UI / "Settings" / "TextDisplaySettingsCopyDialog.swift"
            ),
        }

        for owner, dialog_source in audited_multiselects.items():
            with self.subTest(owner=owner):
                self.assertIn("AndroidDialogWindow(", dialog_source)
                self.assertIn("AndroidMultiselectDialogContent(", dialog_source)
                self.assertNotIn(".regularMaterial", dialog_source)

    def test_reader_overlays_reuse_android_resources_instead_of_ios_materials(self) -> None:
        """Fullscreen reference and toast overlays cannot drift back to local iOS blur styling."""
        reader = source(BIBLE_UI / "Bible" / "BibleReaderView.swift")
        reader_overlays = source_between(
            reader,
            "private var bibleReferenceOverlay: some View",
            "private var textSettingsCopyDialogOverlay: some View",
        )
        reference = source(BIBLE_UI / "Shared" / "AndroidBibleReferenceOverlay.swift")

        self.assertIn("AndroidBibleReferenceOverlay(reference: currentReference)", reader_overlays)
        self.assertIn("AndroidToastOverlay(message: message, bottomPadding: 80)", reader_overlays)
        self.assertNotIn("Material", reader_overlays)
        self.assertIn(".font(.system(size: 18, weight: .regular))", reference)
        self.assertIn("cornerRadius: 6", reference)
        self.assertIn(".padding(8)", reference)
        self.assertIn("0x5A", reference)
        self.assertIn("0xE4", reference)
        self.assertIn("0xDE", reference)

    def test_reader_context_controls_reuse_shared_android_surfaces_and_owner_palette(self) -> None:
        """Selection and quick-document controls cannot redraw iOS material or popup chrome."""
        pane = source(BIBLE_UI / "Bible" / "BibleWindowPane.swift")
        selector = source(BIBLE_UI / "Bible" / "BibleReaderQuickModuleSelector.swift")
        reader = source(BIBLE_UI / "Bible" / "BibleReaderView.swift")

        selection_bar = source_between(
            pane,
            "private var selectionActionBar: some View",
            "private var selectionBookmarkPopup: some View",
        )
        quick_selector_overlays = source_between(
            reader,
            "private func bibleQuickModuleSelectorOverlay",
            "private var readerNavigationDrawerOverlay",
        )

        self.assertIn("AndroidPopupMenuSurface(", selection_bar)
        self.assertIn("surfacePalette.toolbarBackgroundColor", selection_bar)
        self.assertIn("surfacePalette.toolbarForegroundColor", selection_bar)
        self.assertNotIn("Material", selection_bar)
        self.assertNotIn("RoundedRectangle(", selection_bar)

        self.assertIn("AndroidPopupMenuSurface(", selector)
        self.assertIn("AndroidPopupMenuRow(", selector)
        self.assertIn("surfacePalette.backgroundColor", selector)
        self.assertNotIn("Color(red:", selector)
        self.assertNotIn("systemBackground", selector)
        self.assertNotIn("menuBackground", selector)

        self.assertEqual(
            quick_selector_overlays.count("surfacePalette: readerThemeSurfacePalette"),
            2,
        )
        self.assertNotIn("cornerRadius: 12", quick_selector_overlays)
        self.assertNotIn("strokeBorder", quick_selector_overlays)

    def test_every_activity_popup_propagates_its_complete_owner_palette(self) -> None:
        """App-owned popup surfaces may use global colors only inside a global dialog owner."""
        required_arguments = {
            "backgroundColor:",
            "primaryTextColor:",
            "secondaryTextColor:",
            "accentColor:",
        }
        missing_arguments: dict[str, list[list[str]]] = {}

        for path in sorted(BIBLE_UI.rglob("*.swift")):
            popup_headers = re.findall(
                r"AndroidPopupMenuSurface\((.*?)\)\s*\{",
                source(path),
                flags=re.DOTALL,
            )
            for header in popup_headers:
                missing = sorted(argument for argument in required_arguments if argument not in header)
                if missing:
                    relative_path = str(path.relative_to(BIBLE_UI))
                    missing_arguments.setdefault(relative_path, []).append(missing)

        self.assertEqual(
            missing_arguments,
            {
                "MyDocuments/MyDocumentPageEditor.swift": [
                    sorted(required_arguments),
                ],
            },
        )
        dialog_editor = source(BIBLE_UI / "MyDocuments" / "MyDocumentPageEditor.swift")
        self.assertIn("AndroidDialogWindow(", dialog_editor)
        self.assertIn("AndroidDialogSurfacePalette.primaryText", dialog_editor)

    def test_activity_app_bar_keeps_identity_beside_its_actions(self) -> None:
        """App-bar identity must not replace Back, Help, overflow, or contextual action IDs."""
        file_source = source(BIBLE_UI / "Shared" / "AndroidActivityTopAppBar.swift")
        app_bar = source_between(
            file_source,
            "struct AndroidActivityTopAppBar<Actions: View>: View",
            "struct AndroidActivityTopAppBarActionButton: View",
        )

        self.assertIn(".accessibilityElement(children: .contain)", app_bar)
        self.assertIn("AndroidActivityAccessibilityMarker(", app_bar)
        self.assertIn("accessibilityIdentifier: accessibilityIdentifier", app_bar)
        self.assertNotIn(".accessibilityIdentifier(accessibilityIdentifier)", app_bar)

    def test_decision_dialog_reuses_shared_scaffold_and_text_actions(self) -> None:
        """Decision flows must not redraw AlertDialog structure or buttons feature-locally."""
        decision_dialog = source(BIBLE_UI / "Shared" / "AndroidDecisionDialog.swift")

        self.assertIn("AndroidDialogScaffold(title: title)", decision_dialog)
        self.assertIn("AndroidDialogTextAction(", decision_dialog)
        self.assertNotIn("Button(action: action.perform)", decision_dialog)

    def test_text_display_child_activities_preserve_the_safe_content_region(self) -> None:
        """Nested Colors and Hidden Labels bars must remain below iOS system chrome."""
        text_display = source(BIBLE_UI / "Settings" / "TextDisplaySettingsView.swift")
        child_activities = source_between(
            text_display,
            "private var textDisplayActivityOverlay: some View",
            "private var textDisplayResetOverlay: some View",
        )

        self.assertIn("ColorSettingsView(", child_activities)
        self.assertIn("AndroidHiddenLabelsActivityView(", child_activities)
        self.assertNotIn(".ignoresSafeArea()", child_activities)

    def test_nested_android_activities_expand_only_their_backgrounds(self) -> None:
        """Full child activities must not move app bars or controls into iOS system chrome."""
        presentation_slices = {
            "label assignment": source_between(
                source(BIBLE_UI / "Bookmarks" / "LabelAssignmentView.swift"),
                "private var presentationLayer: some View",
                "/// Loads union selection",
            ),
            "label manager": source_between(
                source(BIBLE_UI / "Bookmarks" / "LabelManagerView.swift"),
                "private var presentationLayer: some View",
                "/// Compact hidden state probe",
            ),
            "Study Pads": source_between(
                source(BIBLE_UI / "Bookmarks" / "StudyPadSelectorView.swift"),
                "private var dialogLayer: some View",
                "/// Bridges the selector's mutually exclusive popup enum",
            ),
            "hidden labels": source_between(
                source(BIBLE_UI / "Settings" / "AndroidHiddenLabelsActivityView.swift"),
                "private var presentationLayer: some View",
                "/// Seeds the retained Android list projection",
            ),
            "Speak": source_between(
                source(BIBLE_UI / "Speak" / "SpeakControlView.swift"),
                "private var destinationLayer: some View",
                "/// Reader-supplied module books",
            ),
        }

        for owner, presentation in presentation_slices.items():
            with self.subTest(owner=owner):
                self.assertNotIn(".ignoresSafeArea()", presentation)
                self.assertNotIn(".ignoresSafeArea(edges:", presentation)

        self.assertIn("AndroidLabelEditorView(", presentation_slices["label assignment"])
        self.assertIn("AndroidLabelEditorView(", presentation_slices["label manager"])
        self.assertIn("AndroidLabelEditorView(", presentation_slices["Study Pads"])
        self.assertIn("AndroidLabelEditorView(", presentation_slices["hidden labels"])
        self.assertIn("SpeakVerseRangeEditor(", presentation_slices["Speak"])

    def test_reader_destination_router_does_not_wrap_complete_activities_in_identifiers(self) -> None:
        """Reader routing may export sibling markers but cannot identify composite destinations."""
        reader = source(BIBLE_UI / "Bible" / "BibleReaderView.swift")
        destination_router = source_between(
            reader,
            "private func readerDestinationContent(_ destination: ReaderDestination)",
            "private func documentChooserDestinationContent(",
        )

        self.assertIn("AndroidActivityAccessibilityMarker(", destination_router)
        self.assertNotIn(".accessibilityIdentifier(\"", destination_router)

    def test_app_owned_workflow_routes_export_sibling_identity_markers(self) -> None:
        """Route identity must never replace the real controls inside audited app activities."""
        audited_routes = {
            "label assignment": (
                BIBLE_UI / "Bookmarks" / "LabelAssignmentView.swift",
                "labelAssignmentScreen",
            ),
            "label manager": (
                BIBLE_UI / "Bookmarks" / "LabelManagerView.swift",
                "labelManagerScreen",
            ),
            "Study Pads": (
                BIBLE_UI / "Bookmarks" / "StudyPadSelectorView.swift",
                "studyPadSelectorScreen",
            ),
            "label editor": (
                BIBLE_UI / "Bookmarks" / "AndroidLabelEditorView.swift",
                "labelEditScreen",
            ),
            "hidden labels": (
                BIBLE_UI / "Settings" / "AndroidHiddenLabelsActivityView.swift",
                "textDisplayHiddenBookmarkLabelsScreen",
            ),
            "My Documents": (
                BIBLE_UI / "MyDocuments" / "AndroidMyDocumentsActivityView.swift",
                "myDocumentsListScreen",
            ),
            "My Document pages": (
                BIBLE_UI / "MyDocuments" / "AndroidMyDocumentPagesActivityView.swift",
                "myDocumentPagesScreen",
            ),
            "Backup and Restore": (
                BIBLE_UI / "Settings" / "AndroidBackupRestoreActivityView.swift",
                "importExportScreen",
            ),
            "progress settings": (
                BIBLE_UI / "Bible" / "AndroidReadingProgressSettingsView.swift",
                "readingProgressSettingsScreen",
            ),
            "available reading plans": (
                BIBLE_UI / "ReadingPlans" / "AndroidReadingPlanSelectorView.swift",
                "availablePlansScreen",
            ),
            "reading-plan day selector": (
                BIBLE_UI / "ReadingPlans" / "AndroidDailyReadingActivityView.swift",
                "dailyReadingDaySelectorScreen",
            ),
            "History rows": (
                BIBLE_UI / "Shared" / "HistoryView.swift",
                "historyScreen",
            ),
        }

        for owner, (path, identifier) in audited_routes.items():
            with self.subTest(owner=owner):
                route_source = source(path)
                self.assertIn("AndroidActivityAccessibilityMarker(", route_source)
                self.assertIn(f'accessibilityIdentifier: "{identifier}"', route_source)
                self.assertNotIn(f'.accessibilityIdentifier("{identifier}")', route_source)

    def test_label_assignment_exposes_shared_controls_beside_its_route_marker(self) -> None:
        """Assignment automation must exercise shared Manage Labels controls, not legacy facades."""
        assignment = source(BIBLE_UI / "Bookmarks" / "LabelAssignmentView.swift")
        assignment_body = source_between(
            assignment,
            "var body: some View",
            "/// Route identity reloads only",
        )
        shared_rows = source(BIBLE_UI / "Bookmarks" / "AndroidManageLabelsComponents.swift")
        ui_test = source(
            REPO_ROOT
            / "Tests"
            / "UI"
            / "AndBibleUITests"
            / "AndBibleUITests+BookmarksHistory.swift"
        )
        element_support = source(
            REPO_ROOT
            / "Tests"
            / "UI"
            / "AndBibleUITests"
            / "AndBibleUITestElementSupport.swift"
        )
        state_support = source(
            REPO_ROOT
            / "Tests"
            / "UI"
            / "AndBibleUITests"
            / "AndBibleUITestStateSupport.swift"
        )

        self.assertIn("AndroidActivityAccessibilityMarker(", assignment_body)
        self.assertIn('accessibilityIdentifier: "labelAssignmentScreen"', assignment_body)
        self.assertNotIn('.accessibilityIdentifier("labelAssignmentScreen")', assignment_body)
        self.assertIn('"manageLabelsAssignment::\\(label.id.uuidString)"', shared_rows)
        self.assertIn('"manageLabelsAssignment::"', ui_test)
        self.assertNotIn('"labelAssignmentRow::', ui_test)
        self.assertNotIn('identifier.hasPrefix("labelAssignmentRow::")', element_support)
        self.assertIn('"labelAssignmentAppBarBackButton"', state_support)
        self.assertNotIn('"labelAssignmentDoneButton"', state_support)
        self.assertNotIn('"labelAssignmentDoneButton"', element_support)

    def test_bookmark_rows_reuse_release_aware_android_click_owner(self) -> None:
        """Bookmark click and long-click must stay real, mutually exclusive app interactions."""
        interaction = source(BIBLE_UI / "Shared" / "AndroidTapLongPressButton.swift")
        bookmark_list = source(BIBLE_UI / "Bookmarks" / "BookmarkListView.swift")
        bookmark_row = source_between(
            bookmark_list,
            "private struct BookmarkRow: View",
            "/// Assigned labels rendered as Android's generic tag glyphs",
        )
        bookmark_navigation = source_between(
            bookmark_list,
            "private func navigate(to bookmark: BookmarkListItem)",
            "Converts bookmark ordinals into a human-readable verse reference string.",
        )

        self.assertIn("Button(action: activateTap)", interaction)
        self.assertIn(".simultaneousGesture(", interaction)
        self.assertIn(".onEnded { _ in recognizeLongPress() }", interaction)
        self.assertIn(".onDisappear(perform: resetRecognition)", interaction)
        self.assertIn(".onChange(of: isLongPressActionActive)", interaction)
        self.assertIn("guard !didRecognizeLongPress else {", interaction)
        self.assertIn("didRecognizeLongPress = false\n            return", interaction)
        self.assertIn("AndroidTapLongPressButton(", bookmark_row)
        self.assertIn("isLongPressActionActive: isSelected", bookmark_row)
        self.assertNotIn(".highPriorityGesture(", bookmark_row)
        self.assertNotIn(".accessibilityElement(children: .combine)", bookmark_row)
        self.assertIn("closeBookmarkList()", bookmark_navigation)
        self.assertNotIn("dismiss()", bookmark_navigation)

    def test_document_filter_identifiers_resolve_their_real_button_type(self) -> None:
        """Chooser parity tests must query shared language/type triggers as buttons."""
        filter_source = source(BIBLE_UI / "Shared" / "AndroidDocumentSelectionControls.swift")
        test_support = source(
            REPO_ROOT
            / "Tests"
            / "UI"
            / "AndBibleUITests"
            / "AndBibleUITestElementSupport.swift"
        )

        self.assertIn('accessibilityIdentifier("\\(accessibilityPrefix)LanguageFilter")', filter_source)
        self.assertIn('accessibilityIdentifier("\\(accessibilityPrefix)CategoryFilter")', filter_source)
        self.assertIn('if identifier.hasSuffix("Filter")', test_support)
        filter_branch = source_between(
            test_support,
            'if identifier.hasSuffix("Filter")',
            'if identifier.hasSuffix("Menu")',
        )
        self.assertIn("app.buttons[identifier].firstMatch", filter_branch)


if __name__ == "__main__":
    unittest.main()
