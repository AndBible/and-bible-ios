#!/usr/bin/env python3
"""Validate structural identity and relationship invariants for repository ADRs.

The checker deliberately supports both current front-matter records and the
repository's historical body-only records. It validates structure only: it
does not evaluate decision prose, change status, or treat passing checks as
acceptance.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


ADR_FILENAME_RE = re.compile(r"^(?P<number>\d{4})-[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?\.md$")
ADR_REFERENCE_RE = re.compile(r"\bADR[- ](?P<number>\d{4})\b", re.IGNORECASE)
HEADING_RE = re.compile(r"^#\s+(?:ADR-)?(?P<number>\d{4}):\s+\S", re.MULTILINE)
MARKDOWN_LINK_RE = re.compile(r"\[(?P<label>[^]]+)]\((?P<target>[^)]+)\)")
FRONT_MATTER_ID_RE = re.compile(r"^ADR-(?P<number>\d{4})$")
RELATIONSHIP_FIELDS = {
    "extends",
    "extended-by",
    "amends",
    "amended-by",
    "supersedes",
    "superseded-by",
    "related-adrs",
}


@dataclass(frozen=True)
class AdrRecord:
    """One parsed ADR and the identifiers it claims or references."""

    path: Path
    number: str
    references: frozenset[str]
    markdown_targets: tuple[str, ...]


@dataclass(frozen=True)
class AdrIssue:
    """A structural problem with an ADR file or the directory index."""

    path: Path
    message: str


def repo_root() -> Path:
    """Return the repository root inferred from this script's location."""

    return Path(__file__).resolve().parents[1]


def _front_matter(text: str) -> dict[str, str]:
    """Parse enough YAML front matter to inspect ADR identity relationships.

    Values are retained as text so the checker has no PyYAML dependency.
    Inline lists, scalar references, and indented list items are supported.
    Folded prose under unrelated fields is harmless because only structural
    keys are consumed by callers.
    """

    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}

    try:
        closing = next(index for index in range(1, len(lines)) if lines[index].strip() == "---")
    except StopIteration:
        return {}

    values: dict[str, list[str]] = {}
    current_key: str | None = None
    for line in lines[1:closing]:
        key_match = re.match(r"^([a-z][a-z0-9-]*):(?:\s*(.*))?$", line)
        if key_match:
            current_key = key_match.group(1)
            values[current_key] = [key_match.group(2) or ""]
            continue
        item_match = re.match(r"^\s+-\s+(.+?)\s*$", line)
        if item_match and current_key is not None:
            values[current_key].append(item_match.group(1))
            continue
        if line and not line[0].isspace():
            current_key = None

    return {key: "\n".join(parts) for key, parts in values.items()}


def parse_adr(path: Path) -> tuple[AdrRecord | None, list[AdrIssue]]:
    """Parse one modern or legacy ADR and return structural issues."""

    issues: list[AdrIssue] = []
    filename_match = ADR_FILENAME_RE.match(path.name)
    if not filename_match:
        return None, [
            AdrIssue(path, "ADR filenames must use NNNN-short-kebab-case-title.md")
        ]
    filename_number = filename_match.group("number")

    text = path.read_text(encoding="utf-8")
    metadata = _front_matter(text)
    claimed_numbers = {filename_number}

    if "adr" in metadata:
        raw_identifier = metadata["adr"].strip().strip('"\'')
        identifier_match = FRONT_MATTER_ID_RE.match(raw_identifier)
        if identifier_match is None:
            issues.append(AdrIssue(path, "front matter adr must use ADR-NNNN"))
        else:
            claimed_numbers.add(identifier_match.group("number"))

    heading_match = HEADING_RE.search(text)
    if heading_match is None:
        issues.append(AdrIssue(path, "missing '# NNNN: Title' or '# ADR-NNNN: Title' heading"))
    else:
        claimed_numbers.add(heading_match.group("number"))

    if len(claimed_numbers) != 1:
        issues.append(
            AdrIssue(
                path,
                "filename, front matter adr, and first ADR heading must use the same identifier",
            )
        )

    references: set[str] = set()
    for field in RELATIONSHIP_FIELDS:
        raw_value = metadata.get(field)
        if raw_value is not None:
            references.update(match.group("number") for match in ADR_REFERENCE_RE.finditer(raw_value))

    # Legacy records express supersession and related ADRs in body text. Modern
    # records also use contextual ADR references. Resolving every explicit ADR
    # token catches both forms without requiring historical normalization.
    references.update(match.group("number") for match in ADR_REFERENCE_RE.finditer(text))
    references.discard(filename_number)

    markdown_targets = tuple(
        match.group("target").split("#", 1)[0]
        for match in MARKDOWN_LINK_RE.finditer(text)
        if match.group("target").split("#", 1)[0].endswith(".md")
        and "://" not in match.group("target")
    )

    return (
        AdrRecord(
            path=path,
            number=filename_number,
            references=frozenset(references),
            markdown_targets=markdown_targets,
        ),
        issues,
    )


def _index_targets(index_path: Path) -> tuple[list[str], list[AdrIssue]]:
    """Return ADR Markdown targets from the index and validate link labels."""

    issues: list[AdrIssue] = []
    targets: list[str] = []
    text = index_path.read_text(encoding="utf-8")
    for match in MARKDOWN_LINK_RE.finditer(text):
        target = match.group("target").split("#", 1)[0]
        if not ADR_FILENAME_RE.match(Path(target).name):
            continue
        targets.append(target)
        label_number = re.match(r"^(?:ADR[- ]?)?(\d{4}):", match.group("label"), re.IGNORECASE)
        target_number = ADR_FILENAME_RE.match(Path(target).name).group("number")
        if label_number is None or label_number.group(1) != target_number:
            issues.append(AdrIssue(index_path, f"index label does not match target {target}"))
    return targets, issues


def validate_adr_directory(adr_dir: Path) -> list[AdrIssue]:
    """Validate identity, index coverage, and relationship resolution."""

    issues: list[AdrIssue] = []
    index_path = adr_dir / "README.md"
    if not index_path.is_file():
        return [AdrIssue(index_path, "missing ADR index")]

    records: list[AdrRecord] = []
    for path in sorted(adr_dir.glob("*.md")):
        if path == index_path:
            continue
        record, parse_issues = parse_adr(path)
        issues.extend(parse_issues)
        if record is not None:
            records.append(record)

    by_number: dict[str, list[AdrRecord]] = {}
    by_name = {record.path.name: record for record in records}
    for record in records:
        by_number.setdefault(record.number, []).append(record)
    for number, matching_records in sorted(by_number.items()):
        if len(matching_records) > 1:
            names = ", ".join(record.path.name for record in matching_records)
            issues.append(AdrIssue(adr_dir, f"ADR-{number} is claimed by multiple files: {names}"))

    index_targets, index_issues = _index_targets(index_path)
    issues.extend(index_issues)
    target_counts: dict[str, int] = {}
    for target in index_targets:
        target_counts[Path(target).name] = target_counts.get(Path(target).name, 0) + 1
    for name in sorted(by_name):
        count = target_counts.get(name, 0)
        if count == 0:
            issues.append(AdrIssue(index_path, f"ADR index is missing {name}"))
        elif count > 1:
            issues.append(AdrIssue(index_path, f"ADR index lists {name} {count} times"))
    for name in sorted(set(target_counts) - set(by_name)):
        issues.append(AdrIssue(index_path, f"ADR index target does not exist: {name}"))

    known_numbers = set(by_number)
    for record in records:
        for number in sorted(record.references - known_numbers):
            issues.append(AdrIssue(record.path, f"ADR-{number} relationship does not resolve"))
        for target in record.markdown_targets:
            resolved = (record.path.parent / target).resolve()
            if not resolved.is_file():
                issues.append(AdrIssue(record.path, f"Markdown ADR target does not exist: {target}"))

    return issues


def main(argv: list[str] | None = None) -> int:
    """Run the ADR structure checker and print actionable diagnostics."""

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--adr-dir",
        type=Path,
        default=repo_root() / "docs" / "adr",
        help="ADR directory containing README.md (default: repository docs/adr)",
    )
    args = parser.parse_args(argv)
    issues = validate_adr_directory(args.adr_dir.resolve())
    if not issues:
        print(f"ADR structure check passed: {args.adr_dir}")
        return 0
    for issue in issues:
        print(f"{issue.path}: {issue.message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
