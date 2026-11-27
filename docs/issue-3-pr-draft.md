# Issue #3 — Pull Request (draft)

**Base:** `main` · **Head:** `feat/ipv6-underlay` · **Title:** `Release v0.2.2: native IPv6 VXLAN underlay support`

**Do not merge until the CI run on this pull request is green.** The workflow executes the full
132-check off-device suite plus ShellCheck/`perl -c`/`git diff --check`, the package build and
`scripts/validate-release.sh` on pull requests. The historical CI runs (13 of them, all on or before
2026-09-05) predate the new 132-check suite and must not be counted as validating it; this PR is the
suite's first execution on GitHub's runners.

---

## Description

Closes issue #3.

### Feature summary

* `local-ip`/`remote-ip` accept IPv4 **or** IPv6 literals, with the family enforced across the pair;
  malformed, prefix-carrying, mixed-family and unusable endpoints (link-local / multicast /
  unspecified-remote / loopback / IPv4-mapped) are rejected before anything is changed.
* Live identity is parsed from the kernel's JSON (`local6`/`remote6`) and endpoints are compared
  canonically, so IPv6 tunnels reconcile correctly and equivalent re-spellings do not recreate the
  interface.
* Family-aware MTU defaults — 1450 over IPv4 underlays, 1430 over IPv6 underlays — with explicit
  values always honoured and `delete mtu` restoring the family default. The `mtu` minimum is the
  kernel's own 68; values the kernel cannot apply are rejected at commit (RC2 correction).
* Fail-closed live-state snapshot; identity-guarded leaf handlers; deterministic-failure rollback
  restores the captured interface state, including bridge membership, path cost and port priority.
* New packaged helper `vyatta-vxlan-addr` (core Perl modules only), plus an off-device test suite
  (132 checks) wired into CI.
* No changes to the kernel module payloads (`vxlan.ko`, `udp_tunnel.ko`), their hashes, or the
  CVE-2022-50405 backport.

### Hardware-validation summary

Full record: `docs/issue-3-hardware-evidence.md` (RC1 and RC2 runs on the supported ER-X).

* **RC1:** native IPv6-underlay configuration through the EdgeOS templates; invalid/mixed-family
  commits rejected without touching live state; native creation with correct VNI/port/MTU/identity/
  MAC/addresses; bidirectional dual-stack dataplane; canonicalisation; family-aware MTU defaulting
  and override removal; VNI recreation and IPv4↔IPv6 transitions; deletion; deterministic-failure
  rollback including bridge state (kernel rollback PASS; configuration atomicity FAIL — analysed in
  `docs/issue-3-partial-commit-analysis.md`); no-op commits.
* **RC2:** minimum-MTU validation (64/67/8025 rejected immediately, candidate unchanged); RC1 → RC2
  package upgrade with the live tunnel untouched (ifindex preserved); `save` + reboot restoration of
  the tunnel (identity, MTU 1430, deterministic MAC, both overlay addresses); post-reboot
  dual-stack dataplane **20/20 packets, zero loss**.

### Automated-test results

* **132/132** off-device checks pass (helper 64, templates 32, mock reconciliation 36) — reproduced
  locally at the release commit.
* CI on this PR additionally runs: ShellCheck (installers, scripts, reconciler, tests), `perl -c` on
  the new helper, `git diff --check`, `dpkg-buildpackage -us -uc -b -a mipsel`,
  `scripts/validate-release.sh` and artifact staging.
* Release validation already passes locally (`validate-release.sh` PASS; published-release check
  dry-run PASS against the staged stable artifacts).

### Supported firmware and hardware

```text
Device:       Ubiquiti EdgeRouter X / ER-e50
EdgeOS:       3.0.1, build 5862409
Firmware:     EdgeRouter.ER-e50.v3.0.1.5862409.*
Kernel:       4.14.54-UBNT
Architecture: mipsel (kernel package), all (integration package)
```

Unchanged and deliberately narrow; both packages keep their firmware/kernel guards. No new platform
claims are made anywhere in this branch.

### Known limitations

* **VTEP endpoints are statically configured**; delegated-prefix changes are not tracked
  automatically, and dynamic underlay addressing (SLAAC/DHCPv6) at boot has not been validated.
* **EdgeOS commits are not universally atomic** — a failed commit can leave partially applied
  configuration; the operational rule (never `save` after a failed commit; compare configuration
  with kernel state and re-converge) ships in the README.
* **Existing live IPv4 VXLAN upgrade compatibility has not been directly hardware-tested** (the
  package-upgrade mechanism has been validated, including with a live tunnel).
* **Firewall configuration is the operator's responsibility**; `remote-ip` is not an ingress
  allowlist.

### Remaining untested scenarios

* The exact v0.2.1 → v0.2.2 upgrade with an existing, active IPv4 tunnel on hardware.
* Dynamic underlay addressing at boot and behaviour after an ISP prefix change.
* Traffic over a bridged tunnel in the IPv6-underlay bridge test (membership/options validated).
* The IPv6 firewall drop path for alternate sources (positive path demonstrated).
* The RC2-specific failure injection (256-character description) on the router.

### Release artifact manifest

Built reproducibly from commit `f00c094` (two byte-identical clean-room builds); checksums pinned in
`install.sh` and `SHA256SUMS` at `bd8a8e3`:

| Artifact | Size (bytes) | SHA-256 |
|---|---|---|
| `edgeos-vxlan_0.2.2+edgeos3.0.1.e50_all.deb` | 20028 | `026d4d46dba631bfa2228f8be3af3565d505cd3650c9740b169e8c1b79a11bf9` |
| `edgeos-vxlan-kmod_0.2.2+edgeos3.0.1.e50_mipsel.deb` | 29262 | `0cc64788646518903522711398114085495215480168f65a60fa8af2f347cb04` |

Runtime payload is byte-identical to the hardware-validated RC2 except the packaged changelog and
the version metadata; details and the full release procedure are in
`docs/issue-3-v0.2.2-release-gate.md` and `docs/release-notes-v0.2.2.md`.
