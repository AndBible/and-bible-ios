#!/usr/bin/env python3
"""Source contracts for the build-owned BibleView and two-stage release workflows."""

from __future__ import annotations

from pathlib import Path
import re
import unittest


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


class ReleasePipelineContractTests(unittest.TestCase):
    """Prevents release orchestration from bypassing generated-asset and evidence bindings."""

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

    def test_xcode_jobs_install_verified_debug_assets_before_building(self) -> None:
        """Every CI job that packages BibleView must consume the verified artifact before Xcode."""
        source = (REPO_ROOT / ".github" / "workflows" / "ios-ci.yml").read_text(encoding="utf-8")
        job_boundaries = (
            ("ios-bibleview-package-tests", "ios-bibleui-package-tests"),
            ("ios-bibleui-package-tests", "bibleview-js"),
            ("ios-simulator-unit-tests", "ios-simulator-ui-tests"),
            ("ios-simulator-ui-tests", None),
        )
        for job_name, next_job in job_boundaries:
            job = workflow_job(source, job_name, next_job)
            with self.subTest(job=job_name):
                self.assertIn("name: bibleview-debug-bundle", job)
                self.assertIn("manage_bibleview_bundle.py sync", job)
                self.assertLess(job.index("manage_bibleview_bundle.py sync"), job.index("xcodebuild"))

    def test_release_validation_downloads_exact_tarred_candidates_without_rebuilding(self) -> None:
        """Prepare owns archives; validation must only restore and attest those exact candidates."""
        source = (
            REPO_ROOT / ".github" / "workflows" / "distribution-release-readiness.yml"
        ).read_text(encoding="utf-8")
        prepare = workflow_job(source, "prepare-release-archives", "validate-release-evidence")
        validate = workflow_job(source, "validate-release-evidence")

        self.assertEqual(prepare.count("xcodebuild archive"), 2)
        self.assertIn("npm run build-production", prepare)
        self.assertEqual(prepare.count("manage_bibleview_bundle.py verify-archive"), 2)
        self.assertEqual(prepare.count("tar -C \"$RUNNER_TEMP\" -cpf"), 2)
        self.assertIn("--write-binding", prepare)
        self.assertNotIn("xcodebuild archive", validate)
        self.assertNotIn("npm run build-production", validate)
        self.assertIn("gh run download \"$ARCHIVE_RUN_ID\"", validate)
        self.assertEqual(validate.count("tar -C \"$RUNNER_TEMP/restored-archives\" -xpf"), 2)
        self.assertEqual(validate.count("manage_bibleview_bundle.py verify-archive"), 2)
        self.assertIn("--expected-commit-sha \"$GITHUB_SHA\"", validate)
        self.assertIn("validate_distribution_release_readiness.py", validate)


if __name__ == "__main__":
    unittest.main()
