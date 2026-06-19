"""Workflow guardrails for UI test shard planning.

These tests cover the CI contract that limits planner expansion. The workflow
must keep the cap visible as an environment setting and pass it to
build_ui_test_shards.py so stale timing data cannot silently multiply macOS
runner setup cost.
"""

from __future__ import annotations

from pathlib import Path
import re
import unittest


class IOSCIUIShardGuardrailsTests(unittest.TestCase):
    """Checks the workflow-level guardrail around dynamic UI shard counts."""

    def test_ios_ci_passes_max_shard_count_to_ui_shard_planner(self) -> None:
        workflow_text = Path(".github/workflows/ios-ci.yml").read_text()

        self.assertRegex(
            workflow_text,
            re.compile(r'^\s+UI_TEST_MAX_SHARD_COUNT:\s+"4"\s*$', re.MULTILINE),
        )
        self.assertIn('--max-shard-count "${UI_TEST_MAX_SHARD_COUNT}"', workflow_text)


if __name__ == "__main__":
    unittest.main()
