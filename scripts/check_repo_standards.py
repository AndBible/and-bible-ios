#!/usr/bin/env python3
"""
Incremental repo standards guardrails for commit messages and Swift docblock style.

Checks:
1. Commit messages in the selected rev range must follow the locked commit-message standard.
2. Changed Swift files in the selected rev range must not introduce multi-line `///` docblocks.

The docblock check is intentionally incremental. The repo still contains pre-existing legacy
multi-line `///` blocks, so CI only enforces the rule on Swift files touched by the current
commit range.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


ALLOWED_COMMIT_TYPES = {
    "feat",
    "fix",
    "refactor",
    "docs",
    "test",
    "chore",
    "build",
    "ci",
    "ops",
    "sec",
}

REQUIRED_SECTIONS = ["Why:", "What Changed:", "Validation:", "Impact:"]
OPTIONAL_SECTIONS = ["Breaking Changes:", "Refs:"]
ALL_SECTION_HEADINGS = set(REQUIRED_SECTIONS + OPTIONAL_SECTIONS)

SUBJECT_RE = re.compile(
    r"^(?P<type>feat|fix|refactor|docs|test|chore|build|ci|ops|sec)(\([^)]+\))?: (?P<summary>\S.*)$"
)
DOCBLOCK_LINE_RE = re.compile(r"^\s*///")


@dataclass(frozen=True)
class CommitIssue:
    sha: str
    message: str


@dataclass(frozen=True)
class DocblockIssue:
    path: str
    line: int
    message: str


def default_repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def run_git(repo_root: Path, args: list[str]) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo_root), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def resolve_rev_range(repo_root: Path, rev_range: str | None, base_ref: str | None, head_ref: str) -> str:
    if rev_range:
        return rev_range
    if base_ref:
        merge_base = run_git(repo_root, ["merge-base", base_ref, head_ref]).strip()
        return f"{merge_base}..{head_ref}"
    return "HEAD^..HEAD"


def commit_shas_in_range(repo_root: Path, rev_range: str) -> list[str]:
    output = run_git(repo_root, ["rev-list", "--reverse", "--no-merges", rev_range]).strip()
    if not output:
        return []
    return [line for line in output.splitlines() if line.strip()]


def commit_message(repo_root: Path, sha: str) -> str:
    return run_git(repo_root, ["show", "-s", "--format=%B", sha])


def validate_commit_message(sha: str, message: str) -> list[CommitIssue]:
    issues: list[CommitIssue] = []
    lines = message.splitlines()

    if not lines or not lines[0].strip():
        return [CommitIssue(sha, "missing subject line")]

    subject = lines[0].rstrip()
    subject_match = SUBJECT_RE.match(subject)
    if not subject_match:
        issues.append(
            CommitIssue(
                sha,
                "subject must match <type>(<scope>): <summary> or <type>: <summary> with an allowed type",
            )
        )
    elif subject_match.group("type") not in ALLOWED_COMMIT_TYPES:
        issues.append(CommitIssue(sha, "subject type is not in the allowed type set"))

    if len(lines) < 2 or lines[1].strip():
        issues.append(CommitIssue(sha, "subject must be followed by one blank line"))

    body_lines = lines[2:] if len(lines) > 2 else []
    headings: list[tuple[str, int]] = []
    for index, line in enumerate(body_lines):
        if line in ALL_SECTION_HEADINGS:
            headings.append((line, index))
        if line.startswith("Co-authored-by:"):
            issues.append(CommitIssue(sha, "Co-authored-by trailers are forbidden by default"))

    heading_names = [name for name, _ in headings]
    for required in REQUIRED_SECTIONS:
        if heading_names.count(required) == 0:
            issues.append(CommitIssue(sha, f"missing required section {required}"))
        elif heading_names.count(required) > 1:
            issues.append(CommitIssue(sha, f"duplicate required section {required}"))

    required_positions = []
    for required in REQUIRED_SECTIONS:
        if required in heading_names:
            required_positions.append(heading_names.index(required))
    if required_positions and required_positions != sorted(required_positions):
        issues.append(CommitIssue(sha, "required sections must appear in Why/What Changed/Validation/Impact order"))

    for name, position in headings:
        next_position = len(body_lines)
        for _, candidate_position in headings:
            if candidate_position > position:
                next_position = candidate_position
                break
        content = [line.strip() for line in body_lines[position + 1:next_position] if line.strip()]
        if not content:
            issues.append(CommitIssue(sha, f"section {name} must contain content or 'none'"))

    return issues


def changed_swift_files(repo_root: Path, rev_range: str, all_files: bool) -> list[Path]:
    if all_files:
        output = run_git(repo_root, ["ls-files", "*.swift"])
    else:
        output = run_git(repo_root, ["diff", "--name-only", "--diff-filter=AM", rev_range, "--", "*.swift"])
    files = []
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        files.append(repo_root / line)
    return files


def find_multiline_slash_docblocks(text: str) -> list[int]:
    issues: list[int] = []
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        if DOCBLOCK_LINE_RE.match(lines[index]):
            start = index
            index += 1
            while index < len(lines) and DOCBLOCK_LINE_RE.match(lines[index]):
                index += 1
            if index - start > 1:
                issues.append(start + 1)
            continue
        index += 1
    return issues


def validate_docblock_file(path: Path, repo_root: Path) -> list[DocblockIssue]:
    text = path.read_text(encoding="utf-8")
    return [
        DocblockIssue(
            path=str(path.relative_to(repo_root)),
            line=line,
            message="multi-line Swift documentation comments must use /** */ instead of consecutive /// lines",
        )
        for line in find_multiline_slash_docblocks(text)
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=["commits", "docblocks", "all"],
        help="Which guardrail set to run.",
    )
    parser.add_argument("--repo-root", type=Path, default=default_repo_root())
    parser.add_argument("--rev-range", default=None)
    parser.add_argument("--base-ref", default=None)
    parser.add_argument("--head-ref", default="HEAD")
    parser.add_argument(
        "--all-files",
        action="store_true",
        help="For docblocks, scan all tracked Swift files instead of only changed files in the selected rev range.",
    )
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve()
    rev_range = resolve_rev_range(repo_root, args.rev_range, args.base_ref, args.head_ref)

    commit_issues: list[CommitIssue] = []
    docblock_issues: list[DocblockIssue] = []

    if args.command in {"commits", "all"}:
        for sha in commit_shas_in_range(repo_root, rev_range):
            commit_issues.extend(validate_commit_message(sha, commit_message(repo_root, sha)))

    if args.command in {"docblocks", "all"}:
        for path in changed_swift_files(repo_root, rev_range, args.all_files):
            if path.exists():
                docblock_issues.extend(validate_docblock_file(path, repo_root))

    if commit_issues:
        print("Commit message violations:")
        for issue in commit_issues:
            print(f"- {issue.sha[:12]}: {issue.message}")

    if docblock_issues:
        print("Swift docblock style violations:")
        for issue in docblock_issues:
            print(f"- {issue.path}:{issue.line}: {issue.message}")

    if commit_issues or docblock_issues:
        return 1

    if args.command in {"commits", "all"}:
        checked_commits = len(commit_shas_in_range(repo_root, rev_range))
        print(f"Commit message guardrails passed for {checked_commits} non-merge commit(s).")

    if args.command in {"docblocks", "all"}:
        checked_files = len(changed_swift_files(repo_root, rev_range, args.all_files))
        scope = "all tracked Swift files" if args.all_files else "changed Swift file(s)"
        print(f"Swift docblock style guardrails passed for {checked_files} {scope}.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
