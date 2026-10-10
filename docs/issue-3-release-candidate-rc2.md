# Issue #3 — Release Candidate 2 (`0.2.2~rc2`)

**Status: built, inspected and upgrade-verified off-device. Nothing has been installed on the router,
nothing has been pushed and no release has been published.** This record supersedes
`issue-3-release-candidate.md` (RC1) for deployment; RC1's record stands as the history of that build.

---

## A. Artifacts

| Artifact | Path | Size (bytes) | SHA-256 |
|---|---|---|---|
| Integration package | `../edgeos-vxlan_0.2.2~rc2+edgeos3.0.1.e50_all.deb` | 19660 | `b053372252d36b1fa43d827e03ce7377a3bb780d7ae7b3f138db061c62200b4b` |
| Kernel-module package | `../edgeos-vxlan-kmod_0.2.2~rc2+edgeos3.0.1.e50_mipsel.deb` | 28874 | `7b5b61395f20f6f307a4dfd34cfd5912fe4affdb0d68022c1c8b459c98cdaad2` |

The RC1 artifacts remain in place and unchanged (`ed5bb677…` integration, `70e2580c…` kmod), so an
RC1 → RC2 comparison and the RC1 recovery path both stay available.

## B. What changed since RC1

1. **The VXLAN `mtu` minimum is now 68** — the kernel's own minimum for a VXLAN device
   (`dev->min_mtu = ETH_MIN_MTU`) — instead of 64, with the help text updated to `u32:68-8024`.
2. **A regression test pins it**: `test/unit-templates.sh` reads the bounds the template declares and
   requires 63–67 to be rejected and 68, 100, 1430 and 8024 to be accepted. The suite is **132
   checks** (helper 64, templates 32, mock 36), up from 120.

**Nothing else changed**, and that is verified rather than asserted: extracting both candidates and
diffing them shows the integration package differing **only** in
`opt/vyatta/share/vyatta-cfg/templates/interfaces/vxlan/node.tag/mtu/node.def` and the packaged
changelog, and the kernel-module package differing **only** in its changelog. The whole template tree,
the reconciler, both helpers, `Vyatta/Interface.pm` and both kernel modules are byte-identical to the
reviewed sources.

## C. Manifest

| Field | Value |
|---|---|
| Source | `feat/ipv6-underlay` working tree — the reviewed implementation plus this packaging and documentation change set (the packages were built from the tree, before the change set was committed) |
| Debian package version | `0.2.2~rc2+edgeos3.0.1.e50` |
| Target architecture | `mipsel` (kernel package), `all` (integration package) |
| Target firmware / kernel | EdgeRouter ER-e50, EdgeOS v3.0.1 build 5862409, kernel `4.14.54-UBNT` |
| Dependencies | `edgeos-vxlan-kmod (= 0.2.2~rc2+edgeos3.0.1.e50)`, `vyatta-cfg-system`, `libvyatta-cfg1 (= 1:1.0.18+t5862406.er.3.0.1.ef8cbcb)` — unchanged from RC1 and v0.2.1 |
| `vxlan.ko` / `udp_tunnel.ko` | `7c346342…` / `6d58ee59…` — unchanged since v0.2.1 |
| Test suite | 132/132 |
| Build | `dpkg-buildpackage -us -uc -b -a mipsel` clean; `./scripts/validate-release.sh` PASS |
| Version ordering | `0.2.1 < 0.2.2~rc1 < 0.2.2~rc2 < 0.2.2` |

## D. Upgrade safety (RC1 → RC2)

The transaction has the same shape as the v0.2.1 → RC1 upgrade analysed in
`issue-3-release-candidate.md`: the only maintainer scripts that unload modules or undo diversions act
on `remove`/`purge`, and the kernel package's `postinst` never unloads a loaded module.

**Verified off-device** in a throwaway container running real `dpkg`, with the RC1 pair installed
first and then upgraded to the RC2 pair in one transaction:

* both packages ended **`ii` at `0.2.2~rc2+edgeos3.0.1.e50`** and `dpkg --audit` was empty;
* the installed template was **updated in place** (the mtu bound inside the installed file moved from
  64 to 68);
* both diversions survived, and the diverted stock `Interface.pm` was untouched;
* the module tooling log shows `DEPMOD`, `MODPROBE ip6_udp_tunnel`, `MODPROBE vxlan` and **zero
  module-removal calls** — the already-loaded `udp_tunnel` was left alone, as designed;
* reinstalling the RC1 pair afterwards (with dpkg's expected `downgrading …` warning) returned both
  packages to `ii` with the 64 bound restored — the recovery path works.

Caveats, as with the earlier simulation: the container is amd64 running Debian's `dpkg`, not EdgeOS's;
the kernel-module *copies* were re-architected to amd64 for the run so no forced options were needed;
`lsmod`/`modprobe`/`depmod` were stubbed and the stock `udp_tunnel.ko` hash simulated.

## E. Minimal RC1 → RC2 upgrade procedure

Both packages, one `dpkg` invocation, kernel package first. No `--force-*` options, no `apt`.

```
[PKG] sudo dpkg -i /tmp/rc2/edgeos-vxlan-kmod_0.2.2~rc2+edgeos3.0.1.e50_mipsel.deb \
                   /tmp/rc2/edgeos-vxlan_0.2.2~rc2+edgeos3.0.1.e50_all.deb
```

Verify both files against section A on the router **before** installing.

Expected transcript (it should be boring):

```
Preparing to unpack .../edgeos-vxlan-kmod_0.2.2~rc2+edgeos3.0.1.e50_mipsel.deb ...
Unpacking edgeos-vxlan-kmod (0.2.2~rc2+edgeos3.0.1.e50) over (0.2.2~rc1+edgeos3.0.1.e50) ...
Preparing to unpack .../edgeos-vxlan_0.2.2~rc2+edgeos3.0.1.e50_all.deb ...
Unpacking edgeos-vxlan (0.2.2~rc2+edgeos3.0.1.e50) over (0.2.2~rc1+edgeos3.0.1.e50) ...
Setting up edgeos-vxlan-kmod (0.2.2~rc2+edgeos3.0.1.e50) ...

NOTICE: udp_tunnel is already loaded.
The patched module has been installed on disk but the currently
loaded module will remain active until it is safely reloaded or
the router is rebooted.

Setting up edgeos-vxlan (0.2.2~rc2+edgeos3.0.1.e50) ...
```

Stop on any `ERROR:` line, on `dependency problems`, or on `Errors were encountered while
processing:` — and do not retry with `--force`.

### Post-upgrade validation checks (read-only)

```
[RO] dpkg -l edgeos-vxlan edgeos-vxlan-kmod | tail -3   # both 'ii' at 0.2.2~rc2+edgeos3.0.1.e50
[RO] dpkg --audit                                        # empty
[RO] sudo dpkg -V edgeos-vxlan edgeos-vxlan-kmod         # silent
[RO] grep -n 'VAR(@) >=' /opt/vyatta/share/vyatta-cfg/templates/interfaces/vxlan/node.tag/mtu/node.def
                                                         # must read: $VAR(@) >= 68 && $VAR(@) <= 8024
[RO] sha256sum /lib/modules/4.14.54-UBNT/extra/vxlan.ko \
              /lib/modules/4.14.54-UBNT/kernel/net/ipv4/udp_tunnel.ko   # 7c346342… and 6d58ee59…
[RO] lsmod | grep -E '^(vxlan|udp_tunnel|ip6_udp_tunnel)'               # unchanged set
[RO] ip -j -d link show dev vxlan900      # identity, MTU and admin state unchanged
[RO] ping <peer overlay address>          # traffic still passing (5/5)
```

Then the behaviour check that motivated RC2 — a value the kernel cannot apply must now be refused
**before** anything is committed:

```
[CFG] configure
[CFG] set interfaces vxlan vxlan900 mtu 64     # must be rejected: "Must be between 68-8024"
[CFG] discard                                   # nothing changed
```

### Rolling back to RC1

Same shape, one invocation, kernel package first, with the RC1 files verified against
`issue-3-release-candidate.md` section A. `dpkg` prints a `downgrading …` warning; that is expected.

## F. What RC2 does **not** fix

* **The partial-commit limitation itself.** The engine remains non-transactional
  (`issue-3-partial-commit-analysis.md`). RC2 removes the one route our own validation allowed into it
  — a below-minimum MTU — but the class is wider: any reconciler failure can still leave a value that
  owns its own commit subtree in the active configuration. That is why the validation runbook keeps the
  configuration-versus-kernel check (5.4.5b) and the rule never to `save` after a failed commit.
* **The priority-subtree proposal.** Deliberately excluded from RC2 by the maintainer's instruction; it
  remains a documented, unvalidated follow-up in the analysis document, to be investigated separately.
* **The outstanding hardware work**: re-running Phase 5.4 and the minimum-MTU test on RC2, persistence,
  upgrade compatibility on the router, and non-canonical IPv4 syntax end to end.
