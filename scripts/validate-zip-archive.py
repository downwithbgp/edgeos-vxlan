#!/usr/bin/env python3
"""Validate and safely extract a GitHub Actions artifact ZIP.

Rejects unsafe/ambiguous archives before extraction: traversal or absolute
names, duplicate names, symlinks/non-regular entries, encrypted entries,
setuid/setgid bits, excessive decompressed size, and non-empty destinations.
"""

from __future__ import annotations

import argparse
import os
import stat
import sys
import zipfile
from pathlib import Path, PurePosixPath


class ArchiveError(Exception):
    pass


def fail(message: str) -> None:
    raise ArchiveError(message)


def safe_name(raw: str) -> str:
    if "\x00" in raw:
        fail("archive member contains a NUL byte")
    if "\\" in raw:
        fail(f"archive member uses a backslash: {raw!r}")
    path = PurePosixPath(raw)
    if path.is_absolute():
        fail(f"archive member is absolute: {raw!r}")
    parts = [part for part in path.parts if part not in ("", ".")]
    if not parts:
        fail(f"archive member has an empty path: {raw!r}")
    if any(part == ".." for part in parts):
        fail(f"archive member escapes the destination: {raw!r}")
    return "/".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True)
    parser.add_argument("--destination", required=True)
    parser.add_argument(
        "--max-uncompressed-bytes",
        type=int,
        default=2 * 1024 * 1024 * 1024,
    )
    args = parser.parse_args()

    archive = Path(args.archive)
    destination = Path(args.destination)
    if not archive.is_file():
        fail(f"archive not found: {archive}")
    if destination.exists():
        if not destination.is_dir():
            fail(f"destination is not a directory: {destination}")
        if any(destination.iterdir()):
            fail(f"destination is not empty: {destination}")
    else:
        destination.mkdir(parents=True)

    destination_resolved = destination.resolve()
    seen: set[str] = set()
    entries: list[tuple[zipfile.ZipInfo, str]] = []
    total = 0

    try:
        with zipfile.ZipFile(archive) as bundle:
            infos = bundle.infolist()
            if not infos:
                fail("archive is empty")

            for info in infos:
                name = safe_name(info.filename)
                folded = name.casefold()
                if folded in seen:
                    fail(f"duplicate archive member: {name}")
                seen.add(folded)

                if info.flag_bits & 0x1:
                    fail(f"encrypted archive member: {name}")

                mode = (info.external_attr >> 16) & 0xFFFF
                if mode:
                    file_type = stat.S_IFMT(mode)
                    if file_type == stat.S_IFLNK:
                        fail(f"symlink archive member: {name}")
                    if file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
                        fail(f"non-regular archive member: {name}")
                    if mode & 0o7000:
                        fail(f"archive member has setuid/setgid/sticky bits: {name}")

                if info.is_dir():
                    continue
                if info.file_size < 0:
                    fail(f"archive member has an invalid size: {name}")
                total += info.file_size
                if total > args.max_uncompressed_bytes:
                    fail(
                        "archive decompressed size exceeds limit "
                        f"{args.max_uncompressed_bytes}: {total}"
                    )

                target = (destination / name).resolve()
                try:
                    target.relative_to(destination_resolved)
                except ValueError:
                    fail(f"archive member escapes the destination: {name}")
                entries.append((info, name))

            for info, name in entries:
                target = destination / name
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.open(info) as source, target.open("wb") as output:
                    while True:
                        chunk = source.read(1024 * 1024)
                        if not chunk:
                            break
                        output.write(chunk)
                mode = (info.external_attr >> 16) & 0o777
                os.chmod(target, mode if mode else 0o644)

    except (zipfile.BadZipFile, OSError) as exc:
        fail(f"invalid archive: {exc}")

    print(f"Artifact archive: PASS ({len(entries)} files, {total} bytes uncompressed)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ArchiveError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
