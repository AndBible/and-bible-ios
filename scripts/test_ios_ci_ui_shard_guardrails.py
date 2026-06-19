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

REPO_ROOT = Path(__file__).resolve().parents[1]


def workflow_step_run_block(workflow_text: str, step_name: str) -> str:
    """Return the run block for one named GitHub Actions step."""
    lines = workflow_text.splitlines()
    step_pattern = re.compile(rf"^(\s*)-\s+name:\s+{re.escape(step_name)}\s*$")

    for index, line in enumerate(lines):
        step_match = step_pattern.match(line)
        if step_match is None:
            continue

        step_indent = len(step_match.group(1))
        for step_line_index in range(index + 1, len(lines)):
            step_line = lines[step_line_index]
            if step_line.startswith(" " * step_indent + "- name:"):
                break

            run_match = re.match(r"^(\s*)run:\s*(.*)$", step_line)
            if run_match is None:
                continue

            run_indent = len(run_match.group(1))
            inline_run = run_match.group(2).strip()
            if inline_run not in {"|", "|-", ">", ">-"}:
                return inline_run

            run_lines: list[str] = []
            for run_line in lines[step_line_index + 1 :]:
                if run_line.strip() and len(run_line) - len(run_line.lstrip(" ")) <= run_indent:
                    break
                run_lines.append(run_line[run_indent + 2 :])
            return "\n".join(run_lines)

    raise AssertionError(f"Unable to find run block for workflow step {step_name!r}.")


class IOSCIUIShardGuardrailsTests(unittest.TestCase):
    """Checks the workflow-level guardrail around dynamic UI shard counts."""

    def test_ios_ci_passes_max_shard_count_to_ui_shard_planner(self) -> None:
        workflow_text = (REPO_ROOT / ".github/workflows/ios-ci.yml").read_text(encoding="utf-8")
        shard_plan_run = workflow_step_run_block(workflow_text, "Generate UI shard matrix")

        self.assertRegex(
            workflow_text,
            re.compile(r"^\s+UI_TEST_MAX_SHARD_COUNT:\s+['\"]?4['\"]?\s*$", re.MULTILINE),
        )
        self.assertRegex(
            shard_plan_run,
            re.compile(r"--max-shard-count\s+['\"]?\$\{UI_TEST_MAX_SHARD_COUNT\}['\"]?"),
        )


if __name__ == "__main__":
    unittest.main()
