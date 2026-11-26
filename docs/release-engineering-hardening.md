# Release engineering hardening

**Branch:** `ci/release-engineering-hardening`, based on `origin/main`
`c917f33` (tag `v0.2.2`).
**Status:** review-ready CI branch; nothing merged, tagged or published.
**Verification:** local checks plus two green GitHub Actions runs, including an
independent verification of the published `v0.2.2` release.

## 1. Scope and isolation

The work was done in a dedicated Git worktree under the session scratch
directory. The existing v0.3.0 development worktree was not stashed, reset,
rebased, checked out or modified, and no v0.3.0 commits were merged into this
branch. Product version, package metadata, kernel modules, source payloads and
release notes are unchanged. No tag, release, `main` merge or repository
setting was created or changed.

The only branch pushed is `ci/release-engineering-hardening`.

## 2. Initial findings

### Existing guarantees found

* `scripts/validate-release.sh` already checked package names, versions,
  architectures, the two kernel-module payload hashes, tag/version agreement,
  and the `install.sh` version/pin relationship for stable releases.
* `scripts/validate-published-release.sh` already checked published asset
  names, package versions/architectures, `install.sh` pins, and exact equality
  of the published `SHA256SUMS` with the tagged repository.
* The off-device suite already covered 132 checks: helper (64), templates (32),
  and mocked reconciliation (36).
* Package maintainer scripts already verify the stock EdgeOS payload hashes
  before `dpkg-divert`, and the installer already pins both package hashes.
* Clean builds of `v0.2.2` were already byte-reproducible in practice.

### Defects and gaps found

| Area | Finding |
|---|---|
| Workflow injection | `gh release download "${{ steps.release.outputs.tag }}"` interpolated an expression directly into a shell script. |
| Tag input | The manual-dispatch default was hardcoded to `v0.2.2`; tag syntax was not validated before use. |
| Git validation | `git diff --check` ran on a clean checkout, so it checked nothing. |
| Release download | `gh release download` did not name the target repository explicitly. |
| Supply chain | Actions were referenced by moving tags, not commit SHAs; no Dependabot configuration. |
| Permissions | Checkout credentials persisted by default; no explicit runner image; no timeouts or concurrency policy. |
| Artifact upload | A missing artifact produced a warning rather than a failure; uploads recompressed already-compressed `.deb` files. |
| Artifact contract | No exact content/permission/ownership checks, no ELF/MIPS ABI checks, no `vermagic`/module-dependency checks, no maintainer-script syntax/source checks, no exact manifest-set validation, and no negative tests. |
| Published release | Extra release assets were ignored; the trust model split between current and tagged validation logic was undocumented. |
| Historical release | `v0.1.1` has no committed `SHA256SUMS`; only its published asset carries one. A naive exact-manifest check rejects a legitimate historical release. |
| Packaging lint | `lintian` reported only intentional `dir-or-file-in-opt` errors for the EdgeOS `/opt/vyatta` appliance tree. |
| Release triggering | A release published with `GITHUB_TOKEN` does not start another workflow run; manual dispatch must remain supported. |

## 3. Changes implemented

### 3.1 Shared artifact contract

`scripts/validate-artifacts.sh` is now the single contract behind both
validators. It checks:

* the exact package set and, in published mode, the exact release asset set;
* package names, versions, architectures and dependency relationships;
* exact data contents, file types, modes and `root/root` ownership;
* every packaged payload against the source tree (scripts, Perl module,
  templates, kernel modules, changelog and copyright);
* control-archive contents and modes, maintainer-script syntax, `set -e`, and
  byte equality with `debian/`;
* MIPS ELF class, endianness, relocatable type, machine, numeric ABI flags,
  MIPS32r2 ISA, 32-bit GPRs and soft-float ABI;
* kernel-module name, `vermagic`, dependencies and pinned payload SHA-256;
* package `md5sums` integrity;
* `SHA256SUMS` format, exact names, uniqueness, hashes and exact tagged-tree
  equality where the tag carries a manifest;
* `install.sh` pins for stable builds and published assets;
* known build-host paths and secret material in packaged data.

The expected content list is derived from the tagged source's
`debian/*.install` definitions rather than a manifest tied to the current
release. This is what allows historical releases to be validated with current
trusted logic. The module payload hashes and MIPS ABI anchors remain explicit
reviewed constants for the supported `v0.1.1`–`v0.2.x` payloads.

`scripts/validate-release.sh` handles prerelease (`~`) builds separately: it
skips only the published-pin cross-check and continues to enforce prerelease
version shape, content, module and tag restrictions. The previous validator
would have failed an rc branch because `install.sh` intentionally keeps the
last published version until the release commit.

`scripts/validate-published-release.sh` requires an explicit tagged source
tree. It treats that tree as read-only data: no tagged build or maintainer
script is executed. For tags without a committed `SHA256SUMS` (for example
`v0.1.1`), the published manifest is checked against the tagged `install.sh`
pins instead.

### 3.2 Workflow hardening

* Actions pinned to full commits:
  * `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`
  * `actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2`
* Explicit `runs-on: ubuntu-24.04`; top-level `contents: read`;
  `persist-credentials: false` on every checkout.
* Manual dispatch input default removed; tags must match
  `vMAJOR.MINOR.PATCH`; all event values reach shell through `env:` and are
  quoted.
* `scripts/check-whitespace.sh` selects a meaningful range for pull requests,
  ordinary pushes, multi-commit pushes, new branches, tags, releases and
  manual dispatch. It fetches only the history the event needs.
* Job timeouts: static analysis 10 min, build/validation 30 min, published
  verification 15 min. Concurrency cancels PR builds only; published-release
  verification is never cancelled.
* Artifact upload fails when no files are found and uses
  `compression-level: 0`.
* `SOURCE_DATE_EPOCH` is taken from the changelog; `.buildinfo`, `.changes`
  and a build-environment record are uploaded as CI provenance.
* Dependabot tracks `github-actions` monthly with a 7-day cooldown.
* `lintian` runs with `--fail-on error`; the only suppression is the
  documented `dir-or-file-in-opt` exception for the EdgeOS `/opt/vyatta` tree
  in `.github/lintian-suppressions.txt`.

### 3.3 Static analysis

`scripts/install-ci-tools.sh` downloads and SHA-256-verifies:

| Tool | Version |
|---|---|
| actionlint | 1.7.12 |
| zizmor | 1.33.1 |
| shellcheck | 0.11.0 |

The lint job runs `actionlint`, `zizmor --offline --collect all .github`
(workflows and Dependabot), ShellCheck over installer/build/release/test/
maintainer scripts and the shell helpers, and `perl -c` for the address helper.
Zizmor's online audits were also run locally against the pinned action commits
and reported no findings.

### 3.4 Trust model for published-release verification

* **Validation logic:** current trusted CI code. Release events use the
  default branch; manual dispatch uses a selected branch (dispatching requires
  write access) but never a tag, so a tag cannot certify itself.
* **Expected metadata/pins:** the tagged source tree, treated as data.
* **Artifacts:** the files actually downloaded from the GitHub Release.
* Release metadata is checked for published/non-draft/non-prerelease status,
  tag name, and ancestry in the default branch.
* Downloaded content is never executed.

## 4. Verification evidence

### 4.1 Local checks

| Check | Result |
|---|---|
| `bash test/run.sh` | 132/132 (64 helper + 32 templates + 36 mock) |
| `./scripts/validate-release.sh` (stable) | PASS |
| `test/validate-release-negative.sh` (stable tree) | 29/29 |
| Prerelease build + `--skip-install-pins` | PASS |
| `test/validate-release-negative.sh` (prerelease tree) | 21/21; published-mode cases correctly skipped |
| Published releases `v0.1.1`, `v0.2.0`, `v0.2.1`, `v0.2.2` | PASS with current logic |
| `shellcheck` over all scripts | clean |
| `actionlint` | clean |
| `zizmor` offline (workflows + Dependabot) | clean |
| `zizmor` online | clean |
| `lintian --fail-on error` | clean with the single documented suppression |
| Whitespace checker, push/new-branch/PR-merge paths | rejects trailing whitespace in each |

### 4.2 GitHub Actions runs

* Push run: <https://github.com/downwithbgp/edgeos-vxlan/actions/runs/45902676688>
  * Static analysis: success.
  * Build and validate packages: success (1m6s), including tests, build,
    positive/negative artifact validation, lintian, staging and upload.
  * Verify published release: skipped (push event), as designed.
* Manual dispatch run: <https://github.com/downwithbgp/edgeos-vxlan/actions/runs/45902842570>
  * Static analysis: success.
  * Build and validate packages: success.
  * Verify published release: success; `v0.2.2` validation PASS
    (`Kmod SHA256 0cc647…`, `Integration SHA256 026d4d46…`).

The CI-built packages downloaded from run 45902676688 are byte-identical to
the published v0.2.2 assets and to both local clean builds.

### 4.3 Reproducibility findings

Four independent build contexts produced byte-identical packages:

1. local clean build A, explicit `SOURCE_DATE_EPOCH=1791675638`;
2. local clean build B, same inputs;
3. a `ubuntu:24.04` container pinned by digest
   `sha256:562111b88caa79c71391c0c4d3c2114a7d5c35915c20561fd893cb1e07929e6b`;
4. the GitHub `ubuntu-24.04` runner.

Artifact hashes:

```text
0cc64788646518903522711398114085495215480168f65a60fa8af2f347cb04  edgeos-vxlan-kmod_0.2.2+edgeos3.0.1.e50_mipsel.deb
026d4d46dba631bfa2228f8be3af3565d505cd3650c9740b169e8c1b79a11bf9  edgeos-vxlan_0.2.2+edgeos3.0.1.e50_all.deb
```

CI build environment: Ubuntu 24.04 runner, `dpkg` 1.22.6, `debhelper`
13.14.1ubuntu5, `fakeroot` 1.33-1, `kmod` 31+20240202-2ubuntu7.2, `lintian`
2.117.0ubuntu1.6, GCC 13.3.0, `SOURCE_DATE_EPOCH=1791675638`.

This is a **repeatable build procedure** and a **verified reproducible build**
for the current v0.2.2 payloads across those contexts. It is not yet a
**controlled build environment**: apt packages float within `ubuntu-24.04`,
and no digest-pinned CI container is used. `.buildinfo`/`.changes` are useful
provenance but their `Build-Date` is not reproducible.

## 5. Architectural decisions and tradeoffs

* **One workflow retained, decomposition proposed (not implemented).** The
  existing release procedure remains intact. Splitting into `ci.yml`,
  `release.yml` and `verify-release.yml` is described in §6 for approval.
* **Content contract derived from the tagged source.** This supports historical
  releases and avoids a duplicate manifest that can drift. The tradeoff is that
  new packaged files need a matching source-mapping entry; module hashes and
  the `libvyatta-cfg1` pin are still platform-specific reviewed constants.
* **Stable builds must match `install.sh` pins.** This fails closed when a
  rebuild diverges, but means a packaging-only change that intentionally
  changes bytes must update the release pins/version in a reviewed commit.
* **Lintian suppression is one tag for one package tree.** `/opt/vyatta` is the
  EdgeOS appliance convention, not an accidental FHS violation.
* **Manual dispatch may use a branch's validator logic.** This is required to
  exercise new validation before merge; dispatch requires write access, and tag
  dispatch is forced back to the default branch.
* **No artifact attestations, SBOM, signed tags, immutable releases or
  publication automation were introduced.** They require repository settings,
  signing infrastructure or publication privileges and are listed in §8–§9.

## 6. Proposed release lifecycle

**Principle: build once, validate, qualify, publish the exact validated
artifacts, then independently verify the published distribution.**

1. `ci.yml` — pull requests, `main`, `ci/**`, tags.
   * tests, static analysis, one package build, artifact contract, lintian;
   * upload packages, `SHA256SUMS`, `.buildinfo`, `.changes`, provenance;
   * no publication credentials.
2. `release.yml` — manual dispatch with a release tag and the CI run ID.
   * download the exact artifacts from that CI run, never rebuild;
   * re-verify hashes and the artifact contract;
   * generate provenance/SBOM (future), publish under a protected GitHub
     Environment with maintainer approval;
   * fail if the CI run is not green or the artifact hashes do not match.
3. `verify-release.yml` — `release` event, schedule, or manual dispatch.
   * use current default-branch validation logic;
   * download published assets, verify metadata/ancestry/manifest/contents;
   * never execute downloaded content.

**Migration path:** (a) keep the current single workflow while this branch is
reviewed; (b) split `ci.yml` first, preserving triggers; (c) add the
build-once release workflow behind a protected environment; (d) add
attestations/SBOM/signed-tag verification; (e) add hardware qualification.

**GitHub trigger caveat:** a release created with `GITHUB_TOKEN` will not
trigger another workflow run. Automatic verification after publication needs a
`workflow_dispatch` call, a GitHub App/PAT, or a scheduled verifier; the
manual path is already supported.

## 7. Proposed hardware-in-the-loop qualification

Off-device tests cannot establish complete EdgeOS runtime correctness, as the
EdgeOS 3.0.1 scripted firewall-commit defect demonstrated.

Proposed architecture:

* A dedicated EdgeRouter X test device, isolated from production and from the
  maintainer's management network.
* A separate test controller (not the router) that installs pinned artifacts,
  drives serial console and SSH, and captures evidence.
* No persistent self-hosted runner and no hardware management interface
  exposed to arbitrary pull-request code. Qualification runs only from a
  protected environment on release candidates.
* Coverage: install, upgrade, removal and rollback; kernel-module load/unload;
  VXLAN and bridge lifecycle; IPv4 and IPv6 underlays; MTU and actual
  data-plane forwarding; interactive versus scripted commits; firewall ruleset
  integrity; reboot persistence; deterministic failure injection and recovery.
* Evidence: artifact hashes, console transcripts, kernel/module state,
  interface/bridge state, firewall rulesets, packet captures and post-reboot
  checks, archived with the release record.

This remains a proposal; no hardware was accessed or modified.

## 8. Remaining risks and limitations

* No HIL automation; runtime qualification remains manual.
* No signed tags, artifact attestations, SBOM or immutable-release setting.
* The CI build environment is explicit but not digest-pinned; apt versions can
  move within Ubuntu 24.04. Reproducibility is verified for the current
  payload, not guaranteed for future builds.
* Module hashes, MIPS ABI anchors, the `libvyatta-cfg1` pin and the
  `edgeos3.0.1.e50` suffix are platform-specific. They must be reviewed when
  the supported EdgeOS build or kernel payload changes.
* The content source-mapping table needs entries for new packaged files. A
  v0.3.0 merge should update it deliberately rather than bypass it.
* Published-release verification depends on GitHub API availability; the
  `release` trigger is not exercised when `GITHUB_TOKEN` publishes.
* The `release` event path and pull-request trigger were not executed in this
  session. The same published-release job was exercised by manual dispatch;
  the PR whitespace path was exercised locally and actionlint validates all
  triggers.
* Negative published-mode cases are skipped on prerelease trees, where the
  build pins intentionally still refer to the last stable release.
* The host-path/secret scan covers known build paths and common secret
  signatures; it is not a general-purpose content scanner.
* Lintian suppression is tag-wide for `dir-or-file-in-opt`; a future
  non-appliance `/opt` file in the same package would also be suppressed.
* `zizmor` runs offline in CI. Online provenance audits were run locally and
  were clean, but are not a continuous gate.

## 9. Outstanding decisions requiring maintainer approval

1. Approve the three-workflow, build-once release lifecycle in §6.
2. Approve artifact attestations, SBOM generation, signed Git tags and
   immutable releases, including their repository settings and signing
   infrastructure.
3. Approve hardware and controller provisioning for §7, plus the network
   isolation and access model.
4. Confirm that stable builds should keep failing when package bytes do not
   match `install.sh` pins, including packaging-only changes.
5. Decide how to update the content source-mapping table and platform pins for
   v0.3.0 before merging this branch into that line of development.
6. Decide whether to run `zizmor` online in CI (requires a token/network
   dependency) or keep the offline gate.
7. Decide whether to keep the single lintian suppression or add per-file
   appliance overrides.

## Appendix: verification commands

```sh
bash test/run.sh
./scripts/validate-release.sh
bash test/validate-release-negative.sh ..
RELEASE_TAG=v0.2.2 ./scripts/validate-published-release.sh published tagged-source
shellcheck install.sh scripts/*.sh test/*.sh \
  debian/*.preinst debian/*.postinst debian/*.prerm debian/*.postrm \
  src/vyatta-vxlan src/vyatta-vxlan-bridge
actionlint
zizmor --offline --collect all .github
lintian --suppress-tags-from-file .github/lintian-suppressions.txt \
  --fail-on error --tag-display-limit 0 <packages>
dpkg-buildpackage -us -uc -b -a mipsel
```
