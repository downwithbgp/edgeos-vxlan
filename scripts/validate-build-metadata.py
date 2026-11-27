#!/usr/bin/env python3
"""Validate Debian .buildinfo and .changes files against the candidate.

Checks the source/version/architecture/package set, artifact sizes and
checksums, build-dependency inventory, and SOURCE_DATE_EPOCH. Independent
builds are not required to produce byte-identical metadata.
"""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from pathlib import Path


class MetadataError(Exception):
    pass


def fail(message: str) -> None:
    raise MetadataError(message)


def parse_deb822(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    key = None
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.strip():
            continue
        if line[0] in " \t":
            if key is None:
                fail(f"{path}: continuation line without a field")
            fields[key] += "\n" + line.strip()
        else:
            if ":" not in line:
                fail(f"{path}: malformed field line: {line!r}")
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
    return fields


def run(cmd: list[str]) -> str:
    result = subprocess.run(cmd, check=True, text=True, capture_output=True)
    return result.stdout.strip()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_checksums(field: str, path: Path) -> list[tuple[str, int, str]]:
    entries = []
    for line in field.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) != 3:
            fail(f"{path}: malformed checksum line: {line!r}")
        checksum, size, name = parts
        if len(checksum) != 64 or any(c not in "0123456789abcdef" for c in checksum):
            fail(f"{path}: invalid SHA-256: {checksum}")
        try:
            size_int = int(size)
        except ValueError:
            fail(f"{path}: invalid size: {size}")
        entries.append((checksum, size_int, name))
    return entries


def verify_entries(
    artifact_dir: Path,
    entries: list[tuple[str, int, str]],
    expected: set[str],
    label: str,
) -> None:
    names = [name for _, _, name in entries]
    if sorted(names) != sorted(expected):
        fail(
            f"{label} lists {sorted(names)}, expected {sorted(expected)}"
        )
    for checksum, size, name in entries:
        path = artifact_dir / name
        if not path.is_file():
            fail(f"{label} references missing file: {name}")
        if path.stat().st_size != size:
            fail(f"{label} size mismatch for {name}")
        if sha256_file(path) != checksum:
            fail(f"{label} checksum mismatch for {name}")


def control_build_depends(source_root: Path) -> list[str]:
    control = source_root / "debian/control"
    fields = parse_deb822(control)
    raw = fields.get("Build-Depends", "")
    names = []
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        name = item.split("(", 1)[0].strip().split()[0]
        if name and name not in names:
            names.append(name)
    return names


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact_dir")
    parser.add_argument("source_root")
    args = parser.parse_args()

    artifact_dir = Path(args.artifact_dir)
    source_root = Path(args.source_root)
    try:
        version = run(
            [
                "dpkg-parsechangelog",
                "-l",
                str(source_root / "debian/changelog"),
                "-S",
                "Version",
            ]
        )
        epoch = int(
            run(
                [
                    "dpkg-parsechangelog",
                    "-l",
                    str(source_root / "debian/changelog"),
                    "-S",
                    "Timestamp",
                ]
            )
        )
        integration = f"edgeos-vxlan_{version}_all.deb"
        kmod = f"edgeos-vxlan-kmod_{version}_mipsel.deb"
        buildinfo_name = f"edgeos-vxlan_{version}_mipsel.buildinfo"
        changes_name = f"edgeos-vxlan_{version}_mipsel.changes"

        buildinfo = artifact_dir / buildinfo_name
        changes = artifact_dir / changes_name
        if not buildinfo.is_file():
            fail(f"missing buildinfo: {buildinfo_name}")
        if not changes.is_file():
            fail(f"missing changes: {changes_name}")

        info = parse_deb822(buildinfo)
        chg = parse_deb822(changes)

        if info.get("Format") != "1.0":
            fail(f"buildinfo Format is not 1.0: {info.get('Format')}")
        if chg.get("Format") != "1.8":
            fail(f"changes Format is not 1.8: {chg.get('Format')}")
        if info.get("Source") != "edgeos-vxlan":
            fail(f"buildinfo Source mismatch: {info.get('Source')}")
        if chg.get("Source") != "edgeos-vxlan":
            fail(f"changes Source mismatch: {chg.get('Source')}")
        if info.get("Version") != version:
            fail(f"buildinfo Version mismatch: {info.get('Version')}")
        if chg.get("Version") != version:
            fail(f"changes Version mismatch: {chg.get('Version')}")
        for label, fields in (("buildinfo", info), ("changes", chg)):
            binaries = set(fields.get("Binary", "").split())
            if binaries != {"edgeos-vxlan", "edgeos-vxlan-kmod"}:
                fail(f"{label} Binary set is {sorted(binaries)}")
            archs = set(fields.get("Architecture", "").split())
            if archs != {"all", "mipsel"}:
                fail(f"{label} Architecture set is {sorted(archs)}")

        verify_entries(
            artifact_dir,
            parse_checksums(info.get("Checksums-Sha256", ""), buildinfo),
            {integration, kmod},
            "buildinfo Checksums-Sha256",
        )
        verify_entries(
            artifact_dir,
            parse_checksums(chg.get("Checksums-Sha256", ""), changes),
            {integration, kmod, buildinfo_name},
            "changes Checksums-Sha256",
        )
        verify_entries(
            artifact_dir,
            parse_checksums(chg.get("Checksums-Sha256", ""), changes),
            {integration, kmod, buildinfo_name},
            "changes Checksums-Sha256",
        )

        installed = info.get("Installed-Build-Depends", "")
        if not installed.strip():
            fail("buildinfo has no Installed-Build-Depends")
        for name in control_build_depends(source_root):
            if name not in installed:
                fail(f"Installed-Build-Depends does not mention {name}")

        environment = info.get("Environment", "")
        if environment:
            import re

            match = re.search(r'SOURCE_DATE_EPOCH="([0-9]+)"', environment)
            if match and int(match.group(1)) != epoch:
                fail(
                    "buildinfo SOURCE_DATE_EPOCH does not match the changelog "
                    f"timestamp: {match.group(1)} != {epoch}"
                )
        else:
            fail("buildinfo has no Environment field")

        print("Build metadata: PASS")
        print(f"Version:        {version}")
        print(f"Buildinfo:      {buildinfo_name}")
        print(f"Changes:        {changes_name}")
        return 0
    except (MetadataError, subprocess.CalledProcessError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
