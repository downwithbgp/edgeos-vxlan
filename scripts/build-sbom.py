#!/usr/bin/env python3
"""Deterministic SPDX 2.3 SBOM builder and validator for edgeos-vxlan.

The SBOM is generated from the actual Debian payload, the source package's
control/copyright/changelog, and the known kernel-module provenance. It
deliberately does not claim a source-to-binary relationship for the prebuilt
kernel modules, whose independent recompilation is out of scope.

Runtime: host/CI Python 3 standard library plus dpkg-deb and
dpkg-parsechangelog. The controlled build image does not run this script.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

TOOL = "Tool: edgeos-vxlan-sbom-builder-1.0"
DOCUMENT_NAMESPACE = "https://edgeos-vxlan.dev/spdx"
GPL_ARCHIVE = "GPL.mtk.v3.0.0-rc.9.5753457.tar.bz2"
GPL_ARCHIVE_SHA256 = (
    "4f2ba6fd6b8655582e9090bbc1da96c656cd46841992376811a014970b149fb9"
)
KERNEL_ARCHIVE = "source/kernel_5753457-g001c7c22e530.tgz"
CVE_PATCH = "patches/4.14.54-UBNT/CVE-2022-50405.patch"


class SbomError(Exception):
    pass


def fail(message: str) -> None:
    raise SbomError(message)


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, text=True, **kwargs)


def sha1_bytes(data: bytes) -> str:
    return hashlib.sha1(data).hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha1_file(path: Path) -> str:
    return sha1_bytes(path.read_bytes())


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def spdx_id(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9.-]+", "-", value).strip("-")
    if not cleaned:
        fail(f"cannot derive an SPDX identifier from {value!r}")
    return cleaned


def dpkg_field(package: Path, field: str) -> str:
    result = run(["dpkg-deb", "-f", str(package), field], capture_output=True)
    return result.stdout.strip()


def extract_package(package: Path, destination: Path) -> None:
    run(["dpkg-deb", "-x", str(package), str(destination)])


def package_files(root: Path) -> list[Path]:
    files = []
    for path in root.rglob("*"):
        if path.is_symlink():
            fail(f"symlink payload files are not supported: {path}")
        if path.is_file():
            files.append(path)
    return sorted(files, key=lambda p: p.relative_to(root).as_posix())


def parse_dependencies(field: str) -> list[tuple[str, str | None]]:
    dependencies: list[tuple[str, str | None]] = []
    for item in field.split(","):
        item = item.strip()
        if not item:
            continue
        match = re.match(r"^([A-Za-z0-9+.-]+)(?::[A-Za-z0-9-]+)?(?:\s*\(([^)]*)\))?", item)
        if not match:
            continue
        name = match.group(1)
        version = match.group(2)
        if version:
            version = re.sub(r"^(>=|<=|=|>>|<<)\s*", "", version).strip()
        dependencies.append((name, version))
    return dependencies


def changelog_version(source_root: Path) -> str:
    result = run(
        ["dpkg-parsechangelog", "-l", str(source_root / "debian/changelog"), "-S", "Version"],
        capture_output=True,
    )
    return result.stdout.strip()


def changelog_timestamp(source_root: Path) -> int:
    result = run(
        ["dpkg-parsechangelog", "-l", str(source_root / "debian/changelog"), "-S", "Timestamp"],
        capture_output=True,
    )
    return int(result.stdout.strip())


def source_license(source_root: Path) -> str:
    copyright_file = source_root / "debian/copyright"
    if not copyright_file.is_file():
        return "NOASSERTION"
    licenses = []
    for line in copyright_file.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("License:"):
            value = line.split(":", 1)[1].strip()
            if value and value not in licenses:
                licenses.append(value)
    return licenses[0] if licenses else "NOASSERTION"


def file_type(name: str) -> str:
    if name.endswith(".ko"):
        return "BINARY"
    if name.endswith((".sh", ".pm", ".def")) or "/sbin/" in name:
        return "SOURCE"
    if name.endswith((".gz", "copyright", "changelog")):
        return "DOCUMENTATION"
    return "OTHER"


def purl(name: str, version: str, arch: str) -> str:
    return f"pkg:deb/edgeos-vxlan/{name}@{version}?arch={arch}"


def created_timestamp(epoch: int) -> str:
    return dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def package_verification_code(files: list[dict]) -> str:
    digest = hashlib.sha1()
    for value in sorted(f["checksums"][0]["checksumValue"] for f in files):
        digest.update(value.encode("ascii"))
    return digest.hexdigest()


def make_document(args: argparse.Namespace) -> dict:
    package = Path(args.package)
    source_root = Path(args.source_root)
    if not package.is_file():
        fail(f"package not found: {package}")
    if not (source_root / "debian/changelog").is_file():
        fail(f"source root has no debian/changelog: {source_root}")

    name = dpkg_field(package, "Package")
    version = dpkg_field(package, "Version")
    arch = dpkg_field(package, "Architecture")
    depends = " ".join(
        filter(None, [dpkg_field(package, "Pre-Depends"), dpkg_field(package, "Depends")])
    )
    source_version = changelog_version(source_root)
    if version != source_version:
        fail(f"package version {version} != source version {source_version}")

    epoch = args.source_date_epoch
    if epoch is None:
        epoch = changelog_timestamp(source_root)
    created = created_timestamp(epoch)
    commit = args.source_commit
    if not commit:
        commit = run(
            ["git", "-C", str(source_root), "rev-parse", "HEAD"], capture_output=True
        ).stdout.strip()
    if not re.fullmatch(r"[0-9a-f]{40}([0-9a-f]{24})?", commit or ""):
        fail(f"invalid source commit: {commit}")

    license_id = source_license(source_root)
    package_sha256 = sha256_file(package)
    package_id = f"SPDXRef-Package-{spdx_id(name)}-{spdx_id(version)}-{spdx_id(arch)}"
    source_id = f"SPDXRef-Package-source-{spdx_id(name)}-{spdx_id(version)}"
    namespace = f"{DOCUMENT_NAMESPACE}/{commit}/{spdx_id(name)}/{package_sha256}"

    with tempfile.TemporaryDirectory(prefix="edgeos-vxlan-sbom.") as tmp:
        payload_root = Path(tmp) / "payload"
        payload_root.mkdir()
        extract_package(package, payload_root)
        payload_files = package_files(payload_root)

        files = []
        file_ids = []
        for index, path in enumerate(payload_files):
            relative = "./" + path.relative_to(payload_root).as_posix()
            data = path.read_bytes()
            file_id = f"SPDXRef-File-{index:04d}-{spdx_id(path.name)}"
            file_ids.append((file_id, relative))
            files.append(
                {
                    "SPDXID": file_id,
                    "fileName": relative,
                    "fileTypes": [file_type(relative)],
                    "checksums": [
                        {"algorithm": "SHA1", "checksumValue": sha1_bytes(data)},
                        {"algorithm": "SHA256", "checksumValue": sha256_bytes(data)},
                    ],
                    "licenseConcluded": license_id,
                    "licenseInfoInFiles": [license_id],
                    "copyrightText": "NOASSERTION",
                }
            )

        packages = [
            {
                "SPDXID": source_id,
                "name": name,
                "versionInfo": version,
                "supplier": "Organization: downwithbgp",
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": license_id,
                "licenseDeclared": license_id,
                "copyrightText": "NOASSERTION",
                "sourceInfo": f"Source package built from commit {commit}",
            },
            {
                "SPDXID": package_id,
                "name": name,
                "versionInfo": version,
                "supplier": "Organization: downwithbgp",
                "originator": "Organization: downwithbgp",
                "downloadLocation": (
                    f"https://github.com/{args.repository}/releases/download/"
                    f"{args.release_tag}/{package.name}"
                    if args.release_tag
                    else "NOASSERTION"
                ),
                "filesAnalyzed": True,
                "packageVerificationCode": {
                    "packageVerificationCodeValue": package_verification_code(files)
                },
                "checksums": [
                    {"algorithm": "SHA256", "checksumValue": package_sha256}
                ],
                "primaryPackagePurpose": "APPLICATION"
                if name == "edgeos-vxlan"
                else "LIBRARY",
                "licenseConcluded": license_id,
                "licenseDeclared": license_id,
                "licenseInfoFromFiles": [license_id],
                "copyrightText": "NOASSERTION",
                "externalRefs": [
                    {
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceType": "purl",
                        "referenceLocator": purl(name, version, arch),
                    }
                ],
            },
        ]

        relationships = [
            {
                "spdxElementId": "SPDXRef-DOCUMENT",
                "relationshipType": "DESCRIBES",
                "relatedSpdxElement": package_id,
            },
        ]
        if name == "edgeos-vxlan-kmod":
            relationships.append(
                {
                    "spdxElementId": package_id,
                    "relationshipType": "OTHER",
                    "relatedSpdxElement": source_id,
                    "comment": (
                        "Binary package assembled from the source package; "
                        "the kernel module source-to-binary relationship is "
                        "explicitly unverified and is not a GENERATED_FROM claim."
                    ),
                }
            )
        else:
            relationships.append(
                {
                    "spdxElementId": package_id,
                    "relationshipType": "GENERATED_FROM",
                    "relatedSpdxElement": source_id,
                }
            )

        for file_id, _relative in file_ids:
            relationships.append(
                {
                    "spdxElementId": package_id,
                    "relationshipType": "CONTAINS",
                    "relatedSpdxElement": file_id,
                }
            )

        seen_deps = set()
        for dep_name, dep_version in parse_dependencies(depends):
            key = (dep_name, dep_version)
            if key in seen_deps:
                continue
            seen_deps.add(key)
            dep_id = f"SPDXRef-Package-dependency-{spdx_id(dep_name)}-{spdx_id(dep_version or 'any')}"
            packages.append(
                {
                    "SPDXID": dep_id,
                    "name": dep_name,
                    "versionInfo": dep_version or "NOASSERTION",
                    "supplier": "NOASSERTION",
                    "downloadLocation": "NOASSERTION",
                    "filesAnalyzed": False,
                    "licenseConcluded": "NOASSERTION",
                    "licenseDeclared": "NOASSERTION",
                    "copyrightText": "NOASSERTION",
                }
            )
            relationships.append(
                {
                    "spdxElementId": package_id,
                    "relationshipType": "DEPENDS_ON",
                    "relatedSpdxElement": dep_id,
                }
            )

        annotations = [
            {
                "annotationDate": created,
                "annotationType": "OTHER",
                "annotator": TOOL,
                "comment": (
                    "Build-environment dependencies are intentionally excluded "
                    "from this release SBOM; see the image SBOM."
                ),
            },
            {
                "annotationDate": created,
                "annotationType": "OTHER",
                "annotator": TOOL,
                "comment": (
                    "Debian dependency relationships are direct relationships "
                    "from the package control metadata; transitive dependencies "
                    "are not resolved here."
                ),
            },
        ]

        if name == "edgeos-vxlan-kmod":
            kernel_id = "SPDXRef-Package-kernel-4.14.54-UBNT"
            packages.append(
                {
                    "SPDXID": kernel_id,
                    "name": "linux-4.14.54-UBNT",
                    "versionInfo": "4.14.54-UBNT",
                    "supplier": "NOASSERTION",
                    "downloadLocation": "NOASSERTION",
                    "filesAnalyzed": False,
                    "licenseConcluded": "GPL-2.0-only",
                    "licenseDeclared": "GPL-2.0-only",
                    "copyrightText": "NOASSERTION",
                    "comment": (
                        "Ubiquiti EdgeOS GPL source archive "
                        f"{GPL_ARCHIVE} SHA-256 {GPL_ARCHIVE_SHA256}; "
                        f"inner kernel archive {KERNEL_ARCHIVE}; "
                        f"security patch {CVE_PATCH}. The packaged module "
                        "binaries are prebuilt inputs. Phase III does not "
                        "establish a source-to-binary reproducibility "
                        "relationship and makes no such claim."
                    ),
                }
            )
            relationships.append(
                {
                    "spdxElementId": package_id,
                    "relationshipType": "OTHER",
                    "relatedSpdxElement": kernel_id,
                    "comment": (
                        "Prebuilt kernel module payload; source-to-binary "
                        "relationship is explicitly unverified."
                    ),
                }
            )
            patch = source_root / CVE_PATCH
            if patch.is_file():
                patch_data = patch.read_bytes()
                patch_id = "SPDXRef-File-CVE-2022-50405.patch"
                files.append(
                    {
                        "SPDXID": patch_id,
                        "fileName": "./" + CVE_PATCH,
                        "fileTypes": ["SOURCE"],
                        "checksums": [
                            {"algorithm": "SHA1", "checksumValue": sha1_bytes(patch_data)},
                            {"algorithm": "SHA256", "checksumValue": sha256_bytes(patch_data)},
                        ],
                        "licenseConcluded": "NOASSERTION",
                        "licenseInfoInFiles": ["NOASSERTION"],
                        "copyrightText": "NOASSERTION",
                    }
                )
                relationships.append(
                    {
                        "spdxElementId": package_id,
                        "relationshipType": "OTHER",
                        "relatedSpdxElement": patch_id,
                        "comment": "Security backport source input; not packaged.",
                    }
                )
            annotations.append(
                {
                    "annotationDate": created,
                    "annotationType": "OTHER",
                    "annotator": TOOL,
                    "comment": (
                        "Kernel module binaries are prebuilt repository "
                        "inputs. Their exact source/toolchain relationship is "
                        "recorded as a limitation, not as verified provenance."
                    ),
                }
            )

        document = {
            "spdxVersion": "SPDX-2.3",
            "dataLicense": "CC0-1.0",
            "SPDXID": "SPDXRef-DOCUMENT",
            "name": f"edgeos-vxlan-{version}-{arch}",
            "documentNamespace": namespace,
            "creationInfo": {
                "created": created,
                "creators": [TOOL],
            },
            "documentDescribes": [package_id],
            "packages": sorted(packages, key=lambda p: p["SPDXID"]),
            "files": sorted(files, key=lambda f: f["SPDXID"]),
            "relationships": sorted(
                relationships,
                key=lambda r: (
                    r["spdxElementId"],
                    r["relationshipType"],
                    r["relatedSpdxElement"],
                ),
            ),
            "annotations": annotations,
        }
        return document


def validate_document(document: dict, package: Path, source_root: Path) -> None:
    if document.get("spdxVersion") != "SPDX-2.3":
        fail("SBOM is not SPDX-2.3")
    if document.get("SPDXID") != "SPDXRef-DOCUMENT":
        fail("SBOM document SPDXID is not SPDXRef-DOCUMENT")

    name = dpkg_field(package, "Package")
    version = dpkg_field(package, "Version")
    arch = dpkg_field(package, "Architecture")

    packages = document.get("packages")
    if not isinstance(packages, list) or not packages:
        fail("SBOM has no packages")
    pkg = next(
        (
            item
            for item in packages
            if item.get("name") == name
            and item.get("versionInfo") == version
            and item.get("filesAnalyzed") is True
        ),
        None,
    )
    if pkg is None:
        fail(f"SBOM does not describe {name} {version} as an analyzed package")
    package_id = pkg["SPDXID"]

    files = document.get("files")
    if not isinstance(files, list):
        fail("SBOM has no files array")
    by_name = {}
    for item in files:
        file_name = item.get("fileName", "")
        if file_name in by_name:
            fail(f"duplicate SBOM file entry: {file_name}")
        by_name[file_name] = item

    expected = {}
    with tempfile.TemporaryDirectory(prefix="edgeos-vxlan-sbom-validate.") as tmp:
        payload_root = Path(tmp) / "payload"
        payload_root.mkdir()
        extract_package(package, payload_root)
        for path in package_files(payload_root):
            relative = "./" + path.relative_to(payload_root).as_posix()
            expected[relative] = sha256_file(path)

        payload_entries = 0
        for relative, expected_sha in expected.items():
            if relative not in by_name:
                fail(f"SBOM is missing packaged file: {relative}")
            item = by_name[relative]
            checksums = {
                c.get("algorithm"): c.get("checksumValue")
                for c in item.get("checksums", [])
            }
            if checksums.get("SHA256") != expected_sha:
                fail(f"SBOM file hash mismatch: {relative}")
            if not checksums.get("SHA1"):
                fail(f"SBOM file has no SHA-1 checksum: {relative}")
            payload_entries += 1

        source_only = {
            "./" + CVE_PATCH: "SOURCE",
        }
        for file_name, item in by_name.items():
            if file_name in expected:
                continue
            if file_name not in source_only:
                fail(f"SBOM contains an unexpected file: {file_name}")
            if source_only[file_name] not in item.get("fileTypes", []):
                fail(f"source-only SBOM entry has the wrong type: {file_name}")
            path = source_root / file_name[2:]
            if not path.is_file():
                fail(f"SBOM source-only file is missing: {file_name}")
            checksums = {
                c.get("algorithm"): c.get("checksumValue")
                for c in item.get("checksums", [])
            }
            if checksums.get("SHA256") != sha256_file(path):
                fail(f"SBOM source-only hash mismatch: {file_name}")

        if payload_entries != len(expected):
            fail("SBOM package file coverage is incomplete")

        verification = pkg.get("packageVerificationCode", {}).get(
            "packageVerificationCodeValue"
        )
        payload_file_entries = [by_name[n] for n in expected]
        if verification != package_verification_code(payload_file_entries):
            fail("SBOM package verification code does not match")

    relationships = document.get("relationships")
    if not isinstance(relationships, list):
        fail("SBOM has no relationships")
    describes = [
        r for r in relationships if r.get("relationshipType") == "DESCRIBES"
        and r.get("spdxElementId") == "SPDXRef-DOCUMENT"
    ]
    if not any(r.get("relatedSpdxElement") == package_id for r in describes):
        fail("SBOM document does not DESCRIBE the package")

    contains = {
        r.get("relatedSpdxElement")
        for r in relationships
        if r.get("relationshipType") == "CONTAINS"
        and r.get("spdxElementId") == package_id
    }
    for file_name in expected:
        file_id = by_name[file_name]["SPDXID"]
        if file_id not in contains:
            fail(f"SBOM package does not CONTAIN {file_name}")

    for rel in relationships:
        if rel.get("relationshipType") == "GENERATED_FROM" and (
            package_id in (rel.get("spdxElementId"), rel.get("relatedSpdxElement"))
        ):
            if name == "edgeos-vxlan-kmod":
                fail("SBOM claims GENERATED_FROM for prebuilt kernel modules")

    annotations = document.get("annotations")
    if not isinstance(annotations, list) or not annotations:
        fail("SBOM has no explicit limitation annotations")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    build = sub.add_parser("build", help="build an SPDX SBOM")
    build.add_argument("--package", required=True)
    build.add_argument("--source-root", required=True)
    build.add_argument("--output", required=True)
    build.add_argument("--source-commit", default="")
    build.add_argument("--source-date-epoch", type=int, default=None)
    build.add_argument("--release-tag", default="")
    build.add_argument("--repository", default="downwithbgp/edgeos-vxlan")

    validate = sub.add_parser("validate", help="validate an SPDX SBOM")
    validate.add_argument("--sbom", required=True)
    validate.add_argument("--package", required=True)
    validate.add_argument("--source-root", required=True)

    args = parser.parse_args()
    try:
        if args.command == "build":
            document = make_document(args)
            output = Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(
                json.dumps(document, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )
            validate_document(document, Path(args.package), Path(args.source_root))
            return 0

        document = json.loads(Path(args.sbom).read_text(encoding="utf-8"))
        validate_document(document, Path(args.package), Path(args.source_root))
        return 0
    except (SbomError, subprocess.CalledProcessError, OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
