"""Guardrails for bookmark, label, and StudyPad Android presentation parity."""

from __future__ import annotations

from pathlib import Path
import unittest

REPO_ROOT = Path(__file__).resolve().parents[1]


class BookmarkLabelStudyPadParityGuardrailsTests(unittest.TestCase):
    """Protects Android-owned bookmark, label, and StudyPad presentation routes."""

    def test_bookmark_list_label_routes_are_navigation_destinations(self) -> None:
        """Bookmark label management should stay in the app stack, not nested iOS sheets."""
        source = (
            REPO_ROOT / "Sources/BibleUI/Sources/BibleUI/Bookmarks/BookmarkListView.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("BookmarkListRoute", source)
        self.assertIn("activeBookmarkListRoute", source)
        self.assertIn(".navigationDestination(item: $activeBookmarkListRoute)", source)
        self.assertIn(".labelManager", source)
        self.assertIn(".labelAssignment", source)
        self.assertNotIn(".sheet(isPresented: $showLabelManager)", source)
        self.assertNotIn(".sheet(item: $editingLabelsBookmarkId)", source)

    def test_reader_webview_label_assignment_uses_reader_activity_destination(self) -> None:
        """WebView assign-label requests should route like Android ManageLabels, not overlays."""
        reader_source = (
            REPO_ROOT / "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        ).read_text(encoding="utf-8")
        pane_source = (
            REPO_ROOT / "Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("ReaderLabelAssignmentRoute", reader_source)
        self.assertIn("activeReaderLabelAssignmentRoute", reader_source)
        self.assertIn(
            ".navigationDestination(item: $activeReaderLabelAssignmentRoute)",
            reader_source,
        )
        self.assertNotIn(".fullScreenCover(item: $activeReaderLabelAssignmentRoute)", reader_source)
        self.assertNotIn(".sheet(item: $activeReaderLabelAssignmentRoute)", reader_source)
        self.assertNotIn("if let route = activeReaderLabelAssignmentRoute", reader_source)
        self.assertIn("refreshBookmarkInVueJS", reader_source)
        self.assertIn("onAssignLabels", pane_source)
        self.assertNotIn("pendingLabelBookmarkId", pane_source)
        self.assertNotIn("activeReaderLabelAssignmentRoute", pane_source)
        self.assertNotIn(".sheet(item: $pendingLabelBookmarkId)", pane_source)
        self.assertNotIn("LabelAssignmentView(", pane_source)

    def test_new_labels_open_androids_full_label_editor_activity(self) -> None:
        """ManageLabels creation must open LabelEditActivity parity, not a name-only prompt."""
        assignment_source = (
            REPO_ROOT / "Sources/BibleUI/Sources/BibleUI/Bookmarks/LabelAssignmentView.swift"
        ).read_text(encoding="utf-8")
        manager_source = (
            REPO_ROOT / "Sources/BibleUI/Sources/BibleUI/Bookmarks/LabelManagerView.swift"
        ).read_text(encoding="utf-8")
        editor_source = (
            REPO_ROOT / "Sources/BibleUI/Sources/BibleUI/Bookmarks/AndroidLabelEditorView.swift"
        ).read_text(encoding="utf-8")

        self.assertNotIn(".alert(", assignment_source)
        self.assertNotIn(".alert(", manager_source)
        self.assertIn("AndroidLabelEditorView(", assignment_source)
        self.assertIn("draft: newLabelDraft", assignment_source)
        self.assertIn("AndroidLabelEditorView(", manager_source)
        self.assertIn("draft: newLabelDraft", manager_source)
        self.assertIn("newLabelDraft = AndroidLabelEditorDraft", assignment_source)
        self.assertIn("newLabelDraft = AndroidLabelEditorDraft", manager_source)
        self.assertNotIn("AndroidLabelNameDialog", assignment_source)
        self.assertNotIn("AndroidLabelNameDialog", manager_source)
        self.assertIn("Canonical app-owned equivalent of Android `LabelEditActivity`", editor_source)
        self.assertIn("AndroidActivityAccessibilityMarker(", editor_source)
        self.assertIn('accessibilityIdentifier: "labelEditScreen"', editor_source)
        self.assertNotIn('.accessibilityIdentifier("labelEditScreen")', editor_source)
        self.assertIn("AndroidActivityScreen(", editor_source)

    def test_manage_labels_modes_share_one_android_activity_shell(self) -> None:
        """All Android ManageLabels modes must inherit one app bar, search strip, and surface."""
        shared_source = (
            REPO_ROOT
            / "Sources/BibleUI/Sources/BibleUI/Bookmarks/AndroidManageLabelsComponents.swift"
        ).read_text(encoding="utf-8")
        mode_paths = [
            "Sources/BibleUI/Sources/BibleUI/Bookmarks/LabelAssignmentView.swift",
            "Sources/BibleUI/Sources/BibleUI/Bookmarks/LabelManagerView.swift",
            "Sources/BibleUI/Sources/BibleUI/Bookmarks/StudyPadSelectorView.swift",
            "Sources/BibleUI/Sources/BibleUI/Settings/AndroidHiddenLabelsActivityView.swift",
        ]

        self.assertIn("struct AndroidManageLabelsActivityScreen", shared_source)
        self.assertIn("AndroidActivityScreen(", shared_source)
        self.assertIn("AndroidManageLabelsSearchBar(", shared_source)
        for relative_path in mode_paths:
            with self.subTest(relative_path=relative_path):
                source = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
                self.assertIn("AndroidManageLabelsActivityScreen(", source)
                self.assertNotIn("AndroidManageLabelsSearchBar(", source)

    def test_unused_native_studypad_sheet_route_is_removed(self) -> None:
        """StudyPad add/edit must stay in the WebView document route, not the old native sheet."""
        self.assertFalse(
            (REPO_ROOT / "Sources/BibleUI/Sources/BibleUI/Bookmarks/StudyPadView.swift").exists()
        )


if __name__ == "__main__":
    unittest.main()
