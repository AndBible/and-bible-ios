"""Behavioral tests for CI change classification."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from classify_ci_changes import main, required_checks_only


class ClassifyCIChangesTests(unittest.TestCase):
    def test_documentation_only_change_uses_required_checks_path(self) -> None:
        self.assertTrue(required_checks_only(["docs/testing.md", "README.md"]))

    def test_workflow_change_executes_build_and_test_lanes(self) -> None:
        self.assertFalse(required_checks_only([".github/workflows/ios-ci.yml"]))

    def test_empty_or_mixed_change_set_executes_build_and_test_lanes(self) -> None:
        self.assertFalse(required_checks_only([]))
        self.assertFalse(required_checks_only(["docs/testing.md", "scripts/runner.py"]))

    def test_cli_publishes_the_value_consumed_by_the_workflow(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            output_path = Path(temporary_directory) / "github-output"
            exit_code = main(
                [
                    "--github-output",
                    str(output_path),
                    ".github/workflows/ios-ci.yml",
                ]
            )

            self.assertEqual(exit_code, 0)
            self.assertEqual(output_path.read_text(), "required_checks_only=false\n")


if __name__ == "__main__":
    unittest.main()
