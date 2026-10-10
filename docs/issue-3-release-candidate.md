# Issue #3 — IPv6 VXLAN Underlay: Release Candidate Record

**Status: release candidate prepared and validated off-device. Nothing has been installed on the
router, nothing has been pushed, and no release has been published.**

This document is the reviewable record for the release candidate: the artifacts (A), the manifest
(B) and the upgrade-safety assessment (C). The operational runbooks are separate documents:
`docs/issue-3-hardware-validation-runbook.md` (E) and the deployment runbook (D), which exists in two
forms — the sanitised `docs/issue-3-deployment-runbook.md` in this tree, and an instance carrying the
live underlay addresses in the gitignored `local/` directory.

Sanitisation note: the test environment's addresses come from the owner's delegated home prefix and
are not published here. `<PREFIX>` stands for that delegated prefix throughout this document.

---

## A. Release-candidate artifacts

Built on the development workstation with the project's existing workflow:

```
dpkg-buildpackage -us -uc -b -a mipsel
```

| Artifact | Path | Size (bytes) | SHA-256 |
|---|---|---|---|
| Integration package | `../edgeos-vxlan_0.2.2~rc1+edgeos3.0.1.e50_all.deb` | 19358 | `ed5bb677c932c2eb3c9b6adafd47292f6e2606dd19641c7c8bc173359a5a7f6e` |
| Kernel-module package | `../edgeos-vxlan-kmod_0.2.2~rc1+edgeos3.0.1.e50_mipsel.deb` | 28628 | `70e2580cf47e89ca1c11fa9fc5434b3bec7a803a20d6c60d3d2c7ee02ca6faa3` |

(`../` is relative to the repository root; the `.changes` and `.buildinfo` files produced alongside
them are not deployment artifacts.)

The published v0.2.1 release assets were not touched: the release-candidate filenames carry the
prerelease version.

**Trap for whoever prepares the recovery media.** The copy of the *v0.2.1 integration* package that
happens to sit in the build directory is a development build from this branch, not the published
v0.2.1 asset: it contains `vyatta-vxlan-addr` and the IPv6 templates while still claiming version
`0.2.1+edgeos3.0.1.e50`, and its SHA-256 is not the published one. It must not be used as a
recovery artifact. The v0.2.1 *kmod* build in that directory does still match its published pin.

### Reproducibility

Two independent clean-room builds (fresh `git archive` trees outside the repository, same sources
and packaging changes) produced byte-identical packages to each other:

| Artifact | SHA-256 of both clean-room builds |
|---|---|
| integration | `5a1a273395cd926bab203c7d6daa45b0738ae36edd156d21ede23c0a787e2bca` |
| kmod | `627bc7979c334126fcc8404894e135b6920703dc00636b7a21f51da53dc25d77` |

Their payloads and control data are byte-identical to the delivered artifacts (verified by
extraction and `diff -r`), but the *package files* differ from them because a build run inside the
working tree embeds working-tree file timestamps. The project therefore has reproducible
*contents*, not reproducible *bytes*: two runs in the same materialised tree agree, and a tree
materialised at a different time does not. Hashes in this document are of the delivered files.

For calibration: neither locally rebuilt v0.2.1 package reproduced its published CI-built hash
either, so this is a pre-existing property of the project's packaging, not something this change
introduced.

---

## B. Release-candidate manifest

| Field | Value |
|---|---|
| Implementation commit | `ada9c5ab1966e679f31c850caeed5e9fc8612f57` (`feat/ipv6-underlay`; 13 commits after the `v0.2.1` tag) |
| Packaging changes on top of it | `debian/changelog` (new entry) and `scripts/validate-release.sh` (prerelease-aware cross-check); no source file changed |
| Debian package version | `0.2.2~rc1+edgeos3.0.1.e50` |
| Target architecture | `mipsel` for the kernel-module package, `all` for the integration package |
| Target firmware | EdgeRouter ER-e50, EdgeOS v3.0.1 build 5862409 |
| Target kernel | `4.14.54-UBNT` |
| `vxlan.ko` SHA-256 | `7c346342bf00202820e8581bfdfc28851add052d2b0e5dde1560819f90bf82b6` (unchanged from v0.2.1) |
| `udp_tunnel.ko` SHA-256 | `6d58ee597d8ae50898efe90ec61a4803ae4f0549f29fba9c4132ca92260405cc` (unchanged from v0.2.1) |
| Dependencies (integration) | `edgeos-vxlan-kmod (= 0.2.2~rc1+edgeos3.0.1.e50)`, `vyatta-cfg-system`, `libvyatta-cfg1 (= 1:1.0.18+t5862406.er.3.0.1.ef8cbcb)` |
| Test suite | 120/120 checks pass: unit-helper 64, unit-templates 20, mock 36 |
| Build | `dpkg-buildpackage -us -uc -b -a mipsel` succeeds; `./scripts/validate-release.sh` reports PASS |
| Lint | `shellcheck src/vyatta-vxlan src/vyatta-vxlan-bridge test/*.sh` clean; `sh -n` + `shellcheck install.sh scripts/*.sh` clean; `perl -c src/vyatta-vxlan-addr` clean |

### Payload inventory (verified by extraction, not by trusting the source tree)

Integration package — `opt/vyatta/sbin/vyatta-vxlan` (18664, 0755), `opt/vyatta/sbin/vyatta-vxlan-addr`
(12393, 0755, **new in this release**), `opt/vyatta/sbin/vyatta-vxlan-bridge` (5952, 0755),
`opt/vyatta/share/perl5/Vyatta/Interface.pm`, 12 template files under
`opt/vyatta/share/vyatta-cfg/templates/interfaces/vxlan/`, plus changelog and copyright.
Every file compares byte-identical to its source in the repository.

Kernel-module package — `lib/modules/4.14.54-UBNT/extra/vxlan.ko`,
`lib/modules/4.14.54-UBNT/kernel/net/ipv4/udp_tunnel.ko`, plus changelog and copyright. Both
modules compare byte-identical to the reviewed module payload, and `git diff v0.2.1 HEAD --
modules/ patches/` is empty: the CVE-2022-50405 backport and the module binaries are unchanged.

### Change relative to v0.2.1

Payload-level comparison against a v0.2.1 built from the `v0.2.1` tag reports exactly these
differences in the integration package:

* `opt/vyatta/sbin/vyatta-vxlan` (the reconciler),
* `opt/vyatta/sbin/vyatta-vxlan-addr` (added),
* templates `address`, `bridge-group`, `disable`, `local-ip`, `mtu`, `remote-ip`,
* the packaged changelog.

Everything else — `Vyatta/Interface.pm`, the bridge helper, `node.def`, the `description`, `port`,
`vni`, `bridge-group/bridge`, `bridge-group/cost` and `bridge-group/priority` templates — is
byte-unchanged. The kernel-module package differs from v0.2.1 only in its changelog.

### Packaging properties checked

* The integration package carries the updated templates and the new helper, mode 0755.
* The reconciler carries the full reviewed IPv6 change set.
* Dependencies are unchanged from the working v0.2.1 pair, so they are known-satisfiable on the
  router: the currently installed production packages declare the identical `libvyatta-cfg1` pin.
* Both packages are produced from one `debian/changelog` entry, so the exact-version dependency
  between them is satisfied within a single transaction.
* Installer SHA-256 pins in `install.sh` were deliberately **not** modified, and `SHA256SUMS` still
  describes the published v0.2.1 release. `install.sh` therefore still installs the last public
  release; it will be repointed at release time, not now.
* No additional target platform is claimed: both packages keep the firmware and kernel guards that
  restrict them to ER-e50 / EdgeOS 3.0.1 build 5862409 / `4.14.54-UBNT`.

### Known limitations of this candidate

* The native EdgeOS integration path has since been exercised on hardware for creation, dual-stack
  dataplane, endpoint canonicalisation, family-aware MTU defaulting and restoration, VNI recreation,
  family transitions, deletion, malformed-address and mixed-family rejection, and no-op commits (see
  `issue-3-hardware-evidence.md`). Rollback was then exercised under deterministic failure injection:
  **the kernel rollback passed, but the failed commit still wrote the changed leaf value into the
  active configuration — configuration atomicity FAIL** (`issue-3-partial-commit-analysis.md`).
  Bridging, persistence and upgrade compatibility remain outstanding, so this remains a prerelease
  rather than a validated release.
* The package bytes are not reproducible across differently-materialised trees (see above).
* The candidate is a prerelease: it sorts above 0.2.1 but below the eventual 0.2.2, and it must not
  be published as a release.

---

## C. Upgrade-safety assessment

### The question

The integration package depends on the exact version of the kernel package, so an upgrade bumps the
kernel-module package even though its module payload is byte-identical. The router currently has
`vxlan`, `udp_tunnel` and `ip6_udp_tunnel` loaded. Does the package transaction remove, unload or
disturb them, or can it leave the router half-configured?

### Answer

**The upgrade is safe with the modules loaded. No module is unloaded or removed, no service is
interrupted, and both failure paths fail closed with the previous version still configured.**

### Why — maintainer-script analysis

| Script | Action argument it acts on | Behaviour during an upgrade |
|---|---|---|
| `edgeos-vxlan.preinst` | `install\|upgrade` | Re-verifies the firmware, the existing diversion and the diverted `Interface.pm` hash. Never re-adds a diversion that already exists. |
| `edgeos-vxlan.prerm` | `remove` **only** | Inert. The saved-config guard therefore cannot block an upgrade. |
| `edgeos-vxlan.postrm` | `remove\|purge` | Inert — the diversion is not undone on upgrade. |
| `edgeos-vxlan-kmod.preinst` | `install\|upgrade` | Re-verifies firmware, running kernel, the existing diversion and the diverted stock module hash. |
| `edgeos-vxlan-kmod.prerm` | `remove` **only** | Inert. This is the only place `modprobe -r vxlan` exists, and it is unreachable during an upgrade. |
| `edgeos-vxlan-kmod.postinst` | always | Runs `depmod -a 4.14.54-UBNT`, then `modprobe ip6_udp_tunnel` and `modprobe vxlan` (no-ops when already loaded), and `modprobe udp_tunnel` **only if it is not already loaded**. Otherwise it prints a NOTICE. It never unloads anything. |
| `edgeos-vxlan-kmod.postrm` | `remove\|purge` | Inert — the diversion and `depmod` step are not run on upgrade. |

There is no `edgeos-vxlan.postinst` and no package declares triggers, so no extra transaction phase
exists that could restart a service.

### Expected package-manager sequence

Both packages must be upgraded in **one** `dpkg` invocation, kernel package first:

```
sudo dpkg -i edgeos-vxlan-kmod_0.2.2~rc1+edgeos3.0.1.e50_mipsel.deb \
             edgeos-vxlan_0.2.2~rc1+edgeos3.0.1.e50_all.deb
```

Order of operations dpkg performs — note that dpkg unpacks *every* file argument before configuring
any of them, so the transaction is "unpack both, then configure both" rather than a package-by-package
sequence (the simulation transcript in the deployment runbook shows exactly that):

1. new `edgeos-vxlan-kmod.preinst upgrade <old>` — guards, hash re-verification.
2. old `edgeos-vxlan-kmod.prerm upgrade <new>` — **no-op** (guard is `remove`-only).
3. unpack the new `.ko` files over the old ones.
4. old `edgeos-vxlan-kmod.postrm upgrade <new>` — **no-op**.
5. new `edgeos-vxlan.preinst upgrade <old>` — guards, hash re-verification.
6. old `edgeos-vxlan.prerm upgrade <new>` — **no-op**.
7. unpack the new helper, the new `vyatta-vxlan-addr`, the reconciler and the templates.
8. old `edgeos-vxlan.postrm upgrade <new>` — **no-op**.
9. configure the kernel package: new `edgeos-vxlan-kmod.postinst configure <old>` — `depmod`, NOTICE,
   no unload.
10. configure the integration package — it has no `postinst`, so nothing runs.

The unpacked `.ko` files replace files whose inodes are in use by the running kernel. That is safe:
the loaded module keeps its own copy, and the replacement is byte-identical anyway. The currently
loaded `udp_tunnel` module is *not* reloaded, so the patched code that is already running stays
running, and the on-disk copy stays the patched one.

Note that `vyatta-vxlan-addr` and the reconciler are read from disk on demand by the configuration
system; overwriting them while the CLI is idle affects neither the running configuration nor any
live interface.

### Empirical evidence

A real `dpkg` transaction was executed in a throwaway container against the actual candidate
packages: install 0.2.1 → upgrade to 0.2.2~rc1 → remove attempt → downgrade to 0.2.1 → firmware
guard test. Observed:

* the upgrade completed with **both packages configured** (`ii`) and an empty `dpkg --audit`;
* the module tooling call log contains `DEPMOD`, `MODPROBE ip6_udp_tunnel`, `MODPROBE vxlan` and
  **zero module-removal calls**, and `modprobe udp_tunnel` is skipped with the "already loaded"
  NOTICE — exactly the analysed path;
* both diversions survive the upgrade, and the diverted stock `Interface.pm` still hashes to the
  pinned `f4985acc53058088bda3ed3b989ed2d76e92a3edd9e2582272ff576dd089f721`;
* `/config/config.boot` is byte-unchanged by the transaction;
* a later `dpkg -r edgeos-vxlan` with a saved VXLAN configuration is refused by the `prerm` guard;
* reinstalling the 0.2.1 pair is accepted by `dpkg` (with a `downgrading` warning) and returns both
  packages to `ii` with the 0.2.1 helper set;
* with a wrong `/etc/version`, the new `preinst` refuses and the installed package stays configured
  at its previous version — no half-installed state.

Simulation caveats, stated plainly: the container is amd64 running a Debian `dpkg`, not EdgeOS's
`dpkg`; for that run only, the kernel-module *copy* was re-architected to amd64 (payload and
maintainer scripts untouched) so the transaction needed no forced options; `lsmod`, `modprobe` and
`depmod` were stubbed, and the stock `udp_tunnel.ko` hash was simulated because that exact firmware
artifact is not available off-device. Dependency resolution, diversion handling, file replacement,
guard logic and the stock `Interface.pm` hash check were exercised for real. The simulation is
corroboration, not a substitute for the maintainer-script analysis above.

### Required safeguards

1. **Install both packages in one `dpkg` invocation, kernel package first.** If the kernel package
   fails, `dpkg` leaves the integration package unpacked-but-unconfigured (`iU`) while the kernel
   package stays at its old version; installing them separately makes that state much more likely.
2. **Have verified v0.2.1 recovery packages at hand first** — the published release assets, checked
   against `SHA256SUMS` — not the stale development build mentioned in section A.
3. **Record `lsmod` before and after** and expect the identical loaded set.
4. **Detect incomplete installation with `dpkg --audit` and `dpkg -l`**, never by assuming.
5. **Do not treat `commit-confirm` as an undo for package installation**: it reverts the candidate
   configuration only, and package installation is outside it.
6. **Do not reboot as a generic recovery step.** A reboot changes the loaded-module set (cold-boot
   module loading) and re-runs configuration; it is a *validation* step, not a rollback.

### Residual risk

Low. The transaction only replaces files and re-runs `depmod`; the only code that can unload a
module is unreachable during an upgrade. The dominant residual risk is operational — a package
failing its firmware/hash guard mid-flight, or the operator upgrading the integration package
without the matching kernel package — both of which fail closed as demonstrated above.
