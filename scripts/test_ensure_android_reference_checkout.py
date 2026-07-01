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


if __name__ == "__main__":
    unittest.main()
