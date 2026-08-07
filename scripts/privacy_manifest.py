"""Check the app's privacy manifest against the required-reason APIs it actually uses.

Apple rejects an upload that reaches a "required reason" API without declaring why in
`PrivacyInfo.xcprivacy` (`ITMS-91053`). Two things can go wrong and neither shows up in a
normal build: the manifest can omit a category the code started using, and the manifest can
stop being a member of the app target's resources, at which point it ships nowhere while
still sitting in the source tree.

Everything here is pure: scanning returns data, the CLI (`check_privacy_manifest.py`) is the
only part that prints or exits.
"""

from __future__ import annotations

import plistlib
import re
from dataclasses import dataclass
from pathlib import Path

MANIFEST_RELATIVE_PATH = Path("AndBible/PrivacyInfo.xcprivacy")
PROJECT_RELATIVE_PATH = Path("AndBible.xcodeproj/project.pbxproj")

# Source roots holding first-party Swift. Test code is excluded: a required-reason API used
# only by a test never ships, and declaring a reason for it would overstate what the app does.
SOURCE_ROOTS = (Path("Sources"), Path("AndBible"))

# Apple's required-reason API categories, and the symbols that reach each one. Only categories
# this project could plausibly use are listed; an unused category simply never matches.
CATEGORY_SYMBOLS: dict[str, tuple[str, ...]] = {
    "NSPrivacyAccessedAPICategoryUserDefaults": ("UserDefaults",),
    "NSPrivacyAccessedAPICategoryDiskSpace": (
        "volumeAvailableCapacityForImportantUsage",
        "volumeAvailableCapacity",
        "systemFreeSize",
        "statfs",
    ),
    "NSPrivacyAccessedAPICategoryFileTimestamp": (
        "contentModificationDate",
        "ContentModificationDateKey",
        "modificationDate",
        "creationDate",
    ),
    "NSPrivacyAccessedAPICategorySystemBootTime": (
        "systemUptime",
        "mach_absolute_time",
    ),
    "NSPrivacyAccessedAPICategoryActiveKeyboards": ("activeInputModes",),
}


@dataclass(frozen=True)
class Usage:
    """One required-reason API category, and where in the source it is reached."""

    category: str
    evidence: tuple[str, ...]


def swift_sources(repo_root: Path) -> list[Path]:
    """Every first-party Swift file that ships, excluding test targets and build output."""
    files: list[Path] = []
    for root in SOURCE_ROOTS:
        directory = repo_root / root
        if not directory.is_dir():
            continue
        files.extend(
            path
            for path in directory.rglob("*.swift")
            if "/Tests/" not in str(path) and "/.build/" not in str(path)
        )
    return sorted(files)


def find_usages(repo_root: Path) -> list[Usage]:
    """Return every required-reason category the shipping Swift sources reach.

    Matching is by whole word so that `creationDate` does not also match a longer identifier
    that merely contains it. Evidence is recorded as `path:line` for the failure message: a
    bare category name gives no way to judge which reason code belongs to it.
    """
    patterns = {
        category: re.compile(r"\b(?:" + "|".join(map(re.escape, symbols)) + r")\b")
        for category, symbols in CATEGORY_SYMBOLS.items()
    }
    hits: dict[str, list[str]] = {category: [] for category in CATEGORY_SYMBOLS}
    for path in swift_sources(repo_root):
        text = path.read_text(encoding="utf-8", errors="replace")
        for index, line in enumerate(text.splitlines(), start=1):
            for category, pattern in patterns.items():
                if pattern.search(line):
                    relative = path.relative_to(repo_root)
                    hits[category].append(f"{relative}:{index}")
    return [
        Usage(category=category, evidence=tuple(evidence[:3]))
        for category, evidence in sorted(hits.items())
        if evidence
    ]


def load_manifest(repo_root: Path) -> dict:
    """Read and parse `PrivacyInfo.xcprivacy`."""
    return plistlib.loads((repo_root / MANIFEST_RELATIVE_PATH).read_bytes())


def declared_reasons(manifest: dict) -> dict[str, list[str]]:
    """Map each declared API category to its reason codes."""
    return {
        str(entry.get("NSPrivacyAccessedAPIType")): list(
            entry.get("NSPrivacyAccessedAPITypeReasons") or []
        )
        for entry in manifest.get("NSPrivacyAccessedAPITypes") or []
    }


def manifest_is_in_app_resources(repo_root: Path) -> bool:
    """Whether the manifest is a member of the app target's Copy Bundle Resources phase.

    A file reference alone is not enough - Xcode will happily keep an unreferenced file in the
    navigator - so this looks for the build-file entry that puts it `in Resources`.
    """
    project = (repo_root / PROJECT_RELATIVE_PATH).read_text(encoding="utf-8")
    return bool(
        re.search(
            r"/\* PrivacyInfo\.xcprivacy in Resources \*/ = \{isa = PBXBuildFile",
            project,
        )
    )


def validate(repo_root: Path) -> list[str]:
    """Return every problem found. An empty list means the manifest is consistent."""
    problems: list[str] = []

    manifest_path = repo_root / MANIFEST_RELATIVE_PATH
    if not manifest_path.is_file():
        return [f"{MANIFEST_RELATIVE_PATH}: missing (Apple requires a privacy manifest)"]

    try:
        manifest = load_manifest(repo_root)
    except Exception as error:  # plistlib raises several unrelated types
        return [f"{MANIFEST_RELATIVE_PATH}: not a readable plist ({error})"]

    if not manifest_is_in_app_resources(repo_root):
        problems.append(
            f"{MANIFEST_RELATIVE_PATH} is not in the app target's Copy Bundle Resources "
            "phase, so it would not ship inside AndBible.app"
        )

    if manifest.get("NSPrivacyTracking") is not False:
        problems.append(
            f"{MANIFEST_RELATIVE_PATH}: NSPrivacyTracking must be explicitly false"
        )

    reasons = declared_reasons(manifest)
    for usage in find_usages(repo_root):
        if usage.category not in reasons:
            problems.append(
                f"{usage.category} is reached by shipping code but not declared: "
                + ", ".join(usage.evidence)
            )
        elif not reasons[usage.category]:
            problems.append(f"{usage.category} is declared with no reason code")

    used = {usage.category for usage in find_usages(repo_root)}
    for category in sorted(set(reasons) - used):
        problems.append(
            f"{category} is declared but no shipping code reaches it; remove it rather "
            "than overstating what the app does"
        )

    return problems
