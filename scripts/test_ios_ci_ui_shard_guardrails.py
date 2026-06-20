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


def workflow_step_block(workflow_text: str, step_name: str) -> str:
    """Return the raw YAML block for one named GitHub Actions step."""
    lines = workflow_text.splitlines()
    step_pattern = re.compile(rf"^(\s*)-\s+name:\s+{re.escape(step_name)}\s*$")

    for index, line in enumerate(lines):
        step_match = step_pattern.match(line)
        if step_match is None:
            continue

        step_indent = len(step_match.group(1))
        step_lines = [line]
        for step_line in lines[index + 1 :]:
            if step_line.startswith(" " * step_indent + "- name:"):
                break
            step_lines.append(step_line)
        return "\n".join(step_lines)

    raise AssertionError(f"Unable to find workflow step {step_name!r}.")


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


def upload_artifact_steps(workflow_text: str) -> list[tuple[int, str]]:
    """Returns every upload-artifact workflow step with its source line number."""
    upload_step_pattern = re.compile(r"^(\s*)(-\s*)?uses:\s+actions/upload-artifact@v\d+\s*$")
    steps: list[tuple[int, str]] = []
    lines = workflow_text.splitlines()

    for index, line in enumerate(lines):
        upload_match = upload_step_pattern.match(line)
        if upload_match is None:
            continue

        uses_indent = len(upload_match.group(1))
        step_indent = uses_indent if upload_match.group(2) is not None else uses_indent - 2
        step_boundary = re.compile(rf"^ {{{step_indent}}}-\s+")
        step_lines = [line]
        for step_line in lines[index + 1 :]:
            if step_boundary.match(step_line):
                break
            step_lines.append(step_line)
        steps.append((index + 1, "\n".join(step_lines)))

    return steps


class IOSCIUIShardGuardrailsTests(unittest.TestCase):
    """Checks the workflow-level guardrail around dynamic UI shard counts."""

    def test_ios_ci_upload_artifact_steps_retention_is_one_day(self) -> None:
        """Keep CI artifacts short-lived so test bundles do not accumulate storage churn."""
        workflow_text = (REPO_ROOT / ".github/workflows/ios-ci.yml").read_text(encoding="utf-8")

        upload_steps = upload_artifact_steps(workflow_text)
        for line_number, step_text in upload_steps:
            self.assertIn(
                1,
                [
                    int(match.group(1))
                    for match in re.finditer(
                        r"^\s+retention-days:\s+(\d+)\s*$",
                        step_text,
                        re.MULTILINE,
                    )
                ],
                f"Expected upload-artifact step near line {line_number} to retain artifacts for one day.",
            )

        self.assertGreater(len(upload_steps), 0, "Expected the workflow to contain upload-artifact steps.")

    def test_upload_artifact_retention_guardrail_handles_name_less_steps(self) -> None:
        """Ensure the retention guardrail also catches valid `- uses:` upload steps."""
        workflow_text = """
name: demo
jobs:
  demo:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          name: result
          path: output.txt
          retention-days: 1
      - name: Later step
        run: true
"""

        upload_steps = upload_artifact_steps(workflow_text)

        self.assertEqual(1, len(upload_steps))
        self.assertIn("retention-days: 1", upload_steps[0][1])

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
        consumer_resolve_run = workflow_step_run_block(
            consumer,
            "Resolve iOS simulator destination",
        )
        consumer_run = workflow_step_run_block(
            consumer,
            "Run reused UI build products without rebuilding",
        )

        self.assertIn("needs.repo-standards.outputs.run_ui_build_product_reuse_experiment", producer)
        self.assertIn("contains(github.event.pull_request.labels.*.name, 'ci:ui-build-reuse')", producer)
        self.assertIn("andbible-ui-build-products-${{ github.run_id }}", producer)
        self.assertIn(".derivedData/Build/Products", stage_run)
        self.assertIn("*.xctestrun", stage_run)
        self.assertNotIn("mapfile", stage_run)
        self.assertIn(".build/debug/UITestFixtureTool", stage_run)
        self.assertIn("tar -czf .artifacts/ui-build-product-reuse.tar.gz", stage_run)
        self.assertIn("andbible-ui-build-products-${{ github.run_id }}", consumer)
        self.assertIn("tar -xzf .artifacts/reuse-download/ui-build-product-reuse.tar.gz", consumer)
        self.assertNotIn("--project", consumer_resolve_run)
        self.assertNotIn("--scheme", consumer_resolve_run)
        self.assertIn(
            "-only-testing:AndBibleUITests/AndBibleUITests/testAboutScreenOpensFromReaderMenu",
            consumer,
        )
        self.assertIn("--xctestrun-path", consumer_run)
        self.assertNotIn("mapfile", consumer_run)
        self.assertIn("--action test-without-building", consumer_run)
        self.assertNotIn("--action build-for-testing", consumer_run)

    def test_ios_ci_reuse_product_upload_retry_fails_producer_when_required_artifact_is_missing(
        self,
    ) -> None:
        """Protect required reusable-product uploads from becoming downstream artifact errors."""
        workflow_text = (REPO_ROOT / ".github/workflows/ios-ci.yml").read_text(encoding="utf-8")
        producer = workflow_job_block(workflow_text, "ios-ui-build-product-reuse-producer")
        upload_step = workflow_step_block(producer, "Upload reusable UI build products")
        retry_step = workflow_step_block(producer, "Retry upload reusable UI build products")

        self.assertIn("id: upload_reusable_ui_build_products", upload_step)
        self.assertIn("continue-on-error: true", upload_step)
        self.assertIn("andbible-ui-build-products-${{ github.run_id }}", upload_step)
        self.assertIn(
            "if: steps.upload_reusable_ui_build_products.outcome == 'failure'",
            retry_step,
        )
        self.assertIn("andbible-ui-build-products-${{ github.run_id }}", retry_step)
        self.assertNotIn("continue-on-error", retry_step)


if __name__ == "__main__":
    unittest.main()
