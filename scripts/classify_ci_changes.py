#!/usr/bin/env python3
"""Classify whether a change set can use the documentation-only CI path."""

from __future__ import annotations

import argparse
from pathlib import PurePosixPath
from typing import Sequence


def is_documentation_path(path: str) -> bool:
    """Return whether one repository-relative path contains documentation only."""
    normalized = PurePosixPath(path)
    return normalized.suffix.lower() == ".md" or normalized.parts[:1] == ("docs",)


def required_checks_only(changed_paths: Sequence[str]) -> bool:
    """Return whether a nonempty change set contains documentation only."""
    return bool(changed_paths) and all(is_documentation_path(path) for path in changed_paths)


def main(argv: Sequence[str] | None = None) -> int:
    """Print and optionally publish the GitHub Actions classification output."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--github-output")
    parser.add_argument("changed_paths", nargs="*")
    args = parser.parse_args(argv)

    value = str(required_checks_only(args.changed_paths)).lower()
    print(f"required_checks_only={value}")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as output:
            output.write(f"required_checks_only={value}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
