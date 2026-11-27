# Release engineering hardening

**Branch:** `ci/release-engineering-hardening`
**Draft PR:** <https://github.com/downwithbgp/edgeos-vxlan/pull/5>
**Base:** `origin/main` `5ed46fd` (v0.3.0)
**Status:** review-ready draft; nothing merged, tagged or published.
**Last branch commit before this report update:** `8194f7e`.

## 1. Scope and isolation

The work was performed on the dedicated branch/worktree. The ongoing
`feat/native-firewall` v0.3.0 workstream was inspected but not modified. It is
an ancestor of current `origin/main`; no separate v0.3.0 merge is required.
No product version, package payload, release note, tag, release, repository
setting or `main` commit was changed by this work.

Because `origin/main` advanced to v0.3.0 during the phase, the branch was
brought up to date by merging `origin/main` (`b8c2260`) to resolve the
workflow overlap and make the requested PR mergeable. That merge did not add
v0.3.0-specific content-map or platform-pin entries; the validator is
release-generic.

## 2. Initial findings

### Existing guarantees found

* The original validators checked package names, versions, architectures,
  kernel-module hashes, tag/version agreement, `install.sh` versions, published
  asset names, and (for published releases) exact `SHA256SUMS`.
* The off-device suite covered 132 checks at v0.2.2 and 349 at v0.3.0.
* Maintainer scripts verify stock EdgeOS payload hashes before diversion; the
  installer pins both package hashes.
* v0.2.2 clean builds were byte-reproducible in practice.

### Defects and gaps found

| Area | Finding |
|---|---|
| Workflow injection | Release tags were interpolated into shell; tag syntax/line count was not validated before `GITHUB_OUTPUT`. |
| Git validation | `git diff --check` ran on a clean checkout and checked nothing. |
| Supply chain | Actions and analysis tools were not pinned; Dependabot was absent; checkout credentials persisted. |
| Operations | Floating runner, no timeouts/concurrency policy, warn-only missing artifacts, recompression of `.deb` uploads. |
| Artifact contract | No exact content/permission/ownership, ELF/ABI, module metadata, maintainer-script, exact manifest-set or negative coverage. |
| Published releases | Extra assets were ignored; current vs tagged validation logic was undocumented; v0.1.1 lacks a committed `SHA256SUMS`. |
| v0.3.0 integration | Hardcoded content/dependency tables rejected the firewall file and new dependencies; clean rebuilds do not match v0.3.0 published pins due source mtimes. |
| Reproducibility | `SOURCE_DATE_EPOCH` does not normalize source-file mtimes; v0.3.0 published packages are content-identical to clean rebuilds but not byte-identical. |

## 3. Implemented changes

### 3.1 Release-generic artifact contract

`scripts/validate-artifacts.sh` now checks:

* the required asset set, versions, architectures and dependency/policy fields;
* package contents, modes and `root/root` ownership;
* every packaged file against its source, with the content map derived from
  the tagged tree's `debian/*.install`;
* control-archive contents and modes, maintainer-script syntax, `set -e`, and
  byte equality with `debian/`;
* MIPS ELF class, endianness, numeric ABI flags, MIPS32r2, 32-bit GPRs and
  soft-float ABI;
* module name, `vermagic`, dependencies and pinned payload hashes;
* `md5sums` exact path set and content;
* `SHA256SUMS` format, exact names, uniqueness, hashes and tagged-tree equality;
* `install.sh` pins for published assets;
* known build-host paths and secret material.

Expected dependency and policy fields (`Depends`, `Pre-Depends`, `Conflicts`,
`Breaks`, `Replaces`, `Provides`, `Essential`, `Multi-Arch`) are resolved from
the tagged `debian/control`. Unknown substvars fail closed. The source mapping
and fields are not v0.3.0-specific.

### 3.2 Adversarial hardening

| Finding | Resolution |
|---|---|
| `md5sums` could name absolute/`../` paths | Exact path-set comparison against the packaging contract before `md5sum -c`. |
| Extraction before hash verification | Published package pins checked before extraction; decompressed docs capped. |
| Unvalidated install-time control fields | `Pre-Depends`, `Conflicts`, `Breaks`, `Replaces`, `Provides`, `Essential`, `Multi-Arch` checked against `debian/control`. |
| Hardcoded v0.3.0-incompatible mapping/pins | Replaced by source-derived mapping and fields; no v0.3.0-specific entries added. |
| Tag/branch ambiguity | Tagged source checked out as `refs/tags/<tag>`. |
| Tool redirects not constrained | `curl --proto-redir '=https'`. |
| Relative source root treated as host path | Artifact and source roots normalized to absolute paths. |
| Unapproved build-time pin policy | Removed from enforcement; published pins remain mandatory. |
| Missing regression coverage | Added symlink, unsafe-md5sums, smuggled-control-field, dependency-drift, provenance, multiline-tag, and published-fixture tests. |

### 3.3 Workflow hardening

Pinned actions (`checkout` v7.0.1 SHA `3d3c42e5…`, `upload-artifact` v7.0.2
SHA `cf430e03…`), explicit `ubuntu-24.04`, `contents: read`,
`persist-credentials: false`, timeouts, safe concurrency, event-aware
whitespace checks, pinned actionlint 1.7.12 / zizmor 1.33.1 / shellcheck
0.11.0 with SHA-256 verification, Dependabot with a 7-day cooldown, lintian
with one documented `/opt/vyatta` suppression, `SOURCE_DATE_EPOCH`,
`.buildinfo`/`.changes` provenance upload, and `if-no-files-found: error` with
`compression-level: 0`. The v0.3.0 dataplane job is preserved but excluded
from PR refs because it requires root/network namespaces.

## 4. Verification evidence

| Check | Result |
|---|---|
| Off-device suite (v0.3.0) | 349/349 (64 helper + 122 firewall + 93 templates + 70 mock) |
| Negative suite (v0.2.2 tree) | 33/33 |
| Negative suite (merged v0.3.0 tree) | 25/25; published-fixture cases skipped because clean rebuilds do not match release pins |
| v0.3.0 build contract | PASS |
| Published v0.3.0 assets | PASS, including `.buildinfo`/`.changes` |
| Published v0.2.2 assets | PASS |
| shellcheck / actionlint / zizmor | clean (zizmor offline and online) |
| lintian | clean with the documented suppression |
| Integrated push run 45924535649 | build/validate, static analysis, network-namespace dataplane all green |
| Final push run 45926157384 | static analysis, build/validate and network-namespace dataplane all green |
| PR run 45926265802 | all applicable jobs green (static analysis, build/validate); dataplane and published verification skipped by design |
| PR | <https://github.com/downwithbgp/edgeos-vxlan/pull/5> (draft, mergeable) |

Earlier green runs: 45902676688, 45902842570 (published v0.2.2 verification),
45903324988, 45905792742, 45906496008.

## 5. Reproducibility findings

### Build inputs

| Release | Source commit | Result |
|---|---|---|
| v0.2.2 | `c917f33` | Clean-archive builds reproduce published `0cc647…` / `026d4d46…`. |
| v0.3.0 | `5ed46fd` | Clean-archive builds are mutually identical (`414399…` / `1d8176…`) but differ from published `c555a9…` / `73059b…`. Contents/control are identical; tar mtimes differ. |
| Merged branch | `b8c2260` (product tree `5ed46fd`) | Worktree-copy build (`bdc3e0…` / `7d66f3…`) differs again with source mtimes. |

Toolchain observed: Ubuntu 24.04.5, dpkg 1.22.6, debhelper 13.14.1ubuntu5,
fakeroot 1.33-1, build-essential 12.10ubuntu1, GCC 13.3.0, make 4.3; GitHub
runner image `ubuntu-24.04` (run 45902676688 recorded image
`20261122.23.1`). Container experiment: `ubuntu:24.04` digest
`sha256:562111b88caa79c71391c0c4d3c2114a7d5c35915c20561fd893cb1e07929e6b`.

Kernel provenance is unchanged: prebuilt `vxlan.ko`/`udp_tunnel.ko` are
committed; the README records Ubiquiti GPL archive
`GPL.mtk.v3.0.0-rc.9.5753457.tar.bz2` (SHA-256
`4f2ba6fd6b8655582e9090bbc1da96c656cd46841992376811a014970b149fb9`), kernel
source `source/kernel_5753457-g001c7c22e530.tgz`, kernel 4.14.54-UBNT and
`mipsel-linux-gnu-gcc 6.3.0`. The Debian build does not compile modules, so
kernel headers are provenance for the committed payloads, not a package build
input.

### Timestamp behavior and experiments

* `dpkg-buildpackage` automatically sets `SOURCE_DATE_EPOCH` from the latest
  changelog entry when unset (dpkg-buildpackage script line 536); the workflow
  also sets it explicitly from `dpkg-parsechangelog -S Timestamp`.
* v0.3.0 clean-archive builds were identical with automatic vs explicit
  timestamp, two build paths, `TZ=UTC` vs `America/New_York`, `LC_ALL=C` vs
  `C.UTF-8`, and root vs non-root users.
* `SOURCE_DATE_EPOCH=1` changed both hashes, so the value matters.
* Source-file mtimes are preserved. A worktree-copy build differs from a
  `git archive` build; the published v0.3.0 package preserved historical
  working-tree mtimes. `SOURCE_DATE_EPOCH` alone does not normalize them.
* `reprotest` 0.7.26 was attempted in the container but was blocked by the
  default seccomp/`setarch` personality restriction and missing optional
  tools; no new infrastructure was added. Targeted experiments cover the
  practical variations.

**Scope:** byte reproducibility is demonstrated for v0.2.2 across the tested
contexts and for v0.3.0 only among clean-archive builds. Published v0.3.0 is
content-identical but not byte-reproducible from the tagged tree. Future
releases are not guaranteed byte-reproducible until source mtimes are
normalized and the environment is pinned.

## 6. Maintainer decisions and policy

* Three-workflow build-once lifecycle: approved as direction; implementation
  belongs to a separate workstream. This branch keeps the single workflow.
* Artifact attestations and meaningful SBOM: approved for a later phase.
* Signed tags and immutable releases: deferred pending operational design.
* HIL qualification: separate project.
* Offline zizmor remains a mandatory CI gate; online auditing is proposed as a
  scheduled/manual check, not a PR dependency.
* No v0.3.0-specific content-map or platform-pin changes were added.

### Stable-build pin enforcement (not implemented)

**Problem:** requiring clean rebuilds to match `install.sh` pins fails when
packaging is not byte-reproducible. v0.3.0 demonstrates this: content is
identical, but source-mtime materialization changes package bytes, so a clean
CI rebuild cannot match the published pins.

**Affected scenarios:** every stable branch build, packaging-only changes, and
release candidates; tag builds would also fail until mtimes are normalized.

**Proposed mechanism:** first normalize source mtimes and document toolchain
inputs; then compare the two built package hashes to `install.sh` pins in a
separate, explicitly approved job. Published assets remain strictly pinned.

**Consequences:** enforcing today would block legitimate v0.3.0 builds and
force pin churn. The branch therefore reports build hashes but does not compare
them to pins. This is a policy decision for review, not a silent relaxation.

## 7. Integration readiness

* `origin/main` is `5ed46fd` (v0.3.0); `origin/feat/native-firewall`
  `0b6893f` is an ancestor of main and was not modified.
* The branch merged main at `b8c2260`; `git merge-tree` now exits 0 and the PR
  is mergeable. The branch-vs-main diff contains only CI/scripts/test/report
  changes (11 files).
* The workflow overlap was resolved by keeping v0.3.0's dataplane job under the
  hardened model, excluding it from PR refs (root requirement), and adding
  firewall shellcheck.
* The validator has no `vyatta-vxlan-firewall`, `vyatta-cfg-firewall`,
  `libvyatta-cfg1` or `iptables` special cases; v0.3.0 build and published
  validation pass.
* Remaining adaptation: build-pin policy/mtime normalization; published
  fixtures skip when a rebuild does not reproduce release pins; release-event
  path remains unexecuted; provenance/SBOM/attestation work is deferred.

**Recommended sequence:** review/merge PR #5 into main (main already contains
v0.3.0); do not merge or rebase the v0.3.0 branch. For future patch lines,
retain the generic derivation, and address mtime normalization before any
build-pin enforcement.

## 8. Remaining risks and limitations

* v0.3.0 published bytes are not reproducible from the tagged tree; content and
  control are identical, but mtimes differ.
* No signed tags, attestations, SBOM, immutable releases or automatic
  publication.
* Build dependencies/runner image are recorded but not digest-pinned in CI.
* The `release` event path, including GITHUB_TOKEN publication behavior, was
  not executed; manual dispatch exercised the same published-release job.
* Published-fixture negative cases skip when rebuilds do not match pins.
* Dataplane root test is intentionally excluded from PR refs.
* `reprotest` could not run under the container's seccomp profile.

## 9. Proposed release lifecycle

`ci.yml` (build once, test, static analysis, artifact contract, upload
artifacts) → `release.yml` (download the exact CI-run artifacts, qualify,
generate provenance/SBOM, publish under a protected environment, never
rebuild) → `verify-release.yml` (independent verification with current trusted
logic). A release published with `GITHUB_TOKEN` does not trigger another
workflow; use workflow_dispatch, a GitHub App/PAT, or a scheduled verifier.
Migration is a separate workstream.

## 10. Proposed hardware-in-the-loop qualification

Separate isolated EdgeRouter X and controller; no production device and no
persistent self-hosted runner exposed to PRs. Qualify release candidates only:
install/upgrade/remove/rollback, module lifecycle, VXLAN/bridge, IPv4/IPv6
underlays, MTU/dataplane, scripted vs interactive commits, firewall integrity,
reboot persistence, and failure injection. Capture console, state, rulesets,
packet captures and hashes. This remains a separate project.

## 11. PR and merge procedure

* Draft PR #5: problem, changes, security/correctness, verification,
  reproducibility scope, run links, limitations, deferred architecture and
  integration notes.
* Do not mark ready until the PR checks are green and review is complete.
* Recommended merge: merge commit (preserve the integration history), then
  confirm main CI; do not create a tag/release as a test.
* After merge, delete the branch only if the maintainer chooses; retain the
  recorded run IDs and artifact hashes.

## 12. Prioritized backlog

1. Normalize source mtimes and define the reproducibility contract.
2. Decide/enforce the stable-build pin policy after (1).
3. Validate `.buildinfo`/`.changes` contents and add attestations/SBOM.
4. Implement the three-workflow build-once lifecycle.
5. Design signed tags and immutable releases.
6. Stand up the separate HIL project.
7. Add scheduled/manual online zizmor.
8. Verify the next legitimate release event end to end.
9. Decide whether the root dataplane job should ever run on PRs.

## Appendix: commands

```sh
bash test/run.sh
./scripts/validate-release.sh <clean-artifact-dir>
bash test/validate-release-negative.sh <clean-artifact-dir>
RELEASE_TAG=v0.3.0 ./scripts/validate-published-release.sh \
  published-v0.3.0 tagged-v0.3.0-source
shellcheck install.sh scripts/*.sh test/*.sh \
  debian/*.preinst debian/*.postinst debian/*.prerm debian/*.postrm \
  src/vyatta-vxlan src/vyatta-vxlan-bridge src/vyatta-vxlan-firewall
actionlint
zizmor --offline --collect all .github
lintian --suppress-tags-from-file .github/lintian-suppressions.txt \
  --fail-on error --tag-display-limit 0 <packages>
dpkg-buildpackage -us -uc -b -a mipsel
```
