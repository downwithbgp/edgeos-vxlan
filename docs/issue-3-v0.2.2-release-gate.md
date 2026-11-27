# Issue #3 — v0.2.2 Final Release Gate

**Status: prepared, not executed.** Nothing has been pushed, merged, tagged or published. This
document is the pre-publication record required by the release brief; the ordered procedure in §8 is
executed only on the maintainer's authorization.

**Release decision (from `docs/issue-3-stable-release-readiness.md` §12): READY WITH DOCUMENTED
LIMITATIONS** — carried into this gate as **GO** for publication, conditional on the §8 procedure
(CI green on the pull request; CI-built artifacts hash-matching this manifest before publishing).

---

## 1. Final Git commit SHA

* **Runtime / packaging source: `f00c094ce1c0bca927b9144d1acb05954da59a9b`** ("release: prepare
  v0.2.2") — both stable packages rebuild **byte-identically** from this commit (two clean-room
  builds verified; see §3).
* **Checksum pinning: `bd8a8e37cfd6cc8ac802391caedf160351d01340`** ("release: add v0.2.2 checksums").
* Release materials on top of these (`docs/issue-3-pr-draft.md`, this document, and any
  review-driven fixes) are **documentation-only commits**. The tag is applied to the **merge commit
  of the release PR on `main`** (the v0.2.1 precedent); the PR head at merge time is the
  authoritative final preparation SHA and carries the same tree as recorded here.
* Branch: `feat/ipv6-underlay`; nothing pushed; `origin/main` remains at v0.2.1 (`dc99bce`).

## 2. Stable package files, sizes and SHA-256 checksums

Built with the established workflow (`dpkg-buildpackage -us -uc -b -a mipsel`) from a clean
`git archive` of `f00c094`; both clean-room builds produce byte-identical packages. Delivered copies
live next to the archived RC artifacts:

| Artifact | Path | Size (bytes) | SHA-256 |
|---|---|---|---|
| Integration package | `/home/vadim/edgeos-vxlan_0.2.2+edgeos3.0.1.e50_all.deb` | 20028 | `026d4d46dba631bfa2228f8be3af3565d505cd3650c9740b169e8c1b79a11bf9` |
| Kernel-module package | `/home/vadim/edgeos-vxlan-kmod_0.2.2+edgeos3.0.1.e50_mipsel.deb` | 29262 | `0cc64788646518903522711398114085495215480168f65a60fa8af2f347cb04` |

The same hashes are pinned in `install.sh` (`KMOD_SHA256` / `INTEGRATION_SHA256`) and recorded in
`SHA256SUMS` at `bd8a8e3`. The `.changes` / `.buildinfo` files were produced alongside the build and
are kept with the artifacts (not deployment artifacts). The RC1/RC2 artifacts are preserved
untouched.

## 3. Automated test and release-validation results

* **Off-device suite: 132/132 checks pass** (helper 64, templates 32, mock reconciliation 36) at the
  release commit — reproduced locally. CI runs the same suite on the release PR; historical CI runs
  (all on or before 2026-09-05) predate the suite and are not counted as validating it.
* **`scripts/validate-release.sh`: PASS** for `0.2.2+edgeos3.0.1.e50` — prerelease `no`, installer
  cross-check enforced (install.sh `VERSION`/`PKG_VERSION` == changelog), packaged module hashes
  `7c346342…` / `6d58ee59…` verified.
* **`scripts/validate-published-release.sh`: PASS (dry run)** against a staged asset set (both
  `.debs` + the committed `SHA256SUMS`) — installer pins equal staged hashes, `SHA256SUMS` `cmp`
  equal, package versions/architectures correct. This is the same check CI runs against published
  assets.
* **Reproducibility:** two independent clean-room builds from `f00c094` are byte-identical to each
  other. (As documented for v0.2.1, builds inside differently-materialised working trees embed
  different timestamps; the release artifacts come from clean trees and CI builds from a clean
  checkout, which is why §8 step 4 re-verifies the CI bytes.)
* **Version ordering:** `0.2.1 < 0.2.2~rc1 < 0.2.2~rc2 < 0.2.2` (stable sorts above RC2).
* **Contents and maintainer scripts:** the packaged file lists match the v0.2.1/RC layout
  (`vyatta-vxlan`, `vyatta-vxlan-addr`, `vyatta-vxlan-bridge`, `Interface.pm`, thirteen template files,
  changelog, copyright; kmod: both `.ko` files, changelog, copyright); all maintainer scripts
  (`preinst`/`postinst`/`prerm`/`postrm`, both packages) are **byte-identical to RC2**.
* **Dependencies:** unchanged from the RC2 pair that was installed on the router and container-
  tested — `edgeos-vxlan-kmod (= 0.2.2+edgeos3.0.1.e50)` (machine-verified equality with the built
  kmod version), `vyatta-cfg-system`, `libvyatta-cfg1 (=
  1:1.0.18+t5862406.er.3.0.1.ef8cbcb)`; full `dpkg-deb -f` diffs against RC2 show only the version
  fields changing.

## 4. Exact runtime differences between RC2 and stable

**None in the runtime payload.** Extraction and directory diffing show the stable packages differ
from RC2 **only** in:

* `usr/share/doc/edgeos-vxlan/changelog.gz` and `usr/share/doc/edgeos-vxlan-kmod/changelog.gz` (the
  new `0.2.2` changelog entry);
* control metadata: the `Version:` field, the kmod version inside the integration package's
  `Depends:`, and the regenerated `md5sums` files.

Everything the hardware runs exercised is byte-identical to RC2: the reconciler (`e276748e…`), the
`vyatta-vxlan-addr` helper (`a484717a…`), all templates (byte-equal to the repository), the bridge
helper, `Interface.pm`, both kernel modules (`7c346342…` / `6d58ee59…`), and every maintainer
script. The priority-subtree restructuring is **not** part of this release and remains untouched.

## 5. Final documentation changes

* `README.md` — v0.2.2 throughout: IPv6 underlay support, hardware-validated behavior list,
  upgrade/installation guidance, MTU guidance and family defaults, IPv6 firewall example, and the
  known limitations (static VTEP endpoints; non-atomic commits with the never-`save` rule; live
  IPv4 upgrade not hardware-tested; firewall = operator responsibility).
* `debian/changelog` — final `0.2.2+edgeos3.0.1.e50` entry (RC entries retained).
* `docs/release-notes-v0.2.2.md` — user-facing release notes (also the GitHub release body draft).
* `docs/issue-3-pr-draft.md` — §6 below.
* `docs/issue-3-hardware-validation-runbook.md`, `docs/issue-3-acceptance-criteria.md`,
  `docs/issue-3-hardware-evidence.md` — the bridged-rollback record corrected to the executed VNI
  902 (started from 902, restored 902; ifindex 31→33; br901; cost 200; priority 10); no other
  scenario with its own numbering was altered.
* `docs/issue-3-deployment-runbook.md` — points at the stable release materials.

## 6. Pull request title and description

**Title:** `Release v0.2.2: native IPv6 VXLAN underlay support`

**Description:** the complete PR body is prepared in `docs/issue-3-pr-draft.md` (issue #3 reference,
feature summary, RC1/RC2 hardware-validation summary, automated-test results, supported
firmware/hardware, known limitations, remaining untested scenarios, release artifact manifest, and
the explicit note that the 132-check suite's first CI execution is this PR's run — historical runs
do not validate it). It is submitted as-is when the PR is opened.

## 7. Live IPv4 upgrade test — disclosure confirmation

**Confirmed disclosed.** The exact v0.2.1 → v0.2.2 upgrade carrying an existing, active IPv4 VXLAN
has not been directly hardware-tested, and this statement appears in:

* `README.md` — the "Upgrading from v0.2.1" section and the Known limitations list;
* `docs/release-notes-v0.2.2.md` — Compatibility and upgrade notes, Known limitations, and Remaining
  untested scenarios;
* `docs/issue-3-pr-draft.md` — Known limitations and Remaining untested scenarios;
* `docs/issue-3-stable-release-readiness.md` — the acceptance-criteria audit (the one outright
  untested criterion) and T2 in the recommended test plan.

The package-upgrade mechanism itself has been validated (real `dpkg` container transactions and the
on-router RC1→RC2 upgrade with a live tunnel, no interface recreation), and the packages make no
configuration or interface changes on upgrade — but the specific scenario above remains an
evidence gap, not a tested path.

## 8. Ordered merge → tag → publish → installer-verification procedure

1. **Open the PR** (`feat/ipv6-underlay` → `main`) with the §6 title and the
   `docs/issue-3-pr-draft.md` body. Nothing has been pushed yet; the branch carries the full release
   commit series ahead of `origin/feat/ipv6-underlay`.
2. **Wait for CI on the PR to be green** — first execution of the 132-check suite, plus ShellCheck,
   `perl -c`, `git diff --check`, the package build and `validate-release.sh`. Do not merge on any
   red job, and do not treat earlier historical runs as validating this suite.
3. **Merge** the PR into `main` (regular merge, matching the v0.2.1 PR precedent).
4. **Tag the release commit**: `git tag -a v0.2.2 -m "edgeos-vxlan v0.2.2"` on the merge commit;
   `git push origin main v0.2.2`. The tag must equal `VERSION` (`v0.2.2`); `validate-release.sh`
   enforces this in CI.
5. **Let the tag-triggered CI build and validate** (the `package` job). Download the CI-built
   artifacts and confirm `sha256sum` equals §2 — integration `026d4d46…`, kmod `0cc64788…`. **If
   they differ, STOP and reconcile; do not publish artifacts that contradict the pins.**
6. **Publish the GitHub release** `v0.2.2` using the CI-built packages and `SHA256SUMS` as assets
   and the release notes as the body. Do not re-publish working-tree builds.
7. **Confirm the `published-release` validation job passed** (it runs on the release event; or
   dispatch it manually with `release_tag=v0.2.2`). This is the project's published-asset check.
8. **Installer verification (read-only first):** on a router,
   `curl -fsSL https://raw.githubusercontent.com/downwithbgp/edgeos-vxlan/v0.2.2/install.sh | sh -s -- --check`
   must print `Compatibility check: PASSED`; optionally run the full installer on a test unit and
   confirm `dpkg -l`, `dpkg -V`, `lsmod` and `dpkg --audit` (known pre-existing `squid`/`ssmtp`
   warnings excepted).
9. **Post-release:** keep the v0.2.1 recovery assets; run the recommended hardware tests T1/T2
   (`docs/issue-3-stable-release-readiness.md` §9) in the next maintenance window if not already
   run; file follow-ups for anything they surface.

## 9. GO / NO-GO assessment

**GO** — for publication, conditional on §8 steps 2 and 5.

* The stable runtime is byte-identical to the hardware-validated RC2 (diff proven in §4); the only
  changes are changelog and version metadata.
* No open defect requires a code change; independent review found no blocking issue; packaged
  payloads, module hashes, maintainer scripts and dependencies are all verified against the
  repository and against RC2.
* All release-validation checks pass locally, including a dry run of the published-release check
  against staged assets.
* The known limitations are documented in every user-facing location (§7), and the remaining
  untested scenarios are enumerated with their safety arguments in the readiness report.

Conditions that would make this a **NO-GO** at procedure time: a red CI job on the PR; CI-built
artifact hashes that do not match §2; any unexpected content difference discovered during §8 step 4;
or a maintainer decision that T1/T2 must run before tagging (in which case: run them, then resume at
§8 step 5 — neither is required by this gate).
