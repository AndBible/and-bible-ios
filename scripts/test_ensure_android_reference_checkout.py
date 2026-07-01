#!/usr/bin/env python3
"""
Unit tests for the Android reference checkout helper.
"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = REPO_ROOT / "scripts" / "ensure_android_reference_checkout.sh"


class EnsureAndroidReferenceCheckoutTests(unittest.TestCase):
    """Covers checkout detection before parity guardrails use Android sources."""

    def test_helper_accepts_existing_git_worktree_checkout(self) -> None:
        """Treats worktree checkouts as already available Android references.

        Git worktrees store `.git` as a file instead of a directory. A failure
        means the helper can reject a valid local Android checkout and block
        parity guardrails before they can compare Android/iOS contracts.
        """
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            source = root / "source"
            android = root / "and-bible"
            subprocess.run(["git", "init", "-q", str(source)], check=True)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(source),
                    "-c",
                    "user.email=ci@example.invalid",
                    "-c",
                    "user.name=CI",
                    "commit",
                    "--allow-empty",
                    "-m",
                    "init",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            subprocess.run(
                ["git", "-C", str(source), "worktree", "add", "-q", str(android)],
                check=True,
            )
            self.assertTrue((android / ".git").is_file())

            result = subprocess.run(
                ["bash", str(HELPER), str(android)],
                cwd=REPO_ROOT,
                env={"PATH": os.environ["PATH"]},
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("Android reference checkout already available", result.stdout)

    def test_helper_expands_tilde_android_root_env(self) -> None:
        """Expands local env overrides before resolving checkout paths.

        Operators may run parity checks with ANDBIBLE_ANDROID_ROOT=~/src/and-bible.
        A failure means the helper treats "~" as a literal repo-relative folder
        and may clone into the iOS checkout instead of reusing the requested
        Android repository.
        """
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            fake_repo = root / "ios"
            helper = fake_repo / "scripts" / "ensure_android_reference_checkout.sh"
            home = root / "home"
            android = home / "and-bible"
            helper.parent.mkdir(parents=True)
            home.mkdir()
            helper.write_text(HELPER.read_text(encoding="utf-8"), encoding="utf-8")
            subprocess.run(["git", "init", "-q", str(android)], check=True)

            result = subprocess.run(
                ["bash", str(helper)],
                cwd=fake_repo,
                env={
                    "ANDBIBLE_ANDROID_REPO_URL": str(root / "missing-remote"),
                    "ANDBIBLE_ANDROID_ROOT": "~/and-bible",
                    "HOME": str(home),
                    "PATH": os.environ["PATH"],
                },
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(f"Android reference checkout already available: {android}", result.stdout)

    def test_helper_rejects_git_subdirectory_android_root(self) -> None:
        """Rejects paths inside a checkout that are not the Android repo root.

        ANDBIBLE_ANDROID_ROOT is consumed as the Android repository root by both
        bridge and localization guardrails. A failure means the helper can bless
        a subdirectory, after which localization may miss live resources and
        fall back to snapshots.
        """
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            android = root / "and-bible"
            app_subdir = android / "app"
            app_subdir.mkdir(parents=True)
            subprocess.run(["git", "init", "-q", str(android)], check=True)

            result = subprocess.run(
                ["bash", str(HELPER), str(app_subdir)],
                cwd=REPO_ROOT,
                env={"PATH": os.environ["PATH"]},
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(2, result.returncode, result.stdout)
        self.assertIn("is not the checkout root", result.stderr)


if __name__ == "__main__":
    unittest.main()
