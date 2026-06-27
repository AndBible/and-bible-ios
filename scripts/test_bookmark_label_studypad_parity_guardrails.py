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

    def test_reader_webview_label_assignment_uses_reader_owned_full_screen_route(self) -> None:
        """WebView assign-label requests should route like Android ManageLabels, not pane sheets."""
        reader_source = (
            REPO_ROOT / "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderView.swift"
        ).read_text(encoding="utf-8")
        pane_source = (
            REPO_ROOT / "Sources/BibleUI/Sources/BibleUI/Bible/BibleWindowPane.swift"
        ).read_text(encoding="utf-8")

        self.assertIn("ReaderLabelAssignmentRoute", reader_source)
        self.assertIn("activeReaderLabelAssignmentRoute", reader_source)
        self.assertIn(".fullScreenCover(item: $activeReaderLabelAssignmentRoute)", reader_source)
        self.assertIn("refreshBookmarkInVueJS", reader_source)
        self.assertIn("onAssignLabels", pane_source)
        self.assertNotIn("pendingLabelBookmarkId", pane_source)
        self.assertNotIn(".sheet(item:", pane_source)

    def test_unused_native_studypad_sheet_route_is_removed(self) -> None:
        """StudyPad add/edit must stay in the WebView document route, not the old native sheet."""
        self.assertFalse(
            (REPO_ROOT / "Sources/BibleUI/Sources/BibleUI/Bookmarks/StudyPadView.swift").exists()
        )


if __name__ == "__main__":
    unittest.main()
