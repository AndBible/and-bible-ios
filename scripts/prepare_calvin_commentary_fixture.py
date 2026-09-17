#!/usr/bin/env python3
"""Compose the repository KJV fixture with the reviewed Calvin commentary module."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import stat
import zipfile
from pathlib import Path, PurePosixPath

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BASE_SWORD = (
    REPOSITORY_ROOT / "Sources/BibleUI/Tests/BibleUITests/Fixtures/sword"
)
ARCHIVE_SHA256 = "df66fc8c03537499ad006d069481d2c95b600887cdbd6ce75ec5d264b573192a"
ARCHIVE_BYTES = 20_897_508
SOURCE_PAGE = "https://www.crosswire.org/sword/modules/ModInfo.jsp?modName=CalvinCommentaries"
ARCHIVE_URL = "https://www.crosswire.org/ftpmirror/pub/sword/packages/rawzip/CalvinCommentaries.zip"
CALVIN_ENTRIES = {
    "mods.d/calvincommentaries.conf",
    "modules/comments/zcom/calvincommentaries/nt.bzs",
    "modules/comments/zcom/calvincommentaries/nt.bzv",
    "modules/comments/zcom/calvincommentaries/nt.bzz",
    "modules/comments/zcom/calvincommentaries/ot.bzs",
    "modules/comments/zcom/calvincommentaries/ot.bzv",
    "modules/comments/zcom/calvincommentaries/ot.bzz",
}


def sha256(path: Path) -> str:
    """Return the SHA-256 digest of one regular file."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def file_tree(root: Path) -> dict[str, str]:
    """Return deterministic relative file hashes below one fixture root."""
    return {
        str(path.relative_to(root)): sha256(path)
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def main() -> int:
    """Validate the supplied archive and materialize one new composite fixture."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--record", required=True, type=Path)
    parser.add_argument("--base-sword", type=Path, default=DEFAULT_BASE_SWORD)
    arguments = parser.parse_args()

    archive = arguments.archive.resolve()
    output = arguments.output.resolve()
    record = arguments.record.resolve()
    base_sword = arguments.base_sword.resolve()
    if output.exists() or record.exists():
        raise ValueError("--output and --record must both name new paths")
    if not (base_sword / "mods.d/kjv.conf").is_file():
        raise ValueError("base SWORD fixture does not contain mods.d/kjv.conf")
    if archive.stat().st_size != ARCHIVE_BYTES or sha256(archive) != ARCHIVE_SHA256:
        raise ValueError("archive does not match the reviewed CalvinCommentaries 1.1 input")

    with zipfile.ZipFile(archive) as bundle:
        members = {member.filename: member for member in bundle.infolist()}
        if set(members) != CALVIN_ENTRIES:
            raise ValueError("archive entry set differs from the reviewed seven-file module")
        for name, member in members.items():
            relative_path = PurePosixPath(name)
            unix_mode = member.external_attr >> 16
            if relative_path.is_absolute() or ".." in relative_path.parts or stat.S_ISLNK(unix_mode):
                raise ValueError(f"unsafe archive entry: {name}")

        shutil.copytree(base_sword, output, symlinks=False)
        for name in sorted(CALVIN_ENTRIES):
            destination = output.joinpath(*PurePosixPath(name).parts)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(bundle.read(name))

    record.parent.mkdir(parents=True, exist_ok=True)
    record.write_text(
        json.dumps(
            {
                "archive": str(archive),
                "archive_bytes": ARCHIVE_BYTES,
                "archive_sha256": ARCHIVE_SHA256,
                "archive_url": ARCHIVE_URL,
                "base_sword": str(base_sword),
                "base_sword_files": file_tree(base_sword),
                "calvin_entries": sorted(CALVIN_ENTRIES),
                "output": str(output),
                "output_files": file_tree(output),
                "script_sha256": sha256(Path(__file__)),
                "source_page": SOURCE_PAGE,
                "status": "completed",
            },
            indent=2,
            sort_keys=True,
        )
        + "\n"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
