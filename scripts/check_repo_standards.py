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


def _swift_parenthesized_end(text: str, start: int) -> int | None:
    """Return the exclusive end of one balanced Swift parenthesized region.

    The input is masked Swift source and `start` points at `(`. Nested parentheses are counted;
    comments and strings have already been removed by the caller. The helper returns `None` for an
    unterminated region and performs no I/O or mutation.
    """
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
    return None


def _swift_top_level_arguments(text: str) -> list[str]:
    """Split a masked Swift parameter/call body at top-level commas.

    Parentheses, brackets, braces, and generic angle brackets keep their contained commas together.
    The returned strings preserve source spelling for label/default checks. Malformed nesting fails
    closed by returning the unsplit remainder as one argument; the helper has no side effects.
    """
    if not text.strip():
        return []
    arguments: list[str] = []
    start = 0
    depths = {"(": 0, "[": 0, "{": 0, "<": 0}
    closing = {")": "(", "]": "[", "}": "{", ">": "<"}
    for index, character in enumerate(text):
        if character in depths:
            depths[character] += 1
        elif character in closing:
            opener = closing[character]
            depths[opener] = max(0, depths[opener] - 1)
        elif character == "," and not any(depths.values()):
            arguments.append(text[start:index])
            start = index + 1
    arguments.append(text[start:])
    return arguments


def _swift_function_ranges(masked_source: str) -> list[tuple[str, int, int]]:
    """Return named Swift function body ranges from masked source.

    The result contains `(name, declarationStart, bodyEnd)` tuples for declarations with a braced
    body. Nested functions are retained so the smallest containing range identifies exact publisher
    ownership. Malformed declarations are skipped; no source is changed.
    """
    ranges: list[tuple[str, int, int]] = []
    pattern = re.compile(
        r"(?:\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)|\b(init))\s*\("
    )
    for match in pattern.finditer(masked_source):
        parameter_start = masked_source.find("(", match.start())
        parameter_end = _swift_parenthesized_end(masked_source, parameter_start)
        if parameter_end is None:
            continue
        body_start = masked_source.find("{", parameter_end)
        if body_start == -1:
            continue
        body_end = _matching_brace_end(masked_source, body_start)
        ranges.append((match.group(1) or match.group(2), match.start(), body_end))
    return ranges


def _enclosing_swift_function_name(
    function_ranges: list[tuple[str, int, int]],
    position: int,
) -> str | None:
    """Return the innermost named function containing one source position, if any."""
    containing = [item for item in function_ranges if item[1] <= position < item[2]]
    if not containing:
        return None
    return min(containing, key=lambda item: item[2] - item[1])[0]


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


def find_unsafe_direct_document_publishers(
    text: str,
    relative_path: str = "",
) -> list[int]:
    """Return declaration lines for document publishers that bypass global admission.

    The input is one production Swift file plus its optional repository-relative path. Comments and
    strings are masked before matching so documentation cannot trigger or suppress the guard. The
    result covers EPUB publishers whose later admission/lease parameters can be omitted, direct My
    Documents graph publishers, omission-tolerant registry dependencies, type aliases that obscure
    audited publisher ownership, and calls outside exact function boundaries. The helper performs
    no filesystem access or mutation.
    """
    masked_source = _mask_swift_comments_and_strings(text)
    function_ranges = _swift_function_ranges(masked_source)
    forbidden_patterns = (
        re.compile(
            r"\btypealias\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*"
            r"(?:(?:[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*)*EpubReader\b"
        ),
        re.compile(
            r"\btypealias\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*"
            r"(?:(?:[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*)*MyDocument\b"
        ),
        re.compile(
            r"\btypealias\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*"
            r"(?:(?:[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*)*ExternalDocumentImportService\b"
        ),
        re.compile(
            r"\bEpubReader\s*\.\s*(?:install|installAndroidModuleBackup)\b(?!\s*\()"
        ),
        re.compile(r"\bMyDocument\s*\.\s*init\b(?!\s*\()"),
        re.compile(r"\bExternalDocumentImportService\s*\.\s*init\b(?!\s*\()"),
        re.compile(r"\bSelf\s*\(\s*epubCandidateAdmission\s*:"),
        re.compile(
            r"\bfunc\s+insert\s*\(\s*(?:(?:[A-Za-z_][A-Za-z0-9_]*|_)\s+)?"
            r"(?:[A-Za-z_][A-Za-z0-9_]*|_)\s*:\s*"
            r"(?:(?:[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*)?MyDocument\b"
        ),
        re.compile(r"\bisDocumentInitialsUnavailable\s*:[^,\n=]+="),
        re.compile(r"\bstrictMyDocumentInitialsUnavailable\s*:[^,\n=]+[?=]"),
        re.compile(r"\bepubCandidateAdmission\s*:[^,\n=]+="),
    )
    matches = [
        text.count("\n", 0, match.start()) + 1
        for pattern in forbidden_patterns
        for match in pattern.finditer(masked_source)
    ]

    install_declaration = re.compile(
        r"(?P<modifiers>(?:(?:"
        r"@[A-Za-z_][A-Za-z0-9_]*(?:\s*\([^)]*\))?"
        r"|public|internal|private|fileprivate|package|static|class|final|nonisolated"
        r"|override|required|convenience|mutating|nonmutating|distributed|borrowing|consuming"
        r")\s+)*)"
        r"\bfunc\s+(?P<name>install|installAndroidModuleBackup)\s*\("
    )
    for declaration in install_declaration.finditer(masked_source):
        declaration_name = declaration.group("name")
        parameter_start = masked_source.find("(", declaration.start())
        parameter_end = _swift_parenthesized_end(masked_source, parameter_start)
        if parameter_end is None:
            matches.append(text.count("\n", 0, declaration.start()) + 1)
            continue
        parameters = _swift_top_level_arguments(
            masked_source[parameter_start + 1:parameter_end - 1]
        )
        labels: set[str] = set()
        parameter_types: dict[str, str] = {}
        for parameter in parameters:
            declaration_part, separator, type_part = parameter.partition(":")
            identifiers = re.findall(r"[A-Za-z_][A-Za-z0-9_]*|_", declaration_part)
            if identifiers:
                label = identifiers[0]
                labels.add(label)
                if separator:
                    parameter_types[label] = type_part.strip()
        modifiers = declaration.group("modifiers")
        is_public = re.search(r"\bpublic\b", modifiers) is not None
        has_default = any("=" in parameter for parameter in parameters)
        line = text.count("\n", 0, declaration.start()) + 1

        if declaration_name == "install":
            is_epub_install = (
                "epubURL" in labels
                or relative_path.endswith("/EpubReader.swift")
                or relative_path.endswith("/EpubReaderLibrary.swift")
            )
            if not is_epub_install:
                continue
            if is_public:
                required_labels = {
                    "epubURL",
                    "moduleStoreRootURL",
                    "admittingCandidateWith",
                }
                admission_type = parameter_types.get("admittingCandidateWith", "")
                has_strict_admission_type = re.fullmatch(
                    r"(?:(?:[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*)*InstallAdmission",
                    admission_type,
                ) is not None
                if (
                    has_default
                    or not required_labels.issubset(labels)
                    or not has_strict_admission_type
                ):
                    matches.append(line)
                continue
            is_explicit_root_boundary = (
                relative_path.endswith("/EpubReaderLibrary.swift")
                and "epubURL" in labels
                and "libraryRootURL" in labels
                and not has_default
            )
            if not is_explicit_root_boundary:
                matches.append(line)
            continue

        is_android_epub_publisher = (
            "epubDirectoryURL" in labels
            or relative_path.endswith("/EpubAndroidModuleBackup.swift")
            or not relative_path
        )
        if not is_android_epub_publisher:
            continue
        is_internal_explicit_root_boundary = (
            not is_public
            and relative_path.endswith("/EpubAndroidModuleBackup.swift")
            and {"epubDirectoryURL", "libraryRootURL"}.issubset(labels)
            and not has_default
        )
        if not is_internal_explicit_root_boundary:
            matches.append(line)

    function_declaration = re.compile(r"\bfunc\s+[A-Za-z_][A-Za-z0-9_]*\s*\(")
    my_document_extension_ranges: list[tuple[int, int]] = []
    my_document_extension = re.compile(
        r"\bextension\s+(?:(?:[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*)*MyDocument\s*\{"
    )
    for extension in my_document_extension.finditer(masked_source):
        body_start = masked_source.find("{", extension.start())
        my_document_extension_ranges.append(
            (extension.start(), _matching_brace_end(masked_source, body_start))
        )

    for declaration in function_declaration.finditer(masked_source):
        parameter_start = masked_source.find("(", declaration.start())
        parameter_end = _swift_parenthesized_end(masked_source, parameter_start)
        if parameter_end is None:
            continue
        parameters = _swift_top_level_arguments(
            masked_source[parameter_start + 1:parameter_end - 1]
        )
        body_start = masked_source.find("{", parameter_end)
        if body_start == -1:
            continue
        body_end = _matching_brace_end(masked_source, body_start)
        signature = masked_source[parameter_end:body_start]
        body = masked_source[body_start:body_end]
        returns_document = re.search(
            r"->\s*(?:(?:[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*)*MyDocument\b",
            signature,
        ) is not None
        returns_self_in_document_extension = (
            re.search(r"->\s*Self\b", signature) is not None
            and any(start <= declaration.start() < end for start, end in my_document_extension_ranges)
        )
        constructs_return_value = (
            re.search(r"(?:\breturn\s+)?\.\s*init\s*\(", body) is not None
            or (
                returns_self_in_document_extension
                and re.search(r"\bSelf\s*\(", body) is not None
            )
        )
        if (returns_document or returns_self_in_document_extension) and constructs_return_value:
            matches.append(text.count("\n", 0, declaration.start()) + 1)

        document_parameters: list[tuple[str, bool]] = []
        for parameter in parameters:
            if ":" not in parameter:
                continue
            declaration_part, type_part = parameter.split(":", 1)
            names = re.findall(r"[A-Za-z_][A-Za-z0-9_]*", declaration_part)
            if not names:
                continue
            is_factory = re.search(
                r"\([^)]*\)\s*(?:(?:async|throws|rethrows)\s+)*->\s*"
                r"(?:(?:[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*)*MyDocument\b",
                type_part,
            ) is not None
            is_document = re.search(
                r"(?<!->\s)(?:(?:[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*)*MyDocument\b",
                type_part,
            ) is not None
            if is_factory or is_document:
                document_parameters.append((names[-1], is_factory))
        if not document_parameters:
            continue
        publishes_document_parameter = False
        for name, is_factory in document_parameters:
            if not is_factory:
                publishes_document_parameter = re.search(
                    rf"\.\s*insert\s*\(\s*{re.escape(name)}\s*\)",
                    body,
                ) is not None
            else:
                publishes_document_parameter = re.search(
                    rf"\.\s*insert\s*\(\s*(?:(?:try[!?]?|await)\s+)*"
                    rf"{re.escape(name)}\s*\(",
                    body,
                ) is not None
                if not publishes_document_parameter:
                    aliases = re.findall(
                        rf"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)"
                        rf"(?:\s*:\s*(?:(?:[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*)*MyDocument)?"
                        rf"\s*=\s*(?:(?:try[!?]?|await)\s+)*"
                        rf"{re.escape(name)}\s*\(",
                        body,
                    )
                    publishes_document_parameter = any(
                        re.search(
                            rf"\.\s*insert\s*\(\s*{re.escape(alias)}\s*\)",
                            body,
                        )
                        for alias in aliases
                    )
            if publishes_document_parameter:
                break
        if publishes_document_parameter:
            matches.append(text.count("\n", 0, declaration.start()) + 1)

    typed_document_factory = re.compile(
        r"\b(?:let|var)\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*"
        r"(?:(?:@[A-Za-z_][A-Za-z0-9_]*(?:\s*\([^)]*\))?)\s+)*"
        r"\([^)]*\)\s*"
        r"(?:(?:async|throws|rethrows)\s+)*->\s*"
        r"(?:(?:[A-Za-z_][A-Za-z0-9_]*)\s*\.\s*)*MyDocument\s*=\s*\{"
    )
    for declaration in typed_document_factory.finditer(masked_source):
        body_start = masked_source.find("{", declaration.start())
        body_end = _matching_brace_end(masked_source, body_start)
        body = masked_source[body_start:body_end]
        if re.search(
            r"(?:\breturn\s+)?(?:\.\s*init|\bMyDocument(?:\s*\.\s*init)?)\s*\(",
            body,
        ):
            matches.append(text.count("\n", 0, declaration.start()) + 1)

    if relative_path.endswith("/MyDocumentStore.swift"):
        matches.extend(
            text.count("\n", 0, match.start()) + 1
            for match in re.finditer(r"\bfunc\s+save\s*\(\s*\)", masked_source)
        )

    if relative_path.endswith("/MyDocumentLibraryStore.swift"):
        fail_open_save = re.compile(
            r"\bpublic\s+func\s+save\s*\("
            r"(?:(?!\n\s*\)\s*(?:async\s+)?throws)[\s\S])*?"
            r"\bisInitialsUnavailable\s*:"
        )
        matches.extend(
            text.count("\n", 0, match.start()) + 1
            for match in fail_open_save.finditer(masked_source)
        )

    if relative_path.endswith("/MyDocumentsListView.swift"):
        matches.extend(
            text.count("\n", 0, match.start()) + 1
            for match in re.finditer(
                r"\bisInitialsUnavailable\s*:[^,\n=]+=",
                masked_source,
            )
        )

    audited_calls = {
        "installAndroidModuleBackup": [
            (
                "Sources/BibleCore/Sources/BibleCore/Services/AndroidModuleBackupRestoreAvailability.swift",
                "validatePublishedState",
                {"epubDirectoryURL", "libraryRootURL"},
            ),
            (
                "Sources/BibleCore/Sources/BibleCore/Services/AndroidModuleBackupService.swift",
                "restorePlannedArchive",
                {"epubDirectoryURL", "libraryRootURL"},
            ),
        ],
        "install": [
            (
                "Sources/BibleUI/Sources/BibleUI/Shared/ExternalDocumentImportService.swift",
                "init",
                {"epubURL", "moduleStoreRootURL", "admittingCandidateWith"},
            ),
        ],
    }
    epub_call = re.compile(r"\bEpubReader\s*\.\s*(installAndroidModuleBackup|install)\s*\(")
    for call in epub_call.finditer(masked_source):
        call_name = call.group(1)
        argument_start = masked_source.find("(", call.start())
        argument_end = _swift_parenthesized_end(masked_source, argument_start)
        arguments = "" if argument_end is None else masked_source[argument_start + 1:argument_end - 1]
        parsed_arguments = _swift_top_level_arguments(arguments)
        labeled_arguments: dict[str, str] = {}
        for argument in parsed_arguments:
            label_match = re.match(
                r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([\s\S]*)",
                argument,
            )
            if label_match:
                labeled_arguments[label_match.group(1)] = label_match.group(2).strip()
        labels = set(labeled_arguments)
        enclosing_function = _enclosing_swift_function_name(function_ranges, call.start())
        is_audited_call = any(
            relative_path == expected_path
            and enclosing_function == expected_function
            and required_labels.issubset(labels)
            for expected_path, expected_function, required_labels in audited_calls[call_name]
        )
        if (
            call_name == "install"
            and relative_path
            == "Sources/BibleUI/Sources/BibleUI/Shared/ExternalDocumentImportService.swift"
            and enclosing_function == "init"
            and labeled_arguments.get("admittingCandidateWith") != "admission"
        ):
            is_audited_call = False
        if not is_audited_call:
            matches.append(text.count("\n", 0, call.start()) + 1)

    import_service_constructor = re.compile(
        r"(?:\bExternalDocumentImportService\s*(?:\.\s*init)?|\.\s*init)\s*\("
    )
    for constructor in import_service_constructor.finditer(masked_source):
        argument_start = masked_source.find("(", constructor.start())
        argument_end = _swift_parenthesized_end(masked_source, argument_start)
        arguments = "" if argument_end is None else masked_source[argument_start + 1:argument_end - 1]
        parsed_arguments = _swift_top_level_arguments(arguments)
        labeled_arguments: dict[str, str] = {}
        for argument in parsed_arguments:
            label_match = re.match(
                r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([\s\S]*)",
                argument,
            )
            if label_match:
                labeled_arguments[label_match.group(1)] = label_match.group(2).strip()
        if (
            "epubCandidateAdmission" not in labeled_arguments
            and not re.match(r"\bExternalDocumentImportService", constructor.group(0))
        ):
            continue
        admission = labeled_arguments.get("epubCandidateAdmission", "")
        is_strict_factory = (
            relative_path
            == "Sources/BibleUI/Sources/BibleUI/Shared/ExternalDocumentImportService.swift"
            and _enclosing_swift_function_name(function_ranges, constructor.start())
            == "androidRegistryAware"
            and re.search(
                r"\blet\s+snapshot\s*=\s*try\s+"
                r"BibleReaderInstalledDocumentRegistrySnapshot\s*\.\s*capture\s*\(",
                admission,
            ) is not None
            and re.search(
                r"\bguard\s+snapshot\s*\.\s*admitsEpub\s*\(\s*candidate\s*\)"
                r"\s*else\s*\{[\s\S]*\bthrow\b",
                admission,
            ) is not None
        )
        if not is_strict_factory:
            matches.append(text.count("\n", 0, constructor.start()) + 1)

    audited_constructors = {
        (
            "Sources/BibleCore/Sources/BibleCore/AI/AIGeneratedPageStore.swift",
            "resolveOrCreateAIDocument",
        ),
        (
            "Sources/BibleCore/Sources/BibleCore/Database/MyDocumentLibraryStore.swift",
            "saveUnderExclusiveLease",
        ),
        (
            "Sources/BibleCore/Sources/BibleCore/Services/RemoteSyncMyDocumentRestoreService.swift",
            "stageLocalMyDocuments",
        ),
    }
    my_document_constructor = re.compile(
        r"(?:\bMyDocument\s*(?:\.\s*init)?\s*\(|:\s*MyDocument\s*=\s*\.\s*init\s*\()"
    )
    for constructor in my_document_constructor.finditer(masked_source):
        owner = (
            relative_path,
            _enclosing_swift_function_name(function_ranges, constructor.start()),
        )
        if owner not in audited_constructors:
            matches.append(text.count("\n", 0, constructor.start()) + 1)

    if relative_path.endswith("/MyDocumentStore.swift"):
        matches.extend(
            text.count("\n", 0, match.start()) + 1
            for match in re.finditer(
                r"savePendingGraphChanges\s*\([\s\S]*?modelContext\s*:\s*modelContext",
                masked_source,
            )
        )

    return sorted(set(matches))


def find_unshared_addon_feature_discovery(
    text: str,
    relative_path: str = "",
) -> list[int]:
    """Return lines that recreate feature/picker add-on discovery outside SwordKit admission.

    Comments and strings are masked; the helper performs no filesystem access or mutation. Prompt,
    font, WebView, and picker consumers may not enumerate or reopen raw installed modules, and helpers
    outside the explicit SwordKit infrastructure allowlist may not scan raw configs or request the
    unfiltered add-on category instead of consuming the shared compatibility/BookSet projection.
    """
    masked_source = _mask_swift_comments_and_strings(text)
    patterns: tuple[re.Pattern[str], ...] = ()
    required_function: str | None = None
    function_ranges = _swift_function_ranges(masked_source)
    raw_config_allowed_owners = {
        (
            "Sources/SwordKit/Sources/SwordKit/SwordManager.swift",
            "moduleConfigURL",
        ),
        (
            "Sources/SwordKit/Sources/SwordKit/SwordManager.swift",
            "nativeModuleRegistrySnapshot",
        ),
        (
            "Sources/SwordKit/Sources/SwordKit/SwordManager.swift",
            "androidCustomInstalledRegistrations",
        ),
        (
            "Sources/SwordKit/Sources/SwordKit/ModuleStoreTransactionPublisher+Uninstall.swift",
            "uninstall",
        ),
        (
            "Sources/SwordKit/Sources/SwordKit/ModuleStoreTransactionPublisher+Uninstall.swift",
            "uninstallInstalledAddon",
        ),
    }
    config_reader_names = {"SwordModuleConfig"}
    config_reader_names.update(
        match.group(1)
        for match in re.finditer(
            r"\btypealias\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
            r"(?:[A-Za-z_][A-Za-z0-9_]*\s*\.\s*)*SwordModuleConfig\b",
            masked_source,
        )
    )
    config_reader_pattern = re.compile(
        r"\b(?:" + "|".join(map(re.escape, sorted(config_reader_names)))
        + r")\s*\.\s*readAll\b"
    )
    matches = set()
    for match in config_reader_pattern.finditer(masked_source):
        owner = (
            relative_path,
            _enclosing_swift_function_name(function_ranges, match.start()),
        )
        if owner not in raw_config_allowed_owners:
            matches.add(text.count("\n", 0, match.start()) + 1)
    if not relative_path.endswith("/SwordManager.swift"):
        non_addon_category = (
            r"(?:ModuleCategory\s*\.\s*|\.\s*)?"
            r"(?:bible|commentary|dictionary|generalBook|map|dailyDevotion|glossary|"
            r"questionable|essays|images|unknown)\s*\)"
        )
        patterns += (
            re.compile(
                r"\.\s*installedModules\s*\(\s*category\s*:(?!\s*"
                + non_addon_category
                + r")\s*"
            ),
            re.compile(
                r"\.\s*installedModules\s*\([^)]*\)\s*\.\s*filter\b"
                r"[\s\S]{0,240}?\.\s*category\s*==\s*\.\s*addon\b"
            ),
        )
        for method_reference in re.finditer(
            r"\b(?:let|var)\s+([A-Za-z_][A-Za-z0-9_]*)"
            r"(?:\s*:[^=\n]+)?\s*=\s*"
            r"[A-Za-z_][A-Za-z0-9_]*(?:\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*"
            r"\s*\.\s*installedModules\b(?!\s*\()",
            masked_source,
        ):
            alias = method_reference.group(1)
            if re.search(
                rf"\b{re.escape(alias)}\s*\(",
                masked_source[method_reference.end():],
            ):
                matches.add(text.count("\n", 0, method_reference.start()) + 1)
    if relative_path.endswith("/PromptRepository.swift"):
        required_function = "loadPromptPacks"
        patterns += (
            re.compile(r"\binstalledModules\b"),
            re.compile(r"\bSwordModuleConfig\b"),
            re.compile(r"\bmodule\s*\(\s*named\s*:"),
            re.compile(r"\blocalizedCaseInsensitiveCompare\s*\("),
            re.compile(
                r"\b(?!admittedAddonModules\b)[A-Za-z_][A-Za-z0-9_]*addon[A-Za-z0-9_]*"
                r"\s*\(\s*swordManager\b",
                re.IGNORECASE,
            ),
        )
    elif relative_path.endswith("/BibleReaderModulePicker.swift"):
        required_function = "selectableAddonModules"
        patterns += (
            re.compile(
                r"\.\s*installedModules\s*\(\s*category\s*:\s*\.\s*addon\s*\)"
            ),
            re.compile(
                r"\binstalledModules\s*\([^)]*\)\s*\.\s*filter\b[\s\S]{0,240}?\.\s*addon\b"
            ),
        )

    matches.update(
        text.count("\n", 0, match.start()) + 1
        for pattern in patterns
        for match in pattern.finditer(masked_source)
    )
    if required_function is not None:
        required_function_ranges = [
            item for item in _swift_function_ranges(masked_source)
            if item[0] == required_function
        ]
        if not required_function_ranges:
            matches.add(1)
        else:
            _, start, end = required_function_ranges[-1]
            function_source = masked_source[start:end]
            if len(re.findall(r"\badmittedAddonModules\s*\(", function_source)) != 1:
                matches.add(text.count("\n", 0, start) + 1)
            forbidden_function_calls = (
                r"\binstalledModules\s*\(",
                r"\bSwordModuleConfig\b",
                r"\bmodule\s*\(\s*named\s*:",
                r"\b(?!admittedAddonModules\b|selectableAddonModules\b)"
                r"[A-Za-z_][A-Za-z0-9_]*addon[A-Za-z0-9_]*\s*\(",
            )
            for pattern in forbidden_function_calls:
                for match in re.finditer(pattern, function_source, re.IGNORECASE):
                    matches.add(text.count("\n", 0, start + match.start()) + 1)

    return sorted(matches)


def find_nonexact_module_identity_collections(
    text: str,
    relative_path: str = "",
) -> list[int]:
    """Return module-selection boundaries that regress to Swift canonical string identity.

    The check is path-specific and masks comments and literals. It requires the shared raw-UTF16
    collection/identity types at the Android module settings, Search, Downloads, and reader lookup
    boundaries, and rejects the former raw `Set<String>`, `[String: ModuleInfo]`, synthesized string
    hash, and SwiftUI string-ID shapes. The helper performs no filesystem access or mutation;
    missing required production markers fail closed at line one.
    """
    raw_name_set_patterns = (
        re.compile(
            r"\bSet\s*\(\s*[A-Za-z_][A-Za-z0-9_\.]*\s*\.\s*map\s*\(\s*"
            r"\\\s*\.\s*name\s*\)\s*\)"
        ),
        re.compile(
            r"\bSet\s*\(\s*[A-Za-z_][A-Za-z0-9_\.]*\s*\.\s*map\s*\{\s*"
            r"\$0\s*\.\s*name\b"
        ),
    )
    contracts: dict[str, tuple[tuple[str, ...], tuple[re.Pattern[str], ...]]] = {
        "Sources/SwordKit/Sources/SwordKit/SwordJavaStringIdentity.swift": (
            ("public struct SwordJavaExactStringSet",),
            (),
        ),
        "Sources/SwordKit/Sources/SwordKit/ModuleInfo.swift": (
            ("public struct ModuleInfo: Sendable",),
            (re.compile(r"\bModuleInfo\s*:[^{\n]*\bIdentifiable\b"),),
        ),
        "Sources/SwordKit/Sources/SwordKit/InstallManager.swift": (
            (
                "public var id: SwordJavaExactStringIdentity",
                "public var id: RemoteModuleIdentity",
            ),
            (re.compile(r"public\s+var\s+id\s*:\s*String\s*\{\s*name\s*\}"),),
        ),
        "Sources/SwordKit/Sources/SwordKit/ModuleRepository.swift": (
            (
                "public var id: SwordJavaExactStringIdentity",
                "public var id: RemoteModuleIdentity",
                "SwordJavaStringIdentity.equals($0.name, moduleName)",
                "SwordJavaStringIdentity.equals($0.name, sourceName)",
            ),
            (
                re.compile(r"public\s+var\s+id\s*:\s*String\s*\{[^}]*sourceName[^}]*name"),
                re.compile(r"\$0\s*\.\s*name\s*==\s*(?:moduleName|sourceName)\b"),
            ),
        ),
        "Sources/SwordKit/Sources/SwordKit/ModuleInstallationContracts.swift": (
            (
                "SwordJavaExactStringIdentity(lhs.repository)",
                "SwordJavaExactStringIdentity(lhs.initials)",
                "hasher.combine(SwordJavaExactStringIdentity(repository))",
                "hasher.combine(SwordJavaExactStringIdentity(initials))",
            ),
            (),
        ),
        "Sources/SwordKit/Sources/SwordKit/DefaultDocumentDownloadPlanner.swift": (
            ("SwordJavaExactStringSet", "SwordJavaStringIdentity.equals"),
            (re.compile(r"\bSet\s*<\s*String\s*>"), *raw_name_set_patterns),
        ),
        "Sources/BibleCore/Sources/BibleCore/Services/SearchSelectionPreferences.swift": (
            ("SwordJavaExactStringSet", "SwordJavaStringIdentity.equals"),
            (re.compile(r"\bSet\s*<\s*String\s*>|\bSet\s*\(\s*installedModuleNames"),),
        ),
        "Sources/BibleUI/Sources/BibleUI/Search/SearchTranslationSelectionPolicy.swift": (
            ("SwordJavaExactStringSet", "SwordJavaStringIdentity.equals"),
            (re.compile(r"\bSet\s*<\s*String\s*>"), *raw_name_set_patterns),
        ),
        "Sources/BibleUI/Sources/BibleUI/Search/SearchTranslationPickerDraftState.swift": (
            ("SwordJavaExactStringSet",),
            (re.compile(r"\bSet\s*<\s*String\s*>"),),
        ),
        "Sources/BibleUI/Sources/BibleUI/Search/SearchView.swift": (
            (
                "private var pendingTranslationSelectionIDs: Binding<Set<SwordJavaExactStringIdentity>>",
                "SwordJavaExactStringSet = []",
                "SwordJavaExactStringIdentity(module.name)",
            ),
            (
                re.compile(r"\b(?:selectedModules|pendingTranslationSelection)\s*:\s*Set\s*<\s*String\s*>"),
                re.compile(r"AndroidMultiselectDialogRow\s*<\s*String\s*>"),
                re.compile(r"\bid\s*:\s*module\.name\b"),
                *raw_name_set_patterns,
            ),
        ),
        "Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserView.swift": (
            (
                "typealias InstalledModuleLookup = [SwordJavaExactStringIdentity: ModuleInfo]",
                "Set<RemoteModuleIdentity>",
                "SwordJavaExactStringSet",
            ),
            (
                re.compile(r"\[\s*String\s*:\s*ModuleInfo\s*\]"),
                re.compile(r"failedSourceNames\s*:\s*Set\s*<\s*String\s*>"),
                re.compile(
                    r"\bDictionary\s*\(\s*uniqueKeysWithValues\s*:\s*"
                    r"[A-Za-z_][A-Za-z0-9_\.]*\s*\.\s*map\s*\{\s*\(\s*"
                    r"\$0\s*\.\s*name\s*,"
                ),
                *raw_name_set_patterns,
            ),
        ),
        "Sources/BibleUI/Sources/BibleUI/Downloads/ModuleBrowserRowActionPresentation.swift": (
            (
                "case remote(RemoteModuleIdentity)",
                "case installed(SwordJavaExactStringIdentity)",
                "let module: SwordJavaExactStringIdentity",
            ),
            (
                re.compile(r"var\s+id\s*:\s*String\s*\{[^}]*moduleName"),
                re.compile(r"let\s+id\s*:\s*String\b"),
            ),
        ),
        "Sources/BibleUI/Sources/BibleUI/Settings/SettingsView.swift": (
            (
                "SwordJavaExactStringSet = []",
                "Set<SwordJavaExactStringIdentity> = []",
                "AndroidMultiselectDialogRow<SwordJavaExactStringIdentity>",
            ),
            (
                re.compile(
                    r"\b(?:selectedStrongsGreekDictionaryNames|selectedStrongsHebrewDictionaryNames|"
                    r"selectedRobinsonMorphologyDictionaryNames|disabledWordLookupDictionaryNames)"
                    r"\s*:\s*Set\s*<\s*String\s*>"
                ),
                re.compile(r"AndroidMultiselectDialogRow\s*<\s*String\s*>[\s\S]{0,200}?dictionary"),
                *raw_name_set_patterns,
            ),
        ),
        "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderWordLookupDocumentBuilder.swift": (
            ("SwordJavaExactStringSet",),
            (re.compile(r"disabledDictionaryNames\s*:\s*Set\s*<\s*String\s*>"),),
        ),
        "Sources/BibleUI/Sources/BibleUI/Bible/BibleReaderStrongsDocumentBuilder.swift": (
            ("SwordJavaExactStringSet",),
            (re.compile(r"\bvar\s+seen\s*=\s*Set\s*<\s*String\s*>"),),
        ),
    }
    contract = contracts.get(relative_path)
    if contract is None:
        return []

    required_markers, forbidden_patterns = contract
    masked_source = _mask_swift_comments_and_strings(text)
    matches = {
        text.count("\n", 0, match.start()) + 1
        for pattern in forbidden_patterns
        for match in pattern.finditer(masked_source)
    }
    if any(marker not in masked_source for marker in required_markers):
        matches.add(1)
    return sorted(matches)


def find_ios_bundle_version_reads(
    text: str,
    relative_path: str = "",
) -> list[int]:
    """Return production lines that read iOS version keys outside display metadata.

    The raw key spellings are intentionally matched even in string literals because they are the
    Info.plist API inputs. The one display-metadata owner is allowlisted by exact repository path;
    every Android compatibility and backup producer must instead consume the shared pinned Android
    version-code authority. The helper performs no filesystem access or mutation.
    """
    if relative_path == (
        "Sources/BibleUI/Sources/BibleUI/Shared/AndBibleAppVersionMetadata.swift"
    ):
        return []
    return sorted({
        text.count("\n", 0, match.start()) + 1
        for pattern in (
            re.compile(r'"CFBundleVersion"'),
            re.compile(r'"CFBundleShortVersionString"'),
        )
        for match in pattern.finditer(text)
    })


def validate_source_guards(repo_root: Path) -> list[SourceGuardIssue]:
    """Validate static source contracts that should run outside XCTest.

    The guards keep the `ContentView` legacy root sidebar regression out of the app-host bundle,
    prevent production Swift sources from recreating direct EPUB/My Documents publication APIs that
    bypass Android-compatible global ownership admission, keep prompt/font/WebView/picker add-on
    discovery on SwordKit's shared installed BookSet projection, and preserve Java-exact module
    identity through settings, Search, Downloads, reader collections, and row IDs. Missing
    fixed-path files fail closed, and the publisher/add-on scans follow every non-test Swift file
    under `Sources` and `AndBible` across moves while narrowing infrastructure exceptions to audited
    functions. iOS marketing/build metadata access remains confined to its display-only owner so
    Android manifests and admission cannot reuse unrelated bundle version values.
    """
    content_view_path = repo_root / "AndBible/ContentView.swift"
    relative_path = "AndBible/ContentView.swift"
    issues: list[SourceGuardIssue] = []

    if not content_view_path.exists():
        issues.append(
            SourceGuardIssue(
                path=relative_path,
                line=1,
                message=(
                    "Could not locate AndBible/ContentView.swift. Update the static source guard "
                    "if the project layout changes."
                ),
            )
        )
    else:
        source = content_view_path.read_text(encoding="utf-8")
        issues.extend(
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
        )

    for source_root_name in ("Sources", "AndBible"):
        sources_root = repo_root / source_root_name
        if not sources_root.exists():
            continue
        for path in sorted(sources_root.rglob("*.swift")):
            relative = path.relative_to(repo_root)
            if "Tests" in relative.parts:
                continue
            source = path.read_text(encoding="utf-8")
            issues.extend(
                SourceGuardIssue(
                    path=str(relative),
                    line=line,
                    message=(
                        "Production source declares a direct EPUB/My Documents publisher outside "
                        "the shared global mutation and Android ownership-admission boundary."
                    ),
                )
                for line in find_unsafe_direct_document_publishers(source, str(relative))
            )
            issues.extend(
                SourceGuardIssue(
                    path=str(relative),
                    line=line,
                    message=(
                        "Production add-on feature/picker code bypasses SwordKit's shared Android "
                        "compatibility and installed BookSet projection."
                    ),
                )
                for line in find_unshared_addon_feature_discovery(source, str(relative))
            )
            issues.extend(
                SourceGuardIssue(
                    path=str(relative),
                    line=line,
                    message=(
                        "Android module identity regressed to Swift canonical String collection, "
                        "lookup, comparison, or SwiftUI row-ID semantics."
                    ),
                )
                for line in find_nonexact_module_identity_collections(source, str(relative))
            )
            issues.extend(
                SourceGuardIssue(
                    path=str(relative),
                    line=line,
                    message=(
                        "Production code reads iOS bundle version metadata outside the display "
                        "metadata owner. Android compatibility and backup manifests must consume "
                        "AndBibleAndroidCompatibility instead."
                    ),
                )
                for line in find_ios_bundle_version_reads(source, str(relative))
            )

    return issues


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
