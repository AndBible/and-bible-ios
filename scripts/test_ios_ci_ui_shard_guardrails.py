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


def workflow_job_block(workflow_text: str, job_name: str) -> str:
    """Return the raw YAML block for one top-level workflow job."""
    lines = workflow_text.splitlines()
    job_pattern = re.compile(rf"^  {re.escape(job_name)}:\s*$")

    for index, line in enumerate(lines):
        if job_pattern.match(line) is None:
            continue

        job_lines = [line]
        for job_line in lines[index + 1 :]:
            if re.match(r"^  [A-Za-z0-9_-]+:\s*$", job_line):
                break
            job_lines.append(job_line)
        return "\n".join(job_lines)

    raise AssertionError(f"Unable to find workflow job {job_name!r}.")


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

    def test_ios_ci_exposes_build_product_reuse_experiment_trigger(self) -> None:
        """Protect the narrow opt-in/changed-workflow trigger for the reuse experiment."""
        workflow_text = (REPO_ROOT / ".github/workflows/ios-ci.yml").read_text(encoding="utf-8")
        repo_standards = workflow_job_block(workflow_text, "repo-standards")

        self.assertIn("run_ui_build_product_reuse_experiment:", repo_standards)
        self.assertIn("run_ui_build_product_reuse_experiment=false", repo_standards)
        self.assertIn("run_ui_build_product_reuse_experiment=true", repo_standards)
        self.assertIn(
            "run_ui_build_product_reuse_experiment=${run_ui_build_product_reuse_experiment}",
            repo_standards,
        )
        self.assertIn("ci:ui-build-reuse", workflow_text)

    def test_ios_ci_has_build_product_reuse_producer_and_consumer_jobs(self) -> None:
        """Protect the producer/consumer proof from becoming another per-shard build."""
        workflow_text = (REPO_ROOT / ".github/workflows/ios-ci.yml").read_text(encoding="utf-8")
        producer = workflow_job_block(workflow_text, "ios-ui-build-product-reuse-producer")
        consumer = workflow_job_block(workflow_text, "ios-ui-build-product-reuse-consumer")
        stage_run = workflow_step_run_block(workflow_text, "Stage reusable UI build products")
        consumer_run = workflow_step_run_block(
            workflow_text,
            "Run reused UI build products without rebuilding",
        )

        self.assertIn("needs.repo-standards.outputs.run_ui_build_product_reuse_experiment", producer)
        self.assertIn("contains(github.event.pull_request.labels.*.name, 'ci:ui-build-reuse')", producer)
        self.assertIn("andbible-ui-build-products-${{ github.run_id }}", producer)
        self.assertIn(".derivedData/Build/Products", stage_run)
        self.assertIn("*.xctestrun", stage_run)
        self.assertIn(".build/debug/UITestFixtureTool", stage_run)
        self.assertIn("tar -czf .artifacts/ui-build-product-reuse.tar.gz", stage_run)
        self.assertIn("andbible-ui-build-products-${{ github.run_id }}", consumer)
        self.assertIn("tar -xzf .artifacts/reuse-download/ui-build-product-reuse.tar.gz", consumer)
        self.assertIn(
            "-only-testing:AndBibleUITests/AndBibleUITests/testAboutScreenOpensFromReaderMenu",
            consumer,
        )
        self.assertIn("--xctestrun-path", consumer_run)
        self.assertIn("--action test-without-building", consumer_run)
        self.assertNotIn("--action build-for-testing", consumer_run)


if __name__ == "__main__":
    unittest.main()
