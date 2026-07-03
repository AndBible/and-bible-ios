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
    run_blocks = workflow_step_run_blocks(workflow_text, step_name)
    if len(run_blocks) != 1:
        raise AssertionError(
            f"Expected exactly one run block for workflow step {step_name!r}, found {len(run_blocks)}."
        )

    return run_blocks[0]


def workflow_step_run_blocks(workflow_text: str, step_name: str) -> list[str]:
    """Return run blocks for every GitHub Actions step with the requested name."""
    lines = workflow_text.splitlines()
    step_pattern = re.compile(rf"^(\s*)-\s+name:\s+{re.escape(step_name)}\s*$")
    run_blocks: list[str] = []

    for index, line in enumerate(lines):
        step_match = step_pattern.match(line)
        if step_match is None:
            continue

        step_run_block: str | None = None
        step_indent = len(step_match.group(1))
        step_boundary = re.compile(rf"^ {{{step_indent}}}-\s+")
        for step_line_index in range(index + 1, len(lines)):
            step_line = lines[step_line_index]
            if step_boundary.match(step_line):
                break

            run_match = re.match(r"^(\s*)run:\s*(.*)$", step_line)
            if run_match is None:
                continue

            run_indent = len(run_match.group(1))
            inline_run = run_match.group(2).strip()
            if inline_run not in {"|", "|-", ">", ">-"}:
                step_run_block = inline_run
                break

            run_lines: list[str] = []
            for run_line in lines[step_line_index + 1 :]:
                if run_line.strip() and len(run_line) - len(run_line.lstrip(" ")) <= run_indent:
                    break
                run_lines.append(run_line[run_indent + 2 :])
            step_run_block = "\n".join(run_lines)
            break

        if step_run_block is None:
            raise AssertionError(f"Unable to find run block for workflow step {step_name!r}.")
        run_blocks.append(step_run_block)

    if not run_blocks:
        raise AssertionError(f"Unable to find workflow step {step_name!r}.")

    return run_blocks


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


def upload_step_scalar(step_text: str, key: str) -> str:
    """Returns one scalar `with:` value from an upload-artifact step."""
    match = re.search(rf"^\s+{re.escape(key)}:\s+(.+?)\s*$", step_text, re.MULTILINE)
    if match is None:
        raise AssertionError(f"Expected upload-artifact step to declare {key!r}.\n{step_text}")
    return match.group(1)


def step_offsets(workflow_text: str, step_name: str) -> list[int]:
    """Return source offsets for every workflow step with the requested name."""
    pattern = re.compile(rf"^\s*-\s+name:\s+{re.escape(step_name)}\s*$", re.MULTILINE)
    return [match.start() for match in pattern.finditer(workflow_text)]


def workflow_job_block(workflow_text: str, job_name: str) -> str:
    """Return one top-level GitHub Actions job block by job id."""
    match = re.search(
        rf"^  {re.escape(job_name)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:|\Z)",
        workflow_text,
        re.MULTILINE | re.DOTALL,
    )
    if match is None:
        raise AssertionError(f"Unable to find workflow job {job_name!r}.")
    return match.group("body")


class IOSCIUIShardGuardrailsTests(unittest.TestCase):
    """Checks the workflow-level guardrail around dynamic UI shard counts."""

    def test_ios_ci_upload_artifact_retention_matches_artifact_type(self) -> None:
        """Keep build products short-lived while retaining diagnostic result bundles."""
        workflow_text = (REPO_ROOT / ".github/workflows/ios-ci.yml").read_text(encoding="utf-8")

        upload_steps = upload_artifact_steps(workflow_text)
        for line_number, step_text in upload_steps:
            path = upload_step_scalar(step_text, "path")
            retention_days = int(upload_step_scalar(step_text, "retention-days"))
            expected_retention_days = 14 if ".xcresult" in path else 1
            self.assertEqual(
                expected_retention_days,
                retention_days,
                f"Unexpected upload-artifact retention near line {line_number} for path {path!r}.",
            )

        self.assertGreater(len(upload_steps), 0, "Expected the workflow to contain upload-artifact steps.")

    def test_ios_ci_clones_android_reference_before_parity_guardrails(self) -> None:
        """Ensures parity jobs have a live Android checkout before guardrails run.

        The workflow-level contract is that both bridge and localization parity
        checks use the shared checkout helper and ANDBIBLE_ANDROID_ROOT. A
        failure means CI can regress to snapshot-only or inventory-only checks.
        """
        workflow_text = (REPO_ROOT / ".github/workflows/ios-ci.yml").read_text(encoding="utf-8")
        checkout_offsets = step_offsets(workflow_text, "Checkout Android reference")
        bridge_check_offsets = step_offsets(workflow_text, "Check bridge parity inventory")
        localization_check_offsets = step_offsets(workflow_text, "Run SETPAR-603 guardrails")

        self.assertTrue(
            (REPO_ROOT / "scripts/ensure_android_reference_checkout.sh").exists(),
            "Expected a reusable Android reference checkout script.",
        )
        self.assertRegex(
            workflow_text,
            re.compile(r"^\s+ANDBIBLE_ANDROID_ROOT:\s+['\"]?\.\./and-bible['\"]?\s*$", re.MULTILINE),
        )
        self.assertEqual(2, len(checkout_offsets))
        self.assertEqual(1, len(bridge_check_offsets))
        self.assertEqual(1, len(localization_check_offsets))
        self.assertLess(checkout_offsets[0], bridge_check_offsets[0])
        self.assertLess(checkout_offsets[1], localization_check_offsets[0])
        self.assertEqual(
            [
                "scripts/ensure_android_reference_checkout.sh",
                "scripts/ensure_android_reference_checkout.sh",
            ],
            workflow_step_run_blocks(workflow_text, "Checkout Android reference"),
        )

    def test_unit_test_aggregate_gate_does_not_fail_cancelled_runs(self) -> None:
        """Keep canceled superseded workflow runs from publishing red aggregate checks."""
        workflow_text = (REPO_ROOT / ".github/workflows/ios-ci.yml").read_text(encoding="utf-8")
        unit_job = workflow_job_block(workflow_text, "ios-simulator-unit-tests")
        verify_gate = workflow_step_run_block(workflow_text, "Verify package-test gate results")

        self.assertIn("name: Unit Tests (Simulator)", unit_job)
        self.assertRegex(unit_job, re.compile(r"^\s+if:\s+\$\{\{\s*!cancelled\(\)\s*\}\}\s*$", re.MULTILINE))
        self.assertNotRegex(unit_job, re.compile(r"^\s+if:\s+\$\{\{\s*always\(\)\s*\}\}\s*$", re.MULTILINE))
        self.assertIn("needs.ios-swordkit-package-tests.result", verify_gate)
        self.assertIn("needs.ios-biblecore-package-tests.result", verify_gate)
        self.assertIn("needs.ios-bibleview-package-tests.result", verify_gate)
        self.assertIn("needs.ios-bibleui-package-tests.result", verify_gate)

    def test_upload_artifact_retention_guardrail_handles_name_less_steps(self) -> None:
        """Ensure the retention guardrail classifies valid `- uses:` upload steps."""
        workflow_text = """
name: demo
jobs:
  demo:
    steps:
      - uses: actions/upload-artifact@v6
        with:
          name: result
          path: .artifacts/*.xcresult
          retention-days: 14
      - uses: actions/upload-artifact@v6
        with:
          name: build-product
          path: build-products.tar.gz
          retention-days: 1
      - name: Later step
        run: true
"""

        upload_steps = upload_artifact_steps(workflow_text)

        self.assertEqual(2, len(upload_steps))
        self.assertEqual(".artifacts/*.xcresult", upload_step_scalar(upload_steps[0][1], "path"))
        self.assertEqual("14", upload_step_scalar(upload_steps[0][1], "retention-days"))
        self.assertEqual("build-products.tar.gz", upload_step_scalar(upload_steps[1][1], "path"))
        self.assertEqual("1", upload_step_scalar(upload_steps[1][1], "retention-days"))

    def test_workflow_step_run_blocks_reports_every_duplicate_step_name(self) -> None:
        """Locks duplicate step-name checks to every occurrence, not the first.

        The Android checkout guardrail uses the same step name in two jobs. A
        failure means a later job can drift while tests keep inspecting only the
        first duplicate step.
        """
        workflow_text = """
name: demo
jobs:
  first:
    steps:
      - name: Checkout Android reference
        run: scripts/ensure_android_reference_checkout.sh
  second:
    steps:
      - name: Checkout Android reference
        run: scripts/not-the-helper.sh
"""

        self.assertEqual(
            [
                "scripts/ensure_android_reference_checkout.sh",
                "scripts/not-the-helper.sh",
            ],
            workflow_step_run_blocks(workflow_text, "Checkout Android reference"),
        )

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

    def test_ios_ci_does_not_include_retired_build_product_reuse_experiment(self) -> None:
        """Keep the retired UI build-product reuse experiment out of the active workflow."""
        workflow_text = (REPO_ROOT / ".github/workflows/ios-ci.yml").read_text(encoding="utf-8")

        self.assertNotIn("run_ui_build_product_reuse_experiment", workflow_text)
        self.assertNotIn("ci:ui-build-reuse", workflow_text)
        self.assertNotIn("ios-ui-build-product-reuse-producer", workflow_text)
        self.assertNotIn("ios-ui-build-product-reuse-consumer", workflow_text)
        self.assertNotIn("andbible-ui-build-products", workflow_text)


if __name__ == "__main__":
    unittest.main()
