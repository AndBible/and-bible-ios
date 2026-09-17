#!/usr/bin/env python3
"""Source contracts for build-owned BibleView artifacts."""

from __future__ import annotations

from pathlib import Path
import re
import unittest
import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]


def workflow_job(source: str, job_name: str, next_job_name: str | None = None) -> str:
    """Extract one top-level workflow job block for focused orchestration assertions.

    The input is repository YAML text and a literal job key. Extraction is read-only and stable for
    the workflow's two-space job indentation. Missing or duplicate starts fail the calling test via
    ``AssertionError`` instead of returning a misleading empty block.
    """
    start_matches = list(re.finditer(rf"^  {re.escape(job_name)}:\s*$", source, re.MULTILINE))
    if len(start_matches) != 1:
        raise AssertionError(f"expected one workflow job named {job_name}, found {len(start_matches)}")
    start = start_matches[0].start()
    if next_job_name is not None:
        end_match = re.search(rf"^  {re.escape(next_job_name)}:\s*$", source[start:], re.MULTILINE)
    else:
        end_match = re.search(r"^  [a-zA-Z0-9_-]+:\s*$", source[start_matches[0].end() :], re.MULTILINE)
    if end_match is None:
        return source[start:]
    end_origin = start if next_job_name is not None else start_matches[0].end()
    return source[start : end_origin + end_match.start()]


def workflow_jobs() -> dict[str, dict]:
    """Load CI jobs as structured YAML for role-based orchestration assertions."""
    source = (REPO_ROOT / ".github" / "workflows" / "ios-ci.yml").read_text(encoding="utf-8")
    workflow = yaml.safe_load(source)
    jobs = workflow.get("jobs")
    if not isinstance(jobs, dict):
        raise AssertionError("expected ios-ci.yml to define a jobs mapping")
    return jobs


class ReleasePipelineContractTests(unittest.TestCase):
    """Prevents Xcode jobs from bypassing verified BibleView assets."""

    def test_frontend_ci_rebuilds_deterministically_and_detects_committed_drift(self) -> None:
        """The frontend job must prove Debug determinism and exact Production source alignment."""
        source = (REPO_ROOT / ".github" / "workflows" / "ios-ci.yml").read_text(encoding="utf-8")
        job = workflow_job(source, "bibleview-js", "ui-shard-plan")

        self.assertEqual(job.count("npm run build-debug"), 2)
        self.assertIn("--expected \"${RUNNER_TEMP}/bibleview-debug\"", job)
        self.assertIn("--actual \"${RUNNER_TEMP}/bibleview-debug-repeat\"", job)
        self.assertIn("npm run build-production", job)
        self.assertIn("Sources/BibleView/Sources/BibleView/Resources/bibleview-js", job)
        self.assertIn("--mode production", job)
        self.assertIn("name: bibleview-debug-bundle", job)

    def test_package_xcode_jobs_install_verified_debug_assets_before_building(self) -> None:
        """Package jobs must consume the verified Debug artifact before invoking Xcode."""
        jobs = workflow_jobs()
        for job_name in ("ios-bibleview-package-tests", "ios-bibleui-package-tests"):
            job = jobs[job_name]
            with self.subTest(job=job_name):
                self.assertIn("bibleview-js", job["needs"])
                steps = job["steps"]
                download_steps = [
                    step for step in steps
                    if step.get("uses", "").split("@", 1)[0] == "actions/download-artifact"
                ]
                self.assertTrue(
                    any(step.get("with", {}).get("name") == "bibleview-debug-bundle"
                        for step in download_steps)
                )
                run_commands = [step.get("run", "") for step in steps]
                sync_index = next(
                    index for index, command in enumerate(run_commands)
                    if "manage_bibleview_bundle.py sync" in command
                    and "--mode debug" in command
                )
                xcode_index = next(
                    index for index, command in enumerate(run_commands)
                    if "xcodebuild" in command
                )
                self.assertLess(sync_index, xcode_index)

    def test_app_host_xcode_jobs_validate_checked_in_production_assets_before_building(self) -> None:
        """App-host jobs must test the checked-in Production bundle after source byte comparison."""
        jobs = workflow_jobs()
        for job_name in ("ios-simulator-unit-tests", "ios-simulator-ui-tests"):
            job = jobs[job_name]
            with self.subTest(job=job_name):
                self.assertIn("bibleview-js", job["needs"])
                steps = job["steps"]
                run_commands = [step.get("run", "") for step in steps]
                validation_index = next(
                    index for index, command in enumerate(run_commands)
                    if "manage_bibleview_bundle.py validate" in command
                    and "--bundle Sources/BibleView/Sources/BibleView/Resources/bibleview-js"
                    in command
                    and "--mode production" in command
                )
                xcode_index = next(
                    index for index, command in enumerate(run_commands)
                    if "xcodebuild" in command
                )
                self.assertLess(validation_index, xcode_index)
                self.assertFalse(
                    any("manage_bibleview_bundle.py sync" in command for command in run_commands)
                )
                self.assertFalse(
                    any(
                        step.get("with", {}).get("name") == "bibleview-debug-bundle"
                        for step in steps
                    )
                )

if __name__ == "__main__":
    unittest.main()
