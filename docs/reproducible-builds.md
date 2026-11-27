# Reproducible builds and controlled build environments

**Branch:** `ci/reproducible-builds` (from `origin/main` `f182a64`)
**Status:** review-ready draft; no historical asset, tag, version or `main` change.
**Scope:** future edgeos-vxlan releases; historical v0.3.0 artifacts are not rebuilt or republished.

## 1. Root-cause analysis of the v0.3.0 discrepancy

Published v0.3.0 packages were compared with clean `git archive` rebuilds of
tag `v0.3.0` (`5ed46fd`).

Member-level comparison covered both packages and both archives:

| Archive | Members | mtime-only differences | Non-mtime differences |
|---|---:|---:|---:|
| `edgeos-vxlan` data | 68 | 68 | 0 |
| `edgeos-vxlan` control | 6 | 6 | 0 |
| `edgeos-vxlan-kmod` data | 16 | 16 | 0 |
| `edgeos-vxlan-kmod` control | 7 | 7 | 0 |

Every member has the same name/order, contents, mode, ownership, uid/gid,
size, type and linkname. The `.deb` ar member timestamps are `2026-11-27
01:30` in both packages, and gzip header MTIME is zero in both. The `.deb`
sizes differ only because gzip compresses different tar headers.

The differing mtimes have two sources:

* Published payload files preserve historical working-tree mtimes
  (`2026-11-26 17:47:12` for `vyatta-vxlan`, etc.); clean `git archive`
  payload files use the commit time `2026-11-27 01:29:31`.
* Published generated directories/control/changelog use the actual build
  window `01:26:47`–`01:26:51`; clean rebuilds use `SOURCE_DATE_EPOCH`
  `01:30:00` from `debian/changelog`.

So source-file mtimes explain the payload member differences, while
build-time stamping explains the generated members. Neither source nor
generated timestamps were normalized. Diffoscope and an independent tar
comparison confirmed the same conclusion. No historical asset was modified.

## 2. Canonical build contract

`scripts/build-reproducible.sh` is the single entry point:

```sh
./scripts/build-reproducible.sh --source-rev vX.Y.Z --output-dir <empty-dir>
```

Contract:

* The source revision is resolved to a commit and recorded.
* A dirty tracked working tree is rejected for `HEAD`; an explicit immutable
  revision may be built from a dirty checkout with a warning. Untracked files
  are never included.
* The source is materialized with `git archive` into an isolated output tree;
  no working-tree file is modified and no submodules are permitted.
* `SOURCE_DATE_EPOCH` is derived from the materialized `debian/changelog`
  timestamp. Ambient `SOURCE_DATE_EPOCH` is accepted only if equal; a
  conflicting value fails closed.
* All materialized files and symlinks are touched first, then directories, to
  the derived epoch. The developer's working tree is never normalized.
* The build uses `LC_ALL=C`, `LANG=C`, `TZ=UTC`, `umask 0022`, `fakeroot`/
  `dpkg-buildpackage -us -uc -b -a mipsel`, and the existing gzip packaging
  behavior.
* Kernel modules are prebuilt repository inputs; the package build does not
  compile kernel code or consume kernel headers. The README records the
  Ubiquiti GPL source archive and MIPS toolchain provenance for those
  committed payloads.
* Output contains the two `.deb` files, `.buildinfo`, `.changes` and
  `SHA256SUMS`; the materialized source tree is removed on success unless
  `--keep-source` is used.

`scripts/verify-reproducible-build.sh` performs two independent canonical
builds in different paths, timezone/locale/umask/execution-time contexts and
compares every package and the manifest. It emits member-level diagnostics
and supports `diffoscope` when available.

## 3. Controlled build environment

`containers/reproducible-build/Dockerfile`:

* Base: `ubuntu:24.04@sha256:562111b88caa79c71391c0c4d3c2114a7d5c35915c20561fd893cb1e07929e6b`.
* APT sources: `snapshot.ubuntu.com/ubuntu/20261127T000000Z` (noble,
  noble-updates, noble-security), with snapshot validity handling.
* Packages: `debhelper`, `dpkg-dev`, `fakeroot`, `git` and the base image CA
  support. Versions resolved from the snapshot include debhelper
  `13.14.1ubuntu5`, dpkg-dev `1.22.6ubuntu6.6`, fakeroot `1.33-1` and git
  `1:2.43.0-1ubuntu7.4`.
* `scripts/build-reproducible-container.sh` runs the canonical build with
  `--network none`, a read-only repository mount, writable output/tmpfs,
  dropped capabilities and `no-new-privileges`.

**Qualified local image:** BuildKit export stalled on the local Docker host
for >14 minutes with the disk near 90%; the image layer completed and a
local image eventually appeared. A derived image was qualified by installing
`build-essential` from the frozen snapshot into the minimal snapshot image:
image ID `sha256:dd56fabdc1d5038ddc661fe2e97e92ed0fae10a41e33072c6555c0922cd469fe`.
The complete 200-package inventory has SHA-256
`1c27838283a8c4a3f28eee279281519570f578e893513dd87ab30e50c7079184`.
The Dockerfile now pins the bootstrap CA/OpenSSL versions and includes
`build-essential`; a fresh rebuild directly from the final Dockerfile has not
been performed, so this is a qualified derived image, not a published/rebuilt
OCI identity. The package build in that image used `--network none`, a
read-only source archive, host UID/GID (non-root), dropped capabilities and
read-only repository scripts. It produced exactly the host canonical hashes
`6afa3f25…`/`7ffe10f6…`.

Source resolution/materialization happens on the host; a verified `git
archive` is passed into the container. This makes the container independent of
host Git metadata and supports linked worktrees. Linked-worktree execution was
tested; the dirty/untracked/path-with-whitespace and differing-UID matrix
remains partially tested and is documented below.

## 4. Verification evidence

| Check | Result |
|---|---|
| Canonical host build A | `6afa3f25…` integration, `7ffe10f6…` kmod |
| Canonical host build B (different path/TZ/locale/umask/time) | identical |
| Canonical prototype with deliberately different source mtimes | identical |
| `SOURCE_DATE_EPOCH=1` override | rejected with mismatch error |
| Full off-device suite | passed (349 v0.3.0 checks + build-script tests) |
| Build-mode negative suite | 25/25 |
| Independent published-release fixtures | 7/7 |
| CI run 46009226761 | Static analysis, Reproducibility verification, Build/validate packages, Network-namespace dataplane and Published-release fixtures all green |
| CI package artifacts | `6afa3f25…` / `7ffe10f6…`, matching local canonical builds |
| Published v0.3.0 | `c555a99a…` / `73059ba2…` unchanged; published validator PASS |

CI run: <https://github.com/downwithbgp/edgeos-vxlan/actions/runs/46009226761>

The canonical artifacts are a **new package identity** relative to the
published v0.3.0 artifacts. That is expected: normalizing mtimes changes the
bytes. It does not modify or replace the published release.

Reproducibility vs related properties:

* **Repeatability:** a rebuild with the same inputs can be repeated.
* **Reproducibility:** independent canonical builds match byte-for-byte across
  paths, timezone, locale, umask and execution time; demonstrated locally and
  on GitHub-hosted infrastructure.
* **Controlled dependencies:** the Dockerfile pins the base digest and APT
  snapshot, but the CI job does not yet consume a retained image.
* **Hermeticity:** not claimed; CI installs dependencies at job start and the
  container image path is not end-to-end verified.

## 5. Stable-build pin policy proposal

Published assets remain strictly pinned (install.sh pins, SHA256SUMS, tag
ancestry). The canonical build changes package identity because historical
packages embedded unnormalized mtimes, so a clean rebuild cannot and should
not be expected to match the published v0.3.0 hashes.

Proposed policy, **not enforced pending approval**:

1. Publish only canonical-build artifacts for new releases.
2. Update install.sh pins and SHA256SUMS at the release commit from those
   canonical artifacts; never silently replace an existing release.
3. For packaging-only changes, require a new version/release identity rather
   than reusing published pins.
4. Keep published-release validation strict and fail closed.
5. Treat a clean-rebuild-versus-published mismatch as a diagnostic unless and
   until the maintainer explicitly approves a release-time enforcement gate.

Consequences: this prevents silent package-identity changes but adds a
version/release step for packaging-only work and requires release-time pin
updates. Historical v0.3.0 remains unreproducible and must not be republished.

## 6. Independent published-release fixtures

`test/published-release-fixtures.sh` downloads the published v0.3.0 assets,
verifies the tag commit (`5ed46fd`) and the expected hashes
(`c555a99a…`/`73059ba2…`), and exercises the published validator against:

* the valid asset set;
* missing manifest;
* missing package;
* unexpected asset;
* corrupted package;
* reordered/tampered manifest;
* tag/version mismatch.

The suite is independent of local rebuild reproducibility. It is wired as a
trusted-ref CI job (`Published-release fixtures`) and does not modify the
downloaded historical assets.

## 7. Cross-project reuse

The SADR repository was not modified. Proposed reusable interface:

* Canonical build entry point with project-specific source/config inputs but
  the same revision/clean-materialization/mtime/environment contract.
* Independent two-build verifier and package/member comparison.
* Snapshot-pinned Ubuntu container definition with project package lists.
* Published-release fixture harness (tag/hash verification plus malformed
  asset cases).
* CI conventions: canonical package job, reproducibility job, trusted-ref
  fixture job, artifact hashes and run references.

This should be extracted only after both projects have independent
requirements; no shared framework was created prematurely.

## 7a. Kernel module source-to-binary reproducibility proposal

This work establishes Debian packaging reproducibility, not independent
kernel-module compilation. A future separate workstream must identify and
preserve: the exact Ubiquiti GPL archive/source revision and hash; vendor
patches including CVE-2022-50405; the target 4.14.54-UBNT configuration;
generated headers; `Module.symvers`/symbol-version data; the MIPS cross
compiler and binutils versions; vermagic/ABI requirements; and the existing
prebuilt module hashes. The GPL archive and source name/hash are recorded in
README; the cross toolchain is not part of this package build. Licensing and
corresponding-source obligations must be reviewed before any recompilation.
No module was recompiled or changed in Phase II.

## 8. Remaining limitations and risks

* v0.3.0 published bytes remain unreproducible; accepted and not modified.
* Canonical artifacts differ from historical published bytes.
* Docker export stalled locally; a qualified derived image was built, but a
  fresh rebuild directly from the final Dockerfile and a retained OCI digest
  are still pending.
* Ordinary-checkout, dirty/untracked, whitespace-path and differing-UID/GID
  container tests are not all executed; linked-worktree archive handoff is
  verified.
* Snapshot retention/availability and apt metadata trust still depend on the
  Ubuntu snapshot service.
* Build user variation was not demonstrated end-to-end in a retained container.
* Kernel modules are prebuilt; kernel-source/cross-toolchain rebuild
  reproducibility is not part of this package build.
* No artifact attestations, SBOM, signed tags or immutable releases.
* Build pin enforcement remains a proposal pending maintainer approval.
* `diffoscope` was used opportunistically; tar/ar member comparison is the
  normative evidence and does not require it.

## 9. Prioritized next steps

1. Retain/publish a digest-identified build image with the fixed snapshot.
2. Add explicit reproducibility contract tests for user/container variation.
3. Obtain maintainer approval for the stable-build pin policy.
4. Add provenance validation (`.buildinfo`/`.changes`) and attestations/SBOM.
5. Extract the reusable cross-project interface when SADR requirements are known.

## Appendix: commands

```sh
./scripts/build-reproducible.sh --source-rev v0.3.0 --output-dir <empty-dir>
./scripts/verify-reproducible-build.sh --source-rev v0.3.0
./scripts/build-reproducible-container.sh --source-rev v0.3.0 --output-dir <empty-dir>
bash test/published-release-fixtures.sh
bash test/run.sh
```
