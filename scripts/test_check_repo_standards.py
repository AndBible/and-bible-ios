#!/usr/bin/env python3
"""
Unit tests for incremental repo standards guardrails.
"""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_repo_standards import find_multiline_slash_docblocks, validate_commit_message


class RepoStandardsTests(unittest.TestCase):
    """Covers the locked commit message shape and incremental Swift docblock style checks."""

    def test_valid_commit_message_passes(self) -> None:
        message = "\n".join(
            [
                "docs(sync): document operator workflow",
                "",
                "Why:",
                "- Operators need a stable reference.",
                "",
                "What Changed:",
                "- Added the sync workflow doc.",
                "",
                "Validation:",
                "- Reviewed the existing flow against the app code.",
                "",
                "Impact:",
                "- Reduces operator ambiguity.",
            ]
        )
        self.assertEqual(validate_commit_message("abc123", message), [])

    def test_commit_message_requires_blank_line_and_sections(self) -> None:
        message = "\n".join(
            [
                "docs(sync): document operator workflow",
                "Why:",
                "- Missing blank line.",
            ]
        )
        issues = validate_commit_message("abc123", message)
        messages = [issue.message for issue in issues]
        self.assertIn("subject must be followed by one blank line", messages)
        self.assertIn("missing required section What Changed:", messages)
        self.assertIn("missing required section Validation:", messages)
        self.assertIn("missing required section Impact:", messages)

    def test_commit_message_rejects_invalid_subject(self) -> None:
        message = "\n".join(
            [
                "update sync docs",
                "",
                "Why:",
                "none",
                "",
                "What Changed:",
                "none",
                "",
                "Validation:",
                "none",
                "",
                "Impact:",
                "none",
            ]
        )
        issues = validate_commit_message("abc123", message)
        self.assertTrue(any("subject must match" in issue.message for issue in issues))

    def test_commit_message_rejects_forbidden_coauthor_trailer(self) -> None:
        message = "\n".join(
            [
                "docs(sync): document operator workflow",
                "",
                "Why:",
                "none",
                "",
                "What Changed:",
                "none",
                "",
                "Validation:",
                "none",
                "",
                "Impact:",
                "none",
                "",
                "Co-authored-by: Example <example@example.com>",
            ]
        )
        issues = validate_commit_message("abc123", message)
        self.assertTrue(any("Co-authored-by" in issue.message for issue in issues))

    def test_find_multiline_slash_docblocks_flags_consecutive_lines(self) -> None:
        text = "\n".join(
            [
                "/// First line",
                "/// Second line",
                "func example() {}",
            ]
        )
        self.assertEqual(find_multiline_slash_docblocks(text), [1])

    def test_find_multiline_slash_docblocks_allows_single_line_comment(self) -> None:
        text = "\n".join(
            [
                "/// Single line",
                "func example() {}",
            ]
        )
        self.assertEqual(find_multiline_slash_docblocks(text), [])

    def test_find_multiline_slash_docblocks_reports_multiple_blocks(self) -> None:
        text = "\n".join(
            [
                "/// One",
                "/// Two",
                "func first() {}",
                "",
                "/// Three",
                "/// Four",
                "/// Five",
                "func second() {}",
            ]
        )
        self.assertEqual(find_multiline_slash_docblocks(text), [1, 5])


if __name__ == "__main__":
    unittest.main()
