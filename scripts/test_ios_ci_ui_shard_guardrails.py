"""Workflow guardrails for UI test shard planning.

These tests cover the CI contract that limits planner expansion. The workflow
must keep the cap visible as an environment setting and pass it to
build_ui_test_shards.py so stale timing data cannot silently multiply macOS
runner setup cost.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys
import unittest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from build_ui_test_shards import discover_ui_test_identifiers_from_files
from run_xcodebuild_with_test_selection import requested_test_identifiers


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


def upload_artifact_steps(workflow_text: str) -> list[tuple[str, str, dict]]:
    """Return parsed upload-artifact inputs with their owning job and diagnostic step name."""
    workflow = yaml.safe_load(workflow_text)
    jobs = workflow.get("jobs")
    if not isinstance(jobs, dict):
        raise AssertionError("Expected the workflow to define a jobs mapping.")

    uploads: list[tuple[str, str, dict]] = []
    for job_name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        steps = job.get("steps", [])
        if not isinstance(steps, list):
            raise AssertionError(f"Expected workflow job {job_name!r} to define a steps list.")
        for step in steps:
            if not isinstance(step, dict):
                continue
            uses = step.get("uses")
            if not isinstance(uses, str) or uses.split("@", 1)[0] != "actions/upload-artifact":
                continue
            inputs = step.get("with")
            if not isinstance(inputs, dict):
                raise AssertionError(
                    f"Expected upload step in job {job_name!r} to define with inputs."
                )
            step_name = str(step.get("name", uses))
            uploads.append((str(job_name), step_name, inputs))
    return uploads


def upload_artifact_paths(inputs: dict) -> list[str]:
    """Return individual artifact paths using GitHub Actions multiline-input semantics."""
    path_value = inputs.get("path")
    if not isinstance(path_value, str):
        raise AssertionError("Expected upload-artifact inputs to declare a string path.")
    paths = [line.strip() for line in path_value.splitlines() if line.strip()]
    if not paths:
        raise AssertionError("Expected upload-artifact path to contain at least one entry.")
    return paths


def expected_upload_retention_days(paths: list[str]) -> int:
    """Retain uploads containing result bundles for diagnosis; keep other artifacts short-lived."""
    return 14 if any(".xcresult" in path for path in paths) else 1


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
        for job_name, step_name, inputs in upload_steps:
            paths = upload_artifact_paths(inputs)
            retention_days = int(inputs["retention-days"])
            expected_retention_days = expected_upload_retention_days(paths)
            self.assertEqual(
                expected_retention_days,
                retention_days,
                f"Unexpected retention for upload {step_name!r} in job {job_name!r}: {paths!r}.",
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

    def test_upload_artifact_retention_guardrail_handles_multiline_and_name_less_steps(self) -> None:
        """Classify parsed path entries without depending on optional names or YAML scalar style."""
        workflow_text = """
name: demo
jobs:
  demo:
    steps:
      - name: Upload result diagnostics
        uses: actions/upload-artifact@0123456789abcdef0123456789abcdef01234567
        with:
          name: result
          path: |
            .artifacts/*.xcresult
            .artifacts/reader-gestures.log
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
        self.assertEqual(("demo", "Upload result diagnostics"), upload_steps[0][:2])
        self.assertEqual(("demo", "actions/upload-artifact@v6"), upload_steps[1][:2])
        self.assertEqual(
            [".artifacts/*.xcresult", ".artifacts/reader-gestures.log"],
            upload_artifact_paths(upload_steps[0][2]),
        )
        self.assertEqual(
            14,
            expected_upload_retention_days(upload_artifact_paths(upload_steps[0][2])),
        )
        self.assertEqual(["build-products.tar.gz"], upload_artifact_paths(upload_steps[1][2]))
        self.assertEqual(
            1,
            expected_upload_retention_days(upload_artifact_paths(upload_steps[1][2])),
        )

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

    def test_ios_ci_classification_executes_the_behavioral_classifier(self) -> None:
        workflow_text = (REPO_ROOT / ".github/workflows/ios-ci.yml").read_text(encoding="utf-8")
        classify_run = workflow_step_run_block(workflow_text, "Classify change set")

        self.assertIn("python3 scripts/classify_ci_changes.py", classify_run)
        self.assertIn('--github-output "${GITHUB_OUTPUT}"', classify_run)

    def test_ios_ci_app_host_selection_covers_every_source_discovered_method(self) -> None:
        """Require product-reused target-wide selection to cover the genuine app-host remainder."""
        workflow_text = (REPO_ROOT / ".github/workflows/ios-ci.yml").read_text(encoding="utf-8")
        unit_job = workflow_job_block(workflow_text, "ios-simulator-unit-tests")
        verify_block = workflow_step_run_block(
            unit_job,
            "Verify reusable products for app-host execution",
        )
        run_block = workflow_step_run_block(
            unit_job,
            "Run all discovered app-host tests without rebuilding",
        )
        discovered = discover_ui_test_identifiers_from_files(
            sorted((REPO_ROOT / "Tests/AppHost/AndBibleTests").glob("AndBibleTests*.swift")),
            test_target="AndBibleTests",
            test_case_class="AndBibleTests",
        )

        self.assertTrue(discovered)
        self.assertEqual(
            requested_test_identifiers("-only-testing:AndBibleTests", discovered),
            sorted(discovered),
        )
        self.assertIn("--test-source Tests/AppHost/AndBibleTests/AndBibleTests*.swift", run_block)
        self.assertIn("--test-target AndBibleTests", run_block)
        self.assertIn("--test-case-class AndBibleTests", run_block)
        self.assertIn("ios-ui-foundation", unit_job)
        self.assertIn("andbible-ui-test-products-${{ github.run_id }}", unit_job)
        self.assertIn("manage_ui_test_products.py verify", verify_block)
        self.assertIn("--xctestrun-path", run_block)
        self.assertIn("--action test-without-building", run_block)
        self.assertNotIn("--action build-for-testing", unit_job)
        self.assertNotIn("swift build", unit_job)
        self.assertNotIn("libsword.xcframework", unit_job)
        self.assertNotIn("--project", run_block)
        self.assertNotIn("--scheme", run_block)

    def test_ui_shards_consume_one_validated_build_without_rebuilding(self) -> None:
        """Keep compilation in the producer and execution in every matrix consumer."""
        workflow_text = (REPO_ROOT / ".github/workflows/ios-ci.yml").read_text(encoding="utf-8")
        producer = workflow_job_block(workflow_text, "ios-ui-foundation")
        consumer = workflow_job_block(workflow_text, "ios-simulator-ui-tests")
        producer_build = workflow_step_run_block(producer, "Build UI tests once")
        producer_package = workflow_step_run_block(producer, "Package validated UI test products")
        consumer_verify = workflow_step_run_block(consumer, "Verify reusable UI test products")
        consumer_run = workflow_step_run_block(
            consumer,
            "Run selected simulator tests without rebuilding",
        )

        self.assertEqual(1, producer.count("--action build-for-testing"))
        self.assertIn("--action build-for-testing", producer_build)
        self.assertIn("manage_ui_test_products.py package", producer_package)
        self.assertIn("andbible-ui-test-products-${{ github.run_id }}", producer)
        self.assertIn("ios-ui-foundation", consumer)
        self.assertIn("manage_ui_test_products.py verify", consumer_verify)
        self.assertIn('--expected-commit-sha "${GITHUB_SHA}"', consumer_verify)
        self.assertIn("--xctestrun-path", consumer_run)
        self.assertIn("--action test-without-building", consumer_run)
        self.assertNotIn("--action build-for-testing", consumer)
        self.assertNotIn("swift build", consumer)
        self.assertNotIn("--project", consumer_run)
        self.assertNotIn("--scheme", consumer_run)


if __name__ == "__main__":
    unittest.main()
