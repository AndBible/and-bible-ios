#!/usr/bin/env python3
"""
Repo standards guardrails for commit messages, Swift docblock style, and static source contracts.

Checks:
1. Commit messages in the selected rev range must follow the locked commit-message standard.
2. Swift files in the selected scope must not contain multi-line `///` docblocks.
3. Static source guards prevent known app-structure regressions from reappearing.

The docblock checker supports both incremental and full-repo scans. CI now uses the full-repo
mode because the tracked Swift baseline has been normalized to the locked `/** */` standard.
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


@dataclass(frozen=True)
class SourceGuardIssue:
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


def _mask_swift_comments_and_strings(text: str) -> str:
    """Return Swift-like source with comments and strings blanked while preserving positions.

    The static source guards only need coarse structural matching. Masking comments and strings keeps
    sentinel identifiers and braces in prose or literals from changing guard results while preserving
    line numbers for diagnostics.
    """
    masked = list(text)
    index = 0

    while index < len(text):
        if text.startswith("//", index):
            end = text.find("\n", index)
            if end == -1:
                end = len(text)
            for position in range(index, end):
                masked[position] = " "
            index = end
            continue

        if text.startswith("/*", index):
            end = text.find("*/", index + 2)
            end = len(text) if end == -1 else end + 2
            for position in range(index, end):
                if masked[position] != "\n":
                    masked[position] = " "
            index = end
            continue

        if text.startswith('"""', index):
            end = text.find('"""', index + 3)
            end = len(text) if end == -1 else end + 3
            for position in range(index, end):
                if masked[position] != "\n":
                    masked[position] = " "
            index = end
            continue

        if text[index] == '"':
            position = index
            escaped = False
            while position < len(text):
                current = text[position]
                if current != "\n":
                    masked[position] = " "
                if current == '"' and position != index and not escaped:
                    position += 1
                    break
                escaped = (current == "\\" and not escaped)
                if current != "\\":
                    escaped = False
                position += 1
            index = position
            continue

        index += 1

    return "".join(masked)


def _matching_brace_end(text: str, open_brace_index: int) -> int:
    """Return the exclusive end offset of a brace-delimited block.

    Inputs are expected to already have comments and strings masked so brace counting follows source
    structure instead of prose. If a block is incomplete, the function returns the end of the text so
    the guard still reports a conservative result.
    """
    depth = 0
    for index in range(open_brace_index, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return index + 1
    return len(text)


def find_legacy_root_sidebar_shell(text: str) -> list[int]:
    """Return line numbers where the legacy root sidebar shell appears in ContentView source.

    The guard scans each `NavigationSplitView` block because the regression pattern is structural:
    the legacy root shell colocated Bible and Settings sidebar identifiers in the same root layout
    region. The returned line numbers point reviewers at the triggering `NavigationSplitView`.
    """
    masked_source = _mask_swift_comments_and_strings(text)
    issues: list[int] = []
    search_term = "NavigationSplitView"
    search_start = 0

    while search_start < len(masked_source):
        navigation_index = masked_source.find(search_term, search_start)
        if navigation_index == -1:
            break

        block_start = masked_source.find("{", navigation_index)
        if block_start == -1:
            break

        block_end = _matching_brace_end(masked_source, block_start)
        navigation_block = masked_source[block_start:block_end]

        if "contentTabBible" in navigation_block and "contentSettingsLink" in navigation_block:
            issues.append(text.count("\n", 0, navigation_index) + 1)

        search_start = navigation_index + len(search_term)

    return issues


def validate_source_guards(repo_root: Path) -> list[SourceGuardIssue]:
    """Validate static source contracts that should run outside XCTest.

    The current guard keeps the `ContentView` legacy root sidebar regression out of the app-host
    bundle. It reports a missing file as a failure so project-layout moves must deliberately update
    the guard instead of silently dropping coverage.
    """
    content_view_path = repo_root / "AndBible/ContentView.swift"
    relative_path = "AndBible/ContentView.swift"

    if not content_view_path.exists():
        return [
            SourceGuardIssue(
                path=relative_path,
                line=1,
                message=(
                    "Could not locate AndBible/ContentView.swift. Update the static source guard "
                    "if the project layout changes."
                ),
            )
        ]

    source = content_view_path.read_text(encoding="utf-8")
    return [
        SourceGuardIssue(
            path=relative_path,
            line=line,
            message=(
                "ContentView.swift appears to contain the legacy root sidebar shell pattern: "
                "NavigationSplitView with contentTabBible/contentSettingsLink in the same root "
                "layout region."
            ),
        )
        for line in find_legacy_root_sidebar_shell(source)
    ]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=["commits", "docblocks", "source-guards", "all"],
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
    source_guard_issues: list[SourceGuardIssue] = []

    if args.command in {"commits", "all"}:
        for sha in commit_shas_in_range(repo_root, rev_range):
            commit_issues.extend(validate_commit_message(sha, commit_message(repo_root, sha)))

    if args.command in {"docblocks", "all"}:
        for path in changed_swift_files(repo_root, rev_range, args.all_files):
            if path.exists():
                docblock_issues.extend(validate_docblock_file(path, repo_root))

    if args.command in {"source-guards", "all"}:
        source_guard_issues.extend(validate_source_guards(repo_root))

    if commit_issues:
        print("Commit message violations:")
        for issue in commit_issues:
            print(f"- {issue.sha[:12]}: {issue.message}")

    if docblock_issues:
        print("Swift docblock style violations:")
        for issue in docblock_issues:
            print(f"- {issue.path}:{issue.line}: {issue.message}")

    if source_guard_issues:
        print("Static source guard violations:")
        for issue in source_guard_issues:
            print(f"- {issue.path}:{issue.line}: {issue.message}")

    if commit_issues or docblock_issues or source_guard_issues:
        return 1

    if args.command in {"commits", "all"}:
        checked_commits = len(commit_shas_in_range(repo_root, rev_range))
        print(f"Commit message guardrails passed for {checked_commits} non-merge commit(s).")

    if args.command in {"docblocks", "all"}:
        checked_files = len(changed_swift_files(repo_root, rev_range, args.all_files))
        scope = "all tracked Swift files" if args.all_files else "changed Swift file(s)"
        print(f"Swift docblock style guardrails passed for {checked_files} {scope}.")

    if args.command in {"source-guards", "all"}:
        print("Static source guardrails passed.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
