# Issue #3 — Stable Release Readiness Review: RC2 → v0.2.2

**Reviewed at** `feat/ipv6-underlay`, HEAD `2620ee8601dc357477e91c6532a61ebee10f073e` (6 commits ahead of
`origin/feat/ipv6-underlay` at `ada9c5ab1966e679f31c850caeed5e9fc8612f57`); the working tree was clean when the review began — this change set's documentation updates are the only writes since. The baseline
for the change audit is the published release **v0.2.1**
(`dc99bce4a1bcfc5d57daed7fc167e98df4441e81`). This review changed no code, no packages and no router
state; its only writes are the accompanying documentation updates.

**Method and evidence classes.** Every claim below is one of: **HW** — physical hardware, recorded
with its build (RC1 or RC2) in `issue-3-hardware-evidence.md`; **off-device** — the repository's
automated suites, package extraction and hashing, real-`dpkg` container runs, or live verification of
published assets; **review** — read-only source, packaging and CI analysis, including an independent
adversarial review pass over the branch diff performed for this assessment. Anything that rests on an
assumption rather than an observation says so.

**Verdict: READY WITH DOCUMENTED LIMITATIONS.** No known defect requires a code change. The release
carries explicitly documented limitations, a short list of release-time tasks (checklist, §11), and
two additional hardware tests that are recommended as cheap insurance but are not gating (§9). The
decision and its conditions are stated in §12.

---

## 1. Scope of the release

`0.2.2` is the IPv6 VXLAN underlay release. Relative to v0.2.1, the integration package changes the
reconciler and six templates, adds one helper, adds the off-device test suite and CI wiring, and
updates packaging metadata; the kernel-module package differs **only in its changelog** — its payload
is byte-identical to v0.2.1's (`git diff v0.2.1..HEAD -- modules/ patches/` is empty).

| Area | Change relative to v0.2.1 |
|---|---|
| `src/vyatta-vxlan` | Dual-family reconciliation: JSON identity incl. `local6`/`remote6`, canonical endpoint comparison, fail-closed snapshot capture, guarded mutable application, rollback incl. bridge state, pre-mutation validation |
| `src/vyatta-vxlan-addr` (**new**) | One Perl helper (core `Socket` + `JSON::PP` only): `family`, `canon`, `equal`, `check-endpoint(s)`, `present`, `default-mtu(-if)`, `parse-live`, `identity-matches` |
| Templates | `local-ip`/`remote-ip`: `type: ipv4,ipv6` + helper validation, cross-family commit check; `mtu`: family-aware delete, guard, static default removed, minimum 68 (RC2); `address`/`disable`/`bridge-group`: identity guards and canonical address handling |
| Tests | New off-device suite (helper 64 + templates 32 + mock 36 = **132 checks**), wired into CI |
| Packaging | `debian/changelog` (RC1, RC2 entries), `debian/edgeos-vxlan.install` (+ helper), `scripts/validate-release.sh` (prerelease-aware), workflow (+ suite step) |
| Unchanged | Kernel payload and patch, `src/vyatta-vxlan-bridge`, `Vyatta/Interface.pm`, the `vni`/`port`/`description` templates, the template priority assignments, the bridging model and packaging guards |

The implementation follows the reviewed plan (`issue-3-change-inventory.md`), with two documented
variant choices: the `mtu` template default was **removed** (the fallback variant, so the design does
not depend on the unprobed engine `existsActive` semantics) and the IPv4 literal policy is
**platform-parity octal emulation**. The first is exercised by the hardware runs; the second still
lacks target confirmation (§6).

## 2. Actual supported platforms

Unchanged and deliberately narrow — the same claim v0.2.1 carried:

```text
Device:       Ubiquiti EdgeRouter X / ER-e50
EdgeOS:       3.0.1, build 5862409
Kernel:       4.14.54-UBNT
Architecture: mipsel (kmod), all (integration)
```

Both packages keep the firmware guard in `preinst`; the kmod package additionally requires the
running kernel to be `4.14.54-UBNT`. No new device, firmware or kernel claims are made anywhere in
the tree, and none should be made until separately validated. `README.md` still describes v0.2.1 —
accurate for what it claims, but its update is part of the release task list (§11).

## 3. Hardware-validated capabilities

Recorded in detail, with exact observations, in `issue-3-hardware-evidence.md`:

| Capability | Build | Evidence |
|---|---|---|
| Endpoint validation: IPv6 literals accepted; malformed, CIDR-prefixed and mixed-family commits rejected without touching live state; unusable IPv6 classes rejected | RC1 | HW |
| Native creation: correct VNI, port, MTU, endpoint identity, MAC, overlay addresses; deletion | RC1 | HW |
| Dual-stack dataplane over the IPv6 underlay (IPv4 and IPv6 overlay) | v0.2.1 by hand; RC1 via the integration; RC2 post-reboot | HW |
| Canonicalisation: equivalent re-spelling does not recreate; no-op commits | RC1 (+ RC2 reboot identity) | HW |
| Family-aware MTU: unset → 1430 (v6) / 1450 (v4); explicit honoured; mutable changes; override removal restores the default | RC1 | HW |
| VNI recreation, IPv4↔IPv6 transitions, unrelated interfaces preserved | RC1 | HW |
| Deterministic recreation failure → kernel-state rollback (VNI, port, endpoints, MTU, MAC, bridge membership/cost/priority, admin state); bridge state preserved across recreation | RC1 | HW |
| Minimum-MTU validation: 64, 67, 8025 rejected immediately; candidate unchanged | RC2 | HW |
| RC1 → RC2 package upgrade without interface recreation (ifindex preserved) | RC2 | HW |
| `save` + reboot restoration: identity, MTU 1430, MAC `e6:69:92:17:3e:e9`, both overlay addresses, modules; post-reboot dual-stack dataplane **20/20 packets** | RC2 | HW |
| Full off-device suite, packaging payload integrity, version ordering, lint chain | branch HEAD | off-device (this review) |
| Partial-commit mechanism: per-priority-subtree commit without transaction rollback | RC1 failure runs + vendor-source analysis | HW + review |

**Explicit non-claims** (do not let any summary overstate these): the reboot used the same delegated
prefix; no power-loss, repeated-boot, or peer-reboot scenario was run; the bridged tunnel carried no
traffic in the tests; the peer's own VXLAN is manual and not persistent; and the RC2-specific failure
injection has not been executed (§7, §9).

## 4. Off-device verification, CI and the test suite

* **Test suite:** reproduced during this review — `bash test/run.sh` green, **132/132** (helper 64,
  templates 32, mock 36). The RC2 record's 120 → 132 delta is accurate.
* **Lint:** the CI steps (`sh -n` on the installers, ShellCheck on installers, helper scripts and the
  reconciler scripts, `perl -c` on the new helper, `git diff --check`) all pass locally.
* **Version ordering:** `0.2.1 < 0.2.2~rc1 < 0.2.2~rc2 < 0.2.2` verified with `dpkg --compare-versions`.
* **Packaging integrity:** the RC2 packages' payloads were extracted and compared byte-for-byte
  against the repository: templates `diff -r` clean, reconciler `e276748e…` and helper `a484717a…`
  identical to source, kmod payloads `7c346342…` / `6d58ee59…` matching the pins. The RC1 → RC2
  payload diff is exactly the `mtu` template plus the changelogs — nothing else, as claimed.
* **Published v0.2.1 chain:** the v0.2.1 release assets were downloaded from GitHub and hashed; they
  match `SHA256SUMS` and the pins in `install.sh` exactly (`d3e28936…` / `066f4e5d…`). The recovery
  path is intact and reachable.
* **CI state (fact, not assumption):** GitHub has run this workflow 13 times, all on or before
  2026-09-05 (the last runs built and published-validated v0.2.1 successfully — the machinery is
  known-good). **No CI run has yet executed the new 132-check suite**, because the only qualifying
  events are pushes to `main`/`ci/**`, tags, and pull requests, and the feature branch has had none
  since the suite was added. Opening the release PR produces that run;
  it is a release-checklist item (§11, item 11).

## 5. Packaging, upgrade, downgrade, removal; kernel identity

Maintainer-script behaviour was re-read line by line and matches the analysis in
`issue-3-release-candidate.md` §C and `issue-3-release-candidate-rc2.md` §D: nothing unloads a module
or undoes a diversion on `upgrade`; the kmod `postinst` only runs `depmod`/`modprobe` and leaves a
loaded `udp_tunnel` alone; the integration package has no `postinst` at all.

* **Upgrade (off-device):** real-`dpkg` container runs covered 0.2.1 → RC1 → RC2, downgrade back to
  RC1 (and 0.2.1 in the earlier record), diversion survival, the diverted stock files unchanged, and
  the expected "udp_tunnel is already loaded" notice. Caveats (amd64 container, stubbed module
  tooling) are stated in those records.
* **Upgrade (on the router, RC2):** RC1 → RC2 executed; both packages `ii`, `dpkg -V` clean, tunnel
  untouched (ifindex preserved). `dpkg --audit` shows only the pre-existing `squid`/`ssmtp`
  checksum-metadata warnings that predate both candidates and are unrelated to these packages.
* **Downgrade:** accepted by `dpkg` with the expected warning in the container runs; the v0.2.1
  published assets are verified available and hash-pinned for the real recovery path.
* **Removal:** guards refuse removal while saved VXLAN configuration exists (integration) or live
  VXLAN interfaces exist (kmod); the diversion-restore code is unchanged since v0.2.0/v0.2.1, which
  carry hardware removal records. A full removal on the RC2/stable build was not performed.
* **Kernel identity and security patch:** `vxlan.ko` `7c346342…` and `udp_tunnel.ko` `6d58ee59…`,
  both byte-unchanged from v0.2.1; the CVE-2022-50405 backport patch is untouched
  (`586775e4…`); the stock-module diversion pin `14fbf8c4…` is unchanged. The dependency coupling
  (`edgeos-vxlan` depends on the exact kmod version) is intact and both packages come from one
  changelog entry.

## 6. Known limitations (documented; each with its release impact)

1. **The partial-commit class (engine-level).** EdgeOS commits per priority subtree and writes the
   successful part even when a commit fails (`COMMIT_STATUS=PARTIAL`). Within this integration, a
   failed reconciler can still leave a changed leaf value — `mtu`, `address`, `bridge-group` each own
   a priority-460 subtree — in the active configuration while the kernel holds the pre-commit value.
   RC2 removes the specific route our own validation had allowed (kernel-impossible MTUs now fail in
   validation), and the RC2 injection is deliberately one that cannot drift. The class itself
   remains, including the mutable-only path and the DELETE path. **Impact:** recoverable, operator-
   guided, not a dataplane corruption; the documented rule is *never `save` after a failed commit;
   compare the active configuration with the kernel and re-converge first* (recovery executed and
   proven on hardware). The priority-subtree restructuring is deliberately deferred and must not be
   bundled into this release. **Verdict on the §4 question: acceptable documented limitation, not a
   release blocker — provided the operational rule ships in the documentation (checklist item 3).**
2. **Dynamic underlay addresses.** The tunnel is a fixed-VTEP configuration; a changed delegated
   prefix, or an underlay address that arrives after the configuration replay, is not handled or
   tested. **Recommendation: document the static-VTEP requirement for this release** rather than
   attempt dynamic handling; treat dynamic-prefix support as a separate issue.
3. **Peer persistence.** The peer-side VXLAN is manual and outside the package's responsibility.
   **Impact:** none on the package; must not be described as a persistent two-endpoint deployment.
4. **Non-canonical IPv4 literals.** The platform-parity octal policy is implemented and tested
   off-device but unconfirmed on the target. **Impact:** a wrong guess fails *closed* — the commit is
   refused; it can never silently rebind an address. Low severity.
5. **Evidence filing and documentation debt.** Raw hardware transcripts are not yet attached to the
   issue; `README.md` still describes v0.2.1 (limitations list, MTU guidance, IPv6 firewall example,
   tested-behavior list); the MTU/readiness timing note is unwritten; the Phase-1 design-variant note
   is unwritten. All are release tasks (§11) — **these are the only things this review would not
   publish without.**
6. **Bridged-tunnel traffic and the IPv6 firewall drop direction** are undemonstrated (membership,
   cost, priority, and the positive firewall path *are* demonstrated).
7. **Byte-reproducibility caveat (pre-existing):** clean-room builds from the same tree reproduce
   byte-identically, but builds inside a differently-materialised working tree embed different
   timestamps. The release build must come from the clean/tagged tree (or CI).
8. **Security-review notes:** no reachable injection was found in the new code; one hardening nit was
   identified (`default-mtu-if` passes an interface name into a shell-quoted API call without
   re-validating it — unreachable with the interface-name pattern the templates enforce, cheap to
   harden in a future change, explicitly *not* touched by this review).

## 7. Untested behavior (consolidated)

The evidence document lists these in full; for release purposes:

| # | Untested | Safety of the failure mode |
|---|---|---|
| 1 | RC2-specific failure injection (256-char description) | Bounded: the injection exercises the same rollback code as RC1's; an unexpected rollback failure on the disposable interface is contained |
| 2 | Bridged-tunnel traffic | Cosmetic to the claim, not to the datapath (bridging does not alter encapsulation) |
| 3 | Upgrade from v0.2.1 with a committed IPv4 tunnel | Bounded: no interface-touching code runs during an upgrade; v4 identity handling has hardware and suite coverage |
| 4 | Non-canonical IPv4 binding on the target | Fails closed (see §6.4) |
| 5 | Dynamic prefix / readiness timing | To be documented as a static-VTEP requirement (§6.2; checklist item 3); after a prefix change the stored endpoints must be updated |
| 6 | Snapshot fail-closed on the target (Phase 5.5) | Off-device suites cover it; the hardware scenario cannot be induced safely |
| 7 | Failure injection on a family transition | Mock-covered; no safe hardware variant identified |
| 8 | IPv6 firewall drop direction | Positive path demonstrated; IPv4 analogue demonstrated; documentation task |
| 9 | CI execution of the suite (pending a qualifying event) | Process gap only — the suite is green locally and the workflow is standard |

None of these has a failure mode that would damage a remote router or silently corrupt user traffic.

## 8. Release blockers

**Code-level blockers: none found.** Independent review of the branch diff found no defect that must
block; the audit found the packaged payloads identical to the reviewed sources, the module identity
and security patch unchanged, and the acceptance-criteria gaps confined to the items above.

**Process-level blockers (must be done before publication, not before a decision):**

1. Documentation accuracy — `README.md` (limitations, MTU guidance + formula, IPv6 examples and
   `firewall ipv6-name`, partial-commit operational rule, tested-behavior list with the platform
   named, installer links), the timing note, and the design-variant note (§6.5).
2. Raw hardware captures attached to the issue/PR (sanitised).
3. The release mechanics — final changelog entry, clean build, `validate-release.sh`, pins and
   `SHA256SUMS`, the PR/CI run, tag and publication (§11).

## 9. Minimal final hardware test plan

Phases 0–4, 5.1–5.3 and 6 have already passed on hardware and **should not be repeated** — there is
no new uncertainty to resolve. The following set is the *only* remaining hardware work worth
proposing, each justified individually:

| # | Test (procedure) | Uncertainty it resolves | Why existing evidence is insufficient | Live changes | Expected result | Recovery | Class |
|---|---|---|---|---|---|---|---|
| T1 | Phase 5.4 re-run on RC2, with the 256-character description injection (verify the injection per 5.4.3 first), on disposable `vxlan901` | That the RC2-era injection works on the target kernel and that the rollback path completes under an alias-step failure | The RC1 rollback evidence is on byte-identical reconciler code, but the replacement injection's efficacy is measured only off-device, and the project's own Revision 6 said the rollback criteria stay unticked until this re-run | Candidate + live on the disposable interface; **not saved** | Commit fails; "Rolling back … completed."; pre-commit identity/MAC/MTU/alias/state restored; active config matches kernel (check per 5.4.5b); cleanup | Runbook 5.4.5b recovery then 5.4.6 cleanup; console available | **Desirable — recommended before tagging; not gating** (any rollback failure or unexplained drift would stop the release) |
| T2 | Upgrade v0.2.1 → v0.2.2 with a committed, active IPv4 VXLAN | The actual upgrade story for the existing IPv4 user base | Both real upgrades so far ran without a committed tunnel (RC1 install) or with an IPv6 tunnel (RC2); the criterion is outright untested | Packages only; the IPv4 tunnel config must exist and be active | Upgrade succeeds; tunnel neither recreated nor reconfigured; traffic uninterrupted; `dpkg -V` clean | Deployment runbook §8.4 (v0.2.1 pins verified) and §8.5 | **Desirable — recommended; not gating** (no interface-touching code runs on upgrade; v4 handling is suite- and hardware-covered) |
| T3 | Target non-canonical IPv4 probe (runbook 1.7; can be folded into a T1 session) | Confirms the platform-parity octal policy on the target | The helper's policy is off-device-verified only | Candidate-only for acceptance; a disposable interface to observe binding | Either octal binding (JSON shows the canonical result) or an explicit rejection; record which | `discard` the candidate; delete the disposable interface | Desirable, low priority (fails closed) |
| T4 | Dynamic underlay / prefix change (Phase 7.4) | Boot behaviour when the underlay address changes or arrives late | One reboot, same prefix, is the only evidence | Reboot + ISP-side/prefix disturbance | Tunnel restored once the address exists; readiness delay recorded | Console + saved config backup | **Not required for this release** — document the static-VTEP requirement (§6.2) and defer to a separate issue |
| T5 | Traffic over the bridged tunnel (Phase 6.6) | The one clause of the bridged criterion not demonstrated | Phase 6 validated membership/options only | Disposable `br901`/`vxlan901`, peer-side matching interface | Overlay ping across the bridged tunnel | Documented cleanup order (6.7) | Desirable, low priority |
| T6 | IPv6 firewall drop direction (alternate-source packet against the extended `VLANv6_LOCAL` ruleset) | That the v6 ruleset drops non-peer sources as intended | Only the positive path has been observed on hardware | Modifies the saved firewall config while testing; the current rule 80 is already saved and the tunnel depends on it | Alternate-source UDP/4789 dropped; unrelated traffic preserved | Re-commit the previous ruleset state; keep the rule if the tunnel is to stay up | Desirable, low priority |

Also worth doing at release time (process, not hardware): the PR/CI run on the release commit
(checklist item 11) and attaching the captures (checklist item 4).

## 10. Releasing now vs delaying

**Releasing now (with the checklist) means:** users get native IPv6 underlay support, the
family-aware MTU defaults with the corrected minimum bound, and the hardened reconciliation layer —
all of it already running on the reference router through the reboot — with limitations that are
documented and whose failure modes are bounded or fail closed. The residual risks are the evidence
gaps of §7; the most consequential is T2 (existing IPv4 installs), whose plausible downside is
bounded (no upgrade-time interface code; v4 handling tested) but not zero.

**Delaying buys only the residual tests** — no code change is planned, indicated, or (per this
review) needed. The candidate's behaviour has been hardware-validated across both the RC1 and RC2
runs, including the RC2-specific minimum-MTU change; keeping it a prerelease leaves that correction
unreleased while the same code continues to run in the test setup.
Each additional no-change delay also stretches the distance between the validated candidate and any
future stable build if other work intervenes.

**Balanced position:** decide READY WITH DOCUMENTED LIMITATIONS now; run T1 and T2 in the next
maintenance window — ideally before tagging, at the latest shortly after, with a patch release ready
if either surprises — and complete the release tasks first.

## 11. Release checklist (prepared; **not executed**)

**A. Freeze and content**
1. Confirm the stable payload is RC2's code plus documentation/changelog only (`diff` the built
   integration payload against the RC2 payload; expected differences: changelog and any committed
   doc file that ships in the package).
2. Decide T1/T2 timing (§9) and record the decision.

**B. Documentation (release tasks from §6/§7)**
3. `README.md`: remove “IPv6 underlay” from Known limitations; update version references and the
   installer raw URLs (`v0.2.2`); update the configuration tree (`mtu` 68–8024, family defaults);
   add the path-MTU formula and the no-fragmentation-reliance statement; add IPv6 configuration and
   `ip -j` JSON notes; add the `firewall ipv6-name` example including the existing-local-policy
   case; state the static-VTEP underlay requirement, the partial-commit operational rule and the
   interface-index semantics; extend the tested-behavior list with the RC1/RC2 hardware results,
   platform identified.
4. Attach the sanitised raw captures to the issue/PR.
5. Write the two short notes still owed: underlay readiness timing, and the Phase-1 design-variant
   record (MTU default removed; literal policy platform-parity).

**C. Version and changelog**
6. Add the final entry `edgeos-vxlan (0.2.2+edgeos3.0.1.e50) unstable; urgency=medium` (no `~`;
   RC1/RC2 entries stay). Confirm `scripts/validate-release.sh`'s prerelease guard no longer applies
   and the `VERSION`/`PKG_VERSION` cross-check will pass at the next step.

**D. Build and validate**
7. Build from a clean tree (or use CI artifacts): `dpkg-buildpackage -us -uc -b -a mipsel`;
   `./scripts/validate-release.sh` must print PASS (module hashes, versions, architectures).
8. Reproduce the build once from a second clean tree and confirm the package bytes match (clean-room
   builds are byte-stable; working-tree builds are not).

**E. Pins and checksums (checksums model; no GPG signing exists in the project today)**
9. Compute SHA-256 of the two packages; update `install.sh` `VERSION`, `PKG_VERSION`,
   `KMOD_SHA256`, `INTEGRATION_SHA256`; regenerate `SHA256SUMS`. (Optional hardening, not required
   by precedent: sign the tag and/or assets.)
10. Re-verify: `install.sh` pins equal the built packages' hashes; `SHA256SUMS` matches;
    `dpkg-deb -f` versions/architectures correct.

**F. Commit, tag, CI**
11. Commit the release changes; open the PR on `main`; CI must be green (suite + lint + build +
    `validate-release.sh` + artifact upload) — **this run also satisfies the pending CI-execution
    criterion**.
12. Merge; tag annotated `v0.2.2` on the release commit (tag must equal `VERSION`; the validator
    enforces it); push `main` and the tag.

**G. Publish and verify**
13. Let the tag-triggered CI build and validate; attach **the CI-built packages and their
    `SHA256SUMS`** to the GitHub release (do not re-publish working-tree builds).
14. Confirm the `published-release` validation passes (release event, or `workflow_dispatch` with
    `release_tag=v0.2.2`).
15. Re-download the published assets and re-verify against `install.sh`/`SHA256SUMS` by hand once.

**H. After**
16. Keep the v0.2.1 recovery assets in place (unchanged by this release).
17. Run T1/T2 if not already run; on any surprise, open the follow-up work before closing the issue.
18. If the test router keeps the saved `VLANv6_LOCAL` rule 80, record it as deployment configuration
    (it is not a package-provided rule) and update the deployment runbook's preflight expectations.

## 12. Decision

**READY WITH DOCUMENTED LIMITATIONS.**

Concretely:

* The stable candidate is the RC2 code, which has passed — on the supported hardware — endpoint
  validation, native creation, dual-stack dataplane, canonicalisation, family-aware MTU handling,
  identity recreation, family transitions, deletion, deterministic-failure rollback with bridge
  state (RC1), the minimum-MTU validation, a real RC1→RC2 package upgrade with the tunnel
  untouched, and `save`+reboot restoration with 20/20 post-reboot packets (RC2). The candidate
  payload is byte-identical to what those runs exercised (verified by extraction and diffing); the
  stable build must reproduce it from the release commit (§11 item 1).
* No open defect requires a code change. The independent review found none; the audit confirmed
  module identity, package payload integrity, template consistency, and the packaging/upgrade
  behaviour in container runs plus two real on-router upgrades.
* The release carries real, user-visible limitations — the non-transactional commit class, static
  VTEP underlay requirements, and the evidence/documentation gaps listed in §6 — and it must ship
  with them *documented*, not implied away. That documentation is checklist work.
* The two recommended hardware tests (T1, T2) should be run in the next maintenance window; neither
  is a condition of this decision, and a failure in either would stop the release (T1) or trigger a
  follow-up decision (T2) immediately.

This review found no basis for *NOT READY — CODE CHANGES REQUIRED* (nothing needs changing) and no
remaining test whose absence, given the evidence above, justifies *NOT READY — REQUIRED TESTS
REMAIN*. The publication itself must not proceed until the §11 checklist — in particular the
documentation items and the CI run on the release commit — is complete.
